#!/bin/bash
ROOT=$(cd "$(dirname "$0")/.." && pwd)
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
exit $fail
