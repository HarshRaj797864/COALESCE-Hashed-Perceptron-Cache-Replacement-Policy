#!/usr/bin/env bash
# H2 (bench/policy_sanity/calibration_design_2026-11-14.md), server side: the
# band's noise floor on ocean 2 MB, canneal 4c 2 MB, lunc and fluidanimate.
#
#   (a) gem5: static_backend_latency 8, 9, 11, 12 ns, both stops (32 runs),
#       through a copy of run_gem5_splash.sh with GEM5_PARAMS (~/gem5_cal); the
#       live ~/run_gem5_splash.sh, ~/gem5/configs and the gem5 binary are not
#       touched. Output ~/gem5_b3/cal/<program>/b<n>ns/l2_2MB_mi<stop>M/<tag>.
#       QV0 on each run's config.ini (a failure stops launching), QV1 at its end.
#   (b) each program re-traced 5 times by its own procedure (~/cal/sync_server_cal.sh
#       trace1: traces/cal/r<k>/<program>/), each re-trace replayed on the F-C
#       binary with the F-C reference's config and window into
#       results/phaseA_b3_cal<k>_<suffix>/regime_shared/<wl>_4core/lru/run.log.
#
#   bash ~/cal/cal_server.sh guards          # read-only checks of both halves
#   bash ~/cal/cal_server.sh list            # every job and its state
#   bash ~/cal/cal_server.sh chain           # (owner's word) guards, then both drivers, detached
#   bash ~/cal/cal_server.sh status
#   bash ~/cal/cal_server.sh stop [runs]     # both drivers; with 'runs', H2's gem5, Pin and ChampSim processes too
set -uo pipefail
SELF="$(readlink -f "$0")"
R="${R:-$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy}"
S="$R/simulator"
GW="${GW:-$HOME/gem5_cal}"            # gem5 half: run_gem5_splash.sh copy, cal_score.py, its driver
TW="${TW:-$HOME/cal}"                 # trace half: sync_server_cal.sh, its driver
OUTROOT="${OUTROOT:-$HOME/gem5_b3/cal}"
B3="${B3:-$HOME/gem5_b3}"
TROOT="${TROOT:-$S/traces/cal}"
GEM5_DIR="${GEM5_DIR:-$HOME/gem5}"
GEM5_TAG="${GEM5_TAG:-v25.1.0.1}"
FC_W="${FC_W:-$HOME/sync_fc}"
FC_MD5="${FC_MD5:-a2e88e46788e1f332427567a19bc2f90}"
PAR_G="${PAR_G:-8}"                   # gem5 runs at once
PAR_C="${PAR_C:-4}"                   # ChampSim replays at once
TPAR="${TPAR:-2}"                     # programs traced at once
LIMIT_S="${LIMIT_S:-$((96 * 3600))}"  # a gem5 run past this is ended: OTHER
QV0_WAIT_S="${QV0_WAIT_S:-900}"
POLL_S="${POLL_S:-300}"
TPOLL_S="${TPOLL_S:-60}"
MIN_FREE_GB="${MIN_FREE_GB:-20}"
LATS="${LATS:-8 9 11 12}"
KS="${KS:-1 2 3 4 5}"
DONE_MARKER="ChampSim completed all CPUs"
EXIT_OK='because a thread reached the max instruction count'
ONLY="${ONLY:-}"                      # e.g. ONLY="ocean4 lunc": only those programs (rehearsal)
die() { echo "ERROR: $*" >&2; exit 1; }
ts() { date '+%F %T'; }
alive() { [ -f "$1" ] && kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null; }
free_gb() { df -BG --output=avail "$S" | tail -1 | tr -dc 0-9; }

# program|gem5 150 M original|gem5 50 M original|mode|settings|stop variable|variant|reference trace set|F-C tree|workload|length a thread|tracer
TABLE="${CAL_TABLE:-}"   # a rehearsal sets its own; otherwise the design's four:
[ -n "$TABLE" ] || TABLE='ocean4|l2_2MB_mi150M/ocean_4c|l2_2MB_mi50M/ocean_4c|go-ocean-4c|LLC_SIZE=2MB|MAXINSTS|mx|sync_mx/ocean4|phaseA_b3_fc_g3_ocean4|ocean|215000000|@HOME@/sync_mx_build/simulator/tracer/pin/obj-intel64/champsim_tracer.so
canneal4|canneal/l2_2MB_mi150M/canneal_4c|canneal/l2_2MB_mi50M/canneal_4c|go-canneal-4c|LLC_SIZE=2MB|WORKER_MAXINSTS|mx|sync_mx/canneal4|phaseA_b3_fc_g3_canneal4|canneal|215000000|@HOME@/sync_mx_build/simulator/tracer/pin/obj-intel64/champsim_tracer.so
lunc|newbench/lunc/l2_2MB_mi150M/lunc_4c|newbench/lunc/l2_2MB_mi50M/lunc_4c|go-lunc-4c|LLC_SIZE=2MB BINS=@HOME@/splash-newbench|WORKER_MAXINSTS|nb|sync_nb/lunc|phaseA_b3_fc_n2_lunc4|lunc|310000000|@HOME@/sync_g5_build/simulator/tracer/pin/obj-intel64/champsim_tracer.so
fluidanimate|heldout2/fluidanimate/l2_2MB_mi150M/fluidanimate_4c|heldout2/fluidanimate/l2_2MB_mi50M/fluidanimate_4c|go-fluidanimate-4c|LLC_SIZE=2MB BINS=@HOME@/heldout2_static|WORKER_MAXINSTS|h2|sync_h2/fluidanimate|phaseA_b3_fc_h2_fluidanimate4|fluidanimate|215000000|@HOME@/sync_nc_build/simulator/tracer/pin/obj-intel64/champsim_tracer.so'
VW_mx="$HOME/sync_mx"; VW_nb="$HOME/sync_nb"; VW_h2="$HOME/sync_h2"   # each variant's state (trace_mix; h2: gem5.cpuid)

table() { echo "$TABLE" | sed "s|@HOME@|$HOME|g" | while IFS='|' read -r p rest; do
  [ -z "$ONLY" ] || [[ " $ONLY " == *" $p "* ]] || continue; echo "$p|$rest"; done; }
tf() { table | awk -F'|' -v p="$1" -v f="$2" '$1 == p { print $f }'; }   # program field
progs() { table | cut -d'|' -f1; }

# ---------------------------------------------------------------- (a) gem5
gjobs() {   # program|lat|stop, the 150 M stops first
  local stop p l; for stop in 150 50; do for p in $(progs); do for l in $LATS; do echo "$p|$l|$stop"; done; done; done; }
g_orig() { if [ "$3" = 150 ]; then tf "$1" 2; else tf "$1" 3; fi; }          # p lat stop
g_odir() { echo "$OUTROOT/$1/b$2ns/l2_2MB_mi$3M/$(basename "$(g_orig "$1" "$2" "$3")")"; }
g_st() { echo "$GW/state/$1_b$2_$3"; }
g_result() { cat "$(g_st "$1" "$2" "$3")/RESULT" 2>/dev/null; }
gem5_pid() { pgrep -u "$(id -u)" -f "[g]em5.opt --outdir=$1 " 2>/dev/null | head -1; }

g_launch() {   # p lat stop
  local p=$1 l=$2 stop=$3 st env sv
  st=$(g_st "$p" "$l" "$stop"); mkdir -p "$st"
  env=$(tf "$p" 5); sv=$(tf "$p" 6)
  echo "$(ts) LAUNCH $p ${l} ns, stop ${stop} M: $(tf "$p" 4) $env $sv=${stop}000000"
  # shellcheck disable=SC2086 -- $env is a list of assignments
  ( cd "$HOME" && env OUT="$OUTROOT/$p/b${l}ns/l2_2MB_mi${stop}M" GEM5_PARAMS="system.mem_ctrls[0].static_backend_latency = '${l}ns'" \
      OCEAN_GRID=514 $env "$sv=${stop}000000" bash "$GW/run_gem5_splash.sh" "$(tf "$p" 4)" ) > "$st/launch.log" 2>&1
  local rc=$?
  sed 's/^/      /' "$st/launch.log"
  return $rc
}

g_settle() {   # classify every started run whose gem5 has ended; end runs past the limit
  local p l stop st od pid t0 line
  while IFS='|' read -r p l stop; do
    st=$(g_st "$p" "$l" "$stop"); od=$(g_odir "$p" "$l" "$stop")
    [ -f "$st/STARTED" ] && [ -z "$(g_result "$p" "$l" "$stop")" ] || continue
    pid=$(gem5_pid "$od")
    if [ -n "$pid" ]; then
      t0=$(cat "$st/STARTED")
      if [ $(( $(date +%s) - t0 )) -gt "$LIMIT_S" ]; then kill "$pid"; echo "$(ts) $p $l ns $stop M: past the limit -- ended"; sleep 5; else continue; fi
    fi
    line=$(python3 "$GW/cal_score.py" qv1 "$od" 1 2>&1 | tail -1)
    echo "${line#QV1 }" > "$st/RESULT"
    echo "$(ts) $p $l ns $stop M: ${line#QV1 }"
  done < <(gjobs)
}

g_running() { local n=0 p l stop; while IFS='|' read -r p l stop; do [ -n "$(gem5_pid "$(g_odir "$p" "$l" "$stop")")" ] && n=$((n + 1)); done < <(gjobs); echo "$n"; }

g_chain() {
  echo $$ > "$GW/.driver.pid"
  echo "$(ts) GEM5 CHAIN START (pid $$; $(gjobs | wc -l) runs, $PAR_G at a time; limit ${LIMIT_S}s)"
  local stop_launching=0 p l stop st od waited pid line
  # runs started under an earlier driver that ended while no driver ran: one that reached its stop is
  # classified; any other (ended by 'stop runs', or killed) is launched again, never classified from a
  # partial directory (found in the rehearsal: g_settle would have written the killed run's state as
  # its RESULT and kept it from being launched again)
  while IFS='|' read -r p l stop; do
    st=$(g_st "$p" "$l" "$stop"); od=$(g_odir "$p" "$l" "$stop")
    [ -f "$st/STARTED" ] && [ -z "$(g_result "$p" "$l" "$stop")" ] && [ -z "$(gem5_pid "$od")" ] || continue
    line=$(python3 "$GW/cal_score.py" qv1 "$od" 1 2>&1 | tail -1)
    case "$line" in
      "QV1 ENDED-AT-STOP"*) echo "${line#QV1 }" > "$st/RESULT"; echo "$(ts) $p $l ns $stop M: ended while no driver ran: ${line#QV1 }" ;;
      *) rm -f "$st/STARTED"; echo "$(ts) $p $l ns $stop M: ended while no driver ran, not at its stop (${line#QV1 }) -- to be launched again" ;;
    esac
  done < <(gjobs)
  while IFS='|' read -r p l stop; do
    st=$(g_st "$p" "$l" "$stop"); od=$(g_odir "$p" "$l" "$stop")
    [ -z "$(g_result "$p" "$l" "$stop")" ] || { echo "$(ts) SKIP $p $l ns $stop M: $(g_result "$p" "$l" "$stop")"; continue; }
    if [ -n "$(gem5_pid "$od")" ]; then   # a run from before a restart: checked and classified like the rest
      mkdir -p "$st"
      if [ ! -f "$st/STARTED" ]; then
        python3 "$GW/cal_score.py" qv0 "$B3/$(g_orig "$p" "$l" "$stop")" "$od" "system.mem_ctrls:static_backend_latency=${l}000" > "$st/qv0.txt" 2>&1 \
          || { echo "$(ts) $p $l ns $stop M: running, but QV0 FAILED -- launching stops"; stop_launching=1; }
        date +%s > "$st/STARTED"
      fi
      echo "$(ts) $p $l ns $stop M: already running -- left alone ($(tail -1 "$st/qv0.txt" 2>/dev/null))"; continue
    fi
    while :; do                     # count the live runs FIRST, then classify, then decide
      local running; running=$(g_running)
      g_settle
      [ "$stop_launching" = 0 ] || break
      [ "$running" -lt "$PAR_G" ] && break
      sleep "$POLL_S"
    done
    if [ "$stop_launching" != 0 ]; then mkdir -p "$st"; echo "NOT RUN (the chain stopped launching)" > "$st/RESULT"; continue; fi
    rm -f "$st/STARTED"
    if ! g_launch "$p" "$l" "$stop"; then
      echo "LAUNCH-FAILED" > "$st/RESULT"; echo "$(ts) $p $l ns $stop M: LAUNCH FAILED -- launching stops"; stop_launching=1; continue
    fi
    waited=0
    while [ ! -s "$od/config.ini" ] && [ "$waited" -lt "$QV0_WAIT_S" ]; do sleep 10; waited=$((waited + 10)); done
    sleep 5
    if python3 "$GW/cal_score.py" qv0 "$B3/$(g_orig "$p" "$l" "$stop")" "$od" "system.mem_ctrls:static_backend_latency=${l}000" > "$st/qv0.txt" 2>&1; then
      echo "$(ts) $p $l ns $stop M: $(tail -1 "$st/qv0.txt")"
      date +%s > "$st/STARTED"
    else
      sed 's/^/      /' "$st/qv0.txt"
      pid=$(gem5_pid "$od"); [ -z "$pid" ] || kill "$pid"
      echo "VOID (QV0 failed: $(tail -1 "$st/qv0.txt"))" > "$st/RESULT"
      echo "$(ts) $p $l ns $stop M: QV0 FAILED -- run ended, launching stops"; stop_launching=1
    fi
  done < <(gjobs)
  echo "$(ts) GEM5: ALL LAUNCHED OR SKIPPED; waiting for the runs"
  while :; do
    g_settle
    local open=0
    while IFS='|' read -r p l stop; do [ -n "$(g_result "$p" "$l" "$stop")" ] || open=$((open + 1)); done < <(gjobs)
    [ "$open" = 0 ] && break
    sleep "$POLL_S"
  done
  echo "$(ts) GEM5 CHAIN END"
  rm -f "$GW/.driver.pid"
}

# ---------------------------------------------------------------- (b) traces and replays
tjobs() { local k p; for k in $KS; do for p in $(progs); do echo "$k|$p"; done; done; }
t_dir() { echo "$TROOT/r$1/$2"; }                                              # k p
t_st() { echo "$TW/state/r$1_$2"; }
suffix_of() { local t; t=$(tf "$1" 9); echo "${t##*_}"; }                      # ocean4, canneal4, lunc4, fluidanimate4
fc_log() { echo "$S/results/$(tf "$1" 9)/regime_shared/$(tf "$1" 10)_4core/lru/run.log"; }
c_log() { echo "$S/results/phaseA_b3_cal$1_$(suffix_of "$2")/regime_shared/$(tf "$2" 10)_4core/lru/run.log"; }   # k p
bin_fc() { cat "$FC_W/BIN" 2>/dev/null; }
t_done() { [ -f "$(t_dir "$1" "$2")/DONE" ]; }
c_done() { local f; f=$(c_log "$1" "$2"); grep -q "$DONE_MARKER" "$f" 2>/dev/null && [ "$(cat "$f.bin" 2>/dev/null)" = "$(basename "$(bin_fc)")" ]; }

t_trace() {   # k p -- one re-trace (run in the background; markers in its state directory)
  local k=$1 p=$2 st; st=$(t_st "$k" "$p"); mkdir -p "$st"
  touch "$st/tracing"
  echo "$(ts) TRACE r$k $p: VARIANT=$(tf "$p" 7), $(tf "$p" 11) a thread -> $(t_dir "$k" "$p")"
  VARIANT=$(tf "$p" 7) TDIR="$TROOT/r$k" LEN_OVERRIDE=$(tf "$p" 11) MIN_FREE_GB="$MIN_FREE_GB" \
    bash "$TW/sync_server_cal.sh" trace1 "$p" > "$st/trace.log" 2>&1
  local rc=$?
  if [ "$rc" = 0 ] && t_done "$k" "$p"; then
    echo "$(ts) TRACED r$k $p: $(grep -E 'traced \(' "$st/trace.log" | tail -1 | sed 's/^.*traced/traced/')"
  else
    echo "rc $rc: $(grep -E 'FAILED|ERROR' "$st/trace.log" | tail -1)" > "$st/trace_failed"
    echo "$(ts) TRACE FAILED r$k $p ($(cat "$st/trace_failed")) -- reported, not repeated"
  fi
  rm -f "$st/tracing"
}

c_run() {   # k p -- the re-trace's replay on the F-C binary
  local k=$1 p=$2 st ref log cfg wu si B tr=() x y
  st=$(t_st "$k" "$p"); mkdir -p "$st"; touch "$st/running"
  ref=$(fc_log "$p"); log=$(c_log "$k" "$p"); cfg="$FC_W/cfg/$p.json"; B=$(bin_fc)
  wu=$(awk '/^Warmup Instructions:/ { print $3; exit }' "$ref"); si=$(awk '/^Simulation Instructions:/ { print $3; exit }' "$ref")
  while read -r x; do
    y="${x/"$S/traces/$(tf "$p" 8)/"/"$(t_dir "$k" "$p")/"}"
    [ "$y" != "$x" ] && [ -s "$y" ] || { echo "no trace for $x in r$k" > "$st/run_failed"; echo "$(ts) RUN FAILED r$k $p: $(cat "$st/run_failed")"; rm -f "$st/running"; return 1; }
    tr+=("$y")
  done < <(awk '/^CPU [0-9]+ runs / { print $2, $4 }' "$ref" | sort -n -k1,1 | awk '{ print $2 }')
  mkdir -p "$(dirname "$log")"; rm -f "$log.bin"
  echo "$(ts) RUN r$k $p: $(basename "$B"), window $wu + $si, ${#tr[@]} traces -> $(basename "$(dirname "$(dirname "$(dirname "$(dirname "$log")")")")")"
  ( cd "$S" && nice -n 19 "$B" --config "$cfg" --warmup-instructions "$wu" --simulation-instructions "$si" "${tr[@]}" > "$log" 2>&1 )
  local rc=$?
  basename "$B" > "$log.bin"
  if grep -q "$DONE_MARKER" "$log"; then
    echo "$(ts) RUN END r$k $p: complete; unexplained view-order violations $(grep -E '^LLC COHERENCE DIR VIEW-ORDER VIOLATIONS UNEXPLAINED:' "$log" | awk '{ s += $NF } END { print s + 0 }')"
  else
    echo "rc $rc: $(tail -1 "$log" | cut -c1-100)" > "$st/run_failed"; echo "$(ts) RUN FAILED r$k $p: did not complete ($(cat "$st/run_failed"))"
  fi
  rm -f "$st/running"
}

t_chain() {
  echo $$ > "$TW/.driver.pid"
  ps -o sid= -p $$ | tr -d ' ' > "$TW/.sid"         # 'stop runs' ends this session: the re-traces' Pin and xz, the replays
  rm -f "$TW"/state/*/tracing "$TW"/state/*/running   # no H2 Pin or ChampSim process runs (the chain's check), so these are stale
  echo "$(ts) TRACE CHAIN START (pid $$; $(tjobs | wc -l) re-traces, $TPAR at a time; replays $PAR_C at a time on $(basename "$(bin_fc)"))"
  local k p st nt nc open
  while :; do
    open=0
    nt=$(ls "$TW"/state/*/tracing 2>/dev/null | wc -l); nc=$(ls "$TW"/state/*/running 2>/dev/null | wc -l)
    while IFS='|' read -r k p; do
      st=$(t_st "$k" "$p")
      if ! t_done "$k" "$p"; then
        [ -f "$st/trace_failed" ] && continue
        open=$((open + 1))
        [ -f "$st/tracing" ] && continue
        if [ "$nt" -lt "$TPAR" ] && [ "$(free_gb)" -ge "$MIN_FREE_GB" ]; then mkdir -p "$st"; touch "$st/tracing"; t_trace "$k" "$p" & nt=$((nt + 1)); fi
        continue
      fi
      c_done "$k" "$p" && continue
      [ -f "$st/run_failed" ] && continue
      open=$((open + 1))
      [ -f "$st/running" ] && continue
      if [ "$nc" -lt "$PAR_C" ] && [ "$(free_gb)" -ge "$MIN_FREE_GB" ]; then mkdir -p "$st"; touch "$st/running"; c_run "$k" "$p" & nc=$((nc + 1)); fi
    done < <(tjobs)
    [ "$open" = 0 ] && break
    sleep "$TPOLL_S"
  done
  wait
  echo "$(ts) TRACE CHAIN END"
  rm -f "$TW/.driver.pid"
}

# the trace driver's session still holds an H2 process (its .sid, checked by what runs in it).
# The match is made inside awk, which reads all of ps's output: a `| grep -q` here exits at its
# first match, and under pipefail awk's SIGPIPE then made the test false (found in the rehearsal:
# `stop runs` left the session's Pin, xz and replays running).
t_session_alive() {
  local sid; sid=$(cat "$TW/.sid" 2>/dev/null)
  [ -n "$sid" ] || return 1
  ps -u "$(id -u)" -o sid=,args= | awk -v s="$sid" '$1 == s && /cal_server\.sh __t|sync_server_cal\.sh|traces\/cal\/|pin -t/ { n++ } END { exit !n }'
}

# ---------------------------------------------------------------- guards
guards() {
  local bad=0 p t f g bin v tr d len n
  ok() { echo "   ok   $*"; }
  no() { echo "   FAIL $*"; bad=1; }
  echo "-- (a) gem5"
  [ "$(git -C "$GEM5_DIR" describe --tags 2>/dev/null)" = "$GEM5_TAG" ] && ok "gem5 at $GEM5_TAG" || no "gem5 is not at $GEM5_TAG"
  t=$(git -C "$GEM5_DIR" status --porcelain 2>/dev/null | LC_ALL=C sort | tr '\n' ';')
  [ "$t" = " M configs/ruby/MESI_Three_Level.py;?? .gem5_protocol;?? configs/ruby/MESI_Three_Level.py.orig_fifo;" ] \
    && ok "the live gem5 tree differs from $GEM5_TAG only by the FIFO patch (as for the originals)" || no "the live gem5 tree has other changes: $t"
  [ "$(grep -c 'COALESCE: setup_gem5.sh patch-fifo' "$GEM5_DIR/configs/ruby/MESI_Three_Level.py")" = 2 ] && ok "the live config is patched, as the originals ran" || no "the live config is not patched"
  grep -q '^GEM5_PARAMS=' "$GW/run_gem5_splash.sh" 2>/dev/null && bash -n "$GW/run_gem5_splash.sh" && ok "H2's run_gem5_splash.sh copy has GEM5_PARAMS" || no "no usable $GW/run_gem5_splash.sh"
  python3 -m py_compile "$GW/cal_score.py" 2>/dev/null && ok "cal_score.py compiles" || no "no usable $GW/cal_score.py"
  bin="$GEM5_DIR/build/$(cat "$GEM5_DIR/.gem5_build_dir" 2>/dev/null || echo X86)/gem5.opt"
  [ -x "$bin" ] && ok "gem5 binary $(stat -c '%y' "$bin" | cut -c1-16)" || no "no gem5 binary"
  for p in $(progs); do
    for f in "$(tf "$p" 2)" "$(tf "$p" 3)"; do
      if [ -f "$B3/$f/config.ini" ] && grep -q '^finalTick' "$B3/$f/stats.txt" 2>/dev/null && grep -q "$EXIT_OK" "$B3/$f/run.log" 2>/dev/null \
         && [ "$bin" -ot "$B3/$f/config.ini" ] \
         && [ "$(awk '/^\[/ { s = $0 } s == "[system.mem_ctrls]" && /^static_backend_latency=/' "$B3/$f/config.ini")" = static_backend_latency=10000 ]; then
        ok "$p: original $f ended at its stop, after the binary, at 10 ns"
      else no "$p: original $f incomplete, older than the binary, or not at static_backend_latency=10000"; fi
    done
  done
  alive "$GW/.driver.pid" && no "an H2 gem5 driver is running (pid $(cat "$GW/.driver.pid"))" || ok "no H2 gem5 driver running"
  echo "-- (b) traces and replays"
  [ -f "$TW/sync_server_cal.sh" ] && grep -q 'trace1)' "$TW/sync_server_cal.sh" && bash -n "$TW/sync_server_cal.sh" \
    && ok "sync_server_cal.sh has trace1" || no "no usable $TW/sync_server_cal.sh"
  for f in "$HOME/sync_anchor.py" "$HOME/sync_cut.py"; do [ -s "$f" ] && ok "$(basename "$f")" || no "no $f"; done
  for p in $(progs); do
    v=$(tf "$p" 7); tr=$(tf "$p" 12); d="$S/traces/$(tf "$p" 8)"; len=$(tf "$p" 11)
    eval "w=\$VW_$v"
    [ -f "$d/DONE" ] && [ "$(md5sum < "$tr" 2>/dev/null | cut -c1-32)" = "$(cat "$d/DONE")" ] \
      && ok "$p: tracer $(cut -c1-8 "$d/DONE") = the reference set's" || no "$p: tracer $tr is not the one in $d/DONE"
    [ -x "$w/trace_mix" ] && ok "$p: $w/trace_mix" || no "$p: no $w/trace_mix"
    if [ "$v" = h2 ]; then
      [ "$(md5sum < "$w/gem5.cpuid" 2>/dev/null | cut -c1-32)" = "$(cat "$d/CPUID" 2>/dev/null)" ] && ok "$p: gem5's CPUID file = the reference's ($(cut -c1-8 "$d/CPUID"))" || no "$p: CPUID file differs from $d/CPUID"
    fi
    if [ -s "$d/LEN" ]; then n=$(cat "$d/LEN"); else n=$(awk '$1 == "T" { print $2 - $NF }' "$(ls "$d"/raw*.mix | head -1)"); fi
    [ "$n" = "$len" ] && ok "$p: length $len a thread = the reference's" || no "$p: length $len, the reference's $n"
    local line pb pin pfiles; line=$(VARIANT="$v" bash "$TW/sync_server_cal.sh" progline "$p" 2>/dev/null)
    pb=$(echo "$line" | cut -d'|' -f2); pin=$(echo "$line" | cut -d'|' -f4); pfiles=$(echo "$line" | cut -d'|' -f5)
    [ -n "$line" ] && [ -x "$pb" ] && [ "$pb" -ot "$d/DONE" ] && ok "$p: program $(basename "$pb") older than the reference set" || no "$p: program '$pb' missing or newer than $d/DONE"
    for f in $pin $pfiles; do [ -e "$f" ] || no "$p: input $f missing"; done
    [ -f "$(fc_log "$p")" ] && grep -q "$DONE_MARKER" "$(fc_log "$p")" && grep -q '^SYNC LOCK WORD: request$' "$(fc_log "$p")" \
      && ok "$p: F-C reference $(tf "$p" 9) complete" || no "$p: no complete F-C reference $(fc_log "$p")"
    grep -q '"sync_lock_word": "request"' "$FC_W/cfg/$p.json" 2>/dev/null && ok "$p: F-C config $FC_W/cfg/$p.json" || no "$p: no F-C config $FC_W/cfg/$p.json"
  done
  bin=$(bin_fc)
  [ -x "$bin" ] && [ "$(md5sum < "$bin" | cut -c1-32)" = "$FC_MD5" ] && ok "F-C binary $(basename "$bin")" || no "the F-C binary is not md5 $FC_MD5"
  for f in Q0_PASSED Q0M_PASSED Q0R_PASSED K0_PASSED; do [ -f "$FC_W/$f" ] || no "F-C's $f missing"; done
  [ -x "${PIN_ROOT:-$S/tracer/pin/pin-external-3.31-98869-gfa6f126a8-gcc-linux}/pin" ] && ok "Pin" || no "no Pin"
  alive "$TW/.driver.pid" && no "an H2 trace driver is running (pid $(cat "$TW/.driver.pid"))" || ok "no H2 trace driver running"
  [ -z "$(pgrep -u "$(id -u)" -f "[t]races/cal/|[s]ync_server_cal.sh" 2>/dev/null)" ] && ! t_session_alive \
    && ok "no re-trace or replay process left" || no "a re-trace or replay process is running (an earlier chain's?)"
  t=$(free_gb); [ "${t:-0}" -ge "$MIN_FREE_GB" ] && ok "disk $t GB free" || no "disk $t GB free (< $MIN_FREE_GB)"
  return $bad
}

# ---------------------------------------------------------------- report
list() {
  local p l stop r k st
  echo "-- (a) gem5 ($OUTROOT)"
  while IFS='|' read -r p l stop; do
    r=$(g_result "$p" "$l" "$stop")
    if [ -z "$r" ]; then
      if [ -n "$(gem5_pid "$(g_odir "$p" "$l" "$stop")")" ]; then r="running $(( ($(date +%s) - $(cat "$(g_st "$p" "$l" "$stop")/STARTED" 2>/dev/null || date +%s)) / 3600 )) h"; else r=pending; fi
    fi
    printf '   %-13s %2s ns %3s M  %s\n' "$p" "$l" "$stop" "$r"
  done < <(gjobs)
  echo "-- (b) re-traces and replays ($TROOT)"
  while IFS='|' read -r k p; do
    st=$(t_st "$k" "$p")
    if t_done "$k" "$p"; then r="traced"; elif [ -f "$st/trace_failed" ]; then r="TRACE FAILED ($(cat "$st/trace_failed"))"; elif [ -f "$st/tracing" ]; then r=tracing; else r=pending; fi
    if c_done "$k" "$p"; then r="$r; replay complete"; elif [ -f "$st/run_failed" ]; then r="$r; REPLAY FAILED"; elif [ -f "$st/running" ]; then r="$r; replaying"; fi
    printf '   r%s %-13s %s\n' "$k" "$p" "$r"
  done < <(tjobs)
}

summary() {
  local gd=0 gn=0 td=0 cd=0 tn=0 p l stop k
  while IFS='|' read -r p l stop; do gn=$((gn + 1)); [ -z "$(g_result "$p" "$l" "$stop")" ] || gd=$((gd + 1)); done < <(gjobs)
  while IFS='|' read -r k p; do tn=$((tn + 1)); t_done "$k" "$p" && td=$((td + 1)); c_done "$k" "$p" && cd=$((cd + 1)); done < <(tjobs)
  echo "   gem5 $gd of $gn ended ($(g_running) running); re-traces $td of $tn; replays $cd of $tn complete"
}

case "${1:-}" in
  guards) echo "== H2 guards"; guards ;;
  list) list ;;
  chain)
    mkdir -p "$GW/state" "$TW/state" "$OUTROOT" "$TROOT"
    alive "$GW/.driver.pid" && die "the H2 gem5 driver is running -- 'status'"
    alive "$TW/.driver.pid" && die "the H2 trace driver is running -- 'status'"
    echo "== guards"; guards || die "a guard failed (above) -- nothing started"
    ge=$(grep -c 'GEM5 CHAIN END' "$GW/driver.log" 2>/dev/null); ge=${ge:-0}
    te=$(grep -c 'TRACE CHAIN END' "$TW/driver.log" 2>/dev/null); te=${te:-0}
    setsid nohup bash "$SELF" __g >> "$GW/driver.log" 2>&1 < /dev/null &
    setsid nohup bash "$SELF" __t >> "$TW/driver.log" 2>&1 < /dev/null &
    sleep 3
    okd=0   # a driver counts as started if it is alive, or ran and ended at once (nothing left to do)
    if alive "$GW/.driver.pid"; then echo "gem5 driver started (pid $(cat "$GW/.driver.pid")); log $GW/driver.log"; okd=$((okd + 1))
    elif [ "$(grep -c 'GEM5 CHAIN END' "$GW/driver.log" 2>/dev/null)" -gt "$ge" ]; then echo "gem5 driver ran and ended at once (nothing left to run)"; okd=$((okd + 1))
    else echo "gem5 driver NOT started: $(tail -2 "$GW/driver.log" 2>/dev/null)"; fi
    if alive "$TW/.driver.pid"; then echo "trace driver started (pid $(cat "$TW/.driver.pid")); log $TW/driver.log"; okd=$((okd + 1))
    elif [ "$(grep -c 'TRACE CHAIN END' "$TW/driver.log" 2>/dev/null)" -gt "$te" ]; then echo "trace driver ran and ended at once (nothing left to run)"; okd=$((okd + 1))
    else echo "trace driver NOT started: $(tail -2 "$TW/driver.log" 2>/dev/null)"; fi
    [ "$okd" = 2 ] || die "a driver did not start (above)" ;;
  __g) g_chain ;;
  __t) t_chain ;;
  status)
    echo "== H2 (calibration): gem5 driver $(alive "$GW/.driver.pid" && echo "alive (pid $(cat "$GW/.driver.pid"))" || echo "not running"); trace driver $(alive "$TW/.driver.pid" && echo "alive (pid $(cat "$TW/.driver.pid"))" || echo "not running")"
    summary
    tail -3 "$GW/driver.log" 2>/dev/null | sed 's/^/   g: /'
    tail -3 "$TW/driver.log" 2>/dev/null | sed 's/^/   t: /' ;;
  stop)
    for f in "$GW/.driver.pid" "$TW/.driver.pid"; do
      if alive "$f"; then kill "$(cat "$f")"; rm -f "$f"; echo "driver stopped ($f)"; fi
    done
    if [ "${2:-}" = runs ]; then
      t0=$(date +%s)
      pgrep -u "$(id -u)" -f "[g]em5.opt --outdir=$OUTROOT/" | while read -r x; do kill "$x" && echo "ended gem5 pid $x"; done
      if t_session_alive; then pkill -u "$(id -u)" -s "$(cat "$TW/.sid")" && echo "ended the trace driver's session $(cat "$TW/.sid") (Pin, xz, replays)"; fi
      pgrep -u "$(id -u)" -f "[t]races/cal/" | while read -r x; do kill "$x" && echo "ended pid $x (traces/cal)"; done
      sleep 2   # a failure mark written as the stop ended a run is the stop's, not a failure: the next chain redoes it
      find "$TW/state" \( -name run_failed -o -name trace_failed \) -newermt "@$t0" 2>/dev/null | while read -r f; do
        rm -f "$f"; echo "cleared $(basename "$(dirname "$f")")/$(basename "$f") (written as the stop ended it)"; done
    fi ;;
  *) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
