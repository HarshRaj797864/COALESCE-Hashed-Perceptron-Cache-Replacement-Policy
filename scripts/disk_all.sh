#!/usr/bin/env bash
# Clear the server's disk (owner, 2026-10-18). One command, one password.
#
#   scripts/disk_all.sh          # READ-ONLY report and proposal; nothing is changed
#   scripts/disk_all.sh go       # carry out the proposal the report printed (detached)
#   scripts/disk_all.sh status
#
# The rules are in scripts/disk_server.sh: compress needed traces stored raw
# (checked byte for byte before the original goes), delete void or dropped
# trace sets, old build trees and core dumps, keep everything else; skip
# anything a running job uses. Only this account's files under ~.
set -uo pipefail
PORT=2222
SRV="user@your-server"
SRV_HOME="${SRV_HOME:-/home/harshraj}"
LROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
MODE="${1:-report}"
case "$MODE" in report|go|status) ;; *) echo "usage: $0 [go|status]"; exit 1 ;; esac
CTL="$HOME/.ssh/cm-disk-$$"
mkdir -p "$HOME/.ssh"
cleanup() { ssh -O exit -o ControlPath="$CTL" -p "$PORT" "$SRV" 2>/dev/null || true; rm -f "$CTL"; }
trap cleanup EXIT
echo "One connection -- the password is asked once."
ssh -p "$PORT" -o ControlMaster=yes -o ControlPath="$CTL" -o ControlPersist=20m -fN "$SRV" || { echo "could not connect"; exit 1; }
R() { ssh -n -p "$PORT" -o ControlPath="$CTL" "$SRV" "$@"; }
if [ "$MODE" = report ]; then
  scp -q -P "$PORT" -o ControlPath="$CTL" "$LROOT/scripts/disk_server.sh" "$SRV:$SRV_HOME/disk_server.sh.new" || { echo "upload failed"; exit 1; }
  R "mv -f $SRV_HOME/disk_server.sh.new $SRV_HOME/disk_server.sh" || exit 1
fi
R "bash $SRV_HOME/disk_server.sh $MODE"
