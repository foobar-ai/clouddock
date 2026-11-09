#!/usr/bin/env bash
# 00-prereq.sh — 系统准备：基础工具、时区、vnstat 流量监控、swap、防火墙提示
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/../lib.sh"

require_root
require_debian12

# 幂等标志：基础工具与 vnstat 均已就绪即跳过
prereq_done() {
  have curl && have vnstat
}

prereq_run() {
  export DEBIAN_FRONTEND=noninteractive

  log "更新软件源并安装基础工具..."
  apt-get update -y
  apt-get install -y \
    curl wget ca-certificates gnupg lsb-release git openssl vnstat

  log "设置时区为 Asia/Shanghai ..."
  timedatectl set-timezone Asia/Shanghai || warn "时区设置失败（可忽略）。"

  log "初始化 vnstat 流量监控（对账出网 tx）..."
  systemctl enable --now vnstat 2>/dev/null || true
  local iface
  iface="$(ip route | awk '/default/ {print $5; exit}')"
  if [[ -n "$iface" ]]; then
    vnstat -i "$iface" --add 2>/dev/null || true
    vnstat -i "$iface" >/dev/null 2>&1 || true
  fi

  log "检查并启用 2GB swap（2GiB 内存防 OOM）..."
  if ! swapon --show | grep -q 'swapfile'; then
    fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi
  sysctl -w vm.swappiness=10 >/dev/null 2>&1 || true
  grep -q 'vm.swappiness' /etc/sysctl.conf || echo 'vm.swappiness=10' >> /etc/sysctl.conf

  warn "请在云厂商控制台【安全组/防火墙】确认已放行 22 / 80 / 443 端口（80/443 用于证书签发与 HTTPS）。"
  ok "系统准备完成。"
}

run_step "系统准备（工具/时区/vnstat/swap）" prereq_done prereq_run
