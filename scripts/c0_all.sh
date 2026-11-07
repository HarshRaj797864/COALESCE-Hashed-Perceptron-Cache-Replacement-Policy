#!/usr/bin/env bash
# C0, the cost of an invalidation: upload the sources to their own tree on the
# server, build there, check, and start the 72-run latency sweep. One command,
# one password. Pre-registered in bench/policy_sanity/c0_latency_design_2026-10-14.md.
#
#   scripts/c0_all.sh                # from the repo root, on the LAPTOP
#   JOBS=6 scripts/c0_all.sh         # fewer runs at a time (default 8)
#
# Steps, each checked, stopping at the first failure:
#   1. local    the design and every uploaded file committed; scripts parse
#   2. upload   the source directories the normal deploy sends (simulator/inc,
#               src, branch, btb, prefetcher, replacement, config, test,
#               scripts; Makefile, *.options, vcpkg.json; the guards) into
#               ~/c0_build -- NOT the main tree, whose bin/champsim and
#               runners stay as they are -- and c0_server.sh (.new + mv)
#   3. build    c0_server.sh build: compile, the three guards, frozen copy
#               bin/champsim_c0_<md5>, Q0 (latency 0 prints what
#               champsim_b3v4_69ebdcce prints). Nothing runs if any fails
#   4. start    c0_server.sh go, and its @reboot resume
set -uo pipefail

PORT=2222
SRV="user@your-server"
LROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRV_HOME="${SRV_HOME:-/home/harshraj}"
CB="$SRV_HOME/c0_build"
JOBS="${JOBS:-8}"
PREREG="bench/policy_sanity/c0_latency_design_2026-10-14.md"
SRC_DIRS="simulator/inc simulator/src simulator/branch simulator/btb simulator/prefetcher simulator/replacement simulator/config simulator/test simulator/scripts"
FILES="simulator/Makefile simulator/global.options simulator/module.options simulator/vcpkg.json"
LOG="$LROOT/simulator/results/c0_all_$(date +%Y%m%d_%H%M%S).log"
mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1

die() { echo; echo "STOPPED at step $STEP: $*"; echo "log: $LOG"; exit 1; }
step() { STEP="$1"; echo; echo "================ $1/4  $2 ================"; }
STEP=0

step 1 "local checks"
bash -n "$LROOT/scripts/c0_server.sh" || die "c0_server.sh does not parse"
git -C "$LROOT" ls-files --error-unmatch "$PREREG" > /dev/null 2>&1 || die "the pre-registration is not committed"
dirty=$(git -C "$LROOT" status --porcelain -- $SRC_DIRS $FILES "$PREREG" scripts/c0_server.sh bench/policy_sanity/check_include_path.sh bench/policy_sanity/check_fill_hook.sh bench/policy_sanity/check_signatures.sh)
[ -z "$dirty" ] || { echo "$dirty"; die "uncommitted changes in what is uploaded -- commit first"; }
echo "   committed: $(git -C "$LROOT" log -1 --format='%h %s' | cut -c1-90)"

CTL="$HOME/.ssh/cm-c0-$$"
mkdir -p "$HOME/.ssh"
cleanup() { ssh -O exit -o ControlPath="$CTL" -p "$PORT" "$SRV" 2>/dev/null || true; rm -f "$CTL"; }
trap cleanup EXIT
echo; echo "One connection for every step -- the password is asked once."
ssh -p "$PORT" -o ControlMaster=yes -o ControlPath="$CTL" -o ControlPersist=60m \
    -o ServerAliveInterval=30 -fN "$SRV" || { echo "could not connect"; exit 1; }
R() { ssh -n -p "$PORT" -o ControlPath="$CTL" "$SRV" "$@"; }
RS=(rsync -a --copy-links -e "ssh -p $PORT -o ControlPath=$CTL")

step 2 "upload the sources to $CB (the main tree is not touched)"
if R "[ -f $SRV_HOME/c0/.driver.pid ] && kill -0 \$(cat $SRV_HOME/c0/.driver.pid 2>/dev/null) 2>/dev/null"; then die "the C0 sweep is already running -- bash ~/c0_server.sh status"; fi
R "mkdir -p $CB/simulator $CB/bench/policy_sanity" || die "cannot create $CB"
for d in $SRC_DIRS; do
  "${RS[@]}" --delete "$LROOT/$d/" "$SRV:$CB/$d/" || die "rsync of $d failed"
done
for f in $FILES; do "${RS[@]}" "$LROOT/$f" "$SRV:$CB/$f" || die "rsync of $f failed"; done
for g in check_include_path check_fill_hook check_signatures; do
  "${RS[@]}" "$LROOT/bench/policy_sanity/$g.sh" "$SRV:$CB/bench/policy_sanity/$g.sh" || die "rsync of $g.sh failed"
done
R "rm -f $CB/simulator/absolute.options $CB/simulator/_configuration.mk; rm -rf $CB/simulator/.csconfig"
l=$(cd "$LROOT/simulator/src" && cat cache.cc sharer_directory.cc | md5sum | cut -c1-32)
r=$(R "cd $CB/simulator/src && cat cache.cc sharer_directory.cc | md5sum | cut -c1-32")
[ "$l" = "$r" ] || die "the uploaded sources do not match the laptop's"
scp -q -P "$PORT" -o ControlPath="$CTL" "$LROOT/scripts/c0_server.sh" "$SRV:$SRV_HOME/c0_server.sh.new" || die "upload of c0_server.sh failed"
r=$(R "mv -f ~/c0_server.sh.new ~/c0_server.sh && md5sum < ~/c0_server.sh | cut -c1-32")
[ "$r" = "$(md5sum < "$LROOT/scripts/c0_server.sh" | cut -c1-32)" ] || die "~/c0_server.sh does not match"
echo "   sources, guards and c0_server.sh uploaded; sources match"

step 3 "build, guards, Q0 (several minutes)"
R "bash ~/c0_server.sh build 2>&1" | sed 's/^/   /'
[ "${PIPESTATUS[0]}" -eq 0 ] || die "the build or Q0 failed (above) -- nothing was launched"

step 4 "start the sweep ($JOBS at a time)"
R "JOBS=$JOBS bash ~/c0_server.sh go 2>&1" | sed 's/^/   /'
[ "${PIPESTATUS[0]}" -eq 0 ] || die "the sweep did not start"
R "JOBS=$JOBS bash ~/c0_server.sh install-resume 2>&1" | sed 's/^/   /'

echo
echo "Started: 72 runs (about 290 CPU-hours), 8-core first; resumes by itself after a reboot."
echo "Where it is:  scripts/pull_results.sh"
echo "log: $LOG"
