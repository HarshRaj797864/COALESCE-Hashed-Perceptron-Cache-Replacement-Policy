#!/usr/bin/env bash
# Build two binaries that differ ONLY in the COALESCE family, for an A/B test.
#
#   # on the laptop: bundle arm A's policy sources from a commit
#   scripts/ab_build.sh bundle 4b00ecf ab_armA
#   scp -P 2222 -r ab_armA scripts/ab_build.sh user@your-server:~/
#   # on the server, AFTER the running sweep has finished
#   ssh -n -p 2222 user@your-server 'bash ~/ab_build.sh build ~/ab_armA'
#
# WHY. On 429.mcf the ghost-tag fix alone gave +5.2% IPC, and adding the two
# consistency fixes -- hit training on the allocating PC (5beb7a8) and the
# rescue keyed on the address (8de8c42) -- returned COALESCE to its exact
# pre-fix IPC. One single-core trace cannot say which version is better; A4's
# ten discriminating traces can. See bench/policy_sanity/coalesce_preaudit_2026-09-23.md.
#
#   arm A = 4b00ecf: ghost fix + clean ablations
#   arm B = the deployed tree: arm A + the two consistency fixes
#
# Arm A is NOT the older 97aa5da: 4b00ecf also carries the ablation-hash fix,
# which is independent and belongs in both arms. For the full `coalesce` policy
# the two commits are identical. So the arms differ by exactly the two fixes.
#
# Both binaries are built from the SAME tree with only the six COALESCE-family
# files swapped, so every other policy, the simulator core and any counters are
# byte-for-byte shared. The server tree is rsync-deployed, not a git checkout,
# which is why arm A's sources travel as a bundle rather than a commit.
#
# REFUSES while a queue driver can still launch jobs: this rebuilds
# bin/champsim, and a job launched mid-rebuild would mix binaries.
set -uo pipefail

FILES="coalesce/coalesce.cc coalesce/coalesce.h
coalesce_no_mesi/coalesce_no_mesi.cc coalesce_no_mesi/coalesce_no_mesi.h
coalesce_no_sharer/coalesce_no_sharer.cc coalesce_no_sharer/coalesce_no_sharer.h"

die() { echo "ERROR: $*" >&2; exit 1; }

# Refuse to rebuild bin/champsim only while a queue driver can still LAUNCH from
# it. A driver reads its queue inside `while read ...; done < queue.txt`, so it
# holds the file open until it has attempted every line -- then it can no longer
# start anything. Running jobs are safe: the linker writes a new file and a
# running process keeps the binary it started with (tested 2026-09-24: the job
# completed, its exe shown as "(deleted)"). Refusing on any running champsim, as
# this used to, blocked every rebuild for the whole tail of a sweep.
launching_drivers() {
  local lk pid q fd
  for lk in "$HOME"/.phase_a*/driver.pid "$HOME"/.a4*/driver.pid; do
    [ -f "$lk" ] || continue
    pid=$(cat "$lk" 2>/dev/null)
    { [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; } || continue
    q=$(readlink -f "$(dirname "$lk")/queue.txt")
    for fd in /proc/"$pid"/fd/*; do
      [ "$(readlink "$fd" 2>/dev/null)" = "$q" ] && { printf ' %s (pid %s)' "$(dirname "$lk")" "$pid"; break; }
    done
  done
}

bundle() {   # LAPTOP: $1 commit, $2 output dir
  local rev="$1" out="$2" f
  [ -n "$rev" ] && [ -n "$out" ] || die "usage: bundle <commit> <outdir>"
  git rev-parse --verify -q "$rev^{commit}" >/dev/null || die "no such commit $rev"
  rm -rf "$out"; mkdir -p "$out"
  for f in $FILES; do
    mkdir -p "$out/$(dirname "$f")"
    git show "$rev:simulator/replacement/$f" > "$out/$f" || die "cannot read $f at $rev"
  done
  { echo "commit $(git rev-parse --short "$rev")"; echo "subject $(git log -1 --format=%s "$rev")"; } > "$out/MANIFEST"
  echo "bundled $(echo "$FILES" | wc -w) files from $(git rev-parse --short "$rev") into $out"
}

build() {    # SERVER: $1 bundle dir
  local b="$1" R="${R:-$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy}"
  local S="$R/simulator" RP="$R/simulator/replacement" bak f okA log="$HOME/.ab_build.log"
  # make's OWN exit status decides, and the full output is kept. This used to be
  # `make | grep error`, whose status under `set -o pipefail` is make's when make
  # fails: a failed build returned 2 and was read as success. Found on re-reading
  # before first use; the cmp check at the end would have caught it downstream,
  # but as "the arms are IDENTICAL" rather than as the build error it was.
  mk() { ( cd "$S" && make -j"$(nproc)" ) > "$1" 2>&1; }
  [ -d "$b" ] && [ -f "$b/MANIFEST" ] || die "no bundle at $b"
  local busy; busy=$(launching_drivers)
  [ -z "$busy" ] || die "a queue driver can still launch jobs from bin/champsim -- rebuilding now would mix binaries:$busy"
  for g in check_include_path check_fill_hook check_signatures; do
    bash "$R/bench/policy_sanity/$g.sh" >/dev/null 2>&1 || die "$g failed on the deployed tree"
  done
  # A failed rebuild must not leave a previous run's arm binary behind for
  # run_a4.sh to pick up: its only check is that $BIN exists.
  rm -f "$S/bin/champsim_armA" "$S/bin/champsim_armB"
  bak=$(mktemp -d "$HOME/.ab_armB.XXXX")
  for f in $FILES; do mkdir -p "$bak/$(dirname "$f")"; cp -p "$RP/$f" "$bak/$f"; done

  echo "== arm B: the deployed tree =="
  mk "$log.armB" || { rm -rf "$bak"; die "arm B build failed -- see $log.armB"; }
  cp -p "$S/bin/champsim" "$S/bin/champsim_armB"

  echo "== arm A: $(sed -n 's/^commit //p' "$b/MANIFEST") -- $(sed -n 's/^subject //p' "$b/MANIFEST")"
  # touch: make decides by mtime, so a swapped-in source must be newer than the
  # objects already built from the other arm.
  for f in $FILES; do cp "$b/$f" "$RP/$f"; touch "$RP/$f"; done
  okA=0; mk "$log.armA" && okA=1
  [ "$okA" -eq 1 ] && cp -p "$S/bin/champsim" "$S/bin/champsim_armA"

  echo "== restoring the deployed sources and rebuilding bin/champsim as arm B =="
  # NOT cp -p. Preserving the original mtimes made the restored sources OLDER
  # than the arm-A objects just built, so make skipped the rebuild and left
  # bin/champsim as arm A -- caught by the check below in the first local test.
  for f in $FILES; do cp "$bak/$f" "$RP/$f"; touch "$RP/$f"; done
  mk "$log.restore" || echo "   !! restore build failed -- see $log.restore (the check below will say so)"
  rm -rf "$bak"
  [ "$okA" -eq 1 ] || die "arm A build failed -- see $log.armA; sources restored"

  echo
  echo "   arm A  $(stat -c %s "$S/bin/champsim_armA") bytes"
  echo "   arm B  $(stat -c %s "$S/bin/champsim_armB") bytes"
  cmp -s "$S/bin/champsim_armA" "$S/bin/champsim_armB" && die "the arms are IDENTICAL -- the swap did not take"
  cmp -s "$S/bin/champsim" "$S/bin/champsim_armB" || die "bin/champsim is not arm B after the restore"
  echo "   arms differ; bin/champsim == arm B; sources restored"
}

case "${1:-}" in
  bundle) shift; bundle "$@" ;;
  build)  shift; build "$@" ;;
  *) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
