# D8 — Reactive NUCA (Hardavellas, Ferdman, Falsafi, Ailamaki — ISCA 2009)

**Citation key**: `hardavellas2009rnuca`

## Key contribution
Reactive NUCA (R-NUCA) [`hardavellas2009rnuca`] addressed the related problem of *block placement* in a distributed (Non-Uniform Cache Access) LLC. The insight: different cache blocks have different *sharing behaviour* — some are private, some are shared, some are instruction blocks read by many cores — and the optimal *placement* within the NUCA grid depends on which category the block belongs to. R-NUCA classifies blocks at runtime using simple OS hints + observation, then places each block according to its class (private → near the requesting core; shared read-only → replicated; shared read-write → central).

## Why this paper matters for COALESCE
R-NUCA is a foundational reference for any paper that argues "sharing behaviour matters for cache-management decisions." It is the *placement* analogue of what COALESCE does for *replacement*.

## What gap remains relative to COALESCE
R-NUCA operates on placement at allocation; once placed, a block is not re-classified. COALESCE operates on replacement on every eviction; the predictor learns continuously and can change its mind as workload phases shift. Also, R-NUCA's classification is coarse (private / shared-RO / shared-RW) while COALESCE's sharer count is a fine-grained signal.

## How COALESCE differs
- Replacement vs placement.
- Continuous learning vs one-shot classification.
- Fine-grained sharer count + MESI vs coarse sharing categories.

## Citation sentence for Related Work
> "Hardavellas et al.'s Reactive NUCA [`hardavellas2009rnuca`] argued for adapting cache *placement* to per-block sharing behaviour in distributed LLCs. COALESCE inherits this paper's worldview — that sharing behaviour is first-class signal for cache management — and applies it to the orthogonal axis of *replacement* decisions in a shared LLC."
