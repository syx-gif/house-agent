import uuid
from typing import Annotated, Any
from src.agent.common.db import get_conn


from langchain_core.messages import HumanMessage, SystemMessage
from langchain_core.tools import tool
from langgraph.prebuilt import ToolNode, ToolRuntime, InjectedStore
from langgraph.types import interrupt

from src.agent.common.llm import model
from src.agent.common.store import ReservedInfo, UserPreferences
from src.agent.state.reserve import ReserveState


# 节点：获取预定房源名称
def get_title(state: ReserveState):
    prompt = "请输入要预定的房源名称"

    while True:
        title = interrupt(prompt)
        if title:  # 验证操作
            return {"title": title}

        # 验证失败：再次输入
        prompt = f"‘{title}’ 不是一个有效的房源名称，请更正"

# 节点：获取预定房源名称
def get_phone(state: ReserveState):
    prompt = "请输入要预定的手机号"

    while True:
        phone_number = interrupt(prompt)
        if phone_number:  # 验证操作
            return {"phone_number": phone_number}

        # 验证失败：再次输入
        prompt = f"‘{phone_number}’ 不是一个有效的电话号码，请更正"


# 节点：获取预定人员身份证
def get_id(state: ReserveState):
    prompt = "请输入要预定的身份证号码"

    while True:
        id_card = interrupt(prompt)
        if id_card:  # 验证操作
            return {"id_card": id_card}

        # 验证失败：再次输入
        prompt = f"‘{id_card}’ 不是一个有效的身份证号码，请更正"


def add_reserve_message(state: ReserveState):
    reserve_prompt="""
    根据提供的信息，帮我预定房源。
- 预定的房源标题：{title}
- 用户预定号码：{phone_number}
- 用户身份证号码：{id_card}
    """

    return {"messages": [HumanMessage(content=reserve_prompt.format(
        title=state["title"],
        phone_number=state["phone_number"],
        id_card=state["id_card"]
    ))]}


@tool
def generate_orders(phone_number: str, id_card:str,house_title: str,
                    runtime:ToolRuntime,store:Annotated[Any,InjectedStore()])->str:
    """
    根据用户电话、身份证、预定的房源、生成工单号。

    Args:
        phone_number:用户电话
        id_card:身份证
        house_title:用户要预定的房源标题
        runtime:工具运行时的信息
        store:注入工具的持久储存
    """
    order_id = str(uuid.uuid4())

    # 身份证脱敏后再落库，避免明文敏感信息入库（仅保留后 4 位）
    masked_id = ("****" + id_card[-4:]) if id_card and len(id_card) >= 4 else id_card

    conn = get_conn()
    try:
        with conn.cursor() as cur:
            cur.execute(
                "INSERT INTO reservation_orders "
                "(order_id, phone_number, id_card, house_title) "
                "VALUES (%s, %s, %s, %s)",
                (order_id, phone_number, masked_id, house_title),  # 参数化，防 SQL 注入
            )
        conn.commit()
    finally:
        conn.close()

    reserved_info = ReservedInfo(
        order_id=order_id,
        title=house_title,
        phone_number=phone_number,
    )

    user_id = runtime.context.get("user_id")
    namespace = (user_id, "preferences")

    prefs_result = store.search(namespace)
    if len(prefs_result) == 0:
        # 无偏好数据：新增（统一存为 model_dump 后的 dict）
        prefs = UserPreferences(reserved_info=[reserved_info])
        store.put(
            namespace,
            str(uuid.uuid4()),
            prefs.model_dump(exclude_none=True),
        )
    else:
        # 有偏好数据：还原为对象 -> 追加 -> 再统一 dump，保证新增/更新格式一致
        prefs = UserPreferences(**(prefs_result[0].value or {}))
        prefs.reserved_info = (prefs.reserved_info or []) + [reserved_info]
        store.put(
            namespace,
            prefs_result[0].key,
            prefs.model_dump(exclude_none=True),
        )

    return f"已成功预定房源：{house_title}, 预定工单号为：{order_id}"

tool_node=ToolNode([generate_orders])

def call_orders(state: ReserveState):
    return {"messages": [model.bind_tools([generate_orders]).invoke(
        [SystemMessage(content="你是一个工单生成的助手，支持调用工具进行房源预定工单生成。支持查看结果并返回最终答案")]
        + state["messages"]
    )]}