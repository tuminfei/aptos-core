#[test_only]
module topo_framework::poc_power_version_tests {
    use topo_framework::poc_accounting;
    use topo_framework::poc_allocation;
    use topo_framework::poc_power_store;
    use topo_framework::poc_power_store_tests;

    const UNIT_SCALE: u128 = 65536;
    const INDEX_SCALE: u128 = 18446744073709551616;

    #[test(framework = @topo_framework, user = @0x123)]
    fun poc_minimum_power_one_basis_point_rounds_down(framework: signer, user: signer) {
        poc_power_store_tests::initialize(&framework, 0, 10000, 60);
        poc_power_store::set_genesis_committed_power(&framework, @0x123, 1);
        poc_accounting::enable_pool_for_test(&framework, @0xa);
        poc_power_store_tests::next_epoch();
        poc_allocation::set_allocations(&user, vector[@0xa], vector[1]);
        // 2^16 精度下，最小整数 power 的 1 bps 份额从 6.5536 units 向下取整为 6。
        assert!(poc_accounting::preview_pool_units(@0xa, 2) == 6, 0);
        poc_power_store_tests::next_epoch();
        let (units, _, amount, remainder) = poc_accounting::get_position(@0x123, @0xa);
        assert!(units == 6 && amount == 0 && remainder == 0, 1);
    }

    /// 初始化完整存储，再直接写入周期 0 的算力 100 和周期 1 的 200。
    fun seed(framework: &signer, retention: u64) {
        poc_power_store_tests::initialize(framework, 0, retention, 1);
        poc_power_store::set_genesis_committed_power(framework, @0x123, 100);
        poc_power_store::stage_batch_update(framework, 1, vector[@0x123], vector[200]);
        poc_power_store_tests::next_epoch();
    }

    #[test(framework = @topo_framework)]
    fun poc_versions_remain_readable_after_several_periods(framework: signer) {
        seed(&framework, 10000);
        poc_power_store_tests::next_epoch();
        poc_power_store_tests::next_epoch();
        poc_power_store_tests::next_epoch();
        assert!(poc_power_store::get_current_period() == 3, 1);
        // 多个周期无人访问后，直接读取已经写入的有效版本，不重新计算 units。
        let (units, next_units, period, boundary) = poc_power_store::get_accounting_snapshot(@0x123);
        assert!(units == 200 * UNIT_SCALE && next_units == units, 2);
        let (units2, next_units2, period2, boundary2) = poc_power_store::get_accounting_snapshot(@0x123);
        assert!(units2 == units && next_units2 == next_units && period2 == period && boundary2 == boundary, 3);
    }

    #[test(framework = @topo_framework)]
    fun poc_units_keep_their_effective_period_index(framework: signer) {
        seed(&framework, 9000);
        poc_power_store_tests::next_epoch();
        poc_power_store_tests::next_epoch();
        poc_power_store_tests::next_epoch();
        let (units, next_units, _, _) = poc_power_store::get_accounting_snapshot(@0x123);
        // 周期 1 上报时绑定的 I[1] 不会被首次访问时的共同指数替代。
        let original_index = ((INDEX_SCALE as u256) * 9000 / 10000) as u128;
        assert!(units == poc_power_store::normalize_units_for_test(200, original_index), 1);
        assert!(next_units == units, 2);
    }

    #[test(framework = @topo_framework)]
    fun poc_version_rollover_preserves_current_units(framework: signer) {
        seed(&framework, 9000);
        poc_power_store_tests::next_epoch();
        // 写入周期 2 版本时淘汰周期 0，仍保留周期 1 的当前有效 units。
        poc_power_store::stage_batch_update(&framework, 2, vector[@0x123], vector[300]);
        assert!(poc_power_store::is_user_normalized(@0x123), 1);
        let (current, next, period, _) = poc_power_store::get_accounting_snapshot(@0x123);
        let i1 = ((INDEX_SCALE as u256) * 9000 / 10000) as u128;
        let i2 = ((i1 as u256) * 9000 / 10000) as u128;
        assert!(period == 1 && current == poc_power_store::normalize_units_for_test(200, i1), 2);
        assert!(next == poc_power_store::normalize_units_for_test(300, i2), 3);
    }

    #[test(framework = @topo_framework)]
    fun poc_batch_first_write_and_explicit_zero_version(framework: signer) {
        seed(&framework, 10000);
        poc_power_store_tests::next_epoch();
        // 同批重复上报同一用户时保留首次写入的零值；已有用户的零版本有效，新用户零值不建记录。
        poc_power_store::stage_batch_update(&framework, 2,
            vector[@0x123, @0x123, @0x456], vector[0, 999, 0]);
        let (current, next, _, _) = poc_power_store::get_accounting_snapshot(@0x123);
        assert!(current == 200 * UNIT_SCALE && next == 0, 1);
        assert!(!poc_power_store::is_user_normalized(@0x456), 2);
        poc_power_store_tests::next_epoch();
        let (current, next, _, _) = poc_power_store::get_accounting_snapshot(@0x123);
        assert!(current == 0 && next == 0, 3);
    }

    #[test(framework = @topo_framework, alice = @0x123, bob = @0x456)]
    fun poc_upload_allocation_order_independence(framework: signer, alice: signer, bob: signer) {
        poc_power_store_tests::initialize(&framework, 0, 10000, 60);
        poc_power_store::set_genesis_committed_power(&framework, @0x123, 100);
        poc_power_store::set_genesis_committed_power(&framework, @0x456, 100);
        poc_power_store_tests::next_epoch();
        poc_accounting::enable_pool_for_test(&framework, @0xa);
        poc_accounting::enable_pool_for_test(&framework, @0xb);
        poc_allocation::set_allocations(&alice, vector[@0xa], vector[5000]);
        poc_allocation::set_allocations(&bob, vector[@0xb], vector[5000]);
        poc_power_store_tests::next_epoch();

        // 交换上传与修改分配比例的顺序，比较当前持仓及 E+1、B 两个生效时点的结果。
        poc_power_store::stage_batch_update(&framework, 1, vector[@0x123], vector[200]);
        poc_allocation::set_allocations(&alice, vector[@0xa], vector[2500]);
        poc_allocation::set_allocations(&bob, vector[@0xb], vector[2500]);
        poc_power_store::stage_batch_update(&framework, 1, vector[@0x456], vector[200]);

        let (a_units, a_changes, a_claim, a_fraction) = poc_accounting::get_position(@0x123, @0xa);
        let (b_units, b_changes, b_claim, b_fraction) = poc_accounting::get_position(@0x456, @0xb);
        assert!(a_units == b_units && a_units == 50 * UNIT_SCALE, 1);
        assert!(a_changes == b_changes && a_changes.length() == 2, 2);
        assert!(a_claim == b_claim && a_fraction == b_fraction, 3);
        let (epoch, units) = poc_accounting::position_change_fields(a_changes.borrow(0));
        assert!(epoch == 3 && units == 25 * UNIT_SCALE, 4);
        let (epoch, units) = poc_accounting::position_change_fields(a_changes.borrow(1));
        assert!(epoch == 61 && units == 50 * UNIT_SCALE, 5);
        let (a_current, a_next, a_base, a_vault, a_index) = poc_accounting::get_pool(@0xa);
        let (b_current, b_next, b_base, b_vault, b_index) = poc_accounting::get_pool(@0xb);
        assert!(a_current == b_current && a_next == b_next && a_base == b_base
            && a_vault == b_vault && a_index == b_index, 6);
    }

    #[test(framework = @topo_framework, user = @0x123)]
    fun poc_same_boundary_cancels_zero_change(framework: signer, user: signer) {
        poc_power_store_tests::initialize(&framework, 0, 10000, 2);
        poc_power_store::set_genesis_committed_power(&framework, @0x123, 100);
        poc_power_store_tests::next_epoch();
        poc_accounting::enable_pool_for_test(&framework, @0xa);
        poc_allocation::set_allocations(&user, vector[@0xa], vector[5000]);
        poc_power_store_tests::next_epoch();
        // E+1 与 B 重合，新版本按新比例分配后 units 不变，不应创建持仓变更或检查点引用。
        assert!(poc_power_store::next_boundary_epoch() == 3, 1);
        poc_power_store::stage_batch_update(&framework, 1, vector[@0x123], vector[200]);
        poc_allocation::set_allocations(&user, vector[@0xa], vector[2500]);
        let (units, changes, _, _) = poc_accounting::get_position(@0x123, @0xa);
        assert!(units == 50 * UNIT_SCALE && changes.is_empty(), 2);
        assert!(poc_accounting::pool_changes_for_test(@0xa).is_empty(), 3);
    }

    #[test(framework = @topo_framework, user = @0x123)]
    fun poc_allocation_before_first_upload(framework: signer, user: signer) {
        poc_power_store_tests::initialize(&framework, 0, 10000, 1);
        poc_accounting::enable_pool_for_test(&framework, @0xa);
        poc_allocation::set_allocations(&user, vector[@0xa], vector[10000]);
        assert!(!poc_power_store::is_user_normalized(@0x123), 1);
        poc_power_store::stage_batch_update(&framework, 1, vector[@0x123], vector[100]);
        let (current, next, _, _) = poc_power_store::get_accounting_snapshot(@0x123);
        assert!(current == 0 && next == 100 * UNIT_SCALE, 2);
        poc_power_store_tests::next_epoch();
        let (units, _, _, _) = poc_accounting::get_position(@0x123, @0xa);
        assert!(units == 0, 3);
        poc_power_store_tests::next_epoch();
        let (units, changes, _, _) = poc_accounting::get_position(@0x123, @0xa);
        assert!(units == 100 * UNIT_SCALE && changes.is_empty(), 4);
    }

    #[test(framework = @topo_framework, user = @0x123)]
    fun poc_genesis_write_syncs_allocations_and_preserves_future(framework: signer, user: signer) {
        poc_power_store_tests::initialize(&framework, 0, 10000, 1);
        poc_power_store::set_genesis_committed_power(&framework, @0x123, 0);
        assert!(!poc_power_store::is_user_normalized(@0x123), 1);
        poc_accounting::enable_pool_for_test(&framework, @0xa);
        poc_allocation::set_allocations(&user, vector[@0xa], vector[10000]);
        poc_power_store::set_genesis_committed_power(&framework, @0x123, 100);
        let (current, next, _, _) = poc_power_store::get_accounting_snapshot(@0x123);
        assert!(current == 100 * UNIT_SCALE && next == current, 2);
        poc_power_store::stage_batch_update(&framework, 1, vector[@0x123], vector[200]);
        poc_power_store::set_genesis_committed_power(&framework, @0x123, 50);
        let (current, next, _, _) = poc_power_store::get_accounting_snapshot(@0x123);
        assert!(current == 50 * UNIT_SCALE && next == 200 * UNIT_SCALE, 3);
        assert!(poc_power_store::get_user_committed_power(@0x123) == 50, 4);
        poc_power_store_tests::next_epoch();
        let (units, _, _, _) = poc_accounting::get_position(@0x123, @0xa);
        assert!(units == 50 * UNIT_SCALE, 5);
        poc_power_store_tests::next_epoch();
        let (units, changes, _, _) = poc_accounting::get_position(@0x123, @0xa);
        assert!(units == 200 * UNIT_SCALE && changes.is_empty(), 6);
    }

    #[test(framework = @topo_framework)]
    fun poc_raw_queries_and_units_share_version_window(framework: signer) {
        seed(&framework, 9000);
        let (older_period, older_power, newer_period, newer_power, current_power) =
            poc_power_store::get_user_power_version(@0x123);
        assert!(older_period == 0 && older_power == 100
            && newer_period == 1 && newer_power == 200 && current_power == 100, 1);
        poc_power_store_tests::next_epoch();
        poc_power_store::stage_batch_update(&framework, 2, vector[@0x123], vector[0]);
        let (older_period, older_power, newer_period, newer_power, current_power) =
            poc_power_store::get_user_power_version(@0x123);
        assert!(older_period == 1 && older_power == 200
            && newer_period == 2 && newer_power == 0 && current_power == 200, 2);
        let (current, next, _, _) = poc_power_store::get_accounting_snapshot(@0x123);
        assert!(current > 0 && next == 0, 3);
        assert!(poc_power_store::get_user_power_for_period(@0x123, 0) == 0, 4);
        poc_power_store_tests::next_epoch();
        let (current, next, _, _) = poc_power_store::get_accounting_snapshot(@0x123);
        assert!(current == 0 && next == 0 && poc_power_store::get_user_committed_power(@0x123) == 0, 5);
        poc_power_store::stage_batch_update(&framework, 3, vector[@0x123], vector[300]);
        let (current, next, _, _) = poc_power_store::get_accounting_snapshot(@0x123);
        assert!(current == 0 && next > 0, 6);
        assert!(poc_power_store::get_user_committed_power(@0x123) == 0
            && poc_power_store::get_user_power_for_period(@0x123, 3) == 300, 7);
    }

    #[test(framework = @topo_framework)]
    fun poc_shared_version_preserves_raw_integer_decay(framework: signer) {
        poc_power_store_tests::initialize(&framework, 0, 9000, 1);
        poc_power_store::set_genesis_committed_power(&framework, @0x123, 100);
        poc_power_store_tests::next_epoch();
        poc_power_store_tests::next_epoch();
        let (units, next_units, period, _) = poc_power_store::get_accounting_snapshot(@0x123);
        let (_, _, index, _) = poc_power_store::get_normalization_clock();
        assert!(period == 1 && units == 100 * UNIT_SCALE && next_units == units, 1);
        // 同一版本的原始查询逐周期整数衰减；池算力仍使用共同指数，保留各自的取整规则。
        assert!(poc_power_store::get_user_committed_power(@0x123) == 90, 2);
        assert!(poc_accounting::pool_power(units, index) == 89, 3);
        poc_power_store_tests::next_epoch();
        assert!(poc_power_store::get_user_committed_power(@0x123) == 81, 4);
        poc_power_store_tests::next_epoch();
        assert!(poc_power_store::get_user_committed_power(@0x123) == 72, 5);
        let (current, next, _, _) = poc_power_store::get_accounting_snapshot(@0x123);
        assert!(current == units && next == units, 6);
    }
}
