/// 在同一版本中保存 PoC 原始算力和标准化单位，并维护算力周期时钟。
/// 链下计算原始算力，由获授权的 operator 或框架上传；每个用户保留最近两个版本。
/// 一个算力周期内只接受下一算力周期的版本，同一生效周期保留首次写入，不提前改变当前持仓。
///
/// 原始算力查询沿用逐周期整数衰减。标准化单位 units 保持不变，换算算力时使用逐周期衰减的共同指数。
/// 用户分配使用标准化单位，BFT 权重读取已安装的 ValidatorSet，治理仍按原生代币计权。
/// 算力存储和周期时钟一次性初始化；创世写入和后续上传直接建立标准化版本。
///
/// 时钟只在成功安装 Epoch 时推进。算力周期和指数下标均从初始化时的周期 0 起算。
/// 默认一个算力周期包含 60 个 Epoch：安装 Epoch 1 后倒计时为 59，安装 Epoch 61 才进入源周期 1。
/// 部署显式提供保留比例和周期长度；保留比例自初始化起固定。
///
/// 协议经济规格：TOPO 最大发行总量 100 亿，年通胀率严格低于 10%。
/// 1 TOPO = 10^8 Octa，总量上限为 10^18 Octa；算力和 units 不使用代币金额作为上限。
/// PoC 不设协议失效期限；当前指数下界是定精度计算的数值边界，奖励容量证明见 poc_accounting。
module topo_framework::poc_power_store {
    use std::error;
    use std::option::{Self, Option};
    use std::signer;

    use topo_std::table;
    use topo_std::table::Table;

    use topo_framework::event;
    use topo_framework::chain_status;
    use topo_framework::poc_accounting;
    use topo_framework::system_addresses;

    friend topo_framework::genesis;
    friend topo_framework::stake;
    friend topo_framework::poc_allocation;

    // 比例分母：10000 bps = 100%。
    const BPS_DENOMINATOR: u64 = 10000;
    const INDEX_SCALE: u128 = 18446744073709551616;
    // 2^16 的 units 精度；周期 0 时 1 unit = 1/65536 power，小份额按万分比分配后向下取整。
    // 与 poc_accounting 保持一致。配合 2^24 指数下界，u64 最大算力仍满足 units < 2^120。
    const UNIT_SCALE: u128 = 65536;
    const MIN_PERIOD_INDEX: u128 = 16777216;
    const MAX_VERSION_UNITS: u256 = 1329227995784915872903807060280344576;
    const MAX_U64: u128 = 18446744073709551615;

    // ========== 错误码 ==========

    /// 算力存储或周期时钟尚未初始化。
    const ESTORE_NOT_INITIALIZED: u64 = 1;
    /// 调用者没有上传权限。
    const ENOT_OPERATOR: u64 = 2;
    /// 批量上传的 users 与 powers 长度不一致。
    const EINVALID_BATCH_LENGTH: u64 = 3;
    /// 保留比例必须大于 0 且不超过 10000 bps。
    const EINVALID_RETENTION_BPS: u64 = 4;
    /// 算力周期长度必须为正，边界 Epoch 不能超过 u64 上限。
    const EINVALID_POWER_PERIOD: u64 = 5;
    /// 生效算力周期只能是 current_period + 1，不能提前写入更远周期。
    const EINVALID_EFFECTIVE_PERIOD: u64 = 6;
    /// 算力周期 0 的直接写入仅限真实创世阶段，且时钟尚未推进。
    const EGENESIS_COMMIT_ONLY: u64 = 7;
    /// 周期、指数或标准化单位超出本版支持范围。
    const EPOWER_HORIZON: u64 = 8;
    /// 算力版本顺序或时钟不一致，包括时钟与链 Epoch 的增量不一致。
    const ECLOCK_MISMATCH: u64 = 9;
    /// 算力存储只能初始化一次，不能重置基线与时钟。
    const ESTORE_ALREADY_INITIALIZED: u64 = 11;
    /// 上传人数超过部署确定的单批上限。
    const EUPLOAD_LIMIT: u64 = 13;

    // ========== 核心资源 ==========

    /// 框架地址下的算力存储；原始查询和标准化计账共用一张用户双版本表。
    struct PowerStore has key {
        /// 框架以外唯一获授权的上传地址。
        operator: address,
        /// 用户地址到双版本窗口的映射。
        users: Table<address, UserPowerInfo>,
        /// 未更新版本每周期的保留比例，初始化后固定。
        retention_bps_per_period: u64,
        /// 逐算力周期取整后的共同指数；下一周期指数由此按需计算。
        current_index: u128,
    }

    /// 框架地址下的算力周期时钟；每次成功安装 Epoch 只提交一次，源周期最多增加一。
    /// last_epoch 记录最近成功安装的绝对链 Epoch，须与算力账本对齐。
    struct PeriodClock has key {
        /// 下次切换算力周期时加载的长度，不修改当前剩余倒计时。
        power_period_in_epochs: u64,
        /// 最近成功安装的绝对链 Epoch，单调递增。
        last_epoch: u64,
        /// 当前算力周期编号，同时作为共同指数的下标。
        current_period: u64,
        /// 为零时，下一次成功安装 Epoch 切换算力周期；每次提交先判断是否为零，再减一。
        epochs_until_next_power_period: u64,
    }

    /// 用户算力版本，effective_period 表示开始生效的算力周期。
    struct PowerVersion has copy, drop, store {
        effective_period: u64,
        power: u64,
        /// 按生效周期指数计算并固定。
        units: u128,
    }

    /// 按生效算力周期排序的双版本窗口；Option 区分空槽与有效的零算力版本。
    struct UserPowerInfo has copy, drop, store {
        older: Option<PowerVersion>,
        newer: Option<PowerVersion>,
    }

    #[event]
    /// 记录实际新增的标准化版本；units 是标准化单位，power 是原始算力，二者不能混用。
    struct PowerNormalized has drop, store {
        user: address,
        effective_period: u64,
        units: u128,
    }

    // ========== 事件 ==========

    #[event]
    /// 上传地址实际改变时发出。
    struct OperatorChangedEvent has drop, store {
        old_operator: address,
        new_operator: address,
    }

    #[event]
    /// 批量上传实际新增版本时发出，重复上报不产生该事件。
    struct PowerUpdateStagedEvent has drop, store {
        /// 版本开始生效的算力周期，上传时必须为 current_period + 1。
        effective_period: u64,
        user: address,
        power: u64,
    }

    #[event]
    /// 成功安装 Epoch 且切换算力周期时发出，供链下服务跟踪周期边界。
    struct PowerPeriodCommittedEvent has drop, store {
        previous_period: u64,
        current_period: u64,
    }

    // ========== 初始化 ==========

    /// 同时创建算力表和周期时钟，仅供 PoC 初始化流程调用。
    /// 算力周期从 0 起算，时钟从当前绝对 Epoch 起算；保留比例和基准指数 I[0] 自此固定。
    public(friend) fun initialize(
        framework: &signer,
        epoch: u64,
        retention_bps: u64,
        power_period_in_epochs: u64,
        power_operator: address,
    ) {
        system_addresses::assert_topo_framework(framework);
        poc_accounting::assert_not_frozen();
        assert!(!exists<PowerStore>(@topo_framework) && !exists<PeriodClock>(@topo_framework),
            error::already_exists(ESTORE_ALREADY_INITIALIZED));
        assert!(epoch == poc_accounting::current_epoch(), error::invalid_state(ECLOCK_MISMATCH));
        assert_valid_power_period(power_period_in_epochs);
        assert_valid_retention_bps(retention_bps);
        // 初始 r 为周期长度，检查首个边界及再下一边界；三个 u64 量之和由 u128 安全覆盖。
        assert!((epoch as u128) + 2 * (power_period_in_epochs as u128) + 1 <= MAX_U64,
            error::invalid_argument(EINVALID_POWER_PERIOD));
        move_to(framework, PowerStore {
            operator: power_operator,
            users: table::new(),
            retention_bps_per_period: retention_bps,
            current_index: INDEX_SCALE,
        });
        move_to(framework, PeriodClock {
            power_period_in_epochs,
            last_epoch: epoch,
            current_period: 0,
            epochs_until_next_power_period: power_period_in_epochs,
        });
    }

    // ========== 配置更新 ==========

    /// 设置下一个算力周期的长度，保持当前倒计时和已确定的边界 B 不变。
    /// 按链 Epoch 计算 B = E + r + 1，并以 u128 检查 B + 新长度是否超过 u64 上限。
    public entry fun set_power_period_in_epochs(
        topo_framework: &signer,
        power_period_in_epochs: u64,
    ) {
        system_addresses::assert_topo_framework(topo_framework);
        poc_accounting::assert_not_frozen();
        assert_store_exists();
        assert_clock_exists();
        assert_valid_power_period(power_period_in_epochs);
        assert_clock_alignment();
        let epoch = poc_accounting::current_epoch();
        let clock = borrow_global<PeriodClock>(@topo_framework);
        let boundary = (epoch as u128) + (clock.epochs_until_next_power_period as u128) + 1;
        assert!(boundary + (power_period_in_epochs as u128) <= MAX_U64,
            error::invalid_argument(EINVALID_POWER_PERIOD));
        borrow_global_mut<PeriodClock>(@topo_framework).power_period_in_epochs =
            power_period_in_epochs;
    }

    /// 更换获授权的上传地址，仅框架可调用；冻结期间拒绝修改，地址未变时不重复发事件。
    public entry fun set_operator(
        topo_framework: &signer,
        new_operator: address,
    ) {
        system_addresses::assert_topo_framework(topo_framework);
        poc_accounting::assert_not_frozen();
        assert_store_exists();

        let store = borrow_global_mut<PowerStore>(@topo_framework);
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

    // ========== 版本写入 ==========

    /// 批量写入下一算力周期的原始版本，仅 operator 或框架可调用，users 与 powers 必须等长。
    /// 同一用户、同一生效周期保留首次写入；新用户零值不建记录，已有用户零值从下一周期生效。
    /// 仅对实际新增版本执行标准化和分配同步，任何失败均回滚整批写入。
    /// 冻结期间也拒绝重复上报，所有请求均须先通过冻结检查。
    public entry fun stage_batch_update(
        operator: &signer,
        effective_period: u64,
        users: vector<address>,
        powers: vector<u64>,
    ) {
        poc_accounting::assert_not_frozen();
        assert_store_exists();
        assert_clock_exists();
        assert!(
            users.length() == powers.length(),
            error::invalid_argument(EINVALID_BATCH_LENGTH),
        );

        let current_period = borrow_global<PeriodClock>(@topo_framework).current_period;
        assert_power_update_authority(borrow_global<PowerStore>(@topo_framework), signer::address_of(operator));
        assert!(
            (effective_period as u128) == (current_period as u128) + 1,
            error::invalid_argument(EINVALID_EFFECTIVE_PERIOD),
        );
        assert_clock_alignment();
        assert!(users.length() <= poc_accounting::max_upload_users(), error::invalid_argument(EUPLOAD_LIMIT));
        let next_index = next_index_at(borrow_global<PowerStore>(@topo_framework), current_period);
        assert!(next_index.is_some(), error::invalid_state(EPOWER_HORIZON));
        let index = *next_index.borrow();

        let length = users.length();
        let i = 0;
        while (i < length) {
            let user = *users.borrow(i);
            let power = *powers.borrow(i);
            if (will_insert_version(borrow_global<PowerStore>(@topo_framework), user, effective_period, power)) {
                let store = borrow_global<PowerStore>(@topo_framework);
                let version = normalized_version(effective_period, power, index);
                let older = if (store.users.contains(user)) {
                    store.users.borrow(user).newer
                } else { option::none() };
                let replacement = UserPowerInfo { older, newer: option::some(version) };
                let (current_units, next_units) = snapshot_units(&replacement, current_period);
                poc_accounting::sync_power_versions(user, current_units, next_units, next_boundary_epoch());
                event::emit(PowerNormalized { user, effective_period, units: version.units });
                save_power_versions(borrow_global_mut<PowerStore>(@topo_framework), user, replacement);
                event::emit(PowerUpdateStagedEvent {
                    effective_period,
                    user,
                    power,
                });
            };
            i += 1;
        };
    }


    /// 写入源周期 0 的初始原始算力，仅框架可在真实创世阶段调用。
    /// 创世 Epoch 与源周期必须均为零；同步写入标准化版本与分配。
    public entry fun set_genesis_committed_power(
        topo_framework: &signer,
        user: address,
        power: u64,
    ) {
        system_addresses::assert_topo_framework(topo_framework);
        poc_accounting::assert_not_frozen();
        chain_status::assert_genesis();
        assert_store_exists();
        assert_clock_exists();

        let clock = borrow_global<PeriodClock>(@topo_framework);
        assert!(
            clock.last_epoch == 0 && clock.current_period == 0,
            error::invalid_state(EGENESIS_COMMIT_ONLY),
        );
        set_genesis_power_version(user, power);
    }

    #[test_only]
    /// 仅供测试在创世结束后构造初始算力数据，不进入生产字节码。
    public fun set_committed_power_for_test(
        topo_framework: &signer,
        user: address,
        power: u64,
    ) {
        system_addresses::assert_topo_framework(topo_framework);
        assert_store_exists();
        set_genesis_power_version(user, power);
    }

    /// 推进一次 Epoch 提交计数，并在倒计时结束时切换算力周期。
    /// 每次成功安装 PoC 计划时调用一次。
    /// 这是推进源周期的唯一入口，Deferred、DKG 启动和等待均不能调用。
    /// 先判断倒计时是否为零，必要时切换周期并加载新长度，最后减一。
    /// 长度为 60 时，创世安装 Epoch 1 后 r = 59，安装 Epoch 61 才进入源周期 1。
    /// 调用方须接着更新账本 Epoch，使其与时钟提交次数自初始化以来的增量一致。
    friend fun commit_next_period_if_boundary() {
        let (valid, _, _) = preview_next_period();
        assert!(valid, error::invalid_state(EPOWER_HORIZON));
        let clock = borrow_global_mut<PeriodClock>(@topo_framework);
        assert!((clock.last_epoch as u128) < MAX_U64, error::invalid_state(EPOWER_HORIZON));
        clock.last_epoch += 1;
        if (clock.epochs_until_next_power_period == 0) {
            let previous_period = clock.current_period;
            let next_period = previous_period + 1;
            clock.current_period = next_period;
            clock.epochs_until_next_power_period = clock.power_period_in_epochs;
            let store = borrow_global_mut<PowerStore>(@topo_framework);
            let next_index = next_index_at(store, previous_period);
            store.current_index = *next_index.borrow();
            event::emit(PowerPeriodCommittedEvent {
                previous_period,
                current_period: next_period,
            });
        };

        clock.epochs_until_next_power_period -= 1;
    }

    #[view]
    /// 算力存储存在即表示标准化字段和时钟已初始化，查询不创建资源。
    public fun is_initialized(): bool { exists<PowerStore>(@topo_framework) }

    #[view]
    /// 查询用户是否已有直接写入的标准化算力版本。
    public fun is_user_normalized(user: address): bool {
        is_initialized()
            && borrow_global<PowerStore>(@topo_framework).users.contains(user)
    }

    #[test_only]
    /// 逐算力周期计算并检查给定范围内的指数，供数值边界测试使用。
    public fun validate_index_horizon(retention_bps: u64, periods_to_check: u64) {
        assert_valid_retention_bps(retention_bps);
        // 保留比例为 100% 时无需逐期重算，周期上界由 u64 类型约束。
        if (retention_bps == BPS_DENOMINATOR) return;
        let index = INDEX_SCALE;
        let period = 0;
        while ({
            spec {
                invariant MIN_PERIOD_INDEX <= index && index <= INDEX_SCALE;
                invariant period <= periods_to_check;
            };
            period < periods_to_check
        }) {
            index = decayed_index(index, retention_bps);
            assert!(index >= MIN_PERIOD_INDEX, error::invalid_argument(EPOWER_HORIZON));
            period += 1;
        };
    }

    #[view]
    /// 返回下一算力周期开始时的链 Epoch：B = E + r + 1；先检查计数对齐，再以 u128 检查上界。
    public fun next_boundary_epoch(): u64 {
        assert_clock_alignment();
        let clock = borrow_global<PeriodClock>(@topo_framework);
        let boundary = (poc_accounting::current_epoch() as u128)
            + (clock.epochs_until_next_power_period as u128) + 1;
        assert!(boundary <= MAX_U64, error::invalid_state(EPOWER_HORIZON));
        boundary as u64
    }

    #[view]
    /// 预览下一次 Epoch 安装后的时钟，返回（是否受支持、目标源周期、目标共同指数）。
    /// 在创建计划、冻结配置前检查目标 Epoch、周期切换后的倒计时和下一边界；只读，不推进账本。
    public fun preview_next_period(): (bool, u64, u128) {
        assert_clock_alignment();
        let clock = borrow_global<PeriodClock>(@topo_framework);
        let store = borrow_global<PowerStore>(@topo_framework);
        let target_epoch = (poc_accounting::current_epoch() as u128) + 1;
        let period = clock.current_period;
        let index = store.current_index;
        let countdown = clock.epochs_until_next_power_period;
        if (countdown == 0) {
            let next_index = next_index_at(store, period);
            if (next_index.is_none()) {
                return (false, period, index)
            };
            period += 1;
            index = *next_index.borrow();
            countdown = clock.power_period_in_epochs;
        };
        assert!(countdown > 0, error::invalid_state(ECLOCK_MISMATCH));
        countdown -= 1;
        let boundary = target_epoch + (countdown as u128) + 1;
        let valid = target_epoch <= MAX_U64
            && (clock.last_epoch as u128) < MAX_U64
            && boundary <= MAX_U64
            && index >= MIN_PERIOD_INDEX;
        (valid, period, index)
    }

    #[view]
    /// 返回当前算力周期、绝对边界 B、当前指数及可选下一指数。
    public fun get_normalization_clock(): (u64, u64, u128, Option<u128>) {
        assert_clock_alignment();
        let current_period = get_current_period();
        let boundary = next_boundary_epoch();
        let store = borrow_global<PowerStore>(@topo_framework);
        (current_period, boundary, store.current_index, next_index_at(store, current_period))
    }

    #[view]
    /// 返回当前与下一算力周期的标准化单位 units、当前源周期及边界 Epoch B；查询不创建记录。
    /// 没有未来版本时沿用当前 units，仅共同指数随周期衰减。
    public fun get_accounting_snapshot(user: address): (u128, u128, u64, u64) {
        assert_clock_alignment();
        let store = borrow_global<PowerStore>(@topo_framework);
        let period = get_current_period();
        if (!store.users.contains(user)) return (0, 0, period, next_boundary_epoch());
        let (current_units, next_units) = snapshot_units(store.users.borrow(user), period);
        (current_units, next_units, period, next_boundary_epoch())
    }

    /// 检查时钟最近安装的绝对 Epoch 与算力账本是否相同。
    fun assert_clock_alignment() {
        assert_store_exists();
        let clock = borrow_global<PeriodClock>(@topo_framework);
        assert!(clock.last_epoch == poc_accounting::current_epoch(),
            error::invalid_state(ECLOCK_MISMATCH));
    }

    /// index <= 2^64、retention_bps <= 10000，乘积小于 2^78；使用 u128 保持逐期向下取整。
    fun decayed_index(index: u128, retention_bps: u64): u128 {
        index * (retention_bps as u128) / (BPS_DENOMINATOR as u128)
    }

    /// 下一周期编号必须可表示，且指数不低于数值下界；否则返回 none。
    fun supported_next_index(index: u128, period: u64, retention_bps: u64): Option<u128> {
        let next = decayed_index(index, retention_bps);
        if ((period as u128) < MAX_U64 && next >= MIN_PERIOD_INDEX) {
            option::some(next)
        } else {
            option::none()
        }
    }

    /// 下一周期是否受支持由当前指数、周期和保留比例唯一确定。
    fun next_index_at(store: &PowerStore, period: u64): Option<u128> {
        supported_next_index(store.current_index, period, store.retention_bps_per_period)
    }

    /// 按版本生效周期的指数计算标准化单位 units；确认严格小于 2^120 后，再转为 u128 保存。
    fun normalized_version(effective_period: u64, power: u64, index: u128): PowerVersion {
        assert!(index >= MIN_PERIOD_INDEX, error::invalid_argument(EPOWER_HORIZON));
        let units = (power as u256) * (UNIT_SCALE as u256) * (INDEX_SCALE as u256) / (index as u256);
        assert!(units < MAX_VERSION_UNITS, error::invalid_argument(EPOWER_HORIZON));
        PowerVersion { effective_period, power, units: units as u128 }
    }

    /// 从已有标准化版本中取当前和下一算力周期的 units；长期未更新的版本也不重新计算 units。
    fun snapshot_units(info: &UserPowerInfo, period: u64): (u128, u128) {
        let version = select_effective_version(info, period);
        let current = if (version.is_some()) version.borrow().units else 0;
        let next = current;
        if (info.newer.is_some() && info.newer.borrow().effective_period > period) {
            assert!((info.newer.borrow().effective_period as u128) == (period as u128) + 1,
                error::invalid_state(ECLOCK_MISMATCH));
            next = info.newer.borrow().units;
        };
        (current, next)
    }

    /// 判断本次上报是否会新增版本，避免重复上报触发同步或新增事件。
    fun will_insert_version(store: &PowerStore, user: address, period: u64, power: u64): bool {
        if (!store.users.contains(user)) return power > 0;
        let info = store.users.borrow(user);
        (info.older.is_none() || info.older.borrow().effective_period != period)
            && (info.newer.is_none() || info.newer.borrow().effective_period != period)
    }

    // ========== 原始算力查询 ==========

    #[view]
    public fun get_user_committed_power(user: address): u64 {
        if (!exists<PowerStore>(@topo_framework) || !exists<PeriodClock>(@topo_framework)) {
            return 0
        };
        let clock = borrow_global<PeriodClock>(@topo_framework);
        let store = borrow_global<PowerStore>(@topo_framework);
        get_user_power_for_period_internal(store, user, clock.current_period)
    }

    #[view]
    public fun get_user_committed_power_for_next_epoch(
        user: address,
    ): u64 {
        if (!exists<PowerStore>(@topo_framework) || !exists<PeriodClock>(@topo_framework)) {
            return 0
        };

        let store = borrow_global<PowerStore>(@topo_framework);
        let clock = borrow_global<PeriodClock>(@topo_framework);
        let query_period = if (clock.epochs_until_next_power_period == 0) {
                clock.current_period + 1
            } else {
                clock.current_period
            };
        get_user_power_for_period_internal(store, user, query_period)
    }

    #[view]
    public fun get_user_power_for_period(
        user: address,
        query_period: u64,
    ): u64 {
        if (!exists<PowerStore>(@topo_framework)) {
            return 0
        };
        let store = borrow_global<PowerStore>(@topo_framework);
        get_user_power_for_period_internal(store, user, query_period)
    }

    #[view]
    public fun get_user_committed_powers(
        users: vector<address>,
    ): vector<u64> {
        if (!exists<PowerStore>(@topo_framework) || !exists<PeriodClock>(@topo_framework)) {
            return vector[]
        };
        let period = borrow_global<PeriodClock>(@topo_framework).current_period;
        get_user_powers_for_period(users, period)
    }

    #[view]
    public fun get_user_powers_for_period(
        users: vector<address>,
        query_period: u64,
    ): vector<u64> {
        let powers = vector[];
        if (!exists<PowerStore>(@topo_framework)) {
            return powers
        };
        let store = borrow_global<PowerStore>(@topo_framework);
        let len = users.length();
        let i = 0;
        while (i < len) {
            powers.push_back(get_user_power_for_period_internal(
                store,
                *users.borrow(i),
                query_period,
            ));
            i += 1;
        };
        powers
    }

    #[view]
    public fun get_user_power_version(
        user: address,
    ): (u64, u64, u64, u64, u64) {
        if (!exists<PowerStore>(@topo_framework) || !exists<PeriodClock>(@topo_framework)) {
            return (0, 0, 0, 0, 0)
        };
        let clock = borrow_global<PeriodClock>(@topo_framework);
        let store = borrow_global<PowerStore>(@topo_framework);
        build_user_power_version(store, user, clock.current_period)
    }

    #[view]
    public fun get_user_power_versions_by_addresses(
        users: vector<address>,
    ): (
        vector<address>,
        vector<u64>,
        vector<u64>,
        vector<u64>,
        vector<u64>,
        vector<u64>,
    ) {
        let returned_users = vector[];
        let older_effective_periods = vector[];
        let older_powers = vector[];
        let newer_effective_periods = vector[];
        let newer_powers = vector[];
        let committed_powers = vector[];
        if (!exists<PowerStore>(@topo_framework) || !exists<PeriodClock>(@topo_framework)) {
            return (
                returned_users,
                older_effective_periods,
                older_powers,
                newer_effective_periods,
                newer_powers,
                committed_powers,
            )
        };
        let clock = borrow_global<PeriodClock>(@topo_framework);
        let store = borrow_global<PowerStore>(@topo_framework);
        let len = users.length();
        let i = 0;
        while (i < len) {
            let user = *users.borrow(i);
            let (
                older_effective_period,
                older_power,
                newer_effective_period,
                newer_power,
                committed_power,
            ) = build_user_power_version(store, user, clock.current_period);
            returned_users.push_back(user);
            older_effective_periods.push_back(older_effective_period);
            older_powers.push_back(older_power);
            newer_effective_periods.push_back(newer_effective_period);
            newer_powers.push_back(newer_power);
            committed_powers.push_back(committed_power);
            i += 1;
        };
        (
            returned_users,
            older_effective_periods,
            older_powers,
            newer_effective_periods,
            newer_powers,
            committed_powers,
        )
    }

    #[view]
    public fun get_operator(): address {
        if (!exists<PowerStore>(@topo_framework)) {
            return @0x0
        };
        borrow_global<PowerStore>(@topo_framework).operator
    }

    #[view]
    public fun get_current_period(): u64 {
        if (!exists<PeriodClock>(@topo_framework)) {
            0
        } else {
            borrow_global<PeriodClock>(@topo_framework).current_period
        }
    }

    #[view]
    public fun get_power_period_in_epochs(): u64 {
        if (!exists<PeriodClock>(@topo_framework)) {
            0
        } else {
            borrow_global<PeriodClock>(@topo_framework).power_period_in_epochs
        }
    }

    #[view]
    public fun get_retention_bps_per_period(): u64 {
        if (!exists<PowerStore>(@topo_framework)) {
            0
        } else {
            borrow_global<PowerStore>(@topo_framework).retention_bps_per_period
        }
    }

    // ========== 内部辅助函数 ==========

    fun assert_store_exists() {
        assert!(
            exists<PowerStore>(@topo_framework),
            error::not_found(ESTORE_NOT_INITIALIZED),
        );
    }

    fun assert_clock_exists() {
        assert!(
            exists<PeriodClock>(@topo_framework),
            error::not_found(ESTORE_NOT_INITIALIZED),
        );
    }

    fun assert_power_update_authority(store: &PowerStore, caller: address) {
        assert!(
            store.operator == caller || system_addresses::is_topo_framework_address(caller),
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

    /// 保存已构造的有序双版本；调用者先完成首写判断及分配同步，只写入一张用户表。
    fun save_power_versions(
        store: &mut PowerStore,
        user: address,
        versions: UserPowerInfo,
    ) {
        assert!(versions.newer.is_some(), error::invalid_state(ECLOCK_MISMATCH));
        assert!(versions.older.is_none()
            || versions.older.borrow().effective_period < versions.newer.borrow().effective_period,
            error::invalid_state(ECLOCK_MISMATCH));
        store.users.upsert(user, versions);
    }

    /// 创世和测试入口共用版本写入，原始算力与 units 始终同步。
    fun set_genesis_power_version(user: address, power: u64) {
        let store = borrow_global<PowerStore>(@topo_framework);
        if (power == 0 && !store.users.contains(user)) return;
        let version = normalized_version(0, power, INDEX_SCALE);
        // 写入周期 0 时保留已预写的未来版本，原始查询和标准化快照读取相同双槽。
        let future = if (store.users.contains(user)) {
            store.users.borrow(user).newer
        } else { option::none() };
        let replacement = if (future.is_some() && future.borrow().effective_period > 0) {
            UserPowerInfo { older: option::some(version), newer: future }
        } else {
            UserPowerInfo { older: option::none(), newer: option::some(version) }
        };
        assert_clock_alignment();
        let (current_units, next_units) = snapshot_units(&replacement, 0);
        poc_accounting::sync_power_versions(user, current_units, next_units, next_boundary_epoch());
        event::emit(PowerNormalized { user, effective_period: 0, units: version.units });
        save_power_versions(borrow_global_mut<PowerStore>(@topo_framework), user, replacement);
    }

    /// 选择在 query_period 已生效的最新版本，再按经过的算力周期逐期整数衰减。
    /// query_period 是查询时点，effective_period 是版本生效时点，经过周期数为二者之差。
    /// 用户无记录或查询时点尚无生效版本时返回 0。
    fun get_user_power_for_period_internal(
        store: &PowerStore,
        user: address,
        query_period: u64,
    ): u64 {
        if (!store.users.contains(user)) {
            return 0
        };

        let info = store.users.borrow(user);
        let version = select_effective_version(info, query_period);
        if (version.is_none()) return 0;
        let version = version.borrow();
        apply_retention(
            version.power,
            query_period - version.effective_period,
            store.retention_bps_per_period,
        )
    }

    fun build_user_power_version(
        store: &PowerStore,
        user: address,
        current_period: u64,
    ): (u64, u64, u64, u64, u64) {
        if (!store.users.contains(user)) {
            return (0, 0, 0, 0, 0)
        };
        let info = store.users.borrow(user);
        let (older_period, older_power) = version_fields(&info.older);
        let (newer_period, newer_power) = version_fields(&info.newer);
        (
            older_period,
            older_power,
            newer_period,
            newer_power,
            get_user_power_for_period_internal(
                store,
                user,
                current_period,
            ),
        )
    }

    /// 原始算力和 units 共用有效版本选择；有效零版本也覆盖较早的非零版本。
    fun select_effective_version(
        info: &UserPowerInfo,
        query_period: u64,
    ): Option<PowerVersion> {
        if (info.newer.is_some() && info.newer.borrow().effective_period <= query_period) {
            return info.newer
        };
        if (info.older.is_some() && info.older.borrow().effective_period <= query_period) {
            return info.older
        };
        option::none()
    }

    /// 原始版本查询沿用现有返回格式，空槽仍显示为 (0, 0)。
    fun version_fields(version: &Option<PowerVersion>): (u64, u64) {
        if (version.is_none()) return (0, 0);
        let version = version.borrow();
        (version.effective_period, version.power)
    }

    /// 按旧规则逐算力周期计算原始算力的衰减，每步先以 u128 相乘，再除以 10000 向下取整。
    /// 不能用实数幂或仅在最后取整替代；算力为零、尚未经过算力周期或保留 100% 时可直接返回。
    /// 例如保留 9950 bps：1000 → 995 → 990，每期都独立取整。
    fun apply_retention(
        power: u64,
        periods_elapsed: u64,
        retention_bps_per_period: u64,
    ): u64 {
        if (power == 0 || periods_elapsed == 0 || retention_bps_per_period == BPS_DENOMINATOR) {
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

    #[test_only]
    /// 测试共用生产初始化校验，参数均由调用者显式传入。
    public fun initialize_for_test(
        framework: &signer, epoch: u64, retention_bps: u64,
        period_length: u64, operator: address,
    ) {
        initialize(framework, epoch, retention_bps, period_length, operator)
    }

    #[test_only]
    /// 仅推进一次时钟；测试调用者负责按真实提交顺序同步账本 Epoch。
    public fun commit_period_for_test() { commit_next_period_if_boundary() }

    #[test_only]
    /// 用生产标准化公式校验指定原始算力和指数的整数结果。
    public fun normalize_units_for_test(raw_power: u64, index: u128): u128 {
        normalized_version(0, raw_power, index).units
    }

}
