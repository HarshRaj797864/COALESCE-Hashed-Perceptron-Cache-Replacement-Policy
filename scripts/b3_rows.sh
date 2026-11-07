#!/usr/bin/env bash
# The store-time sharing counters from the B3 ChampSim runs, for the gem5
# comparison. Read-only.
#
#   scp -P 2222 scripts/b3_rows.sh user@your-server:~/
#   ssh -n -p 2222 user@your-server 'bash ~/b3_rows.sh' > bench/policy_sanity/b3_rows_vN.txt
#
# One row per run.log under results/phaseA_b3_* and results/phaseA_l2_*:
#   tree pol wl cores regime status instructions
#   rfo_events rfo_sharers  wb_events wb_invalidations
#   dir_presence_events dir_presence_cores dir_protocol_events dir_protocol_cores
#   dir_registered dir_selfcheck_mismatches  rmw_loads_as_rfo
#   level  upgrade_events upgrade_cores upgrade_presence_events
#   copies_invalidated stale_fills stale_holders
# The last seven are B3 v4 (b3v4_coherent_private_design_2026-10-11.md), "-"
# from an earlier binary: the private-cache coherence level the run printed;
# stores and RFOs that hit a private copy while another core was listed (and
# the cores listed; and by presence); private copies invalidated; fills
# dropped as stale -- each summed over the private caches -- and the LLC's
# stale-holder check (must be 0). phaseA_l2_* is the A5 rerun at level 2.
# The last two (2026-10-17, b3_bounded_design_2026-10-17.md; "-" from an
# earlier binary): store misses at the LLC and upgrades for which the BOUNDED
# protocol view lists another core -- a diagnosis, records only.
# The last five (2026-10-19, b3_g5rule_design_2026-10-19.md; "-" from an
# earlier binary): the gem5-rule view's store misses at the LLC that find
# another core, and the cores; its upgrades, and the cores (summed over the
# private caches); and the LLC's view-order check (must be 0).
# dir_* come from the sharer directory (B3 v2, acb76b2): store-time events per
# RFO against presence (private caches holding the line) and against the
# protocol view; the number of private caches registered (must be 3 x cores);
# and the self-check summed over every private cache (must be 0).
# rmw_loads_as_rfo: loads of read-modify-write instructions issued as RFOs,
# summed over the cores, whole simulation (B3 v3 step 1, f23e03f); "-" from an
# earlier binary. (b3_rows_v5 and earlier: Region of Interest, 0.7% lower.)
# rfo_* are the store-time counters (5ac2844): an RFO hit at the LLC whose
# sharer mask names other cores. They pair with gem5's L2 SS.L1_GETX +
# MT.L1_GETX (gem5_stats.sh). wb_* are the older writeback-time counters,
# kept for contrast.
#
# Separate from `run_phase_a.sh rows` on purpose: that file's 23 columns are
# what analyze_rows.py parses, and it is read by live queue drivers, so it is
# not edited mid-sweep.
#
# A counter line that is ABSENT prints "-", never 0: a log from a binary
# without the counter must not read as "no sharing". The coherence lines are
# printed once per stats block, and for the final phase both blocks are
# identical (end_phase copies sim_stats into roi_stats), so the first
# occurrence is the run's value.
set -uo pipefail

S="${S:-$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy/simulator}"
DONE_MARKER="ChampSim completed all CPUs"

val() { grep -m1 "^LLC COHERENCE $1" "$2" | grep -oE '[0-9]+$' || echo -; }
# The self-check, summed over the private caches -- the first stats block of
# each, since every block is printed twice on a multi-core run.
selfcheck() {
  awk '/^cpu[0-9]+_(L1I|L1D|L2C) COHERENCE DIR SELF-CHECK MISMATCHES:/ { if (!seen[$1]++) { s += $NF; n++ } }
       END { if (n) print s; else print "-" }' "$1"
}

# Read-modify-write loads issued as RFOs, summed over the cores, from the
# WHOLE-SIMULATION block: each core's first block.
#
# A core's two blocks differ: its Region of Interest block stops when that
# core reaches its own instruction target, and the whole-simulation block
# keeps counting while it waits for the others (synthetic test: 101,110
# against the ROI's 99,936). Everything else in this row is whole-simulation:
# the instruction column sums "Simulation complete", printed at the end of the
# phase, and CACHE::end_phase copies every cache counter whole
# (roi_stats.hits = sim_stats.hits), so the LLC's two blocks are equal.
#
# This first read the ROI block, on the false belief that the instruction
# column was per-core ROI too. That put this column 0.7% low on canneal (5.60
# per KI for 5.64), found 2026-10-11 by re-deriving a row from its raw log.
# Rows files up to b3_rows_v5 carry the ROI value.
rmw() {
  awk '/^CPU [0-9]+ RMW LOADS ISSUED AS RFO:/ { if (!seen[$2]++) { s += $NF; n++ } }
       END { if (n) print s; else print "-" }' "$1"
}

# A B3 v4 counter, summed over the private caches: each cache's first block
# (CACHE::end_phase copies these whole, so both blocks are equal).
privsum() {
  awk -v pat="^cpu[0-9]+_(L1I|L1D|L2C) COHERENCE DIR $1:" '$0 ~ pat { if (!seen[$1]++) { s += $NF; n++ } }
       END { if (n) print s; else print "-" }' "$2"
}
level() { grep -m1 '^PRIVATE-CACHE COHERENCE LEVEL:' "$1" | grep -oE '[0-9]+$' || echo -; }

n=0
for root in "$S"/results/phaseA_b3_* "$S"/results/phaseA_l2_*; do
  [ -d "$root" ] || continue
  tree=$(basename "$root")
  while IFS= read -r log; do
    [ -s "$log" ] || continue
    d=$(dirname "$log")
    rg=$(echo "$d" | sed 's|.*regime_\([a-z]*\)/.*|\1|')
    wl=$(echo "$d" | sed 's|.*/\([a-z_]*\)_[0-9]*core/.*|\1|')
    cores=$(echo "$d" | sed 's|.*_\([0-9]*\)core/.*|\1|')
    pol=$(basename "$d")
    grep -q "$DONE_MARKER" "$log" && st=complete || st=INCOMPLETE
    ins=$(awk '/Simulation complete CPU [0-9]+ instructions:/ {
                 for (i = 1; i <= NF; i++) if ($i == "instructions:") s += $(i+1) } END { print s+0 }' "$log")
    echo "$tree $pol $wl $cores $rg $st $ins $(val 'RFO-HIT OTHER-SHARER EVENTS' "$log") $(val 'RFO-HIT OTHER SHARERS' "$log") $(val 'WRITE-HIT OTHER-SHARER EVENTS' "$log") $(val 'INVALIDATIONS' "$log") $(val 'DIR RFO PRESENCE-OTHER EVENTS' "$log") $(val 'DIR RFO PRESENCE-OTHER CORES' "$log") $(val 'DIR RFO PROTOCOL-OTHER EVENTS' "$log") $(val 'DIR RFO PROTOCOL-OTHER CORES' "$log") $(val 'DIR PRIVATE CACHES REGISTERED' "$log") $(selfcheck "$log") $(rmw "$log") $(level "$log") $(privsum 'UPGRADE EVENTS' "$log") $(privsum 'UPGRADE OTHER CORES' "$log") $(privsum 'UPGRADE PRESENCE EVENTS' "$log") $(privsum 'COPIES INVALIDATED' "$log") $(privsum 'STALE FILLS DROPPED' "$log") $(val 'DIR STALE-HOLDER VIOLATIONS' "$log") $(val 'DIR RFO BOUNDED-PROTOCOL EVENTS' "$log") $(privsum 'UPGRADE BOUNDED-PROTOCOL EVENTS' "$log") $(val 'DIR RFO GEM5-RULE EVENTS' "$log") $(val 'DIR RFO GEM5-RULE CORES' "$log") $(privsum 'UPGRADE GEM5-RULE EVENTS' "$log") $(privsum 'UPGRADE GEM5-RULE CORES' "$log") $(val 'DIR VIEW-ORDER VIOLATIONS' "$log")"
    n=$((n + 1))
  done < <(find "$root" -name run.log 2>/dev/null | sort)
done
[ "$n" -gt 0 ] || { echo "no run.log under $S/results/phaseA_b3_* or phaseA_l2_*" >&2; exit 1; }
