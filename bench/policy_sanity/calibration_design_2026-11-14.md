# H2: the band's noise floor -- design (pre-registered 2026-11-14)

PLAN § 10 item 9, part H2. Written before anything for it is built or run.
No perturbed gem5 run and no re-trace exists yet, so none of their numbers
has been seen.

## Why

The band [0.5, 2] for R_g5 was fixed on 2026-10-04, before any run, without
a measured run-to-run spread. No published band exists for coherence counts
between two simulators (the validation report of 2026-11-14). A reviewer can
ask whether lunc's 1.830 (near the top edge) is in the band by luck, and
whether fluidanimate's 0.400 and vips's 0.308 are out of it by more than the
noise. Alameldeen and Wood (HPCA 2003) answer this kind of question for
multi-threaded simulation by perturbing the timing and re-running; the trace
side of a replay tool has a second source: the native run that was traced is
one interleaving of many.

H2 measures both spreads on four programs, then labels every scored R_g5
against them. **The band does not move, and no verdict is scored again.**

## The four programs

The F-C binary (`champsim_fc_a2e88e46`, adopted 2026-11-14) is the ChampSim
side, as in the paper. The reference values are the F-C reruns of the lock-fix
set (`lock_fix_score_v1.txt`):

| program | why | F-C R_g5 | gem5 runs (under `~/gem5_b3`) | F-C reference tree |
|---|---|---|---|---|
| ocean 4c, 2 MB | development set, barrier-driven | 0.712 | `l2_2MB_mi{50,150}M/ocean_4c` | `phaseA_b3_fc_g3_ocean4` |
| canneal 4c, 2 MB | development set, lock-free | 1.018 | `canneal/l2_2MB_mi{50,150}M/canneal_4c` | `phaseA_b3_fc_g3_canneal4` |
| lunc | held-out, nearest the top edge | 1.830 | `newbench/lunc/l2_2MB_mi{50,150}M/lunc_4c` | `phaseA_b3_fc_n2_lunc4` |
| fluidanimate | held-out, fails (locks) | 0.400 | `heldout2/fluidanimate/l2_2MB_mi{50,150}M/fluidanimate_4c` | `phaseA_b3_fc_h2_fluidanimate4` |

## (a) gem5 perturbed

- The memory controller's `static_backend_latency` set to **8, 9, 11 and 12
  ns** (the scored runs use gem5's default, 10 ns), through se.py's `--param
  "system.mem_ctrls[0].static_backend_latency = '<n>ns'"` (applied before
  instantiation, `Simulation.py:684`, v25.1.0.1). Everything else is the
  original run's: binary, inputs, options, CPU count, cache sizes, the FIFO
  patch, the stop. Each latency at both stops: **32 runs**.
- **This amends PLAN's 9.5 / 9.75 / 10.25 / 10.5 ns.** The scored runs'
  config.ini gives a Ruby clock of 500 ps and a memory-controller clock of
  1,000 ps. A 250 ps shift is half a Ruby cycle and may be absorbed by
  rounding to clock edges. A shift of 1 or 2 ns is 2 to 4 Ruby cycles, and it
  stays inside Alameldeen and Wood's per-miss perturbation of 0-4 ns.
- A fixed shift, not a random one per request: that would need a gem5 rebuild,
  and H2 changes configuration only. So each run mixes a small systematic
  change with the reordering it causes. The values are reported per latency,
  so a trend shows.
- Output: `~/gem5_b3/cal/<program>/b<n>ns/l2_2MB_mi<stop>M/<tag>/`, launched
  through a copy of `run_gem5_splash.sh` in `~/gem5_cal` that gains one
  setting, `GEM5_PARAMS` (extra `--param` statements, one a line; default
  none, so every other launch is unchanged). The live `~/run_gem5_splash.sh`
  and `~/gem5/configs` are not touched. Nice 19, 8 at a time, the 150 M stops
  first, 96 h limit a run.
- **QV0, the same configuration:** each run's `config.ini` equals its
  original's (the same stop) once the original's directory is read as the
  new one, except `static_backend_latency` in `[system.mem_ctrls]`, which
  must read the declared value in picoseconds. Any other difference: the run
  is void and the driver stops launching.
- **QV1, the end:** the run must exit "because a thread reached the max
  instruction count", with one statistics dump. Anything else (a panic, the
  limit) and that latency is "not measured" for that program.
- **The window** is the 150 M stop's statistics minus the 50 M stop's, at
  the same latency, as in every score (`b3_score.py window`; a counter that
  goes backwards means the runs diverged: not measured).
- **Reported, deciding nothing:** whether a perturbed window equals the
  scored one exactly (the perturbation absorbed).

## (b) the trace side

- Each program re-traced **5 times** by its own procedure, through a new
  mode of `sync_server.sh`, `trace1 <program>` (`trace_one`, with no length
  rule; it refuses any trace directory outside `traces/cal/`), uploaded as
  `~/cal/sync_server_cal.sh`. Each re-trace uses the same tracer, CPUID,
  program binary, arguments, inputs, threads, skip, thread-0 cut and length
  as the reference set:
  - ocean and canneal: `VARIANT=mx`, the mx tree's tracer, host CPUID, 215 M
    a thread;
  - lunc: `VARIANT=nb`, the g5 tree's tracer, host CPUID, 310 M a thread,
    thread 0 cut at its anchor;
  - fluidanimate: `VARIANT=h2`, nc's tracer under gem5's CPUID, 215 M a
    thread.
- **Guards, before anything starts:**
  - the tracer's md5 equals the reference set's `DONE`;
  - fluidanimate: the CPUID file's md5 equals the reference's `CPUID`;
  - each program binary is older than its reference set's `DONE`;
  - the F-C binary has md5 `a2e88e46`, with F-C's Q0, Q0m, Q0r and K0 passed;
  - the four F-C reference runs are complete.
- **Checks on a re-trace:** trace_one's own (Pin exits 0; every sync call
  returned; every thread traced; lunc's anchor found), then QT. A re-trace
  that fails is reported and not repeated.
- Into `traces/cal/r<k>/<program>/` (k = 1..5), two programs at a time,
  re-trace 1 of all four first.
- **Each re-trace is replayed on the F-C binary** with the F-C reference's
  config (`~/sync_fc/cfg/<program>.json`) and window (from its log: 50 M +
  100 M), its traces in the reference's thread order, into
  `results/phaseA_b3_cal<k>_<suffix>/regime_shared/<wl>_4core/lru/run.log`
  (suffix ocean4, canneal4, lunc4, fluidanimate4). Nice 19, 4 at a time.
- **A run qualifies** by lock_fix_score's rule against its F-C reference log:
  complete, the request line, level 2, no wrap, self-check 0, stale holders
  0, registered caches, Q3 (unexplained 0), the same lengths and CPU count.
  Its traces must be the r<k> set's, with the same file names in the same
  order. A run that does not qualify is reported, not used.

## The measures, per program

- C_k: ChampSim's gem5-rule RFO events per KI, trace set k ∈ {0 (the F-C
  reference), 1..5}, read as lock_fix_score reads them (its parser check on
  the 14 scored logs comes first).
- G_j: gem5's SS + MT L1_GETX per KI in the window, at latency j ∈ {10 (the
  scored runs, `gem5_b3_rows_v6.txt`), 8, 9, 11, 12}.
- R_kj = C_k / G_j: 30 values, all reported (with their minimum, maximum and
  geometric mean).
- s_c: the sample standard deviation (n - 1) of ln C_k. It needs at least 4
  values (the reference and at least 3 re-traces).
- s_g: the same, of ln G_j. It needs at least 3 values.
- s_p = sqrt(s_c² + s_g²): the spread of one scored ln R (one trace set
  against one pair of gem5 runs; the two sources are independent).
- **s\* = the largest s_p** of the programs where both s_c and s_g are
  measured. If fewer than 2 programs have s_p, s\* is not set and no label
  is given ("not measured").

## The reading, fixed now

For each R_g5 the paper reports, the interval is ln R ± 1.645 s\*. That is
the 90% interval of two one-sided tests at α = 0.05 (equivalence, TOST).

- **ROBUSTLY IN:** the interval lies inside [0.5, 2];
- **ROBUSTLY OUT:** it lies wholly below 0.5 or wholly above 2;
- **NEAR THE EDGE:** otherwise.

The four measured programs also get the interval with their own s_p, beside
the pooled one. The labels are printed for the 14 F-C spans of the lock-fix
set, as `lock_fix_score.py` computes their R. The same formula applies to any
later scored R (streamcluster's F-C rerun, Part B), which the scorer takes as
`label=R`.

**If s\* ≥ 0.4214** (1.645 s\* ≥ ln 2), no R can be robustly in. The paper
then says the band is narrower than the measured noise.

**What the labels need, worked out from the F-C values now** (no prediction
of s\* is made):

| span | R_g5 | label needs s\* below |
|---|---|---|
| lunc | 1.830 | 0.0540 (in) |
| canneal 8c | 1.534 | 0.1613 (in) |
| barnes std force | 0.635 | 0.1453 (in) |
| ocean 2 MB | 0.712 | 0.2149 (in) |
| barnes std start | 0.449 | 0.0654 (out) |
| fluidanimate | 0.400 | 0.1356 (out) |
| vips | 0.308 | 0.2945 (out) |

The paper reports every label, the four programs' tables, s_c, s_g, s_p and
s\*. A label decides nothing about a pre-registered verdict: the verdicts
stand as scored, and the labels say how firm each one is.

## Scorer and runner

- `scripts/cal_score.py` (`qv0`, `qv1` on the server; on the laptop `rows`
  for the pulled gem5 runs, `score`, `selftest`). The selftest covers hand
  cases: the standard deviations, the labels at each edge, the s\* ≥ 0.4214
  case, QV0 passing and failing, a run's trace mapping qualifying or not.
- `scripts/cal_server.sh`:
  - modes `guards`, `list`, `chain` (detached: one driver for gem5, one for
    re-traces and their runs), `status`, `stop [runs]`;
  - state in `~/gem5_cal` and `~/cal`.
- `scripts/cal_all.sh`: `go` (owner's word; upload to `.new`, then `mv`; the
  guards; the chain), and `guards`, `status`, `list`, `pull`, `stop`.
- Rehearsed against a stand-in server before launch. The rehearsal's checks
  are added to this note's build record.

## Cost

- 32 gem5 runs, each about as long as its original. The 50 M stops are about
  a third of that.
- 20 re-traces (minutes each) and about 4 GB of traces.
- 20 ChampSim runs at 4 cores.
- Hours to a few days at today's load (about 64 on 48 cores).

## Build record (2026-11-14, before any launch)

- **Read on the server first (read-only):**
  - The four F-C reference runs (window 50 M + 100 M, `SYNC LOCK WORD:
    request`) and their traces: ocean `sync_mx/ocean4/raw0-3`, canneal
    `sync_mx/canneal4/raw1-4` (both 215 M, tracer 7e3269fd, host CPUID),
    lunc `sync_nb/lunc/raw0_aligned` + `raw1-3` (`LEN` 310000000, tracer
    7e3269fd), fluidanimate `sync_h2/fluidanimate/raw1-4` (`LEN` 215000000,
    tracer f39707f3, `CPUID` 74d72229). Each program binary is older than its
    set's `DONE`. Configs `~/sync_fc/cfg/<p>.json`; `~/sync_fc/BIN` =
    `champsim_fc_a2e88e46`.
  - gem5's clocks in the originals' `config.ini`: Ruby 500 ps, memory
    controller 1,000 ps, `static_backend_latency=10000`. In v25.1 se.py's
    `--param` is executed by `apply_config` with the system's children in
    scope, and `system.mem_ctrls` is a list (`Ruby.py:204`), hence
    `system.mem_ctrls[0]`.
- **Built:**
  - `run_gem5_splash.sh` gains `GEM5_PARAMS` (extra `--param` statements,
    one a line; default empty, so every other launch is unchanged). H2
    uploads its own copy into `~/gem5_cal`; `~/run_gem5_splash.sh` is not
    touched.
  - `sync_server.sh` gains `progline <p>` (read-only) and `trace1 <p>`
    (`VARIANT` mx, nb or h2 only; `TDIR` must be under `traces/cal/` and not
    the variant's own tree; `trace_one`, no length rule). H2 uploads it as
    `~/cal/sync_server_cal.sh`; the live `~/sync_server*.sh` are not touched.
  - `scripts/cal_score.py` (`qv0`, `qv1`, `rows`, `score`, `selftest`):
    self-test 27 of 27. On the committed F-C logs it reproduces
    lock_fix_score's R_g5 (ocean 0.712, canneal 4c 1.018, lunc 1.830). The
    labels of bodytrack and fmm print "not scored" beside them (their checks
    failed before the lock fix), so they are never read as verdicts.
  - `scripts/cal_server.sh` (`guards`, `list`, `chain`, `status`, `stop
    [runs]`, and the two drivers) and `scripts/cal_all.sh` (`go`, `guards`,
    `status`, `list`, `pull`, `stop`).
- **Rehearsed against a stand-in server** (a fake home: a gem5 checkout
  tagged v25.1.0.1 and FIFO-patched; a stand-in `gem5.opt` that writes the
  original's `config.ini` with the `--param` applied; a stand-in F-C binary;
  the real pulled originals and F-C logs; stand-in pthread programs; the
  real tracer built with the laptop's Pin; gem5's CPUID file; lengths 2 M a
  thread, lunc 4 M):
  - the guards pass on the clean home; ten injected faults are each refused
    and nothing starts (tracer md5, CPUID file, a program binary newer than
    its set, an original at 9 ns, the live gem5 tree changed, an F-C config
    without the request line, a length different from the reference's, F-C's
    check marker missing, a missing input, the F-C binary's md5);
  - 8 and 12 ns with re-traces 1-3: every QV0 passes; an injected panic at
    lunc 12 ns is classified OTHER; 12 re-traces under real Pin (lunc cut at
    its anchor, fluidanimate under `-cpuid`) and their 12 replays complete;
    an injected Q3 violation in canneal r2 makes the scorer print NOT USED;
  - the scorer end to end on the pulled rehearsal files: s_g 0.0802 and
    s_c 0.0245, equal to the hand computation;
  - a QV0 failure: the run VOID, the rest NOT RUN; a re-trace whose program
    exits 1: TRACE FAILED, no replay; a relaunch skips everything decided.
  - **Defects found and fixed:**
    1. a relaunch with nothing left to run said the driver had not started;
    2. the fake home lacked BARNES in splash-static (rehearsal only);
    3. `stop runs` left the trace driver's session running (Pin, xz,
       replays): `t_session_alive` piped `awk` into `grep -q` under
       pipefail, so `awk`'s SIGPIPE made the test false (the class of the
       2026-10-28 guard). The match is now made inside `awk`;
    4. a relaunch after `stop runs` would have classified each killed gem5
       run from its partial directory and never launched it again. Now a run
       that ended while no driver ran is classified only if it reached its
       stop; otherwise it is launched again. A failure mark written as the
       stop ended a run is cleared.
  - Re-rehearsed after the fixes: `stop runs` with five gem5 runs and four
    replays in flight leaves nothing running; the relaunch launches the four
    started gem5 runs again (each ends at its stop) and redoes the four
    replays; a run that ended at its stop while no driver ran is classified
    and skipped, not rerun.
- `cal_all.sh go` refuses while what it uploads is uncommitted, without this
  record, or with a failing self-test. Its upload path is `fifo_all.sh`'s.
- **Launch, on the owner's word:** `bash scripts/cal_all.sh go`; then
  `status`. Scoring, after `bash scripts/cal_all.sh pull`:
  `python3 scripts/cal_score.py rows > bench/policy_sanity/cal_gem5_rows_v1.txt`,
  then `python3 scripts/cal_score.py score
  bench/policy_sanity/cal_gem5_rows_v1.txt [label=R ...]`.
