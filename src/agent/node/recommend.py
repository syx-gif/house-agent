import os
import uuid
from platform import system
from sysconfig import get_scheme_names
from typing import Optional
import warnings

from dotenv import load_dotenv
from langchain_community.agent_toolkits import SQLDatabaseToolkit
from langchain_community.tools import QuerySQLDatabaseTool
from langchain_community.utilities import SQLDatabase
from langchain_core.messages import filter_messages, HumanMessage, SystemMessage, AIMessage
from langgraph.prebuilt import ToolNode
from langgraph.runtime import Runtime
from langgraph.store.base import BaseStore
from langgraph.types import interrupt, StreamWriter
from pydantic import BaseModel, Field

from src.agent.common.context import ContextSchema
from src.agent.common.llm import model
from src.agent.common.store import UserPreferences
from src.agent.state.recommend import RecommendState, get_recommend_info



warnings.filterwarnings("ignore", category=DeprecationWarning, module="langchain_community")

class UserInfo(BaseModel):
    city: Optional[str] = Field(
        default=None,
        description="用户所在或想要租房的城市，例如：西安、北京、上海"
    )
    district: Optional[str] = Field(
        default=None,
        description="用户想要租房的具体区域或行政区，例如：雁塔区、碑林区、海淀区"
    )
    budget_min: Optional[float] = Field(
        default=None,
        description="用户的最低预算，单位为元/月。如果是xx元以内，要设置最小值为0"
    )
    budget_max: Optional[float] = Field(
        default=None,
        description="用户的最高预算，单位为元/月。如果是xx元以上，最大值设置为10000"
    )
    room_type: Optional[str] = Field(
        default=None,
        description="房屋类型，例如：整租、合租、公寓、一室一厅、两室一厅"
    )
    orientation: Optional[str] = Field(
        default=None,
        description="房屋朝向，例如：朝南、朝北、东南、南北通透"
    )
    room_count: Optional[int] = Field(
        default=None,
        description="需要推荐的房屋数量"
    )
    others: Optional[str] = Field(
        default=None,
        description="特殊要求，例如：带阳台、独立卫生间、近地铁、可养宠物、有电梯等"
    )


def collect_user_info(state: RecommendState, runtime: Runtime[ContextSchema], *, store: BaseStore, writer: StreamWriter):
    """收集用户希望的推荐信息"""
    writer({"type": "progress", "step": "collect_user_info", "message": "🏠 正在收集您的租房需求..."})


    user_messages = filter_messages(state["messages"], include_types="human")
    pref = state.get("user_preferences")
    if pref and (pref["budget_min"] or pref["budget_max"]):
        # 偏好中包含最低和最高预算
        extract_messages = [
            HumanMessage(content="用户的历史偏好信息如下："
                         f"1. 最低预算：{pref['budget_min']}"
                         f"2. 最高预算：{pref['budget_max']}"),
            user_messages[-1]
        ]
    else:
        # 无偏好数据
        extract_messages = [user_messages[-1]]

    # 2. 提取信息(LLM结构化返回)
    # 拓展：将信息与数据库表中的字段进行映射
    def extract_info(messages) -> UserInfo:
        system_message = SystemMessage(
            content="""
你是一个租房需求信息提取专家。请从用户的描述与历史信息中提取租房相关信息。
如果用户历史偏好信息与最新用户消息冲突，以最新的用户消息为主。
只提取用户明确提到的信息，不要猜测或推断。
如果某个信息用户没有提到，就返回null。
注意预算的单位可能是元/月、元/天等，请统一转换为元/月。
如果用户提到价格范围，请分别提取最低和最高预算。
如果用户提到推荐几套房，提取room_count字段。"""
        )
        return model.with_structured_output(schema=UserInfo, method="function_calling").invoke([system_message] + messages)

    # 更新状态函数
    def update_state(current_state: dict, info: UserInfo) -> dict:
        if not info:
            return current_state

        user_info_dict = info.model_dump(exclude_none=True)
        current_state.update(user_info_dict)
        return current_state


    # 根据历史偏好和用户消息提取消息
    updated_state = {}
    extracted_info = extract_info(extract_messages)
    updated_state = update_state(updated_state, extracted_info)

    # 3. 中断咨询推荐的必须参数
    # 场景2：
    # 最新的用户消息：给我推荐房子（并未表明推荐城市，模糊推荐）
    # 询问用户意向城市

    # 检查是否缺失关键信息: 城市、预算范围
    missing_info = []
    if not updated_state.get("city"):
        missing_info.append("**城市**")
    if updated_state.get("budget_min") is None or updated_state.get("budget_max") is None:
        missing_info.append("**预算范围**")

    if missing_info:
        prompt = f"为了给您推荐合适的房源，请提供以下信息:{'，'.join(missing_info)}和其它信息。\n"
        prompt += "如果您不想提供，请输入'**不提供**',我会根据已有信息为您推荐房源。"
        # 根据缺失的信息进行中断
        answer = interrupt(prompt)
        if str(answer).strip() == "不提供":
            # 已经缺失关键信息，而且用户还不提供。需要给关键信息设置默认值
            if not updated_state.get("city"):
                updated_state["city"] = "随机城市"
            if not updated_state.get("budget_min"):
                updated_state["budget_min"] = 500.0
            if not updated_state.get("budget_max"):
                updated_state["budget_max"] = 5000.0
            if not updated_state.get("room_count"):
                updated_state["room_count"] = 5
        else:
            # 缺失关键信息，但用户已经补充
            # 将answer构建为HumanMessage
            user_response_msg = HumanMessage(content=str(answer))
            extracted_info = extract_info([user_response_msg])
            # updated_state就是包含了中断的结果
            updated_state = update_state(updated_state, extracted_info)



    if updated_state.get("budget_min") or updated_state.get("budget_max"):
        # 有可能会更新
        user_id = (runtime.context or {}).get("user_id")
        namespace = (user_id, "preferences")
        prefs_result = store.search(namespace)
        if len(prefs_result) == 0:
            # 新增
            prefs = UserPreferences(
                budget_min=updated_state.get("budget_min"),
                budget_max=updated_state.get("budget_max"),
            )
            store.put(namespace,
                      str(uuid.uuid4()),
                      prefs.model_dump(exclude_none=True))
            updated_state["user_preferences"] = prefs.model_dump(exclude_none=True)
        else:
            # 有持久化信息，判断更新
            # store:  1000-5000
            # state:  2000-3000   不用更新
            # state:  500-6000    需要更新  store:  500-6000
            prefs = prefs_result[0].value
            store_min = prefs["budget_min"]
            store_max = prefs["budget_max"]
            cur_min = updated_state.get("budget_min")
            cur_max = updated_state.get("budget_max")
            update_min = False  # 是否更新最小预算
            update_max = False  # 是否更新最大预算
            if store_min is not None and cur_min is not None and cur_min < store_min:
                # 都不为空，就比较
                update_min = True
            elif store_min is None and cur_min is not None:
                # store 没有，但 cur 有
                update_min = True

            if store_max is not None and cur_max is not None and cur_max > store_max:
                update_max = True
            elif store_max is None and cur_max is not None:
                update_max = True

            if update_min or update_max:
                if update_min:
                    prefs["budget_min"] = cur_min
                if update_max:
                    prefs["budget_max"] = cur_max
                # 更新操作
                store.put(
                    namespace,
                    prefs_result[0].key,  # 根据查询到的key进行更新
                    prefs
                )
                updated_state["user_preferences"] = prefs

    updated_state["message"]=[HumanMessage(content=get_recommend_info(updated_state))]

    print(f"已收集用户信息：\n城市：{updated_state.get('city')}"
          f"区域：{updated_state.get('district')}"
          f"预算：{updated_state.get('budget_min')}-{updated_state.get('budget_max')}元/月"
          f"房间数：{updated_state.get('room_count')}")
    

    return updated_state


load_dotenv()
db_user = os.getenv('DB_USER')
db_password = os.getenv('DB_PASSWORD')
db_host = os.getenv('DB_HOST')
db_port = os.getenv('DB_PORT')
db_name = os.getenv('DB_NAME')
db = SQLDatabase.from_uri(f"mysql+pymysql://{db_user}:{db_password}@{db_host}:{db_port}/{db_name}")

# 获取数据库工具
toolkit = SQLDatabaseToolkit(db=db, llm=model)
tools = toolkit.get_tools()


#获取表信息
# 节点：获取表信息
get_schema_tool =  next(tool for tool in tools if tool.name == "sql_db_schema")
get_schema_node = ToolNode([get_schema_tool], name="get_schema")  # 工具执行节点（返回ToolMessage）
# 节点：执行sql查询
run_query_tool =  next(tool for tool in tools if tool.name == "sql_db_query")
run_query_node = ToolNode([run_query_tool], name="run_query")
# 工具执行节点（返回ToolMessage）

def list_tables(state: RecommendState, writer: StreamWriter):
    writer({"type": "progress", "step": "list_tables", "message": "📑 正在查看数据库表..."})
    # 1. 获取AIMessage(tool_calls)
    tool_call = {
        "name": "sql_db_list_tables",
        "args": {},
        "id": "123123",
        "type": "tool_call",
    }
    # 模拟必定调用工具
    tool_call_message = AIMessage(content="", tool_calls=[tool_call])

    # 2. 手动调用工具：sql_db_list_tables
    list_tables_tool = next(tool for tool in tools if tool.name == "sql_db_list_tables")
    tool_message = list_tables_tool.invoke(tool_call)

    # 3. 整合结果
    response = AIMessage(content=f"可用的表：{tool_message.content}")
    return {
        "messages": [tool_call_message, tool_message, response]
    }

def _real_table_names() -> str:
    """从数据库直接读出真实存在的表名。

    这里原来是让 LLM 自己"猜"要查哪张表，结果模型编出了
    rentals / houses / listings / apartments 等根本不存在的英文表名，
    sql_db_schema 报 "table_names ... not found in database"，
    导致拿不到表结构 -> 生成的 SQL 也错 -> 无条件回环无限重试（前端一直刷屏）。
    表名本来就能从库里直接查，不需要让模型猜。
    """
    try:
        names = db.get_usable_table_names()
        if names:
            return ", ".join(names)
    except Exception as exc:  # 库暂时连不上时兜底，不要因此崩掉整条流程
        print(f"[warn] 读取真实表名失败，回退到已知表名：{exc}")
    return "house, reservation_orders"


# 节点：绑定工具（获取表信息），让LLM将来必定执行工具节点
def call_get_schema(state: RecommendState, writer: StreamWriter):
    writer({"type": "progress", "step": "call_get_schema", "message": "🔍 正在获取表结构..."})
    # 直接用真实表名构造工具调用，不再让 LLM 猜（猜错就会死循环）
    tool_call = {
        "name": "sql_db_schema",
        "args": {"table_names": _real_table_names()},
        "id": str(uuid.uuid4()),
        "type": "tool_call",
    }
    return {"messages": [AIMessage(content="", tool_calls=[tool_call])]}

# SQL 最多重试几次。超过就放弃并给用户一句人话，避免无限刷屏 / GraphRecursionError
MAX_SQL_RETRY = 3


def generate_query(state: RecommendState, writer: StreamWriter):
    # ---- 护栏 1：重试次数上限 ----
    # check_query -> run_query -> generate_query 是一条无条件回环，
    # 如果 SQL 一直失败，没有这个护栏就会一直转到步数上限（表现为前端持续刷屏）。
    retry = state.get("retry_count") or 0
    if retry >= MAX_SQL_RETRY:
        writer({"type": "progress", "step": "give_up",
                "message": f"⚠️ 已重试 {retry} 次仍未查到结果，停止重试"})
        return {
            "messages": [AIMessage(content=(
                "抱歉，我尝试了多次仍未查询到符合条件的房源。\n\n"
                "建议放宽一下条件再试：\n"
                "- 提高预算上限\n"
                "- 换一个城市或区域\n"
                "- 放宽房型 / 朝向要求"
            ))]
        }

    writer({"type": "progress", "step": "generate_query", "message": "💡 正在生成 SQL 查询..."})
    generate_query_system_prompt = """
您是一个设计用于与SQL数据库交互的代理。
给定一个输入问题，创建一个语法正确的{dialect}查询来运行，然后查看查询的结果并返回答案。
需要根据rows from table的示例设置真实查询的值。
除非用户指定了他们希望获得的特定数量的示例，否则始终将查询限制为最多{top_k}个结果。
您可以按相关列对结果排序，以返回最感兴趣的结果。不要查询特定表中的所有列，只查询给定问题的相关列。
不要对数据库做任何DML语句（INSERT， UPDATE， DELETE， DROP等)。
重要：如果历史消息中已经存在查询结果（ToolMessage），请直接根据该结果总结并给出最终推荐，不要再次调用 run_query_tool。
数据库里只有下面这两张表，表名必须严格照抄，禁止臆造其它表名（如 rentals/listings/apartments/properties 等）：
- 房源表：house        —— 所有房源信息都在这一张表里
- 订单表：reservation_orders —— 用户的预订记录
数据库字段与取值映射（生成 SQL 时必须严格遵守）：
- 租房类型在 rent_type 字段，取值为英文代码：省心租=worry_free_rental，公寓=apartment，合租=share_rent，个人房源=personal_house，整租=whole 或 whole_rent（两个值都要匹配，建议写成 rent_type IN ('whole','whole_rent')）
- 朝向在 position 字段，取值为英文：南=south（其他方向请先执行 SELECT DISTINCT position FROM house; 确认后再补）
- 预算对应 price 字段（单位：元/月），用 BETWEEN 下限 AND 上限
- 城市对应 city_name，区域对应 region_name，社区对应 community_name
- 用户要求的推荐套数用 LIMIT 限制（默认 5）
- 特殊要求（带阳台、近地铁等）在 intro 或 devices 字段用 LIKE '%关键词%' 模糊匹配
如果上一次查询报错，不要重复提交同一条错误 SQL：先核对表名和字段名，改对之后再提交。

【最终回答格式 —— 必须严格遵守。前端聊天窗很窄（约 450px），列一多、字一长就会被挤成一团】
1. SELECT 只取下面 7 个字段，绝对不要 SELECT *，也不要带出 intro / devices / images / head_image / id / user_id / title / longitude / latitude 这些长字段：
   SELECT rent_type, house_type, area, price, city_name, region_name, community_name FROM house ...
   （WHERE 里仍然可以用 title 做模糊匹配，只是不要把 title 放进 SELECT）
2. 最终答案只输出一个 Markdown 表格，固定 5 列，表头必须原样照抄这一行：
   | 房源 | 区域 | 户型 | 面积 | 租金(元/月) |
3. 每一列怎么填（不要自由发挥，按下面的规则生成）：
   - 房源 = 中文租房类型 + "·" + community_name；中文类型换算：whole/whole_rent=整租，share_rent=合租，worry_free_rental=省心租，apartment=公寓，personal_house=个人房源。例：整租·金通阳光苑
   - 区域 = city_name + "·" + region_name。例：北京·丰台
   - 户型 = house_type 原值。例：3室1厅1卫
   - 面积 = area 取整数后加 "㎡"。例：100㎡
   - 租金(元/月) = price 取整数。例：5850
4. 严禁把 intro / devices / images 等长文本、原始经纬度、原始 SQL、工具返回的原始文本贴到回答里。
5. 篇幅限制：表格上方最多一句话（不超过 30 字，例："已为您找到 5 套符合条件的房源："）；
   表格下方最多 3 条一句话小建议，每条不超过 20 字。除此之外不要再写任何内容。
6. 不要逐个房源写详细介绍，不要写"第 1 套……第 2 套……"这种长段落。
        """
    system_prompt = generate_query_system_prompt.format(
        dialect=db.dialect,
        top_k=state.get("room_count", 5)
    )

    system_message = SystemMessage(content=system_prompt)
    llm_with_tools = model.bind_tools([run_query_tool])
    return {
        "messages": [llm_with_tools.invoke([system_message] + state["messages"])],  # AIMessage(tool_call?)
        "retry_count": retry + 1,
    }


def check_query(state: RecommendState, writer: StreamWriter):
    writer({"type": "progress", "step": "check_query", "message": "✅ 正在检查 SQL 正确性..."})
    check_query_system_prompt = """
    你是一个非常注重细节的SQL专家。仔细检查{dialect}查询中的常见错误，包括：
    -使用NULL值的NOT IN
    -在应该使用UNION ALL时使用UNION
    -使用BETWEEN表示独占范围
    -谓词中的数据类型不匹配
    -正确引用标识符
    -使用正确数量的函数参数
    -转换为正确的数据类型
    -使用合适的列进行连接
    如果存在上述任何错误，请重写查询。如果没有错误，只需复制原始查询即可。
    在运行此检查之后，您将调用适当的工具来执行查询。
            """.format(dialect=db.dialect)
    system_message = SystemMessage(content=check_query_system_prompt)
    # 将SQL当作用户消息传入进行检查
    tool_call = state["messages"][-1].tool_calls[0]
    user_message =HumanMessage(content=tool_call["args"]["query"])
    llm_with_tools = model.bind_tools([run_query_tool])
    response = llm_with_tools.invoke([system_message,user_message])
    response.id=state["messages"][-1].id
    return {"messages": [response]}