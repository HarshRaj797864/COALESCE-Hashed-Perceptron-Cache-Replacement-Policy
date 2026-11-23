# fmm under gem5: results (2026-11-17)

Design: `fmm_gem5_design_2026-11-17.md`, pre-registered `d7705c3`, with
two amendments:

- amendment 1, `7fcfc9c`, before T2 read a log;
- amendment 2, `ec53788`, after T1-T3 ran and
  before any T4 count was looked at.

Tool: `scripts/fmm_diag.py`, t1-t4, self-test 8/8 (`2b558f9`). Existing files only;
nothing was rerun. **fmm stays not scored.**

## T1: gem5's own files

Instructions committed and idle fraction per CPU, from `stats.txt`.

| key, stop | CPU 0 | worker CPUs that waited | the leading worker CPU |
|---|---|---|---|
| fmm_4, 50 M | 50.68 M, idle 0.252 | 1-2: 36.41 / 35.97 M, idle 0.487 / 0.494 | 3: 50.00 M, idle 0.235 |
| fmm_4, 150 M | 158.88 M | 1-2: 138.38 / 131.56 M | 3: 150.00 M |
| fmm_8, 50 M | 56.57 M, idle 0.474 | 1-6: 0.403-0.404 M, **idle 0.9697-0.9698** | 7: 50.00 M, idle 0.496 |
| fmm_8, 150 M | 141.81 M | 1-6: 85.62-86.59 M, idle 0.655-0.660 | 7: 150.00 M |
| fmm_16, 50 M | 56.38 M, idle 0.484 | 1-14: 0.205 M, **idle 0.9801** | 15: 50.00 M, idle 0.497 |

- **"Suspended" (idle above 90%) at fmm_8 and fmm_16; not at fmm_4.**
- The design's opening claim that fmm_4 "looks the same" was wrong.
  Amendment 2 says so.
- **No warning names futex or an unimplemented syscall** in any run log.
  The ignored syscalls are mprotect, set_robust_list, rseq,
  rt_sigprocmask and rt_sigaction.

## T2: the replay's positions

Heartbeats; each core's position counts from its trace's start.

| run | the lead core passes 50 M at cycle | the other workers then | readings |
|---|---|---|---|
| fmm_8 g6 (`phaseA_b3_b2_fmm8`), lead thread 7 | 44,429,073 | 1: 116.0 M; 2-6: 50.1-50.8 M | 0 of 6 below 10 M, 6 above 25 M |
| fmm_8 F-C (`phaseA_b3_fc_b2_fmm8`) | -- | -- | not available: the run had just started at the pull (172 log lines, no heartbeat) |
| fmm_4 g6, lead thread 3 | 19,506,975 | 1: 63.0 M; 2: 49.5 M | 0 of 2 below, 2 above |
| fmm_4 F-C, lead thread 3 | 19,506,840 | 1: 63.0 M; 2: 49.5 M | 0 of 2 below, 2 above |
| fmm_16 g6 (`phaseA_b3_b16_fmm16`), lead thread 15 | 25,851,671 | 1-14: before their first heartbeat (< 10 M) | 14 of 14 below, 0 above |

Each core's SYNC CYCLES HELD, from the same logs:

- fmm_8: thread 1 0.97 M; the others 28.72-29.08 M.
- fmm_16: thread 15 8.60 M; the others 40.55-52.00 M.
- fmm_4: thread 1 5.55 M; the others 7.83-13.57 M.

Run as well, not pre-registered and reported only: with thread 0 as the
lead, fmm_4 reads 0 of 3 below and 3 above; fmm_16 reads 0 of 15 below
and 15 above, at cycle 44,139,938.

## T3: the native routines

The share of window records (W rows) in libc lock / futex / cond /
barrier routines, over the three gem5-CPUID counter runs.

| key | threads | share |
|---|---|---|
| fmm_4 | 1-3 | 1.19-1.29% |
| fmm_8 | 1-5 and 7 | 0.36-0.39% |
| fmm_8 | 6 | 1.28% |
| fmm_16 | 1-15 | 1.16-1.41% |

The share over gem5's located window is **not reported**. The counter's
per-routine counts are window totals, so no tool can place them on the
located window. The note allows for this.

## The readings, as pre-registered

- **H-F2: rejected at fmm_8 and fmm_4, supported at fmm_16** (14 of 14
  below 10 M under amendment 1).
- **H-F1 at fmm_8: indicated, not shown.** T1 reads suspended and H-F2
  is rejected, but there is no futex or unimplemented-syscall warning.
  - At fmm_16, H-F2 holds, so H-F1 is not indicated.
  - At fmm_4, T1 does not read suspended.
- **H-F3: rejected at every key.** Lock routines hold under 2% of the
  window records of every worker thread.

## T4 (amendment 2): the role thread

In every run exactly one thread has `InitParticleList` A records: 98,319
at fmm_4, 393,231 at fmm_8 and fmm_16. Every other thread has 8. So each
run has a single role thread.

| key | gem5's role CPU (from T1) | gem5-CPUID counter runs 1 / 2 / 3 | host run |
|---|---|---|---|
| fmm_4 | 3 | 1 / 2 / 0 | 2 |
| fmm_8 | 7 | 6 / 6 / 6 | 1 |
| fmm_16 | 15 | 0 / 12 / 13 | 13 |

- **H-F4 is SUPPORTED at fmm_8** (no run gives the role to thread 7) **and
  at fmm_4** (none to thread 3).
- At fmm_16 the role moves between runs (0, 12, 13), and none of them is
  gem5's 15. Reported only.

## What this means

- **(a) Timing.** The six workers that barely run in gem5 at 8 cores, and
  the fourteen at 16, are waiting in fmm's own serial phase.
  - Whichever thread takes `count_lock` first gets `my_id 0`. That thread
    builds every particle alone (`fmm.c.in:185-189`) while the others wait
    at the barrier (`:206`).
  - In gem5 the role fell to the last-created CPU at 8 and 16 cores. In
    the Pin runs it falls to whichever thread arrives first, and that
    changes from run to run (T4).
  - **Seen beside it, post hoc, not a test:**
    - gem5's CPU 7 leads the other workers by 63.4-64.4 M at the 150 M
      stop.
    - In the replay, thread 1 is held for 0.97 M cycles (the others
      ~29 M) and leads by 65.2-65.9 M when thread 7 passes 50 M.
    - Both match a serial build of ~64 M instructions on one thread.
  - **The H-F1 indication rests on T2's choice of lead thread.** T2 took
    gem5's role thread as the lead, which assumed the traced run gave the
    role to the same thread. At fmm_8 it did not: the replay's held
    cycles point to thread 1.
  - At fmm_16, T2 supports H-F2 because there the trace's role thread
    (indicated: 15) is gem5's.
  - **No gem5 rerun follows.** The design calls for one only if H-F1 is
    supported.
- **(b) The stream.** Lock slow paths are not the cause (H-F3 rejected).
  H-F4 gives a reason v2 cannot hold for fmm:
  - v2 and the located windows compare gem5's CPU k with the counter's
    thread k.
  - At fmm_8 the serial-build thread is CPU 7 in gem5 and thread 6 in
    every counter run. So two of the seven worker pairs compare a thread
    that builds with one that does not.
  - At fmm_4 and fmm_16 the role moves between the three counter runs, so
    the native range mixes different work.
  - **Not tested:** whether pairing by role makes v2 hold. That needs its
    own note before any fmm ratio is read.

## Beyond fmm (a source survey; no number)

- **Thread numbers assigned by lock arrival.** Most SPLASH-3 programs
  number their threads this way, not at creation:
  - barnes (`code.c.in:398`);
  - ocean (`slave1.c.in:70-73`; procid also picks the boundary
    partitions);
  - water-nsquared (`:279`) and water-spatial (`:370`);
  - raytrace (`main.c.in:238`);
  - volrend (`main.c.in:244`);
  - radiosity (`rad_main.c.in:813`);
  - radix (`radix.c.in:437`);
  - fft (`fft.c.in:437`);
  - cholesky (`solve.c.in:325`);
  - fmm.

  lu was not found by this search.
- **Set 2's PARSEC programs fix the id at creation:** fluidanimate
  (`pthreads.cpp:1249`, `targs[i].tid = i`) and streamcluster
  (`streamcluster.cpp:1722`). vips was not checked.
- **R_g5 is unaffected by a permutation of roles of equal work.** It sums
  over cores on both sides.
- **Per-thread checks are not.** v2, QW, the located windows and the
  matched windows all pair threads by number. They are exact only where
  the id is fixed at creation.
- How unequal the roles are in the other SPLASH-3 programs is **not
  measured**. fmm's role 0 does ~64 M of serial work, so its mismatch is
  visible.
- The matched-window note records this as a caveat. Its first run,
  fluidanimate_4, fixes its ids at creation.

## For the paper

fmm is not scored: it fails v2 on located windows (W2). Its threads take
their roles by arrival at a lock, and the thread that builds the particle
set alone differs between gem5 and the native runs. A per-thread
comparison therefore pairs different work.

**Next, on the owner's word:** a role-matched v2 for fmm (its own note,
written before any fmm ratio is read). Otherwise fmm stays a stated
limitation.
