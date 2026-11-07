# A5, a control: cache size alone moves the rankings as much as sharing does

**2026-10-14.** Written while working through the weaknesses a reviewer would
raise. No new run: every number comes from `phasea_rows_v18.txt`, through
`scripts/analyze_rows.py compare`, and was re-derived by a separate script
that reads the raw columns and computes τ by brute force (same values).

**The finding.** On canneal, the private regime alone, with no sharing at all,
reorders the policies when only the LLC changes from 2 MB to 2 MB per core.
It reorders them about as much as the cross-regime comparison does, and
**Hawkeye and SRRIP swap places there too**. So the A5 result as stated
("at matched pressure, sharing reorders the policies") is not shown by this
design: the pressure-matched pair differs in LLC size, and LLC size alone
produces the same kind of change.

## The control

Kendall τ over the 8 baselines, canneal (1 = same order). The private regime
is the same at every coherence level (Q1 of every B3 v4 design), so its rows
serve both levels.

| comparison | differs in | 4c | 8c | 16c |
|---|---|---|---|---|
| **cross-regime, pressure-matched** (shared 2 MB vs private 2 MB/core), level 0 | sharing **and** LLC size | +0.57 | +0.29 | +0.29 |
| same, level 2 | | (pending) | +0.14 (7 policies) | +0.29 |
| **private 2 MB vs private 2 MB/core** — no sharing on either side | LLC size (and with it pressure) | **+0.43** | **+0.29** | **+0.36** |
| cross-regime, same size, 2 MB, level 0 | sharing (and with it pressure) | +0.86 | +0.71 | +0.64 |
| same, level 2 | | (pending) | +0.81 (7) | +0.64 |
| cross-regime, same size, 2 MB/core, level 0 | sharing (and with it pressure) | +0.29 | +0.14 | +0.29 |
| same, level 2 | | +0.29 | +0.14 | +0.57 |
| shared 2 MB vs shared 2 MB/core, level 2 | LLC size | (pending) | +0.62 (7) | +0.14 |

LRU's LLC hit rate over loads and RFOs (the measure that is the same on
every binary; see below): private 1.7 / 0.6 / 0.35% at 2 MB and 26.1 / 26.3 /
26.4% at 2 MB per core; shared at level 2, 23.5 / 24.1 / 25.3% at 2 MB and
67.6 / 86.8 / 97.7% at 2 MB per core. At 2 MB per core, 16 cores, the shared
regime hits 98% and every policy is within 0.8% of LRU.

**A measurement trap, found on the way.** From step 1 (`f23e03f`) a
read-modify-write's load is issued as an RFO, so the *load-only* hit rate of
the level-2 binary is a different quantity from the older binary's. LRU,
canneal 16c, private, 2 MB per core: 26.41% on the older binary, 38.28% on
`champsim_b3v4` -- same cycles, same instructions, same total accesses. Loads
plus RFOs reads 26.42% on both. `b3_barnes_results_2026-10-14.md` compared
26.4% (older binary) with 31.7% (level 2, load-only) and concluded that
pressure was less well matched at level 2. On one measure it is as well
matched as before: 26.4% against 25.3%. `analyze_rows.py compare` now prints
the load+RFO rate beside the load rate.

## Hawkeye against SRRIP follows the cache size

Speedup over LRU in `max_cycles`:

| | private, 2 MB | private, 2 MB per core | shared, 2 MB (level 0 / level 2) |
|---|---|---|---|
| 8c | SRRIP +3.21, Hawkeye +2.88 | **Hawkeye +9.78**, SRRIP +1.98 | SRRIP +12.69 / +12.72, Hawkeye +12.07 / +11.91 |
| 16c | SRRIP +1.66, Hawkeye +1.49 | **Hawkeye +9.95**, SRRIP +3.15 | SRRIP +14.67 / +14.00, Hawkeye +11.34 / +10.95 |

At one LLC size (2 MB), SRRIP is ahead of Hawkeye in both regimes. Hawkeye
leads only at 2 MB per core. That is a known sensitivity, already listed as a
threat in PLAN § 8: Hawkeye's sampled-set count scales with the number of
sets, which is 8× and 16× larger at 2 MB per core for 8 and 16 cores (16,384 and 32,768 sets against 2,048).

srrip_bias moves the same way: in the private regime it is fourth at 2 MB
(+2.69 / +1.44 / +0.75) and last or next to last at 2 MB per core (−5.10 /
−4.46 / −2.28).

## What the data does support

**At one LLC size, sharing keeps the order and multiplies the gains.**
Simulated as separate programs (the private regime), canneal's threads each
carry their own copy of the shared data, and the 2 MB cache barely hits (LRU,
loads and RFOs: 0.35-1.7%). Simulated with sharing it hits 23.5-25.3%. The order of the
policies is largely kept (τ +0.64 to +0.86), but what the best policy gains
over LRU differs:

| best gain over LRU, 2 MB | 4c | 8c | 16c |
|---|---|---|---|
| private | +9.47 (Mockingjay) | +3.22 (Mockingjay) | +1.95 (Mockingjay) |
| shared, level 0 | +14.44 (Mockingjay) | +12.69 (SRRIP) | +14.67 (SRRIP) |
| shared, level 2 | (pending) | +12.72 (SRRIP) | +14.00 (SRRIP) |

That is a pressure effect, and a direct one: the private view holds N copies
of data the program holds once.

## What it changes

- **The claim "sharing reorders the policies"** (`a5_crossregime_2026-10-01.md`,
  `framing.md`, the mid-term deck's slide 12) is withdrawn as a sharing effect.
  The pressure-matched τ stands as a measurement; it cannot be attributed to
  sharing while the pair differs in LLC size, because size alone gives the
  same τ and the same swap.
- **What stands:** at one LLC size, sharing changes the pressure the cache
  sees by an order of magnitude and the gains of every policy with it, while
  the order is mostly kept.
- The 2026-10-01 doc said the geometry-matched pair "points the same way".
  That pair (2 MB per core on both sides) differs in pressure by 45-70 points
  of hit rate; at 16 cores and level 2 it reads +0.57.

## What would separate sharing from size

An LLC-size sweep in both regimes. With several sizes per regime, the two
regimes can be compared at equal size and at equal pressure, and each
cross-regime change set against how much the order moves between neighbouring
sizes inside one regime. `make_config.py --llc-per-core-mb` already sets any
power-of-two size, so no simulator change is needed. Pre-registered separately
(`a6_size_sweep_design_2026-10-14.md`) before any run.
