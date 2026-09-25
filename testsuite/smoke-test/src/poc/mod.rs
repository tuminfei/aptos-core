// Copyright (c) Aptos Foundation
// Licensed pursuant to the Innovation-Enabling Source Code License, available at https://github.com/aptos-labs/aptos-core/blob/main/LICENSE

mod allocation_lifecycle;
mod bond_cutoff;
mod bond_rewards;
mod concentration;
mod contract_freeze;
mod defaults;
mod delegation_rewards;
mod fee_rewards;
mod freeze;
mod governance;
mod governance_weight;
mod member_freeze;
mod member_lifecycle;
mod power_governance;
mod power_lifecycle;
mod recovery;
mod reward_checkpoints;
mod reward_churn;
mod reward_split_lifecycle;
mod stake_freeze;
mod testnet_compat;
mod transactions;
mod upload_capacity;
mod weight_limits;

use crate::smoke_test_environment::SwarmBuilder;
use aptos_api_types::{AptosErrorCode, Transaction};
use aptos_cached_packages::aptos_stdlib;
use aptos_forge::{LocalSwarm, NodeExt, Swarm, SwarmExt};
use aptos_genesis::poc::{DeploymentMode, PocGenesisConfiguration, PowerParams};
use aptos_rest_client::{error::RestError, Client, Resource};
use aptos_sdk::{transaction_builder::TransactionFactory, types::LocalAccount};
use aptos_types::{
    account_address::AccountAddress,
    account_config::CORE_CODE_ADDRESS,
    decryption::PerEpochEncryptionKeyResource,
    dkg::{chunky_dkg::ChunkyDKGState, DKGState, DKGTrait, DefaultDKG},
    on_chain_config::{
        FeatureFlag, Features, OnChainChunkyDKGConfig, OnChainConfig, OnChainRandomnessConfig,
        ValidatorSet,
    },
    transaction::TransactionPayload,
    validator_verifier::ValidatorConsensusInfoMoveStruct,
};
use std::{sync::Arc, time::Duration};
use tokio::time::Instant;

#[derive(Clone, Copy)]
enum Transition {
    Synchronous,
    Dkg,
    Chunky,
    DkgRecovery,
    DkgReplacement,
}

/// 使用实际生成的节点身份构造显式 PoC 创世；金额和人数仅是验收测试参数。
fn poc_swarm_builder(transition: Transition) -> SwarmBuilder {
    SwarmBuilder::new_local(
        if matches!(transition, Transition::DkgReplacement) {
            5
        } else {
            4
        },
    )
    .with_aptos()
    .with_num_fullnodes(usize::from(matches!(
        transition,
        Transition::DkgReplacement
    )))
    .with_init_genesis_stake(Arc::new(|_, amount| *amount = 100))
    .with_init_config(Arc::new(move |_, config, _| {
        config.api.failpoints_enabled = matches!(transition, Transition::DkgRecovery);
        if matches!(transition, Transition::DkgRecovery) {
            // 启动 DKG 任务前暂停处理，避免建网健康检查期间已完成首轮 transcript。
            config
                .failpoints
                .get_or_insert_with(Default::default)
                .insert(
                    "dkg::process_dkg_start_event".to_owned(),
                    "pause".to_owned(),
                );
        }
        if matches!(transition, Transition::Chunky) {
            config.api.allow_encrypted_txns_submission = true;
            config.consensus.quorum_store.enable_batch_v2_tx = true;
            config.consensus.quorum_store.enable_batch_v2_rx = true;
            config.consensus.quorum_store.enable_opt_qs_v2_payload_tx = true;
            config.consensus.quorum_store.enable_opt_qs_v2_payload_rx = true;
            config
                .state_sync
                .state_sync_driver
                .enable_auto_bootstrapping = true;
            config
                .state_sync
                .state_sync_driver
                .max_connection_deadline_secs = 3;
        }
    }))
    .with_init_genesis_config(Arc::new(move |config| {
        config.allow_new_validators = true;
        config.epoch_duration_secs = if matches!(
            transition,
            Transition::DkgRecovery | Transition::DkgReplacement
        ) {
            30
        } else {
            10
        };
        config.min_stake = 1;
        config.max_stake = 1000;
        config.voting_power_increase_limit = 25;
        config.randomness_config_override = Some(OnChainRandomnessConfig::Off);
        config.chunky_dkg_config_override = Some(OnChainChunkyDKGConfig::default_disabled());
        if !matches!(transition, Transition::Synchronous) {
            config.consensus_config.enable_validator_txns();
            config.randomness_config_override = Some(OnChainRandomnessConfig::default_enabled());
        }
        if matches!(transition, Transition::Chunky) {
            config.chunky_dkg_config_override = Some(OnChainChunkyDKGConfig::default_enabled());
            let mut features = Features::default();
            features.enable(FeatureFlag::ENCRYPTED_TRANSACTIONS);
            config.initial_features_override = Some(features);
        }
        config.poc_genesis_config = Some(Arc::new(|_| PocGenesisConfiguration {
            params: PowerParams {
                bond_octa_per_ohmp: 100_000_000,
                min_power: 10,
                max_power: 1000,
                min_validators: 4,
            },

            deployment_mode: DeploymentMode::Open,
            retention_bps: 10000,
            initial_raw_power: 10,
        }));
    }))
}

/// 按指定换届方式启动本地测试网络，所有节点加载同一生产 bundle。
async fn create_poc_swarm(transition: Transition) -> LocalSwarm {
    poc_swarm_builder(transition).build().await
}

/// 测试所需的非默认上限和奖励分流通过公开治理入口设置，不扩展生产创世清单。
async fn configure_fixture(swarm: &LocalSwarm, limits: [u64; 5], native_bps: u64) {
    use aptos_types::transaction::{Script, TransactionArgument};
    use once_cell::sync::Lazy;

    static CONFIGURE: Lazy<Vec<u8>> = Lazy::new(|| {
        transactions::compile_script(
            "PoCFixtureConfiguration",
            r#"script {
            use topo_framework::poc_accounting;
            use topo_framework::poc_allocation;
            use topo_framework::reconfiguration;
            use topo_framework::stake;
            use topo_framework::topo_governance;

            fun main(root: &signer, allocations: u64, claims: u64, uploads: u64,
                validators: u64, fee_max: u64, native_bps: u64) {
                let framework = topo_governance::get_signer_testnet_only(root, @0x1);
                poc_allocation::update_deployment_limits(&framework,
                    poc_accounting::new_deployment_limits(allocations, claims, uploads,
                        validators, fee_max));
                stake::schedule_reward_split(&framework, native_bps,
                    reconfiguration::current_epoch() + 1);
                topo_governance::reconfigure(&framework);
            }
        }"#,
        )
    });

    // 首个区块可能触发初始 DKG；等待它完成后再提交治理事务。
    swarm
        .wait_for_all_nodes_to_catchup_to_epoch(2, Duration::from_secs(90))
        .await
        .unwrap();
    let client = swarm.validators().next().unwrap().rest_client();
    let chain = swarm.chain_info();
    let factory = chain
        .transaction_factory()
        .with_gas_unit_price(100)
        .with_max_gas_amount(2_000_000)
        .with_transaction_expiration_time(120);
    let arguments = limits
        .into_iter()
        .chain([native_bps])
        .map(TransactionArgument::U64)
        .collect();
    let transaction = fee_rewards::success(
        transactions::execute(
            &client,
            &chain.root_account(),
            &factory,
            TransactionPayload::Script(Script::new(CONFIGURE.clone(), vec![], arguments)),
        )
        .await,
    );
    let target_epoch = defaults::installed_at(&client, transaction.info.version.0 - 1)
        .await
        .epoch
        + 1;
    swarm
        .wait_for_all_nodes_to_catchup_to_epoch(target_epoch, Duration::from_secs(90))
        .await
        .unwrap();
    let version = client
        .get_ledger_information()
        .await
        .unwrap()
        .into_inner()
        .version;
    assert_eq!(
        fee_rewards::integer(
            &defaults::installed_at(&client, version).await.reward_split
                ["installed_native_reward_bps"]
        ),
        native_bps as u128
    );
}

/// 同步换届后重启一个验证者，确认恢复后的委员会和奖励上下文与其他节点一致。
#[tokio::test]
async fn poc_genesis_restart() {
    let mut swarm = create_poc_swarm(Transition::Synchronous).await;
    swarm
        .wait_for_all_nodes_to_catchup_to_epoch(2, Duration::from_secs(90))
        .await
        .unwrap();
    let client = swarm.validators().next().unwrap().rest_client();
    let before = client.get_ledger_information().await.unwrap().into_inner();
    swarm
        .validators_mut()
        .next()
        .unwrap()
        .restart()
        .await
        .unwrap();
    swarm
        .wait_for_all_nodes_to_catchup_to_epoch(before.epoch + 1, Duration::from_secs(90))
        .await
        .unwrap();
    let after = client.get_ledger_information().await.unwrap().into_inner();
    let installed = resource_at_version::<ValidatorSet>(&client, after.version).await;
    assert_installed_on_all_nodes(&swarm, after.version, after.epoch, &installed, 5000).await;
}

/// 固定 ledger version 读取资源，避免跨越 Epoch 时把不同会话的状态混在一次比较中。
async fn resource_at_version<T: OnChainConfig>(client: &Client, version: u64) -> T {
    client
        .get_account_resource_at_version_bcs(
            CORE_CODE_ADDRESS,
            &T::struct_tag().to_canonical_string(),
            version,
        )
        .await
        .unwrap()
        .into_inner()
}

/// 枚举历史资源需要 indexer；直接按名称读取资源，
/// 使所有 smoke fixture 均可保留原生节点配置。
async fn optional_resource_at_version(
    client: &Client,
    address: AccountAddress,
    resource_type: &str,
    version: u64,
) -> Option<Resource> {
    match client
        .get_account_resource_at_version(address, resource_type, version)
        .await
    {
        Ok(response) => response.into_inner(),
        Err(RestError::Api(error))
            if error.status_code == reqwest::StatusCode::NOT_FOUND
                && error.error.error_code == AptosErrorCode::ResourceNotFound =>
        {
            None
        },
        Err(error) => {
            panic!("Cannot read {resource_type} at {address}, version {version}: {error}")
        },
    }
}

async fn frozen_context_at(client: &Client, version: u64) -> Vec<Vec<u8>> {
    let mut snapshot = Vec::new();
    for resource in [
        "0x1::stake::EpochPlan",
        "0x1::stake::PrecomputedValidatorSet",
        "0x1::stake::InstalledRewardContext",
        "0x1::poc_reward_split::RewardSplitConfig",
        "0x1::poc_power_store::PeriodClock",
    ] {
        snapshot.push(
            client
                .get_account_resource_at_version_bytes(CORE_CODE_ADDRESS, resource, version)
                .await
                .unwrap()
                .into_inner(),
        );
    }
    snapshot
}

/// 按原顺序比较目标地址、公钥和算力权重，验证实际安装集合与 DKG 输入一致。
fn assert_targets(targets: &[ValidatorConsensusInfoMoveStruct], set: &ValidatorSet) {
    assert_eq!(targets.len(), set.active_validators.len());
    for (target, validator) in targets.iter().zip(&set.active_validators) {
        assert_eq!(target.addr, validator.account_address);
        assert_eq!(target.voting_power, validator.consensus_voting_power());
        assert_eq!(target.pk_bytes, validator.consensus_public_key().to_bytes());
    }
}

/// 委员会不变的场景要求所有节点追赶到同一版本，再逐个核对安装结果。
async fn assert_installed_on_all_nodes(
    swarm: &LocalSwarm,
    version: u64,
    epoch: u64,
    expected: &ValidatorSet,
    expected_native_bps: u64,
) {
    swarm
        .wait_for_all_nodes_to_catchup_to_version(version, Duration::from_secs(30))
        .await
        .unwrap();
    for node in swarm.validators() {
        assert_installed_on_client(
            &node.rest_client(),
            version,
            epoch,
            expected,
            expected_native_bps,
        )
        .await;
    }
}

/// 核对本测试清单的四个等权验证者及对应 Epoch 的 PoC 奖励上下文。
async fn assert_installed_on_client(
    client: &Client,
    version: u64,
    epoch: u64,
    expected: &ValidatorSet,
    expected_native_bps: u64,
) {
    let set = resource_at_version::<ValidatorSet>(client, version).await;
    assert_eq!(set.active_validators.len(), 4);
    assert_eq!(set.total_voting_power, 40);
    assert_eq!(set.total_joining_power, 0);
    assert!(set
        .active_validators
        .iter()
        .all(|v| v.consensus_voting_power() == 10));
    assert_eq!(&set, expected);
    let context = client
        .get_account_resource_at_version_bcs::<(u64, bool, u64, u64, bool, u64)>(
            CORE_CODE_ADDRESS,
            "0x1::stake::InstalledRewardContext",
            version,
        )
        .await
        .unwrap()
        .into_inner();
    assert_eq!(context.0, epoch);
    assert!(context.1);
    assert_eq!(context.5, 0);
    let split = client
        .get_account_resource_at_version_bcs::<(u64, u64, u64, Vec<(u64, u64)>)>(
            CORE_CODE_ADDRESS,
            "0x1::poc_reward_split::RewardSplitConfig",
            version,
        )
        .await
        .unwrap()
        .into_inner();
    assert_eq!(
        split,
        (epoch, expected_native_bps, expected_native_bps, vec![])
    );
}

/// 等待真实 DKG 完成，在同一 ledger version 核对会话、委员会及目标 Epoch 的密钥。
async fn check_completed_transition(transition: Transition, timeout: Duration) {
    let swarm = create_poc_swarm(transition).await;
    let client = swarm.validators().next().unwrap().rest_client();
    let deadline = Instant::now() + timeout;
    let (version, epoch, installed) = loop {
        assert!(Instant::now() < deadline, "PoC DKG completion timed out");
        let ledger = client.get_ledger_information().await.unwrap().into_inner();
        if ledger.epoch >= 2 {
            let dkg = resource_at_version::<DKGState>(&client, ledger.version).await;
            if let Some(session) = dkg
                .last_completed
                .filter(|s| s.target_epoch() == ledger.epoch)
            {
                let installed = resource_at_version::<ValidatorSet>(&client, ledger.version).await;
                assert!(!session.transcript.is_empty());
                assert_targets(&session.metadata.target_validator_set, &installed);
                if matches!(transition, Transition::Chunky) {
                    let chunky =
                        resource_at_version::<ChunkyDKGState>(&client, ledger.version).await;
                    if let Some(chunky_session) = chunky
                        .last_completed
                        .filter(|s| s.target_epoch() == ledger.epoch)
                    {
                        assert!(!chunky_session.transcript.is_empty());
                        assert_eq!(
                            chunky_session.metadata.target_validator_set,
                            session.metadata.target_validator_set
                        );
                        assert_targets(&chunky_session.metadata.target_validator_set, &installed);
                        let key = client
                            .get_account_resource_at_version_bcs::<PerEpochEncryptionKeyResource>(
                                CORE_CODE_ADDRESS,
                                "0x1::decryption::PerEpochEncryptionKey",
                                ledger.version,
                            )
                            .await
                            .unwrap()
                            .into_inner();
                        assert_eq!(key.epoch, ledger.epoch);
                        assert!(key.encryption_key.is_some());
                        break (ledger.version, ledger.epoch, installed);
                    }
                } else {
                    break (ledger.version, ledger.epoch, installed);
                }
            }
        }
        tokio::time::sleep(Duration::from_secs(1)).await;
    };
    assert_installed_on_all_nodes(&swarm, version, epoch, &installed, 5000).await;
}

/// 验证普通 DKG 在真实节点上安装会话指定的委员会。
#[tokio::test]
async fn poc_dkg_installs_session_targets() {
    check_completed_transition(Transition::Dkg, Duration::from_secs(90)).await;
}

/// 验证普通与 Chunky DKG 共用同一目标，并安装对应 Epoch 的加密密钥。
#[tokio::test]
async fn poc_chunky_dkg_installs_same_session_targets() {
    // 现有 Chunky 实现的表初始化可能超过一分钟，等待超时时间须包含这段初始化耗时。
    check_completed_transition(Transition::Chunky, Duration::from_secs(240)).await;
}

/// 由池运营者签署成员变更，通过节点公开交易入口提交，并返回交易成功后的账本版本。
async fn submit_membership_change(
    client: &Client,
    operator: &LocalAccount,
    factory: &TransactionFactory,
    payload: TransactionPayload,
) -> u64 {
    let txn = operator.sign_with_transaction_builder(factory.payload(payload));
    let Transaction::UserTransaction(txn) =
        tokio::time::timeout(Duration::from_secs(30), client.submit_and_wait(&txn))
            .await
            .expect("Membership transaction exceeded 30 seconds")
            .unwrap()
            .into_inner()
    else {
        panic!("Expected membership transaction")
    };
    assert!(txn.info.success, "{}", txn.info.vm_status);
    txn.info.version.0
}

/// 根据申请后的成员队列计算预期顺序，验证真实 transcript，并要求本届成员同步到同一版本。
async fn wait_for_poc_membership(
    swarm: &LocalSwarm,
    client: &Client,
    request_version: u64,
) -> ValidatorSet {
    let queued = resource_at_version::<ValidatorSet>(client, request_version).await;
    let expected = queued
        .active_validators
        .iter()
        .chain(queued.pending_active.iter().rev())
        .map(|v| v.account_address)
        .collect::<Vec<_>>();
    let (closing_epoch, _, _, _, _, _) = client
        .get_account_resource_at_version_bcs::<(u64, bool, u64, u64, bool, u64)>(
            CORE_CODE_ADDRESS,
            "0x1::stake::InstalledRewardContext",
            request_version,
        )
        .await
        .unwrap()
        .into_inner();
    let target_epoch = closing_epoch + 1;
    let deadline = Instant::now() + Duration::from_secs(90);
    loop {
        assert!(
            Instant::now() < deadline,
            "PoC member replacement timed out"
        );
        let ledger = client.get_ledger_information().await.unwrap().into_inner();
        if ledger.epoch >= target_epoch {
            let dkg = resource_at_version::<DKGState>(client, ledger.version).await;
            let session = dkg.last_completed.expect("Expected completed member DKG");
            assert_eq!(session.target_epoch(), target_epoch);
            let installed = resource_at_version::<ValidatorSet>(client, ledger.version).await;
            assert_targets(&session.metadata.target_validator_set, &installed);
            assert_eq!(
                session
                    .metadata
                    .target_validator_set
                    .iter()
                    .map(|v| v.addr)
                    .collect::<Vec<_>>(),
                expected
            );
            let params = DefaultDKG::new_public_params(&session.metadata);
            let transcript = bcs::from_bytes(&session.transcript).unwrap();
            DefaultDKG::verify_transcript(&params, &transcript).unwrap();
            // 离任节点可能停在验证者网络的退出边界；所有本届投票成员必须追赶，
            // 其中包括本次重新加入的节点，不能因其曾退出而跳过核对。
            let committee = installed
                .active_validators
                .iter()
                .map(|validator| {
                    (
                        validator.account_address.to_string(),
                        swarm
                            .validator(validator.account_address)
                            .unwrap()
                            .rest_client(),
                    )
                })
                .collect::<Vec<_>>();
            aptos_forge::wait_for_all_nodes_to_catchup_to_version(
                &committee,
                ledger.version,
                Duration::from_secs(30),
            )
            .await
            .unwrap();
            for (_, voter) in &committee {
                assert_installed_on_client(voter, ledger.version, target_epoch, &installed, 5000)
                    .await;
            }
            return installed;
        }
        tokio::time::sleep(Duration::from_secs(1)).await;
    }
}

/// 五个验证者中先退出一个，再通过加入和退出申请完成四人委员会替补，验证新成员的增长预算。
#[tokio::test]
async fn poc_dkg_replaces_validator_with_growth_budget() {
    let swarm = create_poc_swarm(Transition::DkgReplacement).await;
    let client = swarm.validators().nth(2).unwrap().rest_client();
    let identities = swarm
        .validators()
        .take(2)
        .map(|node| {
            (
                node.peer_id(),
                node.account_private_key().as_ref().unwrap().private_key(),
            )
        })
        .collect::<Vec<_>>();
    let mut operators = Vec::new();
    let factory = swarm
        .chain_info()
        .transaction_factory()
        .with_gas_unit_price(1)
        .with_max_gas_amount(2000000)
        .with_transaction_expiration_time(60);
    let mut public_info = swarm.chain_info().into_aptos_public_info();
    for (address, key) in identities {
        public_info.mint(address, 100000000).await.unwrap();
        let sequence = client
            .get_account(address)
            .await
            .unwrap()
            .into_inner()
            .sequence_number;
        operators.push(LocalAccount::new(address, key, sequence));
    }
    let replacement = &operators[0];
    let leaving = &operators[1];

    // 一轮 DKG 完成后立即提交申请，为两笔成员交易留出完整 Epoch，
    // 避免下一轮换届已冻结时才提交。
    let initial = client.get_ledger_information().await.unwrap().into_inner();
    let initial_set = resource_at_version::<ValidatorSet>(&client, initial.version).await;
    assert_eq!(initial_set.active_validators.len(), 5);
    assert_eq!(initial_set.total_voting_power, 50);
    swarm
        .wait_for_all_nodes_to_catchup_to_epoch(initial.epoch + 1, Duration::from_secs(90))
        .await
        .unwrap();

    // 五个合格池允许先自主退出一个，建立四个投票者、总权重 40 的预算基线。
    let version = submit_membership_change(
        &client,
        replacement,
        &factory,
        aptos_stdlib::stake_leave_validator_set(replacement.address()),
    )
    .await;
    let first = wait_for_poc_membership(&swarm, &client, version).await;
    assert!(!first
        .active_validators
        .iter()
        .any(|v| v.account_address == replacement.address()));

    // 两笔申请分别由既有运营者授权；新成员没有已安装基础权重，
    // 旧总权重 40 的 25% 预算恰好使其获得门槛所需的 10 权重。
    let version = submit_membership_change(
        &client,
        replacement,
        &factory,
        aptos_stdlib::stake_join_validator_set(replacement.address()),
    )
    .await;
    let queued = resource_at_version::<ValidatorSet>(&client, version).await;
    assert_eq!(queued.total_voting_power, 40);
    assert_eq!(queued.total_joining_power, 0);
    assert_eq!(queued.pending_active.len(), 1);
    assert_eq!(queued.pending_active[0].consensus_voting_power(), 0);
    let version = submit_membership_change(
        &client,
        leaving,
        &factory,
        aptos_stdlib::stake_leave_validator_set(leaving.address()),
    )
    .await;
    let installed = wait_for_poc_membership(&swarm, &client, version).await;
    let addresses = installed
        .active_validators
        .iter()
        .map(|v| v.account_address)
        .collect::<Vec<AccountAddress>>();
    assert!(addresses.contains(&replacement.address()));
    assert!(!addresses.contains(&leaving.address()));
}

/// 冻结期间停机、重启并强制结束，验证恢复后仍提交原计划，且只结算一次奖励、推进一次时钟。
#[tokio::test]
async fn poc_frozen_dkg_force_end_and_restart() {
    let mut swarm = create_poc_swarm(Transition::DkgRecovery).await;
    let client = swarm.validators().next().unwrap().rest_client();
    let offline = swarm.validators().last().unwrap().peer_id();

    let deadline = Instant::now() + Duration::from_secs(90);
    let (frozen_version, session, cached, old_clock) = loop {
        assert!(
            Instant::now() < deadline,
            "DKG did not freeze within 90 seconds"
        );
        let ledger = client.get_ledger_information().await.unwrap().into_inner();
        let dkg = resource_at_version::<DKGState>(&client, ledger.version).await;
        if let Some(session) = dkg.in_progress {
            assert_eq!(session.metadata.dealer_epoch, ledger.epoch);
            let (cached, fallback) = client
                .get_account_resource_at_version_bcs::<(ValidatorSet, bool)>(
                    CORE_CODE_ADDRESS,
                    "0x1::stake::PrecomputedValidatorSet",
                    ledger.version,
                )
                .await
                .unwrap()
                .into_inner();
            assert!(!fallback);
            assert_targets(&session.metadata.target_validator_set, &cached);
            let clock = client
                .get_account_resource_at_version_bcs::<(u64, u64, u64, u64)>(
                    CORE_CODE_ADDRESS,
                    "0x1::poc_power_store::PeriodClock",
                    ledger.version,
                )
                .await
                .unwrap()
                .into_inner();
            break (ledger.version, session, cached, clock);
        }
        tokio::time::sleep(Duration::from_secs(1)).await;
    };
    let frozen_context = frozen_context_at(&client, frozen_version).await;
    swarm.validator_mut(offline).unwrap().stop();

    // 四个等权验证者中有三个继续出块，统计和费用仍归属旧 Epoch。
    let deadline = Instant::now() + Duration::from_secs(30);
    let waiting = loop {
        assert!(
            Instant::now() < deadline,
            "Old committee stopped producing blocks"
        );
        let ledger = client.get_ledger_information().await.unwrap().into_inner();
        if ledger.version > frozen_version {
            break ledger;
        }
        tokio::time::sleep(Duration::from_secs(1)).await;
    };
    assert_eq!(waiting.epoch, session.metadata.dealer_epoch);
    assert_eq!(
        frozen_context_at(&client, waiting.version).await,
        frozen_context,
        "Old-epoch blocks must preserve the frozen target, clock and reward snapshots",
    );
    assert_eq!(
        resource_at_version::<DKGState>(&client, waiting.version)
            .await
            .in_progress,
        Some(session.clone())
    );

    // 冻结期间重启节点，其余三个节点的 DKG 任务仍暂停，
    // 单个恢复的 dealer 无法在治理交易前完成新的 transcript。
    swarm
        .validator_mut(offline)
        .unwrap()
        .restart()
        .await
        .unwrap();
    swarm
        .wait_for_all_nodes_to_catchup_to_version(waiting.version, Duration::from_secs(30))
        .await
        .unwrap();
    let restarted = swarm.validator(offline).unwrap().rest_client();
    // 启动配置在重启后再次生效；仅恢复这个 dealer，其余三个仍保持暂停。
    restarted
        .set_failpoint("dkg::process_dkg_start_event".to_owned(), "off".to_owned())
        .await
        .expect("PoC recovery requires a node binary built with failpoints");
    let restored = restarted
        .get_ledger_information()
        .await
        .unwrap()
        .into_inner();
    assert_eq!(restored.epoch, session.metadata.dealer_epoch);
    assert_eq!(
        frozen_context_at(&restarted, restored.version).await,
        frozen_context,
        "Restart must preserve the original frozen plan and reward snapshots",
    );

    // 通过原有测试网治理入口调用同一强制结束函数，权限和计划校验与正常治理流程一致。
    let chain = swarm.chain_info();
    let transaction = chain.root_account().sign_with_transaction_builder(
        chain
            .transaction_factory()
            .with_gas_unit_price(1)
            .with_max_gas_amount(2000000)
            .with_transaction_expiration_time(60)
            .payload(aptos_stdlib::topo_governance_force_end_epoch_test_only()),
    );
    let Transaction::UserTransaction(transaction) = tokio::time::timeout(
        Duration::from_secs(90),
        client.submit_and_wait(&transaction),
    )
    .await
    .expect("Governance recovery exceeded 90 seconds")
    .unwrap()
    .into_inner() else {
        panic!("Expected governance transaction")
    };
    assert!(transaction.info.success);
    let version = transaction.info.version.0;
    for name in [
        "::stake::PoCEpochInstalled",
        "::reconfiguration::NewEpochEvent",
    ] {
        assert_eq!(
            transaction
                .events
                .iter()
                .filter(|event| event.typ.to_string().ends_with(name))
                .count(),
            1
        );
    }
    let rewards = transaction
        .events
        .iter()
        .filter(|event| {
            event
                .typ
                .to_string()
                .ends_with("::stake::PoCRewardCredited")
        })
        .collect::<Vec<_>>();
    assert_eq!(rewards.len(), 4);
    for event in rewards {
        assert_eq!(
            event.data["closing_epoch"]
                .as_str()
                .unwrap()
                .parse::<u64>()
                .unwrap(),
            session.metadata.dealer_epoch
        );
    }
    let installed = resource_at_version::<ValidatorSet>(&client, version).await;
    assert_eq!(installed, cached);
    assert_targets(&session.metadata.target_validator_set, &installed);
    let new_clock = client
        .get_account_resource_at_version_bcs::<(u64, u64, u64, u64)>(
            CORE_CODE_ADDRESS,
            "0x1::poc_power_store::PeriodClock",
            version,
        )
        .await
        .unwrap()
        .into_inner();
    assert_eq!(new_clock.1, old_clock.1 + 1);
    assert!(resource_at_version::<DKGState>(&client, version)
        .await
        .in_progress
        .is_none());
    for name in ["EpochPlan", "PrecomputedValidatorSet"] {
        assert!(
            optional_resource_at_version(
                &client,
                CORE_CODE_ADDRESS,
                &format!("0x1::stake::{name}"),
                version,
            )
            .await
            .is_none(),
            "Committed PoC transition left {name} at version {version}",
        );
    }

    for node in swarm.validators() {
        node.rest_client()
            .set_failpoint("dkg::process_dkg_start_event".to_owned(), "off".to_owned())
            .await
            .unwrap();
    }
    assert_installed_on_all_nodes(&swarm, version, session.target_epoch(), &installed, 5000).await;
}
