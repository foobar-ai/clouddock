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
  local model="" max_tokens=8 thinking="" web_search=0 prompt="ping"
  local key body resp code payload logs start_ms elapsed_ms
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --max-tokens=*) max_tokens="${1#--max-tokens=}"; shift ;;
      --thinking=*)   thinking="${1#--thinking=}"; shift ;;
      --web-search)   web_search=1; prompt="今天新加坡天气如何？"; shift ;;
      -*)             die "未知参数：$1" ;;
      *)              model="$1"; shift ;;
    esac
  done
  [[ "$model" =~ ^[^[:space:]]{1,128}$ ]] || die "用法: clouddock magpie probe <model> [--max-tokens=N] [--thinking=N] [--web-search]"
  [[ "$max_tokens" =~ ^[0-9]{1,7}$ ]] || die "非法 --max-tokens"
  [[ -z "$thinking" || "$thinking" =~ ^[0-9]{1,6}$ ]] || die "非法 --thinking"
  key="$(env_get MAGPIE_GATEWAY_KEY 2>/dev/null || true)"
  [[ -n "$key" ]] || die "deploy/.env 缺少 MAGPIE_GATEWAY_KEY"

  body="$(python3 - "$model" "$max_tokens" "$thinking" "$web_search" "$prompt" <<'PY'
import json, sys
model, max_tokens, thinking, web_search, prompt = (
    sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4] == "1", sys.argv[5])
body = {"model": model, "max_tokens": max_tokens,
        "messages": [{"role": "user", "content": prompt}]}
if thinking:
    body["thinking"] = {"type": "enabled", "budget_tokens": int(thinking)}
if web_search:
    body["tools"] = [{"type": "web_search_20250305", "name": "web_search", "max_uses": 3}]
print(json.dumps(body))
PY
)"

  start_ms="$(date +%s%3N)"
  resp="$(curl -s -m 120 -w '\n%{http_code}' http://127.0.0.1:3425/v1/messages \
    -H "x-api-key: ${key}" -H 'anthropic-version: 2023-06-01' \
    -H 'content-type: application/json' -d "$body" 2>&1 || true)"
  elapsed_ms=$(( $(date +%s%3N) - start_ms ))
  code="${resp##*$'\n'}"
  payload="${resp%$'\n'*}"
  logs="$(docker logs --tail=60 magpie 2>&1 | grep -E "call to .* failed|call to " | tail -n3 || true)"

  payload="$(printf '%s' "$payload" | redact)"

  # 用 -c 而非 heredoc：heredoc 会占用 stdin，且按字节读可避免多字节字符被截断产生非法 UTF-8
  printf '%s' "$payload" | python3 -c '
import json, sys
model, code, logs, elapsed = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
body = sys.stdin.buffer.read().decode("utf-8", "replace")
print(json.dumps({
    "requested_model": model,
    "http_status": code,
    "ok": code.startswith("2"),
    "elapsed_ms": int(elapsed),
    "response_head": body[:800],
    "gateway_log": [l for l in logs.splitlines() if l.strip()],
}, ensure_ascii=False, indent=2))
' "$model" "$code" "$logs" "$elapsed_ms"
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
  group)
    sub="${1:-}"
    case "$sub" in
      ""|list) docker exec magpie magpie groups ;;
      *)  [[ "$sub" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]] || usage
          docker exec magpie magpie group "$sub" ;;
    esac
    ;;
  plugin)
    sub="${1:-}"
    case "$sub" in
      list) docker exec magpie magpie plugin list ;;
      options)
        name="${2:-}"
        [[ "$name" =~ ^[a-z0-9-]{1,32}$ ]] || die "用法: clouddock magpie plugin options <name>（只读，不传 JSON）"
        docker exec magpie magpie plugin options "$name"
        ;;
      *) usage ;;
    esac
    ;;
  probe) probe_model "$@" ;;
  *)
    usage
    ;;
esac
