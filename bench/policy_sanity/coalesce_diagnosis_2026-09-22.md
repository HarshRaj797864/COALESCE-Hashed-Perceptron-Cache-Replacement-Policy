# Why COALESCE loses: the coherence bias evicts page-table lines

> **Measured on the pre-fix policy** (added 2026-09-23). COALESCE's ghost-tag
> rescue could not tell one address from another until `97aa5da`; every
> COALESCE figure below predates that fix and is provisional until re-run. See
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

> ## ⚠️ PARTIALLY REFUTED 2026-09-22 — see `verification_2026-09-22.md`
>
> - **"TRANSLATION misses are 7.4x / 14.5x the best policy"** uses an unstable
>   ratio whose denominator is whichever policy happens to be lowest (DRRIP at
>   0.0004/KI). At **2 MB fixed, COALESCE's translation miss rate (0.6357) is
>   indistinguishable from LRU's (0.6380), SHiP's (0.6391) and DRRIP's
>   (0.6374)** — every policy is ~0.63 because a 2 MB cache evicts everything.
>   COALESCE is not an outlier at that geometry.
> - **"srrip_bias corroborates it; every coherence-biased policy shows this"**
>   is wrong. srrip_bias improves 10x and random improves 8x when the LLC grows
>   — srrip_bias sits beside *random*, not beside COALESCE. It is also a
>   different base policy with a different bias form, so it was never a
>   controlled comparison.
>
> The stable restatement: growing the LLC 8x, every non-COALESCE policy reduces
> translation misses by **8x to 1586x**; the COALESCE family manages **2-3x**.
> That gap is real and COALESCE-specific. The mechanism below remains a
> hypothesis — no variant with the bias removed entirely exists, so the causal
> step is untested.

**2026-09-22.** Raw: `phasea_rows_v4.txt`. canneal, shared, scaled geometry.

## The measurement

COALESCE holds an LLC load hit rate within **0.09pp** of SRRIP at 4 cores yet
runs **3.22%** slower. Decomposing every LLC miss per thousand instructions
retired — the residual after LOAD, WRITE, RFO and TRANSLATION is exactly
**0.000**, so this accounts for all of it:

| cores | policy | load MPKI vs SRRIP | wb miss/KI | RFO miss/KI | **TR miss/KI** | vs SRRIP |
|---|---|---|---|---|---|---|
| 4 | hawkeye | +12.68% | 0.008 | 0.000 | 0.008 | 0.11x |
| 4 | mockingjay | +0.75% | 0.179 | 0.000 | 0.003 | 0.04x |
| 4 | srrip | +0.00% | 0.536 | 0.000 | 0.070 | 1.0x |
| 4 | srrip_bias | −3.06% | 0.487 | 0.000 | 0.270 | 3.9x |
| 4 | **coalesce** | **+0.39%** | 0.628 | 0.000 | **0.520** | **7.4x** |
| 8 | srrip | +0.00% | 0.053 | 0.000 | 0.022 | 1.0x |
| 8 | **coalesce** | **+3.17%** | 0.089 | 0.000 | **0.319** | **14.5x** |

Demand loads are competitive. RFO is negligible for every policy (0.001
accesses/KI). Writeback misses are elevated but modest (1.17x at 4 cores).
**The cost is translation misses — page-table entries evicted from the LLC,
each one turning into a page walk to memory.**

The ordering is not COALESCE-specific: `srrip_bias`, the *static* coherence-bias
strawman, is next worst at 3.9x. Every policy carrying a coherence bias shows
it; LRU, Hawkeye, SHiP and Mockingjay do not.

## The mechanism, in `coalesce.cc:133-140`

```cpp
int raw_vote  = brain.predict_raw(current_set[w].ip, current_sharers, current_set[w].state);
int final_vote = raw_vote;
if (raw_vote > 0) {
    if (current_set[w].state == MODIFIED) final_vote += 40;
    if (current_sharers >= 2)             final_vote += (20 * current_sharers);
}
// ... the way with the LOWEST final_vote is evicted
```

Three properties combine badly:

1. **The bias is strictly non-negative.** It only ever raises a line's vote. It
   protects; it never condemns.
2. **It keys on MESI state and sharer count** — metadata that describes shared
   *data*. A page-table line fetched by the walker is not MODIFIED and is not
   multiply-shared, so it receives **nothing**.
3. **`find_victim` ignores `type` entirely.** The policy never distinguishes a
   translation line from a data line; it just sees a lower vote.

So in any set holding both shared data and page-table entries, the page-table
entries are the lowest-voted ways by construction, and they are evicted first.
The policy is not choosing them on merit — they are simply the only lines that
never receive the handicap everything else gets.

## The magnitude problem

`MAX_WEIGHT = 127`, `MIN_WEIGHT = -128` (`coalesce.h:11-12`), two tables summed,
so `raw_vote` spans roughly **[−256, +254]**. Against that:

| sharers | bias | as a fraction of the full perceptron range |
|---|---|---|
| 2 | +40 | 16% |
| 4 | +80 | 31% |
| 8 | +160 | 63% |
| 16 | **+320** | **126% — larger than the entire range** |

At 16 cores a widely-shared line can receive a bias exceeding everything the
perceptron can express. **The coherence bias does not augment the learned
signal; past about four sharers it overwhelms it.** That matches the ranking:
COALESCE places 7/11 at 4 cores, 8/11 at 8, 10/11 at 16 — it degrades as the
bias grows relative to what the perceptron can say.

## This is the same defect A4 found from the other side

On single-core SPEC, `sharer_mask` is always 1 so the sharer bias never fires,
but every dirty line is MODIFIED so the `+40` fires constantly — degenerating
to a dirty-bit preference that costs 0.26pp against simply deleting it
(`a4_results_2026-09-21.md`). Two independent experiments, one line of code.

## What is certain and what is not

**Certain:** the translation-miss measurement, the residual of 0.000 that makes
the decomposition complete, the bias arithmetic, and that `find_victim` never
inspects `type`.

**Not directly measured:** that the evicted translation lines are specifically
the unbiased ones. The reasoning is strong — the bias cannot be negative, it
keys on data-only metadata, and the strawman `srrip_bias` reproduces the effect
— but the closing evidence would be COALESCE's own `VICTIM SHARER HIST`, which
is already printed in every log. If victims cluster at 0–1 sharers while the
sets hold many 2+ lines, the mechanism is confirmed outright.

## Fix directions (not yet implemented; the policy is frozen pending review)

1. **Scale the bias to the perceptron range** rather than using raw additive
   constants, so it can never exceed what the learned signal can express.
2. **Cap the sharer term** — `20 * sharers` was chosen when 8 cores was the
   maximum; at 16 it is unbounded relative to everything else.
3. **Handle translation lines explicitly**, either exempting them from the
   comparison or giving them a floor, so they are not the residual victim.
4. **Gate the MODIFIED bias on `sharers >= 2`**, which A4 already argued for
   independently.

(1) and (3) address the defect found here. (4) addresses A4's. They are
compatible and none of them changes the policy's architecture.
