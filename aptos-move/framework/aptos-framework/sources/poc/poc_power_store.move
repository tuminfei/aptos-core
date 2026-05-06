/// POC Power Store Contract — Maintains the most recent two power versions per user, selecting the effective version based on target period.
///
/// Design Boundaries:
/// - Off-chain service is responsible for computing final power results
/// - On-chain storage only keeps the most recent two versions per user, no longer maintaining a global pending cache
/// - Within the current power period, reads always select the latest version where `effective_period <= current_period`
/// - Mid-period uploads only write to `effective_period = current_period + 1` (future version), not affecting current-period stake/governance/reward reads
/// - Historical users without updates don't need full rewrite at epoch boundaries; reads apply lazy decay based on version and retention
///
/// Architecture Overview:
/// This module serves as the on-chain power registry for the Proof of Contribution (POC) system.
/// Power values represent a user's contribution-based voting weight, computed off-chain from ContributionEvents
/// and uploaded periodically by a trusted operator or framework governance. The two-version sliding window design ensures:
/// 1. Current epoch reads remain stable even when next-period data is being staged
/// 2. Smooth transitions at period boundaries without requiring atomic global updates
/// 3. Automatic decay for inactive users via retention_bps_per_period
///
/// Key Concepts:
/// - Power Period: A configurable number of on-chain epochs (default 60). Power values are updated once per period.
///   Period advancement is driven by an epoch countdown, so changing the configured period length
///   only affects future periods and never reinterprets historical epochs.
/// - Effective Period: The period from which a power version becomes active. Versions with effective_period > current_period are "staged" for future use.
/// - Retention: A decay factor (in basis points) applied per period to power values that haven't been refreshed.
///   Default 9950 bps (99.5%) means power decays by 0.5% per period if not updated.
///
/// Lifecycle Example:
/// 1. Genesis: operator uploads initial power for validators at period 0
/// 2. Period 0 (epochs 1-60): reads return period-0 power
/// 3. During period 0: operator stages period-1 power (effective_period=1)
/// 4. Epoch 61 starts → period transitions to 1 → reads now return period-1 power
/// 5. If a user's power wasn't updated for period 1, their period-0 value is read with 1-period decay applied
module aptos_framework::poc_power_store {
    use std::error;
    use std::signer;

    use aptos_std::table;
    use aptos_std::table::Table;

    use aptos_framework::event;
    use aptos_framework::system_addresses;

    friend aptos_framework::genesis;
    friend aptos_framework::stake;
    friend aptos_framework::staking_registry;

    // Basis points denominator: 10000 bps = 100%
    const BPS_DENOMINATOR: u64 = 10000;
    // Default retention: 9995/10000 = 99.95% power retained per period (0.05% decay per period)
    const DEFAULT_RETENTION_BPS_PER_PERIOD: u64 = 9995;
    // Default power period: 60 epochs per power period
    const DEFAULT_POWER_PERIOD_IN_EPOCHS: u64 = 60;

    // ========== Error Codes ==========

    /// PowerStore resource has not been initialized yet
    const ESTORE_NOT_INITIALIZED: u64 = 1;
    /// Caller is not the designated operator
    const ENOT_OPERATOR: u64 = 2;
    /// `users` and `powers` vectors have different lengths in a batch update
    const EINVALID_BATCH_LENGTH: u64 = 3;
    /// retention_bps_per_period is out of valid range (must be > 0 and <= 10000)
    const EINVALID_RETENTION_BPS: u64 = 4;
    /// power_period_in_epochs must be > 0
    const EINVALID_POWER_PERIOD: u64 = 5;
    /// target_period must equal current_period + 1; staging further ahead is not allowed
    const EINVALID_TARGET_PERIOD: u64 = 6;
    /// Genesis committed snapshots can only be written during the initialization phase (last_epoch == 0 && current_period == 0)
    const EGENESIS_COMMIT_ONLY: u64 = 7;

    // ========== Core Resources ==========

    /// Global power store, stored under @aptos_framework.
    ///
    /// Invariants:
    /// - Only `operator` or @aptos_framework may call `stage_batch_update`
    /// - Each user has at most two PowerVersion slots (older + newer)
    struct PowerStore has key {
        /// The single trusted address allowed to upload power updates
        operator: address,
        /// Per-user storage: address → two-slot power version window
        users: Table<address, UserPowerInfo>,
        /// Decay factor applied per period to stale power values (in basis points, e.g. 9950 = 99.5%)
        retention_bps_per_period: u64,
    }

    /// Global power-period clock, stored under @aptos_framework.
    ///
    /// Invariants:
    /// - `current_period` only advances forward, never backward
    /// - `last_epoch` is incremented once per on-chain epoch via `commit_next_period_if_boundary`
    /// - `current_period` advances by at most one per committed epoch
    struct PeriodClock has key {
        /// Number of on-chain epochs used when starting the next power period
        power_period_in_epochs: u64,
        /// Monotonically increasing count of epochs that have been committed
        last_epoch: u64,
        /// The current power period index
        current_period: u64,
        /// Number of epoch transitions remaining before the next power period starts
        epochs_until_next_power_period: u64,
    }

    /// A single versioned power snapshot for a user.
    /// `effective_period` is the first period in which this value becomes the active reading.
    struct PowerVersion has copy, drop, store {
        effective_period: u64,
        power: u64,
    }

    /// Two-slot sliding window of power versions per user.
    ///
    /// Invariant: older.effective_period <= newer.effective_period (enforced by normalize_user_power_info).
    ///
    /// Why two slots?
    /// - When the operator stages period P+1 data while the chain is still in period P,
    ///   we must keep the period-P value so current reads remain stable.
    /// - At the period boundary, current_period advances to P+1 and reads switch to the newer slot.
    /// - The older slot is then free to be overwritten by the next staging call.
    struct UserPowerInfo has copy, drop, store {
        older: PowerVersion,
        newer: PowerVersion,
    }

    // ========== Events ==========

    #[event]
    /// Emitted when the operator address is changed via `set_operator`.
    struct OperatorChangedEvent has drop, store {
        old_operator: address,
        new_operator: address,
    }

    #[event]
    /// Emitted for each user entry written by `stage_batch_update`.
    /// Allows off-chain indexers to track exactly what was staged and when.
    struct PowerUpdateStagedEvent has drop, store {
        /// The period the caller requested to stage for (must equal current_period + 1)
        target_period: u64,
        /// The period at which this power value becomes effective (equals target_period)
        effective_period: u64,
        user: address,
        power: u64,
    }

    #[event]
    /// Emitted when `commit_next_period_if_boundary` advances current_period.
    /// Off-chain services use this to know when a new period has started on-chain.
    struct PowerPeriodCommittedEvent has drop, store {
        previous_period: u64,
        current_period: u64,
    }

    // ========== Initialization ==========

    friend fun initialize(aptos_framework: &signer, operator: address) {
        initialize_power_store_internal(
            aptos_framework,
            operator,
            DEFAULT_RETENTION_BPS_PER_PERIOD,
            DEFAULT_POWER_PERIOD_IN_EPOCHS,
        );
    }

    friend fun initialize_with_power_period(
        aptos_framework: &signer,
        operator: address,
        power_period_in_epochs: u64,
    ) {
        initialize_power_store_internal(
            aptos_framework,
            operator,
            DEFAULT_RETENTION_BPS_PER_PERIOD,
            power_period_in_epochs,
        );
    }

    public entry fun initialize_power_store(
        aptos_framework: &signer,
        operator: address,
    ) {
        initialize_power_store_internal(
            aptos_framework,
            operator,
            DEFAULT_RETENTION_BPS_PER_PERIOD,
            DEFAULT_POWER_PERIOD_IN_EPOCHS,
        );
    }

    public entry fun initialize_power_store_with_period(
        aptos_framework: &signer,
        operator: address,
        power_period_in_epochs: u64,
    ) {
        initialize_power_store_internal(
            aptos_framework,
            operator,
            DEFAULT_RETENTION_BPS_PER_PERIOD,
            power_period_in_epochs,
        );
    }

    public entry fun set_retention_bps_per_period(
        aptos_framework: &signer,
        retention_bps_per_period: u64,
    ) acquires PowerStore {
        system_addresses::assert_aptos_framework(aptos_framework);
        assert_store_exists();
        assert_valid_retention_bps(retention_bps_per_period);
        borrow_global_mut<PowerStore>(@aptos_framework).retention_bps_per_period =
            retention_bps_per_period;
    }

    /// Update the power-period length used when the next power period starts.
    ///
    /// The current period's remaining countdown is not recomputed. This prevents a
    /// parameter change from reinterpreting historical epochs and making
    /// `current_period` jump by more than one at the next epoch boundary.
    public entry fun set_power_period_in_epochs(
        aptos_framework: &signer,
        power_period_in_epochs: u64,
    ) acquires PeriodClock {
        system_addresses::assert_aptos_framework(aptos_framework);
        assert_store_exists();
        assert_clock_exists();
        assert_valid_power_period(power_period_in_epochs);
        borrow_global_mut<PeriodClock>(@aptos_framework).power_period_in_epochs =
            power_period_in_epochs;
    }

    public entry fun set_operator(
        aptos_framework: &signer,
        new_operator: address,
    ) acquires PowerStore {
        system_addresses::assert_aptos_framework(aptos_framework);
        assert_store_exists();

        let store = borrow_global_mut<PowerStore>(@aptos_framework);
        let old_operator = store.operator;
        if (old_operator == new_operator) {
            return
        };

        store.operator = new_operator;
        event::emit(OperatorChangedEvent {
            old_operator,
            new_operator,
        });
    }

    // ========== Write-back ==========

    /// Batch-write power versions for the next power period.
    ///
    /// Convention:
    /// - When on-chain current_period = P, the off-chain service uploads results computed from period P-1 data.
    /// - However, those results only take effect starting from period P+1, so this function writes
    ///   `effective_period = current_period + 1` (i.e., target_period).
    ///
    /// Constraints:
    /// - Only the designated `operator` or @aptos_framework may call this.
    /// - `target_period` must equal `current_period + 1`; staging further ahead is not allowed
    ///   to prevent the operator from pre-loading multiple future periods at once.
    /// - `users` and `powers` must have the same length.
    ///
    /// Idempotency: calling this multiple times for the same target_period overwrites the previous value.
    /// This allows the operator to correct a mistake before the period boundary is crossed.
    public entry fun stage_batch_update(
        operator: &signer,
        target_period: u64,
        users: vector<address>,
        powers: vector<u64>,
    ) acquires PowerStore, PeriodClock {
        assert_store_exists();
        assert_clock_exists();
        assert!(
            users.length() == powers.length(),
            error::invalid_argument(EINVALID_BATCH_LENGTH),
        );

        let clock = borrow_global<PeriodClock>(@aptos_framework);
        let store = borrow_global_mut<PowerStore>(@aptos_framework);
        assert_power_update_authority(store, signer::address_of(operator));
        assert!(
            target_period == clock.current_period + 1,
            error::invalid_argument(EINVALID_TARGET_PERIOD),
        );

        let effective_period = target_period;
        let length = users.length();
        let i = 0;
        while (i < length) {
            let user = *users.borrow(i);
            let power = *powers.borrow(i);
            upsert_power_version(store, user, effective_period, power);
            event::emit(PowerUpdateStagedEvent {
                target_period,
                effective_period,
                user,
                power,
            });
            i += 1;
        };
    }


    /// Genesis / test special case: directly write a committed snapshot at period 0.
    ///
    /// This bypasses the normal staging flow and is only valid when the chain is still at
    /// last_epoch == 0 && current_period == 0 (i.e., during genesis initialization).
    /// Used to seed initial validator power values before the first epoch begins.
    public entry fun set_genesis_committed_power(
        aptos_framework: &signer,
        user: address,
        power: u64,
    ) acquires PowerStore, PeriodClock {
        system_addresses::assert_aptos_framework(aptos_framework);
        assert_store_exists();
        assert_clock_exists();

        let clock = borrow_global<PeriodClock>(@aptos_framework);
        let store = borrow_global_mut<PowerStore>(@aptos_framework);
        assert!(
            clock.last_epoch == 0 && clock.current_period == 0,
            error::invalid_state(EGENESIS_COMMIT_ONLY),
        );
        upsert_power_version(store, user, 0, power);
    }

    /// Advance the local epoch counter on each new on-chain epoch.
    /// If the new epoch is the first epoch of a new power period, advance current_period.
    ///
    /// Called by `stake::on_new_epoch` at every epoch boundary.
    /// This is the only place where `current_period` advances, ensuring all reads
    /// within an epoch see a consistent period value.
    ///
    /// Period boundary rule:
    /// - `epochs_until_next_power_period` is decremented once per committed epoch.
    /// - When it reaches zero, the next committed epoch advances `current_period` by one
    ///   and reloads the countdown from `power_period_in_epochs`.
    ///
    /// Example with power_period_in_epochs = 60:
    ///   first 60 committed epochs   → period 0
    ///   next 60 committed epochs    → period 1
    ///   next 60 committed epochs    → period 2
    friend fun commit_next_period_if_boundary() acquires PeriodClock {
        if (!exists<PeriodClock>(@aptos_framework)) {
            return
        };

        let clock = borrow_global_mut<PeriodClock>(@aptos_framework);
        clock.last_epoch += 1;
        if (clock.epochs_until_next_power_period == 0) {
            let previous_period = clock.current_period;
            let target_period = previous_period + 1;
            clock.current_period = target_period;
            clock.epochs_until_next_power_period = clock.power_period_in_epochs;
            event::emit(PowerPeriodCommittedEvent {
                previous_period,
                current_period: target_period,
            });
        };

        clock.epochs_until_next_power_period -= 1;
    }

    // ========== Query Interface ==========

    #[view]
    public fun get_user_power(user: address): u64 acquires PowerStore, PeriodClock {
        get_user_committed_power(user)
    }

    #[view]
    public fun get_user_committed_power(user: address): u64 acquires PowerStore, PeriodClock {
        if (!exists<PowerStore>(@aptos_framework) || !exists<PeriodClock>(@aptos_framework)) {
            return 0
        };
        let clock = borrow_global<PeriodClock>(@aptos_framework);
        let store = borrow_global<PowerStore>(@aptos_framework);
        get_user_power_for_period_internal(store, user, clock.current_period)
    }

    #[view]
    public fun get_user_committed_power_for_next_epoch(
        user: address,
    ): u64 acquires PowerStore, PeriodClock {
        if (!exists<PowerStore>(@aptos_framework) || !exists<PeriodClock>(@aptos_framework)) {
            return 0
        };

        let store = borrow_global<PowerStore>(@aptos_framework);
        let clock = borrow_global<PeriodClock>(@aptos_framework);
        let target_period = if (clock.epochs_until_next_power_period == 0) {
                clock.current_period + 1
            } else {
                clock.current_period
            };
        get_user_power_for_period_internal(store, user, target_period)
    }

    #[view]
    public fun get_user_power_for_period(
        user: address,
        target_period: u64,
    ): u64 acquires PowerStore {
        if (!exists<PowerStore>(@aptos_framework)) {
            return 0
        };
        let store = borrow_global<PowerStore>(@aptos_framework);
        get_user_power_for_period_internal(store, user, target_period)
    }

    #[view]
    public fun get_user_committed_powers(
        users: vector<address>,
    ): vector<u64> acquires PowerStore, PeriodClock {
        let powers = vector[];
        if (!exists<PowerStore>(@aptos_framework) || !exists<PeriodClock>(@aptos_framework)) {
            return powers
        };
        let clock = borrow_global<PeriodClock>(@aptos_framework);
        let store = borrow_global<PowerStore>(@aptos_framework);
        let len = users.length();
        let i = 0;
        while (i < len) {
            powers.push_back(get_user_power_for_period_internal(
                store,
                *users.borrow(i),
                clock.current_period,
            ));
            i += 1;
        };
        powers
    }

    #[view]
    public fun get_user_powers_for_period(
        users: vector<address>,
        target_period: u64,
    ): vector<u64> acquires PowerStore {
        let powers = vector[];
        if (!exists<PowerStore>(@aptos_framework)) {
            return powers
        };
        let store = borrow_global<PowerStore>(@aptos_framework);
        let len = users.length();
        let i = 0;
        while (i < len) {
            powers.push_back(get_user_power_for_period_internal(
                store,
                *users.borrow(i),
                target_period,
            ));
            i += 1;
        };
        powers
    }

    #[view]
    public fun get_user_power_version(
        user: address,
    ): (u64, u64, u64, u64, u64) acquires PowerStore, PeriodClock {
        if (!exists<PowerStore>(@aptos_framework) || !exists<PeriodClock>(@aptos_framework)) {
            return (0, 0, 0, 0, 0)
        };
        let clock = borrow_global<PeriodClock>(@aptos_framework);
        let store = borrow_global<PowerStore>(@aptos_framework);
        build_user_power_version(store, user, clock.current_period)
    }

    #[view]
    public fun get_user_power_versions_by_addresses(
        users: vector<address>,
    ): (
        vector<address>,
        vector<u64>,
        vector<u64>,
        vector<u64>,
        vector<u64>,
        vector<u64>,
    ) acquires PowerStore, PeriodClock {
        let returned_users = vector[];
        let older_effective_periods = vector[];
        let older_powers = vector[];
        let newer_effective_periods = vector[];
        let newer_powers = vector[];
        let committed_powers = vector[];
        if (!exists<PowerStore>(@aptos_framework) || !exists<PeriodClock>(@aptos_framework)) {
            return (
                returned_users,
                older_effective_periods,
                older_powers,
                newer_effective_periods,
                newer_powers,
                committed_powers,
            )
        };
        let clock = borrow_global<PeriodClock>(@aptos_framework);
        let store = borrow_global<PowerStore>(@aptos_framework);
        let len = users.length();
        let i = 0;
        while (i < len) {
            let user = *users.borrow(i);
            let (
                older_effective_period,
                older_power,
                newer_effective_period,
                newer_power,
                committed_power,
            ) = build_user_power_version(store, user, clock.current_period);
            returned_users.push_back(user);
            older_effective_periods.push_back(older_effective_period);
            older_powers.push_back(older_power);
            newer_effective_periods.push_back(newer_effective_period);
            newer_powers.push_back(newer_power);
            committed_powers.push_back(committed_power);
            i += 1;
        };
        (
            returned_users,
            older_effective_periods,
            older_powers,
            newer_effective_periods,
            newer_powers,
            committed_powers,
        )
    }

    #[view]
    public fun get_user_decayed_power(user: address): u64 acquires PowerStore, PeriodClock {
        get_user_committed_power(user)
    }

    #[view]
    public fun get_operator(): address acquires PowerStore {
        if (!exists<PowerStore>(@aptos_framework)) {
            return @0x0
        };
        borrow_global<PowerStore>(@aptos_framework).operator
    }

    #[view]
    public fun get_current_period(): u64 acquires PeriodClock {
        if (!exists<PeriodClock>(@aptos_framework)) {
            0
        } else {
            borrow_global<PeriodClock>(@aptos_framework).current_period
        }
    }

    #[view]
    public fun get_power_period_in_epochs(): u64 acquires PeriodClock {
        if (!exists<PeriodClock>(@aptos_framework)) {
            0
        } else {
            borrow_global<PeriodClock>(@aptos_framework).power_period_in_epochs
        }
    }

    #[view]
    public fun get_retention_bps_per_period(): u64 acquires PowerStore {
        if (!exists<PowerStore>(@aptos_framework)) {
            0
        } else {
            borrow_global<PowerStore>(@aptos_framework).retention_bps_per_period
        }
    }

    // ========== Internal Helpers ==========

    fun initialize_power_store_internal(
        aptos_framework: &signer,
        operator: address,
        retention_bps_per_period: u64,
        power_period_in_epochs: u64,
    ) {
        system_addresses::assert_aptos_framework(aptos_framework);
        assert_valid_retention_bps(retention_bps_per_period);
        assert_valid_power_period(power_period_in_epochs);
        move_to(aptos_framework, PowerStore {
            operator,
            users: table::new(),
            retention_bps_per_period,
        });
        move_to(aptos_framework, PeriodClock {
            power_period_in_epochs,
            last_epoch: 0,
            current_period: 0,
            epochs_until_next_power_period: power_period_in_epochs,
        });
    }

    fun assert_store_exists() {
        assert!(
            exists<PowerStore>(@aptos_framework),
            error::not_found(ESTORE_NOT_INITIALIZED),
        );
    }

    fun assert_clock_exists() {
        assert!(
            exists<PeriodClock>(@aptos_framework),
            error::not_found(ESTORE_NOT_INITIALIZED),
        );
    }

    fun assert_power_update_authority(store: &PowerStore, caller: address) {
        assert!(
            store.operator == caller || system_addresses::is_aptos_framework_address(caller),
            error::permission_denied(ENOT_OPERATOR),
        );
    }

    fun assert_valid_retention_bps(retention_bps_per_period: u64) {
        assert!(
            retention_bps_per_period > 0
                && retention_bps_per_period <= BPS_DENOMINATOR,
            error::invalid_argument(EINVALID_RETENTION_BPS),
        );
    }

    fun assert_valid_power_period(power_period_in_epochs: u64) {
        assert!(
            power_period_in_epochs > 0,
            error::invalid_argument(EINVALID_POWER_PERIOD),
        );
    }

    /// Insert or update a user's power version in the two-slot window.
    ///
    /// Slot selection logic:
    /// 1. User not yet in table → create a new entry with `newer` = this version (skip if power == 0)
    /// 2. `effective_period` matches `newer` → overwrite `newer.power` in-place (idempotent update)
    /// 3. `effective_period` matches `older` → overwrite `older.power` in-place (idempotent update)
    /// 4. Neither slot matches → shift: `older = newer`, `newer = new version`
    ///    (the oldest slot is evicted; only the two most recent periods are retained)
    ///
    /// After any write, `normalize_user_power_info` ensures older.effective_period <= newer.effective_period.
    fun upsert_power_version(
        store: &mut PowerStore,
        user: address,
        effective_period: u64,
        power: u64,
    ) {
        if (!store.users.contains(user)) {
            if (power == 0) {
                return
            };
            store.users.add(user, UserPowerInfo {
                older: empty_power_version(),
                newer: PowerVersion {
                    effective_period,
                    power,
                },
            });
            return
        };

        let info = store.users.borrow_mut(user);
        if (info.newer.effective_period == effective_period) {
            info.newer.power = power;
            normalize_user_power_info(info);
            return
        };

        if (info.older.effective_period == effective_period) {
            info.older.power = power;
            normalize_user_power_info(info);
            return
        };

        // Evict the oldest slot and write the new version into `newer`
        info.older = info.newer;
        info.newer = PowerVersion {
            effective_period,
            power,
        };
        normalize_user_power_info(info);
    }

    /// Ensure the two slots are ordered: older.effective_period <= newer.effective_period.
    /// Swaps the slots if they are out of order (can happen after an in-place overwrite).
    fun normalize_user_power_info(info: &mut UserPowerInfo) {
        if (info.older.effective_period > info.newer.effective_period) {
            let swapped = info.older;
            info.older = info.newer;
            info.newer = swapped;
        };
    }

    /// Core read path: find the best power value for a given target_period and apply decay.
    ///
    /// Steps:
    /// 1. Select the effective version: the slot with the highest effective_period that is <= target_period
    /// 2. Compute periods_elapsed = target_period - base_period
    /// 3. Apply retention decay: power * (retention_bps ^ periods_elapsed) / (BPS_DENOMINATOR ^ periods_elapsed)
    ///
    /// Returns 0 if the user has no record or no version is effective for target_period.
    fun get_user_power_for_period_internal(
        store: &PowerStore,
        user: address,
        target_period: u64,
    ): u64 {
        if (!store.users.contains(user)) {
            return 0
        };

        let info = store.users.borrow(user);
        let (base_period, base_power) = select_effective_version(info, target_period);
        if (base_power == 0) {
            return 0
        };
        apply_retention(
            base_power,
            target_period - base_period,
            store.retention_bps_per_period,
        )
    }

    fun build_user_power_version(
        store: &PowerStore,
        user: address,
        current_period: u64,
    ): (u64, u64, u64, u64, u64) {
        if (!store.users.contains(user)) {
            return (0, 0, 0, 0, 0)
        };
        let info = store.users.borrow(user);
        (
            info.older.effective_period,
            info.older.power,
            info.newer.effective_period,
            info.newer.power,
            get_user_power_for_period_internal(
                store,
                user,
                current_period,
            ),
        )
    }

    /// Select the most recent version whose effective_period <= target_period.
    /// Prefers `newer` over `older` when both qualify (newer has higher effective_period).
    /// Returns (0, 0) if neither slot qualifies.
    fun select_effective_version(
        info: &UserPowerInfo,
        target_period: u64,
    ): (u64, u64) {
        let newer = info.newer;
        if (newer.effective_period <= target_period && has_power_version(newer)) {
            return (newer.effective_period, newer.power)
        };

        let older = info.older;
        if (older.effective_period <= target_period && has_power_version(older)) {
            return (older.effective_period, older.power)
        };

        (0, 0)
    }

    /// A PowerVersion is considered "present" if either field is non-zero.
    /// The zero value (effective_period=0, power=0) is used as the empty sentinel.
    /// Note: a version at period 0 with power > 0 is valid (genesis snapshot).
    fun has_power_version(version: PowerVersion): bool {
        version.effective_period > 0 || version.power > 0
    }

    /// Apply per-period retention decay to a base power value.
    ///
    /// Formula: retained = power * (retention_bps / BPS_DENOMINATOR) ^ periods_elapsed
    /// Computed iteratively to avoid u64 overflow in intermediate exponentiation.
    /// Uses u128 for each multiplication step to prevent overflow before the division.
    ///
    /// Example: power=1000, retention_bps=9950, periods_elapsed=2
    ///   step 1: 1000 * 9950 / 10000 = 995
    ///   step 2: 995 * 9950 / 10000 = 990 (truncated)
    fun apply_retention(
        power: u64,
        periods_elapsed: u64,
        retention_bps_per_period: u64,
    ): u64 {
        if (power == 0 || periods_elapsed == 0) {
            return power
        };

        let retained_power = power;
        let i = 0;
        while (i < periods_elapsed) {
            if (retained_power == 0) {
                return 0
            };
            retained_power =
                (((retained_power as u128) * (retention_bps_per_period as u128))
                    / (BPS_DENOMINATOR as u128)) as u64;
            i += 1;
        };
        retained_power
    }

    /// Returns the zero-value sentinel PowerVersion used to initialize empty slots.
    fun empty_power_version(): PowerVersion {
        PowerVersion {
            effective_period: 0,
            power: 0,
        }
    }

    // ========== Tests ==========

    #[test(framework = @aptos_framework, operator = @0xA, user1 = @0xB, user2 = @0xC)]
    public entry fun test_stage_update_commits_on_boundary(
        framework: signer,
        operator: signer,
        user1: signer,
        user2: signer,
    ) acquires PowerStore, PeriodClock {
        initialize_with_power_period(&framework, signer::address_of(&operator), 1);
        set_genesis_committed_power(&framework, signer::address_of(&user1), 100);

        stage_batch_update(
            &operator,
            1,
            vector[signer::address_of(&user1), signer::address_of(&user2)],
            vector[90u64, 30u64],
        );

        assert!(get_current_period() == 0, 0);
        assert!(get_user_committed_power(signer::address_of(&user1)) == 100, 1);
        assert!(get_user_committed_power(signer::address_of(&user2)) == 0, 2);
        assert!(get_user_power_for_period(signer::address_of(&user1), 1) == 90, 3);
        assert!(get_user_power_for_period(signer::address_of(&user2), 1) == 30, 4);

        commit_next_period_if_boundary();
        assert!(get_current_period() == 0, 5);
        assert!(get_user_committed_power(signer::address_of(&user1)) == 100, 6);

        commit_next_period_if_boundary();
        assert!(get_current_period() == 1, 7);
        assert!(get_user_committed_power(signer::address_of(&user1)) == 90, 8);
        assert!(get_user_committed_power(signer::address_of(&user2)) == 30, 9);
    }

    #[test(framework = @aptos_framework, operator = @0xA, user1 = @0xB)]
    public entry fun test_retention_carries_forward_without_pending_updates(
        framework: signer,
        operator: signer,
        user1: signer,
    ) acquires PowerStore, PeriodClock {
        initialize_with_power_period(&framework, signer::address_of(&operator), 1);
        set_genesis_committed_power(&framework, signer::address_of(&user1), 100);

        commit_next_period_if_boundary();
        commit_next_period_if_boundary();
        assert!(get_current_period() == 1, 0);
        assert!(get_user_committed_power(signer::address_of(&user1)) == 99, 1);

        commit_next_period_if_boundary();
        assert!(get_current_period() == 2, 2);
        assert!(get_user_committed_power(signer::address_of(&user1)) == 98, 3);
    }

    #[test(framework = @aptos_framework, operator = @0xA, user1 = @0xB)]
    public entry fun test_stage_update_overwrites_pending_value(
        framework: signer,
        operator: signer,
        user1: signer,
    ) acquires PowerStore, PeriodClock {
        initialize_with_power_period(&framework, signer::address_of(&operator), 1);
        set_genesis_committed_power(&framework, signer::address_of(&user1), 100);

        stage_batch_update(
            &operator,
            1,
            vector[signer::address_of(&user1)],
            vector[70u64],
        );
        stage_batch_update(
            &operator,
            1,
            vector[signer::address_of(&user1)],
            vector[55u64],
        );

        commit_next_period_if_boundary();
        commit_next_period_if_boundary();
        assert!(get_current_period() == 1, 0);
        assert!(get_user_committed_power(signer::address_of(&user1)) == 55, 1);
    }

    #[test(framework = @aptos_framework, operator = @0xA, new_operator = @0xD, user1 = @0xB)]
    public entry fun test_framework_can_stage_after_operator_change(
        framework: signer,
        operator: signer,
        new_operator: signer,
        user1: signer,
    ) acquires PowerStore, PeriodClock {
        initialize_with_power_period(&framework, signer::address_of(&operator), 1);
        set_genesis_committed_power(&framework, signer::address_of(&user1), 100);
        set_operator(&framework, signer::address_of(&new_operator));

        stage_batch_update(
            &framework,
            1,
            vector[signer::address_of(&user1)],
            vector[80u64],
        );

        assert!(get_user_power_for_period(signer::address_of(&user1), 1) == 80, 0);
    }

    #[test(framework = @aptos_framework, operator = @0xA, user1 = @0xB)]
    public entry fun test_stage_update_keeps_current_period_stable_on_long_period(
        framework: signer,
        operator: signer,
        user1: signer,
    ) acquires PowerStore, PeriodClock {
        initialize_with_power_period(&framework, signer::address_of(&operator), 2);
        set_genesis_committed_power(&framework, signer::address_of(&user1), 100);

        // epoch 1 结束后，仍在 period 0
        commit_next_period_if_boundary();
        assert!(get_current_period() == 0, 0);
        assert!(get_user_committed_power(signer::address_of(&user1)) == 100, 1);

        stage_batch_update(
            &operator,
            1,
            vector[signer::address_of(&user1)],
            vector[90u64],
        );

        // 当前 period 读取仍然稳定，下一 period 才看到新值
        assert!(get_user_committed_power(signer::address_of(&user1)) == 100, 2);
        assert!(get_user_power_for_period(signer::address_of(&user1), 1) == 90, 3);

        // epoch 2 结束后，仍在 period 0
        commit_next_period_if_boundary();
        assert!(get_current_period() == 0, 4);
        assert!(get_user_committed_power(signer::address_of(&user1)) == 100, 5);

        // epoch 3 结束后，进入 period 1
        commit_next_period_if_boundary();
        assert!(get_current_period() == 1, 6);
        assert!(get_user_committed_power(signer::address_of(&user1)) == 90, 7);
    }

    #[test(framework = @aptos_framework, operator = @0xA, user1 = @0xB)]
    public entry fun test_zero_power_update_clears_future_period(
        framework: signer,
        operator: signer,
        user1: signer,
    ) acquires PowerStore, PeriodClock {
        initialize_with_power_period(&framework, signer::address_of(&operator), 1);
        set_genesis_committed_power(&framework, signer::address_of(&user1), 100);

        stage_batch_update(
            &operator,
            1,
            vector[signer::address_of(&user1)],
            vector[0u64],
        );

        assert!(get_user_committed_power(signer::address_of(&user1)) == 100, 0);
        assert!(get_user_power_for_period(signer::address_of(&user1), 1) == 0, 1);

        commit_next_period_if_boundary();
        commit_next_period_if_boundary();
        assert!(get_current_period() == 1, 2);
        assert!(get_user_committed_power(signer::address_of(&user1)) == 0, 3);
    }

    #[test(framework = @aptos_framework, operator = @0xA, user1 = @0xB)]
    public entry fun test_shortening_power_period_does_not_jump_current_period(
        framework: signer,
        operator: signer,
        user1: signer,
    ) acquires PowerStore, PeriodClock {
        initialize_with_power_period(&framework, signer::address_of(&operator), 3);
        set_genesis_committed_power(&framework, signer::address_of(&user1), 100);

        stage_batch_update(
            &operator,
            1,
            vector[signer::address_of(&user1)],
            vector[90u64],
        );

        commit_next_period_if_boundary();
        commit_next_period_if_boundary();
        assert!(get_current_period() == 0, 0);

        set_power_period_in_epochs(&framework, 1);

        commit_next_period_if_boundary();
        assert!(get_current_period() == 0, 1);
        assert!(get_user_committed_power(signer::address_of(&user1)) == 100, 2);
        assert!(get_user_committed_power_for_next_epoch(signer::address_of(&user1)) == 90, 3);

        commit_next_period_if_boundary();
        assert!(get_current_period() == 1, 4);
        assert!(get_user_committed_power(signer::address_of(&user1)) == 90, 5);
    }

    #[test(framework = @aptos_framework, operator = @0xA, user1 = @0xB)]
    public entry fun test_lengthening_power_period_does_not_delay_ready_boundary(
        framework: signer,
        operator: signer,
        user1: signer,
    ) acquires PowerStore, PeriodClock {
        initialize_with_power_period(&framework, signer::address_of(&operator), 1);
        set_genesis_committed_power(&framework, signer::address_of(&user1), 100);

        stage_batch_update(
            &operator,
            1,
            vector[signer::address_of(&user1)],
            vector[90u64],
        );

        commit_next_period_if_boundary();
        assert!(get_current_period() == 0, 0);
        assert!(get_user_committed_power_for_next_epoch(signer::address_of(&user1)) == 90, 1);

        set_power_period_in_epochs(&framework, 60);

        commit_next_period_if_boundary();
        assert!(get_current_period() == 1, 2);
        assert!(get_user_committed_power(signer::address_of(&user1)) == 90, 3);
    }
}
