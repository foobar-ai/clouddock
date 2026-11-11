#!/usr/bin/env bash
# 04-cert.sh — 按 HTTP-01 或 DNS API 签发 Let's Encrypt 证书，配置续期 reloadcmd
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/../lib.sh"

require_root

DOMAIN="$(cfg NEWAPI_DOMAIN '')"
CERT_MODE="$(cfg CERT_MODE 'http')"
DNS_PROVIDER="$(cfg DNS_PROVIDER '')"
CERT_FORCE="${CERT_FORCE:-0}"
FORCE_FLAG=""
[[ "$CERT_FORCE" == "1" ]] && FORCE_FLAG="--force"

[[ -n "$DOMAIN" ]] || die "未配置 NEWAPI_DOMAIN，请先运行 bootstrap.sh 完成 .env 初始化。"

cert_done() {
  # 强制重签（如切换证书验证方式）时跳过幂等检查
  [[ "$CERT_FORCE" == "1" ]] && return 1
  [[ -f "$CERT_DIR/fullchain.cer" && -f "$CERT_DIR/${DOMAIN}.key" ]]
}

cert_run() {
  mkdir -p "$CERT_DIR"

  if [[ "$CERT_MODE" == "dns" ]]; then
    local dnsapi="$DEPLOY_DIR/deploy/dnsapi.env"
    [[ -f "$dnsapi" ]] || die "DNS 模式需要 deploy/dnsapi.env（含 DNS API 凭证）。"
    [[ -n "$DNS_PROVIDER" ]] || die "DNS 模式需要 DNS_PROVIDER（acme.sh DNS API 标识）。"
    # shellcheck disable=SC1090
    source "$dnsapi"
    log "签发证书（DNS-01，${DNS_PROVIDER}${CERT_FORCE:+，强制重签}）..."
    # shellcheck disable=SC2086
    "$ACME_SH_HOME/acme.sh" --issue -d "$DOMAIN" --dns "$DNS_PROVIDER" --server letsencrypt $FORCE_FLAG
  else
    log "签发证书（HTTP-01，webroot /var/www/acme${CERT_FORCE:+，强制重签}）..."
    # shellcheck disable=SC2086
    "$ACME_SH_HOME/acme.sh" --issue -d "$DOMAIN" --webroot /var/www/acme --server letsencrypt $FORCE_FLAG
  fi

  log "安装证书到 ${CERT_DIR} 并配置续期 reload..."
  "$ACME_SH_HOME/acme.sh" --install-cert -d "$DOMAIN" \
    --cert-file     "$CERT_DIR/fullchain.cer" \
    --key-file      "$CERT_DIR/${DOMAIN}.key" \
    --fullchain-file "$CERT_DIR/fullchain.cer" \
    --reloadcmd     "systemctl reload openresty"

  ok "证书签发并安装完成（自动续期已配置）。"
}

run_step "签发 TLS 证书" cert_done cert_run
