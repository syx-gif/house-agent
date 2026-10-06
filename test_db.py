import os
from dotenv import load_dotenv

# 1) 先确认环境变量读到了
load_dotenv()
db_user = os.getenv('DB_USER')
db_password = os.getenv('DB_PASSWORD')
db_host = os.getenv('DB_HOST')
db_port = os.getenv('DB_PORT')
db_name = os.getenv('DB_NAME')

print("ENV:", db_user, db_password, db_host, db_port, db_name)
assert all([db_user, db_password, db_host, db_port, db_name]), "有变量是 None，.env 没读对！"

# 2) 引入你的智谱模型（和项目里一致）
from src.agent.common.llm import model

# 3) 建连接
from langchain_community.utilities import SQLDatabase
from langchain_community.agent_toolkits import SQLDatabaseToolkit

db = SQLDatabase.from_uri(f"mysql+pymysql://{db_user}:{db_password}@{db_host}:{db_port}/{db_name}")
print("URI 构建成功")

# 4) 真正发一条查询，验证网络+账号+库都通
result = db.run("SELECT COUNT(*) FROM house")
print("查询 house 表行数:", result)

# 5) 生成工具
toolkit = SQLDatabaseToolkit(db=db, llm=model)
tools = toolkit.get_tools()
print("工具数量:", len(tools))
print("全部通过 ✅")
