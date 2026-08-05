#!/usr/bin/env bash
# pane_pill.sh <target> -- print a short colored state pill for a pane's border.
# CHEAP: reads only the cached @agent_state option (set by the daemon). It must
# NEVER call capture-pane -- it runs per-pane on every status redraw.
# Prints nothing for non-agent panes so the border stays clean.
set -uo pipefail
target="${1:-}"
[ -n "$target" ] || exit 0

state="$(tmux show-option -pqv -t "$target" @agent_state 2>/dev/null)"
[ -n "$state" ] && [ "$state" != none ] || exit 0

# Reuse the resolved catppuccin palette so it matches the theme + auto light/dark.
c() { tmux show-option -gqv "$1" 2>/dev/null; }
case "$state" in
  blocked) col="$(c @thm_red)";   icon="●" ;;
  working) col="$(c @thm_peach)"; icon="◐" ;;
  idle)    col="$(c @thm_green)"; icon="○" ;;
  *)       col="$(c @thm_overlay_0)"; icon="◌" ;;
esac
[ -n "$col" ] || col="default"
printf '#[fg=%s]%s %s#[default]' "$col" "$icon" "$state"
