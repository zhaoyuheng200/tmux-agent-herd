#!/usr/bin/env bash
# patterns/kiro.sh -- Kiro CLI detection.
# Ported from herdr src/detect/manifests/kiro.toml (Apache-2.0, herdrdev/herdr).
# Kiro does NOT set a spinner glyph in the pane title, so detection is fully
# screen-content based. All region = whole_recent in the source manifest.

detect_kiro() {
  # --- tool_approval (herdr priority 300): "requires approval" + an approval verb.
  if lc_contains "$SCREEN" "requires approval"; then
    if lc_contains "$SCREEN" "yes, single permission" \
       || lc_contains "$SCREEN" "trust, always allow" \
       || lc_contains "$SCREEN" "no (tab to edit)" \
       || lc_contains "$SCREEN" "esc to close"; then
      echo blocked; return
    fi
  fi

  # --- subagent_approval (herdr priority 290).
  if lc_contains "$SCREEN" "pending from subagents"; then
    if lc_contains "$SCREEN" "tool approval"; then
      if lc_contains "$SCREEN" "approve all pending" \
         || lc_contains "$SCREEN" "configure individually" \
         || lc_contains "$SCREEN" "exit (cancel subagents)"; then
        echo blocked; return
      fi
    fi
  fi

  # --- kiro_working_marker (herdr priority 100).
  if lc_contains "$SCREEN" "kiro is working"; then
    echo working; return
  fi

  # --- tool_spinner_working (herdr priority 90): "esc to cancel" plus a spinner
  # glyph line (◔◑◕●) followed by a word.
  if lc_contains "$SCREEN" "esc to cancel"; then
    if any_line_matches "$SCREEN" '^\s*[◔◑◕●]\s+\p{Alphabetic}'; then
      echo working; return
    fi
  fi

  # --- idle: Kiro's composer placeholder (observed live this session). Not in the
  # herdr manifest (which only ships working/blocked rules and lets everything else
  # fall back to idle), but a positive idle signal avoids classifying a ready Kiro
  # as unknown.
  if lc_contains "$SCREEN" "ask a question or describe a task" \
     || lc_contains "$SCREEN" "/copy to clipboard"; then
    echo idle; return
  fi

  echo unknown
}
