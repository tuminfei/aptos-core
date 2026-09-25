#[test_only]
module topo_framework::poc_config_tests {
    use topo_framework::poc_accounting;
    use topo_framework::poc_allocation;
    use topo_framework::stake;

    fun setup(framework: &signer, user: &signer) {
        stake::poc_setup(framework, user, vector[@0x11, @0x22, @0x33, @0x44], 2);
    }

    #[test(framework = @0x1, user = @0x777)]
    fun update_limits_preserves_epoch_and_user_state(framework: signer, user: signer) {
        setup(&framework, &user);
        let context = stake::get_installed_reward_context();
        let (active, pending) = poc_accounting::get_allocations(@0x777);
        let (units, changes, claimable, remainder) = poc_accounting::get_position(@0x777, @0x11);
        let limits = poc_accounting::new_deployment_limits(6, 2, 3, 5, 50);
        poc_allocation::update_deployment_limits(&framework, limits);
        let (epoch, _, _, _, _, _, actual) = poc_accounting::get_config();
        assert!(epoch == 1 && actual == limits, 1);
        assert!(stake::get_installed_reward_context() == context, 2);
        let (new_active, new_pending) = poc_accounting::get_allocations(@0x777);
        let (new_units, new_changes, new_claimable, new_remainder) = poc_accounting::get_position(@0x777, @0x11);
        assert!(new_active == active && new_pending == pending && new_units == units
            && new_changes == changes && new_claimable == claimable && new_remainder == remainder, 3);
        stake::poc_commit(&framework);
        assert!(poc_accounting::current_epoch() == 2, 4);
    }

    #[test(framework = @0x1, user = @0x777)]
    #[expected_failure(abort_code = 0x50003, location = topo_framework::system_addresses)]
    fun only_governance_can_update_limits(framework: signer, user: signer) {
        setup(&framework, &user);
        poc_allocation::update_deployment_limits(&user,
            poc_accounting::new_deployment_limits(6, 5, 5, 8, 50));
    }

    #[test(framework = @0x1, user = @0x777)]
    #[expected_failure(abort_code = 0x10007, location = topo_framework::poc_accounting)]
    fun existing_allocation_capacity_cannot_shrink(framework: signer, user: signer) {
        setup(&framework, &user);
        poc_allocation::update_deployment_limits(&framework,
            poc_accounting::new_deployment_limits(4, 5, 5, 8, 50));
    }

    #[test(framework = @0x1, user = @0x777)]
    #[expected_failure(abort_code = 0x10007, location = topo_framework::poc_accounting)]
    fun pending_power_params_must_fit_new_limits(framework: signer, user: signer) {
        setup(&framework, &user);
        poc_allocation::schedule_power_params(&framework,
            poc_accounting::new_power_params(100000000, 10, 1000, 6), 3);
        poc_allocation::update_deployment_limits(&framework,
            poc_accounting::new_deployment_limits(5, 5, 5, 6, 50));
    }

    #[test(framework = @0x1, user = @0x777)]
    #[expected_failure(abort_code = 0x10011, location = topo_framework::poc_accounting)]
    fun installed_fee_snapshot_must_fit_new_limits(framework: signer, user: signer) {
        setup(&framework, &user);
        stake::set_transaction_fee_limit_per_epoch_per_pool(&framework, 0);
        poc_allocation::update_deployment_limits(&framework,
            poc_accounting::new_deployment_limits(5, 5, 5, 8, 0));
    }

    #[test(framework = @0x1, user = @0x777)]
    fun large_max_power_uses_actual_weights_and_reward_bases(framework: signer, user: signer) {
        setup(&framework, &user);
        let max_power = 18446744073709551615;
        poc_allocation::schedule_power_params(&framework,
            poc_accounting::new_power_params(200000000, 10, max_power, 4), 2);
        // 无需随 max_power 限制候选容量；当前和待生效配置均按实际换届结果验证金额。
        poc_allocation::update_deployment_limits(&framework,
            poc_accounting::new_deployment_limits(5, 5, 5, 16, 50));
        stake::poc_commit(&framework);
        let (_, _, _, _, params, pending, _) = poc_accounting::get_config();
        let (_, _, installed_max_power, _) = poc_accounting::get_power_params_fields(&params);
        assert!(installed_max_power == max_power && pending.is_none(), 1);
        assert!(poc_accounting::validator_limit() == 16, 2);
        vector[@0x11, @0x22, @0x33, @0x44].for_each_ref(|pool| {
            assert!(stake::get_current_epoch_voting_power(*pool) == 10, 3);
            assert!(poc_accounting::pool_reward_base_octa(*pool) == 20, 4);
        });
    }

    #[test(framework = @0x1, user = @0x777)]
    #[expected_failure(abort_code = 0x3000b, location = topo_framework::poc_accounting)]
    fun frozen_limits_cannot_change(framework: signer, user: signer) {
        setup(&framework, &user);
        stake::poc_begin_for_test();
        poc_allocation::update_deployment_limits(&framework,
            poc_accounting::new_deployment_limits(6, 5, 5, 8, 50));
    }
}
