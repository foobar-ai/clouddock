#!/usr/bin/env bash
# ops/logs.sh — 查看服务日志：clouddock logs <svc> [--tail=N]，输出过滤敏感值
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
source "$SCRIPT_DIR/lib.sh"

require_root

svc="${1:-}"
[[ -n "$svc" ]] || die "用法: clouddock logs <svc> [--tail=N]"
shift || true
valid_svc_name "$svc" || die "非法服务名：$svc"

tail_n=200
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tail=*) tail_n="${1#--tail=}" ;;
    *) warn "忽略未知参数：$1" ;;
  esac
  shift
done
[[ "$tail_n" =~ ^[0-9]+$ ]] || die "非法 tail 值：$tail_n"

docker logs --tail "$tail_n" "$svc" 2>&1 | redact
