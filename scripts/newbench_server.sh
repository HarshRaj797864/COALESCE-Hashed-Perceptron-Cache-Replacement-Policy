#!/usr/bin/env bash
# Step 4 on the server, part 1: build and size the new benchmarks
# (bench/policy_sanity/newbench_design_2026-10-19.md). Writes only under
# ~/newbench, ~/newbench_build and ~/splash-newbench; touches no trace, run,
# queue or binary of the main tree.
#
#   bash ~/newbench_server.sh size [progs]   # detached; default: the six; a program already sized is skipped
#   bash ~/newbench_server.sh status
#   bash ~/newbench_server.sh tracelen <program> <instructions> ...   # amendment 2: trace length per program
#   bash ~/newbench_server.sh sizegem5 <progs>   # rule (c): size, then start each sized one's gem5 runs
#                                                # (launch_b3_gem5.sh); detached; tracing is separate
#
# Per program:
#   1. build   from a COPY of the source, fortify off: a dynamic binary (Pin)
#              and the same objects linked -static (gem5). QB: every function
#              of the program's objects has the same instruction count and
#              constants in both (as for the held-out programs, b3_heldout.sh).
#              streamcluster: PARSEC's spin-barrier drop-in disabled in the
#              copy (POSIX barriers, which the tracer records).
#   2. inputs  the files each rung of the ladder needs, under ~/newbench/<p>/inputs
#   3. size    Pin's per-thread counter (inscount_tls) on each rung, smallest
#              first; the first whose traced threads each execute >= 300 M
#              instructions is chosen. SPLASH-3: threads 0-3 (thread 0
#              creates three workers and works). streamcluster: the first four
#              created threads (the main pass).
#   4. record  ~/newbench/<p>/CHOSEN, and the program's line for the
#              synchronised-replay chain (sync_server.sh VARIANT=nb) in
#              ~/newbench/PROGS and ~/newbench/JOBS
set -uo pipefail
SELF="$(readlink -f "$0")"
R="${R:-$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy}"
S="$R/simulator"
SPLASH="${SPLASH:-$S/tracer/splash-3/codes}"
PARSEC_SC="${PARSEC_SC:-$S/tracer/pin/parsec-full/pkgs/kernels/streamcluster/src}"
PIN_ROOT="${PIN_ROOT:-$S/tracer/pin/pin-external-3.31-98869-gfa6f126a8-gcc-linux}"
COUNTER="$PIN_ROOT/source/tools/ManualExamples/obj-intel64/inscount_tls.so"
W="${W:-$HOME/newbench}"
BUILD="${BUILD:-$HOME/newbench_build}"
STATIC_DIR="${STATIC_DIR:-$HOME/splash-newbench}"
MIN_INSTR="${MIN_INSTR:-300000000}"
RUN_TIMEOUT="${RUN_TIMEOUT:-4h}"
# the six after the 2026-10-20 amendment (newbench_design): cholesky (below the
# size rule) and waterspatial (hangs) replaced by volrend and radiosity; lunc
# (LU non-contiguous) is next if either of those fails the rule
PROGS_DEFAULT="fft lu raytrace streamcluster volrend radiosity"
LOG="$W/size.log"
PIDF="$W/.size.pid"
trap 'rc=$?; [ "$rc" = 0 ] || echo "newbench_server.sh ${1:-}: stopped, exit code $rc ($(date "+%F %T"))" >&2' EXIT

alive() { [ -f "$1" ] && kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null; }
step() { echo; echo "=== $(date '+%F %T')  $P: $* ==="; }
fail() { echo "STOPPED ($P): $*"; return 1; }

# program -> source dir (SPLASH-3, under codes/) | binary name | kind
info() {
  case "$1" in
    fft)           echo "kernels/fft|FFT|splash" ;;
    lu)            echo "kernels/lu/contiguous_blocks|LU|splash" ;;
    cholesky)      echo "kernels/cholesky|CHOLESKY|splash" ;;
    waterspatial)  echo "apps/water-spatial|WATER-SPATIAL|splash" ;;
    raytrace)      echo "apps/raytrace|RAYTRACE|splash" ;;
    streamcluster) echo "-|streamcluster|parsec" ;;
    volrend)       echo "apps/volrend|VOLREND|splash" ;;
    radiosity)     echo "apps/radiosity|RADIOSITY|splash" ;;
    lunc)          echo "kernels/lu/non_contiguous_blocks|LU|splash" ;;
    *) return 1 ;;
  esac
}
# program -> its ladder, smallest first: "arguments|stdin file (in inputs/)|files the run needs in its directory"
ladder() {
  case "$1" in
    fft)           printf '%s\n' "-m22 -p4||" "-m24 -p4||" "-m26 -p4||" ;;
    lu)            printf '%s\n' "-n1024 -p4 -b16||" "-n2048 -p4 -b16||" ;;
    cholesky)      printf '%s\n' "-p4|tk25.O|" "-p4|tk29.O|" ;;
    waterspatial)  printf '%s\n' "|ws32.in|random.in" "|ws64.in|random.in" "|ws128.in|random.in" ;;
    raytrace)      printf '%s\n' "-p4 -m64 car.env||car.env car.geo" "-p4 -m128 balls4.env||balls4.env balls4.geo" ;;
    streamcluster) printf '%s\n' "10 20 128 16384 16384 1000 none out.txt 4||" "10 20 128 65536 65536 1000 none out.txt 4||" "10 20 128 262144 262144 1000 none out.txt 4||" ;;
    volrend)       printf '%s\n' "4 head 4||head.den" "4 head 16||head.den" "4 head 64||head.den" ;;
    radiosity)     printf '%s\n' "-p 4 -batch -room||" "-p 4 -batch -largeroom||" ;;
    lunc)          printf '%s\n' "-n1024 -p4 -b16||" "-n2048 -p4 -b16||" ;;
  esac
}
traced_tids() { [ "$KIND" = parsec ] && echo "1 2 3 4" || echo "0 1 2 3"; }
# the name the static binary is installed under for gem5: LU non-contiguous
# would otherwise overwrite lu's LU
static_name() { [ "$P" = lunc ] && echo LU-NC || echo "$NAME"; }

setp() {
  P="$1"
  IFS='|' read -r DIR NAME KIND <<< "$(info "$P")" || return 1
  [ -n "$NAME" ] || return 1
  PW="$W/$P"
  if [ "$KIND" = splash ]; then PB="$BUILD/$P/codes/$DIR"; else PB="$BUILD/$P/src"; fi
  DYN="$PB/$NAME.dyn"; STA="$PB/$NAME.static"
}

# --- QB, as in b3_heldout.sh: instruction counts without alignment padding, and constants
disasm() {
  objdump -d --no-show-raw-insn "$1" 2>/dev/null | awk '
    /^[0-9a-f]+ <.*>:$/ { fn = $2; sub(/^</, "", fn); sub(/>:$/, "", fn); next }
    /^ +[0-9a-f]+:/ { sub(/^ +[0-9a-f]+:[ \t]+/, ""); sub(/[ \t]+#.*$/, ""); print fn "\t" $0 }'
}
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
qb() {   # object files in $PB
  local objs="$1" fns f a b n bad=0 same=0
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
}

build() {
  step "1/4 build, dynamic and static, from one set of objects"
  local base_cf cf objs fcc libs
  rm -rf "${BUILD:?}/$P"; mkdir -p "$PW"
  if [ "$KIND" = splash ]; then
    mkdir -p "$BUILD/$P/codes/$(dirname "$DIR")" || { fail "cannot create $BUILD/$P"; return 1; }
    cp -p "$SPLASH/Makefile.config" "$BUILD/$P/codes/" && cp -rp "$SPLASH/pthread_macros" "$BUILD/$P/codes/" \
      && cp -rp "$SPLASH/$DIR" "$BUILD/$P/codes/$DIR" || { fail "could not copy the source"; return 1; }
    cd "$PB" || { fail "no $PB"; return 1; }
    make clean > /dev/null 2>&1
    base_cf=$(grep -E '^\s*CFLAGS\s*[:+]?=' "$BUILD/$P/codes/Makefile.config" | head -1 | sed 's/^[^=]*=//')
    cf="$base_cf -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0"
    # Fortify off through CC, not CFLAGS (2026-10-21): a CFLAGS on make's
    # command line replaces each Makefile's own additions -- volrend's
    # -I./libtiff and radiosity's -I./glibdumb -I./glibps were lost and make
    # failed -- and libtiff's own Makefile sets its own CFLAGS. CC reaches
    # every compile, the bundled libraries' included. For a program whose
    # Makefile adds nothing (fft, lu, raytrace) the compile is the same.
    fcc="gcc -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0"
    echo "   make CC=\"$fcc\" (the tree's CFLAGS and each Makefile's own additions)"
    make CC="$fcc" > "$PB/build.log" 2>&1 || { tail -5 "$PB/build.log" | sed 's/^/      /'; fail "make failed"; return 1; }
    echo "   compile: $(grep -m1 -E -- ' -c .*[[:space:]][^[:space:]]+\.c$' "$PB/build.log")"
    [ -x "$NAME" ] || { fail "the build produced no $NAME"; return 1; }
    mv -f "$NAME" "$DYN"
    objs=$(ls ./*.o)
    # the libraries the Makefile builds in subdirectories (volrend: libtiff;
    # radiosity: glibdumb, glibps), in the static link as in the dynamic one
    libs=$(find . -mindepth 2 -name '*.a' | LC_ALL=C sort | tr '\n' ' ')
    [ -z "$libs" ] || echo "   the program's own libraries: $libs"
    # shellcheck disable=SC2086 -- lists of object files and archives
    gcc $cf -o "$STA" $objs ${libs:+-Wl,--start-group $libs -Wl,--end-group} -lm -static >> "$PB/build.log" 2>&1 || { tail -5 "$PB/build.log" | sed 's/^/      /'; fail "the static link failed"; return 1; }
  else
    mkdir -p "$PB" && cp -p "$PARSEC_SC"/*.cpp "$PARSEC_SC"/*.hpp "$PB/" || { fail "could not copy streamcluster's source from $PARSEC_SC"; return 1; }
    cd "$PB" || { fail "no $PB"; return 1; }
    # POSIX barriers: PARSEC's header redefines pthread_barrier_* to its spin
    # barrier unconditionally, which the tracer cannot see (newbench_design).
    sed -i 's|^#define ENABLE_AUTOMATIC_DROPIN|// #define ENABLE_AUTOMATIC_DROPIN  (disabled for COALESCE: POSIX barriers, which the tracer records)|' parsec_barrier.hpp
    grep -q '^#define ENABLE_AUTOMATIC_DROPIN' parsec_barrier.hpp && { fail "could not disable the spin-barrier drop-in"; return 1; }
    cf="-O2 -g -pthread -DENABLE_THREADS -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0"
    echo "   CXXFLAGS=\"$cf\" (PARSEC's spin-barrier drop-in disabled)"
    # shellcheck disable=SC2086
    g++ $cf -c streamcluster.cpp -o streamcluster.o > "$PB/build.log" 2>&1 || { tail -5 "$PB/build.log" | sed 's/^/      /'; fail "the compile failed"; return 1; }
    objs="streamcluster.o"
    # shellcheck disable=SC2086
    g++ $cf -o "$DYN" $objs >> "$PB/build.log" 2>&1 && g++ $cf -o "$STA" $objs -static >> "$PB/build.log" 2>&1 \
      || { tail -5 "$PB/build.log" | sed 's/^/      /'; fail "the link failed"; return 1; }
    nm "$DYN" | grep -q ' U pthread_barrier_wait\| U pthread_barrier_wait@' || { fail "the dynamic binary does not call pthread_barrier_wait: the drop-in is still in"; return 1; }
  fi
  cd "$HOME" || true
  file -b "$DYN" | grep -q 'dynamically linked' || { fail "$NAME.dyn is not dynamically linked"; return 1; }
  file -b "$STA" | grep -q 'statically linked' || { fail "$NAME.static is not statically linked"; return 1; }
  qb "$objs" || return 1
  echo "   dynamic md5 $(md5sum < "$DYN" | cut -c1-12), static md5 $(md5sum < "$STA" | cut -c1-12)"
  mkdir -p "$STATIC_DIR"
  local sn; sn=$(static_name)
  if [ -f "$STATIC_DIR/$sn" ] && ! cmp -s "$STATIC_DIR/$sn" "$STA"; then
    mv -f "$STATIC_DIR/$sn" "$STATIC_DIR/$sn.prev_$(date +%Y%m%d_%H%M%S)"
  fi
  cp -p "$STA" "$STATIC_DIR/$sn" || { fail "could not install the static binary"; return 1; }
  echo "   gem5 binary: $STATIC_DIR/$sn"
}

inputs() {
  step "2/4 inputs"
  local I="$PW/inputs" k
  rm -rf "$I"; mkdir -p "$I"
  case "$P" in
    cholesky)
      for k in tk25.O tk29.O; do cp -p "$SPLASH/$DIR/inputs/$k" "$I/" || { fail "no inputs/$k"; return 1; }; done ;;
    waterspatial)
      # n512-p4 with 32, 64, 128 steps: field 3 of line 1, as water-nsquared's 8 were set
      for k in 32 64 128; do awk -v s="$k" 'NR == 1 { $3 = s } { print }' "$SPLASH/$DIR/inputs/n512-p4" > "$I/ws$k.in" || { fail "no inputs/n512-p4"; return 1; }; done
      echo "   line 1 of n512-p4: $(head -1 "$SPLASH/$DIR/inputs/n512-p4"); ws64.in: $(head -1 "$I/ws64.in")"
      if [ -f "$SPLASH/$DIR/random.in" ]; then cp -p "$SPLASH/$DIR/random.in" "$I/"; else : > "$I/random.in.absent"; echo "   (no random.in in the source directory)"; fi ;;
    raytrace)
      cp -p "$SPLASH/$DIR"/inputs/*.env "$SPLASH/$DIR"/inputs/*.geo "$I/" || { fail "no raytrace inputs"; return 1; } ;;
    volrend)
      cp -p "$SPLASH/$DIR"/inputs/head.den "$I/" || { fail "no volrend input head.den"; return 1; } ;;
  esac
  ls "$I" | tr '\n' ' ' | sed 's/^/   /'; echo
}

size() {
  step "3/4 size: Pin's per-thread counter up the ladder, $MIN_INSTR instructions a traced thread"
  local k=0 rung args sin files d f low tid n chosen=""
  [ -f "$COUNTER" ] || { ( cd "$PIN_ROOT/source/tools/ManualExamples" && make obj-intel64/inscount_tls.so PIN_ROOT="$PIN_ROOT" ) > "$W/counter_build.log" 2>&1 || { fail "could not build inscount_tls ($W/counter_build.log)"; return 1; }; }
  # the program's own usage text, for the record (2026-10-20: volrend's
  # arguments were set from memory, not read from the server)
  ( cd "$PW" && timeout 10 "$DYN" < /dev/null > "$PW/usage.txt" 2>&1 )
  grep -i -m3 -E 'usage|argument' "$PW/usage.txt" | cut -c1-140 | sed 's/^/   usage: /'
  while IFS= read -r rung; do
    k=$((k + 1))
    IFS='|' read -r args sin files <<< "$rung"
    d="$PW/run$k"; rm -rf "$d"; mkdir -p "$d"
    for f in $files; do
      if [ -f "$PW/inputs/$f" ]; then cp -p "$PW/inputs/$f" "$d/"; elif [ ! -f "$PW/inputs/$f.absent" ]; then fail "no input file $f"; return 1; fi
    done
    echo "   rung $k: $NAME $args${sin:+ < $sin}"
    local in=/dev/null; [ -z "$sin" ] || in="$PW/inputs/$sin"
    [ -f "$in" ] || [ "$in" = /dev/null ] || { fail "no stdin file $in"; return 1; }
    # shellcheck disable=SC2086 -- $args is the argument list
    ( cd "$d" && TMPDIR="$HOME/.build_tmp" timeout "$RUN_TIMEOUT" nice -n 10 "$PIN_ROOT/pin" -t "$COUNTER" -o "$d/count.txt" -- "$DYN" $args \
        < "$in" > "$d/out.txt" 2> "$d/err.txt" )
    n=$?
    [ "$n" = 0 ] || { echo "      exited $n ($(tail -1 "$d/err.txt" 2>/dev/null | cut -c1-100))"; continue; }
    low=""
    for tid in $(traced_tids); do
      n=$(awk -v t="Count[$tid]" '$1 == t { print $3 }' "$d/count.txt")
      [ -n "$n" ] || { low="$low $tid:absent"; continue; }
      [ "$n" -ge "$MIN_INSTR" ] || low="$low $tid:$n"
    done
    echo "      $(grep -c '^Count\[' "$d/count.txt") threads: $(awk '/^Count\[/ { printf "%s %.0fM  ", $1, $3 / 1e6 }' "$d/count.txt")"
    if [ -z "$low" ]; then chosen="$rung"; echo "      CHOSEN: every traced thread ($(traced_tids)) executes >= $((MIN_INSTR / 1000000)) M"; break; fi
    echo "      below the rule:$low"
  done < <(ladder "$P")
  [ -n "$chosen" ] || { fail "no rung of the ladder meets the size rule -- the design's replacement order applies (an amendment, before anything else runs)"; return 1; }
  echo "$chosen" > "$PW/CHOSEN"
}

record() {
  step "4/4 record"
  local args sin files fl="" f cut
  IFS='|' read -r args sin files < "$PW/CHOSEN"
  for f in $files; do [ -f "$PW/inputs/$f" ] && fl="$fl $PW/inputs/$f"; done
  [ "$KIND" = parsec ] && cut=0 || cut=auto
  # sync_server.sh PROGS: name | binary | arguments | stdin | files | threads traced | skip | cut thread 0
  echo "$P|$DYN|$args|${sin:+$PW/inputs/$sin}|${fl# }|$(traced_tids)|0|$cut" > "$PW/PROGS"
  # JOBS_SPEC: suffix | workload | cores | scaled | warm-up | measured | traces
  echo "${P}4|$P|4|0|50000000|100000000|$P" > "$PW/JOBS"
  cat "$PW/PROGS" | sed 's/^/   PROGS: /'
  cat "$W"/*/PROGS > "$W/PROGS.tmp" 2>/dev/null && mv -f "$W/PROGS.tmp" "$W/PROGS"
  cat "$W"/*/JOBS > "$W/JOBS.tmp" 2>/dev/null && mv -f "$W/JOBS.tmp" "$W/JOBS"
  touch "$PW/SIZED"
}

one_program() {
  setp "$1" || { echo "STOPPED: unknown program $1"; return 1; }
  mkdir -p "$PW"
  if [ -f "$PW/SIZED" ]; then echo; echo "=== $P: sized already ($(cat "$PW/CHOSEN")) -- skipped"; return 0; fi
  build && inputs && size && record && { echo; echo "=== $(date '+%F %T')  $P: sized ==="; }
}

pipeline() {
  echo $$ > "$PIDF"
  local p
  for p in "$@"; do one_program "$p"; done
  rm -f "$PIDF"
  echo; echo "=== $(date '+%F %T')  all programs handled: $(ls "$W"/*/SIZED 2>/dev/null | wc -l) sized ==="
}

case "${1:-}" in
  size)
    shift; progs="${*:-$PROGS_DEFAULT}"
    for p in $progs; do info "$p" > /dev/null || { echo "unknown program $p ($PROGS_DEFAULT)"; exit 1; }; done
    [ -x "$PIN_ROOT/pin" ] || { echo "no Pin at $PIN_ROOT"; exit 1; }
    mkdir -p "$W" "$HOME/.build_tmp"
    if alive "$PIDF"; then echo "already running (pid $(cat "$PIDF")) -- 'status'"; exit 0; fi
    # shellcheck disable=SC2086
    ( cd "$W" || exit 1; setsid bash "$SELF" __pipeline $progs >> "$LOG" 2>&1 < /dev/null & )
    sleep 2
    echo "started for: $progs; log $LOG (each program: build, inputs, Pin counts up its ladder -- minutes to hours)" ;;
  __pipeline) shift; pipeline "$@" ;;
  sizegem5)
    # rule (c) (newbench_design, amendment 2): LU non-contiguous replaces
    # radiosity. Its gem5 runs need only the static binary and the chosen
    # input, so they start as soon as it is sized; it is traced separately.
    shift; progs="$*"
    [ -n "$progs" ] || { echo "usage: sizegem5 <program> ..."; exit 1; }
    for p in $progs; do info "$p" > /dev/null || { echo "unknown program $p"; exit 1; }; done
    [ -x "$PIN_ROOT/pin" ] || { echo "no Pin at $PIN_ROOT"; exit 1; }
    [ -f "$HOME/launch_b3_gem5.sh" ] && [ -f "$HOME/run_gem5_splash.sh" ] || { echo "no ~/launch_b3_gem5.sh or ~/run_gem5_splash.sh -- upload them"; exit 1; }
    mkdir -p "$W" "$HOME/.build_tmp"
    if alive "$PIDF"; then echo "already running (pid $(cat "$PIDF")) -- 'status'"; exit 0; fi
    # shellcheck disable=SC2086
    ( cd "$W" || exit 1; setsid bash "$SELF" __sizegem5 $progs >> "$LOG" 2>&1 < /dev/null & )
    sleep 2
    echo "started for: $progs; log $LOG (size, then the gem5 runs: launch_b3_gem5.sh, log ~/gem5_b3/newbench/<p>/launch.log)" ;;
  __sizegem5)
    shift
    pipeline "$@"
    for p in "$@"; do
      if [ -f "$W/$p/SIZED" ]; then
        echo "=== $(date '+%F %T')  $p: starting its gem5 runs ($(cat "$W/$p/CHOSEN")) ==="
        WL="$p" bash "$HOME/launch_b3_gem5.sh" go
      else
        echo "=== $(date '+%F %T')  $p: NOT sized -- no gem5 run started ==="
      fi
    done ;;
  tracelen)
    # newbench_design amendment 2 (2026-10-28): instructions traced per thread,
    # field 9 of the program's PROGS line (0 = the whole run); kept in the
    # program's own file, which ~/newbench/PROGS is rebuilt from
    shift
    [ $# -ge 2 ] && [ $(($# % 2)) = 0 ] || { echo "usage: tracelen <program> <instructions> [<program> <instructions> ...]"; exit 1; }
    while [ $# -ge 2 ]; do
      f="$W/$1/PROGS"
      [ -f "$f" ] && [ -f "$W/$1/SIZED" ] || { echo "$1 is not sized (no $f)"; exit 1; }
      case "$2" in ''|*[!0-9]*) echo "not a number of instructions: $2"; exit 1 ;; esac
      [ -f "$f.orig" ] || cp -p "$f" "$f.orig"
      awk -F'|' -v OFS='|' -v n="$2" '{ $9 = n; print }' "$f" > "$f.tmp" && mv -f "$f.tmp" "$f" || exit 1
      [ "$(cut -d'|' -f1-8 "$f")" = "$(cut -d'|' -f1-8 "$f.orig")" ] || { echo "$1: the first eight fields changed -- restored"; cp -p "$f.orig" "$f"; exit 1; }
      echo "   $1: $(cut -d'|' -f9 "$f") instructions a thread$([ "$2" = 0 ] && echo ' (the whole run)')"
      shift 2
    done
    cat "$W"/*/PROGS > "$W/PROGS.tmp" 2>/dev/null && mv -f "$W/PROGS.tmp" "$W/PROGS" ;;
  status)
    echo "== new benchmarks, sizing: $(for p in $PROGS_DEFAULT; do [ -f "$W/$p/SIZED" ] && echo "$p"; done | wc -l) of $(echo $PROGS_DEFAULT | wc -w) sized ($PROGS_DEFAULT); $(alive "$PIDF" && echo running || echo 'not running')"
    [ -f "$W/lunc/SIZED" ] && echo "   lunc (rule c): sized, $(cat "$W/lunc/CHOSEN")"
    [ -f "$LOG" ] && grep -E "===|STOPPED|QB|rung|threads:|CHOSEN|below|exited|PROGS|rror|libraries|compile:|launching|gem5" "$LOG" | tail -40 | sed 's/^/   /'
    echo "   disk: $(df -h "$HOME" | tail -1 | awk '{print $4}') free" ;;
  *) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
