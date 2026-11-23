#!/usr/bin/env bash
# Part B on the F-C binary (bench/policy_sanity/breadth_bc_design_2026-11-10.md,
# amendment 10): 35 reruns of Part B's ChampSim runs (and canneal 16 and three
# 4-core points) on champsim_fc_a2e88e46 with "sync_lock_word": "request",
# each once its reference run on the g6 binary has completed. Uploads
# partBfc_server.sh into ~/partBfc (.new + mv); the server checks its guards;
# the chain runs DETACHED there.
#
#   bash scripts/partBfc_all.sh go       # (owner's word) upload, guards, start the chain
#   bash scripts/partBfc_all.sh status   # read-only
#   bash scripts/partBfc_all.sh list     # read-only: each rerun, its tree, and whether its reference has completed
#   bash scripts/partBfc_all.sh pull     # read-only: the F-C logs and their references' logs to simulator/results/partB/stage2fc/
#   bash scripts/partBfc_all.sh stop     # the chain (its reruns)
set -uo pipefail
PORT="${PORT:-2222}"
SRV="${SRV:-user@your-server}"
LROOT="${LROOT:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"
SRV_HOME="${SRV_HOME:-/home/harshraj}"
PREREG="bench/policy_sanity/breadth_bc_design_2026-11-10.md"
SV="bash $SRV_HOME/partBfc/partBfc_server.sh"
SROOT="${SROOT:-$SRV_HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy/simulator}"
MODE="${1:-}"
case "$MODE" in go|status|list|pull|stop) ;; *) echo "usage: $0 go|status|list|pull|stop"; exit 1 ;; esac
OUTD="${OUTD:-$LROOT/simulator/results/partB/stage2fc}"
mkdir -p "$OUTD"
if [ "$MODE" = go ]; then
  LOG="$OUTD/partBfc_all_$(date +%Y%m%d_%H%M%S).log"
  exec > >(tee -a "$LOG") 2>&1
fi
die() { echo; echo "STOPPED: $*"; exit 1; }

if [ "$MODE" = go ]; then
  echo "== local checks"
  bash -n "$LROOT/scripts/partBfc_server.sh" || die "partBfc_server.sh does not parse"
  for f in "$PREREG" scripts/partBfc_server.sh scripts/partBfc_all.sh; do
    git -C "$LROOT" ls-files --error-unmatch "$f" > /dev/null 2>&1 || die "$f is not committed"
  done
  dirty=$(git -C "$LROOT" status --porcelain -- scripts/partBfc_server.sh scripts/partBfc_all.sh "$PREREG")
  [ -z "$dirty" ] || { echo "$dirty"; die "uncommitted changes in what is uploaded -- commit first"; }
  grep -q '^## Amendment 10, 2026-11-14' "$LROOT/$PREREG" || die "$PREREG has no amendment 10"
  echo "   committed: $(git -C "$LROOT" log -1 --format='%h %s' | cut -c1-90)"
fi

CTL="$HOME/.ssh/cm-partBfc-$$"
mkdir -p "$HOME/.ssh"
cleanup() { ssh -O exit -o ControlPath="$CTL" -p "$PORT" "$SRV" 2>/dev/null || true; rm -f "$CTL"; }
trap cleanup EXIT
ssh -p "$PORT" -o ControlMaster=yes -o ControlPath="$CTL" -o ControlPersist=20m \
    -o ServerAliveInterval=30 -o ConnectTimeout=40 -fN "$SRV" || { echo "could not connect (a locked key agent? see CLAUDE.md, server access)"; exit 1; }
R() { ssh -n -p "$PORT" -o ControlPath="$CTL" "$SRV" "$@"; }
RS=(rsync -a --copy-links -e "ssh -p $PORT -o ControlPath=$CTL")

case "$MODE" in
  status|list|stop) R "[ -f $SRV_HOME/partBfc/partBfc_server.sh ] || { echo 'partBfc not uploaded yet -- $0 go'; exit 0; }; $SV $MODE" 2>&1; exit 0 ;;
  pull)
    R "$SV status" 2>&1
    mkdir -p "$OUTD/logs" "$OUTD/ref"
    # the F-C trees (run.log and its .bin), and each rerun's reference run.log (for qualify)
    R "$SV list" 2>/dev/null | awk '{ print $2 }' | while read -r t; do
      [ -n "$t" ] || continue
      "${RS[@]}" --include='*/' --include='run.log' --include='run.log.bin' --exclude='*' "$SRV:$SROOT/results/$t" "$OUTD/logs/" 2>/dev/null
      r="phaseA_b3_${t#phaseA_b3_fc_}"
      if [ "${r#phaseA_b3_p2_}" != "$r" ]; then
        "${RS[@]}" --include='*/' --include='lru/' --include='lru/run.log' --exclude='*' "$SRV:$SROOT/results/$r" "$OUTD/ref/" 2>/dev/null
      else
        "${RS[@]}" --include='*/' --include='run.log' --exclude='*' "$SRV:$SROOT/results/$r" "$OUTD/ref/" 2>/dev/null
      fi
    done
    "${RS[@]}" --include='driver.log' --include='cfg/***' --exclude='*' "$SRV:$SRV_HOME/partBfc/" "$OUTD/server/" 2>/dev/null
    cp -p "$OUTD/server/driver.log" "$OUTD/driver.log" 2>/dev/null
    echo "   pulled: $(find "$OUTD/logs" -name run.log | wc -l) F-C logs, $(find "$OUTD/ref" -name run.log | wc -l) reference logs to ${OUTD#"$LROOT"/}/ (nothing read)"
    exit 0 ;;
esac

echo "== upload partBfc_server.sh into ~/partBfc (to .new, then mv)"
R "f=$SRV_HOME/partBfc/.driver.pid; [ -f \$f ] && kill -0 \$(cat \$f 2>/dev/null) 2>/dev/null" && die "the partBfc chain is running already -- $0 status"
R "mkdir -p $SRV_HOME/partBfc" || die "mkdir failed"
scp -q -P "$PORT" -o ControlPath="$CTL" "$LROOT/scripts/partBfc_server.sh" "$SRV:$SRV_HOME/partBfc/partBfc_server.sh.new" || die "upload failed"
R "mv -f $SRV_HOME/partBfc/partBfc_server.sh.new $SRV_HOME/partBfc/partBfc_server.sh" || die "mv failed"
l=$(md5sum < "$LROOT/scripts/partBfc_server.sh" | cut -c1-32); r=$(R "md5sum < $SRV_HOME/partBfc/partBfc_server.sh | cut -c1-32")
[ "$l" = "$r" ] || die "partBfc_server.sh on the server reads $r, the laptop's $l"
echo "   uploaded ($(git -C "$LROOT" rev-parse --short HEAD))"
echo "== guards, then the chain -- detached on the server"
R "$SV chain" 2>&1 | sed 's/^/   /'
[ "${PIPESTATUS[0]}" = 0 ] || die "a guard failed or the chain did not start (above)"
sleep "${FOLLOW_S:-20}"
R "$SV status" 2>&1 | sed 's/^/   /'
echo
echo "Started: 35 reruns on the F-C binary, 8 at a time; each waits for its reference run."
echo "Where it is:  $0 status      Each rerun:  $0 list      Logs:  $0 pull"
echo "log: $LOG"
