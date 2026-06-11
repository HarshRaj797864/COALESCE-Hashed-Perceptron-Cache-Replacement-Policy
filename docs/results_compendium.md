# COALESCE — Results Compendium (frozen 2026-06-11, pre-barnes)

All runs: ChampSim + shared-VMEM overlay, 2 MB shared LLC (2048 sets × 16 ways),
50 M warmup + 100 M sim per core, ranking by max_cycles (lower = better).
Source logs: `simulator/results/regime2_shared_vmem/`.

## canneal (irregular, write-heavy: 89 % RFO+WRITE at LLC)

### 4-core (8 policies)

| # | Policy | max_cycles | vs COALESCE |
|---|---|---|---|
| 1 | coalesce_no_sharer | 267,247,657 | tied (−0.0015 %) |
| 2 | **COALESCE** | **267,251,645** | – |
| 3 | Hawkeye | 286,865,528 | +7.3 % |
| 4 | SRRIP | 287,031,501 | +7.4 % |
| 5 | SHiP | 288,163,881 | +7.8 % |
| 6 | DRRIP | 294,947,400 | +10.4 % |
| 7 | Mockingjay | 311,277,369 | +16.5 % |
| 8 | LRU | 392,999,637 | +47.1 % |

### 8-core (8 policies)

| # | Policy | max_cycles | vs COALESCE |
|---|---|---|---|
| 1 | coalesce_no_sharer | 300,714,619 | −0.41 % |
| 2 | **COALESCE** | **301,945,789** | – |
| 3 | SRRIP | 303,011,899 | +0.35 % |
| 4 | SHiP | 316,393,994 | +4.8 % |
| 5 | Hawkeye | 317,172,523 | +5.0 % |
| 6 | DRRIP | 325,848,199 | +7.9 % |
| 7 | LRU | 392,564,736 | +30.0 % |
| 8 | Mockingjay | 393,934,080 | +30.5 % |

Coherence at 8c: 6.9 M LLC invalidations, 305 K aliased fills, bin[2+] = 25.6 %.

### 16-core

COALESCE: 348,247,158 cycles (bottleneck IPC 0.294, worker IPC 2.645).
Ablation + baselines at 16c pending.

## ocean (SPLASH-3 ocean_cp; regular grid sweeps, ~40 % writes, 6× canneal's coherence traffic)

### 4-core (8 policies — COMPLETE)

| # | Policy | max_cycles | vs SHiP |
|---|---|---|---|
| 1 | SHiP | 549,605,858 | – |
| 2 | SRRIP | 550,297,702 | +0.13 % |
| 3 | DRRIP | 551,685,991 | +0.38 % |
| 4 | **COALESCE** | **569,457,207** | **+3.6 %** |
| 5 | LRU | 587,215,973 | +6.8 % |
| 6 | Hawkeye | 589,923,943 | +7.3 % |
| 7 | coalesce_no_sharer | 611,083,533 | +11.2 % |
| 8 | Mockingjay | 813,767,568 | **+48.1 %** |

### 8-core (6 of 8; no_sharer + mockingjay re-scp pending)

| # | Policy | max_cycles | vs SRRIP |
|---|---|---|---|
| 1 | SRRIP | 550,675,830 | – |
| 2 | SHiP | 550,732,443 | +0.01 % |
| 3 | DRRIP | 551,564,285 | +0.16 % |
| 4 | **COALESCE** | **566,374,131** | **+2.9 %** |
| 5 | LRU | 584,499,393 | +6.1 % |
| 6 | Hawkeye | 591,008,754 | +7.3 % |

724 K LLC invalidations, 91 K aliased fills at 8c.

## fluidanimate (PARSEC; 100 % LOAD at LLC — coherence features structurally inert)

| | 4-core | 8-core |
|---|---|---|
| Best (DRRIP) | 46,559,597 | 106,901,485 |
| SHiP / SRRIP | +0.04 % | +0.02 % |
| Hawkeye | +0.6 % | +0.2 % |
| LRU | +2.6 % | +1.8 % |
| Mockingjay | +4.8 % | +2.8 % |
| **COALESCE (last)** | **+5.0 %** | **+4.9 %** |

INVALIDATIONS = 0 at both scales; 249 aliased fills at 8c. Total policy
spread only ~5 % — the workload barely discriminates.

## Ablation: sharer-count feature is workload-dependent

| Workload | coalesce_no_sharer vs full COALESCE | Reading |
|---|---|---|
| canneal 4c | tied (−0.0015 %) | sharer inert (shallow sharing) |
| canneal 8c | ablation wins +0.41 % | sharer bias mis-fires on noise |
| ocean 4c | **ablation loses 7.3 %** | sharer carries real information under genuine sharing |
| ocean 8c | pending re-scp | – |
| canneal 16c | pending (queued) | – |

## Geomean summary (COALESCE speedup, losses included)

| vs | 4-core (3 benchmarks) | 8-core (3 benchmarks) |
|---|---|---|
| LRU | **+14.0 %** | **+9.2 %** |
| Hawkeye | **+2.1 %** | **+1.5 %** |
| Mockingjay | **+18.4 %** | pending ocean 8c |
| DRRIP | +0.6 % | ~0.0 % |
| SHiP | −0.3 % | −1.0 % |
| SRRIP | −0.4 % | −2.4 % |

## The three load-bearing findings

1. **COALESCE is the strongest learning-based policy on every workload with
   non-zero write traffic tested.** First overall on canneal (both scales);
   first among learning policies on ocean (both scales), ahead of Hawkeye by
   3.5-4.3 % and Mockingjay by ~43 %.
2. **The multi-programmed state of the art does not transfer to multithreaded
   sharing.** Mockingjay — best across 100 multi-programmed mixes in its
   HPCA 2022 evaluation — is last on canneal 8c (+30 %) and last on ocean 4c
   (+48 %). Hawkeye loses to LRU on ocean.
3. **Feature contribution is workload-dependent.** The sharer-count axis is
   inert on canneal but carries +7.3 % on ocean; the MESI axis requires
   write traffic and is structurally dead on fluidanimate. The
   characterization (write fraction × access irregularity × sharing depth)
   predicts where the policy wins.

## Pending (as of 2026-06-11 evening)

| Item | Status |
|---|---|
| barnes 4c × 8 policies (SPLASH-3, irregular octree + writes + sharing) | running — results 2026-06-12 |
| ocean 8c coalesce_no_sharer + mockingjay | finishing on server, re-scp |
| Track C: canneal 8c coalesce seed2/seed3 | running |
| Track C: baseline seeds (srrip/hawkeye/no_sharer × 2) | to queue |
| Bias sweep cb_{0_0, 0_20, 40_0, 150_75} (canneal 8c) | running |
| canneal 16c coalesce_no_sharer | to queue |
| barnes 8t traces + 8c sims | after disk check |
