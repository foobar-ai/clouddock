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

# ---------- compose 聚合 ----------
# 构建所有服务的 compose -f 参数列表（与 05-services.sh / apply.sh 保持一致）
# 约定：本项目 compose 的 service 名与 container_name 一致。
compose_files() {
  COMPOSE_FILES=()
  local f
  for f in "$COMPOSE_DIR"/*/compose.yml; do
    [[ -f "$f" ]] && COMPOSE_FILES+=(-f "$f")
  done
  [[ "${#COMPOSE_FILES[@]}" -gt 0 ]] || die "未找到任何服务 compose 文件（${COMPOSE_DIR}）。"
}

# 服务是否已在本项目声明（按 container_name）
svc_known() {
  local s
  for s in $(svc_names); do
    [[ "$s" == "$1" ]] && return 0
  done
  return 1
}

# 要求合法且已声明的服务名
require_svc() {
  local s="${1:-}"
  [[ -n "$s" ]] || die "缺少服务名。"
  valid_svc_name "$s" || die "非法服务名：$s"
  svc_known "$s" || die "未声明的服务：$s（可用：$(svc_names | tr '\n' ' ')）"
}

# ---------- 精确重建单个服务 ----------
# 用同一组 compose 文件（保持 project 一致）只 up 目标服务，避免误动其他服务。
compose_up_svc() {
  local svc="$1"
  docker compose --env-file "$ENV_FILE" "${COMPOSE_FILES[@]}" up -d "$svc"
}
