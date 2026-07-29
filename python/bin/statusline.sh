#!/bin/sh
# Claude Code status line: context usage, session tokens, elapsed time, rate
# limits, cost.
#
# Installed at /usr/local/share/devcontainer/statusline.sh and pointed at by
# post-create.sh. Baked into the image rather than vendored into each consumer
# repo, so there is one copy to keep current instead of one per project.
#
# Plain POSIX sh plus jq. One jq pass computes everything it can; printf handles the
# zero-padded duration and the two-decimal cost, which jq has no format verb for.
{
    read -r ctx_part
    read -r session_total
    read -r dur_h
    read -r dur_m
    read -r rl_5h
    read -r rl_7d
    read -r cost_usd
} <<EOF
$(jq -r '
    (.context_window // {}) as $cw
  | (($cw.current_usage // {})
      | (.input_tokens // 0) + (.cache_creation_input_tokens // 0)
        + (.cache_read_input_tokens // 0)) as $in
  | ($cw.context_window_size // 0) as $size
  | ((.cost.total_duration_ms // 0) / 1000 | floor) as $secs
  | [ (if $size > 0 then "ctx: \($in)/\($size) (\($in / $size * 100 | round)%)"
                    else "ctx: \($in)" end),
      (($cw.total_input_tokens // 0) + ($cw.total_output_tokens // 0)),
      ($secs / 3600 | floor),
      ($secs % 3600 / 60 | floor),
      (.rate_limits.five_hour.used_percentage // "?"),
      (.rate_limits.seven_day.used_percentage // "?"),
      (.cost.total_cost_usd // 0)
    ] | .[]')
EOF

# Malformed input leaves these empty, and printf %02d would then fail noisily in a
# place nobody is watching.
: "${ctx_part:=ctx: ?}" "${session_total:=0}" "${dur_h:=0}" "${dur_m:=0}"
: "${rl_5h:=?}" "${rl_7d:=?}" "${cost_usd:=0}"

# Prefix with the egress-firewall state, for the same reason the shell prompt
# carries it: an unattended session should never leave you guessing.
fw=$(cat /run/devcontainer/firewall.state 2>/dev/null || echo '?')

printf '[fw:%s] %s | session: %s tok | %02d:%02d | 5h: %s%% 7d: %s%% | $%.2f' \
    "$fw" "$ctx_part" "$session_total" "$dur_h" "$dur_m" "$rl_5h" "$rl_7d" "$cost_usd"
