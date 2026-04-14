# 2. 单位体系与经济参数

## 2.1 单位定义

| 名称 | 类型 | 精度 | 说明 |
|------|------|------|------|
| TOPO | 显示单位 | - | 1 TOPO = 10^8 octas |
| octa | 链上最小单位 | u64 | `coin::value()` 返回值，所有链上金额均为 octas |
| power_snapshot | operator 上传快照 | u64 | 链下算力服务上传的原始值，无小数；运行期先写入 `pending_updates` |
| committed_power | 当前周期已提交算力 | u64 | 当前 power period 内固定不变的 raw power 来源 |
| pending_power | 下一周期待生效算力 | u64 | 周期中途上传到 `pending_updates` 的值，边界提交前不参与链上读取 |
| effective_power | 有效算力 | u64 | `min(committed_power, deposit_octas / OCTAS_PER_POWER)` |
| min_active_power | 活跃质押入场门槛 | u64 | `effective_power` 达到该值，才允许进入可遍历的活跃质押集合 |
| force_exit_power | 强制退出门槛 | u64 | `ceil(min_active_power * force_exit_power_bps / 10000)`；跌破后在 epoch 边界自动退出 |

## 2.2 Power period 与边界提交

代码实现的 `PowerStore` 语义：

```move
struct PowerStore has key {
    operator: address,
    power_period_in_epochs: u64,
    last_epoch: u64,
    current_period: u64,
    users: SmartTable<address, UserPowerInfo>, // 当前 committed snapshot
    user_list: vector<address>,
    pending_updates: Table<address, u64>,      // 下一周期待生效更新
    pending_user_list: vector<address>,
    total_power: u64,
    retention_bps_per_period: u64,
}

struct UserPowerInfo has copy, drop, store {
    power: u64,
}
```

关键规则：
- `power period` 是链 epoch 的整数倍，长度为 `power_period_in_epochs`。
- `users` 表示当前 power period 已提交生效的 committed snapshot。
- `pending_updates` 表示下一 power period 的待生效更新。
- 链下中心化算力服务只需要上传“下一周期有活动的用户”最新值；没有新上传的静默用户，继续沿用历史 committed_power，并在边界提交时自动衰减。
- 当前实现用 `last_epoch` 在 `poc_power_store` 内部记录已经经过的 epoch 数，避免 `stake.move` 反向依赖 `reconfiguration.move`。
- `period_for_epoch(epoch) = (epoch - 1) / power_period_in_epochs`；epoch 1 仍属于 period 0。
- 当 `power_period_in_epochs > 1` 时，长周期中间发生的 `deposit` / `delegate` / `undelegate` 只影响保证金和委托关系；stake / reward / governance 读取的 raw power 来源始终是周期开始时已经提交好的 `users`。

周期中途更新接口：

```move
public entry fun stage_batch_update(
    operator: &signer,
    target_period: u64,
    users: vector<address>,
    powers: vector<u64>,
)
```

约束：
- `target_period == current_period + 1`
- 同一用户在一个周期内被多次 stage 时，最后一次值覆盖前一次
- 兼容旧调用名 `batch_update()`，其内部直接转发到 `stage_batch_update()`

周期边界提交接口：

```move
public(friend) fun commit_next_period_if_boundary() acquires PowerStore
```

执行语义：
1. 每次 `stake::on_new_epoch()` 被调用时，`commit_next_period_if_boundary()` 先把 `last_epoch += 1`。
2. 如果 `last_epoch` 进入了新的 power period 起始 epoch，则对旧 `users` 做 retention carry-forward。
3. carry-forward 会按 `periods_elapsed = target_period - previous_period` 连续应用；如果中间跨过多个 period，历史 committed_power 会被多次衰减，而不依赖链下补传全量静默用户。
4. carry-forward 后的历史值再与 `pending_updates` 合并；`pending_updates` 对同地址结果有覆盖优先级。
5. 合并完成后的结果成为整个新周期固定不变的 `users` 读取源。
6. 清空 `pending_updates` / `pending_user_list`。
7. 推进 `current_period`。

示例：
- `power_period_in_epochs = 3`
- 当前 `current_period = 0`
- `users = {A: 1000, B: 500}`
- `pending_updates(target_period = 1) = {A: 900, C: 300}`
- `retention_bps_per_period = 8000`

则在第 4 个 epoch 进入前执行边界提交后：

| 用户 | carry-forward 后 | pending 覆盖后 | 新 committed_power |
|------|------------------|----------------|--------------------|
| A | 800 | 900 | 900 |
| B | 400 | 无 | 400 |
| C | 无 | 300 | 300 |

如果下一周期仍没有任何更新，则再次边界提交后：
- `A: 900 -> 720`
- `B: 400 -> 320`
- `C: 300 -> 240`

这意味着：
- 链下只算活动用户即可，静默用户由链上按 retention 自动续算。
- 长周期内任意 epoch 的用户行为不会提前改写 committed snapshot，只会在下一周期首个 epoch 边界统一生效。

## 2.3 保证金与算力的绑定公式

核心公式（链上实现）：

```move
const OCTAS_PER_POWER: u64 = 100_000; // 0.001 TOPO per power point

public fun get_effective_power(user: address): u64 {
    let committed_power = poc_power_store::get_user_committed_power(user);
    if (committed_power == 0) return 0;

    let info = borrow_user_stake_info(user);
    if (info.delegated_to == @0x0) return 0;

    let deposit_octas = coin::value(&info.deposit);
    let deposit_covers = deposit_octas / OCTAS_PER_POWER;
    math64::min(committed_power, deposit_covers)
}
```

注意：`deposit_octas` 是 `coin::value(&deposit)` 的返回值，单位是 octas。除法天然向下取整。

### 示例

| committed_power | 保证金 (TOPO) | 保证金可覆盖算力 | effective_power | 说明 |
|-----------------|-------------|------------------|----------------|------|
| 500 | 0.05 | 50 | 50 | 保证金不足，算力打折 |
| 500 | 0.5 | 500 | 500 | 刚好覆盖 |
| 500 | 1.0 | 1000 | 500 | 保证金充裕，当前 committed_power 成为上限 |
| 320 | 1.0 | 1000 | 320 | 历史用户跨周期 carry-forward 后形成当前 committed_power |
| 0 | 10.0 | 10000 | 0 | 无 committed_power，保证金无意义 |

## 2.4 活跃质押门槛与强制退出

为限制 `validator.delegator_list` 的规模，下一版设计不再允许任意 dust 用户进入可遍历集合，而是引入两道门槛：

```text
entry_threshold = min_active_power
maintain_threshold = ceil(min_active_power * force_exit_power_bps / 10000)
```

规则：
- 用户调用 `delegate()` / 代理质押时，必须满足 `effective_power >= min_active_power`，否则直接拒绝进入活跃质押集合。
- 用户进入活跃集合后，不要求始终保持在 `min_active_power` 之上；只要 `effective_power >= maintain_threshold`，就继续保留。
- 若在某个 epoch 边界、完成 `commit_next_period_if_boundary()` 之后发现 `effective_power < maintain_threshold`，则自动执行强制退出：
  `delegated_to = 0x0`，从 validator 的活跃数组移除，并开始 `cooldown_secs`。

推荐初始值：
- `force_exit_power_bps = 8000`，即 `80%`
- 例如 `min_active_power = 100` 时：
  `delegate()` 需要 `effective_power >= 100`
  已入场用户只有在 `effective_power < 80` 时才被踢出

这样可以形成滞回区间，避免用户因为 99 ↔ 100 一类抖动反复进出数组。

复杂度收益：
- 可遍历数组只保存达到门槛的活跃成员。
- 理论上 `active_delegator_count <= total_active_power / min_active_power`。
- `users` 主账本仍可容纳任意数量的 deposit 用户，但不会把所有用户都带入每 epoch 的奖励遍历。

## 2.5 参数与配置

`OCTAS_PER_POWER` 保存在 `StakingRegistryConfig` 中；`retention_bps_per_period` 保存在 `PowerStore` 中，均可链上调整。`power_period_in_epochs` 在初始化时写入：
- 默认入口 `poc_power_store::initialize()` / `initialize_power_store()` 使用 `DEFAULT_POWER_PERIOD_IN_EPOCHS = 1`
- 若要部署长周期，当前实现需要在 friend / entry 可配置入口中调用 `initialize_with_power_period()` 或 `initialize_power_store_with_period()`

```move
struct StakingRegistryConfig has copy, drop, store {
    octas_per_power: u64,
    max_delegators_per_validator: u64,
    cooldown_secs: u64,
    min_active_power: u64,
    force_exit_power_bps: u64,
}
```

安全不变量：

```move
assert!(config.cooldown_secs >= governance_config.voting_duration_secs, ECOOLDOWN_TOO_SHORT);
assert!(retention_bps_per_period > 0 && retention_bps_per_period <= 10000, EINVALID_RETENTION_BPS);
assert!(power_period_in_epochs > 0, EINVALID_POWER_PERIOD);
assert!(target_period == current_period + 1, EINVALID_TARGET_PERIOD);
assert!(min_active_power > 0, EINVALID_CONFIG);
assert!(force_exit_power_bps > 0 && force_exit_power_bps <= 10000, EINVALID_CONFIG);
```
