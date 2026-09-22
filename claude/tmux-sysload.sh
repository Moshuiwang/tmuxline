#!/bin/bash
# 整机 CPU / 内存占用段(2026-09-22,替换原来会话徽标下面的 tmux 运行时长)。
# 由 status-format[1] 以 #() 每 2 秒调用,输出直接画在会话徽标正下方;只在宽屏(>= 100 列)显示,窄屏那格仍给紧凑额度。
# 用 #() 输出而不写 tmux 选项:数值几乎每轮都变,set-option 会让 tmux 整屏重画,#() 输出变化只重画状态栏。
#   $1 = 这一格可用的显示宽度(格数,由状态栏按会话徽标宽度算好传入)
#   宽度 >= 9:`C23% M61%`;宽度 >= 4:只显示两者中较高的一个;再窄不输出。
#   CPU = 与上一次调用之间的整机忙碌比例(读 /proc/stat,上次采样存在运行时目录,首次调用不输出 CPU);
#   内存 = 1 - MemAvailable / MemTotal(/proc/meminfo,含可回收缓存不算占用)。
#   配色:>= 80% 黄、>= 90% 红,平时沿用格子的灰字;按住 Prefix 时状态栏会把样式剥掉(黄底上不画黄字)。
# 测试钩子:TMUX_SYSLOAD_PROC 指定 proc 目录,TMUX_SYSLOAD_STATE 指定上次采样文件。

W=${1:-0}; [[ $W =~ ^-?[0-9]+$ ]] || W=0
PROC=${TMUX_SYSLOAD_PROC:-/proc}
if [ -n "$TMUX_SYSLOAD_STATE" ]; then STATE=$TMUX_SYSLOAD_STATE
else
  RUN=${XDG_RUNTIME_DIR:-/run/user/$UID}; [ -d "$RUN" ] && [ -w "$RUN" ] || RUN=${TMPDIR:-/tmp}
  STATE="$RUN/tmuxline-cpu.prev"
fi
C_BASE="#9399b2"; C_WARN="#f9e2af"; C_HIGH="#f38ba8"

# --- CPU:cpu 行 = user nice system idle iowait irq softirq steal ...;空闲 = idle + iowait ---
cpu=""
read -r _ u n s i io irq sirq st _ < "$PROC/stat" 2>/dev/null
if [[ $u =~ ^[0-9]+$ ]]; then
  total=$((u + n + s + i + io + irq + sirq + ${st:-0})); idle=$((i + io))
  ptotal=""; pidle=""
  [ -r "$STATE" ] && read -r ptotal pidle < "$STATE"
  printf '%s %s\n' "$total" "$idle" > "$STATE" 2>/dev/null
  if [[ $ptotal =~ ^[0-9]+$ ]] && [[ $pidle =~ ^[0-9]+$ ]] && [ "$total" -gt "$ptotal" ]; then
    dt=$((total - ptotal)); di=$((idle - pidle)); [ "$di" -lt 0 ] && di=0
    cpu=$(( ((dt - di) * 100 + dt / 2) / dt )); [ "$cpu" -gt 100 ] && cpu=100
  fi
fi

# --- 内存 ---
mem=""; mt=""; ma=""
while read -r k v _; do
  case $k in MemTotal:) mt=$v ;; MemAvailable:) ma=$v ;; esac
  [ -n "$mt" ] && [ -n "$ma" ] && break
done < "$PROC/meminfo" 2>/dev/null
[[ $mt =~ ^[0-9]+$ ]] && [[ $ma =~ ^[0-9]+$ ]] && [ "$mt" -gt 0 ] && mem=$(( ((mt - ma) * 100 + mt / 2) / mt ))

seg() { # $1=字母 $2=百分比 → 带配色的一段,如 C 5% / M61%(两位右对齐,数字跳动时后面不挪位)
  local col=""
  if [ "$2" -ge 90 ]; then col=$C_HIGH; elif [ "$2" -ge 80 ]; then col=$C_WARN; fi
  if [ -n "$col" ]; then printf '#[fg=%s]%s%2d%%#[fg=%s]' "$col" "$1" "$2" "$C_BASE"
  else printf '%s%2d%%' "$1" "$2"; fi
}

if [ "$W" -ge 9 ] && [ -n "$cpu" ] && [ -n "$mem" ]; then
  printf '%s %s' "$(seg C "$cpu")" "$(seg M "$mem")"
elif [ "$W" -ge 4 ]; then
  if [ -n "$cpu" ] && { [ -z "$mem" ] || [ "$cpu" -gt "$mem" ]; }; then seg C "$cpu"
  elif [ -n "$mem" ]; then seg M "$mem"; fi
fi
exit 0
