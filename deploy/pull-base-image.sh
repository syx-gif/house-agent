#!/usr/bin/env bash
# ============================================================
# 预拉基础镜像 langchain/langgraph-api:3.11-wolfi
#
# 为什么要它：
#   国内直连 docker.io 拉这个镜像常年几 KB/s（实测 19 分钟只下 34MB）。
#   本脚本依次尝试多个国内镜像站，任一个成功就 docker tag 成官方名字，
#   之后 `docker compose up -d --build` 就能直接用本地缓存，不再联网。
#
# 用法（需要 docker 权限，建议 sudo）：
#   sudo bash deploy/pull-base-image.sh
# ============================================================
set -uo pipefail

IMAGE="langchain/langgraph-api:3.11-wolfi"

MIRRORS=(
  "docker.m.daocloud.io"
  "docker.1ms.run"
  "docker.1panel.live"
  "dockerpull.org"
  "docker.xuanyuan.me"
  "docker.unsee.tech"
  "hub.rat.dev"
  "dockerproxy.net"
)

DOCKER="docker"
if ! docker info >/dev/null 2>&1; then
  if sudo docker info >/dev/null 2>&1; then
    DOCKER="sudo docker"
  else
    echo "❌ 无法连接 Docker，请确认 Docker 已启动、且当前用户有权限（或改用 sudo 运行本脚本）" >&2
    exit 1
  fi
fi

echo "==> 目标镜像：$IMAGE"

if $DOCKER image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "✅ 本地已存在 $IMAGE，无需拉取。可以直接："
  echo "     docker compose up -d --build langgraph-api"
  exit 0
fi

FAILED=()
for m in "${MIRRORS[@]}"; do
  src="$m/$IMAGE"
  echo
  echo "==> 尝试镜像站：$src"
  # 每个站最多等 10 分钟，避免卡死在这里不动
  if timeout 600 $DOCKER pull "$src"; then
    $DOCKER tag "$src" "$IMAGE"
    echo
    echo "✅ 拉取成功，已重命名为官方名：$IMAGE"
    echo "   下一步：  docker compose up -d --build langgraph-api"
    exit 0
  fi
  echo "   ✗ $m 不可用，换下一个"
  FAILED+=("$m")
done

echo
echo "❌ 所有镜像站都没成功。备用方案（任选其一）："
echo
echo "  A) 配置 Docker 走宿主机代理后重试"
echo "     （虚拟机里填宿主机在 VMware NAT 网段的网关 IP，不是 127.0.0.1）"
echo "     sudo mkdir -p /etc/systemd/system/docker.service.d"
echo "     sudo tee /etc/systemd/system/docker.service.d/proxy.conf >/dev/null <<'EOF'"
echo "     [Service]"
echo "     Environment=\"HTTPS_PROXY=http://192.168.x.1:7890\""
echo "     Environment=\"HTTP_PROXY=http://192.168.x.1:7890\""
echo "     EOF"
echo "     sudo systemctl daemon-reload && sudo systemctl restart docker"
echo
echo "  B) 在能正常拉取的环境里导出镜像再拷过来"
echo "     docker pull langchain/langgraph-api:3.11-wolfi"
echo "     docker save langchain/langgraph-api:3.11-wolfi -o langgraph-api.tar"
echo "     # 传到虚拟机后："
echo "     sudo docker load -i langgraph-api.tar"
exit 1
