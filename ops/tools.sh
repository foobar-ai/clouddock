#!/usr/bin/env bash
# ops/tools.sh — 受控安装 VPS 侧工具（只允许固定白名单集合，走 Debian 官方 apt 源）
# 用法: clouddock tools ensure <tool>   目前白名单：tmux
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
source "$SCRIPT_DIR/lib.sh"

require_root

ALLOWED_TOOLS="tmux"

usage() {
  echo "用法: clouddock tools ensure <tool>（允许：$ALLOWED_TOOLS）" >&2
  exit 2
}

ensure_tool() {
  local tool="${1:-}" ver
  [[ -n "$tool" ]] || usage
  case " $ALLOWED_TOOLS " in
    *" $tool "*) ;;
    *) die "不允许安装：$tool（白名单：$ALLOWED_TOOLS）" ;;
  esac

  if have "$tool"; then
    ver="$("$tool" -V 2>&1 | head -n1 || true)"
    ok "$tool 已安装（${ver:-版本未知}），无需操作。"
    return 0
  fi

  log "安装 $tool（apt，官方源）..."
  export DEBIAN_FRONTEND=noninteractive
  if ! apt-get install -y --no-install-recommends "$tool" >/dev/null 2>&1; then
    log "软件源索引可能过期，apt-get update 后重试 ..."
    apt-get update -qq
    apt-get install -y --no-install-recommends "$tool"
  fi
  have "$tool" || die "$tool 安装失败"
  ver="$("$tool" -V 2>&1 | head -n1 || true)"
  ok "$tool 安装完成（${ver:-版本未知}）。"
}

action="${1:-}"
case "$action" in
  ensure) shift || true; ensure_tool "${1:-}" ;;
  *)      usage ;;
esac
