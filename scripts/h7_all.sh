#!/usr/bin/env bash
# H7 (bench/policy_sanity/policy_rerun_design_2026-10-19.md, amendment 3): step 5's 171
# runs on the F-C binary. Uploads (to .new, then mv) h7_server.sh and the job lines
# (policy_jobs.py's output) into ~/h7; the server checks its guards and runs the chain
# DETACHED.
#
#   bash scripts/h7_all.sh go       # (owner's word) upload, guards, the chain
#   bash scripts/h7_all.sh guards   # read-only (after a go has uploaded)
#   bash scripts/h7_all.sh status   # read-only
#   bash scripts/h7_all.sh list     # read-only
#   bash scripts/h7_all.sh pull     # read-only: the p3 trees' run.log and run.log.bin, ~/h7/cfg and the
#                                   # driver's log -> simulator/results/h7/
#   bash scripts/h7_all.sh stop
# Then the scoring commands in amendment 3 ("Scoring").
set -uo pipefail
PORT="${PORT:-2222}"
SRV="${SRV:-user@your-server}"
LROOT="${LROOT:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"
SRV_HOME="${SRV_HOME:-/home/harshraj}"
SRV_S="${SRV_S:-$SRV_HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy/simulator}"
PREREG="bench/policy_sanity/policy_rerun_design_2026-10-19.md"
SV="bash $SRV_HOME/h7/h7_server.sh"
MODE="${1:-}"
case "$MODE" in go|guards|status|list|pull|stop) ;; *) echo "usage: $0 go|guards|status|list|pull|stop"; exit 1 ;; esac
OUTD="${OUTD:-$LROOT/simulator/results/h7}"
mkdir -p "$OUTD"
if [ "$MODE" = go ]; then
  LOG="$OUTD/h7_all_$(date +%Y%m%d_%H%M%S).log"
  exec > >(tee -a "$LOG") 2>&1
fi
die() { echo; echo "STOPPED: $*"; exit 1; }

if [ "$MODE" = go ]; then
  echo "== local checks"
  bash -n "$LROOT/scripts/h7_server.sh" || die "h7_server.sh does not parse"
  for f in "$PREREG" scripts/h7_server.sh scripts/h7_all.sh scripts/policy_jobs.py scripts/policy_score.py; do
    git -C "$LROOT" ls-files --error-unmatch "$f" > /dev/null 2>&1 || die "$f is not committed"
  done
  dirty=$(git -C "$LROOT" status --porcelain -- scripts/h7_server.sh scripts/h7_all.sh scripts/policy_jobs.py scripts/policy_score.py "$PREREG")
  [ -z "$dirty" ] || { echo "$dirty"; die "uncommitted changes -- commit first"; }
  grep -q '^## Amendment 3, 2026-11-14: H7' "$LROOT/$PREREG" || die "$PREREG has no amendment 3 (H7)"
  grep -q '^\*\*H7 build and rehearsal record' "$LROOT/$PREREG" || die "$PREREG has no H7 build and rehearsal record yet"
  st=$(python3 "$LROOT/scripts/policy_score.py" selftest 2>&1 | tail -1); [ "$st" = "selftest PASS" ] || die "policy_score.py selftest fails: $st"
  JOBS_FILE="$(mktemp)"
  python3 "$LROOT/scripts/policy_jobs.py" > "$JOBS_FILE" || die "policy_jobs.py failed"
  [ "$(wc -l < "$JOBS_FILE")" = 171 ] || die "expected 171 job lines"
  echo "   committed: $(git -C "$LROOT" log -1 --format='%h %s' | cut -c1-90)"
fi

CTL="$HOME/.ssh/cm-h7-$$"
mkdir -p "$HOME/.ssh"
cleanup() { ssh -O exit -o ControlPath="$CTL" -p "$PORT" "$SRV" 2>/dev/null || true; rm -f "$CTL" "${JOBS_FILE:-}"; }
trap cleanup EXIT
ssh -p "$PORT" -o ControlMaster=yes -o ControlPath="$CTL" -o ControlPersist=20m \
    -o ServerAliveInterval=30 -o ConnectTimeout=40 -fN "$SRV" || { echo "could not connect (a locked key agent? see CLAUDE.md, server access)"; exit 1; }
R() { ssh -n -p "$PORT" -o ControlPath="$CTL" "$SRV" "$@"; }
RS=(rsync -a --copy-links -e "ssh -p $PORT -o ControlPath=$CTL")

case "$MODE" in
  guards|status|list|stop)
    R "[ -f $SRV_HOME/h7/h7_server.sh ] || { echo 'H7 not uploaded yet -- $0 go'; exit 0; }; $SV $MODE" 2>&1; exit 0 ;;
  pull)
    R "$SV status" 2>&1
    mkdir -p "$OUTD/logs" "$OUTD/cfg"
    "${RS[@]}" --include='phaseA_b3_p3_*/***' --exclude='*' "$SRV:$SRV_S/results/" "$OUTD/logs/" 2>/dev/null
    "${RS[@]}" "$SRV:$SRV_HOME/h7/cfg/" "$OUTD/cfg/" 2>/dev/null
    "${RS[@]}" "$SRV:$SRV_HOME/h7/driver.log" "$OUTD/driver.log" 2>/dev/null
    echo "   pulled: $(find "$OUTD/logs" -name run.log 2>/dev/null | wc -l) run logs to ${OUTD#"$LROOT"/}/logs, $(ls "$OUTD"/cfg/*.json 2>/dev/null | wc -l) configs"
    exit 0 ;;
esac

echo "== upload (to .new, then mv)"
R "f=$SRV_HOME/h7/.driver.pid; [ -f \$f ] && kill -0 \$(cat \$f 2>/dev/null) 2>/dev/null" && die "the H7 chain is running already -- $0 status"
R "mkdir -p $SRV_HOME/h7" || die "mkdir failed"
for pair in "$LROOT/scripts/h7_server.sh:h7_server.sh" "$JOBS_FILE:JOBS"; do
  src=${pair%%:*}; dst=${pair##*:}
  scp -q -P "$PORT" -o ControlPath="$CTL" "$src" "$SRV:$SRV_HOME/h7/$dst.new" || die "upload of $dst failed"
  R "mv -f $SRV_HOME/h7/$dst.new $SRV_HOME/h7/$dst" || die "mv of $dst failed"
  l=$(md5sum < "$src" | cut -c1-32); r=$(R "md5sum < $SRV_HOME/h7/$dst | cut -c1-32")
  [ "$l" = "$r" ] || die "$dst on the server reads $r, the laptop's $l"
  echo "   ~/h7/$dst ($l)"
done
echo "== guards, then the chain -- detached on the server"
R "$SV chain" 2>&1 | sed 's/^/   /'
[ "${PIPESTATUS[0]}" = 0 ] || die "a guard failed or the chain did not start (above)"
sleep "${FOLLOW_S:-30}"
R "$SV status" 2>&1 | sed 's/^/   /'
echo
echo "Started: H7, step 5's 171 runs on the F-C binary, 12 at a time (16 cores first)."
echo "Where it is:  $0 status      Results:  $0 pull"
echo "log: $LOG"
