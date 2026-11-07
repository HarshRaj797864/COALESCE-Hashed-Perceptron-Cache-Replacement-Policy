#!/usr/bin/env bash
# B3 v2 on canneal: upload the static canneal and the runners, launch the six
# gem5 runs and the two ChampSim queues, and check what each gem5 run was
# given. One command, one password. Pre-registration:
# bench/policy_sanity/b3v2_canneal_design_2026-10-06.md.
#
#   scripts/canneal_all.sh        # from the repo root, on the LAPTOP
#
# Steps, each checked, stopping at the first failure:
#   1. local     simulator/bin/CANNEAL.static is the verified build
#                (build_canneal_static.sh), statically linked
#   2. server    the netlist there is byte-identical to the laptop's
#   3. binary    -> ~/splash-static/CANNEAL, via .new + mv; a different
#                CANNEAL already there is kept as CANNEAL.prev_<time>
#   4. runners   run_gem5_splash.sh, gem5_stats.sh, launch_b3_gem5.sh,
#                run_phase_a.sh, launch_b3_v2.sh, each via .new + mv (a live
#                driver keeps its old inode, CLAUDE.md); md5 checked after
#   5. ChampSim  SET=canneal launch_b3_v2.sh plan: 2 and 2 to run, nothing
#                unrunnable; then go. If either canneal queue's driver is
#                alive, launch nothing (a rerun of this script)
#   6. gem5      WL=canneal launch_b3_gem5.sh restart: stops a launcher stuck
#                on a run (never a gem5), then go. Runs that ended are
#                skipped, live ones left alone. Wait for the launcher (a
#                minute or more of checks per run), then read back every run's
#                config.ini: CANNEAL and its arguments, the L2 size,
#                cpu0 stop 0 and cpu1-4 at the run's stop, 10 of 10 L0<->L1
#                buffers unordered, randomization off
#
# Everything is also written to simulator/results/canneal_all_<time>.log.
set -uo pipefail

PORT=2222
SRV="user@your-server"
LROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRV_HOME="${SRV_HOME:-/home/harshraj}"   # overridable only to test this script
SRVR="$SRV_HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy"
BIN_LOCAL="$LROOT/simulator/bin/CANNEAL.static"
BIN_MD5=f675a03ae694b7341e92be15a2e72999
NETS_LOCAL="$LROOT/simulator/tracer/pin/100000.nets"
NETS_SRV="$SRVR/simulator/tracer/pin/100000.nets"
RUNNERS="run_gem5_splash.sh gem5_stats.sh launch_b3_gem5.sh run_phase_a.sh launch_b3_v2.sh"
LOG="$LROOT/simulator/results/canneal_all_$(date +%Y%m%d_%H%M%S).log"
mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1

die() { echo; echo "STOPPED at step $STEP: $*"; echo "log: $LOG"; exit 1; }
step() { STEP="$1"; echo; echo "================ $1/6  $2 ================"; }
STEP=0
md5() { md5sum < "$1" | cut -c1-32; }

step 1 "local checks"
[ -f "$BIN_LOCAL" ] || die "no $BIN_LOCAL -- run scripts/build_canneal_static.sh"
[ "$(md5 "$BIN_LOCAL")" = "$BIN_MD5" ] || die "$BIN_LOCAL is not the verified build (md5 $(md5 "$BIN_LOCAL"), expected $BIN_MD5)"
file -b "$BIN_LOCAL" | grep -c 'statically linked' >/dev/null || die "$BIN_LOCAL is not statically linked"
[ -f "$NETS_LOCAL" ] || die "no $NETS_LOCAL"
for f in $RUNNERS; do [ -f "$LROOT/scripts/$f" ] || die "no scripts/$f"; done
echo "   CANNEAL.static is the verified build ($BIN_MD5), static"

CTL="$HOME/.ssh/cm-canneal-$$"
mkdir -p "$HOME/.ssh"
cleanup() { ssh -O exit -o ControlPath="$CTL" -p "$PORT" "$SRV" 2>/dev/null || true; rm -f "$CTL"; }
trap cleanup EXIT
echo; echo "One connection for every step -- the password is asked once."
ssh -p "$PORT" -o ControlMaster=yes -o ControlPath="$CTL" -o ControlPersist=60m \
    -o ServerAliveInterval=30 -fN "$SRV" || { echo "could not connect"; exit 1; }
R() { ssh -n -p "$PORT" -o ControlPath="$CTL" "$SRV" "$@"; }
up() { scp -q -P "$PORT" -o ControlPath="$CTL" "$1" "$SRV:$2"; }

step 2 "server checks"
r=$(R "md5sum < $NETS_SRV 2>/dev/null | cut -c1-32")
[ -n "$r" ] || die "no netlist on the server at $NETS_SRV"
[ "$r" = "$(md5 "$NETS_LOCAL")" ] || die "the server's netlist differs from the laptop's (md5 $r)"
echo "   netlist on the server is byte-identical to the laptop's"
R 'df -h ~ | tail -1' | awk '{print "   disk: " $4 " free of " $2 " (" $5 " used)"}'

step 3 "upload the static canneal"
up "$BIN_LOCAL" "$SRV_HOME/splash-static/CANNEAL.new" || die "upload failed"
r=$(R 'cd ~/splash-static || exit 1
  if [ -f CANNEAL ] && ! cmp -s CANNEAL CANNEAL.new; then t=CANNEAL.prev_$(date +%Y%m%d_%H%M%S); mv -f CANNEAL "$t"; echo "kept the old one as $t"; fi
  mv -f CANNEAL.new CANNEAL && chmod +x CANNEAL
  echo "md5 $(md5sum < CANNEAL | cut -c1-32) static=$(file -b CANNEAL | grep -c "statically linked")"')
echo "$r" | sed 's/^/   /'
echo "$r" | grep -c "md5 $BIN_MD5 static=1" >/dev/null || die "~/splash-static/CANNEAL is not the verified static build"

step 4 "upload the runners (.new + mv)"
for f in $RUNNERS; do
  up "$LROOT/scripts/$f" "$SRV_HOME/$f.new" || die "upload of $f failed"
  r=$(R "mv -f ~/$f.new ~/$f && md5sum < ~/$f | cut -c1-32")
  [ "$r" = "$(md5 "$LROOT/scripts/$f")" ] || die "~/$f on the server does not match the laptop's"
  echo "   $f"
done

step 5 "ChampSim: the canneal 4c LRU queues"
ALIVE=$(R 'for t in b3_v2_canneal4 b3_v2_canneal4_scaled; do p=~/.phase_a_$t/driver.pid; [ -f "$p" ] && kill -0 "$(cat "$p")" 2>/dev/null && echo "$t"; done')
if [ -n "$ALIVE" ]; then
  echo "   already running, left alone: $(echo $ALIVE)"
  [ "$(echo "$ALIVE" | wc -l)" = 2 ] || echo "   WARNING: only one of the two canneal queues has a live driver -- check: bash ~/run_phase_a.sh status-tag <the other>"
else
  PLAN=$(R "SET=canneal bash ~/launch_b3_v2.sh plan 2>&1"); prc=$?
  echo "$PLAN" | sed 's/^/ /'
  [ "$prc" -eq 0 ] || die "the queue preview failed"
  GOT=$(echo "$PLAN" | awk '/to run:/ {printf "%s ", $NF}' | sed 's/ $//')
  [ "$GOT" = "2 2" ] || die "to-run counts are '$GOT', expected '2 2'"
  [ "$(echo "$PLAN" | grep -c 'unrunnable:[[:space:]]*[1-9]')" = 0 ] || die "some jobs are unrunnable"
  R "SET=canneal bash ~/launch_b3_v2.sh go 2>&1" | sed 's/^/ /'
  [ "${PIPESTATUS[0]}" -eq 0 ] || die "the ChampSim launch failed -- a queue listed before the error IS running"
fi

step 6 "gem5: six canneal runs"
R "WL=canneal bash ~/launch_b3_gem5.sh restart 2>&1" | sed 's/^/   /'
[ "${PIPESTATUS[0]}" -eq 0 ] || die "the gem5 launcher did not start"
echo "   waiting for the launcher (a minute or more per run; up to 30 min)..."
for i in $(seq 1 90); do
  sleep 20
  st=$(R 'grep -cE "launcher done|ERROR" ~/gem5_b3/canneal/launch.log 2>/dev/null')
  [ "${st:-0}" -gt 0 ] && break
done
R 'cat ~/gem5_b3/canneal/launch.log' | sed 's/^/ /'
# Three outcomes, not two. On 2026-10-06 the launcher was still on run 1
# after 15 min (a loaded machine: each run's preflight reads the 950 MB gem5
# binary twice) and this said "did not finish cleanly", which read as a failure.
if [ "$(R 'grep -c "launcher done" ~/gem5_b3/canneal/launch.log')" != 1 ]; then
  [ "$(R 'grep -c ERROR ~/gem5_b3/canneal/launch.log')" = 0 ] || die "the gem5 launcher reported an ERROR (its log is above)"
  if R 'kill -0 "$(cat ~/gem5_b3/canneal/.launcher.pid 2>/dev/null)" 2>/dev/null'; then
    echo; echo "NOT FAILED: the gem5 launcher is still working after 30 min (the machine is slow) and carries on by itself."
    echo "ChampSim is launched. Check the gem5 runs later -- every run's config, then status:"
    echo "  ssh -n -p 2222 $SRV 'tail -5 ~/gem5_b3/canneal/launch.log; WL=canneal bash ~/launch_b3_gem5.sh check; WL=canneal bash ~/launch_b3_gem5.sh status'"
    echo "log: $LOG"; exit 2
  fi
  die "the gem5 launcher stopped without finishing or reporting an error (its log is above)"
fi
CHECK=$(R "WL=canneal bash ~/launch_b3_gem5.sh check 2>&1")
echo "$CHECK" | sed 's/^/ /'
# Every run: CANNEAL with the traces' arguments, the L2 size its name says,
# cpu0 stop 0 and cpu1-4 at its stop, 10 of 10 buffers, randomization off.
BAD=$(echo "$CHECK" | awk -v nets="$NETS_SRV" '
  function flush() { if (run != "" && ok != 5) printf "%s (%d of 5 checks)\n", run, ok }
  /^== / { flush(); run = $0; ok = 0; mb = $4; sub(/MB,$/, "", mb); stop = $NF; next }
  /^   cmd / && $0 ~ ("CANNEAL 4 15000 2000 " nets " 128$") { ok++ }
  /^   L2 / && $2 == mb * 1048576 { ok++ }
  /^   stop per cpu/ && $4 == "cpu0=0" && $5 == "cpu1=" stop && $6 == "cpu2=" stop && $7 == "cpu3=" stop && $8 == "cpu4=" stop && NF == 8 { ok++ }
  /ordered=false: 10 of 10/ { ok++ }
  /randomization=false$/ { ok++ }
  END { flush() }')
N=$(echo "$CHECK" | grep -c '^== ')
[ "$N" = 6 ] && [ -z "$BAD" ] || die "config.ini check failed for: ${BAD:-$N runs listed, expected 6}"
echo "   all 6 runs: CANNEAL with the traces' arguments, the right L2, cpu0 unstopped, cpu1-4 at the stop, FIFO patch, no randomization"
R "WL=canneal bash ~/launch_b3_gem5.sh status 2>&1" | sed 's/^/ /'

echo
echo "All six steps done. gem5: ~11-13 h a run; ChampSim: ~3 h a job."
echo "Status:  ssh -n -p 2222 $SRV 'WL=canneal bash ~/launch_b3_gem5.sh status; bash ~/server_status.sh 2>&1 | grep -A3 \"SWEEP: phaseA_b3_v2_canneal\"'"
echo "log: $LOG"
