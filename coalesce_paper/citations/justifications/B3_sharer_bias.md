# B3 — Sharer-count bias value

## Claim in the paper
The paper (`latex/paper/coalesce_hipc.tex` Eq. 2) adds a **fixed +75** to the perceptron vote when the candidate block has a sharer count ≥ 2.

## Claim in the code
The code (`simulator/replacement/coalesce/coalesce.cc:118`) adds **+20 × sharer_count**, only when the raw vote is already positive:

```cpp
if (raw_vote > 0) {
    ...
    if (current_sharers >= 2) final_vote += (20 * current_sharers);
}
```

So the code is (a) a sharer-count-scaled bias (not fixed), (b) smaller per-sharer than the paper claims, (c) gated on positive raw votes.

| Sharers | Paper bias | Code bias |
|---|---|---|
| 0 | 0 | 0 |
| 1 | 0 | 0 |
| 2 | +75 | +40 |
| 3 | +75 | +60 |
| 4 | +75 | +80 |
| 5 | +75 | +100 |
| 6 | +75 | +120 |
| 7 | +75 | +140 |
| 8 | +75 | +160 |

The code's *linear scaling* is arguably more principled than the paper's *fixed +75*: cost of re-fetch genuinely scales with the number of sharing cores. But the paper text doesn't acknowledge this.

## Status
**BLOCKED on Phase 2D bias sweep**, same as [B2](B2_modified_bias.md). Sweep design covers `Sharer bias ∈ {0, 25, 50, 75, 100, 150}` per the strategy doc; if the linear-scaling variant in the code consistently outperforms a fixed bias, we should pivot the paper text to present the linear form and sweep its slope (`{5, 10, 20, 30, 50}× sharers`).

## Intuition for the bias magnitude

A Shared block invalidated on eviction triggers, on subsequent re-references:
- Re-fetch from DRAM: ~200 cycles.
- Plus, depending on cache hierarchy state, additional intervention from a peer cache or directory lookups (~50–100 cycles).

When N cores are sharing the line, each will pay the re-fetch penalty independently. The *system-wide* cost scales with N, even if each individual core's cost does not. This is the argument for linear scaling in the bias.

## What to write after Phase 2D

Decision point: does the empirical optimum favour
- (a) fixed bias for sharers ≥ 2 (the paper formulation),
- (b) linear `B_S × sharers` (the code formulation),
- (c) something more nuanced (e.g., bias only when sharers ≥ N for some N > 2)?

Whichever wins, justify the *form* (fixed vs scaled) before justifying the magnitude.

## Open items
- [BLOCKED] Phase 2D sweep.
- See [B2](B2_modified_bias.md), [OPEN_DECISIONS.md](../../../docs/OPEN_DECISIONS.md) item 1.
