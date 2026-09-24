#!/bin/bash

CHAIN_DIR="${CHAIN_DIR:-/root/chain-data}"
APTOS_NODE_BIN="${APTOS_NODE_BIN:-/root/chain-bin/aptos-node}"

# 节点分组。支持空格或逗号分隔，例如 VALIDATOR_NODE_IDS="0 1 2 3"。
VALIDATOR_NODE_IDS="${VALIDATOR_NODE_IDS:-0 1 2 3}"
FULLNODE_NODE_IDS="${FULLNODE_NODE_IDS:-4 5}"
VALIDATOR_NODE_IDS="${VALIDATOR_NODE_IDS//,/ }"
FULLNODE_NODE_IDS="${FULLNODE_NODE_IDS//,/ }"
read -r -a VALIDATORS <<< "$VALIDATOR_NODE_IDS"
read -r -a FULLNODES <<< "$FULLNODE_NODE_IDS"

########################################
# 基础检查
########################################

if [ ! -f "$APTOS_NODE_BIN" ]; then
    echo "Error: aptos-node not found at $APTOS_NODE_BIN"
    exit 1
fi

if [ ! -d "$CHAIN_DIR" ]; then
    echo "Error: Chain directory not found: $CHAIN_DIR"
    exit 1
fi

# PID ownership checks use Linux procfs. Refuse to manage processes without it.
if [ ! -r /proc/self/cmdline ] || [ ! -L /proc/self/exe ]; then
    echo "Error: Linux /proc is required to verify node processes" >&2
    exit 1
fi

########################################
# 工具函数
########################################

get_port() {
    local node_id=$1
    local config_file="$CHAIN_DIR/$node_id/node.yaml"

    awk '
        /^api:[[:space:]]*$/ { in_api = 1; next }
        in_api && /^[^[:space:]]/ { exit }
        in_api && /^[[:space:]]+address:[[:space:]]*/ {
            address = $0
            sub(/^[[:space:]]+address:[[:space:]]*/, "", address)
            sub(/[[:space:]#].*$/, "", address)
            gsub(/"/, "", address)
            gsub(/\047/, "", address)
            count = split(address, parts, ":")
            print parts[count]
            exit
        }
    ' "$config_file"
}

node_in_group() {
    local node_id=$1
    shift
    local candidate

    for candidate in "$@"; do
        if [ "$candidate" = "$node_id" ]; then
            return 0
        fi
    done
    return 1
}

get_node_role() {
    local node_id=$1

    if node_in_group "$node_id" "${VALIDATORS[@]}"; then
        echo "validator"
        return 0
    fi
    if node_in_group "$node_id" "${FULLNODES[@]}"; then
        echo "fullnode"
        return 0
    fi

    echo "Error: unknown node id '$node_id'" >&2
    return 1
}

pid_matches_node() {
    local pid=$1
    local config_file=$2
    local expected_exe
    local actual_exe
    local arg
    local previous_arg=""
    local config_count=0

    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    [ "$pid" -gt 1 ] || return 1
    [ -r "/proc/$pid/cmdline" ] || return 1

    expected_exe=$(readlink -f -- "$APTOS_NODE_BIN") || return 1
    actual_exe=$(readlink -f -- "/proc/$pid/exe") || return 1
    [ "$actual_exe" = "$expected_exe" ] || return 1

    while IFS= read -r -d '' arg; do
        if [ "$previous_arg" = "--config" ]; then
            [ "$arg" = "$config_file" ] || return 1
            config_count=$((config_count + 1))
        fi
        previous_arg=$arg
    done < "/proc/$pid/cmdline"

    [ "$config_count" -eq 1 ]
}

########################################
# 启动节点
########################################

start_node() {
    local node_id=$1
    local role=$2

    local node_dir="$CHAIN_DIR/$node_id"
    local config_file="$node_dir/node.yaml"
    local pid_file="$node_dir/${role}.pid"
    local log_file="$node_dir/${role}.log"
    local pid

    if [ ! -f "$config_file" ]; then
        echo "Error: Config not found for $role $node_id"
        return 1
    fi

    if [ -f "$pid_file" ]; then
        pid=$(cat "$pid_file")
        if pid_matches_node "$pid" "$config_file"; then
            echo "$role $node_id already running (PID $pid)"
            return 0
        else
            echo "Ignoring stale or unowned PID $pid for $role $node_id" >&2
            rm -f "$pid_file"
        fi
    fi

    echo "Starting $role $node_id..."

    nohup "$APTOS_NODE_BIN" --config "$config_file" >> "$log_file" 2>&1 &
    pid=$!

    echo "$pid" > "$pid_file"
    sleep 1

    if pid_matches_node "$pid" "$config_file"; then
        echo "$role $node_id started (PID $pid)"
    else
        echo "Error: $role $node_id did not start as the expected process; check $log_file" >&2
        if ! ps -p "$pid" > /dev/null 2>&1; then
            rm -f "$pid_file"
        fi
        return 1
    fi
}

########################################
# 停止节点
########################################

stop_node() {
    local node_id=$1
    local role=$2
    local node_dir="$CHAIN_DIR/$node_id"
    local config_file="$node_dir/node.yaml"
    local pid_file="$node_dir/${role}.pid"
    local pid
    local waited=0

    if [ ! -f "$pid_file" ]; then
        echo "$role $node_id not running (PID file not found)"
        return 0
    fi

    pid=$(cat "$pid_file")

    if pid_matches_node "$pid" "$config_file"; then
        echo "Stopping $role $node_id (PID $pid)..."

        if ! kill -15 "$pid"; then
            echo "Error: could not signal $role $node_id (PID $pid)" >&2
            return 1
        fi

        while pid_matches_node "$pid" "$config_file" && [ "$waited" -lt 30 ]; do
            sleep 1
            waited=$((waited + 1))
        done

        if pid_matches_node "$pid" "$config_file"; then
            echo "Warning: $role $node_id did not stop after 30 seconds; sending SIGKILL"
            if ! kill -9 "$pid"; then
                echo "Error: could not force-stop $role $node_id (PID $pid)" >&2
                return 1
            fi
        elif ps -p "$pid" > /dev/null 2>&1; then
            echo "Warning: PID $pid no longer matches $role $node_id; no further signal sent" >&2
        fi

        echo "$role $node_id stopped"
    else
        echo "$role $node_id not running (stale or unowned PID $pid)"
    fi

    rm -f "$pid_file"
}

restart_node() {
    local node_id=$1
    local role

    role=$(get_node_role "$node_id") || return 1
    stop_node "$node_id" "$role" || return 1
    sleep 2
    start_node "$node_id" "$role"
}

########################################
# 状态检查
########################################

status_node() {
    local node_id=$1
    local role
    local node_dir="$CHAIN_DIR/$node_id"
    local config_file="$node_dir/node.yaml"
    local pid_file
    local pid
    local port
    local http_code

    role=$(get_node_role "$node_id") || return 1
    pid_file="$node_dir/${role}.pid"

    echo "Node $node_id:"

    if [ -f "$pid_file" ]; then
        pid=$(cat "$pid_file")

        if pid_matches_node "$pid" "$config_file"; then
            port=$(get_port "$node_id")

            echo "  $role: RUNNING (PID $pid, PORT $port)"

            http_code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$port/v1")
            if [ "$http_code" = "200" ]; then
                echo "  Health: OK"
            else
                echo "  Health: FAIL ($http_code)"
            fi
        else
            echo "  $role: STOPPED (stale or unowned PID)"
            rm -f "$pid_file"
        fi
    else
        echo "  $role: STOPPED"
    fi

    echo
}

########################################
# 批量操作
########################################

start_all_nodes() {
    local failed=0

    echo "Starting validators..."
    for i in "${VALIDATORS[@]}"; do
        start_node "$i" "validator" || failed=1
    done

    echo "Starting fullnodes..."
    for i in "${FULLNODES[@]}"; do
        start_node "$i" "fullnode" || failed=1
    done

    if [ "$failed" -ne 0 ]; then
        echo "Error: one or more nodes failed to start" >&2
        return 1
    fi
    echo "All nodes started."
}

stop_all_nodes() {
    local failed=0

    echo "Stopping all nodes..."

    for i in "${VALIDATORS[@]}"; do
        stop_node "$i" "validator" || failed=1
    done

    for i in "${FULLNODES[@]}"; do
        stop_node "$i" "fullnode" || failed=1
    done

    if [ "$failed" -ne 0 ]; then
        echo "Error: one or more nodes failed to stop" >&2
        return 1
    fi
    echo "All nodes stopped."
}

status_all_nodes() {
    echo "===== Node Status ====="

    for i in "${VALIDATORS[@]}"; do
        status_node "$i"
    done

    for i in "${FULLNODES[@]}"; do
        status_node "$i"
    done

    echo "======================="
}

########################################
# CLI 入口
########################################

case "$1" in
    start)
        start_all_nodes
        ;;
    stop)
        stop_all_nodes
        ;;
    restart)
        stop_all_nodes || exit 1
        sleep 2
        start_all_nodes
        ;;
    status)
        status_all_nodes
        ;;
    start-node)
        role=$(get_node_role "$2") || exit 2
        start_node "$2" "$role"
        ;;
    stop-node)
        role=$(get_node_role "$2") || exit 2
        stop_node "$2" "$role"
        ;;
    restart-node)
        restart_node "$2"
        ;;
    status-node)
        status_node "$2"
        ;;
    *)
        echo "Usage:"
        echo "  $0 start        # 启动所有节点"
        echo "  $0 stop         # 停止所有节点"
        echo "  $0 restart      # 重启所有节点"
        echo "  $0 status       # 查看状态"
        echo "  $0 start-node <id>    # 启动指定 validator/fullnode"
        echo "  $0 stop-node <id>     # 停止指定 validator/fullnode"
        echo "  $0 restart-node <id>  # 重启指定 validator/fullnode"
        echo "  $0 status-node <id>   # 查看指定节点状态"
        ;;
esac
