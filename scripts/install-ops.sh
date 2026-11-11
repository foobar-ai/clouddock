#!/usr/bin/env bash
# install-ops.sh — 一键打通 AI 运维白名单通道（本地执行一次）
# 用法: bash scripts/install-ops.sh <VPS地址> [SSH用户] [SSH端口]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

HOST="${1:-}"
[[ -n "$HOST" ]] || { echo "用法: bash scripts/install-ops.sh <VPS地址> [SSH用户] [SSH端口]" >&2; exit 2; }
SSH_USER="${2:-root}"
SSH_PORT="${3:-22}"

OPS_DIR="$REPO_DIR/.clouddock"
mkdir -p "$OPS_DIR"
KEY="$OPS_DIR/ops_key"
CONF="$OPS_DIR/ops.conf"

# 生成专用密钥（已存在则复用）
if [[ ! -f "$KEY" ]]; then
  ssh-keygen -t ed25519 -N '' -C "clouddock-ops" -f "$KEY" >/dev/null
fi
printf 'OPS_SSH_HOST=%s\nOPS_SSH_USER=%s\nOPS_SSH_PORT=%s\n' "$HOST" "$SSH_USER" "$SSH_PORT" > "$CONF"
chmod 600 "$KEY" "$CONF"

PUB="$(cat "$KEY.pub")"
LINE="command=\"/opt/clouddock/ops/shell.sh\",no-pty,no-port-forwarding,no-agent-forwarding,no-X11-forwarding $PUB"

echo "== 推送白名单与定时巡检到 VPS（首次需输入一次密码）=="
ssh -p "$SSH_PORT" "$SSH_USER@$HOST" "bash -s" <<REMOTE
set -euo pipefail
cd /opt/clouddock && git pull --ff-only
mkdir -p ~/.ssh && chmod 700 ~/.ssh
touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
LINE='$LINE'
grep -qF -- "\$LINE" ~/.ssh/authorized_keys || printf '%s\n' "\$LINE" >> ~/.ssh/authorized_keys
bash /opt/clouddock/ops/cron-install.sh
REMOTE

echo ""
echo "完成。验证白名单通道（应输出 JSON，无需再输入密码）："
echo "  bash scripts/clouddock-ops-ssh.sh status"
