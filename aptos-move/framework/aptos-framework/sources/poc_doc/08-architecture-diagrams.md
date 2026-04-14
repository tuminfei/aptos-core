# 8. 架构图与流程图

## 8.1 当前数据流

```mermaid
graph LR
    subgraph 用户
        A[Staker]
    end
    subgraph 质押层
        B["StakePool<br/>Coin(TopoCoin) 四桶"]
    end
    subgraph 共识层
        C[ValidatorSet<br/>voting_power]
    end
    subgraph 治理层
        D[TopoGovernance<br/>投票/提案]
    end
    subgraph 奖励层
        E[Rewards<br/>mint TopoCoin]
    end

    A -->|"质押 TopoCoin"| B
    B -->|"coin::value = 投票权"| C
    B -->|"coin::value = 投票权"| D
    B -->|"coin::value = 奖励基数"| E
    E -->|"mint 到 active 桶"| B
```

## 8.2 目标数据流

```mermaid
graph LR
    subgraph 链下
        OP[PoC Operator<br/>算力计算服务]
    end
    subgraph 算力层
        PS["PocPowerStore<br/>users = committed snapshot<br/>pending_updates = next period cache<br/>current_period / last_epoch"]
    end
    subgraph 质押注册
        SR["StakingRegistry<br/>users = 主账本<br/>validator.delegators[] = active set"]
    end
    subgraph 用户
        A[Staker/Delegator]
    end
    subgraph 共识层
        C[ValidatorSet<br/>voting_power]
    end
    subgraph 治理层
        D[TopoGovernance<br/>投票/提案]
    end

    OP -->|"stage_batch_update(target_period = current_period + 1)"| PS
    A -->|"deposit() 存入保证金"| SR
    A -->|"delegate() 委托验证者"| SR
    PS --> EP["effective_power =<br/>min(committed_power, deposit_octas / OCTAS_PER_POWER)"]
    SR --> EP
    EP -->|"有效算力"| C
    EP -->|"有效算力"| D
    SR -->|"每 epoch mint 奖励到 deposit"| SR
    A -->|"withdraw_deposit() 退出时取回"| A
```

说明：
- `PowerStore.users` 表实际保存当前 power period 的 committed snapshot。
- `pending_updates` 只保存下一周期待生效更新。
- operator 只需要为 `target_period = current_period + 1` 上传有活动用户；未上传的历史用户在边界提交时自动 carry-forward。
- `StakingRegistry.users` 与 validator 的 `delegator_list` 语义分离：前者是全量主账本，后者只保存通过 `min_active_power` 门槛的 active 成员。
- 旧 `batch_update()` 仍存在，但只是 `stage_batch_update()` 的兼容别名。

## 8.3 Epoch 奖励分配与周期边界流程

```mermaid
sequenceDiagram
    participant Chain as on_new_epoch()
    participant SR as StakingRegistry
    participant PS as PocPowerStore
    participant VS as ValidatorSet

    Note over Chain,VS: 每个 Epoch 切换时

    Chain->>VS: 遍历 active_validators
    loop 每个 validator
        Chain->>SR: get_delegator_list(validator)
        SR-->>Chain: active_delegator_list (含 validator 自身)

        loop 每个 member in active_delegator_list
            Chain->>SR: get_effective_power(member)
            SR->>PS: get_user_committed_power(member)
            PS-->>SR: committed_power
            SR-->>Chain: member_ep
        end

        Note over Chain: pool_power = Σ member_ep (validator 只计一次)
        Note over Chain: epoch_reward = pool_power × rate × perf
        Note over Chain: commission = epoch_reward × bps / 10000
        Note over Chain: distributable = epoch_reward - commission

        loop 每个 member in active_delegator_list
            Chain->>SR: mint(distributable × member_ep / pool_power) → member.deposit
        end
        Chain->>SR: mint(commission + dust) → validator.deposit
    end

    Chain->>PS: commit_next_period_if_boundary()
    Note over PS: 内部 last_epoch += 1
    Note over PS: 若进入新 power period 的第一个 epoch，则 carry-forward + pending merge
    Note over PS: 合并后结果固定为整个新周期的 committed snapshot
    Chain->>SR: sweep active_delegator_list
    Note over SR: 若 effective_power < ceil(min_active_power * bps / 10000)，自动 undelegate + cooldown

    Chain->>VS: 重建 ValidatorSet (按新 committed snapshot 的 effective_power 过滤 minimum_power)
```

## 8.4 用户完整生命周期

```mermaid
sequenceDiagram
    participant U as 用户
    participant SR as StakingRegistry
    participant Mint as TopoCoin Mint

    Note over U,Mint: 1. 存入保证金
    U->>SR: deposit(50_000_000)
    SR->>SR: coin::withdraw → user.deposit += 0.5 TOPO

    Note over U,Mint: 2. 委托给验证者
    U->>SR: delegate(validator_addr)
    SR->>SR: user.delegated_to = validator_addr
    Note over SR: 若 effective_power < min_active_power，则拒绝进入活跃质押
    SR->>SR: validator.delegator_list.add(user)
    SR->>SR: validator.delegator_index.add(user, idx)
    Note over SR: effective_power = min(committed_power, 50_000_000/100_000)

    Note over U,Mint: 3. 多个 epoch 过去，奖励 mint 到 deposit
    Note over SR: 每 epoch: coin::mint(reward) → coin::merge(user.deposit)
    Note over SR: deposit 持续增长（本金+收益）
    Note over SR: operator 中途上传的新算力先进入 pending_updates，下个 power period 才生效
    Note over SR: 长周期中间发生的 delegate/undelegate 只改 registry，不改当期 committed snapshot
    Note over SR: 若边界重算后 effective_power < maintain_threshold，则自动踢出并进入 cooldown

    Note over U,Mint: 4. 退出质押
    U->>SR: undelegate()
    SR->>SR: user.delegated_to = 0x0
    SR->>SR: user.cooldown_until_secs = now + cooldown_secs
    SR->>SR: validator.delegator_list.swap_remove(user)
    Note over SR: effective_power = 0，不再获得新奖励

    Note over U,Mint: 5. 等待冷却期

    Note over U,Mint: 6. 取回全部（本金+收益）
    U->>SR: withdraw_deposit()
    SR->>SR: assert now >= cooldown_until_secs
    SR->>SR: coin::extract_all → transfer 给用户
```

## 8.5 Validator 自委托流程

```mermaid
sequenceDiagram
    participant V as Validator
    participant SR as StakingRegistry
    participant S as stake.move

    V->>SR: register_validator(commission_bps=1000)
    SR->>SR: validators.add(V, ValidatorPool{...})

    V->>SR: deposit(100_000_000)
    Note over SR: 1 TOPO 保证金

    V->>SR: delegate(self)
    SR->>SR: user.delegated_to = self
    SR->>SR: validators[self].delegator_list.add(self)
    Note over SR: validator 自身也在 delegator_list 中

    V->>S: join_validator_set()
    S->>SR: get_effective_power(V)
    SR-->>S: effective_power = min(committed_power, 1000)
    S->>S: assert effective_power >= minimum_power
    S->>S: ValidatorSet.pending_active.add(V)
```

## 8.6 改动范围依赖图

```mermaid
graph TB
    subgraph "新增"
        SR["staking_registry.move"]
    end
    subgraph "核心改动"
        PS["poc_power_store.move<br/>+pending cache +boundary commit +friend"]
        S["stake.move<br/>投票权→算力<br/>奖励→registry"]
        G["topo_governance.move<br/>投票权→算力<br/>移除lockup检查"]
    end
    subgraph "废弃"
        DP["delegation_pool.move"]
        SC["staking_contract.move"]
    end
    subgraph "适配"
        GN["genesis.move"]
        VE["vesting.move"]
        SP["staking_proxy.move"]
        CFG["staking_config.move"]
    end

    PS --> S
    PS --> G
    SR --> S
    SR --> G
    S --> GN
    SR --> GN
    SR --> VE
    SR --> SP
    CFG --> S
    SC -.->|废弃后| VE
    SC -.->|废弃后| SP
```
