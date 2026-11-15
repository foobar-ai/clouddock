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
  mcp)
    # 只读：列出当前网关密钥可用的 MCP 服务器与工具（/v1/magpie/mcp）
    key="$(env_get MAGPIE_GATEWAY_KEY 2>/dev/null || true)"
    [[ -n "$key" ]] || die "deploy/.env 缺少 MAGPIE_GATEWAY_KEY"
    curl -s -m 15 -H "Authorization: Bearer ${key}" http://127.0.0.1:3425/v1/magpie/mcp \
      || die "查询 MCP 列表失败"
    echo
    ;;
  files)
    # 只读：容器 /config 卷的结构（迁移到原生前要知道拷哪些）
    docker exec magpie sh -c 'find /config -mindepth 1 -maxdepth 2 | sort | head -60'
    ;;
  native-status)
    # 只读：宿主是否已有原生 magpie、agent 是否有 linger、3425/3430 谁在监听
    echo "--- 宿主 magpie"
    command -v magpie || echo "(PATH 中无 magpie)"
    ls -l /home/agent/.local/bin/magpie 2>/dev/null || echo "(agent 用户下无 magpie)"
    echo "--- linger"
    loginctl show-user agent -p Linger 2>/dev/null || echo "(无法查询 linger)"
    echo "--- agent systemd user units"
    ls /home/agent/.config/systemd/user 2>/dev/null | head -20 || echo "(无)"
    echo "--- 端口"
    ss -lntp 2>/dev/null | grep -E ':(3425|3430)\b' || echo "(3425/3430 未监听)"
    ;;
  runtime)
    # 只读：确认 magpie 容器内可用的运行时（决定命令型 MCP server 能否启动）
    docker exec magpie sh -c '
      for c in sh node npx bun uv uvx python3 git; do
        if command -v "$c" >/dev/null 2>&1; then printf "%-8s %s\n" "$c" "$(command -v "$c")";
        else printf "%-8s (缺失)\n" "$c"; fi
      done
      echo "--- versions"
      node -v 2>/dev/null || true
      bun --version 2>/dev/null || true
      python3 -V 2>/dev/null || true' 2>&1 || die "容器内无 sh（可能是 distroless 镜像）"
    ;;
  search)
    # 只读：列出已配置的搜索来源（provider 搜索 / Search API）及顺序
    docker exec magpie magpie search
    ;;
  library)
    # 只读：Library 概况（哪些 agent 走 MCP router、哪些保留独立条目）
    docker exec magpie magpie library
    ;;
  router)
    case "${1:-}" in
      on|off)
        docker exec magpie magpie library mcp router "${1}"
        ;;
      *)
        # 只读：从 magpie 的配置文件里取 MCP router 开关
        docker exec magpie sh -c '
          for f in /config/magpie/settings.json /config/settings.json /config/magpie/config.json; do
            [ -f "$f" ] || continue
            echo "--- $f"
            grep -oiE "\"[a-zA-Z]*router[a-zA-Z]*\"[[:space:]]*:[[:space:]]*(true|false)" "$f" || echo "(未找到 router 键)"
          done' 2>/dev/null || die "读取失败"
        ;;
    esac
    ;;
  mcp-call)
    # 只读诊断：调用一次 MCP 工具（仅支持带 query 参数的搜索类工具），并计时
    mpath="${1:-}"; mtool="${2:-}"; mquery="${3:-}"
    [[ "$mpath" =~ ^/mcp/magpie/[a-z][a-z0-9-]{0,31}$ ]] || die "非法 MCP 路径：$mpath"
    [[ "$mtool" =~ ^[a-z][a-z0-9_]{0,63}$ ]] || die "非法工具名：$mtool"
    [[ "$mquery" =~ ^[A-Za-z0-9._-]{1,200}$ ]] || die "非法查询词（只允许字母数字 . _ -，不含空格）"
    key="$(env_get MAGPIE_GATEWAY_KEY 2>/dev/null || true)"
    [[ -n "$key" ]] || die "deploy/.env 缺少 MAGPIE_GATEWAY_KEY"
    body="$(python3 -c 'import json,sys
print(json.dumps({"jsonrpc":"2.0","id":1,"method":"tools/call",
                  "params":{"name":sys.argv[1],"arguments":{"query":sys.argv[2]}}}))' "$mtool" "$mquery")"
    start_ms="$(date +%s%3N)"
    curl -s -m 180 -X POST "http://127.0.0.1:3425${mpath}" \
      -H "Authorization: Bearer ${key}" \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' \
      -d "$body" | head -c 2500
    echo
    log "elapsed_ms=$(( $(date +%s%3N) - start_ms ))"
    ;;
  mcp-tools)
    # 只读：按 MCP 协议先 initialize 拿 session，再 tools/list（hub 是有状态的）
    mpath="${1:-/mcp}"
    [[ "$mpath" =~ ^/mcp(/[A-Za-z0-9-]{1,32}){0,3}$ ]] || die "非法 MCP 路径：$mpath"
    key="$(env_get MAGPIE_GATEWAY_KEY 2>/dev/null || true)"
    [[ -n "$key" ]] || die "deploy/.env 缺少 MAGPIE_GATEWAY_KEY"
    url="http://127.0.0.1:3425${mpath}"

    init_resp="$(curl -s -D - -m 25 -X POST "$url" \
      -H "Authorization: Bearer ${key}" \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' \
      -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"clouddock","version":"0"}}}' || true)"
    sid="$(printf '%s' "$init_resp" | tr -d '\r' | grep -i '^mcp-session-id:' | awk '{print $2}' | head -n1)"

    # 按 MCP 规范补发 initialized 通知，否则部分实现不提供工具
    if [[ -n "$sid" ]]; then
      curl -s -m 10 -o /dev/null -X POST "$url" \
        -H "Authorization: Bearer ${key}" \
        -H "Mcp-Session-Id: ${sid}" \
        -H 'Content-Type: application/json' \
        -H 'Accept: application/json, text/event-stream' \
        -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' || true
    fi

    tl="$(curl -s -m 40 -w '\nHTTP:%{http_code}' -X POST "$url" \
      -H "Authorization: Bearer ${key}" \
      ${sid:+-H "Mcp-Session-Id: ${sid}"} \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' \
      -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' || true)"
    printf '%s\n' "$tl" | head -c 4000
    echo
    [[ -n "$sid" ]] && log "session=$sid" || warn "未拿到 Mcp-Session-Id（该端点可能无状态或不支持 initialize）"
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
