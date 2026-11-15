#!/usr/bin/env python3
"""agy/tmux-agy-quota-refresh.py 的解析、选桶与周燃速测试(不联网、不调真实 agy)。"""
import importlib.util, json, os, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
work = tempfile.mkdtemp()
os.environ["TMUX_AGY_STATE_DIR"] = work
spec = importlib.util.spec_from_file_location("agy_refresh", os.path.join(ROOT, "agy", "tmux-agy-quota-refresh.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

WEEK = 604800
R = 1800000000
WS = R - WEEK
fail = 0


def chk(got, want, name):
    global fail
    ok = got == want
    print(("ok   " if ok else "FAIL ") + name, got, "" if ok else f"want {want}")
    fail |= not ok


# 1. 解析真实 `agy -p /usage --output-format json` 结构
sample_stdout = json.dumps(
    {
        "conversation_id": "",
        "status": "SUCCESS",
        "num_turns": 0,
        "command": {
            "name": "usage",
            "data": {
                "groups": [
                    {
                        "name": "Gemini Models",
                        "buckets": [
                            {
                                "id": "gemini-weekly",
                                "window": "weekly",
                                "remaining_fraction": 0.9983198642730713,
                                "reset_time": "2026-11-18T10:24:56Z",
                            },
                            {
                                "id": "gemini-5h",
                                "window": "5h",
                                "remaining_fraction": 0.9941195249557495,
                                "reset_time": "2026-11-11T15:24:56Z",
                            },
                        ],
                    },
                    {
                        "name": "Claude and GPT models",
                        "buckets": [
                            {
                                "id": "3p-weekly",
                                "window": "weekly",
                                "remaining_fraction": 0.4968104064464569,
                                "reset_time": "2026-11-18T09:25:39Z",
                            },
                            {
                                "id": "3p-5h",
                                "window": "5h",
                                "remaining_fraction": 0,
                                "reset_time": "2026-11-11T14:25:39Z",
                            },
                        ],
                    },
                    {
                        "name": "Gemini 4 Argon",
                        "buckets": [
                            {
                                "id": "gemini-argon-wtu-weekly",
                                "window": "weekly",
                                "remaining_fraction": 0.8205334544181824,
                                "reset_time": "2026-11-18T09:25:19Z",
                            }
                        ],
                    },
                ]
            },
        },
    }
)

buckets = m._parse_usage_stdout(sample_stdout)
chk(len(buckets), 5, "解析出 5 个桶")
h5, p3, ar, gm = m._select_buckets(buckets, now=1794390000)
chk((h5.bucket_id, h5.used_percent), ("3p-5h", 100), "5h 选已用最高的 3p-5h(100%)")
chk((p3.bucket_id, p3.used_percent), ("3p-weekly", 50), "3p 周桶 50%")
chk((ar.bucket_id, ar.used_percent), ("gemini-argon-wtu-weekly", 18), "Argon 周桶 18%")
chk((gm.bucket_id, gm.used_percent), ("gemini-weekly", 0), "Gemini 周桶 0%")

# 2. 7 列周历史追加与按列拆序列算燃速
m.RATE24_WIN = 86400
m.RATE24_MIN_SPAN = 21600
for k in range(25):
    lines = m._append_week_history(
        WS + k * 3600,
        str(10 + k),
        str(R),
        str(5 + k // 2),
        str(R + 10),
        "0",
        str(R + 3600),
    )
now = WS + 24 * 3600
p3_series = m._extract_series(lines, 1, now)
ar_series = m._extract_series(lines, 3, now)
gm_series = m._extract_series(lines, 5, now)
chk(m._week_rate(p3_series, now, "34", str(R)), ("168", "-"), "3p 24h 燃速 1%/h -> 168%/周")
chk(m._week_rate(ar_series, now, "17", str(R + 10)), ("84", "-"), "Ar 24h 燃速 0.5%/h -> 84%/周")
chk(m._week_rate(gm_series, now, "0", str(R + 3600)), ("0", "-"), "Gm 24h 燃速 0")

# 3. 异常输入拒绝
for bad, label in (("", "空文本"), ("{}", "无 groups"), ('{"command":{"data":{"groups":[]}}}', "空 groups")):
    try:
        m._parse_usage_stdout(bad)
        got = "no error"
    except m.ProviderError:
        got = "ProviderError"
    chk(got, "ProviderError", "拒绝非法输出:" + label)

chk("wangzp" in open(os.path.join(ROOT, "agy", "tmux-agy-quota-refresh.py")).read(), False, "脚本不写死用户名")
sys.exit(fail)
