#!/usr/bin/env bash
# ops/claude.sh — 管理 VPS 上 agent 用户的 Claude Code 配置（模板化：claude/settings.template.json）
# 用法: clouddock claude [show | apply [--model <m>] | set-model <m> | doctor]
#   show            查看当前生效的模型矩阵与网关（密钥打码）
#   apply           用仓库模板渲染并写入 settings.json（保留 GH_TOKEN / 网关 key / 用户自定义 env）
#   set-model <m>   仅把所有模型位点改成 <m>，不动其他配置
#   doctor          环境自检（claude/happy/tmux/settings 合法性/网关连通）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
source "$SCRIPT_DIR/lib.sh"

require_root

AGENT_USER="agent"
AGENT_HOME="/home/${AGENT_USER}"
SETTINGS="$AGENT_HOME/.claude/settings.json"
TEMPLATE="$DEPLOY_DIR/claude/settings.template.json"
MAGPIE_URL="${CLAUDE_BASE_URL:-http://127.0.0.1:3425}"
DEFAULT_MODEL="${CLAUDE_MODEL:-group/free[1m]}"

usage() {
  echo "用法: clouddock claude [show | apply [--model <model>] | set-model <model> | doctor]" >&2
  exit 2
}

# 模型名：允许 group/xxx、[1m] 后缀等非空白字符（不进 shell 求值，安全）
valid_model() { [[ "${1:-}" =~ ^[^[:space:]]{1,128}$ ]]; }

write_settings() {
  # 原子替换 + 归位权限（密钥文件 600、属主 agent）
  chown "$AGENT_USER":"$AGENT_USER" "$SETTINGS"
  chmod 600 "$SETTINGS"
}

require_settings() {
  [[ -f "$SETTINGS" ]] || die "未找到 $SETTINGS（先跑 scripts/install-claude-vps.sh 或 clouddock claude apply）。"
}

show() {
  require_settings
  python3 - "$SETTINGS" <<'PY'
import json, sys

with open(sys.argv[1], encoding="utf-8") as f:
    d = json.load(f)
env = d.get("env", {})


def mask(v):
    if not v:
        return ""
    return "***" if len(v) <= 8 else v[:4] + "***" + v[-4:]


picker = []
for opt in (d.get("modelPicker") or {}).get("options", []) or []:
    if isinstance(opt, dict):
        picker.append({"label": opt.get("label", ""), "model": opt.get("model", "")})

print(json.dumps({
    "file": sys.argv[1],
    "base_url": env.get("ANTHROPIC_BASE_URL", ""),
    "model": d.get("model", env.get("ANTHROPIC_MODEL", "(默认)")),
    "models": {
        "small_fast": env.get("ANTHROPIC_SMALL_FAST_MODEL", ""),
        "haiku": env.get("ANTHROPIC_DEFAULT_HAIKU_MODEL", ""),
        "sonnet": env.get("ANTHROPIC_DEFAULT_SONNET_MODEL", ""),
        "opus": env.get("ANTHROPIC_DEFAULT_OPUS_MODEL", ""),
        "teammate": (d.get("agentSettings") or {}).get("teammateModel", ""),
    },
    "model_picker": picker,
    "effort": d.get("effortLevel", ""),
    "api_key": mask(env.get("ANTHROPIC_API_KEY", "") or env.get("ANTHROPIC_AUTH_TOKEN", "")),
    "gh_token": "已配置" if env.get("GH_TOKEN") else "",
}, ensure_ascii=False, indent=2))
PY
}

# 以模板为准渲染 settings.json：模板为唯一真源，敏感项跨次保留
apply_template() {
  local model="${1:-$DEFAULT_MODEL}"
  valid_model "$model" || die "非法模型名：$model"
  [[ -f "$TEMPLATE" ]] || die "未找到模板：$TEMPLATE（clouddock upgrade 可补齐）。"

  local gw_key=""
  gw_key="$(env_get MAGPIE_GATEWAY_KEY 2>/dev/null || true)"

  mkdir -p "$(dirname "$SETTINGS")"
  python3 - "$TEMPLATE" "$SETTINGS" "$model" "$MAGPIE_URL" "$gw_key" "${GH_TOKEN:-}" <<'PY'
import json, os, pathlib, re, sys, tempfile

tpl_path, out_path, model, base_url, gw_key, gh_token = sys.argv[1:7]
raw = pathlib.Path(tpl_path).read_text(encoding="utf-8")
base_model = re.sub(r"\[[^]]*\]$", "", model)

prev = {}
p = pathlib.Path(out_path)
if p.exists():
    try:
        prev = json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        prev = {}
prev_env = prev.get("env", {}) if isinstance(prev, dict) else {}

# 敏感/环境相关项跨 apply 保留（模板里不放密钥）
key = gw_key or prev_env.get("ANTHROPIC_API_KEY", "") or prev_env.get("ANTHROPIC_AUTH_TOKEN", "")
gh = gh_token or prev_env.get("GH_TOKEN", "")

raw = (raw.replace("__MODEL_BASE__", base_model)
          .replace("__MODEL__", model)
          .replace("__BASE_URL__", base_url)
          .replace("__GATEWAY_KEY__", key))
data = json.loads(raw)

env = data.setdefault("env", {})
if not key:
    env.pop("ANTHROPIC_API_KEY", None)   # 空值会让 Claude Code 报鉴权错；回环网关可无 key
if gh:
    env["GH_TOKEN"] = gh

# 模板外、用户自行追加的 env 项保留；已知会与模型矩阵冲突的遗留键丢弃
DROP = {"ANTHROPIC_MODEL", "ANTHROPIC_AUTH_TOKEN"}
for k, v in prev_env.items():
    if k in env or k in DROP:
        continue
    env[k] = v

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(out_path))
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
os.replace(tmp, out_path)
PY

  write_settings
  ok "已按模板渲染 $SETTINGS（model=$model，base_url=$MAGPIE_URL）。重启 Claude Code 生效。"
}

set_model() {
  local model="${1:-}"
  valid_model "$model" || die "用法: clouddock claude set-model <model>"
  require_settings

  python3 - "$SETTINGS" "$model" <<'PY'
import json, os, re, sys, tempfile

path, model = sys.argv[1], sys.argv[2]
base = re.sub(r"\[[^]]*\]$", "", model)

with open(path, encoding="utf-8") as f:
    data = json.load(f)

data["model"] = model

mp = data.get("modelPicker")
if isinstance(mp, dict) and isinstance(mp.get("options"), list):
    for opt in mp["options"]:
        if isinstance(opt, dict) and "model" in opt:
            opt["model"] = model

env = data.setdefault("env", {})
for slot in ("ANTHROPIC_SMALL_FAST_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL",
             "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL"):
    env[slot] = model
if "ANTHROPIC_MODEL" in env:      # 旧配置遗留位点：只改不新增，避免覆盖 picker 选择
    env["ANTHROPIC_MODEL"] = model
if "CLAUDE_CODE_MODEL_CAPABILITIES" in env:
    env["CLAUDE_CODE_MODEL_CAPABILITIES"] = f"{base}=effort"

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path))
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
os.replace(tmp, path)
PY

  write_settings
  ok "已把所有模型位点设为 $model（重启 Claude Code 后生效）。"
}

doctor() {
  python3 - "$AGENT_HOME" "$SETTINGS" "$MAGPIE_URL" <<'PY'
import json, os, shutil, subprocess, sys

agent_home, settings, url = sys.argv[1:4]
checks = {
    "claude": os.access(os.path.join(agent_home, ".local/bin/claude"), os.X_OK),
    "happy": shutil.which("happy") is not None,
    "tmux": shutil.which("tmux") is not None,
    "agent_session": shutil.which("agent-session") is not None,
}


def find_projects(home):
    out = []
    pdir = os.path.join(home, "projects")
    if os.path.isdir(pdir):
        for n in sorted(os.listdir(pdir)):
            p = os.path.join(pdir, n)
            if os.path.isdir(p):
                out.append(p)
    for root, dirs, _files in os.walk(home):
        depth = root[len(home):].count(os.sep)
        if root != home and os.path.isdir(os.path.join(root, ".git")):
            out.append(root)
        if depth >= 3:
            dirs[:] = []
        else:
            dirs[:] = [d for d in dirs if not d.startswith(".") and d != "node_modules"]
    return sorted(set(out))


checks["agent_projects"] = find_projects(agent_home)

try:
    with open(settings, encoding="utf-8") as f:
        json.load(f)
    checks["settings_json"] = True
except Exception:
    checks["settings_json"] = False

try:
    checks["magpie_gateway_http"] = subprocess.run(
        ["curl", "-s", "-o", "/dev/null", "-m", "3", "-w", "%{http_code}", url],
        capture_output=True, text=True).stdout.strip() or "n/a"
except Exception:
    checks["magpie_gateway_http"] = "n/a"

checks["ok"] = all([checks["claude"], checks["happy"], checks["settings_json"],
                    checks["magpie_gateway_http"] not in ("000", "n/a", "")])
if not checks["tmux"]:
    checks["note_tmux"] = "未装 tmux：teammateMode=tmux 不可用，执行 clouddock tools ensure tmux"
print(json.dumps(checks, ensure_ascii=False, indent=2))
PY
}

action="${1:-show}"
case "$action" in
  show)      show ;;
  doctor)    doctor ;;
  apply)
    shift || true
    model="$DEFAULT_MODEL"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --model) [[ $# -ge 2 ]] || die "--model 缺少值"; model="$2"; shift 2 ;;
        *) die "未知参数：$1" ;;
      esac
    done
    apply_template "$model"
    ;;
  set-model) shift || true; set_model "${1:-}" ;;
  *)         usage ;;
esac
