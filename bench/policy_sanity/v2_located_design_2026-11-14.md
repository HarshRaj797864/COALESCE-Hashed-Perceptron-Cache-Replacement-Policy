# The v2 misses of Part B: where gem5's window lies. Pre-registered 2026-11-14, before any located number is computed

Owner, 2026-11-14: "ok do all of them". This is the barnes_16 note promised
in the Part B interim (`partB_checks_interim_2026-11-14.md`, `21095a5`).
Nothing here changes a rule of Note 3. **barnes_16 stays not scored whatever
this finds.**

## What is already known (read before this note)

- **barnes_16, v2 fails on RMWs only.** gem5: 9.756 per 1,000 instructions.
  The three gem5-CPUID counter runs: 10.372-10.378. Widened by 5%, that is
  9.853-10.897 (or within 0.05 of the range). Loads and stores pass.
- fmm fails v2 at every core count: RMWs at 4; stores and RMWs at 8 and 16.
  volrend fails v2 at 8 (stores, RMWs) and 16 (RMWs); at 4 it fails QC.
- Printed by `check`: these rates and its reported per-thread load and store
  lines. Seen while checking the counter rows' format: one row (barnes_16,
  counter run 1, thread 0's window). No located number exists yet.

## Two hypotheses

**H-W, window placement.** v2 compares two windows that need not cover the
same instructions.
- The counter's window: records 50-150 M of each thread after its base.
  Thread 0's base is its last `pthread_create`.
- gem5's window: each CPU between the two runs' stops. gem5 stops when the
  **first** watched worker CPU reaches 50 M or 150 M
  (`max_insts_any_thread` on `cpu[1:n]`, Note 3). A lagging CPU's window
  starts and ends earlier. CPU 0's count runs from the program's start.
- If RMW density changes with the phase, two windows at different positions
  give different rates from the same stream. In barnes, tree building
  takes a cell lock per insertion; the force phase takes almost none.

**H-L, lock contention.** In the native run, a contended acquire adds RMWs:
the `xchg` of each pass through `__lll_lock_wait`. gem5's timing need not
produce as many.

## The tests

**W, the located window.** Each counter run holds running counts every
100,000 records, including the count in gem5's units (`ginst`). gem5's
per-CPU `numInsts` at a stop is the same kind of count, from the same
thread's start.
- Thread t's located window: from the grid point whose `ginst` is nearest
  CPU t's `numInsts` at the low stop, to the one nearest it at the high stop.
- Summed over the key's traced threads: located loads, stores and RMWs per
  1,000 `ginst`, in each of the three gem5-CPUID runs.
- gem5's rates are judged against the located range by v2's own rule
  (widened 5%; RMWs or within 0.05).
- **Caveat, stated:** the counter runs the dynamic binary and gem5 the
  static one. Thread 0's positions therefore differ by the start-up
  difference (ld.so, dynamic initialisation). This is not measured here.

**L, the contention bound.** From each counter run's routine file (`.rtn`, W
lines: the counter's own window):
- the stores per 1,000 window `ginst` in routines whose name contains
  `lll_lock_wait`. Every store there is the futex word's `xchg`, an RMW.
- B = the largest over the three runs.

## Readings (fixed now)

For each failing measure of each key, with g the gem5 rate and [lo, hi] the
counter windows' range:

- **W1:** g lies inside the located range by v2's rule. **H-W is
  supported.** The miss is explained by where the windows lie; the stream is
  not shown to differ.
- **W2:** g lies outside it. H-W does not explain the miss alone. The
  located rate is reported.

For RMWs below the range (barnes_16's case):
- s = (the range's lower widened edge) - g. That edge is the lower of
  0.95 x lo and lo - 0.05. For barnes_16, s = 9.853 - 9.756 = 0.097.
- gap = lo - g. For barnes_16, 0.616.
- **L1:** B < s. **H-L is rejected:** removing every lock-wait RMW from the
  native side would not bring gem5 inside.
- **L2:** B >= gap. **H-L can explain the miss.**
- **L3:** in between. H-L is partial.

**Control C.** Every key that passes v2 on the counter windows is checked
again on the located windows.
- If all of them still pass, the located test is consistent.
- If any fails, it is reported. The located test is then not a safe
  replacement for v2's windows.

**Placement, reported for every key:** per CPU, how far gem5's window start
and end lie from the counter window's, in M instructions.

**Keys:**
- **Primary:** barnes_16.
- **Secondary**, read by the same rules and reported: fmm_4, fmm_8, fmm_16,
  volrend_4, volrend_8, volrend_16.

## What follows from it

Nothing is scored from this note.

**Under W1:** a remedy would apply to every key. Possible remedies:
- v2 on located windows;
- a matched stop;
- for B3 itself, gem5's per-CPU windows set against ChampSim's.

Any remedy needs its own note and the owner's decision.

**Under L2:** the RMW criterion cannot separate a timing effect from a
stream difference for this program. That is stated as a limit of v2.

## Tool and output

- **Tool:** `scripts/v2_located.py`.
  - `run KEYS COUNT_ROWS COUNT_RUNS GEM5_PERCPU GEM5_MIX`;
  - `selftest`: a stand-in key with hand-known located and counter-window
    rates.
  - The counter-window rates it prints must equal `check`'s v2 numbers (QV).
- **Output:** `bench/policy_sanity/v2_located_v1.txt`.
- **Results:** `v2_located_results_2026-11-14.md`.
