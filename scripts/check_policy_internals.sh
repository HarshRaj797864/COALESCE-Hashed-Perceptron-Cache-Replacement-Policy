#!/usr/bin/env bash
# Do the learned policies actually run their own mechanisms? Read-only.
#
#   scp -P 2222 scripts/check_policy_internals.sh user@your-server:~/
#   ssh -p 2222 user@your-server 'bash ~/check_policy_internals.sh' > internals.txt
#
# WHY THIS IS DIFFERENT FROM THE OTHER GUARDS. check_fill_hook.sh proves a fill
# hook EXISTS. A4 proves two policies do not produce IDENTICAL results. Neither
# proves a mechanism inside a policy actually fires: COALESCE's ghost-tag rescue
# was dead code for months while the surrounding policy ran and produced
# plausible numbers, and Hawkeye's detraining did not exist at all.
#
# COALESCE, Hawkeye and Mockingjay each print internal counters at end of run,
# so every completed log already carries the evidence. Nothing needs re-running.
#
# A ZERO IS A DEAD MECHANISM. Every counter below was zero, absent, or unreachable
# at some point in this project's history:
#   coalesce ghost_rescues  the fill hook did not exist, so the rescue never ran
#   coalesce detrains       there was no detraining at all
#   hawkeye  fills          H1: never told about fills, insertion RRPV never set
#   hawkeye  detrains       H2: absent, no sample_signature array
#   mockingjay fills        no insertion hook
#   mockingjay rdp_entries  predictor never trained
set -uo pipefail

R="$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy"
S="$R/simulator"
DONE="ChampSim completed all CPUs"
fails=0; warns=0; checked=0

# $1 log  $2 regex  -> the captured number, or empty
num() { grep -oE "$2" "$1" 2>/dev/null | tail -1 | grep -oE '[0-9]+$'; }

check_one() {
  local log="$1" pol="$2" rel="$3" bad=""
  case "$pol" in
    coalesce|coalesce_no_mesi|coalesce_no_sharer)
      local gi gr dt ht
      gi=$(num "$log" 'ghost_inserts [0-9]+')
      gr=$(num "$log" 'ghost_rescues [0-9]+')
      dt=$(num "$log" 'detrains +[0-9]+')
      ht=$(num "$log" 'hit_trains [0-9]+')
      [ -z "$gi" ] && { printf '   %-58s %-20s NO STATS LINE\n' "$rel" "$pol"; warns=$((warns+1)); return; }
      [ "${gi:-0}" -eq 0 ] && bad="$bad ghost_inserts=0"
      [ "${gr:-0}" -eq 0 ] && bad="$bad ghost_rescues=0"
      [ "${dt:-0}" -eq 0 ] && bad="$bad detrains=0"
      [ "${ht:-0}" -eq 0 ] && bad="$bad hit_trains=0"
      printf '   %-58s ins %12s  resc %10s  detr %12s  hitt %12s' "$rel" "$gi" "$gr" "$dt" "$ht"
      ;;
    hawkeye)
      local fi hi dt oa
      fi=$(num "$log" 'fills [0-9]+'); hi=$(num "$log" 'Hawkeye: fills [0-9]+ hits [0-9]+')
      dt=$(num "$log" 'detrains [0-9]+'); oa=$(num "$log" 'accesses [0-9]+')
      [ -z "$fi" ] && { printf '   %-58s %-20s NO STATS LINE\n' "$rel" "$pol"; warns=$((warns+1)); return; }
      [ "${fi:-0}" -eq 0 ] && bad="$bad fills=0"
      [ "${dt:-0}" -eq 0 ] && bad="$bad detrains=0"
      [ "${oa:-0}" -eq 0 ] && bad="$bad optgen_accesses=0"
      printf '   %-58s fills %11s  hits %11s  detr %12s  optgen %10s' "$rel" "$fi" "$hi" "$dt" "$oa"
      ;;
    mockingjay)
      local vi fi rd
      vi=$(num "$log" 'victims [0-9]+')
      rd=$(num "$log" 'rdp_entries [0-9]+')
      fi=$(num "$log" 'Mockingjay: fills [0-9]+')
      [ -z "$vi" ] && { printf '   %-58s %-20s NO STATS LINE\n' "$rel" "$pol"; warns=$((warns+1)); return; }
      [ "${fi:-0}" -eq 0 ] && bad="$bad fills=0"
      [ "${rd:-0}" -eq 0 ] && bad="$bad rdp_entries=0"
      printf '   %-58s victims %9s  fills %10s  rdp %13s' "$rel" "$vi" "$fi" "$rd"
      ;;
    *) return ;;
  esac
  checked=$((checked+1))
  if [ -n "$bad" ]; then echo "   <-- DEAD:$bad"; fails=$((fails+1)); else echo; fi
}

echo "== policy internal counters, from completed logs =="
echo "   (a zero in any column means that mechanism never ran)"
echo
for root in "$S"/results/phaseA*/ "$S"/results/a4/; do
  [ -d "$root" ] || continue
  while IFS= read -r log; do
    [ -s "$log" ] || continue
    grep -q "$DONE" "$log" 2>/dev/null || continue
    rel=${log#"$S/results/"}; rel=${rel%/run.log}
    # policy is the last path component for phaseA, the second-to-last for a4
    case "$rel" in
      a4/*) pol=$(basename "$(dirname "$log")") ;;
      *)    pol=$(basename "$(dirname "$log")") ;;
    esac
    check_one "$log" "$pol" "$rel"
  done < <(find "$root" -name run.log 2>/dev/null | sort)
done

echo
echo "== ablations must differ from the full policy =="
echo "   coalesce_no_mesi and coalesce_no_sharer each remove a feature. If a"
echo "   variant's counters match coalesce exactly on the same trace, the"
echo "   ablation is not ablating -- the same class of defect as Hawkeye"
echo "   being byte-identical to SRRIP."
for root in "$S"/results/phaseA*/; do
  [ -d "$root" ] || continue
  while IFS= read -r d; do
    base="$d/coalesce/run.log"
    [ -s "$base" ] || continue
    grep -q "$DONE" "$base" 2>/dev/null || continue
    b=$(grep -oE 'ghost_inserts [0-9]+ ghost_rescues [0-9]+' "$base" 2>/dev/null | tail -1)
    [ -n "$b" ] || continue
    for v in coalesce_no_mesi coalesce_no_sharer; do
      vl="$d/$v/run.log"
      [ -s "$vl" ] || continue
      grep -q "$DONE" "$vl" 2>/dev/null || continue
      a=$(grep -oE 'ghost_inserts [0-9]+ ghost_rescues [0-9]+' "$vl" 2>/dev/null | tail -1)
      rel=${d#"$S/results/"}
      if [ "$a" = "$b" ]; then
        echo "   IDENTICAL: $rel $v matches coalesce -- $a"
        fails=$((fails+1))
      else
        echo "   ok  $rel $v differs"
      fi
    done
  done < <(find "$root" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | sort)
done

echo
echo "== instrumentation gaps =="
echo "   drrip and ship print NO internal counters, and they are precisely the"
echo "   two policies whose defect was that insertion never happened (their"
echo "   PSEL duel / SHCT insertion lived in a branch the dispatch never"
echo "   called). Nothing in a log can currently prove those paths now run."
echo "   Adding counters needs a rebuild, so it must wait for the sweep to"
echo "   drain -- swapping bin/champsim mid-sweep would mix binaries."
echo
echo "== summary =="
echo "   logs checked: $checked   dead mechanisms: $fails   missing stats: $warns"
[ "$fails" -eq 0 ] || echo "   FAIL -- a counter at zero means that code never ran"
