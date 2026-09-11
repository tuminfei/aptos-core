// 验证共识算力不会替换代币治理权重，委托入池费始终按已安装计奖上下文决定。
#[test_only]
module topo_framework::poc_delegation_tests {
    use topo_framework::stake;
    use topo_framework::delegation_pool;
    use topo_framework::topo_governance;
    use topo_framework::poc_accounting;
    use topo_framework::poc_allocation;
    use topo_framework::reconfiguration;
    use topo_framework::staking_config;
    use topo_framework::timestamp;
    use topo_std::fixed_point64;

    #[test(framework = @0x1, user = @0x777)]
    fun poc_governance_open_mode_keeps_token_weight(framework: signer, user: signer) {
        stake::poc_setup(&framework, &user, vector[@0x11, @0x22, @0x33, @0x44], 2);
        stake::poc_commit(&framework);
        assert!(stake::get_current_epoch_voting_power(@0x44) == 10, 1);
        assert!(topo_governance::get_voting_power(@0x44) == 100, 2);
        // 当前 Epoch 已启用 PoC，入池费为零，此分支无需读取原生委托份额记录。
        assert!(delegation_pool::get_add_stake_fee(@0x44, 1000000) == 0, 3);
    }

    #[test(framework = @0x1, user = @0x777)]
    fun poc_governance_static_mode_keeps_token_weight(framework: signer, user: signer) {
        stake::poc_setup_controlled(&framework, &user, vector[@0x11, @0x22, @0x33, @0x44], 2);
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
            poc_accounting::new_deployment_limits(4, 4, 4, 3, 100 * apt, 1, 100, 50, 100),
            0, reconfiguration::current_epoch() + 10, 10000, 100, 60, @0x1);
        staking_config::update_rewards_rate(&framework, 1, 200);
        assert!(delegation_pool::get_add_stake_fee(pool, 250 * apt) == expected, 2);
        // 原生配置确已修改，当前 Epoch 仍应使用已安装上下文中的原奖励率。
        let (num, den) = staking_config::get_reward_rate(&staking_config::get());
        assert!(num == 1 && den == 200, 3);
    }
}
