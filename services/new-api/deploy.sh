#!/usr/bin/env bash
# new-api 服务：就绪等待（由 05-services.sh 在 compose up 后调用）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../bootstrap/lib.sh
source "$SCRIPT_DIR/../../bootstrap/lib.sh"

wait_newapi() {
  local i status
  for i in $(seq 1 60); do
    status="$(docker inspect -f '{{.State.Health.Status}}' new-api 2>/dev/null || echo 'none')"
    [[ "$status" == "healthy" ]] && return 0
    sleep 2
  done
  warn "new-api 未在预期时间内变为 healthy（可稍后手动验证）。"
}

wait_newapi
ok "new-api 已就绪。"
