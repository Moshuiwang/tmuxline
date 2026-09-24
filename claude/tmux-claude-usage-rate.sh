# 周额度「燃速」计算(2026-09-17),被 tmux-claude-usage-poll.sh 引用;渲染器不读历史,只用轮询器算好的两个数。
#
# 背景:状态栏的「→ 预测」原来只按本周平均节奏外推,周初 8 小时算不出,冲刺当天也反映不出来。
# 现在轮询器每次采样后多算两个数,写进数据文件末尾两列(每个周窗口各两列):
#   R24  最近 RATE24_WIN 秒的燃速,换算成「照这个速度一整周会用掉多少个百分点」(整数);
#        跨过周重置也能算:旧窗口最后一个样本 − 旧样本 + 本窗口已用;不足 RATE24_MIN_SPAN 秒的历史不算(写 "-")。
#   LF   上一个周窗口最后一次采样的已用%(周初本周还没节奏时先拿它顶上);没有上周数据写 "-"。
# 渲染器取「本周平均」与「最近 RATE24_WIN(默认 6h)」两者中较高的预测:停一天不会塌(回落到周平均),猛干一天当天就报出来。
#
# 用法:series_rate 历史文件 列号 现在 已用% 重置时刻 → 设全局 R24 LF
#   历史文件每行「时刻 7d% 7d重置 Fable% Fable重置」,列号 2 取 7d、4 取 Fable(codex 侧由 python 同算法实现)。
#
# 2026-09-24:接口给的重置时刻会抖 1~2 秒(同一周一会儿 …199 一会儿 …200),以前按「完全相等」认窗口:
#   本周报 …200 时,本周那些 …199 的样本被当成「上一窗口」,上周终值取成本周的 3%,预测塌成 7%;
#   报 …199 时又取到真正的上周 97%,预测跳到 90% 多——两者来回闪。24h 燃速也常因「不是同一窗口」算不出。
#   现在重置时刻相差 ≤ RESET_TOL 秒视为同一窗口(与渲染器 SAME_RESET 同为 5 分钟;窗口本身相隔 5 小时以上,不会混)。

WEEK=${WEEK:-604800}
RATE24_WIN=${RATE24_WIN:-21600}   # 2026-09-22 由 24h 改为 6h:昨天的冲刺不再吓人一整天
RATE24_MIN_SPAN=${RATE24_MIN_SPAN:-10800}

RESET_TOL=${RESET_TOL:-300}

_isnum() { [[ $1 =~ ^[0-9]+$ ]]; }
_near() { local d=$(( $1 - $2 )); [ "${d#-}" -le "$RESET_TOL" ]; }   # 两个重置时刻是否同一窗口

series_rate() {
  local f=$1 col=$2 now=$3 p=$4 r=$5
  local -a T=() P=() R=()
  local a b c d e pp rr n i prev_r=0 t0 oi=-1 span delta lastp
  R24=-; LF=-
  _isnum "$now" && _isnum "$p" && _isnum "$r" || return
  [ -r "$f" ] || return
  while read -r a b c d e; do
    if [ "$col" = 2 ]; then pp=$b; rr=$c; else pp=$d; rr=$e; fi
    _isnum "$a" && _isnum "$pp" && _isnum "$rr" || continue
    [ "$a" -le "$now" ] || continue
    T+=("$a"); P+=("$pp"); R+=("$rr")
  done < "$f"
  n=${#T[@]}; [ "$n" -gt 0 ] || return

  # LF:紧挨着的上一个窗口(重置早于本窗口超过 RESET_TOL、且相差不超过一周零一天)的最后一个样本
  for ((i = 0; i < n; i++)); do
    [ "${R[i]}" -lt $((r - RESET_TOL)) ] && [ "${R[i]}" -gt "$prev_r" ] && prev_r=${R[i]}
  done
  if [ "$prev_r" -gt 0 ] && [ $((r - prev_r)) -le $((WEEK + 86400)) ]; then
    for ((i = n - 1; i >= 0; i--)); do _near "${R[i]}" "$prev_r" && { LF=${P[i]}; break; }; done
  else
    prev_r=0
  fi

  # R24:找 RATE24_WIN 秒前(或更早)最近的一个样本;历史不够长就用最早的
  t0=$((now - RATE24_WIN))
  for ((i = 0; i < n; i++)); do [ "${T[i]}" -le "$t0" ] && oi=$i; done
  [ "$oi" -ge 0 ] || oi=0
  span=$((now - T[oi])); [ "$span" -ge "$RATE24_MIN_SPAN" ] || return
  if _near "${R[oi]}" "$r"; then
    delta=$((p - P[oi]))
  elif [ "$prev_r" -gt 0 ] && _near "${R[oi]}" "$prev_r"; then
    lastp=${P[oi]}
    for ((i = oi; i < n; i++)); do _near "${R[i]}" "$prev_r" && lastp=${P[i]}; done
    delta=$((lastp - P[oi] + p))
  else
    return   # 样本来自更早的窗口(中间断了很久),不猜
  fi
  [ "$delta" -lt 0 ] && delta=0
  R24=$(( (delta * WEEK + span / 2) / span ))
}
