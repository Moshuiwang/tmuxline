#!/bin/bash
# Claude 账号用量轮询器(2026-09-11)。由 tmux-claude-usage.sh 在数据过期时后台拉起,不常驻;
# 所以只在 tmux 开着的时候才打接口。
#
# 用本机 Claude Code 的登录凭据 GET 官方用量接口(就是 /usage 面板用的那个,账号级、跨设备),写三个文件:
#   ~/.claude/tmux-claude-usage-api.dat   一行十一列:时刻 5h% 5h重置 7d% 7d重置 Fable% Fable重置 7d燃速 7d上周 Fable燃速 Fable上周
#                                         (缺失写 "-",时刻均为 epoch 秒;后四列 2026-09-17 起,算法见 tmux-claude-usage-rate.sh)
#   ~/.claude/tmux-claude-usage-5h.hist   5h 采样历史(时刻 % 重置),渲染器据此算最近燃速,只留 HIST_KEEP 行
#   ~/.claude/tmux-claude-usage-7d.hist   周窗口采样历史(时刻 7d% 7d重置 Fable% Fable重置),本脚本据此算 24h 燃速与上周终值,
#                                         只留 HIST7_KEEP 行(5 分钟一采约 8.7 天,够跨一次周重置)
#   ~/.claude/tmux-claude-usage-api.last  本次尝试时刻(成功失败都写),渲染器据此限频,失败不会被反复拉起
#
# 铁律:
#   - 令牌只在本进程内存里过一下,经 stdin 交给 curl;不进命令行参数(/proc 可见)、不落盘、不打日志。
#   - 令牌已过期就不调接口,也绝不自行续期——续期是 Claude Code 的活,两边抢着续会把登录搞坏。
#     等下次开 Claude 自动续上,数据文件自然恢复更新。
#   - 任何失败静默退出、保留旧数据,由渲染器按过期规则隐藏,不显示误导信息。

DIR="$HOME/.claude"
CRED="$DIR/.credentials.json"
API="$DIR/tmux-claude-usage-api.dat"
HIST="$DIR/tmux-claude-usage-5h.hist"
LAST="$DIR/tmux-claude-usage-api.last"
LOCK="$DIR/tmux-claude-usage-poll.lock"
URL="https://api.anthropic.com/api/oauth/usage"
HIST7="$DIR/tmux-claude-usage-7d.hist"
HIST_KEEP=30
HIST7_KEEP=2500
. "$DIR/tmux-claude-usage-rate.sh"

umask 077
exec 9>"$LOCK"
flock -n 9 || exit 0
printf -v now '%(%s)T' -1
printf '%s\n' "$now" > "$LAST"

[ -r "$CRED" ] || exit 0
exp=$(jq -r '.claudeAiOauth.expiresAt // 0' "$CRED" 2>/dev/null); exp=${exp%%.*}
[[ $exp =~ ^[0-9]+$ ]] && [ "$exp" -gt $((now * 1000)) ] || exit 0
tok=$(jq -r '.claudeAiOauth.accessToken // empty' "$CRED" 2>/dev/null)
[ -n "$tok" ] || exit 0
resp=$(printf 'Authorization: Bearer %s\n' "$tok" | curl -sS --max-time 5 -H @- \
        -H 'anthropic-beta: oauth-2025-04-20' -H 'Content-Type: application/json' \
        -w '\n%{http_code}' "$URL" 2>/dev/null)
unset tok
code=${resp##*$'\n'}; json=${resp%$'\n'*}
[ "$code" = 200 ] && [ -n "$json" ] || exit 0

# 5h/7d 取顶层字段;Fable 只在 limits[] 里,按模型标签找(不区分大小写)。
read -r h5p h5r d7p d7r fbp fbr < <(printf '%s' "$json" | jq -r '
  def pct: if type == "number" then (floor | tostring) else "-" end;
  def iso: if type == "string" and length > 0 then . else "-" end;
  ((.limits // []) | map(select(.kind == "weekly_scoped"
      and ((.scope.model.display_name // "") | ascii_downcase) == "fable")) | .[0]) as $fb
  | [ (.five_hour.utilization | pct), (.five_hour.resets_at | iso),
      (.seven_day.utilization | pct), (.seven_day.resets_at | iso),
      ($fb.percent | pct), ($fb.resets_at | iso) ] | join(" ")' 2>/dev/null)
[ -n "$h5p" ] || exit 0

to_epoch() { case "$1" in ''|-) printf -- '-' ;; *) date -d "$1" +%s 2>/dev/null || printf -- '-' ;; esac; }
h5r=$(to_epoch "$h5r"); d7r=$(to_epoch "$d7r"); fbr=$(to_epoch "$fbr")

# 周窗口:先记历史,再据历史算 24h 燃速与上周终值(两个系列各算一次)
if { [ "$d7p" != - ] && [ "$d7r" != - ]; } || { [ "$fbp" != - ] && [ "$fbr" != - ]; }; then
  printf '%s %s %s %s %s\n' "$now" "$d7p" "$d7r" "$fbp" "$fbr" >> "$HIST7"
  tail -n "$HIST7_KEEP" "$HIST7" > "$HIST7.tmp" && mv "$HIST7.tmp" "$HIST7"
fi
series_rate "$HIST7" 2 "$now" "$d7p" "$d7r"; d7k=$R24; d7l=$LF
series_rate "$HIST7" 4 "$now" "$fbp" "$fbr"; fbk=$R24; fbl=$LF

# 写临时文件再 mv,避免渲染器读到半行。
printf '%s %s %s %s %s %s %s %s %s %s %s\n' "$now" "$h5p" "$h5r" "$d7p" "$d7r" "$fbp" "$fbr" "$d7k" "$d7l" "$fbk" "$fbl" > "$API.tmp" && mv "$API.tmp" "$API"
if [ "$h5p" != - ] && [ "$h5r" != - ]; then
  printf '%s %s %s\n' "$now" "$h5p" "$h5r" >> "$HIST"
  tail -n "$HIST_KEEP" "$HIST" > "$HIST.tmp" && mv "$HIST.tmp" "$HIST"
fi
exit 0
