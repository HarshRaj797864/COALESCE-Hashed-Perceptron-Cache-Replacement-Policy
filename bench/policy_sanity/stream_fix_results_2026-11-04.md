# Step 4's same-stream failures: the streamfix verdict. Scored 2026-11-04

Design: `stream_fix_design_2026-11-02.md` (pre-registered `8b483bc`;
amendment 1 `60c60bb`; amendment 2 `5f27db9`). Check code: `stream_check2.py`
as committed in `4bb8243`, before any counter run, and unchanged since apart
from amendment 2's report-only `unlisted` field.

Inputs: `stream_v2_rows_v1.txt` (from `stream_check2.py rows
simulator/results/streamfix`, pulled 2026-11-04 11:04 server time),
`gem5_percpu_v1.txt`, `gem5_mix_v4.txt` and `trace_mix_v4.txt`. Command:
`stream_check2.py check` on those four files.

**No ChampSim ratio of fft, streamcluster, volrend or lunc has been read**,
before or after this scoring. lunc's counter rows are in the rows file. By
amendment 1 it is not in `check`, and its v2 has not been printed.

## The run

- Round 2, via `streamfix_server.sh redo`. Counter md5 `cb5902c7...`, the
  same as round 1, so the 14 host runs stand.
- **exact:** 8 of 8 hand counts met, and the counter equals the tracer on
  thread 1.
- **CPUID:** gem5 was dumped leaf by leaf. It answered 354 lines and aborted
  on 14 pairs (0xd/2-f), as amendment 2 expected. The whole dump's 210 lines
  equal the leaf-by-leaf ones. The extended leaves equal those read from
  gem5's source.
- **Runs:** 31 counter runs, all exit 0. lunc's 2 of them came through
  `more`.

## Qualifying checks

- **QE HOLDS.**
  - The dump under the emulation prints gem5's 354 lines exactly. Its other
    14 pairs are the 14 gem5 aborts on. "CPUID replaced 401, unlisted 0".
  - No AVX, EVEX or FMA library routine runs in any gem5-CPUID run.
  - Every gem5-CPUID run reports `unlisted 0`.
- **QC: holds on 14 of 15 windows. It FAILS on volrend** (stores 39.007
  trace against 39.439 counter, +1.1%; RMWs 0.933 against 0.947, +1.5% and
  +0.014 per 1,000). The design named volrend as the expected candidate
  (a work queue).
  - Every other window agrees within 0.11% on loads and stores: ocean,
    canneal, canneal 8, barnes-256, barnes std's three spans, radix,
    water-nsquared, fmm, fft, lu, raytrace and streamcluster.
  - The worst RMW miss among them is barnes std start, 0.064 per 1,000.
    That is a 0.5% difference, so it passes.
- **QA: holds on every program with thread 0 cut:** barnes std, fft, fmm,
  lu, raytrace, volrend and water-nsquared, the largest deviation 0.007%.
  lunc has no trace yet, so its "FAILS" line is a missing input, not a
  miss.

## Predictions

| | verdict | numbers |
|---|---|---|
| **S0** v2 keeps what v1 passed | **HOLDS** | All 11 v1-passing windows pass v2 (host CPUID). barnes-256's stores read 1.022 (v1: 1.058). fmm still fails: RMWs 1.369. |
| **S1** fft is units (H1) | **HOLDS** | fft workers t1-t3, gem5/trace: loads 1.001 / 1.000 / 1.001, stores the same. v1 read about 2x. |
| **S2** fft's thread 0 is libm (H2) | **FAILS** | Δ host +99.21 M (needed 99 ± 2: met). Δ gem5 CPUID **−16.72 M (needed within ±5 M: missed)**. Of the change in serial start between the two CPUIDs (115.93 M), libm makes 100% (needed 80%: met). |
| **S3** streamcluster is libc's REP strings (H2) | **HOLDS** | Host CPUID, threads 2-4: write micro-ops trace/gem5 1.492 (needed > 1.05). libc REP iterations make 120% of the excess (needed 60%). gem5 CPUID: v2 holds, every worker within 5%. |
| **S4** volrend's RMW gap is run-to-run (H3) | see F3 | Three gem5-CPUID runs: 0.957, 0.946, 0.946 per 1,000; widened [0.899, 1.005]; gem5 0.995, inside. |

**What S2's failure says.** The mechanism is libm, as predicted: all of the
difference between the two CPUIDs is in libm. But the dynamic binary under
gem5's CPUID runs 16.7 M more instructions before its last `pthread_create`
than gem5's static binary does. The emulation therefore moves thread 0 too
far. The cause is not established. One candidate is the static and dynamic
libm choosing different routines, but that is not tested. **By the design,
H2 is wrong for fft:** "the program stays unscored and is reported with what
the counter shows."

## What follows, read strictly

The check prints F1 not adopted, F2 no and F3 YES. Two of these lines need
the design's text read beside the code. **Where text and code differ, the
reading that adopts less is taken.**

- **F1 (v2 replaces v1): NOT ADOPTED.**
  - The design reads "if QC holds and S0 and S1 hold". The committed check
    reads it as QC on every program, and volrend fails QC.
  - A per-program reading would adopt v2, because volrend is in neither S0
    nor S1. It is not taken: the committed code is the operational form of
    the pre-registration.
  - **v1 stays the check in force for step 4's programs.**
  - Effect now: none on any score. The only program v2 would admit is fft,
    and fft has 0 gem5 sharing events (`newbench_results_2026-11-01.md`), so
    it cannot discriminate.
- **F2 (traces with gem5's CPUID): NO**, because S2 fails.
  - By amendment 1, **the nc traces are moved aside and no ratio of their
    runs is read** (none had been made: 0 of 6 runs).
  - **fft, streamcluster and volrend stay unscored.** lu and raytrace keep
    their host traces and v1 verdicts (pass; not discriminating).
  - **LU non-contiguous** is traced with the host's CPUID (`VARIANT=nb`) and
    checked by v1, as amendment 1 states for F2 not holding.
- **F3 (the native range for RMWs): NOT RELIED ON.**
  - The check prints YES, because its code scores S4 without QC.
  - The design's text says a program that fails QC "is reported and its
    predictions are not scored". volrend fails QC.
  - Effect now: none. F3 would act only through `ncheck`, which needs F2, or
    through volrend's host trace, which needs three host-CPUID runs (two
    exist).
- **The earlier B3 programs' traces stand.** F2 does not hold. Even if it
  had, every rate differs by under 2% between the two CPUIDs: ocean at most
  1.37%, barnes std start 1.50%, every other one 0.56% or less. **Step 5's
  gate (amendment 1, item 4 of `policy_rerun_design`) is therefore met.**

## What it means for the tool

- **Diagnosed:**
  - **gem5 counts memory micro-ops, not instructions.** H1 is confirmed
    exactly on fft. S0 shows v2 keeps every v1 verdict.
  - **The host's glibc chooses string routines that gem5's CPU would not
    use.** H2 is confirmed on streamcluster. Tracing under gem5's CPUID
    removes the gap.
  - **fft's serial start is libm.** The mechanism is confirmed, but the
    emulation does not land on gem5's position.
- **Not adopted for step 4's programs,** by the rules written before the
  data: v2, gem5-CPUID traces and the native-range rule. Step 4 still gives
  no discriminating held-out program.
- **Two things stay usable for programs whose numbers do not yet exist:** v2
  as a check, and tracing under gem5's CPUID. Each must be pre-registered
  again before such a program is traced. The owner's decision of
  2026-11-04, two more held-out programs with real sharing, is where that
  happens.
