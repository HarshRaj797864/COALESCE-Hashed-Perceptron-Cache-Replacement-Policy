# B4 — 5× ghost-hit weight boost

## Claim in the code
`simulator/replacement/coalesce/coalesce.cc:163–166`:

```cpp
if (ghosts[set].lookup(tag, ip_val, ghost_sharers, ghost_state)) {
    int vote = brain.predict_raw(ip_val, ghost_sharers, ghost_state);
    for(int k = 0; k < 5; k++) {
        brain.train(ip_val, ghost_sharers, ghost_state, true, vote);
    }
}
```

On a miss in a sampled set, if the address is found in the ghost buffer (was recently evicted from this set), the perceptron is trained 5× in the "reuse-predicting" direction — i.e., the weights are pushed positive five times to signal "this context should not have been evicted; protect it next time."

## Claim in the paper
The paper (`latex/paper/coalesce_hipc.tex:84`) says only "**Ghost hit:** Boost weights (+5)" — ambiguous wording; reads as "+5 to the weight" rather than "+1 applied 5 times."

The **code applies `+1` five times** in the train() function, but the train() function itself has guards (mispredicted OR low-confidence) — so in practice, the effective magnitude depends on whether the misprediction guard kicks in each iteration.

## Justification

There is no peer-reviewed source that establishes "5×" as the canonical ghost-hit boost factor. The closest prior art:

- **Jiménez 2017** [`jimenez2017multiperspective`] — uses a single train step per training event with an aggressive saturating counter; no separate "ghost boost" concept.
- **Hawkeye** [`jain2016hawkeye`] — uses Belady-based labelling rather than ghost-buffer rescue, so the analogy doesn't transfer.
- **Branch predictor literature** — Jiménez & Lin 2001 [`jimenez2001perceptron`] and follow-ups use a single train step per branch; the perceptron's saturating counter and confidence threshold handle the rest.

So the 5× factor is a **hyperparameter chosen by light tuning**. The qualitative rationale: ghost hits are *higher-information* events than ordinary cache hits, because they tell us about a *mistake the policy made*. Treating them as 5× more important than a routine training event biases the learner toward avoiding the same mistake.

## Quantitative sweep candidate

If Phase 2D has time, add a 1-axis sweep:

| Ghost boost | Expected behaviour |
|---|---|
| 0× (no boost) | Reduces to pure positive-feedback training; the policy can never "learn from mistakes" |
| 1× | Treats ghost hits same as cache hits |
| 3× | Mild emphasis on mistake-correction |
| **5× (current)** | Moderate emphasis (current value) |
| 10× | May overfit to ghost hits and destabilize learning |

Predicted shape: U or hockey-stick curve with an optimum somewhere in 3×–7×. Phase 2D ablation can confirm.

## Wording for the paper

Replace the ambiguous "Boost weights (+5)" with:

> "On a ghost hit, the perceptron training step is applied five times in the reuse-predicting direction. This treats prematurely-evicted contexts as five times more informative than ordinary cache hits, accelerating recovery from mispredictions while remaining bounded by the 8-bit saturating counters."

## Open items
- Run the 1-axis sweep above if Phase 2D has spare cycles.
- Decide whether the train() function's mispredict/low-confidence gate should also gate the 5× repeat (each iteration re-checks the guard against the *updated* weights — so in practice the effective boost is probably 2–3× not 5×).
