# Phase 2A — 8-core canneal baseline matrix (V2)

> **Run date**: 2026-05-28/29 · **Config**: 50M warmup + 100M sim/core, 2 MB shared LLC (2048 sets × 16 ways)
> **Code**: V2 (SAMPLING_MODULO=32, GHOST_CAPACITY=128, BLOOM_RESET_THRESHOLD=150) + A.1/A.2 invalidation hook
> **Server**: dual Xeon E5-2670 v3 (iiitsgpu), runs `nice -n 19`, shared box
> **Status**: ✅ All 5 policies completed full 100M/core on all 8 cores. Resolves weakness **A2**.
> **Raw logs**: on server at `results/phase2a_8core_canneal_V2/logs/{policy}_50M_100M.log`

## Headline: system completion time (max cycles across cores — lower = faster)

| Policy | Max cycles | COALESCE is faster by |
|---|---|---|
| **COALESCE** | **415,157,549** | — |
| SRRIP | 619,411,244 | **33.0%** |
| SHiP | 621,172,900 | **33.2%** |
| DRRIP | 627,034,759 | **33.8%** |
| LRU | 640,322,745 | **35.2%** |

COALESCE beats **all four** baselines, including the strongest (SRRIP). The old data compared only against SRRIP — that cherry-picking objection (weakness A2) is now resolved.

## Bottleneck-core IPC (CPUs 1 & 6 — canneal's shared pointer-chasers)

| Policy | CPU1 | CPU6 | avg | COALESCE gain vs |
|---|---|---|---|---|
| **COALESCE** | **0.2421** | **0.2409** | **0.2415** | — |
| SRRIP | 0.1619 | 0.1614 | 0.1616 | **+49.4%** |
| SHiP | 0.1614 | 0.1610 | 0.1612 | **+49.8%** |
| DRRIP | 0.1601 | 0.1595 | 0.1598 | **+51.1%** |
| LRU | 0.1567 | 0.1562 | 0.1565 | **+54.3%** |

## Worker-core IPC (CPUs 0 & 5) — the trade-off (weakness A9)

| Policy | CPU0 | CPU5 | avg |
|---|---|---|---|
| COALESCE | 2.088 | 2.047 | 2.057 |
| SRRIP | 2.129 | 2.084 | 2.104 |
| SHiP | 2.120 | 2.089 | 2.0985 |
| DRRIP | 2.124 | 2.089 | 2.099 |
| LRU | 1.547 | 1.544 | 1.5415 |

COALESCE workers run ~2% below the RRIP variants but +33% above LRU. The net 33% system win is dominated by the bottleneck cores (+49-54%), which gate canneal's completion. Honest framing for the paper: a favourable critical-path trade-off, not a free lunch.

## Coherence invalidations

All policies report **0** synthetic invalidations over the full run. This confirms the COHERENCE_HOOK_AUDIT finding: canneal write-hits rarely land on multi-sharer LLC lines, so the win is **retention-driven hit-rate** on bottleneck cores, NOT invalidation-cycle savings. The paper's mechanism narrative must reflect this.

## Reproducibility note

V2 (44 KB metadata) reproduces V0 (148 KB) almost exactly:
- V0: COALESCE 415.9M cycles vs SRRIP 620.6M
- V2: COALESCE 415.2M cycles vs SRRIP 619.4M

The 3.6× storage reduction and the accurate (non-monotonic) sharer_mask cost nothing in performance — a strength to cite.

## Per-core IPC caveat for aggregate stats

Fast cores (2,3,4,7) stream billions of extra instructions while waiting for the bottleneck cores (e.g. COALESCE CPU7 ran 1.66B instr vs LRU's 2.56B). Faster system completion = fewer extra streaming accesses, so **raw aggregate LLC-miss counts are NOT apples-to-apples** across policies. Use per-core ROI-normalized stats for any miss-rate comparison; do not compare summed misses directly.
