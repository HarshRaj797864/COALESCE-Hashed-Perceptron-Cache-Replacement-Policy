#!/usr/bin/env bash
# B3 on held-out programs: radix, water-nsquared (waternsq), fmm -- SPLASH-3
# programs that played no part in the tool's development. For each: build a
# dynamic binary (for Pin) and a static one (for gem5) from the same objects,
# trace, align thread 0, count the window's instruction mix, run ChampSim at
# levels 0, 1 and 2, and start gem5. Detached; one program after another;
# stops a program at its first failed check.
# Pre-registered in bench/policy_sanity/b3_heldout_design_2026-10-14.md.
#
#   bash ~/b3_heldout.sh go [radix waternsq fmm]   # (scripts/b3_heldout_all.sh does this)
#   bash ~/b3_heldout.sh status
#
# Per program:
#   1. build     from a COPY of the server's SPLASH-3 source, the tree's flags,
#                fortify off: make (dynamic), then the same objects linked
#                -static for gem5. QB: every function defined in the program's
#                objects has the same instruction count and constants in both
#   2. inputs    radix: arguments only; waternsq: inputs/n512-p4 with 8 steps,
#                and random.in; fmm: inputs/input.4.16384 -> ~/b3_heldout/inputs
#   3. trace     Pin, 4 threads, 200 M records a thread -> traces/<p>_4t/.
#                QT: four full traces with memory operands in >= 5% of records
#   4. align     drop thread 0's serial start (barnes_std_traces.py anchor);
#                residual <= 100 records. The unaligned thread 0 is then
#                deleted (KEEP_UNALIGNED=1 keeps it) to save 12.8 GB
#   5. mix       records 50-150 M of each aligned trace, for b3_stream_check.py
#   6. ChampSim  LRU, 4 cores, 2 MB, levels 0, 1, 2 x shared, private,
#                50 M + 100 M -> results/phaseA_b3_h<level>_<p>4 (detached)
#   7. gem5      WL=<p> launch_b3_gem5.sh go: stops when a worker reaches 50 M
#                and 150 M (detached)
#
# It runs the frozen binary and its own launcher: bin/champsim and
# run_phase_a.sh are not touched. A rerun skips what is done.
set -uo pipefail
SELF="$(readlink -f "$0")"   # the script re-invokes itself after changing directory

R="${R:-$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy}"
S="$R/simulator"
SPLASH="${SPLASH:-$S/tracer/splash-3/codes}"
PIN="${PIN:-$S/tracer/pin/pin-external-3.31-98869-gfa6f126a8-gcc-linux/pin}"
TRACER="${TRACER:-$S/tracer/pin/obj-intel64/champsim_tracer.so}"
BIN="${BIN:-$S/bin/champsim_b3v4_69ebdcce}"
W="${W:-$HOME/b3_heldout}"
INPUTS="$W/inputs"                       # run_gem5_splash.sh reads HELDOUT_IN, default ~/b3_heldout/inputs
STATIC_DIR="${STATIC_DIR:-$HOME/splash-heldout}"
BUILD="${BUILD:-$HOME/b3_heldout_build}"
HELP="${HELP:-$HOME/barnes_std_traces.py}"
GEM5_LAUNCH="${GEM5_LAUNCH:-$HOME/launch_b3_gem5.sh}"
LOG="$W/pipeline.log"
PIDF="$W/.pipeline.pid"
DONE_MARKER="ChampSim completed all CPUs"
MAX_INSTR="${MAX_INSTR:-200000000}"
WARMUP="${WARMUP:-50000000}"
SIM="${SIM:-100000000}"
MIN_FREE_GB="${MIN_FREE_GB:-70}"
PROGS_DEFAULT="radix waternsq fmm"

alive() { [ -f "$1" ] && kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null; }
step() { echo; echo "=== $(date '+%F %T')  $P: $* ==="; }
fail() { echo "STOPPED ($P): $*"; return 1; }

# program -> source dir | binary | arguments | stdin file name (in $INPUTS) | extra input files | instructions skipped a thread
# radix skips 780 M: its workers generate keys, privately, for 780.1 M of their
# 1,007 M instructions before the first barrier (measured natively with Pin,
# 2026-10-14), so the window starts at SPLASH-3's region-of-interest point.
# gem5 stops at 830 M and 930 M for it (launch_b3_gem5.sh).
info() {
  case "$1" in
    radix)    echo "kernels/radix|RADIX|-p4 -n16777216 -r1024|||780000000" ;;
    waternsq) echo "apps/water-nsquared|WATER-NSQUARED||waternsq.in|random.in|0" ;;
    fmm)      echo "apps/fmm|FMM||fmm.in||0" ;;
    *) return 1 ;;
  esac
}

disasm() {
  objdump -d --no-show-raw-insn "$1" 2>/dev/null | awk '
    /^[0-9a-f]+ <.*>:$/ { fn = $2; sub(/^</, "", fn); sub(/>:$/, "", fn); next }
    /^ +[0-9a-f]+:/ { sub(/^ +[0-9a-f]+:[ \t]+/, ""); sub(/[ \t]+#.*$/, ""); print fn "\t" $0 }'
}
# Instructions per function, without alignment padding: objdump gives the
# padding after a function to that function, and a static link pads
# differently (radix's printout: "cs nopw; nop" after its last jmp, 2026-10-14
# rehearsal). fn_consts already skips the same mnemonics.
fn_sizes() { disasm "$1" | awk -F'\t' '$2 !~ /^(nop|cs |data16|int3|xchg +%ax,%ax)/ { n[$1]++ } END { for (f in n) print f, n[f] }' | LC_ALL=C sort; }
fn_consts() {
  disasm "$1" | awk -F'\t' '
    { fn = $1; line = $2; split(line, w, " ")
      if (w[1] ~ /^(j|call|nop|data16|cs|endbr)/) next
      gsub(/-?0x[0-9a-f]+\(%rip\)/, "", line)
      while (match(line, /\$0x[0-9a-f]+|-?0x[0-9a-f]+\(%r[a-z0-9]+/)) {
        c = substr(line, RSTART, RLENGTH); line = substr(line, RSTART + RLENGTH)
        if (c ~ /\(%rsp$|\(%rbp$/) continue
        kind = (c ~ /^\$/) ? "imm" : "off"; sub(/\(%r[a-z0-9]+$/, "", c); sub(/^\$/, "", c)
        v = c; sub(/^-/, "", v); if (length(v) > 7) continue
        print fn, kind, c } }' | LC_ALL=C sort -u
}

setp() {   # set the per-program variables for $1
  P="$1"
  IFS='|' read -r DIR NAME ARGS STDIN EXTRA SKIP <<< "$(info "$P")" || return 1
  [ -n "$NAME" ] || return 1
  PB="$BUILD/$P/codes/$DIR"
  DYN="$PB/$NAME.dyn"; STA="$PB/$NAME.static"
  TR="$S/traces/${P}_4t"
  PW="$W/$P"
  CS_PIDF="$PW/.champsim.pid"
}
trace_of() { [ "$1" = 0 ] && echo "$TR/${P}0_aligned.champsimtrace" || echo "$TR/${P}$1.champsimtrace"; }
tree_of() { echo "phaseA_b3_h$1_${P}4"; }
run_log() { echo "$S/results/$(tree_of "$1")/regime_$2/${P}_4core/lru/run.log"; }
jobs_list() { local lv rg; for lv in 0 1 2; do for rg in shared private; do echo "$P $lv $rg"; done; done; }
cs_done() { local n=0 p lv rg; while read -r p lv rg; do grep -q "$DONE_MARKER" "$(run_log "$lv" "$rg")" 2>/dev/null && n=$((n + 1)); done < <(jobs_list); echo "$n"; }

preflight() {
  step "1/8 preflight"
  local f n
  for f in "$PIN" "$TRACER" "$BIN" "$HELP" "$GEM5_LAUNCH" "$HOME/run_gem5_splash.sh" "$S/scripts/make_config.py" "$SPLASH/Makefile.config" "$SPLASH/$DIR/Makefile"; do
    [ -e "$f" ] || { fail "missing $f"; return 1; }
  done
  n=$(strings -a "$BIN" 2>/dev/null | grep -c 'PRIVATE-CACHE COHERENCE LEVEL')
  [ "${n:-0}" -gt 0 ] || { fail "$BIN is not a B3 v4 build"; return 1; }
  [ "$(grep -c 'radix|waternsq|fmm' "$GEM5_LAUNCH")" -gt 0 ] || { fail "$GEM5_LAUNCH has no held-out workloads -- upload it first"; return 1; }
  [ "$(grep -c 'go-waternsq-4c' "$HOME/run_gem5_splash.sh")" -gt 0 ] || { fail "~/run_gem5_splash.sh has no held-out workloads -- upload it first"; return 1; }
  [ "$(grep -c 'min_offset' "$HELP")" -gt 0 ] || { fail "$HELP is the old helper (no minimum-offset argument) -- upload it first"; return 1; }
  n=$(df --output=avail -BG "$S/traces" | tail -1 | tr -dc '0-9')
  echo "   $(basename "$BIN") md5 $(md5sum < "$BIN" | cut -c1-12); disk free ${n} GB"
  if [ ! -f "$TR/.traced" ]; then
    [ "$n" -ge "$MIN_FREE_GB" ] || { fail "only ${n} GB free; tracing $P needs about 65 GB (asking for $MIN_FREE_GB)"; return 1; }
  fi
}

build() {
  step "2/8 build, dynamic and static, from one set of objects"
  local base_cf cf objs fns f a b n bad=0 same=0
  rm -rf "${BUILD:?}/$P"; mkdir -p "$BUILD/$P/codes/$(dirname "$DIR")" || { fail "cannot create $BUILD/$P"; return 1; }
  cp -p "$SPLASH/Makefile.config" "$BUILD/$P/codes/" && cp -rp "$SPLASH/pthread_macros" "$BUILD/$P/codes/" \
    && cp -rp "$SPLASH/$DIR" "$BUILD/$P/codes/$DIR" || { fail "could not copy the source"; return 1; }
  cd "$PB" || { fail "no $PB"; return 1; }
  make clean > /dev/null 2>&1
  base_cf=$(grep -E '^\s*CFLAGS\s*[:+]?=' "$BUILD/$P/codes/Makefile.config" | head -1 | sed 's/^[^=]*=//')
  cf="$base_cf -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0"
  echo "   CFLAGS=\"$cf\""
  make CFLAGS="$cf" > "$PB/build.log" 2>&1 || { tail -5 "$PB/build.log" | sed 's/^/      /'; fail "make failed"; return 1; }
  [ -x "$NAME" ] || { fail "the build produced no $NAME"; return 1; }
  mv -f "$NAME" "$DYN"
  objs=$(ls ./*.o)
  # shellcheck disable=SC2086 -- a list of object files
  gcc $cf -o "$STA" $objs -lm -static >> "$PB/build.log" 2>&1 || { tail -5 "$PB/build.log" | sed 's/^/      /'; fail "the static link failed"; return 1; }
  cd "$HOME" || true
  file -b "$DYN" | grep -q 'dynamically linked' || { fail "$NAME.dyn is not dynamically linked"; return 1; }
  file -b "$STA" | grep -q 'statically linked' || { fail "$NAME.static is not statically linked"; return 1; }
  # shellcheck disable=SC2086
  fns=$(cd "$PB" && nm --defined-only $objs 2>/dev/null | awk '$2 ~ /^[Tt]$/ { print $3 }' | LC_ALL=C sort -u)
  [ -n "$fns" ] || { fail "no functions found in the objects"; return 1; }
  fn_sizes "$DYN" > "$PW/sizes_dyn.txt"; fn_sizes "$STA" > "$PW/sizes_static.txt"
  fn_consts "$DYN" > "$PW/consts_dyn.txt"; fn_consts "$STA" > "$PW/consts_static.txt"
  for f in $fns; do
    a=$(awk -v f="$f" '$1 == f { print $2 }' "$PW/sizes_dyn.txt"); b=$(awk -v f="$f" '$1 == f { print $2 }' "$PW/sizes_static.txt")
    if [ -z "$a" ] || [ "$a" != "$b" ]; then echo "   $f: ${a:-absent} instructions dynamic, ${b:-absent} static"; bad=$((bad + 1)); continue; fi
    n=$(diff <(awk -v f="$f" '$1 == f' "$PW/consts_dyn.txt") <(awk -v f="$f" '$1 == f' "$PW/consts_static.txt") | grep -c '^[<>]')
    if [ "$n" != 0 ]; then echo "   $f: $n constant(s) differ"; bad=$((bad + 1)); continue; fi
    same=$((same + 1))
  done
  [ "$bad" = 0 ] || { fail "QB: $bad of $(echo "$fns" | wc -w) functions differ between the dynamic and the static binary"; return 1; }
  echo "   QB: all $same functions of $NAME's objects have the same instruction count and constants in both binaries"
  echo "   dynamic md5 $(md5sum < "$DYN" | cut -c1-12), static md5 $(md5sum < "$STA" | cut -c1-12)"
  mkdir -p "$STATIC_DIR"
  if [ -f "$STATIC_DIR/$NAME" ] && ! cmp -s "$STATIC_DIR/$NAME" "$STA"; then
    mv -f "$STATIC_DIR/$NAME" "$STATIC_DIR/$NAME.prev_$(date +%Y%m%d_%H%M%S)"
  fi
  cp -p "$STA" "$STATIC_DIR/$NAME" || { fail "could not install the static binary"; return 1; }
  echo "   gem5 binary: $STATIC_DIR/$NAME"
}

inputs() {
  step "3/8 inputs"
  mkdir -p "$INPUTS"
  case "$P" in
    radix) echo "   arguments: $ARGS" ;;
    waternsq)
      awk 'NR == 1 { $3 = 8 } { print }' "$SPLASH/$DIR/inputs/n512-p4" > "$INPUTS/waternsq.in" || { fail "no n512-p4"; return 1; }
      cp -p "$SPLASH/$DIR/random.in" "$INPUTS/random.in" || { fail "no random.in"; return 1; }
      [ "$(head -1 "$INPUTS/waternsq.in" | awk '{ print $2, $3 }')" = "512 8" ] || { fail "waternsq.in's first line is not 512 molecules, 8 steps"; return 1; }
      echo "   waternsq.in: $(head -1 "$INPUTS/waternsq.in")  (n512-p4 with 8 steps); random.in" ;;
    fmm)
      cp -p "$SPLASH/$DIR/inputs/input.4.16384" "$INPUTS/fmm.in" || { fail "no input.4.16384"; return 1; }
      [ "$(sed -n 3p "$INPUTS/fmm.in"):$(sed -n 5p "$INPUTS/fmm.in")" = "16384:4" ] || { fail "fmm.in is not 16384 bodies on 4 processors"; return 1; }
      echo "   fmm.in: input.4.16384 (16384 bodies, 4 processors)" ;;
  esac
}

trace() {
  step "4/8 trace"
  local i f n md5 want=$((MAX_INSTR * 64)) in=/dev/null
  md5=$(md5sum < "$DYN" | cut -c1-32)
  mkdir -p "$TR" "$HOME/.build_tmp" "$PW" || { fail "cannot create $TR"; return 1; }
  if [ -f "$TR/.traced" ] && [ "$(cat "$TR/.traced")" = "$md5" ]; then echo "   already traced from this binary -- skipped"; return 0; fi
  rm -f "$TR"/"$P"*.champsimtrace "$TR/.traced" "$TR/OFFSET" "$TR/.aligned"
  [ -z "$STDIN" ] || in="$INPUTS/$STDIN"
  [ -z "$EXTRA" ] || cp -p "$INPUTS/$EXTRA" "$TR/$EXTRA"
  echo "   pin -t champsim_tracer.so -o $P -skip_instr $SKIP -max_instr $MAX_INSTR -- $NAME.dyn $ARGS < $(basename "$in")   (in $TR)"
  # shellcheck disable=SC2086 -- $ARGS is the program's argument list
  ( cd "$TR" && TMPDIR="$HOME/.build_tmp" nice -n 10 "$PIN" -t "$TRACER" -o "$P" -skip_instr "$SKIP" -max_instr "$MAX_INSTR" -- "$DYN" $ARGS < "$in" ) > "$PW/trace_gen.log" 2>&1
  n=$?
  grep -v '^\s*$' "$PW/trace_gen.log" | sed -n '1,4p' | cut -c1-160 | sed 's/^/   /'
  [ "$n" = 0 ] || { fail "Pin exited with $n ($PW/trace_gen.log)"; return 1; }
  n=$(ls "$TR/$P"[0-9]*.champsimtrace 2>/dev/null | wc -l)
  [ "$n" = 4 ] || { fail "$n trace files, expected 4: $(ls "$TR" | tr '\n' ' ')"; return 1; }
  : > "$PW/samples.txt"
  for i in 0 1 2 3; do
    f="$TR/$P$i.champsimtrace"
    [ "$(stat -c %s "$f")" = "$want" ] || { fail "$(basename "$f") is $(stat -c %s "$f") bytes, expected $want"; return 1; }
    python3 "$HELP" sample "$f" | tee -a "$PW/samples.txt" | sed 's/^/   /'
    n=$(tail -1 "$PW/samples.txt" | awk '{ print int($NF) }')
    # 5%, not barnes's 20%: radix's thread 0 reads 14% while it generates keys
    # (rehearsal, 2026-10-14). The check is for the 2026-09 tracer bug, which
    # read 0.0% on every thread but 0.
    [ "$n" -ge 5 ] || { fail "$(basename "$f") carries memory operands in only ${n}% of its records"; return 1; }
  done
  echo "$md5" > "$TR/.traced"
}

align() {
  step "5/8 align thread 0"
  local off out res
  out=$(trace_of 0)
  if [ -f "$TR/.aligned" ] && [ -f "$out" ]; then
    echo "   already aligned: thread 0 starts $(cat "$TR/OFFSET") records in -- skipped"
  else
    ANCHOR_WORKER_RECORDS="${ANCHOR_WORKER_RECORDS:-60000000}" ANCHOR_MAX_SPREAD="${ANCHOR_MAX_SPREAD:-10000}" python3 "$HELP" anchor "$TR/${P}0.champsimtrace" "$TR/${P}1.champsimtrace" "$TR/${P}2.champsimtrace" "$TR/${P}3.champsimtrace" 0 > "$PW/anchor.txt" 2>&1 \
      || { sed 's/^/   /' "$PW/anchor.txt"; fail "could not find the start of the parallel section"; return 1; }
    sed 's/^/   /' "$PW/anchor.txt"
    off=$(awk '$1 == "OFFSET" { print $2 }' "$PW/anchor.txt")
    [ -n "$off" ] && [ "$off" -ge 0 ] || { fail "no offset"; return 1; }
    tail -c +"$((off * 64 + 1))" "$TR/${P}0.champsimtrace" > "$out.tmp" && mv -f "$out.tmp" "$out" || { fail "could not write the aligned trace"; return 1; }
    [ "$(stat -c %s "$out")" = "$(( (MAX_INSTR - off) * 64 ))" ] || { fail "the aligned trace has the wrong size"; return 1; }
    echo "$off" > "$TR/OFFSET"
  fi
  res=$(ANCHOR_WORKER_RECORDS="${ANCHOR_WORKER_RECORDS:-60000000}" ANCHOR_MAX_SPREAD="${ANCHOR_MAX_SPREAD:-10000}" python3 "$HELP" residual "$out" "$TR/${P}1.champsimtrace" "$TR/${P}2.champsimtrace" "$TR/${P}3.champsimtrace" 2>&1 | awk '$1 == "RESIDUAL" { print $2 }')
  echo "   thread 0 starts $(cat "$TR/OFFSET") records in ($(( MAX_INSTR - $(cat "$TR/OFFSET") )) left); shift still left: ${res:-?} records"
  [ -n "$res" ] && [ "${res#-}" -le 100 ] || { fail "after aligning, thread 0 is still ${res:-?} records off the others"; return 1; }
  touch "$TR/.aligned"
  if [ "${KEEP_UNALIGNED:-0}" != 1 ] && [ -f "$TR/${P}0.champsimtrace" ]; then
    rm -f "$TR/${P}0.champsimtrace" && echo "   the unaligned thread 0 is deleted (KEEP_UNALIGNED=1 keeps it)"
  fi
}

mix() {
  step "6/8 the window's instruction mix"
  local i
  : > "$PW/trace_mix.txt.tmp"
  for i in 0 1 2 3; do python3 "$HELP" mix "${P}_4t_window_t$i" "$(trace_of "$i")" "$WARMUP" "$SIM" >> "$PW/trace_mix.txt.tmp" & done
  wait
  LC_ALL=C sort "$PW/trace_mix.txt.tmp" > "$PW/trace_mix.txt" && rm -f "$PW/trace_mix.txt.tmp"
  sed 's/^/   /' "$PW/trace_mix.txt"
  [ "$(wc -l < "$PW/trace_mix.txt")" = 4 ] || { fail "the mix file is short"; return 1; }
}

champsim_job() {   # prog level regime
  setp "$1" || return 0
  local lv="$2" rg="$3" log
  log=$(run_log "$lv" "$rg")
  if grep -q "$DONE_MARKER" "$log" 2>/dev/null; then echo "$(date '+%F %T') SKIP  $P level $lv $rg (complete)"; return 0; fi
  mkdir -p "$(dirname "$log")"
  echo "$(date '+%F %T') START $P level $lv $rg"
  nice -n 19 "$BIN" --config "$PW/cfg_${rg}_l$lv.json" --warmup-instructions "$WARMUP" --simulation-instructions "$SIM" \
    "$(trace_of 0)" "$(trace_of 1)" "$(trace_of 2)" "$(trace_of 3)" > "$log" 2>&1
  echo "$(date '+%F %T') END   $P level $lv $rg rc=$? $(grep -c "$DONE_MARKER" "$log") complete"
}

champsim_driver() {   # prog
  setp "$1" || return 1
  echo $$ > "$CS_PIDF"
  echo "$(date '+%F %T') QUEUE START $P ($(jobs_list | wc -l) jobs, $(basename "$BIN"))"
  jobs_list | xargs -P 6 -L 1 bash "$SELF" __job
  echo "$(date '+%F %T') QUEUE END $P: $(cs_done) of $(jobs_list | wc -l) complete"
  rm -f "$CS_PIDF"
}

launch_champsim() {
  step "7/8 ChampSim: $(jobs_list | wc -l) runs"
  local lv rg have need
  for lv in 0 1 2; do for rg in shared private; do
    "$S/scripts/make_config.py" --policy lru --cores 4 --regime "$rg" --private-coherence "$lv" -o "$PW/cfg_${rg}_l$lv.json" > /dev/null 2>&1 \
      || { fail "make_config.py failed for $rg, level $lv"; return 1; }
    [ "$(grep -c "\"private_coherence\": $lv" "$PW/cfg_${rg}_l$lv.json")" = 1 ] || { fail "the $rg level-$lv config does not carry the level"; return 1; }
  done; done
  # ChampSim reopens a trace that ends and says nothing (repeatable::eof):
  # the aligned thread 0 must hold the run with the runners' 15% margin.
  have=$(( MAX_INSTR - $(cat "$TR/OFFSET") )); need=$(( (WARMUP + SIM) * 115 / 100 ))
  [ "$need" -le "$have" ] || { fail "the run needs $need records a core with its margin; the aligned thread 0 has $have"; return 1; }
  if alive "$CS_PIDF"; then echo "   already running (pid $(cat "$CS_PIDF")) -- left alone"; return 0; fi
  echo "   $(basename "$BIN"), $WARMUP + $SIM; thread 0 has $have records, $need needed; already complete: $(cs_done)"
  setsid bash "$SELF" __champsim "$P" >> "$PW/champsim.log" 2>&1 < /dev/null &
  disown 2>/dev/null
  sleep 3
  alive "$CS_PIDF" || [ "$(cs_done)" = 6 ] || { fail "the ChampSim driver did not start ($PW/champsim.log)"; return 1; }
  echo "   started; log $PW/champsim.log"
}

launch_gem5() {
  step "8/8 gem5: stops when a worker reaches 50 M and 150 M"
  WL="$P" HELDOUT_IN="$INPUTS" bash "$GEM5_LAUNCH" go 2>&1 | sed 's/^/   /'
  [ "${PIPESTATUS[0]}" -eq 0 ] || { fail "the gem5 launch failed"; return 1; }
}

one_program() {
  setp "$1" || { echo "STOPPED: unknown program $1"; return 1; }
  mkdir -p "$PW"
  preflight && build && inputs && trace && align && mix && launch_champsim && launch_gem5 \
    && { echo; echo "=== $(date '+%F %T')  $P: pipeline done -- ChampSim and gem5 continue in the background ==="; }
}

pipeline() {
  echo $$ > "$PIDF"
  local p
  for p in "$@"; do one_program "$p"; done
  rm -f "$PIDF"
  echo; echo "=== $(date '+%F %T')  all programs handled ==="
}

case "${1:-}" in
  go)
    shift; progs="${*:-$PROGS_DEFAULT}"
    for p in $progs; do info "$p" > /dev/null || { echo "unknown program $p (radix, waternsq, fmm)"; exit 1; }; done
    mkdir -p "$W"
    if alive "$PIDF"; then echo "the pipeline is already running (pid $(cat "$PIDF")) -- 'status'"; exit 0; fi
    # shellcheck disable=SC2086
    setsid bash "$SELF" __pipeline $progs > "$LOG" 2>&1 < /dev/null &
    disown 2>/dev/null
    echo "started in the background for: $progs; log: $LOG"
    echo "check: bash $0 status" ;;
  __pipeline) shift; pipeline "$@" ;;
  __champsim) champsim_driver "$2" ;;
  __job)      shift; champsim_job "$@" ;;
  status)
    if alive "$PIDF"; then echo "(pipeline still working)"; fi
    [ -f "$LOG" ] && sed 's/^/ /' "$LOG" || { echo "not started"; exit 0; }
    for p in $PROGS_DEFAULT; do
      setp "$p"
      [ -d "$PW" ] || continue
      echo; echo " $P: ChampSim runs complete $(cs_done) of 6; driver $(alive "$CS_PIDF" && echo alive || echo 'not running')"
      [ -f "$PW/champsim.log" ] && tail -3 "$PW/champsim.log" | sed 's/^/    /'
      [ -f "$GEM5_LAUNCH" ] && WL="$P" bash "$GEM5_LAUNCH" status 2>&1 | sed 's/^/    /'
    done ;;
  *) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
