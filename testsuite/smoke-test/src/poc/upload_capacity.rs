// Copyright (c) Aptos Foundation
// Licensed pursuant to the Innovation-Enabling Source Code License, available at https://github.com/aptos-labs/aptos-core/blob/main/LICENSE

//! PWR-06 / NUM-02：未来容量拒绝、满额池的下一期拒绝及两段大旧链的合法替换。
//! 所有极限值均通过公开上传入口和真实 Epoch 提交构造。
//! 五节点 A 配置使用 retention=5000，并推进到支持范围的边界 I24=2^40。

use super::{
    defaults::{installed_at, InstalledSnapshot},
    fee_rewards::{
        address, assert_payment, checkpoint_at, events, integer, ledger_at, pool_at, pool_event,
        position_at, success, view, wide,
    },
    optional_resource_at_version,
    transactions::{assert_abort, compile_script, execute},
};
use crate::smoke_test_environment::SwarmBuilder;
use aptos_api_types::{AptosErrorCode, UserTransaction};
use aptos_cached_packages::aptos_stdlib;
use aptos_forge::{LocalSwarm, NodeExt, Swarm};
use aptos_genesis::poc::{DeploymentLimits, DeploymentMode, PocGenesisConfiguration, PowerParams};
use aptos_rest_client::{error::RestError, Client};
use aptos_sdk::{transaction_builder::TransactionFactory, types::LocalAccount};
use aptos_types::{
    account_address::AccountAddress,
    account_config::CORE_CODE_ADDRESS,
    on_chain_config::{OnChainChunkyDKGConfig, OnChainRandomnessConfig, ValidatorSet},
    transaction::{Script, TransactionArgument, TransactionPayload},
    validator_info::ValidatorInfo,
};
use move_core_types::int256::U256;
use once_cell::sync::Lazy;
use serde_json::{json, Value};
use std::{collections::BTreeMap, sync::Arc, time::Duration};
use tokio::time::{timeout, Instant};

const INITIAL_RAW: u64 = 1 << 32;
const INITIAL_UNITS: u128 = 1 << 64;
const SCALE: u128 = 1 << 32;
const INDEX_SCALE: u128 = 1 << 64;
const CAPACITY: u128 = 1 << 120;
const UPLOAD_PERIOD: u64 = 24;
const BOUNDARY: u64 = 85;

static GOVERNANCE: Lazy<Vec<u8>> = Lazy::new(|| {
    compile_script(
        "PoCUploadCapacity",
        r#"script {
        use topo_framework::poc_power_store;
        use topo_framework::topo_governance;
        fun main(root: &signer, operation: u8, uploader: address, length: u64) {
            let framework = topo_governance::get_signer_testnet_only(root, @0x1);
            if (operation == 0) {
                poc_power_store::set_operator(&framework, uploader);
                poc_power_store::set_power_period_in_epochs(&framework, length);
            } else if (operation == 1) {
                topo_governance::reconfigure(&framework);
            } else {
                assert!(operation == 2, 0);
                poc_power_store::set_power_period_in_epochs(&framework, length);
            };
        }
    }"#,
    )
});

struct Fixture {
    swarm: LocalSwarm,
    client: Client,
    root: Arc<LocalAccount>,
    owner: LocalAccount,
    uploader: LocalAccount,
    users: [LocalAccount; 2],
    pools: Vec<AccountAddress>,
    factory: TransactionFactory,
}

fn poc_payload(f: &Fixture, operation: u8, length: u64) -> TransactionPayload {
    TransactionPayload::Script(Script::new(GOVERNANCE.clone(), vec![], vec![
        TransactionArgument::U8(operation),
        TransactionArgument::Address(f.uploader.address()),
        TransactionArgument::U64(length),
    ]))
}

async fn poc_govern(f: &Fixture, operation: u8, length: u64) -> UserTransaction {
    let factory = f.factory.clone().with_gas_unit_price(100);
    success(
        execute(
            &f.client,
            &f.root,
            &factory,
            poc_payload(f, operation, length),
        )
        .await,
    )
}

async fn poc_resource(client: &Client, account: AccountAddress, name: &str, version: u64) -> Value {
    optional_resource_at_version(client, account, name, version)
        .await
        .unwrap_or_else(|| panic!("Missing {name} at {account}, version {version}"))
        .data
}

async fn poc_version(f: &Fixture) -> u64 {
    f.client
        .get_ledger_information()
        .await
        .unwrap()
        .into_inner()
        .version
}

async fn poc_fixture() -> Fixture {
    Lazy::force(&GOVERNANCE);
    println!("Upload capacity fixture A: 5 real validators + 1 fullnode, Open/minimum4/capacity6/growth25%, initial_raw=4294967296 power, bond100 Octa each, ratio1 Octa/power, min_power10/max_power1000, retention5000/max_relative_period24, native0/fee_limit0, reward_horizon1000, epoch3600s, ordinary/Chunky DKG off; public power length60->1, later length specified by each test, upload/governance gas100, member gas1, max_gas2000000");
    let swarm = SwarmBuilder::new_local(5)
        .with_aptos()
        .with_num_fullnodes(1)
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
                    min_validators: 4,
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
                retention_bps: 5000,
                max_relative_period: UPLOAD_PERIOD,
                initial_raw_power: INITIAL_RAW,
                native_reward_bps: 0,
            }));
        }))
        .build()
        .await;
    let mut pools = swarm
        .validators()
        .map(|node| node.peer_id())
        .collect::<Vec<_>>();
    pools.sort();
    // 此背景节点始终属于已安装委员会。Forge 任意选取的首节点客户端
    // 仅用于目标节点退出前的账户注资。
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
    public.mint(pools[0], 100_000_000).await.unwrap();
    let key = swarm
        .validator(pools[0])
        .unwrap()
        .account_private_key()
        .as_ref()
        .unwrap()
        .private_key();
    let sequence = client
        .get_account(pools[0])
        .await
        .unwrap()
        .into_inner()
        .sequence_number;
    let owner = LocalAccount::new(pools[0], key, sequence);
    let uploader = public
        .create_and_fund_user_account(1_000_000_000)
        .await
        .unwrap();
    let users = [
        public
            .create_and_fund_user_account(100_000_000)
            .await
            .unwrap(),
        public
            .create_and_fund_user_account(100_000_000)
            .await
            .unwrap(),
    ];
    let f = Fixture {
        swarm,
        client,
        root,
        owner,
        uploader,
        users,
        pools,
        factory,
    };
    // 治理清理自主退出请求时可能退还存储费用。root 初始余额为 u64::MAX，
    // 因此先通过普通签名转账为退款预留余额空间。
    success(
        execute(
            &f.client,
            &f.root,
            &f.factory,
            aptos_stdlib::topo_coin_transfer(f.pools[1], 100_000_000),
        )
        .await,
    );
    let setup = poc_govern(&f, 0, 1).await;
    let version = setup.info.version.0;
    let installed = installed_at(&f.client, version).await;
    assert_eq!(installed_at(&f.client, version - 1).await, installed);
    assert!(installed.epoch < 60);
    assert_eq!(installed.validators.active_validators.len(), 5);
    assert_eq!(installed.validators.total_voting_power, 500);
    assert!(installed
        .validators
        .active_validators
        .iter()
        .all(|v| v.consensus_voting_power() == 100));
    let store = poc_resource(
        &f.client,
        CORE_CODE_ADDRESS,
        "0x1::poc_power_store::PowerStore",
        version,
    )
    .await;
    assert_eq!(address(&store["operator"]), f.uploader.address());
    assert_eq!(integer(&store["retention_bps_per_period"]), 5000);
    poc_assert_clock(&f.client, version, installed.epoch, 1).await;
    f
}

/// 此参考计算在每次除法前使用宽整数，
/// 不调用 Move 的标准化、聚合展示或结算辅助函数。
fn poc_units(raw: u64, period: u64) -> u128 {
    let index = INDEX_SCALE >> period;
    let product = U256::checked_mul(U256::from(raw), U256::from(SCALE)).unwrap();
    let product = U256::checked_mul(product, U256::from(INDEX_SCALE)).unwrap();
    u128::try_from(U256::checked_div(product, U256::from(index)).unwrap()).unwrap()
}

fn poc_aggregate_power(units: u128, period: u64) -> u128 {
    let product = U256::checked_mul(U256::from(units), U256::from(INDEX_SCALE >> period)).unwrap();
    let scale = U256::checked_mul(U256::from(SCALE), U256::from(INDEX_SCALE)).unwrap();
    u128::try_from(U256::checked_div(product, scale).unwrap()).unwrap()
}

fn poc_clock_model(epoch: u64) -> (u64, u64) {
    assert!(epoch <= BOUNDARY);
    if epoch < 61 {
        (0, 61)
    } else if epoch <= 82 {
        (epoch - 60, epoch + 1)
    } else if epoch <= 84 {
        (23, BOUNDARY)
    } else {
        (UPLOAD_PERIOD, BOUNDARY + 2)
    }
}

async fn poc_assert_clock(client: &Client, version: u64, epoch: u64, length: u64) {
    poc_assert_clock_with_model(client, version, epoch, length, poc_clock_model).await;
}

async fn poc_assert_clock_with_model(
    client: &Client,
    version: u64,
    epoch: u64,
    length: u64,
    model: fn(u64) -> (u64, u64),
) {
    let (period, boundary) = model(epoch);
    let index = INDEX_SCALE >> period;
    let next = if period < UPLOAD_PERIOD {
        json!({"vec": [(index / 2).to_string()]})
    } else {
        json!({"vec": []})
    };
    assert_eq!(
        view(
            client,
            "0x1::poc_power_store::get_normalization_clock",
            vec![],
            version
        )
        .await,
        vec![
            json!("0"),
            json!(period.to_string()),
            json!(boundary.to_string()),
            json!(index.to_string()),
            next,
            json!("24")
        ]
    );
    let clock = poc_resource(
        client,
        CORE_CODE_ADDRESS,
        "0x1::poc_power_store::PeriodClock",
        version,
    )
    .await;
    assert_eq!(integer(&clock["last_epoch"]), epoch as u128);
    assert_eq!(integer(&clock["current_period"]), period as u128);
    assert_eq!(integer(&clock["power_period_in_epochs"]), length as u128);
    assert_eq!(
        integer(&clock["epochs_until_next_power_period"]),
        (boundary - epoch - 1) as u128
    );
}

async fn poc_no_plan(client: &Client, version: u64) {
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
}

async fn poc_commit(f: &Fixture, count: usize, length: u64) -> UserTransaction {
    poc_commit_with_model(f, count, length, poc_clock_model).await
}

async fn poc_commit_with_model(
    f: &Fixture,
    count: usize,
    length: u64,
    model: fn(u64) -> (u64, u64),
) -> UserTransaction {
    let tx = poc_govern(f, 1, 0).await;
    let version = tx.info.version.0;
    let old = installed_at(&f.client, version - 1).await;
    let new = installed_at(&f.client, version).await;
    let active = old
        .validators
        .active_validators
        .iter()
        .chain(old.validators.pending_active.iter().rev())
        .enumerate()
        .map(|(index, info)| {
            let mut config = info.config().clone();
            config.validator_index = index as u64;
            ValidatorInfo::new(info.account_address, 100, config)
        })
        .collect::<Vec<_>>();
    assert_eq!(active.len(), count);
    let expected = ValidatorSet {
        scheme: old.validators.scheme,
        active_validators: active,
        pending_inactive: vec![],
        pending_active: vec![],
        total_voting_power: count as u128 * 100,
        total_joining_power: 0,
    };
    assert_eq!(new.validators, expected);
    assert_eq!(new.epoch, old.epoch + 1);
    assert_eq!(new.reward_context.2, old.reward_context.2);
    assert_eq!(new.reward_context.3, old.reward_context.3);
    assert_eq!(new.reward_context.5, 0);
    assert_eq!(integer(&new.reward_split["installed_native_reward_bps"]), 0);
    let installed = events(&tx, "::stake::PoCEpochInstalled");
    assert_eq!(installed.len(), 1);
    assert_eq!(
        installed[0].data,
        json!({"epoch": new.epoch.to_string(),
        "period": model(new.epoch).0.to_string(), "selected_count": count.to_string(),
        "total_power": (count * 100).to_string()})
    );
    assert_eq!(events(&tx, "::reconfiguration::NewEpochEvent").len(), 1);
    poc_assert_clock_with_model(&f.client, version, new.epoch, length, model).await;
    poc_no_plan(&f.client, version).await;
    let period = model(new.epoch).0;
    assert!(poc_aggregate_power(INITIAL_UNITS, period) >= 100);
    for pool in &f.pools[1..] {
        let actual = pool_at(&f.client, *pool, version).await;
        assert_eq!(integer(&actual[0]), INITIAL_UNITS);
        assert_eq!(integer(&actual[2]), 100);
    }
    println!(
        "Upload capacity commit {} -> {}, period={period}, members={count}, version={version}",
        old.epoch, new.epoch
    );
    tx
}

async fn poc_optional_table(
    client: &Client,
    handle: AccountAddress,
    key_type: &str,
    value_type: &str,
    key: Value,
    version: u64,
) -> Option<Value> {
    match client
        .get_table_item_at_version(handle, key_type, value_type, key, version)
        .await
    {
        Ok(value) => Some(value.into_inner()),
        Err(RestError::Api(error))
            if error.status_code == reqwest::StatusCode::NOT_FOUND
                && error.error.error_code == AptosErrorCode::TableItemNotFound =>
        {
            None
        },
        Err(error) => panic!("Cannot read {value_type} at {handle}, version {version}: {error}"),
    }
}

async fn poc_raw_power(client: &Client, user: AccountAddress, version: u64) -> Option<Value> {
    let store = poc_resource(
        client,
        CORE_CODE_ADDRESS,
        "0x1::poc_power_store::PowerStore",
        version,
    )
    .await;
    poc_optional_table(
        client,
        address(&store["users"]["handle"]),
        "address",
        "0x1::poc_power_store::UserPowerInfo",
        json!(user),
        version,
    )
    .await
}

async fn poc_position(
    client: &Client,
    user: AccountAddress,
    pool: AccountAddress,
    version: u64,
) -> Value {
    let allocation =
        poc_resource(client, user, "0x1::poc_accounting::UserAllocation", version).await;
    poc_optional_table(
        client,
        address(&allocation["positions"]["handle"]),
        "address",
        "0x1::poc_accounting::Position",
        json!(pool),
        version,
    )
    .await
    .unwrap()
}

async fn poc_pool_units(client: &Client, pool: AccountAddress, epoch: u64, version: u64) -> u128 {
    let result = view(
        client,
        "0x1::poc_accounting::preview_pool_units",
        vec![json!(pool), json!(epoch.to_string())],
        version,
    )
    .await;
    assert_eq!(result.len(), 1);
    integer(&result[0])
}

#[derive(Debug, PartialEq)]
struct Snapshot {
    installed: InstalledSnapshot,
    data: BTreeMap<String, Value>,
}

/// 在共享 abort 断言之外，保留原始 UserPowerInfo、Position 表项，
/// 以及包含有效 refs 的实际历史 Checkpoint 表项。
async fn poc_snapshot(f: &Fixture, version: u64, retired_epoch: u64) -> Snapshot {
    poc_snapshot_at(
        f,
        &f.client,
        version,
        &[
            f.owner.address(),
            f.users[0].address(),
            f.users[1].address(),
        ],
        &[retired_epoch, 83, 84, BOUNDARY],
    )
    .await
}

async fn poc_snapshot_at(
    f: &Fixture,
    client: &Client,
    version: u64,
    users: &[AccountAddress],
    checkpoints: &[u64],
) -> Snapshot {
    let mut data = BTreeMap::new();
    for name in [
        "0x1::reconfiguration::Configuration",
        "0x1::reconfiguration_state::State",
        "0x1::poc_power_store::PowerStore",
        "0x1::poc_power_store::PeriodClock",
        "0x1::poc_accounting::AccountingState",
        "0x1::stake::ValidatorPerformance",
        "0x1::stake::PendingTransactionFee",
        "0x1::stake::VoluntaryLeaves",
    ] {
        data.insert(
            name.to_owned(),
            poc_resource(client, CORE_CODE_ADDRESS, name, version).await,
        );
    }
    for pool in &f.pools {
        data.insert(
            format!("stake:{pool}"),
            poc_resource(client, *pool, "0x1::stake::StakePool", version).await,
        );
        data.insert(
            format!("ledger:{pool}"),
            ledger_at(client, *pool, version).await,
        );
    }
    for user in users {
        data.insert(
            format!("raw:{user}"),
            json!(poc_raw_power(client, *user, version).await),
        );
        data.insert(
            format!("allocation:{user}"),
            poc_resource(
                client,
                *user,
                "0x1::poc_accounting::UserAllocation",
                version,
            )
            .await,
        );
        data.insert(
            format!("position:{user}"),
            poc_position(client, *user, f.owner.address(), version).await,
        );
    }
    for epoch in checkpoints {
        data.insert(
            format!("checkpoint:{epoch}"),
            json!(checkpoint_at(client, f.owner.address(), *epoch, version).await),
        );
    }
    poc_no_plan(client, version).await;
    Snapshot {
        installed: installed_at(client, version).await,
        data,
    }
}

async fn poc_allocate(
    f: &Fixture,
    signer: &LocalAccount,
    pools: Vec<AccountAddress>,
    bps: Vec<u64>,
) -> u64 {
    let tx = success(
        execute(
            &f.client,
            signer,
            &f.factory,
            aptos_stdlib::poc_allocation_set_allocations(pools, bps),
        )
        .await,
    );
    tx.info.version.0
}

async fn poc_prepare_empty_pool(f: &Fixture) -> u64 {
    let target = f.owner.address();
    let cleared = poc_allocate(f, &f.owner, vec![], vec![]).await;
    let current = installed_at(&f.client, cleared).await;
    assert_eq!(
        poc_pool_units(&f.client, target, current.epoch, cleared).await,
        INITIAL_UNITS
    );
    assert_eq!(
        poc_pool_units(&f.client, target, current.epoch + 1, cleared).await,
        0
    );
    let left = success(
        execute(
            &f.client,
            &f.owner,
            &f.factory,
            aptos_stdlib::stake_leave_validator_set(target),
        )
        .await,
    );
    let queued = installed_at(&f.client, left.info.version.0).await;
    assert_eq!(queued.validators.active_validators.len(), 4);
    assert_eq!(queued.validators.pending_inactive.len(), 1);
    assert_eq!(
        queued.validators.pending_inactive[0].account_address,
        target
    );
    assert_eq!(queued.validators.total_voting_power, 500);
    let retired = poc_commit(f, 4, 1).await;
    let version = retired.info.version.0;
    let epoch = installed_at(&f.client, version).await.epoch;
    assert_eq!(integer(&pool_at(&f.client, target, version).await[0]), 0);
    assert_eq!(integer(&pool_at(&f.client, target, version).await[2]), 0);
    let checkpoint = checkpoint_at(&f.client, target, epoch, version)
        .await
        .unwrap();
    assert_eq!(integer(&checkpoint["refs"]), 1);
    // 不触碰原 owner 已有成熟变化的持仓，使这一实际检查点引用
    // 在后续批次失败及修复过程中始终保留。
    for user in &f.users {
        let allocated = poc_allocate(f, user, vec![target], vec![10_000]).await;
        assert!(poc_raw_power(&f.client, user.address(), allocated)
            .await
            .is_none());
        let position = poc_position(&f.client, user.address(), target, allocated).await;
        assert_eq!(integer(&position["units"]), 0);
        assert_eq!(position["changes"], json!([]));
    }
    println!("Retired target={target} at epoch={epoch}; cleared genesis units, four live backgrounds, historical checkpoint refs=1");
    epoch
}

async fn poc_upload(f: &Fixture, second_raw: u64) -> UserTransaction {
    let factory = f.factory.clone().with_gas_unit_price(100);
    execute(
        &f.client,
        &f.uploader,
        &factory,
        aptos_stdlib::poc_power_store_stage_batch_update(
            UPLOAD_PERIOD,
            vec![f.users[0].address(), f.users[1].address()],
            vec![u64::MAX, second_raw],
        ),
    )
    .await
}

async fn poc_assert_successful_batch(f: &Fixture, tx: &UserTransaction) {
    let version = tx.info.version.0;
    let normalized = events(tx, "::poc_power_store::PowerNormalized");
    let staged = events(tx, "::poc_power_store::PowerUpdateStagedEvent");
    assert_eq!(
        normalized.len(),
        2,
        "Both rolled-back users must be newly written on retry"
    );
    assert_eq!(staged.len(), 2);
    let business = tx
        .events
        .iter()
        .filter(|event| event.typ.to_string().contains("::poc_"))
        .collect::<Vec<_>>();
    assert_eq!(business.len(), 4);
    for (i, raw) in [u64::MAX, 1].into_iter().enumerate() {
        let user = f.users[i].address();
        let units = poc_units(raw, UPLOAD_PERIOD);
        assert!(business[2 * i]
            .typ
            .to_string()
            .ends_with("::PowerNormalized"));
        assert!(business[2 * i + 1]
            .typ
            .to_string()
            .ends_with("::PowerUpdateStagedEvent"));
        assert_eq!(
            normalized[i].data,
            json!({"user": user.to_hex_literal(), "effective_period": "24", "units": units.to_string()})
        );
        assert_eq!(
            staged[i].data,
            json!({"effective_period": "24", "user": user.to_hex_literal(), "power": raw.to_string()})
        );
        assert_eq!(
            poc_raw_power(&f.client, user, version).await.unwrap(),
            json!({"older": {"vec": []}, "newer": {"vec": [{"effective_period": "24", "power": raw.to_string(), "units": units.to_string()}]}})
        );
        let position = poc_position(&f.client, user, f.owner.address(), version).await;
        assert_eq!(integer(&position["units"]), 0);
        assert_eq!(
            position["changes"],
            json!([{"epoch": BOUNDARY.to_string(), "units": units.to_string()}])
        );
        assert_eq!(
            view(
                &f.client,
                "0x1::poc_power_store::get_accounting_snapshot",
                vec![json!(user)],
                version
            )
            .await,
            vec![
                json!("0"),
                json!(units.to_string()),
                json!("23"),
                json!(BOUNDARY.to_string())
            ]
        );
    }
    let ledger = ledger_at(&f.client, f.owner.address(), version).await;
    assert_eq!(integer(&ledger["epoch"]), 83);
    assert_eq!(integer(&ledger["units"]), 0);
    assert_eq!(
        ledger["changes"],
        json!([{"epoch": BOUNDARY.to_string(), "remove_units": "0", "add_units": CAPACITY.to_string(), "refs": "2"}])
    );
    assert!(
        checkpoint_at(&f.client, f.owner.address(), BOUNDARY, version)
            .await
            .is_none()
    );
    for (epoch, expected) in [(83, 0), (84, 0), (BOUNDARY, CAPACITY)] {
        assert_eq!(
            poc_pool_units(&f.client, f.owner.address(), epoch, version).await,
            expected
        );
    }
}

async fn poc_assert_reward_commit(f: &Fixture, tx: &UserTransaction) {
    let version = tx.info.version.0;
    let old = installed_at(&f.client, version - 1).await;
    assert_eq!(old.validators.active_validators.len(), 4);
    let stats = poc_resource(
        &f.client,
        CORE_CODE_ADDRESS,
        "0x1::stake::ValidatorPerformance",
        version - 1,
    )
    .await;
    assert_eq!(events(tx, "::stake::PoCRewardCredited").len(), 4);
    assert_eq!(events(tx, "::stake::PoCRewardSplit").len(), 4);
    for info in &old.validators.active_validators {
        assert_ne!(info.account_address, f.owner.address());
        let perf = &stats["validators"][info.config().validator_index as usize];
        let successful = integer(&perf["successful_proposals"]);
        let total = successful + integer(&perf["failed_proposals"]);
        let reward = if total == 0 {
            0
        } else {
            (100 * successful * old.reward_context.2 as u128
                / (total * old.reward_context.3 as u128)) as u64
        };
        let before = pool_at(&f.client, info.account_address, version - 1).await;
        let after = pool_at(&f.client, info.account_address, version).await;
        assert_eq!(integer(&after[3]) - integer(&before[3]), reward as u128);
        let delta = (U256::from(reward).repr() << 128u32) / U256::from(INITIAL_UNITS).repr();
        assert_eq!(wide(&after[4]).repr() - wide(&before[4]).repr(), delta);
        assert_eq!(
            pool_event(tx, "::stake::PoCRewardCredited", info.account_address).data,
            json!({"pool": info.account_address.to_hex_literal(), "closing_epoch": old.epoch.to_string(),
                "reward_base_octa": "100", "inflation": reward.to_string(), "fee": "0", "delta_index": delta.to_string()})
        );
        assert_eq!(
            pool_event(tx, "::stake::PoCRewardSplit", info.account_address).data,
            json!({"pool": info.account_address.to_hex_literal(), "closing_epoch": old.epoch.to_string(), "native_reward_bps": "0",
                "total_inflation_octa": reward.to_string(), "active_native_reward_octa": "0", "pending_inactive_native_reward_octa": "0",
                "poc_inflation_octa": reward.to_string()})
        );
    }
    let target_before = pool_at(&f.client, f.owner.address(), version - 1).await;
    let target_after = pool_at(&f.client, f.owner.address(), version).await;
    assert_eq!(target_after[3], target_before[3]);
    assert_eq!(target_after[4], target_before[4]);
}

#[tokio::test]
async fn poc_upload_late_capacity_abort_rolls_back_then_installs_exact_limit() {
    let largest = poc_units(u64::MAX, UPLOAD_PERIOD);
    let one = poc_units(1, UPLOAD_PERIOD);
    let two = poc_units(2, UPLOAD_PERIOD);
    assert_eq!(INDEX_SCALE >> UPLOAD_PERIOD, 1 << 40);
    assert_eq!(largest, CAPACITY - (1 << 56));
    assert_eq!(one, 1 << 56);
    assert_eq!(two, 1 << 57);
    assert!(largest < CAPACITY && two < CAPACITY);
    assert_eq!(largest + two, CAPACITY + (1 << 56));
    assert_eq!(largest + one, CAPACITY);
    let aggregate_power = poc_aggregate_power(CAPACITY, UPLOAD_PERIOD);
    assert_eq!(aggregate_power, 1u128 << 64);
    // 在宽整数范围内限幅；若先将原始聚合算力转为 u64，会因溢出失败。
    let expected_weight = u64::try_from(aggregate_power.min(100).min(1000)).unwrap();
    assert_eq!(expected_weight, 100);
    assert_eq!(poc_aggregate_power(INITIAL_UNITS, UPLOAD_PERIOD), 256);

    let f = poc_fixture().await;
    let retired_epoch = poc_prepare_empty_pool(&f).await;
    let started = Instant::now();
    timeout(Duration::from_secs(300), async {
        loop {
            let installed = installed_at(&f.client, poc_version(&f).await).await;
            assert!(installed.epoch <= 82);
            if installed.epoch == 82 {
                break;
            }
            poc_commit(&f, 4, 1).await;
        }
    })
    .await
    .expect("Public epoch preparation to E82 exceeded 300 seconds");
    println!(
        "Prepared E82/P22 through individual public commits in {:?}",
        started.elapsed()
    );
    // 保持 B83 不变，同时令 P23 持续两个 Epoch，使 E84 与 B85 分离。
    let length = poc_govern(&f, 2, 2).await.info.version.0;
    assert_eq!(
        installed_at(&f.client, length - 1).await,
        installed_at(&f.client, length).await
    );
    poc_assert_clock(&f.client, length, 82, 2).await;
    let at_83 = poc_commit(&f, 4, 2).await.info.version.0;
    assert_eq!(installed_at(&f.client, at_83).await.epoch, 83);
    let target = f.owner.address();
    for epoch in [83, 84, BOUNDARY] {
        assert_eq!(poc_pool_units(&f.client, target, epoch, at_83).await, 0);
    }
    for user in &f.users {
        assert!(poc_raw_power(&f.client, user.address(), at_83)
            .await
            .is_none());
        assert_eq!(
            view(
                &f.client,
                "0x1::poc_accounting::get_allocations",
                vec![json!(user.address())],
                at_83
            )
            .await,
            vec![
                json!([{"pool": target.to_hex_literal(), "bps": "10000"}]),
                json!({"vec": []})
            ]
        );
    }
    let original_checkpoint = checkpoint_at(&f.client, target, retired_epoch, at_83)
        .await
        .unwrap();
    assert_eq!(integer(&original_checkpoint["refs"]), 1);

    let rejected = poc_upload(&f, 2).await;
    let failed_version = rejected.info.version.0;
    assert_abort(
        &f.client,
        &rejected,
        "poc_accounting",
        0x20008,
        &[target, f.users[0].address(), f.users[1].address()],
        &f.pools,
    )
    .await;
    assert_eq!(
        poc_snapshot(&f, failed_version - 1, retired_epoch).await,
        poc_snapshot(&f, failed_version, retired_epoch).await
    );
    for user in &f.users {
        assert!(poc_raw_power(&f.client, user.address(), failed_version)
            .await
            .is_none());
        let position = poc_position(&f.client, user.address(), target, failed_version).await;
        assert_eq!(integer(&position["units"]), 0);
        assert_eq!(position["changes"], json!([]));
    }
    assert_eq!(
        ledger_at(&f.client, target, failed_version).await["changes"],
        json!([])
    );
    assert_eq!(
        checkpoint_at(&f.client, target, retired_epoch, failed_version).await,
        Some(original_checkpoint.clone())
    );
    for epoch in [83, 84, BOUNDARY] {
        assert_eq!(
            poc_pool_units(&f.client, target, epoch, failed_version).await,
            0
        );
    }
    println!("Later batch item rejected with poc_accounting/0x20008 at E83: current/E84=0; first units={largest} fits; first+second={} exceeds only B85; both raw entries, positions, refs, events and writes rolled back", largest + two);

    let accepted = success(poc_upload(&f, 1).await);
    let staged = accepted.info.version.0;
    assert_eq!(
        installed_at(&f.client, staged - 1).await,
        installed_at(&f.client, staged).await
    );
    poc_assert_successful_batch(&f, &accepted).await;
    assert_eq!(
        checkpoint_at(&f.client, target, retired_epoch, staged).await,
        Some(original_checkpoint.clone())
    );
    // 提交中间的 Epoch：此前批次仅在未来 B 边界失败，当前及 E+1 均合法；
    // 修复后的 B85 目标仍保持待生效状态。
    let at_84 = poc_commit(&f, 4, 2).await;
    poc_assert_reward_commit(&f, &at_84).await;
    let v84 = at_84.info.version.0;
    assert_eq!(installed_at(&f.client, v84).await.epoch, 84);
    let pool = pool_at(&f.client, target, v84).await;
    assert_eq!(integer(&pool[0]), 0);
    assert_eq!(integer(&pool[1]), CAPACITY);
    assert_eq!(integer(&pool[2]), 0);
    assert_eq!(
        ledger_at(&f.client, target, v84).await["changes"],
        json!([{"epoch": BOUNDARY.to_string(), "remove_units": "0", "add_units": CAPACITY.to_string(), "refs": "2"}])
    );

    let joined = success(
        execute(
            &f.client,
            &f.owner,
            &f.factory,
            aptos_stdlib::stake_join_validator_set(target),
        )
        .await,
    );
    let queued_version = joined.info.version.0;
    let queued = installed_at(&f.client, queued_version).await;
    assert_eq!(queued.validators.active_validators.len(), 4);
    assert_eq!(queued.validators.pending_active.len(), 1);
    assert_eq!(queued.validators.pending_active[0].account_address, target);
    assert_eq!(
        queued.validators.pending_active[0].consensus_voting_power(),
        0
    );
    assert_eq!(queued.validators.total_joining_power, 0);
    assert_eq!(queued.validators.total_voting_power, 400);
    let now = poc_resource(
        &f.client,
        CORE_CODE_ADDRESS,
        "0x1::timestamp::CurrentTimeMicroseconds",
        queued_version,
    )
    .await;
    let preview = view(
        &f.client,
        "0x1::stake::preview_epoch_transition",
        vec![
            json!(BOUNDARY.to_string()),
            json!((integer(&now["microseconds"]) / 1_000_000).to_string()),
        ],
        queued_version,
    )
    .await;
    assert_eq!(preview.len(), 1);
    assert_eq!(integer(&preview[0]["reason"]), 0);
    assert_eq!(integer(&preview[0]["period"]), UPLOAD_PERIOD as u128);
    assert_eq!(integer(&preview[0]["period_index"]), 1 << 40);
    assert_eq!(
        integer(&preview[0]["validator_set"]["total_voting_power"]),
        500
    );
    let targets = preview[0]["targets"].as_array().unwrap();
    assert_eq!(targets.len(), 5);
    for pool in &f.pools {
        let selected = targets
            .iter()
            .find(|value| address(&value["pool"]) == *pool)
            .unwrap();
        assert_eq!(
            integer(&selected["units"]),
            if *pool == target {
                CAPACITY
            } else {
                INITIAL_UNITS
            }
        );
        assert_eq!(integer(&selected["power"]), expected_weight as u128);
        assert_eq!(integer(&selected["reward_base_octa"]), 100);
    }
    let installed_tx = poc_commit(&f, 5, 2).await;
    poc_assert_reward_commit(&f, &installed_tx).await;
    let completed = installed_tx.info.version.0;
    let installed = installed_at(&f.client, completed).await;
    assert_eq!(installed.epoch, BOUNDARY);
    let target_pool = pool_at(&f.client, target, completed).await;
    assert_eq!(integer(&target_pool[0]), CAPACITY);
    assert_eq!(integer(&target_pool[1]), CAPACITY);
    assert_eq!(integer(&target_pool[2]), 100);
    let target_ledger = ledger_at(&f.client, target, completed).await;
    assert_eq!(integer(&target_ledger["epoch"]), BOUNDARY as u128);
    assert_eq!(integer(&target_ledger["units"]), CAPACITY);
    assert_eq!(target_ledger["changes"], json!([]));
    let new_checkpoint = checkpoint_at(&f.client, target, BOUNDARY, completed)
        .await
        .unwrap();
    assert_eq!(integer(&new_checkpoint["refs"]), 2);
    assert_eq!(new_checkpoint["index"], target_ledger["index"]);
    assert_eq!(
        checkpoint_at(&f.client, target, retired_epoch, completed).await,
        Some(original_checkpoint)
    );
    for (user, raw) in f.users.iter().zip([u64::MAX, 1]) {
        let expected = poc_units(raw, UPLOAD_PERIOD);
        let position = position_at(&f.client, user.address(), target, completed).await;
        assert_eq!(integer(&position[0]), expected);
        assert_eq!(position[1], json!([]));
        assert_eq!(integer(&position[2]), 0);
    }
    // 四个背景节点已占新委员会权重的 80%，因此仅凭转账提交成功
    // 不能证明长期退出的节点已恢复提案。
    let target_index = installed
        .validators
        .active_validators
        .iter()
        .find(|member| member.account_address == target)
        .unwrap()
        .config()
        .validator_index as usize;
    timeout(Duration::from_secs(90), async {
        loop {
            let version = poc_version(&f).await;
            assert_eq!(installed_at(&f.client, version).await, installed);
            let performance = poc_resource(
                &f.client,
                CORE_CODE_ADDRESS,
                "0x1::stake::ValidatorPerformance",
                version,
            )
            .await;
            let successful =
                integer(&performance["validators"][target_index]["successful_proposals"]);
            if successful > 0 {
                println!("Rejoined capacity target proposed in E85: version={version}, target={target}, successful={successful}");
                break;
            }
            success(
                execute(
                    &f.client,
                    &f.root,
                    &f.factory,
                    aptos_stdlib::topo_coin_transfer(f.pools[1], 1),
                )
                .await,
            );
        }
    })
    .await
    .expect("Rejoined target did not propose in E85 within 90 seconds");
    // 不进入不受支持的 P25。等待重新加入的节点实际产出提案后，
    // 在固定版本比较全部五个已安装成员。
    let progress = success(
        execute(
            &f.client,
            &f.root,
            &f.factory,
            aptos_stdlib::topo_coin_transfer(f.pools[1], 1),
        )
        .await,
    );
    assert!(progress.info.version.0 > completed);
    let same_version = progress.info.version.0;
    assert_eq!(installed_at(&f.client, same_version).await, installed);
    assert_eq!(
        ledger_at(&f.client, target, same_version).await,
        target_ledger
    );
    for node in f.swarm.validators() {
        let client = node.rest_client_with_timeout(Duration::from_secs(10));
        timeout(
            Duration::from_secs(30),
            client.wait_for_version(same_version),
        )
        .await
        .expect("Current member catchup exceeded 30 seconds")
        .unwrap();
        assert_eq!(installed_at(&client, same_version).await, installed);
        poc_assert_clock(&client, same_version, BOUNDARY, 2).await;
        for pool in &f.pools {
            assert_eq!(
                ledger_at(&client, *pool, same_version).await,
                ledger_at(&f.client, *pool, same_version).await
            );
        }
        for user in &f.users {
            assert_eq!(
                poc_raw_power(&client, user.address(), same_version).await,
                poc_raw_power(&f.client, user.address(), same_version).await
            );
            assert_eq!(
                poc_position(&client, user.address(), target, same_version).await,
                poc_position(&f.client, user.address(), target, same_version).await
            );
        }
    }
    println!("Exact pool limit installed: E83 future B85={CAPACITY}, E84 next={CAPACITY}, E85 current={CAPACITY}; aggregate power={aggregate_power} capped in wide arithmetic to100; original target rejoined, five nodes agree at version={same_version}; P24 next_index=None, no unsupported transition attempted");
}

const REBUILD_BOUNDARY: u64 = 88;
const REBUILD_RAW: u64 = u64::MAX - 255;

fn poc_rebuild_clock_model(epoch: u64) -> (u64, u64) {
    assert!(epoch <= REBUILD_BOUNDARY);
    if epoch < 61 {
        (0, 61)
    } else if epoch <= 82 {
        (epoch - 60, epoch + 1)
    } else if epoch < REBUILD_BOUNDARY {
        (23, REBUILD_BOUNDARY)
    } else {
        (24, REBUILD_BOUNDARY + 5)
    }
}

async fn poc_rebuild_upload(
    f: &Fixture,
    period: u64,
    values: &[(AccountAddress, u64)],
) -> UserTransaction {
    let tx = success(
        execute(
            &f.client,
            &f.uploader,
            &f.factory.clone().with_gas_unit_price(100),
            aptos_stdlib::poc_power_store_stage_batch_update(
                period,
                values.iter().map(|(user, _)| *user).collect(),
                values.iter().map(|(_, raw)| *raw).collect(),
            ),
        )
        .await,
    );
    let version = tx.info.version.0;
    assert_eq!(
        installed_at(&f.client, version - 1).await,
        installed_at(&f.client, version).await
    );
    let normalized = events(&tx, "::poc_power_store::PowerNormalized");
    let staged = events(&tx, "::poc_power_store::PowerUpdateStagedEvent");
    assert_eq!(normalized.len(), values.len());
    assert_eq!(staged.len(), values.len());
    assert_eq!(
        tx.events
            .iter()
            .filter(|event| event.typ.to_string().contains("::poc_"))
            .count(),
        2 * values.len()
    );
    for (i, (user, raw)) in values.iter().enumerate() {
        assert_eq!(
            normalized[i].data,
            json!({"user": user.to_hex_literal(), "effective_period": period.to_string(),
                "units": poc_units(*raw, period).to_string()})
        );
        assert_eq!(
            staged[i].data,
            json!({"effective_period": period.to_string(),
                "user": user.to_hex_literal(), "power": raw.to_string()})
        );
    }
    assert_payment(&f.client, &tx, 0).await;
    println!(
        "Capacity rebuild upload: period={period}, users={}, gas_price={}, max_gas={}, gas_used={}, version={version}",
        values.len(), tx.request.gas_unit_price.0, tx.request.max_gas_amount.0, tx.info.gas_used.0
    );
    tx
}

async fn poc_rebuild_allocate(
    f: &Fixture,
    user: &LocalAccount,
    bps: Option<u64>,
) -> UserTransaction {
    let pools = bps.map(|_| vec![f.owner.address()]).unwrap_or_default();
    let ratios = bps.map(|ratio| vec![ratio]).unwrap_or_default();
    let tx = success(
        execute(
            &f.client,
            user,
            &f.factory,
            aptos_stdlib::poc_allocation_set_allocations(pools.clone(), ratios.clone()),
        )
        .await,
    );
    let version = tx.info.version.0;
    let installed = installed_at(&f.client, version).await;
    assert_eq!(installed_at(&f.client, version - 1).await, installed);
    let scheduled = events(&tx, "::poc_accounting::AllocationScheduled");
    assert_eq!(scheduled.len(), 1);
    assert_eq!(
        scheduled[0].data,
        json!({"user": user.address().to_hex_literal(), "effective_epoch": (installed.epoch + 1).to_string(),
            "pools": pools.iter().map(AccountAddress::to_hex_literal).collect::<Vec<_>>(),
            "bps": ratios.iter().map(u64::to_string).collect::<Vec<_>>()})
    );
    assert_eq!(
        tx.events
            .iter()
            .filter(|event| event.typ.to_string().contains("::poc_"))
            .count(),
        1
    );
    assert_payment(&f.client, &tx, 0).await;
    tx
}

async fn poc_rebuild_horizon(
    f: &Fixture,
    version: u64,
    epoch: u64,
    expected: [u128; 3],
    reward_base: u64,
) {
    assert_eq!(installed_at(&f.client, version).await.epoch, epoch);
    let target = f.owner.address();
    for (at, units) in [epoch, epoch + 1, REBUILD_BOUNDARY]
        .into_iter()
        .zip(expected)
    {
        assert!(units <= CAPACITY);
        assert_eq!(poc_pool_units(&f.client, target, at, version).await, units);
    }
    let pool = pool_at(&f.client, target, version).await;
    assert_eq!(integer(&pool[0]), expected[0]);
    assert_eq!(integer(&pool[1]), expected[1]);
    assert_eq!(integer(&pool[2]), reward_base as u128);
    let ledger = ledger_at(&f.client, target, version).await;
    assert_eq!(integer(&ledger["epoch"]), epoch as u128);
    assert_eq!(integer(&ledger["units"]), expected[0]);
}

async fn poc_rebuild_refs(f: &Fixture, version: u64, expected: &[(u64, Option<u64>)]) {
    for (epoch, refs) in expected {
        let checkpoint = checkpoint_at(&f.client, f.owner.address(), *epoch, version).await;
        match refs {
            Some(refs) => assert_eq!(
                integer(&checkpoint.unwrap()["refs"]),
                *refs as u128,
                "Unexpected checkpoint refs at epoch {epoch}, version {version}"
            ),
            None => assert!(
                checkpoint.is_none(),
                "Unexpected checkpoint at epoch {epoch}, version {version}"
            ),
        }
    }
}

/// 按旧委员会索引读取提案统计，独立计算已安装基数对应的旧期奖励。
/// 此配置原生占比和费用限额均为 0，原生四类余额不能因 PoC 入账改变。
async fn poc_rebuild_rewards(f: &Fixture, tx: &UserTransaction, target_units: u128) {
    let version = tx.info.version.0;
    let old = installed_at(&f.client, version - 1).await;
    assert_eq!(old.reward_context.5, 0);
    assert_eq!(integer(&old.reward_split["installed_native_reward_bps"]), 0);
    let stats = poc_resource(
        &f.client,
        CORE_CODE_ADDRESS,
        "0x1::stake::ValidatorPerformance",
        version - 1,
    )
    .await;
    assert_eq!(
        events(tx, "::stake::PoCRewardCredited").len(),
        old.validators.active_validators.len()
    );
    assert_eq!(
        events(tx, "::stake::PoCRewardSplit").len(),
        old.validators.active_validators.len()
    );
    for pool in &f.pools {
        let before = pool_at(&f.client, *pool, version - 1).await;
        let after = pool_at(&f.client, *pool, version).await;
        let units = if *pool == f.owner.address() {
            target_units
        } else {
            INITIAL_UNITS
        };
        assert_eq!(integer(&before[0]), units);
        let native_before =
            poc_resource(&f.client, *pool, "0x1::stake::StakePool", version - 1).await;
        let native_after = poc_resource(&f.client, *pool, "0x1::stake::StakePool", version).await;
        for balance in ["active", "pending_active", "pending_inactive", "inactive"] {
            assert_eq!(native_after[balance], native_before[balance]);
        }
        if let Some(member) = old
            .validators
            .active_validators
            .iter()
            .find(|member| member.account_address == *pool)
        {
            assert_eq!(member.consensus_voting_power(), 100);
            assert_eq!(integer(&before[2]), 100);
            let perf = &stats["validators"][member.config().validator_index as usize];
            let successful = integer(&perf["successful_proposals"]);
            let total = successful + integer(&perf["failed_proposals"]);
            let reward = if total == 0 {
                0
            } else {
                100 * successful * old.reward_context.2 as u128
                    / (total * old.reward_context.3 as u128)
            };
            let delta = (U256::from(reward).repr() << 128u32) / U256::from(units).repr();
            assert_eq!(integer(&after[3]) - integer(&before[3]), reward);
            assert_eq!(wide(&after[4]).repr() - wide(&before[4]).repr(), delta);
            assert_eq!(
                pool_event(tx, "::stake::PoCRewardCredited", *pool).data,
                json!({"pool": pool.to_hex_literal(), "closing_epoch": old.epoch.to_string(),
                    "reward_base_octa": "100", "inflation": reward.to_string(), "fee": "0",
                    "delta_index": delta.to_string()})
            );
            assert_eq!(
                pool_event(tx, "::stake::PoCRewardSplit", *pool).data,
                json!({"pool": pool.to_hex_literal(), "closing_epoch": old.epoch.to_string(), "native_reward_bps": "0",
                    "total_inflation_octa": reward.to_string(), "active_native_reward_octa": "0",
                    "pending_inactive_native_reward_octa": "0", "poc_inflation_octa": reward.to_string()})
            );
            assert_eq!(
                integer(&ledger_at(&f.client, *pool, version).await["reward_epoch"]),
                old.epoch as u128
            );
        } else {
            assert_eq!(*pool, f.owner.address());
            assert_eq!(units, 0);
            assert_eq!(integer(&before[2]), 0);
            assert_eq!(after[3], before[3]);
            assert_eq!(after[4], before[4]);
        }
    }
}

#[tokio::test]
async fn poc_current_capacity_rejects_next_epoch_then_rebuilds_large_two_boundary_chain() {
    let half = poc_units(REBUILD_RAW, 23);
    let next = poc_units(REBUILD_RAW, 24);
    let filler = poc_units(512, 23);
    assert_eq!(half, CAPACITY / 2 - (1 << 63));
    assert_eq!(next, 2 * half);
    assert_eq!(filler, INITIAL_UNITS);
    assert_eq!(2 * half + filler, CAPACITY);
    assert!(next < CAPACITY);
    assert_eq!(poc_aggregate_power(CAPACITY, 23), 1u128 << 65);
    // 合法写入口只安排 E+1 或 B 的变化，并在写入时检查整条最终链；
    // 因此无法通过公开交易构造 current > C。本例验证 current=C 时
    // E+1=C+G 的拒绝，不把损坏状态注入测试算作真实节点覆盖。
    println!("NUM-02 覆盖说明：C=2^120，G=2^64；通过公开入口构造 current=C，再拒绝 E+1=C+G。本例不覆盖 current>C；合法公开入口无法构造该损坏状态，须在隔离测试中注入。");
    println!("Capacity rebuild fixture overrides: reuse five-validator A fixture, public power length60->1 then1->5 at E82; P23=E83..87 and B88=P24; uploader O also supplies raw512/full allocation; native0/fee_limit0, no positive native-reward coverage");
    let f = poc_fixture().await;
    let target = f.owner.address();
    let participants = [
        target,
        f.users[0].address(),
        f.users[1].address(),
        f.uploader.address(),
    ];
    let retired_epoch = poc_prepare_empty_pool(&f).await;
    let checkpoints = [retired_epoch, 83, 84, 85, 86, 87, REBUILD_BOUNDARY];
    // O 的上传权限和出资角色在此算术用例中复用；权限隔离另有专门矩阵。
    let allocated = poc_rebuild_allocate(&f, &f.uploader, Some(10_000))
        .await
        .info
        .version
        .0;
    assert!(poc_raw_power(&f.client, f.uploader.address(), allocated)
        .await
        .is_none());
    let empty = poc_position(&f.client, f.uploader.address(), target, allocated).await;
    assert_eq!(integer(&empty["units"]), 0);
    assert_eq!(empty["changes"], json!([]));
    let started = Instant::now();
    timeout(Duration::from_secs(300), async {
        loop {
            let installed = installed_at(&f.client, poc_version(&f).await).await;
            assert!(installed.epoch <= 82);
            if installed.epoch == 82 {
                break;
            }
            poc_commit_with_model(&f, 4, 1, poc_rebuild_clock_model).await;
        }
    })
    .await
    .expect("Public epoch preparation to E82 exceeded 300 seconds");
    println!(
        "Prepared capacity rebuild E82/P22 in {:?}",
        started.elapsed()
    );
    let length = poc_govern(&f, 2, 5).await.info.version.0;
    assert_eq!(
        installed_at(&f.client, length - 1).await,
        installed_at(&f.client, length).await
    );
    poc_assert_clock_with_model(&f.client, length, 82, 5, poc_rebuild_clock_model).await;
    let staged = poc_rebuild_upload(&f, 23, &[
        (f.users[0].address(), REBUILD_RAW),
        (f.users[1].address(), REBUILD_RAW),
        (f.uploader.address(), 512),
    ])
    .await
    .info
    .version
    .0;
    for (user, raw, units) in [
        (f.users[0].address(), REBUILD_RAW, half),
        (f.users[1].address(), REBUILD_RAW, half),
        (f.uploader.address(), 512, filler),
    ] {
        assert_eq!(
            poc_raw_power(&f.client, user, staged).await.unwrap(),
            json!({"older": {"vec": []}, "newer": {"vec": [{"effective_period": "23",
                "power": raw.to_string(), "units": units.to_string()}]}})
        );
        let position = poc_position(&f.client, user, target, staged).await;
        assert_eq!(integer(&position["units"]), 0);
        assert_eq!(
            position["changes"],
            json!([{"epoch": "83", "units": units.to_string()}])
        );
    }
    poc_rebuild_horizon(&f, staged, 82, [0, CAPACITY, CAPACITY], 0).await;
    assert_eq!(
        ledger_at(&f.client, target, staged).await["changes"],
        json!([{"epoch": "83", "remove_units": "0", "add_units": CAPACITY.to_string(), "refs": "3"}])
    );
    let joined = success(
        execute(
            &f.client,
            &f.owner,
            &f.factory,
            aptos_stdlib::stake_join_validator_set(target),
        )
        .await,
    );
    let queued = installed_at(&f.client, joined.info.version.0).await;
    assert_eq!(queued.validators.active_validators.len(), 4);
    assert_eq!(queued.validators.pending_active.len(), 1);
    assert_eq!(queued.validators.pending_active[0].account_address, target);
    assert_eq!(
        queued.validators.pending_active[0].consensus_voting_power(),
        0
    );
    assert_eq!(queued.validators.total_joining_power, 0);
    assert_eq!(queued.validators.total_voting_power, 400);
    let at_83 = poc_commit_with_model(&f, 5, 5, poc_rebuild_clock_model).await;
    poc_rebuild_rewards(&f, &at_83, 0).await;
    let v83 = at_83.info.version.0;
    poc_rebuild_horizon(&f, v83, 83, [CAPACITY; 3], 100).await;
    assert_eq!(
        ledger_at(&f.client, target, v83).await["changes"],
        json!([])
    );
    poc_rebuild_refs(&f, v83, &[
        (retired_epoch, Some(1)),
        (83, Some(3)),
        (84, None),
    ])
    .await;
    let original_checkpoint = checkpoint_at(&f.client, target, retired_epoch, v83)
        .await
        .unwrap();
    let original_owner = poc_position(&f.client, target, target, v83).await;
    assert_eq!(integer(&original_owner["units"]), INITIAL_UNITS);
    assert_eq!(
        original_owner["changes"],
        json!([{"epoch": retired_epoch.to_string(), "units": "0"}])
    );
    let owner_payload = aptos_stdlib::poc_allocation_set_allocations(vec![target], vec![10_000]);
    let rejected = execute(&f.client, &f.owner, &f.factory, owner_payload).await;
    let failed = rejected.info.version.0;
    assert_abort(
        &f.client,
        &rejected,
        "poc_accounting",
        0x20008,
        &participants,
        &f.pools,
    )
    .await;
    assert_payment(&f.client, &rejected, 0).await;
    assert_eq!(
        poc_snapshot_at(&f, &f.client, failed - 1, &participants, &checkpoints).await,
        poc_snapshot_at(&f, &f.client, failed, &participants, &checkpoints).await
    );
    assert_eq!(
        poc_position(&f.client, target, target, failed).await,
        original_owner
    );
    assert_eq!(
        checkpoint_at(&f.client, target, retired_epoch, failed).await,
        Some(original_checkpoint.clone())
    );
    poc_rebuild_horizon(&f, failed, 83, [CAPACITY; 3], 100).await;
    println!("Full current pool rejects owner allocation: E83={CAPACITY}, proposed E84={} and B88={}; poc_accounting/0x20008; raw versions, positions, refs, business writes/events unchanged", CAPACITY + INITIAL_UNITS, CAPACITY + INITIAL_UNITS);

    // 先原样提交一次，证明失败没有破坏已合法的目标；此时尚未释放 O。
    let at_84 = poc_commit_with_model(&f, 5, 5, poc_rebuild_clock_model).await;
    poc_rebuild_rewards(&f, &at_84, CAPACITY).await;
    let v84 = at_84.info.version.0;
    poc_rebuild_horizon(&f, v84, 84, [CAPACITY; 3], 100).await;
    poc_rebuild_refs(&f, v84, &[
        (retired_epoch, Some(1)),
        (83, Some(3)),
        (84, None),
    ])
    .await;
    let released = poc_rebuild_allocate(&f, &f.uploader, None)
        .await
        .info
        .version
        .0;
    poc_rebuild_horizon(
        &f,
        released,
        84,
        [CAPACITY, CAPACITY - filler, CAPACITY - filler],
        100,
    )
    .await;
    assert_eq!(
        ledger_at(&f.client, target, released).await["changes"],
        json!([{"epoch": "85", "remove_units": filler.to_string(), "add_units": "0", "refs": "1"}])
    );
    poc_rebuild_refs(&f, released, &[
        (retired_epoch, Some(1)),
        (83, Some(2)),
        (85, None),
    ])
    .await;
    let retried = poc_rebuild_allocate(&f, &f.owner, Some(10_000)).await;
    assert_eq!(retried.request.payload, rejected.request.payload);
    let restored = retried.info.version.0;
    poc_rebuild_horizon(&f, restored, 84, [CAPACITY; 3], 100).await;
    assert_eq!(
        ledger_at(&f.client, target, restored).await["changes"],
        json!([{"epoch": "85", "remove_units": filler.to_string(), "add_units": INITIAL_UNITS.to_string(), "refs": "2"}])
    );
    poc_rebuild_refs(&f, restored, &[
        (retired_epoch, None),
        (83, Some(2)),
        (85, None),
    ])
    .await;
    let at_85 = poc_commit_with_model(&f, 5, 5, poc_rebuild_clock_model).await;
    poc_rebuild_rewards(&f, &at_85, CAPACITY).await;
    let v85 = at_85.info.version.0;
    poc_rebuild_horizon(&f, v85, 85, [CAPACITY; 3], 100).await;
    poc_rebuild_refs(&f, v85, &[
        (retired_epoch, None),
        (83, Some(2)),
        (85, Some(2)),
    ])
    .await;
    let checkpoint_85 = checkpoint_at(&f.client, target, 85, v85).await.unwrap();
    assert_eq!(
        checkpoint_85["index"],
        ledger_at(&f.client, target, v85).await["index"]
    );
    assert_eq!(
        ledger_at(&f.client, target, v85).await["changes"],
        json!([])
    );
    for (user, units) in [
        (target, INITIAL_UNITS),
        (f.users[0].address(), half),
        (f.users[1].address(), half),
        (f.uploader.address(), 0),
    ] {
        let logical = position_at(&f.client, user, target, v85).await;
        assert_eq!(integer(&logical[0]), units);
        assert_eq!(logical[1], json!([]));
    }

    // 先将 U1 改为 5000 bps，再公开上传 P24，使其旧链为 H -> H/2 -> H。
    // 两段撤销之间的临时预测会达到 C+H/2，但完整新链始终不超过 C。
    let ratio_half = poc_rebuild_allocate(&f, &f.users[0], Some(5000))
        .await
        .info
        .version
        .0;
    poc_rebuild_horizon(
        &f,
        ratio_half,
        85,
        [CAPACITY, CAPACITY - half / 2, CAPACITY - half / 2],
        100,
    )
    .await;
    poc_rebuild_refs(&f, ratio_half, &[
        (83, Some(1)),
        (85, Some(2)),
        (86, None),
        (REBUILD_BOUNDARY, None),
    ])
    .await;
    let updated = poc_rebuild_upload(&f, 24, &[(f.users[0].address(), REBUILD_RAW)])
        .await
        .info
        .version
        .0;
    let two_versions = json!({"older": {"vec": [{"effective_period": "23", "power": REBUILD_RAW.to_string(), "units": half.to_string()}]},
        "newer": {"vec": [{"effective_period": "24", "power": REBUILD_RAW.to_string(), "units": next.to_string()}]}});
    assert_eq!(
        poc_raw_power(&f.client, f.users[0].address(), updated).await,
        Some(two_versions.clone())
    );
    poc_rebuild_horizon(
        &f,
        updated,
        85,
        [CAPACITY, CAPACITY - half / 2, CAPACITY],
        100,
    )
    .await;
    let old_chain = poc_position(&f.client, f.users[0].address(), target, updated).await;
    assert_eq!(integer(&old_chain["units"]), half);
    assert_eq!(
        old_chain["changes"],
        json!([
            {"epoch": "86", "units": (half / 2).to_string()},
            {"epoch": "88", "units": half.to_string()}
        ])
    );
    assert_eq!(
        ledger_at(&f.client, target, updated).await["changes"],
        json!([
            {"epoch": "86", "remove_units": half.to_string(), "add_units": (half / 2).to_string(), "refs": "1"},
            {"epoch": "88", "remove_units": (half / 2).to_string(), "add_units": half.to_string(), "refs": "1"}
        ])
    );
    assert!(CAPACITY + half / 2 > CAPACITY);
    let covered = poc_rebuild_allocate(&f, &f.users[0], Some(2500))
        .await
        .info
        .version
        .0;
    let first_total = CAPACITY - 3 * half / 4;
    let boundary_total = CAPACITY - half / 2;
    poc_rebuild_horizon(
        &f,
        covered,
        85,
        [CAPACITY, first_total, boundary_total],
        100,
    )
    .await;
    assert_eq!(
        poc_raw_power(&f.client, f.users[0].address(), covered).await,
        Some(two_versions.clone())
    );
    let new_chain = poc_position(&f.client, f.users[0].address(), target, covered).await;
    assert_eq!(integer(&new_chain["units"]), half);
    assert_eq!(new_chain["cursor"], old_chain["cursor"]);
    assert_eq!(new_chain["accrued"], old_chain["accrued"]);
    assert_eq!(
        new_chain["changes"],
        json!([
            {"epoch": "86", "units": (half / 4).to_string()},
            {"epoch": "88", "units": (half / 2).to_string()}
        ])
    );
    assert_eq!(
        ledger_at(&f.client, target, covered).await["changes"],
        json!([
            {"epoch": "86", "remove_units": half.to_string(), "add_units": (half / 4).to_string(), "refs": "1"},
            {"epoch": "88", "remove_units": (half / 4).to_string(), "add_units": (half / 2).to_string(), "refs": "1"}
        ])
    );
    assert_eq!(
        view(
            &f.client,
            "0x1::poc_accounting::get_allocations",
            vec![json!(f.users[0].address())],
            covered
        )
        .await,
        vec![
            json!([{"pool": target.to_hex_literal(), "bps": "10000"}]),
            json!({"vec": [{"epoch": "86", "ratios": [{"pool": target.to_hex_literal(), "bps": "2500"}]}]})
        ]
    );
    poc_rebuild_refs(&f, covered, &[
        (retired_epoch, None),
        (83, Some(1)),
        (85, Some(2)),
        (86, None),
        (REBUILD_BOUNDARY, None),
    ])
    .await;
    println!("Large chain replacement accepted: U1 H={half}, P24 units={next}, old5000 H->H/2->H, new2500 H->H/4->H/2; partial-cancel intermediate={} exceeds C, final E86={first_total}, B88={boundary_total}; exactly two refs remain", CAPACITY + half / 2);

    let mut completed = covered;
    for epoch in [86, 87, REBUILD_BOUNDARY] {
        let tx = poc_commit_with_model(&f, 5, 5, poc_rebuild_clock_model).await;
        poc_rebuild_rewards(&f, &tx, if epoch == 86 { CAPACITY } else { first_total }).await;
        completed = tx.info.version.0;
        let current = if epoch < REBUILD_BOUNDARY {
            first_total
        } else {
            boundary_total
        };
        let next_total = if epoch + 1 < REBUILD_BOUNDARY {
            first_total
        } else {
            boundary_total
        };
        poc_rebuild_horizon(
            &f,
            completed,
            epoch,
            [current, next_total, boundary_total],
            100,
        )
        .await;
        poc_rebuild_refs(&f, completed, &[
            (retired_epoch, None),
            (83, Some(1)),
            (84, None),
            (85, Some(2)),
            (86, Some(1)),
            (87, None),
            (
                REBUILD_BOUNDARY,
                if epoch == REBUILD_BOUNDARY {
                    Some(1)
                } else {
                    None
                },
            ),
        ])
        .await;
        if epoch == 86 || epoch == REBUILD_BOUNDARY {
            let checkpoint = checkpoint_at(&f.client, target, epoch, completed)
                .await
                .unwrap();
            assert_eq!(
                checkpoint["index"],
                ledger_at(&f.client, target, completed).await["index"]
            );
        }
    }
    assert_eq!(
        ledger_at(&f.client, target, completed).await["changes"],
        json!([])
    );
    assert_eq!(
        poc_position(&f.client, f.users[0].address(), target, completed).await,
        new_chain
    );
    assert_eq!(
        poc_raw_power(&f.client, f.users[0].address(), completed).await,
        Some(two_versions)
    );
    let mut logical_total = 0;
    for (user, units) in [
        (target, INITIAL_UNITS),
        (f.users[0].address(), half / 2),
        (f.users[1].address(), half),
        (f.uploader.address(), 0),
    ] {
        let logical = position_at(&f.client, user, target, completed).await;
        assert_eq!(integer(&logical[0]), units);
        assert_eq!(logical[1], json!([]));
        logical_total += units;
    }
    assert_eq!(logical_total, boundary_total);
    // 只读逻辑持仓查询不会主动写回成熟变化，也不会消耗历史 refs。
    poc_rebuild_refs(&f, completed, &[
        (83, Some(1)),
        (85, Some(2)),
        (86, Some(1)),
        (REBUILD_BOUNDARY, Some(1)),
    ])
    .await;
    let installed = installed_at(&f.client, completed).await;
    assert_eq!(installed.epoch, REBUILD_BOUNDARY);
    let target_index = installed
        .validators
        .active_validators
        .iter()
        .find(|member| member.account_address == target)
        .unwrap()
        .config()
        .validator_index as usize;
    timeout(Duration::from_secs(90), async {
        loop {
            let version = poc_version(&f).await;
            assert_eq!(installed_at(&f.client, version).await, installed);
            let stats = poc_resource(
                &f.client,
                CORE_CODE_ADDRESS,
                "0x1::stake::ValidatorPerformance",
                version,
            )
            .await;
            if integer(&stats["validators"][target_index]["successful_proposals"]) > 0 {
                break;
            }
            success(
                execute(
                    &f.client,
                    &f.root,
                    &f.factory,
                    aptos_stdlib::topo_coin_transfer(f.pools[1], 1),
                )
                .await,
            );
        }
    })
    .await
    .expect("Rejoined target did not propose in E88 within 90 seconds");
    let progress = success(
        execute(
            &f.client,
            &f.root,
            &f.factory,
            aptos_stdlib::topo_coin_transfer(f.pools[1], 1),
        )
        .await,
    );
    let same_version = progress.info.version.0;
    assert!(same_version > completed);
    let snapshot = poc_snapshot_at(&f, &f.client, same_version, &participants, &checkpoints).await;
    assert_eq!(snapshot.installed, installed);
    for node in f.swarm.validators() {
        assert!(installed
            .validators
            .active_validators
            .iter()
            .any(|member| member.account_address == node.peer_id()));
        let client = node.rest_client_with_timeout(Duration::from_secs(10));
        timeout(
            Duration::from_secs(30),
            client.wait_for_version(same_version),
        )
        .await
        .expect("Current member catchup exceeded 30 seconds")
        .unwrap();
        assert_eq!(
            poc_snapshot_at(&f, &client, same_version, &participants, &checkpoints).await,
            snapshot
        );
        poc_assert_clock_with_model(
            &client,
            same_version,
            REBUILD_BOUNDARY,
            5,
            poc_rebuild_clock_model,
        )
        .await;
        for user in participants {
            assert_eq!(
                position_at(&client, user, target, same_version).await,
                position_at(&f.client, user, target, same_version).await
            );
        }
    }
    println!("Capacity rebuild completed: unchanged state committed after rejection; releasing O allowed the identical owner payload; E85 current=C; 5000->2500 rebuilt both large boundaries without transient-capacity rejection; E88 current={boundary_total}, checkpoints refs83=1/85=2/86=1/88=1, target proposed and five current nodes agree at version={same_version}");
}
