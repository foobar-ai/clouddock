#!/usr/bin/env bash
# 01-docker.sh — 安装 Docker CE + Compose Plugin（官方源），校验 daemon，拉取健康检查
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/../lib.sh"

require_root
require_debian12

docker_done() {
  have docker && docker info >/dev/null 2>&1
}

docker_install() {
  export DEBIAN_FRONTEND=noninteractive

  log "安装依赖并配置 Docker 官方 apt 源..."
  apt-get install -y ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  # shellcheck disable=SC1091
  local codename
  codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${codename} stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  ok "Docker 安装完成。"
}

docker_pull_check() {
  log "拉取健康检查（官方 registry，默认不配第三方加速）..."
  # 失败仅告警不中断：05-services 阶段会再次 compose pull 重试
  docker pull calciumion/new-api:latest || warn "new-api 镜像拉取失败（稍后 compose pull 会重试）。"
  docker pull ghcr.io/yetone/magpie:latest || warn "magpie 镜像拉取失败（稍后 compose pull 会重试）。"
}

if ! docker_done; then
  run_step "安装 Docker CE + Compose Plugin" docker_done docker_install
fi

docker_pull_check
ok "Docker 环境就绪。"
