#!/usr/bin/env bash
# H1 (bench/policy_sanity/fifo_check_design_2026-11-14.md): which gem5 runs
# the FIFO patch touched. Uploads fifo_server.sh, fifo_check.py and a copy of
# run_gem5_splash.sh into ~/gem5_fifo (.new + mv; the live ~/run_gem5_splash.sh
# is not touched); the server prepares its configs copy, checks its guards and
# runs the 13 reruns DETACHED.
#
#   bash scripts/fifo_all.sh go       # (owner's word) upload, guards, start the driver
#   bash scripts/fifo_all.sh guards   # read-only (after a go has uploaded)
#   bash scripts/fifo_all.sh status   # read-only
#   bash scripts/fifo_all.sh list     # read-only
#   bash scripts/fifo_all.sh pull     # read-only: RESULT, qf0, run.log, stats.txt, config.ini, driver.log -> simulator/results/fifo/
#   bash scripts/fifo_all.sh stop     # the driver (stop runs: its gem5 runs too)
set -uo pipefail
PORT="${PORT:-2222}"
SRV="${SRV:-user@your-server}"
LROOT="${LROOT:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"
SRV_HOME="${SRV_HOME:-/home/harshraj}"
PREREG="bench/policy_sanity/fifo_check_design_2026-11-14.md"
UP=(scripts/fifo_server.sh scripts/fifo_check.py scripts/run_gem5_splash.sh)
SV="bash $SRV_HOME/gem5_fifo/fifo_server.sh"
MODE="${1:-}"
case "$MODE" in go|guards|status|list|pull|stop) ;; *) echo "usage: $0 go|guards|status|list|pull|stop [runs]"; exit 1 ;; esac
OUTD="${OUTD:-$LROOT/simulator/results/fifo}"
mkdir -p "$OUTD"
if [ "$MODE" = go ]; then
  LOG="$OUTD/fifo_all_$(date +%Y%m%d_%H%M%S).log"
  exec > >(tee -a "$LOG") 2>&1
fi
die() { echo; echo "STOPPED: $*"; exit 1; }

if [ "$MODE" = go ]; then
  echo "== local checks"
  bash -n "$LROOT/scripts/fifo_server.sh" || die "fifo_server.sh does not parse"
  bash -n "$LROOT/scripts/run_gem5_splash.sh" || die "run_gem5_splash.sh does not parse"
  for f in "$PREREG" "${UP[@]}" scripts/fifo_all.sh; do
    git -C "$LROOT" ls-files --error-unmatch "$f" > /dev/null 2>&1 || die "$f is not committed"
  done
  dirty=$(git -C "$LROOT" status --porcelain -- "${UP[@]}" scripts/fifo_all.sh "$PREREG")
  [ -z "$dirty" ] || { echo "$dirty"; die "uncommitted changes in what is uploaded -- commit first"; }
  grep -q '^## Build record' "$LROOT/$PREREG" || die "$PREREG has no build record (the rehearsal) yet"
  python3 "$LROOT/scripts/fifo_check.py" selftest | tail -1 | grep -q PASSES || die "fifo_check.py selftest fails"
  echo "   committed: $(git -C "$LROOT" log -1 --format='%h %s' | cut -c1-90)"
fi

CTL="$HOME/.ssh/cm-fifo-$$"
mkdir -p "$HOME/.ssh"
cleanup() { ssh -O exit -o ControlPath="$CTL" -p "$PORT" "$SRV" 2>/dev/null || true; rm -f "$CTL"; }
trap cleanup EXIT
ssh -p "$PORT" -o ControlMaster=yes -o ControlPath="$CTL" -o ControlPersist=20m \
    -o ServerAliveInterval=30 -o ConnectTimeout=40 -fN "$SRV" || { echo "could not connect (a locked key agent? see CLAUDE.md, server access)"; exit 1; }
R() { ssh -n -p "$PORT" -o ControlPath="$CTL" "$SRV" "$@"; }
RS=(rsync -a --copy-links -e "ssh -p $PORT -o ControlPath=$CTL")

case "$MODE" in
  guards|status|list|stop)
    R "[ -f $SRV_HOME/gem5_fifo/fifo_server.sh ] || { echo 'H1 not uploaded yet -- $0 go'; exit 0; }; $SV $MODE ${2:-}" 2>&1; exit 0 ;;
  pull)
    R "$SV status" 2>&1
    "${RS[@]}" --include='*/' --include='RESULT' --include='STARTED' --include='launch.log' --include='qf0.txt' \
      --include='run.log' --include='stats.txt' --include='config.ini' --exclude='*' \
      "$SRV:$SRV_HOME/gem5_b3/fifo/" "$OUTD/runs/" 2>/dev/null
    "${RS[@]}" "$SRV:$SRV_HOME/gem5_fifo/driver.log" "$OUTD/driver.log" 2>/dev/null
    echo "   pulled: $(find "$OUTD/runs" -name RESULT 2>/dev/null | wc -l) results to ${OUTD#"$LROOT"/}/runs/"
    exit 0 ;;
esac

echo "== upload into ~/gem5_fifo (to .new, then mv)"
R "f=$SRV_HOME/gem5_fifo/.driver.pid; [ -f \$f ] && kill -0 \$(cat \$f 2>/dev/null) 2>/dev/null" && die "the H1 driver is running already -- $0 status"
R "mkdir -p $SRV_HOME/gem5_fifo" || die "mkdir failed"
for f in "${UP[@]}"; do
  b=$(basename "$f")
  scp -q -P "$PORT" -o ControlPath="$CTL" "$LROOT/$f" "$SRV:$SRV_HOME/gem5_fifo/$b.new" || die "upload of $b failed"
  R "mv -f $SRV_HOME/gem5_fifo/$b.new $SRV_HOME/gem5_fifo/$b" || die "mv $b failed"
  l=$(md5sum < "$LROOT/$f" | cut -c1-32); r=$(R "md5sum < $SRV_HOME/gem5_fifo/$b | cut -c1-32")
  [ "$l" = "$r" ] || die "$b on the server reads $r, the laptop's $l"
  echo "   $b ($l)"
done
echo "== prepare, guards, then the driver -- detached on the server"
R "$SV chain" 2>&1 | sed 's/^/   /'
[ "${PIPESTATUS[0]}" = 0 ] || die "a guard failed or the driver did not start (above)"
sleep "${FOLLOW_S:-30}"
R "$SV status" 2>&1 | sed 's/^/   /'
echo
echo "Started: 13 gem5 runs with the strict FIFO check on, ${PAR:-4} at a time."
echo "Where it is:  $0 status      Results:  $0 pull"
echo "log: $LOG"
