#!/usr/bin/env bash
# The ChampSim half of the micro test (bench/policy_sanity/micro_design_2026-10-17.md),
# on the laptop: trace coherence_micro with Pin, cut the traces at the start
# marks, run ChampSim at levels 0 and 2 on the small hierarchy, and count the
# coherence events on the test lines from the per-request event log.
#
#   PIN_ROOT=... bench/micro_champsim.sh [CASES]     # ~1 h on 12 cores; ~10 GB of temporary traces
#
# Output: $OUT/summary.txt (default simulator/results/micro_champsim/).
set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
PIN_ROOT="${PIN_ROOT:-$HOME/programming-playground/misc/pin-external-3.31-98869-gfa6f126a8-gcc-linux}"
TRACER="${TRACER:?set TRACER to a champsim_tracer.so that knows -max_instr}"
BIN="${BIN:-$ROOT/simulator/bin/champsim}"
OUT="${OUT:-$ROOT/simulator/results/micro_champsim}"
# MICRO_SRC=bench/mutex_micro.c CONTROL_CASE=mx_lock: the real-mutex companion
# (sync_mutex_design_2026-10-19.md, Q2b); same markers, same counting.
MICRO_SRC="${MICRO_SRC:-$ROOT/bench/coherence_micro.c}"
CONTROL_CASE="${CONTROL_CASE:-pp_lock}"
CASES="${1:-pp_lock pp_store pp_rmw readers upgrade ctl priv_E priv_S llc_out offchip}"
ROUNDS="${ROUNDS:-4}"
JOBS="${JOBS:-5}"
mkdir -p "$OUT"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

# MICRO_CFLAGS=-DBARRIER_STEPS TRACER_ARGS="-sync 1": the synchronised-replay
# check (sync_replay_design_2026-10-18.md, Q2). STRIP_SYNC=1 then removes the
# sync records after tracing: the control, replayed without them.
gcc -O2 -pthread ${MICRO_CFLAGS:-} -o "$W/micro" "$MICRO_SRC" || exit 1
for L in 0 2; do
  "$ROOT/simulator/scripts/make_config.py" --policy lru --cores 4 --regime shared --private-coherence $L \
    | python3 -c "import json,sys; c=json.load(sys.stdin); c['L1D']['sets']=4; c['L2C']['sets']=16; c['LLC']['sets']=256; json.dump(c, open('$W/mini$L.json','w'), indent=1)"
done
echo "binary: $BIN ($(md5sum < "$BIN" | cut -c1-12)); program $(basename "$MICRO_SRC") md5 $(md5sum < "$MICRO_SRC" | cut -c1-12)" | tee "$OUT/summary.txt"

for c in control $CASES; do
  if [ "$c" = control ]; then cc=$CONTROL_CASE; r=0; else cc=$c; r=$ROUNDS; fi
  d="$W/$c"; mkdir -p "$d/trim"
  ( cd "$d" && "$PIN_ROOT/pin" -t "$TRACER" -o raw -max_instr 0 ${TRACER_ARGS:-} -- "$W/micro" "$cc" "$r" > run.out 2> pin.err ) || { echo "$c: Pin failed"; exit 1; }
  python3 "$ROOT/bench/micro_trim.py" "$d/run.out" "$d/raw" "$d/trim" > "$d/trim.txt" || { cat "$d/trim.txt"; echo "$c: trim failed"; exit 1; }
  rm -f "$d"/raw?.champsimtrace
  if [ -n "${STRIP_SYNC:-}" ]; then
    for k in 0 1 2 3; do
      python3 -c "import numpy as np,sys; DT=np.dtype([('ip','<u8'),('br','u1'),('tk','u1'),('dr','u1',2),('sr','u1',4),('dm','<u8',2),('sm','<u8',4)]); a=np.fromfile(sys.argv[1],dtype=DT); a[a['dm'][:,1]!=0x53594E4353594E43].tofile(sys.argv[1])" "$d/trim/t$k.champsimtrace"
    done
  fi
  n=$(awk '/^SIMULATE/ { print $2 }' "$d/trim.txt")
  for L in 0 2; do
    while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do sleep 5; done
    ( COHERENCE_EVENT_LOG="$d/ev$L.txt" "$BIN" --config "$W/mini$L.json" --warmup-instructions 0 --simulation-instructions "$n" \
        "$d/trim/t0.champsimtrace" "$d/trim/t1.champsimtrace" "$d/trim/t2.champsimtrace" "$d/trim/t3.champsimtrace" > "$d/cs$L.log" 2>&1
      cp "$d/cs$L.log" "$OUT/${c}_L$L.log"; cp "$d/run.out" "$OUT/${c}_run.out"; cp "$d/trim.txt" "$OUT/${c}_trim.txt"
      python3 - "$d/ev$L.txt" "$d/run.out" > "$OUT/${c}_L$L.xline" <<'PY'
import re, sys
ev, out = sys.argv[1], open(sys.argv[2]).read()
X = int(re.search(r'X (0x[0-9a-f]+)', out).group(1), 16) >> 6
P = A = U = UA = G = G5 = G5U = 0
for line in open(ev):
    p = line.split()
    if len(p) < 12 or p[0] not in 'GU' or p[9] == 'TRANSLATION':
        continue
    if not (X <= int(p[7], 16) < X + 64):
        continue
    g5 = len(p) > 12 and p[12] != '0'      # the gem5-rule view (b3_g5rule_design_2026-10-19.md), 13th field
    if p[0] == 'G':
        G += 1; P += p[10] != '0'; A += p[11] != '0'; G5 += g5
    else:
        U += p[10] != '0'; UA += p[11] != '0'; G5U += g5
print(f'xline ownership_requests {G} P {P} A {A} U {U} U_presence {UA} G5 {G5} G5U {G5U}')
PY
      rm -f "$d/ev$L.txt" ) &
  done
  echo "$c traced, ChampSim started"
done
wait
{ echo; echo "case level | X lines: P A U | whole run: P A B U | wrapped | X lines, gem5-rule view: G GU"
  for c in control $CASES; do for L in 0 2; do
    f="$OUT/${c}_L$L.log"
    tot=$(awk '/^Region of Interest/{r=1} r' "$f" | awk '
      /^LLC COHERENCE DIR RFO PROTOCOL-OTHER EVENTS:/{p=$NF} /^LLC COHERENCE DIR RFO PRESENCE-OTHER EVENTS:/{a=$NF}
      /^LLC COHERENCE DIR RFO BOUNDED-PROTOCOL EVENTS:/{b=$NF} /_(L1D|L2C|L1I) COHERENCE DIR UPGRADE EVENTS:/{u+=$NF}
      END{print p+0, a+0, b+0, u+0}')
    printf '%-9s L%s | %s | %s | %s | %s\n' "$c" "$L" "$(awk '{print $5, $7, $9}' "$OUT/${c}_L$L.xline")" "$tot" "$(grep -c 'Reached end of trace' "$f")" "$(awk '{print $13, $15}' "$OUT/${c}_L$L.xline")"
  done; done; } | tee -a "$OUT/summary.txt"
