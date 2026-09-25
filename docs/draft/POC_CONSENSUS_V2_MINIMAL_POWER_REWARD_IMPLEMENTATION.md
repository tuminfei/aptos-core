# PoC 共识 v2：算力权重与奖励详细实现文档

> 状态：待实现的工程规格；本文不表示相关功能已经开发或通过测试。
>
> 设计依据：[PoC 共识 v2：算力权重与奖励最小实现方案](POC_CONSENSUS_V2_MINIMAL_POWER_REWARD_DESIGN.md)，包含其 2026-09-08 机制修订及 2026-09-10 OHMP 单位补充。
>
> 源码核对：2026-09-09，提交 `2f669734d2`。设计稿记录的历史核对基线为 `b520f3ebb9`；本文单独记录之后接入的源码，不改写设计稿的历史说明。
>
> 交付目标：将设计落实为模块边界、存储布局、接口契约、算法、换届接入顺序、初始化步骤与验收任务。文中的新类型、函数、事件、错误名和测试文件名均为拟新增名称；代码块是接口草图或伪代码，不可直接作为可编译 Move 源码。

> 创世配置精简：Rust 清单仅保留首届委员会参数、部署模式、衰减保留比例和初始算力。上限由 `poc_accounting::default_deployment_limits()` 初始化，治理经 `poc_allocation::update_deployment_limits` 调整；原生分流采用合约默认 5000 bps，后续按 Epoch 排期。

> 2026-09-13 分流补充：通胀只按既定 PoC 基数计算一次，通胀与可分发交易费分别按同一旧期比例分流；每类原生部分为 `floor(amount * native_reward_bps / 10_000)`，PoC 部分各取补数。新准备及创世默认 `5000 bps`，通过治理指定未来 Epoch 生效；本补充不改写历史源码核对基线或测试记录。

## 1. 实现范围与源码差距

### 1.1 必须交付的行为

1. 用户原始算力经固定指数标准化后，按比例分配给已启用 PoC 的质押池；原始版本与算力分配采用各自的生效时点。
2. 根据池算力、原生保证金、参数和增长预算，生成下一 Epoch 的 BFT 权重；当期权重只读取已安装的 `ValidatorSet`。
3. 以当期权重固定计奖基数，通胀按当期治理比例分流至原生质押和 PoC 金库。原生部分沿用份额、佣金、锁仓及复投；费用同比分流后，PoC 的通胀和费用份额按用户标准化算力分配。
4. 同步换届、普通 DKG、Chunky DKG、超时及治理强制结束共享同一个计划构建与提交实现。
5. 不合格目标返回 `Deferred`，保留旧委员会与修复能力；冻结后只提交原计划。
6. 支持全新创世及原生模式下首次准备 PoC，覆盖准备期、最后一期原生奖励和首次 PoC Epoch；开发阶段不承接旧版 PoC 状态。

MVP 保留池级共享保证金、零 PoC 运营佣金、最多两条待生效变更和池级奖励余数不结转。个人保证金关系、第三条未来变更、自动重基准、全用户扫描、独立奖励金库资源、`state_hash`、治理算力投票与新的 quorum 算法均不属于本次实现。

### 1.2 当前源码已经具备什么

以下结论来自当前分支的静态源码核对，未以编译或链上部署结果代替验证。

| 位置 / 符号 | 当前行为 | 本次接入要求 |
| --- | --- | --- |
| `sources/poc/poc_power_store.move` | 已有 `PowerStore`、两槽 `UserPowerInfo`、含 `power / units` 的 `PowerVersion` 和 `PeriodClock` | 在现有模块上接入直接写入的标准化版本及同步钩子，不重新实现一套上传服务 |
| `stage_batch_update` / `will_insert_version` / `save_power_versions` | 外层统一判断同周期首写和新用户零值；统一写入口校验顺序并保存完整双槽 | 构造统一算力版本并同步账本，再写入用户双槽；保留重复上报语义，整批原子提交 |
| `commit_next_period_if_boundary` | 提供局部计数和周期倒计时，但当前框架源码中没有调用点 | 接到每次成功换届，补齐绝对 Epoch 映射与创世调用；不能把注释中的调用关系当成现状 |
| 保留比例 | 实际常量是 `9995`，部分说明文字仍写 `9950` | 使用实际配置；建立基线后禁止修改，并修正相关说明。不能直接把默认值当成部署批准值 |
| `friend topo_framework::staking_registry` | 当前源码搜索未发现对应模块定义 | 在首次框架编译前核实历史依赖并处理无效声明；不能混同于面向应用的 `poc_registry` |
| `stake::on_new_epoch` | 结算原生奖励、处理本金、消费 PVS 或实时选举、更新索引 | 拆出旧期结算与计划提交，PoC 分支不再实时重选 |
| `next_validator_consensus_infos_v2` | 按原生本金及模拟奖励生成 PVS；缓存没有目标 Epoch 字段；含空集合回退 | 增加 PoC 计划构建路径及成对校验；PoC 不调用代币权重回退 |
| `reconfiguration::reconfigure` | 先设置重配置状态，再调用 `stake::on_new_epoch` | 在冻结和任何换届状态修改前执行预检 |
| `reconfiguration_with_dkg::finish` | 先清理会话、应用缓冲配置，再调用重配置 | 改为先校验计划、按旧上下文结奖，再应用新配置 |
| `increase_lockup_with_cap` | 当前没有重配置冻结检查 | 在能力入口补齐检查，覆盖所有转调者 |
| `staking_config`、`config_buffer`、`std::features` | 设置路径没有统一的 PoC 冻结约束 | 增加设置侧防护与组合校验，并区分设置入口和合法提交入口 |
| `delegation_pool::get_add_stake_fee` | 直接读取实时原生奖励率 | 最后一期原生仍用旧上下文；PoC Epoch 依据固定基数、费用开关与限额、已安装分流比例及有效本金估算原生份额收益 |
| `topo_governance::get_voting_power` | 允许成员变化时读代币余额；禁止变化时回退到当前共识权重 | PoC 下两个分支都必须保持代币口径，特别覆盖受控静态委员会 |
| DKG 舍入 | 普通与 Chunky DKG 复用的代码以 `u64` 累加输入权重 | 在 Move 侧验证实际入选总权重，不按候选容量限制单池配置上限 |
| 缓存包生成 | 当前存在独立 `update-cached-packages` 命令及脚本 | 修改 Move 后实际重新生成 bundle，并执行仓库要求的缓存包构建 |

源码入口见第 18 节。开始实现时记录新的提交号并复核此表，尤其是所有 `public`、`friend`、`*_with_cap` 与治理转调路径。

### 1.3 本文补充的工程选择

以下是使设计能够落地的实现细化，不改变权重公式或奖励归属：

- 当前处于开发阶段，使用全新布局一次性初始化 PoC 算力存储，不支持旧版算力迁移或旧资源布局升级。标准化版本在创世写入或上传时直接计算。
- `PowerParams`、部署上限和账本全局 Epoch 放在 `poc_accounting` 的新全局资源中；`stake` 保存计划、计奖上下文和自主退出来源。
- 奖励分流配置及已安装比例放在 `poc_reward_split` 资源中，准备时一次性创建，默认 `5000`。准备后缺失配置即为状态错误，不回退到 `0`、跳过安装或延迟补建。
- 应用身份批准表直接存入 `poc_registry::Registry`，创世时一并创建；不保留独立 `IdentityApprovals` 资源和运行期补初始化入口。算力查询统一使用 `get_user_committed_power`，奖励金额统一由 `split_reward` 分流，删除同义旧接口。
- 采用“只读构建 → 冻结 → 结算 → 安装”四段接口；业务不合格用结果值表示，状态损坏用 abort 表示。
- 对 `std::features` 使用模块内部的冻结资源与不可复制令牌，解决标准库不能反向依赖框架的问题，详见第 11 节。
- 对准备期尚未安装 PoC 的原生路径保留原生选举，但准备状态的 Epoch 与周期仍随成功换届推进；首次 PoC 目标才使用初始化权重例外。

实现涉及的共识权重、框架与标准库改动须按仓库规则进行后续代码审查。本文只生成实施规格，不修改这些实现。

## 2. 参数、单位与部署清单

### 展示单位与底层计量

算力展示统一使用 `OHMP`（One Hundred Million Power，亿算力）：`1 OHMP = 100,000,000 power`。OHMP 与 TOPO 的展示精度均为 8 位小数；`1 TOPO = 100,000,000 Octa`。完整定义见设计稿的[算力与代币单位](POC_CONSENSUS_V2_MINIMAL_POWER_REWARD_DESIGN.md#算力与代币单位)。

| 数量 | 底层计量 | 展示规则 |
| --- | --- | --- |
| 原始算力、池算力、已安装 PoC 权重及其门槛 | 整数 `power` | 按 `100,000,000 power / OHMP` 转成 OHMP，最多 8 位小数 |
| `Position.units`、`PoolLedger.units`、版本 `units` | 标准化算力单位 | 不直接标为 OHMP；先依据目标周期指数还原算力，生效权重则读取已安装集合 |
| 保证金、计奖基数、奖励与交易费 | 整数 `Octa` | 按 `100,000,000 Octa / TOPO` 转成 TOPO |

保证金参数统一为 `bond_octa_per_ohmp`（Octa/OHMP），算力换算分母固定为 `POWER_PER_OHMP = 100,000,000`，通过 `poc_accounting::power_per_ohmp()` 读取；部署配置不再包含可变的换算分母。`reward_base_octa` 和 `pool_reward_base_octa()` 明确使用 Octa。开发阶段直接采用新字段与 BCS 结构，不保留旧版兼容层；`units` 的缩放精度为 `2^16`，`index` 基准为 `2^64`；已有旧精度状态须重建创世，不能按新精度直接读取。

查询展示和输入解析使用十进制定点或大整数，不能先转浮点数，也不能将 `power / 100_000_000` 当作丢弃余数的整数除法。若工具提供 OHMP 输入，最多接受 8 位小数，精确换算成 `power` 并检查对应整数范围后再调用原接口；既有 JSON/BCS 配置继续填写整数 `power`，不直接填写 OHMP 小数。例如 `1 power` 显示为 `0.00000001 OHMP`，`250000000 power` 显示为 `2.5 OHMP`。

### 2.1 固定记账常量

| 名称 | 类型 / 值 | 使用规则 |
| --- | --- | --- |
| `BPS_DENOMINATOR` | `u64 = 10_000` | 只用于分配比例和保留比例；增长预算的分母仍为 `100` |
| `POWER_PER_OHMP` | `u64 = 100,000,000` | 每 1 OHMP 对应的整数 power 数，用于保证金与奖励金额换算 |
| `UNIT_SCALE` | `u128 = 2^16` | 版本标准化精度 |
| `INDEX_SCALE` | `u128 = 2^64` | 相对周期 `0` 的共同指数 |
| `MIN_PERIOD_INDEX` | `u128 = 2^24` | 接受版本和推进周期的指数下界 |
| `MAX_RAW_POWER` | `u64::MAX` | 单版本原始算力上限 |
| `MAX_POOL_UNITS` | `u128 = 2^120` | 当前和未来每个时点的池总量上限 |
| `Q` | `u256 = 2^128` | 用户权益与累计奖励指数精度；不能先以 `u128` 构造 |
| `MAX_TOTAL_POWER` | `u64::MAX` | 最终委员会总权重上限 |

采用 `2^16` units 精度以扩大共同指数的可用范围：周期 0 时，`1 power` 的 `1 bps` 分配从 `6.5536 units` 向下取整为 `6 units`，接受该极小份额约 8.45% 的表示误差；正常 OHMP 级算力的相对误差远小于此。TOPO 的 8 位小数与奖励精度 `Q = 2^128` 保持不变。默认 `9995` 保留比例、每周期 60 个 Epoch、每 Epoch 2 小时下，指数数值边界约为 759 年；这仍是有限精度的边界。

乘法、时间相加、增减汇总和限幅在足够宽的整数中完成，再检查范围并转换为存储类型。不能以最终 `max_power` 限幅为理由，提前把池算力或保证金总量转为 `u64`。

### 2.2 必须具备具体值的部署参数

| 参数 | 固定 / 可更新 | 部署及更新检查 |
| --- | --- | --- |
| `retention_bps` | 从标准化准备开始固定 | `0 < retention_bps <= 10_000`；指数期限从准备时起消耗 |
| 周期长度 | 可更新下一周期长度 | 正数；以 `u128` 校验 `B + new_length <= u64::MAX`；不能改当前剩余倒计时或已经排定的 `B` |
| `bond_octa_per_ohmp` | 最早下一 Epoch 生效 | 每 1 OHMP 所需的 Octa 数，必须为正；按实际最终权重计算 `reward_base_octa` |
| `min_power` / `max_power` | 最早下一 Epoch 生效 | 整数 `power`，`0 < min_power <= max_power`，不填写 OHMP 小数 |
| `min_validators` | 最早下一 Epoch 生效 | 不超过协议及实际支持的候选上限；动态换员时严格小于 `V_LIMIT`；开放模式至少为 `4` |
| `increase_limit` | 沿用原生配置 | `0 < increase_limit <= 50`，动态替换时满足组合约束 |
| `deployment_mode` | 启用前确定，之后固定 | 受控白名单或开放部署；开放模式不能关闭集中度校验 |
| `MAX_ALLOCATIONS` / 单次领取池数 / 上传批次上限 | 在部署与成本测试中确定 | 限制实际读写集；示例不提供默认生产值 |
| 实际支持的候选上限 `V_LIMIT` | 成本验收后确定 | 不超过 `MAX_VALIDATOR_SET_SIZE`，限制加入与取消退出等入口 |
| `fee_max` | 合约默认，治理可调整 | 仅限制交易费分发；通胀奖励沿用原生奖励率，不另设金额上限 |
| 指数及金库预警阈值 | 部署清单固定 | 明确负责人及升级窗口，预警先于数值边界 |

联合校验使用 `u256`：

```text
dynamic_membership => floor(min_validators * min_power * increase_limit / 100) >= min_power
dynamic_membership => min_validators < V_LIMIT
0 < sum(actual_selected_power) <= MAX_TOTAL_POWER  // 换届预检
floor(actual_power * bond_octa_per_ohmp / POWER_PER_OHMP) <= u64::MAX  // 实际金额窄化
```

当前源码 `MAX_VALIDATOR_SET_SIZE = 65536` 只限制人数。`max_power` 默认取 `u64::MAX`，不按协议人数或候选容量分摊；实际总权重超出 DKG 的 `u64` 范围时延期换届，不截断总和。工程前提为实际代币总量远低于 `u64::MAX`，业务测试使用发行规模内的金额，不构造代币总量超过 `u64` 的场景。治理可调整保证金比例，故权重的实际总和仍需独立检查。

当前参数、待生效参数和拟替换的原生参数要按时间组合校验。例如修改增长比例时，同时验证当前及待生效的 `PowerParams`；修改 PoC 参数时，由上层传入真实的原生增长比例。启用动态成员变更时也须验证这些组合约束。最终预检再验证目标 Epoch 的完整组合。只在设置入口分别验证字段范围是不够的。

`min_validators < V_LIMIT` 为最低人数下的替补申请预留至少一个名额，沿用先加入、再退出的既有入口。若两者相等，先加入会超过容量，先退出又会低于最低人数；MVP 拒绝这种动态配置，不新增原子替换入口。

### 2.3 数值校验的可复现样例

以下仅验证整数公式，不构成部署建议：

| 场景 | 计算结果 |
| --- | --- |
| `retention_bps = 9900` | 最大有效相对周期为 `2758`，`I[2758] = 16896047`；`I[2759] = 16727086 < 2^24` |
| 当前源码默认 `9995` | 同组常量下最大有效相对周期为 `55437`；这是当前指数表示的数值边界，不是配置期限 |
| `I = floor(2^64 * 9000 / 10000)` | `I = 16602069666338596454` |
| 上述指数下 `raw_power = 100`，全额分配 | `version_units = 7281777`，整数 `pool_power = 99` |

原始值、标准化单位、共识整数权重与代币最小单位必须在事件和查询结果中分别命名，不共用一个含义随模式变化的 `power` 展示字段。

## 3. 模块边界与文件计划

### 3.1 状态所有权

| 模块 | 唯一职责 | 允许读取 / 调用的上游信息 |
| --- | --- | --- |
| `poc_power_store` | 上传权限、双版本原始数据、周期时钟及派生版本 | 调用 `poc_accounting` 同步；不读取用户质押本金 |
| `poc_accounting`（新增） | 用户配置、持仓、池聚合、检查点、奖励资产及 PoC 参数 | 接收可信入口传入的版本、Epoch、参数；通过 `reconfiguration_state` 读冻结状态 |
| `poc_reward_split`（2026-09-11 新增） | 原生奖励占比、可选待生效值与已安装 Epoch 快照 | `stake` 授权排期、撤销及安装；冻结期间拒绝配置写入 |
| `poc_allocation`（新增） | 用户分配与领取、准备管理入口、查询拼装 | 可读 `stake`、`poc_power_store`、`poc_accounting`；不重复持有账本 |
| `stake` | 资格与保证金推算、权重构建、原生资产处理、奖励铸造与 Epoch 安装 | 可读算力存储与账本，保持 mint capability 的原有归属 |
| `reconfiguration` / `reconfiguration_with_dkg` | 驱动预检、缓存、会话及提交状态机 | 通过 `stake` 使用计划，不自行重算权重 |
| `reconfiguration_state` | 重配置冻结及起始时间 | 不查询 `stake` 或 PoC 账本 |

依赖保持设计中的方向：`poc_allocation → stake / poc_power_store / poc_accounting`，`stake → poc_power_store / poc_accounting`，`poc_power_store → poc_accounting`。账本不反查上述模块，也不调用 `reconfiguration::current_epoch`。

`staking_config` 可调用账本提供的纯参数校验接口，但账本不能反向导入 `staking_config`。PoC 参数管理入口由上层收集原生参数后传入账本。提交时应用参数的受信内部函数与外部设置入口分开，避免冻结检查阻止正常提交。

### 3.2 文件级任务

下表路径以 `aptos-move/framework/` 为根；新模块的同名 `.spec.move` 或规格块随实际证明覆盖补齐。

| 文件 | 改动内容 |
| --- | --- |
| `topo-framework/sources/poc/poc_accounting.move`（新增） | 本文第 4、6、7 节的核心账本与参数约束 |
| `topo-framework/sources/poc/poc_allocation.move`（新增） | 参数化用户入口、管理入口、查询与事件 |
| `topo-framework/sources/poc/poc_power_store.move` | 标准化版本、指数、直接初始化、版本同步、冻结和越界检查 |
| `topo-framework/sources/stake.move` | 计划、上下文、选举、结算、退出取消及相关入口分支 |
| `topo-framework/sources/reconfiguration*.move` | 统一预检与提交驱动，保留 VM 与治理调用的重配置入口 |
| `topo-framework/sources/block.move` | 所有 block prologue 变体处理 `Deferred`，保留旧期统计更新 |
| `topo-framework/sources/configs/staking_config.move` | 原生设置入口冻结及联合参数校验 |
| `topo-framework/sources/configs/config_buffer.move` 及实际配置模块 | 冻结缓冲替换；保留合法的会话结果写入和提交提取路径 |
| `move-stdlib/sources/configs/features.move` | 标准库内冻结资源与令牌接口，无新增业务 feature flag |
| `topo-framework/sources/delegation_pool.move` | 依据已安装上下文决定入池费，保留历史份额与佣金 |
| `topo-framework/sources/topo_governance.move` | 治理重配置失败回滚；PoC 下静态委员会仍使用原生代币治理权重 |
| `topo-framework/sources/genesis.move` | 创世标准化基线、首次上下文与委员会初始化 |
| `topo-framework/tests/poc_*.move`（新增） | 账本、算术、成员、重配置和算力版本测试 |
| `cached-packages/src/head.mrb` 及实际生成的 SDK 文件 | 与 Move 源码同步生成并审查 |

Rust 侧原则上保留 `ValidatorSet`、`EpochState` 和协议消息布局。新增 Rust 工作主要是 E2E、DKG 边界及节点恢复测试；若发现必须修改共识或密码实现，单独提交设计与审查，不能以本实施文档推定这些代码已获修改批准。

## 4. 存储布局与初始化契约

### 4.1 保留设计中的账本结构

`UserAllocation`、`PoolRatio`、`AllocationChange`、`Position`、`PositionChange`、`PoolChange`、`Checkpoint` 和 `PoolLedger` 按设计第 4 节实现，字段名与单位保持一致。以下补充全局容器的逻辑布局：

```move
// 以下是拟新增结构草图；Option 的 import、构造器和访问器省略。
struct AccountingState has key {
    epoch: u64,                         // 绝对链 Epoch
    pools: Table<address, PoolLedger>,
    config: PoCConfig,
}

struct PoCConfig has store {
    params: PowerParams,
    pending_params: Option<PendingPowerParams>,
    activation_epoch: Option<u64>,
    first_poc_epoch: Option<u64>,       // 首次成功安装时写定
    deployment_mode: u8,
    limits: DeploymentLimits,
}

struct PendingPowerParams has store {
    epoch: u64,
    params: PowerParams,
}

struct DeploymentLimits has copy, drop, store {
    max_allocations: u64,
    max_claim_pools: u64,
    max_upload_users: u64,
    validator_limit: u64,
    fee_max: u64,
}
```

参数容器属于框架地址；不为每个池保存重复的部署模式或奖励率。`MAX_ALLOCATIONS` 等实现为协议常量还是部署固定字段，可以在编码时统一，但不能留下两个不同的权威值。

### 4.2 统一算力存储

原始查询和分配账本共用 `PowerStore.users`。每个版本同时保存 `power` 与 `units`；算力表和周期时钟一次性创建，保留比例自初始化起固定，不提供后续修改入口。

```move
struct PowerStore has key {
    operator: address,
    users: Table<address, UserPowerInfo>,
    retention_bps_per_period: u64,
    current_index: u128,
}

struct PowerVersion has copy, drop, store {
    effective_period: u64,              // 源周期编号
    power: u64,
    units: u128,
}

struct UserPowerInfo has copy, drop, store {
    older: Option<PowerVersion>,
    newer: Option<PowerVersion>,
}
```

`PowerStore` 存在即表示标准化字段与时钟已初始化，不再保存可选状态或空表标记。初始化前不能写入算力版本；所有已写入版本的 `units` 均通过标准化公式计算。原生链尚未初始化 PoC 时不创建算力资源，也不推进独立的原始算力时钟。

版本仅在创世写入或上传算力时计算 `units`。无记录用户的只读快照返回零，不创建空记录；新用户上报零值仍不建记录。`Option` 明确区分空槽与有效零版本。当前版本可以长期不更新，不重新绑定指数；下一版本最多指向下一源周期。下一指数按需由当前指数和部署参数计算；计算结果为 `none` 表示支持期限边界，不允许接受超期版本。

新增版本时先在局部构造完整双槽并同步持仓，再一次写入 `PowerStore.users`。统一写入口要求 `newer` 非空，且存在 `older` 时其生效周期严格小于 `newer`；任何一步失败，整笔事务回滚。原始查询与标准化快照共用有效版本选择，分别读取 `power` 和 `units`，保留各自的衰减与取整规则。

### 4.3 `stake` 的新状态

- `InstalledRewardContext { context: RewardContext } has key`：包装设计中的 `RewardContext`，供全局持久化；内部上下文本身仍为 `copy, drop, store`。
- `poc_reward_split` 的独立资源：保存与 `InstalledRewardContext` 同 Epoch 的比例快照。治理排期最早下一 Epoch，未冻结可替换或撤销，结算仅读取旧快照。
- `VoluntaryLeaves { requests: Table<address, u64> } has key`：值为自主退出申请的绝对 Epoch；条目只对应本届待退出成员。
- `EpochPlan { data: EpochPlanData, feature_token: FeatureFreezeToken, stage: u8 } has key`：`data` 保存目标 Epoch、周期与指数、截止时间、模式、参数、旧奖励上下文和池目标；令牌承载第 11.2 节的标准库冻结权限，阶段限制结算、安装和解冻的顺序。

`PrecomputedValidatorSet` 唯一保存冻结的目标委员会和原生回退标记。`EpochPlan` 不再保存委员会副本；冻结后的 `EpochPreview` 查询由计划数据和 PVS 组装。目标 Epoch 由成对存在的 `EpochPlan.data.epoch` 校验；构建、缓存、读取、消费 PVS 的 PoC 路径必须全部经由同一组 `stake` 内部接口。计划与 PVS 在同次构建中生成，禁止外部自行拼装 `PoolTarget` 或验证者配置。

### 4.4 创建时的值与生命周期

| 对象 | 初值 / 生命周期约束 |
| --- | --- |
| `UserAllocation` | 用户首次分配时由本人 signer 创建；`active` 空、`pending` 空、`positions` 空。不因原始上报伪造用户 signer |
| `Position` | 新建时 `units = 0`、`changes = []`、`cursor = pool.index`、`accrued = 0`；历史记录再次使用时先结算，不覆盖其未领权益 |
| `PoolLedger` | 经上层确认池已注册后创建；`epoch = 当前绝对 Epoch`、`units = 0`、`index = 0`、`reward_base_octa = 0`、零金库 |
| `reward_epoch` | 活链初始化水位不高于当前 Epoch 的前一期；创世可用 `0` 哨兵。以后仅奖励入账推进，安装目标基数不能把目标 Epoch 标为已结算 |
| `PoolChange` | 只为实际持仓单位变化创建；`refs` 是该时点持仓变更条数，净变化为零也可非零 |
| `Checkpoint` | 生效时由 `PoolChange.refs` 初始化；逐个持仓结算递减，归零后删除 |
| 退出池 | 保留账本、金库、用户历史持仓和检查点；不进入全网历史池扫描 |

`PoolLedger.epoch` 表示已应用变更的账本 Epoch，`reward_epoch` 是奖励防重复水位，两者用途不同。`reward_base_octa = 0` 不能独自用来判断是否入选：极小权重可能得到零整数计奖基数，成员资格仍以 `ValidatorSet` 为准。

## 5. 接口与权限契约

### 5.1 用户及管理入口

| 拟新增 / 修改接口 | 调用者与输入 | 成功后的效果 | 冻结期间 |
| --- | --- | --- | --- |
| `poc_allocation::set_allocations(user, pools, bps)` | 本人 signer，等长地址与比例向量 | 下一 Epoch 的配置；原子重建相关池 `E+1`、`B` 变更 | 拒绝 |
| `poc_allocation::claim_rewards(user, pools)` | 本人 signer，去重且数量受限的池列表 | 先推进指定池到当前 Epoch，再结算并领取持仓奖励到本人账户；保留分数余量 | 允许 |
| `poc_allocation::prepare_poc(framework, manifest, activation_epoch)` | 治理框架 signer | 初始化准备状态、旧期计奖上下文及标准化基线 | 拒绝 |
| `poc_allocation::enable_pool(framework, pool)` | MVP 默认由治理框架 signer 开放；池必须已注册 | 建立零余额账本，允许用户分配；不自动申请加入委员会 | 拒绝 |
| `poc_allocation::schedule_power_params(framework, params, epoch)` | 治理框架 signer；`epoch >= E+1` | 唯一一份待生效参数，覆盖前联合校验 | 拒绝 |
| `poc_allocation::cancel_pending_power_params(framework)` | 治理框架 signer | 撤销待生效参数，已安装参数不变 | 拒绝 |
| `poc_allocation::reschedule_activation(framework, epoch)` | 尚未首次启用的治理框架 signer | 修改计划启用 Epoch，不重置基线与周期 | 拒绝 |
| `poc_power_store::stage_batch_update` | 已有 operator 或框架权限 | 新增版本时同步写入原始算力、units 和已有分配 | 拒绝，包括重复上报请求 |
| `stake::cancel_leave_validator_set(operator, pool)` | 当前授权运营者 | 恢复本 Epoch 自主待退出成员 | 拒绝 |

`enable_pool` 的框架权限是本实施规格采用的最小准入入口；后续如开放 owner 自助启用，应另定义准入规则，不能直接暴露账本底层建池函数。`poc_registry` 管理贡献应用，不承担验证者池准入。

`set_allocations` 的空配置表示下一 Epoch 全部撤出。各地址唯一、`bps > 0`、总和不超过 `10_000`；显式 `bps = 0` 应拒绝，移除通过省略地址表达。不要求分配者拥有保证金或为目标池提供过本金。

`claim_rewards` 不使用待生效原始版本、不自动复投；若用户账户没有适用的代币接收存储，应沿用框架支持的注册 / 存入流程，存入失败整笔回滚。领取历史退出持仓不受当前算力分配并集限制，仅受本次指定池数量限制。

### 5.2 模块间接口

接口以契约为主，最终 Move 参数可采用下层定义的瞬时快照类型，避免 `poc_accounting` 导入 `poc_power_store` 的类型。

| 所属模块 / 接口 | 输入与输出 | 必须保证 |
| --- | --- | --- |
| `poc_power_store::get_accounting_snapshot(user)` | 当前 / 下一周期的标准化版本值、当前周期、绝对 `B` | 无记录时返回零；无未来版本时沿用当前 `units`，不重新衰减 |
| `poc_accounting::replace_allocation(...)` | 本人 signer、比例、版本快照、Epoch | 完成整个事务级重建流程 |
| `poc_accounting::sync_power_versions(...)` | 用户地址、新旧版本必要信息、Epoch、`B` | 仅同步已存在的用户配置；无配置用户的标准化记录由算力存储维护 |
| `poc_accounting::preview_pool_units(pool, target_epoch)` | 只读推算 `u128` | 不写检查点、不推进账本、不消耗引用 |
| `poc_accounting::advance_pool(ledger, epoch)`（私有） | 用户访问时由内部调用者传入账本全局 Epoch | 处理退出池的成熟变更；用户访问不能越过已安装 Epoch |
| `poc_accounting::credit_epoch_reward(pool, closing_epoch, reward)` | `Coin<TopoCoin>`、明确旧期编号 | 只在 `stake` 合法提交中入账；只读 claim 接口不可使用 |
| `poc_accounting::install_pool_target(...)` | 目标 Epoch、目标 units、计奖基数 | 到期聚合结果必须等于预检值；不把新 Epoch 标为已结奖 |
| `stake::preview_epoch_transition(...)` | 目标 Epoch、截止时间、可选拟成员变动 | 返回可提交预览或具体延期原因；零持久化写入 |
| `stake::cache_epoch_plan(...)` | 同一次构建的计划与目标集合 | 成对创建资源，并取得冻结令牌 |
| `stake::settle_closing_epoch(...)` | 已确认有效的计划 | 只结算旧委员会，旧上下文和旧索引 |
| `stake::install_epoch_plan(...)` | 计划及同批目标集合 | 不重选委员会；验证应用后聚合量及最终总权重 |
| `stake::get_installed_reward_context()` | 全局已安装上下文 | 准备前使用原生路径；准备后缺失是状态错误 |

底层改变余额、版本、Epoch 或参数的函数采用可信框架调用权限；普通入口不得允许用户指定伪造的 Epoch、标准化单位、`reward_base_octa` 或奖励币。即使采用统一 `friend` 列表，也必须逐个审查这些 friend 的对外转调接口。

### 5.3 只读查询

至少提供以下结果，所有金额注明最小单位：

- 配置：已安装模式、当前参数、待生效参数、首次启用 Epoch、支持期限及剩余周期。
- 用户：逻辑生效分配、待生效分配、指定持仓的逻辑当前 units、最多两条变更、已入账可领金额及分数余量。
- 池：逻辑当前 units、下一 Epoch units、候选权重、已安装共识权重、计奖基数、金库余额。
- 换届：只读预检结果、未通过约束、目标人数和总权重；若已冻结，查询返回缓存目标及截止时间，不能伪装成实时重选。

可领取查询可以在内存中模拟检查点结算，但不能扣减 `refs`。某些既有 `#[view]` 会同步原生委托记录，不能据此让新增 PoC 只读预检产生状态写入。RPC 查询结果不是下一次交易的承诺，写事务必须重新验证。

## 6. 周期时钟、原始版本与分配重建

### 6.1 对齐当前倒计时语义

设已安装绝对 Epoch 为 `E`，`PeriodClock.epochs_until_next_power_period = r`。当前实现先判断 `r == 0` 是否切换周期，再在每次成功提交末尾减一。因此在该语义下：

```text
B = E + r + 1
target_period(E+1) = current_period + (r == 0 ? 1 : 0)
```

不能直接写成 `B = E + r`。所有相加先检查 `u64` 上界。示例：周期长度为 `60`，创世安装 Epoch `1` 时完成一次时钟提交，状态为周期 `0`、`r = 59`；Epoch `60` 为 `r = 0`；成功安装 Epoch `61` 才进入周期 `1`。

初始化同时创建时钟，将 `last_epoch` 设为当前绝对链 Epoch；算力周期从 0 起算。之后断言：

```text
clock.last_epoch == accounting.epoch
relative_period = clock.current_period
```

PoC 创世从绝对 Epoch 0 和算力周期 0 开始；运行期准备则从当时的绝对 Epoch 和算力周期 0 开始。初始化只执行一次，不能通过重新创建资源重置衰减率或指数。

`EpochPlan.data.period`、时钟快照中的 `target_period` 与衰减公式 `I[p]` 使用相同周期编号。`get_normalization_clock()` 返回当前周期、下一边界 Epoch、当前指数和可选下一指数四项。

周期长度设置仅修改下次切换时加载的长度。`Deferred`、DKG 启动、重复启动、领奖和墙上时间流逝均不调用时钟提交。成功安装 Epoch 时只调用一次；创世调用和普通换届调用分开测试，避免双推进。

设置未来周期长度时，先由当前状态取得已固定的 `B`，以 `u128` 校验 `new_length > 0` 且 `B + new_length <= u64::MAX`，通过后才写入长度；失败不得改变旧长度或倒计时。初始化 / 准备同样校验当前边界和下一次加载长度后的边界；这些 `u64` 周期量的相加及常数倍运算可由 `u128` 容纳。换届预检须完整预览目标时钟，包括周期切换后重新加载的倒计时及其下一边界，在缓存计划和冻结前确认可表示，不能等提交时才发现溢出。算力和奖励的复杂乘积继续使用 `u256`。

### 6.2 标准化计算

```text
index_at_next_period = floor(current_index * retention_bps / 10000)
version_units = floor(raw_power * UNIT_SCALE * INDEX_SCALE / effective_index)
position_units = floor(version_units * allocation_bps / 10000)
pool_power = floor(pool_units * target_index / (UNIT_SCALE * INDEX_SCALE))
```

在 `u256` 中计算后检查版本 `< 2^120`、持仓值可存入 `u128`。存量版本未更新时，持仓 units 跨周期不变，只改变换届权重计算所用的共同指数；不为统一衰减创建用户变更。

指数只从当前值递推一次；版本绑定后不查历史指数表。不设置部署周期上限；下一指数低于数值下界或周期编号溢出时，拒绝写入该周期版本。当前实现到达数值边界后仍无法安装后续 PoC Epoch，长期持续运行需要升级指数表示或重基准机制；历史领奖继续有效。

### 6.3 上传入口的执行顺序

`stage_batch_update` 保留授权与首次写入语义，新增如下事务内步骤：

1. 验证冻结状态、输入长度、上传批次上限和 `target_period == current_period + 1`。
2. 逐用户判断同周期首写及新用户零值；重复目标周期不修改该用户的版本或持仓记录。
3. 由当前指数计算下一指数，再计算新增版本的 `units`，保留原当前版本并生成当前 / 下一周期快照。
4. 若用户已有 `UserAllocation`，执行第 6.4 节的重建算法；只遍历其配置与未生效持仓涉及的池。
5. 将完整双槽保存到唯一的用户表，发出实际新增事件。同一用户在批次中重复出现时，后续项看到前一项的写入，不重复同步。

批次中任意用户失败，之前用户的所有更改及事件一并回滚。新用户上报零值继续遵循当前“不新增”的行为；已有用户下一周期零算力是有效版本，必须撤销该周期的非零分配。`effective_period > 0, power = 0` 不能被当成空槽。

当前代码没有授权修正未来版本的入口，本 MVP 不增加一个绕过首写语义的修正接口。若后续确需修正，须另行落实权限和审核，并复用完整同步算法。

`set_genesis_committed_power` 增加真正的创世阶段约束，不能仅依赖可能尚未接入的 `last_epoch == 0`。删除 `set_legacy_stake_pool_power`；测试专用写入口不能存在于生产字节码。

### 6.4 两个时点的统一重建算法

分配替换与原始版本新增共享同一个重建核心，防止两个入口演化出不同的舍入或撤销规则。

先把已经生效的配置逻辑推进到 `E`。定义：

```text
S_old = 旧 active、旧 pending 及旧未生效变更涉及的池集合
S_new = 新 active、新 pending 及重建后未生效变更涉及的池集合
S_visit = S_old ∪ S_new
```

提交后 `|S_new| <= MAX_ALLOCATIONS`；旧配置此前也受同一约束，因此一次替换最多访问 `2 * MAX_ALLOCATIONS` 个池。历史零持仓及历史领奖记录不参加后续原始算力同步；不枚举 `positions` 整张 Table 来找到用户所有历史池。

```text
rebuild_user(user, new_ratios_or_unchanged, new_power_snapshot):
    assert not_frozen
    E, B = installed_epoch_and_boundary()
    promote_effective_allocation(user, E)
    determine S_visit and validate new configuration

    for pool in S_visit:
        advance_pool_to(E)                // 只处理已安装的历史状态
        settle_position_to_pool_index()   // 保留全部 accrued，不支付
        save old future position chain

    create wide local shadows for affected pool changes

    for pool in S_visit:
        previous = position.units
        for change in old future chain in epoch order:
            pool_shadow[change.epoch].remove_units -= previous
            pool_shadow[change.epoch].add_units -= change.units
            pool_shadow[change.epoch].refs -= 1
            previous = change.units

    for pool in S_visit:
        previous = position.units
        new_chain = []
        for t in unique_sorted(E+1, B):
            v = standardized_version_effective_at(t)
            ratio = allocation_effective_at(t, pool)
            next_units = floor(v.units * ratio / 10000)
            if next_units != previous:
                new_chain.push({ epoch: t, units: next_units })
                pool_shadow[t].remove_units += previous
                pool_shadow[t].add_units += next_units
                pool_shadow[t].refs += 1
                previous = next_units

    validate all final pool shadows and position chains
    persist configurations, position chains and pool aggregates
```

重建不能使用旧 `raw_power` 的整数衰减查询值；`v.units` 必须来自标准化版本。没有分配项时比例为零，没有未来原始版本时沿用当前版本的 units。

### 6.5 合并、容量与引用规则

| 情况 | 处理 |
| --- | --- |
| `E+1 == B` | 直接计算该时点的新版本与新比例的最终值，只存一条，不能先应用其中一项再记录两条 |
| 前后 units 相等 | 不创建持仓变更，不增加引用；配置本身仍可变化 |
| 用户之间净变化抵消 | 保留非零引用数和完整 `remove_units / add_units`，生效时必须有检查点 |
| 撤销后某时点 `refs == 0` | 断言该记录的 remove 与 add 也为零，再删除池变更 |
| 覆盖回 active 比例 | 重新计算两个时点；未来原始算力版本仍可能需要保留 `B` 变更 |
| 旧 pending 已生效但用户没操作 | 先通过检查点结算并提升配置，再定义新的两个未来时点 |

对每个受影响池，将所有撤销和新记录汇总完毕后再检查最终状态：

```text
u = logical_pool_units(E)
assert u <= MAX_POOL_UNITS
for t in sorted future boundaries:
    assert remove_units[t] <= u
    assert refs[t] <= u64::MAX
    assert remove_units[t] <= MAX_POOL_UNITS
    assert add_units[t] <= MAX_POOL_UNITS
    u = u - remove_units[t] + add_units[t]
    assert u <= MAX_POOL_UNITS
assert at most two future boundaries
```

移除旧记录后出现的临时预测总量不是最终配置，不能提前按业务容量拒绝。用局部宽整数影子完成整个替换，再进行范围转换和写回，避免合法替换因中间状态失败。任何下溢表明贡献记录与池聚合不一致，不能用饱和减法隐藏。

### 6.6 必须复现的时间表

下表省略共同精度，仅显示与设计示例等比例的 units。用户当前版本为 `100`，下一周期版本为 `200`，原分配 `50%`，新分配 `25%`：

| 时点 | 最终 units | 本用户对池聚合的贡献 |
| --- | --- | --- |
| `E` | `50` | 已含在当前总量 |
| `E+1 < B` | `25` | remove `50`、add `25`、refs `1` |
| `B` | `50` | remove `25`、add `50`、refs `1` |

若 `E+1 == B`，最终仍为 `50`，与当前值一致，因此本例根本不需要新的持仓变化或检查点；新配置与新原始版本仍正常生效。实现不能因为发生两种业务更新，就强制保留一条零变化记录。

## 7. 池账本推进、奖励检查点与领取

### 7.1 当前推进与目标预览分开

`preview_pool_units(pool, T)` 只读地从 `ledger.units` 和最多两条聚合记录推算到 `T`。它不修改 `ledger.epoch`、奖励指数或引用数，即使池已经退出多个 Epoch 也是如此。

用户访问中的 `advance_pool(ledger, installed_epoch)` 最多处理两个成熟时点；对于未被最近几次委员会提交访问的退出池，中间没有奖励入账，其历史检查点均可使用保持不变的指数。不通过遍历遗漏的 Epoch 补循环，也不另设无人调用的公开推进入口。

当期投票池已由最近一次成功提交推进到当前 Epoch。正常提交结算旧期奖励后，才应用目标 Epoch 的变更；不能把普通用户的“推进到当前”函数调用成“推进到计划目标”。冻结期间 claim 只允许前者。

### 7.2 到期池变更

```text
apply_mature_pool_change(pool, change):
    assert change.epoch <= allowed_installed_or_commit_epoch
    assert change.refs > 0
    assert no checkpoint already exists for change.epoch
    checkpoint[change.epoch] = { index: pool.index, refs: change.refs }
    pool.units = checked(pool.units - change.remove_units + change.add_units)
    remove only this pool change
```

生效边界检查点记录的是前一段算力已获得全部奖励后的指数。即使本期奖励为零或池总量没有净变化，也不能跳过具有引用的检查点。`PoolChange` 在应用后删除，其引用数转由 `Checkpoint` 承接。

### 7.3 持仓结算与提现

```text
settle_position(position, pool, E):
    assert pool.epoch == E
    for change in position.changes with epoch <= E:
        checkpoint = pool.checkpoints[change.epoch]
        assert checkpoint.index >= position.cursor
        position.accrued += position.units * (checkpoint.index - position.cursor)
        position.units = change.units
        position.cursor = checkpoint.index
        checkpoint.refs -= 1
        if checkpoint.refs == 0: delete checkpoint
        remove this position change

    assert pool.index >= position.cursor
    position.accrued += position.units * (pool.index - position.cursor)
    position.cursor = pool.index

claim(position, pool):
    advance_pool(pool, installed_epoch)
    settle_position(position, pool, installed_epoch)
    amount = floor(position.accrued / Q)
    assert amount <= value(pool.vault)
    position.accrued = position.accrued % Q
    transfer extract(pool.vault, amount) to the position owner
```

所有结算路径先把池推进到已安装 Epoch，再调用 settle；退出池由此惰性生成已成熟变更的检查点。冻结期间也允许这一步，但不能推进到计划的目标 Epoch。普通重建不做取整支付。用户长期不操作仍只需处理最多两条持仓变化；其间池可以累积很多其他用户引用的历史检查点，本次只访问自己的两个 key。

缺失检查点、负向指数差、引用下溢或不足额金库都属于状态错误。禁止以零奖励、跳过记录或重设 `cursor` 方式继续，否则会抹去用户权益或允许重复领取。

### 7.4 奖励入账

```text
credit_epoch_reward(pool, E, rewards):
    assert installed_context.epoch == E
    assert pool.epoch == E
    assert pool.reward_epoch < E
    R = value(rewards)
    U = pool.units
    if U == 0:
        assert installed_power == 0 && inflation == 0 && distributable_fee == 0
        assert R == 0
    else:
        pool.index += floor((R as u256) * Q / U)
    merge(pool.vault, rewards)
    pool.reward_epoch = E
```

`installed_power`、通胀和费用的关系由 `stake` 在受信调用前验证，账本不反向查询委员会；上面的断言表示跨模块契约。零奖励入账也推进防重复水位。只从 `stake` 接收合法奖励，不开放捐款、扫尾提款、运营者提取或残差回收入口。

### 7.5 数值证明与资产守恒

协议经济规格为 TOPO 最大发行总量 100 亿（`10^18 Octa`）、全网年通胀率严格低于 10%，须由发行机制保障。在该规格内，金库余额不超过总量，能由 `u64` 保存。年通胀率与每 Epoch 奖励率、质押 APY 分别计量。

账本不设置奖励期限 H。设单池历史累计入账为 `C`；领取后的代币可以作为交易费再次入账，故 `C` 可以超过发行总量乃至 `u64::MAX`。每池每个正 Epoch 至多入账一次，Epoch 与每次金额均为 `u64`，因此 `C <= (2^64 - 1)^2`。正池 units 至少为 1，每次指数增长不超过 `R * Q`，所以累计指数 `<= C * Q < 2^256`。

对于持仓 units 不变的某段，其每个计奖 Epoch 均有 `position.units <= pool.units`，因此：

```text
position.units * floor(R * Q / pool.units) <= R * Q
```

将本持仓各段相加，其累计权益不会超过该池累计入账乘 `Q`，仍小于 `2^256`；已支付金额扣除后界限更小。这才是 `units * (index - cursor)` 可由 `u256` 安全保存的依据，不能直接将 `2^120` 与一个无关的最大指数相乘。

每期未分配权益小于 `U / Q <= 1/256` 个最小代币单位；边界 `U = 2^120` 时仍严格小于 `1/256`。`R >= 1` 且 `U > 0` 时 `delta_index >= 256`，正奖励不会全部变成池级残差。残差停留在金库，不进入后续指数；个体 `accrued % Q` 则必须保留给原用户。

## 8. 目标委员会与 `EpochPlan` 构建

### 8.1 构建器输入

构建器由上层传入目标 `T = E+1` 和 `cutoff_secs`，读取已安装模式、目标配置、周期预览、原生余额、成员队列及验证者配置。未冻结时截止时间为当前链上秒时间；缓存后所有判断继续使用计划中的同一截止时间。

准备前不启用 PoC 构建器。准备后若 `T` 仍在原生模式，保留原生选举口径，并同步准备状态的 Epoch 与时钟；切换目标及之后的 Epoch 使用本节的 PoC 算法。已安装 PoC 后没有回退到原生模式的分支。

准备期的原生目标由原生构建分支生成，沿用其 PVS 规则，包括既有原生模式的回退语义；不能对代币权重套用本节的 PoC min_power、增长预算或集中度。新的提交管线仍携带一份计划和旧原生上下文：该分支的目标集合权重是原生单位，PoC 账本的目标 `reward_base_octa` 为零，只同步已存在账本的 units 与 Epoch。分支选择由已安装模式与冻结的激活时间共同确定，提交过程中不得改变。

`closing_rewards` 从 `InstalledRewardContext` 复制，要求其 Epoch 为 `E`。奖励率、费用开关与费用限额不从待生效设置反推。构建器不快照出块统计与费用余额，提交时仍读取累计到旧期结束的真实值。

### 8.2 遍历范围、顺序与索引

```text
current_voters = active_validators + pending_inactive
candidates = active_validators + reverse(pending_active)
targets = candidates + current pending_inactive pools not already included
```

当前 `stake::append` 使用 `pop_back`，所以待加入者的次序是反向；PoC 构建必须保持这个既有确定性顺序。不能无意改为正向或按地址排序。

`targets` 是本届投票池与下届候选池的并集，不包含全网注册池。预览阶段拒绝成员重复或不合法索引。新集合的索引按最终入选顺序重新从零编排，但这里只修改局部 `ValidatorInfo`；链上 `ValidatorConfig.validator_index` 要等旧期费用与统计读取完成后再更新。

候选容量与遍历容量分别度量：入口限制 `active + pending_active <= V_LIMIT`；本届 `active + pending_inactive` 同样不超过支持规模。带退出替补的 `targets` 并集可能接近 `2 * V_LIMIT`，成本测试必须覆盖这种情况，不能仅用最终入选人数估计读写成本。

### 8.3 保证金与资格预览

对候选池使用 `u256`：

```text
bond_octa = active + pending_active
if locked_until_secs > cutoff_secs:
    bond_octa += pending_inactive

units = preview_pool_units(pool, T)
relative_target_period = target_period
pool_power = floor(units * I[relative_target_period] / (UNIT_SCALE * INDEX_SCALE))
bond_cap_power = floor(bond_octa * POWER_PER_OHMP / bond_octa_per_ohmp)
candidate = min(pool_power, bond_cap_power, max_power)
```

`locked_until_secs == cutoff_secs` 已到期，不能计入 `pending_inactive`。已 `inactive` 的本金与 PoC 金库余额不计入。到期判断不得在 DKG 提交时改用新的墙上时间。

资格过滤要求：已注册、存在有效验证者配置、已启用 PoC、属于候选状态、`bond_octa >= 原生 minimum_stake`、`candidate >= min_power`。按原有入口保留申请加入及追加质押的 maximum stake 检查；不在每次选举中因超过 maximum stake 剔除池。

每份 PoC 计划只计入预检时已经存在的保证金，不能调用 `compute_simulated_validator_info` 把尚未结算的奖励加入担保额。首次切换的末期原生奖励与费用、以及后续 PoC Epoch 的原生通胀与费用分流部分，均从下一次构建起才可计入，不能改变本次冻结目标。

### 8.4 增长预算与入选

```text
if explicitly_genesis_or_first_poc_install:
    final_power[i] = candidate[i]
else:
    current_total = installed ValidatorSet.total_voting_power
    assert current_total matches sum(active + pending_inactive weights)
    if current_total == 0: return Deferred(ZERO_CURRENT_POWER)

    base[i] = installed power of current candidate, or 0 for a new joiner
    delta[i] = max(candidate[i] - base[i], 0)
    growth = sum(delta[i])
    budget = floor(current_total * increase_limit / 100)

    for eligible candidate i:
        if growth <= budget:
            final_power[i] = candidate[i]
        else:
            final_power[i] = min(candidate[i], base[i])
                + floor(delta[i] * budget / growth)

drop candidates with final_power < min_power
do not redistribute any unused or rounded budget
```

资格过滤在计算 `growth` 之前完成。旧总权重包含待退出成员，因为它们仍是当期投票者；新候选没有临时基础权重。`growth == 0` 自然进入第一分支，不能除零。

预算分配完成后线性累加最终总权重并验证：

- 最终人数至少为 `min_validators`，不超过协议和实际支持上限。
- `0 < sum(power) <= MAX_TOTAL_POWER`。
- 开放模式对每一入选池满足 `3 * power < sum(power)`；所有乘加使用宽整数。
- 目标指数和目标 Epoch 仍在整数表示范围内。
- 各池 `reward_base_octa = floor(power * bond_octa_per_ohmp / POWER_PER_OHMP)` 不超过部署上限。

不入选池的 `PoolTarget.power = 0`、`reward_base_octa = 0`，但保留其目标 units 以提交到期持仓。PoC 候选必须已有账本；首次切换时只参与旧原生结算、未启用 PoC 的池可以没有账本，上层明确跳过 PoC 安装，不能自动为它建账。

### 8.5 结果类型与失败分类

实现一个不携带资产、可安全丢弃的预览结果，例如：

```text
PreviewResult = Ready(plan_data, target_validator_set)
              | Deferred(reason, target_epoch, observed_count, observed_total)
```

仅 `Ready` 结果可转换成存储资源 `EpochPlan`。主动退出预检和只读查询使用可丢弃预览，不创建资源或冻结令牌。

| 失败类型 | 块触发 | 治理要求立即重配置 / 启动重配置 |
| --- | --- | --- |
| 最低人数不足、零总权重、集中度不合格、目标无法满足约束 | 返回 `Deferred`，本块正常继续 | abort 整笔治理事务，回滚该事务内的配置写入 |
| 用户写入超容量、参数组合非法、版本超期 | 在相应写入时拒绝；不等到 block prologue 暴露 | 同样原子拒绝 |
| 冻结计划缺失 / 不成对、Epoch 不匹配、检查点损坏、账本不变量失效 | 协议状态错误，拒绝提交 | 同样拒绝；不以实时状态修补目标 |

`first_poc_epoch` 记录首次成功安装的 PoC Epoch，并锁定此后的 PoC 模式；奖励不设置到期时间。算力指数仍须满足独立的数值下界，Epoch 递增不能超过 `u64` 的表示范围。

## 9. 旧期奖励与原生本金处理

### 9.1 拆分 `update_stake_pool`

将现有混合函数拆成以下内部职责，具体名字可沿用已有实现风格：

| 内部步骤 | 输入 | 输出 / 副作用 |
| --- | --- | --- |
| `settle_native_pool_reward` | 旧上下文、旧索引、旧原生余额 | 按原生 active / pending_inactive 分段公式发奖和分费 |
| `settle_poc_pool_reward` | 旧上下文及分流快照、旧索引、固定 reward_base_octa | 通胀计算一次，原生部分进入质押本金，PoC 部分及费用调用账本入账 |
| `apply_stake_transitions` | 池、计划截止时间 | 合并 pending_active；到期 pending_inactive 转 inactive |
| `install_validator_indices_and_fees` | 计划目标集合 | 旧费用已清空后重建新索引、统计和费用表 |

旧委员会的 `active_validators` 与 `pending_inactive` 都结奖；`pending_active` 没有本期验证者表现，不得用其临时索引领取本期奖励。待加入池仍需在安装前处理到期本金状态。

准备期最后一次原生结算保持原来的分别取整规则，不能把 active 和 pending_inactive 相加后统一取整。PoC Epoch 只对固定 `reward_base_octa` 计算一次通胀，再按治理占比分流；原生部分依据 `active / pending_inactive` 的有效本金比例入账，PoC 部分按 `units` 分配。`pending_active / inactive` 不分得当期通胀和费用，不再独立按实际质押额计算额外发行。

### 9.2 PoC 计奖公式

```text
success = old_performance.successful_proposals as u256
total = success + (old_performance.failed_proposals as u256)
if total == 0:
    inflation = 0
else:
    inflation = floor(reward_base_octa * rate_num * success / (rate_den * total))

fee = old_context.distribute_transaction_fee
      ? min(old_fee_balance, old_context.fee_limit_per_pool)
      : 0
native_inflation = floor(inflation * installed_native_reward_bps / 10_000)
native_fee = floor(fee * installed_native_reward_bps / 10_000)
native_reward = native_inflation + native_fee
poc_inflation = inflation - native_inflation
poc_fee = fee - native_fee
pool_reward = poc_inflation + poc_fee
```

原生通胀和费用分别用入账前本金计算 `floor(amount * pending_inactive / (active + pending_inactive))` 分给 `pending_inactive`，各自余额分给 `active`，再沿用原有份额、佣金和锁仓转换。`native_inflation + poc_inflation == inflation`、`native_fee + poc_fee == fee`，两路总入账等于 `inflation + fee`。PoC 佣金仍为零。

`rate_den > 0` 在配置与上下文安装时保证。先转宽再求总提案数，不能先执行两个 `u64` 的相加；奖励率、表现分子和基数乘法使用 `u256`。原源码中“一期最多一天”的 spec 假设不适用于长期 `Deferred`，必须更新证明前提及边界测试。

`RewardContext` 在准备时和每次安装时保存，旧期结算仅读取其分子、分母及费配置。与奖励有关的治理修改即使已经写入原生配置资源，也只影响下一份上下文。原生周期性奖励率下降在旧期结算后计算，再保存下一期上下文；不要求在 DKG 开始时预估完成时刻的新奖励率。

分流快照在同次安装写入，Epoch 必须匹配。`stake::schedule_reward_split(framework, bps, activation_epoch)` 校验 `0 <= bps <= 10_000` 和未来 Epoch；相同入口可替换待生效值，`stake::cancel_pending_reward_split` 清除待生效值，二者均受冻结保护。原生本金增加后会提高未来担保能力，但本次尚未结算的分流不写回已冻结目标。实际代币总量以 Octa 计量，在持续发行和费用结算后长期远低于 `u64::MAX`。因此预检和追加质押不再为旧期、下一期最大奖励额预留余额容量，也不重复扫描委员会计算这些上界；`fee_max` 与每池费用限额只是政策上限，不能当作真实余额导致换届延期。实际结算仍检查奖励转换、通胀加真实费用总额、有效本金及 `Coin` 合并，金库只按真实奖励入账。`get_native_reward_upper_bound` 为委托入池费保留，使用 `u128` 相加后封顶 `u64::MAX`；此前提下封顶值仍覆盖实际奖励，不改变实际分发、旧期快照或份额计算规则。

### 9.3 费用记录与长期延期

当前 `PendingTransactionFee` 按旧 `validator_index` 保存，`record_fee` 在等待中继续收到费用。结算时无论是否允许分发，都清理旧期费用记录；只把旧上下文允许的金额发到对应池，超过限额部分不进入任一路径。交易费的原有验证者归属、收取和销毁逻辑不因 PoC 分配而改变。

有限的 `fee_max` 约束的是最终分发额，不能据此声称当前无界 `Aggregator<u64>.add` 的累计过程也不会溢出。PoC 实现必须在费用记账入口处理该边界：可复用现有按索引容器，将可分发累计额保存为 `min(旧上下文限额, 已累计额 + 本次归属额)`，加法先使用宽整数；最终结果与旧期结束时限幅等价。原交易费事件仍记录真实费用，不把此限幅展示成少收费用。

若实现需要读取 Aggregator 才能完成限幅，应测量其对并行执行和费用写热点的影响，选择保持安全与性能预算的实现后再发布，不能用 epoch 末尾的 `min` 掩盖写入溢出。原生准备期使用原生结算；其累计费用与超长原生期也应在首次启用测试中检查。

单个提案计数器仍为既有 `u64` 字段，其递增边界需要单独验证；将奖励公式改为 `u256` 不自动扩大计数器存储容量。边界保护不得产生未经设计的表现比例变更。

### 9.4 安装目标后处理本金与费用

处理 pending_inactive 的截止时间来自计划，不重新取 DKG 完成时间。仍在任池的后续锁仓续期可沿用原生“从完成时当前时间开始”的规则，但不能反过来把在计划截止时已经到期的本金重新计入本届目标保证金。

所有旧池费用结算完成并确认旧表为空后，才写入新 `ValidatorConfig.validator_index`、新性能数组与新费用 key。不能通过在原函数中提前覆盖 ValidatorSet、再按新索引回查旧费用来简化提交。

`delegation_pool::get_add_stake_fee` 在准备后先读已安装上下文与分流快照：PoC Epoch 按固定计奖基数的最优通胀和当期可分发费用限额分别估算原生分流金额，再根据原生有效本金推算 active 份额净收益及入池费，佣金使用原生规则，不能将 `pending_active` 当作本期计奖本金，也不能直接套用原生 APY。原生 Epoch 保持旧奖励率及原入池费，准备前继续现有查询；分流为零时没有原生收益入池费。费用未收满时，按整期费用限额估算可能高于实际收益对应的入池费；奖励率为零而费用开启时，费用份额仍参与估算。历史份额、运营佣金、锁仓与提现所有权保留。

仅在 PoC 模式，若 `StakePool.pending_active > 0`，已经到期的佣金调整仍暂缓，直到成功换届清除待入池本金；同步流程先用旧佣金结算历史收益，再应用新佣金。该限制避免高佣金时零/低入池费追加的本金在同一延期 Epoch 的佣金下降后摊走旧收益；原生模式不改变原佣金生效规则。

## 10. 重配置驱动与原子提交

### 10.1 统一入口结构

保留现有对外函数签名，以内部返回结果的核心区分调用语义：

- 块触发使用 `try_*`：业务失败返回 `Deferred`；本块的时间、出块统计及费用仍属于旧 Epoch。
- 治理触发使用 `require_*`：同一核心返回失败时 abort，回滚本次配置写入。
- DKG 完成与强制结束使用 `finish_*`：有冻结计划就校验并消费该计划；没有计划先做同步预检。

`block_prologue`、`block_prologue_ext`、现有 V2 / V3 变体都要接入。保留 VM 调用的已有入口签名；内部结果处理不要求修改网络协议或 block metadata 布局。

### 10.2 未冻结时启动

```text
try_begin_transition(trigger):
    honor existing genesis / disabled / duplicate-event guards
    if frozen:
        validate matching plan and PVS
        return InProgress

    assert no orphan plan or PVS in the managed PoC path
    result = preview(E+1, now_seconds)
    if Deferred:
        return Deferred                         // 没有换届状态写入

    cache plan and PVS from the same result
    acquire feature freeze token
    on_reconfig_start()
    assert start_time_secs == plan.cutoff_secs

    if synchronous:
        commit_cached_transition()
    else:
        perform allowed stale-session cleanup
        start DKG with current dealers and PVS targets
        if Chunky DKG is used: start it with the same targets
```

同步路径可以在同一事务中暂存再消费这对资源，减少两种提交实现的差异。主动退出预检不调用此包装。

当前 `try_start` 在预计算前清理旧 Chunky 会话；应把清理挪到预检成功之后。冻结后重复调用不能重建 PVS、移动截止时间或开启第二份目标。若某种 VM 分发 / 本地 override 恢复要求清理旧会话，必须仍保持当前冻结计划与目标身份。

### 10.3 提交顺序

以下步骤必须处于同一 Move 事务。中间状态不对外可见，任何状态断言失败都整体回滚。

1. **校验**：计划与 PVS 成对、`plan.epoch == E+1`、`closing_rewards.epoch == E`、当前上下文与旧模式一致、冻结令牌存在；检查缓存是本次状态机创建的结果。
2. **旧期结算**：按旧委员会、旧索引、旧 units、旧计奖基数及 `closing_rewards`，结算通胀和费用。原生模式入原生池，PoC 模式入金库。
3. **检查点**：在第 2 步增长后的池指数处，为目标 Epoch 的到期变更建立检查点；退出历史池可在后续访问时惰性建立。
4. **本金和配置**：按 `cutoff_secs` 处理原生待处理本金；应用已缓冲配置和 PoC 到期参数；旧期结奖完成后处理奖励率下降。
5. **周期**：成功提交只推进一次 `PeriodClock`；周期边界才切换指数与源周期，实际结果必须匹配计划预览。
6. **池目标**：执行到期聚合的先减后加，核对实际 units 等于 `PoolTarget.units`；写入新计奖基数，退出 / 被剔除池为零，保留未来变更。
7. **委员会与上下文**：安装 PVS 的最终集合；重建索引、性能与费用表；保存目标 Epoch 的 `RewardContext` 与分流快照，首次启用时写定 `first_poc_epoch`。
8. **全局收尾**：同步账本与链配置的绝对 Epoch，完成原有存储 gas 及新 Epoch 事件流程；清理完成所需会话，成对消费计划与 PVS，消费冻结令牌并解除冻结。

第 4、8 步中的缓冲配置、会话结果及密钥安装维持现有内部依赖顺序，但整体必须位于预检 / 缓存校验之后，涉及奖励的新设置必须位于旧期结算之后。`decryption::on_new_epoch` 使用明确的目标 Epoch，不能在目标改变后再次推算。

`reconfiguration::reconfigure` 原先持有 `Configuration` 可变引用再调用下游；重构时先取必要标量，结束借用后再预检，最后更新 Configuration，避免跨模块回调与可变资源借用冲突。`stake` 也不能在持有池或集合可变引用时调用会重新借用该资源的构建器。

### 10.4 普通 DKG、Chunky DKG 与强制结束

| 路径 | 实现约束 |
| --- | --- |
| 普通 DKG | 目标数组从同一次构建的 PVS 导出，顺序、地址、密钥与权重一致 |
| Chunky DKG | 与普通 DKG 使用同一目标集合；结果中的目标 Epoch 必须匹配计划 |
| 等待期间正常出块 | 继续更新旧索引的表现和费用；不改变 reward_base_octa，不重算目标 |
| DKG / Chunky 完成回调 | 在写入目标密钥或进入提交前确认计划身份；不能把旧会话结果交给新计划 |
| 超时 / shadow grace / 治理强制结束，有计划 | 沿现有恢复语义结束等待，提交原计划，不调用实时选举 |
| 治理强制结束，无计划 | 先同步预检；失败回滚治理事务，成功后提交同一结果 |
| 同一事务重复重配置 | 保留原有时间 / 已发事件保护；不重复结奖、推进周期或创建新计划 |
| 框架恢复取消重配置 | MVP 无用户入口；若升级流程提供，须同时清除计划、PVS、会话、目标密钥及冻结令牌，不能推进 Epoch |

旧模式尚未进入准备流程时保留原生路径；准备初始化必须在无进行中重配置、无残留 PVS / 会话的边界完成，从而不把原生旧缓存误认为已受新计划管理。

## 11. 冻结入口与配置提交权限

### 11.1 冻结检查的实际落点

`reconfiguration_state` 为需要检查的框架模块增加只读 friend 权限，或提供等价只读封装。PoC 准备要求该状态资源已初始化，不能依赖当前“资源不存在时返回未冻结”的兼容行为。

| 类别 | 必查直接 / 间接路径 | 合法提交的区别 |
| --- | --- | --- |
| 分配与原始版本 | `set_allocations`、批量上传、创世写入口、未来可能的修正入口 | 内部应用成熟变更允许，不能接收新未来变更 |
| 本金 | `add_stake_with_cap`、`reactivate_stake_with_cap`、`unlock_with_cap`、`withdraw_with_cap`、`increase_lockup_with_cap` | 原生内部状态转换允许 |
| 成员资格 | 加入、退出、取消加入、取消自主退出、`remove_validators`、池启用、`configure_allowed_validators` | 从缓存安装目标允许 |
| 验证者配置 | `rotate_consensus_key`、网络地址更新及其转调 | 保留现有密码验证逻辑，冻结检查不改变验证算法 |
| 原生参数 | required stake、lockup duration、增长比例、两种奖励率设置、两层 fee config 设置 | 保存下一期实际上下文允许 |
| 奖励分流 | `stake::schedule_reward_split` 及撤销待生效比例 | 冻结期间拒绝；合法提交时安装目标快照 |
| 缓冲配置 | 各 `set_for_next_epoch`、直接 `set`、公开 `on_new_epoch`、更新版本 / gas / consensus / randomness / timeout 等入口 | 仅受信提交路径可提取与安装已冻结载荷 |
| 功能开关 | 直接调用 `std::features` 与 `topo_governance::toggle_features` | 仅持计划令牌的提交路径可安装 |
| 历史奖励 | `claim_rewards` | 允许；不能借领取复投本金或改变目标 units |

现有 `StakingContract`、`DelegationPool`、`Vesting` 通过底层能力接口触达本金；测试必须从这些上层调用进入，以证明能力入口的防护确实覆盖。不能只测试 owner 的 entry 函数。

### 11.2 `std::features` 的无反向依赖实现

`std::features` 位于 Move 标准库，不能直接导入依赖标准库的 `topo_framework::reconfiguration_state`。只在 `topo_governance` 包装层检查也不足，因为治理脚本可以直接调用标准库公开入口。

本实施规格采用以下最小桥接：

```text
std::features 新增：
    PendingFeatureFreeze has key                    // 表示缓冲开关已冻结
    FeatureFreezeToken has store                    // 无 copy、无 drop，不能自行构造

    begin_reconfiguration_freeze(framework) -> FeatureFreezeToken
    on_new_epoch_with_freeze_token(framework, &FeatureFreezeToken)
    end_reconfiguration_freeze(FeatureFreezeToken)
```

`begin` 验证框架 signer、拒绝重复冻结，创建资源并返回唯一令牌。令牌存入新 `EpochPlan`；普通调用者不能从 `stake` 定义的计划中提取其私有字段。

所有可修改 pending features 的公开设置函数检查冻结资源不存在。既有公开 `on_new_epoch(framework)` 同样在冻结时拒绝；合法提交调用带令牌的版本，内部复用原有安装逻辑。结束必须消耗令牌及冻结资源，不提供一个仅持 signer 就能随意清除冻结的布尔 setter。

该桥接只新增类型与入口，不改 `Features` / `PendingFeatures` 的旧结构布局，也不新增业务功能开关。桥接与原有重配置状态必须在同一事务启闭，缺一视为协议状态错误。同步提交的令牌也在同一事务内消费。

### 11.3 缓冲配置与 DKG 结果不是同一种写入

不能在 `config_buffer::upsert` 上不加区分地禁止所有冻结期间写入：Chunky DKG 完成后还需要通过 `decryption::set_for_next_epoch` 保存本次目标密钥。

普通配置 setter 与受信 DKG 结果入口使用不同路径。缓冲写入统一由 `config_buffer::upsert` 检查冻结；无条件调用它的上层 setter 不重复检查，即使先提取缓冲，后续拒绝也必须使整笔事务回滚。存储 gas 包装入口同样复用 `storage_gas::set_config` 的底层检查。直接写资源的运行期入口、运行期初始化和公开安装入口保留各自的保护；已有 `assert_genesis` 的创世专用 setter 由链状态限制调用。

会话结果写入只允许当前计划的目标 Epoch，且调用者来自现有受信完成流程。通用底层 buffer API 的每个 friend 调用点必须审查，不能留下另一个不检查冻结的配置 setter。上述去重不收窄冻结范围，原生 DKG 进行期间仍受相同限制；多项输入同时非法时，错误优先级可以变化。

配置安装入口同样不能只凭框架 signer 绕过冻结。对 `randomness_api_v0_config::on_new_epoch` 等框架公开入口，保留原签名并在冻结时拒绝；合法提交复用既有 friend 关系，增加仅供已校验计划的提交驱动调用的 `public(friend)` 包装，与公开入口共用私有安装函数。逐一审查已有 friend 安装函数的转调，不能经公开包装绕回内部路径。框架配置不再新增令牌或状态；标准库仍使用第 11.2 节的既有桥接方案。

冻结中无权替换目标配置；仅受信提交路径可以消费先前已冻结的载荷、保存匹配计划的 DKG 输出，正常出块统计继续累计。不要临时解除全局冻结来执行这些内部步骤。

## 12. 成员变动、延期恢复与治理口径

### 12.1 加入与取消待加入

`join_validator_set_internal` 保留运营者权限、原生余额范围、验证者配置、ACL 与容量检查。当前 Epoch 已经是 PoC 时：

- 待加入 `ValidatorInfo.voting_power = 0`，不提前增加 `total_voting_power`。
- 不调用按代币金额计量的 `update_voting_power_increase`。
- `add_stake_with_cap` 继续处理原生本金与 maximum stake 检查，但不将追加代币计入 PoC `total_joining_power`。
- `total_joining_power` 用于原生模式的加入权重预算；PoC 下保持零，PoC 增长预算统一由计划构建计算。

现有 `leave_validator_set` 对 pending_active 的移除分支可继续作为取消待加入入口，不需要另建一个重复队列。PoC 下取消时不按代币余额扣减 `total_joining_power`，也不要求取消后整个目标立即有效，以便逐步修复多候选竞争。

准备期仍处在原生 Epoch 时，原生临时权重与增长规则继续适用；首份 PoC 计划忽略这些不同单位的基础权重，按首次初始化规则生成目标。未入选新候选在成功换届后转为不在任，不保留低于门槛的“积攒权重”，下次须重新申请。

### 12.2 自主退出

对当前在任池的 PoC 自主退出，逻辑顺序为：

1. 检查未冻结、当前授权运营者、成员变化允许、池确实在 active 队列。
2. 在局部候选视图中排除该池，使用与真正换届完全相同的构建器做预检。
3. 预检失败 abort；不得留下已移队的成员或自主退出标记。
4. 预检成功后把原 `ValidatorInfo` 从 active 移到 pending_inactive，记录 `requests[pool] = E`。

可由组合交易先为替补完成待加入申请，再调用退出；是否能由同一 signer 完成取决于两池既有运营权限，不新增代签权。也可先在同一事务临时移动、再预检失败回滚，但必须先结束可变借用，并保证没有任何可提交的部分状态。

PoC 分支以完整目标预检为准，不能无条件保留旧代码仅检查 `active_validators.length() > 0` 的退出判据，否则会与合法的替补目标冲突。原生分支继续原有规则。待退出成员仍以原索引参与旧期共识与计奖。

### 12.3 取消自主退出与治理移除

```text
cancel_leave(operator, pool):
    assert not_frozen
    assert operator is the pool's current authorized operator
    assert voluntary_requests[pool] == current_epoch
    assert pool exists in pending_inactive
    assert active_count + pending_active_count + 1 <= V_LIMIT
    restore the original ValidatorInfo into active_validators
    remove voluntary_requests[pool]
```

恢复时不重建 `ValidatorInfo`，保留当期权重和 `config.validator_index`；可以追加到 active 向量，但不能按新向量位置重写本期索引。性能数组、费用 key、总投票权重和增长预算不变，不结算奖励。

取消退出不要求全局目标已经有效，但必须满足硬容量。如果新待加入申请占满空间，可先取消一个待加入者，或在一个组合事务中腾出容量再恢复。

`remove_validators` 在治理移除名单逐池处理时，无论该池是否还在 active 中，都清除其自主退出标记。这样治理移除一个已经自主待退出的池后，运营者无法撤销治理决定。治理移除不受自主退出预检限制，但目标无效时后续换届仍返回 `Deferred`；若治理事务同时要求立即换届，该事务整体回滚。

成功换届时清理本届自主退出标记，遍历本届待退出地址即可，不扫描 Table。迟到的取消申请因为 Epoch 或成员状态不匹配而失败。

### 12.4 `Deferred` 的修复操作

| 失败原因 | 可执行修复 | 重新预检时检查 |
| --- | --- | --- |
| 替补被多个候选摊薄到门槛以下 | 取消多余待加入申请，分批参选 | 同一预算公式，不保留未入选临时权重 |
| 退出后人数不足 | 取消自主待退出，或准备合格替补 | 恢复旧索引，重新核定目标人数 |
| 算力迁移造成集中度过高 | 覆盖尚未生效的分配，撤回迁移 | 最终限幅权重满足开放模式约束 |
| 保证金不足 / 到期 | 追加或重新激活本金，按原生规则处理锁仓 | 使用新的预检截止时间，当前权重不变 |
| 待生效门槛或担保参数不适用 | 治理替换或撤销待生效参数 | 当前与未来参数组合均合法 |
| 期限即将结束 | 按已批准方案提前升级 | 不重置基线、首个 Epoch 或已累计权益 |

预检失败后保留每块重试能力。初版采用每块预检，应记录 `V_LIMIT` 下连续失败的执行成本；如达不到区块预算，先调整并验证支持规模。另加重试节流会改变修复等待时间，需要新的明确规格，不能借修改周期时钟实现。

修复依赖旧委员会仍有足够在线权重提交交易。最低节点人数和单池集中度校验都不能保证同一实体没有控制多个池；开放部署保留“恶意总权重低于三分之一”的外部安全假设。

### 12.5 原生代币治理权重

PoC 只替换 BFT 的已安装权重。`topo_governance::get_voting_power` 中原有静态委员会分支调用 `stake::get_current_epoch_voting_power`，PoC 后会得到算力，必须改为明确的原生代币余额查询。PoC 模式下采用原生池 `active + pending_active + pending_inactive` 的治理口径，并保留现有治理授权、锁仓与投票记录检查。

原生模式的分支行为不因上述适配改变。治理代码、前端和查询命名都不能把新的共识权重用于提案门槛、已投票额度或委托投票统计。测试同时覆盖 `allow_validator_set_change = true` 与 `false`。

## 13. 准备、首次启用与创世初始化

### 13.1 概念状态

以下是由资源存在性、激活配置和已安装上下文推导的状态，不增加一份容易失配的独立 mode 状态机：

| 状态 | 当前计奖 | 用户 PoC 操作 | 换届行为 |
| --- | --- | --- | --- |
| 未准备 | 原生 | 无 PoC 分配 / 金库 | 现有原生流程 |
| 已准备，目标尚未到启用 Epoch | 原生 | 可建账、分配、上传；没有 PoC 奖励 | 原生选举；成功后同步准备时钟和账本 Epoch |
| 目标为首次 PoC Epoch | 旧期仍原生 | 未冻结时可修复 | 使用首份 PoC 计划；失败仍为旧原生 Epoch |
| 已安装 PoC | PoC | 分配下一 Epoch 生效，按检查点领奖 | 正常增长预算、集中度和期限检查 |
| 任一受管理换届已冻结 | 仍按已安装旧模式 | 只允许历史 PoC 领奖等不影响目标的操作 | 只消费同一计划 |

### 13.2 准备事务

准备入口按以下顺序实施：

1. 验证框架权限，确认没有正在进行的重配置、残留 PVS 或待处理目标会话，防止混接不同生命周期。
2. 读取真实的链 Epoch、当前原生奖励率和费用配置，初始化配置缓冲。
3. 验证部署清单、单期奖励上限与参数组合，创建全局 PoC 账本，`epoch` 对齐链 Epoch，排定 `activation_epoch >= E+1`。
4. 保存该 Epoch 的 `RewardContext { poc_enabled: false }`，初始化自主退出记录。
5. 一次性创建算力表和周期时钟，将时钟设为当前绝对 Epoch，记录固定保留比例和支持期限，建立 `I[0]`；拒绝重复初始化。

准备入口只建立全局状态，不全量扫描用户或自动把 owner 算力分给自己的池。验证者启用、用户配置与原始版本准备通过有界事务完成。部署清单里要列出实际准备的候选池与初始分配。

在准备阶段经过的每次成功原生换届都消耗周期倒计时。当前委员会中的已启用池可顺带推进；其他已启用但不在委员会中的池，在用户操作或首次目标预检 / 提交时惰性处理成熟变更，不全量扫描注册池。

### 13.3 开发阶段的算力初始化

当前不承接旧版 PoC 数据，也不提供迁移、惰性转换或缺资源补建入口。准备 PoC 时直接创建完整算力存储、周期时钟及奖励分流配置；开发环境通过全新创世使用新布局。尚未准备 PoC 的原生模式仍可查询空配置，这不适用于已准备但缺资源的损坏状态。

1. 全新 PoC 创世一次性创建算力表和时钟，再写入周期 0 的原始算力及标准化版本，`units = power * UNIT_SCALE`。
2. 运行期在准备后上传下一周期算力，由当前指数计算下一指数并保存 `units`，到生效周期才切换使用。
3. 无算力记录的用户查询返回零，可先设置分配；后续上传会同步已有分配，无需额外初始化用户算力记录。
4. 版本的 `units` 不因首次访问或周期推进而重新计算。创世直写仅限真实创世阶段且时钟尚未推进；存在预写未来版本时须保留该版本并同步持仓。

### 13.4 首次切换事务

首份有效 PoC 计划提交时：

1. 使用旧 `RewardContext` 结算最后一期原生奖励与费用，资产存入原生 `StakePool`，不进入 PoC 金库。
2. 处理到期原生本金和已准备的 PoC 算力变更；不因旧原生池在 `targets` 中就自动启用 PoC。
3. 安装首个 PoC 委员会与计奖基数，跳过不同单位之间的增长率比较。
4. 原子写定 `first_poc_epoch = 目标 Epoch`、新 PoC 上下文及分流快照；后续入池费按原生分流收益估算。

历史质押份额及内含原生收益继续按原有所有权领取。算力用户无需先领取原生收益；只出资但无算力的账户不从 PoC 金库拿奖励。

首份计划失败不写 `first_poc_epoch`，不发放任何末期奖励，不消耗初始化例外。调整启用 Epoch 不清空用户已经准备的 units，也不重新设置相对周期零点。

### 13.5 全新创世

创世先准备标准化状态，再为每个实际验证者 owner 写入 `PocGenesisConfiguration.initial_raw_power` 指定的统一原始算力，启用其同地址的池，并按 `10000 bps` 全额分配到本池。验证者身份与保证金由验证者记录提供，配置无需重复列出用户、启用池或分配。周期 0 的 `units = initial_raw_power * UNIT_SCALE`，最终权重仍受保证金与权重上限约束。初始化期按创世授权写入算力，分配沿用普通入口在 Epoch 1 生效；不能把创世直写能力暴露到运行期。

`PocGenesisConfiguration` 仅保存首届委员会参数、模式、衰减保留比例和初始算力；上限和分流不再通过清单传入。`genesis::create_initialize_poc_validators` 使用合约默认上限及 `5000 bps` 分流，首期安装时生成快照，不结算 Epoch 0 奖励。

`initial_raw_power` 的配置单位是整数 `power`。例如希望配置 `1 OHMP` 的原始算力时，应填 `100000000`，并独立校验保证金、权重门槛与部署上限；已有测试中的 `initial_raw_power = 17` 仍表示 `0.00000017 OHMP`，不能因展示命名而放大测试输入。

直接 PoC 创世的可治理参数采用方案 A：算力周期复用现有默认 `60` Epoch，初始上传者为 `0x1`，每池费用分发限额为 `0`。这三项由 Move 创世流程确定，不再经 Rust 清单及 BCS 逐层传入；后续使用现有治理入口修改。

Rust 的 `PocGenesisConfiguration::mainnet()` 和 `Default` 提供兼容现有 TOPO 配置的完整主网 PoC 参数：1 TOPO/OHMP、每个验证者初始 100 万 OHMP、开放委员会至少 5 人。`PocGenesisConfiguration::testnet()` 适配现有测试创世每个验证者质押 1 TOPO 的配置，使用受控模式、最低 2 人，每人初始 1 OHMP，最低权重为 1 power、每池权重上限 1,000 OHMP；部署上限由合约统一初始化，其余创世参数沿用主网默认值。最低 2 人在动态换员时要求现有测试配置的 50% 增长上限，两个等权节点须同时在线；两套配置均可覆盖个别 PoC 字段。完整取值见[主网默认值](POC_GENESIS_IMPLEMENTATION_CHECKS.md#主网默认值)与[测试网默认值](POC_GENESIS_IMPLEMENTATION_CHECKS.md#测试网默认值)。已有链的准备入口继续要求完整清单。

当前创世创建验证者时会调用 `stake::on_new_epoch`，随后框架另发初始 Epoch 事件。应将首次安装与周期计数设计为一次明确的创世操作，验证最终链 Epoch、账本 Epoch、计奖上下文都是 `1`，周期倒计时与第 6.1 节的初始规则一致。创世不结算一个虚构的 PoC Epoch `0`。

若部署选择先运行原生再准备启用，也应明确记录该路径，不因新创世而隐式提前开启 PoC。开放模式的初始委员会同样满足最终权重集中度，创世例外只免增长预算，不免资格和数值约束。

### 13.6 发布清单模板

以下为发布文档模板，所有占位项必须替换；不能直接作为可执行配置提交：

```yaml
implementation_revision: "<实际发布提交>"
framework_bundle_digest: "<生成 bundle 的摘要>"
deployment_mode: "<controlled 或 open>"
genesis_or_upgrade: "<genesis 或 upgrade>"
activation_epoch: "<绝对 Epoch>"
baseline_epoch: "<绝对 Epoch>"
retention_bps: "<固定保留比例>"
power_period_in_epochs: "<周期长度>"
bond_octa_per_ohmp: "<每 1 OHMP 所需的 Octa 数，正整数>"
min_power: "<最终权重门槛，整数 power>"
max_power: "<最终权重上限，整数 power>"
initial_raw_power: "<仅 PoC 创世：每个验证者的原始算力，整数 power>"
min_validators: "<最低人数>"
increase_limit: "<百分数，非 bps>"
validator_limit: "<通过成本测试的 V_LIMIT>"
max_allocations: "<配置并集上限>"
max_claim_pools: "<单次领取上限>"
max_upload_users: "<单批用户上限>"
fee_max: "<每池每 Epoch 的分发上限，代币最小单位>"
h: "<首次 PoC 起最多结算的 Epoch 数>"
initialization_evidence: "<全新创世或空算力存储准备的验证结果>"
capacity_report: "<数值边界和执行成本报告>"
upgrade_warning: "<阈值、负责人、升级窗口>"
```

## 14. 事件、错误与运行观测

### 14.1 事件

保留既有原生事件及含义；PoC 新增事件明确奖励去向，不把 PoC 金库增长描述为用户质押本金增长。

| 拟新增事件 | 最小字段 | 发出时机 |
| --- | --- | --- |
| `PoCPrepared` | 基线 Epoch / 源周期、计划启用 Epoch、部署方式 | 准备成功 |
| `PoCPoolEnabled` | pool | 首次创建账本 |
| `AllocationScheduled` | user、effective_epoch、pools、bps | 分配事务成功 |
| `PowerNormalized` | user、effective_period、units | 实际新增标准化版本；可与原始事件关联 |
| `PoCRewardCredited` | pool、closing_epoch、reward_base_octa、inflation、fee、delta_index | 每池旧期一次入账；inflation、fee 均为分流后进入 PoC 的金额 |
| `PoCRewardClaimed` | user、pool、amount | 实际支付，零领取可不发 |
| `PoCEpochInstalled` | epoch、period、selected_count、total_power | 新 Epoch 成功安装 |
| `VoluntaryLeaveCancelled` | pool、request_epoch | 恢复自主退出成功 |

`PoCRewardSplit` 记录通胀分流明细；原生通胀继续发出 `DistributeRewards`，正原生费用通过已有 `DistributeTransactionFee` 记录。费用总额可由原生费用事件与 `PoCRewardCredited.fee` 相加还原。

原始版本重复上报不发新增标准化事件。不要在同一事件里复制整个历史持仓或整份计划；可通过资源与已安装 Epoch 查询详细目标，控制事件体积。

### 14.2 错误与延期原因

最终数值错误码按各模块现有序列分配，避免与已经发布的错误重号。建议名称分类如下：

| 分类 | 建议符号 | 含义 |
| --- | --- | --- |
| 用户输入 | `EINVALID_ALLOCATION`、`EDUPLICATE_POOL`、`EALLOCATION_LIMIT` | 比例、地址或数量不符合约束 |
| 准入 / 权限 | `EPOOL_NOT_ENABLED`、`ENOT_OPERATOR`、`ENO_VOLUNTARY_LEAVE` | 池未开放、权限不足或退出来源不符 |
| 时点 / 参数 | `EINVALID_TARGET_EPOCH`、`EINVALID_PARAM_COMBINATION` | 生效时点或组合约束错误 |
| 容量 / 数值边界 | `EPOOL_CAPACITY`、`EPOWER_HORIZON` | 写入超过已声明支持范围 |
| 冻结 | `ERECONFIGURATION_IN_PROGRESS` | 外部尝试改变冻结目标 |
| 状态损坏 | `EPLAN_MISMATCH`、`ECHECKPOINT_MISSING`、`EREWARD_ALREADY_CREDITED`、`EVAULT_INVARIANT` | 不可作为普通延期吞掉 |
| 预检结果值 | `INSUFFICIENT_VALIDATORS`、`ZERO_TARGET_POWER`、`CONCENTRATION_LIMIT`、`TARGET_OUT_OF_RANGE` | 可供修复与观测的业务结果，不直接中止 block prologue |

预检失败无需每块额外写一份全局失败状态，也不需要每块发大事件。初版以只读预检查询和节点可观测输出定位原因；若增加失败事件，必须把连续失败的事件成本纳入性能验收。

### 14.3 运行观测项

运行报告至少记录当前模式与 Epoch、冻结起始时间和目标 Epoch、每池已安装权重与占比、延期原因、候选规模、当前 / 下一指数、距离指数数值边界的余量、金库容量、算力上传失败数和最大单次执行成本。

不能把待生效分配展示为当前共识权重；DKG 期间展示缓存目标与实时旧期奖励累计两个不同对象。监控不替代写入时的容量检查，也不把期限预警等同于自动升级机制。

## 15. 测试设计与验收矩阵

### 15.1 测试分层

| 层级 | 拟新增位置 / 既有入口 | 主要验证 |
| --- | --- | --- |
| Move 算术与账本 | `topo-framework/tests/poc_accounting_tests.move`、`poc_power_store_tests.move` | 单位计算、两时点重建、引用回收、资产守恒 |
| Move 选举与重配置 | `poc_epoch_plan_tests.move`、`poc_reconfiguration_tests.move` | 资格、增长、目标一致、冻结、退出修复 |
| Move 算力版本与集成 | `poc_power_version_tests.move`、`poc_delegation_tests.move` | 直接初始化、版本生效与轮换、首次启用、原生份额 / 入池费 |
| Rust Move E2E | `aptos-move/e2e-move-tests/src/tests/poc_consensus.rs`（新增） | 实际事务回滚、写集、事件、升级与 VM 执行结果 |
| DKG 类型集成 | `aptos-types` 现有普通 / Chunky DKG 测试附近 | 经 Move 校验后的输入安全传递，目标权重顺序一致 |
| 节点 smoke | 现有 randomness 与 chunky_dkg 测试目录 | 重启、离线验证者、超时、强制结束、跨节点目标一致 |

新测试文件须加入现有 harness 或模块注册，不能仅添加文件名而未执行。计奖参考模型应从设计公式和实际生效区间计算，不复制实现内部的 PoolChange 操作序列作为唯一判定标准。

### 15.2 与设计第 9 节逐项对应

| 设计编号 | 必须执行的动作 | 核心断言 |
| --- | --- | --- |
| 1 | 上传后改比例、改比例后上传，比较两条轨迹 | 相同原始版本、配置、持仓目标和池聚合；当前期不被提前改变 |
| 2 | `E+1 == B`、同 Epoch 多次覆盖、覆盖回 active、重复上报 | 最多两条；相同时点合并；没有无意义引用或重复入账 |
| 3 | 多期不领、池退出后长期不访问、清理旧原始版本 | 依据持仓及检查点领回准确历史收益；与当前原始表无依赖 |
| 4 | 两人等量换仓、总 units 不变，下一人随后领奖 | 检查点仍存在；旧用户保留旧权益，新用户不拿旧残差 |
| 5 | 保证金限幅、max_power 限幅、增长限幅分别生效 | 同池用户奖励比例始终为 units 比；不存在个人保证金绑定 |
| 6 | 固定同一开始状态走同步、DKG、Chunky、超时完成 | 目标集合、顺序、权重及基数一致；旧期费用只结算一次 |
| 7 | 目标不合格且继续多个块，随后修复 | Epoch / 时钟 / 待变更未部分推进；旧表现继续累计；退出池新基数为零 |
| 8 | 原生切换与原生份额、PoC 奖励两种领取 | 不混用增长单位；同一奖励不存在双重领取 |
| 9 | 最大版本、单位聚合、长期不领、长延期表现 | 宽整数安全；支持范围内无算术导致的 prologue 中止 |
| 10 | 四池权重 10、最低人数 4、`V_LIMIT = 5`，配置分别为 20% 和 25%，单替补 | 前者配置拒绝；后者无其他增长竞争时可先加入替补、再退出旧池并完成换届 |
| 11 | 多新候选竞争、取消多余加入、自主取消退出、治理移除同池 | 自主退出预检拒绝无效目标；恢复旧索引及收益；治理移除无法取消 |
| 12 | 修改 / 撤销待分配及参数，连续 Deferred 后修复 | 重新使用相同预检；最大候选规模成本达标，失败不结奖不衰减 |
| 13 | 冻结表的所有直接与能力路径，冻结时领奖，各种强制结束状态 | 写入拒绝且零部分状态；领奖不改目标；坏缓存拒绝提交 |
| 14 | 最后原生 Epoch 改费开关 / 奖励率并追加委托，分别延期与成功 | 旧入池费与旧上下文有效；新上下文只在成功安装后生效 |
| 15 | `I = floor(INDEX_SCALE * 9000 / 10000)`、原始 100、100% 分配 | 池整数权重 99，按最终值决定是否达到 min_power |
| 16 | 当前 / E+1 / B 容量越界，临时中间状态超容量的合法替换，两个 `2^63` 目标 | 非法写入原子失败；合法最终替换成功；总权重非法输入在 DKG 前拒绝 |
| 17 | 部署具体参数、指数数值边界、零 / 最小正 / 最大允许奖励、长期不领、代币反复入账使累计奖励超过 u64、调整周期 / 启用时点 | 指数基线不重置；奖励无期限；禁止低于数值下界的版本；u256 累计与领取守恒 |
| 奖励分流 | 占比 `0 / 3000 / 10000`、未来生效和撤销、冻结拒绝、同步与各 DKG 完成路径 | 旧期按旧快照结算，两路总额守恒，通胀和费用均分流、零通胀仍分费、费用开关与限额使用旧快照，原生份额与佣金正确 |
| 原生金额与委托入池费 | 发行规模内的原生复投、追加、解锁、重激活、巨大费用政策上限和已冻结目标 | 有效本金范围正确，新份额不摊走本期原生收益；政策上限不导致容量误拒，实际结算断言保留，未结算奖励不回算目标 |
| 18 | 五池等权 20 迁移到 `[20,5,5,5,5]`，随后撤回 | 开放模式拒绝并可修复；受控测试标出信任假设 |
| 19 | 空存储准备、创世直接写入、晚访问、版本轮换、先分配后上传 | 写入时固定 units、当前与下一周期隔离；首次上下文与 Epoch 一致 |

第 16 项通过独立目标校验器的整数输入覆盖实际总和拒绝，不需要铸造超过 `u64` 的代币。`max_power` 可配置到 `u64::MAX`，实际目标仍须通过 DKG 前总和检查。

### 15.3 补充的源码接入回归

- 时钟长度 `1`、`60`，`r == 0` 和 `r > 0`，准备时局部计数不等于链 Epoch；验证 `B = E+r+1`。
- 固定 `B = 61`，设置 `new_length = u64::MAX - 61` 时下一边界恰为上限；再加一或直接设置 `u64::MAX` 均原子拒绝，旧长度、倒计时与 `B` 不变；初始化和边界预检覆盖相同检查。
- 动态换员、最低人数 `4` 时拒绝 `V_LIMIT = 4`；改为 `5`、四池权重各 `10`、增长比例 `25%` 且无其他竞争时，经既有加入和退出入口完成单替补换届。
- 完全没接入准备的原生链、已准备但尚未到启用目标的原生链，均可继续原生换届。
- 创世写入口仅在真实创世阶段可用，测试专用写入口不进入生产字节码。
- `allow_validator_set_change = false` 的 PoC 链治理仍按代币计权。
- DKG 期间领取导致历史检查点删除，但目标 units、计划与 PVS 都不变化。
- 池在 Epoch `10` 已退出且账本停在该期，持仓有 Epoch `11` 生效的撤回；到 Epoch `12` 直接领奖，先以不增长的指数补出检查点再结算，重复领取不重复支付；冻结时结果相同且不推进目标 Epoch。
- 成熟两条变更的长期未操作持仓，再新增版本或重新分配时仍只有新的两条未来变更。
- 每池变更净零但引用非零；最后一个引用释放；全部撤销后记录删除；漏检查点时必须失败。
- 金库奖励不可通过原生 share 同时体现，原生本金新增也不能产生 PoC 用户算力。
- 费用开关关闭时旧费用仍正确清理，重新启用时新索引记录正确；费用累计触顶不因溢出阻塞交易。
- 标准库直接设置、直接 `on_new_epoch`、框架包装和 buffer 转调都不能绕过冻结；特别验证冻结时直接调用 `randomness_api_v0_config::on_new_epoch` 失败且缓冲 / 生效配置均不变，已校验计划的受信提交及合法 DKG 目标密钥写入仍成功。
- 准备后直接写入周期 0 算力 `100` 和周期 1 算力 `200`，保留比例 `10000`；无后续上传，用户到周期 3 首次访问时直接使用 `200`。另以衰减比例验证 units 始终绑定写入时的生效指数，并覆盖零算力用户先分配后上传。
- 计划 / PVS 任一孤立、目标 Epoch 错位、迟到 DKG 结果、重复 finalize、多个 reconfigure 调用不导致重选或双结奖。
- `cutoff_secs` 恰好等于锁仓截止，和 DKG 等待跨越锁仓截止，两种情况分别验证保证金与原生转换一致。

### 15.4 状态机与差分测试

构造小规模参考模型，显式保存每个用户在每个 Epoch 的 units，按已发生奖励逐期分配。链上实现仍使用两条变更与检查点，测试模型可以保存完整历史，以形成独立参照。

随机交错上传、改比例、领取、出入委员会、调参数、开启 / 完成 DKG 及 `Deferred`。每步比较逻辑池总量、用户按精度计量的权益、累计支付、金库余额与委员会权重。采用同样明确的向下取整规则，不以浮点误差容忍金额差异。

每次成功操作都检查设计中的不变量；每次预期失败比较完整相关资源写集，验证没有部分版本、部分引用更新或部分本金转换。奖励模型保留池级未分配残差与用户余量的区别。

### 15.5 成本验收

至少测量以下负载，不仅给出 `O(V)` / `O(K)`：

| 负载 | 需要记录 |
| --- | --- |
| `V_LIMIT` 下连续 Deferred，带最多本届退出成员 | block prologue 执行时间 / gas 计量、读取数量、完整块预算余量 |
| 最大候选集合的一次成功换届 | 旧期发奖、目标预检、索引重建、写集及事件体积 |
| 最大 `MAX_ALLOCATIONS` 的配置替换 | 访问至多 `2K` 个池、两边界撤销与重建成本 |
| 最大上传批次，所有用户均分配满 | 批次原子事务的 gas、写集大小及冲突情况 |
| 最多两条成熟变化的历史领奖 | 检查点访问、删除成本与跨池领取上限 |
| 热门池的并发分配 / 上报 / 费用记账 | Block-STM 冲突、重执行次数和吞吐，尤其是费用限幅路径 |

不对全部注册池或用户作 Epoch 扫描；但多个用户更新同一个 `PoolLedger` 仍可能产生写冲突，这是部署成本报告必须体现的限制。验收报告给出实测环境、候选上限及可复现命令。

## 16. 实施顺序与阶段完成条件

各阶段按依赖顺序交付；阶段编号用于拆分开发任务，不意味着只完成前几项即可启用 PoC。

| 阶段 | 工作内容 | 前置条件 | 完成条件 |
| --- | --- | --- | --- |
| M0：基线核实 | 记录提交、确认实际发布模块、处理 `staking_registry` 悬空依赖、验证现有框架可构建 | 无 | 得到可重复构建基线及明确的创世初始化路径；把历史既有失败单独记录 |
| M1：数值与存储 | 账本结构、部署参数验证、算术辅助、标准化版本及只读周期快照 | M0 | 固定常量、量化样例、指数数值边界 / 奖励累计容量 / DKG 总和及空存储初始化测试通过 |
| M2：分配与领奖 | 两时点重建、池聚合、检查点引用、版本同步、用户入口 | M1 | 设计验收 1–4、15–17 的账本部分通过，参考模型一致 |
| M3：计划构建 | 保证金预览、资格、增长预算、开放集中度及只读结果 | M1–M2 | 所有边界能返回明确结果；无持久化副作用；候选顺序固定 |
| M4：原生模式与结算拆分 | RewardContext、奖励去向、旧索引费用、本金处理、入池费与治理查询 | M2–M3 | 最后原生期、新 PoC 期、历史原生份额无重复发放或模式混用 |
| M5：冻结与换届 | 所有重配置入口、标准库冻结令牌、buffer 路径、DKG / Chunky / 强制结束 | M3–M4 | 同一计划覆盖所有提交；坏缓存拒绝；冻结矩阵逐入口通过 |
| M6：成员恢复与启用 | 自主退出预检、取消来源、准备入口、首次切换、直接算力写入与创世 | M5 | `Deferred` 可通过设计修复入口恢复；直接创世与空算力准备路径测试通过 |
| M7：系统验收 | 节点恢复、完整初始化、数值证明、容量与并发测试、缓存 bundle | M1–M6 | 19 项验收有执行证据，发布清单无占位，生成资产与源码一致 |

M2 可以使用只在测试编译中存在的奖励注入辅助验证账本，生产模块仍只接受 `stake` 的真实奖励。M3 可先对固定测试输入运行，不能在 M5 尚未完成冻结前接入正式 DKG。M6 的启用交易只有在 M7 的发布要求全部满足后才用于真实部署。

每阶段的代码提交应包含其验证证据与相应 `.spec.move` 更新。不要保留仍然断言“共识权重等于代币本金”或“一期不会超过一天”的过期规格；需要修订证明前提，不能简单删除整个规格文件来让测试通过。

## 17. 构建、验证与发布操作

### 17.1 Move 缓存包必须实际更新

仓库 `CLAUDE.md` 与 `agents.md` 要求任何 `aptos-move/framework/` 下 `.move` 增删改后重建缓存。当前分支的实际生成入口是 `topo-framework update-cached-packages`；单独编译缓存 Rust crate 不能作为已重新编译 Move 源码的证据。

在仓库根目录执行：

```bash
# 实际生成生产 head.mrb 与 SDK 绑定；脚本同时格式化生成的 Rust 文件。
scripts/cargo_build_aptos_cached_packages.sh

# 执行仓库规定的缓存包构建，并验证实际产物。
cargo build -p aptos-cached-packages
git status --short aptos-move/framework/cached-packages/
```

生成过程中必须解决编译、friend 依赖和循环依赖问题。开发阶段直接采用新结构并重建创世。将变更后的 `head.mrb` 与实际生成的 SDK 文件一同审查，不能只提交 Move 源码。测试专用 bundle 与生产 bundle 分开，生产发布不得包含 `#[test_only]` 入口。

### 17.2 定向测试和包级回归

本仓库 Move 单测由 Rust 包 `topo-framework` 的 `move_unit_test` harness 驱动，支持 `TEST_FILTER`。新增模块和测试注册完成后可使用：

```bash
# 定向运行新 PoC Move 测试；确认实际执行数量大于零。
TEST_FILTER=poc_ cargo test -p topo-framework --test move_unit_test move_framework_unit_tests -- --nocapture

# 框架与标准库受影响范围。
cargo test -p topo-framework --test move_unit_test move_framework_unit_tests
cargo test -p topo-framework --test move_unit_test move_stdlib_unit_tests
cargo test -p topo-framework --test move_unit_test move_aptos_stdlib_unit_tests

# 包级回归。
cargo test -p topo-framework

# 实际交易与已有质押回归；poc_ 筛选要求新 Rust 测试采用该名称。
cargo test -p e2e-move-tests poc_
cargo test -p e2e-move-tests stake

# DKG 输入及既有普通 / Chunky DKG 回归。
cargo test -p aptos-types dkg
```

上述筛选是实现完成后的执行入口，不表示当前分支已有这些 PoC 测试。记录执行数量、失败和 ignored 测试；零测试通过不算验收。需要 test-only bundle 的 E2E 使用仓库对应构建选项，不能将其覆盖到生产 `head.mrb`。

Rust 文件发生修改后，对实际修改包运行 `cargo check`、包级测试与 clippy。`cargo xclippy` 是仓库整套 lint 别名；包级检查可直接调用 `cargo clippy -p <package> --all-targets`，避免把 `-p` 拼到别名中已经存在的 `--` 之后。

```bash
# 按实际修改包调整此列表。
cargo check -p topo-framework -p e2e-move-tests -p aptos-types
cargo clippy -p topo-framework --all-targets -- -D warnings
cargo +nightly fmt --check

# 完成集成后按仓库要求运行全量 lint。
./scripts/rust_lint.sh --check
```

如有 Aptos VM 或执行器实现变更，补充相应包测试与顺序 / 并行执行验证；只增加测试或 Move 框架逻辑不能据此宣称已验证所有节点故障场景。

### 17.3 节点及升级演练

在现有 swarm / smoke 环境中准备受控和开放两组配置，运行普通 DKG 成员替换、Chunky DKG、验证者重启、在线权重不足、超时强制结束及升级演练。可从以下现有测试组扩展：

```bash
cargo test -p smoke-test randomness -- --nocapture
cargo test -p smoke-test chunky_dkg -- --nocapture
```

测试报告明确所需节点二进制、测试过滤和是否需要额外运行 ignored 场景，不能仅依靠测试名推断已经覆盖恢复。开发阶段使用新 bundle 验证全新创世，以及空算力存储的准备和首次切换；覆盖直接算力写入、待生效版本和成员变更。

在提交源码及生成产物后的干净验证 checkout 中执行缓存新鲜度检查：

```bash
scripts/cargo_build_aptos_cached_packages.sh --check
```

当前脚本检查 `aptos-move` 下的 tracked 改动，开发中的合法未提交源文件也可能使其失败；不能把此类工作区差异误报成 bundle 必然陈旧。发布时要求完整验证状态与提交一致。

### 17.4 发布门槛与交付材料

发布必须同时满足：

1. 部署清单所有参数有确定值，指数边界和奖励容量证明、增长组合和开放集中度校验通过。
2. 创世与原生模式准备路径有实际演练记录；完整资源初始化、基线稳定及版本槽覆写前同步检查通过。
3. 19 项验收及第 15.3 节的接入回归完成，冻结矩阵覆盖入口及转调路径。
4. 最大支持规模、长延期、热点池及费用记账的成本报告满足实际区块和交易预算。
5. 生产 bundle、生成 SDK、测试结果、源码提交和部署脚本能够对应，关键权限及共识接入已经按仓库规则审查。
6. 已指定期限预警与升级负责人；启用后不提供临时退回原生奖励或重置基线的操作脚本。

最终工程交付包含实现代码、生成 bundle、测试 / 性能报告、初始化验证报告、填完的部署清单以及 `Deferred` 修复操作说明。普通配置调整、治理强制结束与框架升级的操作权限分别沿用各自授权，不提供绕过计划的新恢复后门。

## 18. 源码索引与核对边界

以下链接指向本仓库当前文件。行号会随实现变化，核对时以列出的符号为准。

| 主题 | 源码 | 重点符号 |
| --- | --- | --- |
| 仓库构建与安全约定 | [CLAUDE.md](../../CLAUDE.md)、[agents.md](../../agents.md) | Move 缓存包要求、受保护代码、验证流程 |
| 原设计 | [最小设计](POC_CONSENSUS_V2_MINIMAL_POWER_REWARD_DESIGN.md) | 第 3–9 节及 19 项验收 |
| 双版本与时钟 | [poc_power_store.move](../../aptos-move/framework/topo-framework/sources/poc/poc_power_store.move) | `PowerVersion`、`PeriodClock`、`stage_batch_update`、`commit_next_period_if_boundary` |
| 贡献来源 | [poc_contribution.move](../../aptos-move/framework/topo-framework/sources/poc/poc_contribution.move)、[poc_registry.move](../../aptos-move/framework/topo-framework/sources/poc/poc_registry.move) | 周期读取与应用注册；不是验证者池注册 |
| 原生本金、奖励与目标集合 | [stake.move](../../aptos-move/framework/topo-framework/sources/stake.move) | `on_new_epoch`、`next_validator_consensus_infos_v2`、`update_stake_pool`、`record_fee`、`increase_lockup_with_cap` |
| 同步重配置 | [reconfiguration.move](../../aptos-move/framework/topo-framework/sources/reconfiguration.move) | `reconfigure`、`current_epoch`、创世事件 |
| DKG 生命周期 | [reconfiguration_with_dkg.move](../../aptos-move/framework/topo-framework/sources/reconfiguration_with_dkg.move) | `try_start`、`try_start_with_chunky_dkg`、`finish`、`try_finalize_reconfig` |
| 冻结状态 | [reconfiguration_state.move](../../aptos-move/framework/topo-framework/sources/reconfiguration_state.move) | `is_in_progress`、`on_reconfig_start`、`on_reconfig_finish` |
| 区块入口 | [block.move](../../aptos-move/framework/topo-framework/sources/block.move) | 各 block prologue 变体与旧期性能更新 |
| 原生参数 | [staking_config.move](../../aptos-move/framework/topo-framework/sources/configs/staking_config.move) | `get_reward_rate`、各 update 入口、周期性下降 |
| 缓冲配置 | [config_buffer.move](../../aptos-move/framework/topo-framework/sources/configs/config_buffer.move) | `upsert`、`extract_v2` 及所有 friend 调用者 |
| 标准库功能开关 | [features.move](../../aptos-move/framework/move-stdlib/sources/configs/features.move) | `change_feature_flags_for_next_epoch`、`on_new_epoch` |
| 委托份额与入池费 | [delegation_pool.move](../../aptos-move/framework/topo-framework/sources/delegation_pool.move) | `get_add_stake_fee`、原生份额同步 |
| 治理与强制结束 | [topo_governance.move](../../aptos-move/framework/topo-framework/sources/topo_governance.move) | `get_voting_power`、`reconfigure`、`force_end_epoch`、`toggle_features` |
| 创世安装 | [genesis.move](../../aptos-move/framework/topo-framework/sources/genesis.move) | `create_initialize_validators_with_commission` |
| 普通 DKG 总和边界 | [rounding/mod.rs](../../types/src/dkg/real_dkg/rounding/mod.rs) | `DKGRoundingProfile` 及 `sum::<u64>()` |
| Chunky 共用舍入 | [chunky_dkg.rs](../../types/src/dkg/chunky_dkg.rs) | target validator stakes 与 rounding 调用 |
| Move 单测入口 | [move_unit_test.rs](../../aptos-move/framework/tests/move_unit_test.rs) | `TEST_FILTER`、`move_framework_unit_tests` |
| 实际缓存生成 | [生成脚本](../../scripts/cargo_build_aptos_cached_packages.sh)、[命令实现](../../aptos-move/framework/src/main.rs)、[缓存说明](../../aptos-move/framework/cached-packages/README.md) | `update-cached-packages` 与生产 / test-only 输出 |

本次文档工作的验证范围为源码静态核对、整数数值样例和文档完整性。未执行框架构建、Move 单测、Rust 测试、节点演练；这些是后续实现必须完成的交付条件。
