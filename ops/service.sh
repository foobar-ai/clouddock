#!/usr/bin/env bash
# ops/service.sh — 单服务生命周期：up | start | stop | pull（只动目标服务）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
source "$SCRIPT_DIR/lib.sh"

require_root

action="${1:-}"
svc="${2:-}"
[[ -n "$action" ]] || die "用法: clouddock <up|start|stop|pull> <服务名>"
require_svc "$svc"

compose_files

case "$action" in
  up)
    log "重建/启动服务 $svc ..."
    compose_up_svc "$svc"
    ;;
  start)
    log "启动服务 $svc ..."
    docker compose --env-file "$ENV_FILE" "${COMPOSE_FILES[@]}" start "$svc"
    ;;
  stop)
    log "停止服务 $svc ..."
    docker compose --env-file "$ENV_FILE" "${COMPOSE_FILES[@]}" stop "$svc"
    ;;
  pull)
    log "拉取服务 $svc 镜像 ..."
    docker compose --env-file "$ENV_FILE" "${COMPOSE_FILES[@]}" pull "$svc"
    log "重建服务 $svc ..."
    compose_up_svc "$svc"
    ;;
  *)
    die "未知动作：$action（可用：up|start|stop|pull）"
    ;;
esac

state="$(docker inspect -f '{{.State.Status}}' "$svc" 2>/dev/null || echo absent)"
ok "$svc $action 完成（当前状态：$state）。"
