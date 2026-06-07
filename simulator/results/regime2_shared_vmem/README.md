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

### canneal 4-core shared (all 7 policies, bottleneck-IPC ranking)

| Rank | Policy | Bottleneck IPC (CPU 1) | Projected cycles @ 100 M sim | vs Best |
|---|---|---|---|---|
| 1 | **COALESCE** | **0.3742** | 267.3 M (actual) | — |
| 2 | Hawkeye | 0.3501 | 285.7 M | +6.9 % |
| 3 | SRRIP | 0.3492 | 286.4 M | +7.2 % |
| 4 | SHIP | 0.3481 | 287.3 M | +7.5 % |
| 5 | DRRIP | 0.3402 | 294.0 M | +10.0 % |
| 6 | Mockingjay | 0.3206 | 311.9 M | +16.7 % |
| 7 | LRU | 0.2547 | 392.6 M | +46.9 % |

COALESCE has the **highest bottleneck-core IPC** — beating the best ML
baseline (Hawkeye) by ~6.9 %. This is the **flip from regime 1 to regime 2
that the paper needed**: at 4-core under default ChampSim (regime 1) COALESCE
was 4th of 5; with sharing exposed (regime 2) it wins outright. The
mechanism narrative — "coherence features activate under sharing" — now
has empirical support across two regimes at the same core count.

### canneal 8-core shared (100 M sim/core, COALESCE only so far)

| Metric | Regime 1 V2 | Regime 2 | Δ |
|---|---|---|---|
| max_cycles (COALESCE) | 415,157,549 | **301,945,789** | **−27.3 %** |
| bottleneck IPC (avg of CPU 1, 6) | 0.2415 | **0.3318** | **+37.4 %** |

This is COALESCE vs its regime-1 self. Comparing to other policies at
8-core under shared VMEM is pending (server chat is queuing those runs).

### canneal 16-core shared (in progress)

`canneal/16core/coalesce_in_progress.log` contains a partial run — heartbeats
through CPU 0 at ~510 M instructions, ~192 M cycles. No `Simulation complete`
lines yet. Either still running on server or scp'd mid-run. Treat as TBD.

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
pressure win helps. Wait for 8-core fluidanimate before drawing
workload-generalization conclusions.

## Sub-directory provenance

| Directory | Status |
|---|---|
| `canneal/4core/` | All 7 policies. ⚠️ COALESCE ran 100 M sim/core, baselines ran 50 M sim/core — use IPC for fair comparison. |
| `canneal/8core/` | 1 policy (coalesce). 100 M sim/core. Baselines pending. |
| `canneal/16core/` | 1 policy (coalesce) — `coalesce_in_progress.log`, incomplete. Wait for server. |
| `fluidanimate/4core/` | All 7 policies (lru, srrip, drrip, ship, hawkeye, mockingjay, coalesce). Sim lengths match. |
| `fluidanimate/8core/` | TBD — in flight. |
