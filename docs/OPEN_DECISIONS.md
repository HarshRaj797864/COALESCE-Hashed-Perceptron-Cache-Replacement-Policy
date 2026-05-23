# Open Decisions

> **Purpose**: every design discrepancy, bug, or open question surfaced during Phase 1 — with options laid out so the project owner can pick and proceed.
>
> **Format per item**: Problem · Impact · Options · Recommendation · Status.
>
> **Sort order**: severity. Critical items first.

---

## CRITICAL (block HiPC submission until resolved)

### 1. Bias values: code disagrees with paper

**Problem**:
- Paper [`latex/paper/coalesce_hipc.tex:73–74`] defines bias as **+150 if Modified, +75 if sharers ≥ 2**, presented as mutually exclusive (the bias equation is a case statement).
- Code [`simulator/replacement/coalesce/coalesce.cc:116–119`] uses **+40 if Modified, +20 × sharer_count if sharers ≥ 2**, additive, and only applied when `raw_vote > 0` (the gate is undocumented in the paper).

**Impact**: 🔴 Critical. All existing experimental results were produced by the *code*. The paper as written describes a different policy than what we ran. A reviewer who runs the released code would not reproduce the paper's bias equations. This is a reproducibility-blocker.

**Options**:
- **A**. Keep the code's behaviour, rewrite the paper text to match (+40 / +20×sharers, additive, positive-vote gating).
- **B**. Change the code to match the paper (+150 / +75, mutually exclusive, no gating). Requires re-running every existing experiment.
- **C**. **Phase 2D bias sweep first**, then pick the empirical optimum and write that into both the code and the paper.

**Recommendation**: **C**. The sweep is already in the Phase 2D plan; it's a few simulator-hours of work and the outcome strictly dominates a coin-flip between A and B. Until the sweep is done, freeze the code as-is and put a "values are placeholder; final values from bias sweep" note in the paper draft.

**Status**: BLOCKED on Phase 2D. See [B2](../coalesce_paper/citations/justifications/B2_modified_bias.md) and [B3](../coalesce_paper/citations/justifications/B3_sharer_bias.md).

---

### 2. Hardware overhead claim is off by ~30×

**Problem**: paper Table II (`latex/paper/coalesce_hipc.tex:94–111`) claims total overhead **<5 KB** = "<0.1% of 8 MB LLC." Actual storage with current parameters:

| Component | Per-unit | Units | Total |
|---|---|---|---|
| Weight tables (2 × 2048 × 8 bits) | — | 1 | **4 KB** ✓ matches paper |
| Bloom filter (1024 bits) | 128 B | per sampled set | 128 sampled sets × 128 B = **16 KB** ✗ paper says 128 B |
| Ghost tags (256 entries × 32 bits packed) | 1024 B | per sampled set | 128 sampled sets × 1024 B = **128 KB** ✗ paper says 512 B and uses wrong bit-width |
| Set sampling bit-vector | 1 bit | per set | 2048 / 8 = **256 B** |
| **TOTAL** | | | **≈ 148 KB** |

Against a 2 MB LLC that's **~7.2%**, not "<0.1%". Against an 8 MB LLC (which the paper's denominator assumes for some reason — the actual LLC in our config is 2 MB, not 8 MB) it would still be ~1.8%.

The paper has *two errors stacked*:
1. It reports per-sampled-set Bloom and ghost sizes as if they were per-cache totals (off by 128×).
2. It uses 16-bit ghost tags ("256 × 16-bit tags" → 512 B) when the code uses 32-bit packed entries (1024 B per set).

**Impact**: 🔴 Critical. A reviewer who multiplies the per-set numbers by the number of sampled sets will catch this immediately. The "<5 KB satisfies the industrial budget [Sethumurugan 2021]" framing becomes a misrepresentation.

**Options**:
- **A**. **Be honest in the paper rewrite**: report ~148 KB total, frame as "comparable to a single 16-way set's data array" (16 ways × 64 B = 1 KB per set; 148 KB ≈ 148 sets of capacity, ~7% of LLC). Argue this is acceptable because the metadata storage avoids the dense lookup/training arithmetic that ML methods like distilled LSTMs (Glider) require.
- **B**. **Reduce ghost capacity** to make the claim true. E.g., share one Bloom + ghost-tag set across all sampled sets — but this changes the policy materially and needs re-running.
- **C**. **Sample fewer sets**. Currently 1/16 (128 sets); if we sample 1/64 (32 sets) the ghost storage drops to 32 KB. Need to verify Phase 2D this doesn't hurt accuracy.

**Recommendation**: **A** (honesty), with a Phase 2D mini-sweep on sampling rate (option C) as a *secondary* path to reduce the number. The "honest framing" trumps trying to game the budget number.

**Status**: user wants to reduce storage *and* be honest about the final number. See trade-off table below.

#### Reduction lever trade-off table

Three reduction knobs available, each with a perf-vs-storage trade-off:

1. **`SAMPLING_MODULO`** (currently 16 → fewer sampled sets reduces *everything* per-set proportionally)
2. **`GHOST_CAPACITY`** (currently 256 → smaller ghost buffer; cuts ghost storage but may lose rescue opportunities)
3. **`BLOOM_SIZE`** (currently 1024 → smaller Bloom; raises FP rate)

Concrete configurations to choose between:

| Variant | SAMPLING | GHOST | BLOOM | Sampled sets | Per-set | **Total** | Δ vs current | Risk |
|---|---|---|---|---|---|---|---|---|
| **Current (V0)** | 16 | 256 | 1024 | 128 | 1152 B | **~148 KB** | 1.0× | known good |
| **V1 — moderate** | 32 | 256 | 1024 | 64 | 1152 B | **~74 KB** | 2× smaller | half the training population; may slow predictor convergence |
| **V2 — balanced** | 32 | 128 | 1024 | 64 | 640 B | **~41 KB** | 3.6× smaller | half training pop AND half ghost slots; rescues may miss more often |
| **V3 — aggressive** | 64 | 128 | 512 | 32 | 576 B | **~18 KB** | 8× smaller | quarter training pop; tighter Bloom (higher FP) |
| **V4 — paper-claim** | 128 | 64 | 256 | 16 | 288 B | **~4.5 KB** | 33× smaller | matches paper's <5 KB claim; high risk of accuracy collapse |

(All variants use updated post-Bloom-fix parameters: bit_array reset at 150 insertions.)

This is a parameter decision, not a code-architecture decision — I will not change SAMPLING_MODULO / GHOST_CAPACITY / BLOOM_SIZE without explicit instruction since it determines what Phase 2 experiments measure.

**See AskUserQuestion at end of this session for the choice prompt.**

---

### 3. Tesla K80 GPU mention

**Problem**: paper line 121 says "Executed on a Tesla K80 GPU cluster." ChampSim is a CPU-only single-threaded C++ simulator. The K80 is not used and cannot be used by ChampSim. Likely a copy-paste artifact from a previous ML-focused draft.

**Impact**: 🔴 Critical. Reviewers will read this as either (a) the author doesn't understand their own methodology, or (b) the author is padding the methodology section. Either is a strong rejection signal.

**Options**:
- **A**. Delete the sentence; replace with actual host-machine specs (CPU model, core count, RAM, parallelism). Requires asking sir or running `lscpu` / `nproc` / `free -h` on the experimental server.

**Recommendation**: **A**. Already in the strategy doc as weakness C1.

**Status**: confirmed deletion in the Phase 3 rewrite. Needs the actual server specs to fill in the replacement text.

---

### 4. Only canneal, only SRRIP at 8-core

**Problem**: the 8-core experiment compares COALESCE only to SRRIP, on one workload (canneal). Reviewers will ask whether the 33% cycle reduction is workload-specific cherry-picking, and whether the gap to LRU / DRRIP / SHiP at 8-core is even narrower.

**Impact**: 🔴 Critical. Already documented as weaknesses A2 and A3 in the strategy doc.

**Options**: only one — Phase 2A runs the full 5×3×2 matrix (5 policies × 3 PARSEC benchmarks × 4-core and 8-core).

**Recommendation**: Phase 2A; the strategy doc has this scheduled for Weeks 1–2.

**Status**: pending Phase 2A execution.

---

## HIGH-SEVERITY (paper rejection risk, can fix in rewrite)

### 5. Bloom filter never resets — saturates over long runs ✅ RESOLVED 2026-05-21

**Problem**: `BloomFilter::insert()` ([`simulator/replacement/coalesce/coalesce.cc:27–34`]) only **set** bits in the bit array; there was no clear/reset path. Over a long simulation (hundreds of millions of evictions), the 1024-bit array saturated and the `bit_array[hash]` early-exit check in `lookup()` always succeeded.

**Decision**: Option A (periodic reset). User-approved 2026-05-21.

**Implementation**: added `BLOOM_RESET_THRESHOLD = 150` in `coalesce.h:18`, added `int insert_count` member to `BloomFilter`, modified `BloomFilter::insert()` in `coalesce.cc` to reset bit_array when `insert_count` crosses the threshold. Also added `#include <algorithm>` for `std::fill`. Total change: ~10 lines.

**Verification needed**: re-run one canneal smoke test (4-core, short run) to confirm results don't shift materially. The reset cadence of every 150 insertions corresponds to ~64% of the 237-entry design-point occupancy, which keeps FP rate well below 12.5%.

**Status**: ✅ patched. Will be active for all Phase 2 experiments.

---

### 6. Coherence event hook coverage — writebacks vs invalidations ✅ AUDIT COMPLETE 2026-05-21

**Audit doc**: [`coalesce_paper/COHERENCE_HOOK_AUDIT.md`](../coalesce_paper/COHERENCE_HOOK_AUDIT.md)

**Findings**:
- Writebacks **are** modeled. `handle_fill()` at `cache.cc:197–218` generates a real writeback packet when evicting a dirty line — the cycle cost flows through the simulator. ✅
- Invalidations are **not modeled** — the LLC extension tracks MESI state at *LLC granularity only* and never generates invalidation messages on peer writes. M → S, M → I, S → I transitions do not occur.
- `sharer_mask` is **monotonically increasing** — bits are added on hit (cache.cc:292) but never cleared until eviction. Over long runs, almost every popular line shows `sharer_count = 8`.
- `update_replacement_state` fires from exactly one site (`cache.cc:278`) — `try_hit()`, on both hits and misses. No separate hook on fills or writebacks.

**Implication**: COALESCE's 33% win at 8-core canneal comes from *retention-driven hit-rate effects* (legitimate, measured), NOT from saved invalidation cycles (not modeled). The win is real but the *mechanism* the paper currently advertises is partially wrong.

**Decision**: Option C (acknowledge limitation, no code change for HiPC).
- Add a Methodology paragraph stating the simulator does not model invalidation traffic (audit doc § 4.4 has the wording).
- Add a Threats-to-Validity item noting we likely *underestimate* COALESCE's real-system benefit because invalidation savings are unmodeled.
- Recommend in Saga 2: extend ChampSim with an interconnect/invalidation model.

**Status**: audit complete; integration into Phase 3 paper rewrite is the only remaining work.

---

### 7. Worker-core regression not quantified

**Problem**: paper line 206 says worker cores show "marginally lower IPC under COALESCE." Actual numbers from the run logs:

| Core role | COALESCE | SRRIP | Δ |
|---|---|---|---|
| Worker (CPU 0) | 2.088 | 2.120 | −1.5% |
| Worker (CPU 5) | 2.027 | 2.073 | −2.2% |
| Bottleneck (CPU 1) | 0.241 | 0.162 | +49% |
| Bottleneck (CPU 6) | 0.240 | 0.161 | +49% |

The worker regression is small but real. The paper currently hand-waves it as "trade-off yields a net system-wide gain." A reviewer who cares about fairness or QoS will flag this as "you are speeding up some cores by slowing down others — is this acceptable?"

**Impact**: 🟡 Medium-high. Not a rejection-level issue on its own, but the framing matters.

**Options**:
- **A**. **Quantify explicitly** in the Discussion section: "Worker cores see a 1.5–2.2% IPC regression; the net system speedup of 33% is dominated by the bottleneck cores' 49% IPC improvement. In a critical-path workload like canneal where the bottleneck threads gate completion, this trade-off is favourable."
- **B**. **Add a fairness analysis**: report per-core IPC standard deviation under each policy; show that COALESCE *reduces* per-core IPC variance (good for QoS).
- **C**. **Run with a fairness-aware metric** (harmonic mean of speedups, weighted speedup) and report those alongside cycles.

**Recommendation**: **A + B**. Adding B is ~30 min of post-processing the existing run logs and gives a strong reply to any QoS-flavoured reviewer comment.

**Status**: pending Phase 3 paper rewrite.

---

## MEDIUM-SEVERITY (cleanup, easy fixes)

### 8. θ (confidence threshold) is undefined in the paper

**Problem**: paper line 85 references "|Vote| ≤ θ" but never defines θ. Code has `THRESHOLD = 35`.

**Impact**: 🟡 Medium. Reviewer will ask "what value of θ?" in the first round.

**Options**:
- **A**. Add "θ = 35" to the paper text, with the brief rationale documented in [B6](../coalesce_paper/citations/justifications/B6_confidence_theta.md).

**Recommendation**: **A**. 10-second fix.

**Status**: pending Phase 3 paper rewrite.

---

### 9. PC hash functions are not specified in the paper

**Problem**: paper line 62–64 refers to `H_0(PC ⊕ MESI_State)` and `H_1(PC ⊕ Sharer_Count)` but doesn't define what H₀ and H₁ are.

**Impact**: 🟡 Medium. Reproducibility issue; reviewers will ask.

**Options**:
- **A**. Add the exact formulas to the paper from [B9](../coalesce_paper/citations/justifications/B9_pc_hashing.md) — about 4 lines of LaTeX.

**Recommendation**: **A**.

**Status**: pending Phase 3 paper rewrite.

---

### 10. "97% write-port energy reduction" doesn't quite check out

**Problem**: paper line 88 says set sampling at 6.25% (1/16) reduces write-port energy by "97%." The correct number is 1 − 1/16 = 93.75%, ~94%. 97% would correspond to ~1/33 sampling.

**Impact**: 🟢 Low — minor inaccuracy.

**Options**:
- **A**. Change to "94%" or "approximately 94%."
- **B**. Change to "over 90%" (looser claim, still true).

**Recommendation**: **A**.

**Status**: trivial Phase 3 fix.

---

### 11. ChampSim version, branch-predictor, ROB/LSQ sizes not documented

**Problem**: paper has no Methodology subsection specifying the simulator version or the core microarchitecture parameters. These are standard "first paragraph of Methodology" content for an architecture paper.

**Impact**: 🟡 Medium. Reproducibility issue.

**Options**:
- **A**. Fill in [`coalesce_paper/champsim_params_used.md`](../coalesce_paper/champsim_params_used.md) with the actual values (already has `[TODO]` markers for the missing items) and lift the table directly into the paper.

**Recommendation**: **A**. Most of the values are already discoverable from the config files; the remaining items need a `git log` in the simulator dir and a quick inspection of the generated build files.

**Status**: skeleton exists; needs filling.

---

### 12. Bibliography expansion

**Problem**: paper has 5 citations; HiPC reviewers expect 15+. Strategy doc weakness E6.

**Impact**: 🟡 Medium. Won't reject on its own but reviewers will flag.

**Options**:
- **A**. Wire in the 18-entry `coalesce_paper/citations/references.bib` (already built), restructure Related Work into the 5 subcategories outlined in `citation_map.md` § 6.

**Recommendation**: **A**.

**Status**: BibTeX done; integration is part of Phase 3 paper rewrite.

---

## LOW-SEVERITY (track but don't act on this sprint)

### 13. Paper bibliography uses `jaleel2010high` key; new BibTeX uses `jaleel2010rrip`

**Problem**: when migrating from inline `\bibitem` to BibTeX, the key for the RRIP paper needs to be updated in 1–2 places.

**Impact**: 🟢 Low. Find-and-replace fix.

**Status**: noted in the references.bib header comment; do during Phase 3 rewrite.

---

### 14. PARSEC version / input-size not documented

**Problem**: we cite PARSEC but don't say which version, input set ("simlarge"? "native"?), or how the multi-core traces were partitioned.

**Impact**: 🟢 Low. Reproducibility nit.

**Options**: document in `champsim_params_used.md` once the trace-generation process is recorded.

**Status**: blocked on getting the trace-gen recipe from past notes / sir.

---

### 16. Two ChampSim source trees on disk; build reads headers from the sibling repo 🟠 NEW 2026-05-21

**Problem**: The COALESCE simulator at `/home/rajharsh/programming-playground/repos/COALESCE/simulator/` has its own copy of `inc/`, `src/`, `replacement/`, etc. But the build's `absolute.options` points the compiler's `-I` flag at `/home/rajharsh/programming-playground/repos/ChampSim/inc/` (a sibling ChampSim repo on the same machine). Consequence:

- Edits to `simulator/src/*.cc` ✅ get compiled (read by relative path)
- Edits to `simulator/replacement/coalesce/*` ✅ get compiled (relative path)
- Edits to `simulator/inc/*.h` ❌ ignored (compiler reads sibling repo's headers)

**Discovered**: 2026-05-21 when attempting to add `coherence_invalidations` to `cache_stats.h` for the A.1+A.2 invalidation modeling — build failed because the field was added to `simulator/inc/cache_stats.h` but the compiler was looking at `ChampSim/inc/cache_stats.h`.

**Impact**: 🟠 High. Silent — edits to headers will appear to be applied but the build doesn't see them. Easy way to waste hours.

**Current state**:
- `cache_stats.h` has been mirrored to the sibling repo (so the A.2 invalidation counter works in builds).
- All other headers (`block.h`, `cache.h`, etc.) appear identical between the two trees as of audit time, but this should not be assumed for future edits.

**Options**:
- **A**. **Fix `absolute.options`** to point at `simulator/inc/` so COALESCE/simulator becomes the single source of truth. Then update the sibling repo independently or delete it. **Recommended long-term**.
- **B**. **Mirror every future header edit** to both trees manually. Error-prone.
- **C**. **Symlink** `simulator/inc` → `/home/rajharsh/programming-playground/repos/ChampSim/inc` (or vice versa) so they cannot diverge.

**Recommendation**: A (long-term cleanup) but for the immediate Phase 2 push, B is fine — only `cache_stats.h` has been modified so far and it's already sync'd.

**Status**: discovered + sync'd for current work. Long-term cleanup deferred.

---

### 15. Allocator IP vs. requester IP confusion

**Problem**: in `coalesce.cc` we use `current_set[w].ip` (the PC of the instruction that *allocated* the block) as the perceptron feature. The paper doesn't specify whether this is the allocator or the requester (current accessor). They are different and have different prediction characteristics — most prior perceptron-based replacement work uses the allocator PC, but a few use the requester.

**Impact**: 🟢 Low. Mostly a documentation issue; the code clearly uses allocator PC, paper should match.

**Options**: document explicitly in the paper that we use allocator PC.

**Status**: trivial Phase 3 fix.

---

## Decision log

| Date | Item | Decision | Notes |
|---|---|---|---|
| 2026-05-21 | 1 (bias values) | Defer to Phase 2D sweep | Strategy doc already plans this |
| 2026-05-21 | 3 (K80 mention) | Confirmed for deletion | C1 in strategy doc |
| 2026-05-21 | 4 (8-core baselines) | Phase 2A schedule | Confirmed in strategy doc |
| 2026-05-21 | 5 (Bloom no-reset) | **Option A — periodic reset implemented** | Patched in `coalesce.h` + `coalesce.cc` |
| 2026-05-21 | 2 (overhead reduction) | **V2 applied** — SAMPLING_MODULO 16→32, GHOST_CAPACITY 256→128 | Phase 2A baselines will measure V2 config. Adapt to V1/V0/V3 based on observed accuracy. |
| 2026-05-21 | 6 (coherence hooks) | **A.1 + A.2 IMPLEMENTED** — sharer_mask cleared on write hit, invalidation counter added (was originally going to be Option C; user picked A) | See `coalesce_paper/COHERENCE_HOOK_AUDIT.md` and code changes in cache.cc:296-318, cache_stats.h:26-30, plain_printer.cc:130-132 |
| 2026-05-21 | 16 (two-tree gotcha) | **DISCOVERED + sync'd cache_stats.h** | Build's -I reads `/home/rajharsh/programming-playground/repos/ChampSim/inc/`, not the local `simulator/inc/`. Header edits must mirror. Long-term: fix absolute.options. |
| | | | |
| (your decisions go below) | | | |
