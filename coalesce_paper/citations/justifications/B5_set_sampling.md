# B5 — 6.25 % set sampling (every 16th set) + D10 perceptron lineage

## Claim in the paper
The COALESCE perceptron tables are trained only on a 1-in-16 subset of LLC sets (`SAMPLING_MODULO = 16` in `simulator/replacement/coalesce/coalesce.h:17`). All sets read the perceptron weights at victim-selection time, but only sampled sets write updates. This cuts ~94 % of write-port traffic to the weight tables while preserving prediction accuracy.

## Cited evidence

### The perceptron-predictor lineage (D10 → Jiménez 2017)

**Jiménez & Lin, "Dynamic Branch Prediction with Perceptrons" (HPCA 2001)** [`jimenez2001perceptron`] introduced the hashed-perceptron predictor for branch prediction. The key insight — that a small table of *signed saturating-counter weights* indexed by hashed program-context features can match or exceed the accuracy of much larger gshare/PAg tables — is the algorithmic ancestor of every perceptron-based microarchitectural predictor since, including ours.

**Jiménez, "Multiperspective Reuse Prediction" (MICRO 2017)** [`jimenez2017multiperspective`] adapted the perceptron predictor from the branch front-end to the cache replacement back-end. The paper introduces *multiple parallel feature tables* indexed by orthogonal hash functions over different perspectives (PC, page offset, recency tags, etc.) — the same dual-table pattern COALESCE adopts. Multiperspective Reuse Prediction is the direct predecessor of COALESCE's prediction substrate; the novelty of COALESCE is adding **coherence-domain features** (MESI state, sharer count) and a **coherence-aware veto** on top of that substrate.

> *Citation sentence for Related Work*: "COALESCE's perceptron substrate inherits directly from the hashed-perceptron predictor of Jiménez and Lin [`jimenez2001perceptron`], later adapted to cache replacement in Multiperspective Reuse Prediction [`jimenez2017multiperspective`]; our contribution is the addition of cache-coherence features (MESI state and sharer count) to the feature set, and a coherence-aware bias term that protects expensive-to-evict blocks."

### Set-sampling as established practice

Sampling a subset of cache sets for control-policy training (rather than updating on every access) traces back to Qureshi et al.'s Set-Dueling Monitors [`jaleel2010rrip` cites this in the DRRIP design] and is standard in MICRO-class cache-replacement work. A 1-in-16 sampling rate is a common choice across the literature because it gives ~6 % of the cache as a training population — enough to converge the perceptron weights within tens of millions of instructions — while reducing weight-table write traffic by ~94 %.

> *[TODO: confirm the exact sampling ratio used in `jimenez2017multiperspective` and add a precise page-number citation here. Until then, frame as "follows established practice in perceptron-based cache predictors" rather than asserting Jiménez 2017 specifically used 1/16.]*

## Reconciliation against COALESCE implementation

```cpp
// simulator/replacement/coalesce/coalesce.h (V2 config, 2026-05-21)
constexpr int SAMPLING_MODULO = 32;     // was 16 in V0; reduced to halve sampled-set count

// simulator/replacement/coalesce/coalesce.cc:93-95
for (long i = 0; i < sets; i++) {
    if (i % SAMPLING_MODULO == 0) is_sampled[i] = true;
}
```

With 2048 LLC sets and SAMPLING_MODULO = 32, the sampled-set population is exactly **64 sets** (sets 0, 32, 64, …, 2016) — half the V0 design. On every cache miss in a *sampled* set we may insert a ghost-buffer entry; on every hit or ghost-hit in a sampled set we update both perceptron tables. Unsampled sets are read-only consumers of the predictor — they make decisions but do not contribute to training.

**Energy/area argument for the paper**: Even at the perceptron table's modest 4 KB footprint (2 × 2048 × 8 bits), restricting writes to 3.125 % of sets reduces dynamic write-port activity by ~97 % (1 − 1/32). Read activity is unchanged (every replacement query reads the weights), but read-port leakage and dynamic energy are already amortized by being a tiny fraction of the LLC's 2 MB data-array energy.

> *Note*: this 1/32 rate is the V2 configuration, chosen 2026-05-21 to reduce per-sampled-set storage (the predictor's *total* metadata footprint is dominated by per-set ghost buffers, so reducing the *number* of sampled sets is the most effective storage-reduction lever). If Phase 2A baselines reveal that 1/32 hurts predictor accuracy materially, the fallback is V1 (1/16 with smaller ghost) or V0 (1/16 with full ghost).

## Open items
- Confirm Jiménez 2017's exact sampling ratio (need to grep the paper PDF or check the Champsim community implementation of MPP) and replace the [TODO: verify] above with a hard citation.
- B6 (confidence threshold θ = 35) is closely related — the same training-update path gates on |vote| ≤ THRESHOLD. Write B6 next to fully cover the perceptron training-side parameters.
