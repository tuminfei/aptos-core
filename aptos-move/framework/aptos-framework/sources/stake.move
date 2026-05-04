///
/// Validator lifecycle:
/// 1. Prepare validator metadata by calling `stake::initialize_validator`.
/// 2. Manage principal and delegation through `staking_registry`.
/// 3. Call `stake::join_validator_set` to enter the validator set. Changes are effective in the next epoch.
/// 4. Rewards and transaction fees are accounted in `staking_registry`; `stake.move` only maintains validator-set state.
/// 5. Operators may still rotate consensus keys and network/fullnode addresses through this module.
/// 6. Owners may switch operators through `stake::set_operator`.
///
/// ## Architecture Overview
///
/// `stake.move` is the validator-set manager for the Topo chain. It owns the canonical `ValidatorSet`
/// resource and orchestrates the epoch transition (`on_new_epoch`). Economic accounting (deposits,
/// rewards, fees, power) has been fully delegated to `staking_registry` and `poc_power_store`.
///
/// ## Separation of Concerns
///
/// | Concern                        | Module              |
/// |--------------------------------|---------------------|
/// | Validator set membership       | stake.move          |
/// | Consensus key / network addr   | stake.move          |
/// | Operator / owner management    | stake.move          |
/// | Deposit escrow & delegation    | staking_registry    |
/// | Reward & fee distribution      | staking_registry    |
/// | POC power versioning & decay   | poc_power_store     |
/// | Contribution event gating      | poc_contribution    |
/// | App identity & whitelist       | poc_registry        |
///
/// ## Epoch Transition (`on_new_epoch`) Flow
///
/// 1. For each active + pending_inactive validator:
///    a. Merge pending_active coins into active (update_stake_pool)
///    b. Distribute transaction fees (staking_registry::distribute_transaction_fees)
///    c. Distribute epoch rewards (staking_registry::distribute_epoch_rewards)
/// 2. Advance the POC power period if at a boundary (poc_power_store::commit_next_period_if_boundary)
/// 3. Force-undelegate users below the maintain threshold across all pools
/// 4. Activate pending_active validators; deactivate pending_inactive validators
/// 5. Recompute voting power for all active validators; drop those below minimum_stake
/// 6. Emergency liveness fallback: if the new active set would be empty, retain the previous set
/// 7. Reset performance counters; renew lockups; rebuild the PendingTransactionFee aggregator map
///
/// ## Voting Power Model
///
/// A validator's voting_power in ValidatorSet = staking_registry::get_validator_total_power(pool_address)
/// = sum of effective_power for all delegators in the pool
/// = sum of min(poc_power_i, deposit_i * 1,000,000 / octas_per_million_power) for each delegator i
module aptos_framework::stake {
    use std::error;
    use std::features;
    use std::option::{Self, Option};
    use std::signer;
    use std::vector;
    use aptos_std::bls12381;
    use aptos_std::big_ordered_map::{Self, BigOrderedMap};
    use aptos_std::simple_map::{Self, SimpleMap};
    use aptos_framework::aggregator_v2::{Self, Aggregator};
    use aptos_framework::topo_coin::TopoCoin;
    use aptos_framework::account;
    use aptos_framework::coin::{Self, Coin, MintCapability};
    use aptos_framework::event;
    use aptos_framework::poc_power_store;
    use aptos_framework::timestamp;
    use aptos_framework::system_addresses;
    use aptos_framework::staking_registry;
    use aptos_framework::staking_config::{Self, StakingConfig, StakingRewardsConfig};
    use aptos_framework::validator_consensus_info::ValidatorConsensusInfo;
    use aptos_framework::chain_status;
    use aptos_framework::permissioned_signer;

    friend aptos_framework::block;
    friend aptos_framework::genesis;
    friend aptos_framework::reconfiguration;
    friend aptos_framework::reconfiguration_with_dkg;
    friend aptos_framework::transaction_fee;

    /// Validator Config not published.
    const EVALIDATOR_CONFIG: u64 = 1;
    /// Not enough stake to join validator set.
    const ESTAKE_TOO_LOW: u64 = 2;
    /// Too much stake to join validator set.
    const ESTAKE_TOO_HIGH: u64 = 3;
    /// Account is already a validator or pending validator.
    const EALREADY_ACTIVE_VALIDATOR: u64 = 4;
    /// Account is not a validator.
    const ENOT_VALIDATOR: u64 = 5;
    /// Can't remove last validator.
    const ELAST_VALIDATOR: u64 = 6;
    /// Total stake exceeds maximum allowed.
    const ESTAKE_EXCEEDS_MAX: u64 = 7;
    /// Account is already registered as a validator candidate.
    const EALREADY_REGISTERED: u64 = 8;
    /// Account does not have the right operator capability.
    const ENOT_OPERATOR: u64 = 9;
    /// Validators cannot join or leave post genesis on this test network.
    const ENO_POST_GENESIS_VALIDATOR_SET_CHANGE_ALLOWED: u64 = 10;
    /// Invalid consensus public key
    const EINVALID_PUBLIC_KEY: u64 = 11;
    /// Validator set exceeds the limit
    const EVALIDATOR_SET_TOO_LARGE: u64 = 12;
    /// Voting power increase has exceeded the limit for this current epoch.
    const EVOTING_POWER_INCREASE_EXCEEDS_LIMIT: u64 = 13;
    /// Stake pool does not exist at the provided pool address.
    const ESTAKE_POOL_DOES_NOT_EXIST: u64 = 14;
    /// Owner capability does not exist at the provided account.
    const EOWNER_CAP_NOT_FOUND: u64 = 15;
    /// An account cannot own more than one owner capability.
    const EOWNER_CAP_ALREADY_EXISTS: u64 = 16;
    /// Validator is not defined in the ACL of entities allowed to be validators
    const EINELIGIBLE_VALIDATOR: u64 = 17;
    /// Cannot update stake pool's lockup to earlier than current lockup.
    const EINVALID_LOCKUP: u64 = 18;
    /// Validator set change temporarily disabled because of in-progress reconfiguration. Please retry after 1 minute.
    const ERECONFIGURATION_IN_PROGRESS: u64 = 20;
    /// Signer does not have permission to perform stake logic.
    const ENO_STAKE_PERMISSION: u64 = 28;
    /// Transaction fee is not fully distributed at epoch ending.
    const ETRANSACTION_FEE_NOT_FULLY_DISTRIBUTED: u64 = 29;
    /// `initialize_stake_owner` no longer accepts an inline principal deposit.
    const EINITIAL_STAKE_NOT_SUPPORTED: u64 = 30;

    /// Validator status enum. We can switch to proper enum later once Move supports it.
    const VALIDATOR_STATUS_PENDING_ACTIVE: u64 = 1;
    const VALIDATOR_STATUS_ACTIVE: u64 = 2;
    const VALIDATOR_STATUS_PENDING_INACTIVE: u64 = 3;
    const VALIDATOR_STATUS_INACTIVE: u64 = 4;

    /// Limit the maximum size to u16::max, it's the current limit of the bitvec
    /// https://github.com/aptos-labs/aptos-core/blob/main/crates/aptos-bitvec/src/lib.rs#L20
    const MAX_VALIDATOR_SET_SIZE: u64 = 65536;

    /// Limit the maximum value of `rewards_rate` in order to avoid any arithmetic overflow.
    const MAX_REWARDS_RATE: u64 = 1000000;

    const MAX_U64: u128 = 18446744073709551615;

    /// Capability that represents ownership and can be used to control the validator and the associated stake pool.
    /// Having this be separate from the signer for the account that the validator resources are hosted at allows
    /// modules to have control over a validator.
    ///
    /// Holding this capability grants the right to:
    /// - Change the operator address (set_operator / set_operator_with_cap)
    /// - Extend the lockup period (increase_lockup / increase_lockup_with_cap)
    /// - Transfer ownership to another account (extract_owner_cap / deposit_owner_cap)
    struct OwnerCapability has key, store {
        pool_address: address
    }

    /// Per-validator stake pool resource, stored at the validator's address.
    ///
    /// NOTE: In the Topo POC redesign, actual economic balances (deposits, rewards) are managed
    /// by `staking_registry`. The coin buckets here are retained for lockup tracking and
    /// backward-compatible scaffolding only. They do NOT represent the validator's true stake.
    ///
    /// Coin lifecycle within this struct:
    ///   pending_active → active  (at epoch boundary, via update_stake_pool)
    ///   active → pending_inactive (when leave_validator_set is called)
    ///   pending_inactive → inactive (at epoch boundary, if lockup has expired)
    struct StakePool has key {
        // Active stake (kept for lockup tracking; economic value is in staking_registry)
        active: Coin<TopoCoin>,
        // Inactive stake that can be withdrawn (post-lockup)
        inactive: Coin<TopoCoin>,
        // Stake pending activation in the next epoch
        pending_active: Coin<TopoCoin>,
        // Stake pending deactivation in the next epoch
        pending_inactive: Coin<TopoCoin>,
        // Unix timestamp (seconds) until which the stake is locked.
        // Automatically renewed for validators that remain active across epoch boundaries.
        locked_until_secs: u64,
        // The operator address authorized to manage consensus keys and network addresses.
        // Separated from the owner to allow professional node operators to run validators
        // on behalf of token holders without holding the owner's private key.
        operator_address: address
    }

    /// Validator configuration stored at the validator's address.
    /// Contains the BLS12-381 consensus public key and network addresses.
    struct ValidatorConfig has key, copy, store, drop {
        consensus_pubkey: vector<u8>,
        network_addresses: vector<u8>,
        // to make it compatible with previous definition, remove later
        fullnode_addresses: vector<u8>,
        // Index in the active set if the validator corresponding to this stake pool is active.
        // Used to look up performance stats in ValidatorPerformance.validators[validator_index].
        validator_index: u64
    }

    /// Snapshot of a validator's identity and voting power, stored inside ValidatorSet.
    /// Refreshed at each epoch boundary from the live ValidatorConfig and staking_registry power.
    struct ValidatorInfo has copy, store, drop {
        addr: address,
        voting_power: u64,
        config: ValidatorConfig
    }

    /// The canonical validator set, stored at @aptos_framework.
    ///
    /// State machine:
    ///   join_validator_set  → pending_active
    ///   on_new_epoch        → pending_active becomes active (if power >= minimum_stake)
    ///   leave_validator_set → active becomes pending_inactive
    ///   on_new_epoch        → pending_inactive is removed (rewards distributed first)
    ///
    /// total_voting_power and total_joining_power are used to enforce the
    /// voting_power_increase_limit: no single epoch can increase total power by more than
    /// voting_power_increase_limit% of the current total, preventing sudden validator set takeovers.
    struct ValidatorSet has copy, key, drop, store {
        consensus_scheme: u8,
        // Active validators for the current epoch.
        active_validators: vector<ValidatorInfo>,
        // Pending validators to leave in next epoch (still active for rewards/voting).
        pending_inactive: vector<ValidatorInfo>,
        // Pending validators to join in next epoch.
        pending_active: vector<ValidatorInfo>,
        // Current total voting power (sum of all active + pending_inactive validators).
        total_voting_power: u128,
        // Total voting power of validators waiting to join in the next epoch.
        // Used to enforce the per-epoch voting power increase limit.
        total_joining_power: u128
    }

    /// Per-epoch transaction fee accumulator, indexed by validator_index.
    ///
    /// The VM calls `record_fee` during block execution to credit each validator's share
    /// of transaction fees. At epoch end, `collect_transaction_fee_for_validator` drains
    /// each entry and passes the amount to `staking_registry::distribute_transaction_fees`.
    ///
    /// Uses `BigOrderedMap<u64, Aggregator<u64>>` so that concurrent transactions can
    /// increment fee counters without write conflicts (aggregators are conflict-free).
    struct PendingTransactionFee has key, store {
        pending_fee_by_validator: BigOrderedMap<u64, Aggregator<u64>>
    }

    /// Optional cap on how many octas of transaction fees a single validator pool can
    /// receive per epoch. Prevents a single high-traffic validator from accumulating
    /// disproportionate fees relative to its staking contribution.
    enum TransactionFeeConfig has drop, key, store {
        V0 {
            max_fee_octa_allowed_per_epoch_per_pool: u64
        }
    }

    #[event]
    struct DistributeTransactionFee has drop, store {
        pool_address: address,
        fee_amount: u64
    }

    /// TopoCoin capabilities, set during genesis and stored in @CoreResource account.
    /// This allows the Stake module to mint rewards to stakers.
    struct TopoCoinCapabilities has key {
        mint_cap: MintCapability<TopoCoin>
    }

    struct IndividualValidatorPerformance has store, drop {
        successful_proposals: u64,
        failed_proposals: u64
    }

    struct ValidatorPerformance has key {
        validators: vector<IndividualValidatorPerformance>
    }

    struct StakeManagementPermission has copy, drop, store {}

    #[event]
    struct SetOperator has drop, store {
        pool_address: address,
        old_operator: address,
        new_operator: address
    }

    #[event]
    struct RotateConsensusKey has drop, store {
        pool_address: address,
        old_consensus_pubkey: vector<u8>,
        new_consensus_pubkey: vector<u8>
    }

    #[event]
    struct UpdateNetworkAndFullnodeAddresses has drop, store {
        pool_address: address,
        old_network_addresses: vector<u8>,
        new_network_addresses: vector<u8>,
        old_fullnode_addresses: vector<u8>,
        new_fullnode_addresses: vector<u8>
    }

    #[event]
    struct IncreaseLockup has drop, store {
        pool_address: address,
        old_locked_until_secs: u64,
        new_locked_until_secs: u64
    }

    #[event]
    struct JoinValidatorSet has drop, store {
        pool_address: address
    }

    #[event]
    struct LeaveValidatorSet has drop, store {
        pool_address: address
    }

    #[event]
    struct ValidatorSetLivenessFallback has drop, store {
        minimum_stake: u64,
        emergency_validator_count: u64,
        total_emergency_voting_power: u128
    }

    /// Permissions
    inline fun check_stake_permission(s: &signer) {
        assert!(
            permissioned_signer::check_permission_exists(s, StakeManagementPermission {}),
            error::permission_denied(ENO_STAKE_PERMISSION)
        );
    }

    /// Grant permission to mutate staking on behalf of the master signer.
    public fun grant_permission(
        master: &signer, permissioned_signer: &signer
    ) {
        permissioned_signer::authorize_unlimited(
            master, permissioned_signer, StakeManagementPermission {}
        )
    }

    #[view]
    /// Return the lockup expiration of the stake pool at `pool_address`.
    /// This will throw an error if there's no stake pool at `pool_address`.
    public fun get_lockup_secs(pool_address: address): u64 acquires StakePool {
        assert_stake_pool_exists(pool_address);
        borrow_global<StakePool>(pool_address).locked_until_secs
    }

    #[view]
    /// Return the remaining lockup of the stake pool at `pool_address`.
    /// This will throw an error if there's no stake pool at `pool_address`.
    public fun get_remaining_lockup_secs(pool_address: address): u64 acquires StakePool {
        assert_stake_pool_exists(pool_address);
        let lockup_time = borrow_global<StakePool>(pool_address).locked_until_secs;
        if (lockup_time <= timestamp::now_seconds()) { 0 }
        else {
            lockup_time - timestamp::now_seconds()
        }
    }

    #[view]
    /// Return the different stake amounts for `pool_address` (whether the validator is active or not).
    /// The returned amounts are for (active, inactive, pending_active, pending_inactive) stake respectively.
    public fun get_stake(pool_address: address): (u64, u64, u64, u64) acquires StakePool {
        assert_stake_pool_exists(pool_address);
        let stake_pool = borrow_global<StakePool>(pool_address);
        (
            coin::value(&stake_pool.active),
            coin::value(&stake_pool.inactive),
            coin::value(&stake_pool.pending_active),
            coin::value(&stake_pool.pending_inactive)
        )
    }

    #[view]
    /// Returns the validator's state.
    public fun get_validator_state(pool_address: address): u64 acquires ValidatorSet {
        let validator_set = borrow_global<ValidatorSet>(@aptos_framework);
        if (find_validator(&validator_set.pending_active, pool_address).is_some()) {
            VALIDATOR_STATUS_PENDING_ACTIVE
        } else if (find_validator(&validator_set.active_validators, pool_address).is_some()) {
            VALIDATOR_STATUS_ACTIVE
        } else if (find_validator(&validator_set.pending_inactive, pool_address).is_some()) {
            VALIDATOR_STATUS_PENDING_INACTIVE
        } else {
            VALIDATOR_STATUS_INACTIVE
        }
    }

    #[view]
    /// Return the voting power of the validator in the current epoch.
    /// This is the validator's total effective power in staking_registry.
    public fun get_current_epoch_voting_power(
        pool_address: address
    ): u64 acquires ValidatorSet {
        assert_stake_pool_exists(pool_address);
        let validator_state = get_validator_state(pool_address);
        // Both active and pending inactive validators can still vote in the current epoch.
        if (validator_state == VALIDATOR_STATUS_ACTIVE
            || validator_state == VALIDATOR_STATUS_PENDING_INACTIVE) {
            let (_, maximum_stake) =
                staking_config::get_required_stake(&staking_config::get());
            min_u64(staking_registry::get_validator_total_power(pool_address), maximum_stake)
        } else { 0 }
    }

    #[view]
    /// Return the operator of the validator at `pool_address`.
    public fun get_operator(pool_address: address): address acquires StakePool {
        assert_stake_pool_exists(pool_address);
        borrow_global<StakePool>(pool_address).operator_address
    }

    /// Return the pool address in `owner_cap`.
    public fun get_owned_pool_address(owner_cap: &OwnerCapability): address {
        owner_cap.pool_address
    }

    #[view]
    /// Return the validator index for `pool_address`.
    public fun get_validator_index(pool_address: address): u64 acquires ValidatorConfig {
        assert_stake_pool_exists(pool_address);
        borrow_global<ValidatorConfig>(pool_address).validator_index
    }

    #[view]
    /// Return the number of successful and failed proposals for the proposal at the given validator index.
    public fun get_current_epoch_proposal_counts(
        validator_index: u64
    ): (u64, u64) acquires ValidatorPerformance {
        let validator_performances =
            &borrow_global<ValidatorPerformance>(@aptos_framework).validators;
        let validator_performance = validator_performances.borrow(validator_index);
        (
            validator_performance.successful_proposals,
            validator_performance.failed_proposals
        )
    }

    #[view]
    /// Return the validator's config.
    public fun get_validator_config(
        pool_address: address
    ): (vector<u8>, vector<u8>, vector<u8>) acquires ValidatorConfig {
        assert_stake_pool_exists(pool_address);
        let validator_config = borrow_global<ValidatorConfig>(pool_address);
        (
            validator_config.consensus_pubkey,
            validator_config.network_addresses,
            validator_config.fullnode_addresses
        )
    }

    #[view]
    public fun stake_pool_exists(addr: address): bool {
        exists<StakePool>(addr)
    }

    #[view]
    /// Returns the pending transaction fee that is accumulated in current epoch.
    public fun get_pending_transaction_fee(): vector<u64> acquires PendingTransactionFee {
        let result = vector::empty();
        let fee_table =
            &borrow_global<PendingTransactionFee>(@aptos_framework).pending_fee_by_validator;
        let num_validators = fee_table.compute_length();
        let i = 0;
        while (i < num_validators) {
            result.push_back(fee_table.borrow(&i).read());
            i += 1;
        };

        result
    }

    #[view]
    /// Return the number of active validators in the current epoch.
    public fun get_active_validator_count(): u64 acquires ValidatorSet {
        borrow_global<ValidatorSet>(@aptos_framework).active_validators.length()
    }

    #[view]
    /// Return the number of validators waiting to become active next epoch.
    public fun get_pending_active_validator_count(): u64 acquires ValidatorSet {
        borrow_global<ValidatorSet>(@aptos_framework).pending_active.length()
    }

    #[view]
    /// Return the number of validators still active this epoch but leaving next epoch.
    public fun get_pending_inactive_validator_count(): u64 acquires ValidatorSet {
        borrow_global<ValidatorSet>(@aptos_framework).pending_inactive.length()
    }

    #[view]
    /// Return active validator pool addresses in current-epoch order.
    public fun get_active_validators(
        offset: u64,
        limit: u64
    ): vector<address> acquires ValidatorSet {
        let validator_set = borrow_global<ValidatorSet>(@aptos_framework);
        get_validator_addresses(&validator_set.active_validators, offset, limit)
    }

    #[view]
    /// Return pending-active validator pool addresses.
    public fun get_pending_active_validators(
        offset: u64,
        limit: u64
    ): vector<address> acquires ValidatorSet {
        let validator_set = borrow_global<ValidatorSet>(@aptos_framework);
        get_validator_addresses(&validator_set.pending_active, offset, limit)
    }

    #[view]
    /// Return pending-inactive validator pool addresses.
    public fun get_pending_inactive_validators(
        offset: u64,
        limit: u64
    ): vector<address> acquires ValidatorSet {
        let validator_set = borrow_global<ValidatorSet>(@aptos_framework);
        get_validator_addresses(&validator_set.pending_inactive, offset, limit)
    }

    #[view]
    /// Return validator addresses that can vote in the current epoch:
    /// active validators followed by pending-inactive validators.
    public fun get_current_epoch_validators(
        offset: u64,
        limit: u64
    ): vector<address> acquires ValidatorSet {
        let validator_set = borrow_global<ValidatorSet>(@aptos_framework);
        let addresses = vector[];
        let total = validator_set.active_validators.length()
            + validator_set.pending_inactive.length();
        let i = offset;
        let end = range_end(offset, limit, total);
        while (i < end) {
            if (i < validator_set.active_validators.length()) {
                addresses.push_back(validator_set.active_validators.borrow(i).addr);
            } else {
                let pending_index = i - validator_set.active_validators.length();
                addresses.push_back(
                    validator_set.pending_inactive.borrow(pending_index).addr
                );
            };
            i += 1;
        };
        addresses
    }

    /// Initialize validator set to the core resource account.
    public(friend) fun initialize(aptos_framework: &signer) {
        system_addresses::assert_aptos_framework(aptos_framework);

        move_to(
            aptos_framework,
            ValidatorSet {
                consensus_scheme: 0,
                active_validators: vector::empty(),
                pending_active: vector::empty(),
                pending_inactive: vector::empty(),
                total_voting_power: 0,
                total_joining_power: 0
            }
        );

        move_to(aptos_framework, ValidatorPerformance { validators: vector::empty() });
    }

    /// This is only called during Genesis, which is where MintCapability<TopoCoin> can be created.
    /// Beyond genesis, no one can create TopoCoin mint/burn capabilities.
    public(friend) fun store_topo_coin_mint_cap(
        aptos_framework: &signer, mint_cap: MintCapability<TopoCoin>
    ) {
        system_addresses::assert_aptos_framework(aptos_framework);
        move_to(aptos_framework, TopoCoinCapabilities { mint_cap })
    }

    /// Allow on chain governance to remove validators from the validator set.
    public fun remove_validators(
        aptos_framework: &signer, validators: &vector<address>
    ) acquires ValidatorSet {
        assert_reconfig_not_in_progress();
        system_addresses::assert_aptos_framework(aptos_framework);
        let validator_set = borrow_global_mut<ValidatorSet>(@aptos_framework);
        let active_validators = &mut validator_set.active_validators;
        let pending_inactive = &mut validator_set.pending_inactive;
        spec {
            update ghost_active_num = len(active_validators);
            update ghost_pending_inactive_num = len(pending_inactive);
        };
        let len_validators = validators.length();
        let i = 0;
        // Remove each validator from the validator set.
        while ({
            spec {
                invariant i <= len_validators;
                invariant spec_validators_are_initialized(active_validators);
                invariant spec_validator_indices_are_valid(active_validators);
                invariant spec_validators_are_initialized(pending_inactive);
                invariant spec_validator_indices_are_valid(pending_inactive);
                invariant ghost_active_num + ghost_pending_inactive_num
                    == len(active_validators) + len(pending_inactive);
            };
            i < len_validators
        }) {
            let validator = validators[i];
            let validator_index = find_validator(active_validators, validator);
            if (validator_index.is_some()) {
                let validator_info =
                    active_validators.swap_remove(*validator_index.borrow());
                pending_inactive.push_back(validator_info);
                staking_registry::set_validator_pending_inactive(validator);
                spec {
                    update ghost_active_num = ghost_active_num - 1;
                    update ghost_pending_inactive_num = ghost_pending_inactive_num + 1;
                };
            };
            i += 1;
        };
    }

    public fun initialize_pending_transaction_fee(framework: &signer) {
        system_addresses::assert_aptos_framework(framework);

        if (!exists<PendingTransactionFee>(@aptos_framework)) {
            move_to(
                framework,
                PendingTransactionFee {
                    // The max leaf order is set to 10 because there is a existing limitation that a
                    // resource can only have 10 aggregators at max.
                    pending_fee_by_validator: big_ordered_map::new_with_config(
                        5, 10, true
                    )
                }
            );
        }
    }

    public fun set_transaction_fee_limit_per_epoch_per_pool(
        framework: &signer, limit_octa: u64
    ) acquires TransactionFeeConfig {
        system_addresses::assert_aptos_framework(framework);

        let config = TransactionFeeConfig::V0 {
            max_fee_octa_allowed_per_epoch_per_pool: limit_octa
        };

        set_transaction_fee_config(framework, config);
    }

    public fun set_transaction_fee_config(
        framework: &signer, config: TransactionFeeConfig
    ) acquires TransactionFeeConfig {
        system_addresses::assert_aptos_framework(framework);

        if (exists<TransactionFeeConfig>(@aptos_framework)) {
            *borrow_global_mut<TransactionFeeConfig>(@aptos_framework) = config;
        } else {
            move_to(framework, config);
        }
    }

    public(friend) fun record_fee(
        vm: &signer,
        fee_distribution_validator_indices: vector<u64>,
        fee_amounts_octa: vector<u64>
    ) acquires PendingTransactionFee {
        // Operational constraint: can only be invoked by the VM.
        system_addresses::assert_vm(vm);

        assert!(
            fee_distribution_validator_indices.length() == fee_amounts_octa.length()
        );

        let num_validators_to_distribute = fee_distribution_validator_indices.length();
        let pending_fee = borrow_global_mut<PendingTransactionFee>(@aptos_framework);
        let i = 0;
        while (i < num_validators_to_distribute) {
            let validator_index = fee_distribution_validator_indices[i];
            let fee_octa = fee_amounts_octa[i];
            pending_fee.pending_fee_by_validator.borrow_mut(&validator_index).add(
                fee_octa
            );
            i += 1;
        }
    }

    /// Initialize the validator account and give ownership to the signing account
    /// except it leaves the ValidatorConfig to be set by another entity.
    /// Note: this triggers setting the operator and owner, set it to the account's address
    /// to set later.
    public entry fun initialize_stake_owner(
        owner: &signer,
        initial_stake_amount: u64,
        operator: address
    ) acquires AllowedValidators, OwnerCapability, StakePool {
        initialize_stake_pool_with_empty_config(owner, operator);
        assert!(
            initial_stake_amount == 0,
            error::invalid_argument(EINITIAL_STAKE_NOT_SUPPORTED)
        );
        register_self_owned_validator(signer::address_of(owner));
    }

    /// Initializes a stake pool plus empty validator config for a resource-account backed pool.
    /// The caller is responsible for registering the correct owner in `staking_registry`.
    public(friend) fun initialize_stake_pool(
        owner: &signer,
        operator: address
    ) acquires AllowedValidators, OwnerCapability, StakePool {
        initialize_stake_pool_with_empty_config(owner, operator);
    }

    /// Initialize the validator account and give ownership to the signing account.
    public entry fun initialize_validator(
        account: &signer,
        consensus_pubkey: vector<u8>,
        proof_of_possession: vector<u8>,
        network_addresses: vector<u8>,
        fullnode_addresses: vector<u8>
    ) acquires AllowedValidators {
        check_stake_permission(account);
        // Checks the public key has a valid proof-of-possession to prevent rogue-key attacks.
        let pubkey_from_pop =
            &bls12381::public_key_from_bytes_with_pop(
                consensus_pubkey,
                &proof_of_possession_from_bytes(proof_of_possession)
            );
        assert!(
            pubkey_from_pop.is_some(), error::invalid_argument(EINVALID_PUBLIC_KEY)
        );

        initialize_owner(account);
        move_to(
            account,
            ValidatorConfig {
                consensus_pubkey,
                network_addresses,
                fullnode_addresses,
                validator_index: 0
            }
        );
        register_self_owned_validator(signer::address_of(account));
    }

    fun initialize_owner(owner: &signer) acquires AllowedValidators {
        check_stake_permission(owner);
        let owner_address = signer::address_of(owner);
        assert!(is_allowed(owner_address), error::not_found(EINELIGIBLE_VALIDATOR));
        assert!(
            !stake_pool_exists(owner_address),
            error::already_exists(EALREADY_REGISTERED)
        );

        move_to(
            owner,
            StakePool {
                active: coin::zero<TopoCoin>(),
                pending_active: coin::zero<TopoCoin>(),
                pending_inactive: coin::zero<TopoCoin>(),
                inactive: coin::zero<TopoCoin>(),
                locked_until_secs: 0,
                operator_address: owner_address
            }
        );

        move_to(owner, OwnerCapability { pool_address: owner_address });
    }

    fun initialize_stake_pool_with_empty_config(
        owner: &signer,
        operator: address,
    ) acquires AllowedValidators, OwnerCapability, StakePool {
        check_stake_permission(owner);
        initialize_owner(owner);
        move_to(owner, empty_validator_config());

        let owner_address = signer::address_of(owner);
        if (owner_address != operator) {
            set_operator(owner, operator);
        };
    }

    fun empty_validator_config(): ValidatorConfig {
        ValidatorConfig {
            consensus_pubkey: vector::empty(),
            network_addresses: vector::empty(),
            fullnode_addresses: vector::empty(),
            validator_index: 0
        }
    }

    fun register_self_owned_validator(owner_address: address) {
        if (staking_registry::registry_exists() && !staking_registry::validator_exists(owner_address)) {
            staking_registry::register_validator_for_owner(
                owner_address,
                owner_address,
                0,
            );
        };
    }

    /// Extract and return owner capability from the signing account.
    public fun extract_owner_cap(owner: &signer): OwnerCapability acquires OwnerCapability {
        check_stake_permission(owner);
        let owner_address = signer::address_of(owner);
        assert_owner_cap_exists(owner_address);
        move_from<OwnerCapability>(owner_address)
    }

    /// Deposit `owner_cap` into `account`. This requires `account` to not already have ownership of another
    /// staking pool.
    public fun deposit_owner_cap(
        owner: &signer, owner_cap: OwnerCapability
    ) {
        check_stake_permission(owner);
        assert!(
            !exists<OwnerCapability>(signer::address_of(owner)),
            error::not_found(EOWNER_CAP_ALREADY_EXISTS)
        );
        move_to(owner, owner_cap);
    }

    /// Destroy `owner_cap`.
    public fun destroy_owner_cap(owner_cap: OwnerCapability) {
        let OwnerCapability { pool_address: _ } = owner_cap;
    }

    /// Allows an owner to change the operator of the stake pool.
    public entry fun set_operator(
        owner: &signer, new_operator: address
    ) acquires OwnerCapability, StakePool {
        check_stake_permission(owner);
        let owner_address = signer::address_of(owner);
        assert_owner_cap_exists(owner_address);
        let ownership_cap = borrow_global<OwnerCapability>(owner_address);
        set_operator_with_cap(ownership_cap, new_operator);
    }

    /// Allows an account with ownership capability to change the operator of the stake pool.
    public fun set_operator_with_cap(
        owner_cap: &OwnerCapability, new_operator: address
    ) acquires StakePool {
        let pool_address = owner_cap.pool_address;
        assert_stake_pool_exists(pool_address);
        let stake_pool = borrow_global_mut<StakePool>(pool_address);
        let old_operator = stake_pool.operator_address;
        stake_pool.operator_address = new_operator;

        event::emit(SetOperator { pool_address, old_operator, new_operator });
    }

    /// Rotate the consensus key of the validator, it'll take effect in next epoch.
    public entry fun rotate_consensus_key(
        operator: &signer,
        pool_address: address,
        new_consensus_pubkey: vector<u8>,
        proof_of_possession: vector<u8>
    ) acquires StakePool, ValidatorConfig {
        check_stake_permission(operator);
        assert_reconfig_not_in_progress();
        assert_stake_pool_exists(pool_address);

        let stake_pool = borrow_global_mut<StakePool>(pool_address);
        assert!(
            signer::address_of(operator) == stake_pool.operator_address,
            error::unauthenticated(ENOT_OPERATOR)
        );

        assert!(
            exists<ValidatorConfig>(pool_address),
            error::not_found(EVALIDATOR_CONFIG)
        );
        let validator_info = borrow_global_mut<ValidatorConfig>(pool_address);
        let old_consensus_pubkey = validator_info.consensus_pubkey;
        // Checks the public key has a valid proof-of-possession to prevent rogue-key attacks.
        let pubkey_from_pop =
            &bls12381::public_key_from_bytes_with_pop(
                new_consensus_pubkey,
                &proof_of_possession_from_bytes(proof_of_possession)
            );
        assert!(
            pubkey_from_pop.is_some(), error::invalid_argument(EINVALID_PUBLIC_KEY)
        );
        validator_info.consensus_pubkey = new_consensus_pubkey;

        event::emit(
            RotateConsensusKey {
                pool_address,
                old_consensus_pubkey,
                new_consensus_pubkey
            }
        );
    }

    /// Update the network and full node addresses of the validator. This only takes effect in the next epoch.
    public entry fun update_network_and_fullnode_addresses(
        operator: &signer,
        pool_address: address,
        new_network_addresses: vector<u8>,
        new_fullnode_addresses: vector<u8>
    ) acquires StakePool, ValidatorConfig {
        check_stake_permission(operator);
        assert_reconfig_not_in_progress();
        assert_stake_pool_exists(pool_address);
        let stake_pool = borrow_global_mut<StakePool>(pool_address);
        assert!(
            signer::address_of(operator) == stake_pool.operator_address,
            error::unauthenticated(ENOT_OPERATOR)
        );
        assert!(
            exists<ValidatorConfig>(pool_address),
            error::not_found(EVALIDATOR_CONFIG)
        );
        let validator_info = borrow_global_mut<ValidatorConfig>(pool_address);
        let old_network_addresses = validator_info.network_addresses;
        validator_info.network_addresses = new_network_addresses;
        let old_fullnode_addresses = validator_info.fullnode_addresses;
        validator_info.fullnode_addresses = new_fullnode_addresses;

        event::emit(
            UpdateNetworkAndFullnodeAddresses {
                pool_address,
                old_network_addresses,
                new_network_addresses,
                old_fullnode_addresses,
                new_fullnode_addresses
            }
        );
    }

    /// Similar to increase_lockup_with_cap but will use ownership capability from the signing account.
    public entry fun increase_lockup(owner: &signer) acquires OwnerCapability, StakePool {
        check_stake_permission(owner);
        let owner_address = signer::address_of(owner);
        assert_owner_cap_exists(owner_address);
        let ownership_cap = borrow_global<OwnerCapability>(owner_address);
        increase_lockup_with_cap(ownership_cap);
    }

    /// Extend the lockup horizon used by governance and validator lifecycle checks.
    public fun increase_lockup_with_cap(owner_cap: &OwnerCapability) acquires StakePool {
        let pool_address = owner_cap.pool_address;
        assert_stake_pool_exists(pool_address);
        let config = staking_config::get();

        let stake_pool = borrow_global_mut<StakePool>(pool_address);
        let old_locked_until_secs = stake_pool.locked_until_secs;
        let new_locked_until_secs =
            timestamp::now_seconds()
                + staking_config::get_recurring_lockup_duration(&config);
        assert!(
            old_locked_until_secs < new_locked_until_secs,
            error::invalid_argument(EINVALID_LOCKUP)
        );
        stake_pool.locked_until_secs = new_locked_until_secs;

        event::emit(
            IncreaseLockup {
                pool_address,
                old_locked_until_secs,
                new_locked_until_secs
            }
        );
    }

    /// This can only called by the operator of the validator/staking pool.
    public entry fun join_validator_set(
        operator: &signer, pool_address: address
    ) acquires StakePool, ValidatorConfig, ValidatorSet {
        check_stake_permission(operator);
        assert!(
            staking_config::get_allow_validator_set_change(&staking_config::get()),
            error::invalid_argument(ENO_POST_GENESIS_VALIDATOR_SET_CHANGE_ALLOWED)
        );

        join_validator_set_internal(operator, pool_address);
    }

    /// Request to have `pool_address` join the validator set. Can only be called after calling `initialize_validator`.
    /// If the validator has the required stake (more than minimum and less than maximum allowed), they will be
    /// added to the pending_active queue. All validators in this queue will be added to the active set when the next
    /// epoch starts (eligibility will be rechecked).
    ///
    /// This internal version can only be called by the Genesis module during Genesis.
    ///
    /// Joining checks (in order):
    /// 1. No reconfiguration in progress
    /// 2. Operator signature matches pool's operator_address
    /// 3. Validator is currently INACTIVE (not already pending or active)
    /// 4. Validator's own joining power > 0 (owner must have deposited and delegated)
    /// 5. Total pool power >= minimum_stake and <= maximum_stake
    /// 6. Per-epoch voting power increase limit not exceeded
    /// 7. Consensus pubkey is non-empty
    /// 8. Validator set size <= MAX_VALIDATOR_SET_SIZE (65536)
    ///
    /// On success: validator is added to pending_active and staking_registry status is set to PENDING_ACTIVE.
    public(friend) fun join_validator_set_internal(
        operator: &signer, pool_address: address
    ) acquires StakePool, ValidatorConfig, ValidatorSet {
        assert_reconfig_not_in_progress();
        assert_stake_pool_exists(pool_address);
        let stake_pool = borrow_global_mut<StakePool>(pool_address);
        assert!(
            signer::address_of(operator) == stake_pool.operator_address,
            error::unauthenticated(ENOT_OPERATOR)
        );
        assert!(
            get_validator_state(pool_address) == VALIDATOR_STATUS_INACTIVE,
            error::invalid_state(EALREADY_ACTIVE_VALIDATOR)
        );

        let config = staking_config::get();
        let (minimum_stake, maximum_stake) = staking_config::get_required_stake(&config);
        let self_power = staking_registry::get_validator_joining_power(pool_address);
        assert!(self_power > 0, error::invalid_argument(ESTAKE_TOO_LOW));
        let voting_power = staking_registry::get_validator_total_power(pool_address);
        assert!(voting_power >= minimum_stake, error::invalid_argument(ESTAKE_TOO_LOW));
        assert!(voting_power <= maximum_stake, error::invalid_argument(ESTAKE_TOO_HIGH));

        // Track and validate voting power increase.
        update_voting_power_increase(voting_power);

        // Add validator to pending_active, to be activated in the next epoch.
        let validator_config = borrow_global<ValidatorConfig>(pool_address);
        assert!(
            !validator_config.consensus_pubkey.is_empty(),
            error::invalid_argument(EINVALID_PUBLIC_KEY)
        );

        // Validate the current validator set size has not exceeded the limit.
        let validator_set = borrow_global_mut<ValidatorSet>(@aptos_framework);
        validator_set.pending_active.push_back(
            generate_validator_info(pool_address, *validator_config)
        );
        let validator_set_size =
            validator_set.active_validators.length()
                + validator_set.pending_active.length();
        assert!(
            validator_set_size <= MAX_VALIDATOR_SET_SIZE,
            error::invalid_argument(EVALIDATOR_SET_TOO_LARGE)
        );
        staking_registry::set_validator_pending_active(pool_address);

        event::emit(JoinValidatorSet { pool_address });
    }

    /// Request to have `pool_address` leave the validator set. The validator is only actually removed from the set when
    /// the next epoch starts.
    /// The last validator in the set cannot leave. This is an edge case that should never happen as long as the network
    /// is still operational.
    ///
    /// Can only be called by the operator of the validator/staking pool.
    public entry fun leave_validator_set(
        operator: &signer, pool_address: address
    ) acquires StakePool, ValidatorSet {
        check_stake_permission(operator);
        assert_reconfig_not_in_progress();
        let config = staking_config::get();
        assert!(
            staking_config::get_allow_validator_set_change(&config),
            error::invalid_argument(ENO_POST_GENESIS_VALIDATOR_SET_CHANGE_ALLOWED)
        );

        assert_stake_pool_exists(pool_address);
        let stake_pool = borrow_global_mut<StakePool>(pool_address);
        // Account has to be the operator.
        assert!(
            signer::address_of(operator) == stake_pool.operator_address,
            error::unauthenticated(ENOT_OPERATOR)
        );

        let validator_set = borrow_global_mut<ValidatorSet>(@aptos_framework);
        // If the validator is still pending_active, directly kick the validator out.
        let maybe_pending_active_index =
            find_validator(&validator_set.pending_active, pool_address);
        if (maybe_pending_active_index.is_some()) {
            validator_set.pending_active.swap_remove(maybe_pending_active_index.extract());

            // Decrease the voting power increase as the pending validator's voting power was added when they requested
            // to join. Now that they changed their mind, their voting power should not affect the joining limit of this
            // epoch.
            let validator_stake =
                staking_registry::get_validator_total_power(pool_address) as u128;
            // total_joining_power should be larger than validator_stake but just in case there has been a small
            // rounding error somewhere that can lead to an underflow, we still want to allow this transaction to
            // succeed.
            if (validator_set.total_joining_power > validator_stake) {
                validator_set.total_joining_power -= validator_stake;
            } else {
                validator_set.total_joining_power = 0;
            };
            staking_registry::set_validator_inactive(pool_address);
        } else {
            // Validate that the validator is already part of the validator set.
            let maybe_active_index =
                find_validator(&validator_set.active_validators, pool_address);
            assert!(maybe_active_index.is_some(), error::invalid_state(ENOT_VALIDATOR));
            let validator_info =
                validator_set.active_validators.swap_remove(maybe_active_index.extract());
            assert!(
                validator_set.active_validators.length() > 0,
                error::invalid_state(ELAST_VALIDATOR)
            );
            validator_set.pending_inactive.push_back(validator_info);
            staking_registry::set_validator_pending_inactive(pool_address);

            event::emit(LeaveValidatorSet { pool_address });
        };
    }

    /// Returns true if the current validator can still vote in the current epoch.
    /// This includes validators that requested to leave but are still in the pending_inactive queue and will be removed
    /// when the epoch starts.
    public fun is_current_epoch_validator(pool_address: address): bool acquires ValidatorSet {
        assert_stake_pool_exists(pool_address);
        let validator_state = get_validator_state(pool_address);
        validator_state == VALIDATOR_STATUS_ACTIVE
            || validator_state == VALIDATOR_STATUS_PENDING_INACTIVE
    }

    /// Update the validator performance (proposal statistics). This is only called by block::prologue().
    /// This function cannot abort.
    public(friend) fun update_performance_statistics(
        proposer_index: Option<u64>, failed_proposer_indices: vector<u64>
    ) acquires ValidatorPerformance {
        // Validator set cannot change until the end of the epoch, so the validator index in arguments should
        // match with those of the validators in ValidatorPerformance resource.
        let validator_perf = borrow_global_mut<ValidatorPerformance>(@aptos_framework);
        let validator_len = validator_perf.validators.length();

        spec {
            update ghost_valid_perf = validator_perf;
            update ghost_proposer_idx = proposer_index;
        };
        // proposer_index is an option because it can be missing (for NilBlocks)
        if (proposer_index.is_some()) {
            let cur_proposer_index = proposer_index.extract();
            // Here, and in all other vector::borrow, skip any validator indices that are out of bounds,
            // this ensures that this function doesn't abort if there are out of bounds errors.
            if (cur_proposer_index < validator_len) {
                let validator = validator_perf.validators.borrow_mut(cur_proposer_index);
                spec {
                    assume validator.successful_proposals + 1 <= MAX_U64;
                };
                validator.successful_proposals += 1;
            };
        };

        let f = 0;
        let f_len = failed_proposer_indices.length();
        while ({
            spec {
                invariant len(validator_perf.validators) == validator_len;
                invariant (
                    ghost_proposer_idx.is_some()
                        && ghost_proposer_idx.borrow() < validator_len
                ) ==>
                    (
                        validator_perf.validators[ghost_proposer_idx.borrow()].successful_proposals ==
                        ghost_valid_perf.validators[ghost_proposer_idx.borrow()].successful_proposals
                        + 1
                    );
            };
            f < f_len
        }) {
            let validator_index = failed_proposer_indices[f];
            if (validator_index < validator_len) {
                let validator = validator_perf.validators.borrow_mut(validator_index);
                spec {
                    assume validator.failed_proposals + 1 <= MAX_U64;
                };
                validator.failed_proposals += 1;
            };
            f += 1;
        };
    }

    /// Triggered during a reconfiguration. This function shouldn't abort.
    ///
    /// Full epoch transition sequence:
    ///
    /// Phase 1 — Reward & fee distribution (active + pending_inactive validators):
    ///   For each validator:
    ///   a. update_stake_pool: merge pending_active coins into active; unlock pending_inactive if lockup expired
    ///   b. collect_transaction_fee_for_validator: drain the fee aggregator for this validator index
    ///   c. staking_registry::distribute_transaction_fees: split fees among delegators by power share
    ///   d. staking_registry::distribute_epoch_rewards: mint and distribute staking rewards
    ///
    /// Phase 2 — POC power period advancement:
    ///   poc_power_store::commit_next_period_if_boundary: if this epoch crosses a period boundary,
    ///   advance current_period so staged power versions become effective.
    ///
    /// Phase 3 — Force-undelegate below-threshold users:
    ///   For every pool (active, pending_inactive, pending_active):
    ///   staking_registry::force_undelegate_below_threshold: eject delegators whose effective power
    ///   has dropped below the maintain threshold (due to POC power decay or deposit withdrawal).
    ///
    /// Phase 4 — Validator set state transitions:
    ///   - pending_active validators → ACTIVE in staking_registry
    ///   - pending_inactive validators → INACTIVE in staking_registry
    ///   - Merge pending_active into active_validators; clear pending_inactive
    ///
    /// Phase 5 — Recompute active set for next epoch:
    ///   For each candidate in active_validators:
    ///   - Recompute voting_power from staking_registry (reflects rewards just distributed)
    ///   - Keep if voting_power >= minimum_stake; otherwise drop (set INACTIVE)
    ///
    /// Phase 6 — Emergency liveness fallback:
    ///   If the resulting active set is empty (no validator meets minimum_stake),
    ///   retain the previous active set to keep the chain alive.
    ///   Emit ValidatorSetLivenessFallback event to signal the critical condition.
    ///
    /// Phase 7 — Housekeeping:
    ///   - Reset total_joining_power to 0
    ///   - Update total_staked_power in staking_registry
    ///   - Reassign validator indices; reset performance counters
    ///   - Renew lockups for validators remaining in the active set
    ///   - Rebuild PendingTransactionFee aggregator map for the new active set
    ///   - Optionally update rewards rate (periodical_reward_rate_decrease feature)
    public(friend) fun on_new_epoch() acquires PendingTransactionFee, StakePool, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        let validator_set = borrow_global_mut<ValidatorSet>(@aptos_framework);
        let config = staking_config::get();
        let validator_perf = borrow_global_mut<ValidatorPerformance>(@aptos_framework);

        let (rewards_rate, rewards_rate_denominator) =
            staking_config::get_reward_rate(&config);

        // Process pending stake and distribute transaction fees and rewards for each currently active validator.
        validator_set.active_validators.for_each_ref(|validator| {
            let validator: &ValidatorInfo = validator;
            update_stake_pool(validator_perf, validator.addr, &config);
            let validator_config = borrow_global<ValidatorConfig>(validator.addr);
            let current_perf =
                validator_perf.validators.borrow(validator_config.validator_index);
            let num_successful_proposals = current_perf.successful_proposals;
            let num_total_proposals =
                current_perf.successful_proposals + current_perf.failed_proposals;
            let fee_amount =
                collect_transaction_fee_for_validator(validator_config.validator_index);
            if (std::features::is_distribute_transaction_fee_enabled() && fee_amount > 0) {
                staking_registry::distribute_transaction_fees(
                    validator.addr,
                    fee_amount,
                );
                event::emit(DistributeTransactionFee { pool_address: validator.addr, fee_amount });
            };
            staking_registry::distribute_epoch_rewards(
                validator.addr,
                num_successful_proposals,
                num_total_proposals,
                rewards_rate,
                rewards_rate_denominator,
            );
        });

        // Process pending stake and distribute transaction fees and rewards for each currently pending_inactive validator
        // (requested to leave but not removed yet).
        validator_set.pending_inactive.for_each_ref(|validator| {
            let validator: &ValidatorInfo = validator;
            update_stake_pool(validator_perf, validator.addr, &config);
            let validator_config = borrow_global<ValidatorConfig>(validator.addr);
            let current_perf =
                validator_perf.validators.borrow(validator_config.validator_index);
            let num_successful_proposals = current_perf.successful_proposals;
            let num_total_proposals =
                current_perf.successful_proposals + current_perf.failed_proposals;
            let fee_amount =
                collect_transaction_fee_for_validator(validator_config.validator_index);
            if (std::features::is_distribute_transaction_fee_enabled() && fee_amount > 0) {
                staking_registry::distribute_transaction_fees(
                    validator.addr,
                    fee_amount,
                );
                event::emit(DistributeTransactionFee { pool_address: validator.addr, fee_amount });
            };
            staking_registry::distribute_epoch_rewards(
                validator.addr,
                num_successful_proposals,
                num_total_proposals,
                rewards_rate,
                rewards_rate_denominator,
            );
        });

        poc_power_store::commit_next_period_if_boundary();
        validator_set.active_validators.for_each_ref(|validator| {
            let validator: &ValidatorInfo = validator;
            staking_registry::force_undelegate_below_threshold(validator.addr);
        });
        validator_set.pending_inactive.for_each_ref(|validator| {
            let validator: &ValidatorInfo = validator;
            staking_registry::force_undelegate_below_threshold(validator.addr);
        });
        validator_set.pending_active.for_each_ref(|validator| {
            let validator: &ValidatorInfo = validator;
            staking_registry::force_undelegate_below_threshold(validator.addr);
        });

        validator_set.pending_active.for_each_ref(|validator| {
            let validator: &ValidatorInfo = validator;
            staking_registry::set_validator_active(validator.addr);
        });
        validator_set.pending_inactive.for_each_ref(|validator| {
            let validator: &ValidatorInfo = validator;
            staking_registry::set_validator_inactive(validator.addr);
        });

        let previous_active_count = validator_set.active_validators.length();

        // Activate currently pending_active validators.
        append(&mut validator_set.active_validators, &mut validator_set.pending_active);

        // Officially deactivate all pending_inactive validators. They will now no longer receive rewards.
        validator_set.pending_inactive = vector::empty();

        // Update active validator set so that network address/public key change takes effect.
        // Moreover, recalculate the total voting power, and deactivate the validator whose
        // voting power is less than the minimum required stake.
        let next_epoch_validators = vector::empty();
        let (minimum_stake, maximum_stake) = staking_config::get_required_stake(&config);
        let voting_power_increase_limit =
            staking_config::get_voting_power_increase_limit(&config);
        let max_voting_power_increase =
            calculate_max_voting_power_increase(
                validator_set.total_voting_power,
                voting_power_increase_limit,
            );
        let used_voting_power_increase = 0u128;
        let vlen = validator_set.active_validators.length();
        let total_voting_power = 0;
        let dropped_validators = vector[];
        let i = 0;
        while ({
            spec {
                invariant spec_validators_are_initialized(next_epoch_validators);
                invariant i <= vlen;
            };
            i < vlen
        }) {
            let old_validator_info = validator_set.active_validators.borrow_mut(i);
            let pool_address = old_validator_info.addr;
            let validator_config = borrow_global<ValidatorConfig>(pool_address);
            let raw_validator_info =
                generate_validator_info(pool_address, *validator_config);
            let baseline_voting_power =
                if (i < previous_active_count) {
                    old_validator_info.voting_power
                } else {
                    0
                };
            let new_validator_info =
                cap_validator_info_voting_power_for_epoch(
                    raw_validator_info,
                    maximum_stake,
                    baseline_voting_power,
                    max_voting_power_increase,
                    used_voting_power_increase,
                );

            // A validator needs at least the min stake required to join the validator set.
            if (new_validator_info.voting_power >= minimum_stake) {
                used_voting_power_increase += voting_power_increase(
                    baseline_voting_power,
                    new_validator_info.voting_power,
                );
                spec {
                    assume total_voting_power + new_validator_info.voting_power
                        <= MAX_U128;
                };
                total_voting_power +=(new_validator_info.voting_power as u128);
                next_epoch_validators.push_back(new_validator_info);
            } else {
                dropped_validators.push_back(pool_address);
            };
            i += 1;
        };

        // In the extreme case where the next epoch validator election produces an empty set (i.e., no staker satisfies the minimum stake or participation requirements), the system enters an emergency liveness preservation mode.
        // Instead of transitioning to an empty validator set—which would render the network inoperable—the protocol retains the previous active validator set and recomputes the total voting power from it.
        // A ValidatorSetLivenessFallback event is emitted to signal this critical governance and economic security failure.
        if (!next_epoch_validators.is_empty()) {
            dropped_validators.for_each_ref(|addr| {
                staking_registry::set_validator_inactive(*addr);
            });
            validator_set.active_validators = next_epoch_validators;
            validator_set.total_voting_power = total_voting_power;
        } else {
            // We derive the next validator set from the previous epoch's active and pending-active stakers.
            // If the resulting set is empty, it indicates that no staker is willing or qualified to participate
            // in consensus anymore. In this case, the chain is considered effectively dead, and we must retain
            // the previous active validator set as a last-resort liveness fallback.
            // Recompute each validator's info from current stake (after update_stake_pool) so that
            // voting_power and total_voting_power reflect rewards, fees, and merged stake—not stale values.
            let refreshed_validators = vector::empty();
            let emergency_total_voting_power = 0u128;
            let fallback_vlen = validator_set.active_validators.length();
            let fallback_i = 0;
            while (fallback_i < fallback_vlen) {
                let old_validator_info =
                    validator_set.active_validators.borrow(fallback_i);
                let pool_address = old_validator_info.addr;
                let validator_config = &ValidatorConfig[pool_address];
                let raw_validator_info =
                    generate_validator_info(pool_address, *validator_config);
                let baseline_voting_power =
                    if (fallback_i < previous_active_count) {
                        old_validator_info.voting_power
                    } else {
                        0
                    };
                let new_validator_info =
                    cap_validator_info_voting_power_for_epoch(
                        raw_validator_info,
                        maximum_stake,
                        baseline_voting_power,
                        max_voting_power_increase,
                        used_voting_power_increase,
                    );
                used_voting_power_increase += voting_power_increase(
                    baseline_voting_power,
                    new_validator_info.voting_power,
                );
                refreshed_validators.push_back(new_validator_info);
                emergency_total_voting_power +=(new_validator_info.voting_power as u128);
                fallback_i += 1;
            };
            validator_set.active_validators = refreshed_validators;
            validator_set.total_voting_power = emergency_total_voting_power;
            event::emit(
                ValidatorSetLivenessFallback {
                    minimum_stake,
                    emergency_validator_count: validator_set.active_validators.length(),
                    total_emergency_voting_power: validator_set.total_voting_power
                }
            );
        };
        validator_set.total_joining_power = 0;
        let total_staked_power =
            if (validator_set.total_voting_power > MAX_U64) {
                MAX_U64 as u64
            } else {
                validator_set.total_voting_power as u64
            };
        staking_registry::set_total_staked_power(total_staked_power);

        // Update validator indices, reset performance scores, and renew lockups.
        validator_perf.validators = vector::empty();
        let recurring_lockup_duration_secs =
            staking_config::get_recurring_lockup_duration(&config);
        let vlen = validator_set.active_validators.length();
        let validator_index = 0;
        while ({
            spec {
                invariant spec_validators_are_initialized(validator_set.active_validators);
                invariant len(validator_set.pending_active) == 0;
                invariant len(validator_set.pending_inactive) == 0;
                invariant 0 <= validator_index && validator_index <= vlen;
                invariant vlen == len(validator_set.active_validators);
                invariant forall i in 0..validator_index:
                    global<ValidatorConfig>(validator_set.active_validators[i].addr).validator_index
                        < validator_index;
                invariant forall i in 0..validator_index:
                    validator_set.active_validators[i].config.validator_index
                        < validator_index;
                invariant len(validator_perf.validators) == validator_index;
            };
            validator_index < vlen
        }) {
            let validator_info =
                validator_set.active_validators.borrow_mut(validator_index);
            validator_info.config.validator_index = validator_index;
            let validator_config =
                borrow_global_mut<ValidatorConfig>(validator_info.addr);
            validator_config.validator_index = validator_index;

            validator_perf.validators.push_back(
                IndividualValidatorPerformance {
                    successful_proposals: 0,
                    failed_proposals: 0
                }
            );

            // Automatically renew a validator's lockup for validators that will still be in the validator set in the
            // next epoch.
            let stake_pool = borrow_global_mut<StakePool>(validator_info.addr);
            let now_secs = timestamp::now_seconds();
            let reconfig_start_secs =
                if (chain_status::is_operating()) {
                    get_reconfig_start_time_secs()
                } else {
                    now_secs
                };
            if (stake_pool.locked_until_secs <= reconfig_start_secs) {
                spec {
                    assume now_secs + recurring_lockup_duration_secs <= MAX_U64;
                };
                stake_pool.locked_until_secs = now_secs
                    + recurring_lockup_duration_secs;
            };

            validator_index += 1;
        };

        if (exists<PendingTransactionFee>(@aptos_framework)) {
            let pending_fee_by_validator =
                &mut borrow_global_mut<PendingTransactionFee>(@aptos_framework).pending_fee_by_validator;
            assert!(
                pending_fee_by_validator.is_empty(),
                error::internal(ETRANSACTION_FEE_NOT_FULLY_DISTRIBUTED)
            );
            validator_set.active_validators.for_each_ref(|v| pending_fee_by_validator.add(
                v.config.validator_index, aggregator_v2::create_unbounded_aggregator<u64>()
            ));
        };

        if (features::periodical_reward_rate_decrease_enabled()) {
            // Update rewards rate after reward distribution.
            staking_config::calculate_and_save_latest_epoch_rewards_rate();
        };
    }

    /// Return the `ValidatorConsensusInfo` of each current validator, sorted by current validator index.
    public fun cur_validator_consensus_infos(): vector<ValidatorConsensusInfo> acquires ValidatorSet {
        let validator_set = borrow_global<ValidatorSet>(@aptos_framework);
        validator_consensus_infos_from_validator_set(validator_set)
    }

    public fun get_current_epoch_governance_voting_power(): u64 acquires ValidatorSet {
        if (!exists<ValidatorSet>(@aptos_framework)) {
            return 0
        };

        let cur_validator_set = borrow_global<ValidatorSet>(@aptos_framework);
        let (_, maximum_stake) = staking_config::get_required_stake(&staking_config::get());
        let total_power = 0u128;
        cur_validator_set.active_validators.for_each_ref(|validator| {
            let validator: &ValidatorInfo = validator;
            total_power += (
                min_u64(staking_registry::get_validator_total_power(validator.addr), maximum_stake)
                    as u128
            );
        });
        cur_validator_set.pending_inactive.for_each_ref(|validator| {
            let validator: &ValidatorInfo = validator;
            total_power += (
                min_u64(staking_registry::get_validator_total_power(validator.addr), maximum_stake)
                    as u128
            );
        });
        if (total_power > MAX_U64) {
            MAX_U64 as u64
        } else {
            total_power as u64
        }
    }

    public fun next_validator_consensus_infos(): vector<ValidatorConsensusInfo> acquires PendingTransactionFee, TransactionFeeConfig, ValidatorSet, ValidatorPerformance, ValidatorConfig {
        let simulated_validator_set = simulate_next_epoch_validator_set();
        validator_consensus_infos_from_validator_set(&simulated_validator_set)
    }

    fun simulate_next_epoch_validator_set(): ValidatorSet acquires PendingTransactionFee, TransactionFeeConfig, ValidatorSet, ValidatorPerformance, ValidatorConfig {
        let cur_validator_set = borrow_global<ValidatorSet>(@aptos_framework);
        let config = staking_config::get();
        let validator_perf = borrow_global<ValidatorPerformance>(@aptos_framework);
        let simulated_deposit_deltas = simple_map::create<address, u64>();
        let (minimum_stake, maximum_stake) = staking_config::get_required_stake(&config);
        let voting_power_increase_limit =
            staking_config::get_voting_power_increase_limit(&config);
        let max_voting_power_increase =
            calculate_max_voting_power_increase(
                cur_validator_set.total_voting_power,
                voting_power_increase_limit,
            );
        let used_voting_power_increase = 0u128;
        let (rewards_rate, rewards_rate_denominator) =
            staking_config::get_reward_rate(&config);

        cur_validator_set.active_validators.for_each_ref(|validator| {
            let validator: &ValidatorInfo = validator;
            simulate_epoch_accruals_for_validator(
                validator.addr,
                validator_perf,
                rewards_rate,
                rewards_rate_denominator,
                &mut simulated_deposit_deltas,
            );
        });
        cur_validator_set.pending_inactive.for_each_ref(|validator| {
            let validator: &ValidatorInfo = validator;
            simulate_epoch_accruals_for_validator(
                validator.addr,
                validator_perf,
                rewards_rate,
                rewards_rate_denominator,
                &mut simulated_deposit_deltas,
            );
        });

        let new_active_validators = vector[];
        let num_new_actives = 0;
        let candidate_idx = 0;
        let new_total_power = 0;
        let num_cur_actives = cur_validator_set.active_validators.length();
        let num_cur_pending_actives = cur_validator_set.pending_active.length();
        spec {
            assume num_cur_actives + num_cur_pending_actives <= MAX_U64;
        };
        let num_candidates = num_cur_actives + num_cur_pending_actives;
        while ({
            spec {
                invariant candidate_idx <= num_candidates;
                invariant spec_validators_are_initialized(new_active_validators);
                invariant len(new_active_validators) == num_new_actives;
                invariant forall i in 0..len(new_active_validators):
                    new_active_validators[i].config.validator_index == i;
                invariant num_new_actives <= candidate_idx;
                invariant spec_validators_are_initialized(new_active_validators);
            };
            candidate_idx < num_candidates
        }) {
            let candidate_in_current = candidate_idx < num_cur_actives;
            // Order matches on_new_epoch's append(): active then pending_active (append uses pop_back → reverse).
            let candidate =
                if (candidate_in_current) {
                    cur_validator_set.active_validators.borrow(candidate_idx)
                } else {
                    cur_validator_set.pending_active.borrow(
                        num_candidates - 1 - candidate_idx
                    )
                };
            let baseline_voting_power =
                if (candidate_in_current) {
                    candidate.voting_power
                } else {
                    0
                };
            let (new_voting_power, new_validator_info) = compute_simulated_validator_info(
                candidate,
                num_new_actives,
                &simulated_deposit_deltas,
                maximum_stake,
                baseline_voting_power,
                max_voting_power_increase,
                used_voting_power_increase,
            );
            if (new_voting_power >= minimum_stake) {
                used_voting_power_increase += voting_power_increase(
                    baseline_voting_power,
                    new_voting_power,
                );
                spec {
                    assume new_total_power + new_voting_power <= MAX_U128;
                };
                new_total_power +=(new_voting_power as u128);
                new_active_validators.push_back(new_validator_info);
                num_new_actives += 1;
            };
            candidate_idx += 1;
        };

        // Mirror on_new_epoch's empty-validator-set fallback: active then pending_active.
        // append() uses pop_back so pending_active ends up in reverse order; match that here.
        if (new_active_validators.is_empty()
            && (num_cur_actives > 0 || num_cur_pending_actives > 0)) {
            let num_fallback = num_cur_actives + num_cur_pending_actives;
            for (fallback_idx in 0..num_fallback) {
                let in_active = fallback_idx < num_cur_actives;
                let candidate =
                    if (in_active) {
                        cur_validator_set.active_validators.borrow(fallback_idx)
                    } else {
                        cur_validator_set.pending_active.borrow(
                            num_fallback - 1 - fallback_idx
                        )
                    };
                let (new_voting_power, new_validator_info) = compute_simulated_validator_info(
                    candidate,
                    new_active_validators.length(),
                    &simulated_deposit_deltas,
                    maximum_stake,
                    if (in_active) { candidate.voting_power } else { 0 },
                    max_voting_power_increase,
                    used_voting_power_increase,
                );
                used_voting_power_increase += voting_power_increase(
                    if (in_active) { candidate.voting_power } else { 0 },
                    new_voting_power,
                );
                new_active_validators.push_back(new_validator_info);
                new_total_power +=(new_voting_power as u128);
            };
        };

        let new_validator_set = ValidatorSet {
            consensus_scheme: cur_validator_set.consensus_scheme,
            active_validators: new_active_validators,
            pending_inactive: vector[],
            pending_active: vector[],
            total_voting_power: new_total_power,
            total_joining_power: 0
        };

        new_validator_set
    }

    fun compute_simulated_validator_info(
        candidate: &ValidatorInfo,
        validator_index: u64,
        simulated_deposit_deltas: &SimpleMap<address, u64>,
        maximum_stake: u64,
        baseline_voting_power: u64,
        max_voting_power_increase: u128,
        used_voting_power_increase: u128,
    ): (u64, ValidatorInfo) acquires ValidatorConfig {
        let raw_voting_power = get_validator_total_power_with_extra_deposit_for_next_epoch(
            candidate.addr,
            simulated_deposit_deltas,
        );
        let new_voting_power = cap_voting_power_for_epoch(
            raw_voting_power,
            maximum_stake,
            baseline_voting_power,
            max_voting_power_increase,
            used_voting_power_increase,
        );
        let config = *borrow_global<ValidatorConfig>(candidate.addr);
        config.validator_index = validator_index;
        (
            new_voting_power,
            ValidatorInfo { addr: candidate.addr, voting_power: new_voting_power, config }
        )
    }

    fun simulate_epoch_accruals_for_validator(
        validator_address: address,
        validator_perf: &ValidatorPerformance,
        rewards_rate: u64,
        rewards_rate_denominator: u64,
        simulated_deposit_deltas: &mut SimpleMap<address, u64>,
    ) acquires PendingTransactionFee, TransactionFeeConfig, ValidatorConfig {
        let validator_config = borrow_global<ValidatorConfig>(validator_address);
        let current_perf =
            validator_perf.validators.borrow(validator_config.validator_index);
        let num_successful_proposals = current_perf.successful_proposals;
        let num_total_proposals =
            current_perf.successful_proposals + current_perf.failed_proposals;
        let fee_amount =
            get_pending_transaction_fee_for_validator(validator_config.validator_index);
        if (fee_amount > 0) {
            simulate_fee_distribution_for_validator(
                validator_address,
                fee_amount,
                simulated_deposit_deltas,
            );
        };
        simulate_reward_distribution_for_validator(
            validator_address,
            num_successful_proposals,
            num_total_proposals,
            rewards_rate,
            rewards_rate_denominator,
            simulated_deposit_deltas,
        );
    }

    fun simulate_reward_distribution_for_validator(
        validator_address: address,
        num_successful_proposals: u64,
        num_total_proposals: u64,
        rewards_rate: u64,
        rewards_rate_denominator: u64,
        simulated_deposit_deltas: &mut SimpleMap<address, u64>,
    ) {
        let current_pool_power = staking_registry::get_validator_total_power(validator_address);
        if (current_pool_power == 0) {
            return
        };

        let epoch_reward = calculate_rewards_amount(
            current_pool_power,
            num_successful_proposals,
            num_total_proposals,
            rewards_rate,
            rewards_rate_denominator,
        );
        if (epoch_reward == 0) {
            return
        };
        simulate_registry_distribution_for_validator(
            validator_address,
            epoch_reward,
            false,
            simulated_deposit_deltas,
        );
    }

    fun simulate_fee_distribution_for_validator(
        validator_address: address,
        fee_amount_octa: u64,
        simulated_deposit_deltas: &mut SimpleMap<address, u64>,
    ) {
        if (fee_amount_octa == 0) {
            return
        };
        simulate_registry_distribution_for_validator(
            validator_address,
            fee_amount_octa,
            false,
            simulated_deposit_deltas,
        );
    }

    fun simulate_registry_distribution_for_validator(
        validator_address: address,
        total_amount_octa: u64,
        use_next_epoch_power: bool,
        simulated_deposit_deltas: &mut SimpleMap<address, u64>,
    ) {
        if (total_amount_octa == 0) {
            return
        };

        let owner_address = staking_registry::get_validator_owner(validator_address);
        let commission_bps = staking_registry::get_validator_commission_bps(validator_address);
        let (member_addresses, member_effective_powers, pool_power) =
            if (use_next_epoch_power) {
                staking_registry::get_validator_member_powers_for_next_epoch(
                    validator_address,
                    simulated_deposit_deltas,
                )
            } else {
                staking_registry::get_validator_member_powers_with_current_power(
                    validator_address,
                    simulated_deposit_deltas,
                )
            };
        if (pool_power == 0) {
            return
        };

        let commission = (((total_amount_octa as u128) * (commission_bps as u128)) / 10000) as u64;
        let distributable = total_amount_octa - commission;
        let distributed = 0u64;
        let len = member_addresses.length();
        let i = 0;
        while (i < len) {
            let member = *member_addresses.borrow(i);
            let member_power = *member_effective_powers.borrow(i);
            if (member_power > 0) {
                let reward =
                    (((distributable as u128) * (member_power as u128)) / (pool_power as u128))
                        as u64;
                if (reward > 0) {
                    add_simulated_deposit_delta(simulated_deposit_deltas, member, reward);
                };
                distributed += reward;
            };
            i += 1;
        };

        let owner_reward = commission + (distributable - distributed);
        if (owner_reward > 0) {
            add_simulated_deposit_delta(simulated_deposit_deltas, owner_address, owner_reward);
        };
    }

    fun get_validator_total_power_with_extra_deposit_for_next_epoch(
        validator_address: address,
        simulated_deposit_deltas: &SimpleMap<address, u64>,
    ): u64 {
        let (_, _, total_power) = staking_registry::get_validator_member_powers_for_next_epoch(
            validator_address,
            simulated_deposit_deltas,
        );
        total_power
    }

    fun add_simulated_deposit_delta(
        simulated_deposit_deltas: &mut SimpleMap<address, u64>,
        user: address,
        amount: u64,
    ) {
        if (amount == 0) {
            return
        };

        if (simulated_deposit_deltas.contains_key(&user)) {
            let current = simulated_deposit_deltas.borrow_mut(&user);
            *current = *current + amount;
        } else {
            simulated_deposit_deltas.add(user, amount);
        };
    }

    fun get_pending_transaction_fee_for_validator(
        validator_index: u64
    ): u64 acquires PendingTransactionFee, TransactionFeeConfig {
        if (!exists<PendingTransactionFee>(@aptos_framework)) {
            return 0
        };

        let fee_limit =
            if (exists<TransactionFeeConfig>(@aptos_framework)) {
                let TransactionFeeConfig::V0 { max_fee_octa_allowed_per_epoch_per_pool } =
                    borrow_global<TransactionFeeConfig>(@aptos_framework);
                *max_fee_octa_allowed_per_epoch_per_pool
            } else {
                MAX_U64 as u64
            };
        let pending_fee_by_validator =
            &borrow_global<PendingTransactionFee>(@aptos_framework).pending_fee_by_validator;
        if (!pending_fee_by_validator.contains(&validator_index)) {
            return 0
        };

        let fee_octa = pending_fee_by_validator.borrow(&validator_index).read();
        if (fee_octa > fee_limit) {
            fee_limit
        } else {
            fee_octa
        }
    }

    fun validator_consensus_infos_from_validator_set(
        validator_set: &ValidatorSet
    ): vector<ValidatorConsensusInfo> {
        let validator_consensus_infos = vector[];

        let num_active = validator_set.active_validators.length();
        let num_pending_inactive = validator_set.pending_inactive.length();
        spec {
            assume num_active + num_pending_inactive <= MAX_U64;
        };
        let total = num_active + num_pending_inactive;

        // Pre-fill the return value with dummy values.
        let idx = 0;
        while ({
            spec {
                invariant idx
                    <= len(validator_set.active_validators)
                        + len(validator_set.pending_inactive);
                invariant len(validator_consensus_infos) == idx;
                invariant len(validator_consensus_infos)
                    <= len(validator_set.active_validators)
                        + len(validator_set.pending_inactive);
            };
            idx < total
        }) {
            validator_consensus_infos.push_back(validator_consensus_info::default());
            idx += 1;
        };
        spec {
            assert len(validator_consensus_infos)
                == len(validator_set.active_validators)
                    + len(validator_set.pending_inactive);
            assert spec_validator_indices_are_valid_config(
                validator_set.active_validators,
                len(validator_set.active_validators)
                    + len(validator_set.pending_inactive)
            );
        };

        validator_set.active_validators.for_each_ref(
            |obj| {
                let vi: &ValidatorInfo = obj;
                spec {
                    assume len(validator_consensus_infos)
                        == len(validator_set.active_validators)
                            + len(validator_set.pending_inactive);
                    assert vi.config.validator_index < len(validator_consensus_infos);
                };
                let vci = validator_consensus_infos.borrow_mut(vi.config.validator_index);
                *vci = validator_consensus_info::new(
                    vi.addr, vi.config.consensus_pubkey, vi.voting_power
                );
                spec {
                    assert len(validator_consensus_infos)
                        == len(validator_set.active_validators)
                            + len(validator_set.pending_inactive);
                };
            }
        );

        validator_set.pending_inactive.for_each_ref(
            |obj| {
                let vi: &ValidatorInfo = obj;
                spec {
                    assume len(validator_consensus_infos)
                        == len(validator_set.active_validators)
                            + len(validator_set.pending_inactive);
                    assert vi.config.validator_index < len(validator_consensus_infos);
                };
                let vci = validator_consensus_infos.borrow_mut(vi.config.validator_index);
                *vci = validator_consensus_info::new(
                    vi.addr, vi.config.consensus_pubkey, vi.voting_power
                );
                spec {
                    assert len(validator_consensus_infos)
                        == len(validator_set.active_validators)
                            + len(validator_set.pending_inactive);
                };
            }
        );

        validator_consensus_infos
    }

    fun addresses_from_validator_infos(infos: &vector<ValidatorInfo>): vector<address> {
        infos.map_ref(|obj| {
            let info: &ValidatorInfo = obj;
            info.addr
        })
    }

    /// Advance the coin buckets in a StakePool at epoch boundary.
    ///
    /// This function handles the coin-level state transitions within the StakePool struct.
    /// Note: actual economic rewards are handled by staking_registry, not here.
    ///
    /// Transitions:
    /// - pending_active → active (always, at every epoch boundary)
    /// - pending_inactive → inactive (only if locked_until_secs <= reconfig_start_time)
    ///   If the lockup has not yet expired, pending_inactive coins remain locked for another epoch.
    ///
    /// This function should not abort; it is called inside on_new_epoch which must complete.
    fun update_stake_pool(
        validator_perf: &ValidatorPerformance,
        pool_address: address,
        staking_config: &StakingConfig
    ) acquires StakePool {
        let _unused_validator_perf = validator_perf;
        let _unused_staking_config = staking_config;
        let stake_pool = borrow_global_mut<StakePool>(pool_address);
        // Pending active stake can now be active.
        coin::merge(
            &mut stake_pool.active, coin::extract_all(&mut stake_pool.pending_active)
        );

        // Pending inactive stake is only fully unlocked and moved into inactive if the current lockup cycle has expired
        let current_lockup_expiration = stake_pool.locked_until_secs;
        if (get_reconfig_start_time_secs() >= current_lockup_expiration) {
            coin::merge(
                &mut stake_pool.inactive,
                coin::extract_all(&mut stake_pool.pending_inactive)
            );
        };
    }

    fun collect_transaction_fee_for_validator(
        validator_index: u64
    ): u64 acquires PendingTransactionFee, TransactionFeeConfig {
        if (!exists<PendingTransactionFee>(@aptos_framework)) {
            return 0
        };

        let fee_limit =
            if (exists<TransactionFeeConfig>(@aptos_framework)) {
                let TransactionFeeConfig::V0 { max_fee_octa_allowed_per_epoch_per_pool } =
                    borrow_global<TransactionFeeConfig>(@aptos_framework);
                *max_fee_octa_allowed_per_epoch_per_pool
            } else {
                MAX_U64 as u64
            };
        let pending_fee_by_validator =
            &mut borrow_global_mut<PendingTransactionFee>(@aptos_framework).pending_fee_by_validator;
        if (!pending_fee_by_validator.contains(&validator_index)) {
            return 0
        };

        let fee_octa = pending_fee_by_validator.remove(&validator_index).read();
        if (fee_octa > fee_limit) {
            fee_limit
        } else {
            fee_octa
        }
    }

    /// Assuming we are in a middle of a reconfiguration (no matter it is immediate or async), get its start time.
    fun get_reconfig_start_time_secs(): u64 {
        if (reconfiguration_state::is_initialized()) {
            reconfiguration_state::start_time_secs()
        } else {
            timestamp::now_seconds()
        }
    }

    /// Calculate the rewards amount for a stake pool based on performance and rate.
    ///
    /// Formula: reward = stake_amount * rewards_rate * num_successful_proposals
    ///                   / (rewards_rate_denominator * num_total_proposals)
    ///
    /// The performance multiplier (num_successful / num_total) penalizes validators that
    /// miss proposals. A validator that proposes 90% of its assigned slots earns 90% of
    /// the maximum reward for its stake weight.
    ///
    /// All arithmetic uses u128 to avoid overflow before the final division.
    fun calculate_rewards_amount(
        stake_amount: u64,
        num_successful_proposals: u64,
        num_total_proposals: u64,
        rewards_rate: u64,
        rewards_rate_denominator: u64
    ): u64 {
        spec {
            // The following condition must hold because
            // (1) num_successful_proposals <= num_total_proposals, and
            // (2) `num_total_proposals` cannot be larger than 86400, the maximum number of proposals
            //     in a day (1 proposal per second), and `num_total_proposals` is reset to 0 every epoch.
            assume num_successful_proposals * MAX_REWARDS_RATE <= MAX_U64;
        };
        // The rewards amount is equal to (stake amount * rewards rate * performance multiplier).
        // We do multiplication in u128 before division to avoid the overflow and minimize the rounding error.
        let rewards_numerator =
            (stake_amount as u128) * (rewards_rate as u128)
                * (num_successful_proposals as u128);
        let rewards_denominator =
            (rewards_rate_denominator as u128) * (num_total_proposals as u128);
        if (rewards_denominator > 0) {
            ((rewards_numerator / rewards_denominator) as u64)
        } else { 0 }
    }

    fun append<T>(v1: &mut vector<T>, v2: &mut vector<T>) {
        while (!v2.is_empty()) {
            v1.push_back(v2.pop_back());
        }
    }

    fun find_validator(v: &vector<ValidatorInfo>, addr: address): Option<u64> {
        let i = 0;
        let len = v.length();
        while ({
            spec {
                invariant !(exists j in 0..i: v[j].addr == addr);
            };
            i < len
        }) {
            if (v.borrow(i).addr == addr) {
                return option::some(i)
            };
            i += 1;
        };
        option::none()
    }

    fun get_validator_addresses(
        validators: &vector<ValidatorInfo>,
        offset: u64,
        limit: u64
    ): vector<address> {
        let addresses = vector[];
        let len = validators.length();
        let i = offset;
        let end = range_end(offset, limit, len);
        while (i < end) {
            addresses.push_back(validators.borrow(i).addr);
            i += 1;
        };
        addresses
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

    fun generate_validator_info(
        addr: address, config: ValidatorConfig
    ): ValidatorInfo {
        let voting_power = staking_registry::get_validator_total_power(addr);
        ValidatorInfo { addr, voting_power, config }
    }

    fun cap_validator_info_voting_power_for_epoch(
        info: ValidatorInfo,
        maximum_stake: u64,
        baseline_voting_power: u64,
        max_voting_power_increase: u128,
        used_voting_power_increase: u128,
    ): ValidatorInfo {
        ValidatorInfo {
            addr: info.addr,
            voting_power: cap_voting_power_for_epoch(
                info.voting_power,
                maximum_stake,
                baseline_voting_power,
                max_voting_power_increase,
                used_voting_power_increase,
            ),
            config: info.config,
        }
    }

    fun cap_voting_power_for_epoch(
        raw_voting_power: u64,
        maximum_stake: u64,
        baseline_voting_power: u64,
        max_voting_power_increase: u128,
        used_voting_power_increase: u128,
    ): u64 {
        let capped_by_maximum = min_u64(raw_voting_power, maximum_stake);
        if (capped_by_maximum <= baseline_voting_power) {
            return capped_by_maximum
        };

        let remaining_increase =
            if (used_voting_power_increase >= max_voting_power_increase) {
                0
            } else {
                max_voting_power_increase - used_voting_power_increase
            };
        let allowed_voting_power =
            (baseline_voting_power as u128) + remaining_increase;
        if ((capped_by_maximum as u128) > allowed_voting_power) {
            allowed_voting_power as u64
        } else {
            capped_by_maximum
        }
    }

    fun calculate_max_voting_power_increase(
        total_voting_power: u128,
        voting_power_increase_limit: u64,
    ): u128 {
        if (total_voting_power == 0) {
            MAX_U64
        } else {
            (total_voting_power * (voting_power_increase_limit as u128)) / 100
        }
    }

    fun voting_power_increase(
        baseline_voting_power: u64,
        new_voting_power: u64,
    ): u128 {
        if (new_voting_power > baseline_voting_power) {
            ((new_voting_power - baseline_voting_power) as u128)
        } else {
            0
        }
    }

    fun min_u64(a: u64, b: u64): u64 {
        if (a < b) { a } else { b }
    }

    fun update_voting_power_increase(increase_amount: u64) acquires ValidatorSet {
        let validator_set = borrow_global_mut<ValidatorSet>(@aptos_framework);
        let voting_power_increase_limit =
            (
                staking_config::get_voting_power_increase_limit(&staking_config::get()) as u128
            );
        validator_set.total_joining_power +=(increase_amount as u128);

        // Only validator voting power increase if the current validator set's voting power > 0.
        if (validator_set.total_voting_power > 0) {
            assert!(
                validator_set.total_joining_power
                    <= validator_set.total_voting_power * voting_power_increase_limit
                        / 100,
                error::invalid_argument(EVOTING_POWER_INCREASE_EXCEEDS_LIMIT)
            );
        }
    }

    fun assert_stake_pool_exists(pool_address: address) {
        assert!(
            stake_pool_exists(pool_address),
            error::invalid_argument(ESTAKE_POOL_DOES_NOT_EXIST)
        );
    }

    /// This provides an ACL for Testnet purposes. In testnet, everyone is a whale, a whale can be a validator.
    /// This allows a testnet to bring additional entities into the validator set without compromising the
    /// security of the testnet. This will NOT be enabled in Mainnet.
    struct AllowedValidators has key {
        accounts: vector<address>
    }

    public fun configure_allowed_validators(
        aptos_framework: &signer, accounts: vector<address>
    ) acquires AllowedValidators {
        let aptos_framework_address = signer::address_of(aptos_framework);
        system_addresses::assert_aptos_framework(aptos_framework);
        if (!exists<AllowedValidators>(aptos_framework_address)) {
            move_to(aptos_framework, AllowedValidators { accounts });
        } else {
            let allowed = borrow_global_mut<AllowedValidators>(aptos_framework_address);
            allowed.accounts = accounts;
        }
    }

    fun is_allowed(account: address): bool acquires AllowedValidators {
        if (!exists<AllowedValidators>(@aptos_framework)) { true }
        else {
            let allowed = borrow_global<AllowedValidators>(@aptos_framework);
            allowed.accounts.contains(&account)
        }
    }

    fun assert_owner_cap_exists(owner: address) {
        assert!(
            exists<OwnerCapability>(owner),
            error::not_found(EOWNER_CAP_NOT_FOUND)
        );
    }

    fun assert_reconfig_not_in_progress() {
        assert!(
            !reconfiguration_state::is_in_progress(),
            error::invalid_state(ERECONFIGURATION_IN_PROGRESS)
        );
    }

    #[test_only]
    use aptos_framework::topo_coin;
    use aptos_std::bls12381::proof_of_possession_from_bytes;
    use aptos_framework::reconfiguration_state;
    use aptos_framework::validator_consensus_info;
    #[test_only]
    const EPOCH_DURATION: u64 = 60;

    #[test_only]
    const LOCKUP_CYCLE_SECONDS: u64 = 3600;

    #[test_only]
    public fun initialize_for_test(aptos_framework: &signer) acquires TopoCoinCapabilities {
        reconfiguration_state::initialize(aptos_framework);
        initialize_for_test_custom(
            aptos_framework,
            100,
            10000,
            LOCKUP_CYCLE_SECONDS,
            true,
            1,
            100,
            1000000
        );
        // In the test environment, the periodical_reward_rate_decrease feature is initially turned off.
        features::change_feature_flags_for_testing(
            aptos_framework,
            vector[],
            vector[features::get_periodical_reward_rate_decrease_feature()]
        );
    }

    // Convenient function for setting up all required stake initializations.
    #[test_only]
    public fun initialize_for_test_custom(
        aptos_framework: &signer,
        minimum_stake: u64,
        maximum_stake: u64,
        recurring_lockup_secs: u64,
        allow_validator_set_change: bool,
        rewards_rate_numerator: u64,
        rewards_rate_denominator: u64,
        voting_power_increase_limit: u64
    ) acquires TopoCoinCapabilities {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        reconfiguration_state::initialize(aptos_framework);
        if (!exists<ValidatorSet>(@aptos_framework)) {
            initialize(aptos_framework);
        };
        staking_config::initialize_for_test(
            aptos_framework,
            minimum_stake,
            maximum_stake,
            recurring_lockup_secs,
            allow_validator_set_change,
            rewards_rate_numerator,
            rewards_rate_denominator,
            voting_power_increase_limit
        );

        if (!exists<TopoCoinCapabilities>(@aptos_framework)) {
            let (burn_cap, mint_cap) = topo_coin::initialize_for_test(aptos_framework);
            store_topo_coin_mint_cap(aptos_framework, mint_cap);
            coin::destroy_burn_cap<TopoCoin>(burn_cap);
        };

        if (!staking_registry::registry_exists()) {
            staking_registry::store_topo_coin_mint_cap(
                aptos_framework,
                borrow_global<TopoCoinCapabilities>(@aptos_framework).mint_cap,
            );
            staking_registry::initialize(
                aptos_framework,
                1000000,
                1000,
                recurring_lockup_secs,
            );
        };

        if (poc_power_store::get_operator() == @0x0) {
            poc_power_store::initialize_power_store(aptos_framework, @aptos_framework);
        };

        // In the test environment, the periodical_reward_rate_decrease feature is initially turned off.
        features::change_feature_flags_for_testing(
            aptos_framework,
            vector[],
            vector[features::get_periodical_reward_rate_decrease_feature()]
        );
    }

    #[test_only]
    public fun mint_and_add_stake(
        account: &signer, amount: u64
    ) acquires TopoCoinCapabilities {
        coin::register<TopoCoin>(account);
        let mint_cap = &borrow_global<TopoCoinCapabilities>(@aptos_framework).mint_cap;
        coin::deposit(signer::address_of(account), coin::mint(amount, mint_cap));
        staking_registry::deposit(account, amount);
        let account_address = signer::address_of(account);
        let (_, delegated_to, _) = staking_registry::get_user_stake_info(account_address);
        if (delegated_to == @0x0 && staking_registry::validator_exists(account_address)) {
            staking_registry::delegate(account, account_address);
        };
    }

    #[test_only]
    public fun initialize_test_validator(
        aptos_framework: &signer,
        public_key: &bls12381::PublicKey,
        proof_of_possession: &bls12381::ProofOfPossession,
        validator: &signer,
        amount: u64,
        should_join_validator_set: bool,
        should_end_epoch: bool
    ) acquires AllowedValidators, TopoCoinCapabilities, PendingTransactionFee, StakePool, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        let validator_address = signer::address_of(validator);
        account::create_account_for_test(validator_address);

        let pk_bytes = bls12381::public_key_to_bytes(public_key);
        let pop_bytes = bls12381::proof_of_possession_to_bytes(proof_of_possession);
        initialize_validator(
            validator,
            pk_bytes,
            pop_bytes,
            vector::empty(),
            vector::empty()
        );

        if (amount > 0) {
            let genesis_power =
                staking_registry::calculate_genesis_power_from_stake(amount);
            poc_power_store::set_genesis_committed_power(
                aptos_framework,
                validator_address,
                genesis_power,
            );
            mint_and_add_stake(validator, amount);
        };

        if (should_join_validator_set) {
            join_validator_set(validator, validator_address);
        };
        if (should_end_epoch) {
            end_epoch();
        };
    }

    #[test_only]
    public fun generate_identity(): (
        bls12381::SecretKey, bls12381::PublicKey, bls12381::ProofOfPossession
    ) {
        let (sk, pkpop) = bls12381::generate_keys();
        let pop = bls12381::generate_proof_of_possession(&sk);
        let unvalidated_pk = bls12381::public_key_with_pop_to_normal(&pkpop);
        (sk, unvalidated_pk, pop)
    }

    #[
        test(
            aptos_framework = @0x1,
            validator_1 = @0x123,
            validator_2 = @0x234,
            validator_3 = @0x345
        )
    ]
    public entry fun test_multiple_validators_join_and_leave(
        aptos_framework: &signer,
        validator_1: &signer,
        validator_2: &signer,
        validator_3: &signer
    ) acquires AllowedValidators, TopoCoinCapabilities, PendingTransactionFee, StakePool, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        let validator_1_address = signer::address_of(validator_1);
        let validator_2_address = signer::address_of(validator_2);
        let validator_3_address = signer::address_of(validator_3);

        initialize_for_test_custom(
            aptos_framework,
            100,
            10000,
            LOCKUP_CYCLE_SECONDS,
            true,
            1,
            100,
            100
        );
        let (_sk_1, pk_1, pop_1) = generate_identity();
        let pk_1_bytes = bls12381::public_key_to_bytes(&pk_1);
        let (_sk_2, pk_2, pop_2) = generate_identity();
        let (_sk_3, pk_3, pop_3) = generate_identity();
        initialize_test_validator(aptos_framework, &pk_1, &pop_1, validator_1, 100, false, false);
        initialize_test_validator(aptos_framework, &pk_2, &pop_2, validator_2, 100, false, false);
        initialize_test_validator(aptos_framework, &pk_3, &pop_3, validator_3, 100, false, false);

        // Validator 1 and 2 join the validator set.
        join_validator_set(validator_2, validator_2_address);
        join_validator_set(validator_1, validator_1_address);
        end_epoch();
        assert!(get_validator_state(validator_1_address) == VALIDATOR_STATUS_ACTIVE, 0);
        assert!(get_validator_state(validator_2_address) == VALIDATOR_STATUS_ACTIVE, 1);

        // Validator indices is the reverse order of the joining order.
        let validator_set = borrow_global<ValidatorSet>(@aptos_framework);
        let validator_config_1 = validator_set.active_validators.borrow(0);
        assert!(validator_config_1.addr == validator_1_address, 2);
        assert!(validator_config_1.config.validator_index == 0, 3);
        let validator_config_2 = validator_set.active_validators.borrow(1);
        assert!(validator_config_2.addr == validator_2_address, 4);
        assert!(validator_config_2.config.validator_index == 1, 5);

        // Validator 1 rotates consensus key. Validator 2 leaves. Validator 3 joins.
        let (_sk_1b, pk_1b, pop_1b) = generate_identity();
        let pk_1b_bytes = bls12381::public_key_to_bytes(&pk_1b);
        let pop_1b_bytes = bls12381::proof_of_possession_to_bytes(&pop_1b);
        rotate_consensus_key(
            validator_1,
            validator_1_address,
            pk_1b_bytes,
            pop_1b_bytes
        );
        leave_validator_set(validator_2, validator_2_address);
        join_validator_set(validator_3, validator_3_address);
        // Validator 2 is not effectively removed until next epoch.
        assert!(
            get_validator_state(validator_2_address)
                == VALIDATOR_STATUS_PENDING_INACTIVE,
            6
        );
        assert!(
            borrow_global<ValidatorSet>(@aptos_framework).pending_inactive.borrow(0).addr ==
            validator_2_address,
            0
        );
        // Validator 3 is not effectively added until next epoch.
        assert!(
            get_validator_state(validator_3_address) == VALIDATOR_STATUS_PENDING_ACTIVE,
            7
        );
        assert!(
            borrow_global<ValidatorSet>(@aptos_framework).pending_active.borrow(0).addr
                == validator_3_address,
            0
        );
        assert!(
            borrow_global<ValidatorSet>(@aptos_framework).active_validators.borrow(0).config
            .consensus_pubkey == pk_1_bytes,
            0
        );

        // Changes applied after new epoch
        end_epoch();
        assert!(get_validator_state(validator_1_address) == VALIDATOR_STATUS_ACTIVE, 8);
        assert!(get_validator_index(validator_1_address) == 0, 11);
        assert!(get_validator_state(validator_2_address) == VALIDATOR_STATUS_INACTIVE, 9);
        // The validator index of validator 2 stays the same but this doesn't matter as the next time they rejoin the
        // validator set, their index will get set correctly.
        assert!(get_validator_index(validator_2_address) == 1, 12);
        assert!(get_validator_state(validator_3_address) == VALIDATOR_STATUS_ACTIVE, 10);
        assert!(get_validator_index(validator_3_address) == 1, 13);
        assert!(
            borrow_global<ValidatorSet>(@aptos_framework).active_validators.borrow(0).config
            .consensus_pubkey == pk_1b_bytes,
            0
        );

    }

    #[
        test(
            aptos_framework = @aptos_framework,
            validator_1 = @aptos_framework,
            validator_2 = @0x2,
            validator_3 = @0x3,
            validator_4 = @0x4,
            validator_5 = @0x5
        )
    ]
    public entry fun test_staking_validator_index(
        aptos_framework: &signer,
        validator_1: &signer,
        validator_2: &signer,
        validator_3: &signer,
        validator_4: &signer,
        validator_5: &signer
    ) acquires AllowedValidators, TopoCoinCapabilities, PendingTransactionFee, StakePool, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        let v1_addr = signer::address_of(validator_1);
        let v2_addr = signer::address_of(validator_2);
        let v3_addr = signer::address_of(validator_3);
        let v4_addr = signer::address_of(validator_4);
        let v5_addr = signer::address_of(validator_5);

        initialize_for_test(aptos_framework);
        // This test focuses on validator index churn, not power decay across periods.
        poc_power_store::set_retention_bps_per_period(aptos_framework, 10000);

        let (_sk_1, pk_1, pop_1) = generate_identity();
        let (_sk_2, pk_2, pop_2) = generate_identity();
        let (_sk_3, pk_3, pop_3) = generate_identity();
        let (_sk_4, pk_4, pop_4) = generate_identity();
        let (_sk_5, pk_5, pop_5) = generate_identity();

        initialize_test_validator(aptos_framework, &pk_1, &pop_1, validator_1, 100, false, false);
        initialize_test_validator(aptos_framework, &pk_2, &pop_2, validator_2, 100, false, false);
        initialize_test_validator(aptos_framework, &pk_3, &pop_3, validator_3, 100, false, false);
        initialize_test_validator(aptos_framework, &pk_4, &pop_4, validator_4, 100, false, false);
        initialize_test_validator(aptos_framework, &pk_5, &pop_5, validator_5, 100, false, false);

        join_validator_set(validator_3, v3_addr);
        end_epoch();
        assert!(get_validator_index(v3_addr) == 0, 0);

        join_validator_set(validator_4, v4_addr);
        end_epoch();
        assert!(get_validator_index(v3_addr) == 0, 1);
        assert!(get_validator_index(v4_addr) == 1, 2);

        join_validator_set(validator_1, v1_addr);
        join_validator_set(validator_2, v2_addr);
        // pending_inactive is appended in reverse order
        end_epoch();
        assert!(get_validator_index(v3_addr) == 0, 6);
        assert!(get_validator_index(v4_addr) == 1, 7);
        assert!(get_validator_index(v2_addr) == 2, 8);
        assert!(get_validator_index(v1_addr) == 3, 9);

        join_validator_set(validator_5, v5_addr);
        end_epoch();
        assert!(get_validator_index(v3_addr) == 0, 10);
        assert!(get_validator_index(v4_addr) == 1, 11);
        assert!(get_validator_index(v2_addr) == 2, 12);
        assert!(get_validator_index(v1_addr) == 3, 13);
        assert!(get_validator_index(v5_addr) == 4, 14);

        // after swap remove, it's 3,4,2,5
        leave_validator_set(validator_1, v1_addr);
        // after swap remove, it's 5,4,2
        leave_validator_set(validator_3, v3_addr);
        end_epoch();

        assert!(get_validator_index(v5_addr) == 0, 15);
        assert!(get_validator_index(v4_addr) == 1, 16);
        assert!(get_validator_index(v2_addr) == 2, 17);
    }

    #[test(
        vm = @0x0, aptos_framework = @0x1, validator_0 = @0x123, validator_1 = @0x234
    )]
    public entry fun test_transaction_fee(
        vm: &signer,
        aptos_framework: &signer,
        validator_0: &signer,
        validator_1: &signer
    ) acquires AllowedValidators, TopoCoinCapabilities, PendingTransactionFee, StakePool, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        initialize_for_test(aptos_framework);
        initialize_pending_transaction_fee(aptos_framework);
        features::change_feature_flags_for_testing(
            aptos_framework,
            vector[features::get_distribute_transaction_fee_feature()],
            vector[]
        );
        let address_0 = signer::address_of(validator_0);
        let address_1 = signer::address_of(validator_1);
        let (_sk_0, pk_0, pop_0) = generate_identity();
        let (_sk_1, pk_1, pop_1) = generate_identity();
        initialize_test_validator(aptos_framework, &pk_0, &pop_0, validator_0, 100, true, false);
        initialize_test_validator(aptos_framework, &pk_1, &pop_1, validator_1, 100, true, true);
        assert!(
            borrow_global<ValidatorSet>(@aptos_framework).active_validators.length()
                == 2,
            0
        );

        let validator_to_remove = signer::address_of(validator_0);
        remove_validators(aptos_framework, &vector[validator_to_remove]);
        assert!(
            borrow_global<ValidatorSet>(@aptos_framework).active_validators.length()
                == 1,
            0
        );

        // validator 0 is pending inactive, validator 1 is active, both should get fee.

        {
            let fee_table =
                &borrow_global<PendingTransactionFee>(@aptos_framework).pending_fee_by_validator;
            assert!(fee_table.contains(&0), 0);
            assert!(fee_table.contains(&1), 0);
        };

        record_fee(vm, vector[], vector[]);
        record_fee(
            vm,
            vector[get_validator_index(address_0)],
            vector[1]
        );
        record_fee(
            vm,
            vector[get_validator_index(address_1)],
            vector[2]
        );
        record_fee(
            vm,
            vector[get_validator_index(address_0), get_validator_index(address_1)],
            vector[10, 220]
        );

        {
            let fee_table =
                &borrow_global<PendingTransactionFee>(@aptos_framework).pending_fee_by_validator;
            assert!(
                fee_table.borrow(&get_validator_index(address_0)).read() == 11,
                0
            );
            assert!(
                fee_table.borrow(&get_validator_index(address_1)).read() == 222,
                0
            );
            end_epoch();

            assert!(
                event::was_event_emitted(
                    &DistributeTransactionFee { pool_address: address_0, fee_amount: 11 }
                ),
                0
            );
            assert!(
                event::was_event_emitted(
                    &DistributeTransactionFee { pool_address: address_1, fee_amount: 222 }
                ),
                0
            );
        };

        let fee_table =
            &borrow_global<PendingTransactionFee>(@aptos_framework).pending_fee_by_validator;
        // validator 1 is at index 0 now.
        assert!(fee_table.contains(&0), 0);
        assert!(!fee_table.contains(&1), 0);

        assert!(
            event::emitted_events<DistributeTransactionFee>().length() == 2,
            0
        );
        // No more event is emitted at this epoch ending.
        end_epoch();
        assert!(
            event::emitted_events<DistributeTransactionFee>().length() == 2,
            0
        );
    }

    #[test_only]
    public fun end_epoch() acquires PendingTransactionFee, StakePool, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        // Set the number of blocks to 1, to give out rewards to non-failing validators.
        let validator_perf = borrow_global_mut<ValidatorPerformance>(@aptos_framework);
        validator_perf.validators.for_each_mut(|validator| {
            let validator: &mut IndividualValidatorPerformance = validator;
            if (validator.successful_proposals + validator.failed_proposals < 1) {
                validator.successful_proposals = 1;
            };
        });
        timestamp::fast_forward_seconds(EPOCH_DURATION);
        reconfiguration_state::on_reconfig_start();
        let actual =
            next_validator_consensus_infos().map(|i| validator_consensus_info::get_addr(&i));
        on_new_epoch();
        let expected =
            cur_validator_consensus_infos().map(|i| validator_consensus_info::get_addr(&i));
        assert!(expected == actual, 999);
        reconfiguration_state::on_reconfig_finish();
    }

    #[test_only]
    /// Override the current epoch proposal counters for a validator.
    ///
    /// External test modules cannot mutate `ValidatorPerformance` directly because that
    /// resource is internal to the staking pipeline. This helper keeps tests on the real
    /// reward path while allowing them to deterministically configure the proposal inputs
    /// consumed by `next_validator_consensus_infos()` and `on_new_epoch()`.
    public fun set_validator_performance_for_test(
        validator_index: u64,
        successful_proposals: u64,
        failed_proposals: u64,
    ) acquires ValidatorPerformance {
        let validator_perf = borrow_global_mut<ValidatorPerformance>(@aptos_framework);
        let perf = validator_perf.validators.borrow_mut(validator_index);
        perf.successful_proposals = successful_proposals;
        perf.failed_proposals = failed_proposals;
    }

    #[test_only]
    /// Thin test-only wrapper around the production fee recording path.
    ///
    /// The real `record_fee` entry point is restricted to the VM via a friend-only call,
    /// which is correct for production but inaccessible from external Move test modules.
    /// This helper preserves the exact production logic and only opens a test harness hook.
    public fun record_fee_for_test(
        vm: &signer,
        fee_distribution_validator_indices: vector<u64>,
        fee_amounts_octa: vector<u64>,
    ) acquires PendingTransactionFee {
        record_fee(vm, fee_distribution_validator_indices, fee_amounts_octa);
    }

    #[test_only]
    /// Test-only probe for the emergency validator-set fallback event.
    ///
    /// External Move test modules cannot name `stake::ValidatorSetLivenessFallback`
    /// directly because the event type is private to this module. This helper lets
    /// e2e tests verify the production event without widening production visibility.
    public fun was_validator_set_liveness_fallback_emitted(
        minimum_stake: u64,
        emergency_validator_count: u64,
        total_emergency_voting_power: u128,
    ): bool {
        event::was_event_emitted(
            &ValidatorSetLivenessFallback {
                minimum_stake,
                emergency_validator_count,
                total_emergency_voting_power,
            }
        )
    }

    #[test_only]
    /// Test-only probe for the transaction-fee distribution event.
    ///
    /// This mirrors the exact event emitted inside `on_new_epoch`, allowing external
    /// Move tests to validate the Rust-visible fee path without exposing the event type.
    public fun was_transaction_fee_distributed(
        pool_address: address,
        fee_amount: u64,
    ): bool {
        event::was_event_emitted(
            &DistributeTransactionFee {
                pool_address,
                fee_amount,
            }
        )
    }

    #[test(aptos_framework = @aptos_framework, validator = @0x123)]
    public entry fun test_validator_set_liveness_fallback(
        aptos_framework: &signer, validator: &signer
    ) acquires ValidatorSet, AllowedValidators, TopoCoinCapabilities, PendingTransactionFee, StakePool, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance {
        // Initialize with a minimum stake requirement (100)
        initialize_for_test(aptos_framework);
        let (_sk, pk, pop) = generate_identity();

        initialize_test_validator(aptos_framework, &pk, &pop, validator, 100, true, true);
        staking_config::update_required_stake(aptos_framework, 1000, 10000);
        end_epoch();

        // Verify that ValidatorSetLivenessFallback event was emitted
        let validator_set = &ValidatorSet[@aptos_framework];
        let (minimum_stake, _) =
            staking_config::get_required_stake(&staking_config::get());
        let expected_total_voting_power = validator_set.total_voting_power;
        let expected_validator_count = validator_set.active_validators.length();

        let expected_event = ValidatorSetLivenessFallback {
            minimum_stake,
            emergency_validator_count: expected_validator_count,
            total_emergency_voting_power: expected_total_voting_power
        };
        assert!(event::was_event_emitted(&expected_event), 0);
    }

    #[test(aptos_framework = @aptos_framework, validator = @0x123)]
    public entry fun test_next_validator_consensus_infos_includes_epoch_rewards(
        aptos_framework: &signer,
        validator: &signer,
    ) acquires ValidatorSet, AllowedValidators, TopoCoinCapabilities, PendingTransactionFee, StakePool, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance {
        initialize_for_test_custom(
            aptos_framework,
            100,
            10000,
            LOCKUP_CYCLE_SECONDS,
            true,
            0,
            100,
            1000000,
        );
        poc_power_store::set_retention_bps_per_period(aptos_framework, 10000);

        let validator_address = signer::address_of(validator);
        let (_sk, pk, pop) = generate_identity();
        initialize_test_validator(aptos_framework, &pk, &pop, validator, 100, true, false);
        // Keep the committed power above the current deposit cover so the next-epoch
        // simulation must include rewards to raise voting power from 100 to 120.
        poc_power_store::set_genesis_committed_power(
            aptos_framework,
            validator_address,
            120,
        );
        end_epoch();
        staking_config::update_rewards_rate(aptos_framework, 25, 100);
        {
            let validator_perf = borrow_global_mut<ValidatorPerformance>(@aptos_framework);
            let perf = validator_perf.validators.borrow_mut(0);
            perf.successful_proposals = 1;
            perf.failed_proposals = 0;
        };

        staking_config::update_required_stake(aptos_framework, 110, 10000);

        let next_infos = next_validator_consensus_infos();
        assert!(next_infos.length() == 1, 0);
        let next_info = next_infos.borrow(0);
        assert!(validator_consensus_info::get_addr(next_info) == validator_address, 1);
        assert!(validator_consensus_info::get_voting_power(next_info) == 120, 2);

        end_epoch();

        let cur_infos = cur_validator_consensus_infos();
        assert!(cur_infos.length() == 1, 3);
        let cur_info = cur_infos.borrow(0);
        assert!(validator_consensus_info::get_addr(cur_info) == validator_address, 4);
        assert!(validator_consensus_info::get_voting_power(cur_info) == 120, 5);
    }

    #[test(
        aptos_framework = @aptos_framework,
        validator = @0x123,
        delegator = @0x456
    )]
    #[expected_failure(abort_code = 0x1000f, location = aptos_framework::staking_registry)]
    public entry fun test_delegate_rejects_below_min_active_power(
        aptos_framework: &signer,
        validator: &signer,
        delegator: &signer,
    ) acquires AllowedValidators, TopoCoinCapabilities, PendingTransactionFee, StakePool, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        initialize_for_test(aptos_framework);

        let validator_address = signer::address_of(validator);
        let delegator_address = signer::address_of(delegator);
        let (_validator_sk, validator_pk, validator_pop) = generate_identity();
        initialize_test_validator(
            aptos_framework,
            &validator_pk,
            &validator_pop,
            validator,
            100,
            false,
            false,
        );

        staking_registry::set_active_power_thresholds(aptos_framework, 100, 8000);
        account::create_account_for_test(delegator_address);
        poc_power_store::set_genesis_committed_power(
            aptos_framework,
            delegator_address,
            99,
        );
        mint_and_add_stake(delegator, 99);

        staking_registry::delegate(delegator, validator_address);
    }

    #[test(
        aptos_framework = @aptos_framework,
        validator = @0x123,
        delegator = @0x456
    )]
    public entry fun test_force_undelegate_below_maintain_threshold(
        aptos_framework: &signer,
        validator: &signer,
        delegator: &signer,
    ) acquires AllowedValidators, TopoCoinCapabilities, PendingTransactionFee, StakePool, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        initialize_for_test(aptos_framework);

        let validator_address = signer::address_of(validator);
        let delegator_address = signer::address_of(delegator);
        let (_validator_sk, validator_pk, validator_pop) = generate_identity();
        initialize_test_validator(
            aptos_framework,
            &validator_pk,
            &validator_pop,
            validator,
            100,
            true,
            false,
        );

        account::create_account_for_test(delegator_address);
        poc_power_store::set_genesis_committed_power(
            aptos_framework,
            delegator_address,
            100,
        );
        mint_and_add_stake(delegator, 100);
        staking_registry::delegate(delegator, validator_address);
        staking_registry::set_active_power_thresholds(aptos_framework, 100, 8000);

        let target_period = poc_power_store::get_current_period() + 1;
        poc_power_store::stage_batch_update(
            aptos_framework,
            target_period,
            vector[delegator_address],
            vector[79u64],
        );

        end_epoch();
        let (_, delegated_to_before, _) = staking_registry::get_user_stake_info(delegator_address);
        assert!(delegated_to_before == validator_address, 0);

        while (poc_power_store::get_current_period() < target_period) {
            end_epoch();
        };
        let (_, delegated_to_after, cooldown_until_secs) =
            staking_registry::get_user_stake_info(delegator_address);
        assert!(delegated_to_after == @0x0, 1);
        assert!(cooldown_until_secs > 0, 2);
        assert!(staking_registry::get_effective_power(delegator_address) == 0, 3);
    }
}
