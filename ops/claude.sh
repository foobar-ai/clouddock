#!/usr/bin/env bash
# ops/claude.sh — 查看/修改 VPS 上 agent 用户的 Claude Code 配置（网关与模型）
# 用法: clouddock claude [show | set-model <model>]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
source "$SCRIPT_DIR/lib.sh"

require_root

AGENT_USER="agent"
SETTINGS="/home/${AGENT_USER}/.claude/settings.json"

usage() {
  echo "用法: clouddock claude [show | set-model <model>]" >&2
  exit 2
}

show() {
  [[ -f "$SETTINGS" ]] || die "未找到 $SETTINGS（先运行 scripts/install-claude-vps.sh）。"
  python3 - "$SETTINGS" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    d = json.load(f)
env = d.get("env", {})
def mask(v):
    if not v:
        return ""
    return "***" if len(v) <= 8 else v[:4] + "***" + v[-4:]
print(json.dumps({
    "file": sys.argv[1],
    "base_url": env.get("ANTHROPIC_BASE_URL", ""),
    "model": env.get("ANTHROPIC_MODEL", "(默认)"),
    "api_key": mask(env.get("ANTHROPIC_API_KEY", "")),
}, ensure_ascii=False, indent=2))
PY
}

set_model() {
  local model="${1:-}"
  [[ -n "$model" ]] || die "用法: clouddock claude set-model <model>"
  [[ "$model" =~ ^[A-Za-z0-9._/-]{1,128}$ ]] || die "非法模型名：$model"
  [[ -f "$SETTINGS" ]] || die "未找到 $SETTINGS（先运行 scripts/install-claude-vps.sh）。"
  python3 - "$SETTINGS" "$model" <<'PY'
import json, os, sys, tempfile

path, model = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
data.setdefault("env", {})["ANTHROPIC_MODEL"] = model

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path))
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
os.replace(tmp, path)
PY
  chown "$AGENT_USER":"$AGENT_USER" "$SETTINGS"
  chmod 600 "$SETTINGS"
  ok "已设置 ANTHROPIC_MODEL=$model（重启 Claude Code 后生效）。"
}

action="${1:-show}"
case "$action" in
  show)      show ;;
  set-model) shift || true; set_model "${1:-}" ;;
  *)         usage ;;
esac
