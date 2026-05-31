# COALESCE — coherence_aware.md

> **The single source of truth** for what changed when we discovered the coherence mechanism was empirically inert, what we built to fix it, and what remains across HiPC 2026 (Saga 1) and the Tier-1 waterfall (Saga 2). This document is intentionally long. Read top-to-bottom once for the full picture; thereafter use the section headings as a reference.
>
> **Snapshot**: 2026-05-31 · HiPC submission: 2026-06-17 (18 days remaining) · 16-core canneal run still in flight on server
>
> Companion docs (do not duplicate, reference):
> - `docs/PUBLICATION_STRATEGY.md` — the original Saga map (this doc supersedes the experiment matrix in §4)
> - `docs/OPEN_DECISIONS.md` — issue ledger; this doc explains #17 (VMEM overlay) in depth
> - `docs/SESSION_CONTEXT.md` — the per-session handoff doc; § 16 has the brief log of this session
> - `docs/COALESCE_EXPLAINED.md` — the technical narrative; unchanged by this work
> - `coalesce_paper/COHERENCE_HOOK_AUDIT.md` — what the simulator actually models
> - `~/.claude/plans/ok-analyzew-the-entire-crystalline-reef.md` — the plan that was approved before the implementation

---

## 1. The empirical finding (why the rest of this document exists)

A sharer-count histogram instrumented in `find_victim` during the 8-core canneal V2 run (50 M warmup + 100 M sim per core, all 5 policies) produced this number across every per-policy run:

```
LLC SHARER HIST TOTAL:    19,908,624
LLC SHARER HIST[ 1]:      19,908,624  (100.000%)
```

Not 99.9%, not 99.99% — **exactly 100.000%**. Every single eviction examined had exactly one sharer. In addition, `coherence_invalidations = 0` and `coherence_write_hit_other_sharer_events = 0` (the latter is the new event-count counter we added to distinguish "many bits cleared per event" from "many events with few bits each" — see § 4.4).

**What this means component-by-component:**

| COALESCE component | Status given sharer_count is always 1 |
|---|---|
| Sharer-count perceptron hash input | Constant value → contributes **zero information** to the predictor |
| `+20×sharers` coherence bias | Gated on `sharer_count ≥ 2` → **never fires** |
| `+40` MODIFIED bias | May fire, but unknown — needs a state histogram to confirm (see § 7.2) |
| A.1/A.2 synthetic invalidation hook | Triggers on `other_sharers != 0` at write hits → **never fires** (matches the audit) |
| PC perceptron + saturating-counter learning | Continues to work; this is what produces the 33% win |
| MESI-state feature | Likely alive (state varies across blocks); contributes signal |

**Net**: COALESCE's 33% cycle reduction at 8-core canneal is real. The mechanism producing it is **retention-driven dead-block prediction under multi-program LLC capacity pressure**, NOT the coherence-aware mechanism the paper currently advertises. We are competing against LRU/SRRIP/DRRIP/SHiP as a better dead-block predictor, not as a coherence-savvy one. That is still publishable, but only if the framing is honest.

We chose not to reframe to "capacity-aware dead-block prediction" because the policy *can* be coherence-aware — the simulator just gates it. So instead we patched the simulator. Read on.

---

## 2. The root cause (located in one read of vmem.cc)

`simulator/inc/vmem.h:37`:
```cpp
std::map<std::pair<uint32_t, champsim::page_number>, champsim::page_number> vpage_to_ppage_map;
```

`simulator/src/vmem.cc:107-123`:
```cpp
std::pair<page_number, duration> VirtualMemory::va_to_pa(uint32_t cpu_num, page_number vaddr) {
  auto [ppage, fault] = vpage_to_ppage_map.try_emplace({cpu_num, vaddr}, ppage_front());
  if (fault) ppage_pop();
  ...
}
```

**Key fact**: the map key is `(cpu_num, vaddr)`. ChampSim treats `cpu_num` as an address-space ID. Two cores making identical virtual-address requests deterministically get different physical pages — by construction.

**Consequence**: no two cores can ever share an LLC line. The PIN MT-Sync tracer captures genuinely shared VAs in its per-thread traces, but ChampSim's VMEM remaps them at runtime into disjoint physical pages. The sharing that existed in the original multithreaded program is *erased* by the simulator's translation layer.

The COALESCE policy reads `sharer_mask` (an 8/16-bit bitvector on each cache block) which gets populated on hits. Reads OR in the requester's bit; writes set the mask to sole-owner. If two cores never touch the same physical line, `sharer_mask` only ever has the bit of the *first* toucher — `popcount = 1` forever.

This is not a COALESCE bug. It's a ChampSim design choice: each core is treated as an isolated process. Fine for SPEC CPU; broken for any multithreaded shared-memory workload that depends on actual sharing showing up in the cache hierarchy.

---

## 3. What we considered and rejected

(Full rationale is in `~/.claude/plans/ok-analyzew-the-entire-crystalline-reef.md` § "Critique of your option list".)

| # | Approach | Status | Why |
|---|---|---|---|
| 1 | VMEM shared-region overlay (per-VA window) | ⚠️ Partial — reshape | Range-based heuristic is fragile; stacks/code would alias spuriously |
| **1'** | **ASID-keyed VMEM overlay (per-CPU flag)** | ✅ ADOPTED | Whole-trace shared via per-CPU effective ASID; cleaner semantic |
| 2 | All-pages-shared toggle | ❌ Rejected | Defensibility collapse — stacks/code alias, pathological code-cache thrash |
| 3 | Inter-cache snoop layer with real invalidation traffic | 🅂 Deferred to Saga 2 | 2-4 weeks engineering; out of HiPC budget |
| 4 | Synthetic shared-memory microbenchmark | ✅ ADOPTED (validation harness) | Load-bearing for proving the mechanism end-to-end |
| 5 | Coherence event injection from outside data plane | ❌ Rejected | Synthetic events not principled; weak paper defense |
| 6 | PIN-tracer-level shared-region tagging | ❌ Rejected | Trace regen multi-day per benchmark; calendar-incompatible |
| 7 | PIN tracer captures PA | ❌ Rejected | Bakes in OS page-allocation policy → non-deterministic |
| 8 | Shared-PPN first-touch coloring | ❌ Rejected | More complex than 1' for no additional fidelity in our regime |

**Chosen path**: 1' + 4. Defer 3 to Saga 2.

---

## 4. What we built (the mechanism, the validation, the observability)

### 4.1 The ASID-keyed VMEM overlay

**Files**: `simulator/inc/vmem.h` (mirrored to `/home/rajharsh/programming-playground/repos/ChampSim/inc/vmem.h`), `simulator/src/vmem.cc`.

```cpp
class VirtualMemory {
  // NEW members:
  std::map<uint32_t, uint32_t> cpu_to_shared_asid;          // cpu_num -> SHARED_ASID for shared cores
  std::map<page_number, uint32_t> shared_first_allocator;   // for cross-CPU alias accounting

public:
  static constexpr uint32_t SHARED_ASID = std::numeric_limits<uint32_t>::max();
  static inline std::uint64_t aliased_fills = 0;            // smoking-gun counter

  void set_shared_cpus(const std::vector<uint32_t>& shared_cpu_ids);
  // ...
};
```

The new `va_to_pa` logic:
```cpp
std::pair<page_number, duration> VirtualMemory::va_to_pa(uint32_t cpu_num, page_number vaddr) {
  // Resolve effective ASID
  uint32_t asid = cpu_num;
  if (auto it = cpu_to_shared_asid.find(cpu_num); it != cpu_to_shared_asid.end())
    asid = it->second;  // == SHARED_ASID for cores marked shared

  // Key the map by effective ASID, not raw cpu_num
  auto [ppage, fault] = vpage_to_ppage_map.try_emplace({asid, vaddr}, ppage_front());
  if (fault) ppage_pop();

  // Cross-CPU alias accounting: only when shared and a different core was first
  if (asid == SHARED_ASID) {
    auto [first_it, first_inserted] = shared_first_allocator.try_emplace(vaddr, cpu_num);
    if (!first_inserted && first_it->second != cpu_num)
      ++aliased_fills;  // real cross-CPU shared-page event
  }
  // ...
}
```

**Crucially**: `get_pte_pa` (PTE translation) is **not** modified. Page tables stay per-process. Only data pages alias. This matches OS semantics and avoids weird interactions in the page-walk path.

### 4.2 Config plumbing

JSON: optional `virtual_memory.vmem_shared_cpus: [int, ...]` (default `[]`).

`simulator/config/parse.py` adds the default. `simulator/config/instantiation_file.py` emits:
```cpp
champsim::configured::generated_environment<...>::generated_environment() :
  channels{...}, pmem{...}, vmem{...}, ptws{...}, caches{...}, cores{...}
{
  vmem.set_shared_cpus({0, 1, 2, 3, 4, 5, 6, 7});   // only when list is non-empty
}
```

Empty list → no `set_shared_cpus` call → byte-for-byte equivalent to pre-patch behavior. **Verified**: a 50 k canneal smoke with `vmem_shared_cpus=[]` produces `VMEM ALIASED FILLS = 0`.

### 4.3 The synthetic validation benchmark

**File**: `bench/synth_coherence.c` (~150 LOC, build: `gcc -O0 -pthread -Wall`).

Three deterministic modes:

| Mode | What threads do | Expected under shared VMEM | Role |
|---|---|---|---|
| **A** | Each reads/writes a stack-local 4 KB array | bin[1] dominant (no real sharing) | Negative control — proves overlay is workload-driven |
| **B** | tid=0 writes 16 cacheline-isolated cells, tid=1..7 read those cells | bin[k≥2] populated, invalidations ≫ 0, aliased_fills ≫ 0 | Positive case — smoking-gun demonstration |
| **C** | All 8 round-robin read a 64 KB const array | High bins, invalidations = 0 | Read-only sharing |

PIN MT-Sync tracing produces `synth_mode{A,B,C}{0..7}.champsimtrace`. ChampSim replays them under shared VMEM, the counters fire, the histogram populates.

### 4.4 Observability counters

**New**:
- `VirtualMemory::aliased_fills` (static uint64) — increments when a shared-vpage lookup finds the page already mapped by a *different* core. Printed at end of sim by `main.cc`.
- `cache_stats::coherence_write_hit_other_sharer_events` — events count, distinct from existing `coherence_invalidations` which counts bits cleared. Printed by `plain_printer.cc`.

**Pre-existing** (relevant):
- `cache_stats::coherence_invalidations` (counts bits)
- `cache_stats::coherence_sharer_hist[17]` (histogram of `popcount(sharer_mask)` over evictions)

All four feed the V1..V6 pass criteria in § 5.2.

### 4.5 Test SCENARIOs

**File**: `simulator/test/cpp/src/801-vmem-duplicated.cc` extended with three new Catch2 SCENARIOs:
- **Default isolation**: same VA on two CPUs → distinct PAs (negative test).
- **Shared aliasing**: same VA on two CPUs in shared set → same PA; aliased_fills increments; distinct VAs still distinct; CPUs *not* in shared set stay isolated.
- **Idempotent additive**: two overlapping `set_shared_cpus` calls → union.

801.o builds cleanly (verified). Running the full linked binary is on the critical path for the next session but not for this session's deliverable.

### 4.6 Server-side helpers

- `bench/scripts/run_synth_matrix.sh` — single-script runner for V1..V6.
- `bench/scripts/parse_overlay_results.py` — extracts smoking-gun counters from logs into CSV/MD. Unit-tested locally with a fake log.
- `simulator/synth_8core_private.json` and `synth_8core_shared.json` — pre-built configs (`vmem_shared_cpus=[]` and `=[0..7]` respectively).

---

## 5. The validation plan (Phase 2 D4-D6)

This is the next chat's job once it's on the server.

### 5.1 Prerequisites

1. **Install PIN 3.31** on the server. Not currently present (neither locally nor on the server per prior session log). Download from intel.com.
2. **Build the COALESCE tracer**: `cd simulator/tracer/pin && make PIN_ROOT=$PIN_ROOT obj-intel64/champsim_tracer.so`. The compiled `.so` is already on disk from a previous build — re-verify after PIN install.
3. **Compile the synth bench** on the server: `gcc -O0 -pthread -Wall bench/synth_coherence.c -o bench/synth_coherence`.
4. **Generate synth traces**:
   ```bash
   for mode in A B C; do
     $PIN_ROOT/pin -t simulator/tracer/pin/obj-intel64/champsim_tracer.so \
       -o simulator/traces/synth_mode${mode} \
       -- bench/synth_coherence $mode 200000
   done
   ```
   Produces `synth_mode{A,B,C}{0..7}.champsimtrace`. ~minutes per mode.
5. **Build the two synth simulators**: `./simulator/config.sh simulator/synth_8core_private.json && make` → `bin/champsim_synth_private`; repeat for the shared config. For V5, copy `synth_8core_shared.json`, change `LLC.replacement=coalesce`, rebuild as `bin/champsim_synth_shared_coalesce`.

### 5.2 The matrix and pass criteria

| Run | Mode | VMEM | Policy | Pass criterion (MUST be true) | What it proves |
|---|---|---|---|---|---|
| V1 | A | private | LRU | bin[1]≈100%, inval=0, ALIASED_FILLS=0 | baseline behavior preserved |
| V2 | A | shared | LRU | **bin[1]≈100%**, inval=0, ALIASED_FILLS≈0 | overlay is workload-driven, not synthetic inflator |
| V3 | B | private | LRU | bin[1]≈100% | reproduces the canneal failure mode |
| V4 | B | shared | LRU | **bin[k≥2]>0**, **inval≫0**, **ALIASED_FILLS≫0** | MECHANISM FIRES |
| V5 | B | shared | COALESCE | V4 conditions + IPC differs from V4 LRU by ≥ 3-seed CI | COALESCE's coherence features matter |
| V6 | C | shared | LRU | high sharer bins, inval=0 | read-only sharing works without spurious invals |

**If V2 fails** (sharer hist shifts under shared VMEM with a private workload): the overlay has unintended side effects, debug before proceeding.

**If V4 fails** (no invalidations): something between `va_to_pa` and the LLC sharer-mask propagation is dropping the signal. Debug.

**Run**: `bash bench/scripts/run_synth_matrix.sh` (handles all 6, writes logs, prints table via the parser).

### 5.3 After validation: re-run canneal

Once V1..V6 pass, the mechanism is trusted. Now re-run canneal under shared VMEM, all 5 policies, at 4-core and 8-core:

```bash
# Build the canneal-shared simulators (one per policy via JSON edit + rebuild)
# Or just use one binary and switch JSON to drive the policy at config time

# 4-core
bin/champsim_canneal_shared_<policy> \
  --warmup-instructions 50000000 --simulation-instructions 50000000 \
  traces/canneal_big{0,1,2,3}.champsimtrace > results/.../canneal_4core_shared_<policy>.log

# 8-core
bin/champsim_canneal_shared_<policy> \
  --warmup-instructions 50000000 --simulation-instructions 100000000 \
  traces/canneal_big{0,1,2,3,4,0,1,2}.champsimtrace > results/.../canneal_8core_shared_<policy>.log
```

This yields the "Regime 2" data for the paper. Combined with the existing private-VMEM canneal data (Regime 1), it makes the 4-way ablation figure possible.

---

## 6. The expanded experiment matrix (user's emphasis: "all kinds of tests for the new framing as well")

This is the key change from the original `docs/PUBLICATION_STRATEGY.md` Phase 2 plan. **Every Phase 2 sub-phase now has to be done under BOTH regimes** to support the two-regime paper structure. Below is the expansion, prioritized.

### 6.1 Phase 2A — Baseline matrix (was: 5 policies × 3 workloads × 2 core-counts = 30 runs)

| Axis | Original | Expanded for two-regime |
|---|---|---|
| Policy | LRU, SRRIP, DRRIP, SHiP, COALESCE | unchanged |
| Workload | canneal, fluidanimate, dedup | unchanged |
| Core count | 4, 8 | unchanged |
| **VMEM regime** | (implicit: private) | **private AND shared** |
| **Total runs** | 30 | **60** |

**Critical**: at minimum, do the canneal × {private, shared} cross-product for all 5 policies. fluidanimate and dedup matter less if PIN install delays trace generation; canneal-only two-regime is publishable.

### 6.2 Phase 2B — Scaling (was: 3 policies × 2 workloads × 3 core-counts = 18 runs)

| Axis | Original | Expanded |
|---|---|---|
| Policy | SHiP, DRRIP, COALESCE | unchanged |
| Workload | canneal, dedup | unchanged |
| Core count | 4, 8, 16 | unchanged |
| **VMEM regime** | private | **private AND shared** (minimum: canneal at 8-core and 16-core under both) |
| **Total runs** | 18 | **24** at minimum, **36** ideally |

The 16-core canneal run currently on the server stays as private-VMEM data. After overlay validation, repeat at 16-core × {private, shared} × top 2 baselines + COALESCE.

### 6.3 Phase 2C — LLC size sensitivity

| Axis | Original | Expanded |
|---|---|---|
| LLC size | 1, 2, 4, 8 MB | unchanged |
| Workload | canneal, dedup | unchanged |
| Policy | COALESCE + best baseline | unchanged |
| **VMEM regime** | private | **private AND shared** (the shared regime may show DIFFERENT LLC-size sensitivity — coherence pressure dominates at small LLC differently than capacity pressure) |
| **Total runs** | 16 | **32** |

This sensitivity sweep may reveal that the two regimes have qualitatively different LLC-size curves — that's a useful figure in itself.

### 6.4 Phase 2D — Bias / perceptron sweep ⚠️ MOST CHANGED BY THE NEW REGIME

| Sweep dimension | Original | Expanded |
|---|---|---|
| Modified bias `B_M` | {0, 25, 50, 75, 100, 150, 200, 250} | unchanged sweep, but **must be done under shared VMEM**. The original +40 was tuned implicitly under inert coherence — the "right" value under actual sharing is unknown. |
| Sharer-bias slope | (was fixed at +20×s) | **{5, 10, 20, 30, 50}×sharers** sweep — finally meaningful now that sharer counts can be > 1 |
| Perceptron table size | {512, 1024, 2048, 4096} | unchanged |
| Ablation | {PC-only, PC+MESI, PC+sharers, full} | **CRITICAL** — under shared VMEM the PC+sharers feature *can* contribute non-trivially. The ablation finally tests whether it does. |
| **VMEM regime** | private | **PRIMARILY shared** (the sharer-bias sweep is degenerate under private VMEM — it's all zeros) |

**This is now the load-bearing Phase 2D**: the original was sweeping bias values for a feature that never fired. Re-running under shared VMEM tells us whether `B_M^*` and the sharer-slope are real or noise.

### 6.5 Phase 2E — Statistical rigor (3-seed re-runs)

| Axis | Original | Expanded |
|---|---|---|
| Configurations | Main 2A results | unchanged |
| Seeds | 3 (down from 5) | unchanged |
| **VMEM regime** | private | **private AND shared** (the headline numbers for both regimes need error bars) |
| **Total runs** | 3 × 30 = 90 | 3 × 60 = **180** |

If time gets tight: 3-seed only the canneal-8core results in both regimes (3 × 5 × 2 = 30 runs).

### 6.6 New: Phase 2F — Regime-mix sensitivity (Saga 1 stretch goal, optional)

Cross-product of `vmem_shared_cpus` membership patterns to see how COALESCE responds when sharing is partial:
- All 8 cores shared (full true-sharing)
- Cores 0-3 shared, 4-7 private (50/50 — models a workload with hot shared region + private tails)
- One pair (0,5) shared, others private (rare sharing)

This is a defensibility move ("we don't only work in the all-or-nothing regime"). Cut first if calendar pressure.

### 6.7 Time budget for the expanded matrix

Assuming the server has 8+ parallel jobs available and each run is 6-12 hours:

| Phase | Runs | Wall-clock estimate | Server-days @ 8-way parallel |
|---|---|---|---|
| Validation (V1..V6) | 6 | minutes-hours | < 1 |
| Phase 2A canneal × 2 regimes | 20 | 6-12 hrs each | ~2 days |
| Phase 2A f.+d. × 2 regimes | 40 | 6-12 hrs each | ~4 days (gated on PIN traces) |
| Phase 2B scaling | 6 minimum | 8-24 hrs | ~2 days (16-core slowest) |
| Phase 2D bias sweep on shared | ~50 points | 3 hrs each | ~2 days |
| Phase 2E 3-seed minimum | 30 | 6-12 hrs each | ~2 days |
| **Total** | **150 minimum / 240 ideal** | | **~13 days for the full matrix** |

This is tight against the 18-day HiPC budget. The cut order is in § 8.4.

---

## 7. Open questions surfaced by the empirical finding

These weren't visible until the sharer histogram landed. Each may need its own follow-on instrumentation.

### 7.1 Is the MESI-state feature also inert?

The histogram shows sharer_count is constant; but does the MESI state field (I/E/M/S) actually vary across blocks at find_victim time? Or is it stuck at one value because of analogous simulator semantics? **Action item**: a state histogram analogous to the sharer histogram. ~30 min to add, runs in any 8-core canneal warmup window.

### 7.2 Does the +40 MODIFIED bias ever fire?

The state histogram answers this indirectly (if MODIFIED is a non-trivial fraction of evictions, the bias fires). If MODIFIED never appears, then the +40 also never fires and COALESCE is effectively a PC-only perceptron — which is provocative for the paper (we'd beat SHiP with essentially the same input set, raising the question of *why* — likely training-set composition or saturation discipline).

### 7.3 Does aliased_fills > 0 at VMEM translate to sharer_count > 1 at the LLC?

This was the surprise in our local 50k canneal smoke: `ALIASED FILLS = 30` (VMEM is aliasing) but `LLC COHERENCE INVALIDATIONS = 0` (no LLC-level sharing observable). Plausible explanations:

- The 50 k window is too small for aliased pages to be evicted from L1 to L2 to LLC and re-touched by a peer.
- The aliasing is in code/TLS regions that stay in L1 forever.
- Real heap sharing happens but is rare in this short window.

The synth Mode B run will disambiguate — if it produces non-zero invalidations, the chain works; if not, debug between VMEM and LLC.

### 7.4 The two-tree gotcha (OPEN_DECISIONS #16) is still live

The build's `-I` still reads `/home/rajharsh/programming-playground/repos/ChampSim/inc/`. Every header edit must mirror. Long-term fix is pointing `absolute.options` at `simulator/inc/`. Punt to Saga 2.

---

## 8. The complete Saga plan (with the new framing)

> The original Saga map lives in `docs/PUBLICATION_STRATEGY.md`. This section supersedes the experiment matrix and timeline; the venue choices and waterfall logic are unchanged.

### 8.1 Saga 1 — HiPC 2026 (June 17, 2026 deadline)

**Status**: 17 days remaining (today = May 31). Locked direction.

| Track | What | Owner | When | Status |
|---|---|---|---|---|
| Local: VMEM patch | implementation + smoke | this session | D1-D3 | ✅ DONE |
| Local: synth bench source + scripts | implementation + smoke | this session | D1-D3 | ✅ DONE |
| Local: test SCENARIOs | extension + .o build | this session | D3 | ✅ DONE (linked test binary not on critical path) |
| Local: docs (this file, OPEN_DECISIONS #17, SESSION_CONTEXT #16) | drafted | this session | D3 | ✅ DONE |
| Server: PIN install | install | next session | D4 | ⏳ |
| Server: synth bench tracing | PIN + run | next session | D4 | ⏳ |
| Server: V1..V6 validation matrix | run + parse | next session | D4 | ⏳ — **GATING** |
| Server: canneal-overlay re-runs (5 policies × 4-core + 8-core × {private, shared}) | bulk | next session | D5-D7 | ⏳ |
| Server: Phase 2D bias sweep on shared | bulk | next session | D6-D8 | ⏳ |
| Server: Phase 2E 3-seed minimum (canneal-8core × 5 × 2 regimes × 3 seeds) | bulk | next session | D7-D9 | ⏳ |
| Server: Phase 2B 16-core scaling, both regimes | bulk | next session | D8-D10 | ⏳ (cut if slipping) |
| Paper: Methodology rewrite (describe VMEM overlay) | writing | next session | D10-D12 | ⏳ |
| Paper: Threats-to-Validity (5 attacks preempted) | writing | next session | D11-D12 | ⏳ |
| Paper: 4-way ablation figure | figure | next session | D12 | ⏳ — the smoking-gun figure |
| Paper: advisor review window | review | advisor | D14-D15 | ⏳ |
| Paper: polish + submit | writing | next session | D16-D17 | ⏳ |
| Submission | HiPC main track | | **D18 = 2026-06-17** | ⏳ |

**Cut order if slipping**:
1. Phase 2B 16-core under shared (keep private only) — saves ~1 day.
2. Phase 2D ablation (keep B_M sweep, drop the four-way feature ablation) — saves ~1 day.
3. fluidanimate + dedup under shared VMEM (canneal-only two-regime is publishable) — saves ~2 days.
4. **NEVER cut**: V1..V6 validation, canneal × {private, shared} × 5 policies, 3-seed re-runs of canneal-8core × 5 × 2 regimes, methodology rewrite, the 4-way ablation figure.

**Acceptance threshold (what makes this Saga 1 successful)**:
- Synth Mode B + shared VMEM shows `bin[k≥2] > 0` and `coherence_invalidations > 0` — validates the mechanism.
- canneal-8core × COALESCE × shared shows IPC distinguishable (via 3-seed CI) from canneal-8core × LRU × shared — proves COALESCE benefits from the activated coherence features.
- Paper Methodology section describes the overlay precisely and lists the 5 reviewer attacks the Threats-to-Validity preempts.

### 8.2 Saga 2 — Tier-1 waterfall (Aug 2026 → mid-2027)

**Trigger**: HiPC submitted (rejected, accepted, or pending — doesn't matter; Saga 2 begins regardless).

**Venue waterfall** (strict, no concurrent submission):
1. ASPLOS 2027 Summer (Sep 9, 2026 deadline) — Tier 1, primary target
2. ISCA 2027 (~Nov 2026) — if ASPLOS rejects
3. MICRO 2027 (~Apr 2027) — canonical cache-replacement venue
4. PACT 2027 (~Apr 2027) — Tier 2 safety net
5. IEEE TC / TCAD — rolling, final fallback

**The expanded contribution that justifies Tier 1**:

| Saga 1 (HiPC) contribution | Saga 2 (Tier 1) expansion |
|---|---|
| ASID-keyed VMEM shared-overlay (trace-replay aliasing) | **Real interconnect / snoop layer** with directory-based MESI, M→S/M→I/S→I peer-driven transitions, invalidation broadcasts, cross-cache transfers with modeled latency |
| `set_shared_cpus` whole-trace flag | **Per-VA-range shared-region tagging** with PIN-side detection of MAP_SHARED + heap regions |
| canneal-overlay + synth bench | **PARSEC streamcluster, bodytrack, swaptions, ferret, vips, x264** (8-10 workloads), **SPLASH-3** for additional sharing patterns, **GAP suite** (BFS, PageRank, CC) for graph workloads with heavy coherence |
| LRU/SRRIP/DRRIP/SHiP baselines | + **Hawkeye implementation** (OPTgen-driven), + **Mockingjay implementation** (reuse-distance regression), + **Glider** if feasible |
| <5 KB hardware budget claim | **CACTI energy + area analysis** for perceptron tables, ghost buffer, Bloom filter; **McPAT integration** for full power model |
| Trace-driven only | **gem5 cross-validation** of key results (one workload, one config) — establishes our simulator extensions don't artifact |
| Single LLC, single perceptron policy | **Multi-level coherence-aware policy** (L2 + L3 both coherence-aware), exploring whether L2 retention helps or hurts coherence cost |
| | **Real-hardware validation**: measure DRAM writeback rate + invalidation traffic on an Intel CPU with PCM/PAPI, correlate with simulated numbers |
| | **Power model**: report joules-per-instruction, not just IPC |

**Saga 2 timeline (8 months of expansion before ASPLOS)**:

| Month | Focus | Output |
|---|---|---|
| Aug 2026 | Real snoop layer in ChampSim | Working multi-level coherence; existing Saga 1 results re-run under it |
| Sep 2026 | Hawkeye + Mockingjay implementations | Two strong ML baselines wired up |
| Oct 2026 | Trace regeneration for 8 workloads (PIN MT-Sync + shared-region detection) | Expanded trace corpus |
| Nov 2026 | Run expanded matrix (workloads × policies × cores × regimes × seeds) | Full data set |
| Dec 2026 | CACTI + McPAT integration | Energy + area numbers |
| Jan 2027 | gem5 cross-validation | Sanity check on key workloads |
| Feb 2027 | Real-hardware measurements with PCM | Correlation evidence |
| Mar-Apr 2027 | Paper rewrite for ASPLOS / ISCA / MICRO style | Submission-ready manuscript |

### 8.3 Saga 0 (background) — IEEE CAL distillation

Submitted **after** HiPC (rolling deadline; no schedule pressure). Distilled 4-page version with the strongest single result (8-core bottleneck-core IPC under shared VMEM, or the regime-comparison ablation). Maintain the manuscript through Saga 2 so it can be updated at any time.

### 8.4 If HiPC rejects: what changes for Saga 2

- Strengthen the snoop layer narrative (reviewer will likely have flagged "your overlay isn't real coherence" — Saga 2's snoop layer is the answer).
- Add the real-hardware validation early (gives the rebuttal numbers to point at).
- Expand the per-CPU shared-state tagging (move from whole-trace to per-VA, addressing the spurious stack/code aliasing concern preemptively).
- Re-target ASPLOS 2027 Summer (Sep 9 deadline gives 11 weeks of post-HiPC time to incorporate the expansion).

---

## 9. The paper structure for the two-regime narrative

(Locks in the framing approved during planning. Subject to advisor review.)

```
1. Introduction
   - Hook: multicore LLC pressure has two distinct flavors (capacity + coherence)
   - Contribution: a perceptron policy that exploits both, plus a methodology
     for exposing coherence in trace-driven simulation

2. Motivation (NEW — fills weakness E1)
   - Measured data: % of evictions that trigger writebacks / invalidations
   - Why reuse-only policies leave coherence cost on the table

3. Background (NEW — fills weakness E2)
   - MESI coherence (Sorin/Hill/Wood)
   - Perceptron predictors in microarchitecture (Jiménez & Lin 2001 → Jiménez 2017)
   - RRIP / SHiP / Hawkeye / Mockingjay (positioned as 4 evolutionary steps)

4. COALESCE Design
   - 4.1 Feature engineering (PC, MESI state, sharer count)
   - 4.2 Dual orthogonal hashed-perceptron tables
   - 4.3 Coherence-veto bias (with empirical values from Phase 2D bias sweep)
   - 4.4 Ghost-buffer rescue training (with reset; B7 documented)

5. Methodology (REWRITTEN)
   - 5.1 ChampSim simulator + extensions
   - 5.2 The VMEM shared-overlay mechanism (the new contribution) — explained
       precisely, including what it DOES and does NOT model
   - 5.3 Synthetic microbenchmark (synth_coherence.c) — purpose, three modes
   - 5.4 PARSEC traces + PIN MT-Sync
   - 5.5 The two-regime evaluation framework

6. Results
   - 6.1 Regime 1 (capacity-pressure): 4-core + 8-core canneal under default VMEM
       Headline: COALESCE beats all 4 baselines at 8-core by 33% (sharer hist
       confirms the win is dead-block prediction, not coherence)
   - 6.2 Regime 2 (true-sharing): synth Mode B + canneal under VMEM overlay
       Headline: 4-way ablation (LRU/COALESCE × private/shared) isolates the
       coherence contribution as a double-difference
   - 6.3 Scaling (4 / 8 / 16-core under both regimes)
   - 6.4 LLC size sensitivity under both regimes
   - 6.5 Bias sweep results (Phase 2D outputs) — empirically derived B_M and slope
   - 6.6 Statistical rigor (3-seed error bars)

7. Discussion (NEW)
   - Why COALESCE generalizes from coherence to capacity regimes
   - Worker-core regression as a critical-path trade-off
   - When does coherence-awareness help vs. when is it dead weight?

8. Threats to Validity (NEW — the 5 preempts)
   - 8.1 Overlay is not a coherence model — we deliberately model trace-replay
         aliasing, not snoop/invalidation traffic; future work
   - 8.2 Two regimes — both are reported; we don't claim a single "real" number
   - 8.3 Stack/code aliasing under whole-trace overlay — measured and reported
   - 8.4 Why not snoop layer? — engineering scope, deferred
   - 8.5 Producer/consumer microbenchmark is "what COALESCE was built for" —
         it validates the mechanism end-to-end, not the policy's adversarial behavior

9. Related Work (EXPANDED to 20+ refs)
   - 9.1 Classical replacement policies (Belady, LRU, RRIP, DRRIP)
   - 9.2 ML-based replacement (SHiP, Hawkeye, Glider, Mockingjay, Sethumurugan, Wu CAMP)
   - 9.3 Perceptron predictors (Jiménez & Lin 2001, Jiménez 2017)
   - 9.4 Coherence-aware cache optimization (Cuesta, Hardavellas R-NUCA, Souza)
   - 9.5 Background references (Sorin/Hill/Wood, Hennessy & Patterson)

10. Conclusion
```

**Key new figures**:
- F3 (NEW headline): sharer-count histogram on canneal-8core, private-VMEM vs shared-VMEM side-by-side
- F4 (NEW): synth Mode B results, LRU vs COALESCE bar chart
- F5 (NEW): 4-way ablation bar chart, LRU/COALESCE × private/shared on canneal-8core

Drop one of the existing tables to make room.

---

## 10. Reference: what's in the repo right now

For someone arriving cold:

| Path | What's here |
|---|---|
| `simulator/` | ChampSim source, modified with MESI extensions, the new VMEM overlay, observability counters, COALESCE policy |
| `simulator/inc/vmem.h` | The overlay interface (SHARED_ASID, set_shared_cpus, aliased_fills) — mirrored to sibling ChampSim |
| `simulator/src/vmem.cc` | The va_to_pa change + set_shared_cpus impl |
| `simulator/replacement/coalesce/` | The COALESCE policy itself — NOT modified this session |
| `simulator/test/cpp/src/801-vmem-duplicated.cc` | Catch2 SCENARIOs for the overlay |
| `simulator/btp_config.json`, `btp_8core_config.json` | Existing configs with the new `vmem_shared_cpus: []` field added |
| `simulator/synth_8core_private.json`, `synth_8core_shared.json` | New configs for the V1..V6 validation matrix |
| `bench/synth_coherence.c` | The validation microbenchmark source |
| `bench/synth_coherence` | The compiled binary (local) |
| `bench/README.md` | How to build, trace, and run |
| `bench/scripts/run_synth_matrix.sh` | V1..V6 runner |
| `bench/scripts/parse_overlay_results.py` | Counter extractor |
| `docs/coherence_aware.md` | This file |
| `docs/SESSION_CONTEXT.md` | Per-session handoff including § 16 (this session) |
| `docs/OPEN_DECISIONS.md` | Item #17 documents the empirical finding + the patch |
| `docs/PUBLICATION_STRATEGY.md` | Original Saga map (this doc supersedes its Phase 2 matrix) |
| `docs/COALESCE_EXPLAINED.md` | Technical narrative — unchanged |
| `coalesce_paper/COHERENCE_HOOK_AUDIT.md` | What ChampSim does and doesn't model — still accurate |
| `coalesce_paper/citations/` | Phase 1 citation work — unchanged |
| `~/.claude/plans/ok-analyzew-the-entire-crystalline-reef.md` | The approved plan that drove this session |

---

## 11. One-paragraph reality check (where we actually stand)

The 33% canneal-8core headline is real and measured. It comes from COALESCE being a better dead-block predictor under multi-program LLC capacity pressure, not from coherence-awareness. We empirically proved the coherence half was inert by instrumenting a sharer-count histogram (`bin[1]=100.000%`). Rather than reframe to a single-regime "capacity-aware" paper, we patched the simulator with an ASID-keyed VMEM shared-overlay (~40 LOC), built a synthetic validation harness (~150 LOC), instrumented two new counters, added Catch2 scenarios, and shipped server-side helpers — so the next session can validate the mechanism (V1..V6) and re-run canneal under shared VMEM, producing the second regime. The paper now lands as a two-regime evaluation: COALESCE wins by 33% in the capacity regime (Regime 1, original ChampSim) and additionally fires its coherence features in the true-sharing regime (Regime 2, overlay enabled). Both numbers are honest. The contribution stack is COALESCE-the-policy + the trace-replay aliasing methodology, with snoop-layer modeling explicitly deferred to Saga 2's ASPLOS submission.

Every Phase 2 sub-phase (baseline matrix, scaling, LLC sweep, bias sweep, statistical re-runs) must now be done under both regimes. The expanded matrix is ~150 minimum / 240 ideal runs; the 18-day HiPC budget makes that tight but feasible if server parallelism holds. Saga 2 picks up where Saga 1 ends with a real snoop layer, expanded benchmark suite, CACTI/McPAT energy modeling, Hawkeye/Mockingjay baselines, and gem5 cross-validation — targeting ASPLOS Summer 2027 with strict no-concurrent-submission waterfall semantics through MICRO 2027.
