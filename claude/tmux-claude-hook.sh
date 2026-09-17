#!/bin/bash
# 由 Claude Code hooks 调用(见 ~/.claude/settings.json 的 hooks 段),
# 把本会话的状态写到所在 tmux 分屏(pane)的变量 @claude_state,
# 窗口标签上逐分屏画状态点(见 ~/.tmux.conf 的 window-status-format):
#   busy = 青色点(干活中) wait = 黄色点(回合完成/等你输入/等授权;不再区分绿色 done)
#   clear = 清除标记(会话结束)
# 2026-09-11 起同时记录切换时刻 @claude_since:只在状态真正变化时更新——回合内每次工具调用都会报 busy,
# busy→busy 不重置计时。tmux-claude-age.sh 据此算出「当前状态持续多久」写到 @claude_age,显示在点后面。
# 状态存在分屏一级:一个窗口多个 Claude 各有各的点互不覆盖,分屏关闭时状态随之消失。
# 不在 tmux 里运行时静默退出。stdin 的 hook JSON 不需要,直接丢弃。
# 永远以 0 退出:PreToolUse 钩子退出码 2 会拦截工具调用,这里绝不能发生。

# 2026-09-13:嵌套运行不算——Codex 在自己的分屏里起 `claude -p` 做审核(或 Claude 用 Bash 起另一个 claude),
# 那个无头进程继承了同一个 TMUX_PANE,会把点画到宿主的分屏上;而且它被杀/超时时 SessionEnd 不触发,青点就永远留着。
# 判定:沿父进程链往上找,第一个 claude 就是调本钩子的进程;它上面若还有 claude/codex,就是嵌套,静默退出。
# 只读 /proc,不起子进程(本钩子每次工具调用都会跑)。

state="$1"
cat > /dev/null 2>&1 || true
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
case "$state" in
  busy|wait)
    cur=$(tmux display-message -p -t "$TMUX_PANE" '#{@claude_state}' 2>/dev/null)
    [ "$cur" = "$state" ] && exit 0
    printf -v now '%(%s)T' -1
    tmux set-option -p -t "$TMUX_PANE" @claude_state "$state" \; \
         set-option -p -t "$TMUX_PANE" @claude_since "$now" \; \
         set-option -p -t "$TMUX_PANE" @claude_age 0m 2>/dev/null ;;
  clear)
    tmux set-option -p -t "$TMUX_PANE" -u @claude_state \; \
         set-option -p -t "$TMUX_PANE" -u @claude_since \; \
         set-option -p -t "$TMUX_PANE" -u @claude_age 2>/dev/null ;;
esac
exit 0
