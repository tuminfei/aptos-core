# PoC 改造核心测试用例

编写日期：2026-09-11；修订日期：2026-09-17。源码核对基线：`7331671a80`。适用范围：PoC 直接创世、统一 `PowerStore`、通胀与交易费分流、主网默认配置和最低 2 节点的受控测试网配置。

本文设计 **61 个核心用例（58 个 P0、3 个 P1）**，用于实现回归、VM 验证及节点验收。保留原有编号，新增 REW-08～10、GOV-04～05、NUM-05。“已有”表示本行要求已有对应自动化断言；缺少任一适用参数组、步骤或要求的测试层级时标为“部分”；“待补”表示尚无对应自动化。存在辅助函数测试或相似配置测试，不能直接记为整行“已有”。**这些标记不是本轮执行结果**；自动化映射按当前仓库更新，新增节点测试分批执行并另存基线与日志，未重新执行本文完整测试集合。

## 1. 范围与判定规则

覆盖从创世分配原始算力，到上传、分配、权重安装、奖励分流与结算、换届及节点恢复的完整链路。当前开发阶段不设计旧版算力迁移、旧资源布局升级和旧网络首次切换用例；现有测试中借助原生准备路径构造状态的部分，只复用其进入 PoC 后的业务断言。共享 stake、delegation、staking contract、vesting 路径的既有原生回归仍须执行，以检查份额、佣金和锁仓行为。

| 级别 | 含义 | 执行要求 |
| --- | --- | --- |
| P0 | 涉及错误权重、错发奖励、状态不一致、越权或无法正常换届 | 每次相关实现变更执行；交付前补齐对应自动化 |
| P1 | 长时间运行、部署容量、故障恢复及边界组合 | 每日回归或版本验收；上线容量以目标环境实测为准 |

每个失败用例必须核对错误来源与业务状态，不能只断言“交易失败”。普通用户交易即使 Move abort，仍可能扣 gas、更新序列号和产生费用事件；“原子回滚”指相关 PoC、质押、配置、表项及业务事件没有部分提交。

权限和冻结用例应保持业务值和角色一致，验证四种情况：合法身份未冻结时成功、合法身份冻结时按指定模块与错误码拒绝、解除冻结后恢复成功、未冻结时非法身份被权限检查拒绝。有时效参数的入口在恢复后按当前 Epoch/周期重新计算合法目标；旧目标已过期时另行验证拒绝，不能误判为冻结未解除。冻结期间的非法身份按入口实际检查顺序核对错误。矩阵每项记录公开入口及转调路径；Move `expected_failure` 只能证明拒绝位置，外层份额、费用和表项的事务回滚还需 VM 输出或交易前后快照证据。

跨节点比较选定同一 `ledger_version`。涉及惰性推进的池和持仓，比较当前 Epoch 的**逻辑生效值**，不能要求所有物理表项已经主动落盘。通过测试助手注入的极限值、损坏状态和 DKG 回调只用于隔离测试，不作为节点或密码流程已经通过的证据。

非 `entry` 操作通过现有治理脚本或框架流程触发；真实节点用例不使用绕过可见性或签名校验的内部调用适配器。

## 2. 测试环境与公共数据

### 2.1 配置组合

| 编号 | 用途与配置 | 需要固定的条件 |
| --- | --- | --- |
| M | 主网默认配置：`PocGenesisConfiguration::mainnet()` / `Default`，Open，最低 5 人，容量 128，每人初始 100 万 OHMP，1 TOPO/OHMP | 分别使用原样的 `mainnet_genesis_config()` 和当前 `Layout::default()` 经济参数；原生最低保证金仍须满足 |
| T2 | 测试网默认配置：`testnet()`，Controlled，最低 2 人，容量 128，每人初始 1 OHMP，每池质押 1 TOPO，最低权重 1 power，上限 1,000 OHMP | 使用现有测试创世参数：50% 增长率、1 小时 Epoch、10% APY；保留原生默认功能及普通/Chunky DKG 配置 |
| T2-F | 双节点运行与恢复测试 | 基于 T2，仅将 Epoch 缩短为 10 秒；普通/Chunky DKG 仍取原生默认值。单独记录此覆盖项，不能替代 T2 原参数验收 |
| T2-S | [现有双节点 smoke][N2] 的独立变体 | 使用测试网 PoC 参数、每池 1 TOPO 和 10 秒 Epoch；继承 [SwarmBuilder][SB] 关闭 Chunky DKG 的覆盖项，普通 DKG 保持开启。其余配置逐项记录；该变体不能计为严格的 T2 或 T2-F |
| F4/F5 | 四池功能测试、五池成员替换及真实 DKG | 采用 [现有节点 fixture][ND]：Open、最低 4 人、25% 增长率、每池 100 Octa 保证金、10 power 初始权重，保留比例 10000，合约默认 `native_reward_bps=5000`，特定场景再通过治理设置分流；普通/Chunky DKG 按用例切换 |
| A | 整数算术、账本与时序隔离用例 | 未另行注明时保留比例 10000、`native_reward_bps=0`；奖励分流用例显式覆盖该值。按用例构造明确的生效持仓；VM 执行前清空目标池未列入算例的创世持仓并等待生效，同时保留足够背景验证者 |

M/T2 的合约共同默认值为：`max_allocations=4`、`max_claim_pools=4`、`max_upload_users=32`、`retention_bps=9995`、`native_reward_bps=5000`。直接创世的算力周期为 60 Epoch，上传者为 `0x1`，初始费用分发限额为 0。创世清单不配置上限与奖励分流；自定义值通过治理更新。通胀和可分发交易费各自分流、各自取整；PoC 运营佣金为 0，原生部分沿用份额、佣金和复投规则。

至少准备框架治理账户、上传者 O、验证者 owner/运营者/投票者、用户 U1～U32，以及只提供保证金的委托人、只提供算力的用户和同时持有两类权益的用户。权限用例使角色使用不同地址；另保留多个 owner 共用一个运营者和投票者的组合。每个独立用例从干净创世或固定快照开始。

### 2.2 单位与独立预期模型

```text
1 OHMP = 100_000_000 power
1 TOPO = 100_000_000 Octa
S = UNIT_SCALE = 2^16
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

inflation_octa = floor(reward_base_octa * successful_proposals * rate_num
                       / ((successful_proposals + failed_proposals) * rate_den))
fee_octa = distribute_fee ? min(recorded_fee_octa, installed_fee_limit) : 0
native_inflation_octa = floor(inflation_octa * installed_native_reward_bps / 10000)
native_fee_octa = floor(fee_octa * installed_native_reward_bps / 10000)
poc_reward_octa = (inflation_octa - native_inflation_octa)
                  + (fee_octa - native_fee_octa)

# 对原生通胀和原生费用分别按结奖前余额分配；不能先合计再取整
native_pending_inactive_octa = floor(native_amount_octa * pending_inactive_octa
                                     / (active_octa + pending_inactive_octa))
native_active_octa = native_amount_octa - native_pending_inactive_octa

delta_reward_index = floor(poc_reward_octa * Q / active_pool_units)
claimable_octa = floor(accrued / Q)
```

上述除法仅用于分母为正的分支：无提案时通胀为 0；原生可计奖余额为 0 时只允许零原生奖励；池 units 为 0 时只允许零 PoC 奖励。`rate_num/rate_den`、分流占比、费用开关和限额均取待结束 Epoch 的已安装快照。`pending_active` 和 `inactive` 不参与当期原生分配；只提供保证金者可以获得原生收益，但不能领取无算力持仓的 PoC 金库收益。

算力版本 `units` 和周期 `index` 保持 `u128`，奖励指数和宽整数中间计算使用 `u256`。使用独立大整数参考模型逐步取整；不能将浮点 OHMP、逐用户展示算力之和或理论奖励比例直接作为整数预期。奖励参考模型应按每个 Epoch 的成员持仓累积权益，不调用被测模块的预览、分流或结算函数生成金额预期。原生委托份额还需逐步核对佣金和份额换算；使用误差界时写明来源与上限，不能用宽泛容差掩盖错发。

| 算例 | 精确预期 |
| --- | --- |
| 周期 0、原始算力 17、全额分配 | `units = 17 * S`，生效权重 17 power |
| `retention=9000`，新版本原始算力 100，绑定下一周期指数 | `I=16602069666338596454`，`units=7281777`，该周期全额分配权重为 **99** |
| 创世原始算力 1 OHMP，`retention=9995`，无新上传 | 首次边界 `I=18437520701672696840`，聚合权重 **99,949,999 power**，不是展示值四舍五入后的 100,000,000 |
| 2.5 TOPO/OHMP，周期 0 原始算力各 17，保证金 `[42,43,100,100]` Octa | 最终权重 `[16,17,17,17]`，计奖基数 `[40,42,42,42]` Octa，原始算力及完整 units 保留 |
| A：两名用户 units 为 `10*S`、`30*S`，原生占比 0，1 Octa 通胀加 39 Octa 可分发费用 | PoC 入账 40，分别领取 10、30 Octa |
| 相同 units，原生占比 3000，1 Octa 通胀加 39 Octa 可分发费用 | 原生获得 0 通胀和 11 费用；PoC 入账 29，两人领取 7、21 Octa，金库剩 1，持仓小数权益保留 |
| 相同 units，原生占比 3000，1 Octa 通胀加 27 Octa 可分发费用 | 原生获得 8，PoC 入账 20，两人领取 5、15 Octa；对应 [ST] 当前保证金限幅测试 |
| 相同 units，原生占比 3000，无通胀、39 Octa 可分发费用 | 原生获得 11，PoC 入账 28；池指数先取整后两人领取 **6、20** Octa，金库剩 2，小数权益保留；不能直接按 1:3 比例给出 7、21 |
| 原生占比 3500，10 Octa 通胀加 2 Octa 可分发费用 | 原生获得 `floor(10*35%)+floor(2*35%)=3`，PoC 获得 9；不能合计后给原生 4 |
| A：两名用户各 `S`，连续两期 PoC 金库各入账 1 Octa | 第一期各可领 0，保留 `Q/2` 权益；第二期各可领 1 Octa |

### 2.3 公共观测与不变量

| 对象 | 观测入口或资源 | 必须核对的内容 |
| --- | --- | --- |
| 全局状态 | `poc_accounting::get_config`、`Configuration`、`stake::get_installed_reward_context` | 已安装 Epoch、首次 PoC Epoch、当前/待生效参数、旧期/新期奖励上下文 |
| 奖励分流 | `stake::get_reward_split_configuration`、`get_installed_native_reward_bps`、`poc_reward_split::RewardSplitConfig` | 已安装 Epoch/占比、配置值、待生效占比及 Epoch；旧期分流不受排期、查询或墙上时间改变 |
| 算力与时钟 | `poc_power_store::get_accounting_snapshot`、`get_normalization_clock`、`next_boundary_epoch`、原始版本查询 | 当前/下一版本、生效周期、绑定指数、倒计时；查询无业务写入 |
| 分配与奖励 | `poc_accounting::get_allocations`、`get_position`、`get_pool` | 当前与未来 units、最多两个未来生效时点、可领整数额、小数权益、金库与奖励指数 |
| 共识目标 | `stake::preview_epoch_transition`、`ValidatorSet`、`EpochPlan`、`PrecomputedValidatorSet` | 地址顺序、公钥、验证者索引、每池权重、总权重、截止时间和计奖基数 |
| 质押与治理 | `stake::get_stake`、原生质押/奖励/治理/Block 配置 | 保证金组成、锁仓状态；TOPO 配置资源与对应原生创世逐字节比较 |
| 事件 | `PowerNormalized`、`PowerUpdateStagedEvent`、`AllocationScheduled`、`PoCEpochInstalled`、`PoCRewardCredited`、`PoCRewardClaimed`、`PoCRewardSplit`、`RewardSplitScheduled/Cancelled/Installed`、`DistributeRewards`、`DistributeTransactionFee` | 发出时点、主体、周期、金额及是否重复；`PoCRewardCredited` 记录 PoC 实际入账，`PoCRewardSplit` 记录通胀分流，原生费用另查 `DistributeTransactionFee`；零金额不强求领奖事件 |

所有相关用例共同检查：池逻辑 units 等于生效持仓之和；当前及未来聚合不超过 `2^120`；持仓/池的未来变更最多两条；奖励指数单调不减；累计领取不超过累计入账；`vault = 累计入账 - 累计领取`；检查点引用归零后可释放；已安装权重只来自 `ValidatorSet`；冻结计划与 PVS 成对存在、成对清理。

奖励分流同时检查：分流快照 Epoch 与 `RewardContext.epoch` 一致；`native_inflation + poc_inflation = inflation`、`native_fee + poc_fee = fee`；两路余额增量之和等于该期总收益，通胀只计算一次。金库守恒中的“入账”仅指 PoC 部分；原生本金可因原生奖励复投增加，PoC 结奖和领取自身不增加原生份额。实际代币总量以 Octa 计量并长期远低于 `u64::MAX`；NUM-05 验证巨大费用政策上限不会被当成余额，以及实际结算和委托入池费估算的边界。

## 3. 核心测试用例

下表每行是一个用例，行内参数组合作为子用例执行。覆盖状态按该行整体描述判定；标记“部分”的用例须补充未覆盖的组合。

### 3.1 创世与默认配置

| ID / 级别 | 前置条件与步骤 | 预期结果 | 现有自动化 / 补充点 |
| --- | --- | --- | --- |
| GEN-01 / P0 | M：分别以主网原生配置的默认 10 人、Layout 的 5 人/最低保证金和 128 人/最高保证金生成创世；再尝试 4 人 | 合法组合安装 Epoch 1；每人获配 100 万 OHMP；4 人拒绝；四类 TOPO 配置资源保持原值；`Default` 使用主网值，分流快照为 Epoch 1/5000 | 已有：[VM] `poc_mainnet_defaults_initialize_without_changing_topo_config` 核对默认 10 人、主网默认值及原生资源；[LY] `poc_mainnet_defaults_support_current_layout_and_validator_capacity` 对 Layout 5 人/最低保证金和 128 人/最高保证金分别生成 PoC 与普通原生创世，逐字节比较四类 TOPO 配置并核对 Epoch 1/5000 分流快照；`poc_mainnet_defaults_reject_too_few_validators` 覆盖 4 人拒绝 |
| GEN-02 / P0 | T2：分别用 2、5、10 人生成创世；再用 1 人 | 合法组合各安装 1 OHMP 权重、全额分配、PoC 奖励上下文及 Epoch 1/5000 分流快照；1 人拒绝；现有 TOPO 参数不变 | 已有：[VM] `poc_testnet_defaults_initialize_without_changing_topo_config`、`poc_testnet_defaults_reject_single_validator`；这是创世写集证据，节点默认配置另见 SYS-01 |
| GEN-03 / P0 | 新建 PoC 创世并重载写集；多个 owner 共用运营者与投票者；清单仅提供四项启动配置 | 每个 owner 的原始版本和全额本池分配独立；Epoch 1、周期 0、下一边界 61；合约默认部署上限及 5000 bps 分流正确，Epoch 0 不结奖 | 已有：[VM] `poc_genesis_builder_executes_and_reloads_production_bundle` 和 [LY] `poc_genesis_manifest_contains_only_bootstrap_configuration`；治理更新由 Move `poc_genesis_defaults_remain_governable` 和 `poc_config_tests` 覆盖 |
| GEN-04 / P0 | 原始算力各 100 power，保证金 `[20,30,30,30]` Octa，比例 1 TOPO/OHMP | 最终权重被限为 `[20,30,30,30]`；每个 owner 与池仍保有 `100*S` units，不能只写受担保部分 | 已有：[VM] `poc_genesis_builder_preserves_full_allocation_when_bonds_cap_power` |
| GEN-05 / P0 | 参数化尝试：初始算力 0；Open+最低 2 人；Controlled+最低 2 人+20% 动态增长；动态换员下最低人数等于合约默认容量；再恢复合法参数 | 无效组合以预期原因拒绝，不生成部分创世；Controlled+2 人+50% 合法；Open 仍要求至少 4 人及集中度约束 | 已有：[VM] `poc_genesis_builder_validates_mode_growth_and_default_capacity` 覆盖模式、增长率与默认容量，非法组合匹配模块名和完整 abort code；零算力、Open 集中度测试同样核对错误来源；分流的 0/10000/10001 边界由 [RS] 治理测试覆盖 |
| GEN-06 / P0 | 在已运行链重放创世专用写算力/创建 PoC 验证者操作，或尝试重复初始化 PowerStore；另运行普通原生创世入口 | 重放和重复初始化拒绝，原始版本、基线和时钟不重置；普通原生创世仍沿用其显式入口行为 | 已有：[GE] `poc_genesis_entry_rejects_operating_chain`、`poc_native_genesis_remains_unprepared`；[PS] `poc_initialization_cannot_reset_retention_or_versions`；[NP] `poc_operating_chain_rejects_genesis_power_replay_atomically` 从真实治理事务与普通账户调用创世算力入口，覆盖已有双版本/无记录用户、0/1 OHMP/u64 上限，精确拒绝并回滚前置分流排期及事件，原版本/基线/时钟保留，合法上传随后成功 |

### 3.2 原始算力、双版本与衰减

| ID / 级别 | 前置条件与步骤 | 预期结果 | 现有自动化 / 补充点 |
| --- | --- | --- | --- |
| PWR-01 / P0 | 周期 P 中上传 `effective_period=P+1` 的新绝对原始算力；分别查询当前、E+1、边界 B | 上传按 `I[P+1]` 生成 units 并同步相关分配；B 前不改变当前权重，B 才应用下一原始版本；不得将上传值当作增量 | 已有：[PV] `poc_upload_allocation_order_independence`、`poc_units_keep_their_effective_period_index` |
| PWR-02 / P0 | 同用户、同目标周期依次上报 100、100、200；覆盖同批重复及跨交易重复 | **首次写入 100 生效**，后续不同值也不覆盖；不重复增加 units/refs；只对实际新增版本发出标准化及上传事件 | 已有：[PV] `poc_batch_first_write_and_explicit_zero_version`；[SN] `poc_public_upload_authority_first_write_and_batch_inputs` 核对同批/跨交易 100、100、200 的首次写入、units/refs 快照及两类事件数量 |
| PWR-03 / P0 | 已有用户下一周期上传 0；新用户首次上传 0；已有用户同批 `[0,999]` | 已有用户保存明确零版本并在 B 清除未来算力，历史奖励仍可领；新用户零值不建记录；同周期 999 不覆盖先写的 0 | 已有：[PV] `poc_batch_first_write_and_explicit_zero_version`；[SN] 真实上传矩阵覆盖已有用户 `[0,999]`、新用户零值及事件；[NP] `poc_power_period_zero_rollover_and_historical_claim` 验证零版本生效后实际领取历史权益 |
| PWR-04 / P0 | 连续上传三个周期的版本；跨数个周期不访问，再查询并领取奖励 | 最多保存两个原始版本槽；新写入淘汰旧槽后，当前有效 units 仍使用原生效周期指数；旧奖励可凭检查点结算；重复查询无写入 | 已有：[PV] 版本滚动和长期查询；[PS] `poc_snapshot_is_read_only`；[NP] 同一节点状态链覆盖连续版本、四个周期不操作、两个原始槽及历史领取，按每期生效持仓独立累积整数和小数权益 |
| PWR-05 / P0 | 上传者 O 成功上传；普通用户上传；治理将上传者从 O 改为 O2；分别由 O、O2、框架继续上传；重复设置相同上传者 | 普通用户和被替换的 O 拒绝；O2 与框架可操作；未授权失败不改变任何版本；地址未变不重复发 `OperatorChangedEvent` | 已有：[SN] `poc_public_upload_authority_first_write_and_batch_inputs` 覆盖上传者轮换、框架和非法身份、版本回滚及幂等事件；[NF] 补上传和改上传者的正常/冻结/恢复/越权矩阵；行为依据 [PW] `stage_batch_update`、`set_operator` |
| PWR-06 / P0 | 未冻结且指数有效，分别上传空批、1 项、32 项、33 项；构造向量长度不等、当前/过去/跨过下一周期的 target；令批次后项触发容量错误 | 空批无业务变化；1/32 合法；33、长度或周期非法拒绝。重复地址按原始输入长度计批次上限；后项失败回滚先前合法项及事件 | 已有：[EE] 上传容量及批次 VM 回滚；[SN] 上传矩阵覆盖空批、1/32/33 项、重复地址计数、长度不等、当前及跨期目标；[NP] 补过去目标拒绝；[NU] 在真实 E99/P39/B101 上传 [u64::MAX,2]，后项仅 B 超限于 poc_accounting/0x20008，前项版本、持仓、refs、事件和业务写集全部回滚，修复为 [u64::MAX,1] 后成功安装 |
| PWR-07 / P0 | 使用 60 Epoch 周期从创世推进到 Epoch 60、61、121；期间不上传；另使用 9000 保留比例测试新版本取整 | Epoch 60 仍为周期 0；61/121 各只递推一次指数；按 2.2 节核对首次 1 OHMP 衰减值和 100→99 反例；不逐用户重算标准化版本 | 已有：[PS] 时钟及 9000 下 100→99 取整；[NP] `poc_default_sixty_epoch_period_reaches_second_decay_without_uploads` 保持 60 Epoch、9995/5000，未上传推进至 60/61/120/121，精确权重依次 100,000,000/99,949,999/99,949,999/99,900,024；周期事件仅在 61/121 各一次，每笔核对没有原始版本或持仓表项重写，逐期独立核对两路奖励 |

### 3.3 算力分配与两个生效时点

| ID / 级别 | 前置条件与步骤 | 预期结果 | 现有自动化 / 补充点 |
| --- | --- | --- | --- |
| ALC-01 / P0 | 用户设置全额、部分、空分配；无算力用户先配置再首次上传；分别输入重复池、未启用池、0 bps、总和 10001、向量长度不等 | 合法分配最早 E+1 生效；未分配部分不计权；无算力可先配置，后续上传自动同步；非法参数整笔拒绝 | 已有：[PV]/[AC] 分配与输入检查；[SN] `poc_public_allocation_inputs_and_upload_synchronization` 覆盖公开输入矩阵、首次上传同步及回滚；[NA] `poc_allocation_full_partial_empty_install_and_release_checkpoints` 覆盖已有算力的全额/部分/空分配跨 E+1、逻辑权重和引用释放 |
| ALC-02 / P0 | A：当前原始算力 100、当前比例 50%，上传下一周期 200 后将比例改为 25%；另从同一快照交换操作顺序 | 当前持仓 `50*S`；E+1 为 `25*S`；B 为 `50*S`。两种顺序的当前状态、两条变化、池增减与 refs 一致 | 已有：[AC] `poc_two_boundary_rebuild`、`poc_upload_and_allocation_commute`；[PV] `poc_upload_allocation_order_independence` |
| ALC-03 / P0 | 在 `E+1=B` 时组合原始算力与比例变更；再构造 100×50%→200×25% 的等量情况 | 同一 Epoch 只保留最终一条变化；最终 units 不变时省略变化及其引用，不能先增后减重复应用 | 已有：[AC] `poc_coincident_boundary_omits_unchanged_units`；[PV] `poc_same_boundary_cancels_zero_change` |
| ALC-04 / P0 | 同 Epoch 连续覆盖分配，再覆盖回 active 比例；随后跨过 E+1/B，再修改一次 | 旧未来链被完整撤销并重建；不产生孤立引用或负数；保留尚有效的未来原始版本；两条成熟变化先结算，再写新链 | 已有：[AC] `poc_cover_pending_back_to_active_preserves_future_version`、`poc_two_matured_changes_then_new_version` |
| ALC-05 / P0 | `max_allocations=4`：active 已占 4 池，尝试 pending 再指向其他 4 池；另在 active 为空时，将 pending 4 池覆盖为另外 4 池 | 第一种 active/pending 配置并集为 8，必须拒绝；第二种每份有效配置并集不超过 4，可成功，但撤销和新建合计访问 8 池；不得将访问上限误写成 4 | 已有：[EE] `poc_disjoint_four_pool_replacement_visits_eight`；[NA] `poc_allocation_four_pool_union_and_eight_pool_pending_replacement` 在真实节点成对核对并集拒绝、完整回滚、八池实际写集、成功安装及检查点释放 |
| ALC-06 / P0 | 同一 Epoch 两名用户在同池等量退出/加入，池净 units 不变；前后分别入账奖励并领取 | 仍创建奖励检查点，旧奖励属于旧持仓；新持仓不继承旧指数；用户结算后 refs 正确减少至可释放 | 已有：[AC] `poc_net_zero_change_retains_reward_checkpoint` |

### 3.4 保证金、权重与成员变更

| ID / 级别 | 前置条件与步骤 | 预期结果 | 现有自动化 / 补充点 |
| --- | --- | --- | --- |
| WGT-01 / P0 | 分别使原始聚合算力、保证金、`max_power` 成为最小项；执行 2.2 节的 2.5 TOPO/OHMP 算例；在 `min_power-1/min_power` 比较准入 | 权重取三项最小值；使用宽整数限幅后转 u64；保证金上限与计奖基数各独立向下取整；低于整数门槛才排除，units 不随限幅缩减 | 已有：[VM]/[ST] 创世及保证金限幅；[NX] 五节点同链分别由原始17、保证金42/43和 max16 限幅，2.5 TOPO/OHMP 下权重16/17及基数40/42独立取整；min17 排除16但保留17，min18 复合治理精确失败并回滚；原42池公开补1 Octa后按增长预算17重入，完整17*S持仓、旧期奖励及各在任节点同版本一致 |
| WGT-02 / P0 | 构造 active、pending_active、pending_inactive、inactive；锁仓到期分别位于截止时间前、相等、后；在 DKG 等待中越过到期时间 | 只计 active、pending_active、未到期 pending_inactive；inactive 和已到期部分不计。冻结后沿用缓存 cutoff 推算，不因完成时间变更而重选 | 已有：[DF]/[ST] 保证金推算与缓存隔离测试；[NL] `poc_bond_preview_counts_four_balances_at_exact_expiry_cutoff` 通过真实追加、解锁和到期形成 active/inactive/pending_active/pending_inactive=60/25/20/15，同版本 L−1/L/L+1 精确权重 95/80/80；另一个节点用例在真实 DKG 中跨过 L，缓存目标仍为 95，完成后保留待退出 15 及旧锁仓截止时间 |
| WGT-03 / P0 | 当前四池权重各 10、最低 4 人/10 power，一人退出、一名候选申请；分别以 20%/25% 动态增长配置验收 | 20% 组合配置拒绝；25% 预算为 10，合格替补最终获 10 并完成换届。正常运行不得重新使用创世免增长限制 | 已有：[AC] 动态增长配置测试；[ST] `poc_growth_initialization_and_replacement`；[ND] `poc_dkg_replaces_validator_with_growth_budget` |
| WGT-04 / P0 | 上例改为两名候选各要求 10；另测试下降权重及多个候选分配后不足 1 的取整情况 | 预算 10 被分为 5/5，低于最低 10 而剔除；余量不重分配，目标不足则延期/拒绝退出；取消多余待加入后单替补可成功。待加入权重及 `total_joining_power` 不预增 | 已有：[ST] `poc_growth_drops_and_flooring` 精确覆盖下降权重、预算不足 1 和余量不重分配，`poc_competing_replacements_reject_unsafe_leave` 覆盖不安全退出拒绝；[NM] `poc_competing_candidates_cancel_extra_and_complete_replacement` 通过真实交易验证双候选 5/5、pending 权重和 `total_joining_power` 均为 0、退出精确拒绝及完整回滚，取消多余候选后单替补获 10 并完成替换，同时核对旧期奖励和四节点同版本状态 |
| WGT-05 / P0 | Open 模式五池等权 20，将四池算力转向四个新池，构造最终 `[20,5,5,5,5]`；撤回分配修复；在最低权重 1、最低 4 人的隔离配置检查 `[10,10,5,6]`、`[10,10,5,5]`、`[10,9,5,5]`，并比较 Controlled | Open 对每池严格要求 `3*power<total`；三组边界分别通过、因恰好 1/3 拒绝、因超过 1/3 拒绝；50% 目标也拒绝，修复后可换届。Controlled 跳过集中度约束，但保留人数、总权重和原有 quorum 算法 | 部分：[NC] 两项四节点测试覆盖三组 1/3 精确边界、Open 连续 16 次真实延期与修复及 Controlled 对照；[ST]/[EE] 保留集中度与撤回隔离证据。超过 7 节点的五旧池到四新池完整节点链已移除，仍待用不超过 7 节点的夹具重新构造 |
| WGT-06 / P0 | 运营者申请退出、取消自主退出；换运营者后由旧/新角色重试；治理移除后尝试取消；候选容量满时取消退出 | 退出前执行目标预检，失败不留下部分队列。合法取消恢复旧权重、索引、统计、费用，不加预算、不结奖；旧运营者与撤销治理移除的请求拒绝；容量不足须先腾出名额 | 已有：[NM] 运营者轮换用例覆盖 owner/新旧运营者/voter 分离、精确权限拒绝、取消保留索引/统计/费用/非零金库及治理撤销；`poc_full_candidate_capacity_blocks_cancel_until_pending_slot_is_freed` 补容量 5、公开注册的零权重待加入候选填位、精确 `stake/0x1000c` 回滚、释放名额后同请求恢复，原五节点完成换届；[NJ] 冻结矩阵，[ST] 保留隔离覆盖 |

### 3.5 奖励结算、领取与金库

| ID / 级别 | 前置条件与步骤 | 预期结果 | 现有自动化 / 补充点 |
| --- | --- | --- | --- |
| REW-01 / P0 | 两用户贡献 `10*S:30*S`；10 TOPO/OHMP 比例、100 Octa 保证金，将 40 power 限为 10；1 Octa 通胀加 39 Octa 可分发费用，分别安装原生占比 0/3000；另执行 3000 下的 1+27 算例 | 计奖基数为 100；占比 0 时领取 10/30；占比 3000 时原生获 11、PoC 入账 29、领取 7/21、金库剩 1 并保留小数权益；1+27 时原生获 8、领取 5/15。限幅不改变池内比例；无算力保证金所有人不领取 PoC 金库，但可获原生部分 | 已有：[NB] 三个 `poc_bond_capped_*` 节点测试执行 1+39 的 0/3000 占比及 1+27 的 3000 占比；独立核对真实旧期表现、分流、10/30、7/21、5/15 领取和小数权益，目标保证金 owner 的零持仓领取及原生收益，完整 units、引用释放和金库；[ST] 保留原保证金限幅测试 |
| REW-02 / P0 | 在 Epoch E 中修改保证金比例、奖励率、费用开关/限额或奖励率来源功能，并排定新的原生奖励占比；准备并完成 E+1，DKG 等待期间继续出块 | E 按已安装计奖基数、closing context 和旧分流快照结算；统计与实际费用继续累计，提交时按旧索引分流；新参数只影响目标期，奖励上下文、分流快照 Epoch 与委员会一致 | 已有：[NR] `poc_default_genesis_context_changes_wait_for_dkg_and_settle_old_snapshot` 从原样 `PocGenesisConfiguration::testnet()` 创世出发，Epoch 内联合排定新保证金比例、奖励率、费用限额及 6000 分流并暂停真实普通 DKG；等待期间继续提交付费交易，完成时按旧基数、旧 context、旧 5000 和旧索引独立核对通胀/费用、原生余额、PoC 金库、指数与事件，目标期才安装新值并清缓存，四节点同版本一致；[ST]/[DF] 保留奖励率来源 feature、费用开关及五种完成路径覆盖 |
| REW-03 / P0 | 改变成功/失败提案比例；覆盖无提案、长 Epoch、费用分发关闭、限额 0、正限额及超限费用；隔离测试零 units 和同 Epoch 零奖励重复入账 | 通胀仍使用原生表现公式和宽整数；无有效表现的对应通胀为 0；费用按开关/限额分发；费用限额 0 不关闭 gas 或通胀。零 units 时权重和奖励须为 0，不做除法；零奖励也不能同 Epoch 重复入账 | 已有：[NE] `poc_positive_inflation_fee_switch_limits_and_performance` 在 3600 秒 Epoch 覆盖真实 0/0 无提案、停机产生失败提案及恢复后的成功/失败混合比例；限额 0 下 gas 与正通胀保持、关闭 feature 后费用仍记录但结奖为 0、重开后单笔超限精确封顶 17，独立核对指数、金库、事件及同版本状态。[AC] `poc_zero_reward_still_prevents_double_credit` 与 `poc_zero_unit_pool_rejects_positive_reward_atomically` 将零 units/零基数池推进到有效 PoC Epoch：零奖励 delta/index/vault 均为 0 但阻止重复入账，正奖励精确以 `poc_accounting/0x3000e` 原子拒绝；[ST] 保留宽整数公式覆盖 |
| REW-04 / P0 | A：两用户各 `S`，连续两期各入账 1 Octa；第一期先查询、领取 0，再覆盖配置并恢复原比例，确保两期生效持仓仍各为 `S`；第二期重新领取 | 第一期各保留 `Q/2` 小数权益；普通更新和零额领取不丢权益；第二期各领取 1；同一奖励再次领取为 0，查询结果与实际领取一致 | 已有：[AC] 保留小数权益和查询/领取分段隔离测试；[NK] `poc_fractional_rewards_survive_zero_claim_and_allocation_replacement` 补真实费用连续两期各 1 Octa、先查询/领 0、50%→25%→50% 覆盖恢复、第二期各领 1/重复领 0；独立模型核对 Q/2、余额、事件及引用释放 |
| REW-05 / P0 | A：池 units=`3*S`，单期奖励 1 Octa 制造池级除法余量；下一期等量更换全部持仓后继续结奖 | 每 Epoch 独立计算 `floor(R*Q/U)`；池级除法余量不进入下一期指数。新用户只能取得新期收益；旧用户小数权益留在旧持仓，金库余额可大于当前整数可领额之和 | 已有：[AC] 保留独立 Epoch 模型和净零变化检查点测试；[NK] `poc_pool_division_dust_does_not_follow_replacement_positions` 补 3S 等量换仓、每期 1 Octa 共三期，严格区分逐期与合并取整；旧权益 Q-S、新人领取 1 后 Q-2S、金库余 2，核对引用归零及各在任节点表项释放 |
| REW-06 / P0 | 用户经历两个成熟变化后长期不操作；池退出委员会、原始版本滚动，再查询及领取；隔离注入检查点缺失、引用为 0 或下溢 | 退出池新计奖基数为 0，仍可领取旧收益；分段使用历史检查点，不推进全局 Epoch；合法引用归零后释放。损坏状态的查询/领取明确拒绝，不能静默跳过收益或重复支付 | 已有：[AC] 退出池领取、成熟变化、检查点缺失与零引用的查询/领取精确拒绝；[NP] poc_exited_pool_preserves_matured_checkpoints_across_version_rollover 使 E62/E63 两个成熟检查点长期保留，E64 退出后等待至 E71，再经 P7/P9 上传淘汰两个旧版本、零版本于 E77 生效，E79 精确查询/领取及重复领0；独立模型核对历史权益、引用释放、退出后基数0、全局 Epoch 不因领取推进及三个在任节点同版本 |
| REW-07 / P0 | 原生占比 0/3000 下分别结奖、领取后再次领取；逐步比较质押余额；批量领取输入重复池或 5 池；隔离注入金库不足 | PoC 金库及领取不自动复投或增加原生份额；占比 3000 时结奖产生的原生余额增量单独核对。重复池导致首池已执行的支付回滚；5 池在上限检查处拒绝；金库不足报错并保留权益，失败均无业务事件 | 已有：[ST] 零占比及混合入账；[NE] `poc_fee_only_zero_native_split_claims_and_rollback`、`poc_fee_only_default_native_split_claims_and_rollback` 覆盖真实结奖、两人领取/重复领取、重复池与 5 池拒绝、gas/余额/小数权益/引用回滚；[EE] `poc_claim_limit_and_underfunded_vault_are_atomic` 使用生产 bundle 核对 5 池在访问前拒绝，并隔离注入金库不足，逐字节验证持仓、检查点、金库和业务事件回滚，修复金库后领取原金额 |
| REW-08 / P0 | A：隔离分流计算，金额取 0、1、17、u64 上限，占比取 0、3000、3500、9999、10000，另拒绝 10001；在合法部署额度内执行 10 通胀+2 费用、仅费用及超费用限额的结奖 | 每类收入各自向下取整原生部分、余额归 PoC；每类及两路总额守恒；3500 下 10+2 分为原生 3、PoC 9；费用先按旧期限额截断再分流；占比 0/10000 分别全归 PoC/原生，不额外铸造第二笔通胀 | 已有：[NR] 实际 VM 事务用独立 u128 常数核对金额 `[0,1,2,10,17,u64::MAX]`×全部占比×两类分流函数，并拒绝 10001 排期；[RS] 非法算术占比；[ST] `poc_fee_split_rounding_is_independent_of_inflation`、`poc_fee_only_split_caps_before_splitting_and_uses_old_switch`、`poc_zero_and_full_native_split_use_old_epoch_snapshot` 保留 10+2、费用截断及 0/10000 混合结奖证据；[NE] 另核对真实区块的可分发费用、39 Octa 截断及 0/3000 两路金额。u64 极限仅作隔离验证 |
| REW-09 / P0 | A 覆盖原生占比 3000：结奖前 active=600、pending_inactive=400、pending_active=100、inactive=77；通胀 10、可分发费用 20；分别由不同角色提供保证金和算力，并增加兼具两类权益的变体 | 原生通胀 3 分为 active 2/退出中 1，原生费用 6 分为 4/2；PoC 金库入账 21。未到期时安装后 active=706、pending_inactive=403、pending_active=0、inactive=77；新增和 inactive 本金不分享旧期奖励；两类权益独立、同一收入不重复支付 | 已有：[ST] `poc_mixed_rewards_preserve_native_ownership_and_fee_destination` 以独立地址验证只出保证金者 PoC 领取为 0、只出算力者领取 21，精确核对四类余额、金库、指数和通胀/费用/分流/入账事件；`poc_mixed_rewards_dual_owner_receives_native_and_poc_independently` 验证双重身份的原生收益留在质押桶、PoC 21 进入本人钱包且重复领取为 0；`poc_native_reward_split_rounding_and_zero_balances` 保留余额为零和取整边界 |
| REW-10 / P0 | 真实委托池中分离 owner、委托人、运营者和算力用户；原生占比 0/3000/10000，佣金 0/3735/10000；测试连续追加、追加后解锁、仅费用收入、1 Octa 原生奖励，以及冻结等待跨过佣金生效时间 | 入池费按已安装计奖基数、奖励率、费用上限和原生占比估算；原生占比 0 时为 0，正占比按净原生收益及整数规则计算；新增资金不分享旧期权益，原生佣金和复投保留，PoC 佣金为 0；DKG 等待不能使佣金提前生效或提前释放临时份额 | 已有：[DG] 保留委托份额与佣金隔离测试；[NQ] 覆盖真实委员委托池四角色、native={0,3000,10000}×commission={0,3735,10000} 九组连续追加、追加后解锁、仅费用、1 Octa 原生费用/通胀、正入池费与 NULL 临时份额、失败回滚、原生复投和 PoC 领取；`poc_commission_expiry_waits_for_real_dkg_and_pending_deposit` 将佣金3735排期降为0，暂停真实普通 DKG 并跨过链上生效时间，验证同步不提前应用佣金或释放临时份额，恢复后要求非空 transcript，按精确安装事件版本及旧佣金结算并释放 NULL 份额，最后核对新佣金0和五节点同版本 |

### 3.6 Epoch 预检、延期和计划提交

| ID / 级别 | 前置条件与步骤 | 预期结果 | 现有自动化 / 补充点 |
| --- | --- | --- | --- |
| EPO-01 / P0 | 从同一不可变快照创建五份独立状态，旧期原生占比 3000、目标期 6000，分别走同步、普通 DKG、Chunky DKG、超时和治理强制完成 | 每条路径的目标地址顺序、公钥、units、权重、计奖基数、closing context、最终上下文、分流配置、原生余额、金库、指数与结奖事件一致；旧期用 3000、目标期安装 6000，通胀与费用分别守恒；重复完成不重复入账 | 已有：[DF] `poc_same_snapshot_transition_targets_and_reward_bases`；该测试的内部 DKG 结果注入不覆盖真实 transcript 验证，后者见 SYS-04 |
| EPO-02 / P0 | 分别构造目标人数不足、零总权重、集中度不合格；每组连续触发至少 16 次区块预检，再用合法入口修复；不可由合法状态构造的分支明确标记为隔离注入 | 按对应原因返回 Deferred，旧委员会继续服务；不冻结、不结奖、不推进 Epoch/算力周期，不转换到期质押。允许区块时间、旧期表现和费用继续累计；修复后恰好提交一次 | 已有：[NC] 对相等/超过 1/3 的两种目标，各验证 16 次已到期真实 BlockMetadata 的 Deferred、原业务状态与委员会不变、无计划/PVS/结奖及修复后一次提交；[EE] `poc_zero_total_power_defers_sixteen_blocks_without_partial_state` 由用户签名的公开空分配将 E+1 目标总权重降为零，当前期 units 保持非零，普通/Chunky 分支各经 16 次真实 BlockMetadata 和治理入口精确核对 Deferred、旧状态不变及无计划/PVS；同一 E+1 覆盖回原分配后恰好产生一条 `PoCEpochInstalled`、推进一个 Epoch 并清理计划/PVS；[ST]/[EE] 保留人数不足及修复 |
| EPO-03 / P0 | 一笔治理事务先改 PoC 参数、缓冲配置或原生奖励占比，再要求立即换届；使目标不合法后执行；随后恢复合法目标重试 | 核对准确错误模块和 abort code；失败回滚前面的参数、缓冲配置、分流配置、PoC 状态与 Epoch；合法重试整体成功；不得留下“配置已安装、委员会未更新”的状态 | 已有：[NG] `poc_power_params_lifecycle_and_atomic_reconfiguration` 在同一生产交易写入分流、缓冲配置和 PoC 参数后，对人数不足/权重低于准入门槛的目标精确核对 `reconfiguration_with_dkg/0x30001`、原状态/表项/事件回滚；合法重试整体安装并清理待生效项，按旧基数和旧分流结奖；[EE] 保留既有 VM 配置组合 |
| EPO-04 / P0 | 冻结后重复启动/查询；隔离构造仅有计划、仅有 PVS、目标 Epoch 错配、提交错误 Epoch | 有效计划被复用，返回原 cutoff 和目标；不成对或错配按协议状态错误拒绝，不能返回普通 Deferred 或实时重选；失败不部分清理缓存 | 已有：[ST] `poc_orphan_pvs_rejected`、`poc_plan_epoch_mismatch_rejected`、`poc_install_rejects_wrong_target_epoch` 覆盖精确协议错误；[EE] `poc_corrupt_epoch_plan_states_abort_and_roll_back` 使用生产 bundle 隔离注入仅计划、仅 PVS 和目标 Epoch 错配，逐项核对 `stake/0x30020`、完整业务快照不变及损坏缓存未被部分清理；有效计划复用由既有冻结查询及完成路径覆盖 |
| EPO-05 / P0 | 冻结有效计划，等待真实区块超时或调用授权强制完成；完成后再次运行超时检查，并送入迟到的旧会话结果 | 首次只安装缓存目标，旧期每池奖励只结算一次；计划/PVS、旧会话和冻结状态正确清理；重复 watchdog 不重复提交，迟到结果不能进入新 Epoch | 已有：[EE] `poc_block_metadata_watchdog_commits_cached_plan_once` 通过生产验证者交易入口精确拒绝迟到旧结果，并核对 Epoch、奖励/金库、分流、计划/PVS 和会话不变；[DF] 重复完成断言；[ND] 冻结恢复 |
| EPO-06 / P0 | 周期边界附近冻结，等待时间跨过原锁仓到期及多个名义 Epoch；期间查询目标、记录正常出块，最后完成 | cutoff、目标算力和成员不变；旧期统计仍可增长；完成仅推进一个 Epoch，周期只按成功提交推进一次；不得按经过的墙上时间补结多个周期 | 已有：[ST]/[EE]/[PS] 保留隔离与 watchdog 证据；[NL] `poc_frozen_power_boundary_uses_original_bond_cutoff_after_real_expiry` 在 E60 冻结 E61，跨实际锁仓到期和至少四个名义 5 秒 Epoch，逐笔扫描无中途结奖/推进，完整缓存与业务状态不变、旧期统计增长；授权完成仅安装 E61/周期 1/B63，旧索引独立算奖、四节点同版本一致。此项为普通 DKG、原生占比 0 的时序变体 |

### 3.7 冻结期间的权限与入口

| ID / 级别 | 前置条件与步骤 | 预期结果 | 现有自动化 / 补充点 |
| --- | --- | --- | --- |
| FRZ-01 / P0 | 已冻结有效计划：上传新版本、重复上传、改分配、改上传者/周期长度、启用池、排定/取消 PoC 参数及原生奖励占比；完成后重试同一合法输入 | 全部拒绝且没有相关业务写入；幂等或重复请求也不能绕过冻结检查；原计划/PVS 和分流快照字节保持一致；完成后合法操作恢复 | 已有：[NF] `poc_frozen_public_entries_preserve_plan_and_resume_after_finish` 补真实 DKG 的正常/冻结/恢复/权限矩阵，含新池与重复启用、过期目标单独拒绝及重新计算目标后成功；核对精确 abort、业务资源/表项/事件回滚、缓存字节和待生效占比；[EE]/[FR]/[ST] 保留隔离拒绝覆盖 |
| FRZ-02 / P0 | 冻结中通过直接入口和 `*_with_cap`/staking contract/vesting/delegation 转调追加、解锁、重新激活、提取、延长锁仓；尝试加入、退出、取消和治理移除；完成后重试合法操作 | 拒绝所有会改变保证金、截止时间推算或候选资格的写入；外层委托份额、费用和临时份额也随事务回滚；解除冻结后恢复可用 | 已有：[NS] 直接质押五入口及非委员会委托四入口，并覆盖委托驱逐的正常/冻结/恢复路径；驱逐 payload 不接受池地址，只能操作签名 owner 自己的池，冻结时精确拒绝于 `stake/0x30014`，白名单、治理表、份额、钱包和事件均回滚。[NT] staking contract本金/分发/佣金请求，vesting授予/终止/管理员提取/批量分发/批量授予及两类合约运营者/佣金矩阵；真实委员 vesting 正收益覆盖批量与单项 `unlock_rewards`：R1/R2 各为原生30、佣金11、净收益19，未冻结后项 `vesting/0x30008` 回滚前项支付和新份额，普通 DKG 冻结时批量及单项均在 `stake/0x30014` 拒绝，授权完成后单项调用支付 R1 并将 R2 解锁为待退出份额，重复调用不重复支付且四节点同版本。[NJ] 成员正常/冻结/恢复与权限顺序。[NQ] 真实委员委托池正入池费、NULL临时份额、旧期已记费用39及两套退出周期表项，追加/解锁/重新激活/提取冻结精确拒绝于 `stake/0x30014`，外层份额/治理/白名单/钱包/事件回滚；授权完成后相同 payload 恢复、独立分流及五节点同版本。[CF]/[ST] 保留能力隔离证据。本项不把授权完成记作真实 transcript 完成 |
| FRZ-03 / P0 | 冻结中修改共识公钥、网络地址、原生质押/奖励参数、相关 feature、缓冲配置或直接安装配置；完成后重试合法修改 | 冻结中拒绝且不替换 PVS 所用配置；正常出块统计和费用累计允许继续；完成后授权修改恢复可用，并按原生规则生效 | 已有：[FR] 直接/缓冲配置冻结；[EE] setter 回滚；[NF] `poc_frozen_public_entries_preserve_plan_and_resume_after_finish` 使用 SDK BLS 密钥和有效 PoP，覆盖共识公钥、validator/fullnode 网络地址、质押上下限、原生奖励参数、奖励率 feature、缓冲与安装配置的正常/冻结/恢复/越权矩阵；冻结时逐字节比较 ValidatorConfig、Features、PendingFeatures、计划/PVS、DKG及业务事件，确认普通转账、gas、费用事件和旧委员会提案统计仍增长，完成后重放合法输入并按同版本核对生效值 |
| FRZ-04 / P0 | 冻结前留下历史可领收益；冻结中查询并领取，再重复查询/领取，随后提交原计划 | 领取成功，金额符合冻结前已生效权益；只改变领取相关状态，不改变目标、cutoff、保证金、分流快照或未来分配；最终仍提交原计划且不重复结奖 | 已有：[NF] `poc_nonzero_claim_during_frozen_dkg_preserves_cached_target` 与 `poc_nonzero_mixed_claim_during_frozen_dkg_preserves_cached_target` 分别执行 0/3000 占比；按已安装奖励率、提案统计和 U256 模型核对非零领取、小数权益、重复查询/领取、两路余额及事件，提交原计划并检查缓存清理；[ST]/[EE] 保留原隔离覆盖 |

### 3.8 治理配置与既有代币语义

| ID / 级别 | 前置条件与步骤 | 预期结果 | 现有自动化 / 补充点 |
| --- | --- | --- | --- |
| GOV-01 / P0 | 未冻结时排定 E+1 的 PoC 参数，覆盖并取消，再提交；尝试过去/当前 Epoch、超部署上限、无权限修改 | 待生效配置能替换/撤销，当前权重与旧期奖励基数不提前变化；非法修改回滚；不重置首次 PoC Epoch 或指数基线 | 已有：[NG] 直接 PoC 创世后的 E+1/E+2、覆盖/取消（含空项）、过去/当前 Epoch、非法参数/部署容量/数值上界及越权矩阵；精确状态差异、旧期奖励基数、首次 Epoch 和指数基线，成功安装及配置清理；冻结恢复见 [NF]，原隔离覆盖见 [AC]/[GE] |
| GOV-02 / P0 | 默认边界 B=61，在周期中途将长度 60 改为 2；另设置 0 和使边界加法溢出的长度 | 已确定边界仍为 61，提交到 61 后下一边界为 63；已排定到 B 的变化不顺延；0/溢出拒绝，保留比例和指数基线不重置 | 已有：[PS] 最大长度和边界溢出；[NP] `poc_power_period_zero_rollover_and_historical_claim` 实际推进 60→2、B=61→63，核对已排持仓和指数；0/u64 上限拒绝同时回滚先行的合法奖励占比排期及事件 |
| GOV-03 / P0 | PoC 生效后，构造代币保证金 100 Octa、共识权重 10 power 的池；分别覆盖 Open/Controlled 和原生占比 0/3000；查询治理投票权；正原生奖励下使用真实委托池查询入池费 | 同一版本下共识投票使用 10 power，治理权重仍按原生代币口径；原生占比 0 时入池费为 0；正占比按已安装收益上限、佣金和整数规则计算，可因零收益等条件为 0，不能固定断言免费；奖励复投后的治理权重按更新的原生口径核对 | 已有：[NW] 两项节点测试覆盖 Open/静态 Controlled、0/3000 占比、100 Octa 本金与 10 power、追加/待退出余额、原生复投后的治理权重及 PoC 领取不改权重；[NQ] 覆盖 Open 委员委托池的 0/3000 占比，以及 Controlled 委员委托池在 3000 占比、3735 佣金下的入池费独立模型、实际追加、治理原生权重和同版本状态；[DG] 保留原治理及安装上下文报价测试 |
| GOV-04 / P0 | 直接 PoC 创世后通过治理排定原生占比，覆盖、取消、再排期；分别指定 E+1/E+2、当前/过去 Epoch、10001、无权限调用和无待生效变更时取消；冻结和完成路径与 FRZ-01、EPO-01 联合验证 | 合法排期只改变待生效项；已安装占比不提前改变，达到目标 Epoch 提交时安装且清空待生效项；非法请求核对模块/代码，配置和事件原子回滚；计划内旧期结算仍使用旧占比，快照 Epoch 始终与奖励上下文一致 | 已有：[NR] `poc_reward_split_governance_lifecycle_and_old_epoch_rewards` 补直接创世后的完整排期/取消/错误/事件矩阵，按旧期表现独立核对两路金额；[ST]/[RS] 配置边界，[EE]/[DF] 回滚与五种完成路径，冻结矩阵见 [NF] |
| GOV-05 / P0 | Open、动态换员、容量至少 6、最低权重 10：当前最低 5 人、增长率 25%，排定最低 4 人后把增长率改为 20%；另从相同初态先改增长率，再排定最低 4 人；撤销待生效参数后重试 | 第一种顺序中当前配置合法但待生效配置不合法，原生更新必须拒绝并回滚；第二种顺序中原生更新合法、后续 PoC 排期拒绝；撤销待生效项后 20% 更新可成功。每笔操作同时满足当前与待生效 PoC 参数，不能只校验一份配置 | 已有：[SN] `poc_governance_growth_validates_current_and_pending_params` 用两份五节点创世覆盖两种治理顺序、精确 `poc_accounting/0x10007`、前置分流排期及事件回滚、取消或恢复增长率后的成功重试；行为依据 [PA] `validate_native_config`、[SC] `update_voting_power_increase_limit` |

### 3.9 数值、容量与支持期限

| ID / 级别 | 前置条件与步骤 | 预期结果 | 现有自动化 / 补充点 |
| --- | --- | --- | --- |
| NUM-01 / P0 | 原始算力取 0、1、u64 上限；指数取 J、`2^24`、`2^24-1`；保留比例取 0、9995、10000、10001；验证 9900 下的 2758/2759 和 5000 下的 40/41 | 合法输入按精确宽整数模型计算；单版本 units 可存入 u128；指数低于下界或比例非法拒绝。9995 的 `I[10000]=124137862714582947`；9900 的 2758 有效、2759 无效；5000 的 40 有效、41 无效；低于数值下界的新版本不接收 | 已有：[PS] `poc_normalization_rounding_and_maximum` 精确覆盖 raw 0/1/u64 上限与 J/2^24，2^24−1 精确拒绝；`poc_index_horizon_exact_boundaries` 逐周期取整得到 `I[10000]=124137862714582947`，覆盖 9900 的 2758/2759；retention 0/10001 的 `poc_power_store/0x10004`、9995 时钟、5000 下的数值边界预览与上传 `0x30008`；[AC] 保留算力换算交叉验证 |
| NUM-02 / P0 | 分别使当前、E+1、仅 B 的池 units 达到 `2^120` 和超过上限；测试净结果合法但撤销/重建旧链较大的情形 | 等于上限合法、超过上限原子拒绝；仅 B 超限也在写入阶段拒绝，不能等换届失败；合法替换不能因临时累加而误拒；失败后原计划仍可提交 | 已有：[AC] `poc_pool_capacity_accepts_exact_limit_at_each_horizon` 将 E+1、B 推进为当前并逐层核对恰好上限，`poc_future_pool_capacity_rejected` 和 `poc_boundary_only_pool_capacity_rejected` 分别精确拒绝 E+1 与仅 B 的上限加一，`poc_final_capacity_accepts_replacing_large_chain` 验证按最终净结果判断；[EE] `poc_boundary_only_capacity_failure_rolls_back_batch` 核对仅 B 超限的完整快照回滚，修复后经生产换届入口只推进一个 Epoch并清理计划/PVS；[NU] 真实节点覆盖当前/E+1/B 恰好上限、修复提交、大旧链替换及宽整数限幅安装。生产写入在 E+1/B 已阻止超限值，因此该值不能合法成熟为当前状态 |
| NUM-03 / P0 | 配置允许 `max_power = u64::MAX`；只校验实际入选权重总和，覆盖普通及 Chunky 共用目标检查 | 实际总和必须在 `1..=u64::MAX`，不截断；取消人数与单池上限的预设乘积约束 | [ST] `poc_config_accepts_u64_max_power`、`poc_target_checks_actual_total_independent_of_capacity`、`poc_actual_total_rejects_dkg_overflow`；仅操作权重整数向量，不铸造超发行规模代币。[EE] `poc_zero_total_power_defers_sixteen_blocks_without_partial_state` 覆盖启用/关闭 Chunky 的延期和无部分写入 |
| NUM-04 / P1 | 不设奖励期限；在接近 u64::MAX 的 Epoch 启用和结算；长期不领至金库边界；反复领取再入账使累计奖励超过 u64::MAX；提案计数接近上限 | 单池每 Epoch 至多入账一次；累计奖励乘 Q 小于 2^256；实际领取受金库余额约束，权益与残差守恒；计数器溢出明确拒绝，合法长期统计用宽整数计算 | 已有：[AC] `poc_native_preparation_and_permanent_activation`、`poc_default_per_epoch_reward_limits`、`poc_reward_accounting_near_u64_max_epoch`；`poc_full_reward_vault_maximum_pool` / `large_index` 覆盖金库恰达 u64::MAX；`poc_recycled_rewards_exceed_u64_lifetime` / `maximum_pool` 只铸造一次 10^18 Octa，循环入账累计 2×10^19 Octa 后仍能精确领取；[ST] `poc_counter_maximum_and_unrelated_indices`、`poc_counter_success_overflow_rejected`、`poc_counter_duplicate_failures_overflow_rejected` 覆盖宽整数统计与计数器溢出 |
| NUM-05 / P0 | 发行规模内的小额保证金，设置 `fee_max` 和费用限额为 `u64::MAX`、原生占比 10000；执行首次安装、追加质押和下一次结算 | 不因政策费用上限误判余额容量或延期；委托入池费奖励上界先用 `u128` 相加再封顶，查询不溢出；旧期实际通胀与费用精确入账，实际金额、有效本金与 `Coin` 合并断言保留；真实代币总量不接近 `u64` 上限 | 已有：[ST] `poc_large_fee_limit_does_not_reserve_actual_balance` 使用 1000 Octa 保证金，验证首次和后续预览可提交、估算封顶 `u64::MAX`、追加 7 Octa 成功，仅结算 10 Octa 通胀和 9 Octa 实际费用，最终本金 1026、PoC 金库 0，费用记录及计划/PVS 清理；不再构造接近 `u64::MAX` 的真实代币余额 |

### 3.10 节点运行、恢复、并行与性能

| ID / 级别 | 前置条件与步骤 | 预期结果 | 现有自动化 / 补充点 |
| --- | --- | --- | --- |
| SYS-01 / P0 | 从 T2 原参数真实创世启动两个节点，核对默认功能、普通/Chunky DKG 和占比 5000；提交至少 10 笔普通转账、一次算力上传及一次分配操作；读取同版本资源 | 两节点持续出块、交易可查询；PoC 初始配置与 GEN-02 相同；当前权重不因未生效上传/分配立刻改变；gas 收费正常 | 已有：[SN] `poc_testnet_defaults_transfer_upload_and_allocate` 在严格 T2 下核对完整原生配置、默认功能及 DKG、10 笔付费转账、上传/分配及同版本状态；[N2] 另保留 T2-S 的非零领奖和立即重启变体 |
| SYS-02 / P1 | T2-F 在 Epoch 开始后记录实际已安装的两池等权，停止一节点；等待在途提交稳定后连续观察 30 秒；恢复节点、提交新交易并等待下一次换届 | 停机时剩余 50% 权重不能产生新 quorum，稳定观察窗口内版本不增长、无新结奖；恢复后可提交并安装后续 Epoch，两节点同版本委员会、奖励上下文和分流快照一致 | 已有：[SN] `poc_testnet_two_nodes_quorum_loss_and_recovery` 在严格 T2-F 下核对实际等权、在途提交稳定、连续 30 秒停机观察、恢复交易及换届、同版本两路余额和结奖去重；恢复预算 90 秒、同版本追赶 30 秒，首轮 DKG 初始化单独记录 |
| SYS-03 / P0 | F4 同步换届并重启一节点；F5 运行退出、回加和替补，再比较当前委员会全部节点 | 换届和重启后使用已安装权重继续共识；重新加入节点完成追赶；当前成员的顺序、公钥、权重和上下文一致；不把已离任节点持续同步作为通过条件 | 已有：[ND] `poc_genesis_restart`、`poc_dkg_replaces_validator_with_growth_budget` |
| SYS-04 / P0 | F4 分别开启普通 DKG、普通+Chunky DKG；再暂停 DKG、重启节点、恢复原会话并授权强制完成 | 真实 transcript 通过现有验证路径；普通/Chunky 使用同一 PVS 目标，相关密钥安装到同一目标 Epoch；冻结重启继续原计划，最终每池只结奖一次 | 已有：[ND] `poc_dkg_installs_session_targets`、`poc_chunky_dkg_installs_same_session_targets`、`poc_frozen_dkg_force_end_and_restart` |
| SYS-05 / P0 | 同一块包含多用户向热门池更新；比较顺序执行与 Block-STM 完整输出；扩展真实上传、覆盖分配、领取及失败交易，跨衰减边界并使用占比 0/3000；用多个固定随机 seed 重放 | 状态、事件、成功/失败结果一致，无重复引用或奖励；独立模型逐 Epoch 核对两路奖励、持仓权益与金库；失败交易仅回滚本笔业务修改；错误身份或非法参数不能因并行顺序被放行 | 已有：[EE] `poc_parallel_hot_pool` 覆盖热门池更新；`poc_parallel_mixed_history_across_decay_and_reward_splits` 以固定 seed 1/7/31337 使用 BothComparison 逐交易比较顺序执行与 Block-STM 完整输出，同块混合真实 PowerStore 上传、分配交换、历史领取和 10001 bps 精确失败，跨 9995 衰减边界并核对指数取整；旧期占比0、安装后3000，逐 Epoch 由独立 U256 模型核对通胀与费用分别分流、持仓权益、奖励指数和金库守恒；[AC] 保留账本随机历史交叉验证 |
| SYS-06 / P1 | 128 候选容量下运行换届、合法成员集合并集、连续 Deferred 与修复；32 用户×4 池上传、4 池领取、8 池覆盖；保持活跃集合不变而增加历史用户数，记录占比、费用限额及全部负载配置 | 业务不变量全部成立；收集 gas、读写 key/字节、事件大小、Block-STM 重执行和节点延迟。Epoch 新增 PoC 工作量不随历史总用户数线性增长；执行前固定硬件、区块 gas/字节预算及 p95/p99 延迟门槛，未填写门槛不得记录性能验收通过 | 部分：[LY] 覆盖 128 人创世，[EE] 覆盖 32×4、八池访问及 VM 读写测量，[ST] 覆盖候选样本。128 真实节点验收自动化已按新增场景最多 7 节点的要求移除；运行期容量、吞吐、历史规模及目标硬件验收仍待设计 |

## 4. 自动化补齐顺序与后续执行

下表保留本轮实现自动化时采用的优先顺序。除 WGT-05 的五旧池到四新池完整节点链和 SYS-06 外，所列用例已有对应自动化；被移除的超过 7 节点场景不能用小规模结果替代。

| 顺序 | 用例 | 原因与完成标准 |
| --- | --- | --- |
| 1 | GEN-03、REW-01、REW-08～10、GOV-03～04、NUM-05 | 已按新模型覆盖两路金额、旧期快照、佣金、费用政策上限及事件；占比 0 与默认 5000 分别留证 |
| 2 | SYS-01、SYS-02 | 严格 T2 原参数建网和上传/分配、严格 T2-F 的失去 quorum、稳定停机观察和恢复换届，以及独立 T2-S 均已有自动化映射，见 [SN] |
| 3 | PWR-05、PWR-06、GEN-05、GOV-01、GOV-05、WGT-05、EPO-03 | 身份/输入、当前与待生效配置交叉校验及集中度恰好 1/3 已覆盖；WGT-05 的五旧池到四新池完整节点链仍待以不超过 7 节点的方式重构 |
| 4 | FRZ-01～03 | 已按公开入口、能力转调和包装调用建立正常/冻结/恢复/越权矩阵；新增相关入口时仍须同步更新矩阵 |
| 5 | PWR-07、WGT-02、GOV-02、EPO-06 | 已组合覆盖默认 9995 衰减、边界上传、到期保证金、周期长度变化与异步等待，并核对固定 cutoff 和成功提交计数 |
| 6 | SYS-05、SYS-06 | SYS-05 自动化已实现；SYS-06 的超过 7 节点场景已移除，容量或性能声明前仍须重新设计受控验收。已有小规模 gas 样本、编译通过和创世容量均不等于节点吞吐已通过 |

## 5. 执行方式

以下命令从仓库根目录运行，执行当前已经实现的自动化；“部分”及“待补”的新组合必须落成测试后才能计入通过。测试用例编号不能直接作为现有 Rust/Move 测试过滤器。

### 5.1 记录基线与框架缓存

记录提交号、工作区差异摘要（包含未跟踪的 PoC 源码）、原生与 PoC 配置、工具版本、执行器模式和硬件。配置须包括 Epoch 长度、普通/Chunky DKG、有效功能开关、奖励率、费用限额和原生奖励占比，并记录 fixture 与原生默认值的差异。使用真实节点时还需记录节点二进制摘要；不能只记录 Git HEAD 就忽略工作区改动。

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

Move 的 `TEST_FILTER=poc_` 按模块名或完整测试名匹配，因此包含 [RS] 中未以 `poc_` 命名的测试；它不包含所有共享路径的既有原生测试。框架发布前或共享质押/委托路径变更时，另外执行不带该过滤器的框架回归：

```bash
env -u TEST_FILTER REPORT_STATS=1 RUST_MIN_STACK=167772160 \
  cargo test --profile ci -p topo-framework \
  --test move_unit_test move_framework_unit_tests -- --nocapture
```

该命令覆盖 topo-framework 中原有 stake、delegation、staking contract、vesting 等测试；不能仅凭 PoC 名称过滤器的结果宣称这些原生路径已回归。

### 5.3 真实节点

```bash
cargo build --profile ci -p aptos-node --features failpoints,smoke-test

RUST_MIN_STACK=167772160 SMOKE_TEST_BIN_DIR="$PWD/target/ci" \
  cargo test --profile ci -p smoke-test --lib \
  --features aptos-config/failpoints poc_ -- --test-threads=1 --nocapture
```

节点测试现已集中到 `testsuite/smoke-test/src/poc/`，保留 [ND] 中五个四/五节点场景和 [N2] 中的 T2-S 双节点场景，并增加严格 T2/T2-F、公开交易、治理顺序、分配/算力/奖励生命周期、冻结、集中度、保证金限幅、费用分流、成员交易、合约冻结及委托奖励测试，当前共 72 项；所有新增场景最多启动 7 个节点，精确映射和剩余缺口见 [PoC smoke 说明][SN]。统一使用 `poc_`，新增用例也须保持可被回归命令选中。可将命令末尾替换为 `-- --list` 检查测试集合；列出测试不等于执行通过。

**严格 T2 默认配置、上传/分配及严格 T2-F 停机恢复已增加独立自动化，映射见 [SN]；只有实际执行结果才能作为验收证据。** 现有 T2-S 关闭 Chunky DKG 的配置须明确记录，不能只标为“默认测试网”。故障注入只用于隔离测试网络；节点二进制、缓存与测试程序必须来自一致的源码基线。

当前 F4/F5 同步/普通 DKG 的单次 Epoch 等待一般为 90 秒，Chunky 用例为 240 秒，T2-S 换届等待为 120 秒，同版本追赶为 30 秒；成员用例包含多次等待，应分别记录。SYS-02 的 30 秒停机观察须在在途提交稳定后开始，完整记录停止、稳定、恢复及追赶阶段。节点编译和启动耗时单独统计，不用提高业务超时来掩盖停滞。

### 5.4 执行分层

| 触发时机 | 范围 |
| --- | --- |
| 每次 PoC 相关变更 | 受影响 P0 的 Move/Rust 回归；算术或时序修改增加独立模型与 VM 用例 |
| 每日集成 | 全部已实现 P0、严格 T2/T2-F、独立 T2-S/四节点/五节点 smoke、多个固定随机 seed；其余未补齐组合继续记录缺口 |
| 默认配置或框架发布前 | M/T2 原参数创世、严格 T2 节点和 T2-F 停机恢复、真实普通/Chunky DKG、两路奖励和原生共享路径回归、全部 P0 和适用 P1；核对最终节点与 bundle 摘要，T2-S 不代替默认配置验收 |
| 容量或性能声明前 | SYS-06 在目标硬件和实际区块预算下执行；填写用户量、候选数、负载、重执行、延迟及读写规模，不将 VM 双执行比较耗时当作 TPS |

## 6. 验收与结果记录

每个子用例至少保存：

| 字段 | 内容 |
| --- | --- |
| 用例与变体 | 例如 `REW-01 / native_bps=3000 / inflation=1 / fee=39`；使用的 M/T2/T2-F/T2-S/F4/F5/A 配置；每个参数组单独记录 |
| 自动化映射 | 精确 Rust 模块/测试名或 Move 模块/函数、断言位置和层级；明确验证哪些步骤、还缺哪些步骤，不以函数存在代替覆盖完成 |
| 基线 | 提交号、工作区差异摘要、bundle/节点摘要、完整有效配置 |
| 输入与执行 | 操作顺序、角色地址、交易哈希、开始/结束 ledger version；不记录私钥 |
| 预期 | 精确整数、状态/事件差异、错误模块与 abort code 或 Deferred 原因 |
| 实际 | 查询与交易结果、相关资源/表项快照、事件、gas、分阶段耗时 |
| 结果 | 未执行 / 通过 / 失败 / 阻塞；保留首次执行及重跑各自结果，填写失败原因、日志位置和复现 seed；未实现或被过滤的变体不记通过 |
| 性能验收 | SYS-06 填写目标硬件、历史用户量、候选数、负载、区块 gas/字节预算及 p95/p99 延迟阈值和实测值；缺少阈值仅作测量记录 |

交付验收要求：

1. P0 的每个适用子用例均有当前源码与最终 bundle 的执行证据；未实现、跳过、超时均不能记为通过。
2. 发生业务拒绝时核对错误模块/代码和原子性；正常提交时验证权重、奖励上下文、分流快照、两路金额守恒和计划生命周期，不能只检查最终 Epoch 增加。
3. 双节点验收明确“两个等权节点均在线才能继续提交”的预期，并记录实际已安装权重。T2-S 的立即重启、四节点恢复均不代替 SYS-02 的完整稳定停机观察；默认双节点交付前 SYS-01、SYS-02 都须完成。
4. 真实 DKG 与 VM 五路径差分分别留证；单次创世支持 128 人不代表运行期容量、吞吐或故障恢复已经签收。
5. 所有部分覆盖项记录剩余步骤；性能结果附具体运行环境和采用的预算阈值。历史成功记录仅供定位，必须区分本次执行。
6. 默认占比 5000 与显式占比 0 分别留证；原生佣金、委托份额和复投的变化不可误记为 PoC 金库异常，也不能用零占比 fixture 的结果替代默认分流验收。

## 7. 源码与已有测试索引

| 引用 | 文件及用途 |
| --- | --- |
| [VM] | Rust PoC 默认值、真实创世 bundle 调用与状态重载测试 |
| [LY] | 当前 Layout 下主网最低人数、最高容量、人数不足及奖励占比清单解析测试 |
| [GE] | Move PoC 创世、可治理默认值和创世专用入口限制 |
| [PW] | 原始版本、上传权限、时钟与指数的生产实现 |
| [PS] | 指数、精度、周期时钟、期限与重复初始化测试 |
| [PV] | 双版本窗口、零版本、首次写入与上传/分配顺序测试 |
| [AC] | 持仓、池聚合、检查点、权益参考模型与容量测试 |
| [PA] | PoC 账本生产实现；当前与待生效参数的交叉校验 |
| [RS] | 奖励分流配置、Epoch 快照、分流取整及边界测试 |
| [SC] | 原生质押配置更新及其 PoC 兼容性校验 |
| [ST] | 权重增长、保证金、成员变更、两路奖励、费用政策上限、奖励上下文与计划测试 |
| [FR] | 配置直接入口及缓冲配置冻结测试 |
| [CF] | staking contract、vesting、delegation 能力转调冻结测试 |
| [DG] | 治理代币权重、委托入池费、原生份额/佣金及分流测试 |
| [EE] | 生产 VM 原子回滚、watchdog、热门池并行及读写测量 |
| [DF] | 同一快照的五种换届完成路径差分 |
| [ND] | 真实节点同步、DKG、Chunky、成员替换和冻结恢复 |
| [N2] | T2-S 双节点真实转账、非零领奖、立即重启及同版本比较 |
| [SB] | 本地 smoke 构建器；默认关闭 Chunky DKG 的覆盖项 |
| [SN] | PoC 节点测试目录、严格 T2/T2-F、公开入口及治理顺序测试映射 |
| [NA] | 真实节点分配生效、八池替换与检查点释放 |
| [NP] | 固定 60 Epoch 周期及第二边界、创世算力重放拒绝、版本滚动与历史权益 |
| [NR] | 真实治理奖励占比生命周期、旧期金额与隔离算术矩阵 |
| [NF] | 真实 DKG 冻结入口矩阵及非零历史领奖 |
| [NE] | 真实费用分流、BlockEpilogue 记账、双用户领取及回滚 |
| [NB] | 保证金限幅下 1 Octa 通胀与 39/27 费用的精确领取 |
| [NC] | Open/Controlled 集中度边界、真实区块延期及修复 |
| [NG] | PoC 参数治理生命周期、复合配置回滚及旧基数结奖 |
| [NS] | 直接质押及委托包装的冻结、份额回滚和恢复 |
| [NT] | staking contract/vesting 包装的真实本金、正收益批量解锁、分发和冻结回滚 |
| [NM] | 竞争候选修复、运营者轮换及退出取消的节点交易链 |
| [NW] | Open/静态 Controlled 的原生治理权重和奖励复投 |
| [NQ] | 真实委员委托池的入池费、临时份额、1 Octa 原生费用/通胀、分流/佣金边界及 PoC 权益 |
| [NK] | 两期小数奖励与三期池级余数、等量换仓及检查点引用释放 |
| [NJ] | 普通 DKG 冻结中成员公开入口、原请求消费与恢复 |
| [NL] | 四类保证金的精确到期边界及 DKG 跨真实到期、周期边界的固定 cutoff |
| [NU] | 真实上传的边界/E+1容量回滚、修复至2^120、大旧链替换及宽整数限幅安装 |
| [NX] | 原始/保证金/最大权重三种限幅与整数准入、补保证金重入 |

需求依据：[当前 PoC 设计](POC_CONSENSUS_V2_MINIMAL_POWER_REWARD_DESIGN.md)、[实现方案](POC_CONSENSUS_V2_MINIMAL_POWER_REWARD_IMPLEMENTATION.md)、[创世默认值与验证说明](POC_GENESIS_IMPLEMENTATION_CHECKS.md)。历史执行记录见[实现与主审记录](POC_CONSENSUS_V2_IMPLEMENTATION_REVIEW.md)；其中涉及旧版迁移的历史条目不纳入本计划。

[VM]: ../../aptos-move/vm-genesis/src/poc.rs
[LY]: ../../crates/aptos-genesis/tests/poc_mainnet_defaults.rs
[GE]: ../../aptos-move/framework/topo-framework/sources/genesis.move
[PW]: ../../aptos-move/framework/topo-framework/sources/poc/poc_power_store.move
[PS]: ../../aptos-move/framework/topo-framework/tests/poc_power_store_tests.move
[PV]: ../../aptos-move/framework/topo-framework/tests/poc_power_version_tests.move
[AC]: ../../aptos-move/framework/topo-framework/tests/poc_accounting_tests.move
[PA]: ../../aptos-move/framework/topo-framework/sources/poc/poc_accounting.move
[RS]: ../../aptos-move/framework/topo-framework/sources/poc/poc_reward_split.move
[SC]: ../../aptos-move/framework/topo-framework/sources/configs/staking_config.move
[ST]: ../../aptos-move/framework/topo-framework/sources/stake.move
[FR]: ../../aptos-move/framework/topo-framework/tests/poc_freeze_tests.move
[CF]: ../../aptos-move/framework/topo-framework/tests/poc_capability_freeze_tests.move
[DG]: ../../aptos-move/framework/topo-framework/tests/poc_delegation_tests.move
[EE]: ../../aptos-move/e2e-move-tests/src/tests/poc_consensus.rs
[DF]: ../../aptos-move/e2e-move-tests/src/tests/poc_transition_differential.rs
[ND]: ../../testsuite/smoke-test/src/poc/mod.rs
[N2]: ../../testsuite/smoke-test/src/poc/testnet_compat.rs
[SN]: ../../testsuite/smoke-test/src/poc/README.md
[NA]: ../../testsuite/smoke-test/src/poc/allocation_lifecycle.rs
[NP]: ../../testsuite/smoke-test/src/poc/power_lifecycle.rs
[NR]: ../../testsuite/smoke-test/src/poc/reward_split_lifecycle.rs
[NF]: ../../testsuite/smoke-test/src/poc/freeze.rs
[NE]: ../../testsuite/smoke-test/src/poc/fee_rewards.rs
[NB]: ../../testsuite/smoke-test/src/poc/bond_rewards.rs
[NC]: ../../testsuite/smoke-test/src/poc/concentration.rs
[NG]: ../../testsuite/smoke-test/src/poc/power_governance.rs
[NS]: ../../testsuite/smoke-test/src/poc/stake_freeze.rs
[SB]: ../../testsuite/smoke-test/src/smoke_test_environment.rs
[NT]: ../../testsuite/smoke-test/src/poc/contract_freeze.rs
[NM]: ../../testsuite/smoke-test/src/poc/member_lifecycle.rs
[NW]: ../../testsuite/smoke-test/src/poc/governance_weight.rs
[NQ]: ../../testsuite/smoke-test/src/poc/delegation_rewards.rs
[NK]: ../../testsuite/smoke-test/src/poc/reward_checkpoints.rs
[NJ]: ../../testsuite/smoke-test/src/poc/member_freeze.rs
[NL]: ../../testsuite/smoke-test/src/poc/bond_cutoff.rs
[NU]: ../../testsuite/smoke-test/src/poc/upload_capacity.rs
[NX]: ../../testsuite/smoke-test/src/poc/weight_limits.rs
