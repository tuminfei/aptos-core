# 06 — Epoch 边界与奖励分配

本文档深入分析 `on_new_epoch()` 的完整五阶段流程、奖励计算公式、交易费分配机制。

**源文件**：`stake.move:1101-1355`, `poc/staking_registry.move:513-642`

## 6.1 on_new_epoch 五阶段总览

```mermaid
flowchart TD
    START[on_new_epoch 触发] --> P1

    subgraph P1["阶段 1：奖励结算（使用旧 power 快照）"]
        P1A[遍历 active_validators]
        P1B[遍历 pending_inactive]
        P1A --> P1C[update_stake_pool]
        P1B --> P1C
        P1C --> P1D[collect_transaction_fee]
        P1D --> P1E[distribute_transaction_fees]
        P1E --> P1F[distribute_epoch_rewards]
    end

    P1 --> P2

    subgraph P2["阶段 2：Power Period 边界"]
        P2A["commit_next_period_if_boundary()"]
        P2B["last_epoch += 1"]
        P2C{"跨越 period 边界?"}
        P2B --> P2C
        P2C -->|是| P2D["current_period += 1"]
        P2C -->|否| P2E[跳过]
    end

    P2 --> P3

    subgraph P3["阶段 3：强制退出扫描"]
        P3A[遍历 active_validators]
        P3B[遍历 pending_inactive]
        P3C[遍历 pending_active]
        P3A --> P3D["force_undelegate_below_threshold()"]
        P3B --> P3D
        P3C --> P3D
    end

    P3 --> P4

    subgraph P4["阶段 4：状态转换"]
        P4A["pending_active → ACTIVE"]
        P4B["pending_inactive → INACTIVE"]
        P4C["合并 pending_active 到 active"]
        P4D["清空 pending_inactive"]
    end

    P4 --> P5

    subgraph P5["阶段 5：验证者集合重建"]
        P5A[重新计算每个验证者 voting_power]
        P5B{"voting_power >= minimum_stake?"}
        P5B -->|是| P5C[加入 next_epoch_validators]
        P5B -->|否| P5D[标记为 INACTIVE]
        P5E{"next_epoch_validators 为空?"}
        P5E -->|是| P5F[活性回退：保留旧集合]
        P5E -->|否| P5G[更新 active_validators]
        P5G --> P5H[更新 validator_index]
        P5H --> P5I[重置 performance]
        P5I --> P5J[续期 lockup]
    end
```

## 6.2 阶段 1：奖励结算

### 6.2.1 交易费分配

```mermaid
sequenceDiagram
    participant ST as stake.move
    participant SR as staking_registry

    ST->>ST: collect_transaction_fee_for_validator(index)
    Note over ST: 从 PendingTransactionFee 读取<br/>本 epoch 累积的交易费

    ST->>SR: distribute_transaction_fees(validator, fee_amount)

    SR->>SR: 遍历 delegator_list
    SR->>SR: 计算每个委托者的 effective_power
    SR->>SR: pool_power = Σ(effective_power)

    Note over SR: commission = fee × commission_bps / 10000
    Note over SR: distributable = fee - commission

    loop 每个委托者
        SR->>SR: fee_share = distributable × member_power / pool_power
        SR->>SR: mint fee_share → member.deposit
    end

    SR->>SR: owner_fee = commission + dust
    SR->>SR: mint owner_fee → owner.deposit
```

### 6.2.2 Epoch 奖励分配

```move
public(friend) fun distribute_epoch_rewards(
    validator_address: address,
    num_successful_proposals: u64,
    num_total_proposals: u64,
    rewards_rate: u64,
    rewards_rate_denominator: u64,
)
```

**奖励计算公式**：

```
epoch_reward = pool_power × rewards_rate × num_successful_proposals
               ÷ (rewards_rate_denominator × num_total_proposals)
```

**分配流程**：

```mermaid
graph TD
    A[pool_power = Σ effective_power] --> B["epoch_reward = pool_power × rate × success / (denom × total)"]
    B --> C["commission = epoch_reward × commission_bps / 10000"]
    B --> D["distributable = epoch_reward - commission"]

    D --> E["member_reward = distributable × member_power / pool_power"]
    E --> F["mint → member.deposit"]

    C --> G["dust = distributable - Σ member_reward"]
    G --> H["owner_reward = commission + dust"]
    H --> I["mint → owner.deposit"]
```

### 6.2.3 数值示例

```
假设：
  验证者 A 有 3 个委托者：
    - Owner:  effective_power = 1000
    - User1:  effective_power = 500
    - User2:  effective_power = 300
  pool_power = 1800
  commission_bps = 1000 (10%)
  rewards_rate = 1, rewards_rate_denominator = 100
  num_successful = 95, num_total = 100

计算：
  epoch_reward = 1800 × 1 × 95 / (100 × 100) = 17 (整数截断)
  commission = 17 × 1000 / 10000 = 1
  distributable = 17 - 1 = 16

  Owner reward = 16 × 1000 / 1800 = 8
  User1 reward = 16 × 500 / 1800 = 4
  User2 reward = 16 × 300 / 1800 = 2
  sum_distributed = 8 + 4 + 2 = 14
  dust = 16 - 14 = 2

  Owner 最终获得 = commission(1) + dust(2) + reward(8) = 11
  User1 获得 = 4
  User2 获得 = 2
  总计 = 11 + 4 + 2 = 17 ✓
```

### 6.2.4 u128 防溢出

奖励计算中使用 u128 中间运算：

```move
let reward = (((distributable as u128) * (member_power as u128)) / pool_power) as u64;
```

这防止了 `distributable × member_power` 在 u64 范围内溢出。

## 6.3 阶段 2：Power Period 边界

```move
// stake.move:1166
poc_power_store::commit_next_period_if_boundary();
```

**关键时序**：奖励分配在 period 推进之前完成，确保：
- 奖励按旧 period 的算力分配（公平性）
- 新 period 的算力变化不影响本 epoch 的奖励

```mermaid
graph LR
    subgraph "Epoch N 结束"
        R[奖励分配<br/>使用 period P 的算力] --> C[commit_next_period<br/>period P → P+1]
        C --> F[强制退出扫描<br/>使用 period P+1 的算力]
    end
```

## 6.4 阶段 3：强制退出扫描

对所有三个队列（active、pending_inactive、pending_active）的验证者执行强制退出检查。

```move
// stake.move:1167-1178
validator_set.active_validators.for_each_ref(|v| {
    staking_registry::force_undelegate_below_threshold(v.addr);
});
validator_set.pending_inactive.for_each_ref(|v| {
    staking_registry::force_undelegate_below_threshold(v.addr);
});
validator_set.pending_active.for_each_ref(|v| {
    staking_registry::force_undelegate_below_threshold(v.addr);
});
```

详见 [07-退出状态机与强制退出.md](07-退出状态机与强制退出.md)。

## 6.5 阶段 4：状态转换

```move
// pending_active → ACTIVE
validator_set.pending_active.for_each_ref(|v| {
    staking_registry::set_validator_active(v.addr);
});

// pending_inactive → INACTIVE
validator_set.pending_inactive.for_each_ref(|v| {
    staking_registry::set_validator_inactive(v.addr);
});

// 合并队列
append(&mut validator_set.active_validators, &mut validator_set.pending_active);
validator_set.pending_inactive = vector::empty();
```

## 6.6 阶段 5：验证者集合重建

```mermaid
flowchart TD
    A[遍历 active_validators] --> B[generate_validator_info]
    B --> C["voting_power = get_validator_total_power()"]
    C --> D{"voting_power >= minimum_stake?"}
    D -->|是| E[加入 next_epoch_validators<br/>累加 total_voting_power]
    D -->|否| F[加入 dropped_validators]

    G{next_epoch_validators 非空?}
    E --> G
    F --> G
    G -->|是| H[dropped_validators 标记 INACTIVE<br/>更新 active_validators]
    G -->|否| I[活性回退模式]

    I --> J[保留旧 active_validators<br/>重新计算 voting_power]
    J --> K[emit ValidatorSetLivenessFallback]

    H --> L[更新 validator_index]
    L --> M[重置 ValidatorPerformance]
    M --> N[续期 lockup]
    N --> O[重建 PendingTransactionFee]
    O --> P[更新 total_staked_power]
```

### 活性回退机制

当所有验证者的 `voting_power` 都低于 `minimum_stake` 时，系统进入紧急模式：

```move
if (next_epoch_validators.is_empty()) {
    // 保留旧验证者集合，重新计算投票权
    let refreshed_validators = vector::empty();
    // ... 遍历旧 active_validators，刷新 voting_power ...
    validator_set.active_validators = refreshed_validators;
    event::emit(ValidatorSetLivenessFallback { ... });
}
```

这确保链不会因为没有合格验证者而停机。

### generate_validator_info

```move
fun generate_validator_info(pool_address: address, config: ValidatorConfig): ValidatorInfo {
    let voting_power = staking_registry::get_validator_total_power(pool_address);
    ValidatorInfo { addr: pool_address, voting_power, config }
}
```

投票权直接来自 `staking_registry` 的算力计算，不再依赖 `StakePool` 中的 coin 余额。

## 6.7 奖励自动复利机制

```mermaid
graph LR
    subgraph "Epoch N"
        EP1[effective_power = 500] --> R1[奖励 = 5 TOPO]
        R1 --> D1[deposit += 5 TOPO]
    end

    subgraph "Epoch N+1"
        D1 --> DC2[deposit_cover 增加]
        DC2 --> EP2["effective_power = min(power, 新 cover)"]
        EP2 --> R2[奖励略增]
    end

    subgraph "正向循环"
        R2 -->|"deposit 持续增长"| MORE[可覆盖更多算力]
        MORE -->|"如果算力也在增长"| BIGGER[effective_power 增长]
    end
```

奖励直接 mint 到 `deposit`，无需用户手动操作：
- `deposit` 增长 → `deposit_cover` 增长
- 如果 `committed_power` 是瓶颈，奖励积累为未来的担保余量
- 如果 `deposit_cover` 是瓶颈，奖励直接提升 `effective_power`

## 6.8 交易费记录与分配

### 记录阶段（每个区块）

```move
// 由 VM 调用，记录每个验证者的交易费
public(friend) fun record_fee(
    vm: &signer,
    fee_distribution_validator_indices: vector<u64>,
    fee_amounts_octa: vector<u64>,
)
```

交易费按 `validator_index` 累积到 `PendingTransactionFee` 的 `Aggregator` 中。

### 收集阶段（epoch 边界）

```move
fun collect_transaction_fee_for_validator(validator_index: u64): u64
```

从 `PendingTransactionFee` 中读取并清零该验证者的累积交易费。

### 分配阶段

交易费的分配逻辑与 epoch 奖励完全相同：
1. 计算佣金
2. 按 effective_power 比例分配
3. dust 归验证者 owner

## 6.9 完整时序图

```mermaid
sequenceDiagram
    participant BLK as Block Prologue
    participant ST as stake.move
    participant SR as staking_registry
    participant PS as poc_power_store
    participant SC as staking_config

    Note over BLK,SC: === Epoch 边界触发 ===
    BLK->>ST: on_new_epoch()

    ST->>SC: get_reward_rate()
    SC-->>ST: (rewards_rate, denominator)

    Note over ST,SC: === 阶段 1：奖励结算 ===
    loop 每个 active + pending_inactive 验证者
        ST->>ST: update_stake_pool(validator)
        ST->>ST: collect_transaction_fee(index)
        ST->>SR: distribute_transaction_fees(validator, fee)
        SR->>PS: get_user_committed_power(每个委托者)
        SR->>SR: 计算 effective_power，按比例分配
        SR->>SR: mint 奖励到 deposit

        ST->>SR: distribute_epoch_rewards(validator, proposals, rate)
        SR->>SR: 同上逻辑
    end

    Note over ST,SC: === 阶段 2：Period 边界 ===
    ST->>PS: commit_next_period_if_boundary()
    PS->>PS: last_epoch += 1
    PS->>PS: current_period += 1（如果跨越边界）

    Note over ST,SC: === 阶段 3：强制退出 ===
    loop 每个 active/pending_inactive/pending_active 验证者
        ST->>SR: force_undelegate_below_threshold(validator)
        SR->>SR: 检查每个委托者的 effective_power
        SR->>SR: 低于阈值的自动解委托
    end

    Note over ST,SC: === 阶段 4：状态转换 ===
    ST->>SR: set_validator_active(pending_active 验证者)
    ST->>SR: set_validator_inactive(pending_inactive 验证者)
    ST->>ST: 合并/清空队列

    Note over ST,SC: === 阶段 5：集合重建 ===
    loop 每个 active 验证者
        ST->>SR: get_validator_total_power(validator)
        ST->>ST: 过滤 >= minimum_stake
    end
    ST->>SR: set_total_staked_power(total)
    ST->>ST: 更新 index, 重置 performance, 续期 lockup
```
