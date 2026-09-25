// Copyright (c) Aptos Foundation
// Licensed pursuant to the Innovation-Enabling Source Code License, available at https://github.com/aptos-labs/aptos-core/blob/main/LICENSE

//! WGT-02 / EPO-06：真实构造四类质押余额，并使用缓存的到期判定截止时间。
//! 显式 A 时序变体：创世采用短锁仓期，随后通过公开治理入口
//! 控制名义 Epoch 时长，不注入时钟、质押状态或回调。

use super::{
    assert_targets,
    defaults::{installed_at, InstalledSnapshot},
    fee_rewards::{address, events, integer, ledger_at, pool_at, pool_event, success, view, wide},
    frozen_context_at, optional_resource_at_version, resource_at_version,
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
    dkg::DKGState,
    on_chain_config::{
        OnChainChunkyDKGConfig, OnChainRandomnessConfig, RandomnessConfigMoveStruct, ValidatorSet,
    },
    transaction::{Script, TransactionArgument, TransactionPayload},
};
use move_core_types::int256::U256;
use once_cell::sync::Lazy;
use serde_json::{json, Value};
use std::{collections::BTreeMap, sync::Arc, time::Duration};
use tokio::time::{sleep, timeout, Instant};

const RAW_POWER: u64 = 100;
const UNITS: u128 = (RAW_POWER as u128) << 16;
const INDEX_SCALE: u128 = 1 << 64;
const LOCKUP_SECS: u64 = 30;
const NOMINAL_EPOCH_SECS: u64 = 5;
const DKG_FAILPOINT: &str = "dkg::process_dkg_start_event";

static GOVERNANCE: Lazy<Vec<u8>> = Lazy::new(|| {
    compile_script(
        "PoCBondCutoff",
        r#"script {
        use std::features;
        use topo_std::fixed_point64;
        use topo_framework::block;
        use topo_framework::epoch_timeout_config;
        use topo_framework::poc_power_store;
        use topo_framework::randomness_config;
        use topo_framework::topo_governance;
        use topo_framework::staking_config;

        fun main(root: &signer, operation: u8) {
            let framework = topo_governance::get_signer_testnet_only(root, @0x1);
            if (operation == 0) {
                // 延长区块配置中的换届间隔不会改变已有的短锁仓期；
                // 等待该锁仓真实到期后构造 inactive 余额。
                block::update_epoch_interval_microsecs(&framework, 3600000000);
                staking_config::update_recurring_lockup_duration_secs(&framework, 30);
                poc_power_store::set_power_period_in_epochs(&framework, 2);
                if (features::periodical_reward_rate_decrease_enabled()) {
                    let rate = fixed_point64::create_from_rational(1, 1);
                    staking_config::update_rewards_config(&framework, rate, rate,
                        31536000, fixed_point64::create_from_rational(0, 1));
                } else {
                    staking_config::update_rewards_rate(&framework, 1, 1);
                };
            } else if (operation == 1) {
                topo_governance::reconfigure(&framework);
            } else if (operation == 2) {
                // reconfigure 根据当前配置 Off 选择执行路径。
                // 此次同步提交随后安装已缓冲的 V1 配置。
                randomness_config::set_for_next_epoch(&framework,
                    randomness_config::new_v1(
                        fixed_point64::create_from_rational(1, 2),
                        fixed_point64::create_from_rational(2, 3)));
                epoch_timeout_config::set_for_next_epoch(&framework,
                    epoch_timeout_config::new_disabled());
                topo_governance::reconfigure(&framework);
            } else if (operation == 3) {
                // 在此交易前暂停真实 DKG 发牌方。
                // 原子地更新间隔并启动 DKG，避免准备过程中的竞态。
                block::update_epoch_interval_microsecs(&framework, 5000000);
                topo_governance::reconfigure(&framework);
            } else {
                assert!(operation == 4, 0);
                topo_governance::force_end_epoch(&framework);
                // 冻结现已解除，使后续观测保持在 E61。
                block::update_epoch_interval_microsecs(&framework, 3600000000);
            };
        }
    }"#,
    )
});

fn poc_governance(operation: u8) -> TransactionPayload {
    TransactionPayload::Script(Script::new(GOVERNANCE.clone(), vec![], vec![
        TransactionArgument::U8(operation),
    ]))
}

struct Fixture {
    swarm: LocalSwarm,
    client: Client,
    root: Arc<LocalAccount>,
    owner: LocalAccount,
    pools: Vec<AccountAddress>,
    factory: TransactionFactory,
}

async fn poc_resource(f: &Fixture, owner: AccountAddress, name: &str, version: u64) -> Value {
    optional_resource_at_version(&f.client, owner, name, version)
        .await
        .unwrap_or_else(|| panic!("Missing {name} at {owner}, version {version}"))
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

async fn poc_now(f: &Fixture, version: u64) -> u64 {
    integer(
        &poc_resource(
            f,
            CORE_CODE_ADDRESS,
            "0x1::timestamp::CurrentTimeMicroseconds",
            version,
        )
        .await["microseconds"],
    ) as u64
        / 1_000_000
}

async fn poc_govern(f: &Fixture, operation: u8) -> UserTransaction {
    // 真实 DKG 元数据及缓存计划按生产规则支付存储 gas。
    let factory = f.factory.clone().with_gas_unit_price(100);
    success(execute(&f.client, &f.root, &factory, poc_governance(operation)).await)
}

async fn poc_owner(f: &Fixture, payload: TransactionPayload) -> UserTransaction {
    success(execute(&f.client, &f.owner, &f.factory, payload).await)
}

async fn poc_fixture() -> Fixture {
    Lazy::force(&GOVERNANCE);
    println!("Bond cutoff fixture A: 4 nodes, Open/minimum4/capacity5/growth25%, raw100 power and bond100 Octa each, ratio1 Octa/power, min_power10/max_power1000, retention9995/native0/fee_limit0, ordinary+Chunky initially off; genesis epoch10s/lockup10s/vote1s, public setup epoch3600s/next lockup30s/next power period2/rate1; member gas1, governance gas100, max_gas2000000");
    let swarm = SwarmBuilder::new_local(4)
        .with_aptos()
        .with_init_config(Arc::new(|_, config, _| {
            config.api.failpoints_enabled = true
        }))
        .with_init_genesis_stake(Arc::new(|_, stake| *stake = 100))
        .with_init_genesis_config(Arc::new(|config| {
            config.is_test = true;
            config.allow_new_validators = true;
            config.epoch_duration_secs = 10;
            config.recurring_lockup_duration_secs = 10;
            config.voting_duration_secs = 1;
            config.min_stake = 1;
            config.max_stake = 1000;
            config.voting_power_increase_limit = 25;
            config.consensus_config.enable_validator_txns();
            config.randomness_config_override = Some(OnChainRandomnessConfig::Off);
            config.chunky_dkg_config_override = Some(OnChainChunkyDKGConfig::default_disabled());
            config.poc_genesis_config = Some(Arc::new(|_| PocGenesisConfiguration {
                params: PowerParams {
                    bond_octa_per_ohmp: 100_000_000,
                    min_power: 10,
                    max_power: 1000,
                    min_validators: 4,
                },

                deployment_mode: DeploymentMode::Open,
                retention_bps: 9995,
                initial_raw_power: RAW_POWER,
            }));
        }))
        .build()
        .await;
    super::configure_fixture(&swarm, [4, 4, 4, 5, 10], 0).await;
    let mut pools = swarm
        .validators()
        .map(|node| node.peer_id())
        .collect::<Vec<_>>();
    pools.sort();
    let client = swarm
        .validator(pools[0])
        .unwrap()
        .rest_client_with_timeout(Duration::from_secs(10));
    let root = swarm.chain_info().root_account();
    let factory = swarm
        .chain_info()
        .transaction_factory()
        .with_gas_unit_price(1)
        .with_max_gas_amount(2_000_000)
        .with_transaction_expiration_time(120);
    // 这是首笔用户交易：先停止短周期自动换届，再注资或读取大量资源。
    // 后续步骤以启动时实际安装的 Epoch 为准。
    let configured = success(
        execute(
            &client,
            &root,
            &factory.clone().with_gas_unit_price(100),
            poc_governance(0),
        )
        .await,
    );
    let configured_version = configured.info.version.0;
    assert_eq!(
        installed_at(&client, configured_version - 1).await,
        installed_at(&client, configured_version).await
    );
    let node = swarm.validator(pools[0]).unwrap();
    let key = node.account_private_key().as_ref().unwrap().private_key();
    swarm
        .chain_info()
        .into_aptos_public_info()
        .mint(pools[0], 100_000_000)
        .await
        .unwrap();
    let sequence = client
        .get_account(pools[0])
        .await
        .unwrap()
        .into_inner()
        .sequence_number;
    let owner = LocalAccount::new(pools[0], key, sequence);
    let f = Fixture {
        swarm,
        client,
        root,
        owner,
        pools,
        factory,
    };
    // 为初始余额为 u64::MAX 的 root 钱包预留退款空间。
    success(
        execute(
            &f.client,
            &f.root,
            &f.factory,
            aptos_stdlib::topo_coin_transfer(f.pools[1], 100_000_000),
        )
        .await,
    );
    let version = poc_version(&f).await;
    let installed = installed_at(&f.client, version).await;
    assert!(
        installed.epoch < 59,
        "Startup consumed the planned first power period"
    );
    poc_assert_clock(&f, version, installed.epoch).await;
    for pool in &f.pools {
        poc_assert_balances(&f, *pool, version, [100, 0, 0, 0]).await;
    }
    let old_lock = integer(
        &poc_resource(&f, f.owner.address(), "0x1::stake::StakePool", version).await
            ["locked_until_secs"],
    ) as u64;
    assert!(
        old_lock <= poc_now(&f, version).await + 10,
        "Public setup must not extend the existing genesis lockup"
    );
    println!(
        "Short genesis lockup retained: epoch={}, pool={}, lock={old_lock}, version={version}",
        installed.epoch,
        f.owner.address()
    );
    f
}

async fn poc_assert_balances(f: &Fixture, pool: AccountAddress, version: u64, expected: [u64; 4]) {
    let stake = poc_resource(f, pool, "0x1::stake::StakePool", version).await;
    for (field, value) in ["active", "inactive", "pending_active", "pending_inactive"]
        .iter()
        .zip(expected)
    {
        assert_eq!(
            integer(&stake[*field]["value"]),
            value as u128,
            "pool={pool}, field={field}, version={version}"
        );
    }
    assert_eq!(
        view(
            &f.client,
            "0x1::stake::get_stake",
            vec![json!(pool)],
            version
        )
        .await,
        expected.map(|value| json!(value.to_string())).to_vec()
    );
}

fn poc_period_index(epoch: u64) -> (u64, u128, u64) {
    assert!(epoch <= 61);
    if epoch < 61 {
        (0, INDEX_SCALE, 61)
    } else {
        (1, INDEX_SCALE * 9995 / 10000, 63)
    }
}

async fn poc_assert_clock(f: &Fixture, version: u64, epoch: u64) {
    let (period, index, boundary) = poc_period_index(epoch);
    assert_eq!(
        view(
            &f.client,
            "0x1::poc_power_store::get_normalization_clock",
            vec![],
            version
        )
        .await,
        vec![
            json!(period.to_string()),
            json!(boundary.to_string()),
            json!(index.to_string()),
            json!({"vec": [(index * 9995 / 10000).to_string()]})
        ]
    );
    let clock = poc_resource(
        f,
        CORE_CODE_ADDRESS,
        "0x1::poc_power_store::PeriodClock",
        version,
    )
    .await;
    assert_eq!(integer(&clock["last_epoch"]), epoch as u128);
    assert_eq!(integer(&clock["current_period"]), period as u128);
    assert_eq!(integer(&clock["power_period_in_epochs"]), 2);
    assert_eq!(
        integer(&clock["epochs_until_next_power_period"]),
        (boundary - epoch - 1) as u128
    );
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
    assert!(resource_at_version::<DKGState>(&f.client, version)
        .await
        .in_progress
        .is_none());
}

/// 准备阶段的提交显式读取 Configuration 中已安装的 Epoch。
/// 换届刚完成时，LedgerInfo 仍可能由旧委员会签名。
async fn poc_commit(f: &Fixture, operation: u8) -> u64 {
    let tx = poc_govern(f, operation).await;
    let version = tx.info.version.0;
    let before = installed_at(&f.client, version - 1).await;
    let after = installed_at(&f.client, version).await;
    assert_eq!(after.epoch, before.epoch + 1);
    assert_eq!(events(&tx, "::stake::PoCEpochInstalled").len(), 1);
    assert_eq!(events(&tx, "::reconfiguration::NewEpochEvent").len(), 1);
    assert_eq!(
        integer(&events(&tx, "::stake::PoCEpochInstalled")[0].data["epoch"]),
        after.epoch as u128
    );
    assert_eq!(after.reward_context.2, after.reward_context.3);
    assert!(after.reward_context.3 > 0);
    assert_eq!(after.reward_context.5, 0);
    assert_eq!(
        integer(&after.reward_split["installed_native_reward_bps"]),
        0
    );
    assert_eq!(after.validators.active_validators.len(), 4);
    assert_eq!(after.validators.total_voting_power, 375);
    for member in &after.validators.active_validators {
        let expected = if member.account_address == f.owner.address() {
            75
        } else {
            100
        };
        assert_eq!(member.consensus_voting_power(), expected);
        let pool = pool_at(&f.client, member.account_address, version).await;
        assert_eq!(integer(&pool[0]), UNITS);
        assert_eq!(integer(&pool[2]), expected as u128);
    }
    poc_assert_clock(f, version, after.epoch).await;
    poc_no_plan(f, version).await;
    println!(
        "Bond setup commit: {} -> {}, period={}, version={version}",
        before.epoch,
        after.epoch,
        poc_period_index(after.epoch).0
    );
    version
}

async fn poc_wait_time(f: &Fixture, target: u64, budget: Duration) {
    timeout(budget, async {
        loop {
            if poc_now(f, poc_version(f).await).await >= target {
                break;
            }
            sleep(Duration::from_millis(200)).await;
        }
    })
    .await
    .unwrap_or_else(|_| panic!("Chain timestamp did not reach {target} within {budget:?}"));
}

/// 仅通过等待真实到期并执行公开换届，将余额转入 inactive。
/// 等待前记录旧锁仓截止时间，避免自动续期
/// 使准备步骤在未被察觉的情况下变为 inactive 余额为零的场景。
async fn poc_create_inactive(f: &Fixture) -> u64 {
    let tx = poc_owner(f, aptos_stdlib::stake_unlock(25)).await;
    let version = tx.info.version.0;
    poc_assert_balances(f, f.owner.address(), version, [75, 0, 0, 25]).await;
    let lock = integer(
        &poc_resource(f, f.owner.address(), "0x1::stake::StakePool", version).await
            ["locked_until_secs"],
    ) as u64;
    poc_wait_time(f, lock, Duration::from_secs(15)).await;
    let committed = poc_commit(f, 1).await;
    poc_assert_balances(f, f.owner.address(), committed, [75, 25, 0, 0]).await;
    let now = poc_now(f, committed).await;
    let renewed = poc_resource(f, f.owner.address(), "0x1::stake::StakePool", committed).await;
    assert_eq!(
        integer(&renewed["locked_until_secs"]),
        (now + LOCKUP_SECS) as u128
    );
    assert!(lock <= now);
    committed
}

async fn poc_preview(f: &Fixture, version: u64, cutoff: u64) -> Value {
    let current = installed_at(&f.client, version).await;
    let result = view(
        &f.client,
        "0x1::stake::preview_epoch_transition",
        vec![
            json!((current.epoch + 1).to_string()),
            json!(cutoff.to_string()),
        ],
        version,
    )
    .await;
    assert_eq!(result.len(), 1);
    assert_eq!(integer(&result[0]["reason"]), 0);
    result.into_iter().next().unwrap()
}

/// 每个预期值均从四类已知代币余额及不变的创世 units 推导，
/// 不使用生产预览函数生成预期。
async fn poc_assert_preview(f: &Fixture, version: u64, cutoff: u64, target_bond: u64) -> Value {
    let current = installed_at(&f.client, version).await;
    let next_epoch = current.epoch + 1;
    let (period, index, _) = poc_period_index(next_epoch);
    let raw_power = (UNITS * index / ((1u128 << 16) * INDEX_SCALE)) as u64;
    let preview = poc_preview(f, version, cutoff).await;
    assert_eq!(integer(&preview["epoch"]), next_epoch as u128);
    assert_eq!(integer(&preview["cutoff_secs"]), cutoff as u128);
    assert_eq!(integer(&preview["period"]), period as u128);
    assert_eq!(integer(&preview["period_index"]), index);
    let set = &preview["validator_set"];
    let members = set["active_validators"].as_array().unwrap();
    assert_eq!(members.len(), 4);
    assert!(set["pending_active"].as_array().unwrap().is_empty());
    assert!(set["pending_inactive"].as_array().unwrap().is_empty());
    assert_eq!(integer(&set["total_joining_power"]), 0);
    let mut total = 0u128;
    let mut increase = 0u128;
    for (position, old) in current.validators.active_validators.iter().enumerate() {
        let pool = old.account_address;
        let bond = if pool == f.owner.address() {
            target_bond
        } else {
            100
        };
        let expected = raw_power.min(bond).min(1000);
        let target = preview["targets"]
            .as_array()
            .unwrap()
            .iter()
            .find(|target| address(&target["pool"]) == pool)
            .unwrap();
        assert_eq!(integer(&target["units"]), UNITS);
        assert_eq!(integer(&target["power"]), expected as u128);
        assert_eq!(integer(&target["reward_base_octa"]), expected as u128);
        let member = &members[position];
        assert_eq!(address(&member["addr"]), pool);
        assert_eq!(integer(&member["voting_power"]), expected as u128);
        assert_eq!(
            integer(&member["config"]["validator_index"]),
            position as u128
        );
        assert_eq!(
            member["config"]["consensus_pubkey"],
            json!(format!(
                "0x{}",
                hex::encode(old.consensus_public_key().to_bytes())
            ))
        );
        total += expected as u128;
        increase += expected.saturating_sub(old.consensus_voting_power()) as u128;
    }
    assert!(
        increase <= current.validators.total_voting_power * 25 / 100,
        "Fixture must not bind the growth budget"
    );
    assert_eq!(integer(&set["total_voting_power"]), total);
    assert_eq!(preview["targets"].as_array().unwrap().len(), 4);
    println!("Bond preview: version={version}, target_epoch={next_epoch}, cutoff={cutoff}, target_bond={target_bond}, period={period}, index={index}, aggregate_power={raw_power}, total={total}");
    preview
}

#[derive(Debug, PartialEq)]
struct Stable {
    installed: InstalledSnapshot,
    data: BTreeMap<String, Value>,
}

/// 快照仅排除时间、区块表现、gas 钱包余额和费用计数，
/// 这些状态在 DKG 暂停时仍可变化；原始表项用于核对历史奖励。
async fn poc_stable(f: &Fixture, version: u64) -> Stable {
    let mut data = BTreeMap::new();
    for name in [
        "0x1::reconfiguration::Configuration",
        "0x1::reconfiguration_state::State",
        "0x1::poc_accounting::AccountingState",
        "0x1::poc_power_store::PowerStore",
        "0x1::poc_power_store::PeriodClock",
        "0x1::staking_config::StakingConfig",
    ] {
        data.insert(
            name.to_owned(),
            poc_resource(f, CORE_CODE_ADDRESS, name, version).await,
        );
    }
    let powers = address(&data["0x1::poc_power_store::PowerStore"]["users"]["handle"]);
    for pool in &f.pools {
        for name in [
            "stake::StakePool",
            "stake::ValidatorConfig",
            "poc_accounting::UserAllocation",
        ] {
            data.insert(
                format!("{pool}:{name}"),
                poc_resource(f, *pool, &format!("0x1::{name}"), version).await,
            );
        }
        data.insert(
            format!("{pool}:ledger"),
            ledger_at(&f.client, *pool, version).await,
        );
        data.insert(
            format!("{pool}:power"),
            f.client
                .get_table_item_at_version(
                    powers,
                    "address",
                    "0x1::poc_power_store::UserPowerInfo",
                    pool.to_hex_literal(),
                    version,
                )
                .await
                .unwrap()
                .into_inner(),
        );
        let positions = address(
            &data[&format!("{pool}:poc_accounting::UserAllocation")]["positions"]["handle"],
        );
        data.insert(
            format!("{pool}:position"),
            f.client
                .get_table_item_at_version(
                    positions,
                    "address",
                    "0x1::poc_accounting::Position",
                    pool.to_hex_literal(),
                    version,
                )
                .await
                .unwrap()
                .into_inner(),
        );
    }
    Stable {
        installed: installed_at(&f.client, version).await,
        data,
    }
}

#[tokio::test]
async fn poc_bond_preview_counts_four_balances_at_exact_expiry_cutoff() {
    let f = poc_fixture().await;
    let initial = poc_create_inactive(&f).await;
    let lock = integer(
        &poc_resource(&f, f.owner.address(), "0x1::stake::StakePool", initial).await
            ["locked_until_secs"],
    ) as u64;
    poc_assert_preview(&f, initial, lock - 1, 75).await;
    let added = poc_owner(&f, aptos_stdlib::stake_add_stake(20))
        .await
        .info
        .version
        .0;
    poc_assert_balances(&f, f.owner.address(), added, [75, 25, 20, 0]).await;
    poc_assert_preview(&f, added, lock - 1, 95).await;
    let unlocked = poc_owner(&f, aptos_stdlib::stake_unlock(15))
        .await
        .info
        .version
        .0;
    poc_assert_balances(&f, f.owner.address(), unlocked, [60, 25, 20, 15]).await;
    let before = poc_stable(&f, unlocked).await;
    // 60 active + 20 pending_active + 15 未到期的 pending_inactive；
    // 25 inactive 始终不计入保证金。截止时间恰好相等时按已到期处理。
    for (cutoff, bond) in [(lock - 1, 95), (lock, 80), (lock + 1, 80)] {
        poc_assert_preview(&f, unlocked, cutoff, bond).await;
    }
    assert_eq!(poc_stable(&f, poc_version(&f).await).await, before);
    poc_no_plan(&f, unlocked).await;
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

async fn poc_performance(f: &Fixture, version: u64) -> Value {
    poc_resource(
        f,
        CORE_CODE_ADDRESS,
        "0x1::stake::ValidatorPerformance",
        version,
    )
    .await
}

fn poc_assert_statistics_grow(before: &Value, after: &Value) -> u128 {
    let before = before["validators"].as_array().unwrap();
    let after = after["validators"].as_array().unwrap();
    assert_eq!(before.len(), 4);
    assert_eq!(after.len(), 4);
    let mut additional_successes = 0;
    for (old, new) in before.iter().zip(after) {
        for field in ["successful_proposals", "failed_proposals"] {
            assert!(integer(&new[field]) >= integer(&old[field]));
        }
        additional_successes +=
            integer(&new["successful_proposals"]) - integer(&old["successful_proposals"]);
    }
    additional_successes
}

/// 读取观测区间内的已提交交易，包括普通区块元数据交易。
/// 期间不得发生中途安装、标准化或奖励支付。
async fn poc_no_settlement_events(f: &Fixture, first: u64, last: u64, epoch: u64) {
    let mut start = first;
    let mut blocks = 0;
    while start <= last {
        let count = (last - start + 1).min(100) as u16;
        let transactions = f
            .client
            .get_transactions(Some(start), Some(count))
            .await
            .unwrap()
            .into_inner();
        assert_eq!(transactions.len(), count as usize);
        for transaction in transactions {
            let value = serde_json::to_value(transaction).unwrap();
            assert_eq!(integer(&value["version"]), start as u128);
            if let Some(events) = value.get("events").and_then(Value::as_array) {
                for event in events {
                    let name = event["type"].as_str().unwrap();
                    assert!(
                        !name.contains("::poc_")
                            && !name.contains("::stake::")
                            && !name.contains("::reconfiguration::"),
                        "Unexpected event while frozen: {event}"
                    );
                    if name.ends_with("::block::NewBlockEvent") {
                        assert_eq!(integer(&event["data"]["epoch"]), epoch as u128);
                        blocks += 1;
                    }
                }
            }
            start += 1;
        }
    }
    assert!(
        blocks >= 4,
        "At least four real blocks must span the nominal epochs"
    );
}

async fn poc_assert_settlement(
    f: &Fixture,
    tx: &UserTransaction,
    target: &ValidatorSet,
    cutoff: u64,
) {
    let version = tx.info.version.0;
    let before = installed_at(&f.client, version - 1).await;
    let after = installed_at(&f.client, version).await;
    assert_eq!(before.epoch, 60);
    assert_eq!(after.epoch, 61);
    assert_eq!(&after.validators, target);
    assert_eq!(before.reward_context.2, before.reward_context.3);
    assert!(before.reward_context.3 > 0);
    assert_eq!(before.reward_context.5, 0);
    assert_eq!(
        integer(&before.reward_split["installed_native_reward_bps"]),
        0
    );
    assert_eq!(
        integer(&after.reward_split["installed_native_reward_bps"]),
        0
    );
    assert_eq!(after.reward_context.2, before.reward_context.2);
    assert_eq!(after.reward_context.3, before.reward_context.3);
    assert_eq!(after.reward_context.5, 0);
    let stats = poc_performance(f, version - 1).await;
    let completion_time = poc_now(f, version).await;
    let mut total_reward = 0u64;
    assert_eq!(events(tx, "::stake::PoCRewardCredited").len(), 4);
    assert_eq!(events(tx, "::stake::PoCRewardSplit").len(), 4);
    for old in &before.validators.active_validators {
        let pool = old.account_address;
        let old_power = if pool == f.owner.address() { 75 } else { 100 };
        let new_power = if pool == f.owner.address() { 95 } else { 99 };
        assert_eq!(old.consensus_voting_power(), old_power);
        assert_eq!(
            target
                .active_validators
                .iter()
                .find(|v| v.account_address == pool)
                .unwrap()
                .consensus_voting_power(),
            new_power
        );
        let perf = &stats["validators"][old.config().validator_index as usize];
        let successes = integer(&perf["successful_proposals"]);
        let failures = integer(&perf["failed_proposals"]);
        let reward = if successes + failures == 0 {
            0
        } else {
            (old_power as u128 * successes * before.reward_context.2 as u128
                / ((successes + failures) * before.reward_context.3 as u128)) as u64
        };
        total_reward += reward;
        let old_pool = pool_at(&f.client, pool, version - 1).await;
        let new_pool = pool_at(&f.client, pool, version).await;
        assert_eq!(integer(&old_pool[0]), UNITS);
        assert_eq!(integer(&new_pool[0]), UNITS);
        assert_eq!(integer(&old_pool[2]), old_power as u128);
        assert_eq!(integer(&new_pool[2]), new_power as u128);
        assert_eq!(
            integer(&new_pool[3]) - integer(&old_pool[3]),
            reward as u128
        );
        let delta = (U256::from(reward).repr() << 128u32) / U256::from(UNITS).repr();
        assert_eq!(wide(&new_pool[4]).repr() - wide(&old_pool[4]).repr(), delta);
        assert_eq!(
            pool_event(tx, "::stake::PoCRewardCredited", pool).data,
            json!({"pool": pool.to_hex_literal(), "closing_epoch": "60", "reward_base_octa": old_power.to_string(),
                "inflation": reward.to_string(), "fee": "0", "delta_index": delta.to_string()})
        );
        assert_eq!(
            pool_event(tx, "::stake::PoCRewardSplit", pool).data,
            json!({"pool": pool.to_hex_literal(), "closing_epoch": "60", "native_reward_bps": "0",
                "total_inflation_octa": reward.to_string(), "active_native_reward_octa": "0",
                "pending_inactive_native_reward_octa": "0", "poc_inflation_octa": reward.to_string()})
        );
        let mut expected = poc_resource(f, pool, "0x1::stake::StakePool", version - 1).await;
        let active = integer(&expected["active"]["value"]);
        let pending_active = integer(&expected["pending_active"]["value"]);
        expected["active"]["value"] = json!((active + pending_active).to_string());
        expected["pending_active"]["value"] = json!("0");
        if integer(&expected["locked_until_secs"]) <= cutoff as u128 {
            let inactive = integer(&expected["inactive"]["value"]);
            let pending_inactive = integer(&expected["pending_inactive"]["value"]);
            expected["inactive"]["value"] = json!((inactive + pending_inactive).to_string());
            expected["pending_inactive"]["value"] = json!("0");
            expected["locked_until_secs"] = json!((completion_time + LOCKUP_SECS).to_string());
        }
        assert_eq!(
            poc_resource(f, pool, "0x1::stake::StakePool", version).await,
            expected
        );
    }
    assert!(total_reward > 0);
    let installed = events(tx, "::stake::PoCEpochInstalled");
    assert_eq!(installed.len(), 1);
    assert_eq!(
        installed[0].data,
        json!({"epoch": "61", "period": "1", "selected_count": "4", "total_power": "392"})
    );
    assert_eq!(events(tx, "::reconfiguration::NewEpochEvent").len(), 1);
    let period = events(tx, "::poc_power_store::PowerPeriodCommittedEvent");
    assert_eq!(period.len(), 1);
    assert_eq!(
        period[0].data,
        json!({"previous_period": "0", "current_period": "1"})
    );
    poc_assert_clock(f, version, 61).await;
    poc_no_plan(f, version).await;
    println!("Delayed finish used cached cutoff={cutoff}, actual completion={completion_time}, old_epoch=60/new_epoch=61, period0->1, next_boundary63, total_reward={total_reward}, version={version}");
}

#[tokio::test]
async fn poc_frozen_power_boundary_uses_original_bond_cutoff_after_real_expiry() {
    let f = poc_fixture().await;
    poc_create_inactive(&f).await;
    let advance_start = Instant::now();
    timeout(Duration::from_secs(180), async {
        loop {
            let current = installed_at(&f.client, poc_version(&f).await).await;
            assert!(current.epoch <= 59);
            if current.epoch == 59 {
                break;
            }
            poc_commit(&f, 1).await;
        }
    })
    .await
    .expect("Public synchronous preparation to epoch 59 exceeded 180 seconds");
    println!("Prepared E59 in {:?}", advance_start.elapsed());
    let v59 = poc_version(&f).await;
    let off = resource_at_version::<RandomnessConfigMoveStruct>(&f.client, v59).await;
    assert_eq!(
        off,
        RandomnessConfigMoveStruct::from(OnChainRandomnessConfig::Off)
    );
    // 此时尚无会话。旧的 Off 同步路径安装已缓冲的 V1 配置，
    // 只有后续 E60->61 调用才会启动真实 DKG。
    poc_pause(&f, true).await;
    let enabled = poc_commit(&f, 2).await;
    assert_eq!(installed_at(&f.client, enabled).await.epoch, 60);
    let on = resource_at_version::<RandomnessConfigMoveStruct>(&f.client, enabled).await;
    assert_eq!(
        on,
        RandomnessConfigMoveStruct::from(OnChainRandomnessConfig::default_enabled())
    );
    let watchdog = poc_resource(
        &f,
        CORE_CODE_ADDRESS,
        "0x1::epoch_timeout_config::EpochTimeoutConfig",
        enabled,
    )
    .await;
    assert_eq!(watchdog["force_end_grace_period_secs"], json!({"vec": []}));
    poc_assert_balances(&f, f.owner.address(), enabled, [75, 25, 0, 0]).await;
    // 若此前提交已续期该锁仓，同一秒内再次延长会被拒绝。
    // 仅等待至 now+30 严格大于旧截止时间。
    let old_lock = integer(
        &poc_resource(&f, f.owner.address(), "0x1::stake::StakePool", enabled).await
            ["locked_until_secs"],
    ) as u64;
    poc_wait_time(
        &f,
        old_lock.saturating_sub(LOCKUP_SECS) + 1,
        Duration::from_secs(3),
    )
    .await;
    let extended = poc_owner(&f, aptos_stdlib::stake_increase_lockup())
        .await
        .info
        .version
        .0;
    let lock = integer(
        &poc_resource(&f, f.owner.address(), "0x1::stake::StakePool", extended).await
            ["locked_until_secs"],
    ) as u64;
    assert_eq!(lock, poc_now(&f, extended).await + LOCKUP_SECS);
    assert!(lock > old_lock);
    poc_owner(&f, aptos_stdlib::stake_add_stake(20)).await;
    let prepared = poc_owner(&f, aptos_stdlib::stake_unlock(15))
        .await
        .info
        .version
        .0;
    poc_assert_balances(&f, f.owner.address(), prepared, [60, 25, 20, 15]).await;
    poc_assert_clock(&f, prepared, 60).await;
    // 冻结前，到期条件确实会改变独立模型计算的预期权重。
    poc_assert_preview(&f, prepared, lock - 1, 95).await;
    poc_assert_preview(&f, prepared, lock, 80).await;
    let start = poc_govern(&f, 3).await;
    let frozen_version = start.info.version.0;
    let frozen = poc_stable(&f, frozen_version).await;
    assert_eq!(frozen.installed.epoch, 60);
    assert!(events(&start, "::stake::PoCRewardCredited").is_empty());
    assert!(events(&start, "::stake::PoCEpochInstalled").is_empty());
    assert_eq!(
        installed_at(&f.client, frozen_version - 1).await,
        frozen.installed
    );
    let before_freeze = poc_stable(&f, frozen_version - 1).await;
    for (name, value) in &before_freeze.data {
        if name != "0x1::reconfiguration_state::State" {
            assert_eq!(value, &frozen.data[name], "Starting DKG changed {name}");
        }
    }
    let mut history_vaults = 0;
    for pool in &f.pools {
        history_vaults += integer(&pool_at(&f.client, *pool, frozen_version).await[3]);
    }
    assert!(
        history_vaults > 0,
        "Frozen reward preservation must include real historical rewards"
    );
    assert_eq!(
        integer(
            &poc_resource(
                &f,
                CORE_CODE_ADDRESS,
                "0x1::block::BlockResource",
                frozen_version
            )
            .await["epoch_interval"]
        ),
        NOMINAL_EPOCH_SECS as u128 * 1_000_000
    );
    let plan = poc_resource(
        &f,
        CORE_CODE_ADDRESS,
        "0x1::stake::EpochPlan",
        frozen_version,
    )
    .await;
    let cutoff = integer(&plan["data"]["cutoff_secs"]) as u64;
    assert!(
        cutoff < lock,
        "Preparation missed the required unexpired lock window"
    );
    let frozen_preview = poc_assert_preview(&f, frozen_version, cutoff, 95).await;
    assert_eq!(
        integer(&frozen_preview["validator_set"]["total_voting_power"]),
        392
    );
    let (target, fallback): (ValidatorSet, bool) = f
        .client
        .get_account_resource_at_version_bcs(
            CORE_CODE_ADDRESS,
            "0x1::stake::PrecomputedValidatorSet",
            frozen_version,
        )
        .await
        .unwrap()
        .into_inner();
    assert!(!fallback);
    let dkg = resource_at_version::<DKGState>(&f.client, frozen_version).await;
    let session = dkg
        .in_progress
        .as_ref()
        .expect("Expected real ordinary DKG for E61");
    assert_eq!(session.metadata.dealer_epoch, 60);
    assert_eq!(session.target_epoch(), 61);
    assert!(session.transcript.is_empty());
    assert_targets(&session.metadata.target_validator_set, &target);
    assert_targets(
        &session.metadata.dealer_validator_set,
        &frozen.installed.validators,
    );
    let context = frozen_context_at(&f.client, frozen_version).await;
    let statistics = poc_performance(&f, frozen_version).await;
    let start_time = Instant::now();
    let required_time = (lock + 1).max(cutoff + 4 * NOMINAL_EPOCH_SECS + 1);
    let observed = timeout(Duration::from_secs(60), async {
        let mut transfer_count = 0;
        loop {
            // 等待期间提交真实签名转账，持续验证旧委员会仍在运行。
            // 普通区块可能已推进观测到的链上时间。
            if transfer_count < 3 {
                success(
                    execute(
                        &f.client,
                        &f.root,
                        &f.factory,
                        aptos_stdlib::topo_coin_transfer(f.pools[1], 1),
                    )
                    .await,
                );
                transfer_count += 1;
            }
            let version = poc_version(&f).await;
            assert_eq!(poc_stable(&f, version).await, frozen);
            assert_eq!(frozen_context_at(&f.client, version).await, context);
            assert_eq!(
                resource_at_version::<DKGState>(&f.client, version).await,
                dkg
            );
            let successes =
                poc_assert_statistics_grow(&statistics, &poc_performance(&f, version).await);
            // 即使请求指定过去或未来的截止时间，也必须复用缓存。
            assert_eq!(poc_preview(&f, version, lock + 1).await, frozen_preview);
            if poc_now(&f, version).await >= required_time
                && start_time.elapsed() >= Duration::from_secs(4 * NOMINAL_EPOCH_SECS)
            {
                assert!(successes > 0);
                break version;
            }
            sleep(Duration::from_secs(1)).await;
        }
    })
    .await
    .expect("Frozen real-time observation exceeded 60 seconds");
    assert!(observed > frozen_version);
    poc_no_settlement_events(&f, frozen_version + 1, observed, 60).await;
    println!("Frozen boundary observed for {:?}: cutoff={cutoff}, old_lock={lock}, chain_time={}, at least four nominal 5s epochs elapsed while installed epoch stayed60/period0", start_time.elapsed(), poc_now(&f, observed).await);
    let finish = poc_govern(&f, 4).await;
    assert_eq!(poc_stable(&f, finish.info.version.0 - 1).await, frozen);
    assert_eq!(
        frozen_context_at(&f.client, finish.info.version.0 - 1).await,
        context
    );
    poc_assert_settlement(&f, &finish, &target, cutoff).await;
    let completed = finish.info.version.0;
    assert!(poc_now(&f, completed).await > lock);
    assert_eq!(
        integer(
            &poc_resource(
                &f,
                CORE_CODE_ADDRESS,
                "0x1::block::BlockResource",
                completed
            )
            .await["epoch_interval"]
        ),
        3_600_000_000
    );
    poc_assert_balances(&f, f.owner.address(), completed, [80, 25, 0, 15]).await;
    assert_eq!(
        integer(
            &poc_resource(&f, f.owner.address(), "0x1::stake::StakePool", completed).await
                ["locked_until_secs"]
        ),
        lock as u128
    );
    poc_pause(&f, false).await;
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
    let installed = installed_at(&f.client, completed).await;
    assert_eq!(
        installed_at(&f.client, progress.info.version.0).await,
        installed
    );
    poc_assert_clock(&f, progress.info.version.0, 61).await;
    for pool in &f.pools {
        assert_eq!(
            ledger_at(&f.client, *pool, completed).await,
            ledger_at(&f.client, *pool, progress.info.version.0).await
        );
    }
    let final_version = progress.info.version.0;
    let mut final_resources = BTreeMap::new();
    for name in [
        "0x1::poc_power_store::PowerStore",
        "0x1::poc_power_store::PeriodClock",
    ] {
        final_resources.insert(
            (CORE_CODE_ADDRESS, name),
            poc_resource(&f, CORE_CODE_ADDRESS, name, final_version).await,
        );
    }
    let mut final_ledgers = BTreeMap::new();
    for pool in &f.pools {
        final_resources.insert(
            (*pool, "0x1::stake::StakePool"),
            poc_resource(&f, *pool, "0x1::stake::StakePool", final_version).await,
        );
        final_ledgers.insert(*pool, ledger_at(&f.client, *pool, final_version).await);
    }
    for node in f.swarm.validators() {
        let client = node.rest_client_with_timeout(Duration::from_secs(10));
        timeout(
            Duration::from_secs(30),
            client.wait_for_version(progress.info.version.0),
        )
        .await
        .expect("Current committee catchup exceeded 30 seconds")
        .unwrap();
        assert_eq!(
            installed_at(&client, progress.info.version.0).await,
            installed
        );
        for ((owner, name), expected) in &final_resources {
            assert_eq!(
                optional_resource_at_version(&client, *owner, name, final_version)
                    .await
                    .unwrap()
                    .data,
                *expected
            );
        }
        for (pool, expected) in &final_ledgers {
            assert_eq!(ledger_at(&client, *pool, final_version).await, *expected);
        }
    }
}
