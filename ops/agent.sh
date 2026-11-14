#!/usr/bin/env bash
# ops/agent.sh — agent 用户的 GitHub 访问诊断（只读，不写入远端）
# 用法: clouddock agent git [--check-push]
#   agent git               看 SSH 资产/认证身份/git 身份/仓库 remote
#   agent git --check-push  额外对每个仓库做 git push --dry-run（不实际写入）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
source "$SCRIPT_DIR/lib.sh"

require_root

AGENT_USER="agent"
AGENT_HOME="/home/${AGENT_USER}"

usage() {
  echo "用法: clouddock agent git [--check-push]" >&2
  exit 2
}

agent_git() {
  local check_push=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --check-push) check_push=1; shift ;;
      *) die "未知参数：$1" ;;
    esac
  done

  python3 - "$AGENT_USER" "$AGENT_HOME" "$check_push" <<'PY'
import json, re, shlex, subprocess, sys

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

[[ "${1:-}" == "git" ]] || usage
shift
agent_git "$@"
