#!/usr/bin/env python3
"""codex/tmux-codex-quota-refresh.py 的周燃速函数测试:与 tests/test_rate.sh 同一组情形。"""
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
sys.exit(fail)
