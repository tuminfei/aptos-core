// Copyright (c) Aptos Foundation
// Licensed pursuant to the Innovation-Enabling Source Code License, available at https://github.com/aptos-labs/aptos-core/blob/main/LICENSE

//! 通过公开治理交易覆盖 GOV-04 及旧 Epoch 奖励归属。

use super::{
    defaults::installed_at,
    fee_rewards::{assert_transfer_fee_block, pending_fees_at, priced_fee_factory},
    optional_resource_at_version, resource_at_version,
    transactions::{assert_abort, compile_script, execute},
};
use crate::smoke_test_environment::SwarmBuilder;
use aptos_api_types::{Event, UserTransaction, ViewRequest};
use aptos_cached_packages::aptos_stdlib;
use aptos_forge::{LocalSwarm, NodeExt, Swarm, SwarmExt};
use aptos_genesis::poc::PocGenesisConfiguration;
use aptos_rest_client::Client;
use aptos_sdk::{transaction_builder::TransactionFactory, types::LocalAccount};
use aptos_types::{
    account_address::AccountAddress,
    account_config::CORE_CODE_ADDRESS,
    dkg::DKGState,
    on_chain_config::{OnChainChunkyDKGConfig, OnChainRandomnessConfig, ValidatorSet},
    transaction::{Script, TransactionArgument, TransactionPayload},
};
use move_core_types::int256::U256;
use once_cell::sync::Lazy;
use serde_json::{json, Value};
use std::{collections::BTreeMap, sync::Arc, time::Duration};

const POWER: u64 = 100_000_000;
const SPLIT: &str = "0x1::poc_reward_split::RewardSplitConfig";
const DKG_FAILPOINT: &str = "dkg::process_dkg_start_event";
const OLD_FEE_LIMIT: u64 = 39;
const NEW_FEE_LIMIT: u64 = 17;
const NEW_BOND_RATIO: u64 = 50_000_000;
const NEW_NATIVE_BPS: u64 = 6000;

static GOVERNANCE: Lazy<Vec<u8>> = Lazy::new(|| {
    compile_script(
        "PoCRewardSplitLifecycle",
        r#"
script {
    use topo_framework::stake;
    use topo_framework::topo_governance;

    fun main(root: &signer, operation: u8, bps: u64, epoch: u64) {
        let framework = topo_governance::get_signer_testnet_only(root, @0x1);
        if (operation == 0) {
            stake::schedule_reward_split(&framework, bps, epoch);
        } else if (operation == 1) {
            stake::cancel_pending_reward_split(&framework);
        } else {
            assert!(operation == 2, 0);
            topo_governance::reconfigure(&framework);
        };
    }
}
"#,
    )
});

// 在真实 VM 交易中隔离验证包括 u64::MAX 在内的算术边界。
// 极限值仅作为函数参数，不会向账户或金库注入极端金额。
static ARITHMETIC: Lazy<Vec<u8>> = Lazy::new(|| {
    let mut source =
        String::from("script { use topo_framework::poc_reward_split; fun main(_sender: &signer) {");
    for amount in [0u64, 1, 2, 10, 17, u64::MAX] {
        for bps in [0u64, 3000, 3500, 9999, 10000] {
            let native = (u128::from(amount) * u128::from(bps) / 10000) as u64;
            let poc = amount - native;
            source.push_str(&format!(
                "\n{{ let (native_part, poc_part) = poc_reward_split::split_reward({amount}, {bps}); assert!(native_part == {native} && poc_part == {poc}, 0xface); }};",
            ));
        }
    }
    source.push_str("} }");
    compile_script("PoCRewardSplitArithmeticMatrix", &source)
});

static CONTEXT_GOVERNANCE: Lazy<Vec<u8>> = Lazy::new(|| {
    compile_script(
        "PoCRewardContextLifecycle",
        r#"
script {
    use std::features;
    use topo_std::fixed_point64;
    use topo_framework::block;
    use topo_framework::poc_accounting;
    use topo_framework::poc_allocation;
    use topo_framework::reconfiguration;
    use topo_framework::stake;
    use topo_framework::staking_config;
    use topo_framework::topo_governance;

    fun main(root: &signer, operation: u8) {
        let framework = topo_governance::get_signer_testnet_only(root, @0x1);
        if (operation == 0) {
            // 先安装正费用限额，使下一 Epoch 在 DKG 等待期间能够记录真实费用。
            stake::set_transaction_fee_limit_per_epoch_per_pool(&framework, 39);
            topo_governance::force_end_epoch(&framework);
        } else if (operation == 1) {
            let target = reconfiguration::current_epoch() + 1;
            // 冻结前一次性排定目标期参数；待结束 Epoch 必须继续使用旧快照。
            block::update_epoch_interval_microsecs(&framework, 3600000000);
            poc_allocation::schedule_power_params(&framework,
                poc_accounting::new_power_params(50000000, 1, 100000000000, 2), target);
            let rate = fixed_point64::create_from_rational(1, 200);
            let zero = fixed_point64::create_from_rational(0, 1);
            if (features::periodical_reward_rate_decrease_enabled()) {
                staking_config::update_rewards_config(&framework, rate, rate, 31536000, zero);
            } else {
                staking_config::update_rewards_rate(&framework, 1, 200);
            };
            stake::set_transaction_fee_limit_per_epoch_per_pool(&framework, 17);
            stake::schedule_reward_split(&framework, 6000, target);
            topo_governance::reconfigure(&framework);
        } else {
            assert!(operation == 2, 0);
            topo_governance::force_end_epoch(&framework);
        };
    }
}
"#,
    )
});

fn context_payload(operation: u8) -> TransactionPayload {
    TransactionPayload::Script(Script::new(CONTEXT_GOVERNANCE.clone(), vec![], vec![
        TransactionArgument::U8(operation),
    ]))
}

fn payload(operation: u8, bps: u64, epoch: u64) -> TransactionPayload {
    TransactionPayload::Script(Script::new(GOVERNANCE.clone(), vec![], vec![
        TransactionArgument::U8(operation),
        TransactionArgument::U64(bps),
        TransactionArgument::U64(epoch),
    ]))
}

async fn swarm() -> LocalSwarm {
    println!("GOV-04 reward fixture: 4 validators, Controlled testnet PoC parameters, 1 TOPO/pool, retention=10000, native_bps=5000, epoch=3600s, ordinary/Chunky DKG=off, fee_limit=0; not strict T2");
    SwarmBuilder::new_local(4)
        .with_aptos()
        .with_init_genesis_stake(Arc::new(|_, stake| *stake = POWER))
        .with_init_genesis_config(Arc::new(|config| {
            config.is_test = true;
            config.allow_new_validators = true;
            config.epoch_duration_secs = 3600;
            config.min_stake = 0;
            config.max_stake = 100_000_000_000_000;
            config.voting_power_increase_limit = 50;
            config.randomness_config_override = Some(OnChainRandomnessConfig::Off);
            config.chunky_dkg_config_override = Some(OnChainChunkyDKGConfig::default_disabled());
            config.poc_genesis_config = Some(Arc::new(|_| {
                let mut poc = PocGenesisConfiguration::testnet();
                poc.retention_bps = 10000;
                poc
            }));
        }))
        .build()
        .await
}

fn number(value: &Value) -> u64 {
    value.as_str().unwrap().parse().unwrap()
}

fn address(value: &Value) -> AccountAddress {
    AccountAddress::from_hex_literal(value.as_str().unwrap()).unwrap()
}

async fn resource(client: &Client, name: &str, version: u64) -> Value {
    optional_resource_at_version(client, CORE_CODE_ADDRESS, name, version)
        .await
        .unwrap_or_else(|| panic!("Missing {name} at version {version}"))
        .data
}

async fn view(client: &Client, name: &str, pool: AccountAddress, version: u64) -> Vec<Value> {
    client
        .view(
            &ViewRequest {
                function: name.parse().unwrap(),
                type_arguments: vec![],
                arguments: vec![json!(pool)],
            },
            Some(version),
        )
        .await
        .unwrap()
        .into_inner()
}

async fn state(client: &Client, pools: &[AccountAddress], version: u64) -> BTreeMap<String, Value> {
    let mut state = BTreeMap::new();
    for name in [
        SPLIT,
        "0x1::stake::InstalledRewardContext",
        "0x1::stake::ValidatorSet",
        "0x1::poc_accounting::AccountingState",
        "0x1::poc_power_store::PowerStore",
        "0x1::poc_power_store::PeriodClock",
        "0x1::reconfiguration::Configuration",
    ] {
        state.insert(name.to_owned(), resource(client, name, version).await);
    }
    for pool in pools {
        for name in ["0x1::poc_accounting::get_pool", "0x1::stake::get_stake"] {
            state.insert(
                format!("{name}:{pool}"),
                json!(view(client, name, *pool, version).await),
            );
        }
    }
    state
}

fn events<'a>(transaction: &'a UserTransaction, suffix: &str) -> Vec<&'a Event> {
    transaction
        .events
        .iter()
        .filter(|event| event.typ.to_string().ends_with(suffix))
        .collect()
}

async fn change(
    client: &Client,
    root: &LocalAccount,
    factory: &TransactionFactory,
    pools: &[AccountAddress],
    pending: Option<(u64, u64)>,
) {
    let (operation, bps, epoch) = pending.map_or((1, 0, 0), |(bps, epoch)| (0, bps, epoch));
    let transaction = execute(client, root, factory, payload(operation, bps, epoch)).await;
    assert!(transaction.info.success, "{}", transaction.info.vm_status);
    let version = transaction.info.version.0;
    let mut expected = state(client, pools, version - 1).await;
    let old_pending = expected[SPLIT]["pending_change"]["vec"].clone();
    expected.get_mut(SPLIT).unwrap()["pending_change"] = match pending {
        Some((bps, epoch)) => {
            json!({"vec": [{"native_reward_bps": bps.to_string(), "activation_epoch": epoch.to_string()}]})
        },
        None => json!({"vec": []}),
    };
    assert_eq!(state(client, pools, version).await, expected);
    let split_events = transaction
        .events
        .iter()
        .filter(|event| event.typ.to_string().contains("::poc_reward_split::"))
        .collect::<Vec<_>>();
    assert_eq!(split_events.len(), 1);
    let (suffix, data) = match pending {
        Some((bps, epoch)) => (
            "::RewardSplitScheduled",
            json!({"native_reward_bps": bps.to_string(), "activation_epoch": epoch.to_string()}),
        ),
        None => ("::RewardSplitCancelled", old_pending[0].clone()),
    };
    assert!(split_events[0].typ.to_string().ends_with(suffix));
    assert_eq!(split_events[0].data, data);
    assert!(events(&transaction, "::PoCEpochInstalled").is_empty());
    assert!(events(&transaction, "::PoCRewardCredited").is_empty());
}

/// 根据 v-1 的已安装奖励率和真实提案计数计算每个旧 Epoch 的通胀。
/// 预期金额不由奖励预览或领取函数提供。
async fn install(
    client: &Client,
    root: &LocalAccount,
    factory: &TransactionFactory,
    old_epoch: u64,
    old_bps: u64,
    new_bps: u64,
    pending: Option<(u64, u64)>,
) -> UserTransaction {
    let transaction = execute(client, root, factory, payload(2, 0, 0)).await;
    assert!(transaction.info.success, "{}", transaction.info.vm_status);
    let version = transaction.info.version.0;
    let before_context = resource(client, "0x1::stake::InstalledRewardContext", version - 1).await;
    let before_split = resource(client, SPLIT, version - 1).await;
    assert_eq!(number(&before_context["context"]["epoch"]), old_epoch);
    assert_eq!(number(&before_split["installed_epoch"]), old_epoch);
    assert_eq!(
        number(&before_split["installed_native_reward_bps"]),
        old_bps
    );
    assert_eq!(number(&before_context["context"]["fee_limit_per_pool"]), 0);
    let rate = number(&before_context["context"]["rewards_rate"]) as u128;
    let denominator = number(&before_context["context"]["rewards_rate_denominator"]) as u128;
    assert!(denominator > 0);
    let performance = resource(client, "0x1::stake::ValidatorPerformance", version - 1).await;
    let validators = resource_at_version::<ValidatorSet>(client, version - 1).await;
    let splits = events(&transaction, "::PoCRewardSplit");
    let credits = events(&transaction, "::PoCRewardCredited");
    assert_eq!(splits.len(), 4);
    assert_eq!(credits.len(), 4);
    let mut total_inflation = 0;
    for validator in &validators.active_validators {
        let pool = validator.account_address;
        assert_eq!(validator.consensus_voting_power(), POWER);
        let perf = &performance["validators"][validator.config().validator_index as usize];
        let success = number(&perf["successful_proposals"]) as u128;
        let failures = number(&perf["failed_proposals"]) as u128;
        // 1 TOPO/OHMP 和固定已安装 POWER 对应恰好 POWER Octa。
        let inflation = if success + failures == 0 {
            0
        } else {
            (POWER as u128 * success * rate / ((success + failures) * denominator)) as u64
        };
        let native = (inflation as u128 * old_bps as u128 / 10000) as u64;
        let poc = inflation - native;
        total_inflation += inflation;
        let matching = |event: &&Event| {
            AccountAddress::from_hex_literal(event.data["pool"].as_str().unwrap()).unwrap() == pool
        };
        let split = splits
            .iter()
            .copied()
            .find(matching)
            .expect("Missing pool split");
        let credit = credits
            .iter()
            .copied()
            .find(matching)
            .expect("Missing pool credit");
        assert_eq!(
            split.data,
            json!({
                "pool": pool.to_hex_literal(), "closing_epoch": old_epoch.to_string(),
                "native_reward_bps": old_bps.to_string(), "total_inflation_octa": inflation.to_string(),
                "active_native_reward_octa": native.to_string(), "pending_inactive_native_reward_octa": "0",
                "poc_inflation_octa": poc.to_string(),
            })
        );
        let before_pool = view(client, "0x1::poc_accounting::get_pool", pool, version - 1).await;
        let after_pool = view(client, "0x1::poc_accounting::get_pool", pool, version).await;
        let units = (POWER as u128) << 16;
        let delta = (U256::from(poc).repr() << 128u32) / U256::from(units).repr();
        assert_eq!(
            credit.data,
            json!({
                "pool": pool.to_hex_literal(), "closing_epoch": old_epoch.to_string(),
                "reward_base_octa": POWER.to_string(), "inflation": poc.to_string(), "fee": "0",
                "delta_index": delta.to_string(),
            })
        );
        assert_eq!(before_pool[0], json!(units.to_string()));
        assert_eq!(after_pool[0], before_pool[0]);
        assert_eq!(number(&after_pool[3]) - number(&before_pool[3]), poc);
        let before_index = before_pool[4]
            .as_str()
            .unwrap()
            .parse::<U256>()
            .unwrap()
            .repr();
        let after_index = after_pool[4]
            .as_str()
            .unwrap()
            .parse::<U256>()
            .unwrap()
            .repr();
        assert_eq!(after_index - before_index, delta);
        let before_stake = view(client, "0x1::stake::get_stake", pool, version - 1).await;
        let after_stake = view(client, "0x1::stake::get_stake", pool, version).await;
        assert_eq!(number(&after_stake[0]) - number(&before_stake[0]), native);
        assert_eq!(before_stake[1..], [json!("0"), json!("0"), json!("0")]);
        assert_eq!(after_stake[1..], before_stake[1..]);
        println!("GOV-04 closing_epoch={old_epoch} pool={pool} bps={old_bps} success={success} failed={failures} inflation={inflation} native={native} poc={poc} version={version}");
    }
    assert!(
        total_inflation > 0,
        "Fixture must exercise a nonzero old-epoch reward"
    );
    let installed = events(&transaction, "::RewardSplitInstalled");
    assert_eq!(installed.len(), 1);
    assert_eq!(
        installed[0].data,
        json!({"epoch": (old_epoch + 1).to_string(), "poc_enabled": true, "native_reward_bps": new_bps.to_string()})
    );
    assert_eq!(events(&transaction, "::PoCEpochInstalled").len(), 1);
    assert_eq!(
        number(
            &resource(client, "0x1::stake::InstalledRewardContext", version).await["context"]
                ["epoch"]
        ),
        old_epoch + 1
    );
    assert_eq!(
        resource(client, SPLIT, version).await,
        json!({
            "installed_epoch": (old_epoch + 1).to_string(),
            "configured_native_reward_bps": new_bps.to_string(),
            "installed_native_reward_bps": new_bps.to_string(),
            "pending_change": {"vec": pending.map(|(bps, epoch)| json!({"native_reward_bps": bps.to_string(), "activation_epoch": epoch.to_string()})).into_iter().collect::<Vec<_>>()},
        })
    );
    for name in [
        "0x1::stake::EpochPlan",
        "0x1::stake::PrecomputedValidatorSet",
    ] {
        assert!(
            optional_resource_at_version(client, CORE_CODE_ADDRESS, name, version)
                .await
                .is_none()
        );
    }
    transaction
}

#[tokio::test]
async fn poc_reward_split_governance_lifecycle_and_old_epoch_rewards() {
    Lazy::force(&GOVERNANCE);
    Lazy::force(&ARITHMETIC);
    let swarm = swarm().await;
    let client = swarm
        .validators()
        .next()
        .unwrap()
        .rest_client_with_timeout(Duration::from_secs(10));
    let pools = swarm
        .validators()
        .map(|node| node.peer_id())
        .collect::<Vec<_>>();
    let root = swarm.chain_info().root_account();
    let factory = swarm
        .chain_info()
        .transaction_factory()
        .with_gas_unit_price(100)
        .with_max_gas_amount(2_000_000)
        .with_transaction_expiration_time(120);
    assert_eq!(
        resource(&client, SPLIT, 0).await,
        json!({"installed_epoch": "1", "configured_native_reward_bps": "5000", "installed_native_reward_bps": "5000", "pending_change": {"vec": []}})
    );
    let mut public = swarm.chain_info().into_aptos_public_info();
    let stranger = public
        .create_and_fund_user_account(1_000_000_000)
        .await
        .unwrap();
    let ledger = client.get_ledger_information().await.unwrap().into_inner();
    let mut epoch = number(
        &resource(
            &client,
            "0x1::reconfiguration::Configuration",
            ledger.version,
        )
        .await["epoch"],
    );

    let arithmetic = execute(
        &client,
        &root,
        &factory,
        TransactionPayload::Script(Script::new(ARITHMETIC.clone(), vec![], vec![])),
    )
    .await;
    assert!(arithmetic.info.success, "{}", arithmetic.info.vm_status);
    assert_eq!(
        state(&client, &pools, arithmetic.info.version.0 - 1).await,
        state(&client, &pools, arithmetic.info.version.0).await,
    );
    assert!(arithmetic
        .events
        .iter()
        .all(|event| !event.typ.to_string().contains("::poc_")));
    println!("REW-08 arithmetic: amounts=[0,1,2,10,17,u64::MAX], bps=[0,3000,3500,9999,10000], inflation and fee split each checked against independent u128 constants; version={}", arithmetic.info.version.0);

    for (operation, bps, target, code) in [
        (1, 0, 0, 0x30004),
        (0, 3000, epoch, 0x10002),
        (0, 3000, epoch - 1, 0x10002),
        (0, 10001, epoch + 1, 0x10001),
    ] {
        let rejected = execute(&client, &root, &factory, payload(operation, bps, target)).await;
        assert_abort(&client, &rejected, "poc_reward_split", code, &pools, &pools).await;
    }
    for payload in [
        aptos_stdlib::stake_schedule_reward_split(3000, epoch + 1),
        aptos_stdlib::stake_cancel_pending_reward_split(),
    ] {
        let rejected = execute(&client, &stranger, &factory, payload).await;
        assert_abort(
            &client,
            &rejected,
            "system_addresses",
            0x50003,
            &pools,
            &pools,
        )
        .await;
    }

    change(&client, &root, &factory, &pools, Some((5000, epoch + 2))).await;
    change(&client, &root, &factory, &pools, Some((7500, epoch + 1))).await;
    change(&client, &root, &factory, &pools, None).await;
    let rejected = execute(&client, &root, &factory, payload(1, 0, 0)).await;
    assert_abort(
        &client,
        &rejected,
        "poc_reward_split",
        0x30004,
        &pools,
        &pools,
    )
    .await;

    change(&client, &root, &factory, &pools, Some((6000, epoch + 2))).await;
    install(
        &client,
        &root,
        &factory,
        epoch,
        5000,
        5000,
        Some((6000, epoch + 2)),
    )
    .await;
    epoch += 1;
    install(&client, &root, &factory, epoch, 5000, 6000, None).await;
    epoch += 1;
    let mut old_bps = 6000;
    for next_bps in [3500, 0, 10000, 3000] {
        change(
            &client,
            &root,
            &factory,
            &pools,
            Some((next_bps, epoch + 1)),
        )
        .await;
        install(&client, &root, &factory, epoch, old_bps, next_bps, None).await;
        epoch += 1;
        old_bps = next_bps;
    }
    let ledger = client.get_ledger_information().await.unwrap().into_inner();
    assert_eq!(
        number(
            &resource(
                &client,
                "0x1::reconfiguration::Configuration",
                ledger.version
            )
            .await["epoch"]
        ),
        epoch
    );
    swarm
        .wait_for_all_nodes_to_catchup_to_version(ledger.version, Duration::from_secs(30))
        .await
        .unwrap();
    let expected = state(&client, &pools, ledger.version).await;
    for node in swarm.validators() {
        assert_eq!(
            state(&node.rest_client(), &pools, ledger.version).await,
            expected
        );
    }
}

#[tokio::test]
async fn poc_default_genesis_context_changes_wait_for_dkg_and_settle_old_snapshot() {
    Lazy::force(&CONTEXT_GOVERNANCE);
    println!("REW-02 默认创世组合：4个受控验证者、原样testnet PoC参数、每池1 TOPO/1 OHMP、native_bps=5000、费用初始0；准备期安装fee_limit=39，随后目标期排定ratio=0.5 TOPO/OHMP、rate=1/200、fee_limit=17、native_bps=6000；普通DKG开启并暂停、Chunky关闭");
    let swarm = SwarmBuilder::new_local(4)
        .with_aptos()
        .with_num_fullnodes(1)
        .with_init_genesis_stake(Arc::new(|_, stake| *stake = POWER))
        .with_init_config(Arc::new(|_, config, _| {
            config.api.failpoints_enabled = true;
        }))
        .with_init_genesis_config(Arc::new(|config| {
            config.is_test = true;
            config.allow_new_validators = true;
            config.epoch_duration_secs = 3600;
            config.min_stake = 0;
            config.max_stake = 100_000_000_000_000;
            config.voting_power_increase_limit = 50;
            config.consensus_config.enable_validator_txns();
            config.randomness_config_override = Some(OnChainRandomnessConfig::default_enabled());
            config.chunky_dkg_config_override = Some(OnChainChunkyDKGConfig::default_disabled());
            config.poc_genesis_config = Some(Arc::new(|_| PocGenesisConfiguration::testnet()));
        }))
        .build()
        .await;
    let client = swarm
        .validators()
        .next()
        .unwrap()
        .rest_client_with_timeout(Duration::from_secs(10));
    let pools = swarm
        .validators()
        .map(|node| node.peer_id())
        .collect::<Vec<_>>();
    let root = swarm.chain_info().root_account();
    let factory = swarm
        .chain_info()
        .transaction_factory()
        // EpochPlan、PVS 和 DKG 会话需要支付存储押金；提高 gas 单价可在
        // 保持生产 2M gas 上限不变时容纳这些写入。
        .with_gas_unit_price(100)
        .with_max_gas_amount(2_000_000)
        .with_transaction_expiration_time(120);
    let mut public = swarm.chain_info().into_aptos_public_info();
    let fee_payer = public
        .create_and_fund_user_account(1_000_000_000)
        .await
        .unwrap();

    let genesis = installed_at(&client, 0).await;
    assert_eq!(genesis.epoch, 1);
    assert_eq!(genesis.reward_context.5, 0);
    assert_eq!(
        number(&genesis.reward_split["installed_native_reward_bps"]),
        5000
    );
    assert_eq!(
        resource(&client, "0x1::poc_accounting::AccountingState", 0).await["config"]["params"]
            ["bond_octa_per_ohmp"],
        json!(POWER.to_string())
    );

    // 先通过公开治理安装正费用限额；该准备 Epoch 仍源自原样测试网 PoC 创世。
    let prepared = execute(&client, &root, &factory, context_payload(0)).await;
    assert!(prepared.info.success, "{}", prepared.info.vm_status);
    let prepared_at = prepared.info.version.0;
    let before_prepare = installed_at(&client, prepared_at - 1).await;
    let installed = installed_at(&client, prepared_at).await;
    assert_eq!(installed.epoch, before_prepare.epoch + 1);
    assert_eq!(installed.reward_context.5, OLD_FEE_LIMIT);
    assert_eq!(installed.reward_context.2, before_prepare.reward_context.2);
    assert_eq!(installed.reward_context.3, before_prepare.reward_context.3);
    assert_eq!(
        number(&installed.reward_split["installed_native_reward_bps"]),
        5000
    );
    assert_eq!(events(&prepared, "::stake::PoCEpochInstalled").len(), 1);

    for node in swarm.validators() {
        node.rest_client_with_timeout(Duration::from_secs(10))
            .set_failpoint(DKG_FAILPOINT.to_owned(), "pause".to_owned())
            .await
            .expect("REW-02 需要带 failpoints 的节点二进制");
    }
    let started = execute(&client, &root, &factory, context_payload(1)).await;
    assert!(started.info.success, "{}", started.info.vm_status);
    let frozen_at = started.info.version.0;
    let frozen_installed = installed_at(&client, frozen_at).await;
    assert_eq!(frozen_installed.epoch, installed.epoch);
    assert_eq!(frozen_installed.validators, installed.validators);
    assert_eq!(frozen_installed.reward_context, installed.reward_context);
    assert_eq!(
        number(&frozen_installed.reward_split["installed_native_reward_bps"]),
        5000
    );
    assert!(events(&started, "::stake::PoCRewardCredited").is_empty());
    assert!(events(&started, "::stake::PoCEpochInstalled").is_empty());
    assert!(events(&started, "::reconfiguration::NewEpochEvent").is_empty());

    let dkg = resource_at_version::<DKGState>(&client, frozen_at).await;
    let session = dkg
        .in_progress
        .as_ref()
        .expect("组合治理交易必须启动真实普通 DKG");
    assert_eq!(session.metadata.dealer_epoch, installed.epoch);
    assert_eq!(session.target_epoch(), installed.epoch + 1);
    assert!(session.transcript.is_empty());
    let plan = resource(&client, "0x1::stake::EpochPlan", frozen_at).await;
    assert_eq!(plan["stage"], json!(0));
    assert_eq!(number(&plan["data"]["epoch"]), installed.epoch + 1);
    let old_context = resource(&client, "0x1::stake::InstalledRewardContext", frozen_at).await;
    assert_eq!(plan["data"]["closing_rewards"], old_context["context"]);
    assert_eq!(
        number(&plan["data"]["closing_rewards"]["fee_limit_per_pool"]),
        OLD_FEE_LIMIT
    );
    assert_eq!(
        number(&plan["data"]["closing_rewards"]["epoch"]),
        installed.epoch
    );
    let targets = plan["data"]["targets"].as_array().unwrap();
    assert_eq!(targets.len(), pools.len());
    for target in targets {
        assert_eq!(number(&target["power"]), POWER);
        assert_eq!(number(&target["reward_base_octa"]), NEW_BOND_RATIO);
    }
    let accounting = resource(&client, "0x1::poc_accounting::AccountingState", frozen_at).await;
    assert_eq!(
        accounting["config"]["pending_params"],
        json!({"vec": [{"epoch": (installed.epoch + 1).to_string(), "params": {
            "bond_octa_per_ohmp": NEW_BOND_RATIO.to_string(), "min_power": "1",
            "max_power": "100000000000", "min_validators": "2"
        }}]})
    );
    assert_eq!(
        resource(&client, SPLIT, frozen_at).await,
        json!({
            "installed_epoch": installed.epoch.to_string(),
            "configured_native_reward_bps": "5000",
            "installed_native_reward_bps": "5000",
            "pending_change": {"vec": [{"native_reward_bps": NEW_NATIVE_BPS.to_string(), "activation_epoch": (installed.epoch + 1).to_string()}]},
        })
    );

    // 冻结期间旧委员会继续提交真实付费交易；区块收尾按旧39 Octa上限累计费用。
    let ledger_before_fee = client.get_ledger_information().await.unwrap().into_inner();
    let fees_before = pending_fees_at(&client, ledger_before_fee.version).await;
    let performance_before = resource(&client, "0x1::stake::ValidatorPerformance", frozen_at).await;
    let (priced_factory, burn_price) =
        priced_fee_factory(&client, &factory, ledger_before_fee.version).await;
    let transfer = execute(
        &client,
        &fee_payer,
        &priced_factory,
        aptos_stdlib::topo_coin_transfer(pools[0], 1_000),
    )
    .await;
    assert!(transfer.info.success, "{}", transfer.info.vm_status);
    let (waiting_at, fees_waiting, distributable) = assert_transfer_fee_block(
        &client,
        &transfer,
        burn_price,
        installed.epoch,
        OLD_FEE_LIMIT,
    )
    .await;
    assert!(distributable > 0);
    // 准备和排期治理交易可能已把本期提议者累计到旧上限 39；此时新交易仍有
    // 正的可分配费用，但该池按旧快照执行 min(old + distributed, 39)，不会继续增长。
    // assert_transfer_fee_block 已逐池核对该公式，这里只要求费用不回退且旧上限确实生效。
    assert!(fees_waiting
        .iter()
        .zip(&fees_before)
        .all(|(new, old)| old <= new && *new <= OLD_FEE_LIMIT));
    assert!(fees_waiting.iter().any(|fee| *fee == OLD_FEE_LIMIT));
    assert_eq!(installed_at(&client, waiting_at).await, frozen_installed);
    assert_eq!(
        resource(&client, "0x1::stake::EpochPlan", waiting_at).await,
        plan
    );
    assert_eq!(
        resource_at_version::<DKGState>(&client, waiting_at)
            .await
            .in_progress,
        dkg.in_progress
    );
    let performance_waiting =
        resource(&client, "0x1::stake::ValidatorPerformance", waiting_at).await;
    assert_ne!(performance_waiting, performance_before);

    let finished = execute(&client, &root, &factory, context_payload(2)).await;
    assert!(finished.info.success, "{}", finished.info.vm_status);
    let final_at = finished.info.version.0;
    let before = installed_at(&client, final_at - 1).await;
    let after = installed_at(&client, final_at).await;
    assert_eq!(before.epoch, installed.epoch);
    assert_eq!(before.validators, installed.validators);
    assert_eq!(before.reward_context, installed.reward_context);
    assert_eq!(
        number(&before.reward_split["installed_native_reward_bps"]),
        5000
    );
    assert_eq!(
        number(&before.reward_split["configured_native_reward_bps"]),
        5000
    );
    assert_eq!(after.epoch, installed.epoch + 1);
    assert_eq!(after.validators, installed.validators);
    assert!(after
        .validators
        .active_validators
        .iter()
        .all(|validator| validator.consensus_voting_power() == POWER));
    assert_eq!(after.reward_context.5, NEW_FEE_LIMIT);
    assert_eq!(
        number(&after.reward_split["installed_native_reward_bps"]),
        NEW_NATIVE_BPS
    );
    assert_eq!(after.reward_split["pending_change"], json!({"vec": []}));

    // FixedPoint64(1/200) 转换为已安装分数时逐步向下取整。
    let raw_rate = (1u128 << 64) / 200;
    let expected_denominator = (1_000_000u128 * (1u128 << 64) / raw_rate).min(u64::MAX as u128);
    let expected_numerator = expected_denominator * raw_rate / (1u128 << 64);
    assert_eq!(after.reward_context.2, expected_numerator as u64);
    assert_eq!(after.reward_context.3, expected_denominator as u64);
    let final_accounting =
        resource(&client, "0x1::poc_accounting::AccountingState", final_at).await;
    assert_eq!(
        number(&final_accounting["config"]["params"]["bond_octa_per_ohmp"]),
        NEW_BOND_RATIO
    );
    assert_eq!(
        final_accounting["config"]["pending_params"],
        json!({"vec": []})
    );

    let performance = resource(&client, "0x1::stake::ValidatorPerformance", final_at - 1).await;
    let old_fees = pending_fees_at(&client, final_at - 1).await;
    let splits = events(&finished, "::stake::PoCRewardSplit");
    let credits = events(&finished, "::stake::PoCRewardCredited");
    assert_eq!(splits.len(), pools.len());
    assert_eq!(credits.len(), pools.len());
    let mut total_income = 0u128;
    let mut total_native = 0u128;
    let mut total_poc = 0u128;
    for validator in &before.validators.active_validators {
        let pool = validator.account_address;
        let index = validator.config().validator_index as usize;
        let success = number(&performance["validators"][index]["successful_proposals"]) as u128;
        let failed = number(&performance["validators"][index]["failed_proposals"]) as u128;
        let inflation = if success + failed == 0 {
            0
        } else {
            (POWER as u128 * success * before.reward_context.2 as u128
                / ((success + failed) * before.reward_context.3 as u128)) as u64
        };
        let fee = old_fees[index].min(OLD_FEE_LIMIT);
        let native_inflation = (inflation as u128 * 5000 / 10000) as u64;
        let native_fee = (fee as u128 * 5000 / 10000) as u64;
        let poc_inflation = inflation - native_inflation;
        let poc_fee = fee - native_fee;
        let poc = poc_inflation + poc_fee;
        total_income += inflation as u128 + fee as u128;
        total_native += native_inflation as u128 + native_fee as u128;
        total_poc += poc as u128;

        let split = splits
            .iter()
            .find(|event| address(&event.data["pool"]) == pool)
            .unwrap();
        assert_eq!(
            split.data,
            json!({
                "pool": pool.to_hex_literal(), "closing_epoch": before.epoch.to_string(),
                "native_reward_bps": "5000", "total_inflation_octa": inflation.to_string(),
                "active_native_reward_octa": native_inflation.to_string(),
                "pending_inactive_native_reward_octa": "0",
                "poc_inflation_octa": poc_inflation.to_string(),
            })
        );
        let credit = credits
            .iter()
            .find(|event| address(&event.data["pool"]) == pool)
            .unwrap();
        let units = (POWER as u128) << 16;
        let delta = (U256::from(poc).repr() << 128u32) / U256::from(units).repr();
        assert_eq!(
            credit.data,
            json!({
                "pool": pool.to_hex_literal(), "closing_epoch": before.epoch.to_string(),
                "reward_base_octa": POWER.to_string(), "inflation": poc_inflation.to_string(),
                "fee": poc_fee.to_string(), "delta_index": delta.to_string(),
            })
        );
        let old_pool = view(&client, "0x1::poc_accounting::get_pool", pool, final_at - 1).await;
        let new_pool = view(&client, "0x1::poc_accounting::get_pool", pool, final_at).await;
        assert_eq!(number(&new_pool[3]) - number(&old_pool[3]), poc);
        assert_eq!(
            new_pool[4]
                .as_str()
                .unwrap()
                .parse::<U256>()
                .unwrap()
                .repr()
                - old_pool[4]
                    .as_str()
                    .unwrap()
                    .parse::<U256>()
                    .unwrap()
                    .repr(),
            delta
        );
        let old_stake = view(&client, "0x1::stake::get_stake", pool, final_at - 1).await;
        let new_stake = view(&client, "0x1::stake::get_stake", pool, final_at).await;
        assert_eq!(
            number(&new_stake[0]) - number(&old_stake[0]),
            native_inflation + native_fee
        );
        let reward_events = events(&finished, "::stake::DistributeRewards")
            .into_iter()
            .filter(|event| address(&event.data["pool_address"]) == pool)
            .collect::<Vec<_>>();
        assert_eq!(reward_events.len(), usize::from(native_inflation > 0));
        if let Some(event) = reward_events.first() {
            assert_eq!(number(&event.data["rewards_amount"]), native_inflation);
        }
        let fee_events = events(&finished, "::stake::DistributeTransactionFee")
            .into_iter()
            .filter(|event| address(&event.data["pool_address"]) == pool)
            .collect::<Vec<_>>();
        assert_eq!(fee_events.len(), usize::from(native_fee > 0));
        if let Some(event) = fee_events.first() {
            assert_eq!(number(&event.data["fee_amount"]), native_fee);
        }
    }
    assert_eq!(total_native + total_poc, total_income);
    assert!(total_income > 0);
    assert!(old_fees.iter().any(|fee| *fee > 0));
    assert_eq!(events(&finished, "::stake::PoCEpochInstalled").len(), 1);
    assert_eq!(
        events(&finished, "::poc_reward_split::RewardSplitInstalled").len(),
        1
    );
    assert_eq!(
        events(&finished, "::reconfiguration::NewEpochEvent").len(),
        1
    );
    for name in [
        "0x1::stake::EpochPlan",
        "0x1::stake::PrecomputedValidatorSet",
    ] {
        assert!(
            optional_resource_at_version(&client, CORE_CODE_ADDRESS, name, final_at)
                .await
                .is_none()
        );
    }
    assert!(resource_at_version::<DKGState>(&client, final_at)
        .await
        .in_progress
        .is_none());
    for node in swarm.validators() {
        node.rest_client_with_timeout(Duration::from_secs(10))
            .set_failpoint(DKG_FAILPOINT.to_owned(), "off".to_owned())
            .await
            .unwrap();
    }

    swarm
        .wait_for_all_nodes_to_catchup_to_version(final_at, Duration::from_secs(30))
        .await
        .unwrap();
    let expected = state(&client, &pools, final_at).await;
    for node in swarm.validators() {
        assert_eq!(state(&node.rest_client(), &pools, final_at).await, expected);
    }
    println!("REW-02 完成：旧Epoch={}使用base={}、rate={}/{}、fee_limit={}、native_bps=5000结算；目标Epoch={}安装base={}、rate={}/{}、fee_limit={}、native_bps={}；冻结期间付费交易可提交，income={}、native={}、poc={}、version={final_at}", before.epoch, POWER, before.reward_context.2, before.reward_context.3, OLD_FEE_LIMIT, after.epoch, NEW_BOND_RATIO, after.reward_context.2, after.reward_context.3, NEW_FEE_LIMIT, NEW_NATIVE_BPS, total_income, total_native, total_poc);
}
