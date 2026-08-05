#!/usr/bin/env bash
# agent-herd.tmux -- TPM entry point for tmux-agent-herd.
# Installs config defaults, key bindings, the status-left summary module, and
# launches the background detection daemon (idempotent, so re-sourcing on
# `prefix r` or tpm reload does not spawn a second copy).
set -uo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

set_default() {
  local opt="$1" val="$2"
  [ -z "$(tmux show-option -gqv "$opt" 2>/dev/null)" ] && tmux set-option -gq "$opt" "$val"
}

# --- config defaults (override any of these in tmux.conf BEFORE the run line) ---
set_default @agent_herd_interval "2"           # poll seconds
set_default @agent_notify "both"               # both|display-message|osc9|off
set_default @agent_herd_key "g"                # prefix+<key> -> navigator popup
set_default @agent_herd_goto_key "G"           # prefix+<key> -> jump to next blocked

NAV_KEY="$(tmux show-option -gqv @agent_herd_key)"
GOTO_KEY="$(tmux show-option -gqv @agent_herd_goto_key)"

# --- key bindings (mirror the user's existing `bind f` popup idiom) ---
tmux bind-key "$NAV_KEY"  display-popup -E -w 80% -h 80% "$CURRENT_DIR/scripts/navigator.sh"
tmux bind-key "$GOTO_KEY" run-shell "$CURRENT_DIR/bin/herd goto"

# --- status-left summary module (append; do NOT clobber the full status-right) ---
# Only append once, even across reloads.
if ! tmux show-option -gv status-left 2>/dev/null | grep -q '@agent_summary'; then
  tmux set-option -ga status-left " #[align=left]#{E:@agent_summary}"
fi

# --- launch the daemon detached; flock inside guarantees a single instance ---
tmux run-shell -b "$CURRENT_DIR/scripts/daemon.sh"
