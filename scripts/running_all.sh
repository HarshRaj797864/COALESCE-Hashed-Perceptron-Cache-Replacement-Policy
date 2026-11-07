#!/usr/bin/env bash
# READ-ONLY: what of ours is running on the server, one password.
#
#   scripts/running_all.sh
#
# Uploads scripts/running_server.sh (a report, never a driver; still through a
# new name and mv) and runs it. Output: simulator/results/running/running_<time>.txt
set -uo pipefail
PORT=2222
SRV="user@your-server"
SRV_HOME="${SRV_HOME:-/home/harshraj}"
LROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
bash -n "$LROOT/scripts/running_server.sh" || { echo "running_server.sh does not parse"; exit 1; }
OUT="$LROOT/simulator/results/running"; mkdir -p "$OUT"
F="$OUT/running_$(date +%Y%m%d_%H%M).txt"
CTL="$HOME/.ssh/cm-running-$$"
mkdir -p "$HOME/.ssh"
cleanup() { ssh -O exit -o ControlPath="$CTL" -p "$PORT" "$SRV" 2>/dev/null || true; rm -f "$CTL"; }
trap cleanup EXIT
echo "One connection -- the password is asked once."
ssh -p "$PORT" -o ControlMaster=yes -o ControlPath="$CTL" -o ControlPersist=10m -o ServerAliveInterval=30 -o ServerAliveCountMax=4 \
  -o ConnectTimeout=30 -fN "$SRV" || { echo "could not connect"; exit 1; }
R() { ssh -n -p "$PORT" -o ControlPath="$CTL" -o ServerAliveInterval=30 -o ServerAliveCountMax=4 "$SRV" "$@"; }
scp -q -P "$PORT" -o ControlPath="$CTL" "$LROOT/scripts/running_server.sh" "$SRV:$SRV_HOME/running_server.sh.new" \
  && R "mv -f $SRV_HOME/running_server.sh.new $SRV_HOME/running_server.sh" || { echo "upload failed"; exit 1; }
R "bash $SRV_HOME/running_server.sh" 2>&1 | tee "$F"
echo; echo "Saved to ${F#"$LROOT"/}"
