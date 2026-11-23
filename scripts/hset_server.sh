#!/usr/bin/env bash
# H4 and H5 (bench/policy_sanity/gem5_settings_design_2026-11-14.md), server side.
#
#   H4: gem5's shared L2 with LRURP / BRRIPRP(btp=0, hit_priority) /
#       DRRIPRP(512, 16; BRRIP btp=3 / RRIP, hit_priority) on ocean 2 MB,
#       canneal 4c 2 MB, lunc and radix, both stops (24 runs, PAR4 at a time),
#       through H2's copy of run_gem5_splash.sh (~/gem5_cal: GEM5_PARAMS); QH0 on
#       each config.ini (a failure stops launching H4); and ChampSim srrip / drrip
#       on the F-C binary with the F-C reference's config (only LLC.replacement
#       changed), window and traces (8 runs, PARC at a time) into
#       results/phaseA_b3_hs_<setting>_<suffix>/regime_shared/<wl>_4core/<setting>/run.log.
#   H5: gem5 with CPU_TYPE=X86O3CPU on ocean 2 MB, canneal 4c 2 MB, fluidanimate
#       and vips, both stops (8 runs, PAR5 at a time); QO0 (a failure stops
#       launching H5).
#   gem5 output ~/gem5_b3/hset/<setting>/<program>/l2_2MB_mi<stop>M/<tag>; state ~/hset.
#   The live ~/run_gem5_splash.sh, ~/gem5/configs and the gem5 binary are not touched.
#
#   bash ~/hset/hset_server.sh guards        # read-only
#   bash ~/hset/hset_server.sh list          # every job and its state
#   bash ~/hset/hset_server.sh chain         # (owner's word) guards, then three drivers, detached
#   bash ~/hset/hset_server.sh status
#   bash ~/hset/hset_server.sh stop [runs]   # the drivers; with 'runs', H4 / H5's gem5 and ChampSim processes too
#   bash ~/hset/hset_server.sh relaunch4     # (owner's word; amendment 1) H4's VOID / NOT RUN / LAUNCH-FAILED gem5
#                                            # runs set aside to ~/hset/void_<time>, then the H4 gem5 driver alone
set -uo pipefail
SELF="$(readlink -f "$0")"
R="${R:-$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy}"
S="$R/simulator"
W="${W:-$HOME/hset}"                  # this script, hset_check.py, cfg/, state/, the drivers' logs
OUTROOT="${OUTROOT:-$HOME/gem5_b3/hset}"
B3="${B3:-$HOME/gem5_b3}"
GRUN="${GRUN:-$HOME/gem5_cal/run_gem5_splash.sh}"     # H2's copy (GEM5_PARAMS, CPU_TYPE)
GRUN_MD5="${GRUN_MD5:-53c55a7df8feaf542b1a26e0f9510bd8}"
GEM5_DIR="${GEM5_DIR:-$HOME/gem5}"
GEM5_TAG="${GEM5_TAG:-v25.1.0.1}"
FC_W="${FC_W:-$HOME/sync_fc}"
FC_MD5="${FC_MD5:-a2e88e46788e1f332427567a19bc2f90}"
PAR4="${PAR4:-8}"; PAR5="${PAR5:-4}"; PARC="${PARC:-4}"
LIMIT_S="${LIMIT_S:-$((168 * 3600))}"
QV0_WAIT_S="${QV0_WAIT_S:-900}"
POLL_S="${POLL_S:-300}"
CPOLL_S="${CPOLL_S:-60}"
MIN_FREE_GB="${MIN_FREE_GB:-20}"
GSCOPE="${GSCOPE:-all}"               # guards: 'h4' leaves out the H5 and ChampSim drivers (relaunch4)
SETTINGS4="${SETTINGS4:-lru srrip drrip}"
CSETTINGS="${CSETTINGS:-srrip drrip}"
ONLY="${ONLY:-}"                      # e.g. ONLY="ocean4": only those programs (rehearsal)
DONE_MARKER="ChampSim completed all CPUs"
EXIT_OK='because a thread reached the max instruction count'
die() { echo "ERROR: $*" >&2; exit 1; }
ts() { date '+%F %T'; }
alive() { [ -f "$1" ] && kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null; }
free_gb() { df -BG --output=avail "$S" | tail -1 | tr -dc 0-9; }

# program|gem5 long original|gem5 short original|mode|settings|stop variable|long stop|short stop|F-C tree|F-C config|parts
TABLE="${HS_TABLE:-}"   # a rehearsal sets its own; otherwise the design's six:
[ -n "$TABLE" ] || TABLE='ocean4|l2_2MB_mi150M/ocean_4c|l2_2MB_mi50M/ocean_4c|go-ocean-4c|LLC_SIZE=2MB|MAXINSTS|150000000|50000000|phaseA_b3_fc_g3_ocean4|ocean4|h4 h5
canneal4|canneal/l2_2MB_mi150M/canneal_4c|canneal/l2_2MB_mi50M/canneal_4c|go-canneal-4c|LLC_SIZE=2MB|WORKER_MAXINSTS|150000000|50000000|phaseA_b3_fc_g3_canneal4|canneal4|h4 h5
lunc|newbench/lunc/l2_2MB_mi150M/lunc_4c|newbench/lunc/l2_2MB_mi50M/lunc_4c|go-lunc-4c|LLC_SIZE=2MB BINS=@HOME@/splash-newbench|WORKER_MAXINSTS|150000000|50000000|phaseA_b3_fc_n2_lunc4|lunc|h4
radix|heldout/radix/l2_2MB_mi930M/radix_4c|heldout/radix/l2_2MB_mi830M/radix_4c|go-radix-4c|LLC_SIZE=2MB BINS=@HOME@/splash-heldout|WORKER_MAXINSTS|930000000|830000000|phaseA_b3_fc_g3_radix4|radix|h4
fluidanimate|heldout2/fluidanimate/l2_2MB_mi150M/fluidanimate_4c|heldout2/fluidanimate/l2_2MB_mi50M/fluidanimate_4c|go-fluidanimate-4c|LLC_SIZE=2MB BINS=@HOME@/heldout2_static|WORKER_MAXINSTS|150000000|50000000|phaseA_b3_fc_h2_fluidanimate4|fluidanimate|h5
vips|heldout2/vips/l2_2MB_mi150M/vips_4c|heldout2/vips/l2_2MB_mi50M/vips_4c|go-vips-4c|LLC_SIZE=2MB BINS=@HOME@/heldout2_static|WORKER_MAXINSTS|150000000|50000000|phaseA_b3_fc_h2_vips4|vips|h5'

table() { echo "$TABLE" | sed "s|@HOME@|$HOME|g" | while IFS='|' read -r p rest; do
  [ -z "$ONLY" ] || [[ " $ONLY " == *" $p "* ]] || continue; echo "$p|$rest"; done; }
tf() { table | awk -F'|' -v p="$1" -v f="$2" '$1 == p { print $f }'; }   # program field
progs() { table | awk -F'|' -v x="$1" '(" " $11 " ") ~ (" " x " ") { print $1 }'; }   # the programs of part h4 / h5

# the declared gem5 change of each setting (one --param statement), or the CPU
M5='__import__('"'"'m5.objects'"'"', fromlist=['"'"'x'"'"'])'
# amendment 1: --param's wrapper refuses SimObject parameters, so the statement sets the real
# object, reached through the root (apply_config runs just before m5.instantiate)
L2P="$M5.Root.getInstance().system.ruby.l2_cntrl0.L2cache.replacement_policy"
gparam() {
  case "$1" in
    lru)   echo "$L2P = $M5.LRURP()" ;;
    srrip) echo "$L2P = $M5.BRRIPRP(num_bits=2, btp=0, hit_priority=True)" ;;
    drrip) echo "$L2P = $M5.DRRIPRP(constituency_size=512, team_size=16, replacement_policy_a=$M5.BRRIPRP(num_bits=2, btp=3, hit_priority=True), replacement_policy_b=$M5.RRIPRP(num_bits=2, hit_priority=True))" ;;
    o3)    echo "" ;;
  esac
}

# ---------------------------------------------------------------- gem5 (H4: lru srrip drrip; H5: o3)
gjobs() {   # part -> setting|program|long or short, the long stops first
  local part=$1 stop p s
  for stop in long short; do for p in $(progs "$part"); do
    if [ "$part" = h4 ]; then for s in $SETTINGS4; do echo "$s|$p|$stop"; done; else echo "o3|$p|$stop"; fi
  done; done; }
g_stopv() { if [ "$3" = long ]; then tf "$2" 7; else tf "$2" 8; fi; }         # s p stop -> instructions
g_orig() { if [ "$3" = long ]; then tf "$2" 2; else tf "$2" 3; fi; }
g_odir() { echo "$OUTROOT/$1/$2/l2_2MB_mi$(( $(g_stopv "$@") / 1000000 ))M/$(basename "$(g_orig "$@")")"; }
g_st() { echo "$W/state/$1_$2_$3"; }
g_result() { cat "$(g_st "$@")/RESULT" 2>/dev/null; }
gem5_pid() { pgrep -u "$(id -u)" -f "[g]em5.opt --outdir=$1 " 2>/dev/null | head -1; }
g_check() {   # s p stop: QH0 (H4) or QO0 (H5)
  if [ "$1" = o3 ]; then python3 "$W/hset_check.py" qo0 "$B3/$(g_orig "$@")" "$(g_odir "$@")"
  else python3 "$W/hset_check.py" qh0 "$B3/$(g_orig "$@")" "$(g_odir "$@")" "$1"; fi
}

g_launch() {   # s p stop
  local s=$1 p=$2 stop=$3 st env sv cpu=TimingSimpleCPU
  st=$(g_st "$s" "$p" "$stop"); mkdir -p "$st"
  env=$(tf "$p" 5); sv=$(tf "$p" 6)
  [ "$s" = o3 ] && cpu=X86O3CPU
  echo "$(ts) LAUNCH $s $p $stop: $(tf "$p" 4) $env $sv=$(g_stopv "$s" "$p" "$stop") CPU_TYPE=$cpu"
  # shellcheck disable=SC2086 -- $env is a list of assignments
  ( cd "$HOME" && env OUT="$OUTROOT/$s/$p/l2_2MB_mi$(( $(g_stopv "$s" "$p" "$stop") / 1000000 ))M" "GEM5_PARAMS=$(gparam "$s")" CPU_TYPE="$cpu" \
      OCEAN_GRID=514 $env "$sv=$(g_stopv "$s" "$p" "$stop")" bash "$GRUN" "$(tf "$p" 4)" ) > "$st/launch.log" 2>&1
  local rc=$?
  sed 's/^/      /' "$st/launch.log"
  return $rc
}

g_settle() {   # part: classify every started run whose gem5 has ended; end runs past the limit
  local s p stop st od pid t0 line
  while IFS='|' read -r s p stop; do
    st=$(g_st "$s" "$p" "$stop"); od=$(g_odir "$s" "$p" "$stop")
    [ -f "$st/STARTED" ] && [ -z "$(g_result "$s" "$p" "$stop")" ] || continue
    pid=$(gem5_pid "$od")
    if [ -n "$pid" ]; then
      t0=$(cat "$st/STARTED")
      if [ $(( $(date +%s) - t0 )) -gt "$LIMIT_S" ]; then kill "$pid"; echo "$(ts) $s $p $stop: past the limit -- ended"; sleep 5; else continue; fi
    fi
    line=$(python3 "$W/hset_check.py" qend "$od" 1 2>&1 | tail -1)
    echo "${line#QEND }" > "$st/RESULT"
    echo "$(ts) $s $p $stop: ${line#QEND }"
  done < <(gjobs "$1")
}

g_running() { local n=0 s p stop; while IFS='|' read -r s p stop; do [ -n "$(gem5_pid "$(g_odir "$s" "$p" "$stop")")" ] && n=$((n + 1)); done < <(gjobs "$1"); echo "$n"; }

g_chain() {   # part h4 | h5
  local part=$1 par; if [ "$part" = h4 ]; then par=$PAR4; else par=$PAR5; fi
  echo $$ > "$W/.driver_$part.pid"
  echo "$(ts) GEM5 $part CHAIN START (pid $$; $(gjobs "$part" | wc -l) runs, $par at a time; limit ${LIMIT_S}s)"
  local stop_launching=0 s p stop st od waited pid line
  # runs started under an earlier driver that ended while no driver ran: one that reached its stop is
  # classified; any other (ended by 'stop runs', or killed) is launched again (H2's rule)
  while IFS='|' read -r s p stop; do
    st=$(g_st "$s" "$p" "$stop"); od=$(g_odir "$s" "$p" "$stop")
    [ -f "$st/STARTED" ] && [ -z "$(g_result "$s" "$p" "$stop")" ] && [ -z "$(gem5_pid "$od")" ] || continue
    line=$(python3 "$W/hset_check.py" qend "$od" 1 2>&1 | tail -1)
    case "$line" in
      "QEND ENDED-AT-STOP"*) echo "${line#QEND }" > "$st/RESULT"; echo "$(ts) $s $p $stop: ended while no driver ran: ${line#QEND }" ;;
      *) rm -f "$st/STARTED"; echo "$(ts) $s $p $stop: ended while no driver ran, not at its stop (${line#QEND }) -- to be launched again" ;;
    esac
  done < <(gjobs "$part")
  while IFS='|' read -r s p stop; do
    st=$(g_st "$s" "$p" "$stop"); od=$(g_odir "$s" "$p" "$stop")
    [ -z "$(g_result "$s" "$p" "$stop")" ] || { echo "$(ts) SKIP $s $p $stop: $(g_result "$s" "$p" "$stop")"; continue; }
    if [ -n "$(gem5_pid "$od")" ]; then   # a run from before a restart: checked and classified like the rest
      mkdir -p "$st"
      if [ ! -f "$st/STARTED" ]; then
        g_check "$s" "$p" "$stop" > "$st/qv0.txt" 2>&1 || { echo "$(ts) $s $p $stop: running, but its configuration check FAILED -- launching $part stops"; stop_launching=1; }
        date +%s > "$st/STARTED"
      fi
      echo "$(ts) $s $p $stop: already running -- left alone ($(tail -1 "$st/qv0.txt" 2>/dev/null))"; continue
    fi
    while :; do                     # count the live runs FIRST, then classify, then decide
      local running; running=$(g_running "$part")
      g_settle "$part"
      [ "$stop_launching" = 0 ] || break
      [ "$running" -lt "$par" ] && break
      sleep "$POLL_S"
    done
    if [ "$stop_launching" != 0 ]; then mkdir -p "$st"; echo "NOT RUN (the chain stopped launching)" > "$st/RESULT"; continue; fi
    rm -f "$st/STARTED"
    if ! g_launch "$s" "$p" "$stop"; then
      echo "LAUNCH-FAILED" > "$st/RESULT"; echo "$(ts) $s $p $stop: LAUNCH FAILED -- launching $part stops"; stop_launching=1; continue
    fi
    waited=0
    while [ ! -s "$od/config.ini" ] && [ "$waited" -lt "$QV0_WAIT_S" ]; do sleep 10; waited=$((waited + 10)); done
    sleep 5
    if g_check "$s" "$p" "$stop" > "$st/qv0.txt" 2>&1; then
      echo "$(ts) $s $p $stop: $(tail -1 "$st/qv0.txt")"
      date +%s > "$st/STARTED"
    else
      sed 's/^/      /' "$st/qv0.txt"
      pid=$(gem5_pid "$od"); [ -z "$pid" ] || kill "$pid"
      echo "VOID (configuration check failed: $(tail -1 "$st/qv0.txt"))" > "$st/RESULT"
      echo "$(ts) $s $p $stop: CONFIGURATION CHECK FAILED -- run ended, launching $part stops"; stop_launching=1
    fi
  done < <(gjobs "$part")
  echo "$(ts) GEM5 $part: ALL LAUNCHED OR SKIPPED; waiting for the runs"
  while :; do
    g_settle "$part"
    local open=0
    while IFS='|' read -r s p stop; do [ -n "$(g_result "$s" "$p" "$stop")" ] || open=$((open + 1)); done < <(gjobs "$part")
    [ "$open" = 0 ] && break
    sleep "$POLL_S"
  done
  echo "$(ts) GEM5 $part CHAIN END"
  rm -f "$W/.driver_$part.pid"
}

# ---------------------------------------------------------------- ChampSim (H4: srrip, drrip on the F-C binary)
cjobs() { local s p; for p in $(progs h4); do for s in $CSETTINGS; do echo "$s|$p"; done; done; }
suffix_of() { local t; t=$(tf "$1" 9); echo "${t##*_}"; }                      # ocean4, canneal4, lunc4, radix4
fc_log() { ls "$S/results/$(tf "$1" 9)"/regime_shared/*_4core/lru/run.log 2>/dev/null | head -1; }
wl_of() { local d; d=$(dirname "$(dirname "$(fc_log "$1")")"); basename "$d"; }   # <wl>_4core
c_log() { echo "$S/results/phaseA_b3_hs_$1_$(suffix_of "$2")/regime_shared/$(wl_of "$2")/$1/run.log"; }   # s p
c_st() { echo "$W/state/c_$1_$2"; }
bin_fc() { cat "$FC_W/BIN" 2>/dev/null; }
c_done() { local f; f=$(c_log "$1" "$2"); grep -q "$DONE_MARKER" "$f" 2>/dev/null && [ "$(cat "$f.bin" 2>/dev/null)" = "$(basename "$(bin_fc)")" ]; }

c_run() {   # s p -- the F-C reference's run with LLC.replacement = s
  local s=$1 p=$2 st ref log ref_cfg cfg wu si B tr=() x
  st=$(c_st "$s" "$p"); mkdir -p "$st" "$W/cfg"; touch "$st/running"
  ref=$(fc_log "$p"); log=$(c_log "$s" "$p"); ref_cfg="$FC_W/cfg/$(tf "$p" 10).json"; cfg="$W/cfg/${s}_$p.json"; B=$(bin_fc)
  cp "$ref_cfg" "$W/cfg/ref_$p.json"
  python3 -c 'import json, sys; c = json.load(open(sys.argv[1])); c["LLC"]["replacement"] = sys.argv[3]; json.dump(c, open(sys.argv[2], "w"), indent=2)' "$ref_cfg" "$cfg" "$s"
  if ! python3 "$W/hset_check.py" cfg "$ref_cfg" "$cfg" "$s" > "$st/cfg.txt" 2>&1; then
    echo "config check failed: $(tail -1 "$st/cfg.txt")" > "$st/run_failed"; echo "$(ts) RUN FAILED $s $p: $(cat "$st/run_failed")"; rm -f "$st/running"; return 1
  fi
  wu=$(awk '/^Warmup Instructions:/ { print $3; exit }' "$ref"); si=$(awk '/^Simulation Instructions:/ { print $3; exit }' "$ref")
  while read -r x; do [ -s "$x" ] || { echo "no trace $x" > "$st/run_failed"; echo "$(ts) RUN FAILED $s $p: $(cat "$st/run_failed")"; rm -f "$st/running"; return 1; }; tr+=("$x")
  done < <(awk '/^CPU [0-9]+ runs / { print $2, $4 }' "$ref" | sort -n -k1,1 | awk '{ print $2 }')
  mkdir -p "$(dirname "$log")"; rm -f "$log.bin"; cp "$cfg" "$(dirname "$log")/config.json"
  echo "$(ts) RUN $s $p: $(basename "$B"), window $wu + $si, ${#tr[@]} traces, LLC $s -> $(echo "$log" | sed "s|^$S/results/||")"
  ( cd "$S" && nice -n 19 "$B" --config "$cfg" --warmup-instructions "$wu" --simulation-instructions "$si" "${tr[@]}" > "$log" 2>&1 )
  local rc=$?
  basename "$B" > "$log.bin"
  if grep -q "$DONE_MARKER" "$log"; then
    echo "$(ts) RUN END $s $p: complete; unexplained view-order violations $(grep -E '^LLC COHERENCE DIR VIEW-ORDER VIOLATIONS UNEXPLAINED:' "$log" | awk '{ s += $NF } END { print s + 0 }')"
  else
    echo "rc $rc: $(tail -1 "$log" | cut -c1-100)" > "$st/run_failed"; echo "$(ts) RUN FAILED $s $p: did not complete ($(cat "$st/run_failed"))"
  fi
  rm -f "$st/running"
}

c_chain() {
  echo $$ > "$W/.driver_c.pid"
  ps -o sid= -p $$ | tr -d ' ' > "$W/.sid_c"           # 'stop runs' ends this session: the ChampSim runs
  rm -f "$W"/state/c_*/running                       # no H4 ChampSim process runs (the chain's check), so these are stale
  echo "$(ts) CHAMPSIM CHAIN START (pid $$; $(cjobs | wc -l) runs, $PARC at a time on $(basename "$(bin_fc)"))"
  local s p st nc open
  while :; do
    open=0; nc=$(ls "$W"/state/c_*/running 2>/dev/null | wc -l)
    while IFS='|' read -r s p; do
      st=$(c_st "$s" "$p")
      c_done "$s" "$p" && continue
      [ -f "$st/run_failed" ] && continue
      open=$((open + 1))
      [ -f "$st/running" ] && continue
      if [ "$nc" -lt "$PARC" ] && [ "$(free_gb)" -ge "$MIN_FREE_GB" ]; then mkdir -p "$st"; touch "$st/running"; c_run "$s" "$p" & nc=$((nc + 1)); fi
    done < <(cjobs)
    [ "$open" = 0 ] && break
    sleep "$CPOLL_S"
  done
  wait
  echo "$(ts) CHAMPSIM CHAIN END"
  rm -f "$W/.driver_c.pid"
}

# the ChampSim driver's session still holds an H4 run (matched inside awk: no `| grep -q` under pipefail)
c_session_alive() {
  local sid; sid=$(cat "$W/.sid_c" 2>/dev/null)
  [ -n "$sid" ] || return 1
  ps -u "$(id -u)" -o sid=,args= | awk -v s="$sid" '$1 == s && /hset_server\.sh __c|--config [^ ]*\/hset\/cfg\// { n++ } END { exit !n }'
}

# ---------------------------------------------------------------- guards
guards() {
  local bad=0 p f bin t part
  ok() { echo "   ok   $*"; }
  no() { echo "   FAIL $*"; bad=1; }
  echo "-- gem5"
  [ "$(git -C "$GEM5_DIR" describe --tags 2>/dev/null)" = "$GEM5_TAG" ] && ok "gem5 at $GEM5_TAG" || no "gem5 is not at $GEM5_TAG"
  t=$(git -C "$GEM5_DIR" status --porcelain 2>/dev/null | LC_ALL=C sort | tr '\n' ';')
  [ "$t" = " M configs/ruby/MESI_Three_Level.py;?? .gem5_protocol;?? configs/ruby/MESI_Three_Level.py.orig_fifo;" ] \
    && ok "the live gem5 tree differs from $GEM5_TAG only by the FIFO patch (as for the originals)" || no "the live gem5 tree has other changes: $t"
  [ "$(grep -c 'COALESCE: setup_gem5.sh patch-fifo' "$GEM5_DIR/configs/ruby/MESI_Three_Level.py")" = 2 ] && ok "the live config is patched, as the originals ran" || no "the live config is not patched"
  [ "$(md5sum < "$GRUN" 2>/dev/null | cut -c1-32)" = "$GRUN_MD5" ] && grep -q '^GEM5_PARAMS=' "$GRUN" && grep -q '^CPU_TYPE=' "$GRUN" \
    && ok "H2's runner copy $GRUN (md5 ${GRUN_MD5:0:8}; GEM5_PARAMS, CPU_TYPE)" || no "$GRUN is not the committed runner (md5 ${GRUN_MD5:0:8})"
  python3 -m py_compile "$W/hset_check.py" 2>/dev/null && ok "hset_check.py compiles" || no "no usable $W/hset_check.py"
  bin="$GEM5_DIR/build/$(cat "$GEM5_DIR/.gem5_build_dir" 2>/dev/null || echo X86)/gem5.opt"
  [ -x "$bin" ] && ok "gem5 binary $(stat -c '%y' "$bin" | cut -c1-16)" || no "no gem5 binary"
  if [ -n "$(progs h5)" ]; then
    t=$( cd /tmp && "$bin" "$GEM5_DIR/configs/deprecated/example/se.py" --list-cpu-types 2>/dev/null )   # captured: no `| grep -q` under pipefail
    grep -qw X86O3CPU <<< "$t" && ok "gem5 lists X86O3CPU" || no "gem5 does not list X86O3CPU"
  fi
  for p in $(table | cut -d'|' -f1); do
    for f in "$(tf "$p" 2)" "$(tf "$p" 3)"; do
      if [ -f "$B3/$f/config.ini" ] && grep -q '^finalTick' "$B3/$f/stats.txt" 2>/dev/null && grep -q "$EXIT_OK" "$B3/$f/run.log" 2>/dev/null \
         && [ "$bin" -ot "$B3/$f/config.ini" ] \
         && [ "$(awk '/^\[/ { s = $0 } s == "[system.ruby.l2_cntrl0.L2cache.replacement_policy]" && /^type=/' "$B3/$f/config.ini")" = type=TreePLRURP ] \
         && [ "$(awk '/^\[system.cpu0\]$/ { s = 1; next } /^\[/ { s = 0 } s && /^type=/' "$B3/$f/config.ini")" = type=BaseTimingSimpleCPU ]; then
        ok "$p: original $f ended at its stop, after the binary (TreePLRU, TimingSimpleCPU)"
      else no "$p: original $f incomplete, older than the binary, or not TreePLRU / TimingSimpleCPU"; fi
    done
  done
  for part in h4 h5; do
    [ "$GSCOPE" = h4 ] && [ "$part" = h5 ] && continue     # relaunch4: H5's driver keeps running
    alive "$W/.driver_$part.pid" && no "the $part gem5 driver is running (pid $(cat "$W/.driver_$part.pid"))" || ok "no $part gem5 driver running"
  done
  echo "-- ChampSim (H4's srrip and drrip)"
  for p in $(progs h4); do
    [ -n "$(fc_log "$p")" ] && grep -q "$DONE_MARKER" "$(fc_log "$p")" && grep -q '^SYNC LOCK WORD: request$' "$(fc_log "$p")" \
      && ok "$p: F-C reference $(tf "$p" 9) complete ($(wl_of "$p"))" || no "$p: no complete F-C reference under $S/results/$(tf "$p" 9)"
    f="$FC_W/cfg/$(tf "$p" 10).json"
    grep -q '"sync_lock_word": "request"' "$f" 2>/dev/null && python3 -c 'import json, sys; sys.exit(json.load(open(sys.argv[1]))["LLC"]["replacement"] != "lru")' "$f" \
      && ok "$p: F-C config $f (LLC lru)" || no "$p: no F-C config $f with LLC lru"
  done
  bin=$(bin_fc)
  [ -x "$bin" ] && [ "$(md5sum < "$bin" | cut -c1-32)" = "$FC_MD5" ] && ok "F-C binary $(basename "$bin")" || no "the F-C binary is not md5 $FC_MD5"
  for f in Q0_PASSED Q0M_PASSED Q0R_PASSED K0_PASSED; do [ -f "$FC_W/$f" ] || no "F-C's $f missing"; done
  if [ "$GSCOPE" != h4 ]; then                                  # relaunch4: the ChampSim driver keeps running
    alive "$W/.driver_c.pid" && no "the ChampSim driver is running (pid $(cat "$W/.driver_c.pid"))" || ok "no ChampSim driver running"
    [ -z "$(pgrep -u "$(id -u)" -f -- "[-]-config $W/cfg/" 2>/dev/null)" ] && ! c_session_alive && ok "no H4 ChampSim run left" || no "an H4 ChampSim run is running (an earlier chain's?)"
  fi
  t=$(free_gb); [ "${t:-0}" -ge "$MIN_FREE_GB" ] && ok "disk $t GB free" || no "disk $t GB free (< $MIN_FREE_GB)"
  return $bad
}

# ---------------------------------------------------------------- report
list() {
  local part s p stop r st
  for part in h4 h5; do
    echo "-- $part gem5 ($OUTROOT)"
    while IFS='|' read -r s p stop; do
      r=$(g_result "$s" "$p" "$stop")
      if [ -z "$r" ]; then
        if [ -n "$(gem5_pid "$(g_odir "$s" "$p" "$stop")")" ]; then r="running $(( ($(date +%s) - $(cat "$(g_st "$s" "$p" "$stop")/STARTED" 2>/dev/null || date +%s)) / 3600 )) h"; else r=pending; fi
      fi
      printf '   %-6s %-13s %-5s %s\n' "$s" "$p" "$stop" "$r"
    done < <(gjobs "$part")
  done
  echo "-- H4 ChampSim"
  while IFS='|' read -r s p; do
    st=$(c_st "$s" "$p")
    if c_done "$s" "$p"; then r=complete; elif [ -f "$st/run_failed" ]; then r="FAILED ($(cat "$st/run_failed"))"; elif [ -f "$st/running" ]; then r=running; else r=pending; fi
    printf '   %-6s %-13s %s\n' "$s" "$p" "$r"
  done < <(cjobs)
}

summary() {
  local part n d s p stop cd=0 cn=0
  for part in h4 h5; do
    n=0; d=0
    while IFS='|' read -r s p stop; do n=$((n + 1)); [ -z "$(g_result "$s" "$p" "$stop")" ] || d=$((d + 1)); done < <(gjobs "$part")
    echo "   $part gem5: $d of $n ended ($(g_running "$part") running)"
  done
  while IFS='|' read -r s p; do cn=$((cn + 1)); c_done "$s" "$p" && cd=$((cd + 1)); done < <(cjobs)
  echo "   H4 ChampSim: $cd of $cn complete"
}

start_driver() {   # name mode log -> 0 if alive or ran and ended at once
  local name=$1 mode=$2 log=$3 pidf=$4 endpat=$5 before
  before=$(grep -c "$endpat" "$log" 2>/dev/null); before=${before:-0}
  setsid nohup bash "$SELF" $mode >> "$log" 2>&1 < /dev/null &
  sleep 3
  if alive "$pidf"; then echo "$name driver started (pid $(cat "$pidf")); log $log"; return 0; fi
  if [ "$(grep -c "$endpat" "$log" 2>/dev/null)" -gt "$before" ]; then echo "$name driver ran and ended at once (nothing left to run)"; return 0; fi
  echo "$name driver NOT started: $(tail -2 "$log" 2>/dev/null)"; return 1
}

case "${1:-}" in
  guards) echo "== H4 / H5 guards"; guards ;;
  list) list ;;
  chain)
    mkdir -p "$W/state" "$W/cfg" "$OUTROOT"
    for f in h4 h5 c; do alive "$W/.driver_$f.pid" && die "the $f driver is running -- 'status'"; done
    echo "== guards"; guards || die "a guard failed (above) -- nothing started"
    okd=0
    start_driver "H4 gem5" "__g h4" "$W/driver_h4.log" "$W/.driver_h4.pid" 'GEM5 h4 CHAIN END' && okd=$((okd + 1))
    start_driver "H5 gem5" "__g h5" "$W/driver_h5.log" "$W/.driver_h5.pid" 'GEM5 h5 CHAIN END' && okd=$((okd + 1))
    start_driver "H4 ChampSim" "__c" "$W/driver_c.log" "$W/.driver_c.pid" 'CHAMPSIM CHAIN END' && okd=$((okd + 1))
    [ "$okd" = 3 ] || die "a driver did not start (above)" ;;
  relaunch4)
    mkdir -p "$W/state" "$OUTROOT"
    alive "$W/.driver_h4.pid" && die "the h4 gem5 driver is running -- 'status'"
    while IFS='|' read -r s p stop; do
      [ -z "$(gem5_pid "$(g_odir "$s" "$p" "$stop")")" ] || die "an H4 gem5 run is alive ($s $p $stop) -- 'status'"
    done < <(gjobs h4)
    echo "== guards (H4's gem5 runs)"; GSCOPE=h4 guards || die "a guard failed (above) -- nothing set aside, nothing started"
    A="$W/void_$(date +%Y%m%d_%H%M%S)"; n=0; kept=0
    while IFS='|' read -r s p stop; do
      st=$(g_st "$s" "$p" "$stop"); od=$(g_odir "$s" "$p" "$stop"); r=$(g_result "$s" "$p" "$stop")
      case "$r" in
        VOID*|"NOT RUN"*|LAUNCH-FAILED*) ;;
        "") [ -d "$st" ] && [ ! -f "$st/STARTED" ] || continue ;;   # launched, never checked (a driver killed mid-wait)
        *) kept=$((kept + 1)); continue ;;
      esac
      mkdir -p "$A/state"; mv "$st" "$A/state/" || die "could not set $st aside"
      if [ -d "$od" ]; then rel=${od#"$OUTROOT"/}; mkdir -p "$A/out/$(dirname "$rel")"; mv "$od" "$A/out/$rel" || die "could not set $od aside"; fi
      echo "   set aside: $s $p $stop (${r:-launched, never checked})"; n=$((n + 1))
    done < <(gjobs h4)
    echo "   $n H4 run(s) set aside to $A; $kept decided run(s) kept"
    start_driver "H4 gem5" "__g h4" "$W/driver_h4.log" "$W/.driver_h4.pid" 'GEM5 h4 CHAIN END' || die "the H4 gem5 driver did not start (above)" ;;
  __g) g_chain "$2" ;;
  __c) c_chain ;;
  status)
    echo "== H4 / H5: h4 gem5 driver $(alive "$W/.driver_h4.pid" && echo alive || echo "not running"); h5 gem5 driver $(alive "$W/.driver_h5.pid" && echo alive || echo "not running"); ChampSim driver $(alive "$W/.driver_c.pid" && echo alive || echo "not running")"
    summary
    for f in h4 h5 c; do tail -2 "$W/driver_$f.log" 2>/dev/null | sed "s/^/   $f: /"; done ;;
  stop)
    for f in h4 h5 c; do
      if alive "$W/.driver_$f.pid"; then kill "$(cat "$W/.driver_$f.pid")"; rm -f "$W/.driver_$f.pid"; echo "driver stopped ($f)"; fi
    done
    if [ "${2:-}" = runs ]; then
      t0=$(date +%s)
      pgrep -u "$(id -u)" -f "[g]em5.opt --outdir=$OUTROOT/" | while read -r x; do kill "$x" && echo "ended gem5 pid $x"; done
      if c_session_alive; then pkill -u "$(id -u)" -s "$(cat "$W/.sid_c")" && echo "ended the ChampSim driver's session $(cat "$W/.sid_c")"; fi
      pgrep -u "$(id -u)" -f -- "[-]-config $W/cfg/" | while read -r x; do kill "$x" && echo "ended pid $x (H4 ChampSim)"; done
      sleep 2   # a failure mark written as the stop ended a run is the stop's, not a failure: the next chain redoes it
      find "$W/state" -name run_failed -newermt "@$t0" 2>/dev/null | while read -r f; do
        rm -f "$f"; echo "cleared $(basename "$(dirname "$f")")/run_failed (written as the stop ended it)"; done
    fi ;;
  *) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
