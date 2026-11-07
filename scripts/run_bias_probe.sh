#!/usr/bin/env bash
# Does COALESCE's coherence bias steer eviction onto unbiased lines?
#
#   scp -P 2222 scripts/run_bias_probe.sh user@your-server:~/
#   ssh -p 2222 user@your-server 'bash ~/run_bias_probe.sh build'
#   ssh -p 2222 user@your-server 'bash ~/run_bias_probe.sh go'
#   ssh -p 2222 user@your-server 'bash ~/run_bias_probe.sh report'
#
# THE QUESTION. COALESCE misses 7.4x SRRIP's LLC TRANSLATION rate at 4 cores
# and 14.5x at 8, while its demand-load MPKI stays within 0.4%. The proposed
# cause (bench/policy_sanity/coalesce_diagnosis_2026-09-22.md) is that the
# coherence bias is strictly non-negative and keys on MESI state and sharer
# count, so a line with neither -- a page-table entry, among others -- is the
# lowest-voted way by construction and gets evicted regardless of its merit.
#
# WHY A NEW COUNTER WAS NEEDED. The existing histogram was printed as "VICTIM
# SHARER HIST" but is incremented inside find_victim's loop over every
# candidate way, so it has always measured the resident population rather than
# what was evicted. It is now labelled CANDIDATE, and a genuine VICTIM
# histogram sits beside it. Either distribution alone is consistent with any
# outcome; the test is the gap between them.
#
# WHAT CONFIRMS THE HYPOTHESIS. victim_biased/victim_total must be materially
# BELOW cand_biased/cand_total -- evictions landing on unbiased lines out of
# proportion to how often unbiased lines are present. Equal rates refute it.
#
# SHORT ON PURPOSE. The mechanism is structural, not a function of run length,
# so this uses 10M warmup + 20M simulation (~35 min) rather than the sweep's
# 50M+100M (~3 h). If the gap is real it is visible immediately.
set -uo pipefail

R="$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy"
S="$R/simulator"
OUT="${OUT:-$S/results/bias_probe}"
WARMUP="${WARMUP:-10000000}"
SIM="${SIM:-20000000}"
CORES="${CORES:-4}"
POLICY="${POLICY:-coalesce}"

die() { echo "ERROR: $*" >&2; exit 1; }

phase_build() {
  for g in check_include_path check_fill_hook check_signatures; do
    bash "$R/bench/policy_sanity/$g.sh" >/dev/null 2>&1 || die "$g failed -- not building"
  done
  echo "   guards pass; building"
  ( cd "$S" && make -j"$(nproc)" ) 2>&1 | tail -15
  [ -x "$S/bin/champsim" ] || die "no binary after build"
  echo "   ok: $(ls -la "$S/bin/champsim" | awk '{print $5" bytes  "$6" "$7" "$8}')"
}

phase_go() {
  [ -x "$S/bin/champsim" ] || die "build first"
  pgrep -f "[b]in/champsim" >/dev/null && echo "   note: other champsim jobs are running; this one is niced"
  mkdir -p "$OUT"
  local cfg="$OUT/cfg_$POLICY.json" tr=() i
  "$S/scripts/make_config.py" --policy "$POLICY" --cores "$CORES" --regime shared -o "$cfg" \
    || die "make_config.py failed"
  for ((i = 1; i <= CORES; i++)); do
    local f="$S/traces/canneal_${CORES}t/canneal$i.champsimtrace"
    [ -f "$f" ] || f="$f.xz"
    [ -f "$f" ] || die "no trace $f"
    tr+=("$f")
  done
  echo "   $POLICY, canneal ${CORES}c shared, ${WARMUP} warmup + ${SIM} sim"
  # An ssh client hung here on 2026-09-22 after this phase had printed all its
  # output. The obvious explanation -- the backgrounded job holding the ssh
  # channel's stdout open -- was TESTED AND IS WRONG: champsim's stdin, stdout
  # and stderr were already redirected to /dev/null and run.log, so it never
  # held the pipe, and a launcher whose stdout is a pipe read to EOF returns
  # immediately both before and after this change. The cause is not established.
  #
  # What is kept here is defensive and independently useful: the subshell's own
  # descriptors are closed too, and the pid is written to a file instead of
  # being echoed from inside a subshell. If a client hangs again, the reliable
  # remedy is on the client side -- `ssh -n` -- and Ctrl-C is safe regardless,
  # because setsid has already put the job in its own session with its output
  # in a file.
  ( cd "$S" && setsid nice -n 15 ./bin/champsim --config "$cfg" \
      --warmup-instructions "$WARMUP" --simulation-instructions "$SIM" "${tr[@]}" \
      < /dev/null > "$OUT/run.log" 2>&1 & echo "$!" > "$OUT/pid" ) > /dev/null 2>&1 < /dev/null
  echo "   pid $(cat "$OUT/pid" 2>/dev/null || echo '?')"
  echo "   watch: tail -f $OUT/run.log     then: bash $0 report"
}

phase_report() {
  local log="$OUT/run.log"
  [ -s "$log" ] || die "no $log -- run 'go' first"
  if ! grep -q "ChampSim completed all CPUs" "$log"; then
    echo "   still running (or failed). last line:"; tail -2 "$log" | sed 's/^/     /'; return 1
  fi
  echo "== COALESCE bias exposure =="
  grep "BIAS EXPOSURE" "$log" | sed 's/^/   /'
  echo
  awk '
    /BIAS EXPOSURE/ {
      for (i = 1; i <= NF; i++) {
        if ($i == "cand_modified")  cm = $(i+1)
        if ($i == "victim_modified") vm = $(i+1)
        if ($i == "cand_biased")    cb = $(i+1)
        if ($i == "victim_biased")  vb = $(i+1)
      }
    }
    /CANDIDATE SHARER HIST TOTAL/ { ct = $NF }
    /VICTIM SHARER HIST TOTAL/    { vt = $NF }
    END {
      if (ct == 0 || vt == 0) { print "   no histogram data"; exit }
      cbr = 100 * cb / ct; vbr = 100 * vb / vt
      cmr = 100 * cm / ct; vmr = 100 * vm / vt
      printf "   %-34s %14s %14s\n", "", "candidates", "victims"
      printf "   %-34s %14d %14d\n", "lines examined / evicted", ct, vt
      printf "   %-34s %13.2f%% %13.2f%%\n", "carrying ANY coherence bias", cbr, vbr
      printf "   %-34s %13.2f%% %13.2f%%\n", "MODIFIED", cmr, vmr
      printf "\n"
      if (cbr > 0) {
        printf "   A biased line is %.2fx as likely to be evicted as its share of\n", vbr / cbr
        printf "   the population would predict.\n\n"
        if (vbr < cbr * 0.9)
          print "   CONFIRMED: evictions land on unbiased lines out of proportion."
        else if (vbr > cbr * 1.1)
          print "   OPPOSITE: biased lines are evicted MORE often. Hypothesis refuted."
        else
          print "   NO EFFECT: victims match the population. Hypothesis refuted."
      }
    }' "$log"
  echo
  echo "== sharer distribution, candidates vs victims =="
  # Read both histograms in one pass and join on the bucket index.
  #
  # This used to `paste` two greps and pick awk fields by position. The
  # percentage column varies in width, so the fields shifted and the victim
  # numbers printed under the wrong headings -- on 2026-09-23 it rendered
  # "victim 2 1585" for bucket 2, which is two different values run together.
  # A table that misreports the quantity it exists to show is worse than none.
  awk '
    /CANDIDATE SHARER HIST\[/ { k=$0; sub(/.*HIST\[/,"",k); sub(/\].*/,"",k); gsub(/ /,"",k)
                               v=$0; sub(/.*\]:[ ]*/,"",v); split(v,a," "); cand[k]=a[1]; ctot+=a[1] }
    /VICTIM SHARER HIST\[/    { k=$0; sub(/.*HIST\[/,"",k); sub(/\].*/,"",k); gsub(/ /,"",k)
                               v=$0; sub(/.*\]:[ ]*/,"",v); split(v,a," "); vict[k]=a[1]; vtot+=a[1] }
    END {
      if (ctot == 0) { print "   (no histogram data)"; exit }
      printf "   %-9s %16s %9s %16s %9s %10s\n", "sharers", "candidates", "%", "victims", "%", "vict/cand"
      for (k = 0; k <= 16; k++) {
        if (cand[k] == "" && vict[k] == "") continue
        c = cand[k] + 0; v = vict[k] + 0
        cp = 100 * c / ctot; vp = (vtot ? 100 * v / vtot : 0)
        if (cp > 0) printf "   %-9s %16d %8.3f%% %16d %8.3f%% %9.3fx\n", k, c, cp, v, vp, vp / cp
        else        printf "   %-9s %16d %8.3f%% %16d %8.3f%% %10s\n", k, c, cp, v, vp, "-"
      }
      printf "   %-9s %16d %9s %16d\n", "total", ctot, "", vtot
    }' "$log"
  echo
  echo "== LLC translation, for context =="
  grep -E "^cpu[0-9]+->LLC TRANSLATION" "$log" | sed 's/^/   /'
}

case "${1:-}" in
  build)  phase_build ;;
  go)     phase_go ;;
  report) phase_report ;;
  *) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
