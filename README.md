# clouddock — 云主机一键 DIY AI 云环境

把一台 Debian 12 云主机锻造成个人 AI 云环境：一键完成系统准备、Docker、HTTPS 网关、new-api 与 magpie 部署，并打通本地 Claude Code 经 magpie 调用的双链路。当前已在华为云 Flexus L 上验证。

项目开源，通过 `curl | bash` 一条命令在 VPS 上完成部署，不依赖本地操作系统与 `rsync` 等工具（Windows 也可用）。

## 架构

```
本地 Claude Code ──链路A(SSH隧道 3425,主用)──> magpie(127.0.0.1:3425/3430) ──> 订阅池上游
                 └─链路B(HTTPS 域名,兜底)──> OpenResty(443) ──> new-api(3000) ──渠道转发──> magpie
```

- **new-api**：`calciumion/new-api`，端口 3000，Supabase PostgreSQL + Upstash Redis（托管），HTTPS 域名对外。
- **magpie**：`ghcr.io/yetone/magpie`，网关 3425 / Web UI 3430，仅绑定 127.0.0.1。
- **OpenResty**：宿主机 80/443 反代 + TLS 终结。
- **acme.sh**：Let's Encrypt 免费证书，独立签发、自动续期。

## 前置条件

> 还没有云主机？华为云国际版 Flexus L 实例：[产品介绍](https://www.huaweicloud.com/intl/zh-cn/product/flexus-l.html) · [立即购买](https://console.huaweicloud.com/smb/v2/?region=cn-east-3#/create/hecs-light?image_name=Debian&plan=basic_v13&resource_spec_code=ahf.large.025.30m.linux&period=month_9)（本项目验证环境为新加坡区域）

1. 云主机：Debian 12（已在华为云 Flexus L 验证），可 SSH 登录（root 或 sudo 用户）。
2. 安全组/防火墙放行：**22 / 80 / 443**（80/443 用于证书签发与 HTTPS）。
3. 域名：A 记录已解析到云主机公网 IP（HTTP-01 证书方式必需）。
4. 云主机已装 `git`、`curl`（安装入口会自动补装）。

## 快速开始

SSH 登录云主机（`ssh root@<地址>`），然后以 root 执行：

```bash
curl -fsSL https://raw.githubusercontent.com/foobar-ai/clouddock/main/install.sh | bash
```

> fork 后自用，可指定自己的仓库地址：
> ```bash
> curl -fsSL <install.sh 的 raw 地址> | REPO_URL=https://github.com/<你的用户名>/clouddock.git bash
> ```

脚本会**交互询问**以下配置（均为用户输入，请提前准备；其余密钥由脚本自动生成）：

| 配置项 | 用途 | 是否必填 |
| --- | --- | --- |
| `NEWAPI_DOMAIN` | new-api 对外域名（HTTPS 证书 + 反代，建议子域名如 `api.xxx.com`） | 必填 |
| `CERT_MODE` | 证书验证方式：`http`（HTTP-01，推荐）/ `dns`（DNS API） | 默认 `http` |
| `TRAFFIC_QUOTA_GB` | 月流量包额度（用于告警阈值与 tx 对账，以华为云为例） | 默认 `1024` |
| `NEWAPI_SQL_DSN` | Supabase PostgreSQL 连接串（`postgresql://...`） | 必填 |
| `NEWAPI_REDIS_CONN_STRING` | Upstash Redis 连接串（`rediss://...`） | 可选（留空用内存缓存） |
| `DNS_PROVIDER` | acme.sh DNS API 标识（如 `dns_dp` / `dns_cf`） | 仅 `CERT_MODE=dns` 必填 |
| `MAGPIE_WEB_KEY` | magpie Web UI 访问密钥（`?k=`，**≥16 字符**）；不传则自动随机生成 | 可选 |

> `CERT_MODE=dns` 时，还需在 VPS 的 `deploy/dnsapi.env` 写入 DNS API 凭证（每行一条 `export KEY=VALUE`）；无交互部署可直接用环境变量 `DNS_API_ENV` 传入（见下文「证书与 Cloudflare 代理」）。

### 无交互部署（可选）

不想逐项回答交互提问时，可把上表配置项作为**环境变量**随 `curl | bash` 传入，实现一条命令一步到位：

```bash
curl -fsSL https://raw.githubusercontent.com/foobar-ai/clouddock/main/install.sh | \
  NEWAPI_DOMAIN=api.xxx.com \
  CERT_MODE=http \
  TRAFFIC_QUOTA_GB=1024 \
  NEWAPI_SQL_DSN='postgresql://postgres.xxx:password@host:5432/postgres' \
  NEWAPI_REDIS_CONN_STRING='rediss://:password@host:6379' \
  MAGPIE_WEB_KEY=你的Web密钥 \
  bash
```

所有会询问的配置项（含 `TRAFFIC_QUOTA_GB`、`NEWAPI_REDIS_CONN_STRING`）都通过环境变量提供时**全程零询问**；缺了哪项就只对缺的那项交互询问（在 SSH 会话中仍可正常输入）。`NEWAPI_REDIS_CONN_STRING` 传空串 `''` 表示「不使用 Redis」，也会干净跳过询问。`MAGPIE_WEB_KEY` 传值则直接写入 `.env`（固定 Web UI 密钥），不传则自动随机生成。

取值优先级为：**`deploy/.env` 已有值 > shell 环境变量 > 交互询问**。所有值最终都会写入 `deploy/.env`，因此重跑安装脚本时不会再重复询问（幂等），临时改配置可在 VPS 上直接编辑 `/opt/clouddock/deploy/.env`。

> 安全提示：连接串含密钥，会进入进程环境变量与 shell 历史。仅建议在个人 root VPS 上使用；更在意痕迹可用预置 `.env` 方式——先 `git clone` 仓库到 VPS，手动写好 `deploy/.env`（该文件被 `.gitignore` 忽略），再执行 `bash /opt/clouddock/bootstrap/bootstrap.sh`。

### VPS 上的 Claude Code + Happy（无交互，可选）

在 VPS 上装一个「远程 Claude Code agent」并用手机（Happy Coder）控制，后端走本机 magpie。一条命令、无交互（在 VPS 以 root 执行）：

```bash
curl -fsSL https://raw.githubusercontent.com/foobar-ai/clouddock/main/scripts/install-claude-vps.sh | \
  GH_TOKEN=github_pat_xxx \
  GIT_USER_NAME='你的名字' \
  GIT_USER_EMAIL='你的ID+username@users.noreply.github.com' \
  bash
```

> `GH_TOKEN` 是**认证**（能否 push）；`GIT_USER_NAME` / `GIT_USER_EMAIL` 是**提交身份**（commit 作者）。两者都要配，否则 `git commit` 会因缺身份报 `Please tell me who you are`。email 建议用 GitHub noreply 邮箱（GitHub → Settings → Emails 可查），提交能关联到你的账号、又不暴露真实邮箱。

`GH_TOKEN` 是给 agent 用的 GitHub 细粒度 PAT（fine-grained token），最小权限配置：

| 项 | 设置 |
| --- | --- |
| Repository access | **Only select repositories** → 选本仓库（勿选 All） |
| Contents | Read and write |
| Pull requests | Read and write |
| Expiration | 90 天 |
| 其余 | `Secrets` / `Administration` / `Workflows` / `Actions` 一律不勾 |

装完后（需你本人在 VPS 终端操作、配手机）：

```bash
su - agent -c 'happy auth login'   # 终端出二维码，手机 Happy App 扫
su - agent -c 'happy claude'       # 启动，手机接管
```

> 安全：`GH_TOKEN` 只写入 `~agent/.claude/settings.json`（权限 600），不进 git；token 到期记得轮换。

#### Claude Code 配置模板（单一真源）

agent 的 `~/.claude/settings.json` 不手写，由仓库模板 `claude/settings.template.json` 渲染（模型矩阵、effort、Agent Teams、compact 窗口等都在模板里，可版本管理、可回滚）：

```bash
bash scripts/clouddock-ops-ssh.sh claude                              # 看当前模型矩阵（密钥打码）
bash scripts/clouddock-ops-ssh.sh claude apply --model 'group/free[1m]' # 按模板收敛
bash scripts/clouddock-ops-ssh.sh claude set-model 'group/free[1m]'     # 只换模型，不动其他配置
bash scripts/clouddock-ops-ssh.sh claude doctor                       # 自检（claude/happy/tmux/settings/网关连通）
```

- `apply` 保留模板外的敏感与环境项（`GH_TOKEN`、`deploy/.env` 的 `MAGPIE_GATEWAY_KEY`、你自行追加的 env），并丢弃会与模型矩阵冲突的遗留键 `ANTHROPIC_MODEL` / `ANTHROPIC_AUTH_TOKEN`。
- 模板不含本机专属项：`statusLine`（ccline 二进制）、`extraKnownMarketplaces`（本机插件市场）、代理变量（`HTTPS_PROXY` 等）。`teammateMode: tmux` 需 VPS 装有 tmux，`claude doctor` 会提示。
- 模型名支持 `group/xxx[1m]` 形式；`CLAUDE_CODE_MODEL_CAPABILITIES` 自动取去掉 `[1m]` 的基础名（如 `group/free=effort`）。

### 证书与 Cloudflare 代理（小黄云）

若域名开启了 Cloudflare 代理（橙云），HTTP-01 的签发与**自动续期**都会被 CF 边缘节点拦截：只要开了「Always Use HTTPS / Automatic HTTPS Rewrites」，HTTP 验证请求会被 301 到 HTTPS，导致验证失败。两种处理方式：

**方案 A（推荐）：DNS-01 验证，橙云随便开**

DNS 验证不碰 80 端口、不受 CF 代理影响，续期永远不受干扰。无交互部署：

```bash
curl -fsSL https://raw.githubusercontent.com/foobar-ai/clouddock/main/install.sh | \
  NEWAPI_DOMAIN=api.xxx.com \
  CERT_MODE=dns \
  DNS_PROVIDER=dns_cf \
  DNS_API_ENV=$'export CF_Token=你的API_Token\nexport CF_Account_ID=你的Account_ID\nexport CF_Zone_ID=你的Zone_ID' \
  TRAFFIC_QUOTA_GB=1024 \
  NEWAPI_SQL_DSN='postgresql://...' \
  NEWAPI_REDIS_CONN_STRING='' \
  bash
```

> `dns_cf` 也支持全局密钥方式（`CF_Key` + `CF_Email`）；其他 DNS 服务商把 `DNS_PROVIDER` 换成对应标识、`DNS_API_ENV` 换成对应的 `export KEY=VALUE` 多行即可（如 `dns_dp` 用 `DP_Id`/`DP_Key`）。

**方案 B：保持 HTTP-01，关掉 CF 的强制 HTTPS**

先在 Cloudflare → SSL/TLS → Edge Certificates 关闭 Always Use HTTPS 与 Automatic HTTPS Rewrites，再按普通 HTTP-01 无交互部署（证书续期沿用同一验证路径，故该开关需**一直保持关闭**）：

```bash
curl -fsSL https://raw.githubusercontent.com/foobar-ai/clouddock/main/install.sh | \
  NEWAPI_DOMAIN=api.xxx.com \
  CERT_MODE=http \
  TRAFFIC_QUOTA_GB=1024 \
  NEWAPI_SQL_DSN='postgresql://...' \
  NEWAPI_REDIS_CONN_STRING='' \
  bash
```

> 橙云下存在两套证书：客户端看的是 CF 自签的 Universal SSL，acme.sh 管的是 CF↔源站之间的源站证书（此时 CF 的 SSL/TLS 模式需设为 `Full (strict)`）。源站证书续期失败不会立刻暴露，但到期后会埋雷，建议方案 A 一劳永逸。

### 切换证书验证方式（http ↔ dns）

已用 HTTP-01 部署、想改成 DNS-01（或反向）时，改 `.env` 后强制重签一次即可：

```bash
cd /opt/clouddock

# 1) 改 .env（http → dns）
sed -i 's|^CERT_MODE=.*|CERT_MODE=dns|' deploy/.env
grep -q '^DNS_PROVIDER=' deploy/.env || echo 'DNS_PROVIDER=dns_cf' >> deploy/.env

# 2) 写入 CF 凭证
cat > deploy/dnsapi.env <<'EOF'
export CF_Token=xxx
export CF_Account_ID=xxx
export CF_Zone_ID=xxx
EOF

# 3) 强制重签（CERT_FORCE=1，绕过「证书已存在」的幂等检查）
CERT_FORCE=1 bash bootstrap/steps/04-cert.sh
```

重签后 acme.sh 会记住新验证方式，后续自动续期也按新方式走（`dns → http` 反向同理，改 `CERT_MODE=http` 后 `CERT_FORCE=1` 重签即可）。

随后自动完成：系统准备 → Docker → OpenResty → 证书签发 → 启动服务 → 启用 HTTPS。

> 重复执行安全：各阶段幂等，命中「已就绪」即跳过；密钥已生成则保留不覆盖。

## 卸载

在 VPS 以 root 执行一键卸载脚本，恢复到部署前状态：

```bash
bash /opt/clouddock/uninstall.sh              # 卸载全部，含数据目录 /opt/clouddock-data 与部署生成的 swap
KEEP_DATA=1 bash /opt/clouddock/uninstall.sh  # 保留业务数据目录（new-api 数据库 / magpie 配置）
```

会移除：OpenResty、Docker、acme.sh、证书、容器与镜像、部署目录 `/opt/clouddock`；保留 `curl`/`git`/`vnstat` 等非 clouddock 专属的系统工具，不影响重装。

## AI 运维（可选）

部署完成后，可让 AI（Claude Code / CodeBuddy）通过专用 SSH 白名单通道安全地执行运维（状态巡检 / **单服务启停与更新** / **精确改 env 只重建目标服务** / OpenResty 重载 / magpie 网关密钥 / 证书续期与切换 / 升级 / 日志 / 安装新服务）：

```bash
# 本地仓库一次性初始化：生成专用 key + 推送白名单 + 装定时巡检
bash scripts/install-ops.sh <VPS地址>
# 之后 AI 即可自然语言触发，底层调用：
bash scripts/clouddock-ops-ssh.sh services                     # 服务清单
bash scripts/clouddock-ops-ssh.sh up magpie                    # 只重建 magpie
bash scripts/clouddock-ops-ssh.sh env set MAGPIE_WEB_KEY=新值  # 只重建 magpie
bash scripts/clouddock-ops-ssh.sh reload                       # 重载 OpenResty
```

详见 `docs/ai-ops.md`（命令参考 / 安全模型）与 `skills/clouddock-ops/SKILL.md`（AI 调用约定）。

> 仓库版 skill 更新后，运行 `bash scripts/sync-skill.sh` 同步到 CodeBuddy 本地 `.codebuddy/skills/`（该目录被 gitignore）。

## 安全建议

1. **公网最小暴露**：安全组仅放行 22 / 80 / 443；magpie 的 3425/3430 只绑定 127.0.0.1，经 SSH 隧道访问，不暴露公网。
2. **云主机加固（可选）**：建议使用密钥登录，并在确认无误后关闭密码登录（编辑 `/etc/ssh/sshd_config`，设置 `PasswordAuthentication no` 后 `systemctl restart ssh`）。
3. **下载源**：所有软件与镜像均来自官方/可信渠道，且必须是该渠道当前推荐、未过时的安装方式（如 Claude Code 用官方原生安装器 `curl -fsSL https://claude.ai/install.sh | bash`，不用已废弃的 npm 方式）；不引入第三方镜像站。详见 `AGENTS.md`。

## 目录结构

```
clouddock/
├── install.sh                     # curl | bash 入口（clone 仓库 + 执行 bootstrap）
├── uninstall.sh                   # 一键卸载
├── clouddock                      # AI 运维 CLI 主入口（status/renew/upgrade/...）
├── bootstrap/                     # 部署编排
│   ├── lib.sh                     #   公共函数库（含 svc_names）
│   ├── bootstrap.sh               #   总控：交互收集 + 生成密钥 + 调度阶段
│   └── steps/                     #   阶段脚本（幂等）
│       ├── 00-prereq.sh           #   系统准备 / vnstat / swap
│       ├── 01-docker.sh
│       ├── 02-openresty.sh
│       ├── 03-acme.sh
│       ├── 04-cert.sh
│       ├── 05-services.sh         #   聚合启动所有服务
│       └── 06-openresty-site.sh
├── ops/                           # 运维脚本（clouddock 子命令实现）
│   ├── lib.sh                     #   运维公共库（JSON/脱敏）
│   ├── shell.sh                   #   SSH 白名单受限入口
│   ├── status.sh / health.sh      #   状态巡检 / 健康快照
│   ├── renew.sh / upgrade.sh      #   续期 / 升级
│   ├── apply.sh / restart.sh / logs.sh
│   ├── claude.sh                  #   Claude Code 配置（模板渲染/改模型/自检）
│   └── cron-install.sh            #   定时巡检安装
├── services/                      # 服务定义（每服务一目录，可扩展）
│   ├── new-api/
│   │   ├── compose.yml            #   new-api 编排（Supabase + Upstash）
│   │   └── deploy.sh              #   就绪检查
│   └── magpie/
│       ├── compose.yml            #   magpie 编排
│       └── deploy.sh              #   就绪检查 + gateway key
├── deploy/                        # 配置
│   └── .env.example               #   环境变量模板
├── claude/                        # Claude Code 配置模板
│   └── settings.template.json     #   agent 的 ~/.claude/settings.json 单一真源
├── openresty/                     # 反代配置
│   ├── nginx.conf                 #   OpenResty 主配置
│   └── sites/                     #   站点配置
│       ├── new-api-http.conf      #   HTTP 校验阶段
│       └── new-api-https.conf     #   HTTPS 代理阶段
├── scripts/                       # 本地辅助脚本
│   ├── claude-code-tunnel.sh      #   本地 SSH 隧道（链路 A）
│   ├── add-service.sh             #   新服务脚手架
│   ├── install-ops.sh             #   一键打通 AI 运维白名单通道
│   └── clouddock-ops-ssh.sh       #   本地调用 wrapper
├── skills/clouddock-ops/SKILL.md  # Agent Skill（AI 运维调用约定）
└── docs/
    ├── claude-code-local.md       # 本地 Claude Code 双链路接入说明
    ├── add-service.md             # 新增服务指南
    └── ai-ops.md                  # AI 运维指南
```

## 成本与流量管控

### 计费规则（以华为云 Flexus L 为例，已查证官方文档）

- **仅出网流量（服务器流出，tx）计费，入网（rx）免费**；流量包即「出网流量包」。其他云厂商计费口径可能不同，请以各自文档为准。
- 华为云 Flexus L 含 **1024GB/月流量包**，按月重置、清零不累计；超包后出网流量按量计费，欠费进入宽限期→保留期→释放公网 IP。
- magpie 中转场景的计费流量 ≈「发给上游模型的请求」+「返回本地的响应」之和（两段均为出网）；本地→云主机 与上游→云主机 的入网免费。
- 1024GB/月对个人重度使用（约 1–5GB/天出网，月 30–150GB）余量充足，但必须可观测。

### 落地措施

1. **流量监控**：已安装 `vnstat`，对账**只看 tx（出网）**（`vnstat -m` 的 tx 列）。
2. **告警阈值**：部署完成会打印按额度计算的 70% / 90% 阈值，请在云厂商控制台配置流量告警。
3. **硬边界**：不启用对象存储、日志服务、短信、按量快照等增值计费项；确认未对系统盘开启自动云备份/快照策略。

## 常见问题

- **Docker 拉取慢**：新加坡直连官方 registry 通常够快，默认不配第三方加速。若实测异常，优先重试（断点续传）；仍不行可考虑云厂商官方镜像加速（如华为云 SWR 个人版，有免费额度）。
- **HTTP-01 证书签发失败**：确认域名 A 记录已解析到云主机、安全组放行 80/443；若开了 Cloudflare 橙云，见上文「证书与 Cloudflare 代理」；仍失败可改用 DNS API 方式（`CERT_MODE=dns` + `deploy/dnsapi.env`）。
- **重跑是否安全**：各阶段幂等，命中「已就绪」即跳过；密钥已生成则保留不覆盖。

## 文档

- 架构说明：见 `docs/architecture.md`。
- 本地 Claude Code 接入：见 `docs/claude-code-local.md`。
- 新增服务：见 `docs/add-service.md`。
- AI 运维：见 `docs/ai-ops.md`（及 `skills/clouddock-ops/SKILL.md`）。
- 项目计划（设计决策与背景）：见 `docs/plan.md`。
