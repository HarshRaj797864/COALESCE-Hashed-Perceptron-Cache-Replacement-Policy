# Coherence Event Hook Audit

> **Question**: which coherence-related events in the simulator reach the COALESCE perceptron training path, and which don't?
>
> **Why it matters**: The paper claims COALESCE is "coherence-aware." We need to know — precisely and honestly — what kind of coherence-awareness we actually have, and what we don't.
>
> **Date**: 2026-05-21 · **Auditor**: claude · **Verdict**: ⚠️ the MESI model is simplified at the LLC level; we capture *state-driven retention* effects but not *invalidation-traffic* effects.

---

## 1. What is hooked

### 1.1 The single training entry point

`update_replacement_state(...)` — the only path into `coalesce::update_replacement_state` — is called from exactly one place:

```cpp
// simulator/src/cache.cc:278–279  (inside CACHE::try_hit)
impl_update_replacement_state(handle_pkt.cpu, get_set_index(handle_pkt.address),
                              way_idx, module_address(handle_pkt), handle_pkt.ip,
                              {}, handle_pkt.type, hit);
```

It fires on **both** hits and misses (it's above the `if (hit)` check) so COALESCE sees every LLC access.

### 1.2 What state COALESCE sees at decision time

`find_victim()` is called from `handle_fill()` (cache.cc:182) when a miss needs an eviction. Inside, COALESCE reads three things off each candidate way:

| Field | Source | What it actually represents |
|---|---|---|
| `current_set[w].ip` | Set in `fill_block()` (cache.cc:155) | The PC of the instruction that *allocated* the block (allocator PC, not requester) |
| `current_set[w].state` | MESI_State; set in `fill_block()` and `try_hit()` | The line's current LLC-level coherence state |
| `current_set[w].sharer_mask` | uint8_t bitmask; set/updated in `fill_block()` and `try_hit()` | Bitmask of CPUs that have *at some point* touched this line in the LLC |

These three fields are what feed the perceptron and the coherence bias.

### 1.3 What state COALESCE sees at training time

`update_replacement_state()` is called on hits (with `hit=true`) and misses (with `hit=false`).

- **On hit in a sampled set** (cache.cc:278 → coalesce.cc:145–157): COALESCE re-reads `block_meta.state` and `block_meta.sharer_mask` directly from the cache block (the version *after* try_hit() has updated them — see § 2 below). Training direction is positive.
- **On miss in a sampled set** (coalesce.cc:158–169): COALESCE consults the ghost buffer. If hit, it recovers the (PC, sharers, state) that the block had *at eviction time* and trains 5× positive.

---

## 2. What the LLC's MESI implementation actually does

This is the key audit finding. The MESI extension in this ChampSim fork is **not a full coherence-protocol implementation**. It is a *tagging mechanism* that runs at the LLC level only.

### 2.1 State transitions that DO happen

| Trigger | File:Line | State transition | Sharer-mask update |
|---|---|---|---|
| Read miss (fill) | cache.cc:153–154 | `I → E` (clean fill) | sharer_mask = bit for requesting CPU only |
| Write miss (fill) | cache.cc:153 | `I → M` (dirty fill) | sharer_mask = bit for requesting CPU only |
| Read hit | cache.cc:289–303 | `E → S` if sharer_count becomes >1; otherwise unchanged. `M` is sticky (no demotion). | sharer_mask `|= 1<<cpu` |
| Write hit | cache.cc:293–294 | `* → M` (any state to Modified) | sharer_mask `|= 1<<cpu` |

### 2.2 State transitions that DON'T happen

These are the transitions a real MESI protocol would do but this LLC model does NOT:

| Real MESI transition | Why it's missing here |
|---|---|
| `M → S` on peer read | No peer-read-side hook. When a different CPU's read reaches the LLC, the line's state may go E → S, but if it was already M, the state stays M — and the dirty data is not flushed. |
| `M → I` on peer write | Same. A peer write does not invalidate the original holder; the model has no concept of "core A's private cache held this and just got invalidated." |
| `S → I` on peer write | No invalidation messages are generated at all. |
| `sharer_mask` bit *removal* | Once a CPU is recorded as a sharer of a line, the bit is never cleared until eviction. Even if the CPU's L1/L2 evicted the line minutes ago, the LLC still believes it's a sharer. |
| Cross-cache transfers (E → I + S → E remote, etc.) | No interconnect / cache-to-cache transfer modeling. |

### 2.3 Consequences

1. **sharer_mask drift**: For long-lived LLC lines, `popcount(sharer_mask)` grows monotonically with every distinct CPU that ever touches the line, until eviction. Over time, almost every popular line will show `sharer_count = 8` (or however many cores are active). Our +20×sharers bias will saturate on these lines.
2. **No invalidation traffic**: The cycle cost of invalidation broadcasts that real coherence protocols incur is **not modeled**. So COALESCE's claim that "evicting a Shared block triggers invalidation messages" is true of *real systems* but not of *the simulator we measured*.
3. **No M→S/M→I observation events**: Even if we wanted to *train* the perceptron on invalidation-driven state transitions, there are no such events to hook.

---

## 3. So how is COALESCE actually winning by 33% at 8-core?

The 33% cycle reduction on 8-core canneal is **real** — it shows up in the trace-driven simulation, and the mechanism is consistent with what we hoped to exploit:

- At 8-core with a 2 MB LLC (256 KB per core), capacity pressure is high.
- Canneal's bottleneck cores (CPUs 1 and 6) do most of the shared-graph pointer chasing — they have a small hot working set that other cores' streaming traffic keeps evicting.
- COALESCE's perceptron observes (PC, state, sharer count) at allocation/hit time. For bottleneck-core blocks: the PC is recognizable, the state is often M or S (because the cores are mutating shared data), the sharer_mask accumulates several bits over time.
- The +40/+20×sharers bias systematically protects these bottleneck-core blocks against eviction by streaming cores.
- Bottleneck-core hit rate goes up → bottleneck-core IPC jumps from ~0.16 to ~0.24 → total cycles drop by 33% (because completion time is gated by bottleneck cores in canneal).

**This mechanism is legitimate and the result is real.** The win comes from *retention-driven hit rate*, not from saving invalidation cycles.

### What the paper claims vs what the simulator measures

| Paper claim | Reality |
|---|---|
| "Evicting a Modified block forces a writeback (200+ cycles)" | ✅ True in the simulator. `handle_fill()` at cache.cc:197–218 generates a real writeback packet when evicting a dirty line. |
| "Evicting a Shared block triggers invalidation messages across cores" | ❌ Not modeled in this simulator. Real-world true; sim-world a no-op. |
| "COALESCE saves cycles by avoiding these coherence transactions" | ⚠️ Partially. Writeback avoidance is real and measured. Invalidation-cost avoidance is unmodeled. The 33% win comes mostly from hit-rate effects on bottleneck cores, with some contribution from writeback avoidance. |

---

## 4. Recommended actions

### 4.1 Tighten the paper claims (must do for HiPC)

The Motivation section currently leans on invalidation-cost arguments. We need to:

- Either soften those claims ("…in real systems, invalidations cost interconnect bandwidth; in our trace-driven model we focus on the writeback and hit-rate components of coherence cost"), or
- Explicitly note in Threats-to-Validity that the simulator does not model invalidation traffic and therefore we likely **underestimate** COALESCE's benefit (a real system would save even more cycles from invalidations COALESCE avoids by retaining shared blocks).

**The second framing is stronger** — it acknowledges the limitation honestly and turns it into evidence of conservatism in our reporting.

### 4.2 sharer_mask drift mitigation (optional, ~30 min change)

The monotonically-growing sharer_mask is a real semantics problem. Two easy fixes:

- **A. Reset sharer_mask on long inactivity**: track a "last touched cycle" per line; if any sharer hasn't touched the line in N cycles, clear their bit. Adds a few bits per line, complicates the audit.
- **B. Decay**: every M LLC accesses, scan and apply `sharer_mask &= ~(1<<oldest_unactive)`. Cheap but heuristic.
- **C. Leave as-is**: document the behavior in the paper and proceed. The drift biases the perceptron toward "everything is highly shared," which arguably matches the *actual* sharing intensity of multicore workloads.

**Recommended**: C for HiPC (no code change). Revisit in Saga 2 if Tier-1 reviewers push back.

### 4.3 Don't train on a fake invalidation hook

It would be tempting to *synthesize* invalidation events (e.g., "if a core writes a block previously read by other cores, treat that as an invalidation") and train the perceptron on them. **Don't.** The trace-driven model has no real signal here; synthetic events would just bias the predictor based on our prior beliefs about what coherence cost should be. Stick to hits and ghost-hits as training signals.

### 4.4 Methodology section additions (Phase 3 paper rewrite)

Add a paragraph to the new Methodology section, around the simulator description:

> "Our ChampSim extension augments cache blocks with explicit MESI state and an 8-bit sharer bitmask. These fields are updated on hits in the LLC (state transitions on read/write; sharer-mask bit accumulation per touching CPU) and on fills (initial state set from miss type; sharer mask initialized to the requesting CPU). The extension does **not** model invalidation broadcasts or cross-cache state transfers — these would require an interconnect model that ChampSim does not provide. Our coherence-cost claims are therefore restricted to: (a) writeback traffic generated on Modified-line eviction, which the simulator models faithfully; and (b) hit-rate effects on cores that share data, which the simulator captures through the LLC hit/miss path. The invalidation-traffic component of real-system coherence cost is *not* in our reported numbers, meaning we likely underestimate COALESCE's benefit on real hardware."

This is the honest framing. Take credit for what we have; flag what we don't.

---

## 5. Decision summary for OPEN_DECISIONS #6

Update `docs/OPEN_DECISIONS.md` item 6 with:

- **Audit finding**: writebacks ARE hooked (real cycle cost flows through the simulator). Invalidations are NOT hooked because they are not modeled at the LLC level. Sharer_mask is monotonic. update_replacement_state fires on hit and miss.
- **Recommended action**: § 4.1 (tighten paper claims, add Threats-to-Validity paragraph) + § 4.4 (Methodology paragraph). No code change for HiPC.
- **Deferred**: real invalidation modeling → Saga 2 (would require a non-trivial interconnect model addition to ChampSim).

---

## 6. Files referenced

| File | Lines | What's there |
|---|---|---|
| `simulator/src/cache.cc` | 141–157 | `fill_block()` — sets initial MESI state + sharer_mask on fill |
| `simulator/src/cache.cc` | 174–253 | `handle_fill()` — calls `find_victim`, generates writeback packet on dirty eviction |
| `simulator/src/cache.cc` | 255–313 | `try_hit()` — single update_replacement_state callsite; updates sharer_mask and state on hit |
| `simulator/inc/block.h` | 7, 24–25 | MESI_State enum + cache_block fields |
| `simulator/replacement/coalesce/coalesce.cc` | 98–138 | `find_victim` — reads state + sharer_mask for decision |
| `simulator/replacement/coalesce/coalesce.cc` | 140–170 | `update_replacement_state` — training on hit/miss with ghost buffer rescue |
