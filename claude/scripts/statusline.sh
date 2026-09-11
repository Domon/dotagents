#!/bin/bash
# Claude Code status line.
# Output:  <model> <effort>  <cwd>  [<session_id>]  $<cost>  <ctx>%
# <effort> is the live reasoning effort (low/…/max); omitted when the model
# doesn't support the effort parameter.
#
# The cwd is shrunk ONLY as much as the terminal width requires. Parent segments
# are abbreviated to their first character (dotfiles keep dot+char), left to
# right, one at a time, until the whole line fits in $COLUMNS:
#   ~/Projects/acme/webapp/.worktrees/feature-search
#   ~/P/acme/webapp/.worktrees/feature-search
#   ~/P/a/webapp/.worktrees/feature-search
#   ~/P/a/w/.worktrees/feature-search
#   ~/P/a/w/.w/feature-search
#   .../feature-search
# The last segment is always kept whole. If $COLUMNS is unavailable, the path
# falls back to the fully-abbreviated form. Field order + full session id kept.

input=$(cat)

model_name=$(printf '%s' "$input" | jq -r '.model.display_name')
# Condense the context-window parenthetical: "Opus 4.8 (1M context)" -> "Opus 4.8 1M".
model_name=$(printf '%s' "$model_name" | sed -E 's/ *\(([0-9]+[KM])[^)]*\)/ \1/')
# Live reasoning effort (low/medium/high/xhigh/max); absent when the model has none.
effort=$(printf '%s' "$input" | jq -r '.effort.level // empty')
current_dir=$(printf '%s' "$input" | jq -r '.workspace.current_dir' | sed "s|^$HOME|~|")
session_id=$(printf '%s' "$input" | jq -r '.session_id // "no-session"')
cost=$(printf '%s' "$input" | jq -r '.cost.total_cost_usd // 0')
cost_str=$(printf '%.2f' "$cost" 2>/dev/null)

# Context-window usage as a percent of the limit (used_percentage, 0-100; falls
# back to tokens/size; empty -> omitted).
ctx_pct=$(printf '%s' "$input" | jq -r '
  (.context_window.used_percentage) as $p
  | if ($p != null and $p > 1) then $p
    elif ((.context_window.context_window_size // 0) > 0) then
      (((.context_window.total_input_tokens // 0) + (.context_window.total_output_tokens // 0))
        / .context_window.context_window_size * 100)
    else empty
    end
')
pct_num=""
[ -n "$ctx_pct" ] && pct_num=$(printf '%.0f' "$ctx_pct" 2>/dev/null)

# Columns available for the path = terminal width minus everything else on the
# line and the separators (6 = three spaces + "[" + "]" + "$"; pct adds " NN%").
cols=${COLUMNS:-}
case "$cols" in ''|*[!0-9]*) cols=0 ;; esac
unknown=1
avail=0
if [ "$cols" -gt 0 ]; then
  unknown=0
  fixed=$(( ${#model_name} + ${#session_id} + ${#cost_str} + 6 ))
  [ -n "$effort" ] && fixed=$(( fixed + ${#effort} + 1 ))
  [ -n "$pct_num" ] && fixed=$(( fixed + ${#pct_num} + 2 ))
  avail=$(( cols - fixed - 3 ))   # Claude Code truncates ~2 cols before $COLUMNS
  [ "$avail" -lt 0 ] && avail=0
fi

# Pick the least-abbreviated path that fits in $avail (fully abbreviate if width
# is unknown).
short_dir=$(printf '%s' "$current_dir" | awk -v avail="$avail" -v unknown="$unknown" -F/ '
  function abbrev(s) { return (substr(s,1,1)=="." ? substr(s,1,2) : substr(s,1,1)) }
  function candidate(k,   s,i,seg) {
    s = $1
    for (i = 2; i <= NF-1; i++) { seg = $i; if (i-1 <= k) seg = abbrev(seg); s = s "/" seg }
    return s "/" $NF
  }
  {
    if (NF <= 1) { printf "%s", $0; next }   # no parent segments (e.g. "~")
    np = NF - 2
    if (unknown == "1") { printf "%s", candidate(np); next }
    for (k = 0; k <= np; k++) {
      c = candidate(k)
      if (length(c) <= avail) { printf "%s", c; found = 1; break }
    }
    if (!found) printf "%s", ".../" $NF       # even fully abbreviated overflows
  }
')

case $(printf '%s' "$model_name" | tr '[:upper:]' '[:lower:]') in
  *fable*)  model_color=$'\033[38;5;171m' ;;
  *opus*)   model_color=$'\033[38;5;208m' ;;
  *sonnet*) model_color=$'\033[38;5;87m'  ;;
  *haiku*)  model_color=$'\033[38;5;114m' ;;
  *)        model_color=$'\033[0m'        ;;
esac

# Cost renders in grey until it passes $50, then stressed — bold on the default
# foreground (plain \033[1m), which is what Claude Code uses for bold text.
# (Not ANSI 97 "bright white": that's palette slot 15, themed warmer here.)
cost_color=$'\033[38;5;246m'
awk -v c="$cost" 'BEGIN { exit !(c > 50) }' 2>/dev/null && cost_color=$'\033[1m'

# Context % renders in grey until it passes 50%, then in periwinkle (the color
# Claude Code uses for commands / token counts).
pct_color=$'\033[38;5;245m'
[ -n "$pct_num" ] && [ "$pct_num" -gt 50 ] && pct_color=$'\033[38;2;177;185;249m'

printf '%s%s\033[0m' "$model_color" "$model_name"
[ -n "$effort" ] && printf ' %s\033[2m%s\033[0m' "$model_color" "$effort"
printf ' \033[1m%s\033[0m \033[38;5;242m[%s]\033[0m %s$%s\033[0m' \
  "$short_dir" "$session_id" "$cost_color" "$cost_str"
[ -n "$pct_num" ] && printf ' %s%s%%\033[0m' "$pct_color" "$pct_num"
