#!/bin/bash
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# 下面的算例按 24h 窗口写,测的是算法本身;线上默认 2026-09-22 起为 6h,这里显式固定回 24h
RATE24_WIN=86400; RATE24_MIN_SPAN=21600
. "$ROOT/claude/tmux-claude-usage-rate.sh"
cd "$(mktemp -d)"; trap 'rm -rf "$PWD"' EXIT
fail=0; chk() { if [ "$1" = "$2" ]; then echo "ok   $3 ($1)"; else echo "FAIL $3: got '$1' want '$2'"; fail=1; fi; }
R=1000000; WEEKSTART=$((R-WEEK))
# 1 同窗口:每小时采样,已用从 10 匀速涨到 40(30 小时,1%/h)。24h 前的样本 p=16 → delta=24,span=24h → R24=24*7=168
: > h1; for ((k=0;k<=30;k++)); do echo "$((WEEKSTART+k*3600)) $((10+k)) $R 0 $R" >> h1; done
now=$((WEEKSTART+30*3600)); series_rate h1 2 $now 40 $R; chk "$R24 $LF" "168 -" "同窗口 24h 燃速"
# 2 跨重置:上周末尾每小时 50..60(最后一个在重置前 1h),本周 0..5(每小时)。now=重置后 5h。
#   24h 前 = 上周 p=?:上周样本时刻 R-11h..R-1h → p 50..60;t0=now-24h=R-19h 之前没有样本 → 用最早的(R-11h,p=50),span=16h
#   delta = (60-50)+5 = 15 → R24 = 15*WEEK/16h = 15*168/16 = 157.5 → 158;LF=60
: > h2; for ((k=0;k<=10;k++)); do echo "$((R-11*3600+k*3600)) $((50+k)) $R 0 $R" >> h2; done
R2=$((R+WEEK)); for ((k=0;k<=5;k++)); do echo "$((R+k*3600)) $k $R2 0 $R2" >> h2; done
series_rate h2 2 $((R+5*3600)) 5 $R2; chk "$R24 $LF" "158 60" "跨重置燃速 + 上周终值"
# 3 历史太短(只有 2 小时)→ R24=-
: > h3; for ((k=0;k<=2;k++)); do echo "$((WEEKSTART+k*3600)) $k $R 0 $R" >> h3; done
series_rate h3 2 $((WEEKSTART+2*3600)) 2 $R; chk "$R24 $LF" "- -" "历史不足 6h 不算"
# 4 上一窗口太久远(隔了两周)→ 都不算
: > h4; echo "$((R-3*WEEK)) 70 $((R-2*WEEK)) 0 0" >> h4
series_rate h4 2 $R 1 $R; chk "$R24 $LF" "- -" "隔了两周的旧窗口不猜"
# 5 Fable 列(第 4 列)独立:7d 列全 0,Fable 24h 涨 12 → 84
: > h5; for ((k=0;k<=24;k++)); do echo "$((WEEKSTART+k*3600)) 0 $R $((k/2)) $R" >> h5; done
series_rate h5 4 $((WEEKSTART+24*3600)) 12 $R; chk "$R24 $LF" "84 -" "Fable 列独立计算"
# 6 用量倒退(接口抖动)→ 燃速钳为 0
: > h6; for ((k=0;k<=24;k++)); do echo "$((WEEKSTART+k*3600)) 30 $R 0 $R" >> h6; done
series_rate h6 2 $((WEEKSTART+24*3600)) 25 $R; chk "$R24 $LF" "0 -" "倒退钳 0"
# 7 重置时刻抖 1 秒(2026-09-24 线上现场):上周样本 …-1/…/…+1 混着,末值 97;本周 …-1/… 混着 1..4。
#   不管本次接口报的是 R2 还是 R2-1,上周终值都应是 97(以前报 R2 时把本周 …-1 的样本当上周,取成 3)
: > h7; for ((k=0;k<=10;k++)); do echo "$((R-11*3600+k*3600)) $((87+k)) $((R+k%3-1)) 0 $R" >> h7; done
for ((k=0;k<=3;k++)); do echo "$((R+k*3600)) $((k+1)) $((R2-k%2)) 0 $R2" >> h7; done
series_rate h7 2 $((R+3*3600)) 4 $R2;       chk "$LF" "97" "抖动:本次报 R2 上周终值仍取真上周"
series_rate h7 2 $((R+3*3600)) 4 $((R2-1)); chk "$LF" "97" "抖动:本次报 R2-1 同样"
# 8 同一周内重置时刻来回抖,24h 燃速照算(以前最早样本的重置和本次不「相等」就放弃)
: > h8; for ((k=0;k<=30;k++)); do echo "$((WEEKSTART+k*3600)) $((10+k)) $((R-k%2)) 0 $R" >> h8; done
series_rate h8 2 $((WEEKSTART+30*3600)) 40 $R; chk "$R24 $LF" "168 -" "抖动:同窗口燃速照算、不误认上周"
exit $fail
