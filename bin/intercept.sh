#!/bin/bash
# claude-autocontinue UserPromptSubmit interceptor.
#
# /autocontinue must NOT go through the model: a slash-command .md is sent to
# the API as a prompt, so it dies exactly when you need it (rate-limited).
# This hook fires on the raw typed text, on-device, BEFORE the prompt is sent.
# If the prompt is an autocontinue command we run arm.sh directly and EXIT 2,
# which blocks + erases the prompt (output shown to the user via stderr).
# Works even when fully rate-limited.
#
# For any other prompt: exit 0 with NO stdout (stdout on UserPromptSubmit is
# injected as model context — stay silent).

DIR="$HOME/.claude/autocontinue"
PY=$(command -v python3 || echo /usr/bin/python3)

PAYLOAD=$(cat 2>/dev/null)

LINE=$(printf '%s' "$PAYLOAD" | "$PY" -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
p = d.get("prompt") or d.get("user_prompt") or d.get("text") or ""
p = " ".join(str(p).split())
print(p + "|||" + (d.get("cwd") or "") + "|||" + (d.get("session_id") or ""))
' 2>/dev/null)
PROMPT=${LINE%%|||*}
REST=${LINE#*|||}
CWD=${REST%%|||*}
SID=${REST##*|||}

shopt -s extglob
TRIMMED="${PROMPT##+([[:space:]])}"
case "$TRIMMED" in
  /autocontinue|/autocontinue\ *) : ;;
  *) exit 0 ;;   # not our command — pass through untouched
esac

ARGS="${TRIMMED#/autocontinue}"
ARGS="${ARGS##+([[:space:]])}"

[ -n "$CWD" ] && cd "$CWD" 2>/dev/null

OUT=$(AUTOCONTINUE_SID="$SID" bash "$DIR/arm.sh" $ARGS 2>&1)

printf '%s\n' "$OUT" >&2
exit 2
