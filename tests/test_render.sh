#!/bin/bash
# 渲染器测试:用 TMUX_CLAUDE_DIR / TMUX_CODEX_STATE_DIR / TMUX_AGY_STATE_DIR / TMUX_CLAUDE_NOW 钩子,只看去掉颜色后的文字
ROOT=$(cd "$(dirname "$0")/.." && pwd); W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0; D=$W/cd; C=$W/cx; A=$W/ag; mkdir -p "$D" "$C" "$A"
run() { TMUX_CLAUDE_DIR=$D TMUX_CODEX_STATE_DIR=$C TMUX_AGY_STATE_DIR=$A TMUX_CLAUDE_NOW=$NOW bash "$ROOT/claude/tmux-claude-usage.sh" "$1" | sed 's/#\[[^]]*\]//g; s/  */ /g; s/^ *//; s/ *$//'; }
chk() { if [ "$1" = "$2" ]; then echo "ok   $3 → $1"; else echo "FAIL $3: got '$1' want '$2'"; fail=1; fi; }
WEEK=604800; R=1790233200   # 周四 07:00 UTC
# 1 周初 2 小时(<5%),无燃速无上周 → 不显示预测(与改前一致)
NOW=$((R-WEEK+7200)); echo "$NOW 8 $((NOW+3600)) 4 $R 3 $R - - - -" > $D/tmux-claude-usage-api.dat
chk "$(run claude)" "7d 4% Fable 3% 周四 07:00" "周初无数据不预测"
# 2 周初 2 小时,有上周终值 90 / Fable 上周 40 → 4+90*rem/WEEK ≈ 4+88.9=93;3+40*0.9988≈43
echo "$NOW 8 $((NOW+3600)) 4 $R 3 $R - 90 - 40" > $D/tmux-claude-usage-api.dat
chk "$(run claude)" "7d 4% → 93% Fable 3% → 43% 周四 07:00" "周初用上周终值顶上"
# 3 周初 2 小时,上周终值 90,但 24h 燃速 200%/周 → 4+197.6=202 更高 → 204
echo "$NOW 8 $((NOW+3600)) 4 $R 3 $R 200 90 - 40" > $D/tmux-claude-usage-api.dat
chk "$(run claude)" "7d 4% → 202% Fable 3% → 43% 周四 07:00" "周初冲刺按燃速报高"
# 4 周中(过了 50%),已用 30 → 周平均 60;燃速 20%/周 → 30+10=40 更低 → 60(停一天不塌)
NOW=$((R-WEEK/2)); echo "$NOW 8 $((NOW+3600)) 30 $R 3 $R 20 90 - -" > $D/tmux-claude-usage-api.dat
chk "$(run claude)" "7d 30% → 60% Fable 3% → 6% 周四 07:00" "周中燃速低于周平均取周平均"
# 5 周中,燃速 100%/周 → 30+50=80 高于 60 → 80
echo "$NOW 8 $((NOW+3600)) 30 $R 3 $R 100 90 - -" > $D/tmux-claude-usage-api.dat
chk "$(run claude)" "7d 30% → 80% Fable 3% → 6% 周四 07:00" "周中燃速高于周平均取燃速"
# 6 旧七列文件仍可读
echo "$NOW 8 $((NOW+3600)) 30 $R 3 $R" > $D/tmux-claude-usage-api.dat
chk "$(run claude)" "7d 30% → 60% Fable 3% → 6% 周四 07:00" "旧七列文件兼容"
# 7 codex 七列:周初 2h,已用 2,上周 70 → 2+69=71;燃速 - ;5h 缺
NOW=$((R-WEEK+7200)); echo "$NOW - - 2 $R - 70" > $C/tmux-codex-usage.dat
chk "$(run codex)" "7d 2% → 71% 周四 07:00" "codex 周初上周终值"
# 8 codex 旧五列
echo "$NOW - - 2 $R" > $C/tmux-codex-usage.dat
chk "$(run codex)" "7d 2% 周四 07:00" "codex 旧五列兼容"
# 9 上限 999
NOW=$((R-WEEK/2)); echo "$NOW 8 $((NOW+3600)) 30 $R 3 $R 5000 - - -" > $D/tmux-claude-usage-api.dat
chk "$(run claude)" "7d 30% → 999% Fable 3% → 6% 周四 07:00" "上限 999"
# 10 5h 历史里重置时刻抖 1 秒:半小时从 50 涨到 70,离重置 1h → 预测 70+20×2=110,应显示(以前抖动样本被丢,算不出、不显示)
NOW=$((R-WEEK/2)); H5R=$((NOW+3600))
echo "$NOW 70 $H5R 30 $R 3 $R - - - -" > $D/tmux-claude-usage-api.dat
printf '%s 50 %s\n%s 70 %s\n' $((NOW-1800)) $((H5R-1)) $NOW $H5R > $D/tmux-claude-usage-5h.hist; rm -f $D/tmux-claude-usage-5h.state
chk "$(run claude)" "5h 70% → 110% 1h0m 7d 30% → 60% Fable 3% → 6% 周四 07:00" "5h 抖动样本照算"
# 11 重置时刻抖 1 秒仍显示 07:00
echo "$NOW - - 30 $((R-1)) - - - - - -" > $D/tmux-claude-usage-api.dat
chk "$(run claude)" "7d 30% → 60% 周四 07:00" "重置时刻抖 1 秒仍显示整分"
# 12 AGY: 5h 100% 触发显示,3p 与 Ar 重置相差 ≤5 分钟合并显示一次,Gm=0%(<5%)默认隐藏
NOW=$((R-WEEK/2)); H5R=$((NOW+3600))
echo "$NOW 100 $H5R 50 $R 18 $((R+20)) 0 $((R+3600)) - - - - - -" > $A/tmux-agy-usage.dat
chk "$(run agy)" "5h 100% 1h0m 3p 50% Ar 18% 周四 07:00" "AGY: 5h 满额 + 3p/Ar 合并重置 + Gm<5% 隐藏(不显示预测)"
# 13 AGY: Gm>=5% 时显示,且与 Ar 重置相差 >5 分钟时各自带重置时刻;5h<80% 隐藏
rm -f $A/tmux-agy-usage-5h.state
echo "$NOW 10 $H5R 50 $R 18 $R 12 $((R+3600)) - - - - - -" > $A/tmux-agy-usage.dat
chk "$(run agy)" "3p 50% Ar 18% 周四 07:00 Gm 12% 周四 08:00" "AGY: 5h 低占用隐藏 + Gm>=5% 独立重置显示(不显示预测)"
# 14 top 模式拼接 AGY + Codex
echo "$NOW - - 40 $R - -" > $C/tmux-codex-usage.dat
chk "$(run top)" "3p 50% Ar 18% 周四 07:00 Gm 12% 周四 08:00 7d 40% → 80% 周四 07:00" "top: 拼接 AGY 与 Codex"
exit $fail
