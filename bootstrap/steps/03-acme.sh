#!/usr/bin/env bash
# 03-acme.sh — 安装 acme.sh（官方脚本）并注册账户
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/../lib.sh"

require_root

acme_done() {
  [[ -x "$ACME_SH_HOME/acme.sh" ]]
}

acme_run() {
  local email domain
  domain="$(cfg NEWAPI_DOMAIN '')"
  email="admin@${domain:-example.com}"
  log "安装 acme.sh（官方脚本，注册邮箱 ${email}）..."
  curl -fsSL https://get.acme.sh | sh -s email="$email"
  ok "acme.sh 安装完成。"
}

run_step "安装 acme.sh" acme_done acme_run
