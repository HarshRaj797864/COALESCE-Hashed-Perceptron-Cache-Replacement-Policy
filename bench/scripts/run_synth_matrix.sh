#!/usr/bin/env bash
# run_synth_matrix.sh — V1..V6 validation matrix for the VMEM shared-overlay.
#
# Assumes you've already:
#   1. Built the simulator binary with both private + shared configs (see below).
#   2. Generated PIN MT-Sync traces of the synth bench:
#        traces/synth_modeA{0..7}.champsimtrace
#        traces/synth_modeB{0..7}.champsimtrace
#        traces/synth_modeC{0..7}.champsimtrace
#      (See ../README.md for the PIN command.)
#
# Outputs:
#   - logs/V{1..6}.log
#   - summary table on stdout
#
# Run inside `tmux` on the server, ideally `nice -n 19`. Each run takes a few
# minutes for 200 k-iteration synth traces; the whole matrix is well under an hour.

set -u
SIMULATOR_DIR="$(cd "$(dirname "$0")/../../simulator" && pwd)"
TRACE_DIR="$SIMULATOR_DIR/traces"
RESULTS_DIR="$SIMULATOR_DIR/results/phase2a_synth_overlay"
mkdir -p "$RESULTS_DIR/logs"
cd "$SIMULATOR_DIR"

# Warmup / sim instr counts. Synth traces have ~200k iterations × ~5 instr/iter
# per thread = ~1M committed instr per thread. Keep warmup small and sim small
# so V1..V6 finish fast (we're validating a mechanism, not measuring IPC at scale).
WARMUP=200000
SIM=500000

# Configs (you build these once; see "Config templates" in bench/README.md).
# The binary names below assume you used ./config.sh on each JSON before make.
PRIVATE_8CORE_BIN="bin/champsim_synth_private"
SHARED_8CORE_BIN="bin/champsim_synth_shared"

trace_args() {
  local mode="$1"
  echo "$TRACE_DIR/synth_mode${mode}0.champsimtrace" \
       "$TRACE_DIR/synth_mode${mode}1.champsimtrace" \
       "$TRACE_DIR/synth_mode${mode}2.champsimtrace" \
       "$TRACE_DIR/synth_mode${mode}3.champsimtrace" \
       "$TRACE_DIR/synth_mode${mode}4.champsimtrace" \
       "$TRACE_DIR/synth_mode${mode}5.champsimtrace" \
       "$TRACE_DIR/synth_mode${mode}6.champsimtrace" \
       "$TRACE_DIR/synth_mode${mode}7.champsimtrace"
}

run_one() {
  local tag="$1"; local bin="$2"; local mode="$3"; local policy_note="$4"
  echo "=== $tag : binary=$bin mode=$mode policy_note=$policy_note ==="
  local log="$RESULTS_DIR/logs/${tag}.log"
  $bin --warmup-instructions $WARMUP --simulation-instructions $SIM $(trace_args "$mode") \
    > "$log" 2>&1
  echo "    log -> $log"
  grep -E "VMEM ALIASED FILLS|LLC COHERENCE INVALIDATIONS|LLC COHERENCE WRITE-HIT|LLC SHARER HIST TOTAL" "$log" | head -10
  echo
}

# V1: Mode A, private VMEM, LRU            -> bin[1]=100%, inval=0, aliased=0  (negative control)
# V2: Mode A, shared VMEM, LRU             -> still bin[1]=100% (workload-driven)
# V3: Mode B, private VMEM, LRU            -> bin[1]=100% (current canneal behavior reproduces)
# V4: Mode B, shared VMEM, LRU             -> bin[k>=2]>0, inval>>0, aliased>>0  (POSITIVE)
# V5: Mode B, shared VMEM, COALESCE        -> same as V4 + COALESCE IPC distinct from V4
# V6: Mode C, shared VMEM, LRU             -> high bins, inval=0 (read-only sharing)

run_one V1 "$PRIVATE_8CORE_BIN" A "policy=LRU"
run_one V2 "$SHARED_8CORE_BIN"  A "policy=LRU"
run_one V3 "$PRIVATE_8CORE_BIN" B "policy=LRU"
run_one V4 "$SHARED_8CORE_BIN"  B "policy=LRU"
run_one V5 "$SHARED_8CORE_BIN"  B "policy=COALESCE"     # rebuild $SHARED_8CORE_BIN with replacement=coalesce first!
run_one V6 "$SHARED_8CORE_BIN"  C "policy=LRU"

echo "==== summary ===="
python3 "$(dirname "$0")/parse_overlay_results.py" "$RESULTS_DIR/logs/"
