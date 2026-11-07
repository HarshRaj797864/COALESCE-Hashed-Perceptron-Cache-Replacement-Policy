#!/usr/bin/env bash
# Exact tests of the coherence counters: tiny 4-core traces whose counts are
# worked out by hand, and a simulator that must hit them EXACTLY.
#
#   bench/policy_sanity/check_coherence_exact.sh            # ~25 min on a 12-core laptop (8 at a time), ~16 GB of temporary traces
#   BIN=simulator/bin/champsim_x  bench/policy_sanity/check_coherence_exact.sh
#   ONLY="order pingpong" LEVELS="0 2" bench/policy_sanity/check_coherence_exact.sh
#
# Every case runs at each private_coherence level (B3 v4,
# b3v4_coherent_private_design_2026-10-11.md): 0 none, 1 an RFO at the LLC
# invalidates the other cores' private copies, 2 also a store that hits a
# shared private copy (the upgrade).
#
# Run it after any change to the core's memory path, the caches, or the sharer
# directory, before a build goes to the server. The other guards check that
# code paths run; this checks that they count right. "A non-zero counter proves
# a code path runs, not that it is right" (CLAUDE.md).
#
# The traces: coherence_exact_traces.py (it also records the two traps hit
# while writing them). Columns below, all from the Region of Interest block:
#   v1e v1s   LLC-mask store-time events / other sharers   (5ac2844)
#   pre prc   directory presence events / other cores      (acb76b2)
#   pte ptc   directory protocol-view events / other cores (acb76b2)
#   rmw       RMW loads issued as RFOs, all cores           (f23e03f)
#   fwd       RMW loads satisfied from the store queue, never issued. rmw + fwd
#             is every RMW in the trace: the count is known by construction.
#   upe upc   upgrade events / cores listed, summed over the private caches (level 2)
#   inv       private copies invalidated, summed over the private caches (levels 1, 2)
#   g5e g5c g5u  the gem5-rule view (2026-10-19, b3_g5rule_design_2026-10-19.md):
#             store-miss events / other cores, and upgrade events. In every case
#             below except offchip they equal pte ptc upe: no other case lets an
#             exclusive holder drop its copy or a line leave the chip. An
#             expectation of 11 columns is read that way.
#   sre vord vbs  amendment 2 (2026-10-27): silent re-listings, summed over the
#             private caches; VIEW-ORDER VIOLATIONS (raw); the violating lines
#             explained by silent re-listing. 0 0 0 in every case but
#             silent_own; an expectation of 11 or 14 columns is read that way.
#   chk reg   self-check mismatches over the private caches; caches registered
#   also asserted: the stale-holder check reads 0, VIEW-ORDER VIOLATIONS
#   UNEXPLAINED reads 0, and the log prints the level asked for
#
# EXPECTED COUNTS, and why (R rounds, each on a fresh line X_j):
#
# order, R = 50: core p0 LOADs, p1 RMWs, p2 LOADs, p3 RMWs.
#   RMW p1: the protocol view lists {p0}           -> 1 event, 1 core
#           p0's private caches hold the line      -> 1 event, 1 core
#           the LLC mask is {p0}                   -> 1 event, 1 sharer
#   RMW p3: the view lists {p1, p2} (p1's RFO made it sole owner; p2 read)
#                                                  -> 1 event, 2 cores
#           p0, p1, p2 still hold it (nothing is invalidated) -> 1 event, 3 cores
#           the LLC mask is {p0, p1, p2}           -> 1 event, 3 sharers
#   per round: v1 2/4, presence 2/4, protocol 2/3; 2 RMW loads.
#   In the PRIVATE regime the cores share nothing: every counter 0, rmw unchanged.
#   LEVELS 1, 2: p1's RFO drops p0's two copies (L1D, L2C), so p3's RFO finds
#   only p1 and p2 present: presence 2/3. p3's RFO drops four more. 6 copies a
#   round. v1 and the protocol view are unchanged. No store hits a shared copy.
#
# pingpong, R = 50: A RMW, B RMW, A RMW, B RMW.
#   B's first RMW sees A: 1 event on each counter. A's and B's second RMWs hit
#   their own (stale) private copies and never reach the LLC: nothing.
#   per round: 1/1 on every counter; 4 RMW loads.
#   THAT WAS THE GAP (b3v2_canneal_barnes_2026-10-07.md, barnes), and level 0
#   still shows it. LEVELS 1, 2: each RFO drops the other core's two copies, so
#   the 3rd and 4th turns miss and reach the LLC too: 3/3 on every counter, 6
#   copies invalidated, per round.
#
# upgrade, R = 50: A LOAD, B LOAD, A RMW, B LOAD, A RMW.
#   No RFO ever reaches the LLC (A's RMWs hit its own copy): every LLC counter
#   0, 2 RMW loads a round. LEVEL 2: both of A's RMW loads find B listed -- 2
#   upgrade events, 2 cores -- and each drops B's two copies: 4 a round. B's
#   second LOAD therefore misses, which re-lists it for A's second RMW. The
#   store half of each RMW finds A alone and counts nothing.
#
# upgrade_l2, R = 50: A LOAD, B LOAD, A LOADs ten lines of X_j's L1D set, A RMW.
#   X_j is then in A's L2C only. LEVEL 2: the RMW's RFO misses the L1D, hits
#   the L2C and finds B listed: 1 upgrade event (1 core), 2 copies dropped, a
#   round -- and all of them counted in an L2C, which the check also asserts.
#
# storm, R = 50: all four cores RMW X_j at the same instruction.
#   Four RFOs reach the LLC together; each after the first finds the previous
#   one as sole owner: at least 3 protocol events a round at every level, and
#   exactly 3 at level 0, where every store half then hits. LEVELS 1, 2: three
#   of the four fills are stale on arrival and dropped, so those stores miss
#   and ask again; how those cross is cycle-level, so only bounds are asserted:
#   stale fills > 0, protocol events >= 3 a round, both checks 0.
#
# forward, R = 50: one core RMWs X_j twice, 4 instructions apart; cores take turns.
#   The first load misses and is issued; its instruction cannot retire, so its
#   store is still queued when the second load is dispatched, which is
#   forwarded. No line is touched by two cores: every sharing counter 0,
#   50 issued, 50 forwarded. In every OTHER case no RMW follows a store to its
#   address closely, so fwd is 0 and rmw is the trace's whole RMW count.
#
# wb_control, R = 4, two independent pairs of cores: A RMW ... B RMW.
#   1/1 on the directory counters and 2 RMW loads, per pair per round: 8s and
#   16. v1 is NOT asserted: it fires only if X_j is still in the LLC, and the
#   second pair's first read of its region pushes one X_j out (v1 read 7 of 8,
#   2026-10-11). That is v1's known flaw -- the reason the directory exists
#   (b3_ocean4_2026-10-05.md) -- not a new one.
#   LEVELS 1, 2: B's RFO drops A's two copies: 2 a round per pair, 16.
# sync_pingpong, R = 50 (2026-10-18, sync_replay_design_2026-10-18.md): the
#   pingpong turns with NO spacing, ordered only by sync records (each turn
#   waits for the previous turn's release). Hand counts as pingpong. Without
#   the records the turns race (50 / 106 protocol events at levels 0 / 2).
# sync_storepp, R = 50: sync_pingpong with plain STOREs. A store retires
#   before it reaches the L1D, so the turns hold only because a release
#   retires after its core's stores are performed (the fence). Hand counts as
#   pingpong, with no RMW loads.
# sync_barrier, R = 50: core W works 30,000 instructions and LOADs X_j; all
#   four meet at a barrier (sync records); core (j+1)%4 then RMWs X_j at
#   once. Its RFO finds W: 1/1 on every counter a round; at levels 1 and 2
#   W's two copies go, 100. Without the records the RMW runs ahead: 0.
# mx_handover, R = 50 (2026-10-19, sync_mutex_design_2026-10-19.md): A, B,
#   A, B turns on a mutex, recorded as alternating; B first runs 1 M
#   instructions alone. Timing order (the default): A takes all its turns,
#   then B -- one handover a round, B's first RMW finds A: 50/50, and at levels
#   1, 2 A's two copies go, 100. mx_handover_rec, the same traces in recorded
#   order: the alternation, as sync_pingpong.
# mx_excl, R = 50: four cores, 50 critical sections each on one mutex (RMW Y,
#   3,000 instructions, RMW Y). Under exclusion with a first-come queue every
#   section after the first finds Y at the previous holder, another core:
#   levels 1, 2: 199 events, 1 core each, 398 copies dropped; the LLC's own
#   mask keeps every core that touched Y (1 + 2 + 3 + 196 x 3 = 594). Level 0:
#   nothing is invalidated, so only each core's first section misses: 3
#   events; presence and the LLC mask see 1 + 2 + 3 = 6 cores.
# mx_cond, R = 50: a barrier of a mutex and a condition variable; the native
#   last arriver's lock is an ORDERED acquire. If it waits for the three
#   readers of Z_j, its RMW finds them: 1 event, 3 cores, a round; at levels
#   1, 2 their six copies go. Had it passed early: 0. mx_cond_rec: the same.
#   v1 is NOT asserted: the readers' misses can merge at the LLC, and the LLC's
#   own mask records only the miss's owner (v1 read 101 of 150; the event log
#   showed a LOAD merged into another core's miss 130 cycles earlier) -- v1's
#   known flaw, as in wb_control.
# Every mx log must print its mutex order and no release of a mutex not held;
# the older sync cases (no mutex addresses) must print no mutex line at all.
# offchip, R = 2, two pairs (2026-10-17; asserted since 2026-10-19, ~15 min a
#   run, so not in the default list): A LOADs X_j, then reads 4 MB cyclically,
#   so X_j leaves A's private caches and the LLC; then B RMWs X_j. B's RFO
#   misses the LLC (v1 0), finds no copy (presence 0), and the protocol view
#   still lists A (4/4); the gem5-rule view has forgotten A (0). offchip_control,
#   the same without the sweep: A still holds X_j: 4/4 everywhere, and at levels
#   1, 2 A's two copies go, 8. v1 is NOT asserted there: it read 3 of 4 on
#   2026-10-19, as in wb_control (the other pair's first pass over its region
#   can push an X_j out of the LLC, and v1 counts only RFOs that hit it).
# silent_own, R = 2, two pairs (2026-10-27, amendment 2 of
#   b3_g5rule_design_2026-10-19.md): A RMW X_j; ten L1D-set LOADs push the
#   dirty X_j into A's L2C; A LOADs X_j back into its L1D; a 2 MB sweep with a
#   LOAD of X_j every 32 lines keeps X_j in the L1D while the L2C writes it back
#   to the LLC (A leaves the protocol, bounded and gem5-rule views); A RMWs
#   X_j, an L1D hit. Round 0: B then RMWs X_j. Roles swap in round 1.
#   B's RFO finds A's L1D copy (presence 1/1), no core in the protocol view
#   (0/0): 2/2 and 0/0 over the pairs. RMW loads: 2 a round for A, 1 for B: 10.
#   LEVEL 2: A's L1D hit re-lists A in the gem5-rule view only (a silent
#   re-listing, 1 a round: 4), so B's RFO counts there (2/2), and round 1's
#   X_j is left re-listed at the end: raw violations 2, both explained.
#   LEVELS 1, 2: B's RFO drops A's L1D copy: 2. v1 is not asserted (wb_control).
# wb_evict,   R = 4, two pairs: A RMW, A sweeps 2 MB, B RMW.
#   The sweep pushes A's dirty X_j out of its L1D and L2C; the writeback
#   reaches the LLC and removes A from the protocol view, and A's presence
#   bits clear. B's RMW then finds nobody: presence 0/0, protocol 0/0, and at
#   least 2R LLC writebacks. v1 is not asserted: it depends on whether X_j
#   survives in the LLC, which the sweep also disturbs. Nothing is left to
#   invalidate at any level.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
S="$ROOT/simulator"
BIN="${BIN:-$S/bin/champsim}"
GEN="$ROOT/bench/policy_sanity/coherence_exact_traces.py"
ONLY="${ONLY:-order pingpong upgrade upgrade_l2 forward storm wb_control wb_evict silent_own sync_pingpong sync_barrier sync_storepp mx_handover mx_handover_rec mx_excl mx_cond mx_cond_rec}"
LEVELS="${LEVELS:-0 1 2}"
JOBS="${JOBS:-$(nproc)}"
[ -x "$BIN" ] || { echo "no binary at $BIN"; exit 2; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

# Expected "v1e v1s pre prc pte ptc rmw fwd upe upc inv [g5e g5c g5u [sre vord vbs]]" ('-' = not asserted).
# $1 case (order_private for the private regime)  $2 level
expected() {
  case "$1:$2" in
    order:0)                 echo "100 200 100 200 100 150 100 0 0 0 0" ;;
    order:[12])              echo "100 200 100 150 100 150 100 0 0 0 300" ;;
    order_private:*)         echo "0 0 0 0 0 0 100 0 0 0 0" ;;
    pingpong:0)              echo "50 50 50 50 50 50 200 0 0 0 0" ;;
    pingpong:[12])           echo "150 150 150 150 150 150 200 0 0 0 300" ;;
    upgrade:[01])            echo "0 0 0 0 0 0 100 0 0 0 0" ;;
    upgrade:2)               echo "0 0 0 0 0 0 100 0 100 100 200" ;;
    upgrade_l2:[01])         echo "0 0 0 0 0 0 50 0 0 0 0" ;;
    upgrade_l2:2)            echo "0 0 0 0 0 0 50 0 50 50 100" ;;
    forward:*)               echo "0 0 0 0 0 0 50 50 0 0 0" ;;
    wb_control:0)            echo "- - 8 8 8 8 16 0 0 0 0" ;;
    wb_control:[12])         echo "- - 8 8 8 8 16 0 0 0 16" ;;
    wb_evict:*)              echo "- - 0 0 0 0 16 0 0 0 0" ;;
    silent_own:0)            echo "- - 2 2 0 0 10 0 0 0 0 0 0 0 0 0 0" ;;
    silent_own:1)            echo "- - 2 2 0 0 10 0 0 0 2 0 0 0 0 0 0" ;;
    silent_own:2)            echo "- - 2 2 0 0 10 0 0 0 2 2 2 0 4 2 2" ;;
    sync_pingpong:0)         echo "50 50 50 50 50 50 200 0 0 0 0" ;;
    sync_pingpong:[12])      echo "150 150 150 150 150 150 200 0 0 0 300" ;;
    sync_storepp:0)          echo "50 50 50 50 50 50 0 0 0 0 0" ;;
    sync_storepp:[12])       echo "150 150 150 150 150 150 0 0 0 0 300" ;;
    sync_barrier:0)          echo "50 50 50 50 50 50 50 0 0 0 0" ;;
    sync_barrier:[12])       echo "50 50 50 50 50 50 50 0 0 0 100" ;;
    offchip:*)               echo "0 0 0 0 4 4 4 0 0 0 0 0 0 0" ;;
    offchip_control:0)       echo "- - 4 4 4 4 4 0 0 0 0 4 4 0" ;;
    offchip_control:[12])    echo "- - 4 4 4 4 4 0 0 0 8 4 4 0" ;;
    mx_handover:0)           echo "50 50 50 50 50 50 200 0 0 0 0" ;;
    mx_handover:[12])        echo "50 50 50 50 50 50 200 0 0 0 100" ;;
    mx_handover_rec:0)       echo "50 50 50 50 50 50 200 0 0 0 0" ;;
    mx_handover_rec:[12])    echo "150 150 150 150 150 150 200 0 0 0 300" ;;
    mx_excl:0)               echo "3 6 3 6 3 3 400 0 0 0 0" ;;
    mx_excl:[12])            echo "199 594 199 199 199 199 400 0 0 0 398" ;;
    mx_cond:0|mx_cond_rec:0) echo "- - 50 150 50 150 50 0 0 0 0" ;;
    mx_cond:[12]|mx_cond_rec:[12]) echo "- - 50 150 50 150 50 0 0 0 300" ;;
    *) echo "NONE" ;;
  esac
}

fail=0
# Sets: got (the 11 columns), chk reg viol lvl wb stf ul2 first -- or returns 1.
# $1 label  $2 log  $3 level
read_log() {
  local label="$1" log="$2" roi
  grep -q 'ChampSim completed all CPUs' "$log" || { echo "FAIL  $label: the run did not complete"; tail -3 "$log" | sed 's/^/        /'; return 1; }
  # A wrapped trace replays its start: the counts would no longer be the hand counts.
  [ "$(grep -c 'Reached end of trace' "$log")" = 0 ] || { echo "FAIL  $label: a trace WRAPPED -- lengthen its tail (coherence_exact_traces.py)"; return 1; }
  roi=$(awk '/^Region of Interest Statistics/ { r = 1 } r' "$log")
  got=$(echo "$roi" | awk '
    /^LLC COHERENCE RFO-HIT OTHER-SHARER EVENTS:/      { a = $NF }  /^LLC COHERENCE RFO-HIT OTHER SHARERS:/           { b = $NF }
    /^LLC COHERENCE DIR RFO PRESENCE-OTHER EVENTS:/    { c = $NF }  /^LLC COHERENCE DIR RFO PRESENCE-OTHER CORES:/    { d = $NF }
    /^LLC COHERENCE DIR RFO PROTOCOL-OTHER EVENTS:/    { e = $NF }  /^LLC COHERENCE DIR RFO PROTOCOL-OTHER CORES:/    { f = $NF }
    /^CPU [0-9]+ RMW LOADS ISSUED AS RFO:/             { g += $NF; n++ }
    /^CPU [0-9]+ RMW LOADS FORWARDED FROM THE STORE QUEUE:/ { h += $NF; m++ }
    /^cpu[0-9]+_(L1I|L1D|L2C) COHERENCE DIR UPGRADE EVENTS:/      { ue += $NF; k++ }
    /^cpu[0-9]+_(L1I|L1D|L2C) COHERENCE DIR UPGRADE OTHER CORES:/ { uc += $NF }
    /^cpu[0-9]+_(L1I|L1D|L2C) COHERENCE DIR COPIES INVALIDATED:/  { iv += $NF }
    /^LLC COHERENCE DIR RFO GEM5-RULE EVENTS:/                    { ge = $NF }  /^LLC COHERENCE DIR RFO GEM5-RULE CORES:/ { gc = $NF }
    /^cpu[0-9]+_(L1I|L1D|L2C) COHERENCE DIR UPGRADE GEM5-RULE EVENTS:/ { gu += $NF }
    /^cpu[0-9]+_(L1I|L1D|L2C) COHERENCE DIR GEM5-RULE SILENT RE-LISTINGS:/ { sr += $NF; q++ }
    /^LLC COHERENCE DIR VIEW-ORDER VIOLATIONS:/                   { vo = $NF }
    /^LLC COHERENCE DIR VIEW-ORDER LINES BY SILENT RE-LISTING:/   { vb = $NF }
    END { if (a == "" || c == "" || e == "" || ge == "" || vb == "" || !n || !m || !k || !q) print "MISSING"; else print a, b, c, d, e, f, g, h, ue, uc, iv, ge, gc, gu + 0, sr + 0, vo, vb }')
  [ "$got" != MISSING ] || { echo "FAIL  $label: a counter line is missing -- is this binary older than amendment 2 of the gem5-rule view (2026-10-27)?"; return 1; }
  chk=$(echo "$roi" | awk '/^cpu[0-9]+_(L1I|L1D|L2C) COHERENCE DIR SELF-CHECK MISMATCHES:/ { s += $NF; n++ } END { print (n ? s : "MISSING") }')
  reg=$(echo "$roi" | awk '/^LLC COHERENCE DIR PRIVATE CACHES REGISTERED:/ { print $NF }')
  viol=$(echo "$roi" | awk '/^LLC COHERENCE DIR STALE-HOLDER VIOLATIONS:/ { print $NF }')
  vord=$(echo "$roi" | awk '/^LLC COHERENCE DIR VIEW-ORDER VIOLATIONS:/ { print $NF }')
  vun=$(echo "$roi" | awk '/^LLC COHERENCE DIR VIEW-ORDER VIOLATIONS UNEXPLAINED:/ { print $NF }')
  stf=$(echo "$roi" | awk '/^cpu[0-9]+_(L1I|L1D|L2C) COHERENCE DIR STALE FILLS DROPPED:/ { s += $NF } END { print s + 0 }')
  ul2=$(echo "$roi" | awk '/^cpu[0-9]+_L2C COHERENCE DIR UPGRADE EVENTS:/ { s += $NF } END { print s + 0 }')
  wb=$(echo "$roi" | awk '/^cpu[0-9]+->LLC WRITE / { s += $4 } END { print s + 0 }')
  lvl=$(awk '/^PRIVATE-CACHE COHERENCE LEVEL:/ { print $NF }' "$log")
  # b3_rows.sh reads the FIRST block of these lines, the whole-simulation one;
  # it must equal the Region of Interest block.
  first=$(awk '/^LLC COHERENCE DIR RFO PROTOCOL-OTHER EVENTS:/ { print $NF; exit }' "$log")
  return 0
}
# What every run must satisfy, whatever its counts. Prints the reasons it does not.
common_ok() {   # $1 level
  local ok=1
  [ "$chk" = 0 ] || { ok=0; echo "        self-check mismatches: $chk"; }
  [ "$reg" = 12 ] || { ok=0; echo "        private caches registered: $reg, not 12"; }
  [ "$viol" = 0 ] || { ok=0; echo "        stale-holder violations: $viol"; }
  [ "$vun" = 0 ] || { ok=0; echo "        view-order violations unexplained: $vun"; }
  [ "$lvl" = "$1" ] || { ok=0; echo "        the log says level '$lvl', asked for $1"; }
  [ "$first" = "$(echo "$got" | cut -d' ' -f5)" ] || { ok=0; echo "        first-block protocol events $first differ from the ROI block"; }
  [ "$ok" = 1 ]
}

# $1 label  $2 log  $3 level  $4 expected columns  [$5 min LLC writebacks]
judge() {
  local label="$1" log="$2" level="$3" want="$4" minwb="${5:-}" got chk reg viol vord vun lvl wb stf ul2 first
  read_log "$label" "$log" "$level" || { fail=1; return; }
  # 11 columns: the gem5-rule view must equal the protocol view (pte ptc upe);
  # 14: no silent re-listing and no violation at all (sre vord vbs 0 0 0)
  # shellcheck disable=SC2086
  [ "$(echo $want | wc -w)" = 11 ] && want="$want $(echo $want | cut -d' ' -f5,6,9)"
  # shellcheck disable=SC2086
  [ "$(echo $want | wc -w)" = 14 ] && want="$want 0 0 0"
  local ok=1 i=1 w g
  for w in $want; do
    g=$(echo "$got" | cut -d' ' -f$i); i=$((i + 1))
    [ "$w" = - ] || [ "$w" = "$g" ] || ok=0
  done
  common_ok "$level" || ok=0
  [ -z "$minwb" ] || [ "$wb" -ge "$minwb" ] || ok=0
  # level 0 runs none of B3 v4: no stale fill may be dropped there
  [ "$level" != 0 ] || [ "$stf" = 0 ] || { ok=0; echo "        stale fills dropped at level 0: $stf"; }
  # upgrade_l2: every upgrade must have been seen in an L2C
  case "$label" in upgrade_l2*) [ "$ul2" = "$(echo "$got" | cut -d' ' -f9)" ] || { ok=0; echo "        upgrades seen in an L2C: $ul2"; } ;; esac
  # mutex order: the mode asked for, and no release of a mutex not held; older sync traces print none of it
  local mx; mx=$(grep '^SYNC MUTEX ORDER:' "$log")
  case "$label" in
    mx_*_rec*) echo "$mx" | grep -q '^SYNC MUTEX ORDER: recorded ' || { ok=0; echo "        mutex order line: '$mx', want recorded"; } ;;
    mx_*)      echo "$mx" | grep -q '^SYNC MUTEX ORDER: timing .*releases of a mutex not held 0)' || { ok=0; echo "        mutex order line: '$mx', want timing, 0 releases not held"; } ;;
    *)         [ -z "$mx" ] || { ok=0; echo "        a mutex line on traces without mutex records: '$mx'"; } ;;
  esac
  if [ "$ok" = 1 ]; then printf 'ok    %-22s %s   self-check %s, registered %s, stale-holders %s%s\n' "$label" "$got" "$chk" "$reg" "$viol" "${minwb:+, LLC writebacks $wb}"
  else printf 'FAIL  %-22s got  %s   self-check %s, registered %s, stale-holders %s, LLC writebacks %s\n      %-22s want %s%s\n' "$label" "$got" "$chk" "$reg" "$viol" "$wb" "" "$want" "${minwb:+   (LLC writebacks >= $minwb)}"; fail=1; fi
}

# storm: bounds and invariants only (see the header). $1 label  $2 log  $3 level
judge_storm() {
  local label="$1" log="$2" level="$3" got chk reg viol vord vun lvl wb stf ul2 first pte rmwfwd ok=1
  read_log "$label" "$log" "$level" || { fail=1; return; }
  pte=$(echo "$got" | cut -d' ' -f5); rmwfwd=$(echo "$got" | cut -d' ' -f7,8)
  common_ok "$level" || ok=0
  # as before amendment 2: no violation at all here, explained or not
  [ "$vord" = 0 ] || { ok=0; echo "        view-order violations: $vord"; }
  [ "$rmwfwd" = "200 0" ] || { ok=0; echo "        RMW loads issued, forwarded: $rmwfwd, not 200 0"; }
  [ "$(echo "$got" | cut -d' ' -f12)" -le "$pte" ] || { ok=0; echo "        gem5-rule events above the protocol view's"; }
  if [ "$level" = 0 ]; then
    [ "$pte" = 150 ] || { ok=0; echo "        protocol events $pte, not exactly 150"; }
    [ "$stf" = 0 ] || { ok=0; echo "        stale fills dropped at level 0: $stf"; }
  else
    [ "$pte" -ge 150 ] || { ok=0; echo "        protocol events $pte, below 150"; }
    [ "$stf" -gt 0 ] || { ok=0; echo "        no stale fill was dropped: the rule did not run"; }
  fi
  if [ "$ok" = 1 ]; then printf 'ok    %-22s protocol events %s, stale fills dropped %s   self-check %s, registered %s, stale-holders %s\n' "$label" "$pte" "$stf" "$chk" "$reg" "$viol"
  else printf 'FAIL  %-22s got  %s   stale fills %s\n' "$label" "$got" "$stf"; fail=1; fi
}

for L in $LEVELS; do
  case "$L" in 0|1|2) ;; *) echo "LEVELS: '$L' is not 0, 1 or 2"; exit 2 ;; esac
  "$S/scripts/make_config.py" --policy lru --cores 4 --regime shared  --private-coherence "$L" -o "$W/shared$L.json"  >/dev/null || exit 2
  "$S/scripts/make_config.py" --policy lru --cores 4 --regime private --private-coherence "$L" -o "$W/private$L.json" >/dev/null || exit 2
  "$S/scripts/make_config.py" --policy lru --cores 4 --regime shared  --private-coherence "$L" --sync-mutex-order recorded -o "$W/sharedrec$L.json" >/dev/null || exit 2
done
echo "binary: $BIN"
echo "columns: v1e v1s pre prc pte ptc rmw fwd upe upc inv g5e g5c g5u sre vord vbs"
pids=""
for c in $ONLY; do
  # a case ending _rec replays its base case's traces in recorded mutex order;
  # each case gets its own trace directory, so no run reads a file being rewritten
  g="${c%_rec}"; mkdir -p "$W/$c"
  n=$(python3 "$GEN" "$g" "$W/$c") || { echo "trace generation failed for $c"; exit 2; }
  for L in $LEVELS; do
    for rg in shared $( [ "$c" = order ] && echo private ); do
      cfg="$W/$rg$L.json"; [ "$g" = "$c" ] || cfg="$W/${rg}rec$L.json"
      while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do sleep 1; done
      "$BIN" --config "$cfg" --warmup-instructions 0 --simulation-instructions "$n" \
        "$W/$c/${g}0.champsimtrace" "$W/$c/${g}1.champsimtrace" "$W/$c/${g}2.champsimtrace" "$W/$c/${g}3.champsimtrace" > "$W/${c}_${rg}_$L.log" 2>&1 &
      pids="$pids $!"
    done
  done
done
wait $pids 2>/dev/null
for c in $ONLY; do
  for L in $LEVELS; do
    case "$c" in
      order)    judge "order, shared, L$L"  "$W/order_shared_$L.log"  "$L" "$(expected order "$L")"
                judge "order, private, L$L" "$W/order_private_$L.log" "$L" "$(expected order_private "$L")" ;;
      storm)    judge_storm "storm, L$L" "$W/storm_shared_$L.log" "$L" ;;
      wb_evict) judge "wb_evict, L$L" "$W/wb_evict_shared_$L.log" "$L" "$(expected wb_evict "$L")" 8 ;;
      *)        want=$(expected "$c" "$L"); [ "$want" != NONE ] || { echo "no expectation for case '$c'"; exit 2; }
                judge "$c, L$L" "$W/${c}_shared_$L.log" "$L" "$want" ;;
    esac
  done
done
if [ "$fail" = 0 ]; then echo "PASS: every counter matches its hand count, at level(s) $LEVELS."; else echo "FAILED."; [ -n "${KEEP:-}" ] && { trap - EXIT; echo "logs kept in $W"; }; exit 1; fi
