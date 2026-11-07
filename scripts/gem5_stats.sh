#!/usr/bin/env bash
# Phase B2 -- turn gem5 Ruby stats into the same rates ChampSim reports.
#
#   scp -P 2222 scripts/gem5_stats.sh user@your-server:~/
#   ssh -n -p 2222 user@your-server 'bash ~/gem5_stats.sh discover'
#   ssh -n -p 2222 user@your-server 'bash ~/gem5_stats.sh extract'
#   ssh -n -p 2222 user@your-server 'PRESET=mesi_three_level bash ~/gem5_stats.sh extract'
#   ssh -n -p 2222 user@your-server 'PRESET=mesi_three_level OUT=$HOME/gem5_results_MESI_Three_Level_n514 bash ~/gem5_stats.sh extract'
#   # B3 spans: runs stopped at 50M and 150M, then the whole program
#   bash ~/gem5_stats.sh window ~/gem5_b3/l2_2MB_mi50M/ocean_4c ~/gem5_b3/l2_2MB_mi150M/ocean_4c ~/gem5_results_MESI_Three_Level_n514/ocean_4c
#
# DISCOVER BEFORE EXTRACTING. The names of Ruby's coherence counters are not
# documented anywhere in this repo and differ between protocols and gem5
# versions. Writing a guessed name into an extractor is how you get a metric
# that reads 0.000 and looks like a finding -- exactly what happened to
# coherence_sharer_hist, which was declared, copied into roi_stats, printed,
# and never incremented, reading as absent rather than as broken for months.
#
# So `discover` dumps what the run actually produced and `extract` REFUSES to
# report a metric whose source stat it cannot find. A missing stat is an error,
# never a zero.
#
# THE METRICS, per docs/PLAN.md: sharing-degree distribution, and invalidations
# per kilo-instruction, measured the same way on both sides.
#
# Note: run_gem5_splash.sh's header says "invalidations per thousand LLC
# accesses" instead. PLAN.md is the plan of record and per-kilo-instruction is
# what the ChampSim side already reports, so that is what this uses. The
# discrepancy is real and is recorded rather than silently resolved.
#
# COMPARING RATES IS THE WHOLE POINT. gem5+Ruby is orders of magnitude slower
# than Pin tracing, so these runs are far shorter than the ChampSim ones and
# raw counts are not comparable. Rates survive the difference in length.
set -uo pipefail

# The results directory follows the protocol the build holds, as in
# run_gem5_splash.sh, so Two_Level and Three_Level runs are never mixed.
GEM5_DIR="${GEM5_DIR:-$HOME/gem5}"
PROTOCOL="${PROTOCOL:-$(cat "$GEM5_DIR/.gem5_protocol" 2>/dev/null || echo MESI_Two_Level)}"
OUT="${OUT:-$HOME/gem5_results$( [ "$PROTOCOL" = MESI_Two_Level ] || echo "_$PROTOCOL")}"

die() { echo "ERROR: $*" >&2; exit 1; }

# gem5 stats.txt has two shapes for a counter:
#   scalar   name  value  ...                         -> value
#   vector   name  | v0 pct cum | v1 pct cum | ...   -> v0 + v1 + ...
# Per-controller event counts on a multi-core run are VECTORS, one entry per
# controller (L1Cache_Controller.EE.Fwd_GETX on ocean 4c: | 7052 ... | 7353 ...).
# Reading $2 there returned the literal "|", which awk then added as 0 -- so
# every L1-side stat read as zero on any multi-core run, and the forward
# cross-check below could only ever fail there. Single-core runs and the
# shared L2 (one controller) print scalars, which is why it went unseen.
statval() {   # $1 file  $2 exact stat name -> value (vectors summed), or empty
  awk -v k="$2" '$1 == k {
    if ($2 == "|") { s = 0; for (i = 2; i < NF; i++) if ($i == "|") s += $(i + 1); print s }
    else print $2
    exit }' "$1"
}

phase_discover() {
  local d f n=0
  for d in "$OUT"/*/; do
    [ -d "$d" ] || continue
    f="$d/stats.txt"
    [ -s "$f" ] || { printf '   %-18s no stats.txt (still running or failed)\n' "$(basename "$d")"; continue; }
    n=$((n + 1))
    echo "=============================================================="
    echo "== $(basename "$d")"
    echo "=============================================================="
    echo "-- normalisers --"
    local k
    for k in simInsts simOps simTicks system.clk_domain.clock hostSeconds; do
      printf '   %-46s %s\n' "$k" "$(statval "$f" "$k" || echo '(absent)')"
    done

    echo
    echo "-- ruby controller stats whose name suggests coherence --"
    echo "   (Inv, Fwd, Shar, Upgrade, Exclusive, Modified, WB; network msg"
    echo "    counters excluded -- they are routing, not coherence events)"
    echo "   ZEROS ARE SHOWN. On a single-core run every coherence event is"
    echo "   structurally zero, so filtering them out hides the very names this"
    echo "   mode exists to discover."
    awk '$1 ~ /ruby/ && $1 !~ /network/ &&
         $1 ~ /[Ii]nv|Fwd|[Ss]har|[Uu]pgrade|Exclusive|Modified|WB/ {
           printf "   %-62s %s%s\n", $1, $2, ($2 + 0 == 0 ? "   <- zero" : "") }' "$f" | head -60
    local ncoh
    ncoh=$(awk '$1 ~ /ruby/ && $1 !~ /network/ && $1 ~ /[Ii]nv|Fwd/ && $2 + 0 != 0' "$f" | wc -l)
    if [ "${ncoh:-0}" -eq 0 ]; then
      echo
      echo "   >> NO non-zero invalidation or forward events in this run."
      echo "      If it is single-core that is CORRECT and is the gem5 analogue of"
      echo "      ChampSim's private regime reading exactly zero. The names still"
      echo "      cannot be learned from it -- use 'protocol', or a multi-core run."
    fi

    echo
    echo "-- controller totals, for a denominator --"
    awk '$1 ~ /ruby/ && $1 ~ /(accesses|demand_hits|demand_misses|total)/ {
           v = $2 + 0; if (v != 0) printf "   %-62s %s\n", $1, $2 }' "$f" | head -25

    echo
    echo "-- anything resembling a sharing-degree distribution --"
    echo "   (a bucketed stat on a CACHE controller, not a network router and not"
    echo "    a latency or delay histogram -- those matched before and are noise)"
    awk '$1 ~ /ruby/ && $1 !~ /network|[Dd]elay|[Ll]atency|Hist/ &&
         $1 ~ /(::|\.)[0-9]+$/ && $2 + 0 != 0 { printf "   %-62s %s\n", $1, $2 }' "$f" | head -20
    echo "   (empty here means MESI_Two_Level does not export one -- that is the"
    echo "    B3 scope question in docs/PLAN.md, not a bug)"
    echo
  done
  [ "$n" -gt 0 ] || die "no completed gem5 runs under $OUT"
  echo "Next: put the exact names you see above into INV_STATS / INSTS_STAT"
  echo "below, then run 'extract'. Do not guess them."
}

# Fill these from `discover` output. Space-separated; all are summed.
# Deliberately EMPTY so extract fails loudly rather than reporting a guess.
INV_STATS="${INV_STATS:-}"
INSTS_STAT="${INSTS_STAT:-simInsts}"

phase_extract() {
  # PRESET names a stat set that has been READ FROM THE PROTOCOL, not guessed.
  # mesi_two_level was confirmed on 2026-09-23 against the real
  # MESI_Two_Level-L2cache.sm (bench/policy_sanity/phaseB_metric_semantics_2026-09-23.md):
  #   SS.L1_GETX   store miss, line shared by other L1s -> invalidate them
  #   MT.L1_GETX   store miss, line owned by one L1     -> forward to the owner,
  #                which gives the line up (E/M,Fwd_GETX -> I)
  #   SS.L1_UPGRADE store to a line the requester already holds shared --
  #                reported SEPARATELY, because ChampSim cannot see it at all
  # Per-state stats only. The event total L2Cache_Controller.L1_GETX also counts
  # requests stalled in transient states and re-fired, so it overcounts.
  #
  # mesi_three_level (2026-10-01): the shared cache IS the same controller.
  # MESI_Three_Level.slicc (v25.1.0.1) includes MESI_Two_Level-L2cache.sm for
  # its L2, so SS.L1_GETX / MT.L1_GETX / SS.L1_UPGRADE mean exactly what they
  # mean above; "L1" there is the requester, which in Three_Level is the
  # private unified cache (ChampSim's L2C). What changes is the private side
  # of the forward cross-check. In MESI_Three_Level-L1cache.sm the owner gives
  # the line up from EE and MM (-> I) and from M_I (-> SINK_WB_ACK); the
  # *_IL0 states only stall Fwd_GETX (z2_stallAndWaitL2Queue) and are left out.
  # On the patched ocean 4c run (grid 258), L2 MT.L1_GETX 44,093 ==
  # L1 EE.Fwd_GETX 28,474 + MM.Fwd_GETX 15,619.
  local FWD_STATES
  case "${PRESET:-}" in
    mesi_two_level)
      : "${INV_STATS:=system.ruby.L2Cache_Controller.SS.L1_GETX system.ruby.L2Cache_Controller.MT.L1_GETX}"
      : "${UPG_STATS:=system.ruby.L2Cache_Controller.SS.L1_UPGRADE}"
      FWD_STATES="E M M_I"
      ;;
    mesi_three_level)
      : "${INV_STATS:=system.ruby.L2Cache_Controller.SS.L1_GETX system.ruby.L2Cache_Controller.MT.L1_GETX}"
      : "${UPG_STATS:=system.ruby.L2Cache_Controller.SS.L1_UPGRADE}"
      FWD_STATES="EE MM M_I"
      ;;
    "") FWD_STATES="E M M_I" ;;
    *) die "unknown PRESET '${PRESET}' -- known: mesi_two_level, mesi_three_level" ;;
  esac
  [ -n "$INV_STATS" ] || die "INV_STATS is empty. Run 'discover' first and set it to the
       exact invalidation stat name(s) that run produced, e.g.
         INV_STATS='system.ruby.L1Cache_Controller.Inv::total' bash $0 extract
       Guessing a name here is how a metric ends up silently reading zero."
  local d f inv upg insts k v l2f l1f
  sumstats() {   # $1 file, rest: stat names -> sum, or die on any missing
    local file="$1" total=0 name val; shift
    for name in "$@"; do
      val=$(statval "$file" "$name")
      [ -n "$val" ] || die "stat '$name' not present in $file -- re-run discover; a missing stat is an error, not a zero"
      total=$(awk -v a="$total" -v b="$val" 'BEGIN{print a+b}')
    done
    echo "$total"
  }
  echo "   results: $OUT"
  printf '   %-18s %12s %12s %14s %10s %10s\n' run 'inv events' upgrades instructions 'inv/KI' 'upg/KI'
  local why xfail=0
  for d in "$OUT"/*/; do
    [ -d "$d" ] || continue
    f="$d/stats.txt"; [ -s "$f" ] || continue
    # Only a run that ENDED is measured. gem5 creates stats.txt at start-up, and
    # a run that panicked can leave a partial one; the exit line is what says it
    # finished (the same test run_gem5_splash.sh stats uses).
    why=$(grep -m1 -oE "Exiting @ tick [0-9]+ because .*" "$d/run.log" 2>/dev/null)
    if [ -z "$why" ]; then
      printf '   %-18s skipped: no gem5 exit line in run.log (running, failed, or killed)\n' "$(basename "$d")"
      continue
    fi
    # shellcheck disable=SC2086
    inv=$(sumstats "$f" $INV_STATS) || exit 1
    upg="-"
    # shellcheck disable=SC2086
    [ -n "${UPG_STATS:-}" ] && { upg=$(sumstats "$f" $UPG_STATS) || exit 1; }
    insts=$(statval "$f" "$INSTS_STAT")
    [ -n "$insts" ] || die "'$INSTS_STAT' not present in $f"
    printf '   %-18s %12s %12s %14s %10s %10s\n' "$(basename "$d")" "$inv" "$upg" "$insts" \
      "$(awk -v i="$inv" -v n="$insts" 'BEGIN{ printf (n>0 ? "%.4f" : "n/a"), 1000*i/n }')" \
      "$(awk -v i="$upg" -v n="$insts" 'BEGIN{ if (i=="-") print "-"; else printf (n>0 ? "%.4f" : "n/a"), 1000*i/n }')"

    # Cross-check that the stats are being read the way the protocol says.
    # Fwd_GETX is sent only by MT.L1_GETX (b_forwardRequestToExclusive), and
    # every forward is handled exactly once at the owning L1, in E, M or M_I
    # (LLSC_E/LLSC_M stall it and re-fire it, so their counts are excluded).
    # The two sides must therefore agree. A mismatch means our model of the
    # protocol is wrong, and every number above inherits that. This is the
    # gem5 counterpart of the TOTAL == LOAD+WRITE+RFO+TRANSLATION identity on
    # the ChampSim side.
    l2f=$(statval "$f" "system.ruby.L2Cache_Controller.MT.L1_GETX")
    l1f=0; local st miss=0
    for st in $FWD_STATES; do
      v=$(statval "$f" "system.ruby.L1Cache_Controller.$st.Fwd_GETX")
      [ -n "$v" ] && l1f=$(awk -v a="$l1f" -v b="$v" 'BEGIN{print a+b}') || miss=$((miss + 1))
    done
    if [ -z "$l2f" ]; then
      echo "      cross-check: cannot run, MT.L1_GETX absent"
    elif [ "$l2f" = "$l1f" ]; then
      echo "      cross-check ok: L2 MT.L1_GETX $l2f == L1 {${FWD_STATES// /,}}.Fwd_GETX $l1f   (${why#Exiting @ })"
    else
      xfail=$((xfail + 1))
      echo "      !! cross-check FAILED: L2 MT.L1_GETX $l2f != L1 {${FWD_STATES// /,}}.Fwd_GETX $l1f"
      echo "         ($miss of $(echo $FWD_STATES | wc -w) L1 per-state stats absent) -- the protocol model above is wrong somewhere"
    fi
  done
  echo
  echo "   NOT yet comparable with ChampSim's inv/KI: ChampSim's counter fires when an"
  echo "   L2 WRITEBACK hits the LLC, gem5's at the STORE request"
  echo "   (bench/policy_sanity/phaseB_metric_semantics_2026-09-23.md). The fair"
  echo "   ChampSim side is the store-time counter (docs/PLAN.md section 3)."
  # A failed cross-check means the protocol model is wrong and every number
  # above inherits it: the run must not look like a success to a caller.
  [ "$xfail" -eq 0 ] || die "$xfail run(s) failed the forward cross-check -- do not use these numbers"
}

# The protocol's own .sm files declare every event name. That is a far more
# reliable source than a run that may never trigger them -- a single-core run
# produces no invalidations at all, so its stats file cannot teach the
# vocabulary.
phase_protocol() {
  local g="${GEM5_DIR:-$HOME/gem5}" d
  d="$g/src/mem/ruby/protocol"
  [ -d "$d" ] || d=$(find "$g/src" -type d -name protocol 2>/dev/null | head -1)
  [ -d "$d" ] || die "no Ruby protocol directory under $g/src"
  echo "== MESI_Two_Level event vocabulary, from the protocol definition =="
  echo "   $d"
  local f
  for f in "$d"/MESI_Two_Level-L1cache.sm "$d"/MESI_Two_Level-L2cache.sm; do
    [ -f "$f" ] || continue
    echo
    echo "-- $(basename "$f") events --"
    awk '/^[[:space:]]*enumeration\(Event/,/^[[:space:]]*}/ {
           if ($1 ~ /^[A-Za-z_]/ && $1 !~ /enumeration|desc/) {
             n=$1; sub(/,.*/,"",n); gsub(/[^A-Za-z_0-9]/,"",n)
             if (n != "" && n != "Event") printf "   %s\n", n } }' "$f" | sort -u | head -40
  done
  echo
  echo "   gem5 reports these as system.ruby.<L1Cache|L2Cache>_Controller.<Event>"
  echo "   and per-transition as ...<State>.<Event>."

  # WHICH transitions send an invalidation, read from the protocol rather than
  # inferred from event names.
  #
  # An event called Inv at L1 fires for every invalidation an L1 RECEIVES,
  # whatever caused it -- a peer's store to a shared line, or the inclusive L2
  # recalling a line it is evicting. ChampSim's LLC counter has no inclusion
  # recall at all (cache.cc:246-248: "ChampSim models no inter-level
  # coherence"), so summing every L1 Inv would count a class of event the other
  # side cannot produce. The transitions below say which (state, event) pair
  # issues each invalidation, which is what separates coherence from recall.
  for f in "$d"/MESI_Two_Level-L1cache.sm "$d"/MESI_Two_Level-L2cache.sm; do
    [ -f "$f" ] || continue
    echo
    echo "-- $(basename "$f"): transitions whose actions send or handle an invalidation --"
    awk '
      /^[[:space:]]*transition[[:space:]]*\(/ { inhdr=1; inblk=0; hdr=""; acc="" }
      # The header ends at ") {" -- NOT at the first "{". SLICC writes state
      # and event SETS with braces inside the argument list, as in
      # transition({SS, SS_MB, MT}, L2_Replacement, S_I) {, so the first "{"
      # is usually a set literal. Cutting there printed the header as
      # "transition(" and hid which states the transition applies to.
      inhdr {
        l=$0; gsub(/^[[:space:]]+/,"",l); hdr = hdr (hdr=="" ? "" : " ") l
        if ($0 ~ /\)[[:space:]]*\{/) { inhdr=0; inblk=1; sub(/\)[[:space:]]*\{.*$/, ")", hdr) }
        next
      }
      inblk && /^[[:space:]]*\}/ { if (acc != "") printf "   %s\n%s", hdr, acc; inblk=0; next }
      inblk {
        l=$0; sub(/\/\/.*/,"",l)
        if (l ~ /[Ii]nv/) { gsub(/^[[:space:]]+|[[:space:]]+$/,"",l); acc = acc "        " l "\n" }
      }' "$f" | head -80
  done
  echo
  echo "   Read these before choosing INV_STATS. A transition triggered by a"
  echo "   REQUEST (L1_GETX, L1_UPGRADE) is coherence; one triggered by"
  echo "   L2_Replacement is an inclusion recall with no ChampSim counterpart."

  # The listing above selects transitions by ACTION NAME, and that misses a
  # whole class. A store miss to a line one core owns exclusively (L2 state MT)
  # is resolved by FORWARDING the request to the owner, which gives the line up
  # -- another core's copy removed by a write, exactly what ChampSim's counter
  # means -- but the forwarding actions do not have "Inv" in their names, so the
  # name filter never shows them. Listing by EVENT is complete where listing by
  # action name is not.
  local ev f
  for f in "$d"/MESI_Two_Level-L2cache.sm "$d"/MESI_Two_Level-L1cache.sm; do
    [ -f "$f" ] || continue
    case "$f" in
      *L2cache*) ev="L1_GETX L1_UPGRADE" ;;
      *)         ev="Fwd_GETX Fwd_GETS" ;;
    esac
    echo
    echo "-- $(basename "$f"): every transition on $ev, with ALL its actions --"
    awk -v evs="$ev" '
      BEGIN { n = split(evs, E, " ") }
      /^[[:space:]]*transition[[:space:]]*\(/ { inhdr=1; inblk=0; hdr=""; acc="" }
      inhdr {
        l=$0; gsub(/^[[:space:]]+/,"",l); hdr = hdr (hdr=="" ? "" : " ") l
        if ($0 ~ /\)[[:space:]]*\{/) { inhdr=0; inblk=1; sub(/\)[[:space:]]*\{.*$/, ")", hdr)
          hit=0
          for (i = 1; i <= n; i++) if (hdr ~ ("[^A-Za-z0-9_]" E[i] "[^A-Za-z0-9_]")) hit=1
        }
        next
      }
      inblk && /^[[:space:]]*\}/ { if (hit) printf "   %s\n%s", hdr, acc; inblk=0; next }
      inblk { l=$0; sub(/\/\/.*/,"",l); gsub(/^[[:space:]]+|[[:space:]]+$/,"",l)
              if (l != "") acc = acc "        " l "\n" }' "$f" | head -90
  done
}

# B3: rates over spans of instructions, from runs that stopped at different
# points (launch_b3_gem5.sh). gem5 is deterministic with randomization off,
# so the run stopped at B contains the run stopped at A, and stats(B) -
# stats(A) is the span A..B. Three stops give three spans: 0..A, A..B, and
# B..end when the whole-program run is given. Steady rates across them mean
# the window ChampSim measures need not line up exactly.
# Counters going BACKWARDS between stops would mean the runs diverged and the
# subtraction is meaningless: refused.
phase_window() {
  [ "$#" -ge 2 ] || die "usage: $0 window RUN_STOPPED_EARLY RUN_STOPPED_LATER [WHOLE_PROGRAM_RUN]"
  # Per-cpu instruction counts are discovered from the first run, so a
  # 5-CPU canneal run (main thread + 4 workers) is read like a 4-CPU one.
  local cpus
  cpus=$(grep -oE '^system\.cpu[0-9]+\.commitStats0\.numInsts ' "$1/stats.txt" 2>/dev/null | sort -t u -k2 -V | tr -d ' ' | tr '\n' ' ')
  [ -n "$cpus" ] || die "no per-cpu instruction stats in $1/stats.txt"
  local names="simInsts system.ruby.L2Cache_Controller.SS.L1_GETX system.ruby.L2Cache_Controller.MT.L1_GETX system.ruby.L2Cache_Controller.SS.L1_UPGRADE system.ruby.l2_cntrl0.L2cache.m_demand_accesses system.ruby.l2_cntrl0.L2cache.m_demand_hits $cpus"
  local d f n v why table=""
  for d in "$@"; do
    f="$d/stats.txt"
    [ -s "$f" ] || die "no stats.txt in $d"
    why=$(grep -m1 -oE "Exiting @ tick [0-9]+ because .*" "$d/run.log" 2>/dev/null)
    [ -n "$why" ] || die "$d did not end (no gem5 exit line in run.log)"
    echo "   $(basename "$(dirname "$d")")/$(basename "$d"): ${why#Exiting @ }"
    local row=""
    for n in $names; do
      v=$(statval "$f" "$n"); [ -n "$v" ] || die "stat '$n' not present in $f"
      row="$row $v"
    done
    table="$table${row# }"$'\n'
  done
  printf '%s' "$table" | awk -v nruns="$#" -v ncpu="$(echo $cpus | wc -w)" '
    { for (i = 1; i <= NF; i++) v[NR, i] = $i }
    END {
      span[1] = "0 .. stop 1"; span[2] = "stop 1 .. stop 2"; span[3] = "stop 2 .. end"
      printf "\n   %-18s %14s %12s %12s %10s %10s %12s %9s\n", "span", "instructions", "inv events", "upgrades", "inv/KI", "upg/KI", "L2 acc/KI", "L2 hit"
      bad = 0
      nf = 6 + ncpu
      for (r = 1; r <= nruns; r++) {
        for (i = 1; i <= nf; i++) d[i] = v[r, i] - (r > 1 ? v[r - 1, i] : 0)
        for (i = 1; i <= nf; i++) if (d[i] < 0) bad = 1
        ins = d[1]; inv = d[2] + d[3]
        printf "   %-18s %14d %12d %12d %10.4f %10.4f %12.3f %8.2f%%\n", span[r], ins, inv, d[4],
               (ins > 0 ? 1000 * inv / ins : 0), (ins > 0 ? 1000 * d[4] / ins : 0),
               (ins > 0 ? 1000 * d[5] / ins : 0), (d[5] > 0 ? 100 * d[6] / d[5] : 0)
        printf "   %-18s per-cpu instructions at stop %d:", "", r
        for (i = 7; i <= nf; i++) printf " %d", v[r, i]
        printf "\n"
      }
      if (bad) { print "   !! a counter went BACKWARDS between stops -- the runs diverged; these spans are meaningless"; exit 3 }
    }' || die "window arithmetic refused (see above)"
}

case "${1:-}" in
  window)   shift; phase_window "$@" ;;
  discover) phase_discover ;;
  protocol) phase_protocol ;;
  extract)  phase_extract ;;
  *) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
