# 16 - POC smoke-test 调查改动总结

本文档总结本轮围绕 POC 共识/质押机制进行的 smoke-test 调查、代码改动、已修复问题、仍失败用例、失败原因和后续修复方案。

当前对应提交：

```text
e70c3640aa test: add POC consensus e2e coverage
```

## 16.1 总体结论

本轮改动解决的是一个主问题：

**原 smoke-test 仍按 Aptos direct stake 模型执行，而当前 POC 机制已经改成“转币 + 上传算力 + staking_registry deposit + delegate + validator join/leave/reward”。**

因此，本轮改动重点不是修改 Rust consensus 协议，而是把测试和 Rust CLI helper 接到新的 Move 合约主链路上。

全量 smoke-test 已经可以跑完整套，不再在最早期 genesis 初始化处整体阻断，但结果仍失败：

```text
command:
env RUST_MIN_STACK=33554432 cargo test -p smoke-test -- --nocapture --test-threads=1

result:
121 passed; 21 failed; 26 ignored; finished in 10466.73s
```

仍失败的核心原因不是单一问题，而是三类问题叠加：

1. POC 流程替换后，部分 validator smoke-test 仍存在 reconfiguration race。
2. DKG / randomness / jwk / decryption 类测试依赖固定 epoch 时序，当前 POC epoch/reconfiguration 行为改变后，这些测试没有同步适配。
3. 部分 smoke-test 依赖全 workspace binary 构建、全局 logger/Lazy 状态或旧的 generated stdlib ABI，仍需要独立修复。

## 16.2 本轮已完成的改动

### 16.2.1 Move 合约测试框架

新增独立 Move 测试文件：

| 文件 | 目的 |
| --- | --- |
| `aptos-move/framework/aptos-framework/tests/poc_test_utils.move` | POC 测试公共工具，集中构造账户、算力、质押、epoch 推进等测试辅助逻辑 |
| `aptos-move/framework/aptos-framework/tests/poc_consensus_e2e.move` | 覆盖 validator/delegator 主生命周期、有效算力、加入退出、奖励分配等主链路 |
| `aptos-move/framework/aptos-framework/tests/poc_consensus_epoch_e2e.move` | 覆盖 epoch 边界、period 推进、staged power 生效、跨 epoch 状态变化 |

设计目标：

- 让 POC 主链路测试从模块内碎片化测试迁移到独立 e2e Move 文件。
- 对核心 Move 状态机进行端到端覆盖。
- 避免把 Rust 网络共识协议问题误归因到 Move 合约逻辑。

### 16.2.2 新增 power period 可配置接口

新增接口：

```move
poc_power_store::set_power_period_in_epochs(&signer, power_period_in_epochs)
```

原因：

- 生产默认 `power_period_in_epochs` 可以保持较长周期。
- 测试环境不能等待 60 个 epoch 才看到 staged power 生效。
- smoke-test 中需要通过接口把 `power_period_in_epochs` 改成 `3`，从而快速验证“上传算力 -> 下一个 period 生效 -> validator join”的流程。

### 16.2.3 新增 test-only 治理桥接接口

新增接口：

```move
topo_governance::set_power_period_in_epochs_test_only(core_resources, power_period_in_epochs)
topo_governance::stage_power_update_test_only(core_resources, user, power)
```

原因：

- smoke-test 使用 Rust CLI helper 提交交易。
- `poc_power_store` 的 operator/framework signer 不应直接暴露给普通账户。
- testnet/smoke 环境已有 `@core_resources` 到 `@0x1` 的 signer 桥接能力，因此通过 `topo_governance` 提供最小 test-only 入口。

边界：

- 这些接口服务于测试链路。
- 生产链应使用正式治理/运营路径修改参数和上传算力。

### 16.2.4 Rust CLI test helper 适配 POC 主链路

在 `crates/aptos/src/test/mod.rs` 中新增 helper：

| helper | 作用 |
| --- | --- |
| `registry_deposit` | 调用 `0x1::staking_registry::deposit` |
| `registry_delegate` | 调用 `0x1::staking_registry::delegate` |
| `registry_undelegate` | 调用 `0x1::staking_registry::undelegate` |
| `registry_withdraw_deposit` | 调用 `0x1::staking_registry::withdraw_deposit` |
| `stage_power_update_via_core_resources` | 通过 `@core_resources` 上传测试算力 |
| `set_power_period_in_epochs_via_core_resources` | 测试中把 `power_period_in_epochs` 改为短周期 |
| `force_end_epoch_via_core_resources` | 测试中显式推进 epoch，使 staged power 变为 live power |

同时将 `set_operator` 改为直接调用 `0x1::stake::set_operator`，避免 CLI 侧 pool discovery 在 POC 流程中无池时静默失败。

### 16.2.5 smoke-test validator 流程替换

已替换的关键流程：

旧流程：

```text
create account
initialize_stake_owner
add_stake
join_validator_set
unlock_stake
withdraw_stake
```

新流程：

```text
create/fund account
initialize_stake_owner
set power_period_in_epochs = 3
stage_power_update
force epoch until power becomes live
staking_registry::deposit
staking_registry::delegate
join_validator_set
leave_validator_set
staking_registry::undelegate
staking_registry::withdraw_deposit
```

已覆盖的 smoke-test 文件：

```text
testsuite/smoke-test/src/aptos_cli/validator.rs
```

主要适配点：

- `test_large_total_stake`：新增 initial balance，先上传算力，再 deposit/delegate，再 join。
- `test_join_and_leave_validator`：用 registry deposit/delegate/undelegate/withdraw 替换 direct stake unlock/withdraw。
- `test_owner_create_and_delegate_flow`：owner/operator 流程切换为 owner deposit/delegate，operator 只负责 metadata/join。
- `test_nodes_rewards`：奖励不再通过 voting power 单调增长直接判断，改成 voting power 不下降。原因是 POC 奖励进入 `staking_registry` deposit，effective voting power 还会被 uploaded power cap 限制。

### 16.2.6 root sequence number 和 logger 修复

新增 root sequence number 同步：

```rust
sync_forge_root_account_seq_num(&swarm, &rest_client)
```

原因：

- CLI 和 forge 分别持有同一个 root key 的本地账户状态。
- CLI 通过 `@core_resources` 提交治理/test-only 交易后，forge 的 root account sequence number 可能落后。
- 后续 forge 再提交 reconfiguration 交易时，如果不 resync，容易出现 sequence number 冲突。

logger 修复：

```rust
static INIT_TEST_LOGGERS: Once = Once::new();
```

原因：

- full smoke-test 在同一进程内多次构建 swarm。
- 直接重复 `Logger::new().init()` / `env_logger::init()` 会触发全局 logger 重复初始化问题。
- 改成 `Once` 后，后续测试不会因为 logger 重复初始化而立即 panic。

## 16.3 已修复或已缓解的问题

### 16.3.1 genesis 初始化 abort

早期失败：

```text
Error calling 0x1.genesis.create_initialize_validators
VMError ABORTED at 0x1::staking_registry
```

根因：

- POC genesis 初始化和 validator 初始 stake/power 映射没有完全对齐。
- `DEFAULT_OCTAS_PER_POWER` 原值过大时，测试 genesis stake 转换出的有效 power 不满足 validator 初始化要求。

修复方向：

- 将 `DEFAULT_OCTAS_PER_POWER` 改为 `1`。
- 确保 POC 初始 validator 的 stake/power 能形成非零 consensus voting power。
- 保留 power period 可配置接口，测试中可以缩短 period。

当前状态：

- full smoke-test 已经能完成大量本地 swarm genesis。
- `storage::test_db_restart` 这类长时间多 epoch / 多 reconfig 测试已经通过，说明 genesis 不再是全局阻断点。

### 16.3.2 direct stake 流程不再匹配 POC

早期失败表现：

- validator 加入失败。
- 大额 stake / owner delegate flow 仍按 direct stake 断言余额和 voting power。
- reward 测试假设 voting power 必须随奖励增加。

根因：

- POC 下，validator 是否能进入 consensus set 不只取决于 direct stake。
- 必须同时满足：
  - 有可转代币。
  - 已上传 POC power。
  - power 已跨 period 生效。
  - 已在 `staking_registry` deposit。
  - 已 delegate 到 validator pool。
  - validator 执行 join。

修复：

- smoke-test 中改为 POC registry 流程。
- 测试里通过 `set_power_period_in_epochs = 3` 降低等待成本。
- 用 `force_end_epoch` 推进 staged power 到 live power。

当前状态：

- 这部分主流程已经进入可执行状态。
- 但部分 validator 测试仍存在 reconfiguration race，见 16.5.1。

### 16.3.3 Rust generated stdlib ABI 部分更新

本轮更新了：

```text
aptos-move/framework/cached-packages/src/aptos_framework_sdk_builder.rs
aptos-move/framework/cached-packages/src/head.mrb
```

目的：

- 让 Rust 侧可构造新 Move entry function 的 payload。
- 让 decoder 能识别新增 test-only / power period 接口。

仍需注意：

- full workspace binary 构建仍有失败风险。
- 部分 crate 可能还引用旧的 generated function 或旧签名，见 16.5.3。

## 16.4 full smoke-test 结果

全量命令：

```bash
env RUST_MIN_STACK=33554432 cargo test -p smoke-test -- --nocapture --test-threads=1
```

最终结果：

```text
FAILED
121 passed
21 failed
26 ignored
0 measured
0 filtered out
finished in 10466.73s
```

失败用例：

```text
account_abstraction::test_ethereum_derivable_account
aptos_cli::validator::test_nodes_rewards
chunky_dkg::correctness::chunky_dkg_correctness
chunky_dkg::enable_feature::chunky_dkg_enable_feature
chunky_dkg::with_validator_down::chunky_dkg_with_validator_down
decryption::test_encryption_key_rotation_and_encrypted_txns
genesis::test_validator_genesis_transaction_and_db_restore_flow
jwks::jwk_consensus_per_key::jwk_consensus_per_key
permissioned_delegation::test_permissioned_delegation
randomness::disable_feature_0::disable_feature_0
randomness::disable_feature_1::disable_feature_1
randomness::dkg_with_validator_join_leave::dkg_with_validator_join_leave
randomness::enable_feature_0::enable_feature_0
randomness::enable_feature_1::enable_feature_1
randomness::enable_feature_2::enable_feature_2
randomness::optimistic_verification::optimistic_verification
rest_api::test_gas_estimation_txns_limit
storage::test_db_restore
test_smoke_tests::test_aptos_node_after_get_bin
txn_emitter::test_txn_emmitter_low_funds
txn_emitter::test_txn_emmitter_with_high_pending_latency
```

关键通过信号：

```text
storage::test_db_restart ... ok
```

该用例经历了多轮 validator restart、频繁 reconfiguration、epoch 推进和 catch-up，最终通过。它说明当前链可以在 POC genesis 和 epoch/reconfig 路径下长期运行，不是“一启动即坏”的状态。

## 16.5 仍失败原因详解

### 16.5.1 `aptos_cli::validator::test_nodes_rewards`

单独复跑命令：

```bash
env RUST_MIN_STACK=33554432 cargo test -p smoke-test aptos_cli::validator::test_nodes_rewards -- --nocapture --test-threads=1
```

最新失败：

```text
thread 'aptos_cli::validator::test_nodes_rewards' panicked at testsuite/smoke-test/src/aptos_cli/validator.rs:777:10:
called `Result::unwrap()` on an `Err` value:
SimulationError("Move abort in 0x1::stake: ERECONFIGURATION_IN_PROGRESS(0x30014): Validator set change temporarily disabled because of in-progress reconfiguration. Please retry after 1 minute.")
Logs located at /tmp/.tmpLG92p2
```

失败位置：

```rust
cli.leave_validator_set(validator_cli_indices[3], None)
    .await
    .unwrap();
```

直接原因：

- 测试在触发 reconfig 后很快调用 `leave_validator_set`。
- 当前链上 `0x1::stake` 仍认为 reconfiguration 正在进行。
- `stake` 模块禁止在 reconfiguration in progress 时修改 validator set，于是返回 `ERECONFIGURATION_IN_PROGRESS`。

为什么本轮改动后更容易出现：

- POC 流程额外引入了 power staging、period 推进、registry deposit/delegate、reward 分发等 epoch 边界逻辑。
- 单测里连续触发 `reconfig`、failpoint、faucet mint、validator leave，这些操作压缩在很短时间内。
- 原 direct stake 流程下的固定 sleep/reconfig 顺序不再足够稳定。

修复方案：

1. 在所有 `join_validator_set` / `leave_validator_set` 前增加显式等待：

   ```text
   wait until reconfiguration_state is not in progress
   ```

2. 对 `ERECONFIGURATION_IN_PROGRESS` 增加 bounded retry：

   ```text
   retry leave/join every few seconds, max wait 60-90s
   ```

3. 将 `test_nodes_rewards` 中的 reconfiguration 编排改成状态驱动，而不是固定 sleep：

   ```text
   trigger reconfig
   wait epoch advanced
   wait reconfiguration finished
   submit validator set change
   trigger next reconfig
   verify set/reward
   ```

4. 保留 root sequence number resync，但不要把它当成 reconfiguration 完成条件。sequence number 只解决账户 nonce 问题，不解决链上 reconfiguration gate。

当前判断：

- 这是测试编排问题，不是 POC Move 主公式错误。
- 但它会阻断 `test_nodes_rewards`，需要继续修。

### 16.5.2 DKG / randomness / decryption / jwks 类失败

涉及失败：

```text
chunky_dkg::correctness::chunky_dkg_correctness
chunky_dkg::enable_feature::chunky_dkg_enable_feature
chunky_dkg::with_validator_down::chunky_dkg_with_validator_down
decryption::test_encryption_key_rotation_and_encrypted_txns
jwks::jwk_consensus_per_key::jwk_consensus_per_key
randomness::disable_feature_0::disable_feature_0
randomness::disable_feature_1::disable_feature_1
randomness::dkg_with_validator_join_leave::dkg_with_validator_join_leave
randomness::enable_feature_0::enable_feature_0
randomness::enable_feature_1::enable_feature_1
randomness::enable_feature_2::enable_feature_2
randomness::optimistic_verification::optimistic_verification
```

已观察到的失败现象包括：

```text
timed out waiting for epoch 3, current epoch is 2
Missing DKG result for epoch 5 / epoch 6
maybe_last_complete.target_epoch() mismatch
SimulationError("MAX_GAS_UNITS_BELOW_MIN_TRANSACTION_GAS_UNITS")
DKG msg "DKGTranscriptRequest" unexpected in state "NotStarted"
Rpc timed out / Application layer unexpectedly dropped response channel
```

共同根因：

- 这些测试高度依赖 epoch 变化、validator set 变化、DKG transcript 生成时机。
- POC 修改后，epoch 边界的工作更多，包括 power period、staking registry、reward、force undelegate 等。
- 原测试里“等待固定 epoch / 固定时间 / 固定 target_epoch”的假设不再稳定。
- validator join/leave 流程也不能再用旧 direct stake 模型，需要走 POC registry 流程。

特别是 `randomness::dkg_with_validator_join_leave`：

- 已观察到 `MAX_GAS_UNITS_BELOW_MIN_TRANSACTION_GAS_UNITS`。
- 说明该测试提交的某些交易在当前 gas schedule / POC framework 路径下，max gas 低于最小交易 gas 或执行路径成本假设已变化。

修复方案：

1. 对所有 DKG/randomness 相关 join/leave 流程做 POC 化：

   ```text
   fund account
   stage power
   wait power live
   deposit
   delegate
   join/leave
   ```

2. 把固定 epoch 断言改为状态等待：

   ```text
   wait until epoch >= target
   wait until DKG result exists for target epoch
   wait until randomness config/version observed by all validators
   ```

3. 将 DKG transcript 检查从“某个固定 epoch 必须已经完成”改成“在 bounded timeout 内完成”。

4. 提高或统一相关测试交易的 max gas，避免 `MAX_GAS_UNITS_BELOW_MIN_TRANSACTION_GAS_UNITS` 这类非业务失败。

5. 对涉及 validator down / restart 的测试，增加 state-sync catch-up 和 DKG state ready 检查，避免节点还在 `NotStarted` 状态时就请求 transcript。

当前判断：

- 这组失败大概率是 POC epoch/reconfiguration 语义改变后的测试时序不适配。
- 需要逐个 targeted rerun，不能只看 full smoke-test 的最终失败列表。

### 16.5.3 workspace binary 构建类失败

涉及失败：

```text
genesis::test_validator_genesis_transaction_and_db_restore_flow
storage::test_db_restore
test_smoke_tests::test_aptos_node_after_get_bin
```

已观察到失败：

```text
Unable to build all workspace binaries. Cannot continue running tests.
Try running 'cargo build --release --all --bins --exclude aptos-node' yourself.
```

早期构建输出中还出现过：

```text
cannot find function `staking_contract_*` in module `aptos_stdlib`
cannot find function `delegation_pool_*` in module `aptos_stdlib`
this function takes N arguments but M arguments were supplied
```

根因：

- 某些 Rust crate 仍引用旧的 generated Move entry function。
- POC / topo governance 改动导致部分 Move ABI 变化后，Rust 侧调用点没有完全同步。
- `smoke-test` 中有些测试会触发 “build all workspace binaries”，这比单独构建 `aptos-node` 更严格。

为什么 targeted `aptos-node` 能跑，而这些测试仍失败：

- 多数 LocalSwarm 测试只需要：

  ```text
  cargo build --features=failpoints,smoke-test --package=aptos-node
  ```

- `storage::test_db_restore` / genesis restore 类测试会构建更多 workspace binaries。
- 因此 `aptos-node` 能过，不代表 `--all --bins --exclude aptos-node` 已过。

修复方案：

1. 先单独跑当前版本的 all-bins 构建，获取最新错误：

   ```bash
   cargo build --features=failpoints,smoke-test --all --bins --exclude aptos-node
   ```

2. 对每个错误分两类处理：

   ```text
   旧函数不存在：改成新的 POC/staking_registry/topo_governance entry function
   参数数量不匹配：同步 Rust callsite 到最新 Move ABI
   ```

3. 如果某些 CLI/Rosetta 功能已经不支持旧 staking/delegation_pool 流程，需要明确删除入口或改成 POC 新流程。

4. all-bins 构建通过后，再复跑：

   ```bash
   env RUST_MIN_STACK=33554432 cargo test -p smoke-test storage::test_db_restore -- --nocapture --test-threads=1
   env RUST_MIN_STACK=33554432 cargo test -p smoke-test genesis::test_validator_genesis_transaction_and_db_restore_flow -- --nocapture --test-threads=1
   env RUST_MIN_STACK=33554432 cargo test -p smoke-test test_smoke_tests::test_aptos_node_after_get_bin -- --nocapture --test-threads=1
   ```

当前判断：

- 这是 Rust workspace build/ABI 同步问题。
- 它和 Move POC 主逻辑不是同一类问题，但会导致 full smoke-test 仍失败。

### 16.5.4 txn_emitter 类失败

涉及失败：

```text
txn_emitter::test_txn_emmitter_low_funds
txn_emitter::test_txn_emmitter_with_high_pending_latency
```

full smoke-test 末尾明确看到：

```text
thread 'txn_emitter::test_txn_emmitter_with_high_pending_latency' panicked:
Lazy instance has previously been poisoned
Logs located at /tmp/.tmpFK5WND
```

根因判断：

- `once_cell::sync::Lazy` 被 poison 通常意味着同进程早先某个全局 Lazy 初始化 panic。
- full smoke-test 是单进程连续跑大量测试，前面的失败可能污染后续全局状态。
- 因此这个失败不一定是 txn_emitter 自身业务逻辑错误，需要 isolated rerun 判断。

修复方案：

1. 单独复跑：

   ```bash
   env RUST_MIN_STACK=33554432 cargo test -p smoke-test txn_emitter::test_txn_emmitter_with_high_pending_latency -- --nocapture --test-threads=1
   env RUST_MIN_STACK=33554432 cargo test -p smoke-test txn_emitter::test_txn_emmitter_low_funds -- --nocapture --test-threads=1
   ```

2. 如果 isolated rerun 通过，则 full-run 中该失败可归类为前序失败导致的污染。

3. 如果 isolated rerun 仍失败，再检查：

   ```text
   transaction emitter 是否依赖旧 gas / balance 假设
   faucet mint / account funding 是否受 POC reward/gas 改动影响
   全局 static 初始化是否仍有非 Once 的 panic 路径
   ```

当前判断：

- full-run 里的 `Lazy poisoned` 更像级联失败。
- 需要 targeted rerun 才能确认是否仍有真实 POC 兼容问题。

### 16.5.5 REST / account abstraction / permissioned delegation 类失败

涉及失败：

```text
account_abstraction::test_ethereum_derivable_account
permissioned_delegation::test_permissioned_delegation
rest_api::test_gas_estimation_txns_limit
```

当前状态：

- full-run 输出只保留了最终失败清单，没有完整 panic 摘要。
- 尚未对这几项做 targeted rerun。
- 不能把它们直接归因为 POC Move 逻辑错误。

可能原因：

- gas estimation 测试可能受 framework gas schedule / min gas / execution path 改动影响。
- permissioned delegation 可能仍走旧 stake/delegation assumption。
- account abstraction 可能是 full-run 级联状态污染，也可能是独立签名/交易模拟路径变化。

修复方案：

逐个 isolated rerun：

```bash
env RUST_MIN_STACK=33554432 cargo test -p smoke-test account_abstraction::test_ethereum_derivable_account -- --nocapture --test-threads=1
env RUST_MIN_STACK=33554432 cargo test -p smoke-test permissioned_delegation::test_permissioned_delegation -- --nocapture --test-threads=1
env RUST_MIN_STACK=33554432 cargo test -p smoke-test rest_api::test_gas_estimation_txns_limit -- --nocapture --test-threads=1
```

判断标准：

- isolated 通过：归类为 full-run 级联失败或资源/全局状态污染。
- isolated 失败：根据 panic 再归类到 gas、ABI、POC stake flow 或账户抽象逻辑。

## 16.6 为什么“仍然失败”

一句话总结：

**本轮改动把 POC 主链路接进了 Move 测试和部分 smoke-test，但 full smoke-test 覆盖的是整个 Aptos 节点生态，仍有大量测试在使用旧 direct stake、固定 epoch、旧 ABI、固定 gas 或全局状态假设。**

具体来说：

1. POC 主流程已经不是 direct stake。
2. validator set 变更必须等待 reconfiguration 完全结束。
3. staged power 不是上传后立即生效，而是跨 period 生效。
4. DKG/randomness/JWK/decryption 强依赖 epoch 时序，必须从固定等待改成状态等待。
5. 全 workspace binaries 仍要同步 generated ABI 和 CLI/Rosetta 调用点。
6. full-run 后段的 Lazy poisoned 可能是前面失败导致的级联污染。

所以，当前失败并不等价于“POC Move 主状态机整体错误”。更准确的判断是：

```text
POC 主链路已部分接通；
smoke-test 全生态仍未全部适配 POC 的新质押/算力/epoch 语义；
需要分组 targeted 修复。
```

## 16.7 后续修复优先级

### P0：修 `test_nodes_rewards` reconfiguration race

目标：

- 消除 `ERECONFIGURATION_IN_PROGRESS`。

改法：

- 新增 helper：

  ```text
  wait_until_reconfiguration_not_in_progress(rest_client)
  retry_validator_set_change_on_reconfiguration_in_progress(...)
  ```

- 在 `join_validator_set` / `leave_validator_set` 前后使用。
- 把固定 sleep 改成 epoch/reconfig 状态驱动。

验收：

```bash
env RUST_MIN_STACK=33554432 cargo test -p smoke-test aptos_cli::validator::test_nodes_rewards -- --nocapture --test-threads=1
```

### P0：修 full workspace binary build

目标：

- 让 restore/genesis/get_bin 类测试不再因构建失败阻断。

命令：

```bash
cargo build --features=failpoints,smoke-test --all --bins --exclude aptos-node
```

修复范围：

- `crates/aptos`
- `crates/aptos-rosetta`
- 所有仍引用旧 `aptos_stdlib::*` generated function 的 crate

验收：

```bash
env RUST_MIN_STACK=33554432 cargo test -p smoke-test storage::test_db_restore -- --nocapture --test-threads=1
env RUST_MIN_STACK=33554432 cargo test -p smoke-test genesis::test_validator_genesis_transaction_and_db_restore_flow -- --nocapture --test-threads=1
```

### P1：修 DKG/randomness/decryption/JWKS 时序

目标：

- 让 epoch / DKG result / randomness result 检查不依赖旧固定时序。

改法：

- join/leave 全部替换为 POC registry flow。
- 增加 DKG result polling。
- 增加 node catch-up / DKG state ready 检查。
- 提高交易 max gas。

验收：

```bash
env RUST_MIN_STACK=33554432 cargo test -p smoke-test randomness::enable_feature_0::enable_feature_0 -- --nocapture --test-threads=1
env RUST_MIN_STACK=33554432 cargo test -p smoke-test randomness::dkg_with_validator_join_leave::dkg_with_validator_join_leave -- --nocapture --test-threads=1
env RUST_MIN_STACK=33554432 cargo test -p smoke-test decryption::test_encryption_key_rotation_and_encrypted_txns -- --nocapture --test-threads=1
env RUST_MIN_STACK=33554432 cargo test -p smoke-test jwks::jwk_consensus_per_key::jwk_consensus_per_key -- --nocapture --test-threads=1
```

### P2：隔离确认级联失败

目标：

- 区分 full-run 污染和真实业务失败。

命令：

```bash
env RUST_MIN_STACK=33554432 cargo test -p smoke-test txn_emitter::test_txn_emmitter_with_high_pending_latency -- --nocapture --test-threads=1
env RUST_MIN_STACK=33554432 cargo test -p smoke-test account_abstraction::test_ethereum_derivable_account -- --nocapture --test-threads=1
env RUST_MIN_STACK=33554432 cargo test -p smoke-test rest_api::test_gas_estimation_txns_limit -- --nocapture --test-threads=1
```

## 16.8 建议的下一轮执行顺序

建议不要直接再次跑 full smoke-test。更高效的顺序是：

1. 先修并通过 `test_nodes_rewards`。
2. 再修并通过 all-bins build。
3. 再分组修 DKG/randomness。
4. 再 isolated rerun 剩余 account/rest/txn emitter。
5. 最后再跑 full smoke-test。

推荐门禁顺序：

```bash
env RUST_MIN_STACK=33554432 cargo test -p smoke-test aptos_cli::validator::test_nodes_rewards -- --nocapture --test-threads=1
cargo build --features=failpoints,smoke-test --all --bins --exclude aptos-node
env RUST_MIN_STACK=33554432 cargo test -p smoke-test randomness::dkg_with_validator_join_leave::dkg_with_validator_join_leave -- --nocapture --test-threads=1
env RUST_MIN_STACK=33554432 cargo test -p smoke-test decryption::test_encryption_key_rotation_and_encrypted_txns -- --nocapture --test-threads=1
env RUST_MIN_STACK=33554432 cargo test -p smoke-test -- --nocapture --test-threads=1
```

## 16.9 当前风险判断

| 风险 | 判断 |
| --- | --- |
| POC Move 主状态机是否完全错误 | 暂无证据。Move 主流程已经可进入 genesis/swarm，并有大量 smoke-test 通过 |
| validator join/leave 是否完全适配 | 部分适配，仍需处理 reconfiguration race |
| reward 测试是否仍沿用旧模型 | 已部分修正 voting power 断言，但 `test_nodes_rewards` 仍需稳定化 |
| DKG/randomness 是否适配 POC epoch 语义 | 尚未完成，需要 P1 修复 |
| Rust CLI/Rosetta ABI 是否完全同步 | 尚未完成，需要 all-bins build 驱动修复 |
| full smoke-test 是否可作为当前唯一判断 | 不建议。当前必须先按失败类别 targeted 修复 |

最终判断：

```text
本轮改动完成了 POC 测试框架和主链路接入；
full smoke-test 仍失败，主要因为测试编排、DKG/epoch 时序、workspace ABI 构建和级联污染尚未全部适配；
下一轮应优先修 reconfiguration race 和 all-bins build，再处理 DKG/randomness 组。
```
