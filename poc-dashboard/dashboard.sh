#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKEND_DIR="$ROOT_DIR/backend"
FRONTEND_DIR="$ROOT_DIR/frontend"
PID_DIR="$ROOT_DIR/.pids"
LOG_DIR="$ROOT_DIR/.logs"
BACKEND_VENV_DIR="${BACKEND_VENV_DIR:-$BACKEND_DIR/.venv}"
CONFIG_PATH="${CONFIG_PATH:-$ROOT_DIR/config.yaml}"
CONFIG_PATH="$(python3 -c 'import os, sys; print(os.path.abspath(sys.argv[1]))' "$CONFIG_PATH")"

_read_dashboard_config() {
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
            # Bootstrap fallback for environments before backend requirements are installed.
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

values = {
    "CONFIG_BACKEND_HOST": get(("server", "host"), "0.0.0.0"),
    "CONFIG_BACKEND_PORT": get(("server", "port"), 38000),
    "CONFIG_FRONTEND_HOST": get(("frontend", "host"), "0.0.0.0"),
    "CONFIG_FRONTEND_PORT": get(("frontend", "port"), 35173),
    "CONFIG_FRONTEND_BACKEND_URL": get(("frontend", "backend_url"), ""),
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

_ws_url_from_http_url() {
    case "$1" in
        http://*)  printf "ws://%s" "${1#http://}" ;;
        https://*) printf "wss://%s" "${1#https://}" ;;
        *)         printf "%s" "$1" ;;
    esac
}

CONFIG_EXPORTS="$(_read_dashboard_config)"
eval "$CONFIG_EXPORTS"

BACKEND_HOST="${BACKEND_HOST:-$CONFIG_BACKEND_HOST}"
FRONTEND_HOST="${FRONTEND_HOST:-$CONFIG_FRONTEND_HOST}"
BACKEND_PORT="${BACKEND_PORT:-$CONFIG_BACKEND_PORT}"
FRONTEND_PORT="${FRONTEND_PORT:-$CONFIG_FRONTEND_PORT}"
FRONTEND_BACKEND_URL="${FRONTEND_BACKEND_URL:-${CONFIG_FRONTEND_BACKEND_URL:-http://$(_client_host "$BACKEND_HOST"):$BACKEND_PORT}}"
FRONTEND_WS_BACKEND_URL="${FRONTEND_WS_BACKEND_URL:-$(_ws_url_from_http_url "$FRONTEND_BACKEND_URL")}"

mkdir -p "$PID_DIR" "$LOG_DIR"

red()   { printf "\033[31m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }

_is_running() {
    local pidfile="$PID_DIR/$1.pid"
    [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null
}

_stop_one() {
    local name="$1"
    local pidfile="$PID_DIR/$name.pid"
    if [[ -f "$pidfile" ]]; then
        local pid
        pid=$(cat "$pidfile")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            for _ in $(seq 1 30); do
                kill -0 "$pid" 2>/dev/null || break
                sleep 0.1
            done
            kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
            green "$name 已停止 (pid $pid)"
        else
            yellow "$name 未在运行"
        fi
        rm -f "$pidfile"
    else
        yellow "$name 未在运行"
    fi
}

_stop_port() {
    local name="$1"
    local port="$2"
    local pids
    pids="$(lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)"
    if [[ -z "$pids" ]]; then
        return
    fi
    yellow "清理占用端口 $port 的 $name 进程: $pids"
    for pid in $pids; do
        kill "$pid" 2>/dev/null || true
    done
    for _ in $(seq 1 30); do
        pids="$(lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)"
        [[ -z "$pids" ]] && break
        sleep 0.1
    done
    pids="$(lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)"
    if [[ -n "$pids" ]]; then
        for pid in $pids; do
            kill -9 "$pid" 2>/dev/null || true
        done
    fi
}

start_backend() {
    if _is_running backend; then
        yellow "后端已在运行 (pid $(cat "$PID_DIR/backend.pid"))"
        return
    fi

    if [[ ! -d "$BACKEND_VENV_DIR" ]]; then
        yellow "创建 Python 虚拟环境..."
        python3 -m venv "$BACKEND_VENV_DIR"
    fi

    local python_bin="$BACKEND_VENV_DIR/bin/python"
    local pip_bin="$BACKEND_VENV_DIR/bin/pip"

    if ! "$python_bin" -c "import fastapi" 2>/dev/null; then
        yellow "安装后端依赖..."
        "$pip_bin" install -q -r "$BACKEND_DIR/requirements.txt"
    fi

    cd "$BACKEND_DIR"
    CONFIG_PATH="$CONFIG_PATH" setsid "$python_bin" -m uvicorn main:app \
        --host "$BACKEND_HOST" \
        --port "$BACKEND_PORT" \
        > "$LOG_DIR/backend.log" 2>&1 &
    echo $! > "$PID_DIR/backend.pid"
    green "后端已启动 http://$BACKEND_HOST:$BACKEND_PORT (pid $!)"
    cd "$ROOT_DIR"
}

stop_backend() {
    _stop_one backend
    _stop_port backend "$BACKEND_PORT"
}

start_frontend() {
    if _is_running frontend; then
        yellow "前端已在运行 (pid $(cat "$PID_DIR/frontend.pid"))"
        return
    fi

    if [[ ! -d "$FRONTEND_DIR/node_modules" ]]; then
        yellow "安装前端依赖..."
        (cd "$FRONTEND_DIR" && npm install --silent)
    fi

    cd "$FRONTEND_DIR"
    CONFIG_PATH="$CONFIG_PATH" \
    BACKEND_HOST="$BACKEND_HOST" \
    BACKEND_PORT="$BACKEND_PORT" \
    FRONTEND_HOST="$FRONTEND_HOST" \
    FRONTEND_PORT="$FRONTEND_PORT" \
    FRONTEND_BACKEND_URL="$FRONTEND_BACKEND_URL" \
    FRONTEND_WS_BACKEND_URL="$FRONTEND_WS_BACKEND_URL" \
    setsid npm exec vite -- --host "$FRONTEND_HOST" --port "$FRONTEND_PORT" --strictPort \
        > "$LOG_DIR/frontend.log" 2>&1 &
    echo $! > "$PID_DIR/frontend.pid"
    green "前端已启动 http://$FRONTEND_HOST:$FRONTEND_PORT (pid $!)"
    cd "$ROOT_DIR"
}

stop_frontend() {
    _stop_one frontend
    _stop_port frontend "$FRONTEND_PORT"
}

start_all() {
    start_backend
    start_frontend
    echo ""
    green "全部启动完成"
    echo "  后端: http://$BACKEND_HOST:$BACKEND_PORT"
    echo "  前端: http://$FRONTEND_HOST:$FRONTEND_PORT"
    echo "  配置: $CONFIG_PATH"
    echo "  日志: $LOG_DIR/"
}

stop_all() {
    stop_frontend
    stop_backend
    green "全部已停止"
}

restart_all() {
    stop_all
    sleep 1
    start_all
}

show_status() {
    echo "=== POC Dashboard 状态 ==="
    if _is_running backend; then
        green "后端: 运行中 (pid $(cat "$PID_DIR/backend.pid")) http://$BACKEND_HOST:$BACKEND_PORT"
    else
        red "后端: 未运行"
    fi
    if _is_running frontend; then
        green "前端: 运行中 (pid $(cat "$PID_DIR/frontend.pid")) http://$FRONTEND_HOST:$FRONTEND_PORT"
    else
        red "前端: 未运行"
    fi
}

show_logs() {
    local target="${1:-all}"
    case "$target" in
        backend)  tail -f "$LOG_DIR/backend.log" ;;
        frontend) tail -f "$LOG_DIR/frontend.log" ;;
        all)      tail -f "$LOG_DIR/backend.log" "$LOG_DIR/frontend.log" ;;
    esac
}

usage() {
    cat <<EOF
用法: $0 <命令> [参数]

命令:
  start            启动前后端
  stop             停止前后端
  restart          重启前后端
  start-backend    仅启动后端
  stop-backend     仅停止后端
  start-frontend   仅启动前端
  stop-frontend    仅停止前端
  status           查看运行状态
  logs [target]    查看日志 (backend/frontend/all, 默认 all)

环境变量:
  CONFIG_PATH      配置文件路径 (默认 $ROOT_DIR/config.yaml)
  BACKEND_HOST     后端监听地址 (默认 0.0.0.0)
  BACKEND_PORT     后端端口 (默认读取 config.yaml server.port)
  BACKEND_VENV_DIR 后端虚拟环境目录 (默认 backend/.venv)
  FRONTEND_HOST    前端监听地址 (默认 0.0.0.0)
  FRONTEND_PORT    前端端口 (默认读取 config.yaml frontend.port)
  FRONTEND_BACKEND_URL 前端代理的后端地址 (默认由 server.host/server.port 派生)

配置文件:
  cluster_dir      验证者集群目录，后端从这里读取 API、chain_id 和密钥
  chain.rest_url   显式链 REST 地址；留空时后端从 cluster_dir 自动探测
  server           后端监听配置
  frontend         前端监听与代理配置
EOF
}

case "${1:-}" in
    start)          start_all ;;
    stop)           stop_all ;;
    restart)        restart_all ;;
    start-backend)  start_backend ;;
    stop-backend)   stop_backend ;;
    start-frontend) start_frontend ;;
    stop-frontend)  stop_frontend ;;
    status)         show_status ;;
    logs)           show_logs "${2:-all}" ;;
    *)              usage ;;
esac
