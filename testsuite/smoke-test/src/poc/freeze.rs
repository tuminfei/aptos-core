// Copyright (c) Aptos Foundation
// Licensed pursuant to the Innovation-Enabling Source Code License, available at https://github.com/aptos-labs/aptos-core/blob/main/LICENSE

//! FRZ-01 / FRZ-03：在真实 DKG 暂停前、暂停中和恢复后验证公开入口的身份权限。
//! 使用显式配置的四节点 A fixture，不作为 T2 默认配置测试。

use super::{
    assert_targets,
    defaults::installed_at,
    frozen_context_at, optional_resource_at_version, poc_swarm_builder, resource_at_version,
    transactions::{assert_abort, compile_script, execute},
    Transition,
};
use aptos_api_types::{AptosErrorCode, UserTransaction, ViewRequest};
use aptos_cached_packages::aptos_stdlib;
use aptos_crypto::{bls12381, Uniform};
use aptos_forge::{LocalSwarm, NodeExt, Swarm, SwarmExt};
use aptos_genesis::poc::{DeploymentLimits, DeploymentMode, PocGenesisConfiguration, PowerParams};
use aptos_rest_client::{error::RestError, Client};
use aptos_sdk::{transaction_builder::TransactionFactory, types::LocalAccount};
use aptos_types::{
    account_address::AccountAddress,
    account_config::CORE_CODE_ADDRESS,
    dkg::DKGState,
    on_chain_config::{
        ConfigurationResource, OnChainChunkyDKGConfig, OnChainRandomnessConfig, ValidatorSet,
    },
    transaction::{Script, TransactionArgument, TransactionPayload},
    validator_config::ValidatorConfig,
};
use move_core_types::int256::U256;
use once_cell::sync::Lazy;
use serde_json::{json, Value};
use std::{collections::BTreeMap, sync::Arc, time::Duration};

const DKG_FAILPOINT: &str = "dkg::process_dkg_start_event";
const UNIT_SCALE: u128 = 1 << 32;

#[derive(Clone, Copy, Debug)]
#[repr(u8)]
enum Governance {
    Operator,
    Period,
    SchedulePower,
    CancelPower,
    ScheduleSplit,
    CancelSplit,
    StakeBounds,
    BufferRandomness,
    InstallRandomness,
    Start,
    Finish,
    EnablePool,
    RewardConfig,
    RewardRateFeature,
}

static GOVERNANCE_SCRIPT: Lazy<Vec<u8>> = Lazy::new(|| {
    // 两个分支调用完全相同的公开函数。反例分支传入实际发送者，
    // 使权限错误来自被测入口，
    // 而非提前在 get_signer_testnet_only 中失败。
    let body = r#"
        if (operation == 0) {
            poc_power_store::set_operator(AUTHORITY, address);
        } else if (operation == 1) {
            poc_power_store::set_power_period_in_epochs(AUTHORITY, value);
        } else if (operation == 2) {
            poc_allocation::schedule_power_params(AUTHORITY,
                poc_accounting::new_power_params(100000000, 10, value, 4), target_epoch);
        } else if (operation == 3) {
            poc_allocation::cancel_pending_power_params(AUTHORITY);
        } else if (operation == 4) {
            stake::schedule_reward_split(AUTHORITY, value, target_epoch);
        } else if (operation == 5) {
            stake::cancel_pending_reward_split(AUTHORITY);
        } else if (operation == 6) {
            staking_config::update_required_stake(AUTHORITY, 1, value);
        } else if (operation == 7) {
            randomness_api_v0_config::set_for_next_epoch(AUTHORITY, option::some(value));
        } else if (operation == 8) {
            randomness_api_v0_config::on_new_epoch(AUTHORITY);
        } else if (operation == 9) {
            topo_governance::reconfigure(AUTHORITY);
        } else if (operation == 10) {
            topo_governance::force_end_epoch(AUTHORITY);
        } else if (operation == 11) {
            poc_allocation::enable_pool(AUTHORITY, address);
        } else if (operation == 12) {
            staking_config::update_rewards_config(AUTHORITY,
                fixed_point64::create_from_rational((value as u128), 10000),
                fixed_point64::create_from_rational(0, 1),
                31536000,
                fixed_point64::create_from_rational(0, 1));
        } else {
            assert!(operation == 13, 0);
            if (value == 0) {
                features::change_feature_flags_for_next_epoch(AUTHORITY, vector[],
                    vector[features::get_periodical_reward_rate_decrease_feature()]);
            } else {
                features::change_feature_flags_for_next_epoch(AUTHORITY,
                    vector[features::get_periodical_reward_rate_decrease_feature()], vector[]);
            };
        };
"#;
    compile_script(
        "PoCFreezePublicEntries",
        &format!(
            r#"
script {{
    use std::option;
    use std::features;
    use topo_std::fixed_point64;
    use topo_framework::poc_accounting;
    use topo_framework::poc_allocation;
    use topo_framework::poc_power_store;
    use topo_framework::randomness_api_v0_config;
    use topo_framework::stake;
    use topo_framework::staking_config;
    use topo_framework::topo_governance;

    fun main(sender: &signer, governed: bool, operation: u8, address: address, value: u64, target_epoch: u64) {{
        if (governed) {{
            let framework = topo_governance::get_signer_testnet_only(sender, @0x1);
            {}
        }} else {{
            {}
        }};
    }}
}}
"#,
            body.replace("AUTHORITY", "&framework"),
            body.replace("AUTHORITY", "sender"),
        ),
    )
});

fn governance_payload(
    action: Governance,
    governed: bool,
    address: AccountAddress,
    value: u64,
    target_epoch: u64,
) -> TransactionPayload {
    TransactionPayload::Script(Script::new(GOVERNANCE_SCRIPT.clone(), vec![], vec![
        TransactionArgument::Bool(governed),
        TransactionArgument::U8(action as u8),
        TransactionArgument::Address(address),
        TransactionArgument::U64(value),
        TransactionArgument::U64(target_epoch),
    ]))
}

#[derive(Clone, Copy, Debug)]
enum Call {
    Upload,
    RepeatUpload,
    Allocation,
    Govern(Governance),
    NetworkAddresses,
    ConsensusKey,
}

const CASES: [Call; 16] = [
    Call::Upload,
    Call::RepeatUpload,
    Call::Allocation,
    Call::Govern(Governance::Operator),
    Call::Govern(Governance::Period),
    Call::Govern(Governance::SchedulePower),
    Call::Govern(Governance::CancelPower),
    Call::Govern(Governance::ScheduleSplit),
    Call::Govern(Governance::CancelSplit),
    Call::Govern(Governance::StakeBounds),
    Call::Govern(Governance::BufferRandomness),
    Call::Govern(Governance::InstallRandomness),
    Call::NetworkAddresses,
    Call::ConsensusKey,
    Call::Govern(Governance::RewardConfig),
    Call::Govern(Governance::RewardRateFeature),
];

impl Call {
    fn path(self) -> &'static str {
        match self {
            Self::Upload | Self::RepeatUpload => "poc_power_store::stage_batch_update",
            Self::Allocation => "poc_allocation::set_allocations -> poc_accounting::replace_allocation",
            Self::Govern(Governance::Operator) => "governance script -> poc_power_store::set_operator",
            Self::Govern(Governance::Period) => "governance script -> poc_power_store::set_power_period_in_epochs",
            Self::Govern(Governance::SchedulePower) => "governance script -> poc_allocation::schedule_power_params -> poc_accounting::schedule_power_params",
            Self::Govern(Governance::CancelPower) => "governance script -> poc_allocation::cancel_pending_power_params -> poc_accounting::cancel_pending_power_params",
            Self::Govern(Governance::ScheduleSplit) => "governance script -> stake::schedule_reward_split -> poc_reward_split::schedule_change",
            Self::Govern(Governance::CancelSplit) => "governance script -> stake::cancel_pending_reward_split -> poc_reward_split::cancel_pending_change",
            Self::Govern(Governance::StakeBounds) => "governance script -> staking_config::update_required_stake",
            Self::Govern(Governance::BufferRandomness) => "governance script -> randomness_api_v0_config::set_for_next_epoch -> config_buffer::upsert",
            Self::Govern(Governance::InstallRandomness) => "governance script -> randomness_api_v0_config::on_new_epoch",
            Self::Govern(Governance::RewardConfig) => "governance script -> staking_config::update_rewards_config",
            Self::Govern(Governance::RewardRateFeature) => "governance script -> features::change_feature_flags_for_next_epoch",
            Self::NetworkAddresses => "stake::update_network_and_fullnode_addresses",
            Self::ConsensusKey => "stake::rotate_consensus_key（新公钥及有效持有证明）",
            Self::Govern(Governance::EnablePool) => "governance script -> poc_allocation::enable_pool -> poc_accounting::enable_pool",
            Self::Govern(Governance::Start | Governance::Finish) => panic!("Transition driver is not a matrix case"),
        }
    }

    fn frozen_error(self, unauthorized: bool) -> (&'static str, u64) {
        match self {
            Self::Upload | Self::RepeatUpload | Self::Allocation => ("poc_accounting", 0x3000B),
            Self::NetworkAddresses | Self::ConsensusKey => ("stake", 0x30014),
            Self::Govern(action) => match action {
                Governance::StakeBounds
                | Governance::InstallRandomness
                | Governance::RewardConfig => ("reconfiguration_state", 0x30002),
                Governance::RewardRateFeature => {
                    if unauthorized {
                        ("system_addresses", 0x50001)
                    } else {
                        ("features", 0x30004)
                    }
                },
                Governance::Operator
                | Governance::Period
                | Governance::SchedulePower
                | Governance::CancelPower
                | Governance::EnablePool => {
                    if unauthorized {
                        ("system_addresses", 0x50003)
                    } else {
                        ("poc_accounting", 0x3000B)
                    }
                },
                Governance::ScheduleSplit | Governance::CancelSplit => {
                    if unauthorized {
                        ("system_addresses", 0x50003)
                    } else {
                        ("poc_reward_split", 0x30003)
                    }
                },
                Governance::BufferRandomness => {
                    if unauthorized {
                        ("system_addresses", 0x50003)
                    } else {
                        ("reconfiguration_state", 0x30002)
                    }
                },
                Governance::Start | Governance::Finish => {
                    panic!("Transition driver is not a matrix case")
                },
            },
        }
    }

    fn unauthorized_error(self) -> Option<(&'static str, u64)> {
        match self {
            Self::Upload | Self::RepeatUpload => Some(("poc_power_store", 0x50002)),
            Self::NetworkAddresses | Self::ConsensusKey => Some(("stake", 0x40009)),
            Self::Govern(Governance::RewardRateFeature) => Some(("system_addresses", 0x50001)),
            Self::Govern(_) => Some(("system_addresses", 0x50003)),
            // 此 API 不接收 owner 地址参数，每个签名者都拥有自己的分配；
            // 应验证账户隔离，不构造不存在的非法角色。
            Self::Allocation => None,
        }
    }
}

pub(super) struct Fixture {
    pub(super) swarm: LocalSwarm,
    pub(super) client: Client,
    pub(super) factory: TransactionFactory,
    pub(super) root: Arc<LocalAccount>,
    uploader: LocalAccount,
    next_uploader: LocalAccount,
    warm_user: LocalAccount,
    cold_user: LocalAccount,
    pub(super) attacker: LocalAccount,
    validator_operator: LocalAccount,
    validator_config: ValidatorConfig,
    consensus_pop: Vec<u8>,
    matrix_consensus_public_key: Vec<u8>,
    matrix_consensus_pop: Vec<u8>,
    matrix_validator_network_addresses: Vec<u8>,
    matrix_fullnode_network_addresses: Vec<u8>,
    pub(super) pools: Vec<AccountAddress>,
    period: u64,
}

impl Fixture {
    fn actor(&self, call: Call) -> &LocalAccount {
        match call {
            Call::Upload | Call::RepeatUpload => &self.uploader,
            Call::Allocation => &self.warm_user,
            Call::Govern(_) => &self.root,
            Call::NetworkAddresses | Call::ConsensusKey => &self.validator_operator,
        }
    }

    fn payload(
        &self,
        call: Call,
        governed: bool,
        before_freeze: bool,
        epoch: u64,
    ) -> TransactionPayload {
        match call {
            Call::Upload | Call::RepeatUpload => {
                let user = if before_freeze || matches!(call, Call::RepeatUpload) {
                    self.warm_user.address()
                } else {
                    self.cold_user.address()
                };
                aptos_stdlib::poc_power_store_stage_batch_update(self.period + 1, vec![user], vec![
                    17,
                ])
            },
            Call::Allocation => {
                aptos_stdlib::poc_allocation_set_allocations(vec![self.pools[0]], vec![10_000])
            },
            Call::Govern(action) => {
                let value = match action {
                    Governance::Period => 2,
                    Governance::SchedulePower => 990,
                    Governance::ScheduleSplit => 6000,
                    Governance::StakeBounds => 900,
                    Governance::BufferRandomness => 123,
                    Governance::RewardConfig => {
                        if before_freeze {
                            500
                        } else {
                            400
                        }
                    },
                    // 非治理反例使用“启用”方向，避免交易验证器在执行权限检查前
                    // 拒绝关闭当前 VM 所依赖的功能；授权路径仍验证关闭与恢复。
                    Governance::RewardRateFeature => {
                        if governed {
                            0
                        } else {
                            1
                        }
                    },
                    Governance::Operator
                    | Governance::CancelPower
                    | Governance::CancelSplit
                    | Governance::InstallRandomness
                    | Governance::Start
                    | Governance::Finish
                    | Governance::EnablePool => 0,
                };
                governance_payload(
                    action,
                    governed,
                    self.next_uploader.address(),
                    value,
                    epoch + 1,
                )
            },
            // 两类地址均改用创世已验证的另一组合法 BCS 地址。
            // 冻结前测试会恢复节点磁盘实际使用的创世值。
            Call::NetworkAddresses => aptos_stdlib::stake_update_network_and_fullnode_addresses(
                self.validator_operator.address(),
                self.matrix_validator_network_addresses.clone(),
                self.matrix_fullnode_network_addresses.clone(),
            ),
            Call::ConsensusKey => aptos_stdlib::stake_rotate_consensus_key(
                self.validator_operator.address(),
                self.matrix_consensus_public_key.clone(),
                self.matrix_consensus_pop.clone(),
            ),
        }
    }

    fn users(&self) -> [AccountAddress; 3] {
        [
            self.warm_user.address(),
            self.cold_user.address(),
            self.attacker.address(),
        ]
    }

    fn original_validator_payload(&self, call: Call) -> TransactionPayload {
        match call {
            Call::NetworkAddresses => aptos_stdlib::stake_update_network_and_fullnode_addresses(
                self.validator_operator.address(),
                self.validator_config.validator_network_addresses.clone(),
                self.validator_config.fullnode_network_addresses.clone(),
            ),
            Call::ConsensusKey => aptos_stdlib::stake_rotate_consensus_key(
                self.validator_operator.address(),
                self.validator_config
                    .consensus_public_key
                    .to_bytes()
                    .to_vec(),
                self.consensus_pop.clone(),
            ),
            _ => panic!("只有验证者配置入口具有创世值恢复负载"),
        }
    }
}

pub(super) async fn fixture() -> Fixture {
    fixture_with_split(0).await
}

async fn fixture_with_split(native_reward_bps: u64) -> Fixture {
    Lazy::force(&GOVERNANCE_SCRIPT);
    println!("FRZ fixture A: nodes=4, Open, epoch=3600s, ordinary DKG=on, Chunky=off, failpoints initially off, initial_power=10, bond=100 Octa, min_power=10, min_validators=4, validator_limit=5, growth=25%, retention_bps=10000, native_reward_bps={native_reward_bps}, fee_limit=0; transaction gas price=100, max_gas=2000000");
    let swarm = poc_swarm_builder(Transition::Dkg)
        .with_init_config(Arc::new(|_, config, _| {
            config.api.failpoints_enabled = true
        }))
        .with_init_genesis_config(Arc::new(move |config| {
            config.is_test = true;
            config.allow_new_validators = true;
            config.epoch_duration_secs = 3600;
            config.min_stake = 1;
            config.max_stake = 1000;
            config.voting_power_increase_limit = 25;
            config.consensus_config.enable_validator_txns();
            config.randomness_config_override = Some(OnChainRandomnessConfig::default_enabled());
            config.chunky_dkg_config_override = Some(OnChainChunkyDKGConfig::default_disabled());
            config.poc_genesis_config = Some(Arc::new(move |_| PocGenesisConfiguration {
                params: PowerParams {
                    bond_octa_per_ohmp: 100_000_000,
                    min_power: 10,
                    max_power: 1000,
                    min_validators: 4,
                },
                limits: DeploymentLimits {
                    max_allocations: 4,
                    max_claim_pools: 4,
                    max_upload_users: 4,
                    validator_limit: 5,
                    max_reward_base_octa: 1000,
                    rate_max_num: 1,
                    rate_max_den: 1,
                    fee_max: 10,
                    reward_epoch_limit: 1000,
                },
                deployment_mode: DeploymentMode::Open,
                retention_bps: 10000,
                max_relative_period: 100,
                initial_raw_power: 10,
                native_reward_bps,
            }));
        }))
        .build()
        .await;
    swarm
        .wait_for_all_nodes_to_catchup_to_epoch(2, Duration::from_secs(90))
        .await
        .unwrap();
    let client = swarm.validators().next().unwrap().rest_client();
    let initial = client.get_ledger_information().await.unwrap().into_inner();
    let initial_epoch = epoch_at(&client, initial.version).await;
    let dkg = resource_at_version::<DKGState>(&client, initial.version).await;
    assert!(dkg.in_progress.is_none());
    let completed = dkg.last_completed.expect("Expected a real initial DKG");
    assert_eq!(completed.target_epoch(), initial_epoch);
    assert!(!completed.transcript.is_empty());
    let root = swarm.chain_info().root_account();
    let factory = swarm
        .chain_info()
        .transaction_factory()
        .with_gas_unit_price(100)
        .with_max_gas_amount(2_000_000)
        .with_transaction_expiration_time(60);
    let pools = swarm
        .validators()
        .map(|node| node.peer_id())
        .collect::<Vec<_>>();
    let node = swarm.validators().next().unwrap();
    let operator_address = node.peer_id();
    let operator_key = node.account_private_key().as_ref().unwrap().private_key();
    let mut public = swarm.chain_info().into_aptos_public_info();
    let uploader = public
        .create_and_fund_user_account(1_000_000_000)
        .await
        .unwrap();
    let next_uploader = public
        .create_and_fund_user_account(1_000_000_000)
        .await
        .unwrap();
    let warm_user = public
        .create_and_fund_user_account(1_000_000_000)
        .await
        .unwrap();
    let cold_user = public
        .create_and_fund_user_account(1_000_000_000)
        .await
        .unwrap();
    let attacker = public
        .create_and_fund_user_account(1_000_000_000)
        .await
        .unwrap();
    public.mint(operator_address, 1_000_000_000).await.unwrap();
    let sequence = client
        .get_account(operator_address)
        .await
        .unwrap()
        .into_inner()
        .sequence_number;
    let validator_operator = LocalAccount::new(operator_address, operator_key, sequence);
    let validator_config: ValidatorConfig = client
        .get_account_resource_at_version_bcs(
            operator_address,
            "0x1::stake::ValidatorConfig",
            initial.version,
        )
        .await
        .unwrap()
        .into_inner();
    // 复用本地 fixture 已配置的密钥，仅将公开证明带出此作用域；
    // 不修改密钥或身份文件，也不将其写入日志。
    let consensus_pop = {
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
            validator_config.consensus_public_key
        );
        bls12381::ProofOfPossession::create(&key)
            .to_bytes()
            .to_vec()
    };
    // 矩阵使用独立生成的密钥和对应 PoP，通过生产入口的真实密码校验；
    // 私钥在此作用域结束时丢弃，不写入节点配置或日志。
    let (matrix_consensus_public_key, matrix_consensus_pop) = {
        let key = bls12381::PrivateKey::generate(&mut rand::thread_rng());
        (
            bls12381::PublicKey::from(&key).to_bytes().to_vec(),
            bls12381::ProofOfPossession::create(&key)
                .to_bytes()
                .to_vec(),
        )
    };
    assert_ne!(
        matrix_consensus_public_key,
        validator_config.consensus_public_key.to_bytes().to_vec()
    );
    // 交换两组均已由创世验证过的 BCS 网络地址，既能覆盖验证者共识网络地址，
    // 又无需拼装可能无法通过生产入口校验的伪造协议。冻结前会恢复创世值。
    let matrix_validator_network_addresses = validator_config.fullnode_network_addresses.clone();
    let matrix_fullnode_network_addresses = validator_config.validator_network_addresses.clone();
    assert_ne!(
        matrix_validator_network_addresses, validator_config.validator_network_addresses,
        "fixture 必须提供不同的 validator 与 fullnode 地址，才能观察验证者地址写入"
    );
    assert_ne!(
        matrix_fullnode_network_addresses, validator_config.fullnode_network_addresses,
        "fixture 必须提供不同的 validator 与 fullnode 地址，才能观察公开入口写入"
    );
    let ledger = client.get_ledger_information().await.unwrap().into_inner();
    let epoch = epoch_at(&client, ledger.version).await;
    assert_eq!(epoch, initial_epoch);
    let clock = view(
        &client,
        "poc_power_store::get_normalization_clock",
        vec![],
        ledger.version,
    )
    .await;
    let period = clock[1].as_str().unwrap().parse().unwrap();
    assert_eq!(period, 0);
    assert_eq!(clock[2], json!("61"));
    let configured = execute(
        &client,
        &root,
        &factory,
        governance_payload(Governance::Operator, true, uploader.address(), 0, epoch + 1),
    )
    .await;
    assert!(configured.info.success, "{}", configured.info.vm_status);
    Fixture {
        swarm,
        client,
        factory,
        root,
        uploader,
        next_uploader,
        warm_user,
        cold_user,
        attacker,
        validator_operator,
        validator_config,
        consensus_pop,
        matrix_consensus_public_key,
        matrix_consensus_pop,
        matrix_validator_network_addresses,
        matrix_fullnode_network_addresses,
        pools,
        period,
    }
}

/// 新 Epoch 的首个版本中，REST 账本响应头仍可能报告待结束的 Epoch；
/// 业务断言须读取该版本对应的链上资源。
pub(super) async fn epoch_at(client: &Client, version: u64) -> u64 {
    resource_at_version::<ConfigurationResource>(client, version)
        .await
        .epoch()
}

pub(super) async fn assert_installed(
    f: &Fixture,
    version: u64,
    epoch: u64,
    expected: &ValidatorSet,
    expected_bps: u64,
    expected_pending: Option<(u64, u64)>,
) {
    f.swarm
        .wait_for_all_nodes_to_catchup_to_version(version, Duration::from_secs(30))
        .await
        .unwrap();
    let installed = installed_at(&f.client, version).await;
    assert_eq!(installed.epoch, epoch);
    assert_eq!(&installed.validators, expected);
    assert_eq!(installed.validators.active_validators.len(), 4);
    assert!(installed.validators.pending_active.is_empty());
    assert!(installed.validators.pending_inactive.is_empty());
    assert_eq!(installed.validators.total_voting_power, 40);
    assert_eq!(installed.validators.total_joining_power, 0);
    assert!(installed
        .validators
        .active_validators
        .iter()
        .all(|validator| validator.consensus_voting_power() == 10));
    assert_eq!(installed.reward_context.0, epoch);
    assert!(installed.reward_context.1);
    assert_eq!(installed.reward_context.5, 0);
    let pending = expected_pending
        .map(|(bps, activation_epoch)| {
            json!({
                "native_reward_bps": bps.to_string(),
                "activation_epoch": activation_epoch.to_string(),
            })
        })
        .into_iter()
        .collect::<Vec<_>>();
    assert_eq!(
        installed.reward_split,
        json!({
            "installed_epoch": epoch.to_string(),
            "configured_native_reward_bps": expected_bps.to_string(),
            "installed_native_reward_bps": expected_bps.to_string(),
            "pending_change": {"vec": pending},
        })
    );
    for node in f.swarm.validators() {
        assert_eq!(installed_at(&node.rest_client(), version).await, installed);
    }
}

async fn view(client: &Client, name: &str, arguments: Vec<Value>, version: u64) -> Vec<Value> {
    client
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

async fn resource(client: &Client, address: AccountAddress, name: &str, version: u64) -> Value {
    optional_resource_at_version(client, address, &format!("0x1::{name}"), version)
        .await
        .unwrap_or_else(|| panic!("Missing {name} at {version}"))
        .data
}

/// 在共用的 PoC 账本和表项检查之外，补充原生配置、缓冲配置字节、
/// 运营者和验证者资源、计划/PVS，以及 DKG 会话状态。
async fn protected_state(f: &Fixture, version: u64) -> BTreeMap<String, Option<Value>> {
    let mut state = BTreeMap::new();
    for name in [
        "staking_config::StakingConfig",
        "staking_config::StakingRewardsConfig",
        "features::Features",
        "features::PendingFeatures",
        "features::PendingFeatureFreeze",
        "config_buffer::PendingConfigs",
        "randomness_api_v0_config::RequiredGasDeposit",
        "randomness_api_v0_config::AllowCustomMaxGasFlag",
        "reconfiguration_state::State",
        "stake::EpochPlan",
        "stake::PrecomputedValidatorSet",
        "dkg::DKGState",
    ] {
        state.insert(
            name.to_owned(),
            optional_resource_at_version(
                &f.client,
                CORE_CODE_ADDRESS,
                &format!("0x1::{name}"),
                version,
            )
            .await
            .map(|r| r.data),
        );
    }
    for name in ["stake::ValidatorConfig", "stake::StakePool"] {
        state.insert(
            name.to_owned(),
            Some(resource(&f.client, f.validator_operator.address(), name, version).await),
        );
    }
    state
}

async fn reject(f: &Fixture, call: Call, unauthorized: bool, frozen: bool, epoch: u64) {
    let actor = if unauthorized {
        &f.attacker
    } else {
        f.actor(call)
    };
    let error = if frozen {
        call.frozen_error(unauthorized)
    } else {
        call.unauthorized_error()
            .expect("Allocation has no forbidden signer role")
    };
    println!("FRZ case={call:?} path={} frozen={frozen} unauthorized={unauthorized} expected=0x1::{}:{:#x}", call.path(), error.0, error.1);
    // feature 配置在生产中由治理包装路径取得框架 signer；非法身份也沿该路径
    // 验证 get_signer_testnet_only 的权限，避免 VM 在脚本执行前拒绝 feature 变更。
    let governed = !unauthorized || matches!(call, Call::Govern(Governance::RewardRateFeature));
    let transaction = execute(
        &f.client,
        actor,
        &f.factory,
        f.payload(call, governed, false, epoch),
    )
    .await;
    assert_abort(
        &f.client,
        &transaction,
        error.0,
        error.1,
        &f.users(),
        &f.pools,
    )
    .await;
    let version = transaction.info.version.0;
    assert_eq!(
        protected_state(f, version - 1).await,
        protected_state(f, version).await
    );
    assert!(
        transaction.events.iter().all(|event| {
            let name = event.typ.to_string();
            !name.contains("::stake::")
                && !name.contains("::poc_")
                && !name.contains("::randomness_api_v0_config::")
                && !name.contains("::reconfiguration::")
        }),
        "Rejected public call emitted a business event: {:?}",
        transaction.events
    );
}

fn events<'a>(transaction: &'a UserTransaction, suffix: &str) -> Vec<&'a aptos_api_types::Event> {
    transaction
        .events
        .iter()
        .filter(|event| event.typ.to_string().ends_with(suffix))
        .collect()
}

async fn succeed(f: &Fixture, call: Call, before_freeze: bool, epoch: u64) {
    println!(
        "FRZ case={call:?} path={} phase={}",
        call.path(),
        if before_freeze { "before" } else { "restored" }
    );
    let transaction = execute(
        &f.client,
        f.actor(call),
        &f.factory,
        f.payload(call, true, before_freeze, epoch),
    )
    .await;
    assert!(transaction.info.success, "{}", transaction.info.vm_status);
    let version = transaction.info.version.0;
    match call {
        Call::Upload => {
            let user = if before_freeze {
                f.warm_user.address()
            } else {
                f.cold_user.address()
            };
            for suffix in [
                "::poc_power_store::PowerNormalized",
                "::poc_power_store::PowerUpdateStagedEvent",
            ] {
                let observed = events(&transaction, suffix);
                assert_eq!(observed.len(), 1);
                assert_eq!(
                    AccountAddress::from_hex_literal(observed[0].data["user"].as_str().unwrap())
                        .unwrap(),
                    user
                );
            }
            assert_eq!(
                view(
                    &f.client,
                    "poc_power_store::get_accounting_snapshot",
                    vec![json!(user)],
                    version
                )
                .await,
                vec![
                    json!("0"),
                    json!((17 * UNIT_SCALE).to_string()),
                    json!(f.period.to_string()),
                    json!("61")
                ]
            );
        },
        Call::RepeatUpload => {
            assert!(events(&transaction, "::poc_power_store::PowerNormalized").is_empty());
            assert!(events(&transaction, "::poc_power_store::PowerUpdateStagedEvent").is_empty());
            assert_eq!(
                view(
                    &f.client,
                    "poc_power_store::get_accounting_snapshot",
                    vec![json!(f.warm_user.address())],
                    version - 1
                )
                .await,
                view(
                    &f.client,
                    "poc_power_store::get_accounting_snapshot",
                    vec![json!(f.warm_user.address())],
                    version
                )
                .await
            );
        },
        Call::Allocation => {
            let observed = events(&transaction, "::poc_accounting::AllocationScheduled");
            assert_eq!(observed.len(), 1);
            assert_eq!(
                observed[0].data["effective_epoch"],
                json!((epoch + 1).to_string())
            );
            let position = view(
                &f.client,
                "poc_accounting::get_position",
                vec![json!(f.warm_user.address()), json!(f.pools[0])],
                version,
            )
            .await;
            assert_eq!(position[0], json!("0"));
            assert_eq!(
                position[1],
                json!([{"epoch": "61", "units": (17 * UNIT_SCALE).to_string()}])
            );
        },
        Call::Govern(action) => match action {
            Governance::Operator => {
                let observed = events(&transaction, "::poc_power_store::OperatorChangedEvent");
                assert_eq!(observed.len(), 1);
                let configured =
                    view(&f.client, "poc_power_store::get_operator", vec![], version).await;
                assert_eq!(
                    AccountAddress::from_hex_literal(configured[0].as_str().unwrap()).unwrap(),
                    f.next_uploader.address()
                );
                // 所有阶段和用例均保持相同的上传者角色。
                let restored = execute(
                    &f.client,
                    &f.root,
                    &f.factory,
                    governance_payload(
                        Governance::Operator,
                        true,
                        f.uploader.address(),
                        0,
                        epoch + 1,
                    ),
                )
                .await;
                assert!(restored.info.success, "{}", restored.info.vm_status);
            },
            Governance::Period => {
                assert_eq!(
                    view(
                        &f.client,
                        "poc_power_store::get_power_period_in_epochs",
                        vec![],
                        version
                    )
                    .await,
                    vec![json!("2")]
                );
                assert_eq!(
                    view(
                        &f.client,
                        "poc_power_store::get_normalization_clock",
                        vec![],
                        version
                    )
                    .await[2],
                    json!("61")
                );
            },
            Governance::SchedulePower => {
                let state = resource(
                    &f.client,
                    CORE_CODE_ADDRESS,
                    "poc_accounting::AccountingState",
                    version,
                )
                .await;
                assert_eq!(
                    state["config"]["pending_params"]["vec"][0]["epoch"],
                    json!((epoch + 1).to_string())
                );
                assert_eq!(
                    state["config"]["pending_params"]["vec"][0]["params"]["max_power"],
                    json!("990")
                );
            },
            Governance::CancelPower => assert_eq!(
                resource(
                    &f.client,
                    CORE_CODE_ADDRESS,
                    "poc_accounting::AccountingState",
                    version
                )
                .await["config"]["pending_params"]["vec"],
                json!([])
            ),
            Governance::ScheduleSplit => {
                assert_eq!(
                    events(&transaction, "::poc_reward_split::RewardSplitScheduled").len(),
                    1
                );
                let state = resource(
                    &f.client,
                    CORE_CODE_ADDRESS,
                    "poc_reward_split::RewardSplitConfig",
                    version,
                )
                .await;
                assert_eq!(
                    state["pending_change"]["vec"][0],
                    json!({"native_reward_bps": "6000", "activation_epoch": (epoch + 1).to_string()})
                );
                assert_eq!(state["installed_native_reward_bps"], json!("0"));
            },
            Governance::CancelSplit => {
                assert_eq!(
                    events(&transaction, "::poc_reward_split::RewardSplitCancelled").len(),
                    1
                );
                assert_eq!(
                    resource(
                        &f.client,
                        CORE_CODE_ADDRESS,
                        "poc_reward_split::RewardSplitConfig",
                        version
                    )
                    .await["pending_change"]["vec"],
                    json!([])
                );
            },
            Governance::StakeBounds => {
                let state = resource(
                    &f.client,
                    CORE_CODE_ADDRESS,
                    "staking_config::StakingConfig",
                    version,
                )
                .await;
                assert_eq!(state["minimum_stake"], json!("1"));
                assert_eq!(state["maximum_stake"], json!("900"));
            },
            Governance::BufferRandomness => {
                let before = resource(
                    &f.client,
                    CORE_CODE_ADDRESS,
                    "config_buffer::PendingConfigs",
                    version - 1,
                )
                .await;
                let after = resource(
                    &f.client,
                    CORE_CODE_ADDRESS,
                    "config_buffer::PendingConfigs",
                    version,
                )
                .await;
                assert_ne!(
                    before, after,
                    "Expected the valid buffered update to write a pending value"
                );
            },
            Governance::InstallRandomness => assert_eq!(
                resource(
                    &f.client,
                    CORE_CODE_ADDRESS,
                    "randomness_api_v0_config::RequiredGasDeposit",
                    version
                )
                .await["gas_amount"],
                json!({"vec": ["123"]})
            ),
            Governance::RewardConfig => {
                let before = resource(
                    &f.client,
                    CORE_CODE_ADDRESS,
                    "staking_config::StakingRewardsConfig",
                    version - 1,
                )
                .await;
                let after = resource(
                    &f.client,
                    CORE_CODE_ADDRESS,
                    "staking_config::StakingRewardsConfig",
                    version,
                )
                .await;
                assert_ne!(before, after);
                let numerator = if before_freeze { 500u128 } else { 400u128 };
                let expected_raw = (numerator << 64) / 10_000;
                assert_eq!(
                    after["rewards_rate"]["value"],
                    json!(expected_raw.to_string())
                );
                assert_eq!(after["min_rewards_rate"]["value"], json!("0"));
                assert_eq!(after["rewards_rate_period_in_secs"], json!("31536000"));
                assert_eq!(after["rewards_rate_decrease_rate"]["value"], json!("0"));
            },
            Governance::RewardRateFeature => {
                let installed_before = resource(
                    &f.client,
                    CORE_CODE_ADDRESS,
                    "features::Features",
                    version - 1,
                )
                .await;
                let installed_after =
                    resource(&f.client, CORE_CODE_ADDRESS, "features::Features", version).await;
                assert_eq!(installed_before, installed_after);
                let pending = resource(
                    &f.client,
                    CORE_CODE_ADDRESS,
                    "features::PendingFeatures",
                    version,
                )
                .await;
                assert_ne!(pending, installed_after);

                // 冻结前将待生效向量恢复为当前已安装向量，避免改变本测试的奖励率来源；
                // 解冻后的调用则保留待生效变更，证明公开入口按原生缓冲语义恢复。
                if before_freeze {
                    let restored = execute(
                        &f.client,
                        &f.root,
                        &f.factory,
                        governance_payload(
                            Governance::RewardRateFeature,
                            true,
                            CORE_CODE_ADDRESS,
                            1,
                            epoch + 1,
                        ),
                    )
                    .await;
                    assert!(restored.info.success, "{}", restored.info.vm_status);
                    assert_eq!(
                        resource(
                            &f.client,
                            CORE_CODE_ADDRESS,
                            "features::PendingFeatures",
                            restored.info.version.0,
                        )
                        .await,
                        resource(
                            &f.client,
                            CORE_CODE_ADDRESS,
                            "features::Features",
                            restored.info.version.0,
                        )
                        .await
                    );
                }
            },
            Governance::Start | Governance::Finish => {
                panic!("Transition driver is not a matrix case")
            },
            Governance::EnablePool => panic!("Pool enable has a separate existence matrix"),
        },
        Call::NetworkAddresses | Call::ConsensusKey => {
            let event_type = if matches!(call, Call::NetworkAddresses) {
                "::stake::UpdateNetworkAndFullnodeAddresses"
            } else {
                "::stake::RotateConsensusKey"
            };
            assert_eq!(events(&transaction, event_type).len(), 1);
            let actual: ValidatorConfig = f
                .client
                .get_account_resource_at_version_bcs(
                    f.validator_operator.address(),
                    "0x1::stake::ValidatorConfig",
                    version,
                )
                .await
                .unwrap()
                .into_inner();
            // 同一阶段的两个入口会依次保留各自写入；从交易前状态派生期望，
            // 避免后一个入口把前一个入口已经成功更新的字段误判为回退。
            let mut expected: ValidatorConfig = f
                .client
                .get_account_resource_at_version_bcs(
                    f.validator_operator.address(),
                    "0x1::stake::ValidatorConfig",
                    version - 1,
                )
                .await
                .unwrap()
                .into_inner();
            if matches!(call, Call::NetworkAddresses) {
                expected.validator_network_addresses = f.matrix_validator_network_addresses.clone();
                expected.fullnode_network_addresses = f.matrix_fullnode_network_addresses.clone();
            } else {
                expected.consensus_public_key =
                    bls12381::PublicKey::try_from(f.matrix_consensus_public_key.as_slice())
                        .expect("矩阵公钥已经由 SDK 生成，必须可反序列化");
            }
            assert_eq!(actual, expected);

            // 冻结前恢复节点实际使用的创世配置，保证真实 DKG 和下一 Epoch
            // 继续使用磁盘中的身份及地址；恢复阶段保留新值，证明解冻后入口可用。
            if before_freeze {
                let restored = execute(
                    &f.client,
                    &f.validator_operator,
                    &f.factory,
                    f.original_validator_payload(call),
                )
                .await;
                assert!(restored.info.success, "{}", restored.info.vm_status);
                assert_eq!(events(&restored, event_type).len(), 1);
                let restored_config: ValidatorConfig = f
                    .client
                    .get_account_resource_at_version_bcs(
                        f.validator_operator.address(),
                        "0x1::stake::ValidatorConfig",
                        restored.info.version.0,
                    )
                    .await
                    .unwrap()
                    .into_inner();
                assert_eq!(restored_config, f.validator_config);
            }
        },
    }
}

async fn allocation_owner_isolation(f: &Fixture, epoch: u64) {
    let transaction = execute(
        &f.client,
        &f.attacker,
        &f.factory,
        f.payload(Call::Allocation, false, false, epoch),
    )
    .await;
    assert!(transaction.info.success, "{}", transaction.info.vm_status);
    let version = transaction.info.version.0;
    let observed = events(&transaction, "::poc_accounting::AllocationScheduled");
    assert_eq!(observed.len(), 1);
    assert_eq!(
        AccountAddress::from_hex_literal(observed[0].data["user"].as_str().unwrap()).unwrap(),
        f.attacker.address()
    );
    for name in [
        "poc_accounting::get_allocations",
        "poc_power_store::get_accounting_snapshot",
    ] {
        assert_eq!(
            view(
                &f.client,
                name,
                vec![json!(f.warm_user.address())],
                version - 1
            )
            .await,
            view(&f.client, name, vec![json!(f.warm_user.address())], version).await
        );
    }
    assert_eq!(
        view(
            &f.client,
            "poc_accounting::get_position",
            vec![json!(f.warm_user.address()), json!(f.pools[0])],
            version - 1
        )
        .await,
        view(
            &f.client,
            "poc_accounting::get_position",
            vec![json!(f.warm_user.address()), json!(f.pools[0])],
            version
        )
        .await
    );
}

/// 汇总当前委员会的成功和失败提案数，用于确认 DKG 等待期间旧委员会仍在出块。
async fn proposal_totals(f: &Fixture, version: u64) -> (u64, u64) {
    let mut successes = 0u64;
    let mut failures = 0u64;
    for pool in &f.pools {
        let config: ValidatorConfig = f
            .client
            .get_account_resource_at_version_bcs(*pool, "0x1::stake::ValidatorConfig", version)
            .await
            .unwrap()
            .into_inner();
        let counts = view(
            &f.client,
            "stake::get_current_epoch_proposal_counts",
            vec![json!(config.validator_index.to_string())],
            version,
        )
        .await;
        successes += counts[0].as_str().unwrap().parse::<u64>().unwrap();
        failures += counts[1].as_str().unwrap().parse::<u64>().unwrap();
    }
    (successes, failures)
}

async fn register_unenabled_pool(f: &Fixture) -> LocalAccount {
    let owner = f
        .swarm
        .chain_info()
        .into_aptos_public_info()
        .create_and_fund_user_account(1_000_000_000)
        .await
        .unwrap();
    // 不在委员会中的已注册池无需共识密钥；保持其质押和算力均为零，
    // 避免改变冻结的委员会目标。
    let registered = execute(
        &f.client,
        &owner,
        &f.factory,
        aptos_stdlib::stake_initialize_stake_owner(0, owner.address(), owner.address()),
    )
    .await;
    assert!(registered.info.success, "{}", registered.info.vm_status);
    for name in ["stake::StakePool", "stake::ValidatorConfig"] {
        resource(&f.client, owner.address(), name, registered.info.version.0).await;
    }
    assert!(pool_ledger(f, owner.address(), registered.info.version.0)
        .await
        .is_none());
    owner
}

async fn pool_ledger(f: &Fixture, pool: AccountAddress, version: u64) -> Option<Value> {
    let accounting = resource(
        &f.client,
        CORE_CODE_ADDRESS,
        "poc_accounting::AccountingState",
        version,
    )
    .await;
    let handle =
        AccountAddress::from_hex_literal(accounting["pools"]["handle"].as_str().unwrap()).unwrap();
    match f
        .client
        .get_table_item_at_version(
            handle,
            "address",
            "0x1::poc_accounting::PoolLedger",
            pool.to_hex_literal(),
            version,
        )
        .await
    {
        Ok(response) => Some(response.into_inner()),
        Err(RestError::Api(error))
            if error.status_code == reqwest::StatusCode::NOT_FOUND
                && error.error.error_code == AptosErrorCode::TableItemNotFound =>
        {
            None
        },
        Err(error) => panic!("Cannot read pool {pool} at version {version}: {error}"),
    }
}

/// 新注册地址在整个冻结期间均满足启用请求的业务条件。
/// 已启用地址另作重复请求拒绝用例：
/// enable_pool 的语义不保证重复调用幂等成功。
async fn enable_pool_case(
    f: &Fixture,
    pool: AccountAddress,
    frozen: bool,
    already_enabled: bool,
    unauthorized: bool,
) {
    println!("FRZ path={} pool={pool} frozen={frozen} already_enabled={already_enabled} unauthorized={unauthorized}", Call::Govern(Governance::EnablePool).path());
    let transaction = execute(
        &f.client,
        if unauthorized { &f.attacker } else { &f.root },
        &f.factory,
        governance_payload(Governance::EnablePool, !unauthorized, pool, 0, 0),
    )
    .await;
    let version = transaction.info.version.0;
    let before = pool_ledger(f, pool, version - 1).await;
    let after = pool_ledger(f, pool, version).await;
    assert_eq!(before.is_some(), already_enabled);
    for name in ["stake::StakePool", "stake::ValidatorConfig"] {
        assert_eq!(
            resource(&f.client, pool, name, version - 1).await,
            resource(&f.client, pool, name, version).await
        );
    }
    let error = if unauthorized {
        Some(("system_addresses", 0x50003))
    } else if frozen {
        Some(("poc_accounting", 0x3000B))
    } else if already_enabled {
        Some(("poc_accounting", 0x80005))
    } else {
        None
    };
    if let Some((module, code)) = error {
        assert_abort(&f.client, &transaction, module, code, &f.users(), &f.pools).await;
        assert_eq!(
            before, after,
            "Pool existence or ledger changed after abort"
        );
        assert_eq!(
            protected_state(f, version - 1).await,
            protected_state(f, version).await
        );
        assert!(events(&transaction, "::poc_accounting::PoCPoolEnabled").is_empty());
    } else {
        assert!(transaction.info.success, "{}", transaction.info.vm_status);
        let enabled = events(&transaction, "::poc_accounting::PoCPoolEnabled");
        assert_eq!(enabled.len(), 1);
        assert_eq!(event_pool(enabled[0]), pool);
        let ledger = after.expect("Successful enable must create its zero ledger");
        for field in ["units", "reward_base_octa", "index"] {
            assert_eq!(ledger[field], json!("0"));
        }
        assert_eq!(ledger["changes"], json!([]));
        assert_eq!(ledger["vault"]["value"], json!("0"));
        assert_eq!(
            view(
                &f.client,
                "poc_accounting::get_pool",
                vec![json!(pool)],
                version
            )
            .await,
            vec![json!("0"); 5]
        );
    }
}

#[tokio::test]
async fn poc_frozen_public_entries_preserve_plan_and_resume_after_finish() {
    let f = fixture().await;
    let initial = f
        .client
        .get_ledger_information()
        .await
        .unwrap()
        .into_inner();
    let closing_epoch = epoch_at(&f.client, initial.version).await;
    let installed = resource_at_version::<ValidatorSet>(&f.client, initial.version).await;
    let enabled_pool = register_unenabled_pool(&f).await;
    let frozen_pool = register_unenabled_pool(&f).await;
    enable_pool_case(&f, enabled_pool.address(), false, false, false).await;
    enable_pool_case(&f, frozen_pool.address(), false, false, true).await;
    for unauthorized in [false, true] {
        enable_pool_case(&f, enabled_pool.address(), false, true, unauthorized).await;
    }
    for call in CASES {
        succeed(&f, call, true, closing_epoch).await;
        if call.unauthorized_error().is_some() {
            reject(&f, call, true, false, closing_epoch).await;
        }
    }
    allocation_owner_isolation(&f, closing_epoch).await;

    // 保留真实可取消的待生效变更。冻结换届提交 E+1 后，E+2 仍是未来目标；
    // 待生效缓冲值与当前安装值不同，
    // 因此若绕过冻结检查，状态变化可被观测。
    for (action, value) in [
        (Governance::SchedulePower, 990),
        (Governance::ScheduleSplit, 6000),
        (Governance::BufferRandomness, 456),
    ] {
        let transaction = execute(
            &f.client,
            &f.root,
            &f.factory,
            governance_payload(
                action,
                true,
                f.next_uploader.address(),
                value,
                closing_epoch + 2,
            ),
        )
        .await;
        assert!(transaction.info.success, "{}", transaction.info.vm_status);
    }
    let before_freeze = f
        .client
        .get_ledger_information()
        .await
        .unwrap()
        .into_inner();
    assert_eq!(
        epoch_at(&f.client, before_freeze.version).await,
        closing_epoch
    );
    assert_eq!(
        view(
            &f.client,
            "poc_power_store::is_user_normalized",
            vec![json!(f.cold_user.address())],
            before_freeze.version
        )
        .await,
        vec![json!(false)]
    );
    for node in f.swarm.validators() {
        node.rest_client()
            .set_failpoint(DKG_FAILPOINT.to_owned(), "pause".to_owned())
            .await
            .expect("Freeze tests require a node binary built with failpoints");
    }
    let started = execute(
        &f.client,
        &f.root,
        &f.factory,
        governance_payload(
            Governance::Start,
            true,
            CORE_CODE_ADDRESS,
            0,
            closing_epoch + 1,
        ),
    )
    .await;
    assert!(started.info.success, "{}", started.info.vm_status);
    let frozen_version = started.info.version.0;
    let session = resource_at_version::<DKGState>(&f.client, frozen_version)
        .await
        .in_progress
        .expect("Governance must start a real paused DKG");
    assert_eq!(session.metadata.dealer_epoch, closing_epoch);
    let (cached, fallback): (ValidatorSet, bool) = f
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
    assert_eq!(cached, installed);
    assert_targets(&session.metadata.target_validator_set, &cached);
    let frozen = frozen_context_at(&f.client, frozen_version).await;
    let proposal_counts_at_freeze = proposal_totals(&f, frozen_version).await;

    // DKG 等待只冻结委员会相关配置；普通转账仍可执行、收取 gas 并产生费用事件。
    let transfer = execute(
        &f.client,
        &f.attacker,
        &f.factory,
        aptos_stdlib::topo_coin_transfer(f.warm_user.address(), 1),
    )
    .await;
    assert!(transfer.info.success, "{}", transfer.info.vm_status);
    assert!(transfer.info.gas_used.0 > 0);
    assert_eq!(
        events(&transfer, "::transaction_fee::FeeStatement").len(),
        1
    );
    assert_eq!(
        epoch_at(&f.client, transfer.info.version.0).await,
        closing_epoch
    );
    assert_eq!(
        frozen_context_at(&f.client, transfer.info.version.0).await,
        frozen
    );

    for unauthorized in [false, true] {
        enable_pool_case(&f, frozen_pool.address(), true, false, unauthorized).await;
        enable_pool_case(&f, enabled_pool.address(), true, true, unauthorized).await;
    }
    for call in CASES {
        reject(&f, call, false, true, closing_epoch).await;
        // 分配用例中的第二个签名者也是合法分配所有人；
        // 该账户同样受冻结约束，不能绕过检查。
        reject(&f, call, true, true, closing_epoch).await;
    }
    let waiting = f
        .client
        .get_ledger_information()
        .await
        .unwrap()
        .into_inner();
    assert!(
        waiting.version > frozen_version,
        "Old committee must continue committing during DKG wait"
    );
    assert_eq!(epoch_at(&f.client, waiting.version).await, closing_epoch);
    assert_eq!(frozen_context_at(&f.client, waiting.version).await, frozen);
    let proposal_counts_waiting = proposal_totals(&f, waiting.version).await;
    assert!(
        proposal_counts_waiting.0 + proposal_counts_waiting.1
            > proposal_counts_at_freeze.0 + proposal_counts_at_freeze.1,
        "DKG 等待期间旧委员会的提案统计必须继续增长"
    );
    assert_eq!(
        resource_at_version::<DKGState>(&f.client, waiting.version)
            .await
            .in_progress,
        Some(session.clone())
    );

    let finished = execute(
        &f.client,
        &f.root,
        &f.factory,
        governance_payload(
            Governance::Finish,
            true,
            CORE_CODE_ADDRESS,
            0,
            closing_epoch + 1,
        ),
    )
    .await;
    assert!(finished.info.success, "{}", finished.info.vm_status);
    assert_eq!(events(&finished, "::stake::PoCEpochInstalled").len(), 1);
    assert_eq!(
        events(&finished, "::reconfiguration::NewEpochEvent").len(),
        1
    );
    let credited = events(&finished, "::stake::PoCRewardCredited");
    assert_eq!(credited.len(), f.pools.len());
    for event in credited {
        assert_eq!(
            event.data["closing_epoch"],
            json!(closing_epoch.to_string())
        );
    }
    let finish_version = finished.info.version.0;
    assert_eq!(
        resource_at_version::<ValidatorSet>(&f.client, finish_version).await,
        cached
    );
    assert!(resource_at_version::<DKGState>(&f.client, finish_version)
        .await
        .in_progress
        .is_none());
    for name in ["stake::EpochPlan", "stake::PrecomputedValidatorSet"] {
        assert!(optional_resource_at_version(
            &f.client,
            CORE_CODE_ADDRESS,
            &format!("0x1::{name}"),
            finish_version
        )
        .await
        .is_none());
    }
    for node in f.swarm.validators() {
        node.rest_client()
            .set_failpoint(DKG_FAILPOINT.to_owned(), "off".to_owned())
            .await
            .unwrap();
    }
    let restored_epoch = closing_epoch + 1;
    assert_installed(
        &f,
        finish_version,
        restored_epoch,
        &cached,
        0,
        Some((6000, closing_epoch + 2)),
    )
    .await;
    enable_pool_case(&f, frozen_pool.address(), false, false, false).await;
    for pool in [enabled_pool.address(), frozen_pool.address()] {
        for unauthorized in [false, true] {
            enable_pool_case(&f, pool, false, true, unauthorized).await;
        }
    }

    // 原先合法的 E+1 请求现已过期，单独验证其准确拒绝原因；
    // 恢复调用则重新计算 current_epoch+1，使用合法目标。
    for (action, value, module, code) in [
        (Governance::SchedulePower, 990, "poc_accounting", 0x10006),
        (Governance::ScheduleSplit, 6000, "poc_reward_split", 0x10002),
    ] {
        let stale = execute(
            &f.client,
            &f.root,
            &f.factory,
            governance_payload(
                action,
                true,
                f.next_uploader.address(),
                value,
                restored_epoch,
            ),
        )
        .await;
        assert_abort(&f.client, &stale, module, code, &f.users(), &f.pools).await;
        assert_eq!(
            protected_state(&f, stale.info.version.0 - 1).await,
            protected_state(&f, stale.info.version.0).await
        );
    }
    for call in CASES {
        succeed(&f, call, false, restored_epoch).await;
        if call.unauthorized_error().is_some() {
            reject(&f, call, true, false, restored_epoch).await;
        }
    }
    allocation_owner_isolation(&f, restored_epoch).await;
    let final_ledger = f
        .client
        .get_ledger_information()
        .await
        .unwrap()
        .into_inner();
    assert_eq!(
        epoch_at(&f.client, final_ledger.version).await,
        restored_epoch
    );
    assert_installed(&f, final_ledger.version, restored_epoch, &cached, 0, None).await;
}

static REWARD_RATE_SCRIPT: Lazy<Vec<u8>> = Lazy::new(|| {
    compile_script(
        "PoCFreezeClaimRewardSetup",
        r#"
script {
    use std::features;
    use topo_std::fixed_point64;
    use topo_framework::staking_config;
    use topo_framework::topo_governance;

    fun main(root: &signer) {
        let framework = topo_governance::get_signer_testnet_only(root, @0x1);
        // A 部署允许 rate_max=1/1。安装足够大的固定奖励率，
        // 使 10 Octa 的小计奖基数也能产生可观测的整数领取额。
        if (features::periodical_reward_rate_decrease_enabled()) {
            staking_config::update_rewards_config(&framework,
                fixed_point64::create_from_rational(1, 1),
                fixed_point64::create_from_rational(1, 1),
                31536000, fixed_point64::create_from_rational(0, 1));
        } else {
            staking_config::update_rewards_rate(&framework, 1, 1);
        };
        topo_governance::force_end_epoch(&framework);
    }
}
"#,
    )
});

fn decimal(value: &Value) -> u64 {
    value.as_str().unwrap().parse().unwrap()
}

fn event_pool(event: &aptos_api_types::Event) -> AccountAddress {
    AccountAddress::from_hex_literal(event.data["pool"].as_str().unwrap()).unwrap()
}

/// 使用提交交易紧邻的前一版本独立计算通胀，
/// 纳入待结束 Epoch 的全部区块表现，并采用已安装奖励率；
/// 不使用预览结果生成金额预期。
async fn expected_inflation(f: &Fixture, pool: AccountAddress, version: u64) -> u64 {
    let config: ValidatorConfig = f
        .client
        .get_account_resource_at_version_bcs(pool, "0x1::stake::ValidatorConfig", version)
        .await
        .unwrap()
        .into_inner();
    let counts = view(
        &f.client,
        "stake::get_current_epoch_proposal_counts",
        vec![json!(config.validator_index.to_string())],
        version,
    )
    .await;
    let success = decimal(&counts[0]) as u128;
    let failed = decimal(&counts[1]) as u128;
    let context = resource(
        &f.client,
        CORE_CODE_ADDRESS,
        "stake::InstalledRewardContext",
        version,
    )
    .await;
    let numerator = decimal(&context["context"]["rewards_rate"]) as u128;
    let denominator = decimal(&context["context"]["rewards_rate_denominator"]) as u128;
    assert!(numerator > 0);
    assert_eq!(
        numerator, denominator,
        "The high reward rate was not installed"
    );
    assert_eq!(context["context"]["fee_limit_per_pool"], json!("0"));
    assert_eq!(
        decimal(&context["context"]["epoch"]),
        epoch_at(&f.client, version).await
    );
    if success + failed == 0 {
        0
    } else {
        u64::try_from(10 * success * numerator / ((success + failed) * denominator)).unwrap()
    }
}

async fn native_stakes(f: &Fixture, version: u64) -> Vec<Value> {
    let mut states = vec![];
    for pool in &f.pools {
        states.push(resource(&f.client, *pool, "stake::StakePool", version).await);
    }
    states
}

/// 参考值从 fixture 明确设置的零指数基线开始；
/// 每个 Epoch 增加 floor(PoC*Q/units)，原生通胀不计入该指数。
async fn assert_settlement(
    f: &Fixture,
    transaction: &UserTransaction,
    pool: AccountAddress,
    native_bps: u64,
    vault_before: u64,
    index_before: U256,
) -> (u64, u64, U256) {
    let version = transaction.info.version.0;
    let closing_epoch = epoch_at(&f.client, version - 1).await;
    let split = resource(
        &f.client,
        CORE_CODE_ADDRESS,
        "poc_reward_split::RewardSplitConfig",
        version - 1,
    )
    .await;
    let installed_bps = decimal(&split["installed_native_reward_bps"]);
    assert_eq!(installed_bps, native_bps);
    assert_eq!(decimal(&split["installed_epoch"]), closing_epoch);
    let total = expected_inflation(f, pool, version - 1).await;
    let native = u64::try_from((total as u128) * (installed_bps as u128) / 10_000).unwrap();
    let poc = total - native;
    let units = U256::from(10 * UNIT_SCALE);
    let q = U256::ONE << U256::from(128u64);
    let delta_index =
        U256::checked_div(U256::checked_mul(U256::from(poc), q).unwrap(), units).unwrap();
    let index_after = U256::checked_add(index_before, delta_index).unwrap();

    let credits = events(transaction, "::stake::PoCRewardCredited")
        .into_iter()
        .filter(|event| event_pool(event) == pool)
        .collect::<Vec<_>>();
    assert_eq!(credits.len(), 1);
    let credit = &credits[0].data;
    assert_eq!(decimal(&credit["closing_epoch"]), closing_epoch);
    assert_eq!(decimal(&credit["reward_base_octa"]), 10);
    assert_eq!(decimal(&credit["inflation"]), poc);
    assert_eq!(decimal(&credit["fee"]), 0);
    assert_eq!(credit["delta_index"], json!(delta_index.to_string()));
    let splits = events(transaction, "::stake::PoCRewardSplit")
        .into_iter()
        .filter(|event| event_pool(event) == pool)
        .collect::<Vec<_>>();
    assert_eq!(splits.len(), 1);
    let split_event = &splits[0].data;
    for (field, expected) in [
        ("closing_epoch", closing_epoch),
        ("native_reward_bps", installed_bps),
        ("total_inflation_octa", total),
        ("active_native_reward_octa", native),
        ("pending_inactive_native_reward_octa", 0),
        ("poc_inflation_octa", poc),
    ] {
        assert_eq!(decimal(&split_event[field]), expected, "{field}");
    }

    let native_before = resource(&f.client, pool, "stake::StakePool", version - 1).await;
    let native_after = resource(&f.client, pool, "stake::StakePool", version).await;
    let active_before = decimal(&native_before["active"]["value"]);
    let active_after = decimal(&native_after["active"]["value"]);
    assert_eq!(active_after, active_before + native);
    for field in ["inactive", "pending_active", "pending_inactive"] {
        assert_eq!(decimal(&native_before[field]["value"]), 0);
        assert_eq!(native_before[field], native_after[field]);
    }
    let native_events = events(transaction, "::stake::DistributeRewards")
        .into_iter()
        .filter(|event| {
            AccountAddress::from_hex_literal(event.data["pool_address"].as_str().unwrap()).unwrap()
                == pool
        })
        .collect::<Vec<_>>();
    if native == 0 {
        assert!(native_events.is_empty());
    } else {
        assert_eq!(native_events.len(), 1);
        assert_eq!(decimal(&native_events[0].data["rewards_amount"]), native);
    }
    assert!(events(transaction, "::stake::DistributeTransactionFee").is_empty());

    for (at, vault, index) in [
        (version - 1, vault_before, index_before),
        (version, vault_before + poc, index_after),
    ] {
        let ledger = view(&f.client, "poc_accounting::get_pool", vec![json!(pool)], at).await;
        assert_eq!(ledger, vec![
            json!((10 * UNIT_SCALE).to_string()),
            json!((10 * UNIT_SCALE).to_string()),
            json!("10"),
            json!(vault.to_string()),
            json!(index.to_string())
        ]);
    }
    assert_eq!(active_after - active_before + poc, total);
    println!("FRZ-04 settlement pool={pool} version={version} closing_epoch={closing_epoch} native_bps={installed_bps} inflation={total} native={native} poc={poc} delta_index={delta_index} vault_before={vault_before}");
    (poc, native, index_after)
}

/// FRZ-04：原生分流占比为零的组合单独执行并留证。
#[tokio::test]
async fn poc_nonzero_claim_during_frozen_dkg_preserves_cached_target() {
    nonzero_claim_during_frozen_dkg(0).await;
}

/// FRZ-04：默认原生占比 30%，在真实 DKG 冻结期间领取非零奖励，
/// 分别核对领取前后两路收益的归属。
#[tokio::test]
async fn poc_nonzero_mixed_claim_during_frozen_dkg_preserves_cached_target() {
    nonzero_claim_during_frozen_dkg(3000).await;
}

async fn nonzero_claim_during_frozen_dkg(native_bps: u64) {
    Lazy::force(&REWARD_RATE_SCRIPT);
    let f = fixture_with_split(native_bps).await;
    let configured = execute(
        &f.client,
        &f.root,
        &f.factory,
        TransactionPayload::Script(Script::new(REWARD_RATE_SCRIPT.clone(), vec![], vec![])),
    )
    .await;
    assert!(configured.info.success, "{}", configured.info.vm_status);
    let configured_version = configured.info.version.0;
    for pool in &f.pools {
        let ledger = view(
            &f.client,
            "poc_accounting::get_pool",
            vec![json!(pool)],
            configured_version,
        )
        .await;
        assert_eq!(ledger[0], json!((10 * UNIT_SCALE).to_string()));
        assert_eq!(ledger[2], json!("10"));
        assert_eq!(ledger[3], json!("0"));
        assert_eq!(
            ledger[4],
            json!("0"),
            "Reference model starts at a zero reward index"
        );
    }
    // 先产生真实提案，再结算首个使用新奖励率的 Epoch。
    for _ in 0..16 {
        let transfer = execute(
            &f.client,
            &f.warm_user,
            &f.factory,
            aptos_stdlib::topo_coin_transfer(f.cold_user.address(), 1),
        )
        .await;
        assert!(transfer.info.success, "{}", transfer.info.vm_status);
    }
    let history = execute(
        &f.client,
        &f.root,
        &f.factory,
        governance_payload(Governance::Finish, true, CORE_CODE_ADDRESS, 0, 0),
    )
    .await;
    assert!(history.info.success, "{}", history.info.vm_status);
    let history_version = history.info.version.0;
    let credits = events(&history, "::stake::PoCRewardCredited");
    assert_eq!(credits.len(), f.pools.len());
    assert_eq!(
        events(&history, "::stake::PoCRewardSplit").len(),
        f.pools.len()
    );
    let mut credited = BTreeMap::new();
    let mut native_total = 0;
    for pool in &f.pools {
        let (poc, native, index) =
            assert_settlement(&f, &history, *pool, native_bps, 0, U256::ZERO).await;
        native_total += native;
        credited.insert(*pool, (poc, index));
    }
    if native_bps > 0 {
        assert!(
            native_total > 0,
            "Mixed fixture must pay actual native rewards"
        );
    } else {
        assert_eq!(native_total, 0);
    }
    let (&claim_pool, &(amount, index)) =
        credited.iter().max_by_key(|(_, credit)| credit.0).unwrap();
    let units = U256::from(10 * UNIT_SCALE);
    let q = U256::ONE << U256::from(128u64);
    let accrued = U256::checked_mul(units, index).unwrap();
    let expected_claim = u64::try_from(U256::checked_div(accrued, q).unwrap()).unwrap();
    let expected_fraction = U256::checked_rem(accrued, q).unwrap();
    assert!(
        expected_claim > 0,
        "Real proposals must produce a nonzero historical claim"
    );
    assert_eq!(
        view(
            &f.client,
            "poc_accounting::get_position",
            vec![json!(claim_pool), json!(claim_pool)],
            history_version
        )
        .await,
        vec![
            json!((10 * UNIT_SCALE).to_string()),
            json!([]),
            json!(expected_claim.to_string()),
            json!(expected_fraction.to_string())
        ]
    );

    let node = f.swarm.validator(claim_pool).unwrap();
    let key = node.account_private_key().as_ref().unwrap().private_key();
    f.swarm
        .chain_info()
        .into_aptos_public_info()
        .mint(claim_pool, 1_000_000_000)
        .await
        .unwrap();
    let sequence = f
        .client
        .get_account(claim_pool)
        .await
        .unwrap()
        .into_inner()
        .sequence_number;
    let claimant = LocalAccount::new(claim_pool, key, sequence);
    let before_freeze = f
        .client
        .get_ledger_information()
        .await
        .unwrap()
        .into_inner();
    let closing_epoch = epoch_at(&f.client, before_freeze.version).await;
    for node in f.swarm.validators() {
        node.rest_client()
            .set_failpoint(DKG_FAILPOINT.to_owned(), "pause".to_owned())
            .await
            .unwrap();
    }
    let started = execute(
        &f.client,
        &f.root,
        &f.factory,
        governance_payload(
            Governance::Start,
            true,
            CORE_CODE_ADDRESS,
            0,
            closing_epoch + 1,
        ),
    )
    .await;
    assert!(started.info.success, "{}", started.info.vm_status);
    let frozen_version = started.info.version.0;
    let session = resource_at_version::<DKGState>(&f.client, frozen_version)
        .await
        .in_progress
        .unwrap();
    assert_eq!(session.metadata.dealer_epoch, closing_epoch);
    let (cached, fallback): (ValidatorSet, bool) = f
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
    assert_targets(&session.metadata.target_validator_set, &cached);
    let frozen = frozen_context_at(&f.client, frozen_version).await;
    let stakes = native_stakes(&f, frozen_version).await;
    let allocation_before = view(
        &f.client,
        "poc_accounting::get_allocations",
        vec![json!(claim_pool)],
        frozen_version,
    )
    .await;
    let position_before = view(
        &f.client,
        "poc_accounting::get_position",
        vec![json!(claim_pool), json!(claim_pool)],
        frozen_version,
    )
    .await;
    assert_eq!(position_before[2], json!(expected_claim.to_string()));
    assert_eq!(
        view(
            &f.client,
            "poc_accounting::get_position",
            vec![json!(claim_pool), json!(claim_pool)],
            frozen_version
        )
        .await,
        position_before
    );

    for expected in [expected_claim, 0] {
        let claim = execute(
            &f.client,
            &claimant,
            &f.factory,
            aptos_stdlib::poc_allocation_claim_rewards(vec![claim_pool]),
        )
        .await;
        assert!(claim.info.success, "{}", claim.info.vm_status);
        let version = claim.info.version.0;
        let claims = events(&claim, "::poc_accounting::PoCRewardClaimed");
        if expected > 0 {
            assert_eq!(claims.len(), 1);
            assert_eq!(decimal(&claims[0].data["amount"]), expected);
            for field in ["user", "pool"] {
                assert_eq!(
                    AccountAddress::from_hex_literal(claims[0].data[field].as_str().unwrap())
                        .unwrap(),
                    claim_pool
                );
            }
        } else {
            assert!(claims.is_empty());
        }
        let fee = events(&claim, "::transaction_fee::FeeStatement");
        assert_eq!(fee.len(), 1);
        let refund = decimal(&fee[0].data["storage_fee_refund_octas"]);
        let gas = claim.info.gas_used.0 * claim.request.gas_unit_price.0;
        let balance_before = f
            .client
            .view_apt_account_balance_at_version(claim_pool, version - 1)
            .await
            .unwrap()
            .into_inner();
        let balance_after = f
            .client
            .view_apt_account_balance_at_version(claim_pool, version)
            .await
            .unwrap()
            .into_inner();
        assert_eq!(
            balance_after as i128 - balance_before as i128,
            expected as i128 - gas as i128 + refund as i128
        );
        assert_eq!(frozen_context_at(&f.client, version).await, frozen);
        assert_eq!(native_stakes(&f, version).await, stakes);
        assert_eq!(
            resource_at_version::<DKGState>(&f.client, version)
                .await
                .in_progress,
            Some(session.clone())
        );
        assert_eq!(
            view(
                &f.client,
                "poc_accounting::get_allocations",
                vec![json!(claim_pool)],
                version
            )
            .await,
            allocation_before
        );
        assert_eq!(
            view(
                &f.client,
                "poc_accounting::get_position",
                vec![json!(claim_pool), json!(claim_pool)],
                version
            )
            .await,
            vec![
                json!((10 * UNIT_SCALE).to_string()),
                json!([]),
                json!("0"),
                json!(expected_fraction.to_string())
            ]
        );
        let pool = view(
            &f.client,
            "poc_accounting::get_pool",
            vec![json!(claim_pool)],
            version,
        )
        .await;
        assert_eq!(pool[3], json!((amount - expected_claim).to_string()));
        assert_eq!(pool[4], json!(index.to_string()));
        println!("FRZ-04 native_bps={native_bps} pool={claim_pool} version={version} poc_credited={amount} expected_claim={expected} gas={gas} refund={refund} remaining_fraction={expected_fraction}");
    }
    let finished = execute(
        &f.client,
        &f.root,
        &f.factory,
        governance_payload(
            Governance::Finish,
            true,
            CORE_CODE_ADDRESS,
            0,
            closing_epoch + 1,
        ),
    )
    .await;
    assert!(finished.info.success, "{}", finished.info.vm_status);
    let version = finished.info.version.0;
    assert_eq!(events(&finished, "::stake::PoCEpochInstalled").len(), 1);
    let rewards = events(&finished, "::stake::PoCRewardCredited");
    assert_eq!(rewards.len(), f.pools.len());
    assert_eq!(
        events(&finished, "::stake::PoCRewardSplit").len(),
        f.pools.len()
    );
    assert_eq!(epoch_at(&f.client, version - 1).await, closing_epoch);
    for pool in &f.pools {
        let (first_poc, index_before) = credited[pool];
        let paid = if *pool == claim_pool {
            expected_claim
        } else {
            0
        };
        assert_settlement(
            &f,
            &finished,
            *pool,
            native_bps,
            first_poc - paid,
            index_before,
        )
        .await;
    }
    assert_eq!(
        resource_at_version::<ValidatorSet>(&f.client, version).await,
        cached
    );
    for name in ["stake::EpochPlan", "stake::PrecomputedValidatorSet"] {
        assert!(optional_resource_at_version(
            &f.client,
            CORE_CODE_ADDRESS,
            &format!("0x1::{name}"),
            version
        )
        .await
        .is_none());
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
    assert_installed(&f, version, closing_epoch + 1, &cached, native_bps, None).await;
}
