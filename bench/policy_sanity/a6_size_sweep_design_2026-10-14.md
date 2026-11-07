# A6, the LLC-size sweep: does sharing reorder the policies beyond size and pressure? Pre-registered

**2026-10-14.** Written and committed **before** any run of it exists.

## Why

`a5_size_control_2026-10-14.md`: on canneal, changing only the LLC size
inside the private regime reorders the 8 baselines as much as the
cross-regime comparison of A5 does (τ +0.43 / +0.29 / +0.36 against +0.57 /
+0.29 / +0.29), Hawkeye-SRRIP swap included. A5's pressure-matched pair
differs in LLC size by the core count (2 MB shared against 2 MB per core
private), because the private regime holds one copy of the shared data per
core. So A5 cannot say whether sharing reorders the policies or the size does.

A sweep of LLC sizes in both regimes gives, at each core count n, several
cross-regime pairs at equal pressure (shared s against private n·s) and, as a
control, the same size ratio n inside each regime, where nothing about
sharing changes.

## What is run

The frozen `champsim_b3v4_69ebdcce`, `--private-coherence 2`, 50 M warm-up +
100 M per core, canneal threads 1..n (as every Phase A run), `max_cycles`
across cores ranks. **The 8 baselines:** lru, random, srrip, drrip, ship,
hawkeye, mockingjay, srrip_bias. COALESCE is left out: its architecture is
frozen and its inputs (the LLC's sharer mask and MESI state) are to be aligned
with the validated directory first.

LLC sizes are totals, set with `make_config.py --llc-per-core-mb` (16-way,
64 B lines; 1 MB = 1,024 sets).

**What "size" includes.** `make_config.py` fixes the LLC latency (20 cycles)
but not its bandwidth, which ChampSim derives from the set count
(`legacy_environment.cc`: tag and fill bandwidth = sets / 512, at least 1):
2 per cycle at 1 MB, 4 at 2 MB, 64 at 32 MB. Every scaled run so far had this
too (2 MB per core at 16 cores: 64). It is kept, so the new rows are
comparable with the old ones, and disclosed: a size step here is a step in
capacity, set count (and with it the sampled sets of Hawkeye, SHiP and
Mockingjay) and bandwidth together, as in a banked cache.

| cores | sizes (MB) | already run (same binary, level 2 shared; private rows see Q0) | new runs |
|---|---|---|---|
| 4 | 1, 2, 4, 8, 16 | 2 (`phaseA_l2_fixed`, shared; `phaseA`, private), 8 (`phaseA_l2_scaled`, shared; `phaseA_scaled_private`, private) | 1, 4, 16 MB × 2 regimes × 8 = 48 |
| 8 | 1, 2, 4, 8, 16, 32 | 2 and 16, as above | 1, 4, 8, 32 MB × 2 regimes × 8 = 64 |

Plus **Q0**, 4 runs. New trees: `results/phaseA_l2_a6_<total>mb/`, read by
`run_phase_a.sh rows` and `b3_rows.sh` as they are. Runner:
`scripts/a6_sweep.sh` (its own queue; `run_phase_a.sh` and `bin/champsim` are
not touched). About 600 CPU-hours: 8-core jobs first.

## Qualifying checks

- **Q0, the older private rows stand in for this binary:** hawkeye and
  srrip_bias, 4 cores, private, at 2 MB and 8 MB, rerun on the frozen binary,
  equal the existing rows (`phaseA`, `phaseA_scaled_private`) in `max_cycles`,
  `min_cycles` and instructions. LRU already does at all six sizes and core
  counts (2026-10-14). If Q0 fails, the private rows at 2 and 8 MB (4c) and 2
  and 16 MB (8c) are rerun before anything is scored.
- **Q1:** every run complete; no trace wrapped; private rows read 0 sharing,
  0 invalidations; shared rows read self-check 0, stale-holders 0, 3×n
  registered, level 2.
- **Pressure is LRU's LLC hit rate over loads and RFOs** (the measure that is
  the same on every binary; `a5_size_control_2026-10-14.md`).

## The comparison

For each n in {4, 8}, Kendall τ over the 8 baselines:

- **Matched pairs, M:** shared at s against private at n·s, for s = 1, 2, 4 MB.
  A pair counts only if LRU's two hit rates are within 5 points.
- **Controls, C:** the same factor n inside one regime: (s, n·s) for
  s = 1, 2, 4 MB, in the private regime and in the shared regime. Up to 6 per
  n. Nothing about sharing differs inside a pair.

Under "sharing has no effect beyond pressure", a matched pair differs only in
size, at equal pressure; a control pair differs in size and in pressure. So a
matched pair should reorder the policies no more than the controls do.

## Predictions

No direction is predicted. The decision rule:

- **H1, sharing reorders the policies beyond size and pressure:** for both
  n = 4 and n = 8, the median τ over M is **below the lowest** τ in C.
- **H0, not distinguishable from a size effect:** the median τ over M lies
  within the range of C, for either n.
- **H2, sharing reorders the policies less than size does:** the median τ
  over M is above the highest τ in C, for both n.
- Fewer than two matched pairs at an n: that n is not decided.

**Near ties.** Where every policy is within 0.5% of LRU (a cache that holds
the working set), the order is noise and τ means little; such a pair is
reported with its spread and counted, which can only make H1 harder to meet.

**Reported in every case:** each matched and control τ; the same-size
cross-regime τ at every size; each policy's speedup over LRU against LRU's
hit rate, both regimes on one plot (the figure for the paper); and every
adjacent gap, not only gaps to LRU.

## How each outcome is read

- **H1:** the paper may say sharing changes which policy wins, beyond what
  pressure explains, on canneal at 4 and 8 cores, with the size control
  stated.
- **H0:** the paper says the reordering seen across regimes is as large as a
  change of cache size alone produces, so the evidence does not separate the
  two. What stands is the pressure result: at one size, the private view
  misjudges the gains.
- **H2:** sharing preserves the order better than a change of size does;
  multi-programmed rankings transfer, given matched pressure.

Each of these is publishable. Nothing is tuned after a τ is seen. The
held-out programs (`b3_heldout_design_2026-10-14.md`), once traced, may be
added to the sweep at 4 cores by an amendment written before their rows exist.
