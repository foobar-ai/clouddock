#!/usr/bin/env bash
# ops/service.sh — 单服务生命周期：up | start | stop | pull（只动目标服务）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DEPLOY_DIR="${DEPLOY_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
source "$SCRIPT_DIR/lib.sh"

require_root

action="${1:-}"
svc="${2:-}"
[[ -n "$action" ]] || die "用法: clouddock <up|start|stop|pull|recreate> <服务名> | net"

# 只读：容器 ↔ 宿主的可达地址（跨容器访问宿主上的服务时需要）
if [[ "$action" == "net" ]]; then
  echo "--- 容器与网关 IP"
  local_c=""
  for local_c in $(svc_names 2>/dev/null); do
    docker inspect "$local_c" --format '{{.Name}} {{range $k,$v := .NetworkSettings.Networks}}{{$k}} ip={{$v.IPAddress}} gw={{$v.Gateway}}{{end}}' 2>/dev/null || true
  done
  echo "--- compose 网络"
  for local_n in $(docker network ls --format '{{.Name}}' 2>/dev/null | grep -E '^clouddock_'); do
    printf '%s ' "$local_n"
    docker network inspect "$local_n" --format '{{range .IPAM.Config}}subnet={{.Subnet}} gw={{.Gateway}}{{end}}' 2>/dev/null || true
  done
  echo "--- 宿主回环服务监听"
  ss -lntp 2>/dev/null | grep -E ':(3000|3425|3430)\b' || echo "(无)"
  echo "--- 容器 → 宿主 3425 重定向"
  iptables -t nat -S PREROUTING 2>/dev/null | grep -- '--dport 3425 -j REDIRECT' || echo "(无规则)"
  if docker inspect new-api >/dev/null 2>&1; then
    gw="$(docker inspect new-api --format '{{range $k,$v := .NetworkSettings.Networks}}{{$v.Gateway}}{{end}}' 2>/dev/null)"
    echo "--- new-api → host.docker.internal:3425"
    docker exec new-api sh -c 'wget -S -O- -T 3 http://host.docker.internal:3425/api/hello 2>&1 | tail -4' \
      2>/dev/null || echo "(不可达)"
    if [[ -n "$gw" ]]; then
      echo "--- new-api → 网络网关 ${gw}:3425（/api/hello）"
      docker exec new-api sh -c "wget -S -O- -T 3 http://${gw}:3425/api/hello 2>&1 | tail -4" \
        2>/dev/null || echo "(不可达)"
      mkey="$(env_get MAGPIE_GATEWAY_KEY 2>/dev/null || true)"
      if [[ -n "$mkey" ]]; then
        echo "--- new-api → ${gw}:3425/v1/models（带 gateway key）"
        docker exec -e MK="$mkey" new-api sh -c \
          "wget -S -O- -T 5 --header=\"Authorization: Bearer \$MK\" http://${gw}:3425/v1/models 2>&1 | head -8" \
          2>/dev/null || echo "(不可达)"
        echo
      fi
    fi
    echo
  fi
  exit 0
fi

require_svc "$svc"

compose_files

case "$action" in
  up)
    log "重建/启动服务 $svc ..."
    compose_up_svc "$svc"
    ;;
  start)
    log "启动服务 $svc ..."
    docker compose --env-file "$ENV_FILE" "${COMPOSE_FILES[@]}" start "$svc"
    ;;
  stop)
    log "停止服务 $svc ..."
    docker compose --env-file "$ENV_FILE" "${COMPOSE_FILES[@]}" stop "$svc"
    ;;
  recreate)
    # 删除容器后按当前 compose 重建（用于 project 名变更、容器漂移等场景；数据在卷/挂载上不丢）
    log "移除容器 $svc 并按当前 compose 重建 ..."
    docker rm -f "$svc" >/dev/null 2>&1 || true
    compose_up_svc "$svc"
    ;;
  pull)
    if [[ "$(svc_has_build "$svc")" == "yes" ]]; then
      log "服务 $svc 为本地构建，拉取基础镜像并重建 ..."
      docker compose --env-file "$ENV_FILE" "${COMPOSE_FILES[@]}" build --pull "$svc"
    else
      log "拉取服务 $svc 镜像 ..."
      docker compose --env-file "$ENV_FILE" "${COMPOSE_FILES[@]}" pull "$svc"
    fi
    log "重建服务 $svc ..."
    compose_up_svc "$svc"
    ;;
  *)
    die "未知动作：$action（可用：up|start|stop|pull）"
    ;;
esac

state="$(docker inspect -f '{{.State.Status}}' "$svc" 2>/dev/null || echo absent)"
ok "$svc $action 完成（当前状态：$state）。"
