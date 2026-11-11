#!/usr/bin/env bash
# ops/apply.sh — 聚合启动所有服务（compose up -d + 各 deploy.sh），不走就绪跳过
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
source "$SCRIPT_DIR/lib.sh"

require_root

COMPOSE_FILES=()
for f in "$COMPOSE_DIR"/*/compose.yml; do
  [[ -f "$f" ]] && COMPOSE_FILES+=(-f "$f")
done
[[ "${#COMPOSE_FILES[@]}" -gt 0 ]] || die "未找到任何服务 compose 文件（${COMPOSE_DIR}）。"

log "聚合启动所有服务（apply）..."
docker compose --env-file "$ENV_FILE" "${COMPOSE_FILES[@]}" up -d

log "执行各服务后置初始化..."
for s in "$COMPOSE_DIR"/*/deploy.sh; do
  [[ -f "$s" ]] || continue
  log "  执行 $(basename "$(dirname "$s")")/deploy.sh ..."
  bash "$s"
done

ok "apply 完成。"
docker compose --env-file "$ENV_FILE" "${COMPOSE_FILES[@]}" ps
