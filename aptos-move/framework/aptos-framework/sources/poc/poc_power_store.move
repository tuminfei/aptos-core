/// POC 算力存储合约 —— 每个用户保留最近两个版本，按目标 period 选择可生效版本。
///
/// 设计边界：
/// - 链下服务负责计算最终算力结果
/// - 链上只保存每个用户最近两个版本，不再维护全局 pending cache
/// - 当前 power period 内，读取始终选择 `effective_period <= current_period` 的最新版本
/// - 周期中途上传只会写入 `effective_period = current_period + 1` 的未来版本，不会影响当期 stake / governance / reward 读取
/// - 历史未更新用户不需要在 epoch 边界全量重写；读取时按版本和 retention 惰性衰减
module aptos_framework::poc_power_store {
    use std::error;
    use std::signer;

    use aptos_std::table;
    use aptos_std::table::Table;

    use aptos_framework::event;
    use aptos_framework::system_addresses;

    friend aptos_framework::genesis;
    friend aptos_framework::stake;
    friend aptos_framework::staking_registry;

    const POWER_DECIMALS: u64 = 18;
    const BPS_DENOMINATOR: u64 = 10000;
    const DEFAULT_RETENTION_BPS_PER_PERIOD: u64 = 9950;
    const DEFAULT_POWER_PERIOD_IN_EPOCHS: u64 = 1;

    // ========== 错误码 ==========

    /// 算力存储尚未初始化
    const ESTORE_NOT_INITIALIZED: u64 = 1;
    /// 调用者不是唯一 operator
    const ENOT_OPERATOR: u64 = 2;
    /// `users` 与 `powers` 长度不一致
    const EINVALID_BATCH_LENGTH: u64 = 3;
    /// retention_bps_per_period 非法
    const EINVALID_RETENTION_BPS: u64 = 4;
    /// power_period_in_epochs 非法
    const EINVALID_POWER_PERIOD: u64 = 5;
    /// target_period 必须等于 current_period + 1
    const EINVALID_TARGET_PERIOD: u64 = 6;
    /// genesis committed snapshot 只允许在初始化阶段写入
    const EGENESIS_COMMIT_ONLY: u64 = 7;

    // ========== 核心资源 ==========

    /// 全局算力存储，挂在 @aptos_framework 地址下。
    struct PowerStore has key {
        /// 唯一写入者
        operator: address,
        /// 一个 power period 包含多少个链上 epoch
        power_period_in_epochs: u64,
        /// 本地记录的已进入链 epoch 数
        last_epoch: u64,
        /// 当前已进入的 power period
        current_period: u64,
        /// 用户 -> 最近两个算力版本
        users: Table<address, UserPowerInfo>,
        /// 用户索引，仅用于遍历测试和未来迁移
        user_list: vector<address>,
        /// 每个 power period 的保留比例（bps）
        retention_bps_per_period: u64,
    }

    struct PowerVersion has copy, drop, store {
        effective_period: u64,
        power: u64,
    }

    /// 用户最近两个可生效版本。
    /// `newer` 总是较新的槽位；`older` 用于保留上一个版本，保证当前 period 与下一 period 可以同时被正确读取。
    struct UserPowerInfo has copy, drop, store {
        older: PowerVersion,
        newer: PowerVersion,
    }

    // ========== 事件 ==========

    #[event]
    struct OperatorChangedEvent has drop, store {
        old_operator: address,
        new_operator: address,
    }

    #[event]
    struct PowerUpdateStagedEvent has drop, store {
        target_period: u64,
        effective_period: u64,
        user: address,
        power: u64,
    }

    #[event]
    struct PowerPeriodCommittedEvent has drop, store {
        previous_period: u64,
        current_period: u64,
    }

    // ========== 初始化 ==========

    public(friend) fun initialize(aptos_framework: &signer, operator: address) {
        initialize_power_store_internal(
            aptos_framework,
            operator,
            DEFAULT_RETENTION_BPS_PER_PERIOD,
            DEFAULT_POWER_PERIOD_IN_EPOCHS,
        );
    }

    public(friend) fun initialize_with_power_period(
        aptos_framework: &signer,
        operator: address,
        power_period_in_epochs: u64,
    ) {
        initialize_power_store_internal(
            aptos_framework,
            operator,
            DEFAULT_RETENTION_BPS_PER_PERIOD,
            power_period_in_epochs,
        );
    }

    public entry fun initialize_power_store(
        aptos_framework: &signer,
        operator: address,
    ) {
        initialize_power_store_internal(
            aptos_framework,
            operator,
            DEFAULT_RETENTION_BPS_PER_PERIOD,
            DEFAULT_POWER_PERIOD_IN_EPOCHS,
        );
    }

    public entry fun initialize_power_store_with_period(
        aptos_framework: &signer,
        operator: address,
        power_period_in_epochs: u64,
    ) {
        initialize_power_store_internal(
            aptos_framework,
            operator,
            DEFAULT_RETENTION_BPS_PER_PERIOD,
            power_period_in_epochs,
        );
    }

    public entry fun set_retention_bps_per_period(
        aptos_framework: &signer,
        retention_bps_per_period: u64,
    ) acquires PowerStore {
        system_addresses::assert_aptos_framework(aptos_framework);
        assert_store_exists();
        assert_valid_retention_bps(retention_bps_per_period);
        borrow_global_mut<PowerStore>(@aptos_framework).retention_bps_per_period =
            retention_bps_per_period;
    }

    public entry fun set_operator(
        aptos_framework: &signer,
        new_operator: address,
    ) acquires PowerStore {
        system_addresses::assert_aptos_framework(aptos_framework);
        assert_store_exists();

        let store = borrow_global_mut<PowerStore>(@aptos_framework);
        let old_operator = store.operator;
        if (old_operator == new_operator) {
            return
        };

        store.operator = new_operator;
        event::emit(OperatorChangedEvent {
            old_operator,
            new_operator,
        });
    }

    // ========== 写回 ==========

    /// 批量写入下一 power period 的用户算力版本。
    ///
    /// 约定：
    /// - 当链上当前 period = P 时，链下上传的是 period P-1 的计算结果
    /// - 但该结果只能从 P+1 开始生效，因此这里写入 `effective_period = current_period + 1`
    public entry fun stage_batch_update(
        operator: &signer,
        target_period: u64,
        users: vector<address>,
        powers: vector<u64>,
    ) acquires PowerStore {
        assert_store_exists();
        assert!(
            users.length() == powers.length(),
            error::invalid_argument(EINVALID_BATCH_LENGTH),
        );

        let store = borrow_global_mut<PowerStore>(@aptos_framework);
        assert_operator(store, signer::address_of(operator));
        assert!(
            target_period == store.current_period + 1,
            error::invalid_argument(EINVALID_TARGET_PERIOD),
        );

        let effective_period = target_period;
        let length = users.length();
        let i = 0;
        while (i < length) {
            let user = *users.borrow(i);
            let power = *powers.borrow(i);
            upsert_power_version(store, user, effective_period, power);
            event::emit(PowerUpdateStagedEvent {
                target_period,
                effective_period,
                user,
                power,
            });
            i += 1;
        };
    }

    /// genesis / 测试特例：直接写入当前 period 0 committed snapshot。
    public entry fun set_genesis_committed_power(
        aptos_framework: &signer,
        user: address,
        power: u64,
    ) acquires PowerStore {
        system_addresses::assert_aptos_framework(aptos_framework);
        assert_store_exists();

        let store = borrow_global_mut<PowerStore>(@aptos_framework);
        assert!(
            store.last_epoch == 0 && store.current_period == 0,
            error::invalid_state(EGENESIS_COMMIT_ONLY),
        );
        upsert_power_version(store, user, 0, power);
    }

    /// 在进入下一个 epoch 时推进本地 epoch 计数；若该 epoch 是新 power period 的起始，则只推进当前 period。
    public(friend) fun commit_next_period_if_boundary() acquires PowerStore {
        if (!exists<PowerStore>(@aptos_framework)) {
            return
        };

        let store = borrow_global_mut<PowerStore>(@aptos_framework);
        store.last_epoch += 1;
        let next_epoch = store.last_epoch;
        let target_period = period_for_epoch(next_epoch, store.power_period_in_epochs);
        if (target_period <= store.current_period) {
            return
        };

        let previous_period = store.current_period;
        store.current_period = target_period;
        event::emit(PowerPeriodCommittedEvent {
            previous_period,
            current_period: target_period,
        });
    }

    // ========== 查询接口 ==========

    #[view]
    public fun get_power_deciamls(): u64 {
        POWER_DECIMALS
    }

    #[view]
    public fun get_user_power(user: address): u64 acquires PowerStore {
        get_user_committed_power(user)
    }

    #[view]
    public fun get_user_committed_power(user: address): u64 acquires PowerStore {
        if (!exists<PowerStore>(@aptos_framework)) {
            return 0
        };
        let store = borrow_global<PowerStore>(@aptos_framework);
        get_user_power_for_period_internal(store, user, store.current_period)
    }

    public(friend) fun get_user_committed_power_for_next_epoch(
        user: address,
    ): u64 acquires PowerStore {
        if (!exists<PowerStore>(@aptos_framework)) {
            return 0
        };

        let store = borrow_global<PowerStore>(@aptos_framework);
        let target_period =
            period_for_epoch(store.last_epoch + 1, store.power_period_in_epochs);
        get_user_power_for_period_internal(store, user, target_period)
    }

    #[view]
    public fun get_user_power_for_period(
        user: address,
        target_period: u64,
    ): u64 acquires PowerStore {
        if (!exists<PowerStore>(@aptos_framework)) {
            return 0
        };
        let store = borrow_global<PowerStore>(@aptos_framework);
        get_user_power_for_period_internal(store, user, target_period)
    }

    #[view]
    public fun get_user_power_info(user: address): UserPowerInfo acquires PowerStore {
        if (!exists<PowerStore>(@aptos_framework)) {
            return empty_user_power_info()
        };
        let store = borrow_global<PowerStore>(@aptos_framework);
        if (!store.users.contains(user)) {
            return empty_user_power_info()
        };
        *store.users.borrow(user)
    }

    #[view]
    public fun get_user_decayed_power(user: address): u64 acquires PowerStore {
        get_user_committed_power(user)
    }

    #[view]
    public fun get_operator(): address acquires PowerStore {
        if (!exists<PowerStore>(@aptos_framework)) {
            return @0x0
        };
        borrow_global<PowerStore>(@aptos_framework).operator
    }

    #[view]
    public fun get_current_period(): u64 acquires PowerStore {
        if (!exists<PowerStore>(@aptos_framework)) {
            0
        } else {
            borrow_global<PowerStore>(@aptos_framework).current_period
        }
    }

    #[view]
    public fun get_power_period_in_epochs(): u64 acquires PowerStore {
        if (!exists<PowerStore>(@aptos_framework)) {
            0
        } else {
            borrow_global<PowerStore>(@aptos_framework).power_period_in_epochs
        }
    }

    #[view]
    public fun get_retention_bps_per_period(): u64 acquires PowerStore {
        if (!exists<PowerStore>(@aptos_framework)) {
            0
        } else {
            borrow_global<PowerStore>(@aptos_framework).retention_bps_per_period
        }
    }

    // ========== 内部辅助函数 ==========

    fun initialize_power_store_internal(
        aptos_framework: &signer,
        operator: address,
        retention_bps_per_period: u64,
        power_period_in_epochs: u64,
    ) {
        system_addresses::assert_aptos_framework(aptos_framework);
        assert_valid_retention_bps(retention_bps_per_period);
        assert_valid_power_period(power_period_in_epochs);
        if (!exists<PowerStore>(@aptos_framework)) {
            move_to(aptos_framework, PowerStore {
                operator,
                power_period_in_epochs,
                last_epoch: 0,
                current_period: 0,
                users: table::new(),
                user_list: vector[],
                retention_bps_per_period,
            });
        };
    }

    fun assert_store_exists() {
        assert!(
            exists<PowerStore>(@aptos_framework),
            error::not_found(ESTORE_NOT_INITIALIZED),
        );
    }

    fun assert_operator(store: &PowerStore, caller: address) {
        assert!(
            store.operator == caller,
            error::permission_denied(ENOT_OPERATOR),
        );
    }

    fun assert_valid_retention_bps(retention_bps_per_period: u64) {
        assert!(
            retention_bps_per_period > 0
                && retention_bps_per_period <= BPS_DENOMINATOR,
            error::invalid_argument(EINVALID_RETENTION_BPS),
        );
    }

    fun assert_valid_power_period(power_period_in_epochs: u64) {
        assert!(
            power_period_in_epochs > 0,
            error::invalid_argument(EINVALID_POWER_PERIOD),
        );
    }

    fun upsert_power_version(
        store: &mut PowerStore,
        user: address,
        effective_period: u64,
        power: u64,
    ) {
        if (!store.users.contains(user)) {
            if (power == 0) {
                return
            };
            store.users.add(user, UserPowerInfo {
                older: empty_power_version(),
                newer: PowerVersion {
                    effective_period,
                    power,
                },
            });
            store.user_list.push_back(user);
            return
        };

        let info = store.users.borrow_mut(user);
        if (info.newer.effective_period == effective_period) {
            info.newer.power = power;
            normalize_user_power_info(info);
            return
        };

        if (info.older.effective_period == effective_period) {
            info.older.power = power;
            normalize_user_power_info(info);
            return
        };

        info.older = info.newer;
        info.newer = PowerVersion {
            effective_period,
            power,
        };
        normalize_user_power_info(info);
    }

    fun normalize_user_power_info(info: &mut UserPowerInfo) {
        if (info.older.effective_period > info.newer.effective_period) {
            let swapped = info.older;
            info.older = info.newer;
            info.newer = swapped;
        };
    }

    fun get_user_power_for_period_internal(
        store: &PowerStore,
        user: address,
        target_period: u64,
    ): u64 {
        if (!store.users.contains(user)) {
            return 0
        };

        let info = store.users.borrow(user);
        let (base_period, base_power) = select_effective_version(info, target_period);
        if (base_power == 0) {
            return 0
        };
        apply_retention(
            base_power,
            target_period - base_period,
            store.retention_bps_per_period,
        )
    }

    fun select_effective_version(
        info: &UserPowerInfo,
        target_period: u64,
    ): (u64, u64) {
        let newer = info.newer;
        if (newer.effective_period <= target_period && has_power_version(newer)) {
            return (newer.effective_period, newer.power)
        };

        let older = info.older;
        if (older.effective_period <= target_period && has_power_version(older)) {
            return (older.effective_period, older.power)
        };

        (0, 0)
    }

    fun has_power_version(version: PowerVersion): bool {
        version.effective_period > 0 || version.power > 0
    }

    fun apply_retention(
        power: u64,
        periods_elapsed: u64,
        retention_bps_per_period: u64,
    ): u64 {
        if (power == 0 || periods_elapsed == 0) {
            return power
        };

        let retained_power = power;
        let i = 0;
        while (i < periods_elapsed) {
            if (retained_power == 0) {
                return 0
            };
            retained_power =
                (((retained_power as u128) * (retention_bps_per_period as u128))
                    / (BPS_DENOMINATOR as u128)) as u64;
            i += 1;
        };
        retained_power
    }

    fun period_for_epoch(epoch: u64, power_period_in_epochs: u64): u64 {
        if (epoch == 0) {
            0
        } else {
            (epoch - 1) / power_period_in_epochs
        }
    }

    fun empty_power_version(): PowerVersion {
        PowerVersion {
            effective_period: 0,
            power: 0,
        }
    }

    fun empty_user_power_info(): UserPowerInfo {
        UserPowerInfo {
            older: empty_power_version(),
            newer: empty_power_version(),
        }
    }

    // ========== 测试 ==========

    #[test(framework = @aptos_framework, operator = @0xA, user1 = @0xB, user2 = @0xC)]
    public entry fun test_stage_update_commits_on_boundary(
        framework: signer,
        operator: signer,
        user1: signer,
        user2: signer,
    ) acquires PowerStore {
        initialize_with_power_period(&framework, signer::address_of(&operator), 1);
        set_genesis_committed_power(&framework, signer::address_of(&user1), 100);

        stage_batch_update(
            &operator,
            1,
            vector[signer::address_of(&user1), signer::address_of(&user2)],
            vector[90u64, 30u64],
        );

        assert!(get_current_period() == 0, 0);
        assert!(get_user_committed_power(signer::address_of(&user1)) == 100, 1);
        assert!(get_user_committed_power(signer::address_of(&user2)) == 0, 2);
        assert!(get_user_power_for_period(signer::address_of(&user1), 1) == 90, 3);
        assert!(get_user_power_for_period(signer::address_of(&user2), 1) == 30, 4);

        commit_next_period_if_boundary();
        assert!(get_current_period() == 0, 5);
        assert!(get_user_committed_power(signer::address_of(&user1)) == 100, 6);

        commit_next_period_if_boundary();
        assert!(get_current_period() == 1, 7);
        assert!(get_user_committed_power(signer::address_of(&user1)) == 90, 8);
        assert!(get_user_committed_power(signer::address_of(&user2)) == 30, 9);
    }

    #[test(framework = @aptos_framework, operator = @0xA, user1 = @0xB)]
    public entry fun test_retention_carries_forward_without_pending_updates(
        framework: signer,
        operator: signer,
        user1: signer,
    ) acquires PowerStore {
        initialize_with_power_period(&framework, signer::address_of(&operator), 1);
        set_genesis_committed_power(&framework, signer::address_of(&user1), 100);

        commit_next_period_if_boundary();
        commit_next_period_if_boundary();
        assert!(get_current_period() == 1, 0);
        assert!(get_user_committed_power(signer::address_of(&user1)) == 80, 1);

        commit_next_period_if_boundary();
        assert!(get_current_period() == 2, 2);
        assert!(get_user_committed_power(signer::address_of(&user1)) == 64, 3);
    }

    #[test(framework = @aptos_framework, operator = @0xA, user1 = @0xB)]
    public entry fun test_stage_update_overwrites_pending_value(
        framework: signer,
        operator: signer,
        user1: signer,
    ) acquires PowerStore {
        initialize_with_power_period(&framework, signer::address_of(&operator), 1);
        set_genesis_committed_power(&framework, signer::address_of(&user1), 100);

        stage_batch_update(
            &operator,
            1,
            vector[signer::address_of(&user1)],
            vector[70u64],
        );
        stage_batch_update(
            &operator,
            1,
            vector[signer::address_of(&user1)],
            vector[55u64],
        );

        commit_next_period_if_boundary();
        commit_next_period_if_boundary();
        assert!(get_current_period() == 1, 0);
        assert!(get_user_committed_power(signer::address_of(&user1)) == 55, 1);
    }

    #[test(framework = @aptos_framework, operator = @0xA, user1 = @0xB)]
    public entry fun test_stage_update_keeps_current_period_stable_on_long_period(
        framework: signer,
        operator: signer,
        user1: signer,
    ) acquires PowerStore {
        initialize_with_power_period(&framework, signer::address_of(&operator), 2);
        set_genesis_committed_power(&framework, signer::address_of(&user1), 100);

        // epoch 1 结束后，仍在 period 0
        commit_next_period_if_boundary();
        assert!(get_current_period() == 0, 0);
        assert!(get_user_committed_power(signer::address_of(&user1)) == 100, 1);

        stage_batch_update(
            &operator,
            1,
            vector[signer::address_of(&user1)],
            vector[90u64],
        );

        // 当前 period 读取仍然稳定，下一 period 才看到新值
        assert!(get_user_committed_power(signer::address_of(&user1)) == 100, 2);
        assert!(get_user_power_for_period(signer::address_of(&user1), 1) == 90, 3);

        // epoch 2 结束后，仍在 period 0
        commit_next_period_if_boundary();
        assert!(get_current_period() == 0, 4);
        assert!(get_user_committed_power(signer::address_of(&user1)) == 100, 5);

        // epoch 3 结束后，进入 period 1
        commit_next_period_if_boundary();
        assert!(get_current_period() == 1, 6);
        assert!(get_user_committed_power(signer::address_of(&user1)) == 90, 7);
    }

    #[test(framework = @aptos_framework, operator = @0xA, user1 = @0xB)]
    public entry fun test_zero_power_update_clears_future_period(
        framework: signer,
        operator: signer,
        user1: signer,
    ) acquires PowerStore {
        initialize_with_power_period(&framework, signer::address_of(&operator), 1);
        set_genesis_committed_power(&framework, signer::address_of(&user1), 100);

        stage_batch_update(
            &operator,
            1,
            vector[signer::address_of(&user1)],
            vector[0u64],
        );

        assert!(get_user_committed_power(signer::address_of(&user1)) == 100, 0);
        assert!(get_user_power_for_period(signer::address_of(&user1), 1) == 0, 1);

        commit_next_period_if_boundary();
        commit_next_period_if_boundary();
        assert!(get_current_period() == 1, 2);
        assert!(get_user_committed_power(signer::address_of(&user1)) == 0, 3);
    }
}
