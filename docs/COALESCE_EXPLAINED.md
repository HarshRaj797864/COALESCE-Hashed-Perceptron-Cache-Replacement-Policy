# COALESCE — A Walkthrough

> A narrative explainer of what COALESCE is, why it works, how the pieces fit together, and where the rough edges are. Written for the project owner (Harsh) and any future collaborator — not for HiPC reviewers (the paper is for them).

---

## 1. The problem in 30 seconds

Multicore processors share a Last-Level Cache (LLC). When the LLC fills up and a new block needs to come in, **a replacement policy** picks which existing block to throw out. Every existing policy in the literature (LRU, SRRIP, SHiP, Hawkeye, Mockingjay, …) makes that choice based on one question: **"which block is least likely to be reused?"**

That question has a hidden assumption: *all evictions are equally cheap*. They're not. In a coherent system:

- Evicting a **Modified** block forces a **DRAM writeback** (~200 cycles + interconnect).
- Evicting a **Shared** block forces **invalidation messages** to every peer cache that holds a copy, and any of those cores that re-touches the line pays a DRAM re-fetch.
- Evicting an **Exclusive** clean block is silent.
- Evicting an **Invalid** block costs nothing.

So two blocks with identical reuse probability can have wildly different *eviction costs*. COALESCE's bet is: **if you make the replacement policy aware of coherence cost, not just reuse, you save real cycles** — especially in workloads where many cores share data heavily.

That's the whole pitch.

---

## 2. Quick recap of cache replacement, so the rest makes sense

Levels of sophistication, in roughly chronological order:

1. **LRU** (least-recently-used). Throw out the block you touched longest ago. Simple, works OK for many workloads, falls apart for streaming/thrashing.
2. **SRRIP / DRRIP** [Jaleel 2010]. Give each block a 2-bit "re-reference prediction" counter. Insert at the conservative end; promote on hit; evict from the aggressive end. DRRIP adds *set-dueling*: try two insertion policies on a few "leader sets," let the winner take over.
3. **SHiP** [Wu 2011]. Same RRIP machinery, but learn the insertion counter value from the **PC** of the instruction that allocated the block. A small signature-history table (SHCT) per PC tracks "did blocks I allocated previously get reused?"
4. **Hawkeye / Mockingjay** [Jain 2016 / Shah 2022]. Compute **Belady's optimal policy offline over a sliding window** (using an algorithm called OPTgen), use it as a training label, and learn a PC-indexed predictor that approximates it online.
5. **Perceptron-based** [Jiménez 2017, "Multiperspective Reuse Prediction"]. Replace SHCT's single signature with a **hashed-perceptron predictor** — multiple small weight tables indexed by different feature hashes (PC, page offset, recency tags, …), summed at decision time.

**COALESCE belongs to category 5**, with two new twists:
- The feature set includes **MESI state** and **sharer count** (no other policy in the lineage uses these).
- A **coherence-veto bias** is added to the perceptron vote to make Modified and heavily-shared blocks stickier than their predicted reuse alone would suggest.

That's the entire conceptual addition. The rest is engineering.

---

## 3. How a hashed perceptron predictor works (in our context)

A perceptron in this microarchitecture sense is **not** the textbook gradient-descent thing. It is:

- A **table of signed 8-bit counters** indexed by a hash.
- A *prediction* = a sum of counters read from one or more tables.
- A *training step* = increment or decrement those counters by 1, clamped to [−128, +127].

That's it. There is no learning rate, no softmax, no backprop. The "learning" is just biased coin-flipping: every time a context produces a hit, that context's counter goes up by 1; every time it produces a wrongly-evicted miss, it goes up by 5 (the ghost-buffer boost — see below). Saturation handles the rest.

### Why it works at all

The reason it works is the **hashed-feature** part. We don't have one giant table indexed by (PC × state × sharers), which would be huge and full of empty cells. We have **two small tables** indexed by orthogonal hashes:

```
Table 0[h0(PC, MESI_state)]      ← captures "this PC × this coherence state usually..."
Table 1[h1(PC, sharer_count)]    ← captures "this PC × this sharer count usually..."

Vote = Table 0[h0] + Table 1[h1]
```

Each table on its own would alias a lot (different (PC, state) pairs colliding in the same slot). But because the two tables hash *different feature combinations* of the same input, their aliasing patterns are uncorrelated. Adding the two counters at decision time gives a vote that is much harder to fool than either table alone.

This is the **multiperspective** trick from Jiménez 2017, scaled down to two tables for hardware simplicity.

### What the vote means

Positive vote → predict reuse (protect the block).
Negative vote → predict dead (evict it).
Zero or near-zero → predictor is unsure.

At eviction time, we score every candidate in the set, add the coherence bias, and **evict the one with the lowest score**.

---

## 4. The three things COALESCE actually adds

### 4.1 Coherence features in the perceptron input

`block.h` was extended with two fields per cache line:

```cpp
MESI_State state;       // INVALID / SHARED / EXCLUSIVE / MODIFIED  (2 bits)
uint8_t sharer_mask;    // bitmask of which cores currently hold the line  (8 bits)
```

The sharer count is `popcount(sharer_mask)`, decoded inline.

These two fields feed directly into the hash inputs (B9 documents the exact functions). The predictor can therefore learn things like:

- "When this PC allocates a Modified block, the block tends to be reused — protect it."
- "When this PC allocates a block with 3+ sharers, it's worth retaining even if individual reuse seems low."

A coherence-blind predictor (SHiP, Hawkeye, Mockingjay) cannot learn these patterns because the features aren't visible to it.

### 4.2 The coherence-veto bias

After computing the perceptron vote, *if the raw vote is positive* (the predictor already thinks the block is reusable), we add a static bias to make it even less attractive as a victim:

```cpp
if (raw_vote > 0) {
    if (block.state == MODIFIED)    final_vote += 40;
    if (sharer_count >= 2)          final_vote += 20 * sharer_count;
}
```

The "raw_vote > 0" gate is important and is one of the subtle design choices: we don't *protect* blocks the predictor already thinks are dead, because that would override the learning. We only *reinforce* the predictor's positive verdicts when there's coherence weight behind them.

> ⚠️ **Note**: The paper currently claims biases of +150 and +75 with no positive-vote gating; the code uses +40 and +20×sharers with the gating. This is OPEN_DECISIONS item 1 — Phase 2D bias sweep will reconcile.

### 4.3 The ghost-buffer rescue path

This is the "reinforcement learning" half of the algorithm. Without it, the predictor can only learn from successes (cache hits). The ghost buffer lets it learn from *failures* — specifically, evictions that turned out to be wrong.

How it works:

1. When we evict a block from a sampled set, we record it in a per-set ghost buffer (a 1024-bit Bloom filter + a 256-entry direct-mapped tag table).
2. The next time we get a miss in that set, we check whether the missing address was recently evicted. If yes — **ghost hit** — we know the predictor made a mistake.
3. On a ghost hit, we apply the training step **5 times** in the "this context predicts reuse" direction, with the context recovered from the ghost-buffer entry (its PC, sharer count, and MESI state at eviction time).

This rescue path is what lets the predictor recover from over-aggressive eviction patterns. Without it, the predictor would only get positive examples and would slowly drift toward "everything is reusable."

> ⚠️ **Note**: There's a real bug here — the Bloom filter never resets, so it monotonically saturates. See OPEN_DECISIONS item 2.

---

## 5. Trace through a single victim selection

Suppose the 8-core configuration is running canneal, the LLC has 2048 sets × 16 ways, and we need to bring in a block for set 137 which is full. Walk through what `find_victim()` does:

1. For each of the 16 ways in set 137:
   - Read the existing block's `ip` (PC of allocator), `state` (MESI), and `sharer_mask`.
   - Decode `sharer_count = popcount(sharer_mask)`.
   - Compute `h0 = ((ip ⊕ 0x9e3779b9) ⊕ (state << 8)) % 2048`.
   - Compute `h1 = ((ip ⊕ 0x85ebca6b) ⊕ (sharer_count << 4)) % 2048`.
   - Read `raw_vote = table0[h0] + table1[h1]`. (Both 8-bit signed; sum is in [-256, +255].)
   - If `raw_vote > 0`, add coherence bias: +40 if MODIFIED, +20×sharer_count if sharer_count ≥ 2.
   - Track the minimum final_vote seen so far and which way had it.
2. Return the way with the minimum final_vote — that's the victim.
3. **If set 137 is in the sampled set** (137 % 16 ≠ 0 → not sampled in this case): nothing else happens.
   **If set 137 had been sampled** (say set 144): insert the victim's address into the ghost buffer of set 144 for later potential rescue.

Total work: 16 cache-line reads of metadata, 32 table lookups, 16 small additions, an argmin. Easily one cycle in real hardware.

---

## 6. Trace through training

Same example, set 137 (unsampled). A few accesses later we get a hit on way 5.

`update_replacement_state()` is called with `(set=137, way=5, hit=true)`. Because set 137 is not sampled, **nothing happens**. The hit doesn't train. The predictor still uses this set's reads for decisions — it just doesn't write.

Now consider an access to set 144 (sampled), and assume way 8 already had a block from the same context. We get a hit on way 8.

1. `is_sampled[144] = true`, so we proceed.
2. Read way 8's actual current metadata (`ip`, `state`, `sharer_mask`) — note we re-read the *current* state, not whatever it was at allocation.
3. Compute the current vote for that context.
4. Call `train(positive=true, vote=current_vote)`:
   - Check if it was a misprediction (vote ≤ 0 when we got a positive outcome).
   - Check if it was low-confidence (|vote| ≤ 35).
   - If either, increment both `table0[h0]` and `table1[h1]` by 1 (clamped at +127).

The strict-confidence gating means a high-confidence positive prediction (vote ≥ 36) doesn't retrain on hit. This avoids saturating popular contexts forever and keeps the weights in a useful dynamic range.

### Ghost-hit training

Same set 144, a few accesses later. We get a miss. The address is not in any way of set 144, but we check the ghost buffer:

1. Hash the address into the Bloom filter — if all 3 bits are 0, definitely not a ghost. Move on.
2. If all 3 bits are 1, check the ghost-tag table at slot `(tag ⊕ pc) % 256`.
3. If the tag matches, we have a ghost hit. Recover the *original* PC, sharer count, and MESI state from when the block was evicted.
4. Call `train(positive=true, ...)` **5 times** with those recovered features.

The 5× repeat is the "this mistake mattered" amplifier. In practice, the train() function's mispredict/low-confidence gate often kicks in after the first 1–2 iterations (the weights have already moved past the low-confidence band), so the effective boost is closer to 2–3× — see B4.

---

## 7. What the existing results actually mean

Three numbers from the paper, decoded honestly:

### 7.1 4-core, 50M instructions, canneal

| Policy | IPC | LLC misses |
|---|---|---|
| LRU | 0.4023 | 684,771 |
| DRRIP | 0.5072 | 456,998 |
| SHiP | 0.5090 | 452,631 |
| **COALESCE** | **0.4996** | **539,738** |

**Truthful reading**: COALESCE is **fourth of four** by both IPC and miss count. DRRIP and SHiP each have ~17% fewer LLC misses than COALESCE.

The paper currently frames this as "within 1.8% of SRRIP" (where SRRIP is interpolated, not actually run) and calls it a "+24.2% over LRU" win. Both framings are technically true but hide the ordering.

**Why COALESCE doesn't win at 4-core**: at 4 cores with a 2 MB LLC (512 KB per core), there's enough cache for canneal's working set that *coherence pressure is moderate*. In that regime, the policy is mostly competing on reuse prediction — and SHiP's PC-signature counter is well-tuned for canneal's access patterns. COALESCE's coherence-awareness is dead weight when coherence isn't the bottleneck.

This is **not a bug**. It's expected behaviour, and the paper rewrite needs to frame it honestly: COALESCE is the right tool for high-coherence-pressure regimes, the wrong tool for low-pressure regimes, and at 4-core canneal we are at the boundary.

### 7.2 8-core, 100M instructions, canneal

| Metric | COALESCE | SRRIP |
|---|---|---|
| Total cycles | 415.9 M | 620.6 M |
| Bottleneck IPC (CPU 1) | 0.241 | 0.162 |
| Bottleneck IPC (CPU 6) | 0.240 | 0.161 |
| Worker IPC (CPU 0) | 2.088 | 2.120 |
| Worker IPC (CPU 5) | 2.027 | 2.073 |

**Truthful reading**: COALESCE finishes the whole 8-core workload **33% faster than SRRIP**. The win comes from the *bottleneck cores* (CPUs 1 and 6 — the ones doing the heavy shared-pointer traversal in canneal's annealing loop) jumping from ~0.16 IPC to ~0.24 IPC. The worker cores (CPUs 0 and 5) see a tiny regression (~1.5%). System-wide, COALESCE saves ~205 million cycles.

This is a real result and the strongest selling point in the paper.

**The big methodological gap**: the 8-core experiment compared COALESCE only to SRRIP. We didn't run LRU, DRRIP, SHiP at 8-core. A reviewer's first question will be: "did you cherry-pick the weakest baseline?" Phase 2A (Week 1–2) fills this gap.

### 7.3 What we should and shouldn't be claiming

| Claim | Status |
|---|---|
| "COALESCE wins at high-contention multicore" | True, but only one workload and one baseline so far |
| "COALESCE is competitive at low-contention multicore" | True at 4-core canneal |
| "Coherence-aware features are useful in cache replacement" | The data so far supports this, modulo the gaps above |
| "COALESCE is the new state of the art" | **Don't say this** — we haven't compared to Hawkeye or Mockingjay |
| "Hardware budget under 5 KB" | **Currently false** — actual storage is ~148 KB once per-sampled-set Bloom + ghost storage is counted. See OPEN_DECISIONS item 3. |

---

## 8. Where COALESCE sits relative to the lineage

Mental map of the predictor family:

```
1966   Belady's MIN ─────────────────────────────────► theoretical optimum
                                                              │
1980s  LRU ──────────────────────────────────────► standard online baseline
                                                              │
2001   Jiménez & Lin perceptron ────────► branch prediction  │
                                                  │           │
2010   Jaleel RRIP / DRRIP ──────────────────────►│   ────────│
                                                  │           │
2011   Wu SHiP ────────► PC signature + RRIP ────►│           │
                                                  │           │
2016   Jain Hawkeye ────► OPTgen labels + PC predictor ──────►│
                                                  │           │
2017   Jiménez Multiperspective ────► perceptrons for replacement
                                                  │
2019   Shi Glider ──────────► distilled LSTM
                                                  │
2022   Shah Mockingjay ─► reuse-distance regression
                                                  │
2025   Wu CAMP ────► concurrency-aware perceptron
                                                  │
**2026  COALESCE ───► Jiménez 2017 + MESI state + sharer count + coherence-veto bias + ghost-rescue training**
```

The "new" elements in COALESCE are coherence-domain features and the coherence-veto bias. Everything else is borrowed from the lineage above with full citation.

---

## 9. Plain-English summary of the open issues

Detailed list with options: see [`docs/OPEN_DECISIONS.md`](OPEN_DECISIONS.md).

Top-line:

1. **Bias values disagree**: paper says +150 / +75, code uses +40 / +20×sharer. Phase 2D sweep will tell us which is actually right; in the meantime, the paper text needs a correction once we decide.
2. **Bloom filter doesn't reset**: it monotonically fills, so over long simulations the bit-array layer becomes a no-op. Two-line fix to add a periodic reset.
3. **Hardware overhead claim is wrong by ~30×**: paper says "< 5 KB total"; actual is ~148 KB once you count per-sampled-set Bloom (128 sets × 128 B = 16 KB) and ghost tags (128 sets × 1024 B = 128 KB). This needs honest restatement before submission.
4. **θ (confidence threshold) is undefined in paper**: code has THRESHOLD = 35. Easy fix to add to the paper text.
5. **Tesla K80 line in paper**: ChampSim is CPU-only; the K80 mention is wrong. Delete it.
6. **Worker-core regression is real**: at 8-core, CPUs 0 and 5 have slightly lower IPC under COALESCE. Paper acknowledges briefly; rewrite needs to quantify the trade-off.
7. **Bibliography has 5 entries**: HiPC reviewers expect 15+. The references.bib I built (`coalesce_paper/citations/references.bib`) has 18 — paper rewrite just needs to wire them in.

---

## 10. What comes next (Phase 2 — experiments)

The HiPC sprint plan (in `docs/PUBLICATION_STRATEGY.md`) breaks Phase 2 into five sub-phases:

- **2A — Core Baseline Matrix** (Week 1–2): run all 5 policies (LRU, SRRIP, DRRIP, SHiP, COALESCE) on canneal + fluidanimate + dedup at 4-core and 8-core. Fills the "single baseline / single workload" gaps.
- **2B — Scaling Study** (Week 3): same on 4 / 8 / **16** cores to show the trend.
- **2C — LLC Size Sensitivity** (Week 3): vary LLC from 1 MB to 8 MB at 8-core.
- **2D — Bias / Perceptron Sweep** (Week 3): finally derive the +150/+40 question empirically, plus an ablation (PC-only / +MESI / +sharers / full).
- **2E — Statistical Rigor** (Week 4): re-run the main configs 3× with different seeds.

Phase 1 (citations) finishes in parallel. Phase 3 (paper rewrite) starts Week 2 and folds in Phase 2 results as they land.

---

## 11. If you came here cold and want to read the code

Recommended order:

1. **`simulator/replacement/coalesce/coalesce.h`** (66 lines) — see all the data structures and constants on one screen.
2. **`simulator/replacement/coalesce/coalesce.cc`** (170 lines) — read top-down. The first half is the BloomFilter and PerceptronBrain implementations; the second half is `find_victim()` and `update_replacement_state()`.
3. **`simulator/inc/block.h`** — the MESI_State enum and the `sharer_mask` field on `cache_block`.
4. **`simulator/btp_config.json`** and **`btp_8core_config.json`** — see how the LLC geometry and core count are wired up.
5. **`simulator/config/parse.py`** lines 331–335 — the DRAM defaults that determine the 200-cycle row-miss latency we cite.

After that, this file plus the per-justification docs under `coalesce_paper/citations/` should fill in the "why" behind every parameter.

---

# Deep dive: the hard concepts in full

> Everything below is "you asked me to teach you everything." If something is already obvious to you, skim. Each subsection is self-contained.

## A. The hashed perceptron, mathematically

### A.1 What a saturating counter really is

A saturating counter is the smallest possible state machine that can "learn" something. With 8 bits signed: state ∈ [−128, +127]. Train up (+1) on positive evidence, train down (−1) on negative evidence, **clamp at the boundaries instead of wrapping**.

Why this matters:
- **Hysteresis**: a single training event can't flip a confident prediction. A counter at +120 needs 121 negative events in a row to flip to negative. This is the *memory* of the predictor.
- **Bounded influence**: no single context can dominate the table. If PC X has hit a thousand times in a row, its counter is +127 (saturated), exactly the same as a PC that hit 128 times. The next time PC X is evicted, the perceptron still treats it as "strong reuse signal" but no stronger than any other saturated context.
- **No memory of magnitude**: it knows *how confidently* something is positive/negative, but it has *forgotten how many times* it was trained. This is good — it prevents stale stats from outweighing recent ones forever.

The alternative (unbounded counters, or floats with a learning rate) would need way more bits per entry, would drift, and would need a separate decay mechanism. Saturating counters get all of that for free.

### A.2 How dual orthogonal tables suppress aliasing

Suppose we have one table of 4096 entries, indexed by `hash(PC, state, sharers) % 4096`. With ~10,000 unique (PC, state, sharers) tuples in a workload, the average bucket holds ~2.4 tuples — meaning training events from different contexts collide and partially cancel. This is **aliasing**, and it caps the predictor's effective resolution.

Now split into two tables of 2048 entries each:
- Table 0: indexed by `hash0(PC, state) % 2048`
- Table 1: indexed by `hash1(PC, sharers) % 2048`

The total storage is the same (4096 × 8-bit entries). But the *aliasing patterns are uncorrelated*:
- Two contexts that collide in Table 0 (same `hash0(PC, state)`) almost certainly do **not** collide in Table 1 (because `hash1` uses different bits and different mixing constants).
- The vote = Table 0 + Table 1 sums two **independent** sources of signal. Each source is noisy from aliasing, but the noise is uncorrelated, so the sum has lower noise *relative to* the signal.

Concrete: if Table 0 alone has 70% accuracy on a benchmark, Table 1 alone also has 70%, but their errors are uncorrelated → the sum can reach ~85% accuracy. This is the same statistical principle as ensemble methods in ML.

The fancier name is *Bloom filter principle*: independent hash functions over the same input give independent collision patterns. Jiménez 2017's "multiperspective" paper takes this much further (eight or more tables, each looking at a different feature combination).

### A.3 The training rule, derived

The train() function does this:

```
def train(positive, current_vote):
    mispredicted = (positive and current_vote ≤ 0) or (not positive and current_vote > 0)
    low_confidence = |current_vote| ≤ THRESHOLD     # THRESHOLD = 35
    if mispredicted or low_confidence:
        table0[h0] += (+1 if positive else −1)
        table1[h1] += (+1 if positive else −1)
        # clamp to [MIN_WEIGHT, MAX_WEIGHT]
```

Three logical pieces:

1. **"On misprediction, always train"** — if the predictor said "evict this" (vote ≤ 0) but the block turned out to be reused, push the weights positive. This is the *error-correction* path.
2. **"On low confidence, train even if correct"** — if the predictor said "this is reusable" with vote = +5 (just barely positive) and was correct, still push the weight up to *strengthen* the confidence. This is the *confidence-building* path.
3. **"On high-confidence correct prediction, don't train"** — if the vote was +50 and the prediction was correct, we already know this context. Training again would just saturate the counter for no information gain, and risk *displacing* a more useful update.

This is a textbook perceptron training rule (from Jiménez & Lin 2001). The theta=35 value picks the confidence band as a fraction of the full vote range; see B6.

---

## B. The cache replacement lineage, expanded

### B.1 LRU and why it fails

LRU keeps a per-set ordered list of how recently each line was touched. On eviction, pick the line at the bottom (oldest). In hardware it's a small encoded "stack age" per line (4 bits for a 16-way set).

LRU's fatal flaw: it's optimal for **temporal locality**, terrible for **scan resistance**. If your workload streams through data once (no reuse), every access is a miss, and LRU happily evicts whatever was just useful to make room for the stream. SRRIP was designed specifically to fix this.

### B.2 RRIP, SRRIP, BRRIP, DRRIP

Replace LRU's "age order" with a per-line 2-bit **RRPV** (Re-Reference Prediction Value):
- 0 = predicted soon
- 1, 2 = medium-term reuse
- 3 = predicted far / dead

Behavior:
- **On hit**: set RRPV to 0 (promote to "soon").
- **On miss / fill**: pick a line with RRPV = 3 to evict. If no line has RRPV = 3, increment all RRPVs in the set and try again.
- **On insertion**: this is where the variants differ.

The three insertion policies:
- **SRRIP** (Static): insert at RRPV = 2 — "moderate confidence in reuse." Good default.
- **BRRIP** (Bimodal): insert at RRPV = 3 most of the time (with low probability insert at 2). Aggressively bias toward eviction. Good for scan-heavy workloads.
- **DRRIP** (Dynamic): **set-dueling** — at simulator startup, a small number of "leader sets" are pinned to SRRIP, another small number pinned to BRRIP, and the rest are "follower sets." A single counter tracks "which leader policy has fewer misses?" and the followers adopt the winner. The counter saturates and decays slowly so the choice adapts to phase changes.

DRRIP is the *origin* of the set-dueling pattern, which COALESCE inherits as set-*sampling* (slightly different — we sample sets for *training*, not for *policy A vs B comparison*, but the storage discipline is the same).

### B.3 SHiP — the bridge to ML

SHiP says: instead of using one insertion policy globally, **learn per-PC which insertion RRPV to use**. The PC that allocated the block is hashed into a Signature History Counter Table (SHCT) of small 3-bit saturating counters. On miss/fill, look up the SHCT entry for the allocating PC:
- High counter (PC's blocks usually get reused) → insert at RRPV = 2.
- Low counter (PC's blocks usually die) → insert at RRPV = 3.

Training: on hit, increment the SHCT entry for the block's allocator PC. On eviction (if the block was never reused), decrement.

This is a tiny single-table perceptron, conceptually. Jiménez's 2017 multiperspective and our COALESCE are the multi-table generalization.

### B.4 Hawkeye / Mockingjay — Belady-as-supervision

The breakthrough idea: we cannot run Belady's MIN online (needs future), but we can run it on the *recent past* (a sliding window of the trace we've already seen). For each access, we ask "given the next N accesses we've now seen, *would* MIN have evicted this block in that window?" That gives us a binary label per block: cache-friendly or cache-averse.

Now train a PC-indexed predictor to output that label given the PC of the allocator. At runtime, use the predictor to decide insertion priority. This is **Hawkeye**.

Mockingjay refines: instead of binary cache-friendly/averse, regress the actual reuse distance Belady would assign. The predictor outputs a number, and the policy evicts the block with the largest predicted reuse distance.

OPTgen (the sliding-window-Belady algorithm) is non-trivial but well-defined; it's the main reason Hawkeye is hard to implement (~1–2 weeks of engineering).

### B.5 COALESCE in this picture

COALESCE is the **first paper to add coherence features** to this lineage. The substrate (hashed perceptron, dual tables, set sampling, saturating counters, ghost-buffer rescue) is borrowed from Jiménez 2017. The novelty is the input features and the coherence-veto bias.

We are not competing on the *single-thread reuse* axis — Hawkeye/Mockingjay are stronger there. We are competing on the *multicore coherence cost* axis, where they don't even play.

---

## C. Cache coherence at the level you need to defend the paper

### C.1 Why coherence exists

Each core has private L1 and L2 caches. If core 0 reads address X into its L1, and then core 1 writes to X, core 0's cached copy becomes stale. **Coherence** is the mechanism that ensures all cores see a consistent view of memory, even when their private caches each hold copies.

The two main families:
- **Snoop-based**: every memory transaction is broadcast on a shared bus; each cache snoops the bus and updates its own state. Doesn't scale past ~16 cores because the bus becomes a bottleneck.
- **Directory-based**: a central directory tracks which caches hold copies of each line. Operations consult the directory. Scales to hundreds of cores. Used in everything modern (server chips, GPUs).

Our work assumes directory-based MESI (the directory has the sharer info we use).

### C.2 MESI state transitions (the parts that matter for COALESCE)

The four states again:
- **M (Modified)**: this cache has the only valid copy AND it's dirty (differs from DRAM).
- **E (Exclusive)**: this cache has the only valid copy AND it's clean.
- **S (Shared)**: this cache has a valid copy, but so do others. Always clean.
- **I (Invalid)**: this cache slot doesn't hold a valid copy of anything.

Key transitions:
| From | Event | To | Cost |
|---|---|---|---|
| M | Eviction | I | **DRAM writeback** (~200 cycles bus + DRAM time) |
| M | Peer read | S | Forward dirty data to peer; flush to DRAM |
| M | Peer write | I | Forward dirty data; invalidate self |
| E | Local write | M | Free (no bus transaction needed) |
| E | Peer read | S | Forward clean data |
| E | Eviction | I | Silent (no DRAM, no bus) |
| S | Local write | M | **Invalidation broadcast** to all other sharers |
| S | Peer write | I | Receive invalidation |
| S | Eviction | I | Silent |
| I | Local read miss | S or E | DRAM read or forward from peer |

The two costly transitions for *us* are:
1. **M → I via eviction**: forces a writeback. This is what +40 (Modified bias) is meant to penalize.
2. **S → I via peer write**: invalidation broadcast scales with sharer count. This is what +20×sharers is meant to penalize indirectly (if you keep heavily-shared lines, they're worth retaining because re-fetching them after invalidation is expensive).

### C.3 The sharer mask and how it's tracked

In a real directory-based system, the directory keeps a bitvector per line: one bit per L2 cache, set if that cache holds a copy. With 8 cores, this is an 8-bit field per cached line — exactly what `cache_block::sharer_mask` is in our extension.

In ChampSim (which is normally coherence-oblivious at the LLC level), this is something COALESCE *adds*. The protocol-level coherence in ChampSim's underlying model already exists, but it doesn't expose state at a per-line granularity in the way we need; the extension makes that data accessible to the replacement policy.

> Open question (OPEN_DECISIONS #6): are *all* coherence events (especially invalidations from peer writes) being delivered to the COALESCE module's training path, or only writebacks at eviction? This is the audit we need to do.

---

## D. The simulator side: ChampSim, traces, and what we actually measure

### D.1 Trace-driven vs. execution-driven simulators

Two ways to simulate a processor:
- **Execution-driven** (gem5, MARSS, ZSim): actually executes the program inside the simulator, modeling pipeline state cycle-by-cycle. Slow (10⁴×–10⁵× slower than native), but you can simulate weird microarchitectures and observe wrong-path execution.
- **Trace-driven** (ChampSim): take a pre-recorded trace of the *committed instruction stream* and feed it to a microarchitectural model. Much faster (10–100× faster than execution-driven). Limitation: you cannot model speculation correctly because the trace is the committed path, not the speculative path.

ChampSim is trace-driven. For cache replacement research this is fine — the LLC sees committed memory accesses regardless of whether speculation was right or wrong, and that's what we're studying.

### D.2 Intel PIN and MT-Sync traces

**PIN** is Intel's dynamic binary instrumentation framework. You write a "pintool" (a small C++ plugin) that gets called on every executed instruction. We use PIN to record the committed memory accesses of a real binary into a `.champsimtrace` file.

For multicore traces, you can't just record each thread independently — coherence orderings between threads matter. The **MT-Sync tracer** in `simulator/tracer/` is a custom pintool that uses PIN's synchronization primitives to ensure that the per-thread traces, when replayed by ChampSim, preserve the inter-thread happens-before ordering from the original execution.

This matters for our coherence claims: if the trace ordering doesn't preserve sharing patterns, then ChampSim won't see realistic invalidation traffic and our policy looks better (or worse) than it should. The MT-Sync tracer is the mechanism that gives us valid sharing traces.

> This is C2 in the strategy doc — we currently don't *validate* that the MT-Sync tracer actually preserves coherence ordering. Best-practice would be to run a known-sharing-pattern microbenchmark through the tracer and confirm the recorded trace reproduces the expected M/E/S/I transition counts.

### D.3 PARSEC benchmarks: what they actually do

PARSEC is a multithreaded benchmark suite from Princeton (Bienia et al., PACT 2008). The three we use:

- **canneal**: simulated-annealing placement optimizer for chip layouts. Heavy random pointer-chasing on a large shared graph. Many threads concurrently read+swap pairs of cells. **High coherence pressure**: lots of shared data, frequent writes to shared cells → frequent invalidations. This is the workload where COALESCE wins; it's not a coincidence.
- **fluidanimate**: SPH (smoothed particle hydrodynamics) fluid simulation. Particles partitioned into spatial cells; threads work on cell regions but share particles on cell boundaries. **Moderate coherence pressure** — heavy compute but with structured sharing patterns.
- **dedup**: data deduplication pipeline (compression). Multiple stages connected by queues; each stage runs in its own thread group. **Mixed pressure** — producer-consumer sharing, hash-table lookups, lots of cache pressure but more on capacity than coherence.

The three together give a spectrum: canneal (coherence-heavy) → fluidanimate (mixed) → dedup (capacity-heavy). If COALESCE wins on canneal and loses on dedup, the story is "coherence-aware policies for coherence-heavy workloads." If it wins on all three, that's a stronger story (less likely).

### D.4 Warmup vs. measurement

ChampSim runs in two phases:
1. **Warmup**: run N instructions through the model with no statistics collection. Purpose: fill caches, train predictors, populate page tables. Without warmup, every cache starts empty and the early stats are dominated by cold misses.
2. **Measurement**: run M more instructions with stats on. Report IPC, miss rates, etc.

Our configs use:
- 4-core: 200M warmup + 50M measurement per core
- 8-core: 1B warmup + 100M measurement per core

The 1B warmup at 8-core is **large** — it's there because COALESCE's perceptron needs time to converge before measurement begins. Without enough warmup, you'd be measuring partly-untrained predictor performance.

### D.5 Row-buffer hits and DRAM timing

DDR4 DRAM has three relevant timing parameters for a single access:
- **tRCD** (RAS-to-CAS delay): time from "open this row" to "now I can read columns." ~15 ns.
- **tCAS** (column access strobe): time from "give me column X" to data appearing on the bus. ~15 ns.
- **tRP** (row precharge): time to *close* a row before opening a different one in the same bank. ~15 ns.

A DRAM access has two cases:
- **Row-buffer hit**: the requested address is in the row currently open in the bank. Pay only tCAS (~15 ns). ~60 CPU cycles at 4 GHz.
- **Row-buffer miss**: the requested row is different. Pay tRP (close current) + tRCD (open new) + tCAS = ~45 ns. ~180 CPU cycles at 4 GHz.

In practice, with queuing latency and the bus turnaround time, row-miss observed latency is 200–300 cycles. This is the source of the "200+ cycles" claim in our paper.

The ChampSim DRAM model implements all of this (see `simulator/src/dram_controller.cc`). The defaults match a DDR4-3200 part with reasonable timings (B1 documents all of this).

---

## E. Glossary

| Term | Definition |
|---|---|
| **LLC** | Last-Level Cache. The cache closest to DRAM. In our config: 2 MB shared. |
| **RRPV** | Re-Reference Prediction Value. RRIP's 2-bit per-line counter. |
| **SHCT** | Signature History Counter Table. SHiP's per-PC small-counter table. |
| **OPTgen** | The sliding-window algorithm Hawkeye uses to compute Belady labels. |
| **NUCA** | Non-Uniform Cache Access. A distributed LLC where access latency depends on which slice holds the block. |
| **MSHR** | Miss Status Holding Register. Tracks outstanding cache misses to merge duplicate fetches. |
| **MESI / MOESI / MESIF** | Cache coherence protocols. MESI has 4 states. MOESI adds Owned (dirty-shared). MESIF (Intel) adds Forward (one designated sharer responds). |
| **Snoop** | Coherence mechanism where each cache observes a shared bus. |
| **Directory** | Coherence mechanism where a central table tracks which caches hold each line. |
| **Sharer** | A cache that currently holds a (necessarily Shared, Exclusive, or Modified) copy of a line. |
| **Invalidation** | A message telling a cache to evict its copy of a line so another core can write. |
| **Writeback** | Sending a dirty line's data back to DRAM (or a lower-level cache). |
| **Row buffer** | The currently-open DRAM row whose data is staged in the sense-amplifiers. Hits are fast; misses pay tRP + tRCD. |
| **Set sampling** | Updating predictor state only on a fixed fraction of sets. Saves write-port energy. |
| **Set dueling** | Running two policies on different sample sets and letting the winner take over the rest. DRRIP's mechanism. |
| **Ghost buffer / ghost cache** | A small table of recently-evicted addresses, used to detect "I shouldn't have evicted that." Drives COALESCE's rescue training. |
| **Bloom filter** | A probabilistic set-membership data structure. k hash functions into m bits; false-positives possible, false-negatives not. |
| **Aliasing** | Two different inputs hashing to the same predictor table slot, causing their training to interfere. |
| **Saturating counter** | A signed integer in [a, b] where ±1 updates clamp at the boundaries instead of overflowing. |
| **Allocator PC** | The program counter of the instruction that caused a cache line to be filled. (Distinct from the requester PC of a later access.) |
| **PARSEC** | Princeton Application Repository for Shared-Memory Computers. A multithreaded benchmark suite. |
| **canneal / fluidanimate / dedup** | The three PARSEC benchmarks we evaluate. |
| **PIN** | Intel's dynamic binary instrumentation framework. We use it to record execution traces. |
| **Trace-driven simulator** | A simulator that consumes a pre-recorded committed-instruction trace instead of executing code itself. ChampSim is trace-driven. |
| **Warmup** | Pre-measurement simulation phase used to fill caches and train predictors so we measure steady-state, not cold-start. |
| **IPC** | Instructions Per Cycle. Higher is better. |
| **Belady's MIN** | The provably-optimal *offline* replacement policy: evict the block whose next access is furthest in the future. Cannot be run online; used as a training label by Hawkeye/Mockingjay. |
| **ROB** | Re-Order Buffer. The structure in an out-of-order CPU that holds in-flight instructions. ChampSim default: 352 entries. |
| **Hashed perceptron** | A predictor that uses a small table of saturating-counter weights, indexed by hashed features. Sum of looked-up weights = prediction. |
| **Multiperspective** | The version of hashed perceptron predictors that uses multiple parallel tables with orthogonal feature hashes. Jiménez 2017. |
| **Coherence wall** | Informal term we use for the phenomenon that conventional cache policies leave performance on the table by ignoring coherence costs. The motivation for COALESCE. |
