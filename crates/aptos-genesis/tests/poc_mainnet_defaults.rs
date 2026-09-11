// Copyright (c) Aptos Foundation
// Licensed pursuant to the Innovation-Enabling Source Code License, available at https://github.com/aptos-labs/aptos-core/blob/main/LICENSE

use aptos_genesis::{config::Layout, poc};
use aptos_types::{
    on_chain_config::{ConfigurationResource, ValidatorSet},
    state_store::state_key::StateKey,
    transaction::{ChangeSet, Transaction, WriteSetPayload},
    write_set::TransactionWrite,
};
use aptos_vm_genesis::{
    default_gas_schedule, GenesisConfiguration, TestValidator, GENESIS_KEYPAIR,
};

fn genesis_from_current_layout(validator_count: usize, stake_amount: u64) -> ChangeSet {
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
    match poc::encode_genesis_transaction(
        &GENESIS_KEYPAIR.1,
        &validators,
        aptos_cached_packages::head_release_bundle(),
        layout.chain_id,
        &native,
        &layout.on_chain_consensus_config,
        &layout.on_chain_execution_config,
        &default_gas_schedule(),
        &poc::PocGenesisConfiguration::mainnet(),
    ) {
        Transaction::GenesisTransaction(WriteSetPayload::Direct(genesis)) => genesis,
        _ => panic!("PoC builder must produce a direct genesis transaction"),
    }
}

#[test]
fn poc_mainnet_defaults_support_current_layout_and_validator_capacity() {
    let layout = Layout::default();
    // 验证最低人数/最低保证金与部署容量/最高保证金，均不调整 Layout 中的 TOPO 配置。
    for (count, stake_amount) in [(5, layout.min_stake), (128, layout.max_stake)] {
        let genesis = genesis_from_current_layout(count, stake_amount);
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
    }
}

#[test]
#[should_panic(expected = "0x30006")]
fn poc_mainnet_defaults_reject_too_few_validators() {
    genesis_from_current_layout(4, Layout::default().min_stake);
}
