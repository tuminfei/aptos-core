# PoC 直接创世：主网、测试网默认值与测试清单

> 2026-09-11 新增奖励分流配置与验收项。下文已标日期的历史测试结果及 bundle 摘要保持原样，不作为这次分流调整的通过证据；当前测试结果以重新生成的 bundle 和实际日志为准。

完整业务链路、双节点恢复、核心用例步骤与覆盖缺口见 [PoC 改造核心测试用例](POC_CORE_TEST_CASES.md)。

单位约定：`OHMP`（One Hundred Million Power，亿算力）为展示单位，`1 OHMP = 100,000,000 power`，展示精度为 8 位小数；`1 TOPO = 100,000,000 Octa`。本文与 JSON 清单中的原始算力、PoC 权重及其门槛均以整数 `power` 计量，保证金和奖励金额以 `Octa` 计量。标准化 `units` 不直接作为 OHMP 展示；详见设计稿的[算力与代币单位](POC_CONSENSUS_V2_MINIMAL_POWER_REWARD_DESIGN.md#算力与代币单位)。

## 主网默认值

`PocGenesisConfiguration::mainnet()` 提供主网 PoC 默认参数，`PocGenesisConfiguration::default()` 返回同一套值。
将它传给现有 PoC 创世入口即可；TOPO 的 `GenesisConfiguration`、质押门槛、Epoch 长度、奖励率与功能开关无需为 PoC 调整。
验证者仍须满足原生质押资格；默认开放委员会支持 5–128 名验证者，每个 owner 获得 100 万 OHMP 并全额分配到本池。

| 字段 | 默认值 | 含义 |
| --- | --- | --- |
| `params.bond_octa_per_ohmp` | `100_000_000` | 1 TOPO/OHMP |
| `params.min_power` | `100_000_000` | 最低生效权重 1 OHMP |
| `params.max_power` | `200_000_000_000_000` | 每池最多 200 万 OHMP |
| `params.min_validators` | `5` | 兼容现有 Layout 的 20% 增长上限和动态换员 |
| `limits.max_allocations` / `max_claim_pools` | `4` / `4` | 分配并集及单次领取池数上限 |
| `limits.max_upload_users` | `32` | 原始算力单批上传人数上限 |
| `limits.validator_limit` | `128` | 候选容量 |
| `limits.max_reward_base_octa` | `200_000_000_000_000` | 单池计奖基数上限 200 万 TOPO |
| `limits.rate_max_num` / `rate_max_den` | `1` / `100` | 每 Epoch 奖励率上限 1%；实际奖励率沿用 TOPO 配置 |
| `limits.fee_max` | `100_000_000_000` | 每池每 Epoch 费用分发限额可设置到 1,000 TOPO；创世实际限额仍为 0 |
| `limits.reward_epoch_limit` | `600_060` | 与 0..=10000 周期、每周期 60 Epoch 对应的奖励期数上限 |
| `deployment_mode` | `Open` | 开放模式，保留集中度检查 |
| `retention_bps` | `9995` | 每个算力周期保留 99.95% |
| `max_relative_period` | `10_000` | 最大相对算力周期 |
| `initial_raw_power` | `100_000_000_000_000` | 每个验证者初始 100 万 OHMP |
| `native_reward_bps` | `3000` | 通胀和可分发交易费分别按 30% 进入原生质押、70% 进入 PoC，原生向下取整、余额归 PoC |

最低人数取 5，是因为动态换员要求 `min_validators * min_power * increase_limit / 100 >= min_power`。
现有 Layout 的增长率为 20%，5 人恰好满足；仓库主网创世函数的 30% 增长率也兼容。
原生 `max_stake` 继续保持原值，PoC 单池权重另以 `max_power` 限制，满足 `65536 * max_power <= u64::MAX`。
默认奖励总额上界为 `1_260_126_000_000_000_000 Octa < u64::MAX`；周期 10000 的整数指数为 `124137862714582947 > 2^40`。

奖励只按 PoC 固定基数计算一次再分流，不增加通胀总量。`native_reward_bps` 为 `0..=10_000` 的百分比，独立于 `bond_octa_per_ohmp` 的 Octa/OHMP 担保单位；治理通过 `stake::schedule_reward_split` 指定未来 Epoch 生效，冻结期间拒绝修改。原生部分沿用有效质押余额、份额、佣金和复投，PoC 部分仍按 `units` 分配。追加保证金须保留当期正原生奖励容量；每次 PoC 预检按旧期比例预留本次入账，并为下一期正原生奖励保留目标基数与部署奖励率上限所需容量。未来比例导致不足则在冻结前延期，可取消待生效比例或提取 inactive 修复；不宣称原生本金具有整个支持期限的静态容量保证。

```rust,ignore
let poc_manifest = aptos_vm_genesis::poc::PocGenesisConfiguration::mainnet();
// 也可用 PocGenesisConfiguration::default()，或在返回值上覆盖个别 PoC 字段。
```

## 测试网默认值

`PocGenesisConfiguration::testnet()` 适配现有测试创世每个验证者初始质押 1 TOPO 的配置，
每个 owner 获得 1 OHMP 原始算力并全额分配到本池。它复用主网默认值，仅调整以下六项：

| 字段 | 测试网默认值 | 含义 |
| --- | --- | --- |
| `params.min_power` | `1` | 最低生效权重 1 power，即 0.00000001 OHMP |
| `params.max_power` | `100_000_000_000` | 每池最多 1,000 OHMP |
| `params.min_validators` | `2` | 受控测试网最低人数，配合现有 50% 增长上限 |
| `limits.max_reward_base_octa` | `100_000_000_000` | 单池计奖基数上限 1,000 TOPO |
| `deployment_mode` | `Controlled` | 使用既有受控模式，由部署方控制参与者 |
| `initial_raw_power` | `100_000_000` | 每个验证者初始 1 OHMP |

保证金比例仍为 1 TOPO/OHMP，受控委员会支持 2–128 名验证者，保留比例、容量及其余部署上限与主网一致。
最低权重采用 1 power，使初始 1 OHMP 在首次衰减为约 0.9995 OHMP 后仍满足 PoC 门槛。
原生 TOPO 的质押资格、1 小时 Epoch、10% APY、50% 增长率及默认功能开关沿用现有测试创世参数。
动态换员的最低增长预算为 `floor(2 * 1 * 50 / 100) = 1 power`，恰好满足准入门槛；
搭配其他原生配置时，最低 2 人要求增长上限为 50%，否则须提高最低人数。

开放模式要求至少 4 人，且每池权重严格小于总权重的三分之一，因此 2 人配置使用受控模式。
共识投票门槛保持 `floor(2 * total_power / 3) + 1`；两个等权节点必须同时在线，任一节点停机都会停止出块，
此配置适合受控联调，不具备单节点容错能力。
`Default` 继续返回主网配置；测试网调用者显式选择：

```rust,ignore
let poc_manifest = aptos_vm_genesis::poc::PocGenesisConfiguration::testnet();
```

## 显式测试清单

[POC_GENESIS_TEST_MANIFEST.json](POC_GENESIS_TEST_MANIFEST.json) 是 Move 测试
`genesis::poc_genesis_installs_one_epoch_without_epoch_zero_rewards` 的显式测试参数。
每个池有 100 个代币最小单位保证金，即 `0.000001 TOPO`；`initial_raw_power = 17` 为每个验证者配置 `17 power` 原始算力，即 `0.00000017 OHMP`，自动本人全额分配，初始 BFT 权重各 `17 power`。
测试部署方式是开放模式，四池均满足 `3 * 17 < 68`。这些小数值用于验收，未作为生产参数批准。
该 JSON 不含验证者密钥；有效公钥、持有证明、运营者和网络地址由单独的验证者配置提供。
配置不再包含用户、启用池或分配清单。Move 从实际验证者记录取得 owner，自动启用同地址的池，
向该 owner 的 PowerStore 写入周期 0 原始算力，按 `units = initial_raw_power * 2^32` 标准化，并设置 `[owner] / [10000 bps]`。
`initial_raw_power` 为正的 `u64`，所有创世验证者共用该值；它独立于保证金数额，`units` 和 `index` 精度保持不变。
最终权重仍受保证金、`max_power` 和准入条件限制；全额分配不表示可以绕过这些限制。

JSON 中的 `initial_raw_power = 17`、`min_power = 10`、`max_power = 1000` 仍以整数 power 计量。保证金配置为 `params.bond_octa_per_ohmp = 100000000`，表示每 1 OHMP 需要 `100,000,000 Octa = 1 TOPO`，即每 power 需要 1 Octa；保持原测试的担保效果。分母固定为 `POWER_PER_OHMP = 100,000,000`，部署清单不再提供换算倍率。这些数值仅用于测试，不是生产默认值。

`PowerParams` 与 `DeploymentLimits` 的字段顺序与 Move 结构保持一致，用 BCS 传给
`genesis::create_initialize_poc_validators_with_reward_split`；原内部入口保留原签名，使用 Move 默认比例。`Default` 提供上述主网参数；此处 JSON 继续保存独立的小数值测试清单。
普通 `aptos_vm_genesis::encode_genesis_transaction` 和现有原生创世调用保持原行为。

直接 PoC 创世采用以下三项默认，清单不再提供对应字段，Rust 也不再编码这三个参数：

| 参数 | 创世默认 | 后续治理 |
| --- | --- | --- |
| 算力周期长度 | `genesis` 中固定初始值为 60 Epoch | `set_power_period_in_epochs` 设置后续周期长度，不移动当前边界 |
| 算力上传者 | `0x1`，初始由治理管理上传 | `set_operator` 更换运营地址；框架仍保留原有上传权限 |
| 每池每 Epoch 交易费分发限额 | `0` | `set_transaction_fee_limit_per_epoch_per_pool` 修改后，新安装 Epoch 的奖励上下文采用，且不得超过 `limits.fee_max` |

费用分发限额为零不会停止 gas 收费，也不关闭通胀奖励。上述值在 Move 创世流程中确定，
Rust 的 `mainnet()` 和 `testnet()` 为四项 `PowerParams`、固定部署上限、部署模式、衰减率、支持周期、`initial_raw_power` 及 `native_reward_bps` 提供完整默认值，也可由调用者自定义。JSON/YAML 省略分流字段采用 `3000`，显式 `0` 表示通胀全部进入 PoC，显式 `10_000` 表示通胀全部进入原生；两者都不改变交易费路径。
已有链的 `poc_allocation::prepare_poc` 继续接收完整部署参数，不套用直接创世默认。

显式 PoC 入口位于 [poc.rs](../../aptos-move/vm-genesis/src/poc.rs)，完整路径是
`aptos_vm_genesis::poc::encode_genesis_transaction`。调用者先准备原生 `GenesisConfiguration`、
验证者列表和 `PocGenesisConfiguration`，再保存返回的创世交易：

```rust,ignore
let poc_manifest = aptos_vm_genesis::poc::PocGenesisConfiguration::mainnet();
let transaction = aptos_vm_genesis::poc::encode_genesis_transaction(
    &root_public_key,
    &validators,
    &framework_bundle,
    chain_id,
    &native_genesis_config,
    &consensus_config,
    &execution_config,
    &gas_schedule,
    &poc_manifest,
);
std::fs::write("genesis.blob", bcs::to_bytes(&transaction)?)?;
```

入口创建普通 owner 质押池，PoC 佣金为零，所有验证者申请加入；初始算力 100% 分配到本池，使用下一 Epoch 生效的普通路径。
PoC 专用入口不再接收 staking-contract、佣金或 join 开关，避免 owner 与池地址产生歧义；共同的原生创世入口保持原行为。
它在 Epoch 0 准备基线并构建目标 Epoch 1，不结算虚构的 PoC Epoch 0。
随后既有创世事件步骤将链配置 Epoch 写为 1；账本、奖励上下文和委员会已同为 Epoch 1。
准备后按清单排定 Epoch 1 分流比例，首期安装时写入独立快照；`RewardContext` 的 BCS 布局及原查询保持不变，当前比例由 `stake::get_installed_native_reward_bps` 查询。
周期长度 60 时，倒计时为 59，下一算力边界为绝对 Epoch 61。

以下命令在仓库根目录复现；执行结果以实际日志为准：

```bash
scripts/cargo_build_aptos_cached_packages.sh
cargo build -p aptos-cached-packages

TEST_FILTER=poc_ cargo test -p topo-framework --test move_unit_test move_framework_unit_tests -- --nocapture
cargo test -p aptos-vm-genesis poc_ -- --nocapture
cargo test -p aptos-genesis --test poc_mainnet_defaults -- --nocapture
```

Rust 测试 `poc_genesis_builder_executes_and_reloads_production_bundle` 使用生产 bundle 真正调用
Move 创世入口，检查初始委员会和事件，再将生成的写集装进一个新的 VM，读取账本、池、奖励上下文
及周期边界，核对每个 owner 原始算力 17、本人分配 10000 bps、完整 units、60 Epoch、`0x1` 上传者和零费用限额，并断言查询未写状态。
四个 owner 使用同一外部运营者和投票者，确认算力与持仓按 owner 分别建立。
`poc_genesis_builder_preserves_full_allocation_when_bonds_cap_power` 配置统一原始算力 100，保证金为
`[20, 30, 30, 30]`，核对最终权重被限幅为相同数值，同时每个用户和池仍保有完整的 `100 * 2^32` units。
`poc_genesis_builder_rounds_bond_caps_and_reward_bases_in_octa_per_ohmp` 配置 `250,000,000 Octa/OHMP`（2.5 TOPO/OHMP）、
原始算力 17 power 和保证金 `[42, 43, 100, 100]` Octa，核对权重 `[16, 17, 17, 17]` power、
计奖基数 `[40, 42, 42, 42]` Octa，并验证完整算力分配与金额查询，覆盖非整数比例的两处向下取整。
`poc_genesis_builder_rejects_concentrated_open_committee` 使用
统一原始算力 100 和保证金 `[100, 10, 10, 10]`，要求在生成创世交易时拒绝开放模式集中度违规。
`poc_genesis_builder_rejects_zero_initial_raw_power` 验证 Move 创世入口拒绝零初始算力。
这些测试的原生配置为：minimum stake 1、maximum stake 1000、增长比例 25%、
Epoch 长度 3600 秒、锁仓 7200 秒、投票窗口 3600 秒、原生 APY 10%；PoC 支持相对周期数为 100。

分流调整新增或扩展以下验收：生产 bundle 重载用例显式使用 `6750 bps`，默认主网/测试网用例验证 `3000 bps`；`poc_reward_split_manifest_defaults_and_explicit_zero` 验证旧清单省略字段与显式零值。Move `poc_genesis_defaults_remain_governable` 将 Epoch 2 占比排定为 `5000`，核对 Epoch 1 的 10 Octa 通胀按旧比例分成原生 3、PoC 7，Epoch 2 通胀原生 5、PoC 5，3 Octa 费用按同一比例分为原生 1、PoC 2；两期合计原生本金增长 9、金库增长 14。这些是测试断言说明，不等同于已通过记录。

主网默认值另有独立验证：`poc_mainnet_defaults_initialize_without_changing_topo_config` 直接使用未修改的
`mainnet_genesis_config()`、主网 ChainId、正式代币初始化和默认功能开关，以现有最低保证金创建默认 10 个验证者。
它验证算力、全额分配、保证金、奖励上下文与 Epoch 1，并将质押配置、奖励配置、治理配置和 BlockResource
与同一份 TOPO 配置生成的原生创世逐字节比较。
`aptos-genesis` 的 `poc_mainnet_defaults` 集成测试直接读取当前 `Layout::default()` 参数，按主网路径启用动态换员，
覆盖 20% 增长率下的 5 人/最低保证金、128 人/最高保证金初始化，以及不足 5 人时的拒绝。

测试网默认值由 `poc_testnet_defaults_initialize_without_changing_topo_config` 验证：
与 `generate_test_genesis` 共用同一份原生参数，使用测试网 ChainId、测试代币初始化和默认功能开关，
分别创建 2 个、5 个和默认 10 个验证者，每池质押 1 TOPO。它核对 1 OHMP 原始算力、全额分配、权重、奖励上下文与 Epoch 1，
并使用与主网相同的比较逻辑，确认上述四个 TOPO 配置资源与原生创世逐字节一致。
`poc_testnet_defaults_reject_single_validator` 验证仅提供 1 个验证者时拒绝创世初始化。

本地节点构造器 `aptos_genesis::builder::GenesisConfiguration::poc_genesis_config`
是可选的 Rust 回调，默认 `None`。该回调在验证者身份生成后收到真实 `Validator` 列表，并返回
PoC 配置，可按人数调整部署上限；初始算力由一个配置值提供，owner 与池绑定由 Move 从验证者记录生成。

```bash
cargo build -p aptos-node --features failpoints,smoke-test
SMOKE_TEST_BIN_DIR="$PWD/target/debug" cargo test -p smoke-test --features aptos-config/failpoints poc:: -- --test-threads=1 --nocapture
```

`poc_genesis_restart` 使用同一 typed PoC builder 建四个真实验证者，保证金各 100、权重各 10；
Epoch 长度 10 秒，普通随机数 DKG 与 Chunky DKG 在此测试中显式关闭。
它先等待成功进入 Epoch 2，再重启一个节点，等待所有节点进入重启之后的新 Epoch，比较已安装权重
和奖励上下文。两个 Epoch 追赶等待各限制为 90 秒，最后同版本追赶为 30 秒；节点编译和启动时间另计。
已有二进制可通过 `SMOKE_TEST_BIN_DIR` 指向包含 `aptos-node` 的目录；二进制必须对应当前源码和 bundle。
另两项独立测试复用相同显式清单：`poc_dkg_installs_session_targets` 启用普通随机数 DKG，
`poc_chunky_dkg_installs_same_session_targets` 同时启用普通 DKG、Chunky DKG 与现有加密交易开关。
它们分别在 90 秒、240 秒内等到真实会话完成，再在同一个 ledger version 读取会话元数据、委员会和
上下文，逐项核对目标地址、顺序、公钥及算力权重。Chunky 测试同时核对两种会话的目标相等及目标
Epoch 加密密钥已安装。随后给所有节点 30 秒追赶同一版本并交叉核对资源，避免跨 Epoch 查询混用数据。
这三项测试分别覆盖同步重启、普通 DKG 和 Chunky DKG。

治理恢复另由 `poc_frozen_dkg_force_end_and_restart` 验证。该测试仍为四池各权重 10，Epoch 长度为
30 秒：在节点启动配置中预置普通 DKG 暂停，等待链上会话和成对计划缓存生成，再停一个节点。其余三个节点继续旧 Epoch
出块，缓存计划字节保持不变。该节点在冻结期间重启并追赶，仅恢复该节点的 DKG 处理，确认恢复的仍是同一计划。随后用 swarm
root account 签署既有 `topo_governance::force_end_epoch_test_only` 治理入口交易；该入口沿用受授权的
强制结束路径。测试核对只产生一次换届事件、四个池各结奖一次、周期本地计数只加一，以及安装集合
等于冻结 PVS 和会话目标。解除 DKG 暂停后，所有节点在同一 ledger version 核对委员会和上下文。
冻结等待与治理操作各为 90 秒，旧期出块观察和最后追赶各为 30 秒；不以此结果代替超时验收。

`poc_dkg_replaces_validator_with_growth_budget` 使用五个真实验证者及现有的一条全节点通道、每池权重 10、最低人数 4、
增长比例 25%、候选上限 5，Epoch 长度 30 秒。先在 90 秒内等一次换届完成，再由第一个池的真实
运营者签署退出交易，普通 DKG
安装四人委员会；随后该池的运营者重新申请加入，另一个在任池的运营者签署退出交易。
测试检查待加入权重与 `total_joining_power` 均为零，当前总权重仍为 40；最终替补恰好获得增长预算
允许的 10 权重。两次实际 DKG 的 transcript 均调用现有验证器检查，目标地址顺序来自申请交易后的
成员队列，并与最终委员会的地址、公钥和权重逐一核对。每届四个当期验证者按相同 ledger version
检查安装结果；第二次换届必须包括已回加节点的追赶和资源核对。离任节点可停在退出边界，测试不把
其后续同步作为当期委员会一致性的条件。每次成员交易限时 30 秒，每次换届限时 90 秒，节点追赶
限时 30 秒；不引入新治理或运营权限。

此场景需要节点和测试程序同时启用现有故障注入支持：节点使用 `failpoints,smoke-test`，
测试程序使用 `aptos-config/failpoints`，以通过启动暂停配置的校验。

```bash
cargo build -p aptos-node --features failpoints,smoke-test
SMOKE_TEST_BIN_DIR="$PWD/target/debug" cargo test -p smoke-test --features aptos-config/failpoints poc_frozen_dkg_force_end_and_restart -- --nocapture
```

2026-09-09 在本工作区执行该恢复测试：`1 passed; 0 failed; 0 ignored`，运行时间为 51.52 秒。
这份记录对应 SDK 治理入口版本；先前使用 CLI 现场编译治理脚本的一轮因 debug 编译耗时过长主动终止，
未计作通过。测试使用的节点具有 `failpoints,smoke-test` 特性，未修改生产模块。

2026-09-09 最终 bundle `47fd1a7c693c0bcbb6c079f143d134a1ea098a2ce9a9f56af7eea152d64ef376`
对应的节点已重新构建。整组运行中既有四项全部通过；新增成员测试首次因等待离任节点继续追赶而失败。
按上述全节点拓扑和当前委员会范围修正后，成员替换单项复验 `1 passed; 0 failed; 0 ignored`，
耗时 **113.67 秒**。因此五个场景的成功证据来自分次运行，不能记为一次整组 `5 passed`。
回加节点作为最终四名成员之一，实际通过同版本委员会和奖励上下文核对；不承诺最后离任节点持续同步。

当前开发版本不提供旧版算力迁移。PoC 创世一次性创建算力表、标准化状态与周期时钟，再直接写入初始算力与 `units`；运行期上传按下一周期指数计算版本。无算力用户可先配置分配，后续上传会同步持仓。旧数据重放上限和迁移入口已移除。
