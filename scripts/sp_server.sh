#!/usr/bin/env bash
# The published SRRIP row (bench/policy_sanity/srrip_pub_design_2026-11-18.md), on the server:
# replacement/srrip_pub (upstream srrip + the published insertion, RRPV 2) on the 19 step-5
# SRRIP jobs. Builds in its own tree (~/sp_build), state in ~/sp, binary bin/champsim_sp_<md5>.
# Each run: its step-5 config (~/sync_pol/cfg/<suffix>_<regime>_srrip.json) with LLC.replacement
# srrip -> srrip_pub and nothing else, its window and its traces (the reference's "CPU n runs"
# lines). Output: results/phaseA_b3_sp_<suffix>/regime_<r>/<wl>_<n>core/srrip_pub/run.log.
# Writes only under ~/sp, ~/sp_build, bin/champsim_sp_* and those trees.
#
#   bash ~/sp_server.sh check    # build, guards, frozen copy, QS0 (no run starts)
#   bash ~/sp_server.sh chain    # detached: the 19 runs, PAR at a time, in JOBS order (16 cores first), QS1 each (owner's word)
#   bash ~/sp_server.sh status | list | stop
#
# QS0: three step-5 SRRIP configs at 1 M + 2 M on the new binary (upstream srrip) and on
# champsim_g6_1e3060c1: every line equal once the lines added since g6 are removed from the
# new log; the g6 log holds none of them. QS1: complete; one SRRIP_PUB FILLS line, all fills
# at RRPV 2 (and > 0); unexplained view-order violations 0.
set -uo pipefail
SELF="$(readlink -f "$0")"
trap 'rc=$?; [ "$rc" = 0 ] || echo "sp_server.sh ${1:-}: stopped, exit code $rc ($(date "+%F %T"))" >&2' EXIT

R="${R:-$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy}"
S="$R/simulator"
CB="${CB:-$HOME/sp_build}"
W="${W:-$HOME/sp}"
POL_W="${POL_W:-$HOME/sync_pol}"
JOBS_MD5="${JOBS_MD5:-ec5c7410ef205d94aac3c6e0cc649611}"
G6="${G6:-$S/bin/champsim_g6_1e3060c1}"
G6_MD5="${G6_MD5:-1e3060c1760b4b3b18e5728a9dfb75ed}"
NEWPAT='MUTEX WAITED ACQUIRES|LOCK-WORD REQUESTS|GEM5-RULE OWNER EVENTS'   # printed since g6
PAR="${PAR:-7}"
MIN_FREE_GB="${MIN_FREE_GB:-20}"
QW="${QW:-1000000}"; QL="${QL:-2000000}"
QS0_JOBS="${QS0_JOBS:-canneal4 shared
ocean4_scaled shared
barnesstd4 private}"
DONE_MARKER="ChampSim completed all CPUs"
REF_TREE=phaseA_b3_p2_
NEW_TREE=phaseA_b3_sp_
LOG="$W/driver.log"
PIDF="$W/.driver.pid"

alive() { [ -f "$1" ] && kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null; }
die() { echo "ERROR: $*" >&2; exit 1; }
free_gb() { df -BG --output=avail "$S" | tail -1 | tr -dc 0-9; }
cl() { echo "$(date '+%F %T') $*"; }
bin_sp() { cat "$W/BIN" 2>/dev/null; }
clean() { sed -E 's/\(Simulation time: [^)]*\)//' "$1"; }
passed() { [ -n "$(bin_sp)" ] && [ "$(cat "$W/$1" 2>/dev/null)" = "$(basename "$(bin_sp)")" ]; }

# a JOBS line: suffix|wl|cores|scaled|warmup|sim|traces|policy|regime[|mshr]
f() { echo "$1" | cut -d'|' -f"$2"; }
lab() { echo "$(f "$1" 1) $(f "$1" 9) srrip_pub"; }
ref_log() { echo "$S/results/$REF_TREE$(f "$1" 1)/regime_$(f "$1" 9)/$(f "$1" 2)_$(f "$1" 3)core/srrip/run.log"; }
new_log() { echo "$S/results/$NEW_TREE$(f "$1" 1)/regime_$(f "$1" 9)/$(f "$1" 2)_$(f "$1" 3)core/srrip_pub/run.log"; }
ref_cfg() { echo "$POL_W/cfg/$(f "$1" 1)_$(f "$1" 9)_srrip.json"; }
new_cfg() { echo "$W/cfg/$(f "$1" 1)_$(f "$1" 9)_srrip_pub.json"; }
ref_done() { grep -q "$DONE_MARKER" "$(ref_log "$1")" 2>/dev/null; }
is_done() { local l; l=$(new_log "$1"); grep -q "$DONE_MARKER" "$l" 2>/dev/null && [ "$(cat "$l.bin" 2>/dev/null)" = "$(basename "$(bin_sp)")" ]; }
jobs_list() { awk -F'|' '$8 == "srrip"' "$POL_W/JOBS"; }
traces_of() { awk '/^CPU [0-9]+ runs / { print $2, $4 }' "$1" | sort -n -k1,1 | awk '{ print $2 }'; }

build() {
  mkdir -p "$W"
  alive "$PIDF" && die "the sp chain is running -- 'status'"
  [ -d "$CB/simulator/src" ] || die "no sources in $CB/simulator -- scripts/sp_all.sh uploads them"
  [ -d "$S/vcpkg_installed" ] || die "no $S/vcpkg_installed to build against"
  [ -x "$G6" ] && [ "$(md5sum < "$G6" | cut -c1-32)" = "$G6_MD5" ] || die "no $G6 with md5 $G6_MD5"
  [ -e "$CB/simulator/vcpkg_installed" ] || ln -s "$S/vcpkg_installed" "$CB/simulator/vcpkg_installed"
  echo "== ChampSim, in $CB/simulator (bin/champsim of the main tree is not touched)"
  ( cd "$CB/simulator" && rm -f absolute.options && make -j"$(nproc)" > "$W/build.log" 2>&1 ) || { tail -15 "$W/build.log"; die "the build failed ($W/build.log)"; }
  [ "$(strings -a "$CB/simulator/bin/champsim" | grep -c 'SRRIP_PUB FILLS')" -gt 0 ] || die "the new binary has no srrip_pub"
  echo "== the three policy guards, in that tree"
  local g m
  for g in check_include_path check_fill_hook check_signatures; do
    ( cd "$CB" && bash "bench/policy_sanity/$g.sh" ) > "$W/guard_$g.log" 2>&1 || { tail -5 "$W/guard_$g.log"; die "guard $g failed"; }
    echo "   $g: $(tail -1 "$W/guard_$g.log" | cut -c1-90)"
  done
  m=$(md5sum < "$CB/simulator/bin/champsim" | cut -c1-8)
  cp -p "$CB/simulator/bin/champsim" "$S/bin/champsim_sp_$m.tmp" && mv -f "$S/bin/champsim_sp_$m.tmp" "$S/bin/champsim_sp_$m"
  rm -f "$W/QS0_PASSED"
  echo "$S/bin/champsim_sp_$m" > "$W/BIN"
  echo "   frozen as bin/champsim_sp_$m"
}

guards() {
  [ -s "$POL_W/JOBS" ] && [ "$(md5sum < "$POL_W/JOBS" | cut -c1-32)" = "$JOBS_MD5" ] || die "$POL_W/JOBS is not md5 $JOBS_MD5 (step 5's)"
  [ "$(jobs_list | wc -l)" = 19 ] || die "step 5's JOBS has $(jobs_list | wc -l) srrip jobs, not 19"
  local x n=0 nr=0 nc=0
  while read -r x; do
    n=$((n + 1)); ref_done "$x" && nr=$((nr + 1)); [ -s "$(ref_cfg "$x")" ] && nc=$((nc + 1))
  done < <(jobs_list)
  [ "$nr" = "$n" ] && [ "$nc" = "$n" ] || die "references complete $nr, configs $nc, of $n"
  [ "$(free_gb)" -ge "$MIN_FREE_GB" ] || die "under $MIN_FREE_GB GB free ($(free_gb))"
  echo "   guards: JOBS = step 5's (md5 ${JOBS_MD5:0:8}); $n srrip jobs, references complete, configs present; $(free_gb) GB free"
}

# the reference's config with LLC.replacement srrip -> srrip_pub, nothing else
make_cfg() {   # src dst
  python3 - "$1" "$2" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
if c.get('LLC', {}).get('replacement') != 'srrip':
    sys.exit(f'{sys.argv[1]}: LLC.replacement is {c.get("LLC", {}).get("replacement")!r}, not srrip')
n = json.loads(json.dumps(c))
n['LLC']['replacement'] = 'srrip_pub'
m = json.loads(json.dumps(n)); m['LLC']['replacement'] = 'srrip'
assert m == c
json.dump(n, open(sys.argv[2], 'w'), indent=2)
PY
}

qs0() {
  local B Q="$W/qs0" sfx rg x ref cfg bad=0 n=0 tr
  B=$(bin_sp); [ -x "$B" ] || die "no binary yet"
  rm -rf "$Q"; mkdir -p "$Q"
  echo "== QS0: $(basename "$B") (upstream srrip) against $(basename "$G6"), three step-5 SRRIP configs, $QW + $QL"
  while read -r sfx rg; do
    x=$(jobs_list | awk -F'|' -v s="$sfx" -v r="$rg" '$1 == s && $9 == r'); [ -n "$x" ] || die "QS0: no srrip job $sfx $rg"
    ref=$(ref_log "$x"); cfg=$(ref_cfg "$x")
    tr=$(traces_of "$ref" | tr '\n' ' ')
    # shellcheck disable=SC2086
    ( cd "$S" && env -u COHERENCE_EVENT_LOG -u COHERENCE_POSITION_BINS nice -n 19 "$G6" --config "$cfg" --warmup-instructions "$QW" --simulation-instructions "$QL" $tr > "$Q/${sfx}_${rg}_g6.log" 2>&1 ) &
    # shellcheck disable=SC2086
    ( cd "$S" && env -u COHERENCE_EVENT_LOG -u COHERENCE_POSITION_BINS nice -n 19 "$B" --config "$cfg" --warmup-instructions "$QW" --simulation-instructions "$QL" $tr > "$Q/${sfx}_${rg}_new.log" 2>&1 ) &
  done <<< "$QS0_JOBS"
  wait
  while read -r sfx rg; do
    n=$((n + 1)); local a="$Q/${sfx}_${rg}_g6.log" b="$Q/${sfx}_${rg}_new.log"
    grep -q "$DONE_MARKER" "$a" && grep -q "$DONE_MARKER" "$b" || { echo "   $sfx $rg: did not complete"; bad=$((bad + 1)); continue; }
    if grep -q -E "$NEWPAT" "$a"; then echo "   $sfx $rg: the g6 log holds a line of the new kinds"; bad=$((bad + 1)); continue; fi
    diff <(clean "$a") <(clean "$b" | grep -v -E "$NEWPAT") > /dev/null || { echo "   DIFFERS: $sfx $rg"; bad=$((bad + 1)); continue; }
    echo "   $sfx $rg: every line equal ($(grep -c -E "$NEWPAT" "$b") new-kind lines removed)"
  done <<< "$QS0_JOBS"
  [ "$bad" = 0 ] || { echo "   QS0 FAILED: $bad of $n"; return 1; }
  echo "   QS0 holds: $n of $n"
  basename "$B" > "$W/QS0_PASSED"
}

qs1() {   # log -> one line; exit 1 if it fails
  local log="$1" fl n k un
  grep -q "$DONE_MARKER" "$log" || { echo "not complete"; return 1; }
  fl=$(grep -c '^SRRIP_PUB FILLS:' "$log")
  [ "$fl" = 1 ] || { echo "$fl SRRIP_PUB FILLS lines, not 1"; return 1; }
  n=$(awk '/^SRRIP_PUB FILLS:/ { print $3 }' "$log"); k=$(awk '/^SRRIP_PUB FILLS:/ { print $8 }' "$log")
  [ "$n" -gt 0 ] && [ "$n" = "$k" ] || { echo "fills $n, at RRPV 2 $k"; return 1; }
  un=$(grep -E '^LLC COHERENCE DIR VIEW-ORDER VIOLATIONS UNEXPLAINED:' "$log" | awk '{ s += $NF } END { print s + 0 }')
  [ "$un" = 0 ] || { echo "unexplained view-order violations $un"; return 1; }
  echo "holds: fills $n, all at RRPV 2; unexplained 0"
}

rerun() {   # one JOBS line
  local x=$1 L ref log cfg wu si c B tr=() t v
  L=$(lab "$x")
  if is_done "$x"; then cl "$L: complete already"; return 0; fi
  ref=$(ref_log "$x"); log=$(new_log "$x"); cfg=$(new_cfg "$x")
  ref_done "$x" || { cl "$L: FAILED -- reference not complete ($ref)"; return 1; }
  mkdir -p "$W/cfg" "$(dirname "$log")"
  make_cfg "$(ref_cfg "$x")" "$cfg" 2> "$cfg.err" || { cl "$L: FAILED -- config: $(tail -1 "$cfg.err")"; return 1; }
  rm -f "$cfg.err"
  wu=$(awk '/^Warmup Instructions:/ { print $3; exit }' "$ref"); si=$(awk '/^Simulation Instructions:/ { print $3; exit }' "$ref")
  [ "$wu" = "$(f "$x" 5)" ] && [ "$si" = "$(f "$x" 6)" ] || { cl "$L: FAILED -- the reference's window ($wu + $si) is not the job's"; return 1; }
  c=$(f "$x" 3)
  mapfile -t tr < <(traces_of "$ref")
  [ "${#tr[@]}" = "$c" ] || { cl "$L: FAILED -- $ref names ${#tr[@]} traces, not $c"; return 1; }
  for t in "${tr[@]}"; do [ -s "$t" ] || { cl "$L: FAILED -- no trace $t"; return 1; }; done
  B=$(bin_sp); rm -f "$log.bin"
  cl "$L: START on $(basename "$B"), window $wu + $si, $c traces"
  ( cd "$S" && env -u COHERENCE_EVENT_LOG -u COHERENCE_POSITION_BINS nice -n 19 "$B" --config "$cfg" --warmup-instructions "$wu" --simulation-instructions "$si" "${tr[@]}" > "$log" 2>&1 )
  local rc=$?
  basename "$B" > "$log.bin"
  v=$(qs1 "$log"); echo "$v" > "$(dirname "$log")/qs1.txt"
  cl "$L: END rc=$rc; QS1 $v"
}

count_done() { local n=0 x; while read -r x; do is_done "$x" && n=$((n + 1)); done < <(jobs_list); echo "$n"; }

chain_drive() {
  echo $$ > "$PIDF"
  cl "CHAIN START: $(jobs_list | wc -l) srrip_pub runs, $PAR at a time, in JOBS order (16 cores first); binary $(basename "$(bin_sp)")"
  local x running=0
  while read -r x; do
    while [ "$running" -ge "$PAR" ]; do wait -n; running=$((running - 1)); done
    while [ "$(free_gb)" -lt "$MIN_FREE_GB" ]; do cl "under $MIN_FREE_GB GB free: no run starts until there is room"; sleep 300; done
    rerun "$x" &
    running=$((running + 1))
  done < <(jobs_list)
  wait
  cl "CHAIN END: $(count_done) of $(jobs_list | wc -l) runs complete"
  rm -f "$PIDF"
}

case "${1:-}" in
  check)
    mkdir -p "$W"
    { build && guards && qs0 && echo "CHECK PASSED: $(basename "$(bin_sp)"): guards and QS0 hold. No run was started: 'chain' starts them (owner's word)."; } 2>&1 | tee -p "$W/check_run.log"
    exit "${PIPESTATUS[0]}" ;;
  list) while read -r x; do printf '%-20s %-8s %s\n' "$(f "$x" 1)" "$(f "$x" 9)" "$(is_done "$x" && echo "complete; $(cat "$(dirname "$(new_log "$x")")/qs1.txt" 2>/dev/null)" || { [ -f "$(new_log "$x")" ] && echo 'started' || echo 'not started'; })"; done < <(jobs_list) ;;
  chain)
    mkdir -p "$W"
    alive "$PIDF" && { echo "the sp chain is running already (pid $(cat "$PIDF"))"; exit 0; }
    B=$(bin_sp); [ -x "$B" ] || die "no binary yet -- 'check'"
    passed QS0_PASSED || die "$(basename "$B") has not passed QS0 -- 'check'"
    guards
    n0=0; [ -f "$LOG" ] && n0=$(wc -l < "$LOG")
    setsid bash "$SELF" __chain >> "$LOG" 2>&1 < /dev/null &
    disown 2>/dev/null; sleep 3
    if ! alive "$PIDF"; then
      tail -n +$((n0 + 1)) "$LOG" | grep -q 'CHAIN END' && { echo "nothing left to do: $(tail -1 "$LOG")"; exit 0; }
      tail -5 "$LOG"; die "the chain stopped (above; $LOG)"
    fi
    echo "started: $(jobs_list | wc -l) runs, $PAR at a time; log $LOG" ;;
  __chain) chain_drive ;;
  status)
    echo "== sp (published SRRIP row): binary $(basename "$(bin_sp)" 2>/dev/null); QS0 $(passed QS0_PASSED && echo passed || echo 'not passed'); $(count_done) of $(jobs_list 2>/dev/null | wc -l) runs complete; chain $(alive "$PIDF" && echo alive || echo 'not running'); $(free_gb) GB free"
    [ -f "$W/check_run.log" ] && { echo "   -- check:"; tail -n 4 "$W/check_run.log" | sed 's/^/      /'; }
    [ -f "$LOG" ] && grep -E 'FAILED|END rc|CHAIN' "$LOG" | tail -n 6 | sed 's/^/   /'
    exit 0 ;;
  stop)
    if alive "$PIDF"; then
      sid=$(cat "$PIDF")
      [ "$(ps -o sid= -p "$sid" | tr -d ' ')" = "$sid" ] || die "pid $sid is not a session leader -- stopping nothing"
      ps -o args= -p "$sid" | grep -q 'sp_server.sh __chain' || die "pid $sid is not an sp_server.sh chain -- stopping nothing"
      pkill -TERM -s "$sid"; sleep 2; pgrep -s "$sid" > /dev/null && pkill -KILL -s "$sid"
      rm -f "$PIDF"; echo "stopped the sp chain (session $sid); $(date '+%F %T')" | tee -a "$LOG"
    else
      echo "the sp chain is not running"
    fi ;;
  *) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
