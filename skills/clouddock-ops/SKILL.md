---
name: clouddock-ops
description: clouddock 云主机的 AI 运维能力。当用户需要查看部署状态、服务清单、启停/重启/更新服务、精确修改 .env 配置（如 magpie web key）、重载 OpenResty、证书续期/切换、升级、排查日志、管理 magpie 网关密钥、或打开/管理 magpie Web UI 时使用。通过专用 SSH 白名单通道调用 VPS 上的 clouddock CLI，白名单内命令可直接执行。
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

### 服务控制（只动目标服务）

| 子命令 | 作用 | 说明 |
| --- | --- | --- |
| `services` | 服务清单 | JSON：服务/容器/状态/镜像/端口 |
| `up <svc>` | 重建/启动服务 | 应用最新 `.env`；只动目标服务 |
| `start <svc>` | 启动已停止的服务 | 不重建 |
| `stop <svc>` | 停止服务 | 保留容器 |
| `restart <svc\|all>` | 重启 | 进程重启，**不重读 `.env`** |
| `pull <svc>` | 更新单服务镜像 | pull + 只重建该服务 |
| `logs <svc> [--tail=N]` | 查看日志 | 默认 200 行，自动脱敏 |

### 配置与网关（精确、白名单键）

| 子命令 | 作用 |
| --- | --- |
| `env set KEY=VALUE [--svc <svc>]` | 改 `.env` 并只重建目标服务 |
| `env set KEY --stdin [--svc <svc>]` | 密钥从 stdin 传入（不进 shell 历史） |
| `reload` | 校验并重载 OpenResty |
| `magpie gwkey list` | 列 magpie 网关密钥（打码） |
| `magpie gwkey add <name>` | 新增网关密钥（key 只打印一次） |
| `magpie gwkey remove <name\|id>` | 吊销网关密钥 |

`env set` 允许的键：`MAGPIE_WEB_KEY`、`MAGPIE_PUBLIC_URL`、`TRAFFIC_QUOTA_GB`。其中 `MAGPIE_WEB_KEY` 必须 **≥16 字符**（magpie 硬性要求，过短会导致容器启动即退出）。

### 状态与证书

| 子命令 | 作用 |
| --- | --- |
| `status` | 巡检 JSON（容器/证书/流量/磁盘/git） |
| `health` | 写健康快照 `/opt/clouddock-data/health.json` |
| `renew` | 续期证书（acme.sh --cron） |
| `reissue` | 强制重签（切换 http↔dns） |
| `upgrade` | git pull + 幂等重放 bootstrap + apply |
| `apply` | 全量 compose up -d（**慎用**，单服务请用 `up <svc>`） |

## 自然语言 → 命令映射

- 「看下有哪些服务 / 服务状态」→ `services`
- 「重启 magpie」→ `restart magpie`
- 「把 magpie web key 改成 xxx」→ `env set MAGPIE_WEB_KEY=xxx`
- 「只更新 magpie 镜像」→ `pull magpie`
- 「停掉 magpie」→ `stop magpie`；「拉起来」→ `up magpie`
- 「重载 nginx/OpenResty」→ `reload`
- 「列 magpie 网关密钥」→ `magpie gwkey list`
- 「打开/管理 magpie Web UI」→ 本地隧道（见下节）

## status 判读阈值

- `cert.days_left`：`>= 30` 正常；`14~30` 预警（建议 `renew`）；`< 14` 需立即处理（`renew` 或 `reissue`）。
- `containers[].state != running` 或 `health == unhealthy` → `restart <svc>`；仍异常则 `logs <svc>` 排查。
- `traffic.pct >= 90` → 流量告警，提醒用户关注 `vnstat -m`（tx）与云厂商账单。
- `disk.used_pct >= 85` → 磁盘告警，提示清理（`docker system prune` 等，先向用户确认）。

## 安装新服务

1. 本地脚手架：`bash scripts/add-service.sh <name> --port <端口>`。
2. 编辑 `services/<name>/compose.yml` + `deploy.sh`（端口只绑 `127.0.0.1`）。
3. `git add` / `git commit` / `git push`。
4. 远端落地：`bash scripts/clouddock-ops-ssh.sh upgrade`（git pull + 幂等重放 + apply）。
5. 验证：`services` 中出现该服务且 `state=running`。

## 打开 magpie Web UI（本地隧道）

当用户要「打开/管理 magpie 的管理页面」时（本地与 VPS 两套 magpie 独立），用本地隧道脚本。隧道复用同一把 `.clouddock/ops_key`，走 `-N -L` 纯转发（不是 `clouddock-ops-ssh.sh` 的命令通道）。

```bash
bash scripts/magpie-web-tunnel.sh start    # 后台建隧道，VPS 地址自动读 .clouddock/ops.conf
bash scripts/magpie-web-tunnel.sh status   # 查看状态
bash scripts/magpie-web-tunnel.sh stop     # 关闭隧道
```

`start` 成功后，把返回的「另一个 MAGPIE」填法转告用户即可：地址 `http://127.0.0.1:3431`（本地端口）、密钥取 VPS `deploy/.env` 的 `MAGPIE_WEB_KEY`。不要自行在输出/日志里打印密钥值。

隧道复用同一把 `.clouddock/ops_key`（`install-ops.sh` 已授权 `permitopen="127.0.0.1:3430"`，只允许转发到 magpie Web 端口），无需额外密钥；`-N` 纯转发不触发 `command=` 白名单命令。

## 安全边界（必须遵守）

- 白名单仅放行上述子命令；`uninstall` 不在白名单，需用户人工执行 `bash /opt/clouddock/uninstall.sh`。
- `env set` 仅允许白名单键；密钥优先用 `--stdin`；拒绝日志会自动脱敏（值不进 syslog）。
- `up/stop/pull` 只影响目标服务；`apply` 才是全量，非必要不用。
- 专用 key 无 pty / agent-forwarding；端口转发仅放行 `permitopen="127.0.0.1:3430"`（magpie Web，供本地隧道），其余目标一律拒绝；即使提示词被注入也越不过白名单。
- 日志/status 输出自动脱敏（`.env`、`dnsapi.env` 的敏感值替换为 `***`）。
- 绝不把 `.clouddock/`（私钥）或 VPS 上的 `.env` / `dnsapi.env` 内容写入输出、日志或任何沉淀内容。
- `magpie gwkey add` 返回的是一次性密钥：只回给用户，不写入任何文件/日志/记忆。

## 手动等价命令（无 AI 通道时）

白名单不可用或需人工操作时，SSH 到 VPS 后直接执行：

```bash
cd /opt/clouddock
./clouddock status
./clouddock services
./clouddock up magpie
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
```
