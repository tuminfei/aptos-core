# PoC 改造核心测试用例

编写日期：2026-09-11。适用基线：当前工作区的 PoC 直接创世实现、统一 `PowerStore`、主网默认配置和最低 2 节点的受控测试网配置。

本文设计 **55 个核心用例**，用于实现回归、VM 验证及节点验收。用例中的“已有”表示源码中存在对应自动化断言，“部分”表示仅覆盖部分步骤或较低测试层级，“待补”表示仍需实现用例。**这些标记不是本轮执行结果**；本轮仅编写测试设计并核对源码、链接及整数算例。

## 1. 范围与判定规则

覆盖从创世分配原始算力，到上传、分配、权重安装、奖励结算、换届及节点恢复的完整链路。当前开发阶段不设计旧版算力迁移、旧资源布局升级和旧网络首次切换用例；现有测试中借助原生准备路径构造状态的部分，只复用其进入 PoC 后的业务断言。

| 级别 | 含义 | 执行要求 |
| --- | --- | --- |
| P0 | 涉及错误权重、错发奖励、状态不一致、越权或无法正常换届 | 每次相关实现变更执行；交付前补齐对应自动化 |
| P1 | 长时间运行、部署容量、故障恢复及边界组合 | 每日回归或版本验收；上线容量以目标环境实测为准 |

每个失败用例必须核对错误来源与业务状态，不能只断言“交易失败”。普通用户交易即使 Move abort，仍可能扣 gas、更新序列号和产生费用事件；“原子回滚”指相关 PoC、质押、配置、表项及业务事件没有部分提交。

跨节点比较选定同一 `ledger_version`。涉及惰性推进的池和持仓，比较当前 Epoch 的**逻辑生效值**，不能要求所有物理表项已经主动落盘。通过测试助手注入的极限值、损坏状态和 DKG 回调只用于隔离测试，不作为节点或密码流程已经通过的证据。

非 `entry` 操作通过现有治理脚本或框架流程触发；真实节点用例不使用绕过可见性或签名校验的内部调用适配器。

## 2. 测试环境与公共数据

### 2.1 配置组合

| 编号 | 用途与配置 | 需要固定的条件 |
| --- | --- | --- |
| M | 主网默认配置：`PocGenesisConfiguration::mainnet()` / `Default`，Open，最低 5 人，容量 128，每人初始 100 万 OHMP，1 TOPO/OHMP | 分别使用原样的 `mainnet_genesis_config()` 和当前 `Layout::default()` 经济参数；原生最低保证金仍须满足 |
| T2 | 测试网默认配置：`testnet()`，Controlled，最低 2 人，容量 128，每人初始 1 OHMP，每池质押 1 TOPO，最低权重 1 power，上限 1,000 OHMP | 使用现有测试创世参数：50% 增长率、1 小时 Epoch、10% APY、默认功能开关 |
| T2-F | 双节点运行与恢复测试 | 基于 T2，仅将 Epoch 缩短为 10 秒；单独记录此覆盖项。不能用它代替 T2 的原生配置兼容性验证 |
| F4/F5 | 四池功能测试、五池成员替换及真实 DKG | 采用 [现有节点 fixture][ND]：Open、最低 4 人、25% 增长率、每池 100 Octa 保证金、10 power 初始权重，保留比例 10000；普通/Chunky DKG 按用例切换 |
| A | 整数算术、账本与时序隔离用例 | 默认保留比例 10000；按用例构造明确的生效持仓。用 VM 执行时，先清空目标池未列入算例的创世持仓并等待生效，同时保留足够背景验证者 |

M/T2 的共同默认值为：`max_allocations=4`、`max_claim_pools=4`、`max_upload_users=32`、`retention_bps=9995`、`max_relative_period=10000`、`reward_epoch_limit=600060`。直接创世的算力周期为 60 Epoch，上传者为 `0x1`，初始费用分发限额为 0。

至少准备框架治理账户、上传者 O、验证者 owner/运营者/投票者、用户 U1～U32。权限用例使这些角色使用不同地址；另保留多个 owner 共用一个运营者和投票者的组合。每个独立用例从干净创世或固定快照开始。

### 2.2 单位与独立预期模型

```text
1 OHMP = 100_000_000 power
1 TOPO = 100_000_000 Octa
S = UNIT_SCALE = 2^32
J = INDEX_SCALE = 2^64
Q = 2^128

I[0] = J
I[p+1] = floor(I[p] * retention_bps / 10000)
version_units = floor(raw_power * S * J / I[effective_period])
position_units = floor(version_units * bps / 10000)
pool_power = floor(sum(position_units) * I[target_period] / (S * J))

bond_cap_power = floor(bond_octa * 100_000_000 / bond_octa_per_ohmp)
candidate = min(pool_power, bond_cap_power, max_power)
reward_base_octa = floor(installed_power * bond_octa_per_ohmp / 100_000_000)

delta_reward_index = floor(epoch_reward_octa * Q / active_pool_units)
claimable_octa = floor(accrued / Q)
```

算力版本 `units` 和周期 `index` 保持 `u128`，奖励指数和宽整数中间计算使用 `u256`。使用独立大整数参考模型逐步取整；不能将浮点 OHMP、逐用户展示算力之和或理论奖励比例直接作为整数预期。奖励参考模型应按每个 Epoch 的成员持仓累积权益，不调用被测模块的结算函数来生成预期。

| 算例 | 精确预期 |
| --- | --- |
| 周期 0、原始算力 17、全额分配 | `units = 17 * S`，生效权重 17 power |
| `retention=9000`，新版本原始算力 100，绑定下一周期指数 | `I=16602069666338596454`，`units=477218588444`，该周期全额分配权重为 **99** |
| 创世原始算力 1 OHMP，`retention=9995`，无新上传 | 首次边界 `I=18437520701672696840`，聚合权重 **99,949,999 power**，不是展示值四舍五入后的 100,000,000 |
| 2.5 TOPO/OHMP，周期 0 原始算力各 17，保证金 `[42,43,100,100]` Octa | 最终权重 `[16,17,17,17]`，计奖基数 `[40,42,42,42]` Octa，原始算力及完整 units 保留 |
| 两名用户 units 为 `10*S`、`30*S`，该期实际入账 40 Octa | 分别领取 10、30 Octa；可用 1 Octa 通胀加 39 Octa 费用构造 |
| 两名用户各 `S`，连续两期各入账 1 Octa | 第一期各可领 0，保留 `Q/2` 权益；第二期各可领 1 Octa |

### 2.3 公共观测与不变量

| 对象 | 观测入口或资源 | 必须核对的内容 |
| --- | --- | --- |
| 全局状态 | `poc_accounting::get_config`、`Configuration`、`stake::get_installed_reward_context` | 已安装 Epoch、首次 PoC Epoch、当前/待生效参数、旧期/新期奖励上下文 |
| 算力与时钟 | `poc_power_store::get_accounting_snapshot`、`get_normalization_clock`、`next_boundary_epoch`、原始版本查询 | 当前/下一版本、生效周期、绑定指数、倒计时；查询无业务写入 |
| 分配与奖励 | `poc_accounting::get_allocations`、`get_position`、`get_pool` | 当前与未来 units、最多两个未来生效时点、可领整数额、小数权益、金库与奖励指数 |
| 共识目标 | `stake::preview_epoch_transition`、`ValidatorSet`、`EpochPlan`、`PrecomputedValidatorSet` | 地址顺序、公钥、验证者索引、每池权重、总权重、截止时间和计奖基数 |
| 质押与治理 | `stake::get_stake`、原生质押/奖励/治理/Block 配置 | 保证金组成、锁仓状态；TOPO 配置资源与对应原生创世逐字节比较 |
| 事件 | `PowerNormalized`、`PowerUpdateStagedEvent`、`AllocationScheduled`、`PoCEpochInstalled`、`PoCRewardCredited`、`PoCRewardClaimed` | 发出时点、主体、周期、金额及是否重复；零金额不强求领奖事件 |

所有相关用例共同检查：池逻辑 units 等于生效持仓之和；当前及未来聚合不超过 `2^120`；持仓/池的未来变更最多两条；奖励指数单调不减；累计领取不超过累计入账；`vault = 累计入账 - 累计领取`；检查点引用归零后可释放；已安装权重只来自 `ValidatorSet`；冻结计划与 PVS 成对存在、成对清理。

## 3. 核心测试用例

下表每行是一个用例，行内参数组合作为子用例执行。覆盖状态按该行整体描述判定；标记“部分”的用例须补充未覆盖的组合。

### 3.1 创世与默认配置

| ID / 级别 | 前置条件与步骤 | 预期结果 | 现有自动化 / 补充点 |
| --- | --- | --- | --- |
| GEN-01 / P0 | M：分别以主网原生配置的默认 10 人、Layout 的 5 人/最低保证金和 128 人/最高保证金生成创世；再尝试 4 人 | 合法组合安装 Epoch 1；每人获配 100 万 OHMP；4 人拒绝；四类 TOPO 配置资源保持原值；`Default` 使用主网值 | 已有：[VM] `poc_mainnet_defaults_initialize_without_changing_topo_config`、[LY] 两项默认值测试 |
| GEN-02 / P0 | T2：分别用 2、5、10 人生成创世；再用 1 人 | 合法组合各安装 1 OHMP 权重、全额分配、PoC 奖励上下文；1 人拒绝；现有 TOPO 参数不变 | 已有：[VM] `poc_testnet_defaults_initialize_without_changing_topo_config`、`poc_testnet_defaults_reject_single_validator` |
| GEN-03 / P0 | 新建 PoC 创世，重新加载生成的写集；多个 owner 共用运营者与投票者 | 每个 owner 的 PowerStore 和本池分配独立，分配为 10000 bps、佣金为 0；Epoch 均为 1、周期 0、下一边界 61；上传者 `0x1`、费用限额 0；恰好一次安装，无 Epoch 0 奖励 | 部分：[VM] `poc_genesis_builder_executes_and_reloads_production_bundle`、[GE] `poc_genesis_installs_one_epoch_without_epoch_zero_rewards`；补零佣金无额外分成的显式验收 |
| GEN-04 / P0 | 原始算力各 100 power，保证金 `[20,30,30,30]` Octa，比例 1 TOPO/OHMP | 最终权重被限为 `[20,30,30,30]`；每个 owner 与池仍保有 `100*S` units，不能只写受担保部分 | 已有：[VM] `poc_genesis_builder_preserves_full_allocation_when_bonds_cap_power` |
| GEN-05 / P0 | 参数化尝试：初始算力 0；Open+最低 2 人；Controlled+最低 2 人+20% 动态增长；最低人数等于容量；再恢复合法参数 | 无效组合在创世生成前后置校验阶段拒绝，不生成可用的部分创世；Controlled+2 人+50% 合法。Open 仍要求至少 4 人及集中度约束 | 部分：[VM] 零算力拒绝；[AC] `poc_dynamic_growth_rejects_unreplaceable_committee`、`poc_dynamic_minimum_equal_to_validator_limit_rejected`；补齐测试网组合矩阵 |
| GEN-06 / P0 | 在已运行链重放创世专用写算力/创建 PoC 验证者操作，或尝试重复初始化 PowerStore；另运行普通原生创世入口 | 重放和重复初始化拒绝，原始版本、基线和时钟不重置；普通原生创世仍沿用其显式入口行为 | 部分：[GE] `poc_genesis_entry_rejects_operating_chain`、`poc_native_genesis_remains_unprepared`；[PS] `poc_initialization_cannot_reset_retention_or_versions`；补运行期直写原始算力的拒绝断言 |

### 3.2 原始算力、双版本与衰减

| ID / 级别 | 前置条件与步骤 | 预期结果 | 现有自动化 / 补充点 |
| --- | --- | --- | --- |
| PWR-01 / P0 | 周期 P 中上传 `target_period=P+1` 的新绝对原始算力；分别查询当前、E+1、边界 B | 上传按 `I[P+1]` 生成 units 并同步相关分配；B 前不改变当前权重，B 才应用下一原始版本；不得将上传值当作增量 | 已有：[PV] `poc_upload_allocation_order_independence`、`poc_units_keep_their_effective_period_index` |
| PWR-02 / P0 | 同用户、同目标周期依次上报 100、100、200；覆盖同批重复及跨交易重复 | **首次写入 100 生效**，后续不同值也不覆盖；不重复增加 units/refs；只对实际新增版本发出标准化及上传事件 | 部分：[PV] `poc_batch_first_write_and_explicit_zero_version`；补跨交易与两类事件数量断言 |
| PWR-03 / P0 | 已有用户下一周期上传 0；新用户首次上传 0；已有用户同批 `[0,999]` | 已有用户保存明确零版本并在 B 清除未来算力，历史奖励仍可领；新用户零值不建记录；同周期 999 不覆盖先写的 0 | 已有版本断言：[PV] `poc_batch_first_write_and_explicit_zero_version`；历史奖励与 REW-06 联合执行 |
| PWR-04 / P0 | 连续上传三个周期的版本；跨数个周期不访问，再查询并领取奖励 | 最多保存两个原始版本槽；新写入淘汰旧槽后，当前有效 units 仍使用原生效周期指数；旧奖励可凭检查点结算；重复查询无写入 | 已有：[PV] `poc_version_rollover_preserves_current_units`、`poc_versions_remain_readable_after_several_periods`；[PS] `poc_snapshot_is_read_only` |
| PWR-05 / P0 | 上传者 O 成功上传；普通用户上传；治理将上传者从 O 改为 O2；分别由 O、O2、框架继续上传；重复设置相同上传者 | 普通用户和被替换的 O 拒绝；O2 与框架可操作；未授权失败不改变任何版本；地址未变不重复发 `OperatorChangedEvent` | 待补完整权限矩阵；行为依据 [PW] `stage_batch_update`、`set_operator` |
| PWR-06 / P0 | 未冻结且期限有效，分别上传空批、1 项、32 项、33 项；构造向量长度不等、当前/过去/跨过下一周期的 target；令批次后项触发容量错误 | 空批无业务变化；1/32 合法；33、长度或周期非法拒绝。重复地址按原始输入长度计批次上限；后项失败回滚先前合法项及事件 | 部分：[EE] `poc_manifest_max_upload_allocation_and_claim`、`poc_boundary_only_capacity_failure_rolls_back_batch`；补齐输入矩阵 |
| PWR-07 / P0 | 使用 60 Epoch 周期从创世推进到 Epoch 60、61、121；期间不上传；另使用 9000 保留比例测试新版本取整 | Epoch 60 仍为周期 0；61/121 各只递推一次指数；按 2.2 节核对首次 1 OHMP 衰减值和 100→99 反例；不逐用户重算标准化版本 | 部分：[PS] `poc_clock_genesis_sixty_epochs`、`poc_normalization_rounding_and_maximum`；补 T2 默认算力的首周期集成断言 |

### 3.3 算力分配与两个生效时点

| ID / 级别 | 前置条件与步骤 | 预期结果 | 现有自动化 / 补充点 |
| --- | --- | --- | --- |
| ALC-01 / P0 | 用户设置全额、部分、空分配；无算力用户先配置再首次上传；分别输入重复池、未启用池、0 bps、总和 10001、向量长度不等 | 合法分配最早 E+1 生效；未分配部分不计权；无算力可先配置，后续上传自动同步；非法参数整笔拒绝 | 部分：[PV] `poc_allocation_before_first_upload`；[AC] `poc_explicit_zero_ratio_rejected`、`poc_duplicate_pool_rejected`；补完整输入矩阵 |
| ALC-02 / P0 | A：当前原始算力 100、当前比例 50%，上传下一周期 200 后将比例改为 25%；另从同一快照交换操作顺序 | 当前持仓 `50*S`；E+1 为 `25*S`；B 为 `50*S`。两种顺序的当前状态、两条变化、池增减与 refs 一致 | 已有：[AC] `poc_two_boundary_rebuild`、`poc_upload_and_allocation_commute`；[PV] `poc_upload_allocation_order_independence` |
| ALC-03 / P0 | 在 `E+1=B` 时组合原始算力与比例变更；再构造 100×50%→200×25% 的等量情况 | 同一 Epoch 只保留最终一条变化；最终 units 不变时省略变化及其引用，不能先增后减重复应用 | 已有：[AC] `poc_coincident_boundary_omits_unchanged_units`；[PV] `poc_same_boundary_cancels_zero_change` |
| ALC-04 / P0 | 同 Epoch 连续覆盖分配，再覆盖回 active 比例；随后跨过 E+1/B，再修改一次 | 旧未来链被完整撤销并重建；不产生孤立引用或负数；保留尚有效的未来原始版本；两条成熟变化先结算，再写新链 | 已有：[AC] `poc_cover_pending_back_to_active_preserves_future_version`、`poc_two_matured_changes_then_new_version` |
| ALC-05 / P0 | `max_allocations=4`：active 已占 4 池，尝试 pending 再指向其他 4 池；另在 active 为空时，将 pending 4 池覆盖为另外 4 池 | 第一种 active/pending 配置并集为 8，必须拒绝；第二种每份有效配置并集不超过 4，可成功，但撤销和新建合计访问 8 池；不得将访问上限误写成 4 | 部分：[EE] `poc_disjoint_four_pool_replacement_visits_eight`；补 active/pending 超并集的成对反例 |
| ALC-06 / P0 | 同一 Epoch 两名用户在同池等量退出/加入，池净 units 不变；前后分别入账奖励并领取 | 仍创建奖励检查点，旧奖励属于旧持仓；新持仓不继承旧指数；用户结算后 refs 正确减少至可释放 | 已有：[AC] `poc_net_zero_change_retains_reward_checkpoint` |

### 3.4 保证金、权重与成员变更

| ID / 级别 | 前置条件与步骤 | 预期结果 | 现有自动化 / 补充点 |
| --- | --- | --- | --- |
| WGT-01 / P0 | 分别使原始聚合算力、保证金、`max_power` 成为最小项；执行 2.2 节的 2.5 TOPO/OHMP 算例；在 `min_power-1/min_power` 比较准入 | 权重取三项最小值；使用宽整数限幅后转 u64；保证金上限与计奖基数各独立向下取整；低于整数门槛才排除，units 不随限幅缩减 | 部分：[VM] `poc_genesis_builder_rounds_bond_caps_and_reward_bases_in_octa_per_ohmp`；[ST] `poc_binding_bond_cap_preserves_user_reward_ratio`；补完整限幅/门槛交叉组合 |
| WGT-02 / P0 | 构造 active、pending_active、pending_inactive、inactive；锁仓到期分别位于截止时间前、相等、后；在 DKG 等待中越过到期时间 | 只计 active、pending_active、未到期 pending_inactive；inactive 和已到期部分不计。冻结后沿用缓存 cutoff 推算，不因完成时间变更而重选 | 部分：[DF] 保证金推算差分、[ST] `poc_claim_during_freeze_keeps_target_and_cutoff`；补各余额与相等时点的独立断言 |
| WGT-03 / P0 | 当前四池权重各 10、最低 4 人/10 power，一人退出、一名候选申请；分别以 20%/25% 动态增长配置验收 | 20% 组合配置拒绝；25% 预算为 10，合格替补最终获 10 并完成换届。正常运行不得重新使用创世免增长限制 | 已有：[AC] 动态增长配置测试；[ST] `poc_growth_initialization_and_replacement`；[ND] `poc_dkg_replaces_validator_with_growth_budget` |
| WGT-04 / P0 | 上例改为两名候选各要求 10；另测试下降权重及多个候选分配后不足 1 的取整情况 | 预算 10 被分为 5/5，低于最低 10 而剔除；余量不重分配，目标不足则延期/拒绝退出；取消多余待加入后单替补可成功。待加入权重及 `total_joining_power` 不预增 | 已有：[ST] `poc_growth_drops_and_flooring`、`poc_competing_replacements_reject_unsafe_leave`；[ND] 替补测试 |
| WGT-05 / P0 | Open 模式五池等权 20，将四池算力转向四个新池，构造最终 `[20,5,5,5,5]`；撤回分配修复；另在隔离 Controlled 配置检查同一向量 | Open 按最终权重拒绝 50% 集中度，不能仅凭人数合格放行；修复后可换届。Controlled 允许其部署信任模型，但不改变共识 quorum 算法 | 部分：[ST] `poc_open_concentration_and_controlled_mode`；[EE] `poc_parallel_hot_pool` 覆盖集中与撤回，补五旧池到四新池的完整交易链 |
| WGT-06 / P0 | 运营者申请退出、取消自主退出；换运营者后由旧/新角色重试；治理移除后尝试取消；候选容量满时取消退出 | 退出前执行目标预检，失败不留下部分队列。合法取消恢复旧权重、索引、统计、费用，不加预算、不结奖；旧运营者与撤销治理移除的请求拒绝；容量不足须先腾出名额 | 部分：[ST] `poc_voluntary_cancel_preserves_old_indices`、`poc_governance_revokes_voluntary_cancel`、`poc_capacity_v8_union15_deferred16_repair`；补运营者轮换矩阵 |

### 3.5 奖励结算、领取与金库

| ID / 级别 | 前置条件与步骤 | 预期结果 | 现有自动化 / 补充点 |
| --- | --- | --- | --- |
| REW-01 / P0 | 两用户贡献 `10*S:30*S`；10 TOPO/OHMP 比例、100 Octa 保证金，将 40 power 限为 10；旧期入账 1 Octa 通胀与 39 Octa 费用 | 计奖基数为 100 Octa；两用户分别获得 10/30 Octa；只提供保证金而无算力持仓者不分享 PoC 金库；限幅不改变池内比例 | 已有比例与本金断言：[ST] `poc_binding_bond_cap_preserves_user_reward_ratio`；补无算力保证金所有人的独立领取断言 |
| REW-02 / P0 | 在 Epoch E 中修改保证金比例、奖励率、费用开关/限额或奖励率来源功能；准备并完成 E+1，DKG 等待期间继续出块 | E 按已安装计奖基数和 closing context 结算；统计与实际费用继续累计，提交时按旧索引结算；新参数只影响新期，上下文 Epoch 与委员会一致 | 部分：[ST] `poc_context_rate_changes_only_after_install`、`poc_feature_rate_switch_keeps_closing_context`；[DF] 五路径差分；补默认创世下的组合回归 |
| REW-03 / P0 | 改变成功/失败提案比例；覆盖无提案、长 Epoch、费用分发关闭、限额 0、正限额及超限费用；隔离测试零 units 和同 Epoch 零奖励重复入账 | 通胀仍使用原生表现公式和宽整数；无有效表现的对应通胀为 0；费用按开关/限额分发；费用限额 0 不关闭 gas 或通胀。零 units 时权重和奖励须为 0，不做除法；零奖励也不能同 Epoch 重复入账 | 部分：[ST] `poc_rewards_long_epoch_and_fractional_rate`、`poc_reward_vault_does_not_compound_native_stake`；[AC] `poc_zero_reward_still_prevents_double_credit`；补完整开关与零 units 矩阵 |
| REW-04 / P0 | A：两用户各 `S`，连续两期各入账 1 Octa；第一期先查询、领取 0，再覆盖配置并恢复原比例，确保两期生效持仓仍各为 `S`；第二期重新领取 | 第一期各保留 `Q/2` 小数权益；普通更新和零额领取不丢权益；第二期各领取 1；同一奖励再次领取为 0，查询结果与实际领取一致 | 部分：[AC] `poc_fractional_entitlement_survives_claim`、`poc_query_and_claim_share_matured_reward_segments`；新增参数组使用独立模型核对 |
| REW-05 / P0 | A：池 units=`3*S`，单期奖励 1 Octa 制造池级除法余量；下一期等量更换全部持仓后继续结奖 | 每 Epoch 独立计算 `floor(R*Q/U)`；池级除法余量不进入下一期指数。新用户只能取得新期收益；旧用户小数权益留在旧持仓，金库余额可大于当前整数可领额之和 | 部分：[AC] `poc_independent_epoch_reward_model`、`poc_net_zero_change_retains_reward_checkpoint`；补带非零池级余量的等量换仓组合 |
| REW-06 / P0 | 用户经历两个成熟变化后长期不操作；池退出委员会、原始版本滚动，再查询及领取；隔离注入检查点缺失、引用为 0 或下溢 | 退出池新计奖基数为 0，仍可领取旧收益；分段使用历史检查点，不推进全局 Epoch；合法引用归零后释放。损坏状态的查询/领取明确拒绝，不能静默跳过收益或重复支付 | 部分：[AC] `poc_exited_pool_claim_advances_only_installed_epoch`、`poc_two_matured_changes_then_new_version`、`poc_missing_checkpoint_aborts_readonly_query`、`poc_checkpoint_reference_underflow_aborts`；补与版本滚动的完整组合 |
| REW-07 / P0 | PoC 结奖、领取后再次领取；比较质押余额；批量领取输入重复池或超过 4 池；隔离注入金库不足 | 金库独立于原生本金，不自动复投、不重复计入原生份额；重复池/超限整笔回滚，包括第一池已执行的支付；金库不足报错且保留权益 | 部分：[ST] `poc_reward_vault_does_not_compound_native_stake`；[EE] `poc_frozen_direct_setters_and_claim_rollback`；[AC] `poc_underfunded_vault_aborts_without_resetting_entitlement`；补领取 5 池边界 |

### 3.6 Epoch 预检、延期和计划提交

| ID / 级别 | 前置条件与步骤 | 预期结果 | 现有自动化 / 补充点 |
| --- | --- | --- | --- |
| EPO-01 / P0 | 从同一不可变快照创建五份独立状态，分别走同步、普通 DKG、Chunky DKG、超时和治理强制完成 | 每条路径的目标地址顺序、公钥、units、权重、计奖基数、closing context、最终上下文、金库、指数与结奖事件一致；重复完成不重复入账 | 已有：[DF] `poc_same_snapshot_transition_targets_and_reward_bases`；该测试的内部 DKG 结果注入不覆盖真实 transcript 验证，后者见 SYS-04 |
| EPO-02 / P0 | 使目标人数不足、总权重为 0 或集中度不合格；至少连续触发 16 次区块预检，再用合法入口修复 | 返回 Deferred，旧委员会继续服务；不冻结、不结奖、不推进 Epoch/算力周期，不转换到期质押。允许区块时间、旧期表现和费用继续累计；修复后恰好提交一次 | 已有相关链路：[ST] `poc_deferred_keeps_epoch_and_allows_repair`、`poc_capacity_v8_union15_deferred16_repair`；[EE] `poc_preparation_first_install_and_deferred_repair`；各失败原因分别执行 |
| EPO-03 / P0 | 一笔治理事务先改配置，再要求立即换届；使目标不合法后执行；随后恢复合法目标重试 | 失败回滚前面的参数、缓冲配置、PoC 状态与 Epoch；合法重试整体成功；不得留下“配置已安装、委员会未更新”的状态 | 已有：[EE] `poc_governance_failure_rolls_back_parameters_and_epoch` |
| EPO-04 / P0 | 冻结后重复启动/查询；隔离构造仅有计划、仅有 PVS、目标 Epoch 错配、提交错误 Epoch | 有效计划被复用，返回原 cutoff 和目标；不成对或错配按协议状态错误拒绝，不能返回普通 Deferred 或实时重选；失败不部分清理缓存 | 部分：[ST] `poc_orphan_pvs_rejected`、`poc_plan_epoch_mismatch_rejected`、`poc_install_rejects_wrong_target_epoch`；补仅计划存在及完整回滚快照 |
| EPO-05 / P0 | 冻结有效计划，等待真实区块超时或调用授权强制完成；完成后再次运行超时检查，并送入迟到的旧会话结果 | 首次只安装缓存目标，旧期每池奖励只结算一次；计划/PVS、旧会话和冻结状态正确清理；重复 watchdog 不重复提交，迟到结果不能进入新 Epoch | 部分：[EE] `poc_block_metadata_watchdog_commits_cached_plan_once`、[DF] 重复完成断言、[ND] 冻结恢复；补迟到结果的外部验证路径 |
| EPO-06 / P0 | 周期边界附近冻结，等待时间跨过原锁仓到期及多个名义 Epoch；期间查询目标、记录正常出块，最后完成 | cutoff、目标算力和成员不变；旧期统计仍可增长；完成仅推进一个 Epoch，周期只按成功提交推进一次；不得按经过的墙上时间补结多个周期 | 部分：[ST] `poc_claim_during_freeze_keeps_target_and_cutoff`、[EE] watchdog、[PS] 时钟测试；补真实节点跨边界长等待组合 |

### 3.7 冻结期间的权限与入口

| ID / 级别 | 前置条件与步骤 | 预期结果 | 现有自动化 / 补充点 |
| --- | --- | --- | --- |
| FRZ-01 / P0 | 已冻结有效计划：上传新版本、重复上传、改分配、改上传者/周期长度、启用池、排定/取消 PoC 参数 | 全部拒绝且没有相关业务写入；幂等或重复请求也不能绕过冻结检查；原计划/PVS 字节保持一致 | 部分：[EE]、[FR] 覆盖配置拒绝；[PW] 上传入口先检查冻结；补逐入口参数化矩阵 |
| FRZ-02 / P0 | 冻结中通过直接入口和 `*_with_cap`/staking contract/vesting/delegation 转调追加、解锁、重新激活、提取、延长锁仓；尝试加入、退出、取消和治理移除 | 拒绝所有会改变保证金、截止时间推算或候选资格的写入；外层委托份额与费用也随事务回滚 | 部分：[CF] 五类能力转调；[ST] `poc_frozen_capability_lockup_rejected`；其余可达包装入口逐项补表 |
| FRZ-03 / P0 | 冻结中修改共识公钥、网络地址、原生质押/奖励参数、相关 feature、缓冲配置或直接安装配置；完成后重试合法修改 | 冻结中拒绝且不替换 PVS 所用配置；正常出块统计和费用累计允许继续；完成后授权修改恢复可用，并按原生规则生效 | 部分：[FR] `poc_public_config_install_is_frozen`、`poc_buffered_config_set_is_frozen`、`poc_config_set_resumes_after_finish`；[EE] setter 回滚；补公钥/地址入口矩阵 |
| FRZ-04 / P0 | 冻结前留下历史可领收益；冻结中查询并领取，再重复查询/领取，随后提交原计划 | 领取成功，金额符合冻结前已生效权益；只改变领取相关状态，不改变目标、cutoff、保证金或未来分配；最终仍提交原计划且不重复结奖 | 已有：[ST] `poc_claim_during_freeze_keeps_target_and_cutoff`；[EE] `poc_frozen_direct_setters_and_claim_rollback` |

### 3.8 治理配置与既有代币语义

| ID / 级别 | 前置条件与步骤 | 预期结果 | 现有自动化 / 补充点 |
| --- | --- | --- | --- |
| GOV-01 / P0 | 未冻结时排定 E+1 的 PoC 参数，覆盖并取消，再提交；尝试过去/当前 Epoch、超部署上限、无权限修改 | 待生效配置能替换/撤销，当前权重与旧期奖励基数不提前变化；非法修改回滚；不重置首次 PoC Epoch、指数基线或奖励期限 | 部分：[AC] `poc_cancel_params_and_reschedule_keep_baseline`；[GE] `poc_genesis_defaults_remain_governable`；补直接创世后的目标 Epoch/权限矩阵 |
| GOV-02 / P0 | 默认边界 B=61，在周期中途将长度 60 改为 2；另设置 0 和使边界加法溢出的长度 | 已确定边界仍为 61，提交到 61 后下一边界为 63；已排定到 B 的变化不顺延；0/溢出拒绝，保留比例和指数基线不重置 | 部分：[PS] `poc_period_length_maximum_preserves_boundary`、`poc_period_length_rejects_boundary_overflow`；补 60→2 的明确断言 |
| GOV-03 / P0 | PoC 生效后，构造代币保证金 100 Octa、共识权重 10 power 的池；查询治理投票权与委托入池费；分别覆盖 Open/Controlled | 共识投票使用 10 power，治理权重仍按原生代币口径；已安装 PoC 上下文的委托入池费为 0；不把 OHMP 或 units 作为治理代币金额 | 已有：[DG] `poc_governance_open_mode_keeps_token_weight`、`poc_governance_static_mode_keeps_token_weight` |

### 3.9 数值、容量与支持期限

| ID / 级别 | 前置条件与步骤 | 预期结果 | 现有自动化 / 补充点 |
| --- | --- | --- | --- |
| NUM-01 / P0 | 原始算力取 0、1、u64 上限；指数取 J、`2^40`、`2^40-1`；保留比例取 0、9995、10000、10001；验证默认 P_MAX=10000 及 9900 下的 1655/1656 | 合法输入按精确宽整数模型计算；单版本 units 可存入 u128；指数低于下界或比例非法拒绝。9995 的 `I[10000]=124137862714582947`；9900 的 1655 有效、1656 无效；超支持周期的新版本不接收 | 已有主要边界：[PS] 归一化与期限测试、[AC] 算力换算测试；补默认参数边界报告及非法比例矩阵 |
| NUM-02 / P0 | 分别使当前、E+1、仅 B 的池 units 达到 `2^120` 和超过上限；测试净结果合法但撤销/重建旧链较大的情形 | 等于上限合法、超过上限原子拒绝；仅 B 超限也在写入阶段拒绝，不能等换届失败；合法替换不能因临时累加而误拒；失败后原计划仍可提交 | 已有：[AC] `poc_future_pool_capacity_rejected`、`poc_final_capacity_accepts_replacing_large_chain`；[EE] `poc_boundary_only_capacity_failure_rolls_back_batch` |
| NUM-03 / P0 | 配置检查 `65536*max_power` 的上下界；隔离构造两个权重各 `2^63` 的目标；验证零总权重；覆盖普通及 Chunky 目标生成 | 总权重必须在 `1..=u64::MAX`；违规在进入 DKG 前被拒绝。先限幅再窄化，不能仅检查单池或 u128 总和合法 | 部分：[AC] `poc_dkg_conservative_total_bound`、[ST] `poc_actual_total_rejects_dkg_overflow`；补两条 DKG 入口的拒绝断言 |
| NUM-04 / P1 | 用小 H 快速跨过期限，并对默认 H 做大整数边界校验；构造全 H 无人领取、`H*R_MAX=u64::MAX`/再加 1、`F+H` 溢出；提案计数接近上限 | 支持区间严格为 `F<=epoch<F+H`；超期目标不提交，不能重置 F/指数绕过；每池累计入账和金库不溢出；计数器溢出明确拒绝，合法长期统计用宽整数计算 | 已有：[AC] `poc_full_reward_horizon_maximum_pool`、`poc_full_reward_horizon_large_index`、`poc_reward_lifetime_rejects_u64_max_plus_one`；[ST] 提案计数边界；补默认部署的统一报告 |

### 3.10 节点运行、恢复、并行与性能

| ID / 级别 | 前置条件与步骤 | 预期结果 | 现有自动化 / 补充点 |
| --- | --- | --- | --- |
| SYS-01 / P0 | 从 T2 真实创世启动两个节点，保留默认功能开关；提交至少 10 笔普通转账、一次算力上传及一次分配操作；读取同版本资源 | 两节点持续出块、交易可查询；PoC 初始配置与 GEN-02 相同；当前权重不因未生效上传/分配立刻改变；gas 收费正常 | 待补双节点真实 smoke；现有 [VM] 只证明 T2 创世写集，不能替代此项 |
| SYS-02 / P1 | T2-F 在 Epoch 开始后停止一个等权节点；等待在途提交稳定，观察 30 秒；恢复节点并提交新交易，等待下一次换届 | 停机时剩余 50% 权重不能产生新 quorum，稳定后无新提交、无重复结奖；恢复后能继续提交并安装后续 Epoch，两节点同版本状态一致 | 待补双节点停机/恢复用例；建议恢复等待上限 90 秒、同版本追赶 30 秒，记录超时阶段 |
| SYS-03 / P0 | F4 同步换届并重启一节点；F5 运行退出、回加和替补，再比较当前委员会全部节点 | 换届和重启后使用已安装权重继续共识；重新加入节点完成追赶；当前成员的顺序、公钥、权重和上下文一致；不把已离任节点持续同步作为通过条件 | 已有：[ND] `poc_genesis_restart`、`poc_dkg_replaces_validator_with_growth_budget` |
| SYS-04 / P0 | F4 分别开启普通 DKG、普通+Chunky DKG；再暂停 DKG、重启节点、恢复原会话并授权强制完成 | 真实 transcript 通过现有验证路径；普通/Chunky 使用同一 PVS 目标，相关密钥安装到同一目标 Epoch；冻结重启继续原计划，最终每池只结奖一次 | 已有：[ND] `poc_dkg_installs_session_targets`、`poc_chunky_dkg_installs_same_session_targets`、`poc_frozen_dkg_force_end_and_restart` |
| SYS-05 / P0 | 同一块包含多用户向热门池更新；比较顺序执行与 Block-STM 完整输出；扩展混合上传、覆盖分配、领取及失败交易；用多个固定随机 seed 重放 | 状态、事件、成功/失败结果一致，无重复引用或奖励；参考模型逐 Epoch 核对权益与金库；失败交易回滚本笔业务修改 | 部分：[EE] `poc_parallel_hot_pool` 已比较完整输出；[AC] `poc_randomized_history_seed_1`、`poc_randomized_history_seed_7`、`poc_randomized_history_seed_31337` 覆盖账本历史；补混合并行负载 |
| SYS-06 / P1 | 128 候选容量下运行换届、合法成员集合并集、连续 Deferred 与修复；32 用户×4 池上传、4 池领取、8 池覆盖；保持活跃集合不变而增加历史用户数 | 业务不变量全部成立；收集 gas、读写 key/字节、事件大小、Block-STM 重执行和节点延迟。Epoch 新增 PoC 工作量不随历史总用户数线性增长；在实际目标硬件与区块预算内通过 | 部分：[LY] 128 人创世、[EE] 32×4/8 池测量、[ST] 8 候选样本；**待补 128 候选真实运行容量与吞吐验收** |

## 4. 优先补齐的自动化

| 顺序 | 用例 | 原因与完成标准 |
| --- | --- | --- |
| 1 | SYS-01、SYS-02 | 双节点是最新默认配置。新增真实建网、交易、失去 quorum 后停止提交、恢复后继续换届的 smoke，不能复用四节点结果代替 |
| 2 | PWR-05、PWR-06、GEN-05、GOV-01 | 参数与身份矩阵直接决定准入和写入正确性；补精确错误模块/代码、业务写集与事件回滚断言 |
| 3 | FRZ-01～03 | 枚举源码中所有可达直接入口、能力入口和包装调用；每项至少一个冻结拒绝及完成后恢复的用例，新增入口时更新矩阵 |
| 4 | PWR-07、WGT-02、EPO-06 | 组合测试默认 9995 衰减、边界上传、到期保证金与异步等待；确保固定 cutoff 和成功提交计数共同生效 |
| 5 | EPO-04、EPO-05、NUM-03 | 补齐损坏缓存、迟到会话结果及两种 DKG 数值拒绝；记录拒绝前后目标与金库状态 |
| 6 | SYS-05、SYS-06 | 扩展混合并行历史与 128 候选实际运行。已有小规模 gas 样本和创世容量不等于节点吞吐已通过 |

## 5. 执行方式

以下命令从仓库根目录运行，执行当前已经实现的自动化；“部分”及“待补”的新组合必须落成测试后才能计入通过。测试用例编号不能直接作为现有 Rust/Move 测试过滤器。

### 5.1 记录基线与框架缓存

记录提交号、工作区差异摘要（包含未跟踪的 PoC 源码）、原生与 PoC 配置、工具版本、执行器模式和硬件。使用真实节点时还需记录节点二进制摘要；不能只记录 Git HEAD 就忽略工作区改动。

```bash
git rev-parse HEAD
shasum -a 256 aptos-move/framework/cached-packages/src/head.mrb
```

若修改了 `aptos-move/framework/` 下的 Move 源码，须先重新生成缓存，再测试使用生产 bundle 的 Rust/节点路径：

```bash
scripts/cargo_build_aptos_cached_packages.sh
cargo build --profile ci -p aptos-cached-packages
```

本测试设计文档本身不修改框架，不因编辑文档重建 bundle。

### 5.2 Move、创世和 VM 回归

```bash
REPORT_STATS=1 TEST_FILTER=poc_ cargo test --profile ci -p topo-framework \
  --test move_unit_test move_framework_unit_tests -- --nocapture

cargo test --profile ci -p aptos-vm-genesis -p aptos-genesis

E2E_PARALLEL_EXEC=1 cargo test --profile ci \
  --config 'profile.ci.package.e2e-move-tests.opt-level=0' \
  -p e2e-move-tests tests::poc_consensus:: -- --nocapture --test-threads=1
```

E2E 使用完整模块前缀，包含其内部 `transition_differential` 子模块。`opt-level=0` 仅降低测试包自身优化级别以减少编译等待，不改变生产框架或依赖的精度、逻辑与断言。若后续修改 Rust，按修改包补 `cargo check`、仓库 Clippy 参数检查及 nightly 格式检查。

### 5.3 真实节点

```bash
cargo build --profile ci -p aptos-node --features failpoints,smoke-test

SMOKE_TEST_BIN_DIR="$PWD/target/ci" cargo test --profile ci -p smoke-test \
  --features aptos-config/failpoints poc:: -- --test-threads=1 --nocapture
```

当前命令运行 [ND] 中的五个四/五节点场景。**SYS-01、SYS-02 尚需新增双节点 smoke**，加入同一模块后才会随此命令执行。故障注入只用于隔离测试网络；节点二进制、缓存与测试程序必须来自一致的源码基线。

当前同步/普通 DKG 的单次 Epoch 等待一般为 90 秒，Chunky 用例为 240 秒，同版本追赶为 30 秒；成员用例包含多次等待，应分别记录。节点编译和启动耗时单独统计，不用提高业务超时来掩盖停滞。

### 5.4 执行分层

| 触发时机 | 范围 |
| --- | --- |
| 每次 PoC 相关变更 | 受影响 P0 的 Move/Rust 回归；算术或时序修改增加独立模型与 VM 用例 |
| 每日集成 | 全部已实现 P0、双节点/四节点/五节点 smoke、多个固定随机 seed；记录未实现组合 |
| 默认配置或框架发布前 | M/T2 原参数创世、T2-F 恢复、真实普通/Chunky DKG、全部 P0 和适用 P1，核对最终节点与 bundle 摘要 |
| 容量或性能声明前 | SYS-06 在目标硬件和实际区块预算下执行；填写用户量、候选数、负载、重执行、延迟及读写规模，不将 VM 双执行比较耗时当作 TPS |

## 6. 验收与结果记录

每个子用例至少保存：

| 字段 | 内容 |
| --- | --- |
| 用例与变体 | 例如 `PWR-06 / 33 users / parallel`；使用的 M/T2/T2-F/F4/F5/A 配置 |
| 基线 | 提交号、工作区差异摘要、bundle/节点摘要、完整有效配置 |
| 输入与执行 | 操作顺序、角色地址、交易哈希、开始/结束 ledger version；不记录私钥 |
| 预期 | 精确整数、状态/事件差异、错误模块与 abort code 或 Deferred 原因 |
| 实际 | 查询与交易结果、相关资源/表项快照、事件、gas、分阶段耗时 |
| 结果 | 未执行 / 通过 / 失败 / 阻塞；失败原因、日志位置和复现 seed |

交付验收要求：

1. P0 的每个适用子用例均有当前源码与最终 bundle 的执行证据；未实现、跳过、超时均不能记为通过。
2. 发生业务拒绝时验证原子性；正常提交时验证权重、奖励上下文、金库守恒和计划生命周期，不能只检查最终 Epoch 增加。
3. 双节点验收明确“两个等权节点均在线才能继续提交”的预期。四节点重启成功不替代双节点失去 quorum 后的恢复验证。
4. 真实 DKG 与 VM 五路径差分分别留证；单次创世支持 128 人不代表运行期容量、吞吐或故障恢复已经签收。
5. 所有部分覆盖项记录剩余步骤；性能结果附具体运行环境和采用的预算阈值。历史成功记录仅供定位，必须区分本次执行。

## 7. 源码与已有测试索引

| 引用 | 文件及用途 |
| --- | --- |
| [VM] | Rust PoC 默认值、真实创世 bundle 调用与状态重载测试 |
| [LY] | 当前 Layout 下主网最低人数、最高容量与人数不足测试 |
| [GE] | Move PoC 创世、可治理默认值和创世专用入口限制 |
| [PW] | 原始版本、上传权限、时钟与指数的生产实现 |
| [PS] | 指数、精度、周期时钟、期限与重复初始化测试 |
| [PV] | 双版本窗口、零版本、首次写入与上传/分配顺序测试 |
| [AC] | 持仓、池聚合、检查点、权益参考模型与容量测试 |
| [ST] | 权重增长、保证金、成员变更、奖励上下文与计划测试 |
| [FR] | 配置直接入口及缓冲配置冻结测试 |
| [CF] | staking contract、vesting、delegation 能力转调冻结测试 |
| [DG] | 治理代币权重及委托入池费测试 |
| [EE] | 生产 VM 原子回滚、watchdog、热门池并行及读写测量 |
| [DF] | 同一快照的五种换届完成路径差分 |
| [ND] | 真实节点同步、DKG、Chunky、成员替换和冻结恢复 |

需求依据：[当前 PoC 设计](POC_CONSENSUS_V2_MINIMAL_POWER_REWARD_DESIGN.md)、[实现方案](POC_CONSENSUS_V2_MINIMAL_POWER_REWARD_IMPLEMENTATION.md)、[创世默认值与验证说明](POC_GENESIS_IMPLEMENTATION_CHECKS.md)。历史执行记录见[实现与主审记录](POC_CONSENSUS_V2_IMPLEMENTATION_REVIEW.md)；其中涉及旧版迁移的历史条目不纳入本计划。

[VM]: ../../aptos-move/vm-genesis/src/poc.rs
[LY]: ../../crates/aptos-genesis/tests/poc_mainnet_defaults.rs
[GE]: ../../aptos-move/framework/topo-framework/sources/genesis.move
[PW]: ../../aptos-move/framework/topo-framework/sources/poc/poc_power_store.move
[PS]: ../../aptos-move/framework/topo-framework/tests/poc_power_store_tests.move
[PV]: ../../aptos-move/framework/topo-framework/tests/poc_power_version_tests.move
[AC]: ../../aptos-move/framework/topo-framework/tests/poc_accounting_tests.move
[ST]: ../../aptos-move/framework/topo-framework/sources/stake.move
[FR]: ../../aptos-move/framework/topo-framework/tests/poc_freeze_tests.move
[CF]: ../../aptos-move/framework/topo-framework/tests/poc_capability_freeze_tests.move
[DG]: ../../aptos-move/framework/topo-framework/tests/poc_delegation_tests.move
[EE]: ../../aptos-move/e2e-move-tests/src/tests/poc_consensus.rs
[DF]: ../../aptos-move/e2e-move-tests/src/tests/poc_transition_differential.rs
[ND]: ../../testsuite/smoke-test/src/poc.rs
