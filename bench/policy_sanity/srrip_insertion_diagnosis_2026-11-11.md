# The ocean SRRIP anomaly: upstream ChampSim's SRRIP inserts at the eviction value. Diagnosis, 2026-11-11

**The anomaly** (step 5, `policy_results_2026-11-10.md`): on ocean at 4 cores
and 2 MB a core, SRRIP and srrip_bias take 48-51% more cycles than LRU. It
was already +23% on the drifting traces. No other workload shows it.

**The cause, in the code** (found 2026-11-10; `replacement/srrip/srrip.cc`,
upstream's file):
- a set's RRPVs start at `maxRRPV` (3);
- `victim()` takes the first way holding the largest RRPV and ages the whole
  set so that way sits at 3;
- `update(way, hit)` writes 0 on a hit and `maxRRPV - 1` (2) otherwise, but
  `update_replacement_state` calls it **only on a hit**, and
  `replacement_cache_fill` is **empty**.

So the published insertion (RRPV 2, "long re-reference interval") never
runs. **Every filled line keeps the victim's value, 3**, the value the next
victim search looks for. The file is identical in upstream `f9ed890e` and in
upstream's current `develop`; upstream's unit test calls `update()` itself,
so it passes. `docs/policy_audit.md` recorded the insertion value on
2026-09-16 ("disclose, do not fix"); what was not known is how much it
costs on a workload of ours.

## The probe

A scratch build, never used for a result: main's simulator at `a53391d` with
one change in `replacement/srrip/srrip.h`. The fill hook counts the RRPV each
filled line is left with; with the environment variable `SRRIP_PROBE_FIX=1`
it first calls `update(way, false)`, the published insertion. Binary md5
`82b3c07f`. The tree was restored after the build.

**Does every fill stay at 3?** Yes, on three workloads:

| run | fills left at RRPV 3 (upstream) | at RRPV 2 (with the published insertion) |
|---|---|---|
| 429.mcf, 1 core, 5 M + 20 M | 848,467 of 848,467 | 693,521 of 693,521 |
| canneal 4c shared, 1 M + 2 M | 58,240 of 58,240 | 62,507 of 62,507 |
| ocean 4c shared, 8 MB, 20 M + 50 M | 6,076,083 of 6,076,083 | 919,113 of 919,113 |

**What it costs on ocean** (the step 5 configuration: 4 cores, shared, level
2, 8 MB LLC, the `sync_mx/ocean4` traces; 20 M + 50 M a core; the measured
phase):

| policy | cycles | against LRU | LLC misses (of accesses) | load misses | RFO misses | writeback misses |
|---|---|---|---|---|---|---|
| LRU | 67,712,828 | | 472,562 (7.47%) | 121,104 | 349,728 | 806 |
| DRRIP | 67,347,222 | -0.54% | 546,121 (8.62%) | 129,856 | 345,856 | 69,478 |
| **SRRIP, upstream** | **149,289,141** | **+120.47%** | **3,981,860 (63.05%)** | 2,496,468 | 421,732 | 1,062,705 |
| SRRIP, published insertion | 67,721,274 | +0.01% | 596,530 (9.38%) | 152,092 | 347,320 | 96,174 |

One change, the insertion value, takes SRRIP on ocean from 2.2 times LRU's
cycles to LRU's. **The anomaly is upstream's insertion value.**

**It is not simply "worse".** On 429.mcf (1 core, 5 M + 20 M) the order is
the other way round:

| policy | cycles |
|---|---|
| LRU | 82,002,688 |
| SRRIP, upstream (RRPV 3) | 74,449,278 |
| SRRIP, published insertion (RRPV 2) | 82,901,558 |

Inserting at the eviction value makes a new line the next victim unless it is
hit first. That protects lines already reused from lines that never will be
(mcf), and it throws away lines whose first reuse comes late (ocean's sweeps
over its grids). This reading fits the two tables; it was not tested
further. canneal's short run moves by about 1% either way.

## What follows

- **The step 5 rows stand as measured.** They are rows of ChampSim's SRRIP.
  The ocean anomaly gets its cause in one sentence, with this note.
- **`srrip_bias`** is built on the same set helper and shows the same
  anomaly in step 5; it was not probed.
- **The baseline of record stays upstream's SRRIP** (the audit's rule: it is
  what the field publishes against). Wherever the paper names SRRIP it says
  "as ChampSim ships it, which inserts at RRPV 3".
- **A second row, SRRIP with the published insertion,** would be a new
  module and new runs. That is the owner's decision and needs its own
  pre-registration; nothing is run for it now.
- **Reporting it to ChampSim** (an issue with this table) is the owner's
  call, after the submission.

Not shown here: the 50 M + 100 M window of step 5 itself (the probe ran
20 M + 50 M, where the excess is larger: +120% against step 5's +48%); any
core count but 4; any LLC size but 8 MB.
