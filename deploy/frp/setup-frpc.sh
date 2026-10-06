#!/usr/bin/env bash
# ============================================================
# frp 客户端（frpc）一键安装脚本 —— 在你跑 docker compose 的本地虚拟机上运行
#
# 用法：
#   sudo bash setup-frpc.sh <VPS公网IP> <token> [对外端口，默认8080]
#
# 注意：token 必须和 VPS 上 setup-frps.sh 用的完全一致。
#
# 前置条件：虚拟机里 nginx 容器已经发布到 80 端口
#   验证：curl http://localhost/ | head -3
# ============================================================

set -euo pipefail

FRP_VERSION="0.61.0"
LOCAL_PORT="80"

SERVER_ADDR="${1:-}"
TOKEN="${2:-}"
REMOTE_PORT="${3:-8080}"

if [ -z "${SERVER_ADDR}" ] || [ -z "${TOKEN}" ]; then
    echo "用法: sudo bash setup-frpc.sh <VPS公网IP> <token> [对外端口,默认8080]"
    echo "示例: sudo bash setup-frpc.sh <VPS公网IP> <与frps一致的token> 8080"
    exit 1
fi

echo "==> 0/5 先自测本地 80 端口是否可用"
if curl -fsS --connect-timeout 5 -o /dev/null "http://localhost:${LOCAL_PORT}/"; then
    echo "    localhost:${LOCAL_PORT} 可访问，继续"
else
    echo "    ⚠️ localhost:${LOCAL_PORT} 连不上。先确认容器都起来了："
    echo "       sudo docker compose ps"
    echo "       curl http://localhost/"
    exit 1
fi

echo "==> 1/5 检测系统架构"
ARCH="$(uname -m)"
case "${ARCH}" in
    x86_64)  FRP_ARCH="amd64" ;;
    aarch64) FRP_ARCH="arm64" ;;
    *) echo "不支持的架构: ${ARCH}"; exit 1 ;;
esac
PKG="frp_${FRP_VERSION}_linux_${FRP_ARCH}.tar.gz"
DIR="frp_${FRP_VERSION}_linux_${FRP_ARCH}"
echo "    ${ARCH} -> ${PKG}"

echo "==> 2/5 下载 frp（官方源失败会自动切 GitHub 镜像）"
cd /tmp
rm -f "${PKG}"
OK=0
for U in \
    "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${PKG}" \
    "https://ghfast.top/https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${PKG}" \
    "https://gh-proxy.com/https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${PKG}" \
    "https://ghproxy.net/https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${PKG}"
do
    echo "    尝试: ${U}"
    if curl -fL --connect-timeout 10 --retry 2 -o "${PKG}" "${U}"; then
        OK=1
        echo "    下载成功"
        break
    fi
    rm -f "${PKG}"
done
if [ "${OK}" != "1" ]; then
    echo "    下载失败。请手动下载 ${PKG} 后放到 /tmp 再重跑本脚本。"
    exit 1
fi

echo "==> 3/5 安装 frpc 到 /usr/local/bin"
rm -rf "/tmp/${DIR}"
tar -xzf "${PKG}"
install -m 0755 "/tmp/${DIR}/frpc" /usr/local/bin/frpc
echo "    已安装: $(/usr/local/bin/frpc --version 2>/dev/null || echo frpc)"

echo "==> 4/5 写入配置 /etc/frp/frpc.toml"
mkdir -p /etc/frp
cat > /etc/frp/frpc.toml <<EOF
# frp 客户端配置
serverAddr = "${SERVER_ADDR}"
serverPort = 7000

auth.method = "token"
auth.token = "${TOKEN}"

log.to = "/var/log/frpc.log"
log.level = "info"
log.maxDays = 7

# 只把本地 80 端口（nginx）映射出去
# ⚠️ 千万不要在这里再映射 3306 / 5432 / 6379，那等于把数据库挂到公网上
[[proxies]]
name = "house-web"
type = "tcp"
localIP = "127.0.0.1"
localPort = ${LOCAL_PORT}
remotePort = ${REMOTE_PORT}
EOF
cat /etc/frp/frpc.toml

echo "==> 5/5 注册 systemd 服务并启动"
cat > /etc/systemd/system/frpc.service <<'EOF'
[Unit]
Description=frp client (frpc)
After=network.target docker.service
Wants=docker.service

[Service]
Type=simple
ExecStart=/usr/local/bin/frpc -c /etc/frp/frpc.toml
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now frpc
sleep 3
systemctl --no-pager --full status frpc || true

echo ""
echo "============================================================"
echo "frpc 已启动，正在把本机 ${LOCAL_PORT} 端口送到 ${SERVER_ADDR}:${REMOTE_PORT}"
echo ""
echo "🎉 对外访问地址：  http://${SERVER_ADDR}:${REMOTE_PORT}/"
echo ""
echo "看日志:  tail -f /var/log/frpc.log"
echo "重启:    sudo systemctl restart frpc"
echo "停止:    sudo systemctl stop frpc"
echo "============================================================"
