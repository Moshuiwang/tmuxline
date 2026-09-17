#!/bin/bash
# tmux status-right 里的 Claude / Codex 账号用量段。
#
# 数据源(按优先级):
#   1. ~/.claude/tmux-claude-usage-api.dat —— tmux-claude-usage-poll.sh 从官方用量接口拉的,
#      一行十一列:时刻 5h% 5h重置 7d% 7d重置 Fable% Fable重置 7d燃速 7d上周 Fable燃速 Fable上周
#      (缺失写 "-",时刻为 epoch 秒;后四列由轮询器按 tmux-claude-usage-rate.sh 算,老文件没有这四列也能读)。
#      超过 API_STALE 秒没更新(接口失败/凭据过期)则退回 2;
#   2. ~/.claude/tmux-claude-usage.dat —— statusline-command.sh 顺手写的旧文件(无 Fable),
#      超过 OLD_STALE 秒没更新则整段隐藏。
# 轮询由本脚本触发:上次尝试距今超过 POLL_EVERY 秒就后台拉起一次轮询器,所以只在 tmux 开着时才打接口。
#   Codex 同理(2026-09-14 起):~/.local/state/tmux-codex-quota/tmux-codex-usage.dat 由
#   ~/.codex/tmux-codex-quota-refresh.py 写,也是本脚本每 POLL_EVERY 秒后台拉起一次,不再依赖 Codex 钩子。
#   两边查的都是账号限额接口,不启动模型运行、不消耗 token。
#
# 展示规则:
#   7d / Fable 常显:`7d 21% → 110%`,箭头后是「到重置时会用到多少」的预测,取下面两个估计中较高的那个(2026-09-17 起):
#     a. 本周平均节奏:已用% ÷ 窗口已过比例;窗口已过不足 EARLY_FRAC% 时改用上周终值当节奏
#        (已用 + 上周终值 × 剩余比例),连上周数据也没有才不算;
#     b. 最近 24h 燃速外推:已用 + 燃速 × 剩余时间(燃速由轮询器算好写在数据文件里,跨周重置也连续)。
#     取较高者的用意:停一天不会塌成「没风险」(回落到周平均),猛干一天当天就能报出来。上限 999。
#     重置时刻按北京时间显示 `周四 07:00`,与机器时区无关;
#     7d 与 Fable 重置相差 ≤ SAME_RESET 秒视为同一窗口,只显示一次;不显示距重置倒计时。
#   5h 平时隐藏:按最近 RATE_WIN 秒的燃速外推到重置时刻,预测 ≥ H5_SHOW_PRED 或已用 ≥ H5_SHOW_USED 才出现;
#     出现后预测回落到 H5_KEEP_PRED 以下且 H5_KEEP_SECS 秒内未再触发才隐藏(防闪:一出现整行会左移)。
#   配色:Claude 和 Codex 各自使用低饱和度深色背景,文字使用高对比浅色;
#     用量/预测阈值仍保留深色层次,数字逻辑不变。
# 已知盲区:数据 POLL_EVERY 秒一更,一阵猛干的头 10-15 分钟 5h 预测跟不上。
#
# 参数(2026-09-15 起):`codex` 只输出 Codex 段,`claude` 只输出 Claude 段,不带参数两段都输出(Codex 在前)。
#   状态栏两行时分别用在第 1 行 status-right 和第 2 行 status-format[1] 里;每次调用都会照常触发两边的轮询(有时间戳把关)。
# 测试钩子:TMUX_CLAUDE_DIR / TMUX_CODEX_STATE_DIR 改数据目录、TMUX_CLAUDE_NOW 固定「现在」(设了就不触发轮询)。

export TZ=Asia/Shanghai   # 只影响本进程的时间格式化
ONLY=$1                   # codex | claude | 空=两段都要

DIR=${TMUX_CLAUDE_DIR:-$HOME/.claude}
API="$DIR/tmux-claude-usage-api.dat"
OLD="$DIR/tmux-claude-usage.dat"
HIST="$DIR/tmux-claude-usage-5h.hist"
STATE="$DIR/tmux-claude-usage-5h.state"
LAST="$DIR/tmux-claude-usage-api.last"
POLL="$DIR/tmux-claude-usage-poll.sh"

CODEX_DIR=${TMUX_CODEX_STATE_DIR:-$HOME/.local/state/tmux-codex-quota}
CODEX_CACHE="$CODEX_DIR/tmux-codex-usage.dat"
CODEX_LAST="$CODEX_DIR/tmux-codex-usage.last"
CODEX_RUN_LOCK="$CODEX_DIR/tmux-codex-usage.refresh.lock"
CODEX_REFRESH="$HOME/.codex/tmux-codex-quota-refresh.py"

POLL_EVERY=300     # 轮询间隔(秒)
API_STALE=900      # 接口数据超过多久视为过期
OLD_STALE=86400    # 旧文件超过多久整段隐藏
WEEK=604800
EARLY_FRAC=5       # 周窗口已过不足 5% 不显示预测
SAME_RESET=300     # 7d/Fable 重置相差 ≤5 分钟算同一窗口
RATE_WIN=1800      # 5h 燃速取最近 30 分钟
RATE_MIN_SPAN=600  # 至少跨 10 分钟的两个采样才算速度
H5_SHOW_PRED=90; H5_SHOW_USED=80; H5_KEEP_PRED=80; H5_KEEP_SECS=900

CLAUDE_BG="#452c20"; CLAUDE_FG="#a6c98b"; CLAUDE_DIM="#b69c89"; CLAUDE_MID="#e4b35e"; CLAUDE_HIGH="#df8896"
CODEX_BG="#293c4f"; CODEX_FG="#a6c98b"; CODEX_DIM="#9eb6cc"; CODEX_MID="#e4b35e"; CODEX_HIGH="#df8da7"
CODEX_STALE=86400
WD=(_ 一 二 三 四 五 六 日)

if [ -n "$TMUX_CLAUDE_NOW" ]; then now=$TMUX_CLAUDE_NOW; else printf -v now '%(%s)T' -1; fi
isnum() { [[ $1 =~ ^[0-9]+$ ]]; }
use_palette() {
  if [ "$1" = codex ]; then
    C_BG="$CODEX_BG"; C_G="$CODEX_FG"; C_Y="$CODEX_MID"; C_R="$CODEX_HIGH"; C_DIM="$CODEX_DIM"
  else
    C_BG="$CLAUDE_BG"; C_G="$CLAUDE_FG"; C_Y="$CLAUDE_MID"; C_R="$CLAUDE_HIGH"; C_DIM="$CLAUDE_DIM"
  fi
}
use_palette claude

# --- 触发轮询:后台、所有 fd 脱离,否则 tmux 会等它结束才刷新状态栏 ---
last=0
[ -r "$LAST" ] && read -r last < "$LAST"
isnum "$last" || last=0
if [ -z "$TMUX_CLAUDE_NOW" ] && [ -r "$POLL" ] && [ $((now - last)) -ge "$POLL_EVERY" ]; then
  bash "$POLL" >/dev/null 2>&1 </dev/null &
  disown 2>/dev/null
fi
# Codex 同样:先落盘「上次尝试时刻」再后台起刷新(失败也不会每 2 秒重试);flock 防止两次刷新重叠
clast=0
[ -r "$CODEX_LAST" ] && read -r clast < "$CODEX_LAST"
isnum "$clast" || clast=0
if [ -z "$TMUX_CLAUDE_NOW" ] && [ -r "$CODEX_REFRESH" ] && [ $((now - clast)) -ge "$POLL_EVERY" ]; then
  mkdir -p "$CODEX_DIR" 2>/dev/null && printf '%s\n' "$now" > "$CODEX_LAST" && \
    flock -n "$CODEX_RUN_LOCK" /usr/bin/python3 "$CODEX_REFRESH" >/dev/null 2>&1 </dev/null &
  disown 2>/dev/null
fi

# --- 读数据 ---
if [ -r "$API" ] && read -r ts h5p h5r d7p d7r fbp fbr d7k d7l fbk fbl < "$API" && isnum "$ts" && [ $((now - ts)) -le "$API_STALE" ]; then
  :
elif [ -r "$OLD" ] && read -r ts h5p h5r d7p d7r < "$OLD" && isnum "$ts" && [ $((now - ts)) -le "$OLD_STALE" ]; then
  fbp=-; fbr=-; d7k=-; d7l=-; fbk=-; fbl=-
else
  ts=0; h5p=-; h5r=-; d7p=-; d7r=-; fbp=-; fbr=-; d7k=-; d7l=-; fbk=-; fbl=-
fi
for v in h5p d7p fbp d7k d7l fbk fbl; do x=${!v}; x=${x%%.*}; isnum "$x" || x=-; printf -v "$v" '%s' "$x"; done
for v in h5r d7r fbr; do x=${!v}; { isnum "$x" && [ "$x" -gt "$now" ]; } || x=-; printf -v "$v" '%s' "$x"; done

# --- 小工具(都写全局变量,不起子进程:本脚本每 2 秒跑一次) ---
pct_col()  { if [ "$1" -ge 80 ]; then col=$C_R; elif [ "$1" -ge 50 ]; then col=$C_Y; else col=$C_G; fi; }
pred_col() { if [ "$1" -ge 120 ]; then col=$C_R; elif [ "$1" -ge 100 ]; then col=$C_Y; else col=$C_DIM; fi; }
fmt_left() { # $1=秒 → left="5d15h" / "3h0m" / "12m"
  local s=$1 d h m; [ "$s" -lt 0 ] && s=0
  d=$((s / 86400)); h=$((s % 86400 / 3600)); m=$((s % 3600 / 60))
  if   [ "$d" -gt 0 ]; then left="${d}d"; [ "$h" -gt 0 ] && left="${left}${h}h"
  elif [ "$h" -gt 0 ]; then left="${h}h${m}m"
  else                      left="${m}m"; fi
}
fmt_reset() { # $1=epoch → reset_txt="周四 07:00"(北京时间;北京固定 UTC+8 无夏令时,日序号直接算)
  local r=$1 hm wd label dn_now dn_r
  dn_now=$(( (now + 28800) / 86400 )); dn_r=$(( (r + 28800) / 86400 ))
  printf -v hm '%(%H:%M)T' "$r"; printf -v wd '%(%u)T' "$r"
  case $((dn_r - dn_now)) in
    0) label=今天 ;;
    1) label=明天 ;;
    *) case $(( (dn_r + 3) / 7 - (dn_now + 3) / 7 )) in   # 1970-01-01 是周四,+3 对齐到周一起算的自然周
         0) label="周${WD[wd]}" ;;
         1) label="周${WD[wd]}" ;;
         *) printf -v label '%(%-m/%-d)T' "$r" ;;
       esac ;;
  esac
  reset_txt="$label $hm"
}
week_pred() { # $1=已用% $2=重置 epoch $3=24h燃速(%/周,或 -) $4=上周终值%(或 -) → pred(算不出为空)
  pred=""
  local rem=$(( $2 - now )) el pw="" p24=""
  el=$(( WEEK - rem ))
  [ "$el" -le 0 ] && return
  if [ $(( el * 100 / WEEK )) -ge "$EARLY_FRAC" ]; then
    pw=$(( ($1 * WEEK + el / 2) / el ))               # 本周平均节奏
  elif isnum "$4"; then
    pw=$(( $1 + ($4 * rem + WEEK / 2) / WEEK ))       # 周初:拿上周终值当节奏顶上
  fi
  isnum "$3" && p24=$(( $1 + ($3 * rem + WEEK / 2) / WEEK ))   # 最近 24h 燃速外推
  pred=$pw
  [ -n "$p24" ] && { [ -z "$pred" ] || [ "$p24" -gt "$pred" ]; } && pred=$p24
  [ -n "$pred" ] || return
  [ "$pred" -gt 999 ] && pred=999
}

out=""
wseg() { # $1=标签 $2=已用% $3=重置 $4=1 附带重置时刻 $5=24h燃速 $6=上周终值
  pct_col "$2"; out+="#[fg=${col},bg=${C_BG}] $1 $2%"
  week_pred "$2" "$3" "${5:--}" "${6:--}"
  if [ -n "$pred" ]; then pred_col "$pred"; out+="#[fg=${col}] → ${pred}%"; fi
  if [ "$4" = 1 ]; then fmt_reset "$3"; out+="#[fg=${C_DIM}] ${reset_txt}"; fi
  out+=" "
}

# --- 5h:算燃速预测 + 显隐状态机 ---
h5_pred() { # → h5pred(算不出为空)
  h5pred=""
  [ -r "$HIST" ] || return
  local -a T=() P=(); local t p r i n lt lp ot op dp
  while read -r t p r; do
    [ "$r" = "$h5r" ] && isnum "$t" && isnum "$p" && { T+=("$t"); P+=("$p"); }
  done < "$HIST"
  n=${#T[@]}; [ "$n" -ge 2 ] || return
  lt=${T[n-1]}; lp=${P[n-1]}
  for ((i = 0; i < n; i++)); do [ $(( lt - T[i] )) -le "$RATE_WIN" ] && { ot=${T[i]}; op=${P[i]}; break; }; done
  [ $(( lt - ot )) -ge "$RATE_MIN_SPAN" ] || return
  dp=$(( lp - op )); [ "$dp" -lt 0 ] && dp=0
  h5pred=$(( lp + dp * (h5r - lt) / (lt - ot) ))
  [ "$h5pred" -gt 999 ] && h5pred=999
}
h5_state() { # → h5show;状态文件:shown 最近触发时刻 重置
  local shown=0 lastt=0 sreset=- trig=0 nshown nlast line
  [ -r "$STATE" ] && read -r shown lastt sreset < "$STATE"
  isnum "$shown" || shown=0; isnum "$lastt" || lastt=0
  [ "$sreset" = "$h5r" ] || { shown=0; lastt=0; }   # 换了窗口,状态作废
  [ -n "$h5pred" ] && [ "$h5pred" -ge "$H5_SHOW_PRED" ] && trig=1
  [ "$h5p" -ge "$H5_SHOW_USED" ] && trig=1
  nshown=$shown; nlast=$lastt
  if [ "$trig" = 1 ]; then
    nshown=1; [ $((now - lastt)) -ge 60 ] && nlast=$now   # 触发时刻最多每分钟落一次盘
  elif [ "$shown" = 1 ]; then
    if { [ -n "$h5pred" ] && [ "$h5pred" -ge "$H5_KEEP_PRED" ]; } || [ $((now - lastt)) -lt "$H5_KEEP_SECS" ]; then :
    else nshown=0; nlast=0; fi
  fi
  line="$nshown $nlast $h5r"
  [ "$line" != "$shown $lastt $sreset" ] && printf '%s\n' "$line" > "$STATE"
  h5show=$nshown
}
if [ "$h5p" != - ] && [ "$h5r" != - ]; then
  h5_pred; h5_state
  if [ "$h5show" = 1 ]; then
    pct_col "$h5p"; out+="#[fg=${col},bg=${C_BG}] 5h ${h5p}%"
    if [ -n "$h5pred" ]; then pred_col "$h5pred"; out+="#[fg=${col}] → ${h5pred}%"; fi
    fmt_left $((h5r - now)); out+="#[fg=${C_DIM}] ${left} "
  fi
fi

# --- 7d / Fable:重置一致就合并显示一次 ---
d7ok=0; [ "$d7p" != - ] && [ "$d7r" != - ] && d7ok=1
fbok=0; [ "$fbp" != - ] && [ "$fbr" != - ] && fbok=1
same=0
if [ "$d7ok" = 1 ] && [ "$fbok" = 1 ]; then diff=$((d7r - fbr)); [ "${diff#-}" -le "$SAME_RESET" ] && same=1; fi
if [ "$same" = 1 ]; then
  wseg 7d "$d7p" "$d7r" 0 "$d7k" "$d7l"
  wseg Fable "$fbp" "$fbr" 0 "$fbk" "$fbl"
  fmt_reset "$d7r"; out+="#[fg=${C_DIM},bg=${C_BG}] ${reset_txt} "
else
  [ "$d7ok" = 1 ] && wseg 7d "$d7p" "$d7r" 1 "$d7k" "$d7l"
  [ "$fbok" = 1 ] && wseg Fable "$fbp" "$fbr" 1 "$fbk" "$fbl"
fi

render_codex() { # 进入时 out 为空,只往里写 Codex 段
  local cts raw_h5p raw_h5r raw_d7p raw_d7r raw_k raw_l
  [ -r "$CODEX_CACHE" ] || return
  read -r cts raw_h5p raw_h5r raw_d7p raw_d7r raw_k raw_l < "$CODEX_CACHE" || return
  isnum "$cts" || return
  [ $((now - cts)) -le "$CODEX_STALE" ] || return

  cx_h5p=$raw_h5p; cx_h5r=$raw_h5r; cx_d7p=$raw_d7p; cx_d7r=$raw_d7r; cx_k=$raw_k; cx_l=$raw_l
  for v in cx_h5p cx_d7p cx_k cx_l; do x=${!v}; x=${x%%.*}; isnum "$x" || x=-; printf -v "$v" '%s' "$x"; done
  for v in cx_h5r cx_d7r; do x=${!v}; { isnum "$x" && [ "$x" -gt "$now" ]; } || x=-; printf -v "$v" '%s' "$x"; done
  [ "$cx_h5p" != - ] || [ "$cx_d7p" != - ] || return

  use_palette codex

  # Older refreshes guessed a missing 5h window from the only weekly window.
  # Treat an exactly duplicated 7d pair as that legacy false 5h value too, so
  # an already-written cache stops showing `5h 0% <weekly reset>` immediately.
  if [ "$cx_h5p" != - ] && [ "$cx_h5r" != - ] && \
     { [ "$cx_h5p" != "$cx_d7p" ] || [ "$cx_h5r" != "$cx_d7r" ]; }; then
    pct_col "$cx_h5p"; out+="#[fg=${col},bg=${C_BG}] 5h ${cx_h5p}%"
    fmt_left $((cx_h5r - now)); out+="#[fg=${C_DIM}] ${left} "
  fi

  if [ "$cx_d7p" != - ] && [ "$cx_d7r" != - ]; then
    wseg 7d "$cx_d7p" "$cx_d7r" 1 "$cx_k" "$cx_l"
  fi
}

claude_out=$out
out=""; render_codex; codex_out=$out
case $ONLY in
  codex)  out=$codex_out ;;
  claude) out=$claude_out ;;
  *)      out=$codex_out; [ -n "$codex_out" ] && [ -n "$claude_out" ] && out+="#[default] "; out+=$claude_out ;;
esac

[ -n "$out" ] && printf '%s#[default] ' "$out"
exit 0
