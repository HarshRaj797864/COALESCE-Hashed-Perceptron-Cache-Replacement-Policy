# B3 at 8 cores: canneal against gem5 with 8 workers. Pre-registered

**2026-10-14.** Written and committed **before** any 8-core gem5 run or any
of the ChampSim runs below exists. (The A5 rerun's `phaseA_l2_fixed` LRU
canneal 8c shared row exists and has been read; it is a policy row, and it
is used here only as a determinism check, Q3.)

## Why

Every B3 comparison so far is at 4 cores. The evaluation runs at 8 and 16. A
reviewer will ask whether the tool's sharing still agrees with gem5's when
twice as many cores share. canneal is the program the cross-regime work
rests on, and its 8-thread traces exist (`canneal_8t`, threads 1-8, the
workers; thread 0 loads the netlist).

## What is run

- **ChampSim** (`scripts/b3_canneal8.sh`), the frozen `champsim_b3v4_69ebdcce`:
  LRU, 8 cores, 2 MB, levels 0, 1, 2 x shared, private, 50 M + 100 M ->
  `results/phaseA_b3_e<level>_canneal8`. 6 runs.
- **gem5:** the static CANNEAL already used at 4 cores, `canneal 8 15000 2000
  100000.nets 128` (the arguments `canneal_8t` was traced with), 9 CPUs
  (loader + 8 workers), MESI_Three_Level, 2 MB L2, stopped when a worker
  reaches 50 M and 150 M (`WL=canneal8 launch_b3_gem5.sh`).
- **The window's instruction mix** of each trace, records 50-150 M, for the
  same-stream check.

## Qualifying checks

- **QS:** `b3_stream_check.py`, canneal8: instructions with a load, with a
  store, and read-modify-writes within 5% of gem5's (canneal at 4 cores:
  0.1%).
- **QG:** both gem5 runs end at their stop; config shows 9 CPUs, a 2 MB L2,
  buffers unordered, randomization off, the per-CPU stop on cpu 1-8.
- **Q1:** the private rows at levels 1 and 2 equal level 0's in every column.
- **Q2:** every run complete, no trace wrapped, self-check 0, **24** private
  caches registered, stale-holders 0, the log printing its level.
- **Q3, determinism:** the level-2 shared row equals the A5 rerun's
  `phaseA_l2_fixed` LRU canneal 8c shared row in every column (same binary,
  config and traces).

## Predictions

R_b and the band as in `b3v4_coherent_private_design_2026-10-11.md`.

- **P1, primary: at level 2, 0.5 ≤ R_b ≤ 2.** canneal at 4 cores read 1.263
  (2 MB).
- **P2:** traffic within 2× of gem5's.
- Levels 0 and 1 reported, with no prediction. U is not scored if gem5
  counts fewer than 10,000 upgrades (canneal at 4 cores had 580).

## How each outcome is read

- **P1 holds:** agreement holds at 8 cores on the program the evaluation
  uses most, and the paper may say so.
- **P1 fails:** reported; the cross-regime results at 8 and 16 cores carry
  it as a threat, and a diagnosis follows. The tool is not changed before
  the submission without a new pre-registration.

Nothing is tuned after R is seen.
