#!/usr/bin/env bash
# 02-openresty.sh — 安装 OpenResty（官方源），部署基础配置与 acme challenge 目录，启用 HTTP 阶段站点
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/../lib.sh"

require_root
require_debian12

openresty_done() {
  have openresty && [[ -f "$OPENRESTY_SITES_DIR/new-api.conf" ]]
}

openresty_run() {
  export DEBIAN_FRONTEND=noninteractive

  log "配置 OpenResty 官方 apt 源..."
  apt-get install -y ca-certificates curl gnupg lsb-release
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://openresty.org/package/pubkey.gpg | gpg --dearmor -o /etc/apt/keyrings/openresty.gpg
  local codename
  codename="$(lsb_release -sc)"
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/openresty.gpg] http://openresty.org/package/debian ${codename} openresty" \
    > /etc/apt/sources.list.d/openresty.list

  log "安装 OpenResty（固定版本，见下方说明）..."
  apt-get update -y
  # 固定到 OpenSSL 3.0 时代的稳定版：openresty.org 的 bookworm 新包（1.31.x）在
  # OpenSSL 3.2/3.5 环境编译，与 Debian 12 的 libssl3(3.0) 不兼容，会导致 nginx 起不来。
  # 用 apt-mark hold 锁定，避免 apt upgrade 时被升回不兼容版本。
  OPENRESTY_VER="${OPENRESTY_VER:-1.27.1.2-1~bookworm1}"
  apt-get install -y \
    "openresty=${OPENRESTY_VER}" \
    "openresty-opm=${OPENRESTY_VER}" \
    "openresty-resty=${OPENRESTY_VER}"
  apt-mark hold openresty openresty-opm openresty-resty

  log "创建目录结构..."
  mkdir -p /var/www/acme "$CERT_DIR" "$OPENRESTY_SITES_DIR"

  log "部署主配置与 HTTP 阶段站点配置..."
  if [[ -f "$OPENRESTY_CONF_DIR/nginx.conf" ]]; then
    cp -a "$OPENRESTY_CONF_DIR/nginx.conf" "$OPENRESTY_CONF_DIR/nginx.conf.bak.$(date +%s)" || true
  fi
  cp "$DEPLOY_DIR/openresty/nginx.conf" "$OPENRESTY_CONF_DIR/nginx.conf"
  cp "$DEPLOY_DIR/openresty/sites/new-api-http.conf" "$OPENRESTY_SITES_DIR/new-api.conf"

  log "校验并启动 OpenResty..."
  openresty -t || die "OpenResty 配置校验失败。"
  # 必须 restart 而非 enable --now：apt 装包时可能已自启（仍是默认配置），
  # enable --now 见服务已 active 不会重载，导致新配置不生效。
  systemctl enable openresty 2>/dev/null || true
  systemctl restart openresty 2>/dev/null || service openresty restart || true
  ok "OpenResty 已安装并启动（HTTP 阶段）。"
}

run_step "安装 OpenResty 与基础配置" openresty_done openresty_run
