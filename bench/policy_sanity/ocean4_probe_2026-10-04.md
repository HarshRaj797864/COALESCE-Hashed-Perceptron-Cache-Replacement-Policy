# Ocean at 4 cores: the pairing probe, gem5 at the traced grid, and a prediction

**2026-10-04.** Raw rows: `phasea_rows_v9.txt` (306 rows; the 302 rows of v8
are byte-identical). gem5 output: `simulator/results/gem5_ocean_4c_n514/`
(laptop, gitignored). Written **before** any ocean result for a policy other
than LRU exists.

## The traces

`ocean_4t`, traced 2026-10-01 (`OCEAN_THREADS=4 regen_traces.sh gen ocean`):
- grid 514, 4 threads, all four threads used;
- 200,000,000 records per thread, against the 180 M a 50M+100M run needs
  with ocean's 120% margin;
- audit: 34.8–37.5% of records carry memory operands at 50% depth and
  29.7–39.9% at 75%, all four `ok`.

## The pairing probe (LRU, 4 jobs)

`phaseA_ocean4` (fixed 2 MB) and `phaseA_ocean4_scaled` (2 MB per core), both
regimes. All checks pass (`analyze_rows.py check`); no wrap.

| LRU, ocean 4c | LLC load hit | max_cycles |
|---|---|---|
| fixed, private | 15.50% | 340,708,287 |
| fixed, shared | 15.73% | 343,205,203 |
| scaled, private | 69.48% | 210,071,283 |
| scaled, shared | 69.98% | 209,340,791 |

**The rule committed in `46416c4`** picks the (private, shared) combination
with the closest LRU load hit rates. That is **fixed vs fixed, 0.23 pp apart**.
Scaled vs scaled is also within the 3 pp bound (0.50 pp), and the cross pairs
are 54 pp apart. **For ocean the pressure-matched and geometry-matched
comparisons coincide**, so neither of canneal's confounds applies.

**Why: ocean barely shares.** LRU, 4 cores, shared regime:

| | aliased fills / KI | writeback-time invalidations / KI |
|---|---|---|
| canneal, fixed | 0.9543 | 0.3899 |
| ocean, fixed | 0.0416 | 0.0232 |
| canneal, scaled | 0.9537 | 1.3796 |
| ocean, scaled | 0.0437 | 0.0572 |

Ocean shares about 23× less than canneal per instruction, which fits its
contiguous partitions: each thread owns a block of the grid, and only block
edges are shared.

## Pre-registered prediction for the full ocean sweep

If sharing is what reorders the policies on canneal, a workload that barely
shares should keep its ranking. For the 8 baselines on ocean 4c, private vs
shared:

- **P1. Kendall τ ≥ +0.71 at both geometries.** At most 4 of 28 pairs flip.
- **Refuted if τ ≤ +0.57** (canneal's 4c pressure-matched value) at either
  geometry. Then low sharing does not keep rankings stable, and the
  sharing-intensity account of canneal's divergence is in doubt.
- **Between the two: inconclusive**, and reported as such.
- **P2. COALESCE** (each arm) moves by less than 2 pp, in speedup over LRU,
  between regimes at each geometry. On canneal 4c it moved 16.5 pp
  (−6.66% → +9.85%).

## gem5 at the traced problem

Ocean, `-n514 -p4`, MESI_Three_Level, patched (`ordered=false` on all 8
L0↔L1 buffers, `randomization=false`). It ended normally at 1.369 s simulated
and 1,382,430,104 instructions, roughly the whole traced program; 3.5 h of
host time.

| gem5, ocean 4c | invalidating stores / KI | upgrades / KI | upgrades share | cross-check |
|---|---|---|---|---|
| grid 258 | 0.1290 | 0.3507 | 73% | 44,093 == 44,093 |
| **grid 514** | **0.0712** | **0.0874** | 55% | 97,460 == 97,460 |

Doubling the grid side roughly halves the invalidation rate, as edge-only
sharing predicts (edge length / area). So the B3 comparison must use the
traced grid, 514. That is why this run exists.

**Not yet comparable with ChampSim**, for two reasons:
1. ChampSim's counters here are writeback-time. The store-time counter
   (`5ac2844`) is not deployed yet; the `b3_ocean4*` queues run it.
2. gem5 runs the whole program, while ChampSim measures instructions 50 M to
   150 M of each thread's first 200 M. This window question is still open
   (PLAN § 4, B3 design).
