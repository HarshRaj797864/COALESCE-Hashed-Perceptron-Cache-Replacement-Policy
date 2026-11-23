# H1: which gem5 runs the FIFO patch touched -- design (pre-registered 2026-11-14)

PLAN § 10 item 9, part H1. Written before anything for it is built or run.
No gem5 run with the strict check on exists yet, and none of its results
has been seen.

## Why

Every gem5 run since 2026-09-28 has used `setup_gem5.sh patch-fifo`, which
unorders MESI_Three_Level's two L0<->L1 buffers (`bufferToL1`,
`bufferFromL1`), because the strict-order check killed ocean_4c on
2026-09-27 (`panic: FIFO ordering violated`, 76.2 ms simulated). We had
called that panic a known false alarm. It is not known to be one: gem5 #1597
and #2816 are open, and on #2816 gem5's lead wrote (2025-12-18) that it "is
most likely indicative of a bug in MESI_Three_Level", of unknown effect on
timing (corrected in `0352ab4`).

By the code (`MessageBuffer::enqueue`, gem5 v25.1.0.1): with Ruby
randomization off, a message's arrival time is the current time plus its
delay whether or not the buffer is ordered, and the queue releases messages
by arrival time either way. `ordered` only decides whether the check runs.
So:

- **a run that completes with the check on is the patched run exactly;**
- a run that panics with the check on is one in which a 1-cycle message
  overtook a 2-cycle one. The patched run went on past that point, and gem5's
  lead suspects such a reordering is a protocol bug.

gem5 is deterministic here, so the run to a program's last stop decides
every shorter stop of the same configuration as well: no panic before the
150 M stop means none before the 50 M stop.

## What runs

One gem5 run for each scored configuration, to its longest stop, with the
stock (ordered) buffers. Everything else is the original run's: binary,
inputs, options, CPU count, cache sizes and stop.

| # | configuration | original tree (server) | stop |
|---|---|---|---|
| 1 | ocean 4c, 2 MB | `gem5_b3/l2_2MB_mi150M` (ocean) | 150 M |
| 2 | ocean 4c, 8 MB | `gem5_b3/l2_8MB_mi150M` (ocean) | 150 M |
| 3 | canneal 4c, 2 MB | `gem5_b3/canneal` (2 MB, 150 M) | 150 M |
| 4 | canneal 4c, 8 MB | `gem5_b3/canneal` (8 MB, 150 M) | 150 M |
| 5 | canneal 8c | `gem5_b3/canneal8` (150 M) | 150 M |
| 6 | barnes std | `gem5_b3/barnes` (150 M) | 150 M |
| 7 | barnes-256 | `gem5_b3/barnes_leaf256` (150 M) | 150 M |
| 8 | radix | `gem5_b3/heldout` (radix, 150 M) | 150 M |
| 9 | LU non-contiguous | `gem5_b3/newbench` (lunc, 150 M) | 150 M |
| 10 | streamcluster | `gem5_b3/newbench` (streamcluster, 150 M) | 150 M |
| 11 | fluidanimate | `gem5_b3/heldout2` (fluidanimate, 150 M) | 150 M |
| 12 | vips | `gem5_b3/heldout2` (vips, 150 M) | 150 M |
| 13 | ocean non-contiguous (apart) | `gem5_b3/heldout2` (oceannc, 150 M) | 150 M |

The exact directory of each is resolved from the server's tree by the
runner's `list` mode and written into this note's build record before any
run starts. Runs that were stopped and relaunched (`.prev_*`) are never
used.

**Not in H1:** programs that are reported but not scored (lu, raytrace,
water-nsquared, facesim, fft, volrend, fmm, bodytrack), and Part B's 58
runs at 8 and 16 threads. Part B's runs are added by an amendment only if
the server has room after H1, 8-thread runs first; the 16-thread runs
(up to 240 h) cannot end before the freeze. Until then, the paper says
which points H1 covers.

## How

- A copy of gem5's `configs/` tree (`~/gem5_fifo/configs`) in which
  `ruby/MESI_Three_Level.py` is gem5's stock file: both buffers
  `MessageBuffer(ordered=True)`, checked against gem5 v25.1.0.1's file by md5
  and by `grep` (0 of the patch's 2 lines, 2 `ordered=True` lines). The live
  `~/gem5/configs` is not touched. The gem5 binary is the one the originals
  ran (`~/gem5/build/X86/gem5.opt`); nothing is rebuilt.
- `run_gem5_splash.sh` gains one setting, `GEM5_CONFIGS` (default: the
  current `$GEM5_DIR/configs`, so every existing launch is unchanged) and a
  matching preflight: with `FIFO_STRICT=1` it requires the stock file
  instead of the patched one. Each run is started through the same mode and
  settings as its original, into `~/gem5_b3/fifo/<n>_<name>/`, nice 19,
  four at a time.

## Checks, fixed now

- **QF0, the same configuration:** each run's `config.ini` equals its
  original's except the two buffers' `ordered` lines (`false` -> `true`, for
  every L0 controller) and output paths. Any other difference: the run is
  void, and the runner stops before launching more.
- **QF1, the outcome of each run**, read from its `run.log` and exit code:
  - **COMPLETE-IDENTICAL:** it reaches its stop, and its `stats.txt`
    equals the original's line for line, apart from lines starting with
    `host` (host time, rate and memory).
  - **PANIC:** `FIFO ordering violated` in `run.log`. Recorded: the tick,
    the buffer, the CPU, and whether the tick falls before the original
    50 M stop's final tick (in the warm-up) or after it (in the window).
  - **COMPLETE-DIFFERENT:** it reaches its stop with different statistics.
    That would contradict the code reading above: **stop**, nothing is
    reported until it is diagnosed.
  - **OTHER:** any other end (a time limit of 96 h, another panic): reported
    as not decided.

## What each outcome means for the paper

- **COMPLETE-IDENTICAL:** that configuration's gem5 counts are those of
  stock MESI_Three_Level; the patch did nothing there. It is stated without
  a caveat.
- **PANIC:** the configuration's R stays as scored (its rules were fixed
  before the runs), and the paper lists it as "the reference ran past a
  suspected protocol bug at tick T". If any configuration panics, a records-only
  counter of overtakes (a stat in `MessageBuffer::enqueue`, built in a
  separate gem5 tree; its own Q0: every other statistic identical) is
  pre-registered next, to say how many overtakes per million messages each
  run had.
- **No prediction is made about how many panic.** ocean_4c panicked
  (grid 1026) before the patch; the scored ocean runs use grid 514.

## Cost

13 runs, each about as long as its original 150 M run: hours to about a day
each at today's load. They start only on the owner's word, after a rehearsal
against a stand-in gem5 (a panic case, an identical case, a different case,
a QF0 failure).

## Build record (2026-11-14, before any launch)

- **Read on the server first (read-only):** `~/gem5` is at v25.1.0.1, and
  `git status` shows only the patched `MESI_Three_Level.py`, the untracked
  `.gem5_protocol` and the backup `MESI_Three_Level.py.orig_fifo`. The
  backup's md5 (`df9ec6ee...`) equals the tag's file; its buffers read
  `MessageBuffer(ordered=True)` (lines 210 and 212). `gem5.opt` was built
  2026-09-24 10:13, before every one of the 13 originals (the earliest,
  ocean 2 MB, 2026-10-04). All 13 original directories hold a `config.ini`.
  barnes std and barnes-256 read the same `barnes.in` (md5 f7a45c9b).
- **The 13, as the runner holds them** (under `~/gem5_b3`; short stop in
  brackets): `l2_2MB_mi150M/ocean_4c` (`l2_2MB_mi50M`),
  `l2_8MB_mi150M/ocean_4c` (`l2_8MB_mi50M`),
  `canneal/l2_2MB_mi150M/canneal_4c` (mi50M), `canneal/l2_8MB_mi150M/canneal_4c`
  (mi50M), `canneal8/l2_2MB_mi150M/canneal_8c` (mi50M),
  `barnes/l2_2MB_mi150M/barnes_4c` (mi50M),
  `barnes_leaf256/l2_2MB_mi150M/barnes_4c` (mi50M),
  `heldout/radix/l2_2MB_mi930M/radix_4c` (mi830M), and
  `<set>/<program>/l2_2MB_mi150M/<program>_4c` (mi50M) for lunc,
  streamcluster (newbench), fluidanimate, vips and oceannc (heldout2). Each
  is relaunched through the mode and settings its original used
  (`launch_b3_gem5.sh`: `OCEAN_GRID=514`, `LLC_SIZE`, `MAXINSTS` for ocean
  and barnes, `WORKER_MAXINSTS` for the rest, `BINS` per set).
- **Built:** `run_gem5_splash.sh` gains `GEM5_CONFIGS` and `FIFO_STRICT`
  (defaults: the live tree, the patch required, so every other launch is
  unchanged; H1 uploads its own copy into `~/gem5_fifo`, never over
  `~/run_gem5_splash.sh`). `scripts/fifo_check.py` (QF0, QF1; self-test 9 of
  9 on the pulled ocean run: a same configuration passes, a changed L2 size
  and an unflipped buffer fail; identical, different, panic in the window,
  panic in the warm-up, other and running are each classified as fixed
  above). `scripts/fifo_server.sh` (guards, list, chain, status, stop) and
  `scripts/fifo_all.sh` (go, guards, status, list, pull, stop).
- **Rehearsed against a stand-in server** (a fake home: a gem5 checkout
  tagged v25.1.0.1 and patched as `patch-fifo` patches it; a stand-in
  `gem5.opt` that writes the original's config.ini and flips the buffers to
  ordered **only if** the configs tree it was given has the stock file; real
  static stand-in programs; four originals copied from the pulled runs):
  - guards fail before the copy exists, and pass after `prepare` (15 of 15);
  - each run got its original's binary, arguments, CPU count, LLC size,
    stop and the copy's se.py (read from the stand-in's argument record);
  - ocean COMPLETE-IDENTICAL, canneal PANIC in the window, barnes
    COMPLETE-DIFFERENT, which stopped launching: radix NOT RUN;
  - a changed L2 size: QF0 FAIL, the run ended by the driver, VOID, the
    next NOT RUN;
  - a run past the limit: ended, OTHER;
  - a relaunch skips every decided run;
  - injected faults refused by the guards: the copy patched, the live tree
    changed elsewhere, the copy changed elsewhere, an original without
    statistics, the binary newer than an original, a runner copy without
    `FIFO_STRICT`, and a chain started while a driver is alive;
  - two defects found and fixed: a run could launch in the slot of a run
    that had just ended before that run was classified (now: count, then
    classify, then decide), and a relaunch with nothing to run reported "the
    driver did not start".
  - `fifo_all.sh go` refuses while its files are uncommitted. Its upload
    path is `partBfc_all.sh`'s (rehearsed there), not rehearsed again.
- **Launch, on the owner's word:** `bash scripts/fifo_all.sh go`; then
  `status`, `pull` (to `simulator/results/fifo/`).
- **First launch, 2026-11-14 (owner's word):** stopped at the guard on the
  live gem5 tree. Its three entries were exactly the expected ones, but the
  server sorted them in its en_US.UTF-8 order, not the C order the guard
  compares against (the laptop runs C.UTF-8). Fixed with `LC_ALL=C sort`;
  nothing had started (`prepare` had made `~/gem5_fifo/configs`, kept).
