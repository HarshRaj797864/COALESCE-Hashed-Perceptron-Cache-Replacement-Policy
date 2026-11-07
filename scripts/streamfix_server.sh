#!/usr/bin/env bash
# Step 4's same-stream failures, the diagnosis runs
# (bench/policy_sanity/stream_fix_design_2026-11-02.md). Writes only under
# ~/streamfix. Reads the programs' binaries and inputs; makes no trace and no
# ChampSim run; one gem5 run (cpuid_dump).
#
#   bash ~/streamfix_server.sh go       # detached: build, exact test, facts, CPUID in gem5, QE, the counter runs
#   bash ~/streamfix_server.sh status
#   bash ~/streamfix_server.sh redo     # amendment 2: the round again after a failed cpuid / QE; the
#                                       # last round's logs, CPUID files and QE go to ~/streamfix/rN;
#                                       # runs that ended are kept if the rebuilt counter is the same file
#   bash ~/streamfix_server.sh more lunc   # detached: once the first round has ended and the program is sized
#                                          # (LU non-contiguous, rule c), its runs with both CPUIDs; same log
#
# Sources (uploaded by scripts/streamfix_all.sh to ~/streamfix/src):
# stream_count.cpp + Makefile (the counter, a Pin tool), cpuid_dump.c,
# stream_micro.c, trace_mix.c, cpuid_qe.py.
#
# Steps, in order; a failed step stops everything after it, except where said:
#   build   the counter against the server's Pin; stream_micro (without AVX if
#           the CPU lacks it); cpuid_dump (static); trace_mix
#   exact   the counter on stream_micro at K = 1000 and 2000: thread 1's eight
#           counts differ by exactly K x the hand counts the binary prints;
#           and the tracer step 4 used, on stream_micro 1000: trace_mix of
#           thread 1's trace equals the counter's records, loads, stores, RMWs
#   facts   glibc, the CPU, gem5, md5 of every program binary -> facts.txt
#   cpuid   cpuid_dump natively (host.cpuid) and in gem5 (gem5.cpuid), gem5 as
#           step 4 ran it (MESI_Three_Level, TimingSimpleCPU, 4 CPUs, 2 MB LLC).
#           In gem5 leaf by leaf (amendment 2): gem5 25.1 aborts on a subleaf
#           of leaf 0xd past its two, so a leaf resumes after the subleaf gem5
#           aborts on, and gem5.cpuid lists those pairs ("# gem5 aborts: ...")
#   qe      cpuid_dump under the counter with -cpuid gem5.cpuid prints every line
#           of gem5.cpuid, and nothing else but the pairs gem5 aborts on
#           (cpuid_qe.py; if cpuid or qe fails, the gem5-CPUID runs are skipped
#           and the host runs go on)
#   runs    every program, as traced (binary, arguments, input, files, skip),
#           with the host's CPUID and with gem5's; volrend twice more with
#           gem5's and once more with the host's; PAR at a time
set -uo pipefail
SELF="$(readlink -f "$0")"
R="${R:-$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy}"
S="$R/simulator"
W="${W:-$HOME/streamfix}"
SRC="$W/src"
B="$W/build"
TOOL="$B/obj-intel64/stream_count.so"
PIN_ROOT="${PIN_ROOT:-$S/tracer/pin/pin-external-3.31-98869-gfa6f126a8-gcc-linux}"
TRACER="${TRACER:-$HOME/sync_g5_build/simulator/tracer/pin/obj-intel64/champsim_tracer.so}"   # made step 4's traces (VARIANT=nb)
GEM5_DIR="${GEM5_DIR:-$HOME/gem5}"
G5BUILD="X86"; [ -f "$GEM5_DIR/.gem5_build_dir" ] && G5BUILD="$(cat "$GEM5_DIR/.gem5_build_dir")"
GEM5="$GEM5_DIR/build/$G5BUILD/gem5.opt"
SE="$GEM5_DIR/configs/deprecated/example/se.py"
PAR="${PAR:-8}"
RUN_TIMEOUT="${RUN_TIMEOUT:-8h}"
LOG="$W/driver.log"
PIDF="$W/.driver.pid"
SPLASH_APPS="$S/tracer/splash-3/codes/apps"
NB_EXCLUDE="${NB_EXCLUDE:-radiosity}"   # no traces (rule c)

# The B3 programs, exactly as scripts/sync_server.sh traced them (its PROGS):
# name | binary | arguments | stdin | files | threads traced | skip | cut thread 0
# (B3_PROGS and NB_PROGS_FILE can be set for a rehearsal)
B3_PROGS="${B3_PROGS:-ocean4|$SPLASH_APPS/ocean/contiguous_partitions/OCEAN|-n514 -p4 -e1e-7 -r20000 -t28800|||0 1 2 3|0|0
canneal4|$S/tracer/pin/canneal|4 15000 2000 $S/tracer/pin/100000.nets 128|||1 2 3 4|0|0
canneal8|$S/tracer/pin/canneal|8 15000 2000 $S/tracer/pin/100000.nets 128|||1 2 3 4 5 6 7 8|0|0
barnes256|$SPLASH_APPS/barnes/BARNES||$SPLASH_APPS/barnes/inputs/n16384-p4||0 1 2 3|0|0
barnesstd|$HOME/barnes_std_build/codes/apps/barnes/BARNES||$SPLASH_APPS/barnes/inputs/n16384-p4||0 1 2 3|0|10570006
radix|$HOME/b3_heldout_build/radix/codes/kernels/radix/RADIX.dyn|-p4 -n16777216 -r1024|||0 1 2 3|780000000|0
waternsq|$HOME/b3_heldout_build/waternsq/codes/apps/water-nsquared/WATER-NSQUARED.dyn||$HOME/b3_heldout/inputs/waternsq.in|$HOME/b3_heldout/inputs/random.in|0 1 2 3|0|12952793
fmm|$HOME/b3_heldout_build/fmm/codes/apps/fmm/FMM.dyn||$HOME/b3_heldout/inputs/fmm.in||0 1 2 3|0|12773531}"
NB_PROGS_FILE="${NB_PROGS_FILE:-$HOME/newbench/PROGS}"

all_progs() {   # every PROGS line used here: the B3 set, then step 4's (~/newbench/PROGS) but radiosity
  echo "$B3_PROGS"
  local x
  [ -f "$NB_PROGS_FILE" ] && while IFS= read -r x; do
    [ -n "$x" ] || continue
    case " $NB_EXCLUDE " in *" ${x%%|*} "*) continue ;; esac
    echo "$x"
  done < "$NB_PROGS_FILE"
}
prog_line() { all_progs | awk -F'|' -v n="$1" '$1 == n' | head -1; }

say() { echo "$(date '+%F %T') $*"; }
die() { say "STOPPED: $*"; exit 1; }
alive() { [ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null; }

build() {
  say "== build"
  [ -x "$PIN_ROOT/pin" ] || die "no Pin at $PIN_ROOT"
  for f in stream_count.cpp Makefile cpuid_dump.c stream_micro.c trace_mix.c cpuid_qe.py; do [ -f "$SRC/$f" ] || die "no $SRC/$f -- upload it"; done
  rm -rf "$B"; mkdir -p "$B" "$HOME/.build_tmp"
  cp "$SRC/stream_count.cpp" "$SRC/Makefile" "$B/"
  ( cd "$B" && make PIN_ROOT="$PIN_ROOT" obj-intel64/stream_count.so > build.log 2>&1 ) || die "the counter did not build ($B/build.log)"
  local noavx=""
  grep -qw avx /proc/cpuinfo || noavx="-DNO_AVX"
  gcc -O2 -pthread $noavx -o "$B/stream_micro" "$SRC/stream_micro.c" || die "stream_micro did not build"
  gcc -O2 -static -o "$B/cpuid_dump" "$SRC/cpuid_dump.c" || die "cpuid_dump did not build"
  gcc -O2 -o "$B/trace_mix" "$SRC/trace_mix.c" || die "trace_mix did not build"
  cp "$SRC/cpuid_qe.py" "$B/" || die "no cpuid_qe.py"
  local md5; md5=$(md5sum < "$TOOL" | cut -c1-32)
  say "built: counter md5 $md5; stream_micro ${noavx:-with AVX}"
  # runs that ended stand only if this is the counter that made them
  if [ -f "$W/COUNTER_MD5" ] && [ "$(cat "$W/COUNTER_MD5")" != "$md5" ] && [ -d "$W/runs" ]; then
    mv "$W/runs" "$W/runs_counter_$(cut -c1-8 "$W/COUNTER_MD5")"
    say "build: the counter is not the one that made the runs so far ($(cat "$W/COUNTER_MD5")) -- they are moved aside; every run again"
  elif [ -f "$W/COUNTER_MD5" ]; then
    say "build: the same counter as the runs so far -- the runs that ended stand"
  fi
  echo "$md5" > "$W/COUNTER_MD5"
}

exact() {
  say "== exact: the counter's hand counts, and the tracer against the counter"
  local k d
  for k in 1000 2000; do
    d="$W/exact/k$k"; rm -rf "$d"; mkdir -p "$d"
    ( cd "$d" && TMPDIR="$HOME/.build_tmp" "$PIN_ROOT/pin" -t "$TOOL" -o c -- "$B/stream_micro" "$k" > out.txt 2> err.txt ) || die "stream_micro $k under the counter failed ($d)"
  done
  awk '
    FNR == 1 { f++ }
    f == 1 && /^EXPECT/ { for (i = 2; i < NF; i += 2) want[$i] = $(i + 1); split("rec ld st rmw ginst gld gst rep", name, " ") }
    f == 2 && $1 == "T" { for (i = 1; i <= 8; i++) a[i] = $(i + 1) }
    f == 3 && $1 == "T" { for (i = 1; i <= 8; i++) b[i] = $(i + 1) }
    END { bad = 0; line = ""
          for (i = 1; i <= 8; i++) { d = b[i] - a[i]; line = line " " name[i] " " d / 1000 "/" want[name[i]]; if (d != 1000 * want[name[i]]) bad++ }
          print "   per iteration, counted/by hand:" line; exit bad != 0 }' \
    "$W/exact/k1000/out.txt" "$W/exact/k1000/c.t1.cnt" "$W/exact/k2000/c.t1.cnt" || die "the counter misses a hand count"
  say "exact: 8 of 8 hand counts"
  if [ -f "$TRACER" ]; then
    d="$W/exact/tracer"; rm -rf "$d"; mkdir -p "$d"
    ( cd "$d" && TMPDIR="$HOME/.build_tmp" "$PIN_ROOT/pin" -t "$TRACER" -o raw -max_instr 0 -- "$B/stream_micro" 1000 > out.txt 2> err.txt ) || die "the tracer on stream_micro failed ($d)"
    local t c
    t=$("$B/trace_mix" < "$d/raw1.champsimtrace" | awk '$1 == "T" { print $2, $3, $4, $5 }')
    c=$(awk '$1 == "T" { print $2, $3, $4, $5 }' "$W/exact/k1000/c.t1.cnt")
    rm -f "$d"/raw*.champsimtrace
    echo "   thread 1, records loads stores RMWs: tracer + trace_mix $t; counter $c"
    [ "$t" = "$c" ] || die "the counter does not count what the tracer writes"
    say "exact: the counter equals the tracer on thread 1 ($TRACER, md5 $(md5sum < "$TRACER" | cut -c1-32))"
  else
    say "exact: no tracer at $TRACER -- the tracer comparison is skipped (it held on the laptop)"
  fi
}

facts() {
  say "== facts -> $W/facts.txt"
  {
    echo "date: $(date '+%F %T')"
    echo "kernel: $(uname -r)"
    echo "glibc: $(ldd --version 2>&1 | head -1)"
    echo "cpu: $(grep -m1 '^model name' /proc/cpuinfo | cut -d: -f2-)"
    local f
    for f in sse4_2 ssse3 avx avx2 avx512f fma bmi2 erms fsrm; do grep -qw "$f" /proc/cpuinfo && echo "has $f" || echo "lacks $f"; done
    echo "flags:$(grep -m1 '^flags' /proc/cpuinfo | cut -d: -f2)"
    echo "== ld.so --list-tunables (glibc >= 2.33)"
    /lib64/ld-linux-x86-64.so.2 --list-tunables 2>&1 | head -60
    echo "== ld.so --list-diagnostics (glibc >= 2.33), x86 lines"
    /lib64/ld-linux-x86-64.so.2 --list-diagnostics 2>&1 | grep -E 'x86|cpu_features' | head -80
    echo "== gem5: $GEM5"
    [ -x "$GEM5" ] && echo "md5 $(md5sum < "$GEM5" | cut -c1-32), protocol $(cat "$GEM5_DIR/.gem5_protocol" 2>/dev/null)"
    echo "== program binaries"
    local name bin rest
    while IFS='|' read -r name bin rest; do
      [ -n "$name" ] || continue
      if [ -f "$bin" ]; then echo "$name $(md5sum < "$bin" | cut -c1-32) $(file -b "$bin" | cut -c1-60) $bin"; else echo "$name MISSING $bin"; fi
    done <<< "$(all_progs)"
  } > "$W/facts.txt" 2>&1
  grep -E '^(glibc|cpu|has|lacks)' "$W/facts.txt" | tr '\n' ';' | sed 's/;/; /g; s/^/   /'; echo
  if grep -q ' MISSING ' "$W/facts.txt"; then grep ' MISSING ' "$W/facts.txt" | sed 's/^/   /'; fi
}

# gem5 on cpuid_dump, as step 4 ran gem5. $1 the directory, $2 the dumper's
# arguments (none: the whole dump). No core file (gem5 aborts on purpose here).
g5dump() {
  mkdir -p "$1"
  # shellcheck disable=SC2086
  ( cd "$1" && ulimit -c 0 && timeout "${G5_DUMP_TIMEOUT:-30m}" nice -n 10 "$GEM5" --outdir="$1" "$SE" --ruby --num-cpus=4 --cpu-type=TimingSimpleCPU --mem-size=4GB \
      --l0i_size=32kB --l0i_assoc=8 --l0d_size=32kB --l0d_assoc=8 --l1d_size=512kB --l1d_assoc=8 \
      --l2_size=2MB --l2_assoc=16 --num-l2caches=1 --num-clusters=1 \
      -c "$B/cpuid_dump" ${2:+-o "$2"} < /dev/null > run.log 2>&1 )
}

# One leaf (hex) in gem5, subleaves 0-15. A run that stops before subleaf 15
# must end in gem5's assertion; that subleaf is listed as one gem5 aborts on and
# the leaf resumes after it. Writes $2/leaf_L/{lines,aborts} and DONE or FAILED.
leaf_dump() {
  local L="$1" dir="$2/leaf_$1" first=0 last n rd
  rm -rf "$dir"; mkdir -p "$dir"; : > "$dir/lines"; : > "$dir/aborts"
  while [ "$first" -le 15 ]; do
    rd="$dir/from_$first"
    g5dump "$rd" "$L $(printf %x "$first")"
    n=$(grep -c "^CPUID $L " "$rd/run.log")
    if [ "$n" -gt 0 ]; then last=$(( 16#$(grep "^CPUID $L " "$rd/run.log" | tail -1 | cut -d' ' -f3) )); else last=$((first - 1)); fi
    if [ "$n" -gt 0 ] && [ "$(grep -m1 "^CPUID $L " "$rd/run.log" | cut -d' ' -f3)" != "$(printf %x "$first")" ] || [ "$n" -ne $((last - first + 1)) ]; then
      echo "subleaves out of order from $first ($rd/run.log)" > "$dir/FAILED"; return 1
    fi
    grep "^CPUID $L " "$rd/run.log" >> "$dir/lines"
    [ "$last" -ge 15 ] && break
    if ! grep -qE 'Assertion .* failed|Program aborted' "$rd/run.log"; then
      echo "gem5 stopped at subleaf $((last + 1)) without its assertion ($rd/run.log)" > "$dir/FAILED"; return 1
    fi
    echo "# gem5 aborts: leaf $L subleaf $(printf %x $((last + 1))) ($(grep -m1 -oE 'Assertion .* failed' "$rd/run.log" | cut -c1-120))" >> "$dir/aborts"
    first=$((last + 2))
  done
  echo ok > "$dir/DONE"
}

cpuid() {
  say "== cpuid: host and gem5"
  "$B/cpuid_dump" > "$W/host.cpuid" || die "cpuid_dump failed natively"
  local d="$W/gem5_cpuid" head maxb maxe L i n miss running=0 leaves=()
  rm -rf "$d" "$W/gem5.cpuid"; mkdir -p "$d"
  [ -x "$GEM5" ] || { say "cpuid: no gem5 at $GEM5 -- the gem5-CPUID runs are skipped"; return 1; }
  g5dump "$d/all" ""
  head=$(grep -m1 '^# cpuid_dump' "$d/all/run.log")
  maxb=$(sed -n 's/.*basic leaves 0-\([0-9a-f]*\),.*/\1/p' <<< "$head")
  maxe=$(sed -n 's/.*extended 80000000-\([0-9a-f]*\).*/\1/p' <<< "$head")
  if [ -z "$maxb" ] || [ -z "$maxe" ]; then say "cpuid: gem5 printed no header ($d/all/run.log) -- the gem5-CPUID runs are skipped"; return 1; fi
  for ((i = 0; i <= 16#$maxb; i++)); do leaves+=("$(printf %x "$i")"); done
  for ((i = 16#80000000; i <= 16#$maxe; i++)); do leaves+=("$(printf %x "$i")"); done
  say "cpuid: gem5 leaf by leaf, ${#leaves[@]} leaves ($PAR at a time)"
  for L in "${leaves[@]}"; do
    leaf_dump "$L" "$d" &
    running=$((running + 1))
    if [ "$running" -ge "$PAR" ]; then wait -n; running=$((running - 1)); fi
  done
  wait
  for L in "${leaves[@]}"; do
    [ -f "$d/leaf_$L/DONE" ] || { say "cpuid: leaf $L: $(cat "$d/leaf_$L/FAILED" 2>/dev/null) -- the gem5-CPUID runs are skipped"; return 1; }
  done
  { echo "$head"; for L in "${leaves[@]}"; do cat "$d/leaf_$L/lines"; done; for L in "${leaves[@]}"; do cat "$d/leaf_$L/aborts"; done; } > "$d/assembled"
  # gem5 answers the same in the whole dump (as far as it went) and leaf by leaf
  miss=$(grep '^CPUID ' "$d/all/run.log" | grep -cvxF -f <(grep '^CPUID ' "$d/assembled"))
  [ "$miss" = 0 ] || { say "cpuid: $miss lines of the whole dump differ from the leaf-by-leaf dump -- the gem5-CPUID runs are skipped"; return 1; }
  n=$(grep -c '^CPUID ' "$d/assembled")
  if [ "$n" -lt 32 ] || ! grep -q '^CPUID 0 0 ' "$d/assembled"; then
    say "cpuid: gem5 printed $n CPUID lines ($d) -- the gem5-CPUID runs are skipped"; return 1
  fi
  mv "$d/assembled" "$W/gem5.cpuid"
  echo "   host: $(head -1 "$W/host.cpuid")"
  echo "   gem5: $(head -1 "$W/gem5.cpuid") ($n lines; $(grep -c '^# gem5 aborts' "$W/gem5.cpuid") pairs gem5 aborts on: $(grep '^# gem5 aborts' "$W/gem5.cpuid" | awk '{ printf "%s/%s ", $5, $7 }'))"
  echo "   whole dump in gem5: $(grep -c '^CPUID ' "$d/all/run.log") lines, all equal to the leaf-by-leaf ones"
  echo "   leaf 1 and 7, host: $(grep -E '^CPUID (1|7) 0 ' "$W/host.cpuid" | cut -d' ' -f2- | tr '\n' ';')"
  echo "   leaf 1 and 7, gem5: $(grep -E '^CPUID (1|7) 0 ' "$W/gem5.cpuid" | cut -d' ' -f2- | tr '\n' ';')"
  echo "   extended 80000000-8, gem5: $(grep -E '^CPUID 8000000[0-8] 0 ' "$W/gem5.cpuid" | cut -d' ' -f2,4- | tr '\n' ';')"
}

qe() {
  say "== QE: cpuid_dump under the counter with gem5's CPUID"
  [ -f "$W/gem5.cpuid" ] || { say "QE: no gem5.cpuid -- skipped"; return 1; }
  local d="$W/qe"; rm -rf "$d"; mkdir -p "$d"
  ( cd "$d" && "$PIN_ROOT/pin" -t "$TOOL" -o c -cpuid "$W/gem5.cpuid" -- "$B/cpuid_dump" > dump.txt 2> err.txt ) || { say "QE: FAILED (the run, $d)"; rm -f "$W/gem5.cpuid"; return 1; }
  if python3 "$B/cpuid_qe.py" "$W/gem5.cpuid" "$d/dump.txt" > "$d/diff.txt" 2>&1; then
    say "QE holds: the dump under emulation $(head -1 "$d/diff.txt" | sed 's/^holds: //'); $(grep '^CPUID replaced' "$d/c.summary")"
  else
    say "QE FAILED: $(head -1 "$d/diff.txt") ($d/diff.txt) -- the gem5-CPUID runs are skipped"; mv -f "$W/gem5.cpuid" "$d/gem5.cpuid.failed"; return 1
  fi
}

job() {   # name mode k
  local name="$1" mode="$2" k="$3" line bin args sin files tids skip cut0 rest d cut t0 rc
  line=$(prog_line "$name")
  [ -n "$line" ] || { say "$name: no PROGS line"; return 1; }
  IFS='|' read -r _ bin args sin files tids skip cut0 rest <<< "$line"
  d="$W/runs/${name}__${mode}__$k"
  if [ -f "$d/STATUS" ] && grep -q '^exit 0 ' "$d/STATUS"; then say "$name $mode $k: done already"; return 0; fi
  rm -rf "$d"; mkdir -p "$d"
  echo "$line" > "$d/PROGS"
  local f
  for f in $files; do cp "$f" "$d/" || { echo "exit nofile $f" > "$d/STATUS"; say "$name $mode $k: FAILED -- no $f"; return 1; }; done
  [ "${cut0:-0}" = 0 ] && cut=0 || cut=1
  local cpu=()
  [ "$mode" = gem5 ] && cpu=(-cpuid "$W/gem5.cpuid")
  say "$name $mode $k: started"
  t0=$(date +%s)
  # shellcheck disable=SC2086 -- $args is the program's argument list
  ( cd "$d" && TMPDIR="$HOME/.build_tmp" timeout "$RUN_TIMEOUT" nice -n 10 "$PIN_ROOT/pin" -t "$TOOL" -o c -skip "${skip:-0}" -cut0 "$cut" ${cpu[@]+"${cpu[@]}"} \
      -- "$bin" $args < "${sin:-/dev/null}" > out.txt 2> err.txt )
  rc=$?
  echo "exit $rc seconds $(( $(date +%s) - t0 ))" > "$d/STATUS"
  say "$name $mode $k: exit $rc after $(( ($(date +%s) - t0) / 60 )) min"
}

job_list() {   # the longest first
  local names n
  names=$(all_progs | cut -d'|' -f1)
  for n in canneal8 canneal4 volrend fft radix $names; do echo "$n"; done | awk '!seen[$0]++' | while read -r n; do
    echo "$names" | grep -qx "$n" || continue
    echo "$n host 1"
    [ -f "$W/gem5.cpuid" ] && echo "$n gem5 1"
    if [ "$n" = volrend ]; then
      echo "$n host 2"
      [ -f "$W/gem5.cpuid" ] && { echo "$n gem5 2"; echo "$n gem5 3"; }
    fi
  done
}

runs() {
  say "== runs: $(job_list | wc -l) counter runs, $PAR at a time"
  local running=0 name mode k
  while read -r name mode k; do
    job "$name" "$mode" "$k" &
    running=$((running + 1))
    if [ "$running" -ge "$PAR" ]; then wait -n; running=$((running - 1)); fi
  done < <(job_list)
  wait
  local ok bad
  ok=$(grep -l '^exit 0 ' "$W"/runs/*/STATUS 2>/dev/null | wc -l)
  bad=$(grep -L '^exit 0 ' "$W"/runs/*/STATUS 2>/dev/null | wc -l)
  say "runs: $ok exited 0, $bad did not"
}

drive() {
  echo $$ > "$PIDF"
  build && exact && facts || { rm -f "$PIDF"; exit 1; }
  cpuid && qe
  runs
  say "DONE"
  date '+%F %T' > "$W/DONE"
  rm -f "$PIDF"
}

# A program sized after the first round (LU non-contiguous, rule c): its runs
# with the host's CPUID and gem5's, as every other program's. Waits for the
# first round to end (the build, QE and gem5.cpuid are then final) and for
# each program's PROGS line, up to MORE_WAIT_H hours.
more() {
  local waited=0 p running=0 name mode k
  say "== more: $* -- waits for the first round to end and for each program to be sized (up to ${MORE_WAIT_H:-24} h)"
  echo $$ > "$PIDF.more"
  while alive "$PIDF"; do sleep "${MORE_POLL:-300}"; done
  [ -f "$W/DONE" ] || { rm -f "$PIDF.more"; die "more: the first round did not end with DONE"; }
  [ -f "$TOOL" ] || { rm -f "$PIDF.more"; die "more: no counter at $TOOL"; }
  for p in "$@"; do
    while [ -z "$(prog_line "$p")" ]; do
      [ "$waited" -lt $(( ${MORE_WAIT_H:-24} * 3600 / ${MORE_POLL:-300} )) ] || { rm -f "$PIDF.more"; die "more: $p is not sized after ${MORE_WAIT_H:-24} h"; }
      sleep "${MORE_POLL:-300}"; waited=$((waited + 1))
    done
  done
  say "more: $(for p in "$@"; do echo "$p host 1"; [ -f "$W/gem5.cpuid" ] && echo "$p gem5 1"; done | wc -l) counter runs"
  while read -r name mode k; do
    job "$name" "$mode" "$k" &
    running=$((running + 1))
    if [ "$running" -ge "$PAR" ]; then wait -n; running=$((running - 1)); fi
  done < <(for p in "$@"; do echo "$p host 1"; [ -f "$W/gem5.cpuid" ] && echo "$p gem5 1"; done)
  wait
  say "more: DONE ($*)"
  rm -f "$PIDF.more"
}

status() {
  echo "== streamfix: $(alive "$PIDF" && echo running || echo 'not running')$([ -f "$W/DONE" ] && echo ", DONE $(cat "$W/DONE")")$(alive "$PIDF.more" && echo "; 'more' waiting or running")"
  [ -f "$LOG" ] && grep -E '==|STOPPED|FAILED|holds|exact:|built:|build:|cpuid:|QE|runs:|DONE|gem5:|host:|leaf|extended|more:|redo:' "$LOG" | tail -28 | sed 's/^/   /'
  local n=0 ok=0 d
  for d in "$W"/runs/*/; do
    [ -d "$d" ] || continue
    n=$((n + 1))
    grep -q '^exit 0 ' "$d/STATUS" 2>/dev/null && ok=$((ok + 1))
  done
  echo "   counter runs: $ok of $n complete; running now: $(pgrep -u "$(id -u)" -f "stream_count.so -o c" | wc -l)"
  [ -d "$W/runs" ] && grep -L '^exit 0 ' "$W"/runs/*/STATUS 2>/dev/null | sed "s|$W/runs/||; s|/STATUS||; s/^/   not complete: /"
}

case "${1:-}" in
  go)
    mkdir -p "$W"
    alive "$PIDF" && { echo "already running (pid $(cat "$PIDF"))"; exit 1; }
    rm -f "$W/DONE"
    setsid nohup bash "$SELF" drive > "$LOG" 2>&1 < /dev/null &
    sleep 2
    echo "started (log $LOG); in about 2-4 hours: bash $SELF status" ;;
  drive) drive ;;
  redo)
    # amendment 2 (2026-11-04): the first round's gem5 CPUID dump stopped where
    # gem5 aborts (leaf 0xd, subleaf 2), so QE failed and no gem5-CPUID run was
    # made. The round again: the last round's log, CPUID files and QE go to
    # $W/rN; runs that ended stay if the rebuilt counter is the same file.
    alive "$PIDF" && { echo "the driver is running -- nothing changed"; exit 1; }
    alive "$PIDF.more" && { echo "'more' is waiting or running -- nothing changed"; exit 1; }
    [ -f "$W/DONE" ] || { echo "no finished round in $W -- nothing changed"; exit 1; }
    m=$(sed -n 's/.*built: counter md5 \([0-9a-f]\{32\}\).*/\1/p' "$LOG" | tail -1)
    [ -n "$m" ] || { echo "no counter md5 in $LOG -- nothing changed"; exit 1; }
    [ -f "$W/COUNTER_MD5" ] || echo "$m" > "$W/COUNTER_MD5"
    n=1; while [ -e "$W/r$n" ]; do n=$((n + 1)); done
    mkdir "$W/r$n" || exit 1
    for x in driver.log DONE qe gem5_cpuid host.cpuid gem5.cpuid facts.txt exact; do [ -e "$W/$x" ] && mv "$W/$x" "$W/r$n/"; done
    echo "redo: the last round's log, CPUID files, QE and exact test are in $W/r$n; runs kept: $(grep -l '^exit 0 ' "$W"/runs/*/STATUS 2>/dev/null | wc -l) (if the counter is the same)"
    exec bash "$SELF" go ;;
  more)
    shift; [ $# -ge 1 ] || { echo "usage: $0 more <program> ..."; exit 1; }
    alive "$PIDF.more" && { echo "'more' is already waiting or running (pid $(cat "$PIDF.more"))"; exit 1; }
    mkdir -p "$W"
    setsid nohup bash "$SELF" __more "$@" >> "$LOG" 2>&1 < /dev/null &
    sleep 2
    alive "$PIDF.more" || { echo "'more' did not start ($LOG)"; exit 1; }
    echo "started: waits for the first round to end and for $* to be sized, then the counter runs (log $LOG)" ;;
  __more) shift; more "$@" ;;
  status) status ;;
  *) echo "usage: $0 go|redo|more <program>...|status"; exit 1 ;;
esac
