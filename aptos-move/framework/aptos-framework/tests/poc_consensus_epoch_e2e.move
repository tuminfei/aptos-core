#[test_only]
module aptos_framework::poc_consensus_epoch_e2e {
    use std::features;
    use std::signer;

    use aptos_framework::poc_test_utils;
    use aptos_framework::stake;
    use aptos_framework::staking_config;
    use aptos_framework::staking_registry;

    const EDEPOSIT_DID_NOT_INCREASE: u64 = 1;
    const EDELEGATOR_SHOULD_STILL_BE_BOUND: u64 = 2;
    const EDELEGATOR_SHOULD_BE_FORCE_UNBOUND: u64 = 3;
    const ECOOLDOWN_SHOULD_BE_SET: u64 = 4;
    const EUNEXPECTED_NEXT_POWER: u64 = 5;
    const EUNEXPECTED_CURRENT_POWER: u64 = 6;
    const ENEXT_SET_SIZE_MISMATCH: u64 = 7;
    const ECURRENT_SET_SIZE_MISMATCH: u64 = 8;
    const EVALIDATOR_SHOULD_BE_DROPPED: u64 = 9;
    const EFALLBACK_EVENT_MISSING: u64 = 10;
    const EFEE_EVENT_MISSING: u64 = 11;
    const EOWNER_DEPOSIT_DID_NOT_GROW: u64 = 12;
    const EVALIDATOR_SHOULD_STILL_BE_PENDING_INACTIVE: u64 = 13;
    const EVALIDATOR_SHOULD_BE_INACTIVE: u64 = 14;
    const EVALIDATOR_SHOULD_REMAIN_ACTIVE: u64 = 15;
    const EPOWER_SHOULD_INCLUDE_REWARDS: u64 = 16;
    const EHIGH_POWER_VALIDATOR_MISSING: u64 = 17;
    const EPOWER_SHOULD_BE_CAPPED: u64 = 18;
    const EPOWER_INCREASE_SHOULD_BE_CAPPED: u64 = 19;

    // Rewards for the current epoch must use the current committed power snapshot, while
    // force-undelegation at the period boundary must use the staged next-period power.
    #[test(
        aptos_framework = @aptos_framework,
        validator = @0x300,
        delegator = @0x301
    )]
    fun test_rewards_use_old_power_before_force_undelegate(
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
        poc_test_utils::stage_next_period_power(aptos_framework, delegator_address, 79);
        staking_registry::set_active_power_thresholds(aptos_framework, 100, 8000);
        stake::join_validator_set(validator, validator_address);
        stake::end_epoch();
        poc_test_utils::assert_validator_state(
            validator_address,
            2,
            EVALIDATOR_SHOULD_REMAIN_ACTIVE,
        );

        // Epoch 60 is the last epoch of period 0. The next epoch transition to epoch 61
        // is the first point where the staged period-1 power can affect force-undelegation.
        poc_test_utils::advance_epochs(59);
        let (deposit_before_boundary, delegated_to_before_boundary, cooldown_before_boundary) =
            staking_registry::get_user_stake_info(delegator_address);
        assert!(delegated_to_before_boundary == validator_address, EDELEGATOR_SHOULD_STILL_BE_BOUND);
        assert!(cooldown_before_boundary == 0, ECOOLDOWN_SHOULD_BE_SET);

        stake::end_epoch();
        let (deposit_after_boundary, delegated_to_after_boundary, cooldown_after_boundary) =
            staking_registry::get_user_stake_info(delegator_address);
        assert!(deposit_after_boundary > deposit_before_boundary, EDEPOSIT_DID_NOT_INCREASE);
        assert!(delegated_to_after_boundary == @0x0, EDELEGATOR_SHOULD_BE_FORCE_UNBOUND);
        assert!(cooldown_after_boundary > 0, ECOOLDOWN_SHOULD_BE_SET);
    }

    // A validator leaving the set remains reward-eligible for its final epoch because
    // `pending_inactive` pools are processed before removal.
    #[test(
        aptos_framework = @aptos_framework,
        validator = @0x302,
        keeper = @0x309,
        delegator = @0x303
    )]
    fun test_pending_inactive_gets_last_epoch_reward(
        aptos_framework: &signer,
        validator: &signer,
        keeper: &signer,
        delegator: &signer,
    ) {
        poc_test_utils::setup_poc_env(aptos_framework);
        poc_test_utils::create_validator(aptos_framework, validator, 100);
        poc_test_utils::create_validator(aptos_framework, keeper, 100);

        let validator_address = signer::address_of(validator);
        let keeper_address = signer::address_of(keeper);
        let delegator_address = signer::address_of(delegator);
        poc_test_utils::seed_genesis_power(aptos_framework, delegator_address, 100);
        stake::mint_and_add_stake(delegator, 100);
        staking_registry::delegate(delegator, validator_address);
        stake::join_validator_set(validator, validator_address);
        stake::join_validator_set(keeper, keeper_address);
        stake::end_epoch();

        stake::leave_validator_set(validator, validator_address);
        poc_test_utils::assert_validator_state(
            validator_address,
            3,
            EVALIDATOR_SHOULD_STILL_BE_PENDING_INACTIVE,
        );

        let (deposit_before_epoch, _, _) =
            staking_registry::get_user_stake_info(delegator_address);
        stake::end_epoch();
        let (deposit_after_epoch, _, _) =
            staking_registry::get_user_stake_info(delegator_address);

        assert!(deposit_after_epoch > deposit_before_epoch, EDEPOSIT_DID_NOT_INCREASE);
        poc_test_utils::assert_validator_state(
            validator_address,
            4,
            EVALIDATOR_SHOULD_BE_INACTIVE,
        );
    }

    // The next-epoch simulator must include epoch rewards when it computes the predicted
    // validator voting power exposed to Rust via `next_validator_consensus_infos`.
    #[test(aptos_framework = @aptos_framework, validator = @0x304)]
    fun test_next_validator_consensus_infos_includes_reward_adjusted_power(
        aptos_framework: &signer,
        validator: &signer,
    ) {
        poc_test_utils::setup_poc_env(aptos_framework);
        let validator_address = signer::address_of(validator);

        poc_test_utils::create_validator(aptos_framework, validator, 100);
        poc_test_utils::seed_genesis_power(aptos_framework, validator_address, 120);
        stake::join_validator_set(validator, validator_address);
        stake::end_epoch();

        staking_config::update_rewards_rate(aptos_framework, 25, 100);
        stake::set_validator_performance_for_test(0, 1, 0);
        staking_config::update_required_stake(aptos_framework, 110, 10000);

        poc_test_utils::assert_next_voting_power(
            validator_address,
            120,
            EPOWER_SHOULD_INCLUDE_REWARDS,
        );
        stake::end_epoch();
        poc_test_utils::assert_current_voting_power(
            validator_address,
            120,
            EPOWER_SHOULD_INCLUDE_REWARDS,
        );
    }

    // Validators whose next-epoch voting power falls below the minimum stake should be
    // removed from the next validator set at the epoch boundary when another validator
    // still satisfies the threshold, so the liveness fallback does not trigger.
    #[test(
        aptos_framework = @aptos_framework,
        validator_low = @0x305,
        validator_high = @0x308
    )]
    fun test_validator_below_minimum_stake_gets_dropped(
        aptos_framework: &signer,
        validator_low: &signer,
        validator_high: &signer,
    ) {
        poc_test_utils::setup_poc_env(aptos_framework);
        poc_test_utils::create_validator(aptos_framework, validator_low, 100);
        poc_test_utils::create_validator(aptos_framework, validator_high, 200);

        let low_address = signer::address_of(validator_low);
        let high_address = signer::address_of(validator_high);
        stake::join_validator_set(validator_low, low_address);
        stake::join_validator_set(validator_high, high_address);
        stake::end_epoch();

        staking_config::update_required_stake(aptos_framework, 150, 10000);
        poc_test_utils::assert_next_set_size(1, ENEXT_SET_SIZE_MISMATCH);
        poc_test_utils::assert_next_voting_power(high_address, 200, EHIGH_POWER_VALIDATOR_MISSING);
        stake::end_epoch();

        poc_test_utils::assert_current_set_size(1, ECURRENT_SET_SIZE_MISMATCH);
        poc_test_utils::assert_current_set_contains(high_address, EHIGH_POWER_VALIDATOR_MISSING);
        poc_test_utils::assert_current_set_excludes(low_address, EVALIDATOR_SHOULD_BE_DROPPED);
        poc_test_utils::assert_validator_state(
            low_address,
            4,
            EVALIDATOR_SHOULD_BE_DROPPED,
        );
    }

    #[test(aptos_framework = @aptos_framework, validator = @0x30a)]
    fun test_validator_power_is_capped_at_maximum_stake_on_epoch_recompute(
        aptos_framework: &signer,
        validator: &signer,
    ) {
        poc_test_utils::setup_poc_env(aptos_framework);
        staking_config::update_voting_power_increase_limit(aptos_framework, 50);
        let validator_address = signer::address_of(validator);

        poc_test_utils::create_validator(aptos_framework, validator, 9_900);
        poc_test_utils::seed_genesis_power(aptos_framework, validator_address, 20_000);
        stake::join_validator_set(validator, validator_address);
        stake::end_epoch();

        staking_config::update_rewards_rate(aptos_framework, 1, 1);
        stake::set_validator_performance_for_test(0, 1, 0);

        poc_test_utils::assert_next_voting_power(
            validator_address,
            10_000,
            EPOWER_SHOULD_BE_CAPPED,
        );
        stake::end_epoch();
        poc_test_utils::assert_current_voting_power(
            validator_address,
            10_000,
            EPOWER_SHOULD_BE_CAPPED,
        );
    }

    #[test(aptos_framework = @aptos_framework, validator = @0x30b)]
    fun test_active_validator_power_increase_is_capped_on_epoch_recompute(
        aptos_framework: &signer,
        validator: &signer,
    ) {
        poc_test_utils::setup_poc_env(aptos_framework);
        let validator_address = signer::address_of(validator);

        poc_test_utils::create_validator(aptos_framework, validator, 1_000);
        poc_test_utils::seed_genesis_power(aptos_framework, validator_address, 5_000);
        stake::join_validator_set(validator, validator_address);
        stake::end_epoch();

        staking_config::update_voting_power_increase_limit(aptos_framework, 50);
        staking_config::update_rewards_rate(aptos_framework, 1, 1);
        stake::set_validator_performance_for_test(0, 1, 0);

        poc_test_utils::assert_next_voting_power(
            validator_address,
            1_500,
            EPOWER_INCREASE_SHOULD_BE_CAPPED,
        );
        stake::end_epoch();
        poc_test_utils::assert_current_voting_power(
            validator_address,
            1_500,
            EPOWER_INCREASE_SHOULD_BE_CAPPED,
        );
    }

    // If every validator would be removed by the minimum-stake filter, the framework must
    // keep the previous active set and emit the liveness fallback event.
    #[test(aptos_framework = @aptos_framework, validator = @0x306)]
    fun test_empty_next_set_falls_back_to_previous_validator_set(
        aptos_framework: &signer,
        validator: &signer,
    ) {
        poc_test_utils::setup_poc_env(aptos_framework);
        poc_test_utils::create_active_validator(aptos_framework, validator, 100);

        staking_config::update_required_stake(aptos_framework, 1000, 10000);
        let validator_address = signer::address_of(validator);

        stake::end_epoch();

        poc_test_utils::assert_validator_state(
            validator_address,
            2,
            EVALIDATOR_SHOULD_REMAIN_ACTIVE,
        );
        poc_test_utils::assert_current_set_size(1, ECURRENT_SET_SIZE_MISMATCH);
        assert!(
            stake::was_validator_set_liveness_fallback_emitted(1000, 1, 100),
            EFALLBACK_EVENT_MISSING,
        );
    }

    // The VM fee-recording path exposed through the test-only seam must feed the same
    // fee distribution pipeline that `on_new_epoch` uses in production.
    #[test(aptos_framework = @aptos_framework, validator = @0x307, vm = @vm_reserved)]
    fun test_record_fee_for_test_distributes_transaction_fees(
        aptos_framework: &signer,
        validator: &signer,
        vm: &signer,
    ) {
        poc_test_utils::setup_poc_env(aptos_framework);
        poc_test_utils::create_active_validator(aptos_framework, validator, 100);
        features::change_feature_flags_for_testing(
            aptos_framework,
            vector[features::get_distribute_transaction_fee_feature()],
            vector[],
        );

        let validator_address = signer::address_of(validator);
        let (deposit_before_epoch, _, _) =
            staking_registry::get_user_stake_info(validator_address);

        stake::record_fee_for_test(vm, vector[0], vector[11]);
        stake::end_epoch();

        let (deposit_after_epoch, _, _) =
            staking_registry::get_user_stake_info(validator_address);

        assert!(deposit_after_epoch > deposit_before_epoch, EOWNER_DEPOSIT_DID_NOT_GROW);
        assert!(
            stake::was_transaction_fee_distributed(validator_address, 11),
            EFEE_EVENT_MISSING,
        );
    }
}
