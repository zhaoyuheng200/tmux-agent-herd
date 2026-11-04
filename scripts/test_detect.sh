#!/usr/bin/env bash
# test_detect.sh -- fixture-based regression tests for the detector.
# Each fixture is a saved bottom-buffer capture (fixtures/<name>.txt) plus an
# optional title (fixtures/<name>.title). Run: bash scripts/test_detect.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
DETECT="$ROOT/scripts/detect.sh"
FIX="$ROOT/fixtures"

pass=0 fail=0 skip=0
title_of() { cat "$FIX/$1.title" 2>/dev/null || true; }
have() { [ -f "$FIX/$1.txt" ]; }   # live-capture fixtures are gitignored (real content)

# run <fixture> <agent> [extra detect.sh args...]
run() {
  local fx="$1" agent="$2"; shift 2
  "$DETECT" --file "$FIX/$fx.txt" --agent "$agent" --title "$(title_of "$fx")" "$@" 2>/dev/null || echo ERR
}

# check <label> <got> <expected>
check() {
  if [ "$2" = "$3" ]; then printf '  \033[32mPASS\033[0m  %-32s -> %s\n' "$1" "$2"; pass=$((pass+1));
  else printf '  \033[31mFAIL\033[0m  %-32s -> got=%s expected=%s\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
}
# skip_missing <label> <fixture> : note a skip when a live-capture fixture is absent.
skip_missing() { printf '  \033[33mSKIP\033[0m  %-32s (fixture %s.txt not present)\n' "$1" "$2"; skip=$((skip+1)); }

# Compute the exact hash+counter detect.sh derives for a fixture, so we can feed
# them back as --prev-* to simulate a second, unchanged poll (frozen screen).
prev_pair() {
  local out; out="$("$DETECT" --file "$FIX/$1.txt" --agent "$2" --title "$(title_of "$1")" --explain 2>&1 >/dev/null)"
  PREV_H="$(sed -n 's/^cur_hash *= *\([0-9]*\).*/\1/p' <<<"$out")"
  PREV_C="$(sed -n 's/^counter *= *//p' <<<"$out")"
}

# Live-capture fixtures (idle/working/done) are gitignored because they contain
# real session content; they exist only right after capture. Skip cleanly if absent.
echo "== idle / ready states (real captures) =="
if have claude_idle; then check claude_idle "$(run claude_idle claude)" idle; else skip_missing claude_idle claude_idle; fi
if have claude_done; then check claude_done "$(run claude_done claude)" idle; else skip_missing claude_done claude_done; fi
if have kiro_idle;   then check kiro_idle   "$(run kiro_idle   kiro)"   idle; else skip_missing kiro_idle kiro_idle; fi

echo "== working (real capture): first poll trusts the braille glyph =="
if have claude_working; then
  check claude_working_firstpoll "$(run claude_working claude)" working
  echo "== working: screen changed between polls =="
  check claude_working_moved "$(run claude_working claude --prev-hash 0)" working
  echo "== stalled spinner but a READY box is visible -> idle (not a false working) =="
  # This real capture shows the braille title AND a ready ❯ box (caught between
  # turns). When the spinner is proven frozen, falling through to the visible ready
  # box (idle) is correct -- the key property is that it is NOT reported as working.
  prev_pair claude_working claude
  check claude_working_frozen_with_box "$(run claude_working claude --prev-hash "$PREV_H" --prev-counter "$PREV_C")" idle
else
  skip_missing claude_working claude_working
fi

echo "== working with NO braille title (synthetic, Claude >= ~2026-09) =="
# Regression guard for the "0 working, everything idle" bug: newer Claude Code
# pins the OSC title glyph at ✳ in every state, so working has to be read off the
# in-pane activity line. This fixture is the shape that broke it -- ✳ title, a
# live "Nucleating… (7m 19s · ↓ 30.2k tokens)" line, an earlier turn's "· done"
# line above it, and a ready ❯ box that made rule 3 answer idle.
check claude_working_no_braille "$(run claude_working_no_braille claude)" working
echo "== ... and the same fixture proven frozen -> idle, never a false working =="
prev_pair claude_working_no_braille claude
check claude_working_no_braille_frozen \
  "$(run claude_working_no_braille claude --prev-hash "$PREV_H" --prev-counter "$PREV_C")" idle

echo "== FROZEN spinner, NO ready box (truly hung agent) -> unknown, never working =="
prev_pair claude_frozen claude
check claude_frozen "$(run claude_frozen claude --prev-hash "$PREV_H" --prev-counter "$PREV_C")" unknown

echo "== blocked (synthetic, built from herdr manifest strings) =="
check claude_blocked "$(run claude_blocked claude)" blocked
check kiro_blocked   "$(run kiro_blocked   kiro)"   blocked

echo
echo "TOTAL: pass=$pass fail=$fail skip=$skip"
[ "$fail" = 0 ]
