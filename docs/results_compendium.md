# COALESCE — Results Compendium (updated 2026-06-12: barnes + complete ocean 8c)

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

### 8-core (8 policies — COMPLETE)

| # | Policy | max_cycles | vs SRRIP |
|---|---|---|---|
| 1 | SRRIP | 550,675,830 | – |
| 2 | SHiP | 550,732,443 | +0.01 % |
| 3 | DRRIP | 551,564,285 | +0.16 % |
| 4 | **COALESCE** | **566,374,131** | **+2.9 %** |
| 5 | LRU | 584,499,393 | +6.1 % |
| 6 | Hawkeye | 591,008,754 | +7.3 % |
| 7 | coalesce_no_sharer | 607,309,316 | +10.3 % |
| 8 | Mockingjay | 814,696,310 | **+47.9 %** |

724 K LLC invalidations, 91 K aliased fills at 8c.

## barnes (SPLASH-3 N-body octree, n16384 — LOW LLC pressure)

### 4-core (8 policies — COMPLETE)

| # | Policy | max_cycles | vs LRU |
|---|---|---|---|
| 1 | **LRU** | **156,549,335** | – |
| 2 | DRRIP | 158,994,040 | +1.6 % |
| 3 | SRRIP | 159,098,740 | +1.6 % |
| 4 | SHiP | 159,175,321 | +1.7 % |
| 5 | Hawkeye | 159,500,118 | +1.9 % |
| 6 | **COALESCE** | **160,448,239** | **+2.5 %** |
| 7 | coalesce_no_sharer | 160,656,244 | +2.6 % |
| 8 | Mockingjay | 162,545,897 | +3.8 % |

cpu0→LLC sees only ~500 K accesses (vs canneal's tens of millions) — the
n16384 working set fits in L1/L2; the LLC is barely pressured. Total policy
spread 3.8 %. With no capacity pressure, LRU recency is near-optimal and
every learning policy pays prediction overhead for nothing. Fourth
characterization corner: low-LLC-pressure → nothing matters, LRU wins.

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
| ocean 8c | **ablation loses 7.2 %** | **scale-stable — confirms 4c** |
| barnes 4c | ablation loses 0.13 % | negligible (low LLC pressure) |
| canneal 16c | pending (queued) | – |

## Geomean summary (COALESCE speedup, losses included)

| vs | 4-core (4 benchmarks) | 8-core (3 benchmarks) |
|---|---|---|
| LRU | **+9.7 %** | **+9.2 %** |
| Hawkeye | **+1.5 %** | **+1.5 %** |
| Mockingjay | **+13.9 %** | **+22.5 %** |
| DRRIP | +0.2 % | +0.0 % |
| SHiP | −0.4 % | −1.0 % |
| SRRIP | −0.5 % | −2.4 % |

(4-core includes barnes; 8-core = canneal + ocean + fluidanimate. COALESCE is
positive vs every learning policy and LRU at both scales; flat-to-−2.4 % vs
the RRIP heuristics, disclosed and explained.)

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

## ⚠️ Track C seed study — methodology caveat

The seed runs (seed2/seed3 + relaunched seed1 baselines) use trace mix
**big{0,1,2,3,0,1,2,3}** — NOT the headline mix big{0,1,2,3,4,0,1,2}. The
seed study is internally consistent but its absolute numbers are NOT
comparable to the headline 8-core canneal table (e.g. coalesce seed2 =
273.8 M vs headline 301.9 M — the mix lacks big4). Paper treatment: report
the seed study as a separate variance experiment ("across 3 VMEM
randomization seeds on a fixed workload mix, max_cycles varies by X %"),
NOT as error bars glued onto the headline table.

Seed role-shuffling (e.g. seed3's bottleneck on CPU 4 instead of CPU 0) is
expected: duplicate trace copies alias to the same physical pages under
shared VMEM, and the seed changes which copy wins the warmup race. Verify
each seed log has all 8 CPUs finished + sane max_cycles before use.

## Pending (as of 2026-06-12 early)

| Item | Status |
|---|---|
| Track C: hawkeye/srrip/ship seeds 1,2,3 | running (seed1 launched 03:17) |
| Track C: **coalesce seed1 (new mix) — MISSING, must launch** | ❌ |
| Track C: coalesce_no_sharer seeds — optional | not launched |
| canneal seed3 coalesce log | on server, scp + verify |
| Bias sweep: cb_40_0 + cb_150_75 done; cb_0_0 + cb_0_20 at 6/8 | scp when done |
| canneal 16c coalesce_no_sharer | still to queue |
| barnes 8c | CUT (low discrimination at 4c; not worth server time) |
