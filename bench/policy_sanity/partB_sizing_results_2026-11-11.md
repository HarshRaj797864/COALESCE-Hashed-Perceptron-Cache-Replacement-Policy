# Part B, first stage: the sizing at 8 and 16 threads (2026-11-11)

Design: `breadth_bc_design_2026-11-10.md`, amendment 2 (Note 1, the recipes)
as corrected by amendment 3. Runner: `scripts/partB_all.sh`,
`partB_server.sh` (`8455d1f`; mode change `3c2a3f1`). Launched on the
owner's word, 2026-11-11 13:39 UTC. Rows:
`partB_sizing_rows_v1.txt` (made by `scripts/partB_sizing_rows.py rows`
from the pulled records; every key's record files, per-thread counts and
sizing log).

**This note holds sizing only: instruction counts of native runs under the
probe. No trace, no ChampSim run and no gem5 statistic of Part B exists
yet.**

## What ran

- The six guards passed on the server (the 29 binaries by md5; the stdin
  inputs; the ladders' input files; Pin and the probe `f8af3b0b`; 130 GB
  free; the gem5 runner's entry).
- The 28 keys were sized between 13:39:46 and 13:41:30 UTC: 104 seconds,
  not the "few hours" the runner's header and my report estimated. The
  probe only counts, and the programs run to their end in seconds. The
  estimate was wrong; nothing depends on it.
- **28 of 28 keys sized. None is below the size rule, none failed E3, no
  rung failed to run, and no sizing log holds a NOTE.**

## The rungs

| key | rung | threads started | gem5 CPUs | least traced thread | skip | rungs tried |
|---|---|---|---|---|---|---|
| barnes_8 | b65536 | 8 | 8 | 1183 M | 0 M | 2 |
| bodytrack_8 | simmedium | 10 | 10 | 371 M | 0 M | 1 |
| fft_8 | m24 | 8 | 8 | 1141 M | 0 M | 2 |
| fluidanimate_8 | simmedium | 9 | 9 | 392 M | 0 M | 2 |
| fmm_8 | p65536 | 8 | 8 | 1268 M | 0 M | 2 |
| lunc_8 | n1024 | 8 | 8 | 361 M | 0 M | 1 |
| ocean_8 | n1026 | 8 | 8 | 655 M | 0 M | 2 |
| oceannc_8 | n1026 | 8 | 8 | 724 M | 0 M | 2 |
| radix_8 | n67108864 | 8 | 8 | 2013 M | 1560 M | 3 |
| raytrace_8 | a1 | 8 | 8 | 575 M | 0 M | 1 |
| streamcluster_8 | p16384 | 17 | 9 | 3474 M | 0 M | 1 |
| vips_8 | simsmall | 11 | 11 | 352 M | 0 M | 1 |
| volrend_8 | r16 | 8 | 8 | 1035 M | 0 M | 2 |
| waternsq_8 | s32 | 8 | 8 | 586 M | 0 M | 3 |
| barnes_16 | b65536 | 16 | 16 | 587 M | 0 M | 1 |
| bodytrack_16 | simlarge | 18 | 18 | 664 M | 0 M | 2 |
| canneal_16 | -- | -- | 17 | -- | -- | not sized: traced already |
| fft_16 | m24 | 16 | 16 | 571 M | 0 M | 1 |
| fluidanimate_16 | simlarge | 17 | 17 | 550 M | 0 M | 2 |
| fmm_16 | p65536 | 16 | 16 | 630 M | 0 M | 1 |
| lunc_16 | n2048 | 16 | 16 | 1440 M | 0 M | 2 |
| ocean_16 | n1026 | 16 | 16 | 317 M | 0 M | 1 |
| oceannc_16 | n1026 | 16 | 16 | 355 M | 0 M | 1 |
| radix_16 | n134217728 | 16 | 16 | 2013 M | 1560 M | 2 |
| raytrace_16 | a2 | 16 | 16 | 556 M | 0 M | 2 |
| streamcluster_16 | p16384 | 33 | 17 | 1738 M | 0 M | 1 |
| vips_16 | simmedium | 19 | 19 | 569 M | 0 M | 2 |
| volrend_16 | r16 | 16 | 16 | 540 M | 0 M | 1 |
| waternsq_16 | s64 | 16 | 16 | 586 M | 0 M | 2 |

"Threads started" counts every thread start, main included. "Least traced
thread" is the smallest instruction count among the threads to be traced.

- **radix, as written down beforehand (amendment 3, item 1): 67,108,864
  keys at 8 threads and 134,217,728 at 16, each with a skip of 1,560 M.**
  The first broadcast came at 1,560.28 M at both counts (thread 6 at 8
  threads, thread 1 at 16) and the sort that follows is 453 M a thread. At 16 threads the 8-thread rung was
  tried first and left 227 M past its skip of 780 M, under the rule.
- **streamcluster** starts 2N + 1 threads (17 and 33). Its second set of N
  executes under 15,000 instructions each; the first N are the traced ones.
- **vips:** threads 1 and 2 are the idle ones in both runs (about 14,000
  instructions each at 8 threads, 44,000 at 16); the workers are 3 to
  N + 2.
- **bodytrack:** in the native window the untraced threads execute 1.54%
  (8 threads) and 1.27% (16) of the traced threads' instructions. QW's
  limit is 1%, read later on gem5's CPUs, not here. At 4 threads it failed
  QW at 3.93%. Reported only.
- **barnes, fft and fmm at 16 threads** are uneven in the native window
  (a thread at 31-38 M where the reference thread runs 100 M). Reported
  only; the window is gem5's to set.

## Checked independently

A separate reader (Python; it shares no code with the runner's awk)
recomputed from each key's probe file the thread starts, the least traced
thread, radix's skip, the gem5 line's CPUs, worker slice and stops, the
trace line's threads and skip, and the thread count inside each generated
stdin file: **454 comparisons, 0 mismatches** (the same reader found a
planted fault in the rehearsal).

## gem5

The driver starts one run about every 37 s, at most 24 at once, 8-thread
keys first (canneal at 16 threads, sized from the start, went first). The
first real runs with 16 GB and 17 CPUs were read back from their
config.ini: 17 CPUs, the stop on cpu1..cpu16, L2 2 MB, memory 16 GB,
randomization off, the static CANNEAL with the traced arguments. The item
the rehearsal could not cover therefore holds for 17 CPUs; 18 and 19
(bodytrack and vips at 16 threads) are read back when those runs start.

Estimates, not results: radix's runs simulate about 1.7 G instructions a
thread (13.7 G in all at 8 threads, 27 G at 16).
