#!/usr/bin/env bash
# 由 Codex hooks(~/.codex/hooks.json)调用，把本会话状态写到所在 tmux 分屏的
# @codex_state 变量。窗口标签会把它渲染成彩色菱形(见 ~/.tmux.conf)：
#   busy     = 青色(工作中)     ← UserPromptSubmit
#   wait-now = 黄色(回合完成)   ← Stop
#   clear    = 线程退出         ← SessionEnd(只把该线程从「在忙」集合里去掉,不清分屏)
# 2026-09-14 精简:去掉了 PermissionRequest 的延迟变黄和 Pre/PostToolUse 的撤销逻辑(3 个钩子),
# 只保留回合开始/结束/退出三处;被 kill、崩溃等 SessionEnd 不触发的残留由
# ~/.claude/tmux-claude-age.sh 每 2 秒按进程树清理。
# 同时记录切换时刻 @codex_since(只在状态真正变化时更新,busy→busy 不重置),
# tmux-claude-age.sh 据此算出「当前状态持续多久」写到 @codex_age,显示在菱形后面。
# 永远以 0 退出。
#
# 2026-09-18 实测(codex 0.155):hooks 由后台 `codex app-server` 守护进程执行,不是分屏里的 TUI 进程——
# 没有 TMUX_PANE,父链到 1 号进程;事件 JSON 里只有 session_id / turn_id / cwd 等。因此:
# 1. 定位分屏:TMUX_PANE 有效就用;否则在跑着 codex 的分屏里找 pane_current_path == cwd 的唯一一个;
#    再不行、全局恰好只有一个 codex 分屏时用它;还不行就静默退出,不往错的窗口写。
# 2. 同一分屏里可能有多个线程(TUI 的 agents:主线程 + 用 send_message_to_thread 派的独立线程,各有自己的
#    session_id,但没有父子字段)。派出的线程每轮结束都触发 Stop、归档触发 SessionEnd,主线程明明还在干活,
#    分屏却被改成「等你」甚至清空。改为按 session_id 记「在忙」集合 @codex_busy:UserPromptSubmit 加入、
#    Stop / SessionEnd 移除;集合非空 = busy,清空 = wait。派出线程的回合没有 UserPromptSubmit,不会加入。
#    集合与状态一起由 tmux-claude-age.sh 在 codex 进程退出后清掉。
#
# 嵌套运行不算——Claude 在自己的分屏里用 Bash 起 `codex exec`(或 Codex 起另一个 codex),
# 那个无头进程继承了同一个 TMUX_PANE,会把菱形画到宿主的分屏上。
# 判定:沿父进程链往上找,第一个 codex 就是调本钩子的进程;它上面若还有 claude/codex,就是嵌套,静默退出。
# 只读 /proc,不起子进程。与 ~/.claude/tmux-claude-hook.sh 里的 nested() 镜像。(app-server 执行时父链无 codex,不受影响)
#
# 取证开关:存在 ~/.codex/tmux-codex-hook.debug 时,把每次事件的字段(去掉 prompt / 回复正文)追加进去。

state="${1:-}"
input="$(cat 2>/dev/null || true)"
sid=""; cwd=""
[[ $input =~ \"session_id\":\"([^\"]+)\" ]] && sid=${BASH_REMATCH[1]}
[[ $input =~ \"cwd\":\"([^\"]+)\" ]] && cwd=${BASH_REMATCH[1]}
if [ -f "$HOME/.codex/tmux-codex-hook.debug" ] && command -v jq >/dev/null 2>&1; then
  printf '%(%F %T)T %s pane=%s ppid=%s %s\n' -1 "$state" "${TMUX_PANE:-}" "$PPID" \
    "$(printf '%s' "$input" | jq -c 'del(.prompt, .last_assistant_message, .transcript_path)' 2>/dev/null)" >> "$HOME/.codex/tmux-codex-hook.debug"
fi

nested() {
  local pid=$PPID comm line found=0
  while [ "$pid" -gt 1 ] 2>/dev/null; do
    read -r comm < "/proc/$pid/comm" 2>/dev/null || return 1
    case $comm in
      codex*)  [ "$found" = 1 ] && return 0; found=1 ;;
      claude*) [ "$found" = 1 ] && return 0 ;;
    esac
    read -r line < "/proc/$pid/stat" 2>/dev/null || return 1
    line=${line##*) }; set -- $line; pid=$2   # ") 之后的第 2 个字段是 ppid
  done
  return 1
}
nested && exit 0

pane="${TMUX_PANE:-}"
if [ -n "$pane" ]; then
  actual_pane="$(tmux display-message -p -t "$pane" '#{pane_id}' 2>/dev/null || true)"
  [ "$actual_pane" = "$pane" ] || pane=""
fi

if [ -z "$pane" ]; then
  codex_panes="$(tmux list-panes -a -F '#{pane_id}|#{pane_current_command}|#{pane_current_path}' 2>/dev/null | awk -F '|' '$2 == "codex"')"
  if [ -n "$cwd" ]; then
    by_cwd="$(printf '%s\n' "$codex_panes" | awk -F '|' -v c="$cwd" '$3 == c {print $1}')"
    [ "$(printf '%s\n' "$by_cwd" | awk 'NF {n++} END {print n+0}')" -eq 1 ] && pane="$by_cwd"
  fi
  if [ -z "$pane" ]; then
    all="$(printf '%s\n' "$codex_panes" | awk -F '|' 'NF {print $1}')"
    [ "$(printf '%s\n' "$all" | awk 'NF {n++} END {print n+0}')" -eq 1 ] && pane="$all"
  fi
fi

[ -n "$pane" ] || exit 0

# 设置状态(只在真正变化时写:tmux 每次 set-option 都会整屏重画客户端,busy→busy 不写也不重置计时)
apply_state() {
  local st=$1 cur now
  cur="$(tmux display-message -p -t "$pane" '#{@codex_state}' 2>/dev/null || true)"
  [ "$cur" = "$st" ] && return 0
  printf -v now '%(%s)T' -1
  tmux set-option -p -t "$pane" @codex_state "$st" \; \
       set-option -p -t "$pane" @codex_since "$now" \; \
       set-option -p -t "$pane" @codex_age 0m >/dev/null 2>&1 || true
}

# 「在忙」集合:空格分隔的 session_id 列表,存在分屏变量 @codex_busy 里
busy_set="$(tmux display-message -p -t "$pane" '#{@codex_busy}' 2>/dev/null || true)"
busy_add() { [ -z "$sid" ] && return; case " $busy_set " in *" $sid "*) ;; *) busy_set="${busy_set:+$busy_set }$sid" ;; esac; }
busy_del() { [ -z "$sid" ] && return; local out="" s; for s in $busy_set; do [ "$s" = "$sid" ] || out="${out:+$out }$s"; done; busy_set=$out; }
busy_save() { if [ -n "$busy_set" ]; then tmux set-option -p -t "$pane" @codex_busy "$busy_set" >/dev/null 2>&1; else tmux set-option -p -t "$pane" -u @codex_busy >/dev/null 2>&1; fi; }

case "$state" in
  busy)     busy_add; busy_save; apply_state busy ;;
  wait-now) busy_del; busy_save; if [ -n "$busy_set" ]; then apply_state busy; else apply_state wait; fi ;;
  clear)    busy_del; busy_save   # 线程退出:只把它从集合去掉;集合空了且分屏还显示在忙,才降为「等你」。分屏级清理交给进程树
            [ -z "$busy_set" ] && [ "$(tmux display-message -p -t "$pane" '#{@codex_state}' 2>/dev/null)" = busy ] && apply_state wait ;;
esac

exit 0
