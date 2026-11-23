#!/usr/bin/env bash
# H2 (bench/policy_sanity/calibration_design_2026-11-14.md): the band's noise
# floor. Uploads (to .new, then mv) cal_server.sh and sync_server.sh (as
# sync_server_cal.sh) into ~/cal, run_gem5_splash.sh and cal_score.py into
# ~/gem5_cal; the live ~/run_gem5_splash.sh and ~/sync_server*.sh are not
# touched. The server checks its guards, then runs both halves DETACHED.
#
#   bash scripts/cal_all.sh go       # (owner's word) upload, guards, both drivers
#   bash scripts/cal_all.sh guards   # read-only (after a go has uploaded)
#   bash scripts/cal_all.sh status   # read-only
#   bash scripts/cal_all.sh list     # read-only
#   bash scripts/cal_all.sh pull     # read-only: gem5 stats / config / run.log, replay logs, the traces' small files -> simulator/results/cal/
#   bash scripts/cal_all.sh stop [runs]
set -uo pipefail
PORT="${PORT:-2222}"
SRV="${SRV:-user@your-server}"
LROOT="${LROOT:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"
SRV_HOME="${SRV_HOME:-/home/harshraj}"
SRV_S="${SRV_S:-$SRV_HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy/simulator}"
PREREG="bench/policy_sanity/calibration_design_2026-11-14.md"
# local file -> server path
UP="scripts/cal_server.sh:cal/cal_server.sh
scripts/sync_server.sh:cal/sync_server_cal.sh
scripts/run_gem5_splash.sh:gem5_cal/run_gem5_splash.sh
scripts/cal_score.py:gem5_cal/cal_score.py"
SV="bash $SRV_HOME/cal/cal_server.sh"
MODE="${1:-}"
case "$MODE" in go|guards|status|list|pull|stop) ;; *) echo "usage: $0 go|guards|status|list|pull|stop [runs]"; exit 1 ;; esac
OUTD="${OUTD:-$LROOT/simulator/results/cal}"
mkdir -p "$OUTD"
if [ "$MODE" = go ]; then
  LOG="$OUTD/cal_all_$(date +%Y%m%d_%H%M%S).log"
  exec > >(tee -a "$LOG") 2>&1
fi
die() { echo; echo "STOPPED: $*"; exit 1; }

if [ "$MODE" = go ]; then
  echo "== local checks"
  for f in scripts/cal_server.sh scripts/sync_server.sh scripts/run_gem5_splash.sh; do bash -n "$LROOT/$f" || die "$f does not parse"; done
  for f in "$PREREG" $(echo "$UP" | cut -d: -f1) scripts/cal_all.sh; do
    git -C "$LROOT" ls-files --error-unmatch "$f" > /dev/null 2>&1 || die "$f is not committed"
  done
  # shellcheck disable=SC2046 -- a list of paths
  dirty=$(git -C "$LROOT" status --porcelain -- $(echo "$UP" | cut -d: -f1) scripts/cal_all.sh "$PREREG")
  [ -z "$dirty" ] || { echo "$dirty"; die "uncommitted changes in what is uploaded -- commit first"; }
  grep -q '^## Build record' "$LROOT/$PREREG" || die "$PREREG has no build record (the rehearsal) yet"
  st=$(python3 "$LROOT/scripts/cal_score.py" selftest 2>&1 | tail -1); [[ "$st" == *PASSES* ]] || die "cal_score.py selftest fails: $st"
  echo "   committed: $(git -C "$LROOT" log -1 --format='%h %s' | cut -c1-90)"
fi

CTL="$HOME/.ssh/cm-cal-$$"
mkdir -p "$HOME/.ssh"
cleanup() { ssh -O exit -o ControlPath="$CTL" -p "$PORT" "$SRV" 2>/dev/null || true; rm -f "$CTL"; }
trap cleanup EXIT
ssh -p "$PORT" -o ControlMaster=yes -o ControlPath="$CTL" -o ControlPersist=20m \
    -o ServerAliveInterval=30 -o ConnectTimeout=40 -fN "$SRV" || { echo "could not connect (a locked key agent? see CLAUDE.md, server access)"; exit 1; }
R() { ssh -n -p "$PORT" -o ControlPath="$CTL" "$SRV" "$@"; }
RS=(rsync -a --copy-links -e "ssh -p $PORT -o ControlPath=$CTL")

case "$MODE" in
  guards|status|list|stop)
    R "[ -f $SRV_HOME/cal/cal_server.sh ] || { echo 'H2 not uploaded yet -- $0 go'; exit 0; }; $SV $MODE ${2:-}" 2>&1; exit 0 ;;
  pull)
    R "$SV status" 2>&1
    mkdir -p "$OUTD/gem5" "$OUTD/logs" "$OUTD/traces" "$OUTD/state"
    "${RS[@]}" --include='*/' --include='run.log' --include='stats.txt' --include='config.ini' --exclude='*' \
      "$SRV:$SRV_HOME/gem5_b3/cal/" "$OUTD/gem5/" 2>/dev/null
    "${RS[@]}" --include='phaseA_b3_cal[0-9]_*/***' --exclude='*' "$SRV:$SRV_S/results/" "$OUTD/logs/" 2>/dev/null
    "${RS[@]}" --include='*/' --include='DONE' --include='LEN' --include='CPUID' --include='FAILED' --include='*.mix' --include='pin.err' \
      --include='anchor.txt' --include='cut.log' --exclude='*' "$SRV:$SRV_S/traces/cal/" "$OUTD/traces/" 2>/dev/null
    "${RS[@]}" "$SRV:$SRV_HOME/gem5_cal/state/" "$OUTD/state/gem5/" 2>/dev/null
    "${RS[@]}" "$SRV:$SRV_HOME/cal/state/" "$OUTD/state/traces/" 2>/dev/null
    "${RS[@]}" "$SRV:$SRV_HOME/gem5_cal/driver.log" "$OUTD/gem5_driver.log" 2>/dev/null
    "${RS[@]}" "$SRV:$SRV_HOME/cal/driver.log" "$OUTD/trace_driver.log" 2>/dev/null
    echo "   pulled: $(find "$OUTD/gem5" -name stats.txt 2>/dev/null | wc -l) gem5 statistics, $(find "$OUTD/logs" -name run.log 2>/dev/null | wc -l) replay logs, $(find "$OUTD/traces" -name DONE 2>/dev/null | wc -l) trace sets, to ${OUTD#"$LROOT"/}/"
    exit 0 ;;
esac

echo "== upload (to .new, then mv)"
R "for f in $SRV_HOME/gem5_cal/.driver.pid $SRV_HOME/cal/.driver.pid; do [ -f \$f ] && kill -0 \$(cat \$f 2>/dev/null) 2>/dev/null && exit 0; done; exit 1" \
  && die "an H2 driver is running already -- $0 status"
R "mkdir -p $SRV_HOME/cal $SRV_HOME/gem5_cal" || die "mkdir failed"
while IFS=: read -r f dst; do
  scp -q -P "$PORT" -o ControlPath="$CTL" "$LROOT/$f" "$SRV:$SRV_HOME/$dst.new" || die "upload of $f failed"
  R "mv -f $SRV_HOME/$dst.new $SRV_HOME/$dst" || die "mv $dst failed"
  l=$(md5sum < "$LROOT/$f" | cut -c1-32); r=$(R "md5sum < $SRV_HOME/$dst | cut -c1-32")
  [ "$l" = "$r" ] || die "$dst on the server reads $r, the laptop's $l"
  echo "   ~/$dst ($l)"
done <<< "$UP"
echo "== guards, then both drivers -- detached on the server"
R "$SV chain" 2>&1 | sed 's/^/   /'
[ "${PIPESTATUS[0]}" = 0 ] || die "a guard failed or no driver started (above)"
sleep "${FOLLOW_S:-30}"
R "$SV status" 2>&1 | sed 's/^/   /'
echo
echo "Started: H2 -- 32 gem5 runs (${PAR_G:-8} at a time), 20 re-traces and their replays."
echo "Where it is:  $0 status      Results:  $0 pull"
echo "log: $LOG"
