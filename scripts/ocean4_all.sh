#!/usr/bin/env bash
# Deploy the store-time counter, build it, and launch the ocean 4c sweep plus
# B3's ChampSim runs: one command, one password.
#
#   scripts/ocean4_all.sh          # from the repo root, on the LAPTOP
#
# Steps, each checked, stopping at the first failure:
#   1. deploy preview      refuses if anything under simulator/replacement/ would
#                          change (COALESCE is frozen; the only source change
#                          since the last deploy is the counter, 5ac2844)
#   2. deploy              scripts/deploy_to_server.sh --go (backs up first)
#   3. upload runners      run_phase_a.sh, launch_ocean4.sh, server_build.sh;
#                          refuses if any queue driver is alive, because a plain
#                          copy onto a live runner corrupts it (CLAUDE.md)
#   4. build               server_build.sh; must end "All green."
#   5. preview the queues  launch_ocean4.sh plan; to-run counts must be exactly
#                          14 14 6 6 6 6 2 2 and nothing unrunnable
#   6. launch              launch_ocean4.sh go
#
# Everything is also written to simulator/results/ocean4_all_<time>.log
# (gitignored).
set -uo pipefail

PORT=2222
SRV="user@your-server"
LROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$LROOT/simulator/results/ocean4_all_$(date +%Y%m%d_%H%M%S).log"
mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1

die() { echo; echo "STOPPED at step $STEP: $*"; echo "log: $LOG"; exit 1; }
step() { STEP="$1"; echo; echo "================ $1/6  $2 ================"; }
STEP=0

CTL="$HOME/.ssh/cm-ocean4-$$"
mkdir -p "$HOME/.ssh"
cleanup() { ssh -O exit -o ControlPath="$CTL" -p "$PORT" "$SRV" 2>/dev/null || true; rm -f "$CTL"; }
trap cleanup EXIT
echo "One connection for every step -- the password is asked once."
# ServerAlive keeps the master up through the build's quiet minutes.
ssh -p "$PORT" -o ControlMaster=yes -o ControlPath="$CTL" -o ControlPersist=60m \
    -o ServerAliveInterval=30 -fN "$SRV" || { echo "could not connect"; exit 1; }
R() { ssh -n -p "$PORT" -o ControlPath="$CTL" "$SRV" "$@"; }

# Itemized rsync changes (sent, created, deleted) inside one "== <dir>" section
# of the deploy output. Directory-timestamp lines (".d..t") are not changes.
changes_in() {   # $1 file  $2 section dir
  awk -v d="$2" '/^== / { inside = ($2 == d) ; next }
    inside && /^(\*deleting|[<>ch][fdLDS])/ { print }' "$1"
}

step 1 "deploy preview (copies nothing)"
PREVIEW="$(mktemp)"
COALESCE_CTL="$CTL" bash "$LROOT/scripts/deploy_to_server.sh" > "$PREVIEW" 2>&1 \
  || { cat "$PREVIEW"; die "the deploy preview failed"; }
DEL=$(grep '^\*deleting' "$PREVIEW")
[ -z "$DEL" ] || { echo "$DEL"; die "the deploy would DELETE the files above on the server -- none were expected; check what they are first"; }
# A flagged file under replacement/ may differ only in mtime: ab_build.sh
# restored the COALESCE sources on the server with cp + touch (2026-09-24), so
# their timestamps no longer match the laptop's. rsync's quick check flags that
# (">f..t"). Compare content before refusing: COALESCE is frozen, and any real
# difference there is a stop.
REPL=$(changes_in "$PREVIEW" simulator/replacement | awk '{print $2}')
if [ -n "$REPL" ]; then
  for f in $REPL; do
    l=$(md5sum < "$LROOT/simulator/replacement/$f" | cut -c1-32)
    r=$(R "md5sum < ~/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy/simulator/replacement/$f" | cut -c1-32)
    [ "$l" = "$r" ] || die "simulator/replacement/$f differs in CONTENT between laptop and server -- COALESCE is frozen"
  done
  echo "   simulator/replacement: $(echo "$REPL" | wc -w) file(s) flagged, all identical in content (timestamp only)"
fi
for d in simulator/inc simulator/src simulator/replacement simulator/scripts simulator/config bench; do
  printf '   %-24s %s change(s)\n' "$d" "$(changes_in "$PREVIEW" "$d" | grep -c .)"
done
echo "   simulator/src and inc:"; changes_in "$PREVIEW" simulator/src | sed 's/^/     /'; changes_in "$PREVIEW" simulator/inc | sed 's/^/     /'
rm -f "$PREVIEW"

step 2 "deploy"
COALESCE_CTL="$CTL" bash "$LROOT/scripts/deploy_to_server.sh" --go > /dev/null 2>&1 \
  || die "the deploy failed -- the server keeps a backup tarball in ~/pre_deploy_backup_*"
R 'grep -c "RFO-HIT OTHER-SHARER" ~/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy/simulator/src/plain_printer.cc' \
  | grep -qx 1 || die "the deployed plain_printer.cc does not carry the counter"
echo "   deployed; the server's source carries the counter"

step 3 "upload runner scripts"
LIVE=$(R 'for p in ~/.phase_a*/driver.pid ~/.a4*/driver.pid; do [ -f "$p" ] && kill -0 "$(cat "$p")" 2>/dev/null && echo "$p"; done')
[ -z "$LIVE" ] || die "queue driver(s) alive: $LIVE -- a plain copy onto a live runner corrupts it"
scp -q -P "$PORT" -o ControlPath="$CTL" "$LROOT/scripts/run_phase_a.sh" "$LROOT/scripts/launch_ocean4.sh" \
    "$LROOT/scripts/server_build.sh" "$SRV:~/" || die "upload failed"
echo "   uploaded run_phase_a.sh, launch_ocean4.sh, server_build.sh"

step 4 "build bin/champsim (several minutes)"
BUILD=$(R 'bash ~/server_build.sh 2>&1'); brc=$?
echo "$BUILD" | tail -12 | sed 's/^/   /'
[ "$brc" -eq 0 ] && echo "$BUILD" | grep -q '^All green' || die "the build or a guard failed (output above; ~/.server_build_make.log on the server)"

step 5 "preview the eight queues"
PLAN=$(R 'bash ~/launch_ocean4.sh plan 2>&1'); prc=$?
echo "$PLAN" | sed 's/^/ /'
[ "$prc" -eq 0 ] || die "the queue preview failed"
GOT=$(echo "$PLAN" | awk '/to run:/ {printf "%s ", $NF}' | sed 's/ $//')
[ "$GOT" = "14 14 6 6 6 6 2 2" ] || die "to-run counts are '$GOT', expected '14 14 6 6 6 6 2 2'"
echo "$PLAN" | grep -q 'unrunnable:[[:space:]]*[1-9]' && die "some jobs are unrunnable"
echo "   counts as expected, nothing unrunnable"

step 6 "launch"
R 'bash ~/launch_ocean4.sh go 2>&1' | sed 's/^/ /'
[ "${PIPESTATUS[0]}" -eq 0 ] || die "the launch failed -- queues listed before the error ARE running; check status"

echo
echo "All six steps done: 56 jobs launched across eight queues (4-core, ~4-8 h)."
echo "Status:  ssh -n -p 2222 $SRV 'bash ~/server_status.sh 2>&1 | grep -A2 \"ocean4\"'"
echo "log: $LOG"
