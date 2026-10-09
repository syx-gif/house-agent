#!/usr/bin/env bash
# ============================================================
#  house-agent 一键关闭 / 下线脚本
#  【在本地虚拟机上执行，不是在 VPS、不是在 Windows】
#
#  用法：
#    sudo bash stop-all.sh            # 下线网站（停 frpc + 停容器），保留镜像和数据
#    sudo bash stop-all.sh --poweroff # 下线后，把整台虚拟机也关机
#    sudo APP_DIR=/你的/路径 bash stop-all.sh
#
#  脚本做的事：
#    ① 停 frpc 隧道  → 公网别人立刻访问不了
#    ② docker compose down → 停 5 个容器（api/nginx/mysql/redis/postgres）
#       （只删容器，镜像和数据卷都保留，下次 start-all.sh 秒起）
#    ③ （可选 --poweroff）关机整台虚拟机
# ============================================================
set -uo pipefail

DEFAULT_APP_DIR="/home/${SUDO_USER:-$USER}/project/huose_agent/my_langgraph_app"
APP_DIR="${APP_DIR:-$DEFAULT_APP_DIR}"
POWEROFF=0
[ "${1:-}" = "--poweroff" ] && POWEROFF=1

OK="\033[32m"; ERR="\033[31m"; WARN="\033[33m"; DIM="\033[2m"; NC="\033[0m"
green() { printf "${OK}%s${NC}\n" "$1"; }
red()   { printf "${ERR}%s${NC}\n" "$1"; }
warn()  { printf "${WARN}%s${NC}\n" "$1"; }
hr() { printf '%s\n' "------------------------------------------------------------"; }

echo "============================================================"
echo " house-agent 关闭 / 下线    $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================================"

# ---- 权限与目录（和启动脚本一致）----
if [ "$(id -u)" != "0" ] && ! id -nG 2>/dev/null | grep -qw docker; then
  red "❌ 当前用户既不是 root 也不在 docker 组，无法操作容器。"
  echo "   请改用：sudo bash stop-all.sh"
  exit 1
fi

if [ ! -d "$APP_DIR" ]; then
  red "❌ 项目目录不存在：$APP_DIR"
  echo "   如果是自定义路径：sudo APP_DIR=/你的/路径 bash stop-all.sh"
  exit 1
fi
cd "$APP_DIR" || exit 1
echo "项目目录 : $APP_DIR"

echo
echo "① 切断公网隧道 frpc（让外网访问不了）"
if systemctl list-unit-files 2>/dev/null | grep -q '^frpc\.service'; then
  if systemctl is-active --quiet frpc; then
    systemctl stop frpc
    green "   ✔ frpc 已停止 → 公网别人现在访问不了了"
  else
    warn "   frpc 本来就没在跑（公网早已不可达）"
  fi
else
  warn "   本机没有 frpc.service（隧道若在别处跑，去那台机器停）"
fi

echo
echo "② 停止 5 个容器（api / nginx / mysql / redis / postgres）"
docker compose down
green "   ✔ 容器已停止并移除（镜像和数据卷都保留）"

echo
hr
echo " 关闭完成"
hr
cat <<'TIP'
   现在的状态：
     · 公网（http://<VPS公网IP>:8080/）→ 已不可达
     · 本机 localhost → 也已停止（容器都下了）
     · 数据：MySQL 数据卷、镜像都还在，下次 start-all.sh 秒起
   想重新上线：sudo bash start-all.sh
TIP

if [ "$POWEROFF" = "1" ]; then
  echo
  warn "准备关机整台虚拟机（--poweroff）…"
  sleep 2
  shutdown -h now
fi
echo
