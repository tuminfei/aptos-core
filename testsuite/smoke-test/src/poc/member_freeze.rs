// Copyright (c) Aptos Foundation
// Licensed pursuant to the Innovation-Enabling Source Code License, available at https://github.com/aptos-labs/aptos-core/blob/main/LICENSE

//! FRZ-02：在真实普通 DKG 暂停前后验证公开成员变更入口。
//! 使用七个真实创世身份，在同一快照中同时保留一个非活跃待加入者、
//! 一个可取消退出的成员，以及另一个可安全移除的成员。
//! 另以五节点用例单独验证取消待加入申请。
//! 使用显式配置的 Open A fixture，关闭 Chunky DKG。

use super::{
    assert_targets,
    defaults::{installed_at, InstalledSnapshot},
    frozen_context_at, optional_resource_at_version, resource_at_version,
    transactions::{assert_abort, compile_script, execute},
};
use crate::smoke_test_environment::SwarmBuilder;
use aptos_api_types::{AptosErrorCode, Event, UserTransaction, ViewRequest, WriteSetChange};
use aptos_cached_packages::aptos_stdlib;
use aptos_forge::{LocalSwarm, NodeExt, Swarm, SwarmExt};
use aptos_genesis::poc::{DeploymentLimits, DeploymentMode, PocGenesisConfiguration, PowerParams};
use aptos_rest_client::{error::RestError, Client};
use aptos_sdk::{transaction_builder::TransactionFactory, types::LocalAccount};
use aptos_types::{
    account_address::AccountAddress,
    account_config::CORE_CODE_ADDRESS,
    dkg::DKGState,
    on_chain_config::{OnChainChunkyDKGConfig, OnChainRandomnessConfig, ValidatorSet},
    transaction::{Script, TransactionArgument, TransactionPayload},
    validator_config::ValidatorConfig,
    validator_info::ValidatorInfo,
};
use move_core_types::int256::U256;
use once_cell::sync::Lazy;
use serde_json::{json, Value};
use std::{
    collections::{BTreeMap, BTreeSet},
    sync::Arc,
    time::Duration,
};
use tokio::time::Instant;

const POWER: u64 = 10;
const UNITS: u128 = (POWER as u128) << 32;
const DKG_FAILPOINT: &str = "dkg::process_dkg_start_event";

static GOVERNANCE: Lazy<Vec<u8>> = Lazy::new(|| {
    compile_script(
        "PoCMemberFreeze",
        r#"script {
        use std::features;
        use topo_std::fixed_point64;
        use topo_framework::stake;
        use topo_framework::staking_config;
        use topo_framework::topo_governance;
        fun main(sender: &signer, governed: bool, operation: u8, pool: address) {
            if (governed) {
                let framework = topo_governance::get_signer_testnet_only(sender, @0x1);
                if (operation == 0) {
                    topo_governance::reconfigure(&framework);
                } else if (operation == 1) {
                    topo_governance::force_end_epoch(&framework);
                } else if (operation == 2) {
                    stake::remove_validators(&framework, &vector[pool]);
                } else {
                    assert!(operation == 3, 0);
                    if (features::periodical_reward_rate_decrease_enabled()) {
                        let rate = fixed_point64::create_from_rational(1, 1);
                        staking_config::update_rewards_config(&framework, rate, rate,
                            31536000, fixed_point64::create_from_rational(0, 1));
                    } else {
                        staking_config::update_rewards_rate(&framework, 1, 1);
                    };
                };
            } else {
                // 将发送者传入公开入口，执行真实权限检查；
                // 不在测试网治理签名者适配层提前拒绝。
                assert!(operation == 2, 0);
                stake::remove_validators(sender, &vector[pool]);
            };
        }
    }"#,
    )
});

fn poc_governance_payload(
    governed: bool,
    operation: u8,
    pool: AccountAddress,
) -> TransactionPayload {
    TransactionPayload::Script(Script::new(GOVERNANCE.clone(), vec![], vec![
        TransactionArgument::Bool(governed),
        TransactionArgument::U8(operation),
        TransactionArgument::Address(pool),
    ]))
}

struct Fixture {
    swarm: LocalSwarm,
    client: Client,
    root: Arc<LocalAccount>,
    factory: TransactionFactory,
    pools: Vec<AccountAddress>,
    owners: Vec<LocalAccount>,
    operators: Vec<LocalAccount>,
    voter: LocalAccount,
    attacker: LocalAccount,
}

async fn poc_fixture(nodes: usize) -> Fixture {
    Lazy::force(&GOVERNANCE);
    println!("PoC member fixture A: validators={nodes}, fullnodes=1, Open, minimum=4, min_power=10, initial_power=10, max_power=1000, bond=100 Octa, capacity=8, growth=25%, epoch=3600s, retention=10000, native_bps=0, fee_limit=0, fee_max=10, ordinary DKG=on, Chunky=off; membership gas=1, DKG start/finish governance gas=100, max_gas=2000000; public governance later installs reward rate=1/1");
    let swarm = SwarmBuilder::new_local(nodes)
        .with_aptos()
        .with_num_fullnodes(1)
        .with_init_config(Arc::new(|_, config, _| {
            config.api.failpoints_enabled = true
        }))
        .with_init_genesis_stake(Arc::new(|_, stake| *stake = 100))
        .with_init_genesis_config(Arc::new(|config| {
            config.allow_new_validators = true;
            config.epoch_duration_secs = 3600;
            config.min_stake = 1;
            config.max_stake = 1000;
            config.voting_power_increase_limit = 25;
            config.is_test = true;
            config.consensus_config.enable_validator_txns();
            config.randomness_config_override = Some(OnChainRandomnessConfig::default_enabled());
            config.chunky_dkg_config_override = Some(OnChainChunkyDKGConfig::default_disabled());
            config.poc_genesis_config = Some(Arc::new(|_| PocGenesisConfiguration {
                params: PowerParams {
                    bond_octa_per_ohmp: 100_000_000,
                    min_power: POWER,
                    max_power: 1000,
                    min_validators: 4,
                },
                limits: DeploymentLimits {
                    max_allocations: 4,
                    max_claim_pools: 4,
                    max_upload_users: 32,
                    validator_limit: 8,
                    max_reward_base_octa: 1000,
                    rate_max_num: 1,
                    rate_max_den: 1,
                    fee_max: 10,
                    reward_epoch_limit: 1000,
                },
                deployment_mode: DeploymentMode::Open,
                retention_bps: 10000,
                max_relative_period: 100,
                initial_raw_power: POWER,
                native_reward_bps: 0,
            }));
        }))
        .build()
        .await;
    swarm
        .wait_for_all_nodes_to_catchup_to_epoch(2, Duration::from_secs(90))
        .await
        .unwrap();
    let mut pools = swarm
        .validators()
        .map(|node| node.peer_id())
        .collect::<Vec<_>>();
    pools.sort();
    // 两个场景中，最后一个地址始终保持活跃成员身份。
    let client = swarm
        .validator(*pools.last().unwrap())
        .unwrap()
        .rest_client_with_timeout(Duration::from_secs(10));
    let initial_version = client
        .get_ledger_information()
        .await
        .unwrap()
        .into_inner()
        .version;
    let initial = installed_at(&client, initial_version).await;
    let initial_dkg = resource_at_version::<DKGState>(&client, initial_version).await;
    assert!(initial_dkg.in_progress.is_none());
    let completed = initial_dkg
        .last_completed
        .expect("Initial ordinary DKG must actually complete");
    assert_eq!(completed.target_epoch(), initial.epoch);
    assert!(!completed.transcript.is_empty());
    assert_targets(
        &completed.metadata.target_validator_set,
        &initial.validators,
    );
    let root = swarm.chain_info().root_account();
    let factory = swarm
        .chain_info()
        .transaction_factory()
        .with_gas_unit_price(1)
        .with_max_gas_amount(2_000_000)
        .with_transaction_expiration_time(120);
    let mut public = swarm.chain_info().into_aptos_public_info();
    let mut owners = Vec::new();
    for pool in &pools {
        public.mint(*pool, 100_000_000).await.unwrap();
        let key = swarm
            .validator(*pool)
            .unwrap()
            .account_private_key()
            .as_ref()
            .unwrap()
            .private_key();
        let sequence = client
            .get_account(*pool)
            .await
            .unwrap()
            .into_inner()
            .sequence_number;
        owners.push(LocalAccount::new(*pool, key, sequence));
    }
    // 在所有验证者仍服务于链时，为后续操作的全部角色提供资金。
    let mut operators = Vec::new();
    for _ in 0..3 {
        operators.push(
            public
                .create_and_fund_user_account(100_000_000)
                .await
                .unwrap(),
        );
    }
    let voter = public
        .create_and_fund_user_account(100_000_000)
        .await
        .unwrap();
    let attacker = public
        .create_and_fund_user_account(100_000_000)
        .await
        .unwrap();
    // 测试创世为 root 铸造 u64::MAX。清理自主退出表项时，
    // 原存储费用会退给治理交易发送者；
    // 验证退款前，先为普通钱包余额留出容量。
    let reserve = execute(
        &client,
        &root,
        &factory,
        aptos_stdlib::topo_coin_transfer(*pools.last().unwrap(), 100_000_000),
    )
    .await;
    assert!(reserve.info.success, "{}", reserve.info.vm_status);
    let balance = client
        .view_apt_account_balance_at_version(root.address(), reserve.info.version.0)
        .await
        .unwrap()
        .into_inner();
    assert!(balance <= u64::MAX - 100_000_000);
    println!(
        "Member fixture: root wallet reserved at least 1 TOPO for storage refunds, version={}",
        reserve.info.version.0
    );
    Fixture {
        swarm,
        client,
        root,
        factory,
        pools,
        owners,
        operators,
        voter,
        attacker,
    }
}

fn poc_number(value: &Value) -> u64 {
    value.as_str().unwrap().parse().unwrap()
}

fn poc_address(value: &Value) -> AccountAddress {
    AccountAddress::from_hex_literal(value.as_str().unwrap()).unwrap()
}

async fn poc_resource(f: &Fixture, account: AccountAddress, name: &str, version: u64) -> Value {
    optional_resource_at_version(&f.client, account, name, version)
        .await
        .unwrap_or_else(|| panic!("Missing {name} at {account}, version {version}"))
        .data
}

async fn poc_view(f: &Fixture, name: &str, arguments: Vec<Value>, version: u64) -> Vec<Value> {
    f.client
        .view(
            &ViewRequest {
                function: name.parse().unwrap(),
                type_arguments: vec![],
                arguments,
            },
            Some(version),
        )
        .await
        .unwrap()
        .into_inner()
}

async fn poc_request(
    f: &Fixture,
    handle: AccountAddress,
    pool: AccountAddress,
    version: u64,
) -> Value {
    match f
        .client
        .get_table_item_at_version(handle, "address", "u64", pool.to_hex_literal(), version)
        .await
    {
        Ok(response) => response.into_inner(),
        Err(RestError::Api(error))
            if error.status_code == reqwest::StatusCode::NOT_FOUND
                && error.error.error_code == AptosErrorCode::TableItemNotFound =>
        {
            Value::Null
        },
        Err(error) => panic!("Cannot read voluntary leave for {pool}, version {version}: {error}"),
    }
}

async fn poc_no_plan(f: &Fixture, version: u64) {
    for name in [
        "0x1::stake::EpochPlan",
        "0x1::stake::PrecomputedValidatorSet",
    ] {
        assert!(
            optional_resource_at_version(&f.client, CORE_CODE_ADDRESS, name, version)
                .await
                .is_none()
        );
    }
}

#[derive(Debug, PartialEq)]
struct Snapshot {
    installed: InstalledSnapshot,
    data: BTreeMap<String, Value>,
}

/// v-1/v 快照包含按旧索引记录的表现统计和费用计数。
/// 交易可以扣 gas、递增发送者序列号，但成员队列变更、取消申请
/// 或更换运营者都不得附带结算奖励。
async fn poc_snapshot(f: &Fixture, version: u64) -> Snapshot {
    let mut data = BTreeMap::new();
    for name in [
        "0x1::reconfiguration::Configuration",
        "0x1::reconfiguration_state::State",
        "0x1::poc_power_store::PowerStore",
        "0x1::poc_power_store::PeriodClock",
        "0x1::poc_accounting::AccountingState",
        "0x1::stake::VoluntaryLeaves",
        "0x1::stake::ValidatorPerformance",
        "0x1::stake::PendingTransactionFee",
        "0x1::staking_config::StakingConfig",
        "0x1::staking_config::StakingRewardsConfig",
    ] {
        data.insert(
            name.to_owned(),
            poc_resource(f, CORE_CODE_ADDRESS, name, version).await,
        );
    }
    for name in [
        "0x1::stake::EpochPlan",
        "0x1::stake::PrecomputedValidatorSet",
        "0x1::dkg::DKGState",
    ] {
        data.insert(
            name.to_owned(),
            optional_resource_at_version(&f.client, CORE_CODE_ADDRESS, name, version)
                .await
                .map(|r| r.data)
                .unwrap_or(Value::Null),
        );
    }
    data.insert(
        "fees".to_owned(),
        json!(
            poc_view(
                f,
                "0x1::stake::get_pending_transaction_fee",
                vec![],
                version
            )
            .await
        ),
    );
    let pools_handle =
        poc_address(&data["0x1::poc_accounting::AccountingState"]["pools"]["handle"]);
    let leaves_handle = poc_address(&data["0x1::stake::VoluntaryLeaves"]["requests"]["handle"]);
    for pool in &f.pools {
        for (label, name) in [
            ("stake", "0x1::stake::StakePool"),
            ("config", "0x1::stake::ValidatorConfig"),
            ("allocation", "0x1::poc_accounting::UserAllocation"),
        ] {
            data.insert(
                format!("{label}:{pool}"),
                poc_resource(f, *pool, name, version).await,
            );
        }
        data.insert(
            format!("request:{pool}"),
            poc_request(f, leaves_handle, *pool, version).await,
        );
        data.insert(
            format!("pool:{pool}"),
            json!(
                poc_view(
                    f,
                    "0x1::poc_accounting::get_pool",
                    vec![json!(pool)],
                    version
                )
                .await
            ),
        );
        data.insert(
            format!("position:{pool}"),
            json!(
                poc_view(
                    f,
                    "0x1::poc_accounting::get_position",
                    vec![json!(pool), json!(pool)],
                    version
                )
                .await
            ),
        );
        data.insert(
            format!("ledger:{pool}"),
            f.client
                .get_table_item_at_version(
                    pools_handle,
                    "address",
                    "0x1::poc_accounting::PoolLedger",
                    pool.to_hex_literal(),
                    version,
                )
                .await
                .unwrap()
                .into_inner(),
        );
    }
    Snapshot {
        installed: installed_at(&f.client, version).await,
        data,
    }
}

fn poc_events<'a>(txn: &'a UserTransaction, suffix: &str) -> Vec<&'a Event> {
    txn.events
        .iter()
        .filter(|event| event.typ.to_string().ends_with(suffix))
        .collect()
}

#[derive(Clone, Copy, Debug)]
enum Action {
    Join,
    Leave,
    Cancel,
    Operator(AccountAddress),
    Voter(AccountAddress),
    Remove,
    UnauthorizedRemove,
}

fn poc_member_payload(pool: AccountAddress, action: Action) -> TransactionPayload {
    match action {
        Action::Join => aptos_stdlib::stake_join_validator_set(pool),
        Action::Leave => aptos_stdlib::stake_leave_validator_set(pool),
        Action::Cancel => aptos_stdlib::stake_cancel_leave_validator_set(pool),
        Action::Operator(operator) => aptos_stdlib::stake_set_operator(operator),
        Action::Voter(voter) => aptos_stdlib::stake_set_delegated_voter(voter),
        Action::Remove => poc_governance_payload(true, 2, pool),
        Action::UnauthorizedRemove => poc_governance_payload(false, 2, pool),
    }
}

fn poc_index(infos: &[ValidatorInfo], pool: AccountAddress) -> usize {
    infos
        .iter()
        .position(|info| info.account_address == pool)
        .unwrap()
}

async fn poc_member_change(
    f: &Fixture,
    signer: &LocalAccount,
    pool: AccountAddress,
    action: Action,
) -> u64 {
    let txn = execute(
        &f.client,
        signer,
        &f.factory,
        poc_member_payload(pool, action),
    )
    .await;
    assert!(txn.info.success, "{}", txn.info.vm_status);
    let version = txn.info.version.0;
    let mut expected = poc_snapshot(f, version - 1).await;
    let set = &mut expected.installed.validators;
    let mut expected_event = None;
    match action {
        Action::Join => {
            let config: ValidatorConfig = f
                .client
                .get_account_resource_at_version_bcs(
                    pool,
                    "0x1::stake::ValidatorConfig",
                    version - 1,
                )
                .await
                .unwrap()
                .into_inner();
            set.pending_active.push(ValidatorInfo::new(pool, 0, config));
            expected_event = Some((
                "::stake::JoinValidatorSet",
                json!({"pool_address": pool.to_hex_literal()}),
            ));
        },
        Action::Leave => {
            if let Some(index) = set
                .pending_active
                .iter()
                .position(|info| info.account_address == pool)
            {
                set.pending_active.swap_remove(index);
                // 取消待加入申请按设计不会发出 LeaveValidatorSet 事件。
            } else {
                let index = poc_index(&set.active_validators, pool);
                let info = set.active_validators.swap_remove(index);
                set.pending_inactive.push(info);
                expected.data.insert(
                    format!("request:{pool}"),
                    json!(expected.installed.epoch.to_string()),
                );
                expected_event = Some((
                    "::stake::LeaveValidatorSet",
                    json!({"pool_address": pool.to_hex_literal()}),
                ));
            }
        },
        Action::Cancel => {
            let index = poc_index(&set.pending_inactive, pool);
            set.active_validators
                .push(set.pending_inactive.swap_remove(index));
            expected.data.insert(format!("request:{pool}"), Value::Null);
            expected_event = Some((
                "::stake::VoluntaryLeaveCancelled",
                json!({"pool": pool.to_hex_literal(), "request_epoch": expected.installed.epoch.to_string()}),
            ));
        },
        Action::Operator(operator) => {
            let stake = expected.data.get_mut(&format!("stake:{pool}")).unwrap();
            expected_event = Some((
                "::stake::SetOperator",
                json!({"pool_address": pool.to_hex_literal(), "old_operator": stake["operator_address"], "new_operator": operator.to_hex_literal()}),
            ));
            stake["operator_address"] = json!(operator.to_hex_literal());
        },
        Action::Voter(voter) => {
            expected.data.get_mut(&format!("stake:{pool}")).unwrap()["delegated_voter"] =
                json!(voter.to_hex_literal());
        },
        Action::UnauthorizedRemove => panic!("Unauthorized removal cannot succeed"),
        Action::Remove => {
            expected.data.insert(format!("request:{pool}"), Value::Null);
            if let Some(index) = set
                .active_validators
                .iter()
                .position(|info| info.account_address == pool)
            {
                set.pending_inactive
                    .push(set.active_validators.swap_remove(index));
            }
        },
    }
    assert_eq!(set.total_joining_power, 0);
    assert!(set
        .pending_active
        .iter()
        .all(|member| member.consensus_voting_power() == 0));
    assert_eq!(poc_snapshot(f, version).await, expected);
    let business_events = txn
        .events
        .iter()
        .filter(|event| {
            let typ = event.typ.to_string();
            typ.contains("::stake::")
                || typ.contains("::poc_")
                || typ.contains("::reconfiguration::")
        })
        .collect::<Vec<_>>();
    if let Some((suffix, data)) = expected_event {
        assert_eq!(business_events.len(), 1);
        assert!(business_events[0].typ.to_string().ends_with(suffix));
        assert_eq!(business_events[0].data, data);
    } else {
        assert!(business_events.is_empty());
    }
    println!("Member action={action:?}, signer={}, pool={pool}, epoch={}, version={version}; old weights/indices/statistics/fees/rewards preserved", signer.address(), expected.installed.epoch);
    version
}

fn poc_expected_next(set: &ValidatorSet) -> ValidatorSet {
    let active_validators = set
        .active_validators
        .iter()
        .chain(set.pending_active.iter().rev())
        .enumerate()
        .map(|(index, member)| {
            let mut config = member.config().clone();
            config.validator_index = index as u64;
            ValidatorInfo::new(member.account_address, POWER, config)
        })
        .collect::<Vec<_>>();
    ValidatorSet {
        scheme: set.scheme,
        total_voting_power: active_validators.len() as u128 * POWER as u128,
        total_joining_power: 0,
        active_validators,
        pending_active: vec![],
        pending_inactive: vec![],
    }
}

fn poc_handles(value: &Value, handles: &mut BTreeSet<AccountAddress>) {
    match value {
        Value::Object(fields) => {
            for (name, value) in fields {
                if name == "handle" && value.is_string() {
                    handles.insert(poc_address(value));
                } else {
                    poc_handles(value, handles);
                }
            }
        },
        Value::Array(items) => {
            for item in items {
                poc_handles(item, handles);
            }
        },
        Value::Null | Value::Bool(_) | Value::Number(_) | Value::String(_) => {},
    }
}

fn poc_business_resource(name: &str) -> bool {
    name.contains("::stake::")
        || name.contains("::staking_config::")
        || name.contains("::poc_")
        || name.contains("::dkg::")
        || name.contains("::reconfiguration")
}

async fn poc_rejected(
    f: &Fixture,
    signer: &LocalAccount,
    pool: AccountAddress,
    action: Action,
    module: &str,
    code: u64,
    frozen: Option<&Frozen>,
) {
    let tx = execute(
        &f.client,
        signer,
        &f.factory,
        poc_member_payload(pool, action),
    )
    .await;
    assert_abort(&f.client, &tx, module, code, &f.pools, &f.pools).await;
    let version = tx.info.version.0;
    let before = poc_snapshot(f, version - 1).await;
    assert_eq!(poc_snapshot(f, version).await, before);
    let mut handles = BTreeSet::new();
    for value in before.data.values() {
        poc_handles(value, &mut handles);
    }
    for change in &tx.info.changes {
        match change {
            WriteSetChange::WriteResource(change) => {
                assert!(!poc_business_resource(&change.data.typ.to_string()));
            },
            WriteSetChange::DeleteResource(change) => {
                assert!(!poc_business_resource(&change.resource.to_string()));
            },
            WriteSetChange::WriteTableItem(change) => {
                assert!(
                    !handles.contains(&AccountAddress::from_bytes(change.handle.inner()).unwrap())
                );
            },
            WriteSetChange::DeleteTableItem(change) => {
                assert!(
                    !handles.contains(&AccountAddress::from_bytes(change.handle.inner()).unwrap())
                );
            },
            WriteSetChange::WriteModule(_) | WriteSetChange::DeleteModule(_) => {
                panic!("Rejected membership call wrote a module");
            },
        }
    }
    assert!(tx
        .events
        .iter()
        .all(|event| !poc_business_resource(&event.typ.to_string())));
    if let Some(frozen) = frozen {
        poc_assert_frozen(f, frozen, version).await;
    }
    println!("Member freeze rejection: action={action:?}, signer={}, pool={pool}, frozen={}, module={module}, code={code:#x}, version={version}; exact abort and business writes/events rolled back", signer.address(), frozen.is_some());
}

fn poc_without_statistics(mut state: Snapshot) -> Snapshot {
    for name in [
        "0x1::stake::ValidatorPerformance",
        "0x1::stake::PendingTransactionFee",
        "fees",
    ] {
        state.data.remove(name).unwrap();
    }
    state
}

fn poc_without_transition(mut state: Snapshot) -> Snapshot {
    for name in [
        "0x1::reconfiguration_state::State",
        "0x1::dkg::DKGState",
        "0x1::stake::EpochPlan",
        "0x1::stake::PrecomputedValidatorSet",
    ] {
        state.data.remove(name).unwrap();
    }
    state
}

struct Frozen {
    epoch: u64,
    context: Vec<Vec<u8>>,
    dkg: DKGState,
    target: ValidatorSet,
    stable: Snapshot,
    statistics: Value,
    fees: Value,
    started: Instant,
}

async fn poc_pause(f: &Fixture, paused: bool) {
    for node in f.swarm.validators() {
        node.rest_client_with_timeout(Duration::from_secs(10))
            .set_failpoint(
                DKG_FAILPOINT.to_owned(),
                if paused { "pause" } else { "off" }.to_owned(),
            )
            .await
            .unwrap();
    }
}

async fn poc_freeze(f: &Fixture) -> Frozen {
    poc_pause(f, true).await;
    let started = Instant::now();
    // 七成员 DKG 元数据和缓存 PVS 需要支付存储押金，
    // 因此明确为该生产交易提供足够的存储费用预算。
    // 已安装费用限额为零，此举不改变奖励计算输入。
    let governance_factory = f.factory.clone().with_gas_unit_price(100);
    let tx = execute(
        &f.client,
        &f.root,
        &governance_factory,
        poc_governance_payload(true, 0, CORE_CODE_ADDRESS),
    )
    .await;
    assert!(tx.info.success, "{}", tx.info.vm_status);
    let version = tx.info.version.0;
    let before = poc_snapshot(f, version - 1).await;
    let state = poc_snapshot(f, version).await;
    assert_eq!(before.installed, state.installed);
    let expected = poc_expected_next(&before.installed.validators);
    assert!(expected.active_validators.len() >= 4);
    assert_eq!(
        poc_without_transition(before),
        poc_without_transition(poc_snapshot(f, version).await)
    );
    let dkg = resource_at_version::<DKGState>(&f.client, version).await;
    let session = dkg
        .in_progress
        .as_ref()
        .expect("Public reconfigure must start a real DKG");
    let epoch = state.installed.epoch;
    assert_eq!(session.metadata.dealer_epoch, epoch);
    assert_eq!(session.target_epoch(), epoch + 1);
    assert!(session.transcript.is_empty());
    // dealer 仍来自完整的旧安装委员会，包括待退出成员；
    // 队列中的 swap-remove 不得改变这些成员的旧索引。
    let mut dealers = state.installed.validators.payload().collect::<Vec<_>>();
    dealers.sort_by_key(|member| member.config().validator_index);
    assert_eq!(session.metadata.dealer_validator_set.len(), dealers.len());
    let mut dealer_power = 0_u128;
    for (index, (actual, expected)) in session
        .metadata
        .dealer_validator_set
        .iter()
        .zip(&dealers)
        .enumerate()
    {
        assert_eq!(expected.config().validator_index, index as u64);
        assert_eq!(actual.addr, expected.account_address);
        assert_eq!(actual.pk_bytes, expected.consensus_public_key().to_bytes());
        assert_eq!(actual.voting_power, expected.consensus_voting_power());
        dealer_power += actual.voting_power as u128;
    }
    assert_eq!(dealer_power, state.installed.validators.total_voting_power);
    let (target, fallback): (ValidatorSet, bool) = f
        .client
        .get_account_resource_at_version_bcs(
            CORE_CODE_ADDRESS,
            "0x1::stake::PrecomputedValidatorSet",
            version,
        )
        .await
        .unwrap()
        .into_inner();
    assert!(!fallback);
    assert_eq!(target, expected);
    assert_targets(&session.metadata.target_validator_set, &target);
    assert!(poc_events(&tx, "::stake::PoCRewardCredited").is_empty());
    assert!(poc_events(&tx, "::stake::PoCEpochInstalled").is_empty());
    let cutoff = poc_number(&state.data["0x1::stake::EpochPlan"]["data"]["cutoff_secs"]);
    println!("Member DKG frozen: old_epoch={epoch}, target_epoch={}, selected={}, ordered_target={:?}, cutoff={cutoff}, version={version}", epoch + 1, target.active_validators.len(), target.active_validators.iter().map(|v| v.account_address).collect::<Vec<_>>());
    Frozen {
        epoch,
        context: frozen_context_at(&f.client, version).await,
        dkg,
        target,
        statistics: state.data["0x1::stake::ValidatorPerformance"].clone(),
        fees: state.data["fees"].clone(),
        stable: poc_without_statistics(state),
        started,
    }
}

async fn poc_assert_frozen(f: &Fixture, frozen: &Frozen, version: u64) {
    let state = poc_snapshot(f, version).await;
    let old_stats = frozen.statistics["validators"].as_array().unwrap();
    let new_stats = state.data["0x1::stake::ValidatorPerformance"]["validators"]
        .as_array()
        .unwrap();
    assert_eq!(new_stats.len(), old_stats.len());
    for (old, new) in old_stats.iter().zip(new_stats) {
        for count in ["successful_proposals", "failed_proposals"] {
            assert!(poc_number(&new[count]) >= poc_number(&old[count]));
        }
    }
    // 该 view 返回一个 Move 向量，外层再由 REST 结果向量包装。
    let old_fees = frozen.fees[0].as_array().unwrap();
    let new_fees = state.data["fees"][0].as_array().unwrap();
    assert_eq!(new_fees.len(), old_fees.len());
    for (old, new) in old_fees.iter().zip(new_fees) {
        assert!(poc_number(new) >= poc_number(old));
    }
    assert_eq!(poc_without_statistics(state), frozen.stable);
    assert_eq!(frozen_context_at(&f.client, version).await, frozen.context);
    assert_eq!(
        resource_at_version::<DKGState>(&f.client, version).await,
        frozen.dkg
    );
}

/// 强制完成时使用真实缓存目标；奖励依据旧索引的提案计数
/// 和待结束 Epoch 的已安装奖励率独立计算。
async fn poc_finish(f: &Fixture, frozen: Frozen) -> u64 {
    let governance_factory = f.factory.clone().with_gas_unit_price(100);
    let tx = execute(
        &f.client,
        &f.root,
        &governance_factory,
        poc_governance_payload(true, 1, CORE_CODE_ADDRESS),
    )
    .await;
    assert!(tx.info.success, "{}", tx.info.vm_status);
    let txn = tx;
    let version = txn.info.version.0;
    poc_assert_frozen(f, &frozen, version - 1).await;
    let before = installed_at(&f.client, version - 1).await;
    let after = installed_at(&f.client, version).await;
    assert_eq!(before.epoch, frozen.epoch);
    assert_eq!(after.epoch, frozen.epoch + 1);
    assert_eq!(after.validators, frozen.target);
    assert_eq!(
        poc_number(&before.reward_split["installed_native_reward_bps"]),
        0
    );
    assert_eq!(
        poc_number(&after.reward_split["installed_native_reward_bps"]),
        0
    );
    assert_eq!(before.reward_context.5, 0);
    let selected = after
        .validators
        .active_validators
        .iter()
        .map(|v| v.account_address)
        .collect::<Vec<_>>();
    let perf = poc_resource(
        f,
        CORE_CODE_ADDRESS,
        "0x1::stake::ValidatorPerformance",
        version - 1,
    )
    .await;
    let mut amounts = BTreeMap::new();
    let mut total_reward = 0;
    for member in before.validators.payload() {
        assert_eq!(member.consensus_voting_power(), POWER);
        let statistics = &perf["validators"][member.config().validator_index as usize];
        let success = u128::from(poc_number(&statistics["successful_proposals"]));
        let failures = u128::from(poc_number(&statistics["failed_proposals"]));
        let reward = if success + failures == 0 {
            0
        } else {
            (POWER as u128 * success * before.reward_context.2 as u128
                / ((success + failures) * before.reward_context.3 as u128)) as u64
        };
        assert!(amounts.insert(member.account_address, reward).is_none());
        total_reward += reward;
    }
    assert_eq!(
        poc_events(&txn, "::stake::PoCRewardCredited").len(),
        amounts.len()
    );
    assert_eq!(
        poc_events(&txn, "::stake::PoCRewardSplit").len(),
        amounts.len()
    );
    for pool in &f.pools {
        let old = poc_view(
            f,
            "0x1::poc_accounting::get_pool",
            vec![json!(pool)],
            version - 1,
        )
        .await;
        let new = poc_view(
            f,
            "0x1::poc_accounting::get_pool",
            vec![json!(pool)],
            version,
        )
        .await;
        let reward = amounts.get(pool).copied().unwrap_or(0);
        let delta = (U256::from(reward).repr() << 128u32) / U256::from(UNITS).repr();
        assert_eq!(old[0], json!(UNITS.to_string()));
        assert_eq!(new[0], old[0]);
        assert_eq!(
            poc_number(&new[2]),
            if selected.contains(pool) { POWER } else { 0 }
        );
        assert_eq!(poc_number(&new[3]) - poc_number(&old[3]), reward);
        assert_eq!(
            new[4].as_str().unwrap().parse::<U256>().unwrap().repr()
                - old[4].as_str().unwrap().parse::<U256>().unwrap().repr(),
            delta
        );
        assert_eq!(
            poc_view(f, "0x1::stake::get_stake", vec![json!(pool)], version - 1).await,
            poc_view(f, "0x1::stake::get_stake", vec![json!(pool)], version).await
        );
        for suffix in ["::stake::PoCRewardCredited", "::stake::PoCRewardSplit"] {
            let matching = poc_events(&txn, suffix)
                .into_iter()
                .filter(|event| poc_address(&event.data["pool"]) == *pool)
                .collect::<Vec<_>>();
            assert_eq!(matching.len(), usize::from(amounts.contains_key(pool)));
            if let Some(event) = matching.first() {
                assert_eq!(poc_number(&event.data["closing_epoch"]), before.epoch);
                if suffix.ends_with("PoCRewardCredited") {
                    assert_eq!(
                        event.data,
                        json!({"pool": pool.to_hex_literal(), "closing_epoch": before.epoch.to_string(), "reward_base_octa": POWER.to_string(), "inflation": reward.to_string(), "fee": "0", "delta_index": delta.to_string()})
                    );
                } else {
                    assert_eq!(
                        event.data,
                        json!({"pool": pool.to_hex_literal(), "closing_epoch": before.epoch.to_string(), "native_reward_bps": "0", "total_inflation_octa": reward.to_string(), "active_native_reward_octa": "0", "pending_inactive_native_reward_octa": "0", "poc_inflation_octa": reward.to_string()})
                    );
                }
            }
        }
    }
    let installed = poc_events(&txn, "::stake::PoCEpochInstalled");
    assert_eq!(installed.len(), 1);
    assert_eq!(
        installed[0].data,
        json!({"epoch": after.epoch.to_string(), "period": "0", "selected_count": selected.len().to_string(), "total_power": (selected.len() as u64 * POWER).to_string()})
    );
    assert_eq!(
        poc_events(&txn, "::reconfiguration::NewEpochEvent").len(),
        1
    );
    assert_eq!(after.reward_context.2, after.reward_context.3);
    assert!(after.reward_context.3 > 0);
    if before.reward_context.2 == before.reward_context.3 {
        assert!(
            total_reward > 0,
            "The membership case must retain nonzero historical rewards"
        );
    }
    poc_no_plan(f, version).await;
    assert!(resource_at_version::<DKGState>(&f.client, version)
        .await
        .in_progress
        .is_none());
    poc_pause(f, false).await;
    let state = poc_snapshot(f, version).await;
    for pool in &f.pools {
        assert!(state.data[&format!("request:{pool}")].is_null());
    }
    // 后续签名交易要求新安装的委员会继续提交；
    // 仅收到由旧委员会提交的安装结果，
    // 不足以证明成员替换后已恢复共识。
    let progress = execute(
        &f.client,
        &f.root,
        &f.factory,
        aptos_stdlib::topo_coin_transfer(selected[0], 1),
    )
    .await;
    assert!(progress.info.success, "{}", progress.info.vm_status);
    assert!(progress.info.version.0 > version);
    assert_eq!(
        installed_at(&f.client, progress.info.version.0).await,
        after
    );
    // 仅要求当前成员完成追赶；已移除节点无需持续同步，
    // 重新加入的候选则必须追赶，fullnode 为其保留网络路径。
    for pool in &selected {
        let client = f
            .swarm
            .validator(*pool)
            .unwrap()
            .rest_client_with_timeout(Duration::from_secs(10));
        tokio::time::timeout(
            Duration::from_secs(30),
            client.wait_for_version(progress.info.version.0),
        )
        .await
        .expect("Member catchup exceeded 30 seconds")
        .unwrap();
        assert_eq!(installed_at(&client, version).await, after);
        assert_eq!(installed_at(&client, progress.info.version.0).await, after);
    }
    println!("Member commit: old_epoch={}, new_epoch={}, old_voters={}, members={selected:?}, reward={total_reward}, version={version}", before.epoch, after.epoch, amounts.len());
    println!("Member DKG finished in {:?}; target epoch={}, current nodes can submit and agree on the same version", frozen.started.elapsed(), after.epoch);
    version
}

async fn poc_transition(f: &Fixture) -> u64 {
    let frozen = poc_freeze(f).await;
    poc_finish(f, frozen).await
}

#[tokio::test]
async fn poc_frozen_membership_entries_restore_permissions_and_cached_targets() {
    let f = poc_fixture(7).await;
    let spare = f.pools[0];
    let cancellable = f.pools[1];
    let leaving = f.pools[2];
    // owner、operator 和受委托投票者使用不同地址；
    // 加入时使用的密钥均来自真实创世验证者，并具有真实 BLS PoP。
    for i in 0..3 {
        poc_member_change(
            &f,
            &f.owners[i],
            f.pools[i],
            Action::Operator(f.operators[i].address()),
        )
        .await;
        poc_member_change(
            &f,
            &f.owners[i],
            f.pools[i],
            Action::Voter(f.voter.address()),
        )
        .await;
    }
    let configure = execute(
        &f.client,
        &f.root,
        &f.factory,
        poc_governance_payload(true, 3, CORE_CODE_ADDRESS),
    )
    .await;
    assert!(configure.info.success, "{}", configure.info.vm_status);
    assert_eq!(
        installed_at(&f.client, configure.info.version.0 - 1).await,
        installed_at(&f.client, configure.info.version.0).await
    );

    // 初始清理同时验证授权治理移除确实生效。
    poc_rejected(
        &f,
        &f.attacker,
        spare,
        Action::UnauthorizedRemove,
        "system_addresses",
        0x50003,
        None,
    )
    .await;
    poc_member_change(&f, &f.root, spare, Action::Remove).await;
    let cleaned = poc_transition(&f).await;
    let installed = installed_at(&f.client, cleaned).await;
    assert_eq!(installed.validators.active_validators.len(), 6);
    assert!(!installed
        .validators
        .active_validators
        .iter()
        .any(|v| v.account_address == spare));
    println!("Member initial cleanup installed six validators; inactive joiner={spare}, version={cleaned}");

    // 同一个非活跃池先在冻结前申请加入，再通过公开入口取消待加入申请，
    // 使后续冻结期间的加入请求仍满足业务条件。
    for unauthorized in [&f.owners[0], &f.voter, &f.attacker] {
        poc_rejected(
            &f,
            unauthorized,
            spare,
            Action::Join,
            "stake",
            0x40009,
            None,
        )
        .await;
    }
    poc_member_change(&f, &f.operators[0], spare, Action::Join).await;
    poc_member_change(&f, &f.operators[0], spare, Action::Leave).await;
    for unauthorized in [&f.owners[2], &f.voter, &f.attacker] {
        poc_rejected(
            &f,
            unauthorized,
            leaving,
            Action::Leave,
            "stake",
            0x40009,
            None,
        )
        .await;
    }
    poc_member_change(&f, &f.operators[2], leaving, Action::Leave).await;
    poc_member_change(&f, &f.operators[2], leaving, Action::Cancel).await;
    poc_member_change(&f, &f.operators[1], cancellable, Action::Leave).await;
    for unauthorized in [&f.owners[1], &f.voter, &f.attacker] {
        poc_rejected(
            &f,
            unauthorized,
            cancellable,
            Action::Cancel,
            "stake",
            0x40009,
            None,
        )
        .await;
    }
    poc_member_change(&f, &f.operators[1], cancellable, Action::Cancel).await;
    poc_rejected(
        &f,
        &f.attacker,
        leaving,
        Action::UnauthorizedRemove,
        "system_addresses",
        0x50003,
        None,
    )
    .await;

    // 旧委员会为 6 人，一人待退出使目标变为 5 人，再移除一名活跃成员后仍有 4 人；
    // 因此冻结矩阵中的每个请求在完全相同的业务状态下均满足其他合法条件，
    // 无需注入损坏状态。
    poc_member_change(&f, &f.operators[1], cancellable, Action::Leave).await;
    let frozen = poc_freeze(&f).await;
    assert_eq!(
        frozen.stable.installed.validators.active_validators.len(),
        5
    );
    assert_eq!(frozen.stable.installed.validators.pending_inactive.len(), 1);
    assert_eq!(frozen.target.active_validators.len(), 5);
    assert_eq!(frozen.stable.installed.validators.total_voting_power, 60);
    for (pool, action, operator) in [
        (spare, Action::Join, &f.operators[0]),
        (leaving, Action::Leave, &f.operators[2]),
        (cancellable, Action::Cancel, &f.operators[1]),
    ] {
        poc_rejected(&f, operator, pool, action, "stake", 0x30014, Some(&frozen)).await;
        // 冻结检查先于运营者权限和自主退出申请检查。
        poc_rejected(
            &f,
            &f.attacker,
            pool,
            action,
            "stake",
            0x30014,
            Some(&frozen),
        )
        .await;
    }
    poc_rejected(
        &f,
        &f.root,
        leaving,
        Action::Remove,
        "stake",
        0x30014,
        Some(&frozen),
    )
    .await;
    poc_rejected(
        &f,
        &f.attacker,
        leaving,
        Action::UnauthorizedRemove,
        "stake",
        0x30014,
        Some(&frozen),
    )
    .await;
    let completed = poc_finish(&f, frozen).await;
    assert_eq!(
        installed_at(&f.client, completed)
            .await
            .validators
            .active_validators
            .len(),
        5
    );

    // 完成换届会消耗旧自主退出申请，此时的 0x30023 表示业务状态过期，
    // 而非仍处于冻结。让同一真实节点重新加入，
    // 再创建当前 Epoch 的申请，验证取消功能已恢复。
    poc_rejected(
        &f,
        &f.operators[1],
        cancellable,
        Action::Cancel,
        "stake",
        0x30023,
        None,
    )
    .await;
    poc_member_change(&f, &f.operators[1], cancellable, Action::Join).await;
    let rejoined = poc_transition(&f).await;
    assert_eq!(
        installed_at(&f.client, rejoined)
            .await
            .validators
            .active_validators
            .len(),
        6
    );
    poc_member_change(&f, &f.operators[1], cancellable, Action::Leave).await;
    poc_member_change(&f, &f.operators[1], cancellable, Action::Cancel).await;

    // 重试先前被阻止的合法加入、退出和治理移除请求。
    // 取消退出先恢复原索引，随后治理移除该活跃成员，
    // 最终缓存目标中则加入备用成员。
    poc_member_change(&f, &f.operators[0], spare, Action::Join).await;
    poc_member_change(&f, &f.operators[2], leaving, Action::Leave).await;
    poc_member_change(&f, &f.operators[2], leaving, Action::Cancel).await;
    poc_member_change(&f, &f.root, leaving, Action::Remove).await;
    poc_rejected(
        &f,
        &f.operators[2],
        leaving,
        Action::Cancel,
        "stake",
        0x30023,
        None,
    )
    .await;
    let final_version = poc_transition(&f).await;
    let final_set = installed_at(&f.client, final_version).await.validators;
    assert_eq!(final_set.active_validators.len(), 6);
    assert!(final_set
        .active_validators
        .iter()
        .any(|v| v.account_address == spare));
    assert!(!final_set
        .active_validators
        .iter()
        .any(|v| v.account_address == leaving));
}

/// 证明 leave 执行的是取消待加入分支，而非安排活跃验证者退出；
/// 此分支不会创建自主退出标记。
async fn poc_cancel_pending_join(
    f: &Fixture,
    operator: &LocalAccount,
    pool: AccountAddress,
) -> u64 {
    let version = poc_member_change(f, operator, pool, Action::Leave).await;
    let before = installed_at(&f.client, version - 1).await;
    let after = installed_at(&f.client, version).await;
    assert_eq!(before.validators.pending_active.len(), 1);
    assert_eq!(before.validators.pending_active[0].account_address, pool);
    assert_eq!(
        before.validators.pending_active[0].consensus_voting_power(),
        0
    );
    assert!(before.validators.pending_inactive.is_empty());
    assert!(after.validators.pending_active.is_empty());
    assert!(after.validators.pending_inactive.is_empty());
    assert_eq!(
        before.validators.active_validators,
        after.validators.active_validators
    );
    assert_eq!(after.validators.active_validators.len(), 4);
    assert_eq!(after.validators.total_voting_power, 40);
    assert_eq!(after.validators.total_joining_power, 0);
    assert!(!after
        .validators
        .active_validators
        .iter()
        .any(|v| v.account_address == pool));
    assert!(poc_snapshot(f, version).await.data[&format!("request:{pool}")].is_null());
    println!("Pending join cancelled: pool={pool}, operator={}, epoch={}, current=4, pending=0, old total=40, joining=0, version={version}", operator.address(), after.epoch);
    version
}

#[tokio::test]
async fn poc_frozen_pending_join_cancellation_resumes_for_same_candidate() {
    // 五人是满足本场景的最小真实 Open 委员会：
    // 一名成员退任后，仍可保留要求的四个背景验证者运行。
    let f = poc_fixture(5).await;
    let candidate = f.pools[0];
    let operator = &f.operators[0];
    poc_member_change(
        &f,
        &f.owners[0],
        candidate,
        Action::Operator(operator.address()),
    )
    .await;
    poc_member_change(
        &f,
        &f.owners[0],
        candidate,
        Action::Voter(f.voter.address()),
    )
    .await;
    let configure = execute(
        &f.client,
        &f.root,
        &f.factory,
        poc_governance_payload(true, 3, CORE_CODE_ADDRESS),
    )
    .await;
    assert!(configure.info.success, "{}", configure.info.vm_status);
    assert_eq!(
        installed_at(&f.client, configure.info.version.0 - 1).await,
        installed_at(&f.client, configure.info.version.0).await
    );

    poc_member_change(&f, &f.root, candidate, Action::Remove).await;
    let retired = poc_transition(&f).await;
    let initial = installed_at(&f.client, retired).await;
    assert_eq!(initial.validators.active_validators.len(), 4);
    assert!(!initial
        .validators
        .active_validators
        .iter()
        .any(|v| v.account_address == candidate));
    println!(
        "Pending-join fixture cleanup: retired candidate={candidate}, current=4, version={retired}"
    );

    poc_member_change(&f, operator, candidate, Action::Join).await;
    for unauthorized in [&f.owners[0], &f.voter, &f.attacker] {
        poc_rejected(
            &f,
            unauthorized,
            candidate,
            Action::Leave,
            "stake",
            0x40009,
            None,
        )
        .await;
    }
    poc_cancel_pending_join(&f, operator, candidate).await;
    poc_member_change(&f, operator, candidate, Action::Join).await;
    let frozen = poc_freeze(&f).await;
    let pending = &frozen.stable.installed.validators.pending_active;
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].account_address, candidate);
    assert_eq!(pending[0].consensus_voting_power(), 0);
    assert_eq!(frozen.stable.installed.validators.total_joining_power, 0);
    assert_eq!(frozen.stable.installed.validators.total_voting_power, 40);
    assert!(frozen
        .stable
        .installed
        .validators
        .pending_inactive
        .is_empty());
    assert_eq!(frozen.target.active_validators.len(), 5);
    assert_eq!(frozen.target.total_voting_power, 50);
    assert!(frozen
        .target
        .active_validators
        .iter()
        .any(|v| v.account_address == candidate && v.consensus_voting_power() == POWER));
    for actor in [operator, &f.owners[0], &f.voter, &f.attacker] {
        poc_rejected(
            &f,
            actor,
            candidate,
            Action::Leave,
            "stake",
            0x30014,
            Some(&frozen),
        )
        .await;
    }
    let completed = poc_finish(&f, frozen).await;
    let installed = installed_at(&f.client, completed).await;
    assert_eq!(installed.validators.active_validators.len(), 5);
    assert!(installed.validators.pending_active.is_empty());
    assert!(installed
        .validators
        .active_validators
        .iter()
        .any(|v| v.account_address == candidate));

    // 完成计划后 C 已成为活跃成员，此时退出会执行另一个分支；
    // 因此先通过治理移除 C 并提交，再由同一池和运营者
    // 创建新的待加入申请，随后重试。
    poc_member_change(&f, &f.root, candidate, Action::Remove).await;
    let retired_again = poc_transition(&f).await;
    assert_eq!(
        installed_at(&f.client, retired_again)
            .await
            .validators
            .active_validators
            .len(),
        4
    );
    poc_member_change(&f, operator, candidate, Action::Join).await;
    for unauthorized in [&f.owners[0], &f.voter, &f.attacker] {
        poc_rejected(
            &f,
            unauthorized,
            candidate,
            Action::Leave,
            "stake",
            0x40009,
            None,
        )
        .await;
    }
    poc_cancel_pending_join(&f, operator, candidate).await;
    // 当前四名成员提交下一 Epoch 和后续转账；
    // 不要求已退任的候选持续同步。
    let final_version = poc_transition(&f).await;
    let final_set = installed_at(&f.client, final_version).await.validators;
    assert_eq!(final_set.active_validators.len(), 4);
    assert_eq!(final_set.total_voting_power, 40);
    assert!(!final_set
        .active_validators
        .iter()
        .any(|v| v.account_address == candidate));
}
