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
| `claude [show]` | Claude Code 配置 | 模型矩阵（model/picker/haiku·sonnet·opus·small_fast）+ 网关，密钥打码 |
| `claude apply [--model <m>]` | 按模板重渲染配置 | 模板 `claude/settings.template.json`（单一真源）；保留 GH_TOKEN/网关 key/自加 env |
| `claude set-model <m>` | 只换模型 | 把所有模型位点改为 `<m>`（如 `group/free[1m]`）；重启 Claude Code 生效 |
| `claude doctor` | 环境自检 | claude/happy/tmux/settings 合法性/magpie 网关 HTTP 码 |

### 配置与网关（精确、白名单键）

| 子命令 | 作用 |
| --- | --- |
| `env set KEY=VALUE [--svc <svc>]` | 改 `.env` 并只重建目标服务 |
| `env set KEY --stdin [--svc <svc>]` | 密钥从 stdin 传入（不进 shell 历史） |
| `reload` | 校验并重载 OpenResty |
| `magpie gwkey list` | 列 magpie 网关密钥（打码） |
| `magpie gwkey add <name>` | 新增网关密钥（key 只打印一次） |
| `magpie gwkey remove <name\|id>` | 吊销网关密钥 |
| `tools ensure <tool>` | 受控装工具 | apt 官方源；白名单目前仅 `tmux` |
| `agent git [--check-push]` | agent 的 GitHub 访问诊断 | SSH 资产/认证/git 身份/仓库 remote；`--check-push` = `git push --dry-run` |

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
- 「VPS 上 Claude Code 用哪个模型 / 改成 group/xxx」→ `claude` / `claude set-model group/xxx`
- 「按项目模板收敛 Claude Code 配置 / 恢复参考配置」→ `claude apply --model group/free[1m]`
- 「Claude Code 是不是装坏了 / 连不上 magpie」→ `claude doctor`
- 「VPS 缺 tmux / Agent Teams 不能分屏」→ `tools ensure tmux`
- 「agent 能不能 push GitHub / SSH 有没有配好 / 仓库 remote 是什么」→ `agent git`；要验证写权限 → `agent git --check-push`
- 「agent 用户怎么选项目目录启动 Claude Code」→ 由用户人工执行 `su - agent -c 'agent-session'`（交互菜单，`--list` 列候选；AI 通道不需要也无法代跑交互）
- 「打开/管理 magpie Web UI」「magpie 隧道断了 / 打不开」「唤醒 magpie 隧道」→ `magpie-web-tunnel.sh start`（幂等：已在运行直接返回，断了就重连）
- 「让本机 magpie 用 VPS 的模型/订阅」→ `magpie-gateway-tunnel.sh start` + `magpie gwkey add <名称>`（见 Remote magpie 节）

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

隧道**不会自动重连**（Mac 睡眠、网络切换、SSH 超时都会断）。用户说「隧道断了 / 打不开 / 唤醒一下」时，直接重跑 `start` 即可（幂等）。

## Remote magpie（本机使用 VPS 模型）

当用户要「让本机 magpie 用 VPS 的模型/订阅」时（本机与 VPS 两套 magpie 独立，只是把 VPS 当上游供应商）：

```bash
bash scripts/magpie-gateway-tunnel.sh start                 # 本地 3426 -> VPS 3425，后台
bash scripts/clouddock-ops-ssh.sh magpie gwkey add MacBook   # 生成 gateway key（只打印一次）
```

然后让用户在本机 magpie → 供应商 → 添加 → **Remote magpie**：接口地址 `http://127.0.0.1:3426`，API 密钥填生成的 `sk-magpie-key-...`；可选勾「带上它那边的供应商（穿透）」。关闭隧道：`magpie-gateway-tunnel.sh stop`。

> 与「另一个 MAGPIE」的区别：那个连 3430 管理 Web UI；这个连 3425 当模型上游。

## Claude Code 配置：模板化（单一真源）

agent 的 `~agent/.claude/settings.json` 由仓库内模板 `claude/settings.template.json` 渲染，**不要手工编辑 VPS 上的 json**：

```bash
bash scripts/clouddock-ops-ssh.sh claude apply --model 'group/free[1m]'   # 按模板收敛
bash scripts/clouddock-ops-ssh.sh claude set-model 'group/never-stuck[1m]' # 只换模型
bash scripts/clouddock-ops-ssh.sh claude show                             # 看当前矩阵
bash scripts/clouddock-ops-ssh.sh claude doctor                           # 自检
```

- 模板占位符：`__MODEL__`（模型全名，含 `[1m]`）、`__MODEL_BASE__`（去掉 `[1m]` 的部分，用于 `CLAUDE_CODE_MODEL_CAPABILITIES`）、`__BASE_URL__`（`http://127.0.0.1:3425`）、`__GATEWAY_KEY__`（`deploy/.env` 的 `MAGPIE_GATEWAY_KEY`）。
- `apply` 保留：`GH_TOKEN`、网关 key（模板不含密钥）、用户自行追加的 env；丢弃已知冲突的遗留键 `ANTHROPIC_MODEL` / `ANTHROPIC_AUTH_TOKEN`。
- 模板刻意**不含**本机专属项：`statusLine`（ccline 二进制）、`extraKnownMarketplaces`（本机插件市场）、代理变量；`teammateMode: tmux` 需 VPS 装了 tmux，`claude doctor` 会报。
- 改模板 → `git commit/push` → `upgrade` → `claude apply` 才是完整落地链路。
- 启动方式：agent 用户执行 `agent-session`（`/usr/local/bin/agent-session`，由 bootstrap `07-agent-tools.sh` 随 `upgrade` 安装）选目录后启动；候选 `~/projects/*` 与 `~` 下 3 层 git 仓库，`--list` 纯文本列候选。`claude doctor` 的 `agent_projects` 字段可直接看当前候选。

## 安全边界（必须遵守）

- 白名单仅放行上述子命令；`uninstall` 不在白名单，需用户人工执行 `bash /opt/clouddock/uninstall.sh`。
- `env set` 仅允许白名单键；密钥优先用 `--stdin`；拒绝日志会自动脱敏（值不进 syslog）。
- `up/stop/pull` 只影响目标服务；`apply` 才是全量，非必要不用。
- `tools ensure` 是受控安装：只放行 `tmux`，走 Debian 官方 apt 源，不接受任意包名。
- 专用 key 无 pty / agent-forwarding；端口转发仅放行 `permitopen="127.0.0.1:3430"`（magpie Web）与 `permitopen="127.0.0.1:3425"`（magpie 网关），其余目标一律拒绝；即使提示词被注入也越不过白名单。
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
./clouddock claude
./clouddock claude apply --model 'group/free[1m]'
./clouddock claude set-model 'group/free[1m]'
./clouddock claude doctor
./clouddock tools ensure tmux
```
