/// 保存标准化算力分配与池级奖励账本；委员会资格和奖励铸造由 stake 负责。
/// 算力版本与 Epoch 由框架内部传入；本模块不从原生本金推导算力，也不反查重配置模块。
module topo_framework::poc_accounting {
    use std::error;
    use std::option::{Self, Option};
    use std::signer;
    use std::vector;
    use topo_std::table::{Self, Table};
    use topo_framework::coin::{Self, Coin};
    use topo_framework::event;
    use topo_framework::reconfiguration_state;
    use topo_framework::system_addresses;
    use topo_framework::topo_coin::TopoCoin;

    friend topo_framework::stake;
    friend topo_framework::poc_power_store;
    friend topo_framework::poc_allocation;

    // 分配比例使用万分比；标准化 units 的缩放因子为 2^32，共同衰减指数的缩放因子为 2^64。
    const BPS_DENOMINATOR: u64 = 10000;
    /// 1 OHMP = 100,000,000 个整数 power；保证金比例按 Octa / OHMP 配置。
    const POWER_PER_OHMP: u64 = 100000000;
    const UNIT_SCALE: u128 = 4294967296;
    const INDEX_SCALE: u128 = 18446744073709551616;
    const MIN_PERIOD_INDEX: u128 = 1099511627776;
    const MAX_POOL_UNITS: u128 = 1329227995784915872903807060280344576;
    // 用户权益采用 2^128 精度，常量必须直接存为 u256。
    const Q: u256 = 340282366920938463463374607431768211456;
    const MAX_U64: u256 = 18446744073709551615;
    const MAX_VALIDATOR_SET_SIZE: u64 = 65536;
    const CONTROLLED: u8 = 0;
    const OPEN: u8 = 1;

    const ENOT_PREPARED: u64 = 1;
    const EINVALID_ALLOCATION: u64 = 2;
    const EDUPLICATE_POOL: u64 = 3;
    const EALLOCATION_LIMIT: u64 = 4;
    const EPOOL_NOT_ENABLED: u64 = 5;
    const EINVALID_TARGET_EPOCH: u64 = 6;
    const EINVALID_PARAM_COMBINATION: u64 = 7;
    const EPOOL_CAPACITY: u64 = 8;
    const EPOWER_HORIZON: u64 = 9;
    const EREWARD_HORIZON: u64 = 10;
    const ERECONFIGURATION_IN_PROGRESS: u64 = 11;
    const ECHECKPOINT_MISSING: u64 = 12;
    const EREWARD_ALREADY_CREDITED: u64 = 13;
    const EVAULT_INVARIANT: u64 = 14;
    const EACCOUNTING_INVARIANT: u64 = 15;
    const EALREADY_PREPARED: u64 = 16;
    const EINVALID_REWARD_CONFIG: u64 = 17;

    /// 可排期更新的选举参数；保证金比例使用 Octa / OHMP，权重门槛使用整数 power。
    struct PowerParams has copy, drop, store {
        /// 每 1 OHMP 算力所需的保证金 Octa 数，必须为正。
        bond_octa_per_ohmp: u64,
        min_power: u64,
        max_power: u64,
        min_validators: u64,
    }

    /// 准备时固定的部署上限，用于限制数值范围、本版奖励支持期限和单次事务的读写规模。
    struct DeploymentLimits has copy, drop, store {
        max_allocations: u64,
        max_claim_pools: u64,
        max_upload_users: u64,
        validator_limit: u64,
        max_reward_base_octa: u64,
        rate_max_num: u64,
        rate_max_den: u64,
        fee_max: u64,
        reward_epoch_limit: u64,
    }

    struct PendingPowerParams has copy, drop, store {
        epoch: u64,
        params: PowerParams,
    }

    struct PoCConfig has store {
        params: PowerParams,
        pending_params: Option<PendingPowerParams>,
        activation_epoch: u64,
        first_poc_epoch: Option<u64>, // 首次成功安装 PoC Epoch 时确定，后续调参不能重置奖励支持期限。
        deployment_mode: u8,
        limits: DeploymentLimits,
    }

    /// 全局 epoch 与已安装的链 Epoch 一致；池可在访问时推进，但用户访问不能提前应用下一 Epoch 的变化。
    struct AccountingState has key {
        epoch: u64,
        pools: Table<address, PoolLedger>,
        config: PoCConfig,
    }

    /// 当前与待生效配置的池并集有界；positions 保留历史持仓，换届和上报均不全表扫描。
    struct UserAllocation has key {
        active: vector<PoolRatio>,
        pending: Option<AllocationChange>,
        positions: Table<address, Position>,
    }

    struct PoolRatio has copy, drop, store { pool: address, bps: u64 }
    struct AllocationChange has copy, drop, store { epoch: u64, ratios: vector<PoolRatio> }
    struct Position has store {
        units: u128,
        changes: vector<PositionChange>,
        cursor: u256, // 本持仓已结算到的池奖励指数。
        accrued: u256, // Q 精度的未支付权益，包含整数金额和属于该用户的小数余量。
    }
    struct PositionChange has copy, drop, store { epoch: u64, units: u128 }
    struct PoolChange has copy, drop, store {
        epoch: u64,
        remove_units: u128,
        add_units: u128,
        refs: u64, // 此边界的持仓变化条数；池总量净变化为零时仍可能非零。
    }
    struct Checkpoint has copy, drop, store { index: u256, refs: u64 }
    struct PoolLedger has store {
        epoch: u64, // 池聚合已推进到的 Epoch，用于应用成熟变化，不用于判断奖励是否已入账。
        units: u128,
        changes: vector<PoolChange>,
        reward_base_octa: u64,
        reward_epoch: u64, // 最近已入账的奖励 Epoch；安装下一 Epoch 的计奖基数时不能提前更新。
        index: u256,
        checkpoints: Table<u64, Checkpoint>,
        vault: Coin<TopoCoin>,
    }

    /// 用宽整数暂存替换结果；旧贡献全部撤销、新贡献全部加入后，才检查各时点的最终容量。
    /// 不对中间预测值做容量检查，避免拒绝最终结果合法的两时点整体替换。
    struct PoolShadow has copy, drop {
        epoch: u64,
        remove_units: u256,
        add_units: u256,
        refs: u256,
    }

    #[event]
    struct PoCPoolEnabled has drop, store { pool: address }
    #[event]
    struct AllocationScheduled has drop, store {
        user: address,
        effective_epoch: u64,
        pools: vector<address>,
        bps: vector<u64>,
    }
    #[event]
    struct PoCRewardClaimed has drop, store { user: address, pool: address, amount: u64 }

    /// 封装治理脚本的参数输入；写入时再结合原生增长比例和部署上限验证。
    public fun new_power_params(
        bond_octa_per_ohmp: u64, min_power: u64, max_power: u64, min_validators: u64,
    ): PowerParams {
        PowerParams { bond_octa_per_ohmp, min_power, max_power, min_validators }
    }

    /// 封装显式部署清单，不在构造器中选择默认部署值。
    public fun new_deployment_limits(
        max_allocations: u64, max_claim_pools: u64,
        max_upload_users: u64, validator_limit: u64, max_reward_base_octa: u64,
        rate_max_num: u64, rate_max_den: u64, fee_max: u64, reward_epoch_limit: u64,
    ): DeploymentLimits {
        DeploymentLimits {
            max_allocations, max_claim_pools, max_upload_users,
            validator_limit, max_reward_base_octa, rate_max_num, rate_max_den,
            fee_max, reward_epoch_limit,
        }
    }

    /// 依次返回每 OHMP 所需的保证金 Octa 数、最小 power、最大 power 和最低验证者人数。
    public fun get_power_params_fields(params: &PowerParams): (u64, u64, u64, u64) {
        (params.bond_octa_per_ohmp, params.min_power, params.max_power, params.min_validators)
    }

    /// 资源存在表示已完成准备；首次 PoC 安装另由 first_poc_epoch 标记。
    #[view]
    public fun is_prepared(): bool { exists<AccountingState>(@topo_framework) }

    /// 可能改变换届目标的外部入口共用此冻结检查；内部提交和历史领奖由各自入口控制。
    public fun assert_not_frozen() {
        assert!(!reconfiguration_state::is_in_progress(), error::invalid_state(ERECONFIGURATION_IN_PROGRESS));
    }

    /// 返回账本已安装的绝对 Epoch；准备前没有可用的账本时钟。
    #[view]
    public fun current_epoch(): u64 {
        assert!(is_prepared(), error::invalid_state(ENOT_PREPARED));
        borrow_global<AccountingState>(@topo_framework).epoch
    }

    /// 返回每 1 OHMP 对应的整数 power 数，供保证金与奖励金额换算。
    public fun power_per_ohmp(): u64 { POWER_PER_OHMP }
    /// 返回部署实际支持的候选容量 V_LIMIT。
    public fun validator_limit(): u64 {
        borrow_global<AccountingState>(@topo_framework).config.limits.validator_limit
    }
    /// 返回单批上传用户数上限，供原始算力入口限制实际同步规模。
    public fun max_upload_users(): u64 {
        borrow_global<AccountingState>(@topo_framework).config.limits.max_upload_users
    }
    /// 开放部署须额外执行最低人数及最终权重集中度检查。
    public fun is_open(): bool {
        borrow_global<AccountingState>(@topo_framework).config.deployment_mode == OPEN
    }
    /// 判断池是否已获准使用 PoC 账本；这不表示它已加入委员会。
    #[view]
    public fun pool_enabled(pool: address): bool {
        is_prepared() && borrow_global<AccountingState>(@topo_framework).pools.contains(pool)
    }

    /// 返回计奖基数上限、奖励率上限的分子/分母、费用上限，以及本版支持的奖励 Epoch 数 H。
    public fun get_reward_limits(): (u64, u64, u64, u64, u64) {
        let limits = &borrow_global<AccountingState>(@topo_framework).config.limits;
        (limits.max_reward_base_octa, limits.rate_max_num, limits.rate_max_den,
            limits.fee_max, limits.reward_epoch_limit)
    }

    /// 只读选择目标 Epoch 生效的参数，不提前应用或清除待生效参数。
    public fun get_target_params(epoch: u64): PowerParams {
        let config = &borrow_global<AccountingState>(@topo_framework).config;
        if (config.pending_params.is_some()
            && config.pending_params.borrow().epoch <= epoch) {
            config.pending_params.borrow().params
        } else {
            config.params
        }
    }

    /// 首次启用前按预定时点判断；首次安装后，所有后续目标 Epoch 都保持 PoC 模式。
    public fun target_poc_enabled(epoch: u64): bool {
        if (!is_prepared()) return false;
        let config = &borrow_global<AccountingState>(@topo_framework).config;
        config.first_poc_epoch.is_some() || epoch >= config.activation_epoch
    }

    /// 检查 F <= epoch < F+H；首份预览以拟安装 Epoch 作为 F，但不写入状态。
    public fun reward_epoch_supported(epoch: u64): bool {
        let config = &borrow_global<AccountingState>(@topo_framework).config;
        let first = if (config.first_poc_epoch.is_some()) {
            *config.first_poc_epoch.borrow()
        } else { epoch };
        let end = (first as u256) + (config.limits.reward_epoch_limit as u256);
        end <= MAX_U64 && epoch >= first && (epoch as u256) < end
    }

    /// 返回已安装 Epoch、激活时点、首次 PoC Epoch、模式、当前/待生效参数及固定上限。
    #[view]
    public fun get_config(): (
        u64, u64, Option<u64>, u8, PowerParams, Option<PendingPowerParams>, DeploymentLimits,
    ) {
        let state = borrow_global<AccountingState>(@topo_framework);
        let config = &state.config;
        (state.epoch, config.activation_epoch, config.first_poc_epoch,
            config.deployment_mode, config.params, config.pending_params, config.limits)
    }

    /// 以 u256 验证 H * R_MAX <= u64::MAX，限制单池在本版奖励支持期限内的累计入账与金库余额。
    fun validate_limits(limits: &DeploymentLimits) {
        assert!(limits.max_allocations > 0
            && (limits.max_allocations as u256) * 2 <= MAX_U64
            && limits.max_claim_pools > 0 && limits.max_upload_users > 0
            && limits.validator_limit > 0 && limits.validator_limit <= MAX_VALIDATOR_SET_SIZE
            && limits.rate_max_den > 0 && limits.reward_epoch_limit > 0,
            error::invalid_argument(EINVALID_PARAM_COMBINATION));
        let reward_max = (limits.max_reward_base_octa as u256) * (limits.rate_max_num as u256)
            / (limits.rate_max_den as u256) + (limits.fee_max as u256);
        assert!((limits.reward_epoch_limit as u256) * reward_max <= MAX_U64,
            error::invalid_argument(EREWARD_HORIZON));
    }

    /// 联合验证资格、担保和增长预算；动态换员必须留出一个替补名额及足够增长预算。
    fun validate_params(
        params: &PowerParams, limits: &DeploymentLimits, mode: u8,
        increase_limit: u64, dynamic_membership: bool,
    ) {
        assert!((mode == CONTROLLED || mode == OPEN)
            && params.bond_octa_per_ohmp > 0 && params.min_power > 0
            && params.min_power <= params.max_power && params.min_validators > 0
            && params.min_validators <= limits.validator_limit
            && increase_limit > 0 && increase_limit <= 50,
            error::invalid_argument(EINVALID_PARAM_COMBINATION));
        // DKG 的保守总权重约束使用协议人数上限，不能用较小的部署容量替代。
        assert!((MAX_VALIDATOR_SET_SIZE as u256) * (params.max_power as u256) <= MAX_U64,
            error::invalid_argument(EINVALID_PARAM_COMBINATION));
        assert!((params.max_power as u256) * (params.bond_octa_per_ohmp as u256)
            / (POWER_PER_OHMP as u256) <= (limits.max_reward_base_octa as u256),
            error::invalid_argument(EINVALID_PARAM_COMBINATION));
        if (dynamic_membership) {
            assert!(params.min_validators < limits.validator_limit
                && (params.min_validators as u256) * (params.min_power as u256)
                    * (increase_limit as u256) / 100 >= (params.min_power as u256),
                error::invalid_argument(EINVALID_PARAM_COMBINATION));
        };
        assert!(mode != OPEN || params.min_validators >= 4,
            error::invalid_argument(EINVALID_PARAM_COMBINATION));
    }

    /// 将待校验的 PoC 参数与调用者提供的原生配置组合验证。
    public fun validate_config(
        params: &PowerParams, increase_limit: u64, dynamic_membership: bool,
    ) {
        let config = &borrow_global<AccountingState>(@topo_framework).config;
        validate_params(params, &config.limits, config.deployment_mode, increase_limit, dynamic_membership);
    }

    /// 原生配置更新须同时兼容当前和待生效 PoC 参数；准备前保留原生校验路径。
    public fun validate_native_config(increase_limit: u64, dynamic_membership: bool) {
        if (!is_prepared()) return;
        let config = &borrow_global<AccountingState>(@topo_framework).config;
        validate_params(&config.params, &config.limits, config.deployment_mode, increase_limit, dynamic_membership);
        if (config.pending_params.is_some()) {
            validate_params(&config.pending_params.borrow().params, &config.limits,
                config.deployment_mode, increase_limit, dynamic_membership);
        };
    }

    /// 准备后用交叉相乘检查有理数奖励率上限，避免先除法取整放宽上限。
    public fun validate_reward_rate(num: u64, den: u64) {
        if (!is_prepared()) return;
        let limits = &borrow_global<AccountingState>(@topo_framework).config.limits;
        assert!(den > 0 && (num as u256) * (limits.rate_max_den as u256)
            <= (limits.rate_max_num as u256) * (den as u256),
            error::invalid_argument(EINVALID_REWARD_CONFIG));
    }

    /// 准备后限制每池每 Epoch 的允许分发额，金额使用代币最小单位。
    public fun validate_fee_limit(value: u64) {
        if (!is_prepared()) return;
        assert!(value <= borrow_global<AccountingState>(@topo_framework).config.limits.fee_max,
            error::invalid_argument(EINVALID_REWARD_CONFIG));
    }

    /// 按 raw / 2^64 解释定点奖励率，并与部署上限精确比较。
    public fun validate_fixed_reward_rate(raw: u128) {
        if (!is_prepared()) return;
        let limits = &borrow_global<AccountingState>(@topo_framework).config.limits;
        assert!((raw as u256) * (limits.rate_max_den as u256)
            <= (limits.rate_max_num as u256) * (INDEX_SCALE as u256),
            error::invalid_argument(EINVALID_REWARD_CONFIG));
    }

    /// 安装计奖上下文前，同时验证奖励率与费用分发上限。
    public fun validate_reward_config(num: u64, den: u64, fee_limit: u64) {
        validate_reward_rate(num, den);
        validate_fee_limit(fee_limit);
    }

    /// 由框架内部传入当前链 Epoch，建立全局账本；准备时不扫描用户，也不自动分配算力。
    friend fun prepare(
        framework: &signer, epoch: u64, activation_epoch: u64, params: PowerParams,
        limits: DeploymentLimits, deployment_mode: u8, increase_limit: u64, dynamic_membership: bool,
    ) {
        system_addresses::assert_topo_framework(framework);
        assert_not_frozen();
        assert!(reconfiguration_state::is_initialized(), error::invalid_state(ENOT_PREPARED));
        assert!(!is_prepared(), error::already_exists(EALREADY_PREPARED));
        validate_limits(&limits);
        validate_params(&params, &limits, deployment_mode, increase_limit, dynamic_membership);
        assert!(activation_epoch > epoch && (activation_epoch as u256)
            + (limits.reward_epoch_limit as u256) <= MAX_U64,
            error::invalid_argument(EINVALID_TARGET_EPOCH));
        move_to(framework, AccountingState {
            epoch, pools: table::new(), config: PoCConfig {
                params, pending_params: option::none(), activation_epoch,
                first_poc_epoch: option::none(), deployment_mode, limits,
            },
        });
    }

    /// 校验当前、待生效及新参数的组合后，替换唯一一份待生效参数；生效时点须晚于当前 Epoch。
    friend fun schedule_power_params(
        framework: &signer, params: PowerParams, epoch: u64,
        increase_limit: u64, dynamic_membership: bool,
    ) {
        system_addresses::assert_topo_framework(framework);
        assert_not_frozen();
        assert!(epoch > current_epoch(), error::invalid_argument(EINVALID_TARGET_EPOCH));
        validate_native_config(increase_limit, dynamic_membership);
        validate_config(&params, increase_limit, dynamic_membership);
        borrow_global_mut<AccountingState>(@topo_framework).config.pending_params =
            option::some(PendingPowerParams { epoch, params });
    }

    /// 撤销待生效参数，已安装参数保持不变。
    friend fun cancel_pending_power_params(framework: &signer) {
        system_addresses::assert_topo_framework(framework);
        assert_not_frozen();
        borrow_global_mut<AccountingState>(@topo_framework).config.pending_params = option::none();
    }

    /// 仅在首次安装前调整启用时点；标准化基线与已准备的持仓保持原值。
    friend fun reschedule_activation(framework: &signer, epoch: u64) {
        system_addresses::assert_topo_framework(framework);
        assert_not_frozen();
        let state = borrow_global_mut<AccountingState>(@topo_framework);
        assert!(state.config.first_poc_epoch.is_none() && epoch > state.epoch
            && (epoch as u256) + (state.config.limits.reward_epoch_limit as u256) <= MAX_U64,
            error::invalid_argument(EINVALID_TARGET_EPOCH));
        state.config.activation_epoch = epoch;
    }

    /// 上层已验证池注册和准入权限；此处建立零余额账本，委员会申请由 stake 单独处理。
    friend fun enable_pool(framework: &signer, pool: address) {
        system_addresses::assert_topo_framework(framework);
        assert_not_frozen();
        let state = borrow_global_mut<AccountingState>(@topo_framework);
        assert!(!state.pools.contains(pool), error::already_exists(EPOOL_NOT_ENABLED));
        state.pools.add(pool, PoolLedger {
            epoch: state.epoch, units: 0, changes: vector[], reward_base_octa: 0,
            reward_epoch: if (state.epoch > 0) { state.epoch - 1 } else { 0 },
            index: 0, checkpoints: table::new(), vault: coin::zero<TopoCoin>(),
        });
        event::emit(PoCPoolEnabled { pool });
    }

    /// 将池 units 换算为目标算力周期的整数算力，保持 u256 类型，供后续按保证金和 max_power 限幅。
    public fun pool_power(units: u128, period_index: u128): u256 {
        assert!(units <= MAX_POOL_UNITS, error::out_of_range(EPOOL_CAPACITY));
        assert!(period_index >= MIN_PERIOD_INDEX && period_index <= INDEX_SCALE,
            error::invalid_argument(EPOWER_HORIZON));
        (units as u256) * (period_index as u256) / ((UNIT_SCALE as u256) * (INDEX_SCALE as u256))
    }

    /// 按已校验的万分比分配标准化版本，单个持仓独立向下取整。
    fun allocated_units(version_units: u128, bps: u64): u128 {
        let units = (version_units as u256) * (bps as u256) / (BPS_DENOMINATOR as u256);
        assert!(units <= (MAX_POOL_UNITS as u256), error::out_of_range(EPOOL_CAPACITY));
        units as u128
    }

    /// 只读预览指定池的目标 units，不推进账本或创建检查点。
    #[view]
    public fun preview_pool_units(pool: address, epoch: u64): u128 {
        let ledger = borrow_global<AccountingState>(@topo_framework).pools.borrow(pool);
        preview_units(ledger, epoch)
    }

    /// 从已记录的聚合量和最多两条变化推算目标总量，逐步检查聚合数据是否一致。
    fun preview_units(ledger: &PoolLedger, epoch: u64): u128 {
        assert!(epoch >= ledger.epoch, error::invalid_argument(EINVALID_TARGET_EPOCH));
        let units = ledger.units as u256;
        let i = 0;
        while (i < ledger.changes.length()) {
            let change = ledger.changes.borrow(i);
            if (change.epoch <= epoch) {
                assert!((change.remove_units as u256) <= units, error::invalid_state(EACCOUNTING_INVARIANT));
                units = units - (change.remove_units as u256) + (change.add_units as u256);
                assert!(units <= (MAX_POOL_UNITS as u256), error::invalid_state(EACCOUNTING_INVARIANT));
            };
            i += 1;
        };
        units as u128
    }

    /// 应用成熟聚合变化；调用者限定可推进的 Epoch，奖励指数在此期间保持不变。
    fun advance_pool(ledger: &mut PoolLedger, epoch: u64) {
        assert!(epoch >= ledger.epoch, error::invalid_state(EINVALID_TARGET_EPOCH));
        while ({
            spec {
                invariant ledger.units <= MAX_POOL_UNITS;
                invariant len(ledger.changes) <= 2;
                invariant len(ledger.changes) == 2 ==>
                    ledger.changes[0].epoch < ledger.changes[1].epoch;
                invariant forall i in 0..len(ledger.changes):
                    ledger.changes[i].epoch > ledger.epoch && ledger.changes[i].refs > 0;
                invariant ledger.epoch == old(ledger.epoch);
                invariant ledger.reward_epoch == old(ledger.reward_epoch);
                invariant ledger.reward_base_octa == old(ledger.reward_base_octa);
                invariant ledger.index == old(ledger.index);
                invariant ledger.vault == old(ledger.vault);
            };
            !ledger.changes.is_empty() && ledger.changes.borrow(0).epoch <= epoch
        }) {
            let change = ledger.changes.remove(0);
            assert!(change.refs > 0 && !ledger.checkpoints.contains(change.epoch),
                error::invalid_state(EACCOUNTING_INVARIANT));
            // 先保存边界前的计奖指数，再改变总量；净变化为零也要为引用保留检查点。
            ledger.checkpoints.add(change.epoch, Checkpoint { index: ledger.index, refs: change.refs });
            assert!(change.remove_units <= ledger.units, error::invalid_state(EACCOUNTING_INVARIANT));
            let units = (ledger.units as u256) - (change.remove_units as u256) + (change.add_units as u256);
            assert!(units <= (MAX_POOL_UNITS as u256), error::invalid_state(EACCOUNTING_INVARIANT));
            ledger.units = units as u128;
        };
        ledger.epoch = epoch;
    }

    /// 结算与只读查询共用同一段权益计算；指数不能回退，乘加溢出仍直接中止。
    /// 不在分段时取整，用户的小数权益一直保留到领取时。
    fun accrued_at(units: u128, cursor: u256, accrued: u256, index: u256): u256 {
        assert!(index >= cursor, error::invalid_state(EACCOUNTING_INVARIANT));
        accrued + (units as u256) * (index - cursor)
    }

    /// 池须先推进到同一 Epoch；按检查点分段累计权益，普通结算不取整支付。
    fun settle_position(position: &mut Position, ledger: &mut PoolLedger, epoch: u64) {
        assert!(ledger.epoch == epoch, error::invalid_state(EACCOUNTING_INVARIANT));
        while ({
            spec { invariant ledger.epoch == old(ledger.epoch); };
            !position.changes.is_empty() && position.changes.borrow(0).epoch <= epoch
        }) {
            let change = position.changes.remove(0);
            assert!(ledger.checkpoints.contains(change.epoch), error::invalid_state(ECHECKPOINT_MISSING));
            let checkpoint = ledger.checkpoints.borrow_mut(change.epoch);
            assert!(checkpoint.refs > 0, error::invalid_state(EACCOUNTING_INVARIANT));
            // 每段持仓 units 不超过计奖时的池总量，累计权益受累计入账 * Q 约束。
            position.accrued = accrued_at(position.units, position.cursor, position.accrued, checkpoint.index);
            position.units = change.units;
            position.cursor = checkpoint.index;
            // 一个持仓消费一个引用；最后一个引用释放后才删除历史检查点。
            checkpoint.refs -= 1;
            if (checkpoint.refs == 0) { ledger.checkpoints.remove(change.epoch); };
        };
        position.accrued = accrued_at(position.units, position.cursor, position.accrued, ledger.index);
        position.cursor = ledger.index;
    }

    /// 按首次出现顺序去重，避免同一池被重复撤销或结算。
    fun add_pool(pools: &mut vector<address>, pool: address) {
        if (!pools.contains(&pool)) pools.push_back(pool);
    }

    /// 收集当前与待生效配置涉及的池；历史 positions 不参与未来版本同步的遍历。
    fun allocation_pools(allocation: &UserAllocation): vector<address> {
        let pools = vector[];
        add_ratio_pools(&mut pools, &allocation.active);
        if (allocation.pending.is_some()) {
            add_ratio_pools(&mut pools, &allocation.pending.borrow().ratios);
        };
        pools
    }

    /// 将比例列表涉及的地址并入有界访问集合。
    fun add_ratio_pools(pools: &mut vector<address>, ratios: &vector<PoolRatio>) {
        let i = 0;
        while (i < ratios.length()) {
            add_pool(pools, ratios.borrow(i).pool);
            i += 1;
        };
    }

    /// 将已生效配置移入 active，以当前 Epoch 的有效配置为基准执行替换。
    fun promote_allocation(allocation: &mut UserAllocation, epoch: u64) {
        if (allocation.pending.is_some() && allocation.pending.borrow().epoch <= epoch) {
            allocation.active = allocation.pending.extract().ratios;
        };
    }

    /// 读取指定时点有效的比例；未列出的池按零比例撤出。
    fun ratio_at(allocation: &UserAllocation, pool: address, epoch: u64): u64 {
        let ratios = if (allocation.pending.is_some() && allocation.pending.borrow().epoch <= epoch) {
            &allocation.pending.borrow().ratios
        } else { &allocation.active };
        let i = 0;
        while (i < ratios.length()) {
            let ratio = ratios.borrow(i);
            if (ratio.pool == pool) return ratio.bps;
            i += 1;
        };
        0
    }

    /// 用户本人签名设置下一 Epoch 的分配；版本 units 和下一算力周期的边界由框架内部读取。
    friend fun replace_allocation(
        user: &signer, pools: vector<address>, bps: vector<u64>,
        current_units: u128, next_units: u128, boundary_epoch: u64,
    ) {
        assert_not_frozen();
        let epoch = current_epoch();
        assert!((epoch as u256) < MAX_U64 && pools.length() == bps.length(),
            error::invalid_argument(EINVALID_ALLOCATION));
        let limit = borrow_global<AccountingState>(@topo_framework).config.limits.max_allocations;
        assert!(pools.length() <= limit, error::out_of_range(EALLOCATION_LIMIT));
        let ratios = vector[];
        let seen = vector[];
        let sum = 0u256;
        let i = 0;
        while (i < pools.length()) {
            let pool = *pools.borrow(i);
            let ratio = *bps.borrow(i);
            assert!(!seen.contains(&pool), error::invalid_argument(EDUPLICATE_POOL));
            assert!(pool_enabled(pool), error::invalid_argument(EPOOL_NOT_ENABLED));
            assert!(ratio > 0, error::invalid_argument(EINVALID_ALLOCATION));
            sum += (ratio as u256);
            ratios.push_back(PoolRatio { pool, bps: ratio });
            seen.push_back(pool);
            i += 1;
        };
        assert!(sum <= (BPS_DENOMINATOR as u256), error::invalid_argument(EINVALID_ALLOCATION));
        let owner = signer::address_of(user);
        if (!exists<UserAllocation>(owner)) {
            move_to(user, UserAllocation { active: vector[], pending: option::none(), positions: table::new() });
        };
        rebuild_user(owner, option::some(ratios), current_units, next_units, boundary_epoch);
        event::emit(AllocationScheduled { user: owner, effective_epoch: epoch + 1, pools, bps });
    }

    /// 新增原始版本时仅更新已有分配，上传入口不能代替用户创建分配资源。
    friend fun sync_power_versions(
        user: address, current_units: u128, next_units: u128, boundary_epoch: u64,
    ) {
        assert_not_frozen();
        if (exists<UserAllocation>(user)) {
            rebuild_user(user, option::none(), current_units, next_units, boundary_epoch);
        };
    }

    /// 分配替换与版本新增共用重建核心，最多访问 2K 个池，其中 K 为 max_allocations。
    /// 任一池失败时，整笔 Move 事务回滚配置、持仓、聚合和已产生的事件。
    fun rebuild_user(
        user: address, new_ratios: Option<vector<PoolRatio>>, current_units: u128,
        next_units: u128, boundary_epoch: u64,
    ) {
        let state = borrow_global_mut<AccountingState>(@topo_framework);
        let epoch = state.epoch;
        assert!((epoch as u256) < MAX_U64 && boundary_epoch > epoch,
            error::invalid_argument(EINVALID_TARGET_EPOCH));
        assert!(current_units < MAX_POOL_UNITS && next_units < MAX_POOL_UNITS,
            error::out_of_range(EPOOL_CAPACITY));
        let allocation = borrow_global_mut<UserAllocation>(user);
        // 提升配置前保留旧 active 地址，避免漏掉已成熟但尚未结算的撤出持仓。
        let visit = allocation_pools(allocation);
        promote_allocation(allocation, epoch);
        if (new_ratios.is_some()) {
            allocation.pending = option::some(AllocationChange { epoch: epoch + 1, ratios: new_ratios.extract() });
        };
        let new_pools = allocation_pools(allocation);
        assert!(new_pools.length() <= state.config.limits.max_allocations, error::out_of_range(EALLOCATION_LIMIT));
        let i = 0;
        while (i < new_pools.length()) {
            add_pool(&mut visit, *new_pools.borrow(i));
            i += 1;
        };
        assert!(visit.length() <= 2 * state.config.limits.max_allocations, error::invalid_state(EACCOUNTING_INVARIANT));
        let i = 0;
        while ({
            spec {
                invariant state.epoch == epoch;
                invariant state.config == old(global<AccountingState>(@topo_framework).config);
            };
            i < visit.length()
        }) {
            let pool = *visit.borrow(i);
            rebuild_user_pool(state, allocation, pool, current_units, next_units, boundary_epoch);
            i += 1;
        };
    }

    /// 每个池先结算已有持仓的权益，再替换尚未生效的变化；完成后释放两个 Table 的嵌套借用。
    fun rebuild_user_pool(
        state: &mut AccountingState, allocation: &mut UserAllocation, pool: address,
        current_units: u128, next_units: u128, boundary_epoch: u64,
    ) {
        let epoch = state.epoch;
        // E 是当前 Epoch，B 是下一算力周期开始的 Epoch。
        // E+1 == B 时直接使用新版本和新比例，形成一个最终值。
        let first_units = allocated_units(
            if (epoch + 1 == boundary_epoch) { next_units } else { current_units },
            ratio_at(allocation, pool, epoch + 1),
        );
        let boundary_units = allocated_units(next_units, ratio_at(allocation, pool, boundary_epoch));
        let ledger = state.pools.borrow_mut(pool);
        advance_pool(ledger, epoch);
        if (!allocation.positions.contains(pool)) {
            allocation.positions.add(pool, Position {
                units: 0, changes: vector[], cursor: ledger.index, accrued: 0,
            });
        };
        let position = allocation.positions.borrow_mut(pool);
        settle_position(position, ledger, epoch);
        rebuild_position(position, ledger, epoch + 1, boundary_epoch, first_units, boundary_units);
    }

    /// 复用同一时点的宽整数聚合记录，插入时保持 Epoch 升序。
    fun shadow_at(shadows: &mut vector<PoolShadow>, epoch: u64): &mut PoolShadow {
        let i = 0;
        while ({
            spec {
                invariant i <= len(shadows);
                invariant forall j in 0..i: shadows[j].epoch < epoch;
            };
            i < shadows.length() && shadows.borrow(i).epoch < epoch
        }) { i += 1; };
        if (i == shadows.length() || shadows.borrow(i).epoch != epoch) {
            shadows.insert(i, PoolShadow { epoch, remove_units: 0, add_units: 0, refs: 0 });
        };
        shadows.borrow_mut(i)
    }

    /// 先完整撤销旧贡献，再加入新的两时点变化，最后统一验证容量并写回。
    fun rebuild_position(
        position: &mut Position, ledger: &mut PoolLedger, next_epoch: u64,
        boundary_epoch: u64, first_units: u128, boundary_units: u128,
    ) {
        let shadows = vector[];
        let i = 0;
        while ({
            spec {
                invariant i <= len(ledger.changes);
                invariant len(shadows) == i;
                invariant forall j in 0..i: shadows[j].epoch == ledger.changes[j].epoch;
                invariant sorted_shadows(shadows);
            };
            i < ledger.changes.length()
        }) {
            let change = ledger.changes.borrow(i);
            shadows.push_back(PoolShadow {
                epoch: change.epoch, remove_units: change.remove_units as u256,
                add_units: change.add_units as u256, refs: change.refs as u256,
            });
            i += 1;
        };
        // 沿旧链逐段撤销 remove/add/refs；每段起点取上一段终值，不能都用当前 units。
        let previous = position.units;
        let i = 0;
        while ({
            spec { invariant sorted_shadows(shadows); };
            i < position.changes.length()
        }) {
            let change = position.changes.borrow(i);
            let shadow = shadow_at(&mut shadows, change.epoch);
            assert!(shadow.remove_units >= (previous as u256) && shadow.add_units >= (change.units as u256)
                && shadow.refs > 0, error::invalid_state(EACCOUNTING_INVARIANT));
            shadow.remove_units -= (previous as u256);
            shadow.add_units -= (change.units as u256);
            shadow.refs -= 1;
            previous = change.units;
            i += 1;
        };
        // 重合时点只保留一次计算；append 会省略前后 units 相等的无效变化。
        let changes = vector[];
        append_position_change(&mut changes, &mut shadows, next_epoch, position.units, first_units);
        if (boundary_epoch != next_epoch) {
            append_position_change(&mut changes, &mut shadows, boundary_epoch, first_units, boundary_units);
        };
        // 至此撤销与新增已全部汇总，才按最终时间链检查每个边界的池容量。
        let pool_changes = vector[];
        let units = ledger.units as u256;
        let i = 0;
        while ({
            spec {
                invariant i <= len(shadows);
                invariant units <= MAX_POOL_UNITS;
                invariant forall j in 0..len(pool_changes):
                    pool_changes[j].epoch > ledger.epoch && pool_changes[j].refs > 0;
                invariant forall j in 0..len(pool_changes), k in 0..len(pool_changes):
                    j < k ==> pool_changes[j].epoch < pool_changes[k].epoch;
                invariant forall j in 0..len(pool_changes), k in i..len(shadows):
                    pool_changes[j].epoch < shadows[k].epoch;
            };
            i < shadows.length()
        }) {
            let shadow = shadows.borrow(i);
            if (shadow.refs == 0) {
                // 只有所有持仓引用都撤销后才可删除；净变化为零但仍有引用的记录必须保留。
                assert!(shadow.remove_units == 0 && shadow.add_units == 0, error::invalid_state(EACCOUNTING_INVARIANT));
            } else {
                assert!((shadow.epoch == next_epoch || shadow.epoch == boundary_epoch)
                    && shadow.refs <= MAX_U64 && shadow.remove_units <= (MAX_POOL_UNITS as u256)
                    && shadow.add_units <= (MAX_POOL_UNITS as u256), error::out_of_range(EPOOL_CAPACITY));
                assert!(shadow.remove_units <= units, error::invalid_state(EACCOUNTING_INVARIANT));
                units = units - shadow.remove_units + shadow.add_units;
                assert!(units <= (MAX_POOL_UNITS as u256), error::out_of_range(EPOOL_CAPACITY));
                pool_changes.push_back(PoolChange {
                    epoch: shadow.epoch, remove_units: shadow.remove_units as u128,
                    add_units: shadow.add_units as u128, refs: shadow.refs as u64,
                });
            };
            i += 1;
        };
        assert!(pool_changes.length() <= 2 && changes.length() <= 2, error::invalid_state(EACCOUNTING_INVARIANT));
        ledger.changes = pool_changes;
        position.changes = changes;
    }

    /// 仅实际 units 改变才增加持仓变化和引用，避免比例改动但权益不变时留下空检查点。
    fun append_position_change(
        changes: &mut vector<PositionChange>, shadows: &mut vector<PoolShadow>,
        epoch: u64, previous: u128, units: u128,
    ) {
        if (previous == units) return;
        changes.push_back(PositionChange { epoch, units });
        let shadow = shadow_at(shadows, epoch);
        shadow.remove_units += (previous as u256);
        shadow.add_units += (units as u256);
        shadow.refs += 1;
    }

    /// 返回当前安装的池级计奖基数，单位为 Octa。
    #[view]
    public fun pool_reward_base_octa(pool: address): u64 {
        borrow_global<AccountingState>(@topo_framework).pools.borrow(pool).reward_base_octa
    }

    /// 仅供框架内部结算奖励：stake 核验旧 Epoch 的成员、权重和计奖上下文后，传入奖励币。
    /// 通胀与允许分发的费用进入池金库，本接口返回本次累计奖励指数的增量。
    friend fun credit_epoch_reward(pool: address, epoch: u64, reward: Coin<TopoCoin>): u256 {
        assert!(reward_epoch_supported(epoch), error::invalid_state(EREWARD_HORIZON));
        let state = borrow_global_mut<AccountingState>(@topo_framework);
        assert!(state.epoch == epoch && state.config.first_poc_epoch.is_some(),
            error::invalid_state(EINVALID_TARGET_EPOCH));
        let limits = &state.config.limits;
        let amount = coin::value(&reward);
        let reward_max = (limits.max_reward_base_octa as u256) * (limits.rate_max_num as u256)
            / (limits.rate_max_den as u256) + (limits.fee_max as u256);
        assert!((amount as u256) <= reward_max, error::invalid_state(EVAULT_INVARIANT));
        let ledger = state.pools.borrow_mut(pool);
        assert!(ledger.epoch == epoch, error::invalid_state(EACCOUNTING_INVARIANT));
        assert!(ledger.reward_epoch < epoch, error::invalid_state(EREWARD_ALREADY_CREDITED));
        // 每个 Epoch 的奖励独立向下取整；池级余数留在金库，不计入下一 Epoch 的奖励指数增量。
        let delta = if (ledger.units == 0) {
            assert!(amount == 0, error::invalid_state(EVAULT_INVARIANT));
            0
        } else { (amount as u256) * Q / (ledger.units as u256) };
        // H * R_MAX <= u64::MAX，且每个 Epoch 仅入账一次。
        // 因此本版奖励支持期限内的累计指数和权益均小于 2^192。
        ledger.index += delta;
        coin::merge(&mut ledger.vault, reward);
        // 奖励为零也要记录已入账的 Epoch，防止重复结算。
        ledger.reward_epoch = epoch;
        delta
    }

    /// 结算旧 Epoch 奖励后，应用下一 Epoch 的聚合变化，并核对冻结计划中的 units。
    /// 安装计奖基数不代表已结算该 Epoch 的奖励，因此不能更新 reward_epoch。
    friend fun install_pool_target(
        pool: address, epoch: u64, units: u128, reward_base_octa: u64,
    ) {
        let state = borrow_global_mut<AccountingState>(@topo_framework);
        assert!((epoch as u256) == (state.epoch as u256) + 1,
            error::invalid_state(EINVALID_TARGET_EPOCH));
        assert!(reward_base_octa <= state.config.limits.max_reward_base_octa, error::invalid_state(EVAULT_INVARIANT));
        let ledger = state.pools.borrow_mut(pool);
        advance_pool(ledger, epoch);
        assert!(ledger.units == units, error::invalid_state(EACCOUNTING_INVARIANT));
        ledger.reward_base_octa = reward_base_octa;
    }

    /// 成功提交时推进一次全局 Epoch、应用到期参数，并在首次 PoC 安装时固定奖励期限起点。
    friend fun advance_epoch(epoch: u64, poc_enabled: bool) {
        assert!(poc_enabled == target_poc_enabled(epoch), error::invalid_state(EINVALID_TARGET_EPOCH));
        if (poc_enabled) assert!(reward_epoch_supported(epoch), error::invalid_state(EREWARD_HORIZON));
        let state = borrow_global_mut<AccountingState>(@topo_framework);
        assert!((epoch as u256) == (state.epoch as u256) + 1, error::invalid_state(EINVALID_TARGET_EPOCH));
        if (state.config.pending_params.is_some()
            && state.config.pending_params.borrow().epoch <= epoch) {
            state.config.params = state.config.pending_params.extract().params;
        };
        if (poc_enabled && state.config.first_poc_epoch.is_none()) {
            state.config.first_poc_epoch = option::some(epoch);
        };
        state.epoch = epoch;
    }

    /// 领取本人指定历史持仓的整数奖励；冻结期间仍允许，池最多推进到已安装 Epoch。
    /// 返回合并后的奖励币，由上层存入本人账户，个人小数余量继续保留在原持仓。
    friend fun claim_rewards(user: &signer, pools: vector<address>): Coin<TopoCoin>
    {
        let owner = signer::address_of(user);
        let state = borrow_global_mut<AccountingState>(@topo_framework);
        assert!(pools.length() <= state.config.limits.max_claim_pools, error::out_of_range(EALLOCATION_LIMIT));
        let allocation = borrow_global_mut<UserAllocation>(owner);
        let result = coin::zero<TopoCoin>();
        let seen = vector[];
        let i = 0;
        while (i < pools.length()) {
            let pool = *pools.borrow(i);
            assert!(!seen.contains(&pool), error::invalid_argument(EDUPLICATE_POOL));
            seen.push_back(pool);
            let ledger = state.pools.borrow_mut(pool);
            advance_pool(ledger, state.epoch);
            let position = allocation.positions.borrow_mut(pool);
            settle_position(position, ledger, state.epoch);
            // 先用金库余额验证取整金额可存入 u64；不足额必须中止，不能清零或跳过权益。
            let amount = position.accrued / Q;
            assert!(amount <= (coin::value(&ledger.vault) as u256), error::invalid_state(EVAULT_INVARIANT));
            position.accrued %= Q;
            coin::merge(&mut result, coin::extract(&mut ledger.vault, amount as u64));
            if (amount > 0) event::emit(PoCRewardClaimed { user: owner, pool, amount: amount as u64 });
            i += 1;
        };
        result
    }

    /// 返回当前 Epoch 已生效的分配和待生效配置，查询过程不修改存储。
    #[view]
    public fun get_allocations(user: address): (vector<PoolRatio>, Option<AllocationChange>)
    {
        if (!exists<UserAllocation>(user)) return (vector[], option::none());
        let allocation = borrow_global<UserAllocation>(user);
        if (allocation.pending.is_some() && allocation.pending.borrow().epoch <= current_epoch()) {
            (allocation.pending.borrow().ratios, option::none())
        } else { (allocation.active, allocation.pending) }
    }

    /// 返回当前/下一 Epoch 的 units、已安装计奖基数、金库余额和累计奖励指数；金额使用代币最小单位。
    #[view]
    public fun get_pool(pool: address): (u128, u128, u64, u64, u256) {
        let state = borrow_global<AccountingState>(@topo_framework);
        let ledger = state.pools.borrow(pool);
        let next_epoch = (state.epoch as u256) + 1;
        assert!(next_epoch <= MAX_U64, error::out_of_range(EINVALID_TARGET_EPOCH));
        (preview_units(ledger, state.epoch), preview_units(ledger, next_epoch as u64),
            ledger.reward_base_octa, coin::value(&ledger.vault), ledger.index)
    }

    /// 只读模拟成熟变化，返回当前 units、未来变化、可领整数金额和 Q 精度的小数余量。
    /// 查询不减少检查点引用，也不推进池或更新持仓 cursor。
    #[view]
    public fun get_position(user: address, pool: address): (u128, vector<PositionChange>, u64, u256)
    {
        if (!exists<UserAllocation>(user)) return (0, vector[], 0, 0);
        let allocation = borrow_global<UserAllocation>(user);
        if (!allocation.positions.contains(pool)) return (0, vector[], 0, 0);
        let state = borrow_global<AccountingState>(@topo_framework);
        let ledger = state.pools.borrow(pool);
        let position = allocation.positions.borrow(pool);
        let units = position.units;
        let cursor = position.cursor;
        let accrued = position.accrued;
        let changes = vector[];
        let i = 0;
        while (i < position.changes.length()) {
            let change = position.changes.borrow(i);
            if (change.epoch <= state.epoch) {
                let index = if (change.epoch > ledger.epoch) {
                    // 退出池尚未推进时指数保持不变；仍须找到有效聚合引用，不能掩盖状态损坏。
                    let found = false;
                    let j = 0;
                    while (j < ledger.changes.length()) {
                        let pool_change = ledger.changes.borrow(j);
                        if (pool_change.epoch == change.epoch && pool_change.refs > 0) { found = true; };
                        j += 1;
                    };
                    assert!(found, error::invalid_state(ECHECKPOINT_MISSING));
                    ledger.index
                } else {
                    assert!(ledger.checkpoints.contains(change.epoch), error::invalid_state(ECHECKPOINT_MISSING));
                    let checkpoint = ledger.checkpoints.borrow(change.epoch);
                    assert!(checkpoint.refs > 0, error::invalid_state(EACCOUNTING_INVARIANT));
                    checkpoint.index
                };
                accrued = accrued_at(units, cursor, accrued, index);
                units = change.units;
                cursor = index;
            } else { changes.push_back(*change); };
            i += 1;
        };
        accrued = accrued_at(units, cursor, accrued, ledger.index);
        let amount = accrued / Q;
        assert!(amount <= (coin::value(&ledger.vault) as u256), error::invalid_state(EVAULT_INVARIANT));
        (units, changes, amount as u64, accrued % Q)
    }

    // 以下辅助入口仅用于测试；生产账本中的奖励和版本由框架内部接口传入。
    #[test_only]
    public fun prepare_for_test(framework: &signer, epoch: u64, activation_epoch: u64, limit: u64) {
        reconfiguration_state::initialize(framework);
        prepare(framework, epoch, activation_epoch, new_power_params(100000000, 1, 1000000, 4),
            new_deployment_limits(limit, 16, 16, 8, 1000000, 1, 1, 1000000, 10000), OPEN, 25, true);
    }

    #[test_only]
    public fun prepare_limits_for_test(
        framework: &signer, epoch: u64, activation_epoch: u64, params: PowerParams, limits: DeploymentLimits,
    ) {
        reconfiguration_state::initialize(framework);
        prepare(framework, epoch, activation_epoch, params, limits, OPEN, 25, true);
    }

    #[test_only]
    public fun enable_pool_for_test(framework: &signer, pool: address) {
        enable_pool(framework, pool);
    }

    #[test_only]
    public fun replace_for_test(
        user: &signer, pools: vector<address>, bps: vector<u64>, current_units: u128,
        next_units: u128, boundary_epoch: u64,
    ) {
        replace_allocation(user, pools, bps, current_units, next_units, boundary_epoch);
    }

    #[test_only]
    public fun sync_for_test(user: address, current_units: u128, next_units: u128, boundary_epoch: u64)
    {
        sync_power_versions(user, current_units, next_units, boundary_epoch);
    }

    #[test_only]
    public fun advance_for_test(epoch: u64, pools: vector<address>, poc: bool) {
        let i = 0;
        while (i < pools.length()) {
            let pool = *pools.borrow(i);
            install_pool_target(pool, epoch, preview_pool_units(pool, epoch), 1);
            i += 1;
        };
        advance_epoch(epoch, poc);
    }

    #[test_only]
    public fun credit_for_test(pool: address, reward: Coin<TopoCoin>): u256 {
        credit_epoch_reward(pool, current_epoch(), reward)
    }

    #[test_only]
    public fun claim_for_test(user: &signer, pools: vector<address>): Coin<TopoCoin>
    {
        claim_rewards(user, pools)
    }

    #[test_only]
    public fun checkpoint_refs_for_test(pool: address, epoch: u64): u64 {
        let checkpoints = &borrow_global<AccountingState>(@topo_framework).pools.borrow(pool).checkpoints;
        if (checkpoints.contains(epoch)) { checkpoints.borrow(epoch).refs } else { 0 }
    }

    #[test_only]
    public fun pool_changes_for_test(pool: address): vector<PoolChange> {
        borrow_global<AccountingState>(@topo_framework).pools.borrow(pool).changes
    }

    /// 仅用于验证损坏状态的精确中止行为：删除检查点或将其引用数破坏为零。
    #[test_only]
    public fun corrupt_checkpoint_for_test(pool: address, epoch: u64, remove: bool) {
        let checkpoints = &mut borrow_global_mut<AccountingState>(@topo_framework).pools.borrow_mut(pool).checkpoints;
        if (remove) {
            checkpoints.remove(epoch);
        } else {
            checkpoints.borrow_mut(epoch).refs = 0;
        };
    }

    /// 仅用于不足额金库测试，验证领取失败时不会抹去已累计权益。
    #[test_only]
    public fun drain_vault_for_test(pool: address): Coin<TopoCoin> {
        let vault = &mut borrow_global_mut<AccountingState>(@topo_framework).pools.borrow_mut(pool).vault;
        let amount = coin::value(vault);
        coin::extract(vault, amount)
    }

    /// 返回持仓变化的生效 Epoch 和目标 units。
    public fun position_change_fields(change: &PositionChange): (u64, u128) { (change.epoch, change.units) }
    #[test_only]
    /// 返回聚合变化的 Epoch、撤出 units、加入 units 和持仓引用数。
    public fun pool_change_fields(change: &PoolChange): (u64, u128, u128, u64) {
        (change.epoch, change.remove_units, change.add_units, change.refs)
    }
    /// 返回池地址与万分比分配比例。
    public fun pool_ratio_fields(ratio: &PoolRatio): (address, u64) { (ratio.pool, ratio.bps) }
    /// 返回待生效配置的绝对 Epoch 与比例列表。
    public fun allocation_change_fields(change: &AllocationChange): (u64, vector<PoolRatio>) { (change.epoch, change.ratios) }
}
