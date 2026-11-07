#!/usr/bin/env bash
# Were the threads already this far apart in the traced (Pin) run? One
# command, one password. Read-only on the server's traces; about 10-20 min.
# It waits and prints the result; if the connection drops, run it again (a
# program already measured is skipped). Results land in
# simulator/results/sync/native/.
set -uo pipefail
PORT=2222
SRV="user@your-server"
SRV_HOME="${SRV_HOME:-/home/harshraj}"
LROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
LOUT="$LROOT/simulator/results/sync/native"
CTL="$HOME/.ssh/cm-native-$$"
mkdir -p "$HOME/.ssh" "$LOUT"
cleanup() { ssh -O exit -o ControlPath="$CTL" -p "$PORT" "$SRV" 2>/dev/null || true; rm -f "$CTL"; }
trap cleanup EXIT
echo "One connection -- the password is asked once."
ssh -p "$PORT" -o ControlMaster=yes -o ControlPath="$CTL" -o ControlPersist=60m -o ServerAliveInterval=30 -fN "$SRV" || { echo "could not connect"; exit 1; }
R() { ssh -n -p "$PORT" -o ControlPath="$CTL" "$SRV" "$@"; }
for f in sync_native_drift.py sync_native_server.sh; do
  scp -q -P "$PORT" -o ControlPath="$CTL" "$LROOT/scripts/$f" "$SRV:$SRV_HOME/$f.new" || { echo "upload failed"; exit 1; }
  R "mv -f $SRV_HOME/$f.new $SRV_HOME/$f" || exit 1
done
R "bash $SRV_HOME/sync_native_server.sh go" || exit 1
while R "bash $SRV_HOME/sync_native_server.sh alive"; do
  R "bash $SRV_HOME/sync_native_server.sh status | head -1"
  sleep 60
done
R "bash $SRV_HOME/sync_native_server.sh status"
scp -q -P "$PORT" -o ControlPath="$CTL" "$SRV:$SRV_HOME/sync/native/*.tsv" "$SRV:$SRV_HOME/sync/native/*.txt" "$LOUT/" 2>/dev/null
echo
echo "Pulled to $LOUT. Tell Claude: native done."
