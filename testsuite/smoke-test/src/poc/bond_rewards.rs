// Copyright (c) Aptos Foundation
// Licensed pursuant to the Innovation-Enabling Source Code License, available at https://github.com/aptos-labs/aptos-core/blob/main/LICENSE

//! REW-01：已安装的保证金限幅仍保留完整的 10*S:30*S 奖励份额。
//! 通过普通节点交易产生 1 Octa 通胀及受限额约束的费用。

use super::{
    defaults::installed_at,
    fee_rewards::{
        address, assert_payment, assert_position, assert_transfer_fee_block, checkpoint_at, events,
        integer, ledger_at, pending_fees_at, pool_at, pool_event, position_at, priced_fee_factory,
        recorded_fee, stakes_at, success, view, wide,
    },
    optional_resource_at_version, resource_at_version,
    transactions::{compile_script, execute},
};
use crate::smoke_test_environment::SwarmBuilder;
use aptos_cached_packages::aptos_stdlib;
use aptos_forge::{LocalSwarm, NodeExt, Swarm};
use aptos_genesis::poc::{DeploymentMode, PocGenesisConfiguration, PowerParams};
use aptos_rest_client::Client;
use aptos_sdk::{transaction_builder::TransactionFactory, types::LocalAccount};
use aptos_types::{
    account_address::AccountAddress,
    account_config::CORE_CODE_ADDRESS,
    on_chain_config::{FeatureFlag, Features, OnChainChunkyDKGConfig, OnChainRandomnessConfig},
    transaction::{Script, TransactionArgument, TransactionPayload},
};
use move_core_types::int256::U256;
use once_cell::sync::Lazy;
use serde_json::{json, Value};
use std::{sync::Arc, time::Duration};

const UNIT_SCALE: u128 = 1 << 16;
const RAW_POWER: u64 = 40;
const POOL_UNITS: u128 = RAW_POWER as u128 * UNIT_SCALE;
const POSITION_UNITS: [u128; 2] = [10 * UNIT_SCALE, 30 * UNIT_SCALE];
const BOND: u64 = 100;
const BOND_OCTA_PER_OHMP: u64 = 1_000_000_000;
const INSTALLED_POWER: u64 = 10;
const REWARD_BASE: u64 = 100;

static GOVERNANCE: Lazy<Vec<u8>> = Lazy::new(|| {
    compile_script(
        "PoCBondCappedRewards",
        r#"script {
            use topo_std::fixed_point64;
            use topo_framework::stake;
            use topo_framework::staking_config;
            use topo_framework::topo_governance;

            fun main(root: &signer, configure: bool, fee_limit: u64) {
                let framework = topo_governance::get_signer_testnet_only(root, @0x1);
                if (configure) {
                    // 在一定范围的实际提案成功率下，1.5% 奖励率与计奖基数 100
                    // 可产生恰好 1 个整数 Octa。
                    // 保留原生周期奖励率功能，并使用其公开设置入口。
                    let rate = fixed_point64::create_from_rational(3, 200);
                    let zero = fixed_point64::create_from_rational(0, 1);
                    staking_config::update_rewards_config(&framework, rate, rate, 31536000, zero);
                    stake::set_transaction_fee_limit_per_epoch_per_pool(&framework, fee_limit);
                };
                topo_governance::reconfigure(&framework);
            }
        }"#,
    )
});

fn governance_payload(configure: bool, fee_limit: u64) -> TransactionPayload {
    TransactionPayload::Script(Script::new(GOVERNANCE.clone(), vec![], vec![
        TransactionArgument::Bool(configure),
        TransactionArgument::U64(fee_limit),
    ]))
}

struct Fixture {
    swarm: LocalSwarm,
    client: Client,
    root: Arc<LocalAccount>,
    // 目标池保证金所有人、U1 和 U2；仅 U1/U2 向目标池分配算力。
    participants: [LocalAccount; 3],
    pools: Vec<AccountAddress>,
    factory: TransactionFactory,
}

impl Fixture {
    fn target(&self) -> AccountAddress {
        self.participants[0].address()
    }
}

async fn fixture(native_bps: u64, fee_limit: u64) -> Fixture {
    Lazy::force(&GOVERNANCE);
    println!("REW-01 bond fixture A: nodes=7 (4 background, target bond owner, U1/U2), Open, min_validators=4, min_power=10, max_power=100, each initial_power=40, bond=100 Octa, ratio=10 TOPO/OHMP, epoch=3600s, growth=25%, retention=10000, native_bps={native_bps}, fee_max={fee_limit}; ordinary/Chunky DKG=off; rate 3/200 installed through public governance");
    let swarm = SwarmBuilder::new_local(7)
        .with_aptos()
        .with_init_genesis_stake(Arc::new(|_, stake| *stake = BOND))
        .with_init_genesis_config(Arc::new(move |config| {
            config.allow_new_validators = true;
            config.epoch_duration_secs = 3600;
            config.min_stake = 1;
            config.max_stake = 1000;
            config.voting_power_increase_limit = 25;
            config.randomness_config_override = Some(OnChainRandomnessConfig::Off);
            config.chunky_dkg_config_override = Some(OnChainChunkyDKGConfig::default_disabled());
            config.poc_genesis_config = Some(Arc::new(move |_| PocGenesisConfiguration {
                params: PowerParams {
                    bond_octa_per_ohmp: BOND_OCTA_PER_OHMP,
                    min_power: INSTALLED_POWER,
                    max_power: 100,
                    min_validators: 4,
                },

                deployment_mode: DeploymentMode::Open,
                retention_bps: 10000,
                initial_raw_power: RAW_POWER,
            }));
        }))
        .build()
        .await;
    super::configure_fixture(&swarm, [4, 4, 32, 8, fee_limit], native_bps).await;
    let mut pools = swarm
        .validators()
        .map(|node| node.peer_id())
        .collect::<Vec<_>>();
    pools.sort();
    // 两个算力用户原先的池均在准备阶段退出委员会。
    let client = swarm.validator(pools[3]).unwrap().rest_client();
    let root = swarm.chain_info().root_account();
    let factory = swarm
        .chain_info()
        .transaction_factory()
        .with_gas_unit_price(1)
        .with_max_gas_amount(2_000_000)
        .with_transaction_expiration_time(120);
    let mut public = swarm.chain_info().into_aptos_public_info();
    let mut participants = Vec::new();
    for owner in &pools[..3] {
        public.mint(*owner, 1_000_000_000).await.unwrap();
        let key = swarm
            .validator(*owner)
            .unwrap()
            .account_private_key()
            .as_ref()
            .unwrap()
            .private_key();
        let sequence = client
            .get_account(*owner)
            .await
            .unwrap()
            .into_inner()
            .sequence_number;
        participants.push(LocalAccount::new(*owner, key, sequence));
    }
    Fixture {
        swarm,
        client,
        root,
        participants: participants.try_into().unwrap(),
        pools,
        factory,
    }
}

fn configured_rate() -> (u64, u64, u128) {
    let scale = 1u128 << 64;
    let raw = 3 * scale / 200;
    let denominator = 1_000_000 * scale / raw;
    let numerator = denominator * raw / scale;
    (numerator as u64, denominator as u64, raw)
}

fn reward_index(amount: u64) -> U256 {
    let q = U256::ONE << U256::from(128_u8);
    U256::checked_div(
        U256::checked_mul(U256::from(amount), q).unwrap(),
        U256::from(POOL_UNITS),
    )
    .unwrap()
}

struct Expected {
    native: u64,
    poc: u64,
    delta: U256,
    claims: [u64; 2],
    remainders: [U256; 2],
}

impl Expected {
    fn new(native_bps: u64, fee: u64) -> Self {
        let inflation = 1u128;
        let native_inflation = inflation * native_bps as u128 / 10_000;
        let native_fee = fee as u128 * native_bps as u128 / 10_000;
        let native = (native_inflation + native_fee) as u64;
        let poc = (inflation + fee as u128 - native as u128) as u64;
        let delta = reward_index(poc);
        let q = U256::ONE << U256::from(128_u8);
        let accrued =
            POSITION_UNITS.map(|units| U256::checked_mul(delta, U256::from(units)).unwrap());
        let claims =
            accrued.map(|amount| u64::try_from(U256::checked_div(amount, q).unwrap()).unwrap());
        let remainders = accrued.map(|amount| U256::checked_rem(amount, q).unwrap());
        let exact = match (native_bps, fee) {
            (0, 39) => (0, 40, [10, 30]),
            (3000, 39) => (11, 29, [7, 21]),
            (3000, 27) => (8, 20, [5, 15]),
            combination => panic!("Unsupported REW-01 combination {combination:?}"),
        };
        assert_eq!((native, poc, claims), exact);
        Self {
            native,
            poc,
            delta,
            claims,
            remainders,
        }
    }
}

#[derive(Debug)]
struct PerformanceInput {
    successes: u128,
    failures: u128,
    numerator: u64,
    denominator: u64,
    inflation: u64,
}

/// 使用已安装奖励率和原始提案计数，不使用奖励预览生成预期。
async fn performance_input(
    client: &Client,
    pool: AccountAddress,
    version: u64,
) -> PerformanceInput {
    let installed = installed_at(client, version).await;
    let validator = installed
        .validators
        .active_validators
        .iter()
        .find(|validator| validator.account_address == pool)
        .unwrap();
    assert_eq!(validator.consensus_voting_power(), INSTALLED_POWER);
    let performance = optional_resource_at_version(
        client,
        CORE_CODE_ADDRESS,
        "0x1::stake::ValidatorPerformance",
        version,
    )
    .await
    .unwrap()
    .data;
    let counter = &performance["validators"][validator.config().validator_index as usize];
    let successes = integer(&counter["successful_proposals"]);
    let failures = integer(&counter["failed_proposals"]);
    let (_, _, numerator, denominator, _, _) = installed.reward_context;
    assert!(denominator > 0);
    let inflation = if successes + failures == 0 {
        0
    } else {
        (REWARD_BASE as u128 * successes * numerator as u128
            / ((successes + failures) * denominator as u128)) as u64
    };
    PerformanceInput {
        successes,
        failures,
        numerator,
        denominator,
        inflation,
    }
}

async fn assert_allocation_and_cap(fixture: &Fixture, version: u64) {
    let target = fixture.target();
    let config = view(
        &fixture.client,
        "0x1::poc_accounting::get_config",
        vec![],
        version,
    )
    .await;
    assert_eq!(
        integer(&config[4]["bond_octa_per_ohmp"]),
        BOND_OCTA_PER_OHMP as u128
    );
    let cap = BOND as u128 * 100_000_000 / BOND_OCTA_PER_OHMP as u128;
    let power = (RAW_POWER as u128)
        .min(cap)
        .min(integer(&config[4]["max_power"]));
    let base = power * BOND_OCTA_PER_OHMP as u128 / 100_000_000;
    assert_eq!(
        (power, base),
        (INSTALLED_POWER as u128, REWARD_BASE as u128)
    );
    let installed = installed_at(&fixture.client, version).await;
    let target_validator = installed
        .validators
        .active_validators
        .iter()
        .find(|validator| validator.account_address == target)
        .unwrap();
    assert_eq!(target_validator.consensus_voting_power() as u128, power);
    let pool = pool_at(&fixture.client, target, version).await;
    assert_eq!(integer(&pool[0]), POOL_UNITS);
    assert_eq!(integer(&pool[1]), POOL_UNITS);
    assert_eq!(integer(&pool[2]), base);
    assert_eq!(
        integer(&ledger_at(&fixture.client, target, version).await["units"]),
        POOL_UNITS
    );
    assert_position(&fixture.client, target, target, 0, 0, U256::ZERO, version).await;
    let owner_allocation = view(
        &fixture.client,
        "0x1::poc_accounting::get_allocations",
        vec![json!(target)],
        version,
    )
    .await;
    assert_eq!(owner_allocation, vec![json!([]), json!({"vec": []})]);
    for (index, user) in fixture.participants[1..].iter().enumerate() {
        assert_position(
            &fixture.client,
            user.address(),
            target,
            POSITION_UNITS[index],
            0,
            U256::ZERO,
            version,
        )
        .await;
        assert_eq!(
            pool_at(&fixture.client, user.address(), version).await,
            vec![json!("0"), json!("0"), json!("0"), json!("0"), json!("0"),]
        );
        let allocation = view(
            &fixture.client,
            "0x1::poc_accounting::get_allocations",
            vec![json!(user.address())],
            version,
        )
        .await;
        assert_eq!(allocation[0].as_array().unwrap().len(), 1);
        assert_eq!(address(&allocation[0][0]["pool"]), target);
        assert_eq!(
            integer(&allocation[0][0]["bps"]),
            if index == 0 { 2500 } else { 7500 }
        );
        assert_eq!(allocation[1], json!({"vec": []}));
    }
    for participant in &fixture.participants {
        // 未分配算力及被保证金限幅的算力仍完整保留在 PowerStore 中。
        let raw = view(
            &fixture.client,
            "0x1::poc_power_store::get_accounting_snapshot",
            vec![json!(participant.address())],
            version,
        )
        .await;
        assert_eq!(integer(&raw[0]), POOL_UNITS);
        assert_eq!(integer(&raw[1]), POOL_UNITS);
        assert_eq!(integer(&raw[2]), 0);
        assert_eq!(integer(&raw[3]), 61);
    }
    for background in &fixture.pools[3..] {
        assert_position(
            &fixture.client,
            *background,
            target,
            0,
            0,
            U256::ZERO,
            version,
        )
        .await;
    }
    let owner_cap = optional_resource_at_version(
        &fixture.client,
        target,
        "0x1::stake::OwnerCapability",
        version,
    )
    .await
    .unwrap();
    assert_eq!(address(&owner_cap.data["pool_address"]), target);
}

async fn prepare(fixture: &Fixture, native_bps: u64, fee_limit: u64) -> (u64, u64) {
    let target = fixture.target();
    for (index, participant) in fixture.participants.iter().enumerate() {
        let (pools, ratios) = if index == 0 {
            (vec![], vec![])
        } else {
            (vec![target], vec![if index == 1 { 2500 } else { 7500 }])
        };
        let allocation = success(
            execute(
                &fixture.client,
                participant,
                &fixture.factory,
                aptos_stdlib::poc_allocation_set_allocations(pools, ratios),
            )
            .await,
        );
        let version = allocation.info.version.0;
        assert_eq!(
            installed_at(&fixture.client, version - 1).await,
            installed_at(&fixture.client, version).await
        );
        assert_eq!(
            events(&allocation, "::poc_accounting::AllocationScheduled").len(),
            1
        );
    }
    let preparation = success(
        execute(
            &fixture.client,
            &fixture.root,
            &fixture.factory,
            governance_payload(true, fee_limit),
        )
        .await,
    );
    let version = preparation.info.version.0;
    let before = installed_at(&fixture.client, version - 1).await;
    let after = installed_at(&fixture.client, version).await;
    assert_eq!(after.epoch, before.epoch + 1);
    assert_eq!(before.validators.active_validators.len(), 7);
    assert_eq!(after.validators.active_validators.len(), 5);
    assert_eq!(
        after.validators.total_voting_power,
        5 * INSTALLED_POWER as u128
    );
    assert!(after
        .validators
        .active_validators
        .iter()
        .all(|validator| validator.consensus_voting_power() == INSTALLED_POWER));
    assert_eq!(events(&preparation, "::stake::PoCEpochInstalled").len(), 1);
    assert_eq!(before.reward_context.5, 0);
    assert!(
        (REWARD_BASE as u128) * (before.reward_context.2 as u128) < before.reward_context.3 as u128
    );
    assert_eq!(events(&preparation, "::stake::PoCRewardCredited").len(), 7);
    for validator in &before.validators.active_validators {
        let credit = pool_event(
            &preparation,
            "::stake::PoCRewardCredited",
            validator.account_address,
        );
        assert_eq!(integer(&credit.data["closing_epoch"]), before.epoch as u128);
        assert_eq!(
            integer(&credit.data["reward_base_octa"]),
            REWARD_BASE as u128
        );
        assert_eq!(integer(&credit.data["inflation"]), 0);
        assert_eq!(integer(&credit.data["fee"]), 0);
        assert_eq!(wide(&credit.data["delta_index"]), U256::ZERO);
    }
    let (numerator, denominator, raw) = configured_rate();
    assert_eq!(
        after.reward_context,
        (after.epoch, true, numerator, denominator, true, fee_limit)
    );
    assert_eq!(
        integer(&after.reward_split["installed_epoch"]),
        after.epoch as u128
    );
    assert_eq!(
        integer(&after.reward_split["installed_native_reward_bps"]),
        native_bps as u128
    );
    let rewards_config = optional_resource_at_version(
        &fixture.client,
        CORE_CODE_ADDRESS,
        "0x1::staking_config::StakingRewardsConfig",
        version,
    )
    .await
    .unwrap();
    assert_eq!(integer(&rewards_config.data["rewards_rate"]["value"]), raw);
    assert_eq!(
        integer(&rewards_config.data["min_rewards_rate"]["value"]),
        raw
    );
    let features = resource_at_version::<Features>(&fixture.client, version).await;
    assert!(features.is_enabled(FeatureFlag::PERIODICAL_REWARD_RATE_DECREASE));
    assert_allocation_and_cap(fixture, version).await;
    let pool = pool_at(&fixture.client, target, version).await;
    assert_eq!(integer(&pool[3]), 0);
    assert_eq!(wide(&pool[4]), U256::ZERO);
    for stake in stakes_at(&fixture.client, &fixture.pools, version).await {
        assert_eq!(stake, vec![
            json!(BOND.to_string()),
            json!("0"),
            json!("0"),
            json!("0")
        ]);
    }
    let checkpoint = checkpoint_at(&fixture.client, target, after.epoch, version)
        .await
        .unwrap();
    assert_eq!(integer(&checkpoint["refs"]), 3);
    assert_eq!(wide(&checkpoint["index"]), U256::ZERO);
    println!("REW-01 preparation: version={version}, closing_epoch={}, closing_rate={}/{}, installed_epoch={}, installed_rate={numerator}/{denominator}, full_units={POOL_UNITS}, installed_power={INSTALLED_POWER}, reward_base={REWARD_BASE}, owner_checkpoint_refs=3", before.epoch, before.reward_context.2, before.reward_context.3, after.epoch);
    (after.epoch, version)
}

async fn accumulate_income(fixture: &Fixture, epoch: u64, version: u64, fee_limit: u64) {
    let target = fixture.target();
    let (priced_factory, burn_price) =
        priced_fee_factory(&fixture.client, &fixture.factory, version).await;
    let initial = pending_fees_at(&fixture.client, version).await;
    assert!(initial.iter().all(|fee| *fee == 0));
    let control = success(
        execute(
            &fixture.client,
            &fixture.participants[1],
            &fixture.factory,
            aptos_stdlib::topo_coin_transfer(fixture.participants[2].address(), 1000),
        )
        .await,
    );
    let (_, fees, distributable) =
        assert_transfer_fee_block(&fixture.client, &control, burn_price, epoch, fee_limit).await;
    assert_eq!(distributable, 0);
    assert_eq!(fees, initial);

    tokio::time::timeout(Duration::from_secs(90), async {
        let mut fee_filled = false;
        let mut paid_transfers = 0;
        let mut total_distributable = 0u64;
        loop {
            let factory = if fee_filled { &fixture.factory } else { &priced_factory };
            let transfer = success(execute(&fixture.client, &fixture.participants[1], factory,
                aptos_stdlib::topo_coin_transfer(fixture.participants[2].address(), 1000)).await);
            let (version, _, distributable) = assert_transfer_fee_block(&fixture.client,
                &transfer, burn_price, epoch, fee_limit).await;
            if !fee_filled {
                assert!(distributable > fee_limit);
                paid_transfers += 1;
                total_distributable += distributable;
            } else {
                assert_eq!(distributable, 0);
            }
            fee_filled = recorded_fee(&fixture.client, target, version).await == fee_limit;
            let input = performance_input(&fixture.client, target, version).await;
            // 为提交期间可能额外失败的一轮预留余量。
            // 实际结奖交易仍通过独立模型验证通胀恰好为 1 Octa。
            if fee_filled && input.inflation == 1 && input.successes >= 4 * (input.failures + 1) {
                assert!(total_distributable > fee_limit);
                println!("REW-01 income ready: epoch={epoch}, version={version}, fee_limit={fee_limit}, paid_transfers={paid_transfers}, total_distributable={total_distributable}, actual_performance={input:?}");
                break;
            }
        }
    }).await.expect("REW-01 target did not collect its fee cap and one-Octa inflation within 90 seconds");
}

async fn close(
    fixture: &Fixture,
    native_bps: u64,
    fee_limit: u64,
    epoch: u64,
    expected: &Expected,
) -> u64 {
    let closing = success(
        execute(
            &fixture.client,
            &fixture.root,
            &fixture.factory,
            governance_payload(false, fee_limit),
        )
        .await,
    );
    let version = closing.info.version.0;
    let before = installed_at(&fixture.client, version - 1).await;
    let after = installed_at(&fixture.client, version).await;
    assert_eq!(before.epoch, epoch);
    assert_eq!(after.epoch, epoch + 1);
    assert_eq!(after.validators, before.validators);
    let (numerator, denominator, _) = configured_rate();
    assert_eq!(
        before.reward_context,
        (epoch, true, numerator, denominator, true, fee_limit)
    );
    assert_eq!(
        after.reward_context,
        (epoch + 1, true, numerator, denominator, true, fee_limit)
    );
    assert_eq!(
        integer(&before.reward_split["installed_native_reward_bps"]),
        native_bps as u128
    );
    assert_eq!(
        integer(&after.reward_split["installed_native_reward_bps"]),
        native_bps as u128
    );
    assert_eq!(
        integer(&after.reward_split["installed_epoch"]),
        (epoch + 1) as u128
    );
    assert_eq!(events(&closing, "::stake::PoCEpochInstalled").len(), 1);
    assert_eq!(events(&closing, "::stake::PoCRewardCredited").len(), 5);
    assert_eq!(events(&closing, "::stake::PoCRewardSplit").len(), 5);
    for resource in [
        "0x1::stake::EpochPlan",
        "0x1::stake::PrecomputedValidatorSet",
    ] {
        assert!(optional_resource_at_version(
            &fixture.client,
            CORE_CODE_ADDRESS,
            resource,
            version
        )
        .await
        .is_none());
    }
    let stakes_before = stakes_at(&fixture.client, &fixture.pools, version - 1).await;
    let stakes_after = stakes_at(&fixture.client, &fixture.pools, version).await;
    let target = fixture.target();
    // 独立核对每个待结束 Epoch 的成员，避免将背景池的费用和提案计数
    // 在未被察觉的情况下归入选定的目标池。
    for validator in &before.validators.active_validators {
        let pool = validator.account_address;
        let input = performance_input(&fixture.client, pool, version - 1).await;
        assert_eq!(
            (input.numerator, input.denominator),
            (numerator, denominator)
        );
        let fee = recorded_fee(&fixture.client, pool, version - 1).await;
        assert!(fee <= fee_limit);
        let native_inflation = (input.inflation as u128 * native_bps as u128 / 10000) as u64;
        let native_fee = (fee as u128 * native_bps as u128 / 10000) as u64;
        let poc_inflation = input.inflation - native_inflation;
        let poc_fee = fee - native_fee;
        let poc = poc_inflation + poc_fee;
        let credit = pool_event(&closing, "::stake::PoCRewardCredited", pool);
        assert_eq!(integer(&credit.data["closing_epoch"]), epoch as u128);
        assert_eq!(
            integer(&credit.data["reward_base_octa"]),
            REWARD_BASE as u128
        );
        assert_eq!(integer(&credit.data["inflation"]), poc_inflation as u128);
        assert_eq!(integer(&credit.data["fee"]), poc_fee as u128);
        assert_eq!(wide(&credit.data["delta_index"]), reward_index(poc));
        let split = pool_event(&closing, "::stake::PoCRewardSplit", pool);
        assert_eq!(integer(&split.data["closing_epoch"]), epoch as u128);
        assert_eq!(
            integer(&split.data["native_reward_bps"]),
            native_bps as u128
        );
        assert_eq!(
            integer(&split.data["total_inflation_octa"]),
            input.inflation as u128
        );
        assert_eq!(
            integer(&split.data["active_native_reward_octa"]),
            native_inflation as u128
        );
        assert_eq!(
            integer(&split.data["pending_inactive_native_reward_octa"]),
            0
        );
        assert_eq!(
            integer(&split.data["poc_inflation_octa"]),
            poc_inflation as u128
        );
        let native_events = events(&closing, "::stake::DistributeTransactionFee")
            .into_iter()
            .filter(|event| address(&event.data["pool_address"]) == pool)
            .collect::<Vec<_>>();
        assert_eq!(native_events.len(), usize::from(native_fee > 0));
        if native_fee > 0 {
            assert_eq!(
                integer(&native_events[0].data["fee_amount"]),
                native_fee as u128
            );
        }
        let index = fixture
            .pools
            .iter()
            .position(|address| *address == pool)
            .unwrap();
        assert_eq!(stakes_before[index], vec![
            json!(BOND.to_string()),
            json!("0"),
            json!("0"),
            json!("0")
        ]);
        assert_eq!(stakes_after[index], vec![
            json!((BOND + native_inflation + native_fee).to_string()),
            json!("0"),
            json!("0"),
            json!("0")
        ]);
        let before_pool = pool_at(&fixture.client, pool, version - 1).await;
        let after_pool = pool_at(&fixture.client, pool, version).await;
        assert_eq!(integer(&before_pool[0]), POOL_UNITS);
        assert_eq!(integer(&before_pool[3]), 0);
        assert_eq!(wide(&before_pool[4]), U256::ZERO);
        assert_eq!(integer(&after_pool[0]), POOL_UNITS);
        assert_eq!(integer(&after_pool[2]), REWARD_BASE as u128);
        assert_eq!(integer(&after_pool[3]), poc as u128);
        assert_eq!(wide(&after_pool[4]), reward_index(poc));
        assert_eq!(poc + native_inflation + native_fee, input.inflation + fee);
        if pool == target {
            assert_eq!(
                input.inflation, 1,
                "Actual target closing performance: {input:?}"
            );
            assert_eq!(fee, fee_limit);
            assert_eq!(
                (native_inflation + native_fee, poc),
                (expected.native, expected.poc)
            );
            assert_eq!(wide(&after_pool[4]), expected.delta);
            println!("REW-01 target credit: closing_epoch={epoch}, version={version}, performance={input:?}, fee={fee}, native={}, poc={}, delta={:?}, claims={:?}, fractions={:?}", expected.native, expected.poc, expected.delta, expected.claims, expected.remainders);
        }
    }
    // 两个原所有者池均无已安装权重，不获得新增奖励。
    for (index, pool) in fixture.pools.iter().enumerate().take(3).skip(1) {
        assert_eq!(stakes_after[index], stakes_before[index]);
        assert_eq!(
            pool_at(&fixture.client, *pool, version).await,
            pool_at(&fixture.client, *pool, version - 1).await
        );
    }
    assert!(events(&closing, "::stake::DistributeRewards").is_empty());
    assert_position(&fixture.client, target, target, 0, 0, U256::ZERO, version).await;
    for (index, participant) in fixture.participants[1..].iter().enumerate() {
        assert_position(
            &fixture.client,
            participant.address(),
            target,
            POSITION_UNITS[index],
            expected.claims[index],
            expected.remainders[index],
            version,
        )
        .await;
    }
    version
}

async fn claim(fixture: &Fixture, participant: usize, amount: u64) -> u64 {
    let target = fixture.target();
    let owner = &fixture.participants[participant];
    let transaction = success(
        execute(
            &fixture.client,
            owner,
            &fixture.factory,
            aptos_stdlib::poc_allocation_claim_rewards(vec![target]),
        )
        .await,
    );
    let version = transaction.info.version.0;
    let claims = events(&transaction, "::poc_accounting::PoCRewardClaimed");
    assert_eq!(claims.len(), usize::from(amount > 0));
    if amount > 0 {
        assert_eq!(address(&claims[0].data["user"]), owner.address());
        assert_eq!(address(&claims[0].data["pool"]), target);
        assert_eq!(integer(&claims[0].data["amount"]), amount as u128);
    }
    assert_payment(&fixture.client, &transaction, amount).await;
    assert_eq!(
        installed_at(&fixture.client, version - 1).await,
        installed_at(&fixture.client, version).await
    );
    assert_eq!(
        stakes_at(&fixture.client, &fixture.pools, version - 1).await,
        stakes_at(&fixture.client, &fixture.pools, version).await,
        "PoC payment changed native ownership or compounded native stake"
    );
    let before = pool_at(&fixture.client, target, version - 1).await;
    let after = pool_at(&fixture.client, target, version).await;
    assert_eq!(integer(&before[3]) - integer(&after[3]), amount as u128);
    assert_eq!(before[4], after[4]);
    version
}

async fn snapshot(fixture: &Fixture, client: &Client, version: u64) -> Vec<Value> {
    let target = fixture.target();
    let mut state = vec![
        json!(pool_at(client, target, version).await),
        ledger_at(client, target, version).await,
        json!(stakes_at(client, &fixture.pools, version).await),
    ];
    for participant in &fixture.participants {
        state.push(json!(
            position_at(client, participant.address(), target, version).await
        ));
        state.push(json!(
            view(
                client,
                "0x1::poc_accounting::get_allocations",
                vec![json!(participant.address())],
                version
            )
            .await
        ));
        state.push(json!(
            view(
                client,
                "0x1::poc_power_store::get_accounting_snapshot",
                vec![json!(participant.address())],
                version
            )
            .await
        ));
        state.push(
            optional_resource_at_version(
                client,
                participant.address(),
                "0x1::stake::OwnerCapability",
                version,
            )
            .await
            .unwrap()
            .data,
        );
    }
    state
}

async fn run(native_bps: u64, fee_limit: u64) {
    let fixture = fixture(native_bps, fee_limit).await;
    let target = fixture.target();
    let expected = Expected::new(native_bps, fee_limit);
    let (epoch, version) = prepare(&fixture, native_bps, fee_limit).await;
    accumulate_income(&fixture, epoch, version, fee_limit).await;
    let closing_version = close(&fixture, native_bps, fee_limit, epoch, &expected).await;
    assert_eq!(
        integer(
            &checkpoint_at(&fixture.client, target, epoch, closing_version)
                .await
                .unwrap()["refs"]
        ),
        3
    );

    // owner 保留原生奖励，但在自己的池中没有算力持仓。
    // 首次零额领取仍会释放已经成熟的旧持仓引用。
    let owner_version = claim(&fixture, 0, 0).await;
    assert_eq!(
        integer(
            &checkpoint_at(&fixture.client, target, epoch, owner_version)
                .await
                .unwrap()["refs"]
        ),
        2
    );
    let owner_repeat = claim(&fixture, 0, 0).await;
    assert_eq!(
        integer(
            &checkpoint_at(&fixture.client, target, epoch, owner_repeat)
                .await
                .unwrap()["refs"]
        ),
        2
    );
    let native_owner_stake = view(
        &fixture.client,
        "0x1::stake::get_stake",
        vec![json!(target)],
        owner_repeat,
    )
    .await;
    assert_eq!(
        integer(&native_owner_stake[0]),
        (BOND + expected.native) as u128
    );
    assert_position(
        &fixture.client,
        target,
        target,
        0,
        0,
        U256::ZERO,
        owner_repeat,
    )
    .await;
    let mut final_version = owner_repeat;
    for (index, units) in POSITION_UNITS.iter().copied().enumerate() {
        let paid = claim(&fixture, index + 1, expected.claims[index]).await;
        assert_position(
            &fixture.client,
            fixture.participants[index + 1].address(),
            target,
            units,
            0,
            expected.remainders[index],
            paid,
        )
        .await;
        let checkpoint = checkpoint_at(&fixture.client, target, epoch, paid).await;
        if index == 0 {
            assert_eq!(integer(&checkpoint.unwrap()["refs"]), 1);
        } else {
            assert!(checkpoint.is_none());
        }
        final_version = claim(&fixture, index + 1, 0).await;
        assert_position(
            &fixture.client,
            fixture.participants[index + 1].address(),
            target,
            units,
            0,
            expected.remainders[index],
            final_version,
        )
        .await;
    }
    let vault = expected.poc - expected.claims.iter().sum::<u64>();
    assert_eq!(vault, u64::from(native_bps == 3000 && fee_limit == 39));
    let pool = pool_at(&fixture.client, target, final_version).await;
    assert_eq!(integer(&pool[0]), POOL_UNITS);
    assert_eq!(integer(&pool[3]), vault as u128);
    assert_eq!(wide(&pool[4]), expected.delta);
    let installed = installed_at(&fixture.client, final_version).await;
    let reference = snapshot(&fixture, &fixture.client, final_version).await;
    for validator in &installed.validators.active_validators {
        let client = fixture
            .swarm
            .validator(validator.account_address)
            .unwrap()
            .rest_client();
        tokio::time::timeout(
            Duration::from_secs(30),
            client.wait_for_version(final_version),
        )
        .await
        .expect("REW-01 same-version catchup exceeded 30 seconds")
        .unwrap();
        assert_eq!(installed_at(&client, final_version).await, installed);
        assert_eq!(snapshot(&fixture, &client, final_version).await, reference);
        assert!(checkpoint_at(&client, target, epoch, final_version)
            .await
            .is_none());
    }
    println!("REW-01 completed: native_bps={native_bps}, inflation=1, fee={fee_limit}, installed_power={INSTALLED_POWER}, reward_base={REWARD_BASE}, owner_native={}, owner_poc=0, user_claims={:?}, vault={vault}, final_version={final_version}", expected.native, expected.claims);
}

#[tokio::test]
async fn poc_bond_capped_zero_native_one_inflation_and_39_fee() {
    run(0, 39).await;
}

#[tokio::test]
async fn poc_bond_capped_default_native_one_inflation_and_39_fee() {
    run(3000, 39).await;
}

#[tokio::test]
async fn poc_bond_capped_default_native_one_inflation_and_27_fee() {
    run(3000, 27).await;
}
