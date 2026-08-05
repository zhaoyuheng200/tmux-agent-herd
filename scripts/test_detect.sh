#!/usr/bin/env bash
# test_detect.sh -- fixture-based regression tests for the detector.
# Each fixture is a saved bottom-buffer capture (fixtures/<name>.txt) plus an
# optional title (fixtures/<name>.title). Run: bash scripts/test_detect.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
DETECT="$ROOT/scripts/detect.sh"
FIX="$ROOT/fixtures"

pass=0 fail=0
title_of() { cat "$FIX/$1.title" 2>/dev/null || true; }

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

# Compute the exact hash+counter detect.sh derives for a fixture, so we can feed
# them back as --prev-* to simulate a second, unchanged poll (frozen screen).
prev_pair() {
  local out; out="$("$DETECT" --file "$FIX/$1.txt" --agent "$2" --title "$(title_of "$1")" --explain 2>&1 >/dev/null)"
  PREV_H="$(sed -n 's/^cur_hash *= *\([0-9]*\).*/\1/p' <<<"$out")"
  PREV_C="$(sed -n 's/^counter *= *//p' <<<"$out")"
}

echo "== idle / ready states (real captures) =="
check claude_idle  "$(run claude_idle  claude)" idle
check claude_done  "$(run claude_done  claude)" idle   # finished turn shows ready box = idle
check kiro_idle    "$(run kiro_idle    kiro)"   idle

echo "== working (real capture): first poll trusts the braille glyph =="
check claude_working_firstpoll "$(run claude_working claude)" working
echo "== working: screen changed between polls =="
check claude_working_moved "$(run claude_working claude --prev-hash 0)" working
echo "== stalled spinner but a READY box is visible -> idle (not a false working) =="
# This real capture shows the braille title AND a ready ❯ box (caught between
# turns). When the spinner is proven frozen, falling through to the visible ready
# box (idle) is correct -- the key property is that it is NOT reported as working.
prev_pair claude_working claude
check claude_working_frozen_with_box "$(run claude_working claude --prev-hash "$PREV_H" --prev-counter "$PREV_C")" idle
echo "== FROZEN spinner, NO ready box (truly hung agent) -> unknown, never working =="
prev_pair claude_frozen claude
check claude_frozen "$(run claude_frozen claude --prev-hash "$PREV_H" --prev-counter "$PREV_C")" unknown

echo "== blocked (synthetic, built from herdr manifest strings) =="
check claude_blocked "$(run claude_blocked claude)" blocked
check kiro_blocked   "$(run kiro_blocked   kiro)"   blocked

echo
echo "TOTAL: pass=$pass fail=$fail"
[ "$fail" = 0 ]
