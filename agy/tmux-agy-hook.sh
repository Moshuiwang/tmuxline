#!/usr/bin/env bash
# 由 Antigravity CLI (agy) hooks (~/.gemini/config/hooks.json) 调用，把本会话状态写到所在
# tmux 分屏的 @agy_state 变量。窗口标签第 2 行把它渲染成彩色三角形(见 claude/tmux-status-extra.conf)：
#   busy = 青色闪烁 ▲/△ (干活中) ← PreInvocation
#   wait = 黄色 ▲ (回合完成/等你输入) ← Stop
#   clear = 清除标记
#
# 注意：Antigravity 的 Hook 协议要求 stdout 必须输出合法 JSON 对象(如 `{}`)，
# 且非 0 退出码会被视为钩子报错，因此本脚本始终在退出前输出 `{}` 并以 0 退出。

state="${1:-}"
input="$(cat 2>/dev/null || true)"
printf '{}\n'

T=${TMUX_CLAUDE_TMUX:-tmux}
if [ -n "${TMUX_CLAUDE_NOW:-}" ]; then now=$TMUX_CLAUDE_NOW; else printf -v now '%(%s)T' -1; fi

[ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] || exit 0

# 无头模式(`agy -p ...`)或嵌套调用(在 claude / codex / agy 子进程里再起 agy)不写分屏状态
nested_or_print() {
  local pid=$PPID comm line found=0 arg
  while [ "$pid" -gt 1 ] 2>/dev/null; do
    read -r comm < "/proc/$pid/comm" 2>/dev/null || return 1
    case $comm in
      agy*)
        while IFS= read -r -d '' arg; do
          case "$arg" in -p|--print|--prompt) return 0 ;; esac
        done < "/proc/$pid/cmdline" 2>/dev/null
        [ "$found" = 1 ] && return 0
        found=1
        ;;
      claude*|codex*)
        [ "$found" = 1 ] && return 0
        ;;
    esac
    read -r line < "/proc/$pid/stat" 2>/dev/null || return 1
    line=${line##*) }; set -- $line; pid=$2
  done
  return 1
}
nested_or_print && exit 0

case "$state" in
  busy|wait)
    cur=$($T display-message -p -t "$TMUX_PANE" '#{@agy_state}' 2>/dev/null || true)
    [ "$cur" = "$state" ] && exit 0
    $T set-option -p -t "$TMUX_PANE" @agy_state "$state" \; \
       set-option -p -t "$TMUX_PANE" @agy_since "$now" \; \
       set-option -p -t "$TMUX_PANE" @agy_age 0m >/dev/null 2>&1 || true
    ;;
  clear)
    $T set-option -p -t "$TMUX_PANE" -u @agy_state \; \
       set-option -p -t "$TMUX_PANE" -u @agy_since \; \
       set-option -p -t "$TMUX_PANE" -u @agy_age >/dev/null 2>&1 || true
    ;;
esac

exit 0
