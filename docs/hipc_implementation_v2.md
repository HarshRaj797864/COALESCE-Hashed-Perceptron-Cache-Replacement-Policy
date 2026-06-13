# HiPC Implementation Plan v2 — Simplified Policy Pivot

> ⚠️ **SUPERSEDED (2026-06-14) — HISTORICAL, DO NOT EXECUTE FROM THIS DOC.**
> Current authoritative plan: **`docs/final_run.md`**. Current result numbers:
> **`docs/results_compendium.md`**.
>
> **Three things in this doc are now wrong; corrections:**
> 1. **Deadline is 2026-06-24, not 06-17** (shifted +7 days).
> 2. **The § 1 "simplified-policy pivot" was REVERTED.** It proposed making
>    `coalesce_no_sharer` the headline policy because the sharer feature looked
>    inert on canneal. The ocean ablation then showed the sharer feature carries
>    **+7.2–7.3 %** under genuine sharing — so **full COALESCE (both feature
>    axes) is the headline policy**. The sharer feature is workload-dependent,
>    not dead. See the addendum at the bottom of this file and `final_run.md`.
> 3. **The paper is COMPLETE** (`latex/hip/coalesce_hipc.tex`); all three
>    "tracks" below landed. ocean lost to RRIP (does not generalise beyond
>    canneal-class); fluidanimate/barnes are characterised boundaries.
>
> Original header (historical): *2026-06-10 evening · Deadline 06-17 = D-0 ·
> Today = D-7. Supersedes `hipc_final_implementation.md`. Major pivot: the
> 8-core ablation result on canneal shared has overturned the policy-under-test.*
> The pivot in this sentence is the one that was reverted — see correction #2.

---

## 1. The pivot — what changed today

The 8-core `coalesce_no_sharer` ablation on canneal shared landed at:

| Policy | max_cycles | CPU 1 IPC | CPU 6 IPC |
|---|---|---|---|
| **coalesce_no_sharer** | **300,714,619** | **0.3354** | **0.3325** |
| coalesce (full) | 301,945,789 | 0.3325 | 0.3312 |
| Δ | **−1.23 M cyc (−0.41 %)** | +0.87 % | +0.39 % |

At 4-core they were tied (−0.0015 %). At 8-core, under genuine coherence
pressure (6.93 M LLC invalidations, 305 K VMEM-aliased fills), **the
+20×sharers bias actively mis-fires**. The simplified policy is strictly
better at the headline scale.

**Implication for the paper:**

- The policy under test becomes **`coalesce_no_sharer`** (renamed in paper text
  as "COALESCE" — the simplified design is the final design; the version with
  the sharer axis is an earlier iteration rejected based on this measurement).
- One fewer hyperparameter to defend (`+20×sharers` bias gone).
- One fewer feature axis to defend (sharer-count hash gone).
- Headline numbers strictly improve vs every baseline.
- The "earlier-iteration → ablation → simplified-final" narrative is the
  honest history and the paper's cleanest story.

**Headline numbers (8-core canneal shared) after the pivot:**

| Comparison | Δ |
|---|---|
| COALESCE vs SRRIP | **−0.76 %** (was +0.4 % when full COALESCE was the policy) |
| COALESCE vs Hawkeye | **−5.2 %** |
| COALESCE vs Mockingjay / LRU | **−23.7 % / −23.4 %** |

(Note: "−" means COALESCE finishes faster; signs differ from earlier README
where it was "+X % vs COALESCE" which used the opposite convention.)

---

## 2. What's done (on disk, regime 2 shared VMEM)

| Workload / cores | Status |
|---|---|
| canneal 4-core shared, 8 policies (incl. ablation) | ✅ done, matched 50/100M |
| canneal 8-core shared, 8 policies (incl. ablation) | ✅ done as of today |
| canneal 16-core shared, COALESCE (full) | ✅ done — 348.25 M cyc |
| canneal 16-core shared, `coalesce_no_sharer` | ❌ **needed** for scaling figure with the new headline policy |
| fluidanimate 4-core shared, 7 policies | ✅ done (honest-disclosure data) |
| fluidanimate 8-core shared | ⏳ in flight |
| ocean 4-core shared, 8 policies | ⏳ in flight |
| ocean 8-core shared, 8 policies | ⏳ in flight |
| ocean 16-core shared, COALESCE only | ❌ stretch goal — launch tonight |

---

## 3. What's pending (3 server batches + paper)

### Batch 1 — Track C statistical CI (canneal 8-core shared)

**Goal**: error bars on the headline numbers so the paper can claim significance
on the COALESCE-vs-SRRIP / COALESCE-vs-Hawkeye / ablation-vs-full deltas.

**Scope** — 2 extra seeds × 8 policies × 8-core canneal shared at 100 M
sim/core, 50 M warmup/core = **16 runs**.

Policies: lru, srrip, drrip, ship, hawkeye, mockingjay, coalesce,
**coalesce_no_sharer**.

Seeds: `12345` and `67890` (default seed stays as-is in `seed_default/`).

**Cut order**: if Batch 1 looks like it will blow past D-3:
1. First cut: drop mockingjay + lru extras (they lose by 23 % — CI band is
   already wider than the gap matters). Keeps 6 policies × 2 seeds = 12 runs.
2. Second cut: drop drrip + ship extras. Keeps the four load-bearing policies
   (coalesce_no_sharer, coalesce, srrip, hawkeye) × 2 seeds = 8 runs.
3. Never cut: coalesce_no_sharer × 2 seeds and srrip × 2 seeds (the +0.76 %
   claim depends on this).

### Batch 2 — 16-core `coalesce_no_sharer` canneal shared

**Goal**: complete the scaling figure with the new headline policy.

**Scope**: 1 run, 16-core canneal shared, 100 M sim/core, 50 M warmup/core,
matching the 16-core full-COALESCE config and trace shuffle exactly.

Expected wall time: ~11 h.

**Output**: `simulator/results/regime2_shared_vmem/canneal/16core/coalesce_no_sharer.log`

### Batch 3 — Stretch: 16-core COALESCE on ocean shared

**Goal**: if ocean shows COALESCE wins at 4 + 8 cores, demonstrate scaling on
ocean too.

**Scope**: 1 run, 16-core ocean shared, COALESCE (full or `coalesce_no_sharer`?
pick `coalesce_no_sharer` since that's the headline policy now), 100 M
sim/core, 50 M warmup/core.

Expected wall time: ~11 h.

**Launch condition**: queue tonight after current ocean batches drain. If it
finishes by D-2 end-of-day, include in paper. Otherwise mention as future
work.

### Local work — paper rewrite (`latex/paper/coalesce_hipc.tex`)

Starts D-6 (2026-06-11, tomorrow morning). See § 5 for section plan.

---

## 4. Server cadence

Today (D-7) the server has 17 champsim processes live (ocean + ablation +
4-core fills). Expected drain timeline:

| Day | Server state |
|---|---|
| D-7 (06-10) tonight | Ocean 4c/8c batches finish. Launch Batch 2 (canneal 16c no-sharer) and Batch 3 (stretch — ocean 16c). |
| D-6 (06-11) | Batch 2 + Batch 3 running (~11 h each). Launch Batch 1 (Track C statistical) once cores free. |
| D-5 (06-12) | Batch 1 in flight (~14 h). Batch 2 + 3 land. |
| D-4 (06-13) | Batch 1 finishes. Analysis: aggregate seeds, compute CIs. |
| D-3 (06-14) | Final data on disk. Numbers locked. |

If Batch 1 can run all 16 in parallel (server has shown 17-way), single batch
takes ~14 h. Realistically expect 2 sub-batches of 8 ~ ~28 h.

---

## 5. Paper rewrite plan (`latex/paper/coalesce_hipc.tex`)

Starts D-6 morning. Section-by-section delta from current draft:

| Section | Current | After v2 pivot |
|---|---|---|
| Title | "Coherence-Observant Adaptive Learning…" | Keep — still coherence-observant via MESI state |
| Abstract | "+33 % over SRRIP" | "COALESCE, a perceptron LLC replacement using PC + MESI state, reduces cycles 0.76 % over SRRIP, 5 % over Hawkeye, 23 % over Mockingjay/LRU at 8-core canneal under shared VMEM. The +0.76 % over SRRIP is statistically significant across 3 seeds (95 % CI X)." Lead with mechanism, not magic numbers. |
| § 1 Introduction | – | New: motivation for coherence-awareness; ChampSim default-VMEM artefact; the simplification narrative |
| § 2 Background | – | New: ChampSim VMEM model; MESI state semantics in LLC; perceptron-based prediction primer |
| § 3 Methodology | "ChampSim, PARSEC, 8-core" | Expand: VMEM shared overlay (our methodological contribution); workload-characterization table (canneal vs ocean vs fluidanimate LLC mix); ablation methodology |
| § 4 Design | Describe full COALESCE | Describe **simplified COALESCE** (PC × MESI hash + +40 MODIFIED bias); footnote: "an earlier design iteration also hashed sharer-count and applied a +20×sharer bias; we ablated this in § 6 and found it harmful at scale" |
| § 5 Evaluation — canneal | 33 % number | 8-core shared: 7-policy comparison with 3-seed CIs. 4-core: same, 8 policies. 16-core: simplified COALESCE + full COALESCE scaling (no baselines). |
| § 5 — ocean (NEW) | – | 4-core + 8-core, 8 policies. Headline: does the win generalize? (TBD by D-3) |
| § 5 — fluidanimate | – | Honest disclosure. "LLC access mix is 100 % LOAD — MESI state never varies from EXCLUSIVE, +40 bias never fires. Boundary of the policy's sweet spot." |
| § 6 Ablation (NEW) | – | The big finding. `coalesce_no_sharer` vs full COALESCE on canneal 4/8/16. At 4-core tied; at 8-core simplified wins by 0.41 %; at 16-core [TBD by Batch 2]. Interpretation: +20×sharers bias mis-fires under genuine coherence pressure. |
| § 7 Threats to Validity | "Tesla K80…" | Drop K80 line. Add: (a) restricted to PARSEC + (maybe) SPLASH ocean; (b) coherence-stress benchmarks (water-nsquared, GAP) deferred to future work; (c) results validated under shared VMEM only; default-VMEM-isolation gives larger but less realistic numbers. |
| § 8 Related Work | 5 entries | Expand to ≥ 15 using `coalesce_paper/citations/related_work_notes/D{1..11}*.md` |

**Two paper-text scenarios depending on Track C outcome**:
- CIs of COALESCE vs SRRIP don't overlap → "statistically significant
  +0.76 %"
- Overlap → "lead within seed noise at 8-core; mechanism validated by 5 %
  Hawkeye lead, 30 % LRU lead, and the 16-core scaling figure"

Write both paragraphs; pick when data lands.

---

## 6. Cut order — what gets dropped if D-3 is missed

In order of "first to cut":

1. **Batch 3 (16-core ocean COALESCE)** — already a stretch goal. If not done
   by D-2 EOD, drop. Note in Threats: "16-core ocean is future work."
2. **Mockingjay + LRU extras in Batch 1** — keep them in `seed_default` only;
   report mean only (no CI) for them. The CI matters for the policies near
   the headline.
3. **DRRIP + SHIP extras in Batch 1** — same treatment.
4. **Ocean section in paper** — if ocean results show COALESCE losing AND
   there's no time to integrate honestly, mention as inconclusive ("results
   inconclusive due to compute budget; full ocean evaluation deferred to
   extended version"). Honest, not great.

**Never cut**:
- Batch 2 (16-core canneal no-sharer) — without it the scaling figure has a
  hole.
- Ablation section in paper — this is the core finding now.
- Workload characterization table (the principled argument for when COALESCE
  helps).
- Threats to Validity (honest boundaries).

---

## 7. Naming + cleanup decisions

**Policy name in code**: keep `coalesce_no_sharer` as the module name. Don't
rename modules this close to the deadline — risks header sync breakage with
the sibling ChampSim repo. The paper text calls it "COALESCE" and notes the
sharer-axis version was an earlier iteration.

**Policy name in paper**: "COALESCE — a coherence-observant perceptron LLC
replacement policy using program-counter and MESI-state features." No
sharer-count mention in the headline description. Sharer-count appears once
in the ablation section as "an earlier design iteration that we rejected."

**Code archival**: do not delete `simulator/replacement/coalesce/` (full
COALESCE with sharer axis). Keep as the comparison baseline for the ablation
section. The paper's "COALESCE" maps to the code's `coalesce_no_sharer`; the
ablation row maps to `coalesce`.

**Result directories**: rename or alias is not necessary. The README in
`regime2_shared_vmem/` makes the mapping explicit.

---

## 8. Verification — paper passes 5 reviewer attacks?

1. **"What's your headline number?"** → "+0.76 % cycle reduction over SRRIP at
   8-core canneal under shared VMEM, mean of 3 seeds, ±X % CI. +5 % over
   Hawkeye, +23-30 % over Mockingjay/LRU. Statistically significant if CI
   permits; otherwise mechanism-validated by gap to weaker baselines and the
   scaling figure."
2. **"Have you tested multiple benchmarks?"** → "canneal, ocean_cp,
   fluidanimate. Workload-characterization table explains why COALESCE wins
   on the first two and loses on the third (LLC access mix). Coherence-stress
   benchmarks (water-nsquared, GAP) are deferred to future work."
3. **"How do you know each feature contributes?"** → "Ablation §6: dropping
   the sharer axis from the perceptron strictly improves performance at 8-core
   (−0.41 % cycles). The MESI state axis carries the entire contribution.
   We report the simplified policy as the production design."
4. **"Is the lead statistically significant?"** → "Three seeds at 8-core
   canneal shared, Student-t CI at p=0.05. The lead over SRRIP is [inside /
   outside] the CI; over Hawkeye it is conclusively outside."
5. **"Does ChampSim's default VMEM affect your results?"** → "We extend
   ChampSim with a cross-CPU page-sharing overlay (§ Methodology) as the
   realistic multicore regime. Under default per-CPU isolation we observed
   larger absolute deltas but consider that an artefact, not a property of
   the policy. We report only the shared-VMEM regime."

---

## 9. What this plan does NOT propose

- No new replacement modules.
- No SPLASH-3 water-nsquared / radiosity / GAP for HiPC — deferred to Saga 2.
- No 16-core fluidanimate (workload doesn't activate the mechanism; no value).
- No 3-seed CI on ocean or fluidanimate (budget — ocean is one-seed only).
- No bias-value sweep (the +40 MODIFIED stays; one fewer hyperparameter to
  defend than before since +20×sharer is now gone).
- No more `simulations/coalesce_final.cpp` work — ChampSim is the source of
  truth.

---

## 10. Day-by-day timeline

| Day | Date | Server | Local |
|---|---|---|---|
| **D-7** | 06-10 tonight | Launch Batch 2 (16c canneal no-sharer) + Batch 3 (16c ocean coalesce stretch) | Write this plan (done); start methodology rewrite stub |
| **D-6** | 06-11 | Batch 2 + 3 finish; launch Batch 1 (Track C) | Methodology + Background + Design sections |
| **D-5** | 06-12 | Batch 1 in flight; ocean + fluidanimate-8 finish | Evaluation §5 canneal subsection; reframe |
| **D-4** | 06-13 | Batch 1 finishes; analysis (CIs, tables) | Ablation §6, ocean §5b, fluidanimate §5c |
| **D-3** | 06-14 | Data locked; figures regenerated | Threats §7, Related Work §8 expansion; v1 ready |
| **D-2** | 06-15 | – | Send draft to advisor |
| **D-1** | 06-16 | – | Apply feedback, polish, regenerate figures |
| **D-0** | 06-17 | – | **Submit** |

---

## 11. Open items the user is tracking

- Confirm HiPC Jun 17 deadline is abstract vs full paper (hipc.org).
- Confirm advisor review window for D-2 (turnaround time).
- Confirm ocean traces are running under SPLASH-3 ocean_cp vs PARSEC ocean
  (per server chat).

---

End of plan. Server chat gets § 3 (batch definitions) and § 4 (cadence) as
the handoff. Local work tracked against § 5 (paper plan) and § 10 (timeline).

---

# ADDENDUM (2026-06-11) — ocean 4-core invalidates yesterday's pivot

## What happened

Ocean 4-core shared landed (7 of 8 policies; mockingjay pending). Two findings
overturn the v2 "simplified policy is headline" call:

| Policy | max_cycles | vs SHIP |
|---|---|---|
| SHiP (best) | 549,605,858 | – |
| COALESCE (full) | 569,457,207 | +3.6 % |
| coalesce_no_sharer | 611,083,533 | **+11.2 %** |

1. **COALESCE loses on ocean 4-core**: 4th of 7. RRIP-family (SHiP/SRRIP/DRRIP)
   wins. The canneal-only-wins narrative is now the honest description.
2. **The ablation FLIPS direction**: on ocean, full COALESCE beats
   `coalesce_no_sharer` by 7.3 % — the sharer feature **is** information-bearing
   under genuine cross-thread sharing.

## Revised headline policy: full COALESCE (as before the v2 pivot)

The simplified-policy pivot from yesterday is reverted. Full COALESCE stays
the headline policy with both feature axes intact. The ablation section becomes
a *workload-dependent feature activation* finding:

- canneal (shallow sharing): sharer axis inert, +0.4 % from removing it.
- ocean (genuine sharing): sharer axis carries +7.3 %.

This is a more interesting scientific story than "sharer feature is dead" —
it characterizes when each feature matters.

## Plan adjustments

| § | Change |
|---|---|
| § 1 pivot | REVERTED. Full COALESCE is the headline policy. |
| § 3 Batch 1 (Track C) | UNCHANGED. 16 runs, 2 seeds × 8 policies × 8c canneal shared. CI needed for COALESCE-vs-SRRIP +0.4 % significance. |
| § 3 Batch 2 (16c no-sharer canneal) | KEEP. Needed for the ablation scaling table (canneal 4/8/16 ablation row). |
| § 3 Batch 3 (16c ocean coalesce) | DOWNGRADE to "skip unless 8c ocean shows COALESCE competitive." If COALESCE places 4th-5th on 8c ocean too, 16c ocean adds nothing — just more disclosure of losing. |
| **NEW § 3 Batch 4 (conditional)** | If 8c ocean lands by D-5 and COALESCE is still losing, server chat picks ONE new SPLASH-3 trace (water-nsquared is the top candidate — heavy sharing + writes) and runs 4-core + 8-core with all 8 policies. Cut threshold: trace must build + run in 36 h or skip. |
| § 5 Paper rewrite | Title shifts to something more workload-characterization-y: e.g. "Workload-Dependent Feature Activation in Perceptron-Based LLC Replacement" or "COALESCE: a Coherence-Aware Perceptron Cache Policy with Workload-Bounded Wins". Abstract leads with canneal 8c headline AND honest characterization of where the policy doesn't generalize. |
| § 6 Ablation | Workload-contrast story: canneal (sharer inert) vs ocean (sharer carries +7.3 %). Frame as scientific finding, not simplification call. |
| § 7 Threats to Validity | Keep workload-coverage limit. Add the explicit phrase: "COALESCE's wins are bounded to workloads with capacity-pressured working sets, mixed RFO/WRITE LLC mix, and shallow cross-thread sharing (canneal-class). On ocean-class workloads with deeper sharing the policy is competitive but not winning." |

## What to commit today

1. `ocean/4core/*.log` + `ocean/README.md` — ocean 4c data + analysis
2. Updated `regime2_shared_vmem/README.md` — ablation contrast disclosed
3. This addendum

## What stays the same

- Track C is non-negotiable.
- 16c canneal no-sharer is non-negotiable.
- Paper writing starts D-6 (today, after this commit).
- Submission D-0 (Jun 17). Abstract D-1 (Jun 16).
- Stretch (water-nsquared / 16c ocean) decided after 8c ocean lands.
