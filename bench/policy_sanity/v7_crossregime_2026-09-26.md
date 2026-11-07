# V7 — the cross-regime sweep, re-verified

**2026-09-26.** Raw rows: `phasea_rows_v6.txt` (210 rows, every `phaseA*` tree),
pulled after the sweep's `QUEUE COMPLETE` (2026-09-25 15:10 UTC). Scope: the
`phaseA` canneal rows at 4/8/16 cores in both regimes, fixed 2 MB LLC — 54 rows:
8 baselines × 6 configurations plus the pre-fix COALESCE family at 8 cores (its
4c/16c jobs were cancelled; `coalesce_ghost_defect_2026-09-23.md`, amendment).

## Checks — all pass

| check | result |
|---|---|
| every row `complete`, no page-pool exhaustion, no wrapped trace | 54 / 54 |
| `TOTAL == LOAD + WRITE + RFO + TRANSLATION`, accesses and hits | every row |
| instructions per core ≥ 100 M | 100,132,663 .. 102,768,215 |
| `min_cycles == max_cycles` (the phase ends globally) | every row |
| private: invalidations **and** aliased fills exactly 0 | every policy, every core count |
| shared: both non-zero | every policy |
| shared invalidations rise 4c < 8c < 16c | every baseline |
| no two policies share `max_cycles` in a configuration | none do |

Independent cross-check: LRU's full-length shared invalidations, 0.16 / 0.33 /
0.73 M at 4/8/16 cores, are 10.0× the 2026-09-18 quick pass (15,757 / 32,369 /
73,351) run at a tenth of the length.

## Provenance — two builds, one configuration

The 2026-09-23 queue skipped jobs already complete from the 2026-09-18 sweep, so
**the 8-core shared column and every LRU row ran on the 2026-09-17 build**; all
other rows on the 2026-09-20 build (`bin/champsim_phaseA_20260923`).

- **Configurations are identical.** `make_config.py` output is byte-identical
  for all six core/regime combinations at `ca2b44e`, `c73e1dd` and HEAD, and the
  configs each job actually used (`~/.phase_a/cfg_*.json`, written at launch)
  show a 16 GiB page pool at 8 and 16 cores and 4 GiB at 4 cores, in every job
  of both builds.
- **Binary differences between the builds:** `b985b9c` fills the sharer
  histogram (a statistic only); `eddcb19` bounds-checks indexing in the
  rewritten policies (Hawkeye, Mockingjay, srrip_bias, the COALESCE family);
  `0cf55c4` instruments COALESCE. The upstream policies (LRU, SRRIP, DRRIP,
  SHiP, random) are unchanged between the builds.
- **Residual:** Hawkeye, Mockingjay and srrip_bias at 8c shared ran without the
  bounds checks, and Mockingjay is known to index out of bounds on some inputs
  (`indexing_audit_2026-09-19.md`). Against it: every run of those policies on
  canneal under the bounds-checked build completed. **Closing it: re-run the
  8c-shared rows on the 2026-09-20 build** (`v7equiv`) — identical cycles prove
  the builds equivalent there and check determinism in the same step.

**Correction to a claim made during this check.** I said the page-pool fix
landed five hours after the 2026-09-18 sweep launched. Commit times are IST,
server times UTC: `ca2b44e` at 10:34 IST is 05:04 UTC, 40 minutes *before* the
05:44 UTC launch — consistent with every config showing 16 GiB.

## The result, and why it cannot be quoted yet

Kendall τ between the private and shared rankings of the 8 baselines: **+0.86 /
+0.71 / +0.64** at 4 / 8 / 16 cores. Privately Mockingjay leads at every core
count; shared, SRRIP leads at 8c (tied with Mockingjay to 0.001 pp) and 16c,
where SRRIP +14.67% and srrip_bias +14.44% beat Mockingjay +12.19% and Hawkeye
+11.34% over LRU.

**Confounded by cache pressure.** At a fixed 2 MB the private regime thrashes:
LRU's LLC load hit rate is 1.69% / 0.64% / 0.34% at 4/8/16c, against 23.65% /
23.95% / 24.80% shared — aliasing shrinks the shared working set. So the two
regimes differ in pressure as well as sharing, and at 8c/16c the private order
rests on gaps of 0.01–0.02 pp inside a 2–3 pp spread. This cannot yet be read as
"sharing reorders policies".

> **Corrected 2026-09-28 — the next paragraph is wrong** (`v7_relaunch_2026-09-28.md`,
> "Correction"). It mixes metrics: the confound above is in LLC **load** hit
> rate, while `llc_sizing`'s ~50% is the **total** rate, which writebacks
> inflate. On loads the scaled geometry leaves private at 26% and shared at
> 68 / 87 / 98%, so it **widens** the pressure gap. What matches in pressure is
> fixed-2 MB shared (23.7–24.8%) against scaled private (26.1–26.4%). The
> scaled-private jobs are kept, for that pairing.

**The experiment that separates them:** the scaled geometry (2 MB per core),
where the private hit rate stays near 50% (`llc_sizing_2026-09-19.md`), in
**both** regimes. `phaseA_scaled` has shared rows for every policy but private
rows for LRU only. Missing: 7 baselines × canneal 4/8/16c + barnes 4c, private,
scaled — 28 jobs.

## Open V7 items for this sweep

- [x] `v7equiv` — 4 jobs, canneal 8c shared on the 2026-09-20 build: SRRIP
      (unchanged code) and the three bounds-checked policies. **Identical in
      all 15 columns** (2026-09-28, `v7_relaunch_2026-09-28.md`).
- [ ] the scaled-private baselines, before any cross-regime ranking is quoted
      (running; resumed 2026-09-28 after a reboot killed them).
