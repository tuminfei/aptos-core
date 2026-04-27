# POC 集群与 Dashboard 操作手册

本文记录本次从 0 创世、启动 4 节点集群、通过交易修改测试参数、通过前端接口扩容验证者、创建普通用户并代理质押的可复现流程。

## 目标状态

- 本地 4 节点创世启动成功。
- 不修改 Rust 代码，通过交易设置测试参数：
  - `rewards_rate ~= 10000 / 1000000000`
  - `retention_bps_per_period = 10000`
  - `power_period_in_epochs = 1`
- 通过前端接口加入 3 个普通验证者，总 active validator 数量达到 7。
- 每个新增验证者有 5 个普通用户完成代理质押。
- 前端接口返回验证者和用户的质押、奖励、手续费预估信息。

## 目录与服务

- Dashboard 工作目录：`/home/mott/work/topo/topo-chain/poc-dashboard`
- 集群工作目录：`/home/mott/work/topo/topo-chain/poc-dashboard/poc-validator-cluster`
- 主 REST 本机访问：`http://127.0.0.1:36183/v1`，服务监听 `0.0.0.0:36183`
- Dashboard 后端本机访问：`http://127.0.0.1:38000`，服务监听 `0.0.0.0:38000`
- Dashboard 前端代理本机访问：`http://127.0.0.1:35173`，服务监听 `0.0.0.0:35173`
- 服务器外部访问时，把示例里的 `127.0.0.1` 替换为服务器公网 IP 或域名。

## 从 0 启动 4 节点集群

推荐直接使用全流程脚本：

```bash
./full_flow_bootstrap.sh --reset
```

该脚本会停止旧 Dashboard、停止旧集群、删除 `./poc-validator-cluster` 和 `backend/poc_dashboard.db`，然后自动完成 4 节点创世、设置链上测试参数、启动 Dashboard、加入 3 个新验证者、创建 15 个普通用户并代理质押，最后校验数量和奖励字段。

如果不想删除现有集群和数据库，可执行：

```bash
./full_flow_bootstrap.sh
```

常用可调参数：

```bash
TARGET_VALIDATOR_COUNT=7 USERS_PER_NEW_VALIDATOR=5 ./full_flow_bootstrap.sh --reset
VALIDATOR_POWER=1200000000 USER_POWER=100000000 ./full_flow_bootstrap.sh --reset
USER_MINT_AMOUNT=1000000000 USER_DEPOSIT_AMOUNT=500000000 ./full_flow_bootstrap.sh --reset
```

手动流程如下。

在 `poc-dashboard` 目录执行：

```bash
python3 ./scripts/poc_prod_like_validator_cluster.py stop --workdir ./poc-validator-cluster
rm -rf ./poc-validator-cluster
python3 ./scripts/poc_prod_like_validator_cluster.py start --workdir ./poc-validator-cluster --nodes 4 --port-start 36180
python3 ./scripts/poc_prod_like_validator_cluster.py status --workdir ./poc-validator-cluster
```

健康状态应显示 4 个节点 `UP`，REST 端口通常是 `36183`、`36193`、`36203`、`36213`。

## 提交测试参数交易

本流程不改 Rust，用 Move script 交易修改链上测试参数。脚本文件为：

```bash
set_chain_test_params.move
```

执行示例：

```bash
../target/debug/aptos move run-script \
  --url http://127.0.0.1:36183/v1 \
  --sender-account 0xa550c18 \
  --private-key <core_resources_private_key> \
  --script-path set_chain_test_params.move \
  --assume-yes \
  --max-gas 200000 \
  --gas-unit-price 100
```

检查参数：

```bash
curl -sS http://127.0.0.1:36183/v1/view \
  -X POST -H 'Content-Type: application/json' \
  -d '{"function":"0x1::staking_config::reward_rate","type_arguments":[],"arguments":[]}'

curl -sS http://127.0.0.1:36183/v1/view \
  -X POST -H 'Content-Type: application/json' \
  -d '{"function":"0x1::poc_power_store::get_retention_bps_per_period","type_arguments":[],"arguments":[]}'

curl -sS http://127.0.0.1:36183/v1/view \
  -X POST -H 'Content-Type: application/json' \
  -d '{"function":"0x1::poc_power_store::get_power_period_in_epochs","type_arguments":[],"arguments":[]}'
```

## 启动 Dashboard

推荐：

```bash
./dashboard.sh start
./dashboard.sh status
curl -sS http://127.0.0.1:35173/api/v1/system/health
```

如果后台脚本不稳定，可以分别前台启动：

```bash
cd backend
.venv/bin/python -m uvicorn main:app --host 0.0.0.0 --port 38000
```

```bash
cd frontend
npm exec vite -- --host 0.0.0.0 --port 35173
```

## 通过前端接口加入普通验证者

调用的是前端代理接口：

```bash
curl -sS -X POST http://127.0.0.1:35173/api/v1/validators/prepare-join \
  -H 'Content-Type: application/json' \
  -d '{
    "label": "validator-4",
    "power": 1200000000,
    "set_power_period": 1,
    "force_epochs_before_delegate": 1,
    "force_epochs_after_join": 1,
    "mint_amount": 10000000000,
    "deposit_amount": 2000000000,
    "commission_bps": 0
  }'
```

重复提交 `validator-5`、`validator-6`。成功后检查：

```bash
curl -sS http://127.0.0.1:36183/v1/view \
  -X POST -H 'Content-Type: application/json' \
  -d '{"function":"0x1::stake::get_active_validator_count","type_arguments":[],"arguments":[]}'

curl -sS http://127.0.0.1:35173/api/v1/validators
```

本次新增验证者地址：

- `validator-4`: `0x8725ae23b9c42c03f81163cd24a9611aee6826666740b31b537ed390dd4e12e1`
- `validator-5`: `0xf60b6e5a2d775421fbc3b895c82a5e1d6a57cc32f583b9dcf1c37a5fde926784`
- `validator-6`: `0x4ae7c4e2c093641f0f0ecf21a083fc234033f295057188ec3c2f83d80542d08d`

## 创建普通用户并代理质押

每个普通用户通过 `/api/v1/staking/proxy` 一次完成创建账户、铸币、设置算力、强制 epoch、存款、委托。

示例：

```bash
curl -sS --retry 10 --retry-connrefused --retry-all-errors --retry-delay 1 \
  -X POST http://127.0.0.1:35173/api/v1/staking/proxy \
  -H 'Content-Type: application/json' \
  -d '{
    "target_user": "",
    "label": "validator-4-user-1",
    "mint_amount": 1000000000,
    "set_power": 100000000,
    "deposit_amount": 500000000,
    "delegate_to": "0x8725ae23b9c42c03f81163cd24a9611aee6826666740b31b537ed390dd4e12e1",
    "force_epoch": true
  }'
```

对 `validator-4-user-1` 到 `validator-4-user-5`、`validator-5-user-1` 到 `validator-5-user-5`、`validator-6-user-1` 到 `validator-6-user-5` 顺序执行。不要并行提交这类交易，避免 `core_resources` sequence number 冲突。

## 铸造 TOPO

铸造接口：

```bash
curl -sS -X POST http://127.0.0.1:35173/api/v1/topo/mint \
  -H 'Content-Type: application/json' \
  -d '{
    "recipient": "0x506125589b067ffed8797b2fb914266f6dafee161f4becfbf4aa4227395bedc9",
    "amount": 1000
  }'
```

`amount` 的单位是 octas，`1 TOPO = 100000000 octas`。前端输入框显示 TOPO 时会自动换算成 octas 提交。

查询真实 TOPO 余额：

```bash
curl -sS http://127.0.0.1:35173/api/v1/topo/balance/<address>
```

也可以直接查链上 view：

```bash
curl -sS http://127.0.0.1:36183/v1/view \
  -X POST -H 'Content-Type: application/json' \
  -d '{"function":"0x1::coin::balance","type_arguments":["0x1::topo_coin::TopoCoin"],"arguments":["<address>"]}'
```

如果铸造失败并出现：

```text
Transaction failed: Execution failed in 0x1::fungible_asset::unchecked_deposit (on instruction Add)
```

含义是接收账户当前 TOPO 余额加上本次铸造金额超过了 `u64::MAX = 18446744073709551615` octas。修复后的后端会在提交交易前拦截这种请求，并返回类似：

```json
{
  "code": 40003,
  "message": "铸造后余额会超过 u64 最大值。当前余额 ... octas，最多还能铸造 ... octas"
}
```

处理方式：

- 减小本次铸造金额，使其不超过接口返回的“最多还能铸造”数量。
- 或换一个余额较低的新账户接收测试币。
- 不要根据旧 `CoinStore` 资源判断余额；TOPO 已启用 coin/FA pairing，真实余额应使用 `0x1::coin::balance<0x1::topo_coin::TopoCoin>`。

## 最终验证

```bash
python3 ./scripts/poc_prod_like_validator_cluster.py status --workdir ./poc-validator-cluster
```

应显示 7 个节点 `UP`。

```bash
curl -sS http://127.0.0.1:36183/v1/view \
  -X POST -H 'Content-Type: application/json' \
  -d '{"function":"0x1::stake::get_active_validator_count","type_arguments":[],"arguments":[]}'
```

应返回：

```json
["7"]
```

```bash
curl -sS http://127.0.0.1:35173/api/v1/validators
curl -sS http://127.0.0.1:35173/api/v1/watchlist/users
```

期望：

- `/api/v1/validators` 返回 `total = 7`。
- 三个新增验证者 `delegator_count = 6`，包含 owner 自身和 5 个普通代理质押用户。
- `/api/v1/watchlist/users` 返回 `total = 15`。
- 验证者和用户数据里都包含 `rewards` 字段，含：
  - `reward_rate`
  - `pending_fee_octas`
  - `estimated_epoch_reward_octas`
  - `estimated_epoch_fee_octas`
  - `estimated_epoch_total_octas`

## 常见问题

- `max_gas` 必须使用 `200000`。当前链 block gas limit 是 `200000`，使用 `20000000` 会导致交易长时间 pending 或无法上链。
- `retention_bps_per_period` 建议设为 `10000`。默认衰减可能在多次强制 epoch 后让验证者 power 低于最小 stake，导致验证者退出 active set。
- 批量代理质押不要并行发交易。多个请求共用 `core_resources` 时，并行提交容易产生 sequence number 冲突。
- `prepare-join` 的 `mint_amount` 要大于 `deposit_amount`，预留 gas 和流程中产生的费用。
- 铸造大额 TOPO 时要注意接收账户余额上限。账户余额和铸造金额相加不能超过 `18446744073709551615` octas。
- 前端代理偶尔连接拒绝时，可对 `curl` 加 `--retry-connrefused`，或重启前端：

```bash
./dashboard.sh stop-frontend
./dashboard.sh start-frontend
```
