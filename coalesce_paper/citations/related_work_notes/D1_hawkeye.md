# D1 — Hawkeye (Jain & Lin, ISCA 2016)

**Citation key**: `jain2016hawkeye`

## Key contribution
Hawkeye is the seminal ML cache-replacement policy that uses **Belady's MIN as a training signal**. The insight: while we cannot run MIN online (it requires future knowledge), we *can* run MIN over a recent history of accesses (a sliding window of the OPTgen algorithm) and use those "what would have been the right answer?" labels to train a PC-indexed predictor in real time.

## Features it uses
- Program counter of the load/store that allocated the line.
- Per-set history of recent allocations (for OPTgen).
- A PC-indexed predictor table (similar in spirit to SHiP's signature, but trained against the OPT labels rather than just hit/miss).

## What gap remains relative to COALESCE
Hawkeye is **single-core** in spirit — its features and training are oblivious to coherence state and sharing behaviour. In a multicore setting, two PCs that both have "high reuse" by OPTgen's reckoning can have very different *system-wide* eviction costs depending on whether the line is Modified or shared by many cores. Hawkeye cannot distinguish these.

## How COALESCE differs
COALESCE replaces Hawkeye's OPTgen-derived training signal with a direct reinforcement-learning loop (ghost-buffer rescues), and *adds* MESI state + sharer count to the feature set. The trade-off: COALESCE loses OPTgen's near-optimal training labels (which is why Hawkeye is hard to beat on single-core workloads) but gains coherence-awareness (which is why COALESCE wins on heavily-shared multicore workloads).

## Why we are *not* implementing Hawkeye as a baseline in Saga 1
Time. OPTgen is non-trivial to implement (~1–2 weeks of engineering for a clean, validated ChampSim module). The strategy doc defers this to Saga 2 (`docs/PUBLICATION_STRATEGY.md` § "What got cut"). For HiPC, the answer to "why not Hawkeye?" goes in Threats to Validity: it is the obvious next baseline, deferred for engineering time, expected to be the strongest single-core competitor.

## Citation sentence for Related Work
> "Hawkeye [`jain2016hawkeye`] established the ML-cache-replacement paradigm by using Belady's MIN over a sliding history window as the training signal for a PC-indexed predictor. It remains the strongest published single-core baseline, but does not incorporate coherence state or sharing patterns and therefore cannot exploit the coherence-cost asymmetry that COALESCE targets."
