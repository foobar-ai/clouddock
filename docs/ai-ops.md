# AI 运维指南

让 AI（Claude Code / CodeBuddy）安全地运维 clouddock：把散落在 SSH 手工粘贴里的动作，收敛为一套幂等、JSON 输出的运维 CLI，再通过专用 SSH 白名单通道交给 AI 调用。

## 三层架构

```
本地 AI ──> scripts/clouddock-ops-ssh.sh ──(专用 key)──> VPS sshd
                                                        └─ command= 白名单 ──> ops/shell.sh ──> clouddock CLI
```

- **底层**：VPS 上的 `clouddock` CLI（`ops/*.sh`），幂等、无交互、关键输出 JSON。
- **通道**：专用 SSH key + `authorized_keys` 的 `command=` 硬约束，只放行白名单子命令。
- **上层**：本地 `skills/clouddock-ops`（Agent Skill）+ `scripts/clouddock-ops-ssh.sh` wrapper。

## 一次性初始化

在本地仓库执行（需能 SSH 到 VPS，首次会要一次密码）：

```bash
bash scripts/install-ops.sh <VPS地址> [SSH用户] [SSH端口]
```

它会：
1. 生成 `.clouddock/ops_key`（专用 ed25519 密钥，已 gitignore）+ `.clouddock/ops.conf`。
2. 推送白名单到 VPS `authorized_keys`（`command=/opt/clouddock/ops/shell.sh` + 禁用 pty/端口转发/agent-forwarding）。
3. `git pull` VPS 上的仓库（确保 `ops/` 脚本存在），并安装定时巡检 cron。

验证：

```bash
bash scripts/clouddock-ops-ssh.sh status   # 应输出 JSON，且不再要密码
```

## 子命令参考

| 子命令 | 作用 | 输出 |
| --- | --- | --- |
| `status` | 状态巡检 | JSON：容器/证书/流量/磁盘/git |
| `health` | 写健康快照 | 写 `/opt/clouddock-data/health.json`（cron 每天 0/12 点自动写） |
| `renew` | 续期证书 | `acme.sh --cron`（到期才续，幂等） |
| `reissue` | 强制重签 | 复用 `CERT_FORCE=1`，切换 http↔dns 用 |
| `upgrade` | 升级 | git pull + 幂等重放 bootstrap + apply |
| `apply` | 聚合启动 | `compose up -d` + 各 deploy.sh，不走就绪跳过 |
| `restart <svc\|all>` | 重启 | 服务名正则校验 |
| `logs <svc> [--tail=N]` | 日志 | 默认 200 行，自动脱敏 |

## status 判读阈值

| 字段 | 正常 | 预警 | 处置 |
| --- | --- | --- | --- |
| `cert.days_left` | ≥ 30 | 14~30 | `renew`；<14 则 `renew`/`reissue` |
| `containers[].health` | healthy | unhealthy / 非 running | `restart <svc>` → `logs <svc>` |
| `traffic.pct` | < 70 | ≥ 90 | 提醒查 `vnstat -m`（tx）与账单 |
| `disk.used_pct` | < 70 | ≥ 85 | 清理（`docker system prune` 等） |

## 安装新服务

```bash
# 1) 本地脚手架
bash scripts/add-service.sh <name> --port <端口>
# 2) 编辑 services/<name>/compose.yml + deploy.sh（端口只绑 127.0.0.1）
# 3) 提交推送
git add services/<name> && git commit -m "feat(service): add <name>" && git push
# 4) 远端落地（git pull + 幂等重放 + apply）
bash scripts/clouddock-ops-ssh.sh upgrade
# 5) 验证
bash scripts/clouddock-ops-ssh.sh status
```

## 安全模型

- **白名单最小集**：`status/health/renew/reissue/upgrade/apply/restart/logs`；`uninstall` 不纳入，需人工执行。
- **参数校验**：服务名限 `^[a-z0-9][a-z0-9-]{0,31}$`，`--tail=N` 限正整数，杜绝命令注入；拒绝的调用记录到 syslog（`logger -t clouddock-ops`）。
- **通道加固**：专用 key 无 pty / 端口转发 / agent-forwarding / X11。
- **脱敏**：`logs`/`status` 输出对 `.env`、`dnsapi.env` 的敏感值替换为 `***`。
- **私钥保护**：`.clouddock/` 已 gitignore，绝不提交、绝不写入输出/日志。

## 手动等价命令（无 AI 通道时）

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

> 详见 `skills/clouddock-ops/SKILL.md`（AI 侧调用约定）与 `docs/add-service.md`（服务结构约定）。
