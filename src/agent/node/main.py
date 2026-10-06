from langchain_core.messages import SystemMessage, filter_messages, HumanMessage, AIMessage
from langgraph.runtime import Runtime
from langgraph.store.base import BaseStore
from langgraph.types import interrupt, StreamWriter
from pydantic import BaseModel, Field
from typing_extensions import Literal

from src.agent.common.context import ContextSchema
from src.agent.common.llm import model
from src.agent.common.db import get_conn
from src.agent.state.main import State, NeedReserveOutput


# 节点：查询持久化信息
def get_store_info(state: State, runtime: Runtime[ContextSchema], * , store: BaseStore, writer: StreamWriter):
    # 搜索用户信息
    writer({"type": "progress", "step": "get_store_info", "message": "📋 正在读取您的偏好信息..."})
    user_id = (runtime.context or {}).get("user_id")
    namespace = (user_id, "preferences")
    prefs_result = store.search(namespace)
    if prefs_result and prefs_result[0]:
        return {
            "user_preferences": prefs_result[0].value
        }
    else:
        return {
            "user_preferences": {}
        }

class UserMessage(BaseModel):
    type: Literal["recommend_house", "reserve_house", "get_info", "others"] = Field(
        description="根据用户问题描述判断问题类型：推荐房源、预定房源、获取信息、其它内容"
    )

# 节点：识别用户意图
def identify_question(state: State, writer: StreamWriter):
    # state["messages"] # 用户问题  -》 LLM  -> 结构化输出（type） : 推荐、预定、我的、其它
    writer({"type": "progress", "step": "identify_question", "message": "🧠 正在分析您的需求..."})
    user_intent = model.with_structured_output(UserMessage, method="function_calling").invoke(
        [SystemMessage(content="你是一个根据描述提取信息的提取专家。请从用户的描述中提取想要咨询的相关信息。"
                    "严谨根据语义推断信息，但是不能猜测或者编造信息。"), state["messages"][-1]]
    )
    return {
        "user_intent": user_intent.type  # 条件边使用
    }
def need_reserve(state: State, writer: StreamWriter) -> NeedReserveOutput:
    writer({"type": "progress", "step": "need_reserve", "message": "✅ 已为您推荐房源，正在确认是否需要预订..."})
    prompt = f"已经为您推荐合适的房源，是否需要帮您预订房源？\n"
    prompt += "如果不需要,请输入'**不需要**'。\n"
    prompt += "如果需要,请输入'**需要**'。\n(注意输入其它值无效)\n"
    answer = interrupt(prompt)
    return {"reserve": answer}  # 条件边获取到后，是否执行预定子图

# 节点：用户选择「不需要预订」时的收尾回复
# 为什么需要它：need_reserve -> END 这条路径原本不产生任何消息，
# 前端流读完了却没有任何内容可显示，用户会误以为"卡住了"。
def no_reserve_reply(state: State, writer: StreamWriter):
    writer({"type": "progress", "step": "no_reserve_reply", "message": "✅ 已收到您的选择，本次咨询结束"})
    return {
        "messages": [
            AIMessage(
                content="好的，那就先不预订啦～\n\n"
                        "如果之后看中了哪套房想预订，随时跟我说一声就行。"
            )
        ]
    }

# 节点：返回用户偏好信息
def get_user_preferences(state: State, writer: StreamWriter):
    writer({"type": "progress", "step": "get_user_preferences", "message": "📦 正在查询您的历史订单信息..."})

    # 获取最新历史偏好信息（参考答案）
    prefs = state.get("user_preferences", {})
    # 筛选用户消息（获取到用户问题）
    user_messages = filter_messages(state["messages"], include_types="human")

    # 优先从持久化数据库读取历史订单（MySQL 持久化，跨重启 / 跨线程可用，不受 in-memory store 重启清空影响）
    reserved_info = []
    try:
        conn = get_conn()
        try:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT order_id, house_title, phone_number "
                    "FROM reservation_orders ORDER BY created_at DESC LIMIT 20"
                )
                for row in cur.fetchall():
                    reserved_info.append({
                        "order_id": row[0],
                        "title": row[1],
                        "phone_number": row[2],
                    })
        finally:
            conn.close()
    except Exception:
        # 数据库不可用时回退到 store 中的偏好，保证不崩
        reserved_info = prefs.get("reserved_info", [])

    if reserved_info:
        # 有预定过的信息
        reserved_str = "\n"
        for i, item in enumerate(reserved_info, 1):
            reserved_str += f"{i}. 预定工单ID: {item.get('order_id')}，" \
                            f"房源标题：{item.get('title')}，" \
                            f"预定电话：{item.get('phone_number')}\n"
    else:
        # 没有预定
        reserved_str = "无"

    result = model.invoke(
        [SystemMessage(content="""你是一个乐于助人的助手，可以根据用户偏好信息进行回复。
如果有的偏好数据为空，不要猜测或编造数据。
不要直接回复偏好数据是什么，要结合问题进行生动回复。
如果问题与用户偏好数据无关，直接回复即可。""") ,
         HumanMessage(content="用户的历史偏好信息如下"
                      f"1. 最低预算：{prefs.get('budget_min')}"
                      f"2. 最高预算：{prefs.get('budget_max')}"
                      f"3. 已预定过的信息：{reserved_str}"
                      ) ,
         user_messages[-1]  # 问题
        ]
    )
    return {
        "messages": [result]
    }