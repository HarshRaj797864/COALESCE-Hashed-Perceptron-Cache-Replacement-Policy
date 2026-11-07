#!/usr/bin/env bash
# Phase B1/B2 -- run SPLASH-3 under a real MESI directory and extract the
# coherence ground truth.
#
#   scp -P 2222 scripts/run_gem5_splash.sh user@your-server:~/
#   ssh -p 2222 user@your-server 'bash ~/run_gem5_splash.sh plan'
#   ssh -p 2222 user@your-server 'bash ~/run_gem5_splash.sh smoke'    # 1 core, minutes
#   ssh -p 2222 user@your-server 'bash ~/run_gem5_splash.sh go'       # 4 and 8 cores
#   ssh -p 2222 user@your-server 'bash ~/run_gem5_splash.sh go-4c'    # 4 cores only
#   OUT=... OCEAN_GRID=514 [LLC_SIZE=8MB] [MAXINSTS=N] bash ~/run_gem5_splash.sh go-ocean-4c   # ocean 4c only
#   ssh -p 2222 user@your-server 'bash ~/run_gem5_splash.sh stats'
#
# WHY. The shared-VMEM overlay fakes sharing by aliasing pages; whether that
# resembles real coherence is unproven, and it is the question the paper now
# rests on. gem5's Ruby MESI_Two_Level models coherence properly, so the same
# workload through both gives a comparison.
#
# COMPARE RATES, NOT TOTALS. gem5 with Ruby runs orders of magnitude slower
# than Pin tracing, so a gem5 run cannot be the same length as a ChampSim one.
# Invalidations per thousand LLC accesses and the sharing-degree distribution
# are rates; they survive the difference in run length. Raw counts do not, and
# comparing them would be meaningless.
#
# THE HIERARCHY. Under MESI_Three_Level -- the build since 2026-09-24 -- all three
# levels match ChampSim: private split L0 = L1I/L1D, private unified L1 = L2C,
# shared L2 = LLC (one bank, one cluster; gem5 sizes EACH L2 bank at --l2_size,
# so keep --num-l2caches=1 or the total multiplies). Under MESI_Two_Level, what
# follows applies: only the LLC is matched.
#
# MESI_Two_Level: the LLC size is matched, the hierarchy is not. Its L2 is the
# shared last-level cache, so it is set to ChampSim's LLC -- 2 MB, 16-way by
# default, overridable to match the scaled sweep.
#
# This header used to say "CACHE GEOMETRY IS MATCHED DELIBERATELY". Only the
# LLC is. ChampSim has a private 512 KB L2 between each L1D and the LLC;
# MESI_Two_Level has no private L2 at all, so its shared cache sees every L1
# miss while ChampSim's sees only L2 misses. And the two count invalidations at
# different protocol events -- ChampSim at L2 writeback, gem5 at store request.
# See bench/policy_sanity/phaseB_metric_semantics_2026-09-23.md before
# comparing any number this script produces. A comparison against a differently
# sized cache would measure the geometry, not the overlay; that is exactly the
# confound found on 2026-09-19, where a fixed 2 MB LLC suppressed coherence
# traffic from 19% of accesses to 2.9%.
set -uo pipefail

GEM5_DIR="${GEM5_DIR:-$HOME/gem5}"
BUILD="${GEM5_BUILD:-X86}"
[ -f "$GEM5_DIR/.gem5_build_dir" ] && BUILD="$(cat "$GEM5_DIR/.gem5_build_dir")"
GEM5="$GEM5_DIR/build/$BUILD/gem5.opt"
SE="$GEM5_DIR/configs/deprecated/example/se.py"
BINS="${BINS:-$HOME/splash-static}"
# The protocol the build holds, recorded by `setup_gem5.sh rebuild`. Results go
# to a protocol-specific directory so Two_Level and Three_Level runs never mix.
PROTOCOL="${PROTOCOL:-$(cat "$GEM5_DIR/.gem5_protocol" 2>/dev/null || echo MESI_Two_Level)}"
OUT="${OUT:-$HOME/gem5_results$( [ "$PROTOCOL" = MESI_Two_Level ] || echo "_$PROTOCOL")}"

# Matched to ChampSim. LLC_SIZE overrides for the scaled comparison (2 MB per
# core: 8MB at 4 cores, 16MB at 8).
LLC_SIZE="${LLC_SIZE:-2MB}"
LLC_ASSOC="${LLC_ASSOC:-16}"
L1D_SIZE="${L1D_SIZE:-32kB}"
L1I_SIZE="${L1I_SIZE:-32kB}"
# MESI_Three_Level only: its private L0 (split) / private L1 (unified) / shared
# L2 map onto ChampSim's L1I+L1D / L2C / LLC -- matched to make_config.py:
# L1I and L1D 64 sets x 8 ways = 32 KiB, L2C 1024 x 8 = 512 KiB, LLC 2048 x 16.
L1I_ASSOC="${L1I_ASSOC:-8}"
L1D_ASSOC="${L1D_ASSOC:-8}"
L2C_SIZE="${L2C_SIZE:-512kB}"
L2C_ASSOC="${L2C_ASSOC:-8}"
CPU_TYPE="${CPU_TYPE:-TimingSimpleCPU}"
MEM_SIZE="${MEM_SIZE:-4GB}"

# Ocean grid. The traced runs use -n514, but that is ~172M instructions per
# thread and gem5+Ruby is far slower than Pin. Rates do not care about run
# length, so a smaller grid is used here; raise it if a run finishes quickly.
OCEAN_GRID="${OCEAN_GRID:-258}"
# 16384 = SPLASH-3's inputs/n16384-p4, the problem the barnes_4t traces ran. The
# comparison needs the same problem on both sides; this was 4096, picked for
# speed, before 2026-09-25. (The ocean grid below still differs from the traced
# -n514 -- an open B3 design item, docs/PLAN.md section 4.)
BARNES_BODIES="${BARNES_BODIES:-16384}"
# MAXINSTS stops the run when ANY thread has committed this many instructions
# (se.py --maxinsts -> max_insts_any_thread, configs/common/Simulation.py,
# v25.1.0.1). With randomization off gem5 is deterministic, so two runs that
# stop at 50M and 150M share their first 50M exactly, and the difference of
# their stats is the window ChampSim measures (B3; gem5_stats.sh window).
MAXINSTS="${MAXINSTS:-}"
# canneal (2026-10-06): the traced arguments, `canneal 4 15000 2000
# 100000.nets 128` (regen_traces.sh). Its main thread loads the netlist and
# then waits; the 4 workers are what the canneal_4t traces hold (threads 1..4),
# so gem5 gets threads+1 CPUs. MAXINSTS would stop on ANY thread, and the
# loader on cpu0 passes 50M before a worker starts. WORKER_MAXINSTS instead
# limits only cpu1..N through se.py --param (applied before instantiate by
# configs/common/Simulation.py, v25.1.0.1): the run stops when the first
# WORKER reaches the limit. The static binary is built and checked by
# scripts/build_canneal_static.sh.
CANNEAL_THREADS="${CANNEAL_THREADS:-4}"
CANNEAL_SWAPS="${CANNEAL_SWAPS:-15000}"
CANNEAL_TEMP="${CANNEAL_TEMP:-2000}"
CANNEAL_STEPS="${CANNEAL_STEPS:-128}"
CANNEAL_NETS="${CANNEAL_NETS:-$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy/simulator/tracer/pin/100000.nets}"
WORKER_MAXINSTS="${WORKER_MAXINSTS:-}"
# Held-out programs (b3_heldout_design_2026-10-14.md): radix, waternsq
# (water-nsquared), fmm. b3_heldout.sh writes their inputs here, with the
# random.in water-nsquared opens from its working directory.
HELDOUT_IN="${HELDOUT_IN:-$HOME/b3_heldout/inputs}"
# New benchmarks (newbench_design_2026-10-19.md): newbench_server.sh sizes each
# and records its chosen input in ~/newbench/<wl>/CHOSEN ("arguments|stdin
# file|files it needs in its directory", all under ~/newbench/<wl>/inputs);
# the static binaries are in ~/splash-newbench (BINS, set by launch_b3_gem5.sh).
NEWBENCH="${NEWBENCH:-$HOME/newbench}"
nb_name() { case "$1" in fft) echo FFT ;; lu) echo LU ;; cholesky) echo CHOLESKY ;; waterspatial) echo WATER-SPATIAL ;; raytrace) echo RAYTRACE ;; streamcluster) echo streamcluster ;; volrend) echo VOLREND ;; radiosity) echo RADIOSITY ;; lunc) echo LU-NC ;; *) return 1 ;; esac; }
# Held-out set 2 (heldout2_design_2026-11-04.md): heldout2_server.sh sizes each
# and records ~/heldout2/<wl>/CHOSEN ("input set|arguments|stdin|what the run
# needs in its directory", under ~/heldout2/<wl>/inputs/<set>/) and NCPU (one
# CPU per thread the program creates); the static binaries are in
# ~/heldout2_static (BINS, set by launch_b3_gem5.sh). A run that has not ended
# 96 h after it started is stopped (the design's limit).
HELDOUT2="${HELDOUT2:-$HOME/heldout2}"
H2_TIMEOUT="${H2_TIMEOUT:-96h}"
h2_name() { case "$1" in fluidanimate|bodytrack|facesim|vips) echo "$1" ;; oceannc) echo OCEAN-NC ;; *) return 1 ;; esac; }

die() { echo "ERROR: $*" >&2; exit 1; }

# barnes's input, SPLASH-3 inputs/n16384-p4 with nbody and NPROC substituted
# (the format is explained in run_one). A function, so the native diagnosis
# (`barnes-input`) feeds the binary exactly what a gem5 run would.
write_barnes_in() {   # $1 file  $2 threads
  cat > "$1" << EOF

$BARNES_BODIES
123

0.025
0.05
1.0
2.0
5.0
0.075
0.25
$2
EOF
}

preflight() {   # [static binaries this launch needs; default OCEAN BARNES]
  local need="${*:-OCEAN BARNES}"
  [ -x "$GEM5" ] || die "no gem5 binary at $GEM5 -- is the build finished? (setup_gem5.sh status)"
  [ -f "$SE" ]   || die "no se.py at $SE"
  local n
  n=$(strings -a "$GEM5" 2>/dev/null | grep -c "${PROTOCOL}_L1Cache_Controller")
  [ "${n:-0}" -gt 0 ] || die "gem5 has no $PROTOCOL protocol compiled in"
  if [ "$PROTOCOL" = MESI_Three_Level ]; then
    # grep -c, not grep -q: under pipefail, grep -q exits on the first match,
    # strings dies of SIGPIPE (141) writing the rest of a ~950 MB binary, and
    # the pipeline reports failure for a string it found. That refused the real
    # Three_Level build on 2026-09-25; a small fake binary could not show it.
    n=$(strings -a "$GEM5" 2>/dev/null | grep -c "MESI_Three_Level_L0Cache_Controller")
    [ "${n:-0}" -gt 0 ] || die "gem5 has no MESI_Three_Level L0 controller -- the build is not Three_Level"
    # The L0<->L1 strict-FIFO check is a known false alarm that killed ocean_4c
    # after days (2026-09-27); setup_gem5.sh patch-fifo explains why turning it
    # off changes no result. Refuse to spend days on a run that can die of it.
    n=$(grep -c 'ordered=False)  # COALESCE: setup_gem5.sh patch-fifo' "$GEM5_DIR/configs/ruby/MESI_Three_Level.py" 2>/dev/null)
    [ "${n:-0}" = 2 ] || die "MESI_Three_Level.py is not patched ($n of 2 lines) -- run: bash ~/setup_gem5.sh patch-fifo"
  fi
  for b in $need; do
    [ -x "$BINS/$b" ] || die "no $BINS/$b -- run build_splash_static.sh"
    file -b "$BINS/$b" | grep -q "statically linked" \
      || die "$BINS/$b is not statically linked; gem5 SE mode needs static"
  done
}

# $1 workload  $2 cores  $3 tag
run_one() {
  local wl="$1" nc="$2" tag="$3"
  local odir="$OUT/$tag" live
  # Never start a second gem5 on an outdir one is already writing: both would
  # write the same stats.txt and run.log. go-4c relaunched onto a running ocean
  # run would have done exactly that.
  live=$(pgrep -u "$(id -u)" -f "[g]em5.opt --outdir=$odir " 2>/dev/null | head -1)
  if [ -n "$live" ]; then echo "   $tag: already running (pid $live) -- left alone"; return 0; fi
  # Keep a previous run's output rather than overwrite it.
  if [ -e "$odir/run.log" ]; then
    local keep; keep="$odir.prev_$(date +%Y%m%d_%H%M%S)"
    mv "$odir" "$keep" && echo "   $tag: previous run kept as $(basename "$keep")"
  fi
  mkdir -p "$odir"
  local prog args="" nb_sin="" nb_files="" h2_set="" tmo=() wsl=""
  case "$wl" in
    # NOTE the --options= form below, not -o "...". se.py defines short
    # options including -n, so argparse claims the '-n66' inside the workload
    # arguments as se.py's own -n with value 66, leaving -o with nothing and
    # failing "argument -o/--options: expected one argument". The = form binds
    # the value unambiguously. Reproduced exactly with a two-option parser.
    ocean)  prog="$BINS/OCEAN";  args="-n$OCEAN_GRID -p$nc -e1e-7 -r20000 -t28800" ;;
    barnes) prog="$BINS/BARNES"; args="" ;;   # reads its input on stdin
    canneal)
      prog="$BINS/CANNEAL"
      [ -x "$prog" ] && file -b "$prog" | grep -q "statically linked" || die "no static $prog -- build it with scripts/build_canneal_static.sh and upload it"
      [ -f "$CANNEAL_NETS" ] || die "no netlist at $CANNEAL_NETS"
      args="$CANNEAL_THREADS $CANNEAL_SWAPS $CANNEAL_TEMP $CANNEAL_NETS $CANNEAL_STEPS" ;;
    radix)    prog="$BINS/RADIX";          args="-p$nc -n16777216 -r1024" ;;
    waternsq) prog="$BINS/WATER-NSQUARED"; args="" ;;   # reads its input on stdin, and random.in
    fmm)      prog="$BINS/FMM";            args="" ;;   # reads its input on stdin, writes ./times
    fft|lu|cholesky|waterspatial|raytrace|streamcluster|volrend|radiosity|lunc)
      [ -f "$NEWBENCH/$wl/CHOSEN" ] || die "no $NEWBENCH/$wl/CHOSEN -- newbench_server.sh size has not sized $wl"
      prog="$BINS/$(nb_name "$wl")"
      IFS='|' read -r args nb_sin nb_files < "$NEWBENCH/$wl/CHOSEN" ;;
    fluidanimate|bodytrack|facesim|vips|oceannc)
      [ -f "$HELDOUT2/$wl/CHOSEN" ] || die "no $HELDOUT2/$wl/CHOSEN -- heldout2_server.sh has not sized $wl"
      prog="$BINS/$(h2_name "$wl")"
      IFS='|' read -r h2_set args nb_sin nb_files < "$HELDOUT2/$wl/CHOSEN"
      tmo=(timeout "$H2_TIMEOUT")
      # The worker stop watches the traced threads' CPUs, CPU 0 aside (its
      # count holds main's serial start), not every CPU past 0: bodytrack's
      # image loader (CPU 5) executes 60 M instructions while the workers are
      # under 40 M, and would trip the 50 M stop (Note 3). Thread t runs on
      # CPU t; the traced CPUs past 0 must be one contiguous range.
      local h2t lo hi
      h2t=$(awk -F'|' 'NR == 1 { print $6 }' "$HELDOUT2/$wl/PROGS" 2>/dev/null)
      [ -n "$h2t" ] || die "no traced threads in $HELDOUT2/$wl/PROGS"
      lo=$(tr ' ' '\n' <<< "$h2t" | awk '$1 > 0' | sort -n | head -1); hi=$(tr ' ' '\n' <<< "$h2t" | sort -n | tail -1)
      [ -n "$lo" ] && [ "$(tr ' ' '\n' <<< "$h2t" | awk '$1 > 0' | wc -l)" = $((hi - lo + 1)) ] || die "$wl's traced CPUs past 0 ($h2t) are not one range"
      wsl="$lo:$((hi + 1))" ;;
    *) die "unknown workload $wl" ;;
  esac
  # The held-out programs run from their output directory, with their input
  # copied there: water-nsquared opens random.in, and fmm writes "times", in
  # the working directory, which under gem5 SE is the host's.
  local workdir="$GEM5_DIR"
  case "$wl" in
    waternsq|fmm)
      [ -f "$HELDOUT_IN/$wl.in" ] || die "no $HELDOUT_IN/$wl.in -- b3_heldout.sh writes it"
      cp "$HELDOUT_IN/$wl.in" "$odir/$wl.in"
      [ "$wl" != waternsq ] || cp "$HELDOUT_IN/random.in" "$odir/random.in" || die "no $HELDOUT_IN/random.in"
      workdir="$odir" ;;
    radix) workdir="$odir" ;;
    # the new benchmarks run from their output directory with the files their
    # chosen input needs (raytrace's .env/.geo, water-spatial's random.in)
    fft|lu|cholesky|waterspatial|raytrace|streamcluster|volrend|radiosity|lunc)
      for f in $nb_files; do
        if [ -f "$NEWBENCH/$wl/inputs/$f" ]; then cp "$NEWBENCH/$wl/inputs/$f" "$odir/$f" || die "could not copy $f"
        elif [ ! -f "$NEWBENCH/$wl/inputs/$f.absent" ]; then die "no $NEWBENCH/$wl/inputs/$f"; fi
      done
      if [ -n "$nb_sin" ]; then cp "$NEWBENCH/$wl/inputs/$nb_sin" "$odir/$nb_sin" || die "no $NEWBENCH/$wl/inputs/$nb_sin"; fi
      workdir="$odir" ;;
    # held-out set 2: the chosen set's files and directories (bodytrack's
    # sequence, facesim's Face_Data), copied, since the programs write beside them
    fluidanimate|bodytrack|facesim|vips|oceannc)
      for f in $nb_files; do cp -rp "$HELDOUT2/$wl/inputs/$h2_set/$f" "$odir/" || die "could not copy $HELDOUT2/$wl/inputs/$h2_set/$f"; done
      if [ -n "$nb_sin" ]; then cp "$HELDOUT2/$wl/inputs/$h2_set/$nb_sin" "$odir/$nb_sin" || die "no $HELDOUT2/$wl/inputs/$h2_set/$nb_sin"; fi
      workdir="$odir" ;;
  esac

  # barnes takes its parameters on stdin, so they go in a file passed with -i.
  # The format is SPLASH-3's own inputs/n16384-p4 -- the file the barnes_4t
  # traces were generated with -- read with cat -A ON THE SERVER (2026-09-25):
  # 12 lines. Line 1 is the input FILE NAME, blank = generate a Plummer model;
  # then nbody, seed, output file (blank = none), dtime, eps, tol, fcells,
  # fleaves, tstop, dtout, NPROC. Only nbody and NPROC are substituted.
  # Two earlier versions were wrong. Both lacked the blank first line -- the
  # second was copied from a web rendering that silently dropped it -- so barnes
  # took the body count as a file name: the static build aborted in
  # getparam("in") (strcpy overflow), the traced build segfaulted opening it.
  local stdin_arg=()
  local stdin_file=/dev/null
  if [ "$wl" = barnes ]; then
    write_barnes_in "$odir/barnes.in" "$nc"
    stdin_arg=(-i "$odir/barnes.in"); stdin_file="$odir/barnes.in"
  elif [ "$wl" = waternsq ] || [ "$wl" = fmm ]; then
    stdin_arg=(-i "$odir/$wl.in"); stdin_file="$odir/$wl.in"
  elif [ -n "${nb_sin:-}" ]; then
    stdin_arg=(-i "$odir/$nb_sin"); stdin_file="$odir/$nb_sin"
  fi

  # Cache arguments by protocol. MESI_Two_Level has no private L2: its L1 is
  # ChampSim's L1 and its shared L2 is the LLC. MESI_Three_Level matches all
  # three levels: --l0* are the private split L1s, --l1d_* the private unified
  # L2C, --l2_* the shared LLC (options from gem5 v25.1.0.1
  # configs/ruby/MESI_Three_Level.py and configs/common/Options.py).
  local caches
  case "$PROTOCOL" in
    MESI_Three_Level)
      caches="--l0i_size=$L1I_SIZE --l0i_assoc=$L1I_ASSOC --l0d_size=$L1D_SIZE --l0d_assoc=$L1D_ASSOC"
      caches="$caches --l1d_size=$L2C_SIZE --l1d_assoc=$L2C_ASSOC"
      caches="$caches --l2_size=$LLC_SIZE --l2_assoc=$LLC_ASSOC --num-l2caches=1 --num-clusters=1" ;;
    *)
      caches="--l1d_size=$L1D_SIZE --l1i_size=$L1I_SIZE --l2_size=$LLC_SIZE --l2_assoc=$LLC_ASSOC --num-l2caches=1" ;;
  esac
  # Run the workload natively for 20 s before giving it to gem5. A binary that
  # dies on its input dies the same way under gem5, just hours later to notice;
  # barnes did, twice, on 2026-09-25. 124 = still running at 20 s = fine.
  local rc
  ( cd "$odir" && timeout 20 "$prog" $args < "$stdin_file" ) > "$odir/native_check.log" 2>&1
  rc=$?
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "   $tag: FAILS NATIVELY (rc=$rc) -- gem5 not launched. Last lines:"
    grep -v '^\s*$' "$odir/native_check.log" | tail -3 | sed 's/^/      /'
    return 1
  fi
  echo "   $tag: native check ok (rc=$rc)"
  echo "   $tag: $wl on $nc core(s), $PROTOCOL, LLC $LLC_SIZE/$LLC_ASSOC-way${MAXINSTS:+, stop at $MAXINSTS instructions (any thread)}${WORKER_MAXINSTS:+, stop when a worker (cpu[${wsl:-1:$nc}]) reaches $WORKER_MAXINSTS}"
  # nice 19, as the ChampSim jobs: gem5 shares the machine, it does not outrank it.
  #
  # The & applies to the gem5 command ALONE. It was `cd ... && setsid ... &`,
  # and a trailing & backgrounds the whole && list as a subshell. That
  # subshell kept our stdout -- the launcher's pipe to sed -- open while it
  # waited for gem5, so launch_b3_gem5.sh could not start run N+1 until run N
  # ENDED. The B3 ocean and barnes runs went one after another, and canneal
  # stalled on its first run (2026-10-06). The results are unaffected: gem5
  # is deterministic. Tested: through a pipe, the old form held the pipe for
  # the child's whole life (8 s for an 8 s child), the new form 3 ms. $! is
  # now gem5's own pid, in its own session.
  # shellcheck disable=SC2086 -- $caches is a list of options
  ( cd "$workdir" || exit 1
    setsid nice -n 19 ${tmo[@]+"${tmo[@]}"} "$GEM5" --outdir="$odir" "$SE" \
      --ruby \
      --num-cpus="$nc" \
      --cpu-type="$CPU_TYPE" \
      --mem-size="$MEM_SIZE" \
      $caches \
      ${MAXINSTS:+--maxinsts=$MAXINSTS} \
      ${WORKER_MAXINSTS:+--param "system.cpu[${wsl:-1:$nc}].max_insts_any_thread = $WORKER_MAXINSTS"} \
      -c "$prog" ${args:+--options="$args"} "${stdin_arg[@]}" \
      < /dev/null > "$odir/run.log" 2>&1 &
    echo "      pid $!" )
}

phase_plan() {
  echo "== gem5 SPLASH-3 characterization =="
  echo "   gem5:      $GEM5"
  echo "   protocol:  $PROTOCOL"
  [ -x "$GEM5" ] && echo "              (built)" || echo "              (NOT BUILT YET)"
  echo "   se.py:     $SE"
  echo "   binaries:  $BINS"
  echo "   results:   $OUT"
  echo
  echo "   LLC (Ruby L2): $LLC_SIZE, $LLC_ASSOC-way, 1 bank -- matched to ChampSim"
  if [ "$PROTOCOL" = MESI_Three_Level ]; then
    echo "   L1 (Ruby L1):  $L2C_SIZE, $L2C_ASSOC-way, private -- ChampSim L2C"
    echo "   L0 (Ruby L0):  $L1D_SIZE/$L1D_ASSOC-way data, $L1I_SIZE/$L1I_ASSOC-way inst -- ChampSim L1D/L1I"
  else
    echo "   L1:            $L1D_SIZE data / $L1I_SIZE inst (no private L2 -- ChampSim has one)"
  fi
  echo "   CPU:           $CPU_TYPE"
  echo "   ocean grid:    $OCEAN_GRID    barnes bodies: $BARNES_BODIES"
  echo
  echo "   runs: ocean 4c, ocean 8c, barnes 4c, barnes 8c"
  echo
  echo "   Rates are what get compared, not totals -- gem5+Ruby is far slower"
  echo "   than Pin, so these runs are deliberately shorter than the traced ones."
}

phase_smoke() {
  preflight
  mkdir -p "$OUT"
  echo "== smoke: ocean, 1 core =="
  echo "   proves SE mode runs a static SPLASH binary under Ruby at all,"
  echo "   before spending hours on the multi-core runs."
  OCEAN_GRID=66 run_one ocean 1 smoke_ocean_1c
  echo
  echo "   watch: tail -f $OUT/smoke_ocean_1c/run.log"
  echo "   done when stats.txt appears in that directory."
}

phase_go() {
  preflight
  mkdir -p "$OUT"
  echo "== characterization runs =="
  run_one ocean  4 ocean_4c
  run_one ocean  8 ocean_8c
  run_one barnes 4 barnes_4c
  run_one barnes 8 barnes_8c
  echo
  echo "   check with: bash $0 stats"
}

# The 4-core runs only. barnes 4c is the one gem5 run with a ChampSim
# counterpart in the evaluation (barnes_4t); the 8-core runs are the slowest
# and pair with nothing there, so on a loaded machine they wait.
phase_go_4c() {
  preflight
  mkdir -p "$OUT"
  echo "== characterization runs, 4 cores only =="
  run_one ocean  4 ocean_4c
  run_one barnes 4 barnes_4c
  echo
  echo "   check with: bash $0 stats"
}

phase_stats() {
  echo "== gem5 runs =="
  local d
  for d in "$OUT"/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"   # the glob leaves a trailing /, gem5's --outdir has none
    case "$d" in *.prev_*) continue ;; esac   # superseded runs, kept for the record
    local name; name=$(basename "$d")
    # gem5 creates stats.txt when it STARTS, so its existence proves nothing:
    # on 2026-09-25 a run that died at once showed as "complete (0 lines)".
    # A run is finished only when gem5 printed its exit line; the reason and
    # the instruction count then say whether it ran the program or quit early.
    local why insts pid
    why=$(grep -m1 -oE "Exiting @ tick [0-9]+ because .*" "$d/run.log" 2>/dev/null)
    pid=$(pgrep -u "$(id -u)" -f "[g]em5.opt --outdir=$d" 2>/dev/null | head -1)
    if [ -n "$why" ]; then
      insts=$(grep -m1 -E '^simInsts ' "$d/stats.txt" 2>/dev/null | awk '{print $2}')
      printf '   %-18s ENDED    %s  simInsts=%s\n' "$name" "${why#Exiting @ }" "${insts:-none}"
    elif [ -n "$pid" ]; then
      printf '   %-18s running  (pid %s)\n' "$name" "$pid"
    else
      printf '   %-18s FAILED   -- last line: %s\n' "$name" "$(grep -v '^\s*$' "$d/run.log" 2>/dev/null | tail -1 | cut -c1-110)"
    fi
  done
  echo
  echo "   Ruby coherence counters live in stats.txt under"
  echo "   ruby_system.L1Cache_Controller.* and .L2Cache_Controller.*"
  [ "$PROTOCOL" = MESI_Three_Level ] && echo "   (MESI_Three_Level also has .L0Cache_Controller.* -- the private L1s)"
  echo "   Extraction into ChampSim-comparable rates is the next script."
}

case "${1:-}" in
  plan)  phase_plan ;;
  smoke) phase_smoke ;;
  go)    phase_go ;;
  go-4c) phase_go_4c ;;
  go-ocean-4c) preflight; mkdir -p "$OUT"; run_one ocean 4 ocean_4c ;;
  go-barnes-4c) preflight; mkdir -p "$OUT"; run_one barnes 4 barnes_4c ;;
  go-canneal-4c) preflight; mkdir -p "$OUT"; run_one canneal $((CANNEAL_THREADS + 1)) canneal_4c ;;
  # 8 workers + the loader (b3_canneal8_design_2026-10-14.md): the canneal_8t
  # traces' arguments, `canneal 8 15000 2000 100000.nets 128`
  go-canneal-8c) preflight; mkdir -p "$OUT"; CANNEAL_THREADS=8; run_one canneal 9 canneal_8c ;;
  go-radix-4c)    preflight RADIX;          mkdir -p "$OUT"; run_one radix 4 radix_4c ;;
  go-waternsq-4c) preflight WATER-NSQUARED; mkdir -p "$OUT"; run_one waternsq 4 waternsq_4c ;;
  go-fmm-4c)      preflight FMM;            mkdir -p "$OUT"; run_one fmm 4 fmm_4c ;;
  # the new benchmarks (newbench_design_2026-10-19.md): SPLASH-3 on 4 CPUs;
  # streamcluster on 5 (main + 4 workers), as canneal
  go-fft-4c|go-lu-4c|go-cholesky-4c|go-waterspatial-4c|go-raytrace-4c|go-volrend-4c|go-radiosity-4c|go-lunc-4c)
    wl=${1#go-}; wl=${wl%-4c}; preflight "$(nb_name "$wl")"; mkdir -p "$OUT"; run_one "$wl" 4 "${wl}_4c" ;;
  go-streamcluster-4c) preflight streamcluster; mkdir -p "$OUT"; run_one streamcluster 5 streamcluster_4c ;;
  # held-out set 2 (heldout2_design_2026-11-04.md): one CPU per thread the
  # program creates (NCPU: fluidanimate 5, bodytrack 6, facesim 4, vips 7,
  # ocean non-contiguous 4)
  go-fluidanimate-4c|go-bodytrack-4c|go-facesim-4c|go-vips-4c|go-oceannc-4c)
    wl=${1#go-}; wl=${wl%-4c}
    [ -f "$HELDOUT2/$wl/NCPU" ] || die "no $HELDOUT2/$wl/NCPU -- heldout2_server.sh has not sized $wl"
    preflight "$(h2_name "$wl")"; mkdir -p "$OUT"; run_one "$wl" "$(cat "$HELDOUT2/$wl/NCPU")" "${wl}_4c" ;;
  barnes-input) [ -n "${2:-}" ] || die "usage: $0 barnes-input FILE [threads]"; write_barnes_in "$2" "${3:-4}"; echo "wrote $2" ;;
  stats) phase_stats ;;
  *) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
