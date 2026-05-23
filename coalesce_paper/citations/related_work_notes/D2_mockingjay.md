# D2 — Mockingjay (Shah, Jain, Lin — HPCA 2022 / ISCA 2022)

**Citation key**: `shah2022mockingjay`

## Key contribution
Mockingjay [`shah2022mockingjay`] mimics Belady's MIN policy by **regressing reuse distance** rather than classifying "cache-friendly" vs "cache-averse" (as Hawkeye does). It uses a sampled history of accesses to estimate the *next reuse distance* of each candidate, and evicts the candidate with the largest predicted distance.

## Features it uses
- Per-block reuse distance history.
- A PC- and address-indexed predictor that outputs a regressed reuse-distance estimate.
- (Some Mockingjay variants also use page-offset, but the core mechanism is reuse-distance regression.)

## What gap remains relative to COALESCE
Mockingjay's prediction objective is "what is the most reusable line?" — like Hawkeye, this is a single-core, coherence-oblivious objective. The reuse-distance metric does not capture the *system-wide* cost asymmetry between Modified, Shared, and Exclusive lines.

## How COALESCE differs
COALESCE's prediction objective is "what is the most coherence-safe line to evict?" — implicitly minimizing the *expected coherence-traffic cost* of the next miss, not the raw reuse distance. This is a more multicore-native framing.

## Why we are *not* implementing Mockingjay as a baseline in Saga 1
Same as Hawkeye [D1] — engineering time. The reuse-distance sampler + regression head is a multi-week effort. Deferred to Saga 2.

## Citation sentence for Related Work
> "Mockingjay [`shah2022mockingjay`] further refined the ML-cache-replacement approach by regressing per-block reuse distance, again training against a Belady-derived signal. Like Hawkeye, it operates per-core and per-line in isolation; the system-wide coherence cost of an eviction is not part of its loss function."
