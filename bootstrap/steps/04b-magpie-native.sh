#!/usr/bin/env bash
# 04b-magpie-native.sh — magpie 原生（Linux 终端版）安装 + 数据迁移 + systemd 常驻
#
# 为什么不用容器：官方 Docker 镜像是 gateway-only（#5776/#1540）。容器里没有可编排的
# agent，Library 的 MCP server 无法下发给宿主 agent；命令型 MCP 还依赖容器内运行时。
# 原生安装以 agent 用户运行，可直接读写 /home/agent 下的 agent 配置（Agents 页能力），
# 并用宿主 node/uvx 跑命令型 MCP server。
#
# 幂等：已装则跳过安装；目标配置已存在则不覆盖迁移；systemd 已 active 则只做健康检查。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/../lib.sh"

require_root

AGENT_USER="agent"
AGENT_HOME="/home/agent"
BIN="$AGENT_HOME/.local/bin/magpie"
SRC_CFG="$DATA_DIR/magpie/magpie"          # 旧容器卷（/config/magpie）
DST_CFG="$AGENT_HOME/.config/magpie"       # 原生配置目录
ENV_FILE_MAGPIE="$DEPLOY_DIR/deploy/magpie.env"
UNIT="/etc/systemd/system/magpie.service"

gateway_ok() {
  [[ -x "$BIN" ]] || return 1
  # 命令型 MCP server（uvx/npx）依赖宿主运行时，缺任一项都视为未就绪
  command -v node >/dev/null 2>&1 || return 1
  command -v uvx >/dev/null 2>&1 || return 1
  systemctl is-active --quiet magpie || return 1
  # 网关必须同时监听 0.0.0.0:3425（供 new-api 等容器经 host.docker.internal 访问）
  ss -lntH 2>/dev/null | grep -q '0\.0\.0\.0:3425' || return 1
  curl -s -o /dev/null -m 5 http://127.0.0.1:3425/v1/models 2>/dev/null
}

# 原生 magpie 跑在宿主上，Library 里 npx/uvx 型 MCP server 用宿主运行时
ensure_runtimes() {
  command -v node >/dev/null 2>&1 \
    || die "宿主缺 node（scripts/install-claude-vps.sh 会装 Node 24；或用 apt 装 nodejs）"
  if command -v uvx >/dev/null 2>&1; then
    ok "uv/uvx 已就绪（$(uv --version 2>/dev/null | head -n1)）"
    return 0
  fi
  log "安装 uv（PyPI 官方包，提供 uv/uvx）..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y --no-install-recommends python3-pip >/dev/null
  pip3 install --no-cache-dir --break-system-packages uv >/dev/null
  command -v uvx >/dev/null 2>&1 || die "uv 安装后仍未找到 uvx"
  ok "uv/uvx 安装完成（$(uv --version 2>/dev/null | head -n1)）"
}

native_run() {
  local key pub
  key="$(env_get MAGPIE_WEB_KEY 2>/dev/null || true)"
  pub="$(env_get MAGPIE_PUBLIC_URL 2>/dev/null || true)"

  # 0) 宿主运行时（npx / uvx 型 MCP server 依赖）
  ensure_runtimes

  # 1) 先备份并下线旧容器（释放 3425/3430，且避免迁移时的并发写）
  if docker ps -a --format '{{.Names}}' | grep -qx magpie; then
    log "备份旧容器配置并下线容器 ..."
    if [[ -d "$SRC_CFG" ]]; then
      local bak="$DATA_DIR/magpie-backup-$(date +%Y%m%d%H%M%S)"
      cp -a "$SRC_CFG" "$bak"
      ok "已备份到 $bak"
    fi
    docker rm -f magpie >/dev/null 2>&1 || true
    ok "旧容器已移除（compose 不再管理 magpie）"
  fi

  # 2) 安装原生 magpie（官方脚本，终端版：TUI + web + CLI）
  if [[ -x "$BIN" ]]; then
    ok "magpie 已安装：$("$BIN" version 2>/dev/null | head -n1 || echo "$BIN")"
  else
    log "以 agent 用户安装 magpie（官方安装脚本，--tui 终端版）..."
    su - "$AGENT_USER" -c 'curl -fsSL https://usemagpie.ai/install.sh | sh -s -- --tui' \
      || die "magpie 安装失败（检查出网与官方脚本）"
    [[ -x "$BIN" ]] || die "安装后未找到 $BIN"
    ok "magpie 安装完成：$("$BIN" version 2>/dev/null | head -n1 || echo "$BIN")"
  fi

  # 3) 迁移旧容器卷里的配置（providers / gateway keys / 用量），只在目标未初始化时做
  if [[ -d "$SRC_CFG" && ! -e "$DST_CFG/settings.json" ]]; then
    log "迁移配置：$SRC_CFG → $DST_CFG"
    mkdir -p "$DST_CFG"
    cp -a "$SRC_CFG"/. "$DST_CFG"/
    chown -R "$AGENT_USER":"$AGENT_USER" "$DST_CFG"
    ok "配置已迁移（$(find "$DST_CFG" -maxdepth 1 -type f | wc -l) 个顶层文件）"
  else
    log "跳过配置迁移（目标已初始化或无旧配置）"
  fi
  chown -R "$AGENT_USER":"$AGENT_USER" "$AGENT_HOME/.config" 2>/dev/null || true

  # 4) 生成 magpie 专用环境文件（600，含 Web UI 密钥，不写进 unit）
  mkdir -p "$(dirname "$ENV_FILE_MAGPIE")"
  ( umask 077
    {
      echo "HOME=$AGENT_HOME"
      echo "TZ=Asia/Shanghai"
      [[ -n "$key" ]] && echo "MAGPIE_WEB_KEY=$key"
      [[ -n "$pub" ]] && echo "MAGPIE_PUBLIC_URL=$pub"
    } > "$ENV_FILE_MAGPIE"
  )
  chmod 600 "$ENV_FILE_MAGPIE"

  # 5) systemd 常驻（系统级 unit，User=agent：可见 /home/agent 下的 agent 配置）
  cat > "$UNIT" <<EOF
[Unit]
Description=magpie gateway (native, agent user)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$AGENT_USER
Group=$AGENT_USER
WorkingDirectory=$AGENT_HOME
EnvironmentFile=$ENV_FILE_MAGPIE
# --lan：把网关共享到本机网卡（0.0.0.0:3425），供 new-api 等容器经 host.docker.internal 访问；
# UI 仍只绑回环。云安全组只放行 22/80/443，3425 不对公网开放，且请求仍需 gateway key。
ExecStart=$BIN web --addr 127.0.0.1:3430 --lan --no-open
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$UNIT"
  systemctl daemon-reload
  systemctl enable magpie
  # unit 内容可能变化（如监听地址）：enable --now 对已运行服务不重启，必须 restart
  systemctl restart magpie
  ok "systemd 已启用：magpie.service（User=$AGENT_USER，0.0.0.0:3425 网关 / 127.0.0.1:3430 UI）"

  # 6) 等就绪：必须同时在 0.0.0.0:3425 监听（供容器经 host.docker.internal 访问）
  local i
  for i in $(seq 1 30); do
    if curl -s -o /dev/null -m 3 http://127.0.0.1:3425/v1/models 2>/dev/null; then
      if ss -lntH 2>/dev/null | grep -q '0\.0\.0\.0:3425'; then
        ok "网关就绪：0.0.0.0:3425（宿主回环与容器网桥均可访问）"
      else
        warn "网关仅监听 127.0.0.1:3425 —— 容器（new-api）无法访问；需确认 magpie 的监听参数"
      fi
      return 0
    fi
    sleep 1
  done
  die "magpie 30s 内未响应 3425（journalctl -u magpie -n 50 查看）"
}

run_step "magpie 原生安装与常驻" gateway_ok native_run
