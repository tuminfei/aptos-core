#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$ROOT_DIR/.." && pwd)"
CLUSTER_DIR="${CLUSTER_DIR:-$ROOT_DIR/poc-validator-cluster}"
CLUSTER_SCRIPT="${CLUSTER_SCRIPT:-$ROOT_DIR/scripts/poc_prod_like_validator_cluster.py}"
APTOS_CLI="${APTOS_CLI:-$REPO_ROOT/target/debug/aptos}"
FRAMEWORK_LOCAL_DIR="${FRAMEWORK_LOCAL_DIR:-$REPO_ROOT/aptos-move/framework/aptos-framework}"
REST_URL="${REST_URL:-http://127.0.0.1:36183/v1}"
FRONTEND_URL="${FRONTEND_URL:-http://127.0.0.1:35173}"
BACKEND_URL="${BACKEND_URL:-http://127.0.0.1:38000}"
BACKEND_PORT="${BACKEND_PORT:-38000}"
FRONTEND_PORT="${FRONTEND_PORT:-35173}"
CLUSTER_PORT_START="${CLUSTER_PORT_START:-36180}"
CORE_RESOURCES_ADDRESS="${CORE_RESOURCES_ADDRESS:-0xa550c18}"
CORE_RESOURCES_PRIVATE_KEY="${CORE_RESOURCES_PRIVATE_KEY:-0xD04470F43AB6AEAA4EB616B72128881EEF77346F2075FFE68E14BA7DEBD8095E}"
CHAIN_TEST_PARAMS_SCRIPT="${CHAIN_TEST_PARAMS_SCRIPT:-$ROOT_DIR/scripts/set_chain_test_params.move}"

BASE_NODE_COUNT="${BASE_NODE_COUNT:-4}"
TARGET_VALIDATOR_COUNT="${TARGET_VALIDATOR_COUNT:-7}"
USERS_PER_NEW_VALIDATOR="${USERS_PER_NEW_VALIDATOR:-5}"
POWER_PERIOD_IN_EPOCHS="${POWER_PERIOD_IN_EPOCHS:-5}"
EPOCH_DURATION_SECS="${EPOCH_DURATION_SECS:-60}"
VALIDATOR_LOCKUP_PERIODS="${VALIDATOR_LOCKUP_PERIODS:-${VALIDATOR_EXIT_COOLDOWN_PERIODS:-2}}"
VALIDATOR_LOCKUP_SECS="${VALIDATOR_LOCKUP_SECS:-${VALIDATOR_EXIT_COOLDOWN_SECS:-$((EPOCH_DURATION_SECS * POWER_PERIOD_IN_EPOCHS * VALIDATOR_LOCKUP_PERIODS))}}"
GOVERNANCE_VOTING_PERIODS="${GOVERNANCE_VOTING_PERIODS:-1}"
GOVERNANCE_VOTING_DURATION_SECS="${GOVERNANCE_VOTING_DURATION_SECS:-$((EPOCH_DURATION_SECS * POWER_PERIOD_IN_EPOCHS * GOVERNANCE_VOTING_PERIODS))}"
EXPECTED_STAKING_COOLDOWN_SECS=$((VALIDATOR_LOCKUP_SECS > GOVERNANCE_VOTING_DURATION_SECS ? VALIDATOR_LOCKUP_SECS : GOVERNANCE_VOTING_DURATION_SECS))

MIN_VALIDATOR_STAKE="${MIN_VALIDATOR_STAKE:-1000000000}"
VALIDATOR_STAKE_MULTIPLIER="${VALIDATOR_STAKE_MULTIPLIER:-10}"
USER_STAKE_MULTIPLIER="${USER_STAKE_MULTIPLIER:-5}"
DEFAULT_VALIDATOR_STAKE=$((MIN_VALIDATOR_STAKE * VALIDATOR_STAKE_MULTIPLIER))
DEFAULT_USER_STAKE=$((MIN_VALIDATOR_STAKE * USER_STAKE_MULTIPLIER))

VALIDATOR_POWER="${VALIDATOR_POWER:-$DEFAULT_VALIDATOR_STAKE}"
VALIDATOR_MINT_AMOUNT="${VALIDATOR_MINT_AMOUNT:-$((DEFAULT_VALIDATOR_STAKE + MIN_VALIDATOR_STAKE))}"
VALIDATOR_DEPOSIT_AMOUNT="${VALIDATOR_DEPOSIT_AMOUNT:-$DEFAULT_VALIDATOR_STAKE}"
VALIDATOR_COMMISSION_BPS="${VALIDATOR_COMMISSION_BPS:-0}"
VALIDATOR_FORCE_EPOCHS_BEFORE_DELEGATE="${VALIDATOR_FORCE_EPOCHS_BEFORE_DELEGATE:-$POWER_PERIOD_IN_EPOCHS}"
VALIDATOR_FORCE_EPOCHS_AFTER_JOIN="${VALIDATOR_FORCE_EPOCHS_AFTER_JOIN:-1}"

USER_MINT_AMOUNT="${USER_MINT_AMOUNT:-$((DEFAULT_USER_STAKE + MIN_VALIDATOR_STAKE))}"
USER_POWER="${USER_POWER:-$DEFAULT_USER_STAKE}"
USER_DEPOSIT_AMOUNT="${USER_DEPOSIT_AMOUNT:-$DEFAULT_USER_STAKE}"
USER_FORCE_EPOCH="${USER_FORCE_EPOCH:-true}"
USER_FORCE_EPOCHS="${USER_FORCE_EPOCHS:-$POWER_PERIOD_IN_EPOCHS}"

WAIT_TIMEOUT_SECS="${WAIT_TIMEOUT_SECS:-180}"
POLL_INTERVAL_SECS="${POLL_INTERVAL_SECS:-2}"

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
    BACKEND_PORT="$BACKEND_PORT" FRONTEND_PORT="$FRONTEND_PORT" "$ROOT_DIR/dashboard.sh" start
    wait_until "Dashboard API 健康" "curl_json GET '$FRONTEND_URL/api/v1/system/health' >/dev/null"
}

reset_all() {
    log "停止 Dashboard"
    BACKEND_PORT="$BACKEND_PORT" FRONTEND_PORT="$FRONTEND_PORT" "$ROOT_DIR/dashboard.sh" stop || true

    log "停止旧集群"
    python3 "$CLUSTER_SCRIPT" stop --repo-root "$REPO_ROOT" --workdir "$CLUSTER_DIR" || true

    log "删除旧集群目录和 Dashboard 数据库"
    rm -rf "$CLUSTER_DIR"
    rm -f "$ROOT_DIR/backend/poc_dashboard.db"
}

ensure_base_cluster() {
    if cluster_state_exists; then
        log "检测到已有集群状态，跳过 4 节点创世启动"
        python3 "$CLUSTER_SCRIPT" status --repo-root "$REPO_ROOT" --workdir "$CLUSTER_DIR"
        return
    fi

    log "启动 $BASE_NODE_COUNT 节点创世集群: epoch=${EPOCH_DURATION_SECS}s, period=${POWER_PERIOD_IN_EPOCHS} epochs, validator_lockup=${VALIDATOR_LOCKUP_SECS}s, voting_duration=${GOVERNANCE_VOTING_DURATION_SECS}s"
    python3 "$CLUSTER_SCRIPT" start \
        --repo-root "$REPO_ROOT" \
        --workdir "$CLUSTER_DIR" \
        --nodes "$BASE_NODE_COUNT" \
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
        python3 "$CLUSTER_SCRIPT" add-validators \
            --repo-root "$REPO_ROOT" \
            --workdir "$CLUSTER_DIR" \
            --count "$add_count" \
            --base-stake "$VALIDATOR_POWER"
    else
        log "验证者节点目录数量已达到 $existing_count，跳过 add-validators"
    fi

    python3 "$CLUSTER_SCRIPT" status --repo-root "$REPO_ROOT" --workdir "$CLUSTER_DIR"
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
    python3 "$CLUSTER_SCRIPT" status --repo-root "$REPO_ROOT" --workdir "$CLUSTER_DIR"

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
