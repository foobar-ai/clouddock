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

> 还没有云主机？华为云国际版 Flexus L 实例：[产品介绍](https://www.huaweicloud.com/intl/zh-cn/product/flexus-l.html) · [立即购买](https://console-intl.huaweicloud.com/smb/?locale=zh-cn#/create)（本项目验证环境为新加坡区域）

1. 云主机：Debian 12（已在华为云 Flexus L 验证），可 SSH 登录（root 或 sudo 用户）。
2. 安全组/防火墙放行：**22 / 80 / 443**（80/443 用于证书签发与 HTTPS）。
3. 域名：A 记录已解析到云主机公网 IP（HTTP-01 证书方式必需）。
4. 云主机已装 `git`、`curl`（安装入口会自动补装）。

## 快速开始

SSH 登录云主机（`ssh root@<地址>`），然后以 root 执行：

```bash
curl -fsSL https://raw.githubusercontent.com/<你的用户名>/<你的仓库>/main/install.sh | bash
```

> 未 fork 前，可先 clone 后指定仓库地址：
> ```bash
> curl -fsSL <install.sh 的 raw 地址> | REPO_URL=https://github.com/<用户名>/<仓库>.git bash
> ```

脚本会**交互询问**以下配置（均为用户输入，请提前准备；其余密钥由脚本自动生成）：

| 环境变量 | 用途 | 是否必填 |
| --- | --- | --- |
| `NEWAPI_DOMAIN` | new-api 对外域名（HTTPS 证书 + 反代，建议子域名如 `api.xxx.com`） | 必填 |
| `CERT_MODE` | 证书验证方式：`http`（HTTP-01，推荐）/ `dns`（DNS API） | 默认 `http` |
| `TRAFFIC_QUOTA_GB` | 月流量包额度（用于告警阈值与 tx 对账，以华为云为例） | 默认 `1024` |
| `NEWAPI_SQL_DSN` | Supabase PostgreSQL 连接串（`postgresql://...`） | 必填 |
| `NEWAPI_REDIS_CONN_STRING` | Upstash Redis 连接串（`rediss://...`） | 可选（留空用内存缓存） |
| `DNS_PROVIDER` | acme.sh DNS API 标识（如 `dns_dp` / `dns_cf`） | 仅 `CERT_MODE=dns` 必填 |

> `CERT_MODE=dns` 时，还需在 VPS 的 `deploy/dnsapi.env` 写入 DNS API 凭证（每行一条 `export KEY=VALUE`）。

随后自动完成：系统准备 → Docker → OpenResty → 证书签发 → 启动服务 → 启用 HTTPS。

> 重复执行安全：各阶段幂等，命中「已就绪」即跳过；密钥已生成则保留不覆盖。

## 安全建议

1. **公网最小暴露**：安全组仅放行 22 / 80 / 443；magpie 的 3425/3430 只绑定 127.0.0.1，经 SSH 隧道访问，不暴露公网。
2. **云主机加固（可选）**：建议使用密钥登录，并在确认无误后关闭密码登录（编辑 `/etc/ssh/sshd_config`，设置 `PasswordAuthentication no` 后 `systemctl restart ssh`）。
3. **下载源**：所有软件与镜像均来自官方/可信渠道，不引入第三方镜像站。

## 目录结构

```
clouddock/
├── install.sh                     # curl | bash 入口（clone 仓库 + 执行 bootstrap）
├── bootstrap/                     # 部署编排
│   ├── lib.sh                     #   公共函数库
│   ├── bootstrap.sh               #   总控：交互收集 + 生成密钥 + 调度阶段
│   └── steps/                     #   阶段脚本（幂等）
│       ├── 00-prereq.sh           #   系统准备 / vnstat / swap
│       ├── 01-docker.sh
│       ├── 02-openresty.sh
│       ├── 03-acme.sh
│       ├── 04-cert.sh
│       ├── 05-services.sh         #   聚合启动所有服务
│       └── 06-openresty-site.sh
├── services/                      # 服务定义（每服务一目录，可扩展）
│   ├── new-api/
│   │   ├── compose.yml            #   new-api 编排（Supabase + Upstash）
│   │   └── deploy.sh              #   就绪检查
│   └── magpie/
│       ├── compose.yml            #   magpie 编排
│       └── deploy.sh              #   就绪检查 + gateway key
├── deploy/                        # 配置
│   └── .env.example               #   环境变量模板
├── openresty/                     # 反代配置
│   ├── nginx.conf                 #   OpenResty 主配置
│   └── sites/                     #   站点配置
│       ├── new-api-http.conf      #   HTTP 校验阶段
│       └── new-api-https.conf     #   HTTPS 代理阶段
├── scripts/                       # 本地辅助脚本
│   └── claude-code-tunnel.sh      #   本地 SSH 隧道（链路 A）
└── docs/
    ├── claude-code-local.md       # 本地 Claude Code 双链路接入说明
    └── add-service.md             # 新增服务指南
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
- **HTTP-01 证书签发失败**：确认域名 A 记录已解析到云主机、安全组放行 80/443；仍失败可改用 DNS API 方式（`CERT_MODE=dns` + `deploy/dnsapi.env`）。
- **重跑是否安全**：各阶段幂等，命中「已就绪」即跳过；密钥已生成则保留不覆盖。

## 文档

- 本地 Claude Code 接入：见 `docs/claude-code-local.md`。
- 新增服务：见 `docs/add-service.md`。
