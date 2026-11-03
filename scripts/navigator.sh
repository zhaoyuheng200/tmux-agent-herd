#!/usr/bin/env bash
# navigator.sh -- fzf picker over agent panes, most recently active first.
# Intended to run inside `display-popup -E` (like the user's existing `bind f`).
# Enter jumps to the chosen pane via switch-client/select-window/select-pane.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"

socket="$(tmux display-message -p '#{socket_path}' 2>/dev/null || echo default)"
sockkey="$(printf '%s' "$socket" | cksum | cut -d' ' -f1)"
STATE_JSON="${TMUX_TMPDIR:-/tmp}/agent-herd/$sockkey/state.json"
[ -f "$STATE_JSON" ] || { echo "no agent state yet (daemon not running?)"; sleep 1; exit 0; }

# Columns: icon state target age title.
icon() { case "$1" in blocked) echo "●" ;; working) echo "◐" ;; idle) echo "○" ;; *) echo "◌" ;; esac; }

# Rows sort most recently active first.
# A Claude pane's time is the timestamp of the newest user or assistant entry in its session transcript.
# The transcript's mtime is not used: Claude also appends untimestamped bookkeeping entries (cost-state, last-prompt)
# to idle sessions, which moves the mtime with no prompt or reply.
# Claude registers each live process in sessions/<pid>.json, whose "tmux" field ends in the pane ID (session:@window.%pane).
# Other agents, and Claude panes without a live registry file, fall back to window_activity, the window's last output time.
claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
LAST_MESSAGE_TS='[inputs | fromjson? | select(.type == "user" or .type == "assistant") | .timestamp // empty
  | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601] | max // empty'
declare -A last_message_by_pane=()
for reg in "$claude_dir"/sessions/*.json; do
  pid="$(basename "$reg" .json)"
  kill -0 "$pid" 2>/dev/null || continue
  # One jq call per file: a file caught mid-rewrite fails alone instead of aborting a multi-file read.
  IFS=$'\t' read -r pane sid < <(jq -r 'select(.tmux and .sessionId) | [(.tmux | sub(".*\\."; "")), .sessionId] | @tsv' "$reg" 2>/dev/null) || continue
  for transcript in "$claude_dir"/projects/*/"$sid".jsonl; do
    [ -f "$transcript" ] || continue
    # The tail almost always holds the newest message; scan the whole file only when it does not.
    ts="$(tail -n 200 "$transcript" | jq -nR "$LAST_MESSAGE_TS" 2>/dev/null)"
    [ -n "$ts" ] || ts="$(jq -nR "$LAST_MESSAGE_TS" "$transcript" 2>/dev/null)"
    [ -n "$ts" ] || continue
    [ "$ts" -gt "${last_message_by_pane[$pane]:-0}" ] && last_message_by_pane[$pane]="$ts"
  done
done

declare -A ts_by_target=()
while IFS=$'\t' read -r target pane activity; do
  ts_by_target[$target]="${last_message_by_pane[$pane]:-$activity}"
done < <(tmux list-panes -a -F $'#{session_name}:#{window_index}.#{pane_index}\t#{pane_id}\t#{window_activity}' 2>/dev/null)

now="$(date +%s)"
age() {
  local s=$(( now - $1 ))
  if   [ "$1" -eq 0 ];     then echo "-"
  elif [ "$s" -lt 60 ];    then echo "${s}s"
  elif [ "$s" -lt 3600 ];  then echo "$(( s / 60 ))m"
  elif [ "$s" -lt 86400 ]; then echo "$(( s / 3600 ))h"
  else                          echo "$(( s / 86400 ))d"
  fi
}

rows="$(jq -r '.panes[] | [.state,.target,.title] | @tsv' "$STATE_JSON" 2>/dev/null \
  | while IFS=$'\t' read -r state target title; do
      ts="${ts_by_target[$target]:-0}"
      printf '%s\t%s %-8s %-24s %4s  %s\n' "$ts" "$(icon "$state")" "$state" "$target" "$(age "$ts")" "$title"
    done | sort -s -t$'\t' -k1,1nr | cut -f2-)"

[ -n "$rows" ] || { echo "no agent panes detected"; sleep 1; exit 0; }

sel="$(printf '%s\n' "$rows" | fzf --ansi --reverse --no-sort \
        --header='agents (most recently active first) -- enter to jump' \
        --preview 'tmux capture-pane -p -t $(echo {} | awk "{print \$3}") -S -25' \
        --preview-window=right,60%,wrap 2>/dev/null || true)"
[ -n "$sel" ] || exit 0

target="$(awk '{print $3}' <<<"$sel")"
[ -n "$target" ] || exit 0
win="${target%.*}"
tmux switch-client -t "$win" 2>/dev/null || tmux select-window -t "$win" 2>/dev/null || true
tmux select-window -t "$win" 2>/dev/null || true
tmux select-pane -t "$target" 2>/dev/null || true
