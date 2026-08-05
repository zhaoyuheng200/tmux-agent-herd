#!/usr/bin/env bash
# detect.sh -- classify a single pane's agent state.
#
# Usage:
#   detect.sh --target <session:win.pane>          classify a live pane
#   detect.sh --file screen.txt --agent claude [--title '⠂ x'] [--prev-hash H]
#                                                  classify a saved fixture
#   detect.sh --explain ...                         also print which region/rule fired
#
# Prints the state (working|blocked|idle|done|unknown) on stdout.
# Agent identity for a live target is resolved from the pane's foreground process
# name (claude / kiro-cli / codex). This matches herdr for these native-binary
# agents; node/bun-wrapped agents (gemini, copilot) would need a process-tree
# walk and are intentionally out of MVP scope.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"

TARGET="" FILE="" AGENT="" TITLE="" PREV_HASH="" PREV_COUNTER="" EXPLAIN=0 META=0
CAPTURE_LINES="${AGENT_HERD_CAPTURE_LINES:-40}"

while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --file) FILE="$2"; shift 2 ;;
    --agent) AGENT="$2"; shift 2 ;;
    --title) TITLE="$2"; shift 2 ;;
    --prev-hash) PREV_HASH="$2"; shift 2 ;;
    --prev-counter) PREV_COUNTER="$2"; shift 2 ;;
    --explain) EXPLAIN=1; shift ;;
    --meta) META=1; shift ;;   # print "state|cur_hash|counter" in one line
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Map a foreground process name to a known agent id.
identify_agent() {
  case "$1" in
    claude|claude-code) echo claude ;;
    kiro|kiro-cli) echo kiro ;;
    codex) echo codex ;;
    *) echo "" ;;
  esac
}

if [ -n "$TARGET" ]; then
  cmd="$(tmux display-message -p -t "$TARGET" '#{pane_current_command}' 2>/dev/null || true)"
  AGENT="$(identify_agent "$cmd")"
  [ -n "$AGENT" ] || { [ "$META" = 1 ] && echo "none||"; [ "$META" = 1 ] || echo "none"; exit 0; }
  [ -n "$TITLE" ] || TITLE="$(tmux display-message -p -t "$TARGET" '#{pane_title}' 2>/dev/null || true)"
  SCREEN="$(tmux capture-pane -p -t "$TARGET" -S "-$CAPTURE_LINES" 2>/dev/null || true)"
elif [ -n "$FILE" ]; then
  [ -n "$AGENT" ] || { echo "error: --file needs --agent" >&2; exit 2; }
  SCREEN="$(cat "$FILE")"
else
  echo "error: need --target or --file" >&2; exit 2
fi

# Extract a monotonic counter from the screen for the motion check: Claude's
# footer clock ("Midway: 17h 08m") and any "<n>s"/"<n.n>k tokens" elapsed marker.
# We concatenate all digit runs on matching lines into one comparable string.
extract_counter() {
  printf '%s\n' "$SCREEN" \
    | grep -oP '(?:Midway:\s*\S+|\b\d+m\b|\b\d+s\b|[\d.]+k tokens|Context:\s*\d+%)' \
    | tr -d '\n ' || true
}
COUNTER="$(extract_counter)"
CUR_HASH="$(printf '%s' "$SCREEN" | cksum | cut -d' ' -f1)"

export SCREEN TITLE PREV_HASH CUR_HASH COUNTER PREV_COUNTER

# shellcheck source=../patterns/claude.sh
source "$ROOT/patterns/$AGENT.sh"
state="$("detect_$AGENT")"
[ -n "$state" ] || state="unknown"

if [ "$EXPLAIN" = 1 ]; then
  {
    echo "agent      = $AGENT"
    echo "title      = $TITLE"
    echo "cur_hash   = $CUR_HASH   prev_hash = ${PREV_HASH:-<none>}"
    echo "counter    = $COUNTER"
    echo "state      = $state"
    echo "--- bottom 8 non-empty lines ---"
    region_bottom_non_empty_lines "$SCREEN" 8
  } >&2
fi

# --meta: one line "state|cur_hash|counter" so the daemon gets state + the
# motion-tracking values from a single capture (no second capture-pane).
if [ "$META" = 1 ]; then
  echo "$state|$CUR_HASH|$COUNTER"
else
  echo "$state"
fi
