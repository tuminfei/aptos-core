// Copyright (c) Aptos Foundation
// Licensed pursuant to the Innovation-Enabling Source Code License, available at https://github.com/aptos-labs/aptos-core/blob/main/LICENSE

//! 使用生产字节码验证 PoC 准备、首次安装及事务回滚。
//! 本模块通过公开治理和用户接口执行；差分子模块单独说明内部回调的测试方式与覆盖范围。
//! 两者均不依赖仅供测试的框架字节码。

#[path = "poc_transition_differential.rs"]
mod transition_differential;

use crate::{stake::get_validator_set, tests::common};
use aptos_cached_packages::aptos_stdlib;
use aptos_crypto::HashValue;
use aptos_language_e2e_tests::{account::Account, executor::FakeExecutor};
use aptos_move_e2e_test_harness::{assert_success, MoveHarness};
use aptos_package_builder::PackageBuilder;
use aptos_types::{
    account_address::AccountAddress,
    block_metadata_ext::BlockMetadataExt,
    contract_event::FEE_STATEMENT_EVENT_TYPE,
    dkg::{chunky_dkg::ChunkyDKGState, DKGState, DKGTranscript},
    on_chain_config::{
        ChunkyDKGConfigMoveStruct, ConfigurationResource, OnChainChunkyDKGConfig, ValidatorSet,
    },
    stake_pool::StakePool,
    state_store::{
        state_key::{inner::StateKeyInner, StateKey},
        state_slot::StateSlot,
        state_storage_usage::StateStorageUsage,
        state_value::StateValue,
        StateView, StateViewId, StateViewResult, TStateView,
    },
    transaction::{
        ExecutionStatus, SignedTransaction, Transaction, TransactionArgument, TransactionOutput,
        TransactionStatus,
    },
    validator_txn::ValidatorTransaction,
};
use move_core_types::{
    int256::U256,
    parser::parse_struct_tag,
    vm_status::{AbortLocation, StatusCode, VMStatus},
};
use once_cell::sync::Lazy;
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, BTreeSet},
    sync::Mutex,
    time::Instant,
};
use topo_framework::{BuildOptions, BuiltPackage};

const RAW_POWER: u64 = 10_000;

#[derive(Clone, Debug, Deserialize, Serialize)]
struct PoolChangeMirror {
    epoch: u64,
    remove_units: u128,
    add_units: u128,
    refs: u64,
}

/// 仅用于隔离损坏状态；字段顺序严格对应生产 `poc_accounting::PoolLedger` 的 BCS 布局。
#[derive(Clone, Debug, Deserialize, Serialize)]
struct PoolLedgerMirror {
    epoch: u64,
    units: u128,
    changes: Vec<PoolChangeMirror>,
    reward_base_octa: u64,
    reward_epoch: u64,
    index: U256,
    checkpoints: AccountAddress,
    vault: u64,
}

static GOVERNANCE_SCRIPT: Lazy<Vec<u8>> =
    Lazy::new(|| compile_script("PoCTransactions", GOVERNANCE_SOURCE));

/// 按当前框架依赖编译治理脚本，使测试经过真实公开入口。
fn compile_script(name: &str, source: &str) -> Vec<u8> {
    let mut builder = PackageBuilder::new(name);
    builder.add_local_dep(
        "TopoFramework",
        &common::framework_dir_path("topo-framework").to_string_lossy(),
    );
    builder.add_source("governance", source);
    let directory = builder.write_to_temp().unwrap();
    BuiltPackage::build(
        directory.path().to_path_buf(),
        BuildOptions::move_2().set_latest_language(),
    )
    .unwrap()
    .extract_script_code()
    .remove(0)
}

const GOVERNANCE_SOURCE: &str = r#"
script {
    use std::features;
    use topo_std::fixed_point64;
    use topo_framework::consensus_config;
    use topo_framework::jwks;
    use topo_framework::poc_accounting;
    use topo_framework::poc_allocation;
    use topo_framework::gas_schedule;
    use topo_framework::epoch_timeout_config;
    use topo_framework::randomness_api_v0_config;
    use topo_framework::randomness_config;
    use topo_framework::reconfiguration;
    use topo_framework::reconfiguration_state;
    use topo_framework::stake;
    use topo_framework::staking_config;
    use topo_framework::storage_gas;
    use topo_framework::topo_governance;

    fun main(framework: &signer, operation: u8, value: u64) {
        if (operation == 0) {
            reconfiguration_state::initialize(framework);
            staking_config::update_voting_power_increase_limit(framework, 25);
            stake::set_transaction_fee_limit_per_epoch_per_pool(framework, 1000);
            if (features::periodical_reward_rate_decrease_enabled()) {
                staking_config::update_rewards_config(framework,
                    fixed_point64::create_from_rational(1, 100),
                    fixed_point64::create_from_rational(1, 100),
                    31536000, fixed_point64::create_from_rational(0, 1));
            } else {
                staking_config::update_rewards_rate(framework, 1, 100);
            };
            // 容量边界场景通过真实换届到达较小的受支持指数，
            // 不直接向 VM 存储注入标准化单位。
            let boundary_capacity = value == 3;
            let mixed_parallel = value == 4;
            poc_allocation::prepare_poc(framework,
                poc_accounting::new_power_params(100000000, 1, 1000000, 4),
                poc_accounting::new_deployment_limits(4, 4, 32, 8, 1000000, 1, 1, 1000, 100),
                1, reconfiguration::current_epoch() + (if (boundary_capacity || mixed_parallel) { 6 } else { 2 }),
                if (boundary_capacity) { 3 } else if (mixed_parallel) { 9995 } else { 10000 },
                if (boundary_capacity) { 2 } else { 200 },
                if (boundary_capacity || mixed_parallel) { 4 } else { 1 }, @topo_framework);
            // 原有账本和迁移边界用例将原生奖励占比设为零；五种换届路径的差分测试另设非零占比。
            stake::schedule_reward_split(framework, 0, reconfiguration::current_epoch() + 1);
        } else if (operation == 1 || operation == 2) {
            poc_allocation::schedule_power_params(framework,
                poc_accounting::new_power_params(100000000, value, 1000000, 4),
                reconfiguration::current_epoch() + 1);
            if (operation == 2) topo_governance::force_end_epoch(framework);
        } else if (operation == 3) {
            randomness_config::set_for_next_epoch(framework, randomness_config::new_v1(
                fixed_point64::create_from_rational(1, 2),
                fixed_point64::create_from_rational(2, 3)));
            topo_governance::force_end_epoch(framework);
        } else if (operation == 4) {
            features::change_feature_flags_for_next_epoch(framework, vector[], vector[]);
        } else if (operation == 5) {
            features::on_new_epoch(framework);
        } else if (operation == 6) {
            randomness_api_v0_config::on_new_epoch(framework);
        } else if (operation == 7) {
            staking_config::update_voting_power_increase_limit(framework, 30);
        } else if (operation == 8 || operation == 9 || operation == 10) {
            let item_curve = storage_gas::new_gas_curve(value, value, vector[]);
            let byte_curve = storage_gas::new_gas_curve(1, 1, vector[]);
            let config = storage_gas::new_storage_gas_config(
                storage_gas::new_usage_gas_config(1000000, item_curve, item_curve, item_curve),
                storage_gas::new_usage_gas_config(1000000, byte_curve, byte_curve, byte_curve));
            if (operation == 8) {
                gas_schedule::set_storage_gas_config(framework, config);
            } else {
                gas_schedule::set_storage_gas_config_for_next_epoch(framework, config);
                if (operation == 10) {
                    poc_allocation::schedule_power_params(framework,
                        poc_accounting::new_power_params(100000000, 10001, 1000000, 4),
                        reconfiguration::current_epoch() + 1);
                };
                topo_governance::force_end_epoch(framework);
            };
        } else if (operation == 11) {
            epoch_timeout_config::set_for_next_epoch(framework,
                epoch_timeout_config::new_with_grace_period(value));
            topo_governance::force_end_epoch(framework);
        } else if (operation == 12) {
            consensus_config::set(framework, vector[1]);
        } else if (operation == 13) {
            if (value == 0) {
                jwks::upsert_oidc_provider_for_next_epoch(framework, b"poc-freeze-test", b"https://poc.invalid");
            } else {
                jwks::remove_oidc_provider_for_next_epoch(framework, b"missing-provider");
            };
        } else if (operation == 14) {
            stake::schedule_reward_split(framework, value, reconfiguration::current_epoch() + 1);
        } else if (operation == 15) {
            stake::cancel_pending_reward_split(framework);
        } else if (operation == 16) {
            stake::schedule_reward_split(framework, value, reconfiguration::current_epoch() + 1);
            poc_allocation::schedule_power_params(framework,
                poc_accounting::new_power_params(100000000, 10001, 1000000, 4),
                reconfiguration::current_epoch() + 1);
            topo_governance::force_end_epoch(framework);
        } else {
            abort 99
        };
    }
}
"#;

struct PoCFixture {
    harness: MoveHarness,
    framework: Account,
    users: Vec<Account>,
    pools: Vec<AccountAddress>,
    /// 收集实际访问的表项，使回滚核对覆盖持仓、金库、版本和检查点引用数，而非仅比较表句柄。
    keys: BTreeSet<StateKey>,
}

/// 去重记录存储读取，包括未命中的读取，不改变 VM 执行。
/// 统计包含模块和配置读取，分别报告 key 与 value 的字节数。
struct ReadRecorder<'a, S> {
    inner: &'a S,
    reads: Mutex<BTreeMap<StateKey, usize>>,
}

impl<S: StateView> TStateView for ReadRecorder<'_, S> {
    type Key = StateKey;

    fn id(&self) -> StateViewId {
        self.inner.id()
    }

    fn get_usage(&self) -> StateViewResult<StateStorageUsage> {
        self.inner.get_usage()
    }

    fn next_version(&self) -> u64 {
        self.inner.next_version()
    }

    fn get_state_slot(&self, key: &StateKey) -> StateViewResult<StateSlot> {
        let slot = self.inner.get_state_slot(key)?;
        self.reads.lock().unwrap().insert(
            key.clone(),
            slot.as_state_value_opt()
                .map_or(0, |value| value.bytes().len()),
        );
        Ok(slot)
    }

    fn get_state_value(&self, key: &StateKey) -> StateViewResult<Option<StateValue>> {
        let value = self.inner.get_state_value(key)?;
        self.reads.lock().unwrap().insert(
            key.clone(),
            value.as_ref().map_or(0, |value| value.bytes().len()),
        );
        Ok(value)
    }
}

impl PoCFixture {
    fn prepared() -> Self {
        let mut harness = MoveHarness::new_with_validators(4);
        let framework = harness.topo_framework_account();
        Self::prepare_existing(harness, framework)
    }

    fn prepare_existing(harness: MoveHarness, framework: Account) -> Self {
        Self::prepare_existing_with_manifest(harness, framework, 0)
    }

    /// 用显式测试清单准备已有原生链，保留真实账户、质押及配置状态。
    fn prepare_existing_with_manifest(
        mut harness: MoveHarness,
        framework: Account,
        manifest: u64,
    ) -> Self {
        harness.set_default_gas_unit_price(0);
        let pools = get_validator_set(&harness).active_validators();
        let users = (0..pools.len())
            .map(|i| {
                harness.new_account_at(
                    AccountAddress::from_hex_literal(&format!("0x{:x}", 0x100 + i)).unwrap(),
                )
            })
            .collect();
        let mut fixture = Self {
            harness,
            framework,
            users,
            pools,
            keys: BTreeSet::new(),
        };
        for name in [
            "poc_accounting::AccountingState",
            "poc_power_store::PowerStore",
            "poc_power_store::PeriodClock",
            "poc_reward_split::RewardSplitConfig",
            "stake::ValidatorSet",
            "stake::EpochPlan",
            "stake::PrecomputedValidatorSet",
            "stake::InstalledRewardContext",
            "dkg::DKGState",
            "reconfiguration::Configuration",
            "reconfiguration_state::State",
            "features::PendingFeatureFreeze",
            "features::PendingFeatures",
            "features::Features",
            "staking_config::StakingConfig",
            "storage_gas::StorageGasConfig",
            "storage_gas::StorageGas",
            "config_buffer::PendingConfigs",
            "consensus_config::ConsensusConfig",
            "jwks::SupportedOIDCProviders",
            "randomness_api_v0_config::RequiredGasDeposit",
            "epoch_timeout_config::EpochTimeoutConfig",
        ] {
            fixture.keys.insert(
                StateKey::resource(
                    &AccountAddress::ONE,
                    &parse_struct_tag(&format!("0x1::{name}")).unwrap(),
                )
                .unwrap(),
            );
        }
        fixture.governance_success(0, manifest);
        for pool in fixture.pools.clone() {
            let txn = fixture.harness.create_transaction_payload(
                &fixture.framework,
                aptos_stdlib::poc_allocation_enable_pool(pool),
            );
            let output = fixture.harness.run_raw(txn);
            fixture.record_success(output);
        }
        let addresses: Vec<_> = fixture.users.iter().map(|user| *user.address()).collect();
        let txn = fixture.harness.create_transaction_payload(
            &fixture.framework,
            aptos_stdlib::poc_power_store_stage_batch_update(1, addresses, vec![
                RAW_POWER;
                fixture.users.len()
            ]),
        );
        let output = fixture.harness.run_raw(txn);
        fixture.record_success(output);
        for i in 0..fixture.users.len() {
            let txn = fixture.harness.create_transaction_payload(
                &fixture.users[i],
                aptos_stdlib::poc_allocation_set_allocations(vec![fixture.pools[i]], vec![10_000]),
            );
            let output = fixture.harness.run_raw(txn);
            fixture.record_success(output);
            fixture.keys.insert(
                StateKey::resource(
                    fixture.users[i].address(),
                    &parse_struct_tag("0x1::poc_accounting::UserAllocation").unwrap(),
                )
                .unwrap(),
            );
        }
        fixture
    }

    fn installed() -> Self {
        Self::prepared().install()
    }

    /// 经真实换届完成首次 PoC 安装，并核对最后一个原生 Epoch 的收益归属。
    fn install(mut self) -> Self {
        let fixture = &mut self;
        let before = fixture.epoch();
        fixture.force_epoch();
        assert_eq!(fixture.epoch(), before + 1);
        assert!(!fixture.poc_enabled());
        fixture.force_epoch();
        assert_eq!(fixture.epoch(), before + 2);
        assert!(fixture.poc_enabled());
        let set = get_validator_set(&fixture.harness);
        assert_eq!(
            set.total_voting_power,
            (fixture.pools.len() as u128) * u128::from(RAW_POWER),
        );
        assert_eq!(set.active_validators(), fixture.pools);
        assert!(set
            .active_validators
            .iter()
            .all(|validator| validator.consensus_voting_power() == RAW_POWER));
        for pool in fixture.pools.clone() {
            let values = fixture
                .harness
                .execute_view_function(
                    "0x1::poc_accounting::get_pool".parse().unwrap(),
                    vec![],
                    vec![bcs::to_bytes(&pool).unwrap()],
                )
                .values
                .unwrap();
            // 最后一个原生 Epoch 的奖励只能进入原生池，不能同时记入新 PoC 金库。
            assert_eq!(bcs::from_bytes::<u64>(&values[3]).unwrap(), 0);
        }
        self
    }

    fn epoch(&self) -> u64 {
        self.harness
            .read_resource::<ConfigurationResource>(
                &AccountAddress::ONE,
                parse_struct_tag("0x1::reconfiguration::Configuration").unwrap(),
            )
            .unwrap()
            .epoch()
    }

    fn poc_enabled(&mut self) -> bool {
        let result = self.harness.execute_view_function(
            "0x1::stake::is_poc_enabled".parse().unwrap(),
            vec![],
            vec![],
        );
        bcs::from_bytes(&result.values.unwrap()[0]).unwrap()
    }

    fn governance(&mut self, operation: u8, value: u64) -> TransactionOutput {
        let txn =
            self.harness
                .create_script(&self.framework, GOVERNANCE_SCRIPT.clone(), vec![], vec![
                    TransactionArgument::U8(operation),
                    TransactionArgument::U64(value),
                ]);
        self.run_measured(&format!("governance_{operation}"), txn)
    }

    fn governance_success(&mut self, operation: u8, value: u64) {
        let output = self.governance(operation, value);
        self.record_success(output);
    }

    /// 记录成功交易触及的资源和表项，供后续完整回滚快照使用。
    fn record_success(&mut self, output: TransactionOutput) {
        assert_success!(*output.status());
        self.keys.extend(
            output
                .write_set()
                .write_op_iter()
                .filter(|(key, _)| matches!(key.inner(), StateKeyInner::TableItem { .. }))
                .map(|(key, _)| key.clone()),
        );
    }

    /// 只测量显式测试规模，编译不计入耗时；结果不代表生产候选上限或分布式共识延迟。
    fn run_measured(&mut self, operation: &str, txn: SignedTransaction) -> TransactionOutput {
        let transaction_bytes = bcs::to_bytes(&txn).unwrap().len();
        let started = Instant::now();
        let output = self.harness.run_raw(txn);
        let execution_us = started.elapsed().as_micros();
        println!(
            "POC_COST operation={operation} validators={} transaction_bytes={transaction_bytes} \
             gas_used={} write_count={} write_bytes={} events={} event_bytes={} \
             execution_us={execution_us} status={:?}",
            self.pools.len(),
            output.gas_used(),
            output.write_set().write_op_iter().count(),
            bcs::to_bytes(output.write_set()).unwrap().len(),
            output.events().len(),
            bcs::to_bytes(output.events()).unwrap().len(),
            output.status(),
        );
        output
    }

    fn force_epoch(&mut self) {
        self.harness.new_block_with_metadata(self.pools[0], vec![]);
        let txn = self.harness.create_entry_function(
            &self.framework,
            "0x1::topo_governance::force_end_epoch".parse().unwrap(),
            vec![],
            vec![],
        );
        let output = self.run_measured("force_epoch", txn);
        self.record_success(output);
    }

    /// 构造真实 V1 区块元数据，验证等待 DKG 时的超时提交路径。
    fn randomness_block(&mut self, elapsed_secs: u64) -> TransactionOutput {
        self.harness.fast_forward(elapsed_secs);
        // 默认辅助函数生成 V0 元数据，只走同步换届；V1 才会进入生产 block_prologue_ext
        // 以及 DKG 超时保护和完成驱动。
        let metadata = BlockMetadataExt::new_v1(
            HashValue::zero(),
            self.epoch(),
            0,
            self.pools[0],
            vec![0; self.pools.len().div_ceil(8)],
            vec![],
            self.harness.executor.get_block_time(),
            None,
        );
        let started = Instant::now();
        let output = self
            .harness
            .executor
            .execute_transaction_block(vec![Transaction::BlockMetadataExt(metadata)])
            .unwrap()
            .remove(0);
        assert_success!(*output.status());
        self.harness.executor.apply_write_set(output.write_set());
        self.harness
            .executor
            .append_events(output.events().to_vec());
        println!(
            "POC_WATCHDOG elapsed_secs={elapsed_secs} execution_us={} write_count={} events={}",
            started.elapsed().as_micros(),
            output.write_set().write_op_iter().count(),
            output.events().len()
        );
        output
    }

    /// 保存已访问资源和表项的完整字节，并记录缺失项，检查失败后是否有未回滚的写入。
    fn snapshot(&self) -> BTreeMap<StateKey, Option<Vec<u8>>> {
        self.keys
            .iter()
            .map(|key| (key.clone(), self.harness.read_state_value_bytes(key)))
            .collect()
    }

    fn resource(&self, name: &str) -> Option<Vec<u8>> {
        self.harness.read_resource_raw(
            &AccountAddress::ONE,
            parse_struct_tag(&format!("0x1::{name}")).unwrap(),
        )
    }

    /// 定位生产账本中的池表项；直接改写仅用于构造公开入口无法产生的损坏状态。
    fn pool_ledger(&self, pool: AccountAddress) -> (StateKey, PoolLedgerMirror) {
        let matches = self
            .keys
            .iter()
            .filter_map(|key| match key.inner() {
                StateKeyInner::TableItem { key: item, .. }
                    if bcs::from_bytes::<AccountAddress>(item).ok() == Some(pool) =>
                {
                    self.harness
                        .read_state_value_bytes(key)
                        .and_then(|bytes| bcs::from_bytes::<PoolLedgerMirror>(&bytes).ok())
                        .map(|ledger| (key.clone(), ledger))
                },
                _ => None,
            })
            .collect::<Vec<_>>();
        assert_eq!(matches.len(), 1, "池账本表项必须唯一");
        matches.into_iter().next().unwrap()
    }
}

/// 业务中止后，框架仍正常扣费并更新序号，但不应保留业务写入或业务事件。
fn assert_move_abort(output: &TransactionOutput) {
    assert!(
        matches!(
            output.status(),
            TransactionStatus::Keep(ExecutionStatus::MoveAbort { .. })
        ),
        "unexpected transaction status: {:?}",
        output.status()
    );
    // Move 中止后 VM 仍执行费用扣除和序号更新，不能将这些正常收尾误判为回滚失败。
    assert!(output
        .events()
        .iter()
        .all(|event| event.type_tag() == &*FEE_STATEMENT_EVENT_TYPE));
    assert!(output
        .write_set()
        .write_op_iter()
        .all(|(key, _)| !matches!(key.inner(), StateKeyInner::TableItem { .. })));
}

/// 同时核对中止模块与错误码，避免因其他错误提前中止而误判为通过。
fn assert_move_abort_at(output: &TransactionOutput, module: &str, code: u64) {
    assert_move_abort(output);
    assert!(
        matches!(
            output.status(),
            TransactionStatus::Keep(ExecutionStatus::MoveAbort {
                location: AbortLocation::Module(id), code: actual, ..
            }) if id.name().as_str() == module && *actual == code
        ),
        "unexpected abort: {:?}",
        output.status()
    );
}

#[test]
/// 生产 `stake::add_stake` 须在取币后以精确错误拒绝容量上限加一，并回滚全部业务状态。
fn poc_add_stake_native_capacity_abort_is_atomic_in_production_vm() {
    let mut fixture = PoCFixture::installed();
    fixture.governance_success(14, 3000);
    fixture.force_epoch();

    let pool_address = fixture.pools[0];
    // 测试账户使用创世密钥接管同地址签名；只重建账户和钱包，不改池的 OwnerCapability。
    let owner = fixture.harness.new_account_at(pool_address);
    let stake_tag = parse_struct_tag("0x1::stake::StakePool").unwrap();
    let stake_key = StateKey::resource(&pool_address, &stake_tag).unwrap();
    let owner_cap_key = StateKey::resource(
        &pool_address,
        &parse_struct_tag("0x1::stake::OwnerCapability").unwrap(),
    )
    .unwrap();
    let wallet_key = StateKey::resource(
        &pool_address,
        &parse_struct_tag("0x1::coin::CoinStore<0x1::topo_coin::TopoCoin>").unwrap(),
    )
    .unwrap();
    fixture
        .keys
        .extend([stake_key.clone(), owner_cap_key.clone(), wallet_key.clone()]);

    let upper_bound: u64 = bcs::from_bytes(
        &fixture
            .harness
            .execute_view_function(
                "0x1::stake::get_native_reward_upper_bound".parse().unwrap(),
                vec![],
                vec![bcs::to_bytes(&pool_address).unwrap()],
            )
            .values
            .unwrap()[0],
    )
    .unwrap();
    assert!(upper_bound > 0);

    // 四类余额均非零；本金加当期原生奖励上界恰好为 u64 上限，追加 1 后只超出一位。
    let stake_bytes = fixture.harness.read_state_value_bytes(&stake_key).unwrap();
    let mut stake_pool: StakePool = bcs::from_bytes(&stake_bytes).unwrap();
    stake_pool.active = 101;
    stake_pool.pending_active = 11;
    stake_pool.pending_inactive = 13;
    stake_pool.inactive = u64::MAX - upper_bound - 125;
    assert_eq!(
        u128::from(stake_pool.active)
            + u128::from(stake_pool.inactive)
            + u128::from(stake_pool.pending_active)
            + u128::from(stake_pool.pending_inactive)
            + u128::from(upper_bound),
        u128::from(u64::MAX)
    );
    fixture
        .harness
        .executor
        .write_state_value(stake_key, bcs::to_bytes(&stake_pool).unwrap());

    let before = fixture.snapshot();
    assert!(fixture.resource("stake::EpochPlan").is_none());
    assert!(fixture.resource("stake::PrecomputedValidatorSet").is_none());
    let txn = fixture
        .harness
        .create_transaction_payload(&owner, aptos_stdlib::stake_add_stake(1));
    let output = fixture.run_measured("add_stake_native_capacity_rejected", txn);
    assert_move_abort_at(&output, "stake", 0x10025);

    // 序列号和费用事件属于 VM 收尾；池、四类余额、所有权、钱包、计划及 PVS 必须逐字节不变。
    assert_eq!(fixture.snapshot(), before);
    assert!(fixture.resource("stake::EpochPlan").is_none());
    assert!(fixture.resource("stake::PrecomputedValidatorSet").is_none());
    assert!(output.events().iter().all(|event| {
        event.type_tag() == &*FEE_STATEMENT_EVENT_TYPE
            && !event
                .type_tag()
                .to_canonical_string()
                .ends_with("::stake::AddStakeEvent")
    }));
}

fn poc_pool_state(fixture: &mut PoCFixture, pool: AccountAddress) -> (u128, u64, U256) {
    let values = fixture
        .harness
        .execute_view_function(
            "0x1::poc_accounting::get_pool".parse().unwrap(),
            vec![],
            vec![bcs::to_bytes(&pool).unwrap()],
        )
        .values
        .unwrap();
    (
        bcs::from_bytes(&values[0]).unwrap(),
        bcs::from_bytes(&values[3]).unwrap(),
        bcs::from_bytes(&values[4]).unwrap(),
    )
}

/// 用独立宽整数模型核对一个 Epoch 的通胀、费用分流、奖励指数和金库守恒。
fn assert_poc_epoch_reward_model(
    fixture: &mut PoCFixture,
    output: &TransactionOutput,
    native_reward_bps: u64,
    before: &BTreeMap<AccountAddress, (u128, u64, U256)>,
) {
    let credited: Vec<(AccountAddress, u64, u64, u64, u64, U256)> = output
        .events()
        .iter()
        .filter(|event| {
            event
                .type_tag()
                .to_canonical_string()
                .contains("PoCRewardCredited")
        })
        .map(|event| bcs::from_bytes(event.event_data()).unwrap())
        .collect();
    let split: Vec<(AccountAddress, u64, u64, u64, u64, u64, u64)> = output
        .events()
        .iter()
        .filter(|event| {
            event
                .type_tag()
                .to_canonical_string()
                .ends_with("::stake::PoCRewardSplit")
        })
        .map(|event| bcs::from_bytes(event.event_data()).unwrap())
        .collect();
    let native_fees: BTreeMap<AccountAddress, u64> = output
        .events()
        .iter()
        .filter(|event| {
            event
                .type_tag()
                .to_canonical_string()
                .ends_with("::stake::DistributeTransactionFee")
        })
        .map(|event| bcs::from_bytes(event.event_data()).unwrap())
        .collect();
    assert_eq!(credited.len(), fixture.pools.len());
    assert_eq!(split.len(), fixture.pools.len());

    let q: U256 = "340282366920938463463374607431768211456".parse().unwrap();
    for reward in credited {
        let (pool, closing_epoch, _, poc_inflation, poc_fee, delta_index) = reward;
        let split = split
            .iter()
            .find(|event| event.0 == pool)
            .expect("每个池必须有一条通胀分流事件");
        assert_eq!(split.1, closing_epoch);
        assert_eq!(split.2, native_reward_bps);
        let expected_native_inflation = split.3 * native_reward_bps / 10_000;
        assert_eq!(split.4 + split.5, expected_native_inflation);
        assert_eq!(split.6, split.3 - expected_native_inflation);
        assert_eq!(poc_inflation, split.6);

        // 原生费用事件只在金额非零时发出，PoC 入账事件始终携带本期 PoC 费用。
        let native_fee = native_fees.get(&pool).copied().unwrap_or(0);
        let total_fee = native_fee + poc_fee;
        assert_eq!(native_fee, total_fee * native_reward_bps / 10_000);
        let (units, old_vault, old_index) = before[&pool];
        let poc_reward = poc_inflation + poc_fee;
        let expected_delta = if poc_reward == 0 {
            U256::from(0u8)
        } else {
            U256::checked_div(
                U256::checked_mul(U256::from(poc_reward), q).unwrap(),
                U256::from(units),
            )
            .unwrap()
        };
        assert_eq!(delta_index, expected_delta);
        let (_, new_vault, new_index) = poc_pool_state(fixture, pool);
        assert_eq!(new_vault, old_vault + poc_reward);
        assert_eq!(
            new_index,
            U256::checked_add(old_index, expected_delta).unwrap()
        );
    }
}

#[test]
/// 验证原生准备、首次切换及目标不合格后的修复，延期期间不推进 PoC 状态。
fn poc_preparation_first_install_and_deferred_repair() {
    let mut fixture = PoCFixture::installed();
    let epoch = fixture.epoch();
    fixture.governance_success(1, RAW_POWER + 1);
    let before = fixture.snapshot();
    // 区块继续成功执行并保留旧委员会，只更新旧期表现和时间；
    // PoC 配置、表项和周期时钟保持不变。
    fixture.harness.new_epoch();
    assert_eq!(fixture.epoch(), epoch);
    assert_eq!(fixture.snapshot(), before);
    fixture.harness.new_epoch();
    assert_eq!(fixture.snapshot(), before);
    fixture.governance_success(1, 1);
    fixture.force_epoch();
    assert_eq!(fixture.epoch(), epoch + 1);
    assert_eq!(
        get_validator_set(&fixture.harness).total_voting_power,
        u128::from(4 * RAW_POWER)
    );
}

#[test]
/// 通过公开分配入口将目标总权重降为零，普通和 Chunky 入口均延期，修复后只提交一次。
fn poc_zero_total_power_defers_sixteen_blocks_without_partial_state() {
    assert_zero_total_power_defers_without_partial_state(false);
    assert_zero_total_power_defers_without_partial_state(true);
}

fn assert_zero_total_power_defers_without_partial_state(chunky_enabled: bool) {
    let mut fixture = PoCFixture::installed();
    let chunky_config_key = StateKey::resource(
        &AccountAddress::ONE,
        &parse_struct_tag("0x1::chunky_dkg_config::ChunkyDKGConfig").unwrap(),
    )
    .unwrap();
    if !chunky_enabled {
        // 只替换链上配置资源，使真实 V1 区块分别进入普通与 Chunky try_start 分支。
        let config = ChunkyDKGConfigMoveStruct::from(OnChainChunkyDKGConfig::default_disabled());
        fixture
            .harness
            .executor
            .write_state_value(chunky_config_key, bcs::to_bytes(&config).unwrap());
    }
    let installed_chunky_config: ChunkyDKGConfigMoveStruct = bcs::from_bytes(
        &fixture
            .resource("chunky_dkg_config::ChunkyDKGConfig")
            .unwrap(),
    )
    .unwrap();
    assert_eq!(
        OnChainChunkyDKGConfig::try_from(installed_chunky_config)
            .unwrap()
            .chunky_dkg_enabled(),
        chunky_enabled
    );
    let epoch = fixture.epoch();
    // 当前委员会仍保留已安装 units；空分配只将 E+1 的目标 units 排定为零。
    // 这是真实用户签名交易，不修改账本字节或绕过可见性。
    for user in fixture.users.clone() {
        let txn = fixture.harness.create_transaction_payload(
            &user,
            aptos_stdlib::poc_allocation_set_allocations(vec![], vec![]),
        );
        let output = fixture.run_measured("schedule_zero_target", txn);
        fixture.record_success(output);
    }
    for pool in fixture.pools.clone() {
        let ledger = fixture.pool_ledger(pool).1;
        assert!(ledger.units > 0);
        assert_eq!(ledger.changes.len(), 1);
        assert_eq!(ledger.changes[0].epoch, epoch + 1);
        assert_eq!(ledger.changes[0].remove_units, ledger.units);
        assert_eq!(ledger.changes[0].add_units, 0);
    }

    let validator_set = fixture.resource("stake::ValidatorSet").unwrap();
    let period_clock = fixture.resource("poc_power_store::PeriodClock").unwrap();
    let reward_context = fixture.resource("stake::InstalledRewardContext").unwrap();
    let stakes = fixture
        .pools
        .iter()
        .map(|pool| {
            fixture
                .harness
                .read_resource_raw(pool, parse_struct_tag("0x1::stake::StakePool").unwrap())
                .unwrap()
        })
        .collect::<Vec<_>>();
    let ledgers = fixture
        .pools
        .iter()
        .map(|pool| bcs::to_bytes(&fixture.pool_ledger(*pool).1).unwrap())
        .collect::<Vec<_>>();
    let dkg = fixture.resource("dkg::DKGState").unwrap();
    let chunky_dkg = fixture.resource("chunky_dkg::ChunkyDKGState").unwrap();
    assert!(bcs::from_bytes::<DKGState>(&dkg)
        .unwrap()
        .in_progress
        .is_none());
    assert!(bcs::from_bytes::<ChunkyDKGState>(&chunky_dkg)
        .unwrap()
        .in_progress
        .is_none());
    let interval: u64 = bcs::from_bytes(
        &fixture
            .harness
            .execute_view_function(
                "0x1::block::get_epoch_interval_secs".parse().unwrap(),
                vec![],
                vec![],
            )
            .values
            .unwrap()[0],
    )
    .unwrap();
    let time_before = fixture.harness.executor.get_block_time();

    // 首块跨过实际 Epoch 间隔，后续块在未换届的旧 Epoch 中继续触发同一生产入口。
    fixture.harness.set_default_gas_unit_price(1);
    for attempt in 0..16 {
        let block_output = fixture.randomness_block(if attempt == 0 { interval + 1 } else { 1 });
        assert!(block_output.events().iter().all(|event| {
            let name = event.type_tag().to_canonical_string();
            !name.contains("PoCRewardCredited") && !name.contains("PoCEpochInstalled")
        }));
        let txn = fixture.harness.create_entry_function(
            &fixture.framework,
            "0x1::topo_governance::reconfigure".parse().unwrap(),
            vec![],
            vec![],
        );
        let output = fixture.run_measured("zero_power_deferred", txn);
        assert_move_abort_at(&output, "reconfiguration_with_dkg", 0x30001);
        assert_eq!(fixture.epoch(), epoch);
        assert_eq!(
            fixture.resource("stake::ValidatorSet").unwrap(),
            validator_set
        );
        assert_eq!(
            fixture.resource("poc_power_store::PeriodClock").unwrap(),
            period_clock
        );
        assert_eq!(
            fixture.resource("stake::InstalledRewardContext").unwrap(),
            reward_context
        );
        assert!(fixture.resource("stake::EpochPlan").is_none());
        assert!(fixture.resource("stake::PrecomputedValidatorSet").is_none());
        assert_eq!(fixture.resource("dkg::DKGState").unwrap(), dkg);
        assert_eq!(
            fixture.resource("chunky_dkg::ChunkyDKGState").unwrap(),
            chunky_dkg
        );
        for (index, pool) in fixture.pools.iter().enumerate() {
            assert_eq!(
                fixture
                    .harness
                    .read_resource_raw(pool, parse_struct_tag("0x1::stake::StakePool").unwrap())
                    .unwrap(),
                stakes[index]
            );
            assert_eq!(
                bcs::to_bytes(&fixture.pool_ledger(*pool).1).unwrap(),
                ledgers[index]
            );
        }
    }
    assert!(fixture.harness.executor.get_block_time() > time_before);

    // 在同一 E+1 生效点覆盖回原分配；旧委员会的当前 units 始终非零，
    // 因此旧期奖励可正常结算，目标预检也会立即恢复。
    for i in 0..fixture.users.len() {
        let txn = fixture.harness.create_transaction_payload(
            &fixture.users[i],
            aptos_stdlib::poc_allocation_set_allocations(vec![fixture.pools[i]], vec![10_000]),
        );
        let output = fixture.run_measured("repair_zero_target", txn);
        fixture.record_success(output);
    }
    for pool in fixture.pools.clone() {
        let ledger = fixture.pool_ledger(pool).1;
        assert!(ledger.units > 0);
        assert!(ledger.changes.is_empty());
    }

    let txn = fixture.harness.create_entry_function(
        &fixture.framework,
        "0x1::topo_governance::force_end_epoch".parse().unwrap(),
        vec![],
        vec![],
    );
    let output = fixture.run_measured("commit_repaired_zero_target", txn);
    assert_success!(*output.status());
    assert_eq!(
        output
            .events()
            .iter()
            .filter(|event| {
                event
                    .type_tag()
                    .to_canonical_string()
                    .contains("PoCEpochInstalled")
            })
            .count(),
        1
    );
    fixture.record_success(output);
    assert_eq!(fixture.epoch(), epoch + 1);
    let installed = get_validator_set(&fixture.harness);
    assert_eq!(installed.active_validators(), fixture.pools);
    assert_eq!(installed.total_voting_power, u128::from(4 * RAW_POWER));
    assert!(fixture.resource("stake::EpochPlan").is_none());
    assert!(fixture.resource("stake::PrecomputedValidatorSet").is_none());
}

#[test]
/// 治理事务先修改配置再要求换届；目标不合格时须回滚整笔事务的配置和 Epoch 变更。
fn poc_governance_failure_rolls_back_parameters_and_epoch() {
    let mut fixture = PoCFixture::installed();
    fixture
        .harness
        .new_block_with_metadata(fixture.pools[0], vec![]);
    let before = fixture.snapshot();
    let output = fixture.governance(2, RAW_POWER + 1);
    assert_move_abort(&output);
    assert_eq!(fixture.snapshot(), before);
    // PoC 准备后须通过完整换届流程安装配置，不能经即时存储 gas 入口仅安装部分配置。
    let output = fixture.governance(8, 321);
    assert_move_abort_at(&output, "gas_schedule", 0x30004);
    assert_eq!(fixture.snapshot(), before);
    // 组合事务先写存储配置，再让目标预检失败；存储配置和随后写入的非法 PoC 参数必须一起回滚。
    let output = fixture.governance(10, 321);
    assert_move_abort(&output);
    assert_eq!(fixture.snapshot(), before);
    // 先排定原生奖励占比，再因目标委员会预检失败而回滚时，奖励分配配置也须恢复到事务前的状态。
    let output = fixture.governance(16, 6000);
    assert_move_abort(&output);
    assert_eq!(fixture.snapshot(), before);
    let epoch = fixture.epoch();
    fixture.governance_success(9, 321);
    assert_eq!(fixture.epoch(), epoch + 1);
    let installed: [u64; 6] =
        bcs::from_bytes(&fixture.resource("storage_gas::StorageGas").unwrap()).unwrap();
    assert_eq!(installed, [321, 321, 321, 1, 1, 1]);
}

#[test]
/// 冻结时直接设置和安装配置均被拒绝，历史领奖可执行，但重复池输入必须整体回滚。
fn poc_frozen_direct_setters_and_claim_rollback() {
    let mut fixture = PoCFixture::installed();
    // 先结算有成功提案的 PoC Epoch，留下冻结期间可以领取的历史奖励。
    fixture.force_epoch();
    fixture
        .harness
        .new_block_with_metadata(fixture.pools[0], vec![]);
    fixture.governance_success(3, 0);
    fixture
        .harness
        .new_block_with_metadata(fixture.pools[0], vec![]);
    // 先缓存 OIDC 配置，覆盖冻结 setter 先 extract、再由底层 upsert 拒绝的回滚路径。
    fixture.governance_success(13, 0);
    fixture.governance_success(14, 6000);
    let txn = fixture.harness.create_entry_function(
        &fixture.framework,
        "0x1::topo_governance::reconfigure".parse().unwrap(),
        vec![],
        vec![],
    );
    let output = fixture.run_measured("begin_dkg", txn);
    fixture.record_success(output);
    let plan = fixture
        .resource("stake::EpochPlan")
        .expect("DKG must freeze a plan");
    let pvs = fixture.resource("stake::PrecomputedValidatorSet").unwrap();
    let epoch = fixture.epoch();
    for operation in [3, 4, 5, 6, 7, 8, 9, 10, 12, 13, 14, 15] {
        let before = fixture.snapshot();
        let output = fixture.governance(operation, 321);
        if operation == 4 || operation == 5 {
            assert_move_abort_at(&output, "features", 0x30004);
        } else if operation == 8 {
            // 去掉外层重复检查后，原有 PoC 同步配置限制先报错。
            assert_move_abort_at(&output, "gas_schedule", 0x30004);
        } else if operation == 12 {
            // 创世专用入口仍由链状态检查拒绝，不能在运行链上修改配置。
            assert_move_abort_at(&output, "chain_status", 0x30001);
        } else if operation == 14 || operation == 15 {
            assert_move_abort_at(&output, "poc_reward_split", 0x30003);
        } else {
            assert_move_abort_at(&output, "reconfiguration_state", 0x30002);
        }
        assert_eq!(fixture.snapshot(), before);
    }
    // 发现重复池时，对首个池的奖励支付和检查点引用释放也须随整笔交易回滚。
    let before = fixture.snapshot();
    let txn = fixture.harness.create_transaction_payload(
        &fixture.users[0],
        aptos_stdlib::poc_allocation_claim_rewards(vec![fixture.pools[0], fixture.pools[0]]),
    );
    let output = fixture.run_measured("claim_duplicate_rejected", txn);
    assert_move_abort_at(&output, "poc_accounting", 0x10003);
    assert_eq!(fixture.snapshot(), before);
    let txn = fixture.harness.create_transaction_payload(
        &fixture.users[0],
        aptos_stdlib::poc_allocation_claim_rewards(vec![fixture.pools[0]]),
    );
    let output = fixture.run_measured("claim_frozen", txn);
    assert!(output.events().iter().any(|event| event
        .type_tag()
        .to_canonical_string()
        .contains("PoCRewardClaimed")));
    fixture.record_success(output);
    assert_eq!(fixture.resource("stake::EpochPlan").unwrap(), plan);
    assert_eq!(
        fixture.resource("stake::PrecomputedValidatorSet").unwrap(),
        pvs
    );
    assert_eq!(fixture.epoch(), epoch);
    fixture.force_epoch();
    assert_eq!(fixture.epoch(), epoch + 1);
    assert!(fixture.resource("stake::EpochPlan").is_none());
    assert!(fixture.resource("stake::PrecomputedValidatorSet").is_none());
}

#[test]
/// 五池领取须在访问池表项前拒绝；金库不足时权益、检查点、金库和业务事件须原子回滚。
fn poc_claim_limit_and_underfunded_vault_are_atomic() {
    let mut fixture = PoCFixture::installed();
    fixture
        .harness
        .new_block_with_metadata(fixture.pools[0], vec![]);
    fixture.force_epoch();

    let position = fixture
        .harness
        .execute_view_function(
            "0x1::poc_accounting::get_position".parse().unwrap(),
            vec![],
            vec![
                bcs::to_bytes(fixture.users[0].address()).unwrap(),
                bcs::to_bytes(&fixture.pools[0]).unwrap(),
            ],
        )
        .values
        .unwrap();
    let claimable = bcs::from_bytes::<u64>(&position[2]).unwrap();
    assert!(claimable > 0, "隔离损坏前必须存在非零可领权益");

    // 长度检查必须先于逐池访问；第五项可使用不存在的池地址。
    let five_pools = fixture
        .pools
        .iter()
        .copied()
        .chain(std::iter::once(
            AccountAddress::from_hex_literal("0xcafe").unwrap(),
        ))
        .collect();
    let before_limit = fixture.snapshot();
    let txn = fixture.harness.create_transaction_payload(
        &fixture.users[0],
        aptos_stdlib::poc_allocation_claim_rewards(five_pools),
    );
    let output = fixture.run_measured("claim_5_pools_rejected", txn);
    assert_move_abort_at(&output, "poc_accounting", 0x20004);
    assert_eq!(fixture.snapshot(), before_limit);

    let pool = fixture.pools[0];
    let (ledger_key, mut ledger) = fixture.pool_ledger(pool);
    assert!(ledger.vault >= claimable);
    let healthy_ledger = bcs::to_bytes(&ledger).unwrap();
    ledger.vault = 0;
    fixture
        .harness
        .executor
        .write_state_value(ledger_key.clone(), bcs::to_bytes(&ledger).unwrap());
    let underfunded = fixture.snapshot();
    let txn = fixture.harness.create_transaction_payload(
        &fixture.users[0],
        aptos_stdlib::poc_allocation_claim_rewards(vec![pool]),
    );
    let output = fixture.run_measured("claim_underfunded_vault_rejected", txn);
    assert_move_abort_at(&output, "poc_accounting", 0x3000E);
    assert_eq!(fixture.snapshot(), underfunded);
    assert!(output.events().iter().all(|event| !event
        .type_tag()
        .to_canonical_string()
        .contains("PoCRewardClaimed")));

    // 恢复隔离注入前的生产账本后，同一权益应能完整领取。
    fixture
        .harness
        .executor
        .write_state_value(ledger_key, healthy_ledger);
    let txn = fixture.harness.create_transaction_payload(
        &fixture.users[0],
        aptos_stdlib::poc_allocation_claim_rewards(vec![pool]),
    );
    let output = fixture.run_measured("claim_after_vault_repair", txn);
    let claimed = output
        .events()
        .iter()
        .find(|event| {
            event
                .type_tag()
                .to_canonical_string()
                .contains("PoCRewardClaimed")
        })
        .map(|event| {
            bcs::from_bytes::<(AccountAddress, AccountAddress, u64)>(event.event_data()).unwrap()
        })
        .unwrap();
    assert_eq!(claimed, (*fixture.users[0].address(), pool, claimable));
    fixture.record_success(output);
}

#[test]
/// 隔离注入计划/PVS 不成对或计划 Epoch 错配，失败事务不得改写任何已跟踪业务状态。
fn poc_corrupt_epoch_plan_states_abort_and_roll_back() {
    let plan_key = StateKey::resource(
        &AccountAddress::ONE,
        &parse_struct_tag("0x1::stake::EpochPlan").unwrap(),
    )
    .unwrap();
    let pvs_key = StateKey::resource(
        &AccountAddress::ONE,
        &parse_struct_tag("0x1::stake::PrecomputedValidatorSet").unwrap(),
    )
    .unwrap();

    for corruption in ["only_plan", "only_pvs", "wrong_epoch"] {
        let mut fixture = PoCFixture::installed();
        fixture
            .harness
            .new_block_with_metadata(fixture.pools[0], vec![]);
        fixture.governance_success(3, 0);
        fixture
            .harness
            .new_block_with_metadata(fixture.pools[0], vec![]);
        let txn = fixture.harness.create_entry_function(
            &fixture.framework,
            "0x1::topo_governance::reconfigure".parse().unwrap(),
            vec![],
            vec![],
        );
        let output = fixture.run_measured("begin_corrupt_plan_test", txn);
        fixture.record_success(output);
        assert!(fixture.resource("stake::EpochPlan").is_some());
        assert!(fixture.resource("stake::PrecomputedValidatorSet").is_some());

        if corruption == "only_plan" {
            fixture.harness.executor.remove_state_value(&pvs_key);
        } else if corruption == "only_pvs" {
            fixture.harness.executor.remove_state_value(&plan_key);
        } else {
            let mut plan = fixture.resource("stake::EpochPlan").unwrap();
            let wrong_epoch = fixture.epoch() + 2;
            // EpochPlanData 的首字段是目标 Epoch；仅修改该字段，保留计划其余字节及 PVS。
            plan[..8].copy_from_slice(&wrong_epoch.to_le_bytes());
            fixture
                .harness
                .executor
                .write_state_value(plan_key.clone(), plan);
        }

        let before = fixture.snapshot();
        let txn = fixture.harness.create_entry_function(
            &fixture.framework,
            "0x1::topo_governance::reconfigure".parse().unwrap(),
            vec![],
            vec![],
        );
        let output = fixture.run_measured(&format!("reject_{corruption}"), txn);
        assert_move_abort_at(&output, "stake", 0x30020);
        assert_eq!(fixture.snapshot(), before);
        assert_eq!(
            fixture.resource("stake::EpochPlan").is_some(),
            corruption != "only_pvs"
        );
        assert_eq!(
            fixture.resource("stake::PrecomputedValidatorSet").is_some(),
            corruption != "only_plan"
        );
    }
}

#[test]
/// 真实区块超时路径只能安装已缓存目标一次，并清理计划、会话和冻结令牌。
fn poc_block_metadata_watchdog_commits_cached_plan_once() {
    let mut fixture = PoCFixture::installed();
    fixture
        .harness
        .new_block_with_metadata(fixture.pools[0], vec![]);
    fixture.governance_success(3, 0);
    let interval: u64 = bcs::from_bytes(
        &fixture
            .harness
            .execute_view_function(
                "0x1::block::get_epoch_interval_secs".parse().unwrap(),
                vec![],
                vec![],
            )
            .values
            .unwrap()[0],
    )
    .unwrap();
    fixture
        .harness
        .new_block_with_metadata(fixture.pools[0], vec![]);
    fixture.governance_success(11, interval + 10);
    fixture
        .harness
        .new_block_with_metadata(fixture.pools[0], vec![]);
    // 让冻结目标明显区别于当前委员会，才能检测提交时是否误用旧集合或重新选举。
    let txn = fixture.harness.create_transaction_payload(
        &fixture.users[0],
        aptos_stdlib::poc_allocation_set_allocations(
            vec![fixture.pools[0], fixture.pools[1]],
            vec![9000, 1000],
        ),
    );
    let output = fixture.harness.run_raw(txn);
    fixture.record_success(output);
    let txn = fixture.harness.create_entry_function(
        &fixture.framework,
        "0x1::topo_governance::reconfigure".parse().unwrap(),
        vec![],
        vec![],
    );
    let output = fixture.run_measured("begin_dkg_watchdog", txn);
    fixture.record_success(output);
    let closing_epoch = fixture.epoch();
    let plan = fixture.resource("stake::EpochPlan").unwrap();
    let pvs = fixture.resource("stake::PrecomputedValidatorSet").unwrap();
    let (target, fallback): (ValidatorSet, bool) = bcs::from_bytes(&pvs).unwrap();
    assert!(!fallback);
    assert_ne!(target, get_validator_set(&fixture.harness));
    let before_clock: [u64; 4] =
        bcs::from_bytes(&fixture.resource("poc_power_store::PeriodClock").unwrap()).unwrap();
    let before = fixture.snapshot();
    let output = fixture.randomness_block(interval);
    assert_eq!(fixture.epoch(), closing_epoch);
    assert_eq!(fixture.resource("stake::EpochPlan").unwrap(), plan);
    assert_eq!(
        fixture.resource("stake::PrecomputedValidatorSet").unwrap(),
        pvs
    );
    assert_eq!(fixture.snapshot(), before);
    assert!(!output.events().iter().any(|event| event
        .type_tag()
        .to_canonical_string()
        .contains("PoCRewardCredited")));

    let output = fixture.randomness_block(10);
    let forced: Vec<_> = output
        .events()
        .iter()
        .filter(|event| {
            event
                .type_tag()
                .to_canonical_string()
                .contains("ForceEndEpochEvent")
        })
        .collect();
    assert_eq!(forced.len(), 1);
    let (variant, epoch, dkg_incomplete, _, deadline, now): (u8, u64, bool, bool, u64, u64) =
        bcs::from_bytes(forced[0].event_data()).unwrap();
    assert_eq!(variant, 0);
    assert_eq!(epoch, closing_epoch);
    assert!(dkg_incomplete && now >= deadline);
    let credited: Vec<(AccountAddress, u64, u64, u64, u64, U256)> = output
        .events()
        .iter()
        .filter(|event| {
            event
                .type_tag()
                .to_canonical_string()
                .contains("PoCRewardCredited")
        })
        .map(|event| bcs::from_bytes(event.event_data()).unwrap())
        .collect();
    assert_eq!(credited.len(), fixture.pools.len());
    assert!(credited
        .iter()
        .all(|(_, epoch, _, _, _, _)| *epoch == closing_epoch));
    assert_eq!(
        credited
            .iter()
            .map(|(pool, ..)| pool)
            .collect::<BTreeSet<_>>()
            .len(),
        fixture.pools.len()
    );
    assert_eq!(fixture.epoch(), closing_epoch + 1);
    assert_eq!(get_validator_set(&fixture.harness), target);
    assert!(fixture.resource("stake::EpochPlan").is_none());
    assert!(fixture.resource("stake::PrecomputedValidatorSet").is_none());
    assert!(fixture.resource("features::PendingFeatureFreeze").is_none());
    let after_clock: [u64; 4] =
        bcs::from_bytes(&fixture.resource("poc_power_store::PeriodClock").unwrap()).unwrap();
    assert_eq!(after_clock[1], before_clock[1] + 1);
    let context: (u64, bool, u64, u64, bool, u64) =
        bcs::from_bytes(&fixture.resource("stake::InstalledRewardContext").unwrap()).unwrap();
    assert_eq!(context.0, closing_epoch + 1);
    assert!(context.1);
    for validator in &target.active_validators {
        let values = fixture
            .harness
            .execute_view_function(
                "0x1::poc_accounting::get_pool".parse().unwrap(),
                vec![],
                vec![bcs::to_bytes(validator.account_address()).unwrap()],
            )
            .values
            .unwrap();
        assert_eq!(
            bcs::from_bytes::<u64>(&values[2]).unwrap(),
            validator.consensus_voting_power()
        );
    }
    // 后续区块时间仍超过旧会话截止时间，但不能再次提交计划或重复发放奖励。
    let after = fixture.snapshot();
    let output = fixture.randomness_block(1);
    assert_eq!(fixture.snapshot(), after);
    assert!(!output.events().iter().any(|event| {
        let name = event.type_tag().to_canonical_string();
        name.contains("PoCRewardCredited")
            || name.contains("PoCEpochInstalled")
            || name.contains("ForceEndEpochEvent")
    }));

    // 通过生产验证者交易入口送入旧会话结果。超时提交已经清理 DKG 会话，
    // 因此必须在解析 transcript 前以“无进行中会话”精确拒绝，且不能改写新 Epoch。
    let stale_result = ValidatorTransaction::DKGResult(DKGTranscript::new(
        closing_epoch,
        fixture.pools[0],
        vec![],
    ));
    let before_stale = fixture.snapshot();
    let (status, output) = fixture
        .harness
        .executor
        .execute_validator_transaction_with_vm_status(stale_result)
        .unwrap();
    assert!(matches!(status, VMStatus::MoveAbort {
        location: AbortLocation::Script,
        code: 0x30002,
        ..
    }));
    assert_eq!(
        output.status(),
        &TransactionStatus::Discard(StatusCode::ABORTED)
    );
    assert!(output.write_set().is_empty());
    assert!(output.events().is_empty());
    assert_eq!(fixture.snapshot(), before_stale);
    assert_eq!(fixture.epoch(), closing_epoch + 1);
    assert!(fixture.resource("stake::EpochPlan").is_none());
    assert!(fixture.resource("stake::PrecomputedValidatorSet").is_none());
    let dkg: aptos_types::dkg::DKGState =
        bcs::from_bytes(&fixture.resource("dkg::DKGState").unwrap()).unwrap();
    assert!(dkg.in_progress.is_none());
}

#[test]
/// 比较同一组热门池变更在顺序与并行执行下的完整输出，并验证集中度不合格后可撤回分配以修复目标。
fn poc_parallel_hot_pool() {
    // BothComparison 对同一区块分别执行顺序模式和 Block-STM，比较完整输出后才应用结果。
    // 耗时包含两次执行，不能直接换算成节点吞吐。
    let executor = FakeExecutor::from_head_genesis_with_count(4).set_parallel();
    let mut harness = MoveHarness::new_with_executor(executor);
    let framework = harness.topo_framework_account();
    let mut fixture = PoCFixture::prepare_existing(harness, framework).install();
    let initial_epoch = fixture.epoch();
    for concentrate in [true, false] {
        let mut txns = Vec::new();
        for i in 0..fixture.users.len() {
            let pool = fixture.pools[if concentrate { 0 } else { i }];
            txns.push(fixture.harness.create_transaction_payload(
                &fixture.users[i],
                aptos_stdlib::poc_allocation_set_allocations(vec![pool], vec![10_000]),
            ));
        }
        let transaction_bytes: Vec<_> = txns
            .iter()
            .map(|txn| bcs::to_bytes(txn).unwrap().len())
            .collect();
        let started = Instant::now();
        let outputs = fixture.harness.run_block_get_output(txns);
        println!(
            "POC_HOTSPOT concentrate={concentrate} users={} pools={} comparison_us={} \
             executor=BothComparison",
            fixture.users.len(),
            fixture.pools.len(),
            started.elapsed().as_micros(),
        );
        assert_eq!(outputs.len(), fixture.users.len());
        for (i, output) in outputs.into_iter().enumerate() {
            println!(
                "POC_HOTSPOT txn={i} transaction_bytes={} gas_used={} write_count={} \
                 write_bytes={} events={} event_bytes={}",
                transaction_bytes[i],
                output.gas_used(),
                output.write_set().write_op_iter().count(),
                bcs::to_bytes(output.write_set()).unwrap().len(),
                output.events().len(),
                bcs::to_bytes(output.events()).unwrap().len(),
            );
            fixture.record_success(output);
        }
        if concentrate {
            let before = fixture.snapshot();
            fixture.harness.new_epoch();
            assert_eq!(fixture.epoch(), initial_epoch);
            assert_eq!(fixture.snapshot(), before);
        }
    }
    fixture.force_epoch();
    assert_eq!(fixture.epoch(), initial_epoch + 1);
    assert_eq!(
        get_validator_set(&fixture.harness).active_validators(),
        fixture.pools
    );
    assert_eq!(
        get_validator_set(&fixture.harness).total_voting_power,
        u128::from(4 * RAW_POWER),
    );
}

#[test]
/// 多个固定种子在生产 VM 中混合上传、分配、领奖和失败交易，并跨衰减边界核对两种奖励分流。
fn poc_parallel_mixed_history_across_decay_and_reward_splits() {
    for seed in [1u64, 7, 31337] {
        // BothComparison 会从同一状态分别执行顺序模式和 Block-STM，并逐交易比较完整输出。
        let executor = FakeExecutor::from_head_genesis_with_count(4).set_parallel();
        let mut harness = MoveHarness::new_with_executor(executor);
        let framework = harness.topo_framework_account();
        let mut fixture = PoCFixture::prepare_existing_with_manifest(harness, framework, 4);
        for _ in 0..6 {
            fixture.force_epoch();
        }
        assert!(fixture.poc_enabled());
        fixture.harness.set_default_gas_unit_price(1);

        let initial_clock = fixture
            .harness
            .execute_view_function(
                "0x1::poc_power_store::get_normalization_clock"
                    .parse()
                    .unwrap(),
                vec![],
                vec![],
            )
            .values
            .unwrap();
        let initial_period: u64 = bcs::from_bytes(&initial_clock[1]).unwrap();
        let initial_index: u128 = bcs::from_bytes(&initial_clock[3]).unwrap();
        let target_period = initial_period + 1;

        for phase in 0..3 {
            let mut transactions: Vec<(&str, SignedTransaction)> = Vec::new();
            if phase == 0 {
                let powers = (0..fixture.users.len())
                    .map(|i| RAW_POWER * (2 + ((seed + i as u64) % 3)))
                    .collect::<Vec<_>>();
                transactions.push((
                    "upload",
                    fixture.harness.create_transaction_payload(
                        &fixture.framework,
                        aptos_stdlib::poc_power_store_stage_batch_update(
                            target_period,
                            fixture.users.iter().map(|user| *user.address()).collect(),
                            powers,
                        ),
                    ),
                ));
            }
            let first_pool = if phase == 0 {
                fixture.pools[1]
            } else {
                fixture.pools[0]
            };
            let second_pool = if phase == 0 {
                fixture.pools[0]
            } else {
                fixture.pools[1]
            };
            transactions.push((
                "allocation_0",
                fixture.harness.create_transaction_payload(
                    &fixture.users[0],
                    aptos_stdlib::poc_allocation_set_allocations(vec![first_pool], vec![10_000]),
                ),
            ));
            transactions.push((
                "allocation_1",
                fixture.harness.create_transaction_payload(
                    &fixture.users[1],
                    aptos_stdlib::poc_allocation_set_allocations(vec![second_pool], vec![10_000]),
                ),
            ));
            transactions.push((
                "claim",
                fixture.harness.create_transaction_payload(
                    &fixture.users[2],
                    aptos_stdlib::poc_allocation_claim_rewards(vec![fixture.pools[2]]),
                ),
            ));
            transactions.push((
                "invalid_allocation",
                fixture.harness.create_transaction_payload(
                    &fixture.users[3],
                    aptos_stdlib::poc_allocation_set_allocations(
                        vec![fixture.pools[3], fixture.pools[0]],
                        vec![10_000, 1],
                    ),
                ),
            ));

            // 仅重排不同签名者的交易；同一账户的序列号顺序不因种子改变。
            transactions.sort_by_key(|(name, _)| {
                name.bytes().fold(seed ^ phase, |value, byte| {
                    value
                        .wrapping_mul(6364136223846793005)
                        .wrapping_add(byte as u64)
                })
            });
            let outputs = fixture
                .harness
                .run_block_get_output(transactions.iter().map(|(_, txn)| txn.clone()).collect());
            assert_eq!(outputs.len(), transactions.len());
            for ((name, _), output) in transactions.into_iter().zip(outputs) {
                if name == "invalid_allocation" {
                    assert_move_abort_at(&output, "poc_accounting", 0x10002);
                } else {
                    if name == "upload" {
                        assert_eq!(
                            output
                                .events()
                                .iter()
                                .filter(|event| event
                                    .type_tag()
                                    .to_canonical_string()
                                    .contains("PowerNormalized"))
                                .count(),
                            fixture.users.len(),
                        );
                    }
                    if phase == 1 && name == "claim" {
                        assert!(output.events().iter().any(|event| event
                            .type_tag()
                            .to_canonical_string()
                            .contains("PoCRewardClaimed")));
                    }
                    fixture.record_success(output);
                }
            }

            // 第一期排定 3000，使当前旧期仍按 0 结算，下一期才按新快照结算。
            if phase == 0 {
                fixture.governance_success(14, 3000);
            }
            fixture.harness.new_block_with_metadata(
                fixture.pools[if phase == 0 {
                    2
                } else {
                    (seed as usize + phase as usize) % 4
                }],
                vec![],
            );
            let before = fixture
                .pools
                .clone()
                .into_iter()
                .map(|pool| (pool, poc_pool_state(&mut fixture, pool)))
                .collect::<BTreeMap<_, _>>();
            let epoch_before = fixture.epoch();
            let txn = fixture.harness.create_entry_function(
                &fixture.framework,
                "0x1::topo_governance::force_end_epoch".parse().unwrap(),
                vec![],
                vec![],
            );
            let output = fixture.run_measured("parallel_mixed_force_epoch", txn);
            assert_poc_epoch_reward_model(
                &mut fixture,
                &output,
                if phase == 0 { 0 } else { 3000 },
                &before,
            );
            fixture.record_success(output);
            assert_eq!(fixture.epoch(), epoch_before + 1);
        }

        let final_clock = fixture
            .harness
            .execute_view_function(
                "0x1::poc_power_store::get_normalization_clock"
                    .parse()
                    .unwrap(),
                vec![],
                vec![],
            )
            .values
            .unwrap();
        let final_period: u64 = bcs::from_bytes(&final_clock[1]).unwrap();
        let final_index: u128 = bcs::from_bytes(&final_clock[3]).unwrap();
        assert_eq!(final_period, initial_period + 1);
        assert_eq!(final_index, initial_index * 9995 / 10_000);
    }
}

#[test]
/// 在显式清单上限下测量上传、分配和领奖，并验证超过批次上限时原子拒绝。
fn poc_manifest_max_upload_allocation_and_claim() {
    let mut fixture = PoCFixture::installed();
    // 这些是测试清单的确定值，不代表生产容量；长度为四个 Epoch 的算力周期同时覆盖
    // E+1 的比例变更和独立的未来算力版本边界。
    for i in fixture.users.len()..32 {
        let user = fixture.harness.new_account_at(
            AccountAddress::from_hex_literal(&format!("0x{:x}", 0x200 + i)).unwrap(),
        );
        fixture.keys.insert(
            StateKey::resource(
                user.address(),
                &parse_struct_tag("0x1::poc_accounting::UserAllocation").unwrap(),
            )
            .unwrap(),
        );
        fixture.users.push(user);
    }
    let addresses: Vec<_> = fixture.users.iter().map(|user| *user.address()).collect();
    let period: u64 = bcs::from_bytes(
        &fixture
            .harness
            .execute_view_function(
                "0x1::poc_power_store::get_current_period".parse().unwrap(),
                vec![],
                vec![],
            )
            .values
            .unwrap()[0],
    )
    .unwrap();
    let txn = fixture.harness.create_transaction_payload(
        &fixture.framework,
        aptos_stdlib::poc_power_store_set_power_period_in_epochs(4),
    );
    let output = fixture.harness.run_raw(txn);
    fixture.record_success(output);
    let txn = fixture.harness.create_transaction_payload(
        &fixture.framework,
        aptos_stdlib::poc_power_store_stage_batch_update(
            period + 1,
            addresses.clone(),
            vec![RAW_POWER; 32],
        ),
    );
    let output = fixture.run_measured("seed_32_power_versions", txn);
    fixture.record_success(output);
    for i in 0..32 {
        let txn = fixture.harness.create_transaction_payload(
            &fixture.users[i],
            aptos_stdlib::poc_allocation_set_allocations(fixture.pools.clone(), vec![2500; 4]),
        );
        let output = fixture.harness.run_raw(txn);
        fixture.record_success(output);
    }
    fixture.force_epoch();

    // 用户数只比批次上限多一，也必须在修改任何版本或持仓前拒绝。
    let before = fixture.snapshot();
    let mut too_many = addresses.clone();
    too_many.push(addresses[0]);
    let txn = fixture.harness.create_transaction_payload(
        &fixture.framework,
        aptos_stdlib::poc_power_store_stage_batch_update(period + 2, too_many, vec![
            2 * RAW_POWER;
            33
        ]),
    );
    let output = fixture.run_measured("upload_33_rejected", txn);
    assert_move_abort_at(&output, "poc_power_store", 0x1000D);
    assert_eq!(fixture.snapshot(), before);
    let txn = fixture.harness.create_transaction_payload(
        &fixture.framework,
        aptos_stdlib::poc_power_store_stage_batch_update(period + 2, addresses, vec![
            2 * RAW_POWER;
            32
        ]),
    );
    let output = fixture.run_measured("upload_32_users_4_pools", txn);
    assert_eq!(
        output
            .events()
            .iter()
            .filter(|event| event
                .type_tag()
                .to_canonical_string()
                .contains("PowerNormalized"))
            .count(),
        32,
    );
    fixture.record_success(output);
    for i in 0..32 {
        let ratios: Vec<u64> = (0..4).map(|p| (1 + ((p + i) % 4) as u64) * 1000).collect();
        let txn = fixture.harness.create_transaction_payload(
            &fixture.users[i],
            aptos_stdlib::poc_allocation_set_allocations(fixture.pools.clone(), ratios),
        );
        let output = fixture.run_measured(&format!("replace_4_pools_user_{i}"), txn);
        fixture.record_success(output);
    }
    for pool in fixture.pools.clone() {
        fixture.harness.new_block_with_metadata(pool, vec![]);
    }
    fixture.force_epoch();
    let expected: u64 = fixture
        .pools
        .clone()
        .iter()
        .map(|pool| {
            let values = fixture
                .harness
                .execute_view_function(
                    "0x1::poc_accounting::get_position".parse().unwrap(),
                    vec![],
                    vec![
                        bcs::to_bytes(fixture.users[0].address()).unwrap(),
                        bcs::to_bytes(pool).unwrap(),
                    ],
                )
                .values
                .unwrap();
            bcs::from_bytes::<u64>(&values[2]).unwrap()
        })
        .sum();
    assert!(expected > 0);
    let txn = fixture.harness.create_transaction_payload(
        &fixture.users[0],
        aptos_stdlib::poc_allocation_claim_rewards(fixture.pools.clone()),
    );
    let output = fixture.run_measured("claim_4_pools", txn);
    let claimed: Vec<(AccountAddress, AccountAddress, u64)> = output
        .events()
        .iter()
        .filter(|event| {
            event
                .type_tag()
                .to_canonical_string()
                .contains("PoCRewardClaimed")
        })
        .map(|event| bcs::from_bytes(event.event_data()).unwrap())
        .collect();
    assert_eq!(claimed.len(), 4);
    assert_eq!(
        claimed.iter().map(|(_, _, amount)| *amount).sum::<u64>(),
        expected
    );
    fixture.record_success(output);
}

#[test]
/// 当前和 E+1 均合法、只有 B 超容量时，整批上传（含前面合法项）必须回滚。
fn poc_boundary_only_capacity_failure_rolls_back_batch() {
    fn pool_units(fixture: &mut PoCFixture, pool: AccountAddress, epoch: u64) -> u128 {
        let values = fixture
            .harness
            .execute_view_function(
                "0x1::poc_accounting::preview_pool_units".parse().unwrap(),
                vec![],
                vec![
                    bcs::to_bytes(&pool).unwrap(),
                    bcs::to_bytes(&epoch).unwrap(),
                ],
            )
            .values
            .unwrap();
        bcs::from_bytes(&values[0]).unwrap()
    }

    let mut harness = MoveHarness::new_with_validators(4);
    let framework = harness.topo_framework_account();
    let mut fixture = PoCFixture::prepare_existing_with_manifest(harness, framework, 3);
    for _ in 0..6 {
        fixture.force_epoch();
    }
    assert!(fixture.poc_enabled());
    let epoch = fixture.epoch();
    let clock = fixture
        .harness
        .execute_view_function(
            "0x1::poc_power_store::get_normalization_clock"
                .parse()
                .unwrap(),
            vec![],
            vec![],
        )
        .values
        .unwrap();
    assert_eq!(bcs::from_bytes::<u64>(&clock[1]).unwrap(), 1);
    let boundary: u64 = bcs::from_bytes(&clock[2]).unwrap();
    assert!(epoch + 1 < boundary);
    let pool = fixture.pools[0];
    let txn = fixture.harness.create_transaction_payload(
        &fixture.users[1],
        aptos_stdlib::poc_allocation_set_allocations(vec![pool], vec![10000]),
    );
    let output = fixture.harness.run_raw(txn);
    fixture.record_success(output);
    let txn = fixture.harness.create_transaction_payload(
        &fixture.framework,
        aptos_stdlib::poc_power_store_stage_batch_update(
            2,
            vec![*fixture.users[0].address()],
            vec![u64::MAX],
        ),
    );
    let output = fixture.harness.run_raw(txn);
    fixture.record_success(output);
    let current = pool_units(&mut fixture, pool, epoch);
    let next = pool_units(&mut fixture, pool, epoch + 1);
    let at_boundary = pool_units(&mut fixture, pool, boundary);
    let maximum = 1_u128 << 120;
    assert_eq!(next, 2 * current);
    assert!(current < maximum && next < maximum && at_boundary <= maximum);
    // 在 B，只有首个用户使用较大算力版本时仍合法；两人都切换为较大版本才超出容量，
    // 此时 E 和 E+1 的总量都没有变化。
    let large_version = at_boundary - current;
    assert!(2 * large_version > maximum);
    let before = fixture.snapshot();
    let users = vec![*fixture.users[2].address(), *fixture.users[1].address()];
    let txn = fixture.harness.create_transaction_payload(
        &fixture.framework,
        aptos_stdlib::poc_power_store_stage_batch_update(2, users.clone(), vec![
            u64::MAX,
            u64::MAX,
        ]),
    );
    let output = fixture.run_measured("batch_boundary_capacity_rejected", txn);
    assert_move_abort_at(&output, "poc_accounting", 0x20008);
    assert_eq!(fixture.snapshot(), before);
    assert_eq!(pool_units(&mut fixture, pool, epoch), current);
    assert_eq!(pool_units(&mut fixture, pool, epoch + 1), next);
    assert_eq!(pool_units(&mut fixture, pool, boundary), at_boundary);
    assert_eq!(fixture.epoch(), epoch);

    // 首项原本合法的新版本也已回滚；仅降低第二项数值后，两项都应成功首写，
    // 证明失败没有残留版本，也没有消耗首次写入机会。
    let txn = fixture.harness.create_transaction_payload(
        &fixture.framework,
        aptos_stdlib::poc_power_store_stage_batch_update(2, users, vec![u64::MAX, 1]),
    );
    let output = fixture.run_measured("batch_boundary_capacity_repaired", txn);
    assert_eq!(
        output
            .events()
            .iter()
            .filter(|event| event
                .type_tag()
                .to_canonical_string()
                .contains("PowerNormalized"))
            .count(),
        2,
    );
    fixture.record_success(output);

    // 制造热门池时用户 1 曾离开自己的池；容量修复后恢复原分配，确保目标委员会
    // 同时满足最低成员数，再验证失败事务没有阻断后续合法计划。
    let txn = fixture.harness.create_transaction_payload(
        &fixture.users[1],
        aptos_stdlib::poc_allocation_set_allocations(vec![fixture.pools[1]], vec![10000]),
    );
    let output = fixture.run_measured("restore_pool_after_capacity_repair", txn);
    fixture.record_success(output);
    let repaired_boundary = pool_units(&mut fixture, pool, boundary);
    assert!(repaired_boundary <= maximum);

    // 超限事务已完整回滚，修复输入后应能按生产换届入口重新生成并提交合法计划。
    // 提交完成须只推进一个 Epoch，且不能遗留计划或预计算验证者集合。
    let repaired_epoch = fixture.epoch();
    fixture.force_epoch();
    assert_eq!(fixture.epoch(), repaired_epoch + 1);
    assert!(fixture.resource("stake::EpochPlan").is_none());
    assert!(fixture.resource("stake::PrecomputedValidatorSet").is_none());
    assert_eq!(pool_units(&mut fixture, pool, boundary), repaired_boundary);
}

#[test]
/// 在同一 Epoch 内将待生效四池配置替换为另外四池，测量合计访问 2K 个池的成本。
fn poc_disjoint_four_pool_replacement_visits_eight() {
    let mut harness = MoveHarness::new_with_validators(8);
    let framework = harness.topo_framework_account();
    let mut fixture = PoCFixture::prepare_existing(harness, framework).install();
    let user = fixture
        .harness
        .new_account_at(AccountAddress::from_hex_literal("0x909").unwrap());
    let old_pools = fixture.pools[..4].to_vec();
    let new_pools = fixture.pools[4..].to_vec();
    let epoch = fixture.epoch();
    let period: u64 = bcs::from_bytes(
        &fixture
            .harness
            .execute_view_function(
                "0x1::poc_power_store::get_current_period".parse().unwrap(),
                vec![],
                vec![],
            )
            .values
            .unwrap()[0],
    )
    .unwrap();
    let txn = fixture.harness.create_transaction_payload(
        &fixture.framework,
        aptos_stdlib::poc_power_store_stage_batch_update(period + 1, vec![*user.address()], vec![
            RAW_POWER,
        ]),
    );
    let output = fixture.harness.run_raw(txn);
    fixture.record_success(output);
    let txn = fixture.harness.create_transaction_payload(
        &user,
        aptos_stdlib::poc_allocation_set_allocations(old_pools, vec![2500; 4]),
    );
    let output = fixture.harness.run_raw(txn);
    fixture.record_success(output);

    // MAX_ALLOCATIONS 限制每份 active/pending 配置的并集最多四池；在同一 Epoch
    // 将待生效四池替换为另外四池，虽需访问八池，但替换前后的配置均未超过上限。
    let txn = fixture.harness.create_transaction_payload(
        &user,
        aptos_stdlib::poc_allocation_set_allocations(new_pools.clone(), vec![2500; 4]),
    );
    let transaction_bytes = bcs::to_bytes(&txn).unwrap().len();
    let (output, reads, execution_us) = {
        let recorder = ReadRecorder {
            inner: fixture.harness.executor.get_state_view(),
            reads: Mutex::new(BTreeMap::new()),
        };
        let started = Instant::now();
        let output = fixture
            .harness
            .executor
            .execute_transaction_block_with_state_view(
                vec![Transaction::UserTransaction(txn)],
                &recorder,
                true,
            )
            .unwrap()
            .remove(0);
        let execution_us = started.elapsed().as_micros();
        (output, recorder.reads.into_inner().unwrap(), execution_us)
    };
    assert_success!(*output.status());
    let touched_pools = |keys: Vec<&StateKey>| -> BTreeSet<AccountAddress> {
        keys.into_iter()
            .filter_map(|key| match key.inner() {
                StateKeyInner::TableItem { key, .. } => bcs::from_bytes(key).ok(),
                _ => None,
            })
            .filter(|address| fixture.pools.contains(address))
            .collect()
    };
    let all_pools = fixture.pools.iter().copied().collect();
    assert_eq!(touched_pools(reads.keys().collect()), all_pools);
    assert_eq!(
        touched_pools(
            output
                .write_set()
                .write_op_iter()
                .map(|(key, _)| key)
                .collect()
        ),
        all_pools,
    );
    let read_key_bytes = reads
        .keys()
        .map(|key| bcs::to_bytes(key).unwrap().len())
        .sum::<usize>();
    let read_value_bytes = reads.values().sum::<usize>();
    let write_count = output.write_set().write_op_iter().count();
    let write_bytes = bcs::to_bytes(output.write_set()).unwrap().len();
    let event_bytes = bcs::to_bytes(output.events()).unwrap().len();
    println!(
        "POC_COST operation=replace_disjoint_4_to_4 validators=8 visited_pools=8 \
         transaction_bytes={transaction_bytes} gas_used={} read_count={} read_key_bytes={} \
         read_value_bytes={} write_count={} write_bytes={} events={} event_bytes={} \
         execution_us={execution_us}",
        output.gas_used(),
        reads.len(),
        read_key_bytes,
        read_value_bytes,
        write_count,
        write_bytes,
        output.events().len(),
        event_bytes,
    );
    fixture.harness.executor.apply_write_set(output.write_set());
    fixture
        .harness
        .executor
        .append_events(output.events().to_vec());
    fixture.record_success(output);

    let base_units = u128::from(RAW_POWER) << 32;
    for pool in fixture.pools.clone() {
        let values = fixture
            .harness
            .execute_view_function(
                "0x1::poc_accounting::get_pool".parse().unwrap(),
                vec![],
                vec![bcs::to_bytes(&pool).unwrap()],
            )
            .values
            .unwrap();
        assert_eq!(bcs::from_bytes::<u128>(&values[0]).unwrap(), base_units);
        assert_eq!(
            bcs::from_bytes::<u128>(&values[1]).unwrap(),
            base_units
                + if new_pools.contains(&pool) {
                    base_units / 4
                } else {
                    0
                },
        );
    }
    let allocation = fixture
        .harness
        .execute_view_function(
            "0x1::poc_accounting::get_allocations".parse().unwrap(),
            vec![],
            vec![bcs::to_bytes(user.address()).unwrap()],
        )
        .values
        .unwrap();
    assert!(
        bcs::from_bytes::<Vec<(AccountAddress, u64)>>(&allocation[0])
            .unwrap()
            .is_empty()
    );
    let pending: Vec<(u64, Vec<(AccountAddress, u64)>)> = bcs::from_bytes(&allocation[1]).unwrap();
    assert_eq!(pending, vec![(
        epoch + 1,
        new_pools.iter().map(|pool| (*pool, 2500)).collect()
    )]);
    fixture.force_epoch();
    assert_eq!(fixture.epoch(), epoch + 1);
    let set = get_validator_set(&fixture.harness);
    assert_eq!(set.active_validators(), fixture.pools);
    assert_eq!(set.total_voting_power, 9 * u128::from(RAW_POWER));
    for pool in fixture.pools.clone() {
        let values = fixture
            .harness
            .execute_view_function(
                "0x1::poc_accounting::get_position".parse().unwrap(),
                vec![],
                vec![
                    bcs::to_bytes(user.address()).unwrap(),
                    bcs::to_bytes(&pool).unwrap(),
                ],
            )
            .values
            .unwrap();
        assert_eq!(
            bcs::from_bytes::<u128>(&values[0]).unwrap(),
            if new_pools.contains(&pool) {
                base_units / 4
            } else {
                0
            },
        );
        assert!(bcs::from_bytes::<Vec<(u64, u128)>>(&values[1])
            .unwrap()
            .is_empty());
        assert_eq!(bcs::from_bytes::<u64>(&values[2]).unwrap(), 0);
    }
}
