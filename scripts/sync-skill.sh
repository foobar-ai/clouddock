#!/usr/bin/env bash
# sync-skill.sh — 把仓库版 skill 同步到 CodeBuddy 本地 skill 目录（.codebuddy 已 gitignore）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="$REPO_DIR/skills/clouddock-ops"
DST="$REPO_DIR/.codebuddy/skills/clouddock-ops"

mkdir -p "$DST"
cp -f "$SRC/SKILL.md" "$DST/SKILL.md"
echo "已同步：$SRC/SKILL.md -> $DST/SKILL.md"
