module aptos_framework::staking_registry {
    use std::error;
    use std::signer;

    use aptos_std::math64;
    use aptos_std::smart_table::{Self, SmartTable};
    use aptos_std::table::{Self, Table};

    use aptos_framework::coin::{Self, Coin, MintCapability};
    use aptos_framework::poc_power_store;
    use aptos_framework::system_addresses;
    use aptos_framework::timestamp;
    use aptos_framework::topo_coin::TopoCoin;

    friend aptos_framework::genesis;
    friend aptos_framework::stake;

    const ENOT_VALIDATOR: u64 = 1;
    const EALREADY_VALIDATOR: u64 = 2;
    const EALREADY_DELEGATED: u64 = 3;
    const ENOT_DELEGATED: u64 = 4;
    const EDEPOSIT_LOCKED: u64 = 5;
    const ECOOLDOWN_ACTIVE: u64 = 6;
    const EZERO_DEPOSIT: u64 = 7;
    const EMAX_DELEGATORS: u64 = 8;
    const EUSER_NOT_FOUND: u64 = 9;
    const EINVALID_COMMISSION: u64 = 10;
    const EREGISTRY_NOT_INITIALIZED: u64 = 11;
    const EMINT_CAP_NOT_STORED: u64 = 12;
    const EINVALID_CONFIG: u64 = 13;
    const EALREADY_INITIALIZED: u64 = 14;
    const EPOWER_BELOW_MIN_ACTIVE: u64 = 15;
    const DEFAULT_GENESIS_STAKE_POWER_MULTIPLIER: u64 = 1;
    const DEFAULT_MIN_ACTIVE_POWER: u64 = 1;
    const DEFAULT_FORCE_EXIT_POWER_BPS: u64 = 8000;
    const MAX_U64: u128 = 18446744073709551615;
    const BPS_DENOMINATOR: u64 = 10000;

    const VALIDATOR_STATUS_PENDING_ACTIVE: u64 = 1;
    const VALIDATOR_STATUS_ACTIVE: u64 = 2;
    const VALIDATOR_STATUS_PENDING_INACTIVE: u64 = 3;
    const VALIDATOR_STATUS_INACTIVE: u64 = 4;

    struct PendingMintCapability has key {
        mint_cap: MintCapability<TopoCoin>,
    }

    struct StakingRegistry has key {
        validators: Table<address, ValidatorPool>,
        users: Table<address, UserStakeInfo>,
        total_staked_power: u64,
        mint_cap: MintCapability<TopoCoin>,
        config: StakingRegistryConfig,
    }

    struct StakingRegistryConfig has copy, drop, store {
        octas_per_power: u64,
        max_delegators_per_validator: u64,
        cooldown_secs: u64,
        genesis_stake_power_multiplier: u64,
        min_active_power: u64,
        force_exit_power_bps: u64,
    }

    struct ValidatorPool has store {
        owner_address: address,
        delegator_index: SmartTable<address, u64>,
        delegator_list: vector<address>,
        commission_bps: u64,
        status: u64,
    }

    struct UserStakeInfo has store {
        deposit: Coin<TopoCoin>,
        delegated_to: address,
        cooldown_until_secs: u64,
    }

    #[view]
    public fun registry_exists(): bool {
        exists<StakingRegistry>(@aptos_framework)
    }

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

    #[view]
    public fun get_genesis_stake_power_multiplier(): u64 acquires StakingRegistry {
        if (!exists<StakingRegistry>(@aptos_framework)) {
            0
        } else {
            borrow_global<StakingRegistry>(@aptos_framework).config.genesis_stake_power_multiplier
        }
    }

    #[view]
    public fun get_min_active_power(): u64 acquires StakingRegistry {
        if (!exists<StakingRegistry>(@aptos_framework)) {
            0
        } else {
            borrow_global<StakingRegistry>(@aptos_framework).config.min_active_power
        }
    }

    #[view]
    public fun get_force_exit_power_bps(): u64 acquires StakingRegistry {
        if (!exists<StakingRegistry>(@aptos_framework)) {
            0
        } else {
            borrow_global<StakingRegistry>(@aptos_framework).config.force_exit_power_bps
        }
    }

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

    public entry fun deposit(
        user: &signer,
        amount: u64,
    ) acquires StakingRegistry {
        assert_registry_exists();
        assert!(amount > 0, error::invalid_argument(EZERO_DEPOSIT));

        let user_address = signer::address_of(user);
        let registry = borrow_global_mut<StakingRegistry>(@aptos_framework);
        if (!registry.users.contains(user_address)) {
            registry.users.add(user_address, new_user_info());
        };

        let coins = coin::withdraw<TopoCoin>(user, amount);
        let info = registry.users.borrow_mut(user_address);
        coin::merge(&mut info.deposit, coins);
    }

    public entry fun delegate(
        user: &signer,
        validator_address: address,
    ) acquires StakingRegistry {
        assert_registry_exists();
        let user_address = signer::address_of(user);
        delegate_internal(user_address, validator_address);
    }

    public entry fun undelegate(
        user: &signer,
    ) acquires StakingRegistry {
        assert_registry_exists();
        let user_address = signer::address_of(user);
        undelegate_internal(user_address);
    }

    public entry fun withdraw_deposit(
        user: &signer,
    ) acquires StakingRegistry {
        assert_registry_exists();
        let user_address = signer::address_of(user);
        let coins = extract_withdrawable_deposit(user_address);
        coin::deposit<TopoCoin>(user_address, coins);
    }

    #[view]
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

    public(friend) fun get_validator_total_power_for_next_epoch(
        validator_address: address,
    ): u64 acquires StakingRegistry {
        if (!exists<StakingRegistry>(@aptos_framework)) {
            return 0
        };

        let registry = borrow_global<StakingRegistry>(@aptos_framework);
        if (!registry.validators.contains(validator_address)) {
            return 0
        };

        let maintain_threshold = calculate_force_exit_power(
            registry.config.min_active_power,
            registry.config.force_exit_power_bps,
        );
        let pool = registry.validators.borrow(validator_address);
        let total_power = 0u128;
        pool.delegator_list.for_each_ref(|member| {
            total_power += (get_user_effective_power_for_validator_for_next_epoch(
                registry,
                *member,
                validator_address,
                maintain_threshold,
            ) as u128);
        });
        total_power as u64
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

        if (!registry.users.contains(owner_address)) {
            registry.users.add(owner_address, new_user_info());
        };

        registry.validators.add(validator_address, ValidatorPool {
            owner_address,
            delegator_index: smart_table::new(),
            delegator_list: vector[],
            commission_bps,
            status: VALIDATOR_STATUS_INACTIVE,
        });
    }

    fun delegate_internal(
        user_address: address,
        validator_address: address,
    ) acquires StakingRegistry {
        let registry = borrow_global_mut<StakingRegistry>(@aptos_framework);
        assert!(
            registry.validators.contains(validator_address),
            error::invalid_argument(ENOT_VALIDATOR),
        );

        if (!registry.users.contains(user_address)) {
            registry.users.add(user_address, new_user_info());
        };

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
        if (!registry.users.contains(user)) {
            return 0
        };

        let info = registry.users.borrow(user);
        if (info.delegated_to != validator_address) {
            return 0
        };

        calculate_effective_power(info, registry.config.octas_per_power, user)
    }

    fun get_user_effective_power_for_validator_for_next_epoch(
        registry: &StakingRegistry,
        user: address,
        validator_address: address,
        maintain_threshold: u64,
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
        let deposit_octas = coin::value(&info.deposit);
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
