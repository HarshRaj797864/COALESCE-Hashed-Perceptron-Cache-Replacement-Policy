# D7 — Cuesta et al., Coherence Deactivation for Private Blocks (ISCA 2011)

**Citation key**: `cuesta2011coherence`

## Key contribution
Cuesta et al. observed that **most cache blocks in real workloads are never shared** — they are private to a single core for their entire lifetime. Tracking coherence state for these blocks burns directory-cache capacity for no benefit. Their proposal: detect private blocks at allocation time (using OS / page-table hints), *deactivate* coherence tracking for them, and free up directory capacity for blocks that actually need it.

The result was a meaningful reduction in directory-cache misses and a small but consistent IPC gain on PARSEC workloads.

## Why this paper matters for COALESCE
This is the closest prior work in spirit — it is one of the first papers to explicitly recognize **coherence state as a feature** worth optimizing the cache subsystem around, rather than treating it as protocol plumbing to be hidden from the rest of the design.

The mechanism is different (directory-cache management vs LLC replacement) but the worldview is shared: coherence metadata carries signal, and the system performs better when that signal is exposed to the higher-level policy.

## What gap remains relative to COALESCE
Cuesta operates on **directory capacity**, not LLC capacity, and the decision (deactivate / don't deactivate) is binary and made once at allocation. COALESCE operates on LLC capacity, the decision is per-eviction, and the predictor is *continuous* (perceptron-weighted) rather than binary.

## How COALESCE differs
- Different mechanism (LLC replacement vs directory tracking).
- Continuous, learned predictor instead of a one-shot deactivation decision.
- Uses sharer-count, not just private/shared binary.

## Citation sentence for Related Work
> "Coherence-aware cache optimizations have a small but growing prior literature. Cuesta et al. [`cuesta2011coherence`] showed that detecting private blocks and deactivating their coherence tracking reduces directory pressure with measurable IPC improvement. We extend this worldview — that coherence state carries actionable signal — from the directory to the LLC replacement decision."
