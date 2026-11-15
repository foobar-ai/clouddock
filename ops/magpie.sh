#!/usr/bin/env bash
# ops/magpie.sh — magpie 内部操作（网关密钥）
# 用法: clouddock magpie gwkey list|add <name>|remove <name|id>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
source "$SCRIPT_DIR/lib.sh"

require_root

usage() {
  echo "用法: clouddock magpie gwkey list|add <name>|remove <name|id> | plugin list | probe <model>" >&2
  exit 2
}

# 只读探针：向本机网关发一次最小请求（max_tokens=8），回显 HTTP 码 + 响应摘要 + 网关日志里的实际路由目标。
# 用于验证模型重定向（model-map 中间件）是否生效，不修改任何配置。
probe_model() {
  local model="${1:-}" key body resp code payload logs
  [[ "$model" =~ ^[^[:space:]]{1,128}$ ]] || die "用法: clouddock magpie probe <model>"
  key="$(env_get MAGPIE_GATEWAY_KEY 2>/dev/null || true)"
  [[ -n "$key" ]] || die "deploy/.env 缺少 MAGPIE_GATEWAY_KEY"

  body="$(python3 - "$model" <<'PY'
import json, sys
print(json.dumps({"model": sys.argv[1], "max_tokens": 8,
                  "messages": [{"role": "user", "content": "ping"}]}))
PY
)"

  resp="$(curl -s -m 90 -w '\n%{http_code}' http://127.0.0.1:3425/v1/messages \
    -H "x-api-key: ${key}" -H 'anthropic-version: 2023-06-01' \
    -H 'content-type: application/json' -d "$body" 2>&1 || true)"
  code="${resp##*$'\n'}"
  payload="${resp%$'\n'*}"
  logs="$(docker logs --tail=60 magpie 2>&1 | grep -E "call to .* failed|call to " | tail -n3 || true)"

  printf '%s' "$payload" | redact | python3 - "$model" "$code" "$logs" <<'PY'
import json, sys
model, code, logs = sys.argv[1], sys.argv[2], sys.argv[3]
payload = sys.stdin.read()
print(json.dumps({
    "requested_model": model,
    "http_status": code,
    "ok": code.startswith("2"),
    "response_head": payload[:400],
    "gateway_log": [l for l in logs.splitlines() if l.strip()],
}, ensure_ascii=False, indent=2))
PY
}

group="${1:-}"
[[ -n "$group" ]] || usage
shift || true

case "$group" in
  gwkey)
    sub="${1:-}"
    [[ -n "$sub" ]] || usage
    shift || true
    case "$sub" in
      list)
        docker exec magpie magpie gateway-key list
        ;;
      add)
        name="${1:-}"
        [[ -n "$name" ]] || die "用法: clouddock magpie gwkey add <name>"
        [[ "$name" =~ ^[A-Za-z0-9._-]{1,32}$ ]] || die "非法 key 名称：$name"
        docker exec magpie magpie gateway-key add "$name"
        ;;
      remove)
        sel="${1:-}"
        [[ -n "$sel" ]] || die "用法: clouddock magpie gwkey remove <name|id>"
        [[ "$sel" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || die "非法 key 标识：$sel"
        docker exec magpie magpie gateway-key remove "$sel"
        ;;
      *)
        usage
        ;;
    esac
    ;;
  plugin)
    sub="${1:-}"
    case "$sub" in
      list) docker exec magpie magpie plugin list ;;
      *)    usage ;;
    esac
    ;;
  probe) probe_model "${1:-}" ;;
  *)
    usage
    ;;
esac
