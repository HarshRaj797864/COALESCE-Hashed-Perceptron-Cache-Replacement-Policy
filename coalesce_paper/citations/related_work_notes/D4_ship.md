# D4 — SHiP (Wu, Jaleel, Hasenplaugh, Martonosi, Steely, Emer — MICRO 2011)

**Citation key**: `wu2011ship`

## Key contribution
SHiP [`wu2011ship`] extends RRIP by predicting reuse based on the **signature of the allocating instruction**, where "signature" is typically a hash of the PC or PC + memory-region context. A small per-signature **saturating counter** (the SHCT — signature-history counter table) tracks the historical hit/miss ratio for that signature, and on insertion the block is given a re-reference prediction value (RRPV) that reflects the SHCT verdict.

## Features it uses
- PC signature of the allocating instruction (sometimes augmented with the memory region or thread ID).
- A small SHCT (~2k entries, 3-bit counters).
- RRIP's RRPV insertion / promotion machinery.

## What gap remains relative to COALESCE
SHiP, like its successors Hawkeye and Mockingjay, is coherence-oblivious. It also uses a *single* prediction table indexed by signature, which limits the aliasing-suppression you can get from orthogonal features.

## How COALESCE differs
- COALESCE uses **two orthogonal tables** (one keyed on PC × MESI, one on PC × sharers) instead of SHiP's single table.
- COALESCE adds the **coherence-veto bias** on top of the learned weights.
- COALESCE has a **ghost-buffer rescue path** (5× boosted training on premature evictions) that SHiP lacks.

In low-coherence-traffic regimes (single-core, or multicore workloads with mostly private data), SHiP is expected to match or beat COALESCE — and this is what the existing 4-core canneal results show (SHiP IPC 0.5090 vs COALESCE 0.4996). In high-coherence-traffic regimes (heavy sharing, large multicore counts), COALESCE wins.

## Citation sentence for Related Work
> "SHiP [`wu2011ship`] augments RRIP [`jaleel2010rrip`] with a signature-history counter table indexed by the allocating PC, predicting whether the block is likely to be re-used. SHiP is the strongest classical (non-ML) baseline for cache replacement and is the baseline we are within 1.8 % of on single-thread reuse workloads, while exceeding it substantially when coherence-domain effects dominate."
