///
/// Validator lifecycle:
/// 1. Prepare a validator node set up and call stake::initialize_validator
/// 2. Once ready to deposit stake (or have funds assigned by a staking service in exchange for ownership capability),
/// call stake::add_stake (or *_with_cap versions if called from the staking service)
/// 3. Call stake::join_validator_set (or _with_cap version) to join the active validator set. Changes are effective in
/// the next epoch.
/// 4. Validate and gain rewards. The stake will automatically be locked up for a fixed duration (set by governance) and
/// automatically renewed at expiration.
/// 5. At any point, if the validator operator wants to update the consensus key or network/fullnode addresses, they can
/// call stake::rotate_consensus_key and stake::update_network_and_fullnode_addresses. Similar to changes to stake, the
/// changes to consensus key/network/fullnode addresses are only effective in the next epoch.
/// 6. Validator can request to unlock their stake at any time. However, their stake will only become withdrawable when
/// their current lockup expires. This can be at most as long as the fixed lockup duration.
/// 7. After exiting, the validator can either explicitly leave the validator set by calling stake::leave_validator_set
/// or if their stake drops below the min required, they would get removed at the end of the epoch.
/// 8. Validator can always rejoin the validator set by going through steps 2-3 again.
/// 9. An owner can always switch operators by calling stake::set_operator.
/// 10. An owner can always switch designated voter by calling stake::set_designated_voter.
module topo_framework::stake {
    use std::error;
    use std::features;
    use std::option::{Self, Option};
    use std::signer;
    use std::vector;
    use topo_std::bls12381;
    use topo_std::math64::min;
    use topo_std::big_ordered_map::{Self, BigOrderedMap};
    use topo_std::table::{Self, Table};
    use topo_framework::poc_accounting::{Self, PowerParams};
    use topo_framework::poc_power_store;
    use topo_framework::poc_reward_split;
    use topo_framework::aggregator_v2::{Self, Aggregator};
    use topo_framework::topo_coin::TopoCoin;
    use topo_framework::account;
    use topo_framework::coin::{Self, Coin, MintCapability};
    use topo_framework::event::{Self, EventHandle};
    use topo_framework::timestamp;
    use topo_framework::system_addresses;
    use topo_framework::staking_config::{Self, StakingConfig, StakingRewardsConfig};
    use topo_framework::chain_status;
    use topo_framework::create_signer;

    friend topo_framework::block;
    friend topo_framework::genesis;
    friend topo_framework::reconfiguration;
    friend topo_framework::reconfiguration_with_dkg;
    friend topo_framework::transaction_fee;
    friend topo_framework::poc_allocation;

    // 用旁路资源保存 PoC 状态，不改变已发布的质押资源和 PVS 布局。
    /// 保存当前 Epoch 的奖励配置；治理修改在下次安装上下文时生效。
    struct RewardContext has copy, drop, store {
        epoch: u64,
        poc_enabled: bool,
        rewards_rate: u64,
        rewards_rate_denominator: u64,
        distribute_transaction_fee: bool,
        fee_limit_per_pool: u64,
    }

    struct InstalledRewardContext has key { context: RewardContext }
    /// 记录当前 Epoch 的自主退出申请；治理移除的成员不能自行恢复。
    struct VoluntaryLeaves has key { requests: Table<address, u64> }

    /// units 为标准化算力单位，power 为 BFT 整数权重，reward_base_octa 为 Octa 金额。
    struct PoolTarget has copy, drop, store {
        pool: address,
        units: u128,
        power: u64,
        reward_base_octa: u64,
    }

    /// 只读预检结果，可以安全丢弃；reason == 0 表示 Ready，其余值表示延期原因。
    struct EpochPreview has copy, drop, store {
        reason: u64,
        epoch: u64,
        period: u64,
        period_index: u128,
        cutoff_secs: u64,
        poc_enabled: bool,
        params: PowerParams,
        closing_rewards: RewardContext,
        targets: vector<PoolTarget>,
        validator_set: ValidatorSet,
        is_liveness_fallback: bool,
    }

    /// 委员会和回退标记只存于 PVS；这里保存提交期间必须保持不变的其余数据。
    struct EpochPlanData has copy, drop, store {
        epoch: u64,
        period: u64,
        period_index: u128,
        cutoff_secs: u64,
        poc_enabled: bool,
        params: PowerParams,
        closing_rewards: RewardContext,
        targets: vector<PoolTarget>,
    }

    struct EpochPlan has key {
        data: EpochPlanData,
        feature_token: features::FeatureFreezeToken,
        // 0：已缓存；1：旧 Epoch 奖励已结算；2：目标已安装。仅换届提交函数推进阶段。
        stage: u8,
    }

    #[event]
    struct PoCRewardCredited has drop, store {
        pool: address,
        closing_epoch: u64,
        reward_base_octa: u64,
        inflation: u64,
        fee: u64,
        delta_index: u256,
    }

    #[event]
    /// 记录通胀总额，以及分给原生质押路径和 PoC 奖励金库的通胀金额。
    /// PoCRewardCredited 保持原有布局，继续记录 PoC 奖励金库的实际入账。
    struct PoCRewardSplit has drop, store {
        pool: address,
        closing_epoch: u64,
        native_reward_bps: u64,
        total_inflation_octa: u64,
        active_native_reward_octa: u64,
        pending_inactive_native_reward_octa: u64,
        poc_inflation_octa: u64,
    }

    #[event]
    struct PoCEpochInstalled has drop, store {
        epoch: u64, period: u64, selected_count: u64, total_power: u64,
    }

    #[event]
    struct VoluntaryLeaveCancelled has drop, store { pool: address, request_epoch: u64 }

    const EPLAN_MISMATCH: u64 = 32;
    const EPOC_NOT_PREPARED: u64 = 33;
    const EINVALID_POC_TARGET: u64 = 34;
    const ENO_VOLUNTARY_LEAVE: u64 = 35;
    const ECOUNTER_OVERFLOW: u64 = 36;
    const ENATIVE_REWARD_CAPACITY_EXCEEDED: u64 = 37;
    const INSUFFICIENT_VALIDATORS: u64 = 1;
    const ZERO_TARGET_POWER: u64 = 2;
    const CONCENTRATION_LIMIT: u64 = 3;
    const TARGET_OUT_OF_RANGE: u64 = 4;
    const ZERO_CURRENT_POWER: u64 = 5;

    #[view]
    /// 准备完成不等于已启用；当前 Epoch 仍可能使用原生权重和奖励。
    public fun is_poc_prepared(): bool { poc_accounting::is_prepared() }

    #[view]
    /// 从已安装的上下文读取当前模式，不用计划启用时间推断。
    public fun is_poc_enabled(): bool acquires InstalledRewardContext {
        if (!is_poc_prepared()) { return false };
        get_installed_reward_context().poc_enabled
    }

    /// 准备后缺少奖励上下文即为状态错误，不能用当前治理配置代替旧 Epoch 的配置。
    public fun get_installed_reward_context(): RewardContext acquires InstalledRewardContext {
        assert!(exists<InstalledRewardContext>(@topo_framework), error::invalid_state(EPOC_NOT_PREPARED));
        borrow_global<InstalledRewardContext>(@topo_framework).context
    }

    /// 返回绝对 Epoch、模式、奖励率分子和分母、费用分发开关及每池限额（代币最小单位）。
    public fun get_reward_context_fields(context: &RewardContext): (u64, bool, u64, u64, bool, u64) {
        (context.epoch, context.poc_enabled, context.rewards_rate, context.rewards_rate_denominator,
            context.distribute_transaction_fee, context.fee_limit_per_pool)
    }

    #[view]
    /// 委托入池费使用当前 Epoch 的奖励率快照；准备前直接读取原生配置。
    public fun get_installed_reward_rate(): (bool, u64, u64) acquires InstalledRewardContext {
        if (is_poc_prepared()) {
            let c = get_installed_reward_context();
            (c.poc_enabled, c.rewards_rate, c.rewards_rate_denominator)
        } else {
            let (n, d) = staking_config::get_reward_rate(&staking_config::get());
            (false, n, d)
        }
    }

    /// 治理可设置下一 Epoch 或更晚生效的原生奖励占比；覆盖待生效配置不影响当期占比。
    public entry fun schedule_reward_split(framework: &signer, native_reward_bps: u64, activation_epoch: u64) {
        poc_reward_split::schedule_change(framework, native_reward_bps, activation_epoch);
    }

    public entry fun cancel_pending_reward_split(framework: &signer) {
        poc_reward_split::cancel_pending_change(framework);
    }

    #[view]
    /// 返回当期 PoC 原生奖励占比；原生模式返回 0 表示未启用 PoC 分成，奖励仍全部按原生质押路径分发。
    public fun get_installed_native_reward_bps(): u64 {
        if (!is_poc_prepared()) { return 0 };
        poc_reward_split::get_installed_native_reward_bps(poc_accounting::current_epoch())
    }

    #[view]
    /// 依次返回当期 Epoch、当期原生奖励占比、配置占比、待生效占比及其生效 Epoch；后两项为可选值。
    public fun get_reward_split_configuration(): (u64, u64, u64, Option<u64>, Option<u64>) {
        let installed_epoch = if (is_poc_prepared()) { poc_accounting::current_epoch() } else { 0 };
        poc_reward_split::get_configuration(installed_epoch)
    }

    #[view]
    /// PoC 模式下的当期原生总收益上限：最优出块通胀与已安装费用限额分别分流后相加。
    /// 用于余额容量预留和委托入池费的保守估算；关闭费用分发时不计交易费。
    public fun get_native_reward_upper_bound(pool_address: address): u64 acquires InstalledRewardContext, ValidatorSet {
        if (!is_poc_enabled() || !poc_accounting::pool_enabled(pool_address)
            || !is_current_epoch_validator(pool_address)) { return 0 };
        let reward_context = get_installed_reward_context();
        calculate_native_reward_upper_bound(pool_address, &reward_context)
    }

    fun calculate_native_reward_upper_bound(pool_address: address, reward_context: &RewardContext): u64 {
        let inflation_upper_bound_octa = reward_amount_wide(poc_accounting::pool_reward_base_octa(pool_address), 1, 1,
            reward_context.rewards_rate, reward_context.rewards_rate_denominator);
        let native_reward_bps = poc_reward_split::get_installed_native_reward_bps(reward_context.epoch);
        let (native_inflation_upper_bound_octa, _) =
            poc_reward_split::split_inflation_reward(inflation_upper_bound_octa, native_reward_bps);
        let (native_fee_upper_bound_octa, _) = poc_reward_split::split_reward(
            if (reward_context.distribute_transaction_fee) { reward_context.fee_limit_per_pool } else { 0 },
            native_reward_bps);
        native_inflation_upper_bound_octa + native_fee_upper_bound_octa
    }

    /// 首次启用 PoC 时也为最后一期原生奖励预留容量；可分发交易费按旧期快照的费用上限计入。
    fun calculate_closing_native_reward_upper_bound(pool_address: address, closing_rewards: &RewardContext): u256 acquires StakePool {
        if (closing_rewards.poc_enabled) { return calculate_native_reward_upper_bound(pool_address, closing_rewards) as u256 };
        let stake_pool = borrow_global<StakePool>(pool_address);
        // 保留 u256 估算结果，交由预检在超出容量时返回延期，避免提前转换为 u64 导致事务中止。
        let active_reward_upper_bound_octa = (coin::value(&stake_pool.active) as u256)
            * (closing_rewards.rewards_rate as u256) / (closing_rewards.rewards_rate_denominator as u256);
        let pending_inactive_reward_upper_bound_octa = (coin::value(&stake_pool.pending_inactive) as u256)
            * (closing_rewards.rewards_rate as u256) / (closing_rewards.rewards_rate_denominator as u256);
        active_reward_upper_bound_octa + pending_inactive_reward_upper_bound_octa
            + if (closing_rewards.distribute_transaction_fee) { closing_rewards.fee_limit_per_pool as u256 } else { 0 }
    }

    #[view]
    /// 这里只检查质押池注册状态；PoC 启用状态另行检查，查询不会创建账本。
    public fun validator_registered(pool: address): bool {
        exists<StakePool>(pool) && exists<ValidatorConfig>(pool)
    }

    /// 返回每池每 Epoch 可分发的交易费用上限，以代币最小单位计量。
    /// 未配置时使用原生上限；PoC 准备和预检仍须校验部署上限。
    public fun transaction_fee_limit(): u64 acquires TransactionFeeConfig {
        if (exists<TransactionFeeConfig>(@topo_framework)) {
            let TransactionFeeConfig::V0 { max_fee_octa_allowed_per_epoch_per_pool } =
                borrow_global<TransactionFeeConfig>(@topo_framework);
            *max_fee_octa_allowed_per_epoch_per_pool
        } else { MAX_U64 as u64 }
    }

    /// 在准备或安装 Epoch 时保存奖励配置；结算旧 Epoch 时不能重新读取当前配置。
    fun reward_context(epoch: u64, poc_enabled: bool): RewardContext acquires TransactionFeeConfig {
        let (rewards_rate, rewards_rate_denominator) = staking_config::get_reward_rate(&staking_config::get());
        assert!(rewards_rate_denominator > 0, error::invalid_state(EPLAN_MISMATCH));
        let fee_limit_per_pool = transaction_fee_limit();
        if (poc_enabled) {
            poc_accounting::validate_reward_config(rewards_rate, rewards_rate_denominator, fee_limit_per_pool);
        };
        RewardContext {
            epoch, poc_enabled, rewards_rate, rewards_rate_denominator,
            distribute_transaction_fee: features::is_distribute_transaction_fee_enabled(),
            fee_limit_per_pool,
        }
    }

    /// 确认没有遗留计划后，保存当前原生 Epoch 的奖励配置，并初始化自主退出申请表。
    public(friend) fun prepare_poc_context(framework: &signer, epoch: u64) acquires PendingTransactionFee, TransactionFeeConfig, ValidatorSet {
        system_addresses::assert_topo_framework(framework);
        assert_reconfig_not_in_progress();
        assert!(!exists<PrecomputedValidatorSet>(@topo_framework)
            && !exists<EpochPlan>(@topo_framework)
            && !exists<InstalledRewardContext>(@topo_framework), error::invalid_state(EPLAN_MISMATCH));
        assert!(epoch == poc_accounting::current_epoch(), error::invalid_state(EPLAN_MISMATCH));
        assert!(!features::is_reconfiguration_frozen(), error::invalid_state(EPLAN_MISMATCH));
        staking_config::validate_poc_configuration();
        let context = reward_context(epoch, false);
        poc_accounting::validate_reward_config(context.rewards_rate, context.rewards_rate_denominator, context.fee_limit_per_pool);
        // 将费用累加器替换为有上限的版本，保留已经累计且允许分发的费用。
        if (exists<PendingTransactionFee>(@topo_framework)) {
            let set = borrow_global<ValidatorSet>(@topo_framework);
            let count = set.active_validators.length() + set.pending_inactive.length();
            let fees = &mut borrow_global_mut<PendingTransactionFee>(@topo_framework).pending_fee_by_validator;
            for (i in 0..count) {
                if (fees.contains(&i)) {
                    let amount = min(fees.remove(&i).read(), context.fee_limit_per_pool);
                    fees.add(i, aggregator_v2::create_aggregator_with_value(amount, context.fee_limit_per_pool));
                }
            }
        };
        move_to(framework, InstalledRewardContext { context });
        move_to(framework, VoluntaryLeaves { requests: table::new() });
        poc_reward_split::initialize(framework, epoch);
    }

    /// 只对地址副本做堆排序以查重，不改变委员会顺序。
    fun assert_unique_validators(infos: &vector<ValidatorInfo>) {
        let addresses = addresses_from_validator_infos(infos);
        let n = addresses.length();
        if (n < 2) { return };
        let start = n / 2;
        while (start > 0) {
            start -= 1;
            sift_addresses(&mut addresses, start, n);
        };
        let end = n;
        while (end > 1) {
            end -= 1;
            addresses.swap(0, end);
            sift_addresses(&mut addresses, 0, end);
        };
        for (i in 1..n) {
            assert!(addresses[i - 1] != addresses[i], error::invalid_state(EPLAN_MISMATCH));
        }
    }

    /// 在地址副本的 [0, end) 内恢复堆序，不修改验证者配置或当前 Epoch 的索引。
    fun sift_addresses(addresses: &mut vector<address>, root: u64, end: u64) {
        while (root < end / 2) {
            let child = root * 2 + 1;
            if (child + 1 < end && addresses[child] < addresses[child + 1]) { child += 1 };
            if (addresses[root] >= addresses[child]) { return };
            addresses.swap(root, child);
            root = child;
        }
    }

    /// 待退出成员仍参与当前 Epoch 投票；旧索引或总权重不一致时按状态错误处理。
    fun validate_current_set(set: &ValidatorSet) acquires ValidatorPerformance {
        let voters = set.active_validators;
        voters.append(set.pending_inactive);
        let all = voters;
        all.append(set.pending_active);
        assert_unique_validators(&all);
        let count = voters.length();
        assert!(count == borrow_global<ValidatorPerformance>(@topo_framework).validators.length(),
            error::invalid_state(EPLAN_MISMATCH));
        let seen = vector[];
        for (_i in 0..count) { seen.push_back(false) };
        let total = 0u256;
        let i = 0;
        while ({
            spec {
                invariant i <= count;
                invariant forall j in 0..i: voters[j].config.validator_index < count;
                invariant forall j in 0..len(set.active_validators):
                    j < i ==> set.active_validators[j].config.validator_index < count;
            };
            i < count
        }) {
            let v = &voters[i];
            assert!(v.config.validator_index < count, error::invalid_state(EPLAN_MISMATCH));
            let used = seen.borrow_mut(v.config.validator_index);
            assert!(!*used, error::invalid_state(EPLAN_MISMATCH));
            *used = true;
            total += (v.voting_power as u256);
            i += 1;
        };
        assert!(total == (set.total_voting_power as u256), error::invalid_state(EPLAN_MISMATCH));
    }

    /// DKG 启动前独立校验实际总权重；保守参数上限不能替代此检查。
    fun validate_target_powers(powers: &vector<u64>, minimum: u64, limit: u64, open: bool): (u64, u256) {
        let total = 0u256;
        powers.for_each_ref(|p| total += (*p as u256));
        if (powers.length() < minimum) { return (INSUFFICIENT_VALIDATORS, total) };
        if (powers.length() > limit || powers.length() > MAX_VALIDATOR_SET_SIZE
            || total > (MAX_U64 as u256)) { return (TARGET_OUT_OF_RANGE, total) };
        if (total == 0) { return (ZERO_TARGET_POWER, total) };
        if (open) {
            let concentrated = false;
            powers.for_each_ref(|p| { if (3 * (*p as u256) >= total) { concentrated = true } });
            if (concentrated) { return (CONCENTRATION_LIMIT, total) }
        };
        (0, total)
    }

    /// 按各池增量占比分配增长预算并向下取整，不再分配未用额度或舍入余量。
    /// 首次安装 PoC 时不与原生代币权重比较；后续增长比例按百分数计算，分母为 100。
    fun allocate_growth(candidates: &vector<u64>, bases: &vector<u64>, current_total: u128,
        increase_limit: u64, first: bool): vector<u64> {
        assert!(candidates.length() == bases.length(), error::invalid_state(EPLAN_MISMATCH));
        if (first) { return *candidates };
        let growth = 0u256;
        for (i in 0..candidates.length()) {
            if (candidates[i] > bases[i]) { growth += ((candidates[i] - bases[i]) as u256) }
        };
        let budget = (current_total as u256) * (increase_limit as u256) / 100;
        if (growth <= budget) { return *candidates };
        let result = vector[];
        let i = 0;
        while ({
            spec {
                invariant i <= len(candidates);
                invariant len(result) == i;
                invariant forall j in 0..i: result[j] <= candidates[j];
            };
            i < candidates.length()
        }) {
            let delta = if (candidates[i] > bases[i]) { candidates[i] - bases[i] } else { 0 };
            result.push_back(((min(candidates[i], bases[i]) as u256)
                + (delta as u256) * budget / growth) as u64);
            i += 1;
        };
        result
    }

    #[view]
    /// 冻结前只读生成目标；冻结后只返回原计划，不再按实时状态重选。
    public fun preview_epoch_transition(target_epoch: u64, cutoff_secs: u64): EpochPreview acquires EpochPlan, InstalledRewardContext, PrecomputedValidatorSet, StakePool, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        if (exists<EpochPlan>(@topo_framework)) {
            validate_epoch_plan(poc_accounting::current_epoch() + 1);
            return cached_epoch_preview()
        };
        assert!(!exists<PrecomputedValidatorSet>(@topo_framework)
            && !reconfiguration_state::is_in_progress() && !features::is_reconfiguration_frozen(),
            error::invalid_state(EPLAN_MISMATCH));
        preview_transition(target_epoch, cutoff_secs, option::none())
    }

    /// 保持公开预览布局不变；冻结后的查询从计划数据和唯一的 PVS 组装结果。
    fun cached_epoch_preview(): EpochPreview acquires EpochPlan, PrecomputedValidatorSet {
        let data = &borrow_global<EpochPlan>(@topo_framework).data;
        let pvs = borrow_global<PrecomputedValidatorSet>(@topo_framework);
        EpochPreview {
            reason: 0,
            epoch: data.epoch, period: data.period, period_index: data.period_index,
            cutoff_secs: data.cutoff_secs, poc_enabled: data.poc_enabled, params: data.params,
            closing_rewards: data.closing_rewards, targets: data.targets,
            validator_set: pvs.validator_set, is_liveness_fallback: pvs.is_liveness_fallback,
        }
    }

    /// 换届和自主退出共用此只读构建器；excluded 仅从本地候选列表中排除指定池。
    /// 资格不足返回延期原因，缓存损坏或账本不一致则中止事务。
    fun preview_transition(target_epoch: u64, cutoff_secs: u64, excluded: Option<address>): EpochPreview acquires InstalledRewardContext, StakePool, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        let closing_rewards = get_installed_reward_context();
        poc_reward_split::get_installed_native_reward_bps(closing_rewards.epoch);
        // 待生效功能开关可能切换奖励率来源，两份配置都须先满足部署上限。
        // 提交时的周期性调整只会降低奖励率，因此不会突破已验证的奖励上限。
        staking_config::validate_poc_configuration();
        poc_accounting::validate_fee_limit(transaction_fee_limit());
        let epoch = poc_accounting::current_epoch();
        assert!((target_epoch as u256) == (epoch as u256) + 1
            && closing_rewards.epoch == epoch, error::invalid_state(EPLAN_MISMATCH));
        let cur = *borrow_global<ValidatorSet>(@topo_framework);
        validate_current_set(&cur);
        let (clock_valid, period, period_index) = poc_power_store::preview_next_period();
        let params = poc_accounting::get_target_params(target_epoch);
        let poc_enabled = poc_accounting::target_poc_enabled(target_epoch);
        let preview = EpochPreview {
            reason: 0, epoch: target_epoch, period, period_index, cutoff_secs, poc_enabled, params,
            closing_rewards, targets: vector[],
            validator_set: ValidatorSet { consensus_scheme: cur.consensus_scheme, active_validators: vector[],
                pending_active: vector[], pending_inactive: vector[], total_voting_power: 0, total_joining_power: 0 },
            is_liveness_fallback: false,
        };
        if (!clock_valid || (poc_enabled && !poc_accounting::reward_epoch_supported(target_epoch))) {
            preview.reason = TARGET_OUT_OF_RANGE;
            return preview
        };
        let config = staking_config::get();
        let duration = staking_config::get_recurring_lockup_duration(&config);
        if ((cutoff_secs as u256) + (duration as u256) > (MAX_U64 as u256)) {
            preview.reason = TARGET_OUT_OF_RANGE;
            return preview
        };
        let candidates = cur.active_validators;
        let excluded_info = option::none();
        if (excluded.is_some()) {
            let index = find_validator(&candidates, *excluded.borrow());
            assert!(index.is_some(), error::invalid_state(EPLAN_MISMATCH));
            // 使用与实际退出相同的 swap_remove，确保预检时的候选顺序一致。
            excluded_info = option::some(candidates.swap_remove(index.extract()));
        };
        let num_current_candidates = candidates.length();
        let pending = cur.pending_active;
        // append 用 pop_back 反向追加待加入者，顺序须与原生选举一致。
        append(&mut candidates, &mut pending);
        let num_candidates = candidates.length();
        // 只处理当前投票池与下一 Epoch 候选池的并集；退出池的目标计奖基数设为零。
        candidates.append(cur.pending_inactive);
        if (excluded_info.is_some()) { candidates.push_back(excluded_info.extract()) };
        if (closing_rewards.poc_enabled) {
            // DKG 等待期间仍会累计提案统计；冻结前按最优表现为奖励入账和本金状态转换预留容量。
            // 推算目标权重时，保证金仅计入已有余额，尚未结算的奖励不计入。
            for (i in 0..candidates.length()) {
                let pool_address = candidates[i].addr;
                let native_reward_upper_bound_octa = if (i < num_current_candidates || i >= num_candidates) {
                    calculate_native_reward_upper_bound(pool_address, &closing_rewards)
                } else { 0 };
                if (!can_settle_native_reward(borrow_global<StakePool>(pool_address), native_reward_upper_bound_octa, cutoff_secs)) {
                    preview.reason = TARGET_OUT_OF_RANGE;
                    return preview
                };
            };
        };
        if (!poc_enabled) {
            // 准备期间继续原生选举，只同步已启用池的 units，不提前产生 PoC 奖励。
            let (set, fallback) = compute_native_next_validator_set(
                closing_rewards.rewards_rate, closing_rewards.rewards_rate_denominator, cutoff_secs);
            preview.validator_set = set;
            preview.is_liveness_fallback = fallback;
            let targets = vector[];
            candidates.for_each_ref(|c| {
                if (poc_accounting::pool_enabled(c.addr)) {
                    targets.push_back(PoolTarget { pool: c.addr,
                        units: poc_accounting::preview_pool_units(c.addr, target_epoch), power: 0, reward_base_octa: 0 });
                }
            });
            preview.targets = targets;
            return preview
        };
        let increase = staking_config::get_voting_power_increase_limit(&config);
        poc_accounting::validate_config(&params, increase, staking_config::get_allow_validator_set_change(&config));
        let (bond_octa_per_ohmp, min_power, max_power, min_validators) = poc_accounting::get_power_params_fields(&params);
        let power_per_ohmp = poc_accounting::power_per_ohmp();
        let (minimum_stake, _) = staking_config::get_required_stake(&config);
        let (max_reward_base_octa, max_rewards_rate_numerator, max_rewards_rate_denominator, max_fee_octa, _) =
            poc_accounting::get_reward_limits();
        let next_native_reward_bps = poc_reward_split::get_target_native_reward_bps(target_epoch);
        if (num_candidates > poc_accounting::validator_limit()
            || cur.active_validators.length() + cur.pending_inactive.length() > poc_accounting::validator_limit()) {
            preview.reason = TARGET_OUT_OF_RANGE;
            return preview
        };
        if (closing_rewards.poc_enabled && cur.total_voting_power == 0) {
            preview.reason = ZERO_CURRENT_POWER;
            return preview
        };
        let eligible = vector[];
        let eligible_is_current_validator = vector[];
        let target_indices = vector[];
        let candidate_powers = vector[];
        let bases = vector[];
        let visited = 0;
        while ({
            spec {
                invariant visited <= len(candidates);
                invariant preview.epoch == target_epoch && preview.cutoff_secs == cutoff_secs
                    && preview.closing_rewards == closing_rewards && preview.poc_enabled == poc_enabled;
                invariant len(eligible) == len(bases);
                invariant len(eligible) == len(eligible_is_current_validator);
                invariant len(eligible) == len(candidate_powers);
                invariant len(eligible) == len(target_indices);
                invariant len(eligible) <= visited;
                invariant forall j in 0..len(target_indices): target_indices[j] < len(preview.targets);
            };
            visited < candidates.length()
        }) {
            let i = visited;
            visited += 1;
            let c = candidates[i];
            if (!poc_accounting::pool_enabled(c.addr)) { continue };
            let units = poc_accounting::preview_pool_units(c.addr, target_epoch);
            let target_index = preview.targets.length();
            preview.targets.push_back(PoolTarget { pool: c.addr, units, power: 0, reward_base_octa: 0 });
            if (i >= num_candidates || !validator_registered(c.addr)) { continue };
            let pool = borrow_global<StakePool>(c.addr);
            // 保证金只包含预检时已有的本金；截止时间已到期的 pending_inactive 不计入。
            // 最后一个原生 Epoch 尚未结算的收益，也不能提前作为首个 PoC Epoch 的保证金。
            let bond_octa = (coin::value(&pool.active) as u256) + (coin::value(&pool.pending_active) as u256);
            if (pool.locked_until_secs > cutoff_secs) { bond_octa += (coin::value(&pool.pending_inactive) as u256) };
            let cfg = *borrow_global<ValidatorConfig>(c.addr);
            if (bond_octa < (minimum_stake as u256) || cfg.consensus_pubkey.is_empty()) { continue };
            // 用 u256 计算池算力和保证金上限，确定最终权重后再转换为 u64。
            let pool_power = (units as u256) * (period_index as u256) / ((1u256 << 32) * (1u256 << 64));
            let bond_cap_power = bond_octa * (power_per_ohmp as u256) / (bond_octa_per_ohmp as u256);
            let power = pool_power;
            if (power > bond_cap_power) { power = bond_cap_power };
            if (power > (max_power as u256)) { power = (max_power as u256) };
            if (power < (min_power as u256)) { continue };
            eligible.push_back(ValidatorInfo { addr: c.addr, voting_power: 0, config: cfg });
            eligible_is_current_validator.push_back(i < num_current_candidates);
            target_indices.push_back(target_index);
            candidate_powers.push_back(power as u64);
            bases.push_back(if (i < num_current_candidates) { c.voting_power } else { 0 });
        };
        // 先筛选合格候选，再分配增长预算；当前总权重仍包含待退出成员的投票权重。
        let powers = allocate_growth(&candidate_powers, &bases, cur.total_voting_power, increase, !closing_rewards.poc_enabled);
        let selected_powers = vector[];
        let selected = 0;
        while ({
            spec {
                invariant selected <= len(eligible);
                invariant preview.epoch == target_epoch && preview.cutoff_secs == cutoff_secs
                    && preview.closing_rewards == closing_rewards && preview.poc_enabled == poc_enabled;
            };
            selected < eligible.length()
        }) {
            let i = selected;
            selected += 1;
            let power = powers[i];
            if (power < min_power) { continue };
            let reward_base_octa = (power as u256) * (bond_octa_per_ohmp as u256) / (power_per_ohmp as u256);
            if (reward_base_octa > (max_reward_base_octa as u256)) {
                preview.reason = TARGET_OUT_OF_RANGE;
                return preview
            };
            // 部署参数中的奖励率上限可高于 100%；使用 u256 估算，超过 u64 上限时延期。
            assert!(max_rewards_rate_denominator > 0, error::invalid_state(EPLAN_MISMATCH));
            let next_inflation_upper_bound_octa = reward_base_octa * (max_rewards_rate_numerator as u256)
                / (max_rewards_rate_denominator as u256);
            if (next_inflation_upper_bound_octa > (MAX_U64 as u256)) {
                preview.reason = TARGET_OUT_OF_RANGE;
                return preview
            };
            let (next_native_inflation_upper_bound_octa, _) = poc_reward_split::split_inflation_reward(
                next_inflation_upper_bound_octa as u64, next_native_reward_bps);
            // 下一 Epoch 的费用开关和限额可能在冻结提交时更新，按部署费用上限预留。
            let (next_native_fee_upper_bound_octa, _) = poc_reward_split::split_reward(max_fee_octa, next_native_reward_bps);
            let next_native_reward_upper_bound_octa =
                (next_native_inflation_upper_bound_octa as u256) + (next_native_fee_upper_bound_octa as u256);
            if (next_native_reward_upper_bound_octa > 0) {
                // 若下一期可能产生原生奖励，须同时预留待结束期和下一期的奖励容量，避免后续换届因溢出而持续延期。
                // 按部署奖励率上限估算，覆盖提交时生效的缓冲配置及奖励率来源变更。
                let pool_address = eligible[i].addr;
                let closing_native_reward_upper_bound_octa = if (eligible_is_current_validator[i]) {
                    calculate_closing_native_reward_upper_bound(pool_address, &closing_rewards)
                } else { 0 };
                if (total_stake_balance_octa(borrow_global<StakePool>(pool_address)) + closing_native_reward_upper_bound_octa
                    + next_native_reward_upper_bound_octa > (MAX_U64 as u256)) {
                    preview.reason = TARGET_OUT_OF_RANGE;
                    return preview
                };
            };
            let target = preview.targets.borrow_mut(target_indices[i]);
            target.power = power;
            target.reward_base_octa = reward_base_octa as u64;
            let vi = eligible[i];
            vi.voting_power = power;
            // 这里只修改本地目标索引，旧 Epoch 的费用结清前不改链上索引。
            vi.config.validator_index = preview.validator_set.active_validators.length();
            preview.validator_set.active_validators.push_back(vi);
            selected_powers.push_back(power);
        };
        let (reason, total) = validate_target_powers(&selected_powers, min_validators,
            poc_accounting::validator_limit(), poc_accounting::is_open());
        preview.reason = reason;
        if (total <= (MAX_U64 as u256)) { preview.validator_set.total_voting_power = total as u128 };
        preview
    }

    /// 仅 Ready 时同时缓存计划和 PVS，并取得冻结令牌；延期不会冻结或推进 Epoch。
    /// 重复启动只校验已有计划，不更新截止时间或重新选举。
    public(friend) fun try_cache_epoch_plan(target_epoch: u64, cutoff_secs: u64): u64 acquires EpochPlan, InstalledRewardContext, StakePool, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        if (exists<EpochPlan>(@topo_framework)) { validate_epoch_plan(target_epoch); return 0 };
        assert!(!exists<PrecomputedValidatorSet>(@topo_framework)
            && !reconfiguration_state::is_in_progress(), error::invalid_state(EPLAN_MISMATCH));
        let preview = preview_transition(target_epoch, cutoff_secs, option::none());
        if (preview.reason != 0) { return preview.reason };
        let EpochPreview {
            reason: _, epoch, period, period_index, cutoff_secs, poc_enabled, params,
            closing_rewards, targets, validator_set, is_liveness_fallback,
        } = preview;
        let framework = create_signer::create_signer(@topo_framework);
        let feature_token = features::begin_reconfiguration_freeze(&framework);
        move_to(&framework, PrecomputedValidatorSet { validator_set, is_liveness_fallback });
        move_to(&framework, EpochPlan {
            data: EpochPlanData {
                epoch, period, period_index, cutoff_secs, poc_enabled, params, closing_rewards, targets,
            },
            feature_token, stage: 0,
        });
        0
    }

    /// 核对目标 Epoch、旧奖励上下文、PVS 存在性及冻结状态；委员会只有 PVS 一份。
    public(friend) fun validate_epoch_plan(target_epoch: u64) acquires EpochPlan, InstalledRewardContext {
        assert!(exists<EpochPlan>(@topo_framework) && exists<PrecomputedValidatorSet>(@topo_framework),
            error::invalid_state(EPLAN_MISMATCH));
        let plan = borrow_global<EpochPlan>(@topo_framework);
        let epoch = poc_accounting::current_epoch();
        assert!(plan.stage < 2 && (target_epoch as u256) == (epoch as u256) + 1
            && plan.data.epoch == target_epoch && plan.data.closing_rewards.epoch == epoch
            && plan.data.closing_rewards == get_installed_reward_context(),
            error::invalid_state(EPLAN_MISMATCH));
        poc_reward_split::get_installed_native_reward_bps(plan.data.closing_rewards.epoch);
        assert!(reconfiguration_state::is_in_progress() && features::is_reconfiguration_frozen()
            && plan.data.cutoff_secs == reconfiguration_state::start_time_secs(), error::invalid_state(EPLAN_MISMATCH));
    }

    /// 普通 DKG、Chunky DKG 和 Epoch 安装均从同一个已校验计划读取目标集合。
    public(friend) fun cached_validator_set(): ValidatorSet acquires EpochPlan, InstalledRewardContext, PrecomputedValidatorSet {
        validate_epoch_plan(poc_accounting::current_epoch() + 1);
        borrow_global<PrecomputedValidatorSet>(@topo_framework).validator_set
    }

    /// 结算旧 Epoch 奖励后，才凭计划令牌应用功能开关；期间始终保持冻结。
    public(friend) fun apply_cached_features(framework: &signer) acquires EpochPlan {
        let plan = borrow_global<EpochPlan>(@topo_framework);
        assert!(plan.stage == 1, error::invalid_state(EPLAN_MISMATCH));
        features::on_new_epoch_with_freeze_token(framework, &plan.feature_token);
    }

    /// 按旧索引读取并删除费用记录；即使旧奖励配置关闭费用分发，也必须清空记录。
    fun take_epoch_fee(index: u64, context: &RewardContext): u64 acquires PendingTransactionFee {
        if (!exists<PendingTransactionFee>(@topo_framework)) { return 0 };
        let fees = &mut borrow_global_mut<PendingTransactionFee>(@topo_framework).pending_fee_by_validator;
        if (!fees.contains(&index)) { return 0 };
        let amount = fees.remove(&index).read();
        if (context.distribute_transaction_fee) { min(amount, context.fee_limit_per_pool) } else { 0 }
    }

    /// 基数以代币最小单位计量；用 u256 计算提案总数和乘积，最后对奖励向下取整。
    fun reward_amount_wide(base: u64, success: u64, total: u256, rate: u64, denominator: u64): u64 {
        assert!(denominator > 0, error::invalid_state(EPLAN_MISMATCH));
        if (total == 0) { return 0 };
        let result = (base as u256) * (rate as u256) * (success as u256) / ((denominator as u256) * total);
        assert!(result <= (MAX_U64 as u256), error::invalid_state(EPLAN_MISMATCH));
        result as u64
    }

    /// 按当期 active 和 pending_inactive 余额分配原生奖励；pending_inactive 部分向下取整，余数归 active。
    fun split_native_reward_by_stake(native_reward_octa: u64, active_stake_octa: u64, pending_inactive_stake_octa: u64): (u64, u64) {
        let reward_eligible_stake_octa = (active_stake_octa as u256) + (pending_inactive_stake_octa as u256);
        assert!(reward_eligible_stake_octa > 0 || native_reward_octa == 0, error::invalid_state(EPLAN_MISMATCH));
        let pending_inactive_reward_octa = if (reward_eligible_stake_octa > 0) {
            ((native_reward_octa as u256) * (pending_inactive_stake_octa as u256) / reward_eligible_stake_octa) as u64
        } else { 0 };
        (native_reward_octa - pending_inactive_reward_octa, pending_inactive_reward_octa)
    }

    /// 检查奖励入账及本金状态转换后，Coin 余额和原生质押总额是否仍在 u64 范围内。
    fun can_settle_native_reward(stake_pool: &StakePool, native_reward_octa: u64, cutoff_secs: u64): bool {
        let active_stake_octa = coin::value(&stake_pool.active);
        let pending_inactive_stake_octa = coin::value(&stake_pool.pending_inactive);
        let reward_eligible_stake_octa = (active_stake_octa as u256) + (pending_inactive_stake_octa as u256);
        if (reward_eligible_stake_octa == 0 && native_reward_octa > 0) { return false };
        if (reward_eligible_stake_octa + (coin::value(&stake_pool.pending_active) as u256)
            + (native_reward_octa as u256) > (MAX_U64 as u256)) {
            return false
        };
        let (_, pending_inactive_reward_octa) = split_native_reward_by_stake(
            native_reward_octa, active_stake_octa, pending_inactive_stake_octa);
        stake_pool.locked_until_secs > cutoff_secs
            || (coin::value(&stake_pool.inactive) as u256) + (pending_inactive_stake_octa as u256)
                + (pending_inactive_reward_octa as u256) <= (MAX_U64 as u256)
    }

    /// 汇总池内四类质押余额，仅用于奖励容量预留，不作为投票权重或计奖基数。
    fun total_stake_balance_octa(stake_pool: &StakePool): u256 {
        (coin::value(&stake_pool.active) as u256) + (coin::value(&stake_pool.inactive) as u256)
            + (coin::value(&stake_pool.pending_active) as u256) + (coin::value(&stake_pool.pending_inactive) as u256)
    }

    /// 使用旧委员会原有的 units、权重和索引结算奖励，待加入者不参与旧 Epoch 分配。
    /// 检查计划阶段以防重复结算；奖励结算完成后，才能应用新配置和到期持仓变更。
    public(friend) fun settle_closing_epoch() acquires EpochPlan, InstalledRewardContext, PendingTransactionFee, StakePool, TopoCoinCapabilities, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        validate_epoch_plan(poc_accounting::current_epoch() + 1);
        assert!(borrow_global<EpochPlan>(@topo_framework).stage == 0, error::invalid_state(EPLAN_MISMATCH));
        let context = borrow_global<EpochPlan>(@topo_framework).data.closing_rewards;
        let set = borrow_global<ValidatorSet>(@topo_framework);
        let voters = set.active_validators;
        voters.append(set.pending_inactive);
        let i = 0;
        while ({
            spec {
                invariant i <= len(voters);
                invariant global<poc_accounting::AccountingState>(@topo_framework).epoch == context.epoch;
            };
            i < voters.length()
        }) {
            settle_voting_pool(&voters[i], &context);
            i += 1;
        };
        if (exists<PendingTransactionFee>(@topo_framework)) {
            assert!(borrow_global<PendingTransactionFee>(@topo_framework).pending_fee_by_validator.is_empty(),
                error::internal(ETRANSACTION_FEE_NOT_FULLY_DISTRIBUTED));
        };
        borrow_global_mut<EpochPlan>(@topo_framework).stage = 1;
    }

    /// 按待结束 Epoch 的模式结算奖励；PoC 模式下只计算一笔通胀，再按当期原生奖励占比拆分。
    /// 可分发交易费使用同一旧期占比分流；通胀与费用各自取整、各自守恒。
    fun settle_voting_pool(v: &ValidatorInfo, context: &RewardContext) acquires PendingTransactionFee, StakePool, TopoCoinCapabilities, ValidatorConfig, ValidatorPerformance {
        assert!(borrow_global<ValidatorConfig>(v.addr).validator_index == v.config.validator_index,
            error::invalid_state(EPLAN_MISMATCH));
        let perf = borrow_global<ValidatorPerformance>(@topo_framework).validators.borrow(v.config.validator_index);
        let total = (perf.successful_proposals as u256) + (perf.failed_proposals as u256);
        let fee = take_epoch_fee(v.config.validator_index, context);
        let mint_cap = &borrow_global<TopoCoinCapabilities>(@topo_framework).mint_cap;
        if (context.poc_enabled) {
            assert!(poc_accounting::preview_pool_units(v.addr, context.epoch) > 0, error::invalid_state(EPLAN_MISMATCH));
            // 使用当期固定的计奖基数计算通胀总额，随后再拆分奖励。
            let reward_base_octa = poc_accounting::pool_reward_base_octa(v.addr);
            let total_inflation_octa = reward_amount_wide(reward_base_octa, perf.successful_proposals, total,
                context.rewards_rate, context.rewards_rate_denominator);
            let total_reward_octa = (total_inflation_octa as u256) + (fee as u256);
            assert!(total_reward_octa <= (MAX_U64 as u256) && v.voting_power > 0,
                error::invalid_state(EPLAN_MISMATCH));
            let native_reward_bps = poc_reward_split::get_installed_native_reward_bps(context.epoch);
            let (native_inflation_octa, poc_inflation_octa) = poc_reward_split::split_inflation_reward(
                total_inflation_octa, native_reward_bps);
            let (native_fee_octa, poc_fee_octa) = poc_reward_split::split_reward(fee, native_reward_bps);
            let stake_pool = borrow_global_mut<StakePool>(v.addr);
            let active_stake_octa = coin::value(&stake_pool.active);
            let pending_inactive_stake_octa = coin::value(&stake_pool.pending_inactive);
            let (active_native_reward_octa, pending_inactive_native_reward_octa) = split_native_reward_by_stake(
                native_inflation_octa, active_stake_octa, pending_inactive_stake_octa);
            let (active_native_fee_octa, pending_inactive_native_fee_octa) = split_native_reward_by_stake(
                native_fee_octa, active_stake_octa, pending_inactive_stake_octa);
            coin::merge(&mut stake_pool.active, coin::mint(active_native_reward_octa + active_native_fee_octa, mint_cap));
            coin::merge(&mut stake_pool.pending_inactive,
                coin::mint(pending_inactive_native_reward_octa + pending_inactive_native_fee_octa, mint_cap));
            if (native_inflation_octa > 0) {
                event::emit(DistributeRewards { pool_address: v.addr, rewards_amount: native_inflation_octa });
            };
            if (native_fee_octa > 0) {
                event::emit(DistributeTransactionFee { pool_address: v.addr, fee_amount: native_fee_octa });
            };
            let poc_rewards = coin::mint(poc_inflation_octa + poc_fee_octa, mint_cap);
            let delta_index = poc_accounting::credit_epoch_reward(v.addr, context.epoch, poc_rewards);
            event::emit(PoCRewardCredited { pool: v.addr, closing_epoch: context.epoch,
                reward_base_octa, inflation: poc_inflation_octa, fee: poc_fee_octa, delta_index });
            event::emit(PoCRewardSplit { pool: v.addr, closing_epoch: context.epoch, native_reward_bps,
                total_inflation_octa, active_native_reward_octa, pending_inactive_native_reward_octa, poc_inflation_octa });
        } else {
            let pool = borrow_global_mut<StakePool>(v.addr);
            // 最后一个原生 Epoch 仍对两部分收益分别取整，避免切换时改变历史份额归属。
            let active = coin::value(&pool.active);
            let pending_inactive = coin::value(&pool.pending_inactive);
            let active_reward = reward_amount_wide(active, perf.successful_proposals, total,
                context.rewards_rate, context.rewards_rate_denominator);
            let inactive_reward = reward_amount_wide(pending_inactive, perf.successful_proposals, total,
                context.rewards_rate, context.rewards_rate_denominator);
            let bond_octa = (active as u256) + (pending_inactive as u256);
            assert!(bond_octa > 0 || fee == 0, error::invalid_state(EPLAN_MISMATCH));
            let inactive_fee = if (bond_octa > 0) { ((fee as u256) * (pending_inactive as u256) / bond_octa) as u64 } else { 0 };
            coin::merge(&mut pool.active, coin::mint(active_reward, mint_cap));
            coin::merge(&mut pool.pending_inactive, coin::mint(inactive_reward, mint_cap));
            coin::merge(&mut pool.active, coin::mint(fee - inactive_fee, mint_cap));
            coin::merge(&mut pool.pending_inactive, coin::mint(inactive_fee, mint_cap));
            event::emit(DistributeRewards { pool_address: v.addr, rewards_amount: active_reward + inactive_reward });
            if (fee > 0) { event::emit(DistributeTransactionFee { pool_address: v.addr, fee_amount: fee }) }
        }
    }

    /// 按计划截止时间处理本金，避免 DKG 等待改变计入保证金的本金范围。
    fun apply_stake_transitions(pool: address, cutoff_secs: u64) acquires StakePool {
        let p = borrow_global_mut<StakePool>(pool);
        coin::merge(&mut p.active, coin::extract_all(&mut p.pending_active));
        if (p.locked_until_secs <= cutoff_secs) {
            coin::merge(&mut p.inactive, coin::extract_all(&mut p.pending_inactive));
        }
    }

    /// 结算旧 Epoch 奖励并应用缓冲配置后，在同一事务中安装原计划，不重新选举。
    /// 时钟、池目标、委员会和奖励上下文必须对应同一个目标 Epoch。
    public(friend) fun install_epoch_plan(target_epoch: u64) acquires EpochPlan, InstalledRewardContext, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        // 由链 Epoch 指定目标，同时核对账本 Epoch，避免两个时钟不一致时安装。
        validate_epoch_plan(target_epoch);
        assert!(borrow_global<EpochPlan>(@topo_framework).stage == 1, error::invalid_state(EPLAN_MISMATCH));
        let p = borrow_global<EpochPlan>(@topo_framework).data;
        let set = borrow_global<PrecomputedValidatorSet>(@topo_framework).validator_set;
        let is_liveness_fallback = borrow_global<PrecomputedValidatorSet>(@topo_framework).is_liveness_fallback;
        let old_set = *borrow_global<ValidatorSet>(@topo_framework);
        let pools = old_set.active_validators;
        pools.append(old_set.pending_active);
        pools.append(old_set.pending_inactive);
        pools.for_each_ref(|v| apply_stake_transitions(v.addr, p.cutoff_secs));
        let leaves = &mut borrow_global_mut<VoluntaryLeaves>(@topo_framework).requests;
        old_set.pending_inactive.for_each_ref(|v| { if (leaves.contains(v.addr)) { leaves.remove(v.addr); } });
        if (features::periodical_reward_rate_decrease_enabled()) {
            staking_config::calculate_and_save_latest_epoch_rewards_rate();
        };
        let context = reward_context(p.epoch, p.poc_enabled);
        let (clock_valid, period, index) = poc_power_store::preview_next_period();
        assert!(clock_valid && period == p.period && index == p.period_index, error::invalid_state(EPLAN_MISMATCH));
        // 先推进源周期，再更新账本绝对 Epoch；两步之间不能查询用户算力快照或重建版本。
        poc_power_store::commit_next_period_if_boundary();
        // 检查点记录旧 Epoch 奖励入账后的指数，再核对实际 units 是否等于冻结目标。
        p.targets.for_each_ref(|t| poc_accounting::install_pool_target(t.pool, p.epoch, t.units, t.reward_base_octa));
        let powers = set.active_validators.map_ref(|v| v.voting_power);
        if (p.poc_enabled) {
            let (_, _, _, minimum) = poc_accounting::get_power_params_fields(&p.params);
            let (reason, total) = validate_target_powers(&powers, minimum, poc_accounting::validator_limit(), poc_accounting::is_open());
            assert!(reason == 0 && total == (set.total_voting_power as u256), error::invalid_state(EPLAN_MISMATCH));
        };
        // 旧 Epoch 费用已清空，现在才重建索引、表现数组和费用表。
        let performance = &mut borrow_global_mut<ValidatorPerformance>(@topo_framework).validators;
        *performance = vector[];
        let duration = staking_config::get_recurring_lockup_duration(&staking_config::get());
        let now = timestamp::now_seconds();
        let fees_exist = exists<PendingTransactionFee>(@topo_framework);
        let i = 0;
        while ({
            spec {
                invariant i <= len(set.active_validators);
                invariant len(performance) == i;
                invariant forall j in 0..i:
                    exists<StakePool>(set.active_validators[j].addr)
                        && exists<ValidatorConfig>(set.active_validators[j].addr)
                        && global<ValidatorConfig>(set.active_validators[j].addr).validator_index < i
                        && set.active_validators[j].config.validator_index < i;
            };
            i < set.active_validators.length()
        }) {
            let v = set.active_validators[i];
            assert!(v.config.validator_index == i, error::invalid_state(EPLAN_MISMATCH));
            borrow_global_mut<ValidatorConfig>(v.addr).validator_index = i;
            performance.push_back(IndividualValidatorPerformance { successful_proposals: 0, failed_proposals: 0 });
            let pool = borrow_global_mut<StakePool>(v.addr);
            if (pool.locked_until_secs <= p.cutoff_secs) {
                // 锁仓续期从换届完成时起算，但本金是否到期仍以计划截止时间判断。
                let until = (now as u256) + (duration as u256);
                assert!(until <= (MAX_U64 as u256), error::invalid_state(EPLAN_MISMATCH));
                pool.locked_until_secs = until as u64;
            };
            if (fees_exist) {
                borrow_global_mut<PendingTransactionFee>(@topo_framework).pending_fee_by_validator.add(
                    i, aggregator_v2::create_aggregator(context.fee_limit_per_pool));
            };
            i += 1;
        };
        *borrow_global_mut<ValidatorSet>(@topo_framework) = set;
        borrow_global_mut<InstalledRewardContext>(@topo_framework).context = context;
        poc_reward_split::install_epoch(p.epoch, p.poc_enabled);
        poc_accounting::advance_epoch(p.epoch, p.poc_enabled);
        borrow_global_mut<EpochPlan>(@topo_framework).stage = 2;
        if (is_liveness_fallback) {
            let (minimum_stake, _) = staking_config::get_required_stake(&staking_config::get());
            event::emit(ValidatorSetLivenessFallback { minimum_stake,
                emergency_validator_count: set.active_validators.length(), total_emergency_voting_power: set.total_voting_power });
        };
        if (p.poc_enabled) {
            event::emit(PoCEpochInstalled { epoch: p.epoch, period: p.period,
                selected_count: set.active_validators.length(), total_power: set.total_voting_power as u64 });
        }
    }

    /// 确认目标已安装后，同时移除计划和 PVS、消耗唯一令牌，解除标准库冻结。
    public(friend) fun finish_epoch_plan() acquires EpochPlan, InstalledRewardContext, PrecomputedValidatorSet {
        let EpochPlan { data, feature_token, stage } = move_from<EpochPlan>(@topo_framework);
        let PrecomputedValidatorSet { validator_set: _, is_liveness_fallback: _ } =
            move_from<PrecomputedValidatorSet>(@topo_framework);
        assert!(stage == 2 && data.epoch == poc_accounting::current_epoch()
            && get_installed_reward_context().epoch == data.epoch, error::invalid_state(EPLAN_MISMATCH));
        features::end_reconfiguration_freeze(feature_token);
    }

    /// 只撤销当前 Epoch 的自主退出，恢复原 ValidatorInfo 和索引，保留当前权重与奖励。
    /// 恢复后候选人数不能超过部署上限；其他不合格条件可稍后修复。
    public entry fun cancel_leave_validator_set(operator: &signer, pool: address) acquires StakePool, ValidatorSet, VoluntaryLeaves {
        assert_reconfig_not_in_progress();
        assert!(get_operator(pool) == signer::address_of(operator), error::unauthenticated(ENOT_OPERATOR));
        let epoch = poc_accounting::current_epoch();
        let requests = &mut borrow_global_mut<VoluntaryLeaves>(@topo_framework).requests;
        assert!(requests.contains(pool) && *requests.borrow(pool) == epoch, error::invalid_state(ENO_VOLUNTARY_LEAVE));
        let set = borrow_global_mut<ValidatorSet>(@topo_framework);
        assert!(set.active_validators.length() + set.pending_active.length() < poc_accounting::validator_limit(),
            error::invalid_argument(EVALIDATOR_SET_TOO_LARGE));
        let index = find_validator(&set.pending_inactive, pool);
        assert!(index.is_some(), error::invalid_state(ENO_VOLUNTARY_LEAVE));
        set.active_validators.push_back(set.pending_inactive.swap_remove(index.extract()));
        requests.remove(pool);
        event::emit(VoluntaryLeaveCancelled { pool, request_epoch: epoch });
    }

    /// Validator Config not published.
    const EVALIDATOR_CONFIG: u64 = 1;
    /// Not enough stake to join validator set.
    const ESTAKE_TOO_LOW: u64 = 2;
    /// Too much stake to join validator set.
    const ESTAKE_TOO_HIGH: u64 = 3;
    /// Account is already a validator or pending validator.
    const EALREADY_ACTIVE_VALIDATOR: u64 = 4;
    /// Account is not a validator.
    const ENOT_VALIDATOR: u64 = 5;
    /// Can't remove last validator.
    const ELAST_VALIDATOR: u64 = 6;
    /// Total stake exceeds maximum allowed.
    const ESTAKE_EXCEEDS_MAX: u64 = 7;
    /// Account is already registered as a validator candidate.
    const EALREADY_REGISTERED: u64 = 8;
    /// Account does not have the right operator capability.
    const ENOT_OPERATOR: u64 = 9;
    /// Validators cannot join or leave post genesis on this test network.
    const ENO_POST_GENESIS_VALIDATOR_SET_CHANGE_ALLOWED: u64 = 10;
    /// Invalid consensus public key
    const EINVALID_PUBLIC_KEY: u64 = 11;
    /// Validator set exceeds the limit
    const EVALIDATOR_SET_TOO_LARGE: u64 = 12;
    /// Voting power increase has exceeded the limit for this current epoch.
    const EVOTING_POWER_INCREASE_EXCEEDS_LIMIT: u64 = 13;
    /// Stake pool does not exist at the provided pool address.
    const ESTAKE_POOL_DOES_NOT_EXIST: u64 = 14;
    /// Owner capability does not exist at the provided account.
    const EOWNER_CAP_NOT_FOUND: u64 = 15;
    /// An account cannot own more than one owner capability.
    const EOWNER_CAP_ALREADY_EXISTS: u64 = 16;
    /// Validator is not defined in the ACL of entities allowed to be validators
    const EINELIGIBLE_VALIDATOR: u64 = 17;
    /// Cannot update stake pool's lockup to earlier than current lockup.
    const EINVALID_LOCKUP: u64 = 18;
    /// Table to store collected transaction fees for each validator already exists.
    const EFEES_TABLE_ALREADY_EXISTS: u64 = 19;
    /// Validator set change temporarily disabled because of in-progress reconfiguration. Please retry after 1 minute.
    const ERECONFIGURATION_IN_PROGRESS: u64 = 20;
    /// Transaction fee is not fully distributed at epoch ending.
    const ETRANSACTION_FEE_NOT_FULLY_DISTRIBUTED: u64 = 29;
    /// Deprecated function call.
    const EDEPRECATED: u64 = 30;
    /// The permissioned signer feature has been removed.
    const EPERMISSIONED_SIGNER_REMOVED: u64 = 31;

    /// Validator status enum. We can switch to proper enum later once Move supports it.
    const VALIDATOR_STATUS_PENDING_ACTIVE: u64 = 1;
    const VALIDATOR_STATUS_ACTIVE: u64 = 2;
    const VALIDATOR_STATUS_PENDING_INACTIVE: u64 = 3;
    const VALIDATOR_STATUS_INACTIVE: u64 = 4;

    /// Limit the maximum size to u16::max, it's the current limit of the bitvec
    /// https://github.com/aptos-labs/aptos-core/blob/main/crates/aptos-bitvec/src/lib.rs#L20
    const MAX_VALIDATOR_SET_SIZE: u64 = 65536;

    /// Limit the maximum value of `rewards_rate` in order to avoid any arithmetic overflow.
    const MAX_REWARDS_RATE: u64 = 1000000;

    const MAX_U64: u128 = 18446744073709551615;

    /// Capability that represents ownership and can be used to control the validator and the associated stake pool.
    /// Having this be separate from the signer for the account that the validator resources are hosted at allows
    /// modules to have control over a validator.
    struct OwnerCapability has key, store {
        pool_address: address
    }

    /// Each validator has a separate StakePool resource and can provide a stake.
    /// Changes in stake for an active validator:
    /// 1. If a validator calls add_stake, the newly added stake is moved to pending_active.
    /// 2. If validator calls unlock, their stake is moved to pending_inactive.
    /// 2. When the next epoch starts, any pending_inactive stake is moved to inactive and can be withdrawn.
    ///    Any pending_active stake is moved to active and adds to the validator's voting power.
    ///
    /// Changes in stake for an inactive validator:
    /// 1. If a validator calls add_stake, the newly added stake is moved directly to active.
    /// 2. If validator calls unlock, their stake is moved directly to inactive.
    /// 3. When the next epoch starts, the validator can be activated if their active stake is more than the minimum.
    struct StakePool has key {
        // active stake
        active: Coin<TopoCoin>,
        // inactive stake, can be withdrawn
        inactive: Coin<TopoCoin>,
        // pending activation for next epoch
        pending_active: Coin<TopoCoin>,
        // pending deactivation for next epoch
        pending_inactive: Coin<TopoCoin>,
        locked_until_secs: u64,
        // Track the current operator of the validator node.
        // This allows the operator to be different from the original account and allow for separation of
        // the validator operations and ownership.
        // Only the account holding OwnerCapability of the staking pool can update this.
        operator_address: address,

        // Track the current vote delegator of the staking pool.
        // Only the account holding OwnerCapability of the staking pool can update this.
        delegated_voter: address,

        // The events emitted for the entire StakePool's lifecycle.
        initialize_validator_events: EventHandle<RegisterValidatorCandidateEvent>,
        set_operator_events: EventHandle<SetOperatorEvent>,
        add_stake_events: EventHandle<AddStakeEvent>,
        reactivate_stake_events: EventHandle<ReactivateStakeEvent>,
        rotate_consensus_key_events: EventHandle<RotateConsensusKeyEvent>,
        update_network_and_fullnode_addresses_events: EventHandle<
            UpdateNetworkAndFullnodeAddressesEvent>,
        increase_lockup_events: EventHandle<IncreaseLockupEvent>,
        join_validator_set_events: EventHandle<JoinValidatorSetEvent>,
        distribute_rewards_events: EventHandle<DistributeRewardsEvent>,
        unlock_stake_events: EventHandle<UnlockStakeEvent>,
        withdraw_stake_events: EventHandle<WithdrawStakeEvent>,
        leave_validator_set_events: EventHandle<LeaveValidatorSetEvent>
    }

    /// Validator info stored in validator address.
    struct ValidatorConfig has key, copy, store, drop {
        consensus_pubkey: vector<u8>,
        network_addresses: vector<u8>,
        // to make it compatible with previous definition, remove later
        fullnode_addresses: vector<u8>,
        // Index in the active set if the validator corresponding to this stake pool is active.
        validator_index: u64
    }

    /// Consensus information per validator, stored in ValidatorSet.
    struct ValidatorInfo has copy, store, drop {
        addr: address,
        voting_power: u64,
        config: ValidatorConfig
    }

    /// Full ValidatorSet, stored in @topo_framework.
    /// 1. join_validator_set adds to pending_active queue.
    /// 2. leave_valdiator_set moves from active to pending_inactive queue.
    /// 3. on_new_epoch processes two pending queues and refresh ValidatorInfo from the owner's address.
    struct ValidatorSet has copy, key, drop, store {
        consensus_scheme: u8,
        // Active validators for the current epoch.
        active_validators: vector<ValidatorInfo>,
        // Pending validators to leave in next epoch (still active).
        pending_inactive: vector<ValidatorInfo>,
        // Pending validators to join in next epoch.
        pending_active: vector<ValidatorInfo>,
        // Current total voting power.
        total_voting_power: u128,
        // Total voting power waiting to join in the next epoch.
        total_joining_power: u128
    }

    /// Transaction fee that is collected in current epoch, indexed by validator_index.
    struct PendingTransactionFee has key, store {
        pending_fee_by_validator: BigOrderedMap<u64, Aggregator<u64>>
    }

    enum TransactionFeeConfig has drop, key, store {
        V0 {
            max_fee_octa_allowed_per_epoch_per_pool: u64
        }
    }

    #[event]
    struct DistributeTransactionFee has drop, store {
        pool_address: address,
        fee_amount: u64
    }

    /// TopoCoin capabilities, set during genesis and stored in @CoreResource account.
    /// This allows the Stake module to mint rewards to stakers.
    struct TopoCoinCapabilities has key {
        mint_cap: MintCapability<TopoCoin>
    }

    struct IndividualValidatorPerformance has store, drop {
        successful_proposals: u64,
        failed_proposals: u64
    }

    struct ValidatorPerformance has key {
        validators: vector<IndividualValidatorPerformance>
    }

    /// A system resource holding the pre-computed validator set for the next epoch.
    /// Created by `next_validator_consensus_infos_v2()` when reconfig starts.
    /// Consumed (destroyed) by `on_new_epoch()`.
    /// Resource existence is the "ready" flag — no Option wrapper needed.
    struct PrecomputedValidatorSet has key {
        validator_set: ValidatorSet,
        is_liveness_fallback: bool,
    }

    struct RegisterValidatorCandidateEvent has drop, store {
        pool_address: address
    }

    #[deprecated]
    struct StakeManagementPermission has copy, drop, store {}

    #[event]
    struct RegisterValidatorCandidate has drop, store {
        pool_address: address
    }

    struct SetOperatorEvent has drop, store {
        pool_address: address,
        old_operator: address,
        new_operator: address
    }

    #[event]
    struct SetOperator has drop, store {
        pool_address: address,
        old_operator: address,
        new_operator: address
    }

    struct AddStakeEvent has drop, store {
        pool_address: address,
        amount_added: u64
    }

    #[event]
    struct AddStake has drop, store {
        pool_address: address,
        amount_added: u64
    }

    struct ReactivateStakeEvent has drop, store {
        pool_address: address,
        amount: u64
    }

    #[event]
    struct ReactivateStake has drop, store {
        pool_address: address,
        amount: u64
    }

    struct RotateConsensusKeyEvent has drop, store {
        pool_address: address,
        old_consensus_pubkey: vector<u8>,
        new_consensus_pubkey: vector<u8>
    }

    #[event]
    struct RotateConsensusKey has drop, store {
        pool_address: address,
        old_consensus_pubkey: vector<u8>,
        new_consensus_pubkey: vector<u8>
    }

    struct UpdateNetworkAndFullnodeAddressesEvent has drop, store {
        pool_address: address,
        old_network_addresses: vector<u8>,
        new_network_addresses: vector<u8>,
        old_fullnode_addresses: vector<u8>,
        new_fullnode_addresses: vector<u8>
    }

    #[event]
    struct UpdateNetworkAndFullnodeAddresses has drop, store {
        pool_address: address,
        old_network_addresses: vector<u8>,
        new_network_addresses: vector<u8>,
        old_fullnode_addresses: vector<u8>,
        new_fullnode_addresses: vector<u8>
    }

    struct IncreaseLockupEvent has drop, store {
        pool_address: address,
        old_locked_until_secs: u64,
        new_locked_until_secs: u64
    }

    #[event]
    struct IncreaseLockup has drop, store {
        pool_address: address,
        old_locked_until_secs: u64,
        new_locked_until_secs: u64
    }

    struct JoinValidatorSetEvent has drop, store {
        pool_address: address
    }

    #[event]
    struct JoinValidatorSet has drop, store {
        pool_address: address
    }

    struct DistributeRewardsEvent has drop, store {
        pool_address: address,
        rewards_amount: u64
    }

    #[event]
    /// The amount includes transaction fee and staking rewards.
    struct DistributeRewards has drop, store {
        pool_address: address,
        rewards_amount: u64
    }

    struct UnlockStakeEvent has drop, store {
        pool_address: address,
        amount_unlocked: u64
    }

    #[event]
    struct UnlockStake has drop, store {
        pool_address: address,
        amount_unlocked: u64
    }

    struct WithdrawStakeEvent has drop, store {
        pool_address: address,
        amount_withdrawn: u64
    }

    #[event]
    struct WithdrawStake has drop, store {
        pool_address: address,
        amount_withdrawn: u64
    }

    struct LeaveValidatorSetEvent has drop, store {
        pool_address: address
    }

    #[event]
    struct LeaveValidatorSet has drop, store {
        pool_address: address
    }

    #[event]
    struct ValidatorSetLivenessFallback has drop, store {
        minimum_stake: u64,
        emergency_validator_count: u64,
        total_emergency_voting_power: u128
    }

    #[deprecated]
    /// DEPRECATED
    struct ValidatorFees has key {
        fees_table: Table<address, Coin<TopoCoin>>
    }

    #[deprecated]
    public fun grant_permission(
        _master: &signer, _permissioned_signer: &signer
    ) {
        abort error::unavailable(EPERMISSIONED_SIGNER_REMOVED)
    }

    #[view]
    /// Return the lockup expiration of the stake pool at `pool_address`.
    /// This will throw an error if there's no stake pool at `pool_address`.
    public fun get_lockup_secs(pool_address: address): u64 acquires StakePool {
        assert_stake_pool_exists(pool_address);
        borrow_global<StakePool>(pool_address).locked_until_secs
    }

    #[view]
    /// Return the remaining lockup of the stake pool at `pool_address`.
    /// This will throw an error if there's no stake pool at `pool_address`.
    public fun get_remaining_lockup_secs(pool_address: address): u64 acquires StakePool {
        assert_stake_pool_exists(pool_address);
        let lockup_time = borrow_global<StakePool>(pool_address).locked_until_secs;
        if (lockup_time <= timestamp::now_seconds()) { 0 }
        else {
            lockup_time - timestamp::now_seconds()
        }
    }

    #[view]
    /// Return the different stake amounts for `pool_address` (whether the validator is active or not).
    /// The returned amounts are for (active, inactive, pending_active, pending_inactive) stake respectively.
    public fun get_stake(pool_address: address): (u64, u64, u64, u64) acquires StakePool {
        assert_stake_pool_exists(pool_address);
        let stake_pool = borrow_global<StakePool>(pool_address);
        (
            coin::value(&stake_pool.active),
            coin::value(&stake_pool.inactive),
            coin::value(&stake_pool.pending_active),
            coin::value(&stake_pool.pending_inactive)
        )
    }

    #[view]
    /// Returns the validator's state.
    public fun get_validator_state(pool_address: address): u64 acquires ValidatorSet {
        let validator_set = borrow_global<ValidatorSet>(@topo_framework);
        if (find_validator(&validator_set.pending_active, pool_address).is_some()) {
            VALIDATOR_STATUS_PENDING_ACTIVE
        } else if (find_validator(&validator_set.active_validators, pool_address).is_some()) {
            VALIDATOR_STATUS_ACTIVE
        } else if (find_validator(&validator_set.pending_inactive, pool_address).is_some()) {
            VALIDATOR_STATUS_PENDING_INACTIVE
        } else {
            VALIDATOR_STATUS_INACTIVE
        }
    }

    #[view]
    /// Return the voting power of the validator in the current epoch.
    /// PoC 读取已安装 ValidatorInfo 的当前权重；原生模式继续查询代币余额。
    public fun get_current_epoch_voting_power(
        pool_address: address
    ): u64 acquires InstalledRewardContext, StakePool, ValidatorSet {
        assert_stake_pool_exists(pool_address);
        if (is_poc_enabled()) {
            let set = borrow_global<ValidatorSet>(@topo_framework);
            let active = find_validator(&set.active_validators, pool_address);
            if (active.is_some()) { return set.active_validators[*active.borrow()].voting_power };
            let leaving = find_validator(&set.pending_inactive, pool_address);
            return if (leaving.is_some()) { set.pending_inactive[*leaving.borrow()].voting_power } else { 0 }
        };
        let validator_state = get_validator_state(pool_address);
        // Both active and pending inactive validators can still vote in the current epoch.
        if (validator_state == VALIDATOR_STATUS_ACTIVE
            || validator_state == VALIDATOR_STATUS_PENDING_INACTIVE) {
            let active_stake =
                coin::value(&borrow_global<StakePool>(pool_address).active);
            let pending_inactive_stake =
                coin::value(&borrow_global<StakePool>(pool_address).pending_inactive);
            active_stake + pending_inactive_stake
        } else { 0 }
    }

    #[view]
    /// Return the delegated voter of the validator at `pool_address`.
    public fun get_delegated_voter(pool_address: address): address acquires StakePool {
        assert_stake_pool_exists(pool_address);
        borrow_global<StakePool>(pool_address).delegated_voter
    }

    #[view]
    /// Return the operator of the validator at `pool_address`.
    public fun get_operator(pool_address: address): address acquires StakePool {
        assert_stake_pool_exists(pool_address);
        borrow_global<StakePool>(pool_address).operator_address
    }

    /// Return the pool address in `owner_cap`.
    public fun get_owned_pool_address(owner_cap: &OwnerCapability): address {
        owner_cap.pool_address
    }

    #[view]
    /// Return true if `owner` has an `OwnerCapability` resource.
    public fun owner_cap_exists(owner: address): bool {
        exists<OwnerCapability>(owner)
    }

    #[view]
    /// Return the pool address controlled by the `OwnerCapability` at `owner`.
    public fun get_pool_address_for_owner(owner: address): address acquires OwnerCapability {
        assert_owner_cap_exists(owner);
        OwnerCapability[owner].pool_address
    }

    #[view]
    /// Return the validator index for `pool_address`.
    public fun get_validator_index(pool_address: address): u64 acquires ValidatorConfig {
        assert_stake_pool_exists(pool_address);
        borrow_global<ValidatorConfig>(pool_address).validator_index
    }

    #[view]
    /// Return the number of successful and failed proposals for the proposal at the given validator index.
    public fun get_current_epoch_proposal_counts(
        validator_index: u64
    ): (u64, u64) acquires ValidatorPerformance {
        let validator_performances =
            &borrow_global<ValidatorPerformance>(@topo_framework).validators;
        let validator_performance = validator_performances.borrow(validator_index);
        (
            validator_performance.successful_proposals,
            validator_performance.failed_proposals
        )
    }

    #[view]
    /// Return the validator's config.
    public fun get_validator_config(
        pool_address: address
    ): (vector<u8>, vector<u8>, vector<u8>) acquires ValidatorConfig {
        assert_stake_pool_exists(pool_address);
        let validator_config = borrow_global<ValidatorConfig>(pool_address);
        (
            validator_config.consensus_pubkey,
            validator_config.network_addresses,
            validator_config.fullnode_addresses
        )
    }

    #[view]
    public fun stake_pool_exists(addr: address): bool {
        exists<StakePool>(addr)
    }

    #[view]
    /// Returns the pending transaction fee that is accumulated in current epoch.
    public fun get_pending_transaction_fee(): vector<u64> acquires PendingTransactionFee {
        let result = vector::empty();
        let fee_table =
            &borrow_global<PendingTransactionFee>(@topo_framework).pending_fee_by_validator;
        let num_validators = fee_table.compute_length();
        let i = 0;
        while (i < num_validators) {
            result.push_back(fee_table.borrow(&i).read());
            i += 1;
        };

        result
    }

    /// Initialize validator set to the core resource account.
    public(friend) fun initialize(topo_framework: &signer) {
        system_addresses::assert_topo_framework(topo_framework);

        move_to(
            topo_framework,
            ValidatorSet {
                consensus_scheme: 0,
                active_validators: vector::empty(),
                pending_active: vector::empty(),
                pending_inactive: vector::empty(),
                total_voting_power: 0,
                total_joining_power: 0
            }
        );

        move_to(topo_framework, ValidatorPerformance { validators: vector::empty() });
    }

    /// This is only called during Genesis, which is where MintCapability<TopoCoin> can be created.
    /// Beyond genesis, no one can create TopoCoin mint/burn capabilities.
    public(friend) fun store_topo_coin_mint_cap(
        topo_framework: &signer, mint_cap: MintCapability<TopoCoin>
    ) {
        system_addresses::assert_topo_framework(topo_framework);
        move_to(topo_framework, TopoCoinCapabilities { mint_cap })
    }

    /// Allow on chain governance to remove validators from the validator set.
    public fun remove_validators(
        topo_framework: &signer, validators: &vector<address>
    ) acquires ValidatorSet, VoluntaryLeaves {
        assert_reconfig_not_in_progress();
        system_addresses::assert_topo_framework(topo_framework);
        let validator_set = borrow_global_mut<ValidatorSet>(@topo_framework);
        let active_validators = &mut validator_set.active_validators;
        let pending_inactive = &mut validator_set.pending_inactive;
        spec {
            update ghost_active_num = len(active_validators);
            update ghost_pending_inactive_num = len(pending_inactive);
        };
        let len_validators = validators.length();
        let i = 0;
        // Remove each validator from the validator set.
        while ({
            spec {
                invariant i <= len_validators;
                invariant spec_validators_are_initialized(active_validators);
                invariant spec_validator_indices_are_valid(active_validators);
                invariant spec_validators_are_initialized(pending_inactive);
                invariant spec_validator_indices_are_valid(pending_inactive);
                invariant ghost_active_num == len(active_validators);
                invariant ghost_pending_inactive_num == len(pending_inactive);
                invariant ghost_active_num + ghost_pending_inactive_num
                    == len(active_validators) + len(pending_inactive);
                invariant len(active_validators) + len(pending_inactive)
                    == spec_validator_index_upper_bound();
            };
            i < len_validators
        }) {
            let validator = validators[i];
            // 池已在待退出队列时也要清除自主退出标记，防止运营者撤销治理移除。
            if (exists<VoluntaryLeaves>(@topo_framework)) {
                let requests = &mut borrow_global_mut<VoluntaryLeaves>(@topo_framework).requests;
                if (requests.contains(validator)) { requests.remove(validator); }
            };
            let validator_index = find_validator(active_validators, validator);
            if (validator_index.is_some()) {
                let validator_info =
                    active_validators.swap_remove(*validator_index.borrow());
                pending_inactive.push_back(validator_info);
                spec {
                    update ghost_active_num = ghost_active_num - 1;
                    update ghost_pending_inactive_num = ghost_pending_inactive_num + 1;
                };
            };
            i += 1;
        };
    }

    public fun initialize_pending_transaction_fee(framework: &signer) {
        assert_reconfig_not_in_progress();
        system_addresses::assert_topo_framework(framework);

        if (!exists<PendingTransactionFee>(@topo_framework)) {
            move_to(
                framework,
                PendingTransactionFee {
                    // The max leaf order is set to 10 because there is a existing limitation that a
                    // resource can only have 10 aggregators at max.
                    pending_fee_by_validator: big_ordered_map::new_with_config(
                        5, 10, true
                    )
                }
            );
        }
    }

    public fun set_transaction_fee_limit_per_epoch_per_pool(
        framework: &signer, limit_octa: u64
    ) acquires TransactionFeeConfig {
        system_addresses::assert_topo_framework(framework);

        let config = TransactionFeeConfig::V0 {
            max_fee_octa_allowed_per_epoch_per_pool: limit_octa
        };

        set_transaction_fee_config(framework, config);
    }

    /// 准备后校验部署奖励上限；当前 Epoch 仍按已安装上下文的费用限额分发。
    public fun set_transaction_fee_config(
        framework: &signer, config: TransactionFeeConfig
    ) acquires TransactionFeeConfig {
        assert_reconfig_not_in_progress();
        system_addresses::assert_topo_framework(framework);

        if (is_poc_prepared()) {
            let (n, d) = staking_config::get_reward_rate(&staking_config::get());
            let TransactionFeeConfig::V0 { max_fee_octa_allowed_per_epoch_per_pool } = &config;
            poc_accounting::validate_reward_config(n, d, *max_fee_octa_allowed_per_epoch_per_pool);
        };

        if (exists<TransactionFeeConfig>(@topo_framework)) {
            *borrow_global_mut<TransactionFeeConfig>(@topo_framework) = config;
        } else {
            move_to(framework, config);
        }
    }

    public(friend) fun record_fee(
        vm: &signer,
        fee_distribution_validator_indices: vector<u64>,
        fee_amounts_octa: vector<u64>
    ) acquires PendingTransactionFee {
        // Operational constraint: can only be invoked by the VM.
        system_addresses::assert_vm(vm);

        assert!(
            fee_distribution_validator_indices.length() == fee_amounts_octa.length()
        );

        let num_validators_to_distribute = fee_distribution_validator_indices.length();
        let pending_fee = borrow_global_mut<PendingTransactionFee>(@topo_framework);
        let i = 0;
        while (i < num_validators_to_distribute) {
            let validator_index = fee_distribution_validator_indices[i];
            let fee_octa = fee_amounts_octa[i];
            let fee = pending_fee.pending_fee_by_validator.borrow_mut(&validator_index);
            if (is_poc_prepared()) {
                // 累加器上限取自当前 Epoch 的奖励配置。优先并行累加，触顶时只补齐剩余额度，
                // 避免长期 Deferred 导致溢出；只限制可分发金额，不改变实际收费。
                if (!fee.try_add(fee_octa)) {
                    let remaining = fee.max_value() - fee.read();
                    fee.add(remaining);
                }
            } else {
                fee.add(fee_octa);
            };
            i += 1;
        }
    }

    /// Initialize the validator account and give ownership to the signing account
    /// except it leaves the ValidatorConfig to be set by another entity.
    /// Note: this triggers setting the operator and owner, set it to the account's address
    /// to set later.
    public entry fun initialize_stake_owner(
        owner: &signer,
        initial_stake_amount: u64,
        operator: address,
        voter: address
    ) acquires AllowedValidators, InstalledRewardContext, OwnerCapability, StakePool, ValidatorSet {
        initialize_owner(owner);
        move_to(
            owner,
            ValidatorConfig {
                consensus_pubkey: vector::empty(),
                network_addresses: vector::empty(),
                fullnode_addresses: vector::empty(),
                validator_index: 0
            }
        );

        if (initial_stake_amount > 0) {
            add_stake(owner, initial_stake_amount);
        };

        let account_address = signer::address_of(owner);
        if (account_address != operator) {
            set_operator(owner, operator)
        };
        if (account_address != voter) {
            set_delegated_voter(owner, voter)
        };
    }

    /// Initialize the validator account and give ownership to the signing account.
    public entry fun initialize_validator(
        account: &signer,
        consensus_pubkey: vector<u8>,
        proof_of_possession: vector<u8>,
        network_addresses: vector<u8>,
        fullnode_addresses: vector<u8>
    ) acquires AllowedValidators {
        // Checks the public key has a valid proof-of-possession to prevent rogue-key attacks.
        let pubkey_from_pop =
            &bls12381::public_key_from_bytes_with_pop(
                consensus_pubkey,
                &proof_of_possession_from_bytes(proof_of_possession)
            );
        assert!(
            pubkey_from_pop.is_some(), error::invalid_argument(EINVALID_PUBLIC_KEY)
        );

        initialize_owner(account);
        move_to(
            account,
            ValidatorConfig {
                consensus_pubkey,
                network_addresses,
                fullnode_addresses,
                validator_index: 0
            }
        );
    }

    fun initialize_owner(owner: &signer) acquires AllowedValidators {
        let owner_address = signer::address_of(owner);
        assert!(is_allowed(owner_address), error::not_found(EINELIGIBLE_VALIDATOR));
        assert!(
            !stake_pool_exists(owner_address),
            error::already_exists(EALREADY_REGISTERED)
        );

        move_to(
            owner,
            StakePool {
                active: coin::zero<TopoCoin>(),
                pending_active: coin::zero<TopoCoin>(),
                pending_inactive: coin::zero<TopoCoin>(),
                inactive: coin::zero<TopoCoin>(),
                locked_until_secs: 0,
                operator_address: owner_address,
                delegated_voter: owner_address,
                // Events.
                initialize_validator_events: account::new_event_handle<
                    RegisterValidatorCandidateEvent>(owner),
                set_operator_events: account::new_event_handle<SetOperatorEvent>(owner),
                add_stake_events: account::new_event_handle<AddStakeEvent>(owner),
                reactivate_stake_events: account::new_event_handle<ReactivateStakeEvent>(
                    owner
                ),
                rotate_consensus_key_events: account::new_event_handle<
                    RotateConsensusKeyEvent>(owner),
                update_network_and_fullnode_addresses_events: account::new_event_handle<
                    UpdateNetworkAndFullnodeAddressesEvent>(owner),
                increase_lockup_events: account::new_event_handle<IncreaseLockupEvent>(
                    owner
                ),
                join_validator_set_events: account::new_event_handle<JoinValidatorSetEvent>(
                    owner
                ),
                distribute_rewards_events: account::new_event_handle<DistributeRewardsEvent>(
                    owner
                ),
                unlock_stake_events: account::new_event_handle<UnlockStakeEvent>(owner),
                withdraw_stake_events: account::new_event_handle<WithdrawStakeEvent>(owner),
                leave_validator_set_events: account::new_event_handle<
                    LeaveValidatorSetEvent>(owner)
            }
        );

        move_to(owner, OwnerCapability { pool_address: owner_address });
    }

    /// Extract and return owner capability from the signing account.
    public fun extract_owner_cap(owner: &signer): OwnerCapability acquires OwnerCapability {
        let owner_address = signer::address_of(owner);
        assert_owner_cap_exists(owner_address);
        move_from<OwnerCapability>(owner_address)
    }

    /// Deposit `owner_cap` into `account`. This requires `account` to not already have ownership of another
    /// staking pool.
    public fun deposit_owner_cap(
        owner: &signer, owner_cap: OwnerCapability
    ) {
        assert!(
            !exists<OwnerCapability>(signer::address_of(owner)),
            error::not_found(EOWNER_CAP_ALREADY_EXISTS)
        );
        move_to(owner, owner_cap);
    }

    /// Destroy `owner_cap`.
    public fun destroy_owner_cap(owner_cap: OwnerCapability) {
        let OwnerCapability { pool_address: _ } = owner_cap;
    }

    /// Allows an owner to change the operator of the stake pool.
    public entry fun set_operator(
        owner: &signer, new_operator: address
    ) acquires OwnerCapability, StakePool {
        let owner_address = signer::address_of(owner);
        assert_owner_cap_exists(owner_address);
        let ownership_cap = borrow_global<OwnerCapability>(owner_address);
        set_operator_with_cap(ownership_cap, new_operator);
    }

    /// Allows an account with ownership capability to change the operator of the stake pool.
    public fun set_operator_with_cap(
        owner_cap: &OwnerCapability, new_operator: address
    ) acquires StakePool {
        let pool_address = owner_cap.pool_address;
        assert_stake_pool_exists(pool_address);
        let stake_pool = borrow_global_mut<StakePool>(pool_address);
        let old_operator = stake_pool.operator_address;
        stake_pool.operator_address = new_operator;

        event::emit(SetOperator { pool_address, old_operator, new_operator });
    }

    /// Allows an owner to change the delegated voter of the stake pool.
    public entry fun set_delegated_voter(
        owner: &signer, new_voter: address
    ) acquires OwnerCapability, StakePool {
        let owner_address = signer::address_of(owner);
        assert_owner_cap_exists(owner_address);
        let ownership_cap = borrow_global<OwnerCapability>(owner_address);
        set_delegated_voter_with_cap(ownership_cap, new_voter);
    }

    /// Allows an owner to change the delegated voter of the stake pool.
    public fun set_delegated_voter_with_cap(
        owner_cap: &OwnerCapability, new_voter: address
    ) acquires StakePool {
        let pool_address = owner_cap.pool_address;
        assert_stake_pool_exists(pool_address);
        let stake_pool = borrow_global_mut<StakePool>(pool_address);
        stake_pool.delegated_voter = new_voter;
    }

    /// Add `amount` of coins from the `account` owning the StakePool.
    public entry fun add_stake(
        owner: &signer, amount: u64
    ) acquires InstalledRewardContext, OwnerCapability, StakePool, ValidatorSet {
        let owner_address = signer::address_of(owner);
        assert_owner_cap_exists(owner_address);
        let ownership_cap = borrow_global<OwnerCapability>(owner_address);
        add_stake_with_cap(ownership_cap, coin::withdraw<TopoCoin>(owner, amount));
    }

    /// Add `coins` into `pool_address`. this requires the corresponding `owner_cap` to be passed in.
    public fun add_stake_with_cap(
        owner_cap: &OwnerCapability, coins: Coin<TopoCoin>
    ) acquires InstalledRewardContext, StakePool, ValidatorSet {
        assert_reconfig_not_in_progress();
        let pool_address = owner_cap.pool_address;
        assert_stake_pool_exists(pool_address);

        let amount = coin::value(&coins);
        if (amount == 0) {
            coin::destroy_zero(coins);
            return
        };

        // 当期奖励配置已固定；追加质押后仍须留足当期原生奖励的入账容量，避免阻塞后续换届。
        let native_reward_upper_bound_octa = get_native_reward_upper_bound(pool_address);
        if (native_reward_upper_bound_octa > 0) {
            assert!(total_stake_balance_octa(borrow_global<StakePool>(pool_address)) + (amount as u256)
                + (native_reward_upper_bound_octa as u256) <= (MAX_U64 as u256),
                error::invalid_argument(ENATIVE_REWARD_CAPACITY_EXCEEDED));
        };

        // Only track and validate voting power increase for active and pending_active validator.
        // Pending_inactive validator will be removed from the validator set in the next epoch.
        // Inactive validator's total stake will be tracked when they join the validator set.
        let validator_set = borrow_global<ValidatorSet>(@topo_framework);
        // Search directly rather using get_validator_state to save on unnecessary loops.
        if (find_validator(&validator_set.active_validators, pool_address).is_some()
            || find_validator(&validator_set.pending_active, pool_address).is_some()) {
            update_voting_power_increase(amount);
        };

        // Add to pending_active if it's a current validator because the stake is not counted until the next epoch.
        // Otherwise, the delegation can be added to active directly as the validator is also activated in the epoch.
        let stake_pool = borrow_global_mut<StakePool>(pool_address);
        if (is_current_epoch_validator(pool_address)) {
            coin::merge<TopoCoin>(&mut stake_pool.pending_active, coins);
        } else {
            coin::merge<TopoCoin>(&mut stake_pool.active, coins);
        };

        let (_, maximum_stake) =
            staking_config::get_required_stake(&staking_config::get());
        let voting_power = get_voting_power(stake_pool);
        assert!(
            voting_power <= maximum_stake, error::invalid_argument(ESTAKE_EXCEEDS_MAX)
        );

        event::emit(AddStake { pool_address, amount_added: amount });
    }

    /// Move `amount` of coins from pending_inactive to active.
    public entry fun reactivate_stake(owner: &signer, amount: u64) acquires OwnerCapability, StakePool {
        assert_reconfig_not_in_progress();
        let owner_address = signer::address_of(owner);
        assert_owner_cap_exists(owner_address);
        let ownership_cap = borrow_global<OwnerCapability>(owner_address);
        reactivate_stake_with_cap(ownership_cap, amount);
    }

    public fun reactivate_stake_with_cap(
        owner_cap: &OwnerCapability, amount: u64
    ) acquires StakePool {
        assert_reconfig_not_in_progress();
        let pool_address = owner_cap.pool_address;
        assert_stake_pool_exists(pool_address);

        // Cap the amount to reactivate by the amount in pending_inactive.
        let stake_pool = borrow_global_mut<StakePool>(pool_address);
        let total_pending_inactive = coin::value(&stake_pool.pending_inactive);
        amount = min(amount, total_pending_inactive);

        // Since this does not count as a voting power change (pending inactive still counts as voting power in the
        // current epoch), stake can be immediately moved from pending inactive to active.
        // We also don't need to check voting power increase as there's none.
        let reactivated_coins = coin::extract(&mut stake_pool.pending_inactive, amount);
        coin::merge(&mut stake_pool.active, reactivated_coins);

        event::emit(ReactivateStake { pool_address, amount });
    }

    /// Rotate the consensus key of the validator, it'll take effect in next epoch.
    public entry fun rotate_consensus_key(
        operator: &signer,
        pool_address: address,
        new_consensus_pubkey: vector<u8>,
        proof_of_possession: vector<u8>
    ) acquires StakePool, ValidatorConfig {
        assert_reconfig_not_in_progress();
        assert_stake_pool_exists(pool_address);

        let stake_pool = borrow_global_mut<StakePool>(pool_address);
        assert!(
            signer::address_of(operator) == stake_pool.operator_address,
            error::unauthenticated(ENOT_OPERATOR)
        );

        assert!(
            exists<ValidatorConfig>(pool_address),
            error::not_found(EVALIDATOR_CONFIG)
        );
        let validator_info = borrow_global_mut<ValidatorConfig>(pool_address);
        let old_consensus_pubkey = validator_info.consensus_pubkey;
        // Checks the public key has a valid proof-of-possession to prevent rogue-key attacks.
        let pubkey_from_pop =
            &bls12381::public_key_from_bytes_with_pop(
                new_consensus_pubkey,
                &proof_of_possession_from_bytes(proof_of_possession)
            );
        assert!(
            pubkey_from_pop.is_some(), error::invalid_argument(EINVALID_PUBLIC_KEY)
        );
        validator_info.consensus_pubkey = new_consensus_pubkey;

        event::emit(
            RotateConsensusKey { pool_address, old_consensus_pubkey, new_consensus_pubkey }
        );
    }

    /// Update the network and full node addresses of the validator. This only takes effect in the next epoch.
    public entry fun update_network_and_fullnode_addresses(
        operator: &signer,
        pool_address: address,
        new_network_addresses: vector<u8>,
        new_fullnode_addresses: vector<u8>
    ) acquires StakePool, ValidatorConfig {
        assert_reconfig_not_in_progress();
        assert_stake_pool_exists(pool_address);
        let stake_pool = borrow_global_mut<StakePool>(pool_address);
        assert!(
            signer::address_of(operator) == stake_pool.operator_address,
            error::unauthenticated(ENOT_OPERATOR)
        );
        assert!(
            exists<ValidatorConfig>(pool_address),
            error::not_found(EVALIDATOR_CONFIG)
        );
        let validator_info = borrow_global_mut<ValidatorConfig>(pool_address);
        let old_network_addresses = validator_info.network_addresses;
        validator_info.network_addresses = new_network_addresses;
        let old_fullnode_addresses = validator_info.fullnode_addresses;
        validator_info.fullnode_addresses = new_fullnode_addresses;

        event::emit(
            UpdateNetworkAndFullnodeAddresses {
                pool_address,
                old_network_addresses,
                new_network_addresses,
                old_fullnode_addresses,
                new_fullnode_addresses
            }
        );
    }

    /// Similar to increase_lockup_with_cap but will use ownership capability from the signing account.
    public entry fun increase_lockup(owner: &signer) acquires OwnerCapability, StakePool {
        let owner_address = signer::address_of(owner);
        assert_owner_cap_exists(owner_address);
        let ownership_cap = borrow_global<OwnerCapability>(owner_address);
        increase_lockup_with_cap(ownership_cap);
    }

    /// 用所有权能力延长锁仓；在此检查冻结状态，使质押、委托和归属合约的调用也受约束。
    public fun increase_lockup_with_cap(owner_cap: &OwnerCapability) acquires StakePool {
        assert_reconfig_not_in_progress();
        let pool_address = owner_cap.pool_address;
        assert_stake_pool_exists(pool_address);
        let config = staking_config::get();

        let stake_pool = borrow_global_mut<StakePool>(pool_address);
        let old_locked_until_secs = stake_pool.locked_until_secs;
        let new_locked_until_secs =
            timestamp::now_seconds()
                + staking_config::get_recurring_lockup_duration(&config);
        assert!(
            old_locked_until_secs < new_locked_until_secs,
            error::invalid_argument(EINVALID_LOCKUP)
        );
        stake_pool.locked_until_secs = new_locked_until_secs;

        event::emit(
            IncreaseLockup { pool_address, old_locked_until_secs, new_locked_until_secs }
        );
    }

    /// This can only called by the operator of the validator/staking pool.
    public entry fun join_validator_set(
        operator: &signer, pool_address: address
    ) acquires InstalledRewardContext, StakePool, ValidatorConfig, ValidatorSet {
        assert!(
            staking_config::get_allow_validator_set_change(&staking_config::get()),
            error::invalid_argument(ENO_POST_GENESIS_VALIDATOR_SET_CHANGE_ALLOWED)
        );

        join_validator_set_internal(operator, pool_address);
    }

    /// Request to have `pool_address` join the validator set. Can only be called after calling `initialize_validator`.
    /// If the validator has the required stake (more than minimum and less than maximum allowed), they will be
    /// added to the pending_active queue. All validators in this queue will be added to the active set when the next
    /// epoch starts (eligibility will be rechecked).
    ///
    /// This internal version can only be called by the Genesis module during Genesis.
    public(friend) fun join_validator_set_internal(
        operator: &signer, pool_address: address
    ) acquires InstalledRewardContext, StakePool, ValidatorConfig, ValidatorSet {
        assert_reconfig_not_in_progress();
        assert_stake_pool_exists(pool_address);
        let stake_pool = borrow_global_mut<StakePool>(pool_address);
        assert!(
            signer::address_of(operator) == stake_pool.operator_address,
            error::unauthenticated(ENOT_OPERATOR)
        );
        assert!(
            get_validator_state(pool_address) == VALIDATOR_STATUS_INACTIVE,
            error::invalid_state(EALREADY_ACTIVE_VALIDATOR)
        );

        let config = staking_config::get();
        let (minimum_stake, maximum_stake) = staking_config::get_required_stake(&config);
        // Settle any pending_inactive whose lockup has already expired so it is not counted
        // as voting power. An inactive validator's pending_inactive is never processed by
        // update_stake_pool, so we must do it here before evaluating the minimum stake.
        // Only settle when locked_until_secs > 0 (i.e., a lockup was ever explicitly set);
        // a value of 0 means the pool was just created and the lockup has not been initialised yet.
        if (stake_pool.locked_until_secs > 0
            && timestamp::now_seconds() >= stake_pool.locked_until_secs) {
            coin::merge(
                &mut stake_pool.inactive,
                coin::extract_all(&mut stake_pool.pending_inactive)
            );
        };
        let voting_power = get_voting_power(stake_pool);
        assert!(voting_power >= minimum_stake, error::invalid_argument(ESTAKE_TOO_LOW));
        assert!(voting_power <= maximum_stake, error::invalid_argument(ESTAKE_TOO_HIGH));

        // Track and validate voting power increase.
        update_voting_power_increase(voting_power);

        // Add validator to pending_active, to be activated in the next epoch.
        let validator_config = borrow_global<ValidatorConfig>(pool_address);
        assert!(
            !validator_config.consensus_pubkey.is_empty(),
            error::invalid_argument(EINVALID_PUBLIC_KEY)
        );

        // Validate the current validator set size has not exceeded the limit.
        let validator_set = borrow_global_mut<ValidatorSet>(@topo_framework);
        let validator_info = generate_validator_info(pool_address, stake_pool, *validator_config);
        // PoC 待加入者没有当前 Epoch 的投票权；其权重和增长预算由下一份计划决定。
        if (is_poc_enabled()) { validator_info.voting_power = 0 };
        validator_set.pending_active.push_back(validator_info);
        let validator_set_size =
            validator_set.active_validators.length()
                + validator_set.pending_active.length();
        assert!(
            validator_set_size <= MAX_VALIDATOR_SET_SIZE
                && (!is_poc_prepared() || validator_set_size <= poc_accounting::validator_limit()),
            error::invalid_argument(EVALIDATOR_SET_TOO_LARGE)
        );

        event::emit(JoinValidatorSet { pool_address });
    }

    /// Similar to unlock_with_cap but will use ownership capability from the signing account.
    public entry fun unlock(owner: &signer, amount: u64) acquires OwnerCapability, StakePool {
        assert_reconfig_not_in_progress();
        let owner_address = signer::address_of(owner);
        assert_owner_cap_exists(owner_address);
        let ownership_cap = borrow_global<OwnerCapability>(owner_address);
        unlock_with_cap(amount, ownership_cap);
    }

    /// Unlock `amount` from the active stake. Only possible if the lockup has expired.
    public fun unlock_with_cap(amount: u64, owner_cap: &OwnerCapability) acquires StakePool {
        assert_reconfig_not_in_progress();
        // Short-circuit if amount to unlock is 0 so we don't emit events.
        if (amount == 0) { return };

        // Unlocked coins are moved to pending_inactive. When the current lockup cycle expires, they will be moved into
        // inactive in the earliest possible epoch transition.
        let pool_address = owner_cap.pool_address;
        assert_stake_pool_exists(pool_address);
        let stake_pool = borrow_global_mut<StakePool>(pool_address);
        // Cap amount to unlock by maximum active stake.
        let amount = min(amount, coin::value(&stake_pool.active));
        let unlocked_stake = coin::extract(&mut stake_pool.active, amount);
        coin::merge<TopoCoin>(&mut stake_pool.pending_inactive, unlocked_stake);

        event::emit(UnlockStake { pool_address, amount_unlocked: amount });
    }

    /// Withdraw from `account`'s inactive stake.
    public entry fun withdraw(
        owner: &signer, withdraw_amount: u64
    ) acquires OwnerCapability, StakePool, ValidatorSet {
        let owner_address = signer::address_of(owner);
        assert_owner_cap_exists(owner_address);
        let ownership_cap = borrow_global<OwnerCapability>(owner_address);
        let coins = withdraw_with_cap(ownership_cap, withdraw_amount);
        coin::deposit<TopoCoin>(owner_address, coins);
    }

    /// Withdraw from `pool_address`'s inactive stake with the corresponding `owner_cap`.
    public fun withdraw_with_cap(
        owner_cap: &OwnerCapability, withdraw_amount: u64
    ): Coin<TopoCoin> acquires StakePool, ValidatorSet {
        assert_reconfig_not_in_progress();
        let pool_address = owner_cap.pool_address;
        assert_stake_pool_exists(pool_address);
        let stake_pool = borrow_global_mut<StakePool>(pool_address);
        // There's an edge case where a validator unlocks their stake and leaves the validator set before
        // the stake is fully unlocked (the current lockup cycle has not expired yet).
        // This can leave their stake stuck in pending_inactive even after the current lockup cycle expires.
        if (get_validator_state(pool_address) == VALIDATOR_STATUS_INACTIVE
            && timestamp::now_seconds() >= stake_pool.locked_until_secs) {
            let pending_inactive_stake =
                coin::extract_all(&mut stake_pool.pending_inactive);
            coin::merge(&mut stake_pool.inactive, pending_inactive_stake);
        };

        // Cap withdraw amount by total inactive coins.
        withdraw_amount = min(withdraw_amount, coin::value(&stake_pool.inactive));
        if (withdraw_amount == 0) return coin::zero<TopoCoin>();

        event::emit(WithdrawStake { pool_address, amount_withdrawn: withdraw_amount });

        coin::extract(&mut stake_pool.inactive, withdraw_amount)
    }

    /// 运营者申请下一 Epoch 退出，当前 Epoch 仍可投票并获得奖励。
    /// PoC 先校验退出后的完整目标；原生模式继续禁止最后一名在任者退出。
    public entry fun leave_validator_set(operator: &signer, pool_address: address) acquires InstalledRewardContext, StakePool, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        assert_reconfig_not_in_progress();
        assert!(staking_config::get_allow_validator_set_change(&staking_config::get()),
            error::invalid_argument(ENO_POST_GENESIS_VALIDATOR_SET_CHANGE_ALLOWED));
        assert!(get_operator(pool_address) == signer::address_of(operator), error::unauthenticated(ENOT_OPERATOR));
        let set = borrow_global<ValidatorSet>(@topo_framework);
        let pending = find_validator(&set.pending_active, pool_address);
        if (pending.is_some()) {
            // 允许在目标不合格时取消待加入申请，通过减少候选者缓解增长预算不足。
            let native_stake = if (is_poc_enabled()) { 0 } else { get_voting_power(borrow_global<StakePool>(pool_address)) };
            let set = borrow_global_mut<ValidatorSet>(@topo_framework);
            set.pending_active.swap_remove(pending.extract());
            // 原生取消申请仍保留舍入容差；PoC 的 native_stake 为零，不扣减代币增长额度。
            if (set.total_joining_power > (native_stake as u128)) { set.total_joining_power -= (native_stake as u128) }
            else { set.total_joining_power = 0 };
            return
        };
        let index = find_validator(&set.active_validators, pool_address);
        assert!(index.is_some(), error::invalid_state(ENOT_VALIDATOR));
        if (is_poc_enabled()) {
            let epoch = poc_accounting::current_epoch();
            let target = (epoch as u256) + 1;
            assert!(target <= (MAX_U64 as u256), error::invalid_state(EINVALID_POC_TARGET));
            // 使用换届构建器校验替补、人数和集中度，通过后才记录自主退出并调整队列。
            let preview = preview_transition(target as u64, timestamp::now_seconds(), option::some(pool_address));
            assert!(preview.reason == 0, error::invalid_state(EINVALID_POC_TARGET));
            borrow_global_mut<VoluntaryLeaves>(@topo_framework).requests.add(pool_address, epoch);
        } else {
            assert!(set.active_validators.length() > 1, error::invalid_state(ELAST_VALIDATOR));
        };
        let set = borrow_global_mut<ValidatorSet>(@topo_framework);
        let validator = set.active_validators.swap_remove(index.extract());
        set.pending_inactive.push_back(validator);
        event::emit(LeaveValidatorSet { pool_address });
    }

    /// Returns true if the current validator can still vote in the current epoch.
    /// This includes validators that requested to leave but are still in the pending_inactive queue and will be removed
    /// when the epoch starts.
    public fun is_current_epoch_validator(pool_address: address): bool acquires ValidatorSet {
        assert_stake_pool_exists(pool_address);
        let validator_state = get_validator_state(pool_address);
        validator_state == VALIDATOR_STATUS_ACTIVE
            || validator_state == VALIDATOR_STATUS_PENDING_INACTIVE
    }

    /// 区块入口按旧索引累计提案表现，忽略越界索引。
    /// 计数器达到 u64 上限后再次更新，会以 ECOUNTER_OVERFLOW 回滚整笔事务。
    public(friend) fun update_performance_statistics(
        proposer_index: Option<u64>, failed_proposer_indices: vector<u64>
    ) acquires ValidatorPerformance {
        // 新 Epoch 安装前，待退出成员仍按原索引累计表现。
        let validator_perf = borrow_global_mut<ValidatorPerformance>(@topo_framework);
        let validator_len = validator_perf.validators.length();

        spec {
            update ghost_valid_perf = validator_perf;
            update ghost_proposer_idx = proposer_index;
        };
        // NilBlock 可能没有提案者，因此 proposer_index 使用 Option。
        if (proposer_index.is_some()) {
            let cur_proposer_index = proposer_index.extract();
            // 跳过越界索引；有效索引仍须检查计数器递增是否超出 u64 范围。
            if (cur_proposer_index < validator_len) {
                let validator = validator_perf.validators.borrow_mut(cur_proposer_index);
                assert!(validator.successful_proposals < (MAX_U64 as u64), error::out_of_range(ECOUNTER_OVERFLOW));
                validator.successful_proposals += 1;
            };
        };

        let f = 0;
        let f_len = failed_proposer_indices.length();
        while ({
            spec {
                invariant f <= f_len;
                invariant len(validator_perf.validators) == validator_len;
                invariant forall i in 0..validator_len:
                    validator_perf.validators[i].failed_proposals == ghost_valid_perf.validators[i].failed_proposals
                        + spec_failure_count(failed_proposer_indices, i, f);
                invariant forall i in 0..validator_len:
                    validator_perf.validators[i].successful_proposals == ghost_valid_perf.validators[i].successful_proposals
                        + if (option::is_some(ghost_proposer_idx) && option::borrow(ghost_proposer_idx) == i) { 1 } else { 0 };
            };
            f < f_len
        }) {
            let validator_index = failed_proposer_indices[f];
            if (validator_index < validator_len) {
                spec {
                    assert spec_failure_count(failed_proposer_indices, validator_index, f + 1)
                        == spec_failure_count(failed_proposer_indices, validator_index, f) + 1;
                };
                let validator = validator_perf.validators.borrow_mut(validator_index);
                assert!(validator.failed_proposals < (MAX_U64 as u64), error::out_of_range(ECOUNTER_OVERFLOW));
                validator.failed_proposals += 1;
            };
            f += 1;
        };
    }

    /// PoC 准备前在此安装原生 Epoch；准备后统一通过计划提交。
    ///
    /// 先向在任和待退出成员分发费用并结算奖励，再处理待加入本金和到期退出本金。
    /// 新委员会接纳合格待加入者、移除待退出者，并按原生本金更新投票权重。
    public(friend) fun on_new_epoch() acquires PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        assert!(!is_poc_prepared(), error::invalid_state(EPLAN_MISMATCH));
        let validator_set = borrow_global_mut<ValidatorSet>(@topo_framework);
        let config = staking_config::get();
        let validator_perf = borrow_global_mut<ValidatorPerformance>(@topo_framework);

        // 在任和待退出成员都按原表现索引结算当前 Epoch 的奖励。
        settle_native_voters(validator_perf, &validator_set.active_validators, &config);
        settle_native_voters(validator_perf, &validator_set.pending_inactive, &config);

        // Settle expired pending_inactive for pending_active validators before activating them.
        // update_stake_pool is not called for pending_active validators, so without this step
        // their expired pending_inactive would be incorrectly counted as voting power, causing
        // a mismatch with the DKG validator set (which excludes expired pending_inactive) and
        // an out-of-bounds panic in the epoch manager.
        validator_set.pending_active.for_each_ref(|validator| {
            let validator: &ValidatorInfo = validator;
            let stake_pool = borrow_global_mut<StakePool>(validator.addr);
            if (stake_pool.locked_until_secs > 0
                && get_reconfig_start_time_secs() >= stake_pool.locked_until_secs) {
                coin::merge(
                    &mut stake_pool.inactive,
                    coin::extract_all(&mut stake_pool.pending_inactive)
                );
            };
        });

        // Activate currently pending_active validators.
        append(&mut validator_set.active_validators, &mut validator_set.pending_active);

        // Officially deactivate all pending_inactive validators. They will now no longer receive rewards.
        validator_set.pending_inactive = vector::empty();

        // Determine the next-epoch active set: either consume the cached value
        // produced when reconfig started (async/DKG path), or compute it now from
        // live state (sync/governance path). The two paths are mutually exclusive,
        // so we avoid the O(n) per-validator recomputation when the cache exists.
        let liveness_fallback_event = if (exists<PrecomputedValidatorSet>(@topo_framework)) {
            let PrecomputedValidatorSet { validator_set: precomputed, is_liveness_fallback } =
                move_from<PrecomputedValidatorSet>(@topo_framework);
            *validator_set = precomputed;
            if (is_liveness_fallback) {
                let (minimum_stake, _) = staking_config::get_required_stake(&config);
                option::some(ValidatorSetLivenessFallback {
                    minimum_stake,
                    emergency_validator_count: validator_set.active_validators.length(),
                    total_emergency_voting_power: validator_set.total_voting_power,
                })
            } else {
                option::none()
            }
        } else {
            refresh_validator_set_in_place(validator_set, &config)
        };
        validator_set.total_joining_power = 0;

        if (liveness_fallback_event.is_some()) {
            event::emit(liveness_fallback_event.extract());
        };

        // Update validator indices, reset performance scores, and renew lockups.
        validator_perf.validators = vector::empty();
        let recurring_lockup_duration_secs =
            staking_config::get_recurring_lockup_duration(&config);
        let vlen = validator_set.active_validators.length();
        let validator_index = 0;
        while ({
            spec {
                invariant len(validator_set.pending_active) == 0;
                invariant len(validator_set.pending_inactive) == 0;
                invariant 0 <= validator_index && validator_index <= vlen;
                invariant vlen == len(validator_set.active_validators);
                invariant old(exists<PrecomputedValidatorSet>(@topo_framework)) ==>
                    validator_set.active_validators
                        == old(global<PrecomputedValidatorSet>(@topo_framework)).validator_set.active_validators;
                invariant forall i in 0..validator_index:
                    exists<StakePool>(validator_set.active_validators[i].addr)
                        && exists<ValidatorConfig>(validator_set.active_validators[i].addr);
                invariant forall i in 0..validator_index:
                    global<ValidatorConfig>(validator_set.active_validators[i].addr).validator_index
                        < validator_index;
                invariant forall i in 0..validator_index:
                    validator_set.active_validators[i].config.validator_index
                        < validator_index;
                invariant len(validator_perf.validators) == validator_index;
            };
            validator_index < vlen
        }) {
            let validator_info =
                validator_set.active_validators.borrow_mut(validator_index);
            validator_info.config.validator_index = validator_index;
            let validator_config =
                borrow_global_mut<ValidatorConfig>(validator_info.addr);
            validator_config.validator_index = validator_index;

            validator_perf.validators.push_back(
                IndividualValidatorPerformance {
                    successful_proposals: 0,
                    failed_proposals: 0
                }
            );

            // Automatically renew a validator's lockup for validators that will still be in the validator set in the
            // next epoch.
            let stake_pool = borrow_global_mut<StakePool>(validator_info.addr);
            let now_secs = timestamp::now_seconds();
            let reconfig_start_secs =
                if (chain_status::is_operating()) {
                    get_reconfig_start_time_secs()
                } else {
                    now_secs
                };
            if (stake_pool.locked_until_secs <= reconfig_start_secs) {
                spec {
                    assume now_secs + recurring_lockup_duration_secs <= MAX_U64;
                };
                stake_pool.locked_until_secs = now_secs
                    + recurring_lockup_duration_secs;
            };

            validator_index += 1;
        };

        if (exists<PendingTransactionFee>(@topo_framework)) {
            let pending_fee_by_validator =
                &mut borrow_global_mut<PendingTransactionFee>(@topo_framework).pending_fee_by_validator;
            assert!(
                pending_fee_by_validator.is_empty(),
                error::internal(ETRANSACTION_FEE_NOT_FULLY_DISTRIBUTED)
            );
            validator_set.active_validators.for_each_ref(|v| pending_fee_by_validator.add(
                v.config.validator_index, aggregator_v2::create_unbounded_aggregator<u64>()
            ));
        };

        if (features::periodical_reward_rate_decrease_enabled()) {
            // Update rewards rate after reward distribution.
            staking_config::calculate_and_save_latest_epoch_rewards_rate();
        };
    }

    /// Compute the next-epoch active validator set in place from live `StakePool`/`ValidatorConfig` state.
    /// Used by `on_new_epoch` only on the sync (non-DKG) path; the async/DKG path consumes a
    /// pre-computed `PrecomputedValidatorSet` instead.
    /// Returns `Some(ValidatorSetLivenessFallback)` when the freshly-computed set was empty and we
    /// fell back to retaining the previous active set.
    fun refresh_validator_set_in_place(
        validator_set: &mut ValidatorSet,
        config: &staking_config::StakingConfig,
    ): Option<ValidatorSetLivenessFallback> acquires StakePool, ValidatorConfig {
        // Update active validator set so that network address/public key change takes effect.
        // Moreover, recalculate the total voting power, and deactivate the validator whose
        // voting power is less than the minimum required stake.
        let next_epoch_validators = vector::empty();
        let (minimum_stake, _) = staking_config::get_required_stake(config);
        let vlen = validator_set.active_validators.length();
        let total_voting_power = 0;
        let i = 0;
        while ({
            spec {
                invariant spec_validators_are_initialized(next_epoch_validators);
                invariant i <= vlen;
            };
            i < vlen
        }) {
            let old_validator_info = validator_set.active_validators.borrow_mut(i);
            let pool_address = old_validator_info.addr;
            let validator_config = borrow_global<ValidatorConfig>(pool_address);
            let stake_pool = borrow_global<StakePool>(pool_address);
            let new_validator_info =
                generate_validator_info(pool_address, stake_pool, *validator_config);

            // A validator needs at least the min stake required to join the validator set.
            if (new_validator_info.voting_power >= minimum_stake) {
                spec {
                    assume total_voting_power + new_validator_info.voting_power
                        <= MAX_U128;
                };
                total_voting_power +=(new_validator_info.voting_power as u128);
                next_epoch_validators.push_back(new_validator_info);
            };
            i += 1;
        };

        // In the extreme case where the next epoch validator election produces an empty set (i.e., no staker satisfies the minimum stake or participation requirements), the system enters an emergency liveness preservation mode.
        // Instead of transitioning to an empty validator set—which would render the network inoperable—the protocol retains the previous active validator set and recomputes the total voting power from it.
        // A ValidatorSetLivenessFallback event is emitted to signal this critical governance and economic security failure.
        if (!next_epoch_validators.is_empty()) {
            validator_set.active_validators = next_epoch_validators;
            validator_set.total_voting_power = total_voting_power;
            option::none()
        } else {
            // We derive the next validator set from the previous epoch's active and pending-active stakers.
            // If the resulting set is empty, it indicates that no staker is willing or qualified to participate
            // in consensus anymore. In this case, the chain is considered effectively dead, and we must retain
            // the previous active validator set as a last-resort liveness fallback.
            // Recompute each validator's info from current stake (after update_stake_pool) so that
            // voting_power and total_voting_power reflect rewards, fees, and merged stake—not stale values.
            let refreshed_validators = vector::empty();
            let emergency_total_voting_power = 0u128;
            let fallback_vlen = validator_set.active_validators.length();
            let fallback_i = 0;
            while ({
                spec {
                    invariant fallback_i <= fallback_vlen;
                    invariant spec_validators_are_initialized(refreshed_validators);
                };
                fallback_i < fallback_vlen
            }) {
                let old_validator_info =
                    validator_set.active_validators.borrow(fallback_i);
                let pool_address = old_validator_info.addr;
                let validator_config = &ValidatorConfig[pool_address];
                let stake_pool = &StakePool[pool_address];
                let new_validator_info =
                    generate_validator_info(pool_address, stake_pool, *validator_config);
                refreshed_validators.push_back(new_validator_info);
                emergency_total_voting_power +=(new_validator_info.voting_power as u128);
                fallback_i += 1;
            };
            validator_set.active_validators = refreshed_validators;
            validator_set.total_voting_power = emergency_total_voting_power;
            option::some(ValidatorSetLivenessFallback {
                minimum_stake,
                emergency_validator_count: validator_set.active_validators.length(),
                total_emergency_voting_power: validator_set.total_voting_power
            })
        }
    }

    /// Return the `ValidatorConsensusInfo` of each current validator, sorted by current validator index.
    public fun cur_validator_consensus_infos(): vector<ValidatorConsensusInfo> acquires ValidatorSet {
        let validator_set = borrow_global<ValidatorSet>(@topo_framework);
        validator_consensus_infos_from_validator_set(validator_set)
    }

    /// Compute simulated next-epoch voting power and ValidatorInfo for a candidate (no stake updates).
    /// If include_rewards, use validator_perf to add rewards for current validators; pending_active use false.
    fun compute_simulated_validator_info(
        candidate: &ValidatorInfo,
        validator_perf: &ValidatorPerformance,
        rewards_rate: u64,
        rewards_rate_denominator: u64,
        validator_index: u64,
        include_rewards: bool,
        cutoff_secs: u64
    ): (u64, ValidatorInfo) acquires StakePool, ValidatorConfig {
        let stake_pool = borrow_global<StakePool>(candidate.addr);
        let cur_active = coin::value(&stake_pool.active);
        let cur_pending_active = coin::value(&stake_pool.pending_active);
        let cur_pending_inactive = coin::value(&stake_pool.pending_inactive);
        let lockup_expired = cutoff_secs >= stake_pool.locked_until_secs;
        let retained_pending_inactive = if (lockup_expired) { 0 } else { cur_pending_inactive };
        let (active_reward, pending_inactive_reward) =
            if (include_rewards && (cur_active > 0 || retained_pending_inactive > 0)) {
                spec {
                    assert candidate.config.validator_index
                        < len(validator_perf.validators);
                };
                let cur_perf =
                    validator_perf.validators.borrow(candidate.config.validator_index);
                // 两个计数器各自保留完整 u64 范围，相加前先转为 u256。
                let total_proposals = (cur_perf.successful_proposals as u256)
                    + (cur_perf.failed_proposals as u256);
                // 原生结算对两部分本金分别取整；已到期部分连同奖励转为 inactive，不进入目标权重。
                let active_reward = reward_amount_wide(
                    cur_active,
                    cur_perf.successful_proposals,
                    total_proposals,
                    rewards_rate,
                    rewards_rate_denominator
                );
                let pending_inactive_reward = reward_amount_wide(
                    retained_pending_inactive,
                    cur_perf.successful_proposals,
                    total_proposals,
                    rewards_rate,
                    rewards_rate_denominator
                );
                (active_reward, pending_inactive_reward)
            } else { (0, 0) };
        spec {
            assume cur_active + retained_pending_inactive + cur_pending_active
                + active_reward + pending_inactive_reward <= MAX_U64;
        };
        let new_voting_power =
            cur_active + retained_pending_inactive + cur_pending_active
                + active_reward + pending_inactive_reward;
        let config = *borrow_global<ValidatorConfig>(candidate.addr);
        config.validator_index = validator_index;
        (
            new_voting_power,
            ValidatorInfo { addr: candidate.addr, voting_power: new_voting_power, config }
        )
    }

    /// Deprecated. Use next_validator_consensus_infos_v2() instead.
    public fun next_validator_consensus_infos(): vector<ValidatorConsensusInfo>  {
        abort(error::unavailable(EDEPRECATED))
    }

    /// 换届启动时读取目标：PoC 准备前按原生规则预计算，准备后只返回已校验的缓存。
    public(friend) fun next_validator_consensus_infos_v2(): ValidatorSet acquires EpochPlan, InstalledRewardContext, PrecomputedValidatorSet, StakePool, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        if (is_poc_prepared()) { return cached_validator_set() };
        if (exists<PrecomputedValidatorSet>(@topo_framework)) {
            return borrow_global<PrecomputedValidatorSet>(@topo_framework).validator_set
        };
        let (n, d) = staking_config::get_reward_rate(&staking_config::get());
        let (validator_set, is_liveness_fallback) = compute_native_next_validator_set(n, d, get_reconfig_start_time_secs());
        move_to(&create_signer::create_signer(@topo_framework),
            PrecomputedValidatorSet { validator_set, is_liveness_fallback });
        validator_set
    }

    /// 按传入的旧 Epoch 奖励率和截止时间只读计算原生目标，保留原生空集合回退规则。
    fun compute_native_next_validator_set(rewards_rate: u64, rewards_rate_denominator: u64,
        cutoff_secs: u64): (ValidatorSet, bool) acquires StakePool, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        let cur_validator_set = borrow_global<ValidatorSet>(@topo_framework);
        let staking_config = staking_config::get();
        let validator_perf = borrow_global<ValidatorPerformance>(@topo_framework);
        let (minimum_stake, _) = staking_config::get_required_stake(&staking_config);

        let new_active_validators = vector[];
        let num_new_actives = 0;
        let candidate_idx = 0;
        let new_total_power = 0;
        let num_cur_actives = cur_validator_set.active_validators.length();
        let num_cur_pending_actives = cur_validator_set.pending_active.length();
        spec {
            assume num_cur_actives + num_cur_pending_actives <= MAX_U64;
        };
        let num_candidates = num_cur_actives + num_cur_pending_actives;
        while ({
            spec {
                invariant candidate_idx <= num_candidates;
                invariant spec_validators_are_initialized(new_active_validators);
                invariant len(new_active_validators) == num_new_actives;
                invariant forall i in 0..len(new_active_validators):
                    new_active_validators[i].config.validator_index == i;
                invariant num_new_actives <= candidate_idx;
                invariant spec_validators_are_initialized(new_active_validators);
            };
            candidate_idx < num_candidates
        }) {
            let candidate_in_current = candidate_idx < num_cur_actives;
            // Order matches on_new_epoch's append(): active then pending_active (append uses pop_back → reverse).
            let candidate =
                if (candidate_in_current) {
                    cur_validator_set.active_validators.borrow(candidate_idx)
                } else {
                    cur_validator_set.pending_active.borrow(
                        num_candidates - 1 - candidate_idx
                    )
                };
            let (new_voting_power, new_validator_info) =
                compute_simulated_validator_info(
                    candidate,
                    validator_perf,
                    rewards_rate,
                    rewards_rate_denominator,
                    num_new_actives,
                    candidate_in_current,
                    cutoff_secs
                );
            if (new_voting_power >= minimum_stake) {
                spec {
                    assume new_total_power + new_voting_power <= MAX_U128;
                };
                new_total_power +=(new_voting_power as u128);
                new_active_validators.push_back(new_validator_info);
                num_new_actives += 1;
            };
            candidate_idx += 1;
        };

        // Mirror on_new_epoch's empty-validator-set fallback: active then pending_active.
        // append() uses pop_back so pending_active ends up in reverse order; match that here.
        let is_liveness_fallback = false;
        if (new_active_validators.is_empty()
            && (num_cur_actives > 0 || num_cur_pending_actives > 0)) {
            let num_fallback = num_cur_actives + num_cur_pending_actives;
            let fallback_idx = 0;
            while ({
                spec {
                    invariant fallback_idx <= num_fallback;
                    invariant len(new_active_validators) == fallback_idx;
                    invariant spec_validators_are_initialized(new_active_validators);
                    invariant forall i in 0..len(new_active_validators):
                        new_active_validators[i].config.validator_index == i;
                };
                fallback_idx < num_fallback
            }) {
                let in_active = fallback_idx < num_cur_actives;
                let candidate =
                    if (in_active) {
                        cur_validator_set.active_validators.borrow(fallback_idx)
                    } else {
                        cur_validator_set.pending_active.borrow(
                            num_fallback - 1 - fallback_idx
                        )
                    };
                let (new_voting_power, new_validator_info) =
                    compute_simulated_validator_info(
                        candidate,
                        validator_perf,
                        rewards_rate,
                        rewards_rate_denominator,
                        new_active_validators.length(),
                        in_active,
                        cutoff_secs
                    );
                new_active_validators.push_back(new_validator_info);
                new_total_power +=(new_voting_power as u128);
                is_liveness_fallback = true;
                fallback_idx += 1;
            };
        };

        let new_validator_set = ValidatorSet {
            consensus_scheme: cur_validator_set.consensus_scheme,
            active_validators: new_active_validators,
            pending_inactive: vector[],
            pending_active: vector[],
            total_voting_power: new_total_power,
            total_joining_power: 0
        };

        (new_validator_set, is_liveness_fallback)
    }

    friend fun validator_consensus_infos_from_validator_set(
        validator_set: &ValidatorSet
    ): vector<ValidatorConsensusInfo> {
        let validator_consensus_infos = vector[];

        let num_active = validator_set.active_validators.length();
        let num_pending_inactive = validator_set.pending_inactive.length();
        let total = num_active + num_pending_inactive;

        // Pre-fill the return value with dummy values.
        let idx = 0;
        while ({
            spec {
                invariant idx
                    <= len(validator_set.active_validators)
                        + len(validator_set.pending_inactive);
                invariant len(validator_consensus_infos) == idx;
                invariant len(validator_consensus_infos)
                    <= len(validator_set.active_validators)
                        + len(validator_set.pending_inactive);
            };
            idx < total
        }) {
            validator_consensus_infos.push_back(validator_consensus_info::default());
            idx += 1;
        };
        spec {
            assert len(validator_consensus_infos)
                == len(validator_set.active_validators)
                    + len(validator_set.pending_inactive);
            assert spec_validator_indices_are_valid_config(
                validator_set.active_validators,
                len(validator_set.active_validators)
                    + len(validator_set.pending_inactive)
            );
        };

        idx = 0;
        while ({
            spec {
                invariant idx <= len(validator_set.active_validators);
                invariant len(validator_consensus_infos) == total;
                invariant spec_target_indices(validator_set) ==>
                    (forall i in 0..idx:
                        spec_consensus_info_matches(
                            validator_consensus_infos[i], validator_set.active_validators[i]));
            };
            idx < num_active
        }) {
            let vi = &validator_set.active_validators[idx];
            validator_consensus_infos[vi.config.validator_index] = validator_consensus_info::new(
                vi.addr, vi.config.consensus_pubkey, vi.voting_power
            );
            idx += 1;
        };

        idx = 0;
        while ({
            spec {
                invariant idx <= len(validator_set.pending_inactive);
                invariant len(validator_consensus_infos) == total;
                invariant spec_target_indices(validator_set) ==>
                    (forall i in 0..len(validator_set.active_validators):
                        spec_consensus_info_matches(
                            validator_consensus_infos[i], validator_set.active_validators[i]));
            };
            idx < num_pending_inactive
        }) {
            let vi = &validator_set.pending_inactive[idx];
            validator_consensus_infos[vi.config.validator_index] = validator_consensus_info::new(
                vi.addr, vi.config.consensus_pubkey, vi.voting_power
            );
            idx += 1;
        };

        validator_consensus_infos
    }

    fun addresses_from_validator_infos(infos: &vector<ValidatorInfo>): vector<address> {
        infos.map_ref(|obj| {
            let info: &ValidatorInfo = obj;
            info.addr
        })
    }

    /// 按原队列顺序结算原生投票池，调用期间不重建索引或变更委员会。
    fun settle_native_voters(performance: &ValidatorPerformance, validators: &vector<ValidatorInfo>, config: &StakingConfig)
    acquires PendingTransactionFee, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig {
        let i = 0;
        while ({
            spec {
                invariant i <= len(validators);
                invariant exists<coin::CoinInfo<TopoCoin>>(@topo_framework);
            };
            i < validators.length()
        }) {
            update_stake_pool(performance, validators[i].addr, config);
            i += 1;
        }
    }

    /// PoC 准备前，按原生规则结算 Epoch 奖励、分发费用并处理本金。
    ///
    /// 对 active 和 pending_inactive 分别分发费用、计算奖励，再处理待加入和到期退出本金。
    fun update_stake_pool(
        validator_perf: &ValidatorPerformance,
        pool_address: address,
        staking_config: &StakingConfig
    ) acquires PendingTransactionFee, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig {
        let stake_pool = borrow_global_mut<StakePool>(pool_address);
        let validator_config = borrow_global<ValidatorConfig>(pool_address);
        let validator_index = validator_config.validator_index;
        let cur_validator_perf = validator_perf.validators.borrow(validator_index);
        let num_successful_proposals = cur_validator_perf.successful_proposals;

        let fee_pending_inactive = 0;
        let fee_active = 0;
        let fee_limit = transaction_fee_limit();

        if (exists<PendingTransactionFee>(@topo_framework)) {
            let pending_fee_by_validator =
                &mut borrow_global_mut<PendingTransactionFee>(@topo_framework).pending_fee_by_validator;
            if (pending_fee_by_validator.contains(&validator_index)) {
                let fee_octa = pending_fee_by_validator.remove(&validator_index).read();
                if (fee_octa > fee_limit) {
                    fee_octa = fee_limit;
                };
                let stake_active = (coin::value(&stake_pool.active) as u128);
                let stake_pending_inactive =
                    (coin::value(&stake_pool.pending_inactive) as u128);
                fee_pending_inactive =
                    (
                        ((fee_octa as u128) * stake_pending_inactive
                            / (stake_active + stake_pending_inactive)) as u64
                    );
                fee_active = fee_octa - fee_pending_inactive;
            }
        };

        let num_total_proposals = (cur_validator_perf.successful_proposals as u256)
            + (cur_validator_perf.failed_proposals as u256);
        let (rewards_rate, rewards_rate_denominator) =
            staking_config::get_reward_rate(staking_config);
        let rewards_active =
            distribute_rewards(
                &mut stake_pool.active,
                num_successful_proposals,
                num_total_proposals,
                rewards_rate,
                rewards_rate_denominator
            );
        let rewards_pending_inactive =
            distribute_rewards(
                &mut stake_pool.pending_inactive,
                num_successful_proposals,
                num_total_proposals,
                rewards_rate,
                rewards_rate_denominator
            );
        spec {
            assume rewards_active + rewards_pending_inactive <= MAX_U64;
        };

        if (std::features::is_distribute_transaction_fee_enabled()) {
            let mint_cap =
                &borrow_global<TopoCoinCapabilities>(@topo_framework).mint_cap;
            if (fee_active > 0) {
                coin::merge(&mut stake_pool.active, coin::mint(fee_active, mint_cap));
            };
            if (fee_pending_inactive > 0) {
                coin::merge(
                    &mut stake_pool.pending_inactive,
                    coin::mint(fee_pending_inactive, mint_cap)
                );
            };
            let fee_amount = fee_active + fee_pending_inactive;
            if (fee_amount > 0) {
                event::emit(DistributeTransactionFee { pool_address, fee_amount });
            };
        };

        let rewards_amount = rewards_active + rewards_pending_inactive;
        // Pending active stake can now be active.
        coin::merge(
            &mut stake_pool.active, coin::extract_all(&mut stake_pool.pending_active)
        );

        // Pending inactive stake is only fully unlocked and moved into inactive if the current lockup cycle has expired
        let current_lockup_expiration = stake_pool.locked_until_secs;
        if (get_reconfig_start_time_secs() >= current_lockup_expiration) {
            coin::merge(
                &mut stake_pool.inactive,
                coin::extract_all(&mut stake_pool.pending_inactive)
            );
        };

        event::emit(DistributeRewards { pool_address, rewards_amount });
    }

    /// Assuming we are in a middle of a reconfiguration (no matter it is immediate or async), get its start time.
    fun get_reconfig_start_time_secs(): u64 {
        if (reconfiguration_state::is_in_progress()) {
            reconfiguration_state::start_time_secs()
        } else {
            timestamp::now_seconds()
        }
    }

    /// Mint rewards corresponding to current epoch's `stake` and `num_successful_votes`.
    fun distribute_rewards(
        stake: &mut Coin<TopoCoin>,
        num_successful_proposals: u64,
        num_total_proposals: u256,
        rewards_rate: u64,
        rewards_rate_denominator: u64
    ): u64 acquires TopoCoinCapabilities {
        let stake_amount = coin::value(stake);
        let rewards_amount =
            if (stake_amount > 0) {
                reward_amount_wide(
                    stake_amount,
                    num_successful_proposals,
                    num_total_proposals,
                    rewards_rate,
                    rewards_rate_denominator
                )
            } else { 0 };
        if (rewards_amount > 0) {
            let mint_cap =
                &borrow_global<TopoCoinCapabilities>(@topo_framework).mint_cap;
            let rewards = coin::mint(rewards_amount, mint_cap);
            coin::merge(stake, rewards);
        };
        rewards_amount
    }

    fun append<T>(v1: &mut vector<T>, v2: &mut vector<T>) {
        while (!v2.is_empty()) {
            v1.push_back(v2.pop_back());
        }
    }

    fun find_validator(v: &vector<ValidatorInfo>, addr: address): Option<u64> {
        let i = 0;
        let len = v.length();
        while ({
            spec {
                invariant i <= len;
                invariant !(exists j in 0..i: v[j].addr == addr);
            };
            i < len
        }) {
            if (v.borrow(i).addr == addr) {
                return option::some(i)
            };
            i += 1;
        };
        option::none()
    }

    fun generate_validator_info(
        addr: address, stake_pool: &StakePool, config: ValidatorConfig
    ): ValidatorInfo {
        let voting_power = get_voting_power(stake_pool);
        ValidatorInfo { addr, voting_power, config }
    }

    /// Returns the sum of all non-inactive stake (active + pending_active + pending_inactive).
    /// This equals the actual voting power for the next epoch only when called after expired
    /// pending_inactive has been settled to inactive (e.g. in on_new_epoch or join_validator_set).
    fun get_voting_power(stake_pool: &StakePool): u64 {
        let value_pending_active = coin::value(&stake_pool.pending_active);
        let value_active = coin::value(&stake_pool.active);
        let value_pending_inactive = coin::value(&stake_pool.pending_inactive);
        spec {
            assume value_pending_active + value_active + value_pending_inactive
                <= MAX_U64;
        };
        value_pending_active + value_active + value_pending_inactive
    }

    /// 此处按原生代币累计增长额；PoC 算力的增长预算由计划计算，两种单位不能混用。
    fun update_voting_power_increase(increase_amount: u64) acquires InstalledRewardContext, ValidatorSet {
        if (is_poc_enabled()) { return };
        let validator_set = borrow_global_mut<ValidatorSet>(@topo_framework);
        let voting_power_increase_limit =
            (
                staking_config::get_voting_power_increase_limit(&staking_config::get()) as u128
            );
        validator_set.total_joining_power +=(increase_amount as u128);

        // Only validator voting power increase if the current validator set's voting power > 0.
        if (validator_set.total_voting_power > 0) {
            assert!(
                validator_set.total_joining_power
                    <= validator_set.total_voting_power * voting_power_increase_limit
                        / 100,
                error::invalid_argument(EVOTING_POWER_INCREASE_EXCEEDS_LIMIT)
            );
        }
    }

    fun assert_stake_pool_exists(pool_address: address) {
        assert!(
            stake_pool_exists(pool_address),
            error::invalid_argument(ESTAKE_POOL_DOES_NOT_EXIST)
        );
    }

    /// This provides an ACL for Testnet purposes. In testnet, everyone is a whale, a whale can be a validator.
    /// This allows a testnet to bring additional entities into the validator set without compromising the
    /// security of the testnet. This will NOT be enabled in Mainnet.
    struct AllowedValidators has key {
        accounts: vector<address>
    }

    public fun configure_allowed_validators(
        topo_framework: &signer, accounts: vector<address>
    ) acquires AllowedValidators {
        assert_reconfig_not_in_progress();
        let topo_framework_address = signer::address_of(topo_framework);
        system_addresses::assert_topo_framework(topo_framework);
        if (!exists<AllowedValidators>(topo_framework_address)) {
            move_to(topo_framework, AllowedValidators { accounts });
        } else {
            let allowed = borrow_global_mut<AllowedValidators>(topo_framework_address);
            allowed.accounts = accounts;
        }
    }

    fun is_allowed(account: address): bool acquires AllowedValidators {
        if (!exists<AllowedValidators>(@topo_framework)) { true }
        else {
            let allowed = borrow_global<AllowedValidators>(@topo_framework);
            allowed.accounts.contains(&account)
        }
    }

    fun assert_owner_cap_exists(owner: address) {
        assert!(
            exists<OwnerCapability>(owner),
            error::not_found(EOWNER_CAP_NOT_FOUND)
        );
    }

    fun assert_reconfig_not_in_progress() {
        assert!(
            !reconfiguration_state::is_in_progress(),
            error::invalid_state(ERECONFIGURATION_IN_PROGRESS)
        );
    }

    #[test_only]
    use topo_framework::topo_coin;
    use topo_std::bls12381::proof_of_possession_from_bytes;
    use topo_framework::reconfiguration_state;
    use topo_framework::validator_consensus_info;
    use topo_framework::validator_consensus_info::ValidatorConsensusInfo;
    #[test_only]
    use topo_std::fixed_point64;

    #[test_only]
    const EPOCH_DURATION: u64 = 60;

    #[test_only]
    const LOCKUP_CYCLE_SECONDS: u64 = 3600;

    #[test_only]
    public fun initialize_for_test(topo_framework: &signer) {
        reconfiguration_state::initialize(topo_framework);
        initialize_for_test_custom(
            topo_framework,
            100,
            10000,
            LOCKUP_CYCLE_SECONDS,
            true,
            1,
            100,
            1000000
        );
        // In the test environment, the periodical_reward_rate_decrease feature is initially turned off.
        features::change_feature_flags_for_testing(
            topo_framework,
            vector[],
            vector[features::get_periodical_reward_rate_decrease_feature()]
        );
    }

    #[test_only]
    public fun join_validator_set_for_test(
        pk: &bls12381::PublicKey,
        pop: &bls12381::ProofOfPossession,
        operator: &signer,
        pool_address: address,
        should_end_epoch: bool
    ) acquires EpochPlan, InstalledRewardContext, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        let pk_bytes = bls12381::public_key_to_bytes(pk);
        let pop_bytes = bls12381::proof_of_possession_to_bytes(pop);
        rotate_consensus_key(operator, pool_address, pk_bytes, pop_bytes);
        join_validator_set(operator, pool_address);
        if (should_end_epoch) {
            end_epoch();
        }
    }

    #[test_only]
    public fun fast_forward_to_unlock(
        pool_address: address
    ) acquires EpochPlan, InstalledRewardContext, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        let expiration_time = get_lockup_secs(pool_address);
        timestamp::update_global_time_for_test_secs(expiration_time);
        end_epoch();
    }

    // Convenient function for setting up all required stake initializations.
    #[test_only]
    public fun initialize_for_test_custom(
        topo_framework: &signer,
        minimum_stake: u64,
        maximum_stake: u64,
        recurring_lockup_secs: u64,
        allow_validator_set_change: bool,
        rewards_rate_numerator: u64,
        rewards_rate_denominator: u64,
        voting_power_increase_limit: u64
    ) {
        timestamp::set_time_has_started_for_testing(topo_framework);
        reconfiguration_state::initialize(topo_framework);
        if (!exists<ValidatorSet>(@topo_framework)) {
            initialize(topo_framework);
        };
        staking_config::initialize_for_test(
            topo_framework,
            minimum_stake,
            maximum_stake,
            recurring_lockup_secs,
            allow_validator_set_change,
            rewards_rate_numerator,
            rewards_rate_denominator,
            voting_power_increase_limit
        );

        if (!exists<TopoCoinCapabilities>(@topo_framework)) {
            let (burn_cap, mint_cap) = topo_coin::initialize_for_test(topo_framework);
            store_topo_coin_mint_cap(topo_framework, mint_cap);
            coin::destroy_burn_cap<TopoCoin>(burn_cap);
        };

        // In the test environment, the periodical_reward_rate_decrease feature is initially turned off.
        features::change_feature_flags_for_testing(
            topo_framework,
            vector[],
            vector[features::get_periodical_reward_rate_decrease_feature()]
        );
    }

    // This function assumes the stake module already the capability to mint aptos coins.
    #[test_only]
    public fun mint_coins(amount: u64): Coin<TopoCoin> acquires TopoCoinCapabilities {
        let mint_cap = &borrow_global<TopoCoinCapabilities>(@topo_framework).mint_cap;
        coin::mint(amount, mint_cap)
    }

    #[test_only]
    public fun mint(account: &signer, amount: u64) acquires TopoCoinCapabilities {
        coin::register<TopoCoin>(account);
        coin::deposit(signer::address_of(account), mint_coins(amount));
    }

    #[test_only]
    public fun mint_and_add_stake(
        account: &signer, amount: u64
    ) acquires InstalledRewardContext, OwnerCapability, StakePool, TopoCoinCapabilities, ValidatorSet {
        mint(account, amount);
        add_stake(account, amount);
    }

    #[test_only]
    public fun initialize_test_validator(
        public_key: &bls12381::PublicKey,
        proof_of_possession: &bls12381::ProofOfPossession,
        validator: &signer,
        amount: u64,
        should_join_validator_set: bool,
        should_end_epoch: bool
    ) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        let validator_address = signer::address_of(validator);
        account::create_account_for_test(validator_address);

        let pk_bytes = bls12381::public_key_to_bytes(public_key);
        let pop_bytes = bls12381::proof_of_possession_to_bytes(proof_of_possession);
        initialize_validator(
            validator,
            pk_bytes,
            pop_bytes,
            vector::empty(),
            vector::empty()
        );

        if (amount > 0) {
            mint_and_add_stake(validator, amount);
        };

        if (should_join_validator_set) {
            join_validator_set(validator, validator_address);
        };
        if (should_end_epoch) {
            end_epoch();
        };
    }

    #[test_only]
    public fun create_validator_set(
        topo_framework: &signer,
        active_validator_addresses: vector<address>,
        public_keys: vector<bls12381::PublicKey>
    ) {
        let active_validators = vector::empty<ValidatorInfo>();
        let i = 0;
        while (i < active_validator_addresses.length()) {
            let validator_address = active_validator_addresses.borrow(i);
            let pk = public_keys.borrow(i);
            active_validators.push_back(
                ValidatorInfo {
                    addr: *validator_address,
                    voting_power: 0,
                    config: ValidatorConfig {
                        consensus_pubkey: bls12381::public_key_to_bytes(pk),
                        network_addresses: b"",
                        fullnode_addresses: b"",
                        validator_index: 0
                    }
                }
            );
            i += 1;
        };

        move_to(
            topo_framework,
            ValidatorSet {
                consensus_scheme: 0,
                // active validators for the current epoch
                active_validators,
                // pending validators to leave in next epoch (still active)
                pending_inactive: vector::empty<ValidatorInfo>(),
                // pending validators to join in next epoch
                pending_active: vector::empty<ValidatorInfo>(),
                total_voting_power: 0,
                total_joining_power: 0
            }
        );
    }

    #[test_only]
    public fun create_stake_pool(
        account: &signer,
        active: Coin<TopoCoin>,
        pending_inactive: Coin<TopoCoin>,
        locked_until_secs: u64
    ) acquires AllowedValidators, InstalledRewardContext, OwnerCapability, StakePool, ValidatorSet {
        let account_address = signer::address_of(account);
        initialize_stake_owner(account, 0, account_address, account_address);
        let stake_pool = borrow_global_mut<StakePool>(account_address);
        coin::merge(&mut stake_pool.active, active);
        coin::merge(&mut stake_pool.pending_inactive, pending_inactive);
        stake_pool.locked_until_secs = locked_until_secs;
    }

    // Allows unit tests to set custom validator performances.
    #[test_only]
    public fun update_validator_performances_for_test(
        proposer_index: Option<u64>, failed_proposer_indices: vector<u64>
    ) acquires ValidatorPerformance {
        update_performance_statistics(proposer_index, failed_proposer_indices);
    }

    #[test_only]
    public fun generate_identity(): (
        bls12381::SecretKey, bls12381::PublicKey, bls12381::ProofOfPossession
    ) {
        let (sk, pkpop) = bls12381::generate_keys();
        let pop = bls12381::generate_proof_of_possession(&sk);
        let unvalidated_pk = bls12381::public_key_with_pop_to_normal(&pkpop);
        (sk, unvalidated_pk, pop)
    }

    #[test(topo_framework = @topo_framework, validator = @0x123)]
    #[expected_failure(abort_code = 0x10007, location = Self)]
    public entry fun test_inactive_validator_can_add_stake_if_exceeding_max_allowed(
        topo_framework: &signer, validator: &signer
    ) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        initialize_for_test(topo_framework);
        let (_sk, pk, pop) = generate_identity();
        initialize_test_validator(&pk, &pop, validator, 100, false, false);

        // Add more stake to exceed max. This should fail.
        mint_and_add_stake(validator, 9901);
    }

    #[test(topo_framework = @0x1, validator_1 = @0x123, validator_2 = @0x234)]
    #[expected_failure(abort_code = 0x10007, location = Self)]
    public entry fun test_pending_active_validator_cannot_add_stake_if_exceeding_max_allowed(
        topo_framework: &signer, validator_1: &signer, validator_2: &signer
    ) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        initialize_for_test_custom(
            topo_framework,
            50,
            10000,
            LOCKUP_CYCLE_SECONDS,
            true,
            1,
            10,
            100000
        );
        // Have one validator join the set to ensure the validator set is not empty when main validator joins.
        let (_sk_1, pk_1, pop_1) = generate_identity();
        initialize_test_validator(&pk_1, &pop_1, validator_1, 100, true, true);

        // Validator 2 joins validator set but epoch has not ended so validator is in pending_active state.
        let (_sk_2, pk_2, pop_2) = generate_identity();
        initialize_test_validator(&pk_2, &pop_2, validator_2, 100, true, false);

        // Add more stake to exceed max. This should fail.
        mint_and_add_stake(validator_2, 9901);
    }

    #[test(topo_framework = @topo_framework, validator = @0x123)]
    #[expected_failure(abort_code = 0x10007, location = Self)]
    public entry fun test_active_validator_cannot_add_stake_if_exceeding_max_allowed(
        topo_framework: &signer, validator: &signer
    ) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        initialize_for_test(topo_framework);
        // Validator joins validator set and waits for epoch end so it's in the validator set.
        let (_sk, pk, pop) = generate_identity();
        initialize_test_validator(&pk, &pop, validator, 100, true, true);

        // Add more stake to exceed max. This should fail.
        mint_and_add_stake(validator, 9901);
    }

    #[test(topo_framework = @topo_framework, validator = @0x123)]
    #[expected_failure(abort_code = 0x10007, location = Self)]
    public entry fun test_active_validator_with_pending_inactive_stake_cannot_add_stake_if_exceeding_max_allowed(
        topo_framework: &signer, validator: &signer
    ) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        initialize_for_test(topo_framework);
        // Validator joins validator set and waits for epoch end so it's in the validator set.
        let (_sk, pk, pop) = generate_identity();
        initialize_test_validator(&pk, &pop, validator, 100, true, true);

        // Request to unlock 50 coins, which go to pending_inactive. Validator has 50 remaining in active.
        unlock(validator, 50);
        assert_validator_state(signer::address_of(validator), 50, 0, 0, 50, 0);

        // Add 9901 more. Total stake is 50 (active) + 50 (pending_inactive) + 9901 > 10000 so still exceeding max.
        mint_and_add_stake(validator, 9901);
    }

    #[test(topo_framework = @topo_framework, validator_1 = @0x123, validator_2 = @0x234)]
    #[expected_failure(abort_code = 0x10007, location = Self)]
    public entry fun test_pending_inactive_cannot_add_stake_if_exceeding_max_allowed(
        topo_framework: &signer, validator_1: &signer, validator_2: &signer
    ) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        initialize_for_test(topo_framework);
        let (_sk_1, pk_1, pop_1) = generate_identity();
        let (_sk_2, pk_2, pop_2) = generate_identity();
        initialize_test_validator(&pk_1, &pop_1, validator_1, 100, true, false);
        initialize_test_validator(&pk_2, &pop_2, validator_2, 100, true, true);

        // Leave validator set so validator is in pending_inactive state.
        leave_validator_set(validator_1, signer::address_of(validator_1));

        // Add 9901 more. Total stake is 50 (active) + 50 (pending_inactive) + 9901 > 10000 so still exceeding max.
        mint_and_add_stake(validator_1, 9901);
    }

    #[test(topo_framework = @topo_framework, validator = @0x123)]
    public entry fun test_end_to_end(
        topo_framework: &signer, validator: &signer
    ) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        initialize_for_test(topo_framework);
        let (_sk, pk, pop) = generate_identity();
        initialize_test_validator(&pk, &pop, validator, 100, true, true);

        // Validator has a lockup now that they've joined the validator set.
        let validator_address = signer::address_of(validator);
        assert!(get_remaining_lockup_secs(validator_address) == LOCKUP_CYCLE_SECONDS, 1);

        // Validator adds more stake while already being active.
        // The added stake should go to pending_active to wait for activation when next epoch starts.
        mint(validator, 900);
        add_stake(validator, 100);
        assert!(coin::balance<TopoCoin>(validator_address) == 800, 2);
        assert_validator_state(validator_address, 100, 0, 100, 0, 0);

        // Pending_active stake is activated in the new epoch.
        // Rewards of 1 coin are also distributed for the existing active stake of 100 coins.
        end_epoch();
        assert!(get_validator_state(validator_address) == VALIDATOR_STATUS_ACTIVE, 3);
        assert_validator_state(validator_address, 201, 0, 0, 0, 0);

        // Request unlock of 100 coins. These 100 coins are moved to pending_inactive and will be unlocked when the
        // current lockup expires.
        unlock(validator, 100);
        assert_validator_state(validator_address, 101, 0, 0, 100, 0);

        // Enough time has passed so the current lockup cycle should have ended.
        // The first epoch after the lockup cycle ended should automatically move unlocked (pending_inactive) stake
        // to inactive.
        timestamp::fast_forward_seconds(LOCKUP_CYCLE_SECONDS);
        end_epoch();
        // Rewards were also minted to pending_inactive, which got all moved to inactive.
        assert_validator_state(validator_address, 102, 101, 0, 0, 0);
        // Lockup is renewed and validator is still active.
        assert!(get_validator_state(validator_address) == VALIDATOR_STATUS_ACTIVE, 4);
        assert!(get_remaining_lockup_secs(validator_address) == LOCKUP_CYCLE_SECONDS, 5);

        // Validator withdraws from inactive stake multiple times.
        withdraw(validator, 50);
        assert!(coin::balance<TopoCoin>(validator_address) == 850, 6);
        assert_validator_state(validator_address, 102, 51, 0, 0, 0);
        withdraw(validator, 51);
        assert!(coin::balance<TopoCoin>(validator_address) == 901, 7);
        assert_validator_state(validator_address, 102, 0, 0, 0, 0);

        // Enough time has passed again and the validator's lockup is renewed once more. Validator is still active.
        timestamp::fast_forward_seconds(LOCKUP_CYCLE_SECONDS);
        end_epoch();
        assert!(get_validator_state(validator_address) == VALIDATOR_STATUS_ACTIVE, 8);
        assert!(get_remaining_lockup_secs(validator_address) == LOCKUP_CYCLE_SECONDS, 9);
    }

    #[test(topo_framework = @topo_framework, validator = @0x123)]
    public entry fun test_inactive_validator_with_existing_lockup_join_validator_set(
        topo_framework: &signer, validator: &signer
    ) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        initialize_for_test(topo_framework);
        let (_sk, pk, pop) = generate_identity();
        initialize_test_validator(&pk, &pop, validator, 100, false, false);

        // Validator sets lockup before even joining the set and lets half of lockup pass by.
        increase_lockup(validator);
        timestamp::fast_forward_seconds(LOCKUP_CYCLE_SECONDS / 2);
        let validator_address = signer::address_of(validator);
        assert!(
            get_remaining_lockup_secs(validator_address) == LOCKUP_CYCLE_SECONDS / 2,
            1
        );

        // Join the validator set with an existing lockup
        join_validator_set(validator, validator_address);

        // Validator is added to the set but lockup time shouldn't have changed.
        end_epoch();
        assert!(get_validator_state(validator_address) == VALIDATOR_STATUS_ACTIVE, 2);
        assert!(
            get_remaining_lockup_secs(validator_address)
                == LOCKUP_CYCLE_SECONDS / 2 - EPOCH_DURATION,
            3
        );
        assert_validator_state(validator_address, 100, 0, 0, 0, 0);
    }

    #[test(topo_framework = @topo_framework, validator = @0x123)]
    #[expected_failure(abort_code = 0x10012, location = Self)]
    public entry fun test_cannot_reduce_lockup(
        topo_framework: &signer, validator: &signer
    ) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        initialize_for_test(topo_framework);
        let (_sk, pk, pop) = generate_identity();
        initialize_test_validator(&pk, &pop, validator, 100, false, false);

        // Increase lockup.
        increase_lockup(validator);
        // Reduce recurring lockup to 0.
        staking_config::update_recurring_lockup_duration_secs(topo_framework, 1);
        // INcrease lockup should now fail because the new lockup < old lockup.
        increase_lockup(validator);
    }

    #[test(topo_framework = @topo_framework, validator_1 = @0x123, validator_2 = @0x234)]
    #[expected_failure(abort_code = 0x1000D, location = Self)]
    public entry fun test_inactive_validator_cannot_join_if_exceed_increase_limit(
        topo_framework: &signer, validator_1: &signer, validator_2: &signer
    ) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        // Only 50% voting power increase is allowed in each epoch.
        initialize_for_test_custom(
            topo_framework,
            50,
            10000,
            LOCKUP_CYCLE_SECONDS,
            true,
            1,
            10,
            50
        );
        let (_sk_1, pk_1, pop_1) = generate_identity();
        let (_sk_2, pk_2, pop_2) = generate_identity();
        initialize_test_validator(&pk_1, &pop_1, validator_1, 100, false, false);
        initialize_test_validator(&pk_2, &pop_2, validator_2, 100, false, false);

        // Validator 1 needs to be in the set so validator 2's added stake counts against the limit.
        join_validator_set(validator_1, signer::address_of(validator_1));
        end_epoch();

        // Validator 2 joins the validator set but their stake would lead to exceeding the voting power increase limit.
        // Therefore, this should fail.
        join_validator_set(validator_2, signer::address_of(validator_2));
    }

    #[test(topo_framework = @topo_framework, validator_1 = @0x123, validator_2 = @0x234)]
    public entry fun test_pending_active_validator_can_add_more_stake(
        topo_framework: &signer, validator_1: &signer, validator_2: &signer
    ) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        initialize_for_test_custom(
            topo_framework,
            50,
            10000,
            LOCKUP_CYCLE_SECONDS,
            true,
            1,
            10,
            10000
        );
        // Need 1 validator to be in the active validator set so joining limit works.
        let (_sk_1, pk_1, pop_1) = generate_identity();
        let (_sk_2, pk_2, pop_2) = generate_identity();
        initialize_test_validator(&pk_1, &pop_1, validator_1, 100, false, true);
        initialize_test_validator(&pk_2, &pop_2, validator_2, 100, false, false);

        // Add more stake while still pending_active.
        let validator_2_address = signer::address_of(validator_2);
        join_validator_set(validator_2, validator_2_address);
        assert!(
            get_validator_state(validator_2_address) == VALIDATOR_STATUS_PENDING_ACTIVE,
            0
        );
        mint_and_add_stake(validator_2, 100);
        assert_validator_state(validator_2_address, 200, 0, 0, 0, 0);
    }

    #[test(topo_framework = @topo_framework, validator_1 = @0x123, validator_2 = @0x234)]
    #[expected_failure(abort_code = 0x1000D, location = Self)]
    public entry fun test_pending_active_validator_cannot_add_more_stake_than_limit(
        topo_framework: &signer, validator_1: &signer, validator_2: &signer
    ) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        // 100% voting power increase is allowed in each epoch.
        initialize_for_test_custom(
            topo_framework,
            50,
            10000,
            LOCKUP_CYCLE_SECONDS,
            true,
            1,
            10,
            100
        );
        // Need 1 validator to be in the active validator set so joining limit works.
        let (_sk_1, pk_1, pop_1) = generate_identity();
        initialize_test_validator(&pk_1, &pop_1, validator_1, 100, true, true);

        // Validator 2 joins the validator set but epoch has not ended so they're still pending_active.
        // Current voting power increase is already 100%. This is not failing yet.
        let (_sk_2, pk_2, pop_2) = generate_identity();
        initialize_test_validator(&pk_2, &pop_2, validator_2, 100, true, false);

        // Add more stake, which now exceeds the 100% limit. This should fail.
        mint_and_add_stake(validator_2, 1);
    }

    #[test(topo_framework = @topo_framework, validator = @0x123)]
    public entry fun test_pending_active_validator_leaves_validator_set(
        topo_framework: &signer, validator: &signer
    ) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        initialize_for_test(topo_framework);
        // Validator joins but epoch hasn't ended, so the validator is still pending_active.
        let (_sk, pk, pop) = generate_identity();
        initialize_test_validator(&pk, &pop, validator, 100, true, false);
        let validator_address = signer::address_of(validator);
        assert!(
            get_validator_state(validator_address) == VALIDATOR_STATUS_PENDING_ACTIVE,
            0
        );

        // Check that voting power increase is tracked.
        assert!(
            borrow_global<ValidatorSet>(@topo_framework).total_joining_power == 100, 0
        );

        // Leave the validator set immediately.
        leave_validator_set(validator, validator_address);
        assert!(get_validator_state(validator_address) == VALIDATOR_STATUS_INACTIVE, 1);

        // Check that voting power increase has been decreased when the pending active validator leaves.
        assert!(
            borrow_global<ValidatorSet>(@topo_framework).total_joining_power == 0, 1
        );
    }

    #[test(topo_framework = @topo_framework, validator = @0x123)]
    #[expected_failure(abort_code = 0x1000D, location = Self)]
    public entry fun test_active_validator_cannot_add_more_stake_than_limit_in_multiple_epochs(
        topo_framework: &signer, validator: &signer
    ) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        // Only 50% voting power increase is allowed in each epoch.
        initialize_for_test_custom(
            topo_framework,
            50,
            10000,
            LOCKUP_CYCLE_SECONDS,
            true,
            1,
            10,
            50
        );
        // Add initial stake and join the validator set.
        let (_sk, pk, pop) = generate_identity();
        initialize_test_validator(&pk, &pop, validator, 100, true, true);

        let validator_address = signer::address_of(validator);
        assert_validator_state(validator_address, 100, 0, 0, 0, 0);
        end_epoch();
        assert_validator_state(validator_address, 110, 0, 0, 0, 0);
        end_epoch();
        assert_validator_state(validator_address, 121, 0, 0, 0, 0);
        // Add more than 50% limit. The following line should fail.
        mint_and_add_stake(validator, 99);
    }

    #[test(topo_framework = @topo_framework, validator = @0x123)]
    #[expected_failure(abort_code = 0x1000D, location = Self)]
    public entry fun test_active_validator_cannot_add_more_stake_than_limit(
        topo_framework: &signer, validator: &signer
    ) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        // Only 50% voting power increase is allowed in each epoch.
        initialize_for_test_custom(
            topo_framework,
            50,
            10000,
            LOCKUP_CYCLE_SECONDS,
            true,
            1,
            10,
            50
        );
        let (_sk, pk, pop) = generate_identity();
        initialize_test_validator(&pk, &pop, validator, 100, true, true);

        // Add more than 50% limit. This should fail.
        mint_and_add_stake(validator, 51);
    }

    #[test(topo_framework = @topo_framework, validator = @0x123)]
    public entry fun test_active_validator_unlock_partial_stake(
        topo_framework: &signer, validator: &signer
    ) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        // Reward rate = 10%.
        initialize_for_test_custom(
            topo_framework,
            50,
            10000,
            LOCKUP_CYCLE_SECONDS,
            true,
            1,
            10,
            100
        );
        let (_sk, pk, pop) = generate_identity();
        initialize_test_validator(&pk, &pop, validator, 100, true, true);

        // Unlock half of the coins.
        let validator_address = signer::address_of(validator);
        assert!(get_remaining_lockup_secs(validator_address) == LOCKUP_CYCLE_SECONDS, 1);
        unlock(validator, 50);
        assert_validator_state(validator_address, 50, 0, 0, 50, 0);

        // Enough time has passed so the current lockup cycle should have ended.
        // 50 coins should have unlocked while the remaining 51 (50 + rewards) should stay locked for another cycle.
        timestamp::fast_forward_seconds(LOCKUP_CYCLE_SECONDS);
        end_epoch();
        assert!(get_validator_state(validator_address) == VALIDATOR_STATUS_ACTIVE, 2);
        // Validator received rewards in both active and pending inactive.
        assert_validator_state(validator_address, 55, 55, 0, 0, 0);
        assert!(get_remaining_lockup_secs(validator_address) == LOCKUP_CYCLE_SECONDS, 3);
    }

    #[test(topo_framework = @topo_framework, validator = @0x123, validator_2 = @0x234)]
    public entry fun test_active_validator_can_withdraw_all_stake_and_rewards_at_once(
        topo_framework: &signer, validator: &signer, validator_2: &signer
    ) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        initialize_for_test(topo_framework);
        let (_sk, pk, pop) = generate_identity();
        let (_sk_2, pk_2, pop_2) = generate_identity();
        initialize_test_validator(&pk, &pop, validator, 100, true, false);
        initialize_test_validator(&pk_2, &pop_2, validator_2, 100, true, true);
        let validator_address = signer::address_of(validator);
        assert!(get_remaining_lockup_secs(validator_address) == LOCKUP_CYCLE_SECONDS, 0);

        // One more epoch passes to generate rewards.
        end_epoch();
        assert!(get_validator_state(validator_address) == VALIDATOR_STATUS_ACTIVE, 1);
        assert_validator_state(validator_address, 101, 0, 0, 0, 1);

        // Unlock all coins while still having a lockup.
        assert!(
            get_remaining_lockup_secs(validator_address)
                == LOCKUP_CYCLE_SECONDS - EPOCH_DURATION,
            2
        );
        unlock(validator, 101);
        assert_validator_state(validator_address, 0, 0, 0, 101, 1);

        // One more epoch passes while the current lockup cycle (3600 secs) has not ended.
        timestamp::fast_forward_seconds(1000);
        end_epoch();
        // Validator should not be removed from the validator set since their 100 coins in pending_inactive state should
        // still count toward voting power.
        assert!(get_validator_state(validator_address) == VALIDATOR_STATUS_ACTIVE, 3);
        assert_validator_state(validator_address, 0, 0, 0, 102, 1);

        // Enough time has passed so the current lockup cycle should have ended. Funds are now fully unlocked.
        timestamp::fast_forward_seconds(LOCKUP_CYCLE_SECONDS);
        end_epoch();
        assert_validator_state(validator_address, 0, 103, 0, 0, 1);
        // Validator ahs been kicked out of the validator set as their stake is 0 now.
        assert!(get_validator_state(validator_address) == VALIDATOR_STATUS_INACTIVE, 4);
    }

    #[test(topo_framework = @topo_framework, validator = @0x123)]
    public entry fun test_active_validator_unlocking_more_than_available_stake_should_cap(
        topo_framework: &signer, validator: &signer
    ) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        initialize_for_test(topo_framework);
        let (_sk, pk, pop) = generate_identity();
        initialize_test_validator(&pk, &pop, validator, 100, false, false);

        // Validator unlocks more stake than they have active. This should limit the unlock to 100.
        unlock(validator, 200);
        assert_validator_state(signer::address_of(validator), 0, 0, 0, 100, 0);
    }

    #[test(topo_framework = @topo_framework, validator = @0x123)]
    public entry fun test_active_validator_withdraw_should_cap_by_inactive_stake(
        topo_framework: &signer, validator: &signer
    ) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        initialize_for_test(topo_framework);
        // Initial balance = 900 (idle) + 100 (staked) = 1000.
        let (_sk, pk, pop) = generate_identity();
        initialize_test_validator(&pk, &pop, validator, 100, true, true);
        mint(validator, 900);

        // Validator unlocks stake.
        unlock(validator, 100);
        // Enough time has passed so the stake is fully unlocked.
        timestamp::fast_forward_seconds(LOCKUP_CYCLE_SECONDS);
        end_epoch();

        // Validator can only withdraw a max of 100 unlocked coins even if they request to withdraw more than 100.
        withdraw(validator, 200);
        let validator_address = signer::address_of(validator);
        // Receive back all coins with an extra 1 for rewards.
        assert!(coin::balance<TopoCoin>(validator_address) == 1001, 2);
        assert_validator_state(validator_address, 0, 0, 0, 0, 0);
    }

    #[test(topo_framework = @topo_framework, validator = @0x123)]
    public entry fun test_active_validator_can_reactivate_pending_inactive_stake(
        topo_framework: &signer, validator: &signer
    ) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        initialize_for_test(topo_framework);
        let (_sk, pk, pop) = generate_identity();
        initialize_test_validator(&pk, &pop, validator, 100, true, true);

        // Validator unlocks stake, which gets moved into pending_inactive.
        unlock(validator, 50);
        let validator_address = signer::address_of(validator);
        assert_validator_state(validator_address, 50, 0, 0, 50, 0);

        // Validator can reactivate pending_inactive stake.
        reactivate_stake(validator, 50);
        assert_validator_state(validator_address, 100, 0, 0, 0, 0);
    }

    #[test(topo_framework = @topo_framework, validator = @0x123)]
    public entry fun test_active_validator_reactivate_more_than_available_pending_inactive_stake_should_cap(
        topo_framework: &signer, validator: &signer
    ) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        initialize_for_test(topo_framework);
        let (_sk, pk, pop) = generate_identity();
        initialize_test_validator(&pk, &pop, validator, 100, true, true);

        // Validator tries to reactivate more than available pending_inactive stake, which should limit to 50.
        unlock(validator, 50);
        let validator_address = signer::address_of(validator);
        assert_validator_state(validator_address, 50, 0, 0, 50, 0);
        reactivate_stake(validator, 51);
        assert_validator_state(validator_address, 100, 0, 0, 0, 0);
    }

    #[test(topo_framework = @topo_framework, validator = @0x123, validator_2 = @0x234)]
    public entry fun test_active_validator_having_insufficient_remaining_stake_after_withdrawal_gets_kicked(
        topo_framework: &signer, validator: &signer, validator_2: &signer
    ) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        initialize_for_test(topo_framework);
        let (_sk, pk, pop) = generate_identity();
        let (_sk_2, pk_2, pop_2) = generate_identity();
        initialize_test_validator(&pk, &pop, validator, 100, true, false);
        initialize_test_validator(&pk_2, &pop_2, validator_2, 100, true, true);

        // Unlock enough coins that the remaining is not enough to meet the min required.
        let validator_address = signer::address_of(validator);
        assert!(get_remaining_lockup_secs(validator_address) == LOCKUP_CYCLE_SECONDS, 1);
        unlock(validator, 50);
        assert_validator_state(validator_address, 50, 0, 0, 50, 1);

        // Enough time has passed so the current lockup cycle should have ended.
        // 50 coins should have unlocked while the remaining 51 (50 + rewards) is not enough so the validator is kicked
        // from the validator set.
        assert!(get_validator_state(validator_address) == VALIDATOR_STATUS_ACTIVE, 2);
        timestamp::fast_forward_seconds(LOCKUP_CYCLE_SECONDS);
        end_epoch();
        assert!(get_validator_state(validator_address) == VALIDATOR_STATUS_INACTIVE, 2);
        assert_validator_state(validator_address, 50, 50, 0, 0, 1);
        // Lockup is no longer renewed since the validator is no longer a part of the validator set.
        assert!(get_remaining_lockup_secs(validator_address) == 0, 3);
    }

    #[test(topo_framework = @topo_framework, validator = @0x123, validator_2 = @0x234)]
    public entry fun test_active_validator_leaves_staking_but_still_has_a_lockup(
        topo_framework: &signer, validator: &signer, validator_2: &signer
    ) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        initialize_for_test(topo_framework);
        let (_sk_1, pk_1, pop_1) = generate_identity();
        let (_sk_2, pk_2, pop_2) = generate_identity();
        initialize_test_validator(&pk_1, &pop_1, validator, 100, true, false);
        // We need a second validator here just so the first validator can leave.
        initialize_test_validator(&pk_2, &pop_2, validator_2, 100, true, true);

        // Leave the validator set while still having a lockup.
        let validator_address = signer::address_of(validator);
        assert!(get_remaining_lockup_secs(validator_address) == LOCKUP_CYCLE_SECONDS, 0);
        leave_validator_set(validator, validator_address);
        // Validator is in pending_inactive state but is technically still part of the validator set.
        assert!(
            get_validator_state(validator_address) == VALIDATOR_STATUS_PENDING_INACTIVE,
            2
        );
        assert_validator_state(validator_address, 100, 0, 0, 0, 1);
        end_epoch();

        // Epoch has ended so validator is no longer part of the validator set.
        assert!(get_validator_state(validator_address) == VALIDATOR_STATUS_INACTIVE, 3);
        // However, their stake, including rewards, should still subject to the existing lockup.
        assert_validator_state(validator_address, 101, 0, 0, 0, 1);
        assert!(
            get_remaining_lockup_secs(validator_address)
                == LOCKUP_CYCLE_SECONDS - EPOCH_DURATION,
            4
        );

        // If they try to unlock, their stake is moved to pending_inactive and would only be withdrawable after the
        // lockup has expired.
        unlock(validator, 50);
        assert_validator_state(validator_address, 51, 0, 0, 50, 1);
        // A couple of epochs passed but lockup has not expired so the validator's stake remains the same.
        end_epoch();
        end_epoch();
        end_epoch();
        assert_validator_state(validator_address, 51, 0, 0, 50, 1);
        // Fast forward enough so the lockup expires. Now the validator can just call withdraw directly to withdraw
        // pending_inactive stakes.
        timestamp::fast_forward_seconds(LOCKUP_CYCLE_SECONDS);
        withdraw(validator, 50);
        assert_validator_state(validator_address, 51, 0, 0, 0, 1);
    }

    #[test(topo_framework = @topo_framework, validator = @0x123, validator_2 = @0x234)]
    public entry fun test_active_validator_leaves_staking_and_rejoins_with_expired_lockup_should_be_renewed(
        topo_framework: &signer, validator: &signer, validator_2: &signer
    ) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        initialize_for_test(topo_framework);
        let (_sk_1, pk_1, pop_1) = generate_identity();
        let (_sk_2, pk_2, pop_2) = generate_identity();
        initialize_test_validator(&pk_1, &pop_1, validator, 100, true, false);
        // We need a second validator here just so the first validator can leave.
        initialize_test_validator(&pk_2, &pop_2, validator_2, 100, true, true);

        // Leave the validator set while still having a lockup.
        let validator_address = signer::address_of(validator);
        assert!(get_remaining_lockup_secs(validator_address) == LOCKUP_CYCLE_SECONDS, 0);
        leave_validator_set(validator, validator_address);
        end_epoch();

        // Fast forward enough so the lockup expires.
        timestamp::fast_forward_seconds(LOCKUP_CYCLE_SECONDS);
        assert!(get_remaining_lockup_secs(validator_address) == 0, 1);

        // Validator rejoins the validator set. Once the current epoch ends, their lockup should be automatically
        // renewed.
        join_validator_set(validator, validator_address);
        end_epoch();
        assert!(get_validator_state(validator_address) == VALIDATOR_STATUS_ACTIVE, 2);
        assert!(get_remaining_lockup_secs(validator_address) == LOCKUP_CYCLE_SECONDS, 2);
    }

    #[test(topo_framework = @topo_framework, validator_1 = @0x123, validator_2 = @0x234)]
    public entry fun test_pending_inactive_validator_does_not_count_in_increase_limit(
        topo_framework: &signer, validator_1: &signer, validator_2: &signer
    ) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        // Only 50% voting power increase is allowed in each epoch.
        initialize_for_test_custom(
            topo_framework,
            50,
            10000,
            LOCKUP_CYCLE_SECONDS,
            true,
            1,
            10,
            50
        );
        let (_sk_1, pk_1, pop_1) = generate_identity();
        let (_sk_2, pk_2, pop_2) = generate_identity();
        initialize_test_validator(&pk_1, &pop_1, validator_1, 100, true, false);
        // We need a second validator here just so the first validator can leave.
        initialize_test_validator(&pk_2, &pop_2, validator_2, 100, true, true);

        // Validator 1 leaves the validator set. Epoch has not ended so they're still pending_inactive.
        leave_validator_set(validator_1, signer::address_of(validator_1));
        // Validator 1 adds more stake. This should not succeed as it should not count as a voting power increase.
        mint_and_add_stake(validator_1, 51);
    }

    #[
        test(
            topo_framework = @0x1,
            validator_1 = @0x123,
            validator_2 = @0x234,
            validator_3 = @0x345
        )
    ]
    public entry fun test_multiple_validators_join_and_leave(
        topo_framework: &signer,
        validator_1: &signer,
        validator_2: &signer,
        validator_3: &signer
    ) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        let validator_1_address = signer::address_of(validator_1);
        let validator_2_address = signer::address_of(validator_2);
        let validator_3_address = signer::address_of(validator_3);

        initialize_for_test_custom(
            topo_framework,
            100,
            10000,
            LOCKUP_CYCLE_SECONDS,
            true,
            1,
            100,
            100
        );
        let (_sk_1, pk_1, pop_1) = generate_identity();
        let pk_1_bytes = bls12381::public_key_to_bytes(&pk_1);
        let (_sk_2, pk_2, pop_2) = generate_identity();
        let (_sk_3, pk_3, pop_3) = generate_identity();
        initialize_test_validator(&pk_1, &pop_1, validator_1, 100, false, false);
        initialize_test_validator(&pk_2, &pop_2, validator_2, 100, false, false);
        initialize_test_validator(&pk_3, &pop_3, validator_3, 100, false, false);

        // Validator 1 and 2 join the validator set.
        join_validator_set(validator_2, validator_2_address);
        join_validator_set(validator_1, validator_1_address);
        end_epoch();
        assert!(get_validator_state(validator_1_address) == VALIDATOR_STATUS_ACTIVE, 0);
        assert!(get_validator_state(validator_2_address) == VALIDATOR_STATUS_ACTIVE, 1);

        // Validator indices is the reverse order of the joining order.
        assert_validator_state(validator_1_address, 100, 0, 0, 0, 0);
        assert_validator_state(validator_2_address, 100, 0, 0, 0, 1);
        let validator_set = borrow_global<ValidatorSet>(@topo_framework);
        let validator_config_1 = validator_set.active_validators.borrow(0);
        assert!(validator_config_1.addr == validator_1_address, 2);
        assert!(validator_config_1.config.validator_index == 0, 3);
        let validator_config_2 = validator_set.active_validators.borrow(1);
        assert!(validator_config_2.addr == validator_2_address, 4);
        assert!(validator_config_2.config.validator_index == 1, 5);

        // Validator 1 rotates consensus key. Validator 2 leaves. Validator 3 joins.
        let (_sk_1b, pk_1b, pop_1b) = generate_identity();
        let pk_1b_bytes = bls12381::public_key_to_bytes(&pk_1b);
        let pop_1b_bytes = bls12381::proof_of_possession_to_bytes(&pop_1b);
        rotate_consensus_key(
            validator_1,
            validator_1_address,
            pk_1b_bytes,
            pop_1b_bytes
        );
        leave_validator_set(validator_2, validator_2_address);
        join_validator_set(validator_3, validator_3_address);
        // Validator 2 is not effectively removed until next epoch.
        assert!(
            get_validator_state(validator_2_address)
                == VALIDATOR_STATUS_PENDING_INACTIVE,
            6
        );
        assert!(
            borrow_global<ValidatorSet>(@topo_framework).pending_inactive.borrow(0).addr ==
            validator_2_address,
            0
        );
        // Validator 3 is not effectively added until next epoch.
        assert!(
            get_validator_state(validator_3_address) == VALIDATOR_STATUS_PENDING_ACTIVE,
            7
        );
        assert!(
            borrow_global<ValidatorSet>(@topo_framework).pending_active.borrow(0).addr
                == validator_3_address,
            0
        );
        assert!(
            borrow_global<ValidatorSet>(@topo_framework).active_validators.borrow(0).config
            .consensus_pubkey == pk_1_bytes,
            0
        );

        // Changes applied after new epoch
        end_epoch();
        assert!(get_validator_state(validator_1_address) == VALIDATOR_STATUS_ACTIVE, 8);
        assert_validator_state(validator_1_address, 101, 0, 0, 0, 0);
        assert!(get_validator_state(validator_2_address) == VALIDATOR_STATUS_INACTIVE, 9);
        // The validator index of validator 2 stays the same but this doesn't matter as the next time they rejoin the
        // validator set, their index will get set correctly.
        assert_validator_state(validator_2_address, 101, 0, 0, 0, 1);
        assert!(get_validator_state(validator_3_address) == VALIDATOR_STATUS_ACTIVE, 10);
        assert_validator_state(validator_3_address, 100, 0, 0, 0, 1);
        assert!(
            borrow_global<ValidatorSet>(@topo_framework).active_validators.borrow(0).config
            .consensus_pubkey == pk_1b_bytes,
            0
        );

        // Validators without enough stake will be removed.
        unlock(validator_1, 50);
        timestamp::fast_forward_seconds(LOCKUP_CYCLE_SECONDS);
        end_epoch();
        assert!(
            get_validator_state(validator_1_address) == VALIDATOR_STATUS_INACTIVE, 11
        );
    }

    #[test(topo_framework = @topo_framework, validator = @0x123)]
    public entry fun test_delegated_staking_with_owner_cap(
        topo_framework: &signer, validator: &signer
    ) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        initialize_for_test_custom(
            topo_framework,
            100,
            10000,
            LOCKUP_CYCLE_SECONDS,
            true,
            1,
            100,
            100
        );
        let (_sk, pk, pop) = generate_identity();
        initialize_test_validator(&pk, &pop, validator, 0, false, false);
        let owner_cap = extract_owner_cap(validator);

        // Add stake when the validator is not yet activated.
        add_stake_with_cap(&owner_cap, mint_coins(100));
        let pool_address = signer::address_of(validator);
        assert_validator_state(pool_address, 100, 0, 0, 0, 0);

        // Join the validator set with enough stake.
        join_validator_set(validator, pool_address);
        end_epoch();
        assert!(get_validator_state(pool_address) == VALIDATOR_STATUS_ACTIVE, 0);

        // Unlock the entire stake.
        unlock_with_cap(100, &owner_cap);
        assert_validator_state(pool_address, 0, 0, 0, 100, 0);
        timestamp::fast_forward_seconds(LOCKUP_CYCLE_SECONDS);
        end_epoch();

        // Withdraw stake + rewards.
        assert_validator_state(pool_address, 0, 101, 0, 0, 0);
        let coins = withdraw_with_cap(&owner_cap, 101);
        assert!(coin::value(&coins) == 101, 1);
        assert_validator_state(pool_address, 0, 0, 0, 0, 0);

        // Operator can separately rotate consensus key.
        let (_sk_new, pk_new, pop_new) = generate_identity();
        let pk_new_bytes = bls12381::public_key_to_bytes(&pk_new);
        let pop_new_bytes = bls12381::proof_of_possession_to_bytes(&pop_new);
        rotate_consensus_key(
            validator,
            pool_address,
            pk_new_bytes,
            pop_new_bytes
        );
        let validator_config = borrow_global<ValidatorConfig>(pool_address);
        assert!(validator_config.consensus_pubkey == pk_new_bytes, 2);

        // Operator can update network and fullnode addresses.
        update_network_and_fullnode_addresses(validator, pool_address, b"1", b"2");
        let validator_config = borrow_global<ValidatorConfig>(pool_address);
        assert!(validator_config.network_addresses == b"1", 3);
        assert!(validator_config.fullnode_addresses == b"2", 4);

        // Cleanups.
        coin::register<TopoCoin>(validator);
        coin::deposit(pool_address, coins);
        deposit_owner_cap(validator, owner_cap);
    }

    #[test(topo_framework = @topo_framework, validator = @0x123)]
    #[expected_failure(abort_code = 0x1000A, location = Self)]
    public entry fun test_validator_cannot_join_post_genesis(
        topo_framework: &signer, validator: &signer
    ) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        initialize_for_test_custom(
            topo_framework,
            100,
            10000,
            LOCKUP_CYCLE_SECONDS,
            false,
            1,
            100,
            100
        );

        // Joining the validator set should fail as post genesis validator set change is not allowed.
        let (_sk, pk, pop) = generate_identity();
        initialize_test_validator(&pk, &pop, validator, 100, true, true);
    }

    #[test(topo_framework = @topo_framework, validator = @0x123)]
    #[expected_failure(abort_code = 0x1000E, location = Self)]
    public entry fun test_invalid_pool_address(
        topo_framework: &signer, validator: &signer
    ) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        initialize_for_test(topo_framework);
        let (_sk, pk, pop) = generate_identity();
        initialize_test_validator(&pk, &pop, validator, 100, true, true);
        join_validator_set(validator, @0x234);
    }

    #[test(topo_framework = @topo_framework, validator = @0x123)]
    #[expected_failure(abort_code = 0x1000A, location = Self)]
    public entry fun test_validator_cannot_leave_post_genesis(
        topo_framework: &signer, validator: &signer
    ) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        initialize_for_test_custom(
            topo_framework,
            100,
            10000,
            LOCKUP_CYCLE_SECONDS,
            false,
            1,
            100,
            100
        );
        let (_sk, pk, pop) = generate_identity();
        initialize_test_validator(&pk, &pop, validator, 100, false, false);

        // Bypass the check to join. This is the same function called during Genesis.
        let validator_address = signer::address_of(validator);
        join_validator_set_internal(validator, validator_address);
        end_epoch();

        // Leaving the validator set should fail as post genesis validator set change is not allowed.
        leave_validator_set(validator, validator_address);
    }

    #[
        test(
            topo_framework = @topo_framework,
            validator_1 = @topo_framework,
            validator_2 = @0x2,
            validator_3 = @0x3,
            validator_4 = @0x4,
            validator_5 = @0x5
        )
    ]
    fun test_validator_consensus_infos_from_validator_set(
        topo_framework: &signer,
        validator_1: &signer,
        validator_2: &signer,
        validator_3: &signer,
        validator_4: &signer,
        validator_5: &signer
    ) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        let v1_addr = signer::address_of(validator_1);
        let v2_addr = signer::address_of(validator_2);
        let v3_addr = signer::address_of(validator_3);
        let v4_addr = signer::address_of(validator_4);
        let v5_addr = signer::address_of(validator_5);

        initialize_for_test(topo_framework);

        let (_sk_1, pk_1, pop_1) = generate_identity();
        let (_sk_2, pk_2, pop_2) = generate_identity();
        let (_sk_3, pk_3, pop_3) = generate_identity();
        let (_sk_4, pk_4, pop_4) = generate_identity();
        let (_sk_5, pk_5, pop_5) = generate_identity();
        let pk_1_bytes = bls12381::public_key_to_bytes(&pk_1);
        let pk_3_bytes = bls12381::public_key_to_bytes(&pk_3);
        let pk_5_bytes = bls12381::public_key_to_bytes(&pk_5);

        initialize_test_validator(&pk_1, &pop_1, validator_1, 101, false, false);
        initialize_test_validator(&pk_2, &pop_2, validator_2, 102, false, false);
        initialize_test_validator(&pk_3, &pop_3, validator_3, 103, false, false);
        initialize_test_validator(&pk_4, &pop_4, validator_4, 104, false, false);
        initialize_test_validator(&pk_5, &pop_5, validator_5, 105, false, false);

        join_validator_set(validator_3, v3_addr);
        join_validator_set(validator_1, v1_addr);
        join_validator_set(validator_5, v5_addr);
        end_epoch();
        let vci_vec_0 =
            validator_consensus_infos_from_validator_set(
                borrow_global<ValidatorSet>(@topo_framework)
            );
        let vci_addrs =
            vci_vec_0.map_ref(|obj| {
                let vci: &ValidatorConsensusInfo = obj;
                validator_consensus_info::get_addr(vci)
            });
        let vci_pks =
            vci_vec_0.map_ref(|obj| {
                let vci: &ValidatorConsensusInfo = obj;
                validator_consensus_info::get_pk_bytes(vci)
            });
        let vci_voting_powers =
            vci_vec_0.map_ref(|obj| {
                let vci: &ValidatorConsensusInfo = obj;
                validator_consensus_info::get_voting_power(vci)
            });
        assert!(
            vector[@0x5, @topo_framework, @0x3] == vci_addrs,
            1
        );
        assert!(
            vector[pk_5_bytes, pk_1_bytes, pk_3_bytes] == vci_pks,
            2
        );
        assert!(vector[105, 101, 103] == vci_voting_powers, 3);
        leave_validator_set(validator_3, v3_addr);
        let vci_vec_1 =
            validator_consensus_infos_from_validator_set(
                borrow_global<ValidatorSet>(@topo_framework)
            );
        assert!(vci_vec_0 == vci_vec_1, 11);
        join_validator_set(validator_2, v2_addr);
        let vci_vec_2 =
            validator_consensus_infos_from_validator_set(
                borrow_global<ValidatorSet>(@topo_framework)
            );
        assert!(vci_vec_0 == vci_vec_2, 12);
        leave_validator_set(validator_1, v1_addr);
        let vci_vec_3 =
            validator_consensus_infos_from_validator_set(
                borrow_global<ValidatorSet>(@topo_framework)
            );
        assert!(vci_vec_0 == vci_vec_3, 13);
        join_validator_set(validator_4, v4_addr);
        let vci_vec_4 =
            validator_consensus_infos_from_validator_set(
                borrow_global<ValidatorSet>(@topo_framework)
            );
        assert!(vci_vec_0 == vci_vec_4, 14);
    }

    #[
        test(
            topo_framework = @topo_framework,
            validator_1 = @topo_framework,
            validator_2 = @0x2,
            validator_3 = @0x3,
            validator_4 = @0x4,
            validator_5 = @0x5
        )
    ]
    public entry fun test_staking_validator_index(
        topo_framework: &signer,
        validator_1: &signer,
        validator_2: &signer,
        validator_3: &signer,
        validator_4: &signer,
        validator_5: &signer
    ) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        let v1_addr = signer::address_of(validator_1);
        let v2_addr = signer::address_of(validator_2);
        let v3_addr = signer::address_of(validator_3);
        let v4_addr = signer::address_of(validator_4);
        let v5_addr = signer::address_of(validator_5);

        initialize_for_test(topo_framework);

        let (_sk_1, pk_1, pop_1) = generate_identity();
        let (_sk_2, pk_2, pop_2) = generate_identity();
        let (_sk_3, pk_3, pop_3) = generate_identity();
        let (_sk_4, pk_4, pop_4) = generate_identity();
        let (_sk_5, pk_5, pop_5) = generate_identity();

        initialize_test_validator(&pk_1, &pop_1, validator_1, 100, false, false);
        initialize_test_validator(&pk_2, &pop_2, validator_2, 100, false, false);
        initialize_test_validator(&pk_3, &pop_3, validator_3, 100, false, false);
        initialize_test_validator(&pk_4, &pop_4, validator_4, 100, false, false);
        initialize_test_validator(&pk_5, &pop_5, validator_5, 100, false, false);

        join_validator_set(validator_3, v3_addr);
        end_epoch();
        assert!(get_validator_index(v3_addr) == 0, 0);

        join_validator_set(validator_4, v4_addr);
        end_epoch();
        assert!(get_validator_index(v3_addr) == 0, 1);
        assert!(get_validator_index(v4_addr) == 1, 2);

        join_validator_set(validator_1, v1_addr);
        join_validator_set(validator_2, v2_addr);
        // pending_inactive is appended in reverse order
        end_epoch();
        assert!(get_validator_index(v3_addr) == 0, 6);
        assert!(get_validator_index(v4_addr) == 1, 7);
        assert!(get_validator_index(v2_addr) == 2, 8);
        assert!(get_validator_index(v1_addr) == 3, 9);

        join_validator_set(validator_5, v5_addr);
        end_epoch();
        assert!(get_validator_index(v3_addr) == 0, 10);
        assert!(get_validator_index(v4_addr) == 1, 11);
        assert!(get_validator_index(v2_addr) == 2, 12);
        assert!(get_validator_index(v1_addr) == 3, 13);
        assert!(get_validator_index(v5_addr) == 4, 14);

        // after swap remove, it's 3,4,2,5
        leave_validator_set(validator_1, v1_addr);
        // after swap remove, it's 5,4,2
        leave_validator_set(validator_3, v3_addr);
        end_epoch();

        assert!(get_validator_index(v5_addr) == 0, 15);
        assert!(get_validator_index(v4_addr) == 1, 16);
        assert!(get_validator_index(v2_addr) == 2, 17);
    }

    #[test(topo_framework = @topo_framework, validator_1 = @0x123, validator_2 = @0x234)]
    public entry fun test_validator_rewards_are_performance_based(
        topo_framework: &signer, validator_1: &signer, validator_2: &signer
    ) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        initialize_for_test(topo_framework);

        let validator_1_address = signer::address_of(validator_1);
        let validator_2_address = signer::address_of(validator_2);

        // Both validators join the set.
        let (_sk_1, pk_1, pop_1) = generate_identity();
        let (_sk_2, pk_2, pop_2) = generate_identity();
        initialize_test_validator(&pk_1, &pop_1, validator_1, 100, true, false);
        initialize_test_validator(&pk_2, &pop_2, validator_2, 100, true, true);

        // Validator 2 failed proposal.
        let failed_proposer_indices = vector::empty<u64>();
        let validator_1_index =
            borrow_global<ValidatorConfig>(validator_1_address).validator_index;
        let validator_2_index =
            borrow_global<ValidatorConfig>(validator_2_address).validator_index;
        failed_proposer_indices.push_back(validator_2_index);
        let proposer_indices = option::some(validator_1_index);
        update_performance_statistics(proposer_indices, failed_proposer_indices);
        end_epoch();

        // Validator 2 received no rewards. Validator 1 didn't fail proposals, so it still receives rewards.
        assert_validator_state(validator_1_address, 101, 0, 0, 0, 1);
        assert_validator_state(validator_2_address, 100, 0, 0, 0, 0);

        // Validator 2 decides to leave. Both validators failed proposals.
        unlock(validator_2, 100);
        leave_validator_set(validator_2, validator_2_address);
        let failed_proposer_indices = vector::empty<u64>();
        let validator_1_index =
            borrow_global<ValidatorConfig>(validator_1_address).validator_index;
        let validator_2_index =
            borrow_global<ValidatorConfig>(validator_2_address).validator_index;
        failed_proposer_indices.push_back(validator_1_index);
        failed_proposer_indices.push_back(validator_2_index);
        update_performance_statistics(option::none(), failed_proposer_indices);
        // Fast forward so validator 2's stake is fully unlocked.
        timestamp::fast_forward_seconds(LOCKUP_CYCLE_SECONDS);
        end_epoch();

        // Validator 1 and 2 received no additional rewards due to failed proposals
        assert_validator_state(validator_1_address, 101, 0, 0, 0, 0);
        assert_validator_state(validator_2_address, 0, 100, 0, 0, 0);
    }

    #[test(topo_framework = @topo_framework, validator_1 = @0x123, validator_2 = @0x234)]
    public entry fun test_validator_rewards_rate_decrease_over_time(
        topo_framework: &signer, validator_1: &signer, validator_2: &signer
    ) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        initialize_for_test(topo_framework);

        let genesis_time_in_secs = timestamp::now_seconds();

        let validator_1_address = signer::address_of(validator_1);
        let validator_2_address = signer::address_of(validator_2);

        // Both validators join the set.
        let (_sk_1, pk_1, pop_1) = generate_identity();
        let (_sk_2, pk_2, pop_2) = generate_identity();
        initialize_test_validator(&pk_1, &pop_1, validator_1, 1000, true, false);
        initialize_test_validator(&pk_2, &pop_2, validator_2, 10000, true, true);

        // One epoch passed. Validator 1 and validator 2 should receive rewards at rewards rate = 1% every epoch.
        end_epoch();
        assert_validator_state(validator_1_address, 1010, 0, 0, 0, 1);
        assert_validator_state(validator_2_address, 10100, 0, 0, 0, 0);

        // Enable rewards rate decrease. Initially rewards rate is still 1% every epoch. Rewards rate halves every year.
        let one_year_in_secs: u64 = 31536000;
        staking_config::initialize_rewards(
            topo_framework,
            fixed_point64::create_from_rational(1, 100),
            fixed_point64::create_from_rational(3, 1000),
            one_year_in_secs,
            genesis_time_in_secs,
            fixed_point64::create_from_rational(50, 100)
        );
        features::change_feature_flags_for_testing(
            topo_framework,
            vector[features::get_periodical_reward_rate_decrease_feature()],
            vector[]
        );

        // For some reason, this epoch is very long. It has been 1 year since genesis when the epoch ends.
        timestamp::fast_forward_seconds(one_year_in_secs - EPOCH_DURATION * 3);
        end_epoch();
        // Validator 1 and validator 2 should still receive rewards at rewards rate = 1% every epoch. Rewards rate has halved after this epoch.
        assert_validator_state(validator_1_address, 1020, 0, 0, 0, 1);
        assert_validator_state(validator_2_address, 10200, 0, 0, 0, 0);

        // For some reason, this epoch is also very long. One year passed.
        timestamp::fast_forward_seconds(one_year_in_secs - EPOCH_DURATION);
        end_epoch();
        // Validator 1 and validator 2 should still receive rewards at rewards rate = 0.5% every epoch. Rewards rate has halved after this epoch.
        assert_validator_state(validator_1_address, 1025, 0, 0, 0, 1);
        assert_validator_state(validator_2_address, 10250, 0, 0, 0, 0);

        end_epoch();
        // Rewards rate has halved but cannot become lower than min_rewards_rate.
        // Validator 1 and validator 2 should receive rewards at rewards rate = 0.3% every epoch.
        assert_validator_state(validator_1_address, 1028, 0, 0, 0, 1);
        assert_validator_state(validator_2_address, 10280, 0, 0, 0, 0);
    }

    #[test(topo_framework = @topo_framework, validator = @0x123)]
    public entry fun test_update_performance_statistics_should_not_fail_due_to_out_of_bounds(
        topo_framework: &signer, validator: &signer
    ) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        initialize_for_test(topo_framework);

        let validator_address = signer::address_of(validator);
        let (_sk, pk, pop) = generate_identity();
        initialize_test_validator(&pk, &pop, validator, 100, true, true);

        let valid_validator_index =
            borrow_global<ValidatorConfig>(validator_address).validator_index;
        let out_of_bounds_index = valid_validator_index + 100;

        // Invalid validator index in the failed proposers vector should not lead to abort.
        let failed_proposer_indices = vector::empty<u64>();
        failed_proposer_indices.push_back(valid_validator_index);
        failed_proposer_indices.push_back(out_of_bounds_index);
        update_performance_statistics(option::none(), failed_proposer_indices);
        end_epoch();

        // Validator received no rewards due to failing to propose.
        assert_validator_state(validator_address, 100, 0, 0, 0, 0);

        // Invalid validator index in the proposer should not lead to abort.
        let proposer_index_optional = option::some(out_of_bounds_index);
        update_performance_statistics(proposer_index_optional, vector::empty<u64>());
        end_epoch();
    }

    #[test(topo_framework = @topo_framework, validator = @0x123)]
    #[expected_failure(abort_code = 0x1000B, location = Self)]
    public entry fun test_invalid_config(
        topo_framework: &signer, validator: &signer
    ) acquires AllowedValidators, InstalledRewardContext, OwnerCapability, StakePool, TopoCoinCapabilities, ValidatorConfig, ValidatorSet {
        initialize_for_test_custom(
            topo_framework,
            50,
            10000,
            LOCKUP_CYCLE_SECONDS,
            true,
            1,
            100,
            100
        );

        // Call initialize_stake_owner, which only initializes the stake pool but not validator config.
        let validator_address = signer::address_of(validator);
        account::create_account_for_test(validator_address);
        initialize_stake_owner(
            validator,
            0,
            validator_address,
            validator_address
        );
        mint_and_add_stake(validator, 100);

        // Join the validator set with enough stake. This should fail because the validator didn't initialize validator
        // config.
        join_validator_set(validator, validator_address);
    }

    #[test(topo_framework = @topo_framework, validator = @0x123)]
    public entry fun test_valid_config(
        topo_framework: &signer, validator: &signer
    ) acquires AllowedValidators, InstalledRewardContext, OwnerCapability, StakePool, TopoCoinCapabilities, ValidatorConfig, ValidatorSet {
        initialize_for_test_custom(
            topo_framework,
            50,
            10000,
            LOCKUP_CYCLE_SECONDS,
            true,
            1,
            100,
            100
        );

        // Call initialize_stake_owner, which only initializes the stake pool but not validator config.
        let validator_address = signer::address_of(validator);
        account::create_account_for_test(validator_address);
        initialize_stake_owner(
            validator,
            0,
            validator_address,
            validator_address
        );
        mint_and_add_stake(validator, 100);

        // Initialize validator config.
        let validator_address = signer::address_of(validator);
        let (_sk_new, pk_new, pop_new) = generate_identity();
        let pk_new_bytes = bls12381::public_key_to_bytes(&pk_new);
        let pop_new_bytes = bls12381::proof_of_possession_to_bytes(&pop_new);
        rotate_consensus_key(
            validator,
            validator_address,
            pk_new_bytes,
            pop_new_bytes
        );

        // Join the validator set with enough stake. This now wouldn't fail since the validator config already exists.
        join_validator_set(validator, validator_address);
    }

    #[test]
    public entry fun test_rewards_calculation() {
        let stake_amount = 2000;
        let num_successful_proposals = 199;
        let num_total_proposals = 200;
        let rewards_rate = 700;
        let rewards_rate_denominator = 777;
        let rewards_amount =
            reward_amount_wide(
                stake_amount,
                num_successful_proposals,
                num_total_proposals as u256,
                rewards_rate,
                rewards_rate_denominator
            );
        // Consider `amount_imprecise` and `amount_precise` defined as follows:
        // amount_imprecise = (stake_amount * rewards_rate / rewards_rate_denominator) * num_successful_proposals / num_total_proposals
        // amount_precise = stake_amount * rewards_rate * num_successful_proposals / (rewards_rate_denominator * num_total_proposals)
        // Although they are equivalent in the real arithmetic, they are not in the integer arithmetic due to a rounding error.
        // With the test parameters above, `amount_imprecise` is equal to 1791 because of an unbounded rounding error
        // while `amount_precise` is equal to 1792. The reward must use the single final division.
        assert!(rewards_amount == 1792, 0);

        let stake_amount = 100000000000000000;
        let num_successful_proposals = 9999;
        let num_total_proposals = 10000;
        let rewards_rate = 3141592;
        let rewards_rate_denominator = 10000000;
        // This should not abort due to an arithmetic overflow.
        let rewards_amount =
            reward_amount_wide(
                stake_amount,
                num_successful_proposals,
                num_total_proposals as u256,
                rewards_rate,
                rewards_rate_denominator
            );
        assert!(rewards_amount == 31412778408000000, 0);
    }

    #[test_only]
    public fun set_validator_perf_at_least_one_block() acquires ValidatorPerformance {
        let validator_perf = borrow_global_mut<ValidatorPerformance>(@topo_framework);
        validator_perf.validators.for_each_mut(|validator| {
            let validator: &mut IndividualValidatorPerformance = validator;
            if (validator.successful_proposals + validator.failed_proposals < 1) {
                validator.successful_proposals = 1;
            };
        });
    }

    #[test(topo_framework = @0x1, validator_1 = @0x123, validator_2 = @0x234)]
    public entry fun test_removing_validator_from_active_set(
        topo_framework: &signer, validator_1: &signer, validator_2: &signer
    ) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        initialize_for_test(topo_framework);
        let (_sk_1, pk_1, pop_1) = generate_identity();
        let (_sk_2, pk_2, pop_2) = generate_identity();
        initialize_test_validator(&pk_1, &pop_1, validator_1, 100, true, false);
        initialize_test_validator(&pk_2, &pop_2, validator_2, 100, true, true);
        assert!(
            borrow_global<ValidatorSet>(@topo_framework).active_validators.length()
                == 2,
            0
        );

        // Remove validator 1 from the active validator set. Only validator 2 remains.
        let validator_to_remove = signer::address_of(validator_1);
        remove_validators(topo_framework, &vector[validator_to_remove]);
        assert!(
            borrow_global<ValidatorSet>(@topo_framework).active_validators.length()
                == 1,
            0
        );
        assert!(
            get_validator_state(validator_to_remove)
                == VALIDATOR_STATUS_PENDING_INACTIVE,
            1
        );
    }

    #[test(
        vm = @0x0, topo_framework = @0x1, validator_0 = @0x123, validator_1 = @0x234
    )]
    public entry fun test_transaction_fee(
        vm: &signer,
        topo_framework: &signer,
        validator_0: &signer,
        validator_1: &signer
    ) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        initialize_for_test(topo_framework);
        initialize_pending_transaction_fee(topo_framework);
        features::change_feature_flags_for_testing(
            topo_framework,
            vector[features::get_distribute_transaction_fee_feature()],
            vector[]
        );
        let address_0 = signer::address_of(validator_0);
        let address_1 = signer::address_of(validator_1);
        let (_sk_0, pk_0, pop_0) = generate_identity();
        let (_sk_1, pk_1, pop_1) = generate_identity();
        initialize_test_validator(&pk_0, &pop_0, validator_0, 100, true, false);
        initialize_test_validator(&pk_1, &pop_1, validator_1, 100, true, true);
        assert!(
            borrow_global<ValidatorSet>(@topo_framework).active_validators.length()
                == 2,
            0
        );

        let validator_to_remove = signer::address_of(validator_0);
        remove_validators(topo_framework, &vector[validator_to_remove]);
        assert!(
            borrow_global<ValidatorSet>(@topo_framework).active_validators.length()
                == 1,
            0
        );

        // validator 0 is pending inactive, validator 1 is active, both should get fee.

        {
            let fee_table =
                &borrow_global<PendingTransactionFee>(@topo_framework).pending_fee_by_validator;
            assert!(fee_table.contains(&0), 0);
            assert!(fee_table.contains(&1), 0);
        };

        record_fee(vm, vector[], vector[]);
        record_fee(
            vm,
            vector[get_validator_index(address_0)],
            vector[1]
        );
        record_fee(
            vm,
            vector[get_validator_index(address_1)],
            vector[2]
        );
        record_fee(
            vm,
            vector[get_validator_index(address_0), get_validator_index(address_1)],
            vector[10, 220]
        );

        {
            let fee_table =
                &borrow_global<PendingTransactionFee>(@topo_framework).pending_fee_by_validator;
            assert!(
                fee_table.borrow(&get_validator_index(address_0)).read() == 11,
                0
            );
            assert!(
                fee_table.borrow(&get_validator_index(address_1)).read() == 222,
                0
            );
            end_epoch();

            assert!(
                event::was_event_emitted(
                    &DistributeTransactionFee { pool_address: address_0, fee_amount: 11 }
                ),
                0
            );
            assert!(
                event::was_event_emitted(
                    &DistributeTransactionFee { pool_address: address_1, fee_amount: 222 }
                ),
                0
            );
        };

        let fee_table =
            &borrow_global<PendingTransactionFee>(@topo_framework).pending_fee_by_validator;
        // validator 1 is at index 0 now.
        assert!(fee_table.contains(&0), 0);
        assert!(!fee_table.contains(&1), 0);

        assert!(
            event::emitted_events<DistributeTransactionFee>().length() == 2,
            0
        );
        // No more event is emitted at this epoch ending.
        end_epoch();
        assert!(
            event::emitted_events<DistributeTransactionFee>().length() == 2,
            0
        );
    }

    #[test(
        vm = @0x0, topo_framework = @0x1, validator_0 = @0x123, validator_1 = @0x234
    )]
    #[expected_failure(abort_code = 0x10002, location = 0x1::big_ordered_map)]
    public entry fun test_transaction_fee_non_validator(
        vm: &signer,
        topo_framework: &signer,
        validator_0: &signer,
        validator_1: &signer
    ) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        initialize_for_test(topo_framework);
        initialize_pending_transaction_fee(topo_framework);
        features::change_feature_flags_for_testing(
            topo_framework,
            vector[features::get_distribute_transaction_fee_feature()],
            vector[]
        );
        let (_sk_0, pk_0, pop_0) = generate_identity();
        let (_sk_1, pk_1, pop_1) = generate_identity();
        initialize_test_validator(&pk_0, &pop_0, validator_0, 100, true, false);
        initialize_test_validator(&pk_1, &pop_1, validator_1, 100, true, true);
        assert!(
            borrow_global<ValidatorSet>(@topo_framework).active_validators.length()
                == 2,
            0
        );

        let validator_to_remove = signer::address_of(validator_0);
        remove_validators(topo_framework, &vector[validator_to_remove]);
        assert!(
            borrow_global<ValidatorSet>(@topo_framework).active_validators.length()
                == 1,
            0
        );

        // validator 0 is pending inactive, validator 1 is active.

        end_epoch();
        assert!(
            event::emitted_events<DistributeTransactionFee>().length() == 0,
            0
        );

        // Validator index is out of bound, abort.
        record_fee(vm, vector[1], vector[1]);
    }

    #[test(
        vm = @0x0, topo_framework = @0x1, validator_0 = @0x123, validator_1 = @0x234
    )]
    public entry fun test_transaction_fee_limit(
        vm: &signer,
        topo_framework: &signer,
        validator_0: &signer,
        validator_1: &signer
    ) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        initialize_for_test(topo_framework);
        initialize_pending_transaction_fee(topo_framework);
        features::change_feature_flags_for_testing(
            topo_framework,
            vector[features::get_distribute_transaction_fee_feature()],
            vector[]
        );
        let address_0 = signer::address_of(validator_0);
        let address_1 = signer::address_of(validator_1);
        let (_sk_0, pk_0, pop_0) = generate_identity();
        let (_sk_1, pk_1, pop_1) = generate_identity();
        initialize_test_validator(&pk_0, &pop_0, validator_0, 100, true, false);
        initialize_test_validator(&pk_1, &pop_1, validator_1, 100, true, true);
        assert!(
            borrow_global<ValidatorSet>(@topo_framework).active_validators.length()
                == 2,
            0
        );

        record_fee(vm, vector[], vector[]);
        record_fee(
            vm,
            vector[get_validator_index(address_0)],
            vector[1]
        );
        record_fee(
            vm,
            vector[get_validator_index(address_1)],
            vector[2]
        );
        record_fee(
            vm,
            vector[get_validator_index(address_0), get_validator_index(address_1)],
            vector[10, 220]
        );

        {
            let fee_table =
                &borrow_global<PendingTransactionFee>(@topo_framework).pending_fee_by_validator;
            assert!(
                fee_table.borrow(&get_validator_index(address_0)).read() == 11,
                0
            );
            assert!(
                fee_table.borrow(&get_validator_index(address_1)).read() == 222,
                0
            );
            let config = TransactionFeeConfig::V0 {
                max_fee_octa_allowed_per_epoch_per_pool: 20
            };
            set_transaction_fee_config(topo_framework, config);
            end_epoch();

            assert!(
                event::was_event_emitted(
                    &DistributeTransactionFee { pool_address: address_0, fee_amount: 11 }
                ),
                0
            );
            assert!(
                event::was_event_emitted(
                    &DistributeTransactionFee { pool_address: address_1, fee_amount: 20 }
                ),
                0
            );
        };

        // Make sure we can set the config multiple times.
        let config =
            TransactionFeeConfig::V0 { max_fee_octa_allowed_per_epoch_per_pool: 200 };
        set_transaction_fee_config(topo_framework, config);
    }

    #[test_only]
    public fun end_epoch() acquires EpochPlan, InstalledRewardContext, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        // Set the number of blocks to 1, to give out rewards to non-failing validators.
        set_validator_perf_at_least_one_block();
        timestamp::fast_forward_seconds(EPOCH_DURATION);
        reconfiguration_state::on_reconfig_start();
        let actual = validator_consensus_infos_from_validator_set(&next_validator_consensus_infos_v2());
        on_new_epoch();
        let expected = cur_validator_consensus_infos();
        assert!(expected == actual, 999);
        reconfiguration_state::on_reconfig_finish();
    }

    #[test_only]
    public fun assert_stake_pool(
        pool_address: address,
        active_stake: u64,
        inactive_stake: u64,
        pending_active_stake: u64,
        pending_inactive_stake: u64
    ) acquires StakePool {
        let stake_pool = borrow_global<StakePool>(pool_address);
        let actual_active_stake = coin::value(&stake_pool.active);
        assert!(actual_active_stake == active_stake, actual_active_stake);
        let actual_inactive_stake = coin::value(&stake_pool.inactive);
        assert!(actual_inactive_stake == inactive_stake, actual_inactive_stake);
        let actual_pending_active_stake = coin::value(&stake_pool.pending_active);
        assert!(
            actual_pending_active_stake == pending_active_stake,
            actual_pending_active_stake
        );
        let actual_pending_inactive_stake = coin::value(&stake_pool.pending_inactive);
        assert!(
            actual_pending_inactive_stake == pending_inactive_stake,
            actual_pending_inactive_stake
        );
    }

    #[test_only]
    public fun assert_validator_state(
        pool_address: address,
        active_stake: u64,
        inactive_stake: u64,
        pending_active_stake: u64,
        pending_inactive_stake: u64,
        validator_index: u64
    ) acquires StakePool, ValidatorConfig {
        assert_stake_pool(
            pool_address,
            active_stake,
            inactive_stake,
            pending_active_stake,
            pending_inactive_stake
        );
        let validator_config = borrow_global<ValidatorConfig>(pool_address);
        assert!(
            validator_config.validator_index == validator_index,
            validator_config.validator_index
        );
    }

    #[test(topo_framework = @0x1, validator = @0x123)]
    public entry fun test_allowed_validators(
        topo_framework: &signer, validator: &signer
    ) acquires AllowedValidators, InstalledRewardContext, OwnerCapability, StakePool, ValidatorSet {
        let addr = signer::address_of(validator);
        let (burn, mint) = topo_coin::initialize_for_test(topo_framework);
        configure_allowed_validators(topo_framework, vector[addr]);

        account::create_account_for_test(addr);
        coin::register<TopoCoin>(validator);
        initialize_stake_owner(validator, 0, addr, addr);
        coin::destroy_burn_cap(burn);
        coin::destroy_mint_cap(mint);
    }

    #[test(topo_framework = @0x1, validator = @0x123)]
    #[expected_failure(abort_code = 0x60011, location = Self)]
    public entry fun test_not_allowed_validators(
        topo_framework: &signer, validator: &signer
    ) acquires AllowedValidators, InstalledRewardContext, OwnerCapability, StakePool, ValidatorSet {
        configure_allowed_validators(topo_framework, vector[]);
        let (burn, mint) = topo_coin::initialize_for_test(topo_framework);

        let addr = signer::address_of(validator);
        account::create_account_for_test(addr);
        coin::register<TopoCoin>(validator);
        initialize_stake_owner(validator, 0, addr, addr);
        coin::destroy_burn_cap(burn);
        coin::destroy_mint_cap(mint);
    }

    #[test_only]
    public fun with_rewards(amount: u64): u64 {
        let (numerator, denominator) =
            staking_config::get_reward_rate(&staking_config::get());
        amount + amount * numerator / denominator
    }

    #[test(topo_framework = @topo_framework, validator = @0x123)]
    public entry fun test_validator_set_liveness_fallback(
        topo_framework: &signer, validator: &signer
    ) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        // Initialize with a minimum stake requirement (100)
        initialize_for_test(topo_framework);
        let (_sk, pk, pop) = generate_identity();

        initialize_test_validator(&pk, &pop, validator, 100, true, true);
        staking_config::update_required_stake(topo_framework, 1000, 10000);
        end_epoch();

        // Verify that ValidatorSetLivenessFallback event was emitted
        let validator_set = &ValidatorSet[@topo_framework];
        let (minimum_stake, _) =
            staking_config::get_required_stake(&staking_config::get());
        let expected_total_voting_power = validator_set.total_voting_power;
        let expected_validator_count = validator_set.active_validators.length();

        let expected_event = ValidatorSetLivenessFallback {
            minimum_stake,
            emergency_validator_count: expected_validator_count,
            total_emergency_voting_power: expected_total_voting_power
        };
        assert!(event::was_event_emitted(&expected_event), 0);
    }

    #[test(topo_framework = @topo_framework, validator = @0x123)]
    public entry fun test_reconfig_start_fills_precomputed_cache(
        topo_framework: &signer, validator: &signer
    ) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        initialize_for_test(topo_framework);
        let (_sk, pk, pop) = generate_identity();
        initialize_test_validator(&pk, &pop, validator, 100, true, true);

        // Simulates what try_start / try_start_with_chunky_dkg does.
        reconfiguration_state::on_reconfig_start();
        let _ = next_validator_consensus_infos_v2();
        assert!(exists<PrecomputedValidatorSet>(@topo_framework), 0);
    }

    #[test(topo_framework = @topo_framework, validator = @0x123)]
    public entry fun test_precomputed_cache_cleared_after_epoch(
        topo_framework: &signer, validator: &signer
    ) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        initialize_for_test(topo_framework);
        let (_sk, pk, pop) = generate_identity();
        initialize_test_validator(&pk, &pop, validator, 100, true, true);

        end_epoch();

        // Cache must be cleared so the next epoch starts fresh.
        assert!(!exists<PrecomputedValidatorSet>(@topo_framework), 0);
    }
    #[test_only]
    public fun poc_setup(framework: &signer, user: &signer, addresses: vector<address>, activation: u64) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        poc_setup_mode(framework, user, addresses, activation, true);
    }

    #[test_only]
    public fun poc_setup_controlled(framework: &signer, user: &signer, addresses: vector<address>, activation: u64) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        poc_setup_mode(framework, user, addresses, activation, false);
    }

    #[test_only]
    fun poc_setup_mode(framework: &signer, user: &signer, addresses: vector<address>, activation: u64, dynamic: bool) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        initialize_for_test_custom(framework, 100, 10000, 3600, dynamic, 1, 100, 25);
        initialize_pending_transaction_fee(framework);
        set_transaction_fee_limit_per_epoch_per_pool(framework, 50);
        addresses.for_each_ref(|address| {
            let validator = create_signer::create_signer(*address);
            let (_sk, pk, pop) = generate_identity();
            initialize_test_validator(&pk, &pop, &validator, 100, false, false);
            join_validator_set_internal(&validator, *address);
        });
        end_epoch();
        staking_config::initialize_rewards(framework, fixed_point64::create_from_rational(1, 100),
            fixed_point64::create_from_rational(0, 1), 86400, timestamp::now_seconds(),
            fixed_point64::create_from_rational(0, 1));
        poc_accounting::prepare(framework, 1, activation,
            poc_accounting::new_power_params(100000000, 10, 1000, 4),
            poc_accounting::new_deployment_limits(5, 5, 5, 8, 1000, 1, 100, 50, 100),
            if (dynamic) { 1 } else { 0 }, 25, dynamic);
        prepare_poc_context(framework, 1);
        poc_power_store::initialize_for_test(framework, 1, 10000, 100, 60, @topo_framework);
        addresses.for_each_ref(|pool| poc_accounting::enable_pool(framework, *pool));
        poc_accounting::replace_allocation(user, addresses, vector[2500, 2500, 2500, 2500],
            40u128 << 32, 40u128 << 32, 62);
    }

    #[test_only]
    public fun poc_begin_for_test() acquires EpochPlan, InstalledRewardContext, StakePool, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        let epoch = poc_accounting::current_epoch() + 1;
        assert!(try_cache_epoch_plan(epoch, timestamp::now_seconds()) == 0, 100);
        reconfiguration_state::on_reconfig_start();
        validate_epoch_plan(epoch);
    }

    #[test_only]
    public fun poc_commit(framework: &signer) acquires EpochPlan, InstalledRewardContext, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        assert!(try_cache_epoch_plan(poc_accounting::current_epoch() + 1, timestamp::now_seconds()) == 0, 100);
        reconfiguration_state::on_reconfig_start();
        settle_closing_epoch();
        apply_cached_features(framework);
        install_epoch_plan(poc_accounting::current_epoch() + 1);
        finish_epoch_plan();
        reconfiguration_state::on_reconfig_finish();
    }

    #[test_only]
    public fun record_fee_for_test(vm: &signer, validator_index: u64, fee_octa: u64) acquires PendingTransactionFee {
        record_fee(vm, vector[validator_index], vector[fee_octa]);
    }

    #[test_only]
    /// 每池保证金为 1000 Octa、算力为 1024 power，最终权重上限为 1000 power；最优表现下每期通胀为 10 Octa。
    fun poc_setup_reward_split(framework: &signer, user: &signer, native_reward_bps: u64) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        let pool_addresses = vector[@0x11, @0x22, @0x33, @0x44];
        poc_setup(framework, user, pool_addresses, 2);
        // 通胀用例明确关闭分费；费用用例在安装目标 Epoch 前单独开启。
        features::change_feature_flags_for_testing(framework, vector[], vector[features::get_distribute_transaction_fee_feature()]);
        let mint_cap = &borrow_global<TopoCoinCapabilities>(@topo_framework).mint_cap;
        pool_addresses.for_each_ref(|pool_address| {
            coin::merge(&mut borrow_global_mut<StakePool>(*pool_address).active, coin::mint(900, mint_cap));
        });
        poc_accounting::replace_allocation(user, pool_addresses, vector[2500, 2500, 2500, 2500],
            4096u128 << 32, 4096u128 << 32, 62);
        schedule_reward_split(framework, native_reward_bps, 2);
    }

    #[test_only]
    fun stake_balances_match(pool_address: address, expected_balances_octa: vector<u64>): bool acquires StakePool {
        let (active_stake_octa, inactive_stake_octa, pending_active_stake_octa, pending_inactive_stake_octa) = get_stake(pool_address);
        vector[active_stake_octa, inactive_stake_octa, pending_active_stake_octa, pending_inactive_stake_octa] == expected_balances_octa
    }

    #[test_only]
    /// 将指定池的四类余额之一填充到总本金目标；初始 1000 Octa active 保持不变。
    fun fill_native_capacity_bucket(pool_address: address, bucket: u8, total_target: u64)
    acquires StakePool, TopoCoinCapabilities {
        assert!(total_target >= 1000, 1);
        let mint_cap = &borrow_global<TopoCoinCapabilities>(@topo_framework).mint_cap;
        let coins = coin::mint(total_target - 1000, mint_cap);
        let pool = borrow_global_mut<StakePool>(pool_address);
        if (bucket == 0) {
            coin::merge(&mut pool.active, coins);
        } else if (bucket == 1) {
            coin::merge(&mut pool.inactive, coins);
        } else if (bucket == 2) {
            coin::merge(&mut pool.pending_active, coins);
        } else {
            assert!(bucket == 3, 2);
            coin::merge(&mut pool.pending_inactive, coins);
        };
    }

    #[test_only]
    fun assert_add_stake_capacity_rejected_for_bucket(
        framework: &signer, user: &signer, pool_address: address, bucket: u8,
    ) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee,
        PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig,
        ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        poc_setup_reward_split(framework, user, 3000);
        poc_commit(framework);
        let upper_bound = get_native_reward_upper_bound(pool_address);
        assert!(upper_bound == 3, 1);
        fill_native_capacity_bucket(pool_address, bucket, (MAX_U64 as u64) - upper_bound);
        let mint_cap = &borrow_global<TopoCoinCapabilities>(@topo_framework).mint_cap;
        coin::deposit(pool_address, coin::mint(1, mint_cap));
        let owner = create_signer::create_signer(pool_address);
        add_stake(&owner, 1);
    }

    #[test(framework = @0x1, user = @0x777)]
    fun poc_native_capacity_accepts_exact_limit_for_each_balance_bucket(
        framework: signer, user: signer,
    ) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee,
        PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig,
        ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        poc_setup_reward_split(&framework, &user, 3000);
        poc_commit(&framework);
        let pools = vector[@0x11, @0x22, @0x33, @0x44];
        let i = 0;
        while (i < 4) {
            let pool_address = pools[i];
            let closing_upper_bound = get_native_reward_upper_bound(pool_address);
            assert!(closing_upper_bound == 3, 10 + i);
            // 旧期费用关闭时上界为 3；目标期仍按部署费用限额预留 15，目标上界为 18。
            let target_upper_bound = 18;
            fill_native_capacity_bucket(pool_address, i as u8,
                (MAX_U64 as u64) - closing_upper_bound - target_upper_bound);
            assert!(total_stake_balance_octa(borrow_global<StakePool>(pool_address))
                + (closing_upper_bound as u256) + (target_upper_bound as u256)
                == (MAX_U64 as u256), 20 + i);
            i += 1;
        };
        assert!(preview_epoch_transition(3, timestamp::now_seconds()).reason == 0, 30);
    }

    #[test(framework = @0x1, user = @0x777)]
    fun poc_zero_native_upper_bound_allows_each_balance_bucket_without_aggregate_reserve(
        framework: signer, user: signer,
    ) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee,
        PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig,
        ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        poc_setup_reward_split(&framework, &user, 0);
        poc_commit(&framework);
        let pools = vector[@0x11, @0x22, @0x33, @0x44];
        let i = 0;
        while (i < 4) {
            let pool_address = pools[i];
            assert!(get_native_reward_upper_bound(pool_address) == 0, 10 + i);
            fill_native_capacity_bucket(pool_address, i as u8, MAX_U64 as u64);
            assert!(total_stake_balance_octa(borrow_global<StakePool>(pool_address))
                == (MAX_U64 as u256), 20 + i);
            i += 1;
        };
        // 原生奖励上界为零时不预留聚合空间；inactive 承载大额本金时，追加 1 Octa
        // 只需满足目标 pending_active Coin 自身和原生最大质押约束。
        let mint_cap = &borrow_global<TopoCoinCapabilities>(@topo_framework).mint_cap;
        coin::deposit(@0x22, coin::mint(1, mint_cap));
        let owner = create_signer::create_signer(@0x22);
        add_stake(&owner, 1);
        assert!(total_stake_balance_octa(borrow_global<StakePool>(@0x22))
            == (MAX_U64 as u256) + 1, 30);
        // 四类余额分别达到边界，且一个池的聚合本金已经加一，仍可生成零原生奖励目标。
        assert!(preview_epoch_transition(3, timestamp::now_seconds()).reason == 0, 31);
    }

    #[test(framework = @0x1, user = @0x777)]
    #[expected_failure(abort_code = 0x10025, location = Self)]
    fun poc_add_stake_active_capacity_plus_one_rejected(framework: signer, user: signer)
    acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee,
        PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig,
        ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        assert_add_stake_capacity_rejected_for_bucket(&framework, &user, @0x11, 0);
    }

    #[test(framework = @0x1, user = @0x777)]
    #[expected_failure(abort_code = 0x10025, location = Self)]
    fun poc_add_stake_inactive_capacity_plus_one_rejected(framework: signer, user: signer)
    acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee,
        PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig,
        ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        assert_add_stake_capacity_rejected_for_bucket(&framework, &user, @0x22, 1);
    }

    #[test(framework = @0x1, user = @0x777)]
    #[expected_failure(abort_code = 0x10025, location = Self)]
    fun poc_add_stake_pending_active_capacity_plus_one_rejected(framework: signer, user: signer)
    acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee,
        PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig,
        ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        assert_add_stake_capacity_rejected_for_bucket(&framework, &user, @0x33, 2);
    }

    #[test(framework = @0x1, user = @0x777)]
    #[expected_failure(abort_code = 0x10025, location = Self)]
    fun poc_add_stake_pending_inactive_capacity_plus_one_rejected(framework: signer, user: signer)
    acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee,
        PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig,
        ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        assert_add_stake_capacity_rejected_for_bucket(&framework, &user, @0x44, 3);
    }

    #[test(framework = @0x1, user = @0x777)]
    fun poc_capacity_accepts_deployment_rate_bound_above_one(framework: signer, user: signer) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        initialize_for_test_custom(&framework, 100, 10000, 3600, true, 1, 100, 25);
        initialize_pending_transaction_fee(&framework);
        set_transaction_fee_limit_per_epoch_per_pool(&framework, 50);
        let pool_addresses = vector[@0x11, @0x22, @0x33, @0x44];
        pool_addresses.for_each_ref(|pool_address| {
            let validator = create_signer::create_signer(*pool_address);
            let (_sk, pk, pop) = generate_identity();
            initialize_test_validator(&pk, &pop, &validator, 1000, false, false);
            join_validator_set_internal(&validator, *pool_address);
        });
        end_epoch();
        staking_config::initialize_rewards(&framework, fixed_point64::create_from_rational(1, 100),
            fixed_point64::create_from_rational(0, 1), 86400, timestamp::now_seconds(),
            fixed_point64::create_from_rational(0, 1));
        // 部署参数中的奖励率上限允许设为 2/1（200%）；实际安装的奖励率仍为 1/100（1%）。
        poc_accounting::prepare(&framework, 1, 2,
            poc_accounting::new_power_params(100000000, 10, 1000, 4),
            poc_accounting::new_deployment_limits(5, 5, 5, 8, 1000, 2, 1, 50, 100), 1, 25, true);
        prepare_poc_context(&framework, 1);
        poc_power_store::initialize_for_test(&framework, 1, 10000, 100, 60, @topo_framework);
        pool_addresses.for_each_ref(|pool_address| poc_accounting::enable_pool(&framework, *pool_address));
        poc_accounting::replace_allocation(&user, pool_addresses, vector[2500, 2500, 2500, 2500],
            4096u128 << 32, 4096u128 << 32, 62);
        assert!(preview_epoch_transition(2, timestamp::now_seconds()).reason == 0, 1);
        poc_commit(&framework);
        assert!(get_installed_native_reward_bps() == 3000 && get_native_reward_upper_bound(@0x44) == 18, 2);
        update_performance_statistics(option::some(get_validator_index(@0x44)), vector[]);
        poc_commit(&framework);
        let (_, _, _, vault_balance_octa, _) = poc_accounting::get_pool(@0x44);
        assert!(stake_balances_match(@0x44, vector[1003, 0, 0, 0]) && vault_balance_octa == 7, 3);
    }

    #[test_only]
    fun reward_split_configuration_matches(
        installed_epoch: u64, installed_native_reward_bps: u64, configured_native_reward_bps: u64,
        pending_native_reward_bps: Option<u64>, pending_activation_epoch: Option<u64>,
    ): bool {
        let (actual_installed_epoch, actual_installed_native_reward_bps, actual_configured_native_reward_bps,
            actual_pending_native_reward_bps, actual_pending_activation_epoch) = get_reward_split_configuration();
        actual_installed_epoch == installed_epoch && actual_installed_native_reward_bps == installed_native_reward_bps
            && actual_configured_native_reward_bps == configured_native_reward_bps
            && actual_pending_native_reward_bps == pending_native_reward_bps
            && actual_pending_activation_epoch == pending_activation_epoch
    }

    #[test(framework = @0x1, power_only = @0x777, bond_only = @0x44, vm = @vm_reserved)]
    fun poc_mixed_rewards_preserve_native_ownership_and_fee_destination(framework: signer, power_only: signer, bond_only: signer, vm: signer) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        poc_setup_reward_split(&framework, &power_only, 3000);
        features::change_feature_flags_for_testing(&framework, vector[features::get_distribute_transaction_fee_feature()], vector[]);
        assert!(get_installed_native_reward_bps() == 0, 1);
        // 只出保证金的 owner 建立零 units 持仓，以生产领取路径证明其不能取得 PoC 金库收益。
        poc_accounting::replace_allocation(&bond_only, vector[@0x44], vector[10000], 0, 0, 62);
        coin::register<TopoCoin>(&power_only);
        poc_commit(&framework);
        assert!(get_installed_native_reward_bps() == 3000 && get_native_reward_upper_bound(@0x44) == 18, 2);
        unlock(&bond_only, 400);
        let mint_cap = &borrow_global<TopoCoinCapabilities>(@topo_framework).mint_cap;
        coin::deposit(@0x44, coin::mint(100, mint_cap));
        add_stake(&bond_only, 100);
        coin::merge(&mut borrow_global_mut<StakePool>(@0x44).inactive, coin::mint(77, mint_cap));
        let validator_index = get_validator_index(@0x44);
        update_performance_statistics(option::some(validator_index), vector[]);
        record_fee(&vm, vector[validator_index], vector[20]);
        poc_commit(&framework);
        // 3 Octa 原生奖励按 active 与 pending_inactive 的 600:400 余额比例分为 2 和 1 Octa。
        // 20 Octa 交易费分为原生 6、PoC 14；原生费用按同一旧本金分为 4 和 2 Octa。
        // pending_active 的 100 Octa 与 inactive 的 77 Octa 均不参与本次奖励分配。
        assert!(stake_balances_match(@0x44, vector[706, 77, 0, 403]), 3);
        let (units, _, reward_base_octa, vault_balance_octa, reward_index) = poc_accounting::get_pool(@0x44);
        assert!(units == (1024u128 << 32) && reward_base_octa == 1000
            && vault_balance_octa == 21 && reward_index == 1624796301562061610805100544, 4);
        assert!(event::was_event_emitted(&DistributeRewards { pool_address: @0x44, rewards_amount: 3 })
            && event::was_event_emitted(&DistributeTransactionFee { pool_address: @0x44, fee_amount: 6 }), 5);
        assert!(event::was_event_emitted(&PoCRewardSplit { pool: @0x44, closing_epoch: 2,
            native_reward_bps: 3000, total_inflation_octa: 10, active_native_reward_octa: 2,
            pending_inactive_native_reward_octa: 1, poc_inflation_octa: 7 }), 6);
        assert!(event::was_event_emitted(&PoCRewardCredited { pool: @0x44, closing_epoch: 2,
            reward_base_octa: 1000, inflation: 7, fee: 14,
            delta_index: 1624796301562061610805100544 }), 7);

        let (_, _, bond_claimable, bond_fractional) = poc_accounting::get_position(@0x44, @0x44);
        let (_, _, power_claimable, power_fractional) = poc_accounting::get_position(@0x777, @0x44);
        assert!(bond_claimable == 0 && bond_fractional == 0
            && power_claimable == 21 && power_fractional == 0, 8);
        let bond_rewards = poc_accounting::claim_rewards(&bond_only, vector[@0x44]);
        coin::destroy_zero(bond_rewards);
        let claimed_rewards = poc_accounting::claim_rewards(&power_only, vector[@0x44]);
        assert!(coin::value(&claimed_rewards) == 21 && coin::balance<TopoCoin>(@0x777) == 0
            && coin::balance<TopoCoin>(@0x44) == 0, 9);
        coin::deposit(@0x777, claimed_rewards);
        assert!(coin::balance<TopoCoin>(@0x777) == 21 && coin::balance<TopoCoin>(@0x44) == 0, 10);
        coin::destroy_zero(poc_accounting::claim_rewards(&power_only, vector[@0x44]));
        coin::destroy_zero(poc_accounting::claim_rewards(&bond_only, vector[@0x44]));
        let (_, _, _, remaining_vault, _) = poc_accounting::get_pool(@0x44);
        assert!(remaining_vault == 0, 11);
    }

    #[test(framework = @0x1, dual_owner = @0x44, vm = @vm_reserved)]
    fun poc_mixed_rewards_dual_owner_receives_native_and_poc_independently(framework: signer, dual_owner: signer, vm: signer) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        // 同一地址拥有池保证金并提供全部算力；两类收益仍分别进入质押余额和本人钱包。
        poc_setup_reward_split(&framework, &dual_owner, 3000);
        features::change_feature_flags_for_testing(&framework, vector[features::get_distribute_transaction_fee_feature()], vector[]);
        poc_commit(&framework);
        unlock(&dual_owner, 400);
        let mint_cap = &borrow_global<TopoCoinCapabilities>(@topo_framework).mint_cap;
        coin::deposit(@0x44, coin::mint(100, mint_cap));
        add_stake(&dual_owner, 100);
        coin::merge(&mut borrow_global_mut<StakePool>(@0x44).inactive, coin::mint(77, mint_cap));
        let validator_index = get_validator_index(@0x44);
        update_performance_statistics(option::some(validator_index), vector[]);
        record_fee(&vm, vector[validator_index], vector[20]);
        poc_commit(&framework);

        assert!(stake_balances_match(@0x44, vector[706, 77, 0, 403])
            && coin::balance<TopoCoin>(@0x44) == 0, 1);
        let (_, _, claimable_octa, fractional_entitlement) = poc_accounting::get_position(@0x44, @0x44);
        assert!(claimable_octa == 21 && fractional_entitlement == 0, 2);
        let claimed_rewards = poc_accounting::claim_rewards(&dual_owner, vector[@0x44]);
        assert!(coin::value(&claimed_rewards) == 21, 3);
        coin::deposit(@0x44, claimed_rewards);
        assert!(coin::balance<TopoCoin>(@0x44) == 21
            && stake_balances_match(@0x44, vector[706, 77, 0, 403]), 4);
        coin::destroy_zero(poc_accounting::claim_rewards(&dual_owner, vector[@0x44]));
        let (_, _, _, vault_balance_octa, _) = poc_accounting::get_pool(@0x44);
        assert!(vault_balance_octa == 0, 5);
    }

    #[test(framework = @0x1, user = @0x777, vm = @vm_reserved)]
    fun poc_zero_and_full_native_split_use_old_epoch_snapshot(framework: signer, user: signer, vm: signer) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        poc_setup_reward_split(&framework, &user, 0);
        features::change_feature_flags_for_testing(&framework, vector[features::get_distribute_transaction_fee_feature()], vector[]);
        poc_commit(&framework);
        schedule_reward_split(&framework, 10000, 3);
        assert!(get_installed_native_reward_bps() == 0 && get_native_reward_upper_bound(@0x44) == 0, 1);
        update_performance_statistics(option::some(get_validator_index(@0x44)), vector[]);
        record_fee(&vm, vector[get_validator_index(@0x44)], vector[5]);
        poc_commit(&framework);
        assert!(stake_balances_match(@0x44, vector[1000, 0, 0, 0]) && get_installed_native_reward_bps() == 10000, 2);
        let (_, _, _, vault_balance_octa, _) = poc_accounting::get_pool(@0x44);
        assert!(vault_balance_octa == 15, 3);
        let validator_index = get_validator_index(@0x44);
        update_performance_statistics(option::some(validator_index), vector[]);
        record_fee(&vm, vector[validator_index], vector[4]);
        poc_commit(&framework);
        let (_, _, _, vault_balance_octa, _) = poc_accounting::get_pool(@0x44);
        assert!(stake_balances_match(@0x44, vector[1014, 0, 0, 0]) && vault_balance_octa == 15, 4);
    }

    #[test(framework = @0x1, user = @0x777, vm = @vm_reserved)]
    fun poc_fee_split_rounding_is_independent_of_inflation(framework: signer, user: signer, vm: signer) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        poc_setup_reward_split(&framework, &user, 3500);
        features::change_feature_flags_for_testing(&framework, vector[features::get_distribute_transaction_fee_feature()], vector[]);
        poc_commit(&framework);
        let index = get_validator_index(@0x44);
        update_performance_statistics(option::some(index), vector[]);
        record_fee(&vm, vector[index], vector[2]);
        poc_commit(&framework);
        // 原生分别得到 floor(10 * 35%) = 3 和 floor(2 * 35%) = 0，不能先合计后取整为 4。
        assert!(stake_balances_match(@0x44, vector[1003, 0, 0, 0]), 1);
        let (_, _, _, vault, _) = poc_accounting::get_pool(@0x44);
        assert!(vault == 9, 2);
    }

    #[test(framework = @0x1, user = @0x777, vm = @vm_reserved)]
    fun poc_fee_only_split_caps_before_splitting_and_uses_old_switch(framework: signer, user: signer, vm: signer) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        poc_setup_reward_split(&framework, &user, 3000);
        staking_config::update_rewards_rate(&framework, 0, 100);
        features::change_feature_flags_for_testing(&framework, vector[features::get_distribute_transaction_fee_feature()], vector[]);
        poc_commit(&framework);
        assert!(get_native_reward_upper_bound(@0x44) == 15, 1);
        // 不产生通胀，费用先截断到旧期 50 Octa 上限；当前配置修改不改变已安装上下文。
        set_transaction_fee_limit_per_epoch_per_pool(&framework, 10);
        features::change_feature_flags_for_testing(&framework, vector[], vector[features::get_distribute_transaction_fee_feature()]);
        schedule_reward_split(&framework, 10000, 3);
        assert!(get_native_reward_upper_bound(@0x44) == 15, 2);
        record_fee(&vm, vector[get_validator_index(@0x44)], vector[18446744073709551615]);
        poc_commit(&framework);
        assert!(stake_balances_match(@0x44, vector[1015, 0, 0, 0]), 3);
        let (_, _, _, vault, _) = poc_accounting::get_pool(@0x44);
        assert!(vault == 35 && get_native_reward_upper_bound(@0x44) == 0, 4);
        // 新期关闭费用分发，已记录费用仍清空，但两路都不入账。
        record_fee(&vm, vector[get_validator_index(@0x44)], vector[10]);
        poc_commit(&framework);
        let (_, _, _, vault, _) = poc_accounting::get_pool(@0x44);
        assert!(vault == 35 && stake_balances_match(@0x44, vector[1015, 0, 0, 0]), 5);
        assert!(get_pending_transaction_fee() == vector[0, 0, 0, 0], 6);
    }

    #[test(framework = @0x1, user = @0x777)]
    fun poc_fee_capacity_reserved_before_any_fees_accrue(framework: signer, user: signer) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        poc_setup_reward_split(&framework, &user, 3000);
        staking_config::update_rewards_rate(&framework, 0, 100);
        features::change_feature_flags_for_testing(&framework, vector[features::get_distribute_transaction_fee_feature()], vector[]);
        poc_commit(&framework);
        let mint_cap = &borrow_global<TopoCoinCapabilities>(@topo_framework).mint_cap;
        coin::merge(&mut borrow_global_mut<StakePool>(@0x44).active, coin::mint((MAX_U64 as u64) - 1014, mint_cap));
        assert!(get_native_reward_upper_bound(@0x44) == 15, 1);
        assert!(try_cache_epoch_plan(3, timestamp::now_seconds()) == TARGET_OUT_OF_RANGE, 2);
        assert!(!exists<EpochPlan>(@topo_framework) && !features::is_reconfiguration_frozen(), 3);
    }

    #[test(framework = @0x1, user = @0x777)]
    fun poc_native_capacity_accepts_exact_u64_and_defers_one_over(framework: signer, user: signer) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        poc_setup_reward_split(&framework, &user, 3000);
        features::change_feature_flags_for_testing(&framework,
            vector[features::get_distribute_transaction_fee_feature()], vector[]);
        poc_commit(&framework);
        assert!(get_native_reward_upper_bound(@0x44) == 18, 1);

        let mint_cap = &borrow_global<TopoCoinCapabilities>(@topo_framework).mint_cap;
        // 四类余额都取非零值。按 u256 独立相加后，旧期 18 与目标期 18 的原生收益上界
        // 恰好把总量推到 u64 上限，此边界必须允许生成目标。
        coin::merge(&mut borrow_global_mut<StakePool>(@0x44).pending_active, coin::mint(11, mint_cap));
        coin::merge(&mut borrow_global_mut<StakePool>(@0x44).pending_inactive, coin::mint(13, mint_cap));
        coin::merge(&mut borrow_global_mut<StakePool>(@0x44).inactive,
            coin::mint((MAX_U64 as u64) - 1060, mint_cap));
        assert!(total_stake_balance_octa(borrow_global<StakePool>(@0x44)) + 18 + 18
            == (MAX_U64 as u256), 2);
        assert!(preview_epoch_transition(3, timestamp::now_seconds()).reason == 0, 3);

        // 再增加 1 Octa 后只超出一位；延期必须发生在冻结前，不能残留计划或 PVS。
        coin::merge(&mut borrow_global_mut<StakePool>(@0x44).inactive, coin::mint(1, mint_cap));
        assert!(total_stake_balance_octa(borrow_global<StakePool>(@0x44)) + 18 + 18
            == (MAX_U64 as u256) + 1, 4);
        assert!(try_cache_epoch_plan(3, timestamp::now_seconds()) == TARGET_OUT_OF_RANGE, 5);
        assert!(!exists<EpochPlan>(@topo_framework) && !exists<PrecomputedValidatorSet>(@topo_framework)
            && !reconfiguration_state::is_in_progress() && !features::is_reconfiguration_frozen(), 6);
    }

    #[test(framework = @0x1, user = @0x777)]
    fun poc_inactive_withdraw_repairs_native_capacity_deferred(framework: signer, user: signer) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        poc_setup_reward_split(&framework, &user, 3000);
        features::change_feature_flags_for_testing(&framework,
            vector[features::get_distribute_transaction_fee_feature()], vector[]);
        poc_commit(&framework);
        let mint_cap = &borrow_global<TopoCoinCapabilities>(@topo_framework).mint_cap;
        coin::merge(&mut borrow_global_mut<StakePool>(@0x44).inactive,
            coin::mint((MAX_U64 as u64) - 1035, mint_cap));
        assert!(total_stake_balance_octa(borrow_global<StakePool>(@0x44)) + 18 + 18
            == (MAX_U64 as u256) + 1, 1);
        assert!(try_cache_epoch_plan(3, timestamp::now_seconds()) == TARGET_OUT_OF_RANGE, 2);
        assert!(!exists<EpochPlan>(@topo_framework) && !exists<PrecomputedValidatorSet>(@topo_framework)
            && !features::is_reconfiguration_frozen(), 3);

        // owner 通过生产提取入口取出 1 Octa inactive，本金降到精确容量边界后即可完成换届。
        let owner = create_signer::create_signer(@0x44);
        withdraw(&owner, 1);
        assert!(total_stake_balance_octa(borrow_global<StakePool>(@0x44)) + 18 + 18
            == (MAX_U64 as u256), 4);
        poc_commit(&framework);
        assert!(poc_accounting::current_epoch() == 3 && !exists<EpochPlan>(@topo_framework)
            && !exists<PrecomputedValidatorSet>(@topo_framework)
            && !features::is_reconfiguration_frozen(), 5);
    }

    #[test(framework = @0x1, user = @0x777)]
    fun poc_fee_upper_bound_excludes_nonvoting_pools(framework: signer, user: signer) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        poc_setup_reward_split(&framework, &user, 3000);
        features::change_feature_flags_for_testing(&framework, vector[features::get_distribute_transaction_fee_feature()], vector[]);
        poc_commit(&framework);
        poc_add_replacement(&framework, @0x55);
        assert!(get_native_reward_upper_bound(@0x44) == 18, 1);
        assert!(!is_current_epoch_validator(@0x55) && get_native_reward_upper_bound(@0x55) == 0, 2);
    }

    #[test(framework = @0x1, user = @0x777)]
    fun poc_next_fee_capacity_reserved_when_current_fees_disabled(framework: signer, user: signer) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        poc_setup_reward_split(&framework, &user, 3000);
        staking_config::update_rewards_rate(&framework, 0, 100);
        poc_commit(&framework);
        assert!(get_native_reward_upper_bound(@0x44) == 0, 1);
        // 可容纳下一期的 3 Octa 通胀，却不足以同时容纳部署限额中的 15 Octa 原生费用。
        let mint_cap = &borrow_global<TopoCoinCapabilities>(@topo_framework).mint_cap;
        coin::merge(&mut borrow_global_mut<StakePool>(@0x44).active, coin::mint((MAX_U64 as u64) - 1017, mint_cap));
        features::change_feature_flags_for_testing(&framework, vector[features::get_distribute_transaction_fee_feature()], vector[]);
        assert!(try_cache_epoch_plan(3, timestamp::now_seconds()) == TARGET_OUT_OF_RANGE, 2);
        assert!(!exists<EpochPlan>(@topo_framework) && !features::is_reconfiguration_frozen(), 3);
    }

    #[test(framework = @0x1, user = @0x777)]
    #[expected_failure(abort_code = 0x10025, location = Self)]
    fun poc_add_stake_reserves_fee_only_capacity(framework: signer, user: signer) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        poc_setup_reward_split(&framework, &user, 3000);
        staking_config::update_rewards_rate(&framework, 0, 100);
        features::change_feature_flags_for_testing(&framework, vector[features::get_distribute_transaction_fee_feature()], vector[]);
        poc_commit(&framework);
        let mint_cap = &borrow_global<TopoCoinCapabilities>(@topo_framework).mint_cap;
        coin::merge(&mut borrow_global_mut<StakePool>(@0x44).active, coin::mint((MAX_U64 as u64) - 1015, mint_cap));
        coin::deposit(@0x44, coin::mint(1, mint_cap));
        let owner = create_signer::create_signer(@0x44);
        add_stake(&owner, 1);
    }

    #[test(framework = @0x1, user = @0x777)]
    fun poc_add_stake_accepts_exact_fee_only_capacity(framework: signer, user: signer) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        poc_setup_reward_split(&framework, &user, 3000);
        staking_config::update_rewards_rate(&framework, 0, 100);
        features::change_feature_flags_for_testing(&framework,
            vector[features::get_distribute_transaction_fee_feature()], vector[]);
        poc_commit(&framework);
        let mint_cap = &borrow_global<TopoCoinCapabilities>(@topo_framework).mint_cap;
        coin::merge(&mut borrow_global_mut<StakePool>(@0x44).inactive,
            coin::mint((MAX_U64 as u64) - 1016, mint_cap));
        coin::deposit(@0x44, coin::mint(1, mint_cap));
        let owner = create_signer::create_signer(@0x44);
        // 追加后四类本金与 15 Octa 原生费用上界之和恰好为 u64 上限。
        add_stake(&owner, 1);
        assert!(get_native_reward_upper_bound(@0x44) == 15
            && total_stake_balance_octa(borrow_global<StakePool>(@0x44)) + 15
                == (MAX_U64 as u256), 1);
    }

    #[test(framework = @0x1, user = @0x777)]
    fun poc_reward_split_pending_replace_cancel_and_future_activation(framework: signer, user: signer) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        poc_setup_reward_split(&framework, &user, 3000);
        poc_commit(&framework);
        schedule_reward_split(&framework, 5000, 4);
        schedule_reward_split(&framework, 7500, 3);
        assert!(reward_split_configuration_matches(2, 3000, 3000, option::some(7500), option::some(3)), 1);
        cancel_pending_reward_split(&framework);
        assert!(reward_split_configuration_matches(2, 3000, 3000, option::none(), option::none()), 2);
        schedule_reward_split(&framework, 6000, 4);
        poc_commit(&framework);
        assert!(get_installed_native_reward_bps() == 3000, 3);
        poc_commit(&framework);
        assert!(reward_split_configuration_matches(4, 6000, 6000, option::none(), option::none()), 4);
    }

    #[test(framework = @0x1, user = @0x777)]
    fun poc_legacy_missing_split_stays_zero_until_explicit_activation(framework: signer, user: signer) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        poc_setup_reward_split(&framework, &user, 3000);
        poc_commit(&framework);
        poc_reward_split::remove_config_for_test();
        assert!(get_installed_native_reward_bps() == 0, 1);
        update_performance_statistics(option::some(get_validator_index(@0x44)), vector[]);
        poc_commit(&framework);
        assert!(get_installed_native_reward_bps() == 0 && stake_balances_match(@0x44, vector[1000, 0, 0, 0]), 2);
        schedule_reward_split(&framework, 10000, 4);
        assert!(reward_split_configuration_matches(3, 0, 0, option::some(10000), option::some(4)), 3);
        update_performance_statistics(option::some(get_validator_index(@0x44)), vector[]);
        poc_commit(&framework);
        let (_, _, _, vault_balance_octa, _) = poc_accounting::get_pool(@0x44);
        assert!(get_installed_native_reward_bps() == 10000 && vault_balance_octa == 20 && stake_balances_match(@0x44, vector[1000, 0, 0, 0]), 4);
    }

    #[test(framework = @0x1, user = @0x777)]
    #[expected_failure(abort_code = 0x30003, location = topo_framework::poc_reward_split)]
    fun poc_reward_split_schedule_frozen_rejected(framework: signer, user: signer) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        poc_setup_reward_split(&framework, &user, 3000);
        poc_begin_for_test();
        schedule_reward_split(&framework, 6000, 2);
    }

    #[test(framework = @0x1, user = @0x777)]
    #[expected_failure(abort_code = 0x30003, location = topo_framework::poc_reward_split)]
    fun poc_reward_split_cancel_frozen_rejected(framework: signer, user: signer) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        poc_setup_reward_split(&framework, &user, 3000);
        poc_begin_for_test();
        cancel_pending_reward_split(&framework);
    }

    #[test(user = @0x777)]
    #[expected_failure(abort_code = 0x50003, location = topo_framework::system_addresses)]
    fun poc_reward_split_schedule_unauthorized_rejected(user: signer) {
        schedule_reward_split(&user, 3000, 2);
    }

    #[test(user = @0x777)]
    #[expected_failure(abort_code = 0x50003, location = topo_framework::system_addresses)]
    fun poc_reward_split_cancel_unauthorized_rejected(user: signer) {
        cancel_pending_reward_split(&user);
    }

    #[test(framework = @0x1, user = @0x777)]
    fun poc_native_reward_capacity_defers_before_freeze_including_outgoing(framework: signer, user: signer) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        poc_setup_reward_split(&framework, &user, 3000);
        poc_commit(&framework);
        let mint_cap = &borrow_global<TopoCoinCapabilities>(@topo_framework).mint_cap;
        coin::merge(&mut borrow_global_mut<StakePool>(@0x44).active, coin::mint((MAX_U64 as u64) - 1002, mint_cap));
        // 当前尚无成功提案，奖励为零；预检仍按 DKG 等待期间可能达到的最优表现预留 3 Octa 原生奖励容量。
        let validator_set = borrow_global_mut<ValidatorSet>(@topo_framework);
        let leaving_validator_index = find_validator(&validator_set.active_validators, @0x44).extract();
        let leaving_validator = validator_set.active_validators.swap_remove(leaving_validator_index);
        validator_set.pending_inactive.push_back(leaving_validator);
        assert!(try_cache_epoch_plan(3, timestamp::now_seconds()) == TARGET_OUT_OF_RANGE, 1);
        assert!(!exists<EpochPlan>(@topo_framework) && !exists<PrecomputedValidatorSet>(@topo_framework)
            && !reconfiguration_state::is_in_progress() && !features::is_reconfiguration_frozen()
            && poc_accounting::current_epoch() == 2, 2);
        let (_, _, _, vault_balance_octa, _) = poc_accounting::get_pool(@0x44);
        assert!(vault_balance_octa == 0, 3);
    }

    #[test(framework = @0x1, user = @0x777)]
    fun poc_native_reward_capacity_covers_expired_pending_merge(framework: signer, user: signer) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        poc_setup_reward_split(&framework, &user, 3000);
        poc_commit(&framework);
        let owner = create_signer::create_signer(@0x44);
        unlock(&owner, 400);
        let mint_cap = &borrow_global<TopoCoinCapabilities>(@topo_framework).mint_cap;
        let stake_pool = borrow_global_mut<StakePool>(@0x44);
        coin::merge(&mut stake_pool.inactive, coin::mint((MAX_U64 as u64) - 401, mint_cap));
        let cutoff_secs = timestamp::now_seconds();
        stake_pool.locked_until_secs = cutoff_secs;
        // 3 Octa 奖励按 600:400 分配，pending_inactive 获得 1；到期合并后恰好等于 u64 上限。
        assert!(can_settle_native_reward(stake_pool, 3, cutoff_secs), 1);
        coin::merge(&mut stake_pool.inactive, coin::mint(1, mint_cap));
        assert!(!can_settle_native_reward(stake_pool, 3, cutoff_secs), 2);
        assert!(try_cache_epoch_plan(3, cutoff_secs) == TARGET_OUT_OF_RANGE
            && !exists<EpochPlan>(@topo_framework) && !exists<PrecomputedValidatorSet>(@topo_framework)
            && !features::is_reconfiguration_frozen(), 3);
    }

    #[test(framework = @0x1, user = @0x777)]
    #[expected_failure(abort_code = 0x10025, location = Self)]
    fun poc_add_stake_reserves_installed_native_reward_capacity(framework: signer, user: signer) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        poc_setup_reward_split(&framework, &user, 3000);
        poc_commit(&framework);
        let mint_cap = &borrow_global<TopoCoinCapabilities>(@topo_framework).mint_cap;
        coin::merge(&mut borrow_global_mut<StakePool>(@0x44).active, coin::mint((MAX_U64 as u64) - 1005, mint_cap));
        coin::deposit(@0x44, coin::mint(3, mint_cap));
        let owner = create_signer::create_signer(@0x44);
        // 当前余额可容纳追加的 3 Octa，但还须为当期最多 3 Octa 的原生奖励预留容量。
        add_stake(&owner, 3);
    }

    #[test(framework = @0x1, user = @0x777)]
    fun poc_add_stake_accepts_exact_installed_native_capacity(framework: signer, user: signer) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        poc_setup_reward_split(&framework, &user, 3000);
        poc_commit(&framework);
        let mint_cap = &borrow_global<TopoCoinCapabilities>(@topo_framework).mint_cap;
        coin::merge(&mut borrow_global_mut<StakePool>(@0x44).inactive,
            coin::mint((MAX_U64 as u64) - 1004, mint_cap));
        coin::deposit(@0x44, coin::mint(1, mint_cap));
        let owner = create_signer::create_signer(@0x44);
        // 追加后四类本金与 3 Octa 当期原生通胀上界之和恰好为 u64 上限。
        add_stake(&owner, 1);
        assert!(get_native_reward_upper_bound(@0x44) == 3
            && total_stake_balance_octa(borrow_global<StakePool>(@0x44)) + 3
                == (MAX_U64 as u256), 1);
    }

    #[test(framework = @0x1, user = @0x777)]
    fun poc_unsafe_next_native_split_can_be_cancelled_before_install(framework: signer, user: signer) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        poc_setup_reward_split(&framework, &user, 0);
        poc_commit(&framework);
        let mint_cap = &borrow_global<TopoCoinCapabilities>(@topo_framework).mint_cap;
        coin::merge(&mut borrow_global_mut<StakePool>(@0x44).active, coin::mint((MAX_U64 as u64) - 1001, mint_cap));
        schedule_reward_split(&framework, 10000, 3);
        assert!(try_cache_epoch_plan(3, timestamp::now_seconds()) == TARGET_OUT_OF_RANGE, 1);
        assert!(get_installed_native_reward_bps() == 0 && poc_accounting::current_epoch() == 2
            && !exists<EpochPlan>(@topo_framework) && !features::is_reconfiguration_frozen(), 2);
        cancel_pending_reward_split(&framework);
        assert!(preview_epoch_transition(3, timestamp::now_seconds()).reason == 0, 3);
        poc_commit(&framework);
        assert!(get_installed_native_reward_bps() == 0 && poc_accounting::current_epoch() == 3, 4);
    }

    #[test]
    fun poc_native_reward_split_rounding_and_zero_balances() {
        let (active_reward_octa, pending_inactive_reward_octa) = split_native_reward_by_stake(3, 600, 400);
        assert!(active_reward_octa == 2 && pending_inactive_reward_octa == 1, 1);
        let (active_reward_octa, pending_inactive_reward_octa) = split_native_reward_by_stake(3, 0, 400);
        assert!(active_reward_octa == 0 && pending_inactive_reward_octa == 3, 2);
        let (active_reward_octa, pending_inactive_reward_octa) = split_native_reward_by_stake(3, 600, 0);
        assert!(active_reward_octa == 3 && pending_inactive_reward_octa == 0, 3);
        let (active_reward_octa, pending_inactive_reward_octa) = split_native_reward_by_stake(0, 0, 0);
        assert!(active_reward_octa == 0 && pending_inactive_reward_octa == 0, 4);
        let (active_reward_octa, pending_inactive_reward_octa) = split_native_reward_by_stake(18446744073709551615, 18446744073709551615, 0);
        assert!(active_reward_octa == 18446744073709551615 && pending_inactive_reward_octa == 0, 5);
    }

    #[test(framework = @0x1, validator = @0x55)]
    fun poc_native_preview_pending_member_does_not_read_old_performance(
        framework: signer, validator: signer
    ) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        initialize_for_test_custom(&framework, 100, 10000, 3600, true, 1, 100, 25);
        let (_sk, pk, pop) = generate_identity();
        initialize_test_validator(&pk, &pop, &validator, 100, true, false);
        let candidate = *borrow_global<ValidatorSet>(@topo_framework).pending_active.borrow(0);
        // 待加入成员没有旧期表现：无效索引和空数组也不得被 include_rewards=false 的路径读取。
        candidate.config.validator_index = MAX_U64 as u64;
        let performance = ValidatorPerformance { validators: vector[] };
        let (power, info) = compute_simulated_validator_info(
            &candidate, &performance, 1, 100, 7, false, timestamp::now_seconds());
        let ValidatorPerformance { validators: _ } = performance;
        assert!(power == 100 && info.voting_power == 100 && info.config.validator_index == 7, 1);
    }

    #[test]
    fun poc_growth_initialization_and_replacement() {
        assert!(allocate_growth(&vector[10, 10, 10, 10], &vector[100, 100, 100, 0], 400, 25, true)
            == vector[10, 10, 10, 10], 1);
        assert!(allocate_growth(&vector[10, 10, 10, 10], &vector[10, 10, 10, 0], 40, 25, false)
            == vector[10, 10, 10, 10], 2);
        assert!(allocate_growth(&vector[10, 10, 10, 10, 10], &vector[10, 10, 10, 0, 0], 40, 25, false)
            == vector[10, 10, 10, 5, 5], 3);
    }

    #[test]
    fun poc_growth_drops_and_flooring() {
        assert!(allocate_growth(&vector[5, 10, 10], &vector[10, 0, 0], 10, 25, false)
            == vector[5, 1, 1], 1);
        assert!(allocate_growth(&vector[5, 5], &vector[10, 10], 20, 25, false) == vector[5, 5], 2);
        // 预算为 2，三名新候选各分到 0；舍入余量不再分配。
        assert!(allocate_growth(&vector[10, 10, 10], &vector[0, 0, 0], 10, 25, false) == vector[0, 0, 0], 3);
    }

    #[test_only]
    fun assert_poc_target_bounds() {
        // 合法配置已保证 65536 * max_power <= u64::MAX，普通和 Chunky DKG 共用的
        // 目标预览不可能产生这个向量；此处隔离验证损坏状态下的生产防御校验。
        let (reason, total) = validate_target_powers(
            &vector[1u64 << 63, 1u64 << 63], 2, 8, false
        );
        assert!(reason == TARGET_OUT_OF_RANGE && total == 1u256 << 64, 1);

        // 总权重恰好等于 u64 上限仍可进入 DKG，第一项超过总和上限才被拒绝。
        let (reason, total) = validate_target_powers(
            &vector[1u64 << 63, (1u64 << 63) - 1], 2, 8, false
        );
        assert!(reason == 0 && total == (MAX_U64 as u256), 2);

        // 生产预览只保留 power >= min_power 的成员，且 min_power 大于零；
        // 零总权重同样只是对损坏目标的防御分支。
        let (reason, total) = validate_target_powers(&vector[0, 0], 2, 8, false);
        assert!(reason == ZERO_TARGET_POWER && total == 0, 3);
    }

    #[test]
    fun poc_actual_total_rejects_dkg_overflow() {
        assert_poc_target_bounds();
    }

    #[test]
    fun poc_valid_config_makes_target_total_overflow_unreachable() {
        let protocol_limit = 65536u256;
        let largest_valid_max_power = (1u64 << 48) - 1;
        // 配置校验对协议人数上限而非较小的部署容量取上界，
        // 因此任意合法目标的实际总权重都不可能溢出 u64。
        assert!(protocol_limit * (largest_valid_max_power as u256)
            == (MAX_U64 as u256) - 65535, 1);

        // min_power 和 min_validators 均大于零。非空选中集的总权重至少为 1；
        // 空选中集会先命中人数不足，不会形成零权重 DKG 目标。
        let (reason, total) = validate_target_powers(&vector[1], 1, 65536, false);
        assert!(reason == 0 && total == 1, 2);
        let (reason, total) = validate_target_powers(&vector[], 1, 65536, false);
        assert!(reason == INSUFFICIENT_VALIDATORS && total == 0, 3);
    }

    #[test(framework = @topo_framework)]
    fun poc_dkg_conservative_config_boundary_accepted(framework: signer) {
        initialize_for_test_custom(&framework, 1, 100, 3600, false, 1, 100, 25);
        let max_power = (1u64 << 48) - 1;
        // 65536 * (2^48 - 1) 是保守配置约束允许的最大乘积。
        assert!(65536u256 * (max_power as u256) == (MAX_U64 as u256) - 65535, 1);
        poc_accounting::prepare(
            &framework,
            1,
            2,
            poc_accounting::new_power_params(1, 1, max_power, 4),
            poc_accounting::new_deployment_limits(4, 4, 4, 8, 2814749, 1, 1, 0, 1),
            0,
            25,
            false,
        );
        let (_, _, _, _, params, _, _) = poc_accounting::get_config();
        let (_, _, installed_max_power, _) = poc_accounting::get_power_params_fields(&params);
        assert!(installed_max_power == max_power, 2);
    }

    #[test(framework = @topo_framework)]
    #[expected_failure(abort_code = 0x10007, location = topo_framework::poc_accounting)]
    fun poc_dkg_conservative_config_first_overflow_rejected(framework: signer) {
        initialize_for_test_custom(&framework, 1, 100, 3600, false, 1, 100, 25);
        let max_power = 1u64 << 48;
        // 65536 * 2^48 恰为 2^64，必须在准备配置时精确拒绝。
        assert!(65536u256 * (max_power as u256) == 1u256 << 64, 1);
        poc_accounting::prepare(
            &framework,
            1,
            2,
            poc_accounting::new_power_params(1, 1, max_power, 4),
            poc_accounting::new_deployment_limits(4, 4, 4, 8, 2814749, 1, 1, 0, 1),
            0,
            25,
            false,
        );
    }

    #[test]
    fun poc_open_concentration_and_controlled_mode() {
        let (reason, total) = validate_target_powers(&vector[20, 5, 5, 5, 5], 4, 8, true);
        assert!(reason == CONCENTRATION_LIMIT && total == 40, 1);
        let (reason, _) = validate_target_powers(&vector[20, 5, 5, 5, 5], 4, 8, false);
        assert!(reason == 0, 2);
        let (reason, _) = validate_target_powers(&vector[10, 10, 10, 10], 4, 8, true);
        assert!(reason == 0, 3);
        let (reason, _) = validate_target_powers(&vector[10, 10, 10], 4, 8, true);
        assert!(reason == INSUFFICIENT_VALIDATORS, 4);
    }

    #[test]
    fun poc_rewards_long_epoch_and_fractional_rate() {
        let max = MAX_U64 as u64;
        assert!(reward_amount_wide(max, max, (max as u256) * 2, 1, 1) == max / 2, 1);
        assert!(reward_amount_wide(100, 1, 3, 1, 10) == 3, 2);
        assert!(reward_amount_wide(100, 0, 0, 1, 10) == 0, 3);
        assert!(reward_amount_wide(max, max, max as u256, max, max) == max, 4);
    }

    #[test(framework = @0x1, user = @0x777)]
    fun poc_counter_maximum_and_unrelated_indices(framework: signer, user: signer) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        poc_setup(&framework, &user, vector[@0x11, @0x22, @0x33, @0x44], 2);
        let max = MAX_U64 as u64;
        let performance = &mut borrow_global_mut<ValidatorPerformance>(@topo_framework).validators[0];
        performance.successful_proposals = max - 1;
        performance.failed_proposals = max - 1;
        update_performance_statistics(option::some(0), vector[0]);
        let (success, failed) = get_current_epoch_proposal_counts(0);
        assert!(success == max && failed == max, 1);
        update_performance_statistics(option::some(max), vector[max]);
        let (success, failed) = get_current_epoch_proposal_counts(0);
        assert!(success == max && failed == max, 2);
    }

    #[test(framework = @0x1, user = @0x777)]
    #[expected_failure(abort_code = 0x20024, location = Self)]
    fun poc_counter_success_overflow_rejected(framework: signer, user: signer) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        poc_setup(&framework, &user, vector[@0x11, @0x22, @0x33, @0x44], 2);
        borrow_global_mut<ValidatorPerformance>(@topo_framework).validators[0].successful_proposals = MAX_U64 as u64;
        update_performance_statistics(option::some(0), vector[]);
    }

    #[test(framework = @0x1, user = @0x777)]
    #[expected_failure(abort_code = 0x20024, location = Self)]
    fun poc_counter_duplicate_failures_overflow_rejected(framework: signer, user: signer) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        poc_setup(&framework, &user, vector[@0x11, @0x22, @0x33, @0x44], 2);
        borrow_global_mut<ValidatorPerformance>(@topo_framework).validators[0].failed_proposals = (MAX_U64 as u64) - 1;
        update_performance_statistics(option::some(1), vector[0, 0]);
    }

    #[test(framework = @0x1, user = @0x777)]
    fun poc_native_transition_then_first_install(framework: signer, user: signer) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        poc_setup(&framework, &user, vector[@0x11, @0x22, @0x33, @0x44], 3);
        assert!(reward_split_configuration_matches(1, 0, 3000, option::none(), option::none()), 7);
        let native_preview = preview_epoch_transition(2, timestamp::now_seconds());
        assert!(native_preview.reason == 0 && !native_preview.poc_enabled, 1);
        assert!(native_preview.validator_set.total_voting_power == 400, 2);
        poc_commit(&framework);
        assert!(!is_poc_enabled() && poc_accounting::current_epoch() == 2, 3);
        let first = preview_epoch_transition(3, timestamp::now_seconds());
        assert!(first.reason == 0 && first.poc_enabled && first.validator_set.total_voting_power == 40, 4);
        poc_commit(&framework);
        assert!(is_poc_enabled() && get_installed_reward_context().epoch == 3, 5);
        assert!(get_installed_native_reward_bps() == 3000, 8);
        assert!(!features::is_reconfiguration_frozen() && !exists<EpochPlan>(@topo_framework)
            && !exists<PrecomputedValidatorSet>(@topo_framework), 6);
    }

    #[test(framework = @0x1, user = @0x777, vm = @vm_reserved)]
    fun poc_reward_vault_does_not_compound_native_stake(framework: signer, user: signer, vm: signer) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        poc_setup(&framework, &user, vector[@0x11, @0x22, @0x33, @0x44], 2);
        schedule_reward_split(&framework, 0, 2);
        features::change_feature_flags_for_testing(&framework, vector[features::get_distribute_transaction_fee_feature()], vector[]);
        poc_commit(&framework);
        let (active, inactive, joining, leaving) = get_stake(@0x44);
        let before = vector[active, inactive, joining, leaving];
        update_performance_statistics(option::some(0), vector[]);
        record_fee(&vm, vector[0, 0], vector[49, 18446744073709551615]);
        assert!(get_pending_transaction_fee()[0] == 50, 1);
        poc_commit(&framework);
        let (active, inactive, joining, leaving) = get_stake(@0x44);
        assert!(vector[active, inactive, joining, leaving] == before, 2);
        let claimed = poc_accounting::claim_rewards(&user, vector[@0x44]);
        assert!(coin::value(&claimed) == 50, 3);
        coin::deposit(@0x44, claimed);
        let twice = poc_accounting::claim_rewards(&user, vector[@0x44]);
        coin::destroy_zero(twice);
    }

    #[test(framework = @0x1, user = @0x777, other = @0x888, vm = @vm_reserved)]
    fun poc_binding_bond_cap_preserves_user_reward_ratio(framework: signer, user: signer, other: signer, vm: signer) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        poc_setup(&framework, &user, vector[@0x11, @0x22, @0x33, @0x44], 2);
        // 两个用户分别提供 10、30 算力，池内原生保证金为 100。
        poc_accounting::replace_allocation(&other, vector[@0x44], vector[10000],
            30u128 << 32, 30u128 << 32, 62);
        poc_accounting::schedule_power_params(&framework,
            poc_accounting::new_power_params(1000000000, 10, 100, 4), 2, 25, true);
        features::change_feature_flags_for_testing(&framework,
            vector[features::get_distribute_transaction_fee_feature()], vector[]);
        let preview = preview_epoch_transition(2, timestamp::now_seconds());
        assert!(preview.reason == 0, 1);
        preview.targets.for_each_ref(|target| {
            if (target.pool == @0x44) {
                assert!(target.units == (40u128 << 32)
                    && target.power == 10 && target.reward_base_octa == 100, 2);
            };
        });
        poc_commit(&framework);
        let (units, _, reward_base_octa, vault, _) = poc_accounting::get_pool(@0x44);
        assert!(units == (40u128 << 32) && reward_base_octa == 100 && vault == 0
            && get_current_epoch_voting_power(@0x44) == 10, 3);
        // 保证金将共识权重限制为 100 / 10 = 10，低于总算力 40 和 max_power 100。
        // 1 通胀全部归 PoC，27 费用分为原生 8、PoC 19；PoC 的 20 可按 1:3 精确分配。
        let index = get_validator_index(@0x44);
        update_performance_statistics(option::some(index), vector[]);
        record_fee(&vm, vector[index], vector[27]);
        poc_commit(&framework);
        let (active, _, _, _) = get_stake(@0x44);
        assert!(active == 108, 4);
        let first = poc_accounting::claim_rewards(&user, vector[@0x44]);
        let second = poc_accounting::claim_rewards(&other, vector[@0x44]);
        assert!(coin::value(&first) == 5 && coin::value(&second) == 15, 5);
        coin::merge(&mut first, second);
        coin::deposit(@0x44, first);
        let (_, _, _, vault, _) = poc_accounting::get_pool(@0x44);
        assert!(vault == 0, 6);
    }

    #[test(framework = @0x1, user = @0x777)]
    fun poc_claim_during_freeze_keeps_target_and_cutoff(framework: signer, user: signer) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        poc_setup(&framework, &user, vector[@0x11, @0x22, @0x33, @0x44], 2);
        let owner = create_signer::create_signer(@0x44);
        unlock(&owner, 100);
        let cutoff = timestamp::now_seconds();
        let preview = preview_epoch_transition(2, cutoff);
        assert!(try_cache_epoch_plan(2, cutoff) == 0, 1);
        reconfiguration_state::on_reconfig_start();
        let set = cached_validator_set();
        let data = borrow_global<EpochPlan>(@topo_framework).data;
        timestamp::update_global_time_for_test_secs(7200);
        let claimed = poc_accounting::claim_rewards(&user, vector[@0x44]);
        coin::destroy_zero(claimed);
        assert!(cached_validator_set() == set, 2);
        assert!(preview_epoch_transition(99, 7200) == preview, 3);
        assert!(try_cache_epoch_plan(2, 7200) == 0 && next_validator_consensus_infos_v2() == set, 5);
        assert!(borrow_global<EpochPlan>(@topo_framework).data == data
            && cached_epoch_preview() == preview, 6);
        settle_closing_epoch();
        apply_cached_features(&framework);
        install_epoch_plan(2);
        assert!(*borrow_global<ValidatorSet>(@topo_framework) == preview.validator_set, 7);
        finish_epoch_plan();
        reconfiguration_state::on_reconfig_finish();
        let (_, inactive, _, pending_inactive) = get_stake(@0x44);
        assert!(inactive == 0 && pending_inactive == 100, 4);
    }

    #[test(framework = @0x1, user = @0x777)]
    fun poc_deferred_keeps_epoch_and_allows_repair(framework: signer, user: signer) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        poc_setup(&framework, &user, vector[@0x11, @0x22, @0x33, @0x44], 2);
        poc_accounting::replace_allocation(&user, vector[@0x11], vector[10000], 40u128 << 32, 40u128 << 32, 62);
        let old = *borrow_global<ValidatorSet>(@topo_framework);
        assert!(try_cache_epoch_plan(2, timestamp::now_seconds()) == INSUFFICIENT_VALIDATORS, 1);
        assert!(poc_accounting::current_epoch() == 1 && !reconfiguration_state::is_in_progress()
            && !features::is_reconfiguration_frozen() && !exists<EpochPlan>(@topo_framework), 2);
        assert!(*borrow_global<ValidatorSet>(@topo_framework) == old, 3);
        poc_accounting::replace_allocation(&user, vector[@0x11, @0x22, @0x33, @0x44], vector[2500, 2500, 2500, 2500],
            40u128 << 32, 40u128 << 32, 62);
        poc_commit(&framework);
        assert!(get_installed_reward_context().poc_enabled, 4);
    }

    #[test(framework = @0x1, user = @0x777)]
    #[expected_failure(abort_code = 0x30014, location = Self)]
    fun poc_frozen_capability_lockup_rejected(framework: signer, user: signer) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        poc_setup(&framework, &user, vector[@0x11, @0x22, @0x33, @0x44], 2);
        assert!(try_cache_epoch_plan(2, timestamp::now_seconds()) == 0, 1);
        reconfiguration_state::on_reconfig_start();
        increase_lockup_with_cap(borrow_global<OwnerCapability>(@0x44));
    }

    #[test(framework = @0x1, user = @0x777)]
    #[expected_failure(abort_code = 0x30020, location = Self)]
    fun poc_second_settlement_rejected(framework: signer, user: signer) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        poc_setup(&framework, &user, vector[@0x11, @0x22, @0x33, @0x44], 2);
        assert!(try_cache_epoch_plan(2, timestamp::now_seconds()) == 0, 1);
        reconfiguration_state::on_reconfig_start();
        settle_closing_epoch();
        settle_closing_epoch();
    }
    #[test_only]
    fun poc_add_replacement(framework: &signer, pool: address) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        let owner = create_signer::create_signer(pool);
        let (_sk, pk, pop) = generate_identity();
        initialize_test_validator(&pk, &pop, &owner, 100, false, false);
        poc_accounting::enable_pool(framework, pool);
        poc_accounting::replace_allocation(&owner, vector[pool], vector[10000], 10u128 << 32, 10u128 << 32, 62);
        join_validator_set(&owner, pool);
    }

    #[test(framework = @0x1, user = @0x777)]
    fun poc_voluntary_cancel_preserves_old_indices(framework: signer, user: signer) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        poc_setup(&framework, &user, vector[@0x11, @0x22, @0x33, @0x44], 2);
        poc_commit(&framework);
        let old_index = get_validator_index(@0x44);
        poc_add_replacement(&framework, @0x55);
        assert!(borrow_global<ValidatorSet>(@topo_framework).pending_active[0].voting_power == 0, 1);
        assert!(borrow_global<ValidatorSet>(@topo_framework).total_joining_power == 0, 2);
        let operator = create_signer::create_signer(@0x44);
        let hypothetical = preview_transition(3, timestamp::now_seconds(), option::some(@0x44));
        leave_validator_set(&operator, @0x44);
        assert!(preview_transition(3, timestamp::now_seconds(), option::none()).validator_set == hypothetical.validator_set, 8);
        assert!(get_validator_state(@0x44) == VALIDATOR_STATUS_PENDING_INACTIVE, 3);
        cancel_leave_validator_set(&operator, @0x44);
        assert!(get_validator_state(@0x44) == VALIDATOR_STATUS_ACTIVE, 4);
        assert!(get_validator_index(@0x44) == old_index
            && get_current_epoch_voting_power(@0x44) == 10
            && borrow_global<ValidatorSet>(@topo_framework).total_voting_power == 40, 5);
        // 再次申请同一替换，验证生产构建器仍能生成合格目标。
        leave_validator_set(&operator, @0x44);
        poc_commit(&framework);
        assert!(get_validator_state(@0x44) == VALIDATOR_STATUS_INACTIVE
            && get_current_epoch_voting_power(@0x55) == 10, 6);
        let (_, _, old_base, _, _) = poc_accounting::get_pool(@0x44);
        assert!(old_base == 0, 7);
    }

    #[test(framework = @0x1, user = @0x777, vm = @vm_reserved)]
    fun poc_capacity_v8_union15_deferred16_repair(framework: signer, user: signer, vm: signer) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        poc_setup(&framework, &user, vector[@0x11, @0x22, @0x33, @0x44], 2);
        features::change_feature_flags_for_testing(&framework,
            vector[features::get_distribute_transaction_fee_feature()], vector[]);
        poc_commit(&framework);
        // 每次加入均满足实际增长预算；不同用户各向一个池分配算力。
        vector[@0x55, @0x66, @0x77, @0x88].for_each_ref(|pool| {
            poc_add_replacement(&framework, *pool);
            poc_commit(&framework);
        });
        assert!(poc_accounting::validator_limit() == 8
            && borrow_global<ValidatorSet>(@topo_framework).active_validators.length() == 8
            && borrow_global<ValidatorSet>(@topo_framework).total_voting_power == 80, 1);
        let old_index = get_validator_index(@0x11);
        let exiting = vector[@0x22, @0x33, @0x44, @0x55, @0x66, @0x77, @0x88];
        remove_validators(&framework, &exiting);
        vector[@0x99, @0xaa, @0xbb, @0xcc, @0xdd, @0xee, @0xff].for_each_ref(|pool| {
            poc_add_replacement(&framework, *pool);
        });
        let current = *borrow_global<ValidatorSet>(@topo_framework);
        assert!(current.active_validators.length() == 1 && current.pending_active.length() == 7
            && current.pending_inactive.length() == 7 && current.total_voting_power == 80, 2);
        let epoch = poc_accounting::current_epoch();
        let (_, period, boundary, index, _, _) = poc_power_store::get_normalization_clock();
        let deferred = preview_epoch_transition(epoch + 1, timestamp::now_seconds());
        assert!(deferred.targets.length() == 15 && deferred.reason == INSUFFICIENT_VALIDATORS
            && deferred.validator_set.active_validators.length() == 1, 3);
        // 模拟旧 Epoch 连续出块：继续累计表现和费用，目标与时钟保持不变。
        for (_i in 0..16) {
            timestamp::fast_forward_seconds(1);
            update_performance_statistics(option::some(old_index), vector[]);
            record_fee(&vm, vector[old_index], vector[1]);
            assert!(try_cache_epoch_plan(epoch + 1, timestamp::now_seconds()) == INSUFFICIENT_VALIDATORS, 4);
            assert!(!exists<EpochPlan>(@topo_framework) && !exists<PrecomputedValidatorSet>(@topo_framework)
                && !features::is_reconfiguration_frozen() && !reconfiguration_state::is_in_progress(), 5);
            assert!(*borrow_global<ValidatorSet>(@topo_framework) == current
                && poc_accounting::current_epoch() == epoch, 6);
        };
        let (success, failed) = get_current_epoch_proposal_counts(old_index);
        assert!(success == 16 && failed == 0 && get_pending_transaction_fee()[old_index] == 16, 7);
        let (_, next_period, next_boundary, next_index, _, _) = poc_power_store::get_normalization_clock();
        assert!(period == next_period && boundary == next_boundary && index == next_index, 8);
        let (_, _, old_base, vault, _) = poc_accounting::get_pool(@0x11);
        let (units, future_units, _, _, _) = poc_accounting::get_pool(@0x99);
        assert!(old_base == 10 && vault == 0 && units == 0 && future_units == (10u128 << 32), 9);
        // 治理修复参数后，八名候选在原有的 20 权重预算内全部合格。
        let config = staking_config::get();
        poc_accounting::schedule_power_params(&framework, poc_accounting::new_power_params(100000000, 2, 2, 4),
            epoch + 1, staking_config::get_voting_power_increase_limit(&config),
            staking_config::get_allow_validator_set_change(&config));
        let ready = preview_epoch_transition(epoch + 1, timestamp::now_seconds());
        assert!(ready.reason == 0 && ready.targets.length() == 15
            && ready.validator_set.active_validators.length() == 8
            && ready.validator_set.total_voting_power == 16, 10);
        let expected_order = vector[@0x11, @0xff, @0xee, @0xdd, @0xcc, @0xbb, @0xaa, @0x99];
        for (i in 0..8) {
            let validator = ready.validator_set.active_validators[i];
            assert!(validator.addr == expected_order[i] && validator.voting_power == 2, 11);
        };
        poc_commit(&framework);
        assert!(*borrow_global<ValidatorSet>(@topo_framework) == ready.validator_set
            && poc_accounting::current_epoch() == epoch + 1, 12);
        exiting.for_each_ref(|pool| {
            let (_, _, base, _, _) = poc_accounting::get_pool(*pool);
            assert!(base == 0 && get_validator_state(*pool) == VALIDATOR_STATUS_INACTIVE, 13);
        });
        let (_, _, base, vault, _) = poc_accounting::get_pool(@0x11);
        assert!(base == 2 && vault == 12, 14);
        assert!(stake_balances_match(@0x11, vector[104, 0, 0, 0]), 16);
        let (units, _, base, vault, _) = poc_accounting::get_pool(@0x99);
        assert!(units == (10u128 << 32) && base == 2 && vault == 0, 15);
    }

    #[test(framework = @0x1, user = @0x777)]
    #[expected_failure(abort_code = 0x30023, location = Self)]
    fun poc_governance_revokes_voluntary_cancel(framework: signer, user: signer) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        poc_setup(&framework, &user, vector[@0x11, @0x22, @0x33, @0x44], 2);
        poc_commit(&framework);
        poc_add_replacement(&framework, @0x55);
        let operator = create_signer::create_signer(@0x44);
        leave_validator_set(&operator, @0x44);
        remove_validators(&framework, &vector[@0x44]);
        cancel_leave_validator_set(&operator, @0x44);
    }

    #[test(framework = @0x1, user = @0x777)]
    #[expected_failure(abort_code = 0x30022, location = Self)]
    fun poc_competing_replacements_reject_unsafe_leave(framework: signer, user: signer) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        poc_setup(&framework, &user, vector[@0x11, @0x22, @0x33, @0x44], 2);
        poc_commit(&framework);
        poc_add_replacement(&framework, @0x55);
        poc_add_replacement(&framework, @0x66);
        let operator = create_signer::create_signer(@0x44);
        leave_validator_set(&operator, @0x44);
    }

    #[test(framework = @0x1, user = @0x777)]
    fun poc_context_rate_changes_only_after_install(framework: signer, user: signer) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        poc_setup(&framework, &user, vector[@0x11, @0x22, @0x33, @0x44], 3);
        let (_, rate, den) = get_installed_reward_rate();
        assert!(rate == 1 && den == 100, 1);
        // 治理参数已修改，当前原生 Epoch 仍按已安装的奖励配置结算。
        staking_config::update_rewards_rate(&framework, 1, 200);
        let (_, rate, den) = get_installed_reward_rate();
        assert!(rate == 1 && den == 100, 2);
        update_performance_statistics(option::some(0), vector[]);
        poc_commit(&framework);
        let (active, _, _, _) = get_stake(@0x44);
        assert!(active == 101, 3);
        let (poc, rate, den) = get_installed_reward_rate();
        assert!(!poc && rate == 1 && den == 200, 4);
        poc_commit(&framework);
        let (poc, _, _) = get_installed_reward_rate();
        assert!(poc, 5);
    }

    #[test(framework = @0x1, user = @0x777)]
    #[expected_failure(abort_code = 0x30020, location = Self)]
    fun poc_orphan_pvs_rejected(framework: signer, user: signer) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        poc_setup(&framework, &user, vector[@0x11, @0x22, @0x33, @0x44], 2);
        let preview = preview_transition(2, timestamp::now_seconds(), option::none());
        move_to(&framework, PrecomputedValidatorSet { validator_set: preview.validator_set, is_liveness_fallback: false });
        try_cache_epoch_plan(2, timestamp::now_seconds());
    }

    #[test(framework = @0x1, user = @0x777)]
    #[expected_failure(abort_code = 0x30020, location = Self)]
    fun poc_plan_epoch_mismatch_rejected(framework: signer, user: signer) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        poc_setup(&framework, &user, vector[@0x11, @0x22, @0x33, @0x44], 2);
        assert!(try_cache_epoch_plan(2, timestamp::now_seconds()) == 0, 1);
        reconfiguration_state::on_reconfig_start();
        validate_epoch_plan(3);
    }

    #[test(framework = @0x1, user = @0x777)]
    #[expected_failure(abort_code = 0x30020, location = Self)]
    fun poc_install_rejects_wrong_target_epoch(framework: signer, user: signer) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        poc_setup(&framework, &user, vector[@0x11, @0x22, @0x33, @0x44], 2);
        poc_begin_for_test();
        settle_closing_epoch();
        apply_cached_features(&framework);
        // 安装入口必须拒绝与账本及冻结计划不一致的链目标。
        install_epoch_plan(3);
    }

    #[test(framework = @0x1, user = @0x777)]
    fun poc_native_cached_fallback_preserves_preview(framework: signer, user: signer) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        poc_setup(&framework, &user, vector[@0x11, @0x22, @0x33, @0x44], 3);
        staking_config::update_required_stake(&framework, 1000, 10000);
        let preview = preview_epoch_transition(2, timestamp::now_seconds());
        assert!(preview.reason == 0 && !preview.poc_enabled && preview.is_liveness_fallback, 1);
        poc_begin_for_test();
        assert!(cached_epoch_preview() == preview, 2);
        poc_commit(&framework);
        assert!(*borrow_global<ValidatorSet>(@topo_framework) == preview.validator_set, 3);
        assert!(event::was_event_emitted(&ValidatorSetLivenessFallback {
            minimum_stake: 1000,
            emergency_validator_count: preview.validator_set.active_validators.length(),
            total_emergency_voting_power: preview.validator_set.total_voting_power,
        }), 4);
    }
    #[test(framework = @0x1, user = @0x777)]
    fun poc_feature_rate_switch_keeps_closing_context(framework: signer, user: signer) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        poc_setup(&framework, &user, vector[@0x11, @0x22, @0x33, @0x44], 3);
        staking_config::update_rewards_config(&framework, fixed_point64::create_from_rational(1, 200),
            fixed_point64::create_from_rational(0, 1), 86400, fixed_point64::create_from_rational(0, 1));
        features::change_feature_flags_for_next_epoch(&framework,
            vector[features::get_periodical_reward_rate_decrease_feature()], vector[]);
        update_performance_statistics(option::some(0), vector[]);
        poc_commit(&framework);
        let (active, _, _, _) = get_stake(@0x44);
        assert!(active == 101, 1);
        let (poc, rate, denominator) = get_installed_reward_rate();
        assert!(!poc && (rate as u256) * 200 <= (denominator as u256)
            && rate > 0, 2);
    }

    #[test(framework = @0x1)]
    #[expected_failure(abort_code = 0x10011, location = topo_framework::poc_accounting)]
    fun poc_prepare_rejects_hidden_periodical_rate(framework: signer) acquires PendingTransactionFee, TransactionFeeConfig, ValidatorSet {
        initialize_for_test_custom(&framework, 100, 10000, 3600, true, 1, 100, 25);
        staking_config::initialize_rewards(&framework, fixed_point64::create_from_rational(1, 2),
            fixed_point64::create_from_rational(0, 1), 86400, timestamp::now_seconds(),
            fixed_point64::create_from_rational(0, 1));
        set_transaction_fee_limit_per_epoch_per_pool(&framework, 50);
        poc_accounting::prepare(&framework, 1, 2,
            poc_accounting::new_power_params(100000000, 10, 1000, 4),
            poc_accounting::new_deployment_limits(5, 5, 5, 8, 1000, 1, 100, 50, 100), 1, 25, true);
        prepare_poc_context(&framework, 1);
    }

    #[test(framework = @0x1, user = @0x777)]
    #[expected_failure(abort_code = 0x30020, location = Self)]
    fun poc_readonly_preview_rejects_orphan_pvs(framework: signer, user: signer) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet {
        poc_setup(&framework, &user, vector[@0x11, @0x22, @0x33, @0x44], 2);
        let preview = preview_transition(2, timestamp::now_seconds(), option::none());
        move_to(&framework, PrecomputedValidatorSet { validator_set: preview.validator_set, is_liveness_fallback: false });
        preview_epoch_transition(2, timestamp::now_seconds());
    }

    #[test(framework = @0x1)]
    #[expected_failure(abort_code = 0x2000c, location = topo_framework::staking_config)]
    fun poc_prepare_rejects_lockup_that_can_overflow_on_finish(framework: signer) acquires PendingTransactionFee, TransactionFeeConfig, ValidatorSet {
        initialize_for_test_custom(&framework, 100, 10000, MAX_U64 as u64, true, 1, 100, 25);
        staking_config::initialize_rewards(&framework, fixed_point64::create_from_rational(1, 100),
            fixed_point64::create_from_rational(0, 1), 86400, timestamp::now_seconds(),
            fixed_point64::create_from_rational(0, 1));
        set_transaction_fee_limit_per_epoch_per_pool(&framework, 50);
        poc_accounting::prepare(&framework, 1, 2,
            poc_accounting::new_power_params(100000000, 10, 1000, 4),
            poc_accounting::new_deployment_limits(5, 5, 5, 8, 1000, 1, 100, 50, 100), 1, 25, true);
        prepare_poc_context(&framework, 1);
    }

    #[test(framework = @0x1, user = @0x777)]
    fun poc_maximum_safe_lockup_survives_latest_completion_time(framework: signer, user: signer) acquires AllowedValidators, EpochPlan, InstalledRewardContext, OwnerCapability, PendingTransactionFee, PrecomputedValidatorSet, StakePool, TopoCoinCapabilities, TransactionFeeConfig, ValidatorConfig, ValidatorPerformance, ValidatorSet, VoluntaryLeaves {
        poc_setup(&framework, &user, vector[@0x11, @0x22, @0x33, @0x44], 2);
        let max_seconds = (MAX_U64 / 1000000) as u64;
        let safe_duration = (MAX_U64 as u64) - max_seconds;
        staking_config::update_recurring_lockup_duration_secs(&framework, safe_duration);
        timestamp::update_global_time_for_test_secs(4000);
        assert!(preview_epoch_transition(2, 4000).reason == 0, 1);
        assert!(try_cache_epoch_plan(2, 4000) == 0, 2);
        reconfiguration_state::on_reconfig_start();
        timestamp::update_global_time_for_test_secs(max_seconds);
        settle_closing_epoch();
        apply_cached_features(&framework);
        install_epoch_plan(2);
        finish_epoch_plan();
        reconfiguration_state::on_reconfig_finish();
        assert!(get_lockup_secs(@0x44) == (MAX_U64 as u64), 3);
    }
}
