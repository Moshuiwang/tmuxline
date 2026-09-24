#!/bin/bash
# 子代理标记测试(2026-09-24):在独立的 tmux server(-L)里调 tmux-claude-hook.sh / tmux-claude-age.sh,
# 看分屏变量和第 2 行标签渲染。不碰正在用的 tmux。
ROOT=$(cd "$(dirname "$0")/.." && pwd); W=$(mktemp -d)
S=subtest$$; T="tmux -L $S"
trap '$T kill-server 2>/dev/null; rm -rf "$W"' EXIT
fail=0
chk() { if [ "$1" = "$2" ]; then echo "ok   $3 → $1"; else echo "FAIL $3: got '$1' want '$2'"; fail=1; fi; }

$T -f /dev/null new-session -d -s t -x 200 -y 20 'sleep 300'
$T source-file "$ROOT/claude/tmux-status-extra.conf" 2>/dev/null   # 只要 @tab2 / @tab2_cur 两个格式
P=$($T list-panes -F '#{pane_id}')
NOW=1790000000
hook() { # $1=参数 $2=stdin JSON
  printf '%s' "$2" | TMUX=x TMUX_PANE=$P TMUX_CLAUDE_TMUX="$T" TMUX_CLAUDE_NOW=$NOW TMUX_CLAUDE_LOCK=$W/lock \
    bash "$ROOT/claude/tmux-claude-hook.sh" "$1"
}
get() { $T display -p -t "$P" "#{$1}"; }
tab2() { $T display -p -t "$P" "#{E:@tab2}" | sed 's/#\[[^]]*\]//g'; }
main='{"session_id":"s1","cwd":"/x","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo \"agent_id\":\"fake\""}}'
sub() { echo "{\"session_id\":\"s1\",\"cwd\":\"/x\",\"agent_id\":\"$1\",\"agent_type\":\"general-purpose\",\"hook_event_name\":\"$2\"}"; }

# 1 主 agent 开干:青点;tool_input 里的 "agent_id" 字样不能被当成子代理
hook busy "$main"
chk "$(get @claude_state)|$(get @claude_subs)" "busy|" "主 agent 工具调用"
# 2 派出一个子代理 → ✦
hook sub-start "$(sub a1 SubagentStart)"
chk "$(get @claude_sub_mark)" "✦" "一个子代理"
# 3 主 agent 这一轮说完 → 黄点,✦ 还在
hook done '{"session_id":"s1","hook_event_name":"Stop"}'
chk "$(get @claude_state)|$(get @claude_sub_mark)" "wait|✦" "主 agent 说完、子代理还在跑"
# 4 子代理调工具:主圆点不能被拉回青色
hook busy "$(sub a1 PreToolUse)"
chk "$(get @claude_state)" "wait" "子代理工具调用不改主圆点"
# 5 再并行派两个(同时到,考验加锁)→ ✦³
hook sub-start "$(sub a2 SubagentStart)" & hook sub-start "$(sub a3 SubagentStart)" & wait
chk "$(get @claude_sub_mark)" "✦³" "并行派出后共 3 个"
chk "$(tab2)" "● 0m ✦³" "第 2 行渲染(age 由计时脚本写,这里是钩子写的 0m)"
# 6 选中窗口用深紫、普通窗口用浅紫
chk "$($T display -p -t "$P" '#{E:@tab2_cur}' | grep -o '#\[fg=#5b21b6\]✦³')" "#[fg=#5b21b6]✦³" "选中窗口深紫"
chk "$($T display -p -t "$P" '#{E:@tab2}' | grep -o '#\[fg=#cba6f7\]✦³')" "#[fg=#cba6f7]✦³" "普通窗口浅紫"
chk "$($T display -p -t "$P" '#{w:#{s/#\[[^]]*\]//:#{E:@tab2}}}')" "7" "显示宽度按单格算(● 0m ✦³ = 7 格)"
# 7 结束一个 → ✦²;重复的 SubagentStop 不出错
hook sub-stop "$(sub a2 SubagentStop)"; hook sub-stop "$(sub a2 SubagentStop)"
chk "$(get @claude_sub_mark)" "✦²" "结束一个剩 2 个"
# 8 过期清理:a1 刷新过活动时刻,a3 没有;把「现在」拨到 a3 超 30 分钟、a1 未超 → sub-prune 只清 a3
NOW=$((NOW + 1000)); hook busy "$(sub a1 PreToolUse)"
NOW=$((NOW + 1000))
printf '' | TMUX_CLAUDE_TMUX="$T" TMUX_CLAUDE_NOW=$NOW TMUX_CLAUDE_LOCK=$W/lock bash "$ROOT/claude/tmux-claude-hook.sh" sub-prune "$P"
chk "$(get @claude_subs)|$(get @claude_sub_mark)" "a1:$((NOW - 1000))|✦" "过期条目被清掉"
# 9 最后一个结束 → 标记消失
hook sub-stop "$(sub a1 SubagentStop)"
chk "$(get @claude_subs)|$(get @claude_sub_mark)" "|" "全部结束后标记消失"
# 10 会话结束一并清
hook sub-start "$(sub b1 SubagentStart)"; hook clear '{}'
chk "$(get @claude_state)|$(get @claude_sub_mark)" "|" "会话结束清空"
# 11 十个以上显示 ✦⁹⁺
for i in 1 2 3 4 5 6 7 8 9 10; do hook sub-start "$(sub c$i SubagentStart)"; done
chk "$(get @claude_sub_mark)" "✦⁹⁺" "十个以上"
# 12 分屏里已经没有 claude 进程(这里是 sleep)→ 计时脚本连同子代理标记一起清
TMUX_CLAUDE_TMUX="$T" TMUX_CLAUDE_NOW=$NOW bash "$ROOT/claude/tmux-claude-age.sh"
chk "$(get @claude_subs)|$(get @claude_sub_mark)" "|" "Claude 进程没了一并清掉"
exit $fail
