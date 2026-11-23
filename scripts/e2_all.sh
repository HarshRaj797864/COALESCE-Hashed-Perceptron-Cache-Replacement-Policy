#!/usr/bin/env bash
# E (bench/policy_sanity/second_protocol_design_2026-11-18.md), from the laptop. Each step on the owner's word:
#
#   scripts/e2_all.sh go       # uploads e2_server.sh, e2_check.py, hset_check.py and the runner (as E's copy,
#                              # ~/e2/run_gem5_splash.sh; the live ~/run_gem5_splash.sh is not touched), each to
#                              # .new then mv, md5-checked; then the guards and, detached, the driver: the
#                              # MESI_Two_Level build in ~/gem5_two, QL1's micro runs, the 8 runs with QL0 each
#   scripts/e2_all.sh guards | status | list     # read-only
#   scripts/e2_all.sh pull     # read-only: E's gem5 outputs, the micro runs, state and logs to simulator/results/e2/
#   scripts/e2_all.sh stop [runs]
#
# A dropped connection stops nothing.
set -uo pipefail
PORT="${PORT:-2222}"
SRV="${SRV:-user@your-server}"
LROOT="${LROOT:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"
SRV_HOME="${SRV_HOME:-/home/harshraj}"
PREREG="bench/policy_sanity/second_protocol_design_2026-11-18.md"
UP="scripts/e2_server.sh:e2/e2_server.sh
scripts/e2_check.py:e2/e2_check.py
scripts/hset_check.py:e2/hset_check.py
scripts/run_gem5_splash.sh:e2/run_gem5_splash.sh"
SV="bash $SRV_HOME/e2/e2_server.sh"
MODE="${1:-}"
case "$MODE" in go|guards|status|list|pull|stop) ;; *) echo "usage: $0 go|guards|status|list|pull|stop [runs]"; exit 1 ;; esac
OUTD="${OUTD:-$LROOT/simulator/results/e2}"
mkdir -p "$OUTD"
if [ "$MODE" = go ]; then
  LOG="$OUTD/e2_all_go_$(date +%Y%m%d_%H%M%S).log"
  exec > >(tee -a "$LOG") 2>&1
fi
die() { echo; echo "STOPPED: $*"; exit 1; }

if [ "$MODE" = go ]; then
  echo "== local checks"
  bash -n "$LROOT/scripts/e2_server.sh" || die "e2_server.sh does not parse"
  for f in "$PREREG" $(echo "$UP" | cut -d: -f1) scripts/e2_all.sh; do
    git -C "$LROOT" ls-files --error-unmatch "$f" > /dev/null 2>&1 || die "$f is not committed"
  done
  # shellcheck disable=SC2046 -- a list of paths
  dirty=$(git -C "$LROOT" status --porcelain -- $(echo "$UP" | cut -d: -f1) scripts/e2_all.sh "$PREREG")
  [ -z "$dirty" ] || { echo "$dirty"; die "uncommitted changes in what is uploaded -- commit first"; }
  st=$(python3 "$LROOT/scripts/e2_check.py" selftest 2>&1 | tail -1); [[ "$st" == *"0 fail"* ]] || die "e2_check.py selftest fails: $st"
  echo "   committed: $(git -C "$LROOT" log -1 --format='%h %s' | cut -c1-90)"
fi

CTL="$HOME/.ssh/cm-e2-$$"
mkdir -p "$HOME/.ssh"
cleanup() { ssh -O exit -o ControlPath="$CTL" -p "$PORT" "$SRV" 2>/dev/null || true; rm -f "$CTL"; }
trap cleanup EXIT
ssh -p "$PORT" -o ControlMaster=yes -o ControlPath="$CTL" -o ControlPersist=20m \
    -o ServerAliveInterval=30 -o ConnectTimeout=40 -fN "$SRV" || { echo "could not connect (a locked key agent? see CLAUDE.md, server access)"; exit 1; }
R() { ssh -n -p "$PORT" -o ControlPath="$CTL" "$SRV" "$@"; }
RS=(rsync -a --copy-links -e "ssh -p $PORT -o ControlPath=$CTL")

case "$MODE" in
  guards|status|list|stop)
    R "[ -f $SRV_HOME/e2/e2_server.sh ] || { echo 'E not uploaded yet -- $0 go'; exit 0; }; $SV $MODE ${2:-}" 2>&1; exit 0 ;;
  pull)
    R "$SV status" 2>&1
    mkdir -p "$OUTD/gem5" "$OUTD/g5micro" "$OUTD/state"
    "${RS[@]}" --include='*/' --include='run.log' --include='stats.txt' --include='config.ini' --exclude='*' "$SRV:$SRV_HOME/gem5_b3/e2/" "$OUTD/gem5/" 2>/dev/null
    "${RS[@]}" --include='*/' --include='run.log' --include='stats.txt' --include='config.ini' --exclude='*' "$SRV:$SRV_HOME/e2/g5micro/gem5/" "$OUTD/g5micro/" 2>/dev/null
    "${RS[@]}" "$SRV:$SRV_HOME/e2/state/" "$OUTD/state/" 2>/dev/null
    for f in driver.log ql1_driver.log ql1.txt BUILD_OK QL1_PASSED build_defconfig.log; do "${RS[@]}" "$SRV:$SRV_HOME/e2/$f" "$OUTD/$f" 2>/dev/null; done
    echo "   pulled: $(find "$OUTD/gem5" -name stats.txt 2>/dev/null | wc -l) gem5 statistics, $(find "$OUTD/g5micro" -name stats.txt 2>/dev/null | wc -l) micro runs, to ${OUTD#"$LROOT"/}/"
    exit 0 ;;
esac

echo "== upload (to .new, then mv)"
R "f=$SRV_HOME/e2/.driver.pid; [ -f \$f ] && kill -0 \$(cat \$f 2>/dev/null) 2>/dev/null" && die "the E driver is running already -- $0 status"
R "mkdir -p $SRV_HOME/e2" || die "mkdir failed"
while IFS=: read -r f dst; do
  scp -q -P "$PORT" -o ControlPath="$CTL" "$LROOT/$f" "$SRV:$SRV_HOME/$dst.new" || die "upload of $f failed"
  R "mv -f $SRV_HOME/$dst.new $SRV_HOME/$dst" || die "mv $dst failed"
  l=$(md5sum < "$LROOT/$f" | cut -c1-32); r=$(R "md5sum < $SRV_HOME/$dst | cut -c1-32")
  [ "$l" = "$r" ] || die "$dst differs from the laptop's $f"
  echo "   $dst (md5 ${l:0:8})"
done <<< "$UP"
echo "== the server: guards, then the driver"
R "$SV go" 2>&1 | sed 's/^/   /'
[ "${PIPESTATUS[0]}" = 0 ] || die "not started (above)"
echo "Where it is:  $0 status   (the build takes hours at the server's load; then QL1's micro runs and the 8 runs)"
echo "log: $LOG"
