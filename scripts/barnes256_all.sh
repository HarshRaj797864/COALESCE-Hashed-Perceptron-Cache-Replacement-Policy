#!/usr/bin/env bash
# gem5 on the program the barnes_4t traces hold (BARNES with 256-body leaves):
# upload, build, compare with the traced binary, launch. One command, one
# password. Pre-registration:
# bench/policy_sanity/b3_barnes256_design_2026-10-12.md.
#
#   scripts/barnes256_all.sh        # from the repo root, on the LAPTOP
#
# Steps, each checked, stopping at the first failure:
#   1. local     the scripts are there and parse
#   2. server    disk; nothing of this pipeline already running
#   3. upload    launch_b3_gem5.sh and barnes256_gem5.sh, each via .new + mv,
#                md5 checked. run_gem5_splash.sh only if the server's differs.
#                (None of these is the ChampSim runner; bin/champsim and
#                run_phase_a.sh are not touched.)
#   4. build     barnes256_gem5.sh go: the traced binary reads as 256-body
#                leaves; a static 256 build of a COPY of the source; its
#                force-phase functions equal the traced binary's; it runs
#                natively. Any failure stops here, with nothing launched
#   5. gem5      two runs, LLC 2 MB, stop at 50 M and at 150 M. Wait for the
#                launcher, then read each run's config.ini back: the 256
#                binary, the L2 size, the stop, the FIFO patch, no
#                randomization
#
# Everything is also written to simulator/results/barnes256_all_<time>.log.
set -uo pipefail

PORT=2222
SRV="user@your-server"
LROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRV_HOME="${SRV_HOME:-/home/harshraj}"
UPLOADS="launch_b3_gem5.sh barnes256_gem5.sh"
W="$SRV_HOME/gem5_b3/barnes_leaf256"
LOG="$LROOT/simulator/results/barnes256_all_$(date +%Y%m%d_%H%M%S).log"
mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1

die() { echo; echo "STOPPED at step $STEP: $*"; echo "log: $LOG"; exit 1; }
step() { STEP="$1"; echo; echo "================ $1/5  $2 ================"; }
STEP=0
md5() { md5sum < "$1" | cut -c1-32; }

step 1 "local checks"
for f in $UPLOADS run_gem5_splash.sh; do
  [ -f "$LROOT/scripts/$f" ] || die "no scripts/$f"
  bash -n "$LROOT/scripts/$f" || die "scripts/$f does not parse"
done
[ -f "$LROOT/bench/policy_sanity/b3_barnes256_design_2026-10-12.md" ] || die "the pre-registration is not written"
git -C "$LROOT" ls-files --error-unmatch bench/policy_sanity/b3_barnes256_design_2026-10-12.md > /dev/null 2>&1 || die "the pre-registration is not committed"
[ -z "$(git -C "$LROOT" status --porcelain -- bench/policy_sanity/b3_barnes256_design_2026-10-12.md)" ] || die "the pre-registration has uncommitted changes"
echo "   scripts parse; the pre-registration is committed ($(git -C "$LROOT" log -1 --format=%h -- bench/policy_sanity/b3_barnes256_design_2026-10-12.md))"

CTL="$HOME/.ssh/cm-barnes256-$$"
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
if R "[ -f $W/.pipeline.pid ] && kill -0 \$(cat $W/.pipeline.pid 2>/dev/null) 2>/dev/null"; then die "the pipeline is already running on the server -- bash ~/barnes256_gem5.sh status"; fi
n=$(R "pgrep -u \$(id -u) -fc '[g]em5.opt --outdir=$W/' 2>/dev/null")
[ "${n:-0}" = 0 ] || die "$n gem5 run(s) of this experiment are already going -- bash ~/barnes256_gem5.sh status"
echo "   nothing of this pipeline is running"

step 3 "upload (.new + mv)"
for f in $UPLOADS; do
  up "$LROOT/scripts/$f" "$SRV_HOME/$f.new" || die "upload of $f failed"
  r=$(R "mv -f ~/$f.new ~/$f && md5sum < ~/$f | cut -c1-32")
  [ "$r" = "$(md5 "$LROOT/scripts/$f")" ] || die "~/$f on the server does not match the laptop's"
  echo "   $f"
done
r=$(R 'md5sum < ~/run_gem5_splash.sh 2>/dev/null | cut -c1-32')
if [ "$r" = "$(md5 "$LROOT/scripts/run_gem5_splash.sh")" ]; then
  echo "   run_gem5_splash.sh: the server's is the laptop's, left alone"
else
  up "$LROOT/scripts/run_gem5_splash.sh" "$SRV_HOME/run_gem5_splash.sh.new" || die "upload of run_gem5_splash.sh failed"
  r=$(R 'mv -f ~/run_gem5_splash.sh.new ~/run_gem5_splash.sh && md5sum < ~/run_gem5_splash.sh | cut -c1-32')
  [ "$r" = "$(md5 "$LROOT/scripts/run_gem5_splash.sh")" ] || die "~/run_gem5_splash.sh on the server does not match the laptop's"
  echo "   run_gem5_splash.sh: updated"
fi

step 4 "build the 256-body-leaf BARNES and compare it with the traced binary"
R 'bash ~/barnes256_gem5.sh go 2>&1' | sed 's/^/   /'
[ "${PIPESTATUS[0]}" -eq 0 ] || die "the pipeline did not start"
echo "   waiting for the build, the comparison and the native run (a few minutes)..."
for i in $(seq 1 60); do
  sleep 10
  st=$(R "grep -cE 'pipeline done|STOPPED' $W/pipeline.log 2>/dev/null")
  [ "${st:-0}" -gt 0 ] && break
done
R "cat $W/pipeline.log" | sed 's/^/ /'
[ "$(R "grep -c STOPPED $W/pipeline.log")" = 0 ] || die "the pipeline stopped (its log is above) -- nothing was launched"
[ "$(R "grep -c 'pipeline done' $W/pipeline.log")" = 1 ] || die "the pipeline did not finish within 10 minutes -- bash ~/barnes256_gem5.sh status"
[ "$(R "grep -c 'the force-phase functions match the traced binary' $W/pipeline.log")" = 1 ] || die "the comparison line is missing from the pipeline log"

step 5 "gem5: two runs"
echo "   waiting for the launcher (a minute or more per run; up to 20 min)..."
for i in $(seq 1 60); do
  sleep 20
  st=$(R "grep -cE 'launcher done|ERROR' $W/launch.log 2>/dev/null")
  [ "${st:-0}" -gt 0 ] && break
done
R "cat $W/launch.log" | sed 's/^/ /'
if [ "$(R "grep -c 'launcher done' $W/launch.log")" != 1 ]; then
  [ "$(R "grep -c ERROR $W/launch.log")" = 0 ] || die "the gem5 launcher reported an ERROR (its log is above)"
  if R "kill -0 \$(cat $W/.launcher.pid 2>/dev/null) 2>/dev/null"; then
    echo; echo "NOT FAILED: the gem5 launcher is still working after 20 min (the machine is slow) and carries on by itself."
    echo "Check later:  ssh -n -p 2222 $SRV 'bash ~/barnes256_gem5.sh status; WL=barnes VARIANT=leaf256 bash ~/launch_b3_gem5.sh check'"
    echo "log: $LOG"; exit 2
  fi
  die "the gem5 launcher stopped without finishing or reporting an error (its log is above)"
fi
CHECK=$(R "WL=barnes VARIANT=leaf256 bash ~/launch_b3_gem5.sh check 2>&1")
echo "$CHECK" | sed 's/^/ /'
# Each run: the 256 binary, a 2 MB L2, every cpu at the run's stop, 8 of 8
# buffers unordered, randomization off.
BAD=$(echo "$CHECK" | awk '
  function flush() { if (run != "" && ok != 5) printf "%s (%d of 5 checks)\n", run, ok }
  /^== / { flush(); run = $0; ok = 0; stop = $NF; next }
  /^   cmd / && $0 ~ /splash-static-leaf256\/BARNES$/ { ok++ }
  /^   L2 / && $2 == 2 * 1048576 { ok++ }
  /^   stop per cpu/ && $4 == "cpu0=" stop && $5 == "cpu1=" stop && $6 == "cpu2=" stop && $7 == "cpu3=" stop && NF == 7 { ok++ }
  /ordered=false: 8 of 8/ { ok++ }
  /randomization=false$/ { ok++ }
  END { flush() }')
N=$(echo "$CHECK" | grep -c '^== ')
[ "$N" = 2 ] && [ -z "$BAD" ] || die "config.ini check failed for: ${BAD:-$N runs listed, expected 2}"
echo "   both runs: the 256-body-leaf BARNES, a 2 MB L2, every cpu at the stop, FIFO patch, no randomization"
R "WL=barnes VARIANT=leaf256 bash ~/launch_b3_gem5.sh status 2>&1" | sed 's/^/ /'

echo
echo "All five steps done. The two gem5 runs take a few hours. Then: scripts/pull_results.sh"
echo "log: $LOG"
