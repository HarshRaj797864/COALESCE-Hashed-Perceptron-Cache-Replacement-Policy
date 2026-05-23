# D6 — Belady's MIN (Belady, IBM Systems Journal 1966)

**Citation key**: `belady1966study`

## Key contribution
Belady proved that the **optimal offline cache replacement policy** is to evict, on each miss, the block whose next access is furthest in the future. This is unimplementable online (it requires future knowledge) but defines the *theoretical upper bound* for any replacement policy.

Every cache-replacement paper since 1966 cites Belady — either as the upper bound their policy is compared against, or as the training signal their ML-based predictor regresses toward (Hawkeye, Mockingjay).

## How COALESCE uses this
We do **not** explicitly compute Belady's MIN over our traces (Hawkeye and Mockingjay do, via OPTgen on a sliding window). Instead, we use a reinforcement-learning training loop (cache hits and ghost-buffer hits as positive signals) to approximate good behaviour without ever computing the optimal label.

This is a *philosophical* difference, not a technical one. Belady-trained methods (Hawkeye, Mockingjay) get strong gradient signal from "the right answer," at the cost of an expensive OPTgen sliding window. Self-supervised methods (SHiP, COALESCE) get weaker signal from "did this work?" but with much lower training overhead and no offline label-computation step.

## Citation sentence for Related Work
> "Belady's MIN [`belady1966study`] establishes the theoretical optimum for cache replacement. Modern ML approaches such as Hawkeye [`jain2016hawkeye`] and Mockingjay [`shah2022mockingjay`] derive online predictors by regressing toward Belady-style labels computed over a sliding window. COALESCE instead uses self-supervised reinforcement learning, trading per-context training signal strength for lower training-pipeline overhead and easier extension to features beyond reuse distance — in particular, coherence state and sharing patterns."

## Open items
- For the paper's Results section, consider running OPTgen over the canneal trace and reporting Belady-MIN miss rate as an oracle upper bound. This is a 1–2 day implementation effort and is high reviewer value (shows how much headroom remains). Defer to Saga 2 unless time allows.
