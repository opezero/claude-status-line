#!/bin/bash
# Claude Code Enhanced Status Line for Ghostty
# - Includes Context Breakdown (Cache Read / Fresh Write)

# 安全装置: 入力が空、または不正なJSONの場合は何も表示せずに終了
input=$(cat)
if [ -z "$input" ] || ! echo "$input" | jq -e . >/dev/null 2>&1; then
  exit 0
fi

CLAUDE_DIR="$HOME/.claude"
SESSION_FILE="$CLAUDE_DIR/.sl_session.json"
LAST_STATE_FILE="$CLAUDE_DIR/.sl_last_state.json"
USAGE_LOG="$CLAUDE_DIR/.sl_usage_log.csv"

# ====== 契約プラン名 (ここを自分のプランに書き換えてください) ======
PLAN_NAME="Max (20x)"
# ===================================================================

# Color & Style Definitions
C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'
C_RED=$'\033[31m'
C_BLUE=$'\033[34m'
C_DIM=$'\033[2m'
C_BOLD=$'\033[1m'
C_RESET=$'\033[0m'

# Nerd Fonts Icons
I_AI="󰚩"      # Robot/AI
I_PLAN="󰉇"    # Plan/Subscription (sparkle)
I_CTX="󰋊"     # Chip/Context
I_IN="󰇚"      # Download/Input
I_OUT="󰕯"     # Upload/Output
I_GIT="󰘬"     # Git branch
I_BRN="󱐋"     # Lightning/Burn rate
I_DAY="󰃰"     # Day
I_WEK="󰃭"     # Week
I_MON="󰃬"     # Month
I_RL5="󱎫"     # Rate limit 5h (clock)
I_RL7="󰸗"     # Rate limit 7d (calendar)
I_EFF="󱐌"     # Effort / thinking level
SEP="${C_DIM}│${C_RESET}" # 目立たない区切り線

# Extract Basic Data
model=$(echo "$input" | jq -r '.model.display_name // "Unknown"')
total_input=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0')
total_output=$(echo "$input" | jq -r '.context_window.total_output_tokens // 0')
context_size=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // 0')
session_id=$(echo "$input" | jq -r '.session_id // "unknown"')

# ====== レートリミット & Effort データを取得 ======
rl5_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // 0')
rl5_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // 0')
rl7_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // 0')
rl7_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // 0')
effort_level=$(echo "$input" | jq -r '.effort.level // "-"')
thinking_on=$(echo "$input" | jq -r '.thinking.enabled // false')
# ===================================================

# ====== キャッシュの内訳データを取得 ======
cache_read=$(echo "$input" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0')
cache_create=$(echo "$input" | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0')
fresh=$(echo "$input" | jq -r '.context_window.current_usage.input_tokens // 0')

read_k=$((cache_read / 1000))
write_k=$(( (cache_create + fresh) / 1000 ))
cache_str="${read_k}k/${write_k}k"
# ===================================================

used_tokens=$((total_input + total_output))
current_used=$(awk "BEGIN {printf \"%.0f\", ($used_pct * $context_size) / 100}")
current_time=$(date +%s)

# Format number with k/M suffix
fmt() {
  local n=$1
  if [ "$n" -ge 1000000 ] 2>/dev/null; then
    awk "BEGIN {printf \"%.1fM\", $n/1000000}"
  elif [ "$n" -ge 1000 ] 2>/dev/null; then
    awk "BEGIN {printf \"%.1fk\", $n/1000}"
  else
    echo "${n:-0}"
  fi
}

# Format a future unix timestamp as remaining time until it (e.g. "3.2h", "45min")
fmt_until() {
  local target=$1
  local diff=$((target - current_time))
  if [ "$diff" -le 0 ] 2>/dev/null; then
    echo "now"
  elif [ "$diff" -ge 3600 ] 2>/dev/null; then
    awk "BEGIN {printf \"%.1fh\", $diff/3600}"
  elif [ "$diff" -ge 60 ] 2>/dev/null; then
    awk "BEGIN {printf \"%.0fmin\", $diff/60}"
  else
    echo "${diff}s"
  fi
}

# Initialize usage log
[ ! -f "$USAGE_LOG" ] && echo "ts,sid,tokens" > "$USAGE_LOG"

# Session & burn rate tracking
burn_rate_str="--"
br_val=0

if [ -f "$LAST_STATE_FILE" ]; then
  last_sid=$(jq -r '.sid // ""' "$LAST_STATE_FILE" 2>/dev/null)
  last_tok=$(jq -r '.tok // 0' "$LAST_STATE_FILE" 2>/dev/null)
  if [ "$session_id" != "$last_sid" ] || [ "$current_used" -lt "${last_tok:-0}" ]; then
    if [ -n "$last_sid" ] && [ "${last_tok:-0}" -gt 0 ]; then
      echo "$current_time,$last_sid,$last_tok" >> "$USAGE_LOG"
    fi
    printf '{"ts":%d,"tok":0}' "$current_time" > "$SESSION_FILE"
  fi
else
  printf '{"ts":%d,"tok":0}' "$current_time" > "$SESSION_FILE"
fi

# Update last state
printf '{"sid":"%s","tok":%d,"ts":%d}' "$session_id" "$current_used" "$current_time" > "$LAST_STATE_FILE"

# Calculate burn rate
if [ -f "$SESSION_FILE" ]; then
  s_start=$(jq -r '.ts' "$SESSION_FILE" 2>/dev/null || echo "$current_time")
  elapsed=$((current_time - s_start))
  if [ "$elapsed" -gt 10 ] && [ "$current_used" -gt 0 ]; then
    br_val=$(awk "BEGIN {v=($current_used * 60.0) / $elapsed; printf \"%.0f\", v}")
    burn_rate_str="$(fmt "$br_val")/min"
  fi
fi

# Aggregate daily/weekly/monthly
day_start=$(date -j -v0H -v0M -v0S +%s 2>/dev/null || echo $((current_time - 86400)))
week_ago=$((current_time - 604800))
month_ago=$((current_time - 2592000))
d_total=0; w_total=0; m_total=0

if [ -f "$USAGE_LOG" ]; then
  while IFS=, read -r ts sid tok; do
    [ "$ts" = "ts" ] && continue
    [[ "$tok" =~ ^[0-9]+$ ]] || continue
    [ "${ts:-0}" -ge "$day_start" ] 2>/dev/null && d_total=$((d_total + tok))
    [ "${ts:-0}" -ge "$week_ago" ] 2>/dev/null && w_total=$((w_total + tok))
    [ "${ts:-0}" -ge "$month_ago" ] 2>/dev/null && m_total=$((m_total + tok))
  done < "$USAGE_LOG"
fi

d_total=$((d_total + used_tokens))
w_total=$((w_total + used_tokens))
m_total=$((m_total + used_tokens))

# Git Status & Colors
git_info=""
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch=$(git branch --show-current 2>/dev/null || git rev-parse --short HEAD 2>/dev/null)
  status_str=""

  ! git diff --quiet 2>/dev/null && status_str+="*"
  ! git diff --cached --quiet 2>/dev/null && status_str+="+"
  [ -n "$(git ls-files --others --exclude-standard 2>/dev/null)" ] && status_str+="?"

  if [ -z "$status_str" ]; then
    git_info="${C_GREEN}${I_GIT} ${branch}${C_RESET} ${SEP} "
  else
    git_info="${C_YELLOW}${I_GIT} ${branch}[${status_str}]${C_RESET} ${SEP} "
  fi
fi

# Build progress bar
pct_int=$(awk "BEGIN {printf \"%.0f\", ${used_pct:-0}}" 2>/dev/null || echo "0")
filled=$((pct_int / 10))
[ "$filled" -gt 10 ] && filled=10
empty=$((10 - filled))
bar=""
for ((i=0; i<filled; i++)); do bar+="■"; done
for ((i=0; i<empty; i++)); do bar+="□"; done

# Performance zone & Cache indicator formatting
if [ "$pct_int" -ge 90 ]; then
  perf="${C_RED}${C_BOLD}Critical (${cache_str})${C_RESET}"
  bar="${C_RED}${bar}${C_RESET}"
elif [ "$pct_int" -ge 70 ]; then
  perf="${C_YELLOW}Warning (${cache_str})${C_RESET}"
  bar="${C_YELLOW}${bar}${C_RESET}"
elif [ "$pct_int" -ge 50 ]; then
  perf="${C_YELLOW}Caution (${cache_str})${C_RESET}"
  bar="${C_YELLOW}${bar}${C_RESET}"
else
  perf="${C_GREEN}Good (${cache_str})${C_RESET}"
  bar="${C_GREEN}${bar}${C_RESET}"
fi

# Rate limit color helper (green <50, yellow <80, red >=80)
rl_fmt() {
  local pct=$1 reset=$2 icon=$3
  local p_int color
  p_int=$(awk "BEGIN {printf \"%.0f\", ${pct:-0}}" 2>/dev/null || echo "0")
  if [ "$p_int" -ge 80 ]; then color="$C_RED"
  elif [ "$p_int" -ge 50 ]; then color="$C_YELLOW"
  else color="$C_GREEN"; fi
  local reset_str="--"
  [ "${reset:-0}" -gt 0 ] 2>/dev/null && reset_str="$(fmt_until "$reset")"
  printf "%s%s %d%% ~%s%s" "$color" "$icon" "$p_int" "$reset_str" "$C_RESET"
}
rl5_str=$(rl_fmt "$rl5_pct" "$rl5_reset" "$I_RL5")
rl7_str=$(rl_fmt "$rl7_pct" "$rl7_reset" "$I_RL7")

# Effort / thinking string
if [ "$thinking_on" = "true" ]; then
  effort_str="${C_BLUE}${I_EFF} ${effort_level}+think${C_RESET}"
else
  effort_str="${C_DIM}${I_EFF} ${effort_level}${C_RESET}"
fi

# Output Format (1行目：基本情報＋キャッシュ内訳 / 2行目：履歴とGit)
printf "${C_BLUE}%s ${C_BOLD}%s${C_RESET} ${C_DIM}%s %s${C_RESET} ${SEP} %s ${SEP} %s %s/%s %s %d%% %s ${SEP} %s%s %s%s\n" \
  "$I_AI" "$model" \
  "$I_PLAN" "$PLAN_NAME" \
  "$effort_str" \
  "$I_CTX" "$(fmt $current_used)" "$(fmt $context_size)" "$bar" "$pct_int" "$perf" \
  "$I_IN" "$(fmt $total_input)" "$I_OUT" "$(fmt $total_output)"

printf "%s%s %s/min ${SEP} %s %s ${SEP} %s %s ${SEP} %s %s ${SEP} %s ${SEP} %s\n" \
  "$git_info" \
  "$I_BRN" "$burn_rate_str" \
  "$I_DAY" "$(fmt $d_total)" \
  "$I_WEK" "$(fmt $w_total)" \
  "$I_MON" "$(fmt $m_total)" \
  "$rl5_str" \
  "$rl7_str"
