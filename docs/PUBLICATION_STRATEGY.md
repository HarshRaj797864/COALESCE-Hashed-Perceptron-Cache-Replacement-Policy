# COALESCE — Publication Strategy (Finalized)

> **Status**: Finalized v1.0 — May 20, 2026
> **Owner**: Harsh Raj
> **Architecture status**: **FROZEN.** No structural changes to COALESCE — only parameter sweeps to *justify* current choices. Architecture changes happen only if sweeps prove a clearly better operating point AND the result is reproducible across benchmarks.
>
> Related notes: [[02_architecture]] · [[03_experiments]] · [[04_paper_conference]]

---

## 0. Saga Map

| Saga | Focus | Outcome | Window |
|---|---|---|---|
| **Saga 0** | Refactor existing paper into sir's template format. User-solo, no AI input. | Polished current draft | Continuous, background |
| **Saga 1** | Tier 3 publication push: **IEEE CAL + HiPC 2026 SRS/main**. Tackle weaknesses minimally, get peer-reviewed publication on CV. | 1–2 submitted papers | **May 20 → July 31, 2026** |
| **Saga 2** | Tier 2/1 waterfall starting with ASPLOS / HPCA / ISCA / MICRO. Expanded evaluation, deeper rigor. | Top-tier publication | Aug 2026 → mid-2027 |

**Iteration rule**: Phases inside each Saga are *not* strictly sequential. After running Phase 2 experiments we may discover gaps that send us back to Phase 1 citation hunt. After Phase 3 paper rewrite we may identify a missing experiment in Phase 2. Loop until convergence.

---

## 1. Venue Clarifications & Strategy

### HPCA vs HiPC — they are different conferences

- **HPCA** = High-Performance Computer Architecture. **Tier 1** (ISCA/MICRO/HPCA are the "big three" architecture venues). Acceptance rate ~20%. *No student-specific track.* HPCA 2026 happened Feb 2026 in Sydney; **HPCA 2027 ≈ Jul/Aug 2026 deadline**, conference Feb/Mar 2027.
- **HiPC** = High Performance Computing, Data, and Analytics. **Tier 3** (good fit, more accessible). IEEE-sponsored, India-based. **HiPC 2026 = 33rd edition, Dec 16–19, 2026 in India.** *Has a Student Research Symposium (SRS) — this is what sir referenced.*

### Saga 1 venue plan

| Venue | Deadline | Format | Decision logic |
|---|---|---|---|
| **IEEE CAL** | Rolling, anytime | 4 pages | Submit ~late June. Distilled "early result" focused on 8-core bottleneck-core win. CAL *explicitly permits extended versions at later conferences* — no conflict with HiPC. |
| **HiPC 2026 main track** | **~July 2026** (verify on hipc.org once CFP page is up — 2022 SRS was 14th edition, 2026 is 33rd main) | 10 pages (full paper) | Primary Saga 1 deliverable. Full evaluation expanded per Phase 2 below. |
| **HiPC 2026 SRS** | Typically ~Sept 2026 (later than main track) | Short paper / poster | Backup if HiPC main rejects, or supplementary if main accepts. |

### Saga 2 waterfall (Aug 2026 → mid-2027)

After HiPC submission, immediately begin expanding for Tier 1. Strict waterfall — don't submit to the next tier until rejected from the current one (concurrent submission = blacklist):

| Order | Venue | Tier | Deadline | Rationale |
|---|---|---|---|---|
| 1 | **HPCA 2027** | 1 | ~Jul/Aug 2026 | Best Tier-1 fit for cache replacement. **Conflict warning: overlaps with HiPC window.** Only submit if HiPC version is *substantially extended* AND HiPC notification has come back. Otherwise skip HPCA 2027 and go to ASPLOS Summer. |
| 2 | **ASPLOS 2027 Summer** | 1 | **Sept 9, 2026** (verified) | Two cycles per year, accepts major revisions. Best waterfall target if HPCA isn't ready. |
| 3 | **ISCA 2027** | 1 | ~Nov 2026 | Premier venue. Hardest tier. |
| 4 | **MICRO 2027** | 1 | ~Apr 2027 | THE venue for cache replacement historically (SHiP, Hawkeye, Multiperspective all appeared here). |
| 5 | **PACT 2027** | 2 | ~Apr 2027 | Safety net if Tier 1 fully fails. |
| 6 | **IEEE TC** (journal) | 2 | Rolling | Final journal path with no deadline pressure. |

**Note on HPCA 2027 conflict**: HPCA 2027 deadline (~early Aug) is too close to HiPC (~late July) for a clean revision cycle. Recommend skipping HPCA 2027 and going directly to ASPLOS 2027 Summer (Sept 9, 2026) for Saga 2's first attempt. HPCA 2028 (~Jul/Aug 2027) becomes a stronger target after a full year of expansion work.

---

## 2. The Weakness Inventory

Every weakness Saga 1 must address, ranked by severity. Each one corresponds to a specific reviewer objection.

### A. Evidence & Rigor (CRITICAL — reviewers reject for these)

| # | Weakness | Severity | Phase |
|---|---|---|---|
| A1 | 4-core canneal: COALESCE has *more* misses than SHiP/DRRIP (539K vs 452K). Current framing "within 1.8% of SRRIP" hides being 4th of 4. | 🔴 Critical | Phase 3 (honest framing) |
| A2 | 8-core results only compare to SRRIP. Missing LRU, DRRIP, SHiP — reviewer's first question: "did you cherry-pick the weakest baseline?" | 🔴 Critical | Phase 2 (run all baselines at 8-core) |
| A3 | Single benchmark (canneal only). Multicore architecture papers need 5+ workloads. | 🔴 Critical | Phase 2 (add fluidanimate, dedup, +1) |
| A4 | No scaling study (4 / 8 / 16-core trend). Hides whether the win scales or plateaus. | 🟠 High | Phase 2 |
| A5 | No LLC size sensitivity (e.g., 1MB / 2MB / 4MB / 8MB). | 🟠 High | Phase 2 |
| A6 | No perceptron table size sensitivity (e.g., 512 / 1024 / 2048 / 4096 entries). | 🟠 High | Phase 2 |
| A7 | No bias value sweep — +150 / +75 currently asserted, not derived. | 🟠 High | Phase 2 |
| A8 | No statistical rigor — single runs, no error bars, no geometric means. | 🟠 High | Phase 2 |
| A9 | Worker cores see slightly *lower* IPC under COALESCE. Currently mentioned briefly but not analyzed. | 🟡 Medium | Phase 3 |
| A10 | No ablation study (PC-only vs PC+MESI vs PC+sharers vs full COALESCE). Proves all three features matter. | 🟡 Medium | Phase 2 |

### B. Architectural Justification (must-fix before submission)

| # | Weakness | Severity | Source/Resolution |
|---|---|---|---|
| B1 | "200+ cycles" DRAM writeback — no citation. | 🔴 Critical | Hennessy & Patterson (6th ed.); Intel optimization manual; Molka et al. PACT 2009; cite ChampSim DRAM params |
| B2 | +150 Modified bias value — not derived. | 🟠 High | Phase 2 bias sweep → empirical optimum, then *explain* as approximate ratio of writeback cost to clean-miss cost |
| B3 | +75 Sharer bias value — not derived. | 🟠 High | Same sweep |
| B4 | 5× ghost-hit weight boost — no justification. | 🟡 Medium | Sweep or cite perceptron papers using similar boost factors |
| B5 | 6.25% set sampling rate — looks arbitrary. | 🟢 Low | This comes directly from Jiménez 2017 — just cite it |
| B6 | θ confidence threshold value not specified anywhere. | 🟡 Medium | Phase 1 — specify the value used, cite if from prior work |
| B7 | 1024-bit Bloom filter, 3 hashes — no FP rate calculation. | 🟢 Low | Show math: k* = (m/n)·ln2; report measured FP rate at typical occupancy |
| B8 | MESI state coding rationale unclear (2 bits for 4 states is fine, but tag-bit overhead unjustified). | 🟢 Low | Phase 3 |
| B9 | PC hashing function details missing — what does H0/H1 actually compute? | 🟡 Medium | Phase 3 — specify XOR-fold + truncation |
| B10 | Sorin/Hill/Wood coherence primer not cited despite using MESI throughout. | 🟢 Low | Phase 1 — add citation |

### C. Methodology (reviewers will probe these)

| # | Weakness | Severity | Resolution |
|---|---|---|---|
| C1 | "Tesla K80 GPU cluster" misleading — ChampSim is CPU-only. | 🔴 Critical | Phase 3 — rewrite as "Linux host server, [CPU spec], [N] GB RAM" |
| C2 | MT-Sync PIN tracer validation absent — reviewer: "how do you know coherence ordering is correct?" | 🟠 High | Phase 3 — add validation: e.g., total ordering check, sanity benchmark with known sharing patterns |
| C3 | ChampSim version not specified. | 🟢 Low | Phase 3 |
| C4 | DRAM model parameters (tRCD/tCAS/tRP/channels) not reported. | 🟡 Medium | Phase 3 |
| C5 | L1/L2 cache sizes and policies not reported. | 🟡 Medium | Phase 3 |
| C6 | Warmup instructions count not specified. | 🟡 Medium | Phase 3 — typical: 10–50M warmup, then measure |
| C7 | No energy/area analysis (CACTI numbers for the perceptron tables). | 🟢 Low for HiPC, 🔴 Critical for Tier 1 | Defer to Saga 2 |

### D. Related Work (currently only 5 references — must expand to 20+)

| # | Missing reference | Why it matters |
|---|---|---|
| D1 | Hawkeye (Jain & Lin, ISCA 2016) | THE current SOTA for ML cache replacement — your most important comparison |
| D2 | Mockingjay (Shah et al., ISCA 2022) | Recent SOTA; uses reuse distance regression |
| D3 | Glider (Shi et al., ISCA 2019) | LSTM-based; shows ML at the predictor level |
| D4 | SHiP (Wu et al., MICRO 2011) — original paper, not just RRIP | You compare against SHiP; cite the source |
| D5 | DRRIP / SRRIP (Jaleel et al., ISCA 2010) — full original | You currently cite RRIP partially |
| D6 | Belady's MIN (1966) | The theoretical optimal baseline; every cache paper cites it |
| D7 | Cuesta et al. (ISCA 2011) — coherence deactivation | Coherence-aware optimization prior art |
| D8 | Hardavellas et al. (ISCA 2009) — Reactive NUCA | Coherence + cache placement |
| D9 | Sorin/Hill/Wood primer (Synthesis Lectures) | Canonical MESI reference |
| D10 | Jiménez & Lin (HPCA 2001) — original perceptron predictor | Origin of the technique you use |
| D11 | Hennessy & Patterson textbook (6th ed.) | For latency claims |

### E. Paper Structure (Phase 3 rewrite scope)

| # | Weakness | Resolution |
|---|---|---|
| E1 | No Motivation section with measured data (e.g., "X% of evictions trigger writebacks, Y% trigger invalidations on canneal") | Add Section 2 |
| E2 | No formal Background section (MESI definition, sharer count semantics, reference architecture diagram) | Add Section 3 |
| E3 | No Threats to Validity / Limitations section | Add explicit section |
| E4 | No honest framing of 4-core trade-off | Rewrite Section 5A |
| E5 | No perceptron learning curve / convergence analysis | Add Figure |
| E6 | References thin (5 entries) | Expand to 20+ per Section D above |
| E7 | "Tesla K80 GPU cluster" misleading mention | Remove / rewrite (also in C1) |

---

## 3. The Three-Phase Plan (Iterative, Not Sequential)

### Phase 1 — Citations & Architectural Justification

**Goal**: Every magic number gets a citation OR a derivation. No assertions without sources.
**Output**: `phase1_citation_map.md` (a table mapping every parameter to its source).
**Estimated effort**: ~10 days, parallelizable with Phase 2 simulations starting.

Activities:
1. Read & extract from: Hennessy & Patterson, Intel optimization manual, Molka et al., Sorin/Hill/Wood primer, Jiménez 2017, Jaleel ISCA 2010, Wu MICRO 2011, Jain ISCA 2016
2. Build citation database (BibTeX entries)
3. For each weakness B1–B10, write a paragraph of justification
4. Compute Bloom filter math (B7)
5. Document the ChampSim DRAM model parameters actually used (B1, C4, C5)

### Phase 2 — Experiments (Tackling the User-Specified Bare Minimum)

**Goal**: Generate enough data to fill the weaknesses in Section A.
**Output**: `phase2_results.csv`, sensitivity plots, sweep curves.
**Estimated effort**: ~4 weeks. This is the bulk of Saga 1.

Sub-phases (run in parallel where server allows):

**2A — Core Baseline Matrix** (~Weeks 3–4)
- Policies: LRU, SRRIP, DRRIP, SHiP, COALESCE. (Add Hawkeye if implementation feasible — high reviewer value but moderate engineering cost.)
- Benchmarks: canneal, fluidanimate, dedup. (+ streamcluster if time)
- Configs: 4-core (50M instr/core), 8-core (100M instr/core)
- Metrics: LLC misses, writebacks, invalidations, IPC per core, total cycles
- **Resolves**: A1, A2, A3

**2B — Scaling Study** (~Week 5)
- Best 2 baselines (SHiP, DRRIP) + COALESCE
- Configs: 4-core, 8-core, **16-core** (this validates the scaling argument in your conclusion)
- Benchmarks: canneal + dedup (the two where COALESCE is expected to win)
- **Resolves**: A4
- **Hardware note**: 16-core ChampSim will be ~4× slower than 4-core per run; budget accordingly

**2C — LLC Size Sensitivity** (~Week 6)
- LLC sizes: 1MB, 2MB (current), 4MB, 8MB
- Configs: 8-core
- Benchmarks: canneal, dedup
- Policies: COALESCE + best baseline
- **Resolves**: A5
- **Expected story**: COALESCE's win grows as LLC shrinks (contention dominates) and shrinks as LLC grows (working set fits)

**2D — Perceptron/Bias Optimization** (~Week 6, partial overlap)
- Perceptron table size: 512, 1024, 2048 (current), 4096 entries
- Modified bias: {0, 25, 50, 75, 100, 150, 200, 250}
- Sharer bias: {0, 25, 50, 75, 100, 150}
- **Resolves**: A6, A7, B2, B3
- **Ablation also here**: PC-only, PC+MESI, PC+sharers, full → resolves A10

**2E — Statistical Rigor** (~Week 7)
- Re-run the main configurations (Phase 2A best results) 3–5 times each
- Vary: PIN trace random seed, set sampling phase, perceptron initialization
- Report: mean ± std dev, geometric mean across benchmarks
- **Resolves**: A8

### Phase 3 — Paper Rewrite

**Goal**: A HiPC-quality paper that proactively addresses every weakness in this document.
**Output**: HiPC submission PDF + CAL 4-page version.
**Estimated effort**: ~2.5 weeks of focused writing.

Structural changes from existing draft:
1. Restructure outline → Abstract, Intro, **Motivation (NEW)**, **Background (NEW)**, COALESCE Design, Implementation, Experimental Methodology, Results, **Discussion (NEW)**, **Threats to Validity (NEW)**, Related Work (EXPANDED), Conclusion
2. Add measured-data motivation (E1) — generate from Phase 2A runs
3. Add perceptron learning curve figure (E5)
4. Honest 4-core framing (E4): acknowledge the trade-off explicitly
5. Expand related work to 20+ refs (E6, D1–D11)
6. Rewrite hardware methodology (C1, C3–C6) — drop K80, specify host
7. MT-Sync tracer validation paragraph (C2)
8. Add Limitations section
9. CAL distillation: take the 8-core bottleneck-core result + Phase 2B scaling + minimal justification → 4 pages

---

## 4. Saga 1 Sprint Plan (May 21 → June 17, 2026) — COMPRESSED

**HiPC deadline: June 17, 2026.** That is **28 days from May 21 (Day 1)**. The original 10-week plan is now a 4-week sprint. CAL is deprioritized within Saga 1 — submitted *after* HiPC (rolling deadline, no rush). All energy goes to HiPC.

Today is Wed May 20, 2026 (planning day). Day 1 is Thu May 21.

### Phase parallelism (this is what makes 4 weeks possible)

The only reason this fits is because Phase 1, Phase 2, and Phase 3 run **in parallel**, not sequentially:
- Phase 1 (citations) is reading/writing work — happens during the day while sims run
- Phase 2 (experiments) runs on the server in the background, ~24/7
- Phase 3 (paper writing) starts in Week 2 and overlaps with Phase 2

### Compressed week-by-week

| Week | Dates | Parallel tracks | Deliverables |
|---|---|---|---|
| **Week 1** | May 21–27 (Thu–Wed) | **P1**: citation map for B1 (DRAM latency), B5 (sampling), B10 (MESI primer), D10 (perceptron lineage). **P2A**: launch 4-core full baseline matrix on server. **P3**: paper outline finalized. | Architectural-values doc v1; 4-core results CSV; paper outline |
| **Week 2** | May 28–Jun 3 (Thu–Wed) | **P1**: finish remaining citations (D1–D11), Bloom filter math, Hennessy & Patterson extraction. **P2A complete**: 8-core baseline matrix done. **P2D**: bias sweep + perceptron table sweep launched. **P3**: Intro, Background, Motivation sections drafted | Citation map complete; 8-core results CSV; bias sweep CSV; paper sections drafted |
| **Week 3** | Jun 4–10 (Thu–Wed) | **P2B**: 16-core scaling. **P2C**: LLC size sensitivity. **P2E**: statistical re-runs (3 seeds per main config — reduced from 5). **P3**: Design, Implementation, Results sections drafted | Scaling plot, LLC sensitivity plot, error bars on main table; paper draft v1 (all sections) |
| **Week 4 (first half)** | Jun 11–14 (Thu–Sun) | **P3**: finalize figures, related work, threats to validity, conclusion. Sir's review begins | Paper draft v2 |
| **Week 4 (second half)** | Jun 15–17 (Mon–Wed) | **P3 polish**: incorporate sir's feedback, final formatting, submission portal | **SUBMIT June 17** |

### What got cut from the 10-week plan (you need to approve these)

| Originally planned | Cut/deferred | Why | Risk |
|---|---|---|---|
| Hawkeye baseline implementation | Defer to Saga 2 | 1–2 weeks of engineering work alone | Reviewer asks "why not Hawkeye?" — answer in Threats to Validity that it's the obvious next baseline |
| Mockingjay baseline implementation | Defer to Saga 2 | Same as Hawkeye | Same |
| Streamcluster + bodytrack | Defer to Saga 2 | Time only allows canneal + fluidanimate + dedup | Acceptable — 3 PARSEC benchmarks is the minimum credible breadth |
| 5 statistical re-runs per config | Reduced to 3 | Time | 3 seeds is the minimum acceptable; mention in Methodology |
| SPEC CPU2017 cross-validation | Already dropped (you confirmed SPEC doesn't work for COALESCE) | N/A | Mention in Limitations |
| CACTI energy/area analysis | Defer to Saga 2 | 1+ week of CACTI parameter tuning | Not standard for HiPC; mandatory for Tier 1 |
| Hand-written paper outline iteration | One outline pass only | Time | Will likely need re-org during Phase 3 — buffer time in Week 3 |

### What CANNOT be cut

These are HiPC-acceptance thresholds — losing any one of these risks rejection:
- ✅ Phase 1 full citation work (cheap and high-impact)
- ✅ 4-core + 8-core baseline matrix with **all** policies (LRU, SRRIP, DRRIP, SHiP, COALESCE)
- ✅ 3 PARSEC benchmarks (canneal, fluidanimate, dedup)
- ✅ 16-core scaling result (one of your strongest selling points)
- ✅ Bias sweep to justify +150/+75
- ✅ ≥3 statistical runs with error bars
- ✅ Honest 4-core framing
- ✅ Drop the K80 GPU mention
- ✅ Expanded related work (≥15 refs)

### Critical schedule dependencies

1. **Server access from Day 1.** If server isn't available May 21, the entire timeline slips. Confirm tonight.
2. **Server parallelism level.** With 8+ parallel jobs, the experiment matrix fits comfortably. With 1–2 jobs, we have to cut more experiments (probably 16-core scaling and LLC sensitivity get reduced).
3. **Sir's review window.** Need to factor in 2–3 days of his review time in Week 4. Send draft no later than Jun 14.
4. **Whether June 17 is abstract or paper deadline.** If abstract-only, full paper ~Jun 24 gives us a critical extra week.

---

## 5. User-Specified Bare-Minimum Experiments (Mapped)

Cross-reference table to make sure nothing in your list is dropped:

| User requirement | Maps to | Phase | Week |
|---|---|---|---|
| 1. Multiple benchmarks (no SPEC — too single-core for COALESCE) | A3 | Phase 2A | 3–4 |
| 2. Scaling 4 / 8 / 16-core graph | A4 | Phase 2B | 5 |
| 3. Vary LLC sizes graph | A5 | Phase 2C | 5–6 |
| 4. Perceptron + bias optimization | A6, A7, B2, B3 | Phase 2D | 6 |
| 5. Statistical rigor | A8 | Phase 2E | 7 |

---

## 6. Hardware Reality Check

### ChampSim is CPU-only

The Tesla K80 GPU is **not used** by ChampSim. ChampSim is a single-threaded C++ simulator. Throughput depends on:
- **Host server CPU clock speed and core count** (affects simulation speed)
- **System RAM** (NOT VRAM) — each ChampSim instance uses 2–4 GB
- **Disk I/O** for trace files (PARSEC traces can be 5–50 GB each)
- **Number of parallel jobs** = number of host CPU cores allocated

### What we need to know about the server (ask sir)

- [ ] Host CPU model and core count
- [ ] Total system RAM
- [ ] Available disk space for traces and outputs
- [ ] Job scheduling system (SLURM, plain bash, screen sessions?)
- [ ] Wall-time limits per job

### Implications for the experiment matrix

**Conservative estimate** (assuming 16 host cores, can run 12 ChampSim instances in parallel):
- Phase 2A: 5 policies × 3 benchmarks × 2 core configs × ~6 hrs each = 180 hrs total, ~15 hrs wall time
- Phase 2B: 3 policies × 2 benchmarks × 3 scaling points × ~8 hrs avg = 144 hrs, ~12 hrs wall
- Phase 2C: 2 policies × 2 benchmarks × 4 LLC sizes × 6 hrs = 96 hrs, ~8 hrs wall
- Phase 2D: ~50 sweep points × 3 hrs = 150 hrs, ~13 hrs wall
- Phase 2E: 5× re-runs of main matrix = 5× Phase 2A = ~75 hrs wall
- **Total wall time ≈ 5 days of continuous server use**, fits in 4 weeks easily

**Pessimistic case** (4 parallel jobs only): ~3 weeks wall time, still fits.

### Drop "Tesla K80 GPU cluster" from the paper

Rewrite the methodology section to specify host CPU + RAM, not GPU. This is weakness C1 and is non-negotiable.

---

## 7. Saga 2 Preview (Aug 2026 → mid-2027)

Once HiPC + CAL are submitted, Saga 1 ends. Saga 2 begins immediately with expansion work. Plan to be detailed in a separate session — high-level outline only here:

### Saga 2 weaknesses to add (beyond Saga 1)

- **CACTI energy + area analysis** for the perceptron tables, ghost buffer, Bloom filter (weakness C7)
- **More benchmarks**: streamcluster, bodytrack, swaptions, ferret, vips, x264 — get to 8–10 PARSEC workloads
- **SPLASH-3 benchmarks** for additional sharing patterns
- **GAP benchmark suite** (BFS, PageRank, CC) for graph workloads with heavy coherence traffic
- **Hawkeye + Mockingjay implementations** as proper baselines
- **Trace-driven vs execution-driven** comparison (gem5 cross-validation if feasible)
- **Multi-level cache integration** (L2 + L3 coherence-aware policy)
- **Power model**: McPAT integration
- **Real-hardware validation**: even crude — e.g., measure DRAM writeback rate on a real Intel machine and compare to simulated

### Saga 2 venue waterfall (strict, no concurrent submission)

1. ASPLOS 2027 Summer (Sept 9, 2026) — first attempt
2. ISCA 2027 (~Nov 2026) — if ASPLOS rejects
3. MICRO 2027 (~Apr 2027) — best cache replacement venue, but MICRO sometimes blocks resubmissions; verify
4. PACT 2027 (~Apr 2027) — Tier 2 safety net
5. IEEE TC / TCAD journal — rolling, final fallback

---

## 8. Career Note (parking this here)

Computer architecture / memory systems / cache work is *highly* employable. Indian R&D hubs hiring directly into this space: Intel Bangalore, AMD Bangalore + Hyderabad, NVIDIA Bangalore + Pune, Qualcomm Bangalore + Hyderabad, ARM Bangalore, Marvell, Texas Instruments. ML-accelerator companies (often remote): Tenstorrent, Groq, Cerebras, SambaNova, Tachyum, Rivos. Cache replacement directly applies to memory hierarchy teams and ML accelerator memory subsystems.

A HiPC paper on the CV at graduation is a real differentiator — it shows ability to do publishable research independently. Master's helps but isn't strictly required if the portfolio (papers + GitHub + Claude Code logs of your simulator + this BTP) is strong. Aim for one publication minimum before graduation; HiPC + CAL together would be excellent.

---

## 9. Day 1 Action Plan — Thursday May 21, 2026

**Three things in parallel:**

### Morning: Server kickoff (~1 hour)
- Confirm server access and host CPU/RAM/parallelism level
- Set up the experiment directory structure on the server
- Verify ChampSim builds and runs a smoke test (one short canneal run with LRU)
- Confirm where traces live and that fluidanimate + dedup traces are accessible (generate them this week if not)

### Afternoon: Phase 1 citation work (Claude session)
Next chat session focuses on architectural justification. Deliverables for end of Day 1:
- BibTeX file with first batch: Jiménez 2017, Jaleel ISCA 2010, Wu MICRO 2011, Sorin/Hill/Wood primer, Hennessy & Patterson 6th ed.
- One-paragraph justification each for: DRAM writeback latency (B1), 6.25% set sampling (B5), perceptron lineage (D10), MESI coding (B8, B10)
- Bloom filter false-positive rate calculation (B7) — show k* = (m/n)·ln 2 derivation

### Evening: Paper outline pass
- Draft the new section structure based on Section E weaknesses
- Identify which figures from current draft survive vs which need regeneration
- Note the "honest 4-core framing" paragraph that needs writing (E4)

### Day 1 success criterion
By end of Thursday: server confirmed running, Phase 2A 4-core baseline matrix launched as background job, first 5 citations in the BibTeX file. If any of these slips, escalate immediately — every day matters.

---

## 10. Open Questions Blocking the Plan

These need answers before Day 1 ends:

1. **Is June 17 the abstract deadline or full paper deadline?** Determines whether we have 28 or 35 days. Verify on hipc.org or with sir.
2. **Server parallelism level.** Determines whether sensitivity studies fit. Ask sir / check with `nproc` and check job scheduler config.
3. **Host server specs** (CPU model, total RAM, disk space). For the paper methodology section.
4. **Are fluidanimate + dedup PIN traces already generated**, or do they need to be made this week? Generation can take ~6–12 hours per benchmark per core count.
5. **Sir's availability for review in Week 4** (Jun 11–16). Confirm he can review within 2 days.

---

## Appendix A — Decision Log

| Date | Decision | Rationale |
|---|---|---|
| May 20, 2026 | Architecture frozen; only parameter sweeps allowed | Positive results justify locking; redesign would blow the schedule |
| May 20, 2026 | SPEC dropped from benchmark list | COALESCE doesn't help single-core workloads (no coherence); PARSEC + SPLASH only |
| May 20, 2026 | Target HiPC main track (full paper), not SRS only | Main track is higher value; SRS as backup |
| May 20, 2026 | Skip HPCA 2027 in favor of ASPLOS 2027 Summer for Saga 2 first | HPCA 2027 deadline conflicts with HiPC; ASPLOS Summer (Sept 9) gives a clean 6-week revision window |
| May 20, 2026 | Drop "Tesla K80 GPU cluster" from paper | ChampSim is CPU-only; the GPU mention is misleading |
| **May 20, 2026** | **HiPC deadline = June 17, 2026. Timeline compressed from 10 weeks to 4 weeks** | **Actual deadline date received from sir** |
| **May 20, 2026** | **CAL submission moved to AFTER HiPC** | **All Saga 1 energy focused on HiPC; CAL is rolling, no rush** |
| **May 20, 2026** | **Hawkeye + Mockingjay baselines deferred to Saga 2** | **Implementation takes 1–2 weeks each, can't fit in 4-week sprint** |
| **May 20, 2026** | **Benchmark set: canneal + fluidanimate + dedup only (streamcluster/bodytrack dropped)** | **3 PARSEC benchmarks is minimum credible breadth in available time** |
| **May 20, 2026** | **Statistical re-runs reduced from 5 to 3 seeds per config** | **Time** |
