/// Staking Registry — Delegation, power accounting, and reward distribution for the POC validator set.
///
/// ## Overview
///
/// This module is the economic heart of the Topo chain's Proof-of-Contribution (POC) staking system.
/// It replaces the traditional "stake amount = voting power" model with a hybrid model where a user's
/// effective voting power is the MINIMUM of:
///   1. Their committed POC power (from `poc_power_store`) — contribution-based weight
///   2. Their deposit coverage (deposit_octas / octas_per_power) — economic skin-in-the-game
///
/// This dual-constraint design ensures that:
/// - Pure capital holders without contribution history cannot dominate governance
/// - Pure contributors without economic stake cannot dominate governance
/// - Both dimensions must be maintained to retain voting influence
///
/// ## Key Concepts
///
/// - ValidatorPool: A pool owned by a validator. Delegators stake behind a pool to lend it their power.
/// - UserStakeInfo: Per-user record of deposited TOPO coins, current delegation target, and cooldown state.
/// - Effective Power: min(committed_poc_power, deposit_octas / octas_per_power)
/// - Commission: Validators earn a percentage of epoch rewards and transaction fees from their pool.
/// - Cooldown: After undelegating, users must wait `cooldown_secs` before they can re-delegate or withdraw.
///   This prevents rapid stake-hopping that could destabilize the validator set.
/// - Force Undelegate: If a user's effective power drops below `maintain_threshold` (a fraction of
///   `min_active_power`), they are automatically removed from the pool at epoch boundaries.
///
/// ## Reward Flow
///
/// At each epoch boundary (`on_new_epoch` in stake.move):
/// 1. `distribute_epoch_rewards` is called for each active/pending_inactive validator
/// 2. Rewards are minted proportionally to each delegator's effective power share
/// 3. Commission is taken first; remainder is split pro-rata among delegators
/// 4. Rewards are deposited directly into each user's `deposit` balance (auto-compounding)
/// 5. Transaction fees follow the same distribution path via `distribute_transaction_fees`
///
/// ## Validator Lifecycle (as seen by this module)
///
/// INACTIVE → PENDING_ACTIVE (join_validator_set) → ACTIVE (on_new_epoch)
///         → PENDING_INACTIVE (leave_validator_set) → INACTIVE (on_new_epoch)
///
/// Only ACTIVE and PENDING_INACTIVE validators contribute to effective power reads.
module aptos_framework::staking_registry {
    use std::error;
    use std::signer;

    use aptos_std::math64;
    use aptos_std::simple_map::{Self, SimpleMap};
    use aptos_std::smart_table::{Self, SmartTable};
    use aptos_std::table::{Self, Table};

    use aptos_framework::coin::{Self, Coin, MintCapability};
    use aptos_framework::poc_power_store;
    use aptos_framework::system_addresses;
    use aptos_framework::timestamp;
    use aptos_framework::topo_coin::TopoCoin;

    friend aptos_framework::genesis;
    friend aptos_framework::stake;
    friend aptos_framework::topo_governance;

    // ========== Error Codes ==========
    /// Target address is not a registered validator pool
    const ENOT_VALIDATOR: u64 = 1;
    /// Validator pool already exists for this address
    const EALREADY_VALIDATOR: u64 = 2;
    /// User is already delegated to a validator; must undelegate first
    const EALREADY_DELEGATED: u64 = 3;
    /// User is not currently delegated to any validator
    const ENOT_DELEGATED: u64 = 4;
    /// Deposit is locked because user is still delegated; must undelegate before withdrawing
    const EDEPOSIT_LOCKED: u64 = 5;
    /// Cooldown period has not yet elapsed; user must wait before re-delegating or withdrawing
    const ECOOLDOWN_ACTIVE: u64 = 6;
    /// Deposit amount must be greater than zero
    const EZERO_DEPOSIT: u64 = 7;
    /// Validator pool has reached its maximum delegator capacity
    const EMAX_DELEGATORS: u64 = 8;
    /// No stake info record found for this user address
    const EUSER_NOT_FOUND: u64 = 9;
    /// Commission basis points must be in range [0, 10000]
    const EINVALID_COMMISSION: u64 = 10;
    /// StakingRegistry resource has not been initialized
    const EREGISTRY_NOT_INITIALIZED: u64 = 11;
    /// MintCapability for TopoCoin has not been stored yet (must call store_topo_coin_mint_cap first)
    const EMINT_CAP_NOT_STORED: u64 = 12;
    /// Invalid configuration parameter (e.g. octas_per_power == 0)
    const EINVALID_CONFIG: u64 = 13;
    /// Registry or PendingMintCapability already initialized
    const EALREADY_INITIALIZED: u64 = 14;
    /// User's effective power is below the minimum required to join a validator pool
    const EPOWER_BELOW_MIN_ACTIVE: u64 = 15;

    // ========== Constants ==========
    /// At genesis, each octa of stake maps to this many units of power (default 1:1)
    const DEFAULT_GENESIS_STAKE_POWER_MULTIPLIER: u64 = 1;
    /// Minimum effective power required to delegate to a validator pool
    const DEFAULT_MIN_ACTIVE_POWER: u64 = 1;
    /// Users whose power falls below (min_active_power * force_exit_power_bps / 10000) are force-undelegated
    const DEFAULT_FORCE_EXIT_POWER_BPS: u64 = 8000;
    const MAX_U64: u128 = 18446744073709551615;
    const BPS_DENOMINATOR: u64 = 10000;

    // Validator lifecycle status constants (mirrors stake.move)
    const VALIDATOR_STATUS_PENDING_ACTIVE: u64 = 1;
    const VALIDATOR_STATUS_ACTIVE: u64 = 2;
    const VALIDATOR_STATUS_PENDING_INACTIVE: u64 = 3;
    const VALIDATOR_STATUS_INACTIVE: u64 = 4;

    // ========== Data Structures ==========

    /// Temporary holding resource for the TopoCoin MintCapability during genesis.
    /// Genesis calls `store_topo_coin_mint_cap` before `initialize`, so the cap
    /// must be parked here until the full registry is ready to receive it.
    struct PendingMintCapability has key {
        mint_cap: MintCapability<TopoCoin>,
    }

    /// The global staking registry, stored under @aptos_framework.
    ///
    /// Contains all validator pools, all user stake records, and the global config.
    /// The `mint_cap` is used to mint new TOPO coins as epoch rewards and fee distributions.
    struct StakingRegistry has key {
        /// Map from validator pool address → ValidatorPool
        validators: Table<address, ValidatorPool>,
        /// Map from user address → UserStakeInfo
        users: Table<address, UserStakeInfo>,
        /// Snapshot of total staked power across all active validators; updated at epoch boundaries
        total_staked_power: u64,
        /// Capability to mint TopoCoin for reward distribution
        mint_cap: MintCapability<TopoCoin>,
        config: StakingRegistryConfig,
    }

    /// Tunable parameters for the staking system.
    struct StakingRegistryConfig has copy, drop, store {
        /// How many octas (smallest TOPO unit) of deposit are required to back one unit of POC power.
        /// Effective power = min(poc_power, deposit_octas / octas_per_power)
        octas_per_power: u64,
        /// Hard cap on the number of delegators per validator pool.
        /// Prevents unbounded iteration cost during reward distribution.
        max_delegators_per_validator: u64,
        /// Seconds a user must wait after undelegating before they can re-delegate or withdraw.
        /// Set to max(recurring_lockup_duration, governance_voting_duration) at genesis.
        cooldown_secs: u64,
        /// Multiplier applied to stake_amount when computing genesis power.
        /// Default 1 means 1 octa of stake = 1 unit of genesis power.
        genesis_stake_power_multiplier: u64,
        /// Minimum effective power required to join or remain in a validator pool.
        min_active_power: u64,
        /// Users whose power falls below (min_active_power * force_exit_power_bps / 10000)
        /// are automatically removed from the pool at epoch boundaries.
        /// Default 8000 bps = 80% of min_active_power.
        force_exit_power_bps: u64,
    }

    /// A validator's delegation pool.
    ///
    /// `delegator_index` is a SmartTable for O(1) membership checks and O(1) removal
    /// (using swap-remove on `delegator_list`).
    struct ValidatorPool has store {
        /// The owner of this pool (receives commission rewards)
        owner_address: address,
        /// Maps delegator address → index in delegator_list (for O(1) removal)
        delegator_index: SmartTable<address, u64>,
        /// Ordered list of all current delegators
        delegator_list: vector<address>,
        /// Validator's commission rate in basis points (0–10000)
        commission_bps: u64,
        /// Current lifecycle status (PENDING_ACTIVE / ACTIVE / PENDING_INACTIVE / INACTIVE)
        status: u64,
    }

    /// Per-user staking state.
    struct UserStakeInfo has store {
        /// TOPO coins deposited by this user; held in escrow by the registry
        deposit: Coin<TopoCoin>,
        /// The validator pool this user is currently delegated to; @0x0 means not delegated
        delegated_to: address,
        /// Unix timestamp (seconds) after which the user may re-delegate or withdraw.
        /// Set to now + cooldown_secs when the user undelegates. 0 means no cooldown.
        cooldown_until_secs: u64,
    }

    #[view]
    public fun registry_exists(): bool {
        exists<StakingRegistry>(@aptos_framework)
    }

    /// Park the TopoCoin MintCapability before the registry is fully initialized.
    ///
    /// Called by `genesis::initialize_topo_coin` immediately after minting capabilities are created.
    /// The cap is stored in a temporary `PendingMintCapability` resource and consumed by `initialize`.
    /// This two-step approach avoids a circular dependency: the registry needs the mint cap,
    /// but the mint cap is created before the registry config parameters are known.
    public(friend) fun store_topo_coin_mint_cap(
        aptos_framework: &signer,
        mint_cap: MintCapability<TopoCoin>,
    ) {
        system_addresses::assert_aptos_framework(aptos_framework);
        assert!(
            !exists<PendingMintCapability>(@aptos_framework)
                && !exists<StakingRegistry>(@aptos_framework),
            error::already_exists(EALREADY_INITIALIZED),
        );
        move_to(aptos_framework, PendingMintCapability { mint_cap });
    }

    /// Initialize the StakingRegistry with configuration parameters.
    ///
    /// Consumes the `PendingMintCapability` parked by `store_topo_coin_mint_cap`.
    /// Idempotent: if the registry already exists, returns immediately without error.
    /// Called by `genesis::ensure_poc_staking_initialized`.
    public(friend) fun initialize(
        aptos_framework: &signer,
        octas_per_power: u64,
        max_delegators_per_validator: u64,
        cooldown_secs: u64,
    ) acquires PendingMintCapability {
        system_addresses::assert_aptos_framework(aptos_framework);
        if (exists<StakingRegistry>(@aptos_framework)) {
            return
        };

        assert!(octas_per_power > 0, error::invalid_argument(EINVALID_CONFIG));
        assert!(
            max_delegators_per_validator > 0,
            error::invalid_argument(EINVALID_CONFIG),
        );
        assert!(
            exists<PendingMintCapability>(@aptos_framework),
            error::not_found(EMINT_CAP_NOT_STORED),
        );

        let PendingMintCapability { mint_cap } = move_from<PendingMintCapability>(@aptos_framework);
        move_to(aptos_framework, StakingRegistry {
            validators: table::new(),
            users: table::new(),
            total_staked_power: 0,
            mint_cap,
            config: StakingRegistryConfig {
                octas_per_power,
                max_delegators_per_validator,
                cooldown_secs,
                genesis_stake_power_multiplier: DEFAULT_GENESIS_STAKE_POWER_MULTIPLIER,
                min_active_power: DEFAULT_MIN_ACTIVE_POWER,
                force_exit_power_bps: DEFAULT_FORCE_EXIT_POWER_BPS,
            },
        });
    }

    /// Update the minimum active power and force-exit threshold.
    ///
    /// `min_active_power`: minimum effective power a user must have to join a pool.
    /// `force_exit_power_bps`: users whose power falls below
    ///   (min_active_power * force_exit_power_bps / 10000) are force-undelegated at epoch boundaries.
    /// Setting force_exit_power_bps = 8000 means users are ejected when power < 80% of min_active_power,
    /// providing a hysteresis band to prevent thrashing at the boundary.
    public entry fun set_active_power_thresholds(
        aptos_framework: &signer,
        min_active_power: u64,
        force_exit_power_bps: u64,
    ) acquires StakingRegistry {
        system_addresses::assert_aptos_framework(aptos_framework);
        assert_registry_exists();
        assert_valid_active_power_config(min_active_power, force_exit_power_bps);

        let registry = borrow_global_mut<StakingRegistry>(@aptos_framework);
        registry.config.min_active_power = min_active_power;
        registry.config.force_exit_power_bps = force_exit_power_bps;
    }

    /// Update how much deposited TOPO is required to back one unit of POC power.
    ///
    /// Only the framework account may change this economic parameter. Lowering the value
    /// increases the amount of committed POC power that can become effective for a fixed
    /// deposit; raising it can reduce effective power and may cause low-coverage delegators
    /// to be force-undelegated at the next epoch boundary.
    public entry fun set_octas_per_power(
        aptos_framework: &signer,
        octas_per_power: u64,
    ) acquires StakingRegistry {
        system_addresses::assert_aptos_framework(aptos_framework);
        assert_registry_exists();
        assert!(octas_per_power > 0, error::invalid_argument(EINVALID_CONFIG));

        borrow_global_mut<StakingRegistry>(@aptos_framework).config.octas_per_power =
            octas_per_power;
    }

    public entry fun set_cooldown_secs(
        aptos_framework: &signer,
        cooldown_secs: u64,
    ) acquires StakingRegistry {
        system_addresses::assert_aptos_framework(aptos_framework);
        assert_registry_exists();

        borrow_global_mut<StakingRegistry>(@aptos_framework).config.cooldown_secs =
            cooldown_secs;
    }

    /// Ensure the cooldown period is at least `min_cooldown_secs`.
    ///
    /// Called during governance config updates to keep cooldown >= governance voting duration.
    /// This prevents a user from undelegating, voting, and re-delegating within a single
    /// governance proposal window — which would allow double-influence attacks.
    public(friend) fun ensure_min_cooldown_secs(
        aptos_framework: &signer,
        min_cooldown_secs: u64,
    ) acquires StakingRegistry {
        system_addresses::assert_aptos_framework(aptos_framework);
        if (!exists<StakingRegistry>(@aptos_framework)) {
            return
        };

        let registry = borrow_global_mut<StakingRegistry>(@aptos_framework);
        if (registry.config.cooldown_secs < min_cooldown_secs) {
            registry.config.cooldown_secs = min_cooldown_secs;
        };
    }

    /// Compute the initial POC power for a genesis validator from their stake amount.
    ///
    /// Formula: genesis_power = stake_amount * genesis_stake_power_multiplier
    /// Default multiplier is 1, so 1 octa of stake = 1 unit of genesis power.
    /// This is used in `genesis::create_initialize_validator` to seed the power store
    /// before the first epoch begins.
    public(friend) fun calculate_genesis_power_from_stake(
        stake_amount: u64,
    ): u64 acquires StakingRegistry {
        assert_registry_exists();
        let registry = borrow_global<StakingRegistry>(@aptos_framework);
        let wide_power =
            (stake_amount as u128) * (registry.config.genesis_stake_power_multiplier as u128);
        assert!(wide_power <= MAX_U64, error::invalid_argument(EINVALID_CONFIG));
        wide_power as u64
    }

    public entry fun register_validator(
        validator: &signer,
        commission_bps: u64,
    ) acquires StakingRegistry {
        assert_registry_exists();
        register_validator_internal(
            signer::address_of(validator),
            signer::address_of(validator),
            commission_bps,
        );
    }

    public(friend) fun register_validator_for_genesis(
        owner_address: address,
        validator_address: address,
        commission_bps: u64,
    ) acquires StakingRegistry {
        assert_registry_exists();
        register_validator_internal(owner_address, validator_address, commission_bps);
    }

    public(friend) fun register_validator_for_owner(
        owner_address: address,
        validator_address: address,
        commission_bps: u64,
    ) acquires StakingRegistry {
        assert_registry_exists();
        register_validator_internal(owner_address, validator_address, commission_bps);
    }

    /// Deposit TOPO coins into the registry as staking collateral.
    ///
    /// Deposited coins are held in escrow by the registry and cannot be withdrawn
    /// while the user is delegated to a validator. They serve as economic collateral
    /// that backs the user's POC power: effective_power = min(poc_power, deposit / octas_per_power).
    ///
    /// Deposits auto-compound: epoch rewards and fee shares are minted directly into
    /// the user's deposit balance, increasing their deposit coverage over time.
    public entry fun deposit(
        user: &signer,
        amount: u64,
    ) acquires StakingRegistry {
        assert_registry_exists();
        assert!(amount > 0, error::invalid_argument(EZERO_DEPOSIT));

        let user_address = signer::address_of(user);
        let registry = borrow_global_mut<StakingRegistry>(@aptos_framework);
        ensure_user_record(registry, user_address);

        let coins = coin::withdraw<TopoCoin>(user, amount);
        let info = registry.users.borrow_mut(user_address);
        coin::merge(&mut info.deposit, coins);
    }

    /// Delegate the user's staked deposit to a validator pool.
    ///
    /// Prerequisites:
    /// - User must not already be delegated (must call `undelegate` first)
    /// - Cooldown period must have elapsed (if any)
    /// - User's effective power must be >= min_active_power
    ///
    /// After delegation, the user's deposit backs the validator's total power,
    /// and the user begins receiving a proportional share of epoch rewards and fees.
    public entry fun delegate(
        user: &signer,
        validator_address: address,
    ) acquires StakingRegistry {
        assert_registry_exists();
        let user_address = signer::address_of(user);
        delegate_internal(user_address, validator_address);
    }

    /// Remove the user's delegation from their current validator pool.
    ///
    /// The user's deposit remains in the registry but no longer backs any validator's power.
    /// A cooldown period begins: the user must wait `cooldown_secs` before they can
    /// re-delegate or withdraw their deposit.
    ///
    /// This cooldown prevents rapid stake-hopping that could destabilize the validator set
    /// or enable governance manipulation (vote, undelegate, re-delegate, vote again).
    public entry fun undelegate(
        user: &signer,
    ) acquires StakingRegistry {
        assert_registry_exists();
        let user_address = signer::address_of(user);
        undelegate_internal(user_address);
    }

    /// Withdraw the user's full deposit back to their wallet.
    ///
    /// Requirements:
    /// - User must not be currently delegated (deposit is locked while delegated)
    /// - Cooldown period must have elapsed since undelegating
    ///
    /// After withdrawal, the user's deposit balance becomes zero and cooldown is cleared.
    public entry fun withdraw_deposit(
        user: &signer,
    ) acquires StakingRegistry {
        assert_registry_exists();
        let user_address = signer::address_of(user);
        let coins = extract_withdrawable_deposit(user_address);
        coin::deposit<TopoCoin>(user_address, coins);
    }

    #[view]
    /// Return the user's current effective power.
    ///
    /// Effective power = min(committed_poc_power, deposit_octas / octas_per_power)
    ///
    /// Returns 0 if:
    /// - User is not delegated to any validator
    /// - The validator they are delegated to is not ACTIVE or PENDING_INACTIVE
    /// - Either dimension (poc_power or deposit coverage) is zero
    ///
    /// This is the value used for governance voting weight and reward distribution.
    public fun get_effective_power(user: address): u64 acquires StakingRegistry {
        if (!exists<StakingRegistry>(@aptos_framework)) {
            return 0
        };

        let registry = borrow_global<StakingRegistry>(@aptos_framework);
        if (!registry.users.contains(user)) {
            return 0
        };

        let info = registry.users.borrow(user);
        if (info.delegated_to == @0x0) {
            return 0
        };
        if (!registry.validators.contains(info.delegated_to)) {
            return 0
        };

        let pool = registry.validators.borrow(info.delegated_to);
        if (pool.status != VALIDATOR_STATUS_ACTIVE
            && pool.status != VALIDATOR_STATUS_PENDING_INACTIVE) {
            return 0
        };

        calculate_effective_power(info, registry.config.octas_per_power, user)
    }

    #[view]
    public fun get_validator_joining_power(
        validator_address: address,
    ): u64 acquires StakingRegistry {
        if (!exists<StakingRegistry>(@aptos_framework)) {
            return 0
        };

        let registry = borrow_global<StakingRegistry>(@aptos_framework);
        if (!registry.validators.contains(validator_address)) {
            return 0
        };

        let pool = registry.validators.borrow(validator_address);
        get_user_effective_power_for_validator(
            registry,
            pool.owner_address,
            validator_address,
        )
    }

    #[view]
    public fun get_validator_total_power(
        validator_address: address,
    ): u64 acquires StakingRegistry {
        if (!exists<StakingRegistry>(@aptos_framework)) {
            return 0
        };

        let registry = borrow_global<StakingRegistry>(@aptos_framework);
        if (!registry.validators.contains(validator_address)) {
            return 0
        };

        let pool = registry.validators.borrow(validator_address);
        calculate_validator_total_power(registry, pool, validator_address)
    }

    public(friend) fun get_validator_total_power_for_next_epoch(
        validator_address: address,
    ): u64 acquires StakingRegistry {
        let extra_deposit_octas_by_user = simple_map::create<address, u64>();
        let (_, _, total_power) = get_validator_member_powers_for_next_epoch(
            validator_address,
            &extra_deposit_octas_by_user,
        );
        total_power
    }

    public(friend) fun get_validator_member_powers_for_next_epoch(
        validator_address: address,
        extra_deposit_octas_by_user: &SimpleMap<address, u64>,
    ): (vector<address>, vector<u64>, u64) acquires StakingRegistry {
        if (!exists<StakingRegistry>(@aptos_framework)) {
            return (vector[], vector[], 0)
        };

        let registry = borrow_global<StakingRegistry>(@aptos_framework);
        if (!registry.validators.contains(validator_address)) {
            return (vector[], vector[], 0)
        };

        let maintain_threshold = calculate_force_exit_power(
            registry.config.min_active_power,
            registry.config.force_exit_power_bps,
        );
        let pool = registry.validators.borrow(validator_address);
        let addresses = vector[];
        let powers = vector[];
        let total_power = 0u128;
        pool.delegator_list.for_each_ref(|member| {
            let extra_deposit_octas =
                if (extra_deposit_octas_by_user.contains_key(member)) {
                    *extra_deposit_octas_by_user.borrow(member)
                } else {
                    0
                };
            let power = get_user_effective_power_for_validator_for_next_epoch_with_extra_deposit(
                registry,
                *member,
                validator_address,
                maintain_threshold,
                extra_deposit_octas,
            );
            addresses.push_back(*member);
            powers.push_back(power);
            total_power += (power as u128);
        });
        (addresses, powers, total_power as u64)
    }

    public(friend) fun get_validator_member_powers_with_current_power(
        validator_address: address,
        extra_deposit_octas_by_user: &SimpleMap<address, u64>,
    ): (vector<address>, vector<u64>, u64) acquires StakingRegistry {
        if (!exists<StakingRegistry>(@aptos_framework)) {
            return (vector[], vector[], 0)
        };

        let registry = borrow_global<StakingRegistry>(@aptos_framework);
        if (!registry.validators.contains(validator_address)) {
            return (vector[], vector[], 0)
        };

        let pool = registry.validators.borrow(validator_address);
        let addresses = vector[];
        let powers = vector[];
        let total_power = 0u128;
        pool.delegator_list.for_each_ref(|member| {
            let extra_deposit_octas =
                if (extra_deposit_octas_by_user.contains_key(member)) {
                    *extra_deposit_octas_by_user.borrow(member)
                } else {
                    0
                };
            let power = get_user_effective_power_for_validator_with_extra_deposit(
                registry,
                *member,
                validator_address,
                extra_deposit_octas,
            );
            addresses.push_back(*member);
            powers.push_back(power);
            total_power += (power as u128);
        });
        (addresses, powers, total_power as u64)
    }

    #[view]
    public fun get_total_staked_power(): u64 acquires StakingRegistry {
        if (!exists<StakingRegistry>(@aptos_framework)) {
            0
        } else {
            borrow_global<StakingRegistry>(@aptos_framework).total_staked_power
        }
    }

    #[view]
    public fun validator_exists(validator_address: address): bool acquires StakingRegistry {
        exists<StakingRegistry>(@aptos_framework)
            && borrow_global<StakingRegistry>(@aptos_framework).validators.contains(validator_address)
    }

    #[view]
    public fun validators_exist(
        validators: vector<address>,
    ): vector<bool> acquires StakingRegistry {
        let exists_flags = vector[];
        if (!exists<StakingRegistry>(@aptos_framework)) {
            return exists_flags
        };
        let registry = borrow_global<StakingRegistry>(@aptos_framework);
        let len = validators.length();
        let i = 0;
        while (i < len) {
            exists_flags.push_back(registry.validators.contains(*validators.borrow(i)));
            i += 1;
        };
        exists_flags
    }

    #[view]
    public fun get_validator_view(
        validator_address: address,
    ): (address, address, u64, u64, u64, u64, u64) acquires StakingRegistry {
        if (!exists<StakingRegistry>(@aptos_framework)) {
            return empty_validator_view(validator_address)
        };
        let registry = borrow_global<StakingRegistry>(@aptos_framework);
        build_validator_view(registry, validator_address)
    }

    #[view]
    public fun get_validator_views_by_addresses(
        validators: vector<address>,
    ): (
        vector<address>,
        vector<address>,
        vector<u64>,
        vector<u64>,
        vector<u64>,
        vector<u64>,
        vector<u64>,
    ) acquires StakingRegistry {
        let validator_addresses = vector[];
        let owner_addresses = vector[];
        let commission_bps_values = vector[];
        let statuses = vector[];
        let delegator_counts = vector[];
        let joining_powers = vector[];
        let total_powers = vector[];
        if (!exists<StakingRegistry>(@aptos_framework)) {
            return (
                validator_addresses,
                owner_addresses,
                commission_bps_values,
                statuses,
                delegator_counts,
                joining_powers,
                total_powers,
            )
        };
        let registry = borrow_global<StakingRegistry>(@aptos_framework);
        let len = validators.length();
        let i = 0;
        while (i < len) {
            let (
                validator_address,
                owner_address,
                commission_bps,
                status,
                delegator_count,
                joining_power,
                total_power,
            ) = build_validator_view(registry, *validators.borrow(i));
            validator_addresses.push_back(validator_address);
            owner_addresses.push_back(owner_address);
            commission_bps_values.push_back(commission_bps);
            statuses.push_back(status);
            delegator_counts.push_back(delegator_count);
            joining_powers.push_back(joining_power);
            total_powers.push_back(total_power);
            i += 1;
        };
        (
            validator_addresses,
            owner_addresses,
            commission_bps_values,
            statuses,
            delegator_counts,
            joining_powers,
            total_powers,
        )
    }

    #[view]
    public fun get_user_stake_view(
        user: address,
    ): (address, u64, address, u64, u64, u64) acquires StakingRegistry {
        if (!exists<StakingRegistry>(@aptos_framework)) {
            return empty_user_stake_view(user)
        };
        let registry = borrow_global<StakingRegistry>(@aptos_framework);
        build_user_stake_view(registry, user)
    }

    #[view]
    public fun users_have_stake_records(
        users: vector<address>,
    ): vector<bool> acquires StakingRegistry {
        let exists_flags = vector[];
        if (!exists<StakingRegistry>(@aptos_framework)) {
            return exists_flags
        };
        let registry = borrow_global<StakingRegistry>(@aptos_framework);
        let len = users.length();
        let i = 0;
        while (i < len) {
            exists_flags.push_back(registry.users.contains(*users.borrow(i)));
            i += 1;
        };
        exists_flags
    }

    #[view]
    public fun get_user_stake_views_by_addresses(
        users: vector<address>,
    ): (
        vector<address>,
        vector<u64>,
        vector<address>,
        vector<u64>,
        vector<u64>,
        vector<u64>,
    ) acquires StakingRegistry {
        let returned_users = vector[];
        let deposit_octas_values = vector[];
        let delegated_to_values = vector[];
        let cooldown_until_secs_values = vector[];
        let committed_powers = vector[];
        let effective_powers = vector[];
        if (!exists<StakingRegistry>(@aptos_framework)) {
            return (
                returned_users,
                deposit_octas_values,
                delegated_to_values,
                cooldown_until_secs_values,
                committed_powers,
                effective_powers,
            )
        };
        let registry = borrow_global<StakingRegistry>(@aptos_framework);
        let len = users.length();
        let i = 0;
        while (i < len) {
            let (
                user,
                deposit_octas,
                delegated_to,
                cooldown_until_secs,
                committed_power,
                effective_power,
            ) = build_user_stake_view(registry, *users.borrow(i));
            returned_users.push_back(user);
            deposit_octas_values.push_back(deposit_octas);
            delegated_to_values.push_back(delegated_to);
            cooldown_until_secs_values.push_back(cooldown_until_secs);
            committed_powers.push_back(committed_power);
            effective_powers.push_back(effective_power);
            i += 1;
        };
        (
            returned_users,
            deposit_octas_values,
            delegated_to_values,
            cooldown_until_secs_values,
            committed_powers,
            effective_powers,
        )
    }

    #[view]
    public fun get_validator_delegator_count(
        validator_address: address,
    ): u64 acquires StakingRegistry {
        if (!exists<StakingRegistry>(@aptos_framework)) {
            return 0
        };
        let registry = borrow_global<StakingRegistry>(@aptos_framework);
        if (!registry.validators.contains(validator_address)) {
            return 0
        };
        registry.validators.borrow(validator_address).delegator_list.length()
    }

    #[view]
    public fun get_validator_delegators(
        validator_address: address,
        offset: u64,
        limit: u64,
    ): vector<address> acquires StakingRegistry {
        if (!exists<StakingRegistry>(@aptos_framework)) {
            return vector[]
        };
        let registry = borrow_global<StakingRegistry>(@aptos_framework);
        if (!registry.validators.contains(validator_address)) {
            return vector[]
        };
        let pool = registry.validators.borrow(validator_address);
        copy_address_range(&pool.delegator_list, offset, limit)
    }

    #[view]
    public fun get_validator_delegator_views(
        validator_address: address,
        offset: u64,
        limit: u64,
    ): (vector<address>, vector<u64>, vector<u64>, vector<u64>) acquires StakingRegistry {
        let delegators = vector[];
        let deposit_octas_values = vector[];
        let committed_powers = vector[];
        let effective_powers = vector[];
        if (!exists<StakingRegistry>(@aptos_framework)) {
            return (delegators, deposit_octas_values, committed_powers, effective_powers)
        };
        let registry = borrow_global<StakingRegistry>(@aptos_framework);
        if (!registry.validators.contains(validator_address)) {
            return (delegators, deposit_octas_values, committed_powers, effective_powers)
        };
        let pool = registry.validators.borrow(validator_address);
        let len = pool.delegator_list.length();
        let i = offset;
        let end = range_end(offset, limit, len);
        while (i < end) {
            let delegator = *pool.delegator_list.borrow(i);
            let (deposit_octas, committed_power, effective_power) =
                build_delegator_view(registry, delegator, validator_address);
            delegators.push_back(delegator);
            deposit_octas_values.push_back(deposit_octas);
            committed_powers.push_back(committed_power);
            effective_powers.push_back(effective_power);
            i += 1;
        };
        (delegators, deposit_octas_values, committed_powers, effective_powers)
    }

    #[view]
    public fun get_user_stake_info(
        user: address,
    ): (u64, address, u64) acquires StakingRegistry {
        if (!exists<StakingRegistry>(@aptos_framework)) {
            return (0, @0x0, 0)
        };

        let registry = borrow_global<StakingRegistry>(@aptos_framework);
        if (!registry.users.contains(user)) {
            return (0, @0x0, 0)
        };

        let info = registry.users.borrow(user);
        (coin::value(&info.deposit), info.delegated_to, info.cooldown_until_secs)
    }

    #[view]
    public fun get_validator_owner(
        validator_address: address,
    ): address acquires StakingRegistry {
        if (!exists<StakingRegistry>(@aptos_framework)) {
            return @0x0
        };

        let registry = borrow_global<StakingRegistry>(@aptos_framework);
        if (!registry.validators.contains(validator_address)) {
            return @0x0
        };

        registry.validators.borrow(validator_address).owner_address
    }

    #[view]
    public fun get_validator_commission_bps(
        validator_address: address,
    ): u64 acquires StakingRegistry {
        if (!exists<StakingRegistry>(@aptos_framework)) {
            return 0
        };

        let registry = borrow_global<StakingRegistry>(@aptos_framework);
        if (!registry.validators.contains(validator_address)) {
            return 0
        };

        registry.validators.borrow(validator_address).commission_bps
    }

    public(friend) fun set_total_staked_power(total_staked_power: u64) acquires StakingRegistry {
        if (!exists<StakingRegistry>(@aptos_framework)) {
            return
        };
        borrow_global_mut<StakingRegistry>(@aptos_framework).total_staked_power = total_staked_power;
    }

    #[view]
    public fun get_cooldown_secs(): u64 acquires StakingRegistry {
        if (!exists<StakingRegistry>(@aptos_framework)) {
            0
        } else {
            borrow_global<StakingRegistry>(@aptos_framework).config.cooldown_secs
        }
    }

    #[view]
    public fun get_octas_per_power(): u64 acquires StakingRegistry {
        if (!exists<StakingRegistry>(@aptos_framework)) {
            0
        } else {
            borrow_global<StakingRegistry>(@aptos_framework).config.octas_per_power
        }
    }

    public(friend) fun set_validator_pending_active(
        validator_address: address,
    ) acquires StakingRegistry {
        set_validator_status(validator_address, VALIDATOR_STATUS_PENDING_ACTIVE);
    }

    public(friend) fun set_validator_active(
        validator_address: address,
    ) acquires StakingRegistry {
        set_validator_status(validator_address, VALIDATOR_STATUS_ACTIVE);
    }

    public(friend) fun set_validator_pending_inactive(
        validator_address: address,
    ) acquires StakingRegistry {
        set_validator_status(validator_address, VALIDATOR_STATUS_PENDING_INACTIVE);
    }

    public(friend) fun set_validator_inactive(
        validator_address: address,
    ) acquires StakingRegistry {
        set_validator_status(validator_address, VALIDATOR_STATUS_INACTIVE);
    }

    /// Force-undelegate all delegators of a validator pool whose effective power has dropped
    /// below the maintain threshold.
    ///
    /// Called by `stake::on_new_epoch` for every active, pending_inactive, and pending_active pool.
    ///
    /// Why force-undelegate?
    /// - A user's POC power can decay over time (retention) or drop if they stop contributing.
    /// - If their power falls below the maintain threshold, they no longer meaningfully back
    ///   the validator and should be removed to keep pool accounting clean.
    /// - maintain_threshold = ceil(min_active_power * force_exit_power_bps / 10000)
    ///   The ceiling ensures the threshold is at least 1 when min_active_power > 0.
    ///
    /// Force-undelegated users receive the same cooldown as voluntary undelegation.
    public(friend) fun force_undelegate_below_threshold(
        validator_address: address,
    ) acquires StakingRegistry {
        if (!exists<StakingRegistry>(@aptos_framework)) {
            return
        };

        let registry = borrow_global_mut<StakingRegistry>(@aptos_framework);
        if (!registry.validators.contains(validator_address)) {
            return
        };

        let maintain_threshold = calculate_force_exit_power(
            registry.config.min_active_power,
            registry.config.force_exit_power_bps,
        );
        let members = {
            let pool = registry.validators.borrow(validator_address);
            copy_addresses(&pool.delegator_list)
        };

        let len = members.length();
        let i = 0;
        while (i < len) {
            let member = *members.borrow(i);
            if (should_force_undelegate(
                registry,
                member,
                validator_address,
                maintain_threshold,
            )) {
                force_undelegate_member(registry, member, validator_address);
            };
            i += 1;
        };
    }

    public(friend) fun update_validator_commission(
        validator_address: address,
        commission_bps: u64,
    ) acquires StakingRegistry {
        assert_valid_commission(commission_bps);
        if (!exists<StakingRegistry>(@aptos_framework)) {
            return
        };

        let registry = borrow_global_mut<StakingRegistry>(@aptos_framework);
        if (!registry.validators.contains(validator_address)) {
            return
        };
        registry.validators.borrow_mut(validator_address).commission_bps = commission_bps;
    }

    /// Distribute epoch staking rewards to all delegators of a validator pool.
    ///
    /// Called by `stake::on_new_epoch` for each active and pending_inactive validator.
    ///
    /// Reward formula:
    ///   epoch_reward = pool_power * rewards_rate * num_successful_proposals
    ///                  / (rewards_rate_denominator * num_total_proposals)
    ///
    /// Distribution:
    ///   commission = epoch_reward * commission_bps / 10000  → minted to owner's deposit
    ///   distributable = epoch_reward - commission
    ///   each delegator gets: distributable * member_power / pool_power
    ///   rounding dust (distributable - sum_distributed) goes to the owner
    ///
    /// All rewards are minted as new TopoCoin and deposited directly into each user's
    /// registry deposit balance (auto-compounding — no separate claim step needed).
    ///
    /// If pool_power == 0 or epoch_reward == 0, this is a no-op.
    public(friend) fun distribute_epoch_rewards(
        validator_address: address,
        num_successful_proposals: u64,
        num_total_proposals: u64,
        rewards_rate: u64,
        rewards_rate_denominator: u64,
    ) acquires StakingRegistry {
        if (!exists<StakingRegistry>(@aptos_framework)) {
            return
        };

        let registry = borrow_global<StakingRegistry>(@aptos_framework);
        if (!registry.validators.contains(validator_address)) {
            return
        };

        let pool = registry.validators.borrow(validator_address);
        let owner_address = pool.owner_address;
        let commission_bps = pool.commission_bps;
        let members = copy_addresses(&pool.delegator_list);
        let member_powers = vector<u64>[];
        let pool_power = 0u128;
        members.for_each_ref(|member| {
            let power = get_user_effective_power_for_validator(registry, *member, validator_address);
            member_powers.push_back(power);
            pool_power += (power as u128);
        });

        if (pool_power == 0) {
            return
        };

        let epoch_reward = calculate_rewards_amount(
            pool_power as u64,
            num_successful_proposals,
            num_total_proposals,
            rewards_rate,
            rewards_rate_denominator,
        );
        if (epoch_reward == 0) {
            return
        };

        let commission = (((epoch_reward as u128) * (commission_bps as u128)) / 10000) as u64;
        let distributable = epoch_reward - commission;

        let registry = borrow_global_mut<StakingRegistry>(@aptos_framework);
        let mint_cap = &registry.mint_cap;
        let users = &mut registry.users;

        let sum_distributed = 0u64;
        let len = members.length();
        let i = 0;
        while (i < len) {
            let member = *members.borrow(i);
            let member_power = *member_powers.borrow(i);
            if (member_power > 0) {
                let reward = (((distributable as u128) * (member_power as u128)) / pool_power) as u64;
                if (reward > 0) {
                    mint_to_user_deposit(users, mint_cap, member, reward);
                };
                sum_distributed += reward;
            };
            i += 1;
        };

        let owner_reward = commission + (distributable - sum_distributed);
        if (owner_reward > 0) {
            mint_to_user_deposit(users, mint_cap, owner_address, owner_reward);
        };
    }

    /// Distribute transaction fees collected during an epoch to all delegators of a validator pool.
    ///
    /// Called by `stake::on_new_epoch` after `distribute_epoch_rewards`, for each validator
    /// that has a non-zero fee share (requires the distribute_transaction_fee feature flag).
    ///
    /// Distribution logic is identical to `distribute_epoch_rewards`:
    ///   commission = fee_amount * commission_bps / 10000  → owner's deposit
    ///   remainder split pro-rata by effective power among delegators
    ///   rounding dust goes to the owner
    ///
    /// Fees are minted as new TopoCoin (the fee was already burned at the protocol level;
    /// this re-mints the validator's share as a reward).
    public(friend) fun distribute_transaction_fees(
        validator_address: address,
        fee_amount_octa: u64,
    ) acquires StakingRegistry {
        if (!exists<StakingRegistry>(@aptos_framework) || fee_amount_octa == 0) {
            return
        };

        let registry = borrow_global<StakingRegistry>(@aptos_framework);
        if (!registry.validators.contains(validator_address)) {
            return
        };

        let pool = registry.validators.borrow(validator_address);
        let owner_address = pool.owner_address;
        let commission_bps = pool.commission_bps;
        let members = copy_addresses(&pool.delegator_list);
        let member_powers = vector<u64>[];
        let pool_power = 0u128;
        members.for_each_ref(|member| {
            let power = get_user_effective_power_for_validator(registry, *member, validator_address);
            member_powers.push_back(power);
            pool_power += (power as u128);
        });

        if (pool_power == 0) {
            return
        };

        let commission = (((fee_amount_octa as u128) * (commission_bps as u128)) / 10000) as u64;
        let distributable = fee_amount_octa - commission;

        let registry = borrow_global_mut<StakingRegistry>(@aptos_framework);
        let mint_cap = &registry.mint_cap;
        let users = &mut registry.users;

        let sum_distributed = 0u64;
        let len = members.length();
        let i = 0;
        while (i < len) {
            let member = *members.borrow(i);
            let member_power = *member_powers.borrow(i);
            if (member_power > 0) {
                let fee_share =
                    (((distributable as u128) * (member_power as u128)) / pool_power) as u64;
                if (fee_share > 0) {
                    mint_to_user_deposit(users, mint_cap, member, fee_share);
                };
                sum_distributed += fee_share;
            };
            i += 1;
        };

        let owner_fee = commission + (distributable - sum_distributed);
        if (owner_fee > 0) {
            mint_to_user_deposit(users, mint_cap, owner_address, owner_fee);
        };
    }

    fun register_validator_internal(
        owner_address: address,
        validator_address: address,
        commission_bps: u64,
    ) acquires StakingRegistry {
        assert_valid_commission(commission_bps);
        let registry = borrow_global_mut<StakingRegistry>(@aptos_framework);
        assert!(
            !registry.validators.contains(validator_address),
            error::already_exists(EALREADY_VALIDATOR),
        );

        ensure_user_record(registry, owner_address);

        registry.validators.add(validator_address, ValidatorPool {
            owner_address,
            delegator_index: smart_table::new(),
            delegator_list: vector[],
            commission_bps,
            status: VALIDATOR_STATUS_INACTIVE,
        });
    }

    /// Internal delegation logic shared by `delegate` and genesis paths.
    ///
    /// Checks:
    /// 1. Validator pool must exist
    /// 2. User must not already be delegated
    /// 3. Cooldown must have elapsed
    /// 4. User's effective power must be >= min_active_power
    /// 5. Pool must not exceed max_delegators_per_validator
    ///
    /// On success: adds user to pool's delegator_list, sets delegated_to, clears cooldown.
    fun delegate_internal(
        user_address: address,
        validator_address: address,
    ) acquires StakingRegistry {
        let registry = borrow_global_mut<StakingRegistry>(@aptos_framework);
        assert!(
            registry.validators.contains(validator_address),
            error::invalid_argument(ENOT_VALIDATOR),
        );

        ensure_user_record(registry, user_address);

        let now_seconds = timestamp::now_seconds();
        let info = registry.users.borrow(user_address);
        assert!(info.delegated_to == @0x0, error::invalid_state(EALREADY_DELEGATED));
        assert!(
            info.cooldown_until_secs == 0 || now_seconds >= info.cooldown_until_secs,
            error::invalid_state(ECOOLDOWN_ACTIVE),
        );
        let effective_power =
            calculate_effective_power(info, registry.config.octas_per_power, user_address);
        assert!(
            effective_power >= registry.config.min_active_power,
            error::invalid_argument(EPOWER_BELOW_MIN_ACTIVE),
        );

        let max_delegators = registry.config.max_delegators_per_validator;
        let pool = registry.validators.borrow_mut(validator_address);
        add_delegator(pool, user_address, max_delegators);

        let info = registry.users.borrow_mut(user_address);
        info.delegated_to = validator_address;
        info.cooldown_until_secs = 0;
    }

    fun undelegate_internal(
        user_address: address,
    ) acquires StakingRegistry {
        let registry = borrow_global_mut<StakingRegistry>(@aptos_framework);
        assert!(registry.users.contains(user_address), error::not_found(EUSER_NOT_FOUND));

        let delegated_to = registry.users.borrow(user_address).delegated_to;
        assert!(delegated_to != @0x0, error::invalid_state(ENOT_DELEGATED));

        let pool = registry.validators.borrow_mut(delegated_to);
        remove_delegator(pool, user_address);

        let info = registry.users.borrow_mut(user_address);
        info.delegated_to = @0x0;
        info.cooldown_until_secs = timestamp::now_seconds() + registry.config.cooldown_secs;
    }

    fun assert_registry_exists() {
        assert!(
            exists<StakingRegistry>(@aptos_framework),
            error::not_found(EREGISTRY_NOT_INITIALIZED),
        );
    }

    fun assert_valid_commission(commission_bps: u64) {
        assert!(commission_bps <= 10000, error::invalid_argument(EINVALID_COMMISSION));
    }

    fun assert_valid_active_power_config(
        min_active_power: u64,
        force_exit_power_bps: u64,
    ) {
        assert!(min_active_power > 0, error::invalid_argument(EINVALID_CONFIG));
        assert!(
            force_exit_power_bps > 0 && force_exit_power_bps <= BPS_DENOMINATOR,
            error::invalid_argument(EINVALID_CONFIG),
        );
    }

    fun extract_withdrawable_deposit(
        user_address: address,
    ): Coin<TopoCoin> acquires StakingRegistry {
        let registry = borrow_global_mut<StakingRegistry>(@aptos_framework);
        assert!(registry.users.contains(user_address), error::not_found(EUSER_NOT_FOUND));

        let info = registry.users.borrow(user_address);
        assert!(info.delegated_to == @0x0, error::invalid_state(EDEPOSIT_LOCKED));
        assert!(
            info.cooldown_until_secs == 0 || timestamp::now_seconds() >= info.cooldown_until_secs,
            error::invalid_state(ECOOLDOWN_ACTIVE),
        );

        let info = registry.users.borrow_mut(user_address);
        let coins = coin::extract_all(&mut info.deposit);
        info.cooldown_until_secs = 0;
        coins
    }

    fun new_user_info(): UserStakeInfo {
        UserStakeInfo {
            deposit: coin::zero<TopoCoin>(),
            delegated_to: @0x0,
            cooldown_until_secs: 0,
        }
    }

    fun ensure_user_record(registry: &mut StakingRegistry, user_address: address) {
        if (!registry.users.contains(user_address)) {
            registry.users.add(user_address, new_user_info());
        };
    }

    fun mint_to_user_deposit(
        users: &mut Table<address, UserStakeInfo>,
        mint_cap: &MintCapability<TopoCoin>,
        user_address: address,
        amount: u64,
    ) {
        if (amount == 0) {
            return
        };
        if (!users.contains(user_address)) {
            users.add(user_address, new_user_info());
        };
        let minted = coin::mint<TopoCoin>(amount, mint_cap);
        let info = users.borrow_mut(user_address);
        coin::merge(&mut info.deposit, minted);
    }

    /// Add a delegator to a validator pool using a swap-remove index for O(1) future removal.
    ///
    /// The delegator_index SmartTable maps address → position in delegator_list,
    /// enabling O(1) removal via swap-remove without scanning the full list.
    fun add_delegator(
        pool: &mut ValidatorPool,
        delegator: address,
        max_delegators: u64,
    ) {
        assert!(
            !pool.delegator_index.contains(delegator),
            error::already_exists(EALREADY_DELEGATED),
        );
        assert!(
            pool.delegator_list.length() < max_delegators,
            error::invalid_argument(EMAX_DELEGATORS),
        );
        let index = pool.delegator_list.length();
        pool.delegator_list.push_back(delegator);
        pool.delegator_index.add(delegator, index);
    }

    /// Remove a delegator from a validator pool using swap-remove for O(1) complexity.
    ///
    /// Swap-remove: the target delegator's slot is filled by the last element in the list,
    /// then the list is shrunk by one. The index table is updated accordingly.
    /// This avoids O(n) shifting while keeping the list compact.
    fun remove_delegator(
        pool: &mut ValidatorPool,
        delegator: address,
    ) {
        assert!(
            pool.delegator_index.contains(delegator),
            error::invalid_state(ENOT_DELEGATED),
        );
        let index = pool.delegator_index.remove(delegator);
        let last_index = pool.delegator_list.length() - 1;

        if (index != last_index) {
            let last_addr = *pool.delegator_list.borrow(last_index);
            *pool.delegator_list.borrow_mut(index) = last_addr;
            *pool.delegator_index.borrow_mut(last_addr) = index;
        };
        pool.delegator_list.pop_back();
    }

    fun set_validator_status(
        validator_address: address,
        status: u64,
    ) acquires StakingRegistry {
        if (!exists<StakingRegistry>(@aptos_framework)) {
            return
        };

        let registry = borrow_global_mut<StakingRegistry>(@aptos_framework);
        if (!registry.validators.contains(validator_address)) {
            return
        };

        registry.validators.borrow_mut(validator_address).status = status;
    }

    /// Compute the maintain threshold for force-undelegation using ceiling division.
    ///
    /// maintain_threshold = ceil(min_active_power * force_exit_power_bps / BPS_DENOMINATOR)
    ///
    /// Ceiling division ensures the threshold is at least 1 when min_active_power > 0,
    /// preventing a threshold of 0 that would never trigger force-undelegation.
    ///
    /// Example: min_active_power=10, force_exit_power_bps=8000
    ///   threshold = ceil(10 * 8000 / 10000) = ceil(8.0) = 8
    ///   Users with effective_power < 8 are force-undelegated.
    fun calculate_force_exit_power(
        min_active_power: u64,
        force_exit_power_bps: u64,
    ): u64 {
        let numerator =
            ((min_active_power as u128) * (force_exit_power_bps as u128))
                + ((BPS_DENOMINATOR - 1) as u128);
        (numerator / (BPS_DENOMINATOR as u128)) as u64
    }

    fun should_force_undelegate(
        registry: &StakingRegistry,
        user: address,
        validator_address: address,
        maintain_threshold: u64,
    ): bool {
        if (!registry.users.contains(user)) {
            return false
        };

        let info = registry.users.borrow(user);
        if (info.delegated_to != validator_address) {
            return false
        };

        calculate_effective_power(info, registry.config.octas_per_power, user) < maintain_threshold
    }

    fun force_undelegate_member(
        registry: &mut StakingRegistry,
        user_address: address,
        validator_address: address,
    ) {
        let pool = registry.validators.borrow_mut(validator_address);
        remove_delegator(pool, user_address);

        let info = registry.users.borrow_mut(user_address);
        info.delegated_to = @0x0;
        info.cooldown_until_secs = timestamp::now_seconds() + registry.config.cooldown_secs;
    }

    /// Compute a user's effective power from their current stake info.
    ///
    /// effective_power = min(committed_poc_power, deposit_octas / octas_per_power)
    ///
    /// The dual-constraint design:
    /// - `committed_poc_power` (from poc_power_store) represents contribution-based weight.
    ///   It is computed off-chain from ContributionEvents and uploaded by the operator.
    /// - `deposit_cover` represents economic skin-in-the-game: how much power the user's
    ///   deposited TOPO coins can back at the current octas_per_power exchange rate.
    ///
    /// Taking the minimum ensures both dimensions must be maintained simultaneously.
    /// A user who stops contributing loses poc_power (via decay) and their effective power drops.
    /// A user who withdraws their deposit loses deposit_cover and their effective power drops.
    fun calculate_effective_power(
        info: &UserStakeInfo,
        octas_per_power: u64,
        user: address,
    ): u64 {
        let committed_power = poc_power_store::get_user_committed_power(user);
        if (committed_power == 0) {
            return 0
        };
        let deposit_octas = coin::value(&info.deposit);
        let deposit_cover = deposit_octas / octas_per_power;
        math64::min(committed_power, deposit_cover)
    }

    fun get_user_effective_power_for_validator(
        registry: &StakingRegistry,
        user: address,
        validator_address: address,
    ): u64 {
        get_user_effective_power_for_validator_with_extra_deposit(
            registry,
            user,
            validator_address,
            0,
        )
    }

    fun get_user_effective_power_for_validator_with_extra_deposit(
        registry: &StakingRegistry,
        user: address,
        validator_address: address,
        extra_deposit_octas: u64,
    ): u64 {
        if (!registry.users.contains(user)) {
            return 0
        };

        let info = registry.users.borrow(user);
        if (info.delegated_to != validator_address) {
            return 0
        };

        let committed_power = poc_power_store::get_user_committed_power(user);
        if (committed_power == 0) {
            return 0
        };
        let deposit_octas = coin::value(&info.deposit) + extra_deposit_octas;
        let deposit_cover = deposit_octas / registry.config.octas_per_power;
        math64::min(committed_power, deposit_cover)
    }

    fun get_user_effective_power_for_validator_for_next_epoch(
        registry: &StakingRegistry,
        user: address,
        validator_address: address,
        maintain_threshold: u64,
    ): u64 {
        get_user_effective_power_for_validator_for_next_epoch_with_extra_deposit(
            registry,
            user,
            validator_address,
            maintain_threshold,
            0,
        )
    }

    fun get_user_effective_power_for_validator_for_next_epoch_with_extra_deposit(
        registry: &StakingRegistry,
        user: address,
        validator_address: address,
        maintain_threshold: u64,
        extra_deposit_octas: u64,
    ): u64 {
        if (!registry.users.contains(user)) {
            return 0
        };

        let info = registry.users.borrow(user);
        if (info.delegated_to != validator_address) {
            return 0
        };

        let committed_power = poc_power_store::get_user_committed_power_for_next_epoch(user);
        if (committed_power == 0) {
            return 0
        };
        let deposit_octas = coin::value(&info.deposit) + extra_deposit_octas;
        let deposit_cover = deposit_octas / registry.config.octas_per_power;
        let effective_power = math64::min(committed_power, deposit_cover);
        if (effective_power < maintain_threshold) {
            0
        } else {
            effective_power
        }
    }

    fun copy_addresses(addresses: &vector<address>): vector<address> {
        let copied = vector[];
        addresses.for_each_ref(|addr| copied.push_back(*addr));
        copied
    }

    fun build_validator_view(
        registry: &StakingRegistry,
        validator_address: address,
    ): (address, address, u64, u64, u64, u64, u64) {
        if (!registry.validators.contains(validator_address)) {
            return empty_validator_view(validator_address)
        };
        let pool = registry.validators.borrow(validator_address);
        (
            validator_address,
            pool.owner_address,
            pool.commission_bps,
            pool.status,
            pool.delegator_list.length(),
            get_user_effective_power_for_validator(
                registry,
                pool.owner_address,
                validator_address,
            ),
            calculate_validator_total_power(registry, pool, validator_address),
        )
    }

    fun empty_validator_view(
        validator_address: address,
    ): (address, address, u64, u64, u64, u64, u64) {
        (validator_address, @0x0, 0, VALIDATOR_STATUS_INACTIVE, 0, 0, 0)
    }

    fun build_user_stake_view(
        registry: &StakingRegistry,
        user: address,
    ): (address, u64, address, u64, u64, u64) {
        if (!registry.users.contains(user)) {
            return empty_user_stake_view(user)
        };
        let info = registry.users.borrow(user);
        (
            user,
            coin::value(&info.deposit),
            info.delegated_to,
            info.cooldown_until_secs,
            poc_power_store::get_user_committed_power(user),
            get_active_effective_power(registry, user),
        )
    }

    fun empty_user_stake_view(user: address): (address, u64, address, u64, u64, u64) {
        (user, 0, @0x0, 0, poc_power_store::get_user_committed_power(user), 0)
    }

    fun build_delegator_view(
        registry: &StakingRegistry,
        delegator: address,
        validator_address: address,
    ): (u64, u64, u64) {
        if (!registry.users.contains(delegator)) {
            return (0, poc_power_store::get_user_committed_power(delegator), 0)
        };
        let info = registry.users.borrow(delegator);
        (
            coin::value(&info.deposit),
            poc_power_store::get_user_committed_power(delegator),
            get_user_effective_power_for_validator(
                registry,
                delegator,
                validator_address,
            ),
        )
    }

    fun get_active_effective_power(
        registry: &StakingRegistry,
        user: address,
    ): u64 {
        if (!registry.users.contains(user)) {
            return 0
        };
        let info = registry.users.borrow(user);
        if (info.delegated_to == @0x0 || !registry.validators.contains(info.delegated_to)) {
            return 0
        };
        let pool = registry.validators.borrow(info.delegated_to);
        if (pool.status != VALIDATOR_STATUS_ACTIVE
            && pool.status != VALIDATOR_STATUS_PENDING_INACTIVE) {
            return 0
        };
        calculate_effective_power(info, registry.config.octas_per_power, user)
    }

    fun calculate_validator_total_power(
        registry: &StakingRegistry,
        pool: &ValidatorPool,
        validator_address: address,
    ): u64 {
        let total_power = 0u128;
        pool.delegator_list.for_each_ref(|member| {
            let member_address = *member;
            total_power += (get_user_effective_power_for_validator(
                registry,
                member_address,
                validator_address,
            ) as u128);
        });
        total_power as u64
    }

    fun copy_address_range(
        addresses: &vector<address>,
        offset: u64,
        limit: u64,
    ): vector<address> {
        let copied = vector[];
        let len = addresses.length();
        let i = offset;
        let end = range_end(offset, limit, len);
        while (i < end) {
            copied.push_back(*addresses.borrow(i));
            i += 1;
        };
        copied
    }

    fun range_end(offset: u64, limit: u64, len: u64): u64 {
        if (offset >= len || limit == 0) {
            return offset
        };
        let remaining = len - offset;
        if (limit >= remaining) {
            len
        } else {
            offset + limit
        }
    }

    /// Compute epoch rewards for a validator pool.
    ///
    /// Formula: reward = pool_power * rewards_rate * num_successful_proposals
    ///                   / (rewards_rate_denominator * num_total_proposals)
    ///
    /// All arithmetic is done in u128 to avoid overflow before the final division.
    /// Returns 0 if any of pool_power, num_total_proposals, or rewards_rate is zero.
    fun calculate_rewards_amount(
        pool_power: u64,
        num_successful_proposals: u64,
        num_total_proposals: u64,
        rewards_rate: u64,
        rewards_rate_denominator: u64,
    ): u64 {
        if (pool_power == 0 || num_total_proposals == 0 || rewards_rate == 0) {
            return 0
        };

        let rewards_numerator =
            (pool_power as u128) * (rewards_rate as u128) * (num_successful_proposals as u128);
        let rewards_denominator =
            (rewards_rate_denominator as u128) * (num_total_proposals as u128);
        if (rewards_denominator == 0) {
            0
        } else {
            (rewards_numerator / rewards_denominator) as u64
        }
    }
}
