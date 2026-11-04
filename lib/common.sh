#!/usr/bin/env bash
# common.sh -- shared helpers and screen-region extractors for tmux-agent-herd.
#
# Region model is a pragmatic port of Herdr's src/detect (Apache-2.0):
# detection runs against the pane's visible bottom-of-buffer snapshot, and rules
# are scoped to regions (whole screen, bottom-N non-empty lines, the input/prompt
# box, or the text below the last horizontal rule). Matching is case-insensitive
# substring ("contains") plus optional line-anchored PCRE, highest-priority rule wins.

# Case-insensitive substring test. Usage: lc_contains "$haystack" "needle"
lc_contains() {
  case "${1,,}" in
    *"${2,,}"*) return 0 ;;
    *) return 1 ;;
  esac
}

# Line numbers (1-based) of horizontal-rule lines: runs of box-drawing ─ / ━ or
# long ascii - / _ dashes. Claude and Codex draw the input box with ─ rules.
_rule_line_numbers() {
  printf '%s\n' "$1" | grep -nP '[\x{2500}\x{2501}]{5,}|-{10,}|_{10,}' | cut -d: -f1
}

# region_whole_recent: the entire captured snapshot.
region_whole_recent() { printf '%s\n' "$1"; }

# region_bottom_non_empty_lines N: last N non-empty lines (order preserved).
region_bottom_non_empty_lines() {
  local text="$1" n="$2"
  printf '%s\n' "$text" | grep -v '^[[:space:]]*$' | tail -n "$n"
}

# region_after_last_horizontal_rule: lines below the last horizontal rule.
# Empty when no rule is present (conservative: avoids false region matches).
region_after_last_horizontal_rule() {
  local text="$1" last
  last="$(_rule_line_numbers "$text" | tail -1)"
  [ -n "$last" ] || return 0
  printf '%s\n' "$text" | tail -n +"$((last + 1))"
}

# region_prompt_box_body: the lines between the last two horizontal rules -- for
# Claude this is the input line (e.g. "❯ ...") that sits inside the boxed prompt.
region_prompt_box_body() {
  local text="$1"
  local -a nums
  mapfile -t nums < <(_rule_line_numbers "$text")
  local c=${#nums[@]}
  [ "$c" -ge 2 ] || return 0
  local a=${nums[c-2]} b=${nums[c-1]}
  [ "$b" -gt "$((a + 1))" ] || return 0
  printf '%s\n' "$text" | sed -n "$((a + 1)),$((b - 1))p"
}

# any_line_matches "$text" 'PCRE' : true if any single line matches (grep -P).
any_line_matches() { printf '%s\n' "$1" | grep -qP "$2"; }

# Shapes of an agent status line. Kept as constants so the region extractor below
# and the per-agent rules that classify the line cannot drift apart.
STATUS_LINE_LIVE_RE='\x{2026}\s*\([^)]*\d+\s*[smh]\b'   # "… (7m 19s · ↓ 30.2k tokens)"
STATUS_LINE_DONE_RE='\x{00B7}\s+done\b'                 # "· done 1:49 PM"

# region_last_status_line: the LAST agent status line on screen -- either a live
# activity line ("<verb>… (<elapsed> · ↓ <n>k tokens)") or a finished one
# ("<verb> for <elapsed> · done <clock>"). Claude leaves each turn's finished
# status line in the scrollback, so only the last match describes the current
# turn; taking any match would let a previous turn's "done" mask a live one.
region_last_status_line() {
  printf '%s\n' "$1" | grep -P "$STATUS_LINE_LIVE_RE|$STATUS_LINE_DONE_RE" | tail -1
}

# screen_moved : frozen-spinner guard. Returns 0 (moved -> a spinner glyph may be
# trusted as "working") when EITHER we have no prior poll (first sight: trust the
# glyph, like herdr), OR the screen hash changed, OR the elapsed/token counter
# advanced. Returns 1 (frozen: hash identical AND counter unchanged across polls)
# so a hung/killed agent that left a spinner frame on screen is NOT read as working.
# Reads PREV_HASH/CUR_HASH/COUNTER/PREV_COUNTER from the environment.
screen_moved() {
  [ -z "${PREV_HASH:-}" ] && return 0                       # first poll: trust glyph
  [ "${PREV_HASH}" != "${CUR_HASH:-}" ] && return 0         # screen changed
  [ -n "${COUNTER:-}" ] && [ "${COUNTER}" != "${PREV_COUNTER:-}" ] && return 0
  return 1                                                   # frozen
}
