# POC Feature Migration Summary

本文档用于把当前 `topo_framework` 分支中的 POC 功能迁移到其他分支。它只整理 POC 功能本身以及必要联动，不覆盖完整 `aptos-framework` 到 `topo-framework` 的命名迁移；完整 framework 命名迁移见 `docs/TOPO_FRAMEWORK_MIGRATION_SUMMARY.md` 和 `docs/TOPO_FRAMEWORK_MIGRATION_TODO.md`。

## 参考分支

- 来源分支: `topo_framework`
- 参考 HEAD: `90658ce1fe`
- 对比基线: `company/main`
- merge-base: `de0e326405517cef605319b23fcc2b1f95a55ca4`

建议迁移时用下面命令核对范围:

```bash
git diff --name-status company/main...topo_framework -- \
  aptos-move/framework/topo-framework/sources/poc \
  aptos-move/framework/topo-framework/sources/genesis.move \
  aptos-move/framework/topo-framework/sources/stake.move \
  aptos-move/framework/topo-framework/sources/topo_governance.move \
  aptos-move/framework/topo-framework/sources/configs/staking_config.move \
  aptos-move/framework/topo-framework/tests/poc* \
  aptos-move/e2e-move-tests/src \
  testsuite/smoke-test/src
```

## 总体目标

POC 功能把传统的 `stake amount = consensus/governance voting power` 改成:

```text
trusted contribution events
  -> off-chain power calculation
  -> poc_power_store committed power
  -> staking_registry effective power
  -> stake::ValidatorSet voting_power
  -> epoch-change ValidatorSet on-chain config
  -> consensus validator verifier for next epoch
```

Rust 共识层仍然通过标准 epoch change 机制读取 `ValidatorSet`，核心改造点在 Move framework: epoch 边界重新计算 `stake::ValidatorSet.active_validators[*].voting_power`，让共识下一 epoch 看到的是 POC effective power。

## 合并原则

迁移 POC 时，不要把 `topo_framework` 分支上的已存在文件整文件覆盖到目标分支。目标分支可能已经包含更新的 framework、stake、governance 或 config 逻辑，必须以目标分支的新代码为基底，只把 POC 所需逻辑按语义合进去。

尤其注意这些高冲突文件:

- `aptos-move/framework/topo-framework/sources/genesis.move`
- `aptos-move/framework/topo-framework/sources/stake.move`
- `aptos-move/framework/topo-framework/sources/topo_governance.move`
- `aptos-move/framework/topo-framework/sources/configs/staking_config.move`

这些文件迁移时应逐段对照函数和调用链，保留目标分支已有的新实现，再插入或改造 POC 相关接线点。只有 `sources/poc/*` 这类目标分支不存在的新模块，才适合按文件新增。

## 迁移边界

POC 迁移的最小完整单元不是 `sources/poc/*`。一次迁移必须同时覆盖以下四类内容，缺一项都不能认为 POC 功能迁移完成:

- POC 模块本身: `poc_registry`、`poc_contribution`、`poc_power_store`、`staking_registry`。
- Stake 接线: `stake.move` 中 validator join、epoch recompute、reward/fee distribution、force undelegate、liveness fallback、next validator set simulator、legacy StakePool compatibility。
- Governance 接线: `topo_governance.move` 中 proposer/voter effective power、early resolution threshold、staking cooldown 联动、POC test-only/运维入口。
- 测试与生成物: framework Move tests、Rust e2e helper、smoke 适配、cached packages。

不要只把 POC 模块编译通过就停止。`stake.move` 和 `topo_governance.move` 是 POC power 真正进入 consensus/governance 行为的地方；如果这两处漏迁，链上模块存在但 validator set、governance voting power、next epoch view 仍可能按 legacy stake 语义运行。

## 核心 Move 模块

### `poc_registry.move`

位置: `aptos-move/framework/topo-framework/sources/poc/poc_registry.move`

职责:

- 管理 DApp 注册信息: `app_admin`、`app_address`、`equity_token_address`、`custody_address`、`metadata_uri`。
- 维护 DApp 自身状态: `ACTIVE`、`PAUSED`、`STOPPED`。
- 维护平台 POC 准入状态: `REGISTERED`、`WHITELISTED`、`SUSPENDED`。
- 提供反查能力，供 `poc_contribution` 按 `app_address`、`custody_address`、`equity_token_address` 校验可信贡献事件。
- 平台可设置 DApp `effective_weight_pbs`，用于 off-chain 计算时调整 DApp 权重。

迁移注意:

- `initialize_registry` 需要 framework signer。
- `register_app` 验证 equity token 是真实 FA Metadata object。
- 修改 equity token 会把 POC listing status 重置为 `REGISTERED`，这是安全约束。

### `poc_contribution.move`

位置: `aptos-move/framework/topo-framework/sources/poc/poc_contribution.move`

职责:

- 是可信 ContributionEvent 的唯一链上入口。
- 通过 registry 解析 app、custody、equity token，不信任外部传入 token 地址。
- 完成 FA 转账后发出 `ContributionEvent { contributor, equity_token, equity_amount, app_address, period }`。
- 提供两种模式:
  - `grant_equity_with_contribution`: 非严格模式，转账成功但 POC 校验失败时不发事件。
  - `grant_equity_with_contribution_strict`: 严格模式，先校验 ACTIVE + WHITELISTED + custody 匹配，失败则交易中止。

迁移注意:

- DApp 合约应从自身 entry 调用该模块，方便 indexer 用 entry module 归因。
- 事件中的 `period` 来自 `poc_power_store::get_current_period()`。

### `poc_power_store.move`

位置: `aptos-move/framework/topo-framework/sources/poc/poc_power_store.move`

职责:

- 保存用户 POC power 的两版本窗口: older/newer。
- 当前 period 内读取稳定，operator 只能 stage `current_period + 1`。
- epoch 边界由 `stake::on_new_epoch` 调 `commit_next_period_if_boundary()` 推进 power period。
- 提供衰减机制 `retention_bps_per_period`，未刷新用户按 period lazy decay。
- genesis 期间可用 `set_genesis_committed_power` 直接写 period 0 快照。

关键约束:

- `stage_batch_update` 只能由 operator 或 framework signer 调用。
- `target_period` 必须等于 `current_period + 1`。
- 同一 target period 重复写入同一用户时保留第一份值，避免同 period 重复覆盖。
- `set_power_period_in_epochs` 只影响后续 period 倒计时，不重解释历史 epoch。

### `staking_registry.move`

位置: `aptos-move/framework/topo-framework/sources/poc/staking_registry.move`

职责:

- 管理 validator pool、delegator deposit、delegation、cooldown、commission。
- 计算 effective power:

```text
raw_effective_power = min(committed_poc_power, deposit_octas * 1_000_000 / octas_per_million_power)
```

- 当 `octas_per_million_power == 0` 时禁用押金背书要求。
- 已委托且押金为正的用户最终 effective power 至少为 1，避免参与中用户被衰减到 0 导致共识崩溃。
- 负责 epoch reward 和 transaction fee 按 delegator effective power 分配，并自动复投到 registry deposit。
- 在 epoch 边界 force-undelegate 低于 `min_active_power * force_exit_power_bps / 10000` 的用户。

迁移注意:

- `staking_registry` 持有一份 `TopoCoin` mint cap，用于 reward/fee 分配。
- `genesis::initialize_topo_coin` 必须先通过 `store_topo_coin_mint_cap` 停放 mint cap。
- `stake.move` 不再直接把 coin stake 当 voting power，而是从 `staking_registry` 读取 pool total power。

## 相关合约联动

### `genesis.move`

关键联动:

- 导入并初始化 `poc_power_store` 和 `staking_registry`。
- `ensure_poc_staking_initialized`:
  - 初始化 power store，默认 operator 为 `@topo_framework`。
  - 初始化 staking registry。
  - `cooldown_secs = max(recurring_lockup_duration, governance_voting_duration)`，防止治理窗口内重复影响。
- genesis validator 初始化流程变成:
  - 创建 owner/operator。
  - 初始化 stake owner。
  - 注册 staking_registry validator pool。
  - 用 `stake_amount * genesis_stake_power_multiplier` 写入 period 0 POC power。
  - deposit 到 registry。
  - delegate 到自身 validator pool。
  - 设置 consensus key/network 地址并 join validator set。

### `stake.move`

关键联动:

- `ValidatorSet` 仍是共识读取的标准资源。
- `join_validator_set_internal` 用 `staking_registry::get_validator_joining_power` 和 `get_validator_total_power` 做准入。
- `stake::initialize_test_validator`、`mint_and_add_stake` 等 test-only helper 也要迁移到 POC-aware 语义，否则 legacy stake tests 会在 registry power、rewards、voting power increase limit 上出现假通过或假失败。
- `on_new_epoch` 的顺序很重要:
  1. 给 active 和 pending_inactive validator 分配 fee/reward。
  2. `poc_power_store::commit_next_period_if_boundary()`。
  3. 对 active/pending_inactive/pending_active pool 执行 force undelegate。
  4. pending_active -> active，pending_inactive -> inactive。
  5. 从 `staking_registry` 重算下一 epoch validator voting power。
  6. 应用 maximum stake、voting power increase limit、minimum stake。
  7. 如果下一 validator set 为空，触发 liveness fallback，保留正 voting power validator。
  8. 更新 `staking_registry.total_staked_power`、validator index、performance、lockup 和 fee aggregator。
- `next_validator_consensus_infos` / `simulate_next_epoch_validator_set` 用于预测下一 epoch validator set，必须和 `on_new_epoch` 行为保持一致。

### `topo_governance.move`

关键联动:

- 提案人和投票人的权重来自 `staking_registry::get_effective_power`。
- `create_proposal_v2` 的 early resolution threshold 使用 `stake::get_current_epoch_governance_voting_power()`，该函数基于当前 active + pending_inactive validator 的 live registry power。
- `update_governance_config` 会调用 `staking_registry::ensure_min_cooldown_secs`，保证 staking cooldown 不短于治理投票期。
- governance 相关测试不能只验证 proposal 状态机，还必须验证 proposer/voter power 来自 POC effective power，且 cooldown 与 voting duration 的联动不会允许治理窗口内重复影响。
- 提供测试/运维便利入口:
  - `force_end_epoch`
  - `force_end_epoch_test_only`
  - `set_power_period_in_epochs_test_only`
  - `stage_power_update_test_only`

### `staking_config.move`

关键联动:

- 保留 minimum/maximum stake、recurring lockup、reward rate、voting power increase limit 等 validator set 参数。
- `stake.move` 用这些参数约束 POC effective power 进入 validator set。
- reward rate 会影响 `staking_registry::distribute_epoch_rewards` 的自动复投。

## 共识链路说明

POC 功能不应直接改 `consensus/safety-rules` 或签名验证逻辑。共识参与者集合通过现有链路变化:

1. `stake::on_new_epoch` 生成新的 `ValidatorSet`。
2. reconfiguration / epoch change 把下一 epoch validator set 写入 ledger info 的 next epoch state。
3. Rust 共识 `EpochManager` 从 on-chain config payload 构造 `EpochState` / `ValidatorVerifier`。
4. leader election、vote verification、quorum certificate 仍使用标准 verifier，只是 voting power 来源已经由 Move 层换成 POC effective power。

迁移风险点:

- 不能产生空 validator set 或全 0 voting power set。
- `simulate_next_epoch_validator_set` 必须和 `on_new_epoch` 保持一致，否则 view/API 看到的下一 epoch 预测会和真实 epoch transition 不一致。
- voting power increase limit、maximum stake、minimum stake、force undelegate 的顺序会影响 liveness。
- consensus safety-critical 代码只做必要适配，不做重构。

## 必迁文件清单

核心协议:

- `aptos-move/framework/topo-framework/sources/poc/poc_registry.move`
- `aptos-move/framework/topo-framework/sources/poc/poc_contribution.move`
- `aptos-move/framework/topo-framework/sources/poc/poc_power_store.move`
- `aptos-move/framework/topo-framework/sources/poc/staking_registry.move`
- `aptos-move/framework/topo-framework/sources/poc/staking_registry.spec.move`
- `aptos-move/framework/topo-framework/sources/genesis.move`，在目标分支新代码基础上合入，不整文件覆盖
- `aptos-move/framework/topo-framework/sources/stake.move`，在目标分支新代码基础上合入，不整文件覆盖
- `aptos-move/framework/topo-framework/sources/topo_governance.move`，在目标分支新代码基础上合入，不整文件覆盖
- `aptos-move/framework/topo-framework/sources/configs/staking_config.move`，在目标分支新代码基础上合入，不整文件覆盖

测试:

- `aptos-move/framework/topo-framework/tests/poc_test_utils.move`
- `aptos-move/framework/topo-framework/tests/poc_consensus_e2e.move`
- `aptos-move/framework/topo-framework/tests/poc_consensus_epoch_e2e.move`
- `aptos-move/e2e-move-tests/src/stake.rs`
- `aptos-move/e2e-move-tests/src/topo_governance.rs`

Smoke tests:

- `testsuite/smoke-test/src/aptos_cli/validator.rs`
- `testsuite/smoke-test/src/consensus/batch_v2_rollout.rs`
- `testsuite/smoke-test/src/consensus/consensus_fault_tolerance.rs`
- `testsuite/smoke-test/src/consensus/optqs_fault_tolerance.rs`

生成物和 SDK:

- `aptos-move/framework/cached-packages/src/head.mrb`
- `aptos-move/framework/cached-packages/src/topo_framework_sdk_builder.rs`
- 迁移后必须重新生成 cached packages，不建议手工编辑生成文件。

运维/演示脚本:

- `poc-dashboard/scripts/initialize_poc_registry.move`
- `poc-dashboard/scripts/stage_power_store_batch.move`
- `poc-dashboard/scripts/set_power_store_operator.move`
- `poc-dashboard/scripts/set_power_store_retention.move`
- `poc-dashboard/scripts/set_dapp_poc_status.move`
- `poc-dashboard/scripts/set_dapp_weight.move`
- `poc-dashboard/scripts/set_staking_config.move`
- `poc-dashboard/scripts/set_staking_rewards_config.move`
- `poc-dashboard/scripts/set_staking_reward_rate.move`
- `poc-dashboard/scripts/set_staking_min_active_power.move`
- `poc-dashboard/scripts/set_staking_force_exit_power_bps.move`
- `poc-dashboard/scripts/set_staking_octas_per_million_power.move`
- `poc-dashboard/scripts/set_staking_cooldown_secs.move`
- `poc-dashboard/scripts/set_epoch_interval.move`
- `poc-dashboard/scripts/update_governance_config.move`
- `poc-dashboard/scripts/set_chain_test_params.move`
- `poc-dashboard/scripts/poc_validator_membership.py`
- `poc-dashboard/scripts/poc_prod_like_validator_cluster.py`

## 测试迁移说明

本次 POC 迁移不只是新增 Move 模块，还需要同步迁移测试入口。测试迁移分三层:

- Framework Move tests: 新增 `poc_test_utils.move`、`poc_consensus_e2e.move`、`poc_consensus_epoch_e2e.move`，覆盖 genesis period 0 power、period 边界提交、validator set 重算、force undelegate、governance effective power 等 POC 主链路。
- Stake / governance compatibility tests: `stake.move`、`delegation_pool.move`、`delegation_pool_integration_tests.move`、`topo_governance.move` 中原有测试要按 POC-era 语义同步更新，覆盖 reward/fee 自动复投、legacy StakePool compatibility、voting power increase limit、proposal/vote effective power。
- Rust e2e helpers: `aptos-move/e2e-move-tests/src/stake.rs` 的 stake helper 改为走 `staking_registry::deposit`，`unlock_stake` / `withdraw_stake` 对 POC 迁移阶段保持兼容空操作；新增 `topo_governance.rs` 用于 governance effective power 相关 e2e 场景。
- Smoke tests: validator CLI、rewards、consensus fault tolerance、batch v2 rollout、optqs fault tolerance 都需要适配 POC power，不再假设 coin stake 直接等于 consensus/governance voting power。

Smoke-test 适配重点:

- 新 validator 加入 validator set 前，需要用 root/test-only 入口写入 committed POC power，并完成 `staking_registry::deposit` / `delegate`，否则会在 `stake::join_validator_set` 准入时触发 `ESTAKE_TOO_LOW`。
- reward smoke 不应再用 `stake::get_stake` 推断奖励增长，因为 consensus voting power 可能受 committed POC power cap 限制；应改查 `staking_registry::get_user_stake_info` 中的 registry deposit，验证 reward/fee 自动复投。
- consensus traffic 应使用 `topo_coin_transfer` payload，并对 submit timeout/error 回退本地 sequence number，避免 failpoint 阶段产生大量假失败。
- POC 迁移后本地 full smoke 并发压力更高，部分 consensus recovery smoke 需要更保守的等待窗口或显式关闭 failpoint，避免因为恢复窗口未完成而误判。

### 2026-06-30 smoke-test 修复记录

本次在 `feat/topo_rebase_poc` 上对照 `topo_framework` 排查 full smoke 失败时确认，以下失败和 POC smoke 迁移直接相关，或需要保留目标分支已有的 randomness/DKG 适配:

- `aptos_cli::validator::{test_large_total_stake,test_join_and_leave_validator,test_owner_create_and_delegate_flow,test_nodes_rewards}`:
  - CLI helper 需要补齐 `staking_registry::{register_validator,deposit,delegate,undelegate,withdraw_deposit}`，以及 root/test-only 的 `stage_power_update`、`set_power_period_in_epochs`、`force_end_epoch`。
  - `initialize_validator` 在当前分支不会自动注册 staking registry validator pool；如果缺少 `staking_registry::register_validator`，`registry_delegate` 会因 `ENOT_VALIDATOR` abort。
  - `poc_power_store::set_power_period_in_epochs` 只影响后续 period 倒计时，不会重置当前默认 60 epoch countdown。测试里 stage power 后必须推进到当前 countdown 结束，或者用能明确重置当前 countdown 的 framework 测试入口；否则 `join_validator_set` 会因 committed power 仍为 0 触发 `EPOWER_BELOW_MIN_ACTIVE`。
  - 对显式关闭 randomness 的 validator smoke，当前分支仍需关闭 Chunky DKG，否则节点可能在 epoch 1 DKG result abort 后进入 `sync_only flag is set`，swarm health check 超时。`topo_framework` 去掉了这段配置，但迁移到当前分支时不能盲目删除。
  - reward smoke 已改为 POC-aware 的 validator set / voting power 检查，不再用 `stake::get_stake` 作为 POC voting power 增长依据。
- `randomness::disable_feature_0::disable_feature_0`:
  - 迁移 `topo_framework` 的 governance gas options、randomness config polling、epoch polling 和 `wait_for_new_dkg_completion`，避免固定等待 epoch 4/5。
  - 当前分支仍要保留 `OnChainChunkyDKGConfig::default_disabled()`。否则测试会卡在 epoch 1，日志表现为 `DKGCompletedSessionResourceMissing`、`ValidatorTransaction(DKGResult(...)) with status code ABORTED` 和 `sync_only flag is set`。
- `chunky_dkg::with_validator_down::chunky_dkg_with_validator_down`:
  - 迁移更长的 DKG latency window，但当前分支 `AggregatedSubtranscript` 仍使用 `dealer_bitmask`，不能照搬 `topo_framework` 中的 `dealers` 字段访问。
- `genesis::test_validator_genesis_transaction_and_db_restore_flow`、`storage::test_db_restore`、`rosetta::test_invalid_transaction_gas_charged`:
  - 迁移 `topo_framework` 中的 smoke harness 适配，包括 debugger binary 获取方式、backup/restore 等待目标和 randomness/Chunky DKG 配置调整。
- `chunky_dkg::governance_recovery::chunky_dkg_stall_governance_recovery` 和 `consensus::batch_v2_rollout::test_batch_v2_tx_rollout`:
  - `topo_framework` 对应变更是删除测试文件。删除 DKG/consensus smoke 属于覆盖面变化，不应在迁移时无确认照搬；需要单独决定是删除、ignore，还是按 POC-era recovery window 改写。

本次 focused 验证已通过:

```bash
cargo check -p smoke-test --tests
git diff --check
RUST_MIN_STACK=33554432 cargo test -p smoke-test aptos_cli::validator::test_large_total_stake -- --nocapture --test-threads=1
RUST_MIN_STACK=33554432 cargo test -p smoke-test aptos_cli::validator::test_join_and_leave_validator -- --nocapture --test-threads=1
RUST_MIN_STACK=33554432 cargo test -p smoke-test aptos_cli::validator::test_owner_create_and_delegate_flow -- --nocapture --test-threads=1
RUST_MIN_STACK=33554432 cargo test -p smoke-test aptos_cli::validator::test_nodes_rewards -- --nocapture --test-threads=1
RUST_MIN_STACK=33554432 cargo test -p smoke-test randomness::disable_feature_0::disable_feature_0 -- --nocapture --test-threads=1
```

### 2026-07-02 topo_framework_v2 功能对齐补充

本次对照 `topo_framework` 迁移到 `topo_framework_v2` 时发现，POC 主链路不能只跑 `TEST_FILTER=poc`。部分 POC 接线会影响 legacy stake、delegation pool、next validator set simulator 和 governance/consensus view，必须跑完整 topo-framework Move package 测试。

本次暴露并补齐的遗漏:

- `stake.move` 的 next-epoch 模拟逻辑需要区分 POC registry power 和 legacy `StakePool` power:
  - 当 validator 已有当前 registry power，但 next period registry power 被 staged 为 0 时，不能直接用 legacy stake 补回，否则会绕过 liveness fallback。
  - 只有纯 legacy pool，或 legacy pool 处于 unlocking/inactive 兼容路径时，才应使用 legacy power 兜底。
  - 相关覆盖: `poc_consensus_epoch_e2e::test_liveness_fallback_preserves_positive_power_when_registry_power_zero`。
- `delegation_pool.move` 初始化/测试辅助路径必须和 POC `staking_registry` 保持同一套单位和地址语义:
  - `commission_percentage` 已经是 bps，不应再次乘以 100。
  - delegation pool 的 registry validator address 是 pool address；owner/delegator 的 deposit/delegate 关系不能和 legacy stake owner 地址混用。
- legacy stake tests 仍需要保留 POC-era reward/fee 自动复投后的余额语义:
  - active validator 多 epoch 后 legacy `StakePool.active` 会随 rewards 增长，不能继续断言为初始 stake。
  - `mint_and_add_stake` 仍应触发 legacy validator-set voting power increase limit，用来覆盖 `EVOTING_POWER_INCREASE_EXCEEDS_LIMIT`。
  - 相关覆盖: `stake::test_active_validator_cannot_add_more_stake_than_limit_in_multiple_epochs` 和 `delegation_pool_integration_tests::test_active_validator_cannot_add_more_stake_than_limit_in_multiple_epochs`。
- delegation pool 的 inactive/pending_inactive 测试需要按当前 lockup 行为断言:
  - validator rejoin 会续期 lockup，expired `pending_inactive` 不应在 join 当下被额外 inactivated。
  - pending withdrawal 的 observed lockup cycle 不应因为没有新增 inactive stake 而提前推进。
  - pending_inactive 在后续 epoch 仍可能继续参与 reward 计算，测试要断言这部分余额变化。
  - 相关覆盖: `delegation_pool::test_inactivate_no_excess_stake`。

本次必须固定到迁移 checklist 的验证命令:

```bash
RUST_MIN_STACK=33554432 cargo run -p aptos -- move test --package-dir aptos-move/framework/topo-framework
```

该命令已确认通过:

```text
Test result: OK. Total tests: 821; passed: 821; failed: 0
```

迁移任何 `aptos-move/framework/topo-framework/**/*.move` 后，还必须用生成脚本更新 cached packages。仅运行 `cargo build -p aptos-cached-packages` 只会编译现有 `head.mrb`，不会重新生成 bundle。

```bash
scripts/cargo_build_aptos_cached_packages.sh
```

## 本次执行迁移总结

本次已经按目标分支现状完成 POC 主体迁移:

- 新增 `sources/poc` 下 POC registry、contribution、power store、staking registry 及 spec。
- 在 `genesis.move` 接入 POC staking 初始化、genesis validator committed power、registry deposit/delegate 和 mint cap 保存。
- 在 `stake.move` 接入 POC effective power 的 validator join、epoch recompute、reward/fee distribution、force undelegate、liveness fallback 和 next validator set 模拟。
- 在 `topo_governance.move` 接入 proposer/voter effective power，并增加本次 smoke 需要的 test-only committed power 入口。
- 新增/迁移 POC framework tests、Rust e2e helper、dashboard/运维脚本，并重新生成 cached packages。
- 修复 smoke-test 中 validator join/reward、consensus traffic、batch v2 等待窗口、optqs failpoint 清理等 POC 适配问题。

本次已完成的验证:

```bash
RUST_MIN_STACK=16777216 TEST_FILTER=poc cargo test -p topo-framework move_framework_unit_tests -- --nocapture
cargo run -p aptos -- move test --package-dir aptos-move/framework/topo-framework
cargo check -p topo-framework
cargo check -p e2e-move-tests
./scripts/cargo_build_aptos_cached_packages.sh
RUST_MIN_STACK=33554432 cargo test -p smoke-test aptos_cli::validator::test_owner_create_and_delegate_flow -- --nocapture --test-threads=1
RUST_MIN_STACK=33554432 cargo test -p smoke-test consensus::consensus_fault_tolerance::test_changing_working_consensus -- --nocapture --test-threads=1
RUST_MIN_STACK=33554432 cargo test -p smoke-test consensus::optqs_fault_tolerance::test_remote_batch_read_from_block_voters -- --nocapture --test-threads=1
```

另外，下面这些 focused smoke 在本次迁移过程中也已确认通过:

- `client::test_basic_restartability`
- `aptos_cli::validator::test_nodes_rewards`
- `consensus::batch_v2_rollout::test_batch_v2_tx_rollout`
- `aptos_cli::validator::test_large_total_stake`
- `consensus::consensus_fault_tolerance::test_changing_working_consensus`

全量 smoke 命令已启动过:

```bash
env RUST_MIN_STACK=33554432 cargo test -p smoke-test -- --nocapture --test-threads=12
```

截至本次文档更新，full smoke 在用户切换任务前仍在运行，尚未拿到最终 pass/fail；已观察到若干前序 smoke 用例通过，且未看到新的 POC 相关 panic。后续合并前仍需重新完整跑完该命令。

## 建议验证命令

```bash
cargo test -p topo-framework
cargo run -p aptos -- move test --package-dir aptos-move/framework/topo-framework
scripts/cargo_build_aptos_cached_packages.sh
cargo test -p e2e-move-tests -- stake
cargo test -p e2e-move-tests -- topo_governance
env RUST_MIN_STACK=33554432 cargo test -p smoke-test -- --nocapture --test-threads=12
```

如果迁移分支触及 Rust 共识、执行或 VM 代码，再追加:

```bash
cargo test -p aptos-consensus
cargo test -p aptos-vm
cargo test -p aptos-block-executor
```
