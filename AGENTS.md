# AGENTS.md — clouddock 项目级约束（跨 Agent 单一真源）

## 安装 / 下载源铁律

所有软件、运行时、镜像、工具、CLI 的安装，必须同时满足两点：

1. **来源**：官方或可信渠道（不引入第三方镜像站/非官方源）。
2. **方式未过时**：必须是该渠道**当前推荐、仍受支持**的安装方式；已被官方标记 `deprecated` / 进入维护模式的方式一律不用。

落地要求：动手安装前，先查官方文档核实「当前推荐方式」；拿不准就搜索确认，不凭记忆直接用老命令。

### 反面范例（禁止）

- ❌ Claude Code：`npm install -g @anthropic-ai/claude-code`（npm 通道已进入维护/废弃状态）

### 正面范例（推荐）

- ✅ Claude Code：官方原生安装器 `curl -fsSL https://claude.ai/install.sh | bash`（官方 Recommended，自动后台更新）
- ✅ 本项目既有实践：OpenResty 固定官方源稳定版、Docker 官方 apt 源、acme.sh 官方安装脚本

## 关联

- README「安全建议」的「下载源」条目与本约束一致。
- 新增服务镜像同样遵循：优先官方 `:latest` 或固定可信 tag，不引入第三方镜像加速。
