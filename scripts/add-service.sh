#!/usr/bin/env bash
# add-service.sh — 本地脚手架：生成 services/<name>/compose.yml 与 deploy.sh 模板
# 用法：bash scripts/add-service.sh <name> [--port <端口>]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

name="${1:-}"
[[ -n "$name" ]] || { echo "用法: bash scripts/add-service.sh <name> [--port <端口>]" >&2; exit 2; }
[[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { echo "非法服务名：$name（仅小写字母/数字/连字符）" >&2; exit 2; }

port="8080"
shift || true
if [[ $# -gt 0 ]]; then
  case "$1" in
    --port) [[ -n "${2:-}" ]] && port="$2" ;;
    --port=*) port="${1#--port=}" ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
fi
[[ "$port" =~ ^[0-9]+$ ]] || { echo "非法端口：$port" >&2; exit 2; }

dir="$REPO_DIR/services/$name"
if [[ -e "$dir" ]]; then
  echo "已存在：$dir（避免覆盖，跳过）" >&2
  exit 1
fi
mkdir -p "$dir"

cat > "$dir/compose.yml" <<EOF
# $name 服务编排（模板，按需修改镜像/端口/环境变量）
services:
  $name:
    image: <镜像>:<tag>
    container_name: $name
    restart: on-failure:3
    ports:
      - "127.0.0.1:$port:$port"   # 仅绑定本机，经 OpenResty/SSH 隧道对外，勿暴露公网
    volumes:
      - /opt/clouddock-data/$name:/data
    # environment:
    #   TZ: Asia/Shanghai
EOF

cat > "$dir/deploy.sh" <<'EOF'
#!/usr/bin/env bash
# __NAME__ 服务初始化（compose up 后执行）：数据目录 + 就绪检查
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../bootstrap/lib.sh
source "$SCRIPT_DIR/../../bootstrap/lib.sh"

mkdir -p "$DATA_DIR/__NAME__"
# 若容器用非 root 用户，需 chown 对应 uid，例如：
# chown -R 65532:65532 "$DATA_DIR/__NAME__"

# 就绪检查（示例，按服务实际健康检查调整）：
# for i in $(seq 1 60); do
#   docker inspect -f '{{.State.Health.Status}}' __NAME__ 2>/dev/null | grep -q healthy && break
#   sleep 2
# done
ok "__NAME__ 初始化完成。"
EOF

# 用占位符替换服务名（避免 heredoc 变量展开与生成文件 $ 字面量冲突）
tmp="$(mktemp)"
sed "s/__NAME__/$name/g" "$dir/deploy.sh" > "$tmp" && mv "$tmp" "$dir/deploy.sh"
chmod +x "$dir/deploy.sh"

echo "已生成："
echo "  $dir/compose.yml"
echo "  $dir/deploy.sh"
echo "下一步：编辑模板（镜像/端口/环境变量）→ git add/commit/push → VPS 上 clouddock upgrade"
