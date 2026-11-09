# 本地 Claude Code 接入说明（双链路）

本地 Claude Code 通过两种链路调用 VPS 上的 magpie 网关，按需选择。

## 前置：获取 magpie gateway key

部署时 `05-services.sh` 会自动生成并写入 `deploy/.env` 的 `MAGPIE_GATEWAY_KEY`。若未自动生成，手动获取：

```bash
# 在 VPS 上执行
docker exec magpie magpie gateway-key add "Laptop"
# 输出形如 sk-magpie-key-xxxx
```

> 该 key 是链路 A/B 共用的调用凭证，请妥善保存。

---

## 链路 A（主用）：SSH 隧道直连 magpie

延迟最低、订阅池/插件能力完整，日常推荐。

### 1. 建立隧道

```bash
bash scripts/claude-code-tunnel.sh <VPS地址> [SSH用户] [SSH端口]
# 保持该终端运行
```

### 2. 配置 Claude Code 环境变量

```bash
export ANTHROPIC_BASE_URL=http://127.0.0.1:3425
export ANTHROPIC_API_KEY=sk-magpie-key-xxxx      # 替换为你的 gateway key
claude
```

或写入 `~/.claude/settings.json`：

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://127.0.0.1:3425",
    "ANTHROPIC_API_KEY": "sk-magpie-key-xxxx"
  }
}
```

### 3. 管理 magpie（可选）

浏览器打开 `http://127.0.0.1:3430/?k=<MAGPIE_WEB_KEY>`（`MAGPIE_WEB_KEY` 在 VPS `deploy/.env` 中）。

---

## 链路 B（兜底）：经 new-api HTTPS

远程无 SSH 隧道时可用，且借 new-api 做统一鉴权/用量日志。注意为「网关套网关」，有两次格式转换，可能损失部分 Claude 高级特性。

### 1. 在 new-api 控制台配置渠道

1. 打开 `https://<你的域名>`，首次访问创建管理员账号并登录。
2. 进入「渠道」→「添加渠道」：
   - 类型：`OpenAI`
   - Base URL：`http://127.0.0.1:3425/v1`
   - 密钥：填 `MAGPIE_GATEWAY_KEY`（同链路 A）
   - 模型：填入你需要路由的模型名
3. 进入「令牌」→ 创建令牌，复制 `sk-` 开头的令牌。

### 2. 配置 Claude Code

```bash
export ANTHROPIC_BASE_URL=https://<你的域名>       # new-api 的 Anthropic 兼容端点
export ANTHROPIC_AUTH_TOKEN=sk-xxxx               # new-api 令牌
claude
```

> new-api 的 Anthropic 兼容端点路径以实际部署为准（常见为根路径或 `/anthropic`），首次连通失败时请在 new-api 控制台/文档确认精确路径。

---

## 两条链路对比

| 维度 | 链路 A（SSH 隧道） | 链路 B（new-api） |
| --- | --- | --- |
| 延迟 | 最低 | 略高（多一跳） |
| 订阅池/插件能力 | 完整 | 可能损失部分高级特性 |
| 依赖 | SSH 隧道常驻 | 仅需公网 HTTPS |
| 鉴权/用量管控 | gateway key | new-api 令牌 + 额度/日志 |
| 适用 | 日常主用 | 远程兜底 |
