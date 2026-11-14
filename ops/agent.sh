#!/usr/bin/env bash
# ops/agent.sh — agent 用户的 GitHub 访问诊断与 PAT 接入（只读诊断 + 凭证助手配置）
# 用法:
#   clouddock agent git [--check-push]   SSH 资产/认证/git 身份/仓库 remote；--check-push 走 push --dry-run
#   clouddock agent git-setup            安装 credential helper + git@github.com: → https 重写
#   clouddock agent clone <owner/repo>   以 agent 身份 clone 到 ~agent/projects/<repo>
#   clouddock agent gh-token set         （stdin 传 token）更新 settings.json 的 GH_TOKEN
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
source "$SCRIPT_DIR/lib.sh"

require_root

AGENT_USER="agent"
AGENT_HOME="/home/${AGENT_USER}"
SETTINGS="$AGENT_HOME/.claude/settings.json"
HELPER_SRC="$DEPLOY_DIR/scripts/git-credential-clouddock.sh"
HELPER_DST="/usr/local/bin/git-credential-clouddock"

usage() {
  cat <<'EOF' >&2
用法: clouddock agent <子命令>
  agent git [--check-push]   GitHub 访问诊断（只读）
  agent git-setup            配置 git 走 PAT（credential helper + SSH URL 重写）
  agent clone <owner/repo>   clone 到 ~agent/projects/<repo>
  agent gh-token set         stdin 传入新 PAT，写入 ~agent/.claude/settings.json
EOF
  exit 2
}

# ---------- 诊断 ----------
agent_git() {
  local check_push=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --check-push) check_push=1; shift ;;
      *) die "未知参数：$1" ;;
    esac
  done

  python3 - "$AGENT_USER" "$AGENT_HOME" "$check_push" <<'PY'
import json, os, re, shlex, subprocess, sys

agent_user, agent_home, check_push = sys.argv[1], sys.argv[2], sys.argv[3] == "1"


def run(argv, timeout=30):
    try:
        return subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        class R:
            stdout = ""
            stderr = "timeout"
            returncode = 124
        return R()


def sh(cmd, user, timeout=30):
    """以指定用户执行固定命令串（命令串由本脚本构造，不含外部输入）。"""
    if user == "root":
        return run(["bash", "-c", cmd], timeout=timeout)
    return run(["su", "-", user, "-c", cmd], timeout=timeout)


def mask_url(u):
    return re.sub(r"//[^/@\s]+@", "//***@", u)


out = {"user": agent_user, "home": agent_home}

# ---- SSH 资产 ----
r = sh("ls -1 ~/.ssh 2>/dev/null || true", agent_user)
out["ssh_dir"] = [x for x in r.stdout.split() if x]
r = sh("for f in ~/.ssh/id_*; do [ -f \"$f\" ] || continue; stat -c '%a %n' \"$f\"; done 2>/dev/null || true", agent_user)
out["ssh_key_files"] = [l.strip().replace(agent_home, "~") for l in r.stdout.splitlines() if l.strip()]
r = sh("grep -q github.com ~/.ssh/known_hosts 2>/dev/null && echo yes || echo no", agent_user)
out["github_host_key_known"] = r.stdout.strip() == "yes"

# ---- SSH 认证（只读探测）----
r = sh("ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -T git@github.com 2>&1 | head -n2", agent_user, timeout=40)
txt = r.stdout.strip()
out["ssh_github"] = txt
out["ssh_github_ok"] = "successfully authenticated" in txt

# ---- git 身份 / 凭证 ----
r = sh("git config --global user.name 2>/dev/null; git config --global user.email 2>/dev/null", agent_user)
ident = [l.strip() for l in r.stdout.splitlines() if l.strip()]
out["git_identity"] = " | ".join(ident)
r = sh("git config --global credential.helper 2>/dev/null || true", agent_user)
out["credential_helper"] = r.stdout.strip()
r = sh("test -f ~/.git-credentials && echo yes || echo no", agent_user)
out["git_credentials_file"] = r.stdout.strip() == "yes"
r = sh("git config --global --get-regexp 'url\\..*\\.insteadof' 2>/dev/null || true", agent_user)
out["url_rewrites"] = [l.strip() for l in r.stdout.splitlines() if l.strip()]

# ---- Claude Code 配置里的 token（只看有无，不打印值）----
try:
    with open(os.path.join(agent_home, ".claude", "settings.json"), encoding="utf-8") as f:
        tok = json.load(f).get("env", {}).get("GH_TOKEN", "")
    out["gh_token_in_settings"] = bool(tok)
except Exception:
    out["gh_token_in_settings"] = False

# ---- 仓库扫描（agent 家目录 + root 家目录 + 部署仓库）----
repos = []
for owner, home in ((agent_user, agent_home), ("root", "/root")):
    r = sh("find %s -maxdepth 3 -type d -name .git 2>/dev/null | sed 's|/\\.git$||' | "
           "grep -v -E '/(\\.|node_modules)(/|$)' || true" % home, owner)
    paths = [p for p in r.stdout.splitlines() if p.strip()]
    if owner == "root":
        paths.append("/opt/clouddock")
    for p in sorted(set(paths)):
        q = shlex.quote(p)
        remote = sh("git -C %s remote -v 2>/dev/null | head -n1" % q, owner).stdout.strip()
        branch = sh("git -C %s rev-parse --abbrev-ref HEAD 2>/dev/null" % q, owner).stdout.strip()
        dirty = sh("git -C %s status --porcelain 2>/dev/null | wc -l" % q, owner).stdout.strip()
        item = {
            "owner": owner,
            "path": p,
            "remote": mask_url(remote),
            "branch": branch,
            "dirty_files": int(dirty) if dirty.isdigit() else None,
        }
        if check_push and remote:
            pr = sh("GIT_TERMINAL_PROMPT=0 timeout 40 git -C %s push --dry-run 2>&1 | tail -n3" % q,
                    owner, timeout=60)
            item["push_dry_run"] = pr.stdout.strip()
        repos.append(item)

out["repos"] = repos
print(json.dumps(out, ensure_ascii=False, indent=2))
PY
}

# ---------- PAT 接入 ----------
agent_git_setup() {
  [[ -f "$HELPER_SRC" ]] || die "缺少 $HELPER_SRC（clouddock upgrade 可补齐）。"
  install -m 0755 "$HELPER_SRC" "$HELPER_DST"

  su - "$AGENT_USER" -c "git config --global credential.helper '!${HELPER_DST}'" \
    || die "写入 credential.helper 失败"
  su - "$AGENT_USER" -c 'git config --global url."https://github.com/".insteadOf "git@github.com:"' \
    || die "写入 url rewrite 失败"

  [[ -f "$SETTINGS" ]] || warn "未找到 $SETTINGS：先 clouddock claude apply 生成配置（GH_TOKEN 从那里读）。"
  ok "已配置 credential.helper=!${HELPER_DST}（读 ~agent/.claude/settings.json 的 GH_TOKEN）"
  ok "已配置重写：git@github.com: → https://github.com/（SSH 写法也能走 PAT）"
  log "提醒：PAT 需把目标仓库加入 Repository access，权限 Contents: Read and write。"
}

agent_clone() {
  local spec="${1:-}" name dest out
  [[ "$spec" =~ ^[A-Za-z0-9_.-]{1,64}/[A-Za-z0-9_.-]{1,100}$ ]] \
    || die "用法: clouddock agent clone <owner/repo>"
  name="${spec#*/}"
  dest="$AGENT_HOME/projects/$name"
  [[ -d "$dest/.git" ]] && die "已存在：$dest"

  out="$(su - "$AGENT_USER" -c "mkdir -p ~/projects && GIT_TERMINAL_PROMPT=0 git clone -- https://github.com/${spec}.git ~/projects/${name}" 2>&1 || true)"
  if [[ ! -d "$dest/.git" ]]; then
    printf '%s\n' "$out" | tail -n3 >&2
    die "clone 失败：PAT 是否已把 ${spec} 加入 Repository access（Contents: Read）？"
  fi
  chown -R "$AGENT_USER":"$AGENT_USER" "$dest"
  ok "已 clone 到 $dest"
}

agent_gh_token_set() {
  [[ "${1:-}" == "--stdin" ]] || die "用法: clouddock agent gh-token set --stdin（token 走 stdin，不进命令行）"
  [[ -f "$SETTINGS" ]] || die "未找到 $SETTINGS（先 clouddock claude apply）。"

  local tok
  tok="$(cat)"
  tok="${tok//[[:space:]]/}"
  [[ "$tok" =~ ^[A-Za-z0-9_]{20,255}$ ]] || die "token 格式不合法（应形如 github_pat_xxx 或 ghp_xxx，20-255 位）"

  GH_TOKEN_NEW="$tok" python3 - "$SETTINGS" <<'PY'
import json, os, sys, tempfile

path = sys.argv[1]
tok = os.environ["GH_TOKEN_NEW"]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
data.setdefault("env", {})["GH_TOKEN"] = tok

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path))
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
os.replace(tmp, path)
PY
  chown "$AGENT_USER":"$AGENT_USER" "$SETTINGS"
  chmod 600 "$SETTINGS"
  ok "GH_TOKEN 已更新（$(printf '%s' "$tok" | cut -c1-11)…，重启 Claude Code 生效；git 助手即时可用）。"
}

cmd="${1:-}"
[[ -n "$cmd" ]] || usage
shift || true

case "$cmd" in
  git)        agent_git "$@" ;;
  git-setup)  agent_git_setup ;;
  clone)      agent_clone "${1:-}" ;;
  gh-token)
    [[ "${1:-}" == "set" ]] || usage
    shift || true
    agent_gh_token_set "${1:-}"
    ;;
  *)          usage ;;
esac
