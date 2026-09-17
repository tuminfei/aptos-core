// Copyright (c) Aptos Foundation
// Licensed pursuant to the Innovation-Enabling Source Code License, available at https://github.com/aptos-labs/aptos-core/blob/main/LICENSE

//! 真实节点覆盖默认首次算力边界、零版本及版本滚动后的历史权益。
//! 本文件使用显式四节点同步测试网 PoC 参数变体，不作为严格 T2 验收。

use super::{
    defaults::installed_at,
    fee_rewards::{
        assert_payment, checkpoint_at, events, ledger_at, pool_at, pool_event, position_at,
        success, wide,
    },
    optional_resource_at_version, resource_at_version,
    transactions::{assert_abort, compile_script, execute},
};
use crate::smoke_test_environment::SwarmBuilder;
use aptos_api_types::{Event, UserTransaction, ViewRequest, WriteSetChange};
use aptos_cached_packages::aptos_stdlib;
use aptos_forge::{LocalSwarm, NodeExt, Swarm, SwarmExt};
use aptos_genesis::poc::PocGenesisConfiguration;
use aptos_rest_client::Client;
use aptos_sdk::{transaction_builder::TransactionFactory, types::LocalAccount};
use aptos_types::{
    account_address::AccountAddress,
    account_config::CORE_CODE_ADDRESS,
    on_chain_config::{
        ConfigurationResource, OnChainChunkyDKGConfig, OnChainRandomnessConfig, ValidatorSet,
    },
    transaction::{Script, TransactionArgument, TransactionPayload},
};
use move_core_types::int256::U256;
use once_cell::sync::Lazy;
use serde_json::{json, Value};
use std::{
    collections::{BTreeMap, BTreeSet},
    sync::Arc,
    time::Duration,
};
use tokio::time::{sleep, timeout};

const OHMP: u64 = 100_000_000;
const S: u128 = 1 << 32;
const J: u128 = 1 << 64;
const OWNER_UNITS: u128 = OHMP as u128 * S;
// 生命周期用例会连续跨越大量 Epoch；长时间运行或主机休眠后，
// 尚未提交的治理交易仍须保持有效，避免恢复时被内存池按客户端过期清除。
const LIFECYCLE_TRANSACTION_EXPIRATION_SECS: u64 = 24 * 60 * 60;

static LIFECYCLE_SCRIPT: Lazy<Vec<u8>> = Lazy::new(|| {
    compile_script(
        "PoCPowerLifecycle",
        r#"
script {
    use topo_framework::poc_power_store;
    use topo_framework::reconfiguration;
    use topo_framework::stake;
    use topo_framework::topo_governance;

    fun main(root: &signer, operation: u8, period: u64, user: address, value: u64) {
        let framework = topo_governance::get_signer_testnet_only(root, @0x1);
        if (operation == 0 || operation == 4) {
            if (operation == 4) {
                // 验证非法周期也会回滚前面已经执行的合法写入和事件。
                stake::schedule_reward_split(&framework, 6000, reconfiguration::current_epoch() + 1);
            };
            poc_power_store::set_power_period_in_epochs(&framework, value);
        } else if (operation == 1 || operation == 3) {
            if (operation == 3) {
                // 后续非法上传必须回滚这次合法写入及其事件。
                stake::schedule_reward_split(&framework, 6000, reconfiguration::current_epoch() + 1);
            };
            poc_power_store::stage_batch_update(&framework, period, vector[user], vector[value]);
        } else {
            assert!(operation == 2, 0);
            // 普通治理入口。本 fixture 关闭两种 DKG 模式，因此生产同步换届提交一个 Epoch。
            topo_governance::reconfigure(&framework);
        };
    }
}
"#,
    )
});

enum Action {
    PeriodLength(u64),
    InvalidPeriodLength(u64),
    Upload {
        period: u64,
        user: AccountAddress,
        power: u64,
    },
    Advance,
    PastUpload {
        period: u64,
        user: AccountAddress,
    },
}

fn governance_payload(action: Action) -> TransactionPayload {
    let (operation, period, user, value) = match action {
        Action::PeriodLength(length) => (0, 0, CORE_CODE_ADDRESS, length),
        Action::InvalidPeriodLength(length) => (4, 0, CORE_CODE_ADDRESS, length),
        Action::Upload {
            period,
            user,
            power,
        } => (1, period, user, power),
        Action::Advance => (2, 0, CORE_CODE_ADDRESS, 0),
        Action::PastUpload { period, user } => (3, period, user, OHMP),
    };
    TransactionPayload::Script(Script::new(LIFECYCLE_SCRIPT.clone(), vec![], vec![
        TransactionArgument::U8(operation),
        TransactionArgument::U64(period),
        TransactionArgument::Address(user),
        TransactionArgument::U64(value),
    ]))
}

async fn lifecycle_swarm() -> LocalSwarm {
    println!("Power lifecycle fixture: 4 nodes, testnet PoC Controlled/minimum=2/capacity=128, each owner=1 OHMP/1 TOPO, growth=50%, APY=10%, epoch=3600s, ordinary/Chunky DKG=off, retention=9995, native_bps=3000, initial power period=60, fee_limit=0");
    SwarmBuilder::new_local(4)
        .with_aptos()
        .with_init_genesis_stake(Arc::new(|_, amount| *amount = OHMP))
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
        .await
}

fn integer(value: &Value) -> u128 {
    value.as_str().unwrap().parse().unwrap()
}

fn address(value: &Value) -> AccountAddress {
    AccountAddress::from_hex_literal(value.as_str().unwrap()).unwrap()
}

fn event<'a>(transaction: &'a UserTransaction, suffix: &str) -> &'a Event {
    let events = transaction
        .events
        .iter()
        .filter(|event| event.typ.to_string().ends_with(suffix))
        .collect::<Vec<_>>();
    assert_eq!(events.len(), 1, "Expected exactly one {suffix}");
    events[0]
}

async fn view_at(
    client: &Client,
    function: &str,
    arguments: Vec<Value>,
    version: u64,
) -> Vec<Value> {
    client
        .view(
            &ViewRequest {
                function: function.parse().unwrap(),
                type_arguments: vec![],
                arguments,
            },
            Some(version),
        )
        .await
        .unwrap()
        .into_inner()
}

async fn resource_at(
    client: &Client,
    owner: AccountAddress,
    resource: &str,
    version: u64,
) -> Value {
    optional_resource_at_version(client, owner, resource, version)
        .await
        .unwrap()
        .data
}

fn index_at(period: u64) -> u128 {
    (0..period).fold(J, |index, _| index * 9995 / 10000)
}

fn units_at(raw: u64, period: u64) -> u128 {
    // 这些场景的输入最大为 6 OHMP，因此乘积可安全存入 u128。
    raw as u128 * S * J / index_at(period)
}

fn period_at(epoch: u64) -> u64 {
    if epoch < 61 {
        0
    } else {
        1 + (epoch - 61) / 2
    }
}

async fn assert_clock(client: &Client, version: u64, epoch: u64) {
    let period = period_at(epoch);
    let boundary = if period == 0 { 61 } else { 61 + period * 2 };
    assert_eq!(
        view_at(
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
            json!(index_at(period).to_string()),
            json!({"vec": [index_at(period + 1).to_string()]}),
            json!("10000")
        ],
    );
}

/// 独立权益模型：以已提交的 PoC 入账金额作为账本输入，根据各周期已知持仓计算用户精确份额。
/// 本模型验证指数取整和历史归属，不验证通胀公式。
struct EntitlementModel {
    pool: AccountAddress,
    versions: BTreeMap<u64, u128>,
    credited_epochs: BTreeSet<u64>,
    accrued: U256,
}

impl EntitlementModel {
    fn new(pool: AccountAddress) -> Self {
        Self {
            pool,
            versions: BTreeMap::new(),
            credited_epochs: BTreeSet::new(),
            accrued: U256::ZERO,
        }
    }

    fn units(&self, period: u64) -> u128 {
        self.versions
            .range(..=period)
            .next_back()
            .map(|(_, units)| *units)
            .unwrap_or(0)
    }

    fn credit(&mut self, transaction: &UserTransaction, closing_epoch: u64) {
        let credits = transaction
            .events
            .iter()
            .filter(|event| {
                event
                    .typ
                    .to_string()
                    .ends_with("::stake::PoCRewardCredited")
                    && address(&event.data["pool"]) == self.pool
            })
            .collect::<Vec<_>>();
        assert_eq!(credits.len(), 1);
        let credit = credits[0];
        assert_eq!(
            integer(&credit.data["closing_epoch"]),
            closing_epoch as u128
        );
        assert!(
            self.credited_epochs.insert(closing_epoch),
            "Repeated epoch credit"
        );
        assert_eq!(integer(&credit.data["fee"]), 0);
        let amount = integer(&credit.data["inflation"]);
        let user_units = self.units(period_at(closing_epoch));
        let total_units = OWNER_UNITS + user_units;
        let q = U256::ONE << U256::from(128_u8);
        let delta = U256::checked_div(
            U256::checked_mul(U256::from(amount), q).unwrap(),
            U256::from(total_units),
        )
        .unwrap();
        assert_eq!(
            credit.data["delta_index"]
                .as_str()
                .unwrap()
                .parse::<U256>()
                .unwrap(),
            delta
        );
        self.accrued = U256::checked_add(
            self.accrued,
            U256::checked_mul(U256::from(user_units), delta).unwrap(),
        )
        .unwrap();
    }

    fn claim(&self) -> u64 {
        u64::try_from(U256::checked_div(self.accrued, U256::ONE << U256::from(128_u8)).unwrap())
            .unwrap()
    }

    fn remainder(&self) -> U256 {
        U256::checked_rem(self.accrued, U256::ONE << U256::from(128_u8)).unwrap()
    }
}

async fn governance(
    client: &Client,
    root: &LocalAccount,
    factory: &TransactionFactory,
    action: Action,
) -> UserTransaction {
    let transaction = execute(client, root, factory, governance_payload(action)).await;
    assert!(transaction.info.success, "{}", transaction.info.vm_status);
    transaction
}

async fn advance_to(
    client: &Client,
    root: &LocalAccount,
    factory: &TransactionFactory,
    model: &mut EntitlementModel,
    target: u64,
) -> u64 {
    let initial = client.get_ledger_information().await.unwrap().into_inner();
    // 换届 LedgerInfo 由旧委员会签名，仍可能报告旧 Epoch；因此以同一版本的已安装资源驱动执行。
    let mut epoch = resource_at_version::<ConfigurationResource>(client, initial.version)
        .await
        .epoch();
    let mut version = initial.version;
    assert!(epoch <= target);
    if let Some(last_credited) = model.credited_epochs.last() {
        assert_eq!(
            epoch,
            last_credited + 1,
            "Installed epoch moved without a modeled credit"
        );
    }
    println!("Power lifecycle advance: version={}, ledger_epoch={}, installed_epoch={epoch}, target={target}", initial.version, initial.epoch);
    while epoch < target {
        let transaction = governance(client, root, factory, Action::Advance).await;
        version = transaction.info.version.0;
        let closing_epoch = resource_at_version::<ConfigurationResource>(client, version - 1)
            .await
            .epoch();
        let installed_epoch = resource_at_version::<ConfigurationResource>(client, version)
            .await
            .epoch();
        assert_eq!(
            closing_epoch, epoch,
            "Unexpected epoch before governance transaction {version}"
        );
        assert_eq!(
            installed_epoch,
            closing_epoch + 1,
            "Governance transaction {version} must advance exactly one epoch"
        );
        let installed = event(&transaction, "::stake::PoCEpochInstalled");
        assert_eq!(integer(&installed.data["epoch"]), installed_epoch as u128);
        assert_eq!(integer(&installed.data["selected_count"]), 4);
        assert_eq!(
            integer(&event(&transaction, "::reconfiguration::NewEpochEvent").data["epoch"]),
            installed_epoch as u128
        );
        model.credit(&transaction, closing_epoch);
        epoch = installed_epoch;
        assert_clock(client, version, epoch).await;
        if epoch == 60 {
            let validators = resource_at_version::<ValidatorSet>(client, version).await;
            assert!(validators
                .active_validators
                .iter()
                .all(|validator| validator.consensus_voting_power() == OHMP));
        }
    }
    version
}

async fn upload(
    client: &Client,
    root: &LocalAccount,
    factory: &TransactionFactory,
    user: AccountAddress,
    model: &mut EntitlementModel,
    period: u64,
    raw: u64,
) -> u64 {
    let transaction = governance(client, root, factory, Action::Upload {
        period,
        user,
        power: raw,
    })
    .await;
    let units = units_at(raw, period);
    assert!(model.versions.insert(period, units).is_none());
    let normalized = event(&transaction, "::poc_power_store::PowerNormalized");
    assert_eq!(address(&normalized.data["user"]), user);
    assert_eq!(
        integer(&normalized.data["effective_period"]),
        period as u128
    );
    assert_eq!(integer(&normalized.data["units"]), units);
    let staged = event(&transaction, "::poc_power_store::PowerUpdateStagedEvent");
    assert_eq!(integer(&staged.data["target_period"]), period as u128);
    assert_eq!(integer(&staged.data["power"]), raw as u128);
    transaction.info.version.0
}

async fn raw_version(client: &Client, user: AccountAddress, version: u64) -> Value {
    let store = resource_at(
        client,
        CORE_CODE_ADDRESS,
        "0x1::poc_power_store::PowerStore",
        version,
    )
    .await;
    client
        .get_table_item_at_version(
            address(&store["users"]["handle"]),
            "address",
            "0x1::poc_power_store::UserPowerInfo",
            user.to_hex_literal(),
            version,
        )
        .await
        .unwrap()
        .into_inner()
}

async fn raw_position(
    client: &Client,
    user: AccountAddress,
    pool: AccountAddress,
    version: u64,
) -> Value {
    let allocation =
        resource_at(client, user, "0x1::poc_accounting::UserAllocation", version).await;
    client
        .get_table_item_at_version(
            address(&allocation["positions"]["handle"]),
            "address",
            "0x1::poc_accounting::Position",
            pool.to_hex_literal(),
            version,
        )
        .await
        .unwrap()
        .into_inner()
}

async fn assert_window(
    client: &Client,
    user: AccountAddress,
    version: u64,
    older: (u64, u64),
    newer: (u64, u64),
) {
    let expected = |(period, raw): (u64, u64)| json!({"effective_period": period.to_string(), "power": raw.to_string(), "units": units_at(raw, period).to_string()});
    assert_eq!(
        raw_version(client, user, version).await,
        json!({"older": {"vec": [expected(older)]}, "newer": {"vec": [expected(newer)]}})
    );
}

/// 在用户首次写入零版本前，通过真实成功提案形成确定的非零历史。
/// 测试不注入表现数据，也不直接修改奖励。
async fn wait_for_pool_proposal(client: &Client, pool: AccountAddress, epoch: u64) {
    timeout(Duration::from_secs(30), async {
        loop {
            let ledger = client.get_ledger_information().await.unwrap().into_inner();
            assert_eq!(
                resource_at_version::<ConfigurationResource>(client, ledger.version)
                    .await
                    .epoch(),
                epoch
            );
            let validators = resource_at_version::<ValidatorSet>(client, ledger.version).await;
            let index = validators
                .active_validators
                .iter()
                .find(|validator| validator.account_address == pool)
                .unwrap()
                .config()
                .validator_index as usize;
            let performance = resource_at(
                client,
                CORE_CODE_ADDRESS,
                "0x1::stake::ValidatorPerformance",
                ledger.version,
            )
            .await;
            if integer(&performance["validators"][index]["successful_proposals"]) > 0 {
                break;
            }
            sleep(Duration::from_millis(250)).await;
        }
    })
    .await
    .expect("Power lifecycle pool did not propose within 30 seconds");
}

async fn assert_paid(
    client: &Client,
    transaction: &UserTransaction,
    user: AccountAddress,
    amount: u64,
) {
    let version = transaction.info.version.0;
    let before = client
        .view_apt_account_balance_at_version(user, version - 1)
        .await
        .unwrap()
        .into_inner();
    let after = client
        .view_apt_account_balance_at_version(user, version)
        .await
        .unwrap()
        .into_inner();
    let fee = event(transaction, "::transaction_fee::FeeStatement");
    let refund = integer(&fee.data["storage_fee_refund_octas"]);
    let gas = transaction.info.gas_used.0 as u128 * transaction.request.gas_unit_price.0 as u128;
    assert!(gas > 0);
    assert_eq!(
        after as i128 - before as i128,
        amount as i128 + refund as i128 - gas as i128
    );
}

/// PWR-03/04/06/07 和 GOV-02：覆盖真实周期边界、显式零值、两个存储版本及延迟领取。
/// 池退出后领取和非法上传向量由其他用例覆盖；本场景保持所有背景池活跃。
#[tokio::test]
async fn poc_power_period_zero_rollover_and_historical_claim() {
    Lazy::force(&LIFECYCLE_SCRIPT);
    let swarm = lifecycle_swarm().await;
    let pools = swarm
        .validators()
        .map(|node| node.peer_id())
        .collect::<Vec<_>>();
    let pool = pools[0];
    let background = pools[1];
    let client = swarm
        .validator(background)
        .unwrap()
        .rest_client_with_timeout(Duration::from_secs(10));
    let user = swarm
        .chain_info()
        .into_aptos_public_info()
        .create_and_fund_user_account(OHMP)
        .await
        .unwrap();
    let chain = swarm.chain_info();
    let root = chain.root_account();
    let factory = chain
        .transaction_factory()
        .with_gas_unit_price(1)
        .with_max_gas_amount(2_000_000)
        .with_transaction_expiration_time(LIFECYCLE_TRANSACTION_EXPIRATION_SECS);
    let initial = client.get_ledger_information().await.unwrap().into_inner();
    assert!(
        resource_at_version::<ConfigurationResource>(&client, initial.version)
            .await
            .epoch()
            < 60,
        "Lifecycle setup crossed the default first boundary"
    );
    assert_clock(&client, 0, 1).await;
    assert_eq!(
        view_at(
            &client,
            "0x1::poc_power_store::get_power_period_in_epochs",
            vec![],
            0
        )
        .await,
        vec![json!("60")]
    );
    let allocation = execute(
        &client,
        &user,
        &factory,
        aptos_stdlib::poc_allocation_set_allocations(vec![pool], vec![10000]),
    )
    .await;
    assert!(allocation.info.success, "{}", allocation.info.vm_status);
    let mut model = EntitlementModel::new(pool);
    let scheduled_version = upload(
        &client,
        &root,
        &factory,
        user.address(),
        &mut model,
        1,
        OHMP,
    )
    .await;
    let pending_position = view_at(
        &client,
        "0x1::poc_accounting::get_position",
        vec![json!(user.address()), json!(pool)],
        scheduled_version,
    )
    .await;
    assert_eq!(pending_position[0], json!("0"));
    assert_eq!(
        pending_position[1],
        json!([{"epoch": "61", "units": units_at(OHMP, 1).to_string()}])
    );
    let before_clock = view_at(
        &client,
        "0x1::poc_power_store::get_normalization_clock",
        vec![],
        scheduled_version,
    )
    .await;
    // 已经在 B=61 排定真实变化后再修改下一周期长度；时钟边界和已排定变化均不得移动。
    let changed = governance(&client, &root, &factory, Action::PeriodLength(2)).await;
    assert_eq!(
        view_at(
            &client,
            "0x1::poc_power_store::get_normalization_clock",
            vec![],
            changed.info.version.0
        )
        .await,
        before_clock
    );
    assert_eq!(
        view_at(
            &client,
            "0x1::poc_power_store::get_power_period_in_epochs",
            vec![],
            changed.info.version.0
        )
        .await,
        vec![json!("2")]
    );
    assert_eq!(
        view_at(
            &client,
            "0x1::poc_accounting::get_position",
            vec![json!(user.address()), json!(pool)],
            changed.info.version.0
        )
        .await,
        pending_position
    );
    for length in [0, u64::MAX] {
        let denied = execute(
            &client,
            &root,
            &factory,
            governance_payload(Action::InvalidPeriodLength(length)),
        )
        .await;
        assert_abort(
            &client,
            &denied,
            "poc_power_store",
            0x10005,
            &[user.address()],
            &pools,
        )
        .await;
        assert_eq!(
            view_at(
                &client,
                "0x1::poc_power_store::get_normalization_clock",
                vec![],
                denied.info.version.0
            )
            .await,
            before_clock,
            "Rejected period length {length} moved the fixed boundary",
        );
        assert_eq!(
            view_at(
                &client,
                "0x1::poc_power_store::get_power_period_in_epochs",
                vec![],
                denied.info.version.0
            )
            .await,
            vec![json!("2")],
        );
    }
    let boundary = advance_to(&client, &root, &factory, &mut model, 61).await;
    let index = index_at(1);
    assert_eq!(index, 18_437_520_701_672_696_840);
    let expected_power = OWNER_UNITS * index / (S * J);
    assert_eq!(expected_power, 99_949_999);
    // 旧原始算力查询直接对整数做衰减，其展示值刻意与从 units 推导的已安装权重区分。
    assert_eq!(
        view_at(
            &client,
            "0x1::poc_power_store::get_user_committed_power",
            vec![json!(background)],
            boundary
        )
        .await,
        vec![json!("99950000")]
    );
    let installed = installed_at(&client, boundary).await;
    assert_eq!(installed.epoch, 61);
    assert_eq!(
        installed
            .validators
            .active_validators
            .iter()
            .find(|validator| validator.account_address == background)
            .unwrap()
            .consensus_voting_power(),
        expected_power as u64
    );
    assert_eq!(
        view_at(
            &client,
            "0x1::poc_power_store::get_accounting_snapshot",
            vec![json!(background)],
            boundary
        )
        .await,
        vec![
            json!(OWNER_UNITS.to_string()),
            json!(OWNER_UNITS.to_string()),
            json!("1"),
            json!("63")
        ]
    );
    assert_eq!(
        view_at(
            &client,
            "0x1::poc_accounting::get_pool",
            vec![json!(background)],
            boundary
        )
        .await[0],
        json!(OWNER_UNITS.to_string())
    );
    assert_eq!(
        view_at(
            &client,
            "0x1::poc_accounting::get_position",
            vec![json!(user.address()), json!(pool)],
            boundary
        )
        .await[0],
        json!(units_at(OHMP, 1).to_string())
    );

    let zero = upload(&client, &root, &factory, user.address(), &mut model, 2, 0).await;
    assert_window(&client, user.address(), zero, (1, OHMP), (2, 0)).await;
    let invalid = execute(
        &client,
        &root,
        &factory,
        governance_payload(Action::PastUpload {
            period: 0,
            user: user.address(),
        }),
    )
    .await;
    assert_abort(
        &client,
        &invalid,
        "poc_power_store",
        0x10006,
        &[user.address()],
        &pools,
    )
    .await;
    wait_for_pool_proposal(&client, pool, 61).await;
    let zero_effective = advance_to(&client, &root, &factory, &mut model, 63).await;
    assert!(
        model.claim() > 0,
        "The first active period must create nonzero historical entitlement"
    );
    assert_eq!(
        view_at(
            &client,
            "0x1::poc_accounting::get_position",
            vec![json!(user.address()), json!(pool)],
            zero_effective
        )
        .await[0],
        json!("0")
    );

    let third = upload(
        &client,
        &root,
        &factory,
        user.address(),
        &mut model,
        3,
        2 * OHMP,
    )
    .await;
    assert_window(&client, user.address(), third, (2, 0), (3, 2 * OHMP)).await;
    advance_to(&client, &root, &factory, &mut model, 65).await;
    let fourth = upload(
        &client,
        &root,
        &factory,
        user.address(),
        &mut model,
        4,
        3 * OHMP,
    )
    .await;
    assert_window(
        &client,
        user.address(),
        fourth,
        (3, 2 * OHMP),
        (4, 3 * OHMP),
    )
    .await;
    assert_eq!(
        view_at(
            &client,
            "0x1::poc_power_store::get_accounting_snapshot",
            vec![json!(user.address())],
            fourth
        )
        .await,
        vec![
            json!(units_at(2 * OHMP, 3).to_string()),
            json!(units_at(3 * OHMP, 4).to_string()),
            json!("3"),
            json!("67")
        ]
    );
    let inactive = advance_to(&client, &root, &factory, &mut model, 67).await;
    let untouched_position = raw_position(&client, user.address(), pool, inactive).await;
    let untouched_versions = raw_version(&client, user.address(), inactive).await;
    // 该用户连续四个完整算力周期没有上传、分配或领取；其非零 units 必须继续绑定周期 4 的指数。
    let unvisited_version = advance_to(&client, &root, &factory, &mut model, 75).await;
    assert_eq!(
        raw_position(&client, user.address(), pool, unvisited_version).await,
        untouched_position
    );
    assert_eq!(
        raw_version(&client, user.address(), unvisited_version).await,
        untouched_versions
    );
    assert_window(
        &client,
        user.address(),
        unvisited_version,
        (3, 2 * OHMP),
        (4, 3 * OHMP),
    )
    .await;
    assert_eq!(
        view_at(
            &client,
            "0x1::poc_power_store::get_accounting_snapshot",
            vec![json!(user.address())],
            unvisited_version
        )
        .await,
        vec![
            json!(units_at(3 * OHMP, 4).to_string()),
            json!(units_at(3 * OHMP, 4).to_string()),
            json!("8"),
            json!("77")
        ]
    );
    let displayed_user_power = (4..8).fold(3 * OHMP as u128, |power, _| power * 9995 / 10000);
    assert_eq!(
        view_at(
            &client,
            "0x1::poc_power_store::get_user_committed_power",
            vec![json!(user.address())],
            unvisited_version
        )
        .await,
        vec![json!(displayed_user_power.to_string())]
    );

    // 再写入显式零版本并实际领取全部历史分段，包括早已移出双槽的周期 1 原始版本对应权益。
    let zero_again = upload(&client, &root, &factory, user.address(), &mut model, 9, 0).await;
    assert_window(&client, user.address(), zero_again, (4, 3 * OHMP), (9, 0)).await;
    let final_version = advance_to(&client, &root, &factory, &mut model, 77).await;
    assert_eq!(
        view_at(
            &client,
            "0x1::poc_power_store::get_accounting_snapshot",
            vec![json!(user.address())],
            final_version
        )
        .await,
        vec![json!("0"), json!("0"), json!("9"), json!("79")]
    );

    let expected = model.claim();
    let expected_remainder = model.remainder();
    let position = view_at(
        &client,
        "0x1::poc_accounting::get_position",
        vec![json!(user.address()), json!(pool)],
        final_version,
    )
    .await;
    assert_eq!(position, vec![
        json!("0"),
        json!([]),
        json!(expected.to_string()),
        json!(expected_remainder.to_string())
    ]);
    let claim = execute(
        &client,
        &user,
        &factory,
        aptos_stdlib::poc_allocation_claim_rewards(vec![pool]),
    )
    .await;
    assert!(claim.info.success, "{}", claim.info.vm_status);
    let claimed = event(&claim, "::poc_accounting::PoCRewardClaimed");
    assert_eq!(integer(&claimed.data["amount"]), expected as u128);
    assert_eq!(address(&claimed.data["user"]), user.address());
    assert_eq!(address(&claimed.data["pool"]), pool);
    assert_paid(&client, &claim, user.address(), expected).await;
    let claim_version = claim.info.version.0;
    let pool_before = view_at(
        &client,
        "0x1::poc_accounting::get_pool",
        vec![json!(pool)],
        claim_version - 1,
    )
    .await;
    let mut pool_expected = pool_before.clone();
    pool_expected[3] = json!((integer(&pool_before[3]) - expected as u128).to_string());
    assert_eq!(
        view_at(
            &client,
            "0x1::poc_accounting::get_pool",
            vec![json!(pool)],
            claim_version
        )
        .await,
        pool_expected
    );
    assert_eq!(
        resource_at(&client, pool, "0x1::stake::StakePool", claim_version - 1).await,
        resource_at(&client, pool, "0x1::stake::StakePool", claim_version).await
    );
    assert_eq!(
        view_at(
            &client,
            "0x1::poc_accounting::get_position",
            vec![json!(user.address()), json!(pool)],
            claim_version
        )
        .await,
        vec![
            json!("0"),
            json!([]),
            json!("0"),
            json!(expected_remainder.to_string())
        ]
    );

    let repeat = execute(
        &client,
        &user,
        &factory,
        aptos_stdlib::poc_allocation_claim_rewards(vec![pool]),
    )
    .await;
    assert!(repeat.info.success, "{}", repeat.info.vm_status);
    assert!(repeat.events.iter().all(|event| !event
        .typ
        .to_string()
        .ends_with("::poc_accounting::PoCRewardClaimed")));
    assert_paid(&client, &repeat, user.address(), 0).await;
    assert_eq!(
        view_at(
            &client,
            "0x1::poc_accounting::get_position",
            vec![json!(user.address()), json!(pool)],
            repeat.info.version.0
        )
        .await,
        vec![
            json!("0"),
            json!([]),
            json!("0"),
            json!(expected_remainder.to_string())
        ]
    );
    swarm
        .wait_for_all_nodes_to_catchup_to_version(repeat.info.version.0, Duration::from_secs(30))
        .await
        .unwrap();
    let final_installed = installed_at(&client, repeat.info.version.0).await;
    assert_eq!(final_installed.epoch, 77);
    for node in swarm.validators() {
        assert_eq!(
            installed_at(
                &node.rest_client_with_timeout(Duration::from_secs(10)),
                repeat.info.version.0
            )
            .await,
            final_installed
        );
    }
    println!("Power lifecycle passed: epoch=77, period=9, first_decay_power={expected_power}, historical_claim={expected}, retained_fraction={expected_remainder}; four background pools retained");
}

async fn assert_default_clock(client: &Client, version: u64, epoch: u64) {
    let period = (epoch - 1) / 60;
    assert_eq!(
        view_at(
            client,
            "0x1::poc_power_store::get_power_period_in_epochs",
            vec![],
            version
        )
        .await,
        vec![json!("60")]
    );
    assert_eq!(
        view_at(
            client,
            "0x1::poc_power_store::get_normalization_clock",
            vec![],
            version
        )
        .await,
        vec![
            json!("0"),
            json!(period.to_string()),
            json!((61 + period * 60).to_string()),
            json!(index_at(period).to_string()),
            json!({"vec": [index_at(period + 1).to_string()]}),
            json!("10000")
        ]
    );
}

/// PWR-07：跨越两个边界始终保持生产默认的 60 Epoch 周期。
/// 此历史中没有上传、分配、领取或周期长度修改。
#[tokio::test]
async fn poc_default_sixty_epoch_period_reaches_second_decay_without_uploads() {
    Lazy::force(&LIFECYCLE_SCRIPT);
    let swarm = lifecycle_swarm().await;
    let pools = swarm
        .validators()
        .map(|node| node.peer_id())
        .collect::<Vec<_>>();
    let client = swarm
        .validator(pools[0])
        .unwrap()
        .rest_client_with_timeout(Duration::from_secs(10));
    let chain = swarm.chain_info();
    let root = chain.root_account();
    let factory = chain
        .transaction_factory()
        .with_gas_unit_price(1)
        .with_max_gas_amount(2_000_000)
        .with_transaction_expiration_time(LIFECYCLE_TRANSACTION_EXPIRATION_SECS);
    let initial_version = client
        .get_ledger_information()
        .await
        .unwrap()
        .into_inner()
        .version;
    let initial = installed_at(&client, initial_version).await;
    assert!(initial.epoch < 60);
    assert_default_clock(&client, 0, 1).await;
    let store = resource_at(
        &client,
        CORE_CODE_ADDRESS,
        "0x1::poc_power_store::PowerStore",
        initial_version,
    )
    .await;
    let mut untouched_tables = BTreeSet::from([address(&store["users"]["handle"])]);
    let mut raw_versions = BTreeMap::new();
    let mut raw_positions = BTreeMap::new();
    for pool in &pools {
        let raw = raw_version(&client, *pool, initial_version).await;
        assert_eq!(raw, raw_version(&client, *pool, 0).await);
        let allocation = resource_at(
            &client,
            *pool,
            "0x1::poc_accounting::UserAllocation",
            initial_version,
        )
        .await;
        untouched_tables.insert(address(&allocation["positions"]["handle"]));
        raw_versions.insert(*pool, raw);
        raw_positions.insert(
            *pool,
            raw_position(&client, *pool, *pool, initial_version).await,
        );
    }
    let mut epoch = initial.epoch;
    let mut milestones = BTreeSet::new();
    let mut version = initial_version;
    let mut credited = BTreeSet::new();
    while epoch < 121 {
        let transaction = governance(&client, &root, &factory, Action::Advance).await;
        version = transaction.info.version.0;
        let before = installed_at(&client, version - 1).await;
        let after = installed_at(&client, version).await;
        assert_eq!(before.epoch, epoch);
        assert_eq!(after.epoch, epoch + 1);
        assert!(credited.insert(epoch));
        let period = (after.epoch - 1) / 60;
        let power = OWNER_UNITS * index_at(period) / (S * J);
        assert_default_clock(&client, version, after.epoch).await;
        for state in [&before, &after] {
            assert_eq!(state.reward_context.0, state.epoch);
            assert_eq!(state.reward_context.5, 0);
            assert_eq!(
                integer(&state.reward_split["installed_epoch"]),
                state.epoch as u128
            );
            assert_eq!(
                integer(&state.reward_split["installed_native_reward_bps"]),
                3000
            );
        }
        assert_eq!(after.validators.active_validators.len(), 4);
        assert_eq!(after.validators.total_voting_power, 4 * power);
        assert_eq!(after.validators.total_joining_power, 0);
        assert!(after.validators.pending_active.is_empty());
        assert!(after.validators.pending_inactive.is_empty());
        for (old, new) in before
            .validators
            .active_validators
            .iter()
            .zip(&after.validators.active_validators)
        {
            assert_eq!(new.account_address, old.account_address);
            assert_eq!(new.config(), old.config());
            assert_eq!(new.consensus_voting_power(), power as u64);
        }
        assert_eq!(
            event(&transaction, "::stake::PoCEpochInstalled").data,
            json!({"epoch": after.epoch.to_string(), "period": period.to_string(), "selected_count": "4", "total_power": (4 * power).to_string()})
        );
        assert_eq!(
            integer(&event(&transaction, "::reconfiguration::NewEpochEvent").data["epoch"]),
            after.epoch as u128
        );
        let period_events = events(&transaction, "::poc_power_store::PowerPeriodCommittedEvent");
        let previous_period = (epoch - 1) / 60;
        if period != previous_period {
            assert_eq!(period_events.len(), 1);
            assert_eq!(
                period_events[0].data,
                json!({
                    "previous_period": previous_period.to_string(),
                    "current_period": period.to_string(),
                })
            );
        } else {
            assert!(period_events.is_empty());
        }
        for suffix in [
            "::poc_power_store::PowerNormalized",
            "::poc_power_store::PowerUpdateStagedEvent",
            "::poc_accounting::AllocationScheduled",
        ] {
            assert!(transaction
                .events
                .iter()
                .all(|event| !event.typ.to_string().ends_with(suffix)));
        }
        for change in &transaction.info.changes {
            let handle = match change {
                WriteSetChange::WriteTableItem(item) => {
                    Some(AccountAddress::from_bytes(item.handle.inner()).unwrap())
                },
                WriteSetChange::DeleteTableItem(item) => {
                    Some(AccountAddress::from_bytes(item.handle.inner()).unwrap())
                },
                WriteSetChange::WriteResource(_)
                | WriteSetChange::DeleteResource(_)
                | WriteSetChange::WriteModule(_)
                | WriteSetChange::DeleteModule(_) => None,
            };
            if let Some(handle) = handle {
                assert!(
                    !untouched_tables.contains(&handle),
                    "Epoch transition rewrote a user normalization/position at {version}"
                );
            }
        }
        // 使用已安装奖励率和旧索引对应的真实表现建模每个结束 Epoch。
        // 单一创世持仓拥有全部 PoC 权益；原生奖励独立复投，不改变其 units。
        let performance = resource_at(
            &client,
            CORE_CODE_ADDRESS,
            "0x1::stake::ValidatorPerformance",
            version - 1,
        )
        .await;
        let credits = events(&transaction, "::stake::PoCRewardCredited");
        assert_eq!(credits.len(), 4);
        assert_eq!(events(&transaction, "::stake::PoCRewardSplit").len(), 4);
        for member in &before.validators.active_validators {
            let pool = member.account_address;
            let stats = &performance["validators"][member.config().validator_index as usize];
            let successful = integer(&stats["successful_proposals"]);
            let failed = integer(&stats["failed_proposals"]);
            let base = OWNER_UNITS * index_at((epoch - 1) / 60) / (S * J);
            assert_eq!(member.consensus_voting_power() as u128, base);
            let inflation = if successful + failed == 0 {
                0
            } else {
                base * successful * before.reward_context.2 as u128
                    / ((successful + failed) * before.reward_context.3 as u128)
            };
            let native = inflation * 3000 / 10000;
            let poc = inflation - native;
            let delta = (U256::from(poc).repr() << 128u32) / U256::from(OWNER_UNITS).repr();
            let credit = pool_event(&transaction, "::stake::PoCRewardCredited", pool);
            assert_eq!(
                credit.data,
                json!({"pool": pool.to_hex_literal(), "closing_epoch": epoch.to_string(), "reward_base_octa": base.to_string(), "inflation": poc.to_string(), "fee": "0", "delta_index": delta.to_string()})
            );
            let split = pool_event(&transaction, "::stake::PoCRewardSplit", pool);
            assert_eq!(
                split.data,
                json!({"pool": pool.to_hex_literal(), "closing_epoch": epoch.to_string(), "native_reward_bps": "3000", "total_inflation_octa": inflation.to_string(), "active_native_reward_octa": native.to_string(), "pending_inactive_native_reward_octa": "0", "poc_inflation_octa": poc.to_string()})
            );
            let old_pool = pool_at(&client, pool, version - 1).await;
            let new_pool = pool_at(&client, pool, version).await;
            assert_eq!(integer(&new_pool[0]), OWNER_UNITS);
            assert_eq!(integer(&new_pool[1]), OWNER_UNITS);
            assert_eq!(integer(&new_pool[2]), power);
            assert_eq!(integer(&new_pool[3]) - integer(&old_pool[3]), poc);
            assert_eq!(wide(&new_pool[4]).repr() - wide(&old_pool[4]).repr(), delta);
            let old_stake = view_at(
                &client,
                "0x1::stake::get_stake",
                vec![json!(pool)],
                version - 1,
            )
            .await;
            let new_stake =
                view_at(&client, "0x1::stake::get_stake", vec![json!(pool)], version).await;
            assert_eq!(integer(&new_stake[0]) - integer(&old_stake[0]), native);
            assert_eq!(&old_stake[1..], &[json!("0"), json!("0"), json!("0")]);
            assert_eq!(&new_stake[1..], &old_stake[1..]);
            let old_position = position_at(&client, pool, pool, version - 1).await;
            let new_position = position_at(&client, pool, pool, version).await;
            let entitlement = |position: &[Value]| {
                (U256::from(integer(&position[2])).repr() << 128u32) + wide(&position[3]).repr()
            };
            assert_eq!(integer(&new_position[0]), OWNER_UNITS);
            assert_eq!(new_position[1], json!([]));
            assert_eq!(
                entitlement(&new_position) - entitlement(&old_position),
                U256::from(OWNER_UNITS).repr() * delta
            );
        }
        epoch = after.epoch;
        if [60, 61, 120, 121].contains(&epoch) {
            milestones.insert(epoch);
            let expected = match epoch {
                60 => 100_000_000,
                61 | 120 => 99_949_999,
                121 => 99_900_024,
                _ => unreachable!(),
            };
            assert_eq!(power, expected);
            for pool in &pools {
                assert_eq!(
                    raw_version(&client, *pool, version).await,
                    raw_versions[pool]
                );
                assert_eq!(
                    raw_position(&client, *pool, *pool, version).await,
                    raw_positions[pool]
                );
                assert_eq!(
                    view_at(
                        &client,
                        "0x1::poc_power_store::get_accounting_snapshot",
                        vec![json!(pool)],
                        version
                    )
                    .await,
                    vec![
                        json!(OWNER_UNITS.to_string()),
                        json!(OWNER_UNITS.to_string()),
                        json!(period.to_string()),
                        json!((61 + period * 60).to_string())
                    ]
                );
            }
            println!("PWR-07 fixed period milestone: epoch={epoch}, period={period}, index={}, power={power}, next_boundary={}, version={version}, native_bps=3000; raw versions and physical positions unchanged", index_at(period), 61 + period * 60);
        }
    }
    assert_eq!(milestones, BTreeSet::from([60, 61, 120, 121]));
    assert_eq!(credited.len() as u64, 121 - initial.epoch);
    swarm
        .wait_for_all_nodes_to_catchup_to_version(version, Duration::from_secs(30))
        .await
        .unwrap();
    let expected = installed_at(&client, version).await;
    for node in swarm.validators() {
        let peer = node.rest_client_with_timeout(Duration::from_secs(10));
        assert_eq!(installed_at(&peer, version).await, expected);
        assert_default_clock(&peer, version, 121).await;
        for pool in &pools {
            assert_eq!(raw_version(&peer, *pool, version).await, raw_versions[pool]);
            assert_eq!(
                pool_at(&peer, *pool, version).await,
                pool_at(&client, *pool, version).await
            );
        }
    }
}

static GENESIS_REPLAY: Lazy<Vec<u8>> = Lazy::new(|| {
    compile_script(
        "PoCGenesisPowerReplay",
        r#"
script {
    use topo_framework::poc_power_store;
    use topo_framework::reconfiguration;
    use topo_framework::stake;
    use topo_framework::topo_governance;
    fun main(root: &signer, user: address, power: u64) {
        let framework = topo_governance::get_signer_testnet_only(root, @0x1);
        stake::schedule_reward_split(&framework, 6000, reconfiguration::current_epoch() + 1);
        poc_power_store::set_genesis_committed_power(&framework, user, power);
    }
}
"#,
    )
});

/// GEN-06：创世结束后，真实生产入口必须拒绝已授权的 framework signer，并回滚同笔交易中
/// 位于它之前、原本合法的治理写入。本测试不调用 friend 或 test-only 初始化适配器。
#[tokio::test]
async fn poc_operating_chain_rejects_genesis_power_replay_atomically() {
    Lazy::force(&GENESIS_REPLAY);
    Lazy::force(&LIFECYCLE_SCRIPT);
    let swarm = lifecycle_swarm().await;
    let pools = swarm
        .validators()
        .map(|node| node.peer_id())
        .collect::<Vec<_>>();
    let client = swarm
        .validator(pools[0])
        .unwrap()
        .rest_client_with_timeout(Duration::from_secs(10));
    let mut public = swarm.chain_info().into_aptos_public_info();
    let outsider = public.create_and_fund_user_account(OHMP).await.unwrap();
    let chain = swarm.chain_info();
    let root = chain.root_account();
    let factory = chain
        .transaction_factory()
        .with_gas_unit_price(1)
        .with_max_gas_amount(2_000_000)
        .with_transaction_expiration_time(LIFECYCLE_TRANSACTION_EXPIRATION_SECS);
    let upload = governance(&client, &root, &factory, Action::Upload {
        period: 1,
        user: pools[0],
        power: 2 * OHMP,
    })
    .await;
    let initial_version = upload.info.version.0;
    let raw = raw_version(&client, pools[0], initial_version).await;
    let clock = resource_at(
        &client,
        CORE_CODE_ADDRESS,
        "0x1::poc_power_store::PeriodClock",
        initial_version,
    )
    .await;
    let installed = installed_at(&client, initial_version).await;
    assert_eq!(
        view_at(
            &client,
            "0x1::chain_status::is_operating",
            vec![],
            initial_version
        )
        .await,
        vec![json!(true)]
    );
    assert_eq!(
        view_at(
            &client,
            "0x1::chain_status::is_genesis",
            vec![],
            initial_version
        )
        .await,
        vec![json!(false)]
    );
    let users = [pools[0], outsider.address()];
    for user in users {
        for power in [0, OHMP, u64::MAX] {
            let direct = execute(
                &client,
                &outsider,
                &factory,
                aptos_stdlib::poc_power_store_set_genesis_committed_power(user, power),
            )
            .await;
            assert_abort(
                &client,
                &direct,
                "system_addresses",
                0x50003,
                &users,
                &pools,
            )
            .await;
            let replay =
                TransactionPayload::Script(Script::new(GENESIS_REPLAY.clone(), vec![], vec![
                    TransactionArgument::Address(user),
                    TransactionArgument::U64(power),
                ]));
            let denied = execute(&client, &root, &factory, replay).await;
            // chain_status::assert_genesis 当前使用 ENOT_OPERATING=1；
            // 这里断言准确的生产模块和错误码，而不是常量名称。
            assert_abort(&client, &denied, "chain_status", 0x30001, &users, &pools).await;
            let at = denied.info.version.0;
            assert_eq!(installed_at(&client, at).await, installed);
            assert_eq!(raw_version(&client, pools[0], at).await, raw);
            assert_eq!(
                resource_at(
                    &client,
                    CORE_CODE_ADDRESS,
                    "0x1::poc_power_store::PeriodClock",
                    at
                )
                .await,
                clock
            );
            assert_eq!(
                view_at(
                    &client,
                    "0x1::poc_power_store::is_user_normalized",
                    vec![json!(outsider.address())],
                    at
                )
                .await,
                vec![json!(false)]
            );
        }
    }
    // 普通授权上传仍然可用；失败的创世写入没有为原本不存在的用户占用版本。
    let ordinary = governance(&client, &root, &factory, Action::Upload {
        period: 1,
        user: outsider.address(),
        power: OHMP,
    })
    .await;
    let at = ordinary.info.version.0;
    assert_eq!(installed_at(&client, at).await, installed);
    assert_eq!(
        integer(&event(&ordinary, "::poc_power_store::PowerNormalized").data["units"]),
        units_at(OHMP, 1)
    );
    assert_eq!(
        integer(&event(&ordinary, "::poc_power_store::PowerUpdateStagedEvent").data["power"]),
        OHMP as u128
    );
    assert_eq!(
        view_at(
            &client,
            "0x1::poc_power_store::get_accounting_snapshot",
            vec![json!(outsider.address())],
            at
        )
        .await,
        vec![
            json!("0"),
            json!(units_at(OHMP, 1).to_string()),
            json!("0"),
            json!("61")
        ]
    );
    assert_eq!(raw_version(&client, pools[0], at).await, raw);
    swarm
        .wait_for_all_nodes_to_catchup_to_version(at, Duration::from_secs(30))
        .await
        .unwrap();
    let new_version = raw_version(&client, outsider.address(), at).await;
    for node in swarm.validators() {
        let peer = node.rest_client_with_timeout(Duration::from_secs(10));
        assert_eq!(installed_at(&peer, at).await, installed);
        assert_eq!(raw_version(&peer, pools[0], at).await, raw);
        assert_eq!(
            raw_version(&peer, outsider.address(), at).await,
            new_version
        );
        assert_eq!(
            resource_at(
                &peer,
                CORE_CODE_ADDRESS,
                "0x1::poc_power_store::PeriodClock",
                at
            )
            .await,
            clock
        );
    }
    println!("GEN-06 production replay rejected: authorized chain_status/0x30001, unauthorized system_addresses/0x50003, powers=0/1OHMP/u64::MAX, existing current+future and absent users; ordinary upload succeeds, epoch={}, version={at}", installed.epoch);
}

/// 基于 Epoch 的权益归属模型，不依赖被测的检查点或变化链。
/// 目标池唯一的创世 owner 在整个场景中始终持有 OWNER_UNITS。
struct ExitedHistory {
    pool: AccountAddress,
    units_by_epoch: BTreeMap<u64, u128>,
    boundary_indices: BTreeMap<u64, U256>,
    epoch: u64,
    index: U256,
    accrued: U256,
    vault: u64,
}

impl ExitedHistory {
    fn units(&self, epoch: u64) -> u128 {
        self.units_by_epoch
            .range(..=epoch)
            .next_back()
            .map(|(_, units)| *units)
            .unwrap_or(0)
    }

    fn claimable(&self) -> u64 {
        u64::try_from(U256::checked_div(self.accrued, U256::ONE << U256::from(128_u8)).unwrap())
            .unwrap()
    }

    fn fraction(&self) -> U256 {
        U256::checked_rem(self.accrued, U256::ONE << U256::from(128_u8)).unwrap()
    }

    async fn assert_pool(&self, client: &Client, version: u64) {
        let installed = installed_at(client, version).await;
        assert_eq!(installed.epoch, self.epoch);
        assert_eq!(
            installed.validators.active_validators.len(),
            if self.epoch < 64 { 4 } else { 3 }
        );
        assert_eq!(
            installed
                .validators
                .active_validators
                .iter()
                .any(|member| member.account_address == self.pool),
            self.epoch < 64,
            "An exited pool must not rejoin merely because its raw power changes"
        );
        assert!(installed.validators.pending_active.is_empty());
        assert!(installed.validators.pending_inactive.is_empty());
        assert_eq!(installed.reward_context.0, self.epoch);
        assert_eq!(
            integer(&installed.reward_split["installed_epoch"]),
            self.epoch as u128
        );
        assert_eq!(
            integer(&installed.reward_split["installed_native_reward_bps"]),
            3000
        );
        let base = installed
            .validators
            .active_validators
            .iter()
            .find(|member| member.account_address == self.pool)
            .map(|member| member.consensus_voting_power())
            .unwrap_or(0);
        assert_eq!(pool_at(client, self.pool, version).await, vec![
            json!((OWNER_UNITS + self.units(self.epoch)).to_string()),
            json!((OWNER_UNITS + self.units(self.epoch + 1)).to_string()),
            json!(base.to_string()),
            json!(self.vault.to_string()),
            json!(self.index.to_string()),
        ]);
        assert_clock(client, version, self.epoch).await;
    }

    async fn advance(
        &mut self,
        client: &Client,
        root: &LocalAccount,
        factory: &TransactionFactory,
        target: u64,
    ) -> u64 {
        let mut version = client
            .get_ledger_information()
            .await
            .unwrap()
            .into_inner()
            .version;
        assert_eq!(installed_at(client, version).await.epoch, self.epoch);
        assert!(target >= self.epoch);
        while self.epoch < target {
            let tx = governance(client, root, factory, Action::Advance).await;
            version = tx.info.version.0;
            let before = installed_at(client, version - 1).await;
            let after = installed_at(client, version).await;
            assert_eq!(before.epoch, self.epoch);
            assert_eq!(after.epoch, self.epoch + 1);
            assert_eq!(events(&tx, "::stake::PoCEpochInstalled").len(), 1);
            assert_eq!(events(&tx, "::reconfiguration::NewEpochEvent").len(), 1);
            assert_eq!(
                integer(&event(&tx, "::stake::PoCEpochInstalled").data["epoch"]),
                after.epoch as u128
            );
            assert_eq!(before.reward_context.5, 0);
            assert_eq!(
                integer(&before.reward_split["installed_native_reward_bps"]),
                3000
            );
            // 退出请求将成员移入 pending_inactive，但结束当期仍按旧索引和已安装权重计奖。
            let member = before
                .validators
                .active_validators
                .iter()
                .chain(&before.validators.pending_inactive)
                .find(|member| member.account_address == self.pool);
            if let Some(member) = member {
                let base = member.consensus_voting_power();
                let stats = resource_at(
                    client,
                    CORE_CODE_ADDRESS,
                    "0x1::stake::ValidatorPerformance",
                    version - 1,
                )
                .await;
                let perf = &stats["validators"][member.config().validator_index as usize];
                let successful = integer(&perf["successful_proposals"]);
                let failed = integer(&perf["failed_proposals"]);
                let inflation = if successful + failed == 0 {
                    0
                } else {
                    base as u128 * successful * before.reward_context.2 as u128
                        / ((successful + failed) * before.reward_context.3 as u128)
                };
                let native = inflation * 3000 / 10000;
                let poc = inflation - native;
                let user_units = self.units(self.epoch);
                let total_units = OWNER_UNITS + user_units;
                let delta = U256::checked_div(
                    U256::checked_mul(U256::from(poc), U256::ONE << U256::from(128_u8)).unwrap(),
                    U256::from(total_units),
                )
                .unwrap();
                assert_eq!(
                    pool_event(&tx, "::stake::PoCRewardCredited", self.pool).data,
                    json!({"pool": self.pool.to_hex_literal(), "closing_epoch": self.epoch.to_string(),
                        "reward_base_octa": base.to_string(), "inflation": poc.to_string(),
                        "fee": "0", "delta_index": delta.to_string()})
                );
                assert_eq!(
                    pool_event(&tx, "::stake::PoCRewardSplit", self.pool).data,
                    json!({"pool": self.pool.to_hex_literal(), "closing_epoch": self.epoch.to_string(),
                        "native_reward_bps": "3000", "total_inflation_octa": inflation.to_string(),
                        "active_native_reward_octa": native.to_string(),
                        "pending_inactive_native_reward_octa": "0", "poc_inflation_octa": poc.to_string()})
                );
                let stake_before =
                    resource_at(client, self.pool, "0x1::stake::StakePool", version - 1).await;
                let stake_after =
                    resource_at(client, self.pool, "0x1::stake::StakePool", version).await;
                assert_eq!(
                    integer(&stake_after["active"]["value"])
                        - integer(&stake_before["active"]["value"]),
                    native
                );
                for field in ["inactive", "pending_active", "pending_inactive"] {
                    assert_eq!(integer(&stake_before[field]["value"]), 0);
                    assert_eq!(integer(&stake_after[field]["value"]), 0);
                }
                self.index = U256::checked_add(self.index, delta).unwrap();
                self.accrued = U256::checked_add(
                    self.accrued,
                    U256::checked_mul(U256::from(user_units), delta).unwrap(),
                )
                .unwrap();
                self.vault += u64::try_from(poc).unwrap();
            } else {
                for suffix in ["::stake::PoCRewardCredited", "::stake::PoCRewardSplit"] {
                    assert!(events(&tx, suffix)
                        .iter()
                        .all(|event| address(&event.data["pool"]) != self.pool));
                }
                assert_eq!(
                    resource_at(client, self.pool, "0x1::stake::StakePool", version - 1).await,
                    resource_at(client, self.pool, "0x1::stake::StakePool", version).await
                );
            }
            self.epoch = after.epoch;
            self.boundary_indices.insert(self.epoch, self.index);
            self.assert_pool(client, version).await;
        }
        version
    }
}

async fn stage_history_power(
    client: &Client,
    root: &LocalAccount,
    factory: &TransactionFactory,
    user: AccountAddress,
    period: u64,
    raw: u64,
) -> u64 {
    let tx = governance(client, root, factory, Action::Upload {
        period,
        user,
        power: raw,
    })
    .await;
    assert_eq!(
        integer(&event(&tx, "::poc_power_store::PowerNormalized").data["units"]),
        units_at(raw, period)
    );
    assert_eq!(
        event(&tx, "::poc_power_store::PowerUpdateStagedEvent").data,
        json!({"user": user.to_hex_literal(), "target_period": period.to_string(),
            "effective_period": period.to_string(), "power": raw.to_string()})
    );
    tx.info.version.0
}

/// REW-06：两个已成熟检查点跨越长期不操作和委员会退出后仍然存在；
/// 后续原始版本淘汰及零版本不得抹除历史权益。
#[tokio::test]
async fn poc_exited_pool_preserves_matured_checkpoints_across_version_rollover() {
    Lazy::force(&LIFECYCLE_SCRIPT);
    let swarm = lifecycle_swarm().await;
    let pools = swarm
        .validators()
        .map(|node| node.peer_id())
        .collect::<Vec<_>>();
    let pool = pools[0];
    let client = swarm
        .validator(pools[1])
        .unwrap()
        .rest_client_with_timeout(Duration::from_secs(10));
    let root = swarm.chain_info().root_account();
    let factory = swarm
        .chain_info()
        .transaction_factory()
        .with_gas_unit_price(1)
        .with_max_gas_amount(2_000_000)
        .with_transaction_expiration_time(LIFECYCLE_TRANSACTION_EXPIRATION_SECS);
    let mut public = swarm.chain_info().into_aptos_public_info();
    let user = public.create_and_fund_user_account(OHMP).await.unwrap();
    public.mint(pool, OHMP).await.unwrap();
    let owner = LocalAccount::new(
        pool,
        swarm
            .validator(pool)
            .unwrap()
            .account_private_key()
            .as_ref()
            .unwrap()
            .private_key(),
        client
            .get_account(pool)
            .await
            .unwrap()
            .into_inner()
            .sequence_number,
    );
    // 清理退出记录可能向 root 退还表存储费，因此预先为钱包留出余额空间。
    success(
        execute(
            &client,
            &root,
            &factory,
            aptos_stdlib::topo_coin_transfer(user.address(), OHMP),
        )
        .await,
    );
    success(
        execute(
            &client,
            &user,
            &factory,
            aptos_stdlib::poc_allocation_set_allocations(vec![pool], vec![5000]),
        )
        .await,
    );
    stage_history_power(&client, &root, &factory, user.address(), 1, 2 * OHMP).await;
    let configured = governance(&client, &root, &factory, Action::PeriodLength(2))
        .await
        .info
        .version
        .0;
    let initial = installed_at(&client, configured).await;
    assert!(initial.epoch < 61);
    let initial_pool = pool_at(&client, pool, configured).await;
    let first_units = units_at(2 * OHMP, 1) / 2;
    let mut model = ExitedHistory {
        pool,
        units_by_epoch: BTreeMap::from([(61, first_units)]),
        boundary_indices: BTreeMap::new(),
        epoch: initial.epoch,
        index: wide(&initial_pool[4]),
        accrued: U256::ZERO,
        vault: integer(&initial_pool[3]) as u64,
    };
    model.advance(&client, &root, &factory, 61).await;
    wait_for_pool_proposal(&client, pool, 61).await;
    stage_history_power(&client, &root, &factory, user.address(), 2, 4 * OHMP).await;
    let allocated = success(
        execute(
            &client,
            &user,
            &factory,
            aptos_stdlib::poc_allocation_set_allocations(vec![pool], vec![2500]),
        )
        .await,
    )
    .info
    .version
    .0;
    let middle_units = units_at(2 * OHMP, 1) / 4;
    let second_units = units_at(4 * OHMP, 2) / 4;
    model.units_by_epoch.insert(62, middle_units);
    model.units_by_epoch.insert(63, second_units);
    let expected_changes = json!([
        {"epoch":"62","units":middle_units.to_string()},
        {"epoch":"63","units":second_units.to_string()},
    ]);
    let pending = raw_position(&client, user.address(), pool, allocated).await;
    assert_eq!(integer(&pending["units"]), first_units);
    assert_eq!(pending["changes"], expected_changes);
    model.advance(&client, &root, &factory, 62).await;
    wait_for_pool_proposal(&client, pool, 62).await;
    let matured = model.advance(&client, &root, &factory, 63).await;
    let physical = raw_position(&client, user.address(), pool, matured).await;
    assert_eq!(
        physical, pending,
        "Epoch commits must not eagerly settle user positions"
    );
    for epoch in [62, 63] {
        assert_eq!(
            checkpoint_at(&client, pool, epoch, matured).await.unwrap(),
            json!({"index": model.boundary_indices[&epoch].to_string(), "refs":"1"})
        );
    }
    wait_for_pool_proposal(&client, pool, 63).await;
    let leaving = success(
        execute(
            &client,
            &owner,
            &factory,
            aptos_stdlib::stake_leave_validator_set(pool),
        )
        .await,
    );
    let left = model.advance(&client, &root, &factory, 64).await;
    assert!(model.claimable() > 0);
    let after_exit = installed_at(&client, left).await;
    assert_eq!(after_exit.validators.active_validators.len(), 3);
    assert!(after_exit.validators.pending_inactive.is_empty());
    assert!(after_exit
        .validators
        .active_validators
        .iter()
        .all(|v| v.account_address != pool));
    assert_eq!(
        raw_position(&client, user.address(), pool, leaving.info.version.0).await,
        physical
    );
    assert_eq!(
        raw_position(&client, user.address(), pool, left).await,
        physical
    );
    let versions = raw_version(&client, user.address(), left).await;
    let exited_ledger = ledger_at(&client, pool, left).await;
    assert_eq!(integer(&exited_ledger["epoch"]), 64);
    let past_accrued = model.accrued;
    let untouched = model.advance(&client, &root, &factory, 71).await;
    assert_eq!(model.accrued, past_accrued);
    assert_eq!(ledger_at(&client, pool, untouched).await, exited_ledger);
    assert_eq!(
        raw_position(&client, user.address(), pool, untouched).await,
        physical
    );
    assert_eq!(
        raw_version(&client, user.address(), untouched).await,
        versions
    );
    for epoch in [62, 63] {
        assert_eq!(
            checkpoint_at(&client, pool, epoch, untouched)
                .await
                .unwrap(),
            json!({"index": model.boundary_indices[&epoch].to_string(), "refs":"1"})
        );
    }
    // 此时仅上传者访问该账户：先消费旧检查点，再由下一个原始版本槽淘汰周期 1。
    let rolled = stage_history_power(&client, &root, &factory, user.address(), 7, 6 * OHMP).await;
    model.units_by_epoch.insert(73, units_at(6 * OHMP, 7) / 4);
    assert_window(
        &client,
        user.address(),
        rolled,
        (2, 4 * OHMP),
        (7, 6 * OHMP),
    )
    .await;
    for epoch in [62, 63] {
        assert!(checkpoint_at(&client, pool, epoch, rolled).await.is_none());
    }
    let settled = raw_position(&client, user.address(), pool, rolled).await;
    assert_eq!(wide(&settled["accrued"]), model.accrued);
    assert_eq!(integer(&settled["units"]), second_units);
    let dormant = model.advance(&client, &root, &factory, 75).await;
    assert_eq!(
        raw_position(&client, user.address(), pool, dormant).await,
        settled
    );
    assert_eq!(
        integer(&ledger_at(&client, pool, dormant).await["epoch"]),
        71
    );
    assert!(checkpoint_at(&client, pool, 73, dormant).await.is_none());
    // 本次操作继续淘汰周期 2，并排定一个真实的显式零版本。
    let zero = stage_history_power(&client, &root, &factory, user.address(), 9, 0).await;
    model.units_by_epoch.insert(77, 0);
    assert_window(&client, user.address(), zero, (7, 6 * OHMP), (9, 0)).await;
    assert!(checkpoint_at(&client, pool, 73, zero).await.is_none());
    assert_eq!(
        wide(&raw_position(&client, user.address(), pool, zero).await["accrued"]),
        past_accrued
    );
    let final_version = model.advance(&client, &root, &factory, 79).await;
    let amount = model.claimable();
    let fraction = model.fraction();
    assert!(amount > 0);
    let final_physical = raw_position(&client, user.address(), pool, final_version).await;
    let final_ledger = ledger_at(&client, pool, final_version).await;
    assert_eq!(integer(&final_ledger["epoch"]), 75);
    assert_eq!(
        final_physical["changes"],
        json!([{"epoch":"77","units":"0"}])
    );
    assert_eq!(final_ledger["changes"].as_array().unwrap().len(), 1);
    assert_eq!(integer(&final_ledger["changes"][0]["epoch"]), 77);
    assert_eq!(integer(&final_ledger["changes"][0]["refs"]), 1);
    assert!(checkpoint_at(&client, pool, 77, final_version)
        .await
        .is_none());
    let final_raw = raw_version(&client, user.address(), final_version).await;
    let final_installed = installed_at(&client, final_version).await;
    let final_clock = resource_at(
        &client,
        CORE_CODE_ADDRESS,
        "0x1::poc_power_store::PeriodClock",
        final_version,
    )
    .await;
    for _ in 0..2 {
        assert_eq!(
            position_at(&client, user.address(), pool, final_version).await,
            vec![
                json!("0"),
                json!([]),
                json!(amount.to_string()),
                json!(fraction.to_string())
            ]
        );
    }
    let queried = client
        .get_ledger_information()
        .await
        .unwrap()
        .into_inner()
        .version;
    assert_eq!(ledger_at(&client, pool, queried).await, final_ledger);
    assert_eq!(
        raw_position(&client, user.address(), pool, queried).await,
        final_physical
    );
    assert_eq!(
        raw_version(&client, user.address(), queried).await,
        final_raw
    );
    assert_eq!(installed_at(&client, queried).await, final_installed);
    let claim = success(
        execute(
            &client,
            &user,
            &factory,
            aptos_stdlib::poc_allocation_claim_rewards(vec![pool]),
        )
        .await,
    );
    let claimed = claim.info.version.0;
    assert_eq!(
        event(&claim, "::poc_accounting::PoCRewardClaimed").data,
        json!({"user":user.address().to_hex_literal(), "pool":pool.to_hex_literal(), "amount":amount.to_string()})
    );
    assert_payment(&client, &claim, amount).await;
    model.accrued = fraction;
    model.vault -= amount;
    model.assert_pool(&client, claimed).await;
    assert_eq!(installed_at(&client, claimed).await, final_installed);
    assert_eq!(
        resource_at(
            &client,
            CORE_CODE_ADDRESS,
            "0x1::poc_power_store::PeriodClock",
            claimed
        )
        .await,
        final_clock
    );
    assert_eq!(
        integer(&ledger_at(&client, pool, claimed).await["epoch"]),
        79
    );
    assert!(ledger_at(&client, pool, claimed).await["changes"]
        .as_array()
        .unwrap()
        .is_empty());
    assert_eq!(
        raw_position(&client, user.address(), pool, claimed).await["changes"],
        json!([])
    );
    assert_eq!(
        raw_version(&client, user.address(), claimed).await,
        final_raw
    );
    assert_eq!(
        resource_at(&client, pool, "0x1::stake::StakePool", claimed - 1).await,
        resource_at(&client, pool, "0x1::stake::StakePool", claimed).await
    );
    for epoch in [61, 62, 63, 73, 77] {
        assert!(checkpoint_at(&client, pool, epoch, claimed).await.is_none());
    }
    let repeat = success(
        execute(
            &client,
            &user,
            &factory,
            aptos_stdlib::poc_allocation_claim_rewards(vec![pool]),
        )
        .await,
    );
    assert!(events(&repeat, "::poc_accounting::PoCRewardClaimed").is_empty());
    assert_payment(&client, &repeat, 0).await;
    let at = repeat.info.version.0;
    model.assert_pool(&client, at).await;
    assert_eq!(installed_at(&client, at).await, final_installed);
    let expected_pool = pool_at(&client, pool, at).await;
    let expected_ledger = ledger_at(&client, pool, at).await;
    let expected_stake = resource_at(&client, pool, "0x1::stake::StakePool", at).await;
    // 已离任节点无需继续追赶后续委员会。
    for member in &final_installed.validators.active_validators {
        let other = swarm
            .validator(member.account_address)
            .unwrap()
            .rest_client_with_timeout(Duration::from_secs(10));
        timeout(Duration::from_secs(30), other.wait_for_version(at))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(installed_at(&other, at).await, final_installed);
        assert_eq!(pool_at(&other, pool, at).await, expected_pool);
        assert_eq!(ledger_at(&other, pool, at).await, expected_ledger);
        assert_eq!(raw_version(&other, user.address(), at).await, final_raw);
        assert_eq!(
            resource_at(&other, pool, "0x1::stake::StakePool", at).await,
            expected_stake
        );
        assert_eq!(position_at(&other, user.address(), pool, at).await, vec![
            json!("0"),
            json!([]),
            json!("0"),
            json!(fraction.to_string())
        ]);
        for epoch in [61, 62, 63, 73, 77] {
            assert!(checkpoint_at(&other, pool, epoch, at).await.is_none());
        }
    }
    println!("REW-06 exited pool: two matured checkpoints62/63 retained through E71, raw periods1/2 evicted by7/9, zero effectiveE77, claim_epoch=79, amount={amount}, fractional={fraction}, current_nodes=3, version={at}");
}
