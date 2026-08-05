#!/usr/bin/env bash
# navigator.sh -- fzf picker over agent panes, grouped by state (blocked first).
# Intended to run inside `display-popup -E` (like the user's existing `bind f`).
# Enter jumps to the chosen pane via switch-client/select-window/select-pane.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"

socket="$(tmux display-message -p '#{socket_path}' 2>/dev/null || echo default)"
sockkey="$(printf '%s' "$socket" | cksum | cut -d' ' -f1)"
STATE_JSON="${TMUX_TMPDIR:-/tmp}/agent-herd/$sockkey/state.json"
[ -f "$STATE_JSON" ] || { echo "no agent state yet (daemon not running?)"; sleep 1; exit 0; }

# Sort order blocked>working>idle>other; columns: icon state target title.
rank() { case "$1" in blocked) echo 0 ;; working) echo 1 ;; idle) echo 2 ;; *) echo 3 ;; esac; }
icon() { case "$1" in blocked) echo "●" ;; working) echo "◐" ;; idle) echo "○" ;; *) echo "◌" ;; esac; }

rows="$(jq -r '.panes[] | [.state,.target,.title] | @tsv' "$STATE_JSON" 2>/dev/null \
  | while IFS=$'\t' read -r state target title; do
      printf '%s\t%s %-8s %-24s %s\n' "$(rank "$state")" "$(icon "$state")" "$state" "$target" "$title"
    done | sort -n | cut -f2-)"

[ -n "$rows" ] || { echo "no agent panes detected"; sleep 1; exit 0; }

sel="$(printf '%s\n' "$rows" | fzf --ansi --reverse --no-sort \
        --header='agents (blocked > working > idle) -- enter to jump' \
        --preview 'tmux capture-pane -p -t $(echo {} | awk "{print \$3}") -S -25' \
        --preview-window=right,60%,wrap 2>/dev/null || true)"
[ -n "$sel" ] || exit 0

target="$(awk '{print $3}' <<<"$sel")"
[ -n "$target" ] || exit 0
win="${target%.*}"
tmux switch-client -t "$win" 2>/dev/null || tmux select-window -t "$win" 2>/dev/null || true
tmux select-window -t "$win" 2>/dev/null || true
tmux select-pane -t "$target" 2>/dev/null || true
