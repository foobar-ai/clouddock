#!/usr/bin/env bash
# git-credential-clouddock.sh — git 凭证助手：从 agent 的 Claude Code 配置里取 GH_TOKEN
# 安装为 /usr/local/bin/git-credential-clouddock，由
#   git config --global credential.helper '!/usr/local/bin/git-credential-clouddock'
# 调用。token 唯一真源 = ~agent/.claude/settings.json 的 env.GH_TOKEN，不复制第二份。
set -euo pipefail

# git 传 get/store/erase；只处理 get，其余静默成功
[[ "${1:-get}" == "get" ]] || exit 0

host=""
while IFS= read -r line; do
  if [[ -z "$line" ]]; then
    break
  fi
  case "$line" in
    host=*) host="${line#host=}" ;;
  esac
done

# 只对 github.com 供凭证，其他主机一律不返回
[[ "$host" == "github.com" ]] || exit 0

token="$(python3 - <<'PY'
import json, os, sys
path = os.path.expanduser("~/.claude/settings.json")
try:
    with open(path, encoding="utf-8") as f:
        tok = json.load(f).get("env", {}).get("GH_TOKEN", "")
except Exception:
    tok = ""
sys.stdout.write(tok)
PY
)"

if [[ -z "$token" ]]; then
  echo "git-credential-clouddock: 未找到 GH_TOKEN（执行 clouddock agent gh-token set 写入）" >&2
  exit 1
fi

# 细粒度 PAT / classic PAT 均可：用户名用约定的 x-access-token
printf 'username=x-access-token\npassword=%s\n' "$token"
