#!/usr/bin/env bash
# Step 4, the new benchmarks (bench/policy_sanity/newbench_design_2026-10-19.md
# once written). One command, one password.
#
#   scripts/newbench_all.sh survey   # READ-ONLY: what the server has (programs, inputs, PARSEC, tools),
#                                    # and the new alignment against the old anchors
#   scripts/newbench_all.sh size     # build the six (dynamic + static, QB) and size their inputs with
#                                    # Pin's per-thread counter; detached, hours; writes only ~/newbench*
#   scripts/newbench_all.sh status   # where sizing, tracing, the ChampSim runs and the gem5 runs are
#   scripts/newbench_all.sh go       # once all six are sized: trace them with sync records and run
#                                    # ChampSim on the final tool (sync_server.sh VARIANT=nb), and
#                                    # start their gem5 runs (launch_b3_gem5.sh); detached
#   scripts/newbench_all.sh lunc     # rule (c): size LU non-contiguous, then start its two gem5 runs;
#                                    # detached; its tracing is separate
#   scripts/newbench_all.sh retrace  # amendment 2 (2026-10-28): set the trace length per program, stop the
#                                    # nb chain (radiosity's first trace), start chain 1 (the other five)
#                                    # and chain 2 (radiosity alone, ~/sync_nb_r); gem5 runs untouched
#   scripts/newbench_all.sh lunctrace  # LU non-contiguous with the host's CPUID (stream_fix_design
#                                    # amendment 1: F2 does not hold, stream_fix_results_2026-11-04.md),
#                                    # by amendment 2's length rule, then its run; detached (~/sync_nb)
set -uo pipefail
PORT=2222
SRV="user@your-server"
SRV_HOME="${SRV_HOME:-/home/harshraj}"
LROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
MODE="${1:-}"
case "$MODE" in survey|size|status|go|retrace|lunc|lunctrace) ;; *) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;; esac
UPLOAD="newbench_survey.sh sync_anchor.py newbench_server.sh sync_server.sh sync_cut.py trace_mix.c run_gem5_splash.sh launch_b3_gem5.sh"
NB_PROGS="fft lu raytrace streamcluster volrend radiosity"   # after the 2026-10-20 amendment (lunc if one fails the size rule)
if [ "$MODE" = size ] || [ "$MODE" = go ] || [ "$MODE" = retrace ] || [ "$MODE" = lunc ] || [ "$MODE" = lunctrace ]; then
  git -C "$LROOT" ls-files --error-unmatch bench/policy_sanity/newbench_design_2026-10-19.md > /dev/null 2>&1 || { echo "the pre-registration is not committed"; exit 1; }
  for f in $UPLOAD; do
    [ -z "$(git -C "$LROOT" status --porcelain -- "scripts/$f")" ] || { echo "scripts/$f has uncommitted changes -- commit first"; exit 1; }
  done
fi
if [ "$MODE" = retrace ]; then
  # read the log whole first: piped into grep -q, git dies of SIGPIPE when grep stops early and pipefail fails the check
  subjects=$(git -C "$LROOT" log --format=%s -- bench/policy_sanity/newbench_design_2026-10-19.md)
  grep -q '^prereg(newbench): amendment 2' <<< "$subjects" \
    || { echo "amendment 2 (the trace length) is not committed"; exit 1; }
fi
# radiosity runs in a chain of its own from amendment 2 (2026-10-28)
RAD_ENV="W=$SRV_HOME/sync_nb_r PROGS=\"\$(grep '^radiosity|' $SRV_HOME/newbench/PROGS)\" JOBS_SPEC=\"\$(grep '|radiosity\$' $SRV_HOME/newbench/JOBS)\" VARIANT=nb"
# LU non-contiguous alone, in the nb chain's own directory (chain 1 has ended)
LUNC_ENV="PROGS=\"\$(grep '^lunc|' $SRV_HOME/newbench/PROGS)\" JOBS_SPEC=\"\$(grep '|lunc\$' $SRV_HOME/newbench/JOBS)\" VARIANT=nb"
FIVE_ENV="PROGS=\"\$(grep -v '^radiosity|' $SRV_HOME/newbench/PROGS)\" JOBS_SPEC=\"\$(grep -v '|radiosity\$' $SRV_HOME/newbench/JOBS)\" VARIANT=nb"
CTL="$HOME/.ssh/cm-newbench-$$"
mkdir -p "$HOME/.ssh"
cleanup() { ssh -O exit -o ControlPath="$CTL" -p "$PORT" "$SRV" 2>/dev/null || true; rm -f "$CTL"; }
trap cleanup EXIT
echo "One connection -- the password is asked once."
ssh -p "$PORT" -o ControlMaster=yes -o ControlPath="$CTL" -o ControlPersist=30m -fN "$SRV" || { echo "could not connect"; exit 1; }
R() { ssh -n -p "$PORT" -o ControlPath="$CTL" "$SRV" "$@"; }
for f in $UPLOAD; do
  scp -q -P "$PORT" -o ControlPath="$CTL" "$LROOT/scripts/$f" "$SRV:$SRV_HOME/$f.new" || { echo "upload of $f failed"; exit 1; }
  R "mv -f $SRV_HOME/$f.new $SRV_HOME/$f" || exit 1
done
OUT="$LROOT/simulator/results/newbench"
mkdir -p "$OUT"
case "$MODE" in
  survey)
    R "bash $SRV_HOME/newbench_survey.sh" 2>&1 | tee "$OUT/survey.txt"
    echo; echo "Saved to simulator/results/newbench/survey.txt. Tell Claude: survey done." ;;
  size)
    R "bash $SRV_HOME/newbench_server.sh size" 2>&1
    echo; echo "Sizing runs on the server by itself (hours). Where it is: scripts/newbench_all.sh status" ;;
  go)
    n=$(R "n=0; for p in $NB_PROGS; do [ -f $SRV_HOME/newbench/\$p/SIZED ] && n=\$((n + 1)); done; echo \$n")
    [ "$n" = 6 ] || { echo "only $n of the 6 ($NB_PROGS) are sized -- scripts/newbench_all.sh status"; exit 1; }
    echo "== ChampSim: trace the six with sync records, then the runs on the final tool"
    R "VARIANT=nb bash $SRV_HOME/sync_server.sh chain" 2>&1 | sed 's/^/   /'
    [ "${PIPESTATUS[0]}" -eq 0 ] || { echo "the ChampSim chain did not start"; exit 1; }
    for p in $NB_PROGS; do
      echo "== gem5: $p"
      R "WL=$p bash $SRV_HOME/launch_b3_gem5.sh go" 2>&1 | sed 's/^/   /'
    done
    echo; echo "Started. Where it is: scripts/newbench_all.sh status (or scripts/pull_results.sh)" ;;
  lunc)
    R "bash $SRV_HOME/newbench_server.sh sizegem5 lunc" 2>&1 | sed 's/^/   /'
    [ "${PIPESTATUS[0]}" -eq 0 ] || { echo "did not start"; exit 1; }
    echo; echo "Sizing, then gem5, run on the server by themselves. Where it is: scripts/newbench_all.sh status" ;;
  lunctrace)
    git -C "$LROOT" ls-files --error-unmatch bench/policy_sanity/stream_fix_results_2026-11-04.md > /dev/null 2>&1 \
      || { echo "the streamfix verdict (F2 does not hold) is not committed"; exit 1; }
    R "[ -f $SRV_HOME/newbench/lunc/SIZED ] && grep -q '^lunc|' $SRV_HOME/newbench/PROGS && grep -q '|lunc\$' $SRV_HOME/newbench/JOBS" \
      || { echo "lunc is not sized (scripts/newbench_all.sh lunc first)"; exit 1; }
    if R "VARIANT=nb bash $SRV_HOME/sync_server.sh status 2>/dev/null | grep -q 'chain alive'"; then
      echo "an nb chain is running -- nothing started (scripts/newbench_all.sh status)"; exit 1
    fi
    echo "== lunc: $(R "grep '^lunc|' $SRV_HOME/newbench/PROGS" | cut -d'|' -f1,3,6-9)"
    R "$LUNC_ENV bash $SRV_HOME/sync_server.sh chain" 2>&1 | sed 's/^/   /'
    [ "${PIPESTATUS[0]}" -eq 0 ] || { echo "the lunc chain did not start"; exit 1; }
    echo; echo "Started. Where it is: scripts/pull_results.sh (or scripts/newbench_all.sh status)" ;;
  retrace)
    if R "[ -f $SRV_HOME/sync_nb/RETRACE_STARTED ]"; then
      echo "retrace has run already ($(R "cat $SRV_HOME/sync_nb/RETRACE_STARTED")): nothing stopped or started."
      echo "Where it is: scripts/pull_results.sh"; exit 1
    fi
    echo "== the trace length per program (amendment 2)"
    R "bash $SRV_HOME/newbench_server.sh tracelen lu 375000000 raytrace 400000000 fft 0 volrend 0" 2>&1 | sed 's/^/   /'
    [ "${PIPESTATUS[0]}" -eq 0 ] || { echo "tracelen failed -- nothing stopped or started"; exit 1; }
    rad=$(R "grep -h 'radiosity: ' $SRV_HOME/sync_nb/driver.log 2>/dev/null | tail -1")
    echo "== radiosity's first trace, last line: ${rad:-none}"
    case "$rad" in *"pthread_create after"*)
      echo "   radiosity's trace is being cut and checked (minutes): nothing stopped. Run this again in 30 minutes."; exit 1 ;; esac
    echo "== stop the nb chain (it holds only radiosity's first trace; rule (d)'s 48 h count from chain 2's start)"
    R "VARIANT=nb bash $SRV_HOME/sync_server.sh stop" 2>&1 | sed 's/^/   /'
    echo "== chain 1: fft lu raytrace streamcluster volrend (streamcluster is traced already)"
    R "$FIVE_ENV bash $SRV_HOME/sync_server.sh chain" 2>&1 | sed 's/^/   /'
    [ "${PIPESTATUS[0]}" -eq 0 ] || { echo "chain 1 did not start"; exit 1; }
    R "date '+%F %T chain 1 started by newbench_all.sh retrace' > $SRV_HOME/sync_nb/RETRACE_STARTED"   # a second retrace would stop chain 1
    case "$rad" in
      *FAILED*) echo "== radiosity: its first trace FAILED (above). Rules (b)-(d) decide what follows: NOT restarted. Tell Claude." ;;
      *) echo "== chain 2: radiosity alone (~/sync_nb_r)"
         R "$RAD_ENV bash $SRV_HOME/sync_server.sh chain" 2>&1 | sed 's/^/   /'
         [ "${PIPESTATUS[0]}" -eq 0 ] || { echo "chain 2 did not start"; exit 1; } ;;
    esac
    echo; echo "Started. Where it is: scripts/pull_results.sh (or scripts/newbench_all.sh status)" ;;
  status)
    R "bash $SRV_HOME/newbench_server.sh status" 2>&1 | tee "$OUT/size_status.txt"
    R "[ -d $SRV_HOME/sync_nb ] && VARIANT=nb bash $SRV_HOME/sync_server.sh status" 2>&1 | tee -a "$OUT/size_status.txt"
    R "[ -d $SRV_HOME/sync_nb_r ] && $RAD_ENV bash $SRV_HOME/sync_server.sh status" 2>&1 | sed 's/^== sync nb/== sync nb, radiosity alone/' | tee -a "$OUT/size_status.txt"
    for p in $NB_PROGS lunc; do R "[ -d $SRV_HOME/gem5_b3/newbench/$p ] && WL=$p bash $SRV_HOME/launch_b3_gem5.sh status" 2>&1; done | tee -a "$OUT/size_status.txt"
    rsync -a -e "ssh -p $PORT -o ControlPath=$CTL" --include='*/' --include='size.log' --include='CHOSEN' --include='PROGS' --include='JOBS' --include='count.txt' --include='err.txt' --exclude='*' \
      "$SRV:$SRV_HOME/newbench/" "$OUT/server/" 2>/dev/null && echo "   pulled: logs and counts to simulator/results/newbench/server/" ;;
esac
