#!/usr/bin/env bash
# ChampSim on SPLASH-3's barnes as shipped: upload, build, compare with the
# binary gem5 ran, and start the trace. The rest runs by itself on the server.
# One command, one password. Pre-registration:
# bench/policy_sanity/b3_barnes_std_design_2026-10-13.md.
#
#   scripts/barnes_std_all.sh        # from the repo root, on the LAPTOP
#
# Steps, each checked, stopping at the first failure:
#   1. local    the scripts parse; the pre-registration is committed
#   2. server   disk, boot time; nothing of this pipeline already running
#   3. upload   launch_b3_gem5.sh, barnes_std.sh, barnes_std_traces.py, each
#               via .new + mv, md5 checked. (None is the ChampSim runner;
#               bin/champsim and run_phase_a.sh are not touched.)
#   4. start    barnes_std.sh go, then wait for its first two steps: the
#               preflight, and a dynamic standard BARNES whose force and
#               tree-build functions equal those of the binary gem5 ran. If
#               either stops, nothing is traced or launched
#
# After that the server carries on unattended (barnes_std.sh, steps 3-7): the
# trace, the alignment, the check that it IS the standard program, 18 ChampSim
# runs, one more gem5 stop. scripts/pull_results.sh shows where it is.
#
# Everything is also written to simulator/results/barnes_std_all_<time>.log.
set -uo pipefail

PORT=2222
SRV="user@your-server"
LROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRV_HOME="${SRV_HOME:-/home/harshraj}"   # overridable only to test this script
REMOTE_ENV="${REMOTE_ENV:-}"             # likewise: settings passed to barnes_std.sh
UPLOADS="launch_b3_gem5.sh barnes_std.sh barnes_std_traces.py"
PREREG="bench/policy_sanity/b3_barnes_std_design_2026-10-13.md"
W="$SRV_HOME/barnes_std"
LOG="$LROOT/simulator/results/barnes_std_all_$(date +%Y%m%d_%H%M%S).log"
mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1

die() { echo; echo "STOPPED at step $STEP: $*"; echo "log: $LOG"; exit 1; }
step() { STEP="$1"; echo; echo "================ $1/4  $2 ================"; }
STEP=0
md5() { md5sum < "$1" | cut -c1-32; }

step 1 "local checks"
for f in $UPLOADS; do
  [ -f "$LROOT/scripts/$f" ] || die "no scripts/$f"
  case "$f" in
    *.sh) bash -n "$LROOT/scripts/$f" || die "scripts/$f does not parse" ;;
    *.py) python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "$LROOT/scripts/$f" || die "scripts/$f does not parse" ;;
  esac
done
[ -f "$LROOT/$PREREG" ] || die "the pre-registration is not written"
git -C "$LROOT" ls-files --error-unmatch "$PREREG" > /dev/null 2>&1 || die "the pre-registration is not committed"
[ -z "$(git -C "$LROOT" status --porcelain -- "$PREREG")" ] || die "the pre-registration has uncommitted changes"
echo "   scripts parse; the pre-registration is committed ($(git -C "$LROOT" log -1 --format=%h -- "$PREREG"))"

CTL="$HOME/.ssh/cm-barnesstd-$$"
mkdir -p "$HOME/.ssh"
cleanup() { ssh -O exit -o ControlPath="$CTL" -p "$PORT" "$SRV" 2>/dev/null || true; rm -f "$CTL"; }
trap cleanup EXIT
echo; echo "One connection for every step -- the password is asked once."
ssh -p "$PORT" -o ControlMaster=yes -o ControlPath="$CTL" -o ControlPersist=60m \
    -o ServerAliveInterval=30 -fN "$SRV" || { echo "could not connect"; exit 1; }
R() { ssh -n -p "$PORT" -o ControlPath="$CTL" "$SRV" "$@"; }
up() { scp -q -P "$PORT" -o ControlPath="$CTL" "$1" "$SRV:$2"; }

step 2 "server checks"
R 'df -h ~ | tail -1' | awk '{print "   disk: " $4 " free of " $2 " (" $5 " used)"}'
R 'echo "   booted: $(uptime -s)   now: $(date "+%F %T")   load: $(cut -d" " -f1-3 /proc/loadavg)"'
if R "[ -f $W/.pipeline.pid ] && kill -0 \$(cat $W/.pipeline.pid 2>/dev/null) 2>/dev/null"; then die "the pipeline is already running on the server -- bash ~/barnes_std.sh status"; fi
echo "   this pipeline is not running"

step 3 "upload (.new + mv)"
for f in $UPLOADS; do
  up "$LROOT/scripts/$f" "$SRV_HOME/$f.new" || die "upload of $f failed"
  r=$(R "mv -f ~/$f.new ~/$f && md5sum < ~/$f | cut -c1-32")
  [ "$r" = "$(md5 "$LROOT/scripts/$f")" ] || die "~/$f on the server does not match the laptop's"
  echo "   $f"
done

step 4 "start: preflight, build, compare with the binary gem5 ran"
R "$REMOTE_ENV bash ~/barnes_std.sh go 2>&1" | sed 's/^/   /'
[ "${PIPESTATUS[0]}" -eq 0 ] || die "the pipeline did not start"
echo "   waiting for the first two steps (about a minute)..."
for i in $(seq 1 60); do
  sleep 5
  st=$(R "grep -cE 'STOPPED|3/7 trace it|pipeline done' $W/pipeline.log 2>/dev/null")
  [ "${st:-0}" -gt 0 ] && break
done
R "cat $W/pipeline.log" | sed 's/^/ /'
[ "$(R "grep -c STOPPED $W/pipeline.log")" = 0 ] || die "the pipeline stopped (its log is above) -- nothing was traced or launched"
[ "$(R "grep -c 'the force and tree-build functions match the binary gem5 ran' $W/pipeline.log")" = 1 ] || die "the build was not compared within 5 minutes -- bash ~/barnes_std.sh status"

echo
echo "Started. The server now traces the program (tens of minutes), aligns the traces,"
echo "checks they are the standard program, and starts 18 ChampSim runs and one gem5 run"
echo "(a few hours). It stops by itself if a check fails."
echo "Where it is:  scripts/pull_results.sh"
echo "log: $LOG"
