#!/usr/bin/env bash
# 窄屏用的额度紧凑段：C=Claude 7 天已用% F=Fable 已用% X=codex 7 天已用%（数据文件同 tmux-claude-usage.sh）
a=$HOME/.claude/tmux-claude-usage-api.dat; b=$HOME/.claude/tmux-claude-usage.dat; c=$HOME/.local/state/tmux-codex-quota/tmux-codex-usage.dat
now=$(date +%s); c7=; f=; x=
if [ -r "$a" ] && read -r t _ _ d7 _ fb _ < "$a" && [ $((now - t)) -lt 1800 ]; then c7=$d7; f=$fb
elif [ -r "$b" ] && read -r t _ _ d7 _ < "$b"; then c7=$d7; fi
[ -r "$c" ] && read -r _ _ _ x _ < "$c"
seg=""
[ -n "$c7" ] && seg+=" C${c7}"
[ -n "$f" ] && seg+=" F${f}"
[ -n "$x" ] && [ "$x" != "-" ] && seg+=" X${x}"
if [ "${1:-}" = plain ]; then [ -n "$seg" ] && printf '%s' "${seg# }"; else [ -n "$seg" ] && printf '#[bg=#313244]#[fg=#cdd6f4]%s #[default]' "$seg"; fi
