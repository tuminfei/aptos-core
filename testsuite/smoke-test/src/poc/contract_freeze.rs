// Copyright (c) Aptos Foundation
// Licensed pursuant to the Innovation-Enabling Source Code License, available at https://github.com/aptos-labs/aptos-core/blob/main/LICENSE

//! FRZ-02：staking contract 和 vesting 包装入口转调真实冻结的质押能力。
//! 辅助池用例以 37% 佣金配置验证正本金、正授予金额及分发份额；
//! 正收益批量解锁用例另将真实 vesting 池安装为验证者，核对收益和佣金支付。

use super::{
    assert_targets,
    defaults::installed_at,
    fee_rewards::{ledger_at, pool_at, pool_event, wide},
    freeze::{fixture, Fixture},
    optional_resource_at_version, resource_at_version,
    stake_freeze::{assert_frozen, finish, freeze, wallet_delta},
    transactions::{assert_abort, compile_script, execute},
};
use aptos_api_types::{Event, TransactionData, UserTransaction, ViewRequest, WriteSetChange};
use aptos_cached_packages::aptos_stdlib;
use aptos_config::config::{
    Identity, IdentityBlob, InitialSafetyRulesConfig, OverrideNodeConfig, PersistableConfig,
    SecureBackend,
};
use aptos_crypto::bls12381;
use aptos_forge::{NodeExt, Swarm};
use aptos_sdk::types::LocalAccount;
use aptos_types::{
    account_address::AccountAddress,
    account_config::CORE_CODE_ADDRESS,
    dkg::DKGState,
    transaction::{ExecutionStatus, Script, TransactionArgument, TransactionPayload},
    validator_config::ValidatorConfig,
};
use move_core_types::{int256::U256, vm_status::AbortLocation};
use once_cell::sync::Lazy;
use serde_json::{json, Value};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    time::{Duration, Instant},
};

static LOCKUP: Lazy<Vec<u8>> = Lazy::new(|| {
    compile_script(
        "PoCContractLockup",
        r#"script {
    use topo_framework::staking_config;
    use topo_framework::topo_governance;
    fun main(root: &signer) {
        let framework = topo_governance::get_signer_testnet_only(root, @0x1);
        staking_config::update_recurring_lockup_duration_secs(&framework, 2);
    }
}"#,
    )
});

static CREATE_VESTING: Lazy<Vec<u8>> = Lazy::new(|| {
    compile_script(
        "PoCFreezeVestingCreation",
        r#"script {
    use std::fixed_point32;
    use topo_std::simple_map;
    use topo_framework::coin;
    use topo_framework::topo_coin::TopoCoin;
    use topo_framework::timestamp;
    use topo_framework::vesting;

    fun main(admin: &signer, first: address, second: address, operator: address, voter: address) {
        let buy_ins = simple_map::create<address, coin::Coin<TopoCoin>>();
        buy_ins.add(first, coin::withdraw<TopoCoin>(admin, 100));
        buy_ins.add(second, coin::withdraw<TopoCoin>(admin, 300));
        let schedule = vesting::create_vesting_schedule(
            vector[fixed_point32::create_from_rational(1, 4)], timestamp::now_seconds(), 1);
        vesting::create_vesting_contract(admin, &vector[first, second], buy_ins, schedule,
            first, operator, voter, 37, b"poc-freeze-vesting");
    }
}"#,
    )
});

#[track_caller]
fn integer(v: &Value) -> u64 {
    v.as_str()
        .unwrap_or_else(|| panic!("Expected integer string: {v}"))
        .parse()
        .unwrap()
}
#[track_caller]
fn address(v: &Value) -> AccountAddress {
    AccountAddress::from_hex_literal(
        v.as_str()
            .unwrap_or_else(|| panic!("Expected address string: {v}")),
    )
    .unwrap()
}
fn success(tx: UserTransaction) -> UserTransaction {
    assert!(tx.info.success, "{}", tx.info.vm_status);
    tx
}
fn events<'a>(tx: &'a UserTransaction, suffix: &str) -> Vec<&'a Event> {
    tx.events
        .iter()
        .filter(|event| event.typ.to_string().ends_with(suffix))
        .collect()
}
async fn funded(f: &Fixture) -> LocalAccount {
    funded_with_balance(f, 1_000_000_000).await
}
async fn funded_with_balance(f: &Fixture, amount: u64) -> LocalAccount {
    f.swarm
        .chain_info()
        .into_aptos_public_info()
        .create_and_fund_user_account(amount)
        .await
        .unwrap()
}
async fn resource(f: &Fixture, owner: AccountAddress, name: &str, version: u64) -> Value {
    optional_resource_at_version(&f.client, owner, &format!("0x1::{name}"), version)
        .await
        .unwrap_or_else(|| panic!("Missing {name} for {owner} at {version}"))
        .data
}
async fn view(f: &Fixture, name: &str, arguments: Vec<Value>, version: u64) -> Vec<Value> {
    f.client
        .view(
            &ViewRequest {
                function: format!("0x1::{name}").parse().unwrap(),
                type_arguments: vec![],
                arguments,
            },
            Some(version),
        )
        .await
        .unwrap()
        .into_inner()
}
async fn version(f: &Fixture) -> u64 {
    f.client
        .get_ledger_information()
        .await
        .unwrap()
        .into_inner()
        .version
}
async fn balance(f: &Fixture, account: AccountAddress, version: u64) -> u64 {
    f.client
        .view_apt_account_balance_at_version(account, version)
        .await
        .unwrap()
        .into_inner()
}
async fn now(f: &Fixture) -> u64 {
    integer(
        &resource(
            f,
            CORE_CODE_ADDRESS,
            "timestamp::CurrentTimeMicroseconds",
            version(f).await,
        )
        .await["microseconds"],
    ) / 1_000_000
}
async fn wait_until(f: &Fixture, target: u64) {
    tokio::time::timeout(Duration::from_secs(15), async {
        while now(f).await < target {
            tokio::time::sleep(Duration::from_millis(200)).await;
        }
    })
    .await
    .unwrap_or_else(|_| panic!("Chain did not reach required timestamp {target}"));
}
async fn wait_expired(f: &Fixture, pool: AccountAddress) {
    let locked = resource(f, pool, "stake::StakePool", version(f).await).await;
    wait_until(f, integer(&locked["locked_until_secs"])).await;
}
async fn wait_valid_reset(f: &Fixture, pool: AccountAddress) {
    let locked = resource(f, pool, "stake::StakePool", version(f).await).await;
    // 配置的延长期为两秒；严格满足 old < now+2 需要 now >= old-1。
    // 每次重试都依据实际链上时间重新计算。
    wait_until(f, integer(&locked["locked_until_secs"]).saturating_sub(1)).await;
}
async fn setup() -> Fixture {
    Lazy::force(&LOCKUP);
    let f = fixture().await;
    success(
        execute(
            &f.client,
            &f.root,
            &f.factory,
            TransactionPayload::Script(Script::new(LOCKUP.clone(), vec![], vec![])),
        )
        .await,
    );
    println!("FRZ-02 contract fixture: four A validators remain 4x10; auxiliary pools are off committee, native_bps=0; recurring lockup=2s for real time expiry; staking contract commission=37 percent, no commission earnings");
    f
}

struct Scope {
    staker: AccountAddress,
    operator: AccountAddress,
    pool: AccountAddress,
    wallets: Vec<AccountAddress>,
    vesting_admin: Option<AccountAddress>,
}
async fn contract(f: &Fixture, scope: &Scope, at: u64) -> Value {
    let store = resource(f, scope.staker, "staking_contract::Store", at).await;
    let entries = store["staking_contracts"]["data"].as_array().unwrap();
    let entry = entries
        .iter()
        .find(|entry| address(&entry["key"]) == scope.operator)
        .unwrap();
    entry["value"].clone()
}
fn balances(pool: &Value) -> [u64; 4] {
    ["active", "inactive", "pending_active", "pending_inactive"]
        .map(|field| integer(&pool[field]["value"]))
}
async fn assert_contract(f: &Fixture, scope: &Scope, at: u64, principal: u64, pending: u64) {
    let c = contract(f, scope, at).await;
    assert_eq!(integer(&c["principal"]), principal);
    assert_eq!(integer(&c["commission_percentage"]), 37);
    assert_eq!(address(&c["pool_address"]), scope.pool);
    assert_eq!(integer(&c["distribution_pool"]["total_coins"]), pending);
    assert_eq!(integer(&c["distribution_pool"]["total_shares"]), pending);
    assert_eq!(
        balances(&resource(f, scope.pool, "stake::StakePool", at).await),
        [principal, 0, 0, pending]
    );
    assert_eq!(
        view(
            f,
            "staking_contract::staking_contract_amounts",
            vec![json!(scope.staker), json!(scope.operator)],
            at
        )
        .await,
        vec![json!(principal.to_string()), json!("0"), json!("0")]
    );
}

fn handles(value: &Value, output: &mut BTreeSet<AccountAddress>) {
    match value {
        Value::Object(fields) => {
            for (name, value) in fields {
                if name == "handle" {
                    output.insert(address(value));
                } else {
                    handles(value, output);
                }
            }
        },
        Value::Array(values) => {
            for value in values {
                handles(value, output);
            }
        },
        Value::Null | Value::Bool(_) | Value::Number(_) | Value::String(_) => {},
    }
}
#[derive(Debug, PartialEq)]
struct Snapshot {
    resources: BTreeMap<String, Option<Value>>,
    wallets: BTreeMap<AccountAddress, u64>,
    handles: BTreeSet<AccountAddress>,
}
async fn snapshot(f: &Fixture, scope: &Scope, actor: AccountAddress, at: u64) -> Snapshot {
    let mut result = Snapshot {
        resources: BTreeMap::new(),
        wallets: BTreeMap::new(),
        handles: BTreeSet::new(),
    };
    let mut resources = vec![
        (scope.staker, "staking_contract::Store"),
        (scope.pool, "staking_contract::Staker"),
        (scope.pool, "stake::StakePool"),
        (scope.pool, "stake::ValidatorConfig"),
        (scope.pool, "stake::OwnerCapability"),
        (scope.operator, "staking_contract::BeneficiaryForOperator"),
        (CORE_CODE_ADDRESS, "staking_config::StakingConfig"),
    ];
    if let Some(admin) = scope.vesting_admin {
        resources.extend([
            (admin, "vesting::AdminStore"),
            (scope.staker, "vesting::VestingContract"),
            (scope.staker, "vesting::VestingAccountManagement"),
        ]);
    }
    for (owner, name) in resources {
        let data = optional_resource_at_version(&f.client, owner, &format!("0x1::{name}"), at)
            .await
            .map(|resource| resource.data);
        if let Some(value) = &data {
            handles(value, &mut result.handles);
        }
        result.resources.insert(format!("{owner}/{name}"), data);
    }
    // Store.staking_contracts、distribution_pool 和 vesting grant_pool 使用
    // 内联的 SimpleMap/Pool，而非 Table；需保存所有内联份额和计数器。
    assert!(
        result.handles.is_empty(),
        "New table-backed contract state needs explicit table snapshots"
    );
    for wallet in scope
        .wallets
        .iter()
        .copied()
        .chain([scope.pool, scope.staker])
    {
        if wallet != actor {
            result.wallets.insert(wallet, balance(f, wallet, at).await);
        }
    }
    result
}
async fn reject(
    f: &Fixture,
    scope: &Scope,
    actor: &LocalAccount,
    payload: TransactionPayload,
    module: &str,
    code: u64,
) -> UserTransaction {
    let tx = execute(&f.client, actor, &f.factory, payload).await;
    assert_abort(&f.client, &tx, module, code, &scope.wallets, &f.pools).await;
    let at = tx.info.version.0;
    let before = snapshot(f, scope, actor.address(), at - 1).await;
    assert_eq!(before, snapshot(f, scope, actor.address(), at).await);
    let forbidden = |name: &str| {
        name.contains("::staking_contract::")
            || name.contains("::vesting::")
            || name.contains("::stake::")
    };
    for change in &tx.info.changes {
        match change {
            WriteSetChange::WriteResource(change) => {
                assert!(!forbidden(&change.data.typ.to_string()))
            },
            WriteSetChange::DeleteResource(change) => {
                assert!(!forbidden(&change.resource.to_string()))
            },
            WriteSetChange::WriteTableItem(change) => assert!(!before
                .handles
                .contains(&AccountAddress::from_bytes(change.handle.inner()).unwrap())),
            WriteSetChange::DeleteTableItem(change) => assert!(!before
                .handles
                .contains(&AccountAddress::from_bytes(change.handle.inner()).unwrap())),
            WriteSetChange::WriteModule(_) | WriteSetChange::DeleteModule(_) => {
                panic!("Unexpected module mutation: {change:?}")
            },
        }
    }
    assert!(tx
        .events
        .iter()
        .all(|event| !forbidden(&event.typ.to_string())));
    wallet_delta(f, &tx, 0).await;
    println!("FRZ-02 contract pool={} version={at} sender={} abort={module}:{code:#x}; complete inline shares, principal, wallets and business events rolled back", scope.pool, actor.address());
    tx
}

#[derive(Clone, Copy, Debug)]
enum StakingCall {
    Add,
    Reset,
    Unlock,
}
const STAKING_CALLS: [StakingCall; 3] = [StakingCall::Add, StakingCall::Reset, StakingCall::Unlock];
impl StakingCall {
    fn payload(self, operator: AccountAddress) -> TransactionPayload {
        match self {
            Self::Add => aptos_stdlib::staking_contract_add_stake(operator, 10),
            Self::Reset => aptos_stdlib::staking_contract_reset_lockup(operator),
            Self::Unlock => aptos_stdlib::staking_contract_unlock_stake(operator, 30),
        }
    }
}
async fn staking_success(f: &Fixture, scope: &Scope, staker: &LocalAccount, call: StakingCall) {
    if matches!(call, StakingCall::Reset) {
        wait_valid_reset(f, scope.pool).await;
    }
    let tx = success(execute(&f.client, staker, &f.factory, call.payload(scope.operator)).await);
    let at = tx.info.version.0;
    let before = contract(f, scope, at - 1).await;
    let principal = integer(&before["principal"]);
    let pending = integer(&before["distribution_pool"]["total_coins"]);
    assert_eq!(pending, 0, "Normal control starts with distributions paid");
    match call {
        StakingCall::Add => {
            assert_contract(f, scope, at, principal + 10, 0).await;
            wallet_delta(f, &tx, -10).await;
            assert_eq!(events(&tx, "::staking_contract::AddStake").len(), 1);
        },
        StakingCall::Reset => {
            assert_contract(f, scope, at, principal, 0).await;
            let old = resource(f, scope.pool, "stake::StakePool", at - 1).await;
            let new = resource(f, scope.pool, "stake::StakePool", at).await;
            assert!(integer(&new["locked_until_secs"]) > integer(&old["locked_until_secs"]));
            assert_eq!(events(&tx, "::staking_contract::ResetLockup").len(), 1);
            wallet_delta(f, &tx, 0).await;
        },
        StakingCall::Unlock => {
            assert_contract(f, scope, at, principal - 30, 30).await;
            let emitted = events(&tx, "::staking_contract::UnlockStake");
            assert_eq!(emitted.len(), 1);
            assert_eq!(integer(&emitted[0].data["amount"]), 30);
            assert_eq!(integer(&emitted[0].data["commission_paid"]), 0);
            wallet_delta(f, &tx, 0).await;
        },
    }
}
async fn staking_distribute(f: &Fixture, scope: &Scope, sender: &LocalAccount) {
    wait_expired(f, scope.pool).await;
    let tx = success(
        execute(
            &f.client,
            sender,
            &f.factory,
            aptos_stdlib::staking_contract_distribute(scope.staker, scope.operator),
        )
        .await,
    );
    let at = tx.info.version.0;
    let before = contract(f, scope, at - 1).await;
    assert_eq!(integer(&before["distribution_pool"]["total_coins"]), 30);
    assert_contract(f, scope, at, integer(&before["principal"]), 0).await;
    let emitted = events(&tx, "::staking_contract::Distribute");
    assert_eq!(emitted.len(), 1);
    assert_eq!(integer(&emitted[0].data["amount"]), 30);
    assert_eq!(address(&emitted[0].data["recipient"]), scope.staker);
    assert_eq!(
        balance(f, scope.staker, at).await - balance(f, scope.staker, at - 1).await,
        30
    );
    wallet_delta(f, &tx, 0).await;
}
async fn zero_commission(f: &Fixture, scope: &Scope, actor: &LocalAccount) {
    let tx = success(
        execute(
            &f.client,
            actor,
            &f.factory,
            aptos_stdlib::staking_contract_request_commission(scope.staker, scope.operator),
        )
        .await,
    );
    let at = tx.info.version.0;
    assert_eq!(
        contract(f, scope, at - 1).await,
        contract(f, scope, at).await
    );
    assert!(events(&tx, "::staking_contract::RequestCommission").is_empty());
    wallet_delta(f, &tx, 0).await;
}

#[tokio::test]
async fn poc_frozen_staking_contract_wrappers_restore_principal_and_distributions() {
    let f = setup().await;
    let staker = funded(&f).await;
    let operator = funded(&f).await;
    let voter = funded(&f).await;
    let beneficiary = funded(&f).await;
    let created = success(
        execute(
            &f.client,
            &staker,
            &f.factory,
            aptos_stdlib::staking_contract_create_staking_contract(
                operator.address(),
                voter.address(),
                300,
                37,
                b"poc-freeze-staking".to_vec(),
            ),
        )
        .await,
    );
    let pool = address(
        &view(
            &f,
            "staking_contract::stake_pool_address",
            vec![json!(staker.address()), json!(operator.address())],
            created.info.version.0,
        )
        .await[0],
    );
    let scope = Scope {
        staker: staker.address(),
        operator: operator.address(),
        pool,
        wallets: vec![
            staker.address(),
            operator.address(),
            voter.address(),
            beneficiary.address(),
            f.attacker.address(),
        ],
        vesting_admin: None,
    };
    assert_contract(&f, &scope, created.info.version.0, 300, 0).await;
    success(
        execute(
            &f.client,
            &operator,
            &f.factory,
            aptos_stdlib::staking_contract_set_beneficiary_for_operator(beneficiary.address()),
        )
        .await,
    );
    for actor in [&staker, &operator, &beneficiary] {
        zero_commission(&f, &scope, actor).await;
    }
    for call in STAKING_CALLS {
        staking_success(&f, &scope, &staker, call).await;
        reject(
            &f,
            &scope,
            &f.attacker,
            call.payload(scope.operator),
            "staking_contract",
            0x60003,
        )
        .await;
    }
    staking_distribute(&f, &scope, &f.attacker).await;
    reject(
        &f,
        &scope,
        &f.attacker,
        aptos_stdlib::staking_contract_request_commission(scope.staker, scope.operator),
        "staking_contract",
        0x40008,
    )
    .await;
    staking_success(&f, &scope, &staker, StakingCall::Unlock).await;
    wait_expired(&f, pool).await;
    let frozen = freeze(&f).await;
    for call in STAKING_CALLS {
        reject(
            &f,
            &scope,
            &staker,
            call.payload(scope.operator),
            "stake",
            0x30014,
        )
        .await;
        reject(
            &f,
            &scope,
            &f.attacker,
            call.payload(scope.operator),
            "staking_contract",
            0x60003,
        )
        .await;
    }
    // distribute 无调用身份限制；无论由所有者还是无关账户签名，
    // 其正金额支付在冻结期间都应以相同原因被拒绝。
    for actor in [&staker, &f.attacker] {
        reject(
            &f,
            &scope,
            actor,
            aptos_stdlib::staking_contract_distribute(scope.staker, scope.operator),
            "stake",
            0x30014,
        )
        .await;
    }
    for actor in [&staker, &operator, &beneficiary] {
        reject(
            &f,
            &scope,
            actor,
            aptos_stdlib::staking_contract_request_commission(scope.staker, scope.operator),
            "stake",
            0x30014,
        )
        .await;
    }
    reject(
        &f,
        &scope,
        &f.attacker,
        aptos_stdlib::staking_contract_request_commission(scope.staker, scope.operator),
        "staking_contract",
        0x40008,
    )
    .await;
    assert_frozen(&f, &frozen, version(&f).await).await;
    finish(&f, &frozen).await;
    staking_distribute(&f, &scope, &f.attacker).await;
    for actor in [&staker, &operator, &beneficiary] {
        zero_commission(&f, &scope, actor).await;
    }
    for call in STAKING_CALLS {
        staking_success(&f, &scope, &staker, call).await;
        reject(
            &f,
            &scope,
            &f.attacker,
            call.payload(scope.operator),
            "staking_contract",
            0x60003,
        )
        .await;
    }
    staking_distribute(&f, &scope, &f.attacker).await;
    reject(
        &f,
        &scope,
        &f.attacker,
        aptos_stdlib::staking_contract_request_commission(scope.staker, scope.operator),
        "staking_contract",
        0x40008,
    )
    .await;
    assert_contract(&f, &scope, version(&f).await, 230, 0).await;
}

async fn vesting_reset(f: &Fixture, scope: &Scope, admin: &LocalAccount) {
    wait_valid_reset(f, scope.pool).await;
    let tx = success(
        execute(
            &f.client,
            admin,
            &f.factory,
            aptos_stdlib::vesting_reset_lockup(scope.staker),
        )
        .await,
    );
    let at = tx.info.version.0;
    let old = resource(f, scope.pool, "stake::StakePool", at - 1).await;
    let new = resource(f, scope.pool, "stake::StakePool", at).await;
    assert!(integer(&new["locked_until_secs"]) > integer(&old["locked_until_secs"]));
    assert_eq!(balances(&old), balances(&new));
    assert_eq!(events(&tx, "::vesting::ResetLockup").len(), 1);
    assert_eq!(events(&tx, "::staking_contract::ResetLockup").len(), 1);
    wallet_delta(f, &tx, 0).await;
}
async fn vesting_vest(f: &Fixture, scope: &Scope, sender: &LocalAccount, next_period: u64) {
    let state = resource(
        f,
        scope.staker,
        "vesting::VestingContract",
        version(f).await,
    )
    .await;
    let schedule = &state["vesting_schedule"];
    wait_until(
        f,
        integer(&schedule["start_timestamp_secs"])
            + next_period * integer(&schedule["period_duration"]),
    )
    .await;
    let tx = success(
        execute(
            &f.client,
            sender,
            &f.factory,
            aptos_stdlib::vesting_vest(scope.staker),
        )
        .await,
    );
    let at = tx.info.version.0;
    let before = resource(f, scope.staker, "vesting::VestingContract", at - 1).await;
    let after = resource(f, scope.staker, "vesting::VestingContract", at).await;
    assert_eq!(
        integer(&before["vesting_schedule"]["last_vested_period"]) + 1,
        next_period
    );
    assert_eq!(
        integer(&after["vesting_schedule"]["last_vested_period"]),
        next_period
    );
    assert_eq!(
        integer(&before["remaining_grant"]) - integer(&after["remaining_grant"]),
        100
    );
    assert_eq!(integer(&after["remaining_grant"]), 400 - 100 * next_period);
    assert_eq!(before["grant_pool"], after["grant_pool"]);
    let emitted = events(&tx, "::vesting::Vest");
    assert_eq!(emitted.len(), 1);
    assert_eq!(integer(&emitted[0].data["period_vested"]), next_period);
    assert_eq!(integer(&emitted[0].data["amount"]), 100);
    wallet_delta(f, &tx, 0).await;
}
async fn vesting_distribute(
    f: &Fixture,
    scope: &Scope,
    sender: &LocalAccount,
    first: AccountAddress,
    second: AccountAddress,
    expected: u64,
) {
    wait_expired(f, scope.pool).await;
    let tx = success(
        execute(
            &f.client,
            sender,
            &f.factory,
            aptos_stdlib::vesting_distribute(scope.staker),
        )
        .await,
    );
    let at = tx.info.version.0;
    let emitted = events(&tx, "::vesting::Distribute");
    assert_eq!(emitted.len(), 1);
    assert_eq!(integer(&emitted[0].data["amount"]), expected);
    assert_eq!(
        balance(f, first, at).await - balance(f, first, at - 1).await,
        expected / 4
    );
    assert_eq!(
        balance(f, second, at).await - balance(f, second, at - 1).await,
        expected * 3 / 4
    );
    assert_eq!(balance(f, scope.staker, at).await, 0);
    let remaining = integer(
        &resource(f, scope.staker, "vesting::VestingContract", at).await["remaining_grant"],
    );
    assert_contract(f, scope, at, remaining, 0).await;
    wallet_delta(f, &tx, 0).await;
}

#[tokio::test]
async fn poc_frozen_vesting_wrappers_restore_grant_and_beneficiary_payments() {
    Lazy::force(&CREATE_VESTING);
    let f = setup().await;
    let admin = funded(&f).await;
    let first = funded(&f).await;
    let second = funded(&f).await;
    let operator = funded(&f).await;
    let voter = funded(&f).await;
    let created = success(
        execute(
            &f.client,
            &admin,
            &f.factory,
            TransactionPayload::Script(Script::new(CREATE_VESTING.clone(), vec![], vec![
                TransactionArgument::Address(first.address()),
                TransactionArgument::Address(second.address()),
                TransactionArgument::Address(operator.address()),
                TransactionArgument::Address(voter.address()),
            ])),
        )
        .await,
    );
    let events = events(&created, "::vesting::CreateVestingContract");
    assert_eq!(events.len(), 1);
    let contract = address(&events[0].data["vesting_contract_address"]);
    let pool = address(&events[0].data["staking_pool_address"]);
    let scope = Scope {
        staker: contract,
        operator: operator.address(),
        pool,
        wallets: vec![
            admin.address(),
            first.address(),
            second.address(),
            operator.address(),
            voter.address(),
            f.attacker.address(),
        ],
        vesting_admin: Some(admin.address()),
    };
    assert_contract(&f, &scope, created.info.version.0, 400, 0).await;
    wallet_delta(&f, &created, -400).await;
    vesting_reset(&f, &scope, &admin).await;
    reject(
        &f,
        &scope,
        &f.attacker,
        aptos_stdlib::vesting_reset_lockup(contract),
        "vesting",
        0x40007,
    )
    .await;
    // vest 和 distribute 均无调用身份限制。无关发送者支付 gas，
    // 两个实际份额持有人分别精确获得 25/75 Octa。
    vesting_vest(&f, &scope, &f.attacker, 1).await;
    vesting_distribute(
        &f,
        &scope,
        &f.attacker,
        first.address(),
        second.address(),
        100,
    )
    .await;
    vesting_vest(&f, &scope, &f.attacker, 2).await;
    wait_expired(&f, pool).await;
    let state = resource(&f, contract, "vesting::VestingContract", version(&f).await).await;
    wait_until(
        &f,
        integer(&state["vesting_schedule"]["start_timestamp_secs"]) + 3,
    )
    .await;
    let frozen = freeze(&f).await;
    reject(
        &f,
        &scope,
        &admin,
        aptos_stdlib::vesting_reset_lockup(contract),
        "stake",
        0x30014,
    )
    .await;
    reject(
        &f,
        &scope,
        &f.attacker,
        aptos_stdlib::vesting_reset_lockup(contract),
        "vesting",
        0x40007,
    )
    .await;
    for actor in [&admin, &f.attacker] {
        // vest 先减少 remaining_grant 并推进 last_vested_period，
        // 随后正金额解锁才触及底层质押能力的冻结检查。
        reject(
            &f,
            &scope,
            actor,
            aptos_stdlib::vesting_vest(contract),
            "stake",
            0x30014,
        )
        .await;
        reject(
            &f,
            &scope,
            actor,
            aptos_stdlib::vesting_distribute(contract),
            "stake",
            0x30014,
        )
        .await;
    }
    assert_frozen(&f, &frozen, version(&f).await).await;
    finish(&f, &frozen).await;
    vesting_reset(&f, &scope, &admin).await;
    reject(
        &f,
        &scope,
        &f.attacker,
        aptos_stdlib::vesting_reset_lockup(contract),
        "vesting",
        0x40007,
    )
    .await;
    vesting_vest(&f, &scope, &f.attacker, 3).await;
    vesting_distribute(
        &f,
        &scope,
        &f.attacker,
        first.address(),
        second.address(),
        200,
    )
    .await;
    assert_contract(&f, &scope, version(&f).await, 100, 0).await;
}

async fn create_additional_vesting(
    f: &Fixture,
    admin: &LocalAccount,
    first: AccountAddress,
    second: AccountAddress,
    operator: AccountAddress,
    voter: AccountAddress,
) -> Scope {
    let tx = success(
        execute(
            &f.client,
            admin,
            &f.factory,
            TransactionPayload::Script(Script::new(CREATE_VESTING.clone(), vec![], vec![
                TransactionArgument::Address(first),
                TransactionArgument::Address(second),
                TransactionArgument::Address(operator),
                TransactionArgument::Address(voter),
            ])),
        )
        .await,
    );
    let created = events(&tx, "::vesting::CreateVestingContract");
    assert_eq!(created.len(), 1);
    assert_eq!(integer(&created[0].data["grant_amount"]), 400);
    assert_eq!(address(&created[0].data["withdrawal_address"]), first);
    let scope = Scope {
        staker: address(&created[0].data["vesting_contract_address"]),
        operator,
        pool: address(&created[0].data["staking_pool_address"]),
        wallets: vec![
            admin.address(),
            first,
            second,
            operator,
            voter,
            f.attacker.address(),
        ],
        vesting_admin: Some(admin.address()),
    };
    assert_contract(f, &scope, tx.info.version.0, 400, 0).await;
    wallet_delta(f, &tx, -400).await;
    scope
}

async fn reject_vesting_batch(
    f: &Fixture,
    scopes: &[&Scope],
    actor: &LocalAccount,
    payload: TransactionPayload,
    module: &str,
    code: u64,
) {
    // 通用拒绝断言检查同一笔真实 VM 输出；额外的 scope 将同一组
    // v-1/v 证据扩展到批次中的每个合约。
    let tx = reject(f, scopes[0], actor, payload, module, code).await;
    let at = tx.info.version.0;
    for scope in &scopes[1..] {
        assert_eq!(
            snapshot(f, scope, actor.address(), at - 1).await,
            snapshot(f, scope, actor.address(), at).await
        );
    }
}

async fn terminate_vesting(
    f: &Fixture,
    scope: &Scope,
    admin: &LocalAccount,
    first: AccountAddress,
    second: AccountAddress,
) {
    wait_expired(f, scope.pool).await;
    let tx = success(
        execute(
            &f.client,
            admin,
            &f.factory,
            aptos_stdlib::vesting_terminate_vesting_contract(scope.staker),
        )
        .await,
    );
    let at = tx.info.version.0;
    assert_contract(f, scope, at - 1, 300, 100).await;
    let mut expected = resource(f, scope.staker, "vesting::VestingContract", at - 1).await;
    assert_eq!(integer(&expected["state"]), 1);
    assert_eq!(integer(&expected["remaining_grant"]), 300);
    assert_eq!(
        integer(&expected["vesting_schedule"]["last_vested_period"]),
        1
    );
    expected["state"] = json!("2");
    expected["remaining_grant"] = json!("0");
    assert_eq!(
        resource(f, scope.staker, "vesting::VestingContract", at).await,
        expected
    );
    assert_contract(f, scope, at, 0, 300).await;
    let terminated = events(&tx, "::vesting::Terminate");
    assert_eq!(terminated.len(), 1);
    assert_eq!(
        terminated[0].data,
        json!({"admin": admin.address().to_hex_literal(), "vesting_contract_address": scope.staker.to_hex_literal()})
    );
    let distributions = events(&tx, "::vesting::Distribute");
    assert_eq!(distributions.len(), 1);
    assert_eq!(
        distributions[0].data,
        json!({"admin": admin.address().to_hex_literal(), "vesting_contract_address": scope.staker.to_hex_literal(), "amount": "100"})
    );
    let unlocked = events(&tx, "::staking_contract::UnlockStake");
    assert_eq!(unlocked.len(), 1);
    assert_eq!(address(&unlocked[0].data["pool_address"]), scope.pool);
    assert_eq!(integer(&unlocked[0].data["amount"]), 300);
    assert_eq!(integer(&unlocked[0].data["commission_paid"]), 0);
    assert_eq!(
        balance(f, first, at).await - balance(f, first, at - 1).await,
        25
    );
    assert_eq!(
        balance(f, second, at).await - balance(f, second, at - 1).await,
        75
    );
    for wallet in [scope.operator, scope.staker, scope.pool] {
        assert_eq!(
            balance(f, wallet, at).await,
            balance(f, wallet, at - 1).await
        );
    }
    wallet_delta(f, &tx, 0).await;
    println!("Vesting terminated: contract={}, pool={}, version={at}, distributed=100 (25/75), remaining_unlocked=300, grant=0, commission=0", scope.staker, scope.pool);
}

async fn admin_withdraw_vesting(
    f: &Fixture,
    scope: &Scope,
    admin: &LocalAccount,
    first: AccountAddress,
    second: AccountAddress,
) {
    wait_expired(f, scope.pool).await;
    let tx = success(
        execute(
            &f.client,
            admin,
            &f.factory,
            aptos_stdlib::vesting_admin_withdraw(scope.staker),
        )
        .await,
    );
    let at = tx.info.version.0;
    assert_contract(f, scope, at - 1, 0, 300).await;
    let before = resource(f, scope.staker, "vesting::VestingContract", at - 1).await;
    assert_eq!(integer(&before["state"]), 2);
    assert_eq!(integer(&before["remaining_grant"]), 0);
    assert_eq!(
        resource(f, scope.staker, "vesting::VestingContract", at).await,
        before
    );
    assert_contract(f, scope, at, 0, 0).await;
    let withdrawn = events(&tx, "::vesting::AdminWithdraw");
    assert_eq!(withdrawn.len(), 1);
    assert_eq!(
        withdrawn[0].data,
        json!({"admin": admin.address().to_hex_literal(), "vesting_contract_address": scope.staker.to_hex_literal(), "amount": "300"})
    );
    assert!(events(&tx, "::vesting::Distribute").is_empty());
    assert_eq!(
        balance(f, first, at).await - balance(f, first, at - 1).await,
        300
    );
    for wallet in [second, scope.operator, scope.staker, scope.pool] {
        assert_eq!(
            balance(f, wallet, at).await,
            balance(f, wallet, at - 1).await
        );
    }
    wallet_delta(f, &tx, 0).await;
    println!("Terminated grant withdrawn: contract={}, version={at}, withdrawal_address={first}, amount=300; shareholders receive no second vest distribution", scope.staker);
}

#[tokio::test]
async fn poc_frozen_vesting_termination_and_admin_withdraw_preserve_payments() {
    Lazy::force(&CREATE_VESTING);
    let f = setup().await;
    let admin = funded(&f).await;
    let first = funded(&f).await;
    let second = funded(&f).await;
    let operator = funded(&f).await;
    let voter = funded(&f).await;
    let initial_version = version(&f).await;
    let first_before = balance(&f, first.address(), initial_version).await;
    let second_before = balance(&f, second.address(), initial_version).await;
    let mut scopes = Vec::new();
    for _ in 0..3 {
        let scope = create_additional_vesting(
            &f,
            &admin,
            first.address(),
            second.address(),
            operator.address(),
            voter.address(),
        )
        .await;
        vesting_vest(&f, &scope, &f.attacker, 1).await;
        wait_expired(&f, scope.pool).await;
        scopes.push(scope);
    }
    assert_eq!(
        scopes
            .iter()
            .map(|scope| scope.staker)
            .collect::<BTreeSet<_>>()
            .len(),
        3
    );
    let normal = &scopes[0];
    let withdrawing = &scopes[1];
    let terminating = &scopes[2];

    // terminate 先分发已归属的 100 Octa，再检查调用者身份；
    // 未授权事务也必须回滚这笔支付。
    reject(
        &f,
        normal,
        &f.attacker,
        aptos_stdlib::vesting_terminate_vesting_contract(normal.staker),
        "vesting",
        0x40007,
    )
    .await;
    for actor in [&admin, &f.attacker] {
        reject(
            &f,
            normal,
            actor,
            aptos_stdlib::vesting_admin_withdraw(normal.staker),
            "vesting",
            0x30009,
        )
        .await;
    }
    terminate_vesting(&f, normal, &admin, first.address(), second.address()).await;
    reject(
        &f,
        normal,
        &f.attacker,
        aptos_stdlib::vesting_admin_withdraw(normal.staker),
        "vesting",
        0x40007,
    )
    .await;
    admin_withdraw_vesting(&f, normal, &admin, first.address(), second.address()).await;

    // 第二笔正金额授予已终止，剩余 300 Octa 全部待提取；
    // 第三笔仍处于活跃状态，有已归属且可支付的 100 Octa。
    terminate_vesting(&f, withdrawing, &admin, first.address(), second.address()).await;
    wait_expired(&f, withdrawing.pool).await;
    let frozen = freeze(&f).await;
    for actor in [&admin, &f.attacker] {
        // terminate 中的 distribute -> stake 调用先于 verify_admin。
        reject(
            &f,
            terminating,
            actor,
            aptos_stdlib::vesting_terminate_vesting_contract(terminating.staker),
            "stake",
            0x30014,
        )
        .await;
        // admin_withdraw 先检查合约状态，再检查身份或调用 stake。
        reject(
            &f,
            terminating,
            actor,
            aptos_stdlib::vesting_admin_withdraw(terminating.staker),
            "vesting",
            0x30009,
        )
        .await;
        reject(
            &f,
            withdrawing,
            actor,
            aptos_stdlib::vesting_terminate_vesting_contract(withdrawing.staker),
            "vesting",
            0x30008,
        )
        .await;
    }
    reject(
        &f,
        withdrawing,
        &admin,
        aptos_stdlib::vesting_admin_withdraw(withdrawing.staker),
        "stake",
        0x30014,
    )
    .await;
    reject(
        &f,
        withdrawing,
        &f.attacker,
        aptos_stdlib::vesting_admin_withdraw(withdrawing.staker),
        "vesting",
        0x40007,
    )
    .await;
    assert_frozen(&f, &frozen, version(&f).await).await;
    finish(&f, &frozen).await;

    // 恢复后对相同池地址重试，原有正金额分发均已保留。
    // 各辅助函数按实际时间检查到期条件。
    reject(
        &f,
        terminating,
        &f.attacker,
        aptos_stdlib::vesting_terminate_vesting_contract(terminating.staker),
        "vesting",
        0x40007,
    )
    .await;
    terminate_vesting(&f, terminating, &admin, first.address(), second.address()).await;
    for scope in [withdrawing, terminating] {
        reject(
            &f,
            scope,
            &f.attacker,
            aptos_stdlib::vesting_admin_withdraw(scope.staker),
            "vesting",
            0x40007,
        )
        .await;
        admin_withdraw_vesting(&f, scope, &admin, first.address(), second.address()).await;
        reject(
            &f,
            scope,
            &admin,
            aptos_stdlib::vesting_terminate_vesting_contract(scope.staker),
            "vesting",
            0x30008,
        )
        .await;
    }
    let at = version(&f).await;
    assert_eq!(balance(&f, first.address(), at).await - first_before, 975);
    assert_eq!(balance(&f, second.address(), at).await - second_before, 225);
    for scope in &scopes {
        assert_contract(&f, scope, at, 0, 0).await;
    }
    println!("FRZ-02 termination/admin withdrawal complete: 3x400-Octa grants, first recipient=975, second recipient=225, failed transactions paid no beneficiaries, version={at}");
}

async fn distribute_vesting_batch(
    f: &Fixture,
    scopes: &[&Scope],
    actor: &LocalAccount,
    first: AccountAddress,
    second: AccountAddress,
    vested_period: u64,
) {
    for scope in scopes {
        wait_expired(f, scope.pool).await;
    }
    let tx = success(
        execute(
            &f.client,
            actor,
            &f.factory,
            aptos_stdlib::vesting_distribute_many(
                scopes.iter().map(|scope| scope.staker).collect(),
            ),
        )
        .await,
    );
    let at = tx.info.version.0;
    let emitted = events(&tx, "::vesting::Distribute");
    assert_eq!(emitted.len(), scopes.len());
    let total = scopes.len() as u64 * 100;
    for (scope, event) in scopes.iter().zip(emitted) {
        let remaining = 400 - 100 * vested_period;
        assert_contract(f, scope, at - 1, remaining, 100).await;
        assert_contract(f, scope, at, remaining, 0).await;
        assert_eq!(
            event.data,
            json!({
                "admin": scope.vesting_admin.unwrap().to_hex_literal(),
                "vesting_contract_address": scope.staker.to_hex_literal(), "amount": "100"
            })
        );
        assert_eq!(
            resource(f, scope.staker, "vesting::VestingContract", at - 1).await,
            resource(f, scope.staker, "vesting::VestingContract", at).await
        );
        assert_eq!(balance(f, scope.staker, at).await, 0);
        assert_eq!(balance(f, scope.pool, at).await, 0);
        for wallet in &scope.wallets {
            if ![actor.address(), first, second].contains(wallet) {
                assert_eq!(
                    balance(f, *wallet, at - 1).await,
                    balance(f, *wallet, at).await
                );
            }
        }
    }
    assert_eq!(
        balance(f, first, at).await - balance(f, first, at - 1).await,
        total / 4
    );
    assert_eq!(
        balance(f, second, at).await - balance(f, second, at - 1).await,
        total * 3 / 4
    );
    wallet_delta(f, &tx, 0).await;
    println!("Vesting distribute_many committed: contracts={}, total={total}, first={}, second={}, sender={}, version={at}", scopes.len(), total / 4, total * 3 / 4, actor.address());
}

#[tokio::test]
async fn poc_frozen_vesting_distribute_many_rolls_back_earlier_payments() {
    Lazy::force(&CREATE_VESTING);
    let f = setup().await;
    let admin = funded(&f).await;
    let first = funded(&f).await;
    let second = funded(&f).await;
    let operator = funded(&f).await;
    let voter = funded(&f).await;
    let initial_version = version(&f).await;
    let first_before = balance(&f, first.address(), initial_version).await;
    let second_before = balance(&f, second.address(), initial_version).await;
    let mut scopes = Vec::new();
    for _ in 0..3 {
        let scope = create_additional_vesting(
            &f,
            &admin,
            first.address(),
            second.address(),
            operator.address(),
            voter.address(),
        )
        .await;
        vesting_vest(&f, &scope, &f.attacker, 1).await;
        scopes.push(scope);
    }
    assert_eq!(
        scopes
            .iter()
            .map(|scope| scope.staker)
            .collect::<BTreeSet<_>>()
            .len(),
        3
    );
    let first_contract = &scopes[0];
    let second_contract = &scopes[1];
    let terminated = &scopes[2];
    terminate_vesting(&f, terminated, &admin, first.address(), second.address()).await;
    admin_withdraw_vesting(&f, terminated, &admin, first.address(), second.address()).await;
    let normal = [first_contract, second_contract];
    let all = [first_contract, second_contract, terminated];
    let addresses = vec![first_contract.staker, second_contract.staker];
    let bad_after_payment = vec![first_contract.staker, terminated.staker];
    // distribute_many 无调用身份限制，因此无关账户也可合法调用。
    distribute_vesting_batch(
        &f,
        &normal,
        &f.attacker,
        first.address(),
        second.address(),
        1,
    )
    .await;
    for scope in normal {
        vesting_vest(&f, scope, &f.attacker, 2).await;
        wait_expired(&f, scope.pool).await;
    }
    // 首项有可提取的 100 Octa，会向真实收款人支付；第二项的活跃状态
    // 检查失败。整笔事务必须回滚首项的支付、份额赎回及事件。
    reject_vesting_batch(
        &f,
        &all,
        &f.attacker,
        aptos_stdlib::vesting_distribute_many(bad_after_payment.clone()),
        "vesting",
        0x30008,
    )
    .await;
    reject_vesting_batch(
        &f,
        &all,
        &f.attacker,
        aptos_stdlib::vesting_distribute_many(vec![]),
        "vesting",
        0x10010,
    )
    .await;
    let frozen = freeze(&f).await;
    for actor in [&admin, &f.attacker] {
        reject_vesting_batch(
            &f,
            &all,
            actor,
            aptos_stdlib::vesting_distribute_many(addresses.clone()),
            "stake",
            0x30014,
        )
        .await;
    }
    reject_vesting_batch(
        &f,
        &all,
        &f.attacker,
        aptos_stdlib::vesting_distribute_many(bad_after_payment.clone()),
        "stake",
        0x30014,
    )
    .await;
    reject_vesting_batch(
        &f,
        &all,
        &f.attacker,
        aptos_stdlib::vesting_distribute_many(vec![terminated.staker, first_contract.staker]),
        "vesting",
        0x30008,
    )
    .await;
    reject_vesting_batch(
        &f,
        &all,
        &f.attacker,
        aptos_stdlib::vesting_distribute_many(vec![]),
        "vesting",
        0x10010,
    )
    .await;
    assert_frozen(&f, &frozen, version(&f).await).await;
    finish(&f, &frozen).await;
    reject_vesting_batch(
        &f,
        &all,
        &admin,
        aptos_stdlib::vesting_distribute_many(bad_after_payment),
        "vesting",
        0x30008,
    )
    .await;
    distribute_vesting_batch(&f, &normal, &admin, first.address(), second.address(), 2).await;
    let at = version(&f).await;
    assert_contract(&f, first_contract, at, 200, 0).await;
    assert_contract(&f, second_contract, at, 200, 0).await;
    assert_contract(&f, terminated, at, 0, 0).await;
    // 三笔各 400 Octa 的授予最终保留 400 Octa 质押，精确支付 800 Octa：
    // 两次合法批量操作合计支付 100/300，已终止授予支付 325/75。
    assert_eq!(balance(&f, first.address(), at).await - first_before, 425);
    assert_eq!(balance(&f, second.address(), at).await - second_before, 375);
    println!("FRZ-02 distribute_many complete: valid batches paid 200 Octa before and after freeze; invalid suffix rolled back the preceding 100-Octa payment, version={at}");
}

async fn wait_for_vest_period(f: &Fixture, scope: &Scope, period: u64) {
    let state = resource(
        f,
        scope.staker,
        "vesting::VestingContract",
        version(f).await,
    )
    .await;
    let schedule = &state["vesting_schedule"];
    wait_until(
        f,
        integer(&schedule["start_timestamp_secs"]) + period * integer(&schedule["period_duration"]),
    )
    .await;
    wait_expired(f, scope.pool).await;
}

/// 首批为每笔授予解锁 100 Octa；第二批须先将上一笔 100 Octa
/// 提取到各 vesting 账户，再排定新一笔 100 Octa 分发。
/// 两批均需等到调用 vesting::distribute 时才向份额持有人支付。
async fn vest_vesting_batch(
    f: &Fixture,
    scopes: &[&Scope],
    actor: &LocalAccount,
    next_period: u64,
) {
    assert!((1..=2).contains(&next_period));
    for scope in scopes {
        wait_for_vest_period(f, scope, next_period).await;
    }
    let tx = success(
        execute(
            &f.client,
            actor,
            &f.factory,
            aptos_stdlib::vesting_vest_many(scopes.iter().map(|scope| scope.staker).collect()),
        )
        .await,
    );
    let at = tx.info.version.0;
    let old_distribution = (next_period - 1) * 100;
    let remaining_before = 400 - (next_period - 1) * 100;
    let remaining_after = remaining_before - 100;
    let vested = events(&tx, "::vesting::Vest");
    let unlocked = events(&tx, "::staking_contract::UnlockStake");
    let distributions = events(&tx, "::staking_contract::Distribute");
    assert_eq!(vested.len(), scopes.len());
    assert_eq!(unlocked.len(), scopes.len());
    assert_eq!(
        distributions.len(),
        if next_period == 2 { scopes.len() } else { 0 }
    );
    assert!(events(&tx, "::vesting::Distribute").is_empty());
    for (index, scope) in scopes.iter().enumerate() {
        assert_contract(f, scope, at - 1, remaining_before, old_distribution).await;
        assert_contract(f, scope, at, remaining_after, 100).await;
        let mut expected_grant =
            resource(f, scope.staker, "vesting::VestingContract", at - 1).await;
        assert_eq!(integer(&expected_grant["state"]), 1);
        assert_eq!(
            integer(&expected_grant["remaining_grant"]),
            remaining_before
        );
        assert_eq!(
            integer(&expected_grant["vesting_schedule"]["last_vested_period"]),
            next_period - 1
        );
        expected_grant["remaining_grant"] = json!(remaining_after.to_string());
        expected_grant["vesting_schedule"]["last_vested_period"] = json!(next_period.to_string());
        assert_eq!(
            resource(f, scope.staker, "vesting::VestingContract", at).await,
            expected_grant
        );

        // 比较完整的内联份额映射、份额持有人列表及能力字段。
        // 旧份额先被赎回，随后才以新一笔 100 Octa 购入份额。
        let mut expected_contract = contract(f, scope, at - 1).await;
        expected_contract["principal"] = json!(remaining_after.to_string());
        expected_contract["distribution_pool"]["total_coins"] = json!("100");
        expected_contract["distribution_pool"]["total_shares"] = json!("100");
        expected_contract["distribution_pool"]["shares"]["data"] =
            json!([{"key": scope.staker.to_hex_literal(), "value": "100"}]);
        expected_contract["distribution_pool"]["shareholders"] =
            json!([scope.staker.to_hex_literal()]);
        assert_eq!(contract(f, scope, at).await, expected_contract);
        let mut expected_stake = resource(f, scope.pool, "stake::StakePool", at - 1).await;
        expected_stake["active"]["value"] = json!(remaining_after.to_string());
        expected_stake["pending_inactive"]["value"] = json!("100");
        assert_eq!(
            resource(f, scope.pool, "stake::StakePool", at).await,
            expected_stake
        );

        assert_eq!(
            vested[index].data,
            json!({
                "admin": scope.vesting_admin.unwrap().to_hex_literal(),
                "vesting_contract_address": scope.staker.to_hex_literal(),
                "staking_pool_address": scope.pool.to_hex_literal(),
                "period_vested": next_period.to_string(), "amount": "100"
            })
        );
        assert_eq!(
            unlocked[index].data,
            json!({
                "operator": scope.operator.to_hex_literal(), "pool_address": scope.pool.to_hex_literal(),
                "amount": "100", "commission_paid": "0"
            })
        );
        if next_period == 2 {
            assert_eq!(
                distributions[index].data,
                json!({
                    "operator": scope.operator.to_hex_literal(), "pool_address": scope.pool.to_hex_literal(),
                    "recipient": scope.staker.to_hex_literal(), "amount": "100"
                })
            );
        }
        assert_eq!(balance(f, scope.staker, at - 1).await, 0);
        assert_eq!(balance(f, scope.staker, at).await, old_distribution);
        assert_eq!(balance(f, scope.pool, at).await, 0);
        for wallet in &scope.wallets {
            if *wallet != actor.address() {
                assert_eq!(
                    balance(f, *wallet, at).await,
                    balance(f, *wallet, at - 1).await
                );
            }
        }
        println!("Vesting vest_many item: contract={}, period={next_period}, grant={remaining_after}, vesting_wallet={old_distribution}, new_pending=100, version={at}", scope.staker);
    }
    wallet_delta(f, &tx, 0).await;
}

#[tokio::test]
async fn poc_frozen_vesting_vest_many_rolls_back_grants_and_pending_distributions() {
    Lazy::force(&CREATE_VESTING);
    let f = setup().await;
    let admin = funded(&f).await;
    let first = funded(&f).await;
    let second = funded(&f).await;
    let operator = funded(&f).await;
    let voter = funded(&f).await;
    let initial_version = version(&f).await;
    let first_before = balance(&f, first.address(), initial_version).await;
    let second_before = balance(&f, second.address(), initial_version).await;
    let mut scopes = Vec::new();
    for _ in 0..3 {
        scopes.push(
            create_additional_vesting(
                &f,
                &admin,
                first.address(),
                second.address(),
                operator.address(),
                voter.address(),
            )
            .await,
        );
    }
    assert_eq!(
        scopes
            .iter()
            .map(|scope| scope.staker)
            .collect::<BTreeSet<_>>()
            .len(),
        3
    );
    let first_contract = &scopes[0];
    let second_contract = &scopes[1];
    let terminated = &scopes[2];
    vesting_vest(&f, terminated, &f.attacker, 1).await;
    terminate_vesting(&f, terminated, &admin, first.address(), second.address()).await;
    admin_withdraw_vesting(&f, terminated, &admin, first.address(), second.address()).await;
    let live = [first_contract, second_contract];
    let all = [first_contract, second_contract, terminated];
    let addresses = vec![first_contract.staker, second_contract.staker];
    let invalid_suffix = vec![first_contract.staker, terminated.staker];

    // 公开批量入口允许无关账户调用，并为两笔授予解锁正金额。
    // 保留旧分发，使下次 vest 的首项确实执行赎回，避免成为空操作。
    vest_vesting_batch(&f, &live, &f.attacker, 1).await;
    for scope in live {
        wait_for_vest_period(&f, scope, 2).await;
    }
    let prepared = version(&f).await;
    for scope in live {
        assert_contract(&f, scope, prepared, 300, 100).await;
        assert_eq!(balance(&f, scope.staker, prepared).await, 0);
    }
    // A 推进归属计划，将旧的 100 Octa 赎回到其 vesting 钱包，
    // 再排定新的 100 Octa。随后 T 因已终止而拒绝，VM 必须回滚
    // A 的授予、本金、内联份额、钱包及事件。
    reject_vesting_batch(
        &f,
        &all,
        &f.attacker,
        aptos_stdlib::vesting_vest_many(invalid_suffix.clone()),
        "vesting",
        0x30008,
    )
    .await;
    reject_vesting_batch(
        &f,
        &all,
        &f.attacker,
        aptos_stdlib::vesting_vest_many(vec![]),
        "vesting",
        0x10010,
    )
    .await;

    let frozen = freeze(&f).await;
    for actor in [&admin, &f.attacker] {
        // vest_many 无调用身份限制。两个调用者均在 vest 更新外层
        // 授予状态后，才触及底层的正金额质押提取。
        reject_vesting_batch(
            &f,
            &all,
            actor,
            aptos_stdlib::vesting_vest_many(addresses.clone()),
            "stake",
            0x30014,
        )
        .await;
    }
    reject_vesting_batch(
        &f,
        &all,
        &f.attacker,
        aptos_stdlib::vesting_vest_many(invalid_suffix.clone()),
        "stake",
        0x30014,
    )
    .await;
    reject_vesting_batch(
        &f,
        &all,
        &f.attacker,
        aptos_stdlib::vesting_vest_many(vec![terminated.staker, first_contract.staker]),
        "vesting",
        0x30008,
    )
    .await;
    reject_vesting_batch(
        &f,
        &all,
        &f.attacker,
        aptos_stdlib::vesting_vest_many(vec![]),
        "vesting",
        0x10010,
    )
    .await;
    assert_frozen(&f, &frozen, version(&f).await).await;
    finish(&f, &frozen).await;

    reject_vesting_batch(
        &f,
        &all,
        &admin,
        aptos_stdlib::vesting_vest_many(invalid_suffix),
        "vesting",
        0x30008,
    )
    .await;
    vest_vesting_batch(&f, &live, &admin, 2).await;
    let vested = version(&f).await;
    for scope in live {
        // 恢复后的批次须保留两段金额：旧款已提取到当前钱包，
        // 新一笔授予仍处于待处理状态。
        assert_contract(&f, scope, vested, 200, 100).await;
        assert_eq!(balance(&f, scope.staker, vested).await, 100);
        let grant = resource(&f, scope.staker, "vesting::VestingContract", vested).await;
        assert_eq!(integer(&grant["remaining_grant"]), 200);
        assert_eq!(integer(&grant["vesting_schedule"]["last_vested_period"]), 2);
    }
    assert_eq!(
        balance(&f, first.address(), vested).await - first_before,
        325
    );
    assert_eq!(
        balance(&f, second.address(), vested).await - second_before,
        75
    );
    for scope in live {
        vesting_distribute(
            &f,
            scope,
            &f.attacker,
            first.address(),
            second.address(),
            200,
        )
        .await;
    }
    let at = version(&f).await;
    assert_contract(&f, first_contract, at, 200, 0).await;
    assert_contract(&f, second_contract, at, 200, 0).await;
    assert_contract(&f, terminated, at, 0, 0).await;
    assert_eq!(balance(&f, first.address(), at).await - first_before, 425);
    assert_eq!(balance(&f, second.address(), at).await - second_before, 375);
    println!("FRZ-02 vest_many complete: 3x400-Octa grants, 400 remain staked, first=425, second=375; restored batch preserved old wallet100 plus new pending100 per live grant, version={at}");
}

#[derive(Clone, Copy, Debug)]
enum ManagementCall {
    Switch(AccountAddress, u64),
    SwitchSameCommission(AccountAddress),
    Commission(u64),
}

impl ManagementCall {
    fn payload(self, scope: &Scope) -> TransactionPayload {
        match (scope.vesting_admin, self) {
            (None, Self::Switch(operator, percentage)) => {
                aptos_stdlib::staking_contract_switch_operator(scope.operator, operator, percentage)
            },
            (None, Self::SwitchSameCommission(operator)) => {
                aptos_stdlib::staking_contract_switch_operator_with_same_commission(
                    scope.operator,
                    operator,
                )
            },
            (None, Self::Commission(percentage)) => {
                aptos_stdlib::staking_contract_update_commision(scope.operator, percentage)
            },
            (Some(_), Self::Switch(operator, percentage)) => {
                aptos_stdlib::vesting_update_operator(scope.staker, operator, percentage)
            },
            (Some(_), Self::SwitchSameCommission(operator)) => {
                aptos_stdlib::vesting_update_operator_with_same_commission(scope.staker, operator)
            },
            (Some(_), Self::Commission(percentage)) => {
                aptos_stdlib::vesting_update_commission_percentage(scope.staker, percentage)
            },
        }
    }

    fn result(self, operator: AccountAddress, percentage: u64) -> (AccountAddress, u64) {
        match self {
            Self::Switch(operator, percentage) => (operator, percentage),
            Self::SwitchSameCommission(operator) => (operator, percentage),
            Self::Commission(percentage) => (operator, percentage),
        }
    }

    fn restore(self, original_operator: AccountAddress) -> Self {
        match self {
            Self::Switch(_, _) => Self::Switch(original_operator, 37),
            Self::SwitchSameCommission(_) => Self::SwitchSameCommission(original_operator),
            Self::Commission(_) => Self::Commission(37),
        }
    }

    fn changes_operator(self) -> bool {
        match self {
            Self::Switch(_, _) | Self::SwitchSameCommission(_) => true,
            Self::Commission(_) => false,
        }
    }
}

// 切换前后均纳入两个运营者的受益人资源。scope 中的当前运营者会变，
// 但受保护的资源集合不能随之改变。全部分发和授予份额仍保存在内联结构中。
async fn management_snapshot(
    f: &Fixture,
    scope: &Scope,
    actor: AccountAddress,
    at: u64,
) -> Snapshot {
    let mut state = snapshot(f, scope, actor, at).await;
    for wallet in &scope.wallets {
        let name = "staking_contract::BeneficiaryForOperator";
        let value = optional_resource_at_version(&f.client, *wallet, &format!("0x1::{name}"), at)
            .await
            .map(|resource| resource.data);
        if let Some(value) = &value {
            handles(value, &mut state.handles);
        }
        state.resources.insert(format!("{wallet}/{name}"), value);
    }
    assert!(state.handles.is_empty());
    state
}

fn contract_business_events(tx: &UserTransaction) -> Vec<(String, Value)> {
    tx.events
        .iter()
        .map(|event| (event.typ.to_string(), event.data.clone()))
        .filter(|(typ, _)| {
            typ.starts_with("0x1::stake::")
                || typ.starts_with("0x1::staking_contract::")
                || typ.starts_with("0x1::vesting::")
        })
        .collect()
}

async fn management_rejected(
    f: &Fixture,
    scope: &Scope,
    actor: &LocalAccount,
    payload: TransactionPayload,
    module: &str,
    code: u64,
) {
    let tx = reject(f, scope, actor, payload, module, code).await;
    let at = tx.info.version.0;
    assert_eq!(
        management_snapshot(f, scope, actor.address(), at - 1).await,
        management_snapshot(f, scope, actor.address(), at).await
    );
}

/// 金额来自明确解锁的本金，不取自链上报价。
/// 切换须保留原池、能力及验证者配置；只有 Store 键、运营者、佣金
/// 和已赎回的分发发生变化。
async fn management_success(
    f: &Fixture,
    scope: &mut Scope,
    actor: &LocalAccount,
    call: ManagementCall,
    distribution: u64,
) -> u64 {
    wait_expired(f, scope.pool).await;
    let tx = success(execute(&f.client, actor, &f.factory, call.payload(scope)).await);
    let at = tx.info.version.0;
    let mut expected = management_snapshot(f, scope, actor.address(), at - 1).await;
    let old_operator = scope.operator;
    let old_contract = contract(f, scope, at - 1).await;
    let principal = integer(&old_contract["principal"]);
    let old_percentage = integer(&old_contract["commission_percentage"]);
    let (new_operator, new_percentage) = call.result(old_operator, old_percentage);
    assert_eq!(address(&old_contract["pool_address"]), scope.pool);
    assert_eq!(
        integer(&old_contract["distribution_pool"]["total_coins"]),
        distribution
    );
    assert_eq!(
        integer(&old_contract["distribution_pool"]["total_shares"]),
        distribution
    );
    assert_eq!(
        old_contract["distribution_pool"]["shares"]["data"],
        if distribution == 0 {
            json!([])
        } else {
            json!([{"key": scope.staker.to_hex_literal(), "value": distribution.to_string()}])
        }
    );
    assert_eq!(
        old_contract["distribution_pool"]["shareholders"],
        if distribution == 0 {
            json!([])
        } else {
            json!([scope.staker.to_hex_literal()])
        }
    );

    let store = expected
        .resources
        .get_mut(&format!("{}/staking_contract::Store", scope.staker))
        .unwrap()
        .as_mut()
        .unwrap();
    let entries = store["staking_contracts"]["data"].as_array_mut().unwrap();
    let index = entries
        .iter()
        .position(|entry| address(&entry["key"]) == old_operator)
        .unwrap();
    let mut updated = old_contract;
    updated["commission_percentage"] = json!(new_percentage.to_string());
    updated["distribution_pool"]["total_coins"] = json!("0");
    updated["distribution_pool"]["total_shares"] = json!("0");
    updated["distribution_pool"]["shares"]["data"] = json!([]);
    updated["distribution_pool"]["shareholders"] = json!([]);
    if call.changes_operator() {
        assert_ne!(old_operator, new_operator);
        assert!(!entries
            .iter()
            .any(|entry| address(&entry["key"]) == new_operator));
        entries.swap_remove(index);
        entries.push(json!({"key": new_operator.to_hex_literal(), "value": updated}));
    } else {
        entries[index]["value"] = updated;
    }
    let stake = expected
        .resources
        .get_mut(&format!("{}/stake::StakePool", scope.pool))
        .unwrap()
        .as_mut()
        .unwrap();
    assert_eq!(balances(stake), [principal, 0, 0, distribution]);
    assert_eq!(address(&stake["operator_address"]), old_operator);
    stake["pending_inactive"]["value"] = json!("0");
    stake["operator_address"] = json!(new_operator.to_hex_literal());
    if scope.vesting_admin.is_some() {
        let vesting = expected
            .resources
            .get_mut(&format!("{}/vesting::VestingContract", scope.staker))
            .unwrap()
            .as_mut()
            .unwrap();
        assert_eq!(integer(&vesting["remaining_grant"]), principal);
        assert_eq!(address(&vesting["staking"]["operator"]), old_operator);
        assert_eq!(
            integer(&vesting["staking"]["commission_percentage"]),
            old_percentage
        );
        vesting["staking"]["operator"] = json!(new_operator.to_hex_literal());
        vesting["staking"]["commission_percentage"] = json!(new_percentage.to_string());
        *expected.wallets.get_mut(&scope.staker).unwrap() += distribution;
    }

    let mut expected_events = Vec::new();
    if distribution > 0 {
        expected_events.push((
            "0x1::stake::WithdrawStake".to_owned(),
            json!({"pool_address": scope.pool.to_hex_literal(), "amount_withdrawn": distribution.to_string()}),
        ));
        expected_events.push((
            "0x1::staking_contract::Distribute".to_owned(),
            json!({"operator": old_operator.to_hex_literal(), "pool_address": scope.pool.to_hex_literal(),
                "recipient": scope.staker.to_hex_literal(), "amount": distribution.to_string()}),
        ));
    }
    if call.changes_operator() {
        expected_events.push((
            "0x1::stake::SetOperator".to_owned(),
            json!({"pool_address": scope.pool.to_hex_literal(), "old_operator": old_operator.to_hex_literal(),
                "new_operator": new_operator.to_hex_literal()}),
        ));
        expected_events.push((
            "0x1::staking_contract::SwitchOperator".to_owned(),
            json!({"pool_address": scope.pool.to_hex_literal(), "old_operator": old_operator.to_hex_literal(),
                "new_operator": new_operator.to_hex_literal()}),
        ));
        if let Some(admin) = scope.vesting_admin {
            expected_events.push((
                "0x1::vesting::UpdateOperator".to_owned(),
                json!({"admin": admin.to_hex_literal(), "vesting_contract_address": scope.staker.to_hex_literal(),
                    "staking_pool_address": scope.pool.to_hex_literal(), "old_operator": old_operator.to_hex_literal(),
                    "new_operator": new_operator.to_hex_literal(), "commission_percentage": new_percentage.to_string()}),
            ));
        }
    } else {
        expected_events.push((
            "0x1::staking_contract::UpdateCommission".to_owned(),
            json!({"staker": scope.staker.to_hex_literal(), "operator": old_operator.to_hex_literal(),
                "old_commission_percentage": old_percentage.to_string(), "new_commission_percentage": new_percentage.to_string()}),
        ));
    }
    assert_eq!(contract_business_events(&tx), expected_events);
    scope.operator = new_operator;
    assert_eq!(
        management_snapshot(f, scope, actor.address(), at).await,
        expected
    );
    assert_eq!(
        installed_at(&f.client, at - 1).await,
        installed_at(&f.client, at).await
    );
    assert!(tx
        .events
        .iter()
        .all(|event| !event.typ.to_string().contains("::poc_")));
    assert_eq!(
        view(
            f,
            "staking_contract::staking_contract_amounts",
            vec![json!(scope.staker), json!(scope.operator)],
            at
        )
        .await,
        vec![json!(principal.to_string()), json!("0"), json!("0")]
    );
    assert_eq!(
        view(
            f,
            "staking_contract::stake_pool_address",
            vec![json!(scope.staker), json!(scope.operator)],
            at
        )
        .await,
        vec![json!(scope.pool.to_hex_literal())]
    );
    wallet_delta(
        f,
        &tx,
        if scope.vesting_admin.is_some() {
            0
        } else {
            distribution as i128
        },
    )
    .await;
    println!("FRZ-02 management succeeded: call={call:?}, staker={}, pool={}, old_operator={old_operator}, new_operator={new_operator}, commission={old_percentage}->{new_percentage}, principal={principal}, distribution={distribution}, actual_commission=0, version={at}", scope.staker, scope.pool);
    at
}

/// 管理操作将已归属本金存入合约钱包；份额持有人须通过这个独立、
/// 无调用身份限制的公开分发入口才会实际收到款项。
async fn distribute_management_grant(
    f: &Fixture,
    scope: &Scope,
    first: AccountAddress,
    second: AccountAddress,
) {
    let tx = success(
        execute(
            &f.client,
            &f.attacker,
            &f.factory,
            aptos_stdlib::vesting_distribute(scope.staker),
        )
        .await,
    );
    let at = tx.info.version.0;
    let mut expected = management_snapshot(f, scope, f.attacker.address(), at - 1).await;
    assert_eq!(*expected.wallets.get(&scope.staker).unwrap(), 100);
    *expected.wallets.get_mut(&scope.staker).unwrap() = 0;
    *expected.wallets.get_mut(&first).unwrap() += 25;
    *expected.wallets.get_mut(&second).unwrap() += 75;
    assert_eq!(
        management_snapshot(f, scope, f.attacker.address(), at).await,
        expected
    );
    assert_eq!(contract_business_events(&tx), vec![(
        "0x1::vesting::Distribute".to_owned(),
        json!({"admin": scope.vesting_admin.unwrap().to_hex_literal(),
            "vesting_contract_address": scope.staker.to_hex_literal(), "amount": "100"}),
    )]);
    assert_eq!(
        installed_at(&f.client, at - 1).await,
        installed_at(&f.client, at).await
    );
    wallet_delta(f, &tx, 0).await;
}

#[derive(Clone, Copy, Debug)]
enum ManagementWrapper {
    StakingContract,
    Vesting,
}

async fn run_management_matrix(wrapper: ManagementWrapper) {
    if matches!(wrapper, ManagementWrapper::Vesting) {
        Lazy::force(&CREATE_VESTING);
    }
    let f = setup().await;
    let operator = funded(&f).await;
    let replacement = funded(&f).await;
    let voter = funded(&f).await;
    let first = funded(&f).await;
    let second = funded(&f).await;
    // 使用不同受益人，验证运营者切换不会改变质押者待分发本金的
    // 收款归属，也不会凭空产生运营者佣金。
    for (actor, beneficiary) in [
        (&operator, first.address()),
        (&replacement, second.address()),
    ] {
        success(
            execute(
                &f.client,
                actor,
                &f.factory,
                aptos_stdlib::staking_contract_set_beneficiary_for_operator(beneficiary),
            )
            .await,
        );
    }
    let calls = [
        ManagementCall::Switch(replacement.address(), 53),
        ManagementCall::SwitchSameCommission(replacement.address()),
        ManagementCall::Commission(53),
    ];
    let (initial_principal, distribution, unauthorized_module, unauthorized_code) = match wrapper {
        ManagementWrapper::StakingContract => (300, 30, "staking_contract", 0x60003),
        ManagementWrapper::Vesting => (400, 100, "vesting", 0x40007),
    };
    let mut owners = Vec::new();
    let mut scopes = Vec::new();
    let mut frozen_payloads = Vec::new();
    for call in calls {
        let owner = funded(&f).await;
        let mut scope = match wrapper {
            ManagementWrapper::StakingContract => {
                let created = success(
                    execute(
                        &f.client,
                        &owner,
                        &f.factory,
                        aptos_stdlib::staking_contract_create_staking_contract(
                            operator.address(),
                            voter.address(),
                            initial_principal,
                            37,
                            b"poc-freeze-operator".to_vec(),
                        ),
                    )
                    .await,
                );
                wallet_delta(&f, &created, -(initial_principal as i128)).await;
                let pool = address(
                    &view(
                        &f,
                        "staking_contract::stake_pool_address",
                        vec![json!(owner.address()), json!(operator.address())],
                        created.info.version.0,
                    )
                    .await[0],
                );
                Scope {
                    staker: owner.address(),
                    operator: operator.address(),
                    pool,
                    wallets: vec![
                        owner.address(),
                        operator.address(),
                        voter.address(),
                        first.address(),
                        second.address(),
                        f.attacker.address(),
                    ],
                    vesting_admin: None,
                }
            },
            ManagementWrapper::Vesting => {
                create_additional_vesting(
                    &f,
                    &owner,
                    first.address(),
                    second.address(),
                    operator.address(),
                    voter.address(),
                )
                .await
            },
        };
        scope.wallets.push(replacement.address());
        scope.wallets.sort();
        scope.wallets.dedup();
        assert_contract(&f, &scope, version(&f).await, initial_principal, 0).await;
        match wrapper {
            ManagementWrapper::StakingContract => {
                staking_success(&f, &scope, &owner, StakingCall::Unlock).await;
            },
            ManagementWrapper::Vesting => {
                vesting_vest(&f, &scope, &f.attacker, 1).await;
            },
        }
        // 每次正常管理调用都先执行正金额分发。
        // 完整预期快照区分存入 vesting 钱包与实际支付给份额持有人。
        management_success(&f, &mut scope, &owner, call, distribution).await;
        management_success(&f, &mut scope, &owner, call.restore(operator.address()), 0).await;
        assert_eq!(scope.operator, operator.address());
        assert_contract(
            &f,
            &scope,
            version(&f).await,
            initial_principal - distribution,
            0,
        )
        .await;
        if matches!(wrapper, ManagementWrapper::Vesting) {
            distribute_management_grant(&f, &scope, first.address(), second.address()).await;
        }
        // 精确恢复旧运营者和佣金比例，再创建第二笔正金额分发。
        // 冻结和恢复阶段复用完全相同的 payload，避免某次成功切换
        // 使其他用例的输入失效。
        match wrapper {
            ManagementWrapper::StakingContract => {
                staking_success(&f, &scope, &owner, StakingCall::Unlock).await;
            },
            ManagementWrapper::Vesting => {
                vesting_vest(&f, &scope, &f.attacker, 2).await;
            },
        }
        wait_expired(&f, scope.pool).await;
        assert_contract(
            &f,
            &scope,
            version(&f).await,
            initial_principal - 2 * distribution,
            distribution,
        )
        .await;
        let payload = call.payload(&scope);
        // 运营者及其受益人均与实际质押者/管理员使用不同身份。
        // 无关签名者也由相同的公开包装入口检查拒绝，
        // 拒绝发生在底层冻结检查之前。
        for unauthorized in [&operator, &first, &f.attacker] {
            management_rejected(
                &f,
                &scope,
                unauthorized,
                payload.clone(),
                unauthorized_module,
                unauthorized_code,
            )
            .await;
        }
        frozen_payloads.push(payload);
        owners.push(owner);
        scopes.push(scope);
    }
    let frozen = freeze(&f).await;
    for (index, scope) in scopes.iter().enumerate() {
        // switch_operator 先移除旧键，随后 distribute_internal 才调用
        // withdraw_with_cap。失败的 VM 输出须恢复该键及全部能力/份额。
        // update_commision 在相同提取检查处被拒绝时，尚未写入新比例。
        management_rejected(
            &f,
            scope,
            &owners[index],
            frozen_payloads[index].clone(),
            "stake",
            0x30014,
        )
        .await;
        for unauthorized in [&operator, &first, &f.attacker] {
            management_rejected(
                &f,
                scope,
                unauthorized,
                frozen_payloads[index].clone(),
                unauthorized_module,
                unauthorized_code,
            )
            .await;
        }
        assert_frozen(&f, &frozen, version(&f).await).await;
    }
    let closing_version = version(&f).await;
    let mut auxiliary_before = Vec::new();
    for scope in &scopes {
        auxiliary_before
            .push(management_snapshot(&f, scope, f.root.address(), closing_version).await);
    }
    finish(&f, &frozen).await;
    let completed_version = version(&f).await;
    for (scope, before) in scopes.iter().zip(auxiliary_before) {
        // 委员会外的辅助池在本次提交中不获得原生或 PoC 奖励。
        // 冻结解除后，其已到期的待提取质押仍可由完全相同的包装操作处理。
        assert_eq!(
            management_snapshot(&f, scope, f.root.address(), completed_version).await,
            before
        );
    }
    for (index, scope) in scopes.iter_mut().enumerate() {
        let call = calls[index];
        assert_eq!(call.payload(scope), frozen_payloads[index]);
        for unauthorized in [&operator, &first, &f.attacker] {
            management_rejected(
                &f,
                scope,
                unauthorized,
                frozen_payloads[index].clone(),
                unauthorized_module,
                unauthorized_code,
            )
            .await;
        }
        let at = management_success(&f, scope, &owners[index], call, distribution).await;
        assert_eq!(
            integer(&contract(&f, scope, at).await["principal"]),
            initial_principal - 2 * distribution
        );
        assert_eq!(
            balances(&resource(&f, scope.pool, "stake::StakePool", at).await),
            [initial_principal - 2 * distribution, 0, 0, 0]
        );
        if matches!(wrapper, ManagementWrapper::Vesting) {
            assert_eq!(balance(&f, scope.staker, at).await, 100);
            distribute_management_grant(&f, scope, first.address(), second.address()).await;
        }
    }
    println!("FRZ-02 {wrapper:?} operator/commission matrix complete: three independent contracts, initial_principal={initial_principal}, each pays two {distribution}-Octa principal distributions, final_principal={}, native_rewards=0, actual_commission=0; every frozen payload replayed unchanged", initial_principal - 2 * distribution);
}

#[tokio::test]
async fn poc_frozen_staking_contract_operator_and_commission_updates_restore_distributions() {
    run_management_matrix(ManagementWrapper::StakingContract).await;
}

#[tokio::test]
async fn poc_frozen_vesting_operator_and_commission_updates_restore_distributions() {
    run_management_matrix(ManagementWrapper::Vesting).await;
}

static REWARD_BATCH_GOVERNANCE: Lazy<Vec<u8>> = Lazy::new(|| {
    compile_script(
        "PoCVestingRewardBatch",
        r#"script {
        use topo_std::fixed_point64;
        use topo_framework::epoch_timeout_config;
        use topo_framework::poc_accounting;
        use topo_framework::poc_allocation;
        use topo_framework::stake;
        use topo_framework::staking_config;
        use topo_framework::topo_governance;
        fun main(root: &signer, operation: u8, pool: address, epoch: u64,
                 next_positive: bool, lockup: u64, require_income: bool) {
            let framework = topo_governance::get_signer_testnet_only(root, @0x1);
            assert!(poc_accounting::current_epoch() == epoch, 0x70000);
            if (operation == 1) {
                poc_allocation::enable_pool(&framework, pool);
                return
            };
            assert!(operation == 0 || operation == 2 || operation == 3, 0);
            if (require_income) {
                let (successes, failures) = stake::get_current_epoch_proposal_counts(
                    stake::get_validator_index(pool));
                // 在成功提交的同一事务中保证正佣金，避免表现查询与结奖之间的竞态。
                assert!(successes > 0 && successes >= failures, 0x70001);
            };
            if (operation != 3) {
                let zero = fixed_point64::create_from_rational(0, 1);
                let rate = if (next_positive) fixed_point64::create_from_rational(1, 1) else zero;
                staking_config::update_rewards_config(&framework, rate, rate, 31536000, zero);
                stake::set_transaction_fee_limit_per_epoch_per_pool(&framework, 0);
                if (lockup > 0) {
                    staking_config::update_recurring_lockup_duration_secs(&framework, lockup);
                };
            };
            if (operation == 0) {
                poc_allocation::schedule_power_params(&framework,
                    poc_accounting::new_power_params(1000000000, 10, 100, 4), epoch + 1);
                stake::schedule_reward_split(&framework, 3000, epoch + 1);
                epoch_timeout_config::set_for_next_epoch(&framework,
                    epoch_timeout_config::new_disabled());
            };
            topo_governance::force_end_epoch(&framework);
        }
    }"#,
    )
});

fn reward_batch_governance(
    operation: u8,
    pool: AccountAddress,
    epoch: u64,
    next_positive: bool,
    lockup: u64,
    require_income: bool,
) -> TransactionPayload {
    TransactionPayload::Script(Script::new(REWARD_BATCH_GOVERNANCE.clone(), vec![], vec![
        TransactionArgument::U8(operation),
        TransactionArgument::Address(pool),
        TransactionArgument::U64(epoch),
        TransactionArgument::Bool(next_positive),
        TransactionArgument::U64(lockup),
        TransactionArgument::Bool(require_income),
    ]))
}

#[derive(Clone, Copy, Debug)]
struct BatchIncome {
    native: u64,
    commission: u64,
    net: u64,
}

impl BatchIncome {
    fn new(native: u64) -> Self {
        let commission = u64::try_from(u128::from(native) * 37 / 100).unwrap();
        Self {
            native,
            commission,
            net: native - commission,
        }
    }
}

fn batch_rate(state: &super::defaults::InstalledSnapshot, positive: bool) {
    assert_eq!(state.reward_context.0, state.epoch);
    assert!(state.reward_context.1);
    assert!(state.reward_context.3 > 0);
    if positive {
        assert_eq!(state.reward_context.2, state.reward_context.3);
    } else {
        assert_eq!(state.reward_context.2, 0);
    }
    assert_eq!(state.reward_context.5, 0);
    assert_eq!(
        integer(&state.reward_split["installed_native_reward_bps"]),
        3000
    );
}

async fn wait_batch_proposals(f: &Fixture, pool: AccountAddress, epoch: u64) {
    tokio::time::timeout(Duration::from_secs(90), async {
        loop {
            let at = version(f).await;
            let installed = installed_at(&f.client, at).await;
            assert_eq!(installed.epoch, epoch);
            let member = installed.validators.active_validators.iter()
                .find(|member| member.account_address == pool).unwrap();
            let counts = view(f, "stake::get_current_epoch_proposal_counts",
                vec![json!(member.config().validator_index.to_string())], at).await;
            let successful = integer(&counts[0]);
            let failed = integer(&counts[1]);
            if successful >= 3 && u128::from(successful) >= u128::from(failed) + 3 {
                println!("FRZ-02 vesting validator produced actual proposals: pool={pool}, epoch={epoch}, version={at}, successful={successful}, failed={failed}");
                return;
            }
            success(execute(&f.client, &f.attacker, &f.factory,
                aptos_stdlib::topo_coin_transfer(f.root.address(), 1)).await);
        }
    }).await.expect("The vesting validator did not produce real proposals within 90 seconds");
}

/// 结奖模型只使用成功换届事务 v-1 的已安装上下文和实际提案统计。
/// 固定 10 power、10 Octa/power 的计奖基数为 100；奖励、分流、Q 指数
/// 和 37% 佣金均独立逐步取整，不从预览或领取函数反推预期。
async fn assert_batch_settlement(
    f: &Fixture,
    tx: &UserTransaction,
    vesting_pool: AccountAddress,
    closing_positive: bool,
    next_positive: bool,
) -> BatchIncome {
    let at = tx.info.version.0;
    let before = installed_at(&f.client, at - 1).await;
    let after = installed_at(&f.client, at).await;
    assert_eq!(after.epoch, before.epoch + 1);
    assert_eq!(after.validators, before.validators);
    batch_rate(&before, closing_positive);
    batch_rate(&after, next_positive);
    assert_eq!(events(tx, "::stake::PoCEpochInstalled").len(), 1);
    assert_eq!(events(tx, "::stake::PoCRewardCredited").len(), 4);
    assert_eq!(events(tx, "::stake::PoCRewardSplit").len(), 4);
    assert!(events(tx, "::stake::DistributeTransactionFee").is_empty());
    let mut vesting_income = None;
    for member in &before.validators.active_validators {
        assert_eq!(member.consensus_voting_power(), 10);
        let pool = member.account_address;
        let counts = view(
            f,
            "stake::get_current_epoch_proposal_counts",
            vec![json!(member.config().validator_index.to_string())],
            at - 1,
        )
        .await;
        let successful = u128::from(integer(&counts[0]));
        let failed = u128::from(integer(&counts[1]));
        let total = if successful + failed == 0 {
            0
        } else {
            u64::try_from(
                100 * successful * u128::from(before.reward_context.2)
                    / ((successful + failed) * u128::from(before.reward_context.3)),
            )
            .unwrap()
        };
        let native = u64::try_from(u128::from(total) * 3000 / 10000).unwrap();
        let poc = total - native;
        let old_pool = pool_at(&f.client, pool, at - 1).await;
        let new_pool = pool_at(&f.client, pool, at).await;
        let units = 10u128 << 32;
        assert_eq!(integer(&old_pool[0]) as u128, units);
        assert_eq!(integer(&new_pool[0]) as u128, units);
        assert_eq!(integer(&old_pool[2]), 100);
        assert_eq!(integer(&new_pool[2]), 100);
        let delta_index = U256::checked_div(
            U256::checked_mul(U256::from(poc), U256::ONE << U256::from(128u8)).unwrap(),
            U256::from(units),
        )
        .unwrap();
        assert_eq!(integer(&new_pool[3]), integer(&old_pool[3]) + poc);
        assert_eq!(
            wide(&new_pool[4]),
            U256::checked_add(wide(&old_pool[4]), delta_index).unwrap()
        );
        let credit = pool_event(tx, "::stake::PoCRewardCredited", pool);
        for (field, expected) in [
            ("closing_epoch", before.epoch),
            ("reward_base_octa", 100),
            ("inflation", poc),
            ("fee", 0),
        ] {
            assert_eq!(integer(&credit.data[field]), expected, "{pool} {field}");
        }
        assert_eq!(wide(&credit.data["delta_index"]), delta_index);
        let old_stake = balances(&resource(f, pool, "stake::StakePool", at - 1).await);
        let new_stake = balances(&resource(f, pool, "stake::StakePool", at).await);
        let sum = |values: [u64; 4]| values.into_iter().map(u128::from).sum::<u128>();
        assert_eq!(sum(new_stake), sum(old_stake) + u128::from(native));
        let pending_native = if native == 0 {
            0
        } else {
            u64::try_from(
                u128::from(native) * u128::from(old_stake[3])
                    / (u128::from(old_stake[0]) + u128::from(old_stake[3])),
            )
            .unwrap()
        };
        let split = pool_event(tx, "::stake::PoCRewardSplit", pool);
        for (field, expected) in [
            ("closing_epoch", before.epoch),
            ("native_reward_bps", 3000),
            ("total_inflation_octa", total),
            ("active_native_reward_octa", native - pending_native),
            ("pending_inactive_native_reward_octa", pending_native),
            ("poc_inflation_octa", poc),
        ] {
            assert_eq!(integer(&split.data[field]), expected, "{pool} {field}");
        }
        let native_events = events(tx, "::stake::DistributeRewards")
            .into_iter()
            .filter(|event| address(&event.data["pool_address"]) == pool)
            .collect::<Vec<_>>();
        assert_eq!(native_events.len(), usize::from(native > 0));
        if native > 0 {
            assert_eq!(integer(&native_events[0].data["rewards_amount"]), native);
        }
        if pool == vesting_pool {
            let income = BatchIncome::new(native);
            if closing_positive {
                assert!(successful > 0 && income.commission > 0 && income.net > 0);
                assert_eq!(old_stake[0], 400);
                assert_eq!(old_stake[2], 0);
                assert_eq!(old_stake[3], 0);
            }
            println!("FRZ-02 vesting reward model: closing_epoch={}, version={at}, successful={successful}, failed={failed}, installed_rate={}/{}, inflation={total}, native={native}, commission={}, net={}, poc={poc}", before.epoch, before.reward_context.2, before.reward_context.3, income.commission, income.net);
            vesting_income = Some(income);
        }
    }
    vesting_income.unwrap()
}

async fn commit_batch_epoch(
    f: &Fixture,
    pool: AccountAddress,
    closing_positive: bool,
    next_positive: bool,
    lockup: u64,
) -> (UserTransaction, BatchIncome) {
    let epoch = installed_at(&f.client, version(f).await).await.epoch;
    if closing_positive {
        wait_batch_proposals(f, pool, epoch).await;
    }
    let tx = tokio::time::timeout(Duration::from_secs(90), async {
        loop {
            let tx = execute(
                &f.client,
                &f.root,
                &f.factory,
                reward_batch_governance(2, pool, epoch, next_positive, lockup, closing_positive),
            )
            .await;
            if tx.info.success {
                return tx;
            }
            assert_reward_batch_guard_abort(f, &tx).await;
        }
    })
    .await
    .expect("正收益换届未能在 90 秒内满足事务内提案守卫");
    let income = assert_batch_settlement(f, &tx, pool, closing_positive, next_positive).await;
    (tx, income)
}

/// 公开注册已验证原节点共识密钥的持有证明。仅在旧池退出后重绑隔离
/// 测试节点，并为新 author 建立独立安全存储；旧 author 的存储字节不变。
async fn rebind_vesting_validator(
    f: &mut Fixture,
    node_key: AccountAddress,
    pool: AccountAddress,
    install_version: u64,
) {
    let installed = installed_at(&f.client, install_version).await;
    assert!(installed
        .validators
        .active_validators
        .iter()
        .all(|v| v.account_address != node_key));
    let target = installed
        .validators
        .active_validators
        .iter()
        .find(|v| v.account_address == pool)
        .unwrap();
    let node = f.swarm.validator_mut(node_key).unwrap();
    let rules = &node.config().consensus.safety_rules;
    let SecureBackend::OnDiskStorage(old_backend) = &rules.backend else {
        panic!("Expected the native Forge on-disk safety backend")
    };
    assert!(rules.test.is_none());
    let old_safety_path = old_backend.path();
    assert!(old_safety_path.starts_with(node.base_dir()));
    let new_safety_path = node.base_dir().join("vesting_pool_safety_storage.json");
    assert_ne!(old_safety_path, new_safety_path);
    assert!(!new_safety_path.exists());
    let mut new_backend = old_backend.clone();
    new_backend.path = new_safety_path.clone();
    let InitialSafetyRulesConfig::FromFile {
        identity_blob_path,
        overriding_identity_paths,
        ..
    } = &rules.initial_safety_rules_config
    else {
        panic!("Expected the native Forge identity file")
    };
    assert!(overriding_identity_paths.is_empty());
    let Identity::FromFile(network_identity) =
        &node.config().validator_network.as_ref().unwrap().identity
    else {
        panic!("Expected the native Forge network identity file")
    };
    assert_eq!(network_identity.path, *identity_blob_path);
    assert!(identity_blob_path.starts_with(node.base_dir()));
    let identity_blob_path = identity_blob_path.clone();
    let mut identity = IdentityBlob::from_file(&identity_blob_path).unwrap();
    assert_eq!(identity.account_address, Some(node_key));
    assert_eq!(
        bls12381::PublicKey::from(identity.consensus_private_key.as_ref().unwrap()),
        target.config().consensus_public_key
    );
    let network_key = identity.network_private_key.public_key();
    node.stop();
    let old_safety_bytes = fs::read(&old_safety_path).unwrap();
    identity.account_address = Some(pool);
    fs::write(
        &identity_blob_path,
        serde_yaml::to_string(&identity).unwrap(),
    )
    .unwrap();
    let config_path = node.config_path();
    let mut config = OverrideNodeConfig::load_config(&config_path).unwrap();
    config.override_config_mut().consensus.safety_rules.backend =
        SecureBackend::OnDiskStorage(new_backend.clone());
    config.save_config(&config_path).unwrap();
    node.config_mut().consensus.safety_rules.backend =
        SecureBackend::OnDiskStorage(new_backend.clone());
    let saved = OverrideNodeConfig::load_config(&config_path).unwrap();
    let SecureBackend::OnDiskStorage(saved_backend) =
        &saved.override_config().consensus.safety_rules.backend
    else {
        panic!("Expected the persisted on-disk safety backend")
    };
    assert_eq!(saved_backend.path(), new_safety_path);
    assert_eq!(saved_backend.namespace, new_backend.namespace);
    assert_eq!(
        node.config().validator_network.as_ref().unwrap().peer_id(),
        pool
    );
    assert_eq!(
        node.config()
            .validator_network
            .as_ref()
            .unwrap()
            .identity_key()
            .public_key(),
        network_key
    );
    assert_eq!(
        node.config()
            .consensus
            .safety_rules
            .initial_safety_rules_config
            .identity_blob()
            .unwrap()
            .account_address,
        Some(pool)
    );
    node.start().unwrap();
    node.wait_until_healthy(Instant::now() + Duration::from_secs(30))
        .await
        .unwrap();
    assert!(fs::read(&old_safety_path).unwrap() == old_safety_bytes);
    wait_batch_proposals(f, pool, installed.epoch).await;
    assert!(new_safety_path.is_file());
    assert!(fs::read(&old_safety_path).unwrap() == old_safety_bytes);
    println!("FRZ-02 vesting validator installed: retired_pool={node_key}, active_pool={pool}, version={install_version}; native keys retained, old safety storage unchanged");
}

fn batch_shares(contract: &Value) -> BTreeMap<AccountAddress, u64> {
    contract["distribution_pool"]["shares"]["data"]
        .as_array()
        .unwrap()
        .iter()
        .map(|entry| (address(&entry["key"]), integer(&entry["value"])))
        .collect()
}

async fn assert_batch_distribution(f: &Fixture, scope: &Scope, at: u64, income: BatchIncome) {
    let stored = contract(f, scope, at).await;
    assert_eq!(integer(&stored["principal"]), 400);
    assert_eq!(integer(&stored["commission_percentage"]), 37);
    assert_eq!(integer(&stored["distribution_pool"]["scaling_factor"]), 1);
    assert_eq!(
        integer(&stored["distribution_pool"]["total_coins"]),
        income.native
    );
    assert_eq!(
        integer(&stored["distribution_pool"]["total_shares"]),
        income.native
    );
    assert_eq!(
        batch_shares(&stored),
        BTreeMap::from([
            (scope.operator, income.commission),
            (scope.staker, income.net),
        ])
    );
    assert_eq!(
        integer(
            &resource(f, scope.staker, "vesting::VestingContract", at).await["remaining_grant"]
        ),
        400
    );
}

async fn batch_protocol(f: &Fixture, at: u64) -> BTreeMap<String, Value> {
    let mut state = BTreeMap::new();
    for name in [
        "poc_power_store::PowerStore",
        "poc_power_store::PeriodClock",
        "poc_accounting::AccountingState",
        "poc_reward_split::RewardSplitConfig",
        "staking_config::StakingConfig",
        "staking_config::StakingRewardsConfig",
        "stake::InstalledRewardContext",
        "stake::ValidatorSet",
        "stake::ValidatorPerformance",
        "stake::TransactionFeeConfig",
        "stake::PendingTransactionFee",
        "epoch_timeout_config::EpochTimeoutConfig",
        "config_buffer::PendingConfigs",
        "reconfiguration::Configuration",
        "stake::EpochPlan",
        "stake::PrecomputedValidatorSet",
        "dkg::DKGState",
    ] {
        let value =
            optional_resource_at_version(&f.client, CORE_CODE_ADDRESS, &format!("0x1::{name}"), at)
                .await
                .map(|resource| resource.data);
        state.insert(name.to_owned(), json!(value));
    }
    for pool in &f.pools {
        state.insert(
            format!("ledger/{pool}"),
            ledger_at(&f.client, *pool, at).await,
        );
    }
    state
}

/// 链下读到的提案统计可能在提交前继续变化。这里只接受脚本内同一事务守卫的
/// 精确拒绝，并核对全部结奖、配置、计划和池表项均未发生业务写入后再重试。
async fn assert_reward_batch_guard_abort(f: &Fixture, tx: &UserTransaction) {
    assert!(!tx.info.success);
    let at = tx.info.version.0;
    let TransactionData::OnChain(committed) = f
        .client
        .get_transaction_by_version_bcs(at)
        .await
        .unwrap()
        .into_inner()
    else {
        panic!("预期链上用户交易")
    };
    let ExecutionStatus::MoveAbort { location, code, .. } = committed.info.status() else {
        panic!(
            "预期提案守卫 Move abort，实际为 {:?}",
            committed.info.status()
        )
    };
    assert_eq!(location, &AbortLocation::Script);
    assert_eq!(*code, 0x70001);

    let before = batch_protocol(f, at - 1).await;
    assert_eq!(before, batch_protocol(f, at).await);
    let mut protected_handles = BTreeSet::new();
    for value in before.values() {
        handles(value, &mut protected_handles);
    }
    let protected = |name: &str| {
        name.contains("::poc_")
            || name.contains("::stake::")
            || name.contains("::staking_config::")
            || name.contains("::epoch_timeout_config::")
            || name.contains("::config_buffer::")
            || name.contains("::reconfiguration::")
            || name.contains("::dkg::")
    };
    for change in &tx.info.changes {
        match change {
            WriteSetChange::WriteResource(change) => {
                assert!(!protected(&change.data.typ.to_string()))
            },
            WriteSetChange::DeleteResource(change) => {
                assert!(!protected(&change.resource.to_string()))
            },
            WriteSetChange::WriteTableItem(change) => assert!(!protected_handles
                .contains(&AccountAddress::from_bytes(change.handle.inner()).unwrap())),
            WriteSetChange::DeleteTableItem(change) => assert!(!protected_handles
                .contains(&AccountAddress::from_bytes(change.handle.inner()).unwrap())),
            WriteSetChange::WriteModule(_) | WriteSetChange::DeleteModule(_) => {
                panic!("提案守卫拒绝时不应修改模块：{change:?}")
            },
        }
    }
    assert!(tx
        .events
        .iter()
        .all(|event| !protected(&event.typ.to_string())));
    wallet_delta(f, tx, 0).await;
    println!("FRZ-02 正收益换届提案守卫拒绝：version={at}，Script/0x70001，业务状态保持不变并在同一 Epoch 重试");
}

/// A 的旧收益先从 inactive 支付，随后本期净收益与佣金分别建立新份额。
/// 旧份额在零收益 Epoch 成熟，故无二次佣金或份额价格变化。
async fn assert_batch_unlock(
    f: &Fixture,
    tx: &UserTransaction,
    scope: &Scope,
    zero: &Scope,
    beneficiary: AccountAddress,
    old: BatchIncome,
    new: BatchIncome,
) {
    let at = tx.info.version.0;
    let before_contract = contract(f, scope, at - 1).await;
    assert_eq!(integer(&before_contract["principal"]), 400);
    assert_eq!(
        integer(&before_contract["distribution_pool"]["total_coins"]),
        old.native
    );
    assert_eq!(
        integer(&before_contract["distribution_pool"]["total_shares"]),
        old.native
    );
    let old_shares = if old.native == 0 {
        BTreeMap::new()
    } else {
        BTreeMap::from([(scope.operator, old.commission), (scope.staker, old.net)])
    };
    assert_eq!(batch_shares(&before_contract), old_shares);
    assert_eq!(
        balances(&resource(f, scope.pool, "stake::StakePool", at - 1).await),
        [400 + new.native, old.native, 0, 0]
    );
    assert_eq!(
        balances(&resource(f, scope.pool, "stake::StakePool", at).await),
        [400, 0, 0, new.native]
    );
    assert_batch_distribution(f, scope, at, new).await;
    assert_eq!(
        balance(f, beneficiary, at).await - balance(f, beneficiary, at - 1).await,
        old.commission
    );
    assert_eq!(
        balance(f, scope.staker, at).await - balance(f, scope.staker, at - 1).await,
        old.net
    );
    assert_eq!(
        balance(f, scope.operator, at).await,
        balance(f, scope.operator, at - 1).await
    );
    assert_eq!(
        snapshot(f, zero, *tx.request.sender.inner(), at - 1).await,
        snapshot(f, zero, *tx.request.sender.inner(), at).await
    );
    assert_eq!(batch_protocol(f, at - 1).await, batch_protocol(f, at).await);
    for name in [
        "vesting::VestingContract",
        "vesting::VestingAccountManagement",
    ] {
        assert_eq!(
            optional_resource_at_version(&f.client, scope.staker, &format!("0x1::{name}"), at - 1)
                .await
                .map(|resource| resource.data),
            optional_resource_at_version(&f.client, scope.staker, &format!("0x1::{name}"), at)
                .await
                .map(|resource| resource.data)
        );
    }
    let old_stake = resource(f, scope.pool, "stake::StakePool", at - 1).await;
    let new_stake = resource(f, scope.pool, "stake::StakePool", at).await;
    assert_eq!(
        old_stake["locked_until_secs"],
        new_stake["locked_until_secs"]
    );
    let requests = events(tx, "::staking_contract::RequestCommission");
    assert_eq!(requests.len(), 1);
    assert_eq!(address(&requests[0].data["pool_address"]), scope.pool);
    assert_eq!(
        integer(&requests[0].data["accumulated_rewards"]),
        new.native
    );
    assert_eq!(
        integer(&requests[0].data["commission_amount"]),
        new.commission
    );
    let additions = events(tx, "::staking_contract::AddDistribution");
    assert_eq!(additions.len(), 2);
    assert_eq!(
        additions
            .iter()
            .map(|event| integer(&event.data["amount"]))
            .collect::<Vec<_>>(),
        vec![new.commission, new.net]
    );
    for event in additions {
        assert_eq!(address(&event.data["pool_address"]), scope.pool);
        assert_eq!(address(&event.data["operator"]), scope.operator);
    }
    let unlocks = events(tx, "::stake::UnlockStake");
    assert_eq!(unlocks.len(), 2);
    assert_eq!(
        unlocks
            .iter()
            .map(|event| integer(&event.data["amount_unlocked"]))
            .collect::<Vec<_>>(),
        vec![new.commission, new.net]
    );
    let wrapper_unlocks = events(tx, "::staking_contract::UnlockStake");
    assert_eq!(wrapper_unlocks.len(), 1);
    assert_eq!(integer(&wrapper_unlocks[0].data["amount"]), new.net);
    assert_eq!(
        integer(&wrapper_unlocks[0].data["commission_paid"]),
        new.commission
    );
    let withdrawn = events(tx, "::stake::WithdrawStake");
    assert_eq!(withdrawn.len(), usize::from(old.native > 0));
    let paid = events(tx, "::staking_contract::Distribute");
    assert_eq!(paid.len(), if old.native == 0 { 0 } else { 2 });
    if old.native > 0 {
        assert_eq!(integer(&withdrawn[0].data["amount_withdrawn"]), old.native);
        assert_eq!(address(&withdrawn[0].data["pool_address"]), scope.pool);
        assert_eq!(
            paid.iter()
                .map(|event| (
                    address(&event.data["recipient"]),
                    integer(&event.data["amount"])
                ))
                .collect::<BTreeMap<_, _>>(),
            BTreeMap::from([(beneficiary, old.commission), (scope.staker, old.net)])
        );
    }
    // 此公开入口不发出 vesting::UnlockRewards；实际支付和解锁由下层模块事件证明。
    assert!(tx
        .events
        .iter()
        .all(|event| !event.typ.to_string().contains("::vesting::")));
    wallet_delta(f, tx, 0).await;
}

async fn reject_reward_batch(
    f: &Fixture,
    scopes: &[&Scope],
    payload: TransactionPayload,
    module: &str,
    code: u64,
) -> UserTransaction {
    let tx = reject(f, scopes[0], &f.attacker, payload, module, code).await;
    let at = tx.info.version.0;
    for scope in &scopes[1..] {
        assert_eq!(
            snapshot(f, scope, f.attacker.address(), at - 1).await,
            snapshot(f, scope, f.attacker.address(), at).await
        );
    }
    assert_eq!(batch_protocol(f, at - 1).await, batch_protocol(f, at).await);
    tx
}

#[tokio::test]
async fn poc_frozen_vesting_positive_reward_batch_rolls_back_and_recovers() {
    Lazy::force(&REWARD_BATCH_GOVERNANCE);
    Lazy::force(&CREATE_VESTING);
    let started = Instant::now();
    let mut f = fixture().await;
    let admin = funded(&f).await;
    let first = funded(&f).await;
    let second = funded(&f).await;
    // 运营者要连续提交受益人、公钥、网络地址和成员交易；额外余额保证每笔交易
    // 都能覆盖最大 gas 预留，实际余额变化仍由各业务断言逐笔核对。
    let operator = funded_with_balance(&f, 10_000_000_000).await;
    let voter = funded(&f).await;
    let beneficiary = funded(&f).await;
    let node_key = f.pools[1];
    assert_ne!(node_key, f.swarm.validators().next().unwrap().peer_id());
    // 在原节点离任前完成全部注资；普通转账也为 root 的存储退款保留余额空间。
    success(
        execute(
            &f.client,
            &f.root,
            &f.factory,
            aptos_stdlib::topo_coin_transfer(node_key, 1_000_000_000),
        )
        .await,
    );
    let epoch = installed_at(&f.client, version(&f).await).await.epoch;
    let configured = success(
        execute(
            &f.client,
            &f.root,
            &f.factory,
            reward_batch_governance(0, node_key, epoch, false, 30, false),
        )
        .await,
    );
    let configured_state = installed_at(&f.client, configured.info.version.0).await;
    assert_eq!(configured_state.epoch, epoch + 1);
    batch_rate(&configured_state, false);
    let mut positive = create_additional_vesting(
        &f,
        &admin,
        first.address(),
        second.address(),
        operator.address(),
        voter.address(),
    )
    .await;
    let zero = create_additional_vesting(
        &f,
        &admin,
        first.address(),
        second.address(),
        operator.address(),
        voter.address(),
    )
    .await;
    let terminated = create_additional_vesting(
        &f,
        &admin,
        first.address(),
        second.address(),
        operator.address(),
        voter.address(),
    )
    .await;
    positive.wallets.extend([beneficiary.address(), node_key]);
    let terminated_tx = success(
        execute(
            &f.client,
            &admin,
            &f.factory,
            aptos_stdlib::vesting_terminate_vesting_contract(terminated.staker),
        )
        .await,
    );
    assert_eq!(events(&terminated_tx, "::vesting::Terminate").len(), 1);
    assert_eq!(
        integer(
            &resource(
                &f,
                terminated.staker,
                "vesting::VestingContract",
                terminated_tx.info.version.0
            )
            .await["remaining_grant"]
        ),
        0
    );
    success(
        execute(
            &f.client,
            &operator,
            &f.factory,
            aptos_stdlib::staking_contract_set_beneficiary_for_operator(beneficiary.address()),
        )
        .await,
    );
    let at = version(&f).await;
    let old_config: ValidatorConfig = f
        .client
        .get_account_resource_at_version_bcs(node_key, "0x1::stake::ValidatorConfig", at)
        .await
        .unwrap()
        .into_inner();
    let node = f.swarm.validator(node_key).unwrap();
    let owner = LocalAccount::new(
        node_key,
        node.account_private_key().as_ref().unwrap().private_key(),
        f.client
            .get_account(node_key)
            .await
            .unwrap()
            .into_inner()
            .sequence_number,
    );
    let proof = {
        let identity = node
            .config()
            .consensus
            .safety_rules
            .initial_safety_rules_config
            .identity_blob()
            .unwrap();
        let key = identity.consensus_private_key.unwrap();
        assert_eq!(
            bls12381::PublicKey::from(&key),
            old_config.consensus_public_key
        );
        bls12381::ProofOfPossession::create(&key)
            .to_bytes()
            .to_vec()
    };
    success(
        execute(
            &f.client,
            &operator,
            &f.factory,
            aptos_stdlib::stake_rotate_consensus_key(
                positive.pool,
                old_config.consensus_public_key.to_bytes().to_vec(),
                proof,
            ),
        )
        .await,
    );
    success(
        execute(
            &f.client,
            &operator,
            &f.factory,
            aptos_stdlib::stake_update_network_and_fullnode_addresses(
                positive.pool,
                old_config.validator_network_addresses,
                old_config.fullnode_network_addresses,
            ),
        )
        .await,
    );
    let epoch = installed_at(&f.client, version(&f).await).await.epoch;
    success(
        execute(
            &f.client,
            &f.root,
            &f.factory,
            reward_batch_governance(1, positive.pool, epoch, false, 0, false),
        )
        .await,
    );
    success(
        execute(
            &f.client,
            &owner,
            &f.factory,
            aptos_stdlib::poc_allocation_set_allocations(vec![positive.pool], vec![10000]),
        )
        .await,
    );
    success(
        execute(
            &f.client,
            &operator,
            &f.factory,
            aptos_stdlib::stake_join_validator_set(positive.pool),
        )
        .await,
    );
    let joined = success(
        execute(
            &f.client,
            &f.root,
            &f.factory,
            reward_batch_governance(2, positive.pool, epoch, false, 0, false),
        )
        .await,
    );
    let joined_at = joined.info.version.0;
    let before_join = installed_at(&f.client, joined_at - 1).await;
    let installed = installed_at(&f.client, joined_at).await;
    assert_eq!(installed.epoch, epoch + 1);
    assert_eq!(before_join.validators.pending_active.len(), 1);
    assert_eq!(
        before_join.validators.pending_active[0].account_address,
        positive.pool
    );
    assert_eq!(
        before_join.validators.pending_active[0].consensus_voting_power(),
        0
    );
    assert_eq!(before_join.validators.total_joining_power, 0);
    assert_eq!(installed.validators.active_validators.len(), 4);
    assert_eq!(installed.validators.total_voting_power, 40);
    assert!(installed.validators.pending_active.is_empty());
    assert!(installed.validators.pending_inactive.is_empty());
    for member in &installed.validators.active_validators {
        assert_eq!(member.consensus_voting_power(), 10);
    }
    let expected_members = f
        .pools
        .iter()
        .copied()
        .filter(|pool| *pool != node_key)
        .chain([positive.pool])
        .collect::<BTreeSet<_>>();
    assert_eq!(
        installed
            .validators
            .active_validators
            .iter()
            .map(|member| member.account_address)
            .collect::<BTreeSet<_>>(),
        expected_members
    );
    assert_contract(&f, &positive, joined_at, 400, 0).await;
    f.pools = installed
        .validators
        .active_validators
        .iter()
        .map(|member| member.account_address)
        .collect();
    rebind_vesting_validator(&mut f, node_key, positive.pool, joined_at).await;
    super::freeze::assert_installed(
        &f,
        version(&f).await,
        installed.epoch,
        &installed.validators,
        3000,
        None,
    )
    .await;
    println!("FRZ-02 positive vesting fixture: native_bps=3000, commission=37%, principal=400, reward_base=100, fee_limit=0, short_lockup=30s, epoch=3600s, ordinary DKG=on, Chunky=off; current_members={:?}, setup_elapsed={:?}", f.pools, started.elapsed());

    commit_batch_epoch(&f, positive.pool, false, true, 0).await;
    let (_, first_income) = commit_batch_epoch(&f, positive.pool, true, false, 0).await;
    let payload = aptos_stdlib::vesting_unlock_rewards_many(vec![zero.staker, positive.staker]);
    // unlock_rewards_many 没有 signer 参数或调用者权限限制；无关账户可合法代付 gas。
    let first_unlock = success(execute(&f.client, &f.attacker, &f.factory, payload.clone()).await);
    assert_batch_unlock(
        &f,
        &first_unlock,
        &positive,
        &zero,
        beneficiary.address(),
        BatchIncome::new(0),
        first_income,
    )
    .await;
    let lock = integer(
        &resource(
            &f,
            positive.pool,
            "stake::StakePool",
            first_unlock.info.version.0,
        )
        .await["locked_until_secs"],
    );
    let maturity_started = Instant::now();
    tokio::time::timeout(Duration::from_secs(40), async {
        while now(&f).await < lock {
            tokio::time::sleep(Duration::from_millis(200)).await;
        }
    })
    .await
    .expect("The first native reward did not reach its real 30-second lockup expiry");
    let (matured, zero_income) = commit_batch_epoch(&f, positive.pool, false, true, 3600).await;
    assert_eq!(zero_income.native, 0);
    assert_eq!(
        balances(
            &resource(
                &f,
                positive.pool,
                "stake::StakePool",
                matured.info.version.0
            )
            .await
        ),
        [400, first_income.native, 0, 0]
    );
    assert_batch_distribution(&f, &positive, matured.info.version.0, first_income).await;
    assert!(
        integer(
            &resource(
                &f,
                positive.pool,
                "stake::StakePool",
                matured.info.version.0
            )
            .await["locked_until_secs"]
        ) > lock
    );
    println!("FRZ-02 first reward matured without additional native income: old_lock={lock}, elapsed={:?}, native={}, commission={}, net={}", maturity_started.elapsed(), first_income.native, first_income.commission, first_income.net);
    let (_, second_income) = commit_batch_epoch(&f, positive.pool, true, false, 0).await;
    let before_rejection = version(&f).await;
    assert_eq!(
        balances(&resource(&f, positive.pool, "stake::StakePool", before_rejection).await),
        [400 + second_income.native, first_income.native, 0, 0]
    );
    assert_batch_distribution(&f, &positive, before_rejection, first_income).await;
    let all = [&positive, &zero, &terminated];
    // 前项先支付已到期的 R1，并为 R2 建立佣金/净收益份额；后项终止状态
    // 检查触发 0x30008，必须连同前项的实际付款和事件整体回滚。
    reject_reward_batch(
        &f,
        &all,
        aptos_stdlib::vesting_unlock_rewards_many(vec![positive.staker, terminated.staker]),
        "vesting",
        0x30008,
    )
    .await;
    let before_freeze = version(&f).await;
    batch_rate(&installed_at(&f.client, before_freeze).await, false);
    let frozen = freeze(&f).await;
    let frozen_at = version(&f).await;
    let frozen_state = installed_at(&f.client, frozen_at).await;
    let dkg = resource_at_version::<DKGState>(&f.client, frozen_at).await;
    let session = dkg.in_progress.as_ref().unwrap();
    assert_eq!(session.metadata.dealer_epoch, frozen_state.epoch);
    assert_targets(
        &session.metadata.dealer_validator_set,
        &frozen_state.validators,
    );
    assert_targets(
        &session.metadata.target_validator_set,
        &frozen_state.validators,
    );
    for scope in all {
        assert_eq!(
            snapshot(&f, scope, f.root.address(), before_freeze).await,
            snapshot(&f, scope, f.root.address(), frozen_at).await
        );
    }
    // 单独提交同一个 Z，证明批次前项在冻结中仍是合法的零额操作。
    let zero_only = success(
        execute(
            &f.client,
            &f.attacker,
            &f.factory,
            aptos_stdlib::vesting_unlock_rewards_many(vec![zero.staker]),
        )
        .await,
    );
    let zero_at = zero_only.info.version.0;
    for scope in all {
        assert_eq!(
            snapshot(&f, scope, f.attacker.address(), zero_at - 1).await,
            snapshot(&f, scope, f.attacker.address(), zero_at).await
        );
    }
    assert_eq!(
        batch_protocol(&f, zero_at - 1).await,
        batch_protocol(&f, zero_at).await
    );
    assert!(zero_only.events.iter().all(|event| {
        let name = event.typ.to_string();
        !name.contains("::stake::")
            && !name.contains("::staking_contract::")
            && !name.contains("::vesting::")
    }));
    wallet_delta(&f, &zero_only, 0).await;
    assert_frozen(&f, &frozen, zero_at).await;
    // Z 没有净收益，提前返回且不触及质押冻结检查；A 有正 R2，随后在
    // withdraw_with_cap 处拒绝。冻结前后的角色、池和原始 payload 保持一致。
    let rejected = reject_reward_batch(&f, &all, payload.clone(), "stake", 0x30014).await;
    assert_frozen(&f, &frozen, rejected.info.version.0).await;
    assert_batch_distribution(&f, &positive, rejected.info.version.0, first_income).await;
    // 单项公开入口转调相同的 staking contract 能力路径；正收益状态下也必须
    // 在 stake 冻结检查处拒绝，并回滚佣金、临时份额、付款和全部业务事件。
    let single = aptos_stdlib::vesting_unlock_rewards(positive.staker);
    let rejected_single = reject_reward_batch(&f, &all, single.clone(), "stake", 0x30014).await;
    assert_frozen(&f, &frozen, rejected_single.info.version.0).await;
    assert_batch_distribution(&f, &positive, rejected_single.info.version.0, first_income).await;
    let before_completion = version(&f).await;
    let completed = success(
        execute(
            &f.client,
            &f.root,
            &f.factory,
            reward_batch_governance(3, positive.pool, frozen_state.epoch, false, 0, false),
        )
        .await,
    );
    let completed_at = completed.info.version.0;
    assert_eq!(
        assert_batch_settlement(&f, &completed, positive.pool, false, false)
            .await
            .native,
        0
    );
    for scope in all {
        assert_eq!(
            snapshot(&f, scope, f.root.address(), before_completion).await,
            snapshot(&f, scope, f.root.address(), completed_at).await
        );
    }
    for name in [
        "0x1::stake::EpochPlan",
        "0x1::stake::PrecomputedValidatorSet",
    ] {
        assert!(
            optional_resource_at_version(&f.client, CORE_CODE_ADDRESS, name, completed_at)
                .await
                .is_none()
        );
    }
    assert!(resource_at_version::<DKGState>(&f.client, completed_at)
        .await
        .in_progress
        .is_none());
    for node in f.swarm.validators() {
        node.rest_client()
            .set_failpoint("dkg::process_dkg_start_event".to_owned(), "off".to_owned())
            .await
            .unwrap();
    }
    super::freeze::assert_installed(
        &f,
        completed_at,
        frozen_state.epoch + 1,
        &frozen_state.validators,
        3000,
        None,
    )
    .await;
    let recovered = success(execute(&f.client, &f.attacker, &f.factory, single.clone()).await);
    assert_batch_unlock(
        &f,
        &recovered,
        &positive,
        &zero,
        beneficiary.address(),
        first_income,
        second_income,
    )
    .await;
    let repeated = success(execute(&f.client, &f.attacker, &f.factory, single).await);
    let repeated_at = repeated.info.version.0;
    for scope in all {
        assert_eq!(
            snapshot(&f, scope, f.attacker.address(), repeated_at - 1).await,
            snapshot(&f, scope, f.attacker.address(), repeated_at).await
        );
    }
    assert_eq!(
        batch_protocol(&f, repeated_at - 1).await,
        batch_protocol(&f, repeated_at).await
    );
    assert!(repeated.events.iter().all(|event| {
        let name = event.typ.to_string();
        !name.contains("::stake::")
            && !name.contains("::staking_contract::")
            && !name.contains("::vesting::")
    }));
    wallet_delta(&f, &repeated, 0).await;
    wait_batch_proposals(&f, positive.pool, frozen_state.epoch + 1).await;
    let final_at = version(&f).await;
    super::freeze::assert_installed(
        &f,
        final_at,
        frozen_state.epoch + 1,
        &frozen_state.validators,
        3000,
        None,
    )
    .await;
    for node in f.swarm.validators() {
        let client = node.rest_client();
        for scope in all {
            for (owner, name) in [
                (scope.staker, "staking_contract::Store"),
                (scope.staker, "vesting::VestingContract"),
                (scope.pool, "stake::StakePool"),
            ] {
                let actual =
                    optional_resource_at_version(&client, owner, &format!("0x1::{name}"), final_at)
                        .await
                        .unwrap()
                        .data;
                assert_eq!(actual, resource(&f, owner, name, final_at).await);
            }
            for wallet in scope
                .wallets
                .iter()
                .copied()
                .chain([scope.staker, scope.pool])
            {
                assert_eq!(
                    client
                        .view_apt_account_balance_at_version(wallet, final_at)
                        .await
                        .unwrap()
                        .into_inner(),
                    balance(&f, wallet, final_at).await
                );
            }
        }
        assert_eq!(
            optional_resource_at_version(
                &client,
                CORE_CODE_ADDRESS,
                "0x1::poc_power_store::PeriodClock",
                final_at
            )
            .await
            .unwrap()
            .data,
            resource(
                &f,
                CORE_CODE_ADDRESS,
                "poc_power_store::PeriodClock",
                final_at
            )
            .await
        );
        for pool in &f.pools {
            assert_eq!(
                ledger_at(&client, *pool, final_at).await,
                ledger_at(&f.client, *pool, final_at).await
            );
        }
    }
    println!("FRZ-02 positive vesting batch/single complete: R1={first_income:?}, R2={second_income:?}, exact prefix payments and new shares rolled back on vesting:0x30008; paused ordinary DKG rejects both [zero, positive] and single positive unlock at stake:0x30014; single recovery pays R1 and unlocks R2 exactly once; four current nodes agree at version={final_at}, elapsed={:?}", started.elapsed());
}
