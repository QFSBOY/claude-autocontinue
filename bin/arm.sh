#!/bin/bash
# claude-autocontinue backend. Usage: arm.sh [arm | off | status | test <seconds> | hook]
#
# Per-session: every armed session gets its own state file, watcher, and
# launchd backup job, keyed by session id — arming session A never touches
# session B's watcher.

DIR="$HOME/.claude/autocontinue"
LOG="$DIR/watch.log"
ENABLED_FLAG="$DIR/enabled"
mkdir -p "$DIR"

PY=$(command -v python3 || echo /usr/bin/python3)

cmd=${1:-arm}
# bare number ("/autocontinue 40") => shorthand for test mode
[[ "$cmd" =~ ^[0-9]+$ ]] && { set -- test "$cmd"; cmd="test"; }

# --- identify this session ---------------------------------------------------
# Session id = newest transcript in this project's dir (the live session is the
# most recently written jsonl). The UserPromptSubmit hook passes the exact id
# via AUTOCONTINUE_SID — trust that when present (no guessing).
PROJ_DIR="$HOME/.claude/projects/$(printf '%s' "$PWD" | sed 's/[^a-zA-Z0-9]/-/g')"
SID_FILE=$(ls -t "$PROJ_DIR"/*.jsonl 2>/dev/null | head -1)
SESSION_ID=""
[ -n "$SID_FILE" ] && SESSION_ID=$(basename "$SID_FILE" .jsonl)
[ -n "$AUTOCONTINUE_SID" ] && SESSION_ID="$AUTOCONTINUE_SID"
SESSION_TAG=${SESSION_ID:0:8}
[ -z "$SESSION_TAG" ] && SESSION_TAG="nosession-$$"

STATE="$DIR/state-$SESSION_TAG.json"
PLIST_LABEL="com.claude-autocontinue.$SESSION_TAG"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"

watcher_pid() {
  [ -f "$STATE" ] || return 1
  "$PY" -c "import json;print(json.load(open('$STATE')).get('watcher_pid',''))" 2>/dev/null
}

unload_launchd() {
  launchctl bootout "gui/$(id -u)/$PLIST_LABEL" >/dev/null 2>&1
  rm -f "$PLIST_PATH"
}

kill_watcher() {
  local pid fired_pid
  pid=$(watcher_pid)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null
    echo "killed watcher pid $pid (session $SESSION_TAG)"
  fi
  # A just-fired watcher may still be in its post-delivery hold, tracked by the
  # claimed .fired file — kill it too (its EXIT trap restores clamshell sleep).
  if [ -f "$STATE.fired" ]; then
    fired_pid=$("$PY" -c "import json;print(json.load(open('$STATE.fired')).get('watcher_pid',''))" 2>/dev/null)
    [ -n "$fired_pid" ] && kill -0 "$fired_pid" 2>/dev/null && kill "$fired_pid" 2>/dev/null
    rm -f "$STATE.fired"
  fi
  unload_launchd
  rm -f "$STATE"
}

case "$cmd" in
  off)
    kill_watcher
    rm -f "$ENABLED_FLAG"
    echo "autocontinue: disarmed for this session."
    exit 0
    ;;
  status)
    echo "session: ${SESSION_ID:-unknown}"
    if [ -f "$STATE" ]; then
      pid=$(watcher_pid)
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        echo "ARMED (watcher pid $pid alive)"
      else
        echo "STALE state file (watcher not running)"
      fi
      cat "$STATE"
    else
      echo "NOT ARMED"
    fi
    other=$(ls "$DIR"/state-*.json 2>/dev/null | grep -v "state-$SESSION_TAG.json")
    [ -n "$other" ] && { echo "--- other armed sessions ---"; for f in $other; do basename "$f"; done; }
    echo "--- last log lines ---"
    tail -8 "$LOG" 2>/dev/null || echo "(no log yet)"
    exit 0
    ;;
  test)
    TEST_DELAY=${2:-60}
    ;;
  arm)
    TEST_DELAY=""
    ;;
  hook)
    HOOK_MODE=1
    TEST_DELAY=""
    ;;
  *)
    echo "usage: arm.sh [arm|off|status|test <seconds>]"; exit 1
    ;;
esac

# tty of the hosting terminal = first ancestor process with a real tty (this
# script runs inside Claude's Bash tool / hook subprocess, whose own tty is
# "??"). lsof on the transcript as a second opinion.
pid=$$; TTY_PATH=""
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  tt=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
  if [ -n "$tt" ] && [ "$tt" != "??" ]; then TTY_PATH="/dev/$tt"; break; fi
  pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  [ -z "$pid" ] || [ "$pid" -le 1 ] && break
done
if [ -z "$TTY_PATH" ] && [ -n "$SID_FILE" ]; then
  tt=$(lsof -Fn "$SID_FILE" 2>/dev/null | grep -m1 '^n/dev/ttys' | cut -c2-)
  [ -n "$tt" ] && TTY_PATH="$tt"
fi

# Resolve binaries NOW, in the user's real PATH — launchd's bare environment
# can't find nvm/volta/npm-global installs later.
CLAUDE_BIN=$(command -v claude || true)
TMUX_BIN=$(command -v tmux || true)

# --- (re)arm this session's watcher ------------------------------------------

kill_watcher >/dev/null

"$PY" - "$SESSION_ID" "$PWD" "$TTY_PATH" "${TMUX_PANE:-}" "$TEST_DELAY" "$STATE" "$CLAUDE_BIN" "$TMUX_BIN" <<'PYEOF'
import json, sys, time
sid, cwd, tty, tmux_pane, test, state_path, claude_bin, tmux_bin = sys.argv[1:9]
state = {
    "session_id": sid, "project_dir": cwd, "tty": tty,
    "tmux_pane": tmux_pane, "test_delay": test or None,
    "claude_bin": claude_bin or None, "tmux_bin": tmux_bin or None,
    "armed_at": time.strftime("%F %T"),
}
open(state_path, "w").write(json.dumps(state, indent=2))
PYEOF

AUTOCONTINUE_STATE="$STATE" AUTOCONTINUE_PLIST_LABEL="$PLIST_LABEL" AUTOCONTINUE_PLIST_PATH="$PLIST_PATH" \
  nohup /bin/bash "$DIR/watch.sh" >/dev/null 2>&1 &
WPID=$!
disown "$WPID" 2>/dev/null

"$PY" - "$WPID" "$STATE" <<'PYEOF'
import json, sys
wpid, path = sys.argv[1], sys.argv[2]
d = json.load(open(path)); d["watcher_pid"] = int(wpid)
open(path, "w").write(json.dumps(d, indent=2))
PYEOF

touch "$ENABLED_FLAG"

echo "$(date '+%F %T') [arm] session=$SESSION_TAG pid=$WPID tty=$TTY_PATH tmux=${TMUX_PANE:-} test=${TEST_DELAY:-no} hook=${HOOK_MODE:-0}" >> "$LOG"

if [ -z "$HOOK_MODE" ]; then
  MODE_NOTE=""
  [ -n "$TEST_DELAY" ] && MODE_NOTE=" [TEST: fires in ${TEST_DELAY}s]"
  POWER_NOTE=""
  pmset -g batt 2>/dev/null | head -1 | grep -q "AC Power" || POWER_NOTE=" (On battery — hardware wake needs the setup-wake.sh sudoers rule; without it a sleeping Mac fires on its next wake.)"

  USAGE_NOTE=""
  CRED=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
  TOKEN=$(printf '%s' "$CRED" | "$PY" -c "import sys,json;print(json.load(sys.stdin)['claudeAiOauth']['accessToken'])" 2>/dev/null)
  if [ -n "$TOKEN" ]; then
    USAGE_NOTE=$(curl -sf --max-time 8 "https://api.anthropic.com/api/oauth/usage" \
      -H "Authorization: Bearer $TOKEN" -H "anthropic-beta: oauth-2025-04-20" \
      | "$PY" -c '
import sys, json, datetime
def local(r):
    try: return datetime.datetime.fromisoformat(r).astimezone().strftime("%-I:%M%p %a").lower()
    except Exception: return None
try:
    d = json.load(sys.stdin)
    fh = d.get("five_hour") or {}
    pct = int(fh.get("utilization") or 0)
    blocking = [(l.get("kind"), l.get("resets_at")) for l in d.get("limits") or []
                if (l.get("percent") or 0) >= 100]
    if blocking:
        kind, r = max(blocking, key=lambda b: b[1] or "")
        print(f" Usage now {pct}%, but {kind} limit is at 100% — will fire when it clears at {local(r) or (chr(39)+chr(63)+chr(39))}.")
    else:
        when = local(fh.get("resets_at"))
        if when: print(f" Usage now {pct}%, 5h window resets {when}.")
        else:    print(f" Usage now {pct}%, fresh window (no reset time yet — watcher will pick it up).")
except Exception:
    pass' 2>/dev/null)
  fi

  echo "ok — armed.${MODE_NOTE}${USAGE_NOTE} Watcher PID $WPID will send \"continue where you left off\" when the limit resets. Session ${SESSION_TAG}, tty ${TTY_PATH:-unknown}, tmux ${TMUX_PANE:-none}.${POWER_NOTE}"
fi
