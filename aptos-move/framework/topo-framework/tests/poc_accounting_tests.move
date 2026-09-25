// 覆盖两时点重建、检查点引用、奖励精度和容量边界，并用逐 Epoch 历史模型独立核对权益。
#[test_only]
module topo_framework::poc_accounting_tests {
    use std::option;
    use std::signer;
    use topo_framework::coin;
    use topo_framework::poc_accounting as ledger;
    use topo_framework::poc_allocation;
    use topo_framework::poc_power_store;
    use topo_framework::staking_config;
    use topo_framework::topo_coin;

    const POOL: address = @0xa;
    const OTHER_POOL: address = @0xb;
    const Q: u256 = 340282366920938463463374607431768211456;
    const MAX_UNITS: u128 = 1329227995784915872903807060280344576;

    fun setup(framework: &signer) {
        ledger::prepare_for_test(framework, 1, 2, 4);
        ledger::enable_pool_for_test(framework, POOL);
        ledger::enable_pool_for_test(framework, OTHER_POOL);
    }

    fun allocate(user: &signer, units: u128, next_units: u128, bps: u64, boundary: u64) {
        ledger::replace_for_test(user, vector[POOL], vector[bps], units, next_units, boundary);
    }

    fun assert_pool_change(change: &ledger::PoolChange, epoch: u64, remove: u128, add: u128, refs: u64) {
        let (actual_epoch, actual_remove, actual_add, actual_refs) = ledger::pool_change_fields(change);
        assert!(actual_epoch == epoch && actual_remove == remove && actual_add == add && actual_refs == refs, 99);
    }

    #[test]
    fun poc_normalized_units_convert_to_pool_power() {
        let index = 16602069666338596454;
        let units = poc_power_store::normalize_units_for_test(100, index);
        assert!(units == 7281777, 0);
        assert!(ledger::pool_power(units, index) == 99, 1);
        let maximum = poc_power_store::normalize_units_for_test(18446744073709551615, 16777216);
        assert!(maximum < MAX_UNITS && maximum > MAX_UNITS / 2, 2);
    }

    #[test]
    #[expected_failure(abort_code = 0x10009, location = topo_framework::poc_accounting)]
    fun poc_pool_power_rejects_index_above_scale() {
        ledger::pool_power(1, 18446744073709551617);
    }

    #[test(framework = @topo_framework, user = @0x11)]
    fun poc_two_boundary_rebuild(framework: &signer, user: &signer) {
        setup(framework);
        allocate(user, 100, 100, 5000, 10);
        ledger::advance_for_test(2, vector[POOL], true);
        allocate(user, 100, 200, 2500, 10);
        let changes = ledger::pool_changes_for_test(POOL);
        assert!(changes.length() == 2, 0);
        assert_pool_change(&changes[0], 3, 50, 25, 1);
        assert_pool_change(&changes[1], 10, 25, 50, 1);
        assert!(ledger::preview_pool_units(POOL, 2) == 50, 3);
        assert!(ledger::preview_pool_units(POOL, 3) == 25, 4);
        assert!(ledger::preview_pool_units(POOL, 10) == 50, 5);
    }

    #[test(framework = @topo_framework, user = @0x11)]
    fun poc_coincident_boundary_omits_unchanged_units(framework: &signer, user: &signer) {
        setup(framework);
        allocate(user, 100, 100, 5000, 3);
        ledger::advance_for_test(2, vector[POOL], true);
        allocate(user, 100, 200, 2500, 3);
        assert!(ledger::pool_changes_for_test(POOL).is_empty(), 0);
        let (units, changes, _, _) = ledger::get_position(signer::address_of(user), POOL);
        assert!(units == 50 && changes.is_empty(), 1);
        ledger::advance_for_test(3, vector[POOL], true);
        let (ratios, pending) = ledger::get_allocations(signer::address_of(user));
        let (pool, bps) = ledger::pool_ratio_fields(&ratios[0]);
        assert!(option::is_none(&pending) && pool == POOL && bps == 2500, 2);
    }

    #[test(framework = @topo_framework, first = @0x11, second = @0x12)]
    fun poc_upload_and_allocation_commute(framework: &signer, first: &signer, second: &signer) {
        setup(framework);
        allocate(first, 100, 100, 5000, 10);
        allocate(second, 100, 100, 5000, 10);
        ledger::advance_for_test(2, vector[POOL], true);
        ledger::sync_for_test(signer::address_of(first), 100, 200, 10);
        allocate(first, 100, 200, 2500, 10);
        allocate(second, 100, 100, 2500, 10);
        ledger::sync_for_test(signer::address_of(second), 100, 200, 10);
        let (units1, changes1, amount1, remainder1) = ledger::get_position(signer::address_of(first), POOL);
        let (units2, changes2, amount2, remainder2) = ledger::get_position(signer::address_of(second), POOL);
        assert!(units1 == units2 && changes1 == changes2 && amount1 == amount2 && remainder1 == remainder2, 0);
        let changes = ledger::pool_changes_for_test(POOL);
        assert_pool_change(&changes[0], 3, 100, 50, 2);
        assert_pool_change(&changes[1], 10, 50, 100, 2);
    }

    #[test(framework = @topo_framework, user = @0x11)]
    fun poc_cover_pending_back_to_active_preserves_future_version(framework: &signer, user: &signer) {
        setup(framework);
        allocate(user, 100, 100, 5000, 10);
        ledger::advance_for_test(2, vector[POOL], true);
        allocate(user, 100, 200, 2500, 10);
        allocate(user, 100, 200, 5000, 10);
        let changes = ledger::pool_changes_for_test(POOL);
        assert!(changes.length() == 1, 0);
        assert_pool_change(&changes[0], 10, 50, 100, 1);
        allocate(user, 100, 100, 5000, 10);
        assert!(ledger::pool_changes_for_test(POOL).is_empty(), 2);
    }

    #[test(framework = @topo_framework, first = @0x11, second = @0x12)]
    fun poc_net_zero_change_retains_reward_checkpoint(framework: &signer, first: &signer, second: &signer) {
        setup(framework);
        let (burn, mint) = topo_coin::initialize_for_test(framework);
        allocate(first, 100, 100, 10000, 20);
        ledger::advance_for_test(2, vector[POOL], true);
        ledger::credit_for_test(POOL, coin::mint(100, &mint));
        ledger::replace_for_test(first, vector[], vector[], 100, 100, 20);
        allocate(second, 100, 100, 10000, 20);
        let changes = ledger::pool_changes_for_test(POOL);
        assert_pool_change(&changes[0], 3, 100, 100, 2);
        ledger::advance_for_test(3, vector[POOL], true);
        assert!(ledger::checkpoint_refs_for_test(POOL, 3) == 2, 1);
        ledger::credit_for_test(POOL, coin::mint(50, &mint));
        let second_reward = ledger::claim_for_test(second, vector[POOL]);
        assert!(coin::value(&second_reward) == 50, 2);
        coin::burn(second_reward, &burn);
        assert!(ledger::checkpoint_refs_for_test(POOL, 3) == 1, 3);
        let first_reward = ledger::claim_for_test(first, vector[POOL]);
        assert!(coin::value(&first_reward) == 100, 4);
        coin::burn(first_reward, &burn);
        assert!(ledger::checkpoint_refs_for_test(POOL, 3) == 0, 5);
        coin::destroy_zero(ledger::claim_for_test(first, vector[POOL]));
        coin::destroy_mint_cap(mint);
        coin::destroy_burn_cap(burn);
    }

    #[test(framework = @topo_framework, user = @0x11)]
    fun poc_exited_pool_claim_advances_only_installed_epoch(framework: &signer, user: &signer) {
        setup(framework);
        let (burn, mint) = topo_coin::initialize_for_test(framework);
        allocate(user, 100, 100, 10000, 20);
        ledger::advance_for_test(2, vector[POOL], true);
        ledger::credit_for_test(POOL, coin::mint(77, &mint));
        ledger::replace_for_test(user, vector[], vector[], 100, 100, 20);
        ledger::advance_for_test(3, vector[], true);
        ledger::advance_for_test(4, vector[], true);
        let (units, changes, amount, _) = ledger::get_position(signer::address_of(user), POOL);
        // 池内 77 * Q / 100 向下取整，用户持仓中仍须保留属于自己的小数权益。
        assert!(units == 0 && changes.is_empty() && amount == 76, 0);
        assert!(ledger::checkpoint_refs_for_test(POOL, 3) == 0, 1);
        let reward = ledger::claim_for_test(user, vector[POOL]);
        assert!(coin::value(&reward) == amount && ledger::current_epoch() == 4, 2);
        coin::burn(reward, &burn);
        coin::destroy_zero(ledger::claim_for_test(user, vector[POOL]));
        assert!(ledger::checkpoint_refs_for_test(POOL, 3) == 0, 3);
        coin::destroy_mint_cap(mint);
        coin::destroy_burn_cap(burn);
    }

    #[test(framework = @topo_framework, user = @0x11)]
    fun poc_query_and_claim_share_matured_reward_segments(framework: &signer, user: &signer) {
        setup(framework);
        let (burn, mint) = topo_coin::initialize_for_test(framework);
        allocate(user, 8, 8, 10000, 4);
        ledger::advance_for_test(2, vector[POOL], true);
        ledger::credit_for_test(POOL, coin::mint(3, &mint));
        // 下一 Epoch 减半、边界恢复；两个成熟时点均须按各自之前的 units 分段计奖。
        allocate(user, 8, 16, 5000, 4);
        ledger::advance_for_test(3, vector[POOL], true);
        ledger::credit_for_test(POOL, coin::mint(5, &mint));
        ledger::advance_for_test(4, vector[], true);

        // Epoch 3 的检查点已落盘，Epoch 4 的退出池变化只能通过虚拟检查点预览。
        let owner = signer::address_of(user);
        let (units, changes, amount, remainder) = ledger::get_position(owner, POOL);
        assert!(units == 8 && changes.is_empty() && amount == 8 && remainder == 0, 0);
        let (again_units, again_changes, again_amount, again_remainder) = ledger::get_position(owner, POOL);
        assert!(again_units == units && again_changes == changes
            && again_amount == amount && again_remainder == remainder, 1);
        assert!(ledger::checkpoint_refs_for_test(POOL, 3) == 1
            && ledger::checkpoint_refs_for_test(POOL, 4) == 0, 2);

        let reward = ledger::claim_for_test(user, vector[POOL]);
        assert!(coin::value(&reward) == amount, 3);
        coin::burn(reward, &burn);
        let (after_units, after_changes, after_amount, after_remainder) = ledger::get_position(owner, POOL);
        assert!(after_units == units && after_changes == changes
            && after_amount == 0 && after_remainder == remainder, 4);
        assert!(ledger::checkpoint_refs_for_test(POOL, 3) == 0
            && ledger::checkpoint_refs_for_test(POOL, 4) == 0, 5);
        coin::destroy_mint_cap(mint);
        coin::destroy_burn_cap(burn);
    }

    #[test(framework = @topo_framework, user = @0x11)]
    fun poc_fractional_entitlement_survives_claim(framework: &signer, user: &signer) {
        setup(framework);
        let (burn, mint) = topo_coin::initialize_for_test(framework);
        allocate(user, 3, 3, 10000, 20);
        ledger::advance_for_test(2, vector[POOL], true);
        ledger::credit_for_test(POOL, coin::mint(1, &mint));
        coin::destroy_zero(ledger::claim_for_test(user, vector[POOL]));
        let (_, _, amount, remainder) = ledger::get_position(signer::address_of(user), POOL);
        assert!(amount == 0 && remainder == Q - 1, 0);
        ledger::advance_for_test(3, vector[POOL], true);
        ledger::credit_for_test(POOL, coin::mint(1, &mint));
        let reward = ledger::claim_for_test(user, vector[POOL]);
        assert!(coin::value(&reward) == 1, 1);
        coin::burn(reward, &burn);
        let (_, _, _, remainder) = ledger::get_position(signer::address_of(user), POOL);
        assert!(remainder == Q - 2, 2);
        coin::destroy_mint_cap(mint);
        coin::destroy_burn_cap(burn);
    }

    #[test(framework = @topo_framework, first = @0x11, second = @0x12)]
    fun poc_final_capacity_accepts_replacing_large_chain(framework: &signer, first: &signer, second: &signer) {
        setup(framework);
        let half = MAX_UNITS / 2;
        allocate(first, half, half, 10000, 10);
        allocate(second, half, half, 10000, 10);
        ledger::advance_for_test(2, vector[POOL], true);
        assert!(ledger::preview_pool_units(POOL, 2) == MAX_UNITS, 0);
        // 必须整体替换 E+1 撤出与 B 恢复两段；若只撤销前段，B 的临时预测值会超过 MAX_UNITS。
        // 最终两段均已替换后容量合法，不能因中间状态拒绝本次操作。
        allocate(first, half, MAX_UNITS - 2, 5000, 10);
        allocate(first, half, MAX_UNITS - 2, 2500, 10);
        assert!(ledger::preview_pool_units(POOL, 3) == half + half / 4, 1);
        assert!(ledger::preview_pool_units(POOL, 10) == half + (MAX_UNITS - 2) / 4, 2);
    }

    #[test(framework = @topo_framework, first = @0x11, second = @0x12)]
    fun poc_pool_capacity_accepts_exact_limit_at_each_horizon(
        framework: &signer, first: &signer, second: &signer,
    ) {
        setup(framework);
        let half = MAX_UNITS / 2;
        let quarter = MAX_UNITS / 4;

        // 两笔分配先使 E+1 和 B 都恰好达到上限；推进后同一聚合值成为当前值。
        allocate(first, half, half, 10000, 10);
        allocate(second, half, half, 10000, 10);
        assert!(ledger::preview_pool_units(POOL, 1) == 0, 0);
        assert!(ledger::preview_pool_units(POOL, 2) == MAX_UNITS, 1);
        assert!(ledger::preview_pool_units(POOL, 10) == MAX_UNITS, 2);
        ledger::advance_for_test(2, vector[POOL], true);
        assert!(ledger::preview_pool_units(POOL, 2) == MAX_UNITS, 3);

        // 当前池保持恰好上限；把两名用户转向另一池后，单独构造 E+1 未满、B 恰好上限。
        ledger::replace_for_test(first, vector[OTHER_POOL], vector[10000], quarter, half, 10);
        ledger::replace_for_test(second, vector[OTHER_POOL], vector[10000], quarter, half, 10);
        assert!(ledger::preview_pool_units(POOL, 2) == MAX_UNITS, 4);
        assert!(ledger::preview_pool_units(OTHER_POOL, 3) == MAX_UNITS / 2, 5);
        assert!(ledger::preview_pool_units(OTHER_POOL, 10) == MAX_UNITS, 6);
    }

    #[test(framework = @topo_framework, user = @0x11)]
    fun poc_matured_withdrawal_is_settled_before_configuration_promotion(framework: &signer, user: &signer) {
        setup(framework);
        allocate(user, 100, 100, 10000, 10);
        ledger::advance_for_test(2, vector[POOL], true);
        ledger::replace_for_test(user, vector[OTHER_POOL], vector[10000], 100, 100, 10);
        ledger::advance_for_test(3, vector[POOL, OTHER_POOL], true);
        assert!(ledger::checkpoint_refs_for_test(POOL, 3) == 1, 0);
        ledger::sync_for_test(signer::address_of(user), 100, 200, 10);
        assert!(ledger::checkpoint_refs_for_test(POOL, 3) == 0, 1);
        assert!(ledger::preview_pool_units(POOL, 10) == 0, 2);
        assert!(ledger::preview_pool_units(OTHER_POOL, 10) == 200, 3);
    }

    #[test(framework = @topo_framework, user = @0x11)]
    fun poc_two_matured_changes_then_new_version(framework: &signer, user: &signer) {
        setup(framework);
        allocate(user, 100, 100, 5000, 4);
        ledger::advance_for_test(2, vector[POOL], true);
        allocate(user, 100, 200, 2500, 4);
        ledger::advance_for_test(3, vector[POOL], true);
        ledger::advance_for_test(4, vector[POOL], true);
        ledger::advance_for_test(5, vector[POOL], true);
        assert!(ledger::checkpoint_refs_for_test(POOL, 3) == 1, 0);
        assert!(ledger::checkpoint_refs_for_test(POOL, 4) == 1, 1);
        ledger::sync_for_test(signer::address_of(user), 200, 300, 8);
        assert!(ledger::checkpoint_refs_for_test(POOL, 3) == 0, 2);
        assert!(ledger::checkpoint_refs_for_test(POOL, 4) == 0, 3);
        let (units, changes, _, _) = ledger::get_position(signer::address_of(user), POOL);
        assert!(units == 50 && changes.length() == 1, 4);
        let (epoch, target_units) = ledger::position_change_fields(&changes[0]);
        assert!(epoch == 8 && target_units == 75, 5);
        assert!(ledger::preview_pool_units(POOL, 8) == 75, 6);
    }

    #[test(framework = @topo_framework, user = @0x11)]
    fun poc_independent_epoch_reward_model(framework: &signer, user: &signer) {
        setup(framework);
        let (burn, mint) = topo_coin::initialize_for_test(framework);
        let accrued = 0u256;
        let paid = 0u64;
        let total = 0u64;
        let epoch = 2u64;
        while (epoch < 34) {
            let units = ((epoch * 17) % 23 + 1) as u128;
            allocate(user, units, units, 10000, 100);
            ledger::advance_for_test(epoch, vector[POOL], true);
            let reward = epoch * 13 % 37;
            // 独立参考模型直接计算本 Epoch 的 units 与应得权益，不复用账本变化链。
            accrued = accrued + (units as u256) * ((reward as u256) * Q / (units as u256));
            total = total + reward;
            ledger::credit_for_test(POOL, coin::mint(reward, &mint));
            let (logical_units, changes, claimable, remainder) = ledger::get_position(signer::address_of(user), POOL);
            assert!(logical_units == units && changes.is_empty(), 0);
            assert!((claimable as u256) == accrued / Q && remainder == accrued % Q, 1);
            if (epoch % 5 == 0) {
                let claim = ledger::claim_for_test(user, vector[POOL]);
                assert!((coin::value(&claim) as u256) == accrued / Q, 2);
                paid = paid + coin::value(&claim);
                accrued = accrued % Q;
                coin::burn(claim, &burn);
            };
            let (_, _, _, vault, _) = ledger::get_pool(POOL);
            assert!(vault + paid == total, 3);
            epoch = epoch + 1;
        };
        coin::destroy_mint_cap(mint);
        coin::destroy_burn_cap(burn);
    }

    #[test(framework = @topo_framework)]
    fun poc_dynamic_growth_configuration(framework: &signer) {
        setup(framework);
        ledger::validate_config(&ledger::new_power_params(100000000, 10, 10, 4), 25, true);
        ledger::validate_fee_limit(1000000);
    }

    #[test(framework = @topo_framework)]
    fun poc_dynamic_growth_exact_threshold_is_independent_of_min_power(framework: &signer) {
        ledger::prepare_limits_for_test(framework, 1, 2,
            ledger::new_power_params(100000000, 1, 1, 4), ledger::default_deployment_limits());
        // 100 个最低权重节点的 1% 增长预算恰能容纳一个替补；权重大小不应改变结果。
        ledger::validate_config(&ledger::new_power_params(100000000, 1, 1, 100), 1, true);
        let maximum = 18446744073709551615;
        ledger::validate_config(&ledger::new_power_params(100000000, maximum, maximum, 100), 1, true);
    }

    #[test(framework = @topo_framework)]
    #[expected_failure(abort_code = 0x10007, location = topo_framework::poc_accounting)]
    fun poc_dynamic_growth_rejects_just_below_threshold(framework: &signer) {
        ledger::prepare_limits_for_test(framework, 1, 2,
            ledger::new_power_params(100000000, 1, 1, 4), ledger::default_deployment_limits());
        // 仍有候选名额，但 99 个节点的 1% 预算不足以接纳一个最低权重替补。
        let maximum = 18446744073709551615;
        ledger::validate_config(&ledger::new_power_params(100000000, maximum, maximum, 99), 1, true);
    }

    #[test(framework = @topo_framework)]
    #[expected_failure(abort_code = 0x10007, location = topo_framework::poc_accounting)]
    fun poc_dynamic_growth_rejects_unreplaceable_committee(framework: &signer) {
        setup(framework);
        ledger::validate_config(&ledger::new_power_params(100000000, 10, 10, 4), 20, true);
    }

    #[test(framework = @topo_framework)]
    #[expected_failure(abort_code = 0x10007, location = topo_framework::poc_accounting)]
    fun poc_dynamic_minimum_equal_to_validator_limit_rejected(framework: &signer) {
        // 25% 增长预算已足够支持替补，此例仅因没有预留候选名额而非法。
        // 因此 min_validators < V_LIMIT 必须独立校验。
        ledger::prepare_limits_for_test(framework, 1, 2,
            ledger::new_power_params(100000000, 10, 10, 4),
            ledger::new_deployment_limits(4, 4, 4, 4, 1));
    }

    #[test(framework = @topo_framework)]
    fun poc_max_power_is_not_divided_by_candidate_capacity(framework: &signer) {
        setup(framework);
        ledger::validate_config(&ledger::new_power_params(100000000, 1, 18446744073709551615, 4), 25, true);
    }

    #[test(framework = @topo_framework, user = @0x11)]
    #[expected_failure(abort_code = 0x10002, location = topo_framework::poc_accounting)]
    fun poc_explicit_zero_ratio_rejected(framework: &signer, user: &signer) {
        setup(framework);
        allocate(user, 100, 100, 0, 10);
    }

    #[test(framework = @topo_framework, user = @0x11)]
    #[expected_failure(abort_code = 0x10003, location = topo_framework::poc_accounting)]
    fun poc_duplicate_pool_rejected(framework: &signer, user: &signer) {
        setup(framework);
        ledger::replace_for_test(user, vector[POOL, POOL], vector[5000, 5000], 100, 100, 10);
    }

    #[test(framework = @topo_framework, first = @0x11, second = @0x12)]
    #[expected_failure(abort_code = 0x20008, location = topo_framework::poc_accounting)]
    fun poc_future_pool_capacity_rejected(framework: &signer, first: &signer, second: &signer) {
        setup(framework);
        allocate(first, MAX_UNITS / 2, MAX_UNITS / 2, 10000, 10);
        assert!(ledger::preview_pool_units(POOL, 2) == MAX_UNITS / 2, 0);
        // E+1 增至上限加一时立即拒绝，变化不能留待 Epoch 推进时才发现。
        allocate(second, MAX_UNITS / 2 + 1, MAX_UNITS / 2 + 1, 10000, 10);
    }

    #[test(framework = @topo_framework, first = @0x11, second = @0x12)]
    #[expected_failure(abort_code = 0x20008, location = topo_framework::poc_accounting)]
    fun poc_boundary_only_pool_capacity_rejected(
        framework: &signer, first: &signer, second: &signer,
    ) {
        setup(framework);
        let half = MAX_UNITS / 2;
        let quarter = MAX_UNITS / 4;
        ledger::replace_for_test(first, vector[POOL], vector[10000], quarter, half, 10);
        assert!(ledger::preview_pool_units(POOL, 2) == quarter, 0);
        assert!(ledger::preview_pool_units(POOL, 10) == half, 1);
        // E+1 合计仅为上限一半；第二笔只让 B 达到上限加一，必须在写入阶段拒绝。
        ledger::replace_for_test(second, vector[POOL], vector[10000], quarter, half + 1, 10);
    }

    #[test(framework = @topo_framework)]
    #[expected_failure(abort_code = 0x3000d, location = topo_framework::poc_accounting)]
    fun poc_zero_reward_still_prevents_double_credit(framework: &signer) {
        setup(framework);
        // 启用池尚无任何持仓，当前和下一 Epoch 的聚合 units 及计奖基数都为零。
        ledger::advance_zero_pool_for_test(2, POOL);
        let (before_units, before_next_units, before_base, before_vault, before_index) =
            ledger::get_pool(POOL);
        assert!(before_units == 0 && before_next_units == 0 && before_base == 0
            && before_vault == 0 && before_index == 0, 0);
        let delta = ledger::credit_for_test(POOL, coin::zero());
        let (units, next_units, base, vault, index) = ledger::get_pool(POOL);
        assert!(delta == 0 && units == before_units && next_units == before_next_units
            && base == before_base && vault == before_vault && index == before_index, 1);
        // 零额入账仍须推进内部 reward_epoch；同一 Epoch 再次入账精确拒绝。
        ledger::credit_for_test(POOL, coin::zero());
    }

    #[test(framework = @topo_framework)]
    #[expected_failure(abort_code = 0x3000e, location = topo_framework::poc_accounting)]
    fun poc_zero_unit_pool_rejects_positive_reward_atomically(framework: &signer) {
        setup(framework);
        let (burn, mint) = topo_coin::initialize_for_test(framework);
        ledger::advance_zero_pool_for_test(2, POOL);
        let (units, next_units, base, vault, index) = ledger::get_pool(POOL);
        assert!(units == 0 && next_units == 0 && base == 0 && vault == 0 && index == 0, 0);
        // 正奖励已在同一事务内铸造；生产入口因零 units 以金库不变量错误中止，
        // Move 测试事务随之整体回滚，不提交铸币、金库、指数或 reward_epoch 修改。
        let _ = ledger::credit_for_test(POOL, coin::mint(1, &mint));
        coin::destroy_mint_cap(mint);
        coin::destroy_burn_cap(burn);
    }

    #[test(framework = @topo_framework, user = @0x11)]
    #[expected_failure(abort_code = 0x3000c, location = topo_framework::poc_accounting)]
    fun poc_missing_checkpoint_aborts_even_without_rewards(framework: &signer, user: &signer) {
        setup(framework);
        allocate(user, 100, 100, 10000, 10);
        ledger::advance_for_test(2, vector[POOL], true);
        ledger::corrupt_checkpoint_for_test(POOL, 2, true);
        coin::destroy_zero(ledger::claim_for_test(user, vector[POOL]));
    }

    #[test(framework = @topo_framework, user = @0x11)]
    #[expected_failure(abort_code = 0x3000c, location = topo_framework::poc_accounting)]
    fun poc_missing_checkpoint_aborts_readonly_query(framework: &signer, user: &signer) {
        setup(framework);
        allocate(user, 100, 100, 10000, 10);
        ledger::advance_for_test(2, vector[POOL], true);
        ledger::corrupt_checkpoint_for_test(POOL, 2, true);
        ledger::get_position(signer::address_of(user), POOL);
    }

    #[test(framework = @topo_framework, user = @0x11)]
    #[expected_failure(abort_code = 0x3000f, location = topo_framework::poc_accounting)]
    fun poc_checkpoint_reference_underflow_aborts(framework: &signer, user: &signer) {
        setup(framework);
        allocate(user, 100, 100, 10000, 10);
        ledger::advance_for_test(2, vector[POOL], true);
        ledger::corrupt_checkpoint_for_test(POOL, 2, false);
        coin::destroy_zero(ledger::claim_for_test(user, vector[POOL]));
    }

    #[test(framework = @topo_framework, user = @0x11)]
    #[expected_failure(abort_code = 0x3000f, location = topo_framework::poc_accounting)]
    fun poc_zero_checkpoint_reference_aborts_readonly_query(framework: &signer, user: &signer) {
        setup(framework);
        allocate(user, 100, 100, 10000, 10);
        ledger::advance_for_test(2, vector[POOL], true);
        ledger::corrupt_checkpoint_for_test(POOL, 2, false);
        ledger::get_position(signer::address_of(user), POOL);
    }

    #[test(framework = @topo_framework, user = @0x11)]
    #[expected_failure(abort_code = 0x3000e, location = topo_framework::poc_accounting)]
    fun poc_underfunded_vault_aborts_without_resetting_entitlement(framework: &signer, user: &signer) {
        setup(framework);
        let (burn, mint) = topo_coin::initialize_for_test(framework);
        allocate(user, 1, 1, 10000, 10);
        ledger::advance_for_test(2, vector[POOL], true);
        ledger::credit_for_test(POOL, coin::mint(1, &mint));
        coin::burn(ledger::drain_vault_for_test(POOL), &burn);
        coin::destroy_mint_cap(mint);
        coin::destroy_burn_cap(burn);
        coin::destroy_zero(ledger::claim_for_test(user, vector[POOL]));
    }

    #[test(framework = @topo_framework)]
    fun poc_native_preparation_and_permanent_activation(framework: &signer) {
        ledger::prepare_for_test(framework, 9, 12, 4);
        assert!(!ledger::target_poc_enabled(10), 0);
        ledger::advance_for_test(10, vector[], false);
        ledger::advance_for_test(11, vector[], false);
        ledger::advance_for_test(12, vector[], true);
        let (_, _, first, _, _, _, _) = ledger::get_config();
        assert!(first == option::some(12), 1);
        assert!(ledger::target_poc_enabled(10012), 2);
        assert!(ledger::target_poc_enabled(18446744073709551615), 3);
        ledger::advance_for_test(13, vector[], true);
        let (_, _, first, _, _, _, _) = ledger::get_config();
        assert!(first == option::some(12), 4);
    }

    #[test(framework = @topo_framework)]
    fun poc_default_limits_allow_large_reward_base(framework: &signer) {
        // 不按理论最大全委员会限制 max_power，也不另设计奖基数上限。
        let max_power = 18446744073709551615;
        ledger::prepare_limits_for_test(framework, 1, 2,
            ledger::new_power_params(100000000, 100000000, max_power, 5),
            ledger::default_deployment_limits());
        assert!(ledger::fee_max() == 100000000000, 1);
        let (_, _, _, _, params, _, _) = ledger::get_config();
        let (_, _, installed_max_power, _) = ledger::get_power_params_fields(&params);
        assert!(installed_max_power == max_power, 2);

        ledger::advance_for_test(2, vector[], true);
        let (_, _, first, _, _, pending, _) = ledger::get_config();
        assert!(first == option::some(2) && pending.is_none(), 3);
    }

    #[test(framework = @topo_framework, user = @0x11)]
    fun poc_reward_accounting_near_u64_max_epoch(framework: &signer, user: &signer) {
        // 隔离奖励账本：临近 Epoch 类型上界仍可启用、连续入账和领取，无需预留 F+H。
        let maximum = 18446744073709551615u64;
        ledger::prepare_for_test(framework, maximum - 3, maximum - 2, 4);
        ledger::enable_pool_for_test(framework, POOL);
        let (burn, mint) = topo_coin::initialize_for_test(framework);
        allocate(user, 1, 1, 10000, maximum);
        for (offset in 0..3) {
            ledger::advance_for_test(maximum - 2 + offset, vector[POOL], true);
            ledger::credit_for_test(POOL, coin::mint(1, &mint));
            let (_, _, amount, remainder) = ledger::get_position(signer::address_of(user), POOL);
            assert!(amount == 1 && remainder == 0, 0);
            let reward = ledger::claim_for_test(user, vector[POOL]);
            assert!(coin::value(&reward) == 1, 1);
            coin::burn(reward, &burn);
        };
        assert!(ledger::current_epoch() == maximum, 2);
        coin::destroy_mint_cap(mint);
        coin::destroy_burn_cap(burn);
    }

    // 用超出生产经济规格的测试金额覆盖 u64 金库边界：三次入账后两名用户才领取。
    // 领取后的剩余权益必须仍归原用户，不能作为池级残差重新分配。
    fun full_reward_vault(framework: &signer, first: &signer, second: &signer, pool_units: u128) {
        let maximum = 18446744073709551615u64;
        let reward = maximum / 3;
        ledger::prepare_limits_for_test(framework, 1, 2,
            ledger::new_power_params(100000000, 1, 1, 4),
            ledger::new_deployment_limits(4, 4, 4, 5, reward - 1));
        ledger::enable_pool_for_test(framework, POOL);
        let (burn, mint) = topo_coin::initialize_for_test(framework);
        allocate(first, pool_units / 2, pool_units / 2, 10000, 10);
        allocate(second, pool_units / 2, pool_units / 2, 10000, 10);
        let epoch = 2;
        while (epoch < 5) {
            ledger::advance_for_test(epoch, vector[POOL], true);
            ledger::credit_for_test(POOL, coin::mint(reward, &mint));
            let cumulative = ((epoch - 1) as u256) * (reward as u256);
            // 两种被测池的总 units 均能整除 Q，因此等量持仓各得一半奖励，以 Q 精度记账。
            // 这一预期直接来自分配公式，与检查点实现及领取时点无关。
            let expected = cumulative * Q / 2;
            let (units, changes, amount, remainder) = ledger::get_position(signer::address_of(first), POOL);
            assert!(units == pool_units / 2 && changes.is_empty(), 0);
            assert!((amount as u256) * Q + remainder == expected, 1);
            let (units, _, _, vault, index) = ledger::get_pool(POOL);
            assert!(units == pool_units && (vault as u256) == cumulative, 2);
            assert!(index == cumulative * Q / (pool_units as u256), 3);
            epoch = epoch + 1;
        };
        let first_reward = ledger::claim_for_test(first, vector[POOL]);
        let second_reward = ledger::claim_for_test(second, vector[POOL]);
        assert!(coin::value(&first_reward) == maximum / 2 && coin::value(&second_reward) == maximum / 2, 5);
        let (_, _, _, vault, _) = ledger::get_pool(POOL);
        assert!(vault == 1 && (coin::value(&first_reward) as u256)
            + (coin::value(&second_reward) as u256) + (vault as u256) == (maximum as u256), 6);
        let (_, _, amount, remainder) = ledger::get_position(signer::address_of(first), POOL);
        assert!(amount == 0 && remainder == Q / 2, 7);
        let (_, _, amount, remainder) = ledger::get_position(signer::address_of(second), POOL);
        assert!(amount == 0 && remainder == Q / 2, 8);
        coin::destroy_zero(ledger::claim_for_test(first, vector[POOL]));
        coin::destroy_zero(ledger::claim_for_test(second, vector[POOL]));
        coin::burn(first_reward, &burn);
        coin::burn(second_reward, &burn);
        coin::destroy_mint_cap(mint);
        coin::destroy_burn_cap(burn);
    }

    #[test(framework = @topo_framework, first = @0x11, second = @0x12)]
    fun poc_full_reward_vault_maximum_pool(framework: &signer, first: &signer, second: &signer) {
        full_reward_vault(framework, first, second, MAX_UNITS);
    }

    #[test(framework = @topo_framework, first = @0x11, second = @0x12)]
    fun poc_full_reward_vault_large_index(framework: &signer, first: &signer, second: &signer) {
        full_reward_vault(framework, first, second, 2);
    }

    // 只铸造一次 10^18 Octa，反复领取并作为交易费再次入账；历史累计可超过 u64，而余额不超过总量。
    fun recycled_rewards(framework: &signer, user: &signer, other: &signer, pool_units: u128) {
        let supply = 1000000000000000000u64;
        ledger::prepare_limits_for_test(framework, 1, 2,
            ledger::new_power_params(100000000, 1, 1, 4),
            ledger::new_deployment_limits(4, 4, 4, 5, supply));
        ledger::enable_pool_for_test(framework, POOL);
        let (burn, mint) = topo_coin::initialize_for_test(framework);
        let reward = coin::mint(supply, &mint);
        let user_units = if (pool_units == 1) { 1 } else { pool_units / 2 };
        let user_reward = if (pool_units == 1) { supply } else { supply / 2 };
        allocate(user, user_units, user_units, 10000, 100);
        // 单用户版本必须严格小于池容量；两个合法版本聚合后恰好达到最大池容量。
        if (pool_units > 1) allocate(other, user_units, user_units, 10000, 100);
        for (epoch in 2..22) {
            ledger::advance_for_test(epoch, vector[POOL], true);
            ledger::credit_for_test(POOL, reward);
            let (_, _, amount, remainder) = ledger::get_position(signer::address_of(user), POOL);
            assert!(amount == user_reward && remainder == 0, 0);
            let (_, _, _, vault, index) = ledger::get_pool(POOL);
            let cumulative = ((epoch - 1) as u256) * (supply as u256);
            assert!(vault == supply && index == cumulative * Q / (pool_units as u256), 1);
            reward = ledger::claim_for_test(user, vector[POOL]);
            if (pool_units > 1) {
                let (_, _, amount, remainder) = ledger::get_position(signer::address_of(other), POOL);
                assert!(amount == user_reward && remainder == 0, 6);
                coin::merge(&mut reward, ledger::claim_for_test(other, vector[POOL]));
            };
            assert!(coin::value(&reward) == supply, 2);
            let (_, _, amount, remainder) = ledger::get_position(signer::address_of(user), POOL);
            assert!(amount == 0 && remainder == 0, 3);
        };
        let (_, _, _, vault, index) = ledger::get_pool(POOL);
        assert!(vault == 0 && index * (pool_units as u256) / Q == 20000000000000000000, 4);
        if (pool_units == 1) assert!(index > 18446744073709551615u256 * Q, 5);
        coin::burn(reward, &burn);
        coin::destroy_mint_cap(mint);
        coin::destroy_burn_cap(burn);
    }

    #[test(framework = @topo_framework, user = @0x11, other = @0x12)]
    fun poc_recycled_rewards_exceed_u64_lifetime(framework: &signer, user: &signer, other: &signer) {
        recycled_rewards(framework, user, other, 1);
    }

    #[test(framework = @topo_framework, user = @0x11, other = @0x12)]
    fun poc_recycled_rewards_maximum_pool(framework: &signer, user: &signer, other: &signer) {
        recycled_rewards(framework, user, other, MAX_UNITS);
    }

    #[test(framework = @topo_framework, user = @0x11)]
    fun poc_cancel_params_and_reschedule_keep_baseline(framework: &signer, user: &signer) {
        ledger::prepare_for_test(framework, 1, 5, 4);
        poc_power_store::initialize_for_test(framework, 1, 9995, 60, @topo_framework);
        staking_config::initialize_for_test(framework, 1, 1000000, 60, true, 1, 100, 25);
        ledger::enable_pool_for_test(framework, POOL);
        let (period, boundary, index, next_index) =
            poc_power_store::get_normalization_clock();
        allocate(user, 100, 200, 5000, 62);
        let changes = ledger::pool_changes_for_test(POOL);
        let (epoch, activation, first, mode, params, _, limits) = ledger::get_config();
        let pending = ledger::new_power_params(100000000, 2, 1000, 4);
        poc_allocation::schedule_power_params(framework, pending, 2);
        assert!(ledger::get_target_params(2) == pending, 0);
        poc_allocation::cancel_pending_power_params(framework);
        assert!(ledger::get_target_params(2) == params, 1);
        let (e, a, f, m, p, pending, l) = ledger::get_config();
        assert!(e == epoch && a == activation && f == first && m == mode && p == params
            && pending.is_none() && l == limits, 2);
        poc_allocation::reschedule_activation(framework, 8);
        let (e, a, f, m, p, pending, l) = ledger::get_config();
        assert!(e == epoch && a == 8 && f == first && m == mode && p == params
            && pending.is_none() && l == limits, 3);
        assert!(!ledger::target_poc_enabled(7) && ledger::target_poc_enabled(8), 4);
        let (cp, b, i, ni) = poc_power_store::get_normalization_clock();
        assert!(cp == period
            && b == boundary && i == index && ni == next_index, 5);
        assert!(ledger::pool_changes_for_test(POOL) == changes && ledger::preview_pool_units(POOL, 2) == 50, 6);
    }

    // 参考模型显式保存每个 Epoch，按版本区间和生效比例计算 units，再重算全部奖励历史。
    // 该模型不模拟 PoolChange、检查点、cursor 或引用计数，用于独立核对奖励金额。
    struct ReferenceEpoch has drop {
        units: vector<u128>,
        rewards: vector<u64>,
    }

    fun reference_accrued(history: &vector<ReferenceEpoch>, position: u64, paid: u64): u256 {
        let earned = 0u256;
        let pool = position % 2;
        for (epoch in 0..history.length()) {
            let row = &history[epoch];
            let pool_units = row.units[pool] + row.units[2 + pool];
            earned = earned + (row.units[position] as u256)
                * ((row.rewards[pool] as u256) * Q / (pool_units as u256));
        };
        earned - (paid as u256) * Q
    }

    fun reference_version(user: u64, epoch: u64): u128 {
        if (epoch < 8) {
            if (user == 0) { 101 } else { 211 }
        } else if (epoch < 16) {
            if (user == 0) { 191 } else { 307 }
        } else {
            if (user == 0) { 431 } else { 617 }
        }
    }

    fun next_random(seed: u64): u64 {
        (((seed as u128) * 1664525 + 1013904223) % 4294967296) as u64
    }

    fun randomized_history(framework: &signer, first: &signer, second: &signer, seed: u64) {
        setup(framework);
        let (burn, mint) = topo_coin::initialize_for_test(framework);
        let ratios = vector[5000u64, 6000];
        let staged = vector[101u128, 211];
        let history = vector<ReferenceEpoch>[];
        let paid = vector[0u64, 0, 0, 0];
        let minted = vector[0u64, 0];
        let pools = vector[POOL, OTHER_POOL];
        for (i in 0..2) {
            let user = if (i == 0) { first } else { second };
            ledger::replace_for_test(user, pools, vector[ratios[i], 10000 - ratios[i]],
                staged[i], staged[i], 8);
        };

        for (target_epoch in 2..18) {
            let epoch = target_epoch - 1;
            let boundary = if (epoch < 8) { 8 } else if (epoch < 16) { 16 } else { 24 };
            for (i in 0..2) {
                let user = if (i == 0) { first } else { second };
                let owner = signer::address_of(user);
                let current = reference_version(i, epoch);
                seed = next_random(seed);
                let upload = epoch == 4 || epoch == 12;
                let upload_first = seed % 2 == 0;
                if (upload && upload_first) {
                    staged[i] = reference_version(i, boundary);
                    ledger::sync_for_test(owner, current, staged[i], boundary);
                };
                if (seed % 3 != 0) {
                    ratios[i] = 1000 + seed % 8001;
                    ledger::replace_for_test(user, pools, vector[ratios[i], 10000 - ratios[i]],
                        current, staged[i], boundary);
                };
                if (upload && !upload_first) {
                    staged[i] = reference_version(i, boundary);
                    ledger::sync_for_test(owner, current, staged[i], boundary);
                };
            };
            ledger::advance_for_test(target_epoch, pools, true);

            let units = vector[0u128, 0, 0, 0];
            for (i in 0..2) {
                let version = reference_version(i, target_epoch);
                units[i * 2] = version * (ratios[i] as u128) / 10000;
                units[i * 2 + 1] = version * ((10000 - ratios[i]) as u128) / 10000;
            };
            let rewards = vector[0u64, 0];
            for (p in 0..2) {
                let total_units = units[p] + units[2 + p];
                assert!(ledger::preview_pool_units(pools[p], target_epoch) == total_units, 10);
                seed = next_random(seed);
                let reward = 1 + seed % 31;
                rewards[p] = reward;
                ledger::credit_for_test(pools[p], coin::mint(reward, &mint));
                minted[p] = minted[p] + reward;
            };
            history.push_back(ReferenceEpoch { units, rewards });

            for (i in 0..2) {
                let user = if (i == 0) { first } else { second };
                for (p in 0..2) {
                    let (actual_units, changes, amount, fraction) = ledger::get_position(signer::address_of(user), pools[p]);
                    let accrued = reference_accrued(&history, i * 2 + p, paid[i * 2 + p]);
                    assert!(actual_units == units[i * 2 + p] && changes.length() <= 2, 11);
                    assert!((amount as u256) == accrued / Q, 12);
                    assert!(fraction == accrued % Q, 13);
                };
            };

            if (seed % 3 == 0 || target_epoch == 17) {
                let i = (seed / 3) % 2;
                let user = if (i == 0) { first } else { second };
                let expected = 0u64;
                for (p in 0..2) {
                    let amount = (reference_accrued(&history, i * 2 + p, paid[i * 2 + p]) / Q) as u64;
                    expected = expected + amount;
                    paid[i * 2 + p] = paid[i * 2 + p] + amount;
                };
                let claim = ledger::claim_for_test(user, pools);
                assert!(coin::value(&claim) == expected, 14);
                coin::burn(claim, &burn);
            };
            for (p in 0..2) {
                let (_, _, _, vault, _) = ledger::get_pool(pools[p]);
                assert!(vault + paid[p] + paid[2 + p] == minted[p], 15);
            };
        };
        coin::destroy_mint_cap(mint);
        coin::destroy_burn_cap(burn);
    }

    #[test(framework = @topo_framework, first = @0x11, second = @0x12)]
    fun poc_randomized_history_seed_1(framework: &signer, first: &signer, second: &signer) {
        randomized_history(framework, first, second, 1);
    }

    #[test(framework = @topo_framework, first = @0x11, second = @0x12)]
    fun poc_randomized_history_seed_7(framework: &signer, first: &signer, second: &signer) {
        randomized_history(framework, first, second, 7);
    }

    #[test(framework = @topo_framework, first = @0x11, second = @0x12)]
    fun poc_randomized_history_seed_31337(framework: &signer, first: &signer, second: &signer) {
        randomized_history(framework, first, second, 31337);
    }
}
