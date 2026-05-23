# COALESCE — Project Context

> **One-liner**: COALESCE = Coherence-Observant Adaptive Learning for System-wide Cache Efficiency. A coherence-aware perceptron LLC replacement policy implemented as a ChampSim module.
>
> **Owner**: Harsh Raj (S20240010084) · **Advisor**: Dr. Bheemappa Halavar · **Context**: B.Tech project, IIIT Sri City
>
> **Status banner (as of 2026-05-21)**
> - 🔒 **Architecture FROZEN** — no structural changes. Only parameter sweeps to justify current choices.
> - 🎯 **Active sprint**: 28-day HiPC 2026 push. Deadline = **June 17, 2026**. Today = Day 1.
> - 📋 Full strategy: `docs/PUBLICATION_STRATEGY.md`
> - ⚠️ **CRITICAL BUILD GOTCHA**: the build's `-I` path reads headers from **`/home/rajharsh/programming-playground/repos/ChampSim/inc/`** (sibling repo), not `simulator/inc/`. Edits to anything in `simulator/inc/` must be **mirrored** in the sibling repo, or the build won't see them. Source files (`simulator/src/*.cc` and `simulator/replacement/coalesce/*`) DO get picked up via relative path. See `docs/OPEN_DECISIONS.md` item #16.
> - 📖 Narrative explainer of the project: `docs/COALESCE_EXPLAINED.md`
> - ⚠️ All known bugs / discrepancies / pending decisions: `docs/OPEN_DECISIONS.md`
> - 🧾 Phase 1 citation work (in progress): `coalesce_paper/citations/`
> - 🔌 Coherence event hook audit (LLC MESI is simplified — no invalidation modeling): `coalesce_paper/COHERENCE_HOOK_AUDIT.md`
> - 📦 Self-contained handoff doc for fresh chats: `docs/SESSION_CONTEXT.md`

---

## Repo layout

```
COALESCE/
├── simulator/                       # ChampSim-based environment (Phase 2 — primary)
│   ├── replacement/
│   │   ├── coalesce/                # ★ The COALESCE policy
│   │   ├── lru/  srrip/  drrip/  ship/  random/   # Baselines
│   ├── inc/                         # Headers (block.h has MESI_State + sharer_mask)
│   ├── src/                         # ChampSim core (cache.cc, ooo_cpu.cc, dram_controller.cc)
│   ├── traces/                      # PARSEC traces — GITIGNORED (~18 GB)
│   ├── results/
│   │   ├── canneal_4core_50M/       # 4-core results: COALESCE, LRU, DRRIP, SHIP, random
│   │   └── canneal_8core_100M/      # 8-core: COALESCE vs SRRIP only (gap A2 to fix)
│   ├── tracer/                      # Intel PIN 3.31 MT-Sync tracer
│   ├── btp_config.json              # 4-core sim config (LLC 2 MB, 2048 sets × 16 ways)
│   └── btp_8core_config.json        # 8-core sim config (shared LLC 2 MB)
├── simulations/
│   └── coalesce_final.cpp           # Phase 1 standalone event-driven simulator (historical)
├── latex/                           # GITIGNORED
│   ├── paper/coalesce_hipc.tex      # Current HiPC draft (232 lines, IEEE format)
│   ├── paper/generate_graphs.py     # Figure generation (hardcoded data, matplotlib)
│   ├── paper/{1..5}_*.png           # 5 figures used in paper
│   ├── COALESCE.tex                 # Mid-term beamer slides
│   └── latex2/end_term.tex          # End-term beamer slides
├── reports/                         # BTP progress reports (PDFs)
├── docs/PUBLICATION_STRATEGY.md     # Full Saga 0/1/2 publication plan
├── README.md                        # Build/run instructions, results summary
├── AIM.md                           # Project vision ("Coherence Wall") — GITIGNORED
├── ARCHITECTURE.md                  # Technical design notes — GITIGNORED
└── CLAUDE.md                        # This file
```

**Gitignored**: `AIM.md`, `ARCHITECTURE.md`, `latex/`, `simulator/traces/`, `simulator/bin/`, `simulator/vcpkg/`, `simulator/vcpkg_installed/`, `simulator/archive_logs/`, `simulator/tracer/pin/*.tar.gz`.

---

## COALESCE implementation map

| Component | File | Key lines / symbols |
|---|---|---|
| Data structures, constants | `simulator/replacement/coalesce/coalesce.h` | Lines 9–18 (constants), 20–30 (`CompactGhostEntry`), 32–39 (`BloomFilter`), 41–50 (`PerceptronBrain`), 53–63 (`coalesce` module) |
| Core logic | `simulator/replacement/coalesce/coalesce.cc` | `find_victim()` lines 98–138 · `update_replacement_state()` 140–170 · `predict_raw()` 69–71 · `train()` 72–86 |
| MESI + sharer-mask extensions | `simulator/inc/block.h` | `enum MESI_State {INVALID, SHARED, EXCLUSIVE, MODIFIED}`, `uint8_t sharer_mask` in `cache_block` |
| Phase 1 standalone sim (reference only) | `simulations/coalesce_final.cpp` | Historical — do not modify; ChampSim is the source of truth |

### How the policy works (1-paragraph mental model)

Two orthogonal 2048-entry hashed-perceptron tables vote on each candidate way. Inputs: PC, MESI state, sharer count (decoded from `sharer_mask`). Raw vote = `table0[hash0(pc, state)] + table1[hash1(pc, sharers)]`. A coherence bias is added only when the raw vote is positive (line 116): `+40` if MODIFIED, `+20×sharers` if sharers ≥ 2. The way with the **lowest** final vote is evicted. Training happens only on sampled sets (every 32nd set, i.e. 3.125% under the V2 config): on hit → reward (`+1` to both tables); on miss with a Bloom-filter ghost-tag hit → boosted reward applied 5× to "rescue" wrongly-evicted contexts.

---

## Key parameters — **authoritative values from `coalesce.h`**

| Parameter | Value | Constant |
|---|---|---|
| Perceptron tables | **2 × 2048 entries** (orthogonal feature hashes) | `PERCEPTRON_TABLE_SIZE = 2048` |
| Weight range | 8-bit signed: **[−128, +127]** | `MIN_WEIGHT`, `MAX_WEIGHT` |
| Train-on-low-confidence threshold | **35** | `THRESHOLD = 35` |
| Bloom filter size | **1024 bits, 3 hashes** | `BLOOM_SIZE`, `BLOOM_HASHES` |
| Bloom periodic reset | every **150 insertions** (added 2026-05-21) | `BLOOM_RESET_THRESHOLD = 150` |
| Ghost-tag capacity per sampled set | **128 entries** (V2 config, 2026-05-21; was 256 in V0) | `GHOST_CAPACITY = 128` |
| Set sampling | **Every 32nd set (3.125%)** (V2 config, 2026-05-21; was 1/16 in V0) | `SAMPLING_MODULO = 32` |
| Ghost-hit training boost | **5× repeat** on rescue | hard-coded `for(k=0; k<5; k++)` (coalesce.cc:164) |
| Coherence bias — MODIFIED | **+40** (paper text says +150 — discrepancy, see below) | coalesce.cc:117 |
| Coherence bias — sharers ≥ 2 | **+20 × sharers** (paper text says +75) | coalesce.cc:118 |
| LLC geometry | **2048 sets × 16 ways × 64 B = 2 MB** (shared) | `btp_config.json`, `btp_8core_config.json` |
| Ghost entry encoding | 12-bit pc_sig · 14-bit tag_partial · 3-bit sharers · 2-bit state · 1-bit valid | coalesce.cc:5–11 |

### ⚠️ Known discrepancies (track these — do not silently "fix")

- **Bias values**: code uses `+40 / +20×sharers`. Paper text says `+150 / +75`. Resolution path: Phase 2D bias sweep (see strategy doc, weaknesses B2/B3). Until then, the **code is the source of truth** for what produced the existing results.
- **ARCHITECTURE.md drift**: legacy doc has been corrected to match code (May 2026), but is still gitignored. If reading old commits, expect 4096/32x/8-way numbers in older versions.

---

## Build & run

```bash
cd simulator

# 4-core configuration
./config.sh btp_config.json
make                                # → bin/champsim_btp_test

# 8-core configuration
./config.sh btp_8core_config.json
make                                # → bin/champsim_8core_coalesce
```

**Run 4-core**:
```bash
bin/champsim_btp_test \
  --warmup-instructions 200000000 --simulation-instructions 50000000 \
  traces/canneal_big{0,1,2,3}.champsimtrace
```

**Run 8-core**:
```bash
bin/champsim_8core_coalesce \
  --warmup-instructions 1000000000 --simulation-instructions 100000000 \
  traces/canneal_big{0,1,2,3,4,0,1,2}.champsimtrace > results/.../out.txt
```

**Switching policy**: edit `"replacement"` under `"LLC"` in the config JSON (`coalesce | lru | srrip | drrip | ship | random`), then `./config.sh <cfg> && make clean && make`.

**Dependencies**: GCC 10+, Make, Python 3, vcpkg-installed CLI11/LZMA/Bzip2/fmt.

---

## Current headline results (paper draft)

| Config | Workload | COALESCE | Baseline | Δ | Where the data lives |
|---|---|---|---|---|---|
| 4-core, 50 M instr/core | canneal | IPC **0.4996** | LRU 0.4023 | **+24.2 %** | `simulator/results/canneal_4core_50M/` |
| 4-core, 50 M instr/core | canneal | IPC 0.4996 | DRRIP 0.5072, SHiP 0.5090 | **−1.8 %** (we're 4th of 4) | same dir — this is weakness **A1**, needs honest framing |
| 8-core, 100 M instr/core | canneal | **415.9 M cycles** | SRRIP 620.6 M | **~33 % faster** | `simulator/results/canneal_8core_100M/` |
| 8-core, bottleneck cores (CPUs 1, 6) | canneal | IPC 0.241 / 0.240 | SRRIP 0.162 / 0.161 | **+49 %** | same dir |
| 8-core, worker cores (CPUs 0, 5) | canneal | IPC 2.088 / 2.027 | SRRIP 2.120 / 2.073 | **slight regression** (weakness A9) | same dir |

**Missing comparisons (blocking HiPC acceptance)**: at 8-core only SRRIP exists; LRU/DRRIP/SHiP runs are weakness **A2** in the strategy doc — to be filled by Phase 2A.

---

## Active sprint at a glance (full plan in `docs/PUBLICATION_STRATEGY.md`)

| Track | What | When |
|---|---|---|
| **P1 — Citations** | Map every magic number to a citation or derivation. 11 references to add (Hawkeye, Mockingjay, Glider, SHiP/RRIP originals, Belady, Sorin/Hill/Wood, Jiménez & Lin 2001, Hennessy & Patterson). | Weeks 1–2, async |
| **P2 — Experiments** | 4/8-core baseline matrix across all 5 policies × 3 PARSEC benchmarks (canneal, fluidanimate, dedup); 16-core scaling; LLC size sweep; bias/perceptron-size sweeps; 3-seed statistical re-runs. | Weeks 1–3, server bound |
| **P3 — Paper rewrite** | Add Motivation + Background + Threats-to-Validity sections; honest 4-core framing; drop "Tesla K80 GPU cluster" line; expand related work to ≥15 refs. | Weeks 2–4 |
| **Submission** | HiPC main track | **Jun 17, 2026** |
| **Follow-on** | IEEE CAL distillation (rolling); then Saga 2 → ASPLOS 2027 Summer (Sept 9, 2026) | Post-HiPC |

---

## Do **not**

- Propose architectural changes to COALESCE. Architecture is frozen for Saga 1 (HiPC sprint). Parameter sweeps only.
- Mention **"Tesla K80 GPU"** or any GPU acceleration in writing — ChampSim is **CPU-only**. The paper's existing K80 line is weakness C1 and gets deleted in the rewrite.
- Re-derive parameters without first checking `docs/PUBLICATION_STRATEGY.md` weakness inventory (Section 2) and the citation map (Phase 1 output, when it exists).
- Add **Hawkeye / Mockingjay** baseline implementations. Deferred to Saga 2 — too expensive for the 28-day sprint.
- Add **SPEC CPU2017** benchmarks. Single-core SPEC doesn't exercise coherence, so COALESCE shouldn't help; will be called out as a limitation, not run.
- Touch `simulations/coalesce_final.cpp` (Phase 1 standalone sim). It's historical reference only; ChampSim is the source of truth.
- Silently reconcile the **bias-value discrepancy** (+40/+20×s in code vs +150/+75 in paper). Flag it, don't rewrite either side until Phase 2D resolves.

---

## Pointers

- **Strategy plan**: `docs/PUBLICATION_STRATEGY.md` — Sagas 0/1/2, weakness inventory A–E, compressed sprint, decision log
- **Project explainer (narrative)**: `docs/COALESCE_EXPLAINED.md` — how COALESCE works end-to-end, walkthrough of victim selection + training, honest reading of existing results
- **Open decisions / bugs**: `docs/OPEN_DECISIONS.md` — every known issue with options + recommendations, sorted by severity
- **Phase 1 citation work**:
  - `coalesce_paper/citations/citation_map.md` — Phase 1 plan + deliverables checklist
  - `coalesce_paper/citations/references.bib` — 18-entry BibTeX master (Day 1 + Week 1 + Week 2 batches)
  - `coalesce_paper/citations/justifications/B{1..10}_*.md` — per-parameter justifications
  - `coalesce_paper/citations/related_work_notes/D{1..11}_*.md` — per-paper related-work notes
  - `coalesce_paper/champsim_params_used.md` — discovered ChampSim config (DDR4-3200, tRP=tRCD=tCAS=24, etc.)
- **Current paper draft**: `latex/paper/coalesce_hipc.tex` (gitignored)
- **Figure regeneration**: `latex/paper/generate_graphs.py` (gitignored, data hardcoded)
- **Project vision** (legacy): `AIM.md` (gitignored)
- **Technical design notes** (corrected May 2026): `ARCHITECTURE.md` (gitignored)
- **Mid-review / end-term slides**: `latex/COALESCE.tex`, `latex/latex2/end_term.tex` (gitignored)

---

## Open items the user is tracking (May 21, 2026)

1. **HiPC deadline form**: is Jun 17 abstract-only or full paper? Verify on hipc.org.
2. **Server access on Day 1**: confirm CPU/RAM/parallelism level before launching Phase 2A.
3. **Trace generation**: are `fluidanimate` and `dedup` PIN traces already on disk or do they need to be generated this week?
4. **Sir's review window**: confirm 2-day turnaround for week 4 (Jun 11–16).
