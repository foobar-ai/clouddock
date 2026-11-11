#!/usr/bin/env bash
# ops/upgrade.sh — 升级：git pull + 幂等重放 bootstrap + apply 收敛
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
source "$SCRIPT_DIR/lib.sh"

require_root

log "git pull --ff-only ..."
git -C "$DEPLOY_DIR" pull --ff-only

log "幂等重放 bootstrap ..."
bash "$DEPLOY_DIR/bootstrap/bootstrap.sh"

log "apply 收敛（确保新增服务被拉起）..."
bash "$SCRIPT_DIR/apply.sh"

ok "upgrade 完成。"
