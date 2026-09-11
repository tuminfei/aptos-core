// Copyright (c) Aptos Foundation
// Licensed pursuant to the Innovation-Enabling Source Code License, available at https://github.com/aptos-labs/aptos-core/blob/main/LICENSE

//! 从同一初始状态比较五种换届完成路径。测试适配器用结果标记直接调用框架内部回调，
//! 跳过 Rust 验证者交易的 transcript 和签名验证；真实 DKG 密码流程由节点测试覆盖。
//! 治理设置、强制完成和超时区块元数据均使用正常 VM 事务。

use super::{compile_script, PoCFixture};
use aptos_cached_packages::aptos_stdlib;
use aptos_crypto::HashValue;
use aptos_language_e2e_tests::executor::FakeExecutor;
use aptos_move_e2e_test_harness::assert_success;
use aptos_transaction_simulation::{DeltaStateStore, SimulationStateStore};
use aptos_types::{
    account_address::AccountAddress,
    block_metadata_ext::BlockMetadataExt,
    contract_event::ContractEvent,
    dkg::{chunky_dkg::ChunkyDKGState, DKGState},
    on_chain_config::ValidatorSet,
    state_store::{state_key::StateKey, StateView},
    transaction::Transaction,
    validator_verifier::ValidatorConsensusInfoMoveStruct,
};
use aptos_vm::{data_cache::AsMoveResolver, move_vm_ext::SessionId, AptosVM};
use aptos_vm_environment::environment::AptosEnvironment;
use aptos_vm_types::{
    module_and_script_storage::AsAptosCodeStorage, module_write_set::ModuleWriteSet,
    storage::change_set_configs::ChangeSetConfigs,
};
use move_core_types::{
    identifier::Identifier, int256::U256, language_storage::ModuleId, parser::parse_struct_tag,
    value::MoveValue,
};
use move_vm_runtime::module_traversal::{TraversalContext, TraversalStorage};
use move_vm_types::gas::UnmeteredGasMeter;
use serde::Deserialize;
use std::collections::BTreeMap;

#[derive(Debug, Deserialize, Eq, PartialEq)]
struct PoolTarget {
    pool: AccountAddress,
    units: u128,
    power: u64,
    reward_base_octa: u64,
}

#[derive(Debug, Deserialize, Eq, PartialEq)]
struct Preview {
    reason: u64,
    epoch: u64,
    period: u64,
    period_index: u128,
    cutoff_secs: u64,
    poc_enabled: bool,
    params: [u64; 4],
    closing_rewards: (u64, bool, u64, u64, bool, u64),
    targets: Vec<PoolTarget>,
    validator_set: ValidatorSet,
    is_liveness_fallback: bool,
}

/// 读取指定分支中的完整资源字节，缺失资源保留为 None。
fn raw(state: &impl StateView, name: &str) -> Option<Vec<u8>> {
    state
        .get_state_value(
            &StateKey::resource(
                &AccountAddress::ONE,
                &parse_struct_tag(&format!("0x1::{name}")).unwrap(),
            )
            .unwrap(),
        )
        .unwrap()
        .map(|value| value.bytes().to_vec())
}

/// 在指定状态上执行生产只读查询，不向分支写入结果。
fn view(state: &impl StateView, module: &str, function: &str, args: Vec<Vec<u8>>) -> Vec<Vec<u8>> {
    AptosVM::execute_view_function(
        state,
        ModuleId::new(AccountAddress::ONE, Identifier::new(module).unwrap()),
        Identifier::new(function).unwrap(),
        vec![],
        args,
        u64::MAX,
    )
    .values
    .unwrap()
}

/// 查询目标预检结果；冻结后即使传入新的时间，也必须返回原截止时间和原目标。
fn preview(state: &impl StateView, epoch: u64, cutoff: u64) -> Preview {
    bcs::from_bytes(
        &view(state, "stake", "preview_epoch_transition", vec![
            bcs::to_bytes(&epoch).unwrap(),
            bcs::to_bytes(&cutoff).unwrap(),
        ])[0],
    )
    .unwrap()
}

/// 沿用 FakeExecutor::try_exec 的内部调用方式，将输出应用到独立状态分支。
/// 为模拟 VM 内部回调，此处跳过函数可见性和 gas 检查，不覆盖外部调用权限或密码校验。
fn trusted_driver_call(
    state: &impl SimulationStateStore,
    function: &str,
    args: Vec<Vec<u8>>,
) -> Vec<ContractEvent> {
    let env = AptosEnvironment::new(state);
    let resolver = state.as_move_resolver();
    let vm = AptosVM::new(&env);
    let code = state.as_aptos_code_storage(&env);
    let mut session = vm.new_session(&resolver, SessionId::void(), None);
    let traversal = TraversalStorage::new();
    session
        .execute_function_bypass_visibility(
            &ModuleId::new(
                AccountAddress::ONE,
                Identifier::new("reconfiguration_with_dkg").unwrap(),
            ),
            &Identifier::new(function).unwrap(),
            vec![],
            args,
            &mut UnmeteredGasMeter,
            &mut TraversalContext::new(&traversal),
            &code,
        )
        .unwrap();
    let (writes, events) = session
        .finish(
            &ChangeSetConfigs::unlimited_at_gas_feature_version(env.gas_feature_version()),
            &code,
        )
        .unwrap()
        .try_combine_into_storage_change_set(ModuleWriteSet::empty())
        .unwrap()
        .into_inner();
    state.apply_write_set(&writes).unwrap();
    events
}

/// 通过正常 VM 交易执行治理或区块操作，只把成功输出写入当前独立分支。
fn execute(
    executor: &FakeExecutor,
    state: &(impl SimulationStateStore + Sync),
    transaction: Transaction,
) -> Vec<ContractEvent> {
    let output = executor
        .execute_transaction_block_with_state_view(vec![transaction], state, true)
        .unwrap()
        .remove(0);
    assert_success!(*output.status());
    state.apply_write_set(output.write_set()).unwrap();
    output.events().to_vec()
}

/// 按原顺序逐项比较会话与目标委员会，避免仅比较总权重而漏掉成员身份不匹配的情况。
fn assert_session_targets(targets: &[ValidatorConsensusInfoMoveStruct], expected: &ValidatorSet) {
    assert_eq!(targets.len(), expected.active_validators.len());
    for (target, validator) in targets.iter().zip(&expected.active_validators) {
        assert_eq!(target.addr, validator.account_address);
        assert_eq!(target.voting_power, validator.consensus_voting_power());
        assert_eq!(target.pk_bytes, validator.consensus_public_key().to_bytes());
    }
}

#[derive(Clone, Copy, Debug)]
enum Completion {
    Synchronous,
    Dkg,
    Chunky,
    Timeout,
    Force,
}

/// 五种完成路径从同一基线出发，比较委员会、计奖基数，以及奖励结算和重复完成后的完整状态。
#[test]
fn poc_same_snapshot_transition_targets_and_reward_bases() {
    let mut fixture = PoCFixture::installed();
    let configure = compile_script(
        "PoCDifferentialSetup",
        r#"
script {
    use topo_std::fixed_point64;
    use topo_framework::block;
    use topo_framework::chunky_dkg_config;
    use topo_framework::epoch_timeout_config;
    use topo_framework::randomness_config;
    use topo_framework::topo_governance;
    fun main(framework: &signer) {
        randomness_config::set_for_next_epoch(framework, randomness_config::new_v1(
            fixed_point64::create_from_rational(1, 2), fixed_point64::create_from_rational(2, 3)));
        chunky_dkg_config::set_for_next_epoch(framework, chunky_dkg_config::new_v1(
            fixed_point64::create_from_rational(1, 2), fixed_point64::create_from_rational(2, 3)));
        epoch_timeout_config::set_for_next_epoch(framework, epoch_timeout_config::new_with_grace_period(2));
        block::update_epoch_interval_microsecs(framework, 60000000);
        topo_governance::force_end_epoch(framework);
    }
}
"#,
    );
    // 先推进链上时间戳，避免重复事件保护跳过本次换届。
    fixture
        .harness
        .new_block_with_metadata(fixture.pools[0], vec![]);
    let txn = fixture
        .harness
        .create_script(&fixture.framework, configure, vec![], vec![]);
    let output = fixture.harness.run_raw(txn);
    fixture.record_success(output);
    for pool in fixture.pools.clone() {
        fixture.harness.new_block_with_metadata(pool, vec![]);
    }
    let period: u64 = bcs::from_bytes(
        &view(
            fixture.harness.executor.get_state_view(),
            "poc_power_store",
            "get_current_period",
            vec![],
        )[0],
    )
    .unwrap();
    let users: Vec<_> = fixture.users.iter().map(|user| *user.address()).collect();
    let txn = fixture.harness.create_transaction_payload(
        &fixture.framework,
        aptos_stdlib::poc_power_store_stage_batch_update(period + 1, users, vec![
            30000, 20000, 10000, 40000,
        ]),
    );
    let output = fixture.harness.run_raw(txn);
    fixture.record_success(output);
    let force = fixture.harness.create_entry_function(
        &fixture.framework,
        "0x1::topo_governance::force_end_epoch".parse().unwrap(),
        vec![],
        vec![],
    );

    let base = fixture.harness.executor.get_state_view();
    let base_snapshot = fixture.snapshot();
    let epoch = fixture.epoch();
    assert!(raw(base, "stake::EpochPlan").is_none());
    assert!(raw(base, "stake::PrecomputedValidatorSet").is_none());
    let now_us: u64 =
        bcs::from_bytes(&raw(base, "timestamp::CurrentTimeMicroseconds").unwrap()).unwrap();
    let cutoff = now_us / 1000000;
    let expected = preview(base, epoch + 1, cutoff);
    assert_eq!(expected.reason, 0);
    assert_eq!(expected.validator_set.total_voting_power, 49999);
    assert_eq!(
        expected
            .validator_set
            .active_validators
            .iter()
            .map(|validator| validator.consensus_voting_power())
            .collect::<Vec<_>>(),
        vec![13333, 11666, 10000, 15000]
    );
    assert!(expected
        .targets
        .iter()
        .all(|target| target.reward_base_octa == target.power));
    let clock_before: [u64; 4] =
        bcs::from_bytes(&raw(base, "poc_power_store::PeriodClock").unwrap()).unwrap();
    let signer = MoveValue::Signer(AccountAddress::ONE)
        .simple_serialize()
        .unwrap();
    let mut settled_pools = None;
    let mut closing_rewards = None;
    let mut reward_context = None;

    for completion in [
        Completion::Synchronous,
        Completion::Dkg,
        Completion::Chunky,
        Completion::Timeout,
        Completion::Force,
    ] {
        let branch = DeltaStateStore::new_with_base(base);
        assert!(branch.delta().is_empty());
        let mut events = if matches!(completion, Completion::Synchronous) {
            trusted_driver_call(&branch, "try_finish", vec![signer.clone()])
        } else {
            trusted_driver_call(
                &branch,
                if matches!(completion, Completion::Dkg) {
                    "require_start"
                } else {
                    "require_start_with_chunky_dkg"
                },
                vec![],
            )
        };
        if !matches!(completion, Completion::Synchronous) {
            // 冻结后的较晚查询仍须返回原截止时间和同一目标，不能按新时间重选。
            assert_eq!(preview(&branch, epoch + 1, cutoff + 1), expected);
            let (pvs, fallback): (ValidatorSet, bool) =
                bcs::from_bytes(&raw(&branch, "stake::PrecomputedValidatorSet").unwrap()).unwrap();
            assert_eq!(pvs, expected.validator_set);
            assert!(!fallback);
            let dkg: DKGState = bcs::from_bytes(&raw(&branch, "dkg::DKGState").unwrap()).unwrap();
            let session = dkg.in_progress.unwrap();
            assert_eq!(session.metadata.dealer_epoch, epoch);
            assert_session_targets(
                &session.metadata.target_validator_set,
                &expected.validator_set,
            );
            if !matches!(completion, Completion::Dkg) {
                let chunky: ChunkyDKGState =
                    bcs::from_bytes(&raw(&branch, "chunky_dkg::ChunkyDKGState").unwrap()).unwrap();
                let session = chunky.in_progress.unwrap();
                assert_eq!(session.metadata.dealer_epoch, epoch);
                assert_session_targets(
                    &session.metadata.target_validator_set,
                    &expected.validator_set,
                );
            }
        }
        match completion {
            Completion::Synchronous => {},
            Completion::Dkg | Completion::Chunky => {
                let plan = raw(&branch, "stake::EpochPlan");
                events.extend(trusted_driver_call(
                    &branch,
                    "finish_with_dkg_result",
                    vec![
                        signer.clone(),
                        bcs::to_bytes(&b"trusted-result-marker".to_vec()).unwrap(),
                    ],
                ));
                if matches!(completion, Completion::Chunky) {
                    assert_eq!(raw(&branch, "stake::EpochPlan"), plan);
                    events.extend(trusted_driver_call(
                        &branch,
                        "finish_with_chunky_dkg_result",
                        vec![
                            signer.clone(),
                            bcs::to_bytes(&b"trusted-chunky-marker".to_vec()).unwrap(),
                            bcs::to_bytes(&b"trusted-key-marker".to_vec()).unwrap(),
                        ],
                    ));
                }
            },
            Completion::Timeout => {
                events.extend(execute(
                    &fixture.harness.executor,
                    &branch,
                    Transaction::BlockMetadataExt(BlockMetadataExt::new_v2(
                        HashValue::zero(),
                        epoch,
                        100,
                        fixture.pools[0],
                        vec![0],
                        vec![],
                        (cutoff + 60) * 1000000,
                        None,
                        None,
                    )),
                ));
                assert!(events.iter().any(|event| event
                    .type_tag()
                    .to_canonical_string()
                    .contains("ForceEndEpochEvent")));
            },
            Completion::Force => events.extend(execute(
                &fixture.harness.executor,
                &branch,
                Transaction::UserTransaction(force.clone()),
            )),
        }
        let installed: ValidatorSet =
            bcs::from_bytes(&raw(&branch, "stake::ValidatorSet").unwrap()).unwrap();
        assert_eq!(installed, expected.validator_set, "{completion:?}");
        let clock: [u64; 4] =
            bcs::from_bytes(&raw(&branch, "poc_power_store::PeriodClock").unwrap()).unwrap();
        assert_eq!(clock[1], clock_before[1] + 1);
        assert_eq!(clock[2], expected.period);
        let context: (u64, bool, u64, u64, bool, u64) =
            bcs::from_bytes(&raw(&branch, "stake::InstalledRewardContext").unwrap()).unwrap();
        assert_eq!(context.0, expected.epoch);
        assert!(context.1);
        if let Some(reference) = reward_context {
            assert_eq!(context, reference, "{completion:?}");
        } else {
            reward_context = Some(context);
        }
        for resource in [
            "stake::EpochPlan",
            "stake::PrecomputedValidatorSet",
            "features::PendingFeatureFreeze",
        ] {
            assert!(
                raw(&branch, resource).is_none(),
                "{completion:?}: {resource}"
            );
        }
        let mut pool_results = BTreeMap::new();
        for target in &expected.targets {
            let values = view(&branch, "poc_accounting", "get_pool", vec![bcs::to_bytes(
                &target.pool,
            )
            .unwrap()]);
            let units: u128 = bcs::from_bytes(&values[0]).unwrap();
            let base: u64 = bcs::from_bytes(&values[2]).unwrap();
            let vault: u64 = bcs::from_bytes(&values[3]).unwrap();
            let index: U256 = bcs::from_bytes(&values[4]).unwrap();
            assert_eq!(units, target.units);
            assert_eq!(base, target.reward_base_octa);
            pool_results.insert(target.pool, (units, base, vault, index));
        }
        let rewards: Vec<(AccountAddress, u64, u64, u64, u64, U256)> = events
            .iter()
            .filter(|event| {
                event
                    .type_tag()
                    .to_canonical_string()
                    .contains("PoCRewardCredited")
            })
            .map(|event| bcs::from_bytes(event.event_data()).unwrap())
            .collect();
        assert_eq!(rewards.len(), fixture.pools.len());
        assert!(rewards.iter().all(|(_, closing, ..)| *closing == epoch));
        assert!(rewards
            .iter()
            .all(|(_, _, _, inflation, ..)| *inflation > 0));
        if let Some(reference) = &settled_pools {
            assert_eq!(&pool_results, reference, "{completion:?}");
            assert_eq!(
                &rewards,
                closing_rewards.as_ref().unwrap(),
                "{completion:?}"
            );
        } else {
            settled_pools = Some(pool_results);
            closing_rewards = Some(rewards);
        }
        // 同一时间戳下重复完成不能再次发放奖励或推进 Epoch，原始基线也须保持不变。
        let once = branch.delta();
        assert!(trusted_driver_call(&branch, "try_finish", vec![signer.clone()]).is_empty());
        assert_eq!(branch.delta(), once);
        assert_eq!(fixture.snapshot(), base_snapshot);
        println!("POC_DIFFERENTIAL path={completion:?} target_epoch={} total_power={} pools={} passed=true",
            expected.epoch, expected.validator_set.total_voting_power, expected.targets.len());
    }
}
