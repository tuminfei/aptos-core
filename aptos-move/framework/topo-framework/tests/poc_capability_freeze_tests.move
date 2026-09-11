// 从质押合约、锁定合约和委托池的上层入口验证冻结检查，确保无法通过能力接口绕过。
#[test_only]
module topo_framework::poc_capability_freeze_tests {
    use std::signer;
    use topo_std::fixed_point64;
    use topo_framework::account;
    use topo_framework::delegation_pool;
    use topo_framework::poc_accounting;
    use topo_framework::poc_allocation;
    use topo_framework::reconfiguration;
    use topo_framework::stake;
    use topo_framework::staking_config;
    use topo_framework::staking_contract;
    use topo_framework::timestamp;
    use topo_framework::vesting;

    fun setup_contract(framework: &signer, user: &signer, staker: &signer, operator: &signer) {
        stake::poc_setup(framework, user, vector[@0x11, @0x22, @0x33, @0x44], 2);
        staking_contract::setup_staking_contract(framework, staker, operator, 300, 0);
    }

    #[test(framework = @0x1, user = @0x777, staker = @0x123, operator = @0x234)]
    #[expected_failure(abort_code = 0x30014, location = topo_framework::stake)]
    fun poc_capability_staking_contract_add_frozen(
        framework: signer, user: signer, staker: signer, operator: signer
    ) {
        setup_contract(&framework, &user, &staker, &operator);
        stake::mint(&staker, 100);
        stake::poc_begin_for_test();
        staking_contract::add_stake(&staker, @0x234, 100);
    }

    #[test(framework = @0x1, user = @0x777, staker = @0x123, operator = @0x234)]
    #[expected_failure(abort_code = 0x30014, location = topo_framework::stake)]
    fun poc_capability_staking_contract_lockup_frozen(
        framework: signer, user: signer, staker: signer, operator: signer
    ) {
        setup_contract(&framework, &user, &staker, &operator);
        // 先保证续期时间合法，确认本次失败是由冻结检查触发的。
        timestamp::update_global_time_for_test_secs(timestamp::now_seconds() + 1);
        stake::poc_begin_for_test();
        staking_contract::reset_lockup(&staker, @0x234);
    }

    #[test(framework = @0x1, user = @0x777, staker = @0x123, operator = @0x234)]
    #[expected_failure(abort_code = 0x30014, location = topo_framework::stake)]
    fun poc_capability_staking_contract_withdraw_frozen(
        framework: signer, user: signer, staker: signer, operator: signer
    ) {
        setup_contract(&framework, &user, &staker, &operator);
        staking_contract::reset_lockup(&staker, @0x234);
        staking_contract::unlock_stake(&staker, @0x234, 100);
        let pool = staking_contract::stake_pool_address(@0x123, @0x234);
        timestamp::update_global_time_for_test_secs(stake::get_lockup_secs(pool));
        let (_, _, _, pending_inactive) = stake::get_stake(pool);
        assert!(pending_inactive == 100, 1);
        stake::poc_begin_for_test();
        // 使用已到期的本金调用公开分发入口，验证转调 withdraw_with_cap 时仍被拒绝。
        staking_contract::distribute(@0x123, @0x234);
    }

    #[test(framework = @0x1, user = @0x777, admin = @0x123)]
    #[expected_failure(abort_code = 0x30014, location = topo_framework::stake)]
    fun poc_capability_vesting_lockup_frozen(framework: signer, user: signer, admin: signer) {
        stake::poc_setup(&framework, &user, vector[@0x11, @0x22, @0x33, @0x44], 2);
        let admin_address = signer::address_of(&admin);
        account::create_account_for_test(admin_address);
        stake::mint(&admin, 0);
        let contract = vesting::setup_vesting_contract(
            &admin, &vector[admin_address], &vector[300], admin_address, 0);
        timestamp::update_global_time_for_test_secs(timestamp::now_seconds() + 1);
        stake::poc_begin_for_test();
        // 管理员权限合法，调用沿 Vesting -> StakingContract -> stake 能力接口逐层进入。
        vesting::reset_lockup(&admin, contract);
    }

    #[test(framework = @0x1, owner = @0x123)]
    #[expected_failure(abort_code = 0x30014, location = topo_framework::stake)]
    fun poc_capability_delegation_add_frozen(framework: signer, owner: signer) {
        let apt = 100000000u64;
        delegation_pool::initialize_for_test_custom(&framework,
            100 * apt, 1000000 * apt, 3600, true, 1, 100, 50);
        delegation_pool::initialize_test_validator_custom(&owner, 1000 * apt, true, true, 3735);
        let pool = delegation_pool::get_owned_pool_address(@0x123);
        stake::set_transaction_fee_limit_per_epoch_per_pool(&framework, 50);
        staking_config::initialize_rewards(&framework, fixed_point64::create_from_rational(1, 100),
            fixed_point64::create_from_rational(0, 1), 86400, timestamp::now_seconds(),
            fixed_point64::create_from_rational(0, 1));
        poc_allocation::prepare_poc(&framework,
            poc_accounting::new_power_params(apt * 100000000, 10, 100, 2),
            poc_accounting::new_deployment_limits(4, 4, 4, 3, 100 * apt, 1, 100, 50, 100),
            0, reconfiguration::current_epoch() + 10, 10000, 100, 60, @0x1);
        stake::mint(&owner, 10 * apt);
        // 准备完成后，即使当前 Epoch 仍采用原生奖励，也使用相同的计划/PVS 成对缓存和冻结规则。
        stake::poc_begin_for_test();
        delegation_pool::add_stake(&owner, pool, 10 * apt);
    }
}
