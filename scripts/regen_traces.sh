#!/usr/bin/env bash
# Regenerate the workload traces with the FIXED PIN tracer.
#
# 28 of 34 existing traces contain no data accesses at all -- only instruction
# pointers -- because champsim_tracer.cpp wrote every thread's memory operands
# into thread 0's buffer while emitting from each thread's own buffer. Exactly
# one healthy trace exists per workload, always the thread-0 one. Every
# multi-core result this project has produced therefore gave real data to one
# core and empty streams to the rest. See docs/trace_audit_2026-09-16.txt.
#
# Run the phases IN ORDER. Nothing destructive happens until `smoke` passes.
#
#   bash ~/regen_traces.sh build     # rebuild the tool from the fixed source
#   bash ~/regen_traces.sh smoke     # prove the fix works, on a 4-thread toy
#   bash ~/regen_traces.sh plan      # show what would be deleted and freed
#   bash ~/regen_traces.sh clean     # delete the broken traces (frees ~380 GB)
#   bash ~/regen_traces.sh gen ocean # regenerate one workload
#   bash ~/regen_traces.sh verify    # re-audit everything
#   bash ~/regen_traces.sh reclaim   # report reclaimable disk (build output etc.)
#   bash ~/regen_traces.sh reclaim-go # ...and delete it
#
# Disk is the constraint: 221 GB free against 406 GB of traces, so the broken
# ones must come off before the replacements land. They are provably worthless
# -- 0.0% data accesses across their whole length -- so this is safe, but it is
# still gated behind `smoke`.
set -uo pipefail

REPO="$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy/simulator"
PIN_ROOT="$REPO/tracer/pin/pin-external-3.31-98869-gfa6f126a8-gcc-linux"
PIN="$PIN_ROOT/pin"
TRACER="$REPO/tracer/pin/obj-intel64/champsim_tracer.so"
SRC="$REPO/tracer/pin/champsim_tracer.cpp"
TRACES="$REPO/traces"
SPLASH="$REPO/tracer/splash-3/codes/apps"
STAMP="$HOME/.regen_smoke_passed"

# Instructions traced PER THREAD. The originals were generated with no limit,
# which is why barnes is 35 GB per thread and water 16 GB. A run only consumes
# 50M warmup + 100M simulation per core, so 200M leaves generous headroom while
# cutting generation time and disk enormously. Override with:
#   MAX_INSTR=500000000 bash ~/regen_traces.sh gen ocean
MAX_INSTR="${MAX_INSTR:-200000000}"

# Tracing runs are launched with setsid and all three descriptors redirected.
# nohup alone is not enough over ssh: the background job still shares the
# session's stdout/stderr, so ssh waits for them to close and the terminal
# appears to hang even though the job is detached.

# /tmp here is NOT a RAM drive -- it is the root filesystem (/dev/sda5, 2.5 TB),
# it is shared with every other user of this machine, and it sits at 100% full
# with 0 bytes available while /home still has 534 GB. Anything written to /tmp
# fails. That is what broke the first water launch, and what makes g++ fail with
# "No space left on device" on its assembler temporaries. Keep every temporary
# on /home. Do not try to free space under /tmp -- those are other people's files.
export TMPDIR="${TMPDIR_OVERRIDE:-$HOME/.build_tmp}"
mkdir -p "$TMPDIR"

die() { echo "ERROR: $*" >&2; exit 1; }

# Every process name a running trace job can present as. Pin does NOT keep
# "pin" or the tool name in the command line of the process doing the work --
# it runs under the APPLICATION's name -- so matching only champsim_tracer
# gives a false "nothing running". That false negative previously allowed two
# barnes runs to be launched at once and corrupt 576 GB of traces. Match both.
#
# The first character of each pattern is bracketed so the regex cannot match
# the command line of the shell evaluating it; without that, pkill -f kills
# its own shell.
TRACER_PATTERNS='[c]hampsim_tracer [W]ATER-NSQUARED [O]CEAN [B]ARNES [c]anneal [f]luidanimate [p]inbin'

# PIDs of live tracer processes, with this script and its helpers excluded.
#
# Bracketing the first character of a pattern stops pgrep matching the literal
# pattern in a command line, but it does NOT help when the workload name is a
# genuine argument: `regen_traces.sh gen canneal` really does contain "canneal",
# so [c]anneal matches the script's own shell and the guard reports a job that
# is not running. Worse, `kill canneal` would pkill the script mid-kill.
#
# So match by pattern, then discard by identity: our own pid, our parent, any
# process whose command line names this script, and the ps/pgrep helpers we
# spawn to do the looking. What survives is a real tracer or application.
tracer_pids() {
  local pats="${*:-$TRACER_PATTERNS}"
  local pat pid cmd
  {
    for pat in $pats; do
      pgrep -f "$pat" 2>/dev/null
    done
  } | sort -u | while read -r pid; do
    [ -n "$pid" ] || continue
    [ "$pid" = "$$" ] && continue
    [ "$pid" = "$PPID" ] && continue
    # A process can exit between the scan and this read; that is normal and
    # must stay silent, so the redirect itself is guarded rather than just tr.
    [ -r "/proc/$pid/cmdline" ] || continue
    cmd=$( { tr '\0' ' ' < "/proc/$pid/cmdline"; } 2>/dev/null ) || continue
    [ -n "$cmd" ] || continue
    case "$cmd" in
      *regen_traces.sh*) continue ;;   # this script, or another copy of it
      pgrep*|*/pgrep*|ps\ *|*/ps\ *) continue ;;
    esac
    echo "$pid"
  done
}

tracer_procs() { tracer_pids "$@" | wc -l | tr -d ' '; }

# Ground truth, independent of how any process names itself: are the traces
# still growing? This is the check to trust when process matching disagrees.
traces_growing() {
  local before after
  before=$(du -sb "$TRACES" 2>/dev/null | cut -f1)
  sleep 5
  after=$(du -sb "$TRACES" 2>/dev/null | cut -f1)
  [ "$before" != "$after" ]
}

# Traces with no data accesses, from docs/trace_audit_2026-09-16.txt.
BROKEN=(
  barnes_4t1.champsimtrace barnes_4t2.champsimtrace barnes_4t3.champsimtrace
  canneal_big1.champsimtrace canneal_big2.champsimtrace canneal_big3.champsimtrace canneal_big4.champsimtrace
  canneal_tiny1.champsimtrace canneal_tiny2.champsimtrace canneal_tiny3.champsimtrace canneal_tiny4.champsimtrace
  fluidanimate_8t/fluid1.champsimtrace fluidanimate_8t/fluid2.champsimtrace fluidanimate_8t/fluid3.champsimtrace
  fluidanimate_8t/fluid4.champsimtrace fluidanimate_8t/fluid5.champsimtrace fluidanimate_8t/fluid6.champsimtrace
  fluidanimate_8t/fluid7.champsimtrace fluidanimate_8t/fluid8.champsimtrace
  ocean_8t/ocean1.champsimtrace ocean_8t/ocean2.champsimtrace ocean_8t/ocean3.champsimtrace ocean_8t/ocean4.champsimtrace
  ocean_8t/ocean5.champsimtrace ocean_8t/ocean6.champsimtrace ocean_8t/ocean7.champsimtrace
  water_8t/water2.champsimtrace water_8t/water3.champsimtrace water_8t/water4.champsimtrace
  water_8t/water5.champsimtrace water_8t/water6.champsimtrace water_8t/water7.champsimtrace
)

phase_build() {
  echo "== rebuilding the tracer from $SRC =="
  grep -q "curr_instr\[0\].source_memory" "$SRC" && \
    die "this source still has the curr_instr[0] bug. scp the fixed champsim_tracer.cpp up first."
  grep -q "WriteSourceMem" "$SRC" || \
    die "this source does not look like the fixed tracer (no WriteSourceMem). scp it up first."
  [ -x "$PIN" ] || die "pin not found at $PIN"
  echo "   TMPDIR=$TMPDIR  ($(df -h "$TMPDIR" | tail -1 | awk '{print $4}') free)"
  echo "   /tmp is $(df -h /tmp | tail -1 | awk '{print $5}') full -- bypassing it"
  ( cd "$REPO/tracer/pin" && make PIN_ROOT="$PIN_ROOT" TMPDIR="$TMPDIR" obj-intel64/champsim_tracer.so ) \
    || die "tracer build failed"
  ls -la "$TRACER"
  echo "built."
}

phase_smoke() {
  echo "== smoke test: 4 threads, each touching its own array =="
  local d="$HOME/.regen_smoke"; rm -rf "$d"; mkdir -p "$d"; cd "$d" || die "cd failed"
  cat > mt.c <<'EOF'
#include <pthread.h>
#include <stdlib.h>
#include <stdio.h>
#define N (64*1024)
static long *buf[4];
static void* work(void* a){ long id=(long)a; long*p=buf[id]; long acc=0;
  for(int r=0;r<20;r++) for(int i=0;i<N;i++){ p[i]+=i+r; acc+=p[i]; } return (void*)acc; }
int main(void){ pthread_t t[4];
  for(long i=0;i<4;i++) buf[i]=calloc(N,sizeof(long));
  for(long i=0;i<4;i++) pthread_create(&t[i],NULL,work,(void*)i);
  for(int i=0;i<4;i++) pthread_join(t[i],NULL);
  printf("done\n"); return 0; }
EOF
  TMPDIR="$TMPDIR" gcc -O0 -pthread -o mt mt.c || die "smoke program build failed"
  "$PIN" -t "$TRACER" -o smoke -max_instr 100000 -- ./mt >/dev/null 2>&1

  python3 - "$d" <<'PYEOF'
import glob, os, struct, sys
FMT='<QBB2B4B2Q4Q'; SZ=struct.calcsize(FMT)
bad = 0
files = sorted(glob.glob(os.path.join(sys.argv[1], "smoke*.champsimtrace")))
if not files:
    print("FAIL: no trace files produced"); raise SystemExit(1)
for f in files:
    n = os.path.getsize(f)//SZ
    tot=mem=0
    with open(f,'rb') as fh:
        for _ in range(min(n, 50000)):
            r=fh.read(SZ)
            if len(r)<SZ: break
            v=struct.unpack(FMT,r); tot+=1
            if any(v[8:10]) or any(v[10:14]): mem+=1
    pct = 100.0*mem/tot if tot else 0.0
    flags = []
    if pct <= 1.0:
        flags.append("NO DATA ACCESSES"); bad += 1
    # the cap was 100000; allow slack for the main thread but catch runaways
    if n > 200000:
        flags.append(f"CAP IGNORED ({n} records vs 100000 requested)"); bad += 1
    print(f"  {os.path.basename(f):28} records={n:<9} memory_ops={pct:5.1f}%  {' / '.join(flags) or 'ok'}")
if bad:
    print(f"\nFAIL: {bad} thread trace(s) carry no data. The tracer is still broken.")
    raise SystemExit(1)
print("\nPASS: every thread's trace carries memory operands.")
PYEOF
  if [ $? -eq 0 ]; then
    touch "$STAMP"
    echo "smoke passed -- 'clean' and 'gen' are now unlocked."
  else
    rm -f "$STAMP"
    die "smoke failed. Do not delete anything."
  fi
}

phase_plan() {
  echo "== broken traces (0.0% data accesses) that 'clean' would delete =="
  local total=0
  for t in "${BROKEN[@]}"; do
    local f="$TRACES/$t"
    if [ -f "$f" ]; then
      local sz; sz=$(stat -c %s "$f")
      total=$((total + sz))
      printf "  %-46s %8s\n" "$t" "$(numfmt --to=iec "$sz")"
    fi
  done
  echo
  echo "would free: $(numfmt --to=iec $total)"
  echo "free now:   $(df -h "$HOME" | tail -1 | awk '{print $4}')"
  echo
  echo "KEPT (the one healthy thread-0 trace per workload, as reference):"
  echo "  barnes_4t0, barnes_big_4t0, canneal_big0, canneal_simlarge, canneal_tiny0,"
  echo "  fluidanimate_8t/fluid0, ocean_8t/ocean0, water_8t/water1"
}

phase_clean() {
  [ -f "$STAMP" ] || die "run 'smoke' first and let it pass. Refusing to delete anything."
  echo "== deleting broken traces =="
  read -r -p "This permanently deletes the traces listed by 'plan'. Type YES to proceed: " ans
  [ "$ans" = "YES" ] || die "aborted"
  for t in "${BROKEN[@]}"; do
    local f="$TRACES/$t"
    [ -f "$f" ] && rm -f "$f" && echo "  deleted $t"
  done
  echo
  df -h "$HOME" | tail -1
}

phase_gen() {
  [ -f "$STAMP" ] || die "run 'smoke' first and let it pass."
  local w="${1:-}"

  # Refuse to start if a tracing run is already alive. Two Pin processes writing
  # the same trace files interleave their records and corrupt both. This
  # happened: an uncapped pre-fix run was still going when a capped one was
  # launched on top of it, and the files reached 144 GB of garbage.
  #
  # Match on the tracer .so, which appears only in a real Pin command line.
  # Matching the script name instead makes the guard match ITSELF, and
  # 'ps -C pin' misses these entirely because Pin runs the process under the
  # application's name.
  local running
  running=$(pgrep -u "$USER" -f "champsim_tracer.so" | head -5)
  if [ -n "$running" ]; then
    echo "A tracing run is already in progress:" >&2
    ps -o pid,etime,args -p $(echo "$running" | tr '\n' ' ') 2>/dev/null | cut -c1-130 >&2
    die "refusing to start a second run -- concurrent writers corrupt the traces. Kill it, delete the partial files, then retry."
  fi

  [ -n "$w" ] || die "usage: $0 gen <ocean|barnes|water|canneal|fluidanimate>"
  [ -x "$PIN" ] || die "pin not found at $PIN"
  mkdir -p "$TRACES"

  # Refuse to start a second job on top of a running one. Two concurrent Pin
  # jobs writing the same trace directory previously corrupted 576 GB, and the
  # only reason a second was launched is that a process check reported "nothing
  # running" when something was. Check processes AND directory growth, and
  # treat either as occupied.
  local live; live=$(tracer_procs)
  if [ "$live" -gt 0 ]; then
    phase_progress
    die "$live tracer process(es) already running. Wait, or run '$0 kill' deliberately."
  fi
  echo -n "   checking the traces directory is idle (5s)... "
  if traces_growing; then
    echo "STILL GROWING"
    die "traces are still being written even though no process matched. Something is running. Refusing to launch."
  fi
  echo "idle"

  # A capped 8-thread run writes 8 x 12.8 GB ~= 103 GB. Refuse to start one
  # onto a disk that cannot hold it -- otherwise it dies hours in, having
  # produced a directory of truncated traces that still look plausible.
  # Each capped thread is 12.8 GB. A flat floor is wrong: an 8-thread run needs
  # ~103 GB and a 16-thread run ~205 GB. Passing a 120 GB check and then dying
  # at 60% is the worst outcome -- it leaves truncated traces that look whole.
  local nthreads="${CANNEAL_THREADS:-${OCEAN_THREADS:-${FLUID_THREADS:-8}}}"
  local auto_gb=$(( (MAX_INSTR / 1000000 * 64 / 1000) * nthreads * 115 / 100 ))
  [ "$auto_gb" -lt 20 ] && auto_gb=20
  local need_gb="${NEED_GB:-$auto_gb}"
  local free_gb
  free_gb=$(df -BG --output=avail "$TRACES" 2>/dev/null | tail -1 | tr -dc '0-9')
  if [ -n "$free_gb" ] && [ "$free_gb" -lt "$need_gb" ]; then
    df -h "$TRACES" | tail -1
    die "only ${free_gb}G free on the traces filesystem, need ~${need_gb}G. Run 'reclaim' / 'plan' + 'clean' first, or lower MAX_INSTR."
  fi
  echo "   disk: ${free_gb:-?}G free"

  case "$w" in
    ocean)
      local D="$SPLASH/ocean/contiguous_partitions"
      [ -x "$D/OCEAN" ] || die "OCEAN binary not found at $D/OCEAN -- build SPLASH-3 first"

      # Grid size. The original -n258 produced ~45.3M records per thread, but a
      # 50M warmup + 100M simulation run consumes 150M per core. ChampSim does
      # not stop at a short trace -- main.cc sets repeat = simulation_given and
      # repeatable::operator() silently reopens the file at EOF -- so every
      # ocean run in the first sweep WRAPPED 3.3 times, replaying the same
      # instructions. Under the shared-VMEM overlay the eight traces are
      # near-identical in length, so the cores wrap in near-lockstep and
      # re-touch the same addresses together, manufacturing both reuse and
      # sharing. That is the trace-duplication artifact again, in time.
      #
      # SPLASH ocean takes grids of 2^k+2, so the next size up is 514: four
      # times the grid points, ~181M records per thread, clearing 150M with
      # margin. Costs ~86 GB for the eight threads against the old 22 GB.
      local GRID="${OCEAN_GRID:-514}"
      local NT="${OCEAN_THREADS:-8}"
      local OUT="$TRACES/ocean_${NT}t"
      mkdir -p "$OUT"
      if ls "$OUT"/*.champsimtrace >/dev/null 2>&1; then
        echo "   $OUT already holds traces:"
        ls -la "$OUT"/*.champsimtrace | awk '{print "     "$NF"  "$5}'
        die "refusing to overwrite. Delete them deliberately first -- and note the n258 set wraps, so it is not worth keeping."
      fi

      echo "== tracing ocean, $NT threads, grid ${GRID}x${GRID} =="
      echo "   args: -n$GRID -p$NT -e1e-7 -r20000 -t28800"
      echo "   output: $OUT/ocean*"
      echo "   capped at $MAX_INSTR instructions per thread"
      echo "   a run needs 150M records/thread; n258 gave only ~45.3M and wrapped"
      ( cd "$OUT" && setsid nice -n 10 "$PIN" -t "$TRACER" -o ocean -max_instr "$MAX_INSTR" \
          -- "$D/OCEAN" -n"$GRID" -p"$NT" -e1e-7 -r20000 -t28800 \
          < /dev/null > "$HOME/trace_gen_ocean_${NT}t_n${GRID}.log" 2>&1 & disown 2>/dev/null; echo "launched, pid $!" )
      # The thread count is in the name: the 8-thread set's log is
      # trace_gen_ocean_n514.log, and a 4-thread run must not overwrite it.
      echo "log: ~/trace_gen_ocean_${NT}t_n${GRID}.log"
      ;;
    barnes)
      local D="$SPLASH/barnes"
      [ -x "$D/BARNES" ] || die "BARNES binary not found at $D/BARNES -- build SPLASH-3 first"
      [ -f "$D/inputs/n16384-p4" ] || die "input not found at $D/inputs/n16384-p4"
      echo "== tracing barnes, 4 threads =="
      echo "   capped at $MAX_INSTR instructions per thread"
      ( cd "$TRACES" && setsid nice -n 10 "$PIN" -t "$TRACER" -o barnes_4t -max_instr "$MAX_INSTR" \
          -- "$D/BARNES" < "$D/inputs/n16384-p4" \
          > "$HOME/trace_gen_barnes.log" 2>&1 & disown 2>/dev/null; echo "launched, pid $!" )
      echo "log: ~/trace_gen_barnes.log"
      ;;
    water)
      local D="$HOME/splash3/codes/apps/water-nsquared"
      [ -x "$D/WATER-NSQUARED" ] || die "WATER-NSQUARED not found at $D -- build SPLASH-3 first"
      mkdir -p "$TRACES/water_8t"

      # Parameters recovered from the original retrace_water.sh:
      #   NMOL=13824 (24^3), NSTEP=1, NPRINT=2, NumProcs=8, CUTOFF=6.212752
      # Working set is 13824 x 648 B ~= 8.96 MB per thread, 4.5x the 2 MB LLC.
      #
      # NOT in /tmp: on this machine /tmp is the root filesystem, it is shared
      # with other users, and it runs full. A failed write there would leave
      # water reading empty stdin and silently tracing nothing.
      local WIN="$HOME/.water_trace.in"
      cat > "$WIN" << 'WEOF'
1.5e-16   13824  1   6
0      0     2  0
8 6.212752
WEOF
      [ -s "$WIN" ] || die "could not write $WIN (disk full?). Refusing to launch."
      [ "$(wc -l < "$WIN")" -eq 3 ] || die "$WIN is truncated. Refusing to launch."

      # water reads random.in and needs 1 + NMOL*3*3 lines.
      local needed=124417
      local have
      have=$(wc -l < "$D/random.in" 2>/dev/null || echo 0)
      if [ "$have" -lt "$needed" ]; then
        echo "   random.in has $have lines, needs $needed -- extending"
        python3 -c "
import random, sys
need, have = $needed, $have
with open('$D/random.in', 'a') as f:
    for _ in range(need - have):
        f.write(f'{random.random():.6f}\\n')
" || die "could not extend random.in"
      fi

      echo "== tracing water-nsquared, 8 threads =="
      echo "   NMOL=13824, NumProcs=8, capped at $MAX_INSTR instructions per thread"
      ( cd "$D" && setsid nice -n 10 "$PIN" -t "$TRACER" -o "$TRACES/water_8t/water" -max_instr "$MAX_INSTR" \
          -- ./WATER-NSQUARED < "$WIN" \
          > "$HOME/trace_gen_water.log" 2>&1 & disown 2>/dev/null; echo "launched, pid $!" )
      echo "log: ~/trace_gen_water.log"
      ;;
    canneal)
      # The original canneal tracing command was never recorded -- those traces
      # predate every captured script. These are PARSEC's standard arguments:
      #   canneal <nthreads> <nswaps> <temperature> <netlist> [nsteps]
      # Override any of them from the environment.
      local B="${CANNEAL_BIN:-}"
      if [ -z "$B" ]; then
        for cand in "$REPO/tracer/canneal" "$REPO/tracer/pin/canneal"; do
          [ -x "$cand" ] && B="$cand" && break
        done
      fi
      [ -n "$B" ] && [ -x "$B" ] || die "canneal binary not found; set CANNEAL_BIN=<path>"

      local NETS="${CANNEAL_NETS:-}"
      if [ -z "$NETS" ]; then
        for cand in "$REPO/tracer/pin/100000.nets" "$REPO/tracer/pin/10000.nets"; do
          [ -f "$cand" ] && NETS="$cand" && break
        done
      fi
      [ -n "$NETS" ] && [ -f "$NETS" ] || die "no .nets input found; set CANNEAL_NETS=<path>"

      local NT="${CANNEAL_THREADS:-8}"
      local SWAPS="${CANNEAL_SWAPS:-15000}"
      local TEMP="${CANNEAL_TEMP:-2000}"
      local STEPS="${CANNEAL_STEPS:-128}"

      # Output goes in a per-thread-count directory. Writing flat canneal0..N
      # would make a 16-thread run silently overwrite the verified 8-thread
      # set -- the same class of accident as everything else in here.
      local OUT="$TRACES/canneal_${NT}t"
      mkdir -p "$OUT"
      if ls "$OUT"/*.champsimtrace >/dev/null 2>&1; then
        echo "   $OUT already holds traces:"
        ls -la "$OUT"/*.champsimtrace | awk '{print "     "$NF"  "$5}'
        die "refusing to overwrite. Move or delete them first."
      fi

      echo "== tracing canneal, $NT threads =="
      echo "   binary: $B"
      echo "   netlist: $NETS"
      echo "   args: $NT $SWAPS $TEMP $(basename "$NETS") $STEPS"
      echo "   output: $OUT/canneal*"
      echo "   capped at $MAX_INSTR instructions per thread"
      ( cd "$OUT" && setsid nice -n 10 "$PIN" -t "$TRACER" -o canneal -max_instr "$MAX_INSTR" \
          -- "$B" "$NT" "$SWAPS" "$TEMP" "$NETS" "$STEPS" \
          < /dev/null > "$HOME/trace_gen_canneal_${NT}t.log" 2>&1 & disown 2>/dev/null; echo "launched, pid $!" )
      echo "log: ~/trace_gen_canneal_${NT}t.log"
      ;;
    fluidanimate)
      # PARSEC, not SPLASH-3. The original invocation was never recorded.
      # Standard PARSEC arguments:
      #   fluidanimate <nthreads> <nframes> <input.fluid> [output.fluid]
      # The trace set is fluid0..fluid8 = 9 threads = main + 8 workers, which
      # is what `fluidanimate 8` produces. Override anything from the env.
      local B="${FLUID_BIN:-}"
      if [ -z "$B" ]; then
        for cand in "$REPO/tracer/fluidanimate" "$REPO/tracer/pin/fluidanimate" \
                    "$HOME/parsec"*/pkgs/apps/fluidanimate/inst/*/bin/fluidanimate \
                    "$HOME/parsec"*/pkgs/apps/fluidanimate/src/fluidanimate; do
          [ -x "$cand" ] && B="$cand" && break
        done
      fi
      [ -n "$B" ] && [ -x "$B" ] || \
        die "fluidanimate binary not found; run '$0 locate' then set FLUID_BIN=<path>"

      local IN="${FLUID_INPUT:-}"
      if [ -z "$IN" ]; then
        for cand in "$REPO/tracer/pin/in_100K.fluid" "$REPO/tracer/in_100K.fluid" \
                    "$HOME/parsec"*/pkgs/apps/fluidanimate/inputs/in_100K.fluid \
                    "$HOME/parsec"*/pkgs/apps/fluidanimate/run/in_*.fluid; do
          [ -f "$cand" ] && IN="$cand" && break
        done
      fi
      [ -n "$IN" ] && [ -f "$IN" ] || \
        die "fluidanimate .fluid input not found; run '$0 locate' then set FLUID_INPUT=<path>"

      local NT="${FLUID_THREADS:-8}"
      local NF="${FLUID_FRAMES:-5}"
      mkdir -p "$TRACES/fluidanimate_8t"

      echo "== tracing fluidanimate, $NT threads =="
      echo "   binary: $B"
      echo "   input:  $IN"
      echo "   args: $NT $NF $(basename "$IN")"
      echo "   capped at $MAX_INSTR instructions per thread"
      ( cd "$TRACES/fluidanimate_8t" && setsid nice -n 10 "$PIN" -t "$TRACER" -o fluid -max_instr "$MAX_INSTR" \
          -- "$B" "$NT" "$NF" "$IN" \
          < /dev/null > "$HOME/trace_gen_fluidanimate.log" 2>&1 & disown 2>/dev/null; echo "launched, pid $!" )
      echo "log: ~/trace_gen_fluidanimate.log"
      ;;
    *) die "unknown workload: $w" ;;
  esac
}

phase_locate() {
  echo "== hunting for the workload binaries and inputs =="
  echo "   (read-only; this only searches)"
  echo
  local roots="$HOME $REPO/tracer $SPLASH"
  for name in fluidanimate canneal WATER-NSQUARED OCEAN BARNES; do
    echo "-- $name"
    find $roots -maxdepth 6 -type f -name "$name" -perm -u+x 2>/dev/null | head -10 | sed 's/^/     /'
    echo
  done
  echo "-- PARSEC .fluid inputs"
  find $roots -maxdepth 7 -type f -name "*.fluid" 2>/dev/null | head -15 | sed 's/^/     /'
  echo
  echo "-- canneal .nets inputs"
  find $roots -maxdepth 7 -type f -name "*.nets" 2>/dev/null | head -15 | sed 's/^/     /'
  echo
  echo "-- any parsec tree"
  find "$HOME" -maxdepth 3 -type d -iname "*parsec*" 2>/dev/null | head -10 | sed 's/^/     /'
  echo
  echo "If fluidanimate or canneal are missing above, point the script at them:"
  echo "   FLUID_BIN=... FLUID_INPUT=... bash ~/regen_traces.sh gen fluidanimate"
  echo "   CANNEAL_BIN=... CANNEAL_NETS=... bash ~/regen_traces.sh gen canneal"
}

# Map a workload name to the process patterns it runs as, so one job can be
# stopped without touching another that is legitimately still running.
workload_patterns() {
  case "$1" in
    water)        echo '[W]ATER-NSQUARED' ;;
    ocean)        echo '[O]CEAN' ;;
    barnes)       echo '[B]ARNES' ;;
    canneal)      echo '[c]anneal' ;;
    fluidanimate) echo '[f]luidanimate' ;;
    *) return 1 ;;
  esac
}

phase_kill() {
  local label pats pids
  if [ -n "${1:-}" ]; then
    # Targeted: stop one workload. Needed because jobs overlap -- a tracer that
    # has hit its cap leaves the application running untraced while the next
    # workload is legitimately mid-run, and stopping everything would throw
    # away hours of that one.
    pats=$(workload_patterns "$1") || die "unknown workload: $1"
    label="$1"
  else
    pats="$TRACER_PATTERNS"
    label="every tracer"
  fi

  echo "== stopping $label =="
  pids=$(tracer_pids $pats)
  if [ -z "$pids" ]; then echo "   not running"; return 0; fi

  echo "   matched:"
  # shellcheck disable=SC2086
  ps -o pid,etime,args -p "$(echo $pids | tr ' ' ',')" 2>/dev/null | tail -n +2 | cut -c1-140 | sed 's/^/     /'

  # shellcheck disable=SC2086
  kill $pids 2>/dev/null
  sleep 3
  local left; left=$(tracer_pids $pats)
  if [ -n "$left" ]; then
    # shellcheck disable=SC2086
    kill -9 $left 2>/dev/null
    sleep 1
  fi

  left=$(tracer_pids $pats)
  echo "   remaining: $(echo -n "$left" | grep -c . || true)"

  if [ -n "${1:-}" ]; then
    echo
    echo "   still running elsewhere:"
    local others; others=$(tracer_pids)
    if [ -z "$others" ]; then echo "     nothing"
    else ps -o pid,args -p "$(echo $others | tr ' ' ',')" 2>/dev/null | tail -n +2 | cut -c1-120 | sed 's/^/     /'
    fi
  fi

  [ -z "$left" ] || die "$label survived; investigate before regenerating"
}

phase_disk() {
  echo "== filesystems =="
  df -h /home /tmp "$TRACES" 2>/dev/null
  echo
  echo "== trace usage =="
  du -sh "$TRACES"/* 2>/dev/null | sort -h
  echo
  echo "== total =="
  du -sh "$TRACES" 2>/dev/null
}

phase_progress() {
  echo "== running tracers =="
  local pids found=0
  pids=$(tracer_pids)
  if [ -n "$pids" ]; then
    found=1
    # shellcheck disable=SC2086
    ps -o pid,etime,pcpu,args -p "$(echo $pids | tr ' ' ',')" 2>/dev/null \
      | tail -n +2 | cut -c1-140 | sed 's/^/     /'
  fi

  # Process matching is not trustworthy on its own here: Pin runs the work
  # under the application's name, so a pattern list can always miss something.
  # Growth of the trace directory is the ground truth, so it is ALWAYS checked
  # and it wins any disagreement. A false "idle" is what let two barnes runs
  # launch at once and corrupt 576 GB.
  echo -n "   checking whether traces are still growing (5s)... "
  if traces_growing; then
    echo "YES -- a trace job IS active"
    [ "$found" -eq 0 ] && echo "   !! no process matched but traces ARE growing -- DO NOT launch anything"
  else
    echo "no growth"
    [ "$found" -eq 0 ] && echo "   idle (no matching process, no growth)"
  fi
  echo

  echo "== recent log tails =="
  for l in "$HOME"/trace_gen_*.log; do
    [ -f "$l" ] || continue
    echo "-- $(basename "$l")  (modified $(date -r "$l" '+%H:%M:%S'))"
    tail -3 "$l" | sed 's/^/     /'
  done
  echo

  echo "== trace sizes (cap is 12,800,000,000 bytes = 200M records x 64 B) =="
  for d in "$TRACES"/*_8t "$TRACES"/*_4t; do
    [ -d "$d" ] || continue
    echo "-- $(basename "$d")"
    ls -la "$d"/*.champsimtrace 2>/dev/null \
      | awk '{n=split($NF,a,"/"); printf "     %-26s %15d%s\n", a[n], $5, ($5==12800000000 ? "  <- at cap" : "")}'
  done
  ls -la "$TRACES"/*.champsimtrace 2>/dev/null \
    | awk '{n=split($NF,a,"/"); printf "     %-26s %15d%s\n", a[n], $5, ($5==12800000000 ? "  <- at cap" : "")}'
  echo
  df -h "$TRACES" | tail -1
}

phase_reclaim() {
  echo "== reclaimable space (report only; nothing is deleted yet) =="
  local total=0
  show() {
    [ -e "$1" ] || return 0
    local sz; sz=$(du -sb "$1" 2>/dev/null | cut -f1); [ -n "$sz" ] || return 0
    total=$((total + sz))
    printf "  %-58s %8s  %s\n" "$(basename "$1")" "$(numfmt --to=iec "$sz")" "$2"
  }

  echo "-- obsolete build output --"
  show "$REPO/bin"        "per-policy binaries; develop builds ONE bin/champsim"
  show "$REPO/.csconfig"  "object files, regenerated by make"
  show "$REPO/archive_logs" "archived run logs"

  echo "-- source tarballs already extracted --"
  for t in "$HOME"/*.tar.gz "$REPO/tracer/pin"/*.tar.gz; do
    [ -f "$t" ] && show "$t" "extracted already"
  done

  echo "-- stray logs --"
  for f in "$HOME"/nohup*.log "$REPO"/nohup*.log "$HOME"/pintool.log "$REPO"/pintool.log "$HOME"/trace_gen_*.log; do
    [ -f "$f" ] && show "$f" ""
  done

  echo
  echo "total reclaimable here: $(numfmt --to=iec $total)"
  echo "free on /home:          $(df -h "$HOME" | tail -1 | awk '{print $4}')"
  echo "free on /tmp:           $(df -h /tmp | tail -1 | awk '{print $4}')  ($(df -h /tmp | tail -1 | awk '{print $5}') used)"
  echo
  echo "NOTE: /tmp is a small RAM drive here and fills fast. Builds already"
  echo "      redirect temporaries to \$HOME/.build_tmp. If /tmp is full, that"
  echo "      is usually stale files from previous runs:"
  echo "        ls -la /tmp | sort -k5 -rn | head"
  echo
  echo "NOT touched: traces, simulator/results, the repo working tree, splash3 sources."
  echo "Run '$0 reclaim-go' to delete the above."
}

phase_reclaim_go() {
  echo "== deleting reclaimable build output and extracted tarballs =="
  read -r -p "Type YES to proceed: " ans
  [ "$ans" = "YES" ] || die "aborted"
  rm -rf "$REPO/bin" "$REPO/.csconfig" "$REPO/archive_logs" 2>/dev/null
  rm -f "$HOME"/*.tar.gz "$REPO/tracer/pin"/*.tar.gz 2>/dev/null
  rm -f "$HOME"/nohup*.log "$REPO"/nohup*.log "$HOME"/pintool.log "$REPO"/pintool.log 2>/dev/null
  echo "done. bin/ and .csconfig are rebuilt by 'make'."
  df -h "$HOME" | tail -1
}

phase_verify() {
  echo "== re-auditing all traces =="
  [ -f "$HOME/audit_traces.sh" ] || die "audit_traces.sh not found in \$HOME -- scp it up"
  bash "$HOME/audit_traces.sh"
}

case "${1:-}" in
  build)  phase_build ;;
  smoke)  phase_smoke ;;
  plan)   phase_plan ;;
  clean)  phase_clean ;;
  gen)    shift; phase_gen "$@" ;;
  locate) phase_locate ;;
  kill)   shift; phase_kill "$@" ;;
  disk)   phase_disk ;;
  progress) phase_progress ;;
  reclaim)    phase_reclaim ;;
  reclaim-go) phase_reclaim_go ;;
  verify) phase_verify ;;
  *) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
