#!/usr/bin/env bash
# ops/renew.sh — 续期证书（acme.sh --cron，到期才真正续，幂等）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
source "$SCRIPT_DIR/lib.sh"

require_root

[[ -x "$ACME_SH_HOME/acme.sh" ]] || die "未找到 acme.sh（$ACME_SH_HOME/acme.sh）。"
"$ACME_SH_HOME/acme.sh" --cron
ok "证书续期检查完成（acme.sh --cron）。"
