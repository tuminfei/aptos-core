# 2. 单位体系与经济参数

## 2.1 单位定义

| 名称 | 类型 | 精度 | 说明 |
|------|------|------|------|
| TOPO | 显示单位 | - | 1 TOPO = 10^8 octas |
| octa | 链上最小单位 | u64 | `coin::value()` 返回值，所有链上金额均为 octas |
| power_snapshot | operator 上传快照 | u64 | 链下算力服务上传的原始值，无小数；运行期写入用户的 future period 版本 |
| committed_power | 目标周期生效算力 | u64 | 读取某个 `target_period` 时，选择 `effective_period <= target_period` 的最新版本，再按跨越 period 数做 retention 衰减得到的 raw power |
| future_power_version | 下一周期版本 | u64 | 当 `target_period = current_period + 1` 时写入 `UserPowerInfo.newer` 的值；当前周期读取不会看到它 |
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
    users: Table<address, UserPowerInfo>,
    user_list: vector<address>,
    retention_bps_per_period: u64,
}

struct PowerVersion has copy, drop, store {
    effective_period: u64,
    power: u64,
}

struct UserPowerInfo has copy, drop, store {
    older: PowerVersion,
    newer: PowerVersion,
}
```

关键规则：
- `power period` 是链 epoch 的整数倍，长度为 `power_period_in_epochs`。
- `users` 为每个用户保留最近两个版本，而不是维护全局 pending cache。
- 读取目标 period `T` 时，优先选择 `effective_period <= T` 的最新版本；若两个版本都晚于 `T`，则该用户在 `T` 的 committed power 为 0。
- 链下中心化算力服务只需要上传“下一周期有活动的用户”最新值；没有新上传的静默用户，会在读取时按 `target_period - effective_period` 连续做 retention 衰减。
- 当前实现用 `last_epoch` 在 `poc_power_store` 内部记录已经经过的 epoch 数，避免 `stake.move` 反向依赖 `reconfiguration.move`。
- `period_for_epoch(epoch) = (epoch - 1) / power_period_in_epochs`；epoch 1 仍属于 period 0。
- 当 `power_period_in_epochs > 1` 时，长周期中间发生的 `deposit` / `delegate` / `undelegate` 只影响保证金和委托关系；stake / reward / governance 读取的 raw power 来源始终由 `current_period` 对应的版本选择结果决定。

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
- 写入的是用户的 future version，`effective_period = target_period`
- 同一用户在一个周期内被多次 stage 时，最后一次值覆盖前一次
- 兼容旧调用名 `batch_update()`，其内部直接转发到 `stage_batch_update()`

周期边界提交接口：

```move
public(friend) fun commit_next_period_if_boundary() acquires PowerStore
```

执行语义：
1. 每次 `stake::on_new_epoch()` 被调用时，`commit_next_period_if_boundary()` 先把 `last_epoch += 1`。
2. 如果 `last_epoch` 还没有跨入新的 power period，则直接返回。
3. 如果跨期了，只推进 `current_period = target_period`，不再全表重写用户算力，也不再执行额外合并步骤。
4. 新周期的 committed power 由读取函数按版本选择规则即时得出：
   - 有 `effective_period = target_period` 的用户，直接读取该版本。
   - 没有新版本的历史用户，继续读取旧版本，并按 `target_period - effective_period` 做 retention 衰减。
5. 因此边界提交的复杂度与用户数量无关；历史静默用户不需要在边界被全量重写。

示例：
- `power_period_in_epochs = 3`
- 当前 `current_period = 0`
- 已有版本：
  - `A = { older: empty, newer: (effective_period = 0, power = 1000) }`
  - `B = { older: empty, newer: (effective_period = 0, power = 500) }`
- 周期中途上传：
  - `stage_batch_update(target_period = 1, {A, C}, {900, 300})`
  - 结果：
    - `A.newer = (1, 900)`，`A.older = (0, 1000)`
    - `C.newer = (1, 300)`
- `retention_bps_per_period = 8000`

则在第 4 个 epoch 进入前执行边界提交后，`current_period` 从 0 进入 1；对 period 1 的读取结果为：

| 用户 | 选中的版本 | retention 次数 | committed_power(period=1) |
|------|------------|----------------|---------------------------|
| A | `(1, 900)` | 0 | 900 |
| B | `(0, 500)` | 1 | 400 |
| C | `(1, 300)` | 0 | 300 |

如果下一周期仍没有任何更新，则在 period 2 读取时：
- `A: 900 -> 720`
- `B: 400 -> 320`
- `C: 300 -> 240`

这意味着：
- 链下只算活动用户即可，静默用户由链上按 retention 自动续算。
- 当前周期读取始终稳定，因为 future version 的 `effective_period > current_period` 时不会被选中。
- 长周期内任意 epoch 的用户行为不会提前改写当前周期 committed power，只会在跨到下一 power period 后切换到对应 future version。

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
| 320 | 1.0 | 1000 | 320 | 历史用户在读取时按 retention 衰减后形成当前 committed_power |
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
