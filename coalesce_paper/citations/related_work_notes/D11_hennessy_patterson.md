# D11 — Hennessy & Patterson, Computer Architecture: A Quantitative Approach, 6th ed. (2017)

**Citation key**: `hennessy2017quantitative`

## What this reference is
The standard graduate-level computer-architecture textbook. The 6th edition (2017) includes updated coverage of multicore memory hierarchies, DRAM timing, and the Roofline model.

## Why we cite it
- **DRAM-latency claim** (B1): Chapter 2 gives the canonical range (150–300 cycles end-to-end for DDR4-class memory) we cite for the "200+ cycle writeback" motivation.
- **Cache-hierarchy background**: Section 2.1–2.3 covers the L1 / L2 / LLC structure we assume the reader understands.
- **Memory consistency**: Chapter 5 covers coherence at the textbook level (Sorin/Hill/Wood [`sorin2011coherence`] is the depth-reference; H&P is the breadth-reference).

## Citation sentence for Introduction / Background
> "Modern DDR4-class DRAM access from an out-of-order core typically costs 150–300 cycles end-to-end depending on row-buffer state and queuing [`hennessy2017quantitative`]; a Modified-state writeback is therefore a single eviction that triggers two such accesses (the writeback itself, plus the inevitable subsequent fill on re-reference)."

## Open items
- For a Tier-1 venue (Saga 2: ASPLOS / HPCA / ISCA / MICRO), pair this with a more specific microbenchmark citation (e.g., Molka 2009 [`molka2009memory`] or a current Intel optimization manual section) to avoid the appearance of relying solely on a textbook.
- The 6th edition was 2017; if a 7th edition has appeared by 2026, switch to that and update the BibTeX entry.
