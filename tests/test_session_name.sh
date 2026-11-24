#!/bin/bash
# 会话名与 CPU/内存格宽测试(2026-11-24):在独立 tmux server(-L)里加载仓库 tmux.conf,不碰正在用的 tmux。
ROOT=$(cd "$(dirname "$0")/.." && pwd); S=nametest$$; T="tmux -L $S"
trap '$T kill-server 2>/dev/null' EXIT
fail=0
chk() { if [ "$1" = "$2" ]; then echo "ok   $3 → $1"; else echo "FAIL $3: got '$1' want '$2'"; fail=1; fi; }

$T -f "$ROOT/tmux.conf" new-session -d -x 200 -y 20 'sleep 60'
chk "$($T ls -F '#S')" "TZ-server" "启动时第一个默认名会话自动叫 TZ-server"
$T new-session -d 'sleep 60'; $T new-session -d -s mine 'sleep 60'
chk "$($T ls -F '#S' | LC_ALL=C sort | tr '\n' ' ')" "1 TZ-server mine " "已有 TZ-server 时新会话保持数字名;手动起名不受影响"

# 宽屏分支下 CPU/内存格宽(@sys_w = 徽标去样式格宽 - 3)必须 >= 9,才放得下「C23% M61%」
SL=$($T source-file "$ROOT/claude/tmux-status-extra.conf" 2>/dev/null; $T show -gv status-left); f=${SL//'#{e|<:#{client_width},100}'/0}
w() { local o; o=$($T display -p -t "=$1:" "$f" | sed 's/#\[[^]]*\]//g'); echo $(( ${#o} - 3 )); }
chk "$(w 1)" "9" "短名会话:格宽补到 9"
chk "$(w TZ-server)" "10" "TZ-server:格宽与改前一致"
exit $fail
