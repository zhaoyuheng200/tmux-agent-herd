#!/usr/bin/env bash
# patterns/claude.sh -- Claude Code detection.
# Ported from herdr src/detect/manifests/claude.toml (Apache-2.0, herdrdev/herdr).
#
# Rule ORDER follows herdr's rule priorities: osc_title_working (1100) is highest,
# above the blocked forms (980/850) and the idle prompt box (950). We add one
# guard herdr lacks -- a moving-screen requirement on the spinner -- which also
# closes the "streaming text that contains an approval string" false-blocked hole:
# a working agent's screen is MOVING, so it resolves to working and never reaches
# the blocked check; a genuinely-waiting agent's screen is STATIC, so its stalled
# spinner is not trusted and it falls through to the blocked check.
#
# Inputs (from detect.sh, exported): $SCREEN $TITLE $PREV_HASH $CUR_HASH
#                                    $COUNTER $PREV_COUNTER
# Echo one of: working | blocked | idle | unknown

detect_claude() {
  local after_rule prompt_box title_working=1

  # Title carries a braille spinner glyph (U+2800..U+28FF) while working, ✳ idle.
  printf '%s' "$TITLE" | grep -qP '^[\x{2800}-\x{28FF}] ' || title_working=0

  after_rule="$(region_after_last_horizontal_rule "$SCREEN")"
  prompt_box="$(region_prompt_box_body "$SCREEN")"

  # 1. WORKING (herdr osc_title_working, priority 1100) -- spinner glyph in title
  #    AND the screen is actually moving (screen_moved: first poll trusts the
  #    glyph; later polls require a hash change or an advancing elapsed/token
  #    counter). Defeats a frozen spinner on a hung/killed agent.
  if [ "$title_working" = 1 ] && screen_moved; then
    echo working; return
  fi
  # Past this point the spinner is absent or stalled -> the pane is not actively
  # streaming, so approval-form matches below are trustworthy.

  # 2. BLOCKED: live_blocked_form (priority 980) -- "esc to cancel" plus a
  #    confirm/select hint, scoped to the text below the last horizontal rule.
  if lc_contains "$after_rule" "esc to cancel"; then
    if lc_contains "$after_rule" "enter to confirm" \
       || { lc_contains "$after_rule" "enter to select" \
            && lc_contains "$after_rule" "to navigate"; }; then
      echo blocked; return
    fi
  fi

  # 2b. dynamic_workflow_prompt (priority 980).
  if lc_contains "$SCREEN" "run a dynamic workflow?" && lc_contains "$SCREEN" "esc to cancel"; then
    echo blocked; return
  fi

  # 2c. bash_permission_prompt / generic_permission_prompt (priority 850/840):
  #     "do you want to proceed?" plus a numbered yes/no option line.
  if lc_contains "$SCREEN" "do you want to proceed?"; then
    if any_line_matches "$SCREEN" '(?i)^\s*❯?\s*1\.\s*yes\b' \
       || any_line_matches "$SCREEN" '(?i)^\s*2\.\s*no\b' \
       || any_line_matches "$SCREEN" '(?i)^\s*2\.\s*yes\b' \
       || any_line_matches "$SCREEN" '(?i)^\s*3\.\s*no\b'; then
      echo blocked; return
    fi
  fi

  # 3. IDLE: live_prompt_box (priority 950) -- ready "❯" input box, no menu hints.
  if any_line_matches "$prompt_box" '^\s*❯'; then
    if ! lc_contains "$prompt_box" "enter to select" \
       && ! lc_contains "$prompt_box" "esc to cancel" \
       && ! lc_contains "$prompt_box" "to navigate"; then
      echo idle; return
    fi
  fi

  # 4. IDLE: osc_title_idle (priority 250) -- ✳ glyph in title.
  if printf '%s' "$TITLE" | grep -qP '^\x{2733} '; then
    echo idle; return
  fi

  # 5. Spinner glyph present but stalled and nothing else matched: honestly
  #    unknown (a hung agent with no ready box), never a false "working".
  if [ "$title_working" = 1 ]; then
    echo unknown; return
  fi

  echo unknown
}
