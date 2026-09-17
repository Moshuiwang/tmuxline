#!/bin/bash
# 把仓库里的文件安装到本机的实际位置(符号链接),之后改仓库即改现场,git 就是变更记录。
#   ./install.sh          安装(已存在的真实文件先备份到 ~/.claude/tmux-status-backup-<UTC 时刻>/,再换成链接)
#   ./install.sh --check  只核对:每个目标是否已经链接到本仓库,不改任何东西
# 不碰 ~/.claude/settings.json(hooks / statusLine 段请按 claude/settings-hooks.snippet.json 手工合并)。
# 不碰运行期数据文件(*.dat / *.hist / *.state / *.last / *.lock),它们留在原位。
set -u
ROOT=$(cd "$(dirname "$0")" && pwd)
MODE=${1:-install}
BK="$HOME/.claude/tmux-status-backup-$(date -u +%Y%m%dT%H%M%SZ)"

# 仓库路径 → 安装路径
MAP=(
  "claude/tmux-claude-usage.sh          $HOME/.claude/tmux-claude-usage.sh"
  "claude/tmux-claude-usage-poll.sh     $HOME/.claude/tmux-claude-usage-poll.sh"
  "claude/tmux-claude-usage-rate.sh     $HOME/.claude/tmux-claude-usage-rate.sh"
  "claude/tmux-usage-compact.sh         $HOME/.claude/tmux-usage-compact.sh"
  "claude/tmux-claude-age.sh            $HOME/.claude/tmux-claude-age.sh"
  "claude/tmux-claude-hook.sh           $HOME/.claude/tmux-claude-hook.sh"
  "claude/tmux-status-extra.conf        $HOME/.claude/tmux-status-extra.conf"
  "claude/tmux-status-stage-section.conf $HOME/.claude/tmux-status-stage-section.conf"
  "claude/statusline-command.sh         $HOME/.claude/statusline-command.sh"
  "codex/tmux-codex-hook.sh             $HOME/.codex/tmux-codex-hook.sh"
  "codex/tmux-codex-quota-refresh.py    $HOME/.codex/tmux-codex-quota-refresh.py"
  "codex/hooks.json                     $HOME/.codex/hooks.json"
  "tmux.conf                            $HOME/.tmux.conf"
)

rc=0
for entry in "${MAP[@]}"; do
  read -r src dst <<<"$entry"
  abs="$ROOT/$src"
  if [ "$MODE" = --check ]; then
    if [ -L "$dst" ] && [ "$(readlink -f "$dst")" = "$abs" ]; then echo "ok      $dst"
    elif [ -e "$dst" ]; then echo "DIFFERS $dst (真实文件或指向别处的链接)"; rc=1
    else echo "MISSING $dst"; rc=1; fi
    continue
  fi
  mkdir -p "$(dirname "$dst")"
  if [ -L "$dst" ] && [ "$(readlink -f "$dst")" = "$abs" ]; then echo "已链接  $dst"; continue; fi
  if [ -e "$dst" ] || [ -L "$dst" ]; then
    mkdir -p "$BK" && mv "$dst" "$BK/$(basename "$dst")" && echo "备份    $dst → $BK/"
  fi
  ln -s "$abs" "$dst" && echo "链接    $dst → $abs"
done
[ "$MODE" = --check ] || echo "完成。状态栏脚本每 2 秒重新调用,不需要重启 tmux;tmux.conf 改动需 prefix+r 重载。"
exit $rc
