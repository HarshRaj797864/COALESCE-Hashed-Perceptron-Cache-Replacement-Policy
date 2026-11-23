#!/usr/bin/env bash
# H6(b) (bench/policy_sanity/h6b_attribution_design_2026-11-14.md): QP on the micro
# program under gem5's ProtocolTrace; then, only if QP holds, fluidanimate, vips and
# canneal 4c: gem5 rerun exactly as the scored 150 M run with ProtocolTrace from the
# 50 M run's finalTick (filtered in the pipe), ChampSim's F-C run with
# COHERENCE_EVENT_LOG, the traces' RMW ips, then the attribution and the report.
# Writes only under ~/h6b. Records only: no scored file is touched.
#
#   bash ~/h6b/h6b_server.sh guards
#   bash ~/h6b/h6b_server.sh go       # guards, then the chain, DETACHED
#   bash ~/h6b/h6b_server.sh go2      # amendment 2: after QP FAILED, its files kept aside, then go
#   bash ~/h6b/h6b_server.sh status
set -uo pipefail
SELF="$(readlink -f "$0")"
trap 'rc=$?; [ "$rc" = 0 ] || echo "h6b_server.sh ${1:-}: stopped, exit code $rc ($(date "+%F %T"))" >&2' EXIT

R="${R:-$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy}"
S="$R/simulator"
W="${W:-$HOME/h6b}"
FC_MD5="${FC_MD5:-a2e88e46788e1f332427567a19bc2f90}"
CFG_MD5="${CFG_MD5:-3efd5110e5d7d96b11e9470439d60e29}"
GEM5_DIR="${GEM5_DIR:-$HOME/gem5}"
GEM5="${GEM5:-$GEM5_DIR/build/X86/gem5.opt}"
SE="${SE:-$GEM5_DIR/configs/deprecated/example/se.py}"
G5R="${G5R:-$HOME/gem5_b3}"
H2="${H2:-$HOME/heldout2}"
MICRO="${MICRO:-$HOME/micro/micro_m5}"
NUMPY_PY="${NUMPY_PY:-$HOME/q16cs/venv/bin/python3}"
MIN_FREE_GB="${MIN_FREE_GB:-30}"
QP_CASES="${QP_CASES:-pp_store pp_lock pp_rmw readers}"
PROGS="${PROGS:-fluidanimate vips canneal}"
DONE_MARKER="ChampSim completed all CPUs"
PIDF="$W/.pid"
LOG="$W/driver.log"
# the filter in the pipe: L1 and L2 transitions, the end lines, and each ST Seq Begin. gem5
# prints a request's SECONDARY type (Sequencer.cc:1157), ST for a store and for both parts of a
# locked or plain RMW; an ST whose core's previous request (any type, loads and fetches
# included) was an ST at the same address is written "Seq Pair": the write of an RMW.
# Amendment 2: gem5 25.1 prints the address through printAddress (Address.cc:76) as
# "[0xADDR, line 0xLINE]" and the type LAST; a request without an address prints the type alone.
# The address is the first field that reads [0x...,; the ST lines are written out normalised:
# tick core Seq Begin|Pair > 0xADDR ST.
FILTER='$3 == "Seq" && $4 == "Begin" { c = $2; a = ""; for (i = 5; i <= NF; i++) if ($i ~ /^\[?0x[0-9a-fA-F]+,?$/) { a = $i; gsub(/[\[,]/, "", a); break }
  t = $NF; if (t == "ST" && a != "") { if (pt[c] == "ST" && pa[c] == a) print $1, c, "Seq", "Pair", ">", a, "ST"; else print $1, c, "Seq", "Begin", ">", a, "ST" }
  pt[c] = t; pa[c] = a; next }
$1 ~ /^[0-9]+$/ && ($3 == "L1Cache" || $3 == "L2Cache") { print; next }
/^Exiting @ tick|^command line:/ { print }'
# the filter on a hand case (amendment 2: gem5 25.1's form; line 5 the older bare form): 3 pairs with
# 1 (core 0, same address, nothing between) and 9 with 2 (core 1); 5 follows a load and 8 the
# no-address form 7, so neither pairs; 13 is core 1's ST at another byte of 9's line: no pair; the LD,
# the L0 line and 7 are dropped; every ST line comes out as tick core Seq Begin|Pair > 0xADDR ST
filter_check() {
  local got
  got=$(printf '%s\n' \
    '      1   0        Seq               Begin       >       [0x10, line 0x0] ST' \
    '      2   1        Seq               Begin       >       [0x10, line 0x0] ST' \
    '      3   0        Seq               Begin       >       [0x10, line 0x0] ST' \
    '      4   0        Seq               Begin       >       [0x10, line 0x0] LD' \
    '      5   0        Seq               Begin       >       0x10 ST' \
    '      6   0    L0Cache               Store      I>IM     [0x40, line 0x40] ' \
    '      7   0        Seq               Begin       >       TLBI' \
    '      8   0        Seq               Begin       >       [0x10, line 0x0] ST' \
    '      9   1        Seq               Begin       >       [0x10, line 0x0] ST' \
    '     10   0    L1Cache               Store      I>IM     [0x40, line 0x40] ' \
    '     11   0    L2Cache             L1_GETX     MT>MT_MB  [0x40, line 0x40] [NetDest (20) 0 0 0 0  - 1 0 0 0  - ]' \
    '     13   1        Seq               Begin       >       [0x18, line 0x0] ST' \
    'Exiting @ tick 14 because done' | LC_ALL=C awk "$FILTER" | awk '{ printf "%s %s %s%s;", $1, $3, $4, ($3 == "Seq" ? " " $6 " " $7 : "") }')
  [ "$got" = "1 Seq Begin 0x10 ST;2 Seq Begin 0x10 ST;3 Seq Pair 0x10 ST;5 Seq Begin 0x10 ST;8 Seq Begin 0x10 ST;9 Seq Pair 0x10 ST;10 L1Cache Store;11 L2Cache L1_GETX;13 Seq Begin 0x18 ST;Exiting tick 14;" ]
}
alive() { [ -f "$1" ] && kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null; }
die() { echo "ERROR: $*" >&2; exit 1; }
free_gb() { df -BG --output=avail "$HOME" | tail -1 | tr -dc 0-9; }
cl() { echo "$(date '+%F %T') $*"; }
bin_fc() { cat "$HOME/sync_fc/BIN" 2>/dev/null; }
# per program: the F-C rerun's directory, the gem5 runs, the traced CPUs
fcdir() { case "$1" in fluidanimate) echo "$S/results/phaseA_b3_fc_h2_fluidanimate4/regime_shared/fluidanimate_4core/lru" ;;
                       vips) echo "$S/results/phaseA_b3_fc_h2_vips4/regime_shared/vips_4core/lru" ;;
                       canneal) echo "$S/results/phaseA_b3_fc_g3_canneal4/regime_shared/canneal_4core/lru" ;; esac; }
g5dir() { case "$1" in canneal) echo "$G5R/canneal/l2_2MB_mi$2M/canneal_4c" ;; *) echo "$G5R/heldout2/$1/l2_2MB_mi$2M/$1_4c" ;; esac; }
traced() { case "$1" in vips) echo 3,4,5,6 ;; *) echo 1,2,3,4 ;; esac; }
cmdval() { awk -v k="$1" '$1 == k { $1 = ""; sub(/^ /, ""); print; exit }' "$2/cmd.txt"; }

guards() {
  local B p d
  B=$(bin_fc)
  [ -n "$B" ] && [ -x "$B" ] && [ "$(md5sum < "$B" | cut -c1-32)" = "$FC_MD5" ] || die "the F-C binary ($B) is missing or not md5 $FC_MD5"
  [ -x "$GEM5" ] || die "no gem5 at $GEM5"
  [ "$(cat "$GEM5_DIR/.gem5_protocol" 2>/dev/null)" = MESI_Three_Level ] || die "gem5 is not the MESI_Three_Level build"
  [ -x "$MICRO" ] && file -b "$MICRO" | grep -q 'statically linked' || die "no static micro binary at $MICRO"
  "$NUMPY_PY" -c 'import numpy' 2>/dev/null || die "no numpy in $NUMPY_PY"
  python3 "$W/h6b_attr.py" selftest > /dev/null 2>&1 || die "h6b_attr.py's self-test fails here"
  python3 "$W/h6_lockreq.py" selftest > /dev/null 2>&1 || die "h6_lockreq.py's self-test fails here"
  command -v xz > /dev/null || die "no xz"
  filter_check || die "the pipe's awk filter fails its hand case"
  for p in $PROGS; do
    d=$(fcdir "$p")
    grep -q "$DONE_MARKER" "$d/run.log" 2>/dev/null || die "$p: the F-C rerun's log $d/run.log is not complete"
    grep -q "^binary .*champsim_fc_a2e88e46 $FC_MD5\$" "$d/cmd.txt" || die "$p: $d/cmd.txt names another binary"
    [ "$(md5sum < "$(cmdval config "$d" | awk '{print $1}')" | cut -c1-32)" = "$CFG_MD5" ] || die "$p: the config is not md5 $CFG_MD5"
    [ "$(cmdval warmup "$d")" = "50000000 simulation 100000000" ] || die "$p: another window in $d/cmd.txt"
    for t in $(cmdval traces "$d"); do [ -s "$t" ] || die "$p: no trace $t"; done
    [ -s "$(g5dir "$p" 50)/stats.txt" ] && [ -s "$(g5dir "$p" 150)/stats.txt" ] || die "$p: a gem5 run's stats.txt is missing"
    grep -q '^command line: ' "$(g5dir "$p" 150)/run.log" || die "$p: no command line in the 150 M run's log"
    grep -m1 '^command line: ' "$(g5dir "$p" 150)/run.log" | grep -q " --outdir=$(g5dir "$p" 150) " || die "$p: the command line names another outdir"
    grep -m1 '^command line: ' "$(g5dir "$p" 150)/run.log" | grep -q "^command line: $GEM5 " || die "$p: the 150 M run used another gem5"
    [ -n "$(awk '$1 == "finalTick" { print $2; exit }' "$(g5dir "$p" 50)/stats.txt")" ] || die "$p: no finalTick in the 50 M run"
    [ "$p" = canneal ] || [ -f "$H2/$p/CHOSEN" ] || die "$p: no $H2/$p/CHOSEN"
  done
  [ "$(free_gb)" -ge "$MIN_FREE_GB" ] || die "under $MIN_FREE_GB GB free ($(free_gb))"
  echo "   guards: $(basename "$B") md5 ${FC_MD5:0:8}; gem5 md5 $(md5sum < "$GEM5" | cut -c1-8); micro md5 $(md5sum < "$MICRO" | cut -c1-8); $PROGS: F-C reruns complete, gem5 runs present; self-tests pass; $(free_gb) GB free"
}

# gem5 with ProtocolTrace on stdout, filtered and compressed; $1 out dir, then gem5's arguments
traced_gem5() {
  local od="$1"; shift
  ( set -o pipefail
    timeout 96h nice -n 19 "$@" 2> "$od/gem5.err" | LC_ALL=C awk "$FILTER" | nice -n 19 xz -1 -T1 > "$od/trace.xz"
    echo "${PIPESTATUS[0]} ${PIPESTATUS[1]} ${PIPESTATUS[2]}" > "$od/pipe.rc" )
}

qp_one() {
  local c="$1" od="$W/qp/$1"
  rm -rf "$od"; mkdir -p "$od"
  ( cd "$od" && traced_gem5 "$od" "$GEM5" --outdir="$od" --debug-flags=ProtocolTrace "$SE" --ruby --num-cpus=4 --cpu-type=TimingSimpleCPU --mem-size=4GB \
      --l0i_size=32kB --l0i_assoc=8 --l0d_size=2kB --l0d_assoc=8 --l1d_size=8kB --l1d_assoc=8 \
      --l2_size=256kB --l2_assoc=16 --num-l2caches=1 --num-clusters=1 -c "$MICRO" --options="$c 4" < /dev/null )
  python3 "$W/h6b_attr.py" gem5 "$od/trace.xz" --traced 0,1,2,3 --repl > "$od/ev.txt" 2> "$od/attr.err"
  python3 "$W/h6b_attr.py" qp "$c" "$od/ev.txt" > "$od/qp.txt" 2>&1
}

g5_one() {
  local p="$1" o50 o150 od cmd ta cwd a=() new=() x f set_ args sin files
  o50=$(g5dir "$p" 50); o150=$(g5dir "$p" 150); od="$W/g5/$p"
  rm -rf "$od"; mkdir -p "$od"
  ta=$(awk '$1 == "finalTick" { print $2; exit }' "$o50/stats.txt")
  cmd=$(grep -m1 '^command line: ' "$o150/run.log" | sed 's/^command line: //')
  eval "a=( $cmd )"
  [ "${a[0]}" = "$GEM5" ] && [ "${a[1]}" = "--outdir=$o150" ] || { cl "$p: the command line does not parse as expected"; return 1; }
  new=("${a[0]}" "--outdir=$od" --debug-flags=ProtocolTrace "--debug-start=$ta")
  for x in "${a[@]:2}"; do new+=("${x//$o150/$od}"); done
  cwd=$(awk -F= '$1 == "cwd" { print $2; exit }' "$o150/config.ini")
  if [ "$cwd" = "$o150" ]; then
    IFS='|' read -r set_ args sin files < "$H2/$p/CHOSEN"
    for f in $files; do cp -rp "$H2/$p/inputs/$set_/$f" "$od/" || { cl "$p: could not copy $f"; return 1; }; done
    [ -z "$sin" ] || cp "$H2/$p/inputs/$set_/$sin" "$od/" || return 1
    cwd="$od"
  fi
  printf '%s\n' "T_a $ta" "cwd $cwd" "${new[@]}" > "$od/command.txt"
  ( cd "$cwd" && traced_gem5 "$od" "${new[@]}" < /dev/null )
  python3 "$W/h6b_attr.py" gem5 "$od/trace.xz" --traced "$(traced "$p")" > "$od/ev.txt" 2> "$od/attr.err"
  python3 "$W/h6b_attr.py" qg1 "$o150/stats.txt" "$od/stats.txt" > "$od/qg1.txt" 2>&1
}

cs_one() {
  local p="$1" d od B t=()
  d=$(fcdir "$p"); od="$W/cs/$p"; B=$(bin_fc)
  rm -rf "$od"; mkdir -p "$od"
  read -ra t <<< "$(cmdval traces "$d")"
  ( cd "$S" && COHERENCE_EVENT_LOG="$od/events.log" nice -n 19 "$B" --config "$(cmdval config "$d" | awk '{print $1}')" \
      --warmup-instructions 50000000 --simulation-instructions 100000000 "${t[@]}" > "$od/run.log" 2>&1 )
  if python3 "$W/h6_lockreq.py" qe0 "$od/run.log" "$d/run.log" > "$od/qe0.txt" 2>&1; then :; fi
  nice -n 19 "$NUMPY_PY" "$W/h6b_attr.py" rmwips "${t[@]}" --warmup 50000000 --sim 100000000 > "$od/rmw.txt" 2> "$od/rmw.err"
  python3 "$W/h6b_attr.py" champsim "$od/events.log" "$od/rmw.txt" "$od/run.log" > "$od/ev.txt" 2> "$od/attr.err"
  nice -n 19 xz -T1 -f "$od/events.log"
}

drive() {
  echo $$ > "$PIDF"
  local c p bad=0 pids=()
  cl "QP START: $QP_CASES"
  for c in $QP_CASES; do qp_one "$c" & pids+=($!); done
  wait "${pids[@]}"
  for c in $QP_CASES; do cl "$(cat "$W/qp/$c/qp.txt" 2>/dev/null || echo "QP $c: no result")"; grep -q ' -> holds$' "$W/qp/$c/qp.txt" 2>/dev/null || bad=1; done
  if [ "$bad" = 1 ]; then cl "QP FAILED: nothing else runs (the note)"; date '+%F %T QP FAILED' > "$W/DONE"; rm -f "$PIDF"; exit 1; fi
  cl "QP HOLDS; RUNS START: gem5 and ChampSim for $PROGS"
  pids=()
  for p in $PROGS; do g5_one "$p" & pids+=($!); cs_one "$p" & pids+=($!); done
  wait "${pids[@]}"
  for p in $PROGS; do
    cl "$p: gem5 pipe rc $(cat "$W/g5/$p/pipe.rc" 2>/dev/null); $(cat "$W/g5/$p/qg1.txt" 2>/dev/null); $(head -1 "$W/cs/$p/qe0.txt" 2>/dev/null); $(head -1 "$W/cs/$p/ev.txt" 2>/dev/null | cut -c1-160)"
    python3 "$W/h6b_attr.py" report "$p" "$W/g5/$p/ev.txt" "$W/cs/$p/ev.txt" "$(g5dir "$p" 50)/stats.txt" "$W/g5/$p/stats.txt" \
      "$(g5dir "$p" 150)/stats.txt" "$W/cs/$p/qe0.txt" > "$W/report_$p.txt" 2>&1
    cl "REPORT $p rc=$? -> $W/report_$p.txt"
  done
  date '+%F %T' > "$W/DONE"
  cl "END"
  rm -f "$PIDF"
}

case "${1:-}" in
  guards) mkdir -p "$W"; guards ;;
  go)
    mkdir -p "$W"
    alive "$PIDF" && { echo "H6(b) is running already (pid $(cat "$PIDF"))"; exit 0; }
    [ -f "$W/DONE" ] && { echo "H6(b) is done already ($(cat "$W/DONE")); remove $W/DONE to run it again"; exit 0; }
    guards
    n0=0; [ -f "$LOG" ] && n0=$(wc -l < "$LOG")
    setsid bash "$SELF" __drive >> "$LOG" 2>&1 < /dev/null &
    disown 2>/dev/null; sleep 3
    alive "$PIDF" || tail -n +$((n0 + 1)) "$LOG" | grep -q 'QP START' || { tail -5 "$LOG"; die "the chain did not start (above; $LOG)"; }
    echo "started: QP, then (if it holds) 3 gem5 reruns and 3 ChampSim runs, then the reports; log $LOG" ;;
  go2)   # amendment 2: only after QP FAILED; the failed QP's files are kept, then as go
    mkdir -p "$W"
    alive "$PIDF" && { echo "H6(b) is running already (pid $(cat "$PIDF"))"; exit 0; }
    grep -q 'QP FAILED' "$W/DONE" 2>/dev/null || die "go2 is only for a chain that stopped at QP (DONE: $(cat "$W/DONE" 2>/dev/null || echo none))"
    guards
    tag="a1_$(date +%Y%m%d_%H%M%S)"
    mv "$W/qp" "$W/qp.fail_$tag" && mv "$W/DONE" "$W/DONE.fail_$tag" || die "could not move the failed QP aside"
    echo "   the failed QP kept as $W/qp.fail_$tag"
    cl "AMENDMENT 2: the failed QP kept as qp.fail_$tag; QP again" >> "$LOG"
    exec bash "$SELF" go ;;
  __drive) drive ;;
  status)
    echo "== H6(b): $( [ -f "$W/DONE" ] && echo "done $(cat "$W/DONE")" || { alive "$PIDF" && echo running || echo 'not running'; })"
    [ -f "$LOG" ] && tail -n 8 "$LOG" | sed 's/^/   /'
    for p in $PROGS; do
      [ -d "$W/g5/$p" ] && echo "   $p: gem5 trace $(du -h "$W/g5/$p/trace.xz" 2>/dev/null | cut -f1); ChampSim $(grep '^Heartbeat' "$W/cs/$p/run.log" 2>/dev/null | tail -1 | cut -c1-60)"
    done
    exit 0 ;;
  *) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
