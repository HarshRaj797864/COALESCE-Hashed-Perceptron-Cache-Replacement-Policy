# Held-out set 2: scored. 2026-11-06

Pull of 2026-11-06 05:47 server time (`phasea_rows_v27.txt`,
`b3_rows_v18.txt`) and the 24 counter runs (`heldout2_all.sh pullcount`).

- Pre-registration: `heldout2_design_2026-11-04.md`. The design is `f8e3abd`
  and Notes 1-8. Note 8 (`3e0d2c6`) fixes the checks and the score. Its
  amendment 1 (`061027a`) fixes a row-maker defect and was committed before
  `score` ran.
- Binary `champsim_g6_1e3060c1`, level 2, mutex order by timing.
- Primary measure R_g5 (owner, 2026-10-27).

Nothing was tuned. Before this scoring no rate of these programs had been
read.

## In one line

**Set 2's target is met: two counted programs, fluidanimate and vips, pass
every check and discriminate. But ChampSim does not agree with gem5 on
either: P15 fails on both.**

- **fluidanimate:** R_g5 0.398.
- **vips:** R_g5 0.309.
- Both are below the 0.5-2 band. ChampSim sees 2.5-3x fewer store misses
  that find another core than gem5 does.
- On both, traffic agrees (P17) and R_b ≥ R_g5 (P16).
- **Ocean non-contiguous, reported apart, agrees:** R_g5 0.663, with P16 and
  P17 holding.
- **Not scored:** bodytrack fails QW, as expected beforehand. facesim fails
  the 500-event rule: gem5 counts 1 event.
- **streamcluster is pending:** its trace and run were still in progress.

## The verdicts

| program | role | checks | R_g5 (P15) | R_b ≥ R_g5 (P16) | traffic (P17) | gem5 events |
|---|---|---|---|---|---|---|
| fluidanimate | counted | all hold | **0.398, fails** | 0.538, holds | 0.769, holds | 43,879 |
| bodytrack | counted | **QW fails** (3.933% > 1%) | not scored | | | 26,542 |
| facesim | counted | **500 fails** (1 event) | not scored | | | 1 |
| vips | counted | all hold | **0.309, fails** | 0.309, holds | 0.947, holds | 3,242 |
| ocean non-contiguous | apart, never counted | all hold | 0.663, holds | 1.094, holds | 0.983, holds | 30,667 |
| streamcluster | step 4 program | pending (no ChampSim run log yet) | | | | 2,245 |

**Arithmetic check (R_g5 = ChampSim's gem5-rule events per 1,000 instructions,
over gem5's):**
- fluidanimate (18,681 / 412.47 M) / (43,879 / 386.01 M) = 0.0453 / 0.1137 = 0.398
- vips (1,032 / 411.13 M) / (3,242 / 398.70 M) = 0.0025 / 0.0081 = 0.309
- ocean non-contiguous (20,364 / 400.26 M) / (30,667 / 399.77 M) = 0.0509 / 0.0767 = 0.663

## Expected beforehand, both as stated (Note 8; neither was a prediction)

- **bodytrack fails QW.** Its untraced CPUs commit 3.933% of the traced
  CPUs' window instructions. Nearly all of it is CPU 0, at 15.71 M. Native
  sizing gave 3.4-4.0%.
- **facesim's run reports 1 release of a mutex not held** (Note 4).

## The checks, briefly

- **QB, QT, Q3 and QG hold on all five.**
  - Q3: every view-order violation is explained by silent re-listing
    (fluidanimate 4, bodytrack 10, facesim 119; vips and ocean
    non-contiguous 0).
  - QG: every run used the static binary, 2 MB, randomization false, and
    Note 3's stop on the traced CPUs.
- **QC and v2 hold on all five.** These are the same-stream checks, with the
  native range from three gem5-CPUID counter runs.
  - The trace and the counter agree within 0.3% on loads and stores for
    every program (the largest gap: fluidanimate's stores, 0.26%).
  - On fluidanimate and facesim the three counter runs gave equal counts:
    lo = hi.
- **QW holds** except on bodytrack (above).
- **500:** fluidanimate 43,879, vips 3,242, ocean non-contiguous 30,667,
  bodytrack 26,542, facesim 1. streamcluster 2,245 (as in step 4).

## What it means

- **Held-out set 2's target is met, and the held-out test fails on the
  programs that met it.**
  - The paper may not state held-out agreement from set 2.
  - The earlier held-out programs are unchanged by this result:
    - set 1: radix agrees under the gem5-rule view (R_g5 0.990);
      water-nsquared does not discriminate; fmm is unscored;
    - step 4: lunc agrees (R_g5 1.831).
  - So among the held-out programs that discriminate and are scored:
    - radix and lunc agree;
    - ocean non-contiguous agrees, but it is reported apart (a layout of a
      development program);
    - fluidanimate and vips do not.
- **The miss is in one direction:** ChampSim lists fewer cores at a store
  miss than gem5 does.
  - It is not the protocol rule alone. On vips every view reads about 0.31
    (R_b, R_bounded, R_g5).
  - On fluidanimate, the protocol view is in the band (0.538), while the
    gem5-rule and bounded views are not (0.398 / 0.399).
  - Traffic agrees on both, so the two streams are not far apart in volume.
- **Upgrades:**
  - fluidanimate: U_g5 0.890, in the band;
  - vips: gem5 has 509 upgrades, below b3_score's 10,000, so U is not
    scored;
  - ocean non-contiguous: U_g5 0.973.
  - Hand-overs: fluidanimate 0.670, vips 0.377, ocean non-contiguous 1.186.
- **Not diagnosed.** By the owner's rule (2026-11-05) the failure is
  diagnosed, not tuned, and the diagnosis is pre-registered before it runs.
  - One candidate, untested: in both failing programs the main thread runs
    on a gem5 CPU that ChampSim does not model (fluidanimate CPU 0; vips
    CPUs 0-2).
  - It is idle in the window, but its caches may still hold lines it wrote
    during set-up. A worker's store miss that finds them counts in gem5 and
    cannot in ChampSim.
  - The two programs that agree (lunc, ocean non-contiguous) trace thread 0
    themselves, or have no untraced CPU.
  - gem5's statistics may already separate these events by the CPU that held
    the line. That is to be checked in the diagnosis note, not here.

## streamcluster, and a correction to amendment 1

- The pull ran while streamcluster was being traced, so its set held only
  `LEN` and `pin.err`.
- Amendment 1 expected its line to read "not scored (QT ...)". **It reads
  "pending: no ChampSim run log yet".** `check_program` tests for a missing
  run log before the checks decide, and pending wins.
  - Its QT and QC lines print FAILS and "not checked". They describe a trace
    still being made, not a verdict.
- It is scored by the same command on new row files once its trace and run
  exist.
- Its counter runs and gem5 lines are as in step 4: v2's rates at a point
  reproduce Note 8's test (284.295 against 284.315, 2.878 against 2.806,
  0.005).

## Commands

```bash
scripts/heldout2_all.sh sc                    # 2026-11-06 05:45 server time (owner's word); streamcluster tracing
scripts/pull_results.sh                       # rows v27, b3 v18; set 2's reports, run logs, sizing, chain log
scripts/heldout2_all.sh pullcount             # 24 of 24 exited 0
python3 scripts/heldout2_score.py tracerows simulator/results/heldout2/traces simulator/results/heldout2/server simulator/results/newbench/server > bench/policy_sanity/h2_trace_rows_v1.txt
python3 scripts/heldout2_score.py countrows simulator/results/heldout2/count > bench/policy_sanity/h2_count_rows_v1.txt     # after amendment 1
python3 scripts/heldout2_score.py runrows simulator/results/heldout2/logs simulator/results/heldout2/driver.log > bench/policy_sanity/h2_run_rows_v1.txt
python3 scripts/heldout2_score.py gem5cfg simulator/results/gem5_b3 > bench/policy_sanity/h2_gem5_config_v1.txt
python3 scripts/stream_check2.py gem5rows simulator/results/gem5_b3 > bench/policy_sanity/gem5_percpu_v2.txt
python3 scripts/b3_stream_check.py extract simulator/results/gem5_b3 > bench/policy_sanity/gem5_mix_v6.txt
python3 scripts/b3_score.py gem5-rows > bench/policy_sanity/gem5_b3_rows_v6.txt
python3 scripts/heldout2_score.py score bench/policy_sanity/h2_trace_rows_v1.txt bench/policy_sanity/h2_count_rows_v1.txt \
  bench/policy_sanity/h2_run_rows_v1.txt bench/policy_sanity/h2_gem5_config_v1.txt bench/policy_sanity/gem5_percpu_v2.txt \
  bench/policy_sanity/gem5_mix_v6.txt bench/policy_sanity/gem5_b3_rows_v6.txt bench/policy_sanity/phasea_rows_v27.txt bench/policy_sanity/b3_rows_v18.txt
```

**Note 8's gate before `score` holds:**
- `gem5_b3_rows_v6` holds all 38 v5 rows unchanged, plus the 10 set-2 runs.
- `gem5_mix_v6` holds all 39 v5 rows, plus 10.
- `gem5_percpu_v2` holds all 163 v1 rows, plus 60: set 2's 52 CPU lines and
  lunc's 8, whose runs postdate v1.

## Not read

- **Step 5's rows:** 39 of 171 complete in `phasea_rows_v27.txt`. Step 5 is
  scored when it completes.
- **Step 4's fft and volrend blocks.**

## The output of `score`, whole

```
== Held-out set 2 and streamcluster: the checks (heldout2_design_2026-11-04.md, Note 8)
   counter LOG 2026-11-05 07:29:25 QE-h2 holds: 354 lines equal, the 14 other pairs the dump asked are the 14 gem5 aborts on; CPUID replaced 401 unlisted 0
   counter LOG 2026-11-05 07:41:42 COUNT DONE: 24 of 24 exited 0 with the options, bases and thread files Note 7 names
   counter markers: {'done': 'yes', 'counter_md5': '22776143da830acac58082ebc8f2eede'}

== fluidanimate (held-out set 2, counted); traced threads 1,2,3,4
   QB    holds: SIZED (written only after QB held)
   QT    holds: tracer f39707f3, CPUID 74d72229, length rule applied (LEN 215000000); instructions t1 215.0 M, t2 215.0 M, t3 215.0 M, t4 215.0 M
   Q3    holds (view-order raw 4 = by silent re-listing 4; releases of a mutex not held 0, reported)
   QG    holds: 5 CPUs, /home/harshraj/heldout2_static/fluidanimate, L2 2 MB, randomization false, stop on CPUs 1,2,3,4
   QW    holds: untraced CPUs 0 commit 0.000% of the traced CPUs' 386.0 M window instructions (under 1% needed); per CPU 0:0.00M 1:93.71M 2:98.21M 3:94.09M 4:100.00M
   QC    holds: per 1,000 records, the trace in the three gem5-CPUID runs' range (widened 1%; RMWs or 0.01): loads 227.956 in [228.453, 228.453]; stores 36.401 in [36.495, 36.495]; RMWs 3.168 in [3.185, 3.185]; host run 228.453, 36.495, 3.185
   v2    holds: per 1,000 instructions (gem5 units), gem5 in the three counter runs' range (widened 5%; RMWs or 0.05): loads 226.056 in [228.465, 228.465]; stores 37.001 in [36.495, 36.495]; RMWs 3.234 in [3.185, 3.185]
          t1 (counter gem5 1 / gem5 CPU 1, reported): loads 229.108 / 225.271, stores 35.082 / 35.822; instructions 100.00 M / 93.71 M
          t2 (counter gem5 1 / gem5 CPU 2, reported): loads 227.710 / 225.969, stores 37.180 / 37.178; instructions 100.00 M / 98.21 M
          t3 (counter gem5 1 / gem5 CPU 3, reported): loads 229.955 / 226.394, stores 36.092 / 36.939; instructions 100.00 M / 94.09 M
          t4 (counter gem5 1 / gem5 CPU 4, reported): loads 227.089 / 226.557, stores 37.625 / 37.989; instructions 100.00 M / 100.00 M
   500   holds: gem5 counts 43879 store misses that find another core in the window (SS + MT L1_GETX; at least 500)
   -> SCORED

== bodytrack (held-out set 2, counted); traced threads 1,2,3,4
   QB    holds: SIZED (written only after QB held)
   QT    holds: tracer f39707f3, CPUID 74d72229, length rule applied (LEN 215000000); instructions t1 215.0 M, t2 215.0 M, t3 215.0 M, t4 215.0 M
   Q3    holds (view-order raw 10 = by silent re-listing 10; releases of a mutex not held 0, reported)
   QG    holds: 6 CPUs, /home/harshraj/heldout2_static/bodytrack, L2 2 MB, randomization false, stop on CPUs 1,2,3,4
   QW    FAILS: untraced CPUs 0,5 commit 3.933% of the traced CPUs' 399.4 M window instructions (under 1% needed); per CPU 0:15.71M 1:100.00M 2:99.52M 3:99.92M 4:99.98M 5:0.00M
   QC    holds: per 1,000 records, the trace in the three gem5-CPUID runs' range (widened 1%; RMWs or 0.01): loads 196.369 in [196.417, 196.844]; stores 48.978 in [48.894, 49.152]; RMWs 22.090 in [21.944, 22.147]; host run 196.893, 48.903, 22.344
   v2    holds: per 1,000 instructions (gem5 units), gem5 in the three counter runs' range (widened 5%; RMWs or 0.05): loads 202.099 in [201.975, 202.465]; stores 52.848 in [53.026, 53.217]; RMWs 21.099 in [21.944, 22.147]
          t1 (counter gem5 1 / gem5 CPU 1, reported): loads 202.717 / 202.476, stores 51.675 / 53.288; instructions 100.00 M / 100.00 M
          t2 (counter gem5 1 / gem5 CPU 2, reported): loads 201.940 / 202.022, stores 55.391 / 52.853; instructions 100.00 M / 99.52 M
          t3 (counter gem5 1 / gem5 CPU 3, reported): loads 201.880 / 201.953, stores 55.330 / 52.611; instructions 100.00 M / 99.92 M
          t4 (counter gem5 1 / gem5 CPU 4, reported): loads 203.323 / 201.944, stores 49.708 / 52.642; instructions 100.00 M / 99.98 M
   500   holds: gem5 counts 26542 store misses that find another core in the window (SS + MT L1_GETX; at least 500)
   -> NOT SCORED: fails QW

== facesim (held-out set 2, counted); traced threads 0,1,2,3
   QB    holds: SIZED (written only after QB held)
   QT    holds: tracer 02ff8f48, CPUID 74d72229, length rule applied (LEN 215000000); instructions t0 215.0 M, t1 215.0 M, t2 215.0 M, t3 215.0 M
   Q3    holds (view-order raw 119 = by silent re-listing 119; releases of a mutex not held 1, reported)
   QG    holds: 4 CPUs, /home/harshraj/heldout2_static/facesim, L2 2 MB, randomization false, stop on CPUs 1,2,3
   QW    holds: untraced CPUs none commit 0.000% of the traced CPUs' 399.8 M window instructions (under 1% needed); per CPU 0:99.98M 1:100.01M 2:99.84M 3:99.98M
   QC    holds: per 1,000 records, the trace in the three gem5-CPUID runs' range (widened 1%; RMWs or 0.01): loads 260.993 in [260.993, 260.993]; stores 113.710 in [113.710, 113.710]; RMWs 1.226 in [1.226, 1.226]; host run 264.268, 115.140, 1.241
   v2    holds: per 1,000 instructions (gem5 units), gem5 in the three counter runs' range (widened 5%; RMWs or 0.05): loads 287.756 in [287.516, 287.516]; stores 140.397 in [140.226, 140.226]; RMWs 1.227 in [1.226, 1.226]
          t0 (counter gem5 1 / gem5 CPU 0, reported): loads 288.031 / 288.275, stores 140.588 / 140.762; instructions 100.00 M / 99.98 M
          t1 (counter gem5 1 / gem5 CPU 1, reported): loads 288.266 / 288.516, stores 140.859 / 141.038; instructions 100.00 M / 100.01 M
          t2 (counter gem5 1 / gem5 CPU 2, reported): loads 286.309 / 286.537, stores 139.081 / 139.242; instructions 100.00 M / 99.84 M
          t3 (counter gem5 1 / gem5 CPU 3, reported): loads 287.456 / 287.693, stores 140.376 / 140.542; instructions 100.00 M / 99.98 M
   500   FAILS: gem5 counts 1 store misses that find another core in the window (SS + MT L1_GETX; at least 500)
   -> NOT SCORED: fails 500

== vips (held-out set 2, counted); traced threads 3,4,5,6
   QB    holds: SIZED (written only after QB held)
   QT    holds: tracer f39707f3, CPUID 74d72229, length rule applied (LEN 215000000); instructions t3 215.0 M, t4 215.0 M, t5 215.0 M, t6 215.0 M
   Q3    holds (view-order raw 0 = by silent re-listing 0; releases of a mutex not held 0, reported)
   QG    holds: 7 CPUs, /home/harshraj/heldout2_static/vips, L2 2 MB, randomization false, stop on CPUs 3,4,5,6
   QW    holds: untraced CPUs 0,1,2 commit 0.006% of the traced CPUs' 398.7 M window instructions (under 1% needed); per CPU 0:0.02M 1:0.00M 2:0.00M 3:99.61M 4:99.96M 5:99.09M 6:100.03M
   QC    holds: per 1,000 records, the trace in the three gem5-CPUID runs' range (widened 1%; RMWs or 0.01): loads 189.336 in [189.320, 189.445]; stores 54.696 in [54.711, 54.758]; RMWs 0.217 in [0.217, 0.218]; host run 189.728, 54.537, 0.218
   v2    holds: per 1,000 instructions (gem5 units), gem5 in the three counter runs' range (widened 5%; RMWs or 0.05): loads 188.979 in [189.390, 189.526]; stores 55.008 in [54.808, 54.870]; RMWs 0.220 in [0.217, 0.218]
          t3 (counter gem5 1 / gem5 CPU 3, reported): loads 189.289 / 189.029, stores 54.759 / 54.879; instructions 100.00 M / 99.61 M
          t4 (counter gem5 1 / gem5 CPU 4, reported): loads 189.458 / 188.928, stores 54.943 / 55.042; instructions 100.00 M / 99.96 M
          t5 (counter gem5 1 / gem5 CPU 5, reported): loads 189.437 / 189.049, stores 54.771 / 55.025; instructions 100.00 M / 99.09 M
          t6 (counter gem5 1 / gem5 CPU 6, reported): loads 189.375 / 188.913, stores 54.760 / 55.087; instructions 100.00 M / 100.03 M
   500   holds: gem5 counts 3242 store misses that find another core in the window (SS + MT L1_GETX; at least 500)
   -> SCORED

== oceannc (reported apart, never counted); traced threads 0,1,2,3
   QB    holds: SIZED (written only after QB held)
   QT    holds: tracer f39707f3, CPUID 74d72229, length rule applied (LEN 215000000); instructions t0 215.0 M, t1 215.0 M, t2 215.0 M, t3 215.0 M
   Q3    holds (view-order raw 0 = by silent re-listing 0; releases of a mutex not held 0, reported)
   QG    holds: 4 CPUs, /home/harshraj/heldout2_static/OCEAN-NC, L2 2 MB, randomization false, stop on CPUs 1,2,3
   QW    holds: untraced CPUs none commit 0.000% of the traced CPUs' 399.8 M window instructions (under 1% needed); per CPU 0:99.88M 1:99.94M 2:99.95M 3:100.00M
   QC    holds: per 1,000 records, the trace in the three gem5-CPUID runs' range (widened 1%; RMWs or 0.01): loads 322.997 in [322.991, 322.992]; stores 56.537 in [56.562, 56.580]; RMWs 0.048 in [0.046, 0.046]; host run 323.213, 56.294, 0.046
   v2    holds: per 1,000 instructions (gem5 units), gem5 in the three counter runs' range (widened 5%; RMWs or 0.05): loads 323.169 in [322.998, 322.999]; stores 57.895 in [57.926, 57.944]; RMWs 0.050 in [0.046, 0.046]
          t0 (counter gem5 1 / gem5 CPU 0, reported): loads 322.800 / 323.140, stores 57.308 / 57.948; instructions 100.00 M / 99.88 M
          t1 (counter gem5 1 / gem5 CPU 1, reported): loads 322.887 / 323.203, stores 58.442 / 57.917; instructions 100.00 M / 99.94 M
          t2 (counter gem5 1 / gem5 CPU 2, reported): loads 323.080 / 323.126, stores 58.163 / 57.882; instructions 100.00 M / 99.95 M
          t3 (counter gem5 1 / gem5 CPU 3, reported): loads 323.231 / 323.208, stores 57.791 / 57.832; instructions 100.00 M / 100.00 M
   500   holds: gem5 counts 30667 store misses that find another core in the window (SS + MT L1_GETX; at least 500)
   -> SCORED

== streamcluster (step 4 program, scored by set 2's procedure (newbench amendment 3)); traced threads 1,2,3,4
   QB    holds: step 4 sizing (CHOSEN; QB held then)
   QT    FAILS: DONE - is not the tracer f39707f3; CPUID -; t1 MISSING; t2 MISSING; t3 MISSING; t4 MISSING: tracer -, CPUID -, length rule applied (LEN 215000000); instructions 
   Q3    FAILS: no run log; no rows
   QG    holds: 5 CPUs, /home/harshraj/splash-newbench/streamcluster, L2 2 MB, randomization false, stop on CPUs 1,2,3,4
   QW    holds: untraced CPUs 0 commit 0.000% of the traced CPUs' 388.3 M window instructions (under 1% needed); per CPU 0:0.00M 1:100.00M 2:96.11M 3:96.11M 4:96.12M
   QC    FAILS: not checked (the three gem5-CPUID counter runs or the trace windows are not all usable)
   v2    holds: per 1,000 instructions (gem5 units), gem5 in the three counter runs' range (widened 5%; RMWs or 0.05): loads 284.295 in [284.315, 284.315]; stores 2.878 in [2.806, 2.806]; RMWs 0.005 in [0.005, 0.005]
          t1 (counter gem5 1 / gem5 CPU 1, reported): loads 285.427 / 285.231, stores 7.961 / 7.963; instructions 100.00 M / 100.00 M
          t2 (counter gem5 1 / gem5 CPU 2, reported): loads 283.941 / 283.970, stores 1.087 / 1.113; instructions 100.00 M / 96.11 M
          t3 (counter gem5 1 / gem5 CPU 3, reported): loads 283.944 / 283.970, stores 1.087 / 1.114; instructions 100.00 M / 96.11 M
          t4 (counter gem5 1 / gem5 CPU 4, reported): loads 283.945 / 283.972, stores 1.088 / 1.115; instructions 100.00 M / 96.12 M
   500   holds: gem5 counts 2245 store misses that find another core in the window (SS + MT L1_GETX; at least 500)
   -> PENDING: no ChampSim run log yet (checked again once it exists)

== Verdicts
   fluidanimate  held-out set 2, counted                                                SCORED
   bodytrack     held-out set 2, counted                                                not scored (QW)
   facesim       held-out set 2, counted                                                not scored (500)
   vips          held-out set 2, counted                                                SCORED
   oceannc       reported apart, never counted                                          SCORED
   streamcluster step 4 program, scored by set 2's procedure (newbench amendment 3)     pending: no ChampSim run log yet

== The score, the programs that pass every check only (b3_score.py, h2@set2)
== ChampSim trees phaseA_b3_h2_*  vs gem5 (set2), window 50-150 M, per 1,000 instructions
                     gem5  protocol    R_b    R_a   R_v1 | traffic store-miss  RMW/KI | checks
   fluidanimate 2 MB   0.1137    0.0611  0.538  0.330  0.335 |    0.77     0.8151    1.60 | self-check 0
                 gem5 events 43879 (MT 43679, upgrades 21769), GETX all 235643, window 386005066 instr, per cpu [0, 93706703, 98210855, 94087508, 100000000]; ChampSim protocol 25211, LLC RFO 205241, 412469354 instr
                 level 2; upgrades 21777 (0.0528/KI; gem5 0.0564/KI; U = 0.936), by presence 19847; copies invalidated 63810 (0.1547/KI); stale fills 6351; stale-holders 0
                 hand-overs: ChampSim 46988 (0.1139/KI), gem5 65648 (0.1701/KI), ratio 0.670; demand accesses 1.1478 against 1.4934/KI; with ChampSim's upgrades added 1.2006, ratio 0.804
                 bounded view: R_bounded 0.399 (18711 events, protocol 25211; subset yes); bounded upgrades 20704 (U_bounded = 0.890) -- OUT OF THE BAND
                 gem5-rule view: R_g5 0.398 (18681 events, 18692 cores; at most the bounded view's: yes; view-order violations 4); its upgrades 20693 (U_g5 = 0.890) -- OUT OF THE BAND
                 held-out set 2: P15 R_g5 0.398 FAILS; P16 R_b 0.538 >= R_g5: holds; P17 traffic 0.769 holds  (43879 gem5 events)
   vips 2 MB       0.0081    0.0025  0.309  0.300  0.435 |    0.95     0.9838    0.21 | self-check 0
                 gem5 events 3242 (MT 3233, upgrades 509), GETX all 765841, window 398703787 instr, per cpu [22584, 1596, 0, 99605072, 99955262, 99089189, 100030084]; ChampSim protocol 1032, LLC RFO 776908, 411131895 instr
                 level 2; upgrades 427 (0.0010/KI; gem5 0.0013/KI; U not scored (gem5 has 509)), by presence 424; copies invalidated 1964 (0.0048/KI); stale fills 57; stale-holders 0
                 hand-overs: ChampSim 1459 (0.0035/KI), gem5 3751 (0.0094/KI), ratio 0.377; demand accesses 2.6085 against 2.7537/KI; with ChampSim's upgrades added 2.6096, ratio 0.948
                 bounded view: R_bounded 0.309 (1032 events, protocol 1032; subset yes); bounded upgrades 424 (U_bounded not scored (gem5 has 509)) -- OUT OF THE BAND
                 gem5-rule view: R_g5 0.309 (1032 events, 1032 cores; at most the bounded view's: yes; view-order violations 0); its upgrades 424 (U_g5 not scored (gem5 has 509)) -- OUT OF THE BAND
                 held-out set 2: P15 R_g5 0.309 FAILS; P16 R_b 0.309 >= R_g5: holds; P17 traffic 0.947 holds  (3242 gem5 events)
   oceannc 2 MB    0.0767    0.0839  1.094  0.629  0.645 |    0.98     1.0070    0.04 | self-check 0
                 gem5 events 30667 (MT 30343, upgrades 82892), GETX all 1394644, window 399766801 instr, per cpu [99875511, 99941309, 99949981, 100000000]; ChampSim protocol 33594, LLC RFO 1406158, 400256323 instr
                 level 2; upgrades 101277 (0.2530/KI; gem5 0.2074/KI; U = 1.220), by presence 76808; copies invalidated 169112 (0.4225/KI); stale fills 2399; stale-holders 0
                 hand-overs: ChampSim 134871 (0.3370/KI), gem5 113559 (0.2841/KI), ratio 1.186; demand accesses 20.8994 against 21.2573/KI; with ChampSim's upgrades added 21.1524, ratio 0.995
                 bounded view: R_bounded 0.663 (20364 events, protocol 33594; subset yes); bounded upgrades 80918 (U_bounded = 0.975) -- in the band
                 gem5-rule view: R_g5 0.663 (20364 events, 20380 cores; at most the bounded view's: yes; view-order violations 0); its upgrades 80720 (U_g5 = 0.973) -- in the band
                 ocean non-contiguous (reported apart, never counted): P15 R_g5 0.663 holds; P16 R_b 1.094 >= R_g5: holds; P17 traffic 0.983 holds  (30667 gem5 events)

== The target (two counted programs that pass every check and discriminate): 2 of 4 (fluidanimate, vips) -> MET
   Agreement on them is P15 above; a P15 miss is stated beside it. ocean non-contiguous and streamcluster do not count toward it.
```
