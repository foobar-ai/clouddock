---
name: clouddock-ops
description: clouddock 云主机的 AI 运维能力。当用户需要查看 clouddock 部署状态、证书续期或切换验证方式、升级服务、重启或排查服务、或安装新服务时使用。通过专用 SSH 白名单通道调用 VPS 上的 clouddock CLI，白名单内命令可直接执行。
---

# clouddock AI 运维

通过本地 `scripts/clouddock-ops-ssh.sh` 经专用 SSH 白名单通道，调用 VPS 上的 `clouddock` CLI 完成运维操作。

## 前置条件

- 已运行 `bash scripts/install-ops.sh <VPS地址>`（生成本地 `.clouddock/ops_key` + `.clouddock/ops.conf`，并在 VPS 装好白名单与定时巡检）。
- 若尚未初始化，先提示用户执行 install-ops.sh，不要尝试绕过白名单直接 SSH。

## 调用方式

```bash
bash scripts/clouddock-ops-ssh.sh <子命令> [参数]
```

子命令（全部幂等、白名单已放行）：

| 子命令 | 作用 | 说明 |
| --- | --- | --- |
| `status` | 状态巡检 | JSON：容器/证书/流量/磁盘/git |
| `health` | 写健康快照 | 写 `/opt/clouddock-data/health.json` |
| `renew` | 续期证书 | `acme.sh --cron`，到期才真正续 |
| `reissue` | 强制重签 | 切换 http↔dns 验证方式用 |
| `upgrade` | 升级 | git pull + 幂等重放 bootstrap + apply |
| `apply` | 聚合启动 | compose up -d + deploy.sh，不走就绪跳过 |
| `restart <svc\|all>` | 重启服务 | 服务名限 `^[a-z0-9][a-z0-9-]{0,31}$` |
| `logs <svc> [--tail=N]` | 查看日志 | 默认 200 行，自动脱敏 |

## status 判读阈值

- `cert.days_left`：`>= 30` 正常；`14~30` 预警（建议 `renew`）；`< 14` 需立即处理（`renew` 或 `reissue`）。
- `containers[].state != running` 或 `health == unhealthy` → `restart <svc>`；仍异常则 `logs <svc>` 排查。
- `traffic.pct >= 90` → 流量告警，提醒用户关注 `vnstat -m`（tx）与云厂商账单。
- `disk.used_pct >= 85` → 磁盘告警，提示清理（`docker system prune` 等，先向用户确认）。

## 安装新服务

1. 本地脚手架：`bash scripts/add-service.sh <name> --port <端口>`，生成 `services/<name>/compose.yml` 与 `deploy.sh`。
2. 编辑模板（镜像、端口、环境变量、数据目录；端口只绑 `127.0.0.1`，不暴露公网）。
3. `git add` / `git commit` / `git push` 推送到远端。
4. 远端落地：`bash scripts/clouddock-ops-ssh.sh upgrade`（含 git pull + 幂等重放 + apply）。
5. 验证：`bash scripts/clouddock-ops-ssh.sh status` 确认新容器 `running`。

## 安全边界（必须遵守）

- 白名单仅放行上述子命令；`uninstall` 不在白名单，需用户人工执行 `bash /opt/clouddock/uninstall.sh`。
- 专用 key 无 pty / 端口转发 / agent-forwarding；即使提示词被注入也越不过白名单。
- 日志/status 输出自动脱敏（`.env`、`dnsapi.env` 的敏感值替换为 `***`）。
- 绝不把 `.clouddock/`（私钥）或 VPS 上的 `.env` / `dnsapi.env` 内容写入输出、日志或任何沉淀内容。

## 手动等价命令（无 AI 通道时）

白名单不可用或需人工操作时，SSH 到 VPS 后直接执行：

```bash
cd /opt/clouddock
./clouddock status
./clouddock renew
./clouddock reissue
./clouddock upgrade
./clouddock apply
./clouddock restart <svc>
./clouddock logs <svc> --tail=200
```
