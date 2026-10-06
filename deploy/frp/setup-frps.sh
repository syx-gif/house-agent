#!/usr/bin/env bash
# ============================================================
# frp 服务端（frps）一键安装脚本 —— 在有公网 IP 的 VPS 上运行
#
# 用法：
#   sudo bash setup-frps.sh <自定义token>
#
# 生成一个随机 token 的命令（复制输出即可）：
#   openssl rand -hex 16
#
# 跑之前先在云控制台放通这两个端口：
#   TCP 7000  —— frp 控制端口（frpc 连过来用）
#   TCP 8080  —— 对外访问端口（浏览器访问用）
# ============================================================

set -euo pipefail

FRP_VERSION="0.61.0"
BIND_PORT="7000"

TOKEN="${1:-}"
if [ -z "${TOKEN}" ]; then
    echo "用法: sudo bash setup-frps.sh <自定义token>"
    echo "示例: sudo bash setup-frps.sh $(openssl rand -hex 16 2>/dev/null || echo 'my-secret-token-123')"
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

echo "==> 3/5 安装 frps 到 /usr/local/bin"
rm -rf "/tmp/${DIR}"
tar -xzf "${PKG}"
install -m 0755 "/tmp/${DIR}/frps" /usr/local/bin/frps
echo "    已安装: $(/usr/local/bin/frps --version 2>/dev/null || echo frps)"

echo "==> 4/5 写入配置 /etc/frp/frps.toml"
mkdir -p /etc/frp
cat > /etc/frp/frps.toml <<EOF
# frp 服务端配置
bindPort = ${BIND_PORT}

# 必须设置 token：否则任何人都能把 frpc 连上来蹭你的隧道
auth.method = "token"
auth.token = "${TOKEN}"

# 只允许转发这几个端口，防止有人拿你的 VPS 当跳板
allowPorts = [
  { start = 8080, end = 8080 }
]

# 日志
log.to = "/var/log/frps.log"
log.level = "info"
log.maxDays = 7
EOF
cat /etc/frp/frps.toml

echo "==> 5/5 注册 systemd 服务并启动"
cat > /etc/systemd/system/frps.service <<'EOF'
[Unit]
Description=frp server (frps)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/frps -c /etc/frp/frps.toml
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now frps
sleep 1
systemctl --no-pager --full status frps || true

echo ""
echo "============================================================"
echo "frps 已启动，监听 ${BIND_PORT}，允许转发端口 8080"
echo ""
echo "⚠️ 现在去腾讯云控制台确认防火墙已放通："
echo "   TCP 7000   （frpc 控制连接）"
echo "   TCP 8080   （对外访问）"
echo ""
echo "看日志:  tail -f /var/log/frps.log"
echo "重启:    sudo systemctl restart frps"
echo "============================================================"
