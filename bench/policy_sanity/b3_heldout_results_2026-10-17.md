# B3 on held-out programs and at 8 cores: scored (2026-10-17)

Scored against `b3_heldout_design_2026-10-14.md` (with its amendments, all
made before any server run) and `b3_canneal8_design_2026-10-14.md`. Rows:
`phasea_rows_v19.txt`, `b3_rows_v10.txt`, `gem5_b3_rows_v3.txt`,
`gem5_mix_v3.txt`, `trace_mix_v3.txt`. Every number from `b3_score.py score
... h0@held h1@held h2@held e0@e8 e1@e8 e2@e8` and `b3_stream_check.py check`.

## Summary

| program | same stream (QS) | gem5 events in the window | R_b at level 2 | verdict |
|---|---|---|---|---|
| **canneal, 8 cores** | yes (0.1%) | 260,815 | **1.721** | **P1 holds**; traffic 1.01 |
| **radix** (held out) | yes, exactly (0.000-0.001) | 36,869 | **42.96** | **P1 FAILS**: 43× too many; traffic 0.99 |
| **water-nsquared** (held out) | yes | 414 | 1.924 | **not discriminating** (fewer than 500 events); its upgrades agree, **U = 0.953** (P3 holds) |
| **fmm** (held out) | **no**: stores 1.32×, read-modify-writes 1.37× | (9,953) | (1.409) | **not scored**, as pre-registered |

So the held-out test does not support "the tool generalizes": on the one
held-out program that could be scored on the primary measure, the tool is
43× off.

## Qualifying checks

- **QB** held on the server for all three (radix 12 functions, water-nsquared
  16, fmm 93, dynamic against static).
- **QT** held: offsets radix (skipped 780 M, as amended), water-nsquared
  12,952,793, fmm 12,773,531 records; residual 0 in each.
- **QG** held for all eight new gem5 runs: each ended at its stop; the config
  shows the right static binary, a 2 MB L2, every L0-L1 buffer unordered,
  randomization off, and the per-CPU stop on the workers only (cpu 1-3; cpu
  1-8 for canneal at 8).
- **Q1** held: in the private regime the level-1 and level-2 rows equal level
  0's in every column (radix, water-nsquared, fmm, canneal 8c).
- **Q2** held: every run complete, self-check 0, registered 12 (24 at 8
  cores), stale-holders 0, levels printed.
- **Q3 (canneal 8c):** the level-2 shared row equals the A5 rerun's
  `phaseA_l2_fixed` LRU canneal 8c row in every column.
- **QS:** radix, water-nsquared and canneal 8c are the same stream; **fmm is
  not** (below).

## radix fails, and what the two views say

| radix, level 2, window | ChampSim | gem5 |
|---|---|---|
| store misses reaching the shared cache | 3,161,274 | 3,325,661 GETX |
| ... that find another core, protocol view | **1,609,213** | 36,869 |
| ... that find another core still **holding a copy** (presence view) | **32,824** | |
| shared-cache demand accesses per 1,000 instructions | 21.61 | 21.85 |

The traffic and the store misses match gem5's (0.99, 0.94). What does not is
which of those misses find another core listed: the protocol view lists 49×
more cores than actually hold the line. The presence view, the cores whose
private caches hold it, gives **R_a = 0.876**, inside the band.

**A hypothesis, not yet tested:** ChampSim's protocol view keeps a core
listed after it silently drops a clean copy, with no limit on how long
(the directory was made independent of the LLC on 2026-10-05, because the
non-inclusive LLC forgot sharers that ocean's cores still held). gem5's
sharer list lives in its inclusive 2 MB L2 and is gone when the L2 evicts the
line. radix sorts 16 M keys, far more than 2 MB, so between its passes a line
leaves gem5's L2 and its readers are forgotten; ChampSim remembers every
reader of every line. ocean is the opposite case: its shared lines stay on
chip, and there the presence view undercounts (R_a 0.08) while the protocol
view agrees (0.99).

**How to test it** (a stats-only counter, no behaviour change): count the
protocol-view events whose line is held nowhere on chip -- a miss in the LLC
and no private copy anywhere. If that accounts for nearly all of radix's
excess and little of ocean's, a step 4 -- keep a line's protocol entry only
while the line is on chip -- is the candidate fix. It would need its own
pre-registration, a rescore of every program, and **new held-out programs**:
radix could no longer count as held out for the revised tool.

## water-nsquared: no store-miss sharing to score, but its upgrades agree

gem5 counts 414 store misses that find another core in the window, under the
500 the design set, so P1 is not decided. Its sharing is upgrades: gem5
17,774, ChampSim at level 2 18,170 (**U = 0.953**); at levels 0 and 1, 0.
Hand-overs 0.976. Traffic 0.60 (P2 holds, narrowly). This is the first
held-out evidence for step 3's upgrade, scored where the design said it
would be.

## fmm: not the same stream, so not scored

gem5 executes 32% more stores and 37% more read-modify-writes per 1,000
instructions than the traces in the window; loads 6.5% more. By the design,
nothing is scored for fmm until that is explained. **A likely reason, not
established:** fmm's threads run unevenly under gem5. At the 50 M stop
workers 1 and 2 are at 36.4 M and 36.0 M while worker 3 is at 50 M; over the
window they run 102.0, 95.6 and 100 M. Each trace's window is its own
50-150 M, so the two simulators cover different phases of threads 1 and 2,
and fmm's phases differ in their mix. (Its numbers -- R_b 1.41, U 1.16 --
are not results.)

## canneal at 8 cores agrees

R_b 1.721 (levels 0 and 1: 1.632, 1.721), inside the band but higher than at
4 cores (1.263). Traffic 1.01, store misses 0.99. Upgrades are not scored
(gem5 1,788). The presence view reads 1.54. Whether the rise from 4 to 8
cores is the same stale-reader effect as radix's, smaller, is open; the
counter above would show it.

## What this changes

- **The validation claim narrows.** At level 2 the tool agrees with gem5 on
  ocean, canneal (4 and 8 cores) and barnes, and on water-nsquared's
  upgrades. On radix, a held-out program with a footprint far beyond the
  cache, its protocol view over-counts sharing 43×. The paper reports this as
  measured.
- **The policy results** (A5, A6, C0) were run on the same level-2 tool; on
  canneal, their workload, R_b is in the band at 4 and 8 cores. If a step 4
  is made, its pre-registration must include a check of whether it changes
  their timing.
- **Next decision (the owner's):** test the hypothesis with the stats-only
  counter, and if it holds, pre-register step 4 with fresh held-out programs.
