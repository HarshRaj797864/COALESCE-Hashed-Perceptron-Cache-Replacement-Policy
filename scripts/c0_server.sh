#!/usr/bin/env bash
# C0, the cost of an invalidation, on the server: build the binary in its own
# tree (bin/champsim is never touched), check it, and run the latency sweep.
# Pre-registered in bench/policy_sanity/c0_latency_design_2026-10-14.md.
#
#   bash ~/c0_server.sh build    # ~/c0_build -> bin/champsim_c0_<md5>; guards; Q0
#   bash ~/c0_server.sh go       # the 72 runs, detached ($JOBS at a time)
#   bash ~/c0_server.sh status
#   bash ~/c0_server.sh install-resume
#
# build: the sources scripts/c0_all.sh uploaded to ~/c0_build/simulator are
#   compiled there against the main tree's vcpkg_installed (a symlink made
#   here); the three policy guards run in that tree; the binary is copied to
#   the main tree as bin/champsim_c0_<first 8 of its md5> and named in
#   ~/c0/BIN. Q0: it and champsim_b3v4_69ebdcce, at latency 0, on canneal_4t
#   (1 M + 2 M; shared and private; levels 0 and 2; lru and hawkeye) must
#   print the same log, wall-clock lines aside. Nothing is launched otherwise.
# go: shared, fixed 2 MB, level 2, the 8 baselines, 50 M + 100 M, latency 20,
#   50 and 100 cycles: canneal 4c and 8c, ocean 4c -> results/phaseA_l2_c0_<L>c
#   (read by run_phase_a.sh rows and b3_rows.sh as they are).
set -uo pipefail
SELF="$(readlink -f "$0")"

R="${R:-$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy}"
S="$R/simulator"
CB="${CB:-$HOME/c0_build}"
W="${W:-$HOME/c0}"
REF="${REF:-$S/bin/champsim_b3v4_69ebdcce}"
JOBS="${JOBS:-8}"
WARMUP="${WARMUP:-50000000}"
SIM="${SIM:-100000000}"
LATENCIES="${LATENCIES:-20 50 100}"
CONFIGS="${CONFIGS:-canneal 4
canneal 8
ocean 4}"
POLICIES="${POLICIES:-lru random srrip drrip ship hawkeye mockingjay srrip_bias}"
DONE_MARKER="ChampSim completed all CPUs"
LOG="$W/driver.log"
PIDF="$W/.driver.pid"

alive() { [ -f "$1" ] && kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null; }
die() { echo "ERROR: $*" >&2; exit 1; }
bin_c0() { cat "$W/BIN" 2>/dev/null; }

resolve_trace() {
  if [ -f "$1.champsimtrace" ]; then echo "$1.champsimtrace"; return 0; fi
  if [ -f "$1.champsimtrace.xz" ]; then echo "$1.champsimtrace.xz"; return 0; fi
  return 1
}
traces_for() {   # wl n -- canneal: threads 1..n (thread 0 loads the netlist); ocean: all n
  local w="$1" n="$2" i f out="" first=0 last
  if [ "$w" = canneal ]; then first=1; last="$n"; else last=$((n - 1)); fi
  for ((i = first; i <= last; i++)); do
    f=$(resolve_trace "$S/traces/${w}_${n}t/$w$i") || { echo "MISSING:${w}_${n}t/$w$i"; return 1; }
    out="$out $f"
  done
  echo "${out# }"
}
tree_of() { echo "phaseA_l2_c0_$1c"; }
run_log() { echo "$S/results/$(tree_of "$4")/regime_shared/$2_$3core/$1/run.log"; }   # pol wl n lat
is_done() { grep -q "$DONE_MARKER" "$(run_log "$@")" 2>/dev/null; }
jobs_list() {   # pol wl n lat; 8-core first
  local lat wl n p
  for lat in $LATENCIES; do
    echo "$CONFIGS" | sort -k2,2nr | while read -r wl n; do for p in $POLICIES; do echo "$p $wl $n $lat"; done; done
  done | sort -k3,3nr -s
}
cfg_of() { echo "$W/cfg/$1_$2c_l$3.json"; }   # pol n lat

build() {
  mkdir -p "$W"
  [ -d "$CB/simulator/src" ] || die "no sources in $CB/simulator -- scripts/c0_all.sh uploads them"
  [ -d "$S/vcpkg_installed" ] || die "no $S/vcpkg_installed to build against"
  [ -e "$CB/simulator/vcpkg_installed" ] || ln -s "$S/vcpkg_installed" "$CB/simulator/vcpkg_installed"
  echo "== build in $CB/simulator (bin/champsim of the main tree is not touched)"
  ( cd "$CB/simulator" && rm -f absolute.options && make -j"$(nproc)" > "$W/build.log" 2>&1 ) || { tail -15 "$W/build.log"; die "the build failed ($W/build.log)"; }
  local n m
  n=$(strings -a "$CB/simulator/bin/champsim" | grep -c 'COHERENCE INVALIDATION LATENCY')
  [ "${n:-0}" -gt 0 ] || die "the new binary has no C0 latency"
  echo "== the three policy guards, in that tree"
  for g in check_include_path check_fill_hook check_signatures; do
    ( cd "$CB" && bash "bench/policy_sanity/$g.sh" ) > "$W/guard_$g.log" 2>&1 || { tail -5 "$W/guard_$g.log"; die "guard $g failed"; }
    echo "   $g: $(tail -1 "$W/guard_$g.log" | cut -c1-90)"
  done
  m=$(md5sum < "$CB/simulator/bin/champsim" | cut -c1-8)
  cp -p "$CB/simulator/bin/champsim" "$S/bin/champsim_c0_$m.tmp" && mv -f "$S/bin/champsim_c0_$m.tmp" "$S/bin/champsim_c0_$m"
  echo "$S/bin/champsim_c0_$m" > "$W/BIN"
  echo "   frozen as bin/champsim_c0_$m"
  q0
}

q0() {
  local B; B=$(bin_c0); [ -x "$B" ] || die "no C0 binary yet -- 'build'"
  [ -x "$REF" ] || die "no reference $REF"
  local Q="$W/q0" t c pol rg lv bad=0 n=0
  rm -rf "$Q"; mkdir -p "$Q"
  t=$(traces_for canneal 4) || die "${t#MISSING:}"
  echo "== Q0: latency 0 against $(basename "$REF"), canneal 4c, 1 M + 2 M"
  for pol in lru hawkeye; do for rg in shared private; do for lv in 0 2; do
    c="$Q/cfg_${pol}_${rg}_$lv.json"
    "$CB/simulator/scripts/make_config.py" --policy "$pol" --cores 4 --regime "$rg" --private-coherence "$lv" -o "$c" > /dev/null 2>&1 || die "make_config failed"
    # shellcheck disable=SC2086
    ( cd "$S" && nice -n 19 "$REF" --config "$c" --warmup-instructions 1000000 --simulation-instructions 2000000 $t > "$Q/${pol}_${rg}_${lv}_ref.log" 2>&1 ) &
    # shellcheck disable=SC2086
    ( cd "$S" && nice -n 19 "$B" --config "$c" --warmup-instructions 1000000 --simulation-instructions 2000000 $t > "$Q/${pol}_${rg}_${lv}_c0.log" 2>&1 ) &
  done; done; done
  wait
  for f in "$Q"/*_ref.log; do
    n=$((n + 1))
    grep -q "$DONE_MARKER" "$f" || { echo "   $(basename "$f"): did not complete"; bad=$((bad + 1)); continue; }
    # only the wall-clock text goes: the lines that carry it also carry cycle counts
    if ! diff <(sed -E 's/\(Simulation time: [^)]*\)//' "$f") <(sed -E 's/\(Simulation time: [^)]*\)//' "${f%_ref.log}_c0.log") > /dev/null; then
      echo "   DIFFERS: $(basename "${f%_ref.log}")"; bad=$((bad + 1))
    fi
  done
  [ "$bad" = 0 ] || die "Q0 failed: $bad of $n pairs differ -- nothing is launched"
  echo "   Q0 holds: $n of $n pairs print the same log"
  echo ok > "$W/Q0_PASSED"
}

make_cfg() {   # pol n lat
  local c; c=$(cfg_of "$@"); mkdir -p "$(dirname "$c")"
  "$CB/simulator/scripts/make_config.py" --policy "$1" --cores "$2" --regime shared --private-coherence 2 --coherence-latency "$3" -o "$c" > /dev/null 2>&1 || return 1
  grep -q "\"coherence_latency\": $3" "$c"
}

job() {   # pol wl n lat
  local p="$1" wl="$2" n="$3" lat="$4" log t B
  B=$(bin_c0); log=$(run_log "$p" "$wl" "$n" "$lat")
  if is_done "$p" "$wl" "$n" "$lat"; then echo "$(date '+%F %T') SKIP  $p $wl ${n}c L=$lat (complete)"; return 0; fi
  t=$(traces_for "$wl" "$n") || { echo "$(date '+%F %T') FAIL  $p $wl ${n}c L=$lat -- ${t#MISSING:}"; return 0; }
  make_cfg "$p" "$n" "$lat" || { echo "$(date '+%F %T') FAIL  $p $wl ${n}c L=$lat -- config"; return 0; }
  mkdir -p "$(dirname "$log")"
  echo "$(date '+%F %T') START $p $wl ${n}c L=$lat"
  # shellcheck disable=SC2086
  ( cd "$S" && nice -n 19 "$B" --config "$(cfg_of "$p" "$n" "$lat")" --warmup-instructions "$WARMUP" --simulation-instructions "$SIM" $t > "$log" 2>&1 )
  echo "$(date '+%F %T') END   $p $wl ${n}c L=$lat rc=$? $(grep -c "$DONE_MARKER" "$log") complete"
}
count_done() { local n=0 p wl c l; while read -r p wl c l; do is_done "$p" "$wl" "$c" "$l" && n=$((n + 1)); done < <(jobs_list); echo "$n"; }

driver() {
  echo $$ > "$PIDF"
  echo "$(date '+%F %T') QUEUE START ($(jobs_list | wc -l) jobs, $(count_done) complete, $JOBS at a time, $(basename "$(bin_c0)"))"
  jobs_list | xargs -P "$JOBS" -L 1 bash "$SELF" __job
  echo "$(date '+%F %T') QUEUE END: $(count_done) of $(jobs_list | wc -l) complete"
  rm -f "$PIDF"
}

case "${1:-}" in
  build) build ;;
  q0)    q0 ;;
  go)
    mkdir -p "$W"
    [ -f "$W/Q0_PASSED" ] || die "Q0 has not passed -- 'build' first"
    [ -x "$(bin_c0)" ] || die "no C0 binary"
    if alive "$PIDF"; then echo "already running (pid $(cat "$PIDF"))"; exit 0; fi
    while read -r p wl n lat; do make_cfg "$p" "$n" "$lat" || die "cannot make the config for $p ${n}c L=$lat"; traces_for "$wl" "$n" > /dev/null || die "traces missing for $wl ${n}c"; done < <(jobs_list)
    setsid bash "$SELF" __driver >> "$LOG" 2>&1 < /dev/null &
    disown 2>/dev/null; sleep 3
    alive "$PIDF" || [ "$(count_done)" = "$(jobs_list | wc -l)" ] || die "the driver did not start ($LOG)"
    echo "started: $(jobs_list | wc -l) jobs, $(count_done) complete, $JOBS at a time; log $LOG" ;;
  __driver) driver ;;
  __job)    shift; job "$@" ;;
  status)
    echo "== C0: $(count_done) of $(jobs_list | wc -l) complete; binary $(basename "$(bin_c0)" 2>/dev/null); Q0 $([ -f "$W/Q0_PASSED" ] && echo passed || echo 'not passed'); driver $(alive "$PIDF" && echo alive || echo 'not running')"
    [ -f "$LOG" ] && tail -4 "$LOG" | sed 's/^/   /' ;;
  install-resume)
    line="@reboot sleep 150; JOBS=$JOBS bash $HOME/c0_server.sh go >> $W/resume.log 2>&1"
    ( crontab -l 2>/dev/null | grep -v 'c0_server.sh'; echo "$line" ) | crontab - || die "crontab failed"
    echo "installed: $line" ;;
  *) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
