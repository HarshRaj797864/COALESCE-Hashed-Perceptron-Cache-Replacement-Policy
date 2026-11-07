#!/usr/bin/env bash
# Launch a policy x regime sweep for one workload.
#
# Replaces run_tmux_8core.sh / run_rebuttal_baselines.sh / build_single_core.sh,
# which all assumed the old compile-time model where `config.sh <cfg> && make`
# produced one binary per policy. On ChampSim develop there is a single
# bin/champsim and the policy is chosen at runtime, so the build happens once.
#
#   scripts/run_matrix.sh --workload canneal --cores 8 --regime shared
#   scripts/run_matrix.sh --workload canneal --cores 8 --regime shared --policies "coalesce srrip"
#
# Runs are launched detached with `nice`, one log per policy. Check with
# scripts/check_progress.sh.
set -uo pipefail

SIM_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SIM_DIR" || exit 2

POLICIES="coalesce coalesce_no_mesi coalesce_no_sharer lru srrip drrip ship hawkeye mockingjay srrip_bias"
WORKLOAD=""
CORES=8
REGIME="shared"
WARMUP=50000000
SIM=100000000

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workload) WORKLOAD="$2"; shift 2 ;;
    --cores)    CORES="$2";    shift 2 ;;
    --regime)   REGIME="$2";   shift 2 ;;
    --policies) POLICIES="$2"; shift 2 ;;
    --warmup)   WARMUP="$2";   shift 2 ;;
    --sim)      SIM="$2";      shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$WORKLOAD" ]] || { echo "--workload is required" >&2; exit 2; }

# Build once. Every policy is compiled into the single binary.
if [[ ! -x bin/champsim ]]; then
  echo "bin/champsim missing -- building"
  make -j"$(nproc)" || exit 1
fi

# Sanity guards. A build that is quietly wrong is the failure mode this project
# has been bitten by repeatedly; do not launch a multi-hour sweep without them.
for g in check_include_path check_fill_hook check_signatures; do
  if [[ -x "../bench/policy_sanity/$g.sh" ]]; then
    "../bench/policy_sanity/$g.sh" >/dev/null 2>&1 || { echo "FAIL: bench/policy_sanity/$g.sh did not pass" >&2; exit 1; }
  fi
done
echo "sanity guards passed"

# Trace mix: one DISTINCT thread per core. Never repeat.
#
# This used to glob traces/<workload>_big*.champsimtrace and pad with
#     TRACES+=("${AVAIL[$((i % ${#AVAIL[@]}))]}")
# which repeats traces when there are fewer than CORES of them. Under the
# shared-VMEM overlay, two cores running the same trace touch identical
# addresses and therefore alias by construction -- that manufactures sharing
# whether or not the workload has any. The published 8-core mix was
# canneal_big{0,1,2,3,4,0,1,2}, three traces used twice, which is a large part
# of why the old invalidation-scaling result does not survive scrutiny.
#
# Now: take exactly CORES distinct traces, or refuse.
TRACES=()
case "$WORKLOAD" in
  canneal)
    # canneal_<N>t holds canneal0..N. Thread 0 is the main thread that loads the
    # netlist (54.6% memory operands vs 57.5-58.3% for workers), so use 1..N.
    d="traces/canneal_${CORES}t"
    [[ -d "$d" ]] || { echo "no $d -- trace canneal at $CORES threads first" >&2; exit 2; }
    for ((i = 1; i <= CORES; i++)); do
      f="$d/canneal$i.champsimtrace"
      [[ -f "$f" ]] || { echo "missing $f" >&2; exit 2; }
      TRACES+=("$f")
    done ;;
  ocean|water)
    [[ "$CORES" -eq 8 ]] || { echo "$WORKLOAD exists only as an 8-thread run" >&2; exit 2; }
    for ((i = 0; i < 8; i++)); do
      f="traces/${WORKLOAD}_8t/${WORKLOAD}$i.champsimtrace"
      [[ -f "$f" ]] || { echo "missing $f" >&2; exit 2; }
      TRACES+=("$f")
    done ;;
  barnes)
    [[ "$CORES" -eq 4 ]] || { echo "barnes exists only as a 4-thread run" >&2; exit 2; }
    for ((i = 0; i < 4; i++)); do
      f="traces/barnes_4t$i.champsimtrace"
      [[ -f "$f" ]] || { echo "missing $f" >&2; exit 2; }
      TRACES+=("$f")
    done ;;
  *) echo "unknown workload: $WORKLOAD" >&2; exit 2 ;;
esac

OUTDIR="results/regime_${REGIME}/${WORKLOAD}/${CORES}core"
mkdir -p "$OUTDIR" configs

echo "workload=$WORKLOAD cores=$CORES regime=$REGIME warmup=$WARMUP sim=$SIM"
echo "traces: ${TRACES[*]}"
echo

for p in $POLICIES; do
  cfg="configs/${p}_${CORES}c_${REGIME}.json"
  scripts/make_config.py --policy "$p" --cores "$CORES" --regime "$REGIME" -o "$cfg" || exit 1
  log="$OUTDIR/${p}.log"
  echo "launching $p -> $log"
  # setsid, not nohup: over ssh a nohup'd job still shares the session's
  # stdout, so ssh waits for it and the terminal appears to hang.
  setsid nice -n 19 ./bin/champsim --config "$cfg" \
      --warmup-instructions "$WARMUP" --simulation-instructions "$SIM" \
      "${TRACES[@]}" < /dev/null > "$log" 2>&1 &
  disown 2>/dev/null
done

echo
echo "all launched. progress: scripts/check_progress.sh $OUTDIR"
echo "when each finishes, confirm the regime actually engaged:"
echo "  grep 'VMEM ALIASED FILLS' $OUTDIR/*.log     # non-zero for shared, zero for private"
