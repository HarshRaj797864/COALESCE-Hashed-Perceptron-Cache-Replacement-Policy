#!/usr/bin/env bash
# Run everything Phase A still owes, unattended and across reboots.
#
#   bash ~/run_phase_a.sh plan            # list jobs, run nothing
#   bash ~/run_phase_a.sh go              # launch, detached
#   bash ~/run_phase_a.sh install-resume  # restart the queue automatically after a reboot
#   bash ~/run_phase_a.sh status
#   bash ~/run_phase_a.sh results
#
#   # relaunch one policy family on a given binary, into results/phaseA_<tag>
#   ONLY_POLICIES="coalesce coalesce_no_mesi coalesce_no_sharer" BIN=... \
#     WORKLOADS=... REGIMES=... [SCALED=1] bash ~/run_phase_a.sh go-tag <tag>
#   # ocean on the 4-thread set (ocean_4t); 8 is the default
#   WORKLOADS=ocean OCEAN_CORES=4 ... bash ~/run_phase_a.sh go-tag <tag>
#   # keep only some core counts (canneal is queued at 4, 8 and 16)
#   WORKLOADS=canneal ONLY_CORES=4 ... bash ~/run_phase_a.sh go-tag <tag>
#   # private-cache coherence 1 or 2 (B3 v4); 0 or unset is the simulator as it was
#   COHERENCE=2 ... bash ~/run_phase_a.sh go-tag <tag>
#   bash ~/run_phase_a.sh plan-tag|status-tag|results-tag|install-resume <tag>
#
# TRACE SELECTION. The previous runner padded its mix to the core count by
# cycling the available traces. Under the shared-VMEM overlay two cores running
# the same trace touch identical addresses and alias by construction, which
# manufactures sharing whether or not the workload has any -- the published
# 8-core mix was canneal_big{0,1,2,3,4,0,1,2}. Here each core gets a DISTINCT
# thread of one parallel run, and a job that cannot be given distinct traces is
# refused, never padded.
#
# WHY THIS SCRIPT SURVIVES REBOOTS. The first attempt (2026-09-17 05:56) was
# killed at 07:51 when the machine crashed -- `last` records the 09:49 boot with
# no matching shutdown. Every log ended mid-line, which is unflushed page cache
# lost on an unclean halt, and the machine then sat idle for 19 hours because
# nothing restarted the queue. `install-resume` fixes that half.
set -uo pipefail

R="$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy"
S="$R/simulator"
# These must honour the environment. They did not, and a quick pass launched
# with STATE=... in its environment silently read the FULL 52-job queue, wrote
# its progress into the full sweep's log, and overwrote the full sweep's driver
# lock. An unconditional assignment is not a default.
STATE="${STATE:-$HOME/.phase_a}"
QUEUE="${QUEUE:-$STATE/queue.txt}"
RUNLOG="${RUNLOG:-$STATE/run.log}"
LOCK="${LOCK:-$STATE/driver.pid}"

RESULTS_ROOT="${RESULTS_ROOT:-$S/results/phaseA}"
WARMUP="${WARMUP:-50000000}"
SIM="${SIM:-100000000}"
MAXJOBS="${MAXJOBS:-14}"
# Which binary a queue runs, and which policies it keeps. The defaults are the
# whole sweep on bin/champsim. They exist so one policy family can be relaunched
# on a rebuilt binary into a results tree of its own (go-tag) without rerunning
# the other policies -- the COALESCE relaunch after the ghost-tag fix.
BIN="${BIN:-$S/bin/champsim}"
ONLY_POLICIES="${ONLY_POLICIES:-}"
# ONLY_CORES keeps those core counts' jobs, as ONLY_POLICIES keeps policies.
# canneal is queued at 4, 8 and 16 cores; B3 v2 compares canneal at 4 only
# (2026-10-06), and its 16-core LRU job alone is 12-36 h.
ONLY_CORES="${ONLY_CORES:-}"

# ChampSim prints "<phase> complete CPU <n>" per CPU, so "Simulation complete"
# appears as soon as the FIRST core finishes and says nothing about the rest.
# The run is only over at main.cc's final line.
DONE_MARKER="ChampSim completed all CPUs"

ALL_POLICIES="lru srrip drrip ship hawkeye mockingjay srrip_bias random coalesce coalesce_no_mesi coalesce_no_sharer"

die() { echo "ERROR: $*" >&2; exit 1; }
count() { local n; n=$(grep -c "$1" "$2" 2>/dev/null); echo "${n:-0}"; }

# Resolve a trace stem to an actual file, preferring uncompressed.
#
# ChampSim reads .xz natively, so traces not in active use can be compressed to
# reclaim disk -- water_8t alone is 96 GB and compresses to roughly a quarter of
# that. Trace selection previously built exact .champsimtrace paths, so
# compressing anything silently removed it from every job's reach.
resolve_trace() {
  local stem="$1"
  if [ -f "$stem.champsimtrace" ]; then echo "$stem.champsimtrace"; return 0; fi
  if [ -f "$stem.champsimtrace.xz" ]; then echo "$stem.champsimtrace.xz"; return 0; fi
  return 1
}

# Instruction records a trace holds. One record is 64 bytes.
#
# For .xz this reads the stream index rather than decompressing -- these expand
# to ~10 GB each and a full decompression per job would cost more than the runs.
trace_records() {
  local f="$1" bytes
  case "$f" in
    *.xz) bytes=$(xz --robot -l "$f" 2>/dev/null | awk -F'\t' '$1=="totals"{print $5}') ;;
    *)    bytes=$(stat -c %s "$f" 2>/dev/null) ;;
  esac
  [ -n "$bytes" ] && echo $((bytes / 64)) || echo 0
}

# How far the fastest core outruns the slowest, per workload, x100.
#
# A core is NOT stopped when it reaches its instruction target. champsim.cc:141
# sets its phase-complete flag, but the phase ends only once every core's flag
# is set, and a finished core keeps being ticked while it waits. So the fastest
# core consumes WARMUP+SIM scaled by this ratio, and the trace it needs is that
# much longer than the nominal figure.
#
# MEASURED, NOT GUESSED -- from 105 completed runs on 2026-09-21, recorded in
# bench/policy_sanity/wrap_diagnosis_2026-09-21.txt. Observed maxima:
#
#     canneal  1.07x    barnes  1.08x    ocean  1.10x    water  1.37x
#
# water is the outlier and is also strongly policy-dependent (LRU 1.09x,
# Mockingjay and COALESCE 1.26x), because a policy that raises IPC unevenly
# across cores widens the gap. The margins below round the observed maximum up,
# so they are floors, not predictions -- a new policy or a larger LLC can push
# past them. A bigger LLC already did: the same water jobs consumed 193M in the
# 2 MB sweep and 205M in the scaled one.
#
# This is why the post-run check matters more than this one. A preflight can
# only refuse what it can predict; "Reached end of trace" in the log is ground
# truth, and server_status.sh reports it.
trace_margin_pct() {
  case "$1" in
    water)   echo 150 ;;
    ocean)   echo 120 ;;
    canneal) echo 115 ;;
    barnes)  echo 115 ;;
    *)       echo 150 ;;   # unknown workload: assume the worst seen
  esac
}

# Refuse a job whose trace cannot supply warmup + simulation instructions, with
# the margin above.
#
# main.cc sets repeat = simulation_given, and repeatable::operator() silently
# reopens a trace at EOF, so a short trace does not fail -- it WRAPS. ocean was
# ~45.3M records against the 150M a 50M+100M run consumes, so every ocean job in
# the first sweep replayed its trace 3.3 times, re-touching the same addresses.
# Under the overlay the cores wrap in near-lockstep, manufacturing both reuse
# and sharing. Nothing warned; it took reading main.cc to find.
#
# The bare WARMUP+SIM version of this check passed water (200M records per file)
# and ocean (172M) and both wrapped anyway, because it was a single-core rule
# applied to multi-core runs.
check_trace_length() {
  local f="$1" w="${2:-}" need have margin
  margin=$(trace_margin_pct "$w")
  need=$(( (WARMUP + SIM) * margin / 100 ))
  have=$(trace_records "$f")
  if [ "$have" -lt "$need" ]; then
    echo "SHORT:$(basename "$f") has $have records; ${w:-unknown} at $((WARMUP + SIM)) nominal needs $need (${margin}% margin for core divergence)"
    return 1
  fi
  return 0
}

traces_for() {
  local w="$1" n="$2" i out=""
  case "$w" in
    canneal)
      local d="$S/traces/canneal_${n}t"
      [ -d "$d" ] || { echo "MISSING:$d"; return 1; }
      # thread 0 loads the 100,000-element netlist and reads 54.6% memory
      # operands against 57.5-58.3% for the workers, so use 1..n
      local f
      for ((i = 1; i <= n; i++)); do
        f=$(resolve_trace "$d/canneal$i") || { echo "MISSING:$d/canneal$i"; return 1; }
        check_trace_length "$f" "$w" || { check_trace_length "$f" "$w"; return 1; }
        out="$out $f"
      done ;;
    ocean|water)
      # One trace set per thread count: ${w}_<n>t, from a -p<n> run. Taking n
      # threads of a larger run would be a different experiment. All n
      # threads are used: SPLASH's main thread is processor 0 and does a full
      # share of the work, unlike canneal's loader thread. ocean_4t was traced
      # 2026-10-01 (grid 514, 200M records per thread).
      local d="$S/traces/${w}_${n}t"
      [ -d "$d" ] || { echo "MISSING:$w has no ${n}-thread trace set ($d)"; return 1; }
      local f
      for ((i = 0; i < n; i++)); do
        f=$(resolve_trace "$d/${w}$i") || { echo "MISSING:$d/${w}$i"; return 1; }
        check_trace_length "$f" "$w" || { check_trace_length "$f" "$w"; return 1; }
        out="$out $f"
      done ;;
    barnes)
      [ "$n" -eq 4 ] || { echo "MISSING:barnes exists only as a 4-thread run"; return 1; }
      local f
      for ((i = 0; i < 4; i++)); do
        f=$(resolve_trace "$S/traces/barnes_4t$i") || { echo "MISSING:barnes_4t$i"; return 1; }
        check_trace_length "$f" "$w" || { check_trace_length "$f" "$w"; return 1; }
        out="$out $f"
      done ;;
    *) echo "MISSING:unknown workload $w"; return 1 ;;
  esac
  echo "${out# }"
}

job_outdir() { echo "$RESULTS_ROOT/regime_$4/$2_${3}core/$1"; }
job_log()    { echo "$(job_outdir "$@")/run.log"; }
job_done()   { [ -s "$(job_log "$@")" ] && grep -q "$DONE_MARKER" "$(job_log "$@")" 2>/dev/null; }

# policy|workload|cores|regime, deduplicated.
#
# The first version keyed output directories on policy/workload/cores/regime but
# queued tier 3's LRU rows on top of tiers 1 and 2, which already cover them.
# Four pairs of identical jobs therefore ran concurrently writing the SAME log:
# 15 jobs started, 12 files existed. Deduplicating the queue fixes it at the
# source; adding the tier to the path would only have hidden it behind
# duplicated compute.
build_queue() {
  mkdir -p "$STATE"
  local tmp="$STATE/.q"
  : > "$tmp"
  local n rg p
  # Workloads in the sweep.
  #
  # water and ocean are OUT as of 2026-09-21, and not because they were
  # unfavourable -- because neither trace set can supply a clean 8-core run.
  # Both sit inside the core-divergence margin measured in
  # bench/policy_sanity/trace_wrap_2026-09-21.md: water needs ~205M records
  # against 200M, ocean ~172.6M against a 171.8M shortest file. Being *near*
  # the edge is the problem, not being under it: whether a run wraps then
  # depends on the policy (LRU diverges 1.09x on water, Mockingjay and COALESCE
  # 1.26x), and a wrapped run replays its trace, inflating reuse and IPC. That
  # would bias the comparison toward the policies under evaluation.
  #
  # Recoverable, in principle, by regenerating longer -- 8 files x 16 GB = 128 GB
  # against 56 GB free -- or by shortening the run for these two workloads only
  # and reporting them as a separate row. Neither is worth it for a workload
  # that was already marginal to the argument. canneal carries the headline
  # claims and barnes is the cross-check.
  #
  # Set WORKLOADS to put them back; the preflight will refuse them until the
  # traces are long enough, which is the intended behaviour.
  local WL="${WORKLOADS:-canneal barnes}"
  in_wl() { case " $WL " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

  # Regimes the ELEVEN-POLICY comparison is run in. Default "shared" preserves
  # the original queue.
  #
  # REGIMES="shared private" is the tool's headline experiment and it has never
  # been run. Every private-regime run in every sweep so far is LRU, because the
  # private rows existed only to show the overlay was off -- invalidation
  # scaling is a memory-system property, so one policy sufficed for that.
  #
  # But the claim the overlay exists to test is not "sharing happens now", it
  # is "policy rankings under sharing differ from what multi-programmed
  # evaluation reports". That needs the same eleven policies on the same traces
  # in both regimes, with nothing changing but whether cores alias onto the same
  # physical pages. Without it the instrument has been built and validated and
  # never used to answer a question only it can answer.
  #
  # Either outcome is publishable: rankings differ, and multi-programmed
  # evaluation misranks policies under sharing; rankings match, and the overlay
  # does not change conclusions, which is worth knowing and honest.
  local RG="${REGIMES:-shared}"
  # ocean's core count. 8 is the original set, which wraps at 8 cores and is
  # out of the evaluation; OCEAN_CORES=4 uses ocean_4t (2026-10-01).
  local OC="${OCEAN_CORES:-8}"

  # the overlay re-validation: invalidation scaling is a property of the memory
  # system, not the replacement policy, so one policy suffices
  in_wl canneal && for n in 4 8 16; do for rg in shared private; do echo "lru|canneal|$n|$rg" >> "$tmp"; done; done
  # the blind-spot finding across every workload
  for rg in shared private; do
    in_wl ocean  && echo "lru|ocean|$OC|$rg"  >> "$tmp"
    in_wl water  && echo "lru|water|8|$rg"  >> "$tmp"
    in_wl barnes && echo "lru|barnes|4|$rg" >> "$tmp"
  done
  # the eleven-policy comparison, in each requested regime
  local rg2
  for p in $ALL_POLICIES; do
    for rg2 in $RG; do
      in_wl canneal && echo "$p|canneal|8|$rg2" >> "$tmp"
      in_wl ocean   && echo "$p|ocean|$OC|$rg2"   >> "$tmp"
      in_wl water   && echo "$p|water|8|$rg2"   >> "$tmp"
      in_wl barnes  && echo "$p|barnes|4|$rg2"  >> "$tmp"
    done
  done

  # canneal at 4 and 16 cores for every policy, to reproduce the HiPC tables.
  #
  # The submitted paper reports canneal at 4c and 8c across eight policies and
  # 16c for COALESCE alone. 8c and barnes 4c are already covered above; these
  # fill in the rest. canneal is the workload the headline claims rest on, and
  # the 4->8->16 scaling argument needs every point measured the same way.
  #
  # NOT reproduced, and the reasons are not interchangeable:
  #   ocean 4-core    we only ever traced ocean at 8 threads, and taking 4 of
  #                   those 8 is a different experiment. It needs a -p4 run.
  #   fluidanimate    no binary and no PARSEC tree anywhere on the server; the
  #                   workload is dropped (docs/framing.md).
  #   seed study      it used mix big{0,1,2,3,0,1,2,3} -- duplicated traces,
  #                   which manufacture sharing by construction. Re-running it
  #                   would reproduce an artifact, not a result.
  #
  # Cost: 4-core is ~4 h a job, 16-core is ~36 h (measured -- the 16c LRU job in
  # the first sweep ran 34 h and was still going). Set PAPER_REPRO=0 to skip.
  if [ "${PAPER_REPRO:-1}" = "1" ] && in_wl canneal; then
    for p in $ALL_POLICIES; do
      for rg2 in $RG; do
        echo "$p|canneal|4|$rg2"  >> "$tmp"
        echo "$p|canneal|16|$rg2" >> "$tmp"
      done
    done
  fi
  # ONLY_POLICIES keeps those policies' jobs and drops everything else, the LRU
  # overlay rows included. A misspelt name would otherwise yield an empty or
  # partial queue that "completes" at once, so every name must be known.
  local q
  for q in $ONLY_POLICIES; do
    case " $ALL_POLICIES " in *" $q "*) ;; *) rm -f "$tmp"; die "ONLY_POLICIES: unknown policy '$q'" ;; esac
  done
  for q in $ONLY_CORES; do
    case "$q" in 4|8|16) ;; *) rm -f "$tmp"; die "ONLY_CORES: '$q' is not a queued core count (4 8 16)" ;; esac
  done
  awk -F'|' -v only="$ONLY_POLICIES" -v cores="$ONLY_CORES" '
    BEGIN { n = split(only, a, " "); for (i = 1; i <= n; i++) keep[a[i]] = 1
            m = split(cores, c, " "); for (i = 1; i <= m; i++) keepc[c[i]] = 1 }
    !seen[$0]++ && (n == 0 || ($1 in keep)) && (m == 0 || ($3 in keepc))' "$tmp" > "$QUEUE"
  rm -f "$tmp"
  [ -s "$QUEUE" ] || die "the queue is empty -- WORKLOADS='${WORKLOADS:-}' ONLY_POLICIES='$ONLY_POLICIES' ONLY_CORES='$ONLY_CORES' select nothing"
  # LONGEST_FIRST=1 launches the most cores first. The queue is built policy by
  # policy, so a family's 16-core jobs -- 26+ h each at fixed 2 MB -- would
  # otherwise start only after slots free up, and the relaunch would run for two
  # of them back to back. Stable, so ties keep the build order. A new file is
  # renamed into place: a driver reading the old one is never disturbed.
  if [ "${LONGEST_FIRST:-0}" = 1 ]; then
    sort -s -t'|' -k3,3nr "$QUEUE" > "$QUEUE.sorted" && mv -f "$QUEUE.sorted" "$QUEUE"
  fi
}

phase_plan() {
  # build_queue rewrites queue.txt, and a live driver is reading that file
  # line by line through an open descriptor (see trim_queue.sh). Rebuilding it
  # under the driver moves every byte after its position. A plan is only safe
  # on a queue nobody is running.
  driver_alive && die "a driver is running this queue (pid $(cat "$LOCK")) -- 'plan' would rewrite the file it is reading; use 'status'"
  build_queue
  echo "== Phase A run queue =="
  echo "   warmup=$WARMUP sim=$SIM per core, max $MAXJOBS concurrent"
  echo "   binary $BIN   policies ${ONLY_POLICIES:-all}   geometry $([ "${SCALED:-0}" = 1 ] && echo scaled || echo 'fixed 2 MB')"
  echo "   results -> $RESULTS_ROOT"
  [ "${LONGEST_FIRST:-0}" = 1 ] && echo "   order: longest first (16-core, then 8, then 4)"
  echo
  local pol wl cores rg t runnable=0 missing=0 done=0 hours=0 est
  while IFS='|' read -r pol wl cores rg; do
    if ! t=$(traces_for "$wl" "$cores"); then
      printf '  %-20s %-8s %2sc %-8s UNRUNNABLE (%s)\n' "$pol" "$wl" "$cores" "$rg" "${t#MISSING:}"
      missing=$((missing + 1)); continue
    fi
    if job_done "$pol" "$wl" "$cores" "$rg"; then done=$((done + 1)); continue; fi
    runnable=$((runnable + 1))
    # measured on 2026-09-17 under 14-way concurrency, before the crash
    case "$cores" in 4) est=3 ;; 8) est=6 ;; 16) est=12 ;; *) est=6 ;; esac
    hours=$((hours + est))
  done < "$QUEUE"
  echo "  total queued: $(wc -l < "$QUEUE")"
  echo "  already done: $done"
  echo "  to run:       $runnable"
  echo "  unrunnable:   $missing"
  echo
  echo "  ~$hours CPU-hours; at $MAXJOBS concurrent, ~$(( (hours + MAXJOBS - 1) / MAXJOBS )) h wall clock"
  echo "  (4-core ~3 h, 8-core ~6 h, 16-core ~12 h, measured not guessed)"
}

worker() {
  echo $$ > "$LOCK"
  local pol wl cores rg t cfg out log started
  while IFS='|' read -r pol wl cores rg; do
    if ! t=$(traces_for "$wl" "$cores"); then
      echo "$(date '+%F %T') SKIP  $pol $wl ${cores}c $rg -- ${t#MISSING:}" >> "$RUNLOG"; continue
    fi
    if job_done "$pol" "$wl" "$cores" "$rg"; then
      echo "$(date '+%F %T') DONE  $pol $wl ${cores}c $rg (already complete)" >> "$RUNLOG"; continue
    fi

    while [ "$(jobs -rp | wc -l)" -ge "$MAXJOBS" ]; do sleep 30; done

    out=$(job_outdir "$pol" "$wl" "$cores" "$rg"); mkdir -p "$out"
    log="$out/run.log"
    cfg="$STATE/cfg_${pol}_${cores}c_${rg}.json"
    # shellcheck disable=SC2086 -- MAKE_CONFIG_EXTRA is deliberately word-split
    if ! "$S/scripts/make_config.py" --policy "$pol" --cores "$cores" --regime "$rg" \
           ${MAKE_CONFIG_EXTRA:-} -o "$cfg"; then
      echo "$(date '+%F %T') CFGFAIL $pol $wl ${cores}c $rg" >> "$RUNLOG"; continue
    fi

    echo "$(date '+%F %T') START $pol $wl ${cores}c $rg" >> "$RUNLOG"
    # shellcheck disable=SC2086
    (
      started=$(date +%s)
      cd "$S" && nice -n 19 "$BIN" --config "$cfg" \
        --warmup-instructions "$WARMUP" --simulation-instructions "$SIM" $t > "$log" 2>&1
      rc=$?     # captured immediately; a $(date) in the same expansion resets it
      printf '%s END   %s %s %sc %s rc=%s elapsed=%sm\n' \
        "$(date '+%F %T')" "$pol" "$wl" "${cores}c" "$rg" "$rc" "$(( ($(date +%s) - started) / 60 ))" >> "$RUNLOG"
    ) &
    sleep 2
  done < "$QUEUE"
  wait
  echo "$(date '+%F %T') QUEUE COMPLETE" >> "$RUNLOG"
  rm -f "$LOCK"
}

driver_alive() { [ -f "$LOCK" ] && kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null; }

launch() {
  [ -x "$S/bin/champsim" ] || die "no $S/bin/champsim -- run server_build.sh first"
  local g
  for g in check_include_path check_fill_hook check_signatures; do
    bash "$R/bench/policy_sanity/$g.sh" >/dev/null 2>&1 \
      || die "$g failed -- refusing to launch a multi-hour sweep on an unverified build"
  done
  build_queue
  mkdir -p "$STATE"
  echo "$(date '+%F %T') QUEUE START ($(wc -l < "$QUEUE") jobs, max $MAXJOBS concurrent)" >> "$RUNLOG"
  setsid bash "$0" __worker < /dev/null >> "$RUNLOG" 2>&1 &
  disown 2>/dev/null
  sleep 3
}

# Answer the overlay question in an hour instead of a day.
#
# Tier 1 asks only whether canneal's invalidation count scales with core count.
# That is a property of the sharing pattern, not a subtle policy effect, so it
# does not need 50M+100M per core: the 1M+2M smoke already produced 24,062
# aliased fills and 4,879 invalidations. 5M+10M is short enough to finish in an
# hour and long enough for the trend to be unambiguous.
#
# Writes to results/phaseA_quick so these numbers can never be mistaken for, or
# overwrite, the full-length ones that go in the paper.
# Six tier-1 jobs (lru, canneal, 4/8/16 cores, shared and private) at short
# length. Tier 1 asks only whether invalidations scale with core count, which is
# a property of the sharing pattern rather than the replacement policy, so one
# policy and a 10M simulation answer it directionally in about an hour.
#
# $1 = variant tag ("" for the historical geometry), $2 = extra make_config
# args. Each variant gets its own results tree and state directory, so short
# numbers can never be mistaken for, or overwrite, the full-length ones.
run_quick() {
  local tag="${1:-}" extra="${2:-}"
  local suffix=""; [ -n "$tag" ] && suffix="_$tag"
  export RESULTS_ROOT="$S/results/phaseA_quick$suffix"
  export WARMUP="${QUICK_WARMUP:-5000000}"
  export SIM="${QUICK_SIM:-10000000}"
  export MAXJOBS=6
  export STATE="$HOME/.phase_a_quick$suffix"
  export QUEUE="$STATE/queue.txt"
  export RUNLOG="$STATE/run.log"
  export LOCK="$STATE/driver.pid"
  export MAKE_CONFIG_EXTRA="$extra"
  mkdir -p "$STATE"

  driver_alive && die "a quick$suffix driver is already running (pid $(cat "$LOCK"))"

  local n rg
  : > "$QUEUE"
  for n in 4 8 16; do for rg in shared private; do echo "lru|canneal|$n|$rg" >> "$QUEUE"; done; done

  [ -x "$S/bin/champsim" ] || die "no $S/bin/champsim"
  local g
  for g in check_include_path check_fill_hook check_signatures; do
    bash "$R/bench/policy_sanity/$g.sh" >/dev/null 2>&1 || die "$g failed"
  done

  echo "== quick overlay validation${tag:+ ($tag)} =="
  echo "   6 runs, lru, canneal 4/8/16 cores, shared and private"
  echo "   $WARMUP warmup + $SIM simulation per core (short, on purpose)"
  [ -n "$extra" ] && echo "   extra config: $extra"
  echo "   results -> $RESULTS_ROOT"
  echo
  echo "$(date '+%F %T') QUICK START${tag:+ [$tag]}" >> "$RUNLOG"
  setsid env RESULTS_ROOT="$RESULTS_ROOT" WARMUP="$WARMUP" SIM="$SIM" MAXJOBS=6 \
      STATE="$STATE" QUEUE="$QUEUE" RUNLOG="$RUNLOG" LOCK="$LOCK" \
      MAKE_CONFIG_EXTRA="$extra" \
      bash "$0" __worker < /dev/null >> "$RUNLOG" 2>&1 &
  disown 2>/dev/null
  sleep 3
  if [ -n "$tag" ]; then echo "launched. check with:  bash $0 quick-$tag-status"
  else echo "launched. check with:  bash $0 quick-status"; fi
}

phase_quick() { run_quick "" ""; }

# The same six jobs with the LLC scaled to 2 MB per core instead of a fixed 2 MB.
#
# WHY: the LLC is 2048 sets x 16 ways x 64 B = 2 MB at EVERY core count, in
# make_config.py and in all four original configs. That is 0.5 MB per core at 4
# cores and 0.125 MB at 16, against 1-2 MB per core on real parts. Private-VMEM
# LLC hit rate on canneal duly collapses 12.21% -> 0.93% -> 0.24% across 4/8/16
# cores, and at 0.24% no replacement policy can matter, because nothing survives
# to be reused.
#
# So the private-vs-shared gap conflates two effects: the overlay shrinking the
# working set, and a cache too small to hold sixteen independent ones. This
# separates them. If the regime difference survives at 32 MB it is real; if it
# disappears it was cache pressure -- which would apply equally to the paper's
# existing 16-core numbers.
phase_quick_llc() { run_quick "llc" "--llc-per-core-mb ${LLC_PER_CORE_MB:-2}"; }

phase_quick_status() {
  local sfx="${1:-}"
  STATE="$HOME/.phase_a_quick$sfx"; RUNLOG="$STATE/run.log"; LOCK="$STATE/driver.pid"
  QUEUE="$STATE/queue.txt"; RESULTS_ROOT="$S/results/phaseA_quick$sfx"
  phase_status
  echo
  echo "== overlay scaling (the question) =="
  phase_results
}

# $1 = variant tag ("" for the historical geometry), $2 = extra make_config args.
# Each variant gets its own results tree and state directory.
run_full() {
  local tag="${1:-}" extra="${2:-}"
  local suffix=""; [ -n "$tag" ] && suffix="_$tag"
  export RESULTS_ROOT="$S/results/phaseA$suffix"
  export STATE="$HOME/.phase_a$suffix"
  export QUEUE="$STATE/queue.txt"
  export RUNLOG="$STATE/run.log"
  export LOCK="$STATE/driver.pid"
  export MAKE_CONFIG_EXTRA="$extra"
  QUEUE="$STATE/queue.txt"; RUNLOG="$STATE/run.log"; LOCK="$STATE/driver.pid"
  mkdir -p "$STATE"

  driver_alive && die "a phaseA$suffix driver is already running (pid $(cat "$LOCK")). Use 'status'."
  # Scope the busy check to THIS user. The machine is shared -- another account
  # was running its own champsim on 2026-09-22 -- and an unscoped pgrep matches
  # it, so the guard would refuse to launch until a stranger's job finished.
  # The thing worth refusing is our own overlapping run, not anyone else's.
  if [ "${RESUME_SKIP_BUSY:-0}" != "1" ]; then
    # match the process NAME, not the command line -- see ab_build.sh.
    if pgrep -u "$(id -u)" '^champsim' >/dev/null 2>&1; then
      echo "   our champsim processes:" >&2
      pgrep -u "$(id -u)" -a '^champsim' 2>/dev/null | cut -c1-100 | sed 's/^/     /' >&2
      die "one of our champsim jobs is already running. Let it finish, or set RESUME_SKIP_BUSY=1 deliberately."
    fi
    local others
    others=$(( $(pgrep '^champsim' 2>/dev/null | wc -l) - $(pgrep -u "$(id -u)" '^champsim' 2>/dev/null | wc -l) ))
    [ "${others:-0}" -gt 0 ] && echo "   note: $others champsim job(s) from other users are on this machine; ours will be niced alongside"
  fi

  [ -x "$BIN" ] || die "no binary at $BIN -- run server_build.sh first"
  local g
  for g in check_include_path check_fill_hook check_signatures; do
    bash "$R/bench/policy_sanity/$g.sh" >/dev/null 2>&1 \
      || die "$g failed -- refusing to launch a multi-day sweep on an unverified build"
  done
  build_queue
  # Persist what this queue was built from, so a resume rebuilds the SAME one.
  #
  # build_queue reads WORKLOADS and REGIMES from the environment, and the
  # @reboot crontab line carries no environment. A sweep launched with
  # REGIMES="shared private" would, after a reboot, silently rebuild the
  # default shared-only queue: the private jobs drop out, the rest are already
  # complete, and the resume exits in seconds looking like it worked.
  # Values are QUOTED. REGIMES="shared private" written bare would, on being
  # sourced, set REGIMES=shared and then try to run `private` as a command --
  # restoring half the queue while reporting nothing wrong.
  {
    echo "WORKLOADS='${WORKLOADS:-canneal barnes}'"
    echo "REGIMES='${REGIMES:-shared}'"
    echo "PAPER_REPRO='${PAPER_REPRO:-1}'"
    # A relaunch is defined as much by these as by the workloads: resumed
    # without them it would run every policy, on bin/champsim, in the geometry
    # its tag name happens to imply.
    echo "ONLY_POLICIES='$ONLY_POLICIES'"
    echo "BIN='$BIN'"
    echo "MAKE_CONFIG_EXTRA='$extra'"
    echo "LONGEST_FIRST='${LONGEST_FIRST:-0}'"
    echo "OCEAN_CORES='${OCEAN_CORES:-8}'"
    echo "ONLY_CORES='$ONLY_CORES'"
    # Without this a resume ran the default 14 at a time, whatever the launch
    # asked for: two 7-way queues would come back from a reboot as 28.
    echo "MAXJOBS='$MAXJOBS'"
  } > "$STATE/queue.env"
  echo "$(date '+%F %T') QUEUE START${tag:+ [$tag]} ($(wc -l < "$QUEUE") jobs, max $MAXJOBS concurrent)" >> "$RUNLOG"
  [ -n "$extra" ] && echo "   extra config: $extra"
  echo "   binary:  $BIN"
  [ -n "$ONLY_POLICIES" ] && echo "   policies: $ONLY_POLICIES (only)"
  [ -n "$ONLY_CORES" ] && echo "   cores: $ONLY_CORES (only)"
  echo "   results -> $RESULTS_ROOT"
  setsid env RESULTS_ROOT="$RESULTS_ROOT" STATE="$STATE" QUEUE="$QUEUE" RUNLOG="$RUNLOG" \
      LOCK="$LOCK" MAKE_CONFIG_EXTRA="$extra" WARMUP="$WARMUP" SIM="$SIM" MAXJOBS="$MAXJOBS" \
      BIN="$BIN" bash "$0" __worker < /dev/null >> "$RUNLOG" 2>&1 &
  disown 2>/dev/null
  sleep 3
  echo "launched."
  tail -4 "$RUNLOG"
}

phase_go() { run_full "" ""; echo; echo "Survive a reboot too:  bash $0 install-resume"; }

# The full 52-job sweep with the LLC scaled to 2 MB per core.
#
# WHY THIS IS THE ONE THAT COUNTS. The historical geometry is 2 MB at every core
# count, and that suppresses the effect under study: private-regime LLC hit rate
# on canneal reads 12.21% / 0.93% / 0.24% at 4/8/16 cores there, against a flat
# ~50.7% when the cache scales. Coherence traffic is 6.5x higher at 16 cores
# once lines live long enough to be invalidated -- 19.0% of LLC accesses against
# 2.95%. Every policy number this project has produced, COALESCE's -2.4%
# included, was measured with that signal suppressed.
#
# The unscaled sweep is still worth having: it reproduces what the paper
# measured, so the two together say exactly what changed and why.
phase_go_scaled() { run_full "scaled" "--llc-per-core-mb ${LLC_PER_CORE_MB:-2}"; }

# Point every per-sweep path at one variant's tree and state. "" is the
# historical sweep. Separate statements on purpose: `export A=x B="$A/y"`
# expands $A before assigning it.
use_tag() {
  local suffix=""; [ -n "${1:-}" ] && suffix="_$1"
  export RESULTS_ROOT="$S/results/phaseA$suffix"
  export STATE="$HOME/.phase_a$suffix"
  export QUEUE="$STATE/queue.txt"
  export RUNLOG="$STATE/run.log"
  export LOCK="$STATE/driver.pid"
}

# A tag names a new results tree. The existing trees keep their own commands,
# and a quick* tag would land inside run_quick's trees.
check_tag() {
  case "${1:-}" in
    "")                       die "name the tag: results go to results/phaseA_<tag>" ;;
    scaled|quick|quick_*)     die "tag '$1' belongs to an existing sweep" ;;
    *[!A-Za-z0-9_]*)          die "tag '$1': use letters, digits and _ only" ;;
  esac
}

# A relaunch into results/phaseA_<tag>, with its own state, lock and queue.
# SCALED=1 gives the scaled geometry, as go-scaled does. Everything else --
# WORKLOADS, REGIMES, ONLY_POLICIES, BIN -- comes from the environment and is
# recorded in queue.env, so a resume rebuilds exactly this queue.
#
# COHERENCE=1|2 sets private-cache coherence (B3 v4;
# b3v4_coherent_private_design_2026-10-11.md). It travels as a make_config.py
# argument, so queue.env's MAKE_CONFIG_EXTRA carries it through a resume. A
# binary older than B3 v4 would ignore the config key and run at level 0
# without a word, so such a binary is refused here.
phase_go_tag() {
  check_tag "${1:-}"
  local extra=""
  [ "${SCALED:-0}" = 1 ] && extra="--llc-per-core-mb ${LLC_PER_CORE_MB:-2}"
  case "${COHERENCE:-0}" in
    0) ;;
    1|2)
      # grep -c, not -q: under pipefail an early -q exit SIGPIPEs strings (1a2b8ca)
      [ "$(strings -a "$BIN" 2>/dev/null | grep -c 'PRIVATE-CACHE COHERENCE LEVEL')" -gt 0 ] \
        || die "COHERENCE=$COHERENCE, but $BIN predates B3 v4 and would silently run at level 0"
      extra="${extra:+$extra }--private-coherence $COHERENCE" ;;
    *) die "COHERENCE must be 0, 1 or 2" ;;
  esac
  run_full "$1" "$extra"
  echo; echo "Survive a reboot too:  bash $0 install-resume $1"
}

# Resume after a reboot. $1 selects the variant, matching go / go-scaled.
#
# This took a variant-less phase_go, so 'resume' always restarted the UNSCALED
# sweep. After a reboot during the scaled run that would have left the scaled
# queue stopped AND started ~20 new unscaled jobs from the extended queue into
# results/phaseA -- silently producing a second, wrong set of results.
#
# Completed jobs are skipped by the end marker in their log, so a resume costs
# only the runs actually in flight.
phase_resume() {
  local tag="${1:-}" suffix=""
  [ -n "$tag" ] && suffix="_$tag"
  local lock="$HOME/.phase_a$suffix/driver.pid"
  if [ -f "$lock" ] && kill -0 "$(cat "$lock" 2>/dev/null)" 2>/dev/null; then
    echo "driver already running for phaseA$suffix (pid $(cat "$lock"))"; return 0
  fi
  rm -f "$lock"
  # Restore the queue definition this sweep was launched with. Without it a
  # reboot rebuilds the default queue and silently drops whatever the sweep was
  # actually running.
  if [ -f "$HOME/.phase_a$suffix/queue.env" ]; then
    # shellcheck disable=SC1090
    set -a; . "$HOME/.phase_a$suffix/queue.env"; set +a
    echo "   resuming with: WORKLOADS='${WORKLOADS:-}' REGIMES='${REGIMES:-}'"
  fi
  echo "$(date '+%F %T') RESUME${tag:+ [$tag]} after reboot (up since $(uptime -s))" \
    >> "$HOME/.phase_a$suffix/run.log" 2>/dev/null
  # RESUME_SKIP_BUSY: on a reboot the other queue's @reboot entry may already
  # have started jobs, and run_full refuses when any champsim is alive. The
  # per-variant driver lock above is the check that matters here.
  # The geometry comes from queue.env when it was recorded there. Only queues
  # launched before it was (the historical and scaled sweeps) fall back to
  # inferring it from the tag, which is all this ever did.
  local extra
  if grep -q '^MAKE_CONFIG_EXTRA=' "$HOME/.phase_a$suffix/queue.env" 2>/dev/null; then
    extra="$MAKE_CONFIG_EXTRA"
  else
    extra="$([ "$tag" = scaled ] && echo "--llc-per-core-mb ${LLC_PER_CORE_MB:-2}")"
  fi
  RESUME_SKIP_BUSY=1 run_full "$tag" "$extra"
}

phase_install_resume() {
  local tag="${1:-}" suffix="" delay=180
  [ -n "$tag" ] && { suffix="_$tag"; delay=300; }
  mkdir -p "$HOME/.phase_a$suffix"
  local line="@reboot sleep $delay && /bin/bash $HOME/run_phase_a.sh resume $tag >> $HOME/.phase_a$suffix/reboot.log 2>&1"
  # Remove every prior entry for THIS tag and no other. This filtered on
  # "resume $tag\b", which fails both ways: with an empty tag, "resume \b"
  # needs a word character after the space, so it missed the default entry
  # (two spaces) and matched every TAGGED one instead. fix_resume_env.sh found
  # and fixed this on 2026-09-23; this is the same pattern.
  local pat
  if [ -n "$tag" ]; then pat="run_phase_a\.sh resume[[:space:]]+$tag([[:space:]]|$)"
  else pat="run_phase_a\.sh resume[[:space:]]*(>|$)"; fi
  (crontab -l 2>/dev/null | grep -Ev "$pat"; echo "$line") | crontab -
  echo "installed:"; crontab -l | grep "run_phase_a.sh resume"
  echo
  echo "phaseA$suffix restarts itself ~$((delay / 60)) min after any boot, skipping finished jobs."
  echo "Install one per variant you are running: 'install-resume' and 'install-resume scaled'."
}

phase_status() {
  echo "== queue =="
  [ -f "$RUNLOG" ] || { echo "   not started"; return 0; }
  # Count only the CURRENT queue. run.log is appended to by every queue ever run
  # into this tree, so counting the whole file mixed queues: on 2026-09-23 it
  # printed "*** QUEUE COMPLETE ***" (from an earlier queue) beside a live
  # driver with 19 of 66 jobs done.
  local cur
  cur=$(awk '/ QUEUE START/ {n = NR} END {print n + 0}' "$RUNLOG")
  cur_log() { tail -n +"$((cur > 0 ? cur : 1))" "$RUNLOG"; }
  printf '   this queue -- started: %s   finished: %s   running now (ours): %s\n' \
    "$(cur_log | grep -c ' START [a-z]')" "$(cur_log | grep -c ' END   ')" \
    "$(pgrep -u "$(id -u)" -c '^champsim' 2>/dev/null | head -1)"
  driver_alive && echo "   driver: alive (pid $(cat "$LOCK"))" || echo "   driver: NOT RUNNING"
  cur_log | grep -q "QUEUE COMPLETE" && echo "   *** QUEUE COMPLETE ***"
  local total done
  total=$(wc -l < "$QUEUE" 2>/dev/null || echo 0); done=0
  while IFS='|' read -r p w c r; do job_done "$p" "$w" "$c" "$r" && done=$((done + 1)); done < "$QUEUE" 2>/dev/null
  echo "   verified complete (end marker present): $done / $total"
  echo
  echo "== last 12 events =="; tail -12 "$RUNLOG"
  echo
  echo "== machine =="; uptime; echo "   booted: $(uptime -s)"; df -h "$S/traces" | tail -1
}

phase_results() {
  printf '%-20s %-9s %-5s %-8s %14s %14s %12s %-10s %-6s %s\n' policy workload cores regime aliased_fills invalidations max_cycles state vmem trace
  local log d rg wl cores pol af inv mc st vm tw
  while IFS= read -r log; do
    [ -s "$log" ] || continue
    d=$(dirname "$log")
    rg=$(echo "$d" | sed 's|.*regime_\([a-z]*\)/.*|\1|')
    wl=$(echo "$d" | sed 's|.*/\([a-z_]*\)_[0-9]*core/.*|\1|')
    cores=$(echo "$d" | sed 's|.*_\([0-9]*\)core/.*|\1|')
    pol=$(basename "$d")
    grep -q "$DONE_MARKER" "$log" && st=complete || st=INCOMPLETE
    # vmem.cc recycles physical pages when the pool runs out, which fabricates
    # aliasing indistinguishable from real sharing. Any run that printed this
    # has contaminated aliased_fills and invalidations.
    grep -q "Out of physical memory" "$log" && vm=EXHAUSTED-INVALID || vm=ok
    # ChampSim enables trace repeat whenever --simulation-instructions is given
    # (main.cc: repeat = simulation_given), and repeatable::operator() silently
    # reopens a trace at EOF. A run consuming 50M warmup + 100M simulation needs
    # 150M records per core; ocean has only ~45.3M, so it wraps 3.3 times,
    # re-touching the same addresses. Under the shared overlay the cores wrap in
    # near-lockstep, which manufactures both reuse and sharing.
    grep -q "Reached end of trace" "$log" && tw=LOOPED || tw=ok
    af=$(grep -m1 "VMEM ALIASED FILLS" "$log" | grep -oE '[0-9]+$')
    inv=$(grep -m1 "^LLC COHERENCE INVALIDATIONS" "$log" | grep -oE '[0-9]+$')
    mc=$(grep -oE "Simulation complete CPU [0-9]+ instructions: [0-9]+ cycles: [0-9]+" "$log" \
         | grep -oE '[0-9]+$' | sort -n | tail -1)
    printf '%-20s %-9s %-5s %-8s %14s %14s %12s %-10s %-6s %s\n' \
      "$pol" "$wl" "$cores" "$rg" "${af:-.}" "${inv:-.}" "${mc:-.}" "$st" "$vm" "$tw"
  done < <(find "$RESULTS_ROOT" -name run.log 2>/dev/null | sort)
  echo
  echo "Only 'complete' rows are trustworthy. shared => non-zero aliased fills; private => zero."
  echo "vmem=EXHAUSTED-INVALID: the page pool ran out and physical pages were recycled,"
  echo "which fabricates aliasing. Those aliased_fills and invalidations mean nothing."
  echo "trace=LOOPED: the trace ran out and ChampSim silently reopened it, so the run"
  echo "replayed the same instructions. ocean is ~45.3M records against the 150M a"
  echo "50M+100M run consumes, so it wraps 3.3x and re-touches the same addresses."
}

# Raw rows, one per run, nothing interpreted. The A4 harness has the same
# command and for the same reason: every published number should re-derive from
# a committed file of these, not from a summary written the day it was measured.
#
# Emits, whitespace-separated:
#   variant policy workload cores regime status vmem wrap max_cycles min_cycles
#   instrs llc_load_acc llc_load_hit llc_total_acc llc_total_hit
#   llc_write_acc llc_write_hit llc_rfo_acc llc_rfo_hit llc_tr_acc llc_tr_hit
#   aliased_fills invals
#
# min_cycles is kept but is NOT a measure of core imbalance: every core ends on
# the same cycle, because the phase ends globally once the slowest core retires
# its target, and the others keep being ticked until then (champsim.cc:141).
# It comes back exactly equal to max_cycles on every run. What varies per core
# is instructions retired, not cycles.
#
# RFO and TRANSLATION are split out for the same reason WRITE was: so the
# remaining traffic is measured, not inferred by subtraction. With WRITE
# separated it turned out writeback misses are only 1.17x SRRIP at 4 cores while
# everything left over is 7.4x, and RFO -- read-for-ownership, a store finding
# the line absent -- is a coherence operation, which is exactly the traffic a
# coherence-biased policy could plausibly be creating. Guessing which of RFO and
# TRANSLATION carries it would repeat the mistake this whole exercise has been
# correcting.
#
# llc_write_acc/hit is the writeback stream from L2. It is here because COALESCE
# holds an LLC load hit rate within 0.09pp of SRRIP at 4 cores while running
# 3.22% slower, and the gap is not demand loads: its load MPKI is +0.39% against
# SRRIP while its NON-load MPKI is 1.148 against SRRIP's 0.606 and Hawkeye's
# 0.016. Splitting WRITE out of TOTAL says whether that traffic is writebacks
# missing in the LLC -- i.e. the policy evicting lines that L2 is about to write
# back -- rather than leaving it inferred from a subtraction.
#
# LLC counters are SUMMED OVER THE PER-CPU ROWS (cpuN->LLC ...) IN THE REGION
# OF INTEREST BLOCK ONLY.
#
# Two separate double-counting traps here, and the second was live until
# 2026-09-23:
#
#  1. ChampSim prints an aggregate row alongside the per-CPU ones; adding both
#     double-counts. Handled by anchoring on `cpu[0-9]+->`.
#  2. plain_printer.cc:184-199 prints the whole cache-stat block TWICE whenever
#     NUM_CPUS > 1 -- once under "Total Simulation Statistics (not including
#     warmup)" from sim_cache_stats, then again under "Region of Interest
#     Statistics" from roi_cache_stats. CACHE::end_phase copies sim_stats into
#     roi_stats, so for the final phase the two blocks are IDENTICAL, and
#     summing the file gave exactly 2x every LLC counter on every multi-core
#     run. Single-core runs (the A4 harness) skip the first block entirely, so
#     they were never affected -- which made the two datasets silently
#     inconsistent with each other.
#
#     Hit RATES were unaffected, since numerator and denominator doubled
#     together, and so was every policy-vs-policy ratio. What was wrong is any
#     per-instruction rate: instrs comes from the "Simulation complete CPU"
#     lines, which champsim.cc prints once, so MPKI-style figures read 2x high.
#
#     The TOTAL == LOAD+WRITE+RFO+TRANSLATION identity could not catch this,
#     because a uniform doubling preserves it.
phase_rows() {
  local root log d rg wl cores pol st vm tw mc ins la lh ta th af inv var
  # Every phaseA* tree, so a go-tag relaunch is picked up without editing this
  # list; each row is labelled with its tree, so nothing mixes.
  for root in "$S"/results/phaseA "$S"/results/phaseA_*; do
    [ -d "$root" ] || continue
    var=$(basename "$root")
    while IFS= read -r log; do
      [ -s "$log" ] || continue
      d=$(dirname "$log")
      rg=$(echo "$d" | sed 's|.*regime_\([a-z]*\)/.*|\1|')
      wl=$(echo "$d" | sed 's|.*/\([a-z_]*\)_[0-9]*core/.*|\1|')
      cores=$(echo "$d" | sed 's|.*_\([0-9]*\)core/.*|\1|')
      pol=$(basename "$d")
      grep -q "$DONE_MARKER" "$log" && st=complete || st=INCOMPLETE
      grep -q "Out of physical memory" "$log" && vm=EXHAUSTED || vm=ok
      grep -q "Reached end of trace" "$log" && tw=LOOPED || tw=ok
      mc=$(grep -oE "Simulation complete CPU [0-9]+ instructions: [0-9]+ cycles: [0-9]+" "$log" \
           | grep -oE '[0-9]+$' | sort -n | tail -1)
      mn=$(grep -oE "Simulation complete CPU [0-9]+ instructions: [0-9]+ cycles: [0-9]+" "$log" \
           | grep -oE '[0-9]+$' | sort -n | head -1)
      ins=$(awk '/Simulation complete CPU [0-9]+ instructions:/ {
                   for (i = 1; i <= NF; i++) if ($i == "instructions:") s += $(i+1) } END { print s+0 }' "$log")
      read -r la lh <<< "$(awk '/Region of Interest/ {roi=1} roi && /^cpu[0-9]+->LLC LOAD/ {
              for (i = 1; i <= NF; i++) { if ($i == "ACCESS:") a += $(i+1); if ($i == "HIT:") h += $(i+1) } }
              END { printf "%d %d\n", a+0, h+0 }' "$log")"
      read -r wa wh <<< "$(awk '/Region of Interest/ {roi=1} roi && /^cpu[0-9]+->LLC WRITE/ {
              for (i = 1; i <= NF; i++) { if ($i == "ACCESS:") a += $(i+1); if ($i == "HIT:") h += $(i+1) } }
              END { printf "%d %d\n", a+0, h+0 }' "$log")"
      read -r ra rh <<< "$(awk '/Region of Interest/ {roi=1} roi && /^cpu[0-9]+->LLC RFO/ {
              for (i = 1; i <= NF; i++) { if ($i == "ACCESS:") a += $(i+1); if ($i == "HIT:") h += $(i+1) } }
              END { printf "%d %d\n", a+0, h+0 }' "$log")"
      read -r xa xh <<< "$(awk '/Region of Interest/ {roi=1} roi && /^cpu[0-9]+->LLC TRANSLATION/ {
              for (i = 1; i <= NF; i++) { if ($i == "ACCESS:") a += $(i+1); if ($i == "HIT:") h += $(i+1) } }
              END { printf "%d %d\n", a+0, h+0 }' "$log")"
      read -r ta th <<< "$(awk '/Region of Interest/ {roi=1} roi && /^cpu[0-9]+->LLC TOTAL/ {
              for (i = 1; i <= NF; i++) { if ($i == "ACCESS:") a += $(i+1); if ($i == "HIT:") h += $(i+1) } }
              END { printf "%d %d\n", a+0, h+0 }' "$log")"
      af=$(grep -m1 "VMEM ALIASED FILLS" "$log" | grep -oE '[0-9]+$')
      inv=$(grep -m1 "^LLC COHERENCE INVALIDATIONS" "$log" | grep -oE '[0-9]+$')
      echo "$var $pol $wl $cores $rg $st $vm $tw ${mc:-0} ${mn:-0} ${ins:-0} ${la:-0} ${lh:-0} ${ta:-0} ${th:-0} ${wa:-0} ${wh:-0} ${ra:-0} ${rh:-0} ${xa:-0} ${xh:-0} ${af:-0} ${inv:-0}"
    done < <(find "$root" -name run.log 2>/dev/null | sort)
  done
}

case "${1:-}" in
  plan)           phase_plan ;;
  quick)             phase_quick ;;
  quick-llc)         phase_quick_llc ;;
  quick-status)      phase_quick_status ;;
  quick-llc-status)  phase_quick_status _llc ;;
  go)             phase_go ;;
  go-scaled)      phase_go_scaled ;;
  go-tag)         shift; phase_go_tag "$@" ;;
  plan-tag)       shift; check_tag "${1:-}"; use_tag "$1"; phase_plan ;;
  status-tag)     shift; check_tag "${1:-}"; use_tag "$1"; phase_status ;;
  results-tag)    shift; check_tag "${1:-}"; use_tag "$1"; phase_results ;;
  resume)         shift; phase_resume "$@" ;;
  install-resume) shift; phase_install_resume "$@" ;;
  status)         phase_status ;;
  status-scaled)  STATE="$HOME/.phase_a_scaled"; QUEUE="$STATE/queue.txt"; RUNLOG="$STATE/run.log";
                  LOCK="$STATE/driver.pid"; RESULTS_ROOT="$S/results/phaseA_scaled"; phase_status ;;
  results)        phase_results ;;
  results-scaled) RESULTS_ROOT="$S/results/phaseA_scaled"; phase_results ;;
  rows)           phase_rows ;;
  __worker)       worker ;;
  *) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
