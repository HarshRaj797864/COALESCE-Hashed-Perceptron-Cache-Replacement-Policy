# HiPC Final Implementation Plan — Three parallel tracks + paper rewrite

> ⚠️ **SUPERSEDED (2026-06-14) — HISTORICAL.** This was the Jun-10 three-track
> plan; both it and its successor `hipc_implementation_v2.md` are now historical.
> Current authoritative plan: **`docs/final_run.md`**. Current numbers:
> **`docs/results_compendium.md`**.
>
> **What actually happened (vs the plan below):**
> - **Track A (ablation)**: done. Sharer feature inert on canneal (−0.41 % at
>   8c), but **+7.2–7.3 % on ocean** — workload-dependent, kept in the policy.
> - **Track B (ocean)**: done. COALESCE **loses** to the RRIP family on ocean
>   (regular access favours RRIP); it is the strongest *learning* policy there.
>   Added fluidanimate (read-only, inert) and barnes (low LLC pressure) as
>   characterised boundaries.
> - **Track C (variance)**: done. 3-seed study, bands non-overlapping, ranking
>   stable; the 0.4 % canneal-8c gap is within COALESCE's own 2.8 % seed band
>   (treated as a tie).
> - **Deadline shifted to 2026-06-24.** Paper is complete; the extension is for
>   16-core completion + new benchmarks per `final_run.md`.
>
> Original header (historical): *Today 2026-06-10 (D-7) · Deadline 06-17 abstract
> · Meeting 06-15 advisor.*

---

## Why we are doing this (context)

After the 8-core × 7-policy shared-VMEM matrix landed for both canneal and fluidanimate, the picture forced a strategy revision:

1. **The two-regime framing is dropped.** The +33 % canneal-8-core win we had under default ChampSim VMEM (formerly "regime 1") was driven by per-CPU address-space isolation — an artefact of the simulator's default, not a property of a policy operating under realistic multicore sharing. Under shared VMEM (closer to real coherent multicore) the COALESCE-vs-SRRIP lead collapses from +33 % to +0.4 %. Continuing to publish two regimes invites two reviewer attacks at once. The original COALESCE design intent was always to operate where sharing actually happens, i.e. **shared VMEM is the canonical setup throughout the paper**.

2. **fluidanimate is structurally outside the policy's sweet spot.** Verified directly from `regime2_shared_vmem/fluidanimate/8core/coalesce.log`: LLC access mix is 100 % LOAD (0 RFO, 0 WRITE, no TRANSLATION). Every fill enters as EXCLUSIVE; nothing ever transitions to MODIFIED; the +40 MODIFIED bias never fires. The +5 % loss vs DRRIP is structural, not a bug. We keep fluidanimate as honest disclosure but need a second canneal-class workload that actually has writes.

3. **Three open questions we have not yet answered:**
   - Does the **MESI-half** of COALESCE deliver value under shared VMEM, or is it dead weight once sharing is exposed? → **Track A** ablation.
   - Does the canneal win generalise to another write-mixed memory-bound benchmark? → **Track B** SPLASH-3 ocean.
   - Is the +0.4 % lead over SRRIP statistically real, or within seed noise? → **Track C** statistical re-runs.

This plan answers all three in parallel, then rewrites the paper around a single shared-VMEM narrative.

---

## What's on disk right now (do NOT redo)

```
simulator/results/
├── regime1_private_vmem/                  ← KEEP as on-disk archive; do NOT cite in paper
│   └── canneal/{4core_50M_v0, 8core_100M_v0, 8core_100M_v2, 16core_100M_v2}
└── regime2_shared_vmem/                   ← canonical paper setup
    ├── canneal/
    │   ├── 4core/   (7 policies, ⚠️ length mismatch: COALESCE 100M, baselines 50M)
    │   ├── 8core/   (7 policies, matched 100M)         ← F5 ablation source
    │   └── 16core/  (coalesce_in_progress.log only)    ← waiting on server
    └── fluidanimate/
        ├── 4core/   (7 policies, matched 50M)
        └── 8core/   (7 policies, matched 100M)
```

Pre-built infrastructure committed to git:
- `simulator/inc/vmem.h` — `set_shared_cpus()` mechanism (use `vmem_shared_cpus: [0..N-1]` in JSON to enable).
- `simulator/replacement/{hawkeye,mockingjay,coalesce,...}` — 7 policy modules already work.
- `bench/scripts/parse_overlay_results.py` — extracts max_cycles, bottleneck IPC, smoking-gun counters.
- `coalesce_paper/citations/` — 18-entry references.bib + per-parameter justifications + 11 per-paper related-work notes.

---

## Track A — Drop the sharer feature (ablation)

**Question**: does the MESI half of COALESCE deliver value, or is the +20×sharer bias dead weight that's noisily neutral?

**Approach**: build a new replacement module `coalesce_no_sharer/` — same as COALESCE V2 minus the sharer axis.

### What changes vs `coalesce/coalesce.{h,cc}`

| Keep | Drop |
|---|---|
| PC perceptron (2 × 2048 × 8-bit tables) | Sharer-count input to `hash1` |
| MESI state in `hash0` (`h ^= (state << 8)`) | Sharer-count parameter from `predict_raw` / `train` signatures |
| +40 MODIFIED bias (gated on `raw_vote > 0`) | `+20 × sharer_count` bias block (`coalesce.cc:117-119`) |
| Bloom filter ghost buffer + 5× rescue boost | – |
| Set sampling (`SAMPLING_MODULO = 32`) | – |
| THRESHOLD = 35, BLOOM_RESET_THRESHOLD = 150 | – |
| Ghost entry encoding (sharer bits stored but unused) | – |

`hash1` becomes a second PC-only orthogonal hash with a different mixing constant — the classic Jiménez 2017 multiperspective trick: `((PC ^ 0x85ebca6b) ^ (PC >> 13)) % 2048`. Keeps the dual-table aliasing-suppression benefit; eliminates the constant-input degeneracy.

### Files to create

```
simulator/replacement/coalesce_no_sharer/
├── coalesce_no_sharer.h
└── coalesce_no_sharer.cc
```

Module name registered as `"coalesce_no_sharer"` in the LLC `replacement` JSON field. ~200 LOC; copy of `coalesce/coalesce.cc` with the changes listed above.

### Server build + run

```bash
cd ~/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy/simulator

# config copy
python3 -c "
import json
c = json.load(open('btp_8core_coalesce_shared_v2.json'))
c['executable_name']    = 'champsim_8core_no_sharer_shared_v2'
c['LLC']['replacement'] = 'coalesce_no_sharer'
open('btp_8core_no_sharer_shared_v2.json','w').write(json.dumps(c, indent=2))
"

./config.sh btp_8core_no_sharer_shared_v2.json
make

# canneal-8core shared
TRACES_CAN8="traces/canneal_big0.champsimtrace traces/canneal_big1.champsimtrace \
traces/canneal_big2.champsimtrace traces/canneal_big3.champsimtrace \
traces/canneal_big4.champsimtrace traces/canneal_big0.champsimtrace \
traces/canneal_big1.champsimtrace traces/canneal_big2.champsimtrace"

nice -n 19 bin/champsim_8core_no_sharer_shared_v2 \
  --warmup-instructions  50000000 \
  --simulation-instructions 100000000 \
  $TRACES_CAN8 \
  > results/regime2_shared_vmem/canneal/8core/coalesce_no_sharer.log 2>&1
```

Repeat for ocean traces once Track B has produced them. **1 run on each workload** (no seed sweep here — Track C handles seeds for the full-COALESCE only).

### Outcomes and what each means

| Result | Interpretation | Paper action |
|---|---|---|
| `no-sharer ≈ full` (within 1 %) | Sharer half was empirically dead | Defend the simpler module; mention this is a tightening for Saga 2 |
| `no-sharer > full` | Sharer bias was hurting (noise mis-firing) | Drop sharer from production COALESCE; rename if needed |
| `no-sharer < full` | Sharer half contributes despite empirically-rare firing | Keep the full policy; this is what the paper currently claims |

---

## Track B — Add SPLASH-3 ocean (generalisation)

**Question**: does the canneal win generalise to another write-mixed memory-bound benchmark?

**Choice**: SPLASH-3 ocean_cp (continuous-partitions variant). Multi-grid PDE solver. Known write-heavy multicore workload. Used in cache-replacement literature (SHiP, Hawkeye, Mockingjay all report ocean numbers).

### Server setup

1. **Get SPLASH-3 source**. Likely URL: `https://github.com/SakaleshKolur/Splash-3` (verify; if blocked, push a tarball from local). Land it at `~/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy/simulator/tracer/splash-3/`.

2. **Build ocean_cp** with `gcc -pthread`. Apps directory is typically `Splash-3/codes/apps/ocean/contiguous_partitions`. Standard build sequence:
   ```bash
   cd ~/.../simulator/tracer/splash-3/codes/apps/ocean/contiguous_partitions
   make
   # verify ./OCEAN (or similar) runs natively
   ./OCEAN -n258 -p4 -e1e-7 -r20000 -t28800
   ```
   Input parameters: `-n258` (grid size), `-p4` (threads — match to core count), `-e1e-7` (error tolerance), `-r/-t` (relaxation / timestep). Use the SPLASH-3 default "large" input if listed in the suite docs; otherwise the values above give a working medium input.

3. **Trace with PIN MT-Sync** at 4-thread and 8-thread:
   ```bash
   for nt in 4 8; do
     $PIN_ROOT/pin -t simulator/tracer/pin/obj-intel64/champsim_tracer.so \
       -o simulator/traces/ocean_cp_${nt}t \
       -- ~/.../OCEAN -n258 -p${nt} -e1e-7 -r20000 -t28800
   done
   ```
   Produces `simulator/traces/ocean_cp_{4,8}t{0..N-1}.champsimtrace`. Expect ~hours per trace generation.

4. **Verify access mix matches canneal-class** (NOT fluidanimate-class). On any ocean log after a short smoke run, check `cpu0->LLC RFO` and `cpu0->LLC WRITE` are both non-zero. If both are 0, ocean is read-only at LLC and won't help — pivot to bodytrack (PARSEC, source at `simulator/tracer/pin/parsec-3.0`).

### Run matrix

8 runs at 8-core ocean shared, matched 100 M sim/core:
- 7 baselines: LRU, SRRIP, DRRIP, SHIP, Hawkeye, Mockingjay, COALESCE
- 1 ablation: coalesce_no_sharer (Track A overlap)

```bash
mkdir -p results/regime2_shared_vmem/ocean/8core

TRACES_OCEAN8="traces/ocean_cp_8t0.champsimtrace traces/ocean_cp_8t1.champsimtrace \
traces/ocean_cp_8t2.champsimtrace traces/ocean_cp_8t3.champsimtrace \
traces/ocean_cp_8t4.champsimtrace traces/ocean_cp_8t5.champsimtrace \
traces/ocean_cp_8t6.champsimtrace traces/ocean_cp_8t7.champsimtrace"

for pol in lru srrip drrip ship hawkeye mockingjay coalesce coalesce_no_sharer; do
  # one-time: derive config + build per policy
  python3 -c "
import json
c = json.load(open('btp_8core_coalesce_shared_v2.json'))
c['executable_name']    = 'champsim_8core_${pol}_shared_v2'
c['LLC']['replacement'] = '${pol}'
open('btp_8core_${pol}_shared_v2.json','w').write(json.dumps(c, indent=2))
"
  ./config.sh btp_8core_${pol}_shared_v2.json
  make 2>&1 | tail -1

  nice -n 19 bin/champsim_8core_${pol}_shared_v2 \
    --warmup-instructions  50000000 \
    --simulation-instructions 100000000 \
    $TRACES_OCEAN8 \
    > results/regime2_shared_vmem/ocean/8core/${pol}.log 2>&1 &

  while [ $(jobs -r | wc -l) -ge 2 ]; do sleep 60; done
done
wait
```

Verification per run: 8 `Simulation complete CPU` lines, `VMEM ALIASED FILLS > 0`, CPU 0 hit 100 M instr.

### Cut order

- If SPLASH-3 doesn't build cleanly by EOD D-6, abandon ocean. Paper falls back to canneal + fluidanimate + ablation. Mention ocean as future work.
- If ocean's LLC access mix is read-only (RFO=0, WRITE=0 like fluidanimate), pivot to bodytrack instead — same 8 runs, swap the trace list.

---

## Track C — Statistical re-runs on canneal-8-core shared

**Question**: is the +0.4 % COALESCE-vs-SRRIP lead at 8-core canneal shared statistically significant?

**Approach**: 2 additional seeds × 7 policies × canneal-8-core shared = 14 runs.

The existing run is seed 1 (default). Run seeds 12345 and 67890 via the `vmem.randomization` JSON field already plumbed at `parse.py:343`:

```bash
mkdir -p results/regime2_shared_vmem/canneal/8core_seeds

for seed in 12345 67890; do
  for pol in lru srrip drrip ship hawkeye mockingjay coalesce; do

    # generate a per-(policy, seed) config
    python3 -c "
import json
c = json.load(open('btp_8core_${pol}_shared_v2.json'))
c['virtual_memory']['randomization'] = ${seed}
c['executable_name'] = 'champsim_8core_${pol}_shared_v2_seed${seed}'
open('btp_8core_${pol}_shared_v2_seed${seed}.json','w').write(json.dumps(c, indent=2))
"
    ./config.sh btp_8core_${pol}_shared_v2_seed${seed}.json
    make 2>&1 | tail -1

    nice -n 19 bin/champsim_8core_${pol}_shared_v2_seed${seed} \
      --warmup-instructions  50000000 \
      --simulation-instructions 100000000 \
      $TRACES_CAN8 \
      > results/regime2_shared_vmem/canneal/8core_seeds/${pol}_seed${seed}.log 2>&1 &

    while [ $(jobs -r | wc -l) -ge 2 ]; do sleep 60; done
  done
done
wait
```

### Aggregation

For each policy compute mean ± std-dev over 3 seeds (seed 1 = the existing `regime2_shared_vmem/canneal/8core/<policy>.log`; seeds 2 + 3 from above):

```bash
python3 bench/scripts/parse_overlay_results.py \
  results/regime2_shared_vmem/canneal/8core/ \
  results/regime2_shared_vmem/canneal/8core_seeds/ \
  --csv results/regime2_shared_vmem/canneal/8core_3seed_summary.csv
```

(Extend parser to group by policy and emit mean / std / CI.)

### Cut order

- If 3-seed budget overflows, reduce to **1 extra seed** (7 runs). Report mean ± half-range instead of 95 % CI. Disclose.

---

## Paper rewrite — single-setup framing

Edit `latex/paper/coalesce_hipc.tex` per the section table below. Aim for advisor draft by EOD D-3.

| Section | Current state | Target |
|---|---|---|
| Title | "Coherence-Observant Adaptive Learning for System-wide Cache Efficiency" | Keep — MESI state IS a coherence-protocol signal even with sharer-bias dropped |
| Abstract | "33 % over SRRIP at 8-core canneal" | Reframe: lead with shared-VMEM canneal headline; mention ablation-isolated MESI contribution; one sentence on ocean generalisation |
| Methodology | "ChampSim, PARSEC, 8-core" | Add subsection "VMEM cross-core page sharing extension" — describe `set_shared_cpus` mechanism + cite `[champsim]` for the unmodified base |
| Evaluation §1 (NEW) | – | **Workload characterisation table**: LLC TOTAL / LOAD-miss-rate / RFO / WRITE / TRANSLATION / AVG MISS LATENCY for canneal, ocean, fluidanimate (CPU 0 row each). First-principles argument: COALESCE helps where RFO+WRITE fraction > N % at LLC. |
| Evaluation §2 — canneal | The 33 % number | Replace with shared-VMEM canneal: 4-core (length-normalised), 8-core (mean ± CI from Track C), 16-core (when complete). 7-policy table. |
| Evaluation §3 — ocean (NEW) | – | 7-policy + no-sharer ablation. Headline: does the win generalise? |
| Evaluation §4 — fluidanimate (NEW) | – | Honest disclosure. Reference Table 1 for the structural cause. |
| Evaluation §5 — ablation (NEW) | – | `coalesce_no_sharer` vs full COALESCE on canneal + ocean. Which COALESCE component is doing the work? |
| Threats to Validity | "Tesla K80 GPU, etc." | Wipe the prior errata. Explicit boundary: COALESCE helps on multicore memory-bound workloads with non-trivial write fraction at LLC. |
| Related Work | 5 entries | Expand to ≥ 15 using `coalesce_paper/citations/related_work_notes/D{1..11}*.md` |

Default-ChampSim-VMEM results (the old "regime 1") are mentioned in **one sentence** in Methodology as a footnote: *"Under default per-CPU isolation we observe similar relative rankings with larger absolute gaps; we report the shared-VMEM results throughout as the more realistic regime."*

---

## Documentation cleanup (in parallel with paper)

| File | Change |
|---|---|
| `docs/coherence_aware.md` | Drop two-regime narrative from § 1, 2, 7, 9. Add workload-characterisation argument. Update § 8 Saga 1 timeline. |
| `docs/saga1_plan.md` | Mark Phase 2V (synth bench V1..V6) as superseded — canneal vs ocean is the validation. Replace two-regime matrix with shared-VMEM-only matrix. |
| `docs/OPEN_DECISIONS.md` | Close #17 with the decision: "regime split dropped; shared VMEM canonical; default-VMEM = one-sentence Methodology footnote." |
| `simulator/results/regime2_shared_vmem/README.md` | Optionally rename dir to `shared_vmem/` (drop "regime2" prefix). Add LLC access-mix table for canneal / ocean / fluidanimate. |
| `simulator/results/regime1_private_vmem/README.md` | One-paragraph note: "Default-ChampSim-VMEM runs, kept as on-disk archive; not used in paper." |

---

## Day-by-day timeline (today D-7 = 2026-06-10)

| Day | Date | Track A | Track B | Track C | Paper |
|---|---|---|---|---|---|
| D-7 | 06-10 | Write `coalesce_no_sharer/{h,cc}` + commit | Pull SPLASH-3 onto server; verify build | – | Start Methodology rewrite |
| D-6 | 06-11 | Build + smoke on server | Build ocean_cp; PIN trace 4-thread + 8-thread | – | Workload-characterisation §1 |
| D-5 | 06-12 | Run canneal-shared (1 run) | Verify trace access mix is canneal-class | Kick off 14 stat re-runs | Reframe canneal §2 around shared-VMEM |
| D-4 | 06-13 | – | Launch ocean 8-core matrix (8 runs) | Stat re-runs land | Ocean §3, fluidanimate §4 |
| D-3 | 06-14 | – | Aggregate; CSVs + figures | 3-seed CI computed | Ablation §5, Threats §6 |
| D-2 | 06-15 | – | – | – | **Advisor meeting**; apply feedback |
| D-1 | 06-16 | – | – | – | Polish + post |
| D-0 | 06-17 | – | – | – | **Submit** |

### Cut order (lowest priority first)

1. SPLASH-3 doesn't build cleanly by EOD D-6 → drop ocean entirely; paper is canneal + fluidanimate + ablation.
2. Track C blows budget → reduce to 1 extra seed (mean ± half-range).
3. Ablation shows no-sharer ≈ full within noise → mention briefly; don't make a big deal; defer the "drop sharer" decision to Saga 2.
4. Ocean shows COALESCE losing → still publish (honesty); reframe as "we test against ocean and fluidanimate to characterise the boundary."

**NEVER cut**: workload-characterisation table, Related Work expansion, Threats to Validity, the advisor review window.

---

## Five reviewer rebuttals the rewrite must support

The paper succeeds when each rebuttal cites only on-disk data:

1. **"What's your headline number?"** → "30 % cycle reduction vs LRU at 8-core canneal under shared VMEM, ±X % CI from 3 seeds." (Track C output)
2. **"Have you tested multiple benchmarks?"** → "canneal, ocean_cp, fluidanimate. Workload characterisation in Table 1 explains why COALESCE wins on the first two and loses on the third." (Track B output + workload table)
3. **"How do you know the sharer feature contributes?"** → "Ablation: `coalesce_no_sharer` (table X) shows that dropping the sharer axis [improves / matches / hurts] performance; the MESI axis carries [most / all / none] of the contribution." (Track A output)
4. **"Is the lead statistically significant?"** → "Three seeds, std-dev < 2 % of mean, 95 % CI bands in Figure X. The lead over SRRIP/Hawkeye is [inside / outside] the confidence band." (Track C output)
5. **"Does ChampSim's default VMEM affect your results?"** → "We extend ChampSim to model cross-core sharing (§ Methodology); under default per-CPU isolation we observe similar rankings with larger absolute gaps. We report shared-VMEM as the realistic regime." (one-sentence footnote)

If any rebuttal requires hand-waving past missing data, the corresponding track is incomplete and the cut order in § Day-by-day kicks in.

---

## What this plan does NOT propose

- No changes to the existing `coalesce/` module (V2 stays as the comparison baseline).
- No more synth-bench V1..V6 runs (the canneal + ocean comparison validates VMEM overlay end-to-end).
- No PARSEC dedup work (ocean picked instead).
- No bias sweep (B_M = 40 stays; Saga 2 territory).
- No 16-core ocean / fluidanimate (calendar).
- No further VMEM modification.

---

## Companion docs (read when stuck)

- `docs/coherence_aware.md` § 1-4 — what the policy actually does, how the VMEM overlay was designed.
- `docs/saga1_plan.md` § 4-8 — server-side execution patterns (configs, run templates, verification grep recipes); apply the same patterns to ocean.
- `coalesce_paper/citations/references.bib` + `related_work_notes/D{1..11}*.md` — drop-in source material for Related Work expansion.
- `simulator/results/regime2_shared_vmem/README.md` — current headline numbers for each workload/core-count.

---

## One-paragraph reality check

We have 7 days. Three small parallel tracks (ablation, ocean generalisation, statistical re-runs) plus a paper rewrite is feasible if the SPLASH-3 build doesn't fight us. The ablation is the highest-leverage piece because it isolates which COALESCE component is doing the work — and answers it cleanly with one new module + 1-2 server runs. Ocean is the bigger gamble: if it builds and shows canneal-class access mix, the paper has a 2-workload positive generalisation story; if it doesn't, we ship with canneal + fluidanimate + ablation and frame around workload characterisation. Track C is cheap and high-defensibility — confirms the +0.4 % lead is real or admits it's within noise. The paper rewrite is non-negotiable and starts today regardless of how the tracks progress. By D-2 advisor draft, by D-1 polish, by D-0 submit.
