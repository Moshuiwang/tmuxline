#!/bin/bash
# 跑全部测试:bash 燃速函数 / 渲染器 / codex 侧 python。任一失败退出非 0。
cd "$(dirname "$0")" || exit 1
rc=0
bash test_rate.sh || rc=1
bash test_render.sh || rc=1
bash test_sysload.sh || rc=1
bash test_subagent.sh || rc=1
python3 test_codex_rate.py || rc=1
[ "$rc" = 0 ] && echo "ALL OK" || echo "SOME FAILED"
exit $rc
