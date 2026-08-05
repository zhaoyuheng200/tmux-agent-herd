#!/usr/bin/env bash
# patterns/codex.sh -- Codex CLI detection.
# Ported from herdr src/detect/manifests/codex.toml (Apache-2.0, herdrdev/herdr).
# Rule order follows herdr priorities: osc_title_blocked (1100) > osc_title_working
# (1050) > live_strong_blocker (900) > weak_blocker (600) > screen fallback (500) >
# osc_title_idle (100). The moving-screen guard sits on the title spinner.

detect_codex() {
  local after_rule bottom3 title_working=0

  # 1. osc_title_blocked (priority 1100): Codex writes "Action Required" to the
  #    title when it needs input -- an authoritative, spoof-resistant blocked signal.
  if lc_contains "$TITLE" "action required"; then
    echo blocked; return
  fi

  # 2. osc_title_working (priority 1050): spinner glyph in title, guarded by motion.
  printf '%s' "$TITLE" | grep -qP '(?:^| )[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏](?: |$)' && title_working=1
  if [ "$title_working" = 1 ] && screen_moved; then
    echo working; return
  fi

  after_rule="$(region_after_last_horizontal_rule "$SCREEN")"
  bottom3="$(region_bottom_non_empty_lines "$SCREEN" 3)"

  # 3. live_strong_blocker (priority 900): region after_last_prompt_marker,
  #    approximated with after_last_horizontal_rule + whole-screen fallback.
  local scope
  for scope in "$after_rule" "$SCREEN"; do
    if lc_contains "$scope" "press enter to confirm or esc to cancel" \
       || lc_contains "$scope" "enter to submit answer" \
       || lc_contains "$scope" "enter to submit all" \
       || lc_contains "$scope" "allow command?"; then
      echo blocked; return
    fi
  done

  # 4. weak_blocker (priority 600): region=whole_recent.
  if lc_contains "$SCREEN" "[y/n]" || lc_contains "$SCREEN" "yes (y)"; then
    echo blocked; return
  fi
  if { lc_contains "$SCREEN" "do you want to" || lc_contains "$SCREEN" "would you like to"; } \
     && { lc_contains "$SCREEN" "yes" || lc_contains "$SCREEN" "❯"; }; then
    echo blocked; return
  fi

  # 5. screen_working_fallback (priority 500): "• Working (… esc to interrupt)".
  if any_line_matches "$bottom3" '^[•◦]\s+Working \([^)]*esc to interrupt\)' \
     && ! lc_contains "$SCREEN" "conversation interrupted"; then
    echo working; return
  fi

  # 6. osc_title_idle (priority 100): title has content, not a spinner, not blocked.
  if printf '%s' "$TITLE" | grep -qP '\S' && [ "$title_working" = 0 ]; then
    echo idle; return
  fi

  # Spinner present but stalled and nothing else matched -> unknown, not working.
  echo unknown
}
