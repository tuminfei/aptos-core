// Copyright (c) Aptos Foundation
// Licensed pursuant to the Innovation-Enabling Source Code License, available at https://github.com/aptos-labs/aptos-core/blob/main/LICENSE

//! FRZ-02：在 DKG 暂停前后执行真实签名的质押与委托交易。
//! 四节点 A 委员会保持不变，额外注册的辅助池不加入委员会；
//! 委托池佣金比例为 3735 bps，但入池费和临时费用份额均为 0。
//! 正费用份额、staking contract 和 vesting 由独立用例覆盖，
//! 不计入本文件的覆盖范围。

use super::{
    assert_targets,
    freeze::{assert_installed, epoch_at, fixture, Fixture},
    frozen_context_at, optional_resource_at_version, resource_at_version,
    transactions::{assert_abort, compile_script, execute},
};
use aptos_api_types::{AptosErrorCode, Event, UserTransaction, ViewRequest, WriteSetChange};
use aptos_cached_packages::aptos_stdlib;
use aptos_forge::{NodeExt, Swarm};
use aptos_rest_client::error::RestError;
use aptos_sdk::types::LocalAccount;
use aptos_types::{
    account_address::AccountAddress,
    account_config::CORE_CODE_ADDRESS,
    dkg::DKGState,
    on_chain_config::ValidatorSet,
    transaction::{Script, TransactionArgument, TransactionPayload},
};
use once_cell::sync::Lazy;
use serde_json::{json, Value};
use std::{
    collections::{BTreeMap, BTreeSet},
    time::Duration,
};

const DKG_FAILPOINT: &str = "dkg::process_dkg_start_event";
const DELEGATION_UNIT: u64 = 1_000_000_000; // 10 TOPO，即原生份额余额的最低要求。

static GOVERNANCE: Lazy<Vec<u8>> = Lazy::new(|| {
    compile_script(
        "PoCStakeFreeze",
        r#"script {
        use topo_framework::staking_config;
        use topo_framework::topo_governance;
        fun main(root: &signer, operation: u8) {
            let framework = topo_governance::get_signer_testnet_only(root, @0x1);
            if (operation == 0) {
                staking_config::update_required_stake(&framework, 1, 50000000000);
            } else if (operation == 1) {
                topo_governance::reconfigure(&framework);
            } else {
                assert!(operation == 2, 0);
                topo_governance::force_end_epoch(&framework);
            };
        }
    }"#,
    )
});

fn governance(operation: u8) -> TransactionPayload {
    TransactionPayload::Script(Script::new(GOVERNANCE.clone(), vec![], vec![
        TransactionArgument::U8(operation),
    ]))
}

fn integer(v: &Value) -> u64 {
    v.as_str().unwrap().parse().unwrap()
}
#[track_caller]
fn address(v: &Value) -> AccountAddress {
    let literal = v
        .as_str()
        .unwrap_or_else(|| panic!("Expected a Move address string, got {v}"));
    AccountAddress::from_hex_literal(literal)
        .unwrap_or_else(|error| panic!("Invalid Move address {literal}: {error}"))
}

#[track_caller]
fn table_with_length_handle(table: &Value, context: &str) -> AccountAddress {
    let handle = table
        .get("inner")
        .and_then(|inner| inner.get("handle"))
        .unwrap_or_else(|| panic!("Missing TableWithLength.inner.handle in {context}: {table}"));
    address(handle)
}
fn events<'a>(tx: &'a UserTransaction, suffix: &str) -> Vec<&'a Event> {
    tx.events
        .iter()
        .filter(|event| event.typ.to_string().ends_with(suffix))
        .collect()
}
fn success(tx: UserTransaction) -> UserTransaction {
    assert!(tx.info.success, "{}", tx.info.vm_status);
    tx
}
async fn resource(f: &Fixture, owner: AccountAddress, name: &str, version: u64) -> Value {
    optional_resource_at_version(&f.client, owner, &format!("0x1::{name}"), version)
        .await
        .unwrap()
        .data
}
async fn view(f: &Fixture, name: &str, args: Vec<Value>, version: u64) -> Vec<Value> {
    f.client
        .view(
            &ViewRequest {
                function: format!("0x1::{name}").parse().unwrap(),
                type_arguments: vec![],
                arguments: args,
            },
            Some(version),
        )
        .await
        .unwrap()
        .into_inner()
}
async fn funded(f: &Fixture, amount: u64) -> LocalAccount {
    f.swarm
        .chain_info()
        .into_aptos_public_info()
        .create_and_fund_user_account(amount)
        .await
        .unwrap()
}
pub(super) async fn wallet_delta(f: &Fixture, tx: &UserTransaction, business_delta: i128) {
    let version = tx.info.version.0;
    let sender = tx.request.sender.into();
    let before = f
        .client
        .view_apt_account_balance_at_version(sender, version - 1)
        .await
        .unwrap()
        .into_inner();
    let after = f
        .client
        .view_apt_account_balance_at_version(sender, version)
        .await
        .unwrap()
        .into_inner();
    let fee = events(tx, "::transaction_fee::FeeStatement");
    assert_eq!(fee.len(), 1);
    let refund = integer(&fee[0].data["storage_fee_refund_octas"]);
    let gas = (tx.info.gas_used.0 as i128) * (tx.request.gas_unit_price.0 as i128);
    assert_eq!(
        after as i128 - before as i128,
        business_delta - gas + refund as i128
    );
}

pub(super) struct Frozen {
    epoch: u64,
    context: Vec<Vec<u8>>,
    dkg: DKGState,
    target: ValidatorSet,
}
pub(super) async fn freeze(f: &Fixture) -> Frozen {
    for node in f.swarm.validators() {
        node.rest_client()
            .set_failpoint(DKG_FAILPOINT.to_owned(), "pause".to_owned())
            .await
            .unwrap();
    }
    let tx = success(execute(&f.client, &f.root, &f.factory, governance(1)).await);
    let version = tx.info.version.0;
    let epoch = epoch_at(&f.client, version).await;
    let dkg = resource_at_version::<DKGState>(&f.client, version).await;
    let session = dkg
        .in_progress
        .as_ref()
        .expect("Expected an actual paused DKG session");
    assert_eq!(session.metadata.dealer_epoch, epoch);
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
    assert_eq!(
        target,
        resource_at_version::<ValidatorSet>(&f.client, version).await
    );
    assert_targets(&session.metadata.target_validator_set, &target);
    Frozen {
        epoch,
        context: frozen_context_at(&f.client, version).await,
        dkg,
        target,
    }
}
pub(super) async fn assert_frozen(f: &Fixture, frozen: &Frozen, version: u64) {
    assert_eq!(epoch_at(&f.client, version).await, frozen.epoch);
    assert_eq!(frozen_context_at(&f.client, version).await, frozen.context);
    assert_eq!(
        resource_at_version::<DKGState>(&f.client, version).await,
        frozen.dkg
    );
}
pub(super) async fn finish(f: &Fixture, frozen: &Frozen) {
    let tx = success(execute(&f.client, &f.root, &f.factory, governance(2)).await);
    let version = tx.info.version.0;
    assert_eq!(events(&tx, "::stake::PoCEpochInstalled").len(), 1);
    let credits = events(&tx, "::stake::PoCRewardCredited");
    assert_eq!(credits.len(), 4);
    let mut pools = BTreeSet::new();
    for credit in credits {
        assert_eq!(integer(&credit.data["closing_epoch"]), frozen.epoch);
        assert!(pools.insert(address(&credit.data["pool"])));
    }
    assert_eq!(pools, f.pools.iter().copied().collect());
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
    assert!(resource_at_version::<DKGState>(&f.client, version)
        .await
        .in_progress
        .is_none());
    for node in f.swarm.validators() {
        node.rest_client()
            .set_failpoint(DKG_FAILPOINT.to_owned(), "off".to_owned())
            .await
            .unwrap();
    }
    assert_installed(f, version, frozen.epoch + 1, &frozen.target, 0, None).await;
}

#[derive(Clone, Copy, Debug)]
enum Direct {
    Add,
    Unlock,
    Reactivate,
    Withdraw,
    Lockup,
}
const DIRECT: [Direct; 5] = [
    Direct::Add,
    Direct::Unlock,
    Direct::Reactivate,
    Direct::Withdraw,
    Direct::Lockup,
];
impl Direct {
    fn payload(self) -> TransactionPayload {
        match self {
            Self::Add => aptos_stdlib::stake_add_stake(10),
            Self::Unlock => aptos_stdlib::stake_unlock(30),
            Self::Reactivate => aptos_stdlib::stake_reactivate_stake(10),
            Self::Withdraw => aptos_stdlib::stake_withdraw(5),
            Self::Lockup => aptos_stdlib::stake_increase_lockup(),
        }
    }

    fn event(self) -> &'static str {
        match self {
            Self::Add => "::stake::AddStake",
            Self::Unlock => "::stake::UnlockStake",
            Self::Reactivate => "::stake::ReactivateStake",
            Self::Withdraw => "::stake::WithdrawStake",
            Self::Lockup => "::stake::IncreaseLockup",
        }
    }
}
fn balances(pool: &Value) -> [u64; 4] {
    ["active", "inactive", "pending_active", "pending_inactive"]
        .map(|field| integer(&pool[field]["value"]))
}

async fn direct_success(f: &Fixture, owner: &LocalAccount, call: Direct) {
    if matches!(call, Direct::Lockup) {
        // 再次延长锁仓的目标必须晚于上次目标；使用真实区块时间，
        // 不修改时间戳，也不注入回调。
        tokio::time::timeout(Duration::from_secs(10), async {
            loop {
                let version = f
                    .client
                    .get_ledger_information()
                    .await
                    .unwrap()
                    .into_inner()
                    .version;
                let pool = resource(f, owner.address(), "stake::StakePool", version).await;
                let config = resource(
                    f,
                    CORE_CODE_ADDRESS,
                    "staking_config::StakingConfig",
                    version,
                )
                .await;
                let time = resource(
                    f,
                    CORE_CODE_ADDRESS,
                    "timestamp::CurrentTimeMicroseconds",
                    version,
                )
                .await;
                if integer(&time["microseconds"]) / 1_000_000
                    + integer(&config["recurring_lockup_duration_secs"])
                    > integer(&pool["locked_until_secs"])
                {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(200)).await;
            }
        })
        .await
        .expect("No later block timestamp for a valid lockup extension");
    }
    let tx = success(execute(&f.client, owner, &f.factory, call.payload()).await);
    let version = tx.info.version.0;
    let before = resource(f, owner.address(), "stake::StakePool", version - 1).await;
    let after = resource(f, owner.address(), "stake::StakePool", version).await;
    let mut expected = balances(&before);
    let delta = match call {
        Direct::Add => {
            expected[0] += 10;
            -10
        },
        Direct::Unlock => {
            assert!(expected[0] >= 30);
            expected[0] -= 30;
            expected[3] += 30;
            0
        },
        Direct::Reactivate => {
            assert!(expected[3] >= 10);
            expected[0] += 10;
            expected[3] -= 10;
            0
        },
        Direct::Withdraw => {
            if integer(&before["locked_until_secs"]) == 0 {
                expected[1] += expected[3];
                expected[3] = 0;
            }
            assert!(expected[1] >= 5);
            expected[1] -= 5;
            5
        },
        Direct::Lockup => {
            assert!(integer(&after["locked_until_secs"]) > integer(&before["locked_until_secs"]));
            0
        },
    };
    assert_eq!(balances(&after), expected);
    let emitted = events(&tx, call.event());
    assert_eq!(emitted.len(), 1);
    assert_eq!(address(&emitted[0].data["pool_address"]), owner.address());
    if !matches!(call, Direct::Lockup) {
        assert_eq!(before["locked_until_secs"], after["locked_until_secs"]);
    }
    wallet_delta(f, &tx, delta).await;
    println!(
        "FRZ-02 direct={call:?} version={version} before={:?} after={expected:?}",
        balances(&before)
    );
}

async fn direct_reject(
    f: &Fixture,
    owner: &LocalAccount,
    call: Direct,
    unauthorized: bool,
    frozen: bool,
) {
    let actor = if unauthorized { &f.attacker } else { owner };
    let tx = execute(&f.client, actor, &f.factory, call.payload()).await;
    // unlock/reactivate 先检查冻结，再查找 OwnerCapability；
    // add/withdraw/increase_lockup 先查找能力，再转调持能力的入口。
    let code = if frozen && (!unauthorized || matches!(call, Direct::Unlock | Direct::Reactivate)) {
        0x30014
    } else {
        0x6000F
    };
    assert_abort(
        &f.client,
        &tx,
        "stake",
        code,
        &[owner.address(), f.attacker.address()],
        &f.pools,
    )
    .await;
    let version = tx.info.version.0;
    for name in [
        "stake::StakePool",
        "stake::OwnerCapability",
        "stake::ValidatorConfig",
    ] {
        assert_eq!(
            resource(f, owner.address(), name, version - 1).await,
            resource(f, owner.address(), name, version).await
        );
    }
    assert!(tx
        .events
        .iter()
        .all(|e| !e.typ.to_string().contains("::stake::")));
    wallet_delta(f, &tx, 0).await;
    println!(
        "FRZ-02 direct={call:?} frozen={frozen} unauthorized={unauthorized} abort=stake:{code:#x}"
    );
}

#[tokio::test]
async fn poc_frozen_direct_stake_entries_restore_with_capability_permissions() {
    Lazy::force(&GOVERNANCE);
    let f = fixture().await;
    let owner = funded(&f, 10 * DELEGATION_UNIT).await;
    success(
        execute(
            &f.client,
            &owner,
            &f.factory,
            aptos_stdlib::stake_initialize_stake_owner(500, owner.address(), owner.address()),
        )
        .await,
    );
    for call in DIRECT {
        direct_success(&f, &owner, call).await;
        direct_reject(&f, &owner, call, true, false).await;
    }
    // 保留正的待退出及已退出余额，确保这些冻结操作若无
    // 全局保护检查，都会执行真实质押变更。
    success(
        execute(
            &f.client,
            &owner,
            &f.factory,
            aptos_stdlib::stake_unlock(30),
        )
        .await,
    );
    let frozen = freeze(&f).await;
    for call in DIRECT {
        for unauthorized in [false, true] {
            direct_reject(&f, &owner, call, unauthorized, true).await;
        }
    }
    let version = f
        .client
        .get_ledger_information()
        .await
        .unwrap()
        .into_inner()
        .version;
    assert_frozen(&f, &frozen, version).await;
    finish(&f, &frozen).await;
    for call in DIRECT {
        direct_success(&f, &owner, call).await;
        direct_reject(&f, &owner, call, true, false).await;
    }
}

#[derive(Clone, Copy, Debug)]
enum Delegated {
    Add,
    Unlock,
    Reactivate,
    Withdraw,
}
const DELEGATED: [Delegated; 4] = [
    Delegated::Add,
    Delegated::Unlock,
    Delegated::Reactivate,
    Delegated::Withdraw,
];
impl Delegated {
    fn amount(self) -> u64 {
        match self {
            Self::Add => 2 * DELEGATION_UNIT,
            Self::Unlock => 3 * DELEGATION_UNIT,
            Self::Reactivate | Self::Withdraw => DELEGATION_UNIT,
        }
    }

    fn payload(self, pool: AccountAddress) -> TransactionPayload {
        let amount = self.amount();
        match self {
            Self::Add => aptos_stdlib::delegation_pool_add_stake(pool, amount),
            Self::Unlock => aptos_stdlib::delegation_pool_unlock(pool, amount),
            Self::Reactivate => aptos_stdlib::delegation_pool_reactivate_stake(pool, amount),
            Self::Withdraw => aptos_stdlib::delegation_pool_withdraw(pool, amount),
        }
    }

    fn event(self) -> &'static str {
        match self {
            Self::Add => "::delegation_pool::AddStake",
            Self::Unlock => "::delegation_pool::UnlockStake",
            Self::Reactivate => "::delegation_pool::ReactivateStake",
            Self::Withdraw => "::delegation_pool::WithdrawStake",
        }
    }
}

async fn table(
    f: &Fixture,
    handle: AccountAddress,
    key_type: &str,
    value_type: &str,
    key: Value,
    version: u64,
) -> Option<Value> {
    match f
        .client
        .get_table_item_at_version(handle, key_type, value_type, key, version)
        .await
    {
        Ok(response) => Some(response.into_inner()),
        Err(RestError::Api(error))
            if error.status_code == reqwest::StatusCode::NOT_FOUND
                && error.error.error_code == AptosErrorCode::TableItemNotFound =>
        {
            None
        },
        Err(error) => panic!("Cannot read {value_type} table at {version}: {error}"),
    }
}
fn handles(value: &Value, out: &mut BTreeSet<AccountAddress>) {
    match value {
        Value::Object(fields) => {
            for (name, value) in fields {
                if name == "handle" {
                    out.insert(address(value));
                } else {
                    handles(value, out);
                }
            }
        },
        Value::Array(values) => {
            for value in values {
                handles(value, out);
            }
        },
        _ => {},
    }
}
#[derive(Debug, PartialEq)]
struct DelegationSnapshot {
    data: BTreeMap<String, Value>,
    handles: BTreeSet<AccountAddress>,
}

async fn smart_table(
    f: &Fixture,
    name: &str,
    value: &Value,
    key_type: &str,
    value_type: &str,
    version: u64,
    state: &mut DelegationSnapshot,
) {
    let handle = table_with_length_handle(
        &value["buckets"],
        &format!("SmartTable {name} buckets at version {version}"),
    );
    let buckets = integer(&value["num_buckets"]);
    for bucket in 0..buckets {
        let item = table(
            f,
            handle,
            "u64",
            &format!("vector<0x1::smart_table::Entry<{key_type}, {value_type}>>"),
            json!(bucket.to_string()),
            version,
        )
        .await
        .unwrap();
        state.data.insert(format!("{name}/{bucket}"), item);
    }
}

async fn delegation_snapshot(
    f: &Fixture,
    pool: AccountAddress,
    users: &[AccountAddress],
    version: u64,
) -> DelegationSnapshot {
    let mut state = DelegationSnapshot {
        data: BTreeMap::new(),
        handles: BTreeSet::new(),
    };
    for name in [
        "stake::StakePool",
        "stake::ValidatorConfig",
        "stake::OwnerCapability",
        "delegation_pool::DelegationPool",
        "delegation_pool::GovernanceRecords",
        "delegation_pool::DelegationPoolAllowlisting",
    ] {
        let r = resource(f, pool, name, version).await;
        handles(&r, &mut state.handles);
        state.data.insert(name.to_owned(), r);
    }
    let delegation = state.data["delegation_pool::DelegationPool"].clone();
    let cycle = integer(&delegation["observed_lockup_cycle"]["index"]);
    // pool_u64_unbound 将 TableWithLength 导入为 Table；其 shares
    // 包含内层表和长度，与 delegation_pool 使用的普通表结构不同。
    let active_handle = table_with_length_handle(
        &delegation["active_shares"]["shares"],
        &format!("pool {pool} active shares at version {version}"),
    );
    for user in users {
        state.data.insert(
            format!("active/{user}"),
            json!(table(f, active_handle, "address", "u128", json!(user), version).await),
        );
        state.data.insert(
            format!("withdrawal/{user}"),
            json!(
                table(
                    f,
                    address(&delegation["pending_withdrawals"]["handle"]),
                    "address",
                    "0x1::delegation_pool::ObservedLockupCycle",
                    json!(user),
                    version
                )
                .await
            ),
        );
        state.data.insert(
            format!("stake/{user}"),
            json!(
                view(
                    f,
                    "delegation_pool::get_stake",
                    vec![json!(pool), json!(user)],
                    version
                )
                .await
            ),
        );
    }
    for index in 0..=cycle {
        let inactive = table(
            f,
            address(&delegation["inactive_shares"]["handle"]),
            "0x1::delegation_pool::ObservedLockupCycle",
            "0x1::pool_u64_unbound::Pool",
            json!({"index": index.to_string()}),
            version,
        )
        .await
        .unwrap();
        handles(&inactive, &mut state.handles);
        let inactive_handle = table_with_length_handle(
            &inactive["shares"],
            &format!("pool {pool} inactive shares OLC {index} at version {version}"),
        );
        for user in users {
            state.data.insert(
                format!("inactive/{index}/{user}"),
                json!(table(f, inactive_handle, "address", "u128", json!(user), version).await),
            );
        }
        state.data.insert(format!("inactive/{index}"), inactive);
    }
    let governance = state.data["delegation_pool::GovernanceRecords"].clone();
    for (name, key, value) in [
        ("votes", "0x1::delegation_pool::VotingRecordKey", "u64"),
        ("votes_per_proposal", "u64", "u64"),
        (
            "vote_delegation",
            "address",
            "0x1::delegation_pool::VoteDelegation",
        ),
        (
            "delegated_votes",
            "address",
            "0x1::delegation_pool::DelegatedVotes",
        ),
    ] {
        smart_table(f, name, &governance[name], key, value, version, &mut state).await;
    }
    let allowlist = state.data["delegation_pool::DelegationPoolAllowlisting"]["allowlist"].clone();
    smart_table(
        f,
        "allowlist",
        &allowlist,
        "address",
        "bool",
        version,
        &mut state,
    )
    .await;
    state.data.insert(
        "add_fee".to_owned(),
        json!(
            view(
                f,
                "delegation_pool::get_add_stake_fee",
                vec![json!(pool), json!((2 * DELEGATION_UNIT).to_string())],
                version
            )
            .await
        ),
    );
    state
}

async fn delegated_reject(
    f: &Fixture,
    pool: AccountAddress,
    actor: &LocalAccount,
    users: &[AccountAddress],
    call: Delegated,
    error: (&str, u64),
) {
    let tx = execute(&f.client, actor, &f.factory, call.payload(pool)).await;
    assert_abort(&f.client, &tx, error.0, error.1, users, &f.pools).await;
    let version = tx.info.version.0;
    let before = delegation_snapshot(f, pool, users, version - 1).await;
    let after = delegation_snapshot(f, pool, users, version).await;
    assert_eq!(before, after);
    for change in &tx.info.changes {
        match change {
            WriteSetChange::WriteTableItem(item) => assert!(!before
                .handles
                .contains(&AccountAddress::from_bytes(item.handle.inner()).unwrap())),
            WriteSetChange::DeleteTableItem(item) => assert!(!before
                .handles
                .contains(&AccountAddress::from_bytes(item.handle.inner()).unwrap())),
            WriteSetChange::WriteResource(item) => assert!(
                !item.data.typ.to_string().contains("::delegation_pool::")
                    && !item.data.typ.to_string().contains("::stake::")
            ),
            WriteSetChange::DeleteResource(item) => assert!(
                !item.resource.to_string().contains("::delegation_pool::")
                    && !item.resource.to_string().contains("::stake::")
            ),
            WriteSetChange::WriteModule(_) | WriteSetChange::DeleteModule(_) => {
                panic!("Unexpected module mutation in rejected delegation call: {change:?}")
            },
        }
    }
    assert!(tx.events.iter().all(
        |event| !event.typ.to_string().contains("::delegation_pool::")
            && !event.typ.to_string().contains("::stake::")
    ));
    assert_eq!(
        f.client
            .view_apt_account_balance_at_version(pool, version - 1)
            .await
            .unwrap()
            .into_inner(),
        f.client
            .view_apt_account_balance_at_version(pool, version)
            .await
            .unwrap()
            .into_inner()
    );
    wallet_delta(f, &tx, 0).await;
    println!("FRZ-02 delegation={call:?} version={version} abort={}:{:#x} snapshots/tables/events unchanged", error.0, error.1);
}

async fn delegated_success(
    f: &Fixture,
    pool: AccountAddress,
    user: &LocalAccount,
    call: Delegated,
) {
    let tx = success(execute(&f.client, user, &f.factory, call.payload(pool)).await);
    let version = tx.info.version.0;
    let before = view(
        f,
        "delegation_pool::get_stake",
        vec![json!(pool), json!(user.address())],
        version - 1,
    )
    .await;
    let mut expected = before.iter().map(integer).collect::<Vec<_>>();
    let amount = call.amount();
    let delta = match call {
        Delegated::Add => {
            expected[0] += amount;
            -(amount as i128)
        },
        Delegated::Unlock => {
            expected[0] -= amount;
            expected[2] += amount;
            0
        },
        Delegated::Reactivate => {
            expected[0] += amount;
            expected[2] -= amount;
            0
        },
        Delegated::Withdraw => {
            // 对这个不在委员会中且 lockup=0 的池，withdraw_internal
            // 先临时重新激活超出提取额的部分，仅提取请求金额，再将
            // 剩余部分解锁。inactive 仍为零，因此 OLC 不推进，
            // 剩余待提取份额仍全部体现在返回值下标 2 中。
            expected[2] -= amount;
            amount as i128
        },
    };
    assert_eq!(
        view(
            f,
            "delegation_pool::get_stake",
            vec![json!(pool), json!(user.address())],
            version
        )
        .await,
        expected
            .iter()
            .map(|n| json!(n.to_string()))
            .collect::<Vec<_>>()
    );
    let emitted = events(&tx, call.event());
    assert_eq!(emitted.len(), 1);
    assert_eq!(address(&emitted[0].data["pool_address"]), pool);
    assert_eq!(
        address(&emitted[0].data["delegator_address"]),
        user.address()
    );
    let field = match call {
        Delegated::Add => "amount_added",
        Delegated::Unlock => "amount_unlocked",
        Delegated::Reactivate => "amount_reactivated",
        Delegated::Withdraw => "amount_withdrawn",
    };
    assert_eq!(integer(&emitted[0].data[field]), amount);
    if matches!(call, Delegated::Add) {
        assert_eq!(integer(&emitted[0].data["add_stake_fee"]), 0);
    }
    assert_eq!(
        events(&tx, "::delegation_pool::DistributeCommission").len(),
        1
    );
    wallet_delta(f, &tx, delta).await;
}

async fn no_owned_withdrawal(f: &Fixture, pool: AccountAddress, delegator: AccountAddress) {
    // withdraw 只能处理签名者自己的持仓。发送者没有待提取权益时，
    // 同步后正常返回；冻结期间也遵循这一语义。
    let tx = success(
        execute(
            &f.client,
            &f.attacker,
            &f.factory,
            Delegated::Withdraw.payload(pool),
        )
        .await,
    );
    let version = tx.info.version.0;
    assert!(events(&tx, Delegated::Withdraw.event()).is_empty());
    for user in [delegator, f.attacker.address()] {
        assert_eq!(
            view(
                f,
                "delegation_pool::get_stake",
                vec![json!(pool), json!(user)],
                version - 1
            )
            .await,
            view(
                f,
                "delegation_pool::get_stake",
                vec![json!(pool), json!(user)],
                version
            )
            .await
        );
    }
    assert_eq!(
        resource(f, pool, "stake::StakePool", version - 1).await,
        resource(f, pool, "stake::StakePool", version).await
    );
    wallet_delta(f, &tx, 0).await;
}

async fn evict_success(
    f: &Fixture,
    pool: AccountAddress,
    owner: &LocalAccount,
    delegator: AccountAddress,
) {
    let tx = success(
        execute(
            &f.client,
            owner,
            &f.factory,
            aptos_stdlib::delegation_pool_evict_delegator(delegator),
        )
        .await,
    );
    let at = tx.info.version.0;
    let old = view(
        f,
        "delegation_pool::get_stake",
        vec![json!(pool), json!(delegator)],
        at - 1,
    )
    .await;
    let new = view(
        f,
        "delegation_pool::get_stake",
        vec![json!(pool), json!(delegator)],
        at,
    )
    .await;
    let active = integer(&old[0]);
    assert!(active >= DELEGATION_UNIT);
    assert_eq!(integer(&new[0]), 0);
    assert_eq!(integer(&new[2]), integer(&old[2]) + active);
    let evicted = events(&tx, "::delegation_pool::EvictDelegator");
    assert_eq!(evicted.len(), 1);
    assert_eq!(address(&evicted[0].data["pool_address"]), pool);
    assert_eq!(address(&evicted[0].data["delegator_address"]), delegator);
    let unlocked = events(&tx, "::delegation_pool::UnlockStake");
    assert_eq!(unlocked.len(), 1);
    assert_eq!(integer(&unlocked[0].data["amount_unlocked"]), active);
    wallet_delta(f, &tx, 0).await;
}

async fn evict_frozen_reject(
    f: &Fixture,
    pool: AccountAddress,
    owner: &LocalAccount,
    users: &[AccountAddress],
    delegator: AccountAddress,
) -> u64 {
    let tx = execute(
        &f.client,
        owner,
        &f.factory,
        aptos_stdlib::delegation_pool_evict_delegator(delegator),
    )
    .await;
    assert_abort(&f.client, &tx, "stake", 0x30014, users, &f.pools).await;
    let at = tx.info.version.0;
    let before = delegation_snapshot(f, pool, users, at - 1).await;
    assert_eq!(delegation_snapshot(f, pool, users, at).await, before);
    for change in &tx.info.changes {
        match change {
            WriteSetChange::WriteTableItem(item) => assert!(!before
                .handles
                .contains(&AccountAddress::from_bytes(item.handle.inner()).unwrap())),
            WriteSetChange::DeleteTableItem(item) => assert!(!before
                .handles
                .contains(&AccountAddress::from_bytes(item.handle.inner()).unwrap())),
            WriteSetChange::WriteResource(item) => assert!(
                !item.data.typ.to_string().contains("::delegation_pool::")
                    && !item.data.typ.to_string().contains("::stake::")
            ),
            WriteSetChange::DeleteResource(item) => assert!(
                !item.resource.to_string().contains("::delegation_pool::")
                    && !item.resource.to_string().contains("::stake::")
            ),
            WriteSetChange::WriteModule(_) | WriteSetChange::DeleteModule(_) => {
                panic!("冻结驱逐拒绝时不应修改模块：{change:?}")
            },
        }
    }
    assert!(tx.events.iter().all(|event| {
        let name = event.typ.to_string();
        !name.contains("::delegation_pool::") && !name.contains("::stake::")
    }));
    wallet_delta(f, &tx, 0).await;
    at
}

#[tokio::test]
async fn poc_frozen_delegation_entries_rollback_outer_shares_and_resume() {
    Lazy::force(&GOVERNANCE);
    let f = fixture().await;
    success(execute(&f.client, &f.root, &f.factory, governance(0)).await);
    println!("FRZ-02 delegation variant: max_native_stake=500TOPO; off-committee pool; commission=3735; fee=0; NULL_SHAREHOLDER fee shares=0; owner/operator distinct from delegator; positive active and pending shares");
    let owner = funded(&f, 10 * DELEGATION_UNIT).await;
    let delegator = funded(&f, 100 * DELEGATION_UNIT).await;
    let evictee = funded(&f, 30 * DELEGATION_UNIT).await;
    success(
        execute(
            &f.client,
            &owner,
            &f.factory,
            aptos_stdlib::delegation_pool_initialize_delegation_pool(
                3735,
                b"poc-freeze-delegation".to_vec(),
            ),
        )
        .await,
    );
    let version = f
        .client
        .get_ledger_information()
        .await
        .unwrap()
        .into_inner()
        .version;
    let pool = address(
        &view(
            &f,
            "delegation_pool::get_owned_pool_address",
            vec![json!(owner.address())],
            version,
        )
        .await[0],
    );
    success(
        execute(
            &f.client,
            &owner,
            &f.factory,
            aptos_stdlib::delegation_pool_enable_delegators_allowlisting(),
        )
        .await,
    );
    success(
        execute(
            &f.client,
            &owner,
            &f.factory,
            aptos_stdlib::delegation_pool_allowlist_delegator(delegator.address()),
        )
        .await,
    );
    success(
        execute(
            &f.client,
            &delegator,
            &f.factory,
            aptos_stdlib::delegation_pool_add_stake(pool, 8 * DELEGATION_UNIT),
        )
        .await,
    );
    success(
        execute(
            &f.client,
            &owner,
            &f.factory,
            aptos_stdlib::delegation_pool_allowlist_delegator(evictee.address()),
        )
        .await,
    );
    success(
        execute(
            &f.client,
            &evictee,
            &f.factory,
            aptos_stdlib::delegation_pool_add_stake(pool, 8 * DELEGATION_UNIT),
        )
        .await,
    );
    let users = [
        owner.address(),
        delegator.address(),
        evictee.address(),
        f.attacker.address(),
        AccountAddress::ZERO,
    ];
    for call in DELEGATED {
        delegated_success(&f, pool, &delegator, call).await;
    }
    for call in [Delegated::Add, Delegated::Reactivate] {
        delegated_reject(
            &f,
            pool,
            &f.attacker,
            &users,
            call,
            ("delegation_pool", 0x50019),
        )
        .await;
    }
    delegated_reject(
        &f,
        pool,
        &f.attacker,
        &users,
        Delegated::Unlock,
        ("delegation_pool", 0x10009),
    )
    .await;
    no_owned_withdrawal(&f, pool, delegator.address()).await;
    // 驱逐 payload 不接受池地址，只能操作签名 owner 自己的委托池。
    // 先成功驱逐一次，再重建相同的正 active 状态供冻结和恢复复用。
    success(
        execute(
            &f.client,
            &owner,
            &f.factory,
            aptos_stdlib::delegation_pool_remove_delegator_from_allowlist(evictee.address()),
        )
        .await,
    );
    evict_success(&f, pool, &owner, evictee.address()).await;
    success(
        execute(
            &f.client,
            &owner,
            &f.factory,
            aptos_stdlib::delegation_pool_allowlist_delegator(evictee.address()),
        )
        .await,
    );
    success(
        execute(
            &f.client,
            &evictee,
            &f.factory,
            aptos_stdlib::delegation_pool_reactivate_stake(pool, 4 * DELEGATION_UNIT),
        )
        .await,
    );
    success(
        execute(
            &f.client,
            &owner,
            &f.factory,
            aptos_stdlib::delegation_pool_remove_delegator_from_allowlist(evictee.address()),
        )
        .await,
    );
    let frozen = freeze(&f).await;
    for call in DELEGATED {
        // add 在能力入口的保护检查前同步、发出佣金事件并转账。
        // unlock/reactivate/withdraw 还会先赎回外层份额、更新治理表，
        // 随后 stake 才拒绝整笔事务。
        delegated_reject(&f, pool, &delegator, &users, call, ("stake", 0x30014)).await;
    }
    for call in [Delegated::Add, Delegated::Reactivate] {
        delegated_reject(
            &f,
            pool,
            &f.attacker,
            &users,
            call,
            ("delegation_pool", 0x50019),
        )
        .await;
    }
    delegated_reject(
        &f,
        pool,
        &f.attacker,
        &users,
        Delegated::Unlock,
        ("stake", 0x30014),
    )
    .await;
    no_owned_withdrawal(&f, pool, delegator.address()).await;
    let rejected = evict_frozen_reject(&f, pool, &owner, &users, evictee.address()).await;
    assert_frozen(&f, &frozen, rejected).await;
    let version = f
        .client
        .get_ledger_information()
        .await
        .unwrap()
        .into_inner()
        .version;
    assert_frozen(&f, &frozen, version).await;
    let state = delegation_snapshot(&f, pool, &users, version).await;
    assert_eq!(state.data["add_fee"], json!(["0"]));
    let null = state.data[&format!("active/{}", AccountAddress::ZERO)].clone();
    assert!(null.is_null() || null == json!("0"));
    finish(&f, &frozen).await;
    for call in DELEGATED {
        delegated_success(&f, pool, &delegator, call).await;
    }
    for call in [Delegated::Add, Delegated::Reactivate] {
        delegated_reject(
            &f,
            pool,
            &f.attacker,
            &users,
            call,
            ("delegation_pool", 0x50019),
        )
        .await;
    }
    delegated_reject(
        &f,
        pool,
        &f.attacker,
        &users,
        Delegated::Unlock,
        ("delegation_pool", 0x10009),
    )
    .await;
    no_owned_withdrawal(&f, pool, delegator.address()).await;
    evict_success(&f, pool, &owner, evictee.address()).await;
}
