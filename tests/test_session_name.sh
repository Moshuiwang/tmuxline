#!/bin/bash
# 会话名与 CPU/内存格宽测试(2026-11-24):在独立 tmux server(-L)里加载仓库 tmux.conf,不碰正在用的 tmux。
# 会话名文件用 TMUXLINE_SESSION_NAME_FILE 指到临时位置,不受本机 ~/.claude/tmux-session-name 影响。
ROOT=$(cd "$(dirname "$0")/.." && pwd); S=nametest$$; T="tmux -L $S"; T2="tmux -L ${S}b"
TMP=$(mktemp -d)
trap '$T kill-server 2>/dev/null; $T2 kill-server 2>/dev/null; rm -rf "$TMP"' EXIT
fail=0
chk() { if [ "$1" = "$2" ]; then echo "ok   $3 → $1"; else echo "FAIL $3: got '$1' want '$2'"; fail=1; fi; }

# 没有会话名文件:缺省 TZ-server
TMUXLINE_SESSION_NAME_FILE="$TMP/none" $T -f "$ROOT/tmux.conf" new-session -d -x 200 -y 20 'sleep 60'
chk "$($T ls -F '#S')" "TZ-server" "无会话名文件:第一个默认名会话自动叫 TZ-server"
$T new-session -d 'sleep 60'; $T new-session -d -s mine 'sleep 60'
chk "$($T ls -F '#S' | LC_ALL=C sort | tr '\n' ' ')" "1 TZ-server mine " "已有 TZ-server 时新会话保持数字名;手动起名不受影响"

# 有会话名文件:用文件第一行(去空白)
printf ' Cote \nignored\n' > "$TMP/name"
TMUXLINE_SESSION_NAME_FILE="$TMP/name" $T2 -f "$ROOT/tmux.conf" new-session -d 'sleep 60'
$T2 new-session -d 'sleep 60'
chk "$($T2 ls -F '#S' | LC_ALL=C sort | tr '\n' ' ')" "1 Cote " "会话名文件写 Cote:第一个会话叫 Cote,第二个保持数字名"

# 宽屏分支下 CPU/内存格宽(@sys_w = 徽标去样式格宽 - 3)必须 >= 9,才放得下「C23% M61%」
SL=$($T source-file "$ROOT/claude/tmux-status-extra.conf" 2>/dev/null; $T show -gv status-left); f=${SL//'#{e|<:#{client_width},100}'/0}
w() { local o; o=$($T display -p -t "=$1:" "$f" | sed 's/#\[[^]]*\]//g'); echo $(( ${#o} - 3 )); }
chk "$(w 1)" "9" "短名会话:格宽补到 9"
chk "$(w TZ-server)" "10" "TZ-server:格宽与改前一致"
exit $fail
