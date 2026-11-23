#!/usr/bin/env bash
# C0f (bench/policy_sanity/c0f_latency_final_design_2026-11-23.md): the invalidation latency on
# the final binary, step 5's 27 fixed-2 MB shared jobs at L = 0 and 100. Uploads (to .new, then mv)
# c0f_server.sh and the 27 job lines (policy_jobs.py's lines with suffix canneal4 / canneal8 / ocean4,
# regime shared) into ~/c0f; the server checks its guards and runs the chain DETACHED.
#
#   bash scripts/c0f_all.sh go       # (owner's word) upload, guards, the chain
#   bash scripts/c0f_all.sh guards   # read-only (after a go has uploaded)
#   bash scripts/c0f_all.sh status   # read-only
#   bash scripts/c0f_all.sh list     # read-only
#   bash scripts/c0f_all.sh pull     # read-only: the c0f trees' run.log and run.log.bin, ~/c0f/cfg and the
#                                    # driver's log -> simulator/results/c0f/
#   bash scripts/c0f_all.sh stop
# Then scripts/c0f_score.py (the design's "Tools").
set -uo pipefail
PORT="${PORT:-2222}"
SRV="${SRV:-user@your-server}"
LROOT="${LROOT:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"
SRV_HOME="${SRV_HOME:-/home/harshraj}"
SRV_S="${SRV_S:-$SRV_HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy/simulator}"
PREREG="bench/policy_sanity/c0f_latency_final_design_2026-11-23.md"
SV="bash $SRV_HOME/c0f/c0f_server.sh"
MODE="${1:-}"
case "$MODE" in go|guards|status|list|pull|stop) ;; *) echo "usage: $0 go|guards|status|list|pull|stop"; exit 1 ;; esac
OUTD="${OUTD:-$LROOT/simulator/results/c0f}"
mkdir -p "$OUTD"
if [ "$MODE" = go ]; then
  LOG="$OUTD/c0f_all_$(date +%Y%m%d_%H%M%S).log"
  exec > >(tee -a "$LOG") 2>&1
fi
die() { echo; echo "STOPPED: $*"; exit 1; }

if [ "$MODE" = go ]; then
  echo "== local checks"
  bash -n "$LROOT/scripts/c0f_server.sh" || die "c0f_server.sh does not parse"
  for f in "$PREREG" scripts/c0f_server.sh scripts/c0f_all.sh scripts/c0f_score.py scripts/policy_jobs.py scripts/policy_score.py; do
    git -C "$LROOT" ls-files --error-unmatch "$f" > /dev/null 2>&1 || die "$f is not committed"
  done
  dirty=$(git -C "$LROOT" status --porcelain -- scripts/c0f_server.sh scripts/c0f_all.sh scripts/c0f_score.py scripts/policy_jobs.py scripts/policy_score.py "$PREREG")
  [ -z "$dirty" ] || { echo "$dirty"; die "uncommitted changes -- commit first"; }
  grep -q '^## Build and rehearsal record' "$LROOT/$PREREG" || die "$PREREG has no build and rehearsal record yet"
  st=$(python3 "$LROOT/scripts/c0f_score.py" selftest 2>&1 | tail -1); [ "$st" = "selftest PASS" ] || die "c0f_score.py selftest fails: $st"
  JOBS_FILE="$(mktemp)"
  python3 "$LROOT/scripts/policy_jobs.py" | awk -F'|' '($1 == "canneal4" || $1 == "canneal8" || $1 == "ocean4") && $9 == "shared"' > "$JOBS_FILE" || die "policy_jobs.py failed"
  [ "$(wc -l < "$JOBS_FILE")" = 27 ] || die "expected 27 job lines"
  want=$(grep -o 'JOBS_MD5:-[0-9a-f]*' "$LROOT/scripts/c0f_server.sh" | cut -d- -f2)
  [ "$(md5sum < "$JOBS_FILE" | cut -c1-32)" = "$want" ] || die "the 27 job lines are not md5 $want"
  echo "   committed: $(git -C "$LROOT" log -1 --format='%h %s' | cut -c1-90)"
fi

CTL="$HOME/.ssh/cm-c0f-$$"
mkdir -p "$HOME/.ssh"
cleanup() { ssh -O exit -o ControlPath="$CTL" -p "$PORT" "$SRV" 2>/dev/null || true; rm -f "$CTL" "${JOBS_FILE:-}"; }
trap cleanup EXIT
ssh -p "$PORT" -o ControlMaster=yes -o ControlPath="$CTL" -o ControlPersist=20m \
    -o ServerAliveInterval=30 -o ConnectTimeout=40 -fN "$SRV" || { echo "could not connect (a locked key agent? see CLAUDE.md, server access)"; exit 1; }
R() { ssh -n -p "$PORT" -o ControlPath="$CTL" "$SRV" "$@"; }
RS=(rsync -a --copy-links -e "ssh -p $PORT -o ControlPath=$CTL")

case "$MODE" in
  guards|status|list|stop)
    R "[ -f $SRV_HOME/c0f/c0f_server.sh ] || { echo 'C0f not uploaded yet -- $0 go'; exit 0; }; $SV $MODE" 2>&1; exit 0 ;;
  pull)
    R "$SV status" 2>&1
    mkdir -p "$OUTD/logs" "$OUTD/cfg"
    "${RS[@]}" --include='phaseA_b3_c0f*/***' --exclude='*' "$SRV:$SRV_S/results/" "$OUTD/logs/" 2>/dev/null
    "${RS[@]}" "$SRV:$SRV_HOME/c0f/cfg/" "$OUTD/cfg/" 2>/dev/null
    "${RS[@]}" "$SRV:$SRV_HOME/c0f/driver.log" "$OUTD/driver.log" 2>/dev/null
    echo "   pulled: $(find "$OUTD/logs" -name run.log 2>/dev/null | wc -l) run logs to ${OUTD#"$LROOT"/}/logs, $(ls "$OUTD"/cfg/*.json 2>/dev/null | wc -l) configs"
    exit 0 ;;
esac

echo "== upload (to .new, then mv)"
R "f=$SRV_HOME/c0f/.driver.pid; [ -f \$f ] && kill -0 \$(cat \$f 2>/dev/null) 2>/dev/null" && die "the C0f chain is running already -- $0 status"
R "mkdir -p $SRV_HOME/c0f" || die "mkdir failed"
for pair in "$LROOT/scripts/c0f_server.sh:c0f_server.sh" "$JOBS_FILE:JOBS"; do
  src=${pair%%:*}; dst=${pair##*:}
  scp -q -P "$PORT" -o ControlPath="$CTL" "$src" "$SRV:$SRV_HOME/c0f/$dst.new" || die "upload of $dst failed"
  R "mv -f $SRV_HOME/c0f/$dst.new $SRV_HOME/c0f/$dst" || die "mv of $dst failed"
  l=$(md5sum < "$src" | cut -c1-32); r=$(R "md5sum < $SRV_HOME/c0f/$dst | cut -c1-32")
  [ "$l" = "$r" ] || die "$dst on the server reads $r, the laptop's $l"
  echo "   ~/c0f/$dst ($l)"
done
echo "== guards, then the chain -- detached on the server"
R "$SV chain" 2>&1 | sed 's/^/   /'
[ "${PIPESTATUS[0]}" = 0 ] || die "a guard failed or the chain did not start (above)"
sleep "${FOLLOW_S:-30}"
R "$SV status" 2>&1 | sed 's/^/   /'
echo
echo "Started: C0f, 30 runs (27 jobs at L = 100, LRU controls at L = 0; amendment 1: the other L = 0 rows are H7's) on the F-C binary, 8 at a time (8 cores first)."
echo "Where it is:  $0 status      Results:  $0 pull"
echo "log: $LOG"
