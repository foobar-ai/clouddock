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
2. 推送白名单到 VPS `authorized_keys`（`command=/opt/clouddock/ops/shell.sh` + 禁用 pty/agent-forwarding；端口转发仅限 `permitopen="127.0.0.1:3430"`（magpie Web）与 `permitopen="127.0.0.1:3425"`（magpie 网关，供 Remote magpie））。
3. `git pull` VPS 上的仓库（确保 `ops/` 脚本存在），并安装定时巡检 cron。

验证：

```bash
bash scripts/clouddock-ops-ssh.sh status   # 应输出 JSON，且不再要密码
```

## 子命令参考

### 服务控制（只动目标服务）

| 子命令 | 作用 | 说明 |
| --- | --- | --- |
| `services` | 服务清单 | JSON：服务/容器/状态/镜像/端口 |
| `up <svc>` | 重建/启动 | 应用最新 `.env`，只动目标服务 |
| `start <svc>` | 启动已停止容器 | 不重建 |
| `stop <svc>` | 停止服务 | 保留容器 |
| `restart <svc\|all>` | 重启 | 进程重启，**不重读 `.env`** |
| `pull <svc>` | 更新单服务镜像 | pull + 只重建该服务 |
| `logs <svc> [--tail=N]` | 日志 | 默认 200 行，自动脱敏 |
| `claude [show]` | Claude Code 配置 | 模型矩阵（model/picker/haiku·sonnet·opus·small_fast）+ 网关（密钥打码） |
| `claude apply [--model <m>]` | 按模板重渲染 | 模板 `claude/settings.template.json`；保留 `GH_TOKEN`/网关 key/自加 env |
| `claude set-model <m>` | 只改模型 | 所有模型位点改成 `<m>`（如 `group/free[1m]`）；重启 Claude Code 生效 |
| `claude doctor` | 环境自检 | claude/happy/tmux/settings 合法性/magpie 网关 HTTP 码 |

### 配置与网关

| 子命令 | 作用 |
| --- | --- |
| `env set KEY=VALUE [--svc <svc>]` | 精确改 `.env` 并只重建目标服务 |
| `env set KEY --stdin [--svc <svc>]` | 密钥从 stdin 传入（不进 shell 历史） |
| `reload` | 校验并重载 OpenResty |
| `magpie gwkey list` | 列 magpie 网关密钥（打码） |
| `magpie gwkey add <name>` | 新增网关密钥（一次性返回） |
| `magpie gwkey remove <name\|id>` | 吊销网关密钥 |
| `tools ensure <tool>` | 受控安装工具 | apt 官方源；白名单目前只放行 `tmux` |
| `agent git [--check-push]` | agent 的 GitHub 访问诊断 | SSH 资产/认证身份/git 身份/仓库 remote；`--check-push` 走 `push --dry-run`（不写入） |

`env set` 允许的键：`MAGPIE_WEB_KEY`、`MAGPIE_PUBLIC_URL`、`TRAFFIC_QUOTA_GB`。其中 `MAGPIE_WEB_KEY` 必须 **≥16 字符**（magpie 硬性要求，过短会导致容器启动即退出）。

### 状态与证书

| 子命令 | 作用 |
| --- | --- |
| `status` | 巡检 JSON（容器/证书/流量/磁盘/git） |
| `health` | 写 `/opt/clouddock-data/health.json`（cron 每天 0/12 点） |
| `renew` | `acme.sh --cron`（到期才续，幂等） |
| `reissue` | 强制重签（切换 http↔dns） |
| `upgrade` | git pull + 幂等重放 bootstrap + apply |
| `apply` | 全量 compose up -d（慎用；单服务用 `up <svc>`） |

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

- **白名单**：`status/health/renew/reissue/upgrade/apply/services/up/start/stop/pull/restart/logs/env set/reload/magpie gwkey/claude show|apply|set-model|doctor/tools ensure tmux`；`uninstall` 不纳入，需人工执行。
- **参数校验**：服务名限 `^[a-z0-9][a-z0-9-]{0,31}$`；`--tail=N` 限正整数；`env set` 仅允许 `MAGPIE_WEB_KEY/MAGPIE_PUBLIC_URL/TRAFFIC_QUOTA_GB`；杜绝命令注入；拒绝的调用记录到 syslog（`logger -t clouddock-ops`）。
- **密钥不落日志**：`env set` 的拒绝日志会脱敏（`KEY=***`）；密钥优先 `--stdin`，避免进 shell 历史与 SSH 命令行。
- **单服务优先**：`up/start/stop/pull` 只作用于目标服务；`apply` 才是全量，避免误重启无关服务。
- **通道加固**：专用 key 无 pty / agent-forwarding / X11；端口转发仅 `permitopen="127.0.0.1:3430"`（magpie Web 隧道用），其余目标一律拒绝。
- **脱敏**：`logs`/`status` 输出对 `.env`、`dnsapi.env` 的敏感值替换为 `***`。
- **私钥保护**：`.clouddock/` 已 gitignore，绝不提交、绝不写入输出/日志。

## 手动等价命令（无 AI 通道时）

```bash
cd /opt/clouddock
./clouddock status
./clouddock services
./clouddock up magpie
./clouddock start magpie
./clouddock stop magpie
./clouddock pull magpie
./clouddock env set MAGPIE_WEB_KEY=新值
./clouddock reload
./clouddock magpie gwkey list
./clouddock renew
./clouddock reissue
./clouddock upgrade
./clouddock apply
./clouddock restart <svc>
./clouddock logs <svc> --tail=200
./clouddock claude
./clouddock claude apply --model 'group/free[1m]'
./clouddock claude set-model 'group/free[1m]'
./clouddock claude doctor
./clouddock tools ensure tmux
```

> 详见 `skills/clouddock-ops/SKILL.md`（AI 侧调用约定）与 `docs/add-service.md`（服务结构约定）。
