# D10 — Jiménez & Lin, Perceptron Branch Predictor (HPCA 2001)

**Citation key**: `jimenez2001perceptron`

## Key contribution
This is the **origin paper for hashed-perceptron predictors in microarchitecture**. Jiménez and Lin showed that a small table of signed saturating-counter weights, indexed by hashing branch history and PC, could match or exceed the accuracy of much larger gshare- or PAg-style branch predictors at a fraction of the hardware budget.

The core algorithmic ideas — XOR-mixed feature hashing, signed saturating counters, low-confidence training, set-sampled training — all originate here and propagated into every subsequent perceptron-based microarchitectural predictor.

## Lineage to COALESCE
1. Jiménez & Lin 2001 — perceptrons for branch prediction.
2. Jiménez 2017 [`jimenez2017multiperspective`] — same family adapted to cache replacement (Multiperspective Reuse Prediction).
3. COALESCE — Jiménez 2017's substrate + coherence-domain features + ghost-buffer rescue training.

## What COALESCE inherits directly
- Hashed-feature indexing (B9).
- Signed 8-bit saturating counter weights (`MIN_WEIGHT = -128`, `MAX_WEIGHT = 127` in `coalesce.h`).
- Confidence-threshold training (B6).
- Set-sampled training (B5).

## Citation sentence for Related Work
> "Our perceptron substrate inherits directly from the hashed-perceptron branch predictor of Jiménez and Lin [`jimenez2001perceptron`], later adapted to cache replacement in Multiperspective Reuse Prediction [`jimenez2017multiperspective`]. We add coherence-domain features (MESI state, sharer count) and a coherence-aware bias term on top of this substrate."

## Open items
- This citation should appear early in the paper (in the Introduction when first naming the predictor family) and also in the dedicated Related Work subsection on perceptron predictors.
