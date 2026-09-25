// 验证共识算力不会替换代币治理权重，委托入池费始终按已安装计奖上下文决定。
#[test_only]
module topo_framework::poc_delegation_tests {
    use std::signer;
    use std::features;
    use topo_framework::account;
    use topo_framework::coin;
    use topo_framework::stake;
    use topo_framework::delegation_pool;
    use topo_framework::topo_governance;
    use topo_framework::poc_accounting;
    use topo_framework::poc_allocation;
    use topo_framework::poc_power_store;
    use topo_framework::reconfiguration;
    use topo_framework::staking_config;
    use topo_framework::timestamp;
    use topo_framework::topo_coin::TopoCoin;
    use topo_std::fixed_point64;

    const OCTA_PER_TOPO: u64 = 100000000;
    const OPERATOR_ADDRESS: address = @0x999;

    #[test(framework = @0x1, user = @0x777)]
    fun poc_governance_open_mode_keeps_token_weight(framework: signer, user: signer) {
        stake::poc_setup(&framework, &user, vector[@0x11, @0x22, @0x33, @0x44], 2);
        stake::schedule_reward_split(&framework, 0, 2);
        stake::poc_commit(&framework);
        assert!(stake::get_current_epoch_voting_power(@0x44) == 10, 1);
        assert!(topo_governance::get_voting_power(@0x44) == 100, 2);
        // 当前 Epoch 的原生奖励占比已明确配置为 0%；入池费为零，无需读取委托份额记录。
        assert!(delegation_pool::get_add_stake_fee(@0x44, 1000000) == 0, 3);
    }

    #[test(framework = @0x1, user = @0x777)]
    fun poc_governance_static_mode_keeps_token_weight(framework: signer, user: signer) {
        stake::poc_setup_controlled(&framework, &user, vector[@0x11, @0x22, @0x33, @0x44], 2);
        stake::schedule_reward_split(&framework, 0, 2);
        stake::poc_commit(&framework);
        assert!(stake::get_current_epoch_voting_power(@0x44) == 10, 1);
        assert!(topo_governance::get_voting_power(@0x44) == 100, 2);
        assert!(delegation_pool::get_add_stake_fee(@0x44, 1000000) == 0, 3);
    }

    #[test(framework = @0x1, owner = @0x123)]
    fun poc_native_delegation_fee_uses_installed_rate(framework: signer, owner: signer) {
        let apt = 100000000u64;
        delegation_pool::initialize_for_test_custom(&framework, 100 * apt, 1000000 * apt, 3600, true, 1, 100, 50);
        delegation_pool::initialize_test_validator_custom(&owner, 1000 * apt, true, true, 3735);
        let pool = delegation_pool::get_owned_pool_address(@0x123);
        let expected = ((250u256 * (apt as u256) * 6265) / (1000000 + 6265)) as u64;
        assert!(delegation_pool::get_add_stake_fee(pool, 250 * apt) == expected, 1);
        stake::set_transaction_fee_limit_per_epoch_per_pool(&framework, 50);
        staking_config::initialize_rewards(&framework, fixed_point64::create_from_rational(1, 100),
            fixed_point64::create_from_rational(0, 1), 86400, timestamp::now_seconds(),
            fixed_point64::create_from_rational(0, 1));
        poc_allocation::prepare_poc(&framework,
            poc_accounting::new_power_params(apt * 100000000, 10, 100, 2),
            poc_accounting::new_deployment_limits(4, 4, 4, 3, 50),
            0, reconfiguration::current_epoch() + 10, 10000, 60, @0x1);
        staking_config::update_rewards_rate(&framework, 1, 200);
        assert!(delegation_pool::get_add_stake_fee(pool, 250 * apt) == expected, 2);
        // 原生配置确已修改，当前 Epoch 仍应使用已安装上下文中的原奖励率。
        let (num, den) = staking_config::get_reward_rate(&staking_config::get());
        assert!(num == 1 && den == 200, 3);
    }

    // 两个受控验证者满足已配置的成员替换增长预算约束。
    // 委托池本金为 1,000 TOPO，按 PoC 生效算力折算的计奖基数为 400 TOPO。
    // 由不同账户分别提供算力、持有委托份额和领取运营佣金。
    fun prepare_reward_split_delegation_pool(
        framework: &signer, owner: &signer, power_user: &signer,
        operator_commission_bps: u64, native_reward_bps: u64, rewards_rate_denominator: u64,
    ): address {
        delegation_pool::initialize_for_test_custom(framework,
            100 * OCTA_PER_TOPO, 1000000 * OCTA_PER_TOPO, 3600, true, 1, rewards_rate_denominator, 50);
        // 既有通胀用例不预估交易费；分费用例显式开启并安装新的费用上下文。
        features::change_feature_flags_for_testing(framework, vector[], vector[features::get_distribute_transaction_fee_feature()]);
        delegation_pool::initialize_test_validator_custom(owner, 1000 * OCTA_PER_TOPO, true, false, operator_commission_bps);
        let pool_address = delegation_pool::get_owned_pool_address(signer::address_of(owner));
        let other_validator = account::create_signer_for_test(@0x45);
        let (_, public_key, proof) = stake::generate_identity();
        stake::initialize_test_validator(&public_key, &proof, &other_validator, 1000 * OCTA_PER_TOPO, true, false);
        delegation_pool::end_aptos_epoch();
        account::create_account_for_test(OPERATOR_ADDRESS);
        delegation_pool::set_operator(owner, OPERATOR_ADDRESS);
        account::create_account_for_test(signer::address_of(power_user));

        stake::set_transaction_fee_limit_per_epoch_per_pool(framework, 50);
        staking_config::initialize_rewards(framework,
            fixed_point64::create_from_rational(1, rewards_rate_denominator as u128),
            fixed_point64::create_from_rational(0, 1), 86400, timestamp::now_seconds(),
            fixed_point64::create_from_rational(0, 1));
        let activation_epoch = reconfiguration::current_epoch() + 1;
        poc_allocation::prepare_poc(framework,
            poc_accounting::new_power_params(OCTA_PER_TOPO * 100000000, 10, 400, 2),
            poc_accounting::new_deployment_limits(4, 4, 4, 3, 50),
            0, activation_epoch, 10000, 60, @0x1);
        poc_allocation::enable_pool(framework, pool_address);
        poc_allocation::enable_pool(framework, @0x45);
        poc_power_store::set_committed_power_for_test(framework, signer::address_of(power_user), 400);
        poc_power_store::set_committed_power_for_test(framework, @0x45, 400);
        poc_allocation::set_allocations(power_user, vector[pool_address], vector[10000]);
        poc_allocation::set_allocations(&other_validator, vector[@0x45], vector[10000]);
        stake::schedule_reward_split(framework, native_reward_bps, activation_epoch);
        stake::poc_commit(framework);
        assert!(stake::is_poc_enabled() && stake::get_installed_native_reward_bps() == native_reward_bps, 100);
        assert!(poc_accounting::pool_reward_base_octa(pool_address) == 400 * OCTA_PER_TOPO, 101);
        assert!(total_stake_balance_octa(pool_address) == 1000 * OCTA_PER_TOPO, 102);
        pool_address
    }

    fun add_delegator(delegator: &signer, pool_address: address, amount_octa: u64) {
        let delegator_address = signer::address_of(delegator);
        if (!account::exists_at(delegator_address)) { account::create_account_for_test(delegator_address); };
        stake::mint(delegator, amount_octa);
        delegation_pool::add_stake(delegator, pool_address, amount_octa);
    }

    fun total_stake_balance_octa(pool_address: address): u64 {
        let (active_stake_octa, inactive_stake_octa, pending_active_stake_octa, pending_inactive_stake_octa) =
            stake::get_stake(pool_address);
        active_stake_octa + inactive_stake_octa + pending_active_stake_octa + pending_inactive_stake_octa
    }

    fun poc_reward_vault_balance_octa(pool_address: address): u64 {
        let (_, _, _, amount_octa, _) = poc_accounting::get_pool(pool_address);
        amount_octa
    }

    fun close_reward_epoch(framework: &signer) {
        stake::set_validator_perf_at_least_one_block();
        stake::poc_commit(framework);
    }

    // 以下用例允许用户和运营者的余额查询值与预期值相差最多 2 Octa，
    // 用于容纳奖励分配、佣金取整及 pool_u64 份额换算造成的误差。
    // 该容差仅用于这些具体用例；奖励铸币总额另作精确断言，防止掩盖正奖励丢失。
    fun assert_within_two_octa(actual_octa: u64, expected_octa: u64) {
        assert!((actual_octa as u256) + 2 >= (expected_octa as u256)
            && (actual_octa as u256) <= (expected_octa as u256) + 2, actual_octa);
    }

    #[test(framework = @0x1, owner = @0x123, power_user = @0x777,
        delegator_one = @0x456, delegator_two = @0x789)]
    fun poc_reward_split_delegation_repeated_adds_preserve_old_rewards(
        framework: signer, owner: signer, power_user: signer,
        delegator_one: signer, delegator_two: signer,
    ) {
        let pool_address = prepare_reward_split_delegation_pool(&framework, &owner, &power_user, 3735, 3000, 100);
        // 当期通胀为 4 TOPO：原生部分 1.2 TOPO，PoC 部分 2.8 TOPO。
        // 原生部分的预期分配为：运营佣金 0.4482 TOPO，原有委托者收益 0.7518 TOPO。
        assert!(delegation_pool::get_add_stake_fee(pool_address, 100 * OCTA_PER_TOPO) == 7512353, 1);
        add_delegator(&delegator_one, pool_address, 100 * OCTA_PER_TOPO);
        assert!(delegation_pool::get_add_stake_fee(pool_address, 100 * OCTA_PER_TOPO) == 7512353, 2);
        add_delegator(&delegator_two, pool_address, 100 * OCTA_PER_TOPO);
        add_delegator(&delegator_one, pool_address, 100 * OCTA_PER_TOPO);
        assert!(delegation_pool::get_add_stake_fee(pool_address, 100 * OCTA_PER_TOPO) == 7512353, 3);
        close_reward_epoch(&framework);

        assert!(total_stake_balance_octa(pool_address) == 1300 * OCTA_PER_TOPO + 120000000
            && poc_reward_vault_balance_octa(pool_address) == 280000000, 4);
        delegation_pool::synchronize_delegation_pool(pool_address);
        let (owner_stake_octa, _, _) = delegation_pool::get_stake(pool_address, @0x123);
        let (delegator_one_stake_octa, _, _) = delegation_pool::get_stake(pool_address, @0x456);
        let (delegator_two_stake_octa, _, _) = delegation_pool::get_stake(pool_address, @0x789);
        let (operator_stake_octa, _, _) = delegation_pool::get_stake(pool_address, OPERATOR_ADDRESS);
        assert_within_two_octa(owner_stake_octa, 1000 * OCTA_PER_TOPO + 75180000);
        assert_within_two_octa(delegator_one_stake_octa, 200 * OCTA_PER_TOPO);
        assert_within_two_octa(delegator_two_stake_octa, 100 * OCTA_PER_TOPO);
        assert_within_two_octa(operator_stake_octa, 44820000);

        poc_allocation::claim_rewards(&power_user, vector[pool_address]);
        assert!(coin::balance<TopoCoin>(@0x777) == 280000000 && poc_reward_vault_balance_octa(pool_address) == 0, 5);
        assert!(total_stake_balance_octa(pool_address) == 1300 * OCTA_PER_TOPO + 120000000, 6);
        poc_allocation::claim_rewards(&power_user, vector[pool_address]);
        assert!(coin::balance<TopoCoin>(@0x777) == 280000000, 7);
    }

    #[test(framework = @0x1, owner = @0x123, power_user = @0x777, delegator = @0x456, vm = @vm_reserved)]
    fun poc_fee_only_delegation_preserves_commission_and_old_shares(
        framework: signer, owner: signer, power_user: signer, delegator: signer, vm: signer,
    ) {
        let pool_address = prepare_reward_split_delegation_pool(&framework, &owner, &power_user, 2000, 3000, 100);
        stake::initialize_pending_transaction_fee(&framework);
        features::change_feature_flags_for_testing(&framework, vector[features::get_distribute_transaction_fee_feature()], vector[]);
        staking_config::update_rewards_rate(&framework, 0, 100);
        stake::set_transaction_fee_limit_per_epoch_per_pool(&framework, 35);
        stake::poc_commit(&framework);
        // 没有通胀，35 Octa 费用上限对应原生 10；扣除佣金并预留取整差后入池费为 9。
        assert!(stake::get_native_reward_upper_bound(pool_address) == 10, 1);
        assert!(delegation_pool::get_add_stake_fee(pool_address, 1000 * OCTA_PER_TOPO) == 9, 2);
        add_delegator(&delegator, pool_address, 1000 * OCTA_PER_TOPO);
        // 当期入池费与未来配置和费用到账时间无关。
        stake::set_transaction_fee_limit_per_epoch_per_pool(&framework, 10);
        stake::record_fee_for_test(&vm, stake::get_validator_index(pool_address), 35);
        assert!(stake::get_native_reward_upper_bound(pool_address) == 10, 3);
        close_reward_epoch(&framework);
        assert!(total_stake_balance_octa(pool_address) == 2000 * OCTA_PER_TOPO + 10
            && poc_reward_vault_balance_octa(pool_address) == 25, 4);
        delegation_pool::synchronize_delegation_pool(pool_address);
        let (owner_stake, _, _) = delegation_pool::get_stake(pool_address, @0x123);
        let (new_stake, _, _) = delegation_pool::get_stake(pool_address, @0x456);
        let (operator_stake, _, _) = delegation_pool::get_stake(pool_address, OPERATOR_ADDRESS);
        assert_within_two_octa(owner_stake, 1000 * OCTA_PER_TOPO + 8);
        assert_within_two_octa(new_stake, 1000 * OCTA_PER_TOPO);
        assert_within_two_octa(operator_stake, 2);
        poc_allocation::claim_rewards(&power_user, vector[pool_address]);
        assert!(coin::balance<TopoCoin>(@0x777) == 25 && poc_reward_vault_balance_octa(pool_address) == 0, 5);
        assert!(stake::get_native_reward_upper_bound(pool_address) == 3, 6);
    }

    #[test(framework = @0x1, owner = @0x123, power_user = @0x777, delegator = @0x456)]
    fun poc_reward_split_delegation_add_then_unlock_keeps_reward_ownership(
        framework: signer, owner: signer, power_user: signer, delegator: signer,
    ) {
        let pool_address = prepare_reward_split_delegation_pool(&framework, &owner, &power_user, 3735, 3000, 100);
        let add_stake_fee_octa = delegation_pool::get_add_stake_fee(pool_address, 200 * OCTA_PER_TOPO);
        assert!(add_stake_fee_octa == 15024705, 1);
        add_delegator(&delegator, pool_address, 200 * OCTA_PER_TOPO);
        delegation_pool::unlock(&delegator, pool_address, 200 * OCTA_PER_TOPO - add_stake_fee_octa);
        let (active_stake_octa, _, pending_active_stake_octa, pending_inactive_stake_octa) =
            stake::get_stake(pool_address);
        assert!(active_stake_octa + pending_inactive_stake_octa == 1000 * OCTA_PER_TOPO
            && pending_active_stake_octa == 200 * OCTA_PER_TOPO, 2);
        assert!(delegation_pool::get_add_stake_fee(pool_address, 200 * OCTA_PER_TOPO) == add_stake_fee_octa, 3);
        close_reward_epoch(&framework);

        assert!(total_stake_balance_octa(pool_address) == 1200 * OCTA_PER_TOPO + 120000000
            && poc_reward_vault_balance_octa(pool_address) == 280000000, 4);
        delegation_pool::synchronize_delegation_pool(pool_address);
        let (owner_stake_octa, _, _) = delegation_pool::get_stake(pool_address, @0x123);
        let (delegator_active_stake_octa, delegator_inactive_stake_octa, delegator_pending_inactive_stake_octa) =
            delegation_pool::get_stake(pool_address, @0x456);
        let (operator_active_stake_octa, operator_inactive_stake_octa, operator_pending_inactive_stake_octa) =
            delegation_pool::get_stake(pool_address, OPERATOR_ADDRESS);
        assert!(delegator_active_stake_octa == 0 && delegator_inactive_stake_octa == 0, 5);
        assert_within_two_octa(delegator_pending_inactive_stake_octa, 200 * OCTA_PER_TOPO);
        assert_within_two_octa(owner_stake_octa, 1000 * OCTA_PER_TOPO + 75180000);
        assert_within_two_octa(operator_active_stake_octa + operator_inactive_stake_octa
            + operator_pending_inactive_stake_octa, 44820000);
    }

    #[test(framework = @0x1, owner = @0x123, power_user = @0x777)]
    fun poc_reward_split_delegation_quote_uses_installed_split_and_rate(
        framework: signer, owner: signer, power_user: signer,
    ) {
        let pool_address = prepare_reward_split_delegation_pool(&framework, &owner, &power_user, 3735, 3000, 100);
        let add_stake_fee_octa = delegation_pool::get_add_stake_fee(pool_address, 100 * OCTA_PER_TOPO);
        stake::schedule_reward_split(&framework, 5000, poc_accounting::current_epoch() + 1);
        staking_config::update_rewards_rate(&framework, 1, 200);
        assert!(stake::get_installed_native_reward_bps() == 3000, 1);
        assert!(delegation_pool::get_add_stake_fee(pool_address, 100 * OCTA_PER_TOPO) == add_stake_fee_octa, 2);
        close_reward_epoch(&framework);
        assert!(total_stake_balance_octa(pool_address) == 1000 * OCTA_PER_TOPO + 120000000
            && poc_reward_vault_balance_octa(pool_address) == 280000000, 3);
        assert!(stake::get_installed_native_reward_bps() == 5000, 4);
        assert!(stake::get_native_reward_upper_bound(pool_address) == OCTA_PER_TOPO, 5);
        assert!(delegation_pool::get_add_stake_fee(pool_address, 100 * OCTA_PER_TOPO) < add_stake_fee_octa, 6);
        close_reward_epoch(&framework);
        // 第二个 PoC Epoch 的通胀为 2 TOPO，原生质押与 PoC 各分得 1 TOPO。
        // 第一个 PoC Epoch 仍按已安装的配置结算：奖励率为 1%，原生奖励占比为 30%。
        assert!(total_stake_balance_octa(pool_address) == 1000 * OCTA_PER_TOPO + 220000000
            && poc_reward_vault_balance_octa(pool_address) == 380000000, 7);
    }

    #[test(framework = @0x1, owner = @0x123, power_user = @0x777, delegator = @0x456)]
    fun poc_all_native_zero_commission_keeps_new_principal_whole(
        framework: signer, owner: signer, power_user: signer, delegator: signer,
    ) {
        let pool_address = prepare_reward_split_delegation_pool(&framework, &owner, &power_user, 0, 10000, 100);
        add_delegator(&delegator, pool_address, 100 * OCTA_PER_TOPO);
        close_reward_epoch(&framework);
        assert!(total_stake_balance_octa(pool_address) == 1104 * OCTA_PER_TOPO
            && poc_reward_vault_balance_octa(pool_address) == 0, 1);
        delegation_pool::synchronize_delegation_pool(pool_address);
        let (owner_stake_octa, _, _) = delegation_pool::get_stake(pool_address, @0x123);
        let (delegator_stake_octa, _, _) = delegation_pool::get_stake(pool_address, @0x456);
        let (operator_stake_octa, _, _) = delegation_pool::get_stake(pool_address, OPERATOR_ADDRESS);
        assert_within_two_octa(owner_stake_octa, 1004 * OCTA_PER_TOPO);
        assert_within_two_octa(delegator_stake_octa, 100 * OCTA_PER_TOPO);
        assert!(operator_stake_octa == 0, 2);
    }

    #[test(framework = @0x1, owner = @0x123, power_user = @0x777, delegator = @0x456)]
    fun poc_zero_native_portion_does_not_charge_delegators(
        framework: signer, owner: signer, power_user: signer, delegator: signer,
    ) {
        let pool_address = prepare_reward_split_delegation_pool(&framework, &owner, &power_user, 3735, 0, 100);
        assert!(delegation_pool::get_add_stake_fee(pool_address, 100 * OCTA_PER_TOPO) == 0, 1);
        add_delegator(&delegator, pool_address, 100 * OCTA_PER_TOPO);
        close_reward_epoch(&framework);
        assert!(total_stake_balance_octa(pool_address) == 1100 * OCTA_PER_TOPO
            && poc_reward_vault_balance_octa(pool_address) == 4 * OCTA_PER_TOPO, 2);
        let (owner_stake_octa, _, _) = delegation_pool::get_stake(pool_address, @0x123);
        let (delegator_stake_octa, _, _) = delegation_pool::get_stake(pool_address, @0x456);
        assert!(owner_stake_octa == 1000 * OCTA_PER_TOPO && delegator_stake_octa == 100 * OCTA_PER_TOPO, 3);
    }

    #[test(framework = @0x1, owner = @0x123, power_user = @0x777, delegator = @0x456)]
    fun poc_full_native_commission_does_not_charge_delegators(
        framework: signer, owner: signer, power_user: signer, delegator: signer,
    ) {
        let pool_address = prepare_reward_split_delegation_pool(&framework, &owner, &power_user, 10000, 3000, 100);
        assert!(delegation_pool::get_add_stake_fee(pool_address, 100 * OCTA_PER_TOPO) == 0, 1);
        add_delegator(&delegator, pool_address, 100 * OCTA_PER_TOPO);
        close_reward_epoch(&framework);
        assert!(total_stake_balance_octa(pool_address) == 1100 * OCTA_PER_TOPO + 120000000
            && poc_reward_vault_balance_octa(pool_address) == 280000000, 2);
        delegation_pool::synchronize_delegation_pool(pool_address);
        let (owner_stake_octa, _, _) = delegation_pool::get_stake(pool_address, @0x123);
        let (delegator_stake_octa, _, _) = delegation_pool::get_stake(pool_address, @0x456);
        let (operator_stake_octa, _, _) = delegation_pool::get_stake(pool_address, OPERATOR_ADDRESS);
        assert!(owner_stake_octa == 1000 * OCTA_PER_TOPO
            && delegator_stake_octa == 100 * OCTA_PER_TOPO
            && operator_stake_octa == 120000000, 3);
    }

    #[test(framework = @0x1, owner = @0x123, power_user = @0x777, delegator = @0x456)]
    fun poc_commission_expiry_during_dkg_cannot_release_pending_deposit_rewards(
        framework: signer, owner: signer, power_user: signer, delegator: signer,
    ) {
        let pool_address = prepare_reward_split_delegation_pool(&framework, &owner, &power_user, 10000, 3000, 100);
        delegation_pool::update_commission_percentage(&owner, 0);
        assert!(delegation_pool::get_add_stake_fee(pool_address, 1000 * OCTA_PER_TOPO) == 0, 1);
        add_delegator(&delegator, pool_address, 1000 * OCTA_PER_TOPO);
        stake::set_validator_perf_at_least_one_block();
        stake::poc_begin_for_test();
        let closing_epoch = poc_accounting::current_epoch();
        timestamp::fast_forward_seconds(stake::get_remaining_lockup_secs(pool_address) + 1);

        // DKG 尚未完成，新增质押仍处于当前 Epoch 的 pending_active。
        // 即使已到佣金变更时间，调用公开同步入口也不能提前将佣金降为零；
        // 否则本应全部归运营者的 1.2 TOPO 原生奖励会被新入池用户分走 0.6 TOPO。
        delegation_pool::synchronize_delegation_pool(pool_address);
        assert!(poc_accounting::current_epoch() == closing_epoch, 2);
        assert!(!delegation_pool::is_next_commission_percentage_effective(pool_address), 3);
        assert!(delegation_pool::operator_commission_percentage(pool_address) == 10000, 4);
        assert!(delegation_pool::get_add_stake_fee(pool_address, 1000 * OCTA_PER_TOPO) == 0, 5);
        stake::poc_commit(&framework);
        assert!(total_stake_balance_octa(pool_address) == 2000 * OCTA_PER_TOPO + 120000000
            && poc_reward_vault_balance_octa(pool_address) == 280000000, 6);
        delegation_pool::synchronize_delegation_pool(pool_address);
        let (owner_stake_octa, _, _) = delegation_pool::get_stake(pool_address, @0x123);
        let (delegator_stake_octa, _, _) = delegation_pool::get_stake(pool_address, @0x456);
        let (operator_stake_octa, _, _) = delegation_pool::get_stake(pool_address, OPERATOR_ADDRESS);
        assert!(owner_stake_octa == 1000 * OCTA_PER_TOPO
            && delegator_stake_octa == 1000 * OCTA_PER_TOPO
            && operator_stake_octa == 120000000, 7);
        assert!(delegation_pool::operator_commission_percentage(pool_address) == 0, 8);
        assert!(delegation_pool::get_add_stake_fee(pool_address, 1000 * OCTA_PER_TOPO) > 0, 9);
    }

    #[test(framework = @0x1, owner = @0x123, power_user = @0x777, delegator = @0x456)]
    fun poc_one_octa_native_reward_survives_large_mid_epoch_add(
        framework: signer, owner: signer, power_user: signer, delegator: signer,
    ) {
        let pool_address = prepare_reward_split_delegation_pool(&framework, &owner, &power_user, 5000, 3000, 10000000000);
        // 当期通胀为 4 Octa：原生部分向下取整为 1 Octa，PoC 部分为 3 Octa。
        // 该 1 Octa 的 50% 佣金取整后为零，委托者净奖励仍为 1 Octa；
        // 若误将净奖励估成 0.5 Octa，就会低估入池费。
        assert!(stake::get_native_reward_upper_bound(pool_address) == 1, 1);
        assert!(delegation_pool::get_add_stake_fee(pool_address, 50000 * OCTA_PER_TOPO) == 50, 2);
        add_delegator(&delegator, pool_address, 50000 * OCTA_PER_TOPO);
        close_reward_epoch(&framework);
        assert!(total_stake_balance_octa(pool_address) == 51000 * OCTA_PER_TOPO + 1
            && poc_reward_vault_balance_octa(pool_address) == 3, 3);
        delegation_pool::synchronize_delegation_pool(pool_address);
        let (owner_stake_octa, _, _) = delegation_pool::get_stake(pool_address, @0x123);
        let (delegator_stake_octa, _, _) = delegation_pool::get_stake(pool_address, @0x456);
        let (operator_stake_octa, _, _) = delegation_pool::get_stake(pool_address, OPERATOR_ADDRESS);
        assert!(owner_stake_octa == 1000 * OCTA_PER_TOPO + 1
            && delegator_stake_octa <= 50000 * OCTA_PER_TOPO
            && operator_stake_octa == 0, 4);
    }

    #[test(framework = @0x1, user = @0x777)]
    #[expected_failure(abort_code = 0x10003, location = topo_framework::delegation_pool)]
    fun poc_positive_native_fee_requires_real_delegation_pool(framework: signer, user: signer) {
        stake::poc_setup(&framework, &user, vector[@0x11, @0x22, @0x33, @0x44], 2);
        stake::schedule_reward_split(&framework, 3000, 2);
        stake::poc_commit(&framework);
        delegation_pool::get_add_stake_fee(@0x44, 1000000);
    }
}
