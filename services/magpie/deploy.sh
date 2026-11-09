#!/usr/bin/env bash
# magpie 服务：就绪等待 + 生成 gateway key（由 05-services.sh 在 compose up 后调用）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../bootstrap/lib.sh
source "$SCRIPT_DIR/../../bootstrap/lib.sh"

wait_magpie() {
  local i status
  for i in $(seq 1 60); do
    status="$(docker inspect -f '{{.State.Health.Status}}' magpie 2>/dev/null || echo 'none')"
    [[ "$status" == "healthy" ]] && return 0
    sleep 2
  done
  warn "magpie 未在预期时间内变为 healthy（可稍后手动验证）。"
}

wait_magpie

# 生成 gateway key（幂等：已存在则复用）
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
    warn "未能自动生成 gateway key，请稍后在 magpie Web UI（Gateway → Gateway keys）手动创建。"
  fi
fi
