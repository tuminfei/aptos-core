# PoC v2 实现与主审记录

> 历史记录（2026-09-11，已被文末 2026-09-13 费用分流修订取代）：当时工作区按固定 PoC 计奖基数计算一次通胀，再按治理占比分入原生质押和 PoC 金库；新准备及创世默认 `native_reward_bps = 3000`，交易费全部进入 PoC。原生部分恢复份额、佣金和复投，PoC 部分保持零佣金。比例使用独立资源及 Epoch 快照，旧资源缺失时保留 `0`，治理配置在未来 Epoch 生效并受冻结保护。委托池入池费及原生余额容量同步调整。下文 2026-09-09 的“收益不复投原生本金”等行为及测试数量、bundle 摘要均为历史证据，不代表这次变更的验收结果；当前结果须以本次实际执行日志为准。

> 2026-09-10 开发范围调整：旧版算力迁移和历史 bundle 升级测试已移除，PoC 使用空算力存储准备或全新创世。创世和上传直接计算标准化版本；无算力用户只读快照返回零。下文兼容性、迁移及其验证数据为此前实现的历史记录，不适用于本次调整后的版本，也不再作为当前交付要求。

> 2026-09-10 单位补充：算力展示采用 `OHMP`（One Hundred Million Power，亿算力），`1 OHMP = 100,000,000 power`，与 TOPO 的 8 位小数展示精度对应。下文原始算力与 PoC 权重仍按整数 `power` 记录，保证金和奖励金额仍按代币最小单位记录；例如 `17 power = 0.00000017 OHMP`。标准化 `units` 不直接标为 OHMP。本次仅同步文档单位，不改写历史测试输入、结果或 bundle 摘要，也不表示 OHMP 展示工具已实现或通过测试。定义见[设计稿](POC_CONSENSUS_V2_MINIMAL_POWER_REWARD_DESIGN.md#算力与代币单位)。

本次实现依据 `POC_CONSENSUS_V2_MINIMAL_POWER_REWARD_IMPLEMENTATION.md`。起始源码提交为
`2f669734d2450d67396a6f23d160138a101148a6`。修改保留在工作区，未提交、发布或启用生产链。
本文记录实际验证，不能把实现代码、单测通过和生产发布验收视为同一件事。

## 实现与主审

子任务按账本、算力与迁移、质押与奖励并行实现，主 agent 负责依赖方向、重配置驱动、冻结配置、
跨模块审查及统一验证。保留原始存储布局、Rust ValidatorSet/EpochState 和网络消息布局；
没有修改 Rust 共识、安全规则或密码验证算法。

- `poc_accounting` 是分配、持仓、聚合、检查点、金库和部署参数的唯一账本；分配替换与上传共用两时点重建。
- `poc_power_store` 保留原始双槽，新增兼容旁路、固定基线及指数；原始槽覆盖前完成迁移和持仓同步。
- `stake` 保存已安装奖励上下文、计划及 PVS，负责保证金与增长预算、旧期结奖、退出恢复和目标安装。
- 同步区块、普通 DKG、Chunky DKG、超时和治理结束共用受管理提交管线；业务失败不冻结、不结奖、不推进时钟。
- 标准库用不可复制、不可丢弃的令牌冻结功能配置；框架配置设置与合法提交、DKG 结果写入分开。
- 提供原生链准备与首次切换，以及显式 PoC 创世入口；默认原生创世不自动启用 PoC。

主审发现并已修正的关键问题：

1. 自主退出的假设预览必须复现实际 `swap_remove` 顺序，不能只过滤原向量。
2. 当前共识权重读取已安装集合；PoC 治理在动态、静态委员会两种模式均保留原生代币口径。
3. 最后原生期按旧上下文分别取整结奖；PoC 金库不增加原生质押份额，入池费只随新上下文安装改变。
4. 准备及预检同时验证原生、周期性两份奖励率，防止待生效功能开关选择未校验的配置。
5. 续锁时长按 `u64::MAX - floor(u64::MAX / 1_000_000)` 校验，覆盖任意可表示的 DKG 完成时间。
6. 原生设置入口先验证权限和基本参数，再读取资源做 PoC 联合校验，保留原有错误语义。
7. 冻结期间领取只推进已安装 Epoch；缺检查点、孤立缓存或目标不匹配明确失败，不实时修补计划。
8. 费用累计使用有上限的 aggregator；正常路径使用 `try_add`，仅触顶时读取余量，避免旧期持续延期导致累加溢出。
9. 未准备 PoC 的原生链同样在每次成功换届推进已初始化的算力时钟；准备分支单独接入，避免重复推进。

## 一项兼容性选择

旧 `gas_schedule::set_storage_gas_config` 直接调用的原生换届入口不能完整安装缓冲配置，模块依赖也不允许
直接反向调用 DKG 驱动。本次采用最小改动：准备前保持原行为；准备后该旧入口报
`gas_schedule::EPOC_REQUIRES_GOVERNANCE_TRANSITION`（`0x30004`），在同一治理事务中使用：

```move
gas_schedule::set_storage_gas_config_for_next_epoch(framework, config);
topo_governance::reconfigure(framework);
```

需要同步强制结束时，第二步使用既有 `topo_governance::force_end_epoch`。
失败会回滚本事务的配置写入；冻结后只能消费既有计划。该选择不删除或更改原函数签名。

## 基线与兼容性证据

原始源码不能直接编译：`poc_power_store` 声明的 friend `staking_registry` 不存在。
在临时基线副本仅移除该声明后，原始框架编译成功。

历史 `head.mrb` 有 191 个模块，尚未包含源码中的 PoC 原始模块。因此分开执行两种检查：

- 历史完整 bundle 对新 bundle：191 个既有模块全部通过 public/friend/entry 链接和结构布局兼容检查；新增 5 个模块。
- 从上述基线源码实际编译的 `poc_power_store.mv` 对新 bundle：旧模块的公开接口及全部结构布局兼容。

可复现工具：

```bash
cargo run -p topo-framework --example poc_check_compatibility -- OLD.mrb NEW.mrb
cargo run -p topo-framework --example poc_check_compatibility -- OLD_poc_power_store.mv NEW.mrb
```

真实历史 bundle 的升级测试通过 `POC_LEGACY_BUNDLE` 显式指定发布材料，默认标记 ignored。
本次已单独执行通过：真实 VM 发布 7 个包、196 个模块，4 个原生资源发布前后字节保持一致，
恢复原 gas 配置后首次 PoC 安装在 Epoch 7；后续收益不复投原生本金，治理失败完整回滚。
历史缓存不含算力模块，故其实际升级覆盖原生资产到 PoC；
双版本旧算力的固定基线、晚访问和覆写行为另由 Move 迁移测试及真实旧模块兼容检查验证。

完整包发布超出历史普通交易限额。演练先通过旧框架公开 setter 和真实换届事务，将
`txn.max_transaction_size_in_bytes` 从 65,536 临时设为 4,194,304，
`txn.max_execution_gas` 从 9,200,000,000 临时设为旧配置已有的治理上限 40,000,000,000。
没有直接改 VM 存储，也没有提高 IO 或 storage 限额。发布后用同一公开流程恢复完整原配置。
TopoFramework 的实际签名交易为 958,892 字节；上线必须批准对应发布窗口或使用正式已批准治理脚本的发布流程。

## 验证命令与范围

编译 Move 与测试使用现有优化 `ci` profile，保持原有断言与执行比较。
升级测试另通过真实治理事务开启有界发布窗口，随后恢复原 gas 配置；普通业务测试不提高 gas 上限。
调试版 full-model 编译的中止运行不计作通过。E2E 精确使用模块名筛选，避免 `poc_` 同时命中既有安全漏洞复现。

```bash
scripts/cargo_build_aptos_cached_packages.sh
cargo build -p aptos-cached-packages
REPORT_STATS=1 cargo test --profile ci -p topo-framework -- --skip prover --nocapture
E2E_PARALLEL_EXEC=1 cargo test --profile ci -p e2e-move-tests tests::poc_consensus:: -- --nocapture --test-threads=1
POC_LEGACY_BUNDLE=OLD.mrb cargo test --profile ci -p e2e-move-tests poc_upgrade_from_legacy_bundle -- --ignored --nocapture
cargo test --profile ci -p e2e-move-tests stake
cargo test -p aptos-vm-genesis
cargo test -p aptos-types dkg
cargo build -p aptos-node --features failpoints,smoke-test
SMOKE_TEST_BIN_DIR=target/debug cargo test -p smoke-test poc:: -- --test-threads=1 --nocapture
cargo xclippy
cargo +nightly fmt --check
./scripts/rust_lint.sh --check

# 使用仓库指定的 Boogie 3.5.6、Z3 4.13.0，并设置对应工具路径。
MVP_PROC_CORES=3 MVP_TEST_VC_TIMEOUT=120 MVP_TEST_DISALLOW_TIMEOUT_OVERWRITE=1 \
  cargo test --profile ci -p topo-framework --test move_prover_tests -- --nocapture
```

2026-09-09 功能实现验收的执行记录如下，所有数量均来自实际测试输出：

| 检查 | 实际结果 |
| --- | --- |
| 框架 Move 单测 | 870 / 870（含容量、完整奖励期限、损坏状态、计数器边界与原生时钟回归） |
| Move 标准库 | 207 / 207 |
| Topo 标准库 / token objects / token / trading | 297 / 86 / 43 / 136，全部通过；experimental 为 0，不计验收 |
| PoC 生产字节码 E2E | 11 / 11，59.20 秒；使用 `--include-ignored` 和真实旧 bundle，包含 V1 block metadata 超时提交、升级、B 独立容量回滚、8 池替换及五路径同快照差分 |
| 原生 Rust stake 筛选 | 13 / 13；修复原 fixture 仍引用 `aptos_std` 的既有重命名遗漏 |
| Rust 创世包 | `aptos-vm-genesis` 4 / 4，其中新增 PoC 2 项；`aptos-genesis` 无单测 |
| Rust DKG 筛选 | 13 / 13 |
| 节点 smoke | 四节点同步重启、普通 DKG、Chunky DKG、冻结重启后强制结束均通过；五节点退出/回加/替补独立复跑 1 / 1，113.67 秒 |
| Rust check | topo-framework、e2e-move-tests、aptos-vm-genesis；aptos-genesis、aptos、smoke-test（含 tests）通过 |
| lint | 全 workspace `cargo xclippy`、nightly fmt、cargo machete 通过 |

最终 bundle 的 smoke 整组首跑为 4 通过、1 失败：新增替补测试错误要求离任节点持续追赶新区块。
按仓库既有成员测试增加全节点通道并改为核对当期委员会后，该项独立复跑通过；合计五种场景通过，
不是把最初整组结果记为全绿。每次换届都验证实际 DKG transcript、目标顺序、公钥、权重及同版本资源，
最终回加节点必须追赶并参加四人委员会的核对；最后离任节点的持续同步不在该断言范围。

全量 `rust_lint.sh --check` 在 `cargo sort --grouped --workspace --check` 停止：
41 个既有 Cargo.toml 存在排序问题。本次未修改 Cargo.toml 或 Cargo.lock，没有自动重排无关依赖。
该脚本末尾还有已跟踪文件工作区差异检查，未提交的实现不满足这一提交后检查条件。

独立参考模型使用三个随机种子、两个用户、两个池和 16 个 Epoch。模型保留完整历史，逐期计算权益，
不复刻链上的 PoolChange/checkpoint/cursor 算法；每一步比较 units、整数与分数权益、已付金额和金库守恒。
该随机模型覆盖账本操作；成员、参数和 DKG 交错另由定向测试覆盖，尚非包含全部操作的随机状态机验收。
上层冻结测试实际经过 StakingContract、Vesting 和 DelegationPool 的能力转调，并要求确切冻结错误码。

生产 bundle 与 SDK 已用实际生成脚本更新，并重新构建 `aptos-cached-packages`。
以下为 2026-09-09 功能验收时的产物 SHA-256；中文注释更新后的产物见本文末节：

| 产物 | SHA-256 |
| --- | --- |
| `cached-packages/src/head.mrb` | `47fd1a7c693c0bcbb6c079f143d134a1ea098a2ce9a9f56af7eea152d64ef376` |
| `cached-packages/src/topo_framework_sdk_builder.rs` | `cecd5ecfcdcc0740adec907b77c220103dc51790b66ae65bba4cd7614753b0f8` |

最终 smoke 使用 `failpoints,smoke-test` 编译的 `target/debug/aptos-node`，SHA-256 为
`84654178f860134e1b528b9d0c396ad259453fcf4b6a27029a938330b0535c58`。

提交后的缓存新鲜度检查 `scripts/cargo_build_aptos_cached_packages.sh --check` 尚未执行。
该脚本检查 `aptos-move` 下所有 tracked 差异，当前合法的未提交源码会使其失败；发布前应在对应的干净提交上执行。

## 与 19 项验收的对应

下列是已执行自动化测试的代表入口，`poc_` 名称可在框架测试与 `stake.move` 中直接检索。
它们证明表述的场景，不表示原规格每一编号下的所有动作均已完成生产验收。
同快照差分已对一个不可变基线构造五份独立 overlay，比较同步、普通 DKG、Chunky DKG、超时和强制完成。
目标权重为 `[13333, 11666, 10000, 15000]`，总和 49999；目标顺序、PVS、units、基数、完整新上下文、
每池金库/指数和四条正通胀结奖事件一致，重复完成不再写入。普通/Chunky 完成以可信内部回调适配器
注入结果标记，仅验证生产 Move 驱动；真实 transcript 密码验证另由节点测试覆盖。
生产规模、完整运维演练仍按后文门槛签收。

| 编号 | 主要证据 |
| --- | --- |
| 1 | `poc_upload_and_allocation_commute`、`poc_upload_allocation_order_independence` |
| 2 | `poc_two_boundary_rebuild`、`poc_coincident_boundary_omits_unchanged_units`、首写及显式零版本测试 |
| 3 | 退出池惰性领奖、两个成熟变更、原始槽覆写前迁移测试 |
| 4 | `poc_net_zero_change_retains_reward_checkpoint`，缺失检查点/零引用精确失败测试 |
| 5 | `poc_binding_bond_cap_preserves_user_reward_ratio`：算力 40 被保证金限为 10，两个用户仍按 10:30 分奖；另有增长限幅与独立逐期参考模型 |
| 6 | `poc_same_snapshot_transition_targets_and_reward_bases` 五路径差分；普通/Chunky 真实节点核对；V1 block metadata 超时按缓存目标只提交一次 |
| 7 | 16 次连续 Deferred 后修复，旧统计/费用不丢失且只结算一次 |
| 8 | 原生准备到首次 PoC、金库不复投本金、旧 bundle 真实升级 |
| 9 | 最大标准化数值、长期延期宽整数奖励、两类提案计数器溢出精确拒绝 |
| 10 | 20% 不足替换拒绝、25% 单替补成功；`poc_dynamic_minimum_equal_to_validator_limit_rejected` 独立验证动态人数等于容量时拒绝 |
| 11 | 多候选竞争拒绝退出、自主取消保留索引、治理移除撤销取消权限 |
| 12 | 覆盖比例、`poc_cancel_params_and_reschedule_keep_baseline`、E2E 集中度迁移再撤回恢复 |
| 13 | 标准库直接设置/安装、配置缓冲、能力转调冻结；冻结中领奖及坏缓存拒绝 |
| 14 | 已安装奖励率/费配置、周期奖励 feature 切换、原生委托入池费 |
| 15 | 标准化两次向下取整使原始 100 得池权重 99 |
| 16 | 最终影子容量、合法替换、两个 `2^63` 实际总和拒绝；`poc_boundary_only_capacity_failure_rolls_back_batch` 验证仅 B 越界时整批原始版本/聚合回滚；`poc_disjoint_four_pool_replacement_visits_eight` 实测 2K 访问 |
| 17 | P_MAX、H、周期长度上界与固定基线；两项 `poc_full_reward_horizon_*` 验证 H 期不领、累计入账恰达 u64::MAX、最大池和大指数的权益守恒；H×R_MAX 多 1 精确拒绝 |
| 18 | 开放集中度拒绝与受控模式，顺序/并行输出一致并可撤回修复 |
| 19 | 191 模块兼容、旧算力模块真实二进制兼容、晚访问/幂等迁移、两种创世 |

## 成本记录的含义

`REPORT_STATS` 是 Move harness 的完整测试场景统计，含准备和辅助操作；不能作为单次区块 prologue 的生产 gas。
`POC_COST` 记录生产字节码 E2E 的交易大小、gas、写集与事件体积、VM 执行耗时。
启用顺序/并行比较时，耗时包括两种执行及测试框架开销，不能换算为节点 TPS。

已测 `V_LIMIT=8`、8 名当期成员、15 池并集、16 次连续 Deferred、参数修复和成功安装的完整场景：
两轮分别为 0.053 秒和 0.395 秒，harness Gas Used 均为 8154；后一轮并行运行其他验证任务，
耗时包含测试机资源争用。退出池新基数为零，旧统计与费用持续累计且只结算一次。
四用户同块修改热门池的测试比较顺序和 Block-STM 的完整输出，并验证集中度延期后能通过撤回分配修复。

生产 bundle 的 E2E 样本，环境为 macOS arm64、18 个逻辑 CPU、64 GiB 内存：

| 操作 | gas used | 交易 BCS 字节 | 写条目 / 写字节 | 事件数 / 字节 |
| --- | ---: | ---: | ---: | ---: |
| 32 用户、每人 4 池，上传下一版本 | 4030 | 1529 | 233 / 44345 | 65 / 8266 |
| 替换同 4 池比例 | 230 | 395 | 10 / 2757 | 2 / 380 |
| 同 Epoch 将待生效 4 池替换为另 4 池（8 验证者） | 303 | 395 | 18 / 3761 | 2 / 380 |
| 领取 4 池已入账奖励 | 257 | 359 | 16 / 3709 | 6 / 765 |
| 冻结中领取单池 | 151 | 262 | 7 / 1981 | 3 / 345 |
| 4 验证者换届（样本） | 604 | 231 | 31 / 7817 | 9 / 883 |

上传 33 用户被 `EUPLOAD_LIMIT` 原子拒绝，相关账本与版本字节保持不变。
8 池替换的唯一读取为 152 个 key：key 共 12,331 字节，非空 value 共 496,901 字节，包含模块和配置读取。
测试包装实际 StateView 记录读取，并核对读写 table key 的池地址集合都覆盖 8 池。
这里 active 配置为空，覆盖先前排定的 4 池 pending 配置；每份有效配置并集仍不超过 4，
撤销旧链和安装新链合计访问 8 池。它不允许 active 4 池与另 4 池 pending 同时绕过配置并集上限。

仅 B 超容量的生产 VM 测试使用显式 `retention_bps=3`、`P_MAX=2`、周期长度 4。
两个最大原始版本在 B 汇聚越界，当前及 E+1 仍合法；失败 gas 为 244，仅产生标准 epilogue 写入/费用事件。
完整相关资源和表项字节不变，降低第二项版本后两项都成功首写，证明批次第一项的合法变更也被回滚。
这些规模来自显式测试清单，不把 8 验证者或 32 用户认定为已批准的生产上限。
尚无目标生产环境的 TPS、重执行次数和区块预算签收，不能用上述 VM 比较耗时推算。

## 发布材料及尚未完成的门槛

[创世测试清单与调用说明](POC_GENESIS_IMPLEMENTATION_CHECKS.md) 和
[显式 JSON 测试参数](POC_GENESIS_TEST_MANIFEST.json) 是可执行测试示例，不是批准的生产部署参数。
生产需要确定实际限额、期限预警负责人和升级窗口，并在目标硬件/区块预算下完成容量签收。

最初包级 Prover 在缺少工具时失败，随后已在临时目录安装仓库指定 .NET 8、Boogie 3.5.6 和 Z3 4.13.0。
Move 标准库、Topo 标准库及 Token 三个 Prover harness 均已通过。框架已通过的定向范围包括：

| 范围 | 实际验证目标 |
| --- | --- |
| PoC 账本 / 算力存储 / 用户入口 | 61 / 55 / 8 |
| stake | 105；随后对缓存成对契约、下一届查询和严格计数器溢出契约另行补验 |
| 同步重配置 / DKG 重配置 | 17 / 26 |
| genesis | 11；随后对原生创建、包装和初始化验证入口按全模型补验 |
| 区块公共 prologue | 全模型验证精确的计数器溢出条件；不再假设 Epoch 最多一天 |

全框架 120 秒预算的扩展验证发现了跨模块契约遗漏，已修正缓存计划/PVS 的等价与存在性摘要、
统计计数器的完整溢出条件、原生创世循环不变量以及 JWKS 冻结入口规格，并逐项实际验证函数体。
原生创世的一处 `for_each_ref` 等价改为按原顺序的索引循环，便于声明必要的存在性不变量。

以下全模型失败已经使用同一工具及原始 `2f669734d2` 源码逐根复现，未因本次实现而修改无关逻辑：

- `account::rotate_authentication_key_with_rotation_capability`：旧规格未涵盖 `is_orderless_txn_internal` 的 abort。
- `staking_contract` 三个创建入口：9 项旧账户、CoinStore/FA 与最低质押额规格失败。
- `transaction_validation::fee_payer_script_prologue_extended`：同一 120 秒 VC 预算下求解超时。

最终整包复跑耗时 919.38 秒，仍失败：报告上述旧模块的 5 项反例，以及 `create_staking_contract`
和 `fee_payer_script_prologue_extended` 两个入口的 120 秒超时；未再报告本次 PoC 接入相关反例。
`create_staking_contract` 在原始基线的独立验证曾报告 5 项旧反例，本轮整包超时未将其完整列出，
诊断数量减少不表示这些旧问题已修复。

这些结果不代表全框架 Prover 全部通过。已有 `verify = false`、验证时长跳过、原生函数模型及部分 abort
契约仍是证明边界；定向目标通过也不等于所有合法链状态下的无 abort 证明。
没有删除旧规格文件或新增假设来掩盖本次反例。

旧数据若超过 10000 次整数衰减重放且仍非零，以 `EMIGRATION_REQUIRED` 拒绝；
此时需要该链可验证的基线迁移材料及审查后的升级方案，不提供猜测基线或重置权益的入口。

## Deferred 修复

未冻结时可以按失败原因执行有界修复：撤回或覆盖分配；取消多余待加入申请；
取消本 Epoch 的自主退出；追加或重新激活保证金；替换或撤销待生效 PoC 参数。
下一块重新使用相同预检公式。治理移除不会被运营者的取消自主退出覆盖。

已冻结时只能领取历史奖励，或由既有授权入口完成、超时或强制结束原计划。
不能改截止时间、重选委员会、重置基线、重置首次 PoC Epoch 或临时退回原生计奖。

## 2026-09-10 中文注释整理

为本次新增函数和关键改动补充中文说明，并统一润色，覆盖生效时点、计量单位、权限、冻结计划、
旧 Epoch 奖励结算、检查点引用、固定基线迁移及测试适配器的覆盖范围。注释明确区分链 Epoch 与
算力周期，以具体动作替代生硬缩写，并保留必要的边界条件。本次新增的英文说明已改为中文；
版权许可、代码标识、公式和可复现命令保留原文。SDK 注释由 Move 接口文档重新生成，未手改生成结果。

49 个手写源文件及生成 SDK 的词法核对通过：与本轮开始快照相比，代码、测试断言、规格语句及
非源码字符串均未改变；Rust 内嵌 Move 脚本另按 Move 语法剔除注释后比较。暂存区保持不变，没有文件删除。

实际重跑缓存生成脚本及 `cargo build -p aptos-cached-packages`。196 个模块的可执行表、结构布局、
错误码/名称与运行时属性均与注释整理前的产物相同；模块字节差异仅有 `poc_power_store` 的 13 条错误说明和
`staking_config` 的 1 条错误说明中文化。包内源码摘要、ABI 文档及生成 SDK 随注释同步更新。

本轮注释整理期间已通过框架 1,639 项 Move 单测、PoC E2E 11 项（包含历史 bundle 升级，
0 项 ignored）及创世测试 4 项；受影响 Rust 包的 `cargo check --all-targets`、workspace
`cargo xclippy` 和 `cargo +nightly fmt --check` 也已通过。二次润色后重新生成产物，复查源码词法、
模块执行逻辑与布局，并再次通过 Move 单测、编译和 lint 检查。

最终框架回归使用 `cargo test --profile ci -p topo-framework -- --skip prover`：Move 单测 1,639 项全部通过，
耗时 13.24 秒；文档测试 1 项通过。此前未优化版本因耗时主动停止，未将其计为通过。
未因纯注释变化重复节点或 Prover 全量演练，前述历史结果及证明边界仍按各自记录解释。

本轮生成产物 SHA-256：

| 产物 | SHA-256 |
| --- | --- |
| `cached-packages/src/head.mrb` | `ad353c4f1429cbf87db219f933bb975ee44dd308db3b89263c3c3a9bbab1aab0` |
| `cached-packages/src/topo_framework_sdk_builder.rs` | `824b2f7deab5c67d501c04ea9eec0aed9919b19eddd9822769de1c73b6c39f90` |

## 2026-09-10 PoC 代码与逻辑精简

三路并行实施后交叉复核，按当前未发布 PoC 实现收敛以下重复逻辑：

- 委员会与回退标记只保存在 `PrecomputedValidatorSet`；`EpochPlanData` 保存其余冻结数据，
  公开 `EpochPreview` 由二者组装。重复准备只校验缓存，DKG 与安装始终使用同一份委员会。
  `install_epoch_plan` 显式接收链目标 Epoch，并校验计划、链时钟和账本时钟一致；0/1/2 提交阶段保持。
- 算力上传由外层逐项执行一次首写判断，再依次迁移、同步和写入；私有写入函数删除重复去重与布尔返回值。
  同批重复用户仍观察前一次实际写入的原始槽，零值和双版本迁移规则保持。
- 查询与结算共用 `accrued_at` 乘加计算；分别保留只读虚拟检查点和消费引用的遍历。
  查询已落盘检查点时补齐零引用拒绝，分段累计不提前取整。
- 删除未使用的 `normalize_power`、`advance_pool_to_current` 和仅转发的奖励计算适配器；
  归一化与奖励测试直接执行生产函数，`pool_change_fields` 仅保留于测试编译。
  DKG 完成函数收为私有，删除重复预校验，原生手续费读取复用既有 helper。
- 22 处 Rust PoC 测试交易构造改用生成 SDK，保留签名账户、参数与断言；两个 E2E 文件合计减少 78 行。

新增 6 项 Move 回归覆盖归一化上下界、已落盘/虚拟检查点混合时的查询与领取一致性、零引用拒绝、
错误目标 Epoch 拒绝、原生回退预览；冻结期间重复准备与最终安装的完整委员会一致性断言同时加强。
未删除迁移、历史奖励模型或差分测试，未通过新增假设、关闭验证或削弱规格来完成精简。

### 兼容范围

最终 bundle 对历史 `2f669734d2` bundle 的 191 个既有模块全部兼容，新增 5 个模块；
真实历史 `poc_power_store.mv` 的单模块兼容检查也通过。
`EpochPreview`、`PrecomputedValidatorSet`、`StakePool`、`ValidatorSet` 及相关嵌套布局未变，
生成 SDK 与本轮开始快照逐字节一致。

本轮开始时的未发布 PoC bundle 与本轮产物不兼容，检查实际报告三个模块：
`stake` 的新 `EpochPlan` 布局及内部安装函数签名，`poc_accounting` 的辅助接口删除/测试化，
`reconfiguration_with_dkg::try_finish` 的可见性收缩。历史基线兼容结论不适用于已发布的前一 PoC bundle。

### 本轮验证

已重新生成 cached packages 并执行 `cargo build -p aptos-cached-packages`。
首次编译发现生产入口及测试包装入口各一处多余的 `PrecomputedValidatorSet` acquires，移除后再次生成缓存。
最终框架 Move 单测 1,645 / 1,645 通过（七个 harness，13.31 秒），另有 CLI 测试 1 项及包元数据集成测试 1 项通过。
`aptos-cached-packages`、`e2e-move-tests`、`aptos-vm-genesis`、`smoke-test` 的 `cargo check --all-targets` 通过。
全 workspace `cargo xclippy` 及 `cargo +nightly fmt --check` 通过。
`cargo test -p aptos-vm-genesis` 的 4 项测试全部通过（2.71 秒），包含生产 bundle 的执行和重载。
PoC E2E 11 / 11 通过（48.92 秒，0 项 ignored）：显式传入同一历史 bundle，
启用 `E2E_PARALLEL_EXEC=1`，覆盖真实历史升级、顺序/Block-STM 对照和五条换届路径差分。
原生质押 E2E 13 / 13 通过（5.17 秒）。
重新构建带 `failpoints,smoke-test` 的节点后，PoC 节点 smoke 整组 5 / 5 通过（310.16 秒），
覆盖普通/Chunky DKG、五节点成员替换、冻结重启后强制结束以及创世重启。
首次启动因 `SMOKE_TEST_BIN_DIR` 相对路径在测试包目录下失效而未执行节点场景，
改用仓库 `target/debug` 的绝对路径后重跑整组通过，测试和超时设置未修改。

使用仓库既定 Boogie/Z3 环境，运行六组 `aptos move prove --filter ... --for-test`，
每组使用 2 个求解进程及 120 秒单目标预算，结果如下。计数包含各过滤范围的依赖闭包和函数分支，
不同组存在重复目标，不能相加视为互不重复的函数数量。

| 过滤范围 | 通过求解任务数 | 总时长 |
| --- | ---: | ---: |
| `poc_accounting` | 59 / 59 | 48.99 秒 |
| `poc_power_store` | 55 / 55 | 42.19 秒 |
| `stake` | 108 / 108 | 215.33 秒 |
| `reconfiguration`（三个换届模块及依赖） | 51 / 51 | 116.86 秒 |
| `genesis` | 13 / 13 | 46.45 秒 |
| `block` | 10 / 10 | 15.81 秒 |

本轮没有重跑全框架 Prover；此前记录的基线失败及已有模型/修改集摘要边界仍适用。

本轮最终 `head.mrb` SHA-256 为
`7224cc18f27a3d535735cd9ccadd44bf83270eb342a6992d9a5f6ddd52d2804d`；
SDK SHA-256 仍为 `824b2f7deab5c67d501c04ea9eec0aed9919b19eddd9822769de1c73b6c39f90`。

## 2026-09-10 创世默认方案 A

按用户选择，直接 PoC 创世统一使用算力周期 60 Epoch、上传者 `0x1`、每池每 Epoch 费用分发限额 0。
周期由现有 `initialize_power_store` 初始化，再读取实际值传给准备流程，不新增一份默认常量。
Rust 创世清单、BCS 编码及 Move 创世入口各删除三个对应参数；创世入口保留 13 项参数。
JSON 清单及烟测构造同步简化，四项权重参数、固定部署上限、衰减与初始用户分配仍显式提供。
已有链的 `prepare_poc` 继续使用完整部署参数。

零费用分发限额不影响 gas 收费或通胀奖励。三个参数均可通过原有治理入口修改：上传者立即变更，
周期设置不移动当前边界，费用新限额由后续安装的 Epoch 上下文采用。
新增创世后治理回归同时检查零上限下不累计费用、旧期费用不追补、正通胀继续发放，以及新期按新限额分发费用。
Rust 实际 bundle 重载与节点同版本资源检查增加默认值断言，原有回归断言和超时保持。

本次重新生成 cached packages 并执行 `cargo build -p aptos-cached-packages`。
最终缓存对应的框架 Move 单测 1,646 / 1,646 通过（七个 harness，13.04 秒），
CLI 与包元数据集成测试各 1 项通过；Rust 创世 4 / 4 通过（1.61 秒）。
`cargo check -p aptos-vm-genesis -p aptos-genesis -p smoke-test --all-targets`、
全 workspace `cargo xclippy` 和 `cargo +nightly fmt --check` 通过。
与历史原生 bundle 比较，191 个旧模块兼容、新增 5 个；与方案 A 修改前的 PoC bundle 比较，
196 个模块全部兼容，公共、friend、entry 链接及资源布局均无不兼容项。

首次节点 smoke 为 4 / 5 通过，冻结恢复场景暴露已有启动时序竞态：节点在测试经 REST 注入暂停前
已生成并广播 DKG transcript，随后完成正常换届，测试因此读到空会话。
现将该场景的暂停配置前移至 `NodeConfig.failpoints`，在节点启动 DKG 前生效；
冻结期间重启的单节点经 REST 恢复处理，其余三节点继续暂停。全部断言、超时、拓扑及生产逻辑保持。
最终缓存对应的节点整组复验仍为 4 / 5 通过：冻结场景在启动阶段被配置校验拒绝，
因为测试程序也需要启用现有 `aptos-config/failpoints` 特性，单独给节点启用并不足够。
复现命令已同步该特性，无需新增依赖或跳过配置校验。
启用 `aptos-config/failpoints` 后，冻结恢复单项复验 1 / 1 通过（17.31 秒）。
因此最终缓存的五个节点场景均有成功证据：普通/Chunky DKG、成员替换、创世重启来自整组运行，
冻结恢复来自上述单项复验；不能记为一次整组 5 / 5 通过。

genesis Prover 本次完整验证为 12 / 13 通过。唯一未完成项为 `create_initialize_poc_validators`：
保留既有契约并新增三项默认值后置条件后，在 120 秒单目标预算下超时（含备用 seed 的目标耗时
207.340 秒，总耗时 221.97 秒），没有给出反例。补充原始算力初始化循环的字段保持不变式后仍超时。
最后一次单入口 `--split-vcs` 诊断产生 82 条断言，运行约 4 分 35 秒后主动中止，未计作通过。
本次没有删除后置条件、添加假设或关闭验证；不能沿用上一节的 13 / 13 结果作为当前入口的完整证明。

本次最终 `head.mrb` SHA-256 为
`6a1bd422dddf7c91fd78102f2f2da055f5c083ceb3827b340807dccb2229540b`；
SDK SHA-256 仍为 `824b2f7deab5c67d501c04ea9eec0aed9919b19eddd9822769de1c73b6c39f90`。

## 2026-09-10 冻结检查去重

按用户确认的范围清理 `reconfiguration_state::assert_not_in_progress()` 调用，直接检查由 47 处减少为 16 处：
删除 19 个最终无条件进入 `config_buffer::upsert` 的上层检查、2 个存储 gas 包装层检查，
以及 10 个已有 `assert_genesis()` 的创世专用入口检查。移除 5 个无用导入，并同步删除创世规格中
6 条独立冻结条件；缓冲和存储 gas 包装入口的冻结规格仍由下层检查成立。

底层 buffer、存储 gas、直接写入的 staking/JWKS 参数、运行期初始化和公开配置安装入口仍有冻结保护。
DKG 结果专用写入路径保留；全局冻结策略不变，未启用 PoC 的原生 DKG 期间也继续限制这些配置写入。
本次不改变权限或密码验证算法。多个条件同时非法时，参数、权限、创世状态或 PoC 同步配置限制
可能先于冻结条件报错，不能声称错误优先级完全相同。

既有冻结 E2E 增加 randomness 缓冲写入、运行链调用创世专用 consensus setter、JWKS 提取缓冲后
删除不存在 provider 的拒绝路径，并将 `PendingConfigs`、`ConsensusConfig`、`SupportedOIDCProviders`
纳入业务状态快照。冻结前先写入真实 pending provider，确保 JWKS 回归确实覆盖 extract 后由 upsert
拒绝的整事务回滚。业务资源和表项必须保持，失败交易的费用与账户序号仍按 VM 规则更新。

本轮重新生成 cached packages 并执行 `cargo build -p aptos-cached-packages`。
框架 Move 单测 1,646 / 1,646 通过（12.14 秒），CLI 与包元数据集成测试各 1 项通过。
生产 bundle 的 Rust 创世执行与重载测试 4 / 4 通过（1.69 秒）。
PoC E2E 11 / 11 通过（47.38 秒，0 项 ignored），覆盖新增冻结/创世拒绝及业务状态回滚断言、
历史 bundle 升级、顺序/Block-STM 对照和五条换届路径差分。使用 `E2E_PARALLEL_EXEC=1`、
显式历史 `POC_LEGACY_BUNDLE` 和以下模块筛选运行：

```bash
cargo test --profile ci -p e2e-move-tests tests::poc_ -- --include-ignored --test-threads=1
```

此前宽泛 `poc_` 筛选包含无关同名测试，随后模块筛选的 debug 运行又因现场编译较慢主动中止，
两次均未计作通过。最终使用仓库既有 `ci` 配置，仍启用断言与溢出检查。
`cargo check -p e2e-move-tests -p aptos-cached-packages --all-targets`、全 workspace `cargo xclippy`
及格式检查通过。公共、friend、entry 链接和资源布局兼容检查通过：本轮开始的 196 个模块全部兼容，
历史原生 bundle 的 191 个旧模块全部兼容，新增 5 个模块。

使用既定 Boogie/Z3、每组 2 个求解进程和 120 秒单目标预算，本轮 Prover 结果如下。
计数表示各过滤范围实际运行的求解任务，依赖闭包可能重叠；不能把未运行的函数也计作已证明。

| 过滤范围 | 结果 | 总时长 |
| --- | --- | --- |
| `/configs/` | 99 / 99 通过 | 127.07 秒 |
| `jwks` | 29 / 29 通过 | 30.03 秒 |
| `keyless_account` | 既有 `on_new_epoch` 规格 1 / 1 通过 | 9.98 秒 |

keyless setter 原本未提供独立证明规格，不能将该模块的一项结果解释为所有 setter 都已完成证明。
本轮未重跑全框架或 genesis Prover，上一节创世入口超时的限制仍然适用。

本轮最终 `head.mrb` SHA-256 为
`3f7c4efdc87bd271cf1d57f310b74fe3532ca50c868ca289f22d8a59d7daee3d`；SDK 与本轮开始快照逐字节一致。


## 2026-09-10：开发阶段移除旧版算力迁移

删除 `ensure_normalized`、`migrate_power`、基线旧算力重放和历史升级测试。准备 PoC 时要求算力存储为空；创世先准备共同指数，再直接写入周期 0 的算力与 units。运行期上传直接生成下一周期标准化版本，无记录用户的快照返回零，允许先分配后上传。版本生效、首次写入及显式零版本规则保持。

本轮验证：

- `cargo run --profile ci -p topo-framework -- update-cached-packages` 与 `cargo build -p aptos-cached-packages` 通过，已更新 `head.mrb` 和 SDK 绑定。
- `cargo test --profile ci -p topo-framework --test move_unit_test move_framework_unit_tests -- --nocapture`：878 个 Move 测试通过。
- `E2E_PARALLEL_EXEC=1 cargo test --profile ci -p e2e-move-tests tests::poc_consensus:: -- --nocapture --test-threads=1`：9 个端到端测试通过。
- `cargo test --profile ci -p aptos-vm-genesis poc_ -- --nocapture`：2 个创世测试通过。
- `cargo check --profile ci -p e2e-move-tests --tests`、变更 Rust 文件的 nightly rustfmt 检查、`git diff --check` 通过。
- 对 `e2e-move-tests` 和 `aptos-cached-packages` 使用仓库 xclippy 的 lint 参数并指定 `--all-targets --no-deps`：通过。包含依赖的检查被未修改的 `crates/aptos-metrics-core/src/const_metric.rs` 第 40、66、87 行 `clippy::useless_conversion` 阻塞。

本轮未重跑 Move Prover 或节点 smoke 测试；前文历史兼容性及节点测试结果不作为本轮产物的验证证据。

## 2026-09-10：统一算力版本存储

将原始算力与标准化算力合并到 `PowerStore.users`。`PowerVersion` 同时保存生效周期、`power` 和 `units`，两个 `Option` 槽区分空槽与有效零算力版本；共同指数与基线作为 `PowerStore.normalization` 保存，保留比例只保存一份，`PeriodClock` 继续独立维护时钟。上传和创世写入共用完整版本写入口，显式检查较新版本存在及双版本的严格顺序，再一次写入用户表。

原始查询与标准化快照共用版本选择，原始算力仍逐周期整数衰减，持仓 units 仍只在版本创建时计算。新增回归覆盖未准备状态拒绝计账、原始查询与 units 的版本切换一致性、有效零值和两种算力计算各自的取整规则。开发阶段直接使用新结构，不提供旧资源迁移。

本轮验证：

- 已重新生成缓存并执行 `cargo build -p aptos-cached-packages`；SDK 绑定生成并格式化后与本轮开始时一致。
- 加入顺序校验后的框架 Move 测试 881 / 881 通过，PoC E2E 9 / 9 通过；E2E 启用顺序与并行执行对照，包含五条换届路径差分。
- 最终错误码规格按标准库的抽象错误类别表达，算力存储模块的 51 个 Prover 目标全部通过，总耗时 36.69 秒；未新增证明假设或关闭验证。
- 最终缓存的 Rust 创世测试 2 / 2 通过。`cargo check --profile ci -p e2e-move-tests --tests`、使用仓库 xclippy 参数的两个相关包 `--all-targets --no-deps` 检查、变更 Rust 文件格式检查及 `git diff --check` 通过。

本轮未重跑全框架 Prover、节点 smoke 或全 workspace lint。最终 `head.mrb` SHA-256 为 `3f71a237f3492469e05567733a15c534affa2db4a6ef0d24f0791068793a4746`。


## 2026-09-10：算力存储一次初始化

PoC 创世在 Epoch 0 通过 `prepare_poc` 一次性创建算力表、标准化状态和周期时钟，随后写入算力与分配并安装 Epoch 1。创世不再先创建原始存储、修改保留比例、再补建标准化状态。本次精简的是算力存储的初始化路径；账本的准备与启用控制仍由既有流程管理。

- `PowerStore.normalization` 改为必有的 `NormalizationState`，移除 `has_versions` 和未准备时写入 `units = 0` 的分支；创世及上传始终计算标准化版本并同步持仓。
- 删除独立原始存储初始化接口、保留比例 setter 和无调用方的旧质押算力写入接口。保留比例只能在完整初始化时确定，重复初始化被拒绝。
- 周期及本地提交计数固定从 0 起算，删除恒为 0 的 `baseline_source_period` 与 `baseline_local_epoch`。时钟校验简化为 `last_epoch == accounting.epoch - baseline_epoch`，共同指数直接使用算力周期编号。
- 原生 `stake::on_new_epoch` 不再推进独立的原始算力时钟；已创建 PoC 状态的换届通过安装计划统一推进一次。
- 初始化查询统一为 `is_initialized()`。`get_normalization_clock()` 缩减为六项：初始化 Epoch、当前周期、下一边界 Epoch、当前指数、可选下一指数和支持期限，仓库调用方同步调整。
- `units`、`index` 继续使用 `u128`，计算公式、精度、整数取整方式和支持期限保持原值。生产缓存与生成的 SDK 已同步更新。

本轮验证：

- 已重新生成缓存并执行 `cargo build -p aptos-cached-packages`；生成的 SDK 删除了旧初始化和保留比例修改入口。
- 框架 Move 测试 879 / 879 通过，覆盖创世周期边界、版本切换、缺少时钟提交、重复初始化和边界溢出。
- 算力存储模块 44 个 Move Prover 目标全部通过，包含完整初始化的后置条件，总耗时 28.90 秒。
- 精确过滤 `tests::poc_consensus::` 的 9 个生产字节码端到端测试全部通过，启用顺序与并行执行对照，包含五条换届路径差分；Rust PoC 创世测试 2 / 2 通过。
- `cargo check --profile ci -p e2e-move-tests -p aptos-cached-packages --all-targets`、使用仓库 xclippy 参数的两包 `--all-targets --no-deps` 检查、两包 nightly 格式检查及 `git diff --check` 通过。

首次使用较宽的 `poc_` 过滤时额外命中三个与 PoC 共识无关的测试。其中 `tests::init_module_closure_store::poc_type_confusion_module_upgrade_parallel` 因测试脚本使用未配置的 `aptos_std` 地址而失败，该文件未修改；另两项通过。该次宽过滤运行不计为整体通过，之后精确过滤的 PoC 共识测试结果如上。

本轮未重跑全框架 Prover、节点 smoke 或全 workspace lint。最终 `head.mrb` SHA-256 为 `5416603c158efb2ff9fa40f3374db6c1be0f8637a1da173c90895ebe7c08b8f3`。

## 2026-09-10：创世验证者统一初始算力与全额分配

`PocGenesisConfiguration` 使用显式 `initial_raw_power: u64` 为每个创世验证者指定相同的初始原始算力，要求大于零。验证者身份和代币保证金仍取自 `Validator` 记录。Move 在 Epoch 0 为每个 owner 自动启用同地址的池，写入 PowerStore 周期 0 算力与 `units`，并通过普通分配入口设置 `[owner] / [10000 bps]`，在 Epoch 1 生效。

创世不再接受自由的用户、启用池和分配清单；Rust 的 `UserPower`、`Allocation` 类型及对应五组 Move 参数已删除。PoC 专用入口只接收普通验证者记录，在 Move 中固定 owner 直接持有池、零佣金、申请加入，避免配置产生 owner 与 pool 地址不一致。重复 owner 仍由现有建池检查拒绝。

初始算力独立于保证金数额。周期 0 的 `units = initial_raw_power * 2^32`，全部分配到本池；最终权重仍为原始算力、保证金可支持权重与 `max_power` 的最小值，并遵守现有准入、人数和集中度校验。`units` 与 `index` 的类型及精度未变，仍只安装一次 Epoch 1，不发放 Epoch 0 奖励。

同步调整 Rust 构建器、Move 测试和规格、真实节点测试构造器与 JSON 示例。新验收覆盖配置值 17 的实际写入及 VM 重载、统一算力 100 在不同保证金下的完整分配、开放模式集中度拒绝、零初始算力拒绝。

规格验证同时补齐一次初始化重构后的模块间约束：`prepare_poc` 明确创建 PowerStore 和 PeriodClock 并设置初始上传者、周期长度；`commit_next_period_if_boundary` 和 `install_epoch_plan` 明确只在框架地址修改这两个资源，并保留上传者和周期长度配置。这些修改补强既有后置条件，没有更改运行期换届逻辑，也没有增加算力 setter 的 opaque 假设。

已完成的验证：

- 最终缓存下框架 Move 测试 **880 / 880**，`aptos-vm-genesis` 包测试 **6 / 6**，包含四个 PoC 创世用例与两个普通创世用例。
- 最终缓存下精确过滤 `tests::poc_consensus::` 的端到端测试 **9 / 9** 通过，启用 `E2E_PARALLEL_EXEC=1`，耗时 14.23 秒。
- `create_initialize_poc_validators`、`prepare_poc`、`commit_next_period_if_boundary` 与 `install_epoch_plan` 的 Prover 验证全部通过，共 8 个验证目标，包含安装的四个分支和依赖引理。最初创世证明因调用摘要缺少资源存在性和保持项而超时；补强并逐项独立验证后通过，没有降低既有断言。
- 5 个真实节点场景整组通过，耗时 305.54 秒，覆盖同步重启、普通 DKG、Chunky DKG、成员替换、冻结恢复。该组运行使用功能修改后的 `0fc09fdd253c01624decfa92e57c024a9246360f3f1191d0f6b2a7ab0381c813` bundle；随后增加上述规格约束并重新生成最终缓存。
- 最终缓存和对应节点另行复验 `poc::poc_genesis_restart`，**1 / 1** 通过，耗时 27.38 秒。
- 三个修改的 Rust 包通过 `cargo check --all-targets`、使用仓库 xclippy 参数的 `--all-targets --no-deps` 检查及 nightly 格式检查，`git diff --check` 通过。

最终 `head.mrb` SHA-256：`0360e0a60d7d9c492552dfcac278ff528bf9fa65b24b84ff8ff79381a1f04262`。最终缓存已执行 `cargo build -p aptos-cached-packages`，对应节点已重新构建。未执行全工作区测试或全框架 Prover。

### 创世即支持 PoC 的并行分析

以下为只读审查结论，尚未混入本次创世算力配置修改：

- `poc_allocation::prepare_poc` 仍允许运行期准备，`activation_epoch`、`first_poc_epoch` 和重新安排启用时间仍用于从原生模式切换。若仅允许 PoC 创世，可先将初始化限定为创世 Epoch 0，再精简这些状态与入口；`pending_params` 仍服务普通治理调参，应保留。
- `stake` 的准备上下文、计划预览和奖励结算仍处理最后一个原生 Epoch。限定 PoC 初始化到创世后，可改为直接建立初始 PoC 上下文。创世 0→1 的增长预算例外与零奖励约束必须保留，否则零初始委员会无法安装首届验证者。
- 独立原生创世仍是普通 Rust/CLI 构建器的有效路径，PoC 配置为可选项。不能仅因 PoC 链从创世启用就删除所有原生换届、事件或资源分支；是否所有链都必须使用 PoC，是更大的范围选择。
- `PowerNormalized` 与 `PowerUpdateStagedEvent` 在运行期上传时重复记录同一版本信息，可以合并为包含用户、生效周期、原始算力与 units 的一次版本写入事件，并同时覆盖创世写入。尚未修改事件接口。
- 奖励期限边界需单独验证：预览会先拒绝超出期限的目标 Epoch，再结算旧 Epoch。由静态调用顺序推断，在首期为 1、期限为 H 时，H→H+1 的普通换届可能先被拒绝，使 Epoch H 奖励无法通过该次换届结算。现有直接账本奖励测试不覆盖这一真实换届边界，应明确最后可安装期与最后可结算期的含义后补验证。
- 保留冻结、失败预检与重试、DKG 会话目标匹配和首届密钥初始化；这些机制服务正常运行期换届，不能按创世简化一并删除。

## 2026-09-10：保证金比例统一使用 Octa/OHMP

保证金参数改为 `bond_octa_per_ohmp: u64`，表示每 1 OHMP 所需的 Octa 数，必须为正。
`1 OHMP = 100,000,000 power`，`1 TOPO = 100,000,000 Octa`；例如 `250,000,000 Octa/OHMP` 表示 2.5 TOPO/OHMP。
删除 `DeploymentLimits.power_scale`，换算分母使用固定常量 `POWER_PER_OHMP = 100,000,000`。

| 原命名 | 当前命名或处理 |
| --- | --- |
| `bond_per_power` | `bond_octa_per_ohmp` |
| `power_scale()` | 纯函数 `power_per_ohmp()`，返回固定单位常量 |
| `get_params_fields()` | `get_power_params_fields()` |
| `bond` / `bond_cap` | `bond_octa` / `bond_cap_power` |
| `reward_base` / `max_reward_base` | `reward_base_octa` / `max_reward_base_octa` |
| `pool_reward_base()` | `pool_reward_base_octa()` |

字段更名覆盖 `PowerParams`、`PoolLedger`、`PoolTarget`、`PoCRewardCredited`、Rust BCS 镜像、测试构造器和 JSON 清单。
开发阶段直接使用新结构，不增加旧字段别名或迁移。算力门槛与 `initial_raw_power` 仍以整数 power 计量，`units/index` 类型和精度不变。

```text
bond_cap_power = floor(bond_octa * POWER_PER_OHMP / bond_octa_per_ohmp)
reward_base_octa = floor(power * bond_octa_per_ohmp / POWER_PER_OHMP)
```

既有测试配置的分母均为 1，本轮将其比例分子乘以 100,000,000，保持原担保效果、权重与奖励预期。
新增生产创世回归以 `250,000,000 Octa/OHMP`、17 power 和 `[42, 43, 100, 100]` Octa 保证金检查两次向下取整：
最终权重为 `[16, 17, 17, 17]` power，计奖基数为 `[40, 42, 42, 42]` Octa，每个 owner 仍持有完整的 `17 * 2^32` units。

本轮验证：

- 重新生成框架缓存并执行 `cargo build -p aptos-cached-packages`；框架 Move 测试 **880 / 880** 通过。
- `aptos-vm-genesis` 包测试 **7 / 7** 通过，包含新增的 Octa/OHMP 限幅与取整用例，以及两个普通创世用例。
- PoC 端到端测试 **9 / 9** 通过，启用 `E2E_PARALLEL_EXEC=1`，运行耗时 15.08 秒。命令为 `cargo test --profile ci --config 'profile.ci.package.e2e-move-tests.opt-level=0' -p e2e-move-tests tests::poc_consensus:: -- --nocapture`；只降低测试包自身的编译优化级别，复用 ci 配置的依赖。
- `poc_accounting` 的全部 **59** 个 Prover 验证目标，以及 `stake::preview_transition` 与依赖引理 **2** 个目标通过。
- 三个修改的 Rust 包通过 `cargo check --all-targets`、仓库 xclippy 参数的 `--all-targets --no-deps` 检查及 nightly 格式检查；改动文件的空白检查通过。
- 使用最终缓存重新构建 `aptos-node`，真实节点 `poc::poc_genesis_restart` **1 / 1** 通过，耗时 28.70 秒，覆盖 PoC 创世加载、推进 Epoch 与重启后继续共识。

最终 `head.mrb` SHA-256：`2c8e8770b6044fa0a886b1bdaa0d4dd4b4d961ed2f8c9d68b63b152b561a31f6`。

## 2026-09-10：兼容现有 TOPO 配置的 PoC 主网默认值

`PocGenesisConfiguration::mainnet()` 返回主网默认 PoC 配置，`Default` 复用同一份定义；调用者可继续覆盖 PoC 字段。
默认保证金比例为 1 TOPO/OHMP，每个验证者初始获配 100 万 OHMP，最低权重 1 OHMP、每池上限 200 万 OHMP。
开放委员会最低人数为 5、容量为 128，最低人数满足现有 Layout 的 20% 增长预算与动态换员约束，也兼容仓库主网配置的 30%。

默认保留比例为 9995 bps，最大相对周期为 10000，奖励期数上限为 600060；保留 Move 创世的 60 Epoch 周期、0x1 上传者和零初始费用分发限额。
计奖基数上限为 200 万 TOPO，奖励率上限为每 Epoch 1%，费用分发限额的上界为每池每 Epoch 1000 TOPO。
实际奖励率仍取自 TOPO 配置。默认数值满足指数下界、总权重和累计奖励金额上界，完整参数见[主网默认值](POC_GENESIS_IMPLEMENTATION_CHECKS.md#主网默认值)。

本轮只增加 Rust 默认配置、回归测试和说明文档，没有调整 TOPO 配置、Move 字节码、共识换届算法或奖励计算公式。
新增验证分别使用未修改的 `mainnet_genesis_config()` 和当前 `Layout::default()` 的经济参数；主网测试以正式代币模式执行，保留默认功能开关。
前者比较 PoC 与原生创世的 StakingConfig、StakingRewardsConfig、GovernanceConfig 和 BlockResource 原始字节，并核对每个 owner 的保证金、PowerStore、完整分配、权重及 Epoch 1。
后者按主网入口的既有规则开启动态换员，覆盖 5 人/最低保证金、128 人/最高保证金及人数不足时拒绝初始化。

验证结果：`cargo test --profile ci -p aptos-vm-genesis -p aptos-genesis` 全部通过，包含 8 项 VM 创世测试和 2 项 Layout 集成测试。
两个包的 `cargo check --all-targets`、使用仓库 xclippy 参数的 Clippy 检查、nightly 格式检查和改动空白检查通过。
本轮未修改 Move 源码，测试使用的生产缓存 SHA-256 仍为 `2c8e8770b6044fa0a886b1bdaa0d4dd4b4d961ed2f8c9d68b63b152b561a31f6`。

## 2026-09-10：兼容现有 TOPO 测试创世的 PoC 测试网默认值

新增 `PocGenesisConfiguration::testnet()`，复用主网默认配置，仅将初始算力改为 1 OHMP、最低权重改为 1 power、
每池权重上限改为 1,000 OHMP、计奖基数上限改为 1,000 TOPO。保证金比例仍为 1 TOPO/OHMP，
开放委员会最低 5 人、容量 128；`Default` 仍返回主网配置。较低的权重门槛让初始 1 OHMP 在首次衰减后仍可参与。

原生 `generate_test_genesis` 的配置字面量抽取为私有 `test_genesis_config()`，所有字段值保持原样，
供原生创世和 PoC 测试网验收共用，防止测试通过调整 TOPO 参数绕过校验。
新增测试使用测试网 ChainId、测试代币初始化及默认功能开关，覆盖 5 个和默认 10 个验证者，每池质押 1 TOPO，
检查原始算力、完整分配、最终权重、保证金、奖励上下文及 Epoch 1；与主网复用四个 TOPO 配置资源的字节比较。

验证结果：`cargo test --profile ci -p aptos-vm-genesis -p aptos-genesis` 全部通过，包含 9 项 VM 创世测试和 2 项 Layout 集成测试。
两个包的 `cargo check --all-targets`、使用仓库 xclippy 参数的 Clippy 检查、nightly 格式检查和改动空白检查通过。
本轮仅修改 Rust 与文档，生产缓存 SHA-256 仍为 `2c8e8770b6044fa0a886b1bdaa0d4dd4b4d961ed2f8c9d68b63b152b561a31f6`。

## 2026-09-10：测试网最低 2 个验证者

`PocGenesisConfiguration::testnet()` 将最低人数改为 2、部署模式改为既有 `Controlled`。
开放模式继续要求至少 4 人并检查 `3 * pool_power < total_power`；主网和 `Default` 保持开放模式、最低 5 人。
测试网原生增长上限仍为 50%，满足 `floor(2 * min_power * 50 / 100) >= min_power`，无需调整 TOPO 配置。
两个等权验证者必须同时参与投票才能达到既有共识门槛，任一节点停机都会停止出块；此配置用于受控联调。

测试网创世回归扩展到 2、5、默认 10 个验证者，继续核对完整 PoC 状态并与原生 TOPO 配置逐字节比较，
另增加单验证者创世必须拒绝的边界用例。本轮仅调整 Rust 默认参数、测试和文档，复用生产 Move 中已有的受控模式。

验证结果：`cargo test --profile ci -p aptos-vm-genesis -p aptos-genesis` 全部通过，包含 10 项 VM 创世测试和 2 项 Layout 集成测试。
两个包的 `cargo check --all-targets`、使用仓库 xclippy 参数的 Clippy 检查、nightly 格式检查和改动空白检查通过。
生产缓存 SHA-256 仍为 `2c8e8770b6044fa0a886b1bdaa0d4dd4b4d961ed2f8c9d68b63b152b561a31f6`。

## 2026-09-11：保证金与算力奖励分流

本次由子 agent 修改奖励与治理配置、委托池及测试、创世和文档，主 agent 审查接口、资产归属、
冻结状态、容量边界和跨模块行为，并统一重建缓存及运行验证。修改保留在工作区，未提交或发布。
本节记录本轮变更；上文历史测试数量、节点 smoke 结果和缓存摘要不作为这次分流调整的验证证据。

每个 PoC 池继续按已安装算力折算的 `reward_base_octa`、当期奖励率和出块表现计算一次通胀总额，
随后使用 `native_reward = floor(inflation * native_reward_bps / 10_000)`，PoC 部分取余额。
各路按分流金额铸造，总和不重复增发；允许分发的交易费全部进入 PoC 金库。
原生部分按 `active / pending_inactive` 的有效本金比例入账，`pending_inactive` 向下取整、余额归 `active`，
沿用原有份额、佣金、锁仓与复投。`pending_active / inactive` 不参与当期计奖；PoC 部分继续按 `units` 分配、运营佣金为零。

分流比例为纯百分比，独立于 `bond_octa_per_ohmp` 的 Octa/OHMP 担保单位。新准备和 PoC 创世默认
`native_reward_bps = 3000`，即保证金 30%、算力 70%；JSON/YAML 省略新增字段采用该默认值，
显式 `0` 保留全额 PoC 通胀，`10_000` 将通胀全部分入原生路径。既有链若尚无分流资源，继续使用 `0`，
须显式治理排定比例并成功换届后才启用新分流，不因代码升级自动改变正在计奖的 Epoch。

新增 `poc_reward_split::RewardSplitConfig` 保存配置、待生效值和已安装快照，保留现有
`RewardContext`、`PowerParams`、`EpochPlan` 及 `PoCRewardCredited` 的布局。治理通过
`stake::schedule_reward_split` 指定未来 Epoch，未冻结时可替换或通过 `cancel_pending_reward_split` 撤销；
当期占比由快照固定。`PoCRewardCredited.inflation` 表示实际进入 PoC 金库的通胀，新增
`PoCRewardSplit` 事件记录总通胀、占比和两路金额，原生正奖励继续产生 `DistributeRewards`。

主审及交叉审查修正的关键问题：

1. 分流配置与已安装 Epoch 分开保存，结算使用旧快照；DKG 冻结拒绝排期和撤销，完成后才安装下一期比例。
   原生分流复投从后续预检起增加保证金，不能回算本次冻结委员会。五条完成路径共享同一行为。
2. PoC 委托池不能继续返回零入池费，也不能直接套用原生 APY。费用根据固定 PoC 基数、当期原生占比、
   有效本金和佣金保守估算，排除 `pending_active`；对净收益及本金分段取整保留保护，覆盖微小正奖励。
3. 佣金从 100% 降至 0% 时，若只按墙上时间生效，延期或 DKG 等待期间的待入池本金可能先支付零入池费、
   再分享旧期净奖励。PoC 模式在 `StakePool.pending_active > 0` 时暂缓到期佣金调整，成功换届后先按旧佣金同步收益，
   再应用新佣金。原生模式的佣金生效规则保持原行为。
4. 仅在换届时检查原生余额，可能让用户先追加到 `u64::MAX`，随后旧期正奖励无法发放且不能通过修改未来占比修复。
   当前 PoC 原生奖励上界为正时，`add_stake_with_cap` 对四类余额、追加本金和当期奖励之和作容量检查，超限原子拒绝。
5. 下一期原生奖励上界为正的入选池，预检另保留“四类现有余额 + 旧期入账上界 + 下一期原生奖励上界”的容量，
   下一期上界使用目标计奖基数、目标比例与部署奖励率上限。旧期及到期转换也保留精确容量检查，覆盖 DKG 等待期间的最优表现。
   不安全的未来比例在冻结前返回 `Deferred`，可撤销待生效比例或提取 inactive 修复；不追改旧期奖励，也不宣称原生本金具有整个 `H` 的静态容量保证。
6. 保留原 Move 创世入口签名，Rust 通过新增显式分流入口传值；默认和自定义比例都在 Epoch 1 安装，Epoch 0 不发奖。
   分流资源加入 E2E 回滚快照，组合治理事务失败时不能留下孤立的待生效比例。
7. 部署奖励率上限可高于 100%，容量估算不能直接调用要求实际奖励率不超过 100% 的计奖 helper。
   预检改用 `u256` 计算该上界，超过可表示范围时在窄化前返回 `Deferred`，并增加对应回归。

本轮已确认的验证：

| 检查 | 本次结果与范围 |
| --- | --- |
| 框架 Move 单测 | 最终源码 **913 / 913** 通过，耗时 **7.33 秒**，包含分流边界、冻结、原生容量、委托入池费、佣金及部署奖励率上界回归；日志 `/tmp/poc-reward-final-move-tests.log` |
| PoC E2E | 最终缓存复验 **9 / 9** 通过，`E2E_PARALLEL_EXEC=1`，耗时 **40.06 秒**；日志 `/tmp/poc-reward-final-e2e-tests.log`，五条换届路径均为 `passed=true`。此前一轮同组 9 / 9、39.68 秒记录见 `/tmp/poc-reward-e2e-tests.log` |
| 五路径同快照差分 | 同步、普通 DKG、Chunky DKG、超时、强制结束全部通过；旧比例 `3000` 结算、目标比例 `6000` 安装，比较原生余额、PoC 金库、两路事件及总额守恒 |
| E2E 交易费输入 | 分支前通过 VM `BlockEpilogueV2` 提供同一笔 3 Octa 费用归属，验证全部进入 PoC；不以此覆盖上游费用归属计算 |
| 原生质押相关 E2E | 最终缓存执行 `cargo test --profile ci -p e2e-move-tests stake -- --nocapture --test-threads=1`，**13 / 13** 通过，耗时 **9.17 秒**；包含 stake 模块 3 项及 transaction_limits 10 项，日志 `/tmp/poc-reward-final-native-e2e-tests.log` |
| 模块兼容性 | 对最终缓存核对：原 **196** 个模块的接口及结构布局兼容，新增 **1** 个模块；不等同于真实节点升级演练 |
| Rust 编译检查 | `cargo check --profile ci -p aptos-vm-genesis -p aptos-genesis -p e2e-move-tests -p smoke-test --tests` 通过，耗时 **21.98 秒** |
| 格式与空白 | nightly rustfmt、`git diff --check` 通过 |
| Clippy | 上述四个 Rust 包按仓库 xclippy 参数执行 `--all-targets --no-deps` 通过，耗时 **47.57 秒**；日志 `/tmp/poc-reward-clippy.log` |
| 创世包测试 | 最终缓存执行 `cargo test --profile ci -p aptos-vm-genesis -p aptos-genesis -- --nocapture`，`aptos-genesis` 单元 3 项、`poc_mainnet_defaults` 集成 3 项、`aptos-vm-genesis` 单元 10 项，共 **16 / 16** 通过；编译 35.75 秒，三组运行分别 0.22、0.47、0.69 秒。日志 `/tmp/poc-reward-final-genesis-tests.log`，0 项文档测试不计入 |
| 定向 Move Prover | 新模块写函数补齐 `modifies`、部署奖励率上界修正后，`poc_reward_split` 模块 **10 / 10** 个目标通过（10.30 秒，`/tmp/poc-reward-split-module-prover.log`）；`native_reward_shares` 及既有依赖引理 **2 / 2**（5.52 秒，`/tmp/poc-reward-shares-prover-after.log`）、`preview` 及既有依赖引理 **2 / 2**（7.66 秒，`/tmp/poc-reward-preview-prover-final.log`）、`install` 的 4 个拆分目标及既有依赖引理共 **5 / 5**（25.44 秒，`/tmp/poc-reward-install-prover.log`）均通过。各组重复依赖引理不合并为独立目标总数 |
| 节点 smoke | 用最终缓存重新构建 debug 节点，`cargo build -p aptos-node --features failpoints,smoke-test` 通过，耗时 **35.25 秒**（`/tmp/poc-reward-final-node-build.log`）。`poc::poc_genesis_restart` **1 / 1** 通过、进程退出码 0，耗时 **29.09 秒**；日志 `/tmp/poc-reward-final-smoke-debug.log`。该场景显式占比为 `0`，验证节点加载及重启兼容；正比例分流由 Move、生产 E2E 和默认创世用例覆盖 |

上界估算与规格修正后，已重新生成最终生产/测试缓存，并执行 `cargo build -p aptos-cached-packages` 成功。
最终 `head.mrb` SHA-256：`a3eba89b7d03eba892b6c46f9949fc9a593de79406e3759dde479e38dd51fdfb`。
兼容性基线为本轮开始前临时保存的 `before.mrb`，SHA-256：
`8ff7b01645b70866ed57d499c4438b035814da260af1c1caee1dbfe7c1975c36`；不是上文历史记录中的缓存。

本轮通过的节点 smoke 使用仓库默认 debug profile，命令为：

```bash
SMOKE_TEST_BIN_DIR=/Users/cc/work/topo/topo-chain/target/debug \
  cargo test -p smoke-test poc::poc_genesis_restart -- --exact --nocapture --test-threads=1
```

此前使用 `--profile ci` 的首次尝试在依赖编译阶段主动中止，退出码 130，测试尚未开始，不计作验收通过。
本轮未运行完整五场景节点 smoke、全工作区测试或全框架 Prover；上述定向验证不替代这些范围。


## 2026-09-13：通胀与可分发交易费同比分流

通胀与可分发交易费分别使用旧 Epoch 的 `native_reward_bps`，原生份额向下取整、各自余额归 PoC。两类收入各自守恒；费用先应用旧上下文的开关和每池限额。原生部分按同一入账前有效本金分配，沿用佣金、锁仓和复投；`PoCRewardCredited.fee` 记录实际 PoC 费用，原生费用由既有 `DistributeTransactionFee` 记录。已有事件及配置资源布局保持兼容。

当期容量和委托入池费估算纳入快照的可分发费用上限；下一期容量预留纳入部署费用上限，以覆盖冻结提交时才生效的费用配置。入池费采用保守上限，实际费用未收满时可能高于按实际净收益计算的值。

当前新增验证覆盖：费用限幅后分流、零通胀费用收入、0%/30%/100% 占比、费用开关与限额的旧期快照、有效本金分段、委托份额与佣金、未累计费用时的当前/下一期容量及追加质押拒绝。五种换届完成路径的差分用例改为 17 Octa 费用，明确断言原生 5、PoC 12，并核对两路余额和事件。以下验证结果以本次执行为准，历史结果不作为本次通过证据。

已完成的验证：

- `cargo run --profile ci -p topo-framework -- update-cached-packages` 与 `cargo build -p aptos-cached-packages` 通过。生产 `head.mrb` 为 1,525,477 字节，SHA-256 为 `73a5416d3da4dfc5ec5905770d1ae548af7ef82be00f1c5afd292e2a0ebb5bb7`。
- `cargo test --profile ci -p topo-framework -- --skip prover` 通过：全部 1,689 项 Move 单测，其中核心框架 920 项；其余 Rust harness 与文档测试也通过。日志 `/tmp/poc-fee-split-framework-tests.log`。
- `cargo check --profile ci -p e2e-move-tests -p aptos-vm-genesis --tests`、`cargo +nightly fmt --check` 通过。
- `poc_reward_split` 定向 Move Prover **11 / 11** 通过，包括通用分流函数；使用已安装的 Boogie 3.5.6 与 Z3 4.13.0。日志 `/tmp/poc-fee-split-prover.log`。

首次端到端尝试在 `e2e-move-tests` 的优化编译阶段主动中止，尚未开始运行用例，不计作测试结果。最终 E2E 使用 `--config 'profile.ci.package.e2e-move-tests.opt-level=0'`，只调整测试包自身的编译优化级别。

最终生产缓存下的验证结果：

- PoC E2E **9 / 9** 通过，启用 `E2E_PARALLEL_EXEC=1`，运行 40.03 秒。同步、DKG、Chunky DKG、超时和强制完成五条路径均为 `passed=true`，并核对 17 Octa 费用分为原生 5、PoC 12。日志 `/tmp/poc-fee-split-e2e-tests-fast.log`。
- 原生质押相关 E2E **13 / 13** 通过，运行 9.49 秒。日志 `/tmp/poc-fee-split-native-e2e.log`。
- `cargo test --profile ci -p aptos-vm-genesis -p aptos-genesis -- --nocapture` 通过：3 项 aptos-genesis 单测、3 项主网默认配置集成测试、10 项 VM 创世单测，共 **16 / 16**。日志 `/tmp/poc-fee-split-genesis-tests.log`。
- 使用仓库 `xclippy` 全部 lint 参数，对 `e2e-move-tests`、`aptos-vm-genesis` 运行 `--all-targets --no-deps` 检查通过。日志 `/tmp/poc-fee-split-clippy.log`。最终 `git diff --check` 通过。
