# B3, held-out programs: pre-registered

**2026-10-14.** Written and committed **before** any trace, ChampSim run or
gem5 run of these programs exists. The only measurements of them so far are
native instruction counts under Pin (below), taken to apply the selection rule.

## Why

Every fix to the tool (the sharer directory, steps 1-3) was designed after
ocean and canneal disagreed with gem5, then checked on the same ocean and
canneal runs. A reviewer can fairly say the tool was fitted to them. barnes is
partly held out: step 3 was designed before ChampSim ran the standard barnes,
though gem5's barnes counters informed it. This scores the tool, **frozen as
it is now**, on programs that played no part in its development.

**Frozen means:** `champsim_b3v4_69ebdcce`, level 2 (the owner's choice of
2026-10-13), no change to the simulator before these are scored. If one fails,
the failure is reported as is; any later change to the tool needs its own
pre-registration and is rescored on all six programs.

## The selection rule, and what it picked

Candidates: SPLASH-3 programs ChampSim has never run (not ocean, not barnes;
canneal is PARSEC). Kept if, at 4 threads with the stated input, measured
natively under Pin (`serialstart.so`, a 20-line counting tool, laptop,
gcc 11 -- the server's gcc 13 build may differ by a few percent):

1. every worker thread executes **at least 200 M instructions**: a 50 M + 100 M
   window with the 15% margin the runners use;
2. thread 0's **serial start** (its instructions before its first
   `pthread_create`) is **at most 60 M**, so a 200 M-record trace of thread 0
   still covers the window after the serial start is dropped;
3. one program per application family.

| program, input | serial start | per worker | kept? |
|---|---|---|---|
| **radix** `-p4 -n16777216 -r1024` | 0.16 M | 1,007 M | **yes** |
| **water-nsquared** `n512-p4` with 8 steps (first line `1.5e-16 512 8 6`) | 12.9 M | 298-303 M | **yes** |
| **fmm** `input.16384` with 4 processors (line 5: `4`) | 12.8 M | 599-616 M | **yes** |
| lu (contiguous) `-p4 -n1024 -b16` | 153 M | 766-823 M | no: serial start |
| fft `-m22 -p4 -n65536 -l4` | 1,326 M | 611 M | no: serial start |
| raytrace `-p4 -m64 car.env` | (not measured) | 124-126 M | no: too short |
| water-spatial `n512-p4` | (not needed) | (3 steps: 127 M) | no: same family as water-nsquared, which locks per molecule |
| cholesky `-p4 < tk29.O` | 244 M | 225-237 M | no: serial start |

volrend and radiosity were not measured (their inputs need more setup); they
are the next candidates if a fourth program is wanted.

The three differ in how they share: **radix** writes keys across all
partitions (all-to-all, barrier-separated); **water-nsquared** updates shared
molecule records, with per-molecule locks (few: see the amendment); **fmm** builds and
walks a shared tree (read-shared with locked updates, like barnes but a
different algorithm).

## What is built and run (server)

`scripts/b3_heldout.sh`, one program at a time:

1. **Build**, from a copy of the server's SPLASH-3 source, with the tree's
   flags and fortify off: a dynamic binary for Pin and a static one for gem5.
   **QB:** every function defined in the program's own objects has the same
   instruction count and constants in both. Otherwise stop.
2. **Trace:** Pin, the same tracer, 4 threads, 200 M records a thread ->
   `traces/<prog>_4t/`. **QT:** four full traces, each with memory operands
   in at least 20% of its records.
3. **Align** thread 0 at the first read-modify-write all workers make on one
   address (SPLASH-3's process-id lock), checked at a second address 5,000
   records on. **QT:** residual within 100 records.
4. **Mix** of the window (records 50 M to 150 M of each aligned trace) for the
   same-stream check.
5. **ChampSim:** LRU, 4 cores, 2 MB, levels 0, 1, 2, shared and private,
   50 M + 100 M on the aligned traces -> `results/phaseA_b3_h<level>_<prog>4`.
   6 runs a program.
6. **gem5** (MESI_Three_Level, 2 MB L2, the static binary): stopped when a
   **worker** (cpu 1-3) reaches 50 M and 150 M instructions. Thread 0's
   serial start falls before the window on both sides.

## Qualifying checks

- **QB, QT** as above.
- **QS, the same stream** (`b3_stream_check.py`, the window): read-modify-
  writes per 1,000 instructions within 5% of gem5's -- **gating**. Loads and
  stores within 5% expected; a miss of up to 8% is reported and scored with
  the miss stated, because gem5's side counts memory micro-ops and read 3-6%
  more on floating-point code (barnes, measured 2026-10-14); beyond 8% nothing
  is scored.
- **QG:** both gem5 runs end at their stop; config shows the static binary,
  2 MB L2, 8 of 8 buffers unordered, randomization off.
- **Q1:** in the private regime the level-1 and level-2 rows equal level 0's
  in every column.
- **Q2:** every run complete, no trace wrapped, self-check 0, 12 registered,
  stale-holder check 0, each log printing its level.

## Predictions

R_b, U and the band (0.5 to 2) as in
`b3v4_coherent_private_design_2026-10-11.md`; the window is 50-150 M worker
instructions.

- **P1, the primary criterion: at level 2, 0.5 ≤ R_b ≤ 2 for each of the
  three programs** where gem5 counts at least 500 store misses that find
  another core in the window. Below 500, that program is reported as not
  discriminating and is not counted either way.
- **P2:** traffic (shared-cache demand accesses) within 2× of gem5's.
- **P3, low confidence:** U in the band where gem5 has at least 10,000
  upgrades (ocean 8 MB read 0.21 and barnes-256 0.48).
- Levels 0 and 1 are reported, with no prediction.

No point estimate is made. The development programs read 0.63 to 1.26.

## How each outcome is read

- **P1 holds for all three:** the frozen tool agrees with gem5 on six shipped
  programs, three of them held out. That is the generalization claim.
- **P1 fails for one or more:** reported as a failure of the tool on that
  program, which stays in the paper. A diagnosis follows; the tool is not
  changed before the submission without a new pre-registration.
- **QS fails (gating part):** the two simulators did not run the same
  program; nothing is scored for it until that is explained.

Nothing is tuned after R is seen.

## Amendment, 2026-10-14 (same day), before any server run

From a local rehearsal of `b3_heldout.sh` (laptop, real Pin and ChampSim,
20 M-record traces, a stand-in for gem5). No server run of any held-out
program exists; nothing here is a result.

- **QT's memory-operand floor is 5%, not 20%.** radix's thread 0 reads 14%
  while it generates keys, and fmm's thread 0 16% late in its first 20 M
  records. The floor exists to catch the 2026-09 tracer bug, which read 0.0%
  on every thread but 0; 5% still does.
- **water-nsquared is not lock-heavy** in the rehearsal's short window (14
  read-modify-writes in 3 M records a thread). The design called it so; the
  description is corrected. It changes no prediction.
- The function comparison (QB) now ignores alignment padding: a static link
  pads after a function differently (radix's `printout`: `cs nopw; nop`).
- The script re-invokes itself by its absolute path.
- **radix's window starts at its region of interest, not at 50 M.** Its
  workers generate keys, privately, for 780.1 M of their 1,007 M instructions
  before the first barrier (a native run under a 20-line Pin tool that records
  each thread's instruction count at each `pthread_mutex_lock`: workers
  780.14 M, thread 0 780.31 M). A 50-150 M window would hold key generation
  only, with no sharing at all. So radix's traces skip 780 M instructions a
  thread (`-skip_instr 780000000`), thread 0 is aligned as before, and gem5
  stops when a worker reaches **830 M and 930 M**: the window is the first
  150 M instructions of the sort, as SPLASH-3's own region-of-interest marker
  ("here one might reset the statistics") places it. water-nsquared's workers
  reach their first barrier at 27.4 M and fmm's lock from 0.3 M on, so their
  50-150 M windows lie inside the computation and are unchanged.
- **The alignment anchor must be touched by thread 0.** fmm's workers first
  share an address inside the thread-start code, which thread 0 never runs;
  the anchor is now the first address threads 1-3 share that thread 0 also
  touches, with threads 1-3 searched over 60 M records. barnes's anchor is
  the same under the new rule (its first shared address is one thread 0
  takes).
- **The anchor may be up to 10,000 records apart across threads 1-3**
  (1,000 for barnes). After the 780 M skip, radix's workers reach their first
  barrier 1,234 records apart: their key-generation phases differ slightly in
  length. The skipped trace confirms the window: 29-36% of radix's records
  carry a memory operand in the sort, against 14% in key generation.
