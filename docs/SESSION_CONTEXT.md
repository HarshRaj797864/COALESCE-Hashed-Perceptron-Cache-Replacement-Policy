# COALESCE — Session Handoff Context

> **Purpose**: paste this into a fresh chat to onboard a new Claude session with the full picture of where the project stands and what needs to happen next. **Self-contained** — assumes the reader has zero prior context.
>
> **Snapshot date**: 2026-05-21 · **HiPC submission**: 2026-06-17 (27 days remaining)

---

## 1. Who you are talking to

**Harsh Raj** — B.Tech student at IIIT Sri City. Advisor: **Dr. Bheemappa Halavar**. This is his B.Tech project, target venue **HiPC 2026 main track**.

Working directory: `/home/rajharsh/programming-playground/repos/COALESCE`. Git: branch `main`, fork of ChampSim with project-specific extensions.

---

## 2. What COALESCE is (in 3 sentences)

COALESCE = **Co**herence-**O**bservant **A**daptive **L**earning for **S**ystem-wide **C**ache **E**fficiency. It's a Last-Level-Cache (LLC) replacement policy that uses a small hashed-perceptron predictor — but unlike SHiP, Hawkeye, Mockingjay, or any other ML-cache-replacement work in the literature — the predictor's features include **MESI coherence state** and **sharer count** in addition to PC. The bet is that coherence-aware replacement wins on heavily-shared multicore workloads because evicting a Modified block costs a writeback (~200 cycles) and evicting a Shared block triggers invalidation traffic — costs that reuse-only policies ignore.

## 3. What's been done (existing results)

Two experiments exist (PARSEC canneal benchmark, ChampSim trace-driven simulator):

**4-core, 50M instructions/core, 2 MB LLC:**
| Policy | IPC | LLC misses |
|---|---|---|
| LRU | 0.4023 | 684,771 |
| DRRIP | 0.5072 | 456,998 |
| SHiP | 0.5090 | 452,631 |
| COALESCE | 0.4996 | 539,738 |

→ COALESCE wins big over LRU (+24.2%) but loses to DRRIP and SHiP by ~1.8%. We are **4th of 4** on this config.

**8-core, 100M instructions/core, 2 MB shared LLC:**
| Metric | COALESCE | SRRIP |
|---|---|---|
| Total cycles | 415.9 M | 620.6 M |
| Bottleneck IPC (CPU 1) | 0.241 | 0.162 |
| Bottleneck IPC (CPU 6) | 0.240 | 0.161 |
| Worker IPC (CPU 0) | 2.088 | 2.120 |
| Worker IPC (CPU 5) | 2.027 | 2.073 |

→ COALESCE finishes 33% faster than SRRIP. Win comes from bottleneck cores (CPUs 1 & 6) doing canneal's shared pointer-chasing — they jump from ~0.16 IPC to ~0.24 IPC. Worker cores see a small regression (~1.5%). System-wide saving: 205 M cycles.

**Critical methodological gap**: at 8-core, COALESCE was compared **only to SRRIP**. LRU / DRRIP / SHiP at 8-core were never run. This is the #1 reviewer-rejection risk and is the first thing Phase 2A fixes.

---

## 4. Where the code lives

```
COALESCE/
├── simulator/                       # ChampSim-based env (the only thing that matters for experiments)
│   ├── replacement/
│   │   ├── coalesce/                # ★ The COALESCE policy (coalesce.h + coalesce.cc)
│   │   ├── lru/  srrip/  drrip/  ship/  random/   # Baselines
│   ├── inc/block.h                  # MESI_State enum + sharer_mask field on cache_block
│   ├── src/cache.cc                 # ChampSim core; only single update_replacement_state hook (line 278)
│   ├── traces/                      # PARSEC canneal traces (GITIGNORED, ~18 GB)
│   ├── results/
│   │   ├── canneal_4core_50M/       # All 5 baselines + COALESCE
│   │   └── canneal_8core_100M/      # Only COALESCE + SRRIP — needs filling
│   ├── btp_config.json              # 4-core sim config
│   └── btp_8core_config.json        # 8-core sim config
├── docs/                            # Project-level docs (TRACKED in git)
│   ├── PUBLICATION_STRATEGY.md      # Full 28-day HiPC sprint plan
│   ├── COALESCE_EXPLAINED.md        # Long-form technical explainer (READ THIS FIRST if onboarding)
│   ├── OPEN_DECISIONS.md            # All bugs + design discrepancies + decisions
│   └── SESSION_CONTEXT.md           # This file
├── coalesce_paper/                  # Phase 1 citation work (TRACKED in git)
│   ├── citations/
│   │   ├── references.bib           # 18 BibTeX entries (Day 1 + Week 1 + Week 2)
│   │   ├── citation_map.md          # Phase 1 plan + checklist
│   │   ├── justifications/B{1..10}_*.md  # Per-parameter justifications
│   │   └── related_work_notes/D{1..11}_*.md  # Per-paper notes
│   ├── champsim_params_used.md      # Discovered ChampSim defaults
│   └── COHERENCE_HOOK_AUDIT.md      # ⚠️ Critical finding — see § 7
├── CLAUDE.md                        # Project context auto-loaded by Claude Code
├── README.md                        # Build/run instructions
├── AIM.md  ARCHITECTURE.md          # Legacy notes (GITIGNORED)
└── latex/paper/coalesce_hipc.tex    # Current paper draft (GITIGNORED)
```

---

## 5. Current code parameters (V2 config, applied 2026-05-21)

From `simulator/replacement/coalesce/coalesce.h`:

| Constant | Value | Notes |
|---|---|---|
| `PERCEPTRON_TABLE_SIZE` | 2048 | 2 tables × 2048 × 8-bit signed weights = 4 KB |
| `MIN_WEIGHT`, `MAX_WEIGHT` | −128, +127 | 8-bit signed saturating counters |
| `THRESHOLD` | 35 | Confidence threshold for training: train if |vote| ≤ 35 or mispredicted |
| `BLOOM_SIZE` | 1024 bits | Per-sampled-set Bloom filter |
| `BLOOM_HASHES` | 3 | |
| `BLOOM_RESET_THRESHOLD` | **150** ← added 2026-05-21 | Reset bit_array after this many insertions (Option A fix for Bloom saturation bug) |
| `SAMPLING_MODULO` | **32** ← changed 2026-05-21 (was 16) | Sample 1/32 sets (= 64 sampled sets of 2048) |
| `GHOST_CAPACITY` | **128** ← changed 2026-05-21 (was 256) | Per-sampled-set ghost-tag direct-mapped table |

**Coherence bias** (in `coalesce.cc:116–119`, applied only when `raw_vote > 0`):
- +40 if MESI state == MODIFIED
- +20 × sharer_count if sharer_count ≥ 2

> Note: the paper draft says +150 / +75 — this is a known discrepancy. Phase 2D bias sweep will determine the right values. Current code is what produced the existing results.

**Total V2 storage**: 4 KB weights + 64 sampled sets × (128 B Bloom + 512 B ghost) = **~44 KB** ≈ 2.1% of 2 MB LLC. (Old V0 was ~148 KB.)

**Sim configuration** (from `btp_config.json` and `btp_8core_config.json`):
- L1I/L1D: 32 KB each, 8-way, 4-cycle access, LRU
- L2: 512 KB per core, 8-way, 10-cycle, LRU
- LLC: 2 MB total, 2048 sets × 16 ways, 20-cycle access, COALESCE replacement
- DRAM: DDR4-3200 defaults (tRP=tRCD=tCAS=24 MC cycles @ 1600 MHz, 1 channel, 1 rank × 8 bankgroups × 4 banks)
- CPU clock: 4 GHz default

---

## 6. Build & run commands (verbatim)

### ⚠️ CRITICAL: two source trees gotcha (read first)

There are **two ChampSim trees** on this machine:
- `/home/rajharsh/programming-playground/repos/COALESCE/simulator/` — where you'll spend most of your time
- `/home/rajharsh/programming-playground/repos/ChampSim/` — sibling repo; **the build's `-I` reads headers from here**

What this means concretely:
- Edits to `simulator/src/*.cc` ✅ compiled (read by relative path)
- Edits to `simulator/replacement/coalesce/*` ✅ compiled (relative path)
- Edits to `simulator/inc/*.h` ❌ **ignored by the build** — the compiler reads `ChampSim/inc/<file>.h` instead
- Solution for any header edit: **also apply it to `/home/rajharsh/programming-playground/repos/ChampSim/inc/<file>.h`**

Verified header diff status as of 2026-05-21: only `cache_stats.h` differs (already sync'd). All other headers are identical between the trees.

See `docs/OPEN_DECISIONS.md` item #16 for the long-term fix path.

### Build

```bash
cd /home/rajharsh/programming-playground/repos/COALESCE/simulator

# 4-core configuration
./config.sh btp_config.json && make    # produces bin/champsim_btp_test

# 8-core configuration (rebuild after switching configs)
./config.sh btp_8core_config.json && make clean && make
                                       # produces bin/champsim_8core_coalesce
```

### Switch replacement policy

Edit `"replacement"` under `"LLC"` in the config JSON, options: `coalesce | lru | srrip | drrip | ship | random`. Then `./config.sh <cfg> && make clean && make`.

### Run 4-core

```bash
cd /home/rajharsh/programming-playground/repos/COALESCE/simulator
bin/champsim_btp_test \
  --warmup-instructions 200000000 \
  --simulation-instructions 50000000 \
  traces/canneal_big0.champsimtrace \
  traces/canneal_big1.champsimtrace \
  traces/canneal_big2.champsimtrace \
  traces/canneal_big3.champsimtrace \
  > results/canneal_4core_50M/<policy>_v2.txt
```

### Run 8-core

```bash
cd /home/rajharsh/programming-playground/repos/COALESCE/simulator
bin/champsim_8core_coalesce \
  --warmup-instructions 1000000000 \
  --simulation-instructions 100000000 \
  traces/canneal_big0.champsimtrace traces/canneal_big1.champsimtrace \
  traces/canneal_big2.champsimtrace traces/canneal_big3.champsimtrace \
  traces/canneal_big4.champsimtrace traces/canneal_big0.champsimtrace \
  traces/canneal_big1.champsimtrace traces/canneal_big2.champsimtrace \
  > results/canneal_8core_100M/<policy>_v2.txt
```

(8-core re-uses trace 0/1/2 because there are only 5 unique canneal traces.)

### Extract key metrics from output

Each `*.txt` output has the per-CPU stats and a summary. Quick greps:

```bash
# Per-CPU IPC
grep -E "^CPU [0-9] cumulative IPC:" results/<dir>/<file>.txt

# Total cycles
grep -E "Finished CPU [0-9] instructions:" results/<dir>/<file>.txt

# LLC stats
grep -E "LLC TOTAL.*ACCESS.*HIT.*MISS" results/<dir>/<file>.txt
grep -E "LLC LOAD|LLC RFO|LLC PREFETCH|LLC WRITE" results/<dir>/<file>.txt
```

---

## 7. ⚠️ Critical context: the coherence audit + invalidation modeling

Full doc: `coalesce_paper/COHERENCE_HOOK_AUDIT.md`. TL;DR:

The simulator's MESI implementation is **simplified at the LLC level**:

- ✅ **Writebacks ARE modeled** — evicting a Modified block generates a real writeback packet (cache.cc:197–218), so the 200-cycle DRAM penalty flows through the simulation correctly.
- ⚠️ **Invalidations are partially modeled (as of 2026-05-21)** — Option A.1+A.2 implemented: on write-hit, sharer_mask bits of other CPUs are cleared (synthetic invalidation broadcast) and a per-broadcast counter is incremented. **Reported in output as `LLC COHERENCE INVALIDATIONS: N`**. Important caveats:
  - This is **LLC-bookkeeping only**. The actual L1/L2 tags of "invalidated" cores still hold the line — ChampSim has no inter-level coherence. So no real invalidation cycles or interconnect traffic are simulated.
  - There is no cycle penalty applied for the invalidation broadcasts. The counter exists for reporting only.
  - The COALESCE perceptron is NOT trained on invalidation events directly (that would be A.3, deferred).
- 🆕 **`sharer_mask` is now accurate-ish** — bits *are* cleared on write hits to multi-sharer lines. Previously was monotonically increasing.
- 🪝 `update_replacement_state` fires from exactly one site (cache.cc:278), in `try_hit()`, on both hits AND misses.

**Implication**: COALESCE's 33% win at 8-core was originally measured with the *unfixed* (monotonic sharer_mask) model — meaning the +20×sharer_count bias was artificially inflated. With the A.1+A.2 fix, sharer counts are more accurate (smaller on average), so the bias kicks in less often. The new Phase 2 runs may show different numbers than the old ones — could go either way.

**For the paper Methodology / Threats-to-Validity** (see audit doc § 4.1): we model writeback traffic faithfully and we report invalidation event counts; we do NOT model invalidation cycle cost or interconnect latency. This means we still likely *underestimate* COALESCE's real-system benefit but less so than before.

---

## 8. Phase 2 experiment matrix (this is what the new chat needs to run)

### 8.1 Order of operations

1. **Smoke test the V2 build**:
   ```bash
   cd simulator
   ./config.sh btp_config.json && make
   ```
   If this fails, the V2 parameter changes broke the build; report the error.

2. **V2 sanity run** (short 4-core canneal to confirm V2 doesn't break behavior):
   ```bash
   bin/champsim_btp_test \
     --warmup-instructions 50000000 \
     --simulation-instructions 5000000 \
     traces/canneal_big{0,1,2,3}.champsimtrace \
     > results/v2_smoke.txt
   ```
   Sanity check: IPC should be in the ballpark of 0.40–0.55 per core. If wildly off (e.g., <0.1), something broke.

3. **Phase 2A — Baseline Matrix** (the main deliverable). Run **every cell** in the table:

   | Cores | Workload | Policy |
   |---|---|---|
   | 4 | canneal | LRU, SRRIP, DRRIP, SHiP, COALESCE |
   | 4 | fluidanimate | LRU, SRRIP, DRRIP, SHiP, COALESCE |
   | 4 | dedup | LRU, SRRIP, DRRIP, SHiP, COALESCE |
   | 8 | canneal | LRU, SRRIP, DRRIP, SHiP, COALESCE |
   | 8 | fluidanimate | LRU, SRRIP, DRRIP, SHiP, COALESCE |
   | 8 | dedup | LRU, SRRIP, DRRIP, SHiP, COALESCE |

   = 30 simulations total. Each takes a few hours; with parallelism, the whole matrix completes in 1–2 days of wall time.

   **Trace prerequisites**: only canneal traces are confirmed present at `simulator/traces/canneal_big{0..4}.champsimtrace`. **fluidanimate and dedup traces may not yet exist** — first action of the new chat should be `ls simulator/traces/ | grep -E "fluidanimate|dedup"`. If absent, the user needs to generate them with the PIN MT-Sync tracer in `simulator/tracer/` (this is a multi-hour task per benchmark per core count).

4. **Phase 2B — Scaling Study** (after 2A succeeds): repeat the top 3 baselines (SHiP, DRRIP, COALESCE) at 16-core (needs a `btp_16core_config.json` to be created — derive from the 8-core config).

5. **Phase 2C — LLC Size Sensitivity**: 8-core canneal + dedup, COALESCE + best baseline, LLC ∈ {1 MB, 2 MB, 4 MB, 8 MB}. Edit `sets` field in config JSON (1 MB = 1024 sets, 4 MB = 4096 sets, etc.) while keeping 16 ways.

6. **Phase 2D — Bias/Perceptron Sweep**:
   - Modified bias ∈ {0, 25, 50, 75, 100, 150, 200, 250}
   - Sharer bias slope ∈ {0, 10, 20, 30, 50} (the multiplier, currently 20)
   - Perceptron table size ∈ {512, 1024, 2048, 4096} (currently 2048)
   - Ablation: PC-only, PC+MESI, PC+sharers, full
   - Each variant is a code change in `coalesce.h` constants + recompile + 4-core canneal run.

7. **Phase 2E — Statistical Rigor**: re-run the main 2A configurations 3× with different seeds. (How to vary the seed in ChampSim: needs investigation — may require trace-selection differences or a `--seed` flag.)

### 8.2 What metrics to extract per run

For each result file, capture into a CSV row:

| Column | Source |
|---|---|
| `policy` | filename |
| `workload` | filename |
| `cores` | filename / config |
| `total_instr` | sum across CPUs |
| `total_cycles` | max across CPUs |
| `ipc_overall` | total_instr / total_cycles |
| `ipc_cpu0..N` | per-CPU |
| `llc_accesses` | `LLC TOTAL ACCESS` |
| `llc_hits` | `LLC TOTAL HIT` |
| `llc_misses` | `LLC TOTAL MISS` |
| `llc_miss_rate` | derived |
| `llc_writebacks` | look for `LLC WRITE` |

### 8.3 What to compare against

The existing 4-core canneal `final_<POLICY>_50M.txt` files in `simulator/results/canneal_4core_50M/` were produced with **V0 parameters** (SAMPLING_MODULO=16, GHOST_CAPACITY=256) AND the monotonic-sharer-mask simulator. V2 runs (1/32 sampling, 128 ghost, NEW invalidation-on-write-hit) introduce TWO changes simultaneously:
1. V2 parameter shrink (less metadata storage)
2. A.1+A.2 invalidation modeling (accurate sharer counts, but no real cycle penalty)

So the comparison is "V0 results from old simulator" vs "V2 results from new simulator." A big swing (>10% IPC) is plausible and isn't automatically a bug — it reflects the combined effect of both changes.

**To isolate the effects** (if results swing wildly), the user can:
- Revert V2 parameters in `coalesce.h` (set SAMPLING_MODULO=16, GHOST_CAPACITY=256), rebuild, re-run → tells us "this was caused by the simulator change, not the parameters."
- Revert the invalidation hook in cache.cc (the COALESCE comment-block) → tells us "this was caused by parameters, not the simulator change."

The existing 8-core canneal `coalesce_100M.txt` and `srrip_100M.txt` were also V0 + monotonic-sharer-mask. Same caveats.

---

## 9. Known issues / decisions made

Full list with options + recommendations in `docs/OPEN_DECISIONS.md`. Snapshot:

| # | Issue | Status |
|---|---|---|
| 1 | Bias values: code +40/+20×s vs paper +150/+75 | DEFERRED to Phase 2D sweep |
| 2 | Hardware overhead was 148 KB (paper claimed <5 KB) | V2 PATCHED → 44 KB; honest reframe in paper rewrite |
| 3 | Tesla K80 GPU mention in paper | DELETE in Phase 3 rewrite |
| 4 | 8-core only compared SRRIP | Phase 2A fills the gap |
| 5 | Bloom filter never reset | ✅ PATCHED (Option A; 2026-05-21) |
| 6 | Coherence event hook coverage | ✅ A.1 + A.2 IMPLEMENTED (2026-05-21) — sharer_mask cleared on write hits, invalidation counter added |
| 7 | Worker-core regression at 8-core | Quantify in paper Discussion |
| 8 | θ = 35 undefined in paper | Document in Phase 3 rewrite |
| 9 | PC hash functions undefined in paper | Document in Phase 3 rewrite |
| 10 | "97% energy reduction" arithmetic | Now correct at 1/32 sampling (97% of write-port activity skipped) |
| 11 | ChampSim version / ROB / LSQ not documented | Capture for Methodology |
| 12 | Bibliography has only 5 entries | references.bib built (18 entries); wire in during rewrite |
| 13 | `jaleel2010high` vs `jaleel2010rrip` key mismatch | Find-and-replace during BibTeX migration |
| 14 | PARSEC version / input-size undocumented | Capture during trace generation |
| 15 | Allocator PC vs requester PC ambiguity | Document explicitly |
| 16 | **Two ChampSim source trees** — build reads headers from sibling repo | ⚠️ DISCOVERED 2026-05-21; cache_stats.h sync'd. Future header edits MUST also go to `/home/rajharsh/programming-playground/repos/ChampSim/inc/`. |

---

## 10. The 28-day HiPC sprint (high-level)

| Week | Dates | Phase activity |
|---|---|---|
| 1 | May 21–27 | Phase 2A starts (4-core matrix). Phase 1 citation work (mostly done). Paper outline. |
| 2 | May 28–Jun 3 | Phase 2A completes (8-core matrix). Phase 2D bias sweep launches. Paper Intro/Background/Motivation drafted. |
| 3 | Jun 4–10 | Phase 2B (16-core scaling). Phase 2C (LLC sensitivity). Phase 2E (3-seed re-runs). Paper draft v1 complete. |
| 4a | Jun 11–14 | Paper draft v2; advisor review. |
| 4b | Jun 15–17 | Polish + submit. |

---

## 11. Pointer hierarchy (read in this order if onboarding cold)

1. `CLAUDE.md` — repo overview, auto-loaded
2. `docs/COALESCE_EXPLAINED.md` — full technical narrative + glossary
3. `docs/OPEN_DECISIONS.md` — every known bug + decision
4. `coalesce_paper/COHERENCE_HOOK_AUDIT.md` — the simulator-MESI audit (critical for understanding what the results mean)
5. `docs/PUBLICATION_STRATEGY.md` — sprint plan and weakness inventory
6. `coalesce_paper/champsim_params_used.md` — simulator config reference
7. `simulator/replacement/coalesce/coalesce.h` + `coalesce.cc` — the policy code itself
8. `simulator/src/cache.cc` lines 141–313 — where MESI state and sharer_mask are managed
9. `simulator/btp_config.json` + `btp_8core_config.json` — sim configs
10. (Optional) `coalesce_paper/citations/` — citation map and per-parameter justifications, useful when writing the paper rewrite

---

## 12. What I want you (the new chat) to do

Concrete first 5 steps for the new chat:

1. **Verify the build**: `cd simulator && ./config.sh btp_config.json && make 2>&1 | tail -50`. Report any errors.
2. **Confirm trace availability**: `ls simulator/traces/`. Report which canneal/fluidanimate/dedup traces are present.
3. **Run V2 smoke test** (short, 5M instructions; ~10 min wall time). Compare IPC to the existing `results/canneal_4core_50M/final_COALESCE_50M.txt`.
4. **If sanity holds**: start Phase 2A baseline matrix. Use `nohup` or `screen` so runs survive disconnection. Run the four LLC policies (LRU, SRRIP, DRRIP, SHiP) at 4-core canneal first — these are the V0 comparison points and the fastest to complete.
5. **Aggregate results into a CSV** at `simulator/results/phase2a_summary.csv` as runs complete. Use `python3` + a small parser script if needed.

Don't touch:
- The COALESCE policy code (`simulator/replacement/coalesce/`) without asking Harsh — architecture is FROZEN for Saga 1.
- The PARSEC trace files (~18 GB; gitignored).
- Phase 3 paper rewrite (separate work; this chat is Phase 2).

Do tell Harsh if:
- Any simulator build error occurs.
- V2 smoke results diverge >10% from V0.
- Fluidanimate or dedup traces are missing.
- Any Phase 2A run hangs or crashes.

---

## 13. Quick facts for context

- **HiPC 2026 main track deadline**: 2026-06-17 (full paper, ~10 pages, IEEE format).
- **Today**: 2026-05-21. 27 days remaining.
- **Architecture is FROZEN**: only parameter sweeps to *justify* current choices. No structural changes to the COALESCE policy.
- **ChampSim is CPU-only**: it's a single-threaded C++ trace-driven simulator. No GPU acceleration. The paper draft's mention of a "Tesla K80 GPU cluster" is wrong and gets deleted in the rewrite.
- **PIN MT-Sync tracer** (in `simulator/tracer/`): how multi-core traces are generated to preserve coherence ordering.
- **Existing baselines and policies live in** `simulator/replacement/{lru,srrip,drrip,ship,random,coalesce}/` — pluggable via config JSON.
- **No commits have been made for the Phase 1 work** as of 2026-05-21; Harsh hasn't asked. Don't auto-commit.

---

## 14. Summary in one paragraph

COALESCE is a coherence-aware perceptron-based LLC replacement policy with current results showing +24% IPC over LRU at 4-core canneal (but losing to DRRIP/SHiP by 1.8%) and 33% cycle reduction over SRRIP at 8-core canneal (sole 8-core baseline so far). For HiPC 2026 (deadline Jun 17), the experimental gap is filling out the 5×3×2 baseline matrix (5 policies × 3 PARSEC benchmarks × 4-core/8-core), then a scaling study, LLC sweep, bias sweep, and statistical re-runs. Code is currently in V2 config (SAMPLING_MODULO=32, GHOST_CAPACITY=128, BLOOM_RESET_THRESHOLD=150) — reduces metadata storage from ~148 KB to ~44 KB. A coherence-hook audit found the simulator does not model invalidation traffic, only writebacks; the wins we measure are retention-driven hit-rate effects on bottleneck cores, which is real but the paper's mechanism narrative needs honest reframing. Next step: launch Phase 2A baseline matrix.

---

## 15. Session log — 2026-05-28/29 (Phase 2A 8-core complete + 16-core prep)

### Server reality (iiitsgpu)

- Host: dual Xeon E5-2670 v3, 24 physical / 48 logical cores, 251 GB RAM, 1.6 TB free on /home. NUMA: node0 = even CPUs, node1 = odd CPUs.
- Server path: `/home/harshraj/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy/` (NOT the same path as local; local is `/home/rajharsh/...`).
- Connect: `ssh -p 2222 harshraj@61.1.175.170`. scp uses `-P 2222` (capital P). The hostname `iiitsgpu` does NOT resolve from local WSL — use the IP.
- **Box is shared and busy.** During this run, load average was ~22–30. Two other users (`mohanganesh` ~19 cores of Python, `saketh` ~9 cores) held most of the box. Effective budget was ~3–5 contended cores, NOT the full 24. This is why runs are ~10× slower than a dedicated box.
- Server `simulator/absolute.options` points `-I` at the **local** `simulator/inc` (single source of truth) — so the two-tree header gotcha (OPEN_DECISIONS #16) does NOT apply on the server. Header edits build directly. (The two-tree problem is local-WSL-only.)

### Git state (important)

- Server can't push to GitHub (storage/quota issue). All code transfer is via patches generated locally + applied with `git apply` on the server.
- Server HEAD `1b56a25` ("Final 8-core simulation results: COALESCE complete, SRRIP partial") is a server-only commit not on origin.
- Origin is ahead of the server by `0ddc2ee` + `79da2c8` (research paper + 8-core results) — server never pulled these.
- Local has `33645cb` (V2 code) + `099628d` (docs) that never reached origin. The V2 commit (`33645cb`) was manually applied to the server this session via heredoc patch.
- **Divergence is intentional and unresolved.** Do NOT attempt a git merge of server↔origin until after HiPC — both committed similar result files and would conflict. Work on the server's working tree directly.

### Workflow lesson learned

- Pasting multi-line scripts directly into the SSH terminal **corrupts them** (strips quotes, adds leading whitespace, splits at backslash continuations). This wasted ~2 hours across two stalls (a hung `jq` waiting on stdin, a runaway smoke loop).
- **Fixed workflow**: Claude writes script to local `/tmp/*.sh` → user `scp -P 2222`s it to server → runs `bash ~/script.sh` inside `tmux`. Single-line commands paste fine; multi-line scripts must go via scp.
- Always launch long runs inside `tmux` (`tmux new -s NAME`, detach Ctrl-B then D, reattach `tmux attach -t NAME`) so SSH drops don't kill them. Run sims `nice -n 19` to be a polite citizen on the shared box.

### ✅ Phase 2A — 8-core canneal baseline matrix COMPLETE (resolves weakness A2)

All 5 policies ran 50M warmup + 100M sim/core, 2 MB shared LLC, V2 code. **All completed full 100M on all 8 cores** (verified via `Simulation finished CPU N instructions: 100000000` lines — note this fork uses "Simulation finished", NOT "Finished CPU").

| Policy | Max cycles | COALESCE faster by | Bottleneck IPC (CPU1/6 avg) | Worker IPC (CPU0/5 avg) |
|---|---|---|---|---|
| **COALESCE** | **415,157,549** | — | **0.2415** | 2.057 |
| SRRIP | 619,411,244 | 33.0% | 0.1616 | 2.104 |
| SHiP | 621,172,900 | 33.2% | 0.1612 | 2.0985 |
| DRRIP | 627,034,759 | 33.8% | 0.1598 | 2.099 |
| LRU | 640,322,745 | 35.2% | 0.1565 | 1.5415 |

Bottleneck-core IPC gain: +49.4% vs SRRIP, +49.8% vs SHiP, +51.1% vs DRRIP, +54.3% vs LRU.

- **COALESCE now beats ALL FOUR baselines** at 8-core, not just SRRIP. Weakness A2 (cherry-picked weakest baseline) is dead.
- **V2 reproduces V0 almost exactly**: V0 was COALESCE 415.9M / SRRIP 620.6M; V2 is 415.2M / 619.4M. The 3.6× storage cut (148→44 KB) and accurate (non-monotonic) sharer_mask cost nothing. Reproducibility = strength to cite.
- **Coherence invalidations = 0 for every policy** over the full run. Confirms COHERENCE_HOOK_AUDIT: canneal write-hits rarely hit multi-sharer LLC lines, so the win is **retention-driven hit-rate** on bottleneck cores, NOT invalidation savings. Mechanism narrative in the paper must say this.
- **Worker regression (A9) persists**: COALESCE workers ~2% below RRIP variants but +33% above LRU. Net win is dominated by bottleneck cores that gate canneal completion. Frame as favourable critical-path trade-off.
- **Aggregate LLC-miss counts are NOT comparable across policies** — faster completion means fast cores stream fewer extra instructions (COALESCE CPU7 ran 1.66B instr vs LRU's 2.56B). Use per-core ROI-normalized stats for any miss-rate claim; never compare summed misses directly.

**Saved artifacts (local, since server can't push):**
- `simulator/results/phase2a_8core_canneal_V2/summary_8core_canneal_V2.csv` — machine-readable
- `simulator/results/phase2a_8core_canneal_V2/RESULTS_8core_canneal_V2.md` — paper-ready writeup
- Raw logs remain on server at `results/phase2a_8core_canneal_V2/logs/{policy}_50M_100M.log` (~2 MB total; not yet backed up locally — TODO scp them down).

### ⏱️ Run timing (and a ⚠️ flag worth investigating)

Wall-clock per policy (under heavy server contention, so absolute numbers are inflated ~10×; the RELATIVE picture is what matters):

| Policy | Wall time |
|---|---|
| SHiP | ~8 hr 06 min |
| DRRIP | ~8 hr 12 min |
| SRRIP | ~8 hr 33 min |
| LRU | ~8 hr 49 min |
| **COALESCE** | **~22 hr 28 min** |

⚠️ **COALESCE took ~2.7× longer in wall-clock than the simple policies — flag this as suspicious / worth investigating.** Two competing explanations:
1. **Benign**: COALESCE does real extra per-access work (2 perceptron-table lookups + bloom-filter ops + ghost-buffer insert/lookup on sampled sets) AND it finishes the simulated workload in far fewer CYCLES (415M vs ~620M), but cycles ≠ wall-clock. The wall-clock is dominated by how many trace records get processed. Because the fast streaming cores (2,3,4,7) keep running at IPC≈4 until the bottleneck cores hit 100M, and COALESCE's bottleneck cores are faster, the run length in *events processed* could differ. Need to confirm.
2. **Concerning**: a hot path in the COALESCE module (e.g. the per-way sharer-decode loops, now widened to i<16) could be disproportionately expensive, OR COALESCE was simply unlucky with which foreign jobs shared its cores during its 22 hr window. The 8-core SHiP/DRRIP/SRRIP/LRU all clustered at ~8 hr while COALESCE alone ran 22 hr — if it were pure contention luck we'd expect more spread among the others too.
- **To investigate** (cheap): compare `instructions:` totals on the fast cores across logs (COALESCE CPU7 = 1.66B vs LRU CPU7 = 2.56B). If COALESCE processed FEWER total trace events but still took 2.7× longer, that points to per-access overhead (explanation 2). If it processed similar/more events, explanation 1. Also re-run COALESCE alone on an idle box and time it to remove the contention variable. Not a blocker for the result (cycles are what we report), but matters for the paper's "practicality / overhead" framing and for estimating future run budgets.

### 🔧 16-core enablement (code change — done locally, applied to server)

16-core was NOT a simple config bump. `sharer_mask` was `uint8_t` (max 8 cores) with five hardcoded `for(i=0;i<8)` sharer-count loops + three `static_cast<uint8_t>` truncations. At 16 cores, cores 8–15 would silently vanish from coherence tracking (no crash, just wrong sharer counts → corrupts COALESCE's whole premise). Widened to `uint16_t` / `i<16` everywhere:
- `simulator/inc/block.h`: `uint8_t sharer_mask` → `uint16_t`
- `simulator/src/cache.cc`: 3 casts → uint16_t, 1 read-hit loop → i<16
- `simulator/replacement/coalesce/coalesce.cc`: 3 sharer-decode loops → i<16
- Patch: `/tmp/16core_widening.patch` (71 lines, verified well-formed). Applied to server via `git apply` (must `cd` into repo root first — paths are repo-relative).
- Helper scripts (local `/tmp`, scp'd to server): `setup_16core.sh` (guards patch applied, builds 5 binaries, runs a CPU-15 validation smoke), `run_16core_matrix.sh` (5 policies, 50M+100M, tmux), `status_16core.sh` (monitor).
- Config: `btp_16core_config.json` = 8-core config with `num_cores=16`, LLC unchanged at 2 MB. Trace pattern replicates the 5 unique canneal traces to fill 16 inputs.
- **Decision**: running all 5 policies at 16-core (strategy doc said 3; parallelism is free on the box, and a complete 16-core matrix matches the complete 8-core matrix for a clean 4→8→16 scaling figure).
- **Time estimate**: 16-core ≈ 2× the work per policy; COALESCE could be ~40+ hr under contention. Budget ~2 days wall. Still fine vs Jun 17.

### Parser / tooling notes

- `parse_phase2a.py` (local `/tmp`, scp'd to server) parses the `Simulation finished CPU N instructions: ... cycles: ... cumulative IPC: ...` format. The earlier parser failed because it grepped for "Finished CPU" — this ChampSim fork emits "Simulation finished CPU".
- ROI completion lines have `instructions: 100000000` exactly; the fast cores also emit much higher cumulative `instructions:` in "Simulation complete" lines (their total trace consumption) — don't confuse the two.

### Remaining sprint queue (priority order per Harsh: 8→16→4, then breadth)

1. ✅ 8-core canneal (DONE)
2. 🔄 16-core canneal (setup running / matrix next)
3. ⏳ 4-core canneal V2 redo (5 policies — supersedes V0 4-core data)
4. ⏳ PIN install + fluidanimate/dedup trace generation (PIN binary NOT present on server; PARSEC source IS at `simulator/tracer/pin/parsec-3.0`). Parallel overnight track.
5. ⏳ Phase 2D sweeps (bias, perceptron size, ablation)
6. ⏳ Phase 2E 3-seed statistical re-runs
7. ⏳ Aggregate → CSVs + paper figures ("the bang")
