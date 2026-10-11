#!/bin/bash
# Claude Code statusLine script
# Shows: model name + effort | current dir | git branch | context usage | session cost | rate limit usage

input=$(cat)

model=$(echo "$input" | jq -r '.model.display_name')

# reasoning effort (absent when the model does not support the effort parameter)
effort=$(echo "$input" | jq -r '.effort.level // empty')

dir=$(echo "$input" | jq -r '.workspace.current_dir')
cwd_display=$(basename "$dir" 2>/dev/null)

# git branch (skip optional locks so we never block on a git lock file)
branch=""
if git -C "$dir" --no-optional-locks rev-parse --is-inside-work-tree > /dev/null 2>&1; then
  branch=$(git -C "$dir" --no-optional-locks branch --show-current 2>/dev/null)
fi

# context window usage
used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')

# session cost so far, in USD (the same figure /cost reports)
cost=$(echo "$input" | jq -r '.cost.total_cost_usd // empty')

# claude.ai subscription rate limits
five=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
week=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')

# ANSI colors (dimmed, since the status line renders with dimmed colors)
RESET='\033[0m'
DIM='\033[2m'
CYAN='\033[2;36m'
BLUE='\033[2;34m'
GREEN='\033[2;32m'
YELLOW='\033[2;33m'
MAGENTA='\033[2;35m'

out="${CYAN}${model}${RESET}"
if [ -n "$effort" ]; then
  out="${out} ${CYAN}[${effort}]${RESET}"
fi
out="${out} ${DIM}${cwd_display}${RESET}"

if [ -n "$branch" ]; then
  out="${out} ${GREEN}(${branch})${RESET}"
fi

if [ -n "$used" ]; then
  used_r=$(printf '%.0f' "$used")
  out="${out} ${YELLOW}ctx:${used_r}%${RESET}"
fi

if [ -n "$cost" ]; then
  out="${out} ${MAGENTA}\$$(printf '%.2f' "$cost")${RESET}"
fi

rl=""
if [ -n "$five" ]; then
  rl="5h:$(printf '%.0f' "$five")%"
fi
if [ -n "$week" ]; then
  [ -n "$rl" ] && rl="${rl} "
  rl="${rl}7d:$(printf '%.0f' "$week")%"
fi
if [ -n "$rl" ]; then
  out="${out} ${BLUE}${rl}${RESET}"
fi

printf "%b" "$out"
