#!/usr/bin/env bash
# claude-code-tunnel.sh — 本地建立到 VPS 的 SSH 隧道（链路 A 主用）
# 转发：3425(magpie 网关) 与 3430(Web UI)
# 用法：bash claude-code-tunnel.sh <VPS地址> [SSH用户] [SSH端口]
set -euo pipefail

SSH_HOST="${1:-${SSH_HOST:-}}"
SSH_USER="${2:-${SSH_USER:-root}}"
SSH_PORT="${3:-${SSH_PORT:-22}}"

if [[ -z "$SSH_HOST" ]]; then
  echo "用法：bash claude-code-tunnel.sh <VPS地址> [SSH用户] [SSH端口]" >&2
  echo "示例：bash claude-code-tunnel.sh 1.2.3.4 root 22" >&2
  exit 1
fi

echo "建立 SSH 隧道（保持前台运行，Ctrl+C 退出）："
echo "  127.0.0.1:3425 -> magpie 网关（链路 A：本地 Claude Code 直连）"
echo "  127.0.0.1:3430 -> magpie Web UI"
echo

exec ssh -N -p "$SSH_PORT" \
  -L 127.0.0.1:3425:127.0.0.1:3425 \
  -L 127.0.0.1:3430:127.0.0.1:3430 \
  "${SSH_USER}@${SSH_HOST}"
