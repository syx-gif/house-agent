"""诊断：复现「推荐 -> 中断 -> 回复'不需要' -> 是否卡死」

直接调 langgraph-api 的 REST 接口，绕过前端，判断问题出在后端图逻辑还是前端展示。
用法：
    python deploy/diag-interrupt.py [服务地址]

例：
    python deploy/diag-interrupt.py http://127.0.0.1:8080
    python deploy/diag-interrupt.py https://你的域名
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

# 服务地址：优先取命令行第一个参数，其次环境变量 HOUSE_AGENT_URL。
# 注意：不要把真实服务器地址硬编码进文件 —— 仓库一旦公开就会暴露你的服务器。
BASE = (sys.argv[1] if len(sys.argv) > 1
        else os.environ.get("HOUSE_AGENT_URL", "http://127.0.0.1:8080"))
ASSISTANT = "house_agent"


def req(method, path, body=None, timeout=240):
    data = json.dumps(body).encode("utf-8") if body is not None else None
    r = urllib.request.Request(
        BASE + path, data=data, method=method,
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(r, timeout=timeout) as resp:
        raw = resp.read().decode("utf-8")
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return raw


def brief(state):
    """从返回的 state 里挑关键信息，避免刷屏"""
    if not isinstance(state, dict):
        return {"raw": str(state)[:200]}
    msgs = state.get("messages") or []
    return {
        "有中断": "__interrupt__" in state,
        "中断内容": [i.get("value", "")[:60].replace("\n", " ")
                     for i in (state.get("__interrupt__") or [])],
        "next": state.get("next"),
        "消息条数": len(msgs),
        "最后一条": (msgs[-1].get("type") if msgs and isinstance(msgs[-1], dict) else None),
    }


print("=" * 60)
print("步骤1：创建会话")
tid = req("POST", "/threads", {})["thread_id"]
print(f"  thread_id = {tid}")

print("=" * 60)
print("步骤2：发第一轮提问（会跑到 need_reserve 中断）")
t0 = time.time()
r1 = req("POST", f"/threads/{tid}/runs/wait", {
    "assistant_id": ASSISTANT,
    "input": {"messages": [{"role": "human", "content": "北京 5000 以内的两居室"}]},
    "context": {"user_id": "159"},
})
print(f"  耗时 {time.time() - t0:.1f}s")
print("  " + json.dumps(brief(r1), ensure_ascii=False))

print("=" * 60)
print("步骤3：查看 thread 状态（确认确实停在中断点）")
st = req("GET", f"/threads/{tid}/state")
print("  " + json.dumps(brief(st), ensure_ascii=False))

print("=" * 60)
print("步骤4：用 command.resume 回复『不需要』（前端就是这么发的）")
t0 = time.time()
try:
    r2 = req("POST", f"/threads/{tid}/runs/wait", {
        "assistant_id": ASSISTANT,
        "command": {"resume": "不需要"},
        "context": {"user_id": "159"},
    })
    print(f"  耗时 {time.time() - t0:.1f}s")
    print("  " + json.dumps(brief(r2), ensure_ascii=False))
except urllib.error.HTTPError as e:
    print(f"  ❌ HTTP {e.code}: {e.read().decode('utf-8', 'replace')[:500]}")

print("=" * 60)
print("步骤5：再次查看 thread 状态（next 为空 = 图已正常结束）")
st2 = req("GET", f"/threads/{tid}/state")
print("  " + json.dumps(brief(st2), ensure_ascii=False))

print("=" * 60)
print("步骤6：查看 run 状态")
try:
    runs = req("GET", f"/threads/{tid}/runs")
    for r in runs:
        print(f"  run={r.get('run_id', '')[:8]} status={r.get('status')}")
except urllib.error.HTTPError as e:
    print(f"  查询 runs 失败 HTTP {e.code}")

print("=" * 60)
print("结论判读：")
print("  步骤3 有中断 + 步骤5 next 为空  => 后端完全正常，问题在前端「跑完了没给任何反馈」")
print("  步骤4 报错 / 步骤5 仍有中断      => 后端 resume 逻辑有问题")
