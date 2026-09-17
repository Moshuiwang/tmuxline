# 周额度「燃速」计算(2026-09-17),被 tmux-claude-usage-poll.sh 引用;渲染器不读历史,只用轮询器算好的两个数。
#
# 背景:状态栏的「→ 预测」原来只按本周平均节奏外推,周初 8 小时算不出,冲刺当天也反映不出来。
# 现在轮询器每次采样后多算两个数,写进数据文件末尾两列(每个周窗口各两列):
#   R24  最近 RATE24_WIN 秒的燃速,换算成「照这个速度一整周会用掉多少个百分点」(整数);
#        跨过周重置也能算:旧窗口最后一个样本 − 旧样本 + 本窗口已用;不足 RATE24_MIN_SPAN 秒的历史不算(写 "-")。
#   LF   上一个周窗口最后一次采样的已用%(周初本周还没节奏时先拿它顶上);没有上周数据写 "-"。
# 渲染器取「本周平均」与「最近 24h」两者中较高的预测:停一天不会塌(回落到周平均),猛干一天当天就报出来。
#
# 用法:series_rate 历史文件 列号 现在 已用% 重置时刻 → 设全局 R24 LF
#   历史文件每行「时刻 7d% 7d重置 Fable% Fable重置」,列号 2 取 7d、4 取 Fable(codex 侧由 python 同算法实现)。

WEEK=${WEEK:-604800}
RATE24_WIN=${RATE24_WIN:-86400}
RATE24_MIN_SPAN=${RATE24_MIN_SPAN:-21600}

_isnum() { [[ $1 =~ ^[0-9]+$ ]]; }

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

  # LF:紧挨着的上一个窗口(重置早于本窗口、且相差不超过一周零一天)的最后一个样本
  for ((i = 0; i < n; i++)); do
    [ "${R[i]}" -lt "$r" ] && [ "${R[i]}" -gt "$prev_r" ] && prev_r=${R[i]}
  done
  if [ "$prev_r" -gt 0 ] && [ $((r - prev_r)) -le $((WEEK + 86400)) ]; then
    for ((i = n - 1; i >= 0; i--)); do [ "${R[i]}" = "$prev_r" ] && { LF=${P[i]}; break; }; done
  else
    prev_r=0
  fi

  # R24:找 RATE24_WIN 秒前(或更早)最近的一个样本;历史不够长就用最早的
  t0=$((now - RATE24_WIN))
  for ((i = 0; i < n; i++)); do [ "${T[i]}" -le "$t0" ] && oi=$i; done
  [ "$oi" -ge 0 ] || oi=0
  span=$((now - T[oi])); [ "$span" -ge "$RATE24_MIN_SPAN" ] || return
  if [ "${R[oi]}" = "$r" ]; then
    delta=$((p - P[oi]))
  elif [ "$prev_r" -gt 0 ] && [ "${R[oi]}" = "$prev_r" ]; then
    lastp=${P[oi]}
    for ((i = oi; i < n; i++)); do [ "${R[i]}" = "$prev_r" ] && lastp=${P[i]}; done
    delta=$((lastp - P[oi] + p))
  else
    return   # 样本来自更早的窗口(中间断了很久),不猜
  fi
  [ "$delta" -lt 0 ] && delta=0
  R24=$(( (delta * WEEK + span / 2) / span ))
}
