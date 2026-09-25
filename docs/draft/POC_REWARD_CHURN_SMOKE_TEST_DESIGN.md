# PoC 多周期奖励稳定性 smoke 测试设计

## 1. 目标与范围

新增 10、100、1000 Epoch 三档节点测试，覆盖多个算力周期内，多用户反复进行以下操作后的奖励比例稳定性：

- 代币：`add_stake`、`unlock`、`reactivate_stake`、到期 `withdraw`；
- 算力：分配、部分分配、清空分配、重新分配，以及周期边界的新原始算力版本；
- 奖励：跨 Epoch 结算、间隔领取、退出后领取和最终全量领取。

“奖励比例未腐化”使用独立整数账本逐 Epoch 精确判定，不比较浮点百分比，也不设置模糊容差。现有短链用例已覆盖单次分账、小数权益和委托份额；本设计补充长期反复进出后的累计漂移、旧权益串账、索引重置和金库失衡。

模型范围是当期全部 5 个验证者池，而不是只有被测委托池。创世为 4 个背景验证者 owner 写入初始算力并全额分配给各自池，这 4 个池具有非零 units、真实提案统计、独立奖励指数和 vault。被测委托池执行逐用户精确核对；4 个背景池执行池级精确计算、事件唯一性、指数单调和全网守恒核对。

## 2. 公共夹具与参考账本

### 2.1 夹具和运行范围

新增 `testsuite/smoke-test/src/poc/reward_churn.rs`，复用现有委托池委员夹具：4 个背景验证者、1 个真实出块的委托池、独立 owner/operator/uploader，以及 N 个同时持有代币和算力的用户。普通和 Chunky DKG 关闭，通过授权换届逐次推进 Epoch；三档均通过治理设置 3 Epoch 算力周期和 3 秒 recurring lockup，不注入时间或奖励。名义 Epoch 时长仍为 3600 秒，避免自动 5 秒换届与显式治理换届竞争。

公共参数默认取：`native_reward_bps=3000`、委托佣金 `3735 bps`、`retention_bps=9995`、费用上限 17 Octa。每名用户初始至少有 100 TOPO active stake 和互不相同的原始算力。质押金额使用带零散 Octa 的值，算力比例在 `10000/7777/3333/0` 间轮换，以持续制造合法取整余量。

奖励账本不设置期限 H。设首次安装的 PoC Epoch 为 `F`，测试记录实际关闭的 Epoch 范围；准备阶段、主循环和无变更收尾均按真实换届推进。收尾至少为 2 轮，并包含等待锁仓到期后应用成熟变化所需的换届。

检查点计数扫描 `F..=current_epoch`；未来聚合变化只在池推进到对应 Epoch 后生成检查点，不预先建立固定期限内的扫描窗口。零奖励入账仍更新每池防重复水位，不能因累计运行时间长而阻止换届。

算力周期不设置部署上限；每次换届核对链上周期、共同指数和下一边界，并确保指数仍不小于 `MIN_PERIOD_INDEX`。

### 2.2 五池模型和累计口径

参考账本分为一个全量池模型和 4 个背景池模型：

- 被测委托池维护原生质押四类本金、各用户 shares、NULL 临时 shares、佣金、锁仓状态和钱包净变化；每个原始算力版本、待生效分配、用户/池 units 和检查点引用；每期 PoC 指数、用户 `Q=2^128` 权益及 vault。
- 每个背景池维护 units、当期 `reward_base_octa`、成功/失败提案数、通胀与费用分流、每期指数增量、vault、累计入账和累计领取。背景池不展开 owner 的逐段用户权益，但池级金额和指数仍按整数公式精确重算。
- 网络模型维护已安装奖励率、原生分流比例、费用开关和限额，并逐期核对 5 池总通胀。对每个池独立计算总通胀后，必须满足 `sum(total_inflation) = sum(active_native_inflation + pending_inactive_native_inflation + poc_inflation)`；每池费用另满足 `distributable_fee = native_fee + PoCRewardCredited.fee`。费用与通胀分别分流、分别取整后才相加。

链上没有“累计入账”或“累计领取”字段。测试另建只增事件归约器：每池累计入账为 `PoCRewardCredited.inflation + fee` 之和，累计领取为 `PoCRewardClaimed.amount` 之和。每个受支持的 closing Epoch 即使入账为零也应为每个结算池发出一条 `PoCRewardCredited`；领取金额为零时没有 `PoCRewardClaimed`，归约器按增加 0 处理。`get_pool` 只提供当前 vault 和指数，必须在同一 ledger version 验证 `vault = 事件累计入账 - 事件累计领取 = 独立模型余额`。事件是链上实际值，只用于核对，不能反向生成模型预期。

预期值只使用交易输入、上一期模型状态、已安装配置、实际提案统计和实际可分发费用计算。链上奖励预览、入池费报价、领取报价及被测模块的分账结果只能作为实际值比较，不能反向喂给模型。

夹具启动时 E1 由 `BlockMetadata` 交易直接关闭，随后加入和启用委托池的两笔治理交易分别关闭 E2、E3。参考账本从零重放这三次结算；对 `BlockMetadata` 自身触发的结算，`version-1` 尚未包含本块结果，因此模型只从该元数据补入 proposer 的一次成功及 `failed_proposer_indices`，再按相同公式核对事件。普通用户交易触发的换届仍完全读取 `version-1` 的提案计数和费用。

### 2.3 必须独立复现的整数路径

计奖基数是最容易写错的第一条路径。模型按下列顺序逐步向下取整：

1. `I[0]=2^64`，`I[p+1]=floor(I[p] * retention_bps / 10000)`；每个周期独立 floor，不能把保留率先做幂再除一次。
2. 先按冻结计划的截止时间计算 `bond_octa = active + pending_active + (locked_until_secs > cutoff_secs ? pending_inactive : 0)`，再计算 `pool_power=floor(units * I[p] / 2^96)`。候选 power 取 `pool_power`、`floor(bond_octa * power_per_ohmp / bond_octa_per_ohmp)` 和 `max_power` 的最小值，并应用与委员会相同的增长预算分配及 `min_power` 资格判断。
3. 以最终安装 power 计算 `reward_base_octa=floor(power * bond_octa_per_ohmp / power_per_ohmp)`；每池每期总通胀为 `floor(reward_base_octa * rate * success / (denominator * (success+failed)))`，无提案时为 0。

委托池同步是第二条易错路径。模型必须同时维护 stake pool 的 active、inactive、pending-active、pending-inactive，delegation pool 的 active shares、按 `ObservedLockupCycle` 分组的 inactive/pending-inactive shares、NULL 入池费 shares，以及 active 与 pending-inactive 两路分别 floor 的运营佣金。实现直接扩展 `delegation_rewards.rs` 的 `Shares` 和 `UnlockModel`，保留其逐次份额换算顺序，不能把两路奖励或佣金合并后只取整一次。

### 2.4 操作、生效和锁仓规则

每轮 `r` 使用固定 seed 选择不同用户：一人追加 `10 TOPO + (r mod 7 + 1) Octa`，一人请求解锁 `11 TOPO + (r mod 5 + 1) Octa`；偶数轮中未在换届时成熟的解锁在下一轮重新激活，若已成熟则按真实状态提取；奇数轮显式等待锁仓到期，以保证提取路径被覆盖。另一名用户将算力分配轮换为全额、部分、空、重新进入。在算力边界前，仅为尚未写入目标周期的用户提交一次新版本，并包含零版本退出及后续周期非零重入。

模型同时保存名义请求额和预计实际额，并复现两层金额调整。底层 `stake::unlock` 和 `stake::withdraw` 分别以池的 active、inactive 截顶；委托入口在此之前先同步，再执行池级 active 检查、用户 shares 余额截顶、最低 10 TOPO 残余/目标余额调整和 shares↔coins 的逐次 floor。模型依据自身状态得到最终 `amount_unlocked`/`amount_withdrawn`，再与委托及底层事件、四类本金、shares 和钱包变化比较。固定 seed 选中用户后，模型在发送交易前断言池级请求可执行且用户实际金额大于 0；用 `u64::MAX` 提取成熟份额，显式覆盖名义额大于可用额的截顶分支。

被测池是当期验证者，`add_stake` 的底层本金进入 pending-active，到 E+1 才并入 active 和计奖保证金；delegation 层仍为全部追加金额发行 shares，并独立计算向上取整的入池费，将费用对应 shares 暂记给 NULL 持有人。令 `upper` 为当期原生奖励上限，`base_net = upper - floor(upper * commission_bps / 10000)`；存在正佣金且 `base_net < upper` 时令 `reserve=1`，否则为 0；`net=base_net+reserve`，入池费为 `ceil(amount * net / (active + pending_inactive + net))`。`upper=0` 时费用为 0。模型独立复现该公式，并将链上 `get_add_stake_fee` 仅作为实际值比较。

pending-inactive 成熟不按固定 N 个 Epoch 推断。模型跟踪 `locked_until_secs`、冻结计划的 `cutoff_secs` 和 `ObservedLockupCycle`：仅当时间已到且下一次换届应用本金变化后，余额才进入 inactive；继续留任的验证者会在换届时自动续锁。需要提取的轮次沿用现有真实等待流程，等待链上时间越过锁仓点后再完成一次授权换届和同步。

Epoch E 的核对顺序固定为：同步需要同步的委托状态；执行用户操作并更新独立模型；读取 closing context、提案计数和可分发费用；独立结算 E；完成换届并安装 E+1；应用已成熟的质押/算力变化；按计划同步或领取。这样可以直接发现新增本金或算力错误继承旧期奖励。

## 3. 用例

| 用例 | 规模与配置 | 操作与重点 | 执行级别 |
| --- | --- | --- | --- |
| `poc_reward_churn_10_epochs_exact` | 10 个主循环 Epoch、10 用户、算力周期 3 Epoch、seed `0x5eed0010` | 安装零通胀，每期达到被测池 17 Octa 费用上限，固定 3000/3735 分流；每期执行代币进出和算力轮换，跨 3 个周期边界；每期全量核对所有用户、5 池、事件和节点状态 | 普通 PoC 回归，非 `ignore` |
| `poc_reward_churn_100_epochs_seeded` | 100 个主循环 Epoch、16 用户、算力周期 3 Epoch、seed `0x5eed0100` | 安装固定非零奖励率，跨 33 个以上周期；第 25/50/75 轮排期 `native_reward_bps` 为 0/10000/3000；第 20/60/80 轮停止被测节点直至出现失败提案，再恢复并在同一 Epoch 等到成功提案；每 7 轮分批领取 | 夜间回归，`ignore` |
| `poc_reward_churn_1000_epochs_soak` | 1000 个主循环 Epoch、32 用户、算力周期 3 Epoch、seed `0x5eed1000` | 安装固定非零奖励率，跨 333 个以上周期；每 100 轮轮换分流比例 `0/1/3000/5000/9999/10000`；稀疏领取、周期性零算力退出和重入，持续检查索引与状态规模 | 候选版本及奖励相关改动后的 soak，`ignore` |

100/1000 档使用每池真实成功/失败提案数和实际可分发费用作为奖励输入；100 档必须主动得到至少 3 个 `success>0 && failed>0` 的池期，1000 档记录自然出现的失败但不重复增加停机成本。零收入 Epoch 仍须正常结算，产生唯一的零额入账事件并验证不重复入账。

主循环后先停止新变更。存在待提取余额时，先按 `locked_until_secs` 真实等待；随后运行至少两个无变更 Epoch，其中第一个换届应用已到期变化，末轮完成稳定态复核。最后显式同步委托池，领取所有用户奖励，并检查所有已成熟变化和检查点均已消费。实际执行的全部收尾换届计入 `D`。未到期且按模型应保留的状态单独报告，不能为了清零而注入时间。

## 4. 必须断言

1. **逐期精确分账和五池守恒**
   - 5 个当期池各有且仅有一条 `(closing_epoch,pool)` 对应的 `PoCRewardCredited` 和 `PoCRewardSplit`，零金额也不例外；
   - 每池通胀和费用分别满足 `native + poc = total`，分别取整后再相加；5 池总通胀满足网络级守恒式；
   - 4 个背景池的 `reward_base_octa`、入账额、指数增量和 vault 与池级模型一致，指数单调不减；
   - 被测池原生四类本金、佣金和 shares 与参考账本完全一致；每个算力用户的新增权益严格等于 `units * floor(poc_reward * Q / pool_units)`；
   - 零本金或零 units 的区间不新增对应收益，新增持仓不分享旧期收益。

2. **累计守恒与取整**
   - 对每个池及 5 池合计均有 `PoC vault = PoCRewardCredited 累计 - PoCRewardClaimed 累计`；零额领取没有事件，累计值保持不变；
   - 奖励指数跨 Epoch、算力周期及用户退出/重入均不重置；每期池级除法余量不结转为下一期指数，用户小数权益不转移给新持仓；
   - 原生 shares 的精确余额和 dust 始终与独立模型一致；辅助界 `coins - sum(各非零持有人可赎回额) < 非零持有人数` 只在显式 `synchronize_delegation_pool` 完成、NULL shares 已释放且 `sum(shares)=total_shares` 的同一版本断言；
   - 任何最终 vault 或 dust 都必须由模型逐项解释，不能用“最终应为 0”代替取整核对。

3. **生命周期与状态规模**
   - add-stake 的 pending-active 与 E+1 生效、解锁和提取的实际截顶金额、四类本金迁移、算力 E+1 生效及周期边界版本均在正确时点变化；
   - 锁仓成熟同时符合 `locked_until_secs <= cutoff_secs`、换届和 `ObservedLockupCycle` 的模型；同一目标周期首个原始版本生效，零版本退出后可在后续周期重新进入；
   - 成熟检查点引用最终归零并释放；原生 `Table` 没有可读长度，因此在每个采样点扫描 `first_poc_epoch ..= current_epoch` 的全部可达 key 计数，最终逐 key 断言不存在；每个持仓和池的未来变化不超过协议上限；
   - 每个 closing Epoch 每池只入账和分流一次；正额领取恰有一条事件，零额领取无事件，均不得重复。

4. **节点一致性与可复现性**
   - 10 档每期、100 档每 10 期、1000 档每 50 期及所有周期边界，在同一 ledger version 比较全部在任节点的 5 个池账本、`AccountingState`、质押状态和已安装上下文；
   - 失败信息打印 seed、Epoch、周期、ledger version、最近 20 个操作及模型/链上差异；
   - 固定 seed 必须稳定复现；本地覆盖 seed 时须在日志首行输出。

任何金额、shares、fixed-point 权益、索引、引用、事件数量或守恒式不相等即失败。

## 5. 实现与验收

三项测试共用 `run_reward_churn(RunConfig)`、一个 `NetworkModel`、一个逐用户 `TestPoolModel` 和 4 个 `BackgroundPoolModel`。短档逐期读取全部用户和池；长档每笔核对被操作用户，每个采样点、周期边界和最终阶段再做全量扫描。背景池复用 `fee_rewards.rs` 中独立重算通胀与指数的模式，委托份额复用并扩展 `delegation_rewards.rs` 的 `Shares`/`UnlockModel`，跨节点快照复用 `upload_capacity.rs` 的逐池读取方式。实现不新增依赖。

测试实现合入时同步更新 `testsuite/smoke-test/src/poc/README.md` 的文件表、测试总数和运行矩阵。10 档沿用全量 `poc_ -- --test-threads=1`；100 档给出 nightly 的 `--ignored --exact` 命令；1000 档给出候选版本/奖励改动后的人工或专用作业命令。两项 ignored 测试必须单独指名，不能用一次无筛选的 `--ignored` 意外并行或串入其他长测。

验收记录至少包含：总耗时、最终 ledger version、`F` 和实际 closing 范围、正收益/零收益 Epoch 数、主动制造的混合提案池期数、各分流档累计金额、按事件归约的累计入账/领取、最终 vault/dust、最大检查点数和跨节点比较次数。3 秒锁仓和 3 Epoch 算力周期下，10 档硬预算仍为 15 分钟内，100 档目标 0.25–1 小时，1000 档目标 2–6 小时；据此设置 CI/作业超时，不能无上限等待。10 档每期填满 17 Octa 费用上限所产生的额外转账必须计入耗时。
