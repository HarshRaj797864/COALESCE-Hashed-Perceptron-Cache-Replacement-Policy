#!/usr/bin/env bash
# Part B on the server, part 1: the 14 programs sized at 8 and 16 threads, and
# gem5's runs of every sized key
# (bench/policy_sanity/breadth_bc_design_2026-11-10.md, amendment 2 = Note 1,
# as corrected by amendment 3). Writes only under ~/partB and ~/gem5_b3/partB; builds
# nothing; touches no trace, run, queue or binary of any other tree.
#
#   bash ~/partB_server.sh plan             # every key's recipe and ladder; runs nothing
#   bash ~/partB_server.sh guards           # the checks below; runs nothing
#   bash ~/partB_server.sh go [programs]    # detached: sizing, and the gem5 driver beside it
#   bash ~/partB_server.sh size [programs]  # detached: sizing alone
#   bash ~/partB_server.sh gem5             # detached: the gem5 driver alone
#   bash ~/partB_server.sh status
#   bash ~/partB_server.sh check            # what each started gem5 run was given (its config.ini)
#   bash ~/partB_server.sh stop             # the sizing pipeline and the gem5 driver; NEVER a gem5 run
#
# A key is <program>_<N>, N = 8 or 16.
#
# Sizing, per key (Pin and the probe of held-out set 2, records only):
#   the probe runs the program's ladder, smallest rung first. At 8 threads
#   the first rung is the one chosen at 4; at 16 it is the one chosen at 8
#   (the ladder's first if the 8-thread key was not sized).
#     E3  the run creates the number of threads its family creates (table in
#         recipe), each once; vips: exactly two threads besides main execute
#         under 1 M instructions each (its idle helpers; threads 1 and 2 when
#         Pin numbers the threads in creation order); streamcluster: 2N + 1
#         thread starts (N workers for the stream's chunk, N for the final
#         clustering), the second N started only after the first N have ended.
#         Pin numbers threads in the order they START, which under load can
#         differ from the order they are created (seen in the rehearsal). So
#         vips's workers are taken as its N threads that are not idle,
#         whatever their numbers, and a run whose idle threads are not 1 and
#         2 is marked with a NOTE; and every run prints each untraced
#         thread's count, with a NOTE when one of them (main aside) executes
#         more than the least traced thread. A NOTE decides nothing.
#     E5  every traced thread executes at least 300 M instructions (radix:
#         its skip plus 300 M). radix's skip: SPLASH-3's barrier is a mutex
#         and a condition variable, and the last thread to arrive releases it
#         with pthread_cond_broadcast; the skip is the count of the traced
#         thread that makes the run's first pthread_cond_broadcast, rounded
#         DOWN to 10 M (at 4 threads: 780.14 / 780.31 M -> 780 M).
#   The first rung meeting E3 and E5 is chosen. A rung that does not run
#   (non-zero exit, the time limit) is reported and skipped. If no rung
#   meets E5, the largest rung that ran and met E3 is chosen and the key is
#   marked BELOW with its count (the design: traced on that rung, reported
#   with its count). If no rung meets E3 the key is NOT sized (reported,
#   excluded) and gem5 does not run it.
#   Records, in ~/partB/<key>/: CHOSEN, NTHR, NCPU, SKIP, MIN, [BELOW], MD5,
#   PROGS, JOBS, GEM5, probe_chosen.txt, SIZED -- or FAILED_E3.
#   Eight keys at a time at 8 threads, then four at a time at 16.
#   canneal_16 is not sized: its line is the one sync_mx/canneal16 was traced
#   with, on 17 CPUs.
#
# gem5, per sized key: two runs through ~/run_gem5_splash.sh go-pb (the same
#   run_one as every earlier run), stopping when a worker reaches the key's
#   skip + 50 M and skip + 150 M; 2 MB; --mem-size=16GB; time limit 168 h at 8
#   threads and 240 h at 16. 8-thread keys first; at most 24 gem5 runs of
#   Part B at once. A run that ENDED or is running is left alone; one stopped
#   by its time limit (the runner records timeout's exit status, 124, in the
#   run's limit.rc) is never started again; one that died otherwise (gem5's
#   own exit, or the machine's) is reported and started again only by a new
#   `gem5` (or `go`) command, from the beginning and with a new limit.
#   Output: ~/gem5_b3/partB/<key>/l2_2MB_mi<stop>M/<key>c/
#
# No auto-resume: after a reboot, run `go` again (the owner's word).
set -uo pipefail
SELF="$(readlink -f "$0")"
R="${R:-$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy}"
S="$R/simulator"
SPLASH_APPS="${SPLASH_APPS:-$S/tracer/splash-3/codes/apps}"
PIN_ROOT="${PIN_ROOT:-$S/tracer/pin/pin-external-3.31-98869-gfa6f126a8-gcc-linux}"
PROBE="${PROBE:-$HOME/heldout2/h2probe/obj-intel64/h2probe.so}"
PROBE_MD5="${PROBE_MD5:-f8af3b0b}"
W="${W:-$HOME/partB}"
G="${G:-$HOME/gem5_b3/partB}"
HELDOUT_IN="${HELDOUT_IN:-$HOME/b3_heldout/inputs}"
NB="${NB:-$HOME/newbench}"
H2="${H2:-$HOME/heldout2}"
BARNES_IN="${BARNES_IN:-$SPLASH_APPS/barnes/inputs/n16384-p4}"
NETS="${NETS:-$S/tracer/pin/100000.nets}"
RUNNER="${RUNNER:-$HOME/run_gem5_splash.sh}"
MIN_INSTR="${MIN_INSTR:-300000000}"
RUN_TIMEOUT="${RUN_TIMEOUT:-6h}"
SIZE_PAR8="${SIZE_PAR8:-8}"
SIZE_PAR16="${SIZE_PAR16:-4}"
GEM5_MAX="${GEM5_MAX:-24}"
GEM5_MEM="${GEM5_MEM:-16GB}"
LIMIT8="${LIMIT8:-168h}"
LIMIT16="${LIMIT16:-240h}"
POLL_S="${POLL_S:-300}"
MIN_DISK_GB="${MIN_DISK_GB:-30}"
PROGS14="ocean oceannc radix barnes lunc fft volrend waternsq raytrace fmm streamcluster fluidanimate vips bodytrack"
LOG="$W/size.log"
GLOG="$W/gem5.log"
PIDF="$W/.size.pid"
GPIDF="$W/.gem5.pid"
MODE="${1:-}"
trap 'rc=$?; [ "$rc" = 0 ] || echo "partB_server.sh $MODE: stopped, exit code $rc ($(date "+%F %T"))" >&2' EXIT

alive() { [ -f "$1" ] && kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null; }
die() { echo "ERROR: $*" >&2; exit 1; }
md5of() { md5sum < "$1" | cut -c1-8; }

# program -> family | dynamic binary (Pin) | static binary (gem5) | md5 of the
# dynamic | md5 of the static (first 8 hex digits, read on the server
# 2026-11-11: the binaries that passed QB at 4 threads). PB_INFO_FILE replaces
# the table (a rehearsal's stand-ins): lines "program|family|dyn|static|md5|md5".
info() {
  if [ -n "${PB_INFO_FILE:-}" ]; then awk -F'|' -v p="$1" '$1 == p { sub(/^[^|]*\|/, ""); print; f = 1 } END { exit !f }' "$PB_INFO_FILE"; return; fi
  case "$1" in
    ocean)         echo "splash|$SPLASH_APPS/ocean/contiguous_partitions/OCEAN|$HOME/splash-static/OCEAN|f89e2015|b1563bd2" ;;
    oceannc)       echo "splash|$HOME/heldout2_build/oceannc/OCEAN.dyn|$HOME/heldout2_static/OCEAN-NC|f7a8da02|ee0d1daf" ;;
    radix)         echo "splash|$HOME/b3_heldout_build/radix/codes/kernels/radix/RADIX.dyn|$HOME/splash-heldout/RADIX|c9454330|518a7bc9" ;;
    barnes)        echo "splash|$HOME/barnes_std_build/codes/apps/barnes/BARNES|$HOME/splash-static/BARNES|0a70bc1c|75e48ad7" ;;
    lunc)          echo "splash|$HOME/newbench_build/lunc/codes/kernels/lu/non_contiguous_blocks/LU.dyn|$HOME/splash-newbench/LU-NC|2df78c25|58d11531" ;;
    fft)           echo "splash|$HOME/newbench_build/fft/codes/kernels/fft/FFT.dyn|$HOME/splash-newbench/FFT|cda982a1|b640125e" ;;
    volrend)       echo "splash|$HOME/newbench_build/volrend/codes/apps/volrend/VOLREND.dyn|$HOME/splash-newbench/VOLREND|903d3a3f|95c1869f" ;;
    waternsq)      echo "splash|$HOME/b3_heldout_build/waternsq/codes/apps/water-nsquared/WATER-NSQUARED.dyn|$HOME/splash-heldout/WATER-NSQUARED|086a6d11|0d9e0ea6" ;;
    raytrace)      echo "splash|$HOME/newbench_build/raytrace/codes/apps/raytrace/RAYTRACE.dyn|$HOME/splash-newbench/RAYTRACE|254a07f7|e9f2d7aa" ;;
    fmm)           echo "splash|$HOME/b3_heldout_build/fmm/codes/apps/fmm/FMM.dyn|$HOME/splash-heldout/FMM|aed6b1f2|be09b0b2" ;;
    streamcluster) echo "sc|$HOME/newbench_build/streamcluster/src/streamcluster.dyn|$HOME/splash-newbench/streamcluster|3662e65f|c453a221" ;;
    fluidanimate)  echo "main1|$HOME/heldout2_build/fluidanimate/fluidanimate.dyn|$HOME/heldout2_static/fluidanimate|99251eac|5632b012" ;;
    vips)          echo "vips|$HOME/heldout2_build/vips/vips.dyn|$HOME/heldout2_static/vips|1cd422bd|afb7b014" ;;
    bodytrack)     echo "body|$HOME/heldout2_build/bodytrack/bodytrack.dyn|$HOME/heldout2_static/bodytrack|a01e66ca|59d390bc" ;;
    canneal)       echo "main1|-|$HOME/splash-static/CANNEAL|-|f675a03a" ;;   # gem5 only, 16 threads only
    *) return 1 ;;
  esac
}

# family, N -> threads the run creates | traced threads | gem5 CPUs | the
# worker stop's CPU slice (lo:hi, hi excluded) | the probe's reference thread
recipe() {
  local n="$2"
  case "$1" in
    splash) echo "$n|$(seq -s' ' 0 $((n - 1)))|$n|1:$n|1" ;;
    main1)  echo "$((n + 1))|$(seq -s' ' 1 "$n")|$((n + 1))|1:$((n + 1))|1" ;;
    sc)     echo "$((2 * n + 1))|$(seq -s' ' 1 "$n")|$((n + 1))|1:$((n + 1))|1" ;;
    body)   echo "$((n + 2))|$(seq -s' ' 1 "$n")|$((n + 2))|1:$((n + 1))|1" ;;
    vips)   echo "$((n + 3))|$(seq -s' ' 3 $((n + 2)))|$((n + 3))|3:$((n + 3))|3" ;;
    *) return 1 ;;
  esac
}

# program, N -> its ladder, smallest first: "label|arguments|stdin (gen: made
# by gen_stdin)|files the run needs in its directory (absolute paths)"
ladder() {
  local n="$2" x
  case "$1" in
    ocean|oceannc) for x in 514 1026 2050; do echo "n$x|-n$x -p$n -e1e-7 -r20000 -t28800||"; done ;;
    radix)         for x in 16777216 33554432 67108864 134217728; do echo "n$x|-p$n -n$x -r1024||"; done ;;
    barnes)        for x in 16384 65536 262144; do echo "b$x||gen|"; done ;;
    lunc)          for x in 1024 2048 4096; do echo "n$x|-n$x -p$n -b16||"; done ;;
    fft)           for x in 22 24 26; do echo "m$x|-m$x -p$n||"; done ;;
    volrend)       for x in 4 16 64 256; do echo "r$x|$n head $x||$NB/volrend/inputs/head.den"; done ;;
    waternsq)      for x in 8 16 32 64; do echo "s$x||gen|$HELDOUT_IN/random.in"; done ;;
    raytrace)      echo "a1|-p$n -m128 balls4.env||$NB/raytrace/inputs/balls4.env $NB/raytrace/inputs/balls4.geo"
                   for x in 2 4; do echo "a$x|-p$n -m128 -a$x balls4.env||$NB/raytrace/inputs/balls4.env $NB/raytrace/inputs/balls4.geo"; done ;;
    fmm)           for x in 16384 65536 262144; do echo "p$x||gen|"; done ;;
    streamcluster) for x in 16384 65536 262144; do echo "p$x|10 20 128 $x $x 1000 none out.txt $n||"; done ;;
    fluidanimate)  echo "simsmall|$n 5 in_35K.fluid out.fluid||$H2/fluidanimate/inputs/simsmall/in_35K.fluid"
                   echo "simmedium|$n 5 in_100K.fluid out.fluid||$H2/fluidanimate/inputs/simmedium/in_100K.fluid"
                   echo "simlarge|$n 5 in_300K.fluid out.fluid||$H2/fluidanimate/inputs/simlarge/in_300K.fluid"
                   echo "simlarge20|$n 20 in_300K.fluid out.fluid||$H2/fluidanimate/inputs/simlarge/in_300K.fluid" ;;
    vips)          echo "simsmall|--vips-concurrency=$n im_benchmark pomegranate_1600x1200.v output.v||$H2/vips/inputs/simsmall/pomegranate_1600x1200.v"
                   echo "simmedium|--vips-concurrency=$n im_benchmark vulture_2336x2336.v output.v||$H2/vips/inputs/simmedium/vulture_2336x2336.v"
                   echo "simlarge|--vips-concurrency=$n im_benchmark bigben_2662x5500.v output.v||$H2/vips/inputs/simlarge/bigben_2662x5500.v" ;;
    bodytrack)     echo "simmedium|sequenceB_2 4 2 2000 5 0 $n||$H2/bodytrack/inputs/simmedium/sequenceB_2"
                   echo "simlarge|sequenceB_4 4 4 4000 5 0 $n||$H2/bodytrack/inputs/simlarge/sequenceB_4" ;;
    *) return 1 ;;
  esac
}

# The three programs that take their thread count on stdin: the 4-thread
# input with two values changed, every other byte kept.
#   barnes    SPLASH-3's n16384-p4: line 2 bodies, line 12 processors
#   fmm       fmm.in: line 3 particles, line 5 processors
#   waternsq  waternsq.in: line 1's third number time steps, line 3's first
#             number processors
gen_stdin() {   # program N label
  case "$1" in
    barnes)   awk -v b="${3#b}" -v n="$2" 'NR == 2 { print b; next } NR == 12 { print n; next } { print }' "$BARNES_IN" ;;
    fmm)      awk -v b="${3#p}" -v n="$2" 'NR == 3 { print b; next } NR == 5 { print n; next } { print }' "$HELDOUT_IN/fmm.in" ;;
    waternsq) awk -v s="${3#s}" -v n="$2" 'NR == 1 { $3 = s; print; next } NR == 3 { $1 = n; print; next } { print }' "$HELDOUT_IN/waternsq.in" ;;
    *) return 1 ;;
  esac
}

setk() {   # program N
  P="$1"; N="$2"; KEY="${P}_$N"; KD="$W/$KEY"
  local i r
  i="$(info "$P")" || return 1
  IFS='|' read -r FAM DYN STA MD5D MD5S <<< "$i"
  r="$(recipe "$FAM" "$N")" || return 1
  IFS='|' read -r NTHR TIDS NCPU WSL REF <<< "$r"
  if [ "$N" = 16 ]; then LIMIT="$LIMIT16"; else LIMIT="$LIMIT8"; fi
  # thread 0's start in the trace: SPLASH-3 at its anchor (auto: its last
  # pthread_create); radix as at 4 threads, not cut -- its skip covers thread
  # 0's serial start; the PARSEC programs' thread 0 is not traced
  if [ "$FAM" = splash ] && [ "$P" != radix ]; then START0=auto; else START0=0; fi
}
keys() {   # programs... -> the keys in gem5's order: 8 threads first, then 16 (canneal at 16 only)
  local p
  for p in "$@"; do [ "$p" = canneal ] || echo "${p}_8"; done
  for p in "$@"; do echo "${p}_16"; done
}
all_keys() { keys $PROGS14 canneal; }

# ---------------------------------------------------------------- guards
guards() {   # [gem5]
  local bad=0 p i fam dyn sta md mds f a
  echo "== guards ($(date '+%F %T'))"
  for p in $PROGS14 canneal; do
    i="$(info "$p")" || { echo "   FAIL no table line for $p"; bad=$((bad + 1)); continue; }
    IFS='|' read -r fam dyn sta md mds <<< "$i"
    if [ "$dyn" != - ]; then
      if [ ! -x "$dyn" ]; then echo "   FAIL $p: no dynamic binary $dyn"; bad=$((bad + 1))
      elif [ "$(md5of "$dyn")" != "$md" ]; then echo "   FAIL $p: $dyn reads md5 $(md5of "$dyn"), the table has $md (rebuilt since QB?)"; bad=$((bad + 1)); fi
    fi
    if [ ! -x "$sta" ]; then echo "   FAIL $p: no static binary $sta"; bad=$((bad + 1))
    elif [ "$(md5of "$sta")" != "$mds" ]; then echo "   FAIL $p: $sta reads md5 $(md5of "$sta"), the table has $mds"; bad=$((bad + 1))
    elif ! file -b "$sta" | grep -q "statically linked"; then echo "   FAIL $p: $sta is not statically linked"; bad=$((bad + 1)); fi
  done
  [ "$bad" = 0 ] && echo "   ok   G1: the 14 dynamic and 15 static binaries are the ones in the table (md5)"
  a=$bad
  # G2: the stdin inputs have the shape gen_stdin edits, and at 4 threads it
  # gives the 4-thread input back byte for byte
  [ "$(wc -l < "$BARNES_IN" 2>/dev/null)" = 12 ] && [ "$(sed -n 2p "$BARNES_IN")" = 16384 ] && [ "$(sed -n 12p "$BARNES_IN")" = 4 ] \
    || { echo "   FAIL G2: $BARNES_IN is not 12 lines with 16384 bodies and 4 processors"; bad=$((bad + 1)); }
  [ "$(wc -l < "$HELDOUT_IN/fmm.in" 2>/dev/null)" = 9 ] && [ "$(sed -n 3p "$HELDOUT_IN/fmm.in")" = 16384 ] && [ "$(sed -n 5p "$HELDOUT_IN/fmm.in")" = 4 ] \
    || { echo "   FAIL G2: $HELDOUT_IN/fmm.in is not 9 lines with 16384 particles and 4 processors"; bad=$((bad + 1)); }
  [ "$(wc -l < "$HELDOUT_IN/waternsq.in" 2>/dev/null)" = 3 ] && [ "$(awk 'NR == 1 { print $2, $3 } NR == 3 { print $1 }' "$HELDOUT_IN/waternsq.in" | tr '\n' ' ')" = "512 8 4 " ] \
    || { echo "   FAIL G2: $HELDOUT_IN/waternsq.in is not 512 molecules, 8 steps, 4 processors"; bad=$((bad + 1)); }
  if [ "$bad" = "$a" ]; then
    gen_stdin barnes 4 b16384 | cmp -s - "$BARNES_IN" || { echo "   FAIL G2: gen_stdin barnes at 4 threads does not reproduce $BARNES_IN"; bad=$((bad + 1)); }
    gen_stdin fmm 4 p16384 | cmp -s - "$HELDOUT_IN/fmm.in" || { echo "   FAIL G2: gen_stdin fmm at 4 threads does not reproduce fmm.in"; bad=$((bad + 1)); }
    gen_stdin waternsq 4 s8 | cmp -s - "$HELDOUT_IN/waternsq.in" || { echo "   FAIL G2: gen_stdin waternsq at 4 threads does not reproduce waternsq.in"; bad=$((bad + 1)); }
    for f in 8 16; do   # SPLASH-3 ships barnes's 8- and 16-processor inputs
      [ ! -f "${BARNES_IN%4}$f" ] || gen_stdin barnes "$f" b16384 | cmp -s - "${BARNES_IN%4}$f" || { echo "   FAIL G2: gen_stdin barnes at $f threads differs from SPLASH-3's ${BARNES_IN%4}$f"; bad=$((bad + 1)); }
    done
  fi
  [ "$bad" = "$a" ] && echo "   ok   G2: the three stdin inputs have the expected shape; at 4 threads gen_stdin reproduces each byte for byte$([ -f "${BARNES_IN%4}16" ] && echo '; barnes at 8 and 16 equals SPLASH-3'"'"'s own files')"
  a=$bad
  # G3: every file a ladder names exists
  for p in $PROGS14; do
    while IFS='|' read -r _ _ _ f; do for i in $f; do [ -e "$i" ] || { echo "   FAIL G3: $p needs $i"; bad=$((bad + 1)); }; done; done < <(ladder "$p" 8)
  done
  [ -f "$NETS" ] || { echo "   FAIL G3: no netlist $NETS (canneal)"; bad=$((bad + 1)); }
  [ "$bad" = "$a" ] && echo "   ok   G3: every input file the ladders name exists"
  a=$bad
  [ -x "$PIN_ROOT/pin" ] || { echo "   FAIL G4: no Pin at $PIN_ROOT"; bad=$((bad + 1)); }
  if [ ! -f "$PROBE" ]; then echo "   FAIL G4: no probe $PROBE"; bad=$((bad + 1))
  elif [ "$(md5of "$PROBE")" != "$PROBE_MD5" ]; then echo "   FAIL G4: the probe reads md5 $(md5of "$PROBE"), expected $PROBE_MD5 (held-out set 2's)"; bad=$((bad + 1)); fi
  [ "$bad" = "$a" ] && echo "   ok   G4: Pin, and the probe held-out set 2 was sized with ($PROBE_MD5)"
  a=$bad
  f=$(df -BG --output=avail "$HOME" 2>/dev/null | tail -1 | tr -dc 0-9)
  [ "${f:-0}" -ge "$MIN_DISK_GB" ] || { echo "   FAIL G5: ${f:-?} GB free, under $MIN_DISK_GB"; bad=$((bad + 1)); }
  [ "$bad" = "$a" ] && echo "   ok   G5: $f GB free"
  if [ "${1:-}" = gem5 ]; then
    a=$bad
    [ -f "$RUNNER" ] && grep -q '^  go-pb)' "$RUNNER" || { echo "   FAIL G6: $RUNNER has no go-pb entry -- partB_all.sh uploads it"; bad=$((bad + 1)); }
    [ "$bad" = "$a" ] && echo "   ok   G6: the gem5 runner has the Part B entry"
  fi
  [ "$bad" = 0 ] || { echo "== guards: $bad FAILED -- nothing is started"; return 1; }
  echo "== guards pass"
}

# ---------------------------------------------------------------- sizing
# E3 for one probe file; prints the reason when it fails. "Created once": the
# number of thread starts equals the number of thread ids (Pin may give a
# later thread the id of one that has ended, so the ids alone cannot show a
# program that creates its workers again).
e3() {
  local f="$1" nt ns n why=""
  nt=$(awk '$1 == "THREADS" { print $2 }' "$f"); ns=$(grep -c '^START ' "$f")
  if [ "$FAM" = sc ]; then
    # streamcluster: N workers for the stream's chunk and, once they have
    # ended, N for the final clustering of the centres (2N + 1 thread starts
    # with main; N + 1 or 2N + 1 thread ids)
    [ "$ns" = "$NTHR" ] || why="$ns thread starts, the recipe has $NTHR"
    [ -n "$why" ] || [ "$nt" = $((N + 1)) ] || [ "$nt" = "$NTHR" ] || why="$nt thread ids, expected $((N + 1)) or $NTHR"
    [ -n "$why" ] || why=$(awk -v n="$N" '
      $1 == "START" && $2 != "t0" { s++; if (s == n + 1) second = NR }
      $1 == "END" && $2 != "t0" { e++; if (e == n) ended = NR }
      END { if (!second || !ended || ended > second) print "the second " n " workers start before the first " n " have ended" }' "$f")
  else
    [ "$nt" = "$NTHR" ] || why="$nt threads, the recipe has $NTHR"
    [ -n "$why" ] || [ "$ns" = "$NTHR" ] || why="$ns thread starts for $nt thread ids: a thread is created more than once"
  fi
  if [ -z "$why" ] && [ "$FAM" = vips ]; then
    n=$(awk '$1 == "TOTAL" && $2 != "t0" && $3 < 1000000 { n++ } END { print n + 0 }' "$f")
    [ "$n" = 2 ] || why="$n threads besides main execute under 1 M instructions, expected its 2 idle helpers: the workers are not the ones assumed"
  fi
  [ -z "$why" ] || { echo "$why"; return 1; }
}
# radix: the skip from one probe file -- "skip thread count" for the first
# pthread_cond_broadcast a traced thread makes (the release of the first
# barrier by its last arrival), the count rounded down to 10 M; "none" if no
# traced thread makes one
radix_skip() {
  awk -v tr="$TIDS" '
    BEGIN { n = split(tr, T, " "); for (k = 1; k <= n; k++) traced["t" T[k]] = 1 }
    $1 == "CALL" && $2 == "broadcast" && ($3 in traced) { printf "%d %s %d\n", int($5 / 10000000) * 10000000, $3, $5; f = 1; exit }
    END { if (!f) print "none" }' "$1"
}
# reported only (as held-out set 2): the reference worker from 50 M to 150 M
# past the skip, each thread's instructions there, the untraced threads' share
report_window() {   # probe file, skip, traced threads, reference thread
  awk -v tr="$3" -v ref="t$4" -v sk="$2" '
    /^SNAP/ { r = $3
      if (r >= sk + 50000000 && !A) { A = 1; for (i = 5; i <= NF; i += 2) s[$i] = $(i + 1) }
      if (r >= sk + 150000000 && !B) { B = 1; for (i = 5; i <= NF; i += 2) e[$i] = $(i + 1) } }
    END {
      if (!B) { printf "      native window: the reference %s never reaches %d M\n", ref, (sk + 150000000) / 1e6; exit }
      n = split(tr, T, " "); for (k = 1; k <= n; k++) traced["t" T[k]] = 1
      for (t in e) { d = e[t] - (t in s ? s[t] : 0); if (t in traced) { ts += d; if (!lo || d < lo) lo = d; if (d > hi) hi = d } else us += d }
      printf "      native window (%s %d-%d M; reported only): traced threads %.1f-%.1f M each; untraced/traced %.2f%%\n", ref, (sk + 50000000) / 1e6, (sk + 150000000) / 1e6, lo / 1e6, hi / 1e6, ts ? 100 * us / ts : 0 }' "$1"
}

size_key() {   # program N   (output: the key's size.log)
  setk "$1" "$2" || { echo "STOPPED: unknown program $1"; return 1; }
  mkdir -p "$KD"
  if [ -f "$KD/SIZED" ]; then echo "=== $KEY: sized already ($(cut -d'|' -f1,2 "$KD/CHOSEN")) -- skipped"; return 0; fi
  if [ -f "$KD/FAILED_E3" ]; then echo "=== $KEY: failed E3 already ($(cat "$KD/FAILED_E3")) -- skipped; remove the file to size it again"; return 0; fi
  echo "=== $(date '+%F %T')  $KEY: E3 $NTHR threads; E5 traced threads ($TIDS) >= $((MIN_INSTR / 1000000)) M each$([ "$P" = radix ] && echo ' past the skip')"
  echo "    dynamic $DYN ($MD5D)"
  local first="" rung label args sin files d in rc why skip low tid tids ref n min k=0 started=0 best="" bestmin="" bestskip=0 chosen="" e3why=""
  # at 16 threads the first rung is the one chosen at 8
  if [ "$N" = 16 ] && [ -f "$W/${P}_8/CHOSEN" ]; then first=$(cut -d'|' -f1 "$W/${P}_8/CHOSEN"); echo "    the ladder starts at $first, the rung chosen at 8 threads"; fi
  while IFS= read -r rung; do
    IFS='|' read -r label args sin files <<< "$rung"
    if [ -n "$first" ] && [ "$started" = 0 ] && [ "$label" != "$first" ]; then continue; fi
    started=1; k=$((k + 1))
    d="$KD/run_$label"
    rm -rf "$d"; mkdir -p "$d" || { echo "STOPPED: cannot create $d"; return 1; }
    for n in $files; do cp -rp "$n" "$d/" || { echo "STOPPED: could not copy $n"; return 1; }; done
    in=/dev/null
    if [ "$sin" = gen ]; then gen_stdin "$P" "$N" "$label" > "$d/$P.in" || { echo "STOPPED: gen_stdin failed"; return 1; }; in="$d/$P.in"; fi
    echo "   rung $label: $(basename "$DYN") $args$([ "$sin" = gen ] && echo " < $P.in ($(tr '\n' ' ' < "$in" | cut -c1-70))")"
    # shellcheck disable=SC2086 -- $args is the argument list
    ( cd "$d" && TMPDIR="$HOME/.build_tmp" timeout "$RUN_TIMEOUT" nice -n 19 "$PIN_ROOT/pin" -t "$PROBE" -o "$d/probe.txt" -ref "$REF" -- "$DYN" $args \
        < "$in" > "$d/out.txt" 2> "$d/err.txt" )
    rc=$?
    # keep the probe's file, the program's output and its stdin; drop the copied inputs and what the program wrote
    case "$d" in "$W"/*/run_*) find "$d" -mindepth 1 -maxdepth 1 ! -name probe.txt ! -name out.txt ! -name err.txt ! -name "$P.in" -exec rm -rf {} + ;; esac
    if [ "$rc" != 0 ] || ! grep -q '^THREADS ' "$d/probe.txt" 2>/dev/null; then
      echo "      did not run: exit $rc ($(grep -v '^\s*$' "$d/err.txt" 2>/dev/null | tail -1 | cut -c1-100)) -- rung skipped"; continue
    fi
    echo "      $(awk '$1 == "THREADS" { print $2 }' "$d/probe.txt") threads: $(awk '$1 == "TOTAL" { printf "%s %.0fM  ", $2, $3 / 1e6 }' "$d/probe.txt")"
    if ! why=$(e3 "$d/probe.txt"); then echo "      E3 fails: $why -- not chosen"; e3why="$why"; continue; fi
    skip=0
    if [ "$P" = radix ]; then
      read -r skip why n <<< "$(radix_skip "$d/probe.txt")"
      if [ "$skip" = none ]; then echo "      radix: no traced thread calls pthread_cond_broadcast (no first barrier seen) -- not chosen"; e3why="no first barrier seen"; continue; fi
      echo "      radix: the first barrier is released by $why at $n instructions (its pthread_cond_broadcast); skip $((skip / 1000000)) M"
    fi
    # the traced threads of THIS run: the recipe's, except vips's, which are
    # its threads that are not idle (the numbers follow the start order)
    tids="$TIDS"; ref="$REF"
    if [ "$FAM" = vips ]; then
      tids=$(awk '$1 == "TOTAL" && $2 != "t0" && $3 >= 1000000 { printf "%s ", substr($2, 2) }' "$d/probe.txt"); tids="${tids% }"
      ref="${tids%% *}"
      [ "$tids" = "$TIDS" ] || echo "      NOTE: the threads are not numbered in creation order in this run: the idle ones are $(awk '$1 == "TOTAL" && $2 != "t0" && $3 < 1000000 { printf "%s ", $2 }' "$d/probe.txt"), the workers $tids (the recipe: $TIDS)"
    fi
    low=""; min=""
    for tid in $tids; do
      n=$(awk -v t="t$tid" '$1 == "TOTAL" && $2 == t { print $3 }' "$d/probe.txt")
      [ -n "$n" ] || { low="$low $tid:absent"; n=0; }
      [ "$n" -ge $((skip + MIN_INSTR)) ] || low="$low $tid:$n"
      if [ -z "$min" ] || [ "$n" -lt "$min" ]; then min="$n"; fi
    done
    report_window "$d/probe.txt" "$skip" "$tids" "$ref"
    # every untraced thread's count; a NOTE when one of them (main aside) executes more than the least traced thread
    awk -v tr="$tids" -v min="$min" 'BEGIN { n = split(tr, T, " "); for (k = 1; k <= n; k++) traced["t" T[k]] = 1 }
      $1 == "TOTAL" && !($2 in traced) { line = line sprintf("%s %.1fM  ", $2, $3 / 1e6); if ($2 != "t0" && $3 + 0 > min + 0) odd = odd " " $2 }
      END { if (line != "") print "      untraced: " line
            if (odd != "") print "      NOTE: untraced" odd " execute(s) more than the least traced thread (" min "): if the threads are not numbered in creation order, the traced set is not the workers -- look before this key is used" }' "$d/probe.txt"
    best="$rung"; bestmin="$min"; bestskip="$skip"
    if [ -z "$low" ]; then chosen="$rung"; echo "      CHOSEN: E3 holds and every traced thread executes >= $(( (skip + MIN_INSTR) / 1000000 )) M (the least: $((min / 1000000)) M)"; break; fi
    echo "      not chosen (E5):$low"
  done < <(ladder "$P" "$N")
  if [ -z "$chosen" ] && [ -z "$best" ]; then
    echo "${e3why:-no rung ran}" > "$KD/FAILED_E3"
    echo "=== $(date '+%F %T')  $KEY: NOT SIZED -- no rung ran and met E3 (${e3why:-no rung ran}); reported, excluded; gem5 does not run it"
    return 0
  fi
  if [ -z "$chosen" ]; then
    chosen="$best"
    echo "$bestmin" > "$KD/BELOW"
    echo "      BELOW the size rule on every rung: the largest rung that ran and met E3 is taken (the least traced thread: $bestmin instructions)"
  fi
  IFS='|' read -r label args sin files <<< "$chosen"
  d="$KD/run_$label"
  sin=""
  if [ -f "$d/$P.in" ]; then cp -p "$d/$P.in" "$KD/$P.in"; sin="$KD/$P.in"; fi
  cp -p "$d/probe.txt" "$KD/probe_chosen.txt"
  echo "$label|$args|$sin|$files" > "$KD/CHOSEN"
  echo "$NTHR" > "$KD/NTHR"; echo "$NCPU" > "$KD/NCPU"; echo "$bestskip" > "$KD/SKIP"; echo "$bestmin" > "$KD/MIN"
  echo "dynamic $(md5sum < "$DYN" | cut -c1-32) $DYN" > "$KD/MD5"; echo "static $(md5sum < "$STA" | cut -c1-32) $STA" >> "$KD/MD5"
  # sync_server.sh PROGS: name | binary | arguments | stdin | files | threads traced | skip | thread 0's start
  echo "$KEY|$DYN|$args|$sin|$files|$TIDS|$bestskip|$START0" > "$KD/PROGS"
  # JOBS_SPEC: suffix | workload | cores | scaled | warm-up | measured | traces
  echo "$P$N|$P|$N|0|50000000|100000000|$KEY" > "$KD/JOBS"
  # gem5: key | static binary | arguments | stdin | files | CPUs | worker slice | time limit | low stop | high stop
  echo "$KEY|$STA|$args|$sin|$files|$NCPU|$WSL|$LIMIT|$((bestskip + 50000000))|$((bestskip + 150000000))" > "$KD/GEM5"
  touch "$KD/SIZED"
  echo "=== $(date '+%F %T')  $KEY: sized on $label$([ -f "$KD/BELOW" ] && echo ' (BELOW the size rule)'); gem5 $NCPU CPUs, worker stop cpu[$WSL] at $(( (bestskip + 50000000) / 1000000 )) M and $(( (bestskip + 150000000) / 1000000 )) M, limit $LIMIT"
}

# canneal at 16 threads: not sized (its traces exist: sync_mx/canneal16). Its
# gem5 line is the traced arguments on 17 CPUs.
canneal16() {
  setk canneal 16 || return 1
  mkdir -p "$KD"
  [ -f "$KD/SIZED" ] && return 0
  echo "traced|16 15000 2000 $NETS 128||" > "$KD/CHOSEN"
  echo "$NTHR" > "$KD/NTHR"; echo "$NCPU" > "$KD/NCPU"; echo 0 > "$KD/SKIP"
  echo "static $(md5sum < "$STA" | cut -c1-32) $STA" > "$KD/MD5"
  echo "$KEY|$STA|16 15000 2000 $NETS 128|||$NCPU|$WSL|$LIMIT|50000000|150000000" > "$KD/GEM5"
  touch "$KD/SIZED"
  echo "=== $(date '+%F %T')  $KEY: not sized (the arguments sync_mx/canneal16 was traced with); gem5 $NCPU CPUs, worker stop cpu[$WSL], limit $LIMIT"
}

collect() {   # the sized keys' lines for the trace chain, in one file each
  cat "$W"/*/PROGS > "$W/PROGS.tmp" 2>/dev/null && mv -f "$W/PROGS.tmp" "$W/PROGS"
  cat "$W"/*/JOBS > "$W/JOBS.tmp" 2>/dev/null && mv -f "$W/JOBS.tmp" "$W/JOBS"
}

pool() {   # N, at most PAR at once, programs...
  local n="$1" par="$2" p; shift 2
  for p in "$@"; do
    while [ "$(jobs -rp | wc -l)" -ge "$par" ]; do sleep 5; done
    mkdir -p "$W/${p}_$n"
    ( size_key "$p" "$n" >> "$W/${p}_$n/size.log" 2>&1; tail -1 "$W/${p}_$n/size.log" ) &
  done
  wait
}

pipeline() {   # programs...
  echo $$ > "$PIDF"
  echo "=== $(date '+%F %T')  Part B sizing: $*"
  echo "    probe $PROBE ($(md5of "$PROBE")); $((MIN_INSTR / 1000000)) M a traced thread; $SIZE_PAR8 keys at a time at 8 threads, $SIZE_PAR16 at 16"
  canneal16
  echo "--- 8 threads"
  pool 8 "$SIZE_PAR8" "$@"
  collect
  echo "--- 16 threads"
  pool 16 "$SIZE_PAR16" "$@"
  collect
  rm -f "$PIDF"
  echo "=== $(date '+%F %T')  sizing done: $(ls "$W"/*/SIZED 2>/dev/null | wc -l) keys sized ($(ls "$W"/*/BELOW 2>/dev/null | wc -l) below the size rule), $(ls "$W"/*/FAILED_E3 2>/dev/null | wc -l) not sized"
}

# ---------------------------------------------------------------- gem5
odir() { echo "$G/$1/l2_2MB_mi$(( $2 / 1000000 ))M/${1}c"; }   # key, stop
# ENDED (gem5 printed its exit line) | RUNNING | TIMEOUT (stopped by its time
# limit: the runner's limit.rc holds timeout's 124; never started again) |
# DEAD (gem5 exited by itself, or died with the machine: no limit.rc) | NEW
run_state() {   # key, stop
  local od; od="$(odir "$1" "$2")"
  if grep -q "Exiting @ tick" "$od/run.log" 2>/dev/null; then echo ENDED; return; fi
  if pgrep -u "$(id -u)" -f "[g]em5.opt --outdir=$od " > /dev/null 2>&1; then echo RUNNING; return; fi
  if [ "$(cat "$od/limit.rc" 2>/dev/null)" = 124 ]; then echo TIMEOUT; return; fi
  if [ -f "$W/$1/gem5_$(( $2 / 1000000 )).started" ] || [ -e "$od/run.log" ]; then echo DEAD; return; fi
  echo NEW
}
# gem5's own processes (the line of `timeout` holding the same words does not start with gem5's path)
running_now() { pgrep -u "$(id -u)" -f "^[^ ]*[g]em5\.opt --outdir=$G/" 2>/dev/null | wc -l; }

gem5_driver() {
  echo $$ > "$GPIDF"
  echo "=== $(date '+%F %T')  Part B gem5 driver: at most $GEM5_MAX runs at once, 8-thread keys first; $GEM5_MEM; limits $LIMIT8 / $LIMIT16"
  local key kd line sta args sin files ncpu wsl lim lo hi stop st pending m rc
  declare -A tried=() told=()
  while :; do
    pending=0
    while IFS= read -r key; do
      kd="$W/$key"
      if [ ! -f "$kd/SIZED" ]; then
        # not sized yet: wait for it only while the sizing is still working
        if [ ! -f "$kd/FAILED_E3" ] && alive "$PIDF"; then pending=1; fi
        continue
      fi
      IFS='|' read -r _ sta args sin files ncpu wsl lim lo hi < "$kd/GEM5"
      for stop in $lo $hi; do
        m=$((stop / 1000000))
        st=$(run_state "$key" "$stop")
        case "$st" in
          ENDED|RUNNING) continue ;;
          TIMEOUT) [ -n "${told[$key:$m]:-}" ] || { echo "$(date '+%F %T') TIMEOUT $key ${m}M: stopped by its $lim limit -- reported, not scored; never started again"; told[$key:$m]=1; }; continue ;;
          DEAD) if [ -n "${tried[$key:$m]:-}" ]; then
                  [ -n "${told[$key:$m]:-}" ] || { echo "$(date '+%F %T') DIED    $key ${m}M before its limit (exit $(cat "$(odir "$key" "$stop")/limit.rc" 2>/dev/null || echo '?: killed')): $(grep -v '^\s*$' "$(odir "$key" "$stop")/run.log" 2>/dev/null | tail -1 | cut -c1-120) -- a new 'gem5' command starts it again"; told[$key:$m]=1; }
                  continue
                fi ;;
        esac
        [ -z "${tried[$key:$m]:-}" ] || continue
        if [ "$(running_now)" -ge "$GEM5_MAX" ]; then pending=1; break 2; fi
        tried[$key:$m]=1
        OUT="$(dirname "$(odir "$key" "$stop")")" LLC_SIZE=2MB MEM_SIZE="$GEM5_MEM" MAXINSTS="" WORKER_MAXINSTS="$stop" PB_GEM5="$kd/GEM5" \
          bash "$RUNNER" go-pb > "$kd/gem5_$m.launch" 2>&1
        rc=$?
        if [ "$rc" = 0 ] && grep -q '^ *pid ' "$kd/gem5_$m.launch"; then
          date +%s > "$kd/gem5_$m.started"
          echo "$(date '+%F %T') START   $key ${m}M ($ncpu CPUs, cpu[$wsl] to $stop, limit $lim; $(grep -o 'pid [0-9]*' "$kd/gem5_$m.launch" | tail -1)); $(running_now) running"
        else
          echo "$(date '+%F %T') NOT STARTED $key ${m}M: $(grep -E 'ERROR|FAILS NATIVELY' "$kd/gem5_$m.launch" | head -1 | cut -c1-140) ($kd/gem5_$m.launch)"
          told[$key:$m]=1
        fi
      done
    done < <(all_keys)
    [ "$pending" = 1 ] || break
    sleep "$POLL_S"
  done
  rm -f "$GPIDF"
  echo "=== $(date '+%F %T')  gem5 driver done: every sized key's runs are started, ended or reported (status shows each)"
}

# ---------------------------------------------------------------- commands
start_size() {
  local progs="${*:-$PROGS14}" p
  for p in $progs; do [ "$p" != canneal ] && info "$p" > /dev/null || die "unknown program $p ($PROGS14)"; done
  if alive "$PIDF"; then echo "sizing is already running (pid $(cat "$PIDF")) -- 'status'"; return 0; fi
  mkdir -p "$W" "$HOME/.build_tmp"
  # shellcheck disable=SC2086
  ( cd "$W" || exit 1; setsid bash "$SELF" __size $progs >> "$LOG" 2>&1 < /dev/null & )
  sleep 2
  echo "sizing started for: $progs; log $LOG (each key: $W/<key>/size.log)"
}
start_gem5() {
  if alive "$GPIDF"; then echo "the gem5 driver is already running (pid $(cat "$GPIDF")) -- 'status'"; return 0; fi
  mkdir -p "$W" "$G"
  ( cd "$W" || exit 1; setsid bash "$SELF" __gem5 >> "$GLOG" 2>&1 < /dev/null & )
  sleep 2
  echo "gem5 driver started; log $GLOG"
}
# stop one of our two detached sessions (never a gem5 run: each is in a session of its own)
stop_one() {   # pid file, the mode its leader runs
  local sid inside
  alive "$1" || { echo "   $2: not running"; rm -f "$1"; return 0; }
  sid=$(cat "$1")
  [ "$(ps -o sid= -p "$sid" | tr -d ' ')" = "$sid" ] || { echo "   $2: pid $sid is not a session leader -- stopping nothing"; return 1; }
  ps -o args= -p "$sid" | grep -q "partB_server.sh $2" || { echo "   $2: pid $sid is not a partB_server.sh $2 -- stopping nothing"; return 1; }
  inside=$(ps -eo pid=,sid=,comm= | awk -v s="$sid" '$2 == s && $3 ~ /^gem5/ { print $1 }')
  [ -z "$inside" ] || { echo "   $2: gem5 pid(s) $inside are in its session -- stopping nothing"; return 1; }
  pkill -TERM -s "$sid"; sleep 2
  pgrep -s "$sid" > /dev/null && { pkill -KILL -s "$sid"; sleep 1; }
  pgrep -s "$sid" > /dev/null && { echo "   $2: session $sid did not stop"; return 1; }
  rm -f "$1"
  echo "   $2: stopped (session $sid)"
}

status() {
  local key kd st lo hi lim line s n=0 t=0 e=0 r=0 x=0
  echo "== Part B, $(date '+%F %T'): sizing $(alive "$PIDF" && echo running || echo 'not running'); gem5 driver $(alive "$GPIDF" && echo running || echo 'not running'); $(running_now) gem5 runs of Part B; load $(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null); $(df -h "$HOME" | tail -1 | awk '{print $4}') free"
  while IFS= read -r key; do
    kd="$W/$key"; t=$((t + 1))
    if [ -f "$kd/SIZED" ]; then
      n=$((n + 1))
      IFS='|' read -r _ _ _ _ _ _ _ lim lo hi < "$kd/GEM5"
      s=""
      for st in $lo $hi; do
        line=$(run_state "$key" "$st")
        case "$line" in ENDED) e=$((e + 1)); line="ENDED($(grep -m1 -oE 'because .*' "$(odir "$key" "$st")/run.log" | cut -c9-60))" ;; RUNNING) r=$((r + 1)) ;; TIMEOUT|DEAD) x=$((x + 1)) ;; esac
        s="$s $((st / 1000000))M:$line"
      done
      if [ -f "$kd/MIN" ]; then line="least $(printf '%5s' "$(( $(cat "$kd/MIN") / 1000000 ))") M"; else line="(not sized)  "; fi
      printf '   %-18s %-11s %s%s | gem5%s\n' "$key" "$(cut -d'|' -f1 "$kd/CHOSEN")" "$line" "$([ -f "$kd/BELOW" ] && echo ' BELOW' || echo '      ')" "$s"
    elif [ -f "$kd/FAILED_E3" ]; then printf '   %-18s NOT SIZED: %s\n' "$key" "$(cut -c1-90 "$kd/FAILED_E3")"
    elif [ -f "$kd/size.log" ]; then printf '   %-18s sizing: %s\n' "$key" "$(grep -E '^   rung|did not run|E3 fails|not chosen' "$kd/size.log" | tail -1 | sed 's/^ *//' | cut -c1-90)"
    else printf '   %-18s waiting\n' "$key"; fi
  done < <(all_keys)
  echo "== $n of $t keys sized; gem5 runs: $e ended, $r running, $x stopped or dead, of $((2 * n)); keys whose sizing log holds a NOTE: $(grep -l '^      NOTE' "$W"/*/size.log 2>/dev/null | wc -l)$(grep -l '^      NOTE' "$W"/*/size.log 2>/dev/null | sed 's#.*/\([^/]*\)/size.log# \1#' | tr -d '\n')"
  [ -f "$GLOG" ] && grep -E 'TIMEOUT|DIED|NOT STARTED' "$GLOG" | tail -8 | sed 's/^/   /'
  return 0
}

check() {   # each started run's config.ini, read back
  local key kd lo hi st c
  while IFS= read -r key; do
    kd="$W/$key"; [ -f "$kd/GEM5" ] || continue
    IFS='|' read -r _ _ _ _ _ _ _ _ lo hi < "$kd/GEM5"
    for st in $lo $hi; do
      c="$(odir "$key" "$st")/config.ini"
      [ -f "$c" ] || continue
      awk -v k="$key" -v m="$((st / 1000000))" '
        /^\[/ { sec = substr($0, 2, length($0) - 2); next }
        { key = $0; sub(/=.*/, "", key); v = substr($0, length(key) + 2) }
        sec ~ /^system\.cpu[0-9]+$/ && key == "max_insts_any_thread" { n = substr(sec, 11) + 0; stop[n] = v; if (n + 1 > ncpu) ncpu = n + 1 }
        sec == "system.ruby" && key == "randomization" { rnd = v }
        sec ~ /^system\.ruby\.l2_cntrl[0-9]+\.L2cache$/ && key == "size" { l2 = v }
        sec == "system" && key == "mem_ranges" { mem = v }
        sec ~ /^system\.cpu[0-9]+\.workload$/ && key == "cmd" && cmd == "" { cmd = v }
        sec ~ /^system\.cpu[0-9]+\.workload$/ && key == "input" && inp == "" { inp = v }
        END {
          lo = -1; for (i = 0; i < ncpu; i++) if (stop[i] + 0 > 0) { if (lo < 0) lo = i; hi = i; s = stop[i] }
          printf "   %-18s %4sM: %d CPUs, stop %s on cpu%d..cpu%d, L2 %.0f MB, memory %s, randomization %s\n      cmd %s%s\n", k, m, ncpu, s, lo, hi, l2 / 1048576, mem, rnd, cmd, (inp != "" && inp != "cin") ? "  < " inp : "" }' "$c"
    done
  done < <(all_keys)
}

plan() {
  local key p n rung
  echo "== Part B: the keys, in gem5's order (probe: $((MIN_INSTR / 1000000)) M a traced thread; gem5 $GEM5_MEM, limits $LIMIT8 / $LIMIT16)"
  while IFS= read -r key; do
    p="${key%_*}"; n="${key##*_}"
    setk "$p" "$n" || continue
    echo "-- $key ($FAM): creates $NTHR threads; traced $(echo "$TIDS" | awk '{ print $1 ".." $NF }'); gem5 $NCPU CPUs, worker stop cpu[$WSL]; limit $LIMIT; thread 0's start $START0"
    if [ "$p" = canneal ]; then echo "     (not sized) 16 15000 2000 $NETS 128"; continue; fi
    ladder "$p" "$n" | while IFS='|' read -r label args sin files; do
      echo "     $label: $(basename "$DYN") $args$([ "$sin" = gen ] && echo " < [$(gen_stdin "$p" "$n" "$label" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')]")$([ -n "$files" ] && echo "   files: $(for rung in $files; do basename "$rung"; done | tr '\n' ' ')")"
    done
  done < <(all_keys)
}

case "${1:-}" in
  plan) plan ;;
  guards) guards "${2:-}" ;;
  go) shift
      guards gem5 || exit 1
      start_size "$@"; start_gem5 ;;
  size) shift; guards || exit 1; start_size "$@" ;;
  gem5) guards gem5 || exit 1; start_gem5 ;;
  __size) shift; pipeline "$@" ;;
  __gem5) gem5_driver ;;
  status) status ;;
  check) check ;;
  stop) echo "== stopping the sizing pipeline and the gem5 driver (gem5 runs are left running)"
        stop_one "$PIDF" __size; stop_one "$GPIDF" __gem5 ;;
  *) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
