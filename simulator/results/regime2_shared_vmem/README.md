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
| canneal | 8 | **25.6 %** | **6,894,555** | 304,516 |
| fluidanimate | 4 | 0.30 % | 0 (read-only sharing) | (TBD) |

canneal at 8-core is where the mechanism *visibly* dominates: a quarter of
all evictions involve LLC lines shared by 2+ cores; the invalidation
machinery is busy. Fluidanimate at 4-core has trivial sharing — bin[1]
still 99.7 %, no invalidations.

## Headline numbers landed so far

### canneal 8-core shared (100 M sim/core)

| Metric | Regime 1 V2 | Regime 2 | Δ |
|---|---|---|---|
| max_cycles (COALESCE) | 415,157,549 | **301,945,789** | **−27.3 %** |
| bottleneck IPC (avg of CPU 1, 6) | 0.2415 | **0.3318** | **+37.4 %** |

This is COALESCE compared to itself across regimes. Comparing to other
policies under shared VMEM requires those policies to be re-run in
regime 2 (see fluidanimate/4core/ for the prototype of that comparison).

### fluidanimate 4-core shared (all 7 policies)

| Rank | Policy | max_cycles | vs best |
|---|---|---|---|
| 1 | DRRIP | 46,559,597 | — |
| 2 | SRRIP, SHIP (tie) | 46,576,519 | +0.04 % |
| 3 | Hawkeye | 46,840,339 | +0.60 % |
| 4 | LRU | 47,757,062 | +2.57 % |
| 5 | Mockingjay | 48,774,327 | +4.76 % |
| 6 | **COALESCE** | **48,870,477** | **+4.96 %** |

COALESCE is last by ~5 %. The whole range is small (~5 %), so 4-core
fluidanimate barely discriminates between policies — but the perceptron
+ ghost-buffer overhead is not amortized by either capacity-pressure or
coherence-feature wins (sharing is read-only and tiny). Wait for 8-core
fluidanimate results before drawing workload-generalization conclusions.

## Sub-directory provenance

| Directory | Status |
|---|---|
| `canneal/4core/` | 1 policy (coalesce). 100 M sim/core. |
| `canneal/8core/` | 1 policy (coalesce). 100 M sim/core. |
| `canneal/16core/` | TBD — in flight. |
| `fluidanimate/4core/` | All 7 policies (lru, srrip, drrip, ship, hawkeye, mockingjay, coalesce). |
| `fluidanimate/8core/` | TBD — in flight. |
