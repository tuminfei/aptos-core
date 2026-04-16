module aptos_framework::genesis {
    use std::error;
    use std::vector;

    use aptos_framework::account;
    use aptos_framework::aggregator_factory;
    use aptos_framework::topo_account;
    use aptos_framework::topo_coin::{Self, TopoCoin};
    use aptos_framework::topo_governance;
    use aptos_framework::block;
    use aptos_framework::chain_id;
    use aptos_framework::chain_status;
    use aptos_framework::coin;
    use aptos_framework::consensus_config;
    use aptos_framework::execution_config;
    use aptos_framework::create_signer::create_signer;
    use aptos_framework::gas_schedule;
    use aptos_framework::nonce_validation;
    use aptos_framework::poc_power_store;
    use aptos_framework::reconfiguration;
    use aptos_framework::stake;
    use aptos_framework::staking_registry;
    use aptos_framework::staking_config;
    use aptos_framework::state_storage;
    use aptos_framework::storage_gas;
    use aptos_framework::timestamp;
    use aptos_framework::transaction_fee;
    use aptos_framework::transaction_validation;
    use aptos_framework::version;

    const EDUPLICATE_ACCOUNT: u64 = 1;
    const DEFAULT_OCTAS_PER_POWER: u64 = 100_000;
    const DEFAULT_MAX_DELEGATORS_PER_VALIDATOR: u64 = 1000;

    struct AccountMap has drop {
        account_address: address,
        balance: u64,
    }

    struct ValidatorConfiguration has copy, drop {
        owner_address: address,
        operator_address: address,
        voter_address: address,
        stake_amount: u64,
        consensus_pubkey: vector<u8>,
        proof_of_possession: vector<u8>,
        network_addresses: vector<u8>,
        full_node_network_addresses: vector<u8>,
    }

    struct ValidatorConfigurationWithCommission has copy, drop {
        validator_config: ValidatorConfiguration,
        commission_percentage: u64,
        join_during_genesis: bool,
    }

    /// Genesis step 1: Initialize aptos framework account and core modules on chain.
    fun initialize(
        gas_schedule: vector<u8>,
        chain_id: u8,
        initial_version: u64,
        consensus_config: vector<u8>,
        execution_config: vector<u8>,
        epoch_interval_microsecs: u64,
        minimum_stake: u64,
        maximum_stake: u64,
        recurring_lockup_duration_secs: u64,
        allow_validator_set_change: bool,
        rewards_rate: u64,
        rewards_rate_denominator: u64,
        voting_power_increase_limit: u64,
    ) {
        // Initialize the aptos framework account. This is the account where system resources and modules will be
        // deployed to. This will be entirely managed by on-chain governance and no entities have the key or privileges
        // to use this account.
        let (aptos_framework_account, aptos_framework_signer_cap) = account::create_framework_reserved_account(@aptos_framework);
        // Initialize account configs on aptos framework account.
        account::initialize(&aptos_framework_account);

        transaction_validation::initialize(
            &aptos_framework_account,
            b"script_prologue",
            b"module_prologue",
            b"multi_agent_script_prologue",
            b"epilogue",
        );
        // Give the decentralized on-chain governance control over the core framework account.
        topo_governance::store_signer_cap(&aptos_framework_account, @aptos_framework, aptos_framework_signer_cap);

        // put reserved framework reserved accounts under aptos governance
        let framework_reserved_addresses = vector<address>[@0x2, @0x3, @0x4, @0x5, @0x6, @0x7, @0x8, @0x9, @0xa];
        while (!framework_reserved_addresses.is_empty()) {
            let address = framework_reserved_addresses.pop_back();
            let (_, framework_signer_cap) = account::create_framework_reserved_account(address);
            topo_governance::store_signer_cap(&aptos_framework_account, address, framework_signer_cap);
        };

        consensus_config::initialize(&aptos_framework_account, consensus_config);
        execution_config::set(&aptos_framework_account, execution_config);
        version::initialize(&aptos_framework_account, initial_version);
        stake::initialize(&aptos_framework_account);
        stake::initialize_pending_transaction_fee(&aptos_framework_account);
        timestamp::set_time_has_started(&aptos_framework_account);
        staking_config::initialize(
            &aptos_framework_account,
            minimum_stake,
            maximum_stake,
            recurring_lockup_duration_secs,
            allow_validator_set_change,
            rewards_rate,
            rewards_rate_denominator,
            voting_power_increase_limit,
        );
        storage_gas::initialize(&aptos_framework_account);
        gas_schedule::initialize(&aptos_framework_account, gas_schedule);

        // Ensure we can create aggregators for supply, but not enable it for common use just yet.
        aggregator_factory::initialize_aggregator_factory(&aptos_framework_account);

        chain_id::initialize(&aptos_framework_account, chain_id);
        reconfiguration::initialize(&aptos_framework_account);
        block::initialize(&aptos_framework_account, epoch_interval_microsecs);
        state_storage::initialize(&aptos_framework_account);
        nonce_validation::initialize(&aptos_framework_account);
    }

    /// Genesis step 2: Initialize Topo coin.
    fun initialize_topo_coin(aptos_framework: &signer) {
        let (burn_cap, mint_cap) = topo_coin::initialize(aptos_framework);

        coin::create_coin_conversion_map(aptos_framework);
        coin::create_pairing<TopoCoin>(aptos_framework);

        // Give stake module MintCapability<TopoCoin> so it can mint rewards.
        stake::store_topo_coin_mint_cap(aptos_framework, mint_cap);
        // Cache a copy for staking_registry so genesis can initialize it later without Rust changes.
        staking_registry::store_topo_coin_mint_cap(aptos_framework, mint_cap);
        // Give transaction_fee module BurnCapability<TopoCoin> so it can burn gas.
        transaction_fee::store_topo_coin_burn_cap(aptos_framework, burn_cap);
        // Give transaction_fee module MintCapability<TopoCoin> so it can mint refunds.
        transaction_fee::store_topo_coin_mint_cap(aptos_framework, mint_cap);
    }

    /// Only called for testnets and e2e tests.
    public fun initialize_core_resources_and_topo_coin(
        aptos_framework: &signer,
        core_resources_auth_key: vector<u8>,
    ) {
        let (burn_cap, mint_cap) = topo_coin::initialize(aptos_framework);

        coin::create_coin_conversion_map(aptos_framework);
        coin::create_pairing<TopoCoin>(aptos_framework);

        // Give stake module MintCapability<TopoCoin> so it can mint rewards.
        stake::store_topo_coin_mint_cap(aptos_framework, mint_cap);
        // Cache a copy for staking_registry so test-only flows can opt into the new path.
        staking_registry::store_topo_coin_mint_cap(aptos_framework, mint_cap);
        // Give transaction_fee module BurnCapability<TopoCoin> so it can burn gas.
        transaction_fee::store_topo_coin_burn_cap(aptos_framework, burn_cap);
        // Give transaction_fee module MintCapability<TopoCoin> so it can mint refunds.
        transaction_fee::store_topo_coin_mint_cap(aptos_framework, mint_cap);

        let core_resources = account::create_account(@core_resources);
        account::rotate_authentication_key_internal(&core_resources, core_resources_auth_key);
        topo_account::register_topo(&core_resources); // registers TOPO store
        topo_coin::configure_accounts_for_test(aptos_framework, &core_resources, mint_cap);
    }

    fun create_accounts(aptos_framework: &signer, accounts: vector<AccountMap>) {
        let unique_accounts = vector::empty();
        accounts.for_each_ref(|account_map| {
            let account_map: &AccountMap = account_map;
            assert!(
                !unique_accounts.contains(&account_map.account_address),
                error::already_exists(EDUPLICATE_ACCOUNT),
            );
            unique_accounts.push_back(account_map.account_address);

            create_account(
                aptos_framework,
                account_map.account_address,
                account_map.balance,
            );
        });
    }

    /// This creates an funds an account if it doesn't exist.
    /// If it exists, it just returns the signer.
    fun create_account(aptos_framework: &signer, account_address: address, balance: u64): signer {
        let account = if (account::exists_at(account_address)) {
            create_signer(account_address)
        } else {
            account::create_account(account_address)
        };

        if (coin::balance<TopoCoin>(account_address) == 0) {
            coin::register<TopoCoin>(&account);
            topo_coin::mint(aptos_framework, account_address, balance);
        };
        account
    }

    fun ensure_poc_staking_initialized(aptos_framework: &signer) {
        if (poc_power_store::get_operator() == @0x0) {
            poc_power_store::initialize(aptos_framework, @aptos_framework);
        };

        let recurring_lockup_duration =
            staking_config::get_recurring_lockup_duration(&staking_config::get());
        let governance_voting_duration =
            if (topo_governance::has_governance_config()) {
                topo_governance::get_voting_duration_secs()
            } else {
                0
            };
        let cooldown_secs =
            if (recurring_lockup_duration > governance_voting_duration) {
                recurring_lockup_duration
            } else {
                governance_voting_duration
            };
        staking_registry::initialize(
            aptos_framework,
            DEFAULT_OCTAS_PER_POWER,
            DEFAULT_MAX_DELEGATORS_PER_VALIDATOR,
            cooldown_secs,
        );
    }

    fun create_initialize_validators_with_commission(
        aptos_framework: &signer,
        validators: vector<ValidatorConfigurationWithCommission>,
    ) {
        ensure_poc_staking_initialized(aptos_framework);
        validators.for_each_ref(|validator| {
            let validator: &ValidatorConfigurationWithCommission = validator;
            create_initialize_validator(aptos_framework, validator);
        });

        // Destroy the aptos framework account's ability to mint coins now that we're done with setting up the initial
        // validators.
        topo_coin::destroy_mint_cap(aptos_framework);

        stake::on_new_epoch();
    }

    /// Sets up the initial validator set for the network.
    /// The validator "owner" accounts, and their authentication
    /// Addresses (and keys) are encoded in the `owners`
    /// Each validator signs consensus messages with the private key corresponding to the Ed25519
    /// public key in `consensus_pubkeys`.
    /// Finally, each validator must specify the network address
    /// (see types/src/network_address/mod.rs) for itself and its full nodes.
    ///
    /// Network address fields are a vector per account, where each entry is a vector of addresses
    /// encoded in a single BCS byte array.
    fun create_initialize_validators(aptos_framework: &signer, validators: vector<ValidatorConfiguration>) {
        let validators_with_commission = vector::empty();
        validators.for_each_reverse(|validator| {
            let validator_with_commission = ValidatorConfigurationWithCommission {
                validator_config: validator,
                commission_percentage: 0,
                join_during_genesis: true,
            };
            validators_with_commission.push_back(validator_with_commission);
        });

        create_initialize_validators_with_commission(aptos_framework, validators_with_commission);
    }

    fun create_initialize_validator(
        aptos_framework: &signer,
        commission_config: &ValidatorConfigurationWithCommission,
    ) {
        let validator = &commission_config.validator_config;
        let commission_percentage = commission_config.commission_percentage;
        let genesis_power =
            staking_registry::calculate_genesis_power_from_stake(validator.stake_amount);

        let owner = &create_account(aptos_framework, validator.owner_address, validator.stake_amount);
        create_account(aptos_framework, validator.operator_address, 0);

        stake::initialize_stake_owner(
            owner,
            0,
            validator.operator_address,
        );
        let pool_address = validator.owner_address;

        if (!staking_registry::validator_exists(pool_address)) {
            staking_registry::register_validator_for_genesis(
                validator.owner_address,
                pool_address,
                commission_percentage * 100,
            );
        };
        poc_power_store::set_genesis_committed_power(
            aptos_framework,
            validator.owner_address,
            genesis_power,
        );
        staking_registry::deposit(owner, validator.stake_amount);
        staking_registry::delegate(owner, pool_address);

        if (commission_config.join_during_genesis) {
            initialize_validator(pool_address, validator);
        };
    }

    fun initialize_validator(pool_address: address, validator: &ValidatorConfiguration) {
        let operator = &create_signer(validator.operator_address);

        stake::rotate_consensus_key(
            operator,
            pool_address,
            validator.consensus_pubkey,
            validator.proof_of_possession,
        );
        stake::update_network_and_fullnode_addresses(
            operator,
            pool_address,
            validator.network_addresses,
            validator.full_node_network_addresses,
        );
        stake::join_validator_set_internal(operator, pool_address);
    }

    /// The last step of genesis.
    fun set_genesis_end(aptos_framework: &signer) {
        chain_status::set_genesis_end(aptos_framework);
    }

    #[verify_only]
    use std::features;

    #[verify_only]
    fun initialize_for_verification(
        gas_schedule: vector<u8>,
        chain_id: u8,
        initial_version: u64,
        consensus_config: vector<u8>,
        execution_config: vector<u8>,
        epoch_interval_microsecs: u64,
        minimum_stake: u64,
        maximum_stake: u64,
        recurring_lockup_duration_secs: u64,
        allow_validator_set_change: bool,
        rewards_rate: u64,
        rewards_rate_denominator: u64,
        voting_power_increase_limit: u64,
        aptos_framework: &signer,
        min_voting_threshold: u128,
        required_proposer_stake: u64,
        voting_duration_secs: u64,
        accounts: vector<AccountMap>,
        validators: vector<ValidatorConfigurationWithCommission>
    ) {
        initialize(
            gas_schedule,
            chain_id,
            initial_version,
            consensus_config,
            execution_config,
            epoch_interval_microsecs,
            minimum_stake,
            maximum_stake,
            recurring_lockup_duration_secs,
            allow_validator_set_change,
            rewards_rate,
            rewards_rate_denominator,
            voting_power_increase_limit
        );
        features::change_feature_flags_for_verification(aptos_framework, vector[1, 2], vector[]);
        initialize_topo_coin(aptos_framework);
        topo_governance::initialize_for_verification(
            aptos_framework,
            min_voting_threshold,
            required_proposer_stake,
            voting_duration_secs
        );
        create_accounts(aptos_framework, accounts);
        create_initialize_validators_with_commission(aptos_framework, validators);
        set_genesis_end(aptos_framework);
    }

    #[test_only]
    public fun setup() {
        initialize(
            x"000000000000000000", // empty gas schedule
            4u8, // TESTING chain ID
            0,
            x"12",
            x"13",
            1,
            0,
            1,
            1,
            true,
            1,
            1,
            30,
        )
    }

    #[test]
    fun test_setup() {
        setup();
        assert!(account::exists_at(@aptos_framework), 1);
        assert!(account::exists_at(@0x2), 1);
        assert!(account::exists_at(@0x3), 1);
        assert!(account::exists_at(@0x4), 1);
        assert!(account::exists_at(@0x5), 1);
        assert!(account::exists_at(@0x6), 1);
        assert!(account::exists_at(@0x7), 1);
        assert!(account::exists_at(@0x8), 1);
        assert!(account::exists_at(@0x9), 1);
        assert!(account::exists_at(@0xa), 1);
    }

    #[test(aptos_framework = @0x1)]
    fun test_create_account(aptos_framework: &signer) {
        setup();
        initialize_topo_coin(aptos_framework);

        let addr = @0x121341; // 01 -> 0a are taken
        let test_signer_before = create_account(aptos_framework, addr, 15);
        let test_signer_after = create_account(aptos_framework, addr, 500);
        assert!(test_signer_before == test_signer_after, 0);
        assert!(coin::balance<TopoCoin>(addr) == 15, 1);
    }

    #[test(aptos_framework = @0x1)]
    fun test_create_accounts(aptos_framework: &signer) {
        setup();
        initialize_topo_coin(aptos_framework);

        // 01 -> 0a are taken
        let addr0 = @0x121341;
        let addr1 = @0x121345;

        let accounts = vector[
            AccountMap {
                account_address: addr0,
                balance: 12345,
            },
            AccountMap {
                account_address: addr1,
                balance: 67890,
            },
        ];

        create_accounts(aptos_framework, accounts);
        assert!(coin::balance<TopoCoin>(addr0) == 12345, 0);
        assert!(coin::balance<TopoCoin>(addr1) == 67890, 1);

        create_account(aptos_framework, addr0, 23456);
        assert!(coin::balance<TopoCoin>(addr0) == 12345, 2);
    }

    #[test(aptos_framework = @0x1, root = @0xabcd)]
    fun test_create_root_account(aptos_framework: &signer) {
        use aptos_framework::aggregator_factory;
        use aptos_framework::object;
        use aptos_framework::primary_fungible_store;
        use aptos_framework::fungible_asset::Metadata;
        use std::features;

        let feature = features::get_new_accounts_default_to_fa_apt_store_feature();
        features::change_feature_flags_for_testing(aptos_framework, vector[feature], vector[]);

        aggregator_factory::initialize_aggregator_factory_for_test(aptos_framework);

        let (burn_cap, mint_cap) = topo_coin::initialize(aptos_framework);
        topo_coin::ensure_initialized_with_topo_fa_metadata_for_test();

        let core_resources = account::create_account(@core_resources);
        topo_account::register_topo(&core_resources); // registers TOPO store

        let topo_metadata = object::address_to_object<Metadata>(@aptos_fungible_asset);
        assert!(primary_fungible_store::primary_store_exists(@core_resources, topo_metadata), 2);

        topo_coin::configure_accounts_for_test(aptos_framework, &core_resources, mint_cap);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }
}
