#!/usr/bin/env bash
# install.sh — 开源安装入口（curl | bash）
# 用法（在 VPS 上以 root 执行）：
#   curl -fsSL https://raw.githubusercontent.com/foobar-ai/clouddock/main/install.sh | bash
# 或指定仓库（如 fork 后自用）：
#   curl -fsSL <raw-install-url> | REPO_URL=https://github.com/<user>/<repo>.git bash
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/foobar-ai/clouddock.git}"
BRANCH="${BRANCH:-main}"
INSTALL_DIR="${INSTALL_DIR:-/opt/clouddock}"

info() { echo -e "\033[0;34m[INFO]\033[0m $*"; }
die()  { echo -e "\033[0;31m[ERR ]\033[0m $*" >&2; exit 1; }

# root 校验
[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "请以 root 运行：sudo -i 后再执行本脚本。"

# 依赖（Debian 12 最小安装可能缺 git）
export DEBIAN_FRONTEND=noninteractive
if ! command -v git >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  info "安装 git/curl ..."
  apt-get update -y
  apt-get install -y git curl
fi

# 克隆或更新仓库
if [[ -d "$INSTALL_DIR/.git" ]]; then
  info "更新仓库 ..."
  git -C "$INSTALL_DIR" pull --ff-only
else
  info "克隆仓库到 $INSTALL_DIR ..."
  git clone --depth 1 -b "$BRANCH" "$REPO_URL" "$INSTALL_DIR"
fi

# 执行部署。stdin 重定向到 /dev/tty，确保 curl | bash 场景下交互输入仍可用。
info "开始部署 ..."
if [[ -t 0 ]]; then
  bash "$INSTALL_DIR/bootstrap/bootstrap.sh"
else
  bash "$INSTALL_DIR/bootstrap/bootstrap.sh" < /dev/tty
fi
