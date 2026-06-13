# Saga 1 — Server Execution Plan (HiPC 2026)

> ⚠️ **SUPERSEDED (2026-06-14) — HISTORICAL, EARLIEST OF THE PLAN DOCS.**
> Lineage: `saga1_plan.md` (Jun 5) → `hipc_final_implementation.md` (Jun 10) →
> `hipc_implementation_v2.md` (Jun 10 eve) → **`docs/final_run.md`** (Jun 14,
> current). Current numbers: **`docs/results_compendium.md`**.
>
> **Two key things in this doc are stale/contradicted by later evidence:**
> 1. **§ 1.1 says the sharer feature is "inert" and `sharer-count bin[1]=100 %`,
>    `INVALIDATIONS=0`.** That was true only under *default ChampSim VMEM*
>    (per-CPU isolation). Under the **shared-VMEM overlay** (now canonical),
>    sharing is real: canneal 8c has 6.9 M invalidations, bin[2+]=25.6 %, and
>    the sharer feature contributes **+7.2 % on ocean**. The "inert" finding is
>    a property of the old simulator default, not the policy.
> 2. **Deadline is 2026-06-24** (was 06-17). **dedup is dropped.** The paper is
>    complete; remaining work is 16-core completion + new benchmarks
>    (`final_run.md`).
>
> The shared-VMEM overlay this doc set up IS the canonical paper setup, and its
> day-by-day server recipes (PIN tracing, config templates) remain accurate
> reference. Read it for *how to run things*, not *what to run* — for the latter,
> use `final_run.md`.
>
> Original header (historical): *drafted 2026-06-05. Purpose: day-by-day handoff
> for iiitsgpu up to the HiPC abstract deadline 2026-06-17.*
>
> Read this top-to-bottom once. The sections after § 3 are self-contained execution recipes; jump straight to them when you start each phase. Read companion docs only when this file points at them: `docs/coherence_aware.md` (mechanism + Saga-2 roadmap), `docs/OPEN_DECISIONS.md` (issue log, item #17), `docs/PUBLICATION_STRATEGY.md` § 2 (weakness inventory; this plan supersedes its § 4 sprint matrix).

---

## 1. Status snapshot (what's already done)

### 1.1 Empirical findings that lock the architecture

| Finding | Source | Implication |
|---|---|---|
| Sharer-count `bin[1] = 100.000 %` over 19.9 M evictions | 8-core canneal V2 sharer histogram | Sharer feature inert under default ChampSim VMEM `[champsim]` |
| `LLC COHERENCE INVALIDATIONS = 0` across all 5 policies at 4/8/16-core | All `simulator/results/*` logs grepped | Confirms sharer-count = 1 universally |
| MESI fills ≈ 85 % MODIFIED, ≈ 15 % EXCLUSIVE on 16-core canneal CPU 0 | LLC LOAD/RFO/WRITE miss counts | MESI half of the policy is genuinely load-bearing |
| 16-core data show clean policy discrimination (COALESCE 921.7 M cycles vs RRIP family 1347 M) | `simulator/results/phase2b_16core_canneal_V2/logs/` | The other chat's "trace truncation" claim was a misread |

### 1.2 Existing results matrix (Regime 1 = private VMEM)

| Workload | 4-core | 8-core | 16-core |
|---|---|---|---|
| canneal | ☑ all 5 policies (V0+V2) | ☑ all 5 policies (V2) | ☑ all 5 policies (V2) |
| fluidanimate | 🆕 | 🆕 | – (skip, see § 12 cut order) |
| dedup | 🆕 | 🆕 | – (skip) |

Headline number from canneal-8core V2: COALESCE 415.2 M cycles vs SRRIP 619.4 M → **33 % cycle reduction**. Reproduces from V0 (148 KB metadata) to V2 (44 KB metadata) within 0.2 %, confirming the V2 storage shrink costs nothing.

16-core canneal V2 (corrected from `simulator/results/phase2b_16core_canneal_V2/logs/`):

| Policy | max cycles | vs COALESCE | bottleneck IPC (CPU 1/6/11 avg) | worker IPC (CPU 0/5/10/15 avg) |
|---|---|---|---|---|
| **COALESCE** | **921,717,448** | – | **0.1086** | **1.1832** |
| LRU | 1,175,413,203 | +21.6 % slower | 0.0852 | 0.8911 |
| SRRIP | 1,346,899,280 | +31.6 % slower | 0.0744 | 1.0257 |
| SHiP | 1,347,373,218 | +31.6 % slower | 0.0743 | 1.0268 |
| DRRIP | 1,348,106,937 | +31.6 % slower | 0.0743 | 1.0257 |

The 8-core worker regression flips into a +15.3 % win at 16-core. Use this as the scaling figure F2 in the paper.

### 1.3 Infrastructure already built and committed (DO NOT rebuild)

| Component | Path | What it does | Sanity check |
|---|---|---|---|
| ASID-keyed VMEM overlay | `simulator/inc/vmem.h` + sibling, `simulator/src/vmem.cc` | `set_shared_cpus({0..N-1})` makes identical VAs from those CPUs alias on the same physical page. Smoking-gun counter: `VMEM ALIASED FILLS` printed by `main.cc` at end of sim. | Smoke-verified: `vmem_shared_cpus=[]` reproduces V0; `=[0,1,2,3]` gives ALIASED FILLS = 30 in a 50 k canneal smoke. |
| Synthetic microbench | `bench/synth_coherence.c` | 3 modes (A=private-only, B=producer/consumer, C=read-mostly migratory) for end-to-end VMEM validation | Compiles `gcc -O0 -pthread -Wall`; runs in ~10 ms per mode locally. |
| V1..V6 runner | `bench/scripts/run_synth_matrix.sh` | Launches the full validation matrix with one shell call | Reads pre-built configs from § 1.4 |
| Result parser | `bench/scripts/parse_overlay_results.py` | Extracts smoking-gun counters from any ChampSim log into CSV/MD | Unit-tested with a fake log; extracts ALIASED FILLS, INVALIDATIONS, SHARER HIST, per-CPU IPC, max_cycles. |
| Configs | `simulator/synth_8core_private.json`, `simulator/synth_8core_shared.json` | Pre-built configs (`vmem_shared_cpus=[]` and `=[0..7]`) | Use directly with `./config.sh` + `make` |
| Cross-CPU isolation tests | `simulator/test/cpp/src/801-vmem-duplicated.cc` | Three Catch2 SCENARIOs (default isolation, shared aliasing, idempotent setter) | `.o` builds clean; full link not run yet |
| Observability counters | `cache_stats.h` + sibling | `coherence_invalidations`, `coherence_write_hit_other_sharer_events`, `coherence_sharer_hist[17]` already plumbed | All three counters print in `plain_printer.cc` |

### 1.4 Citation references (already curated)

- BibTeX master: `coalesce_paper/citations/references.bib` (18 entries).
- Per-parameter justifications (10): `coalesce_paper/citations/justifications/B{1..10}_*.md`.
- Per-paper Related Work notes (11): `coalesce_paper/citations/related_work_notes/D{1..11}_*.md`.

Inline citations in this doc use `[bibkey]` to point at `references.bib`.

---

## 2. The two-regime paper framing (locked)

### Regime 1 — Capacity-pressure (the headline)

Default ChampSim VMEM `[champsim]`, each CPU isolated address space. COALESCE wins 21–33 % at 4/8/16-core canneal even though the sharer-count feature is inert (sharer = 1 always). The win comes from PC + MESI-state perceptron prediction `[jimenez2017multiperspective]` with the +40 MODIFIED bias firing on ~85 % of evictions.

**Story**: "COALESCE's perceptron features generalize beyond the coherence regime they were designed for, delivering large gains under capacity-driven multi-program LLC pressure."

### Regime 2 — True-sharing (the contribution lift)

VMEM shared-overlay activates. Same workloads, same policies, but cpus 0..N-1 alias on shared physical pages. Sharer-count fires (`bin[k≥2] > 0`). +20×sharer bias contributes. Coherence invalidations are non-zero.

**Story**: "When sharing is exposed (we built the overlay mechanism for this purpose), COALESCE's coherence features deliver additional benefit. The 4-way ablation (LRU × private/shared vs COALESCE × private/shared) isolates this contribution as a double-difference."

### Why two regimes (not just one)

A single-regime paper would have to either (a) claim coherence-observance with empirical sharer hist = 100 % bin[1] (dishonest) or (b) reframe to "capacity-aware" (deflating). The two-regime structure keeps the headline AND honestly reports the coherence mechanism firing under controlled conditions.

---

## 3. Lock decisions (do NOT re-litigate)

| Decision | Status | Why |
|---|---|---|
| Policy stays as V2 config (SAMPLING_MODULO=32, GHOST_CAPACITY=128, BLOOM_RESET_THRESHOLD=150, +40 MODIFIED bias, +20×sharer bias) | LOCKED | All 4/8/16-core canneal results were produced by V2. Changing it invalidates the headline. |
| Hash1 keeps `(pc, sharers)` signature | LOCKED | Sharer is currently constant input in Regime 1 (harmless) and varies in Regime 2 (the whole point). Don't refactor. |
| Existing 4/8/16-core canneal results stay untouched as Regime 1 | LOCKED | Re-running wastes server-days. |
| Regime 2 = VMEM shared-overlay only | LOCKED | Inter-cache snoop layer = Saga 2, see `docs/coherence_aware.md` § 8.2. |
| Server is the only execution surface | LOCKED | All experiments here. Local laptop is for plan + doc work only. |

---

## 4. The expanded experiment matrix

### 4.1 Regime 2 main matrix (Phase 2A-R2)

| | LRU | SRRIP | DRRIP | SHiP | **Hawkeye** | **Mockingjay** | **COALESCE** |
|---|---|---|---|---|---|---|---|
| **canneal-4core shared** | 🆕 | 🆕 | 🆕 | 🆕 | 🆕 | 🆕 | 🆕 |
| **canneal-8core shared** | 🆕 | 🆕 | 🆕 | 🆕 | 🆕 | 🆕 | 🆕 |
| **fluidanimate-4core shared** | 🆕 | 🆕 | 🆕 | 🆕 | 🆕 | 🆕 | 🆕 |
| **fluidanimate-8core shared** | 🆕 | 🆕 | 🆕 | 🆕 | 🆕 | 🆕 | 🆕 |
| **dedup-4core shared** | 🆕 | 🆕 | 🆕 | 🆕 | 🆕 | 🆕 | 🆕 |
| **dedup-8core shared** | 🆕 | 🆕 | 🆕 | 🆕 | 🆕 | 🆕 | 🆕 |
| **canneal-16core shared** (limited) | 🆕 | – | – | – | – | – | 🆕 |

= 42 runs at 4/8-core + 2 at 16-core canneal = **44 runs**. Each 8-core run is ~6–12 hr, 16-core is ~22 hr.

### 4.2 Regime 1 Hawkeye/Mockingjay supplement (Phase 2A-R1)

| | canneal-4core | canneal-8core | canneal-16core |
|---|---|---|---|
| Hawkeye (private) | 🆕 | 🆕 | 🆕 |
| Mockingjay (private) | 🆕 | 🆕 | 🆕 |

= 6 runs. Needed so the Regime 1 results compare against the ML state-of-the-art, not just classical baselines.

### 4.3 Bias sweep (Phase 2D)

`B_M ∈ {0, 20, 40, 60, 100}` on **8-core canneal under SHARED VMEM**, COALESCE only. 5 runs. The shared regime is where the bias actually matters (Regime 1 results are insensitive to it because the gate `if (raw_vote > 0) ... if (current_set[w].state == MODIFIED)` fires regardless of sharing — but bias magnitude tuning is most meaningful where the full set of bias terms is active).

### 4.4 Statistical re-runs (Phase 2E)

8-core canneal headline matrix under both regimes: 7 policies × 2 regimes × 2 additional seeds = **28 runs**. Use `vmem.randomization` JSON field (already supported, `parse.py:343`).

### 4.5 Validation (Phase 2V, GATING)

V1..V6 from `bench/scripts/run_synth_matrix.sh`. 6 runs. < 1 day total.

### 4.6 Total budget

| Phase | Runs | Wall-clock @ 8-way | Cut priority if slipping |
|---|---|---|---|
| 2V validation | 6 | < 1 day | — never cut, GATING |
| 2H smoke | 2 | < 1 day | — never cut |
| 2W trace gen | 6 trace sets | 1-2 days | cut dedup first |
| 2A-R2 main | 42 | 4-7 days | cut Mockingjay-* second, then dedup-* third |
| 2A-R2 16-core | 2 | 1 day | cut entirely; use Regime 1 16-core for scaling |
| 2A-R1 supplement | 6 | 1 day | cut Mockingjay entries first |
| 2D bias sweep | 5 | 1 day | reduce to 3 points (0, 40, 100) |
| 2E 3-seed | 28 | 3-5 days | reduce to 2 extra seeds, only canneal-8core-shared × 7 = 14 runs |

Realistic ship target: ~55 runs in 8 server-days. See § 12 day-by-day timeline.

---

## 5. Phase 2V — Validate VMEM overlay (GATING)

Until V4 passes, **do not start any other Regime-2 work**. The overlay either fires or it doesn't; that determines whether the entire Track A direction is viable.

### 5.1 Prerequisites

1. PIN 3.31 installed at `$PIN_ROOT` on server. Tracer source at `simulator/tracer/pin/champsim_tracer.cpp` (already there). Build the tracer once:
   ```
   cd simulator/tracer/pin
   make PIN_ROOT=$PIN_ROOT obj-intel64/champsim_tracer.so
   ```
2. Compile the synth bench on the server:
   ```
   cd bench
   gcc -O0 -pthread -Wall synth_coherence.c -o synth_coherence
   ```
3. Generate synth traces (≈ minutes per mode):
   ```
   for mode in A B C; do
     $PIN_ROOT/pin -t simulator/tracer/pin/obj-intel64/champsim_tracer.so \
       -o simulator/traces/synth_mode${mode} \
       -- bench/synth_coherence $mode 200000
   done
   ```
   Produces `synth_mode{A,B,C}{0..7}.champsimtrace`.
4. Build the two synth simulators from pre-existing configs:
   ```
   ./simulator/config.sh simulator/synth_8core_private.json && (cd simulator && make)
   ./simulator/config.sh simulator/synth_8core_shared.json && (cd simulator && make)
   ```
   For V5: copy `synth_8core_shared.json` → `synth_8core_shared_coalesce.json`, change `LLC.replacement` to `coalesce`, rebuild.

### 5.2 The matrix and pass criteria

| Run | Mode | VMEM | Policy | Pass | What it proves |
|---|---|---|---|---|---|
| V1 | A | private | LRU | bin[1]≈100%, inv=0, aliased=0 | baseline preserved |
| V2 | A | shared (cpus 0..7) | LRU | **bin[1]≈100%**, inv=0, aliased=0 | overlay is workload-driven (NEGATIVE CONTROL — critical) |
| V3 | B | private | LRU | bin[1]≈100% | reproduces canneal failure mode |
| V4 | B | shared | LRU | **bin[k≥2]>0**, **inv≫0**, **aliased≫0** | **MECHANISM FIRES** |
| V5 | B | shared | COALESCE | V4 conditions + IPC distinguishable from V4 LRU | COALESCE benefits from active coherence features |
| V6 | C | shared | LRU | high sharer bins, inv=0 | read-only sharing works without spurious invalidations |

### 5.3 Run it

```
cd /home/harshraj/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy
bash bench/scripts/run_synth_matrix.sh
```

This writes per-run logs to `simulator/results/phase2a_synth_overlay/logs/` and a stdout summary table.

### 5.4 What to do on each outcome

- **All six pass**: proceed to § 6 (Hawkeye/Mockingjay) AND § 7 (workload traces) in parallel.
- **V4 fails** (no invalidations): debug by running with `champsim::debug_print = true` recompile, look for VMEM not seeing the shared addresses. Check `aliased_fills` first — if zero, the JSON `vmem_shared_cpus` field didn't propagate; verify `simulator/config/parse.py:343` default kicked in and `instantiation_file.py` emits the `set_shared_cpus` call. If `aliased_fills > 0` but `inv = 0`, the VMEM is aliasing but the LLC sharer-mask propagation isn't seeing the shared accesses — check `cache.cc:153, 305, 315` for the state-transition code.
- **V2 fails** (Mode A + shared still shows bin[k≥2]): the overlay is over-firing on something workload-independent (stacks/code text aliasing). Add VA-range filtering (Saga 2 territory; for HiPC, document as Threat-to-Validity).

---

## 6. Phase 2H — Sourcing & integrating Hawkeye + Mockingjay

### 6.1 Sourcing

Two paths, in priority order:

1. **CRC2 / CRC3 community implementations** (preferred): The Cache Replacement Championships 2 (2017) and 3 (2021) shipped clean Hawkeye + Mockingjay implementations as ChampSim modules. Pull from:
   - Hawkeye `[jain2016hawkeye]`: https://crc2.ece.tamu.edu/ or the original `https://github.com/Akanksha-Jain/Hawkeye` (verify URL during PIN install). The implementation typically lives in a `replacement/hawkeye/hawkeye.{h,cc}` pattern matching our existing modules in `simulator/replacement/{lru,srrip,drrip,ship,random,coalesce}/`.
   - Mockingjay `[shah2022mockingjay]`: Originally distributed at the HPCA 2022 artifact. Search via Ishan Shah's homepage / Akanksha Jain's UT Austin page.
2. **Authors' personal repos**: If CRC repos are stale, the original implementations from Jain & Lin (UT Austin) and Shah et al. (UT Austin) are the next stop.

### 6.2 Integration

For each new module, the ChampSim module API requires:
- A subdirectory under `simulator/replacement/<name>/`
- A `<name>.h` declaring `class <Name> : public champsim::modules::replacement` with at minimum `find_victim()` and `update_replacement_state()` (see `simulator/replacement/coalesce/coalesce.h` for the exact signature)
- A `<name>.cc` implementing them
- The module name is referenced from the LLC `replacement` field in the JSON config.

### 6.3 Smoke test

Build a copy of `btp_config.json` with `LLC.replacement` set to `hawkeye` (then `mockingjay`), build, run on a single canneal-4core trace for ~5 M sim instructions, and confirm IPC is in the same ballpark as the published numbers for the corresponding workload.

### 6.4 Pass criterion

Hawkeye 4-core canneal IPC should be within ±5 % of SHiP `[wu2011ship]` (Hawkeye consistently matches or beats SHiP on PARSEC in the published literature). If wildly off, the implementation is mis-integrated or the trace differs from what the authors tested on.

---

## 7. Phase 2W — Trace generation for fluidanimate + dedup

### 7.1 PIN install + tracer build

(Same prerequisites as § 5.1.)

### 7.2 PARSEC source

At `simulator/tracer/pin/parsec-3.0/`. The fluidanimate and dedup binaries need to be built first (PARSEC's gcc-pthreads build):
```
cd simulator/tracer/pin/parsec-3.0
. env.sh
parsecmgmt -a build -p fluidanimate -c gcc-pthreads
parsecmgmt -a build -p dedup -c gcc-pthreads
```
This requires `gcc`, `make`, `boost`, `libssl-dev` and others; expect dependency-hunt time on a fresh server.

### 7.3 Generate traces

For each workload at each core count, run the PARSEC binary under PIN with the simlarge input set:
```
$PIN_ROOT/pin -t simulator/tracer/pin/obj-intel64/champsim_tracer.so \
  -o simulator/traces/fluidanimate_4t \
  -- parsec-3.0/pkgs/apps/fluidanimate/inst/<arch>/bin/fluidanimate 4 5 \
       parsec-3.0/pkgs/apps/fluidanimate/inputs/simlarge/in_300K.fluid out.fluid
```
The exact PARSEC invocation lives in `parsec-3.0/pkgs/apps/<bench>/parsec/<arch>.runconf`. Wrap with `parsecmgmt -a run -p fluidanimate -c gcc-pthreads -i simlarge -n 4 -s "<pin command>"` for cleaner integration.

Trace expected size: ~300 MB per thread × 4/8/16 threads = 1.2 / 2.4 / 4.8 GB per workload-config. Each takes ~6–12 hr wall.

### 7.4 Pass criterion

For each `(workload, threads)` pair, all N thread output files exist and are non-empty. Open one in a hex viewer and sanity-check it starts with a sequence of `input_instr` records (binary, see `simulator/inc/trace_instruction.h`).

---

## 8. Phase 2A-R2 — Regime 2 main matrix

### 8.1 Per-policy binary build

For each of 7 policies (LRU, SRRIP, DRRIP, SHiP, Hawkeye, Mockingjay, COALESCE), produce a binary built with the shared VMEM config:
```
# Make a per-policy config file from synth_8core_shared.json:
cp simulator/synth_8core_shared.json simulator/btp_8core_shared_<policy>.json
# Edit LLC.replacement to "<policy>" and executable_name to e.g. "champsim_8core_shared_lru"
# Build:
./simulator/config.sh simulator/btp_8core_shared_<policy>.json
(cd simulator && make)
```
Repeat for the 4-core analogue (`btp_config.json` as the base, change to 4-core; or use a fresh `synth_4core_shared.json`).

### 8.2 Run template

```
cd simulator
bin/champsim_8core_shared_<policy> \
  --warmup-instructions 50000000 --simulation-instructions 100000000 \
  $TRACE_LIST > results/phase2a_R2_<workload>_8core_shared_<policy>.log 2>&1
```
where `$TRACE_LIST` is the comma-separated list of 8 thread traces. Use `nice -n 19` and run inside `tmux`.

### 8.3 Workload trace selection

| Workload | Trace pattern (8-core) |
|---|---|
| canneal | `traces/canneal_big{0,1,2,3,4,0,1,2}.champsimtrace` |
| fluidanimate | `traces/fluidanimate_8t{0..7}.champsimtrace` |
| dedup | `traces/dedup_8t{0..7}.champsimtrace` |

### 8.4 Pass criterion

Each log ends with `Simulation complete CPU N` for every CPU and ROI stats with non-zero `VMEM ALIASED FILLS` (otherwise the shared overlay didn't activate — likely a config bug, NOT a workload property).

---

## 9. Phase 2D — Bias sweep

Edit `simulator/replacement/coalesce/coalesce.cc:118` (the `+ 40` constant for the MODIFIED bias) to each sweep value, rebuild, and re-run 8-core canneal under SHARED VMEM. Single seed.

| Run | B_M value | Action |
|---|---|---|
| B0 | 0 | edit `+ 40` → `+ 0`, rebuild, run |
| B20 | 20 | edit `+ 40` → `+ 20`, rebuild, run |
| B40 | 40 (current) | use existing R2 result |
| B60 | 60 | edit `+ 40` → `+ 60`, rebuild, run |
| B100 | 100 | edit `+ 40` → `+ 100`, rebuild, run |

Result: a 5-point sensitivity curve (B_M on x-axis, 8-core canneal max_cycles on y-axis). Cite `[jimenez2017multiperspective]` for the sweep methodology. Expected shape: shallow optimum around B_M = 40–60. If optimum is dramatically elsewhere, V2 was mis-tuned and the headline number may shift — flag immediately.

(Restore `+ 40` after the sweep ends, before any other runs.)

---

## 10. Phase 2E — 3-seed statistical re-runs

Add `"vmem": { "randomization": <seed> }` to the JSON config (in addition to the existing `vmem_shared_cpus` field). The `randomization` value is already plumbed by `parse.py:343` and gets passed to `VirtualMemory`'s second constructor (`vmem.cc:30`).

For each of 7 policies × 2 regimes (private, shared) × 8-core canneal:
- Seed 1 = existing run (already logged)
- Seed 2 = new run with `randomization: 12345`
- Seed 3 = new run with `randomization: 67890`

Report mean ± std-dev for max_cycles and per-CPU IPC in the paper headline table.

Pass criterion: std-dev < 2 % of mean for the headline numbers. If higher, the result is noisier than ChampSim's typical variance and the headline claim weakens — investigate before submission.

---

## 11. Aggregation and the paper-figure list

### 11.1 Result parser

Extend `bench/scripts/parse_overlay_results.py` to:
- Pull `MESI STATE HIST` if present (it's not yet — instrumentation pending; if not present, skip silently)
- Pull `BIAS FIRES` counters (same — not yet wired)
- Label each row with `regime` (private/shared) and `seed`
- Output a long-form CSV: `run, regime, workload, cores, policy, seed, max_cycles, mean_ipc, llc_invalidations, llc_other_share_evs, aliased_fills, hist_top4`

### 11.2 The 5 paper figures

| # | Figure | Source data | Status |
|---|---|---|---|
| F1 | 4-core canneal IPC bar chart, 5 policies | Existing `simulator/results/canneal_4core_50M/` | ☑ |
| F2 | 8/16-core canneal scaling (cycles for 4 baselines + COALESCE) | Existing 8-core V2 + 16-core V2 | ☑ |
| F3 | **Sharer-count histogram, private vs shared VMEM** | Need: 8-core canneal × LRU × {private, shared} runs from § 8 + instrumentation for SHARER HIST emission | NEW |
| F4 | **Synth bench Mode B, LRU vs COALESCE under shared VMEM** | V4 + V5 from Phase 2V | NEW |
| F5 | **4-way ablation on canneal-8core: (LRU, COALESCE) × (private, shared)** | 4 runs total: 2 from existing Regime 1 + 2 from Phase 2A-R2 | NEW |

### 11.3 Tables

- T1: hardware overhead (be honest about 148 KB → 44 KB shrink; reference `[sethumurugan2021designing]` for the 5 KB design point we approach)
- T2: 8-core canneal headline numbers under both regimes (with 3-seed CI)
- T3: bias-sweep sensitivity (Phase 2D output)
- T4: scaling 4/8/16-core under both regimes (cycles + IPC)

---

## 12. Day-by-day timeline (today = 2026-06-05, deadline = 2026-06-17)

| Day | Date | Server work | Local / paper work | Cut order applies |
|---|---|---|---|---|
| D1 | Jun 5 | PIN install + tracer build; kick off Hawkeye sourcing | – | – |
| D2 | Jun 6 | Synth trace gen; **V1..V6 validation (Phase 2V)** | – | – |
| D3 | Jun 7 | V4 result lands. If pass: start fluidanimate trace gen; integrate Hawkeye. If fail: debug per § 5.4. | – | If V4 fails by EOD, cut Regime 2 entirely; use bias sweep on private VMEM as bonus material; refocus on canneal Regime 1 + Hawkeye/Mockingjay supplement (Phase 2A-R1) |
| D4 | Jun 8 | dedup trace gen starts; canneal-8core-shared × 5 existing policies kicks off (5 runs) | – | If trace gen drags, cut dedup |
| D5 | Jun 9 | canneal-shared completes; fluidanimate-8core-shared starts; Hawkeye + Mockingjay smoke (Phase 2H) | Begin paper draft outline | – |
| D6 | Jun 10 | fluidanimate-shared completes; bias sweep (Phase 2D) starts | Intro + Background sections | – |
| D7 | Jun 11 | bias sweep completes; 3-seed re-runs (Phase 2E) start; canneal-shared × Hawkeye + Mockingjay | Methodology + Results sections | – |
| D8 | Jun 12 | 3-seed completes; aggregate; build figures | Discussion + Threats to Validity | If 3-seed runs blow budget, drop to 2 seeds |
| D9 | Jun 13 | dedup-shared × 5 existing policies (if budget allows) | Paper draft v1 complete | If server saturated, cut dedup |
| D10 | Jun 14 | – | Send draft to advisor | – |
| D11 | **Jun 15** | – | **Advisor meeting, apply feedback** | – |
| D12 | Jun 16 | – | Polish, format check, post draft | – |
| D13 | **Jun 17** | – | Final check, **submit abstract** | – |

### Cut order if slipping (single rule: every cut shaves ~1 server-day)

1. dedup × all configs → cut first (most expensive, lowest marginal value)
2. Mockingjay × all configs → cut second (Hawkeye is the more critical ML baseline)
3. 16-core canneal-shared → cut third (use Regime 1 16-core for scaling figure)
4. fluidanimate × Hawkeye/Mockingjay → cut fourth
5. B_M sweep → reduce from 5 to 3 points

NEVER cut: V1..V6, canneal-8core × {LRU, COALESCE} × {private, shared}, 3-seed on canneal-8core-shared headline, the methodology rewrite, the 4-way ablation figure.

---

## 13. Citation map (every claim → bibkey)

| Claim / parameter | Bibkey | Where it goes in the paper |
|---|---|---|
| Perceptron substrate | `[jimenez2017multiperspective]`, `[jimenez2001perceptron]` | § Background, § COALESCE Design |
| MESI protocol semantics | `[sorin2011coherence]` | § Background |
| Baseline RRIP family | `[jaleel2010rrip]` | § Background, § Evaluation |
| SHiP baseline | `[wu2011ship]` | § Background, § Evaluation |
| Hawkeye baseline (NEW) | `[jain2016hawkeye]` | § Background, § Evaluation, § Related Work |
| Mockingjay baseline (NEW) | `[shah2022mockingjay]` | § Background, § Evaluation, § Related Work |
| Belady's MIN (theoretical upper bound) | `[belady1966study]` | § Related Work, optional § Discussion |
| DRAM latency justification | `[hennessy2017quantitative]`, `[molka2009memory]` | § Methodology |
| 6.25% set sampling rationale | `[jimenez2017multiperspective]` | § COALESCE Design § B5 |
| <5 KB hardware budget target | `[sethumurugan2021designing]` | § Hardware Overhead |
| PARSEC workloads | `[bienia2008parsec]` | § Methodology |
| PIN tracer | `[luk2005pin]` | § Methodology |
| ChampSim simulator | `[champsim]` | § Methodology |
| Coherence-aware optimization prior art | `[cuesta2011coherence]`, `[hardavellas2009rnuca]` | § Related Work |
| RL-based ML cache replacement | `[souza2024rl]`, `[sethumurugan2021designing]`, `[wu2025camp]` | § Related Work |
| Distilled LSTM cache replacement | `[shi2019glider]` | § Related Work |
| Computer architecture textbook | `[hennessy2017quantitative]` | § Background |

Per-parameter justifications already drafted at `coalesce_paper/citations/justifications/B{1..10}_*.md`. Per-paper Related Work paragraphs already drafted at `coalesce_paper/citations/related_work_notes/D{1..11}_*.md`. Use these as drop-in source material; do not re-derive.

---

## 14. Risk register

| Risk | Probability | Impact | Mitigation |
|---|---|---|---|
| PIN install blocked on server | medium | high | Day 1 escalate to lab admin; fall back to canneal-only Regime 2 if PIN unavailable by D3 |
| V4 fails (no invalidations under shared VMEM) | low | very high | Debug per § 5.4; if not fixable by D3 EOD, drop Regime 2 entirely; ship Regime 1 + Hawkeye/Mockingjay supplement |
| Hawkeye/Mockingjay implementations unavailable | medium | high | Skip whichever isn't found; cite as Threats-to-Validity ("strongest available baseline at submission time was SHiP") |
| Server contention (other users) | high | medium | Run `nice -n 19`; budget assumes 8-way parallel, scale down if only 4-way available; drop further per § 12 cut order |
| 3-seed std-dev > 2 % | low | medium | Investigate; may indicate non-deterministic trace replay; report seeds + means honestly |
| 16-core shared VMEM run takes > 30 hr | medium | low | Cut; use Regime 1 16-core for scaling figure |
| Advisor feedback requires major rewrite by Jun 15 | low | high | D14-D16 buffer is tight but real; pre-emptively share an outline with advisor on D9 so feedback can come in before Jun 15 if possible |
| dedup workload doesn't show coherence sharing | medium | medium | Dedup uses producer-consumer queue passing, expected to show sharing. If not, drop it from Regime 2 results without comment. |
| Hawkeye/Mockingjay implementations don't compile under our modified ChampSim (16-bit sharer_mask, etc.) | medium | medium | Adapt minimally; only the replacement-module interface needs to match. Avoid touching their internals. |

---

## 15. After the matrix completes

### 15.1 The "ready-for-paper" checklist

- [ ] All V1..V6 runs logged in `simulator/results/phase2a_synth_overlay/logs/`
- [ ] V4 produced bin[k≥2] > 0, INV > 0, ALIASED FILLS > 0
- [ ] Regime 2 main matrix: at minimum canneal-8core × 5 policies × shared logged in `simulator/results/phase2a_R2_canneal_8core_shared/`
- [ ] Bias sweep: 5 logs in `simulator/results/phase2d_bias_sweep/`
- [ ] 3-seed: 14+ logs in `simulator/results/phase2e_seeds/`
- [ ] All logs parsed into a single CSV via `bench/scripts/parse_overlay_results.py`
- [ ] 5 figures generated (F1..F5)
- [ ] 4 tables generated (T1..T4)
- [ ] BibTeX wired into the .tex draft (currently uses inline `\bibitem`; migrate to `\bibliography{references.bib}`)

### 15.2 Paper rewrite checklist (Day 8-10)

- [ ] Title locked: **COALESCE: Coherence-Observant Adaptive Learning for System-wide Cache Efficiency**
- [ ] Abstract names both regimes
- [ ] Methodology has new subsection "VMEM shared-overlay mechanism"
- [ ] Methodology DROPS the K80 GPU mention (see `docs/OPEN_DECISIONS.md` item #3)
- [ ] Threats-to-Validity covers the 5 preempts listed in `docs/coherence_aware.md` § 6
- [ ] Related Work expanded to ≥15 refs using the D-notes
- [ ] Hardware budget table is honest about ~44 KB (not <5 KB; see `docs/OPEN_DECISIONS.md` item #2)
- [ ] All claims tied to a citation; no `[TODO]` markers in the camera-ready

### 15.3 Submission

- Conference: HiPC 2026 main track
- Format: IEEE conference, 10 pages
- Deadline: 2026-06-17 (verify abstract vs full paper deadline on hipc.org)
- Camera-ready: post-acceptance, no immediate concern

---

## 16. Companion docs (read these when stuck)

| Doc | When to read |
|---|---|
| `docs/coherence_aware.md` | Whenever you need to understand WHY a decision was made; especially § 6 (Threats-to-Validity preempts) and § 8 (Saga 1+2 timeline) |
| `docs/SESSION_CONTEXT.md` § 16 | Per-session log; what was done in the previous session that produced the infrastructure |
| `docs/OPEN_DECISIONS.md` | Item #2 (hardware overhead), #6 (coherence hook audit), #17 (VMEM overlay) are the load-bearing ones |
| `docs/COALESCE_EXPLAINED.md` | Technical walk-through; share with advisor before the Jun 15 meeting if they want depth |
| `docs/PUBLICATION_STRATEGY.md` § 2 | The original weakness inventory A1–A10, B1–B10, C1–C7, D1–D11, E1–E7. This plan addresses A1, A2, A3, A4, A5, A7, A8, B2, B3, C1, D1, D2, E1, E2, E3, E4, E5, E6, E7. |
| `coalesce_paper/COHERENCE_HOOK_AUDIT.md` | What ChampSim does and doesn't model coherence-wise; the input data for Threats-to-Validity § 4.1 |
| `~/.claude/plans/ok-analyzew-the-entire-crystalline-reef.md` | The plan that produced this document |

---

## 17. One-paragraph reality check

We have 12 days. The Regime 1 results (4/8/16-core canneal under default VMEM) already exist and stand on their own as a 21–33 % cycle reduction via PC + MESI-state perceptron prediction. The VMEM shared-overlay was built and committed last session; this plan validates it via V1..V6 and runs Regime 2 to demonstrate the coherence features fire when sharing actually exists. Adding Hawkeye + Mockingjay baselines and fluidanimate + dedup workloads strengthens the paper considerably, but is also where most of the server-time risk sits — apply the cut order in § 12 ruthlessly if calendars slip. The bias sweep and 3-seed re-runs close the n=1 and B_M=40-is-asserted weaknesses from the original strategy doc. By Jun 14, the paper draft is in the advisor's hands; Jun 15 meeting, Jun 16 polish, Jun 17 submit. The policy itself is locked at V2 — no code changes, no refinement, no Track B fallback. Either V4 passes and we ship a two-regime paper, or V4 fails and we ship a single-regime capacity-pressure paper with Hawkeye/Mockingjay supplement and the VMEM overlay relegated to Future Work / Saga 2. Both outcomes are publishable. The thing we are NOT doing is re-running 4 baselines on canneal that already have 4/8/16-core V2 numbers.
