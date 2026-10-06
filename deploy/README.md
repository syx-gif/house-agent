# 部署 LangGraph Agent 到远程服务器

把本地 `my_langgraph_app` 这个租房 agent 部署到一台远程 Linux 服务器（如阿里云/腾讯云的 Ubuntu 22.04），
让它在公网/内网跑起来，别人也能调用 `house_agent` 等接口。

## 整体架构（4 个容器）

| 容器 | 作用 |
|---|---|
| `langgraph-redis` | 任务队列 / 流式推送 |
| `langgraph-postgres` | 存 agent 的状态和检查点（LangGraph 自己用，和房源无关）|
| `mysql` | 你的房源库 `house_prd`，`get_conn()` 连的就是它 |
| `langgraph-api` | 你的 agent 服务，跑 `house_agent` / `recommended_agent` 等 |

## 前置条件

1. 一台远程 Linux 服务器（建议 Ubuntu 22.04，2G 内存以上）。
2. 服务器上装好 **Docker + Docker Compose**。
3. 服务器**安全组/防火墙**开放 `8123` 端口（只开放这一个；3306/5433/6379 不要对公网开放）。
4. 一个免费的 **LangSmith API Key**（https://smith.langchain.com 注册即得）。

### 0. 在 Ubuntu 上安装 Docker（国内镜像，避免 download.docker.com 被墙）

> 默认 Ubuntu 源里没有 `docker-compose-plugin`，且 `download.docker.com` 在国内常被重置连接。
> 用阿里云镜像源安装（腾讯云/阿里云服务器都适用）：

```bash
sudo apt update
sudo apt install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://mirrors.aliyun.com/docker-ce/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin python3-venv python3-pip
sudo systemctl enable --now docker
sudo usermod -aG docker $USER
newgrp docker
docker --version && docker compose version
```

> 如果阿里云镜像也连不上，把上面两处 `mirrors.aliyun.com` 换成腾讯云镜像：
> `https://mirrors.cloud.tencent.com/docker-ce/linux/ubuntu`

### 0.1 配置 Docker 镜像加速（国内必做，否则拉镜像会超时/被限流）

Docker Hub 在国内常被限速，腾讯云服务器用腾讯云内网加速器（免登录）：

```bash
sudo mkdir -p /etc/docker
echo '{ "registry-mirrors": ["https://mirror.ccs.tencentyun.com"] }' | sudo tee /etc/docker/daemon.json > /dev/null
sudo systemctl restart docker
docker info | grep -A1 Registry   # 能看到 mirror.ccs.tencentyun.com 即生效
```

## 步骤

### 1. 把项目传到服务器
```bash
# 方式A：git（推荐，先把项目推到 Gitee/GitHub）
git clone <你的仓库地址> my_langgraph_app
cd my_langgraph_app

# 方式B：scp 整个文件夹
# scp -r . user@服务器IP:/home/user/my_langgraph_app
```

### 2. 构建 LangGraph 镜像
需要 Docker 可用，并装好 `langgraph-cli`（用国内 PyPI 镜像加速）：
```bash
cd ~/my_langgraph_app
touch .env                       # 避免构建时找不到 .env
python3 -m venv ~/lgbuild
source ~/lgbuild/bin/activate
pip install -U pip
pip install -i https://pypi.tuna.tsinghua.edu.cn/simple "langgraph-cli[inmem]"
langgraph build -t my-langgraph-agent   # 读取项目根目录的 langgraph.json
```
> 构建会拉取 LangGraph 基础镜像并装依赖，耗时几分钟，耐心等。看到 `Successfully built ... my-langgraph-agent` 即成功。
> 构建出的镜像名就是后面 `.env` 里的 `IMAGE_NAME`。

### 3. 准备环境变量
```bash
cd deploy
cp .env.example .env
# 编辑 .env，至少填：LANGSMITH_API_KEY、ZHIPUAI_API_KEY、DB_PASSWORD
```
关键变量说明：
- `IMAGE_NAME`：第 2 步构建的镜像名
- `LANGSMITH_API_KEY`：免费版启动也要（一次性鉴权）
- `ZHIPUAI_API_KEY`：智谱 key（`llm.py` 用）
- `DB_*`：房源 MySQL 连接信息，`DB_HOST=mysql`（连 compose 里的 mysql 服务）

### 4. 导入房源数据（重要！）
你的 agent 查房源依赖 `house_prd` 库。本地电脑上的库不会自动出现，需要迁移：
```bash
# 在【本地】导出
mysqldump -uroot -p house_prd > house_prd.sql

# 传到服务器后，在【服务器】导入到 mysql 容器
docker cp house_prd.sql house-mysql:/house_prd.sql
docker exec -i house-mysql mysql -uroot -p"$DB_PASSWORD" house_prd < house_prd.sql
```
> 如果还没数据，可以先不导入，但 `house_agent` 推荐房源会查不到（不影响服务起来）。

### 5. 启动
```bash
cd deploy
docker compose up -d
```

### 6. 验证
```bash
curl http://localhost:8123/ok
# 期望返回：{"ok":true}
```

### 7. 调用 agent
和本地一样，把地址换成服务器 IP（注意端口是 8123）：
```bash
curl -N -X POST "http://<服务器IP>:8123/assistants/house_agent/runs/stream?stream_mode=updates&stream_mode=messages&stream_subgraphs=true" \
  -H "Content-Type: application/json" \
  -d '{
    "input": {"messages":[{"role":"human","content":"帮我推荐几套房子"}]},
    "context": {"user_id": "789"}
  }'
```

## 常见坑

1. **`LANGSMITH_API_KEY` 必须要有**：免费 Self-Hosted Lite 启动时要联网鉴权一次，没有会启动失败。
2. **房源数据库没迁移**：服务能起来，但推荐房源查不到，记得第 4 步导数据。
3. **`langgraph build` 依赖报错**：如果卡在装依赖（pyproject 里 `any`/`runtime`/`start` 这类占位依赖），
   把 `pyproject.toml` 的 `dependencies` 精简成真实需要的包再构建。
4. **安全**：只对外暴露 8123；MySQL/Postgres/Redis 端口不要对公网开放，密码设强一点。
5. **公网 HTTPS（可选）**：生产环境建议在前面加一层 Nginx 反代 + 免费证书，不要裸奔 8123。
