#!/bin/bash
# claude-autocontinue watcher — detached by arm.sh (or relaunched by launchd at
# the usage-reset time). Waits until your Claude Code usage window resets, then
# sends "continue where you left off" + Enter into the armed session.
# Delivery cascade: tmux pane -> terminal keystroke (Terminal.app / iTerm2) ->
# headless `claude -p --resume`. Pure add-on: never touches the Claude Code
# install, survives updates.
#
# State file path comes from $AUTOCONTINUE_STATE (per-session). launchd
# relaunch passes AUTOCONTINUE_INSTANT=1 to skip the wait loop.

# launchd/cron/pmset spawn us with a bare PATH (/usr/bin:/bin). Cover Apple
# Silicon brew, Intel brew, and common user-level bin dirs; exact binary paths
# for claude/tmux are recorded in the state file at arm time (user's real PATH).
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.npm-global/bin:$HOME/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

DIR="$HOME/.claude/autocontinue"
STATE="${AUTOCONTINUE_STATE:-$DIR/state.json}"
PLIST_LABEL="${AUTOCONTINUE_PLIST_LABEL:-}"
PLIST_PATH="${AUTOCONTINUE_PLIST_PATH:-}"
LOG="$DIR/watch.log"
MSG="${AUTOCONTINUE_MSG:-continue where you left off}"
MAX_LIFETIME=$((36 * 3600))
START=$(date +%s)

PY=$(command -v python3 || echo /usr/bin/python3)

log() { echo "$(date '+%F %T') [watch] $*" >> "$LOG"; }

notify() {
  osascript -e "display notification \"$1\" with title \"autocontinue\"" >/dev/null 2>&1
  afplay /System/Library/Sounds/Ping.aiff >/dev/null 2>&1
}

jget() {
  "$PY" -c "import json;v=json.load(open('$STATE')).get('$1');print('' if v is None else v)" 2>/dev/null
}

[ -f "$STATE" ] || { log "no state file at $STATE — exiting"; exit 0; }

SESSION_ID=$(jget session_id)
PROJECT_DIR=$(jget project_dir)
TTY_PATH=$(jget tty)
TMUX_PANE=$(jget tmux_pane)
TEST_DELAY=$(jget test_delay)
CLAUDE_BIN=$(jget claude_bin); [ -x "$CLAUDE_BIN" ] || CLAUDE_BIN=$(command -v claude || true)
TMUX_BIN=$(jget tmux_bin);     [ -x "$TMUX_BIN" ]   || TMUX_BIN=$(command -v tmux || true)

# Keep the Mac awake for as long as we live (backup to launchd/pmset — those
# can wake a sleeping Mac; caffeinate can only prevent sleep).
caffeinate -is -w $$ &

cleanup() {
  rm -f "$STATE.fired"
  # If $STATE exists again, a NEWER watcher re-armed this session while we were
  # delivering/holding — the plist/launchd job belongs to it now.
  if [ -f "$STATE" ]; then
    log "newer watcher owns this session now — leaving its state/launchd untouched"
    return 0
  fi
  rm -f "$STATE"
  if [ -n "$PLIST_LABEL" ]; then
    launchctl bootout "gui/$(id -u)/$PLIST_LABEL" >/dev/null 2>&1
    rm -f "$PLIST_PATH"
  fi
}

# ---------------------------------------------------------------------------
# Phase A — learn the usage/limit state and fire time
# ---------------------------------------------------------------------------

usage_json() {
  local cred token
  cred=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null) || return 1
  token=$(printf '%s' "$cred" | "$PY" -c "import sys,json;print(json.load(sys.stdin)['claudeAiOauth']['accessToken'])" 2>/dev/null)
  [ -n "$token" ] || return 1
  curl -sf --max-time 20 "https://api.anthropic.com/api/oauth/usage" \
    -H "Authorization: Bearer $token" -H "anthropic-beta: oauth-2025-04-20"
}

# Prints "<blocked 0|1> <fire_epoch>". blocked=1 when ANY limit (session or
# weekly) is at >=100% — the fire time is then the LATEST blocking reset
# (typing into a weekly-blocked session gets eaten). When nothing blocks,
# fire at the 5h window reset (usage-reset-driven).
fire_state() {
  usage_json | "$PY" -c '
import sys, json, datetime
def ep(r):
    try: return int(datetime.datetime.fromisoformat(r).timestamp())
    except Exception: return 0
d = json.load(sys.stdin)
blocking = [ep(l.get("resets_at")) for l in d.get("limits") or []
            if (l.get("percent") or 0) >= 100
            or str(l.get("severity")) in ("exceeded", "limited", "blocked")]
fh = d.get("five_hour") or {}
if blocking:
    print(1, max(blocking))
else:
    print(0, ep(fh.get("resets_at") or ""))
'
}

probe_ok() { [ -n "$CLAUDE_BIN" ] && (cd /tmp && "$CLAUDE_BIN" -p "ok" --model haiku >/dev/null 2>&1); }

chunked_sleep() {
  local s=$1 c
  while [ "$s" -gt 0 ]; do
    c=$((s > 300 ? 300 : s)); sleep "$c"; s=$((s - c))
    # State vanished mid-wait => another watcher delivered and cleaned up, or
    # the user disarmed. Exit instead of thawing hours later as a zombie.
    if [ ! -f "$STATE" ] && [ ! -f "$STATE.fired" ]; then
      log "state gone mid-wait — delivered elsewhere or disarmed; exiting"
      exit 0
    fi
  done
}

# Persist reset_epoch and install the wake path for a sleeping Mac:
# launchd StartCalendarInterval relaunches us at the fire minute (runs on the
# next wake if the Mac slept through it), and pmset schedules a hardware RTC
# wake (needs the scoped sudoers rule from setup-wake.sh; silently skipped
# without it).
schedule_backup() {
  local ep=$1
  [ -n "$PLIST_LABEL" ] || return 0
  [ "$ep" -gt "$(date +%s)" ] || return 0
  "$PY" - "$STATE" "$ep" <<'PYEOF'
import json,sys
p,ep=sys.argv[1],int(sys.argv[2])
d=json.load(open(p)); d["reset_epoch"]=ep; open(p,"w").write(json.dumps(d,indent=2))
PYEOF
  local fire=$((ep + 30))
  local MIN HOUR DAY MON
  MIN=$(date -r "$fire" +%M); HOUR=$(date -r "$fire" +%H)
  DAY=$(date -r "$fire" +%d); MON=$(date -r "$fire" +%m)
  cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$PLIST_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string><string>$DIR/watch.sh</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.npm-global/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>AUTOCONTINUE_STATE</key><string>$STATE</string>
    <key>AUTOCONTINUE_PLIST_LABEL</key><string>$PLIST_LABEL</string>
    <key>AUTOCONTINUE_PLIST_PATH</key><string>$PLIST_PATH</string>
    <key>AUTOCONTINUE_INSTANT</key><string>1</string>
  </dict>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Minute</key><integer>$((10#$MIN))</integer>
    <key>Hour</key><integer>$((10#$HOUR))</integer>
    <key>Day</key><integer>$((10#$DAY))</integer>
    <key>Month</key><integer>$((10#$MON))</integer>
  </dict>
  <key>RunAtLoad</key><false/>
</dict></plist>
PLIST
  launchctl bootout "gui/$(id -u)/$PLIST_LABEL" >/dev/null 2>&1
  launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH" >/dev/null 2>&1 \
    && log "launchd backup scheduled for $(date -r "$fire" '+%F %T')" \
    || log "launchd bootstrap failed (backup unavailable) — live watcher still active"
  local wake=$((fire - 15))
  sudo -n /usr/bin/pmset schedule wake "$(date -r "$wake" '+%m/%d/%y %H:%M:%S')" >/dev/null 2>&1 \
    && log "pmset hardware wake armed for $(date -r "$wake" '+%F %T')" \
    || log "pmset wake NOT armed (no passwordless sudoers — run setup-wake.sh). A sleeping Mac fires on its next wake instead."
}

# ---------------------------------------------------------------------------
# Keeping the Mac awake for the continued turn
# ---------------------------------------------------------------------------
# `pmset disablesleep 1` defeats clamshell (lid-closed) sleep, which caffeinate
# cannot; `caffeinate -u` promotes a battery DarkWake into a full wake so the
# turn is not throttled. Both degrade gracefully without the sudoers rule.
HOLDDIR="$DIR/holds"
KEEPAWAKE_ON=0

keepawake_on() {
  mkdir -p "$HOLDDIR"
  : > "$HOLDDIR/$$"
  KEEPAWAKE_ON=1
  trap 'keepawake_off' EXIT INT TERM
  sudo -n /usr/bin/pmset -a disablesleep 1 >/dev/null 2>&1 \
    && log "clamshell sleep DISABLED — Mac stays awake lid-closed on battery" \
    || log "could not disable clamshell sleep (no sudoers rule) — battery+lid-closed may re-sleep mid-turn"
  caffeinate -u -t "$((${AUTOCONTINUE_MAXHOLD:-1500} + 60))" >/dev/null 2>&1 &
}

keepawake_off() {
  [ "$KEEPAWAKE_ON" = "1" ] || return 0
  KEEPAWAKE_ON=0
  rm -f "$HOLDDIR/$$"
  if [ -z "$(ls -A "$HOLDDIR" 2>/dev/null)" ]; then
    sudo -n /usr/bin/pmset -a disablesleep 0 >/dev/null 2>&1 \
      && log "clamshell sleep restored to normal"
  fi
}

transcript_path() {
  local mangled
  mangled=$(printf '%s' "${PROJECT_DIR:-$HOME}" | sed 's/[^a-zA-Z0-9]/-/g')
  echo "$HOME/.claude/projects/$mangled/$SESSION_ID.jsonl"
}

# Claude's TUI shows an elapsed-time + token footer like "(3m 43s · ↓ 11.1k
# tokens)" ONLY while a turn is processing. Match "(<time> · <arrow>" — the
# spinner verb (Drizzling/Cooking/…) rotates randomly, and plain chat text or
# statusline token widgets lack this shape.
pane_busy() {
  [ -n "$TMUX_PANE" ] && [ -n "$TMUX_BIN" ] || return 1
  "$TMUX_BIN" capture-pane -t "$TMUX_PANE" -p 2>/dev/null \
    | grep -qE '\([0-9]+m? ?[0-9]*s · [↑↓]'
}

# Hold rules: ALWAYS >= MINHOLD (7 min floor); then keep holding while active
# (transcript mtime advancing OR TUI spinner visible); release after IDLE
# (3.5 min) of quiet; hard cap MAXHOLD (25 min).
hold_awake() {
  local tp minhold maxhold idle start now last_act mt elapsed
  tp=$(transcript_path)
  minhold=${AUTOCONTINUE_MINHOLD:-420}
  maxhold=${AUTOCONTINUE_MAXHOLD:-1500}
  idle=${AUTOCONTINUE_IDLE:-210}
  start=$(date +%s); last_act=$start
  keepawake_on
  log "holding Mac awake: floor ${minhold}s, then while active, cap ${maxhold}s"
  sleep 15
  while :; do
    now=$(date +%s); elapsed=$((now - start))
    [ "$elapsed" -ge "$maxhold" ] && { log "hit ${maxhold}s cap — releasing"; break; }
    [ -f "$tp" ] && { mt=$(stat -f %m "$tp" 2>/dev/null || echo "$now"); [ "$mt" -gt "$last_act" ] && last_act=$mt; }
    pane_busy && last_act=$now
    if [ "$elapsed" -ge "$minhold" ] && [ $((now - last_act)) -ge "$idle" ]; then
      log "past ${minhold}s floor and idle ${idle}s — releasing"; break
    fi
    sleep 20
  done
  keepawake_off
}

# ---------------------------------------------------------------------------
# Phase B — deliver the message
# ---------------------------------------------------------------------------

screen_locked() {
  "$PY" -c '
import sys
try:
    import Quartz
    d = Quartz.CGSessionCopyCurrentDictionary()
    sys.exit(0 if (d and d.get("CGSSessionScreenIsLocked", 0)) else 1)
except Exception:
    sys.exit(1)'
}

session_alive_on_tty() {
  [ -n "$TTY_PATH" ] || return 1
  ps -t "${TTY_PATH#/dev/tty}" -o comm= 2>/dev/null | grep -q .
}

deliver_tmux() {
  [ -n "$TMUX_PANE" ] && [ -n "$TMUX_BIN" ] || return 1
  "$TMUX_BIN" list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qx "$TMUX_PANE" || return 1
  "$TMUX_BIN" send-keys -t "$TMUX_PANE" "$MSG" && sleep 1 && "$TMUX_BIN" send-keys -t "$TMUX_PANE" Enter
}

# GUI keystroke into whichever terminal app owns the recorded tty. Supports
# Terminal.app and iTerm2. Requires the screen to be UNLOCKED (macOS drops
# synthetic keys at the lock screen — that is an OS wall; tmux is the only
# locked-screen path) and a one-time Accessibility grant.
deliver_keystroke() {
  [ -n "$TTY_PATH" ] || return 1
  session_alive_on_tty || return 1
  screen_locked && { log "screen is locked — skipping keystroke path"; return 1; }
  if pgrep -xq Terminal; then
    osascript - "$TTY_PATH" "$MSG" <<'APPLESCRIPT' && return 0
on run argv
  set ttyPath to item 1 of argv
  set theMsg to item 2 of argv
  tell application "Terminal"
    set found to false
    repeat with w in windows
      repeat with t in tabs of w
        if tty of t is ttyPath then
          set selected of t to true
          set index of w to 1
          set found to true
          exit repeat
        end if
      end repeat
      if found then exit repeat
    end repeat
    if not found then error "tab not found for " & ttyPath
    activate
  end tell
  delay 1
  tell application "System Events"
    keystroke theMsg
    delay 0.5
    key code 36
  end tell
end run
APPLESCRIPT
  fi
  if pgrep -xq iTerm2; then
    osascript - "$TTY_PATH" "$MSG" <<'APPLESCRIPT' && return 0
on run argv
  set ttyPath to item 1 of argv
  set theMsg to item 2 of argv
  tell application "iTerm2"
    set found to false
    repeat with w in windows
      repeat with t in tabs of w
        repeat with s in sessions of t
          if tty of s is ttyPath then
            select w
            select t
            select s
            set found to true
            exit repeat
          end if
        end repeat
        if found then exit repeat
      end repeat
      if found then exit repeat
    end repeat
    if not found then error "session not found for " & ttyPath
    activate
  end tell
  delay 1
  tell application "System Events"
    keystroke theMsg
    delay 0.5
    key code 36
  end tell
end run
APPLESCRIPT
  fi
  return 1
}

deliver_headless() {
  [ -n "$SESSION_ID" ] && [ -n "$CLAUDE_BIN" ] || return 1
  log "headless resume of session $SESSION_ID (watchdog: 20 min)"
  (cd "${PROJECT_DIR:-$HOME}" && "$CLAUDE_BIN" -p --resume "$SESSION_ID" "$MSG" >> "$LOG" 2>&1) &
  local hp=$! waited=0
  while kill -0 "$hp" 2>/dev/null; do
    [ "$waited" -ge 1200 ] && { kill "$hp" 2>/dev/null; log "headless watchdog: killed after ${waited}s"; return 1; }
    sleep 15; waited=$((waited + 15))
  done
  wait "$hp"
}

deliver() {
  # Atomic claim: the primary (reset+90s) and the launchd instant (reset+30s)
  # can both be alive — exactly one may deliver. Losers exit outright.
  if ! mv "$STATE" "$STATE.fired" 2>/dev/null; then
    log "delivery already claimed by another watcher — standing down"
    exit 0
  fi
  if deliver_tmux; then
    log "DELIVERED via tmux pane $TMUX_PANE"; notify "Limit reset — continued via tmux"
  elif deliver_keystroke; then
    log "DELIVERED via terminal keystroke into $TTY_PATH"; notify "Limit reset — typed into your session"
  elif deliver_headless; then
    log "DELIVERED via headless resume — reopen with: claude --resume $SESSION_ID"
    notify "Limit reset — continued headlessly (claude --resume to view)"
  else
    log "FAILED: all delivery paths failed"; notify "Limit reset, but autocontinue could not deliver — see watch.log"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# Test hook: `AUTOCONTINUE_SOURCE_ONLY=1 source watch.sh` loads functions only.
[ -n "$AUTOCONTINUE_SOURCE_ONLY" ] && return 0 2>/dev/null

is_num() { [[ "$1" =~ ^[0-9]+$ ]]; }

# Instant-respawn handoff: give the launchd job a moment to exit before the
# respawned primary touches its plist.
[ -n "$AUTOCONTINUE_DELAY" ] && sleep "$AUTOCONTINUE_DELAY"

log "watcher started (pid $$) session=$SESSION_ID tty=$TTY_PATH tmux=$TMUX_PANE test=$TEST_DELAY instant=${AUTOCONTINUE_INSTANT:-0}"

# launchd relaunched us at (or near) the fire time. Verify nothing STILL blocks
# (a weekly limit can outlive the 5h reset); if blocked, respawn a primary to
# rewait rather than typing into a blocked session.
if [ "${AUTOCONTINUE_INSTANT:-0}" = "1" ]; then
  blocked=""; out=$(fire_state) && blocked=${out%% *}
  if [ "$blocked" = "1" ]; then
    log "instant: fired but something still blocks (weekly limit?) — respawning primary to rewait"
    AUTOCONTINUE_DELAY=10 AUTOCONTINUE_STATE="$STATE" \
      AUTOCONTINUE_PLIST_LABEL="$PLIST_LABEL" AUTOCONTINUE_PLIST_PATH="$PLIST_PATH" \
      nohup /bin/bash "$DIR/watch.sh" >/dev/null 2>&1 &
    disown 2>/dev/null
    exit 0
  fi
  deliver; hold_awake; cleanup; log "watcher done (instant)"; exit 0
fi

if [ -n "$TEST_DELAY" ]; then
  log "TEST MODE: firing in ${TEST_DELAY}s"
  chunked_sleep "$TEST_DELAY"
else
  # USAGE-RESET-DRIVEN, weekly-aware: fire when you can actually use Claude
  # again — the 5h window reset normally, or the latest blocking limit's reset
  # when something is at 100%. Wake/launchd are scheduled immediately.
  while :; do
    [ $(( $(date +%s) - START )) -gt "$MAX_LIFETIME" ] && { log "expired 36h"; notify "autocontinue expired (36h)"; cleanup; exit 0; }
    blocked=""; reset_ep=""
    out=$(fire_state) && { blocked=${out%% *}; reset_ep=${out##* }; }
    if is_num "$reset_ep" && [ "$reset_ep" -gt 0 ]; then
      schedule_backup "$reset_ep"
      now=$(date +%s); wait_s=$((reset_ep - now + 90))
      if [ "$wait_s" -gt 0 ]; then
        [ "$blocked" = "1" ] && why="blocking limit clears" || why="usage window resets"
        log "will deliver when $why at $(date -r "$reset_ep" '+%F %T') (in ${wait_s}s)"
        chunked_sleep "$wait_s"
      fi
      out2=$(fire_state) && [ "${out2%% *}" = "1" ] && { log "still blocked after wait — rescheduling"; sleep 60; continue; }
      break
    else
      if probe_ok; then
        [ "${seen_limited:-0}" = "1" ] && { log "probe ok after being blocked — delivering"; break; }
        log "no reset time available; probe ok — recheck in 600s"; sleep 600
      else
        [ "${seen_limited:-0}" = "0" ] && log "no reset time available; probe failed — assuming blocked"
        seen_limited=1; sleep 600
      fi
    fi
  done
fi

deliver
hold_awake
cleanup
log "watcher done"
