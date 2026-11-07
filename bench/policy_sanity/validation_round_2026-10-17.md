# The full validation round (2026-10-17)

At the owner's request ("we have to do a full round validation of everything
we have done"), every layer re-checked by something other than the code that
produced it. The last such pass was `verification_2026-10-11.md`; this one
covers everything since (steps 2-3, the barnes rework, A5's size control, A6,
C0, held-out B3, the bounded-view diagnosis) and re-derives the older results
the claims still rest on.

Status: **complete (2026-10-18).** **No defect found in the simulator, the
runs, the inputs or the analysis.** The micro test validates the B3 metric
directly and measures gem5's rule for remembering a core
(`micro_results_2026-10-18.md`). The radix diagnosis is scored separately
(`b3_bounded_results_2026-10-18.md`: P1 holds, P2 fails).

## Layers and what checks them

| layer | question | checked by | status |
|---|---|---|---|
| 1 inputs | is every trace the program, thread and length we say? | `audit_server.sh traces` + `trace_mix.c` (a C counter, independent of `count_rmw.py`) | **done: all hold** |
| 2 runs | did every run get the settings its tree name says? | `verify_inputs.py` over every server run.log; `verify_sources.py` (every source that ran is a committed version) | **done: all hold** |
| 3 simulator | is the coherence code right? | line-by-line review; new hand-counted tests for the bounded view and C0 | **done: no defect** |
| 4 reference | do gem5 and ChampSim count the same event? | `coherence_micro.c`, known answers, both simulators (`micro_design_2026-10-17.md`) | **done: they do** (`micro_results_2026-10-18.md`) |
| 5 analysis | do the numbers follow from the data? | `verify_rankings.py`, `verify_numbers.py`: fresh code, raw columns and raw logs | **done: all reproduce** |
| 6 claims | does every stated number trace to data? | deck, speech, docs against the recomputed values | **done** (two stale statements) |

## Layers 1 and 2: inputs and runs (the server audit) -- all hold

The audit (`scripts/audit_all.sh`, collected 2026-10-17 11:59 server time):
884 run logs, 83 binaries, 30 gem5 runs, every source tree, 64 traces counted.

- **Every source file that built a binary in use is a committed version**
  (`verify_sources.py`): the main tree is the b3v4 sources (newest file
  `f4266a7`, 2026-10-11), `~/c0_build` is `e620494`, `~/diag_build` is
  `e082655`; only the generated `absolute.options` is not in git. Every
  runner script in `~` that produced a current result is a committed
  version. The frozen binaries named after their md5 (`champsim_b3v4_69ebdcce`,
  `champsim_c0_6098e804`, `champsim_diag_e583dac3`) carry it correctly.
- **Every run used the settings its tree name says** (`verify_inputs.py`):
  lengths, core count, LLC sets, coherence level, latency, regime, the
  binary's fingerprint, per-CPU traces, self-checks. What it flagged, all
  explained: runs still going when the snapshot was taken (the 12 diagnosis
  runs, 8 of A6's 32 MB runs -- all complete at the 2026-10-18 pull); the 4
  known-incomplete ocean 8-core COALESCE rows of 09-23 (unused); barnes at
  8 MB reading identical for all 11 policies (known: no LLC miss there;
  unused); and three gaps in the checker itself (the aligned barnes trace
  names, the v1 ocean tree's scaled geometry, and missing files counted as
  duplicates).
- **Traces the older logs name are gone from disk** (632 + 480 + ... log
  lines; the 2026-09 sweeps): they were compressed to `.xz` on 2026-10-06.
  Their private LRU rows equal the b3v4 reruns on the compressed traces to
  the cycle (layer 5), so the content is the same.
- **64 traces counted by the C counter:** no two hold the same content
  (content hash), none ends in a partial record, every one is long enough
  for its window (aligned thread-0 traces 187-189 M records, the rest
  200 M or more). **40 of 40 instruction-mix windows the stream checks used
  equal the C counter's exactly** (canneal 4/8, barnes, barnes std spans,
  ocean, radix, water-nsquared, fmm). The only window not re-counted is
  barnes std's start span for thread 0, which came from the unaligned
  trace. ocean's threads 1-3 are now counted: they match thread 0
  (65.1 stores per 1,000 instructions each).

## Layer 3: the simulator -- no defect found

Read line by line: `sharer_directory.{h,cc}`, every directory hook in
`cache.cc` (fill, hit, miss, write, invalidate, the upgrade, the stale-fill
rule, C0's wait, the bounded view's LLC residency), `vmem.cc` (the overlay),
the config parsing, `make_config.py`.

- The directory's invariants hold by construction: the bounded view stays a
  subset of the protocol view; an entry cannot be erased during its own
  invalidations (the protocol view is set to the taker first); stale marks are
  cleared only by the core's own next accepted request.
- Two suspicions, both standard ChampSim and not defects: a store that misses
  the L1D fetches the line (first-level caches compare full addresses, so
  writes there go through `handle_miss`, as an RFO below); copies invalidated
  are counted in each private cache, not at the LLC (a level-2 run prints 0
  on the LLC's line and the per-cache counts sum to the presence events).
- **New hand-counted tests, all exact** (laptop, `bin/champsim` at `e082655`):
  - the bounded view, `offchip` (A reads X, A sweeps 4 MB so X is held
    nowhere, B RMWs X; 2 pairs x 2 rounds): protocol 4, presence 0,
    **bounded 0**; `offchip_control` (no sweep): 4 / 4 / **4**, and 8 private
    copies invalidated at level 2. Levels 0 and 2.
    (`coherence_exact_traces.py` cases `offchip`, `offchip_control`; 15 min a run.)
  - C0 at 50 cycles, level 2: waits = order 100 (all at the LLC), pingpong
    150 (LLC), upgrade 100 (L1D), upgrade_l2 50 (L2C), the hand counts, and
    every other counter equal to the latency-0 run. The latency is applied:
    on pingpong the two active cores' L1D miss latency rises 70 -> 105
    cycles (3 of 4 accesses wait 50); total cycles do not move, because a
    70-cycle load hides in the 352-entry window. Consistent with C0 being a
    lower bound.
- **Determinism:** the same configuration run twice (hawkeye, canneal 4c,
  level 2, 1 M + 2 M) prints identical logs, 1,699 lines, wall-clock times
  aside.

### Modelling choices a reviewer will see, not stated anywhere yet

1. **The shared cache has 16 MSHRs at every core count** (`make_config.py`,
   from the historical btp configs); upstream's default is 64 for one core.
   The L1D has 8 MSHRs and 8 ways (upstream 16, 12), the L2C 16 MSHRs
   (upstream 32). At 16 cores, 16 MSHRs for the whole shared cache caps
   memory-level parallelism hard. Same for every policy, but it amplifies
   miss-heavy ones. State it in the methodology table; a sensitivity run at
   64 would answer the question.
2. **Each core keeps its own page table in the shared regime**
   (`vmem.cc get_pte_pa` keys on `cpu_num`). Threads of one process share one.
   Only translation traffic is affected.
3. **The shared cache's own MESI state and sharer mask** (what COALESCE and
   srrip_bias read) treat a writeback hit as a store (the writer becomes sole
   owner, MODIFIED) and an RFO hit as a read (the requester joins the
   sharers). Known as "the older rules"; the paper must say exactly this.
4. **Plain read-modify-writes: possibly filed differently.** The trace cannot
   tell `lock add` from `add`, so step 1 issues every RMW's load as an RFO. I
   first wrote that gem5 issues a plain one as a load (GETS, then an upgrade);
   on reflection its Ruby sequencer probably hands such a load (x86 StoreCheck)
   to the protocol as a store, as ChampSim does. Not settled from memory: the
   micro test measures it (pp_rmw) and `micro_server.sh` prints gem5's
   sequencer source. **Read on the server, 2026-10-17:** `Sequencer.cc`
   lines 1046-1047 make a StoreCheck load `primary_type = RMW_Read`,
   `secondary_type = ST`, and `issueRequest` hands the protocol the
   secondary type. So gem5 also issues a plain RMW's load as a store: the
   two simulators file it the same way. **Not a difference; closed.**
   (pp_rmw should read like pp_store.)

## Layer 5: the analysis -- every number reproduces

**From the raw logs (the audit):** 665 of 679 phasea rows equal their raw
logs in every column; the 14 others were runs still going when the logs were
copied, complete in the newer rows. Every R_b, R_a and U of the 21 B3
comparisons, recomputed from the raw logs, equals the stated value; traffic
too, by the documents' definition (all accesses but writebacks against gem5's
`m_demand_accesses`). The 12 diagnosis reruns equal the original level-2 rows
in every column.

**From the rows:**

`scripts/verify_rankings.py bench/policy_sanity/phasea_rows_v19.txt`, written
for this round (brute-force Kendall tau over all pairs, its own row reader):

- **33 of 33 Kendall tau values** the documents state reproduce (A5 in all
  its comparisons and levels, C0, the 16-core repeat); the two still marked
  "pending" in `a5_size_control_2026-10-14.md` now read +0.571 (4c) and
  +0.714 (8c) for shared 2 MB against shared 2 MB per core at level 2.
- **22 of 22 gains over LRU** reproduce, every one as speedup
  (LRU cycles / policy cycles - 1), none as cycles saved.
- **C0:** LRU +1.09% / +2.01% at 100 cycles and ocean's -0.19% at 50
  reproduce.
- **11 of 11 rows that must be identical are**, in cycles, instructions and
  traffic: the private LRU rows on the 2026-09-23 binary against b3v4 (2 MB
  and 2 MB per core, 4/8/16 cores) -- which is what lets A5 mix rows from
  three binaries; A6's Q0 rows; B3 canneal 8c against the A5 rerun.

`scripts/verify_numbers.py` (gem5 side, from `simulator/results/gem5_b3`):
every gem5 window count the documents quote reproduces -- 27,649 / 26,451
(ocean), 89,307 / 98,861 (canneal), 708 / 123,076 / 44,867 (barnes spans),
295,420 (barnes256), 260,815 (canneal 8c), 36,869 (radix), 414 (water-nsquared),
9,953 (fmm), and the upgrades 41,899 / 67,195 / 5,901 / 154,740 / 61,777 /
433,760 / 17,774.
- **Noted:** in water-nsquared's gem5 window the threads ran 93.4 / 91.9 /
  100.0 / 91.9 M instructions, not 100 M each -- the uneven-thread effect
  that disqualified fmm (108 / 102 / 96 / 100), smaller. Its stream check
  passed; disclose it beside fmm's.

## Layer 6: the claims

- Deck (`latex/latex2/mid_term.tex`) slide "Agreement with the Reference":
  every number traces to a document (Before: 0.045, 0.460 v1; 0 v2; 0.082 /
  0.401 level 0. Now: 0.986, 1.125, 1.263, 1.142, 0.761, 0.689).
  **Stale since 2026-10-17:** it says "all six cases sit inside the pass
  range, on three standard programs" -- true, but radix, held out, is 43x
  off. If the deck is shown again it must say so.
- Speech: "Why only 4 cores and three programs?" -- stale: canneal at 8 cores
  and three held-out programs have been run.

## Test-design errors caught on the way (not results)

- The micro test's first version used a 256 KB wait ring; its speed depended
  on where pages landed, threads drifted 1.7x apart and steps overtook each
  other (12 of 24 hand-overs counted). The event log showed it; the program
  was redesigned (small hierarchy, ring always in the private L2) before any
  gem5 run.
