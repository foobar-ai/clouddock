#!/usr/bin/env bash
# ops/shell.sh — SSH 白名单受限入口（由 authorized_keys 的 command= 指定）
# 读取 $SSH_ORIGINAL_COMMAND，仅放行白名单子命令，其余一律拒绝并记录 syslog。
set -euo pipefail

CLOUDDOCK="/opt/clouddock/clouddock"

deny() {
  logger -t clouddock-ops "DENY: ${SSH_ORIGINAL_COMMAND:-<empty>}"
  echo "拒绝：$*"
  exit 1
}

cmd="${SSH_ORIGINAL_COMMAND:-}"
[[ -n "$cmd" ]] || deny "空命令"

# 按空白拆分（read -r -a 不做 glob 展开，安全）
read -r -a a <<< "$cmd"
sub="${a[0]:-}"

case "$sub" in
  status|health|renew|reissue|upgrade|apply)
    [[ "${#a[@]}" -eq 1 ]] || deny "子命令 $sub 不接受参数"
    exec "$CLOUDDOCK" "$sub"
    ;;
  restart)
    [[ "${#a[@]}" -eq 2 ]] || deny "restart 需且仅需 1 个参数"
    svc="${a[1]}"
    if [[ "$svc" == "all" ]]; then
      exec "$CLOUDDOCK" restart all
    fi
    [[ "$svc" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || deny "非法服务名：$svc"
    exec "$CLOUDDOCK" restart "$svc"
    ;;
  logs)
    [[ "${#a[@]}" -ge 2 && "${#a[@]}" -le 3 ]] || deny "logs 参数数量非法"
    svc="${a[1]}"
    [[ "$svc" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || deny "非法服务名：$svc"
    if [[ "${#a[@]}" -eq 3 ]]; then
      [[ "${a[2]}" =~ ^--tail=[0-9]+$ ]] || deny "非法参数：${a[2]}"
      exec "$CLOUDDOCK" logs "$svc" "${a[2]}"
    fi
    exec "$CLOUDDOCK" logs "$svc"
    ;;
  *)
    deny "不允许的命令：$sub"
    ;;
esac

deny "参数非法"
