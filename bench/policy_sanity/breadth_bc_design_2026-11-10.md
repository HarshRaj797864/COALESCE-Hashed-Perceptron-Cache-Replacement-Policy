# Parts B and C of the breadth plan: 15 programs at 4 and 8 cores against gem5, with stock ChampSim beside them. Pre-registered 2026-11-10, before any run

**Why** (owner, 2026-11-10; PLAN § 10 item 7). HiPC turned the paper down
partly for too little variety in testing. The breadth plan tests the tool
widely, in three parts, each pre-registered before any of its runs:
- **A**, equivalence with upstream (`upstream_equiv_design_2026-11-10.md`);
- **B**, the 15 multi-threaded programs at 4 and 8 cores against gem5
  ("first target to finish 4 and 8"; "we don't know which will agree or
  not": every program is reported, pass or fail);
- **C**, the improvement: the same programs on stock ChampSim (each thread a
  separate program), on ours, and on gem5.

This note is B and C. It is written before any 8-thread trace, 8-core gem5
run, stripped trace or stock run of these programs exists, and before any
number of theirs is read.

**What was read before writing** (server, read-only, 2026-11-10 13:26 UTC;
load 0, nothing of ours running, 130 GB free of 7.4 TB):
- the synchronised traces on the server: `sync_mx` (barnes256, barnesstd,
  canneal4, **canneal8, canneal16**, fmm, ocean4, radix, waternsq),
  `sync_nb` (fft, lu, lunc, radiosity, raytrace, streamcluster, volrend),
  `sync_h2` (bodytrack, facesim, fluidanimate, oceannc, streamcluster, vips).
  **Only canneal has synchronised traces at 8 threads.** 80-830 MB a
  program at 4 threads;
- the gem5 runs' durations at light load (config.ini to stats.txt): canneal
  at 8 workers (9 CPUs) **11.6 h and 14.6 h** for the 50 M and 150 M stops;
  canneal 4c 8.2-9.2 h; ocean 4c 2.8 h;
- each program's PROGS line (binary, arguments, inputs, traced threads,
  thread 0's cut) from `~/heldout2/PROGS`, `~/newbench/PROGS`, and
  `sync_server.sh`'s built-in lines; canneal's 8-worker gem5 command
  (`CANNEAL 8 15000 2000 100000.nets 128`, 9 CPUs).

## The 15 programs and where each stands at 4 cores (nothing changes here)

| program | source | 4-core status (procedure; primary measure R_g5) | counted at 4 cores as |
|---|---|---|---|
| ocean (contiguous) | SPLASH-3 | development; agrees, 0.682 (m2 traces, host CPUID, v1) | scored |
| ocean non-contiguous | SPLASH-3 | reported apart; agrees, 0.663 (set 2's procedure) | scored, apart |
| radix | SPLASH-3 | held out; agrees, 0.990 | scored |
| barnes (standard) | SPLASH-3 | development; force span 0.634 agrees, start / window 0.233 / 0.249 read low; under diagnosis (`disagree_diagnosis_design_2026-11-06.md`, round 2) | scored |
| LU non-contiguous (lunc) | SPLASH-3 | held out; agrees, 1.831 | scored |
| fft | SPLASH-3 | **unscored**: v1's same-stream check failed on units (gem5 counts memory micro-ops; S1 of `stream_fix_results_2026-11-04.md`) | **B1** |
| volrend | SPLASH-3 | **unscored**: v1's check failed (stores +1.1%, RMW +1.5%; run-to-run variation, H3) | **B1** |
| water-nsquared | SPLASH-3 | passes; not discriminating (414 gem5 events < 500); upgrades agree (U 0.953) | reported |
| raytrace | SPLASH-3 | passes; not discriminating (184 events); U_g5 0.924 | reported |
| fmm | SPLASH-3 | **unscored**: v1's check failed (stores 1.32x, RMW 1.37x; threads run unevenly under gem5) | **B1** |
| canneal | PARSEC | development; agrees, 1.016 at 4c **and 1.537 at 8c** (`sync_mx/canneal8`, gem5 9 CPUs) | scored, both counts |
| streamcluster | PARSEC | held out; agrees, 0.925 (set 2's procedure) | scored |
| fluidanimate | PARSEC | held out; reads low, 0.398; under diagnosis | scored |
| vips | PARSEC | held out; reads low, 0.309; under diagnosis | scored |
| bodytrack | PARSEC | fails QW (untraced threads 3.933% of the window); F-W (trace the main thread) is a candidate fix in the diagnosis plan | reported, failed QW |

Every scored 4-core result stands as scored, under the procedure it was
scored by. B adds points; it rescores nothing already scored.

## Part B

### B1: the three unscored 4-core points, under set 2's procedure

fft, volrend and fmm were never scored (no ratio of theirs was read). They
are traced and checked again by **set 2's procedure**
(`heldout2_design_2026-11-04.md`: the h2 tracer under gem5's CPUID, the
counter three times under gem5's CPUID and once under the host's, QC and
v2 with the native range), as streamcluster was by newbench amendment 3.
- **Traces:** new, by the h2 tracer (`~/sync_h2_build`, md5 02ff8f48) with
  `-cpuid ~/sync_nc/gem5.cpuid` and `-sync 1`; the voided nc traces
  (`traces/sync_nc_void_F2no`) are not reused. Threads 0-3; thread 0 cut at
  its anchor (`auto`); 215 M records a thread, with newbench amendment 2's
  lengths (fft and volrend: the whole run) and the length rule once.
- **gem5:** the existing runs (fft and volrend in `~/gem5_b3/newbench`, fmm
  in `~/gem5_b3/heldout`); gem5 does not read CPUID files and ran the
  static binary on the same input, so a new trace changes nothing on its
  side. QG reads their config.ini as before.
- **ChampSim:** `champsim_g6_1e3060c1`, LRU, 2 MB, level 2, shared, 50 M +
  100 M, into `phaseA_b3_b1_<p>4`.
- **Checks and score:** set 2's (Note 8's `heldout2_score.py`), with step
  4's predictions P8-P10 for these programs (they are step 4's programs).

### B2: 8 cores, the 14 programs without an 8-core point

canneal's 8-core point stands as scored. The other 14 are sized, traced,
counted and run at 8 threads, and gem5 runs them at one CPU a thread.

**How each program takes 8 threads** (recorded in a note here, before
sizing, with the exact PROGS line):
- SPLASH-3 by argument `-p8`: ocean, ocean-nc, radix, fft, lunc, raytrace;
  volrend's first argument; barnes, fmm and water-nsquared by the `NPROC`
  line of their input files (as `n16384-p4` holds it for barnes);
- PARSEC by argument: fluidanimate's first (a power of two: 8 is allowed),
  streamcluster's and bodytrack's last, vips `--vips-concurrency=8`.

**The ladder** of each program is its 4-thread ladder (newbench's, held-out
set 2's Note 2, or the B3 program's input list), **starting at the rung
chosen at 4 threads**, then the larger rungs in order. **The size rule is
unchanged:** the first rung on which every traced thread executes at least
300 M instructions; a program whose largest rung is below it is traced on
that rung and reported with its count. **E3 at 8 threads:** exactly eight
threads do the parallel work, each created once and living to the end (main
and helper threads counted, as before); a program that creates its workers
repeatedly, or not eight of them, is reported and excluded from B2.

**Traced threads:** SPLASH-3 threads 0-7 (thread 0 cut at its anchor, its
last `pthread_create`); fluidanimate, bodytrack, streamcluster 1-8; vips the
eight worker threads the probe identifies (3-6 were the four at 4 threads).

**Trace length:** 215 M records a thread; the per-program lengths of
newbench amendment 2 (lu's and raytrace's, fft's and volrend's whole run)
carry over, and the length rule applies once if QT fails for length.

**gem5:** MESI_Three_Level, TimingSimpleCPU, the same 2 MB shared cache,
the static binary, the same input. **CPUs:** one per thread the program runs
at once (SPLASH-3 8; fluidanimate and streamcluster 9; bodytrack 10; vips
as the probe counts, expected 11). **Stops:** when a worker reaches 50 M and
150 M (Note 3's worker slice: the traced threads' CPUs). **Time limit, fixed
now: 168 h** (canneal's 8-worker runs took 12-15 h at light load; the
server's load reached 120 in late October, 5-6x slower). A run that has
not ended by then is stopped; its program is reported, not scored.

**ChampSim:** `champsim_g6_1e3060c1`, LRU, **2 MB** (fixed, as canneal's
8-core point and every B3 run), level 2, shared, 50 M + 100 M a core, into
`phaseA_b3_b2_<p>8`.

**Procedure otherwise = set 2's:** the h2 tracer under gem5's CPUID; the
counter (`~/sync_h2_build`, md5 22776143) three times under gem5's CPUID
and once under the host's, each run as traced; the same files and checkers.

### Qualifying checks (as set 2's, at 8 threads; nothing new)

QB (the binaries are the ones that passed it; a program rebuilt for any
reason passes it again), QT, Q3 (no `SYNC DEADLOCK`, `VIEW-ORDER VIOLATIONS
UNEXPLAINED` 0, self-check and stale-holders 0), QG (both gem5 runs end at
their stop; config.ini shows the CPUs, the static binary, 2 MB,
randomization off, the worker stop), **QW** (untraced CPUs commit under 1%
of the traced CPUs' instructions in the window), **QC and v2 with the native
range** (1% / 5%; RMW 0.01 / 0.05 per 1,000; the held-out 8% rule for loads
and stores), **500 gem5 events** to discriminate. A program that fails a
check is reported with the check and not scored; no tolerance changes after
a number is seen.

### Predictions

For each program that passes every check and discriminates at 8 cores:
- **P18:** R_g5 in the band 0.5-2.
- **P19:** R_b >= R_g5.
- **P20:** the shared-cache demand-traffic ratio within 0.5-2.

For B1:
- **P21:** fft passes QC and v2 with the native range (S1 showed v2 removes
  its unit difference exactly on its workers; S2's miss was thread 0's
  serial start, which the anchor cuts away). volrend and fmm are reported;
  nothing is predicted for them.

Expected, not predicted: a program that agrees at 4 cores agrees at 8; one
that reads low reads low. Upgrades (U_g5) are reported, not predicted.

### How the outcomes are read

- Every program is reported at both core counts: scored (with its three
  ratios), failed (with the check), not discriminating (with the count), or
  excluded (with the reason).
- The paper's breadth statement counts the programs scored and
  discriminating at each core count, and says how many agree. Nothing is
  dropped to raise that count, and no program is tuned after a number is
  seen; a failure is diagnosed (the diagnosis plan continues in parallel,
  and any fix it pre-registers in its own note applies to B2's traces only
  if it lands before they are made, stated in an amendment here).

## Part C: stock ChampSim beside ours, both against gem5

**Stock ChampSim** is upstream `f9ed890e`'s own binary, Part A's frozen
`champsim_partA_up_<md5>`, not ours with switches off. It cannot replay sync
records (it would read them as stores to odd addresses), so it runs **the
same traces with the sync records removed**: `scripts/sync_strip.py` drops
every record whose second destination-memory field is the `SYNCSYNC` magic
(the base record included) and copies every other record byte for byte.
Its check, before any stripped trace is used: records out = records in
minus sync records; every kept record identical; and **C0** below.

**Three simulators on the same traces and windows:**
- **gem5:** B's runs (and the existing 4-core ones).
- **ours:** B's ChampSim runs and the existing scored 4-core runs
  (`champsim_g6_1e3060c1`, shared, level 2).
- **stock:** upstream's binary on the stripped traces, each core its own
  program: LRU, the same 2 MB LLC, 4 or 8 cores, 50 M + 100 M a core,
  Part A's configuration files `off_<c>_lru.json` (private regime, level 0,
  `rmw_as_rfo` 0; the same JSON upstream reads in Part A).
- **ours with the extension off:** our binary on the same stripped traces
  and the same JSON. **C0:** E1 (Part A's comparison) holds on every pair,
  so stock's numbers can be read from either log. This extends Part A's
  claim from SPEC to the paper's own programs.

**Measures,** per program and core count, per 1,000 instructions of
ChampSim's measured window (the ROI block) against gem5's window (the
50 M-to-150 M stops), each as a ratio simulator / gem5:
- **M1, demand traffic:** ChampSim's LLC accesses less writebacks, over
  gem5's L2 demand accesses (`m_demand_accesses`): P17's measure.
- **M2, memory traffic:** ChampSim's LLC load + RFO misses, over gem5's L2
  demand misses (`m_demand_accesses - m_demand_hits`).
- **Sharing:** a store miss that finds another core's copy is 0 in stock by
  construction (every core has its own memory); stock has no R. That is
  reported as the construction, not as a measure.

**Predictions,** over the programs scored and discriminating in B at that
core count:
- **C1 (primary):** on M2, ours is at least as close to gem5 as stock:
  |ln(M2_ours)| <= |ln(M2_stock)|, for at least two thirds of those
  programs at each core count.
- **C2:** the same on M1, reported with its count.
- **C0:** E1 holds on all 30 pairs (15 programs x 2 core counts; bodytrack's
  and any excluded program's pairs run and count in C0 whatever B decides).

The direction of stock's error (replicated read-only data filling the LLC
n times; no invalidation misses) is reported per program, not predicted.

**Runs:** 30 stock + 30 ours-off, LRU, 2 MB, on the stripped traces, into
`results/partC/<p>_<cores>.<up|oursoff>.log`, by a runner of Part A's kind
(the frozen Part A binaries by name; a log counts as done only with its
binary's sidecar).

## Order, and what is built before anything runs

1. This note, committed.
2. **`scripts/sync_strip.py`** and its check (a hand-made trace with known
   sync records; a real 4-thread pair on the laptop: `ocean4`'s sync traces
   stripped, then upstream `f9ed890e` against ours-off, E1 by
   `upstream_equiv.py`).
3. **B's runner** (`scripts/partB_all.sh`, server side `partB_server.sh`;
   the existing pieces reused: `heldout2_server.sh`'s probe and sizing,
   `sync_server.sh`'s h2 variant for tracing, `streamfix_server.sh`'s
   counter runs, the gem5 runners with the worker stop), in modes:
   `size` (8-thread sizing, E3, QB; gem5 launched per sized program),
   `trace` (B1 then B2, two programs at a time), `count`, `status`,
   `pull`. Each program's PROGS lines, ladders and gem5 CPU counts are
   recorded in a note here before `size` runs on the server.
4. **C's runner** (`scripts/partC_all.sh`, `partC_server.sh`), after B's
   traces exist.
5. **Scoring:** `heldout2_score.py` takes the thread count from PROGS (E3 =
   8 workers, QW over the traced CPUs); `b3_score.py` gains blocks
   `b1@set2` and `b2@set2`; a new `scripts/partC_score.py` (M1, M2, C0-C2)
   with a self-test on hand cases. Committed before any ratio of B or C is
   read.
6. Each runner rehearsed against the stand-in server; **launched only on the
   owner's word**; server order: A's chain (first), then B's sizing and gem5
   runs (the long pole, independent of traces), then B's traces, counter and
   ChampSim runs, then C.

**Estimates, stated now:** gem5 28 new runs at 8-11 CPUs (14 programs x 2
stops), 12-15 h each at light load, run in parallel: 1-4 days; Pin 14 x 8
threads plus B1's 3 x 4; counter 17 x 4 runs; ChampSim 17 of ours (8-core
~6-12 h each), 60 of C's. Disk: 8-thread traces about twice the 4-thread
sizes, ~10-15 GB; 130 GB are free.

**Disclosed:** the LLC stays 2 MB at 8 cores (as every validation run); 16
cores are not part of B; gem5's timing (an in-order CPU) is not compared,
only its memory-side counts.

## Amendment 1, 2026-11-11: 16 cores (B16, and C at 16), before any runner of B exists and before any 16-thread trace or 16-CPU gem5 run of these programs

**Owner, 2026-11-11: "we will do 16 cores as well".** The last line of this
note ("16 cores are not part of B") is replaced by this amendment. Nothing
of B1, B2 or C at 4 and 8 cores changes.

**Why 16 and no further:** a cache block's sharer mask is a `uint16_t`
(`inc/block.h`), so 16 cores is the tool's limit as built. It is stated in
the paper as the limit; widening it is a later change with its own checks.

### B16: the 15 programs at 16 threads against gem5

- **Programs:** all 15. No 16-thread point of any of them has been scored.
  canneal has 16-thread synchronised traces (`sync_mx/canneal16`, made
  2026-10-19 for step 5) and no 16-worker gem5 run.
- **canneal** keeps the procedure its 4- and 8-core points were scored by
  (the `sync_mx` traces, the host's CPUID, the v1 same-stream check), so its
  three points are comparable; only its gem5 runs are new
  (`CANNEAL 16 15000 2000 100000.nets 128`, 17 CPUs).
- **The other 14** follow B2 exactly, with 16 in place of 8: how each takes
  its threads (`-p16`, `NPROC 16`, the PARSEC arguments; fluidanimate's
  count must be a power of two, 16 is one); **the ladder starts at the rung
  chosen at 8 threads**; the size rule (every traced thread at least 300 M
  instructions; else the largest rung, reported with its count); **E3 at 16:
  exactly sixteen threads do the parallel work, each created once**; a
  program that cannot is reported and excluded from B16.
- **Traced threads:** SPLASH-3 0-15 (thread 0 cut at its anchor);
  fluidanimate, bodytrack, streamcluster 1-16; vips the sixteen workers the
  probe identifies. 215 M records a thread; the length rule once.
- **gem5:** as B2. CPUs: SPLASH-3 16; canneal, fluidanimate and
  streamcluster 17; bodytrack 18; vips as the probe counts (expected 19).
  Stops at 50 M and 150 M of a worker. **Time limit, fixed now: 240 h.** A
  run not ended by then is stopped; its program is reported, not scored. If
  gem5 cannot build or start a system of that many CPUs under
  MESI_Three_Level, the program is reported with gem5's message.
- **ChampSim:** `champsim_g6_1e3060c1`, LRU, **2 MB** (fixed, as every
  validation run; the 2 MB-a-core geometry is the policy study's, not the
  validation's), level 2, shared, 50 M + 100 M a core, into
  `phaseA_b3_b16_<p>16`.
- **Checks:** B2's (QB, QT, Q3, QG, QW, QC and v2 with the native range, 500
  gem5 events), at 16 threads, and one new check:
- **Q16, the mask's last bits, before any 16-core ratio is read.**
  `bench/coherence_micro.c` gains a thread count and an actor offset: at 16
  threads the four acting threads are threads 12-15 and the other twelve
  only wait, so every case's hand count is the 4-thread one. One new case,
  `s16`: all sixteen threads read the round's line, then thread 15 writes
  it (hand counts written in a note before it runs: 16 holders, then 15
  copies invalidated by one store, a round). Pass: ChampSim meets every hand
  count exactly at levels 0, 1, 2 on the g6 sources; a 16-CPU gem5 run of
  the same program agrees as the 4-thread micro test did (within 1 wherever
  nothing leaves a cache). If Q16 fails, no 16-core point is scored until
  the cause is found and fixed under its own note.

**Predictions,** for each program passing every check and discriminating at
16 cores:
- **P22:** R_g5 in the band 0.5-2.
- **P23:** R_b >= R_g5.
- **P24:** the shared-cache demand-traffic ratio within 0.5-2.

Expected, not predicted: a program agreeing at 4 and 8 agrees at 16; the
lock-heavy and thread-pool programs (barnes, fluidanimate, vips, bodytrack)
do not, unless the diagnosis lands a fix first. Each program's R_g5 at 4, 8
and 16 cores is reported as a series; no trend is predicted.

### C at 16 cores

Stock ChampSim and ours-off on the stripped 16-thread traces, LRU, 2 MB,
`off_16_lru.json`: 15 more pairs for **C0** (45 in all); **C1 and C2** at 16
cores as at 4 and 8, over the programs scored and discriminating there. Logs
`results/partC/<p>_16.<up|oursoff>.log`.

### Order and estimates

Sizing runs once for 8 and 16 threads; each sized program's gem5 runs start
at once (8-thread first). The gem5 queue holds 58 runs (28 at 8 threads, 30
at 16) and runs at most 24 at a time. Estimates, stated now: a 16-17 CPU
gem5 run about twice an 8-9 CPU one (25-30 h at light load; several days
under load); 16-thread traces about four times the 4-thread sizes (20-30 GB
in all, 130 GB free); 15 ChampSim runs of 12-36 h; 60 counter runs.

**Disclosed:** the LLC stays 2 MB at 16 cores; canneal's 16-core point is
scored by the older procedure; the stock runs at 16 cores are 16 separate
programs by construction.

## Amendment 2 (Note 1), 2026-11-11: the sizing recipes at 8 and 16 threads, before any sizing run

The design asked for this note before `size` runs: each program's line, its
ladder and its gem5 CPU count. Read for it, on the server and read-only: the
4-thread lines (`~/heldout2/PROGS`, `~/newbench/PROGS`, `sync_server.sh`),
the input files that hold a thread count (`n16384-p4`, `fmm.in`,
`waternsq.in`), where each dynamic and static binary is, and the 4-thread
probes' thread lists. No 8- or 16-thread run of any kind exists.

**The binaries are the ones that passed QB at 4 threads.** The thread count
is an argument or an input line in all 15, so nothing is rebuilt. Each
key's record holds both binaries' md5.

N is 8 or 16. A *key* is `<program>_<N>`.

| program | dynamic binary (Pin) | static binary (gem5) | N enters as | ladder, smallest first |
|---|---|---|---|---|
| ocean | `splash-3/.../ocean/contiguous_partitions/OCEAN` | `~/splash-static/OCEAN` | `-pN` | `-n514`, `-n1026`, `-n2050` (each with `-e1e-7 -r20000 -t28800`) |
| oceannc | `~/heldout2_build/oceannc/OCEAN.dyn` | `~/heldout2_static/OCEAN-NC` | `-pN` | as ocean |
| radix | `~/b3_heldout_build/radix/.../RADIX.dyn` | `~/splash-heldout/RADIX` | `-pN` | `-n16777216`, `-n33554432`, `-n67108864`, `-n134217728` (each with `-r1024`) |
| barnes | `~/barnes_std_build/.../BARNES` | `~/splash-static/BARNES` | the last line of its input | bodies 16384, 65536, 262144 (SPLASH-3's `n16384-p4` with those two lines changed) |
| lunc | `~/newbench_build/lunc/.../LU.dyn` | `~/splash-newbench/LU-NC` | `-pN` | `-n1024`, `-n2048`, `-n4096` (each with `-b16`) |
| fft | `~/newbench_build/fft/.../FFT.dyn` | `~/splash-newbench/FFT` | `-pN` | `-m22`, `-m24`, `-m26` |
| volrend | `~/newbench_build/volrend/.../VOLREND.dyn` | `~/splash-newbench/VOLREND` | its first argument | `N head 4`, `N head 16`, `N head 64`, `N head 256` (rotation steps) |
| waternsq | `~/b3_heldout_build/waternsq/.../WATER-NSQUARED.dyn` | `~/splash-heldout/WATER-NSQUARED` | the first number of its input's third line | time steps 8, 16, 32, 64 (the third number of the first line; 512 molecules throughout) |
| raytrace | `~/newbench_build/raytrace/.../RAYTRACE.dyn` | `~/splash-newbench/RAYTRACE` | `-pN` | `-m128 balls4.env`, then the same with `-a2`, then `-a4` (antialiasing: more rays; SPLASH's recommended run has none, so a rung above the first is disclosed) |
| fmm | `~/b3_heldout_build/fmm/.../FMM.dyn` | `~/splash-heldout/FMM` | the fifth line of its input | particles 16384, 65536, 262144 (the third line) |
| streamcluster | `~/newbench_build/streamcluster/src/streamcluster.dyn` | `~/splash-newbench/streamcluster` | its last argument | `10 20 128 P P 1000 none out.txt N` with P = 16384, 65536, 262144 |
| fluidanimate | `~/heldout2_build/fluidanimate/fluidanimate.dyn` | `~/heldout2_static/fluidanimate` | its first argument | `N 5 in_35K.fluid`, `N 5 in_100K.fluid`, `N 5 in_300K.fluid`, `N 20 in_300K.fluid` (PARSEC's simsmall, simmedium, simlarge; then simlarge with 20 frames) |
| vips | `~/heldout2_build/vips/vips.dyn` | `~/heldout2_static/vips` | `--vips-concurrency=N` | simsmall, simmedium, simlarge (`pomegranate_1600x1200.v`, `vulture_2336x2336.v`, `bigben_2662x5500.v`) |
| bodytrack | `~/heldout2_build/bodytrack/bodytrack.dyn` | `~/heldout2_static/bodytrack` | its last argument | `sequenceB_2 4 2 2000 5 0 N` (simmedium, chosen at 4 threads), `sequenceB_4 4 4 4000 5 0 N` (simlarge) |
| canneal (16 only) | not traced again | `~/splash-static/CANNEAL` | its first argument | none: `16 15000 2000 100000.nets 128`, the arguments of `sync_mx/canneal16` |

**The ladders are extended upward here, once, before any run** (the design
named the 4-thread ladders; ocean, oceannc, radix, barnes, waternsq and fmm
had a single rung at 4 threads, and at 16 threads a thread does a quarter
of the work). New rungs: ocean / oceannc 1026 and 2050; radix's three
larger key counts; barnes and fmm at 65536 and 262144; lunc 4096; volrend
256; waternsq's time steps; raytrace's antialiasing; fluidanimate's 20
frames. The first rung at 8 threads is the one chosen at 4; the first at 16
is the one chosen at 8. A rung that fails to run (memory, a program limit)
is reported and skipped.

| programs | threads the run creates | traced threads | gem5 CPUs | gem5's worker stop watches |
|---|---|---|---|---|
| the ten SPLASH-3 programs | N | 0 .. N-1 (thread 0 cut at its anchor) | N | CPUs 1 .. N-1 |
| canneal, streamcluster, fluidanimate | N + 1 | 1 .. N | N + 1 | CPUs 1 .. N |
| bodytrack | N + 2 (its loader thread last) | 1 .. N | N + 2 | CPUs 1 .. N |
| vips | N + 3 (threads 1 and 2 idle at 4 threads) | 3 .. N+2 | N + 3 | CPUs 3 .. N+2 |

**E3** is checked against the "threads the run creates" column; a different
count fails E3 and the key is reported, not sized. For vips the probe must
also show threads 1 and 2 under 1 M instructions each, as at 4 threads;
otherwise its traced threads are not the ones assumed and the key fails E3.

**radix's skip.** At 4 threads its traces and gem5 stops skip the key
generation before the first barrier (780 M a thread). At N threads the skip
is **the largest count any traced thread has at its first
`pthread_barrier_wait`, rounded up to the next 10 M** (read from the
probe). E5 for radix is: every traced thread executes at least the skip
plus 300 M. Its gem5 stops are the skip plus 50 M and plus 150 M of a
worker; its trace skips that many instructions a thread, as at 4.

**gem5 for these runs:** the settings of every earlier run
(MESI_Three_Level, TimingSimpleCPU, the same three cache levels, 2 MB,
randomization off, the same runner and `run_one`), with two differences,
both outside every measure: `--mem-size=16GB` (4 GB before; the larger
rungs need it), and the time limit (168 h at 8 threads, 240 h at 16). The
program's files are copied into the run's directory as for held-out set 2.

**The queue:** `scripts/partB_server.sh` sizes eight keys at a time (Pin
runs) and a separate driver starts each sized key's two gem5 runs,
8-thread keys first, at most 24 gem5 runs at once. Outputs:
`~/partB/<key>/` (the probe's files, `CHOSEN`, `NCPU`, `PROGS`, `JOBS`,
`GEM5`, `SIZED`) and `~/gem5_b3/partB/<key>/l2_2MB_mi<stop>M/<key>c/`.

Tracing, the counter runs, the ChampSim runs and Q16 follow in later notes
(the trace chain needs a variant of `sync_server.sh`); none of them starts
from this note.

## Amendment 3, 2026-11-11: corrections to Note 1 found while building and rehearsing the runner; before any sizing run

Nothing of Part B has run on the server. Read there for this amendment,
read-only: the dynamic symbols of five binaries (`nm -D`), the thread lines
of the five 4-thread probe files, the md5 of every binary and input the
runner names. Run on the laptop: a real SPLASH-3 radix under the probe's
source, and real barnes, fmm, water-nsquared, raytrace and volrend natively.

1. **radix's skip.** Note 1's rule read a `pthread_barrier_wait` that
   SPLASH-3 never calls: its barrier (`pthread.m4.stougie`) is a mutex and a
   condition variable, and `RADIX.dyn` on the server holds no such symbol
   (nor do OCEAN, FFT.dyn and BARNES). The last thread to arrive releases
   the barrier with `pthread_cond_broadcast`, which the probe records.
   **The rule is now: the skip is the instruction count of the traced
   thread that makes the run's first `pthread_cond_broadcast`, rounded down
   to 10 M.** Applied to the 4-thread measurement of 2026-10-14 (workers
   780.14 M, thread 0 780.31 M) it gives the 4-thread skip, 780 M; Note 1's
   "rounded up" would have given 790 M. E5 for radix and gem5's stops stand
   as in Note 1 (skip + 300 M; skip + 50 M and + 150 M). radix's thread 0
   is not cut at an anchor (its line's start is 0, as at 4 threads): the
   skip covers its serial start.
   - Checked on a real radix (SPLASH-3 built on the laptop with the same
     macros, under the probe's source): at 4, 8 and 16 threads with
     2,097,152 keys the first broadcast comes after 186.0 instructions a key
     (97.5, 48.8, 24.4 M), the figure the server's 4-thread run gives (780.1
     M for 4,194,304 keys a thread); the sort is about 54.6 a key.
   - From these, by arithmetic and not from any sizing run: the first rung
     with 300 M of sort a thread should be 67,108,864 keys at 8 threads and
     134,217,728 at 16, each with a skip of 1,560 M. Written down so that it
     can be seen to fail.
2. **streamcluster creates its workers twice:** N for the stream's one
   chunk and, when they have ended, N for the final clustering of the
   centres (`localSearch` at lines 1916 and 1955 of `streamcluster.cpp`). So
   it creates 2N + 1 threads, not the N + 1 of Note 1's table. It was traced
   so at 4 threads (step 4: "the first four created threads").
   - E3 for streamcluster: 2N + 1 thread starts, the second N started only
     after the first N have ended. Traced: the first N. gem5: N + 1 CPUs, as
     at 4 threads (a thread that has ended frees its CPU).
   - The design's sentence "a program that creates its workers repeatedly
     ... is reported and excluded" is not applied to these two sets. The
     exception is written before any 8-thread run, from the source, and
     keeps streamcluster at 8 and 16 threads as it was at its scored
     4-thread point.
3. **E3 counts thread starts, not only thread numbers.** Pin's
   documentation allows a thread number to be given again after its thread
   has ended, and then the numbers alone could not show workers created
   again. E3: thread starts = thread numbers = the recipe's count
   (streamcluster: 2N + 1 starts; N + 1 or 2N + 1 numbers). The five
   4-thread probe files hold as many starts as numbers (5, 6, 7, 4, 4), so
   nothing at 4 threads changes.
4. **Pin numbers threads in the order they start, not the order they are
   created.** Seen in the rehearsal: a stand-in's seventeenth-created thread
   took number 14. vips creates its two idle helpers and its workers within
   19,000 instructions (its 4-thread probe file), so on a loaded machine a
   helper can be numbered after a worker.
   - vips's E3 is therefore: exactly two threads besides main execute under
     1 M instructions. Its workers are the N others, whatever their numbers;
     E5 is read on them. A run whose idle threads are not 1 and 2 gets a
     NOTE. Its line for the trace chain keeps threads 3 to N + 2 (creation
     order, which gem5's CPUs follow); at trace time QT refuses the trace of
     an idle thread (it is far under 215 M records).
   - Every run prints each untraced thread's count, with a NOTE when one of
     them (main aside) executes more than the least traced thread.
     bodytrack's loader is created after its model is loaded
     (`main.cpp:222-234`), well after its pool.
   - A NOTE decides nothing. Each is read before its key is used.
5. **The queue:** eight keys at a time at 8 threads, four at a time at 16
   (64 program threads either way). A 16-thread key whose 8-thread key was
   not sized starts at the ladder's first rung.
6. **gem5's time limit** is applied through `timeout`, and the runner
   records its exit status in the run's `limit.rc`: 124 means stopped by the
   limit, and such a run is never started again. A run that died otherwise
   (gem5's own exit, or the machine's) is reported, and a new command starts
   it from the beginning with a new limit.
7. **Records per key** (`~/partB/<key>/`): `CHOSEN`, `NTHR`, `NCPU`, `SKIP`,
   `MIN` (the least traced thread's count), `BELOW` (only when under the
   size rule), `MD5`, `PROGS`, `JOBS`, `GEM5`, `probe_chosen.txt`, `SIZED`;
   or `FAILED_E3` with the reason.

## The runner of Part B's first stage, and its rehearsal (2026-11-11)

`scripts/partB_all.sh` (laptop: upload, then `status`, `check`, `pull`,
`stop`), `scripts/partB_server.sh` (server: `plan`, `guards`, `go`, `size`,
`gem5`, `status`, `check`, `stop`), and `run_gem5_splash.sh go-pb` (one
key's run from its `GEM5` line, through the same `run_one` as every earlier
gem5 run). It builds nothing and writes only under `~/partB` and
`~/gem5_b3/partB`.

**Guards, before anything starts:** G1 the 14 dynamic and 15 static
binaries are the ones read on 2026-11-11 (md5 in the script's table; static
ones statically linked); G2 the three stdin inputs have the shape
`gen_stdin` edits, at 4 threads it reproduces each byte for byte, and
barnes's at 8 and 16 equal SPLASH-3's own `n16384-p8` and `-p16`; G3 every
input file a ladder names exists; G4 Pin and the probe of held-out set 2
(md5 `f8af3b0b`); G5 30 GB free; G6 the runner on the server has `go-pb`.

**Rehearsed against a stand-in server** (the launcher through a stand-in
ssh; real Pin; the probe built from its source; one stand-in program a
family, which parses each program's real arguments or stdin and executes a
set number of instructions a thread; a stand-in gem5 that writes a
config.ini from its options). Nothing here is a result.

- **Sizing, 28 keys: every outcome equals the one worked out by hand
  beforehand.** Covered: the first rung chosen; two to four rungs climbed;
  a rung that does not run, skipped (fft at 8 threads); no rung meeting E5,
  so the largest taken and marked BELOW (lunc at 8 and 16, radix at 16);
  E3 failing on every rung, so the key not sized and no gem5 run (fmm at
  16); the 16-thread ladder starting at the 8-thread rung; radix's skip at
  190, 390, 780 and 1,560 M, each as computed by hand.
- **An independent recomputation** (a separate Python reader of each key's
  probe file): 437 comparisons with the runner's records, 0 mismatches; a
  planted wrong skip is found.
- **Unit cases:** vips with its thread numbers out of creation order (sized
  as before, with the NOTE); vips with a busy helper (E3 fails, not sized);
  bodytrack with its loader started before a worker (the NOTE names the
  untraced thread); streamcluster's second set started early (E3 fails);
  radix without a barrier (not sized); a program that creates its workers
  twice (E3 fails; its 16-thread key then starts at the first rung).
- **gem5 queue:** 56 runs, never more than the cap at once (6 in the
  rehearsal); every config.ini equals its key's line (CPUs, worker slice,
  stop) and shows 2 MB, 16 GB, randomization off. A run that dies is
  reported and started again only by a new command (the old directory kept
  as `.prev_*`); a run stopped by its limit is not started again; ended
  runs are skipped.
- **Guards:** nine injected faults each refused, nothing started (a changed
  binary, a dynamic binary in a static one's place, two malformed inputs, a
  missing input file, another probe, a runner without `go-pb` twice, too
  little disk).
- **Launcher:** the uploads checked by md5; a second launch refused while
  the first runs; `stop` ends the sizing and the driver and leaves gem5's
  runs (4 running, 4 after); a second `stop` finds nothing; a relaunch
  skips the 15 keys sized already and completes; `pull` brings the records.
- **Real programs, natively, at 8 and 16 threads with the runner's own
  inputs:** barnes (its output shows nbody 16384 / 65536 and NPROC 8 / 16),
  fmm ("Starting FMM with 16 processors"), water-nsquared ("Using 16 procs
  on 16 steps of 512 mols"), raytrace `-a2` ("Samples per pixel: 2"),
  volrend.
- **Three defects found and fixed before the commit:** the gem5 count read
  double (the line of `timeout` holds gem5's words too); a run that had died
  was taken for one stopped by its limit once the limit's time had passed
  (hence `limit.rc`); the pull left out `NTHR`.
- **Not rehearsed, because only the server can show it:** real gem5 with
  16 GB of memory and 16 to 19 CPUs. `check` reads each started run's
  config.ini back within minutes of the launch.

**Next:** `scripts/partB_all.sh` on the owner's word. Tracing, the counter
runs, the ChampSim runs, Q16 and part C each follow in their own note.

## Amendment 4 (Note 2), 2026-11-12: Part B's traces, ChampSim runs and counter runs, with B1 folded in; before any trace of Part B exists

Sizing is done (`partB_sizing_results_2026-11-11.md`; 28 of 28 keys).
gem5's runs started 2026-11-11. No Part B trace, ChampSim run or counter
run exists. Every number below comes from sizing's records, not from any
measurement of the B3 ratios.

**Decided (2026-11-12): streamcluster stays at 8 and 16 threads**, traced
on its first N workers. The owner left the choice to me. The reasons: it
is the procedure its 4-thread point was scored by (`heldout2_sc_results_2026-11-07.md`,
P8-P10 held); its second worker set executes under 15,000 instructions a
thread in sizing; and QW on gem5's CPUs reads whatever those threads do in
the window. Amendment 3's exception stands as written.

### The keys

- The 28 sized keys (14 programs at 8 and 16 threads), from sizing's
  `PROGS` and `JOBS` lines (`~/partB/<key>/`).
- **B1, three 4-thread keys, run by this same procedure:** `fft_4` and
  `volrend_4` from step 4's lines (`~/newbench/PROGS`: the same binaries
  and arguments, the whole run), and `fmm_4` from the held-out set's (FMM.dyn,
  `~/b3_heldout/inputs/fmm.in`). Thread 0 is cut at its anchor (`auto`)
  for all three, as B1 states; fmm's old numeric cut (12,773,531, from the
  pre-synchronisation anchor) is not used. Their gem5 runs are the existing
  ones; their ChampSim runs go to `phaseA_b3_b1_<p>4`.
- **canneal_16** has its traces (`sync_mx/canneal16`) and its ChampSim run
  (step 5's LRU, fixed 2 MB, shared, level 2, on the g6 binary). Nothing
  of it is traced or run again.

### Tracing

- **Tracer:** h2's (`~/sync_h2_build`, md5 02ff8f48; QS, QK and QZ held)
  for every key, under gem5's CPUID (md5 74d72229, the file QE held for),
  `-sync 1`, without `-start0`. B2 names this tracer.
- **Threads with a FIFO:** 0 to the larger of 15 and NTHR - 1 + 4 (NTHR =
  the threads the sizing run started; 4 to spare). A thread numbered beyond
  writes a plain file: it is removed and the key fails, never used.
- **First length a thread:** fft and volrend the whole run (newbench
  amendment 2: thread 0's set-up is 2-5 G instructions). A key whose
  thread 0 is cut: thread 0's last `pthread_create` in sizing's probe run
  + 215 M, rounded up to 5 M, at least 215 M. **This amends B2 / B16's
  first length** (215 M) for these keys: it is the length rule's value
  computed beforehand, so a 16-thread trace is not made twice when its
  thread 0's set-up alone is longer than QT allows. Sizing ran under the host's CPUID, so the
  trace's anchor may sit a few M away (fft's libm moved 16.7 M at 4
  threads), and the 42.5 M between 215 M and QT's 172.5 M absorbs that.
  Others: 215 M (radix after its skip of 1,560 M).
- **Then the length rule once, unchanged:** if QT fails for length, the
  trace's own anchor + 215 M rounded up to 5 M; a key without an anchor,
  the whole run.

| key | thread 0 | its last create in sizing | first length |
|---|---|---|---|
| barnes_8, barnes_16 | cut | 41.5 M | 260 M |
| fft_8, fft_16 | cut | 4,961.4 M | whole run |
| fmm_8, fmm_16 | cut | 50.1 M | 270 M |
| lunc_8 / lunc_16 | cut | 92.5 / 369.3 M | 310 / 585 M |
| ocean_8 / ocean_16 | cut | 0.6 / 1.0 M | 220 M |
| oceannc_8, oceannc_16 | cut | 7.6 M | 225 M |
| raytrace_8, raytrace_16 | cut | 184.7 M | 400 M (step 4's value) |
| volrend_8, volrend_16 | cut | 2,076.4 M | whole run |
| waternsq_8 / waternsq_16 | cut | 14.6 / 17.9 M | 230 / 235 M |
| radix_8, radix_16 | not cut (skip 1,560 M) | -- | 215 M |
| streamcluster, fluidanimate, bodytrack, vips (8 and 16) | not traced | -- | 215 M |
| fft_4, volrend_4 | cut | -- | whole run |
| fmm_4 | cut | -- | 215 M, then the rule |

- **QT** as before: every traced thread holds 172.5 M instructions after
  its cut.
- **Order and load:** the 4- and 8-thread keys traced two at a time (each
  a Pin process and an xz per thread, at nice 10); their ChampSim runs
  start as that group ends; the 16-thread keys traced one at a time; their
  runs. A key that fails holds back no other.

### ChampSim runs

`champsim_g6_1e3060c1` (the binary that passed Q0 and Q0m), LRU, fixed
2 MB, level 2, shared, 50 M + 100 M a core, as every B3 run. Trees
`phaseA_b3_b1_<p>4`, `phaseA_b3_b2_<p>8`, `phaseA_b3_b16_<p>16`. At most
10 at a time a group (4 and 8 threads; 16), at nice 19. A run starts only
from traces that passed QT. At the chain's end, Q3 is printed per run
(unexplained view-order violations 0); it decides nothing before scoring.

### Counter runs

h2's counter (md5 22776143; QR held), as set 2's Note 7: QE first
(cpuid_dump under the counter with gem5's CPUID, the QE rule), then four
runs a key, gem5's CPUID three times and the host's once, 124 in all.
- Each run is the traced run: same binary, arguments, stdin and input
  files (copied with `cp -r`), `-skip` = the key's skip.
- Thread 0's base: `-cut0 1` where thread 0 is cut (its last
  `pthread_create`, as streamfix counted step 4's programs); `-cut0 0`
  elsewhere.
- Window 50-150 M; address randomisation on; 12 h limit; retried once.
- Three at a time for 4- and 8-thread keys, two at 16, at nice 10. They
  start when the chain's tracing ends, so Pin runs do not pile up.
- Into `~/sync_pb/count/runs/<key>__<gem5|host>__<k>/`; structure checks
  only (exit 0, the options, a file for every traced thread). **No rate is
  read before the scoring note (Note 3).**

### Guards, before anything starts

h2's tracer and counter are the builds that passed QZ and QR; gem5's CPUID
has the QE md5 (copied to `~/sync_pb`, never replaced); the g6 binary
passed Q0 and Q0m; each key has exactly one trace line and one run line;
each key's binary is the file sizing read, unchanged (B1: the same file
as the program's 8-thread key), and its inputs exist; 3 + 14 + 14 keys;
sizing is not running; 60 GB free (each trace then needs 20 GB).

**Disk, estimated from the 4-thread sets (0.1-0.8 GB each):** 25-40 GB in
all, most of it fft's and volrend's whole runs (about 3 GB a key).

**Server side:** `VARIANT=pb` of `sync_server.sh`, uploaded as
`~/sync_server_pb.sh` (the running chains keep their files). Modes:
`guards`, `chain` (detached), `count` (detached; the chain starts it),
`status`, `stop`, `countstop`. Laptop: `scripts/partB_all.sh trace`
(upload, guards, chain; it refuses unless `~/sync_anchor.py`,
`~/sync_cut.py` and `~/trace_mix.c` on the server equal the committed
files), `tstatus`, `tpull` (trace reports, run logs, counter files; nothing
read), `tstop`, `countstop`.

**Rehearsed 2026-11-12, against a stand-in server on the laptop** (real Pin,
h2's tracer and counter built from these sources, real SPLASH-3 and PARSEC
binaries on small inputs with keys sized by the real probe, ChampSim built
from these sources standing in for the g6 binary; lengths scaled down:
3 M a thread, QT 2 M, the rule's addend 3 M, runs 0.5 M + 1.5 M):
- 7 keys (`fft_4`, `fmm_4`, `fmm_8`, `radix_8`, `lunc_8`,
  `streamcluster_8`, `ocean_16`): all traced, QT held; `fmm_4` took the
  length rule once (first trace 0.9 M after its cut; again at 10 M, cut at
  its anchor 2,086,584); `lunc_8`'s first length came from its probe (30 M,
  anchor 22.5 M); `fft_4` the whole run; `radix_8` from its skip.
- 7 of 7 ChampSim runs complete in `phaseA_b3_b1_*`, `_b2_*`, `_b16_*`;
  **Q3 holds in 7 of 7** (unexplained 0).
- QE held under the counter (354 lines equal, 14 abort pairs); **28 of 28
  counter runs exited 0** with the options and thread files named here
  (`-cut0 1` for cut keys).
- A relaunch of the finished chain does nothing ("nothing left to do"); the
  counter refuses to run again ("done").
- **Ten guard faults, each refused with its own message:** the tracer's md5,
  gem5's CPUID md5, a replaced `~/sync_pb/gem5.cpuid`, a binary changed since
  sizing, a key without NTHR, sizing still running, the key count, the disk,
  QZ not passed, a B1 binary that is not the one sizing read. The unfaulted
  copy passes.
- **Two chain faults:** `streamcluster_8` with NTHR 2 (its second worker set
  has no FIFO): FAILED, the stray `raw16` trace removed, nothing run;
  `lunc_8` without sizing's probe file: first trace too short to hold its
  anchor, so the rule's "no anchor: the whole run", then cut at 22,494,381.

## Amendment 5, 2026-11-12: Q16's procedure and hand counts, before the program has run at 16 threads anywhere

Amendment 1 names Q16: the micro program at 16 threads, its four acting
threads on 12-15, and a 16-holder case, exact, before any 16-core ratio is
read. This fixes how it is built, run and judged.

**The program.** `bench/coherence_micro.c` gains two build settings: `NT`
(threads, default 4) and `ACT0` (the first acting thread, default 0). In
round j the roles are A = ACT0 + (j % 4), B, C, D the next three (mod 4
within ACT0 .. ACT0 + 3); every other thread takes no role and only waits,
so it never touches X_j. With the defaults the schedule and roles are the
program's as it was (its start line prints two more numbers). Q16 builds it
with `-DNT=16 -DACT0=12`. One new case:
- **s16:** EVERY thread loads X_j; the wait; thread NT - 1 (15) stores X_j.

The small hierarchy, the 4 rounds, the control (pp_lock with 0 rounds) and
the counting (the run minus the control, on the X lines, from the per-request
event log) are the micro test's (`micro_design_2026-10-17.md`).

**ChampSim, on the laptop, on the g6 sources (`1b56891`, built in a scratch
tree), LRU, shared, levels 0, 1 and 2, 16 cores, two forms:**
1. timed waits, traced without sync records (the micro test's form);
2. `-DBARRIER_STEPS`, traced with `-sync 1` (Q2's form: a real barrier
   after every step, now with sixteen arrivals).

**Hand counts, per round (x 4), on the X lines.** The ten cases: the micro
test's table at level 2 (P, A, B, U); at level 0, pp_lock, pp_store and
pp_rmw read P = A = B = 1 and upgrade reads U = 0, the rest as at level 2; at
level 1 (an RFO invalidates the others' copies, no upgrade), as level 2
except upgrade, U = 0. s16:

| s16, per round | level 0 | level 1 | level 2 |
|---|---|---|---|
| P, A, B (store misses finding another core) | 0 | 0 | 0 |
| U (upgrades finding another core) | 0 | 0 | **1** |
| the other cores that upgrade finds (protocol view; gem5-rule view) | 0 | 0 | **15; 15** |
| private copies invalidated on X_j | 0 | 0 | **15** |

Why 15 copies, not 30: the wait after the loads chases 16 ring lines through
each 8-way L1D set, so every reader's X_j is left only in its private L2
(the wait's lines fit the L2's sets 4 a set); the store finds thread 15's
own L2 copy (shared) and takes the line from the other fifteen.

**Q16 holds** when every count above is met exactly, in both forms, at all
three levels, with no trace wrapped (`Reached end of trace` 0). The
whole-run counts are reported beside them. A miss is diagnosed (the event
log says which step and which core) and fixed under its own note before any
16-core ratio is read, as amendment 1 says.

**gem5, on the server:** the static binary, `-DM5OPS -DNT=16 -DACT0=12`,
timed waits, MESI_Three_Level, TimingSimpleCPU, **16 CPUs**, the small
hierarchy in one cluster with one shared bank (`--num-clusters=1`), 12 runs
(the control and 11 cases) under `~/micro16`, at nice 19. Counted as
before, from the first statistics dump, case minus control: GETX-o (SS + MT
L1_GETX) and UPG (SS L1_UPGRADE). **Passes** as the 4-thread test did:
within 1 of ChampSim's level-2 P (GETX-o) and U (UPG) in pp_lock, pp_store,
readers, ctl, upgrade and s16 (s16: GETX-o 0, UPG 4); pp_rmw, priv_E, priv_S,
llc_out and offchip are reported beside gem5's 4-CPU counts (expected equal
within 1; not gating, as at 4 CPUs). gem5's L1 invalidation events summed
over its sixteen private controllers are reported for s16 (expected 60 more
than the control), not gating. If gem5 cannot build or run a 16-CPU system
of this shape, that is reported with its message, and Q16 rests on
ChampSim's exact counts.

**Scripts:** `bench/micro_trim.py` takes the thread count; `bench/micro_champsim.sh`
takes `NT`, `ACT0` and `LEVELS` (defaults: the harness as it was) and adds the
s16 columns; `scripts/micro_server.sh` takes `NT`, `ACT0` and `W`;
`scripts/micro_all.sh q16` uploads to `~/micro16` and starts the 12 runs
(owner's word), `q16pull` brings them down.

## Amendment 6 (Note 4), 2026-11-12: Part C's runner, before any stripped trace or stock run exists

Part C as written, made concrete. Nothing of it has run; no ratio of B or C
has been read.

**The pairs:** the 15 programs at 4, 8 and 16 cores (45; C0 counts all of
them, whatever B decides). Each pair's **reference** is our ChampSim run
that the program is (or will be) scored by, LRU, fixed 2 MB, shared,
level 2:

| cores | reference tree (results/) |
|---|---|
| 4 | ocean, canneal, radix, waternsq: `phaseA_b3_g3_<p>4` (the g6 reruns, identical to g2); barnes: `phaseA_b3_g3_barnesstd4` (the standard barnes, its window span); fft, volrend, fmm: `phaseA_b3_b1_<p>4` (B1); lunc, raytrace: `phaseA_b3_n2_<p>4` (step 4); oceannc, fluidanimate, vips, bodytrack, streamcluster: `phaseA_b3_h2_<p>4` (set 2; streamcluster by newbench amendment 3) |
| 8 | canneal: `phaseA_b3_g3_canneal8`; the rest `phaseA_b3_b2_<p>8` |
| 16 | canneal: `phaseA_b3_p2_canneal16` (step 5's LRU run); the rest `phaseA_b3_b16_<p>16` |

**From the reference's own log,** never retyped: the traces, in core order
(its `CPU n runs` lines), and the window (its `Warmup Instructions` and
`Simulation Instructions`; barnes's window span is 37.9 M + 100 M, every
other 50 M + 100 M). A pair starts only once its reference has completed
(the chain looks every 10 minutes); one whose reference has not completed
14 days after the chain started is reported, not run.

**Then, per pair:** every trace stripped by `scripts/sync_strip.py`
(`selftest` passes on the server first), each strip's report checked
(records in = sync records + records out, no odd trailing bytes); upstream
(`champsim_partA_up_8effd663`) and ours-off (`champsim_partA_ours_f08a3994`)
run side by side on the stripped copies with the reference's window and
`off_<cores>_lru.json` (made by Part A's `make_config.py`; the 4- and
8-core files must equal Part A's byte for byte; the 16-core one is new,
its LLC checked to be 2 MB); once both logs are complete the stripped
copies are removed (disk), the strip reports kept. Logs
`results/partC/<p>_<cores>.<up|oursoff>.log`, each with its binary's
sidecar. Six pairs at a time (12 ChampSim runs at nice 19; the strips at
nice 10); a pair waiting for its reference holds no slot.

**C0** is then E1 of Part A (`upstream_equiv.py`) on each pair's two logs;
**C1 and C2** are computed by `scripts/partC_score.py` (written, with a
self-test on hand cases, before any of these logs is read).

**Scripts:** `scripts/partC_all.sh` (laptop: upload into `~/partC`,
guards, the detached chain; `status`, `pairs`, `pull`, `stop`) and
`scripts/partC_server.sh`.

**Rehearsed 2026-11-12 on the laptop**, against stand-in Part A binaries
(both our build, so E1 trivially holds; the test is the runner) and the
references Note 2's rehearsal made:
- Guards pass; `off_4` and `off_8` equal Part A's; the 16-core config's
  LLC is 2 MB; the stripper's selftest passes on the server's copy.
- 18 pairs, 12 at a time, 15 min allowed: the six whose reference was
  complete stripped (each report balanced: records in = sync + out) and ran
  both sides; `ocean 16` started the moment its reference completed during
  the wait; the eleven others were reported NOT RUN at the limit.
- The driver was then changed so that a waiting pair holds no slot (the
  first version let it hold one), and rehearsed again: 9 pairs, 2 at a time,
  60 s allowed: the four ready pairs ran two at a time, the five without a
  reference were reported, and ready pairs kept starting after the limit; no
  stripped copy was left behind. The first rehearsal's 16-core pair
  (`ocean 16`) completed later (7 of 18 pairs at its end), and E1 holds on
  it (8,091 upstream lines).
- `partC_score.py c0` on the rehearsal's logs: E1 holds on 4 of 4. `rows`
  reads a real log exactly as `run_phase_a.sh`'s awk does (LLC load, RFO,
  write and total, and the instruction total, checked on one log).
  `selftest`: 13 of 13 hand cases.

## Amendment 7 (Note 3), 2026-11-12: Part B's scoring, before any Part B ratio exists

No Part B trace, ChampSim run or counter run exists, and gem5's Part B runs
have not ended; no number of B has been read. This note fixes how B is
checked and scored. The checks, tolerances and predictions above are
unchanged.

**The scorer: `scripts/partB_score.py`**, built on set 2's checker.
- `heldout2_score.py`'s `check_program` now takes each program's facts from
  its entry, with set 2's values as the defaults: the tree and run log
  (`wl`, `cores`), the trace set (`tdir`), thread 0's cut (`cut`: `auto` =
  cut at its last `pthread_create`, its trace `raw0_aligned`, the counter
  with `-cut0 1`), the counter's `skip`, gem5's two stops (`stopsM`: radix's
  are 1,610 M and 1,710 M) and the CPUs carrying them, the counter's CPUID
  file (`~/sync_pb/gem5.cpuid`), and Q3's private-cache count (3 a core: 24
  at 8 cores, 48 at 16). `countrows` bases a cut thread 0's window at the
  counter's last `CREATE 0` line, as `stream_check2.py rows` did for step 4.
- **Tested unchanged on set 2:** its four row makers reproduce the committed
  `h2_trace_rows_v2`, `h2_count_rows_v1`, `h2_run_rows_v2` and
  `h2_gem5_config_v1` byte for byte, and `heldout2_score.py score` on the
  nine files of `heldout2_sc_results_2026-11-07.md` prints the same 137
  lines.
- **The keys** come from sizing's records (`partB_score.py keys`, a
  committed `partB_keys_vN.txt`): each key's traced threads, gem5 CPUs,
  worker stop, stops, skip, cut, static binary, tree, and whether it was
  sized. A key not sized is reported with its reason.
- **B1** (`fft_4`, `volrend_4`, `fmm_4`): QB holds when the 8-thread key's
  binaries passed QB at sizing (its SIZED), and QG checks that the existing
  4-thread gem5 runs (`newbench/fft`, `newbench/volrend`, `heldout/fmm`) ran
  that key's static binary. Their stops (CPUs 1-3, CPU 0 aside; read from
  their config.ini, settings only) fit QG's rule. Predictions P8-P10, as B1
  states.
- **PENDING, not a failure:** a key without a trace set, a ChampSim run log
  or a counter run, or whose gem5 run has not started or is still running.
  **A gem5 run stopped by its time limit** (its `limit.rc` reads 124) fails
  QG with that reason: the key is reported and not scored, as B2 and B16
  state. `pull_results.sh` now pulls `limit.rc`.
- **canneal_16** keeps the procedure of its 4- and 8-core points (amendment
  1): QG (17 CPUs, the stop on CPUs 1-16, the static `CANNEAL`, 2 MB,
  randomization off); **v1**, the same-stream check
  (`b3_stream_check.py`, workload `canneal16`: the sync_mx/canneal16 traces'
  records 50-150 M of threads 1-16, as rows `canneal_16t_t<k>` made by
  `window`, against gem5's window; every rate within 5%); Q3 from step 5's
  LRU rows of `phaseA_b3_p2_canneal16` (complete, self-check 0 with 48
  private caches, stale-holders 0, level 2; its run log's checks are step
  5's, which held on 171 of 171); 500 events. QW is printed for it, and
  decides nothing (it is not part of that procedure). `partB_all.sh tpull`
  now pulls those traces' `.mix` files.
- **The score:** `b3_score.py`'s blocks **`b1@partB`, `b2@partB`,
  `b16@partB`** and **`p2@partB`** (canneal_16), printed only for keys that
  pass every check. The design named them `@set2`; a separate reference was
  needed because set 1's `phaseA_b3_h2_fmm4` tree exists, and adding B1's
  `fmm4` to `set2` would have changed what the existing `h2@set2` block
  prints. The P-numbers: B1 P8-P10, B2 P18-P20, B16 P22-P24 (canneal_16
  included). Then, per core count, the keys scored, those discriminating,
  and on how many the first prediction (R_g5 in the band) holds.
- Two changes to the shared tools, each tested to change nothing that
  exists. **`b3_score.py score` reads LRU rows only**: step 5's trees hold
  nine policies under one tree name, and its loader kept the last row of a
  tree. Every B3 tree is LRU alone; 33 generation specs score to the same 573
  lines before and after. **`b3_score.py gem5-rows` skips a run that has
  not ended and has no statistics** (a comment line, no row; Part B's runs
  end over days), and still stops on an ended run without exactly one
  dump. On today's tree it prints `gem5_b3_rows_v6` byte for byte.
- **Self-test, `partB_score.py selftest`: 35 of 35 hand cases hold**: the
  keys from stand-in sizing records (radix's stops at the skip, B1 from its
  8-thread key, a key that failed E3, canneal_16), a cut thread 0's counter
  window (52.3-152.3 M after a create at 2.3 M), gem5-rows on a run still
  running and on an ended one without statistics, a stand-in key passing
  every check, ten faults each caught by its check, a still-running and a
  not-started gem5 run PENDING, canneal_16 passing v1 and failing it at 25%
  apart, and the score on hand-computed rows (R_g5 0.750 holds; 0.300
  fails; 400 gem5 events not discriminating; the counts per core count).

**The order** (laptop; each pull is read-only):
1. `scripts/partB_all.sh pull` (sizing), `tpull` (stage 2), and
   `scripts/pull_results.sh` (rows, gem5).
2. Rows, each committed under a new version:
   `partB_score.py keys simulator/results/partB`,
   `tracerows KEYS simulator/results/partB/stage2/traces`,
   `countrows simulator/results/partB/stage2/count`,
   `runrows KEYS simulator/results/partB/stage2/logs simulator/results/partB/stage2/driver.log`,
   `gem5cfg KEYS simulator/results/gem5_b3`; then `stream_check2.py
   gem5rows`, `b3_stream_check.py extract`, `b3_score.py gem5-rows` (every
   older row must reappear unchanged), and a trace_mix version that adds
   `canneal_16t_t1..t16` (`b3_stream_check.py window` on
   `stage2/canneal16/raw<k>.mix`).
3. `partB_score.py check` (the eleven files): no ratio printed.
4. `partB_score.py score` (the same eleven files).
5. Part C's C1 and C2 at each core count are over the keys `score` lists as
   scored and discriminating there (`partC_score.py score ... PROGRAMS`).

Keys are scored as they complete: a score taken while others are pending
says so per key, and a later score adds keys without changing the earlier
ones' checks.


## Amendment 8, 2026-11-12 evening: Q16's ChampSim half runs on the server, before any count of it is read

**Why.** The owner asked that the laptop carry as little load as possible.
The laptop also rebooted (~17:36) during Q16's ChampSim half. The control
had finished and pp_lock and pp_store were running, but all of it was in a
scratch directory the reboot wiped, and no case's count had been read. gem5's
half (amendment 5) runs on the server as written: 12 runs, `~/micro16`.

**What changes: only where and on what.** `scripts/q16cs_all.sh go` uploads
`bench/micro_champsim.sh`, `bench/micro_trim.py`, `bench/coherence_micro.c` and
`simulator/scripts/make_config.py`, as committed, to `~/q16cs/root`. Then
`scripts/q16cs_server.sh` runs the harness unchanged, with
`NT=16 ACT0=12 LEVELS="0 1 2"`, in both forms side by side, at nice 19, 6
ChampSim runs at a time each:
- **timed:** no flags.
- **barrier:** `MICRO_CFLAGS=-DBARRIER_STEPS TRACER_ARGS="-sync 1"`.

The pieces it runs on:
- **The binary is the frozen `champsim_g6_1e3060c1`**, built from the g6
  sources. It is the binary every 4-, 8- and 16-core B3 run of Parts B and
  C replays on, so Q16 tests that binary itself, not a laptop build of its
  sources. make_config's mini configurations at 16 cores are byte-identical
  between `1b56891` and HEAD at levels 0, 1 and 2 (checked).
- **The tracer is h2's** (`~/sync_h2_build`, md5 02ff8f48): the frozen
  tracer Part B traces with, run without `-cpuid` and without `-start0`.
- **Pin** is the server's 3.31.
- **numpy** (the cutter needs it; the server's python3 has none) is pip's
  `numpy==2.4.6`, the laptop's version, in `~/q16cs/venv`.
- **Traces** go under `/tmp/harshraj_q16cs` (on `/`; `/home` is 99% full),
  and the harness removes them when it ends.

The hand counts, the pass rule ("every count met exactly, in both forms, at
all three levels, no trace wrapped") and the rule that a miss is diagnosed
under its own note before any 16-core ratio is read are amendment 5's,
unchanged. The counts are read only after both forms end
(`scripts/q16cs_all.sh pull`).

## Amendment 9, 2026-11-12 evening: how Q16's ChampSim counts are read, fixed before any count of either half is read

Amendment 5 lists the micro test's columns (P, A, B, U) "on the X lines".
The harness cannot give **B (the bounded view) on the X lines**. The
per-request event log carries the protocol, presence and gem5-rule views,
but not the bounded one. The harness's summary therefore reads B over the
whole run only, which includes the program's other sharing (on the 4-thread
output of 2026-10-19, pp_lock at level 2 reads whole-run B 77 against 12 on
the X lines). The harness of 2026-10-17 counted the same way. So:
- **Judged, exactly, on the X lines, case minus control, x 4 rounds:**
  - P, A and U for all eleven cases at levels 0, 1 and 2, with the
    amendment 5 table;
  - for s16 also: the cores its upgrades find, in the protocol view and in
    the gem5-rule view (60 at level 2, 0 below), and the private copies
    invalidated (60 at level 2, 0 below);
  - no trace wrapped, the control included.
- **Reported, not judged:** B, and whole-run P, A and U.

The reader is **`bench/q16_judge.py FORM_DIR ...`**, which prints "Q16
(ChampSim half) ... HOLDS" only when both forms have the control and all
eleven cases at all three levels, and every count is met. Its self-test
(`--selftest`) runs the judge on the 4-thread harness output of
2026-10-19 (`simulator/results/micro_champsim_g5`, levels 0 and 2, the ten
cases): 20 of 20 met. An injected wrong hand count (ctl, P 2 a round) is
caught on 2 of 2 rows. Its whole-run columns equal that summary's. gem5's
half is read as amendment 5 says.


## Amendment 10, 2026-11-14: Part B's ChampSim runs on the F-C binary (F-C adopted), before any Part B ratio is read

**Why.** F-C was scored 2026-11-14 and is ADOPTED by its rule
(`lock_fix_results_2026-11-14.md`, `b44f0e9`). Its note says: "every Part B
ChampSim run is rerun on the F-C binary with `request` under an amendment
written before those reruns (traces, gem5 runs and counter runs
unchanged), and the paper reports the F-C binary". This is that amendment.

**State when written.** No Part B ratio has been read. The keys' traces and
ChampSim runs on `champsim_g6_1e3060c1` are under way (amendment 4's chain,
21 of 31 keys traced and 7 of 31 runs complete on 2026-11-13). gem5's runs
are under way. No counter run of Part B has been read. Nothing here changes
a trace, a gem5 run, a counter run, a check, a tolerance or a prediction.

**What runs (35 reruns), each once its reference run has completed.**
- B1: fft, volrend, fmm at 4 cores (references `phaseA_b3_b1_<p>4`).
- B2: the 14 programs at 8 cores (`phaseA_b3_b2_<p>8`).
- B16: the 14 programs at 16 cores (`phaseA_b3_b16_<p>16`).
- canneal at 16 cores: step 5's LRU run (`phaseA_b3_p2_canneal16`).
- **Three 4-core points that are neither Part B's nor among F-C's 14**:
  water-nsquared (`phaseA_b3_g3_waternsq4`), raytrace (`phaseA_b3_n2_raytrace4`)
  and streamcluster (`phaseA_b3_h2_streamcluster4`). They are added so that
  every point of the paper's 15-program table is on one binary. canneal 8c
  and the other 4-core spans are F-C's 14 reruns (`phaseA_b3_fc_*`), scored
  already.

**How each rerun is made** (`scripts/partBfc_server.sh`, launched by
`scripts/partBfc_all.sh go` on the owner's word):
- Binary `champsim_fc_a2e88e46` (md5 a2e88e46788e1f332427567a19bc2f90, the
  file in `~/sync_fc/BIN`; its check record: Q0 8/8, Q0m 3/3, Q0r 3/3, K0).
- The reference's config file (the one its runner wrote: `~/sync_pb/cfg/`
  for Part B's keys, `~/sync_pol/cfg/` for canneal 16, `~/sync_g6/cfg/`,
  `~/sync_nb/cfg/`, `~/sync_h2/cfg/` for the three 4-core points) **plus
  `"sync_lock_word": "request"` and nothing else** (asserted: the new file
  minus that key equals the old file, which must not set it already).
- The reference log's window (Warmup / Simulation Instructions) and traces
  (its `CPU n runs` lines, in CPU order).
- Into `phaseA_b3_fc_<reference's tag>_<suffix>`, the same
  `regime_shared/<wl>_<n>core/lru/run.log` path (for example
  `phaseA_b3_fc_b2_fft8`, `phaseA_b3_fc_p2_canneal16`). The `fc_` trees of
  F-C's 14 already follow that naming.
- 8 at a time, nice 19; a rerun starts only when its reference run has
  completed (at most 14 days from launch; a reference not complete by then
  is reported, not rerun). The driver writes only `~/partBfc` and those trees.
- **The g6 runs stay** and are reported as "before F-C" beside each F-C
  run. They are never scored.

**Qualification of each rerun** (`lock_fix_score.py`'s `qualify`, against
its reference log; the rows file of `partB_score.py --fc fcrows`):
complete; "SYNC LOCK WORD: request" once; one LOCK-WORD REQUESTS line per
MUTEX WAITED ACQUIRES line; warm-up, length, CPU count and traces equal to
the reference's; level 2; no trace wrapped; self-check mismatches 0,
stale-holder violations 0, 3 private caches a core registered; Q3:
unexplained view-order violations 0. A rerun that does not qualify leaves
its key NOT SCORED with that reason.

**Scoring** (Note 3's order, unchanged, with `--fc`):
- `partB_score.py --fc` reads each key's tree as `phaseA_b3_fc_<tree's
  tag>_<suffix>`, expects the chain's binary `champsim_fc_a2e88e46` (the
  CHAIN START line of `~/partBfc/driver.log`), and takes one more file,
  the FCQ rows: a key passes every check only if its rerun qualifies too.
  Every other check is Note 3's (QB, QT, Q3, QG, QW, QC, v2 with the native
  range, 500 events; canneal 16 by v1).
- The blocks become `fc_b1@partB`, `fc_b2@partB`, `fc_b16@partB`,
  `fc_p2@partB`. The predictions are unchanged: B1 P8-P10, B2 P18-P20, B16
  P22-P24.
- The three extra 4-core points are scored by their own earlier
  procedures, whose checks held then and do not depend on the binary
  (traces, gem5 runs, counter runs unchanged), once their reruns qualify:
  `b3_score.py score ... fc_g3@held fc_n2@new fc_h2@set2`. So the 4-core
  column of the paper's table reads: F-C's 14 (scored) and these three.
- Without `--fc`, `partB_score.py` prints what it printed before this
  amendment, byte for byte (its self-test, 35 cases, unchanged).

**Part C** is unchanged. Its pairs read only their reference's traces and
window, and run with the extension off.

**The order.**
1. Commit this amendment, the runner, the launcher and the scorer's `--fc`
   mode with its self-test cases; rehearse the runner against a stand-in
   server.
2. The owner's word: `bash scripts/partBfc_all.sh go`.
3. `bash scripts/partBfc_all.sh pull` (read-only), then Note 3's rows and
   `partB_score.py --fc fcrows`, `--fc check`, `--fc score`.

**Build and rehearsal record (2026-11-14, before any launch).**
- `scripts/partBfc_server.sh` (guards, list, chain, status, stop),
  `scripts/partBfc_all.sh` (go, status, list, pull, stop), and
  `partB_score.py --fc` (`fcrows`; `check` and `score` with the FCQ rows as a
  twelfth file).
- `partB_score.py selftest`: **48 of 48** (the 35 earlier cases unchanged,
  13 new): the fc_ trees and the kept g6 tree; fcrows on stand-in logs (a
  qualifying rerun ok, one without the request FAILS, no F-C log and an
  incomplete rerun PENDING, the three extra points listed); `fc_verdict` on
  seven verdict / FCQ combinations; and `score` on the fc_ trees gives the
  same hand-computed verdicts as on the g6 trees (P18 R_g5 0.750 holds,
  P22 0.300 fails, the counts per core count) under `fc_b2@partB` /
  `fc_b16@partB`.
- **Rehearsed against a stand-in server** (a stand-in F-C binary that
  prints the setting it was given, its window and its traces). The guards
  pass. Four complete references rerun at once, each with 4, 8 or 16 traces
  in CPU order, the reference's window, and the reference's config plus the
  setting alone. A reference completed during the chain is rerun when it
  completes. A config that already sets `sync_lock_word` is refused
  (FAILED, nothing run). References not complete by the limit are reported
  NOT RUN. A relaunch skips the five complete reruns. `stop` ends the chain.
  The guards refuse a wrong md5 and a missing K0_PASSED.

## Amendment 11, 2026-11-17: a cut-off for amendment 10's reruns, before any Part B ratio is read

**Why.** On 2026-11-17 the server's load was about 386 on 48 cores, mostly
other users' work. Amendment 10's 35 reruns stood at 17 complete, and the
results freeze is planned for Tue 8 Dec. A rule for a rerun that has not
finished must be fixed now, while no Part B ratio has been read (none has:
only the input checks were read, `partB_checks_interim_2026-11-14.md`, and
those decide nothing about a ratio).

**The rule.**
- **Cut-off: Sat 2026-12-05 23:59 server time.** A key whose F-C rerun has
  completed and qualified (amendment 10's qualification) by then is scored
  on the F-C binary, as amendment 10 says.
- **A key whose F-C rerun has not completed or not qualified by the
  cut-off is scored on its g6 run** (`champsim_g6_1e3060c1`, the reference
  tree), by Note 3 as written before amendment 10 (the same checks, the same
  gem5 runs and counter runs). Its row and every table that shows it carry
  the label **"before F-C (g6)"**. The paper lists these keys.
- A rerun that completes after the cut-off does not replace that score. It
  is reported beside it as a later check, with both values.
- Nothing else changes: no check, tolerance, prediction or band.

**What is known about the difference (from scored results, stated so the
label is read correctly).**
- F-C moved the spans that agreed by at most 0.04 (P-F2, 7 of 7).
- It moved barnes's spans by much more (window 0.249 -> 0.954, barnes-256
  0.267 -> 0.780, start 0.233 -> 0.449).
- So a lock-heavy key scored on g6 (barnes above all) may read lower than
  its F-C value would. The label says so; nothing is adjusted.

**Tooling.** `partB_score.py --fc` gains this fallback: given the cut-off and
the chain's per-run end times, a key with no qualifying F-C rerun is read
from its g6 tree and labelled. It is built and self-tested (one key each
way, and a rerun ending after the cut-off) before Dec 5, and its build
record is added here. Until then nothing of Part B is scored.

## Amendment 12, 2026-11-17: v2 judged on the located windows, for every key (owner's decision of 2026-11-14), before any Part B ratio is read

**Why.** gem5 stops when its FIRST watched worker reaches 50 M or 150 M
(Note 3), so a lagging CPU's gem5 window covers other instructions than the
counter's records 50-150 M. `v2_located_results_2026-11-14.md` (`be3f390`)
measured this: barnes_16's RMW miss is explained by placement (W1); control
C held on 24 of 24 keys passing v2 (every one still passes on the located
windows). **The owner decided on 2026-11-14 that v2 is judged on the
located windows, for every key.** This writes that down.

**The rule.**
- For each set-2-procedure key (B1, B2, B16), each of the three gem5-CPUID
  counter runs gives a **located** rate: for each traced thread t, the
  counts between the grid point whose `ginst` is nearest gem5 CPU t's
  `numInsts` at the low stop and the one nearest it at the high stop
  (`v2_located.py`'s computation, unchanged), summed over the traced
  threads, per 1,000 `ginst`.
- **v2 compares gem5's rates with the range of the three located rates,
  by v2's whole rule, unchanged:** widened 5% (RMWs: or within 0.05 per
  1,000); loads and stores up to 8% outside scored with the miss stated;
  RMWs gate.
- A key whose located window cannot be read (a thread's located end past
  its counter run's end, or a missing gem5 per-CPU row) fails v2 as "not
  checked", as a missing input does now.
- QC, QW, 500 and every other check are unchanged. canneal_16 keeps its
  older procedure (v1 same-stream check, amendment 1).
- The counter-window rates stay printed beside the located ones, reported.

**The known effect, disclosed.** This amendment is written after the
located numbers of 31 keys were read (the 2026-11-14 results). On those
keys, by the whole rule:
- **barnes_16:** RMWs 9.756 in the located range 9.801-10.058 (inside by
  the 0.05 rule); loads and stores inside. v2 FAILED -> **holds**.
- **volrend_16:** RMWs 1.007 in 0.828-0.975 widened (inside); stores
  41.615 against 38.921-39.097, +6.4% (scored, the miss stated). v2 FAILED
  -> **holds by the held-out rule**. Its other checks decide whether it is
  scored.
- fmm_4/8/16 and volrend_8 still fail v2 (W2). Every key that passed still
  passes (control C).
- Keys whose rows did not exist on 2026-11-14 (gem5 still running, or
  counter runs missing) are judged by this rule only.

**Caveat, stated with any key scored by it.** The counter runs the dynamic
binary and gem5 the static one; thread 0's positions differ by the
start-up difference (ld.so, dynamic initialisation), not measured. The
grid is 100,000 records, so a located edge is within 50,000 records of
gem5's position.

**What it does not do.** It does not change B3's windows: gem5's events
are still counted between its stops, and ChampSim's over its own window.
Matching B3's windows is a separate note (the owner's decision of
2026-11-14).

**Tooling.**
- `v2_located.py rows KEYS COUNT_ROWS COUNT_RUNS GEM5_PERCPU >
  bench/policy_sanity/partB_v2loc_rows_vN.txt`: per key and counter run, the
  located sums (LOC lines) or the reason none (LOCNOT).
- `heldout2_score.check_program` takes the located rows; without them its
  output is unchanged (set 2's check, byte for byte).
- `partB_score.py [--fc] --v2loc FILE check|score ...`. Without `--v2loc`,
  the output is as before (byte for byte); with it, v2 reads "on the located
  windows (amendment 12)".
- Build record below, before any Part B score is computed.

**Amendment 12 build record (2026-11-17, before any Part B score).**
- `v2_located.py rows` -> `partB_v2loc_rows_v1.txt` (on `partB_keys_v1`,
  the pulled counter runs, `gem5_percpu_v3`): 90 LOC rows (30 keys x 3
  runs), each thread's grid points (LOCPT), and one LOCNOT: radix_16 (its
  gem5 runs had not ended).
- `v2_located.py run` still reproduces `v2_located_v1.txt` byte for byte.
  Its self-test PASSES, with new cases for the rows: the hand-known sums, a
  located end past a run's end, and missing gem5 rows.
- Without the located rows, `heldout2_score.py check` on set 2's nine files
  and `partB_score.py --fc check` on the interim's twelve are byte for byte
  as before (the latter equals `partB_fc_check_interim_v1.txt`).
- `partB_score.py` self-test: **59 hold, 0 fail** (8 new, L1-L8). With the
  located rates ignored (a fault put in by hand), 4 of them fail.
- **QV:** with `--fc --v2loc`, each key's located range and counter-window
  range printed by `check` equals `v2_located_v1.txt`'s (90 of 90
  measure-key pairs). No B3 ratio was printed (0 R lines);
  `partB_fc_check_loc_interim_v1.txt`.
- **Effect, as disclosed above:** v2 now holds for barnes_16 and holds by
  the held-out rule for volrend_16 (stores +6.4%). No other key's v2
  changed. Both are still PENDING at that pull (their ChampSim runs had not
  finished). Every verdict line equals the interim's.
- **The scoring command from now on:** `partB_score.py --fc --v2loc
  bench/policy_sanity/partB_v2loc_rows_vN.txt check|score <twelve files>`,
  with the located rows remade (`v2_located.py rows`) on the pull that is
  scored.

**Amendment 11 build record (2026-11-17, before the cut-off and before any
Part B score).** `partB_score.py`:
- `fcrows KEYS REFLOGS FCLOGS DRIVER_LOG`: each FCQ row ends `ended <time>`,
  the rerun's last `END rc=0 complete` time in `~/partBfc/driver.log`, or
  `ended -`. Without the fifth argument the rows are as before: on the pull
  of 2026-11-14 they equal `partB_fcq_rows_v1.txt` byte for byte, and with
  it they equal those rows plus the tails (35 rows; the 3 `ok` rows all have
  a time).
- `--fc --cutoff YYYY-MM-DDTHH:MM:SS --g6rows G6_RUN_ROWS check|score`: a
  key whose FCQ row is not `ok`, has no END time, or ended after the cut-off
  is checked on its g6 run:
  - its g6 tree;
  - the g6 run rows (`runrows` on the g6 chain's logs and
    `stage2/driver.log`);
  - Q3 against `champsim_g6_1e3060c1`.
  The key's block carries an `FC amendment 11: <why>` line, its summary line
  `[before F-C (g6)]`, and its score falls in a separate block, headed
  "Scored on their g6 run, labelled 'before F-C (g6)'". The per-core counts
  mark it `(g6)`.
- It refuses `--cutoff` without `--g6rows` or `--fc`, and refuses FCQ rows
  made without the chain log: those would send every `ok` key to g6. This
  was found in a smoke test before anything was scored.
- Without `--cutoff`, `--fc check` and `--fc --v2loc check` on the interim's
  twelve files equal `partB_fc_check_interim_v1.txt` and
  `partB_fc_check_loc_interim_v1.txt` byte for byte.
- Self-test: **71 hold, 0 fail** (12 new, A1-A6 and A3b). Two faults put in
  by hand were each caught: the END time ignored (A5) and the g6 block
  unlabelled (A6).
- Smoke test on the real rows (2026-11-14 pull, a cut-off of 2026-11-14
  16:00, g6 run rows made from `stage2/logs`, outside the repo): every key
  without a qualifying rerun went through its g6 run with its label. It
  printed checks only (0 B3 ratio lines) and was not read further.
- **The scoring command at the cut-off:**
  1. `partB_score.py --fc fcrows ... stage2fc/driver.log > partB_fcq_rows_vN.txt`;
  2. `partB_score.py runrows partB_keys_v1.txt stage2/logs
     stage2/driver.log > partB_run_rows_g6_vN.txt`;
  3. `partB_score.py --fc --v2loc partB_v2loc_rows_vN.txt --cutoff
     2026-12-05T23:59:00 --g6rows partB_run_rows_g6_vN.txt score <twelve
     files>`.

## Amendment 13, 2026-11-23: radix16's rerun may start before its reference completes; disk guard 5 GB (before any Part B ratio is read)

- **Why:** the 22 Nov reboot killed radix16's g6 reference at 130 M of 150 M
  instructions a core, after 9 days under load. Restarted, then followed by
  its F-C rerun, it could miss amendment 11's cut-off.
- **The rule:**
  - A rerun in `EARLY` (radix16) may start once its reference's log shows
    its window lines.
  - Its traces are listed from the sizing record, as the trace runner lists
    them.
  - QE-early, in the runner's guards, requires that this rule give the
    exact trace list of every completed 8- and 16-thread reference: 27 of
    27 on 23 Nov.
- **Scoring is unchanged:** `fcrows` still compares each rerun's window,
  CPU count and traces with its completed reference.
- **partBfc's disk guard is 5 GB** (was 20; logs only).
- Details, checks and the day's order are in `relaunch_2026-11-24.md`.
