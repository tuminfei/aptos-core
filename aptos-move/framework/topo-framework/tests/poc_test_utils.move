#[test_only]
module topo_framework::poc_test_utils {
    use std::signer;

    use topo_framework::account;
    use topo_framework::event;
    use topo_framework::poc_power_store;
    use topo_framework::stake;
    use topo_framework::staking_registry;
    use topo_framework::validator_consensus_info;

    /// Shared status constants used by the external PoC end-to-end tests.
    ///
    /// These values intentionally mirror the constants in `stake.move`. The test
    /// modules keep their own copy because the production constants are not public.
    const VALIDATOR_STATUS_PENDING_ACTIVE: u64 = 1;
    const VALIDATOR_STATUS_ACTIVE: u64 = 2;
    const VALIDATOR_STATUS_PENDING_INACTIVE: u64 = 3;
    const VALIDATOR_STATUS_INACTIVE: u64 = 4;
    const TEST_POWER_PERIOD_IN_EPOCHS: u64 = 60;

    /// Bootstrap the common PoC test environment.
    ///
    /// The helper deliberately uses the production-style `power_period_in_epochs = 60`
    /// so external end-to-end tests validate the real period-boundary semantics instead
    /// of a shortened one-epoch approximation.
    ///
    /// The rest of the environment still goes through the real framework setup path from
    /// `stake.move`, and the pending fee accumulator is initialized eagerly so fee-oriented
    /// scenarios can exercise the production distribution logic without extra ceremony.
    public fun setup_poc_env(topo_framework: &signer) {
        poc_power_store::initialize_power_store_with_period(
            topo_framework,
            @topo_framework,
            TEST_POWER_PERIOD_IN_EPOCHS,
        );
        stake::initialize_for_test_custom(
            topo_framework,
            100,
            10000,
            3600,
            true,
            1,
            100,
            1000000,
        );
        stake::initialize_pending_transaction_fee(topo_framework);
    }

    /// Create a validator account with stake and POC power, but do not join it yet.
    ///
    /// This helper keeps all validator creation on the real production path:
    /// - initialize validator metadata
    /// - mint/deposit stake
    /// - seed POC power
    /// The caller remains responsible for deciding when to join and when to advance
    /// the epoch, which is important for scenario-specific assertions.
    public fun create_validator(
        topo_framework: &signer,
        validator: &signer,
        amount: u64,
    ) {
        let (_sk, pk, pop) = stake::generate_identity();
        stake::initialize_test_validator(
            topo_framework,
            &pk,
            &pop,
            validator,
            amount,
            false,
            false,
        );
    }

    /// Create a validator and activate it in the validator set.
    ///
    /// This is the standard entry point for scenarios that need a stable active
    /// validator before adding delegators or manipulating epoch transitions.
    public fun create_active_validator(
        topo_framework: &signer,
        validator: &signer,
        amount: u64,
    ) {
        create_validator(topo_framework, validator, amount);
        stake::join_validator_set(validator, signer::address_of(validator));
        stake::end_epoch();
        assert_validator_state(signer::address_of(validator), VALIDATOR_STATUS_ACTIVE, 0);
    }

    /// Seed a genesis-period committed power snapshot for `user`.
    ///
    /// This helper is intentionally explicit because it is only valid before the first
    /// committed epoch. Tests that need to update power after genesis should use
    /// `stage_next_period_power` instead.
    public fun seed_genesis_power(
        topo_framework: &signer,
        user: address,
        power: u64,
    ) {
        poc_power_store::set_genesis_committed_power(topo_framework, user, power);
    }

    /// Stage a power value for the next active period.
    ///
    /// With the test environment's 60-epoch period, the staged value becomes visible
    /// only after the chain crosses into the next power period.
    public fun stage_next_period_power(
        topo_framework: &signer,
        user: address,
        power: u64,
    ) {
        let target_period = poc_power_store::get_current_period() + 1;
        poc_power_store::stage_batch_update(
            topo_framework,
            target_period,
            vector[user],
            vector[power],
        );
    }

    public fun create_delegator_with_power_and_stake(
        topo_framework: &signer,
        delegator: &signer,
        validator_address: address,
        power: u64,
        stake_amount: u64,
    ) {
        let delegator_address = signer::address_of(delegator);
        account::create_account_for_test(delegator_address);
        seed_genesis_power(topo_framework, delegator_address, power);
        stake::mint_and_add_stake(delegator, stake_amount);
        staking_registry::delegate(delegator, validator_address);
    }

    /// Advance epochs until the requested power period becomes active.
    ///
    /// PoC power updates stage values for the next period rather than the next epoch.
    /// A dedicated helper keeps period-oriented scenarios readable and avoids copying
    /// the same epoch-loop logic across multiple tests.
    public fun advance_to_target_period(target_period: u64) {
        while (poc_power_store::get_current_period() < target_period) {
            stake::end_epoch();
        };
    }

    /// Advance the chain by a fixed number of epochs.
    ///
    /// With `power_period_in_epochs = 60`, many edge-case tests need to land exactly on
    /// the last epoch before a period boundary or cross that boundary deterministically.
    public fun advance_epochs(num_epochs: u64) {
        let i = 0;
        while (i < num_epochs) {
            stake::end_epoch();
            i += 1;
        };
    }

    /// Assert the validator lifecycle state exposed by `stake.move`.
    public fun assert_validator_state(pool_address: address, expected: u64, abort_code: u64) {
        assert!(stake::get_validator_state(pool_address) == expected, abort_code);
    }

    /// Assert the user's registry-level delegation target.
    public fun assert_delegated_to(user: address, expected: address, abort_code: u64) {
        let (_, delegated_to, _) = staking_registry::get_user_stake_info(user);
        assert!(delegated_to == expected, abort_code);
    }

    /// Assert the user's deposited balance tracked by `staking_registry`.
    public fun assert_deposit_at_least(user: address, minimum_deposit: u64, abort_code: u64) {
        let (deposit, _, _) = staking_registry::get_user_stake_info(user);
        assert!(deposit >= minimum_deposit, abort_code);
    }

    /// Assert that a user's cooldown is active.
    public fun assert_cooldown_active(user: address, abort_code: u64) {
        let (_, _, cooldown_until_secs) = staking_registry::get_user_stake_info(user);
        assert!(cooldown_until_secs > 0, abort_code);
    }

    /// Assert that the current validator set contains the target validator address.
    public fun assert_current_set_contains(validator: address, abort_code: u64) {
        let infos = stake::cur_validator_consensus_infos();
        let i = 0;
        let found = false;
        while (i < infos.length()) {
            if (validator_consensus_info::get_addr(infos.borrow(i)) == validator) {
                found = true;
            };
            i += 1;
        };
        assert!(found, abort_code);
    }

    /// Assert that the current validator set does not contain the target validator.
    public fun assert_current_set_excludes(validator: address, abort_code: u64) {
        let infos = stake::cur_validator_consensus_infos();
        let i = 0;
        while (i < infos.length()) {
            assert!(
                validator_consensus_info::get_addr(infos.borrow(i)) != validator,
                abort_code
            );
            i += 1;
        };
    }

    /// Assert the predicted next-epoch voting power for a validator.
    public fun assert_next_voting_power(
        validator: address,
        expected_voting_power: u64,
        abort_code: u64,
    ) {
        let infos = stake::next_validator_consensus_infos();
        let i = 0;
        while (i < infos.length()) {
            let info = infos.borrow(i);
            if (validator_consensus_info::get_addr(info) == validator) {
                assert!(
                    validator_consensus_info::get_voting_power(info) == expected_voting_power,
                    abort_code
                );
                return
            };
            i += 1;
        };
        abort abort_code
    }

    /// Assert the current validator-set voting power for a validator.
    public fun assert_current_voting_power(
        validator: address,
        expected_voting_power: u64,
        abort_code: u64,
    ) {
        let infos = stake::cur_validator_consensus_infos();
        let i = 0;
        while (i < infos.length()) {
            let info = infos.borrow(i);
            if (validator_consensus_info::get_addr(info) == validator) {
                assert!(
                    validator_consensus_info::get_voting_power(info) == expected_voting_power,
                    abort_code
                );
                return
            };
            i += 1;
        };
        abort abort_code
    }

    /// Assert the current validator-set size.
    public fun assert_current_set_size(expected_size: u64, abort_code: u64) {
        let infos = stake::cur_validator_consensus_infos();
        assert!(infos.length() == expected_size, abort_code);
    }

    /// Assert the next-epoch validator-set size computed by the production simulator.
    public fun assert_next_set_size(expected_size: u64, abort_code: u64) {
        let infos = stake::next_validator_consensus_infos();
        assert!(infos.length() == expected_size, abort_code);
    }

    /// Convenience wrapper so external tests can assert module-event presence without
    /// importing the event module everywhere.
    public fun assert_event_emitted<T: drop + store>(msg: &T, abort_code: u64) {
        assert!(event::was_event_emitted(msg), abort_code);
    }
}
