# B7 — Bloom filter parameters (1024-bit, 3 hashes, 256 ghost tags)

## Claim in the paper
COALESCE's per-set ghost buffer uses a 1024-bit Bloom filter with k = 3 hash functions to track recently-evicted addresses, backed by a 256-entry direct-mapped ghost-tag table that stores the PC signature, sharer count, and MESI state of each evicted block. A ghost hit on a subsequent miss triggers a 5× boosted training update (B4) to rescue the wrongly-evicted context.

## Standard FP-rate analysis

For a Bloom filter with **m bits**, **n inserted elements**, and **k hash functions**, the false-positive rate is:

$$P_{FP} \;\approx\; \left(1 - e^{-kn/m}\right)^k$$

The optimal **k** for given **m** and **n** is:

$$k^* \;=\; \frac{m}{n} \ln 2$$

**Substituting m = 1024 and k = 3** gives the design-point occupancy at which our 3-hash choice is optimal:

$$3 = \frac{1024}{n} \ln 2 \quad\Longrightarrow\quad n = \frac{1024 \ln 2}{3} \;\approx\; 237 \text{ entries}$$

At that occupancy:

$$P_{FP}(n{=}237) = \left(1 - e^{-3 \cdot 237 / 1024}\right)^3 \;=\; \left(1 - e^{-0.694}\right)^3 \;\approx\; (0.500)^3 \;=\; 0.125 \;\;(12.5\%)$$

At half occupancy (n = 118):

$$P_{FP}(n{=}118) = \left(1 - e^{-0.346}\right)^3 \;\approx\; (0.293)^3 \;\approx\; 0.025 \;\;(2.5\%)$$

At quarter occupancy (n = 60):

$$P_{FP}(n{=}60) = \left(1 - e^{-0.176}\right)^3 \;\approx\; (0.161)^3 \;\approx\; 0.0042 \;\;(0.42\%)$$

## ⚠️ Important reconciliation with the actual code

The standard FP-rate model **assumes the bit array is periodically cleared**. Inspecting `simulator/replacement/coalesce/coalesce.cc:27–34`:

```cpp
void BloomFilter::insert(uint64_t tag, uint64_t pc, int sharers, MESI_State state) {
    for (int i = 0; i < BLOOM_HASHES; i++) {
        uint64_t hash = (tag ^ pc ^ (i * 0x9e3779b9)) % BLOOM_SIZE;
        bit_array[hash] = true;       // monotonic — never cleared
    }
    uint64_t ghost_hash = (tag ^ pc) % GHOST_CAPACITY;
    ghost_tags[ghost_hash] = CompactGhostEntry(tag, pc, sharers, state);
}
```

**The `bit_array` is never reset after the constructor.** Every eviction insertion monotonically adds bits, so over a long simulation the bit array saturates and the *effective* FP rate of the bit-array layer approaches **100 %**. The lookup path (`coalesce.cc:35–48`) only proceeds to the ghost-tag check *after* the bit array confirms presence, so a saturated bit array means the ghost-tag table becomes the *de facto* arbiter — and the bit-array layer becomes pure overhead.

The `ghost_tags` array (256 entries per sampled set) **does** age out entries: every insertion at hash slot `(tag ^ pc) % 256` overwrites the previous entry there. So the *effective* ghost capacity is bounded at 256 with overwrite-on-collision (not LRU).

**Net behaviour in long runs**: the system reduces to a 256-entry direct-mapped recently-evicted table with overwrite-on-collision, and the 1024-bit bit array is a no-op early-exit that always succeeds.

**Implication for FP-rate reporting in the paper**: The 12.5 % design-point FP rate above is the *nominal* number for a periodically-reset Bloom filter and is what the design *intended*. The actual effective rate as currently implemented is dominated by ghost-tag collisions in the 256-entry table — which behave differently and need a separate analysis (collision probability under uniform hashing: with N evictions inserted into a 256-slot direct-mapped table, the expected fraction of distinct entries surviving is roughly `256 · (1 − (1 − 1/256)^N)` — saturating around 200 distinct survivors after ~600 evictions).

## Two paths forward (decide during Phase 1)

### Path A — patch the implementation to match the design
Add a periodic reset of `bit_array` whenever ghost-tag occupancy crosses ~150 entries (or every N inserts for a configurable N). This restores the standard 12.5 % design-point FP rate and lets us cite the math above verbatim. **Cost**: one small code change; needs re-running canneal to confirm results don't shift materially.

### Path B — re-derive B7 around the actual 256-entry direct-mapped table
Treat the bit array as a saturated early-exit and analyze the ghost mechanism as a direct-mapped table with overwrite-on-collision. The relevant metric becomes the *collision probability* and *lookup-hit rate as a function of recent-eviction distance*, not Bloom FP rate. **Cost**: rewriting this whole document; the paper text needs to drop "Bloom filter" framing and use "compact ghost cache" instead.

> **Recommendation**: Path A. It's cheaper, preserves the existing paper structure, and aligns the implementation with what the design diagrams already claim. The reset itself is a 2-line addition (`std::fill(bit_array.begin(), bit_array.end(), false);` inside `insert()` gated on an occupancy counter).

## Interpretation paragraph for the paper (assuming Path A is taken)

> "The 1024-bit per-sampled-set Bloom filter with k = 3 hash functions is dimensioned for an expected occupancy of approximately 237 evicted addresses, at which the false-positive rate is 12.5 %. A periodic reset triggered at half occupancy keeps the average operating-point FP rate below 5 %. A false positive in the ghost buffer triggers a spurious training event — but since training updates are bounded by 8-bit saturating counters and gated on the perceptron's confidence threshold (B6), an occasional spurious update introduces only minor noise into the weight tables."

## Open items
- **Decide Path A vs Path B**, then update the paper Methodology text accordingly.
- Per-set memory cost reconciliation: 1024 bits (Bloom) + 256 entries × 32 bits (ghost) = **1152 bytes per sampled set**. With 128 sampled sets, total = **144 KB**. This is ~7 % of the 2 MB LLC data array — larger than the 4 KB weight-table claim and worth mentioning honestly in the hardware-cost section (the paper currently understates ghost storage).
- The ghost-tag entry packing is 12-bit pc_sig + 14-bit tag_partial + 3-bit sharers + 2-bit state + 1-bit valid = 32 bits (`coalesce.cc:5–11`). Cross-check that 12-bit pc_sig and 14-bit tag_partial give acceptably-low false-match rates in the *match* step (`coalesce.cc:17–20`); aliasing here is a second-order FP source independent of the Bloom layer.
