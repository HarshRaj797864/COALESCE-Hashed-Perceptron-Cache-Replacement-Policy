#!/usr/bin/env bash
# Part C on the server (bench/policy_sanity/breadth_bc_design_2026-11-10.md,
# Part C, amendment 1's C at 16 cores, amendment 6 = Note 4): stock ChampSim
# (upstream f9ed890e's own binary, Part A's frozen champsim_partA_up_<md5>)
# and ours with the extension off (Part A's champsim_partA_ours_<md5>), on the
# traces OUR scored run of each program replayed, with the sync records
# removed (sync_strip.py), the same window, LRU, the same 2 MB LLC, private
# regime, level 0, rmw_as_rfo 0 (Part A's off_<cores>_lru.json).
#
# Each pair is (program, cores). Its REFERENCE is our run in
# results/<tree>/regime_shared/*_<cores>core/lru/run.log: the traces are read
# from its "CPU n runs" lines, the window from its Warmup / Simulation lines.
# A pair waits until its reference has completed (Part B's runs end over
# days), then: strip every trace into $W/strip/<pair>/ (xz), check each
# (records out = records in - sync records), run upstream and ours-off side
# by side, and delete the stripped copies once both logs are complete
# (KEEP_STRIP=1 keeps them). Logs results/partC/<p>_<cores>.<up|oursoff>.log,
# each with a .bin sidecar naming its binary; strip reports in $W/strip_reports/.
# Writes only under ~/partC and results/partC; reads Part A's binaries and
# configs, never rebuilds them; touches no other chain.
#
#   bash ~/partC_server.sh guards   # read-only apart from ~/partC/cfg: binaries, E0, configs, the stripper's selftest, references present
#   bash ~/partC_server.sh chain    # detached: the 45 pairs, PAR at a time, each started once its reference has completed
#   bash ~/partC_server.sh status | stop | pairs
set -uo pipefail
SELF="$(readlink -f "$0")"
trap 'rc=$?; [ "$rc" = 0 ] || echo "partC_server.sh ${1:-}: stopped, exit code $rc ($(date "+%F %T"))" >&2' EXIT

R="${R:-$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy}"
S="$R/simulator"
W="${W:-$HOME/partC}"
OUT="${OUT:-$S/results/partC}"
PA_W="${PA_W:-$HOME/partA}"                       # Part A: BIN_UP, BIN_OURS, E0_PASSED, cfg/off_<c>_lru.json
MC="${MC:-$HOME/partA_ours_build/simulator/scripts/make_config.py}"
STRIP="${STRIP:-$W/sync_strip.py}"
PAR="${PAR:-6}"                                    # pairs at a time (each: two ChampSim runs; the strip before)
WAIT_DAYS="${WAIT_DAYS:-14}"                       # a reference not complete by then: the pair is reported, not run
WAIT_S="${WAIT_S:-$((WAIT_DAYS * 86400))}"
POLL_S="${POLL_S:-600}"
MIN_FREE_GB="${MIN_FREE_GB:-20}"
DONE_MARKER="ChampSim completed all CPUs"
LOG="$W/driver.log"
PIDF="$W/.driver.pid"
PROGS15="ocean oceannc radix barnes lunc fft volrend waternsq raytrace fmm canneal streamcluster fluidanimate vips bodytrack"

alive() { [ -f "$1" ] && kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null; }
die() { echo "ERROR: $*" >&2; exit 1; }
free_gb() { df -BG --output=avail "$S" | tail -1 | tr -dc 0-9; }

# the reference tree of each pair: the run each program was (or will be) scored by
tree_of() {   # program cores
  local p=$1 c=$2
  case "$c" in
    4) case "$p" in
         ocean|canneal|radix|waternsq) echo "phaseA_b3_g3_${p}4" ;;
         barnes) echo "phaseA_b3_g3_barnesstd4" ;;                        # the standard barnes, its window span
         fft|volrend|fmm) echo "phaseA_b3_b1_${p}4" ;;                     # B1
         lunc|raytrace) echo "phaseA_b3_n2_${p}4" ;;                       # step 4
         oceannc|fluidanimate|vips|bodytrack|streamcluster) echo "phaseA_b3_h2_${p}4" ;;   # set 2 (streamcluster: newbench amendment 3)
       esac ;;
    8) if [ "$p" = canneal ]; then echo "phaseA_b3_g3_canneal8"; else echo "phaseA_b3_b2_${p}8"; fi ;;
    16) if [ "$p" = canneal ]; then echo "phaseA_b3_p2_canneal16"; else echo "phaseA_b3_b16_${p}16"; fi ;;
  esac
}
pairs() { local c p; for c in ${CORES:-4 8 16}; do for p in ${PROGS:-$PROGS15}; do echo "$p $c"; done; done; }
ref_log() { ls "$S/results/$(tree_of "$1" "$2")"/regime_shared/*_"$2"core/lru/run.log 2>/dev/null | head -1; }
ref_done() { local f; f=$(ref_log "$1" "$2"); [ -n "$f" ] && grep -q "$DONE_MARKER" "$f"; }
logname() { echo "$OUT/$1_$2.$3.log"; }          # program cores side
binof() { case $1 in up) cat "$PA_W/BIN_UP" ;; *) cat "$PA_W/BIN_OURS" ;; esac; }
is_done() { grep -q "$DONE_MARKER" "$1" 2>/dev/null && [ "$(cat "$1.bin" 2>/dev/null)" = "$(basename "$(binof "$2")")" ]; }
pair_done() { is_done "$(logname "$1" "$2" up)" up && is_done "$(logname "$1" "$2" oursoff)" oursoff; }
cl() { echo "$(date '+%F %T') $*"; }

guards() {
  local f c bad=0
  [ -x "$(cat "$PA_W/BIN_UP" 2>/dev/null)" ] && [ -x "$(cat "$PA_W/BIN_OURS" 2>/dev/null)" ] || die "Part A's frozen binaries are not there ($PA_W/BIN_UP, BIN_OURS)"
  [ "$(cat "$PA_W/E0_PASSED" 2>/dev/null)" = "$(basename "$(cat "$PA_W/BIN_OURS")") $(basename "$(cat "$PA_W/BIN_UP")")" ] || die "Part A's binaries have not passed E0"
  grep -qa 'RMW LOADS AS RFO' "$(cat "$PA_W/BIN_OURS")" || die "the ours binary has no rmw_as_rfo setting"
  [ -f "$MC" ] || die "no make_config.py at $MC (Part A's ours tree)"
  [ -f "$STRIP" ] || die "no $STRIP"
  python3 "$STRIP" selftest > "$W/strip_selftest.txt" 2>&1 || { tail -3 "$W/strip_selftest.txt"; die "sync_strip.py's selftest fails"; }
  mkdir -p "$W/cfg" "$OUT"
  for c in 4 8 16; do
    python3 "$MC" --policy lru --cores "$c" --regime private --rmw-as-rfo 0 -o "$W/cfg/off_${c}_lru.json" > /dev/null || die "make_config failed at $c cores"
    if [ -f "$PA_W/cfg/off_${c}_lru.json" ]; then cmp -s "$W/cfg/off_${c}_lru.json" "$PA_W/cfg/off_${c}_lru.json" || die "off_${c}_lru.json differs from Part A's"; fi
  done
  python3 -c "import json,sys; c=json.load(open(sys.argv[1])); assert c['LLC']['sets'] * c['LLC']['ways'] * 64 == 2 << 20, 'LLC is not 2 MB'" "$W/cfg/off_16_lru.json" \
    || die "the 16-core config's LLC is not 2 MB"
  while read -r p c; do
    [ -n "$(tree_of "$p" "$c")" ] || { echo "   $p $c: no reference tree known"; bad=$((bad + 1)); }
  done < <(pairs)
  [ "$bad" = 0 ] || die "$bad pairs have no reference tree"
  [ "${1:-}" = nodisk ] || [ "$(free_gb)" -ge "$MIN_FREE_GB" ] || die "under $MIN_FREE_GB GB free ($(free_gb))"
  echo "   guards: up $(basename "$(cat "$PA_W/BIN_UP")"), ours $(basename "$(cat "$PA_W/BIN_OURS")") (E0 passed); configs off_{4,8,16}_lru.json (4 and 8 equal to Part A's); stripper selftest passes; $(pairs | wc -l) pairs, references complete now: $(n=0; while read -r p c; do ref_done "$p" "$c" && n=$((n + 1)); done < <(pairs); echo $n); $(free_gb) GB free"
}

# one pair (its reference complete): strip, run both, delete the stripped copies
pair() {
  local p=$1 c=$2 ref wu si k t tr=() bad=0 d rep
  if pair_done "$p" "$c"; then cl "$p $c: complete already"; return 0; fi
  ref=$(ref_log "$p" "$c")
  wu=$(awk '/^Warmup Instructions:/ { print $3; exit }' "$ref"); si=$(awk '/^Simulation Instructions:/ { print $3; exit }' "$ref")
  [ -n "$wu" ] && [ -n "$si" ] || { cl "$p $c: FAILED -- no window in $ref"; return 1; }
  mapfile -t tr < <(awk '/^CPU [0-9]+ runs / { print $2, $4 }' "$ref" | sort -n -k1,1 | awk '{ print $2 }')
  [ "${#tr[@]}" = "$c" ] || { cl "$p $c: FAILED -- $ref names ${#tr[@]} traces, not $c"; return 1; }
  d="$W/strip/${p}_$c"; rep="$W/strip_reports/${p}_$c.txt"; mkdir -p "$d" "$W/strip_reports"
  cl "$p $c: reference $(tree_of "$p" "$c") complete; window $wu + $si; stripping $c traces"
  : > "$rep"
  for k in "${!tr[@]}"; do
    t="${tr[$k]}"
    [ -s "$t" ] || { cl "$p $c: FAILED -- no trace $t"; return 1; }
    if [ ! -s "$d/t$k.champsimtrace.xz" ] || ! grep -q "^t$k " "$W/strip_reports/${p}_$c.ok" 2>/dev/null; then
      ( nice -n 10 python3 "$STRIP" strip "$t" "$d/t$k.champsimtrace.xz" > "$d/t$k.strip.txt" 2>&1 ) &
    fi
  done
  wait
  for k in "${!tr[@]}"; do
    if [ -f "$d/t$k.strip.txt" ]; then
      echo "t$k $(cat "$d/t$k.strip.txt")" >> "$rep"
      # records out = records in - sync records (sync_strip.py asserts it; its report line is checked again here)
      awk -v k="t$k" '{ n_in = $2; n_sync = $5; n_out = $(NF - 2) } END { exit !(NR == 1 && n_in == n_sync + n_out && $0 !~ /IGNORED/) }' "$d/t$k.strip.txt" \
        && echo "t$k" >> "$W/strip_reports/${p}_$c.ok" || { cl "$p $c: FAILED -- t$k's strip report: $(cat "$d/t$k.strip.txt")"; bad=$((bad + 1)); }
    fi
  done
  [ "$bad" = 0 ] || return 1
  cl "$p $c: stripped ($(awk '{ s += $6 } END { print s + 0 }' "$rep") sync records dropped in all); running upstream and ours-off"
  local sd B log
  for sd in up oursoff; do
    log=$(logname "$p" "$c" "$sd")
    is_done "$log" "$sd" && continue
    B=$(binof "$sd"); rm -f "$log.bin"
    ( cd "$S" && nice -n 19 "$B" --config "$W/cfg/off_${c}_lru.json" --warmup-instructions "$wu" --simulation-instructions "$si" \
        $(for k in "${!tr[@]}"; do echo "$d/t$k.champsimtrace.xz"; done) > "$log" 2>&1; basename "$B" > "$log.bin" ) &
  done
  wait
  for sd in up oursoff; do
    is_done "$(logname "$p" "$c" "$sd")" "$sd" || { cl "$p $c: FAILED -- the $sd run did not complete ($(tail -1 "$(logname "$p" "$c" "$sd")" | cut -c1-100))"; bad=$((bad + 1)); }
  done
  [ "$bad" = 0 ] || return 1
  if [ -z "${KEEP_STRIP:-}" ]; then rm -f "$d"/t*.champsimtrace.xz; fi
  cl "$p $c: complete (both logs); stripped copies $([ -z "${KEEP_STRIP:-}" ] && echo removed || echo kept)"
}

count_done() { local n=0; while read -r p c; do pair_done "$p" "$c" && n=$((n + 1)); done < <(pairs); echo "$n"; }

chain_drive() {
  echo $$ > "$PIDF"
  cl "CHAIN START: $(pairs | wc -l) pairs, $PAR at a time; up $(basename "$(cat "$PA_W/BIN_UP")"), ours-off $(basename "$(cat "$PA_W/BIN_OURS")"); a pair starts once its reference has completed (at most $((WAIT_S / 86400)) days from now)"
  local pending=() rest p c t0 started=0
  mapfile -t pending < <(pairs)
  t0=$(date +%s)
  while [ "${#pending[@]}" -gt 0 ]; do
    rest=()
    for pc in "${pending[@]}"; do
      read -r p c <<< "$pc"
      if [ "$(jobs -rp | wc -l)" -lt "$PAR" ] && [ "$(free_gb)" -ge "$MIN_FREE_GB" ] && { pair_done "$p" "$c" || ref_done "$p" "$c"; }; then
        pair "$p" "$c" &
        started=$((started + 1))
      else
        rest+=("$pc")
      fi
    done
    pending=("${rest[@]}")
    [ "${#pending[@]}" -gt 0 ] || break
    if [ $(( $(date +%s) - t0 )) -ge "$WAIT_S" ]; then   # time is up for references; pairs whose reference completed still run
      rest=()
      for pc in "${pending[@]}"; do
        read -r p c <<< "$pc"
        if ref_done "$p" "$c"; then rest+=("$pc")
        else cl "$p $c: NOT RUN -- its reference ($(tree_of "$p" "$c")) did not complete in $((WAIT_S / 86400)) days"; fi
      done
      pending=("${rest[@]}")
      [ "${#pending[@]}" -gt 0 ] || break
    fi
    [ "$(free_gb)" -ge "$MIN_FREE_GB" ] || cl "under $MIN_FREE_GB GB free: no pair starts until there is room"
    sleep "$POLL_S"
  done
  wait
  cl "CHAIN END: $(count_done) of $(pairs | wc -l) pairs complete"
  rm -f "$PIDF"
}

case "${1:-}" in
  guards) mkdir -p "$W"; guards ;;
  pairs) while read -r p c; do printf '%-13s %2s  %-28s %s\n' "$p" "$c" "$(tree_of "$p" "$c")" "$(ref_done "$p" "$c" && echo 'reference complete' || echo 'reference not complete')"; done < <(pairs) ;;
  chain)
    mkdir -p "$W" "$OUT"
    alive "$PIDF" && { echo "the partC chain is running already (pid $(cat "$PIDF"))"; exit 0; }
    guards
    n0=0; [ -f "$LOG" ] && n0=$(wc -l < "$LOG")
    setsid bash "$SELF" __chain >> "$LOG" 2>&1 < /dev/null &
    disown 2>/dev/null; sleep 3
    if ! alive "$PIDF"; then
      tail -n +$((n0 + 1)) "$LOG" | grep -q 'CHAIN END' && { echo "nothing left to do: $(tail -1 "$LOG")"; exit 0; }
      tail -5 "$LOG"; die "the chain stopped (above; $LOG)"
    fi
    echo "started: $(pairs | wc -l) pairs, $PAR at a time; log $LOG" ;;
  __chain) chain_drive ;;
  status)
    echo "== partC (stock beside ours): up $(basename "$(cat "$PA_W/BIN_UP" 2>/dev/null)" 2>/dev/null), ours-off $(basename "$(cat "$PA_W/BIN_OURS" 2>/dev/null)" 2>/dev/null); pairs $(count_done) of $(pairs | wc -l) complete; chain $(alive "$PIDF" && echo alive || echo 'not running'); $(free_gb) GB free"
    [ -f "$LOG" ] && grep -E 'FAILED|NOT RUN|complete \(|CHAIN' "$LOG" | tail -n 8 | sed 's/^/   /'
    exit 0 ;;
  stop)
    if alive "$PIDF"; then
      sid=$(cat "$PIDF")
      [ "$(ps -o sid= -p "$sid" | tr -d ' ')" = "$sid" ] || die "pid $sid is not a session leader -- stopping nothing"
      ps -o args= -p "$sid" | grep -q 'partC_server.sh __chain' || die "pid $sid is not a partC_server.sh chain -- stopping nothing"
      pkill -TERM -s "$sid"; sleep 2; pgrep -s "$sid" > /dev/null && pkill -KILL -s "$sid"
      rm -f "$PIDF"; echo "stopped the partC chain (session $sid); $(date '+%F %T')" | tee -a "$LOG"
    else
      echo "the partC chain is not running"
    fi ;;
  *) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
