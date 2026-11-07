#!/usr/bin/env bash
# Held-out set 2 on the server, part 1: build and size
# (bench/policy_sanity/heldout2_design_2026-11-04.md, Note 2). Writes only under
# ~/heldout2, ~/heldout2_build and ~/heldout2_static; touches no trace, run,
# queue or binary of the main tree.
#
#   bash ~/heldout2_server.sh size [progs]       # detached; default: the five; a program sized already is skipped
#   bash ~/heldout2_server.sh sizegem5 [progs]   # size, then start each sized one's two gem5 runs (launch_b3_gem5.sh)
#   bash ~/heldout2_server.sh status
#   bash ~/heldout2_server.sh regem5 progs...    # Note 3: stop these programs' gem5 runs (only theirs, by
#                                                # output directory) and launch them again with the runner now
#                                                # on the server; then each run's stop per CPU from config.ini
#
# Programs: fluidanimate bodytrack facesim vips (the four first candidates)
# and oceannc (ocean non-contiguous, reported apart).
#
# Per program:
#   1. build   from a COPY of the source, fortify off: a dynamic binary (Pin)
#              and the same objects linked -static (gem5). QB: every function
#              of the program's objects has the same instruction count and
#              constants in both binaries; a function absent from both (an
#              archive member never linked) is counted, not compared.
#   2. inputs  PARSEC's input tars, uploaded from the laptop's
#              parsec-3.0-input-sim.tar.gz into ~/heldout2/upload/<p>/ and
#              checked against MD5SUMS there, unpacked into ~/heldout2/<p>/inputs/<set>/
#   3. size    the probe (simulator/tracer/h2probe, a Pin tool) up the ladder,
#              smallest first:
#                E3: the number of threads the run creates equals the
#                    recipe's (each created once);
#                E5: every traced thread executes >= 300 M instructions.
#              The first rung meeting both is chosen. The probe also prints
#              where main is when its workers start, and the untraced
#              threads' share of instructions in the native window (the
#              reference worker from 50 M to 150 M): reported, decides nothing.
#   4. record  ~/heldout2/<p>/CHOSEN, NCPU (gem5's CPUs: every thread the
#              program creates), and the program's lines for the
#              synchronised-replay chain in ~/heldout2/PROGS and ~/heldout2/JOBS
set -uo pipefail
SELF="$(readlink -f "$0")"
R="${R:-$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy}"
S="$R/simulator"
PARSEC="${PARSEC:-$S/tracer/pin/parsec-full}"
SPLASH="${SPLASH:-$S/tracer/splash-3/codes}"
PIN_ROOT="${PIN_ROOT:-$S/tracer/pin/pin-external-3.31-98869-gfa6f126a8-gcc-linux}"
W="${W:-$HOME/heldout2}"
BUILD="${BUILD:-$HOME/heldout2_build}"
STATIC_DIR="${STATIC_DIR:-$HOME/heldout2_static}"
UP="$W/upload"
PROBE_DIR="$W/h2probe"
PROBE="$PROBE_DIR/obj-intel64/h2probe.so"
CC="${CC:-gcc}"
CXX="${CXX:-g++}"
JOBS_MAKE="${JOBS_MAKE:-8}"
MIN_INSTR="${MIN_INSTR:-300000000}"
RUN_TIMEOUT="${RUN_TIMEOUT:-6h}"
PROGS_DEFAULT="fluidanimate bodytrack facesim vips oceannc"
LOG="$W/size.log"
PIDF="$W/.size.pid"
# fortify off and -O2 -g for every compile (as every earlier program)
CF="-O2 -g -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0"
# PARSEC's C++ is C++98 (dynamic exception specifications, and code that
# needs -fpermissive, which PARSEC's own gcc.bldconf passes)
CXXF="$CF -std=gnu++98 -fpermissive -pthread"
trap 'rc=$?; [ "$rc" = 0 ] || echo "heldout2_server.sh ${1:-}: stopped, exit code $rc ($(date "+%F %T"))" >&2' EXIT

alive() { [ -f "$1" ] && kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null; }
step() { echo; echo "=== $(date '+%F %T')  $P: $* ==="; }
fail() { echo "STOPPED ($P): $*"; return 1; }

# program -> kind | source dir | binary name | threads the run creates (main
# included) | threads traced | where thread 0's trace starts (0: thread 0 not
# cut; start0:broadcast: at its first pthread_cond_broadcast, Note 2)
info() {
  case "$1" in
    fluidanimate) echo "parsec|apps/fluidanimate|fluidanimate|5|1 2 3 4|0" ;;
    bodytrack)    echo "parsec|apps/bodytrack|bodytrack|6|1 2 3 4|0" ;;
    facesim)      echo "parsec|apps/facesim|facesim|4|0 1 2 3|start0:broadcast" ;;
    vips)         echo "parsec|apps/vips|vips|7|3 4 5 6|0" ;;
    oceannc)      echo "splash|apps/ocean/non_contiguous_partitions|OCEAN|4|0 1 2 3|0" ;;
    *) return 1 ;;
  esac
}
# program -> its ladder, smallest first: "input set | arguments | stdin | what
# the run needs in its directory (from inputs/<set>/)". PARSEC's run
# configurations without native (Note 1: no native input on either machine);
# NTHREADS = 4. vips: IM_CONCURRENCY=4 (PARSEC's runconf) as the option that
# sets the same variable (im_init_world.c: --vips-concurrency).
ladder() {
  case "$1" in
    fluidanimate) printf '%s\n' "simsmall|4 5 in_35K.fluid out.fluid||in_35K.fluid" \
                                "simmedium|4 5 in_100K.fluid out.fluid||in_100K.fluid" \
                                "simlarge|4 5 in_300K.fluid out.fluid||in_300K.fluid" ;;
    bodytrack)    printf '%s\n' "simsmall|sequenceB_1 4 1 1000 5 0 4||sequenceB_1" \
                                "simmedium|sequenceB_2 4 2 2000 5 0 4||sequenceB_2" \
                                "simlarge|sequenceB_4 4 4 4000 5 0 4||sequenceB_4" ;;
    facesim)      printf '%s\n' "simsmall|-timing -threads 4||Face_Data" ;;   # the three sets are one file (Note 1)
    vips)         printf '%s\n' "simsmall|--vips-concurrency=4 im_benchmark pomegranate_1600x1200.v output.v||pomegranate_1600x1200.v" \
                                "simmedium|--vips-concurrency=4 im_benchmark vulture_2336x2336.v output.v||vulture_2336x2336.v" \
                                "simlarge|--vips-concurrency=4 im_benchmark bigben_2662x5500.v output.v||bigben_2662x5500.v" ;;
    oceannc)      printf '%s\n' "-|-n514 -p4 -e1e-7 -r20000 -t28800||" ;;   # ocean's arguments
  esac
}
static_name() { [ "$P" = oceannc ] && echo OCEAN-NC || echo "$NAME"; }

setp() {
  P="$1"
  local i; i="$(info "$P")" || return 1
  IFS='|' read -r KIND DIR NAME NTHR TIDS START0 <<< "$i"
  PW="$W/$P"
  if [ "$KIND" = splash ]; then PB="$BUILD/$P/codes/$DIR"; else PB="$BUILD/$P/src"; fi
  DYN="$BUILD/$P/$NAME.dyn"; STA="$BUILD/$P/$NAME.static"
}

# --- QB, as newbench_server.sh: instruction counts without alignment padding,
# and constants. Counted per COPY of a function: a local function of the
# program (a C++ template clone such as basic_string::_M_construct.isra.0) can
# share its name with a local one inside libstdc++.a, which only the static
# binary holds (bodytrack, laptop rehearsal 2026-11-04: 48 + 96 = 144).
disasm() {
  objdump -d --no-show-raw-insn "$1" 2>/dev/null | awk '
    /^[0-9a-f]+ <.*>:$/ { fn = $2; sub(/^</, "", fn); sub(/>:$/, "", fn); print fn "\t@@start"; next }
    /^ +[0-9a-f]+:/ { sub(/^ +[0-9a-f]+:[ \t]+/, ""); sub(/[ \t]+#.*$/, ""); print fn "\t" $0 }'
}
fn_sizes() {   # one line per copy: name, instructions
  disasm "$1" | awk -F'\t' '$2 == "@@start" { if (fn != "") print fn, n; fn = $1; n = 0; next }
    $2 !~ /^(nop|cs |data16|int3|xchg +%ax,%ax)/ { n++ } END { if (fn != "") print fn, n }' | LC_ALL=C sort
}
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
qb() {   # object files and archives (paths)
  local res same absent bad n m
  # the program's functions: name, T if global in any object (one copy by
  # the one-definition rule), t if only local (copies may share the name)
  # shellcheck disable=SC2086 -- a list of files
  nm --defined-only $1 2>/dev/null | awk 'NF == 3 && $2 ~ /^[Tt]$/ { k[$3] = (k[$3] == "T" || $2 == "T") ? "T" : "t" }
    END { for (x in k) print x, k[x] }' | LC_ALL=C sort > "$PW/qb_functions.txt"
  [ -s "$PW/qb_functions.txt" ] || { fail "no functions found in the objects"; return 1; }
  fn_sizes "$DYN" > "$PW/sizes_dyn.txt"; fn_sizes "$STA" > "$PW/sizes_static.txt"
  # one pass (the C++ programs have thousands of functions). A function in
  # neither binary is an archive member never linked. Otherwise every copy in
  # the dynamic binary must be in the static one with the same count, and a
  # global function must have no other copy there.
  res=$(awk 'FILENAME == ARGV[1] { kind[$1] = $2; next }
    FILENAME == ARGV[2] { if ($1 in kind) { d[$1 SUBSEP $2]++; dn[$1]++ } next }
    { if ($1 in kind) { s[$1 SUBSEP $2]++; sn[$1]++ } }
    END { for (k in d) { split(k, a, SUBSEP); if (d[k] > s[k] + 0) miss[a[1]] = 1 }
          for (x in kind) {
            if (!(x in dn) && !(x in sn)) { absent++; continue }
            why = ""
            if (!(x in dn)) why = "absent from the dynamic binary"
            else if (!(x in sn)) why = "absent from the static binary"
            else if (x in miss) why = "a copy of the dynamic binary is not in the static one"
            else if (kind[x] == "T" && dn[x] != sn[x]) why = "global, " dn[x] " copies dynamic and " sn[x] " static"
            if (why != "") { bad++; if (bad <= 10) printf "   %s: %s\n", x, why > "/dev/stderr" } else same++ }
          print same + 0, absent + 0, bad + 0 }' "$PW/qb_functions.txt" "$PW/sizes_dyn.txt" "$PW/sizes_static.txt")
  read -r same absent bad <<< "$res"
  # constants, per name over its copies: the dynamic binary's must all be in
  # the static one's; for a global function the two sets are equal
  fn_consts "$DYN" | awk 'NR == FNR { k[$1] = 1; next } ($1 in k)' "$PW/qb_functions.txt" - | LC_ALL=C sort > "$PW/consts_dyn.txt"
  fn_consts "$STA" | awk 'NR == FNR { k[$1] = 1; next } ($1 in k)' "$PW/qb_functions.txt" - | LC_ALL=C sort > "$PW/consts_static.txt"
  n=$(LC_ALL=C comm -23 "$PW/consts_dyn.txt" "$PW/consts_static.txt" | tee "$PW/qb_consts_dyn_only.txt" | wc -l)
  m=$(LC_ALL=C comm -13 "$PW/consts_dyn.txt" "$PW/consts_static.txt" | awk 'NR == FNR { if ($2 == "T") g[$1] = 1; next } ($1 in g)' "$PW/qb_functions.txt" - | tee "$PW/qb_consts_static_only.txt" | wc -l)
  if [ "$n" != 0 ] || [ "$m" != 0 ]; then
    echo "   constants: $n line(s) only in the dynamic binary, $m only in the static one for a global function (first: $(head -2 "$PW/qb_consts_dyn_only.txt" "$PW/qb_consts_static_only.txt" | grep -v '^==' | grep . | head -2 | tr '\n' ' '))"
    bad=$((bad + 1))
  fi
  [ "$bad" = 0 ] || { fail "QB: $bad difference(s) between the dynamic and the static binary"; return 1; }
  echo "   QB: all $same functions of the program's objects that are linked have the same instruction count and constants in both binaries ($absent in neither: archive members not linked)"
}

# autotools outputs made newer than their inputs, so make never reruns
# aclocal / autoconf / automake (the server's are newer than the tarballs')
stamps() {
  local now; now=$(date +%s)
  find . \( -name configure.in -o -name configure.ac -o -name Makefile.am -o -name '*.m4' \) ! -name aclocal.m4 -exec touch -d "@$((now - 30))" {} +
  find . -name aclocal.m4 -exec touch -d "@$((now - 20))" {} +
  find . -name configure -exec touch -d "@$((now - 10))" {} +
  find . \( -name Makefile.in -o -name config.h.in \) -exec touch -d "@$((now - 5))" {} +
  find . -type f \( -name configure -o -name config.guess -o -name config.sub -o -name install-sh -o -name missing \
    -o -name depcomp -o -name mkinstalldirs -o -name '*.sh' -o -name '*.pl' -o -name '*.py' \) -exec chmod u+x {} +
}
# gettext's msgfmt, which GLib's configure requires, may be absent: a stub
# that writes empty message catalogues (translations, which the benchmark
# never loads)
stub_msgfmt() {
  local d="$BUILD/$P/stub"
  mkdir -p "$d"
  cat > "$d/msgfmt" <<'EOF'
#!/bin/sh
out=""; while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift ;; -o*) out="${1#-o}" ;; --output-file=*) out="${1#*=}" ;; --version) echo "msgfmt (GNU gettext-tools) 0.19 (heldout2 stub)"; exit 0 ;; esac; shift; done
[ -n "$out" ] && : > "$out"; exit 0
EOF
  printf '#!/bin/sh\nexit 0\n' > "$d/xgettext"
  chmod +x "$d/msgfmt" "$d/xgettext"; ln -sf msgfmt "$d/gmsgfmt"
  echo "$d"
}

build() {
  step "1/4 build, dynamic and static, from one set of objects"
  local objs cf src o s inst stub
  rm -rf "${BUILD:?}/$P"; mkdir -p "$BUILD/$P" "$PW"
  case "$P" in
    fluidanimate)
      cp -rp "$PARSEC/pkgs/apps/fluidanimate/src" "$PB" && cd "$PB" || { fail "could not copy the source"; return 1; }
      # POSIX barriers: PARSEC's header redefines pthread_barrier_* to its
      # spin barrier, which the tracer cannot see (as streamcluster)
      sed -i 's|^#define ENABLE_AUTOMATIC_DROPIN|// #define ENABLE_AUTOMATIC_DROPIN  (disabled for COALESCE: POSIX barriers, which the tracer records)|' parsec_barrier.hpp
      grep -q '^#define ENABLE_AUTOMATIC_DROPIN' parsec_barrier.hpp && { fail "could not disable the spin-barrier drop-in"; return 1; }
      cf="$CXXF -D_GNU_SOURCE -D__XOPEN_SOURCE=600"   # Makefile.pthreads' own flags
      echo "   $CXX $cf (Makefile.pthreads' objects; the drop-in disabled)"
      objs=""
      for s in pthreads cellpool parsec_barrier; do
        # shellcheck disable=SC2086
        $CXX $cf -c "$s.cpp" -o "$s.o" >> build.log 2>&1 || { tail -5 build.log | sed 's/^/      /'; fail "compile of $s.cpp failed"; return 1; }
        objs="$objs $PB/$s.o"
      done
      # shellcheck disable=SC2086
      $CXX $cf -o "$DYN" $objs >> build.log 2>&1 && $CXX $cf -o "$STA" $objs -static >> build.log 2>&1 \
        || { tail -5 build.log | sed 's/^/      /'; fail "the link failed"; return 1; }
      nm "$DYN" | grep -q ' U pthread_barrier_wait' || { fail "the dynamic binary does not call pthread_barrier_wait: the drop-in is still in"; return 1; } ;;
    bodytrack)
      cp -rp "$PARSEC/pkgs/apps/bodytrack/src" "$PB" && cd "$PB" || { fail "could not copy the source"; return 1; }
      # the pthreads build (--enable-threads --disable-openmp --disable-tbb):
      # Makefile.am's sources with ENABLE_THREADS, and the three macros its
      # configure would put in config.h for them (USE_THREADS) and that the
      # code reads (HAVE_LIBPTHREAD, HAVE_STDINT_H); -fexceptions as PARSEC's bldconf
      cf="$CXXF -fexceptions -DUSE_THREADS=1 -DHAVE_LIBPTHREAD=1 -DHAVE_STDINT_H=1 -IFlexImageLib"
      echo "   $CXX $cf (Makefile.am's pthreads sources)"
      objs=""
      for src in FlexImageLib/FlexImage.cpp FlexImageLib/FlexIO.cpp \
                 TrackingBenchmark/threads/Thread.cpp TrackingBenchmark/threads/ThreadGroup.cpp TrackingBenchmark/threads/WorkerGroup.cpp \
                 TrackingBenchmark/threads/Mutex.cpp TrackingBenchmark/threads/Condition.cpp TrackingBenchmark/threads/Barrier.cpp \
                 TrackingBenchmark/threads/RWLock.cpp TrackingBenchmark/AnnealingFactor.cpp TrackingBenchmark/BodyGeometry.cpp \
                 TrackingBenchmark/BodyPose.cpp TrackingBenchmark/CameraModel.cpp TrackingBenchmark/CovarianceMatrix.cpp \
                 TrackingBenchmark/ImageMeasurements.cpp TrackingBenchmark/ImageProjection.cpp TrackingBenchmark/RandomGenerator.cpp \
                 TrackingBenchmark/TrackingModel.cpp TrackingBenchmark/main.cpp TrackingBenchmark/TrackingModelPthread.cpp \
                 TrackingBenchmark/AsyncIO.cpp; do
        o="${src%.cpp}.o"
        # shellcheck disable=SC2086
        $CXX $cf -c "$src" -o "$o" >> build.log 2>&1 || { tail -5 build.log | sed 's/^/      /'; fail "compile of $src failed"; return 1; }
        objs="$objs $PB/$o"
      done
      # shellcheck disable=SC2086
      $CXX $cf -o "$DYN" $objs -lm >> build.log 2>&1 && $CXX $cf -o "$STA" $objs -lm -static >> build.log 2>&1 \
        || { tail -5 build.log | sed 's/^/      /'; fail "the link failed"; return 1; } ;;
    facesim)
      cp -rp "$PARSEC/pkgs/apps/facesim/src" "$PB" && cd "$PB" || { fail "could not copy the source"; return 1; }
      # PARSEC's pthreads build (version=pthreads, PHYSBAM=<the tree>), with
      # -fwrapv-pointer: PhysBAM's ARRAY keeps base_pointer = array - 1
      # (1-based arrays) and frees base_pointer + 1; gcc 13 at -O2 assumes
      # that pointer arithmetic cannot wrap and drops delete[]'s null check,
      # and the program crashes in its argument parser (laptop, gcc 13.4,
      # 2026-11-04). The flag lets pointer arithmetic wrap and nothing else.
      cf="$CXXF -fexceptions -fwrapv-pointer -DENABLE_PTHREADS"
      echo "   make version=pthreads CXX=$CXX CXXFLAGS=\"$cf\" (PhysBAM and TaskQ's own makefiles)"
      make -j"$JOBS_MAKE" version=pthreads PHYSBAM="$PB" CXX="$CXX" CXXFLAGS="$cf" > build.log 2>&1 \
        || { grep -m3 -i ' error' build.log | sed 's/^/      /'; fail "make failed"; return 1; }
      [ -x Benchmarks/facesim/facesim ] || { fail "the build produced no facesim"; return 1; }
      cp -p Benchmarks/facesim/facesim "$DYN"
      objs="$(ls "$PB"/Benchmarks/facesim/obj/*.o | tr '\n' ' ') $PB/TaskQ/lib/taskQ.o $PB/lib/libPhysBAM.a"
      # the same objects in make's link order, -static
      # shellcheck disable=SC2086
      ( cd Benchmarks/facesim && $CXX $cf -o "$STA" obj/main.o $(ls obj/*.o | grep -v '^obj/main.o$') -L"$PB/lib" -lPhysBAM "$PB/TaskQ/lib/taskQ.o" -pthread -lm -static ) >> build.log 2>&1 \
        || { tail -5 build.log | sed 's/^/      /'; fail "the static link failed"; return 1; } ;;
    vips)
      # vips and its three libraries from PARSEC's sources, as its bldconfs:
      # zlib; GLib --disable-shared --enable-threads --with-threads=posix;
      # libxml2 --disable-shared --with-threads; vips ${vips_basic_conf}
      # --enable-threads. Every library is static, so the dynamic binary
      # differs from the static one only in libc, libm and libstdc++.
      inst="$BUILD/$P/inst"; mkdir -p "$inst"
      stub=$(stub_msgfmt)
      local -a env_b=(env CC="$CC" CXX="$CXX" PATH="$stub:$PATH")
      cp -rp "$PARSEC/pkgs/libs/zlib/src" "$BUILD/$P/zlib" && cd "$BUILD/$P/zlib" || { fail "could not copy zlib"; return 1; }
      "${env_b[@]}" make -j"$JOBS_MAKE" CC="$CC" CFLAGS="$CF" > build.log 2>&1 && "${env_b[@]}" make install prefix="$inst" >> build.log 2>&1 \
        || { tail -5 build.log | sed 's/^/      /'; fail "zlib failed"; return 1; }
      cp -rp "$PARSEC/pkgs/libs/glib/src" "$BUILD/$P/glib" && cd "$BUILD/$P/glib" && stamps || { fail "could not copy glib"; return 1; }
      "${env_b[@]}" CFLAGS="$CF" ./configure --prefix="$inst" --disable-shared --enable-threads --with-threads=posix > build.log 2>&1 \
        && "${env_b[@]}" make -j"$JOBS_MAKE" >> build.log 2>&1 && "${env_b[@]}" make install >> build.log 2>&1 \
        || { grep -m3 -i 'error' build.log | sed 's/^/      /'; fail "GLib failed ($BUILD/$P/glib/build.log)"; return 1; }
      cp -rp "$PARSEC/pkgs/libs/libxml2/src" "$BUILD/$P/libxml2" && cd "$BUILD/$P/libxml2" && stamps || { fail "could not copy libxml2"; return 1; }
      "${env_b[@]}" CFLAGS="-I$inst/include $CF" LDFLAGS="-L$inst/lib" ./configure --prefix="$inst" --disable-shared --with-threads --without-python > build.log 2>&1 \
        && "${env_b[@]}" make -j"$JOBS_MAKE" >> build.log 2>&1 && "${env_b[@]}" make install >> build.log 2>&1 \
        || { grep -m3 -i 'error' build.log | sed 's/^/      /'; fail "libxml2 failed ($BUILD/$P/libxml2/build.log)"; return 1; }
      cp -rp "$PARSEC/pkgs/apps/vips/src" "$PB" && cd "$PB" && stamps || { fail "could not copy vips"; return 1; }
      local conf="--disable-shared --disable-cxx --without-fftw3 --without-magick --without-liboil --without-lcms --without-OpenEXR --without-matio --without-pangoft2 --without-tiff --without-jpeg --without-zip --without-png --without-libexif --without-python --without-x --without-perl --without-v4l --without-cimg --enable-threads"
      local -a env_v=("${env_b[@]}" CFLAGS="$CF" CXXFLAGS="-I$inst/include $CF -fexceptions" LDFLAGS="-L$inst/lib" PKG_CONFIG_PATH="$inst/lib/pkgconfig" LIBS="-lstdc++")
      echo "   vips: configure $conf (zlib, GLib, libxml2 built static into $inst)"
      # shellcheck disable=SC2086
      "${env_v[@]}" ./configure --prefix="$inst" $conf > build.log 2>&1 && "${env_v[@]}" make -j"$JOBS_MAKE" >> build.log 2>&1 \
        || { grep -m3 -i 'error' build.log | sed 's/^/      /'; fail "vips failed ($PB/build.log)"; return 1; }
      [ -x tools/iofuncs/vips ] && file -b tools/iofuncs/vips | grep -q ELF || { fail "the build produced no vips binary"; return 1; }
      cp -p tools/iofuncs/vips "$DYN"
      # the same objects relinked by the same libtool command, -all-static
      rm -f tools/iofuncs/vips
      "${env_v[@]}" make -C tools/iofuncs vips LDFLAGS="-L$inst/lib -all-static" >> build.log 2>&1 \
        || { tail -5 build.log | sed 's/^/      /'; fail "the static link failed"; return 1; }
      cp -p tools/iofuncs/vips "$STA"
      objs="$PB/tools/iofuncs/vips.o $PB/libvips/.libs/libvips.a" ;;
    oceannc)
      mkdir -p "$BUILD/$P/codes/$(dirname "$DIR")" || { fail "cannot create $BUILD/$P"; return 1; }
      cp -p "$SPLASH/Makefile.config" "$BUILD/$P/codes/" && cp -rp "$SPLASH/pthread_macros" "$BUILD/$P/codes/" \
        && cp -rp "$SPLASH/$DIR" "$BUILD/$P/codes/$DIR" && cd "$PB" || { fail "could not copy the source"; return 1; }
      # Its arrays are static, IMAX x JMAX doubles, sized for the largest
      # grid: 8194 on a 64-bit target makes one struct 15 GB, which malloc
      # refuses (laptop) and gem5's 4 GB memory cannot hold. SPLASH-3's own
      # 32-bit size, 2050, holds the 514-point grid it runs (about 1.9 GB).
      sed -i 's@^#if defined(SPARC_SOLARIS) || defined(__i386__) || defined(__ARM_32BIT_STATE).*$@#if 1  /* heldout2 (Note 2): SPLASH-3s 32-bit array size, IMAX = JMAX = 2050 */@' decs.h.in
      grep -q '^#if 1  /\* heldout2' decs.h.in || { fail "could not set the array size in decs.h.in"; return 1; }
      make clean > /dev/null 2>&1
      # fortify off through CC (newbench_server.sh, 2026-10-21)
      local fcc="$CC -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0" base_cf
      base_cf=$(grep -E '^\s*CFLAGS\s*[:+]?=' "$BUILD/$P/codes/Makefile.config" | head -1 | sed 's/^[^=]*=//')
      cf="$base_cf -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0"
      echo "   make CC=\"$fcc\" (the tree's CFLAGS)"
      make CC="$fcc" > build.log 2>&1 || { tail -5 build.log | sed 's/^/      /'; fail "make failed"; return 1; }
      [ -x "$NAME" ] || { fail "the build produced no $NAME"; return 1; }
      mv -f "$NAME" "$DYN"
      objs=$(ls "$PB"/*.o | tr '\n' ' ')
      # shellcheck disable=SC2086
      $CC $cf -o "$STA" $objs -lm -static >> build.log 2>&1 || { tail -5 build.log | sed 's/^/      /'; fail "the static link failed"; return 1; } ;;
  esac
  cd "$HOME" || true
  file -b "$DYN" | grep -q 'dynamically linked' || { fail "$NAME.dyn is not dynamically linked"; return 1; }
  file -b "$STA" | grep -q 'statically linked' || { fail "$NAME.static is not statically linked"; return 1; }
  ( cd "$BUILD/$P" && timeout 10 "$DYN" < /dev/null > "$PW/usage.txt" 2>&1 )
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
  local set f n=0
  rm -rf "$PW/inputs"; mkdir -p "$PW/inputs"
  [ "$KIND" = parsec ] || { echo "   none (generated by the program)"; return 0; }
  [ -f "$UP/$P/MD5SUMS" ] || { fail "no $UP/$P/MD5SUMS -- heldout2_all.sh uploads the inputs"; return 1; }
  ( cd "$UP/$P" && md5sum -c --quiet MD5SUMS ) || { fail "an uploaded input does not match its md5"; return 1; }
  for set in $(ladder "$P" | cut -d'|' -f1 | sort -u); do
    f="$UP/$P/input_$set.tar"
    [ -f "$f" ] || { fail "no $f"; return 1; }
    mkdir -p "$PW/inputs/$set" && tar -xf "$f" -C "$PW/inputs/$set" || { fail "could not unpack $f"; return 1; }
    echo "   $set: $(ls "$PW/inputs/$set" | tr '\n' ' ')($(du -sh "$PW/inputs/$set" | cut -f1))"
    n=$((n + 1))
  done
  echo "   $n input set(s), md5 checked"
}

build_probe() {
  [ -f "$PROBE" ] && [ "$PROBE" -nt "$PROBE_DIR/h2probe.cpp" ] && return 0
  ( cd "$PROBE_DIR" && make PIN_ROOT="$PIN_ROOT" obj-intel64/h2probe.so ) > "$W/probe_build.log" 2>&1 \
    || { echo "STOPPED: the probe did not build ($W/probe_build.log)"; return 1; }
  echo "   probe built: $PROBE (md5 $(md5sum < "$PROBE" | cut -c1-12))"
}

# the run directory of rung k: the files its input needs, copied
rundir() {   # k set files -> prints the directory
  local d="$PW/run$1" f
  rm -rf "$d"; mkdir -p "$d"
  for f in $3; do cp -rp "$PW/inputs/$2/$f" "$d/" || return 1; done
  echo "$d"
}

size() {
  step "3/4 size: the probe up the ladder; E3 ($NTHR threads), E5 (traced threads $TIDS: >= $((MIN_INSTR / 1000000)) M each)"
  local k=0 rung set args sin files d low tid n nt ref chosen=""
  # the reference for the window: the first traced worker (not main)
  ref=$(for tid in $TIDS; do [ "$tid" = 0 ] || { echo "$tid"; break; }; done)
  while IFS= read -r rung; do
    k=$((k + 1))
    IFS='|' read -r set args sin files <<< "$rung"
    d=$(rundir "$k" "$set" "$files") || { fail "could not set up rung $k's directory"; return 1; }
    echo "   rung $k ($set): $NAME $args${sin:+ < $sin}"
    local in=/dev/null; [ -z "$sin" ] || in="$PW/inputs/$set/$sin"
    # shellcheck disable=SC2086 -- $args is the argument list
    ( cd "$d" && TMPDIR="$HOME/.build_tmp" timeout "$RUN_TIMEOUT" nice -n 10 "$PIN_ROOT/pin" -t "$PROBE" -o "$d/probe.txt" -ref "$ref" -- "$DYN" $args \
        < "$in" > "$d/out.txt" 2> "$d/err.txt" )
    n=$?
    [ "$n" = 0 ] || { echo "      exited $n ($(tail -1 "$d/err.txt" 2>/dev/null | cut -c1-100))"; continue; }
    nt=$(awk '$1 == "THREADS" { print $2 }' "$d/probe.txt")
    echo "      $nt threads: $(awk '$1 == "TOTAL" { printf "%s %.0fM  ", $2, $3 / 1e6 }' "$d/probe.txt")"
    echo "      thread creations: $(awk '$1 == "CALL" && $2 == "create" { printf "%s at %.1fM  ", $3, $5 / 1e6 }' "$d/probe.txt")"
    low=""
    [ "$nt" = "$NTHR" ] || low=" E3: $nt threads, the recipe has $NTHR"
    for tid in $TIDS; do
      n=$(awk -v t="t$tid" '$1 == "TOTAL" && $2 == t { print $3 }' "$d/probe.txt")
      [ -n "$n" ] || { low="$low $tid:absent"; continue; }
      [ "$n" -ge "$MIN_INSTR" ] || low="$low $tid:$n"
    done
    report_window "$d/probe.txt" "$ref"
    if [ -z "$low" ]; then chosen="$rung"; echo "      CHOSEN: E3 holds and every traced thread ($TIDS) executes >= $((MIN_INSTR / 1000000)) M"; break; fi
    echo "      not chosen:$low"
  done < <(ladder "$P")
  [ -n "$chosen" ] || { fail "no rung of the ladder meets E3 and E5 -- the design's order applies (the next candidate)"; return 1; }
  echo "$chosen" > "$PW/CHOSEN"
  echo "$NTHR" > "$PW/NCPU"
  cp -p "$d/probe.txt" "$PW/probe_chosen.txt"
}

# reported only: the reference worker from 50 M to 150 M, each thread's
# instructions there, and the untraced threads' share; and where thread 0 was
# at its first broadcast (facesim: where its parallel work starts)
report_window() {
  awk -v tr="$TIDS" -v ref="t$2" '
    /^SNAP/ { r = $3
      if (r >= 50000000 && !A) { A = 1; for (i = 5; i <= NF; i += 2) s[$i] = $(i + 1) }
      if (r >= 150000000 && !B) { B = 1; for (i = 5; i <= NF; i += 2) e[$i] = $(i + 1) } }
    $1 == "CALL" && $2 == "broadcast" && $3 == "t0" && !bc { bc = $5 }
    END {
      if (!B) { printf "      native window: the reference %s never reaches 150 M\n", ref; exit }
      n = split(tr, T, " "); for (k = 1; k <= n; k++) traced["t" T[k]] = 1
      line = ""
      for (t in e) { d = e[t] - (t in s ? s[t] : 0); if (t in traced) ts += d; else us += d; line = line sprintf("%s %.1fM ", t, d / 1e6) }
      printf "      native window (%s 50-150 M; reported only): %s; untraced/traced %.2f%%\n", ref, line, 100 * us / ts
      if (bc) printf "      thread 0 first pthread_cond_broadcast at %.1f M\n", bc / 1e6 }' "$1"
}

record() {
  step "4/4 record"
  local set args sin files fl="" f
  IFS='|' read -r set args sin files < "$PW/CHOSEN"
  for f in $files; do fl="$fl $PW/inputs/$set/$f"; done
  # sync_server.sh PROGS: name | binary | arguments | stdin | files | threads traced | skip | thread 0's start
  echo "$P|$DYN|$args|${sin:+$PW/inputs/$set/$sin}|${fl# }|$TIDS|0|$START0" > "$PW/PROGS"
  # JOBS_SPEC: suffix | workload | cores | scaled | warm-up | measured | traces
  echo "${P}4|$P|4|0|50000000|100000000|$P" > "$PW/JOBS"
  sed 's/^/   PROGS: /' "$PW/PROGS"; echo "   gem5 CPUs: $(cat "$PW/NCPU")"
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
  echo "=== $(date '+%F %T')  heldout2 sizing: $*; $CC / $CXX: $($CXX --version | head -1)"
  build_probe || { rm -f "$PIDF"; return 1; }
  for p in "$@"; do one_program "$p"; done
  rm -f "$PIDF"
  echo; echo "=== $(date '+%F %T')  all programs handled: $(ls "$W"/*/SIZED 2>/dev/null | wc -l) sized ==="
}

start() {   # mode progs...
  local mode="$1"; shift
  local progs="${*:-$PROGS_DEFAULT}" p
  for p in $progs; do info "$p" > /dev/null || { echo "unknown program $p ($PROGS_DEFAULT)"; exit 1; }; done
  [ -x "$PIN_ROOT/pin" ] || { echo "no Pin at $PIN_ROOT"; exit 1; }
  [ -f "$PROBE_DIR/h2probe.cpp" ] || { echo "no $PROBE_DIR/h2probe.cpp -- heldout2_all.sh uploads it"; exit 1; }
  if [ "$mode" = __sizegem5 ]; then
    [ -f "$HOME/launch_b3_gem5.sh" ] && [ -f "$HOME/run_gem5_splash.sh" ] || { echo "no ~/launch_b3_gem5.sh or ~/run_gem5_splash.sh -- upload them"; exit 1; }
  fi
  mkdir -p "$W" "$HOME/.build_tmp"
  if alive "$PIDF"; then echo "already running (pid $(cat "$PIDF")) -- 'status'"; exit 0; fi
  # shellcheck disable=SC2086
  ( cd "$W" || exit 1; setsid bash "$SELF" "$mode" $progs >> "$LOG" 2>&1 < /dev/null & )
  sleep 2
  echo "started for: $progs; log $LOG"
}

# Note 3: a program's gem5 runs launched before the worker-stop correction.
# Each run is found by its output directory: the processes whose command line
# holds --outdir=<dir> exactly (timeout and gem5, one session, started with
# setsid). Only a session holding nothing but timeout and gem5.opt is stopped.
# The launcher then keeps the stopped run's directory as <dir>.prev_<time>
# (nothing of it is read) and starts the run again with the runner now here.
regem5() {
  local G="${GEM5_B3:-$HOME/gem5_b3}/heldout2" p m od sids sid bad n
  [ $# -ge 1 ] || { echo "usage: $0 regem5 <program>..."; exit 1; }
  for p in "$@"; do info "$p" > /dev/null || { echo "unknown program $p"; exit 1; }; done
  grep -q 'wsl=' "$HOME/run_gem5_splash.sh" || { echo "the runner on the server has no worker-stop correction -- heldout2_all.sh uploads it"; exit 1; }
  for p in "$@"; do
    [ -f "$G/$p/.launcher.pid" ] && kill -0 "$(cat "$G/$p/.launcher.pid")" 2>/dev/null && { echo "$p: its launcher is still working -- nothing changed"; exit 1; }
    for m in 50 150; do
      od="$G/$p/l2_2MB_mi${m}M/${p}_4c"
      if grep -q "Exiting @ tick" "$od/run.log" 2>/dev/null; then echo "$p ${m}M: already ENDED with the old stop -- moved aside, launched again"; mv "$od" "$od.prev_$(date +%Y%m%d_%H%M%S)"; continue; fi
      sids=$(ps -u "$(id -u)" -o sid=,args= | awk -v o="--outdir=$od" '{ for (i = 2; i <= NF; i++) if ($i == o) { print $1; break } }' | sort -u)
      [ -n "$sids" ] || { echo "$p ${m}M: no process of this run is running"; continue; }
      for sid in $sids; do
        bad=$(ps -s "$sid" -o comm= | grep -vcxE 'timeout|gem5.opt')
        n=$(ps -s "$sid" -o comm= | wc -l)
        [ "$bad" = 0 ] || { echo "$p ${m}M: session $sid holds other processes ($(ps -s "$sid" -o comm= | tr '\n' ' ')) -- stopping nothing"; exit 1; }
        pkill -TERM -s "$sid"
        for _ in $(seq 1 60); do pgrep -s "$sid" > /dev/null || break; sleep 1; done
        pgrep -s "$sid" > /dev/null && { pkill -KILL -s "$sid"; sleep 2; }
        pgrep -s "$sid" > /dev/null && { echo "$p ${m}M: session $sid did not stop"; exit 1; }
        echo "$p ${m}M: stopped (session $sid, $n processes: timeout and gem5)"
      done
    done
  done
  for p in "$@"; do
    WL="$p" bash "$HOME/launch_b3_gem5.sh" go | sed 's/^/   /'
  done
  echo "   waiting for the launchers (about a minute of checks per run) ..."
  for p in "$@"; do
    for _ in $(seq 1 120); do [ -f "$G/$p/.launcher.pid" ] && kill -0 "$(cat "$G/$p/.launcher.pid")" 2>/dev/null || break; sleep 5; done
    grep -E 'kept as|stop when|pid|ERROR' "$G/$p/launch.log" | sed "s/^ */   $p: /"
  done
  sleep 20
  for p in "$@"; do WL="$p" bash "$HOME/launch_b3_gem5.sh" check | grep -E '==|stop per cpu|cmd' | sed 's/^/   /'; done
}

case "${1:-}" in
  size) shift; start __pipeline "$@"; echo "(each program: build, inputs, the probe up its ladder -- minutes to hours)" ;;
  sizegem5) shift; start __sizegem5 "$@"; echo "(size, then each sized program's two gem5 runs: launch_b3_gem5.sh, log ~/gem5_b3/heldout2/<p>/launch.log)" ;;
  __pipeline) shift; pipeline "$@" ;;
  __sizegem5)
    shift
    pipeline "$@"
    for p in "$@"; do
      if [ -f "$W/$p/SIZED" ]; then
        echo "=== $(date '+%F %T')  $p: starting its gem5 runs ($(cat "$W/$p/CHOSEN"); $(cat "$W/$p/NCPU") CPUs) ==="
        WL="$p" bash "$HOME/launch_b3_gem5.sh" go
      else
        echo "=== $(date '+%F %T')  $p: NOT sized -- no gem5 run started ==="
      fi
    done ;;
  regem5) shift; regem5 "$@" ;;
  status)
    echo "== held-out set 2, sizing: $(for p in $PROGS_DEFAULT; do [ -f "$W/$p/SIZED" ] && echo "$p"; done | wc -l) of $(echo $PROGS_DEFAULT | wc -w) sized; $(alive "$PIDF" && echo running || echo 'not running')"
    [ -f "$LOG" ] && grep -E "===|STOPPED|QB|rung|threads:|creations|CHOSEN|not chosen|exited|PROGS|gem5 CPUs|native window|broadcast at|rror|gem5" "$LOG" | tail -60 | sed 's/^/   /'
    echo "   disk: $(df -h "$HOME" | tail -1 | awk '{print $4}') free" ;;
  *) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
