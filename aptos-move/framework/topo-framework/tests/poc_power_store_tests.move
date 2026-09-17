#[test_only]
module topo_framework::poc_power_store_tests {
    use topo_framework::poc_accounting;
    use topo_framework::poc_power_store;

    const INDEX_SCALE: u128 = 18446744073709551616;
    const UNIT_SCALE: u128 = 4294967296;
    const MAX_U64: u64 = 18446744073709551615;

    /// 一次性初始化账本、算力表和时钟，提交计数从 0 起算。
    public fun initialize(framework: &signer, epoch: u64, retention: u64, length: u64, p_max: u64) {
        poc_accounting::prepare_for_test(framework, epoch, epoch + 1000, 4);
        poc_power_store::initialize_for_test(framework, epoch, retention, p_max, length, @topo_framework);
    }

    /// 模拟一次成功提交的顺序：先推进时钟，再同步账本 Epoch。
    public fun next_epoch() {
        let target = poc_accounting::current_epoch() + 1;
        poc_power_store::commit_period_for_test();
        poc_accounting::advance_for_test(target, vector[], false);
    }

    #[test]
    fun poc_normalization_rounding_and_maximum() {
        // 周期 0 的共同指数为 J；零值、最小非零值和 u64 上限均按精确整数保存。
        assert!(poc_power_store::normalize_units_for_test(0, INDEX_SCALE) == 0, 0);
        assert!(poc_power_store::normalize_units_for_test(1, INDEX_SCALE) == UNIT_SCALE, 1);
        assert!(poc_power_store::normalize_units_for_test(MAX_U64, INDEX_SCALE)
            == (MAX_U64 as u128) * UNIT_SCALE, 2);
        assert!(poc_power_store::normalize_units_for_test(100, INDEX_SCALE) == 100 * UNIT_SCALE, 3);
        let index = ((INDEX_SCALE as u256) * 9000 / 10000) as u128;
        assert!(index == 16602069666338596454, 4);
        let units = poc_power_store::normalize_units_for_test(100, index);
        assert!(units == 477218588444, 5);
        // 标准化和换算算力各取整一次，原始算力 100 得到整数权重 99；资格判断须使用 99。
        let pool_power = (units as u256) * (index as u256)
            / ((UNIT_SCALE as u256) * (INDEX_SCALE as u256));
        assert!(pool_power == 99, 6);

        // 2^40 是支持的最小指数；u64 上限恰得到 2^120-2^56，仍严格小于版本容量。
        let minimum_index = 1099511627776;
        assert!(poc_power_store::normalize_units_for_test(0, minimum_index) == 0, 7);
        assert!(poc_power_store::normalize_units_for_test(1, minimum_index) == 72057594037927936, 8);
        let maximum = poc_power_store::normalize_units_for_test(MAX_U64, minimum_index);
        assert!(maximum == 1329227995784915872831749466242416640, 9);
        assert!((maximum as u256) < 1329227995784915872903807060280344576, 10);
    }

    #[test]
    #[expected_failure(abort_code = 0x10008, location = topo_framework::poc_power_store)]
    fun poc_normalization_rejects_index_below_minimum() {
        poc_power_store::normalize_units_for_test(1, 1099511627775);
    }

    #[test]
    fun poc_index_horizon_exact_boundaries() {
        poc_power_store::validate_index_horizon(9900, 1655);
        poc_power_store::validate_index_horizon(9995, 10000);
        poc_power_store::validate_index_horizon(9995, 33262);
        poc_power_store::validate_index_horizon(10000, MAX_U64);

        // 主网部署的 P_MAX=10000；逐周期向下取整，不能用浮点幂或最终一次取整代替。
        let index = INDEX_SCALE;
        let period = 0;
        while (period < 10000) {
            index = (((index as u256) * 9995) / 10000) as u128;
            period += 1;
        };
        assert!(index == 124137862714582947, 0);
    }

    #[test]
    #[expected_failure(abort_code = 0x10004, location = topo_framework::poc_power_store)]
    fun poc_index_horizon_rejects_zero_retention() {
        poc_power_store::validate_index_horizon(0, 10000);
    }

    #[test]
    #[expected_failure(abort_code = 0x10004, location = topo_framework::poc_power_store)]
    fun poc_index_horizon_rejects_retention_above_one_hundred_percent() {
        poc_power_store::validate_index_horizon(10001, 10000);
    }

    #[test(framework = @topo_framework)]
    fun poc_default_horizon_clock(framework: signer) {
        initialize(&framework, 0, 9995, 60, 10000);
        let (baseline, period, boundary, index, next_index, p_max) =
            poc_power_store::get_normalization_clock();
        assert!(baseline == 0 && period == 0 && boundary == 61, 0);
        assert!(next_index.is_some(), 1);
        assert!(index == INDEX_SCALE && *next_index.borrow() == 18437520701672696840, 2);
        assert!(p_max == 10000 && poc_power_store::get_retention_bps_per_period() == 9995, 3);
    }

    #[test(framework = @topo_framework)]
    fun poc_full_retention_preserves_index(framework: signer) {
        initialize(&framework, 0, 10000, 60, 10000);
        let (_, _, _, index, next_index, p_max) = poc_power_store::get_normalization_clock();
        assert!(next_index.is_some(), 0);
        assert!(index == INDEX_SCALE && *next_index.borrow() == INDEX_SCALE, 1);
        assert!(p_max == 10000 && poc_power_store::get_retention_bps_per_period() == 10000, 2);
    }

    #[test]
    #[expected_failure(abort_code = 0x10008, location = topo_framework::poc_power_store)]
    fun poc_index_horizon_rejects_first_expired_period() {
        poc_power_store::validate_index_horizon(9900, 1656);
    }

    #[test(framework = @topo_framework)]
    fun poc_clock_genesis_sixty_epochs(framework: signer) {
        initialize(&framework, 0, 9995, 60, 100);
        // 创世恰好安装一次 Epoch 1，倒计时从 60 变为 59。
        next_epoch();
        assert!(poc_power_store::next_boundary_epoch() == 61, 1);
        while (poc_accounting::current_epoch() < 60) next_epoch();
        assert!(poc_power_store::get_current_period() == 0, 2);
        let (valid, period, _) = poc_power_store::preview_next_period();
        assert!(valid && period == 1, 3);
        next_epoch();
        assert!(poc_power_store::get_current_period() == 1, 4);
        assert!(poc_power_store::next_boundary_epoch() == 121, 5);
    }

    #[test(framework = @topo_framework)]
    #[expected_failure(abort_code = 0x30009, location = topo_framework::poc_power_store)]
    fun poc_clock_rejects_missing_epoch_commit(framework: signer) {
        initialize(&framework, 0, 9995, 60, 100);
        next_epoch();
        // 漏掉时钟提交、单独推进账本后，下一次读取必须检测出状态不一致。
        poc_accounting::advance_for_test(2, vector[], false);
        poc_power_store::get_normalization_clock();
    }

    #[test(framework = @topo_framework)]
    fun poc_clock_length_one_and_horizon_preview(framework: signer) {
        initialize(&framework, 0, 9995, 1, 1);
        next_epoch();
        assert!(poc_power_store::next_boundary_epoch() == 2, 1);
        next_epoch();
        assert!(poc_power_store::get_current_period() == 1, 2);
        let (valid, _, _) = poc_power_store::preview_next_period();
        assert!(!valid, 3);
        // 预览失败不能推进已安装 Epoch 或改变其边界。
        assert!(poc_accounting::current_epoch() == 2 && poc_power_store::next_boundary_epoch() == 3, 4);
    }

    #[test(framework = @topo_framework)]
    fun poc_period_length_maximum_preserves_boundary(framework: signer) {
        initialize(&framework, 0, 9995, 60, 100);
        next_epoch();
        // 下一算力周期仍从 Epoch 61 开始；新长度使再下一算力周期的开始边界恰为 u64 上限，应当允许。
        poc_power_store::set_power_period_in_epochs(&framework, MAX_U64 - 61);
        assert!(poc_power_store::next_boundary_epoch() == 61, 1);
        while (poc_accounting::current_epoch() < 60) next_epoch();
        let (valid, _, _) = poc_power_store::preview_next_period();
        assert!(valid, 2);
        next_epoch();
        assert!(poc_power_store::next_boundary_epoch() == MAX_U64, 3);
    }

    #[test(framework = @topo_framework)]
    #[expected_failure(abort_code = 0x10005, location = topo_framework::poc_power_store)]
    fun poc_period_length_rejects_boundary_overflow(framework: signer) {
        initialize(&framework, 0, 9995, 60, 100);
        next_epoch();
        poc_power_store::set_power_period_in_epochs(&framework, MAX_U64 - 60);
    }

    #[test(framework = @topo_framework)]
    #[expected_failure(abort_code = 0x8000b, location = topo_framework::poc_power_store)]
    fun poc_initialization_cannot_reset_retention_or_versions(framework: signer) {
        initialize(&framework, 0, 9995, 60, 100);
        poc_power_store::set_genesis_committed_power(&framework, @0x123, 100);
        next_epoch();
        poc_power_store::initialize_for_test(&framework, 1, 10000, 200, 1, @0x123);
    }

    #[test(framework = @topo_framework)]
    #[expected_failure(abort_code = 0x30008, location = topo_framework::poc_power_store)]
    fun poc_upload_rejects_unsupported_version(framework: signer) {
        // P_MAX=0 仅支持创世周期；下一周期没有合法指数，上传必须在写版本前精确拒绝。
        initialize(&framework, 0, 9995, 1, 0);
        poc_power_store::stage_batch_update(&framework, 1, vector[@0x123], vector[100]);
    }

    #[test(framework = @topo_framework)]
    fun poc_snapshot_is_read_only(framework: signer) {
        assert!(!poc_power_store::is_initialized(), 4);
        initialize(&framework, 0, 9995, 60, 100);
        assert!(poc_power_store::is_initialized(), 5);
        let (current, next, period, boundary) = poc_power_store::get_accounting_snapshot(@0x123);
        assert!(current == 0 && next == 0 && period == 0 && boundary == 61, 1);
        assert!(!poc_power_store::is_user_normalized(@0x123), 2);
        let (current2, next2, period2, boundary2) = poc_power_store::get_accounting_snapshot(@0x123);
        assert!(current2 == current && next2 == next && period2 == period && boundary2 == boundary, 3);
    }

    #[test]
    #[expected_failure(abort_code = 0x60001, location = topo_framework::poc_power_store)]
    fun poc_snapshot_requires_initialized_store() {
        assert!(!poc_power_store::is_initialized(), 1);
        poc_power_store::get_accounting_snapshot(@0x123);
    }

    #[test(framework = @topo_framework)]
    #[expected_failure(abort_code = 0x60001, location = topo_framework::poc_power_store)]
    fun poc_upload_requires_initialized_store(framework: signer) {
        poc_power_store::stage_batch_update(&framework, 1, vector[@0x123], vector[100]);
    }

    #[test(framework = @topo_framework)]
    #[expected_failure(abort_code = 0x10005, location = topo_framework::poc_power_store)]
    fun poc_initialization_rejects_boundary_overflow(framework: signer) {
        initialize(&framework, 0, 10000, MAX_U64 / 2 + 1, 100);
    }
}
