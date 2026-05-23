# D3 — Glider (Shi, Huang, Jain, Lin — MICRO 2019)

**Citation key**: `shi2019glider`

## Key contribution
Glider [`shi2019glider`] is the deep-learning entry in the ML cache replacement family. It uses an **LSTM trained offline** to map sequences of recent PCs into reuse predictions, then **distills** the trained LSTM into a small online-deployable predictor (a binary integer-linear program, or a small attention-style lookup) that can fit in a realistic hardware budget.

## Features it uses
- A sliding window of recent program counters (10–50 PCs deep).
- Offline LSTM training on traces.
- Online: the distilled predictor uses PC sequences as the only feature.

## What gap remains relative to COALESCE
Glider is *purely* PC-based and ignores coherence state entirely. Its training pipeline is also offline — adapting to a new workload requires retraining the LSTM and re-distilling, which is not feasible for the dynamic mix of programs running on a server LLC.

## How COALESCE differs
COALESCE is fully *online* (perceptron weights update during execution via ghost-buffer feedback) and incorporates coherence features. The trade-off: COALESCE is a simpler model class than a distilled LSTM, so it has lower per-context expressive power, but it adapts on the fly and is coherence-aware.

## Citation sentence for Related Work
> "Glider [`shi2019glider`] demonstrated that deep-learning models trained offline on PC sequences can be distilled into deployable hardware predictors. The approach is coherence-oblivious and requires offline retraining, contrasting with COALESCE's online, coherence-aware predictor."
