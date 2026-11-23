#!/usr/bin/env bash
# H6(b) (bench/policy_sanity/h6b_attribution_design_2026-11-14.md): QP, then gem5 reruns with
# ProtocolTrace and ChampSim runs with the coherence event log for fluidanimate, vips
# and canneal 4c, then the attribution and the reports, all on the server. Uploads
# (to .new, then mv) h6b_server.sh, h6b_attr.py and h6_lockreq.py into ~/h6b.
#
#   bash scripts/h6b_all.sh go       # (owner's word) upload, guards, the chain (detached)
#   bash scripts/h6b_all.sh go2      # (amendment 2) the same after QP FAILED: the failed QP's files are
#                                    # kept as ~/h6b/qp.fail_a1_<time>, then QP and the chain again
#   bash scripts/h6b_all.sh status   # read-only
#   bash scripts/h6b_all.sh pull     # read-only: reports, QP results, event files, checks -> simulator/results/h6b/
set -uo pipefail
PORT="${PORT:-2222}"
SRV="${SRV:-user@your-server}"
LROOT="${LROOT:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"
SRV_HOME="${SRV_HOME:-/home/harshraj}"
PREREG="bench/policy_sanity/h6b_attribution_design_2026-11-14.md"
SV="bash $SRV_HOME/h6b/h6b_server.sh"
MODE="${1:-}"
case "$MODE" in go|go2|status|pull) ;; *) echo "usage: $0 go|go2|status|pull"; exit 1 ;; esac
OUTD="${OUTD:-$LROOT/simulator/results/h6b}"
mkdir -p "$OUTD"
die() { echo; echo "STOPPED: $*"; exit 1; }
if [ "$MODE" = go ] || [ "$MODE" = go2 ]; then
  echo "== local checks"
  bash -n "$LROOT/scripts/h6b_server.sh" || die "h6b_server.sh does not parse"
  for f in "$PREREG" scripts/h6b_server.sh scripts/h6b_all.sh scripts/h6b_attr.py scripts/h6_lockreq.py; do
    git -C "$LROOT" ls-files --error-unmatch "$f" > /dev/null 2>&1 || die "$f is not committed"
  done
  dirty=$(git -C "$LROOT" status --porcelain -- scripts/h6b_server.sh scripts/h6b_all.sh scripts/h6b_attr.py scripts/h6_lockreq.py "$PREREG")
  [ -z "$dirty" ] || { echo "$dirty"; die "uncommitted changes -- commit first"; }
  grep -q '^## Build and rehearsal record' "$LROOT/$PREREG" || die "$PREREG has no build and rehearsal record yet"
  [ "$MODE" = go ] || grep -q '^## Amendment 2' "$LROOT/$PREREG" || die "$PREREG has no amendment 2 yet"
  for t in h6b_attr.py h6_lockreq.py; do st=$(python3 "$LROOT/scripts/$t" selftest 2>/dev/null | tail -1); [ "$st" = "selftest PASS" ] || die "$t selftest fails: $st"; done
fi
CTL="$HOME/.ssh/cm-h6b-$$"
mkdir -p "$HOME/.ssh"
cleanup() { ssh -O exit -o ControlPath="$CTL" -p "$PORT" "$SRV" 2>/dev/null || true; rm -f "$CTL"; }
trap cleanup EXIT
ssh -p "$PORT" -o ControlMaster=yes -o ControlPath="$CTL" -o ControlPersist=20m \
    -o ServerAliveInterval=30 -o ConnectTimeout=40 -fN "$SRV" || { echo "could not connect (a locked key agent? see CLAUDE.md, server access)"; exit 1; }
R() { ssh -n -p "$PORT" -o ControlPath="$CTL" "$SRV" "$@"; }
RS=(rsync -a --copy-links -e "ssh -p $PORT -o ControlPath=$CTL")
case "$MODE" in
  status) R "[ -f $SRV_HOME/h6b/h6b_server.sh ] || { echo 'H6(b) not uploaded yet'; exit 0; }; $SV status" 2>&1; exit 0 ;;
  pull)
    R "$SV status" 2>&1
    inc=(--include='*/' --include='driver.log' --include='DONE' --include='report_*.txt' --include='qp.txt' --include='ev.txt' --include='qg1.txt'
         --include='qe0.txt' --include='command.txt' --include='pipe.rc' --include='run.log' --include='stats.txt' --include='attr.err' --include='rmw.err' --include='gem5.err')
    "${RS[@]}" "${inc[@]}" --exclude='*' "$SRV:$SRV_HOME/h6b/" "$OUTD/" 2>/dev/null
    echo "   pulled to ${OUTD#"$LROOT"/}: $(cd "$OUTD" && ls | tr '\n' ' ')"
    exit 0 ;;
esac
echo "== upload (to .new, then mv)"
R "f=$SRV_HOME/h6b/.pid; [ -f \$f ] && kill -0 \$(cat \$f 2>/dev/null) 2>/dev/null" && die "H6(b) is running already -- $0 status"
R "mkdir -p $SRV_HOME/h6b" || die "mkdir failed"
for f in h6b_server.sh h6b_attr.py h6_lockreq.py; do
  scp -q -P "$PORT" -o ControlPath="$CTL" "$LROOT/scripts/$f" "$SRV:$SRV_HOME/h6b/$f.new" || die "upload of $f failed"
  R "mv -f $SRV_HOME/h6b/$f.new $SRV_HOME/h6b/$f" || die "mv of $f failed"
  l=$(md5sum < "$LROOT/scripts/$f" | cut -c1-32); r=$(R "md5sum < $SRV_HOME/h6b/$f | cut -c1-32")
  [ "$l" = "$r" ] || die "$f on the server reads $r, the laptop's $l"
  echo "   ~/h6b/$f ($l)"
done
echo "== guards, then the chain -- detached on the server"
R "$SV $MODE" 2>&1 | sed 's/^/   /'
[ "${PIPESTATUS[0]}" = 0 ] || die "a guard failed or the chain did not start (above)"
echo; echo "Started: H6(b). Where it is: $0 status   Results: $0 pull"
