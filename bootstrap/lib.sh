#!/usr/bin/env bash
# lib.sh — 公共函数库：日志、校验、幂等检查、.env 读写
# 由 bootstrap.sh 及各阶段脚本 source 使用。
# 注意：本文件被 source，不在此设置 set（由各调用脚本自行 set -euo pipefail）。

# ---------- 路径常量 ----------
DEPLOY_DIR="${DEPLOY_DIR:-/opt/clouddock}"                 # 远端项目根目录
ENV_FILE="$DEPLOY_DIR/deploy/.env"                        # 环境文件（含用户输入与自动生成密钥）
COMPOSE_DIR="$DEPLOY_DIR/services"                           # 服务目录：每个 services/<name>/compose.yml
DATA_DIR="/opt/clouddock-data"                             # 数据目录（独立于代码目录，代码更新不覆盖）：new-api /data 与 magpie /config
OPENRESTY_PREFIX="/usr/local/openresty/nginx"             # OpenResty 官方 apt 安装前缀
OPENRESTY_CONF_DIR="$OPENRESTY_PREFIX/conf"
OPENRESTY_SITES_DIR="$OPENRESTY_PREFIX/conf/sites"        # 站点配置目录（include 到主配置）
ACME_SH_HOME="/root/.acme.sh"
CERT_DIR="/etc/ssl/clouddock"                              # acme.sh 签发后安装到的证书目录

# ---------- 颜色 ----------
C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_BLUE='\033[0;34m'; C_NC='\033[0m'

# ---------- 日志 ----------
log()  { echo -e "${C_BLUE}[INFO]${C_NC} $*"; }
ok()   { echo -e "${C_GREEN}[ OK ]${C_NC} $*"; }
warn() { echo -e "${C_YELLOW}[WARN]${C_NC} $*"; }
err()  { echo -e "${C_RED}[ERR ]${C_NC} $*" >&2; }
die()  { err "$*"; exit 1; }

# ---------- 校验 ----------
require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "请以 root 运行（或 sudo）。"
}

require_debian12() {
  [[ -f /etc/os-release ]] || die "无法识别操作系统。"
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == "debian" && "${VERSION_ID:-}" == "12" ]] \
    || die "仅支持 Debian 12，当前系统：${PRETTY_NAME:-未知}。"
}

# ---------- 工具判断 ----------
have() { command -v "$1" >/dev/null 2>&1; }

# ---------- .env 读写 ----------
# env 文件行格式：KEY=value（值不含空格/换行/特殊 shell 字符，域名与随机密钥均满足）
env_file_exists() { [[ -f "$ENV_FILE" ]]; }

env_get() {
  local key="$1"
  [[ -f "$ENV_FILE" ]] || return 1
  local val
  val="$(grep -E "^${key}=" "$ENV_FILE" | tail -n1 | cut -d= -f2-)"
  [[ -n "$val" ]] && printf '%s' "$val" || return 1
}

# 幂等写入：若 key 已存在则覆盖，否则追加
env_set() {
  local key="$1" val="$2"
  mkdir -p "$(dirname "$ENV_FILE")"
  if [[ -f "$ENV_FILE" ]] && grep -qE "^${key}=" "$ENV_FILE"; then
    # 用 sed 替换（值可能含 / 与 . ，用 | 作分隔符）
    sed -i "s|^${key}=.*|${key}=${val}|" "$ENV_FILE"
  else
    echo "${key}=${val}" >> "$ENV_FILE"
  fi
}

# 读取环境变量，带默认值
cfg() {
  local key="$1" default="${2:-}"
  local v
  v="$(env_get "$key" 2>/dev/null)" || v="$default"
  printf '%s' "$v"
}

# ---------- 随机密钥 ----------
rand_hex() { openssl rand -hex "${1:-16}"; }

# ---------- 幂等封装 ----------
# 若 step 函数此前已完成（由标记函数判断），跳过；否则执行并打印阶段标题
run_step() {
  local title="$1" check_fn="$2" fn="$3"
  log "===== 阶段：${title} ====="
  if "$check_fn"; then
    ok "已就绪，跳过：${title}"
    return 0
  fi
  "$fn"
}
