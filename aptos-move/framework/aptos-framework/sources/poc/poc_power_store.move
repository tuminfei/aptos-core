/// POC 算力存储合约 —— 只负责保存用户当前算力值并发出更新事件
///
/// 设计边界：
/// - 链下服务负责计算最终算力结果
/// - 链上只保存 `user -> power` 和最后更新周期
/// - 更新时发出事件
/// - 链下自行查询用户值或事件，确认写入是否成功
/// - 不负责周期终局、批次幂等、治理、共识等语义
/// - 为防止乱序写回，旧周期写入不会覆盖链上已存在的新周期结果
module aptos_framework::poc_power_store {
    use std::error;
    use std::signer;

    use aptos_std::table::{Self, Table};

    use aptos_framework::event;
    use aptos_framework::system_addresses;

    friend aptos_framework::genesis;

    const POWER_DECIMALS: u64 = 18;

    // ========== 错误码 ==========

    /// 算力存储尚未初始化
    const ESTORE_NOT_INITIALIZED: u64 = 1;
    /// 调用者不是唯一 operator
    const ENOT_OPERATOR: u64 = 2;
    /// `users` 与 `powers` 长度不一致
    const EINVALID_BATCH_LENGTH: u64 = 3;

    // ========== 核心资源 ==========

    /// 全局算力存储，挂在 @aptos_framework 地址下。
    struct PowerStore has key {
        /// 唯一写入者
        operator: address,
        /// 用户当前最新算力
        users: Table<address, UserPowerInfo>,
    }

    /// 用户当前算力信息。
    struct UserPowerInfo has copy, drop, store {
        power: u128,
        last_updated_period: u64,
    }

    // ========== 事件 ==========

    #[event]
    struct OperatorChangedEvent has drop, store {
        old_operator: address,
        new_operator: address,
    }

    #[event]
    struct PowerUpdatedEvent has drop, store {
        period: u64,
        user: address,
        power: u128,
    }

    // ========== 初始化 ==========

    /// 由 genesis 调用的 friend 初始化入口。
    public(friend) fun initialize(aptos_framework: &signer, operator: address) {
        initialize_power_store(aptos_framework, operator);
    }

    /// 初始化全局算力存储。
    /// 仅限 @aptos_framework 地址调用，幂等执行。
    public entry fun initialize_power_store(
        aptos_framework: &signer,
        operator: address,
    ) {
        system_addresses::assert_aptos_framework(aptos_framework);
        if (!exists<PowerStore>(@aptos_framework)) {
            move_to(aptos_framework, PowerStore {
                operator,
                users: table::new(),
            });
        };
    }

    /// 更新唯一 operator 地址。
    /// 仅限 @aptos_framework 调用；新旧地址相同则幂等返回。
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

    /// 批量更新用户算力。
    ///
    /// 说明：
    /// - 本模块不做链上批次幂等
    /// - 同一用户被再次写入时：
    ///   - 若 `period >= last_updated_period`，则覆盖旧值和最后更新周期
    ///   - 若 `period < last_updated_period`，则跳过该用户，防止旧周期回退覆盖
    /// - 只有实际发生写入的用户才会发出 `PowerUpdatedEvent`
    public entry fun batch_update(
        operator: &signer,
        period: u64,
        users: vector<address>,
        powers: vector<u128>,
    ) acquires PowerStore {
        assert_store_exists();
        assert!(
            users.length() == powers.length(),
            error::invalid_argument(EINVALID_BATCH_LENGTH),
        );

        let store = borrow_global_mut<PowerStore>(@aptos_framework);
        assert_operator(store, signer::address_of(operator));

        let length = users.length();
        let i = 0;
        while (i < length) {
            let user = *users.borrow(i);
            let power = *powers.borrow(i);
            if (upsert_user_power_if_not_stale(store, user, power, period)) {
                event::emit(PowerUpdatedEvent { period, user, power });
            };
            i += 1;
        };
    }

    // ========== 查询接口 ==========
    #[view]
    public fun get_power_deciamls(): u64 {
        POWER_DECIMALS
    }

    // 获取用户当前最新算力；不存在时返回 0。
    #[view]
    public fun get_user_power(user: address): u128 acquires PowerStore {
        get_user_power_info(user).power
    }

    // 获取用户当前最新算力信息；不存在时返回默认零值。
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

    // 获取当前 operator 地址；未初始化时返回 `@0x0`。
    #[view]
    public fun get_operator(): address acquires PowerStore {
        if (!exists<PowerStore>(@aptos_framework)) {
            return @0x0
        };
        borrow_global<PowerStore>(@aptos_framework).operator
    }

    // ========== 内部辅助函数 ==========

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

    fun upsert_user_power_if_not_stale(
        store: &mut PowerStore,
        user: address,
        power: u128,
        period: u64,
    ): bool {
        if (store.users.contains(user)) {
            let info = store.users.borrow_mut(user);
            if (period < info.last_updated_period) {
                return false
            };
            info.power = power;
            info.last_updated_period = period;
            true
        } else {
            store.users.add(user, UserPowerInfo {
                power,
                last_updated_period: period,
            });
            true
        }
    }

    fun empty_user_power_info(): UserPowerInfo {
        UserPowerInfo {
            power: 0,
            last_updated_period: 0,
        }
    }

    // ========== 测试 ==========

    #[test(framework = @aptos_framework, operator = @0xA, user1 = @0xB, user2 = @0xC)]
    public entry fun test_batch_update(
        framework: signer,
        operator: signer,
        user1: signer,
        user2: signer,
    ) acquires PowerStore {
        initialize_power_store(&framework, signer::address_of(&operator));
        assert!(get_operator() == signer::address_of(&operator), 0);

        batch_update(
            &operator,
            1,
            vector[signer::address_of(&user1), signer::address_of(&user2)],
            vector[10u128, 20u128],
        );

        let user1_info = get_user_power_info(signer::address_of(&user1));
        let user2_info = get_user_power_info(signer::address_of(&user2));
        assert!(user1_info.power == 10, 1);
        assert!(user1_info.last_updated_period == 1, 2);
        assert!(user2_info.power == 20, 3);
        assert!(user2_info.last_updated_period == 1, 4);
        assert!(get_user_power(@0xD) == 0, 5);
    }

    #[test(framework = @aptos_framework, operator = @0xA, user1 = @0xB)]
    public entry fun test_batch_update_overwrites_user_power(
        framework: signer,
        operator: signer,
        user1: signer,
    ) acquires PowerStore {
        initialize_power_store(&framework, signer::address_of(&operator));

        batch_update(
            &operator,
            1,
            vector[signer::address_of(&user1)],
            vector[42u128],
        );
        batch_update(
            &operator,
            2,
            vector[signer::address_of(&user1)],
            vector[88u128],
        );

        let info = get_user_power_info(signer::address_of(&user1));
        assert!(info.power == 88, 0);
        assert!(info.last_updated_period == 2, 1);
    }

    #[test(framework = @aptos_framework, operator = @0xA, user1 = @0xB, user2 = @0xC)]
    public entry fun test_batch_update_skips_stale_period_updates(
        framework: signer,
        operator: signer,
        user1: signer,
        user2: signer,
    ) acquires PowerStore {
        initialize_power_store(&framework, signer::address_of(&operator));

        batch_update(
            &operator,
            2,
            vector[signer::address_of(&user1)],
            vector[88u128],
        );

        batch_update(
            &operator,
            1,
            vector[signer::address_of(&user1), signer::address_of(&user2)],
            vector[42u128, 15u128],
        );

        let user1_info = get_user_power_info(signer::address_of(&user1));
        let user2_info = get_user_power_info(signer::address_of(&user2));
        assert!(user1_info.power == 88, 0);
        assert!(user1_info.last_updated_period == 2, 1);
        assert!(user2_info.power == 15, 2);
        assert!(user2_info.last_updated_period == 1, 3);
    }
}