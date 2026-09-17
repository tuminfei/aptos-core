// Copyright (c) Aptos Foundation
// Licensed pursuant to the Innovation-Enabling Source Code License, available at https://github.com/aptos-labs/aptos-core/blob/main/LICENSE

//! GOV-05：生产交易必须同时校验当前和待生效的 PoC 参数。

use super::{
    optional_resource_at_version, resource_at_version,
    transactions::{assert_abort, compile_script, execute},
};
use crate::smoke_test_environment::SwarmBuilder;
use aptos_api_types::{UserTransaction, WriteSetChange};
use aptos_cached_packages::aptos_stdlib;
use aptos_forge::{LocalSwarm, NodeExt, Swarm, SwarmExt};
use aptos_genesis::poc::{DeploymentLimits, DeploymentMode, PocGenesisConfiguration, PowerParams};
use aptos_rest_client::Client;
use aptos_types::{
    account_address::AccountAddress,
    account_config::CORE_CODE_ADDRESS,
    on_chain_config::{OnChainChunkyDKGConfig, OnChainRandomnessConfig, ValidatorSet},
    transaction::{Script, TransactionArgument, TransactionPayload},
};
use once_cell::sync::Lazy;
use serde_json::{json, Value};
use std::{collections::BTreeMap, sync::Arc, time::Duration};

const INVALID_PARAM_COMBINATION: u64 = 0x10007;
const ACCOUNTING: &str = "poc_accounting::AccountingState";
const STAKING_CONFIG: &str = "staking_config::StakingConfig";
const REQUIRED_RESOURCES: [&str; 8] = [
    ACCOUNTING,
    STAKING_CONFIG,
    "poc_power_store::PowerStore",
    "poc_power_store::PeriodClock",
    "poc_reward_split::RewardSplitConfig",
    "stake::InstalledRewardContext",
    "stake::ValidatorSet",
    "reconfiguration::Configuration",
];
const OPTIONAL_RESOURCES: [&str; 5] = [
    "staking_config::StakingRewardsConfig",
    "config_buffer::PendingConfigs",
    "reconfiguration_state::State",
    "stake::EpochPlan",
    "stake::PrecomputedValidatorSet",
];

type GovernanceState = BTreeMap<String, Value>;

static GOVERNANCE_SCRIPT: Lazy<Vec<u8>> = Lazy::new(|| {
    compile_script(
        "PoCGovernanceCrossValidation",
        r#"
script {
    use topo_framework::poc_accounting;
    use topo_framework::poc_allocation;
    use topo_framework::stake;
    use topo_framework::staking_config;
    use topo_framework::topo_governance;

    fun main(root: &signer, operation: u8, value: u64, target_epoch: u64, rollback_marker: bool) {
        let framework = topo_governance::get_signer_testnet_only(root, @0x1);
        if (rollback_marker) {
            // 这次合法写入会在不兼容更新前发出 RewardSplitScheduled。
            // Move abort 必须同时丢弃待生效分流及其事件。
            stake::schedule_reward_split(&framework, 3000, target_epoch);
        };
        if (operation == 0) {
            poc_allocation::schedule_power_params(&framework,
                poc_accounting::new_power_params(100000000, 10, 1000, value), target_epoch);
        } else if (operation == 1) {
            staking_config::update_voting_power_increase_limit(&framework, value);
        } else {
            assert!(operation == 2, 0);
            poc_allocation::cancel_pending_power_params(&framework);
        };
    }
}
"#,
    )
});

#[derive(Clone, Copy, Debug)]
enum Change {
    Minimum(u64),
    Growth(u64),
    CancelPending,
}

fn payload(change: Change, epoch: u64, rollback_marker: bool) -> TransactionPayload {
    let (operation, value) = match change {
        Change::Minimum(value) => (0, value),
        Change::Growth(value) => (1, value),
        Change::CancelPending => (2, 0),
    };
    TransactionPayload::Script(Script::new(GOVERNANCE_SCRIPT.clone(), vec![], vec![
        TransactionArgument::U8(operation),
        TransactionArgument::U64(value),
        TransactionArgument::U64(epoch.checked_add(1).expect("Target epoch overflow")),
        TransactionArgument::Bool(rollback_marker),
    ]))
}

/// 显式 A 变体：五个等权验证者、六个候选槽、1 小时 Epoch，并关闭两种 DKG 模式。
/// 本 fixture 不是默认网络配置。
async fn governance_swarm() -> LocalSwarm {
    println!("GOV-05 fixture A: nodes=5, Open, dynamic=true, min_validators=5, validator_limit=6, min_power=10, max_power=1000, initial_power=10, bond=100 Octa, growth=25%, epoch=3600s, ordinary/Chunky DKG=off, retention_bps=10000, native_reward_bps=0, fee_limit=0");
    SwarmBuilder::new_local(5)
        .with_aptos()
        .with_init_genesis_stake(Arc::new(|_, stake| *stake = 100))
        .with_init_genesis_config(Arc::new(|config| {
            config.is_test = true;
            config.allow_new_validators = true;
            config.epoch_duration_secs = 3600;
            config.min_stake = 1;
            config.max_stake = 1000;
            config.voting_power_increase_limit = 25;
            config.randomness_config_override = Some(OnChainRandomnessConfig::Off);
            config.chunky_dkg_config_override = Some(OnChainChunkyDKGConfig::default_disabled());
            config.poc_genesis_config = Some(Arc::new(|_| PocGenesisConfiguration {
                params: PowerParams {
                    bond_octa_per_ohmp: 100_000_000,
                    min_power: 10,
                    max_power: 1000,
                    min_validators: 5,
                },
                limits: DeploymentLimits {
                    max_allocations: 4,
                    max_claim_pools: 4,
                    max_upload_users: 32,
                    validator_limit: 6,
                    max_reward_base_octa: 1000,
                    rate_max_num: 1,
                    rate_max_den: 1,
                    fee_max: 10,
                    reward_epoch_limit: 1000,
                },
                deployment_mode: DeploymentMode::Open,
                retention_bps: 10000,
                max_relative_period: 100,
                initial_raw_power: 10,
                native_reward_bps: 0,
            }));
        }))
        .build()
        .await
}

async fn state_at(client: &Client, version: u64, epoch: u64) -> GovernanceState {
    let mut state = GovernanceState::new();
    for name in REQUIRED_RESOURCES.iter().chain(OPTIONAL_RESOURCES.iter()) {
        if let Some(resource) = optional_resource_at_version(
            client,
            CORE_CODE_ADDRESS,
            &format!("0x1::{name}"),
            version,
        )
        .await
        {
            state.insert((*name).to_owned(), resource.data);
        }
    }
    for required in REQUIRED_RESOURCES {
        assert!(
            state.contains_key(required),
            "Missing {required} at version {version}"
        );
    }
    assert_eq!(
        state["reconfiguration::Configuration"]["epoch"],
        json!(epoch.to_string()),
        "GOV-05 escaped its fixed epoch"
    );
    assert_eq!(state[ACCOUNTING]["epoch"], json!(epoch.to_string()));
    assert_eq!(
        state[ACCOUNTING]["config"]["params"],
        json!({
            "bond_octa_per_ohmp": "100000000", "min_power": "10", "max_power": "1000", "min_validators": "5",
        })
    );
    assert_eq!(
        state[ACCOUNTING]["config"]["limits"]["validator_limit"],
        json!("6")
    );
    assert_eq!(state[ACCOUNTING]["config"]["deployment_mode"], json!(1));
    assert_eq!(
        state[STAKING_CONFIG]["allow_validator_set_change"],
        json!(true)
    );
    assert_eq!(
        state["stake::InstalledRewardContext"]["context"]["epoch"],
        json!(epoch.to_string())
    );
    assert_eq!(
        state["stake::InstalledRewardContext"]["context"]["poc_enabled"],
        json!(true)
    );
    assert_eq!(
        state["poc_reward_split::RewardSplitConfig"],
        json!({
            "installed_epoch": epoch.to_string(), "installed_native_reward_bps": "0", "configured_native_reward_bps": "0", "pending_change": {"vec": []},
        })
    );
    assert!(!state.contains_key("stake::EpochPlan"));
    assert!(!state.contains_key("stake::PrecomputedValidatorSet"));
    state
}

fn assert_no_governance_events(transaction: &UserTransaction) {
    assert!(
        transaction.events.iter().all(|event| {
            let module = event.typ.to_string();
            !module.contains("::poc_")
                && !module.contains("::staking_config::")
                && !module.contains("::stake::")
                && !module.contains("::reconfiguration::")
        }),
        "Governance business events survived: {:?}",
        transaction.events
    );
}

async fn submit_change(
    swarm: &mut LocalSwarm,
    client: &Client,
    change: Change,
    epoch: u64,
    rollback_marker: bool,
) -> UserTransaction {
    let chain = swarm.chain_info();
    let factory = chain
        .transaction_factory()
        .with_gas_unit_price(1)
        .with_max_gas_amount(2_000_000)
        .with_transaction_expiration_time(120);
    execute(
        client,
        &chain.root_account(),
        &factory,
        payload(change, epoch, rollback_marker),
    )
    .await
}

/// 成功的 setter 只修改请求字段；已安装委员会、Epoch、奖励上下文、分流和指数基线均保持不变。
async fn successful_change(
    swarm: &mut LocalSwarm,
    client: &Client,
    change: Change,
    epoch: u64,
) -> UserTransaction {
    let transaction = submit_change(swarm, client, change, epoch, false).await;
    assert!(transaction.info.success, "{}", transaction.info.vm_status);
    let version = transaction.info.version.0;
    let mut expected = state_at(client, version - 1, epoch).await;
    match change {
        Change::Minimum(minimum) => {
            let mut params = expected[ACCOUNTING]["config"]["params"].clone();
            params["min_validators"] = json!(minimum.to_string());
            expected.get_mut(ACCOUNTING).unwrap()["config"]["pending_params"] =
                json!({"vec": [{"epoch": (epoch + 1).to_string(), "params": params}]});
        },
        Change::Growth(growth) => {
            expected.get_mut(STAKING_CONFIG).unwrap()["voting_power_increase_limit"] =
                json!(growth.to_string());
        },
        Change::CancelPending => {
            expected.get_mut(ACCOUNTING).unwrap()["config"]["pending_params"] = json!({"vec": []});
        },
    }
    assert_eq!(
        state_at(client, version, epoch).await,
        expected,
        "Unexpected state change for {change:?}"
    );
    // 这些 setter 不产生业务事件；用于回滚检测的主动发事件标记处于关闭状态。
    assert_no_governance_events(&transaction);
    transaction
}

async fn rejected_change(
    swarm: &mut LocalSwarm,
    client: &Client,
    change: Change,
    epoch: u64,
    pools: &[AccountAddress],
) {
    let transaction = submit_change(swarm, client, change, epoch, true).await;
    assert_abort(
        client,
        &transaction,
        "poc_accounting",
        INVALID_PARAM_COMBINATION,
        pools,
        pools,
    )
    .await;
    let version = transaction.info.version.0;
    assert_eq!(
        state_at(client, version - 1, epoch).await,
        state_at(client, version, epoch).await,
        "GOV-05 failed update changed governance configuration"
    );
    for change in &transaction.info.changes {
        let resource = match change {
            WriteSetChange::WriteResource(change) => Some(change.data.typ.to_string()),
            WriteSetChange::DeleteResource(change) => Some(change.resource.to_string()),
            WriteSetChange::WriteTableItem(_)
            | WriteSetChange::DeleteTableItem(_)
            | WriteSetChange::WriteModule(_)
            | WriteSetChange::DeleteModule(_) => None,
        };
        if let Some(resource) = resource {
            assert!(
                REQUIRED_RESOURCES
                    .iter()
                    .chain(OPTIONAL_RESOURCES.iter())
                    .all(|name| !resource.ends_with(name)),
                "Failed governance transaction wrote {resource}"
            );
        }
    }
    assert_no_governance_events(&transaction);
}

#[tokio::test]
async fn poc_governance_growth_validates_current_and_pending_params() {
    // 在节点启动前完成编译，使治理序列保持在同一个已安装 Epoch 内。
    Lazy::force(&GOVERNANCE_SCRIPT);
    for pending_first in [true, false] {
        println!(
            "GOV-05 order: {}",
            if pending_first {
                "schedule minimum, then update growth"
            } else {
                "update growth, then schedule minimum"
            }
        );
        let mut swarm = governance_swarm().await;
        let client = swarm
            .validators()
            .next()
            .unwrap()
            .rest_client_with_timeout(Duration::from_secs(10));
        let genesis = state_at(&client, 0, 1).await;
        assert_eq!(
            genesis[STAKING_CONFIG]["voting_power_increase_limit"],
            json!("25")
        );
        assert_eq!(
            genesis[ACCOUNTING]["config"]["pending_params"],
            json!({"vec": []})
        );
        // 即使 Epoch 很长，首个区块也可能已经越过创世 Epoch 1。
        // 先提交普通交易，之后全程使用实际已安装 Epoch。
        let receiver = swarm.validators().next().unwrap().peer_id();
        let chain = swarm.chain_info();
        let factory = chain
            .transaction_factory()
            .with_gas_unit_price(1)
            .with_max_gas_amount(2_000_000)
            .with_transaction_expiration_time(120);
        let warmup = execute(
            &client,
            &chain.root_account(),
            &factory,
            aptos_stdlib::topo_coin_transfer(receiver, 1),
        )
        .await;
        assert!(warmup.info.success, "{}", warmup.info.vm_status);
        let initial = client.get_ledger_information().await.unwrap().into_inner();
        let epoch = initial.epoch;
        let initial_state = state_at(&client, initial.version, epoch).await;
        assert_eq!(
            initial_state[STAKING_CONFIG]["voting_power_increase_limit"],
            json!("25")
        );
        assert_eq!(
            initial_state[ACCOUNTING]["config"]["pending_params"],
            json!({"vec": []})
        );
        println!(
            "GOV-05 fixed installed epoch: epoch={epoch}, version={}",
            initial.version
        );
        let validators = resource_at_version::<ValidatorSet>(&client, initial.version).await;
        assert_eq!(validators.active_validators.len(), 5);
        assert_eq!(validators.total_voting_power, 50);
        assert!(validators
            .active_validators
            .iter()
            .all(|validator| validator.consensus_voting_power() == 10));
        let pools = validators
            .active_validators
            .iter()
            .map(|validator| validator.account_address)
            .collect::<Vec<_>>();

        let final_transaction = if pending_first {
            successful_change(&mut swarm, &client, Change::Minimum(4), epoch).await;
            // 当前配置 5*10*20/100=10 合法；待生效配置 4*10*20/100=8 不合法。
            rejected_change(&mut swarm, &client, Change::Growth(20), epoch, &pools).await;
            successful_change(&mut swarm, &client, Change::CancelPending, epoch).await;
            successful_change(&mut swarm, &client, Change::Growth(20), epoch).await
        } else {
            successful_change(&mut swarm, &client, Change::Growth(20), epoch).await;
            rejected_change(&mut swarm, &client, Change::Minimum(4), epoch, &pools).await;
            // 恢复充足预算，验证先前被拒绝的排期现在可以成功。
            successful_change(&mut swarm, &client, Change::Growth(25), epoch).await;
            successful_change(&mut swarm, &client, Change::Minimum(4), epoch).await
        };
        let version = final_transaction.info.version.0;
        swarm
            .wait_for_all_nodes_to_catchup_to_version(version, Duration::from_secs(30))
            .await
            .unwrap();
        let expected = state_at(&client, version, epoch).await;
        for node in swarm.validators() {
            assert_eq!(
                state_at(
                    &node.rest_client_with_timeout(Duration::from_secs(10)),
                    version,
                    epoch,
                )
                .await,
                expected,
                "GOV-05 nodes diverged at the same ledger version"
            );
        }
    }
}
