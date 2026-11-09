#!/usr/bin/env bash
# uninstall.sh — 一键卸载 clouddock，恢复到部署前状态
# 用法（在 VPS 以 root 执行）：
#   bash /opt/clouddock/uninstall.sh          # 卸载全部（含数据目录与部署时生成的 swap）
#   KEEP_DATA=1 bash /opt/clouddock/uninstall.sh  # 保留业务数据目录 /opt/clouddock-data
set -u

export DEBIAN_FRONTEND=noninteractive

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "[ERR ] 请以 root 运行：sudo -i 后再执行本脚本。"
  exit 1
fi

# 常量（与 bootstrap/lib.sh 保持一致）
INSTALL_DIR="${INSTALL_DIR:-/opt/clouddock}"
DATA_DIR="/opt/clouddock-data"
CERT_DIR="/etc/ssl/clouddock"
ACME_SH_HOME="/root/.acme.sh"
OPENRESTY_PREFIX="/usr/local/openresty/nginx"

echo "== 开始卸载 clouddock =="

# 1. 停止并移除 Docker 容器 / 镜像 / 网络
if command -v docker >/dev/null 2>&1; then
  echo "== 停止并移除容器与镜像 =="
  systemctl start docker 2>/dev/null || true
  docker rm -f new-api magpie 2>/dev/null || true
  docker rmi -f calciumion/new-api:latest ghcr.io/yetone/magpie:latest 2>/dev/null || true
  docker network prune -f 2>/dev/null || true
fi

# 2. 卸载 OpenResty（服务 / 包 / apt 源 / 配置 / 站点目录）
echo "== 卸载 OpenResty =="
systemctl disable --now openresty 2>/dev/null || true
systemctl stop openresty 2>/dev/null || true
rm -f /etc/apt/sources.list.d/openresty.list /etc/apt/keyrings/openresty.gpg
# 先解锁版本锁定，再 purge；purge 注销 conffile，否则重装时 dpkg 不会恢复被删的 mime.types 等配置文件
apt-mark unhold openresty openresty-opm openresty-resty >/dev/null 2>&1 || true
apt-get purge -y openresty openresty-opm openresty-resty >/dev/null 2>&1 || true
rm -rf /usr/local/openresty "$OPENRESTY_PREFIX" /var/www/acme "$CERT_DIR"

# 3. 卸载 acme.sh（含自动续期 cron）
echo "== 卸载 acme.sh =="
if [[ -x "$ACME_SH_HOME/acme.sh" ]]; then
  "$ACME_SH_HOME/acme.sh" --uninstall >/dev/null 2>&1 || true
fi
rm -rf "$ACME_SH_HOME"

# 4. 卸载 Docker（包 / apt 源 / keyring / 数据目录）
echo "== 卸载 Docker =="
systemctl stop docker 2>/dev/null || true
systemctl disable docker 2>/dev/null || true
apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1 || true
rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc
# 清除数据/配置目录（镜像层、卷、网络等，动辄数 GB）
rm -rf /var/lib/docker /var/lib/containerd /etc/docker /etc/containerd

# 5. 移除业务数据目录（可用 KEEP_DATA=1 保留）
if [[ "${KEEP_DATA:-0}" == "1" ]]; then
  echo "== 保留数据目录：${DATA_DIR} =="
else
  echo "== 移除数据目录：${DATA_DIR} =="
  rm -rf "$DATA_DIR"
fi

# 6. 移除部署时生成的 swap 与 swappiness 设置
if grep -q '^/swapfile ' /etc/fstab 2>/dev/null; then
  echo "== 移除部署生成的 swap =="
  swapoff /swapfile 2>/dev/null || true
  sed -i '\|^/swapfile |d' /etc/fstab
  rm -f /swapfile
fi
sed -i '\|^vm.swappiness|d' /etc/sysctl.conf 2>/dev/null || true

# 7. 最后移除部署目录（脚本自身）
echo "== 移除部署目录：${INSTALL_DIR} =="
rm -rf "$INSTALL_DIR"

echo ""
echo "== 卸载完成 =="
echo "已移除：OpenResty / Docker / acme.sh / 证书 / 容器与镜像 / 部署目录"
[[ "${KEEP_DATA:-0}" == "1" ]] && echo "已保留数据目录：${DATA_DIR}"
echo "未移除的系统工具：curl / wget / git / openssl / vnstat 等（非 clouddock 专属，不影响重装）。"
