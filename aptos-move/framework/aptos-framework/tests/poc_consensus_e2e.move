#[test_only]
module aptos_framework::poc_consensus_e2e {
    use std::signer;

    use aptos_framework::poc_test_utils;
    use aptos_framework::stake;
    use aptos_framework::staking_registry;
    use aptos_framework::timestamp;

    const EVALIDATOR_SHOULD_BE_PENDING_ACTIVE: u64 = 1;
    const EVALIDATOR_SHOULD_BE_ACTIVE: u64 = 2;
    const EVALIDATOR_SHOULD_BE_PENDING_INACTIVE: u64 = 3;
    const EVALIDATOR_SHOULD_BE_INACTIVE: u64 = 4;
    const EVALIDATOR_MISSING_FROM_CURRENT_SET: u64 = 5;
    const EVALIDATOR_UNEXPECTED_IN_CURRENT_SET: u64 = 6;
    const EDELEGATOR_NOT_BOUND_TO_VALIDATOR: u64 = 7;
    const EDELEGATOR_SHOULD_BE_UNBOUND: u64 = 8;
    const EDEPOSIT_DID_NOT_GROW: u64 = 9;
    const ECOOLDOWN_SHOULD_BE_ACTIVE: u64 = 10;
    const ECOOLDOWN_SHOULD_BE_CLEARED: u64 = 11;
    const EREDELEGATION_DID_NOT_SUCCEED: u64 = 12;
    const ESET_SIZE_MISMATCH: u64 = 13;
    const EPOWER_SHOULD_BE_VISIBLE: u64 = 14;
    const EDEFAULT_OCTAS_PER_POWER: u64 = 15;
    const EUPDATED_OCTAS_PER_POWER: u64 = 16;

    // Validate the public validator lifecycle from creation to active membership.
    #[test(aptos_framework = @aptos_framework, validator = @0x100)]
    fun test_validator_join_lifecycle(
        aptos_framework: &signer,
        validator: &signer,
    ) {
        poc_test_utils::setup_poc_env(aptos_framework);
        poc_test_utils::create_validator(aptos_framework, validator, 100);

        let validator_address = signer::address_of(validator);
        poc_test_utils::assert_validator_state(
            validator_address,
            4,
            EVALIDATOR_SHOULD_BE_INACTIVE,
        );

        stake::join_validator_set(validator, validator_address);
        poc_test_utils::assert_validator_state(
            validator_address,
            1,
            EVALIDATOR_SHOULD_BE_PENDING_ACTIVE,
        );

        stake::end_epoch();

        poc_test_utils::assert_validator_state(
            validator_address,
            2,
            EVALIDATOR_SHOULD_BE_ACTIVE,
        );
        poc_test_utils::assert_current_set_contains(
            validator_address,
            EVALIDATOR_MISSING_FROM_CURRENT_SET,
        );
        assert!(
            staking_registry::get_validator_total_power(validator_address) == 100,
            EPOWER_SHOULD_BE_VISIBLE,
        );
    }

    // Validate that the registry starts with the genesis bootstrap exchange rate and that
    // the framework account can tune the deposit-to-power backing ratio after initialization.
    #[test(aptos_framework = @aptos_framework)]
    fun test_octas_per_power_is_mutable_by_framework(aptos_framework: &signer) {
        poc_test_utils::setup_poc_env(aptos_framework);
        assert!(
            staking_registry::get_octas_per_power() == 1,
            EDEFAULT_OCTAS_PER_POWER,
        );

        staking_registry::set_octas_per_power(aptos_framework, 100_000);
        assert!(
            staking_registry::get_octas_per_power() == 100_000,
            EUPDATED_OCTAS_PER_POWER,
        );
    }

    // The exchange rate must stay positive because effective power divides deposit by it.
    #[test(aptos_framework = @aptos_framework)]
    #[expected_failure(abort_code = 0x1000d, location = aptos_framework::staking_registry)]
    fun test_set_octas_per_power_rejects_zero(aptos_framework: &signer) {
        poc_test_utils::setup_poc_env(aptos_framework);
        staking_registry::set_octas_per_power(aptos_framework, 0);
    }

    // Validate the full delegator lifecycle against the production staking registry.
    #[test(
        aptos_framework = @aptos_framework,
        validator = @0x101,
        delegator = @0x201
    )]
    fun test_delegator_full_lifecycle_e2e(
        aptos_framework: &signer,
        validator: &signer,
        delegator: &signer,
    ) {
        poc_test_utils::setup_poc_env(aptos_framework);
        poc_test_utils::create_validator(aptos_framework, validator, 100);

        let validator_address = signer::address_of(validator);
        let delegator_address = signer::address_of(delegator);
        poc_test_utils::seed_genesis_power(aptos_framework, delegator_address, 120);
        stake::mint_and_add_stake(delegator, 120);
        staking_registry::delegate(delegator, validator_address);
        stake::join_validator_set(validator, validator_address);
        stake::end_epoch();

        poc_test_utils::assert_delegated_to(
            delegator_address,
            validator_address,
            EDELEGATOR_NOT_BOUND_TO_VALIDATOR,
        );
        poc_test_utils::assert_validator_state(
            validator_address,
            2,
            EVALIDATOR_SHOULD_BE_ACTIVE,
        );

        let (deposit_before_rewards, _, _) =
            staking_registry::get_user_stake_info(delegator_address);
        stake::end_epoch();
        let (deposit_after_rewards, delegated_to_after_rewards, cooldown_after_rewards) =
            staking_registry::get_user_stake_info(delegator_address);
        assert!(delegated_to_after_rewards == validator_address, EDELEGATOR_NOT_BOUND_TO_VALIDATOR);
        assert!(cooldown_after_rewards == 0, ECOOLDOWN_SHOULD_BE_CLEARED);
        assert!(deposit_after_rewards > deposit_before_rewards, EDEPOSIT_DID_NOT_GROW);

        staking_registry::undelegate(delegator);
        let (_, delegated_to_after_undelegate, cooldown_after_undelegate) =
            staking_registry::get_user_stake_info(delegator_address);
        assert!(delegated_to_after_undelegate == @0x0, EDELEGATOR_SHOULD_BE_UNBOUND);
        assert!(cooldown_after_undelegate > timestamp::now_seconds(), ECOOLDOWN_SHOULD_BE_ACTIVE);

        let cooldown_secs = staking_registry::get_cooldown_secs();
        timestamp::fast_forward_seconds(cooldown_secs);
        staking_registry::withdraw_deposit(delegator);

        let (deposit_after_withdraw, delegated_to_after_withdraw, cooldown_after_withdraw) =
            staking_registry::get_user_stake_info(delegator_address);
        assert!(deposit_after_withdraw == 0, EDEPOSIT_DID_NOT_GROW);
        assert!(delegated_to_after_withdraw == @0x0, EDELEGATOR_SHOULD_BE_UNBOUND);
        assert!(cooldown_after_withdraw == 0, ECOOLDOWN_SHOULD_BE_CLEARED);
    }

    // Validate that cooldown prevents immediate re-delegation and that the same
    // delegator can re-enter a validator pool once the cooldown has elapsed.
    #[test(
        aptos_framework = @aptos_framework,
        validator = @0x102,
        delegator = @0x202
    )]
    fun test_redelegate_after_cooldown_e2e(
        aptos_framework: &signer,
        validator: &signer,
        delegator: &signer,
    ) {
        poc_test_utils::setup_poc_env(aptos_framework);
        poc_test_utils::create_validator(aptos_framework, validator, 100);

        let validator_address = signer::address_of(validator);
        let delegator_address = signer::address_of(delegator);
        poc_test_utils::seed_genesis_power(aptos_framework, delegator_address, 100);
        stake::mint_and_add_stake(delegator, 100);
        staking_registry::delegate(delegator, validator_address);
        stake::join_validator_set(validator, validator_address);
        stake::end_epoch();
        staking_registry::undelegate(delegator);

        let (_, _, cooldown_until_secs) =
            staking_registry::get_user_stake_info(delegator_address);
        assert!(cooldown_until_secs > timestamp::now_seconds(), ECOOLDOWN_SHOULD_BE_ACTIVE);

        let cooldown_secs = staking_registry::get_cooldown_secs();
        timestamp::fast_forward_seconds(cooldown_secs);
        staking_registry::delegate(delegator, validator_address);

        poc_test_utils::assert_delegated_to(
            delegator_address,
            validator_address,
            EREDELEGATION_DID_NOT_SUCCEED,
        );
        let (_, _, cooldown_after_redelegate) =
            staking_registry::get_user_stake_info(delegator_address);
        assert!(cooldown_after_redelegate == 0, ECOOLDOWN_SHOULD_BE_CLEARED);
    }

    // Validate that multiple validators can join and leave through the public PoC path,
    // and that validator-set membership is rebuilt correctly across epoch boundaries.
    #[test(
        aptos_framework = @aptos_framework,
        validator_1 = @0x103,
        validator_2 = @0x104,
        validator_3 = @0x105
    )]
    fun test_multiple_validators_join_leave_e2e(
        aptos_framework: &signer,
        validator_1: &signer,
        validator_2: &signer,
        validator_3: &signer,
    ) {
        poc_test_utils::setup_poc_env(aptos_framework);

        poc_test_utils::create_validator(aptos_framework, validator_1, 100);
        poc_test_utils::create_validator(aptos_framework, validator_2, 100);
        poc_test_utils::create_validator(aptos_framework, validator_3, 100);

        let validator_1_address = signer::address_of(validator_1);
        let validator_2_address = signer::address_of(validator_2);
        let validator_3_address = signer::address_of(validator_3);

        stake::join_validator_set(validator_1, validator_1_address);
        stake::join_validator_set(validator_2, validator_2_address);
        stake::end_epoch();

        poc_test_utils::assert_current_set_size(2, ESET_SIZE_MISMATCH);
        poc_test_utils::assert_current_set_contains(
            validator_1_address,
            EVALIDATOR_MISSING_FROM_CURRENT_SET,
        );
        poc_test_utils::assert_current_set_contains(
            validator_2_address,
            EVALIDATOR_MISSING_FROM_CURRENT_SET,
        );

        stake::leave_validator_set(validator_2, validator_2_address);
        stake::join_validator_set(validator_3, validator_3_address);
        poc_test_utils::assert_validator_state(
            validator_2_address,
            3,
            EVALIDATOR_SHOULD_BE_PENDING_INACTIVE,
        );
        poc_test_utils::assert_validator_state(
            validator_3_address,
            1,
            EVALIDATOR_SHOULD_BE_PENDING_ACTIVE,
        );

        stake::end_epoch();

        poc_test_utils::assert_current_set_size(2, ESET_SIZE_MISMATCH);
        poc_test_utils::assert_current_set_contains(
            validator_1_address,
            EVALIDATOR_MISSING_FROM_CURRENT_SET,
        );
        poc_test_utils::assert_current_set_contains(
            validator_3_address,
            EVALIDATOR_MISSING_FROM_CURRENT_SET,
        );
        poc_test_utils::assert_current_set_excludes(
            validator_2_address,
            EVALIDATOR_UNEXPECTED_IN_CURRENT_SET,
        );
        poc_test_utils::assert_validator_state(
            validator_2_address,
            4,
            EVALIDATOR_SHOULD_BE_INACTIVE,
        );
        poc_test_utils::assert_validator_state(
            validator_3_address,
            2,
            EVALIDATOR_SHOULD_BE_ACTIVE,
        );
    }

    // The staking registry must reject delegation while a cooldown is still active.
    #[test(
        aptos_framework = @aptos_framework,
        validator = @0x106,
        delegator = @0x206
    )]
    #[expected_failure(abort_code = 0x30006, location = aptos_framework::staking_registry)]
    fun test_redelegate_before_cooldown_expires_should_fail(
        aptos_framework: &signer,
        validator: &signer,
        delegator: &signer,
    ) {
        poc_test_utils::setup_poc_env(aptos_framework);
        poc_test_utils::create_validator(aptos_framework, validator, 100);

        let validator_address = signer::address_of(validator);
        let delegator_address = signer::address_of(delegator);
        poc_test_utils::seed_genesis_power(aptos_framework, delegator_address, 100);
        stake::mint_and_add_stake(delegator, 100);
        staking_registry::delegate(delegator, validator_address);
        stake::join_validator_set(validator, validator_address);
        stake::end_epoch();
        staking_registry::undelegate(delegator);

        staking_registry::delegate(delegator, validator_address);
    }
}
