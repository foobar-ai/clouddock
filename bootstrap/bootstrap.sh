#!/usr/bin/env bash
# bootstrap.sh — 远端总控：交互收集配置、初始化 .env、按序调用各阶段脚本、收尾打印自查清单
# 通常由 install.sh 调用；也可直接 bash bootstrap/bootstrap.sh 运行（需 root）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
export DEPLOY_DIR="$PROJECT_DIR"

# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_root
require_debian12
log "项目根目录：${DEPLOY_DIR}"

# ---------- 交互收集配置 ----------
# 取值优先级：.env 已有值 > shell 环境变量（无交互场景，如 curl | VAR=x bash）> 交互询问。
# 所有值最终写入 .env，重跑幂等不重复询问。
collect_config() {
  local v

  if [[ -z "$(env_get NEWAPI_DOMAIN 2>/dev/null || true)" ]]; then
    if [[ -n "${NEWAPI_DOMAIN:-}" ]]; then
      log "使用环境变量 NEWAPI_DOMAIN=${NEWAPI_DOMAIN}"
      v="$NEWAPI_DOMAIN"
    else
      read -rp "new-api 对外域名（如 api.example.com）: " v
    fi
    [[ -n "$v" ]] || die "域名不能为空（用于 HTTPS 证书与反代）。"
    env_set NEWAPI_DOMAIN "$v"
  fi

  if [[ -z "$(env_get CERT_MODE 2>/dev/null || true)" ]]; then
    if [[ -n "${CERT_MODE:-}" ]]; then
      log "使用环境变量 CERT_MODE=${CERT_MODE}"
      v="$CERT_MODE"
    else
      echo "证书验证方式：http = HTTP-01（推荐，需域名 A 记录已解析到本 VPS 且安全组放行 80/443）；dns = DNS API"
      read -rp "证书验证方式 [http]: " v
    fi
    v="${v:-http}"
    case "$v" in
      http|dns) ;;
      *) die "证书验证方式仅支持 http 或 dns。" ;;
    esac
    env_set CERT_MODE "$v"
  fi

  if [[ -z "$(env_get TRAFFIC_QUOTA_GB 2>/dev/null || true)" ]]; then
    if [[ -n "${TRAFFIC_QUOTA_GB:-}" ]]; then
      log "使用环境变量 TRAFFIC_QUOTA_GB=${TRAFFIC_QUOTA_GB}"
      v="$TRAFFIC_QUOTA_GB"
    else
      read -rp "月流量包额度 GB [1024]: " v
    fi
    v="${v:-1024}"
    env_set TRAFFIC_QUOTA_GB "$v"
  fi

  if [[ -z "$(env_get NEWAPI_SQL_DSN 2>/dev/null || true)" ]]; then
    if [[ -n "${NEWAPI_SQL_DSN:-}" ]]; then
      log "使用环境变量 NEWAPI_SQL_DSN（值不回显）"
      v="$NEWAPI_SQL_DSN"
    else
      read -rp "Supabase PostgreSQL 连接串（postgresql://postgres.xxx:password@host:5432/postgres）: " v
    fi
    [[ -n "$v" ]] || die "SQL_DSN 不能为空（new-api 需要数据库）。"
    env_set NEWAPI_SQL_DSN "$v"
  fi

  if [[ -z "$(env_get NEWAPI_REDIS_CONN_STRING 2>/dev/null || true)" ]]; then
    # 显式传入（含空串=不使用 Redis）则跳过询问；未传入才交互询问
    if [[ "${NEWAPI_REDIS_CONN_STRING+x}" == "x" ]]; then
      v="$NEWAPI_REDIS_CONN_STRING"
      [[ -n "$v" ]] && log "使用环境变量 NEWAPI_REDIS_CONN_STRING（值不回显）"
    else
      read -rp "Upstash Redis 连接串（rediss://:password@host:6379，回车跳过=不使用）: " v
    fi
    if [[ -n "$v" ]]; then
      env_set NEWAPI_REDIS_CONN_STRING "$v"
    else
      warn "未配置 Upstash Redis，new-api 将降级使用内存缓存（不影响核心功能）。"
    fi
  fi

  if [[ "$(env_get CERT_MODE)" == "dns" ]]; then
    if [[ -z "$(env_get DNS_PROVIDER 2>/dev/null || true)" ]]; then
      if [[ -n "${DNS_PROVIDER:-}" ]]; then
        log "使用环境变量 DNS_PROVIDER=${DNS_PROVIDER}"
        v="$DNS_PROVIDER"
      else
        read -rp "acme.sh DNS API 标识（如 dns_dp / dns_cf / dns_ali）: " v
      fi
      [[ -n "$v" ]] || die "DNS 模式需提供 acme.sh DNS API 标识。"
      env_set DNS_PROVIDER "$v"
    fi
    if [[ ! -f "$DEPLOY_DIR/deploy/dnsapi.env" ]]; then
      # 无交互场景：可用 DNS_API_ENV 环境变量直接写入凭证文件（内容为多行 export KEY=VALUE）
      if [[ -n "${DNS_API_ENV:-}" ]]; then
        log "使用环境变量 DNS_API_ENV 写入 ${DEPLOY_DIR}/deploy/dnsapi.env"
        printf '%s\n' "$DNS_API_ENV" > "$DEPLOY_DIR/deploy/dnsapi.env"
      else
        warn "DNS 模式需在 ${DEPLOY_DIR}/deploy/dnsapi.env 写入凭证（每行一条 export KEY=VALUE，例如："
        warn "  export DP_Id=xxx"
        warn "  export DP_Key=yyy"
        warn "）。或通过环境变量 DNS_API_ENV 传入（无交互部署）。"
        exit 1
      fi
    fi
  fi

  ok "配置收集完成。"
}

# ---------- 初始化密钥（幂等：已存在不覆盖） ----------
init_secrets() {
  mkdir -p "$(dirname "$ENV_FILE")"
  touch "$ENV_FILE"
  [[ -z "$(env_get NEWAPI_SESSION_SECRET 2>/dev/null || true)" ]] && env_set NEWAPI_SESSION_SECRET "$(rand_hex 32)"
  [[ -z "$(env_get NEWAPI_CRYPTO_SECRET 2>/dev/null || true)" ]] && env_set NEWAPI_CRYPTO_SECRET "$(env_get NEWAPI_SESSION_SECRET)"
  [[ -z "$(env_get MAGPIE_WEB_KEY 2>/dev/null || true)" ]] && env_set MAGPIE_WEB_KEY "$(rand_hex 16)"
  [[ -z "$(env_get MAGPIE_PUBLIC_URL 2>/dev/null || true)" ]] && env_set MAGPIE_PUBLIC_URL "http://127.0.0.1:3425"
  [[ -z "$(env_get NEWAPI_TRUSTED_PROXIES 2>/dev/null || true)" ]] && env_set NEWAPI_TRUSTED_PROXIES "127.0.0.1,172.16.0.0/12"
  ok ".env 已就绪（密钥已生成/保留）。"
}

# ---------- 收尾打印 ----------
print_finish() {
  local domain quota warn_q crit_q
  domain="$(cfg NEWAPI_DOMAIN '')"
  quota="$(cfg TRAFFIC_QUOTA_GB '1024')"
  warn_q=$(( quota * 70 / 100 ))
  crit_q=$(( quota * 90 / 100 ))

  echo
  echo "======================================================"
  echo " 部署完成。以下是首次上线自查清单（重要）："
  echo "======================================================"
  echo "1) 流量告警：在云厂商控制台『监控/告警』对出网流量设置两级阈值"
  echo "   - 提示阈值：${warn_q}GB（70%）"
  echo "   - 严重阈值：${crit_q}GB（90%）"
  echo "   （华为云 Flexus L 仅出网流量计费，月流量包 ${quota}GB，超包按量收费；其他云按各自规则）"
  echo "2) 系统盘备份策略：确认未对该实例启用自动云备份/快照，避免超额计费"
  echo "3) 查看本月出网流量对账：vnstat -m  （只看 tx 列）"
  if [[ -n "$domain" ]]; then
    echo "4) new-api 控制台：https://${domain}  （首次访问创建管理员账号）"
  fi
  echo "5) magpie Web UI：SSH 隧道后访问 http://127.0.0.1:3430/?k=<MAGPIE_WEB_KEY>"
  echo "======================================================"
}

# ---------- 主流程 ----------
collect_config
init_secrets

log "开始按序执行各阶段脚本..."
"$SCRIPT_DIR/steps/00-prereq.sh"
"$SCRIPT_DIR/steps/01-docker.sh"
"$SCRIPT_DIR/steps/02-openresty.sh"
"$SCRIPT_DIR/steps/03-acme.sh"
"$SCRIPT_DIR/steps/04-cert.sh"
"$SCRIPT_DIR/steps/05-services.sh"
"$SCRIPT_DIR/steps/06-openresty-site.sh"

ok "全部阶段执行完毕。"
print_finish
