#!/usr/bin/env bash
# install-claude-vps.sh — 在 VPS 上安装 Claude Code（官方原生安装器）+ Happy CLI（手机遥控）
# 以专用 agent 用户运行，模型后端走本机 magpie 网关（127.0.0.1:3425）。
# 约束见 AGENTS.md：一律用官方/可信渠道的当前推荐（未过时）方式。
# 用法（在 VPS 以 root 执行）：bash /opt/clouddock/scripts/install-claude-vps.sh
set -euo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "[ERR] 请以 root 运行：sudo -i" >&2; exit 1; }

AGENT_USER="agent"
AGENT_HOME="/home/$AGENT_USER"
CLOUDDOCK_DIR="/opt/clouddock"
MAGPIE_URL="http://127.0.0.1:3425"

# 1) 专用用户（幂等）
if ! id "$AGENT_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$AGENT_USER"
  echo "[OK] 已创建用户 $AGENT_USER"
else
  echo "[OK] 用户 $AGENT_USER 已存在"
fi

# 2) Node 22 LTS（Happy CLI 需 Node 20+；NodeSource 为可信渠道，Node 官方备选为 nodejs.org tarball）
if ! command -v node >/dev/null 2>&1 || [[ "$(node -v 2>/dev/null | tr -d 'v' | cut -d. -f1)" -lt 20 ]]; then
  echo "[INFO] 安装 Node 22 LTS ..."
  export DEBIAN_FRONTEND=noninteractive
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y nodejs
else
  echo "[OK] Node 已满足（$(node -v)）"
fi

# 3) Happy CLI（npm 官方包，当前名 happy）
echo "[INFO] 安装 Happy CLI ..."
npm install -g happy

# 4) Claude Code（官方原生安装器，未过时方式；装到 agent 用户 ~/.local）
echo "[INFO] 以 $AGENT_USER 安装 Claude Code（原生安装器）..."
su - "$AGENT_USER" -c 'curl -fsSL https://claude.ai/install.sh | bash'

# 5) 后端走本机 magpie：写 agent 的 ~/.claude/settings.json
GATEWAY_KEY="$(grep '^MAGPIE_GATEWAY_KEY=' "$CLOUDDOCK_DIR/deploy/.env" 2>/dev/null | cut -d= -f2- || true)"
[[ -n "$GATEWAY_KEY" ]] || echo "[WARN] 未找到 MAGPIE_GATEWAY_KEY，稍后请手动补写 settings.json" >&2

mkdir -p "$AGENT_HOME/.claude"
cat > "$AGENT_HOME/.claude/settings.json" <<EOF
{
  "env": {
    "ANTHROPIC_BASE_URL": "$MAGPIE_URL",
    "ANTHROPIC_API_KEY": "$GATEWAY_KEY"
  }
}
EOF
chown -R "$AGENT_USER":"$AGENT_USER" "$AGENT_HOME/.claude"
chmod 600 "$AGENT_HOME/.claude/settings.json"

# 确保登录 shell 能找到 claude（原生安装器装到 ~/.local/bin）
grep -q '\.local/bin' "$AGENT_HOME/.profile" 2>/dev/null \
  || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$AGENT_HOME/.profile"

echo ""
echo "======================================================"
echo " 安装完成。自检："
echo "   claude: $(su - "$AGENT_USER" -c 'test -x "$HOME/.local/bin/claude" && echo 已安装 || echo 未找到' 2>/dev/null || true)"
echo "   happy : $(happy --version 2>/dev/null || echo 未知)"
echo ""
echo " 后续两步（需你本人在 VPS 终端操作）："
echo " 1) 配对手机（终端出二维码，手机 Happy App 扫码）："
echo "      su - $AGENT_USER -c 'happy auth login'"
echo "    选择 Mobile App，扫码完成配对。"
echo " 2) 启动 Claude Code（手机即可接管）："
echo "      su - $AGENT_USER -c 'happy claude'"
echo "======================================================"
