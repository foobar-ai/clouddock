#!/usr/bin/env bash
# 05-services.sh — 聚合启动所有服务：准备数据目录 + compose up + 各服务后置初始化
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "$SCRIPT_DIR/../lib.sh"

require_root

services_done() {
  local running
  running="$(docker ps --format '{{.Names}}' 2>/dev/null || true)"
  if grep -qx 'new-api' <<< "$running" && grep -qx 'magpie' <<< "$running"; then
    return 0
  fi
  return 1
}

# 构建所有服务的 compose -f 参数列表
build_compose_files() {
  COMPOSE_FILES=()
  local f
  for f in "$COMPOSE_DIR"/*/compose.yml; do
    [[ -f "$f" ]] && COMPOSE_FILES+=(-f "$f")
  done
  [[ "${#COMPOSE_FILES[@]}" -gt 0 ]] || die "未找到任何服务 compose 文件（${COMPOSE_DIR}）。"
}

services_run() {
  log "准备数据目录与权限..."
  mkdir -p "$DATA_DIR/new-api" "$DATA_DIR/magpie"
  # magpie 容器内 nonroot uid 65532，需可写 /config
  chown -R 65532:65532 "$DATA_DIR/magpie"

  build_compose_files
  log "拉取镜像并启动所有服务..."
  docker compose --env-file "$ENV_FILE" "${COMPOSE_FILES[@]}" pull
  docker compose --env-file "$ENV_FILE" "${COMPOSE_FILES[@]}" up -d

  log "执行各服务后置初始化..."
  local s
  for s in "$COMPOSE_DIR"/*/deploy.sh; do
    [[ -f "$s" ]] || continue
    log "  执行 $(basename "$(dirname "$s")")/deploy.sh ..."
    bash "$s"
  done

  ok "服务启动完成。"
  docker compose --env-file "$ENV_FILE" "${COMPOSE_FILES[@]}" ps
}

run_step "启动所有服务" services_done services_run
