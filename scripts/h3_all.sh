#!/usr/bin/env bash
# H3a (bench/policy_sanity/h3_statistics_design_2026-11-14.md): ChampSim's noise floor,
# 32 window-shifted runs of step 5's canneal 8c shared. Uploads (to .new, then mv)
# h3_server.sh into ~/h3; the server checks its guards and runs the driver DETACHED.
#
#   bash scripts/h3_all.sh go       # (owner's word) upload, guards, the driver
#   bash scripts/h3_all.sh guards   # read-only (after a go has uploaded)
#   bash scripts/h3_all.sh status   # read-only
#   bash scripts/h3_all.sh list     # read-only
#   bash scripts/h3_all.sh pull     # read-only: the runs' run.log, config.json, run.log.bin and the
#                                   # driver's log -> simulator/results/h3/
#   bash scripts/h3_all.sh stop [runs]
# Then: python3 scripts/h3_stats.py noise simulator/results/h3/logs simulator/results/policy/logs \
#         simulator/results/policy/sync_pol/cfg > bench/policy_sanity/h3_noise_v1.txt
#       python3 scripts/h3_stats.py score bench/policy_sanity/phasea_rows_v29.txt bench/policy_sanity/h3_noise_v1.txt
set -uo pipefail
PORT="${PORT:-2222}"
SRV="${SRV:-user@your-server}"
LROOT="${LROOT:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"
SRV_HOME="${SRV_HOME:-/home/harshraj}"
SRV_S="${SRV_S:-$SRV_HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy/simulator}"
PREREG="bench/policy_sanity/h3_statistics_design_2026-11-14.md"
SV="bash $SRV_HOME/h3/h3_server.sh"
MODE="${1:-}"
case "$MODE" in go|guards|status|list|pull|stop) ;; *) echo "usage: $0 go|guards|status|list|pull|stop [runs]"; exit 1 ;; esac
OUTD="${OUTD:-$LROOT/simulator/results/h3}"
mkdir -p "$OUTD"
if [ "$MODE" = go ]; then
  LOG="$OUTD/h3_all_$(date +%Y%m%d_%H%M%S).log"
  exec > >(tee -a "$LOG") 2>&1
fi
die() { echo; echo "STOPPED: $*"; exit 1; }

if [ "$MODE" = go ]; then
  echo "== local checks"
  bash -n "$LROOT/scripts/h3_server.sh" || die "h3_server.sh does not parse"
  for f in "$PREREG" scripts/h3_server.sh scripts/h3_all.sh scripts/h3_stats.py; do
    git -C "$LROOT" ls-files --error-unmatch "$f" > /dev/null 2>&1 || die "$f is not committed"
  done
  dirty=$(git -C "$LROOT" status --porcelain -- scripts/h3_server.sh scripts/h3_all.sh scripts/h3_stats.py "$PREREG")
  [ -z "$dirty" ] || { echo "$dirty"; die "uncommitted changes -- commit first"; }
  grep -q '^## Build record' "$LROOT/$PREREG" || die "$PREREG has no build record (the rehearsal) yet"
  st=$(python3 "$LROOT/scripts/h3_stats.py" selftest 2>&1 | tail -1); [[ "$st" == *PASSES* ]] || die "h3_stats.py selftest fails: $st"
  echo "   committed: $(git -C "$LROOT" log -1 --format='%h %s' | cut -c1-90)"
fi

CTL="$HOME/.ssh/cm-h3-$$"
mkdir -p "$HOME/.ssh"
cleanup() { ssh -O exit -o ControlPath="$CTL" -p "$PORT" "$SRV" 2>/dev/null || true; rm -f "$CTL"; }
trap cleanup EXIT
ssh -p "$PORT" -o ControlMaster=yes -o ControlPath="$CTL" -o ControlPersist=20m \
    -o ServerAliveInterval=30 -o ConnectTimeout=40 -fN "$SRV" || { echo "could not connect (a locked key agent? see CLAUDE.md, server access)"; exit 1; }
R() { ssh -n -p "$PORT" -o ControlPath="$CTL" "$SRV" "$@"; }
RS=(rsync -a --copy-links -e "ssh -p $PORT -o ControlPath=$CTL")

case "$MODE" in
  guards|status|list|stop)
    R "[ -f $SRV_HOME/h3/h3_server.sh ] || { echo 'H3 not uploaded yet -- $0 go'; exit 0; }; $SV $MODE ${2:-}" 2>&1; exit 0 ;;
  pull)
    R "$SV status" 2>&1
    mkdir -p "$OUTD/logs"
    "${RS[@]}" --include='phaseA_b3_h3w*/***' --exclude='*' "$SRV:$SRV_S/results/" "$OUTD/logs/" 2>/dev/null
    "${RS[@]}" "$SRV:$SRV_HOME/h3/driver.log" "$OUTD/driver.log" 2>/dev/null
    echo "   pulled: $(find "$OUTD/logs" -name run.log 2>/dev/null | wc -l) run logs to ${OUTD#"$LROOT"/}/logs"
    exit 0 ;;
esac

echo "== upload (to .new, then mv)"
R "f=$SRV_HOME/h3/.driver.pid; [ -f \$f ] && kill -0 \$(cat \$f 2>/dev/null) 2>/dev/null" && die "the H3 driver is running already -- $0 status"
R "mkdir -p $SRV_HOME/h3" || die "mkdir failed"
scp -q -P "$PORT" -o ControlPath="$CTL" "$LROOT/scripts/h3_server.sh" "$SRV:$SRV_HOME/h3/h3_server.sh.new" || die "upload failed"
R "mv -f $SRV_HOME/h3/h3_server.sh.new $SRV_HOME/h3/h3_server.sh" || die "mv failed"
l=$(md5sum < "$LROOT/scripts/h3_server.sh" | cut -c1-32); r=$(R "md5sum < $SRV_HOME/h3/h3_server.sh | cut -c1-32")
[ "$l" = "$r" ] || die "h3_server.sh on the server reads $r, the laptop's $l"
echo "   ~/h3/h3_server.sh ($l)"
echo "== guards, then the driver -- detached on the server"
R "$SV chain" 2>&1 | sed 's/^/   /'
[ "${PIPESTATUS[0]}" = 0 ] || die "a guard failed or the driver did not start (above)"
sleep "${FOLLOW_S:-30}"
R "$SV status" 2>&1 | sed 's/^/   /'
echo
echo "Started: H3a, 32 ChampSim runs at 8 cores, 8 at a time (the fixed class first)."
echo "Where it is:  $0 status      Results:  $0 pull"
echo "log: $LOG"
