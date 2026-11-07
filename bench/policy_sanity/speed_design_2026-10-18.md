# Is the extended ChampSim faster than gem5? Pre-registered

**2026-10-18.** Written and committed before any run below exists. Step 1
of the order in PLAN § 10.

## Why

The existing logs say gem5 as we have run it (TimingSimpleCPU, an in-order
core, with Ruby's MESI_Three_Level) simulated 47-155 K instructions/s while
ChampSim simulated 16-77 K/s on the same windows. Those runs were at
different times under different load, and the cores are not alike: ChampSim
models an out-of-order core. Whether the tool is faster than gem5 *at
comparable detail* decides whether speed can be part of the tool paper's
case at all. Also unmeasured: what our extension (the overlay, the sharer
directory, coherent private caches) cost ChampSim's own speed.

## The runs (server, `scripts/speed_server.sh`; all at once, nice 19, each twice)

One workload for all: the **standard barnes**, 4 threads, 16,384 bodies, the
program every barnes B3 score uses.

| run | simulator | core | memory system | length |
|---|---|---|---|---|
| G-ts-ruby | gem5 (gem5.opt, v25.1.0.1) | TimingSimpleCPU (in order) | Ruby MESI_Three_Level, the B3 hierarchy | from the program's start until a thread commits 30 M |
| **G-o3-ruby** | gem5 | **O3 (out of order)** | Ruby MESI_Three_Level, the B3 hierarchy | same |
| G-o3-classic | gem5 | O3 | classic caches: private L1s, one shared 2 MB L2 (snooping) | same |
| **C-l2** | ChampSim, `champsim_b3v4_69ebdcce` | out of order | the tool: shared regime, level 2 | the aligned traces, 25 M per core |
| C-l0 | same binary | out of order | shared regime, level 0 | same |
| C-before | `champsim_phaseA_20260923` (before the sharer directory and steps 1-3) | out of order | shared regime (the overlay only) | same |

**The measure:** simulated instructions per CPU-second of the simulator
process (user + system time from `/usr/bin/time`; wall time is reported but
the server is shared, so CPU time is primary). Peak memory is reported.
Each run twice; the mean of the two, and their spread.

## Predictions

- **P1 (the claim):** C-l2 simulates at least **2x** the instructions per
  CPU-second of G-o3-ruby.
- **P2:** G-ts-ruby simulates at least as many per CPU-second as C-l2 -- the
  log finding, now under one load.
- **P3:** our extension costs under **30%**: C-l2 at least 0.7x C-before.
- Reported, no prediction: G-o3-classic; the spread between repeats.

## How the outcomes are read

- **P1 holds:** "ChampSim with our extension simulates N x faster than gem5's
  out-of-order core with Ruby on the same program" is a claim the paper may
  make, with the caveat below.
- **P1 fails:** the paper makes no speed claim. The case for the tool rests
  on the rest: every ChampSim policy and prefetcher runs under real sharing
  unchanged, and traces start at the region of interest (gem5 simulated
  canneal's 4 G-instruction loader before each of its windows: 8-9 h a run).
- **P3 fails:** the directory's cost is reported and its data structure
  examined before anything else is built on it.

**Caveat, stated now:** gem5 is the `.opt` build (with assertions); a `.fast`
build is quicker. The server has 16 GB free, too little to build it beside
the running work. If P1 holds by less than 1.5x, the paper says the margin
may not survive `gem5.fast`.

Nothing is tuned after a number is seen.
