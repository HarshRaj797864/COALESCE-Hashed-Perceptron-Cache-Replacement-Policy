#!/usr/bin/env bash
# H6(a) (bench/policy_sanity/h6_lockreq_design_2026-11-14.md): one records-only run of
# barnes std start on the F-C binary with the coherence event log, then QE0, the
# request pairs and the classes, all on the server. Uploads (to .new, then mv)
# h6_server.sh and h6_lockreq.py into ~/h6.
#
#   bash scripts/h6_all.sh go       # (owner's word) upload, guards, the run (detached)
#   bash scripts/h6_all.sh status   # read-only
#   bash scripts/h6_all.sh pull     # read-only: run.log, qe0.txt, pairs.txt, summary.txt, driver.log
#                                   # (and events.log.xz with EVENTS=1) -> simulator/results/h6/
set -uo pipefail
PORT="${PORT:-2222}"
SRV="${SRV:-user@your-server}"
LROOT="${LROOT:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"
SRV_HOME="${SRV_HOME:-/home/harshraj}"
PREREG="bench/policy_sanity/h6_lockreq_design_2026-11-14.md"
SV="bash $SRV_HOME/h6/h6_server.sh"
MODE="${1:-}"
case "$MODE" in go|status|pull) ;; *) echo "usage: $0 go|status|pull"; exit 1 ;; esac
OUTD="${OUTD:-$LROOT/simulator/results/h6}"
mkdir -p "$OUTD"
die() { echo; echo "STOPPED: $*"; exit 1; }
if [ "$MODE" = go ]; then
  echo "== local checks"
  bash -n "$LROOT/scripts/h6_server.sh" || die "h6_server.sh does not parse"
  for f in "$PREREG" scripts/h6_server.sh scripts/h6_all.sh scripts/h6_lockreq.py; do
    git -C "$LROOT" ls-files --error-unmatch "$f" > /dev/null 2>&1 || die "$f is not committed"
  done
  dirty=$(git -C "$LROOT" status --porcelain -- scripts/h6_server.sh scripts/h6_all.sh scripts/h6_lockreq.py "$PREREG")
  [ -z "$dirty" ] || { echo "$dirty"; die "uncommitted changes -- commit first"; }
  grep -q '^## Build and rehearsal record' "$LROOT/$PREREG" || die "$PREREG has no build and rehearsal record yet"
  st=$(python3 "$LROOT/scripts/h6_lockreq.py" selftest 2>/dev/null | tail -1); [ "$st" = "selftest PASS" ] || die "h6_lockreq.py selftest fails: $st"
fi
CTL="$HOME/.ssh/cm-h6-$$"
mkdir -p "$HOME/.ssh"
cleanup() { ssh -O exit -o ControlPath="$CTL" -p "$PORT" "$SRV" 2>/dev/null || true; rm -f "$CTL"; }
trap cleanup EXIT
ssh -p "$PORT" -o ControlMaster=yes -o ControlPath="$CTL" -o ControlPersist=20m \
    -o ServerAliveInterval=30 -o ConnectTimeout=40 -fN "$SRV" || { echo "could not connect (a locked key agent? see CLAUDE.md, server access)"; exit 1; }
R() { ssh -n -p "$PORT" -o ControlPath="$CTL" "$SRV" "$@"; }
RS=(rsync -a --copy-links -e "ssh -p $PORT -o ControlPath=$CTL")
case "$MODE" in
  status) R "[ -f $SRV_HOME/h6/h6_server.sh ] || { echo 'H6 not uploaded yet'; exit 0; }; $SV status" 2>&1; exit 0 ;;
  pull)
    R "$SV status" 2>&1
    inc=(--include='run.log' --include='qe0.txt' --include='pairs.txt' --include='pairs.err' --include='summary.txt' --include='driver.log' --include='DONE')
    [ "${EVENTS:-0}" = 1 ] && inc+=(--include='events.log.xz')
    "${RS[@]}" "${inc[@]}" --exclude='*' "$SRV:$SRV_HOME/h6/" "$OUTD/" 2>/dev/null
    echo "   pulled to ${OUTD#"$LROOT"/}: $(ls "$OUTD" | tr '\n' ' ')"
    exit 0 ;;
esac
echo "== upload (to .new, then mv)"
R "f=$SRV_HOME/h6/.pid; [ -f \$f ] && kill -0 \$(cat \$f 2>/dev/null) 2>/dev/null" && die "the H6 run is running already -- $0 status"
R "mkdir -p $SRV_HOME/h6" || die "mkdir failed"
for f in h6_server.sh h6_lockreq.py; do
  scp -q -P "$PORT" -o ControlPath="$CTL" "$LROOT/scripts/$f" "$SRV:$SRV_HOME/h6/$f.new" || die "upload of $f failed"
  R "mv -f $SRV_HOME/h6/$f.new $SRV_HOME/h6/$f" || die "mv of $f failed"
  l=$(md5sum < "$LROOT/scripts/$f" | cut -c1-32); r=$(R "md5sum < $SRV_HOME/h6/$f | cut -c1-32")
  [ "$l" = "$r" ] || die "$f on the server reads $r, the laptop's $l"
  echo "   ~/h6/$f ($l)"
done
echo "== guards, then the run -- detached on the server"
R "$SV go" 2>&1 | sed 's/^/   /'
[ "${PIPESTATUS[0]}" = 0 ] || die "a guard failed or the run did not start (above)"
echo; echo "Started: H6(a). Where it is: $0 status   Results: $0 pull"
