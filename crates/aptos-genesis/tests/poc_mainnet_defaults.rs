// Copyright (c) Aptos Foundation
// Licensed pursuant to the Innovation-Enabling Source Code License, available at https://github.com/aptos-labs/aptos-core/blob/main/LICENSE

use aptos_genesis::{config::Layout, poc};
use aptos_types::{
    access_path::AccessPath,
    account_config::CORE_CODE_ADDRESS,
    on_chain_config::{ConfigurationResource, ValidatorSet},
    state_store::state_key::StateKey,
    transaction::{ChangeSet, Transaction, WriteSetPayload},
    write_set::TransactionWrite,
};
use aptos_vm_genesis::{
    default_gas_schedule, encode_genesis_change_set, GenesisConfiguration, TestValidator,
    GENESIS_KEYPAIR,
};

fn genesis_pair_from_current_layout(
    validator_count: usize,
    stake_amount: u64,
) -> (ChangeSet, ChangeSet) {
    let layout = Layout::default();
    // 与 MainnetGenesisInfo 一致，主网开启动态换员并使用正式代币初始化；其余 TOPO 参数原样取自 Layout。
    let native = GenesisConfiguration {
        allow_new_validators: true,
        is_test: false,
        epoch_duration_secs: layout.epoch_duration_secs,
        min_stake: layout.min_stake,
        min_voting_threshold: layout.min_voting_threshold,
        max_stake: layout.max_stake,
        recurring_lockup_duration_secs: layout.recurring_lockup_duration_secs,
        required_proposer_stake: layout.required_proposer_stake,
        rewards_apy_percentage: layout.rewards_apy_percentage,
        voting_duration_secs: layout.voting_duration_secs,
        voting_power_increase_limit: layout.voting_power_increase_limit,
        employee_vesting_start: layout.employee_vesting_start.unwrap(),
        employee_vesting_period_duration: layout.employee_vesting_period_duration.unwrap(),
        initial_features_override: layout.initial_features_override,
        randomness_config_override: layout.randomness_config_override,
        chunky_dkg_config_override: layout.chunky_dkg_config_override,
        jwk_consensus_config_override: layout.jwk_consensus_config_override,
        initial_jwks: layout.initial_jwks,
        keyless_groth16_vk: layout.keyless_groth16_vk_override,
        initialize_decryption_at_genesis: true,
    };
    let validators = TestValidator::new_test_set(Some(validator_count), Some(stake_amount))
        .into_iter()
        .map(|v| v.data)
        .collect::<Vec<_>>();
    let framework = aptos_cached_packages::head_release_bundle();
    let gas = default_gas_schedule();
    let poc_genesis = match poc::encode_genesis_transaction(
        &GENESIS_KEYPAIR.1,
        &validators,
        framework,
        layout.chain_id,
        &native,
        &layout.on_chain_consensus_config,
        &layout.on_chain_execution_config,
        &gas,
        &poc::PocGenesisConfiguration::mainnet(),
    ) {
        Transaction::GenesisTransaction(WriteSetPayload::Direct(genesis)) => genesis,
        _ => panic!("PoC builder must produce a direct genesis transaction"),
    };
    let native_genesis = encode_genesis_change_set(
        &GENESIS_KEYPAIR.1,
        &validators,
        framework,
        layout.chain_id,
        &native,
        &layout.on_chain_consensus_config,
        &layout.on_chain_execution_config,
        &gas,
    );
    (poc_genesis, native_genesis)
}

fn genesis_from_current_layout(validator_count: usize, stake_amount: u64) -> ChangeSet {
    genesis_pair_from_current_layout(validator_count, stake_amount).0
}

fn resource_bytes(genesis: &ChangeSet, name: &str) -> Vec<u8> {
    genesis
        .write_set()
        .as_v0()
        .iter()
        .find_map(|(key, write)| {
            let encoded = key.encoded();
            let access_path = bcs::from_bytes::<AccessPath>(encoded.get(1..)?).ok()?;
            let tag = access_path.get_struct_tag()?;
            (access_path.address == CORE_CODE_ADDRESS && tag.to_canonical_string() == name)
                .then(|| write.extract_raw_bytes().map(|bytes| bytes.to_vec()))
                .flatten()
        })
        .unwrap_or_else(|| panic!("创世写集缺少资源 {name}"))
}

#[test]
fn poc_mainnet_defaults_support_current_layout_and_validator_capacity() {
    let layout = Layout::default();
    // 验证最低人数/最低保证金与部署容量/最高保证金，均不调整 Layout 中的 TOPO 配置。
    for (count, stake_amount) in [(5, layout.min_stake), (128, layout.max_stake)] {
        let (genesis, native_genesis) = genesis_pair_from_current_layout(count, stake_amount);
        let writes = genesis.write_set().as_v0();
        let validators: ValidatorSet = bcs::from_bytes(
            &writes
                .get(&StateKey::on_chain_config::<ValidatorSet>().unwrap())
                .unwrap()
                .extract_raw_bytes()
                .unwrap(),
        )
        .unwrap();
        assert_eq!(validators.active_validators.len(), count);
        assert_eq!(
            validators.total_voting_power,
            count as u128 * 100_000_000_000_000
        );
        assert!(validators
            .active_validators
            .iter()
            .all(|v| v.consensus_voting_power() == 100_000_000_000_000));
        let configuration: ConfigurationResource = bcs::from_bytes(
            &writes
                .get(&StateKey::on_chain_config::<ConfigurationResource>().unwrap())
                .unwrap()
                .extract_raw_bytes()
                .unwrap(),
        )
        .unwrap();
        assert_eq!(configuration.epoch(), 1);

        // 逐字节比较同一 Layout 的四类原生配置，证明 PoC 创世没有改写经济参数。
        for resource in [
            "0x1::staking_config::StakingConfig",
            "0x1::staking_config::StakingRewardsConfig",
            "0x1::topo_governance::GovernanceConfig",
            "0x1::block::BlockResource",
        ] {
            assert_eq!(
                resource_bytes(&genesis, resource),
                resource_bytes(&native_genesis, resource),
                "PoC 创世改写了原生配置 {resource}",
            );
        }

        // Move Option 在 BCS 中按 vector 编码；创世安装 Epoch 1/3000，且没有待生效项。
        let split_bytes = resource_bytes(&genesis, "0x1::poc_reward_split::RewardSplitConfig");
        let split: (u64, u64, u64, Vec<(u64, u64)>) = bcs::from_bytes(&split_bytes).unwrap();
        assert_eq!(split, (1, 3_000, 3_000, vec![]));
    }
}

#[test]
fn poc_mainnet_defaults_reject_too_few_validators() {
    let error =
        std::panic::catch_unwind(|| genesis_from_current_layout(4, Layout::default().min_stake))
            .expect_err("四人主网 PoC 创世必须拒绝");
    let message = error
        .downcast_ref::<String>()
        .map(String::as_str)
        .or_else(|| error.downcast_ref::<&str>().copied())
        .expect("创世失败应提供稳定的文本状态");
    assert!(
        message.contains("name: Identifier(\"reconfiguration\")"),
        "创世失败模块不匹配：{message}"
    );
    assert!(message.contains("(0x30006)"), "创世失败码不匹配：{message}");
}

#[test]
fn poc_reward_split_manifest_defaults_and_explicit_zero() {
    // 新创世的 JSON/YAML 清单省略此字段时，原生奖励占比默认 3000 bps。
    // 显式设为 0 时，通胀奖励全部归 PoC。
    let manifest = include_str!("../../../docs/draft/POC_GENESIS_TEST_MANIFEST.json");
    let mut manifest_value: serde_yaml::Value = serde_yaml::from_str(manifest).unwrap();
    let explicit_config: poc::PocGenesisConfiguration =
        serde_yaml::from_value(manifest_value.clone()).unwrap();
    assert_eq!(explicit_config.native_reward_bps, 3_000);
    manifest_value
        .as_mapping_mut()
        .unwrap()
        .remove(&serde_yaml::Value::String("native_reward_bps".into()));
    let defaulted_config: poc::PocGenesisConfiguration =
        serde_yaml::from_value(manifest_value.clone()).unwrap();
    assert_eq!(defaulted_config.native_reward_bps, 3_000);
    manifest_value["native_reward_bps"] = serde_yaml::Value::Number(0.into());
    let zero_native_reward_config: poc::PocGenesisConfiguration =
        serde_yaml::from_value(manifest_value).unwrap();
    assert_eq!(zero_native_reward_config.native_reward_bps, 0);
}
