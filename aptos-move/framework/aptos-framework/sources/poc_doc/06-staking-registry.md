# 6. StakingRegistry 数据结构与索引设计

## 6.1 v5 设计调整目标

当前方案里，`ValidatorPool.delegator_list` 会承载所有委托用户。随着 dust 级用户增多，`get_validator_total_power()`、奖励分配、手续费分配都会退化为对大数组的重复遍历。

因此下一版设计目标是：
- `users` 主账本继续保存所有用户的保证金、冷却期、委托关系。
- validator 侧的数组只保存“达到门槛、真正参与结算”的活跃成员。
- 用 `min_active_power` + `force_exit_power_bps` 做准入和维持门槛，保证数组规模由经济门槛自然约束。

## 6.2 完整数据结构

```move
module aptos_framework::staking_registry {
    use std::signer;
    use aptos_std::table::{Self, Table};
    use aptos_std::smart_table::{Self, SmartTable};
    use aptos_framework::coin::{Self, Coin, MintCapability};
    use aptos_framework::topo_coin::TopoCoin;
    use aptos_framework::poc_power_store;
    use aptos_framework::timestamp;
    use aptos_framework::math64;
    use aptos_framework::event;

    friend aptos_framework::stake;
    friend aptos_framework::genesis;

    // ========== 错误码 ==========
    const ENOT_VALIDATOR: u64 = 1;
    const EALREADY_VALIDATOR: u64 = 2;
    const EALREADY_DELEGATED: u64 = 3;
    const ENOT_DELEGATED: u64 = 4;
    const EDEPOSIT_LOCKED: u64 = 5;
    const ECOOLDOWN_ACTIVE: u64 = 6;
    const EZERO_DEPOSIT: u64 = 7;
    const EMAX_DELEGATORS: u64 = 8;
    const EUSER_NOT_FOUND: u64 = 9;
    const EINVALID_COMMISSION: u64 = 10;

    // ========== 核心资源 ==========

    /// 全局质押注册表
    struct StakingRegistry has key {
        /// validator_address → ValidatorPool
        validators: Table<address, ValidatorPool>,
        /// user_address → UserStakeInfo
        users: Table<address, UserStakeInfo>,
        /// 全网已质押有效总算力
        /// 统计范围：所有 active validator 的 delegator_list 中 effective_power > 0 的成员
        /// 更新时机：每 epoch 由 distribute_epoch_rewards 遍历 active validator 时累加
        /// 用途：治理早期决议阈值 = total_staked_power / 2 + 1
        total_staked_power: u64,
        /// TopoCoin mint 能力（用于每 epoch mint 奖励到 deposit）
        mint_cap: MintCapability<TopoCoin>,
        /// 可治理配置
        config: StakingRegistryConfig,
    }

    /// 可治理配置参数
    struct StakingRegistryConfig has copy, drop, store {
        /// 每点有效算力需要的保证金 (octas)
        octas_per_power: u64,
        /// 每个验证者最大活跃 delegator 数
        max_delegators_per_validator: u64,
        /// undelegate 后的冷却期 (秒)
        cooldown_secs: u64,
        /// genesis 阶段由保证金推导 raw power 的倍率
        /// 当前默认值 = 1
        genesis_stake_power_multiplier: u64,
        /// 进入活跃质押集合的最低有效算力
        min_active_power: u64,
        /// 强制退出边界百分比，推荐默认值 8000 = 80%
        force_exit_power_bps: u64,
    }

    /// 验证者节点信息
    struct ValidatorPool has store {
        /// 验证者 owner 地址
        owner_address: address,
        /// active delegator_address → 在 delegator_list 中的 index
        /// 用于 O(1) 删除和防重复
        delegator_index: SmartTable<address, u64>,
        /// 活跃 delegator 地址列表（只保存通过 `min_active_power` 门槛的用户）
        delegator_list: vector<address>,
        /// operator 佣金比例 (basis points, 0-10000)
        commission_bps: u64,
        /// 当前 validator 状态（pending_active / active / pending_inactive / inactive）
        status: u64,
    }

    /// 用户质押信息（验证者和普通用户共用）
    struct UserStakeInfo has store {
        /// 保证金 + 累积奖励（合并存储，奖励直接 mint 进来）
        deposit: Coin<TopoCoin>,
        /// 委托给哪个验证者 (0x0 = 未委托)
        delegated_to: address,
        /// undelegate 后的冷却到期时间 (0 = 无冷却)
        cooldown_until_secs: u64,
    }
}
```

说明：
- `users` 是主账本，覆盖所有 deposit 用户。
- `delegator_list` 的语义调整为“可遍历的 active delegator set”，不再等于“所有曾经 delegate 过的用户”。
- 即使实现上继续沿用 `delegator_list` 这个字段名，其设计语义也应视为“活跃成员集合”。

## 6.3 两层结构

| 层 | 保存内容 | 是否可遍历 | 设计目的 |
|----|---------|-----------|---------|
| 用户主账本 `users` | `deposit`、`delegated_to`、`cooldown_until`、待领取收益 | 否 | 支持任意数量用户，不把全量用户拖入每 epoch 结算 |
| validator 活跃集合 `delegator_list` | 达到门槛、当前参与奖励/投票的成员 | 是 | 只遍历有经济意义的成员，控制复杂度 |

这种分层下：
- `deposit()` 只改主账本，不改数组。
- `delegate()` 必须先通过 `min_active_power` 校验，才能把用户写入 validator 活跃集合。
- `undelegate()` 和强制退出都要把用户从活跃集合移除，但主账本仍保留其保证金和 cooldown 状态。

## 6.4 Delegator 索引设计

v3 中使用裸 `vector<address>` 存储 delegator 列表，存在以下问题：
- undelegate 时删除是 O(n)
- 无法防止重复注册（依赖外部检查）
- 重复 delegate/undelegate 可能残留脏数据

v5 继续使用 **`SmartTable<address, u64>` + `vector<address>`** 双索引，但只对活跃成员生效：

```
delegator_index: SmartTable<address, u64>   // active address → index in delegator_list
delegator_list: vector<address>             // 只遍历 active 成员
```

### delegate 操作 — O(1)

```move
fun add_delegator(pool: &mut ValidatorPool, delegator: address) {
    assert!(effective_power(delegator) >= config.min_active_power, EPOWER_BELOW_MIN_ACTIVE);
    assert!(!pool.delegator_index.contains(delegator), EALREADY_DELEGATED);
    assert!(
        pool.delegator_list.length() < registry.config.max_delegators_per_validator,
        EMAX_DELEGATORS
    );
    let index = pool.delegator_list.length();
    pool.delegator_list.push_back(delegator);
    pool.delegator_index.add(delegator, index);
}
```

### undelegate 操作 — O(1) swap-remove

```move
fun remove_delegator(pool: &mut ValidatorPool, delegator: address) {
    assert!(pool.delegator_index.contains(delegator), ENOT_DELEGATED);
    let index = pool.delegator_index.remove(delegator);
    let last_index = pool.delegator_list.length() - 1;

    if (index != last_index) {
        // swap with last element
        let last_addr = *pool.delegator_list.borrow(last_index);
        *pool.delegator_list.borrow_mut(index) = last_addr;
        // update swapped element's index
        *pool.delegator_index.borrow_mut(last_addr) = index;
    };
    pool.delegator_list.pop_back();
}
```

### 遍历（on_new_epoch 中）

```move
// O(n) 遍历，仅在 on_new_epoch 系统交易中执行
pool.delegator_list.for_each_ref(|addr| {
    let ep = get_effective_power(*addr);
    // ...
});
```

### 强制退出（epoch 边界）

```move
let maintain_threshold =
    ceil(config.min_active_power * config.force_exit_power_bps / 10000);

pool.delegator_list.for_each_ref(|addr| {
    let ep = get_effective_power_after_boundary(*addr);
    if (ep < maintain_threshold) {
        // 从活跃集合移除，并进入 cooldown
        force_undelegate(*addr);
    };
});
```

### 安全保证

| 操作 | 复杂度 | 安全性 |
|------|--------|--------|
| delegate | O(1) | SmartTable.contains 防重复 |
| undelegate | O(1) | swap-remove + index 更新 |
| 遍历 | O(n_active) | 只遍历达到门槛的 active 成员 |
| 强制退出 | O(n_active) | 只在 epoch 边界执行，避免普通交易路径反复 churn |
| 重复 delegate/undelegate | - | delegator_index 是 source of truth，不会残留 |

复杂度边界：
- `n_active` 由经济门槛约束，而不是由全量账户数决定。
- 理论上 `n_active <= total_staked_power / min_active_power`。

## 6.5 有效算力计算

```move
/// 获取用户有效算力
/// effective_power = min(committed_power, deposit_octas / octas_per_power)
/// 返回 0 的情况：未委托、委托到非 active validator、无算力、无保证金
public fun get_effective_power(user: address): u64 acquires StakingRegistry {
    let registry = borrow_global<StakingRegistry>(@aptos_framework);
    if (!registry.users.contains(user)) return 0;

    let info = registry.users.borrow(user);
    // 未委托 → 不参与质押
    if (info.delegated_to == @0x0) return 0;

    // delegated_to 必须是已注册的 validator 且在 active set 中
    if (!registry.validators.contains(info.delegated_to)) return 0;
    let validator_state = stake::get_validator_state(info.delegated_to);
    if (validator_state != VALIDATOR_STATUS_ACTIVE
        && validator_state != VALIDATOR_STATUS_PENDING_INACTIVE) {
        return 0
    };

    let committed_power = poc_power_store::get_user_committed_power(user);
    if (committed_power == 0) return 0;

    let deposit_octas = coin::value(&info.deposit);
    let deposit_covers = deposit_octas / registry.config.octas_per_power;
    math64::min(committed_power, deposit_covers)
}
```

与 `PowerStore` 的接口约定：
- `staking_registry` 只消费 `PowerStore` 的 committed power 读取接口，不直接接触 future version 写入过程。
- 当前实现使用 `poc_power_store::get_user_committed_power(user)`；旧 `get_user_power()` / `get_user_decayed_power()` 仅作为兼容别名保留。
- 预测下一 epoch 时，`staking_registry` 使用 `poc_power_store::get_user_committed_power_for_next_epoch(user)`，该接口会基于下一 epoch 对应的 target period 做版本选择与 retention 计算。
- 周期边界提交由 `stake::on_new_epoch()` 内部调用 `poc_power_store::commit_next_period_if_boundary()` 驱动。
- 在 v5 设计中，边界提交完成后还需要额外做一次 active set sweep，把跌破维持门槛的成员自动移出活跃集合。
