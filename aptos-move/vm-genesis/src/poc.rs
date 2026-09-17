// Copyright (c) Aptos Foundation
// Licensed pursuant to the Innovation-Enabling Source Code License, available at https://github.com/aptos-labs/aptos-core/blob/main/LICENSE

//! 使用主网、测试网默认参数或自定义清单构建 PoC 创世；普通创世构建器继续使用原生质押模式。
//! 数值上界、保证金资格与委员会约束由生产 Move 代码实际执行校验。

use crate::{encode_genesis_change_set_internal, exec_function, GenesisConfiguration, Validator};
use aptos_crypto::ed25519::Ed25519PublicKey;
use aptos_release_bundle::ReleaseBundle;
use aptos_types::{
    account_config::CORE_CODE_ADDRESS,
    chain_id::ChainId,
    on_chain_config::{GasScheduleV2, OnChainConsensusConfig, OnChainExecutionConfig},
    transaction::{Transaction, WriteSetPayload},
};
use aptos_vm::move_vm_ext::{AptosMoveResolver, SessionExt};
use aptos_vm_types::module_and_script_storage::module_storage::AptosModuleStorage;
use move_core_types::value::{serialize_values, MoveValue};
use move_vm_runtime::module_traversal::TraversalContext;
use serde::{Deserialize, Serialize};

/// PoC 权重参数；字段顺序必须与 `poc_accounting::PowerParams` 的 BCS 布局一致。
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct PowerParams {
    /// 每 1 OHMP 算力所需的保证金 Octa 数，必须为正；1 OHMP = 100,000,000 power。
    pub bond_octa_per_ohmp: u64,
    /// 最终整数共识权重的准入门槛。
    pub min_power: u64,
    /// 单池最终整数共识权重上限，还须满足协议对总权重的保守上界要求。
    pub max_power: u64,
    /// 最终委员会最低人数；动态换员时必须小于候选容量。
    pub min_validators: u64,
}

/// 部署固定上限；字段顺序必须与 `poc_accounting::DeploymentLimits` 的 BCS 布局一致。
/// 奖励基数和费用均使用 Octa；调用者须提供全部参数，并验证其容量上限。
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DeploymentLimits {
    /// 单个用户当前及待生效配置涉及的池并集上限。
    pub max_allocations: u64,
    /// 单次领取可指定的池数上限。
    pub max_claim_pools: u64,
    /// 原始算力单批上传人数上限。
    pub max_upload_users: u64,
    /// 经成本验收确定的候选数量上限 V_LIMIT；总权重上界仍按 MAX_VALIDATOR_SET_SIZE 计算。
    pub validator_limit: u64,
    /// 单池计奖基数上限 B_MAX，单位为 Octa。
    pub max_reward_base_octa: u64,
    /// 允许的最大奖励率分子，与 rate_max_den 配对使用。
    pub rate_max_num: u64,
    /// 允许的最大奖励率分母，必须为正。
    pub rate_max_den: u64,
    /// 每池每 Epoch 可分发交易费上限。
    pub fee_max: u64,
    /// 自首次 PoC Epoch 起支持的奖励期数 H，不因调参重置。
    pub reward_epoch_limit: u64,
}

/// 部署信任模式；传入 Move 时分别编码为 0 和 1。
#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
pub enum DeploymentMode {
    /// 受控准入，部署方承担白名单对应的信任假设。
    Controlled,
    /// 开放部署，最终委员会中每个池的权重都必须严格小于总权重的三分之一。
    Open,
}

/// PoC 创世清单：创建 owner 直接持有的零佣金质押池，并安装 PoC Epoch 1。
/// 验证者身份与保证金来自单独传入的 `Validator` 记录；每个 owner 获得相同初始算力并全额分配到本池。
/// 算力周期、上传者和费用限额使用 Move 默认值：60 个 Epoch、0x1、0，上线后可通过治理调整。
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct PocGenesisConfiguration {
    pub params: PowerParams,
    pub limits: DeploymentLimits,
    pub deployment_mode: DeploymentMode,
    /// 每个算力周期的保留比例，单位 bps；准备标准化基线时固定。
    pub retention_bps: u64,
    /// 以创世基线为 0 的最大相对算力周期 P_MAX，须逐周期校验整数指数。
    pub max_relative_period: u64,
    /// 每个创世验证者在周期 0 获得的原始算力，必须为正；自动写入 PowerStore 并 100% 分配到本池。
    /// 独立于代币保证金数量，最终权重仍受保证金及 params.max_power 限制。
    pub initial_raw_power: u64,
    /// PoC 通胀与可分发交易费共用的原生奖励占比，以基点（bps）表示，范围为 0..=10_000。
    /// 新创世配置省略此项时，默认 3000 bps：原生质押获得 30%，PoC 奖励金库获得 70%。
    /// 两类收入分别分流并向下取整原生份额，余额各归 PoC 奖励金库。
    #[serde(default = "default_native_reward_bps")]
    pub native_reward_bps: u64,
}

fn default_native_reward_bps() -> u64 {
    3_000
}

impl PocGenesisConfiguration {
    /// 主网 PoC 默认值，与现有 TOPO 质押门槛、2 小时 Epoch 和 10% APY 配合使用。
    /// 每个验证者获配 100 万 OHMP，保证金比例为 1 TOPO/OHMP；仍须满足原有 TOPO 质押资格。
    /// 开放委员会至少 5 人，支持现有 Layout 的 20% 增长上限和动态换员，不修改原生配置。
    pub fn mainnet() -> Self {
        const POWER_PER_OHMP: u64 = 100_000_000;
        const OCTA_PER_TOPO: u64 = crate::APTOS_COINS_BASE_WITH_DECIMALS;
        Self {
            params: PowerParams {
                bond_octa_per_ohmp: OCTA_PER_TOPO,
                min_power: POWER_PER_OHMP,
                // 65536 * max_power < u64::MAX，不能直接沿用更大的原生 max_stake。
                max_power: 2_000_000 * POWER_PER_OHMP,
                min_validators: 5,
            },
            limits: DeploymentLimits {
                max_allocations: 4,
                max_claim_pools: 4,
                max_upload_users: 32,
                validator_limit: 128,
                max_reward_base_octa: 2_000_000 * OCTA_PER_TOPO,
                // 每 Epoch 1% 的奖励率上限，兼容当前 2 小时 Epoch / 10% APY。
                rate_max_num: 1,
                rate_max_den: 100,
                // 仅为治理可设置的上限；Move 创世的实际费用分发限额仍为零。
                fee_max: 1_000 * OCTA_PER_TOPO,
                // 覆盖周期 0..=10000，每周期 60 Epoch；H * R_MAX < u64::MAX。
                reward_epoch_limit: 600_060,
            },
            deployment_mode: DeploymentMode::Open,
            retention_bps: 9_995,
            max_relative_period: 10_000,
            initial_raw_power: 1_000_000 * POWER_PER_OHMP,
            native_reward_bps: default_native_reward_bps(),
        }
    }

    /// 受控测试网 PoC 默认值，适配现有测试创世每个验证者 1 TOPO 的初始质押。
    /// 初始算力为 1 OHMP，最低权重为 1 power，避免首次衰减后跌破 1 OHMP 的门槛。
    /// 最低 2 人，动态换员要求原生增长上限为 50%；两个等权节点须同时在线，不具备单节点容错能力。
    /// 沿用主网的 1 TOPO/OHMP 比例、容量及衰减参数；原生 TOPO 质押资格仍须满足。
    pub fn testnet() -> Self {
        const POWER_PER_OHMP: u64 = 100_000_000;
        let mut config = Self::mainnet();
        config.params.min_power = 1;
        config.params.max_power = 1_000 * POWER_PER_OHMP;
        config.params.min_validators = 2;
        config.limits.max_reward_base_octa = 1_000 * crate::APTOS_COINS_BASE_WITH_DECIMALS;
        config.deployment_mode = DeploymentMode::Controlled;
        config.initial_raw_power = POWER_PER_OHMP;
        config
    }
}

impl Default for PocGenesisConfiguration {
    fn default() -> Self {
        Self::mainnet()
    }
}

/// 按完整 PoC 清单离线编码创世交易，其余初始化步骤与普通创世共用。
/// framework 须包含匹配的 PoC 入口与 BCS 类型；Move 校验失败会终止生成。
pub fn encode_genesis_transaction(
    core_resources_key: &Ed25519PublicKey,
    validators: &[Validator],
    framework: &ReleaseBundle,
    chain_id: ChainId,
    genesis_config: &GenesisConfiguration,
    consensus_config: &OnChainConsensusConfig,
    execution_config: &OnChainExecutionConfig,
    gas_schedule: &GasScheduleV2,
    poc_config: &PocGenesisConfiguration,
) -> Transaction {
    Transaction::GenesisTransaction(WriteSetPayload::Direct(encode_genesis_change_set_internal(
        core_resources_key,
        validators,
        framework,
        chain_id,
        genesis_config,
        consensus_config,
        execution_config,
        gas_schedule,
        Some(poc_config),
    )))
}

/// 按 Move 创世入口的参数顺序编码验证者和配置。
/// Move 为实际验证者创建 owner 池、写入统一初始算力并全额分配，权限和数值范围由该入口复核。
pub(crate) fn create_and_initialize_validators(
    session: &mut SessionExt<impl AptosMoveResolver>,
    module_storage: &impl AptosModuleStorage,
    traversal_context: &mut TraversalContext,
    validators: &[Validator],
    config: &PocGenesisConfiguration,
) {
    let mut arguments = serialize_values(&[MoveValue::Signer(CORE_CODE_ADDRESS)]);
    arguments.extend([
        encode(&validators),
        encode(&config.params),
        encode(&config.limits),
    ]);
    arguments.extend(serialize_values(&[
        MoveValue::U8(match config.deployment_mode {
            DeploymentMode::Controlled => 0,
            DeploymentMode::Open => 1,
        }),
        MoveValue::U64(config.retention_bps),
        MoveValue::U64(config.max_relative_period),
        MoveValue::U64(config.initial_raw_power),
        MoveValue::U64(config.native_reward_bps),
    ]));
    exec_function(
        session,
        module_storage,
        traversal_context,
        "genesis",
        "create_initialize_poc_validators_with_reward_split",
        vec![],
        arguments,
    );
}

fn encode(value: &impl Serialize) -> Vec<u8> {
    bcs::to_bytes(value).expect("PoC genesis manifest values are serializable")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        default_gas_schedule, mainnet_genesis_config, test_genesis_config, TestValidator,
        GENESIS_KEYPAIR,
    };
    use aptos_crypto::HashValue;
    use aptos_types::{
        on_chain_config::{ConfigurationResource, ValidatorSet},
        state_store::{
            errors::StateViewError, state_key::StateKey, state_storage_usage::StateStorageUsage,
            state_value::StateValue, TStateView,
        },
        transaction::ChangeSet,
        write_set::{TransactionWrite, WriteSet},
    };
    use aptos_vm::{data_cache::AsMoveResolver, move_vm_ext::GenesisRuntimeBuilder};
    use aptos_vm_types::module_and_script_storage::AsAptosCodeStorage;
    use move_core_types::{
        account_address::AccountAddress, identifier::Identifier, language_storage::ModuleId,
    };
    use move_vm_runtime::module_traversal::TraversalStorage;
    use move_vm_types::gas::UnmeteredGasMeter;
    use serde::de::{
        value::{Error as ManifestError, MapDeserializer},
        Deserializer, IntoDeserializer, Visitor,
    };

    /// 只为测试构造与 JSON/YAML 等价的树状清单，避免绕过 `Deserialize`
    /// 直接修改 Rust 结构体，从而同时验证缺省字段和显式零值。
    enum ManifestValue {
        U64(u64),
        Text(&'static str),
        Map(Vec<(&'static str, ManifestValue)>),
    }

    impl<'de> IntoDeserializer<'de, ManifestError> for ManifestValue {
        type Deserializer = Self;

        fn into_deserializer(self) -> Self::Deserializer {
            self
        }
    }

    impl<'de> Deserializer<'de> for ManifestValue {
        type Error = ManifestError;

        serde::forward_to_deserialize_any! {
            bool i8 i16 i32 i64 i128 u8 u16 u32 u64 u128 f32 f64 char str string
            bytes byte_buf option unit unit_struct newtype_struct seq tuple tuple_struct map
            struct identifier ignored_any
        }

        fn deserialize_any<V>(self, visitor: V) -> Result<V::Value, Self::Error>
        where
            V: Visitor<'de>,
        {
            match self {
                Self::U64(value) => visitor.visit_u64(value),
                Self::Text(value) => visitor.visit_borrowed_str(value),
                Self::Map(fields) => visitor.visit_map(MapDeserializer::new(fields.into_iter())),
            }
        }

        fn deserialize_enum<V>(
            self,
            _name: &'static str,
            _variants: &'static [&'static str],
            visitor: V,
        ) -> Result<V::Value, Self::Error>
        where
            V: Visitor<'de>,
        {
            match self {
                Self::Text(value) => visitor.visit_enum(value.into_deserializer()),
                other => other.deserialize_any(visitor),
            }
        }
    }

    fn liquid_balance_at_genesis(genesis: &ChangeSet, address: AccountAddress) -> u64 {
        let view = InstalledGenesis(genesis.write_set());
        let output = aptos_vm::AptosVM::execute_view_function(
            &view,
            ModuleId::new(CORE_CODE_ADDRESS, Identifier::new("coin").unwrap()),
            Identifier::new("balance").unwrap(),
            vec![move_core_types::parser::parse_type_tag("0x1::topo_coin::TopoCoin").unwrap()],
            vec![encode(&address)],
            2_000_000,
        );
        let values = output
            .values
            .expect("The production balance view must succeed");
        bcs::from_bytes(&values[0]).unwrap()
    }

    /// 可复现的验收清单；这些数值不构成生产部署默认值。
    fn manifest() -> PocGenesisConfiguration {
        PocGenesisConfiguration {
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
            native_reward_bps: default_native_reward_bps(),
        }
    }

    /// 经由 `PocGenesisConfiguration::deserialize` 读取完整清单；`None` 表示
    /// 清单确实省略 `native_reward_bps`，由字段默认值补成 3000。
    fn deserialize_manifest(native_reward_bps: Option<u64>) -> PocGenesisConfiguration {
        let mut fields = vec![
            (
                "params",
                ManifestValue::Map(vec![
                    ("bond_octa_per_ohmp", ManifestValue::U64(100_000_000)),
                    ("min_power", ManifestValue::U64(10)),
                    ("max_power", ManifestValue::U64(1000)),
                    ("min_validators", ManifestValue::U64(4)),
                ]),
            ),
            (
                "limits",
                ManifestValue::Map(vec![
                    ("max_allocations", ManifestValue::U64(4)),
                    ("max_claim_pools", ManifestValue::U64(4)),
                    ("max_upload_users", ManifestValue::U64(4)),
                    ("validator_limit", ManifestValue::U64(5)),
                    ("max_reward_base_octa", ManifestValue::U64(1000)),
                    ("rate_max_num", ManifestValue::U64(1)),
                    ("rate_max_den", ManifestValue::U64(1)),
                    ("fee_max", ManifestValue::U64(10)),
                    ("reward_epoch_limit", ManifestValue::U64(1000)),
                ]),
            ),
            ("deployment_mode", ManifestValue::Text("Open")),
            ("retention_bps", ManifestValue::U64(10_000)),
            ("max_relative_period", ManifestValue::U64(100)),
            ("initial_raw_power", ManifestValue::U64(17)),
        ];
        if let Some(value) = native_reward_bps {
            fields.push(("native_reward_bps", ManifestValue::U64(value)));
        }
        PocGenesisConfiguration::deserialize(ManifestValue::Map(fields))
            .expect("PoC 验收清单必须能反序列化")
    }

    /// 使用指定的原生参数执行真实 PoC 创世入口，返回可重新加载的测试写集。
    fn encode_test_genesis(
        config: &PocGenesisConfiguration,
        validators: &[Validator],
    ) -> ChangeSet {
        encode_test_genesis_with_native_config(config, validators, 25)
    }

    /// 保留生产创世的完整执行路径，仅覆盖原生动态增长上限，
    /// 用于联合验证 PoC 模式、最低人数和候选容量。
    fn encode_test_genesis_with_native_config(
        config: &PocGenesisConfiguration,
        validators: &[Validator],
        voting_power_increase_limit: u64,
    ) -> ChangeSet {
        let mut native_config = mainnet_genesis_config();
        native_config.is_test = true;
        native_config.min_stake = 1;
        native_config.max_stake = 1000;
        native_config.min_voting_threshold = 0;
        native_config.required_proposer_stake = 0;
        native_config.epoch_duration_secs = 3600;
        native_config.recurring_lockup_duration_secs = 7200;
        native_config.voting_duration_secs = 3600;
        native_config.voting_power_increase_limit = voting_power_increase_limit;
        match encode_genesis_transaction(
            &GENESIS_KEYPAIR.1,
            validators,
            aptos_cached_packages::head_release_bundle(),
            ChainId::test(),
            &native_config,
            &OnChainConsensusConfig::default_for_genesis(),
            &OnChainExecutionConfig::default_for_genesis(),
            &default_gas_schedule(),
            config,
        ) {
            Transaction::GenesisTransaction(WriteSetPayload::Direct(change_set)) => change_set,
            _ => panic!("PoC builder must produce a direct genesis transaction"),
        }
    }

    /// 创世构建器将 Move 错误转成 panic；这里同时固定错误模块和完整编码，
    /// 防止只凭“发生错误”误收其他创世阶段的失败。
    fn assert_genesis_abort(
        config: &PocGenesisConfiguration,
        validators: &[Validator],
        voting_power_increase_limit: u64,
        module: &str,
        code: u64,
    ) {
        let error = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            encode_test_genesis_with_native_config(config, validators, voting_power_increase_limit)
        }))
        .expect_err("非法 PoC 创世参数必须被生产 Move 入口拒绝");
        let message = error
            .downcast_ref::<String>()
            .map(String::as_str)
            .or_else(|| error.downcast_ref::<&str>().copied())
            .expect("创世失败应提供稳定的文本状态");
        let module_location = format!("name: Identifier(\"{module}\")");
        assert!(
            message.contains(&module_location),
            "创世失败模块不匹配：期望 {module}，实际 {message}"
        );
        assert!(
            message.contains(&format!("({code:#x})")),
            "创世失败码不匹配：期望 {code:#x}，实际 {message}"
        );
    }

    /// 将创世写集作为只读状态视图，验证保存的数据可被新 VM 正确读取。
    struct InstalledGenesis<'a>(&'a WriteSet);

    impl TStateView for InstalledGenesis<'_> {
        type Key = StateKey;

        fn get_state_value(&self, key: &StateKey) -> Result<Option<StateValue>, StateViewError> {
            Ok(self
                .0
                .as_v0()
                .get(key)
                .and_then(|op| op.extract_raw_bytes().map(StateValue::new_legacy)))
        }

        fn get_usage(&self) -> Result<StateStorageUsage, StateViewError> {
            Ok(StateStorageUsage::zero())
        }
    }

    fn assert_installed_genesis(
        config: &PocGenesisConfiguration,
        validators: &[Validator],
        expected_powers: &[u64],
        expected_reward_bases_octa: &[u64],
    ) {
        let genesis = encode_test_genesis(config, validators);
        assert_installed_genesis_state(
            &genesis,
            config,
            validators,
            expected_powers,
            expected_reward_bases_octa,
        );
    }

    fn assert_installed_genesis_state(
        genesis: &ChangeSet,
        config: &PocGenesisConfiguration,
        validators: &[Validator],
        expected_powers: &[u64],
        expected_reward_bases_octa: &[u64],
    ) {
        let writes = genesis.write_set().as_v0();
        let validator_set: ValidatorSet = bcs::from_bytes(
            &writes
                .get(&StateKey::on_chain_config::<ValidatorSet>().unwrap())
                .unwrap()
                .extract_raw_bytes()
                .unwrap(),
        )
        .unwrap();
        assert_eq!(validator_set.active_validators.len(), validators.len());
        assert_eq!(
            validator_set.total_voting_power,
            expected_powers.iter().map(|p| u128::from(*p)).sum::<u128>()
        );
        assert_eq!(validator_set.total_joining_power, 0);
        assert_eq!(expected_powers.len(), validators.len());
        assert_eq!(expected_reward_bases_octa.len(), validators.len());
        for (validator, power) in validators.iter().zip(expected_powers) {
            let installed = validator_set
                .active_validators
                .iter()
                .find(|v| v.account_address() == &validator.owner_address)
                .unwrap();
            assert_eq!(installed.consensus_voting_power(), *power);
        }
        let configuration: ConfigurationResource = bcs::from_bytes(
            &writes
                .get(&StateKey::on_chain_config::<ConfigurationResource>().unwrap())
                .unwrap()
                .extract_raw_bytes()
                .unwrap(),
        )
        .unwrap();
        assert_eq!(configuration.epoch(), 1);
        assert_eq!(
            genesis
                .events()
                .iter()
                .filter(|e| e
                    .type_tag()
                    .to_canonical_string()
                    .ends_with("::stake::PoCEpochInstalled"))
                .count(),
            1
        );
        for suffix in [
            "::stake::PoCRewardCredited",
            "::stake::PoCRewardSplit",
            "::stake::DistributeRewards",
            "::stake::DistributeTransactionFee",
            "::poc_accounting::PoCRewardClaimed",
        ] {
            assert!(
                !genesis
                    .events()
                    .iter()
                    .any(|event| event.type_tag().to_canonical_string().ends_with(suffix)),
                "创世不得结算 Epoch 0 奖励：{suffix}"
            );
        }

        // 用新 VM 重新加载保存的数据，查询 Table 账本和算力周期时钟，并确认查询未写入状态。
        let view = InstalledGenesis(genesis.write_set());
        let chain_id: ChainId = bcs::from_bytes(
            &writes
                .get(&StateKey::on_chain_config::<ChainId>().unwrap())
                .unwrap()
                .extract_raw_bytes()
                .unwrap(),
        )
        .unwrap();
        let builder = GenesisRuntimeBuilder::new(chain_id);
        let environment = builder.build_genesis_runtime_environment();
        let module_storage = view.as_aptos_code_storage(&environment);
        let resolver = view.as_move_resolver();
        let vm = builder.build_genesis_vm();
        let mut session = vm.new_genesis_session(&resolver, HashValue::zero());
        let traversal_storage = TraversalStorage::new();
        let mut traversal = TraversalContext::new(&traversal_storage);
        let mut query = |module: &str, function: &str, arguments| {
            session
                .execute_function_bypass_visibility(
                    &ModuleId::new(CORE_CODE_ADDRESS, Identifier::new(module).unwrap()),
                    &Identifier::new(function).unwrap(),
                    vec![],
                    arguments,
                    &mut UnmeteredGasMeter,
                    &mut traversal,
                    &module_storage,
                )
                .unwrap()
                .return_values
                .into_iter()
                .map(|v| v.0)
                .collect::<Vec<_>>()
        };
        let epoch = query("poc_accounting", "current_epoch", vec![]);
        assert_eq!(bcs::from_bytes::<u64>(&epoch[0]).unwrap(), 1);
        let power_per_ohmp = query("poc_accounting", "power_per_ohmp", vec![]);
        assert_eq!(
            bcs::from_bytes::<u64>(&power_per_ohmp[0]).unwrap(),
            100_000_000
        );
        let context = query("stake", "get_installed_reward_context", vec![]);
        let (epoch, poc, _, _, _, fee_limit): (u64, bool, u64, u64, bool, u64) =
            bcs::from_bytes(&context[0]).unwrap();
        assert_eq!(epoch, 1);
        assert!(poc);
        assert_eq!(fee_limit, 0);
        let encoded_native_reward_bps = query("stake", "get_installed_native_reward_bps", vec![]);
        assert_eq!(
            bcs::from_bytes::<u64>(&encoded_native_reward_bps[0]).unwrap(),
            config.native_reward_bps
        );
        let reward_split = query("stake", "get_reward_split_configuration", vec![]);
        assert_eq!(reward_split.len(), 5);
        assert_eq!(bcs::from_bytes::<u64>(&reward_split[0]).unwrap(), 1);
        assert_eq!(
            bcs::from_bytes::<u64>(&reward_split[1]).unwrap(),
            config.native_reward_bps
        );
        assert_eq!(
            bcs::from_bytes::<u64>(&reward_split[2]).unwrap(),
            config.native_reward_bps
        );
        assert_eq!(
            bcs::from_bytes::<Option<u64>>(&reward_split[3]).unwrap(),
            None
        );
        assert_eq!(
            bcs::from_bytes::<Option<u64>>(&reward_split[4]).unwrap(),
            None
        );
        let period_length = query("poc_power_store", "get_power_period_in_epochs", vec![]);
        assert_eq!(bcs::from_bytes::<u64>(&period_length[0]).unwrap(), 60);
        let period = query("poc_power_store", "get_current_period", vec![]);
        assert_eq!(bcs::from_bytes::<u64>(&period[0]).unwrap(), 0);
        let operator = query("poc_power_store", "get_operator", vec![]);
        assert_eq!(
            bcs::from_bytes::<AccountAddress>(&operator[0]).unwrap(),
            CORE_CODE_ADDRESS
        );
        let boundary = query("poc_power_store", "next_boundary_epoch", vec![]);
        assert_eq!(bcs::from_bytes::<u64>(&boundary[0]).unwrap(), 61);
        for (validator, reward_base_octa) in validators.iter().zip(expected_reward_bases_octa) {
            let pool = &validator.owner_address;
            let stake_operator = query("stake", "get_operator", vec![encode(pool)]);
            assert_eq!(
                bcs::from_bytes::<AccountAddress>(&stake_operator[0]).unwrap(),
                validator.operator_address
            );
            let delegated_voter = query("stake", "get_delegated_voter", vec![encode(pool)]);
            assert_eq!(
                bcs::from_bytes::<AccountAddress>(&delegated_voter[0]).unwrap(),
                validator.voter_address
            );
            // PoC 创世建立 owner 直持池，不创建带运营佣金的 staking contract；
            // 因而即使多个 owner 共用运营者，也不存在非零 PoC 运营佣金路径。
            let contract_exists = query("staking_contract", "staking_contract_exists", vec![
                encode(pool),
                encode(&validator.operator_address),
            ]);
            assert!(!bcs::from_bytes::<bool>(&contract_exists[0]).unwrap());
            let stake = query("stake", "get_stake", vec![encode(pool)]);
            assert_eq!(
                bcs::from_bytes::<u64>(&stake[0]).unwrap(),
                validator.stake_amount
            );
            for balance in &stake[1..] {
                assert_eq!(bcs::from_bytes::<u64>(balance).unwrap(), 0);
            }
            let expected_units = u128::from(config.initial_raw_power) << 32;
            let raw_power = query("poc_power_store", "get_user_committed_power", vec![encode(
                pool,
            )]);
            assert_eq!(
                bcs::from_bytes::<u64>(&raw_power[0]).unwrap(),
                config.initial_raw_power
            );
            let allocations = query("poc_accounting", "get_allocations", vec![encode(pool)]);
            assert_eq!(
                bcs::from_bytes::<Vec<(AccountAddress, u64)>>(&allocations[0]).unwrap(),
                vec![(*pool, 10000)]
            );
            let position = query("poc_accounting", "get_position", vec![
                encode(pool),
                encode(pool),
            ]);
            assert_eq!(
                bcs::from_bytes::<u128>(&position[0]).unwrap(),
                expected_units
            );
            let values = query("poc_accounting", "get_pool", vec![encode(pool)]);
            assert_eq!(bcs::from_bytes::<u128>(&values[0]).unwrap(), expected_units);
            assert_eq!(
                bcs::from_bytes::<u64>(&values[2]).unwrap(),
                *reward_base_octa
            );
            assert_eq!(bcs::from_bytes::<u64>(&values[3]).unwrap(), 0);
            let encoded_reward_base_octa =
                query("poc_accounting", "pool_reward_base_octa", vec![encode(
                    pool,
                )]);
            assert_eq!(
                bcs::from_bytes::<u64>(&encoded_reward_base_octa[0]).unwrap(),
                *reward_base_octa
            );
        }
        let changes = session
            .finish(&vm.genesis_change_set_configs(), &module_storage)
            .unwrap();
        assert!(
            changes.resource_write_set().is_empty(),
            "PoC views must not write state"
        );
        let mint_cap = StateKey::resource(
            &CORE_CODE_ADDRESS,
            &move_core_types::parser::parse_struct_tag("0x1::topo_coin::MintCapStore").unwrap(),
        )
        .unwrap();
        assert!(view.get_state_value(&mint_cap).unwrap().is_none());
    }

    #[test]
    fn poc_mainnet_defaults_initialize_without_changing_topo_config() {
        // 使用原主网配置，包括 is_test=false、原生质押门槛、锁仓、奖励率及默认功能开关。
        let native_config = mainnet_genesis_config();
        let config = PocGenesisConfiguration::default();
        let validators = TestValidator::new_test_set(None, Some(native_config.min_stake))
            .into_iter()
            .map(|v| v.data)
            .collect::<Vec<_>>();
        assert_defaults_preserve_topo_config(
            &config,
            &native_config,
            ChainId::mainnet(),
            &validators,
            100_000_000_000_000,
        );
    }

    #[test]
    fn poc_testnet_defaults_initialize_without_changing_topo_config() {
        // 原生参数与 generate_test_genesis 共用，保留 1 小时 Epoch、10% APY 和每池 1 TOPO。
        let native_config = test_genesis_config();
        let config = PocGenesisConfiguration::testnet();
        for count in [Some(2), Some(5), None] {
            let validators = TestValidator::new_test_set(count, Some(100_000_000))
                .into_iter()
                .map(|v| v.data)
                .collect::<Vec<_>>();
            assert_defaults_preserve_topo_config(
                &config,
                &native_config,
                ChainId::testnet(),
                &validators,
                100_000_000,
            );
        }
    }

    #[test]
    #[should_panic(expected = "0x30006")]
    fn poc_testnet_defaults_reject_single_validator() {
        let validators = TestValidator::new_test_set(Some(1), Some(100_000_000))
            .into_iter()
            .map(|v| v.data)
            .collect::<Vec<_>>();
        encode_genesis_transaction(
            &GENESIS_KEYPAIR.1,
            &validators,
            aptos_cached_packages::head_release_bundle(),
            ChainId::testnet(),
            &test_genesis_config(),
            &OnChainConsensusConfig::default_for_genesis(),
            &OnChainExecutionConfig::default_for_genesis(),
            &default_gas_schedule(),
            &PocGenesisConfiguration::testnet(),
        );
    }

    fn assert_defaults_preserve_topo_config(
        config: &PocGenesisConfiguration,
        native_config: &GenesisConfiguration,
        chain_id: ChainId,
        validators: &[Validator],
        expected_power: u64,
    ) {
        let framework = aptos_cached_packages::head_release_bundle();
        let consensus = OnChainConsensusConfig::default_for_genesis();
        let execution = OnChainExecutionConfig::default_for_genesis();
        let gas = default_gas_schedule();
        let transaction = encode_genesis_transaction(
            &GENESIS_KEYPAIR.1,
            validators,
            framework,
            chain_id,
            native_config,
            &consensus,
            &execution,
            &gas,
            config,
        );
        let Transaction::GenesisTransaction(WriteSetPayload::Direct(genesis)) = transaction else {
            panic!("PoC builder must produce a direct genesis transaction");
        };
        let expected_powers = vec![expected_power; validators.len()];
        assert_installed_genesis_state(
            &genesis,
            config,
            validators,
            &expected_powers,
            &expected_powers,
        );
        if !native_config.is_test {
            // 主网沿用只铸造并质押 stake_amount 的创世行为，不额外预留流动余额。
            for validator in validators {
                assert_eq!(
                    liquid_balance_at_genesis(&genesis, validator.owner_address),
                    0
                );
            }
        }

        // 与同一份原生配置产生的链上资源逐字节比较，确保未通过改 TOPO 参数绕过 PoC 校验。
        let native = crate::encode_genesis_change_set(
            &GENESIS_KEYPAIR.1,
            validators,
            framework,
            chain_id,
            native_config,
            &consensus,
            &execution,
            &gas,
        );
        for resource in [
            "0x1::staking_config::StakingConfig",
            "0x1::staking_config::StakingRewardsConfig",
            "0x1::topo_governance::GovernanceConfig",
            "0x1::block::BlockResource",
        ] {
            let tag = move_core_types::parser::parse_struct_tag(resource).unwrap();
            let key = StateKey::resource(&CORE_CODE_ADDRESS, &tag).unwrap();
            assert_eq!(
                genesis
                    .write_set()
                    .as_v0()
                    .get(&key)
                    .unwrap()
                    .extract_raw_bytes()
                    .unwrap(),
                native
                    .write_set()
                    .as_v0()
                    .get(&key)
                    .unwrap()
                    .extract_raw_bytes()
                    .unwrap(),
                "TOPO configuration changed: {resource}",
            );
        }
    }

    #[test]
    fn poc_genesis_builder_executes_and_reloads_production_bundle() {
        let validators = TestValidator::new_test_set(Some(4), Some(100))
            .into_iter()
            // 共用运营者与投票者，确认初始算力和全额分配仍分别归属各 owner。
            .map(|v| Validator {
                operator_address: AccountAddress::from_hex_literal("0xb0b").unwrap(),
                voter_address: AccountAddress::from_hex_literal("0xcafe").unwrap(),
                ..v.data
            })
            .collect::<Vec<_>>();
        assert!(validators
            .windows(2)
            .all(|pair| pair[0].owner_address != pair[1].owner_address));
        assert!(validators.iter().all(|validator| {
            validator.operator_address == AccountAddress::from_hex_literal("0xb0b").unwrap()
                && validator.voter_address == AccountAddress::from_hex_literal("0xcafe").unwrap()
        }));

        // 四组均从清单值反序列化后进入生产创世；省略字段和显式 3000
        // 最终值相同，但必须分别经过 serde 默认路径和显式字段路径。
        for (encoded, expected) in [
            (None, 3_000),
            (Some(0), 0),
            (Some(3_000), 3_000),
            (Some(6_750), 6_750),
        ] {
            let config = deserialize_manifest(encoded);
            assert_eq!(config.native_reward_bps, expected);
            assert_installed_genesis(&config, &validators, &[17, 17, 17, 17], &[17, 17, 17, 17]);
        }
    }

    #[test]
    fn poc_genesis_builder_preserves_full_allocation_when_bonds_cap_power() {
        let validators = TestValidator::new_test_set(Some(4), Some(30))
            .into_iter()
            .enumerate()
            .map(|(i, v)| Validator {
                stake_amount: if i == 0 { 20 } else { 30 },
                ..v.data
            })
            .collect::<Vec<_>>();
        let mut config = manifest();
        config.initial_raw_power = 100;
        assert_installed_genesis(&config, &validators, &[20, 30, 30, 30], &[20, 30, 30, 30]);
    }

    #[test]
    fn poc_genesis_builder_rounds_bond_caps_and_reward_bases_in_octa_per_ohmp() {
        let validators = TestValidator::new_test_set(Some(4), Some(100))
            .into_iter()
            .zip([42, 43, 100, 100])
            .map(|(v, stake_amount)| Validator {
                stake_amount,
                ..v.data
            })
            .collect::<Vec<_>>();
        let mut config = manifest();
        config.initial_raw_power = 17;
        config.params.bond_octa_per_ohmp = 250_000_000;
        config.limits.max_reward_base_octa = 2500;
        // 2.5 TOPO/OHMP：42 Octa 只支持 16 power，43 Octa 支持 17 power；
        // 17 power 的计奖基数是 42 Octa。保证金限幅不减少已分配的原始算力。
        assert_installed_genesis(&config, &validators, &[16, 17, 17, 17], &[40, 42, 42, 42]);
    }

    #[test]
    fn poc_genesis_builder_rejects_zero_initial_raw_power() {
        let validators = TestValidator::new_test_set(Some(4), Some(100))
            .into_iter()
            .map(|v| v.data)
            .collect::<Vec<_>>();
        let mut config = manifest();
        config.initial_raw_power = 0;
        assert_genesis_abort(&config, &validators, 25, "genesis", 0x10003);
    }

    #[test]
    fn poc_genesis_builder_rejects_concentrated_open_committee() {
        let validators = TestValidator::new_test_set(Some(4), Some(100))
            .into_iter()
            .enumerate()
            .map(|(i, v)| Validator {
                stake_amount: if i == 0 { 100 } else { 10 },
                ..v.data
            })
            .collect::<Vec<_>>();
        let mut config = manifest();
        config.initial_raw_power = 100;
        // 目标集中度校验使首次重配置延期；创世不能把 Deferred 当作可用的部分写集。
        assert_genesis_abort(&config, &validators, 25, "reconfiguration", 0x30006);
    }

    #[test]
    fn poc_genesis_builder_validates_mode_growth_capacity_and_reward_split_matrix() {
        let two_validators = TestValidator::new_test_set(Some(2), Some(100))
            .into_iter()
            .map(|validator| validator.data)
            .collect::<Vec<_>>();
        let four_validators = TestValidator::new_test_set(Some(4), Some(100))
            .into_iter()
            .map(|validator| validator.data)
            .collect::<Vec<_>>();

        // Open 模式即使只有两个等权池，也必须满足至少四人的协议约束。
        let mut open_two = manifest();
        open_two.params.min_validators = 2;
        assert_genesis_abort(&open_two, &two_validators, 50, "poc_accounting", 0x10007);

        // Controlled 两人动态委员会在 20% 增长上限下无法补足一个最低权重成员。
        let mut controlled_two = manifest();
        controlled_two.deployment_mode = DeploymentMode::Controlled;
        controlled_two.params.min_validators = 2;
        assert_genesis_abort(
            &controlled_two,
            &two_validators,
            20,
            "poc_accounting",
            0x10007,
        );

        // 动态换员还必须在最低人数之外至少保留一个候选名额。
        let mut no_replacement_slot = manifest();
        no_replacement_slot.deployment_mode = DeploymentMode::Controlled;
        no_replacement_slot.limits.validator_limit = no_replacement_slot.params.min_validators;
        assert_genesis_abort(
            &no_replacement_slot,
            &four_validators,
            25,
            "poc_accounting",
            0x10007,
        );

        // 奖励分流边界由独立模块校验，不能被前面的合法 PoC 参数掩盖。
        let mut invalid_split = manifest();
        invalid_split.native_reward_bps = 10_001;
        assert_genesis_abort(
            &invalid_split,
            &four_validators,
            25,
            "poc_reward_split",
            0x10001,
        );

        // 50% 增长预算恰好允许两人 Controlled 委员会替换一名最低权重成员；
        // 原生占比的两个闭区间端点都必须写入并从新 VM 正确读回。
        for native_reward_bps in [0, 10_000] {
            let mut valid = controlled_two.clone();
            valid.native_reward_bps = native_reward_bps;
            let genesis = encode_test_genesis_with_native_config(&valid, &two_validators, 50);
            assert_installed_genesis_state(&genesis, &valid, &two_validators, &[10, 10], &[10, 10]);
        }
    }
}
