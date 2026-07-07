#!/bin/bash
# Optional one-time setup for claude-autocontinue's sleep-defeating abilities.
#
# Grants two narrowly-scoped passwordless sudo rules:
#   1. `pmset schedule wake ...` / `pmset schedule cancelall`
#      — wake a sleeping Mac at the exact usage-reset time (hardware RTC timer;
#        works lid-closed, on battery). Without it, a sleeping Mac delivers on
#        its NEXT wake instead of on time.
#   2. `pmset -a disablesleep 1|0`
#      — keep the Mac awake lid-closed on battery while the resumed turn runs
#        (caffeinate cannot defeat clamshell sleep). Always restored afterwards.
#
# Nothing else is granted. Remove anytime:
#   sudo rm /etc/sudoers.d/claude-autocontinue-pmset

set -e
USER_NAME=$(id -un)
DROPIN="/etc/sudoers.d/claude-autocontinue-pmset"
TMP=$(mktemp)

cat > "$TMP" <<EOF
# Installed by claude-autocontinue setup-wake.sh — lets the watcher wake the
# Mac at the usage-reset time and hold it awake for the resumed turn, without
# a password. Scoped to these exact pmset commands only.
$USER_NAME ALL=(root) NOPASSWD: /usr/bin/pmset schedule wake *
$USER_NAME ALL=(root) NOPASSWD: /usr/bin/pmset schedule cancelall
$USER_NAME ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1
$USER_NAME ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0
EOF

echo "This will install a passwordless sudoers rule (needs your password once):"
echo "----------------------------------------------------------------------"
cat "$TMP"
echo "----------------------------------------------------------------------"

if sudo visudo -c -f "$TMP" >/dev/null 2>&1; then
  sudo install -m 0440 -o root -g wheel "$TMP" "$DROPIN"
  rm -f "$TMP"
  echo "Installed $DROPIN"
  echo "Verifying..."
  if sudo -n /usr/bin/pmset schedule cancelall >/dev/null 2>&1; then
    echo "OK — autocontinue can now wake your Mac at reset time, even asleep/locked/lid-closed."
  else
    echo "WARN — sudoers installed but the sudo -n test failed; check $DROPIN"
  fi
else
  rm -f "$TMP"
  echo "ERROR: sudoers syntax check failed — nothing installed."
  exit 1
fi
