#!/usr/bin/env bash
# The checks of 2026-10-14, started on the server in one command (one password):
#   - B3 on three held-out programs   (b3_heldout_design_2026-10-14.md)
#   - B3 at 8 cores, canneal          (b3_canneal8_design_2026-10-14.md)
#   - A6, the LLC-size sweep          (a6_size_sweep_design_2026-10-14.md)
#
#   scripts/checks_all.sh             # from the repo root, on the LAPTOP
#   A6_JOBS=6 scripts/checks_all.sh   # fewer A6 jobs at a time (default 8)
#   SKIP_A6=1 scripts/checks_all.sh   # everything but A6
#
# Steps, each checked, stopping at the first failure:
#   1. local    every script parses; every pre-registration is committed
#   2. server   disk, boot, load; none of these pipelines already running; no
#               gem5 launcher alive (two of the uploads are its scripts)
#   3. upload   each script via .new + mv, md5 checked. None is a live
#               runner: bin/champsim and run_phase_a.sh are not touched, and
#               everything here runs the frozen champsim_b3v4_69ebdcce
#   4. start    the held-out pipeline (waits until its first program's build
#               and function check pass), canneal 8c, then A6 (its plan, then go)
#
# Afterwards the server carries on unattended. scripts/pull_results.sh shows
# where each one is. Written also to simulator/results/checks_all_<time>.log.
set -uo pipefail

PORT=2222
SRV="user@your-server"
LROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRV_HOME="${SRV_HOME:-/home/harshraj}"
UPLOADS="b3_heldout.sh b3_canneal8.sh a6_sweep.sh barnes_std_traces.py launch_b3_gem5.sh run_gem5_splash.sh count_rmw.py"
PREREGS="bench/policy_sanity/b3_heldout_design_2026-10-14.md bench/policy_sanity/b3_canneal8_design_2026-10-14.md bench/policy_sanity/a6_size_sweep_design_2026-10-14.md"
A6_JOBS="${A6_JOBS:-8}"
LOG="$LROOT/simulator/results/checks_all_$(date +%Y%m%d_%H%M%S).log"
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
for p in $PREREGS; do
  git -C "$LROOT" ls-files --error-unmatch "$p" > /dev/null 2>&1 || die "$p is not committed"
  [ -z "$(git -C "$LROOT" status --porcelain -- "$p")" ] || die "$p has uncommitted changes"
done
for f in $UPLOADS; do
  [ -z "$(git -C "$LROOT" status --porcelain -- "scripts/$f")" ] || die "scripts/$f has uncommitted changes -- commit what is uploaded"
done
echo "   scripts parse; pre-registrations and scripts committed ($(git -C "$LROOT" log -1 --format=%h))"

CTL="$HOME/.ssh/cm-checks-$$"
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
R 'echo "   booted: $(uptime -s)   now: $(date "+%F %T")   load: $(cut -d" " -f1-3 /proc/loadavg)   cores: $(nproc)"'
free_gb=$(R 'df --output=avail -BG ~ | tail -1 | tr -dc 0-9')
[ "${free_gb:-0}" -ge 80 ] || die "only ${free_gb} GB free; the held-out traces need about 52 GB a program (they are made one at a time, and the pipeline checks before each)"
for w in b3_heldout b3_canneal8; do
  if R "[ -f $SRV_HOME/$w/.pipeline.pid ] && kill -0 \$(cat $SRV_HOME/$w/.pipeline.pid 2>/dev/null) 2>/dev/null"; then die "the $w pipeline is already running -- bash ~/$w.sh status"; fi
done
if R "pgrep -u \$(id -u) -f '[l]aunch_b3_gem5.sh __go' > /dev/null"; then die "a gem5 launcher is working; its scripts are about to be replaced -- wait for it (bash ~/launch_b3_gem5.sh status)"; fi
echo "   none of these pipelines is running; no gem5 launcher alive"
R '[ -x ~/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy/simulator/bin/champsim_b3v4_69ebdcce ]' || die "the frozen binary champsim_b3v4_69ebdcce is missing"
echo "   the frozen binary is there"

step 3 "upload (.new + mv)"
for f in $UPLOADS; do
  up "$LROOT/scripts/$f" "$SRV_HOME/$f.new" || die "upload of $f failed"
  r=$(R "mv -f ~/$f.new ~/$f && md5sum < ~/$f | cut -c1-32")
  [ "$r" = "$(md5 "$LROOT/scripts/$f")" ] || die "~/$f on the server does not match the laptop's"
  echo "   $f"
done

step 4 "start"
echo "-- held-out programs (radix, waternsq, fmm), one after another"
R "bash ~/b3_heldout.sh go 2>&1" | sed 's/^/   /'
echo "   waiting for radix's build and function check (about a minute)..."
for i in $(seq 1 60); do
  sleep 5
  st=$(R "grep -cE 'STOPPED|4/8 trace' ~/b3_heldout/pipeline.log 2>/dev/null")
  [ "${st:-0}" -gt 0 ] && break
done
R "cat ~/b3_heldout/pipeline.log" | sed 's/^/ /'
[ "$(R "grep -c STOPPED ~/b3_heldout/pipeline.log")" = 0 ] || die "the held-out pipeline stopped (its log is above)"
[ "$(R "grep -c 'QB: all' ~/b3_heldout/pipeline.log")" -ge 1 ] || die "radix's build was not checked within 5 minutes -- bash ~/b3_heldout.sh status"

echo; echo "-- canneal at 8 cores"
R "bash ~/b3_canneal8.sh go 2>&1" | sed 's/^/   /'
for i in $(seq 1 24); do
  sleep 5
  st=$(R "grep -cE 'STOPPED|2/4' ~/b3_canneal8/pipeline.log 2>/dev/null")
  [ "${st:-0}" -gt 0 ] && break
done
R "cat ~/b3_canneal8/pipeline.log" | sed 's/^/ /'
[ "$(R "grep -c STOPPED ~/b3_canneal8/pipeline.log")" = 0 ] || die "the canneal 8c pipeline stopped (its log is above)"

if [ "${SKIP_A6:-0}" = 1 ]; then
  echo; echo "-- A6 skipped (SKIP_A6=1); start it later with: ssh -n -p 2222 $SRV 'JOBS=$A6_JOBS bash ~/a6_sweep.sh go'"
else
  echo; echo "-- A6, the LLC-size sweep ($A6_JOBS at a time)"
  R "JOBS=$A6_JOBS bash ~/a6_sweep.sh plan 2>&1" | sed 's/^/   /'
  [ "${PIPESTATUS[0]}" -eq 0 ] || die "A6's plan failed (above)"
  R "JOBS=$A6_JOBS bash ~/a6_sweep.sh go 2>&1" | sed 's/^/   /'
  [ "${PIPESTATUS[0]}" -eq 0 ] || die "A6 did not start"
  R "JOBS=$A6_JOBS bash ~/a6_sweep.sh install-resume 2>&1" | sed 's/^/   /'
fi

echo
echo "Started. Unattended from here:"
echo "  held-out  traces each program (tens of minutes each), aligns it, then 6 ChampSim"
echo "            runs (~3 h) and 2 gem5 runs per program. No auto-resume: after a"
echo "            reboot, run this script again (completed steps are skipped)."
echo "  canneal8  counts the traces' mix, then 6 ChampSim runs (~6 h) and 2 gem5 runs."
echo "  A6        $( [ "${SKIP_A6:-0}" = 1 ] && echo 'not started' || echo 'about 600 CPU-hours; resumes by itself after a reboot.')"
echo "Where they are:  scripts/pull_results.sh"
echo "log: $LOG"
