# 模型路由：手机端切换模型报「找不到模型」

记录 Claude Code 经 magpie 网关（第三方 Anthropic 兼容端点）时，**手机远程控制端切换模型导致 404 unknown model** 的成因、两套解法与验证方式。

## 症状

手机端（Happy / Paseo 等）把模型切到 Anthropic 官方具体模型（如 `claude-opus-5`）后，发消息报：

```
There's an issue with the selected model (claude-opus-5). It may not exist or you may not have access to it.
```

magpie 日志同时出现：

```
gateway: claude's call to claude-opus-5 on (none) failed: 404 after 2.017s: unknown model (and 25 times more like it)
```

## 根因

`ANTHROPIC_DEFAULT_SONNET_MODEL` / `_OPUS_` / `_HAIKU_` 这组映射**只对 tier 别名生效**（`sonnet` / `opus` / `haiku`）。手机端切换时下发的是**具体模型 ID**，Claude Code 视为「用户显式指定」，不再查映射，原样发给网关；magpie 里没有这个模型（`on (none)`），于是 404。

`[1m]` 是 Claude Code 侧的 1M 上下文标记，不会到达网关：`group/free[1m]` 在网关上实际是 `group/free`。

责任分层：

| 层 | 职责 | 实际行为 |
| --- | --- | --- |
| 遥控端（Happy / Paseo） | 展示模型清单、透传所选模型 | Happy 用内置清单（含 Anthropic 官方 ID），原样透传 |
| Claude Code（harness） | tier 别名解析 | 只解析 `sonnet/opus/haiku`；具体 ID 直通 |
| magpie（网关） | 模型名 → 供应商/路由组 | 官方**无**模型重定向能力（`magpie model id` 只能做供应商内改名，不能指向 `group/<id>`） |

> 官方 Reference 明确：没有 alias / `mapping` / `redirect` 配置项，`group/<id>` 只能以 `group/<id>` 形式访问。所以重定向只能在网关侧用插件实现，或在客户端侧收紧清单。

## 方案 A：网关兜底（magpie 插件）

优点：与客户端无关，任何遥控端误切都不会报错。缺点：依赖插件（社区包或自写代码）。

### A-1 当前采用：`@magpie-community/middleware-model-map`

已手动安装。它把请求体里的 `model` 按映射表改写后再转发，回复仍以请求名返回。

```bash
# 插件状态（应显示 model-map on）
docker exec magpie magpie plugin list

# 设置/更新映射表（示例：把所有会被选中的 Anthropic 具体 ID 指向路由组）
docker exec magpie magpie plugin options model-map '{"mapping":{
  "claude-opus-5":"group/free",
  "claude-sonnet-4-5":"group/free",
  "claude-haiku-4-5":"group/free"
}}'
```

**固有局限：只能精确枚举**。遥控端清单里出现任何没写进 `mapping` 的名字（新版本、带日期后缀的 `claude-sonnet-4-5-20250929` 等）仍会 404。因此：

- 升级 Claude Code / 遥控端后，先跑一次 `agent sessions --errors` 看有没有新模型名报错；
- 有则补进 `mapping`；
- 若嫌维护麻烦，改用 A-2 的前缀匹配写法。

回滚：在 magpie Web UI → Plugins 关掉该插件，或 `docker exec magpie magpie plugin remove model-map`（以实际 CLI 子命令为准）；必要时 `docker restart magpie`。

### A-2 备选：自写 `onRequest` 中间件（前缀匹配，一次覆盖所有变体）

把下列文件放到宿主 `/opt/clouddock-data/magpie/plugins/`（容器内即 `/config/plugins/`，compose 已挂载 `/opt/clouddock-data/magpie:/config`），然后 `docker exec magpie magpie plugin add /config/plugins/anthropic-alias.middleware.js`：

```js
// anthropic-alias.middleware.js
// 把 Anthropic 官方模型名（claude-opus-5 / claude-sonnet-4-5-* / claude-haiku-* …）重定向到路由组
const TARGET = "group/free";
const RE = /^claude-(opus|sonnet|haiku|3)[-.]/i;

export function onRequest(body) {
  const m = typeof body?.model === "string" ? body.model : "";
  if (!m || m.includes("/")) return;            // group/xxx、provider/model 一律不动
  const base = m.replace(/\[[^\]]*\]$/, "");    // 兜底剥离 [1m] 之类后缀
  if (!RE.test(base)) return;                   // 非 Anthropic 官方名不碰
  return { ...body, model: TARGET };
}
```

注意点：

- 钩子抛错/超时会**保持原请求**，不会阻断业务；
- 若将来真的接入官方 Claude 供应商，用带前缀的形式（`anthropic/claude-opus-5`）绕开改写；
- 改写只换模型名，不动 `anthropic-beta`、thinking、effort 等参数。

## 方案 B：客户端收紧模型清单

优点：物理上不给误选机会，无需网关插件。缺点：只对支持自定义清单的遥控端有效。

### B-1 Paseo（支持）

Paseo 有两层：

1. **Claude settings 发现**：内置 `claude` provider 会读 `~/.claude/settings.json` 的顶层 `model` 与 `env` 下 `ANTHROPIC_MODEL`、`ANTHROPIC_SMALL_FAST_MODEL`、`ANTHROPIC_DEFAULT_FABLE_MODEL`、`ANTHROPIC_DEFAULT_OPUS_MODEL`、`ANTHROPIC_DEFAULT_SONNET_MODEL`、`ANTHROPIC_DEFAULT_HAIKU_MODEL`，追加到模型列表。所以 `group/free[1m]` 会自动出现。
2. **`models` / `additionalModels` 覆盖**：`models` **整体替换**列表（第一方模型与 settings 发现项都不再出现）；`additionalModels` 只追加/改标签。

要把清单收成一个选项，在 `~/.paseo/config.json` 覆盖内置 provider（覆盖已打包 provider 时省略 `extends`）：

```json
{
  "agents": {
    "providers": {
      "claude": {
        "models": [
          { "id": "group/free[1m]", "label": "免费路由组（magpie）", "isDefault": true }
        ]
      }
    }
  }
}
```

改完 `paseo reload` 生效（新 agent 无需重启）。注意 Paseo 同样**不做重定向**：显式模型 ID 原样传给 Claude Code（官方原文 "passed unchanged"），写错名字照样 404。

相关社区插件：`magpie plugin add magpie-paseo` 会写入 `paseo-magpie` profile（`extends: claude` + `ANTHROPIC_BASE_URL` + magpie 模型目录）。属早期版本（0.1.x，单人维护，作者自述未跑过端到端真实会话），启用前备份 `~/.paseo/config.json` 并先做一次实测。

### B-2 Happy（不支持）

Happy 的模型清单由客户端内置，`~/.happy/settings.json` 只存 UI/设备状态（`schemaVersion` / `onboardingCompleted` / `machineId`），没有模型清单配置位。`happy config set model <name>` 能设默认值（写成 `sonnet` 这类 tier 也会被 Claude Code 正确解析），但手机端点一次具体模型就会被覆盖回 `claude-opus-5`。

因此 Happy 侧只能：① 手机端只选 `group/free[1m]`；② 等上游支持自定义清单/读 harness picker；③ 靠方案 A 兜底。

## 两种方案的关系

不互斥，可叠加：

| 组合 | 效果 |
| --- | --- |
| 只有 A | 误切不报错，但请求名五花八门，日志里看不出一致性 |
| 只有 B（Paseo） | 手机上只有一个选项，但换遥控端/换机器仍可能踩坑 |
| A + B | 清单收紧 + 网关兜底，最稳 |

选择建议：用 Paseo 就先做 B-1（零插件依赖）；用 Happy 或需要跨客户端兜底就做 A；两者一起上也不冲突。

## 验证

```bash
# 1) 直接打网关，模拟遥控端切模型后的请求（key 从 deploy/.env 读，不回显）
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3425/v1/messages \
  -H "x-api-key: $(grep '^MAGPIE_GATEWAY_KEY=' /opt/clouddock/deploy/.env | cut -d= -f2-)" \
  -H 'anthropic-version: 2023-06-01' -H 'content-type: application/json' \
  -d '{"model":"claude-opus-5","max_tokens":8,"messages":[{"role":"user","content":"hi"}]}'
# 期望 200；同时日志应出现 "claude's call to group/free on ..." 而不是 "claude-opus-5 on (none) 404"

# 2) 看网关侧模型名与错误
bash scripts/clouddock-ops-ssh.sh logs magpie --tail=1000 | grep -E "unknown model|failed:"

# 3) 看 Claude Code 会话里的报错文案
bash scripts/clouddock-ops-ssh.sh agent sessions --errors --limit=5

# 4) 看遥控端日志（Happy）
bash scripts/clouddock-ops-ssh.sh agent happy --file=<日志名> --tail=200 --grep=model
```

## 相关命令速查

| 目的 | 命令 |
| --- | --- |
| 看 VPS Claude Code 当前模型矩阵 | `clouddock claude show` |
| 按模板重渲染配置 | `clouddock claude apply --model 'group/free[1m]'` |
| 只换模型（全位点） | `clouddock claude set-model 'group/free[1m]'` |
| magpie 插件状态 | `clouddock magpie plugin list` |
| Claude Code 会话报错 | `clouddock agent sessions --errors` |
| Happy 日志/配置 | `clouddock agent happy --tail=200 [--file=xxx] [--grep=xxx]` |
