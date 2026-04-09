#!/usr/bin/env python3
"""
POC Multi-App Test — 模拟 3 个 Dapp + 20 个用户的完整 POC 流程测试

使用前:
  pip install cryptography requests
  python3 poc_multi_app_test.py

重新生成密钥:
  python3 poc_multi_app_test.py --generate-keys

python3 poc_multi_app_test.py --continuous \
    0xf4ba012cbe715c0efa5ac5810d23b46bcf7d0bb8d69f1d3351396bd54291aa69 \
    0x2e96aae32e04c83bd90cc41449a7b1d1082a590ec6141eead347bb69b7f1180f \
    0x3663636d2c383de82cf7fd92f32664af5b6b8fb1f03019dafeddf46ccd1e1495
"""

import hashlib
import json
import os
import random
import re
import subprocess
import sys
import time

import requests

# ============================================================
# 配置 (可修改)
# ============================================================
NUM_APPS = 3          # App 数量
NUM_USERS = 20        # 用户数量

REST_URL = "http://120.26.182.36:8080/"
FAUCET_URL = "http://120.26.182.36:8081"
POC_FRAMEWORK = "0xbfe262acf85005487af8911dc00d3587178c26bd0ff5443a89614da5f823028d"
FW_PRIVATE_KEY = "0xbce37e059c3b78829f1f8fb3d56c473ac2de8516df7cbf4ae4ad72361184c8c1"
PACKAGE_DIR = os.path.dirname(os.path.abspath(__file__))
MAX_GAS = 1000000
GAS_UNIT_PRICE = 100
FAUCET_AMOUNT = 1_000_000_000
KEYS_FILE = os.path.join(PACKAGE_DIR, "poc_test_keys.json")

# App 配置模板，部署时按 NUM_APPS 截取或循环扩展
_APP_TEMPLATES = [
    {"name": "Alpha", "symbol": "PDEQ-A", "uri": "https://app-alpha.example.com", "supply": 1_000_000_000_000, "price": 100, "decimals": 9},
    {"name": "Beta",  "symbol": "PDEQ-B", "uri": "https://app-beta.example.com",  "supply": 500_000_000_000,  "price": 200, "decimals": 9},
    {"name": "Gamma", "symbol": "PDEQ-G", "uri": "https://app-gamma.example.com", "supply": 2_000_000_000_000, "price": 50,  "decimals": 9},
    {"name": "Delta", "symbol": "PDEQ-D", "uri": "https://app-delta.example.com", "supply": 800_000_000_000,  "price": 150, "decimals": 9},
    {"name": "Epsilon","symbol":"PDEQ-E", "uri": "https://app-epsilon.example.com","supply": 1_500_000_000_000, "price": 80,  "decimals": 9},
]

APP_CONFIGS = [_APP_TEMPLATES[i % len(_APP_TEMPLATES)] for i in range(NUM_APPS)]

# ============================================================
# 密钥生成
# ============================================================
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat


def generate_keypair():
    pk = Ed25519PrivateKey.generate()
    priv_hex = pk.private_bytes_raw().hex()
    pub_bytes = pk.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    account = hashlib.sha3_256(pub_bytes + b"\x00").hexdigest()
    return {"private_key": f"0x{priv_hex}", "account": f"0x{account}"}


def generate_all_keys(n_apps=3, n_users=20):
    """动态生成全部密钥，每次部署都是全新账户"""
    app_keys = [generate_keypair() for _ in range(n_apps)]
    user_keys = [generate_keypair() for _ in range(n_users)]
    return app_keys, user_keys


def save_session(app_keys, user_keys, app_objects):
    """保存密钥和部署信息到 JSON"""
    data = {
        "app_keys": app_keys,
        "user_keys": user_keys,
        "app_objects": app_objects,
        "app_configs": APP_CONFIGS,
        "poc_framework": POC_FRAMEWORK,
        "rest_url": REST_URL,
        "saved_at": time.strftime("%Y-%m-%d %H:%M:%S"),
    }
    with open(KEYS_FILE, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    info(f"会话已保存到 {KEYS_FILE}")


def load_session():
    """从 JSON 加载密钥和部署信息"""
    if not os.path.exists(KEYS_FILE):
        fail(f"未找到 {KEYS_FILE}，请先运行: python3 poc_multi_app_test.py")
        sys.exit(1)
    with open(KEYS_FILE) as f:
        data = json.load(f)
    info(f"从 {KEYS_FILE} 加载会话 (保存于 {data.get('saved_at', '?')})")
    for i, obj in enumerate(data["app_objects"]):
        info(f"  App {i} ({APP_CONFIGS[i]['name']}): {short_addr(data['app_keys'][i]['account'])} -> {short_addr(obj)}")
    return data["app_keys"], data["user_keys"], data["app_objects"]

# ============================================================
# 颜色输出
# ============================================================
GREEN = "\033[0;32m"
CYAN = "\033[0;36m"
RED = "\033[0;31m"
YELLOW = "\033[1;33m"
BOLD = "\033[1m"
NC = "\033[0m"


def step(msg):
    print(f"\n{CYAN}{'=' * 60}{NC}")
    print(f"{CYAN}  {msg}{NC}")
    print(f"{CYAN}{'=' * 60}{NC}\n")


def info(msg):
    print(f"{GREEN}[OK]{NC} {msg}")


def warn(msg):
    print(f"{YELLOW}[WARN]{NC} {msg}")


def fail(msg):
    print(f"{RED}[FAIL]{NC} {msg}")


def short_addr(addr):
    return f"{addr[:6]}...{addr[-4:]}"


def fmt_amount(raw, decimals=9):
    """将链上原始整数格式化为带小数的字符串"""
    if decimals == 0:
        return str(raw)
    d = 10 ** decimals
    integer = raw // d
    frac = raw % d
    # 去掉尾部多余的 0，最少保留 2 位小数
    frac_str = f"{frac:0{decimals}d}".rstrip("0")
    if len(frac_str) < 2:
        frac_str = frac_str.ljust(2, "0")
    return f"{integer}.{frac_str}"


# ============================================================
# 工具函数
# ============================================================
def run_topo(args, label="", timeout=180):
    """执行 topo CLI 命令，返回 stdout"""
    cmd = ["topo"] + args
    if label:
        print(f"  {BOLD}>{NC} {label}")
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    output = result.stdout + result.stderr
    if result.returncode != 0 and '"success": true' not in output and '"Result": "Success"' not in output:
        fail(f"命令失败: topo {' '.join(args[:3])}...")
        print(output[-500:] if len(output) > 500 else output)
        raise RuntimeError(f"topo command failed: {label}")
    return output


def common_args(private_key):
    return [
        "--url", REST_URL,
        "--private-key", private_key,
        "--assume-yes",
        "--max-gas", str(MAX_GAS),
        "--gas-unit-price", str(GAS_UNIT_PRICE),
    ]


def faucet_mint(account, amount=FAUCET_AMOUNT):
    """从 faucet 领取代币"""
    addr = account.replace("0x", "")
    for attempt in range(3):
        try:
            resp = requests.post(
                f"{FAUCET_URL}/mint",
                params={"auth_key": addr, "amount": amount, "return_txns": "true"},
                timeout=30,
            )
            if resp.status_code == 200:
                return True
        except Exception as e:
            if attempt < 2:
                time.sleep(2)
    warn(f"faucet mint 失败: {short_addr(account)}")
    return False


def deploy_poc_demo(private_key):
    """部署 poc_demo，返回 object address"""
    output = run_topo(
        ["move", "create-object-and-publish-package",
         "--address-name", "poc_demo",
         "--package-dir", PACKAGE_DIR] + common_args(private_key),
        label="部署 poc_demo",
        timeout=300,
    )
    m = re.search(r"object address (0x[0-9a-fA-F]+)", output)
    if m:
        return m.group(1)
    raise RuntimeError(f"无法解析 object address:\n{output[-300:]}")


def register_app(object_addr, private_key, uri, supply, price):
    run_topo(
        ["move", "run",
         "--function-id", f"{object_addr}::poc_demo::register_demo_app",
         "--args", f"string:{uri}", f"u64:{supply}", f"u64:{price}",
         ] + common_args(private_key),
        label=f"注册 app ({uri})",
    )


def whitelist_app(app_admin_account):
    run_topo(
        ["move", "run",
         "--function-id", f"{POC_FRAMEWORK}::poc_registry::whitelist_app_for_poc",
         "--args", f"address:{app_admin_account}",
         ] + common_args(FW_PRIVATE_KEY),
        label=f"白名单批准 {short_addr(app_admin_account)}",
    )


def buy_equity(object_addr, app_admin_account, user_private_key, amount, quiet=False):
    """购买股权，返回 (tx_hash, gas_used) 或 (None, None)"""
    label = "" if quiet else f"buy_equity({amount})"
    output = run_topo(
        ["move", "run",
         "--function-id", f"{object_addr}::poc_demo::buy_equity",
         "--args", f"address:{app_admin_account}", f"u64:{amount}",
         ] + common_args(user_private_key),
        label=label,
    )
    tx_hash = None
    gas_used = None
    m = re.search(r'"transaction_hash":\s*"(0x[0-9a-fA-F]+)"', output)
    if m:
        tx_hash = m.group(1)
    m = re.search(r'"gas_used":\s*(\d+)', output)
    if m:
        gas_used = int(m.group(1))
    return tx_hash, gas_used


def view(function_id, args):
    """调用 view 函数，返回结果"""
    cmd_args = ["move", "view", "--function-id", function_id, "--url", REST_URL]
    for a in args:
        cmd_args.extend(["--args", a])
    result = subprocess.run(
        ["topo"] + cmd_args, capture_output=True, text=True, timeout=30,
    )
    output = result.stdout + result.stderr
    m = re.search(r'"Result":\s*\[([^\]]*)\]', output, re.DOTALL)
    if m:
        raw = m.group(1).strip().strip('"')
        return raw
    return None


# ============================================================
# 主流程
# ============================================================
def main():
    n_apps = NUM_APPS
    n_users = NUM_USERS
    print(f"\n{BOLD}POC Multi-App Test{NC}")
    print(f"{n_apps} 个 Dapp + {n_users} 个用户 随机交互测试\n")

    # 动态生成全新密钥
    step("Phase 0: 生成密钥")
    app_keys, user_keys = generate_all_keys(n_apps, n_users)
    for i, k in enumerate(app_keys):
        info(f"App {i} ({APP_CONFIGS[i]['name']}): {short_addr(k['account'])}")
    info(f"User 0-{n_users-1}: 已生成 {len(user_keys)} 个用户密钥")

    app_objects = [None] * n_apps

    # ---- Phase 1: Fund app accounts ----
    step(f"Phase 1: 为 {n_apps} 个 App 账户领币")
    for i, key in enumerate(app_keys):
        ok = faucet_mint(key["account"])
        status = "OK" if ok else "FAIL"
        info(f"App {i} ({APP_CONFIGS[i]['name']}): {short_addr(key['account'])} -> {status}")
    time.sleep(3)

    # ---- Phase 2: Deploy poc_demo instances ----
    step(f"Phase 2: 部署 {n_apps} 个 poc_demo 合约")
    for i, key in enumerate(app_keys):
        print(f"\n--- App {i} ({APP_CONFIGS[i]['name']}) ---")
        obj_addr = deploy_poc_demo(key["private_key"])
        app_objects[i] = obj_addr
        info(f"object address: {obj_addr}")
        time.sleep(2)

    # ---- Phase 3: Register each app ----
    step(f"Phase 3: 注册 {n_apps} 个 Demo App")
    for i, key in enumerate(app_keys):
        cfg = APP_CONFIGS[i]
        register_app(app_objects[i], key["private_key"], cfg["uri"], cfg["supply"], cfg["price"])
        info(f"App {i} ({cfg['name']}) 注册成功")
        time.sleep(1)

    # ---- Phase 4: Whitelist all apps ----
    step(f"Phase 4: 白名单批准 {n_apps} 个 App")
    for i, key in enumerate(app_keys):
        whitelist_app(key["account"])
        info(f"App {i} ({APP_CONFIGS[i]['name']}) 已加入白名单")
        time.sleep(1)

    # 验证资格
    for i, key in enumerate(app_keys):
        result = view(
            f"{POC_FRAMEWORK}::poc_registry::is_app_eligible_for_poc",
            [f"address:{key['account']}"],
        )
        info(f"App {i} eligible: {result}")

    # ---- Phase 5: Fund users ----
    step(f"Phase 5: 为 {n_users} 个用户领币")
    for i, key in enumerate(user_keys):
        faucet_mint(key["account"])
        if i % 5 == 0:
            info(f"User {i:2d}-{min(i+4, n_users-1):2d} 领币中...")
    time.sleep(3)
    info(f"{n_users} 个用户领币完成")

    # ---- Phase 6: Random buy_equity ----
    step(f"Phase 6: {n_users} 个用户随机购买股权")
    random.seed(42)
    assignments = []

    print(f"{'User':>6} | {'App':>10} | {'Amount':>6} | Status")
    print("-" * 45)

    for i, ukey in enumerate(user_keys):
        app_idx = random.randint(0, n_apps - 1)
        amount = random.randint(1, 20)
        assignments.append({"user": i, "app_idx": app_idx, "amount": amount})

        try:
            buy_equity(
                app_objects[app_idx],
                app_keys[app_idx]["account"],
                ukey["private_key"],
                amount,
            )
            print(f"  U{i:02d}  | {APP_CONFIGS[app_idx]['name']:>10} | {amount:>6} | OK")
        except RuntimeError:
            print(f"  U{i:02d}  | {APP_CONFIGS[app_idx]['name']:>10} | {amount:>6} | FAIL")
        time.sleep(1)

    # ---- Phase 7: Verify results ----
    step("Phase 7: 验证结果")

    app_stats = {i: {"count": 0, "total": 0} for i in range(n_apps)}
    for a in assignments:
        app_stats[a["app_idx"]]["count"] += 1
        app_stats[a["app_idx"]]["total"] += a["amount"]

    print(f"\n{'App':>10} | {'Trades':>7} | {'Expected':>8} | {'On-chain':>8} | {'Equity Sold':>11} | {'On-chain':>8}")
    print("-" * 75)

    for i in range(n_apps):
        trade_count = view(
            f"{app_objects[i]}::poc_demo::trade_count",
            [f"address:{app_keys[i]['account']}"],
        )
        total_sold = view(
            f"{app_objects[i]}::poc_demo::total_equity_sold",
            [f"address:{app_keys[i]['account']}"],
        )
        expected_trades = app_stats[i]["count"]
        expected_sold = app_stats[i]["total"]
        print(f"{APP_CONFIGS[i]['name']:>10} | {expected_trades:>7} | {expected_trades:>8} | {trade_count:>8} | {expected_sold:>11} | {total_sold:>8}")

    # 抽查几个用户余额
    print(f"\n--- 用户余额抽查 ---")
    print(f"{'User':>6} | {'App':>10} | {'Bought':>6} | {'Balance':>8} | Status")
    print("-" * 55)

    for a in assignments[:10]:
        i = a["user"]
        app_idx = a["app_idx"]
        balance = view(
            f"{app_objects[app_idx]}::poc_demo::user_equity_balance",
            [f"address:{app_keys[app_idx]['account']}", f"address:{user_keys[i]['account']}"],
        )
        ok = str(a["amount"]) == str(balance)
        mark = "OK" if ok else "MISMATCH"
        print(f"  U{i:02d}  | {APP_CONFIGS[app_idx]['name']:>10} | {a['amount']:>6} | {balance:>8} | {mark}")

    print(f"\n{BOLD}测试完成!{NC}\n")

    for i in range(3):
        info(f"App {i} ({APP_CONFIGS[i]['name']}): object={app_objects[i]}")

    # 保存会话到 JSON，方便 --continuous 复用
    save_session(app_keys, user_keys, app_objects)

    return app_objects, app_keys, user_keys


# ============================================================
# 持续运行模式
# ============================================================
def continuous_run(app_objects, app_keys, user_keys):
    """持续随机购买，Ctrl+C 停止"""
    step("持续运行模式 (Ctrl+C 停止)")

    tx_count = 0
    ok_count = 0
    fail_count = 0
    n_apps = len(app_objects)
    app_totals = {i: {"count": 0, "equity": 0, "payment": 0} for i in range(n_apps)}
    user_holdings = {}  # {(user_idx, app_idx): equity_amount}
    start_time = time.time()

    # 表头
    print(
        f"  {'#':>4}  {'Time':>8}  {'User':>4}  {'App':>6}  {'Symbol':>6}  "
        f"{'Qty':>12}  {'Pay':>7}  {'UserHold':>12}  {'AppTotal':>12}  "
        f"{'Wait':>5}  St"
    )
    print("-" * 105)

    try:
        while True:
            user_idx = random.randint(0, len(user_keys) - 1)
            app_idx = random.randint(0, n_apps - 1)
            amount = random.randint(1, 10000)
            delay = random.uniform(1, 10)
            cfg = APP_CONFIGS[app_idx]
            payment = amount * cfg["price"]

            tx_count += 1
            ts = time.strftime("%H:%M:%S")
            hold_key = (user_idx, app_idx)

            try:
                buy_equity(
                    app_objects[app_idx],
                    app_keys[app_idx]["account"],
                    user_keys[user_idx]["private_key"],
                    amount,
                    quiet=True,
                )
                ok_count += 1
                app_totals[app_idx]["count"] += 1
                app_totals[app_idx]["equity"] += amount
                app_totals[app_idx]["payment"] += payment
                user_holdings[hold_key] = user_holdings.get(hold_key, 0) + amount

                user_hold = user_holdings[hold_key]
                app_eq = app_totals[app_idx]["equity"]
                st = f"{GREEN}OK{NC}"
            except RuntimeError:
                fail_count += 1
                user_hold = user_holdings.get(hold_key, 0)
                app_eq = app_totals[app_idx]["equity"]
                st = f"{RED}FL{NC}"

            dec = cfg["decimals"]

            print(
                f"  {tx_count:>4}  {ts:>8}  U{user_idx:02d}   {cfg['name']:>6}  "
                f"{cfg['symbol']:>6}  {fmt_amount(amount, dec):>12}  {payment:>7}  "
                f"{fmt_amount(user_hold, dec):>12}  {fmt_amount(app_eq, dec):>12}  "
                f"{delay:>4.1f}s  {st}"
            )

            #time.sleep(delay)

    except KeyboardInterrupt:
        elapsed = time.time() - start_time
        mins = int(elapsed) // 60
        secs = int(elapsed) % 60
        print(f"\n\n{BOLD}{'=' * 60}{NC}")
        print(f"{BOLD}  持续运行汇总  ({mins}m{secs}s, {tx_count} txns, {ok_count} ok, {fail_count} fail){NC}")
        print(f"{'=' * 60}")
        print()
        print(f"  {'App':>6}  {'Symbol':>6}  {'Trades':>6}  {'Equity Issued':>15}  {'Payment':>10}")
        print(f"  {'-'*6}  {'-'*6}  {'-'*6}  {'-'*15}  {'-'*10}")
        for i in range(n_apps):
            s = app_totals[i]
            dec = APP_CONFIGS[i]["decimals"]
            print(f"  {APP_CONFIGS[i]['name']:>6}  {APP_CONFIGS[i]['symbol']:>6}  {s['count']:>6}  {fmt_amount(s['equity'], dec):>15}  {s['payment']:>10}")
        print()

        # 用户持仓汇总（只显示有持仓的）
        if user_holdings:
            print(f"  {'User':>5}  {'App':>6}  {'Symbol':>6}  {'Holdings':>12}")
            print(f"  {'-'*5}  {'-'*6}  {'-'*6}  {'-'*12}")
            for (uid, aid), hold in sorted(user_holdings.items()):
                dec = APP_CONFIGS[aid]["decimals"]
                print(f"  U{uid:02d}    {APP_CONFIGS[aid]['name']:>6}  {APP_CONFIGS[aid]['symbol']:>6}  {fmt_amount(hold, dec):>12}")
            print()


if __name__ == "__main__":
    if "--continuous" in sys.argv:
        # 从 JSON 加载上次部署的会话
        app_keys, user_keys, app_objects = load_session()
        # 补币
        step("补充用户代币")
        for i, key in enumerate(user_keys):
            faucet_mint(key["account"])
            if i % 5 == 0:
                info(f"User {i:2d}-{min(i+4,19):2d} 领币中...")
        time.sleep(2)
        info("领币完成")
        continuous_run(app_objects, app_keys, user_keys)
    else:
        main()
