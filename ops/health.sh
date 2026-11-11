#!/usr/bin/env bash
# ops/health.sh — 执行巡检并写 /opt/clouddock-data/health.json（供 AI 按需读取）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
source "$SCRIPT_DIR/lib.sh"

require_root
mkdir -p "$DATA_DIR"

snapshot="$(bash "$SCRIPT_DIR/status.sh")"
printf '%s\n' "$snapshot" > "$DATA_DIR/health.json"

# 顺带打印一行摘要（证书剩余天数 / 异常容器数）
echo "$snapshot" | python3 -c '
import json, sys
d = json.load(sys.stdin)
c = d.get("cert", {})
bad = [x["name"] for x in d.get("containers", []) if x.get("state") != "running" or x.get("health") == "unhealthy"]
print("health ok | cert days_left=%s | 异常容器=%s" % (c.get("days_left"), bad or "无"))
'
ok "健康快照已写入 $DATA_DIR/health.json"
