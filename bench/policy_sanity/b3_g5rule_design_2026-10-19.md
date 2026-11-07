# Step 3: gem5's measured rule, as a records-only view. Pre-registered 2026-10-19, before any code

Why: `micro_results_2026-10-18.md` measured how gem5's MESI_Three_Level
directory remembers a core. ChampSim's protocol view keeps every core it
ever listed (radix: R_b 42.96 on the held-out test). The bounded view
(forget a line's cores once it is held nowhere on chip) put radix in the band
(0.878), but broke ocean (0.091) on traces whose threads drifted apart.
Step 2, synchronised replay, addresses the drift: `sync_mutex_design_2026-10-19.md`,
running as `phaseA_b3_m2_*`. This step adds the rule gem5 was measured to
follow.

## The rule gem5 follows (measured, micro test, 2026-10-18)

- An **exclusive** holder (granted E on a read nobody else held, or M on a
  store) is forgotten when its private caches drop the line (priv_E: 0).
- **Shared** readers stay listed after dropping their copies silently, until
  the shared cache evicts the line (priv_S: 4). gem5's shared cache is
  inclusive, so that is when the line leaves the chip (offchip: 0).

## The view (sharer_directory.cc; records only, like the bounded view)

Per line: the cores listed, and whether the listing is exclusive.
- **A read reaching the LLC:** if no other core is listed, the reader alone,
  exclusive (gem5 grants E). Otherwise the reader is added, and the listing is
  shared.
- **A store miss (RFO) reaching the LLC:** the requester alone, exclusive.
  **A writeback:** the writer is removed.
- **An ownership hit at level 2** (a store or RFO hitting a private copy):
  the requester alone, exclusive.
- **A private eviction or invalidation** that leaves a core with no private
  copy forgets that core, if it is the exclusive holder (gem5's PUTX/PUTE).
- **The line held nowhere on chip** (no private copy, not in the LLC) forgets
  every core.
- A store's own update comes after the invalidations it causes, as in the
  bounded view.

It changes no simulated behaviour: it feeds only new counters.
- `COHERENCE DIR RFO GEM5-RULE EVENTS` / `CORES`: store misses at the LLC for
  which it lists another core.
- `COHERENCE DIR UPGRADE GEM5-RULE EVENTS` / `CORES`: the same for level-2
  upgrades.
- `COHERENCE DIR VIEW-ORDER VIOLATIONS`: lines where this view lists a core
  the bounded view does not, or the bounded view one the protocol view does
  not. Must be 0, since each view only forgets more than the one before.

The event log gains a 13th field, this view's other cores; its readers accept
12 or more.

**Not modelled, disclosed:** inclusion. ChampSim's LLC is non-inclusive. A
line that leaves the LLC but stays in a private cache keeps its holder present
and listed, where gem5's inclusive shared cache would have invalidated that
copy. So `llc_out` reads 4 here and 0-1 in gem5. This is a modelling choice,
stated with the other four.

## Qualifying checks

- **Q0:** every older log line is unchanged.
  - Locally: the new binary against the current one, on the exact suite's
    traces.
  - On the server: against `champsim_b3v4_69ebdcce` on traces without sync
    records, and against `champsim_syncmx_cc45d6f5` on the m2 traces
    (1 M + 2 M). In both, only the new GEM5-RULE lines are filtered out.
- **Q0-full:** the 12 runs of this step, on the m2 traces, print every line
  the 12 m2 runs print, apart from the new lines and the wall clock. The view
  changes no behaviour, so the whole simulation must repeat exactly.
- **Q1, exact:** `check_coherence_exact.sh` gains three columns (`g5e g5c
  g5u`).
  - In every existing case they equal the protocol view's (`pte ptc upe`). No
    case lets an exclusive holder drop its copy or a line leave the chip.
  - `offchip` and `offchip_control` (2 rounds x 2 pairs) join the asserted
    cases, at every level:
    - `offchip`: v1 `0 0`, presence `0 0`, protocol `4 4`, rmw 4, gem5-rule
      `0 0 0`; inv 0.
    - `offchip_control`: v1 `4 4`, presence `4 4`, protocol `4 4`, rmw 4,
      gem5-rule `4 4 0`; inv 0 at L0, 8 at L1/2.
- **Amendment, 2026-10-19, after the first local run; no expectation of the
  tested views changed:** `offchip_control`'s v1 read `3 3`, not `4 4`, at
  every level; presence, protocol, gem5-rule and invalidations were exact. v1
  (the LLC's own mask) counts only RFOs that hit the LLC. In `wb_control`, v1
  is not asserted, because the other pair's first pass over its region can
  push an X_j out of the LLC; this setup is the same. v1 is no longer asserted
  for `offchip_control`. The mechanism is the documented `wb_control` one; it
  was not separately confirmed for this case.
- **Q2, the micro test** (`-DBARRIER_STEPS`, `-sync 1`), with the view's
  X-line counts `G` (ownership events) and `GU` (upgrades), by hand:

  | case | L2 G | L2 GU | L0 G | L0 GU |
  |---|---|---|---|---|
  | pp_lock, pp_store, pp_rmw | 12 | 0 | 4 | 0 |
  | readers | 4 | 0 | 4 | 0 |
  | upgrade | 0 | 4 | 0 | 0 |
  | ctl | 4 | 0 | 4 | 0 |
  | **priv_E** | **0** | 0 | **0** | 0 |
  | priv_S | 4 | 0 | 4 | 0 |
  | llc_out | 4 | 0 | 4 | 0 |
  | offchip | 0 | 0 | 0 | 0 |

  Every other X-line column (P, A, U) is as before.
- **Q3:** VIEW-ORDER VIOLATIONS read 0 in every run, local and server.

## Acceptance against gem5 (the micro test, gem5's counts from 2026-10-18)

The view's L2 counts agree with gem5's within 1 in every case except
`llc_out` (inclusion, above):
- pp 12 against 11;
- readers 4 against 4;
- upgrade GU 4 against UPG 3 plus 1 GETX;
- ctl 4 against 3;
- priv_E 0 against 0;
- priv_S 4 against 4;
- offchip 0 against 0.

The protocol view misses this today on priv_E (4 against 0).

## Predictions (the 12 B3 configurations on the m2 traces, level 2)

R_g5 = the view's store misses that find another core, per KI, divided by
gem5's (SS + MT).L1_GETX per KI. The band is 0.5-2.

- **P5:** radix's R_g5 is in the band (protocol view 42.96 before the
  synchronised replay; bounded 0.878).
- **P6:** ocean's R_g5 is in the band at 2 MB and 8 MB.
- **P7:** the programs in the band today stay in it: canneal 4c and 8c,
  barnes std (force and start spans), barnes-256.
- Reported: water-nsquared, fmm, barnes std's window span, and U_g5 against
  gem5's upgrades. The m2 scoring of P1-P4
  (`sync_mutex_design_2026-10-19.md`) stands apart from this.

## How the outcomes are read

- **Q fails:** fixed before anything goes to the server.
- **The acceptance fails:** the rule as built is not gem5's. It is not used,
  and the reason is found.
- **P5-P7 hold:** proposed to the owner: **R_g5 becomes the primary B3
  measure of the final tool**, since it applies the rule gem5 was measured
  to follow, with R_b reported beside it. The owner decides before the paper
  uses either.
- **P5 holds, P6 fails:** forgetting is right, but ocean's lines are still
  lost in the replay where gem5 keeps them. That is a residency gap, examined
  before step 4.
- **P5 fails:** radix's over-count has another cause, examined.

Nothing is tuned after a number is seen.

## Local results (2026-10-19), before any server run

- **Q0:** 14 of 14 logs identical to the mutex-order build
  (`a255df9`/`003ebef`), apart from the new lines.
- **Q1:** 51 of 51 exact, levels 0-2, with g5e g5c g5u equal to the
  protocol view's in every existing case. `offchip` exact at every level:
  protocol 4, gem5-rule 0, presence 0. `offchip_control` exact apart from v1
  (amendment above).
- **Q2: every hand count met** (`simulator/results/micro_champsim_g5/summary.txt`;
  `-DBARRIER_STEPS`, `-sync 1`, the fixed tracer):

  | case | L2 G | L2 GU | L0 G | L0 GU |
  |---|---|---|---|---|
  | pp_lock, pp_store, pp_rmw | 12 | 0 | 4 | 0 |
  | readers | 4 | 0 | 4 | 0 |
  | upgrade | 0 | 4 | 0 | 0 |
  | ctl | 4 | 0 | 4 | 0 |
  | **priv_E** | **0** | 0 | **0** | 0 |
  | priv_S | 4 | 0 | 4 | 0 |
  | llc_out | 4 | 0 | 4 | 0 |
  | offchip | 0 | 0 | 0 | 0 |

  The P A U columns are identical to the previous Q2's, no trace wrapped, and
  VIEW-ORDER VIOLATIONS read 0 in every log.
- **Q3:** the order check reads 0 in every local run (exact suite, micro).
- **Acceptance against gem5: holds.** At L2 the view agrees with gem5's
  counts within 1 in every case but `llc_out` (inclusion, stated above):
  - pp 12 against 11;
  - readers 4 against 4;
  - upgrade GU 4 against UPG 3 plus 1 GETX;
  - ctl 4 against 3;
  - **priv_E 0 against 0**, where the protocol view reads 4;
  - priv_S 4 against 4;
  - offchip 0 against 0.
- The server path (`scripts/syncg5_all.sh`) was rehearsed end to end on a fake
  tree: Q0 8/8, Q0m 2/2, and Q0-full 2/2 identical to the m2 runs.

## Amendment 2, 2026-10-27, after the server's Q3 failed. Written before any code

**Seen** (`sync_mx_g5_results_2026-10-27.md`): VIEW-ORDER VIOLATIONS read 1-57
in 9 of the 12 g2 runs (0 in ocean 2 MB / 8 MB and water-nsquared). In every
run the view's event total stayed at or below the bounded view's. Q0-full held
(12 of 12 identical to m2), so the simulation itself is untouched.

**Suspected cause, from reading `sharer_directory.cc`:** an ownership hit at
level 2 that finds no other core (`dir_private_ownership_hit`, its first
branch) makes the requester the gem5-rule view's exclusive owner, and leaves
the protocol and bounded views as they are. Those two drop a core on its
writeback. ChampSim's private caches are not inclusive, so a core's L2C can
write a dirty line back while its L1D keeps a clean copy. A later store to that
copy then re-lists the core in the gem5-rule view only. Call this a **silent
re-listing**. gem5 lists a core that stores to a line it holds (micro test: the
store makes the line M), so the view is probably right, and the design's
reason for "must be 0" ("each view only forgets more") missed this path. The
state it starts from (an L1D copy after its L2C wrote the line back) cannot
arise in gem5's inclusive private hierarchy. That is the inclusion choice
already disclosed above.

**The fix changes no view's rule.** R_b, R_bounded, R_g5 and every upgrade
count stay exactly as scored; every existing log line stays byte-identical.
It adds records:
- per line, the cores the gem5-rule view lists only through a silent
  re-listing (cleared when the view reassigns the line or that core leaves it,
  and whenever the bounded view lists the core too);
- `<cache> COHERENCE DIR GEM5-RULE SILENT RE-LISTINGS` (per private cache, as
  the upgrade counters): ownership hits that re-list a core the bounded and
  gem5-rule views both left out;
- `COHERENCE DIR VIEW-ORDER LINES BY SILENT RE-LISTING`: violating lines whose
  every departure from the order is such a core;
- `COHERENCE DIR VIEW-ORDER VIOLATIONS UNEXPLAINED`: the rest. **Must be 0.**
  The existing VIEW-ORDER VIOLATIONS line stays the raw count:
  raw = by silent re-listing + unexplained.

**Q1, a new exact case, `silent_own`** (R = 2 rounds, two independent pairs
as in `wb_evict`). A of the pair does, on a fresh line X_j:
1. an RMW of X_j;
2. ten LOADs in X_j's L1D set, which push the dirty X_j into its L2C;
3. a LOAD of X_j, which refills the L1D from the L2C;
4. a 2 MB sweep with a LOAD of X_j every 32 lines: X_j stays in the L1D, and
   the L2C writes the dirty X_j back to the LLC;
5. an RMW of X_j, which hits the L1D.

In round 0 only, B then RMWs X_j. Roles swap in round 1. Hand counts, both
pairs together (v1 not asserted, as in `wb_evict`):

| level | pre prc | pte ptc | rmw fwd | upe upc | inv | g5e g5c g5u | silent | raw | by silent | unexplained |
|---|---|---|---|---|---|---|---|---|---|---|
| 0 | 2 2 | 0 0 | 10 0 | 0 0 | 0 | 0 0 0 | 0 | 0 | 0 | 0 |
| 1 | 2 2 | 0 0 | 10 0 | 0 0 | 2 | 0 0 0 | 0 | 0 | 0 | 0 |
| 2 | 2 2 | 0 0 | 10 0 | 0 0 | 2 | **2 2** 0 | **4** | **2** | **2** | 0 |

The reasoning:
- B's RFO finds A's L1D copy (presence 1/1) but no core in the protocol view,
  which dropped A at its writeback.
- At level 2, step 5 re-listed A, so the gem5-rule view counts B's RFO
  (1/1): one silent re-listing in each round.
- Round 1's line is left re-listed at the end: one raw violation per pair,
  explained.
- Steps 1 and 5 issue an RMW load each; B issues one: 5 a pair.

In every existing case the three new columns read 0.

**If `silent_own` misses a count,** the mechanism is not what is written
here: it is examined, and nothing goes to the server.

**Q0:** against `champsim_g5_034cd735` (on the laptop, the current
`bin/champsim`, md5 `245146bf`): every older line is identical on the exact
suite and on a real trace (barnes_4t, 5 M + 30 M, level 2). Only the three new
lines are new.

**Q3, amended:** UNEXPLAINED reads 0 in every run, local and server. The raw
count is reported, and must equal BY SILENT RE-LISTING.

**On the server:** the new build is checked against `champsim_g5_034cd735`
(Q0 / Q0m, only the new lines filtered). Then the 12 g2 configurations rerun
(`phaseA_b3_g3_*`), and **Q0-full** requires every line the g2 runs print,
apart from the new lines. Q3 must hold there: in each run raw = the server's
g2 count (1-57) = by silent re-listing, and unexplained 0. Step 4 and step 5
run on this build. **No B3 number changes.** P5-P7 stand as scored.

### Amendment 2: local results (2026-10-27), before any server run

- **Q1: 54 of 54 exact** at levels 0-2, on the new binary (`f2de49ad`).
  - **`silent_own` met every pre-registered count on its first run.** At level
    2: presence 2/2, protocol 0/0, gem5-rule 2/2, 4 silent re-listings, 2 raw
    violations, both explained. Levels 0 and 1 as tabled.
  - Every existing case reads 0 0 0 in the three new columns.
  - storm still reads 0 raw violations.
- **The mechanism is confirmed.** On these traces the gem5-rule view counts a
  store miss that the protocol view does not, because the protocol view
  dropped the writer at its L2C writeback while its L1D kept the line.
- **Q0, real trace** (barnes_4t, 5 M + 30 M, level 2): every older line is
  identical to the current binary's (`245146bf`). The old binary reads 3 raw
  violations; the new one splits them into 3 by silent re-listing and 0
  unexplained, with 11 silent re-listings.
- **Q0 on canneal 4c** (lru and hawkeye, shared and private, levels 0 and 2;
  1 M + 2 M): 8 of 8 identical apart from the new lines. This ran in the
  rehearsal below, against the g5 binary as reference.
- **Deviation from the text above:** the exact suite was checked by its hand
  counts, not line by line against the old binary. The line-by-line Q0 ran on
  canneal (8 configurations) and barnes.
- **The server path was rehearsed** on a fake tree (`VARIANT=g6`), with the real
  build, Pin and binaries. Steps:
  - build, the three guards and QS pass;
  - Q0 holds, 8 of 8, against the g5 binary;
  - a malformed program list stopped the build at Q0m, and nothing was
    launched;
  - Q0m holds on its own (1 of 1);
  - the chain runs one job, then Q0-full and Q3.

  Q0-full flagged the stand-in g2 run, which named its traces by relative paths
  (its only differing lines). On the server both runs name them by the same
  absolute paths. Q3 printed raw / by silent / unexplained and held.
