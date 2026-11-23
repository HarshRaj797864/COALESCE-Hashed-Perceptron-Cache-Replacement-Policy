# H3: the ranking statistics and ChampSim's noise floor (pre-registration, 2026-11-14)

PLAN § 10 item 9, H3. Written before any shifted-window run exists and
before the statistics below have been computed on any row.

## Why

- **τ is weak with nine policies.** It must reach 0.556 for a two-sided
  p below 0.05; τ 0.278 has a one-sided p of 0.179 (the research report,
  `reports/Validating a multithreaded cache simulator.md`).
- **The paper quotes τ without an exact p, an interval or a tie rule.** Its
  question is whether a ranking *transfers* (τ near the ceiling that noise
  allows), not whether τ exceeds 0.
- **Some of the paper's claims rest on gaps nobody has compared with
  ChampSim's own variation.** COALESCE "1st" at canneal 8c fixed 2 MB shared
  (by 0.67%) and at 16c (by 0.06%). P11's explanation, "at 2 MB a core the
  policies sit closer together, and any change of conditions reorders them".

## Already read (disclosed)

Every τ restated below was scored earlier by its own rules and has been
read: step 5 (P11-P14, the size controls, synchronised against drifting),
A6, C0. So were step 5's rankings:
- canneal 8c fixed 2 MB shared: COALESCE, Mockingjay, SRRIP, srrip_bias,
  gaps 0.67 / 0.01 / 0.28%;
- canneal 8c 2 MB a core shared: SRRIP, srrip_bias, Mockingjay, SHIP, gaps
  0.15 / 0.02 / 0.02%.

**No verdict changes.** P11-P14 and A6's H0 stand as scored. H3 adds the
statistics and the noise floor beside them.

## H3a: the noise floor (server, 32 runs)

**Configurations.** Step 5's canneal 8c, shared, on step 5's binary
`champsim_g6_1e3060c1` (md5 `1e3060c1760b4b3b18e5728a9dfb75ed`), traces
`sync_mx/canneal8/raw1-8`:
- **fixed** (2 MB): the reference tree is `phaseA_b3_p2_canneal8`, config
  `~/sync_pol/cfg/canneal8_shared_<p>.json`. Policies: the top four of step 5
  there, `coalesce mockingjay srrip srrip_bias`.
- **scaled** (2 MB a core): the reference tree is
  `phaseA_b3_p2_canneal8_scaled`, config
  `~/sync_pol/cfg/canneal8_scaled_shared_<p>.json`. Policies: its top four,
  `srrip srrip_bias mockingjay ship`.

The scaled set is added to PLAN's "canneal 8c fixed 2 MB": it tests P11's
explanation directly. If the server is short, it is cut before the fixed set.

**Windows.** Warmup W ∈ {45, 47.5, 52.5, 55} M, simulation 100 M a core,
everything else the reference run's: its config file unchanged, its traces
in its order, its binary. Step 5's run is W = 50 M, so each policy has 5
windows. That gives 2 classes × 4 policies × 4 new windows = **32 runs**, the
fixed class first, 8 at a time, nice 19. Each run is written to
`results/phaseA_b3_h3w<W>_canneal8[_scaled]/regime_shared/canneal_8core/<p>/run.log`,
with `W` in M (`45`, `47p5`, `52p5`, `55`), its `config.json` beside it and
`.bin`.

**Guards (server).**
- The g6 binary's md5.
- Each reference log complete at 50 M + 100 M with 8 CPUs, its traces equal
  to `sync_mx/canneal8/raw1-8`, and its config file present with
  `LLC.replacement` = its policy.
- Every trace's `raw<t>.mix` totals at least 160 M instructions (55 + 100 M
  and a 5 M margin; each holds 215 M).
- No H3 driver or run alive; disk free at least 20 GB.

**Each run qualifies** if it:
- completed (`ChampSim completed all CPUs`);
- prints `Warmup Instructions: W` and `Simulation Instructions: 100000000`;
- has 8 CPUs, and its `CPU n runs` lines equal the reference's;
- is at level 2 with `SYNC REPLAY: on`;
- has no `Reached end of trace` and no `SYNC DEADLOCK`;
- reads 0 for self-check, stale holders and unexplained view-order
  violations;
- has a `config.json` equal to the reference config file and a `.bin` that
  names the g6 binary.

If any run of a class fails, that class's δ is **not declared**, and its
rankings are restated without a tie rule.

**The measure.**
- Each run gives c = its max_cycles, the largest ROI `cycles` over its
  CPUs, the rows' `max_cyc`. The parser must reproduce step 5's rows for
  the 8 references.
- Per class, ln c(p, W) is fitted by the two-way additive model μ + a_p +
  b_W + e. This removes the common shift that a window move gives every
  policy.
- The residual standard deviation is s_e, with (4 − 1)(5 − 1) = 12 degrees
  of freedom.
- Two policies' log gap then varies with standard deviation √2 s_e.
- **The tie threshold is δ = t(0.975, 12) × √2 × s_e = 2.179 × √2 × s_e** (log
  units). A pair whose |ln(c_i / c_j)| < δ is *not separated*.
- Also printed: each of the 6 pairs' gap in every window and whether its
  sign holds in all 5.

**Where δ applies.**
- δ_fixed applies to every fixed-2 MB ranking, δ_scaled to every
  2 MB-a-core ranking: canneal 4, 8 and 16 cores and ocean, shared and
  private, step 5's g6 rows and the drifting side of synchronised against
  drifting.
- This assumes that the window noise of canneal 8c shared stands for the
  other cores, programs and regimes in log units. Only one configuration a
  class is measured, so the assumption is disclosed wherever δ is used.
- A6 and C0 (another binary, drifting traces, other LLC sizes) are restated
  without δ.

## H3b: the statistics (laptop, committed rows only)

Rows: `phasea_rows_v29.txt` (step 5, A6, C0, the level-2 A5 rerun), as
scored. Ranking: max_cycles, lower first. Over each pair of rankings A, B of
the same n policies:

1. **τ_b.** Kendall's tau-b; ties are only exactly equal max_cycles.
2. **Exact two-sided p of τ_b.** Every one of the n! assignments of B's
   values to the policies is enumerated with A held, giving 362,880 for n = 9
   and 40,320 for n = 8. p = the share with |τ_b| ≥ |τ_b observed| (to
   1e-12). It is exact under random assignment, with the observed ties.
3. **τ_δ.** The tau-b formula with pairwise ties: a pair is tied in a
   ranking when its gap is under δ there.
   - C and D are counted over pairs separated in both rankings.
   - T_A and T_B are the pairs tied in A and in B; N = n(n−1)/2.
   - τ_δ = (C − D) / √((N − T_A)(N − T_B)).
4. **Sign agreement:** over pairs separated in both rankings, the counts that
   agree and disagree.
5. **Top-1 and top-3.**
   - Top-1 agrees when A's best is within δ of B's best in B, and B's best
     within δ of A's best in A.
   - Top-3 is the overlap (0-3) of the two top-3 sets.
6. **The noise ceiling and the noise interval** (a parametric bootstrap;
   10,000 draws, numpy seed 20261114).
   - Every policy's ln c in A and in B gets independent N(0, s_e²) noise.
   - The **ceiling** for the comparison is the distribution of
     τ_b(A′, A″) and τ_b(B′, B″), pooled: how far two noisy copies of the
     *same* condition agree.
   - The **noise interval** of the comparison is the 2.5-97.5 percentiles of
     τ_b(A′, B′).
   - Computed only where δ applies; s_e is the class's.
7. **Intervals over configurations, where a statement pools them.**
   - "Synchronised against drifting, τ +0.72 to +1.00" (8 configurations):
     the median τ_b, with a bootstrap over the configurations (10,000
     resamples, the same seed).
   - A6's median over matched pairs and over size controls, likewise.

**The statements restated:**
- P11 (4): canneal 4c / 8c × fixed / 2 MB a core, shared against private.
- The size controls (6): canneal 4c, 8c and ocean 4c, private and shared,
  fixed against 2 MB a core.
- P13 (2): ocean 4c, shared against private, at both sizes.
- P14 (1): 64 against 16 MSHRs.
- P12 (2): the best gain over LRU, shared against private, at canneal 4c and
  8c fixed. Restated as robust if ln(1 + g_shared) − ln(1 + g_private) > δ.
- Synchronised against drifting (8).
- A6: every matched pair and size control at 4c and 8c, by `a6_score.py`'s
  lists (τ_b, exact p, the bootstrap of the medians).
- C0 (6): L = 20, 50, 100 against L = 0, at canneal 4c, 8c and ocean 4c
  (τ_b and exact p).
- COALESCE's place at canneal 8c and 16c, fixed, shared.

**Readings, fixed now:**
- **R1.** "COALESCE is 1st at canneal 8c fixed 2 MB shared" is written only
  if its gap to the 2nd ≥ δ_fixed **and** its sign holds in all 5 windows.
  Otherwise the paper says "tied for first with …", naming every policy
  within δ_fixed. At 16c (no windows) the δ rule alone decides.
- **R2.** Each cross-condition τ (P11, the size controls, P13, synchronised
  against drifting) is labelled:
  - **WITHIN NOISE** if τ_b ≥ the 5th percentile of its ceiling;
  - **BELOW THE NOISE CEILING** otherwise: a reordering beyond window noise,
    reported with the size control beside it, as step 5 did.
- **R3.** A τ whose exact p ≥ 0.05 is never called agreement beyond chance.
  The paper quotes every τ as τ_b with its exact p.
- **R4.** P11's explanation ("at 2 MB a core any change reorders them") is
  supported only if its two 2 MB-a-core P11 comparisons read WITHIN NOISE
  under δ_scaled. Otherwise the sentence is withdrawn and the failure stands
  without that explanation.

## Tools

- `scripts/h3_stats.py`:
  - `noise LOGTOP REFTOP` takes the pulled shifted runs and step 5's pulled
    references, and does the qualification, the parser check, s_e, δ and the
    pair table per class;
  - `score ROWS NOISEFILE` prints every statement above;
  - `selftest` covers hand cases for τ_b with ties, the exact p (9 policies,
    no ties: τ 20/36 gives p 0.0446), the two-way s_e, τ_δ, top-1 under δ
    and the reproducibility of the draws.
- `scripts/h3_server.sh` (`guards`, `list`, `chain`, `status`, `stop
  [runs]`) and `scripts/h3_all.sh` (`go`, `guards`, `status`, `list`,
  `pull`, `stop`). They are modelled on H4's ChampSim driver, with H2's stop
  and relaunch rules.
- Rehearsed against a stand-in server before launch; the launch is on the
  owner's word.

## Cost

32 ChampSim runs at 8 cores. Step 5's canneal 8c took about 11.5 h at
lighter load, so at today's load (80-90 on 48 cores) expect about a day a
run, 8 at a time: 4-5 days, inside 24 Nov. The laptop part takes seconds
(the 9! enumeration is vectorised).

## Amendment 1 (2026-11-14, while building the scorer; before `score` ran on any row and before any shifted run exists)

1. **P12's threshold is √2·δ, not δ.** P12 restates the difference
   ln(1 + g_shared) − ln(1 + g_private). Each term is one pair gap (ln LRU
   − ln best), so their difference has standard deviation 2·s_e, √2 times
   a pair gap's. It is called robust if the difference exceeds √2·δ.
2. **C0 has 9 comparisons, not 6.** L = 20, 50 and 100 cycles, each against
   L = 0 (`phaseA_l2_fixed`), at canneal 4c, canneal 8c and ocean 4c, shared,
   over the 8 baselines.
3. **The reference runs (W = 50 M) are qualified on their logs only.**
   Step 5's checks C1-C7 (`policy_results_2026-11-10.md`) already fixed their
   binary and config files, and the step 5 runs have no `config.json`
   beside them. Their ROI max cycles must equal `phasea_rows_v29.txt`; on
   the pulled logs all 8 do (the parser check, run on the references alone;
   the shifted runs do not exist yet).
4. **A6.** Every matched pair is restated, including those A6 did not count
   for pressure, which are printed as such. The median over matched pairs
   uses only the counted ones, as A6 did.
5. **The noise file** `h3_stats.py noise` writes is committed as
   `bench/policy_sanity/h3_noise_v1.txt`, and `score` reads it.

## Build record (2026-11-14, before any launch)

- **Read on the server (read-only):**
  - the g6 binary's md5 is `1e3060c1760b4b3b18e5728a9dfb75ed`;
  - `~/sync_pol` holds `BIN` (the g6 path), `cfg/` and `JOBS` (171);
  - `sync_mx/canneal8` has its `DONE` (tracer 7e3269fd) and `raw1-8.mix`,
    each with a `T` line of 215,000,308 records (215,000,000 instructions
    and 308 sync records).
  - In step 5's canneal 8c LRU log, every core's ROI position ends within
    about 1 M of 150 M. So W = 55 M ends near 156 M, inside the 160 M guard
    and the 215 M traces.
- **Built:**
  - `scripts/h3_stats.py` (`noise`, `score`, `selftest`):
    - the self-test covers τ_b (with and without ties, against brute force);
    - the exact p: 0.0446 at τ 20/36 and 2 × 0.179 at 10/36 (the report's
      values), 2/9! for identical orders, and a brute-force 6! with ties;
    - s_e of an additive table and of one perturbed cell (h/√(rc));
    - τ_δ, top-1 and top-3 on hand cases;
    - reproducible draws, the qualification of a made-up log and 8 faults
      in it.
  - `scripts/h3_server.sh` (`guards`, `list`, `chain`, `status`, `stop
    [runs]`; one driver, PAR 8, the fixed class first, H2's stop and
    relaunch rules) and `scripts/h3_all.sh` (`go`, `guards`, `status`,
    `list`, `pull`, `stop`). `go` requires everything committed, this record
    and a passing self-test.
- **Checked on the real pulled files:**
  - The parser reproduces `phasea_rows_v29.txt`'s `max_cyc` for all 8 W =
    50 M references, and all 8 qualify.
  - On the committed rows, `score`'s τ_b equals the τ each statement was
    scored with: P11 +0.78 / +0.33 / +0.50 / +0.28; A6's medians +0.571 /
    +0.286; C0's +1.00 / +0.93.
  - With δ from the rehearsal's stand-in noise, `score` runs end to end,
    with both classes, with the fixed class undeclared and with no noise
    file. Those tie-rule lines and readings come from stand-in values and
    are not results.
- **Rehearsed against a stand-in server.** The fake home held step 5's real
  reference logs and configs, stand-in traces with the real counts, and a
  stand-in g6 that writes the reference log with the new warmup and
  window-shifted cycles.
  - The guards pass on the clean home. Six injected faults are each refused
    by their own FAIL line alone, and `chain` then starts nothing: the
    binary's md5, a short trace, the traces without `DONE`, an incomplete
    reference, a reference on other traces, a config of another policy.
  - `stop runs` with 8 runs in flight leaves no process and no driver; the
    next chain redoes all 32.
  - With an injected wrapped trace (fixed, 47.5 M, srrip) and an abort
    (scaled, 55 M, ship): 31 complete and 1 FAILED; a relaunch skips the
    FAILED one until its mark is cleared, then completes it (32 of 32).
  - `noise` on the "pulled" runs (trace paths mapped back to the server's):
    - the wrapped run is NOT USED, the fixed class is NOT DECLARED (exit
      2), and the scaled class is declared;
    - clean, both classes are declared, δ equals the hand value (2.1788 ×
      √2 × 0.000165417 = 0.000510), and each pair's signs over the five
      windows are printed.
- **Defects found and fixed:**
  1. The exact p printed `0.0000` for τ = 1 over 8 (2/8! = 4.96e-05); it now
     prints 3 significant digits.
  2. R4 was left to the reader; `score` now decides it from the two P11
     labels at 2 MB a core.
  3. Rehearsal only: the fake `HOME` hid the laptop's user-installed numpy;
     the scorer ran with the real one.
- **Launch (owner's word, "start the H's in that order"):** `bash
  scripts/h3_all.sh go`; then `status`.
- **Scoring, once 32 of 32 have ended:**
  - `bash scripts/h3_all.sh pull`;
  - `python3 scripts/h3_stats.py noise simulator/results/h3/logs
    simulator/results/policy/logs simulator/results/policy/sync_pol/cfg >
    bench/policy_sanity/h3_noise_v1.txt`;
  - `python3 scripts/h3_stats.py score bench/policy_sanity/phasea_rows_v29.txt
    bench/policy_sanity/h3_noise_v1.txt`.

**Launch record (2026-11-14, server time).** 12:03 `bash scripts/h3_all.sh
go` (`d2a9fc1`): every guard passes on the server, the driver started, and 8
runs (the fixed class at W = 45 and 47.5 M) are alive. Load is about 98 on 48
cores, with H1, H2, H4 / H5, Part B's F-C reruns and Part A also running.
