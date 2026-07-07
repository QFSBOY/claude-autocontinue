# Changelog

All notable changes to this project are documented here.
Format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.0.0] — 2026-07-07

Initial public release.

### Added
- `UserPromptSubmit` hook interception for `/autocontinue` — fully on-device,
  works even while rate-limited (no API call to arm).
- Usage-reset-driven watcher: fires when the 5-hour usage window resets,
  weekly-limit-aware (waits for the weekly reset if a weekly limit is at 100%
  rather than firing uselessly into a still-blocked session).
- Delivery cascade with atomic single-delivery claim: tmux `send-keys` (works
  through a locked screen) → AppleScript keystroke (Terminal.app and iTerm2)
  → headless `claude -p --resume` fallback, with a 20-minute watchdog.
- `launchd` calendar-job backup + `pmset` hardware RTC wake so delivery
  survives the Mac being fully asleep, lid-closed, on battery.
- Adaptive post-delivery keep-awake hold: `pmset disablesleep` (defeats
  clamshell sleep) + `caffeinate -u` (avoids DarkWake throttling), with a
  7-minute floor, activity-based extension (transcript writes or the live TUI
  spinner), and a 25-minute hard cap — always restored via an EXIT trap.
- Per-session watchers, state files, and launchd jobs — concurrent sessions
  never interfere with each other.
- Installer with a preflight doctor (macOS, Claude Code version, python3,
  `claude` binary location across install methods, Keychain login, tmux) and
  an idempotent, backup-preserving `settings.json` merge.
- Full uninstaller reversing every change, including power state and the
  optional sudoers rule.

### Known limitations
See [README § Honest limitations](README.md#honest-limitations).
