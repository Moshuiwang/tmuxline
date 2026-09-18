#!/usr/bin/env bash
# 由 Codex hooks(~/.codex/hooks.json)调用，把本会话状态写到所在 tmux 分屏的
# @codex_state 变量。窗口标签会把它渲染成彩色菱形(见 ~/.tmux.conf)：
#   busy     = 青色(工作中)     ← UserPromptSubmit
#   wait-now = 黄色(回合完成)   ← Stop
#   clear    = (已停用,见下)  ← SessionEnd
# 2026-09-14 精简:去掉了 PermissionRequest 的延迟变黄和 Pre/PostToolUse 的撤销逻辑(3 个钩子),
# 只保留回合开始/结束/退出三处;被 kill、崩溃等 SessionEnd 不触发的残留由
# ~/.claude/tmux-claude-age.sh 每 2 秒按进程树清理。
# 同时记录切换时刻 @codex_since(只在状态真正变化时更新,busy→busy 不重置),
# tmux-claude-age.sh 据此算出「当前状态持续多久」写到 @codex_age,显示在菱形后面。
# Codex 传入的 hook JSON 不需要，直接丢弃。永远以 0 退出。
#
# 正常情况下 TMUX_PANE 会随 Codex 进程继承。若 Codex 通过后台 app-server
# 执行 hook，可能没有这两个环境变量；此时仅在全局恰好只有一个 Codex pane
# 时回退定位，多于一个就静默退出，避免把状态写到错误的窗口。
#
# 嵌套运行不算——Claude 在自己的分屏里用 Bash 起 `codex exec`(或 Codex 起另一个 codex),
# 那个无头进程继承了同一个 TMUX_PANE,会把菱形画到宿主的分屏上。
# 判定:沿父进程链往上找,第一个 codex 就是调本钩子的进程;它上面若还有 claude/codex,就是嵌套,静默退出。
# 只读 /proc,不起子进程。与 ~/.claude/tmux-claude-hook.sh 里的 nested() 镜像。

state="${1:-}"
# 2026-09-18 取证开关:存在 ~/.codex/tmux-codex-hook.debug 时,把每次事件的字段(去掉 prompt / 回复正文)追加到该文件,
# 用来核实 codex 多线程(agents)下各线程事件如何落到同一分屏;平时没有该文件,输入直接丢弃。
if [ -f "$HOME/.codex/tmux-codex-hook.debug" ] && command -v jq >/dev/null 2>&1; then
  printf '%(%F %T)T %s pane=%s ppid=%s %s\n' -1 "$state" "${TMUX_PANE:-}" "$PPID" \
    "$(jq -c 'del(.prompt, .last_assistant_message, .transcript_path)' 2>/dev/null)" >> "$HOME/.codex/tmux-codex-hook.debug"
else
  cat >/dev/null 2>&1 || true
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
  codex_panes="$(tmux list-panes -a -F '#{pane_id}|#{pane_current_command}' 2>/dev/null | awk -F '|' '$2 == "codex" {print $1}')"
  codex_count="$(printf '%s\n' "$codex_panes" | awk 'NF {n++} END {print n+0}')"
  [ "$codex_count" -eq 1 ] && pane="$codex_panes"
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

case "$state" in
  busy)     apply_state busy ;;
  wait-now) apply_state wait ;;
  clear) ;;   # 2026-09-18 起不再清空:codex 开 agents 子线程时,子线程退出也触发 SessionEnd、写到同一分屏,会把主线程
              # 正在干活的状态抹掉。codex 进程真退出后,~/.claude/tmux-claude-age.sh 每 2 秒按进程树清理即可兜底。
esac

exit 0
