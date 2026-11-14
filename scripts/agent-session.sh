#!/usr/bin/env bash
# agent-session.sh — 选择项目目录后启动 happy claude（在 VPS 上以 agent 用户运行）
# 用法:
#   agent-session                 交互选择项目目录（上次选择会置顶）
#   agent-session <名字|路径>     直达：匹配 ~/projects/<名字>、~/<名字> 或任意有效路径
#   agent-session --list          列出候选目录（纯文本，便于脚本/AI 调用）
# 候选来源：~/projects/* 优先，其次 ~ 下最多 3 层内的 git 仓库（跳过隐藏目录与 node_modules）。
set -euo pipefail

AGENT_HOME="${AGENT_HOME:-$HOME}"
PROJECTS_DIR="${PROJECTS_DIR:-$AGENT_HOME/projects}"
STATE_FILE="$AGENT_HOME/.agent-session-last"
MAX_DEPTH=3

err() { printf '[ERR ] %s\n' "$*" >&2; }

usage() {
  cat <<'EOF'
用法: agent-session [项目名|路径 | --list]

  无参数       交互选择项目目录后启动 happy claude
  项目名/路径  直接进入并启动
  --list       列出候选项目目录
EOF
}

# 候选目录（去重，上次使用过的置顶）
list_candidates() {
  local d last out=""
  if [[ -d "$PROJECTS_DIR" ]]; then
    for d in "$PROJECTS_DIR"/*/; do
      [[ -d "$d" ]] && printf '%s\n' "${d%/}"
    done
  fi
  find "$AGENT_HOME" -maxdepth "$MAX_DEPTH" -type d -name .git 2>/dev/null \
    | sed 's|/\.git$||' \
    | grep -v -E '/(\.|node_modules)(/|$)' || true
}

ordered_candidates() {
  local last
  last="$( [[ -f "$STATE_FILE" ]] && head -n1 "$STATE_FILE" || true )"
  {
    [[ -n "$last" && -d "$last" ]] && printf '%s\n' "$last"
    list_candidates | awk '!seen[$0]++'
  } | awk '!seen[$0]++'
}

pretty() { printf '%s' "${1/#$AGENT_HOME/~}"; }

resolve_arg() {
  local a="$1" hit
  if [[ -d "$a" ]]; then (cd "$a" && pwd); return 0; fi
  if [[ -d "$PROJECTS_DIR/$a" ]]; then (cd "$PROJECTS_DIR/$a" && pwd); return 0; fi
  if [[ -d "$AGENT_HOME/$a" ]]; then (cd "$AGENT_HOME/$a" && pwd); return 0; fi
  # 按目录名在候选里匹配（如 misc/gamma 可用 gamma 直达）
  hit="$(ordered_candidates | awk -v n="$a" -F/ '$NF == n { print; exit }')"
  if [[ -n "$hit" && -d "$hit" ]]; then printf '%s' "$hit"; return 0; fi
  return 1
}

start_in() {
  local dir
  dir="$(cd "$1" && pwd)"
  printf '%s\n' "$dir" > "$STATE_FILE" 2>/dev/null || true
  if [[ "${AGENT_SESSION_NO_EXEC:-0}" == "1" ]]; then
    printf '[DRY] cd %s && happy claude\n' "$dir"
    return 0
  fi
  command -v happy >/dev/null 2>&1 || { err "未找到 happy（先执行 su - \$USER -c 'happy auth login'）"; exit 1; }
  printf '[INFO] 进入 %s，启动 Claude Code（手机 Happy App 接管）...\n' "$(pretty "$dir")"
  cd "$dir"
  exec happy claude
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --list)    ordered_candidates; exit 0 ;;
esac

if [[ $# -ge 1 ]]; then
  target="$(resolve_arg "$1")" || {
    err "找不到项目目录：$1（可用候选见 agent-session --list）"
    exit 1
  }
  start_in "$target"
  exit 0
fi

[[ -t 0 ]] || { err "非交互环境：请用 agent-session <项目名|路径>"; exit 1; }

list_text="$(ordered_candidates)"
last="$( [[ -f "$STATE_FILE" ]] && head -n1 "$STATE_FILE" || true )"
count=0
[[ -n "$list_text" ]] && count="$(printf '%s\n' "$list_text" | wc -l | tr -d ' ')"

while :; do
  echo
  echo "== 选择项目目录 =="
  if [[ "$count" -gt 0 ]]; then
    i=0
    while IFS= read -r d; do
      i=$((i + 1))
      marker=""
      [[ "$d" == "$last" ]] && marker="  ← 上次"
      printf '  %2d) %s%s\n' "$i" "$(pretty "$d")" "$marker"
    done <<< "$list_text"
  else
    echo "  （暂无项目；把仓库 git clone 到 ~/projects 后重跑即可）"
  fi
  printf '   0) ~ （家目录）\n'
  printf '   m) 手动输入路径\n'
  printf '   q) 退出\n'
  printf '编号: '
  read -r ans || exit 0

  case "$ans" in
    ""|q|Q) exit 0 ;;
    0)      start_in "$AGENT_HOME"; exit 0 ;;
    m|M)
      printf '路径: '
      read -r p || exit 0
      if target="$(resolve_arg "$p")"; then
        start_in "$target"; exit 0
      fi
      err "路径无效：$p"
      ;;
    *[!0-9]*) continue ;;
    *)
      if [[ "$ans" -ge 1 && "$ans" -le "$count" ]]; then
        start_in "$(printf '%s\n' "$list_text" | sed -n "${ans}p")"; exit 0
      fi
      err "编号超出范围：$ans"
      ;;
  esac
done
