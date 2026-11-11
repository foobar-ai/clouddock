#!/usr/bin/env bash
# clouddock-ops-ssh.sh — 本地调用 wrapper：用专用 key 经白名单通道执行远端 clouddock
# 用法: bash scripts/clouddock-ops-ssh.sh <子命令> [参数]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OPS_DIR="$REPO_DIR/.clouddock"
CONF="$OPS_DIR/ops.conf"
KEY="$OPS_DIR/ops_key"

[[ -f "$CONF" ]] || { echo "缺少 $CONF，请先运行 bash scripts/install-ops.sh <VPS地址>" >&2; exit 1; }
[[ -f "$KEY" ]] || { echo "缺少 $KEY，请先运行 bash scripts/install-ops.sh <VPS地址>" >&2; exit 1; }

# shellcheck source=/dev/null
source "$CONF"

cmd="${*:-status}"
ssh -i "$KEY" -p "${OPS_SSH_PORT:-22}" "${OPS_SSH_USER:-root}@${OPS_SSH_HOST}" "$cmd"
