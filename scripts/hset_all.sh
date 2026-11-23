#!/usr/bin/env bash
# H4 and H5 (bench/policy_sanity/gem5_settings_design_2026-11-14.md): gem5's LLC
# policy and CPU model as settings. Uploads (to .new, then mv) hset_server.sh and
# hset_check.py into ~/hset; the gem5 runs go through H2's runner copy
# (~/gem5_cal/run_gem5_splash.sh, checked against the committed file's md5). The
# server checks its guards, then runs three drivers DETACHED.
#
#   bash scripts/hset_all.sh go       # (owner's word) upload, guards, the drivers
#   bash scripts/hset_all.sh guards   # read-only (after a go has uploaded)
#   bash scripts/hset_all.sh status   # read-only
#   bash scripts/hset_all.sh list     # read-only
#   bash scripts/hset_all.sh pull     # read-only: gem5 stats / config / run.log, the ChampSim logs and configs,
#                                     # the originals' statistics -> simulator/results/hset/
#   bash scripts/hset_all.sh stop [runs]
#   bash scripts/hset_all.sh relaunch4  # (owner's word; amendment 1) upload, then H4's gem5 driver alone: its VOID /
#                                       # NOT RUN runs set aside; H5 and the ChampSim driver keep running
set -uo pipefail
PORT="${PORT:-2222}"
SRV="${SRV:-user@your-server}"
LROOT="${LROOT:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"
SRV_HOME="${SRV_HOME:-/home/harshraj}"
SRV_S="${SRV_S:-$SRV_HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy/simulator}"
PREREG="bench/policy_sanity/gem5_settings_design_2026-11-14.md"
UP="scripts/hset_server.sh:hset/hset_server.sh
scripts/hset_check.py:hset/hset_check.py"
GRUN_MD5=$(md5sum < "$LROOT/scripts/run_gem5_splash.sh" | cut -c1-32)
SV="GRUN_MD5=$GRUN_MD5 bash $SRV_HOME/hset/hset_server.sh"
ORIGS="l2_2MB_mi150M/ocean_4c l2_2MB_mi50M/ocean_4c canneal/l2_2MB_mi150M/canneal_4c canneal/l2_2MB_mi50M/canneal_4c
newbench/lunc/l2_2MB_mi150M/lunc_4c newbench/lunc/l2_2MB_mi50M/lunc_4c heldout/radix/l2_2MB_mi930M/radix_4c heldout/radix/l2_2MB_mi830M/radix_4c
heldout2/fluidanimate/l2_2MB_mi150M/fluidanimate_4c heldout2/fluidanimate/l2_2MB_mi50M/fluidanimate_4c
heldout2/vips/l2_2MB_mi150M/vips_4c heldout2/vips/l2_2MB_mi50M/vips_4c"
MODE="${1:-}"
case "$MODE" in go|relaunch4|guards|status|list|pull|stop) ;; *) echo "usage: $0 go|relaunch4|guards|status|list|pull|stop [runs]"; exit 1 ;; esac
OUTD="${OUTD:-$LROOT/simulator/results/hset}"
mkdir -p "$OUTD"
if [ "$MODE" = go ] || [ "$MODE" = relaunch4 ]; then
  LOG="$OUTD/hset_all_${MODE}_$(date +%Y%m%d_%H%M%S).log"
  exec > >(tee -a "$LOG") 2>&1
fi
die() { echo; echo "STOPPED: $*"; exit 1; }

if [ "$MODE" = go ] || [ "$MODE" = relaunch4 ]; then
  echo "== local checks"
  bash -n "$LROOT/scripts/hset_server.sh" || die "hset_server.sh does not parse"
  for f in "$PREREG" $(echo "$UP" | cut -d: -f1) scripts/hset_all.sh scripts/run_gem5_splash.sh; do
    git -C "$LROOT" ls-files --error-unmatch "$f" > /dev/null 2>&1 || die "$f is not committed"
  done
  # shellcheck disable=SC2046 -- a list of paths
  dirty=$(git -C "$LROOT" status --porcelain -- $(echo "$UP" | cut -d: -f1) scripts/hset_all.sh scripts/run_gem5_splash.sh "$PREREG")
  [ -z "$dirty" ] || { echo "$dirty"; die "uncommitted changes in what is uploaded -- commit first"; }
  grep -q '^## Build record' "$LROOT/$PREREG" || die "$PREREG has no build record (the rehearsal) yet"
  st=$(python3 "$LROOT/scripts/hset_check.py" selftest 2>&1 | tail -1); [[ "$st" == *PASSES* ]] || die "hset_check.py selftest fails: $st"
  echo "   committed: $(git -C "$LROOT" log -1 --format='%h %s' | cut -c1-90)"
fi

CTL="$HOME/.ssh/cm-hset-$$"
mkdir -p "$HOME/.ssh"
cleanup() { ssh -O exit -o ControlPath="$CTL" -p "$PORT" "$SRV" 2>/dev/null || true; rm -f "$CTL"; }
trap cleanup EXIT
ssh -p "$PORT" -o ControlMaster=yes -o ControlPath="$CTL" -o ControlPersist=20m \
    -o ServerAliveInterval=30 -o ConnectTimeout=40 -fN "$SRV" || { echo "could not connect (a locked key agent? see CLAUDE.md, server access)"; exit 1; }
R() { ssh -n -p "$PORT" -o ControlPath="$CTL" "$SRV" "$@"; }
RS=(rsync -a --copy-links -e "ssh -p $PORT -o ControlPath=$CTL")

case "$MODE" in
  guards|status|list|stop)
    R "[ -f $SRV_HOME/hset/hset_server.sh ] || { echo 'H4 / H5 not uploaded yet -- $0 go'; exit 0; }; $SV $MODE ${2:-}" 2>&1; exit 0 ;;
  pull)
    R "$SV status" 2>&1
    mkdir -p "$OUTD/gem5" "$OUTD/logs" "$OUTD/cfg" "$OUTD/state" "$OUTD/orig"
    "${RS[@]}" --include='*/' --include='run.log' --include='stats.txt' --include='config.ini' --exclude='*' \
      "$SRV:$SRV_HOME/gem5_b3/hset/" "$OUTD/gem5/" 2>/dev/null
    "${RS[@]}" --include='phaseA_b3_hs_*/***' --exclude='*' "$SRV:$SRV_S/results/" "$OUTD/logs/" 2>/dev/null
    "${RS[@]}" "$SRV:$SRV_HOME/hset/cfg/" "$OUTD/cfg/" 2>/dev/null
    "${RS[@]}" "$SRV:$SRV_HOME/hset/state/" "$OUTD/state/" 2>/dev/null
    for f in driver_h4.log driver_h5.log driver_c.log; do "${RS[@]}" "$SRV:$SRV_HOME/hset/$f" "$OUTD/$f" 2>/dev/null; done
    for o in $ORIGS; do
      mkdir -p "$OUTD/orig/$o"
      "${RS[@]}" "$SRV:$SRV_HOME/gem5_b3/$o/stats.txt" "$SRV:$SRV_HOME/gem5_b3/$o/run.log" "$OUTD/orig/$o/" 2>/dev/null
    done
    echo "   pulled: $(find "$OUTD/gem5" -name stats.txt 2>/dev/null | wc -l) gem5 statistics, $(find "$OUTD/logs" -name run.log 2>/dev/null | wc -l) ChampSim logs, $(find "$OUTD/orig" -name stats.txt 2>/dev/null | wc -l) originals, to ${OUTD#"$LROOT"/}/"
    exit 0 ;;
esac

echo "== upload (to .new, then mv)"
if [ "$MODE" = go ]; then
  R "for f in $SRV_HOME/hset/.driver_h4.pid $SRV_HOME/hset/.driver_h5.pid $SRV_HOME/hset/.driver_c.pid; do [ -f \$f ] && kill -0 \$(cat \$f 2>/dev/null) 2>/dev/null && exit 0; done; exit 1" \
    && die "an H4 / H5 driver is running already -- $0 status"
else
  R "f=$SRV_HOME/hset/.driver_h4.pid; [ -f \$f ] && kill -0 \$(cat \$f 2>/dev/null) 2>/dev/null" && die "the H4 gem5 driver is running -- $0 status"
fi
R "mkdir -p $SRV_HOME/hset" || die "mkdir failed"
while IFS=: read -r f dst; do
  scp -q -P "$PORT" -o ControlPath="$CTL" "$LROOT/$f" "$SRV:$SRV_HOME/$dst.new" || die "upload of $f failed"
  R "mv -f $SRV_HOME/$dst.new $SRV_HOME/$dst" || die "mv $dst failed"
  l=$(md5sum < "$LROOT/$f" | cut -c1-32); r=$(R "md5sum < $SRV_HOME/$dst | cut -c1-32")
  [ "$l" = "$r" ] || die "$dst on the server reads $r, the laptop's $l"
  echo "   ~/$dst ($l)"
done <<< "$UP"
if [ "$MODE" = go ]; then
  echo "== guards, then the drivers -- detached on the server"
  R "$SV chain" 2>&1 | sed 's/^/   /'
else
  echo "== H4's guards, its VOID / NOT RUN runs set aside, then the H4 gem5 driver -- detached on the server"
  R "$SV relaunch4" 2>&1 | sed 's/^/   /'
fi
[ "${PIPESTATUS[0]}" = 0 ] || die "a guard failed or a driver did not start (above)"
sleep "${FOLLOW_S:-30}"
R "$SV status" 2>&1 | sed 's/^/   /'
echo
if [ "$MODE" = go ]; then echo "Started: H4 (24 gem5 runs, 8 at a time; 8 ChampSim runs, 4 at a time) and H5 (8 gem5 O3 runs, 4 at a time)."
else echo "Relaunched: H4's gem5 runs (8 at a time), each checked by QH0 before the next launch."; fi
echo "Where it is:  $0 status      Results:  $0 pull"
echo "log: $LOG"
