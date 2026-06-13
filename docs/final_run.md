# COALESCE — Final Run Plan (HiPC 2026, extended deadline)

> **Today**: 2026-06-14 · **Deadline**: **2026-06-24** (shifted from Jun 17 — 10 days runway)
> **Status**: Paper is COMPLETE and verified (`latex/hip/coalesce_hipc.tex`, 9 pages, compiles clean). This plan covers the strengthening work the extra 10 days enable: complete the results story, then add benchmarks.
> **Authoritative result numbers**: `docs/results_compendium.md`
> **Supersedes**: `hipc_implementation_v2.md`, `hipc_final_implementation.md`, `saga1_plan.md` (all historical — see their banners).

---

## Where we are (committed, on disk)

- **Paper**: full 8-page → 9-page IEEE draft, every section verified, every number log-traceable. One placeholder left: § III-B `[X]` bias-vs-(0,0), pending `cb_0_0`.
- **Policy under test**: full COALESCE (PC + MESI + sharer features, +40/+20×s gated bias). The v2 "simplified-policy pivot" was **REVERTED** — ocean ablation showed the sharer feature carries +7.2–7.3 %, so both feature axes stay.
- **Results landed**: canneal (4/8/16c COALESCE, 4/8c all 8 policies + ablation), ocean (4/8c all 8), fluidanimate (4/8c all 7), barnes (4/8c all 8), 3-seed variance study (canneal 8c, 4 policies, n=3), partial bias sweep (cb_40_0, cb_150_75 done).
- **Headline**: COALESCE wins outright on canneal (+5 % Hawkeye, +30 % Mockingjay at 8c); strongest learning policy on canneal+ocean; geomean +9.7 %/+6.2 % over LRU at 4/8c. Mockingjay last on 3 of 4 workloads. Ablation: sharer feature inert on canneal, +7.2 % on ocean.

## Locked decisions (2026-06-14)

1. **Honest-reporting commitment — APPROVED.** Every benchmark we launch goes in the paper regardless of outcome. We do not fish for wins; we test the characterization's predictions and report all of them. This is what lets us run aggressively without cherry-pick review risk.
2. **dedup — DROPPED** from the benchmark candidate list.
3. **Priority 1** = complete the results story (bias + 16-core) before adding benchmarks.

---

# Part 1 — Complete the story (PRIORITY 1)

## 1a. Bias sweep: finish + upgrade to a sensitivity surface

**Finish (running):** `cb_0_0`, `cb_0_20` close the 5-point sweep `{(0,0),(0,20),(40,0),(150,75),(40,20)}`.
- Note: **`cb_0_0` (0,0) IS the no-bias ablation** — full COALESCE, both perceptron features, zero coherence bias. It directly answers reviewer R7 ("features or bias?"). Fills the § III-B `[X]` placeholder.

**Upgrade (high value — defends the magic numbers, reviewer R4):** expand to a 2D sensitivity grid so (40, 20) is shown sitting on a broad plateau, not a fragile peak. Add ~6 points: (20,10), (20,20), (60,30), (80,40), (40,40), (40,10). Turns one sentence into a sensitivity figure in the style of Mockingjay's penalty sweep. ~8 runs, canneal 8c only, cheap.

## 1b. The 16-core matrix — tiered

Current 16-core data: canneal COALESCE only (348.2 M). To complete scaling:

| Tier | Runs | Buys | Pri |
|---|---|---|---|
| **MUST** | canneal 16c: 7 baselines + no-sharer (8) | Removes the R3 "deferred to extended evaluation" hedge; Fig 2 becomes a real per-policy scaling comparison | 🔴 |
| **SHOULD** | ocean 16c: 8 policies | "Characterization holds at every scale" becomes provable | 🟠 |
| **NICE** | fluid 16c (7) + barnes 16c (8) | Boundary consistency at scale (4c→8c already shows it) | 🟡 |

**Cost**: ~31 runs × ~15–20 h, ~1.5–2 days wall at 17-way parallelism. Biggest server consumer; start ~now, run mostly uninterrupted.

**Dependencies (confirm with server chat):**
- 16-core traces replicated across 16 cores (canneal has it; ocean/fluid/barnes need per-thread traces replicated to 16).
- 16-core binaries for all 8 policies (`config.sh + make` per policy; only COALESCE's exists today).

## 1c. MESI-axis ablation — cheapest high-value run

cb_0_0 gives the no-bias ablation; the only missing feature-ablation is the MESI axis. One module `coalesce_no_mesi` (copy of `coalesce_no_sharer`, strips MESI from h0 instead of sharer from h1), 4 runs (canneal+ocean × 4/8c). Completes the 3-feature ablation matrix: **bias-off (cb_0_0) · sharer-off (have) · MESI-off (new)**.

## Priority-1 server ordering (today)

1. Finish cb_0_0 / cb_0_20 (running)
2. Build 16-core binaries (all policies) + replicate traces
3. Launch **canneal 16c MUST tier** (8 runs) — headline completion
4. Parallel: bias-grid expansion (8) + MESI ablation (4)
5. Then **ocean 16c**, then fluid/barnes 16c as slots free
6. **V1–V6 overlay validation** (`bench/scripts/run_synth_matrix.sh`, <1 h) — the artifact that defends the methodology; run when a slot opens, scp logs back

---

# Part 2 — Benchmark survey (everything, scored)

Win-recipe axes: **I**rregular access · **W**rite-heavy at LLC · **P**ressure (WSS ≫ LLC) · **S**haring depth. Predictions are hypotheses (note: prior predictions for ocean/barnes were wrong — treat as coin flips).

## PARSEC (infra proven)

| App | I | W | P | S | Infra | Prediction |
|---|---|---|---|---|---|---|
| **facesim** | ★★ | ★★★ | ★★★ | ★ | low | win-likely — tetrahedral mesh physics, write-heavy, large WSS |
| **freqmine** | ★★★ | ★★ | ★★ | ★ | low* | win-likely — FP-tree pointer-chasing + writes (*OpenMP tracing differs) |
| **ferret** | ★★ | ★ | ★★ | ★★ | low | toss-up — pipeline image search, read-leaning |
| **bodytrack** | ★★ | ★ | ★ | ★★ | low | likely-lose |
| streamcluster / x264 / vips / swaptions / blackscholes / raytrace | mostly ✗ | | | | low | lose (streaming/compute/read-heavy) |
| ~~dedup~~ | — | — | — | — | — | DROPPED per decision |

## SPLASH-3 (ocean infra exists)

| App | I | W | P | S | Infra | Prediction |
|---|---|---|---|---|---|---|
| **cholesky** | ★★★ | ★★ | ★★ | ★ | medium | win-likely — sparse factorization = irregular + writes |
| **water-nsquared** | ★ | ★★ | ★★ | ★★★ | medium | toss-up on cycles, **activates sharer feature (3rd ablation point)** |
| **radiosity** | ★★★ | ★★ | ★★ | ★★★ | high (build) | win-likely IF it builds — task-steal + scene writes + sharing |
| **fmm** | ★★ | ★ | ★ | ★ | medium | pressure risk (needs large input — barnes lesson) |
| water-spatial | ★ | ★★ | ★★ | ★ | medium | toss-up |
| lu / fft / radix / raytrace / volrend | ✗ | | | | medium | lose (regular/read-heavy) |

## GAP (new tracing infra, ~1–2 day setup)

| App | I | W | P | S | Infra | Prediction |
|---|---|---|---|---|---|---|
| **PageRank (pr)** | ★★★ | ★★★ | ★★★ | ★★★ | high | best fit + highest impact — rank-vector RMW, all-core sharing |
| **bc (betweenness)** | ★★★ | ★★ | ★★ | ★★ | high | win-likely |
| bfs / cc / sssp | ★★★ | ★ | ★★ | ★★ | high | toss-up (read/frontier-leaning) |
| tc | ✗ | ✗ | | | high | lose |

## Recommendation

- **Tier 1 (trace now)**: **facesim** (best canneal-recipe match, proven infra) + **water-nsquared** (dual-purpose: cycle result + the 3rd sharer-ablation point that makes § VI airtight)
- **Tier 2 (high upside, accept infra cost)**: **GAP PageRank** — highest-impact sentence we could add; graph is the hot area; worth the setup given 10 days
- **Tier 3 (backups)**: freqmine (watch OpenMP) or SPLASH cholesky

Worst case (2 of 3 lose): characterization absorbs it; water-nsquared still earns its place via the ablation.

---

## Open decisions to lock

1. **16-core tier**: MUST+SHOULD (canneal+ocean), or all the way to fluid/barnes?
2. **Bias grid expansion**: yes to ~6 extra points for a sensitivity figure?
3. **MESI ablation**: green-light `coalesce_no_mesi` now?
4. **Benchmarks**: confirm facesim + water-nsquared for immediate tracing; PageRank yes/no on infra?
5. **Trace status**: facesim / water / GAP traces on disk, or all from scratch?

## Calendar (Jun 14 → Jun 24)

| Days | Server | Local |
|---|---|---|
| D-10–9 | bias finish/expand; build 16c binaries; trace facesim+water; MESI ablation | cb_0_0 fill; "characterization predicts" framing |
| D-9–7 | canneal/ocean 16c; facesim+water 4/8c; start PageRank infra | ablation rows; seed-study writeup |
| D-7–5 | PageRank matrix if ready; fluid/barnes 16c; V1–V6 | fold new benchmarks into tables/geomeans/figures |
| D-5–3 | stragglers, freeze | full integration, regenerate figures |
| D-3–2 | — | advisor re-review, polish |
| D-2–1 | — | final compile, submit Jun 24 |
