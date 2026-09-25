/// 保存 PoC 通胀和可分发交易费的原生奖励占比及当期快照。
/// 配置在 PoC 准备时创建，仅允许 stake 排期和安装更新。
module topo_framework::poc_reward_split {
    use std::error;
    use std::features;
    use std::option::{Self, Option};
    use topo_framework::event;
    use topo_framework::poc_accounting;
    use topo_framework::reconfiguration_state;
    use topo_framework::system_addresses;

    friend topo_framework::stake;

    const BPS_DENOMINATOR: u64 = 10000;
    const DEFAULT_NATIVE_REWARD_BPS: u64 = 5000;
    const EINVALID_NATIVE_REWARD_BPS: u64 = 1;
    const EINVALID_EPOCH: u64 = 2;
    const ERECONFIGURATION_IN_PROGRESS: u64 = 3;
    const ENO_PENDING_REWARD_SPLIT: u64 = 4;

    struct PendingRewardSplit has copy, drop, store {
        native_reward_bps: u64,
        activation_epoch: u64,
    }

    struct RewardSplitConfig has key {
        installed_epoch: u64,
        configured_native_reward_bps: u64,
        installed_native_reward_bps: u64,
        pending_change: Option<PendingRewardSplit>,
    }

    #[event]
    struct RewardSplitScheduled has drop, store {
        native_reward_bps: u64,
        activation_epoch: u64,
    }

    #[event]
    struct RewardSplitCancelled has drop, store {
        native_reward_bps: u64,
        activation_epoch: u64,
    }

    #[event]
    struct RewardSplitInstalled has drop, store {
        epoch: u64,
        poc_enabled: bool,
        native_reward_bps: u64,
    }

    public fun default_native_reward_bps(): u64 { DEFAULT_NATIVE_REWARD_BPS }

    /// 通胀和可分发交易费分别调用同一分流公式；每笔原生部分向下取整，余额归 PoC。
    public fun split_reward(amount_octa: u64, native_reward_bps: u64): (u64, u64) {
        assert!(native_reward_bps <= BPS_DENOMINATOR, error::invalid_argument(EINVALID_NATIVE_REWARD_BPS));
        // u64 金额乘不超过 10000 的比例，乘积小于 2^78，u128 足够且不改变取整。
        let native_octa = ((amount_octa as u128) * (native_reward_bps as u128)
            / (BPS_DENOMINATOR as u128)) as u64;
        (native_octa, amount_octa - native_octa)
    }

    fun assert_not_frozen() {
        assert!(!reconfiguration_state::is_in_progress() && !features::is_reconfiguration_frozen(),
            error::invalid_state(ERECONFIGURATION_IN_PROGRESS));
    }

    /// 准备 PoC 时默认将原生奖励占比设为 50%；当前原生 Epoch 继续沿用原生质押路径。
    public(friend) fun initialize(framework: &signer, installed_epoch: u64) {
        system_addresses::assert_topo_framework(framework);
        assert_not_frozen();
        move_to(framework, RewardSplitConfig {
            installed_epoch, configured_native_reward_bps: DEFAULT_NATIVE_REWARD_BPS,
            installed_native_reward_bps: 0, pending_change: option::none(),
        });
    }

    /// 将原生奖励占比安排在未来 Epoch 生效。
    public(friend) fun schedule_change(framework: &signer, native_reward_bps: u64, activation_epoch: u64)
    acquires RewardSplitConfig {
        system_addresses::assert_topo_framework(framework);
        assert_not_frozen();
        assert!(native_reward_bps <= BPS_DENOMINATOR, error::invalid_argument(EINVALID_NATIVE_REWARD_BPS));
        let current_epoch = poc_accounting::current_epoch();
        assert!(activation_epoch > current_epoch, error::invalid_argument(EINVALID_EPOCH));
        let config = borrow_global_mut<RewardSplitConfig>(@topo_framework);
        assert!(config.installed_epoch == current_epoch, error::invalid_state(EINVALID_EPOCH));
        config.pending_change = option::some(PendingRewardSplit { native_reward_bps, activation_epoch });
        event::emit(RewardSplitScheduled { native_reward_bps, activation_epoch });
    }

    public(friend) fun cancel_pending_change(framework: &signer) acquires RewardSplitConfig {
        system_addresses::assert_topo_framework(framework);
        assert_not_frozen();
        let config = borrow_global_mut<RewardSplitConfig>(@topo_framework);
        assert!(config.installed_epoch == poc_accounting::current_epoch(), error::invalid_state(EINVALID_EPOCH));
        assert!(config.pending_change.is_some(), error::invalid_state(ENO_PENDING_REWARD_SPLIT));
        let PendingRewardSplit { native_reward_bps, activation_epoch } = config.pending_change.extract();
        event::emit(RewardSplitCancelled { native_reward_bps, activation_epoch });
    }

    /// 核对传入的 Epoch 与当期快照一致，确保 DKG 完成时使用 closing_rewards 对应的原生奖励占比。
    public fun get_installed_native_reward_bps(installed_epoch: u64): u64 acquires RewardSplitConfig {
        let config = borrow_global<RewardSplitConfig>(@topo_framework);
        assert!(config.installed_epoch == installed_epoch, error::invalid_state(EINVALID_EPOCH));
        config.installed_native_reward_bps
    }

    /// 查询目标 Epoch 将使用的原生奖励占比，供预检预留奖励容量；查询不使配置生效。
    public fun get_target_native_reward_bps(target_epoch: u64): u64 acquires RewardSplitConfig {
        let config = borrow_global<RewardSplitConfig>(@topo_framework);
        assert!(target_epoch > config.installed_epoch, error::invalid_state(EINVALID_EPOCH));
        if (config.pending_change.is_some() && config.pending_change.borrow().activation_epoch <= target_epoch) {
            config.pending_change.borrow().native_reward_bps
        } else { config.configured_native_reward_bps }
    }

    /// 原生模式下 installed_native_reward_bps = 0 表示未启用 PoC 奖励分成；奖励仍全部按原生质押路径分发。
    public fun get_configuration(installed_epoch: u64): (u64, u64, u64, Option<u64>, Option<u64>) acquires RewardSplitConfig {
        let config = borrow_global<RewardSplitConfig>(@topo_framework);
        assert!(config.installed_epoch == installed_epoch, error::invalid_state(EINVALID_EPOCH));
        let (pending_native_reward_bps, pending_activation_epoch) = if (config.pending_change.is_some()) {
            let pending_change = config.pending_change.borrow();
            (option::some(pending_change.native_reward_bps), option::some(pending_change.activation_epoch))
        } else { (option::none(), option::none()) };
        (installed_epoch, config.installed_native_reward_bps, config.configured_native_reward_bps,
            pending_native_reward_bps, pending_activation_epoch)
    }

    /// 在提交新 Epoch 时与 stake 的 RewardContext 一起安装；查询或时间流逝不会使配置提前生效。
    public(friend) fun install_epoch(target_epoch: u64, poc_enabled: bool) acquires RewardSplitConfig {
        let config = borrow_global_mut<RewardSplitConfig>(@topo_framework);
        assert!((target_epoch as u128) == (config.installed_epoch as u128) + 1, error::invalid_state(EINVALID_EPOCH));
        if (config.pending_change.is_some() && config.pending_change.borrow().activation_epoch <= target_epoch) {
            config.configured_native_reward_bps = config.pending_change.extract().native_reward_bps;
        };
        config.installed_epoch = target_epoch;
        config.installed_native_reward_bps = if (poc_enabled) { config.configured_native_reward_bps } else { 0 };
        event::emit(RewardSplitInstalled { epoch: target_epoch, poc_enabled,
            native_reward_bps: config.installed_native_reward_bps });
    }

    spec split_reward {
        aborts_if native_reward_bps > BPS_DENOMINATOR;
        ensures result_1 == amount_octa * native_reward_bps / BPS_DENOMINATOR;
        ensures result_1 + result_2 == amount_octa;
    }

    // 显式声明配置资源的写入范围，供 stake 的准备、治理和 Epoch 安装规格引用。
    spec initialize {
        modifies global<RewardSplitConfig>(@topo_framework);
    }

    spec schedule_change {
        modifies global<RewardSplitConfig>(@topo_framework);
    }

    spec cancel_pending_change {
        modifies global<RewardSplitConfig>(@topo_framework);
    }

    spec install_epoch {
        modifies global<RewardSplitConfig>(@topo_framework);
    }

    #[test]
    fun split_reward_boundaries_and_rounding() {
        let (native_inflation_octa, poc_inflation_octa) = split_reward(17, 0);
        assert!(native_inflation_octa == 0 && poc_inflation_octa == 17, 1);
        let (native_inflation_octa, poc_inflation_octa) = split_reward(17, 10000);
        assert!(native_inflation_octa == 17 && poc_inflation_octa == 0, 2);
        let (native_inflation_octa, poc_inflation_octa) = split_reward(17, 3000);
        assert!(native_inflation_octa == 5 && poc_inflation_octa == 12, 3);
        let (native_inflation_octa, poc_inflation_octa) = split_reward(17, default_native_reward_bps());
        assert!(native_inflation_octa == 8 && poc_inflation_octa == 9, 6);
        let (native_inflation_octa, poc_inflation_octa) = split_reward(1, 9999);
        assert!(native_inflation_octa == 0 && poc_inflation_octa == 1, 4);
        let (native_inflation_octa, poc_inflation_octa) = split_reward(18446744073709551615, 10000);
        assert!(native_inflation_octa == 18446744073709551615 && poc_inflation_octa == 0, 5);
        let (native_inflation_octa, poc_inflation_octa) = split_reward(18446744073709551615, 5000);
        assert!(native_inflation_octa == 9223372036854775807
            && poc_inflation_octa == 9223372036854775808, 7);
    }

    #[test]
    #[expected_failure(abort_code = 0x10001, location = Self)]
    fun invalid_native_reward_bps_rejected() { split_reward(10, 10001); }

    #[test(framework = @0x1)]
    fun maximum_epoch_can_be_installed(framework: signer) acquires RewardSplitConfig {
        let maximum = 18446744073709551615;
        initialize(&framework, maximum - 1);
        install_epoch(maximum, true);
        assert!(get_installed_native_reward_bps(maximum) == default_native_reward_bps(), 1);
    }

    #[test(framework = @0x1)]
    #[expected_failure(abort_code = 0x30002, location = Self)]
    fun maximum_epoch_cannot_wrap_to_zero(framework: signer) acquires RewardSplitConfig {
        initialize(&framework, 18446744073709551615);
        install_epoch(0, true);
    }

    #[test(framework = @0x1)]
    #[expected_failure(abort_code = 0x30002, location = Self)]
    fun mismatched_installed_epoch_rejected(framework: signer) acquires RewardSplitConfig {
        initialize(&framework, 1);
        get_installed_native_reward_bps(2);
    }

    #[test(framework = @0x1)]
    #[expected_failure(abort_code = 0x10002, location = Self)]
    fun current_epoch_schedule_rejected(framework: signer) acquires RewardSplitConfig {
        poc_accounting::prepare_for_test(&framework, 1, 2, 4);
        initialize(&framework, 1);
        schedule_change(&framework, 6000, 1);
    }
}
