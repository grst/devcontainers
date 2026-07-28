#!/bin/sh
# Claude Code status line: context usage, session tokens, elapsed time, rate
# limits, cost.
#
# Installed at /usr/local/share/devcontainer/statusline.sh and pointed at by
# post-create.sh. Baked into the image rather than vendored into each consumer
# repo, so there is one copy to keep current instead of one per project.
#
# Plain POSIX sh plus jq and awk, all present in the base image.
input=$(cat)

in_ctx=$(echo "$input" | jq -r '(.context_window.current_usage | ((.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0)))')
total_in=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0')
total_out=$(echo "$input" | jq -r '.context_window.total_output_tokens // 0')
ctx_size=$(echo "$input" | jq -r '.context_window.context_window_size // 0')
session_total=$(( ${total_in:-0} + ${total_out:-0} ))

if [ "$ctx_size" -gt 0 ] 2>/dev/null; then
    ctx_pct=$(awk "BEGIN {printf \"%.0f\", ($in_ctx / $ctx_size) * 100}")
    ctx_part="ctx: ${in_ctx}/${ctx_size} (${ctx_pct}%)"
else
    ctx_part="ctx: ${in_ctx}"
fi

dur_ms=$(echo "$input" | jq -r '.cost.total_duration_ms // 0')
dur_s=$(( ${dur_ms:-0} / 1000 ))
dur_h=$(( dur_s / 3600 ))
dur_m=$(( (dur_s % 3600) / 60 ))
dur_part=$(printf "%02d:%02d" "$dur_h" "$dur_m")

rl_5h=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // "?"')
rl_7d=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // "?"')

cost_usd=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
cost_fmt=$(awk "BEGIN {printf \"%.2f\", $cost_usd}")

# Prefix with the egress-firewall state, for the same reason the shell prompt
# carries it: an unattended session should never leave you guessing.
fw=$(cat /run/devcontainer/firewall.state 2>/dev/null || echo '?')

printf '[fw:%s] %s | session: %s tok | %s | 5h: %s%% 7d: %s%% | $%s' \
    "$fw" "$ctx_part" "$session_total" "$dur_part" "$rl_5h" "$rl_7d" "$cost_fmt"
