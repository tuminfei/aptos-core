// Copyright (c) Aptos Foundation
// Licensed pursuant to the Innovation-Enabling Source Code License, available at https://github.com/aptos-labs/aptos-core/blob/main/LICENSE

//! WGT-04 / WGT-06：竞争候选、运营者轮换和取消申请。
//! 所有身份均属于真实节点或已注资账户；成员变更通过公开签名交易执行，
//! Epoch 则通过同步治理路径推进。

use super::{
    defaults::{installed_at, InstalledSnapshot},
    optional_resource_at_version,
    transactions::{assert_abort, compile_script, execute},
};
use crate::smoke_test_environment::SwarmBuilder;
use aptos_api_types::{AptosErrorCode, Event, UserTransaction, ViewRequest, WriteSetChange};
use aptos_cached_packages::aptos_stdlib;
use aptos_crypto::{bls12381, Uniform};
use aptos_forge::{LocalSwarm, NodeExt, Swarm};
use aptos_genesis::poc::{DeploymentMode, PocGenesisConfiguration, PowerParams};
use aptos_rest_client::{error::RestError, Client};
use aptos_sdk::{transaction_builder::TransactionFactory, types::LocalAccount};
use aptos_types::{
    account_address::AccountAddress,
    account_config::CORE_CODE_ADDRESS,
    on_chain_config::{OnChainChunkyDKGConfig, OnChainRandomnessConfig, ValidatorSet},
    transaction::{Script, TransactionArgument, TransactionPayload},
    validator_config::ValidatorConfig,
    validator_info::ValidatorInfo,
};
use move_core_types::int256::U256;
use once_cell::sync::Lazy;
use serde_json::{json, Value};
use std::{collections::BTreeMap, sync::Arc, time::Duration};

const POWER: u64 = 10;
const UNITS: u128 = (POWER as u128) << 16;

static GOVERNANCE: Lazy<Vec<u8>> = Lazy::new(|| {
    compile_script(
        "PoCMemberLifecycle",
        r#"
script {
    use std::features;
    use topo_std::fixed_point64;
    use topo_framework::stake;
    use topo_framework::staking_config;
    use topo_framework::topo_governance;

    fun main(root: &signer, operation: u8, pool: address) {
        let framework = topo_governance::get_signer_testnet_only(root, @0x1);
        if (operation == 2) {
            stake::remove_validators(&framework, &vector[pool]);
        } else {
            assert!(operation == 0 || operation == 1, 0);
            if (operation == 1) {
                // 显式设置 A 配置的上限，先产生非零历史奖励，
                // 再测试那些不得触发 Epoch 结算的操作。
                if (features::periodical_reward_rate_decrease_enabled()) {
                    staking_config::update_rewards_config(&framework,
                        fixed_point64::create_from_rational(1, 1),
                        fixed_point64::create_from_rational(1, 1),
                        31536000, fixed_point64::create_from_rational(0, 1));
                } else {
                    staking_config::update_rewards_rate(&framework, 1, 1);
                };
            };
            topo_governance::reconfigure(&framework);
        };
    }
}
"#,
    )
});

fn poc_governance_payload(operation: u8, pool: AccountAddress) -> TransactionPayload {
    TransactionPayload::Script(Script::new(GOVERNANCE.clone(), vec![], vec![
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
    // 已注册但无算力的池仅用于队列容量测试，没有对应运行节点；
    // 在任何委员会安装前，都必须取消其待加入申请。
    auxiliary_pools: Vec<AccountAddress>,
}

async fn poc_fixture(nodes: usize) -> Fixture {
    poc_fixture_with_limit(nodes, 8).await
}

async fn poc_fixture_with_limit(nodes: usize, validator_limit: u64) -> Fixture {
    Lazy::force(&GOVERNANCE);
    assert!(nodes as u64 <= validator_limit);
    println!("PoC member fixture A: validators={nodes}, fullnodes=1, Open, minimum=4, min_power=10, initial_power=10, max_power=1000, bond=100 Octa, capacity={validator_limit}, growth=25%, epoch=3600s, retention=10000, native_bps=0, fee_limit=0, fee_max=10, ordinary/Chunky DKG=off; public governance later installs reward rate=1/1");
    let swarm = SwarmBuilder::new_local(nodes)
        .with_aptos()
        .with_num_fullnodes(1)
        .with_init_genesis_stake(Arc::new(|_, stake| *stake = 100))
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
                    bond_octa_per_ohmp: 100_000_000,
                    min_power: POWER,
                    max_power: 1000,
                    min_validators: 4,
                },

                deployment_mode: DeploymentMode::Open,
                retention_bps: 10000,
                initial_raw_power: POWER,
            }));
        }))
        .build()
        .await;
    super::configure_fixture(&swarm, [4, 4, 32, validator_limit, 10], 0).await;
    let mut pools = swarm
        .validators()
        .map(|node| node.peer_id())
        .collect::<Vec<_>>();
    pools.sort();
    // 每个场景中，最后一个地址始终保留在已安装委员会中。
    let client = swarm
        .validator(*pools.last().unwrap())
        .unwrap()
        .rest_client_with_timeout(Duration::from_secs(10));
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
        auxiliary_pools: vec![],
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
    ] {
        data.insert(
            name.to_owned(),
            poc_resource(f, CORE_CODE_ADDRESS, name, version).await,
        );
    }
    poc_no_plan(f, version).await;
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
    for pool in &f.auxiliary_pools {
        for name in ["StakePool", "ValidatorConfig", "OwnerCapability"] {
            data.insert(
                format!("aux:{pool}:{name}"),
                poc_resource(f, *pool, &format!("0x1::stake::{name}"), version).await,
            );
        }
        data.insert(
            format!("aux-request:{pool}"),
            poc_request(f, leaves_handle, *pool, version).await,
        );
        data.insert(
            format!("aux-allocation:{pool}"),
            optional_resource_at_version(
                &f.client,
                *pool,
                "0x1::poc_accounting::UserAllocation",
                version,
            )
            .await
            .map(|r| r.data)
            .unwrap_or(Value::Null),
        );
        data.insert(
            format!("aux-power:{pool}"),
            json!(
                poc_view(
                    f,
                    "0x1::poc_power_store::get_accounting_snapshot",
                    vec![json!(pool)],
                    version
                )
                .await
            ),
        );
        data.insert(
            format!("aux-enabled:{pool}"),
            json!(
                poc_view(
                    f,
                    "0x1::poc_accounting::pool_enabled",
                    vec![json!(pool)],
                    version
                )
                .await
            ),
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
}

fn poc_member_payload(pool: AccountAddress, action: Action) -> TransactionPayload {
    match action {
        Action::Join => aptos_stdlib::stake_join_validator_set(pool),
        Action::Leave => aptos_stdlib::stake_leave_validator_set(pool),
        Action::Cancel => aptos_stdlib::stake_cancel_leave_validator_set(pool),
        Action::Operator(operator) => aptos_stdlib::stake_set_operator(operator),
        Action::Voter(voter) => aptos_stdlib::stake_set_delegated_voter(voter),
        Action::Remove => poc_governance_payload(2, pool),
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

async fn poc_rejected(
    f: &Fixture,
    signer: &LocalAccount,
    pool: AccountAddress,
    action: Action,
    code: u64,
) -> UserTransaction {
    let txn = execute(
        &f.client,
        signer,
        &f.factory,
        poc_member_payload(pool, action),
    )
    .await;
    assert_abort(&f.client, &txn, "stake", code, &f.pools, &f.pools).await;
    let before = poc_snapshot(f, txn.info.version.0 - 1).await;
    assert_eq!(before, poc_snapshot(f, txn.info.version.0).await);
    let leave_handle =
        poc_address(&before.data["0x1::stake::VoluntaryLeaves"]["requests"]["handle"]);
    for change in &txn.info.changes {
        match change {
            WriteSetChange::WriteResource(change) => {
                assert!(!change.data.typ.to_string().contains("::stake::"))
            },
            WriteSetChange::DeleteResource(change) => {
                assert!(!change.resource.to_string().contains("::stake::"))
            },
            WriteSetChange::WriteTableItem(change) => assert_ne!(
                AccountAddress::from_bytes(change.handle.inner()).unwrap(),
                leave_handle
            ),
            WriteSetChange::DeleteTableItem(change) => assert_ne!(
                AccountAddress::from_bytes(change.handle.inner()).unwrap(),
                leave_handle
            ),
            WriteSetChange::WriteModule(_) | WriteSetChange::DeleteModule(_) => {
                panic!("Rejected member transaction changed a module")
            },
        }
    }
    assert!(txn
        .events
        .iter()
        .all(|event| !event.typ.to_string().contains("::stake::")));
    txn
}

async fn poc_preview(f: &Fixture, version: u64) -> Value {
    let installed = installed_at(&f.client, version).await;
    let timestamp = poc_resource(
        f,
        CORE_CODE_ADDRESS,
        "0x1::timestamp::CurrentTimeMicroseconds",
        version,
    )
    .await;
    let result = poc_view(
        f,
        "0x1::stake::preview_epoch_transition",
        vec![
            json!((installed.epoch + 1).to_string()),
            json!((poc_number(&timestamp["microseconds"]) / 1_000_000).to_string()),
        ],
        version,
    )
    .await;
    assert_eq!(result.len(), 1);
    assert_eq!(poc_number(&result[0]["reason"]), 0);
    assert_eq!(poc_number(&result[0]["epoch"]), installed.epoch + 1);
    poc_no_plan(f, version).await;
    result.into_iter().next().unwrap()
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

/// 根据旧投票成员的旧索引独立计算结算结果；
/// 新加入节点不获旧期奖励，待退出成员仍恰好结算一次旧期奖励。
async fn poc_commit(f: &Fixture, operation: u8, selected: &[AccountAddress]) -> u64 {
    let latest = f
        .client
        .get_ledger_information()
        .await
        .unwrap()
        .into_inner();
    let intended = installed_at(&f.client, latest.version).await;
    let expected_set = poc_expected_next(&intended.validators);
    assert_eq!(expected_set.active_validators.len(), selected.len());
    for pool in selected {
        assert!(expected_set
            .active_validators
            .iter()
            .any(|member| member.account_address == *pool));
    }
    let txn = execute(
        &f.client,
        &f.root,
        &f.factory,
        poc_governance_payload(operation, CORE_CODE_ADDRESS),
    )
    .await;
    assert!(txn.info.success, "{}", txn.info.vm_status);
    let version = txn.info.version.0;
    let before = installed_at(&f.client, version - 1).await;
    let after = installed_at(&f.client, version).await;
    assert_eq!(
        before, intended,
        "Membership installed before the intended governance transaction"
    );
    assert_eq!(after.epoch, before.epoch + 1);
    assert_eq!(after.validators, expected_set);
    assert_eq!(
        poc_number(&before.reward_split["installed_native_reward_bps"]),
        0
    );
    assert_eq!(
        poc_number(&after.reward_split["installed_native_reward_bps"]),
        0
    );
    assert_eq!(before.reward_context.5, 0);
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
    if operation == 0 {
        assert!(
            total_reward > 0,
            "The membership case must retain nonzero historical rewards"
        );
    }
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
    for pool in selected {
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
    version
}

async fn poc_prepare_four(f: &Fixture, spare_count: usize) {
    poc_commit(f, 1, &f.pools).await;
    for index in 0..spare_count {
        poc_member_change(f, &f.owners[index], f.pools[index], Action::Leave).await;
    }
    let version = poc_commit(f, 0, &f.pools[spare_count..]).await;
    let state = poc_snapshot(f, version).await;
    assert_eq!(state.installed.validators.active_validators.len(), 4);
    assert_eq!(state.installed.validators.total_voting_power, 40);
    assert!(f
        .pools
        .iter()
        .any(|pool| poc_number(&state.data[&format!("pool:{pool}")][3]) > 0));
}

#[tokio::test]
async fn poc_competing_candidates_cancel_extra_and_complete_replacement() {
    let f = poc_fixture(6).await;
    poc_prepare_four(&f, 2).await;
    let replacement = f.pools[0];
    let extra = f.pools[1];
    let outgoing = f.pools[2];
    let first_join = poc_member_change(&f, &f.owners[0], replacement, Action::Join).await;
    let singly_queued = installed_at(&f.client, first_join).await;
    assert_eq!(singly_queued.validators.total_voting_power, 40);
    assert_eq!(singly_queued.validators.total_joining_power, 0);
    assert_eq!(singly_queued.validators.pending_active.len(), 1);
    assert_eq!(
        singly_queued.validators.pending_active[0].account_address,
        replacement
    );
    assert_eq!(
        singly_queued.validators.pending_active[0].consensus_voting_power(),
        0
    );
    let queued_version = poc_member_change(&f, &f.owners[1], extra, Action::Join).await;
    let queued = installed_at(&f.client, queued_version).await;
    assert_eq!(queued.validators.total_voting_power, 40);
    assert_eq!(queued.validators.pending_active.len(), 2);
    assert_eq!(queued.validators.total_joining_power, 0);
    assert_eq!(
        queued
            .validators
            .pending_active
            .iter()
            .map(|member| member.account_address)
            .collect::<Vec<_>>(),
        vec![replacement, extra]
    );
    assert!(queued
        .validators
        .pending_active
        .iter()
        .all(|member| member.consensus_voting_power() == 0));
    // 独立计算：增长需求为 20，预算 floor(40*25/100)=10；
    // 每名候选分得 floor(10*10/20)=5，低于 min_power=10。
    // 未用增长预算不重新分配，因此此时移除一名旧成员不安全。
    let budget = 40u64 * 25 / 100;
    let each = POWER * budget / (2 * POWER);
    assert_eq!(each, 5);
    let preview = poc_preview(&f, queued_version).await;
    assert_eq!(
        preview["validator_set"]["active_validators"]
            .as_array()
            .unwrap()
            .len(),
        4
    );
    assert_eq!(
        poc_number(&preview["validator_set"]["total_voting_power"]),
        40
    );
    for pool in [replacement, extra] {
        let target = preview["targets"]
            .as_array()
            .unwrap()
            .iter()
            .find(|target| poc_address(&target["pool"]) == pool)
            .unwrap();
        assert_eq!(target["units"], json!(UNITS.to_string()));
        assert_eq!(poc_number(&target["power"]), 0);
        assert_eq!(poc_number(&target["reward_base_octa"]), 0);
    }
    let rejected = poc_rejected(&f, &f.owners[2], outgoing, Action::Leave, 0x30022).await;
    assert!(rejected.info.gas_used.0 > 0);
    assert!(poc_events(&rejected, "::stake::LeaveValidatorSet").is_empty());
    assert!(poc_events(&rejected, "::stake::PoCRewardCredited").is_empty());
    assert!(poc_events(&rejected, "::stake::PoCRewardSplit").is_empty());
    assert!(poc_events(&rejected, "::stake::PoCEpochInstalled").is_empty());
    assert!(poc_events(&rejected, "::reconfiguration::NewEpochEvent").is_empty());
    let before_rejection = poc_snapshot(&f, rejected.info.version.0 - 1).await;
    assert_eq!(
        poc_snapshot(&f, rejected.info.version.0).await,
        before_rejection
    );
    assert_eq!(before_rejection.installed.validators, queued.validators);
    let cancelled = poc_member_change(&f, &f.owners[1], extra, Action::Leave).await;
    let after_cancel = installed_at(&f.client, cancelled).await;
    assert_eq!(after_cancel.validators.total_voting_power, 40);
    assert_eq!(after_cancel.validators.total_joining_power, 0);
    assert_eq!(after_cancel.validators.pending_active.len(), 1);
    assert_eq!(
        after_cancel.validators.pending_active[0].account_address,
        replacement
    );
    assert_eq!(
        after_cancel.validators.pending_active[0].consensus_voting_power(),
        0
    );
    let ready = poc_preview(&f, cancelled).await;
    assert_eq!(
        poc_number(&ready["validator_set"]["total_voting_power"]),
        50
    );
    let target = ready["targets"]
        .as_array()
        .unwrap()
        .iter()
        .find(|target| poc_address(&target["pool"]) == replacement)
        .unwrap();
    assert_eq!(poc_number(&target["power"]), POWER);
    let left = poc_member_change(&f, &f.owners[2], outgoing, Action::Leave).await;
    let after_leave = installed_at(&f.client, left).await;
    assert_eq!(after_leave.validators.active_validators.len(), 3);
    assert_eq!(after_leave.validators.pending_inactive.len(), 1);
    assert_eq!(after_leave.validators.pending_active.len(), 1);
    assert_eq!(after_leave.validators.total_voting_power, 40);
    assert_eq!(after_leave.validators.total_joining_power, 0);
    let ready = poc_preview(&f, left).await;
    assert_eq!(
        poc_number(&ready["validator_set"]["total_voting_power"]),
        40
    );
    let selected = [replacement, f.pools[3], f.pools[4], f.pools[5]];
    let final_version = poc_commit(&f, 0, &selected).await;
    let final_state = poc_snapshot(&f, final_version).await;
    assert_eq!(final_state.installed.validators.active_validators.len(), 4);
    assert!(final_state.installed.validators.pending_active.is_empty());
    assert!(final_state.installed.validators.pending_inactive.is_empty());
    assert_eq!(final_state.installed.validators.total_voting_power, 40);
    assert_eq!(final_state.installed.validators.total_joining_power, 0);
    let mut installed_members = final_state
        .installed
        .validators
        .active_validators
        .iter()
        .map(|member| member.account_address)
        .collect::<Vec<_>>();
    installed_members.sort();
    let mut expected_members = selected.to_vec();
    expected_members.sort();
    assert_eq!(installed_members, expected_members);
    assert_eq!(
        poc_number(&final_state.data[&format!("pool:{replacement}")][2]),
        POWER
    );
    assert_eq!(
        poc_number(&final_state.data[&format!("pool:{extra}")][2]),
        0
    );
    assert_eq!(
        poc_number(&final_state.data[&format!("pool:{outgoing}")][2]),
        0
    );

    // 在最终安装版本上逐节点读取完整安装快照和核心账本资源，
    // 证明替补节点恢复共识后看到相同的委员会、奖励上下文、分流和池账本。
    let accounting = &final_state.data["0x1::poc_accounting::AccountingState"];
    for pool in selected {
        let client = f
            .swarm
            .validator(pool)
            .unwrap()
            .rest_client_with_timeout(Duration::from_secs(10));
        assert_eq!(
            installed_at(&client, final_version).await,
            final_state.installed
        );
        assert_eq!(
            client
                .get_account_resource_at_version(
                    CORE_CODE_ADDRESS,
                    "0x1::poc_accounting::AccountingState",
                    final_version,
                )
                .await
                .unwrap()
                .into_inner()
                .unwrap()
                .data,
            *accounting
        );
    }
}

#[tokio::test]
async fn poc_operator_rotation_cancel_restores_indices_and_governance_revokes_it() {
    let f = poc_fixture(5).await;
    let replacement = f.pools[0];
    let outgoing = f.pools[1];
    let mut public = f.swarm.chain_info().into_aptos_public_info();
    let old_operator = public
        .create_and_fund_user_account(100_000_000)
        .await
        .unwrap();
    let new_operator = public
        .create_and_fund_user_account(100_000_000)
        .await
        .unwrap();
    let voter = public
        .create_and_fund_user_account(100_000_000)
        .await
        .unwrap();
    // Forge 的公开客户端使用首个创建的节点；
    // 在所有创世成员仍活跃、该节点尚未退任时，完成所有钱包准备。
    poc_prepare_four(&f, 1).await;
    poc_member_change(
        &f,
        &f.owners[1],
        outgoing,
        Action::Operator(old_operator.address()),
    )
    .await;
    poc_member_change(&f, &f.owners[1], outgoing, Action::Voter(voter.address())).await;
    let queued_version = poc_member_change(&f, &f.owners[0], replacement, Action::Join).await;
    let before_leave = installed_at(&f.client, queued_version).await;
    let old_info = before_leave.validators.active_validators
        [poc_index(&before_leave.validators.active_validators, outgoing)]
    .clone();
    poc_member_change(&f, &old_operator, outgoing, Action::Leave).await;
    // 在真实可取消申请仍存在时变更权限；
    // 本矩阵中的 owner、operator 和受委托投票者使用不同地址。
    poc_member_change(
        &f,
        &f.owners[1],
        outgoing,
        Action::Operator(new_operator.address()),
    )
    .await;
    for signer in [&old_operator, &f.owners[1], &voter] {
        poc_rejected(&f, signer, outgoing, Action::Cancel, 0x40009).await;
    }
    let restored_version = poc_member_change(&f, &new_operator, outgoing, Action::Cancel).await;
    let restored = installed_at(&f.client, restored_version).await;
    assert_eq!(
        restored.validators.total_voting_power,
        before_leave.validators.total_voting_power
    );
    assert_eq!(restored.validators.total_joining_power, 0);
    assert_eq!(
        restored.validators.active_validators
            [poc_index(&restored.validators.active_validators, outgoing)],
        old_info
    );
    // 取消申请会将原 ValidatorInfo 追加到向量末尾，无需恢复原向量位置；
    // 但必须保留原共识索引和权重。
    for member in &before_leave.validators.active_validators {
        assert_eq!(
            restored.validators.active_validators[poc_index(
                &restored.validators.active_validators,
                member.account_address
            )],
            *member
        );
    }
    for signer in [&old_operator, &f.owners[1], &voter] {
        poc_rejected(&f, signer, outgoing, Action::Leave, 0x40009).await;
    }
    poc_member_change(&f, &new_operator, outgoing, Action::Leave).await;
    poc_member_change(&f, &new_operator, outgoing, Action::Cancel).await;
    poc_member_change(&f, &new_operator, outgoing, Action::Leave).await;
    // 即使池已处于 pending inactive，治理仍会撤销其自主退出标记；
    // 新运营者保留运营权限，
    // 但无权撤销该治理决定。
    poc_member_change(&f, &f.root, outgoing, Action::Remove).await;
    poc_rejected(&f, &new_operator, outgoing, Action::Cancel, 0x30023).await;
    poc_rejected(&f, &old_operator, outgoing, Action::Cancel, 0x40009).await;
    poc_commit(&f, 0, &[replacement, f.pools[2], f.pools[3], f.pools[4]]).await;
}

async fn poc_register_queue_candidate(f: &mut Fixture) -> LocalAccount {
    let candidate = f
        .swarm
        .chain_info()
        .into_aptos_public_info()
        // 每笔准备交易在 prologue 中最多预留 2M * 100 Octa；
        // 余额须覆盖两笔准备交易及后续队列操作。
        .create_and_fund_user_account(1_000_000_000)
        .await
        .unwrap();
    let pool = candidate.address();
    // 使用现有 SDK 生成密钥和 PoP，并通过链上公开验证器检查；
    // 该地址没有对应运行节点，私钥也不写入日志。
    let (public_key, proof) = {
        let secret = bls12381::PrivateKey::generate(&mut rand::thread_rng());
        (
            bls12381::PublicKey::from(&secret).to_bytes().to_vec(),
            bls12381::ProofOfPossession::create(&secret)
                .to_bytes()
                .to_vec(),
        )
    };
    // 创建存储时使用 100 Octa/gas，保持 2M gas 上限不变；
    // 所有成员变更调用，包括容量失败用例，仍使用 1 Octa/gas。
    let setup_factory = f.factory.clone().with_gas_unit_price(100);
    let initialized = execute(
        &f.client,
        &candidate,
        &setup_factory,
        aptos_stdlib::stake_initialize_stake_owner(100, pool, pool),
    )
    .await;
    assert!(initialized.info.success, "{}", initialized.info.vm_status);
    let registered = execute(
        &f.client,
        &candidate,
        &setup_factory,
        aptos_stdlib::stake_rotate_consensus_key(pool, public_key.clone(), proof),
    )
    .await;
    assert!(registered.info.success, "{}", registered.info.vm_status);
    let version = registered.info.version.0;
    let config: ValidatorConfig = f
        .client
        .get_account_resource_at_version_bcs(pool, "0x1::stake::ValidatorConfig", version)
        .await
        .unwrap()
        .into_inner();
    assert_eq!(config.consensus_public_key.to_bytes().to_vec(), public_key);
    let current = installed_at(&f.client, version).await;
    assert!(current.validators.payload().all(|member| member
        .consensus_public_key()
        .to_bytes()
        .to_vec()
        != public_key));
    assert_eq!(
        poc_view(f, "0x1::stake::get_stake", vec![json!(pool)], version).await,
        vec![json!("100"), json!("0"), json!("0"), json!("0")]
    );
    assert_eq!(
        poc_view(
            f,
            "0x1::poc_power_store::is_user_normalized",
            vec![json!(pool)],
            version
        )
        .await,
        vec![json!(false)]
    );
    assert_eq!(
        poc_view(
            f,
            "0x1::poc_accounting::pool_enabled",
            vec![json!(pool)],
            version
        )
        .await,
        vec![json!(false)]
    );
    f.auxiliary_pools.push(pool);
    println!("Capacity fixture registered auxiliary pool={pool}: 100-Octa bond, fresh valid BLS proof, zero raw power, no PoC allocation, no running node; used only to occupy then cancel a pending slot, never installed; setup gas=100, membership gas=1, max_gas=2000000");
    candidate
}

#[tokio::test]
async fn poc_full_candidate_capacity_blocks_cancel_until_pending_slot_is_freed() {
    // min_validators=4 时，动态 Open 部署的最小容量为 5。
    // 五个真实节点加上通过公开入口注册、没有算力的第六个池，
    // 即可触发 active+pending 容量检查，无需第六个节点或内部状态注入。
    // 该额外池始终不会被安装为委员会成员。
    let mut f = poc_fixture_with_limit(5, 5).await;
    let candidate = poc_register_queue_candidate(&mut f).await;
    let auxiliary = candidate.address();
    poc_commit(&f, 1, &f.pools).await;
    let history_version = poc_commit(&f, 0, &f.pools).await;
    let history = poc_snapshot(&f, history_version).await;
    assert_eq!(
        poc_number(
            &history.data["0x1::poc_accounting::AccountingState"]["config"]["limits"]
                ["validator_limit"]
        ),
        5
    );
    // 选择实际获奖的池，确保取消失败时还必须保留
    // 该待退出池的非零历史金库余额，避免仅检查零值。
    let outgoing_index = (0..f.pools.len())
        .max_by_key(|i| poc_number(&history.data[&format!("pool:{}", f.pools[*i])][3]))
        .unwrap();
    let outgoing = f.pools[outgoing_index];
    let owner = &f.owners[outgoing_index];
    let old_member = history.installed.validators.active_validators
        [poc_index(&history.installed.validators.active_validators, outgoing)]
    .clone();
    assert!(poc_number(&history.data[&format!("pool:{outgoing}")][3]) > 0);
    poc_member_change(&f, owner, outgoing, Action::Leave).await;
    let full_version = poc_member_change(&f, &candidate, auxiliary, Action::Join).await;
    let full = poc_snapshot(&f, full_version).await;
    let set = &full.installed.validators;
    assert_eq!(set.active_validators.len(), 4);
    assert_eq!(set.pending_active.len(), 1);
    assert_eq!(set.pending_inactive.len(), 1);
    assert_eq!(set.active_validators.len() + set.pending_active.len(), 5);
    assert_eq!(set.pending_active[0].account_address, auxiliary);
    assert_eq!(set.pending_active[0].consensus_voting_power(), 0);
    assert_eq!(set.pending_inactive[0], old_member);
    assert_eq!(set.total_voting_power, 50);
    assert_eq!(set.total_joining_power, 0);
    assert_eq!(
        full.data[&format!("request:{outgoing}")],
        json!(full.installed.epoch.to_string())
    );
    assert!(full.data[&format!("aux-request:{auxiliary}")].is_null());
    assert_eq!(full.data[&format!("aux-power:{auxiliary}")][0], json!("0"));
    assert_eq!(full.data[&format!("aux-power:{auxiliary}")][1], json!("0"));
    let preview = poc_preview(&f, full_version).await;
    assert_eq!(
        preview["validator_set"]["active_validators"]
            .as_array()
            .unwrap()
            .len(),
        4
    );
    assert_eq!(
        poc_number(&preview["validator_set"]["total_voting_power"]),
        40
    );

    // 权限和当前 Epoch 的自主退出标记均有效，紧接着应在候选容量检查处拒绝。
    // 共用拒绝断言核对完整的 v-1/v 成员队列、原索引、表现统计和费用、
    // 池历史、辅助资源、申请表，
    // 以及业务写集和业务事件。
    let rejected = poc_rejected(&f, owner, outgoing, Action::Cancel, 0x1000C).await;
    let after_rejection = poc_snapshot(&f, rejected.info.version.0).await;
    assert_eq!(after_rejection.installed, full.installed);
    assert_eq!(
        after_rejection.data[&format!("request:{outgoing}")],
        full.data[&format!("request:{outgoing}")]
    );
    assert_eq!(
        after_rejection.data[&format!("pool:{outgoing}")],
        history.data[&format!("pool:{outgoing}")]
    );
    println!("Full-capacity cancel rejected: current=5, active=4, pending_join=1 at zero power, pending_leave=1, limit=5, outgoing={outgoing}, auxiliary={auxiliary}, old_index={}, version={}", old_member.config().validator_index, rejected.info.version.0);

    let freed_version = poc_member_change(&f, &candidate, auxiliary, Action::Leave).await;
    let freed = installed_at(&f.client, freed_version).await;
    assert_eq!(freed.validators.active_validators.len(), 4);
    assert!(freed.validators.pending_active.is_empty());
    assert_eq!(freed.validators.pending_inactive, vec![old_member.clone()]);
    assert_eq!(freed.validators.total_joining_power, 0);
    assert_eq!(freed.validators.total_voting_power, 50);
    let restored_version = poc_member_change(&f, owner, outgoing, Action::Cancel).await;
    let restored = poc_snapshot(&f, restored_version).await;
    assert_eq!(restored.installed.epoch, full.installed.epoch);
    assert_eq!(restored.installed.validators.active_validators.len(), 5);
    assert!(restored.installed.validators.pending_active.is_empty());
    assert!(restored.installed.validators.pending_inactive.is_empty());
    assert_eq!(restored.installed.validators.total_voting_power, 50);
    assert_eq!(restored.installed.validators.total_joining_power, 0);
    for member in &history.installed.validators.active_validators {
        assert_eq!(
            restored.installed.validators.active_validators[poc_index(
                &restored.installed.validators.active_validators,
                member.account_address
            )],
            *member
        );
    }
    assert!(restored.data[&format!("request:{outgoing}")].is_null());
    assert_eq!(
        restored.data[&format!("pool:{outgoing}")],
        history.data[&format!("pool:{outgoing}")]
    );
    // 仅原有五个运行节点参与；提交助手核对独立结算模型、
    // 后续转账及同版本状态。
    let final_version = poc_commit(&f, 0, &f.pools).await;
    let final_state = poc_snapshot(&f, final_version).await;
    assert_eq!(final_state.installed.validators.active_validators.len(), 5);
    assert!(!final_state
        .installed
        .validators
        .active_validators
        .iter()
        .any(|member| member.account_address == auxiliary));
    assert_eq!(
        final_state.data[&format!("aux-enabled:{auxiliary}")],
        json!([false])
    );
    assert!(final_state.data[&format!("aux-allocation:{auxiliary}")].is_null());
    assert_eq!(
        final_state.data[&format!("aux:{auxiliary}:StakePool")],
        history.data[&format!("aux:{auxiliary}:StakePool")]
    );
    println!("Capacity repaired in the same request epoch: original five validators preserved; auxiliary pool was never installed, final_version={final_version}");
}
