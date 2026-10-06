FROM langchain/langgraph-api:3.11-wolfi

# 使用国内 PyPI 镜像加速依赖下载（uv pip 和 pip 都覆盖）
ENV UV_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple
ENV UV_DEFAULT_INDEX=https://pypi.tuna.tsinghua.edu.cn/simple
ENV PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple
# 把 uv 的下载缓存固定到下面 cache mount 挂载的目录，重建时可复用
ENV UV_CACHE_DIR=/root/.cache/uv



# -- Adding local package . --
ADD . /deps/my_langgraph_app
# -- End of local package . --

# -- Installing all local dependencies --
# 用 BuildKit 的缓存挂载复用 uv 下载缓存：第二次重建时依赖不必再从网上下载。
# 若 Docker 版本较老报 "the --mount option requires BuildKit"，把开头的
# `--mount=type=cache,target=/root/.cache/uv \` 删掉即可回退成原始写法。
RUN --mount=type=cache,target=/root/.cache/uv \
    for dep in /deps/*; do \
      echo "Installing $dep"; \
      if [ -d "$dep" ]; then \
        (cd "$dep" && PYTHONDONTWRITEBYTECODE=1 uv pip install --system -c /api/constraints.txt -e .); \
      fi; \
    done
# -- End of local dependencies install --
ENV LANGSERVE_GRAPHS='{"agent": "/deps/my_langgraph_app/src/agent/graph.py:graph", "house_agent": "/deps/my_langgraph_app/src/agent/graph.py:graph", "recommended_agent": "/deps/my_langgraph_app/src/agent/recommend.py:recommended_graph", "reserve_agent": "/deps/my_langgraph_app/src/agent/reserve.py:reserve_graph", "extend_agent": "/deps/my_langgraph_app/src/agent/extend.py:extend_graph"}'



# -- Ensure user deps didn't inadvertently overwrite langgraph-api
RUN mkdir -p /api/langgraph_api /api/langgraph_runtime /api/langgraph_license && touch /api/langgraph_api/__init__.py /api/langgraph_runtime/__init__.py /api/langgraph_license/__init__.py
RUN PYTHONDONTWRITEBYTECODE=1 uv pip install --system --no-cache-dir --no-deps -e /api
# -- End of ensuring user deps didn't inadvertently overwrite langgraph-api --
# -- Removing build deps from the final image ~<:===~~~ --
RUN pip uninstall -y pip setuptools wheel
RUN rm -rf /usr/local/lib/python*/site-packages/pip* /usr/local/lib/python*/site-packages/setuptools* /usr/local/lib/python*/site-packages/wheel* && find /usr/local/bin -name "pip*" -delete || true
RUN rm -rf /usr/lib/python*/site-packages/pip* /usr/lib/python*/site-packages/setuptools* /usr/lib/python*/site-packages/wheel* && find /usr/bin -name "pip*" -delete || true
RUN uv pip uninstall --system pip setuptools wheel && rm /usr/bin/uv /usr/bin/uvx

WORKDIR /deps/my_langgraph_app