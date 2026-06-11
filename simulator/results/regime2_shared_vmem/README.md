# Regime 2 — Shared VMEM (overlay enabled)

VMEM is configured with `vmem_shared_cpus` listing all participating CPUs.
Identical virtual addresses across those CPUs alias on the same physical
page — see `simulator/inc/vmem.h::set_shared_cpus()`.

Consequence: **sharer_count can exceed 1**, `LLC COHERENCE INVALIDATIONS`
and the `+20×sharer` bias fire on real workload data. COALESCE's
coherence machinery is no longer dormant.

The mechanism is documented in `docs/coherence_aware.md` § 4. Validation
of the overlay (V1..V6 synthetic matrix) is in `bench/scripts/`.

## What the regime exposes (vs regime 1)

| Workload | Cores | bin[2+] of sharer hist | INVALIDATIONS | VMEM ALIASED FILLS |
|---|---|---|---|---|
| canneal | 4 | **1.45 %** | 106,667 | 7,874 |
| canneal | 8 | **25.6 %** | **6,894,555** (coalesce) / 6,930,421 (no-sharer) | 304,516 / 304,964 |
| canneal | 16 | TBD (instrument logs) | TBD | TBD |
| fluidanimate | 4 | 0.30 % | 0 (read-only) | small |
| fluidanimate | 8 | n/a (no sharing) | **0** (read-only) | 249 |

canneal at 8-core is where the mechanism *visibly* dominates: a quarter of
all evictions involve LLC lines shared by 2+ cores; the invalidation
machinery is busy. Fluidanimate has trivial cross-core writes (LLC mix is
100 % LOAD) — sharer/MODIFIED features structurally cannot fire.

## ⚠️ Methodology gotcha — sim-length mismatch in 4-core canneal

The 4-core canneal shared run was launched with **`--simulation-instructions 100000000`
for COALESCE** but **`--simulation-instructions 50000000`** for the six baseline
policies. Comparing `max_cycles` directly is therefore misleading (COALESCE did
2× the work). Use **bottleneck-core IPC** (length-independent) or normalize
cycles to 100 M sim/core by dividing 100 M / bottleneck_IPC.

For final paper numbers the server chat should **rerun the baselines at
100 M sim/core** so the comparison is direct and reviewers don't have to
trust the IPC normalization.

## Headline numbers landed so far

### canneal 4-core shared (matched 50M warmup + 100M sim across all policies)

| Rank | Policy | max cycles | vs COALESCE | Bottleneck IPC | INV |
|---|---|---|---|---|---|
| 1 | **COALESCE** | **267,251,645** | – | **0.3742** | 106,667 |
| 2 | **coalesce_no_sharer** (ablation) | **267,247,657** | **−0.0015 %** (tied) | 0.3742 | 105,710 |
| 3 | Hawkeye | 286,865,528 | +7.3 % | 0.3486 | 88,918 |
| 4 | SRRIP | 287,031,501 | +7.4 % | 0.3484 | 91,764 |
| 5 | SHIP | 288,163,881 | +7.8 % | 0.347 | 88,298 |
| 6 | DRRIP | 294,947,400 | +10.4 % | 0.339 | 94,724 |
| 7 | Mockingjay | 311,277,369 | +16.5 % | 0.3213 | 36,555 |
| 8 | LRU | 392,999,637 | **+47.1 %** | 0.2545 | — |

COALESCE wins outright. The +7.3 % lead over Hawkeye (the strongest ML baseline)
is direct max-cycles comparison at matched length — no IPC-normalisation
caveat. This is the **regime-flip narrative**: at 4-core under default
ChampSim (default VMEM) COALESCE was 4th of 5; with sharing exposed it wins
outright over six other policies.

**Ablation result (the big finding)**: `coalesce_no_sharer` (full COALESCE
minus the sharer-count hash and the +20×sharer bias, with a PC-only
orthogonal hash1) is dead-tied with full COALESCE at this scale (difference:
4 K cycles over 267 M = 0.0015 %). The sharer feature contributes nothing
measurable on canneal — empirically confirming the inert-bin[1]=98.5% sharer
histogram. The MESI half of COALESCE (PC × MESI state hash + +40 MODIFIED
bias) carries all the contribution. This justifies a simpler policy with one
less hyperparameter to defend in the paper.

### canneal 8-core shared (100 M sim/core, all 7 policies + ablation)

| Rank | Policy | max cycles | vs full COALESCE | Bottleneck IPC (CPU 1 / 6) |
|---|---|---|---|---|
| 1 | **coalesce_no_sharer** (ablation) | **300,714,619** | **−0.41 %** (wins) | **0.3354 / 0.3325** |
| 2 | **COALESCE** | **301,945,789** | – | **0.3325 / 0.3312** |
| 3 | SRRIP | 303,011,899 | +0.4 % | 0.3306 (avg) |
| 4 | SHiP | 316,393,994 | +4.8 % | 0.3166 |
| 5 | Hawkeye | 317,172,523 | +5.0 % | 0.3157 |
| 6 | DRRIP | 325,848,199 | +7.9 % | 0.3073 |
| 7 | LRU | 392,564,736 | +30.0 % | 0.2549 |
| 8 | Mockingjay | 393,934,080 | +30.5 % | 0.2543 |

Full COALESCE leads SRRIP by +0.4 % (down from the archived +33 % under default
ChampSim VMEM — the regime change exposes how much of the original "win" was
the per-CPU isolation artefact). The lead over Hawkeye is **+5.0 %**, over
Mockingjay/LRU **+30 %**.

**Ablation result at 8-core**: `coalesce_no_sharer` beats full COALESCE by
0.41 % (300.71 M vs 301.95 M cycles). At 4-core the two were dead-tied
(−0.0015 %). On canneal — where genuine cross-thread sharing is shallow
(bin[2+] = 1.45 % at 4c, 25.6 % at 8c) — the +20×sharers bias mis-fires on
noise and the simplified policy is better.

⚠️ **This finding does NOT generalize.** On ocean 4-core (genuine boundary-cell
sharing, ~6× higher LLC invalidations per access than canneal), full COALESCE
beats `coalesce_no_sharer` by +7.3 % (569 M vs 611 M cycles). The sharer
feature is **workload-dependent**: inert on canneal, information-bearing on
ocean. See `ocean/README.md` for the full ocean data.

**Paper narrative**: full COALESCE is the headline policy. The
canneal-vs-ocean ablation contrast is presented in § 6 as a *workload-dependent
feature activation* finding, not a policy-simplification recommendation.

### canneal 16-core shared (COALESCE only — baselines pending)

| Metric | Default ChampSim (archived) | Shared VMEM | Δ |
|---|---|---|---|
| max_cycles (COALESCE) | 921,717,448 | **348,247,158** | **−62.2 %** |
| bottleneck IPC (avg CPU 1, 6, 11) | 0.1088 | **0.294** | +170 % |
| worker IPC (CPU 0, 5, 10, 15 avg) | 1.183 | 2.645 | +124 % |

COALESCE at 16-core under shared VMEM hits 348 M cycles — 62 % faster than
its default-VMEM-archive self at the same core count. The mechanism scales:
bottleneck cores nearly triple their IPC, worker cores more than double.
Baselines at 16-core shared (SRRIP, Hawkeye, LRU at minimum) are queued.

### fluidanimate 4-core shared (all 7 policies — same sim length, comparable)

| Rank | Policy | max_cycles | vs best |
|---|---|---|---|
| 1 | DRRIP | 46,559,597 | — |
| 2 | SRRIP, SHIP (tie) | 46,576,519 | +0.04 % |
| 3 | Hawkeye | 46,840,339 | +0.60 % |
| 4 | LRU | 47,757,062 | +2.57 % |
| 5 | Mockingjay | 48,774,327 | +4.76 % |
| 6 | **COALESCE** | **48,870,477** | **+4.96 %** |

(Sim lengths verified identical for fluidanimate — this ranking is direct.)
COALESCE is last by ~5 % across a 5 % policy spread. The whole workload
barely discriminates at 4-core. Sharing is read-only at this scale
(`INVALIDATIONS = 0`), so neither the coherence machinery nor capacity-
pressure win helps.

### fluidanimate 8-core shared (all 7 policies — matched lengths)

| Rank | Policy | max_cycles | vs best | CPU 0 IPC |
|---|---|---|---|---|
| 1 | DRRIP | 106,901,485 | — | 0.9354 |
| 2 | SHiP / SRRIP (tie) | 106,925,560 | +0.02 % | – |
| 3 | Hawkeye | 107,086,325 | +0.2 % | – |
| 4 | LRU | 108,798,167 | +1.8 % | – |
| 5 | Mockingjay | 109,921,513 | +2.8 % | – |
| 6 | **COALESCE** | **112,179,646** | **+4.9 %** | 0.8914 |

Perfectly consistent with 4-core: COALESCE last by ~5 % across a ~5 %
total spread, `LLC INVALIDATIONS = 0`, only 249 aliased fills. The LLC
access mix is 100 % LOAD — MESI state never leaves EXCLUSIVE, neither
the +40 MODIFIED bias nor the sharer feature can fire. This is the
structural boundary of the policy's sweet spot, and the consistency
across core counts confirms it's principled, not noise.

## Sub-directory provenance

| Directory | Status |
|---|---|
| `canneal/4core/` | All 7 policies. ⚠️ COALESCE ran 100 M sim/core, baselines ran 50 M sim/core — use IPC for fair comparison. |
| `canneal/8core/` | 8 policies (lru, srrip, drrip, ship, hawkeye, mockingjay, coalesce, coalesce_no_sharer). 100 M sim/core. **Ablation result: no-sharer beats full COALESCE by 0.41 %.** |
| `canneal/16core/` | 1 policy (coalesce.log) — COALESCE-only scaling figure data. |
| `fluidanimate/4core/` | All 7 policies (lru, srrip, drrip, ship, hawkeye, mockingjay, coalesce). Sim lengths match. |
| `fluidanimate/8core/` | All 7 policies. COALESCE last by 4.9 % — consistent with 4-core. |
| `ocean/4core/` | 7 policies (mockingjay pending on server). COALESCE 4th; ablation flip — see `ocean/README.md`. |
| `ocean/8core/` | In flight on server (5 done, 3 finishing as of Jun 11 13:44). |

### Still on the server (queued / running, Jun 11)

- Track C seeds: canneal 8c coalesce seed2/seed3 (baseline seeds still to queue)
- Bias sweep: cb_0_0, cb_0_20, cb_40_0, cb_150_75 (canneal 8c)
- barnes 4c × 8 policies (traces done, sims running)
- Missing: ocean 4c mockingjay, canneal 16c coalesce_no_sharer, barnes 8t traces |
