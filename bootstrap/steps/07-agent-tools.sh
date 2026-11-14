#!/usr/bin/env bash
# 07-agent-tools.sh — 安装 agent 侧项目会话启动器 agent-session（选项目目录后启动 happy claude）
# 仅在已存在 agent 用户时生效（install-claude-vps.sh 创建）；未启用 agent 则跳过。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/../lib.sh"

require_root

AGENT_USER="agent"
AGENT_HOME="/home/${AGENT_USER}"
SRC="$DEPLOY_DIR/scripts/agent-session.sh"
DST="/usr/local/bin/agent-session"

agent_done() {
  # 未启用 agent：视为无需处理（不阻塞安装/升级）
  id "$AGENT_USER" >/dev/null 2>&1 || return 0
  [[ -x "$DST" ]] && cmp -s "$SRC" "$DST"
}

agent_run() {
  [[ -f "$SRC" ]] || die "未找到 $SRC（仓库不完整，请 git pull 后重试）。"
  install -m 0755 "$SRC" "$DST"
  mkdir -p "$AGENT_HOME/projects"
  chown "$AGENT_USER":"$AGENT_USER" "$AGENT_HOME/projects"
  ok "已安装项目启动器：$DST（候选目录 $AGENT_HOME/projects/*）"
}

run_step "安装 agent 项目启动器" agent_done agent_run
