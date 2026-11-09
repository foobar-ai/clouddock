# 新增服务指南

本项目采用统一编排与反代入口，新增服务只需三步，不破坏既有环境。

## 前提约定

- 编排文件：`deploy/docker-compose.yml`
- 反代站点：`deploy/openresty/` 下的配置模板（部署后由脚本渲染到 OpenResty `conf/sites/`）
- 数据目录：`/opt/clouddock-data/<service>`（独立于代码目录，代码更新不覆盖）
- 环境变量：统一写入 `deploy/.env`（用户输入与密钥均由部署脚本交互写入）

## 步骤

### 1. 追加服务到 compose

编辑 `deploy/docker-compose.yml`，新增一个 service，注意：

- `ports` 一律绑定 `127.0.0.1`（由 OpenResty 或 SSH 隧道对外，不直接暴露公网）。
- 需要持久化的数据挂到 `/opt/clouddock-data/<service>`。
- 若容器使用非 root 用户，先 `chown` 对应 uid。

```yaml
  my-service:
    image: official/image:tag
    container_name: my-service
    restart: unless-stopped
    ports:
      - "127.0.0.1:8080:8080"
    volumes:
      - /opt/clouddock-data/my-service:/data
```

### 2. 新增反代站点（如需域名访问）

在 `deploy/openresty/` 新建 `my-service.conf`（参考 `new-api-https.conf`，`__DOMAIN__` 为渲染占位符），并在 `06-openresty-site.sh` 中追加渲染与启用逻辑。

### 3. 应用变更

在 VPS 上执行：

```bash
cd /opt/clouddock/deploy
docker compose up -d          # 启动新容器
# 如改动了反代配置：
# bash /opt/clouddock/bootstrap/steps/06-openresty-site.sh
```

## 幂等提示

- 各阶段脚本以「是否已就绪」为判据，重跑安全。
- 密钥已生成则保留；删除 `deploy/.env` 中的对应行才会重新生成。
- 数据目录 `/opt/clouddock-data` 独立于代码目录，`git pull` 更新代码不会覆盖数据。
