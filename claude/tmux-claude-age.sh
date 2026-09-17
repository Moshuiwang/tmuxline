#!/bin/bash
# 「状态持续多久」计时器(2026-09-11)。由 ~/.tmux.conf 的 status-right 以 #() 每 2 秒调用一次,自身不输出任何东西;
# 把每个分屏的 @claude_since / @codex_since(状态切换时刻,由两个钩子在状态真正变化时写入)换算成文字,
# 写到 @claude_age / @codex_age,窗口标签在状态点后面显示:
#   青点 = 这一阵跑了多久   黄点 = 等你等了多久(回合完成/等授权)
# 规则:分钟粒度(4m / 2h),不足 1 分钟显示占位 0m(宽度不变,标签不跳);黄点(等你)超过 WAIT_WARN 秒数字变黄(文字自带样式,
# 覆盖标签格式里的默认灰色)。只在文字变化时写回(每个分屏每分钟最多一次),一次 tmux 调用批量写。
# 兼容:改造前已开着的会话没有切换时刻,首次看到时以当时为起点补一个;状态已清而残留的时刻/文字一并清掉。
# 另外每次翻一下全局开关 @blink(按 2 秒时槽取 0/1),窗口标签让干活中的青点/青菱形在实心与空心之间交替——
# 「闪 = 正在工作,不闪 = 没在工作」;节奏就是状态栏刷新间隔(2 秒),不额外起进程。
# 只在有青点要闪、且值真的要翻时才写 @blink:tmux 每次 set-option 都会整屏重画一遍客户端,没事别写。
# 2026-09-13 起顺带清理残留标记:分屏里已经没有 claude / codex 进程(被 kill、崩溃、无头 `claude -p` 跑完)却还挂着状态,
# 就把它清掉——这些情况 SessionEnd 钩子不会触发。每轮 ps 一次(约 10ms),只对挂着状态的分屏查其进程树。
# 先 list-panes 再 ps:状态是活着的进程写的,后拍的 ps 快照一定能看到它,不会误清刚启动的会话。
# 2026-09-15 起顺带算 tmux server 的运行时长(现在 - #{start_time})写进全局 @uptime,状态栏 session 徽标下面显示:
# 不足 1 小时 `23m`,不足 1 天 `3h 12m`,之后 `3d 4h`;同样只在文字变化时写回。数据从同一次 list-panes 里带出来,不多起进程。
# 测试钩子:TMUX_CLAUDE_TMUX 指定 tmux 命令(如 "tmux -L test"),TMUX_CLAUDE_NOW 固定「现在」。

WAIT_WARN=600
C_WARN="#f9e2af"
T=${TMUX_CLAUDE_TMUX:-tmux}
if [ -n "$TMUX_CLAUDE_NOW" ]; then now=$TMUX_CLAUDE_NOW; else printf -v now '%(%s)T' -1; fi

cmds=()
plan() { # $1=分屏 $2=前缀(claude|codex) $3=状态 $4=切换时刻 $5=现有文字
  local pane=$1 pfx=$2 st=$3 since=$4 cur=$5 age label
  if [ -z "$st" ]; then   # 状态已清:残留一并清掉
    [ -n "$since" ] && cmds+=(set-option -p -t "$pane" -u "@${pfx}_since" ';')
    [ -n "$cur" ]   && cmds+=(set-option -p -t "$pane" -u "@${pfx}_age" ';')
    return
  fi
  if [[ ! $since =~ ^[0-9]+$ ]]; then   # 改造前开着的会话:补起点
    cmds+=(set-option -p -t "$pane" "@${pfx}_since" "$now" ';')
    [ "$cur" = 0m ] || cmds+=(set-option -p -t "$pane" "@${pfx}_age" 0m ';')
    return
  fi
  age=$((now - since)); [ "$age" -lt 0 ] && age=0
  if   [ "$age" -lt 60 ];   then label="0m"
  elif [ "$age" -lt 3600 ]; then label="$((age / 60))m"
  else                           label="$((age / 3600))h"; fi
  [ "$st" = wait ] && [ "$age" -ge "$WAIT_WARN" ] && label="#[fg=${C_WARN}]${label}"
  [ "$label" = "$cur" ] && return
  cmds+=(set-option -p -t "$pane" "@${pfx}_age" "$label" ';')
}

# 用 | 分隔(空字段要保留,不能用空白做分隔符);文字里只有 #[fg=…] 和数字,不会含 |
rows=()
while IFS= read -r line; do rows+=("$line"); done \
  < <($T list-panes -a -F '#{pane_id}|#{pane_pid}|#{@claude_state}|#{@claude_since}|#{@claude_age}|#{@codex_state}|#{@codex_since}|#{@codex_age}|#{@blink}|#{start_time}|#{@uptime}' 2>/dev/null)

# 残留清理:哪些分屏的进程树里真有 claude / codex 在跑。只在有分屏挂着状态时才 ps。
# comm 取自可执行文件名(claude 是原生二进制,codex 也是),最长 15 字符,用前缀匹配。
declare -A live ppid_of
need_sweep=0
for line in "${rows[@]}"; do IFS='|' read -r _ _ cst _ _ kst _ _ _ _ _ <<< "$line"; [ -n "$cst$kst" ] && { need_sweep=1; break; }; done
need_sweep=1   # tz 2026-09-17：嵌套 codex（Claude 派的 codex exec）检测需要进程树，每轮都扫
if [ "$need_sweep" = 1 ]; then
  agents=()
  while read -r pid pp comm; do
    ppid_of[$pid]=$pp
    case $comm in claude*) agents+=("$pid claude") ;; codex*) agents+=("$pid codex") ;; esac
  done < <(ps -eo pid=,ppid=,comm= 2>/dev/null)
  for a in "${agents[@]}"; do
    pid=${a%% *}; kind=${a##* }
    while [ -n "$pid" ] && [ "$pid" != 1 ] && [ "$pid" != 0 ]; do   # 沿父链往上,途经的每个 pid 都记为「有 kind 在跑」
      live["$pid/$kind"]=1; pid=${ppid_of[$pid]}
    done
  done
fi

# tz 追加(2026-09-17):没跑 claude / codex 的分屏,若 shell 下有子进程在跑(如独占 full 门禁),
# 把最老那个子进程的运行时长写进 @run_age(分钟粒度),标签第 2 行显示 ▶ 时长;没有子进程则清掉。
declare -A run_child_et
while read -r pid pp et; do
  cur=${run_child_et[$pp]:-0}; [ "$et" -gt "$cur" ] 2>/dev/null && run_child_et[$pp]=$et
done < <(ps -eo pid=,ppid=,etimes= 2>/dev/null)
fmt_run() { local s=$1; if [ "$s" -ge 3600 ]; then printf '%dh%02dm' $((s/3600)) $((s%3600/60)); elif [ "$s" -ge 60 ]; then printf '%dm' $((s/60)); else printf '<1m'; fi; }

any_busy=0; blink_cur=""; start=""; up_cur=""
for line in "${rows[@]}"; do
  IFS='|' read -r pane ppid cst csince cage kst ksince kage blink_cur start up_cur <<< "$line"
  if [ -n "$cst" ] && [ "$need_sweep" = 1 ] && [ -z "${live[$ppid/claude]}" ]; then
    cmds+=(set-option -p -t "$pane" -u @claude_state ';'); cst=""
  fi
  if [ -n "$kst" ] && [ "$need_sweep" = 1 ] && [ -z "${live[$ppid/codex]}" ]; then
    cmds+=(set-option -p -t "$pane" -u @codex_state ';' set-option -p -t "$pane" -u @codex_pending ';'); kst=""
  fi
  plan "$pane" claude "$cst" "$csince" "$cage"
  plan "$pane" codex  "$kst" "$ksince" "$kage"
  # tz 2026-09-17：分屏进程树里同时有 claude 与 codex（= Claude 派出的 codex exec 子进程）→ @codex_sub=1，标签画灰色小菱形；否则清掉
  if [ -n "${live[$ppid/claude]}" ] && [ -n "${live[$ppid/codex]}" ] && [ -z "$kst" ]; then
    cmds+=(set-option -p -t "$pane" @codex_sub 1 ';')
  else
    cmds+=(set-option -p -t "$pane" -u @codex_sub ';')
  fi
  if [ -z "$cst$kst" ] && [ -n "${run_child_et[$ppid]:-}" ]; then
    cmds+=(set-option -p -t "$pane" @run_age "$(fmt_run "${run_child_et[$ppid]}")" ';')
  else
    cmds+=(set-option -p -t "$pane" -u @run_age ';')
  fi
  { [ "$cst" = busy ] || [ "$kst" = busy ]; } && any_busy=1
done

if [[ $start =~ ^[0-9]+$ ]]; then
  up=$((now - start)); [ "$up" -lt 0 ] && up=0
  if   [ "$up" -lt 3600 ];  then up_label="$((up / 60))m"
  elif [ "$up" -lt 86400 ]; then up_label="$((up / 3600))h $((up % 3600 / 60))m"
  else                            up_label="$((up / 86400))d $((up % 86400 / 3600))h"; fi
  [ "$up_label" = "$up_cur" ] || cmds+=(set-option -g @uptime "$up_label" ';')
fi

blink=$(( now / 2 % 2 ))
[ "$any_busy" = 1 ] && [ "$blink_cur" != "$blink" ] && { if [ "$blink" = 1 ]; then d="●"; m="◆"; else d="○"; m="◇"; fi; cmds+=(set-option -g @blink "$blink" ';' set-option -g @busy_dot "$d" ';' set-option -g @busy_dia "$m" ';'); }   # tz：tmux 3.4 分支内嵌套 #{?} 解析失败，闪烁字符改由脚本算好
[ ${#cmds[@]} -gt 0 ] || exit 0
unset 'cmds[-1]'   # 去掉末尾多余的 ';'
$T "${cmds[@]}" >/dev/null 2>&1
exit 0
