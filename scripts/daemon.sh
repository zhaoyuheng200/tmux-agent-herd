#!/usr/bin/env bash
# daemon.sh -- single long-lived poller for tmux-agent-herd.
#
# Every AGENT_HERD_INTERVAL seconds it: discovers agent panes, classifies each
# (carrying the prior poll's screen-hash + counter so the detector can prove
# motion), publishes state into tmux user-options and an atomic state.json, and
# fires an edge-triggered notification when a pane transitions into "blocked".
#
# It is flock-guarded (one instance per tmux socket) and exits when the tmux
# server goes away, so `bind r` / tpm re-sourcing can relaunch it idempotently.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
DETECT="$ROOT/scripts/detect.sh"
NOTIFY="$ROOT/scripts/notify.sh"

get_opt() { tmux show-option -gqv "$1" 2>/dev/null; }
INTERVAL="$(get_opt @agent_herd_interval)"; INTERVAL="${INTERVAL:-2}"
KNOWN_CMDS="claude claude-code kiro kiro-cli codex"

# Per-tmux-socket runtime dir (multi-server safe). tmux exposes the socket path
# via #{socket_path}; fall back to a fixed name if unavailable.
socket="$(tmux display-message -p '#{socket_path}' 2>/dev/null || echo default)"
sockkey="$(printf '%s' "$socket" | cksum | cut -d' ' -f1)"
RUN_DIR="${TMUX_TMPDIR:-/tmp}/agent-herd/$sockkey"
mkdir -p "$RUN_DIR"
STATE_JSON="$RUN_DIR/state.json"
LOCK="$RUN_DIR/daemon.lock"

# Single-instance guard: hold an exclusive lock on our own fd for our lifetime.
exec 9>"$LOCK"
if ! flock -n 9; then exit 0; fi

is_known() { case " $KNOWN_CMDS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
agent_of() {
  case "$1" in
    claude|claude-code) echo claude ;;
    kiro|kiro-cli) echo kiro ;;
    codex) echo codex ;;
    *) echo "" ;;
  esac
}

# In-memory maps keyed by pane target -> prior hash / counter / state.
declare -A PREV_HASH PREV_COUNTER PREV_STATE

PREV_SUMMARY=""

cleanup() { tmux set-option -gq @agent_summary "" 2>/dev/null || true; }
trap cleanup EXIT

while :; do
  tmux has-session 2>/dev/null || break   # server gone -> die (no orphan)

  # One discovery call: target|cmd|pane_pid|title  for every pane.
  mapfile -t panes < <(tmux list-panes -a -F \
    '#{session_name}:#{window_index}.#{pane_index}|#{pane_current_command}|#{pane_title}' 2>/dev/null)

  declare -A seen=()
  n_blocked=0 n_working=0 n_idle=0
  json_entries=()

  for line in "${panes[@]}"; do
    IFS='|' read -r target cmd title <<<"$line"
    is_known "$cmd" || continue
    agent="$(agent_of "$cmd")"
    [ -n "$agent" ] || continue
    seen[$target]=1

    ph="${PREV_HASH[$target]:-}"
    pc="${PREV_COUNTER[$target]:-}"

    # Classify in one capture. --meta prints "state|cur_hash|counter"; we carry
    # the hash+counter into the next poll so the detector can prove motion.
    meta="$("$DETECT" --target "$target" --title "$title" \
              --prev-hash "$ph" --prev-counter "$pc" --meta 2>/dev/null || echo 'unknown||')"
    state="${meta%%|*}"; rest="${meta#*|}"
    cur_hash="${rest%%|*}"; cur_counter="${rest#*|}"
    [ -n "$state" ] || state=unknown

    PREV_HASH[$target]="$cur_hash"
    PREV_COUNTER[$target]="$cur_counter"

    # Edge-triggered notify: fire once when a pane ENTERS blocked.
    if [ "$state" = blocked ] && [ "${PREV_STATE[$target]:-}" != blocked ]; then
      "$NOTIFY" "$target" "$agent" "$title" 2>/dev/null || true
    fi

    # Publish per-pane option only when state changed; unconditional set-option
    # triggers a pane-border redraw (pane_border_format.sh fork) every poll cycle
    # for every agent pane, causing visible flashing.
    if [ "$state" != "${PREV_STATE[$target]:-}" ]; then
      tmux set-option -pq -t "$target" @agent_state "$state" 2>/dev/null || true
    fi
    PREV_STATE[$target]="$state"

    case "$state" in
      blocked) n_blocked=$((n_blocked+1)) ;;
      working) n_working=$((n_working+1)) ;;
      idle)    n_idle=$((n_idle+1)) ;;
    esac

    esc_title="${title//\\/\\\\}"; esc_title="${esc_title//\"/\\\"}"
    json_entries+=("{\"target\":\"$target\",\"agent\":\"$agent\",\"state\":\"$state\",\"title\":\"$esc_title\"}")
  done

  # Drop options for panes that disappeared this poll.
  for t in "${!PREV_STATE[@]}"; do
    if [ -z "${seen[$t]:-}" ]; then
      unset 'PREV_STATE[$t]' 'PREV_HASH[$t]' 'PREV_COUNTER[$t]'
      tmux set-option -puq -t "$t" @agent_state 2>/dev/null || true
    fi
  done

  # Aggregate summary option for the status line (only shows non-zero groups).
  summary=""
  [ "$n_blocked" -gt 0 ] && summary="${summary}#[fg=#ed8796]!$n_blocked "
  [ "$n_working" -gt 0 ] && summary="${summary}#[fg=#f5a97f]*$n_working "
  [ "$n_idle"    -gt 0 ] && summary="${summary}#[fg=#a6da95].$n_idle "
  new_summary="${summary% }"
  tmux set-option -gq @agent_summary "$new_summary" 2>/dev/null || true

  # Atomic state.json for the CLI + navigator.
  {
    printf '{"updated":%s,"panes":[' "$(date +%s 2>/dev/null || echo 0)"
    IFS=,; printf '%s' "${json_entries[*]:-}"; unset IFS
    printf ']}\n'
  } > "$STATE_JSON.tmp" && mv -f "$STATE_JSON.tmp" "$STATE_JSON"

  # Only force a status-line redraw when the summary actually changed;
  # unconditional refresh-client every poll cycle causes visible flashing.
  if [ "$new_summary" != "$PREV_SUMMARY" ]; then
    tmux refresh-client -S 2>/dev/null || true
  fi
  PREV_SUMMARY="$new_summary"

  sleep "$INTERVAL"
done
