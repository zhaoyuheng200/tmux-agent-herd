#!/usr/bin/env bash
# notify.sh <target> <agent> <title> -- notify that a pane just became blocked.
#
# Delivery mode from @agent_notify (default "both"):
#   display-message : tmux status-line message (always visible, in-terminal)
#   osc9            : OSC 9 desktop notification written to each attached client's
#                     tty -- reaches WezTerm/Mac. NOTE: this is written to the
#                     client tty directly, NOT echoed from here through tmux
#                     allow-passthrough (passthrough only forwards sequences
#                     emitted by a process running *inside* a pane; this daemon
#                     has no in-pane tty, so passthrough would never deliver).
#   both            : both of the above
#   off             : nothing
set -uo pipefail

target="${1:-}"; agent="${2:-}"; title="${3:-}"
[ -n "$target" ] || exit 0

mode="$(tmux show-option -gqv @agent_notify 2>/dev/null)"; mode="${mode:-both}"
[ "$mode" = off ] && exit 0

# Suppress notifications for agents whose blocked UI is not yet verified live.
# (kiro strings are ported from herdr's manifest; enable once confirmed on your
# installed version by setting @agent_notify_kiro on.)
if [ "$agent" = kiro ] && [ "$(tmux show-option -gqv @agent_notify_kiro 2>/dev/null)" != on ]; then
  exit 0
fi

msg="agent blocked: $target  ${title:-$agent}"

if [ "$mode" = display-message ] || [ "$mode" = both ]; then
  tmux display-message "#[fg=#ed8796,bold] $msg" 2>/dev/null || true
fi

if [ "$mode" = osc9 ] || [ "$mode" = both ]; then
  # OSC 9 ; <text> BEL -- desktop notification. Write to every attached client tty.
  local_seq="$(printf '\033]9;%s\a' "$msg")"
  while IFS= read -r tty; do
    [ -n "$tty" ] && [ -w "$tty" ] && printf '%s' "$local_seq" > "$tty" 2>/dev/null || true
  done < <(tmux list-clients -F '#{client_tty}' 2>/dev/null)
fi
exit 0
