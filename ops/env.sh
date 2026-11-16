#!/usr/bin/env bash
# ops/env.sh — 精确修改 deploy/.env，并只重建受影响的目标服务
# 用法: clouddock env set KEY[=VALUE] [--svc <服务名>] [--stdin]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
source "$SCRIPT_DIR/lib.sh"

require_root

# 允许修改的键（白名单，避免任意 env 注入；改域名/证书相关键请走 reissue 流程）
# NEWAPI_SQL_DSN：Supabase 连接串（改数据库密码时用；值含密码，务必 --stdin）
ALLOWED_KEYS=(MAGPIE_WEB_KEY MAGPIE_PUBLIC_URL TRAFFIC_QUOTA_GB NEWAPI_SQL_DSN)

usage() {
  echo "用法: clouddock env set KEY[=VALUE] [--svc <服务名>] [--stdin]" >&2
  echo "允许的键: ${ALLOWED_KEYS[*]}" >&2
  exit 2
}

key_allowed() {
  local k="$1" a
  for a in "${ALLOWED_KEYS[@]}"; do
    [[ "$a" == "$k" ]] && return 0
  done
  return 1
}

[[ "${1:-}" == "set" ]] || usage
shift

[[ $# -gt 0 ]] || usage

key=""
val=""
svc=""
from_stdin=0

assign="$1"
shift || true
case "$assign" in
  --*) die "缺少 KEY。" ;;
esac
if [[ "$assign" == *=* ]]; then
  key="${assign%%=*}"
  val="${assign#*=}"
else
  key="$assign"
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --svc)    svc="${2:-}"; shift 2 ;;
    --stdin)  from_stdin=1; shift ;;
    *)        die "未知参数：$1" ;;
  esac
done

[[ -n "$key" ]] || usage
[[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "非法键名：$key"
key_allowed "$key" || die "不允许修改该键：$key（可用：${ALLOWED_KEYS[*]}）"

if [[ "$from_stdin" == "1" ]]; then
  IFS= read -r val || true
fi
[[ -n "$val" ]] || die "缺少值（用 KEY=VALUE 或 --stdin）。"
[[ "$val" != *$'\n'* && "$val" != *$'\r'* && "$val" != *" "* && "$val" != *$'\t'* ]] \
  || die "值不能包含空白或换行。"

# magpie 硬性要求：MAGPIE_WEB_KEY ≥16 字符，否则容器启动即退出
if [[ "$key" == "MAGPIE_WEB_KEY" && ${#val} -lt 16 ]]; then
  die "MAGPIE_WEB_KEY 至少 16 字符（当前 ${#val}）；magpie 启动会拒绝过短密钥。"
fi

# 按前缀推断目标（--svc 优先）；magpie 已改为宿主原生 + systemd，不再是 compose 服务
case "$key" in
  MAGPIE_WEB_KEY|MAGPIE_PUBLIC_URL) svc="${svc:-__magpie_native__}" ;;
  MAGPIE_*) svc="" ;;                          # 其余 MAGPIE_* 只写 .env
  NEWAPI_*) svc="${svc:-new-api}" ;;
esac
if [[ -n "$svc" && "$svc" != "__magpie_native__" ]]; then
  require_svc "$svc"
fi

# 安全写入（避免 sed 分隔符问题）
mkdir -p "$(dirname "$ENV_FILE")"
touch "$ENV_FILE"
grep -vE "^${key}=" "$ENV_FILE" > "$ENV_FILE.tmp" || true
mv "$ENV_FILE.tmp" "$ENV_FILE"
chmod 600 "$ENV_FILE"
printf '%s=%s\n' "$key" "$val" >> "$ENV_FILE"
ok "已写入 $key（值不回显）。"

if [[ "$svc" == "__magpie_native__" ]]; then
  mf="$DEPLOY_DIR/deploy/magpie.env"
  mkdir -p "$(dirname "$mf")"
  ( umask 077
    {
      echo "HOME=/home/agent"
      echo "TZ=Asia/Shanghai"
      printf 'MAGPIE_WEB_KEY=%s\n' "$(env_get MAGPIE_WEB_KEY 2>/dev/null || true)"
      printf 'MAGPIE_PUBLIC_URL=%s\n' "$(env_get MAGPIE_PUBLIC_URL 2>/dev/null || true)"
    } > "$mf"
  )
  chmod 600 "$mf"
  systemctl restart magpie
  ok "已同步 deploy/magpie.env 并重启原生 magpie（systemd）。"
elif [[ -n "$svc" ]]; then
  compose_files
  log "仅重建目标服务 $svc ..."
  compose_up_svc "$svc"
  state="$(docker inspect -f '{{.State.Status}}' "$svc" 2>/dev/null || echo absent)"
  ok "$svc 已重建（当前状态：$state）。"
else
  warn "该键未绑定服务，仅写入 .env，未重启任何容器。"
fi
