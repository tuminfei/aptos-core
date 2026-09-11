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
    on_chain_config::{ConfigurationResource, ValidatorSet},
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
};
use move_core_types::{int256::U256, parser::parse_struct_tag, vm_status::AbortLocation};
use once_cell::sync::Lazy;
use std::{
    collections::{BTreeMap, BTreeSet},
    sync::Mutex,
    time::Instant,
};
use topo_framework::{BuildOptions, BuiltPackage};

const RAW_POWER: u64 = 10_000;

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
            poc_allocation::prepare_poc(framework,
                poc_accounting::new_power_params(100000000, 1, 1000000, 4),
                poc_accounting::new_deployment_limits(4, 4, 32, 8, 1000000, 1, 1, 1000, 100),
                1, reconfiguration::current_epoch() + (if (boundary_capacity) { 6 } else { 2 }),
                if (boundary_capacity) { 3 } else { 10000 },
                if (boundary_capacity) { 2 } else { 200 },
                if (boundary_capacity) { 4 } else { 1 }, @topo_framework);
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
            "stake::ValidatorSet",
            "stake::EpochPlan",
            "stake::PrecomputedValidatorSet",
            "stake::InstalledRewardContext",
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
    for operation in [3, 4, 5, 6, 7, 8, 9, 10, 12, 13] {
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
    assert!(pool_units(&mut fixture, pool, boundary) <= maximum);
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
    println!(
        "POC_COST operation=replace_disjoint_4_to_4 validators=8 visited_pools=8 \
         transaction_bytes={transaction_bytes} gas_used={} read_count={} read_key_bytes={} \
         read_value_bytes={} write_count={} write_bytes={} events={} event_bytes={} \
         execution_us={execution_us}",
        output.gas_used(),
        reads.len(),
        reads
            .keys()
            .map(|key| bcs::to_bytes(key).unwrap().len())
            .sum::<usize>(),
        reads.values().sum::<usize>(),
        output.write_set().write_op_iter().count(),
        bcs::to_bytes(output.write_set()).unwrap().len(),
        output.events().len(),
        bcs::to_bytes(output.events()).unwrap().len(),
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
