#!/bin/bash
# 由 Claude Code hooks 调用(见 ~/.claude/settings.json 的 hooks 段),
# 把本会话的状态写到所在 tmux 分屏(pane)的变量 @claude_state,
# 窗口标签上逐分屏画状态点(见 ~/.tmux.conf 的 window-status-format):
#   busy = 青色点(干活中) wait = 黄色点(回合完成/等你输入/等授权;不再区分绿色 done)
#   clear = 清除标记(会话结束)
# 2026-09-11 起同时记录切换时刻 @claude_since:只在状态真正变化时更新——回合内每次工具调用都会报 busy,
# busy→busy 不重置计时。tmux-claude-age.sh 据此算出「当前状态持续多久」写到 @claude_age,显示在点后面。
# 状态存在分屏一级:一个窗口多个 Claude 各有各的点互不覆盖,分屏关闭时状态随之消失。
# 不在 tmux 里运行时静默退出。stdin 的 hook JSON 只用来取 agent_id(见下方子代理一段)。
# 永远以 0 退出:PreToolUse 钩子退出码 2 会拦截工具调用,这里绝不能发生。

# 2026-09-24:子代理单独标记。主 agent 派出的子代理和主 agent 同进程,调工具时一样触发 PreToolUse,
# 以前会把主圆点拉回青色——主 agent 早已说完话在等后台时,点在黄/青之间乱跳,分不清「等你」还是「等子代理」。
# 现在:事件 JSON 里带 agent_id 的工具调用是子代理的,不动主圆点;子代理另记在分屏变量里,
#   @claude_subs      在跑的子代理「id:最近活动时刻」空格分隔列表(SubagentStart 加入、SubagentStop 移出、
#                     子代理每次调工具刷新时刻——被强杀时 SubagentStop 不一定触发,靠它判断过期)
#   @claude_sub_mark  标签上画的标记:1 个 ✦,2~9 个 ✦²…✦⁹,更多 ✦⁹⁺;没有子代理时不设
# 超过 SUB_STALE 秒没动静的条目视为残留,由 tmux-claude-age.sh 定时调本脚本 sub-prune 清掉。
# 并发的钩子是异步的(并行派出几个子代理时 SubagentStart 几乎同时到),读-改-写 @claude_subs 要加 flock。
# 测试钩子:TMUX_CLAUDE_TMUX 指定 tmux 命令,TMUX_CLAUDE_NOW 固定「现在」,TMUX_CLAUDE_LOCK 指定锁文件。

# 2026-09-13:嵌套运行不算——Codex 在自己的分屏里起 `claude -p` 做审核(或 Claude 用 Bash 起另一个 claude),
# 那个无头进程继承了同一个 TMUX_PANE,会把点画到宿主的分屏上;而且它被杀/超时时 SessionEnd 不触发,青点就永远留着。
# 判定:沿父进程链往上找,第一个 claude 就是调本钩子的进程;它上面若还有 claude/codex,就是嵌套,静默退出。
# 只读 /proc,不起子进程(本钩子每次工具调用都会跑)。

state="$1"
input=$(cat 2>/dev/null)
T=${TMUX_CLAUDE_TMUX:-tmux}
if [ -n "$TMUX_CLAUDE_NOW" ]; then now=$TMUX_CLAUDE_NOW; else printf -v now '%(%s)T' -1; fi
SUB_STALE=1800
LOCK=${TMUX_CLAUDE_LOCK:-${XDG_RUNTIME_DIR:-/tmp}/tmux-claude-sub.lock}
SUP=("" "" "²" "³" "⁴" "⁵" "⁶" "⁷" "⁸" "⁹")

# sub_update <分屏> <add|del|prune> [agent_id]:在锁内重写 @claude_subs(顺带丢掉过期条目)并重算 @claude_sub_mark
sub_update() {
  local pane=$1 op=$2 aid=$3 list out="" e ts n=0 mark
  exec 9>>"$LOCK" && flock -w 2 9 || return
  list=$($T display-message -p -t "$pane" '#{@claude_subs}' 2>/dev/null)
  for e in $list; do
    ts=${e##*:}
    [ "${e%:*}" = "$aid" ] && continue
    [[ $ts =~ ^[0-9]+$ ]] && [ $((now - ts)) -lt "$SUB_STALE" ] || continue
    out="${out:+$out }$e"; n=$((n + 1))
  done
  [ "$op" = add ] && { out="${out:+$out }$aid:$now"; n=$((n + 1)); }
  [ "$out" = "$list" ] && return
  if [ "$n" = 0 ]; then
    $T set-option -p -t "$pane" -u @claude_subs \; set-option -p -t "$pane" -u @claude_sub_mark 2>/dev/null
  else
    if [ "$n" -le 9 ]; then mark="✦${SUP[$n]}"; else mark="✦⁹⁺"; fi
    $T set-option -p -t "$pane" @claude_subs "$out" \; set-option -p -t "$pane" @claude_sub_mark "$mark" 2>/dev/null
  fi
}

# tmux-claude-age.sh 定时调用:只清过期条目。不在 Claude 进程里跑,跳过下面的 tmux / 嵌套判断。
if [ "$state" = sub-prune ]; then
  [ -n "$2" ] && sub_update "$2" prune
  exit 0
fi

[ -n "$TMUX" ] && [ -n "$TMUX_PANE" ] || exit 0

nested() {
  local pid=$PPID comm line found=0
  while [ "$pid" -gt 1 ] 2>/dev/null; do
    read -r comm < "/proc/$pid/comm" 2>/dev/null || return 1
    case $comm in
      claude*) [ "$found" = 1 ] && return 0; found=1 ;;
      codex*)  [ "$found" = 1 ] && return 0 ;;
    esac
    read -r line < "/proc/$pid/stat" 2>/dev/null || return 1
    line=${line##*) }; set -- $line; pid=$2   # ") 之后的第 2 个字段是 ppid(comm 里可能有空格,不能按列数)
  done
  return 1
}
nested && exit 0
# 2026-09-24:Stop 钩子传的是 done(回合结束),以前落不进下面任何分支被静默丢弃,
# 只能等 Notification 的空闲提醒来改黄——那个提醒不保证触发,于是回合早结束了点还一直是青色「干活中」。
[ "$state" = done ] && state=wait

# agent_id:公共字段排在 hook_event_name 之前;工具调用只看这一段,免得 tool_input 正文里恰好有这串字符被误认。
# SubagentStart/Stop 的 agent_id 也落在这一段(覆盖公共字段时 JSON 键位不变),取不到再退回全文第一个。
aid=""
head=${input%%\"hook_event_name\"*}
if [[ $head =~ \"agent_id\":\"([^\"]+)\" ]]; then aid=${BASH_REMATCH[1]}
elif [[ $state = sub-* && $input =~ \"agent_id\":\"([^\"]+)\" ]]; then aid=${BASH_REMATCH[1]}; fi
aid=${aid//[^A-Za-z0-9_.-]/}

case "$state" in
  sub-start) [ -n "$aid" ] && sub_update "$TMUX_PANE" add "$aid" ;;
  sub-stop)  [ -n "$aid" ] && sub_update "$TMUX_PANE" del "$aid" ;;
  busy|wait)
    if [ "$state" = busy ] && [ -n "$aid" ]; then   # 子代理的工具调用:不动主圆点,只刷新它的活动时刻(一分钟内刷过就不再写)
      list=$($T display-message -p -t "$TMUX_PANE" '#{@claude_subs}' 2>/dev/null)
      case " $list " in *" $aid:"*) ts=${list#*"$aid:"}; ts=${ts%% *}
        [[ $ts =~ ^[0-9]+$ ]] && [ $((now - ts)) -lt 60 ] && exit 0 ;; esac
      sub_update "$TMUX_PANE" add "$aid"
      exit 0
    fi
    cur=$($T display-message -p -t "$TMUX_PANE" '#{@claude_state}' 2>/dev/null)
    [ "$cur" = "$state" ] && exit 0
    $T set-option -p -t "$TMUX_PANE" @claude_state "$state" \; \
       set-option -p -t "$TMUX_PANE" @claude_since "$now" \; \
       set-option -p -t "$TMUX_PANE" @claude_age 0m 2>/dev/null ;;
  clear)
    $T set-option -p -t "$TMUX_PANE" -u @claude_state \; \
       set-option -p -t "$TMUX_PANE" -u @claude_since \; \
       set-option -p -t "$TMUX_PANE" -u @claude_age \; \
       set-option -p -t "$TMUX_PANE" -u @claude_subs \; \
       set-option -p -t "$TMUX_PANE" -u @claude_sub_mark 2>/dev/null ;;
esac
exit 0
