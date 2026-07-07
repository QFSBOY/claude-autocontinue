# claude-autocontinue

**Hit your Claude Code rate limit, walk away, and have your session pick itself back up the moment your usage resets — even with the Mac asleep, locked, lid closed, on battery.**

Type `/autocontinue` in any Claude Code session. When your 5-hour usage window resets, autocontinue wakes your Mac (if needed), types **"continue where you left off"** into that exact session, presses Enter, holds the Mac awake while Claude works, then lets it go back to sleep.

100% on-device add-on: no AI involvement, no API calls to arm it (works *while* you're rate-limited), zero modifications to the Claude Code install — it survives every update.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/QFSBOY/claude-autocontinue/master/install.sh | bash
```

Then **restart Claude Code** (hooks load at startup).

Optional but recommended — let it wake a sleeping Mac at the exact reset time (one password prompt, tightly-scoped sudo rule):

```bash
bash ~/.claude/autocontinue/setup-wake.sh
```

## Use

| Command | Effect |
|---|---|
| `/autocontinue` | Arm this session — auto-continues at the next usage reset |
| `/autocontinue status` | Armed? Which sessions? Recent log |
| `/autocontinue off` | Disarm this session |
| `/autocontinue test 30` | Full end-to-end rehearsal, fires in 30s |

The command is intercepted **on your machine before it reaches the API** (a `UserPromptSubmit` hook that blocks the prompt), so it works even when Claude is fully rate-limited and can't respond. Each armed session gets its own independent watcher — arm as many concurrent sessions as you like; each gets exactly one continue message.

## How it works

1. **Arm** — a hook catches `/autocontinue` on-device, records the session's identity (session id, terminal tty, tmux pane, resolved `claude`/`tmux` paths), and detaches a watcher.
2. **Watch** — the watcher reads your real usage state from Anthropic's OAuth usage endpoint (Keychain token, no LLM guessing): current %, the 5-hour window reset time, *and weekly limits* — if a weekly limit is maxed, it fires at the weekly reset instead of uselessly typing into a blocked session.
3. **Wake** — a `launchd` calendar job plus (with setup-wake.sh) a `pmset` hardware RTC wake fire at the reset time. The RTC wake works lid-closed on battery.
4. **Deliver** — first path that works wins, exactly once (atomic claim):
   - **tmux `send-keys`** — injects at the pty layer; the *only* path that works through a locked screen
   - **GUI keystroke** — AppleScript into the exact Terminal.app tab or iTerm2 session that owns the armed tty (needs the screen unlocked + one-time Accessibility grant)
   - **headless `claude -p --resume`** — same session transcript continues in the background; reopen later with `claude --resume` (20-min watchdog)
5. **Hold** — keeps the Mac awake while the continued turn actually runs: `pmset disablesleep` (defeats clamshell sleep, which `caffeinate` can't) + `caffeinate -u` (full wake, no DarkWake throttling). Minimum 7 min, extends while Claude is visibly working (transcript writes or the TUI spinner), releases 3.5 min after it goes quiet, 25-min hard cap, always restores normal sleep (trap-protected, refcounted across concurrent sessions).

## Requirements

- macOS (uses launchd, pmset, osascript, Keychain)
- Claude Code ≥ 1.0.62 (UserPromptSubmit hooks) — installer checks and tells you to `claude update` if too old
- python3 (Xcode Command Line Tools — you almost certainly have it)
- Logged into Claude Code with a claude.ai subscription (usage/reset times come from the OAuth usage endpoint; API-key setups degrade to probe mode)
- **Recommended:** `tmux` (`brew install tmux`) and running claude inside it — locked-screen delivery only works via tmux

Works on Apple Silicon and Intel; finds your `claude` wherever it's installed (npm-global, Homebrew, `~/.local/bin`, nvm/volta) by resolving it at arm time in your real shell PATH.

## Honest limitations

- **Locked screen + no tmux** → GUI keystrokes are impossible at the macOS lock screen (OS security wall). Falls back to headless resume — work continues, you view it with `claude --resume`.
- **Sleeping Mac without setup-wake.sh** → launchd can't wake hardware; delivery happens on the next manual wake instead of on time.
- **The continue message fires at the reset even if you weren't blocked** — it's usage-reset-driven by design. Disarm with `/autocontinue off` if you don't want it.
- The GPU/display state after an RTC wake on battery is a DarkWake; `caffeinate -u` promotes it, but extremely long unattended turns on battery are less battle-tested than on AC power.

## Security notes

- The sudoers drop-in is scoped to exactly four `pmset` invocations (schedule wake / cancelall / disablesleep 1 / disablesleep 0) — nothing else, validated with `visudo -c`, removable with `sudo rm /etc/sudoers.d/claude-autocontinue-pmset`.
- Your OAuth token is read from your own Keychain at runtime and sent only to `api.anthropic.com` — the same endpoint Claude Code itself uses. It is never stored or logged.
- Keystrokes are only ever sent to the specific terminal tab/pane that owns the armed session's tty — never blind typing into the frontmost app.

## Uninstall

```bash
bash ~/.claude/autocontinue/uninstall.sh
```

Stops watchers, restores sleep settings, removes launchd jobs, the hook, all files, and (with your password) the sudoers rule.

## License

MIT
