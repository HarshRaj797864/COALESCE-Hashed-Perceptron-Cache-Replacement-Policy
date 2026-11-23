#!/usr/bin/env bash
# The relaunch after the 22 Nov 2026 reboot (bench/policy_sanity/relaunch_2026-11-24.md), laptop side.
# Uploads scripts/relaunch_server.sh as ~/relaunch_server.sh (to .new, then mv) and runs one mode there.
#
#   bash scripts/relaunch_all.sh plan      # (owner's word: it uploads) then READ-ONLY on the server
#   bash scripts/relaunch_all.sh clean     # (owner's word) delete the approved items (~18 GB)
#   bash scripts/relaunch_all.sh radix16   # (owner's word) restart radix16's g6 reference, detached
#   bash scripts/relaunch_all.sh partA     # (owner's word) resume Part A's chain (the committed runner)
#
# The rest of the relaunch uses each chain's own launcher; the order is in the note.
set -uo pipefail
PORT="${PORT:-2222}"
SRV="${SRV:-user@your-server}"
LROOT="${LROOT:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"
SRV_HOME="${SRV_HOME:-/home/harshraj}"
NOTE="bench/policy_sanity/relaunch_2026-11-24.md"
MODE="${1:-}"
case "$MODE" in plan|clean|radix16|partA) ;; *) echo "usage: $0 plan|clean|radix16|partA"; exit 1 ;; esac
die() { echo; echo "STOPPED: $*"; exit 1; }

bash -n "$LROOT/scripts/relaunch_server.sh" || die "relaunch_server.sh does not parse"
for f in "$NOTE" scripts/relaunch_server.sh scripts/relaunch_all.sh scripts/partA_server.sh; do
  git -C "$LROOT" ls-files --error-unmatch "$f" > /dev/null 2>&1 || die "$f is not committed"
done
dirty=$(git -C "$LROOT" status --porcelain -- scripts/relaunch_server.sh scripts/relaunch_all.sh scripts/partA_server.sh "$NOTE")
[ -z "$dirty" ] || { echo "$dirty"; die "uncommitted changes -- commit first"; }

CTL="$HOME/.ssh/cm-relaunch-$$"
mkdir -p "$HOME/.ssh"
cleanup() { ssh -O exit -o ControlPath="$CTL" -p "$PORT" "$SRV" 2>/dev/null || true; rm -f "$CTL"; }
trap cleanup EXIT
ssh -p "$PORT" -o ControlMaster=yes -o ControlPath="$CTL" -o ControlPersist=20m \
    -o ServerAliveInterval=30 -o ConnectTimeout=40 -fN "$SRV" || { echo "could not connect (a locked key agent? see CLAUDE.md, server access)"; exit 1; }
R() { ssh -n -p "$PORT" -o ControlPath="$CTL" "$SRV" "$@"; }

scp -q -P "$PORT" -o ControlPath="$CTL" "$LROOT/scripts/relaunch_server.sh" "$SRV:$SRV_HOME/relaunch_server.sh.new" || die "upload failed"
R "mv -f $SRV_HOME/relaunch_server.sh.new $SRV_HOME/relaunch_server.sh" || die "mv failed"
l=$(md5sum < "$LROOT/scripts/relaunch_server.sh" | cut -c1-32); r=$(R "md5sum < $SRV_HOME/relaunch_server.sh | cut -c1-32")
[ "$l" = "$r" ] || die "~/relaunch_server.sh reads $r, the laptop's $l"

case "$MODE" in
  partA) R "bash $SRV_HOME/relaunch_server.sh partA $(md5sum < "$LROOT/scripts/partA_server.sh" | cut -c1-32)" ;;
  *) R "bash $SRV_HOME/relaunch_server.sh $MODE" ;;
esac
rc=$?
[ "$rc" = 0 ] || die "the server side stopped (above)"
