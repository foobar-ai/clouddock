#!/usr/bin/env bash
# ops/services.sh — 服务清单：声明的服务 + 容器实况（JSON，只读）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
source "$SCRIPT_DIR/lib.sh"

OPS_DECLARED="$(svc_names | tr '\n' ' ')"
OPS_PS="$(docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.State}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || true)"
export OPS_DECLARED OPS_PS

python3 <<'PY'
import os, json

declared = os.environ.get("OPS_DECLARED", "").split()
rows = {}
for line in os.environ.get("OPS_PS", "").splitlines():
    parts = line.split("\t")
    if len(parts) < 5:
        continue
    name, image, state, status, ports = parts[:5]
    rows[name] = {"image": image, "state": state, "status": status, "ports": ports}

out = []
for name in declared:
    r = rows.get(name, {})
    out.append({
        "service": name,
        "container": name,
        "state": r.get("state", "absent"),
        "image": r.get("image", ""),
        "ports": r.get("ports", ""),
        "status": r.get("status", ""),
    })

print(json.dumps({"services": out}, ensure_ascii=False, indent=2))
PY
