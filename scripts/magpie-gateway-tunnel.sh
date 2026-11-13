#!/usr/bin/env bash
# magpie-gateway-tunnel.sh — 本地到 VPS magpie 网关(3425)的 SSH 隧道（后台可管理）
# 用于在本机 magpie「Remote magpie」里把 VPS 当作上游供应商，本地 Agent 使用 VPS 模型。
# 只转发 3425(网关)；本地端口默认 3426，避开本地 magpie 占用的 3425。
# 用法:
#   bash scripts/magpie-gateway-tunnel.sh start [VPS地址] [SSH用户] [SSH端口] [本地端口]
#   bash scripts/magpie-gateway-tunnel.sh stop
#   bash scripts/magpie-gateway-tunnel.sh status
# VPS 地址不传时，自动读取 .clouddock/ops.conf（OPS_SSH_HOST/USER/PORT）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OPS_DIR="$REPO_DIR/.clouddock"
CONF="$OPS_DIR/ops.conf"
CTL="$OPS_DIR/magpie-gw.sock"
STATE="$OPS_DIR/magpie-gw.state"
OPS_KEY="$OPS_DIR/ops_key"

ACTION="${1:-status}"

usage() {
  echo "用法:" >&2
  echo "  bash scripts/magpie-gateway-tunnel.sh start [VPS地址] [SSH用户] [SSH端口] [本地端口]" >&2
  echo "  bash scripts/magpie-gateway-tunnel.sh stop" >&2
  echo "  bash scripts/magpie-gateway-tunnel.sh status" >&2
}

load_conf() {
  [[ -f "$CONF" ]] || return 0
  # shellcheck source=/dev/null
  source "$CONF"
}

read_state() {
  [[ -f "$STATE" ]] || return 0
  # shellcheck source=/dev/null
  source "$STATE"
}

start() {
  load_conf
  SSH_HOST="${2:-${OPS_SSH_HOST:-}}"
  SSH_USER="${3:-${OPS_SSH_USER:-root}}"
  SSH_PORT="${4:-${OPS_SSH_PORT:-22}}"
  LOCAL_PORT="${5:-${LOCAL_PORT:-3426}}"

  if [[ -z "$SSH_HOST" ]]; then
    echo "未提供 VPS 地址，且 .clouddock/ops.conf 不存在。" >&2
    echo "请先运行 bash scripts/install-ops.sh <VPS地址>，或显式传 <VPS地址>。" >&2
    exit 2
  fi

  if [[ -S "$CTL" ]] && ssh -S "$CTL" -O check "$SSH_USER@$SSH_HOST" >/dev/null 2>&1; then
    echo "隧道已在运行：http://127.0.0.1:${LOCAL_PORT} -> VPS 127.0.0.1:3425"
    exit 0
  fi
  rm -f "$CTL"

  mkdir -p "$OPS_DIR"
  # 复用运维专用 key（install-ops.sh 已授权 permitopen="127.0.0.1:3425"）：
  # -N 纯转发不触发 command= 白名单命令，无需额外密钥。
  SSH_KEY_OPT=()
  if [[ -f "$OPS_KEY" ]]; then
    SSH_KEY_OPT=(-i "$OPS_KEY")
  fi

  if ! ssh -f -N -M -S "$CTL" \
    ${SSH_KEY_OPT[@]+"${SSH_KEY_OPT[@]}"} \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
    -p "$SSH_PORT" \
    -L "127.0.0.1:${LOCAL_PORT}:127.0.0.1:3425" \
    "$SSH_USER@$SSH_HOST"; then
    rm -f "$CTL" "$STATE"
    echo "隧道建立失败：确认 VPS 可达、且 .clouddock/ops_key 免密可用（先跑 install-ops.sh）。" >&2
    exit 1
  fi

  printf 'SSH_HOST=%s\nSSH_USER=%s\nSSH_PORT=%s\nLOCAL_PORT=%s\n' \
    "$SSH_HOST" "$SSH_USER" "$SSH_PORT" "$LOCAL_PORT" > "$STATE"
  chmod 600 "$STATE"

  if [[ -S "$CTL" ]] && ssh -S "$CTL" -O check "$SSH_USER@$SSH_HOST" >/dev/null 2>&1; then
    echo "隧道已建立：127.0.0.1:${LOCAL_PORT} -> VPS 127.0.0.1:3425"
    echo
    echo "本机 magpie「供应商 → 添加 → Remote magpie」填写："
    echo "  接口地址：http://127.0.0.1:${LOCAL_PORT}"
    echo "  API 密钥：VPS 的 gateway key（sk-magpie-key-...）"
    echo "  获取/新建（在本地仓库执行）："
    echo "    bash scripts/clouddock-ops-ssh.sh magpie gwkey add MacBook"
    echo
    echo "关闭隧道：bash scripts/magpie-gateway-tunnel.sh stop"
  else
    rm -f "$CTL" "$STATE"
    echo "隧道建立失败，请检查 VPS 地址与 SSH 登录。" >&2
    exit 1
  fi
}

stop() {
  if [[ ! -S "$CTL" ]]; then
    echo "隧道未在运行。"
    exit 0
  fi
  read_state
  if [[ -n "${SSH_HOST:-}" ]]; then
    ssh -S "$CTL" -O exit "${SSH_USER:-root}@${SSH_HOST}" >/dev/null 2>&1 || true
  fi
  rm -f "$CTL" "$STATE"
  echo "隧道已关闭。"
}

status() {
  if [[ ! -S "$CTL" ]]; then
    echo "隧道未在运行。"
    exit 1
  fi
  read_state
  if ssh -S "$CTL" -O check "${SSH_USER:-root}@${SSH_HOST:-}" >/dev/null 2>&1; then
    echo "隧道运行中：http://127.0.0.1:${LOCAL_PORT:-3426} -> VPS 127.0.0.1:3425"
  else
    echo "控制套接字已失效，隧道未在运行。"
    rm -f "$CTL" "$STATE"
    exit 1
  fi
}

case "$ACTION" in
  start)  start "$@" ;;
  stop)   stop ;;
  status) status ;;
  *)      usage; exit 2 ;;
esac
