# PoC 算力质押模型改造技术方案 v4

## 1. 背景与目标

### 1.1 现状

当前 Topo Chain 沿用 Aptos 原生质押模型，原生代币 TopoCoin（8 位小数，最小单位 octa，1 TOPO = 10^8 octas）的质押量同时决定共识投票权、治理投票权和出块奖励比例。

### 1.2 目标

将上述三者全部替换为 PoC（Proof of Contribution）算力值，TopoCoin 仅保留 Gas 费支付和作为出块奖励货币。

### 1.3 新模型核心规则

| 维度 | 当前模型 | 新模型 |
|------|---------|--------|
| 共识投票权 | 质押量 | 有效算力 |
| 治理投票权 | 质押量 | 有效算力 |
| 奖励分配比例 | 质押量 | 有效算力 |
| 质押行为 | 质押 N 个 TopoCoin | 全部算力质押，保证金按比例决定有效算力 |
| 保证金 | 质押量即权重 | 按算力比例存入 TopoCoin 保证金，不足则有效算力打折 |
| 退出质押 | unlock → 等待 lockup → withdraw | undelegate → 等待冷却期 → withdraw_deposit |
| 委托质押 | 转移 TopoCoin 到 pool | 注册地址到验证者，保证金锁定在 registry 中 |
| 算力快照 | 无 | `PowerStore.users` 保存当前 power period 的 committed snapshot，周期中途更新先写 `pending_updates` |
| 历史算力处理 | 无 | 只在进入新 power period 的边界时，对 committed snapshot 做 retention carry-forward，再与 `pending_updates` 合并 |
| 活跃质押门槛 | 无 | 引入 `min_active_power`；只有 `effective_power >= min_active_power` 的用户才允许进入活跃质押 / 代理质押集合 |
| 强制退出边界 | 无 | 引入 `force_exit_power_bps`；若 `effective_power < ceil(min_active_power * bps / 10000)`，则在 epoch 边界自动踢出并进入 cooldown |
| 奖励发放 | mint TopoCoin 到 StakePool | 每 epoch 直接 mint 到用户保证金（deposit），退出时一并取回 |
| 奖励锁定 | lockup 控制质押解锁 | 无独立锁定，冷却期即提取锁定 |
| 治理投票 | stake_pool 为主键，delegated_voter 代投 | 用户地址为主键，effective_power 直接投票 |

补充说明：
- `power period` 是链 epoch 的整数倍；同一个 power period 内，raw power 来源固定为 `committed_power`。
- operator 周期中途上传的算力只进入 `pending_updates`，不会立刻影响 stake、治理或奖励分配。
- 中心化算力服务只需要上传“下一 power period 内有活动的用户”最新快照；未出现在 `pending_updates` 的历史用户，不会被立刻删除，而是在周期边界提交时按跨越的 period 数继续做 retention 衰减。
- 当 `power_period_in_epochs > 1` 时，周期中每个 epoch 仍然允许 `deposit` / `delegate` / `undelegate` / 代理质押变化，但这些变化不会改写 `PowerStore.users`；`users` 只在新周期开始的第一个 epoch 边界统一切换。
- 为控制大规模 dust 用户导致的遍历成本，`StakingRegistry` 需要区分“用户资金/委托主账本”和“可遍历的活跃质押集合”；数组只保存达到门槛的活跃成员，而不是所有存过保证金的用户。
- `min_active_power` 是入场门槛，`force_exit_power_bps` 是维持门槛，二者形成滞回区间，避免用户在阈值附近频繁进出数组。
- `stake::on_new_epoch()` 先用旧周期 committed snapshot 结算当期奖励，再调用 `poc_power_store::commit_next_period_if_boundary()` 在边界提交下一周期快照。
