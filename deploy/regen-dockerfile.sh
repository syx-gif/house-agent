#!/usr/bin/env bash
# ============================================================
# 重新生成 Dockerfile，并自动注入「国内 pip 源 + BuildKit 缓存」优化。
#
# 为什么需要它：
#   `langgraph dockerfile` 每次都会把 Dockerfile 覆盖成原始版本，
#   手动加的加速配置会丢。跑这个脚本 = 生成 + 自动补优化，一条搞定。
#
# 用法（项目根目录或任意位置都行）：
#   bash deploy/regen-dockerfile.sh
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

LANGGRAPH_BIN="$(command -v langgraph || true)"
[ -z "$LANGGRAPH_BIN" ] && LANGGRAPH_BIN="$HOME/.local/bin/langgraph"

if [ ! -x "$LANGGRAPH_BIN" ]; then
  echo "❌ 找不到 langgraph 命令。先安装：pip install --user langgraph-cli" >&2
  exit 1
fi

echo "==> 1/3 生成 Dockerfile"
"$LANGGRAPH_BIN" dockerfile -c langgraph.json Dockerfile

echo "==> 2/3 注入国内 PyPI 源 + uv 缓存目录"
python3 - <<'PY'
import pathlib
p = pathlib.Path("Dockerfile")
s = p.read_text(encoding="utf-8")

BLOCK = (
    "\n\n# --- 构建提速：国内 PyPI 镜像 + uv 缓存目录 ---\n"
    "ENV UV_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple\n"
    "ENV UV_DEFAULT_INDEX=https://pypi.tuna.tsinghua.edu.cn/simple\n"
    "ENV PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple\n"
    "ENV UV_CACHE_DIR=/root/.cache/uv\n"
)

if "PIP_INDEX_URL" not in s:
    s = s.replace("FROM langchain/langgraph-api:3.11-wolfi",
                  "FROM langchain/langgraph-api:3.11-wolfi" + BLOCK, 1)
    print("   - 已插入 ENV 提速配置")
else:
    print("   - ENV 提速配置已存在，跳过")
p.write_text(s, encoding="utf-8")
PY

echo "==> 3/3 给依赖安装层加 BuildKit 缓存挂载"
python3 - <<'PY'
import re, pathlib
p = pathlib.Path("Dockerfile")
s = p.read_text(encoding="utf-8")

if "mount=type=cache,target=/root/.cache/uv" in s:
    print("   - 缓存挂载已存在，跳过")
else:
    def fix(m):
        body = m.group(0)
        body = body.replace("--no-cache-dir ", "")   # 让 uv 用缓存
        body = body.replace(
            "RUN for dep in /deps/*",
            "RUN --mount=type=cache,target=/root/.cache/uv \\\n    for dep in /deps/*",
            1,
        )
        return body

    new, n = re.subn(
        r"RUN for dep in /deps/\*;.*?(?=\n# -- End of local dependencies install --)",
        fix, s, flags=re.S,
    )
    if n == 0:
        print("   ! 没找到依赖安装层，未改动（请检查生成的 Dockerfile）")
    else:
        s = new
        print("   - 已加缓存挂载并去掉 --no-cache-dir")
    p.write_text(s, encoding="utf-8")
PY

echo
echo "✅ 完成。核对一下："
grep -n "UV_INDEX_URL\|mount=type=cache\|no-cache-dir" Dockerfile || true
echo
echo "下一步：  docker compose up -d --build langgraph-api"
