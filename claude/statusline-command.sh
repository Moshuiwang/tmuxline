#!/bin/bash
# Claude Code statusLine
#
# 单行：模型 | 思考深度 | 上下文占比 | user@host:路径 (git 分支)
# 5h/7d 用量不再在这里显示（tmux 状态条已有，见 ~/.claude/tmux-claude-usage.sh），
# 但仍在末尾转发写入数据文件供 tmux 渲染。
#
# 字段路径按本机实际输入 JSON 核对过（2026-08-02，Claude Code 2.1.220）：
#   .model.display_name          模型名
#   .effort.level                思考深度 low|medium|high|xhigh|max（模型不支持时整个 effort 缺失）
#   .thinking.enabled            是否开启思考
#   .fast_mode                   快速模式
#   .workspace.current_dir       当前目录（JSON 不提供 git 分支，必须自己跑 git）
#   .rate_limits.{five_hour,seven_day}.{used_percentage,resets_at}
#       resets_at 是 Unix epoch 秒。整个 rate_limits 仅在 Claude.ai 订阅且首个 API 响应后出现，
#       两个窗口也可能各自缺失——所以每个值都用 `// empty` 取，再在 bash 里判空。
#
# 任何字段缺失都只是不渲染对应段，不报错、不留空壳。

# 显示的主机名:优先读 ~/.claude/statusline-host(一行,不入库,每台机器自己写;biai 的内部 hostname 会随实例变,
# 那边固定写 aws-ie-01),没有这个文件就用 hostname -s。
STATUS_HOST=$(head -n1 "$HOME/.claude/statusline-host" 2>/dev/null)
STATUS_HOST=${STATUS_HOST:-$(hostname -s)}

input=$(cat)
get() { printf '%s' "$input" | jq -r "$1" 2>/dev/null; }

RESET=$'\033[0m'
DIM=$'\033[2m'
CYAN=$'\033[1;36m'
BLUE=$'\033[1;34m'
GREEN=$'\033[1;32m'
YELLOW=$'\033[1;33m'
RED=$'\033[1;31m'
MAGENTA=$'\033[2;35m'

# 用量百分比按水位配色：越接近用满越刺眼
pct_color() {
  local p=${1%%.*}
  if   [ "$p" -ge 80 ] 2>/dev/null; then printf '%s' "$RED"
  elif [ "$p" -ge 50 ] 2>/dev/null; then printf '%s' "$YELLOW"
  else                                   printf '%s' "$GREEN"
  fi
}

segments=()

# --- 模型 ---
model=$(get '.model.display_name // empty')
# 去掉括号后缀（"Opus 5 (1M context)" -> "Opus 5"）：上下文窗口大小不是每次都要看的东西，
# 它占的宽度比它的信息量大。没有括号的名字不受影响。
model="${model%% (*}"
[ -n "$model" ] && segments+=("${CYAN}${model}${RESET}")

# --- 思考深度：effort 等级 + thinking 开关 + fast mode ---
depth=""
effort=$(get '.effort.level // empty')
[ -n "$effort" ] && depth="${effort}"
thinking=$(get '.thinking.enabled // empty')
[ "$thinking" = "true" ] && depth="${depth:+${depth}+}think"
fast=$(get '.fast_mode // empty')
[ "$fast" = "true" ] && depth="${depth:+${depth} }fast"
[ -n "$depth" ] && segments+=("${MAGENTA}${depth}${RESET}")

# --- 上下文占比 ---
ctx=$(get '.context_window.used_percentage // empty')
if [ -n "$ctx" ]; then
  segments+=("$(pct_color "$ctx")ctx $(printf '%.0f' "$ctx")%${RESET}")
fi

# --- 位置段：仿 ~/.bashrc 的 PS1（\u@\h 亮绿、\w 亮蓝），末尾接 git 分支 ---
# JSON 不提供 git 分支，必须自己跑；--no-optional-locks 避免碰 index.lock 干扰并发的 git 操作。
cwd=$(get '.workspace.current_dir // .cwd // empty')
[ -z "$cwd" ] && cwd="$PWD"
line2="${GREEN}$(whoami)@${STATUS_HOST}${RESET}:${BLUE}${cwd/#$HOME/\~}${RESET}"
if git -C "$cwd" --no-optional-locks rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch=$(git -C "$cwd" --no-optional-locks branch --show-current 2>/dev/null)
  [ -z "$branch" ] && branch=$(git -C "$cwd" --no-optional-locks rev-parse --short HEAD 2>/dev/null)
  dirty=""
  [ -n "$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null)" ] && dirty="*"
  [ -n "$branch" ] && line2="${line2} ${YELLOW}(${branch}${dirty})${RESET}"
fi

# 单行输出：位置段放最后（5h/7d 用量已移到 tmux 状态条，不在这里重复显示）。
segments+=("$line2")
out=""
for seg in "${segments[@]}"; do
  [ -n "$out" ] && out="${out} ${DIM}|${RESET} "
  out="${out}${seg}"
done
printf '%s\n' "$out"

# --- 顺手把账号用量转发给 tmux 状态条 ---
# tmux 侧由 ~/.claude/tmux-claude-usage.sh 读取渲染(status-right 里)。
# 账号用量是账号级数据,与终端无关,所以不管本会话在不在 tmux 里都写。
# 写临时文件再 mv,避免 tmux 读到半行。
h5p=$(get '.rate_limits.five_hour.used_percentage // empty')
h5r=$(get '.rate_limits.five_hour.resets_at // empty')
d7p=$(get '.rate_limits.seven_day.used_percentage // empty')
d7r=$(get '.rate_limits.seven_day.resets_at // empty')
if [ -n "$h5p$d7p" ]; then
  uf="$HOME/.claude/tmux-claude-usage.dat"
  printf '%s %s %s %s %s\n' "$(date +%s)" "${h5p:--}" "${h5r:--}" "${d7p:--}" "${d7r:--}" > "${uf}.tmp" \
    && mv "${uf}.tmp" "$uf"
fi
