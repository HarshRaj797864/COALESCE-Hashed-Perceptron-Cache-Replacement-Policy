# B6 — Confidence threshold θ

## Claim in the paper
The paper (`latex/paper/coalesce_hipc.tex:85`) writes:

> "Training triggers only on mispredictions or low-confidence votes (|Vote| ≤ θ)."

**θ is never defined** in the paper. This is a documentation gap.

## Claim in the code
`simulator/replacement/coalesce/coalesce.h:13`:

```cpp
constexpr int THRESHOLD = 35;
```

Used in `simulator/replacement/coalesce/coalesce.cc:72–86`:

```cpp
void PerceptronBrain::train(uint64_t pc, int sharers, MESI_State state, bool positive, int current_vote) {
    bool mispredicted = (positive && current_vote <= 0) || (!positive && current_vote > 0);
    bool low_confidence = std::abs(current_vote) <= THRESHOLD;
    if (mispredicted || low_confidence) {
        int h0 = get_hash0(pc, state);
        int h1 = get_hash1(pc, sharers);
        int direction = positive ? 1 : -1;
        // ... update both tables ±1, clamped to [MIN_WEIGHT, MAX_WEIGHT] ...
    }
}
```

So **θ = 35** in our implementation.

## Justification for θ = 35

The perceptron vote is the sum of two 8-bit signed weights, so it ranges in [−256, +255]. With a confidence threshold of 35:

- |vote| ≤ 35 → train (~14% of the full vote range)
- |vote| > 35 → already-confident prediction; skip training

This roughly matches Jiménez 2017's [`jimenez2017multiperspective`] confidence-region tuning, which uses a similar small fraction of the full weight range as the "low-confidence band." *[TODO: verify the exact θ value used in Jiménez 2017's MICRO 2017 evaluation; the multiperspective predictor's confidence threshold is typically in the 8–32 range for an 8-bit weight × few features design.]*

### Why 35 specifically (informed guess, needs confirmation)

The value 35 likely emerged from:
- A weight space of roughly [−128, +127] per table
- A 2-table sum giving votes in roughly [−256, +255]
- A heuristic "train if the vote is within ~15% of zero"

15% of 255 ≈ 38; 35 is in that ballpark. **If a different θ was chosen during the implementation iteration, document the reason in a comment in `coalesce.h`.**

## What to add to the paper

Update line 85 to:

> "Training triggers only on mispredictions, or on low-confidence votes where |Vote| ≤ θ. We use θ = 35, which corresponds to roughly 14% of the full ±256 vote range; values in this band indicate the predictor has not yet built strong confidence for the context and additional samples are valuable. This follows the confidence-region tuning of Jiménez [`jimenez2017multiperspective`]."

## Sensitivity check

A small sweep of θ ∈ {15, 25, 35, 50, 75} would be a 5-point addition to Phase 2D. If results are flat in this range, the qualitative claim is robust; if they're not, we've found a more interesting parameter.

## Open items
- [TODO] Verify Jiménez 2017 specifically uses a similar confidence threshold; cite exactly.
- Add the θ sweep to Phase 2D if time allows.
