#!/usr/bin/env bash
# H3a (bench/policy_sanity/h3_statistics_design_2026-11-14.md), server side: ChampSim's
# noise floor. Step 5's canneal 8c shared runs on step 5's binary (champsim_g6_1e3060c1)
# and configs, with the warmup moved to 45 / 47.5 / 52.5 / 55 M (simulation 100 M):
#   fixed  (phaseA_b3_p2_canneal8):        coalesce mockingjay srrip srrip_bias
#   scaled (phaseA_b3_p2_canneal8_scaled): srrip srrip_bias mockingjay ship
# 32 runs, the fixed class first, PAR at a time, nice 19, into
#   results/phaseA_b3_h3w<W>_canneal8[_scaled]/regime_shared/canneal_8core/<policy>/run.log
# (config.json and run.log.bin beside each). State ~/h3. Nothing else is touched.
#
#   bash ~/h3/h3_server.sh guards        # read-only
#   bash ~/h3/h3_server.sh list          # every run and its state
#   bash ~/h3/h3_server.sh chain         # (owner's word) guards, then the driver, detached
#   bash ~/h3/h3_server.sh status
#   bash ~/h3/h3_server.sh stop [runs]   # the driver; with 'runs', its ChampSim runs too
set -uo pipefail
SELF="$(readlink -f "$0")"
R="${R:-$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy}"
S="$R/simulator"
W="${W:-$HOME/h3}"
POL_W="${POL_W:-$HOME/sync_pol}"                 # step 5's state: cfg/, BIN
G6_MD5="${G6_MD5:-1e3060c1760b4b3b18e5728a9dfb75ed}"
G6_NAME="champsim_g6_1e3060c1"
TRDIR="${TRDIR:-$S/traces/sync_mx/canneal8}"
PAR="${PAR:-8}"
CPOLL_S="${CPOLL_S:-60}"
MIN_FREE_GB="${MIN_FREE_GB:-20}"
MIN_TRACE="${MIN_TRACE:-160000000}"              # 55 M + 100 M and a 5 M margin
SIM=100000000
WINDOWS="${WINDOWS:-45000000 47500000 52500000 55000000}"
DONE_MARKER="ChampSim completed all CPUs"
die() { echo "ERROR: $*" >&2; exit 1; }
ts() { date '+%F %T'; }
alive() { [ -f "$1" ] && kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null; }
free_gb() { df -BG --output=avail "$S" | tail -1 | tr -dc 0-9; }

# class|reference tree|config prefix|policies
CLASSES='fixed|phaseA_b3_p2_canneal8|canneal8_shared|coalesce mockingjay srrip srrip_bias
scaled|phaseA_b3_p2_canneal8_scaled|canneal8_scaled_shared|srrip srrip_bias mockingjay ship'
cf() { echo "$CLASSES" | awk -F'|' -v c="$1" -v f="$2" '$1 == c { print $f }'; }
jobs() { local c w p; for c in fixed scaled; do for w in $WINDOWS; do for p in $(cf "$c" 4); do echo "$c|$w|$p"; done; done; done; }
wtag() { awk -v w="$1" 'BEGIN { s = sprintf("%g", w / 1e6); gsub(/\./, "p", s); print s }'; }
tree() { echo "phaseA_b3_h3w$(wtag "$2")_canneal8$([ "$1" = scaled ] && echo _scaled)"; }      # class w
ref_log() { echo "$S/results/$(cf "$1" 2)/regime_shared/canneal_8core/$2/run.log"; }           # class p
cfg_src() { echo "$POL_W/cfg/$(cf "$1" 3)_$2.json"; }                                           # class p
h_log() { echo "$S/results/$(tree "$1" "$2")/regime_shared/canneal_8core/$3/run.log"; }         # class w p
h_st() { echo "$W/state/$1_$(wtag "$2")_$3"; }
bin_g6() { cat "$POL_W/BIN" 2>/dev/null; }
h_done() { local f; f=$(h_log "$@"); grep -q "$DONE_MARKER" "$f" 2>/dev/null && [ "$(cat "$f.bin" 2>/dev/null)" = "$G6_NAME" ]; }

h_run() {   # class w p
  local c=$1 w=$2 p=$3 st ref cfg log B tr=() x
  st=$(h_st "$c" "$w" "$p"); mkdir -p "$st" "$W/cfg"; touch "$st/running"
  ref=$(ref_log "$c" "$p"); cfg="$W/cfg/${c}_$p.json"; log=$(h_log "$c" "$w" "$p"); B=$(bin_g6)
  cmp -s "$(cfg_src "$c" "$p")" "$cfg" || cp "$(cfg_src "$c" "$p")" "$cfg"
  while read -r x; do [ -s "$x" ] || { echo "no trace $x" > "$st/run_failed"; echo "$(ts) RUN FAILED $c $w $p: $(cat "$st/run_failed")"; rm -f "$st/running"; return 1; }; tr+=("$x")
  done < <(awk '/^CPU [0-9]+ runs / { print $2, $4 }' "$ref" | sort -n -k1,1 | awk '{ print $2 }')
  mkdir -p "$(dirname "$log")"; rm -f "$log.bin"; cp "$cfg" "$(dirname "$log")/config.json"
  echo "$(ts) RUN $c $w $p: $(basename "$B"), window $w + $SIM, ${#tr[@]} traces -> $(echo "$log" | sed "s|^$S/results/||")"
  ( cd "$S" && nice -n 19 "$B" --config "$cfg" --warmup-instructions "$w" --simulation-instructions "$SIM" "${tr[@]}" > "$log" 2>&1 )
  local rc=$?
  basename "$B" > "$log.bin"
  if grep -q "$DONE_MARKER" "$log"; then
    echo "$(ts) RUN END $c $w $p: complete; unexplained view-order violations $(grep -E '^LLC COHERENCE DIR VIEW-ORDER VIOLATIONS UNEXPLAINED:' "$log" | awk '{ s += $NF } END { print s + 0 }')"
  else
    echo "rc $rc: $(tail -1 "$log" | cut -c1-100)" > "$st/run_failed"; echo "$(ts) RUN FAILED $c $w $p: did not complete ($(cat "$st/run_failed"))"
  fi
  rm -f "$st/running"
}

h_chain() {
  echo $$ > "$W/.driver.pid"
  ps -o sid= -p $$ | tr -d ' ' > "$W/.sid"            # 'stop runs' ends this session: the runs
  rm -f "$W"/state/*/running                         # no H3 run is alive (the chain's check), so these are stale
  echo "$(ts) H3 CHAIN START (pid $$; $(jobs | wc -l) runs, $PAR at a time on $(basename "$(bin_g6)"))"
  local c w p st n open
  while :; do
    open=0; n=$(ls "$W"/state/*/running 2>/dev/null | wc -l)
    while IFS='|' read -r c w p; do
      st=$(h_st "$c" "$w" "$p")
      h_done "$c" "$w" "$p" && continue
      [ -f "$st/run_failed" ] && continue
      open=$((open + 1))
      [ -f "$st/running" ] && continue
      if [ "$n" -lt "$PAR" ] && [ "$(free_gb)" -ge "$MIN_FREE_GB" ]; then mkdir -p "$st"; touch "$st/running"; h_run "$c" "$w" "$p" & n=$((n + 1)); fi
    done < <(jobs)
    [ "$open" = 0 ] && break
    sleep "$CPOLL_S"
  done
  wait
  echo "$(ts) H3 CHAIN END"
  rm -f "$W/.driver.pid"
}

# the driver's session still holds an H3 run (matched inside awk: no `| grep -q` under pipefail)
session_alive() {
  local sid; sid=$(cat "$W/.sid" 2>/dev/null)
  [ -n "$sid" ] || return 1
  ps -u "$(id -u)" -o sid=,args= | awk -v s="$sid" '$1 == s && /h3_server\.sh __chain|--config [^ ]*\/h3\/cfg\// { n++ } END { exit !n }'
}

guards() {
  local bad=0 c p f t x n
  ok() { echo "   ok   $*"; }
  no() { echo "   FAIL $*"; bad=1; }
  f=$(bin_g6)
  [ "$(basename "$f")" = "$G6_NAME" ] && [ -x "$f" ] && [ "$(md5sum < "$f" | cut -c1-32)" = "$G6_MD5" ] \
    && ok "step 5's binary $G6_NAME (md5 ${G6_MD5:0:8})" || no "$POL_W/BIN does not name an executable $G6_NAME of md5 $G6_MD5"
  [ -s "$TRDIR/DONE" ] && ok "traces $TRDIR complete (DONE)" || no "no DONE in $TRDIR"
  n=0
  for x in 1 2 3 4 5 6 7 8; do
    t=$(awk '$1 == "T" { print $2 }' "$TRDIR/raw$x.mix" 2>/dev/null)
    [ -s "$TRDIR/raw$x.champsimtrace.xz" ] && [ "${t:-0}" -ge "$MIN_TRACE" ] && n=$((n + 1)) || no "trace raw$x: ${t:-no count} instructions (< $MIN_TRACE) or missing"
  done
  [ "$n" = 8 ] && ok "8 traces, each at least $MIN_TRACE instructions"
  for c in fixed scaled; do
    for p in $(cf "$c" 4); do
      f=$(ref_log "$c" "$p")
      if grep -q "$DONE_MARKER" "$f" 2>/dev/null && grep -q '^Warmup Instructions: 50000000$' "$f" && grep -q "^Simulation Instructions: $SIM$" "$f" \
         && grep -q '^Number of CPUs: 8$' "$f" \
         && [ "$(awk '/^CPU [0-9]+ runs / { print $2, $4 }' "$f" | sort -n -k1,1 | awk '{ printf "%s ", $2 }')" = "$(for x in 1 2 3 4 5 6 7 8; do printf '%s ' "$TRDIR/raw$x.champsimtrace.xz"; done)" ]; then
        ok "$c $p: reference $(cf "$c" 2) complete at 50 M + 100 M, 8 CPUs, traces raw1-8"
      else no "$c $p: reference $f incomplete, not 50 M + 100 M on 8 CPUs, or not traces raw1-8"; fi
      f=$(cfg_src "$c" "$p")
      python3 -c 'import json, sys; sys.exit(json.load(open(sys.argv[1]))["LLC"]["replacement"] != sys.argv[2])' "$f" "$p" 2>/dev/null \
        && ok "$c $p: config $f (LLC $p)" || no "$c $p: no config $f with LLC $p"
    done
  done
  alive "$W/.driver.pid" && no "the H3 driver is running (pid $(cat "$W/.driver.pid"))" || ok "no H3 driver running"
  [ -z "$(pgrep -u "$(id -u)" -f -- "[-]-config $W/cfg/" 2>/dev/null)" ] && ! session_alive && ok "no H3 run left" || no "an H3 run is running (an earlier chain's?)"
  t=$(free_gb); [ "${t:-0}" -ge "$MIN_FREE_GB" ] && ok "disk $t GB free" || no "disk $t GB free (< $MIN_FREE_GB)"
  return $bad
}

list() {
  local c w p st r
  while IFS='|' read -r c w p; do
    st=$(h_st "$c" "$w" "$p")
    if h_done "$c" "$w" "$p"; then r=complete; elif [ -f "$st/run_failed" ]; then r="FAILED ($(cat "$st/run_failed"))"; elif [ -f "$st/running" ]; then r=running; else r=pending; fi
    printf '   %-6s %-9s %-11s %s\n' "$c" "$w" "$p" "$r"
  done < <(jobs)
}

summary() {
  local c w p n=0 d=0 f=0 r=0
  while IFS='|' read -r c w p; do
    n=$((n + 1))
    if h_done "$c" "$w" "$p"; then d=$((d + 1)); elif [ -f "$(h_st "$c" "$w" "$p")/run_failed" ]; then f=$((f + 1)); elif [ -f "$(h_st "$c" "$w" "$p")/running" ]; then r=$((r + 1)); fi
  done < <(jobs)
  echo "   H3: $d of $n complete, $r running, $f failed"
}

case "${1:-}" in
  guards) echo "== H3 guards"; guards ;;
  list) list ;;
  chain)
    mkdir -p "$W/state" "$W/cfg"
    alive "$W/.driver.pid" && die "the H3 driver is running -- 'status'"
    echo "== guards"; guards || die "a guard failed (above) -- nothing started"
    before=$(grep -c 'H3 CHAIN END' "$W/driver.log" 2>/dev/null); before=${before:-0}
    setsid nohup bash "$SELF" __chain >> "$W/driver.log" 2>&1 < /dev/null &
    sleep 3
    if alive "$W/.driver.pid"; then echo "H3 driver started (pid $(cat "$W/.driver.pid")); log $W/driver.log"
    elif [ "$(grep -c 'H3 CHAIN END' "$W/driver.log" 2>/dev/null)" -gt "$before" ]; then echo "H3 driver ran and ended at once (nothing left to run)"
    else die "the H3 driver did not start: $(tail -2 "$W/driver.log" 2>/dev/null)"; fi ;;
  __chain) h_chain ;;
  status)
    echo "== H3: driver $(alive "$W/.driver.pid" && echo alive || echo "not running")"
    summary
    tail -3 "$W/driver.log" 2>/dev/null | sed 's/^/   /' ;;
  stop)
    if alive "$W/.driver.pid"; then kill "$(cat "$W/.driver.pid")"; rm -f "$W/.driver.pid"; echo "driver stopped"; fi
    if [ "${2:-}" = runs ]; then
      t0=$(date +%s)
      if session_alive; then pkill -u "$(id -u)" -s "$(cat "$W/.sid")" && echo "ended the driver's session $(cat "$W/.sid")"; fi
      pgrep -u "$(id -u)" -f -- "[-]-config $W/cfg/" | while read -r x; do kill "$x" && echo "ended pid $x (H3 ChampSim)"; done
      sleep 2   # a failure mark written as the stop ended a run is the stop's, not a failure: the next chain redoes it
      find "$W/state" -name run_failed -newermt "@$t0" 2>/dev/null | while read -r f; do
        rm -f "$f"; echo "cleared $(basename "$(dirname "$f")")/run_failed (written as the stop ended it)"; done
    fi ;;
  *) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
