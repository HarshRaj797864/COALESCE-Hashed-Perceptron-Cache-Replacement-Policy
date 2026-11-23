#!/usr/bin/env bash
# Part B (bench/policy_sanity/breadth_bc_design_2026-11-10.md, amendments 2 and 3):
# the 14 programs sized at 8 and 16 threads on the server, and gem5's two runs
# of every sized key (canneal at 16 threads included). Uploads
# partB_server.sh and the gem5 runner with Part B's entry (.new + mv); the
# server checks its guards and then, DETACHED there, sizes (Pin, the probe)
# and starts gem5's runs as keys are sized. Builds nothing; writes only under
# ~/partB and ~/gem5_b3/partB. A dropped connection stops nothing.
#
#   scripts/partB_all.sh            # from the repo root, on the LAPTOP (owner's word)
#   scripts/partB_all.sh status     # read-only
#   scripts/partB_all.sh check      # read-only: what each started gem5 run was given
#   scripts/partB_all.sh pull       # read-only: status, then the records to simulator/results/partB/
#   scripts/partB_all.sh stop       # the sizing and the gem5 driver; never a gem5 run
#
# Stage 2 (amendment 4 = Note 2): the 31 keys (B1's three at 4 threads, the
# 28 sized) traced with h2's tracer under gem5's CPUID, run on the g6 binary
# (phaseA_b3_b1_* / _b2_* / _b16_*), then the 124 counter runs. Uploads
# sync_server.sh as ~/sync_server_pb.sh (.new + mv; live chains keep theirs);
# the server checks Note 2's guards, then the chain runs DETACHED there.
#   scripts/partB_all.sh trace      # (owner's word) upload, guards, start the chain
#   scripts/partB_all.sh tstatus    # read-only: traced, runs, counter runs
#   scripts/partB_all.sh tpull      # read-only: trace reports, run logs, counter files to simulator/results/partB/stage2/ (nothing read)
#   scripts/partB_all.sh tstop      # stops the pb chain (its tracing and runs); countstop: the counter runs
#
# Load: sizing runs up to eight 8-thread programs under Pin at once (then
# four 16-thread ones), a few hours in all; gem5 then holds up to 24 cores at
# nice 19 for days (limits: 168 h a run at 8 threads, 240 h at 16).
# No auto-resume: after a reboot, run this again (sized keys and ended runs
# are skipped; a run stopped by its time limit is never started again).
set -uo pipefail
PORT="${PORT:-2222}"
SRV="${SRV:-user@your-server}"
LROOT="${LROOT:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"
SRV_HOME="${SRV_HOME:-/home/harshraj}"
VW=partB
PREREG="bench/policy_sanity/breadth_bc_design_2026-11-10.md"
SV="bash $SRV_HOME/partB_server.sh"
MODE="${1:-}"
case "$MODE" in ""|status|check|pull|stop|trace|tstatus|tpull|tstop|countstop) ;; *) echo "usage: $0 [status|check|pull|stop|trace|tstatus|tpull|tstop|countstop]"; exit 1 ;; esac
SVPB="VARIANT=pb bash $SRV_HOME/sync_server_pb.sh"
WPB="$SRV_HOME/sync_pb"
SROOT="$SRV_HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy/simulator"
OUTD="${OUTD:-$LROOT/simulator/results/partB}"
mkdir -p "$OUTD"
if [ -z "$MODE" ] || [ "$MODE" = trace ]; then
  LOG="$OUTD/partB_${MODE:-all}_$(date +%Y%m%d_%H%M%S).log"
  exec > >(tee -a "$LOG") 2>&1
fi
die() { echo; echo "STOPPED at step $STEP: $*"; exit 1; }
step() { STEP="$1"; echo; echo "================ $1/3  $2 ================"; }
STEP=0

if [ -z "$MODE" ]; then
  step 1 "local checks"
  for f in scripts/partB_server.sh scripts/run_gem5_splash.sh; do bash -n "$LROOT/$f" || die "$f does not parse"; done
  for f in "$PREREG" scripts/partB_server.sh scripts/partB_all.sh scripts/run_gem5_splash.sh; do
    git -C "$LROOT" ls-files --error-unmatch "$f" > /dev/null 2>&1 || die "$f is not committed"
  done
  dirty=$(git -C "$LROOT" status --porcelain -- scripts/partB_server.sh scripts/partB_all.sh scripts/run_gem5_splash.sh "$PREREG")
  [ -z "$dirty" ] || { echo "$dirty"; die "uncommitted changes in what is uploaded -- commit first"; }
  grep -q '^  go-pb)' "$LROOT/scripts/run_gem5_splash.sh" || die "run_gem5_splash.sh has no go-pb entry"
  grep -q 'Amendment 2 (Note 1)' "$LROOT/$PREREG" || die "$PREREG has no Note 1 (the sizing recipes)"
  grep -q '^## Amendment 3, 2026-11-11' "$LROOT/$PREREG" || die "$PREREG has no amendment 3 (the corrections to Note 1)"
  echo "   committed: $(git -C "$LROOT" log -1 --format='%h %s' | cut -c1-90)"
fi
if [ "$MODE" = trace ]; then
  step 1 "local checks (stage 2)"
  bash -n "$LROOT/scripts/sync_server.sh" || die "sync_server.sh does not parse"
  for f in "$PREREG" scripts/sync_server.sh scripts/partB_all.sh scripts/sync_anchor.py scripts/sync_cut.py scripts/trace_mix.c; do
    git -C "$LROOT" ls-files --error-unmatch "$f" > /dev/null 2>&1 || die "$f is not committed"
  done
  dirty=$(git -C "$LROOT" status --porcelain -- scripts/sync_server.sh scripts/partB_all.sh "$PREREG")
  [ -z "$dirty" ] || { echo "$dirty"; die "uncommitted changes in what is uploaded -- commit first"; }
  grep -q '^## Amendment 4 (Note 2), 2026-11-12' "$LROOT/$PREREG" || die "$PREREG has no amendment 4 (Note 2: the tracing, runs and counter runs)"
  grep -q '^  pb) CB_D=' "$LROOT/scripts/sync_server.sh" || die "sync_server.sh has no VARIANT=pb"
  echo "   committed: $(git -C "$LROOT" log -1 --format='%h %s' | cut -c1-90)"
fi

CTL="$HOME/.ssh/cm-$VW-$$"
mkdir -p "$HOME/.ssh"
cleanup() { ssh -O exit -o ControlPath="$CTL" -p "$PORT" "$SRV" 2>/dev/null || true; rm -f "$CTL"; }
trap cleanup EXIT
ssh -p "$PORT" -o ControlMaster=yes -o ControlPath="$CTL" -o ControlPersist=20m \
    -o ServerAliveInterval=30 -o ConnectTimeout=30 -fN "$SRV" || { echo "could not connect (a locked key agent? see CLAUDE.md, server access)"; exit 1; }
R() { ssh -n -p "$PORT" -o ControlPath="$CTL" "$SRV" "$@"; }
RS=(rsync -a --copy-links -e "ssh -p $PORT -o ControlPath=$CTL")

case "$MODE" in
  status|check|stop) R "$SV $MODE" 2>&1; exit 0 ;;
  tstatus) R "[ -f $SRV_HOME/sync_server_pb.sh ] || { echo 'stage 2 not uploaded yet -- $0 trace'; exit 0; }; $SVPB status" 2>&1; exit 0 ;;
  tstop)   R "$SVPB stop" 2>&1; exit 0 ;;
  countstop) R "$SVPB countstop" 2>&1; exit 0 ;;
  tpull)
    O2="$OUTD/stage2"; mkdir -p "$O2/logs" "$O2/traces" "$O2/count"
    R "$SVPB status" 2>&1 | tee "$O2/status_$(date +%Y%m%d_%H%M).txt"
    for t in b1 b2 b16; do
      R "ls -d $SROOT/results/phaseA_b3_${t}_* 2>/dev/null" | while read -r d; do
        "${RS[@]}" --include='*/' --include='run.log' --exclude='*' "$SRV:$d" "$O2/logs/" 2>/dev/null
      done
    done
    "${RS[@]}" --prune-empty-dirs --include='*/' --include='pin.err' --include='*.mix' --include='DONE' --include='CPUID' \
      --include='LEN' --include='FAILED' --include='anchor.txt' --include='anchor.err' --exclude='*' \
      "$SRV:$SROOT/traces/sync_pb/" "$O2/traces/" 2>/dev/null
    "${RS[@]}" --include='driver.log' --include='BIN' --include='Q0_PASSED' --include='QEH2_PASSED' --include='gem5.cpuid' --exclude='*' \
      "$SRV:$WPB/" "$O2/" 2>/dev/null
    "${RS[@]}" --prune-empty-dirs --include='*/' --include='c.summary' --include='c.t*.cnt' --include='c.t*.rtn' \
      --include='STATUS' --include='RUN' --include='PROGS' --include='pin.err' --include='driver.log' --include='DONE' --include='COUNTER_MD5' \
      --exclude='*' "$SRV:$WPB/count/" "$O2/count/" 2>/dev/null
    "${RS[@]}" "$SRV:$WPB/qeh2/" "$O2/qeh2/" 2>/dev/null
    # canneal at 16 cores keeps its older procedure: the v1 check reads its sync_mx traces' mixes
    "${RS[@]}" --include='raw*.mix' --include='DONE' --exclude='*' "$SRV:$SROOT/traces/sync_mx/canneal16/" "$O2/canneal16/" 2>/dev/null
    echo "   pulled to ${O2#"$LROOT"/}/: $(find "$O2/traces" -name DONE | wc -l) trace sets done, $(find "$O2/logs" -name run.log | wc -l) run logs, $(grep -l '^exit 0 ' "$O2"/count/runs/*/STATUS 2>/dev/null | wc -l) counter runs exited 0"
    echo "   No rate was read (the scoring note, Note 3, first)."
    exit 0 ;;
  trace)
    step 2 "upload sync_server.sh as ~/sync_server_pb.sh (to .new, then mv)"
    R "f=$WPB/.driver.pid; [ -f \$f ] && kill -0 \$(cat \$f 2>/dev/null) 2>/dev/null" && die "the pb chain is running already -- $0 tstatus"
    # the helpers the chain runs: the server's must be the committed files (they are shared with older chains; never replaced here)
    for f in sync_anchor.py sync_cut.py trace_mix.c; do
      l=$(md5sum < "$LROOT/scripts/$f" | cut -c1-32); r=$(R "md5sum < $SRV_HOME/$f 2>/dev/null | cut -c1-32")
      [ "$l" = "$r" ] || die "~/$f on the server reads '${r:-missing}', the committed file $l -- not replaced automatically (older chains use it)"
    done
    scp -q -P "$PORT" -o ControlPath="$CTL" "$LROOT/scripts/sync_server.sh" "$SRV:$SRV_HOME/sync_server_pb.sh.new" || die "upload failed"
    R "mv -f $SRV_HOME/sync_server_pb.sh.new $SRV_HOME/sync_server_pb.sh" || die "mv failed"
    l=$(md5sum < "$LROOT/scripts/sync_server.sh" | cut -c1-32); r=$(R "md5sum < $SRV_HOME/sync_server_pb.sh | cut -c1-32")
    [ "$l" = "$r" ] || die "~/sync_server_pb.sh reads $r, the laptop's $l"
    echo "   uploaded ($(git -C "$LROOT" rev-parse --short HEAD)); the helpers equal the committed files"
    step 3 "Note 2's guards, then the chain -- detached on the server"
    R "$SVPB guards" 2>&1 | sed 's/^/   /'
    [ "${PIPESTATUS[0]}" = 0 ] || die "a guard failed (above) -- nothing was started"
    R "$SVPB chain" 2>&1 | sed 's/^/   /'
    [ "${PIPESTATUS[0]}" = 0 ] || die "the chain did not start (above)"
    sleep "${FOLLOW_S:-20}"
    R "$SVPB status" 2>&1 | sed 's/^/   /'
    echo
    echo "Started: 31 keys traced (4 and 8 threads two at a time, 16 one at a time), their ChampSim runs as each group ends,"
    echo "then the 124 counter runs (QE first). Where it is:  $0 tstatus      Files:  $0 tpull"
    echo "log: $LOG"
    exit 0 ;;
  pull)
    R "$SV status" 2>&1
    "${RS[@]}" --prune-empty-dirs --include='*/' --exclude='run_*/**' \
      --include='CHOSEN' --include='NTHR' --include='NCPU' --include='SKIP' --include='MIN' --include='BELOW' --include='MD5' --include='PROGS' \
      --include='JOBS' --include='GEM5' --include='SIZED' --include='FAILED_E3' --include='size.log' --include='gem5.log' \
      --include='probe_chosen.txt' --include='*.in' --include='gem5_*.launch' --include='gem5_*.started' --exclude='*' \
      "$SRV:$SRV_HOME/$VW/" "$OUTD/" && echo "   pulled: the records of $(ls -d "$OUTD"/*_8 "$OUTD"/*_16 2>/dev/null | wc -l) keys to ${OUTD#"$LROOT"/}/ (nothing of gem5's statistics: that is the scoring pull)"
    exit 0 ;;
esac

step 2 "upload partB_server.sh and the gem5 runner (to .new, then mv)"
if R "for f in $SRV_HOME/$VW/.size.pid $SRV_HOME/$VW/.gem5.pid; do [ -f \$f ] && kill -0 \$(cat \$f 2>/dev/null) 2>/dev/null && exit 0; done; exit 1"; then
  die "Part B's sizing or gem5 driver is already running on the server -- $0 status"
fi
for f in partB_server.sh run_gem5_splash.sh; do
  scp -q -P "$PORT" -o ControlPath="$CTL" "$LROOT/scripts/$f" "$SRV:$SRV_HOME/$f.new" || die "upload of $f failed"
  R "mv -f $SRV_HOME/$f.new $SRV_HOME/$f" || die "mv of $f failed"
  l=$(md5sum < "$LROOT/scripts/$f" | cut -c1-32); r=$(R "md5sum < $SRV_HOME/$f | cut -c1-32")
  [ "$l" = "$r" ] || die "$f on the server reads $r, the laptop's $l"
done
echo "   uploaded; both match the laptop's"

step 3 "guards, then sizing and the gem5 driver -- detached on the server"
R "$SV go" 2>&1 | sed 's/^/   /'
[ "${PIPESTATUS[0]}" = 0 ] || die "a guard failed (above) -- nothing was started"
sleep "${FOLLOW_S:-20}"
R "$SV status" 2>&1 | sed 's/^/   /'
echo
echo "Started: sizing of 28 keys (14 programs at 8, then 16 threads) and the gem5 driver (up to 58 runs, 24 at a time,"
echo "8-thread keys first). Sizing takes a few hours; the gem5 runs days (limits 168 h / 240 h a run)."
echo "Where it is:  $0 status      Records:  $0 pull      What gem5 was given:  $0 check"
echo "log: $LOG"
