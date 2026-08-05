# tmux-agent-herd -- architecture and usage

## Mental model

tmux already hosts your agents and keeps them alive. What it does NOT know is
*what each agent is doing*. This plugin adds exactly one thing: a background
process that looks at every agent pane a few times a second, decides whether the
agent is `working`, `blocked`, or `idle`, and writes that verdict somewhere cheap
to read. Everything else -- the status-line badge, the border pill, the navigator,
the `herd` CLI, the notifications -- are just thin readers of that verdict.

So there are two halves:

- ONE writer: `daemon.sh`, the poller. It is the only thing that runs
  `capture-pane` and the only thing that decides state.
- MANY readers: the status line, border, navigator, and CLI. They never scrape a
  pane; they read a tmux option or a small JSON file. This keeps the redraw path
  and your keystrokes fast no matter how many panes you have.

The split matters because tmux redraws its status line constantly (per client, per
resize, per `status-interval`). If detection ran in the redraw path it would fork
`capture-pane` for every pane on every redraw. Instead the daemon does the work on
its own clock and the redraw path just reads a string.

## Architecture diagram

```
                            YOUR TMUX SERVER (one per socket)
        +--------------------------------------------------------------------+
        |  sessions / windows / panes                                        |
        |                                                                    |
        |   chat:2.1  [claude]  <- agent panes (foreground cmd = claude /    |
        |   cdk:1.1   [claude]     kiro-cli / codex); title carries an OSC   |
        |   doc:1.2   [kiro-cli]   spinner glyph while working, star = idle  |
        |   ...                                                               |
        +--------------------------------------------------------------------+
             ^                                              |
             | (1) tmux list-panes -a                       | (2) capture-pane -p
             |     #{pane_current_command} #{pane_title}     |     + #{pane_title}
             |                                              v
        +--------------------------------------------------------------------+
        |  daemon.sh    (single flock-guarded loop, every @agent_herd_interval)|
        |                                                                    |
        |   discover agent panes  --------------------------+                |
        |   for each pane:                                  |                |
        |     detect.sh --meta  ->  "state|hash|counter"    |                |
        |        |  sources patterns/<agent>.sh             |                |
        |        |  + lib/common.sh (regions, screen_moved)  |                |
        |     carry prev hash+counter in memory (motion)    |                |
        |     rising edge into blocked? -> notify.sh        |                |
        +----|-----------------------|----------------------|---------------+
             | (3a) set -p            | (3b) set -g          | (3c) write
             |     @agent_state       |     @agent_summary   |     state.json (atomic)
             v                        v                      v
     per-pane option           global option         $TMUX_TMPDIR/agent-herd/
     (border pill reads)       (status-left reads)   <sockhash>/state.json
             |                        |                      |
             |                        |                      | (4) jq
             v                        v                      v
     +--------------+       +-----------------+     +------------------------+
     | pane border  |       | status-left     |     | herd CLI  &  navigator |
     | pane_pill.sh |       | #{E:@agent_     |     | list/blocked/goto/nav  |
     | (optional)   |       |    summary}     |     | fzf popup -> switch-   |
     +--------------+       +-----------------+     | client                 |
                                                    +------------------------+

     notify.sh (on blocked edge):
        tmux display-message        -> status-line toast (always works)
        OSC 9 -> each #{client_tty} -> WezTerm/Mac desktop notification
        (NOT via allow-passthrough: that is pane-scoped; the daemon has no pane tty)
```

## The four numbered flows

1. DISCOVER -- one `tmux list-panes -a -F '...'` per poll returns every pane with
   its `pane_current_command` and `pane_title`. The daemon keeps only panes whose
   command is a known agent (`claude`, `kiro-cli`, `codex`). This process-name gate
   is why a pane titled `star Claude Code` but running `zsh` (Claude already exited)
   is correctly ignored.

2. CLASSIFY -- for each agent pane, `detect.sh --meta` runs `capture-pane -p` on the
   bottom ~40 lines plus reads the title, then applies that agent's rules and prints
   `state|screen_hash|counter` from a single capture. The daemon remembers the hash
   and counter so the next poll can prove the screen moved (see Detection below).

3. PUBLISH -- the verdict is written three ways, each for a different reader:
   - `set -p -t <pane> @agent_state <state>` -- a per-pane option the border reads.
   - `set -g @agent_summary '<colored counts>'` -- a global option the status line reads.
   - `state.json` written atomically (tmp file + `mv`) -- the CLI and navigator read it.
   Then `refresh-client -S` nudges tmux to repaint so the badge updates promptly.

4. READ -- nothing in this layer scrapes a pane. The border pill reads one option,
   the status line interpolates one option, and `herd`/navigator run `jq` over the
   JSON. All cheap and safe to call on every redraw or keypress.

## Detection: how state is decided (the interesting part)

Input per pane: the bottom-of-buffer text (`capture-pane -p`) and the pane title.
Rules are applied in priority order, ported from herdr's TOML manifests
(`src/detect/manifests/*.toml`, Apache-2.0). Highest-priority match wins.

For Claude Code the order is:

1. WORKING -- the title starts with a braille spinner glyph (U+2800..U+28FF) AND
   the screen actually moved since the last poll. "Moved" = the screen hash changed,
   or an elapsed/token counter (e.g. `Context: 14%`, `Midway: 16h 45m`, `30.2k tokens`)
   advanced. On the very first poll we trust the glyph (no prior to compare).
2. BLOCKED -- a structural approval form below the last horizontal rule: e.g.
   `do you want to proceed?` plus a `1. Yes` / `2. No` option line, or `esc to cancel`
   plus `enter to confirm`.
3. IDLE -- the ready input box (`>` prompt) with no menu/selection hints, or the
   star glyph in the title.
4. UNKNOWN -- a spinner glyph is present but the screen is frozen (hung/killed agent)
   and nothing else matched. Deliberately not called `working`.

Why WORKING is checked before BLOCKED (the key design choice): an agent that is
actively streaming has a MOVING screen, so it resolves to `working` and never reaches
the blocked rules -- even if its output happens to contain the literal text
`do you want to proceed?` (common when you are building agent tooling and your agent
prints such strings as content). A genuinely waiting agent has a STATIC screen, so its
stalled spinner is distrusted, it falls through, and the blocked rules run on it. This
single ordering removes the most dangerous false positive (a false "blocked" page).

The motion guard (`lib/common.sh:screen_moved`) is also what defeats a frozen spinner:
`capture-pane` returns the last painted frame, so a killed agent would show a spinner
forever. Requiring motion means a spinner that has not changed for a full poll is
demoted to `unknown`, not reported as `working`.

Kiro CLI has no title glyph, so it is detected purely from screen content
(`kiro is working`, `requires approval` + `trust, always allow`, its composer
placeholder). Codex uses a different spinner glyph set and an `Action Required` title.

## Where state lives

| Artifact | Scope | Written by | Read by |
|---|---|---|---|
| `@agent_state` | per pane (`set -p`) | daemon | pane border pill |
| `@agent_summary` | global (`set -g`) | daemon | status-left |
| `state.json` | file, per tmux socket | daemon | `herd`, navigator |
| in-memory prev hash/counter | daemon process only | daemon | daemon (motion check) |

All of it is ephemeral. On a tmux server restart the options and JSON are gone; the
daemon relaunches (from the `run-shell` line) and re-detects everything within one
poll. Nothing here is persisted by resurrect/continuum, which is correct -- detection
state is a live view, not saved state.

## Lifecycle and safety

- The daemon holds an exclusive `flock` on a per-socket lock file for its whole life,
  so re-sourcing the config (`prefix r`) or a tpm reload cannot spawn a second copy --
  the second launch loses the lock race and exits immediately.
- Each iteration checks `tmux has-session`; when the server goes away the daemon exits,
  so there are no orphan loops.
- The runtime directory is keyed on the tmux socket path (`#{socket_path}` hashed),
  so multiple tmux servers do not collide.
