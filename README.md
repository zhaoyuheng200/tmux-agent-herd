# tmux-agent-herd

A tmux plugin that gives you the one thing [Herdr](https://herdr.dev) adds over a
plain terminal multiplexer: **it watches every coding-agent pane and tells you
which agents are working, which are blocked waiting on you, and which are idle** --
then lets you jump straight to a blocked one.

It deliberately does NOT reimplement persistence, layout restore, detach-keep-running,
remote attach, or the notification transport -- tmux (plus `tmux-resurrect` /
`tmux-continuum` and OSC-9 passthrough) already do those. This plugin is only the
detect + display + notify + navigate layer.

## What it does

- **Status detection.** A background daemon polls each agent pane and classifies it
  `working` / `blocked` / `idle` (`unknown` when a signal is ambiguous). Detection
  rules are ported from Herdr's open-source detection manifests (see Attribution).
- **Status display.** A colored pill on each agent pane's border (`● blocked`,
  `◐ working`, `○ idle`) and an aggregate `!N *N .N` module on the status line.
- **Blocked notification.** When a pane transitions *into* `blocked`, one
  edge-triggered notification fires (tmux message and/or an OSC-9 desktop toast).
- **Navigator.** `prefix + g` opens an fzf popup of all agent panes grouped
  blocked > working > idle, with a live preview; Enter jumps to the pane.
  `prefix + G` jumps directly to the next blocked agent.
- **`herd` CLI.** `herd list | blocked | goto | nav | explain <target> | status`.

Supported agents out of the box: **Claude Code**, **Kiro CLI**, **Codex**
(the native-binary agents identifiable by process name). Node/bun-wrapped agents
(Gemini, Copilot, Cursor, OpenCode) need a process-tree walk and are not yet included.

## How detection works (the interesting part)

The daemon reads each pane's recent bottom buffer with `tmux capture-pane -p` and
the pane title with `#{pane_title}`, then applies per-agent rules in priority order
(highest wins), mirroring Herdr's screen-manifest engine:

- Claude Code and Codex encode state in the **OSC pane title**: a braille spinner
  glyph (`⠐ ⠂ ⠹` …) while working, `✳` while idle. That title is the highest-priority
  signal and is nearly free to read.
- **`working` requires motion.** A title spinner alone is not trusted -- the screen
  hash or an elapsed/token counter must have advanced since the previous poll.
  This defeats a *frozen* spinner left behind by a hung or killed agent (which would
  otherwise read "working" forever and mask a real block). See `lib/common.sh:screen_moved`.
- Because the moving-spinner check runs *before* the blocked check, a working agent
  whose output happens to contain an approval-looking string (common when you're
  building agent tooling) resolves to `working` and never trips a false `blocked`.
  A genuinely waiting agent has a static screen, so its stalled spinner is distrusted
  and it falls through to the strict blocked rules.
- **`blocked`** matches structural approval UI in a specific screen region -- e.g.
  Claude's `"do you want to proceed?"` with a `1. Yes` / `2. No` option line, or
  Kiro's `"requires approval"` with `"trust, always allow"`.

Run `scripts/test_detect.sh` for the fixture-based regression suite (real captures
plus synthetic blocked/frozen cases). `herd explain <target>` dumps the evidence
for one live pane.

## Install

### TPM

```tmux
set -g @plugin 'neilzhao/tmux-agent-herd'   # or a local path
run '~/.tmux/plugins/tpm/tpm'
```

### Manual (this repo lives at ~/code/tmux-agent-herd)

Add to `~/.config/tmux/tmux.conf` (anywhere after the plugin list, before the final
`tpm` run line is fine):

```tmux
run-shell '~/code/tmux-agent-herd/agent-herd.tmux'
```

Then `prefix + r` to reload. Add `~/code/tmux-agent-herd/bin` to `PATH` to use `herd`.

## Configuration (set before the run-shell line)

| Option | Default | Meaning |
|---|---|---|
| `@agent_herd_interval` | `2` | poll seconds |
| `@agent_notify` | `both` | `both` / `display-message` / `osc9` / `off` |
| `@agent_notify_kiro` | (off) | set `on` to enable Kiro blocked toasts (see Limitations) |
| `@agent_herd_key` | `g` | `prefix+<key>` opens the navigator |
| `@agent_herd_goto_key` | `G` | `prefix+<key>` jumps to the next blocked agent |

The pane-border pill is opt-in (keeps this plugin from fighting an existing
`pane-border-format`). To enable it, call `scripts/pane_pill.sh <target>` from your
`pane-border-format` -- see `INTEGRATION.md` for the exact snippet for a config that
already has a custom border format.

## Performance

One full scan of 12 agent panes measured ~0.64s wall on a dev desktop (dominated by
per-pane subprocess spawning), i.e. ~30% duty cycle at a 2s interval. Fine for a
handful-to-a-dozen agents on a workstation. If you run many more panes or want lower
overhead, the daemon is contract-compatible with a drop-in Rust rewrite (roadmap M7)
that does in-process matching and one control-mode connection instead of per-poll forks.

## Limitations

- **No timer hook in tmux**, so detection is sleep-polled, not push -- state can lag
  the interval. Truly event-driven waits need the Rust/control-mode work.
- **Screen-scraped `blocked` is inherently spoofable** by pane *content*. The
  moving-spinner-first ordering removes the common false positive, but the real fix
  is the lifecycle-hook path (roadmap M5: a Claude Code Stop/Notification hook writes
  authoritative state and disables scraping for that pane).
- **Kiro blocked strings** are ported from Herdr's manifest but were not captured live
  here, so Kiro blocked *notifications* are suppressed until you confirm them and set
  `@agent_notify_kiro on`. Detection still classifies Kiro; only the toast is gated.
- **Node/bun-wrapped agents** report `pane_current_command=node` and are not detected
  until process-tree identification lands.

## Roadmap

- **M5** lifecycle-hook authoritative path for Claude Code (spoof-proof, near-zero cost).
- **M6** `herd send` / `herd wait --until blocked|idle` orchestration verbs.
- **M7** Rust daemon (in-process manifest eval, event loop, much lower CPU).
- Broader agent coverage (Gemini, Copilot, Cursor, OpenCode) via process-tree walk.

## Attribution

Detection rules in `patterns/*.sh` are ported from the agent-detection TOML manifests
in [herdrdev/herdr](https://github.com/herdrdev/herdr) (`src/detect/manifests/`),
which is Apache-2.0 licensed. This plugin is an independent reimplementation of the
matching logic for tmux; it does not include Herdr's source. See `LICENSE`/`NOTICE`.
