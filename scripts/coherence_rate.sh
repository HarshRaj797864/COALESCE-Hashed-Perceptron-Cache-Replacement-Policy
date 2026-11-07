#!/usr/bin/env bash
# How much coherence traffic is there, relative to LLC work?
#
#   scp -P 2222 scripts/coherence_rate.sh user@your-server:~/
#   ssh -p 2222 user@your-server 'bash ~/coherence_rate.sh'
#
# Read-only; parses logs that already exist.
#
# WHY: the overlay validation shows invalidations scaling cleanly with core
# count, but at 16 cores that is 73,351 invalidations across 160M instructions
# -- about 0.46 per thousand instructions, which is sparse. And sharing makes
# the workload *faster* by a near-constant ~17% at every core count, which
# reads as a capacity effect (fewer copies, less pressure) rather than
# coherence pressure a smarter policy could exploit.
#
# If coherence events are rare as a fraction of LLC accesses, a coherence-aware
# replacement policy has little to act on, and that would be an explanation for
# COALESCE's -2.4% that is not "the implementation was broken". This measures
# the headroom directly.
#
# Prints the raw matched lines for the first log before aggregating anything,
# so the parse can be checked rather than trusted.
set +e

R="$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy"
S="$R/simulator"
ROOT="${RESULTS_ROOT:-$S/results/phaseA_quick}"

echo "coherence_rate  $(date '+%F %T')"
echo "reading: $ROOT"

first=$(find "$ROOT" -name run.log 2>/dev/null | sort | head -1)
if [ -z "$first" ]; then echo "no logs under $ROOT"; exit 1; fi

echo
echo "============================================================"
echo "PARSE CHECK -- raw lines from $(echo "$first" | sed "s|$ROOT/||")"
echo "============================================================"
echo "-- lines containing LLC and ACCESS (first 8):"
grep -E "LLC.*ACCESS:" "$first" 2>/dev/null | head -8 | sed 's/^/   /'
echo "-- coherence / vmem lines:"
grep -E "COHERENCE|ALIASED" "$first" 2>/dev/null | grep -vE "^cpu[0-9]+_(L1|L2|DTLB|ITLB|STLB)" | head -6 | sed 's/^/   /'
echo
echo "   If the LLC ACCESS lines above are not per-CPU LLC access counts,"
echo "   the totals below are meaningless -- say so rather than using them."

echo
echo "============================================================"
echo "RATES"
echo "============================================================"
printf '%-9s %-8s %12s %12s %9s %12s %10s %11s\n' \
  workload regime LLC_access LLC_miss hit_rate invalidations inv/1k_acc alias/1k_acc

find "$ROOT" -name run.log 2>/dev/null | sort | while read -r log; do
  grep -q "ChampSim completed all CPUs" "$log" 2>/dev/null || continue
  d=$(dirname "$log")
  rg=$(echo "$d" | sed 's|.*regime_\([a-z]*\)/.*|\1|')
  wl=$(echo "$d" | sed 's|.*/\([a-z_]*\)_[0-9]*core/.*|\1|')
  cores=$(echo "$d" | sed 's|.*_\([0-9]*\)core/.*|\1|')

  # Sum the per-CPU LLC TOTAL rows ONLY.
  #
  # ChampSim prints, per CPU, a TOTAL row followed by LOAD / RFO / PREFETCH /
  # WRITE / TRANSLATION rows, and TOTAL is their sum -- verified on a real log:
  # 50,964 + 4 + 0 + 23,958 + 2,927 = 77,853 = the TOTAL. Matching every LLC row
  # therefore counted each access twice and halved every rate this script
  # reported.
  read -r acc hit miss <<< "$(grep -E "^cpu[0-9]+->LLC TOTAL" "$log" 2>/dev/null \
    | awk '{for(i=1;i<=NF;i++){if($i=="ACCESS:")a+=$(i+1); if($i=="HIT:")h+=$(i+1); if($i=="MISS:")m+=$(i+1)}} END{print a+0, h+0, m+0}')"

  inv=$(grep -m1 "^LLC COHERENCE INVALIDATIONS" "$log" 2>/dev/null | grep -oE '[0-9]+$')
  ali=$(grep -m1 "VMEM ALIASED FILLS" "$log" 2>/dev/null | grep -oE '[0-9]+$')
  inv=${inv:-0}; ali=${ali:-0}

  python3 - "$wl" "$cores" "$rg" "$acc" "$hit" "$miss" "$inv" "$ali" << 'PY'
import sys
wl, cores, rg, acc, hit, miss, inv, ali = sys.argv[1:9]
acc, hit, miss, inv, ali = (int(x or 0) for x in (acc, hit, miss, inv, ali))
hr = f"{100*hit/acc:.2f}%" if acc else "n/a"
r1 = f"{1000*inv/acc:.2f}" if acc else "n/a"
r3 = f"{1000*ali/acc:.2f}" if acc else "n/a"
print(f"{wl+'/'+cores+'c':<9} {rg:<8} {acc:>12} {miss:>12} {hr:>9} {inv:>12} {r1:>10} {r3:>11}")
PY
done

echo
echo "inv/1k_acc is invalidations per thousand LLC accesses -- the headroom a"
echo "coherence-aware policy has to act on. hit_rate is the other half of the"
echo "story: a policy cannot improve a cache that never hits, whatever signal"
echo "it keys on."
