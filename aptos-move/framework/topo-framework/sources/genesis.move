module topo_framework::genesis {
    use std::error;
    use std::fixed_point32;
    use std::vector;

    use topo_std::simple_map;

    use topo_framework::account;
    use topo_framework::aggregator_factory;
    use topo_framework::topo_account;
    use topo_framework::topo_coin::{Self, TopoCoin};
    use topo_framework::topo_governance;
    use topo_framework::block;
    use topo_framework::chain_id;
    use topo_framework::chain_status;
    use topo_framework::coin;
    use topo_framework::consensus_config;
    use topo_framework::execution_config;
    use topo_framework::create_signer::create_signer;
    use topo_framework::gas_schedule;
    use topo_framework::transaction_limits;
    use topo_framework::nonce_validation;
    use topo_framework::reconfiguration;
    use topo_framework::stake;
    use topo_framework::staking_contract;
    use topo_framework::staking_config;
    use topo_framework::state_storage;
    use topo_framework::storage_gas;
    use topo_framework::system_addresses;
    use topo_framework::timestamp;
    use topo_framework::transaction_fee;
    use topo_framework::transaction_validation;
    use topo_framework::version;
    use topo_framework::vesting;

    const EDUPLICATE_ACCOUNT: u64 = 1;
    const EACCOUNT_DOES_NOT_EXIST: u64 = 2;
    const EINVALID_INITIAL_RAW_POWER: u64 = 3;

    /// PoC 创世的初始算力周期长度，后续可通过治理调整未来周期。
    const POC_POWER_PERIOD_IN_EPOCHS: u64 = 60;

    struct AccountMap has drop {
        account_address: address,
        balance: u64,
    }

    struct EmployeeAccountMap has copy, drop {
        accounts: vector<address>,
        validator: ValidatorConfigurationWithCommission,
        vesting_schedule_numerator: vector<u64>,
        vesting_schedule_denominator: u64,
        beneficiary_resetter: address,
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
        let (topo_framework_account, topo_framework_signer_cap) = account::create_framework_reserved_account(@topo_framework);
        // Initialize account configs on aptos framework account.
        account::initialize(&topo_framework_account);

        transaction_validation::initialize(
            &topo_framework_account,
            b"script_prologue",
            b"module_prologue",
            b"multi_agent_script_prologue",
            b"epilogue",
        );
        // Give the decentralized on-chain governance control over the core framework account.
        topo_governance::store_signer_cap(&topo_framework_account, @topo_framework, topo_framework_signer_cap);

        // put reserved framework reserved accounts under aptos governance
        let framework_reserved_addresses = vector<address>[@0x2, @0x3, @0x4, @0x5, @0x6, @0x7, @0x8, @0x9, @0xa];
        while (!framework_reserved_addresses.is_empty()) {
            let address = framework_reserved_addresses.pop_back();
            let (_, framework_signer_cap) = account::create_framework_reserved_account(address);
            topo_governance::store_signer_cap(&topo_framework_account, address, framework_signer_cap);
        };

        consensus_config::initialize(&topo_framework_account, consensus_config);
        execution_config::set(&topo_framework_account, execution_config);
        version::initialize(&topo_framework_account, initial_version);
        stake::initialize(&topo_framework_account);
        stake::initialize_pending_transaction_fee(&topo_framework_account);
        timestamp::set_time_has_started(&topo_framework_account);
        staking_config::initialize(
            &topo_framework_account,
            minimum_stake,
            maximum_stake,
            recurring_lockup_duration_secs,
            allow_validator_set_change,
            rewards_rate,
            rewards_rate_denominator,
            voting_power_increase_limit,
        );
        storage_gas::initialize(&topo_framework_account);
        gas_schedule::initialize(&topo_framework_account, gas_schedule);

        // Ensure we can create aggregators for supply, but not enable it for common use just yet.
        aggregator_factory::initialize_aggregator_factory(&topo_framework_account);

        chain_id::initialize(&topo_framework_account, chain_id);
        reconfiguration::initialize(&topo_framework_account);
        block::initialize(&topo_framework_account, epoch_interval_microsecs);
        state_storage::initialize(&topo_framework_account);
        nonce_validation::initialize(&topo_framework_account);

        transaction_limits::initialize(
            &topo_framework_account,
            // Execution tiers:
            //   2x: 1M APT
            //   4x: 5M APT
            //   8x: 10M APT
            vector[
                transaction_limits::new_tier(1_000_000_0000_0000, 200),
                transaction_limits::new_tier(5_000_000_0000_0000, 400),
                transaction_limits::new_tier(10_000_000_0000_0000, 800),
            ],
            // IO tiers:
            //   2x: 5M APT
            //   4x: 10M APT
            //   8x: 20M APT
            vector[
                transaction_limits::new_tier(5_000_000_0000_0000, 200),
                transaction_limits::new_tier(10_000_000_0000_0000, 400),
                transaction_limits::new_tier(20_000_000_0000_0000, 800),
            ],
        );
    }

    /// Genesis step 2: Initialize Aptos coin.
    fun initialize_topo_coin(topo_framework: &signer) {
        let (burn_cap, mint_cap) = topo_coin::initialize(topo_framework);

        coin::create_coin_conversion_map(topo_framework);
        coin::create_pairing<TopoCoin>(topo_framework);

        // Give stake module MintCapability<TopoCoin> so it can mint rewards.
        stake::store_topo_coin_mint_cap(topo_framework, mint_cap);
        // Give transaction_fee module BurnCapability<TopoCoin> so it can burn gas.
        transaction_fee::store_topo_coin_burn_cap(topo_framework, burn_cap);
        // Give transaction_fee module MintCapability<TopoCoin> so it can mint refunds.
        transaction_fee::store_topo_coin_mint_cap(topo_framework, mint_cap);
    }

    /// Only called for testnets and e2e tests.
    fun initialize_core_resources_and_topo_coin(
        topo_framework: &signer,
        core_resources_auth_key: vector<u8>,
    ) {
        let (burn_cap, mint_cap) = topo_coin::initialize(topo_framework);

        coin::create_coin_conversion_map(topo_framework);
        coin::create_pairing<TopoCoin>(topo_framework);

        // Give stake module MintCapability<TopoCoin> so it can mint rewards.
        stake::store_topo_coin_mint_cap(topo_framework, mint_cap);
        // Give transaction_fee module BurnCapability<TopoCoin> so it can burn gas.
        transaction_fee::store_topo_coin_burn_cap(topo_framework, burn_cap);
        // Give transaction_fee module MintCapability<TopoCoin> so it can mint refunds.
        transaction_fee::store_topo_coin_mint_cap(topo_framework, mint_cap);

        let core_resources = account::create_account(@core_resources);
        account::rotate_authentication_key_internal(&core_resources, core_resources_auth_key);
        topo_account::register_apt(&core_resources); // registers APT store
        topo_coin::configure_accounts_for_test(topo_framework, &core_resources, mint_cap);
    }

    fun create_accounts(topo_framework: &signer, accounts: vector<AccountMap>) {
        let unique_accounts = vector::empty();
        accounts.for_each_ref(|account_map| {
            let account_map: &AccountMap = account_map;
            assert!(
                !vector::contains(&unique_accounts, &account_map.account_address),
                error::already_exists(EDUPLICATE_ACCOUNT),
            );
            vector::push_back(&mut unique_accounts, account_map.account_address);

            create_account(
                topo_framework,
                account_map.account_address,
                account_map.balance,
            );
        });
    }

    /// This creates an funds an account if it doesn't exist.
    /// If it exists, it just returns the signer.
    fun create_account(topo_framework: &signer, account_address: address, balance: u64): signer {
        let account = if (account::exists_at(account_address)) {
            create_signer(account_address)
        } else {
            account::create_account(account_address)
        };

        if (coin::balance<TopoCoin>(account_address) == 0) {
            coin::register<TopoCoin>(&account);
            topo_coin::mint(topo_framework, account_address, balance);
        };
        account
    }

    fun create_employee_validators(
        employee_vesting_start: u64,
        employee_vesting_period_duration: u64,
        employees: vector<EmployeeAccountMap>,
    ) {
        let unique_accounts = vector::empty();

        employees.for_each_ref(|employee_group| {
            let j = 0;
            let employee_group: &EmployeeAccountMap = employee_group;
            let num_employees_in_group = vector::length(&employee_group.accounts);

            let buy_ins = simple_map::create();

            while (j < num_employees_in_group) {
                let account = vector::borrow(&employee_group.accounts, j);
                assert!(
                    !vector::contains(&unique_accounts, account),
                    error::already_exists(EDUPLICATE_ACCOUNT),
                );
                vector::push_back(&mut unique_accounts, *account);

                let employee = create_signer(*account);
                let total = coin::balance<TopoCoin>(*account);
                let coins = coin::withdraw<TopoCoin>(&employee, total);
                simple_map::add(&mut buy_ins, *account, coins);

                j += 1;
            };

            let j = 0;
            let num_vesting_events = vector::length(&employee_group.vesting_schedule_numerator);
            let schedule = vector::empty();

            while (j < num_vesting_events) {
                let numerator = vector::borrow(&employee_group.vesting_schedule_numerator, j);
                let event = fixed_point32::create_from_rational(*numerator, employee_group.vesting_schedule_denominator);
                vector::push_back(&mut schedule, event);

                j += 1;
            };

            let vesting_schedule = vesting::create_vesting_schedule(
                schedule,
                employee_vesting_start,
                employee_vesting_period_duration,
            );

            let admin = employee_group.validator.validator_config.owner_address;
            let admin_signer = &create_signer(admin);
            let contract_address = vesting::create_vesting_contract(
                admin_signer,
                &employee_group.accounts,
                buy_ins,
                vesting_schedule,
                admin,
                employee_group.validator.validator_config.operator_address,
                employee_group.validator.validator_config.voter_address,
                employee_group.validator.commission_percentage,
                x"",
            );
            let pool_address = vesting::stake_pool_address(contract_address);

            if (employee_group.beneficiary_resetter != @0x0) {
                vesting::set_beneficiary_resetter(admin_signer, contract_address, employee_group.beneficiary_resetter);
            };

            let validator = &employee_group.validator.validator_config;
            // These checks ensure that validator accounts have 0x1::Account resource.
            // So, validator accounts can't be stateless.
            assert!(
                account::exists_at(validator.owner_address),
                error::not_found(EACCOUNT_DOES_NOT_EXIST),
            );
            assert!(
                account::exists_at(validator.operator_address),
                error::not_found(EACCOUNT_DOES_NOT_EXIST),
            );
            assert!(
                account::exists_at(validator.voter_address),
                error::not_found(EACCOUNT_DOES_NOT_EXIST),
            );
            if (employee_group.validator.join_during_genesis) {
                initialize_validator(pool_address, validator);
            };
        });
    }

    fun create_initialize_validators_with_commission(
        topo_framework: &signer,
        use_staking_contract: bool,
        validators: vector<ValidatorConfigurationWithCommission>,
    ) {
        // 按输入顺序逐池初始化；每轮都保留验证者集合与代币资源，供循环结束后安装原生 Epoch。
        for (i in 0..validators.length()) {
            create_initialize_validator(topo_framework, &validators[i], use_staking_contract);
        } spec {
            invariant i <= len(validators);
            invariant exists<stake::ValidatorSet>(@topo_framework);
            invariant exists<coin::CoinInfo<TopoCoin>>(@topo_framework);
        };

        // Destroy the aptos framework account's ability to mint coins now that we're done with setting up the initial
        // validators.
        topo_coin::destroy_mint_cap(topo_framework);

        stake::on_new_epoch();
    }

    /// 为每个创世验证者创建 owner 直接持有的保证金池，写入统一配置的初始原始算力并全额分配到本池。
    /// 在 Epoch 0 准备基线和周期 0 算力，分配沿用普通入口于 Epoch 1 生效。
    /// 算力周期初始为 60 个 Epoch，上传权限初始归框架，每池费用限额从零开始；三者均可在运行期治理调整。
    /// 使用统一计划流程安装一次 Epoch 1，不结算 Epoch 0 奖励。
    /// 外层构建器随后仍须执行既有初始 Epoch 事件及 set_genesis_end 步骤。
    fun create_initialize_poc_validators(
        framework: &signer,
        validators: vector<ValidatorConfiguration>,
        params: topo_framework::poc_accounting::PowerParams,
        deployment_mode: u8,
        retention_bps: u64,
        initial_raw_power: u64,
    ) {
        chain_status::assert_genesis();
        system_addresses::assert_topo_framework(framework);
        assert!(initial_raw_power > 0, error::invalid_argument(EINVALID_INITIAL_RAW_POWER));
        for (i in 0..validators.length()) {
            let validator = ValidatorConfigurationWithCommission {
                validator_config: validators[i],
                commission_percentage: 0,
                join_during_genesis: true,
            };
            create_initialize_validator(framework, &validator, false);
        } spec {
            invariant i <= len(validators);
            invariant exists<stake::ValidatorSet>(@topo_framework);
            invariant exists<coin::CoinInfo<TopoCoin>>(@topo_framework);
        };
        // 保证金入池后先准备 PoC，初始算力写入时直接按固定基线计算 units。
        topo_framework::reconfiguration_state::initialize(framework);
        stake::set_transaction_fee_limit_per_epoch_per_pool(framework, 0);
        topo_framework::poc_allocation::prepare_poc(framework, params,
            topo_framework::poc_accounting::default_deployment_limits(),
            deployment_mode, 1, retention_bps, POC_POWER_PERIOD_IN_EPOCHS, @topo_framework);
        for (i in 0..validators.length()) {
            let owner = validators[i].owner_address;
            topo_framework::poc_allocation::enable_pool(framework, owner);
            topo_framework::poc_power_store::set_genesis_committed_power(framework, owner, initial_raw_power);
            // 创世授权只为实际验证者 owner 建立初始分配，算力全部质押到本人的池。
            let user = create_signer(owner);
            topo_framework::poc_allocation::set_allocations(&user, vector[owner], vector[10000]);
        } spec {
            invariant i <= len(validators);
            invariant exists<topo_framework::poc_power_store::PowerStore>(@topo_framework);
            invariant global<topo_framework::poc_power_store::PowerStore>(@topo_framework).operator == @topo_framework;
            invariant exists<topo_framework::poc_accounting::AccountingState>(@topo_framework);
            invariant global<topo_framework::poc_accounting::AccountingState>(@topo_framework).epoch
                == reconfiguration::current_epoch();
            invariant global<topo_framework::poc_accounting::AccountingState>(@topo_framework).config.activation_epoch == 1;
        };
        topo_coin::destroy_mint_cap(framework);
        reconfiguration::install_genesis_poc_epoch(framework);
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
    fun create_initialize_validators(topo_framework: &signer, validators: vector<ValidatorConfiguration>) {
        let validators_with_commission = vector::empty();
        validators.for_each_reverse(|validator| {
            let validator_with_commission = ValidatorConfigurationWithCommission {
                validator_config: validator,
                commission_percentage: 0,
                join_during_genesis: true,
            };
            vector::push_back(&mut validators_with_commission, validator_with_commission);
        });

        create_initialize_validators_with_commission(topo_framework, false, validators_with_commission);
    }

    fun create_initialize_validator(
        topo_framework: &signer,
        commission_config: &ValidatorConfigurationWithCommission,
        use_staking_contract: bool,
    ) {
        let validator = &commission_config.validator_config;

        let owner = &create_account(topo_framework, validator.owner_address, validator.stake_amount);
        create_account(topo_framework, validator.operator_address, 0);
        create_account(topo_framework, validator.voter_address, 0);

        // Initialize the stake pool and join the validator set.
        let pool_address = if (use_staking_contract) {
            staking_contract::create_staking_contract(
                owner,
                validator.operator_address,
                validator.voter_address,
                validator.stake_amount,
                commission_config.commission_percentage,
                x"",
            );
            staking_contract::stake_pool_address(validator.owner_address, validator.operator_address)
        } else {
            stake::initialize_stake_owner(
                owner,
                validator.stake_amount,
                validator.operator_address,
                validator.voter_address,
            );
            validator.owner_address
        };

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
    fun set_genesis_end(topo_framework: &signer) {
        chain_status::set_genesis_end(topo_framework);
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
        topo_framework: &signer,
        min_voting_threshold: u128,
        required_proposer_stake: u64,
        voting_duration_secs: u64,
        accounts: vector<AccountMap>,
        employee_vesting_start: u64,
        employee_vesting_period_duration: u64,
        employees: vector<EmployeeAccountMap>,
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
        features::change_feature_flags_for_verification(topo_framework, vector[1, 2], vector[]);
        initialize_topo_coin(topo_framework);
        topo_governance::initialize_for_verification(
            topo_framework,
            min_voting_threshold,
            required_proposer_stake,
            voting_duration_secs
        );
        create_accounts(topo_framework, accounts);
        create_employee_validators(employee_vesting_start, employee_vesting_period_duration, employees);
        create_initialize_validators_with_commission(topo_framework, true, validators);
        set_genesis_end(topo_framework);
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
        assert!(account::exists_at(@topo_framework), 1);
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

    #[test_only]
    /// 为四个独立测试池分别设置相同数额的保证金，密钥沿用现有测试生成入口。
    fun poc_genesis_validators(amount: u64): vector<ValidatorConfiguration> {
        let validators = vector[];
        vector[@0xa11, @0xa12, @0xa13, @0xa14].for_each(|owner| {
            let (_, public_key, proof) = stake::generate_identity();
            validators.push_back(ValidatorConfiguration {
                owner_address: owner,
                operator_address: owner,
                voter_address: owner,
                stake_amount: amount,
                consensus_pubkey: topo_std::bls12381::public_key_to_bytes(&public_key),
                proof_of_possession: topo_std::bls12381::proof_of_possession_to_bytes(&proof),
                network_addresses: vector[],
                full_node_network_addresses: vector[],
            });
        });
        validators
    }

    #[test_only]
    /// 共用真实创世入口建立四池；链 Epoch 仍由各测试显式完成创世事件步骤。
    fun initialize_poc_genesis_for_test(framework: &signer, initial_raw_power: u64): vector<address> {
        setup();
        initialize_topo_coin(framework);
        staking_config::update_required_stake(framework, 1, 1000);
        std::features::change_feature_flags_for_testing(framework,
            vector[std::features::get_distribute_transaction_fee_feature()],
            vector[std::features::get_periodical_reward_rate_decrease_feature()]);
        let pools = vector[@0xa11, @0xa12, @0xa13, @0xa14];
        create_initialize_poc_validators(framework, poc_genesis_validators(100),
            topo_framework::poc_accounting::new_power_params(100000000, 10, 1000, 4),
            1, 10000, initial_raw_power);
        pools
    }

    #[test(framework = @topo_framework)]
    fun poc_genesis_installs_one_epoch_without_epoch_zero_rewards(framework: signer) {
        let initial_raw_power = 17;
        let pools = initialize_poc_genesis_for_test(&framework, initial_raw_power);
        // VM 的既有创世事件步骤单独推进链配置，不能重复安装委员会或推进算力时钟。
        assert!(reconfiguration::current_epoch() == 0, 1);
        reconfiguration::emit_genesis_event_for_test();
        set_genesis_end(&framework);
        assert!(reconfiguration::current_epoch() == 1
            && topo_framework::poc_accounting::current_epoch() == 1, 2);
        let (epoch, poc, _, _, distribute_fees, fee_limit) =
            stake::get_reward_context_fields(&stake::get_installed_reward_context());
        assert!(epoch == 1 && poc && distribute_fees && fee_limit == 0 && chain_status::is_operating(), 3);
        assert!(stake::get_installed_native_reward_bps() == 5000, 17);
        let (period, boundary, _, _) =
            topo_framework::poc_power_store::get_normalization_clock();
        assert!(period == 0 && boundary == 61, 4);
        pools.for_each(|pool| {
            assert!(stake::get_current_epoch_voting_power(pool) == initial_raw_power, 5);
            let (units, _, reward_base_octa, vault, index) = topo_framework::poc_accounting::get_pool(pool);
            assert!(units == (initial_raw_power as u128) * 65536
                && reward_base_octa == initial_raw_power && vault == 0 && index == 0, 6);
            let (active, inactive, pending_active, pending_inactive) = stake::get_stake(pool);
            assert!(active == 100 && inactive == 0 && pending_active == 0 && pending_inactive == 0, 7);
            assert!(topo_framework::poc_power_store::get_user_committed_power(pool) == initial_raw_power, 13);
            let (ratios, pending) = topo_framework::poc_accounting::get_allocations(pool);
            assert!(ratios.length() == 1 && pending.is_none(), 14);
            let (allocated_pool, bps) = topo_framework::poc_accounting::pool_ratio_fields(&ratios[0]);
            assert!(allocated_pool == pool && bps == 10000, 15);
            let (position_units, _, _, _) = topo_framework::poc_accounting::get_position(pool, pool);
            assert!(position_units == units, 16);
        });
        assert!(topo_framework::event::emitted_events<stake::PoCRewardCredited>().is_empty(), 8);
        assert!(topo_framework::event::emitted_events<stake::PoCEpochInstalled>().length() == 1, 9);
        assert!(topo_framework::event::emitted_events<reconfiguration::NewEpoch>().length() == 1, 10);
        assert!(!topo_framework::reconfiguration_state::is_in_progress()
            && !std::features::is_reconfiguration_frozen(), 11);
        assert!(topo_framework::poc_power_store::get_power_period_in_epochs() == 60
            && topo_framework::poc_power_store::get_operator() == @topo_framework
            && stake::transaction_fee_limit() == 0, 12);
    }

    #[test(framework = @topo_framework, operator = @0xb0b, vm = @vm_reserved)]
    fun poc_genesis_defaults_remain_governable(framework: signer, operator: signer, vm: signer) {
        initialize_poc_genesis_for_test(&framework, 10);
        reconfiguration::emit_genesis_event_for_test();
        set_genesis_end(&framework);
        let initial_context = stake::get_installed_reward_context();
        let (_, _, _, _, _, _, limits) = topo_framework::poc_accounting::get_config();
        assert!(limits == topo_framework::poc_accounting::default_deployment_limits(), 10);
        topo_framework::poc_allocation::update_deployment_limits(&framework,
            topo_framework::poc_accounting::new_deployment_limits(6, 2, 8, 5, 10));
        assert!(topo_framework::poc_accounting::validator_limit() == 5
            && topo_framework::poc_accounting::max_upload_users() == 8, 11);
        let index = stake::get_validator_index(@0xa11);
        stake::update_performance_statistics(std::option::some(index), vector[]);
        stake::record_fee(&vm, vector[index], vector[18446744073709551615]);
        assert!(stake::get_pending_transaction_fee()[index] == 0, 1);

        topo_framework::poc_power_store::set_operator(&framework, std::signer::address_of(&operator));
        topo_framework::poc_power_store::set_power_period_in_epochs(&framework, 2);
        stake::set_transaction_fee_limit_per_epoch_per_pool(&framework, 3);
        stake::schedule_reward_split(&framework, 6000, 2);
        // 新上传者立即可写下一算力周期；改长度不能移动已经确定的首个周期边界。
        topo_framework::poc_power_store::stage_batch_update(&operator, 1, vector[@0xa11], vector[20]);
        assert!(topo_framework::poc_power_store::get_operator() == std::signer::address_of(&operator)
            && topo_framework::poc_power_store::get_power_period_in_epochs() == 2
            && topo_framework::poc_power_store::next_boundary_epoch() == 61, 2);
        assert!(topo_framework::poc_power_store::get_user_committed_power(@0xa11) == 10
            && topo_framework::poc_power_store::get_user_power_for_period(@0xa11, 1) == 20, 3);
        stake::record_fee(&vm, vector[index], vector[1]);
        assert!(stake::transaction_fee_limit() == 3
            && stake::get_installed_reward_context() == initial_context
            && stake::get_pending_transaction_fee()[index] == 0
            && stake::get_installed_native_reward_bps() == 5000, 4);

        timestamp::fast_forward_seconds(1);
        topo_governance::force_end_epoch(&framework);
        let (epoch, poc, _, _, distribute_fees, fee_limit) =
            stake::get_reward_context_fields(&stake::get_installed_reward_context());
        assert!(epoch == 2 && poc && distribute_fees && fee_limit == 3
            && stake::get_installed_native_reward_bps() == 6000, 5);
        assert!(topo_framework::poc_power_store::get_current_period() == 0
            && topo_framework::poc_power_store::next_boundary_epoch() == 61
            && topo_framework::poc_power_store::get_user_committed_power(@0xa11) == 10, 6);
        let (_, _, _, poc_vault_balance_octa, _) = topo_framework::poc_accounting::get_pool(@0xa11);
        let (active_stake_octa, _, _, _) = stake::get_stake(@0xa11);
        // Epoch 1 的 10 Octa 通胀奖励按当期原生奖励占比 50% 分配：原生质押和 PoC 奖励金库各增加 5 Octa。
        // 当期交易费限额为零，后续提高限额也不补发。
        assert!(poc_vault_balance_octa == 5 && active_stake_octa == 105, 7);

        let index = stake::get_validator_index(@0xa11);
        stake::update_performance_statistics(std::option::some(index), vector[]);
        stake::record_fee(&vm, vector[index], vector[18446744073709551615]);
        assert!(stake::get_pending_transaction_fee()[index] == 3, 8);
        timestamp::fast_forward_seconds(1);
        topo_governance::force_end_epoch(&framework);
        let (_, _, _, poc_vault_balance_octa, _) = topo_framework::poc_accounting::get_pool(@0xa11);
        let (active_stake_octa, _, _, _) = stake::get_stake(@0xa11);
        // Epoch 2 的通胀和交易费均按 60% 分流：10 Octa 通胀原生得 6、PoC 得 4，3 Octa 费用原生得 1、PoC 得 2。
        assert!(poc_vault_balance_octa == 11 && active_stake_octa == 112, 9);
    }

    #[test(framework = @topo_framework)]
    #[expected_failure(abort_code = 0x30001, location = topo_framework::chain_status)]
    fun poc_genesis_entry_rejects_operating_chain(framework: signer) {
        setup();
        set_genesis_end(&framework);
        create_initialize_poc_validators(&framework, vector[],
            topo_framework::poc_accounting::new_power_params(100000000, 10, 1000, 4),
            1, 10000, 10);
    }

    #[test(framework = @topo_framework)]
    #[expected_failure(abort_code = 0x10003, location = topo_framework::genesis)]
    fun poc_genesis_rejects_zero_initial_raw_power(framework: signer) {
        initialize_poc_genesis_for_test(&framework, 0);
    }

    #[test(framework = @topo_framework)]
    fun poc_native_genesis_remains_unprepared(framework: signer) {
        setup();
        initialize_topo_coin(&framework);
        std::features::change_feature_flags_for_testing(&framework, vector[],
            vector[std::features::get_periodical_reward_rate_decrease_feature()]);
        create_initialize_validators(&framework, poc_genesis_validators(1));
        reconfiguration::emit_genesis_event_for_test();
        set_genesis_end(&framework);
        assert!(reconfiguration::current_epoch() == 1 && !stake::is_poc_prepared(), 1);
        assert!(!topo_framework::poc_power_store::is_initialized(), 2);
        vector[@0xa11, @0xa12, @0xa13, @0xa14].for_each(|pool| {
            assert!(stake::get_current_epoch_voting_power(pool) == 1, 3);
        });
    }

    #[test(topo_framework = @0x1)]
    fun test_create_account(topo_framework: &signer) {
        setup();
        initialize_topo_coin(topo_framework);

        let addr = @0x121341; // 01 -> 0a are taken
        let test_signer_before = create_account(topo_framework, addr, 15);
        let test_signer_after = create_account(topo_framework, addr, 500);
        assert!(test_signer_before == test_signer_after, 0);
        assert!(coin::balance<TopoCoin>(addr) == 15, 1);
    }

    #[test(topo_framework = @0x1)]
    fun test_create_accounts(topo_framework: &signer) {
        setup();
        initialize_topo_coin(topo_framework);

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

        create_accounts(topo_framework, accounts);
        assert!(coin::balance<TopoCoin>(addr0) == 12345, 0);
        assert!(coin::balance<TopoCoin>(addr1) == 67890, 1);

        create_account(topo_framework, addr0, 23456);
        assert!(coin::balance<TopoCoin>(addr0) == 12345, 2);
    }

    #[test(topo_framework = @0x1, root = @0xabcd)]
    fun test_create_root_account(topo_framework: &signer) {
        use topo_framework::aggregator_factory;
        use topo_framework::object;
        use topo_framework::primary_fungible_store;
        use topo_framework::fungible_asset::Metadata;

        aggregator_factory::initialize_aggregator_factory_for_test(topo_framework);

        let (burn_cap, mint_cap) = topo_coin::initialize(topo_framework);
        topo_coin::ensure_initialized_with_apt_fa_metadata_for_test();

        let core_resources = account::create_account(@core_resources);
        topo_account::register_apt(&core_resources); // registers APT store

        let apt_metadata = object::address_to_object<Metadata>(@aptos_fungible_asset);
        assert!(primary_fungible_store::primary_store_exists(@core_resources, apt_metadata), 2);

        topo_coin::configure_accounts_for_test(topo_framework, &core_resources, mint_cap);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }
}
