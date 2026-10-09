# house-agent — 租房推荐 Agent

一个基于 LangGraph 的租房推荐多轮对话 Agent。用户用自然语言说需求，它能识别意图、
从 MySQL 查询房源推荐、走「预订」子流程（带人工确认中断），还能查询历史偏好和预订记录。

技术关键词：**LangGraph 状态图**、**意图识别**、**Human-in-the-loop 中断**、
**MySQL 持久化**、**智谱 GLM**。

---

## 功能

| 能力 | 说明 |
| - | - |
| 意图识别 | 用 LLM 结构化输出，把用户输入归为「推荐 / 预订 / 查询 / 其它」四类 |
| 房源推荐 | 根据用户预算、需求，从 MySQL 房源表查询并推荐 |
| 预订子流程 | 推荐后走 `interrupt()` 人工确认，用户选择「需要」才进入预订 |
| 历史偏好查询 | 读取持久化的预算、已预订订单等信息，生动回复 |
| 多轮上下文 | 基于 LangGraph 状态图，保持对话上下文 |

---

## 技术栈

- **LangGraph**：状态图编排，条件路由到推荐 / 预订 / 查询 / 闲聊四个子图
- **LangChain**：LLM 封装、结构化输出（function calling）、消息过滤
- **智谱 GLM**：经 OpenAI 兼容协议调用（`glm-4.7`），key 走 `ZHIPUAI_API_KEY`
- **MySQL**：房源表 + 预订订单表，持久化跨重启可用
- **FastAPI**：对外 HTTP 服务（`src/server.py`）

---

## 工作流

```
用户输入
   │
   ▼
读取偏好信息 (store) ──► 意图识别 (LLM 结构化输出)
                            │
        ┌──────────┬────────┼──────────┐
        ▼          ▼        ▼          ▼
     推荐子图    预订子图  查询偏好    闲聊兜底
        │          │
        ▼          │
  需要预订吗? (interrupt 人工确认)
        │
     ┌──┴──┐
  需要    不需要
   │       │
 预订    收尾回复
```

核心路由逻辑在 `src/agent/graph.py`：先识别意图，再条件路由到对应子图；
推荐子图结束后通过 `interrupt()` 挂起，等用户确认是否预订。

---

## 跑起来

```bash
# 1. 装依赖
pip install -e . "langgraph-cli[inmem]"

# 2. 配置 .env（填智谱 GLM 的 key）
cp .env.example .env
# 关键配置：
#   ZHIPUAI_API_KEY=xxx
#   MODEL_NAME=glm-4.7
#   MYSQL_HOST / MYSQL_PORT / MYSQL_USER / MYSQL_PASSWORD / MYSQL_DB

# 3. 起依赖容器（MySQL）
docker compose up -d

# 4. 启动服务
langgraph dev        # 开发模式（带可视化 Studio）
# 或
uvicorn src.server:app --host 0.0.0.0 --port 8000
```

---

## 代码结构

| 位置 | 内容 |
| - | - |
| `src/agent/graph.py` | 主图组装：节点注册、条件路由 |
| `src/agent/node/` | 各节点实现（意图识别、预订、推荐、查询偏好） |
| `src/agent/state/` | 状态定义（State、NeedReserveOutput 等） |
| `src/agent/common/` | LLM、数据库连接、store 等公共能力 |
| `src/agent/recommend.py` | 推荐子图 |
| `src/agent/reserve.py` | 预订子图 |
| `src/agent/extend.py` | 闲聊兜底子图 |
| `src/server.py` | FastAPI 入口 |

---

## 许可证

MIT
