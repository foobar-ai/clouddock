#!/usr/bin/env bash
# 06-openresty-site.sh — 渲染并启用 HTTPS 站点配置（443 反代 new-api + 80 跳转），reload OpenResty
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/../lib.sh"

require_root

DOMAIN="$(cfg NEWAPI_DOMAIN '')"

site_done() {
  local rendered="$OPENRESTY_SITES_DIR/new-api.conf"
  [[ -f "$rendered" ]] || return 1
  grep -q 'listen 443 ssl' "$rendered" || return 1
  [[ -n "$DOMAIN" ]] || return 0
  # 逐字节比对模板渲染结果：站点配置的变更（如关闭 HTTP/2 的安全缓解）才能随 upgrade 落到 VPS，
  # 而不是被「已存在 listen 443 ssl」的标记式判定跳过。
  diff -q <(sed "s/__DOMAIN__/${DOMAIN}/g" "$DEPLOY_DIR/openresty/sites/new-api-https.conf") "$rendered" >/dev/null 2>&1
}

site_run() {
  [[ -n "$DOMAIN" ]] || die "未配置 NEWAPI_DOMAIN，请先运行 bootstrap.sh 完成 .env 初始化。"
  [[ -f "$CERT_DIR/fullchain.cer" && -f "$CERT_DIR/${DOMAIN}.key" ]] \
    || die "证书尚未签发，请先完成 04-cert 阶段。"

  log "渲染 HTTPS 站点配置（域名 ${DOMAIN}）..."
  sed "s/__DOMAIN__/${DOMAIN}/g" \
    "$DEPLOY_DIR/openresty/sites/new-api-https.conf" \
    > "$OPENRESTY_SITES_DIR/new-api.conf"

  log "校验并重载 OpenResty..."
  openresty -t || die "OpenResty 配置校验失败，已回滚配置内容，请检查。"
  systemctl reload openresty 2>/dev/null || service openresty reload

  ok "HTTPS 站点已启用：https://${DOMAIN}  → new-api(127.0.0.1:3000)"
}

run_step "启用 HTTPS 反代站点" site_done site_run
