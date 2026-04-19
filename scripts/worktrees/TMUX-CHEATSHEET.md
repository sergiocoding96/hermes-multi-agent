# tmux — 5-minute cheatsheet

tmux lets one SSH session hold many shells, and those shells survive if your SSH drops. Exactly what you need when running multiple Claude Code sessions on tower from a laptop / phone / whatever.

## The one-time setup

```bash
# SSH in
ssh openclaw@tower.taila4a33f.ts.net

# First time: create a named session
tmux new -s hermes

# Any other time: reattach
tmux attach -t hermes

# List sessions
tmux ls

# Detach (leaves everything running)
# Press: Ctrl-b  then  d
```

**Ctrl-b is the "prefix"** — every tmux command starts with it. Press and release Ctrl-b, then press the next key.

## Windows (= tabs, one per worktree)

| Keys | What |
|------|------|
| `Ctrl-b c` | Create new window |
| `Ctrl-b n` | Next window |
| `Ctrl-b p` | Previous window |
| `Ctrl-b 0` … `Ctrl-b 9` | Jump to window N |
| `Ctrl-b ,` | Rename current window |
| `Ctrl-b w` | List all windows (pick from menu) |
| `Ctrl-b &` | Kill current window (confirms) |

**Typical flow:** one tmux window per worktree. Rename each with `Ctrl-b ,` so it shows up as `memos-auth-perf` instead of `bash`. Then `Ctrl-b w` gives you a clean list to jump between.

## Panes (split a window, e.g. shell + log tail)

| Keys | What |
|------|------|
| `Ctrl-b %` | Split vertically (left / right) |
| `Ctrl-b "` | Split horizontally (top / bottom) |
| `Ctrl-b ←/→/↑/↓` | Move between panes |
| `Ctrl-b x` | Kill current pane |
| `Ctrl-b z` | Zoom current pane to full window (press again to unzoom) |

**Useful pattern:** split a worktree's window: left pane runs Claude, right pane tails MemOS logs or runs curl tests.

## Scrollback (read output that scrolled off)

| Keys | What |
|------|------|
| `Ctrl-b [` | Enter scroll mode |
| `PgUp / PgDown` or arrows | Scroll |
| `q` | Leave scroll mode |

## Copy / paste (tmux's own copy mode)

```
Ctrl-b [         enter scroll mode
Space            start selection
arrows / PgUp    extend selection
Enter            copy to tmux buffer
Ctrl-b ]         paste
```

If you just want system clipboard, use your terminal emulator's selection (drag with mouse) — tmux doesn't interfere with that in most terminals.

## Daily workflow on tower

```bash
# Morning: reattach
ssh openclaw@tower.taila4a33f.ts.net
tmux attach -t hermes     # everything is right where you left it

# Ctrl-b w to see all windows
# Jump to the one you want

# End of day: detach (DO NOT exit)
# Press: Ctrl-b  then  d
# Then close the ssh session — everything keeps running

# If a Claude session finished overnight, its window shows a shell prompt.
# If it's still working, you'll see Claude's output live.
```

## Starting a Claude session for one worktree

```bash
# New window for this task:
# Ctrl-b c

# Name it so you can find it:
# Ctrl-b ,   (type name, Enter)

# Move into the worktree and launch Claude:
cd ~/Coding/MemOS-wt/fix-auth-perf
claude
```

Claude picks up `TASK.md` automatically as part of its context (it's in the working directory).

## Gotchas

- **If you SSH in from a new terminal and run `tmux` (no args) it creates a NEW session.** You probably want `tmux attach -t hermes` instead, or `tmux ls` first to see what's running.
- **Mouse wheel scrolling may not work by default.** If you want it, add to `~/.tmux.conf`:
  ```
  set -g mouse on
  ```
  Then `tmux source-file ~/.tmux.conf`.
- **Never nest tmux sessions.** If you're already in tmux and type `tmux attach`, you'll get a nested mess. Detach first.

## Alternatives

- **zellij** — prettier, modal, shows all shortcuts in a footer. Good if tmux feels arcane. `cargo install zellij` or `brew install zellij`.
- **screen** — older, simpler, almost everywhere. Different shortcuts (`Ctrl-a` prefix). Fine if tmux isn't available.

For this project, tmux is the safe default — preinstalled everywhere, stable, no surprises.
