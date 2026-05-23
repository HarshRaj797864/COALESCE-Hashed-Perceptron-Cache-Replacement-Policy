# B10 — MESI protocol reference

## Claim in the paper
The paper uses MESI state throughout (Introduction, Architecture § A) but provides no citation for the protocol definition.

## Citation

The canonical reference for MESI (and the MSI/MOESI/MESIF family generally) is **Sorin, Hill, and Wood's "A Primer on Memory Consistency and Cache Coherence"** [`sorin2011coherence`], Synthesis Lectures on Computer Architecture, Morgan & Claypool, 2011. Chapter 7 ("Coherence Protocols") is the section to cite when introducing MESI.

## Wording for the paper

Add to the Introduction (line 37 of `latex/paper/coalesce_hipc.tex`, after "Under the MESI protocol..."):

> "Under the MESI protocol [`sorin2011coherence`], each cache line is in one of four stable states — Modified, Exclusive, Shared, or Invalid — that govern read/write/invalidate behaviour across the coherence domain. Evicting a Modified block forces a writeback to DRAM (200+ cycles, see §III); evicting a Shared block typically triggers invalidation messages to peer caches (interconnect traffic and ordering latency)."

The same `[sorin2011coherence]` citation should also appear:
- In the new Background section (E2) that the strategy doc calls for.
- In the discussion of *why* sharer-count matters as a prediction feature.

## Why this matters for reviewers

Multicore architecture reviewers will reject papers that use MESI as a load-bearing concept without ever citing a coherence-protocol source. Sorin/Hill/Wood is the textbook citation — once it appears in the bibliography and is cited in the Introduction, this weakness is closed.

## Open items
- Decide whether to also cite the original MESI paper (Papamarcos & Patel, ISCA 1984) as a historical reference. Optional — the Synthesis primer subsumes it. For a HiPC submission, the primer alone is sufficient.
