# Speed test, scored (2026-10-19): P1 fails -- the paper makes no speed claim

Design: `speed_design_2026-10-18.md`. Report pulled 2026-10-19 (server time
03:17); 12 of 12 runs, every one "ok" (gem5 ended at its stop; ChampSim
completed, never wrapped, printed the expected coherence level).

The standard barnes (`barnes_std_4t`, aligned), 4 cores, both simulators at
once on the same server; gem5 until a thread commits 30 M, ChampSim 25 M per
core from the aligned start. Instructions per CPU-second (user + sys), two
repeats each:

| configuration | K instr / CPU-s | repeats | peak MB |
|---|---|---|---|
| G-ts-ruby (TimingSimpleCPU, Ruby MESI_Three_Level) | **145.5** | 141.5, 149.5 | 807 |
| G-o3-ruby (DerivO3CPU, Ruby) | **44.9** | 44.2, 45.5 | 827 |
| G-o3-classic (DerivO3CPU, classic caches) | 54.8 | 54.5, 55.0 | 232 |
| C-l2 (ChampSim, level 2: the tool) | **64.0** | 63.8, 64.3 | 120 |
| C-l0 (ChampSim, level 0) | 65.6 | 65.0, 66.1 | 120 |
| C-before (ChampSim before every change, `champsim_phaseA_20260923`) | 66.0 | 66.2, 65.9 | 117 |

Repeats agree within 0.5-5.5%.

## Predictions

- **P1 FAILS: C-l2 / G-o3-ruby = 1.43** (needed 2). Against gem5's
  out-of-order core with classic caches: 1.17.
- **P2 holds: G-ts-ruby / C-l2 = 2.27.** gem5's in-order core is faster than
  ChampSim's out-of-order core, as the logs had shown.
- **P3 holds: C-l2 / C-before = 0.97.** The extension (overlay, directory,
  level 2) costs 3%.

## What follows (pre-registered)

**The paper makes no speed claim.** The case for the tool rests on what
remains: every ChampSim replacement policy and prefetcher runs under real
sharing unchanged, and traces start at the region of interest. Even the 1.43x
would not survive the caveat stated beforehand: gem5 here is the `.opt` build,
and `gem5.fast` is quicker.

Not claimed either: the region-of-interest argument as a speed advantage.
gem5 can skip a loader with checkpoints or a fast-forward CPU, so a reviewer
would discount it. It is a convenience, not a measurement.

Memory, reported: ChampSim peaks at 120 MB against gem5's 230-830 MB.
