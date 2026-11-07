#!/usr/bin/env bash
# ChampSim on SPLASH-3's barnes as shipped (10-body leaves): build it, trace
# it, align the traces, run ChampSim at levels 0, 1 and 2, and give gem5 one
# more stop. Detached, one step at a time, stopping at the first failure.
# Pre-registered in bench/policy_sanity/b3_barnes_std_design_2026-10-13.md.
#
#   bash ~/barnes_std.sh go        # (scripts/barnes_std_all.sh does this)
#   bash ~/barnes_std.sh status
#
# WHY. The barnes_4t traces are of a BARNES built with MAX_BODIES_PER_LEAF 256
# (b3_barnes_stream_2026-10-12.md). gem5 ran the standard program. This traces
# the standard program, so the two simulators can be compared on the benchmark
# as its authors ship it.
#
#   1. preflight  Pin, the tracer, the frozen ChampSim binary, disk
#   2. build      a dynamic BARNES from a COPY of the source (the tree and the
#                 old traced binary are not touched): the tree's flags, fortify
#                 off as in gem5's static binary. STOP unless its leaves hold
#                 10 bodies and its force and tree-build functions equal that
#                 static binary's in instruction count and constants
#   3. trace      Pin, 4 threads, the traced input, 200 M records a thread ->
#                 traces/barnes_std_4t/barnes{0..3}.champsimtrace. STOP unless
#                 there are exactly four full traces that carry memory operands
#   4. align      thread 0 is the main thread: its trace opens with the
#                 program's serial start. Drop that, so all four start at the
#                 same point of the program (barnes_std_traces.py anchor), and
#                 measure what shift is left
#   5. guard      read-modify-writes per 1,000 instructions must be the
#                 standard program's (gem5 executed 10.6; the 256-body-leaf
#                 build makes 26.8) -- else STOP. Then count the instruction
#                 mix of each span, for the laptop's same-stream check
#   6. ChampSim   LRU, 4 cores, 2 MB, both regimes, levels 0, 1 and 2, three
#                 spans (18 runs, $JOBS at a time, nice 19):
#                   start   0 + 37.9 M      the tree build and the first third of the forces
#                   force   37.9 M + 50 M   inside the first force phase
#                   window  37.9 M + 100 M  gem5's 50-150 M window, across the step boundary
#                 -> results/phaseA_b3_x<level>_barnesstd4[_start|_force]
#   7. gem5       the standard static BARNES stopped at 100 M as well, which
#                 with the 50 M stop bounds the "force" span
#
# It runs the frozen binary and its own launcher: bin/champsim and
# run_phase_a.sh are not touched, so it can run beside a sweep. A rerun skips
# what is done: traces whose binary is unchanged, runs that completed.
set -uo pipefail

R="${R:-$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy}"
S="$R/simulator"
SPLASH="${SPLASH:-$S/tracer/splash-3/codes}"
PIN="${PIN:-$S/tracer/pin/pin-external-3.31-98869-gfa6f126a8-gcc-linux/pin}"
TRACER="${TRACER:-$S/tracer/pin/obj-intel64/champsim_tracer.so}"
BIN="${BIN:-$S/bin/champsim_b3v4_69ebdcce}"
GEM5_STATIC="${GEM5_STATIC:-$HOME/splash-static/BARNES}"
INPUT="$SPLASH/apps/barnes/inputs/n16384-p4"
BUILD="$HOME/barnes_std_build"
NEW="$BUILD/codes/apps/barnes/BARNES"
TR="$S/traces/barnes_std_4t"
W="$HOME/barnes_std"
LOG="$W/pipeline.log"
PIDF="$W/.pipeline.pid"
CS_PIDF="$W/.champsim.pid"
HELP="$HOME/barnes_std_traces.py"
DONE_MARKER="ChampSim completed all CPUs"
MAX_INSTR="${MAX_INSTR:-200000000}"
JOBS="${JOBS:-9}"
MIN_FREE_GB="${MIN_FREE_GB:-90}"
# span | warm-up | measured, in instructions per core. Overridable to rehearse.
SPANS="${SPANS:-start|0|37900000
force|37900000|50000000
window|37900000|100000000}"
# The guard reads GUARD_N records from GUARD_AT of each trace.
GUARD_AT="${GUARD_AT:-60000000}"
GUARD_N="${GUARD_N:-5000000}"
GUARD_LO="${GUARD_LO:-8}"
GUARD_HI="${GUARD_HI:-13.5}"
# The functions the comparison with gem5's binary must match exactly.
MUST="gravsub walksub hackgrav hackwalk subdivp ComputeForces stepsystem loadtree SubdivideLeaf hackcofm maketree"

alive() { [ -f "$1" ] && kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null; }
step() { echo; echo "=== $(date '+%F %T')  $* ==="; }
fail() { echo "STOPPED: $*"; rm -f "$PIDF"; exit 1; }

disasm() {
  objdump -d --no-show-raw-insn "$1" 2>/dev/null | awk '
    /^[0-9a-f]+ <.*>:$/ { fn = $2; sub(/^</, "", fn); sub(/>:$/, "", fn); next }
    /^ +[0-9a-f]+:/ { sub(/^ +[0-9a-f]+:[ \t]+/, ""); sub(/[ \t]+#.*$/, ""); print fn "\t" $0 }'
}
leaf_cmp() { disasm "$1" | awk -F'\t' '$1 == "loadtree" && $2 ~ /^cmp[a-z]* +\$0x(a|100),/ { match($2, /\$0x[0-9a-f]+/); print substr($2, RSTART + 1, RLENGTH - 1) }' | sort -u | tr '\n' ' '; }
fn_sizes() { disasm "$1" | awk -F'\t' '{ n[$1]++ } END { for (f in n) print f, n[f] }' | LC_ALL=C sort; }
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
trace_of() { [ "$1" = 0 ] && echo "$TR/barnes0_aligned.champsimtrace" || echo "$TR/barnes$1.champsimtrace"; }
# tree name for a level and a span
tree_of() { echo "phaseA_b3_x$1_barnesstd4$( [ "$2" = window ] || echo "_$2" )"; }
run_log() { echo "$S/results/$(tree_of "$1" "$2")/regime_$3/barnes_4core/lru/run.log"; }
jobs_list() {   # level span regime warmup sim
  local sp wu si lv rg
  while IFS='|' read -r sp wu si; do
    for lv in 0 1 2; do for rg in shared private; do echo "$lv $sp $rg $wu $si"; done; done
  done <<< "$SPANS"
}

preflight() {
  step "1/7 preflight"
  local n f
  for f in "$PIN" "$TRACER" "$INPUT" "$BIN" "$GEM5_STATIC" "$HELP" "$S/scripts/make_config.py" "$HOME/launch_b3_gem5.sh" "$HOME/run_gem5_splash.sh"; do
    [ -e "$f" ] || fail "missing $f"
  done
  n=$(strings -a "$BIN" 2>/dev/null | grep -c 'PRIVATE-CACHE COHERENCE LEVEL')
  [ "${n:-0}" -gt 0 ] || fail "$BIN is not a B3 v4 build"
  n=$("$S/scripts/make_config.py" --policy lru --cores 4 --regime shared --private-coherence 2 2>/dev/null | grep -c '"private_coherence": 2')
  [ "${n:-0}" = 1 ] || fail "the deployed make_config.py has no --private-coherence"
  n=$(grep -c '100000000' "$HOME/launch_b3_gem5.sh")
  [ "${n:-0}" -gt 0 ] || fail "~/launch_b3_gem5.sh has no 100 M stop -- upload it first"
  n=$(df --output=avail -BG "$S/traces" | tail -1 | tr -dc '0-9')
  echo "   $(basename "$BIN") md5 $(md5sum < "$BIN" | cut -c1-12); disk free ${n} GB; $JOBS ChampSim runs at a time"
  if [ ! -f "$TR/traced_binary.md5" ]; then
    [ "$n" -ge "$MIN_FREE_GB" ] || fail "only ${n} GB free; the four traces and the aligned copy need about 65 GB (asking for $MIN_FREE_GB)"
  fi
  n=$(pgrep -u "$(id -u)" -fc '[b]arnes_std_build/codes/apps/barnes/BARNES' 2>/dev/null)
  [ "${n:-0}" = 0 ] || fail "a trace of this program is already being made ($n process(es))"
}

build() {
  step "2/7 build the standard BARNES, dynamic, in a copy"
  local n base_cf cf f a b
  rm -rf "$BUILD"; mkdir -p "$BUILD/codes/apps" || fail "cannot create $BUILD"
  cp -p "$SPLASH/Makefile.config" "$BUILD/codes/" && cp -rp "$SPLASH/pthread_macros" "$BUILD/codes/" && cp -rp "$SPLASH/apps/barnes" "$BUILD/codes/apps/" \
    || fail "could not copy the barnes source"
  cd "$BUILD/codes/apps/barnes" || fail "no build directory"
  make clean > /dev/null 2>&1
  [ "$(grep -c '^#define MAX_BODIES_PER_LEAF 10$' defs.h.in)" = 1 ] || fail "defs.h.in does not say '#define MAX_BODIES_PER_LEAF 10' -- the source is not the standard one"
  base_cf=$(grep -E '^\s*CFLAGS\s*[:+]?=' "$BUILD/codes/Makefile.config" | head -1 | sed 's/^[^=]*=//')
  cf="$base_cf -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0"
  echo "   CFLAGS=\"$cf\""
  make CFLAGS="$cf" > "$BUILD/build.log" 2>&1 || { tail -8 "$BUILD/build.log" | sed 's/^/      /'; fail "the build failed ($BUILD/build.log)"; }
  [ -x "$NEW" ] || fail "the build produced no BARNES"
  cd "$HOME" || true
  file -b "$NEW" | grep -c 'dynamically linked' > /dev/null || fail "the new BARNES is not dynamically linked"
  echo "   new binary: $(ls -l "$NEW" | awk '{print $5}') bytes, md5 $(md5sum < "$NEW" | cut -c1-12), dynamic; loadtree compares a leaf's body count with: $(leaf_cmp "$NEW")(0xa = 10)"
  [ "$(leaf_cmp "$NEW")" = "0xa " ] || fail "the new binary does not read as a 10-body-leaf build"
  [ "$(leaf_cmp "$GEM5_STATIC")" = "0xa " ] || fail "gem5's static binary does not read as a 10-body-leaf build"
  for f in $MUST; do
    a=$(fn_sizes "$GEM5_STATIC" | awk -v f="$f" '$1 == f { print $2 }'); b=$(fn_sizes "$NEW" | awk -v f="$f" '$1 == f { print $2 }')
    [ -n "$a" ] && [ -n "$b" ] || { echo "   $f: not a separate function in both (gem5's '${a:-none}', new '${b:-none}')"; continue; }
    [ "$a" = "$b" ] || fail "$f has $a instructions in gem5's binary and $b in the new one -- not the same code"
    n=$(diff <(fn_consts "$GEM5_STATIC" | awk -v f="$f" '$1 == f') <(fn_consts "$NEW" | awk -v f="$f" '$1 == f') | grep -c '^[<>]')
    if [ "$n" != 0 ]; then
      diff <(fn_consts "$GEM5_STATIC" | awk -v f="$f" '$1 == f') <(fn_consts "$NEW" | awk -v f="$f" '$1 == f') | grep '^[<>]' | head -6 | sed 's/^/      /'
      fail "$f differs from gem5's binary in $n constant(s) (< gem5's, > new)"
    fi
    echo "   $f: $a instructions, same constants"
  done
  echo "   the force and tree-build functions match the binary gem5 ran"
}

trace() {
  step "3/7 trace it"
  local i f n md5 want=$((MAX_INSTR * 64))
  md5=$(md5sum < "$NEW" | cut -c1-32)
  mkdir -p "$TR" "$HOME/.build_tmp" || fail "cannot create $TR"
  if [ "$(cat "$TR/traced_binary.md5" 2>/dev/null)" = "$md5" ]; then
    n=0; for i in 0 1 2 3; do [ "$(stat -c %s "$TR/barnes$i.champsimtrace" 2>/dev/null)" = "$want" ] && n=$((n + 1)); done
    if [ "$n" = 4 ]; then echo "   already traced from this binary ($md5): four full traces -- skipped"; return 0; fi
  fi
  rm -f "$TR"/barnes*.champsimtrace "$TR/traced_binary.md5" "$TR/OFFSET"
  echo "   pin -t champsim_tracer.so -o barnes -max_instr $MAX_INSTR -- BARNES < n16384-p4   (in $TR)"
  # /tmp on this machine is the full root filesystem: Pin's temporaries go to $HOME.
  ( cd "$TR" && TMPDIR="$HOME/.build_tmp" nice -n 10 "$PIN" -t "$TRACER" -o barnes -max_instr "$MAX_INSTR" -- "$NEW" < "$INPUT" ) > "$W/trace_gen.log" 2>&1
  n=$?
  grep -v '^\s*$' "$W/trace_gen.log" | sed -n '1,5p' | cut -c1-160 | sed 's/^/   /'
  [ "$n" = 0 ] || fail "Pin exited with $n ($W/trace_gen.log)"
  n=$(ls "$TR"/barnes[0-9]*.champsimtrace 2>/dev/null | wc -l)
  [ "$n" = 4 ] || fail "$n trace files, expected 4: $(ls "$TR" | tr '\n' ' ')"
  for i in 0 1 2 3; do
    f="$TR/barnes$i.champsimtrace"
    [ "$(stat -c %s "$f")" = "$want" ] || fail "$(basename "$f") is $(stat -c %s "$f") bytes, expected $want ($MAX_INSTR records)"
    python3 "$HELP" sample "$f" | tee -a "$W/samples.txt" | sed 's/^/   /'
    n=$(tail -1 "$W/samples.txt" | awk '{print int($NF)}')
    [ "$n" -ge 20 ] || fail "$(basename "$f") carries memory operands in only ${n}% of its records"
  done
  echo "$md5" > "$TR/traced_binary.md5"
}

align() {
  step "4/7 align thread 0 with the others"
  local off out="$TR/barnes0_aligned.champsimtrace" res
  if [ -f "$TR/OFFSET" ] && [ -f "$out" ] && [ "$(stat -c %s "$out")" = "$(( (MAX_INSTR - $(cat "$TR/OFFSET")) * 64 ))" ]; then
    echo "   already aligned: thread 0 starts $(cat "$TR/OFFSET") records in -- skipped"
  else
    python3 "$HELP" anchor "$TR"/barnes0.champsimtrace "$TR"/barnes1.champsimtrace "$TR"/barnes2.champsimtrace "$TR"/barnes3.champsimtrace > "$W/anchor.txt" 2>&1 \
      || { sed 's/^/   /' "$W/anchor.txt"; fail "could not find the start of the parallel section"; }
    sed 's/^/   /' "$W/anchor.txt"
    off=$(awk '$1 == "OFFSET" { print $2 }' "$W/anchor.txt")
    [ -n "$off" ] && [ "$off" -gt 0 ] || fail "no offset"
    tail -c +"$((off * 64 + 1))" "$TR/barnes0.champsimtrace" > "$out.tmp" && mv -f "$out.tmp" "$out" || fail "could not write the aligned trace"
    [ "$(stat -c %s "$out")" = "$(( (MAX_INSTR - off) * 64 ))" ] || fail "the aligned trace has the wrong size"
    echo "$off" > "$TR/OFFSET"
  fi
  res=$(python3 "$HELP" residual "$out" "$TR"/barnes1.champsimtrace "$TR"/barnes2.champsimtrace "$TR"/barnes3.champsimtrace 2>&1 | awk '$1 == "RESIDUAL" { print $2 }')
  echo "   thread 0 now starts $(cat "$TR/OFFSET") records in ($(( MAX_INSTR - $(cat "$TR/OFFSET") )) left); shift still left: ${res:-?} records"
  [ -n "$res" ] && [ "${res#-}" -le 100 ] || fail "after aligning, thread 0 is still ${res:-?} records off the others"
}

guard_and_mix() {
  step "5/7 is it the standard program? and the instruction mix of each span"
  local i v bad=0 off sp wu si
  off=$(cat "$TR/OFFSET")
  for i in 0 1 2 3; do
    v=$(python3 "$HELP" mix "guard_t$i" "$(trace_of "$i")" "$GUARD_AT" "$GUARD_N" | tee -a "$W/guard.txt" | awk '{ for (j = 1; j < NF; j++) if ($j == "rmw_per_ki") print $(j + 1) }')
    echo "   thread $i, records $GUARD_AT + $GUARD_N: $v read-modify-writes per 1,000 instructions"
    awk -v v="$v" -v lo="$GUARD_LO" -v hi="$GUARD_HI" 'BEGIN { exit !(v >= lo && v <= hi) }' || bad=$((bad + 1))
  done
  [ "$bad" = 0 ] || fail "$bad thread(s) outside $GUARD_LO-$GUARD_HI read-modify-writes per 1,000 instructions (gem5's standard run: 10.6; the 256-body-leaf build: 26.8) -- this is not the standard program; nothing launched"
  echo "   all four inside $GUARD_LO-$GUARD_HI: the standard program"
  # For b3_stream_check.py. The start span is compared with gem5's run from
  # its beginning, which holds thread 0's serial start, so thread 0 is counted
  # there from the unaligned trace.
  : > "$W/trace_mix.txt.tmp"
  while IFS='|' read -r sp wu si; do
    for i in 0 1 2 3; do
      if [ "$sp" = start ] && [ "$i" = 0 ]; then python3 "$HELP" mix "barnes_std_4t_${sp}_t$i" "$TR/barnes0.champsimtrace" 0 "$((off + si))"
      else python3 "$HELP" mix "barnes_std_4t_${sp}_t$i" "$(trace_of "$i")" "$wu" "$si"; fi >> "$W/trace_mix.txt.tmp" &
    done
    wait
  done <<< "$SPANS"
  LC_ALL=C sort "$W/trace_mix.txt.tmp" > "$W/trace_mix.txt" && rm -f "$W/trace_mix.txt.tmp"
  sed 's/^/   /' "$W/trace_mix.txt"
  [ "$(wc -l < "$W/trace_mix.txt")" = "$(( $(echo "$SPANS" | wc -l) * 4 ))" ] || fail "the mix file is short"
}

champsim_job() {   # level span regime warmup sim
  local lv="$1" sp="$2" rg="$3" wu="$4" si="$5" log cfg
  log=$(run_log "$lv" "$sp" "$rg"); cfg="$W/cfg_${rg}_l$lv.json"
  if grep -q "$DONE_MARKER" "$log" 2>/dev/null; then echo "$(date '+%F %T') SKIP  level $lv $sp $rg (complete)"; return 0; fi
  mkdir -p "$(dirname "$log")"
  echo "$(date '+%F %T') START level $lv $sp $rg"
  nice -n 19 "$BIN" --config "$cfg" --warmup-instructions "$wu" --simulation-instructions "$si" \
    "$(trace_of 0)" "$(trace_of 1)" "$(trace_of 2)" "$(trace_of 3)" > "$log" 2>&1
  echo "$(date '+%F %T') END   level $lv $sp $rg rc=$? $(grep -c "$DONE_MARKER" "$log") complete"
}

champsim_driver() {
  echo $$ > "$CS_PIDF"
  echo "$(date '+%F %T') QUEUE START ($(jobs_list | wc -l) jobs, $JOBS at a time, $(basename "$BIN"))"
  jobs_list | xargs -P "$JOBS" -L 1 bash "$0" __job
  echo "$(date '+%F %T') QUEUE END: $(champsim_done) of $(jobs_list | wc -l) complete"
  rm -f "$CS_PIDF"
}
champsim_done() { local n=0 lv sp rg wu si; while read -r lv sp rg wu si; do grep -q "$DONE_MARKER" "$(run_log "$lv" "$sp" "$rg")" 2>/dev/null && n=$((n + 1)); done < <(jobs_list); echo "$n"; }

launch_champsim() {
  step "6/7 ChampSim: $(jobs_list | wc -l) runs"
  local lv rg
  for lv in 0 1 2; do for rg in shared private; do
    "$S/scripts/make_config.py" --policy lru --cores 4 --regime "$rg" --private-coherence "$lv" -o "$W/cfg_${rg}_l$lv.json" > /dev/null 2>&1 \
      || fail "make_config.py failed for $rg, level $lv"
    [ "$(grep -c "\"private_coherence\": $lv" "$W/cfg_${rg}_l$lv.json")" = 1 ] || fail "the $rg level-$lv config does not carry the level"
  done; done
  # ChampSim reopens a trace that ends and says nothing (repeatable::eof), so
  # the length is checked here: every core runs on past its count until the
  # slowest finishes, by a few percent; 15% is allowed.
  local sp wu si have need
  have=$(( MAX_INSTR - $(cat "$TR/OFFSET") ))
  while IFS='|' read -r sp wu si; do
    need=$(( (wu + si) * 115 / 100 ))
    [ "$need" -le "$have" ] || fail "span $sp needs $need records a core with its margin; the aligned thread 0 has $have"
  done <<< "$SPANS"
  echo "   the longest span needs $(echo "$SPANS" | awk -F'|' '{ n = ($2 + $3) * 1.15; if (n > m) m = n } END { printf "%d", m }') records a core with a 15% margin; thread 0 has $have"
  if alive "$CS_PIDF"; then echo "   the ChampSim runs are already going (pid $(cat "$CS_PIDF")) -- left alone"; return 0; fi
  echo "   traces: $(trace_of 0 | xargs basename) + barnes1..3; binary $(basename "$BIN"); already complete: $(champsim_done)"
  setsid bash "$0" __champsim >> "$W/champsim.log" 2>&1 < /dev/null &
  disown 2>/dev/null
  sleep 3
  alive "$CS_PIDF" || [ "$(champsim_done)" = "$(jobs_list | wc -l)" ] || fail "the ChampSim driver did not start ($W/champsim.log)"
  echo "   started; log $W/champsim.log"
}

launch_gem5() {
  step "7/7 gem5: the standard BARNES stopped at 100 M as well"
  WL=barnes bash "$HOME/launch_b3_gem5.sh" go 2>&1 | sed 's/^/   /'
  [ "${PIPESTATUS[0]}" -eq 0 ] || fail "the gem5 launch failed"
}

pipeline() {
  echo $$ > "$PIDF"
  preflight; build; trace; align; guard_and_mix; launch_champsim; launch_gem5
  rm -f "$PIDF"
  echo; echo "=== pipeline done $(date '+%F %T') -- ChampSim and gem5 continue in the background ==="
}

case "${1:-}" in
  go)
    mkdir -p "$W"
    if alive "$PIDF"; then echo "the pipeline is already running (pid $(cat "$PIDF")) -- 'status'"; exit 0; fi
    setsid bash "$0" __pipeline > "$LOG" 2>&1 < /dev/null &
    disown 2>/dev/null
    echo "started in the background; log: $LOG"
    echo "check: bash $0 status" ;;
  __pipeline) pipeline ;;
  __champsim) champsim_driver ;;
  __job)      shift; champsim_job "$@" ;;
  status)
    if alive "$PIDF"; then echo "(pipeline still working)"; fi
    [ -f "$LOG" ] && sed 's/^/ /' "$LOG" || { echo "not started"; exit 0; }
    echo; echo " ChampSim runs complete: $(champsim_done) of $(jobs_list | wc -l)   driver $(alive "$CS_PIDF" && echo alive || echo 'not running')"
    [ -f "$W/champsim.log" ] && tail -6 "$W/champsim.log" | sed 's/^/    /'
    [ -f "$HOME/launch_b3_gem5.sh" ] && { echo; WL=barnes bash "$HOME/launch_b3_gem5.sh" status 2>&1 | sed 's/^/ /'; } ;;
  *) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
