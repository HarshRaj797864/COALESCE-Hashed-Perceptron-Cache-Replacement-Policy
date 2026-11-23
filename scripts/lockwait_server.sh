#!/usr/bin/env bash
# Round 2, step 1 on the server (bench/policy_sanity/lock_wait_design_2026-11-06.md):
# the records-only counter of mutex acquires that waited. Builds in its own tree
# (~/sync_lc_build), state in ~/sync_lc, binary bin/champsim_lc_<md5>.
# bin/champsim, every trace, every scored run and every live chain are left as
# they are: the reruns write only new trees, results/phaseA_b3_lc_<old tree
# without phaseA_b3_>.
#
#   bash ~/lockwait_server.sh build    # ChampSim, guards, frozen copy, Q0 and Q0m against the g6 binary
#   bash ~/lockwait_server.sh chain    # detached: rerun round 1's 14 spans, then Q0-full
#   bash ~/lockwait_server.sh status | q0full | stop
#
# Each rerun is its scored run again: the traces and lengths read from the
# scored run's own log ("CPU n runs", "Warmup Instructions", "Simulation
# Instructions"), the config file its chain wrote, the same command. Q0-full
# then requires every line of each rerun to equal the scored log, apart from
# the wall clock and the new MUTEX WAITED ACQUIRES lines.
set -uo pipefail
SELF="$(readlink -f "$0")"
trap 'rc=$?; [ "$rc" = 0 ] || echo "lockwait_server.sh ${1:-}: stopped, exit code $rc ($(date "+%F %T"))" >&2' EXIT

R="${R:-$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy}"
S="$R/simulator"
CB="${CB:-$HOME/sync_lc_build}"
W="${W:-$HOME/sync_lc}"
REF="${REF:-$S/bin/champsim_g6_1e3060c1}"       # the binary every scored span ran
REF_MD5="${REF_MD5:-1e3060c1760b4b3b18e5728a9dfb75ed}"
NEWLINES='MUTEX WAITED ACQUIRES'                # the only lines this build adds
PAR="${PAR:-14}"                                 # reruns at once
DONE_MARKER="ChampSim completed all CPUs"
LOG="$W/driver.log"
PIDF="$W/.driver.pid"
MC="$CB/simulator/scripts/make_config.py"

# label | scored tree | <workload>_<n>core | the config its chain ran
SPANS="${SPANS:-fluidanimate|phaseA_b3_h2_fluidanimate4|fluidanimate_4core|$HOME/sync_h2/cfg/fluidanimate4_shared_lru.json
vips|phaseA_b3_h2_vips4|vips_4core|$HOME/sync_h2/cfg/vips4_shared_lru.json
oceannc|phaseA_b3_h2_oceannc4|oceannc_4core|$HOME/sync_h2/cfg/oceannc4_shared_lru.json
bodytrack|phaseA_b3_h2_bodytrack4|bodytrack_4core|$HOME/sync_h2/cfg/bodytrack4_shared_lru.json
barnesstd_window|phaseA_b3_g3_barnesstd4|barnes_4core|$HOME/sync_g6/cfg/barnesstd4_shared_lru.json
barnesstd_start|phaseA_b3_g3_barnesstd4_start|barnes_4core|$HOME/sync_g6/cfg/barnesstd4_start_shared_lru.json
barnesstd_force|phaseA_b3_g3_barnesstd4_force|barnes_4core|$HOME/sync_g6/cfg/barnesstd4_force_shared_lru.json
barnes256|phaseA_b3_g3_barnes4|barnes_4core|$HOME/sync_g6/cfg/barnes4_shared_lru.json
ocean4|phaseA_b3_g3_ocean4|ocean_4core|$HOME/sync_g6/cfg/ocean4_shared_lru.json
canneal4|phaseA_b3_g3_canneal4|canneal_4core|$HOME/sync_g6/cfg/canneal4_shared_lru.json
canneal8|phaseA_b3_g3_canneal8|canneal_8core|$HOME/sync_g6/cfg/canneal8_shared_lru.json
radix|phaseA_b3_g3_radix4|radix_4core|$HOME/sync_g6/cfg/radix4_shared_lru.json
fmm|phaseA_b3_g3_fmm4|fmm_4core|$HOME/sync_g6/cfg/fmm4_shared_lru.json
lunc|phaseA_b3_n2_lunc4|lunc_4core|$HOME/sync_nb/cfg/lunc4_shared_lru.json}"
NSPANS=$(echo "$SPANS" | grep -c '|')
Q0M_SPANS="${Q0M_SPANS:-barnesstd_force ocean4}"   # Q0m: lock-heavy and barrier-driven synchronised traces

alive() { [ -f "$1" ] && kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null; }
die() { echo "ERROR: $*" >&2; exit 1; }
bin_lc() { cat "$W/BIN" 2>/dev/null; }
field() { echo "$SPANS" | awk -F'|' -v n="$1" -v f="$2" '$1 == n { print $f }'; }   # label field
old_log() { echo "$S/results/$(field "$1" 2)/regime_shared/$(field "$1" 3)/lru/run.log"; }
new_tree() { local t; t=$(field "$1" 2); echo "phaseA_b3_lc_${t#phaseA_b3_}"; }
new_log() { echo "$S/results/$(new_tree "$1")/regime_shared/$(field "$1" 3)/lru/run.log"; }
is_done() { grep -q "$DONE_MARKER" "$(new_log "$1")" 2>/dev/null; }
count_done() { local n=0 l; for l in $(echo "$SPANS" | cut -d'|' -f1); do is_done "$l" && n=$((n + 1)); done; echo "$n"; }
clean() { sed -E 's/\(Simulation time: [^)]*\)//' "$1" | grep -v -E "$NEWLINES"; }

# the traces (core order), warm-up and length of a scored run, from its log; "MISSING:..." on a problem
log_settings() {   # log -> "wu si trace..."
  local f="$1" wu si n tr k
  grep -q "$DONE_MARKER" "$f" 2>/dev/null || { echo "MISSING:$f is not a complete run"; return 1; }
  wu=$(awk '/^Warmup Instructions:/ { print $3; exit }' "$f")
  si=$(awk '/^Simulation Instructions:/ { print $3; exit }' "$f")
  n=$(awk '/^Number of CPUs:/ { print $4; exit }' "$f")
  tr=$(awk '/^CPU [0-9]+ runs / { print $2, $4 }' "$f" | sort -n -k1,1 | awk '{ print $2 }')
  [ -n "$wu" ] && [ -n "$si" ] && [ -n "$n" ] || { echo "MISSING:$f has no lengths"; return 1; }
  [ "$(echo "$tr" | grep -c .)" = "$n" ] || { echo "MISSING:$f lists $(echo "$tr" | grep -c .) traces for $n CPUs"; return 1; }
  [ "$(awk '/^CPU [0-9]+ runs / { print $2 }' "$f" | sort -n | tr '\n' ' ')" = "$(seq -s ' ' 0 $((n - 1))) " ] || { echo "MISSING:$f: the CPUs listed are not 0..$((n - 1))"; return 1; }
  for k in $tr; do [ -s "$k" ] || { echo "MISSING:$k"; return 1; }; done
  echo "$wu $si $(echo "$tr" | tr '\n' ' ')"
}

build() {
  mkdir -p "$W"
  alive "$PIDF" && die "the lc chain is running -- 'status'"
  [ -d "$CB/simulator/src" ] || die "no sources in $CB/simulator -- scripts/lockwait_all.sh uploads them"
  [ -d "$S/vcpkg_installed" ] || die "no $S/vcpkg_installed to build against"
  [ -x "$REF" ] && [ "$(md5sum < "$REF" | cut -c1-32)" = "$REF_MD5" ] || die "no reference $REF with md5 $REF_MD5"
  [ -e "$CB/simulator/vcpkg_installed" ] || ln -s "$S/vcpkg_installed" "$CB/simulator/vcpkg_installed"
  echo "== ChampSim, in $CB/simulator (bin/champsim of the main tree is not touched)"
  ( cd "$CB/simulator" && rm -f absolute.options && make -j"$(nproc)" > "$W/build.log" 2>&1 ) || { tail -15 "$W/build.log"; die "the build failed ($W/build.log)"; }
  [ "$(strings -a "$CB/simulator/bin/champsim" | grep -c 'MUTEX WAITED ACQUIRES')" -gt 0 ] || die "the new binary does not print MUTEX WAITED ACQUIRES"
  echo "== the three policy guards, in that tree"
  local g m
  for g in check_include_path check_fill_hook check_signatures; do
    ( cd "$CB" && bash "bench/policy_sanity/$g.sh" ) > "$W/guard_$g.log" 2>&1 || { tail -5 "$W/guard_$g.log"; die "guard $g failed"; }
    echo "   $g: $(tail -1 "$W/guard_$g.log" | cut -c1-90)"
  done
  m=$(md5sum < "$CB/simulator/bin/champsim" | cut -c1-8)
  cp -p "$CB/simulator/bin/champsim" "$S/bin/champsim_lc_$m.tmp" && mv -f "$S/bin/champsim_lc_$m.tmp" "$S/bin/champsim_lc_$m"
  rm -f "$W/Q0_PASSED" "$W/Q0M_PASSED"
  echo "$S/bin/champsim_lc_$m" > "$W/BIN"
  echo "   frozen as bin/champsim_lc_$m"
  q0 || die "Q0 failed ($W/q0) -- nothing is launched"
  q0m || die "Q0m failed ($W/q0m) -- nothing is launched"
}

# a line a minute while background runs go (a long silence lost a connection before)
wait_runs() {   # dir total
  while [ -n "$(jobs -rp)" ]; do
    sleep 60
    [ -z "$(jobs -rp)" ] || echo "   $(date +%T) $(grep -l "$DONE_MARKER" "$1"/*.log 2>/dev/null | wc -l) of $2 runs done"
  done
  wait
}

# Q0: on canneal_4t (no sync records), 1 M + 2 M, LRU and Hawkeye, both
# regimes, levels 0 and 2, the new binary prints every line the g6 binary
# prints, and no SYNC or waited-acquire line.
q0() {
  local B Q="$W/q0" t="" i f pol rg lv c bad=0 n=0
  B=$(bin_lc); [ -x "$B" ] || die "no binary yet -- 'build'"
  rm -rf "$Q"; mkdir -p "$Q"
  for i in 1 2 3 4; do
    f="$S/traces/canneal_4t/canneal$i.champsimtrace.xz"; [ -f "$f" ] || f="$S/traces/canneal_4t/canneal$i.champsimtrace"
    [ -f "$f" ] || die "no canneal_4t trace $i for Q0"
    t="$t $f"
  done
  echo "== Q0: every line, against $(basename "$REF"), canneal 4c (no sync records), 1 M + 2 M"
  for pol in lru hawkeye; do for rg in shared private; do for lv in 0 2; do
    c="$Q/cfg_${pol}_${rg}_$lv.json"
    "$MC" --policy "$pol" --cores 4 --regime "$rg" --private-coherence "$lv" -o "$c" > /dev/null 2>&1 || die "make_config failed"
    # shellcheck disable=SC2086
    ( cd "$S" && nice -n 19 "$REF" --config "$c" --warmup-instructions 1000000 --simulation-instructions 2000000 $t > "$Q/${pol}_${rg}_${lv}_ref.log" 2>&1 ) &
    # shellcheck disable=SC2086
    ( cd "$S" && nice -n 19 "$B" --config "$c" --warmup-instructions 1000000 --simulation-instructions 2000000 $t > "$Q/${pol}_${rg}_${lv}_new.log" 2>&1 ) &
  done; done; done
  echo "   $(date +%T) 16 runs started (8 pairs); waiting"
  wait_runs "$Q" 16
  for f in "$Q"/*_ref.log; do
    n=$((n + 1))
    grep -q "$DONE_MARKER" "$f" && grep -q "$DONE_MARKER" "${f%_ref.log}_new.log" || { echo "   $(basename "${f%_ref.log}"): did not complete"; bad=$((bad + 1)); continue; }
    if grep -q -E 'SYNC|MUTEX' "${f%_ref.log}_new.log"; then echo "   $(basename "${f%_ref.log}"): a SYNC or MUTEX line on a trace without sync records"; bad=$((bad + 1)); continue; fi
    diff <(sed -E 's/\(Simulation time: [^)]*\)//' "$f") <(sed -E 's/\(Simulation time: [^)]*\)//' "${f%_ref.log}_new.log") > /dev/null \
      || { echo "   DIFFERS: $(basename "${f%_ref.log}")"; bad=$((bad + 1)); }
  done
  [ "$bad" = 0 ] || { echo "   Q0 FAILED: $bad of $n pairs differ"; return 1; }
  echo "   Q0 holds: $n of $n pairs print every line the same"
  echo "$(basename "$B")" > "$W/Q0_PASSED"
}

# Q0m: on synchronised traces with mutex records (the scored spans' own, 1 M +
# 2 M, their configs), every line equal apart from the new lines, which must be
# there, one per MUTEX ACQUIRES line.
q0m() {
  local B Q="$W/q0m" l s wu si tr bad=0 n=0 a b
  B=$(bin_lc); [ -x "$B" ] || die "no binary yet -- 'build'"
  rm -rf "$Q"; mkdir -p "$Q"
  echo "== Q0m: the synchronised traces of $Q0M_SPANS, against $(basename "$REF"), 1 M + 2 M"
  for l in $Q0M_SPANS; do
    s=$(log_settings "$(old_log "$l")") || die "Q0m: ${s#MISSING:}"
    read -r wu si tr <<< "$s"
    [ -s "$(field "$l" 4)" ] || die "Q0m: no config $(field "$l" 4)"
    # shellcheck disable=SC2086
    ( cd "$S" && nice -n 19 "$REF" --config "$(field "$l" 4)" --warmup-instructions 1000000 --simulation-instructions 2000000 $tr > "$Q/${l}_ref.log" 2>&1 ) &
    # shellcheck disable=SC2086
    ( cd "$S" && nice -n 19 "$B" --config "$(field "$l" 4)" --warmup-instructions 1000000 --simulation-instructions 2000000 $tr > "$Q/${l}_new.log" 2>&1 ) &
  done
  wait_runs "$Q" $(( 2 * $(echo $Q0M_SPANS | wc -w) ))
  for l in $Q0M_SPANS; do
    n=$((n + 1))
    grep -q "$DONE_MARKER" "$Q/${l}_ref.log" && grep -q "$DONE_MARKER" "$Q/${l}_new.log" || { echo "   $l: did not complete"; bad=$((bad + 1)); continue; }
    a=$(grep -c '^CPU [0-9]* MUTEX ACQUIRES:' "$Q/${l}_new.log"); b=$(grep -c '^CPU [0-9]* MUTEX WAITED ACQUIRES:' "$Q/${l}_new.log")
    [ "$a" -gt 0 ] && [ "$a" = "$b" ] || { echo "   $l: $b waited-acquire lines for $a MUTEX ACQUIRES lines"; bad=$((bad + 1)); continue; }
    diff <(clean "$Q/${l}_ref.log") <(clean "$Q/${l}_new.log") > /dev/null || { echo "   DIFFERS: $l"; bad=$((bad + 1)); }
  done
  [ "$bad" = 0 ] || { echo "   Q0m FAILED: $bad of $n differ"; return 1; }
  echo "   Q0m holds: $n of $n print every older line the same, and the new line once per core"
  echo "$(basename "$B")" > "$W/Q0M_PASSED"
}

span() {   # label: the scored run again, on the new binary
  local l="$1" B s wu si tr log cfg
  B=$(bin_lc); log=$(new_log "$l"); cfg=$(field "$l" 4)
  if is_done "$l"; then echo "$(date '+%F %T') SKIP  $l (complete)"; return 0; fi
  s=$(log_settings "$(old_log "$l")") || { echo "$(date '+%F %T') FAIL  $l -- ${s#MISSING:}"; return 0; }
  [ -s "$cfg" ] || { echo "$(date '+%F %T') FAIL  $l -- no config $cfg"; return 0; }
  read -r wu si tr <<< "$s"
  mkdir -p "$(dirname "$log")"
  { echo "binary $B $(md5sum < "$B" | cut -c1-32)"; echo "config $cfg $(md5sum < "$cfg" | cut -c1-32)"; echo "scored $(old_log "$l")"; echo "warmup $wu simulation $si"; echo "traces $tr"; } > "$(dirname "$log")/cmd.txt"
  echo "$(date '+%F %T') START $l ($wu + $si; $(echo $tr | wc -w) traces)"
  # shellcheck disable=SC2086
  ( cd "$S" && nice -n 19 "$B" --config "$cfg" --warmup-instructions "$wu" --simulation-instructions "$si" $tr > "$log" 2>&1 )
  echo "$(date '+%F %T') END   $l rc=$? $(grep -c "$DONE_MARKER" "$log") complete"
}

# Q0-full: every rerun against its scored run, line by line, apart from the wall
# clock and the new lines; the new lines must be there (one per MUTEX
# ACQUIRES line, or none where there is none).
q0full() {
  local l same=0 differ=0 waiting=0 a b
  for l in $(echo "$SPANS" | cut -d'|' -f1); do
    if ! is_done "$l"; then waiting=$((waiting + 1)); continue; fi
    a=$(grep -c '^CPU [0-9]* MUTEX ACQUIRES:' "$(new_log "$l")"); b=$(grep -c '^CPU [0-9]* MUTEX WAITED ACQUIRES:' "$(new_log "$l")")
    if [ "$a" = "$b" ] && diff <(clean "$(old_log "$l")") <(clean "$(new_log "$l")") > /dev/null; then
      same=$((same + 1))
    else
      differ=$((differ + 1)); echo "   Q0-full DIFFERS: $l (waited-acquire lines $b for $a)"
    fi
  done
  echo "   Q0-full: $same identical, $differ differ, $waiting not complete (of $NSPANS)"
}

chain_drive() {
  echo $$ > "$PIDF"
  echo "$(date '+%F %T') CHAIN START: $NSPANS reruns, $PAR at a time, $(basename "$(bin_lc)")"
  echo "$SPANS" | cut -d'|' -f1 | xargs -P "$PAR" -I{} bash "$SELF" __span {}
  echo "$(date '+%F %T') CHAIN END: $(count_done) of $NSPANS reruns complete"
  q0full | tee "$W/q0full.txt"
  rm -f "$PIDF"
}

case "${1:-}" in
  build) mkdir -p "$W"; build 2>&1 | tee -p "$W/build_run.log"; exit "${PIPESTATUS[0]}" ;;
  chain)
    mkdir -p "$W"
    alive "$PIDF" && { echo "the lc chain is running already (pid $(cat "$PIDF"))"; exit 0; }
    B=$(bin_lc); [ -x "$B" ] || die "no binary yet -- 'build'"
    [ "$(cat "$W/Q0_PASSED" 2>/dev/null)" = "$(basename "$B")" ] && [ "$(cat "$W/Q0M_PASSED" 2>/dev/null)" = "$(basename "$B")" ] \
      || die "$(basename "$B") has not passed Q0 and Q0m -- 'build'"
    for l in $(echo "$SPANS" | cut -d'|' -f1); do
      s=$(log_settings "$(old_log "$l")") || die "$l: ${s#MISSING:}"
      [ -s "$(field "$l" 4)" ] || die "$l: no config $(field "$l" 4)"
    done
    n0=0; [ -f "$LOG" ] && n0=$(wc -l < "$LOG")
    setsid bash "$SELF" __chain >> "$LOG" 2>&1 < /dev/null &
    disown 2>/dev/null; sleep 3
    if ! alive "$PIDF"; then
      # a chain whose reruns were all complete ends within the 3 s: that is not a
      # failure (found by the 2026-11-10 rehearsal, which called it one)
      if tail -n +$((n0 + 1)) "$LOG" | grep -q 'CHAIN END'; then
        tail -n +$((n0 + 1)) "$LOG" | tail -3
        echo "started: the chain has already ended (every rerun was complete); log $LOG"
        exit 0
      fi
      tail -5 "$LOG"; die "the chain stopped (above; $LOG)"
    fi
    echo "started: $NSPANS reruns, $PAR at a time, then Q0-full; log $LOG" ;;
  __chain) chain_drive ;;
  __span) span "$2" ;;
  q0full) q0full ;;
  status)
    echo "== lc (round 2 step 1, waited acquires): binary $(basename "$(bin_lc)" 2>/dev/null); Q0 $([ -n "$(bin_lc)" ] && [ "$(cat "$W/Q0_PASSED" 2>/dev/null)" = "$(basename "$(bin_lc)")" ] && echo passed || echo 'not passed'); Q0m $([ -n "$(bin_lc)" ] && [ "$(cat "$W/Q0M_PASSED" 2>/dev/null)" = "$(basename "$(bin_lc)")" ] && echo passed || echo 'not passed'); reruns $(count_done) of $NSPANS complete; chain $(alive "$PIDF" && echo alive || echo 'not running')"
    [ -f "$W/q0full.txt" ] && sed 's/^/   /' "$W/q0full.txt"
    [ -f "$LOG" ] && tail -n 4 "$LOG" | sed 's/^/   /'
    exit 0 ;;
  stop)
    if alive "$PIDF"; then
      sid=$(cat "$PIDF")
      [ "$(ps -o sid= -p "$sid" | tr -d ' ')" = "$sid" ] || die "pid $sid is not a session leader -- stopping nothing"
      ps -o args= -p "$sid" | grep -q 'lockwait_server.sh __chain' || die "pid $sid is not a lockwait_server.sh chain -- stopping nothing"
      pkill -TERM -s "$sid"; sleep 2
      rm -f "$PIDF"; echo "stopped the lc chain (session $sid)"
    else
      echo "the lc chain is not running"
    fi ;;
  *) echo "usage: $0 build | chain | status | q0full | stop"; exit 1 ;;
esac
