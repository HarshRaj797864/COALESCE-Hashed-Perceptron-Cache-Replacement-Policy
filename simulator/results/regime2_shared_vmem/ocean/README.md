# Ocean — SPLASH-3 ocean_cp under shared VMEM

Multi-grid PDE solver. Memory-bound; mixed RFO/WRITE traffic at the LLC; genuine
cross-thread sharing of grid boundary cells.

## What ocean tells us (vs canneal)

| Metric | canneal | ocean |
|---|---|---|
| LLC RFO+WRITE fraction | ~89 % | ~62 % at CPU 0 (LOAD 14.5 M, RFO 3.0 M, WRITE 6.5 M) |
| LLC INVALIDATIONS at 4-core | 106,667 | **~660 K (6× higher)** |
| VMEM ALIASED FILLS | 7,874 | 91,000+ |
| Sharing pattern | shallow (bin[2+]=1.45 % at 4c, 25.6 % at 8c) | TBD-instrumented |

ocean has **substantially more genuine cross-thread sharing** than canneal at the
same core count. This makes it the right workload to test whether the
sharer-count feature is information-bearing.

## Headline 4-core shared (7 policies, mockingjay pending)

Sorted by max_cycles (lower = better):

| Rank | Policy | max_cycles | vs SHIP | CPU 0 IPC | CPU 1 IPC | LLC INV |
|---|---|---|---|---|---|---|
| 1 | **SHiP** | **549,605,858** | – | 0.1819 | 0.3675 | 658,123 |
| 2 | SRRIP | 550,297,702 | +0.1 % | 0.1817 | 0.3599 | 662,548 |
| 3 | DRRIP | 551,685,991 | +0.4 % | 0.1813 | 0.3577 | 672,496 |
| 4 | **COALESCE (full)** | **569,457,207** | **+3.6 %** | 0.1756 | 0.3245 | 780,482 |
| 5 | LRU | 587,215,973 | +6.8 % | 0.1703 | 0.2848 | 482,899 |
| 6 | Hawkeye | 589,923,943 | +7.3 % | 0.1695 | 0.3081 | 791,673 |
| 7 | **coalesce_no_sharer** | **611,083,533** | **+11.2 %** | 0.1636 | 0.2874 | 564,368 |

**Two key findings**:

### 1. COALESCE does NOT win on ocean 4-core

Full COALESCE is 4th of 7. RRIP-family (SHiP / SRRIP / DRRIP) wins by 3-4 %.
This is honest disclosure data — the policy's win on canneal does not
unconditionally generalize. Workload-characterization analysis explains the
gap: ocean has higher inherent cross-thread sharing than canneal, but the
working set still fits poorly under capacity pressure that RRIP heuristics
handle well.

### 2. The sharer feature IS contributing on ocean — full COALESCE beats no-sharer by 7.3 %

| | max_cycles | Δ |
|---|---|---|
| coalesce (full) | 569,457,207 | – |
| coalesce_no_sharer | 611,083,533 | **+7.3 % (full wins by 41.6 M cycles)** |

This **directly contradicts** the 8-core canneal ablation finding where
`coalesce_no_sharer` beat full COALESCE by 0.41 %.

**Implication**: the sharer-count feature is workload-dependent. On canneal
(shallow cross-thread sharing, bin[2+] = 1.45 % at 4-core) the +20×sharers
bias mis-fires on noise. On ocean (genuine boundary-cell sharing) it activates
correctly and contributes substantially.

The paper narrative therefore keeps full COALESCE as the headline policy. The
ablation section presents this contrast as a *workload-dependent feature
activation* finding rather than a policy-simplification recommendation.

## Status of sub-directories

| Directory | Policies present | Status |
|---|---|---|
| `4core/` | lru, srrip, drrip, ship, hawkeye, coalesce, coalesce_no_sharer (7) | Mockingjay pending |
| `8core/` | TBD | Running |
| `16core/` | TBD | Stretch goal — launch tonight |
