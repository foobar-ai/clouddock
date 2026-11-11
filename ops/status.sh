#!/usr/bin/env bash
# ops/status.sh — 状态巡检，输出 JSON（容器/证书/流量/磁盘/git）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
source "$SCRIPT_DIR/lib.sh"

# 采集事实，经环境变量交给 python 生成 JSON
OPS_DOMAIN="$(cfg NEWAPI_DOMAIN '')"
OPS_QUOTA_GB="$(cfg TRAFFIC_QUOTA_GB '1024')"
OPS_GIT_BRANCH="$(git -C "$DEPLOY_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')"
OPS_GIT_COMMIT="$(git -C "$DEPLOY_DIR" rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
OPS_CERT_END=""
if [[ -f "$CERT_DIR/fullchain.cer" ]]; then
  OPS_CERT_END="$(openssl x509 -enddate -noout -in "$CERT_DIR/fullchain.cer" 2>/dev/null | sed 's/^notAfter=//' || true)"
fi
OPS_CONTAINERS="$(docker ps -a --format '{{.Names}}\t{{.State}}\t{{.Status}}' 2>/dev/null || true)"
OPS_VNSTAT="$(vnstat --json m 2>/dev/null || true)"
OPS_DISK="$(df -Pk / 2>/dev/null || true)"

export OPS_DOMAIN OPS_QUOTA_GB OPS_GIT_BRANCH OPS_GIT_COMMIT OPS_CERT_END OPS_CONTAINERS OPS_VNSTAT OPS_DISK

python3 <<'PY'
import os, json
from datetime import datetime, timezone

def env(k): return os.environ.get(k, '') or ''

domain = env('OPS_DOMAIN')
quota = float(env('OPS_QUOTA_GB') or 0)

git = {"branch": env('OPS_GIT_BRANCH') or 'unknown', "commit": env('OPS_GIT_COMMIT') or 'unknown'}

# cert
cert = {"domain": domain, "days_left": None, "expires": None, "ok": False}
end = env('OPS_CERT_END').strip()
if end:
    try:
        parts = end.split()
        if len(parts) >= 4:
            dt = datetime.strptime('%s %d %s %s' % (parts[0], int(parts[1]), parts[2], parts[3]), '%b %d %H:%M:%S %Y')
            days = (dt.replace(tzinfo=timezone.utc) - datetime.now(timezone.utc)).days
            cert["expires"] = dt.strftime('%Y-%m-%d')
            cert["days_left"] = days
            cert["ok"] = days >= 14
    except Exception:
        pass

# containers
containers = []
for line in env('OPS_CONTAINERS').splitlines():
    parts = line.split('\t')
    if len(parts) < 2:
        continue
    name, state = parts[0], parts[1]
    status = parts[2] if len(parts) > 2 else ''
    health = 'none'
    if '(healthy)' in status:
        health = 'healthy'
    elif '(unhealthy)' in status:
        health = 'unhealthy'
    containers.append({"name": name, "state": state, "health": health})

# traffic (vnstat --json m)
# vnstat 2.x JSON：interfaces[0].traffic.month（单数、数组、按时间升序）。
# 注意勿用 traffic.total.tx（网卡累计总量，非当月）。取 month 数组末位即当前月。
def parse_traffic(raw):
    try:
        d = json.loads(raw)
    except Exception:
        return None
    months = None
    for ifc in d.get('interfaces', []):
        tr = ifc.get('traffic', {})
        months = tr.get('month') or tr.get('months')  # 兼容单数/复数
        if months:
            break
    if not months:
        tr = d.get('traffic', {})
        months = tr.get('month') or tr.get('months')
    if not months:
        return None
    return months[-1].get('tx', 0)  # bytes，最后一项为当前月

tx_bytes = parse_traffic(env('OPS_VNSTAT'))
traffic = {"tx_gb": None, "quota_gb": quota, "pct": None}
if tx_bytes is not None:
    tx_gb = round(tx_bytes / 1024**3, 2)
    traffic["tx_gb"] = tx_gb
    traffic["pct"] = round(tx_gb / quota * 100, 1) if quota else None

# disk (df -Pk /)
disk = {"used_pct": None, "total_gb": None, "used_gb": None}
lines = env('OPS_DISK').splitlines()
if len(lines) >= 2:
    cols = lines[1].split()
    if len(cols) >= 5:
        try:
            disk = {
                "used_pct": int(cols[4].rstrip('%')),
                "total_gb": round(int(cols[1]) / 1024 / 1024, 1),
                "used_gb": round(int(cols[2]) / 1024 / 1024, 1),
            }
        except Exception:
            pass

out = {
    "ts": datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    "git": git,
    "cert": cert,
    "containers": containers,
    "traffic": traffic,
    "disk": disk,
}
print(json.dumps(out, ensure_ascii=False, indent=2))
PY
