# B3, the standard barnes — new traces against gem5's existing runs: pre-registered

**2026-10-13.** Written and committed **before** the traces, the ChampSim
runs or the new gem5 stop exist.

The `barnes_4t` traces are of a BARNES built with 256-body leaves
(`b3_barnes_stream_2026-10-12.md`). gem5 ran SPLASH-3's barnes as shipped,
with 10. This traces the shipped program, so the two simulators can be
compared on the benchmark its authors define.

It is separate from `b3_barnes256_design_2026-10-12.md`, which takes the
other road: gem5 on the 256-body-leaf program.

## What is built and run

`scripts/barnes_std.sh`, on the server:

1. **The binary.** A dynamic BARNES from a copy of the server's source, the
   tree's flags, fortify off as in gem5's static binary. The tree and the
   old traced binary are not touched.
2. **The traces.** Pin, the same tracer and input (`n16384-p4`), 4 threads,
   200 M records a thread, to `traces/barnes_std_4t/`.
3. **Alignment.** Thread 0 is the program's main thread, so its trace opens
   with about 10 M instructions of serial start-up that the other three do
   not have. Those records are dropped, so all four traces start at the same
   point of the program.
   - The anchor is the first read-modify-write that threads 1, 2 and 3 all
     make on one address: `SlaveStart`'s lock on `Global->CountLock`.
   - On the old traces this puts the first barrier at record 25,490 in all
     four threads, exactly.
   - **This is a correction to the input, made before any result is seen.**
     The old runs replayed thread 0 that far behind the others.
4. **ChampSim**, the frozen `champsim_b3v4_69ebdcce`: LRU, 4 cores, 2 MB,
   both regimes, levels 0, 1 and 2, over three spans. 18 runs.
5. **gem5:** one more stop of the standard static BARNES, at 100 M.

## The three spans

A time step of the standard program is about 137 M instructions a thread:
a tree build of a few million, then the force phase. Threads meet at
barriers between phases. **A trace replay has no barriers:** each core runs
its own trace at its own speed.

| span | ChampSim, per core | gem5 | what it holds |
|---|---|---|---|
| **force** | 37.9 M warm-up + 50 M | from its 50 M stop to its 100 M stop | the inside of the first force phase, on both sides. No barrier is crossed |
| **start** | 0 + 37.9 M | from the program's start to its 50 M stop | the first tree build, then the first third of the forces. The threads start aligned |
| **window** | 37.9 M + 100 M | its 50 M to its 150 M stop, as every B3 score so far | the rest of the forces, the step boundary, and the second tree build |

- At gem5's 50 M stop threads 1 to 3 have run 37.76 to 37.95 M
  instructions, hence 37.9 M.
- gem5's threads run at nearly one instruction rate inside a phase (37.76
  to 37.95 M at that stop), so at its 100 M stop each should be about 50 M
  further on. That is short of where the first thread finishes its forces,
  about 100 M by an estimate from a native run. **QF below checks it.**
- **In the window span the threads cross a barrier that the replay does not
  hold them at.** One thread starts rebuilding the tree while the others
  still read it. That cannot happen in the program.

## Qualifying checks

If one fails, nothing is scored until it is explained.

- **QB, the binary.** Leaves of 10 bodies, and `gravsub`, `walksub`,
  `hackgrav`, `hackwalk`, `subdivp`, `ComputeForces`, `stepsystem`,
  `loadtree`, `SubdivideLeaf`, `hackcofm` and `maketree` each have the
  instruction count and constants of the binary gem5 ran. The pipeline
  stops otherwise.
- **QT, the traces.** Exactly four, each 200 M records, each with memory
  operands in at least 20% of its records. After alignment thread 0 is
  within 100 records of the others at the anchor.
- **QG, the guard.** 8 to 13.5 read-modify-writes per 1,000 instructions in
  each trace (gem5's standard run: 10.6; the 256-body-leaf build: 26.8).
  The pipeline launches nothing otherwise.
- **QS, the same stream.** `b3_stream_check.py`, force span: instructions
  with a load, with a store, and read-modify-writes each within 5% of
  gem5's. The other two spans are reported: their ends do not line up
  thread by thread.
- **QF, the force span crosses no barrier in gem5.** A thread that waits at
  a barrier executes nothing, so between gem5's 50 M and 100 M stops each
  of its four cores must have run 50 M instructions, within 2%.
- **Q1, the private regime is untouched:** in each span the private rows at
  levels 1 and 2 equal the level-0 row in every column, and every new
  counter reads 0.
- **Q2:** all 18 rows complete, no trace wrapped, self-check 0, 12
  registered, stale-holder check 0, each log printing its level. The new
  gem5 run ends at its stop, with the standard binary, a 2 MB L2, 8 of 8
  buffers unordered and randomization off.

## Predictions

R_b, U and the band (0.5 to 2) are as in
`b3v4_coherent_private_design_2026-10-11.md`. In the start span the ratios
are of **counts**: gem5's instructions there include thread 0's serial
start, which the aligned traces leave out. U is scored where gem5 has at
least 10,000 upgrades in the span.

**Level 2, the target.**
- **P1, force span, the primary criterion: 0.5 ≤ R_b ≤ 2.** Both
  simulators are inside one phase, where the order of the threads is not
  fixed by the program.
- **P2, start span: 0.5 ≤ R_b ≤ 2 by count.** gem5 counts 123,076 store
  misses that find another core, and 154,740 upgrades.
- **P3, window span: reported, and expected at or above the force span's
  R_b.** The replay lets a thread into the next step while the others
  finish this one. gem5 counts 44,867 and 61,777.
- **P4, upgrades:** 0.5 ≤ U ≤ 2 in the start span and, if gem5 has 10,000
  there, in the force span. **Held with less confidence:** ocean reads 0.53
  and 0.21.
- **P5, traffic:** shared-cache demand accesses within 2× of gem5's in the
  force and start spans.

**Levels 0 and 1.**
- **P6, force span: R_b < 0.5 at both.** The program's working set fits the
  private caches, so its hand-overs are upgrades and invalidations.
- **P7:** in every span R_b at level 1 is at or below R_b at level 2.
- In the start span a line's first write by a new core reaches the shared
  cache even at level 0, so R_b there may not be near 0. Expected under 0.5,
  with little confidence.

## How each outcome is read

- **P1 and P2 hold:** the tool agrees with gem5 on the standard barnes at
  level 2, where the comparison is clean. With ocean and canneal that is
  three shipped programs at 4 cores.
- **P1 fails high:** ChampSim over-counts hand-overs in a steady phase.
  Candidates: a hand-over costs no time; ownership is asked for when a
  read-modify-write executes, long before its store retires.
- **P1 fails low:** ChampSim misses hand-overs. Candidates: store-to-load
  forwarding hides read-modify-write loads from the cache; a store that
  hits is counted only when the directory lists another core.
- **The window span reads well above the force span:** it measures what a
  replay without barriers costs at a phase boundary. That is a limit of
  trace-driven simulation, reported with its size. It is not tuned away.
- **The window span reads like the force span:** the barrier matters less
  than expected for this program.
- **QS fails in the force span:** the two are not the same stream. Nothing
  is scored.

**Nothing is tuned after R is seen.** No run in flight depends on this: the
A5 rerun is canneal and ocean.

## What it changes for results in hand

- Every policy row labelled "barnes" so far is of the 256-body-leaf
  program. Whether those are rerun on these traces or dropped is the
  owner's decision. A5 does not use barnes.
- These traces start aligned; the old ones did not. Any future barnes run
  uses the aligned set.
