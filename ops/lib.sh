#!/usr/bin/env bash
# ops/lib.sh — 运维公共库：复用 bootstrap/lib.sh 的常量与函数，补充 JSON 构造与敏感值过滤
# 约定：调用方需先 export DEPLOY_DIR（= /opt/clouddock），再 source 本文件。

# shellcheck source=../bootstrap/lib.sh
source "$DEPLOY_DIR/bootstrap/lib.sh"

# ---------- JSON 构造 ----------
# 用 python3（Debian 12 内置）生成合法 JSON，避免手拼引号出错。
json_str() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1], ensure_ascii=False), end="")' "$1"; }
json_int() { python3 -c 'import sys; print(int(sys.argv[1]), end="")' "$1"; }
json_num() { python3 -c 'import sys; print(float(sys.argv[1]), end="")' "$1"; }

# ---------- 敏感值过滤 ----------
# 从 deploy/.env 与 deploy/dnsapi.env 提取敏感值，替换 stdin 中的明文为 ***
# 注意：用 python3 -c（而非 heredoc），避免 stdin 被脚本源码占用导致读不到待过滤数据。
redact() {
  python3 -c '
import sys
secrets = []
for path in sys.argv[1:]:
    try:
        f = open(path, encoding="utf-8", errors="ignore")
    except OSError:
        continue
    with f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("export "):
                line = line[7:]
            if "=" in line:
                v = line.partition("=")[2].strip().strip("\"").strip(chr(39))
                if len(v) >= 8:
                    secrets.append(v)
data = sys.stdin.read()
for s in sorted(set(secrets), key=len, reverse=True):
    if s:
        data = data.replace(s, "***")
sys.stdout.write(data)
' "$ENV_FILE" "${DEPLOY_DIR}/deploy/dnsapi.env"
}

# ---------- 服务名校验 ----------
# 合法服务名：^[a-z0-9][a-z0-9-]{0,31}$
valid_svc_name() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]]
}
