import os

from dotenv import load_dotenv
from langchain_openai import ChatOpenAI

# 自动从项目根目录的 .env 读取 key（即使运行环境没有预先 export 也能生效）
load_dotenv()

# 智谱 GLM 支持 OpenAI 兼容协议，直接用 ChatOpenAI 调用，
# 避免 zhipuai SDK 与 LangGraph 基础镜像的 pyjwt 版本冲突。
# .env 里需配置 ZHIPUAI_API_KEY / MODEL_NAME / MODEL_TEMPERATURE
model = ChatOpenAI(
    model=os.getenv("MODEL_NAME", "glm-4.7"),
    temperature=float(os.getenv("MODEL_TEMPERATURE", "0")),
    api_key=os.getenv("ZHIPUAI_API_KEY"),
    base_url="https://open.bigmodel.cn/api/paas/v4/",
)
