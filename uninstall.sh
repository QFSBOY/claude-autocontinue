#!/bin/bash
# claude-autocontinue uninstaller — reverses everything install.sh (and
# setup-wake.sh) did. Safe to run repeatedly.

CLAUDE_DIR="$HOME/.claude"
DEST="$CLAUDE_DIR/autocontinue"
SETTINGS="$CLAUDE_DIR/settings.json"
PY=$(command -v python3 || echo /usr/bin/python3)

echo "== claude-autocontinue uninstaller =="

# 1. stop all watchers
pkill -f "autocontinue/watch.sh" 2>/dev/null && echo "stopped running watchers" || echo "no watchers running"

# 2. restore power state + cancel scheduled wakes (needs the sudoers rule; ok if absent)
sudo -n /usr/bin/pmset -a disablesleep 0 >/dev/null 2>&1
sudo -n /usr/bin/pmset schedule cancelall >/dev/null 2>&1

# 3. remove launchd jobs + plists
for plist in "$HOME/Library/LaunchAgents"/com.claude-autocontinue.*.plist "$HOME/Library/LaunchAgents"/com.echo.autocontinue.*.plist; do
  [ -f "$plist" ] || continue
  label=$(basename "$plist" .plist)
  launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1
  rm -f "$plist"
  echo "removed launchd job $label"
done

# 4. remove the hook from settings.json
if [ -f "$SETTINGS" ]; then
  "$PY" - "$SETTINGS" <<'PYEOF'
import json, sys
path = sys.argv[1]
d = json.load(open(path))
ups = (d.get("hooks") or {}).get("UserPromptSubmit")
if ups:
    kept = []
    for entry in ups:
        hooks = [h for h in entry.get("hooks", []) if "autocontinue/intercept.sh" not in h.get("command", "")]
        if hooks:
            entry["hooks"] = hooks
            kept.append(entry)
    if kept: d["hooks"]["UserPromptSubmit"] = kept
    else:    d["hooks"].pop("UserPromptSubmit", None)
    open(path, "w").write(json.dumps(d, indent=2) + "\n")
    print("removed hook from settings.json")
PYEOF
fi

# 5. remove files
rm -f "$CLAUDE_DIR/commands/autocontinue.md" && echo "removed slash command"
rm -rf "$DEST" && echo "removed $DEST"

# 6. sudoers (needs password — the only interactive step)
for dropin in /etc/sudoers.d/claude-autocontinue-pmset /etc/sudoers.d/autocontinue-pmset; do
  if [ -f "$dropin" ]; then
    echo "removing $dropin (asks for your password)..."
    sudo rm -f "$dropin" && echo "removed $dropin"
  fi
done

echo ""
echo "== uninstalled. Restart Claude Code to drop the (now missing) hook cleanly. =="
