// Copyright (c) Aptos Foundation
// Licensed pursuant to the Innovation-Enabling Source Code License, available at https://github.com/aptos-labs/aptos-core/blob/main/LICENSE

//! GOV-01 / EPO-03：公开参数排期和配置原子安装。

use super::{
    defaults::installed_at,
    optional_resource_at_version, resource_at_version,
    transactions::{assert_abort, compile_script, execute},
};
use crate::smoke_test_environment::SwarmBuilder;
use aptos_api_types::{Event, UserTransaction, ViewRequest};
use aptos_forge::{LocalSwarm, NodeExt, Swarm, SwarmExt};
use aptos_genesis::poc::PocGenesisConfiguration;
use aptos_rest_client::Client;
use aptos_sdk::{transaction_builder::TransactionFactory, types::LocalAccount};
use aptos_types::{
    account_address::AccountAddress,
    account_config::CORE_CODE_ADDRESS,
    on_chain_config::{OnChainChunkyDKGConfig, OnChainRandomnessConfig, ValidatorSet},
    transaction::{Script, TransactionArgument, TransactionPayload},
};
use move_core_types::int256::U256;
use once_cell::sync::Lazy;
use serde_json::{json, Value};
use std::{collections::BTreeMap, sync::Arc, time::Duration};

const POWER: u64 = 100_000_000;
const ACCOUNTING: &str = "0x1::poc_accounting::AccountingState";
const SPLIT: &str = "0x1::poc_reward_split::RewardSplitConfig";
const CLOCK: &str = "0x1::poc_power_store::PeriodClock";
const STORE: &str = "0x1::poc_power_store::PowerStore";
const REQUIRED_GAS: &str = "0x1::randomness_api_v0_config::RequiredGasDeposit";
type Params = [u64; 4];
type State = BTreeMap<String, Value>;

static GOVERNANCE: Lazy<[Vec<u8>; 2]> = Lazy::new(|| {
    [false, true].map(|authorized| {
        let source = r#"
script {
    use std::option;
    use topo_framework::poc_accounting;
    use topo_framework::poc_allocation;
    use topo_framework::randomness_api_v0_config;
    use topo_framework::reconfiguration;
    use topo_framework::stake;
    use topo_framework::topo_governance;

    fun main(sender: &signer, operation: u8, target: u64,
        bond: u64, minimum: u64, maximum: u64, members: u64) {
        AUTHORITY
        if (operation == 0 || operation == 2) {
            if (operation == 2) {
                // 两次写入都发生在目标检查之前；失败时必须连同待生效算力参数和事件一起回滚。
                stake::schedule_reward_split(framework, 6000, reconfiguration::current_epoch() + 1);
                randomness_api_v0_config::set_for_next_epoch(framework, option::some(12345));
            };
            poc_allocation::schedule_power_params(framework,
                poc_accounting::new_power_params(bond, minimum, maximum, members), target);
            if (operation == 2) { topo_governance::reconfigure(framework); };
        } else if (operation == 1) {
            poc_allocation::cancel_pending_power_params(framework);
        } else {
            assert!(operation == 3, 0);
            topo_governance::reconfigure(framework);
        };
    }

}
"#;
        // 脚本只含一个函数。两种变体调用完全相同的公开路径；
        // 仅治理变体会从 root 解析 framework signer。
        let authority = if authorized {
            "let signer = topo_governance::get_signer_testnet_only(sender, @0x1); let framework = &signer;"
        } else {
            "let framework = sender;"
        };
        compile_script(
            &format!("PoCPowerParameterLifecycle{authorized}"),
            &source.replace("AUTHORITY", authority),
        )
    })
});

fn payload(authorized: bool, operation: u8, target: u64, params: Params) -> TransactionPayload {
    let mut arguments = vec![
        TransactionArgument::U8(operation),
        TransactionArgument::U64(target),
    ];
    arguments.extend(params.into_iter().map(TransactionArgument::U64));
    TransactionPayload::Script(Script::new(
        GOVERNANCE[usize::from(authorized)].clone(),
        vec![],
        arguments,
    ))
}

fn params_json(params: Params) -> Value {
    json!({"bond_octa_per_ohmp": params[0].to_string(), "min_power": params[1].to_string(),
        "max_power": params[2].to_string(), "min_validators": params[3].to_string()})
}

fn pending_json(pending: Option<(u64, Params)>) -> Value {
    json!({"vec": pending.into_iter().map(|(epoch, params)|
        json!({"epoch": epoch.to_string(), "params": params_json(params)})).collect::<Vec<_>>()})
}

fn number(value: &Value) -> u64 {
    value.as_str().unwrap().parse().unwrap()
}

async fn view(client: &Client, function: &str, args: Vec<Value>, version: u64) -> Vec<Value> {
    client
        .view(
            &ViewRequest {
                function: function.parse().unwrap(),
                type_arguments: vec![],
                arguments: args,
            },
            Some(version),
        )
        .await
        .unwrap()
        .into_inner()
}

async fn resource(client: &Client, name: &str, version: u64) -> Value {
    optional_resource_at_version(client, CORE_CODE_ADDRESS, name, version)
        .await
        .unwrap_or_else(|| panic!("Missing {name} at version {version}"))
        .data
}

async fn state(client: &Client, pools: &[AccountAddress], version: u64) -> State {
    let mut result = State::new();
    for name in [
        ACCOUNTING,
        SPLIT,
        CLOCK,
        STORE,
        "0x1::stake::InstalledRewardContext",
        "0x1::stake::ValidatorSet",
        "0x1::reconfiguration::Configuration",
        "0x1::staking_config::StakingConfig",
        "0x1::staking_config::StakingRewardsConfig",
        "0x1::config_buffer::PendingConfigs",
        REQUIRED_GAS,
        "0x1::reconfiguration_state::State",
        "0x1::stake::EpochPlan",
        "0x1::stake::PrecomputedValidatorSet",
    ] {
        result.insert(
            name.to_owned(),
            json!(
                optional_resource_at_version(client, CORE_CODE_ADDRESS, name, version)
                    .await
                    .map(|value| value.data)
            ),
        );
    }
    assert!(result["0x1::stake::EpochPlan"].is_null());
    assert!(result["0x1::stake::PrecomputedValidatorSet"].is_null());
    for pool in pools {
        for name in [
            "0x1::poc_accounting::get_pool",
            "0x1::poc_accounting::get_allocations",
            "0x1::poc_power_store::get_user_power_version",
            "0x1::poc_power_store::get_accounting_snapshot",
            "0x1::stake::get_stake",
        ] {
            result.insert(
                format!("{name}:{pool}"),
                json!(view(client, name, vec![json!(pool)], version).await),
            );
        }
    }
    result
}

fn events<'a>(txn: &'a UserTransaction, suffix: &str) -> Vec<&'a Event> {
    txn.events
        .iter()
        .filter(|event| event.typ.to_string().ends_with(suffix))
        .collect()
}

fn assert_no_business_events(txn: &UserTransaction) {
    assert!(txn.events.iter().all(|event| {
        let typ = event.typ.to_string();
        [
            "::poc_",
            "::stake::",
            "::reconfiguration::",
            "::randomness_api_v0_config::",
        ]
        .iter()
        .all(|module| !typ.contains(module))
    }));
}

async fn rejected(
    client: &Client,
    txn: &UserTransaction,
    pools: &[AccountAddress],
    module: &str,
    code: u64,
) {
    assert_abort(client, txn, module, code, pools, pools).await;
    let version = txn.info.version.0;
    assert_eq!(
        state(client, pools, version - 1).await,
        state(client, pools, version).await
    );
    assert_no_business_events(txn);
    println!(
        "GOV-01/EPO-03 rejected {module}/{code:#x}, atomic business rollback, version={version}"
    );
}

async fn change(
    client: &Client,
    root: &LocalAccount,
    factory: &TransactionFactory,
    pools: &[AccountAddress],
    pending: Option<(u64, Params)>,
) {
    let (operation, target, params) =
        pending.map_or((1, 0, [0; 4]), |(epoch, params)| (0, epoch, params));
    let txn = execute(
        client,
        root,
        factory,
        payload(true, operation, target, params),
    )
    .await;
    assert!(txn.info.success, "{}", txn.info.vm_status);
    let version = txn.info.version.0;
    let mut expected = state(client, pools, version - 1).await;
    expected.get_mut(ACCOUNTING).unwrap()["config"]["pending_params"] = pending_json(pending);
    assert_eq!(state(client, pools, version).await, expected);
    // 当前协议中的这些公开算力 setter 不产生业务事件。
    assert_no_business_events(&txn);
}

/// 即使同一笔交易修改算力参数、分流和缓冲原生配置，结束当期奖励仍使用旧已安装权重和基数。
async fn assert_install(
    client: &Client,
    txn: &UserTransaction,
    old_power: u64,
    new_power: u64,
    new_params: Params,
    pending: Option<(u64, Params)>,
    new_bps: u64,
) {
    assert!(txn.info.success, "{}", txn.info.vm_status);
    let version = txn.info.version.0;
    let before = installed_at(client, version - 1).await;
    let after = installed_at(client, version).await;
    assert_eq!(after.epoch, before.epoch + 1);
    assert_eq!(
        after.reward_split,
        json!({"installed_epoch": after.epoch.to_string(),
            "installed_native_reward_bps": new_bps.to_string(),
            "configured_native_reward_bps": new_bps.to_string(),
            "pending_change": {"vec": []}})
    );
    let mut expected_context = before.reward_context;
    expected_context.0 = after.epoch;
    assert_eq!(after.reward_context, expected_context);
    assert_eq!(
        after.validators.total_voting_power,
        u128::from(new_power) * 4
    );
    assert!(after.validators.pending_active.is_empty());
    assert!(after.validators.pending_inactive.is_empty());
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
    let old_bps = number(&before.reward_split["installed_native_reward_bps"]);
    let old_config = resource(client, ACCOUNTING, version - 1).await;
    let new_config = resource(client, ACCOUNTING, version).await;
    let mut expected_config = old_config.clone();
    expected_config["epoch"] = json!(after.epoch.to_string());
    expected_config["config"]["params"] = params_json(new_params);
    expected_config["config"]["pending_params"] = pending_json(pending);
    assert_eq!(new_config, expected_config);
    assert_eq!(
        new_config["config"]["first_poc_epoch"],
        json!({"vec": ["1"]})
    );
    // 本场景不跨周期边界；参数不得重置或改写原始标准化基线、时钟、保留比例或支持期限。
    assert_eq!(
        resource(client, STORE, version - 1).await,
        resource(client, STORE, version).await
    );
    let mut expected_clock = resource(client, CLOCK, version - 1).await;
    expected_clock["last_epoch"] = json!((number(&expected_clock["last_epoch"]) + 1).to_string());
    expected_clock["epochs_until_next_power_period"] =
        json!((number(&expected_clock["epochs_until_next_power_period"]) - 1).to_string());
    assert_eq!(resource(client, CLOCK, version).await, expected_clock);
    let perf = resource(client, "0x1::stake::ValidatorPerformance", version - 1).await;
    let before_validators = resource_at_version::<ValidatorSet>(client, version - 1).await;
    let units = (POWER as u128) << 16;
    let mut total_inflation = 0;
    assert_eq!(events(txn, "::PoCRewardCredited").len(), 4);
    assert_eq!(events(txn, "::PoCRewardSplit").len(), 4);
    for validator in &before_validators.active_validators {
        let pool = validator.account_address;
        assert_eq!(validator.consensus_voting_power(), old_power);
        let performance = &perf["validators"][validator.config().validator_index as usize];
        let success = u128::from(number(&performance["successful_proposals"]));
        let failed = u128::from(number(&performance["failed_proposals"]));
        let inflation = if success + failed == 0 {
            0
        } else {
            (u128::from(old_power) * success * u128::from(before.reward_context.2)
                / ((success + failed) * u128::from(before.reward_context.3))) as u64
        };
        let native = (u128::from(inflation) * u128::from(old_bps) / 10000) as u64;
        let poc = inflation - native;
        total_inflation += inflation;
        let pool_event = |suffix| {
            let matching = events(txn, suffix)
                .into_iter()
                .filter(|event| {
                    AccountAddress::from_hex_literal(event.data["pool"].as_str().unwrap()).unwrap()
                        == pool
                })
                .collect::<Vec<_>>();
            assert_eq!(matching.len(), 1);
            matching[0].data.clone()
        };
        let delta = (U256::from(poc).repr() << 128u32) / U256::from(units).repr();
        assert_eq!(
            pool_event("::PoCRewardCredited"),
            json!({"pool": pool.to_hex_literal(),
            "closing_epoch": before.epoch.to_string(), "reward_base_octa": old_power.to_string(),
            "inflation": poc.to_string(), "fee": "0", "delta_index": delta.to_string()})
        );
        assert_eq!(
            pool_event("::PoCRewardSplit"),
            json!({"pool": pool.to_hex_literal(),
            "closing_epoch": before.epoch.to_string(), "native_reward_bps": old_bps.to_string(),
            "total_inflation_octa": inflation.to_string(), "active_native_reward_octa": native.to_string(),
            "pending_inactive_native_reward_octa": "0", "poc_inflation_octa": poc.to_string()})
        );
        let old_pool = view(
            client,
            "0x1::poc_accounting::get_pool",
            vec![json!(pool)],
            version - 1,
        )
        .await;
        let new_pool = view(
            client,
            "0x1::poc_accounting::get_pool",
            vec![json!(pool)],
            version,
        )
        .await;
        assert_eq!(old_pool[0], json!(units.to_string()));
        assert_eq!(new_pool[0], old_pool[0]);
        assert_eq!(old_pool[2], json!(old_power.to_string()));
        assert_eq!(new_pool[2], json!(new_power.to_string()));
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
        let old_stake = view(
            client,
            "0x1::stake::get_stake",
            vec![json!(pool)],
            version - 1,
        )
        .await;
        let new_stake = view(client, "0x1::stake::get_stake", vec![json!(pool)], version).await;
        assert_eq!(number(&new_stake[0]) - number(&old_stake[0]), native);
        assert_eq!(new_stake[1..], old_stake[1..]);
        assert_eq!(
            after
                .validators
                .active_validators
                .iter()
                .find(|v| v.account_address == pool)
                .unwrap()
                .consensus_voting_power(),
            new_power
        );
        println!("GOV-01 install version={version}, closing={}, pool={pool}, old_base={old_power}, new_base={new_power}, success={success}, failed={failed}, inflation={inflation}, native={native}, poc={poc}", before.epoch);
    }
    assert!(
        total_inflation > 0,
        "Must exercise actual old-epoch rewards"
    );
    let installed = events(txn, "::PoCEpochInstalled");
    assert_eq!(installed.len(), 1);
    assert_eq!(
        installed[0].data,
        json!({"epoch": after.epoch.to_string(), "period": "0", "selected_count": "4", "total_power": (4 * new_power).to_string()})
    );
    assert_eq!(events(txn, "::RewardSplitInstalled").len(), 1);
    assert_eq!(after.validators.active_validators.len(), 4);
}

#[tokio::test]
async fn poc_power_params_lifecycle_and_atomic_reconfiguration() {
    Lazy::force(&GOVERNANCE);
    println!("GOV-01/EPO-03 fixture: 4 validators, Controlled testnet PoC, each 1 OHMP/1 TOPO, growth50%, APY10%, epoch3600s, DKG/Chunky off, retention9995/native5000, fee0; power ceilings install only at target epochs");
    let swarm: LocalSwarm = SwarmBuilder::new_local(4)
        .with_aptos()
        .with_init_genesis_stake(Arc::new(|_, amount| *amount = POWER))
        .with_init_genesis_config(Arc::new(|config| {
            config.is_test = true;
            config.allow_new_validators = true;
            config.epoch_duration_secs = 3600;
            config.min_stake = 1;
            config.max_stake = 100_000_000_000_000;
            config.rewards_apy_percentage = 10;
            config.voting_power_increase_limit = 50;
            config.randomness_config_override = Some(OnChainRandomnessConfig::Off);
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
        .with_gas_unit_price(1)
        .with_max_gas_amount(2_000_000)
        .with_transaction_expiration_time(120);
    let mut public = swarm.chain_info().into_aptos_public_info();
    let stranger = public
        .create_and_fund_user_account(1_000_000_000)
        .await
        .unwrap();
    let initial: Params = [POWER, 1, 1000 * POWER, 2];
    assert_eq!(
        resource(&client, ACCOUNTING, 0).await["config"]["params"],
        params_json(initial)
    );
    let version = client
        .get_ledger_information()
        .await
        .unwrap()
        .into_inner()
        .version;
    let epoch = installed_at(&client, version).await.epoch;
    // Swarm 启动健康检查可能已经触发一次换届；创世配置已在上方版本 0 单独核对。
    assert!(epoch < 58, "Keep this case before the first power boundary");
    let half = [POWER, 1, POWER / 2, 2];
    let quarter = [POWER, 1, POWER / 4, 2];

    change(&client, &root, &factory, &pools, None).await;
    change(&client, &root, &factory, &pools, Some((epoch + 2, half))).await;
    change(&client, &root, &factory, &pools, Some((epoch + 1, quarter))).await;
    change(&client, &root, &factory, &pools, None).await;
    change(&client, &root, &factory, &pools, None).await;
    for target in [epoch - 1, epoch] {
        let txn = execute(&client, &root, &factory, payload(true, 0, target, half)).await;
        rejected(&client, &txn, &pools, "poc_accounting", 0x10006).await;
    }
    for invalid in [
        [0, 1, POWER, 2],
        [POWER, 0, POWER, 2],
        [POWER, 2, 1, 2],
        [POWER, 1, POWER, 0],
        [POWER, 1, POWER, 129],
        [POWER, 1, POWER, 128],
    ] {
        let txn = execute(
            &client,
            &root,
            &factory,
            payload(true, 0, epoch + 1, invalid),
        )
        .await;
        rejected(&client, &txn, &pools, "poc_accounting", 0x10007).await;
    }
    // 上限参数可覆盖完整 u64 范围；实际总权重和计奖金额由换届预检验证。
    for valid in [[POWER, 1, u64::MAX, 2], [2 * POWER, 1, u64::MAX, 2]] {
        change(&client, &root, &factory, &pools, Some((epoch + 1, valid))).await;
        change(&client, &root, &factory, &pools, None).await;
    }
    for operation in [0, 1] {
        let txn = execute(
            &client,
            &stranger,
            &factory,
            payload(false, operation, epoch + 1, half),
        )
        .await;
        rejected(&client, &txn, &pools, "system_addresses", 0x50003).await;
    }
    // 两笔包含多次写入的治理交易失败后，既有排期必须保持不变。
    change(&client, &root, &factory, &pools, Some((epoch + 2, half))).await;
    for invalid_target in [[POWER, POWER + 1, 2 * POWER, 2], [POWER, 1, POWER, 5]] {
        let txn = execute(
            &client,
            &root,
            &factory,
            payload(true, 2, epoch + 1, invalid_target),
        )
        .await;
        rejected(&client, &txn, &pools, "reconfiguration_with_dkg", 0x30001).await;
    }
    let txn = execute(&client, &root, &factory, payload(true, 3, 0, [0; 4])).await;
    assert_install(
        &client,
        &txn,
        POWER,
        POWER,
        initial,
        Some((epoch + 2, half)),
        5000,
    )
    .await;
    let txn = execute(&client, &root, &factory, payload(true, 3, 0, [0; 4])).await;
    assert_install(&client, &txn, POWER, POWER / 2, half, None, 5000).await;
    // 相同复合操作此时具有合法目标；所有配置一起安装，而结束当期仍使用旧基数和旧分流。
    let txn = execute(
        &client,
        &root,
        &factory,
        payload(true, 2, epoch + 3, quarter),
    )
    .await;
    assert_install(&client, &txn, POWER / 2, POWER / 4, quarter, None, 6000).await;
    assert_eq!(
        resource(&client, REQUIRED_GAS, txn.info.version.0).await,
        json!({"gas_amount": {"vec": ["12345"]}})
    );
    let pending = resource(
        &client,
        "0x1::config_buffer::PendingConfigs",
        txn.info.version.0,
    )
    .await;
    assert!(pending["configs"]["data"]
        .as_array()
        .unwrap()
        .iter()
        .all(|item| !item["key"]
            .as_str()
            .unwrap()
            .ends_with("::randomness_api_v0_config::RequiredGasDeposit")));
    assert_eq!(events(&txn, "::RewardSplitScheduled").len(), 1);
    let version = txn.info.version.0;
    swarm
        .wait_for_all_nodes_to_catchup_to_version(version, Duration::from_secs(30))
        .await
        .unwrap();
    let expected = state(&client, &pools, version).await;
    for node in swarm.validators() {
        assert_eq!(state(&node.rest_client(), &pools, version).await, expected);
    }
}
