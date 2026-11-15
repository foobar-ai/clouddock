# services/magpie/Dockerfile — 官方镜像 + 命令型 MCP server 需要的运行时
#
# 为什么需要这一层：官方镜像是 Debian 12 slim + bash/curl，容器内没有 node/npx/uv/uvx，
# 导致 Library 里以 `npx …` / `uvx …` 启动的 MCP server 全部报「找不到 npx / uvx」。
# 这里只补运行时，不改 magpie 自身的任何文件；magpie 本体与默认 cmd/entrypoint 完全继承官方镜像。
#
# 渠道约束（见 AGENTS.md）：Node 用 NodeSource 官方源；uv 用 PyPI 官方 wheel；其余走 Debian 官方 apt。
FROM ghcr.io/yetone/magpie:latest

USER root
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg python3 python3-pip \
 && curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && pip3 install --no-cache-dir --break-system-packages uv \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# 官方镜像以非 root 的 65532 运行，装完运行时切回去
USER 65532:65532
