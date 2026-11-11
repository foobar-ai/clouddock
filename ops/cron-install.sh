#!/usr/bin/env bash
# ops/cron-install.sh — 安装定时巡检（/etc/cron.d/clouddock-health，每天 0 点与 12 点执行）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
source "$SCRIPT_DIR/lib.sh"

require_root

CRON_FILE="/etc/cron.d/clouddock-health"
cat > "$CRON_FILE" <<EOF
# clouddock 健康巡检：每天 0 点、12 点写 /opt/clouddock-data/health.json
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 0,12 * * * root $DEPLOY_DIR/ops/health.sh >/dev/null 2>&1
EOF
chmod 644 "$CRON_FILE"
ok "已安装定时巡检：$CRON_FILE"
