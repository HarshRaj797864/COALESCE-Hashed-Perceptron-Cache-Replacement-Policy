# B2 — Modified-state bias value

## Claim in the paper
The paper (`latex/paper/coalesce_hipc.tex` Eq. 2, line 73) defines a coherence-veto bias of **+150** added to the perceptron vote when the candidate block is in MESI state Modified.

## Claim in the code
The code (`simulator/replacement/coalesce/coalesce.cc:117`) adds **+40**, only when the raw vote is already positive:

```cpp
if (raw_vote > 0) {
    if (current_set[w].state == MODIFIED) final_vote += 40;
    ...
}
```

So the code's bias is (a) smaller (+40 vs +150) and (b) gated on positive raw votes (the paper's equation doesn't show this gating).

## Status of this justification
**BLOCKED on Phase 2D bias sweep.** Until we run the bias-sensitivity sweep (Phase 2D in `docs/PUBLICATION_STRATEGY.md`) we cannot defend either value as optimal. The 4-core and 8-core results in the current paper were produced by the *code's* +40 value, so:

- Whatever we publish must match the value used in the runs (or we must re-run).
- The Phase 2D sweep will sample {0, 25, 50, 75, 100, 150, 200, 250} as planned, and the optimum becomes the empirical justification.

## Intuition for the bias magnitude (to be revisited post-Phase 2D)

A Modified block, if evicted, costs:
1. A DRAM writeback (~200 cycles, see [B1](B1_dram_latency.md)).
2. Whenever the data is needed again, a clean read miss to DRAM (another ~200 cycles).

A non-Modified block, if evicted, costs:
1. No writeback (clean line).
2. When needed again, a clean read miss to DRAM (~200 cycles).

So the *incremental* cost of evicting Modified vs. evicting clean is approximately one writeback (~200 cycles), assuming the same line is re-referenced. In an 8-bit signed weight space [−128, +127], +200 would saturate the perceptron contribution; +150 is "approximately the writeback penalty, scaled into the weight space" — that is the paper's implicit (but unstated) rationale.

The code's +40 is much smaller; the rationale there appears to be conservatism — make sure the bias doesn't dominate the learned weights but is large enough to break ties in favour of dirty-line retention.

## What to write after Phase 2D
Once we have the sweep:
- Report the optimal value (call it `B_M^*`)
- Show the sensitivity curve (canneal IPC vs. bias, for at least canneal + 1 other workload)
- Explain `B_M^*` in terms of either (a) the cycle ratio of writeback to clean miss, OR (b) the perceptron weight scale — whichever fits the empirical result more cleanly.
- Mark this as the *justification* for the chosen value, not a coincidence.

## Open items
- [BLOCKED] Phase 2D sweep results.
- Decide whether to keep "only-on-positive-votes" gating or to always add the bias. The gating is a meaningful behaviour change worth either documenting in the paper or removing from the code.
- See also [B3](B3_sharer_bias.md) which has the same shape of problem for the sharer bias.
