#!/usr/bin/env bash
# Part C (bench/policy_sanity/breadth_bc_design_2026-11-10.md, Part C and
# amendment 6 = Note 4): stock ChampSim (Part A's upstream binary) and ours with
# the extension off, on our scored runs' traces with the sync records removed,
# 15 programs at 4, 8 and 16 cores (45 pairs). Uploads partC_server.sh and
# sync_strip.py (into ~/partC, .new + mv); the server checks its guards, then
# the chain runs DETACHED there: each pair waits for its reference run (Part
# B's end over days), strips, runs both, removes the stripped copies.
#
#   scripts/partC_all.sh            # (owner's word) upload, guards, start the chain
#   scripts/partC_all.sh status     # read-only
#   scripts/partC_all.sh pairs      # read-only: each pair's reference tree and whether it has completed
#   scripts/partC_all.sh pull       # read-only: the logs and strip reports to simulator/results/partC/
#   scripts/partC_all.sh stop       # the chain (its strips and runs)
set -uo pipefail
PORT="${PORT:-2222}"
SRV="${SRV:-user@your-server}"
LROOT="${LROOT:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"
SRV_HOME="${SRV_HOME:-/home/harshraj}"
PREREG="bench/policy_sanity/breadth_bc_design_2026-11-10.md"
SV="bash $SRV_HOME/partC/partC_server.sh"
SROOT="$SRV_HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy/simulator"
MODE="${1:-}"
case "$MODE" in ""|status|pairs|pull|stop) ;; *) echo "usage: $0 [status|pairs|pull|stop]"; exit 1 ;; esac
OUTD="${OUTD:-$LROOT/simulator/results/partC}"
mkdir -p "$OUTD"
if [ -z "$MODE" ]; then
  LOG="$OUTD/partC_all_$(date +%Y%m%d_%H%M%S).log"
  exec > >(tee -a "$LOG") 2>&1
fi
die() { echo; echo "STOPPED: $*"; exit 1; }

if [ -z "$MODE" ]; then
  echo "== local checks"
  bash -n "$LROOT/scripts/partC_server.sh" || die "partC_server.sh does not parse"
  python3 "$LROOT/scripts/sync_strip.py" selftest > /dev/null || die "sync_strip.py's selftest fails here"
  for f in "$PREREG" scripts/partC_server.sh scripts/partC_all.sh scripts/sync_strip.py; do
    git -C "$LROOT" ls-files --error-unmatch "$f" > /dev/null 2>&1 || die "$f is not committed"
  done
  dirty=$(git -C "$LROOT" status --porcelain -- scripts/partC_server.sh scripts/partC_all.sh scripts/sync_strip.py "$PREREG")
  [ -z "$dirty" ] || { echo "$dirty"; die "uncommitted changes in what is uploaded -- commit first"; }
  grep -q '^## Amendment 6 (Note 4), 2026-11-12' "$LROOT/$PREREG" || die "$PREREG has no amendment 6 (Note 4: part C's runner)"
  echo "   committed: $(git -C "$LROOT" log -1 --format='%h %s' | cut -c1-90)"
fi

CTL="$HOME/.ssh/cm-partC-$$"
mkdir -p "$HOME/.ssh"
cleanup() { ssh -O exit -o ControlPath="$CTL" -p "$PORT" "$SRV" 2>/dev/null || true; rm -f "$CTL"; }
trap cleanup EXIT
ssh -p "$PORT" -o ControlMaster=yes -o ControlPath="$CTL" -o ControlPersist=20m \
    -o ServerAliveInterval=30 -o ConnectTimeout=30 -fN "$SRV" || { echo "could not connect (a locked key agent? see CLAUDE.md, server access)"; exit 1; }
R() { ssh -n -p "$PORT" -o ControlPath="$CTL" "$SRV" "$@"; }
RS=(rsync -a --copy-links -e "ssh -p $PORT -o ControlPath=$CTL")

case "$MODE" in
  status|pairs|stop) R "[ -f $SRV_HOME/partC/partC_server.sh ] || { echo 'part C not uploaded yet'; exit 0; }; $SV $MODE" 2>&1; exit 0 ;;
  pull)
    R "$SV status" 2>&1
    mkdir -p "$OUTD/logs"
    "${RS[@]}" --include='*.log' --include='*.log.bin' --exclude='*' "$SRV:$SROOT/results/partC/" "$OUTD/logs/" 2>/dev/null
    "${RS[@]}" --include='driver.log' --include='order.txt' --include='strip_selftest.txt' --include='strip_reports/***' --include='cfg/***' --exclude='*' \
      "$SRV:$SRV_HOME/partC/" "$OUTD/server/" 2>/dev/null
    echo "   pulled: $(ls "$OUTD"/logs/*.log 2>/dev/null | wc -l) logs, $(ls "$OUTD"/server/strip_reports/*.txt 2>/dev/null | wc -l) strip reports (nothing read)"
    exit 0 ;;
esac

echo "== upload partC_server.sh and sync_strip.py into ~/partC (to .new, then mv)"
R "f=$SRV_HOME/partC/.driver.pid; [ -f \$f ] && kill -0 \$(cat \$f 2>/dev/null) 2>/dev/null" && die "the partC chain is running already -- $0 status"
R "mkdir -p $SRV_HOME/partC" || die "mkdir failed"
for f in partC_server.sh sync_strip.py; do
  scp -q -P "$PORT" -o ControlPath="$CTL" "$LROOT/scripts/$f" "$SRV:$SRV_HOME/partC/$f.new" || die "upload of $f failed"
  R "mv -f $SRV_HOME/partC/$f.new $SRV_HOME/partC/$f" || die "mv of $f failed"
  l=$(md5sum < "$LROOT/scripts/$f" | cut -c1-32); r=$(R "md5sum < $SRV_HOME/partC/$f | cut -c1-32")
  [ "$l" = "$r" ] || die "$f on the server reads $r, the laptop's $l"
done
echo "   uploaded ($(git -C "$LROOT" rev-parse --short HEAD))"
echo "== guards, then the chain -- detached on the server"
R "$SV chain" 2>&1 | sed 's/^/   /'
[ "${PIPESTATUS[0]}" = 0 ] || die "a guard failed or the chain did not start (above)"
sleep "${FOLLOW_S:-20}"
R "$SV status" 2>&1 | sed 's/^/   /'
echo
echo "Started: 45 pairs (15 programs x 4, 8, 16 cores), 6 at a time; a pair waits for its reference run."
echo "Where it is:  $0 status      Each pair's reference:  $0 pairs      Logs:  $0 pull"
echo "log: $LOG"
