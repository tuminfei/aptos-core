#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$ROOT_DIR/.." && pwd)"
CONFIG_PATH="${CONFIG_PATH:-$ROOT_DIR/config.yaml}"
CONFIG_PATH="$(python3 -c 'import os, sys; print(os.path.abspath(sys.argv[1]))' "$CONFIG_PATH")"

_read_bootstrap_config() {
    python3 - "$CONFIG_PATH" <<'PY'
import os
import shlex
import sys

try:
    import yaml
except Exception:
    yaml = None

path = sys.argv[1]
raw = {}
if os.path.exists(path):
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
        if yaml is not None:
            raw = yaml.safe_load(text) or {}
        else:
            raw = {}
            section = ""
            for raw_line in text.splitlines():
                line = raw_line.split("#", 1)[0].rstrip()
                if not line.strip():
                    continue
                if not raw_line.startswith(" ") and line.endswith(":"):
                    section = line[:-1].strip()
                    raw.setdefault(section, {})
                    continue
                if not raw_line.startswith(" ") and ":" in line:
                    key, value = line.split(":", 1)
                    value = value.strip().strip('"').strip("'")
                    raw[key.strip()] = int(value) if value.isdigit() else value
                    continue
                if section and raw_line.startswith(" ") and ":" in line:
                    key, value = line.split(":", 1)
                    value = value.strip().strip('"').strip("'")
                    if value.isdigit():
                        value = int(value)
                    raw[section][key.strip()] = value
    except Exception as exc:
        print(f"无法解析配置文件 {path}: {exc}", file=sys.stderr)
        sys.exit(2)

def get(keys, default=""):
    cur = raw
    for key in keys:
        if not isinstance(cur, dict) or key not in cur:
            return default
        cur = cur[key]
    return default if cur is None else cur

def resolve_path(value):
    text = str(value or "").strip()
    if not text:
        return ""
    if os.path.isabs(text):
        return text
    return os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(path)), text))

cluster = raw.get("test_cluster") if isinstance(raw.get("test_cluster"), dict) else {}
keys = raw.get("keys") if isinstance(raw.get("keys"), dict) else {}
core = keys.get("core_resources") if isinstance(keys.get("core_resources"), dict) else {}

values = {
    "CONFIG_CLUSTER_DIR": resolve_path(get(("cluster_dir",), "")),
    "CONFIG_CHAIN_REST_URL": get(("chain", "rest_url"), ""),
    "CONFIG_CHAIN_ID": get(("chain", "chain_id"), 4),
    "CONFIG_BACKEND_HOST": get(("server", "host"), "0.0.0.0"),
    "CONFIG_BACKEND_PORT": get(("server", "port"), 38000),
    "CONFIG_FRONTEND_HOST": get(("frontend", "host"), "0.0.0.0"),
    "CONFIG_FRONTEND_PORT": get(("frontend", "port"), 35173),
    "CONFIG_CLUSTER_PORT_START": cluster.get("port_start", 36180),
    "CONFIG_BASE_NODE_COUNT": cluster.get("base_node_count", 4),
    "CONFIG_TARGET_VALIDATOR_COUNT": cluster.get("target_validator_count", 7),
    "CONFIG_USERS_PER_NEW_VALIDATOR": cluster.get("users_per_new_validator", 5),
    "CONFIG_POWER_PERIOD_IN_EPOCHS": cluster.get("power_period_in_epochs", 5),
    "CONFIG_EPOCH_DURATION_SECS": cluster.get("epoch_duration_secs", 60),
    "CONFIG_VALIDATOR_LOCKUP_PERIODS": cluster.get("validator_lockup_periods", 2),
    "CONFIG_VALIDATOR_LOCKUP_SECS": cluster.get("validator_lockup_secs", cluster.get("validator_exit_cooldown_secs", "")),
    "CONFIG_GOVERNANCE_VOTING_PERIODS": cluster.get("governance_voting_periods", 1),
    "CONFIG_GOVERNANCE_VOTING_DURATION_SECS": cluster.get("governance_voting_duration_secs", ""),
    "CONFIG_MIN_VALIDATOR_STAKE": cluster.get("min_validator_stake", 1000000000),
    "CONFIG_VALIDATOR_STAKE_MULTIPLIER": cluster.get("validator_stake_multiplier", 10),
    "CONFIG_USER_STAKE_MULTIPLIER": cluster.get("user_stake_multiplier", 5),
    "CONFIG_VALIDATOR_POWER": cluster.get("validator_power", ""),
    "CONFIG_VALIDATOR_MINT_AMOUNT": cluster.get("validator_mint_amount", ""),
    "CONFIG_VALIDATOR_DEPOSIT_AMOUNT": cluster.get("validator_deposit_amount", ""),
    "CONFIG_VALIDATOR_COMMISSION_BPS": cluster.get("validator_commission_bps", 0),
    "CONFIG_VALIDATOR_FORCE_EPOCHS_BEFORE_DELEGATE": cluster.get("validator_force_epochs_before_delegate", ""),
    "CONFIG_VALIDATOR_FORCE_EPOCHS_AFTER_JOIN": cluster.get("validator_force_epochs_after_join", 1),
    "CONFIG_USER_MINT_AMOUNT": cluster.get("user_mint_amount", ""),
    "CONFIG_USER_POWER": cluster.get("user_power", ""),
    "CONFIG_USER_DEPOSIT_AMOUNT": cluster.get("user_deposit_amount", ""),
    "CONFIG_USER_FORCE_EPOCH": cluster.get("user_force_epoch", "true"),
    "CONFIG_USER_FORCE_EPOCHS": cluster.get("user_force_epochs", ""),
    "CONFIG_WAIT_TIMEOUT_SECS": cluster.get("wait_timeout_secs", 180),
    "CONFIG_POLL_INTERVAL_SECS": cluster.get("poll_interval_secs", 2),
    "CONFIG_CORE_RESOURCES_ADDRESS": core.get("address", "0xa550c18"),
    "CONFIG_CORE_RESOURCES_PRIVATE_KEY": core.get("private_key", "0xD04470F43AB6AEAA4EB616B72128881EEF77346F2075FFE68E14BA7DEBD8095E"),
}

for key, value in values.items():
    print(f"{key}={shlex.quote(str(value))}")
PY
}

_client_host() {
    case "$1" in
        ""|"0.0.0.0"|"::") printf "127.0.0.1" ;;
        *) printf "%s" "$1" ;;
    esac
}

CONFIG_EXPORTS="$(_read_bootstrap_config)"
eval "$CONFIG_EXPORTS"

_first_non_empty() {
    local value
    for value in "$@"; do
        if [[ -n "$value" ]]; then
            printf "%s" "$value"
            return
        fi
    done
}

CLUSTER_DIR="${CLUSTER_DIR:-${CONFIG_CLUSTER_DIR:-$ROOT_DIR/poc-validator-cluster}}"
CLUSTER_SCRIPT="${CLUSTER_SCRIPT:-$ROOT_DIR/scripts/poc_prod_like_validator_cluster.py}"
APTOS_CLI="${APTOS_CLI:-$REPO_ROOT/target/debug/aptos}"
FRAMEWORK_LOCAL_DIR="${FRAMEWORK_LOCAL_DIR:-$REPO_ROOT/aptos-move/framework/aptos-framework}"
BACKEND_HOST="${BACKEND_HOST:-$CONFIG_BACKEND_HOST}"
FRONTEND_HOST="${FRONTEND_HOST:-$CONFIG_FRONTEND_HOST}"
BACKEND_PORT="${BACKEND_PORT:-$CONFIG_BACKEND_PORT}"
FRONTEND_PORT="${FRONTEND_PORT:-$CONFIG_FRONTEND_PORT}"
CLUSTER_PORT_START="${CLUSTER_PORT_START:-$CONFIG_CLUSTER_PORT_START}"
REST_URL="${REST_URL:-${CONFIG_CHAIN_REST_URL:-http://127.0.0.1:$((CLUSTER_PORT_START + 3))/v1}}"
FRONTEND_URL="${FRONTEND_URL:-http://$(_client_host "$FRONTEND_HOST"):$FRONTEND_PORT}"
BACKEND_URL="${BACKEND_URL:-http://$(_client_host "$BACKEND_HOST"):$BACKEND_PORT}"
CORE_RESOURCES_ADDRESS="${CORE_RESOURCES_ADDRESS:-$CONFIG_CORE_RESOURCES_ADDRESS}"
CORE_RESOURCES_PRIVATE_KEY="${CORE_RESOURCES_PRIVATE_KEY:-$CONFIG_CORE_RESOURCES_PRIVATE_KEY}"
CHAIN_TEST_PARAMS_SCRIPT="${CHAIN_TEST_PARAMS_SCRIPT:-$ROOT_DIR/scripts/set_chain_test_params.move}"

CHAIN_ID="${CHAIN_ID:-$CONFIG_CHAIN_ID}"
BASE_NODE_COUNT="${BASE_NODE_COUNT:-$CONFIG_BASE_NODE_COUNT}"
TARGET_VALIDATOR_COUNT="${TARGET_VALIDATOR_COUNT:-$CONFIG_TARGET_VALIDATOR_COUNT}"
USERS_PER_NEW_VALIDATOR="${USERS_PER_NEW_VALIDATOR:-$CONFIG_USERS_PER_NEW_VALIDATOR}"
POWER_PERIOD_IN_EPOCHS="${POWER_PERIOD_IN_EPOCHS:-$CONFIG_POWER_PERIOD_IN_EPOCHS}"
EPOCH_DURATION_SECS="${EPOCH_DURATION_SECS:-$CONFIG_EPOCH_DURATION_SECS}"
VALIDATOR_LOCKUP_PERIODS="${VALIDATOR_LOCKUP_PERIODS:-${VALIDATOR_EXIT_COOLDOWN_PERIODS:-$CONFIG_VALIDATOR_LOCKUP_PERIODS}}"
DEFAULT_VALIDATOR_LOCKUP_SECS=$((EPOCH_DURATION_SECS * POWER_PERIOD_IN_EPOCHS * VALIDATOR_LOCKUP_PERIODS))
VALIDATOR_LOCKUP_SECS="${VALIDATOR_LOCKUP_SECS:-$(_first_non_empty "${VALIDATOR_EXIT_COOLDOWN_SECS:-}" "$CONFIG_VALIDATOR_LOCKUP_SECS" "$DEFAULT_VALIDATOR_LOCKUP_SECS")}"
GOVERNANCE_VOTING_PERIODS="${GOVERNANCE_VOTING_PERIODS:-$CONFIG_GOVERNANCE_VOTING_PERIODS}"
DEFAULT_GOVERNANCE_VOTING_DURATION_SECS=$((EPOCH_DURATION_SECS * POWER_PERIOD_IN_EPOCHS * GOVERNANCE_VOTING_PERIODS))
GOVERNANCE_VOTING_DURATION_SECS="${GOVERNANCE_VOTING_DURATION_SECS:-$(_first_non_empty "$CONFIG_GOVERNANCE_VOTING_DURATION_SECS" "$DEFAULT_GOVERNANCE_VOTING_DURATION_SECS")}"
EXPECTED_STAKING_COOLDOWN_SECS=$((VALIDATOR_LOCKUP_SECS > GOVERNANCE_VOTING_DURATION_SECS ? VALIDATOR_LOCKUP_SECS : GOVERNANCE_VOTING_DURATION_SECS))

MIN_VALIDATOR_STAKE="${MIN_VALIDATOR_STAKE:-$CONFIG_MIN_VALIDATOR_STAKE}"
VALIDATOR_STAKE_MULTIPLIER="${VALIDATOR_STAKE_MULTIPLIER:-$CONFIG_VALIDATOR_STAKE_MULTIPLIER}"
USER_STAKE_MULTIPLIER="${USER_STAKE_MULTIPLIER:-$CONFIG_USER_STAKE_MULTIPLIER}"
DEFAULT_VALIDATOR_STAKE=$((MIN_VALIDATOR_STAKE * VALIDATOR_STAKE_MULTIPLIER))
DEFAULT_USER_STAKE=$((MIN_VALIDATOR_STAKE * USER_STAKE_MULTIPLIER))

VALIDATOR_POWER="${VALIDATOR_POWER:-$(_first_non_empty "$CONFIG_VALIDATOR_POWER" "$DEFAULT_VALIDATOR_STAKE")}"
VALIDATOR_MINT_AMOUNT="${VALIDATOR_MINT_AMOUNT:-$(_first_non_empty "$CONFIG_VALIDATOR_MINT_AMOUNT" "$((DEFAULT_VALIDATOR_STAKE + MIN_VALIDATOR_STAKE))")}"
VALIDATOR_DEPOSIT_AMOUNT="${VALIDATOR_DEPOSIT_AMOUNT:-$(_first_non_empty "$CONFIG_VALIDATOR_DEPOSIT_AMOUNT" "$DEFAULT_VALIDATOR_STAKE")}"
VALIDATOR_COMMISSION_BPS="${VALIDATOR_COMMISSION_BPS:-$CONFIG_VALIDATOR_COMMISSION_BPS}"
VALIDATOR_FORCE_EPOCHS_BEFORE_DELEGATE="${VALIDATOR_FORCE_EPOCHS_BEFORE_DELEGATE:-$(_first_non_empty "$CONFIG_VALIDATOR_FORCE_EPOCHS_BEFORE_DELEGATE" "$POWER_PERIOD_IN_EPOCHS")}"
VALIDATOR_FORCE_EPOCHS_AFTER_JOIN="${VALIDATOR_FORCE_EPOCHS_AFTER_JOIN:-$CONFIG_VALIDATOR_FORCE_EPOCHS_AFTER_JOIN}"

USER_MINT_AMOUNT="${USER_MINT_AMOUNT:-$(_first_non_empty "$CONFIG_USER_MINT_AMOUNT" "$((DEFAULT_USER_STAKE + MIN_VALIDATOR_STAKE))")}"
USER_POWER="${USER_POWER:-$(_first_non_empty "$CONFIG_USER_POWER" "$DEFAULT_USER_STAKE")}"
USER_DEPOSIT_AMOUNT="${USER_DEPOSIT_AMOUNT:-$(_first_non_empty "$CONFIG_USER_DEPOSIT_AMOUNT" "$DEFAULT_USER_STAKE")}"
USER_FORCE_EPOCH="${USER_FORCE_EPOCH:-$CONFIG_USER_FORCE_EPOCH}"
USER_FORCE_EPOCHS="${USER_FORCE_EPOCHS:-$(_first_non_empty "$CONFIG_USER_FORCE_EPOCHS" "$POWER_PERIOD_IN_EPOCHS")}"

WAIT_TIMEOUT_SECS="${WAIT_TIMEOUT_SECS:-$CONFIG_WAIT_TIMEOUT_SECS}"
POLL_INTERVAL_SECS="${POLL_INTERVAL_SECS:-$CONFIG_POLL_INTERVAL_SECS}"

RESET=false
SKIP_DASHBOARD=false
SKIP_CHAIN_PARAMS=false

usage() {
    cat <<EOF
用法: $0 [选项]

全流程执行:
  1. 可选清理旧集群和 Dashboard 数据库
  2. 启动 4 节点本地集群
  3. 用 Move script 交易设置 rewards_rate/retention/power_period
  4. 启动 Dashboard 前后端
  5. 生成并启动 3 个 post-genesis 验证者节点
  6. 调用前端接口 /api/v1/validators/prepare-join 加入验证者集合
  7. 调用前端接口 /api/v1/staking/proxy 创建 15 个用户并代理质押
  8. 校验 active validator 数量、watchlist 用户数量和奖励字段

选项:
  --reset              从 0 开始。停止集群，删除集群目录和 backend/poc_dashboard.db
  --skip-dashboard     不启动 Dashboard，只使用已运行的前端代理接口
  --skip-chain-params  跳过 set_chain_test_params.move 交易
  -h, --help           显示帮助

常用环境变量:
  CLUSTER_DIR                    默认 $CLUSTER_DIR
  CONFIG_PATH                    默认 $CONFIG_PATH
  REST_URL                       默认 $REST_URL
  FRONTEND_URL                   默认 $FRONTEND_URL
  BACKEND_PORT                   默认 $BACKEND_PORT
  FRONTEND_PORT                  默认 $FRONTEND_PORT
  CLUSTER_PORT_START             默认 $CLUSTER_PORT_START
  TARGET_VALIDATOR_COUNT         默认 $TARGET_VALIDATOR_COUNT
  USERS_PER_NEW_VALIDATOR        默认 $USERS_PER_NEW_VALIDATOR
  POWER_PERIOD_IN_EPOCHS         默认 $POWER_PERIOD_IN_EPOCHS
  EPOCH_DURATION_SECS            默认 $EPOCH_DURATION_SECS
  VALIDATOR_LOCKUP_PERIODS       默认 $VALIDATOR_LOCKUP_PERIODS
  VALIDATOR_LOCKUP_SECS          默认 $VALIDATOR_LOCKUP_SECS
  GOVERNANCE_VOTING_PERIODS      默认 $GOVERNANCE_VOTING_PERIODS
  GOVERNANCE_VOTING_DURATION_SECS 默认 $GOVERNANCE_VOTING_DURATION_SECS
  MIN_VALIDATOR_STAKE            默认 $MIN_VALIDATOR_STAKE
  VALIDATOR_STAKE_MULTIPLIER     默认 $VALIDATOR_STAKE_MULTIPLIER
  USER_STAKE_MULTIPLIER          默认 $USER_STAKE_MULTIPLIER
  VALIDATOR_POWER                默认 $VALIDATOR_POWER
  VALIDATOR_MINT_AMOUNT          默认 $VALIDATOR_MINT_AMOUNT
  VALIDATOR_DEPOSIT_AMOUNT       默认 $VALIDATOR_DEPOSIT_AMOUNT
  USER_MINT_AMOUNT               默认 $USER_MINT_AMOUNT
  USER_POWER                     默认 $USER_POWER
  USER_DEPOSIT_AMOUNT            默认 $USER_DEPOSIT_AMOUNT
  USER_FORCE_EPOCHS              默认 $USER_FORCE_EPOCHS
  FRAMEWORK_LOCAL_DIR            默认 $FRAMEWORK_LOCAL_DIR
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --reset)
            RESET=true
            shift
            ;;
        --skip-dashboard)
            SKIP_DASHBOARD=true
            shift
            ;;
        --skip-chain-params)
            SKIP_CHAIN_PARAMS=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "未知参数: $1" >&2
            usage
            exit 2
            ;;
    esac
done

log() {
    printf "\n[%s] %s\n" "$(date '+%H:%M:%S')" "$*"
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

need_file() {
    [[ -f "$1" ]] || die "文件不存在: $1"
}

need_executable() {
    [[ -x "$1" ]] || die "可执行文件不存在或不可执行: $1"
}

curl_json() {
    local method="$1"
    local url="$2"
    local data="${3:-}"
    local tmp_body
    tmp_body="$(mktemp)"
    local status
    if [[ -n "$data" ]]; then
        status="$(curl -sS --retry 10 --retry-connrefused --retry-all-errors --retry-delay 1 \
            -X "$method" "$url" \
            -H 'Content-Type: application/json' \
            -d "$data" \
            -o "$tmp_body" \
            -w '%{http_code}')"
    else
        status="$(curl -sS --retry 10 --retry-connrefused --retry-all-errors --retry-delay 1 \
            -X "$method" "$url" \
            -o "$tmp_body" \
            -w '%{http_code}')"
    fi

    if [[ "$status" -lt 200 || "$status" -ge 300 ]]; then
        echo "HTTP $status $url" >&2
        cat "$tmp_body" >&2
        rm -f "$tmp_body"
        return 1
    fi

    cat "$tmp_body"
    rm -f "$tmp_body"
}

view_call() {
    local function_id="$1"
    local arguments="${2:-[]}"
    curl_json POST "$REST_URL/view" \
        "{\"function\":\"$function_id\",\"type_arguments\":[],\"arguments\":$arguments}"
}

wait_until() {
    local description="$1"
    local command="$2"
    local deadline
    deadline=$((SECONDS + WAIT_TIMEOUT_SECS))
    until eval "$command"; do
        if (( SECONDS >= deadline )); then
            die "等待超时: $description"
        fi
        sleep "$POLL_INTERVAL_SECS"
    done
}

json_get() {
    python3 -c 'import json,sys
data=json.load(sys.stdin)
for key in sys.argv[1].split("."):
    if key == "":
        continue
    if isinstance(data, list):
        data = data[int(key)]
    else:
        data = data[key]
print(data)' "$1"
}

json_assert_final_success() {
    local label="$1"
    python3 -c 'import json,sys
data=json.load(sys.stdin)
if data.get("final_status") != "success":
    print(json.dumps(data, ensure_ascii=False, indent=2), file=sys.stderr)
    raise SystemExit(f"{sys.argv[1]} final_status != success")' "$label"
}

json_assert_reward_fields() {
    local kind="$1"
    python3 -c 'import json,sys
data=json.load(sys.stdin)
kind=sys.argv[1]
items=data.get(kind) or []
required=[
    "reward_rate",
    "pending_fee_octas",
    "estimated_epoch_reward_octas",
    "estimated_epoch_fee_octas",
    "estimated_epoch_total_octas",
]
missing=[]
for item in items:
    rewards=item.get("rewards") or {}
    for key in required:
        if key not in rewards:
            missing.append((item.get("label") or item.get("address"), key))
if missing:
    for label, key in missing:
        print(f"missing rewards.{key}: {label}", file=sys.stderr)
    raise SystemExit(1)' "$kind"
}

json_has_label() {
    local collection="$1"
    local label="$2"
    python3 -c 'import json,sys
data=json.load(sys.stdin)
collection=sys.argv[1]
label=sys.argv[2]
for item in data.get(collection) or []:
    if str(item.get("label") or "") == label:
        raise SystemExit(0)
raise SystemExit(1)' "$collection" "$label"
}

json_contains_address() {
    local address="$1"
    python3 -c 'import json,sys
data=json.load(sys.stdin)
address=sys.argv[1].lower()
if isinstance(data, list) and data and isinstance(data[0], list):
    values=data[0]
elif isinstance(data, list):
    values=data
else:
    values=[]
for value in values:
    if str(value).lower() == address:
        raise SystemExit(0)
raise SystemExit(1)' "$address"
}

validator_address_by_index() {
    local index="$1"
    local key_file="$CLUSTER_DIR/users/validator-$index/private-keys.yaml"
    need_file "$key_file"
    python3 -c 'import sys,yaml
with open(sys.argv[1]) as f:
    data=yaml.safe_load(f)
addr=str(data["account_address"])
print(addr if addr.startswith("0x") else "0x" + addr)' "$key_file"
}

cluster_state_exists() {
    [[ -f "$CLUSTER_DIR/.prod_like_validator_cluster_state.json" ]]
}

start_dashboard_if_needed() {
    if curl_json GET "$FRONTEND_URL/api/v1/system/health" >/dev/null 2>&1; then
        log "Dashboard 前端代理已健康: $FRONTEND_URL"
        return
    fi

    if [[ "$SKIP_DASHBOARD" == true ]]; then
        log "跳过 Dashboard 启动，使用已有前端代理: $FRONTEND_URL"
        return
    fi

    log "启动 Dashboard 前后端"
    CONFIG_PATH="$CONFIG_PATH" BACKEND_PORT="$BACKEND_PORT" FRONTEND_PORT="$FRONTEND_PORT" "$ROOT_DIR/dashboard.sh" start
    wait_until "Dashboard API 健康" "curl_json GET '$FRONTEND_URL/api/v1/system/health' >/dev/null"
}

reset_all() {
    log "停止 Dashboard"
    CONFIG_PATH="$CONFIG_PATH" BACKEND_PORT="$BACKEND_PORT" FRONTEND_PORT="$FRONTEND_PORT" "$ROOT_DIR/dashboard.sh" stop || true

    log "停止旧集群"
    CONFIG_PATH="$CONFIG_PATH" python3 "$CLUSTER_SCRIPT" stop --repo-root "$REPO_ROOT" --workdir "$CLUSTER_DIR" || true

    log "删除旧集群目录和 Dashboard 数据库"
    rm -rf "$CLUSTER_DIR"
    rm -f "$ROOT_DIR/backend/poc_dashboard.db"
}

ensure_base_cluster() {
    if cluster_state_exists; then
        log "检测到已有集群状态，跳过 4 节点创世启动"
        CONFIG_PATH="$CONFIG_PATH" python3 "$CLUSTER_SCRIPT" status --repo-root "$REPO_ROOT" --workdir "$CLUSTER_DIR"
        return
    fi

    log "启动 $BASE_NODE_COUNT 节点创世集群: epoch=${EPOCH_DURATION_SECS}s, period=${POWER_PERIOD_IN_EPOCHS} epochs, validator_lockup=${VALIDATOR_LOCKUP_SECS}s, voting_duration=${GOVERNANCE_VOTING_DURATION_SECS}s"
    CONFIG_PATH="$CONFIG_PATH" python3 "$CLUSTER_SCRIPT" start \
        --repo-root "$REPO_ROOT" \
        --workdir "$CLUSTER_DIR" \
        --nodes "$BASE_NODE_COUNT" \
        --chain-id "$CHAIN_ID" \
        --port-start "$CLUSTER_PORT_START" \
        --epoch-duration-secs "$EPOCH_DURATION_SECS" \
        --min-stake "$MIN_VALIDATOR_STAKE" \
        --base-stake "$VALIDATOR_POWER" \
        --recurring-lockup-duration-secs "$VALIDATOR_LOCKUP_SECS" \
        --voting-duration-secs "$GOVERNANCE_VOTING_DURATION_SECS" \
        --poc-power-period-in-epochs "$POWER_PERIOD_IN_EPOCHS"
}

set_chain_test_params() {
    if [[ "$SKIP_CHAIN_PARAMS" == true ]]; then
        log "跳过链上测试参数交易"
        return
    fi

    log "提交链上测试参数交易: rewards_rate=10000/1000000000, retention=9998, power_period=$POWER_PERIOD_IN_EPOCHS"
    need_file "$CHAIN_TEST_PARAMS_SCRIPT"
    "$APTOS_CLI" move run-script \
        --url "$REST_URL" \
        --sender-account "$CORE_RESOURCES_ADDRESS" \
        --private-key "$CORE_RESOURCES_PRIVATE_KEY" \
        --script-path "$CHAIN_TEST_PARAMS_SCRIPT" \
        --framework-local-dir "$FRAMEWORK_LOCAL_DIR" \
        --skip-fetch-latest-git-deps \
        --args "u64:$POWER_PERIOD_IN_EPOCHS" \
        --assume-yes \
        --max-gas 200000 \
        --gas-unit-price 100

    log "检查 reward_rate"
    view_call "0x1::staking_config::reward_rate"
}

ensure_post_genesis_nodes() {
    local existing_count
    existing_count="$(find "$CLUSTER_DIR/users" -maxdepth 1 -type d -name 'validator-*' 2>/dev/null | wc -l | tr -d ' ')"
    if (( existing_count < TARGET_VALIDATOR_COUNT )); then
        local add_count=$((TARGET_VALIDATOR_COUNT - existing_count))
        log "生成并启动 $add_count 个 post-genesis 验证者节点"
        CONFIG_PATH="$CONFIG_PATH" python3 "$CLUSTER_SCRIPT" add-validators \
            --repo-root "$REPO_ROOT" \
            --workdir "$CLUSTER_DIR" \
            --count "$add_count" \
            --base-stake "$VALIDATOR_POWER"
    else
        log "验证者节点目录数量已达到 $existing_count，跳过 add-validators"
    fi

    CONFIG_PATH="$CONFIG_PATH" python3 "$CLUSTER_SCRIPT" status --repo-root "$REPO_ROOT" --workdir "$CLUSTER_DIR"
}

current_active_validator_count() {
    view_call "0x1::stake::get_active_validator_count" | json_get "0"
}

validator_is_active() {
    local address="$1"
    view_call "0x1::stake::get_active_validators" '["0","200"]' | json_contains_address "$address"
}

join_validator_if_needed() {
    local index="$1"
    local label="validator-$index"
    local address
    address="$(validator_address_by_index "$index")"

    log "通过前端接口加入验证者 $label $address"
    local payload
    payload="$(printf '{"validator_address":"%s","label":"%s","power":%s,"set_power_period":%s,"force_epochs_before_delegate":%s,"force_epochs_after_join":%s,"mint_amount":%s,"deposit_amount":%s,"commission_bps":%s}' \
        "$address" "$label" "$VALIDATOR_POWER" "$POWER_PERIOD_IN_EPOCHS" "$VALIDATOR_FORCE_EPOCHS_BEFORE_DELEGATE" \
        "$VALIDATOR_FORCE_EPOCHS_AFTER_JOIN" "$VALIDATOR_MINT_AMOUNT" "$VALIDATOR_DEPOSIT_AMOUNT" \
        "$VALIDATOR_COMMISSION_BPS")"
    local response
    response="$(curl_json POST "$FRONTEND_URL/api/v1/validators/prepare-join" "$payload")"
    echo "$response" | json_assert_final_success "$label"
}

join_missing_validators() {
    local active_count
    active_count="$(current_active_validator_count)"
    if (( active_count >= TARGET_VALIDATOR_COUNT )); then
        log "active validator 已达到 $active_count，跳过验证者加入"
        return
    fi

    local start_index="$BASE_NODE_COUNT"
    local end_index=$((TARGET_VALIDATOR_COUNT - 1))
    local index
    for ((index = start_index; index <= end_index; index++)); do
        active_count="$(current_active_validator_count)"
        if (( active_count >= TARGET_VALIDATOR_COUNT )); then
            break
        fi
        local address
        address="$(validator_address_by_index "$index")"
        if validator_is_active "$address"; then
            log "验证者 validator-$index 已在 active set，跳过"
            continue
        fi
        join_validator_if_needed "$index"
        active_count="$(current_active_validator_count)"
        log "当前 active validator 数量: $active_count"
    done
}

proxy_stake_user() {
    local validator_index="$1"
    local user_index="$2"
    local validator_address="$3"
    local label="validator-$validator_index-user-$user_index"
    local payload
    payload="$(printf '{"target_user":"","label":"%s","mint_amount":%s,"set_power":%s,"deposit_amount":%s,"delegate_to":"%s","force_epoch":%s,"force_epochs":%s}' \
        "$label" "$USER_MINT_AMOUNT" "$USER_POWER" "$USER_DEPOSIT_AMOUNT" "$validator_address" "$USER_FORCE_EPOCH" "$USER_FORCE_EPOCHS")"

    log "创建普通用户并代理质押 $label -> $validator_address"
    local response
    response="$(curl_json POST "$FRONTEND_URL/api/v1/staking/proxy" "$payload")"
    echo "$response" | json_assert_final_success "$label"
}

create_users_and_proxy_stake() {
    local users_json total
    users_json="$(curl_json GET "$FRONTEND_URL/api/v1/watchlist/users")"
    total="$(echo "$users_json" | json_get "total")"
    local expected=$(((TARGET_VALIDATOR_COUNT - BASE_NODE_COUNT) * USERS_PER_NEW_VALIDATOR))
    log "当前 watchlist 用户数量: $total，目标新增用户标签数量: $expected"

    local validator_index user_index validator_address
    for ((validator_index = BASE_NODE_COUNT; validator_index < TARGET_VALIDATOR_COUNT; validator_index++)); do
        validator_address="$(validator_address_by_index "$validator_index")"
        for ((user_index = 1; user_index <= USERS_PER_NEW_VALIDATOR; user_index++)); do
            local label="validator-$validator_index-user-$user_index"
            if echo "$users_json" | json_has_label "users" "$label"; then
                log "普通用户 $label 已存在，跳过"
                continue
            fi
            proxy_stake_user "$validator_index" "$user_index" "$validator_address"
            users_json="$(curl_json GET "$FRONTEND_URL/api/v1/watchlist/users")"
        done
    done
}

final_verify() {
    log "最终校验集群状态"
    CONFIG_PATH="$CONFIG_PATH" python3 "$CLUSTER_SCRIPT" status --repo-root "$REPO_ROOT" --workdir "$CLUSTER_DIR"

    local active_count
    active_count="$(current_active_validator_count)"
    [[ "$active_count" == "$TARGET_VALIDATOR_COUNT" ]] || die "active validator 数量为 $active_count，期望 $TARGET_VALIDATOR_COUNT"

    local validators_json users_json user_total
    validators_json="$(curl_json GET "$FRONTEND_URL/api/v1/watchlist/validators")"
    users_json="$(curl_json GET "$FRONTEND_URL/api/v1/watchlist/users")"
    user_total="$(echo "$users_json" | json_get "total")"

    local expected_users=$(((TARGET_VALIDATOR_COUNT - BASE_NODE_COUNT) * USERS_PER_NEW_VALIDATOR))
    (( user_total >= expected_users )) || die "watchlist 用户数量为 $user_total，期望至少 $expected_users"

    echo "$validators_json" | json_assert_reward_fields "validators"
    echo "$users_json" | json_assert_reward_fields "users"

    local governance_json voting_duration cooldown_secs
    governance_json="$(curl_json GET "$FRONTEND_URL/api/v1/governance/config")"
    voting_duration="$(echo "$governance_json" | json_get "governance.voting_duration_secs")"
    cooldown_secs="$(echo "$governance_json" | json_get "staking.cooldown_secs")"
    [[ "$voting_duration" == "$GOVERNANCE_VOTING_DURATION_SECS" ]] || die "治理投票时长为 $voting_duration，期望 $GOVERNANCE_VOTING_DURATION_SECS"
    [[ "$cooldown_secs" == "$EXPECTED_STAKING_COOLDOWN_SECS" ]] || die "POC 冷却期为 $cooldown_secs，期望 $EXPECTED_STAKING_COOLDOWN_SECS"

    log "校验通过"
    echo "active_validators=$active_count"
    echo "watchlist_users=$user_total"
    echo "validator_lockup_secs=$VALIDATOR_LOCKUP_SECS"
    echo "governance_voting_duration_secs=$voting_duration"
    echo "staking_cooldown_secs=$cooldown_secs"
    echo "frontend=$FRONTEND_URL"
    echo "backend=$BACKEND_URL"
    echo "rest=$REST_URL"
}

main() {
    need_file "$CLUSTER_SCRIPT"
    need_executable "$APTOS_CLI"
    need_file "$FRAMEWORK_LOCAL_DIR/Move.toml"
    need_file "$ROOT_DIR/dashboard.sh"
    log "使用配置文件: $CONFIG_PATH"
    log "集群目录: $CLUSTER_DIR, rest=$REST_URL, dashboard=$FRONTEND_URL, chain_id=$CHAIN_ID, port_start=$CLUSTER_PORT_START"
    if (( GOVERNANCE_VOTING_DURATION_SECS >= VALIDATOR_LOCKUP_SECS )); then
        die "创世要求 GOVERNANCE_VOTING_DURATION_SECS($GOVERNANCE_VOTING_DURATION_SECS) 必须小于 VALIDATOR_LOCKUP_SECS($VALIDATOR_LOCKUP_SECS)"
    fi

    if [[ "$RESET" == true ]]; then
        reset_all
    fi

    ensure_base_cluster
    wait_until "REST API 可用" "curl -sS '$REST_URL' >/dev/null"
    set_chain_test_params
    start_dashboard_if_needed
    ensure_post_genesis_nodes
    join_missing_validators
    create_users_and_proxy_stake
    final_verify
}

main "$@"
