# 新增服务指南

本项目采用「基础设施与服务分离」结构，新增服务只需在 `services/` 下加一个目录，不破坏既有环境。

## 结构约定

- 服务编排：`services/<name>/compose.yml`（该服务的 compose 片段）
- 服务初始化：`services/<name>/deploy.sh`（compose up 后执行，如就绪检查、生成密钥）
- 反代站点：`openresty/sites/<name>.conf`（如需域名访问）
- 数据目录：`/opt/clouddock-data/<name>`（独立于代码目录）
- 环境变量：`deploy/.env`（变量带 `<服务>_` 前缀，如 `NEWAPI_` / `MAGPIE_`）

> `bootstrap/steps/05-services.sh` 会自动遍历 `services/*/compose.yml` 聚合启动，并执行各 `services/*/deploy.sh`。新增服务无需改动该脚本。

## 步骤

### 1. 新建服务目录与 compose 片段

```bash
mkdir -p services/my-service
```

创建 `services/my-service/compose.yml`，注意：

- `ports` 一律绑定 `127.0.0.1`（由 OpenResty 或 SSH 隧道对外，不直接暴露公网）。
- 需要持久化的数据挂到 `/opt/clouddock-data/my-service`。
- 容器若用非 root 用户，记得在 deploy.sh 里 `chown` 对应 uid。

```yaml
services:
  my-service:
    image: official/image:tag
    container_name: my-service
    restart: on-failure:3
    ports:
      - "127.0.0.1:8080:8080"
    volumes:
      - /opt/clouddock-data/my-service:/data
```

### 2. 新建 deploy.sh（可选）

创建 `services/my-service/deploy.sh`，做 compose up 之后的初始化（数据目录、就绪检查、生成密钥等）：

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../bootstrap/lib.sh"

mkdir -p "$DATA_DIR/my-service"
# ... 就绪检查 / 初始化逻辑 ...
```

### 3. 新增反代站点（如需域名访问）

在 `openresty/sites/` 新建 `my-service.conf`（参考 `new-api-https.conf`，`__DOMAIN__` 为渲染占位符），并在 `bootstrap/steps/06-openresty-site.sh` 中追加渲染与启用逻辑。

### 4. 应用变更

在 VPS 上执行：

```bash
cd /opt/clouddock
bash bootstrap/bootstrap.sh      # 重新跑一遍（幂等，会自动聚合启动新服务）
# 或只拉起新服务，不动其他服务：
./clouddock up <name>
```

## 幂等提示

- 各阶段脚本以「是否已就绪」为判据，重跑安全。
- 密钥已生成则保留；删除 `deploy/.env` 中的对应行才会重新生成。
- 数据目录 `/opt/clouddock-data` 独立于代码目录，`git pull` 更新代码不会覆盖数据。
