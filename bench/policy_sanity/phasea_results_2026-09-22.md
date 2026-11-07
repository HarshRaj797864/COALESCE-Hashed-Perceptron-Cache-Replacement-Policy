# Phase A scaled sweep — complete, 72/72

> **COALESCE rows measured on the pre-fix policy** (added 2026-09-23). COALESCE's
> ghost-tag rescue could not tell one address from another until `97aa5da`;
> every COALESCE-family figure below predates that fix and is provisional until
> re-run. The other policies' rows are unaffected. See
> `coalesce_ghost_defect_2026-09-23.md`, "Which COALESCE findings are now
> provisional".

> ## ⚠️ ABSOLUTE PER-INSTRUCTION RATES BELOW ARE 2x TOO HIGH (found 2026-09-23)
>
> `plain_printer.cc:184-199` prints the whole cache-stat block twice when
> `NUM_CPUS > 1`, and `begin_phase()` zeroes both stat sets while `end_phase()`
> copies sim into roi — so the two blocks are **identical** and the extraction
> summed them. Every LLC counter in the multi-core rows is exactly **2x**.
>
> | quantity | affected? |
> |---|---|
> | hit rates, and anything "vs SRRIP" or "vs best" | **no** — both sides doubled |
> | policy rankings, `max_cycles`, cycle percentages | **no** — printed once |
> | improvement factors between geometries | **no** — both sides doubled |
> | **absolute MPKI, TR miss/KI, wb miss/KI, non-load MPKI** | **YES — halve them** |
> | `invals/KI`, `aliased_fills` | **no** — extracted with `grep -m1`, first match only |
> | anything from A4 | **no** — single core skips the first block |
>
> No conclusion in this document changes; every comparison here is a ratio.
>
> **Corrected data is available**: `phasea_rows_v5.txt`. Verified against v4 —
> all 130 rows in common have their LLC counters exactly halved, while
> `max_cycles`, `instrs`, `inv` and `af` are identical in 130/130. The factor
> really was exactly 2, so halving a figure below is exact rather than
> approximate. Fixed in `2e74427`.

**2026-09-22.** Raw rows: `phasea_rows_2026-09-22.txt` (134 rows, 111 usable).
Usable = `complete` + `vmem ok` + `wrap ok`. Every number below re-derives from
that file; nothing is quoted from an earlier summary.

## 1. The overlay validates — this is the contribution

canneal, LRU, scaled geometry:

| cores | regime | aliased fills | invalidations |
|---|---|---|---|
| 4 | private | **0** | **0** |
| 4 | shared | 384,915 | 556,804 |
| 8 | private | **0** | **0** |
| 8 | shared | 908,558 | 1,964,495 |
| 16 | private | **0** | **0** |
| 16 | shared | 1,982,046 | 5,085,373 |

Private is *exactly* zero at every core count; shared scales monotonically with
core count in both columns. This is the claim `docs/framing.md` calls alive, and
it holds on honest traces with a working policy interface. The earlier version of
this result was void because four of five canneal traces carried no data
accesses; this one is not.

## 2. COALESCE does not work

canneal, shared, scaled, ranked by max_cycles (the ranking metric — slowest core):

| cores | COALESCE rank | vs LRU | winner |
|---|---|---|---|
| 4 | **7 / 11** | +2.41% | mockingjay +6.01% |
| 8 | **8 / 11** | **−1.56%** | srrip +1.39% |
| 16 | **10 / 11** | **−1.02%** | ship +0.01% |

It is beaten by plain LRU at 8 and 16 cores. `docs/framing.md` already recorded
the policy claim as dead on a −2.4% 8-core geomean; this is that result
reproduced on correct code and honest traces. It is not a regression — it is a
confirmation.

**The ablations do say coherence state carries signal.** At 4 and 8 cores the
full policy beats both ablations (4c: coalesce +2.41 > no_mesi +0.71 >
no_sharer −9.06; 8c: coalesce −1.56 > no_sharer −3.59 > no_mesi −3.85). So
removing either coherence feature makes it worse. The features help; the policy
they are bolted to is not strong enough for that to matter.

## 3. What actually costs COALESCE: non-demand traffic

| cores | policy | load hit vs SRRIP | max_cycles vs SRRIP |
|---|---|---|---|
| 4 | coalesce | −0.09pp | **−3.22%** |
| 4 | mockingjay | −0.18pp | **+0.18%** |
| 8 | coalesce | −0.37pp | **−2.91%** |

Mockingjay posts a *worse* aggregate LLC hit rate than COALESCE at 4 cores and
still finishes faster, so what COALESCE loses is not capacity.

**Per-core imbalance was the first hypothesis and it is wrong.** `min_cycles`
comes back exactly equal to `max_cycles` on all 111 usable runs: every core ends
on the same cycle because the phase ends globally once the slowest core retires
its target and the rest keep being ticked until then (`champsim.cc:141`). There
is no laggard to find. Aggregate IPC also tracks `max_cycles` almost exactly
(coalesce −3.15% vs −3.22% at 4 cores), so COALESCE is genuinely slower in
whole-machine throughput, not merely unlucky in the ranking metric.

The cost is in traffic that is not a demand load. Normalising by instructions
retired, canneal shared scaled:

| cores | policy | load MPKI vs SRRIP | **non-load MPKI** |
|---|---|---|---|
| 4 | hawkeye | +12.68% | 0.016 |
| 4 | lru | +32.53% | 0.023 |
| 4 | ship | +4.48% | 0.109 |
| 4 | mockingjay | +0.75% | 0.182 |
| 4 | srrip | +0.00% | 0.606 |
| 4 | srrip_bias | −3.06% | 0.758 |
| 4 | **coalesce** | **+0.39%** | **1.148** |
| 8 | srrip | +0.00% | 0.076 |
| 8 | mockingjay | +2.35% | 0.006 |
| 8 | **coalesce** | **+3.17%** | **0.409** |

COALESCE's demand-load behaviour is competitive — load MPKI within 0.4% of
SRRIP at 4 cores — while its non-load miss rate is **1.9x SRRIP's at 4 cores
and 5.4x at 8**, and 70x Hawkeye's. That is where the cycles go.

`srrip_bias` — the static coherence-bias strawman — sits second highest at
0.758, and all three COALESCE variants are elevated (1.148 / 0.814 / 0.953).
Every policy carrying a coherence bias shows this; Hawkeye, LRU, SHiP and
Mockingjay do not. That is a strong hint the bias itself is responsible.

**The mechanism is a hypothesis, not yet measured.** Non-load misses were
derived by subtracting LOAD from TOTAL, which lumps writebacks with RFO,
prefetch and translation. The plausible story is that protecting MODIFIED lines
makes the LLC evict lines L2 is about to write back, so the writeback then
misses — but that needs the WRITE counters split out rather than inferred.
`llc_write_acc` and `llc_write_hit` have been added to the rows dump to settle
it. If confirmed, the fix is the same one A4 pointed at from the other
direction: gate the `+40` MODIFIED bias instead of applying it unconditionally.

## 4. The scaled geometry removes the problem it was meant to fix

| cores | LLC | best hit | worst hit | spread | cycle spread |
|---|---|---|---|---|---|
| 4 | 8 MB | 76.34% | 56.44% | **19.90pp** | 16.57% |
| 8 | 16 MB | 88.66% | 82.38% | 6.28pp | 5.83% |
| 16 | 32 MB | 97.76% | 96.10% | **1.65pp** | 2.14% |

2 MB per core was adopted to fix the fixed-2 MB confound found on 2026-09-19.
At 16 cores it gives canneal a 32 MB LLC, a 97.7% hit rate, and a 1.65pp spread
across eleven policies — replacement has almost nothing left to decide. Ranks 1
through 6 at 16 cores span 0.1%, which is noise, not an ordering.

**So the discriminating configuration in this sweep is 4 cores**, and 16-core
rows should be reported as evidence that the problem disappears at that size,
never as a policy comparison. This is the same effect that made barnes 4-core
empty at the scaled geometry (`internals_finding_2026-09-21.md`), one step short
of total.

Cache size is not a free parameter: it decides whether a replacement problem
exists at all. Both the fixed 2 MB and the scaled 2 MB-per-core are defensible;
what is not defensible is quoting a policy ranking from a configuration where
every policy hits 97.7%.
