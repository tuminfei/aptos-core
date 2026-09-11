// 准备 PoC 后、正式启用前，原生预览按计划截止时间和预览时的表现计算两部分奖励。
#[test_only]
module topo_framework::poc_native_preview_smoke_tests {
    use std::option;
    use topo_framework::poc_accounting;
    use topo_framework::stake;
    use topo_framework::timestamp;
    use topo_framework::validator_consensus_info;

    fun assert_installed_power(pool: address, expected: u64) {
        // 原生模式的 get_current_epoch_voting_power 读取实时本金，这里核对已安装的 BFT 权重。
        let installed = stake::cur_validator_consensus_infos();
        let validator = &installed[stake::get_validator_index(pool)];
        assert!(validator_consensus_info::get_addr(validator) == pool, 100);
        assert!(validator_consensus_info::get_voting_power(validator) == expected, 101);
    }

    #[test(framework = @0x1, user = @0x777, validator = @0x44)]
    fun poc_prepared_native_epoch_keeps_pending_inactive_rewards_in_voting_power(
        framework: signer, user: signer, validator: signer
    ) {
        // 当前 Epoch 为 1，Epoch 3 才启用 PoC；本次提交的 Epoch 2 仍使用原生权重。
        // 每池已有 100 Octa 保证金，当前原生奖励率为 1%。
        stake::poc_setup(&framework, &user, vector[@0x11, @0x22, @0x33, @0x44], 3);
        assert!(!stake::is_poc_enabled(), 1);
        assert!(stake::get_lockup_secs(@0x44) > timestamp::now_seconds(), 2);

        // 将保证金全部移入尚未到期的 pending_inactive，并记录一次成功提案。
        // 这 100 Octa 在下一 Epoch 仍处于锁仓中，其 1 Octa 奖励也应计入原生投票权重。
        stake::unlock(&validator, 100);
        let index = stake::get_validator_index(@0x44);
        stake::update_validator_performances_for_test(option::some(index), vector[]);
        stake::poc_commit(&framework);

        assert!(poc_accounting::current_epoch() == 2 && !stake::is_poc_enabled(), 3);
        let (active, inactive, pending_active, pending_inactive) = stake::get_stake(@0x44);
        assert!(active == 0 && inactive == 0 && pending_active == 0 && pending_inactive == 101, 4);
        assert_installed_power(@0x44, 101);
    }

    #[test(framework = @0x1, user = @0x777, validator = @0x44)]
    fun poc_native_preview_rounds_active_and_pending_inactive_separately(
        framework: signer, user: signer, validator: signer
    ) {
        stake::poc_setup(&framework, &user, vector[@0x11, @0x22, @0x33, @0x44], 3);
        stake::unlock(&validator, 50);
        stake::update_validator_performances_for_test(
            option::some(stake::get_validator_index(@0x44)), vector[]);
        stake::poc_commit(&framework);

        // floor(50 * 1%) + floor(50 * 1%) = 0；合并本金后计算会多出 1 Octa。
        let (active, inactive, pending_active, pending_inactive) = stake::get_stake(@0x44);
        assert!(active == 50 && inactive == 0 && pending_active == 0 && pending_inactive == 50, 1);
        assert_installed_power(@0x44, 100);
    }

    #[test(framework = @0x1, user = @0x777, validator = @0x44)]
    fun poc_native_preview_excludes_pending_inactive_reward_at_exact_cutoff(
        framework: signer, user: signer, validator: signer
    ) {
        stake::poc_setup(&framework, &user, vector[@0x11, @0x22, @0x33, @0x44], 4);
        stake::mint_and_add_stake(&validator, 100);
        stake::poc_commit(&framework);
        let (active, _, _, _) = stake::get_stake(@0x44);
        assert!(active == 200, 1);
        stake::unlock(&validator, 100);
        stake::update_validator_performances_for_test(
            option::some(stake::get_validator_index(@0x44)), vector[]);
        timestamp::update_global_time_for_test_secs(stake::get_lockup_secs(@0x44));
        stake::poc_commit(&framework);

        // 截止时刻等于到期时刻：退出本金及其 1 Octa 奖励一起转为 inactive。
        let (active, inactive, pending_active, pending_inactive) = stake::get_stake(@0x44);
        assert!(active == 101 && inactive == 101 && pending_active == 0 && pending_inactive == 0, 2);
        assert_installed_power(@0x44, 101);
    }

    #[test(framework = @0x1, user = @0x777, validator = @0x44)]
    fun poc_native_preview_does_not_reward_pending_active_stake(
        framework: signer, user: signer, validator: signer
    ) {
        stake::poc_setup(&framework, &user, vector[@0x11, @0x22, @0x33, @0x44], 3);
        stake::mint_and_add_stake(&validator, 100);
        let (active, _, pending_active, _) = stake::get_stake(@0x44);
        assert!(active == 100 && pending_active == 100, 1);
        stake::update_validator_performances_for_test(
            option::some(stake::get_validator_index(@0x44)), vector[]);
        stake::poc_commit(&framework);

        // 追加的 pending_active 本次仅转为 active；旧期奖励只有原 active 的 1 Octa。
        let (active, inactive, pending_active, pending_inactive) = stake::get_stake(@0x44);
        assert!(active == 201 && inactive == 0 && pending_active == 0 && pending_inactive == 0, 2);
        assert_installed_power(@0x44, 201);
    }

    #[test(framework = @0x1, user = @0x777, validator = @0x44)]
    fun poc_native_preview_keeps_cached_weight_and_cutoff_during_wait(
        framework: signer, user: signer, validator: signer
    ) {
        stake::poc_setup(&framework, &user, vector[@0x11, @0x22, @0x33, @0x44], 3);
        stake::unlock(&validator, 100);
        let index = stake::get_validator_index(@0x44);
        stake::update_validator_performances_for_test(option::some(index), vector[]);
        stake::poc_begin_for_test();

        // 计划冻结后跨过锁仓到期时刻，并增加一次失败提案；不能据此重算已缓存的委员会。
        timestamp::update_global_time_for_test_secs(stake::get_lockup_secs(@0x44));
        stake::update_validator_performances_for_test(option::none(), vector[index]);
        stake::poc_commit(&framework);

        // 结算奖励为 floor(100 * 1% * 1/2) = 0，但计划仍采用冻结前的 101 权重。
        // 本金是否到期同样使用原 cutoff，因此它仍留在 pending_inactive。
        let (active, inactive, pending_active, pending_inactive) = stake::get_stake(@0x44);
        assert!(active == 0 && inactive == 0 && pending_active == 0 && pending_inactive == 100, 1);
        assert_installed_power(@0x44, 101);
    }
}
