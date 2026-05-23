# B8 — MESI state coding (2 bits)

## Claim in the paper
The paper (`latex/paper/coalesce_hipc.tex:51`) lists "MESI Coherence State — 2 bits" as one of the three perceptron features.

## Justification

The MESI protocol [`sorin2011coherence`] defines exactly four stable states per cache line:

| State | Encoding | Meaning |
|---|---|---|
| Invalid (I) | 00 | Line is not present / not valid |
| Shared (S) | 01 | Read-only copy; other caches may also hold copies |
| Exclusive (E) | 10 | Sole valid copy; clean (matches DRAM) |
| Modified (M) | 11 | Sole valid copy; dirty (differs from DRAM) |

4 states ⇒ ⌈log₂ 4⌉ = **2 bits**. This is the minimum representation; there is nothing to "justify" beyond citing the protocol definition.

## Important: COALESCE does not add this overhead

The 2-bit MESI state is **part of the cache block's existing coherence metadata** in any MESI-capable cache, not an additional field introduced by COALESCE. Our implementation extends ChampSim (which is MESI-aware at the protocol layer but does not expose state at the block level) by adding an explicit `state` field to `cache_block` in `simulator/inc/block.h`:

```cpp
enum MESI_State { INVALID = 0, SHARED = 1, EXCLUSIVE = 2, MODIFIED = 3 };
struct cache_block {
    ...
    MESI_State state = INVALID;   // 2 bits in hardware
    uint8_t    sharer_mask = 0;   // 8 bits (see B9)
    ...
};
```

The 2 bits are storage we are now *using* for prediction, but they were already implicitly present in any real coherence-supporting LLC. The paper should make this clear so reviewers don't double-count storage.

## Wording for the paper

In the "Hardware Overhead" subsection (currently `latex/paper/coalesce_hipc.tex` Table II, lines 94–111), add a note:

> "The 2-bit MESI state field is part of the cache block's existing coherence metadata in any MESI-capable LLC; COALESCE consumes this state for prediction but does not introduce it. The reported overhead numbers therefore exclude MESI state storage."

## Reference
- Sorin, Hill, Wood [`sorin2011coherence`] — canonical MESI definition in Ch. 7.

## Open items
- Confirm that ChampSim's stock cache model does *not* already include MESI state at the block level (it appears not to, given the COALESCE patch adds it). If ChampSim's upstream is moving toward MESI support, cite the relevant commit / version.
