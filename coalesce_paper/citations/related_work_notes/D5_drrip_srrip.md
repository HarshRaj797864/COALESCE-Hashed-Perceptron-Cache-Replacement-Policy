# D5 — RRIP / SRRIP / DRRIP (Jaleel, Theobald, Steely, Emer — ISCA 2010)

**Citation key**: `jaleel2010rrip`

> Note: the current paper draft (`latex/paper/coalesce_hipc.tex`) cites this as `jaleel2010high`. When migrating the paper to use the master `references.bib`, rewrite all `\cite{jaleel2010high}` → `\cite{jaleel2010rrip}` for consistency.

## Key contribution
Jaleel et al. introduced the **RRIP (Re-Reference Interval Prediction)** family of replacement policies, which generalize LRU into a 2- or 3-bit per-line "re-reference prediction value" (RRPV). The two operational variants:

- **SRRIP** (Static RRIP): On insertion, give the block a long RRPV (e.g., 2-bit value of 2, on a 0–3 scale). On hit, promote to the "most recently expected" position (RRPV = 0). On replacement, pick the line with the largest RRPV; if none has the max, increment all RRPVs (this is the "aging" step).
- **DRRIP** (Dynamic RRIP): Sample two policies (SRRIP and BRRIP, where BRRIP gives most lines the max RRPV on insertion) on a small fraction of "leader sets" and use a per-set Policy Selector to pick the winner. This is the canonical **Set-Dueling Monitor** mechanism that underpins much of subsequent ML-cache-replacement work.

## Features it uses
- Per-block 2-bit RRPV.
- Set-dueling for SRRIP vs BRRIP selection (DRRIP).
- No machine learning, no PC features.

## Why this paper matters for COALESCE
1. **It is the baseline framework**: SRRIP/DRRIP are the standard RRIP variants we compare against in 4-core and 8-core experiments.
2. **It introduced set-dueling**: the conceptual ancestor of set sampling (B5).
3. **It is the substrate SHiP extends**: SHiP [`wu2011ship`] adds learned RRPV insertion on top of RRIP.

## How COALESCE differs
- COALESCE has *no per-block recency state* (no RRPV, no LRU stack). Decisions are made purely on perceptron-predicted reuse.
- COALESCE incorporates coherence features that RRIP variants ignore.
- COALESCE is competitive with DRRIP on single-core / low-contention regimes, and wins decisively on multicore high-contention regimes.

## Citation sentence for Related Work
> "RRIP and its dynamic variant DRRIP [`jaleel2010rrip`] established the modern baseline for cache replacement, using a 2-bit re-reference prediction value per block and set-dueling between insertion policies. SRRIP remains the de-facto industrial baseline for LLC replacement, and SHiP [`wu2011ship`] later showed that learning the insertion RRPV from PC signatures improves over fixed insertion policies."
