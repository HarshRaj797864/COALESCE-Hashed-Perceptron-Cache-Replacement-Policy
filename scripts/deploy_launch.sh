#!/usr/bin/env bash
# Deploy, build, and launch queues on the server: one command, one password.
# Generalised from ocean4_all.sh (ee29d25, tested end to end); a thin wrapper
# names the launcher. E.g. scripts/b3v2_all.sh.
#
#   LAUNCHER=<server script with plan|go>  EXPECT="<to-run counts>"  COUNTER="<string>" \
#     [LAUNCHER_ENV="SET=v3"] [FREEZE_AS=<name>] [EXTRA_UPLOADS="<repo paths>"] scripts/deploy_launch.sh
#
# LAUNCHER_ENV is put in front of the launcher's plan and go. FREEZE_AS keeps
# the server's current bin/champsim as bin/<name> before step 4 rebuilds it,
# so the results it made stay reproducible; an existing bin/<name> is left
# alone. EXTRA_UPLOADS names more files, relative to the repo root, to put in
# the server's home in step 3 (each to <name>.new, then mv: one may be a
# script that a live process is reading).
#
# Steps, each checked, stopping at the first failure:
#   1. deploy preview      refuses any deletion; refuses any CONTENT difference
#                          under simulator/replacement/ (COALESCE is frozen)
#   2. deploy              scripts/deploy_to_server.sh --go (backs up first), then
#                          the deployed plain_printer.cc must contain COUNTER
#   3. upload runners      run_phase_a.sh, server_build.sh, b3_rows.sh, LAUNCHER;
#                          refuses if any queue driver is alive (a plain copy
#                          onto a live runner corrupts it, CLAUDE.md)
#   4. build               server_build.sh; must end "All green."
#   5. preview the queues  LAUNCHER plan; to-run counts must equal EXPECT, and
#                          nothing unrunnable
#   6. launch              LAUNCHER go
#
# Everything is also written to simulator/results/<launcher>_<time>.log
# (gitignored).
set -uo pipefail

PORT=2222
SRV="user@your-server"
LROOT="$(cd "$(dirname "$0")/.." && pwd)"
LAUNCHER="${LAUNCHER:?set LAUNCHER, e.g. launch_b3_v2.sh}"
EXPECT="${EXPECT:?set EXPECT, the to-run counts the plan must show}"
COUNTER="${COUNTER:?set COUNTER, a string the deployed plain_printer.cc must contain}"
LAUNCHER_ENV="${LAUNCHER_ENV:-}"
FREEZE_AS="${FREEZE_AS:-}"
EXTRA_UPLOADS="${EXTRA_UPLOADS:-}"
case "$LAUNCHER_ENV$FREEZE_AS" in *[!A-Za-z0-9_=\ .-]*) echo "LAUNCHER_ENV / FREEZE_AS: plain words only"; exit 1 ;; esac
case "$EXTRA_UPLOADS" in *[!A-Za-z0-9_/\ .-]*) echo "EXTRA_UPLOADS: plain paths only"; exit 1 ;; esac
[ -f "$LROOT/scripts/$LAUNCHER" ] || { echo "no scripts/$LAUNCHER"; exit 1; }
for f in $EXTRA_UPLOADS; do [ -f "$LROOT/$f" ] || { echo "EXTRA_UPLOADS: no $f"; exit 1; }; done
LOG="$LROOT/simulator/results/${LAUNCHER%.sh}_$(date +%Y%m%d_%H%M%S).log"
mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1

die() { echo; echo "STOPPED at step $STEP: $*"; echo "log: $LOG"; exit 1; }
step() { STEP="$1"; echo; echo "================ $1/6  $2 ================"; }
STEP=0

CTL="$HOME/.ssh/cm-deploy-$$"
mkdir -p "$HOME/.ssh"
cleanup() { ssh -O exit -o ControlPath="$CTL" -p "$PORT" "$SRV" 2>/dev/null || true; rm -f "$CTL"; }
trap cleanup EXIT
echo "One connection for every step -- the password is asked once."
# ServerAlive keeps the master up through the build's quiet minutes.
ssh -p "$PORT" -o ControlMaster=yes -o ControlPath="$CTL" -o ControlPersist=60m \
    -o ServerAliveInterval=30 -fN "$SRV" || { echo "could not connect"; exit 1; }
R() { ssh -n -p "$PORT" -o ControlPath="$CTL" "$SRV" "$@"; }

# Itemized rsync changes (sent, created, deleted) inside one "== <dir>" section
# of the deploy output. Directory-timestamp lines (".d..t") are not changes.
changes_in() {   # $1 file  $2 section dir
  awk -v d="$2" '/^== / { inside = ($2 == d) ; next }
    inside && /^(\*deleting|[<>ch][fdLDS])/ { print }' "$1"
}

step 1 "deploy preview (copies nothing)"
PREVIEW="$(mktemp)"
COALESCE_CTL="$CTL" bash "$LROOT/scripts/deploy_to_server.sh" > "$PREVIEW" 2>&1 \
  || { cat "$PREVIEW"; die "the deploy preview failed"; }
DEL=$(grep '^\*deleting' "$PREVIEW")
[ -z "$DEL" ] || { echo "$DEL"; die "the deploy would DELETE the files above on the server -- none were expected; check what they are first"; }
# A flagged file under replacement/ may differ only in mtime: ab_build.sh
# restored the COALESCE sources on the server with cp + touch (2026-09-24), so
# their timestamps no longer match the laptop's. rsync's quick check flags that
# (">f..t"). Compare content before refusing: COALESCE is frozen, and any real
# difference there is a stop.
REPL=$(changes_in "$PREVIEW" simulator/replacement | awk '{print $2}')
if [ -n "$REPL" ]; then
  for f in $REPL; do
    l=$(md5sum < "$LROOT/simulator/replacement/$f" | cut -c1-32)
    r=$(R "md5sum < ~/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy/simulator/replacement/$f" | cut -c1-32)
    [ "$l" = "$r" ] || die "simulator/replacement/$f differs in CONTENT between laptop and server -- COALESCE is frozen"
  done
  echo "   simulator/replacement: $(echo "$REPL" | wc -w) file(s) flagged, all identical in content (timestamp only)"
fi
for d in simulator/inc simulator/src simulator/replacement simulator/scripts simulator/config bench; do
  printf '   %-24s %s change(s)\n' "$d" "$(changes_in "$PREVIEW" "$d" | grep -c .)"
done
echo "   simulator/src and inc:"; changes_in "$PREVIEW" simulator/src | sed 's/^/     /'; changes_in "$PREVIEW" simulator/inc | sed 's/^/     /'
rm -f "$PREVIEW"

step 2 "deploy"
COALESCE_CTL="$CTL" bash "$LROOT/scripts/deploy_to_server.sh" --go > /dev/null 2>&1 \
  || die "the deploy failed -- the server keeps a backup tarball in ~/pre_deploy_backup_*"
n=$(R "grep -c '$COUNTER' ~/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy/simulator/src/plain_printer.cc")
[ "${n:-0}" -ge 1 ] 2>/dev/null || die "the deployed plain_printer.cc does not contain '$COUNTER'"
echo "   deployed; the server's source carries the counter"

step 3 "upload runner scripts"
LIVE=$(R 'for p in ~/.phase_a*/driver.pid ~/.a4*/driver.pid; do [ -f "$p" ] && kill -0 "$(cat "$p")" 2>/dev/null && echo "$p"; done')
[ -z "$LIVE" ] || die "queue driver(s) alive: $LIVE -- a plain copy onto a live runner corrupts it"
scp -q -P "$PORT" -o ControlPath="$CTL" "$LROOT/scripts/run_phase_a.sh" "$LROOT/scripts/$LAUNCHER" \
    "$LROOT/scripts/server_build.sh" "$LROOT/scripts/b3_rows.sh" "$SRV:~/" || die "upload failed"
echo "   uploaded run_phase_a.sh, $LAUNCHER, server_build.sh, b3_rows.sh"
for f in $EXTRA_UPLOADS; do
  b=$(basename "$f")
  scp -q -P "$PORT" -o ControlPath="$CTL" "$LROOT/$f" "$SRV:~/$b.new" && R "mv -f ~/$b.new ~/$b" || die "upload of $f failed"
  echo "   uploaded $b"
done

step 4 "build bin/champsim (several minutes)"
if [ -n "$FREEZE_AS" ]; then
  r=$(R "cd ~/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy/simulator/bin && if [ -e '$FREEZE_AS' ]; then echo exists; else cp -p champsim '$FREEZE_AS' && cmp -s champsim '$FREEZE_AS' && echo frozen; fi")
  case "$r" in
    frozen) echo "   kept the previous binary as bin/$FREEZE_AS" ;;
    exists) echo "   bin/$FREEZE_AS already exists -- left alone" ;;
    *) die "could not keep the previous binary as bin/$FREEZE_AS ($r)" ;;
  esac
fi
BUILD=$(R 'bash ~/server_build.sh 2>&1'); brc=$?
echo "$BUILD" | tail -12 | sed 's/^/   /'
[ "$brc" -eq 0 ] && echo "$BUILD" | grep -q '^All green' || die "the build or a guard failed (output above; ~/.server_build_make.log on the server)"

step 5 "preview the queues"
PLAN=$(R "$LAUNCHER_ENV bash ~/$LAUNCHER plan 2>&1"); prc=$?
echo "$PLAN" | sed 's/^/ /'
[ "$prc" -eq 0 ] || die "the queue preview failed"
GOT=$(echo "$PLAN" | awk '/to run:/ {printf "%s ", $NF}' | sed 's/ $//')
[ "$GOT" = "$EXPECT" ] || die "to-run counts are '$GOT', expected '$EXPECT'"
echo "$PLAN" | grep -q 'unrunnable:[[:space:]]*[1-9]' && die "some jobs are unrunnable"
echo "   counts as expected, nothing unrunnable"

step 6 "launch"
R "$LAUNCHER_ENV bash ~/$LAUNCHER go 2>&1" | sed 's/^/ /'
[ "${PIPESTATUS[0]}" -eq 0 ] || die "the launch failed -- queues listed before the error ARE running; check status"

echo
echo "All six steps done: $LAUNCHER launched."
echo "log: $LOG"
