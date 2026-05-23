# B9 — PC hashing functions H0, H1

## Claim in the paper
The paper (`latex/paper/coalesce_hipc.tex:62–64`) defines:

- Table 0 indexed by `H_0(PC ⊕ MESI_State)`
- Table 1 indexed by `H_1(PC ⊕ Sharer_Count)`

The exact form of H₀ and H₁ is not given.

## Claim in the code

`simulator/replacement/coalesce/coalesce.cc:59–67`:

```cpp
int PerceptronBrain::get_hash0(uint64_t pc, MESI_State state) {
    uint64_t h = pc ^ 0x9e3779b9;
    h ^= (state << 8);
    return h % PERCEPTRON_TABLE_SIZE;        // % 2048
}

int PerceptronBrain::get_hash1(uint64_t pc, int sharers) {
    uint64_t h = pc ^ 0x85ebca6b;
    h ^= (sharers << 4);
    return h % PERCEPTRON_TABLE_SIZE;        // % 2048
}
```

## Specification (for the paper)

Both hash functions XOR the program counter with a 32-bit irrational-derived constant (the **golden-ratio constants** popularized by Knuth and used widely in hash-mixing functions: 0x9e3779b9 = ⌊2³² · (√5−1)/2⌋ for H₀; 0x85ebca6b = a related constant from MurmurHash3's finalizer for H₁), then XORs in the coherence feature shifted into a separate bit-range, then truncates to the table-size modulus.

Formal definition for the paper:

$$
H_0(\text{PC}, S) = \big((\text{PC} \oplus \text{0x9e3779b9}) \oplus (S \ll 8)\big) \bmod 2048
$$

$$
H_1(\text{PC}, C) = \big((\text{PC} \oplus \text{0x85ebca6b}) \oplus (C \ll 4)\big) \bmod 2048
$$

where S ∈ {0, 1, 2, 3} is the MESI state and C ∈ {0, ..., 8} is the sharer count.

### Why the shifts matter

- **`S << 8`**: pushes the 2-bit MESI state into bits 8–9 of the intermediate hash word, so it does *not* collide with the low-entropy bits of the PC (the bottom 6 bits of PC are typically zero from cache-line alignment).
- **`C << 4`**: pushes the 3-bit sharer count into bits 4–6, again above the line-alignment zeros of the PC.
- **Different golden-ratio constants per table**: ensures the two tables hash the same `(PC, …)` input into *uncorrelated* index streams, which is the whole point of using two orthogonal tables to suppress aliasing.

### Why XOR (not multiply or CRC)

- **Single-gate-depth**: in hardware, an XOR + add is parallel-prefix logic that fits in a single sub-cycle. A multiply or CRC would burn area and latency.
- **Reversibility (per-feature)**: XOR is its own inverse, so the contribution of each feature to the index is exactly preserved; this matters for the perceptron's training direction.

## Wording for the paper

Add a small block to Section II-B (Hashed Perceptron Predictor):

> "Both hash functions XOR-mix the program counter with a 32-bit pseudo-random constant (Knuth-style golden-ratio multipliers, distinct per table) and then XOR in the coherence feature shifted into a non-overlapping bit-range, before truncating modulo the table size: H₀(PC, S) = ((PC ⊕ C₀) ⊕ (S ≪ 8)) mod 2048 with C₀ = 0x9e3779b9, and H₁(PC, C) = ((PC ⊕ C₁) ⊕ (C ≪ 4)) mod 2048 with C₁ = 0x85ebca6b. Using distinct mixing constants per table de-correlates the index streams and is the mechanism by which the dual-table predictor suppresses aliasing relative to a single larger table."

## Open items
- The PC actually passed in is `cache_block::ip` (the IP of the instruction that allocated the block), not the IP of the *current* access. Confirm in the paper that we use *allocator IP*, not *requester IP* — these differ and have different prediction characteristics.
- Sensitivity: try alternative mixing constants (e.g., CRC-32 polynomial, MurmurHash3 finalizer, FNV-1a) to confirm the choice of golden-ratio constants is not a load-bearing assumption.
