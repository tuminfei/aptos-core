# PoC 节点 smoke 测试

对应 [核心测试用例](../../../../docs/draft/POC_CORE_TEST_CASES.md) 中需要真实节点、签名交易和跨节点状态证据的场景。所有测试名称包含 `poc_`，统一从仓库根目录运行：

```bash
cargo build --profile ci -p aptos-node --features failpoints,smoke-test
RUST_MIN_STACK=167772160 SMOKE_TEST_BIN_DIR="$PWD/target/ci" \
  cargo test --profile ci -p smoke-test --lib \
  --features aptos-config/failpoints poc_ -- --test-threads=1 --nocapture
```

本地可将构建和测试都改为默认 dev profile，并将二进制目录改为 `$PWD/target/debug`；执行记录必须注明实际 profile 和节点摘要。用 `-- --list` 核对过滤器，仅列出测试不能计为运行通过。

| 文件 | 文档用例及配置 | 主要证据 |
| --- | --- | --- |
| [defaults.rs](defaults.rs) | SYS-01，严格 T2 | 原生测试创世参数、功能与普通/Chunky DKG 默认值，3000 分流快照，10 笔转账、上传、分配和同版本比较 |
| [recovery.rs](recovery.rs) | SYS-02，严格 T2-F | 实际等权、在途提交稳定、连续 30 秒无 quorum 观察、恢复交易及换届、结奖去重 |
| [transactions.rs](transactions.rs) | PWR-02/03/05/06、ALC-01 的公开入口组合，显式 A 变体 | 权限与输入矩阵、明确零版本、精确 Move abort、交易前后业务快照和事件回滚 |
| [governance.rs](governance.rs) | GOV-05，五节点 A 变体 | 当前/待生效参数的两种修改顺序、精确拒绝、前置分流排期及事件回滚、取消或恢复增长率后重试 |
| [mod.rs](mod.rs) | SYS-03/04，F4/F5 | 同步、普通/Chunky DKG、成员替换、冻结重启和授权强制完成 |
| [testnet_compat.rs](testnet_compat.rs) | 原有 T2-S | 关闭 Chunky DKG，真实非零领奖及立即重启；单独保留此变体 |

T2/T2-F 显式恢复 `SwarmBuilder` 底层改写的原生测试创世参数。T2-F 仅缩短 Epoch 为 10 秒。首轮 Chunky 初始化单独计时，不计入停机观察或恢复换届预算。跨节点资源固定同一 `ledger_version`；失败交易允许正常收取 gas、更新序列号和发出费用事件。

上传输入矩阵中的 32 名新用户批次使用 100 Octa/gas、最多 2,000,000 gas，上传钱包注资 10 TOPO；其余交易使用 1 Octa/gas。日志记录批次实际 gas 和费用，供复现存储费预算；这项功能验证不作为 SYS-06 性能验收。

这些 smoke 测试不替代文档中的独立整数模型、VM 损坏状态注入、Block-STM 差分或 128 候选性能验收；SYS-05/06 的完整覆盖仍需对应执行器和目标硬件负载。完整用例是否覆盖，以核心文档逐项要求和实际执行记录为准。

公开入口矩阵尚未包含 ALC-05 的八池配置并集、上传后项容量溢出、周期推进后的过去目标、零版本生效后的历史领奖及完整冻结/恢复矩阵。
