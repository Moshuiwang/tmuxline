#!/bin/bash
# CPU / 内存段测试:用 TMUX_SYSLOAD_PROC 指向假 /proc,TMUX_SYSLOAD_STATE 指向临时采样文件
ROOT=$(cd "$(dirname "$0")/.." && pwd); W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0; P=$W/proc; mkdir -p "$P"; S=$W/cpu.prev
run() { TMUX_SYSLOAD_PROC=$P TMUX_SYSLOAD_STATE=$S bash "$ROOT/claude/tmux-sysload.sh" "$1"; }
plain() { run "$1" | sed 's/#\[[^]]*\]//g'; }
chk() { if [ "$1" = "$2" ]; then echo "ok   $3 → $1"; else echo "FAIL $3: got '$1' want '$2'"; fail=1; fi; }
stat() { echo "cpu  $1 0 0 $2 0 0 0 0 0 0" > "$P/stat"; }   # $1=忙碌 $2=空闲(累计)
mem()  { printf 'MemTotal:       %s kB\nMemFree:        1 kB\nMemAvailable:   %s kB\n' "$1" "$2" > "$P/meminfo"; }

mem 1000 390; stat 100 900
chk "$(plain 10)" "M61%" "首次无上一次采样:只显示内存"
stat 150 950     # 本轮 忙 50 / 共 100
chk "$(plain 10)" "C50% M61%" "两项都显示"
stat 155 1045    # 忙 5 / 共 100 → 两位右对齐
chk "$(plain 9)" "C 5% M61%" "个位数右对齐、宽 9 刚好放下"
stat 175 1065    # 忙 20 / 共 40 = 50% < 61%
chk "$(plain 8)" "M61%" "宽不够两项:只显示较高的内存"
stat 245 1075    # 忙 70 / 共 80 = 88% > 61%
chk "$(plain 5)" "C88%" "宽不够两项:只显示较高的 CPU"
stat 250 1080
chk "$(plain 3)" "" "再窄不输出"
mem 1000 150; stat 350 1080   # 内存 85% 黄、CPU 100% 红
chk "$(run 10)" "#[fg=#f38ba8]C100%#[fg=#9399b2] #[fg=#f9e2af]M85%#[fg=#9399b2]" "超 80% 黄、超 90% 红"
exit $fail
