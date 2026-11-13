#!/usr/bin/env bash
# ops/reload.sh — 校验并重载 OpenResty（不重启容器）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
source "$SCRIPT_DIR/lib.sh"

require_root

have openresty || die "未找到 openresty 命令。"
log "校验 OpenResty 配置 ..."
openresty -t
log "重载 OpenResty ..."
systemctl reload openresty 2>/dev/null || service openresty reload
ok "OpenResty 已重载。"
