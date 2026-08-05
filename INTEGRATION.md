# Integration with your tmux config

Tailored to `~/.config/tmux/tmux.conf` (prefix `C-a`, catppuccin-macchiato, full
status-right, a custom `pane_border_format.sh`, `bind f` fzf popup, resurrect/continuum).

Everything below is **opt-in and additive**. The plugin's entry script only sets
`@`-options, binds `prefix+g`/`prefix+G`, appends one segment to `status-left`, and
launches the daemon -- it never touches your `status-right`, window-status, or
`pane-border-format`.

## 1. Enable the plugin

Add one line to `tmux.conf` (after the plugin list; before the final `tpm` run line):

```tmux
run-shell '~/code/tmux-agent-herd/agent-herd.tmux'
```

`prefix + r` to reload. That gets you: the status-left summary, `prefix+g` navigator,
`prefix+G` jump-to-blocked, notifications, and the daemon. No keybind collisions --
`g`/`G` are unbound in your config (taken: `r x C e f a` and pain-control `h j k l`).

## 2. (Optional) Pane-border state pill

Your `pane-border-format` calls `pane_border_format.sh` per-pane. Because that format
is evaluated in a pane context, `#{@agent_state}` expands to *that pane's* daemon-set
state -- so you can pass it in as a 5th argument with zero extra cost (no capture-pane).

In `tmux.conf`, change the `pane-border-format` line to pass the state:

```tmux
set -g pane-border-format "#(~/.config/tmux/pane_border_format.sh #{pane_active} #{pane_current_command} #{pane_current_path} '#{pane_title}' '#{@agent_state}')"
```

Then in `~/.config/tmux/pane_border_format.sh`, add near the top (after `title="$4"`):

```bash
agent_state="$5"
pill=""
if [ -n "$agent_state" ] && [ "$agent_state" != none ]; then
  case "$agent_state" in
    blocked) pc=$(tmux show-option -gqv @thm_red);   pi="●" ;;
    working) pc=$(tmux show-option -gqv @thm_peach); pi="◐" ;;
    idle)    pc=$(tmux show-option -gqv @thm_green); pi="○" ;;
    *)       pc=$(tmux show-option -gqv @thm_overlay_0); pi="◌" ;;
  esac
  pill="#[fg=${pc}]${pi} #[default]"
fi
```

and prepend `${pill}` inside the final label, e.g.:

```bash
echo "#[fg=${bg},bg=default]${LEFT}#[fg=${fg},bg=${bg}] ${pill}${label}  ${formatted_path} #[fg=${bg},bg=default]${RIGHT}"
```

This is safe on reload: catppuccin's `@catppuccin_pane_border_status` is off, so it
never regenerates `pane-border-format` and your pill survives `prefix + r`.

## 3. Notifications over the existing OSC-9 pipe

Your `allow-passthrough on` forwards OSC-9 from processes *inside* a pane. The daemon
runs outside any pane, so it can't use passthrough; instead `notify.sh` writes the
OSC-9 sequence directly to each attached client's tty (`#{client_tty}`), which still
reaches WezTerm. Verify delivery once on your Mac-over-SSH setup:

```bash
# with the daemon running, drive a Claude pane into a permission prompt, then:
herd blocked      # should list it
# and you should get a WezTerm toast + a tmux status message.
```

If the OSC-9 toast does not appear over SSH, set `@agent_notify display-message`
(tmux status message only) -- always works.

## 4. Coexistence with resurrect / continuum

No action needed. Detection state lives in ephemeral per-pane `@agent_state` options
and a state.json under `$TMUX_TMPDIR`; resurrect/continuum don't persist arbitrary
`@`-options, so on restore the daemon simply re-detects within one poll. Don't add
agent state to the resurrect save format.

## Uninstall / disable

Remove the `run-shell '.../agent-herd.tmux'` line and `prefix + r`. Kill a running
daemon with `pkill -f tmux-agent-herd/scripts/daemon.sh`. Undo section 2 by reverting
`pane_border_format.sh` and the `pane-border-format` line.
