#!/usr/bin/env bash
# Part A on the server (bench/policy_sanity/upstream_equiv_design_2026-11-10.md):
# upstream ChampSim f9ed890e, built untouched, against ours with the extension
# off, on the 12 SPEC CPU2006 traces (single core; mixes at 4 and 8 cores),
# five policies, 50 M + 100 M a core, one config for both binaries.
# Builds in its own trees (~/partA_ours_build, ~/partA_up_build), state in
# ~/partA, binaries bin/champsim_partA_{ours,up}_<md5>, logs in
# results/partA/<name>_<policy>.<side>.log (+ <log>.bin, the binary that made it). bin/champsim, every other tree and every
# live chain are left as they are.
#
#   bash ~/partA_server.sh build    # both builds, guards (ours), frozen copies, the upstream source checksum, trace counts (E0)
#   bash ~/partA_server.sh chain    # detached: 185 runs, 8-core first (E1: 170; E2: 15)
#   bash ~/partA_server.sh e0_16    # amendment 3: the two 16-core mixes' configs (only once the chain has ended);
#                                   # the next 'chain' adds their 22 runs (E1 20, E2 2) and skips the 185 done
#   bash ~/partA_server.sh status | stop
set -uo pipefail
SELF="$(readlink -f "$0")"
trap 'rc=$?; [ "$rc" = 0 ] || echo "partA_server.sh ${1:-}: stopped, exit code $rc ($(date "+%F %T"))" >&2' EXIT

R="${R:-$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy}"
S="$R/simulator"
OB="${OB:-$HOME/partA_ours_build}"
UB="${UB:-$HOME/partA_up_build}"
W="${W:-$HOME/partA}"
OUT="${OUT:-$S/results/partA}"
UP_SRC_MD5="${UP_SRC_MD5:-b714419844d229ac00601653f842b1f0}"   # git archive f9ed890e, vcpkg excluded (laptop, 2026-11-10)
TRACE_DIR="${TRACE_DIR:-$S/traces/spec}"
TRACES="${TRACES:-410.bwaves-1963B 429.mcf-22B 433.milc-127B 437.leslie3d-232B 450.soplex-247B 459.GemsFDTD-1169B 462.libquantum-1343B 470.lbm-1274B 471.omnetpp-188B 473.astar-153B 482.sphinx3-1100B 483.xalancbmk-716B}"
POLS="lru srrip drrip ship random"
WU="${WU:-50000000}"
SI="${SI:-100000000}"
PAR="${PAR:-24}"
DONE_MARKER="ChampSim completed all CPUs"
LOG="$W/driver.log"
PIDF="$W/.driver.pid"
MC="$OB/simulator/scripts/make_config.py"

alive() { [ -f "$1" ] && kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null; }
die() { echo "ERROR: $*" >&2; exit 1; }
nth() { echo $TRACES | tr ' ' '\n' | sed -n "$1p"; }                 # 1-based
mix() { local a=$1 b=$2 k o=""; for k in $(seq "$a" "$b"); do o="$o $TRACE_DIR/$(nth "$k").champsimtrace.xz"; done; echo "$o"; }
src_md5() { ( cd "$1" && find . -type f -not -path './vcpkg*' | LC_ALL=C sort | xargs md5sum | md5sum | cut -c1-32 ); }

# name|cores|traces : the design's configurations (traces sorted by name; 4a/4b/4c = 1-4/5-8/9-12; 8a/8b = 1-8/5-12)
# amendment 3: 16a = 1-12 then 1-4, 16b = 1-12 then 9-12, once e0_16 has written their configs for these binaries
has16() { [ -f "$W/E0_16" ] && [ "$(cat "$W/E0_16" 2>/dev/null)" = "$(cat "$W/E0_PASSED" 2>/dev/null)" ]; }
configs() {
  if has16; then echo "16a|16|$(mix 1 12)$(mix 1 4)"; echo "16b|16|$(mix 1 12)$(mix 9 12)"; fi
  echo "8a|8|$(mix 1 8)"; echo "8b|8|$(mix 5 12)"
  echo "4a|4|$(mix 1 4)"; echo "4b|4|$(mix 5 8)"; echo "4c|4|$(mix 9 12)"
  local k; for k in $(seq 1 12); do echo "1c_$(nth "$k" | cut -d- -f1)|1|$(mix "$k" "$k")"; done
}
# name side cores policy traces -- E1 (up, ours; 170), then E2 (oursdefault, LRU, 1c and 4c; 15)
jobs_list() {
  local line n c t p
  configs | while IFS='|' read -r n c t; do
    for p in $POLS; do echo "$n up $c $p$t"; echo "$n ours $c $p$t"; done
  done
  configs | while IFS='|' read -r n c t; do [ "$c" = 8 ] || echo "$n oursdefault $c lru$t"; done
}
logname() { echo "$OUT/$1_$4.$2.log"; }      # name side cores policy
binof() { case $1 in up) cat "$W/BIN_UP" ;; *) cat "$W/BIN_OURS" ;; esac; }
# done = the log completed AND its sidecar <log>.bin names the binary now frozen for its side
# (a rebuild that gave another binary reruns everything rather than mixing binaries)
is_done() { grep -q "$DONE_MARKER" "$1" 2>/dev/null && [ "$(cat "$1.bin" 2>/dev/null)" = "$(basename "$(binof "$2")")" ]; }

build() {
  mkdir -p "$W" "$OUT"
  alive "$PIDF" && die "the partA chain is running -- 'status'"
  [ -d "$OB/simulator/src" ] || die "no sources in $OB -- scripts/partA_all.sh uploads them"
  [ -d "$UB/src" ] || die "no upstream sources in $UB -- scripts/partA_all.sh uploads them"
  [ -d "$S/vcpkg_installed" ] || die "no $S/vcpkg_installed to build against"
  local m u
  m=$(src_md5 "$UB")
  [ "$m" = "$UP_SRC_MD5" ] || die "the upstream tree's checksum is $m, not $UP_SRC_MD5 (git archive f9ed890e; a build needs a fresh upload: scripts/partA_all.sh)"
  echo "== upstream source checksum $m: f9ed890e as archived"
  for d in "$OB/simulator" "$UB"; do [ -e "$d/vcpkg_installed" ] || ln -s "$S/vcpkg_installed" "$d/vcpkg_installed"; done
  echo "== ours, in $OB/simulator"
  ( cd "$OB/simulator" && rm -f absolute.options && make -j"$(nproc)" > "$W/build_ours.log" 2>&1 ) || { tail -15 "$W/build_ours.log"; die "our build failed"; }
  grep -qa 'RMW LOADS AS RFO' "$OB/simulator/bin/champsim" || die "our binary has no rmw_as_rfo setting"
  local g
  for g in check_include_path check_fill_hook check_signatures; do
    ( cd "$OB" && bash "bench/policy_sanity/$g.sh" ) > "$W/guard_$g.log" 2>&1 || { tail -5 "$W/guard_$g.log"; die "guard $g failed"; }
    echo "   $g: $(tail -1 "$W/guard_$g.log" | cut -c1-90)"
  done
  echo "== upstream, in $UB (its own Makefile, untouched)"
  ( cd "$UB" && make -j"$(nproc)" > "$W/build_up.log" 2>&1 ) || { tail -15 "$W/build_up.log"; die "the upstream build failed"; }
  m=$(md5sum < "$OB/simulator/bin/champsim" | cut -c1-8); u=$(md5sum < "$UB/bin/champsim" | cut -c1-8)
  cp -p "$OB/simulator/bin/champsim" "$S/bin/champsim_partA_ours_$m.tmp" && mv -f "$S/bin/champsim_partA_ours_$m.tmp" "$S/bin/champsim_partA_ours_$m"
  cp -p "$UB/bin/champsim" "$S/bin/champsim_partA_up_$u.tmp" && mv -f "$S/bin/champsim_partA_up_$u.tmp" "$S/bin/champsim_partA_up_$u"
  echo "$S/bin/champsim_partA_ours_$m" > "$W/BIN_OURS"; echo "$S/bin/champsim_partA_up_$u" > "$W/BIN_UP"
  echo "   frozen: champsim_partA_ours_$m, champsim_partA_up_$u"
  rm -f "$W/E0_PASSED"
  e0 || die "E0 failed -- nothing is launched"
}

# E0: every trace holds at least WU + SI instructions (amendment 2); the configs are written.
# A trace is read only as far as WU + SI records (64 bytes each): tracelen.txt says "at least".
e0() {
  local t n need=$((WU + SI)) bad=0
  echo "== E0: the traces, counted up to $need records each"
  : > "$W/tracelen.txt"
  for t in $TRACES; do
    [ -s "$TRACE_DIR/$t.champsimtrace.xz" ] || { echo "   MISSING $t"; bad=$((bad + 1)); continue; }
    ( n=$(( $(xz -dc "$TRACE_DIR/$t.champsimtrace.xz" 2>/dev/null | head -c $((need * 64)) | wc -c) / 64 )); echo "$t $n" >> "$W/tracelen.txt" ) &
    while [ "$(jobs -rp | wc -l)" -ge 6 ]; do sleep 2; done
  done
  wait
  while read -r t n; do
    if [ "$n" -lt "$need" ]; then echo "   SHORT $t: $n records"; bad=$((bad + 1)); else echo "   $t: at least $n records"; fi
  done < <(sort "$W/tracelen.txt")
  [ "$(wc -l < "$W/tracelen.txt")" = "$(echo $TRACES | wc -w)" ] || { echo "   counted $(wc -l < "$W/tracelen.txt") of $(echo $TRACES | wc -w)"; bad=$((bad + 1)); }
  mkdir -p "$W/cfg"
  local c p
  for c in 1 4 8; do for p in $POLS; do
    python3 "$MC" --policy "$p" --cores "$c" --regime private --rmw-as-rfo 0 -o "$W/cfg/off_${c}_$p.json" > /dev/null || bad=$((bad + 1))
  done
    python3 "$MC" --policy lru --cores "$c" --regime private -o "$W/cfg/default_${c}_lru.json" > /dev/null || bad=$((bad + 1))
  done
  [ "$bad" = 0 ] || { echo "   E0 FAILED ($bad)"; return 1; }
  echo "   E0 holds: $(echo $TRACES | wc -w) traces long enough; $(ls "$W/cfg" | wc -l) configs"
  echo "$(basename "$(cat "$W/BIN_OURS")") $(basename "$(cat "$W/BIN_UP")")" > "$W/E0_PASSED"
}

# amendment 3: the 16-core configs, written by the frozen tree's make_config.py as E0 wrote the others.
# The traces are E0's 12, already counted; E0_16 records the binaries it was written for.
e0_16() {
  alive "$PIDF" && die "the partA chain is running -- the 16-core runs are added after it ends (amendment 3)"
  [ -f "$W/E0_PASSED" ] && [ "$(cat "$W/E0_PASSED")" = "$(basename "$(cat "$W/BIN_OURS" 2>/dev/null)") $(basename "$(cat "$W/BIN_UP" 2>/dev/null)")" ] \
    || die "the frozen binaries have not passed E0 -- 'build'"
  local t n need=$((WU + SI)) bad=0 p d a
  if ! has16; then   # the first 185 runs must all be complete (a chain cut short is relaunched with 'chain' first)
    d=$(count_done); a=$(jobs_list | wc -l)
    [ "$d" = "$a" ] || die "$d of $a runs are complete -- the 16-core runs are added once all of them are ('chain' resumes the rest)"
  fi
  for t in $TRACES; do
    n=$(awk -v t="$t" '$1 == t { print $2 }' "$W/tracelen.txt" 2>/dev/null)
    [ -n "$n" ] && [ "$n" -ge "$need" ] || { echo "   $t: E0 did not count it at least $need records"; bad=$((bad + 1)); }
  done
  for p in $POLS; do
    python3 "$MC" --policy "$p" --cores 16 --regime private --rmw-as-rfo 0 -o "$W/cfg/off_16_$p.json" > /dev/null || bad=$((bad + 1))
  done
  python3 "$MC" --policy lru --cores 16 --regime private -o "$W/cfg/default_16_lru.json" > /dev/null || bad=$((bad + 1))
  [ "$bad" = 0 ] || { rm -f "$W/E0_16"; echo "   E0 (16 cores) FAILED ($bad)"; return 1; }
  cp "$W/E0_PASSED" "$W/E0_16"
  echo "   E0 (16 cores) holds: E0's 12 traces counted; 6 configs written; mixes 16a, 16b added ($(jobs_list | wc -l) runs in all)"
}

one() {   # name side cores policy traces...
  local n=$1 sd=$2 c=$3 p=$4; shift 4
  local B cfg log
  log=$(logname "$n" "$sd" "$c" "$p")
  if is_done "$log" "$sd"; then echo "$(date '+%F %T') SKIP  $n $p $sd"; return 0; fi
  B=$(binof "$sd")
  case $sd in
    up|ours) cfg="$W/cfg/off_${c}_$p.json" ;;
    oursdefault) cfg="$W/cfg/default_${c}_$p.json" ;;
  esac
  rm -f "$log.bin"
  echo "$(date '+%F %T') START $n $p $sd"
  # shellcheck disable=SC2068
  ( cd "$S" && nice -n 19 "$B" --config "$cfg" --warmup-instructions "$WU" --simulation-instructions "$SI" $@ > "$log" 2>&1 )
  local rc=$?
  basename "$B" > "$log.bin"
  echo "$(date '+%F %T') END   $n $p $sd rc=$rc $(grep -c "$DONE_MARKER" "$log") complete"
}

count_done() { local n=0; while read -r a b c d _; do is_done "$(logname "$a" "$b" "$c" "$d")" "$b" && n=$((n + 1)); done < <(jobs_list); echo "$n"; }

chain_drive() {
  echo $$ > "$PIDF"
  echo "$(date '+%F %T') CHAIN START: $(jobs_list | wc -l) runs, $PAR at a time, $(basename "$(cat "$W/BIN_OURS")") vs $(basename "$(cat "$W/BIN_UP")")"
  jobs_list | xargs -P "$PAR" -L 1 bash "$SELF" __one
  echo "$(date '+%F %T') CHAIN END: $(count_done) of $(jobs_list | wc -l) runs complete"
  rm -f "$PIDF"
}

case "${1:-}" in
  build) mkdir -p "$W"; build 2>&1 | tee -p "$W/build_run.log"; exit "${PIPESTATUS[0]}" ;;
  e0_16) e0_16 2>&1 | tee -a "$W/build_run.log"; exit "${PIPESTATUS[0]}" ;;
  chain)
    mkdir -p "$W" "$OUT"
    alive "$PIDF" && { echo "the partA chain is running already (pid $(cat "$PIDF"))"; exit 0; }
    [ "$(cat "$W/E0_PASSED" 2>/dev/null)" = "$(basename "$(cat "$W/BIN_OURS" 2>/dev/null)") $(basename "$(cat "$W/BIN_UP" 2>/dev/null)")" ] \
      || die "the frozen binaries have not passed E0 -- 'build'"
    n0=0; [ -f "$LOG" ] && n0=$(wc -l < "$LOG")
    setsid bash "$SELF" __chain >> "$LOG" 2>&1 < /dev/null &
    disown 2>/dev/null; sleep 3
    if ! alive "$PIDF"; then
      if tail -n +$((n0 + 1)) "$LOG" | grep -q 'CHAIN END'; then
        tail -n +$((n0 + 1)) "$LOG" | tail -2
        echo "started: the chain has already ended (every run was complete); log $LOG"; exit 0
      fi
      tail -5 "$LOG"; die "the chain stopped (above; $LOG)"
    fi
    echo "started: $(jobs_list | wc -l) runs, $PAR at a time; log $LOG" ;;
  __chain) chain_drive ;;
  __one) shift; one "$@" ;;
  status)
    echo "== partA (upstream equivalence): ours $(basename "$(cat "$W/BIN_OURS" 2>/dev/null)" 2>/dev/null), upstream $(basename "$(cat "$W/BIN_UP" 2>/dev/null)" 2>/dev/null); E0 $([ -f "$W/E0_PASSED" ] && echo passed || echo 'not passed'); runs $(count_done) of $(jobs_list | wc -l) complete; chain $(alive "$PIDF" && echo alive || echo 'not running')"
    [ -f "$LOG" ] && tail -n 4 "$LOG" | sed 's/^/   /'
    exit 0 ;;
  stop)
    if alive "$PIDF"; then
      sid=$(cat "$PIDF")
      [ "$(ps -o sid= -p "$sid" | tr -d ' ')" = "$sid" ] || die "pid $sid is not a session leader -- stopping nothing"
      ps -o args= -p "$sid" | grep -q 'partA_server.sh __chain' || die "pid $sid is not a partA_server.sh chain -- stopping nothing"
      pkill -TERM -s "$sid"; sleep 2; rm -f "$PIDF"; echo "stopped the partA chain (session $sid)"
    else
      echo "the partA chain is not running"
    fi ;;
  *) echo "usage: $0 build | e0_16 | chain | status | stop"; exit 1 ;;
esac
