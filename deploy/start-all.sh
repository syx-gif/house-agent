#!/usr/bin/env bash
# ============================================================
#  house-agent 一键启动 / 自检脚本
#  【在本地 Ubuntu 虚拟机上执行，不是在 VPS、不是在 Windows】
#
#  用法：
#    sudo bash start-all.sh          # 启动全部服务 + 自检
#    sudo bash start-all.sh --check  # 只自检，不做任何启动动作
#    sudo APP_DIR=/你的/路径 bash start-all.sh
#
#  脚本做的事（幂等，重复执行无副作用）：
#    ① 确认 docker 服务在跑，没跑就拉起来
#    ② 启动 5 个容器（api / nginx / mysql / redis / postgres）
#    ③ 轮询等待后端就绪（/ok 返回 200，最多 90 秒）
#    ④ 确认 frpc 隧道在跑（公网访问靠它）
#    ⑤ 打印自检结果与公网地址
# ============================================================
set -uo pipefail

# ---- 定位项目目录（sudo 下 $HOME 会变成 /root，所以从 SUDO_USER 取）----
DEFAULT_APP_DIR="/home/${SUDO_USER:-$USER}/project/huose_agent/my_langgraph_app"
APP_DIR="${APP_DIR:-$DEFAULT_APP_DIR}"

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

OK="\033[32m"; ERR="\033[31m"; WARN="\033[33m"; DIM="\033[2m"; NC="\033[0m"
green() { printf "${OK}%s${NC}\n" "$1"; }
red()   { printf "${ERR}%s${NC}\n" "$1"; }
warn()  { printf "${WARN}%s${NC}\n" "$1"; }

hr() { printf '%s\n' "------------------------------------------------------------"; }

echo "============================================================"
echo " house-agent 启动 / 自检    $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================================"

# ---- 0. 权限与目录 ----
if [ "$(id -u)" != "0" ] && ! id -nG 2>/dev/null | grep -qw docker; then
  red "❌ 当前用户既不是 root 也不在 docker 组，无法操作容器。"
  echo "   请改用：sudo bash start-all.sh"
  exit 1
fi

if [ ! -d "$APP_DIR" ]; then
  red "❌ 项目目录不存在：$APP_DIR"
  echo "   如果是自定义路径：sudo APP_DIR=/你的/路径 bash start-all.sh"
  exit 1
fi
cd "$APP_DIR" || exit 1
if [ ! -f docker-compose.yml ]; then
  red "❌ 目录里没有 docker-compose.yml，请确认路径：$APP_DIR"
  exit 1
fi
echo "项目目录 : $APP_DIR"

# ============================================================
# 启动阶段（--check 模式跳过）
# ============================================================
if [ "$CHECK_ONLY" = "0" ]; then

  echo
  echo "① 检查 Docker 服务"
  if systemctl is-active --quiet docker; then
    green "   ✔ docker 已在运行"
  else
    warn "   docker 未运行，正在启动…"
    systemctl start docker
    sleep 3
    if systemctl is-active --quiet docker; then
      green "   ✔ docker 已启动"
    else
      red "   ✘ docker 启动失败，请执行：systemctl status docker"
      exit 1
    fi
  fi

  echo
  echo "② 启动 5 个容器（api / nginx / mysql / redis / postgres）"
  if ! docker compose up -d; then
    red "   ✘ docker compose up 失败，先看上面报错"
    exit 1
  fi
  green "   ✔ 已下发启动指令"

  echo
  echo "③ 等待后端就绪（/ok 返回 200，最多 90 秒）"
  READY=0
  for i in $(seq 1 30); do
    CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://localhost/ok 2>/dev/null || echo 000)
    if [ "$CODE" = "200" ]; then READY=1; break; fi
    printf "${DIM}   第 %2d 次探测… HTTP %s${NC}\n" "$i" "$CODE"
    sleep 3
  done
  if [ "$READY" = "1" ]; then
    green "   ✔ 后端已就绪"
  else
    warn "   ⚠ 90 秒内后端仍未就绪，常见原因："
    echo "       · mysql 数据卷首次初始化较慢（看 docker compose logs mysql）"
    echo "       · .env 里的 DB_PASSWORD 与数据库实际密码不一致"
    echo "       · 容器内存不足被 OOM 杀掉（dmesg | tail）"
  fi

  echo
  echo "④ 检查 frpc 隧道（公网访问的命脉）"
  if ! systemctl list-unit-files 2>/dev/null | grep -q '^frpc\.service'; then
    warn "   ⚠ 本机没有 frpc.service，说明隧道不是装在这台虚拟机上"
    echo "       → 去 Windows 侧确认（可能装在 Windows 或 WSL 里）"
    echo "       → 判断依据：公网 8080 能打开就说明隧道在别处正常跑着"
  elif systemctl is-active --quiet frpc; then
    green "   ✔ frpc 已运行"
  else
    warn "   frpc 未运行，正在启动…"
    systemctl start frpc
    sleep 2
    if systemctl is-active --quiet frpc; then green "   ✔ frpc 已启动"; else red "   ✘ frpc 启动失败：journalctl -u frpc -n 30"; fi
  fi
fi

# ============================================================
# 自检阶段
# ============================================================
echo
hr
echo " 自检结果"
hr

echo "[容器]"
docker compose ps 2>/dev/null || red "   docker compose ps 执行失败"

echo
echo "[端口探测]"
for item in "首页/http://localhost/" "后端接口/http://localhost/ok"; do
  NAME="${item%%/*}"; URL="${item#*/}"
  CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$URL" 2>/dev/null || echo 000)
  case "$CODE" in
    200) printf "   %-8s HTTP %s  ${OK}正常${NC}\n" "$NAME" "$CODE" ;;
    401) printf "   %-8s HTTP %s  ${WARN}已启用访问口令（正常，浏览器会弹登录框）${NC}\n" "$NAME" "$CODE" ;;
    502) printf "   %-8s HTTP %s  ${ERR}nginx 通了但后端挂了 → docker compose logs langgraph-api${NC}\n" "$NAME" "$CODE" ;;
    000) printf "   %-8s HTTP %s  ${ERR}本机 nginx 都没起来 → docker compose logs nginx${NC}\n" "$NAME" "$CODE" ;;
    *)   printf "   %-8s HTTP %s  ${WARN}非预期状态码${NC}\n" "$NAME" "$CODE" ;;
  esac
done

echo
echo "[隧道]"
if systemctl list-unit-files 2>/dev/null | grep -q '^frpc\.service'; then
  printf "   frpc %s\n" "$(systemctl is-active frpc 2>/dev/null)"
else
  echo "   本机无 frpc.service（隧道在别处运行）"
fi

echo
echo "[磁盘]"
df -h / | awk 'NR==2 {printf "   根分区已用 %s / %s（%s）\n", $3, $2, $5}'

echo
hr
echo " 下一步"
hr
cat <<'TIP'
   1) 浏览器打开公网地址（形如 http://<VPS公网IP>:8080/）验证
   2) Windows 主机电源设置里把「睡眠」设为「从不」，否则半夜会变 502
   3) 故障速判：公网「超时」= VPS 侧问题；公网「502」= 本地虚拟机侧问题
   4) 只看不改：sudo bash start-all.sh --check
TIP
echo
