# D9 — Sorin, Hill, Wood — Memory Consistency and Cache Coherence Primer (2011)

**Citation key**: `sorin2011coherence`

## What this reference is
A textbook-length tutorial on cache-coherence protocols and memory-consistency models, published in Morgan & Claypool's Synthesis Lectures on Computer Architecture series. It is the canonical reference for MSI, MESI, MOESI, MESIF, directory vs snoop, and the consistency-vs-coherence distinction.

## Why we cite it
- **MESI definition** (B8, B10): cited as the source for the four-state protocol.
- **Coherence costs** (paper Introduction): the bus-traffic and ordering-latency costs of invalidation are documented here.
- **Background section** (E2 in the strategy doc): when writing the new Background section, this is the single citation for everything coherence-related.

## Citation sentence for Related Work / Background
> "We adopt MESI as the cache-coherence protocol for our experiments; the canonical reference for MESI and the broader family of invalidation-based protocols is Sorin, Hill, and Wood's primer [`sorin2011coherence`]."

## Open items
- Decide whether to also cite a more recent coherence-protocol survey (e.g., one from the 2020+ era) if one exists and is more current. For HiPC, the Synthesis primer is sufficient.
