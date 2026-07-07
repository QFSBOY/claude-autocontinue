#!/bin/bash
# claude-autocontinue installer.
#   curl -fsSL https://raw.githubusercontent.com/QFSBOY/claude-autocontinue/master/install.sh | bash
# or from a cloned repo:  bash install.sh [--with-wake]
#
# Idempotent: safe to re-run (upgrades in place). Never touches the Claude
# Code install itself — user-level files only, survives Claude updates.

set -e

REPO_RAW="https://raw.githubusercontent.com/QFSBOY/claude-autocontinue/master"
CLAUDE_DIR="$HOME/.claude"
DEST="$CLAUDE_DIR/autocontinue"
CMDS="$CLAUDE_DIR/commands"
SETTINGS="$CLAUDE_DIR/settings.json"
HOOK_CMD="bash ~/.claude/autocontinue/intercept.sh"

say()  { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf 'WARN:  %s\n' "$*"; }

say "== claude-autocontinue installer =="
say ""

# ---------------------------------------------------------------------------
# Preflight doctor — verify this Mac + Claude Code setup can run autocontinue
# ---------------------------------------------------------------------------
say "-- preflight checks --"

[ "$(uname -s)" = "Darwin" ] || fail "macOS only (uses launchd, pmset, osascript, Keychain)."

[ -d "$CLAUDE_DIR" ] || fail "~/.claude not found — install and run Claude Code first (https://claude.com/claude-code)."

# python3: macOS provides it once Command Line Tools are installed; Claude Code
# users overwhelmingly have it, but check.
PY=$(command -v python3 || true)
[ -n "$PY" ] || fail "python3 not found. Install Xcode Command Line Tools: xcode-select --install"
say "python3:      $PY"

# claude binary — wherever this Mac has it (npm-global, brew, ~/.local, nvm...)
CLAUDE_BIN=$(command -v claude || true)
if [ -z "$CLAUDE_BIN" ]; then
  for c in "$HOME/.local/bin/claude" "/opt/homebrew/bin/claude" "/usr/local/bin/claude" "$HOME/.npm-global/bin/claude"; do
    [ -x "$c" ] && CLAUDE_BIN="$c" && break
  done
fi
[ -n "$CLAUDE_BIN" ] || fail "claude CLI not found in PATH or common locations."
say "claude:       $CLAUDE_BIN"

# Version check: UserPromptSubmit hooks are the core mechanism. They exist in
# Claude Code >= 1.0.62 (hooks GA); warn (don't block) if we can't parse.
CC_VER=$("$CLAUDE_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
if [ -n "$CC_VER" ]; then
  MAJ=${CC_VER%%.*}; REST=${CC_VER#*.}; MIN=${REST%%.*}
  if [ "$MAJ" -lt 1 ] || { [ "$MAJ" -eq 1 ] && [ "$MIN" -lt 1 ] && [ "${CC_VER}" != "1.0.62" ] && [ "${REST}" \< "0.62" ]; }; then
    warn "Claude Code $CC_VER may predate UserPromptSubmit hooks (need >= 1.0.62). Run: claude update"
  else
    say "claude code:  v$CC_VER (hooks supported)"
  fi
else
  warn "could not detect Claude Code version — if /autocontinue is not intercepted, run: claude update"
fi

# Keychain credentials (how the watcher reads your usage/reset times)
if security find-generic-password -s "Claude Code-credentials" -w >/dev/null 2>&1; then
  say "credentials:  Keychain OK"
else
  warn "no 'Claude Code-credentials' in Keychain (are you logged in via claude.ai subscription?). API-key users: usage polling degrades to probe mode."
fi

# tmux (optional but STRONGLY recommended: the only delivery path that works
# through a locked screen)
TMUX_BIN=$(command -v tmux || true)
if [ -n "$TMUX_BIN" ]; then
  say "tmux:         $TMUX_BIN (locked-screen delivery available)"
else
  warn "tmux not found — without it, delivery needs an UNLOCKED screen (or falls back to headless resume). Install: brew install tmux"
fi

say ""

# ---------------------------------------------------------------------------
# Install files
# ---------------------------------------------------------------------------
say "-- installing files --"
mkdir -p "$DEST" "$CMDS"

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
fetch() {  # fetch <relpath> <dest> — from local repo if present, else GitHub
  if [ -f "$SRC_DIR/$1" ]; then
    cp "$SRC_DIR/$1" "$2"
  else
    curl -fsSL "$REPO_RAW/$1" -o "$2" || fail "could not fetch $1"
  fi
}

for f in watch.sh arm.sh intercept.sh setup-wake.sh; do
  fetch "bin/$f" "$DEST/$f"
  chmod +x "$DEST/$f"
  say "installed $DEST/$f"
done
fetch "uninstall.sh" "$DEST/uninstall.sh"; chmod +x "$DEST/uninstall.sh"
fetch "commands/autocontinue.md" "$CMDS/autocontinue.md"
say "installed $CMDS/autocontinue.md (fallback slash command)"

# ---------------------------------------------------------------------------
# Wire the UserPromptSubmit hook into settings.json (safe JSON merge)
# ---------------------------------------------------------------------------
say ""
say "-- wiring UserPromptSubmit hook --"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.autocontinue-backup"
"$PY" - "$SETTINGS" "$HOOK_CMD" <<'PYEOF'
import json, sys
path, hook_cmd = sys.argv[1], sys.argv[2]
d = json.load(open(path))
hooks = d.setdefault("hooks", {})
ups = hooks.setdefault("UserPromptSubmit", [])
for entry in ups:
    for h in entry.get("hooks", []):
        if "autocontinue/intercept.sh" in h.get("command", ""):
            print("hook already present — leaving settings.json unchanged")
            sys.exit(0)
ups.append({"matcher": "", "hooks": [{"type": "command", "command": hook_cmd}]})
open(path, "w").write(json.dumps(d, indent=2) + "\n")
print("hook added to settings.json (backup: settings.json.autocontinue-backup)")
PYEOF

# ---------------------------------------------------------------------------
# Optional: sleep-defeating powers (sudo, interactive)
# ---------------------------------------------------------------------------
say ""
if [ "$1" = "--with-wake" ] || [ "${AUTOCONTINUE_WITH_WAKE:-}" = "1" ]; then
  bash "$DEST/setup-wake.sh"
else
  say "-- optional: wake-from-sleep powers --"
  say "To let autocontinue WAKE a sleeping Mac at the reset time and hold it"
  say "awake lid-closed on battery, run once (asks for your password):"
  say "    bash ~/.claude/autocontinue/setup-wake.sh"
  say "Without it everything still works while the Mac is awake; a sleeping"
  say "Mac delivers on its next wake instead of exactly on time."
fi

say ""
say "== installed =="
say "1. RESTART Claude Code (hooks load at startup)."
say "2. In any session, type: /autocontinue          (arm this session)"
say "   Also: /autocontinue status | off | test 30"
say "3. First GUI-keystroke delivery may prompt for Accessibility permission"
say "   (System Settings > Privacy & Security > Accessibility) — grant it once."
say "4. Best resilience: run claude inside tmux (delivery works even locked)."
say ""
say "Uninstall anytime: bash ~/.claude/autocontinue/uninstall.sh"
