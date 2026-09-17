#!/usr/bin/env python3
"""codex/tmux-codex-quota-refresh.py 的周燃速函数测试(与 tests/test_rate.sh 同一组情形)+ 内联拉取/解析层测试(不联网)。"""
import importlib.util, os, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
work = tempfile.mkdtemp()
os.environ["TMUX_CODEX_STATE_DIR"] = work
spec = importlib.util.spec_from_file_location("refresh", os.path.join(ROOT, "codex", "tmux-codex-quota-refresh.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

WEEK = 604800; R = 1000000; WS = R - WEEK; fail = 0

def chk(got, want, name):
    global fail
    ok = got == want
    print(("ok   " if ok else "FAIL ") + name, got, "" if ok else f"want {want}")
    fail |= not ok

h = [(WS + k * 3600, 10 + k, R) for k in range(31)]
chk(m._week_rate(h, WS + 30 * 3600, "40", str(R)), ("168", "-"), "同窗口 24h 燃速")
R2 = R + WEEK
h = [(R - 11 * 3600 + k * 3600, 50 + k, R) for k in range(11)] + [(R + k * 3600, k, R2) for k in range(6)]
chk(m._week_rate(h, R + 5 * 3600, "5", str(R2)), ("158", "60"), "跨重置燃速 + 上周终值")
h = [(WS + k * 3600, k, R) for k in range(3)]
chk(m._week_rate(h, WS + 2 * 3600, "2", str(R)), ("-", "-"), "历史不足 6h")
chk(m._week_rate([(R - 3 * WEEK, 70, R - 2 * WEEK)], R, "1", str(R)), ("-", "-"), "隔两周旧窗口")
h = [(WS + k * 3600, 30, R) for k in range(25)]
chk(m._week_rate(h, WS + 24 * 3600, "25", str(R)), ("0", "-"), "倒退钳 0")
chk(m._week_rate([], R, "5", str(R)), ("-", "-"), "空历史")
chk(m._week_rate(h, R, "-", "-"), ("-", "-"), "无周窗口")
m.WEEK_HISTORY_KEEP = 3
for k in range(5):
    m._append_week_history(WS + k * 300, str(k), str(R))
hist = m._append_week_history(WS + 5 * 300, "-", "-")
chk([x[1] for x in hist], [2, 3, 4], "历史文件只留 KEEP 行且缺失不追加")

# ---- 内联的拉取/解析层(2026-09-17 起不再依赖 ~/ai-usage-widget) ----
import json
def summary(ws): return [(w.window, int(w.used_percent), w.reset_at, w.window_duration_minutes) for w in ws]
wham = {"rate_limit": {"primary_window": {"used_percent": 12.7, "reset_at": "2026-09-17T12:00:00Z", "limit_window_seconds": 18000},
                       "secondary_window": {"used_percent": 55, "resets_at": 1789816245, "window_duration_minutes": 10080}}}
chk(summary(m._parse_windows(wham["rate_limit"], (("primary_window", "session"), ("secondary_window", "week")))),
    [("session", 12, "2026-09-17T12:00:00Z", 300), ("week", 55, "2026-09-19T11:10:45+00:00", 10080)], "WHAM 两窗口(秒时长 / 数字重置)")
chk(summary(m._parse_windows({"secondary_window": {"usedPercent": 3, "resetsAt": "2026-09-20T00:00:00+08:00"}},
                             (("primary_window", "session"), ("secondary_window", "week")))),
    [("week", 3, "2026-09-20T00:00:00+08:00", 0)], "只有周窗口 + 驼峰字段 + 缺时长")
for bad, name in (({}, "空对象"), ({"primary_window": 1}, "窗口不是对象"),
                  ({"primary_window": {"used_percent": "x", "reset_at": "2026-09-17T12:00:00Z"}}, "用量不是数"),
                  ({"primary_window": {"used_percent": 1}}, "缺重置时刻")):
    try: m._parse_windows(bad, (("primary_window", "session"),)); got = "no error"
    except m.ProviderError: got = "ProviderError"
    chk(got, "ProviderError", "解析拒绝:" + name)
rpc_line = json.dumps({"id": m.RPC_REQUEST_ID, "result": {"rate_limits": {"primary": {"usedPercent": 40, "resetsAt": "2026-09-17T12:00:00Z", "windowDurationMins": 300}}}})
chk(m._parse_rpc_stdout('{"id":"other","result":{}}\n' + rpc_line + "\n")["id"], m.RPC_REQUEST_ID, "RPC 多行输出挑本请求的那行")
try: m._parse_rpc_stdout("   "); got = "no error"
except m.ProviderError: got = "ProviderError"
chk(got, "ProviderError", "RPC 空输出")
auth = os.path.join(work, "auth.json")
open(auth, "w").write(json.dumps({"tokens": {"access_token": " tok-1 "}}))
chk(m._load_access_token(m.Path(auth)), "tok-1", "auth.json tokens.access_token")
open(auth, "w").write(json.dumps({"access_token": "tok-2"}))
chk(m._load_access_token(m.Path(auth)), "tok-2", "auth.json 顶层 access_token")
try: m._load_access_token(m.Path(work, "missing.json")); got = "no error"
except m.ProviderError: got = "ProviderError"
chk(got, "ProviderError", "auth.json 缺失")
chk("wangzp" in open(os.path.join(ROOT, "codex", "tmux-codex-quota-refresh.py")).read().split('"""', 2)[2], False, "脚本正文不写死用户名")
sys.exit(fail)
