#!/usr/bin/env bash
# ops/restart.sh — 重启服务：clouddock restart <svc|all>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
source "$SCRIPT_DIR/lib.sh"

require_root

svc="${1:-}"
[[ -n "$svc" ]] || die "用法: clouddock restart <svc|all>"

if [[ "$svc" == "all" ]]; then
  for c in $(svc_names); do
    docker restart "$c"
    ok "已重启 $c"
  done
else
  valid_svc_name "$svc" || die "非法服务名：$svc"
  docker restart "$svc"
  ok "已重启 $svc"
fi
