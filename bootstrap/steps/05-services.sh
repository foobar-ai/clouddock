#!/usr/bin/env bash
# 05-services.sh — 生成数据目录与权限，compose up 启动 new-api + magpie，生成 magpie gateway key
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/../lib.sh"

require_root

services_done() {
  local up
  up="$(docker compose -f "$COMPOSE_FILE" ps --status running --format '{{.Service}}' 2>/dev/null || true)"
  if grep -qx 'new-api' <<< "$up" && grep -qx 'magpie' <<< "$up"; then
    return 0
  fi
  return 1
}

# 等待 magpie 健康（镜像自带 HEALTHCHECK）
wait_magpie() {
  local i status
  for i in $(seq 1 60); do
    status="$(docker inspect -f '{{.State.Health.Status}}' magpie 2>/dev/null || echo 'none')"
    [[ "$status" == "healthy" ]] && return 0
    sleep 2
  done
  warn "magpie 未在预期时间内变为 healthy（可稍后手动验证）。"
  return 0
}

services_run() {
  log "准备数据目录与权限..."
  mkdir -p "$DATA_DIR/new-api" "$DATA_DIR/magpie"
  # magpie 容器内 nonroot uid 65532，需可写 /config
  chown -R 65532:65532 "$DATA_DIR/magpie"

  cd "$DEPLOY_DIR/deploy"
  log "拉取镜像并启动容器..."
  docker compose pull
  docker compose up -d

  log "等待 magpie 就绪..."
  wait_magpie

  # 生成 gateway key（幂等：已存在则复用）
  local gk
  gk="$(env_get MAGPIE_GATEWAY_KEY 2>/dev/null || true)"
  if [[ -n "$gk" ]]; then
    ok "magpie gateway key 已存在，复用。"
  else
    log "生成 magpie gateway key..."
    gk="$(docker exec magpie magpie gateway-key add "Laptop" 2>/dev/null | grep -oE 'sk-[A-Za-z0-9_-]+' | tail -n1 || true)"
    if [[ -n "$gk" ]]; then
      env_set MAGPIE_GATEWAY_KEY "$gk"
      ok "magpie gateway key 已生成：${gk}"
    else
      warn "未能自动生成 gateway key，请稍后在 magpie Web UI（Gateway → Gateway keys）手动创建，填入 ANTHROPIC_API_KEY。"
    fi
  fi

  ok "服务启动完成。"
  docker compose -f "$COMPOSE_FILE" ps
}

run_step "启动 new-api + magpie" services_done services_run
