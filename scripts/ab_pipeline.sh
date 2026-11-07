#!/usr/bin/env bash
# The COALESCE A/B, server side, as ONE detached pipeline that stops at the
# first failure. Run after `scripts/deploy_to_server.sh --go`.
#
#   scripts/ab_build.sh bundle 4b00ecf ab_armA        # laptop
#   scp -P 2222 -r scripts/ab_pipeline.sh scripts/server_build.sh scripts/ab_build.sh \
#       scripts/run_a4.sh scripts/run_a4.sh.py scripts/server_status.sh ab_armA user@your-server:~/
#   ssh -n -p 2222 user@your-server 'bash ~/ab_pipeline.sh go'       # returns at once
#   ssh -n -p 2222 user@your-server 'bash ~/ab_pipeline.sh status'
#
# Steps, each gated on the previous one's exit status:
#   1  server_build.sh   rebuild bin/champsim from the deployed tree (= arm B,
#                        HEAD) and run the three policy guards
#   2  the two COALESCE probes against the objects just built; each carries a
#                        negative control and exits non-zero on any failure
#   3  ab_build.sh       build arm A (4b00ecf) beside it; both binaries frozen
#                        as bin/champsim_armA / _armB
#   4  run_a4.sh go      both arms' 36 COALESCE-family A4 jobs, detached
#   5  install-resume    both arms restart after a reboot
#
# WHY DETACHED. The chain takes ~25 min. Run inside an ssh session, a dropped
# connection would kill it mid-step -- worst inside ab_build.sh, which swaps
# arm A's sources into the deployed tree and restores them afterwards; killed
# between the two, the tree is left holding arm A's sources.
set -uo pipefail

R="$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy"
S="$R/simulator"
LOG="${LOG:-$HOME/ab_pipeline.log}"
PIDF="$HOME/.ab_pipeline.pid"
BUNDLE="${BUNDLE:-$HOME/ab_armA}"
MAXJOBS="${MAXJOBS:-12}"

die() { echo "ERROR: $*" >&2; exit 1; }
step() { echo; echo "=== $(date '+%F %T') $* ==="; }
alive() { [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null; }

probe() {   # $1 name, $2.. objects
  local name="$1"; shift
  g++ @global.options @absolute.options "../bench/policy_sanity/$name.cc" "$@" \
      -L vcpkg_installed/x64-linux/lib -lfmt -o "$HOME/$name" || { echo "   could not build $name"; return 1; }
  "$HOME/$name" | tail -3
}

pipeline() {
  step "1/5  build HEAD (arm B) and run the guards"
  bash "$HOME/server_build.sh" || return 1

  step "2/5  COALESCE probes against the objects just built"
  cd "$S" || return 1
  probe coalesce_ghost_probe .csconfig/replacement/coalesce/coalesce.o || return 1
  probe coalesce_ablation_probe .csconfig/replacement/coalesce/coalesce.o \
        .csconfig/replacement/coalesce_no_mesi/coalesce_no_mesi.o \
        .csconfig/replacement/coalesce_no_sharer/coalesce_no_sharer.o || return 1

  step "3/5  arm A beside it"
  bash "$HOME/ab_build.sh" build "$BUNDLE" || return 1

  step "4/5  launch both A4 arms (MAXJOBS=$MAXJOBS each)"
  ARM=A MAXJOBS="$MAXJOBS" bash "$HOME/run_a4.sh" go || return 1
  ARM=B MAXJOBS="$MAXJOBS" bash "$HOME/run_a4.sh" go || return 1

  step "5/5  both arms survive a reboot"
  ARM=A MAXJOBS="$MAXJOBS" bash "$HOME/run_a4.sh" install-resume || return 1
  ARM=B MAXJOBS="$MAXJOBS" bash "$HOME/run_a4.sh" install-resume || return 1
}

phase_go() {
  alive && die "the pipeline is already running (pid $(cat "$PIDF")) -- 'status'"
  [ -d "$BUNDLE" ] && [ -f "$BUNDLE/MANIFEST" ] || die "no arm A bundle at $BUNDLE"
  local f; for f in server_build.sh ab_build.sh run_a4.sh run_a4.sh.py; do
    [ -f "$HOME/$f" ] || die "missing ~/$f -- upload it with this script"
  done
  : > "$LOG"
  setsid bash "$0" __run < /dev/null >> "$LOG" 2>&1 &
  disown 2>/dev/null
  sleep 3
  echo "launched; log -> $LOG"
  tail -4 "$LOG"
  echo
  echo "check with:  bash $0 status"
}

phase_status() {
  alive && echo "== pipeline RUNNING (pid $(cat "$PIDF")) ==" || echo "== pipeline not running =="
  grep -E '^=== |PASS:|FAIL|ERROR|FAILED|All green|arms differ|launched' "$LOG" 2>/dev/null | tail -25
  echo
  echo "== last 5 log lines =="; tail -5 "$LOG" 2>/dev/null
}

case "${1:-}" in
  go)     phase_go ;;
  status) phase_status ;;
  __run)
    echo $$ > "$PIDF"
    if pipeline; then step "PIPELINE DONE -- both A4 arms running"
    else step "PIPELINE STOPPED at the step above -- nothing after it ran"; fi
    rm -f "$PIDF" ;;
  *) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
