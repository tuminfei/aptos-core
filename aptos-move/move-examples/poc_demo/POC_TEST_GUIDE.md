# POC Multi-App 测试工具使用文档

## 概述

`poc_multi_app_test.py` 是一个 Python 测试脚本，用于模拟多个 Dapp 和多个用户与 Topo 链 POC（Proof of Contribution）系统的交互。

脚本支持两种模式：
- **部署模式** — 自动生成密钥、部署合约、注册、白名单、购买测试，一键完成
- **持续模式** — 加载已部署的会话，随机用户持续购买股权，模拟真实交易流

## 环境要求

- Python 3.8+
- `topo` CLI 已安装并在 PATH 中
- 网络可达 Topo 链节点

```bash
pip install cryptography requests  # or
# python3 -m .venv ..venv && source ..venv/bin/activate && pip install cryptography requests
```

## 快速开始

```bash
cd poc_demo

# 1. 部署 + 测试（全自动，无需手动操作）
python3 poc_multi_app_test.py

# 2. 持续运行模式（基于上次部署）
python3 poc_multi_app_test.py --continuous
```

## 配置参数

在脚本顶部修改：

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `NUM_APPS` | 3 | App 数量（最多 5 个模板，超出循环复用） |
| `NUM_USERS` | 20 | 模拟用户数量 |
| `REST_URL` | `http://120.26.182.36:8080/` | 链节点 RPC 地址 |
| `FAUCET_URL` | `http://120.26.182.36:8081` | Faucet 地址 |
| `FAUCET_AMOUNT` | 1,000,000,000 | 每个账户领取的代币数量 |
| `MAX_GAS` | 1,000,000 | 最大 Gas |
| `GAS_UNIT_PRICE` | 100 | Gas 单价 |

### App 模板

内置 5 个 App 配置模板，按 `NUM_APPS` 自动截取：

| App | 代币符号 | 初始供应量 | 单价 | Decimals |
|-----|---------|-----------|------|----------|
| Alpha | PDEQ-A | 1,000,000,000,000 | 100 | 9 |
| Beta | PDEQ-B | 500,000,000,000 | 200 | 9 |
| Gamma | PDEQ-G | 2,000,000,000,000 | 50 | 9 |
| Delta | PDEQ-D | 800,000,000,000 | 150 | 9 |
| Epsilon | PDEQ-E | 1,500,000,000,000 | 80 | 9 |

## 部署模式

```bash
python3 poc_multi_app_test.py
```

自动执行以下流程：

1. **Phase 0** — 生成 `NUM_APPS` 个 App 密钥 + `NUM_USERS` 个用户密钥
2. **Phase 1** — 为所有 App 账户从 Faucet 领币
3. **Phase 2** — 部署 `NUM_APPS` 个 poc_demo 合约（`create-object-and-publish-package`）
4. **Phase 3** — 注册每个 App（调用 `register_demo_app`）
5. **Phase 4** — Framework 账户将所有 App 加入 POC 白名单
6. **Phase 5** — 为所有用户从 Faucet 领币
7. **Phase 6** — 每个用户随机选一个 App 购买股权（seed=42，可复现）
8. **Phase 7** — 链上验证 trade_count、total_equity_sold、user_equity_balance

完成后自动保存会话到 `poc_test_keys.json`。

## 持续运行模式

```bash
python3 poc_multi_app_test.py --continuous
```

从 `poc_test_keys.json` 加载上次部署的会话，跳过部署流程，直接进入持续购买循环：

- 随机选用户（U00-U19）
- 随机选 App（Alpha/Beta/Gamma）
- 随机购买数量（1-20）
- 随机等待 1-10 秒
- `Ctrl+C` 停止

### 输出格式

每笔交易一行：

```
  #      Time    User    App  Symbol           Qty      Pay      UserHold     AppTotal   Wait  St
-----------------------------------------------------------------------------------------------------
     1  14:30:22  U07   Alpha  PDEQ-A  0.000000012      1200  0.000000012  0.000000012   3.2s  OK
     2  14:30:26  U13    Beta  PDEQ-B  0.000000005      1000  0.000000005  0.000000005   7.1s  OK
```

| 列 | 说明 |
|----|------|
| # | 交易序号 |
| Time | 时间戳 |
| User | 用户编号 |
| App | App 名称 |
| Symbol | 代币符号 |
| Qty | 本次购买数量（带小数） |
| Pay | 支付金额（Qty × Price） |
| UserHold | 该用户在该 App 的累计持仓 |
| AppTotal | 该 App 累计发放量 |
| Wait | 下次交易等待时间 |
| St | 状态（OK / FL） |

### 停止后汇总

`Ctrl+C` 停止后打印：

- 运行时长、总交易数、成功/失败数
- 每个 App 的交易数、发放总量、收款总额
- 每个用户在每个 App 的持仓明细

## 会话文件

部署完成后自动生成 `poc_test_keys.json`，包含：

```json
{
  "app_keys": [{"private_key": "0x...", "account": "0x..."}, ...],
  "user_keys": [{"private_key": "0x...", "account": "0x..."}, ...],
  "app_objects": ["0x...", "0x...", "0x..."],
  "app_configs": [...],
  "poc_framework": "0x...",
  "rest_url": "http://...",
  "saved_at": "2026-04-09 14:30:00"
}
```

`--continuous` 模式会自动读取此文件，无需手动传参。

## 典型使用场景

### 场景 1：首次部署 + 持续压测

```bash
# 部署 3 个 App + 20 个用户
python3 poc_multi_app_test.py

# 持续压测
python3 poc_multi_app_test.py --continuous
```

### 场景 2：扩大规模

修改脚本顶部：
```python
NUM_APPS = 5
NUM_USERS = 50
```

然后重新部署：
```bash
python3 poc_multi_app_test.py
```

### 场景 3：重新部署（合约变更后）

直接重新运行部署命令，脚本会自动生成全新密钥和账户：
```bash
python3 poc_multi_app_test.py
```

旧的 `poc_test_keys.json` 会被覆盖。

## 相关文件

| 文件 | 说明 |
|------|------|
| `poc_demo/sources/poc_demo.move` | Demo App 合约（register_demo_app, buy_equity） |
| `poc_framework/sources/poc_registry.move` | 注册中心合约（白名单管理） |
| `poc_framework/sources/poc_contribution.move` | 贡献发放合约（ContributionEvent） |
| `poc_demo/poc_test_keys.json` | 自动生成的会话文件 |
| `poc_demo/deploy_and_test.sh` | 单 App 部署脚本（Shell 版） |

## 注意事项

- 每次部署会自动生成全新密钥，无需手动 `topo init`
- 持续模式启动时会自动为用户补充代币
- 用户代币耗尽时 `buy_equity` 会失败（显示 FL），脚本不会中断
- `poc_framework` 账户需要有足够余额支付白名单交易的 Gas
