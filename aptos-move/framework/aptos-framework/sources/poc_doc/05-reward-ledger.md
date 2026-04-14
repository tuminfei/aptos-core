# 5. 奖励机制

## 5.1 核心规则

奖励直接 mint 为 TopoCoin 并合并到用户的保证金（`deposit`）中。不存在独立的奖励账本。

```
每 epoch:
  reward = effective_power × rate × performance
  user.deposit += mint(reward)
```

效果：
- 保证金自动增长 → 可覆盖算力增加 → 有效算力可能提升 → 复利
- 不需要 `pending_rewards` 字段
- 不需要 `reward_lockup_until_secs` 字段
- 不需要 `claim_rewards()` 函数
- 用户退出质押（undelegate → cooldown → withdraw_deposit）时一次性取回本金 + 全部收益

## 5.2 UserStakeInfo 简化

```move
struct UserStakeInfo has store {
    /// 保证金 + 累积奖励（合并存储）
    deposit: Coin<TopoCoin>,
    /// 委托给哪个验证者 (0x0 = 未委托)
    delegated_to: address,
    /// undelegate 后的冷却到期时间 (0 = 无冷却)
    cooldown_until_secs: u64,
}
```

对比 v4 旧版（已删除的字段）：
- ~~`pending_rewards: u64`~~ — 不需要，奖励直接进 deposit
- ~~`reward_lockup_until_secs: u64`~~ — 不需要，退出才能提取

## 5.3 distribute_epoch_rewards 逻辑

```
对每个 active validator:
  1. 收集 pool 所有成员的 effective_power
  2. pool_power = Σ effective_power
  3. epoch_reward = calculate_rewards_amount(pool_power, successful, total, rate, denom)
  4. commission = epoch_reward × commission_bps / 10000
  5. distributable = epoch_reward - commission

  对每个 member (含 validator 自身):
      member_ep = effective_power(member)
      member_reward = distributable * member_ep / pool_power  (u128 中间计算)
      coin::mint(member_reward) → coin::merge(member.deposit)
      sum_distributed += member_reward

  dust = distributable - sum_distributed
  coin::mint(commission + dust) → coin::merge(validator.deposit)
```

### 实现要点

```move
public(friend) fun distribute_epoch_rewards(
    validator_perf: &ValidatorPerformance,
    rewards_rate: u64,
    rewards_rate_denominator: u64,
) acquires StakingRegistry {
    let registry = borrow_global_mut<StakingRegistry>(@aptos_framework);
    let mint_cap = &registry.mint_cap;

    // 遍历 active validators (由 stake.move 传入地址列表)
    // ... 对每个 validator:

    let pool_power: u64 = 0;
    let member_powers: vector<u64> = vector[];

    // 1. 收集所有成员的 effective_power
    pool.delegator_list.for_each_ref(|addr| {
        let ep = get_effective_power_internal(registry, *addr);
        member_powers.push_back(ep);
        pool_power += ep;
    });

    if (pool_power == 0) return; // 全员无效算力，跳过

    // 2. 计算 epoch 奖励
    let epoch_reward = calculate_rewards_amount(
        pool_power, successful, total, rewards_rate, rewards_rate_denominator
    );
    if (epoch_reward == 0) return;

    // 3. 佣金
    let commission = (epoch_reward as u128) * (pool.commission_bps as u128) / 10000;
    let commission = (commission as u64);
    let distributable = epoch_reward - commission;

    // 4. 按比例分配，mint 到各成员 deposit
    let sum_distributed: u64 = 0;
    let i = 0;
    while (i < pool.delegator_list.length()) {
        let member_addr = *pool.delegator_list.borrow(i);
        let member_ep = *member_powers.borrow(i);
        if (member_ep > 0) {
            let member_reward = (
                (distributable as u128) * (member_ep as u128) / (pool_power as u128)
            ) as u64;
            if (member_reward > 0) {
                let coins = coin::mint<TopoCoin>(member_reward, mint_cap);
                let info = registry.users.borrow_mut(member_addr);
                coin::merge(&mut info.deposit, coins);
            };
            sum_distributed += member_reward;
        };
        i += 1;
    };

    // 5. commission + dust 归 validator
    let dust = distributable - sum_distributed;
    let validator_extra = commission + dust;
    if (validator_extra > 0) {
        let coins = coin::mint<TopoCoin>(validator_extra, mint_cap);
        let info = registry.users.borrow_mut(validator_addr);
        coin::merge(&mut info.deposit, coins);
    };
}
```

## 5.4 复利效应

```
Epoch 1: power=500, deposit=0.5 TOPO, effective=500, reward=0.01 TOPO
         → deposit 变为 0.51 TOPO, 可覆盖 510 算力

Epoch 2: power=500, deposit=0.51 TOPO, effective=500 (算力仍是瓶颈)
         → reward 不变 (effective 没变)

Epoch N: deposit 持续增长，直到 deposit/OCTAS_PER_POWER > committed_power
         → 此后 effective = committed_power (保证金不再是瓶颈)
         → 超出部分的保证金是"纯收益"，退出时取回
```

当保证金充裕后，复利不再增加当前周期的有效算力（因为 `committed_power` 是当期上限），但保证金余额持续增长，退出时可取回全部。进入下一个 power period 后，如果用户没有新的 pending 更新，新的 committed power 会在边界提交时继续按 retention 衰减。

## 5.5 Rounding dust

整数除法 `distributable * member_ep / pool_power` 向下取整产生 dust。

规则：**dust 归 validator**。

实现：先遍历所有 member 累加 `sum_distributed`，最后 `dust = distributable - sum_distributed` 加到 validator 的 deposit 中。

乘法在 u128 中进行，防止 `distributable * member_ep` 溢出 u64。

## 5.6 pool_power == 0 的处理

如果一个 active validator 的 pool 所有成员 effective_power 都为 0，则 `epoch_reward = 0`，不分配任何奖励。该 validator 在下一次 `on_new_epoch()` 重建 ValidatorSet 时会因 `effective_power < minimum_power` 被踢出。

## 5.7 与 v4 旧版对比

| 维度 | v4 旧版 (pending_rewards) | v4 新版 (mint 到 deposit) |
|------|--------------------------|--------------------------|
| 数据结构 | pending_rewards + reward_lockup_until_secs | 无额外字段 |
| 奖励发放 | 记账，claim 时 mint | 每 epoch 直接 mint 到 deposit |
| 提取方式 | claim_rewards() 随时可领（lockup 后） | undelegate → cooldown → withdraw_deposit |
| 复利 | 无（奖励不增加有效算力） | 有（保证金增长 → 有效算力可能增加） |
| lockup 机制 | reward_lockup_until_secs 每次刷新 | 不需要（cooldown 即锁定） |
| 实现复杂度 | 中（记账 + lockup 刷新 + claim） | 低（直接 mint merge） |
| 每 epoch 链上操作 | 写 pending_rewards (u64 加法) | mint + merge Coin（稍重但可接受） |
