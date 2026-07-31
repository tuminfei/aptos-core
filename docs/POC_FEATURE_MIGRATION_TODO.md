# POC Feature Migration TODO

本文档是把当前分支 POC 功能迁移到其他分支的执行 checklist。配套总结见 `docs/POC_FEATURE_MIGRATION_SUMMARY.md`。

## 0. 迁移原则

- [ ] 先确认目标分支已经完成或兼容 `topo-framework` 命名迁移。
- [ ] 不要把整个 `topo_framework` 分支 cherry-pick 到目标分支。
- [ ] 对目标分支已经存在的文件，只在目标分支新代码基础上合入 POC 逻辑，不用 `topo_framework` 版本整文件覆盖。
- [ ] 把 `sources/poc/*`、`stake.move` POC 接线、`topo_governance.move` POC 接线、相关测试作为同一个迁移单元处理，不要只迁移 POC 模块本身。
- [ ] 在 `stake.move` 和 `topo_governance.move` 的功能与测试都迁移并验证前，不把 POC 迁移标记为完成。
- [ ] 不修改 `consensus/safety-rules`、签名验证、crypto、数据库 schema，除非用户明确确认。
- [ ] 每一步保持可编译或接近可编译，优先小批量提交。
- [ ] Move framework 修改后必须重新生成 cached packages。

高冲突文件必须逐段语义合并:

```text
aptos-move/framework/topo-framework/sources/genesis.move
aptos-move/framework/topo-framework/sources/stake.move
aptos-move/framework/topo-framework/sources/topo_governance.move
aptos-move/framework/topo-framework/sources/configs/staking_config.move
```

## 1. 建立迁移工作区

- [ ] 从目标基线创建迁移分支。

```bash
git status --short
git checkout <target-base>
git pull --ff-only
git checkout -b codex/poc-feature-migration
```

- [ ] 记录来源和目标。

```bash
git rev-parse HEAD
git rev-parse topo_framework
git merge-base topo_framework company/main
```

- [ ] 阅读当前仓库指导。

```bash
sed -n '1,220p' CLAUDE.md
```

## 2. 迁移 POC 核心模块

- [ ] 拷贝或重放 `sources/poc` 下核心模块。

```text
aptos-move/framework/topo-framework/sources/poc/poc_registry.move
aptos-move/framework/topo-framework/sources/poc/poc_contribution.move
aptos-move/framework/topo-framework/sources/poc/poc_power_store.move
aptos-move/framework/topo-framework/sources/poc/staking_registry.move
aptos-move/framework/topo-framework/sources/poc/staking_registry.spec.move
```

- [ ] 检查 `friend` 声明是否和目标分支模块名一致。
- [ ] 检查 named address 是否使用目标分支的 framework address。
- [ ] 检查依赖模块是否存在: `event`、`fungible_asset`、`object`、`primary_fungible_store`、`topo_coin`、`staking_config`。

完成检查:

```bash
cargo check -p topo-framework
```

## 3. 接入 Genesis

- [ ] 以目标分支当前 `genesis.move` 为基底，不整文件覆盖。
- [ ] 对照目标分支已有 genesis 初始化顺序，确认新代码没有被旧分支版本回退。
- [ ] 在 `genesis.move` 中引入:

```move
use topo_framework::poc_power_store;
use topo_framework::staking_registry;
```

- [ ] 在 topo coin 初始化后调用 `staking_registry::store_topo_coin_mint_cap` 保存 mint cap。
- [ ] 添加或迁移 `ensure_poc_staking_initialized`。
- [ ] 在 validator 初始化前调用 `ensure_poc_staking_initialized`。
- [ ] genesis validator 初始化时完成:
  - [ ] `staking_registry::register_validator_for_genesis`
  - [ ] `poc_power_store::set_genesis_committed_power`
  - [ ] `staking_registry::deposit`
  - [ ] `staking_registry::delegate`
  - [ ] 原有 consensus key / network address / join validator set 流程

完成检查:

```bash
cargo test -p topo-framework genesis
```

## 4. 接入 Stake/Epoch

- [ ] 以目标分支当前 `stake.move` 为基底，不整文件覆盖。
- [ ] 先保留目标分支已有 validator lifecycle、fee、reward、lockup、reconfiguration 逻辑，再逐段接入 POC power 计算。
- [ ] 迁移 `stake.move` 内 test-only helper，确保 `initialize_test_validator`、`mint_and_add_stake`、epoch helper 等测试入口会同步 seed committed power / registry deposit / delegate，且保留 legacy StakePool compatibility。
- [ ] 在 `stake.move` 中导入 `poc_power_store` 和 `staking_registry`。
- [ ] 把 validator join 准入从 coin stake 改为 registry power:
  - [ ] `get_validator_joining_power`
  - [ ] `get_validator_total_power`
  - [ ] minimum/maximum stake 仍来自 `staking_config`
- [ ] 在 `on_new_epoch` 中按顺序接入:
  - [ ] active validator fee/reward 分配
  - [ ] pending_inactive validator 最后一个 epoch 的 fee/reward 分配
  - [ ] `poc_power_store::commit_next_period_if_boundary`
  - [ ] `staking_registry::force_undelegate_below_threshold`
  - [ ] pending_active/pending_inactive 状态同步
  - [ ] 重算下一 epoch validator voting power
  - [ ] maximum stake cap
  - [ ] voting power increase limit
  - [ ] minimum stake 过滤
  - [ ] 空集合 liveness fallback
  - [ ] 更新 `staking_registry::set_total_staked_power`
- [ ] 迁移 `next_validator_consensus_infos` 和 `simulate_next_epoch_validator_set`，并确保模拟逻辑和真实 `on_new_epoch` 顺序一致。
- [ ] 保留 `ValidatorSet` 作为共识读取边界，不改变 Rust 共识 verifier 数据结构。

完成检查:

```bash
cargo test -p topo-framework poc_consensus
cargo run -p aptos -- move test --package-dir aptos-move/framework/topo-framework --filter test_active_validator_cannot_add_more_stake_than_limit_in_multiple_epochs
cargo run -p aptos -- move test --package-dir aptos-move/framework/topo-framework --filter test_inactivate_no_excess_stake
```

## 5. 接入 Governance

- [ ] 以目标分支当前 `topo_governance.move` 为基底，不整文件覆盖。
- [ ] 保留目标分支已有 proposal、permissioned signer、reconfiguration、feature toggle 逻辑，再替换 proposer/voter power 来源。
- [ ] 迁移 `topo_governance.move` 内 POC test-only/运维入口，确保测试可 stage power、推进 power period、force end epoch。
- [ ] 在 `topo_governance.move` 中导入 `poc_power_store`、`staking_registry`。
- [ ] 把 proposer stake 检查改为 `staking_registry::get_effective_power`。
- [ ] 把投票剩余权重改为 `staking_registry::get_effective_power(voter) - used_voting_power`。
- [ ] early resolution threshold 使用 `stake::get_current_epoch_governance_voting_power()`。
- [ ] `update_governance_config` 调 `staking_registry::ensure_min_cooldown_secs`。
- [ ] 如目标分支需要测试/运维入口，迁移:
  - [ ] `force_end_epoch_test_only`
  - [ ] `set_power_period_in_epochs_test_only`
  - [ ] `stage_power_update_test_only`

完成检查:

```bash
cargo test -p topo-framework topo_governance
cargo test -p e2e-move-tests -- topo_governance
cargo run -p aptos -- move test --package-dir aptos-move/framework/topo-framework --filter topo_governance
```

## 6. 参数与配置

- [ ] 以目标分支当前 `staking_config.move` 为基底，不整文件覆盖。
- [ ] 如果目标分支已有新的 staking 参数或 reward 逻辑，优先保留，再补齐 POC 需要读取的 minimum/maximum/reward/voting-power-increase 接口。
- [ ] 确认 `staking_config.move` 支持目标 POC 流程需要的配置:
  - [ ] minimum stake
  - [ ] maximum stake
  - [ ] recurring lockup duration
  - [ ] reward rate / denominator
  - [ ] voting power increase limit
- [ ] 确认 `staking_registry` 自身配置默认值:
  - [ ] `octas_per_million_power`
  - [ ] `max_delegators_per_validator`
  - [ ] `cooldown_secs`
  - [ ] `min_active_power`
  - [ ] `force_exit_power_bps`
  - [ ] `retention_bps_per_period`
  - [ ] `power_period_in_epochs`

## 7. 测试迁移

- [ ] 迁移 POC 测试工具:

```text
aptos-move/framework/topo-framework/tests/poc_test_utils.move
```

- [ ] 迁移主链路测试:

```text
aptos-move/framework/topo-framework/tests/poc_consensus_e2e.move
aptos-move/framework/topo-framework/tests/poc_consensus_epoch_e2e.move
```

- [ ] 同步迁移 stake / governance 相关 Move 测试，不只迁移 `tests/poc*`:

```text
aptos-move/framework/topo-framework/sources/stake.move
aptos-move/framework/topo-framework/sources/delegation_pool.move
aptos-move/framework/topo-framework/sources/topo_governance.move
aptos-move/framework/topo-framework/tests/delegation_pool_integration_tests.move
```

- [ ] 迁移 Rust e2e helper 中与 stake/governance 相关的改动:

```text
aptos-move/e2e-move-tests/src/stake.rs
aptos-move/e2e-move-tests/src/topo_governance.rs
```

- [ ] `stake.rs` helper 不再假设 coin stake 直接进入 validator voting power:
  - [ ] `add_stake` 改为 `staking_registry::deposit`
  - [ ] 根据目标分支测试语义处理 `unlock_stake` / `withdraw_stake` 兼容路径
- [ ] `topo_governance.rs` 覆盖 governance proposer/voter effective power 场景。
- [ ] 测试重点覆盖:
  - [ ] genesis validator 可以获得 period 0 power 并进入 validator set。
  - [ ] staged power 只在 power period 边界后生效。
  - [ ] reward/fee 自动复投会影响下一 epoch power。
  - [ ] 低于 force exit 阈值的 delegator 会被移除。
  - [ ] validator set 不会变成空集合或全 0 voting power。
  - [ ] governance proposer/voter 权重使用 effective power。
  - [ ] `topo_governance` proposal creation、vote、early resolution threshold 和 cooldown 联动都使用 POC effective power。
  - [ ] next validator set simulator 与真实 `on_new_epoch` 对 registry power 为 0、legacy stake fallback、liveness fallback 的处理一致。
  - [ ] legacy stake/delegation pool 测试仍覆盖 POC-era reward/fee 自动复投、lockup renewal、pending_inactive 和 voting power increase limit。

完成检查:

```bash
cargo test -p topo-framework
cargo run -p aptos -- move test --package-dir aptos-move/framework/topo-framework
cargo test -p e2e-move-tests -- stake
cargo test -p e2e-move-tests -- topo_governance
```

注意: `TEST_FILTER=poc cargo test -p topo-framework move_framework_unit_tests` 只能覆盖 POC 命名测试，不能替代完整 package-dir Move 单测。`stake`、`delegation_pool`、`delegation_pool_integration_tests` 中的 legacy compatibility 测试也会暴露 POC 接线问题。

### 7.1 2026-07-02 topo_framework_v2 对齐发现的必补测试

- [x] `poc_consensus_epoch_e2e::test_liveness_fallback_preserves_positive_power_when_registry_power_zero`
  - [x] 覆盖 staged next-period registry power 为 0 时，validator set 预测不能生成 total voting power 为 0 的非空集合。
  - [x] 覆盖 simulator 应走 previous positive snapshot liveness fallback，而不是无条件用 legacy stake 补零。
- [x] `stake::test_active_validator_cannot_add_more_stake_than_limit_in_multiple_epochs`
  - [x] 覆盖 active validator 多 epoch reward 后的 legacy `StakePool.active` 余额。
  - [x] 覆盖新增 stake 仍触发 `EVOTING_POWER_INCREASE_EXCEEDS_LIMIT`。
- [x] `delegation_pool_integration_tests::test_active_validator_cannot_add_more_stake_than_limit_in_multiple_epochs`
  - [x] 覆盖 delegation pool 地址作为 registry validator address 的路径。
  - [x] 覆盖 delegation pool 初始化后 POC registry power 与 legacy stake pool 余额同步。
- [x] `delegation_pool::test_inactivate_no_excess_stake`
  - [x] 覆盖 validator rejoin renew lockup 后，不提前把 expired `pending_inactive` 额外搬到 inactive。
  - [x] 覆盖 observed lockup cycle 不因没有新增 inactive stake 而提前推进。
  - [x] 覆盖 pending withdrawal 在后续 epoch 的 reward 余额变化。

本组验证命令:

```bash
RUST_MIN_STACK=33554432 cargo run -p aptos -- move test --package-dir aptos-move/framework/topo-framework --filter test_liveness_fallback_preserves_positive_power_when_registry_power_zero
RUST_MIN_STACK=33554432 cargo run -p aptos -- move test --package-dir aptos-move/framework/topo-framework --filter test_active_validator_cannot_add_more_stake_than_limit_in_multiple_epochs
RUST_MIN_STACK=33554432 cargo run -p aptos -- move test --package-dir aptos-move/framework/topo-framework --filter test_inactivate_no_excess_stake
RUST_MIN_STACK=33554432 cargo run -p aptos -- move test --package-dir aptos-move/framework/topo-framework
```

## 8. Smoke-test 迁移

POC 迁移后，smoke-test 不能继续假设 `stake::add_stake` 的 coin 数量就是 validator set voting power。迁移时需要逐个检查 CLI、rewards、consensus recovery 类 smoke。

- [x] 迁移 validator CLI smoke:

```text
testsuite/smoke-test/src/aptos_cli/validator.rs
```

- [x] 对新 validator join flow，在 `join_validator_set` 前补齐:
  - [x] root/test-only committed POC power
  - [x] `staking_registry::register_validator`，如该 flow 未由 CLI 初始化完成
  - [x] `staking_registry::deposit`
  - [x] `staking_registry::delegate`
- [x] 对 owner/operator/delegation flow，在 owner 已初始化 stake owner 后补齐 POC power seed、registry deposit/delegate。
- [x] reward smoke 改查 POC-aware 的 validator set / voting power 路径；不要用 `stake::get_stake` 推断 POC voting power 增长。
- [x] 在 CLI test helper 中补齐 POC smoke 所需入口:
  - [x] `staking_registry::{register_validator,deposit,delegate,undelegate,withdraw_deposit}`
  - [x] `topo_governance::{stage_power_update_test_only,set_power_period_in_epochs_test_only,force_end_epoch_test_only}`
- [x] 处理当前分支的 power period countdown 差异: `set_power_period_in_epochs` 只影响后续 period，focused smoke 需要推进默认 60 epoch countdown 后再依赖 staged power。
- [x] 对关闭 randomness 的 validator smoke 保留 `OnChainChunkyDKGConfig::default_disabled()`，避免 Chunky DKG 在 epoch 1 DKG result abort 后导致 `sync_only flag is set`。
- [x] 迁移 `randomness::disable_feature_0` 的 POC-era 等待逻辑:
  - [x] governance gas options
  - [x] randomness config polling
  - [x] epoch polling
  - [x] `wait_for_new_dkg_completion`
  - [x] 保留当前分支需要的 Chunky DKG disabled 配置
- [x] 迁移 non-consensus-delete smoke harness 适配:
  - [x] `testsuite/smoke-test/src/chunky_dkg/with_validator_down.rs`
  - [x] `testsuite/smoke-test/src/genesis.rs`
  - [x] `testsuite/smoke-test/src/storage.rs`
  - [x] `testsuite/smoke-test/src/rosetta.rs`
- [ ] 单独处理 `topo_framework` 中删除的 DKG/consensus smoke:
  - [ ] `testsuite/smoke-test/src/chunky_dkg/governance_recovery.rs`
  - [ ] `testsuite/smoke-test/src/consensus/batch_v2_rollout.rs`
  - [ ] 迁移时需确认是删除、ignore，还是按 POC-era recovery window 改写；不要无确认直接删除共识/DKG 覆盖。
- [ ] 迁移 consensus traffic smoke:

```text
testsuite/smoke-test/src/consensus/consensus_fault_tolerance.rs
```

- [ ] traffic payload 使用 `topo_stdlib::topo_coin_transfer`。
- [ ] submit 超时或失败时回退本地 sequence number，并短暂 sleep 后继续，避免 failpoint 阶段污染后续交易。
- [ ] 对 POC-era full smoke 并发下恢复较慢的 failpoint 测试，保留故障注入覆盖，但给恢复窗口足够时间，避免误判无进展。
- [ ] 迁移 batch/optqs smoke:

```text
testsuite/smoke-test/src/consensus/batch_v2_rollout.rs
testsuite/smoke-test/src/consensus/optqs_fault_tolerance.rs
```

- [ ] batch rollout 等待窗口能覆盖 POC local swarm 的 epoch/recovery 延迟。
- [ ] optqs 测试在停止/重启节点前显式清理会影响追块的 failpoint，例如 `consensus::send::broadcast_self_only`。

完成检查:

```bash
git diff --check
cargo check -p smoke-test --tests
RUST_MIN_STACK=33554432 cargo test -p smoke-test aptos_cli::validator::test_large_total_stake -- --nocapture --test-threads=1
RUST_MIN_STACK=33554432 cargo test -p smoke-test aptos_cli::validator::test_join_and_leave_validator -- --nocapture --test-threads=1
RUST_MIN_STACK=33554432 cargo test -p smoke-test aptos_cli::validator::test_owner_create_and_delegate_flow -- --nocapture --test-threads=1
RUST_MIN_STACK=33554432 cargo test -p smoke-test aptos_cli::validator::test_nodes_rewards -- --nocapture --test-threads=1
RUST_MIN_STACK=33554432 cargo test -p smoke-test randomness::disable_feature_0::disable_feature_0 -- --nocapture --test-threads=1
RUST_MIN_STACK=33554432 cargo test -p smoke-test consensus::batch_v2_rollout::test_batch_v2_tx_rollout -- --nocapture --test-threads=1
RUST_MIN_STACK=33554432 cargo test -p smoke-test consensus::consensus_fault_tolerance::test_changing_working_consensus -- --nocapture --test-threads=1
RUST_MIN_STACK=33554432 cargo test -p smoke-test consensus::optqs_fault_tolerance::test_remote_batch_read_from_block_voters -- --nocapture --test-threads=1
```

2026-06-30 当前分支 focused 验证记录:

- [x] `git diff --check`
- [x] `cargo check -p smoke-test --tests`
- [x] `aptos_cli::validator::test_large_total_stake`
- [x] `aptos_cli::validator::test_join_and_leave_validator`
- [x] `aptos_cli::validator::test_owner_create_and_delegate_flow`
- [x] `aptos_cli::validator::test_nodes_rewards`
- [x] `randomness::disable_feature_0::disable_feature_0`
- [ ] `chunky_dkg::governance_recovery::chunky_dkg_stall_governance_recovery`
- [ ] `chunky_dkg::with_validator_down::chunky_dkg_with_validator_down`
- [ ] `consensus::batch_v2_rollout::test_batch_v2_tx_rollout`
- [ ] `genesis::test_validator_genesis_transaction_and_db_restore_flow`
- [ ] `storage::test_db_restore`
- [ ] `rosetta::test_invalid_transaction_gas_charged`

最终 full smoke:

```bash
env RUST_MIN_STACK=33554432 cargo test -p smoke-test -- --nocapture --test-threads=12
```

## 9. 重新生成 Cached Packages

- [ ] 重新生成 framework cached packages。

```bash
scripts/cargo_build_aptos_cached_packages.sh
```

注意: `cargo build -p aptos-cached-packages` 只会编译当前已存在的 cached package crate，不会重新生成 `head.mrb`。修改 `aptos-move/framework/**/*.move` 后必须使用上面的脚本或等价的 `cargo run --profile=ci -p topo-framework -- update-cached-packages`。

- [ ] 检查生成文件。

```bash
git status --short aptos-move/framework/cached-packages
rg -n "poc_power_store|poc_registry|staking_registry|topo_governance" \
  aptos-move/framework/cached-packages/src/topo_framework_sdk_builder.rs
```

- [ ] 不手工补 `head.mrb`，以构建生成结果为准。

## 10. 运维脚本和 Dashboard 可选迁移

如果目标分支要运行 PoC dashboard 或测试网运维脚本，迁移:

- [ ] POC registry:
  - [ ] `poc-dashboard/scripts/initialize_poc_registry.move`
  - [ ] `poc-dashboard/scripts/set_dapp_poc_status.move`
  - [ ] `poc-dashboard/scripts/set_dapp_weight.move`
- [ ] Power store:
  - [ ] `poc-dashboard/scripts/stage_power_store_batch.move`
  - [ ] `poc-dashboard/scripts/set_power_store_operator.move`
  - [ ] `poc-dashboard/scripts/set_power_store_retention.move`
- [ ] Staking:
  - [ ] `poc-dashboard/scripts/set_staking_config.move`
  - [ ] `poc-dashboard/scripts/set_staking_rewards_config.move`
  - [ ] `poc-dashboard/scripts/set_staking_reward_rate.move`
  - [ ] `poc-dashboard/scripts/set_staking_min_active_power.move`
  - [ ] `poc-dashboard/scripts/set_staking_force_exit_power_bps.move`
  - [ ] `poc-dashboard/scripts/set_staking_octas_per_million_power.move`
  - [ ] `poc-dashboard/scripts/set_staking_cooldown_secs.move`
- [ ] Chain/governance:
  - [ ] `poc-dashboard/scripts/set_epoch_interval.move`
  - [ ] `poc-dashboard/scripts/update_governance_config.move`
  - [ ] `poc-dashboard/scripts/set_chain_test_params.move`
- [ ] Cluster tools:
  - [ ] `poc-dashboard/scripts/poc_validator_membership.py`
  - [ ] `poc-dashboard/scripts/poc_prod_like_validator_cluster.py`

完成检查:

```bash
rg -n "poc_power_store|poc_registry|staking_registry|topo_governance" poc-dashboard/scripts
```

## 11. 共识和安全验证

- [ ] 确认没有修改 `consensus/safety-rules`。
- [ ] 确认没有修改签名验证、BLS/crypto 逻辑。
- [ ] 确认 Rust 共识读取链路仍然是 epoch change `ValidatorSet`。
- [ ] 检查下一 epoch on-chain config 中 validator voting power 非 0。
- [ ] 检查单节点/多节点 epoch transition 后节点能进入新 epoch。
- [ ] 如果目标分支已有共识改动，额外跑:

```bash
cargo test -p aptos-consensus
cargo test -p aptos-vm
cargo test -p aptos-block-executor
```

## 12. 最终验证

- [ ] 格式检查。

```bash
cargo +nightly fmt --check
```

- [ ] Framework 测试。

```bash
cargo test -p topo-framework
cargo run -p aptos -- move test --package-dir aptos-move/framework/topo-framework
```

- [ ] Cached packages。

```bash
scripts/cargo_build_aptos_cached_packages.sh
```

- [ ] E2E helper 相关测试。

```bash
cargo test -p e2e-move-tests -- stake
cargo test -p e2e-move-tests -- topo_governance
```

- [ ] 如目标是可运行测试网，再跑 smoke 或 dashboard flow。

```bash
env RUST_MIN_STACK=33554432 cargo test -p smoke-test -- --nocapture --test-threads=12
```

## 13. 本次迁移执行记录

本节记录当前这次 POC 迁移工作的落地状态，方便后续接手继续验证。

- [x] 新增 POC Move 模块:
  - [x] `poc_registry.move`
  - [x] `poc_contribution.move`
  - [x] `poc_power_store.move`
  - [x] `staking_registry.move`
  - [x] `staking_registry.spec.move`
- [x] 接入 `genesis.move`:
  - [x] 初始化 POC power store 和 staking registry
  - [x] 保存 TopoCoin mint cap
  - [x] genesis validator 写入 period 0 committed power
  - [x] genesis validator registry deposit/delegate
- [x] 接入 `stake.move`:
  - [x] validator join 使用 registry power
  - [x] epoch 边界提交 POC period
  - [x] reward/fee 分配并自动复投
  - [x] force undelegate 和 liveness fallback
  - [x] next validator set 模拟与真实 epoch transition 对齐
- [x] 接入 `topo_governance.move`:
  - [x] proposal/vote 权重使用 effective power
  - [x] governance config 联动 staking cooldown
  - [x] 增加本次 smoke 需要的 test-only committed power 入口
- [x] 迁移 framework tests 和 Rust e2e helper。
- [x] 迁移 smoke-test 的 POC 适配:
  - [x] validator join/delegation flow seed committed power + registry deposit/delegate
  - [x] rewards smoke 改查 staking registry deposit
  - [x] consensus traffic 改用 topo coin transfer 并处理 submit timeout/error
  - [x] batch v2 rollout 等待窗口调整
  - [x] optqs 测试停止节点前清理 `broadcast_self_only` failpoint
- [x] 重新生成 cached packages。

本次已通过的验证:

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

本次执行过程中也已确认以下 focused smoke 通过:

- `client::test_basic_restartability`
- `aptos_cli::validator::test_nodes_rewards`
- `consensus::batch_v2_rollout::test_batch_v2_tx_rollout`
- `aptos_cli::validator::test_large_total_stake`

尚待完成:

- [ ] 重新完整跑完 full smoke:

```bash
env RUST_MIN_STACK=33554432 cargo test -p smoke-test -- --nocapture --test-threads=12
```

说明: 本次曾启动 full smoke，上游任务切换前已看到多个前序 smoke 通过，但命令未跑到最终汇总，因此不能记录为 full smoke 已通过。

## 14. 迁移完成判定

- [ ] `poc_registry` 能注册/白名单 DApp。
- [ ] `poc_contribution` 能发可信 ContributionEvent。
- [ ] operator 能 stage 下一 period power。
- [ ] power period 在 epoch 边界推进。
- [ ] staking registry 能 deposit/delegate/undelegate/withdraw。
- [ ] validator join 和 epoch recompute 使用 POC effective power。
- [ ] governance proposal/vote 使用 POC effective power。
- [ ] cached packages 包含 POC entry 函数和 decoder。
- [ ] 新 epoch 的 Rust 共识 verifier 能读取非 0 voting power validator set。
