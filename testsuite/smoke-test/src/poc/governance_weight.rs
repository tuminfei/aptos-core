// Copyright (c) Aptos Foundation
// Licensed pursuant to the Innovation-Enabling Source Code License, available at https://github.com/aptos-labs/aptos-core/blob/main/LICENSE

//! GOV-03：在 PoC 原生分流为零值和默认值时验证原生治理余额。

use super::{
    defaults::installed_at,
    fee_rewards::{
        assert_payment, events, integer, pool_at, pool_event, position_at, success, view, wide,
    },
    optional_resource_at_version,
    transactions::{compile_script, execute},
};
use crate::smoke_test_environment::SwarmBuilder;
use aptos_api_types::UserTransaction;
use aptos_cached_packages::aptos_stdlib;
use aptos_forge::{LocalSwarm, NodeExt, Swarm};
use aptos_genesis::poc::{DeploymentMode, PocGenesisConfiguration, PowerParams};
use aptos_rest_client::Client;
use aptos_sdk::{transaction_builder::TransactionFactory, types::LocalAccount};
use aptos_types::{
    account_address::AccountAddress,
    account_config::CORE_CODE_ADDRESS,
    on_chain_config::{OnChainChunkyDKGConfig, OnChainRandomnessConfig},
    transaction::{Script, TransactionArgument, TransactionPayload},
};
use move_core_types::int256::U256;
use once_cell::sync::Lazy;
use serde_json::{json, Value};
use std::{sync::Arc, time::Duration};

const POWER: u64 = 10;
const BASE: u64 = 100;
const UNITS: u128 = (POWER as u128) << 16;

static GOVERNANCE: Lazy<Vec<u8>> = Lazy::new(|| {
    compile_script(
        "PoCGovernanceNativeWeight",
        r#"script {
            use topo_std::fixed_point64;
            use topo_framework::reconfiguration;
            use topo_framework::stake;
            use topo_framework::staking_config;
            use topo_framework::topo_governance;
            fun main(root: &signer, configure: bool, bps: u64) {
                let framework = topo_governance::get_signer_testnet_only(root, @0x1);
                if (configure) {
                    let rate = fixed_point64::create_from_rational(1, 1);
                    staking_config::update_rewards_config(&framework, rate, rate,
                        31536000, fixed_point64::create_from_rational(0, 1));
                };
                stake::schedule_reward_split(&framework, bps, reconfiguration::current_epoch() + 1);
                topo_governance::reconfigure(&framework);
            }
        }"#,
    )
});

fn governance(configure: bool, bps: u64) -> TransactionPayload {
    TransactionPayload::Script(Script::new(GOVERNANCE.clone(), vec![], vec![
        TransactionArgument::Bool(configure),
        TransactionArgument::U64(bps),
    ]))
}

struct Fixture {
    swarm: LocalSwarm,
    client: Client,
    root: Arc<LocalAccount>,
    owner: LocalAccount,
    factory: TransactionFactory,
    pools: Vec<AccountAddress>,
}

#[derive(Default)]
struct Model {
    index: U256,
    credited: u64,
}

async fn fixture(controlled: bool) -> Fixture {
    Lazy::force(&GOVERNANCE);
    println!("GOV-03 fixture A: nodes=4, controlled={controlled}, allow_new_validators={}, bond=100 Octa, initial_power=10, ratio=10 TOPO/OHMP, min_power=10, min_validators=4, capacity=5, retention=10000, native_bps=0 then 3000, fee_limit=0, epoch=3600s, ordinary/Chunky DKG=off; rate=1/1 installed by public governance, gas_price=1", !controlled);
    let swarm = SwarmBuilder::new_local(4)
        .with_aptos()
        .with_init_genesis_stake(Arc::new(|_, amount| *amount = BASE))
        .with_init_genesis_config(Arc::new(move |config| {
            config.is_test = true;
            config.allow_new_validators = !controlled;
            config.epoch_duration_secs = 3600;
            config.min_stake = 1;
            config.max_stake = 10000;
            config.voting_power_increase_limit = 25;
            config.randomness_config_override = Some(OnChainRandomnessConfig::Off);
            config.chunky_dkg_config_override = Some(OnChainChunkyDKGConfig::default_disabled());
            config.poc_genesis_config = Some(Arc::new(move |_| PocGenesisConfiguration {
                params: PowerParams {
                    bond_octa_per_ohmp: 1_000_000_000,
                    min_power: POWER,
                    max_power: 100,
                    min_validators: 4,
                },

                deployment_mode: if controlled {
                    DeploymentMode::Controlled
                } else {
                    DeploymentMode::Open
                },
                retention_bps: 10000,
                initial_raw_power: POWER,
            }));
        }))
        .build()
        .await;
    super::configure_fixture(&swarm, [4, 4, 32, 5, 0], 0).await;
    let client = swarm.validators().next().unwrap().rest_client();
    let root = swarm.chain_info().root_account();
    let factory = swarm
        .chain_info()
        .transaction_factory()
        .with_gas_unit_price(1)
        .with_max_gas_amount(2_000_000)
        .with_transaction_expiration_time(120);
    let mut pools = swarm.validators().map(|v| v.peer_id()).collect::<Vec<_>>();
    pools.sort();
    let pool = pools[0];
    swarm
        .chain_info()
        .into_aptos_public_info()
        .mint(pool, 1_000_000_000)
        .await
        .unwrap();
    let key = swarm
        .validator(pool)
        .unwrap()
        .account_private_key()
        .as_ref()
        .unwrap()
        .private_key();
    let sequence = client
        .get_account(pool)
        .await
        .unwrap()
        .into_inner()
        .sequence_number;
    Fixture {
        swarm,
        client,
        root,
        owner: LocalAccount::new(pool, key, sequence),
        factory,
        pools,
    }
}

async fn weights(client: &Client, pool: AccountAddress, version: u64) -> (u64, u64) {
    let consensus = view(
        client,
        "0x1::stake::get_current_epoch_voting_power",
        vec![json!(pool)],
        version,
    )
    .await;
    let governance = view(
        client,
        "0x1::topo_governance::get_voting_power",
        vec![json!(pool)],
        version,
    )
    .await;
    (
        integer(&consensus[0]) as u64,
        integer(&governance[0]) as u64,
    )
}

async fn balances(client: &Client, pool: AccountAddress, version: u64) -> [u64; 4] {
    let result = view(client, "0x1::stake::get_stake", vec![json!(pool)], version).await;
    std::array::from_fn(|i| integer(&result[i]) as u64)
}

async fn wait_for_proposals(f: &Fixture) {
    tokio::time::timeout(Duration::from_secs(30), async {
        loop {
            let version = f
                .client
                .get_ledger_information()
                .await
                .unwrap()
                .into_inner()
                .version;
            let installed = installed_at(&f.client, version).await;
            let validator = installed
                .validators
                .active_validators
                .iter()
                .find(|v| v.account_address == f.owner.address())
                .unwrap();
            let counts = view(
                &f.client,
                "0x1::stake::get_current_epoch_proposal_counts",
                vec![json!(validator.config().validator_index.to_string())],
                version,
            )
            .await;
            if integer(&counts[0]) >= 4 * (integer(&counts[1]) + 1) {
                break;
            }
            tokio::time::sleep(Duration::from_millis(200)).await;
        }
    })
    .await
    .expect("GOV-03 target did not produce enough proposals within 30 seconds");
}

/// 由目标版本的直接前序版本提供真实提案计数和已安装上下文。
/// 金额预期不来自任何 PoC 预览、分流或领取查询。
async fn assert_settlement(f: &Fixture, tx: &UserTransaction, new_bps: u64, model: &mut Model) {
    let version = tx.info.version.0;
    let before = installed_at(&f.client, version - 1).await;
    let after = installed_at(&f.client, version).await;
    assert_eq!(after.epoch, before.epoch + 1);
    assert_eq!(after.validators, before.validators);
    assert_eq!(after.validators.total_voting_power, 4 * u128::from(POWER));
    assert_eq!(
        integer(&after.reward_split["installed_native_reward_bps"]),
        new_bps as u128
    );
    assert_eq!(after.reward_split["pending_change"], json!({"vec": []}));
    assert_eq!(after.reward_context.5, 0);
    let old_bps = integer(&before.reward_split["installed_native_reward_bps"]);
    assert_eq!(events(tx, "::PoCRewardSplit").len(), 4);
    assert_eq!(events(tx, "::PoCRewardCredited").len(), 4);
    assert_eq!(events(tx, "::PoCEpochInstalled").len(), 1);
    for pool in &f.pools {
        let validator = before
            .validators
            .active_validators
            .iter()
            .find(|v| v.account_address == *pool)
            .unwrap();
        let counts = view(
            &f.client,
            "0x1::stake::get_current_epoch_proposal_counts",
            vec![json!(validator.config().validator_index.to_string())],
            version - 1,
        )
        .await;
        let (successful, failed) = (integer(&counts[0]), integer(&counts[1]));
        let inflation = if successful + failed == 0 {
            0
        } else {
            BASE as u128 * successful * before.reward_context.2 as u128
                / ((successful + failed) * before.reward_context.3 as u128)
        };
        let native = (inflation * old_bps / 10000) as u64;
        let poc = inflation as u64 - native;
        let old_stake = balances(&f.client, *pool, version - 1).await;
        let new_stake = balances(&f.client, *pool, version).await;
        let [active, inactive, pending_active, pending_inactive] = old_stake;
        let native_inactive = (native as u128 * pending_inactive as u128
            / (active as u128 + pending_inactive as u128)) as u64;
        let native_active = native - native_inactive;
        // 这些创世锁仓在整个测试期间都有效。pending_active 在旧期结奖后加入，
        // pending_inactive 仍保留旧期份额。
        let stake =
            optional_resource_at_version(&f.client, *pool, "0x1::stake::StakePool", version - 1)
                .await
                .unwrap()
                .data;
        let timestamp = optional_resource_at_version(
            &f.client,
            CORE_CODE_ADDRESS,
            "0x1::timestamp::CurrentTimeMicroseconds",
            version - 1,
        )
        .await
        .unwrap()
        .data;
        assert!(
            integer(&stake["locked_until_secs"]) > integer(&timestamp["microseconds"]) / 1_000_000
        );
        assert_eq!(new_stake, [
            active + pending_active + native_active,
            inactive,
            0,
            pending_inactive + native_inactive
        ]);
        assert_eq!(
            weights(&f.client, *pool, version - 1).await,
            (POWER, active + pending_active + pending_inactive)
        );
        assert_eq!(
            weights(&f.client, *pool, version).await,
            (POWER, active + pending_active + pending_inactive + native)
        );
        let old_pool = pool_at(&f.client, *pool, version - 1).await;
        let new_pool = pool_at(&f.client, *pool, version).await;
        assert_eq!(integer(&old_pool[0]), UNITS);
        assert_eq!(new_pool[0], old_pool[0]);
        assert_eq!(integer(&old_pool[2]), BASE as u128);
        assert_eq!(new_pool[2], old_pool[2]);
        assert_eq!(integer(&new_pool[3]) - integer(&old_pool[3]), poc as u128);
        let delta = (U256::from(poc).repr() << 128u32) / U256::from(UNITS).repr();
        assert_eq!(wide(&new_pool[4]).repr() - wide(&old_pool[4]).repr(), delta);
        assert_eq!(
            pool_event(tx, "::PoCRewardSplit", *pool).data,
            json!({
                "pool": pool.to_hex_literal(), "closing_epoch": before.epoch.to_string(),
                "native_reward_bps": old_bps.to_string(), "total_inflation_octa": inflation.to_string(),
                "active_native_reward_octa": native_active.to_string(),
                "pending_inactive_native_reward_octa": native_inactive.to_string(),
                "poc_inflation_octa": poc.to_string()
            })
        );
        assert_eq!(
            pool_event(tx, "::PoCRewardCredited", *pool).data,
            json!({
                "pool": pool.to_hex_literal(), "closing_epoch": before.epoch.to_string(),
                "reward_base_octa": BASE.to_string(), "inflation": poc.to_string(), "fee": "0",
                "delta_index": delta.to_string()
            })
        );
        if *pool == f.owner.address() {
            assert_eq!(wide(&old_pool[4]), model.index);
            assert_eq!(integer(&old_pool[3]), model.credited as u128);
            model.index = U256::checked_add(model.index, delta.into()).unwrap();
            model.credited += poc;
            assert_eq!(wide(&new_pool[4]), model.index);
            assert_eq!(integer(&new_pool[3]), model.credited as u128);
        }
        if old_bps == 3000 && *pool == f.owner.address() {
            assert!(
                native > 0,
                "Positive native compounding must actually be exercised"
            );
        }
        println!("GOV-03 version={version}, pool={pool}, epoch={}, native_bps={old_bps}, inflation={inflation}, native={native}, poc={poc}, stake={old_stake:?}->{new_stake:?}, consensus_power={POWER}", before.epoch);
    }
}

async fn close(f: &Fixture, configure: bool, bps: u64, model: &mut Model) -> u64 {
    let tx = success(execute(&f.client, &f.root, &f.factory, governance(configure, bps)).await);
    assert_settlement(f, &tx, bps, model).await;
    tx.info.version.0
}

async fn snapshot(f: &Fixture, client: &Client, version: u64) -> Vec<Value> {
    let mut result = Vec::new();
    for pool in &f.pools {
        result.push(
            json!({"pool": pool, "weights": weights(client, *pool, version).await,
            "stake": balances(client, *pool, version).await,
            "ledger": pool_at(client, *pool, version).await,
            "position": position_at(client, *pool, *pool, version).await}),
        );
    }
    result
}

async fn run(controlled: bool) {
    let f = fixture(controlled).await;
    let owner = f.owner.address();
    let mut model = Model::default();
    let config = optional_resource_at_version(
        &f.client,
        CORE_CODE_ADDRESS,
        "0x1::staking_config::StakingConfig",
        0,
    )
    .await
    .unwrap()
    .data;
    assert_eq!(config["allow_validator_set_change"], json!(!controlled));
    let accounting = optional_resource_at_version(
        &f.client,
        CORE_CODE_ADDRESS,
        "0x1::poc_accounting::AccountingState",
        0,
    )
    .await
    .unwrap()
    .data;
    assert_eq!(
        accounting["config"]["deployment_mode"],
        json!(u8::from(!controlled))
    );
    assert_eq!(weights(&f.client, owner, 0).await, (POWER, BASE));
    close(&f, true, 0, &mut model).await;
    let add = success(
        execute(
            &f.client,
            &f.owner,
            &f.factory,
            aptos_stdlib::stake_add_stake(17),
        )
        .await,
    );
    assert_eq!(balances(&f.client, owner, add.info.version.0).await, [
        100, 0, 17, 0
    ]);
    assert_eq!(
        weights(&f.client, owner, add.info.version.0).await,
        (POWER, 117)
    );
    let unlock = success(
        execute(
            &f.client,
            &f.owner,
            &f.factory,
            aptos_stdlib::stake_unlock(13),
        )
        .await,
    );
    assert_eq!(balances(&f.client, owner, unlock.info.version.0).await, [
        87, 0, 17, 13
    ]);
    assert_eq!(
        weights(&f.client, owner, unlock.info.version.0).await,
        (POWER, 117)
    );
    wait_for_proposals(&f).await;
    close(&f, false, 0, &mut model).await;
    wait_for_proposals(&f).await;
    close(&f, false, 3000, &mut model).await; // 结束当期仍按原生占比 0 结算。
    let add = success(
        execute(
            &f.client,
            &f.owner,
            &f.factory,
            aptos_stdlib::stake_add_stake(17),
        )
        .await,
    );
    assert_eq!(balances(&f.client, owner, add.info.version.0).await, [
        104, 0, 17, 13
    ]);
    assert_eq!(
        weights(&f.client, owner, add.info.version.0).await,
        (POWER, 134)
    );
    wait_for_proposals(&f).await;
    let version = close(&f, false, 3000, &mut model).await;
    let native = balances(&f.client, owner, version).await;
    assert!(native[0] + native[3] > 134);
    let installed = installed_at(&f.client, version).await;
    assert_eq!(installed.reward_context.2, installed.reward_context.3);

    // 未变化的全额分配从零指数开始。整数领取额取自独立累积的模型指数，
    // 而非领取查询；同时验证花费 PoC 奖励不会改变治理权重。
    let ledger = pool_at(&f.client, owner, version).await;
    let accrued = U256::from(UNITS).repr() * model.index.repr();
    let amount: u64 = (accrued >> 128u32).try_into().unwrap();
    assert!(amount > 0);
    let claimed = success(
        execute(
            &f.client,
            &f.owner,
            &f.factory,
            aptos_stdlib::poc_allocation_claim_rewards(vec![owner]),
        )
        .await,
    );
    assert_payment(&f.client, &claimed, amount).await;
    let claim_events = events(&claimed, "::poc_accounting::PoCRewardClaimed");
    assert_eq!(claim_events.len(), 1);
    assert_eq!(
        claim_events[0].data,
        json!({"user": owner.to_hex_literal(),
        "pool": owner.to_hex_literal(), "amount": amount.to_string()})
    );
    let claimed_version = claimed.info.version.0;
    assert_eq!(
        weights(&f.client, owner, claimed_version).await,
        weights(&f.client, owner, claimed_version - 1).await
    );
    assert_eq!(balances(&f.client, owner, claimed_version).await, native);
    let claimed_ledger = pool_at(&f.client, owner, claimed_version).await;
    assert_eq!(wide(&claimed_ledger[4]), model.index);
    assert_eq!(
        integer(&ledger[3]) - integer(&claimed_ledger[3]),
        amount as u128
    );
    let position = position_at(&f.client, owner, owner, claimed_version).await;
    assert_eq!(integer(&position[2]), 0);
    assert_eq!(
        wide(&position[3]).repr(),
        accrued % (U256::ONE.repr() << 128u32)
    );
    let expected = snapshot(&f, &f.client, claimed_version).await;
    for node in f.swarm.validators() {
        let client = node.rest_client();
        tokio::time::timeout(
            Duration::from_secs(30),
            client.wait_for_version(claimed_version),
        )
        .await
        .expect("GOV-03 same-version catchup exceeded 30 seconds")
        .unwrap();
        assert_eq!(installed_at(&client, claimed_version).await, installed);
        assert_eq!(snapshot(&f, &client, claimed_version).await, expected);
    }
}

#[tokio::test]
async fn poc_open_governance_keeps_native_weight_after_compounding() {
    run(false).await;
}

#[tokio::test]
async fn poc_controlled_governance_keeps_native_weight_after_compounding() {
    run(true).await;
}
