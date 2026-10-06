#!/usr/bin/env bash
# ============================================================
# 本地 Ubuntu 虚拟机一键部署脚本
# ------------------------------------------------------------
# 前置条件：
#   1) 项目已解压到 ~/my_langgraph_app
#      根目录必须含：Dockerfile、docker-compose.yml、.dockerignore、
#      langgraph.json、pyproject.toml、src/、static/、nginx/
#   2) 房源 SQL 已上传到虚拟机，例如 ~/house_prd.sql
#
# 运行方式：
#   cd ~/my_langgraph_app
#   bash deploy/deploy-local-vm.sh ~/house_prd.sql
#
#（不带参数时默认找 ~/house_prd.sql）
# ============================================================
set -u

SQL_FILE="${1:-$HOME/house_prd.sql}"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
echo "==> 项目目录：$PROJECT_DIR"

# ---------- 0. 选择 docker 命令（能免 sudo 就免） ----------
if docker info >/dev/null 2>&1; then
  DOCKER="docker"
else
  DOCKER="sudo docker"
fi

# ---------- 1. 安装 docker + compose v2 ----------
if ! command -v docker >/dev/null 2>&1; then
  echo "==> 未检测到 Docker，开始安装（需要输入 sudo 密码）..."
  sudo apt update
  sudo apt install -y docker.io docker-compose-v2
  sudo systemctl enable --now docker
  sudo usermod -aG docker "$USER" || true
  echo "==> 已把 $USER 加入 docker 组；本次仍会用 sudo 执行，重新登录后即可免 sudo"
  DOCKER="sudo docker"
fi

if ! $DOCKER compose version >/dev/null 2>&1; then
  echo "!! 未检测到 docker compose 插件，尝试安装 docker-compose-v2 ..."
  sudo apt install -y docker-compose-v2 || true
fi

# ---------- 2. 配置国内镜像加速（拉镜像快很多） ----------
if [ ! -f /etc/docker/daemon.json ]; then
  echo "==> 写入 Docker 镜像加速配置 /etc/docker/daemon.json"
  sudo mkdir -p /etc/docker
  sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
  "registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://docker.1ms.run",
    "https://mirror.ccs.tencentyun.com"
  ]
}
EOF
  sudo systemctl restart docker
else
  echo "==> 已存在 /etc/docker/daemon.json，跳过镜像加速配置"
fi

# ---------- 3. 准备根目录 .env ----------
if [ ! -f .env ]; then
  echo "==> 根目录没有 .env，从 deploy/.env.example 复制一份"
  cp deploy/.env.example .env
fi

# 3.1 DB_HOST 必须是容器服务名 mysql，不能是 127.0.0.1
if grep -q '^DB_HOST=127\.0\.0\.1' .env; then
  echo "==> 修正 .env：DB_HOST 127.0.0.1 → mysql（容器里必须用服务名）"
  sed -i 's/^DB_HOST=127\.0\.0\.1/DB_HOST=mysql/' .env
fi

# 3.2 compose 里 postgres 需要 POSTGRES_PASSWORD，缺了就补上
if ! grep -q '^POSTGRES_PASSWORD=' .env; then
  echo "==> 补充 POSTGRES_PASSWORD=postgres 到 .env"
  printf '\nPOSTGRES_PASSWORD=postgres\n' >> .env
fi

# 3.3 关键变量不能还是占位符
if grep -qE '^(LANGSMITH_API_KEY|ZHIPUAI_API_KEY)=(lsv2_x|your_)' .env; then
  echo ""
  echo "!!  .env 里的 LANGSMITH_API_KEY / ZHIPUAI_API_KEY 还是占位符。"
  echo "!!  请先执行  nano .env  把这两个 key 填成真实值，再重跑本脚本。"
  echo "!!  当前 .env 有效内容："
  grep -vE '^\s*#' .env | grep -v '^\s*$'
  exit 1
fi

DB_PASS="$(grep -E '^DB_PASSWORD=' .env | head -1 | cut -d= -f2-)"
DB_NAME="$(grep -E '^DB_NAME=' .env | head -1 | cut -d= -f2-)"
DB_NAME="${DB_NAME:-house_prd}"
echo "==> .env 就绪：DB_NAME=$DB_NAME"

# ---------- 4. 构建并启动全部服务 ----------
echo "==> docker compose up -d --build（首次构建较慢，5~15 分钟，请耐心等待）"
$DOCKER compose up -d --build

# ---------- 5. 等待 house-mysql 变 healthy ----------
echo "==> 等待 house-mysql 就绪 ..."
STATUS="unknown"
for _ in $(seq 1 60); do
  STATUS="$($DOCKER inspect --format '{{.State.Health.Status}}' house-mysql 2>/dev/null || echo unknown)"
  [ "$STATUS" = "healthy" ] && break
  sleep 3
done
echo "==> house-mysql 状态：$STATUS"

# ---------- 6. 导入房源数据（已有数据则跳过） ----------
if [ -f "$SQL_FILE" ]; then
  ROWS="$($DOCKER exec house-mysql mysql -uroot -p"$DB_PASS" -N -e "select count(*) from $DB_NAME.house" 2>/dev/null | tr -d '\r')"
  if [ -n "${ROWS:-}" ] && [ "${ROWS:-0}" -gt 0 ] 2>/dev/null; then
    echo "==> $DB_NAME.house 已有 $ROWS 行，跳过导入"
  else
    echo "==> 导入 $SQL_FILE 到 $DB_NAME ..."
    $DOCKER exec -i house-mysql mysql -uroot -p"$DB_PASS" "$DB_NAME" < "$SQL_FILE"
    ROWS="$($DOCKER exec house-mysql mysql -uroot -p"$DB_PASS" -N -e "select count(*) from $DB_NAME.house" 2>/dev/null | tr -d '\r')"
    echo "==> 导入完成，house 表行数：${ROWS:-未知}"
  fi
else
  echo "!! 没找到 SQL 文件：$SQL_FILE（跳过数据导入）"
  echo "!! 稍后可手动导入：docker exec -i house-mysql mysql -uroot -p$DB_PASS $DB_NAME < 你的SQL路径"
fi

# ---------- 7. 验证 ----------
echo ""
echo "==> 容器状态"
$DOCKER compose ps
echo ""
echo "==> API 健康检查（http://localhost:8123/ok）"
curl -s http://localhost:8123/ok || true
echo ""
IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo ""
echo "============================================================"
echo " 部署完成 🎉"
echo "   前端页面：http://${IP:-<虚拟机IP>}/"
echo "   接口直连：http://${IP:-<虚拟机IP>}:8123/ok"
echo "============================================================"
