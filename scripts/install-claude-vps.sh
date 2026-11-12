#!/usr/bin/env bash
# install-claude-vps.sh — 在 VPS 上安装 Claude Code（官方原生安装器）+ Happy CLI（手机遥控）
# 以专用 agent 用户运行，模型后端走本机 magpie 网关（127.0.0.1:3425）。
# 约束见 AGENTS.md：一律用官方/可信渠道的当前推荐（未过时）方式。
# 用法（在 VPS 以 root 执行）：bash /opt/clouddock/scripts/install-claude-vps.sh
# 可选环境变量（无交互）：
#   GH_TOKEN=github_pat_xxx               GitHub 细粒度 token（认证：能否 push）
#   GIT_USER_NAME / GIT_USER_EMAIL        git 提交身份（commit 作者）
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

# 2) Node 24 LTS（happy 的依赖 @slopus/happy-terminal 要求 node>=24；NodeSource 为可信渠道，Node 官方备选为 nodejs.org tarball）
NODE_MAJOR=24
if ! command -v node >/dev/null 2>&1 || [[ "$(node -v 2>/dev/null | tr -d 'v' | cut -d. -f1)" -lt "$NODE_MAJOR" ]]; then
  echo "[INFO] 安装 Node ${NODE_MAJOR} LTS ..."
  export DEBIAN_FRONTEND=noninteractive
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
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

# 5) 后端走本机 magpie + 可选 GitHub token：写 agent 的 ~/.claude/settings.json
GATEWAY_KEY="$(grep '^MAGPIE_GATEWAY_KEY=' "$CLOUDDOCK_DIR/deploy/.env" 2>/dev/null | cut -d= -f2- || true)"
[[ -n "$GATEWAY_KEY" ]] || echo "[WARN] 未找到 MAGPIE_GATEWAY_KEY，稍后请手动补写 settings.json" >&2

mkdir -p "$AGENT_HOME/.claude"
# 用 python3 构造 JSON，避免 token/密钥含特殊字符破坏 JSON；GH_TOKEN 可选
python3 - "$MAGPIE_URL" "$GATEWAY_KEY" "${GH_TOKEN:-}" > "$AGENT_HOME/.claude/settings.json" <<'PY'
import json, sys
base_url, gateway_key, gh_token = sys.argv[1], sys.argv[2], sys.argv[3]
env = {"ANTHROPIC_BASE_URL": base_url, "ANTHROPIC_API_KEY": gateway_key}
if gh_token:
    env["GH_TOKEN"] = gh_token
print(json.dumps({"env": env}, ensure_ascii=False, indent=2))
PY
chown -R "$AGENT_USER":"$AGENT_USER" "$AGENT_HOME/.claude"
chmod 600 "$AGENT_HOME/.claude/settings.json"
[[ -n "${GH_TOKEN:-}" ]] && echo "[OK] 已写入 GH_TOKEN 到 agent 的 Claude Code 配置"

# 6) git 提交身份（认证靠 GH_TOKEN，身份靠 name/email，两者缺一不可）
if [[ -n "${GIT_USER_NAME:-}" && -n "${GIT_USER_EMAIL:-}" ]]; then
  su - "$AGENT_USER" -c "git config --global user.name '${GIT_USER_NAME}'"
  su - "$AGENT_USER" -c "git config --global user.email '${GIT_USER_EMAIL}'"
  echo "[OK] 已设置 git 身份：${GIT_USER_NAME} <${GIT_USER_EMAIL}>"
else
  echo "[WARN] 未提供 GIT_USER_NAME/GIT_USER_EMAIL，agent 提交会缺 git 身份（可稍后：su - $AGENT_USER -c 'git config --global user.name 你的名字'）"
fi

# 确保各 shell 能找到 claude（原生安装器装到 ~/.local/bin；.profile=登录 shell，.bashrc=交互 shell）
for f in "$AGENT_HOME/.profile" "$AGENT_HOME/.bashrc"; do
  grep -q '\.local/bin' "$f" 2>/dev/null \
    || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$f"
done

echo ""
echo "======================================================"
echo " 安装完成。自检："
echo "   claude: $(su - "$AGENT_USER" -c 'test -x "$HOME/.local/bin/claude" && echo 已安装 || echo 未找到' 2>/dev/null || true)"
echo "   happy : $(command -v happy >/dev/null 2>&1 && echo 已安装 || echo 未找到)"
echo ""
echo " 后续两步（需你本人在 VPS 终端操作）："
echo " 1) 配对手机（终端出二维码，手机 Happy App 扫码）："
echo "      su - $AGENT_USER -c 'happy auth login'"
echo "    选择 Mobile App，扫码完成配对。"
echo " 2) 启动 Claude Code（手机即可接管）："
echo "      su - $AGENT_USER -c 'happy claude'"
echo "======================================================"
