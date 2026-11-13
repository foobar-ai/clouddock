#!/usr/bin/env bash
# ops/shell.sh — SSH 白名单受限入口（由 authorized_keys 的 command= 指定）
# 读取 $SSH_ORIGINAL_COMMAND，仅放行白名单子命令，其余一律拒绝并记录 syslog。
set -euo pipefail

CLOUDDOCK="/opt/clouddock/clouddock"
SVC_RE='^[a-z0-9][a-z0-9-]{0,31}$'
ENV_KEY_RE='^[A-Z][A-Z0-9_]*$'
ALLOWED_ENV_KEYS='MAGPIE_WEB_KEY MAGPIE_PUBLIC_URL TRAFFIC_QUOTA_GB'
GWKEY_RE='^[A-Za-z0-9._-]{1,64}$'

# 日志脱敏：env set 的值绝不落 syslog
redact_cmd() {
  local c="${SSH_ORIGINAL_COMMAND:-}"
  case "$c" in
    "env set "*)
      printf '%s' "$c" | sed -E 's/^(env set [A-Z0-9_]+=)[^ ]*/\1***/'
      ;;
    *)
      printf '%s' "$c"
      ;;
  esac
}

deny() {
  logger -t clouddock-ops "DENY: $(redact_cmd)"
  echo "拒绝：$*" >&2
  exit 1
}

cmd="${SSH_ORIGINAL_COMMAND:-}"
[[ -n "$cmd" ]] || deny "空命令"

# 按空白拆分（read -r -a 不做 glob 展开，安全）
read -r -a a <<< "$cmd"
sub="${a[0]:-}"

case "$sub" in
  status|health|renew|reissue|upgrade|apply|services|reload)
    [[ "${#a[@]}" -eq 1 ]] || deny "子命令 $sub 不接受参数"
    exec "$CLOUDDOCK" "$sub"
    ;;
  restart)
    [[ "${#a[@]}" -eq 2 ]] || deny "restart 需且仅需 1 个参数"
    svc="${a[1]}"
    if [[ "$svc" == "all" ]]; then
      exec "$CLOUDDOCK" restart all
    fi
    [[ "$svc" =~ $SVC_RE ]] || deny "非法服务名：$svc"
    exec "$CLOUDDOCK" restart "$svc"
    ;;
  up|start|stop|pull)
    [[ "${#a[@]}" -eq 2 ]] || deny "$sub 需且仅需 1 个服务名"
    svc="${a[1]}"
    [[ "$svc" =~ $SVC_RE ]] || deny "非法服务名：$svc"
    exec "$CLOUDDOCK" "$sub" "$svc"
    ;;
  logs)
    [[ "${#a[@]}" -ge 2 && "${#a[@]}" -le 3 ]] || deny "logs 参数数量非法"
    svc="${a[1]}"
    [[ "$svc" =~ $SVC_RE ]] || deny "非法服务名：$svc"
    if [[ "${#a[@]}" -eq 3 ]]; then
      [[ "${a[2]}" =~ ^--tail=[0-9]+$ ]] || deny "非法参数：${a[2]}"
      exec "$CLOUDDOCK" logs "$svc" "${a[2]}"
    fi
    exec "$CLOUDDOCK" logs "$svc"
    ;;
  env)
    [[ "${a[1]:-}" == "set" ]] || deny "仅支持 env set"
    [[ "${#a[@]}" -ge 3 && "${#a[@]}" -le 6 ]] || deny "env set 参数数量非法"
    key="${a[2]%%=*}"
    [[ "$key" =~ $ENV_KEY_RE ]] || deny "非法 env 键：$key"
    case " $ALLOWED_ENV_KEYS " in
      *" $key "*) ;;
      *) deny "不允许修改该键：$key" ;;
    esac
    i=3
    while [[ $i -lt ${#a[@]} ]]; do
      case "${a[$i]}" in
        --svc)
          [[ $((i + 1)) -lt ${#a[@]} ]] || deny "--svc 缺少值"
          check_svc="${a[$((i + 1))]}"
          [[ "$check_svc" =~ $SVC_RE ]] || deny "非法服务名：$check_svc"
          i=$((i + 2))
          ;;
        --stdin)
          i=$((i + 1))
          ;;
        *)
          deny "未知参数：${a[$i]}"
          ;;
      esac
    done
    exec "$CLOUDDOCK" env "${a[@]:1}"
    ;;
  claude)
    if [[ "${#a[@]}" -eq 1 ]]; then
      exec "$CLOUDDOCK" claude
    fi
    [[ "${a[1]:-}" == "set-model" && "${#a[@]}" -eq 3 ]] \
      || deny "claude 仅支持 show 或 set-model <model>"
    [[ "${a[2]}" =~ ^[^[:space:]]{1,128}$ ]] || deny "非法模型名"
    exec "$CLOUDDOCK" claude set-model "${a[2]}"
    ;;
  magpie)
    [[ "${a[1]:-}" == "gwkey" ]] || deny "仅支持 magpie gwkey"
    case "${a[2]:-}" in
      list)
        [[ "${#a[@]}" -eq 3 ]] || deny "gwkey list 不接受参数"
        exec "$CLOUDDOCK" magpie gwkey list
        ;;
      add)
        [[ "${#a[@]}" -eq 4 ]] || deny "gwkey add 需且仅需 1 个名称"
        [[ "${a[3]}" =~ $GWKEY_RE ]] || deny "非法 key 名称"
        exec "$CLOUDDOCK" magpie gwkey add "${a[3]}"
        ;;
      remove)
        [[ "${#a[@]}" -eq 4 ]] || deny "gwkey remove 需且仅需 1 个标识"
        [[ "${a[3]}" =~ $GWKEY_RE ]] || deny "非法 key 标识"
        exec "$CLOUDDOCK" magpie gwkey remove "${a[3]}"
        ;;
      *)
        deny "未知 magpie 子命令"
        ;;
    esac
    ;;
  *)
    deny "不允许的命令：$sub"
    ;;
esac

deny "参数非法"
