# Held-out set 2: programs with real sharing, against gem5. Pre-registered 2026-11-04

Written before any of these programs has been surveyed on the server, built,
sized, traced or run, and before any number of theirs exists.

**Why.** Step 4 gives no held-out program that both passes its checks and
discriminates (`newbench_results_2026-11-01.md`,
`stream_fix_results_2026-11-04.md`):
- fft, streamcluster and volrend are unscored;
- lu and raytrace pass but share too little (108 and 184 gem5 events, under
  500).

The owner decided on 2026-11-04 to add **two more held-out programs with real
sharing**: a choice rule pre-registered first, then a read-only survey. This
is that rule, with how the programs are run, checked and scored. LU
non-contiguous stays under step 4's design and is scored there.

**What was read before writing.**
- The PARSEC 3.0 source on the laptop (`bamos/parsec-benchmark` at
  `2e492f77`): each candidate's run configurations and how it synchronises.
- Step 4's survey of the server's SPLASH-3 tree
  (`newbench_survey_2026-10-19.txt`).

Nothing of the server's PARSEC tree has been read for these programs; the
survey below does that.

**This is a new pre-registration written after streamfix was scored.** It
adopts two things streamfix established, for programs none of whose numbers
exist:
- the check in gem5's units (v2);
- tracing under gem5's CPUID.

It changes nothing for any program already scored or unscored.

## The candidates, in order (fixed now)

| # | program | how it synchronises (read in the source) | threads | ladder (PARSEC's run configurations, smallest first) |
|---|---|---|---|---|
| 1 | **fluidanimate** (PARSEC apps) | a pthread mutex per grid cell, pthread barriers between phases. PARSEC's spin-barrier drop-in is in the source and is disabled in the build copy, as for streamcluster. | main creates the workers and joins them | `4 5 in_35K.fluid`, `4 5 in_100K.fluid`, `4 5 in_300K.fluid`, `4 500 in_500K.fluid` (each with `out.fluid`) |
| 2 | **bodytrack** (PARSEC apps; build `--enable-threads --disable-openmp --disable-tbb`) | its own `threads` library over pthread mutexes, condition variables and barriers. Its atomic headers are never included (grep). | main, a pool of 4 workers, and an image-loader thread | `sequenceB_1 4 1 1000 5 0 4`, `sequenceB_2 4 2 2000 5 0 4`, `sequenceB_4 4 4 4000 5 0 4`, `sequenceB_261 4 261 4000 5 0 4` |
| 3 | **facesim** (PARSEC apps; `version=pthreads`) | pthread mutexes and condition variables: TaskQ (work stealing) and PhysBAM's thread pool | main and a pool | `-timing -threads 4` on the simsmall, simmedium and simlarge inputs; native adds `-lastframe 100` |
| 4 | **vips** (PARSEC apps; `--enable-threads`) | GLib threads. Whether the bundled GLib's mutex is a pthread mutex is for the survey to read. | main and a pool | `im_benchmark <image> output.v`: pomegranate_1600x1200, vulture_2336x2336, bigben_2662x5500, orion_18000x18000 |
| 5 | **x264** (PARSEC apps) | pthreads (`encoder.c`) | frame threads; E3 decides | PARSEC's run arguments with `--threads 4`; inputs simsmall to native |
| 6 | **ferret** (PARSEC apps) | pthread thread pools, one per pipeline stage | several per stage; E3 decides | `corel lsh queries 10 20 4 output.txt` on simsmall to simlarge; native uses 50 |

**Run as well, reported separately, never counted toward the two:**
- **ocean non-contiguous** (SPLASH-3 `apps/ocean/non_contiguous_partitions`,
  `-n514 -p4 -e1e-7 -r20000 -t28800`, ocean's arguments). It is held out from
  development, but it is a second data layout of a development program
  (ocean).

**Excluded now, with the reason:**
- **blackscholes, swaptions:** each thread works on a disjoint slice and the
  threads meet only at the start and the end. A store that finds another
  core's copy is rare by construction.
- **freqmine:** OpenMP. Its waits are in libgomp, not in pthread calls the
  tracer records.
- **dedup:** tried before, failed, and removed permanently by the owner.
- **canneal, streamcluster, PARSEC's raytrace:** already used. (SPLASH-3's
  raytrace is a step 4 program.)
- **The other SPLASH-3 programs:**
  - used: ocean, barnes, radix, water-nsquared, fmm, fft, lu, raytrace,
    volrend, LU non-contiguous;
  - failed step 4's rules: cholesky, water-spatial, radiosity.

## Eligibility, checked in this order before any B3 number exists

- **E1 (survey, read-only).** The source and its inputs are on the server,
  and so are the build's dependencies:
  - vips: GLib, libxml2, zlib;
  - ferret: GSL, libjpeg;
  - the C++ programs: a static libstdc++.

  A missing input rung is dropped from the ladder; the order of the others is
  unchanged.
- **E2 (survey and source).** Every wait between threads is a pthread call
  the tracer records: mutex, condition variable, barrier, create or join. No
  thread waits by spinning on memory.
  - PARSEC's barrier drop-in is disabled in the build copy wherever it is
    included.
  - At run time it is confirmed by the tracer's per-call report and by Q3
    (below).
- **E3 (sizing).** Exactly four threads do the parallel work, each created
  once and living to the end. Main and helper threads (an I/O thread) may
  exist and are counted.
  - Read from the sizing run's per-thread instruction counts and thread
    count.
  - A program that creates more than four working threads, or creates them
    repeatedly, is excluded.
- **E4 (build).** A dynamic binary for Pin and the same objects linked
  `-static` for gem5, built from a copy with fortify off. **QB** holds: every
  function of the program's objects has the same instruction count and
  constants in both, as for every earlier program.
- **E5 (size rule, unchanged).** The first rung on which every traced thread
  executes at least 300 M instructions.

**How many proceed.**
- The first **four** eligible candidates in the table's order, plus ocean
  non-contiguous if it is eligible. The cap is the server's capacity beside
  step 5.
- If fewer than two of the six are eligible, more candidates are added by an
  amendment, pre-registered, before any eligible program is scored. The
  eligible ones still run.

## The runs

- **Counter** (`stream_count`; `streamfix_server.sh`):
  - **three runs under gem5's CPUID**, the frozen `~/sync_nc/gem5.cpuid`
    (QE held 2026-11-04);
  - one run under the host's CPUID, reported only.

  Each run is the program as traced: same binary, arguments, input and
  working directory.
- **Traces** (sync_server.sh, a new variant `h2`):
  - **Tracer:** the tracer built in `~/sync_nc_build`, which passed QS and QK
    under that CPUID on 2026-11-04. It runs with `-cpuid` that file and
    `-sync 1`, 215 M records per traced thread, into `traces/sync_h2/`.
  - **Where each thread's trace starts:**
    - PARSEC: each traced worker from its creation (no cut), as canneal and
      streamcluster were.
    - ocean non-contiguous: threads 0-3 from the start, as ocean was.
  - **QT** as step 4. If it fails for length, newbench amendment 2's length
    rule applies once.
- **ChampSim:** the final binary `champsim_g6_1e3060c1`. Level 2, shared,
  LRU, 2 MB, 4 cores, 50 M + 100 M, into `phaseA_b3_h2_<program>4`.
- **gem5:** as step 4.
  - **Configuration:** MESI_Three_Level, TimingSimpleCPU, the same 2 MB
    shared cache, the static binary, the same input and working files.
  - **CPUs:** one per thread the program runs at once: main, the workers and
    any helpers.
  - **Stops:** when a **worker** reaches 50 M and 150 M.
  - **Time limit, fixed now:** a gem5 run that has not ended **96 h** after it
    started is stopped. Its program is reported and not scored.

## Qualifying checks (before any ratio is read)

- **QB, QT, Q3** as step 4, with Q3 as amended there:
  - no `SYNC DEADLOCK`;
  - `VIEW-ORDER VIOLATIONS UNEXPLAINED` 0;
  - self-check and stale-holders 0.
- **QG:** both gem5 runs end at their stop. The configuration shows the
  static binary, 2 MB L2 and randomization off.
- **QW (new): the untraced threads are idle in the window.** In gem5's
  window, the CPUs of untraced threads commit **under 1%** of the traced
  CPUs' instructions. ChampSim replays only the four traced threads, so work
  by main or a helper thread in the window would count in gem5 alone.
- **QC (the counter speaks for the trace), with the native range.** The
  trace's rates per 1,000 instructions must lie inside the three
  gem5-CPUID counter runs' range, widened by 1% on each side. For RMWs,
  within 0.01 per 1,000 also counts.
  - The rates are loads, stores and RMWs, in record units, over v1's window,
    summed over the traced threads.
  - **Why the range:** a program whose threads take work from a queue
    differs between native runs, and the trace is one such run. volrend
    failed the single-run QC of streamfix by 1.1%. For a program that does
    not vary, the range is a point, and this is QC as before.
- **Same stream, v2 (gem5 units; `stream_check2.py`), with the native
  range.** gem5's rate per 1,000 must lie inside the three counter runs'
  range, widened by 5% on each side.
  - The rates are summed over the traced threads and their CPUs.
  - RMWs pass also within 0.05 per 1,000. They gate.
  - **The held-out rule applies to loads and stores:** a miss of up to 8% is
    scored with the miss stated; beyond 8%, nothing is scored.
  - Per-thread rows are printed and do not gate.
- **Discriminating:** gem5 counts at least **500** events in the window:
  `SS.L1_GETX + MT.L1_GETX` at the shared cache's controller, per 1,000 of
  the window's instructions (all CPUs). That is how `b3_score.py` counts
  them for every earlier program, and it is not redefined here. QW keeps
  all CPUs and the traced CPUs within 1% of each other.

**A program that fails a check is reported with the check it failed and is
not scored.** No tolerance changes after a number of these programs is seen.

**Why v2 and gem5's CPUID, stated from the evidence**
(`stream_fix_results_2026-11-04.md`):
- **S0:** v2 keeps every v1 verdict on 11 windows.
- **S1:** v2 removes the unit difference exactly, on fft's workers.
- **S3:** gem5's CPUID removes streamcluster's library difference, and every
  worker agrees within 5%.
- **S2 failed on fft's thread 0**, whose serial start (libm) lands 16.7 M
  off under gem5's CPUID. Here the PARSEC traces start at each worker's
  creation, and ocean non-contiguous's thread 0 is traced from the start,
  as ocean's was. Thread 0's position enters only through v2's per-thread
  rows and QW.

## Predictions

These apply to each counted program that passes every check and discriminates.
- **P15:** R_g5 is in the band 0.5-2.
- **P16:** R_b ≥ R_g5. Each view only forgets more.
- **P17:** the shared-cache demand-traffic ratio (ChampSim against gem5, per
  KI) is within 0.5-2.

Upgrades (U against gem5's) are reported, not predicted. ocean
non-contiguous gets the same three, reported in its own row.

## How the outcomes are read

- **Every candidate is reported whatever happens to it:** excluded with its
  reason, failed with its check, or scored.
- **The owner's target, two held-out programs with real sharing,** is met
  when at least two counted programs pass every check and discriminate.
  - The paper then states held-out agreement over those programs, with any
    P15 miss beside it.
  - With fewer than two, the paper says so and claims no more than holds.
- A failure is diagnosed, never tuned away. Nothing is tuned after a number
  is seen.

## What is built before anything runs (recorded in a note here, before sizing)

- **`scripts/heldout2_survey.sh`** (read-only, writes only under
  `~/heldout2_survey`) and **`scripts/heldout2_all.sh survey`**: E1 and E2's
  evidence. The survey's facts go into a note here; the rules do not change.
- **The build and sizing recipes** for the eligible candidates, rehearsed on
  the laptop's PARSEC tree.
- **`VARIANT=h2`** of `sync_server.sh`.
- **The counter's three gem5-CPUID runs** and one host run.
- **`stream_check2.py`:** QC and v2 with the native range, and QW.

Target dates: survey 4-5 Nov; build and sizing 5-6 Nov; traces, counter and
gem5 6-10 Nov; scoring as each program's runs end.

## Note 1, 2026-11-04: what the survey found (E1, E2), before anything is built

Source: `heldout2_survey_2026-11-04.txt` (`scripts/heldout2_all.sh survey`,
read-only). No rule above changes.

- **Sources:** all six candidates are in `parsec-full/pkgs/apps`, the tree
  streamcluster was built from. SPLASH-3's ocean non-contiguous is present.
- **Inputs: not on the server.**
  - Each candidate's `inputs/` holds only PARSEC's `test` and `simdev` sets;
    facesim's holds none. No PARSEC input archive exists in the tracer tree or
    the home directory.
  - **Fix: the inputs are uploaded** from PARSEC's input archive on the
    laptop, `parsec-3.0-input-sim.tar.gz` (md5 `63be2694...`). Only the
    candidates' own `input_sim{small,medium,large}.tar` are uploaded, each
    checked by md5 on the server.
  - **The native sets exist on neither machine,** so by E1 every ladder
    loses its native rung.
  - facesim's three sets are byte-identical (md5 `bb79105b6e4e`) and its
    arguments are the same, so its ladder is one rung.
- **Build dependencies.** The sources of GLib, libxml2 and zlib (vips) and of
  GSL and libjpeg (ferret) are in the tree, none of them built (no `inst/`).
  They are built from those sources in the build copy. x264 needs yasm,
  which is not installed; PARSEC's `tools/yasm` source is in the tree.
- **Toolchain:**
  - gcc and g++ 13.3, with every static library the gem5 binaries need
    (libstdc++, libc, libm, libpthread, libgcc_eh);
  - autoconf 2.71 and automake 1.16.5;
  - no system libtool.
- **E2, from the source:**
  - **fluidanimate: holds.** It uses pthread mutexes and barriers. The
    drop-in (`ENABLE_AUTOMATIC_DROPIN`, `parsec_barrier.hpp`) is disabled in
    the copy. `sched_yield` occurs only in the drop-in's own barrier, which
    is then unused.
  - **bodytrack: holds.** Its threads library wraps pthread mutexes,
    condition variables and barriers. OpenMP appears only in the OMP files,
    which the pthreads build leaves out. The atomic headers are never
    included.
  - **facesim: holds.** It uses pthread mutexes and condition variables
    (TaskQ and the thread pool), with no atomics, futex or yield.
  - **vips: holds as far as the source shows.** GLib 2.24's `gthread-posix.c`
    builds its mutex and condition on pthread ones (futex 0).
  - **x264:** its waits are pthread calls, but `encoder.c:1587` creates a
    thread per frame (`x264_slices_write`) when threads > 1. E3 is expected
    to exclude it at sizing.
  - **ferret:** its waits are pthread calls, but it builds six pools of
    NTHREADS each (`ferret-pthreads.c:550-555`). E3 is expected to exclude
    it at sizing.
  - **ocean non-contiguous:** SPLASH-3's BARRIER and LOCK macros, as ocean.
- **So:** all six pass E1 (with the upload) and E2. By the design's order,
  **fluidanimate, bodytrack, facesim and vips are built and sized first.**
  x264, then ferret, are taken up only if one of those four fails E3, E4 or
  E5.
- **What the runs will use, as the survey read it:**
  - gem5 `build/X86/gem5.opt` (24 Sep), the binary of every gem5 run so far;
  - gem5's CPUID file, md5 `74d72229...`, with QS and QK passed;
  - tracer `f39707f3`, counter `cb5902c7`;
  - ChampSim `champsim_g6_1e3060c1`, with Q0 and Q0m passed.
  - Disk: 153 GB free.

## Note 2, 2026-11-04: the build and sizing recipes, before anything runs on the server

Rehearsed on the laptop, end to end:
- PARSEC 3.0 at `2e492f77`, the same file counts as the server's tree;
- SPLASH-3;
- gcc and g++ 13.4 (the server has 13.3) and Pin 3.31;
- the inputs from `parsec-3.0-input-sim.tar.gz`.

Every program built, passed QB and met E3 and E5. **No rule above changes.**
No trace, counter run, ChampSim run or gem5 run of these programs exists.

**Commands.**
- `scripts/heldout2_all.sh size` is one command. It stages and uploads the
  inputs, md5 checked on both ends, and uploads the probe and the runners.
  Then the server, detached, runs `heldout2_server.sh sizegem5`: build,
  inputs, size, record, then each sized program's two gem5 runs.
- `scripts/heldout2_all.sh status` reports both.

**The probe (new): `simulator/tracer/h2probe`, a Pin tool, records only.**
- It records:
  - each thread's instruction count, counted as inscount_tls counts (the
    tool that sized every earlier program);
  - each `pthread_create` and `pthread_join`;
  - each thread's first 40 condition broadcasts or signals and barrier waits,
    with the caller's count;
  - every thread's count, each time a reference worker passes another 10 M.
- It sizes (E3, E5). It also reports two things that decide nothing:
  - where thread 0 is when its workers start;
  - the untraced threads' share of instructions while the reference worker
    goes from 50 M to 150 M, a native estimate of what QW measures in gem5.

**Builds.** Each is built from a copy, fortify off, `-O2 -g`. One set of
objects is linked dynamic and `-static`, and QB compares the two.
- **The C++ programs** use `-std=gnu++98 -fpermissive -pthread`.
  - PARSEC's code is C++98: bodytrack's dynamic exception specifications are
    an error under gcc 13's default, C++17.
  - PARSEC's own `gcc.bldconf` passes `-fpermissive`.
- **fluidanimate:** `Makefile.pthreads`' objects and flags. The drop-in is
  disabled, and checked: the binary calls `pthread_barrier_wait`.
- **bodytrack:** `Makefile.am`'s pthreads sources, compiled directly.
  - It gets the macros its configure would define for them: `USE_THREADS`,
    plus `HAVE_LIBPTHREAD` and `HAVE_STDINT_H`, which the code reads.
  - `-fexceptions`, as its bldconf.
  - The configure script is not run: no system libtool, and nothing else it
    sets is read by the code.
- **facesim:** PARSEC's pthreads build (PhysBAM's and TaskQ's makefiles,
  `version=pthreads`), plus `-fwrapv-pointer`.
  - Why: PhysBAM's 1-based arrays keep `base_pointer = array - 1`. gcc 13 at
    `-O2` assumes pointer arithmetic cannot wrap and drops `delete[]`'s null
    check, and the program crashed in its argument parser.
  - Tried first, not enough: `-fno-delete-null-pointer-checks` and
    `-fno-lifetime-dse`.
  - `-fwrapv-pointer` is the narrowest flag that works
    (`-fno-strict-overflow` also works): pointer arithmetic may wrap, and
    nothing else changes.
- **vips:** zlib, GLib 2.24, libxml2 and vips from PARSEC's sources, with its
  bldconfs' options, all static.
  - GLib's configure requires gettext's `msgfmt`, which the laptop lacks. A
    stub writes empty message catalogues: translations, never loaded.
  - Autotools outputs are stamped newer than their inputs, so make never
    reruns the server's newer autotools on them.
  - The static binary is the same objects, relinked by the same libtool
    command with `-all-static`.
- **ocean non-contiguous:** SPLASH-3's make, fortify off through `CC`, as
  step 4.
  - Its arrays are static, sized `IMAX = JMAX = 8194` on 64-bit targets. One
    struct is 15 GB: malloc refused it on the laptop, and gem5's 4 GB memory
    cannot hold it.
  - It is built with SPLASH-3's own 32-bit size, 2050 (the other branch of
    `decs.h.in`). That holds the 514-point grid it runs, about 1.9 GB.
- **QB compares each copy of a function.** A local function can share its
  name with one inside `libstdc++.a`, which only the static binary holds
  (bodytrack: `basic_string::_M_construct.isra.0`, 48 instructions in the
  program, 144 summed in the static binary).
  - Every copy in the dynamic binary must be in the static one, unchanged.
  - A global function must have exactly the same copies in both.
  - A function in neither binary (an archive member never linked) is
    counted, not compared.

**Inputs and arguments.** PARSEC's runconfs with NTHREADS = 4. No native
rung (Note 1).

| program | ladder (input set: arguments) |
|---|---|
| fluidanimate | simsmall `4 5 in_35K.fluid out.fluid`; simmedium `in_100K`; simlarge `in_300K` |
| bodytrack | simsmall `sequenceB_1 4 1 1000 5 0 4`; simmedium `sequenceB_2 4 2 2000 5 0 4`; simlarge `sequenceB_4 4 4 4000 5 0 4` |
| facesim | `-timing -threads 4` in the directory of `Face_Data` (one set: the three are one file) |
| vips | `--vips-concurrency=4 im_benchmark <image> output.v`: pomegranate, vulture, bigben |
| ocean non-contiguous | `-n514 -p4 -e1e-7 -r20000 -t28800` (ocean's) |

vips's runconf exports `IM_CONCURRENCY=${NTHREADS}`, which is 4 here. The
same count is given as `--vips-concurrency=4` (`im_init_world.c`). It sets
`im__concurrency`, which `im_concurrency_get` (`threadpool.c`) reads before
the environment variable. So the tracer, the counter and gem5 need no
environment.

**Laptop sizing (host CPUID).** The server's sizing is the record.

| program | threads | chosen | traced threads (M instructions) | main | native untraced / traced (QW's measure) |
|---|---|---|---|---|---|
| fluidanimate | 5 | simsmall | 1-4: 356-375 | creates the workers at 126.6 M, then waits in `pthread_join` | 0.00% |
| bodytrack | 6 | simmedium (simsmall: 227-255) | 1-4: 768-828 | dispatches, and runs the particle filter's serial steps | 3.97% (3.37% in an earlier run) |
| facesim | 4 | the one set | 0-3: main 14,212 (8,117 of set-up), workers 5,220-5,417 | the fourth worker | 0.00% |
| vips | 7 | simsmall | 3-6: 673-810 (a work queue) | creates six threads at 119.3 M, then joins | 0.00% |
| ocean non-contiguous | 4 | the one set | 0-3: 386-388 | creates three workers at 2.1 M and works | 0.00% |

**Traced threads (E3), fixed now.**
- **fluidanimate 1-4.** Main executes nothing in the window.
- **bodytrack 1-4.** Main dispatches and computes between the workers'
  phases. The image loader (5) ends before the window.
  - **QW is unchanged.** bodytrack is run as designed and is expected to
    fail QW: its native estimate, 3.4-4.0%, is above QW's 1%.
- **facesim 0-3.** TaskQ's `taskQInit` creates three threads, and main takes
  tasks as the fourth.
- **vips 3-6.** Threads 1 and 2 are helpers: they execute about 8 K
  instructions, then wait to the end. Threads 3-6 do the work.
- **ocean non-contiguous 0-3, from the start,** as the design says.

**facesim's thread 0: where its trace starts.**
- **The problem.** Neither of the design's rules fits:
  - PARSEC's (each worker from its creation, no cut) starts thread 0's trace
    at the start of the program;
  - SPLASH's (cut at the last `pthread_create`) starts it at 2.4 M.

  Both put thread 0's trace inside its serial set-up. Main creates the pool
  at 2.4 M instructions and starts its parallel work at its first
  `pthread_cond_broadcast`, 8,117.5 M on the laptop. The workers then reach
  10 M within the next 12 M of main's instructions.
- **Rule, fixed now:** facesim's thread 0 is traced from its first
  `pthread_cond_broadcast`.
- **It needs a tracer option, `-start0 broadcast`.**
  - Thread 0 records nothing until that call.
  - Its base record is written there, before the call's release is
    numbered, so the workers wait for that release.
  - Without the option, nothing changes.
- **Before facesim is traced,** the option is built and checked (QS, QK, and
  a micro case with hand-known positions). The checks and their results go
  into a note.
- **Sizing and gem5 do not need it,** so they start now.
- **If the option cannot be checked,** facesim is reported as not traced,
  and x264, then ferret, is built and sized, as after a failure of E3-E5.

**gem5.**
- One CPU per thread the program creates (`NCPU`): 5, 6, 4, 7 and 4.
- The runs stop when a worker (CPUs 1 to N-1) reaches 50 M and 150 M.
- The runs start from their output directory, with the chosen set's files
  copied there.
- The 96 h limit is enforced with `timeout`.
- facesim's runs simulate main's serial set-up first, about 8 G
  instructions: about 8.3 G for the 50 M stop and 8.8 G for the 150 M stop.
  - The rate depends on the server's load. lunc's runs (2026-11-04, light
    load) ran at 141-155 K instructions/s, which gives about 17 h. Step 4's
    runs, under load 75-120, ran at 10-22 K/s, which gives more than 96 h.
  - If the limit is reached, facesim is reported and not scored (the rule
    above). Nothing here changes it.

**Built later, each in a note before it runs:**
- `VARIANT=h2` of `sync_server.sh` (input directories copied, `-start0`);
- the counter runs;
- `stream_check2.py`'s range checks and QW.

## Note 3, 2026-11-04: gem5's worker stop watches the traced CPUs. A correction before any gem5 run of these programs

Written while the server sizes the programs (`heldout2_all.sh size`, started
2026-11-04), before any gem5 run of them has started. No number of theirs
exists.

**The error.** "Stops when a worker reaches 50 M and 150 M" was implemented
as every program before used it: `system.cpu[1:N].max_insts_any_thread`,
every CPU but CPU 0. Here some CPUs past 0 run helper threads.
- **bodytrack's image loader (thread 5, CPU 5)** executes 60.3 M
  instructions and ends while the reference worker is under 40 M (laptop
  probe). It would trip the 50 M stop early. gem5's window would then start
  with the workers near 30 M, not 50 M, and the loader's last 10 M would
  fall inside it.
- vips's helpers (threads 1 and 2) execute about 8 K instructions and could
  never trip it, but they are not workers either.

**The correction.** The stop watches the **traced threads' CPUs, CPU 0
aside**. Thread t runs on CPU t: each thread has its own CPU, and none ends
before the last is created. The rule:
- the CPUs are read from the program's PROGS line;
- they must form one contiguous range, or the launch stops;
- CPU 0 stays out, as before, since its count holds main's serial start.

| program | traced threads | stop on |
|---|---|---|
| fluidanimate | 1-4 | `cpu[1:5]` (as before) |
| bodytrack | 1-4 | `cpu[1:5]` (was `cpu[1:6]`) |
| facesim | 0-3 | `cpu[1:4]` (as before) |
| vips | 3-6 | `cpu[3:7]` (was `cpu[1:7]`) |
| ocean non-contiguous | 0-3 | `cpu[1:4]` (as before) |

This is what "a worker reaches 50 M" was meant to say, so no rule changes.

**Rehearsed** with the stand-in gem5: each program's two runs received the
slice above.

**Upload:** `scripts/heldout2_all.sh runners` replaces the two gem5 runners
on the server (through a new name and `mv`). It lists any held-out gem5 run
already launched. If bodytrack's or vips's runs started before the upload,
they are stopped and launched again, and the stopped runs are reported in a
note. Nothing of theirs is read.

**What the upload found (2026-11-04).** Sizing had already ended, 5 of 5
sized, and all ten runs had been launched with the old stop before the
upload:
- bodytrack `cpu1..5` and vips `cpu1..6`;
- fluidanimate, facesim and ocean non-contiguous on the slices above, so
  those six runs stand.

By the rule above, **bodytrack's and vips's four runs are stopped and
launched again** with `scripts/heldout2_all.sh regem5`.
- vips's old slice differed only by its two helpers, which execute about
  8 K instructions and could not reach 50 M. Its runs are relaunched anyway,
  as this note says.
- `regem5` stops a run only by its exact output directory, and only if the
  run's session holds nothing but `timeout` and gem5.
- The stopped runs' directories are kept as `<dir>.prev_<time>` and are not
  read.
- It prints each relaunched run's stop per CPU from gem5's own
  `config.ini`.
- Rehearsed with a stand-in gem5:
  - the four runs were stopped and launched again with the slices above;
  - fluidanimate's runs were untouched;
  - a session holding another process was refused.

## Note 4, 2026-11-04: facesim's tracer option, `-start0 broadcast`, and its checks, before it runs on the server

Written before the option is built on the server and before any program of
this set is traced. No number of theirs exists. Note 2 fixed the rule
(facesim's thread 0 is traced from its first `pthread_cond_broadcast`) and
required the option to be checked first (QS, QK and a micro case with
hand-known positions). This note says how it is built and checked.

**The option** (`simulator/tracer/pin/champsim_tracer.cpp`, `-start0 broadcast`):
- Thread 0 writes nothing until its first outermost `pthread_cond_broadcast`
  (any version the tracer hooks; QS lists them). Its window opens there:
  - K, the number of instructions thread 0 has executed, takes the place of
    `-skip_instr` for thread 0 only; `-max_instr` counts from K.
  - Thread 0's base record is written at that point, numbered as the next
    release (seq + 1), **before** the call's own release is numbered. So the
    broadcast is inside the trace, and a thread it woke waits for it in a
    replay. (Without this, the base would be written at the first record,
    after the numbering, and the broadcast would count as already done.)
  - Every earlier release of thread 0 is numbered before the base, so a
    replay counts it as done. Nothing of thread 0 before the call is in its
    trace.
- The other threads are traced as without the option.
- It requires `-sync 1`; any value other than `broadcast` stops the tracer.
- The tracer prints K and the base's seq when the window opens, and thread
  0's total N when it ends ("NEVER opened" if no broadcast came).
- Without the option the tracer behaves as before (Z7 below).

**One effect, expected and harmless.** facesim's first broadcast is in
TaskQ's `signalTasks`, which takes the task mutex before it. So thread 0's
trace starts inside a critical section: the lock is not in the trace, the
unlock is. ChampSim ignores a release of a mutex the core does not hold and
counts it (`releases of a mutex not held`), as it does wherever a trace was
cut while a mutex was held. **One such release is expected per facesim trace
set.** The workers' wake-up acquires wait for the broadcast, as recorded
(Z5), as they would without the option.

**Which tracer traces what.**
- **facesim:** this tracer, built on the server in its own tree,
  `~/sync_h2_build`.
- **fluidanimate, bodytrack, vips, ocean non-contiguous:** nc's tracer
  (`~/sync_nc_build`, md5 f39707f3; QS and QK held 2026-11-04), unchanged.
  They need no option, and Z7 shows that the new tracer, without the option,
  writes what nc's writes.
- **Both under gem5's CPUID:** the file nc froze after QE held,
  `~/sync_nc/gem5.cpuid`, md5 74d72229d62c92e4ce627b5298375a23, and no other.

**QZ, the micro case** (`bench/start0_micro.c`, `scripts/start0_check.py`).
start0_micro has facesim's start: main creates three workers, each takes the
mutex, counts itself ready and waits on the condition. Main runs a serial
phase of register-only work (2 M iterations), waits until all three wait,
then takes the mutex, sets the flag, broadcasts, stores and unlocks. Every
thread then works, stores to its own line, and runs a register-only tail.
Traced with `-sync 1 -start0 broadcast -cpuid gem5.cpuid -max_instr 0`:
- **Z1** the tracer reports K and N, once each.
- **Z2** thread 0's record 0 is its base (seq as reported), and record 1 is
  the first instruction of a hooked `pthread_cond_broadcast` (its address
  from the tracer's own list).
- **Z3** thread 0 holds exactly N - K instruction records.
- **Z4** thread 0's first release is the broadcast's (no mutex), numbered at
  the base; none of its releases is numbered before the base.
- **Z5** each of the three workers has exactly one acquire waiting for that
  release, right after its own release of the mutex (the condition wait).
- **Z6** the same tracer without `-start0`: thread 0 starts at its beginning,
  base seq 1 at record 0, no start0 message.
- **Z7** without `-start0`, this tracer against nc's on `stream_micro 1000`
  (`-sync 1`, gem5's CPUID): per thread, equal records, loads, stores, RMWs,
  branches, leftover bytes and sync records (`trace_mix`'s T line, its hash
  aside). Both runs with address randomisation off (`setarch -R`) where the
  machine allows it. Byte identity is reported, not required: an address can
  move with the tool's size (stream_fix amendment 1).
- **Z8** the `-start0` traces replay on the g6 binary (`~/sync_g6/BIN`, the
  binary that passed Q0; LRU, shared, level 2, 0 + 1 M): the run completes,
  no SYNC DEADLOCK, and exactly **1** release of a mutex not held.

**Local results, 2026-11-04** (laptop, real Pin 3.31 and glibc 2.39):
- **Host CPUID:** Z1 K = 10,150,985 of N = 12,154,877; Z2 record 1 is
  `pthread_cond_broadcast` in libc.so.6; Z3 2,003,892 = N - K; Z4 the
  broadcast is release 0x800 (seq 8 = the base), then the unlock; Z5 each
  worker waits for 0x800 right after its release of the mutex.
- **gem5's CPUID:** Z1 K = 10,147,274 of N = 12,151,100; Z3 2,003,826; Z2,
  Z4, Z5 as above.
- **Z6** holds. **Z7:** with `-sync 1` every thread's trace is byte for byte
  equal to the old tracer's. (With `-sync 0`, which no h2 trace uses, thread
  0's data addresses move by the tool's size; instruction pointers and
  counts are equal.)
- **Z8:** ChampSim completed all CPUs, no SYNC DEADLOCK, `releases of a mutex
  not held 1`.

**Rehearsed end to end** (`heldout2_all.sh tracer` against a fake server
home: real Pin, the old tracer standing in for nc's, the laptop's ChampSim
standing in for g6's, the streamfix build's tools):
- Upload, detached build, QS, QK and QZ all held, and the mode exited 0.
  Z1 K = 10,149,602 of 12,153,428; Z3 2,003,826; Z8 as above.
- Z7 with randomisation off: both threads' counts equal; thread 1 byte for
  byte, thread 0 not (the tool-size shift: the tracers differ in size).
- A second run with the same source and QZ passed does nothing and prints
  the status. With trace sets present from another source, it refuses.
  `chain` under h2 refuses.
- **Faults injected, each caught:**
  - a CPUID file with another md5;
  - a frozen `~/sync_h2/gem5.cpuid` that differs from the source;
  - a binary that is not g6's (`qz` mode);
  - traces without `-start0` checked as start0 (Z1, or with copied messages
    Z2-Z5);
  - host-CPUID traces with the gem5 run's messages (Z2, Z3);
  - a missing worker trace (Z5);
  - `-start0` traces checked as plain (Z6);
  - `-start0 signal`, and `-start0` without `-sync 1` (the tracer stops).
- The rehearsal found one script error before anything ran on the server:
  an unset variable under `set -u` (`NC_CPUID_SRC`). It is fixed, and the
  failure path stopped and reported as it should.

**On the server** (`scripts/sync_server.sh`, `VARIANT=h2`, uploaded as
`~/sync_server_h2.sh` so the live step-5 and lunc chains keep reading
`~/sync_server.sh`):
- `build` copies the CPUID file after checking its md5, builds the tracer
  (it must print `cpuid = ` and `start0 = broadcast`), then runs **QS**
  (mutex_micro, under gem5's CPUID), **QK** (cpuid_dump and stream_micro
  under it, as for nc) and **QZ** (Z1-Z8 above). Any failure stops the
  build, and nothing is traced.
- `qz` reruns QZ alone on a built tracer.
- `chain` refuses under h2 for now. Tracing and the runs come in a later
  note.
- One command: `scripts/heldout2_all.sh tracer`. It uploads the tracer's
  sources to `~/sync_h2_build`, the script as `~/sync_server_h2.sh`, and
  start0_micro.c, start0_check.py, trace_mix.c and mutex_micro.c to the home
  directory (a file already equal is left alone). It starts the build
  detached and follows its log. It refuses if trace sets exist from a tracer
  built from another source.
- **If QZ fails on the server,** facesim is reported as not traced and x264,
  then ferret, is built and sized (Note 2's rule).


**On the server, 2026-11-04 (`heldout2_all.sh tracer`; output in
`simulator/results/heldout2/tracer_20261104_2153.txt`): QS, QK and QZ hold.**
- Tracer built in `~/sync_h2_build`, md5 02ff8f48654b81f6f277cdac8a13d60b,
  source md5 18843187...; gem5's CPUID copied from `~/sync_nc`, md5 74d72229.
- **QS:** the server's glibc names the mutex routines `__pthread_mutex_lock`
  / `__pthread_mutex_unlock`; both are hooked. Every thread has 8 or more
  locks and unlocks, and 8 condition calls.
- **QK:** 354 lines equal, the 14 other pairs are gem5's aborts; stream_micro
  thread 1, tracer and counter equal (76,103 / 4,278 / 66,200 / 1,006).
- **QZ:**
  - Z1: K = 10,121,553 of N = 12,125,747; base seq 9.
  - Z2: record 1 is `pthread_cond_broadcast` in libc.so.6.
  - Z3: 2,004,194 = N - K.
  - Z4: the broadcast is release 0x900, at the base.
  - Z5: each worker waits for 0x900 right after its release of the mutex.
  - Z6 holds.
  - Z7 against nc's tracer f39707f3: both threads' counts equal, no thread
    byte for byte (the tracers differ in size; reported, not required).
  - Z8 on `champsim_g6_1e3060c1`: complete, 0 SYNC DEADLOCK, `releases of a
    mutex not held 1`.
- **The server differs from the laptop in ways that are not criteria.**
  Its glibc numbers one more release before the broadcast (seq 9, not 8),
  and the workers reach their wait later (record 878, not 180). Z8 reports
  `ordered acquires 1`, not 2.
- One message in the upload was noise. Checking whether `~/start0_micro.c`
  and `~/start0_check.py` already existed printed "No such file" before
  uploading them, because the redirect came before the error suppression.
  Fixed (`heldout2_all.sh`); nothing else changed.
- **facesim may be traced with this tracer** once the tracing note
  (`VARIANT=h2`) is written and committed.

## Note 5, 2026-11-04: the counter's BROADCAST line and `-base0 broadcast` (step 2), checked locally, before any counter run of these programs

Written before any counter run of a held-out set 2 program. No number of
theirs exists.

**Why.** facesim's thread 0 is traced from its first `pthread_cond_broadcast`
(Note 4). Each counter run must place that window itself, because K differs
between runs. The counter (`simulator/tracer/stream_count`) now:
- writes `BROADCAST tid rec ginst` in its summary at each thread's first
  outermost `pthread_cond_broadcast`. The position is the count before the
  routine's first instruction, as the tracer's K. The broadcast is found by
  name and by version-stripped routine name, as in the tracer, and nested
  calls are counted once. `HOOK` lines list the routines hooked.
- with **`-base0 broadcast`**, sets thread 0's window base at that
  broadcast: W is [base + from, base + to), and S is everything before it.
  A `pthread_create` does not move it, and the BASE0 line records it.
  Without the option, counts and windows are as before.
- facesim's counter runs use `-base0 broadcast`; the other four programs
  keep the rule they have. stream_check2.py reads facesim's thread-0 base
  from BASE0 (step 5's note).

**QR** (`bench/bcast_micro.c`, a thread 0 whose first broadcast is at the
same instruction in every run; `scripts/bcast_check.py`):
- **R1** bcast_micro, one thread: the counter's BROADCAST 0 position equals
  the tracer's K (`-start0`, Note 4); BASE0 equals it; the counter's thread-0
  total equals the tracer's N; the trace holds N - K records.
- **R2** `-base0 broadcast`: thread 0's line once, BASE0 equal; lines for
  exactly the threads that broadcast; S = K; W = to - from exactly; a create
  after the broadcast falls inside the window (W holds libc's
  `pthread_create`). Run on bcast_micro with a worker (threads 0 and 1
  broadcast) and on start0_micro (facesim's shape: only thread 0 broadcasts).
- **R3** without the option, against the committed counter (md5 9a5e6b48,
  rebuilt equal): on stream_micro 1000 and bcast_micro, every .cnt and .rtn
  file equal byte for byte, and the summaries equal apart from the
  BROADCAST / HOOK lines.

**Local results, 2026-11-04 (laptop, Pin 3.31, glibc 2.39): QR holds under
both CPUIDs.**
- R1, host: K = BROADCAST = 10,144,855, N = total = 26,149,341, trace
  16,004,486 = N - K. gem5's CPUID: 10,141,112 / 26,145,628 / 16,004,516.
- R2: W 10,000,000 and 1,000,000 exactly; S = K; the create (at K + 8.0 M)
  inside the window; thread 1's broadcast at 4,000,131; two broadcast
  versions hooked.
- R3: 4 and 2 files equal byte for byte.
- Found and fixed before these results: the first build opened thread 0's
  window only after its first create (W empty on one thread, 3 M of 10 M
  with a late create).

**Still to build (each before it runs):** the counter's server build and QR
there (h2's tree, `~/sync_h2_build`; the streamfix counter untouched), then
steps 3-5.

### Note 5 addendum, 2026-11-05: the server build and QR there, before anything is counted

**`scripts/heldout2_all.sh counter`** (laptop, one password):
- refuses without Note 5, with uncommitted files, while an h2 counter build
  runs, or before the h2 tracer passed QZ on the server;
- refuses if the server's counter was built from another source and counter
  runs exist in `~/sync_h2/count/` (one set of counts is never made by two
  counters); does nothing if this source already passed QR;
- uploads the counter's two sources to `~/sync_h2_build/simulator/tracer/stream_count/`
  (md5 checked there), `sync_server.sh` as `~/sync_server_h2.sh` (new name,
  then `mv`), and `bcast_micro.c`, `bcast_check.py`, `start0_micro.c` to `~`
  where their md5 differs;
- starts, detached, `VARIANT=h2 sync_server_h2.sh counter`: build the counter
  in that tree (it must carry `BASE0 broadcast`), then QR as above (R1, R2,
  R3) under gem5's CPUID (`~/sync_h2/gem5.cpuid`, QZ's file) and the host's.
  R1 uses the h2 tracer that passed QZ. R3's reference is the streamfix
  counter in `~/streamfix/build`, which is not rebuilt or touched. Address
  randomisation is off for R3 where `setarch -R` works;
- on success writes `~/sync_h2/QR_PASSED`, `COUNTER_MD5` and `COUNTER_SRC`;
- runs no program of held-out set 2.

**Rehearsed 2026-11-05** against a stand-in server on the laptop (fake ssh
and scp, a home with Pin, the h2 tracer from the committed source, the
streamfix counter rebuilt from `96c7da8` at md5 9a5e6b48, `stream_micro`, and
nc's gem5.cpuid at md5 74d72229):
- **QR holds under both CPUIDs.** gem5's: K = BROADCAST = 10,143,513, N =
  total = 26,148,029, trace 16,004,516 = N - K. Host: 10,147,249 /
  26,151,735 / 16,004,486. R2: W 10,000,000 and 1,000,000 exactly, the create
  inside the window. R3: 4 and 2 files equal byte for byte. The markers were
  written and the laptop printed "QR holds".
- **R3 also holds with address randomisation on** (counter 46636158, built
  again from the committed source, against 9a5e6b48). So the check does not
  depend on `setarch -R`, which the server may refuse.
- **Fault cases, each run through the whole command:**
  - F0, the same source again: "nothing to do".
  - Refused before anything changed:
    - F1, an uncommitted file;
    - F2, the design without Note 5;
    - F3, QZ not passed;
    - F4, a counter build running;
    - F5, another source while a counter run exists.
  - Stopped by QR (after F6, checked: no `QR_PASSED`, `COUNTER_MD5` or
    `COUNTER_SRC` left behind; F7 and F8 stop by the same path):
    - F6, a create moving thread 0's base under `-base0` (R2: W 14,006,707);
    - F7, the BROADCAST position one late (R1);
    - F8, thread 0's set-up counted in its window without the option (R3).
  - F9, the committed source after those failures: rebuilt, and QR holds.
- **Found by the rehearsal and fixed before the commit:**
  - A failed rebuild would have left an earlier `QR_PASSED` in place. The
    build and `qr` now clear the markers first.
  - F5's guard would have missed counts made by a counter of unrecorded
    source. It now refuses whenever counts exist and the recorded source is
    not this one.

### Note 5 amendment 1, 2026-11-05: QR failed on the server at R1; R1 now runs with address randomisation off, as R3 does. Written before any rerun.

**What failed** (`heldout2_all.sh counter`, `1c58035`; server 03:31; laptop
copy `simulator/results/heldout2/counter_20261105_0900.txt`):
- The counter built (md5 22776143).
- R1 under gem5's CPUID: tracer K 10,115,785, N 26,120,439. Counter
  BROADCAST 0 and BASE0 at 10,115,740, total 26,120,394. Both are 45 lower.
- After the broadcast the two runs agree exactly (N - K = 16,004,654 both,
  and the trace holds 16,004,654 records).
- QR stopped there: R2, R3 and the host's CPUID never ran. No marker was
  written and nothing was counted.

**Cause, found on the laptop (reproduced, then shown absent):**
- **Run-to-run variation from address randomisation, before `main`.** The
  committed counter ran six times on bcast_micro under gem5's CPUID. Thread
  0's total and BROADCAST position were +45 in 2 of the 6 runs (26,145,628
  against 26,145,673): the same 45 as on the server.
- The two runs' per-routine counts (`.rtn`) differ in one routine only:
  **ld.so's `strcmp`** (6,333 against 6,378 instructions). Its count depends
  on where the randomised layout puts the strings it compares.
- With `setarch -R`, 3 of 3 counter runs were identical. R1 was then run in
  full, the tracer and the counter both under `setarch -R`, 4 times under
  each CPUID: **it held 8 of 8**, with the same K and N every time. gem5's
  CPUID: K 10,141,112, N 26,145,628. The host's: 10,144,855 / 26,149,341.
- So R1, which compares two runs, was written without the precaution R3
  already had. Its earlier laptop passes were by chance: about half of all
  pairs agree.
- The tracer's CPUID code is the counter's own (`champsim_tracer.cpp`: "the
  code of stream_count.cpp"), so the two tools' CPUID answers are not a
  cause.

**Change (procedure only; every criterion unchanged, exact as before):**
- R1's tracer and counter runs run under `setarch -R`, as R3's do. QR stops
  if `setarch -R` does not work (on the server it does: the failed run printed
  "R3 with randomisation off" when it checked).
- R2 checks positions within one run and is unchanged.
- QR's earlier files are kept as `~/sync_h2/qr.prev_<time>`, and R1's trace is
  deleted pass or fail. The failed run left its ~1 GB trace in
  `~/sync_h2/qr/gem5/r1t/`; the rerun removes it.
- The counter's source and `bcast_check.py` are unchanged. The rerun is the
  same command, `scripts/heldout2_all.sh counter`. The failed build cleared
  `COUNTER_SRC`, so it rebuilds, which takes seconds.

**What it means later (for step 4's note, not decided here):**
- A program's counter runs differ by such start-up amounts from run to run,
  in thread 0's set-up (S), outside every window. The native range (three
  counter runs, QC) measures run-to-run variation as it is, randomisation on.
- facesim's thread-0 window is based at each run's own broadcast. A
  set-up shift moves the base with the broadcast, and the window's content
  after it was identical here (N - K equal).

**Rehearsed 2026-11-05** against the stand-in server, set up as the server is
now (markers cleared, an earlier QR directory holding a trace):
- QR holds under both CPUIDs with R1 and R3 under `setarch -R`. gem5's
  CPUID: K = BROADCAST = 10,143,558, N = total = 26,148,074. Host: 10,147,249
  / 26,151,735.
- The earlier QR directory was kept as `qr.prev_<time>` with its `pin.err`,
  and its trace was removed.
- With a `setarch` that refuses, QR stopped ("setarch -R does not work
  here") and left no marker.
- The same command then passed again.

### Note 5 result, 2026-11-05 (laptop 09:25; `c4b0e6e`): QR holds on the server

`scripts/heldout2_all.sh counter`; laptop copy
`simulator/results/heldout2/counter_20261105_0925.txt`. Counter
`~/sync_h2_build/.../stream_count.so`, md5 22776143. Tracer 02ff8f48;
streamfix counter cb5902c7 (untouched). R1 and R3 ran with randomisation off.
- **gem5's CPUID:**
  - R1: K = BROADCAST = BASE0 = 10,115,738; N = total = 26,120,392; trace
    16,004,654 = N - K.
  - R2: W 10,000,000 and 1,000,000 exactly; S = K; the create inside the
    window; thread 1's broadcast at 4,000,828.
  - R3: 4 and 2 files equal byte for byte.
- **Host's CPUID:**
  - R1: 10,122,323 / 26,126,950; trace 16,004,627.
  - R2 and R3 hold as above.
- The failed run's randomised positions were +2 (counter) and +47 (tracer)
  from these. Each run has its own variation and the rule fixes none of it;
  with randomisation off both tools agree exactly.
- Markers `QR_PASSED`, `COUNTER_MD5` (22776143...), `COUNTER_SRC` (5ceba279...)
  written. **Step 2 is done. Nothing of held-out set 2 has been counted.**

## Note 6, 2026-11-05: step 3, the traces and the ChampSim runs (`VARIANT=h2`), before anything is traced

Written before any held-out set 2 program is traced. No trace, count or
ChampSim number of theirs exists. Their gem5 runs exist: eight have ended, and
facesim's two are running. None has been pulled or read.

**One command, `scripts/heldout2_all.sh trace` (laptop).** It uploads
`sync_server.sh` as `~/sync_server_h2.sh` (new name, then `mv`) and starts,
detached, `VARIANT=h2 bash ~/sync_server_h2.sh chain`. It returns once the
chain has started.

**The chain refuses to start unless:**
- h2's tracer passed QS, QK and QZ (`~/sync_h2/QZ_PASSED`), and its md5 is
  02ff8f48654b81f6f277cdac8a13d60b, the build Note 4 recorded;
- nc's tracer (`~/sync_nc_build`) passed QS and QK under gem5's CPUID
  (`~/sync_nc/QS_PASSED`, `QK_PASSED`), and its md5 is
  f39707f3e4e197c409b362706a69e268, the build that passed;
- `~/sync_h2/gem5.cpuid`'s md5 is 74d72229d62c92e4ce627b5298375a23 (QE's
  file);
- the binary is the g6 variant's `champsim_g6_1e3060c1`, which passed Q0 and
  Q0m (as nb, nc and pol);
- all five programs are sized (`~/heldout2/<p>/SIZED`), and
  `~/heldout2/PROGS` and `~/heldout2/JOBS` hold exactly their five lines.

**What is traced** (the lines sizing wrote, Note 2; nothing re-chosen):
- Each program is the dynamic build with the chosen rung's arguments. It runs
  in its trace directory with that rung's input files and directories copied
  there (bodytrack's `sequenceB_2` and facesim's `Face_Data` are
  directories).
- **Threads:** fluidanimate 1-4, bodytrack 1-4, facesim 0-3, vips 3-6,
  ocean non-contiguous 0-3.
- **Starts:** PARSEC workers from their creation; ocean non-contiguous's
  threads from the start. facesim's thread 0 starts at its first
  `pthread_cond_broadcast` (`-start0 broadcast`).
- **Tracers:**
  - facesim: h2's (Note 4);
  - the other four: nc's (the design).
  - Both run with `-cpuid ~/sync_h2/gem5.cpuid -sync 1`.
- **Length:** 215 M records per traced thread. For facesim's thread 0 they
  count from its broadcast (the tracer's `-max_instr` counts after `skip0`).
  From the sizing: workers 356-828 M, facesim's thread 0 about 6.1 G after its
  broadcast, ocean non-contiguous 386-388 M.
- Two programs are traced at a time, through FIFOs into xz, as before.

**Checks on each trace set (as step 4; nothing is run from a set that fails):**
- Pin exits 0, and no thread's sync calls are left unbalanced.
- Every traced thread has a trace.
- facesim: the tracer reports where thread 0's window opened (not "NEVER").
- **QT:** every trace used holds at least 172.5 M instructions (records minus
  sync records, from `trace_mix`).
- **The length rule:** if QT fails for length, the program is traced again
  once with the whole run (newbench amendment 2's rule where there is no
  anchor). None of the five is expected to need it.
- `DONE` records the tracer's md5 and `CPUID` the gem5.cpuid md5.
- One program's failure does not hold back the others' runs. A program that
  fails is reported, not traced again by hand.

**ChampSim runs:**
- One per program, from its traces only if they passed (`DONE`).
- The binary is `champsim_g6_1e3060c1`. The settings are as the design says:
  level 2, shared, LRU, the fixed 2 MB LLC, 4 cores, 50 M + 100 M.
- Trees `phaseA_b3_h2_<program>4`. All five run at once.

**Not in this step:**
- The counter runs (step 4).
- Q3, QC, v2, QW and every ratio (step 5's note).
- No B3 number of these programs is read before step 5's note is written.
  Q3 is read with the other checks then.
- ocean non-contiguous is run and reported apart and never counted
  (the design).

**Cost on the server:**
- Tracing two programs at a time takes about 5-8 cores each (Pin and an xz per
  traced thread).
  - Earlier trace sets took 77-827 MB each, so these should take under 5 GB in
    all. 151 GB was free on 2026-11-05.
  - facesim first executes its 8.1 G set-up under Pin, writing nothing.
- Then five 4-core ChampSim runs, about 3-6 h each at the current load (20 of
  48 cores, step 5 using 16).

**Rehearsed 2026-11-05 against a stand-in server** (fake ssh and scp):
- **The home held:**
  - h2's tracer from the committed source;
  - nc's tracer rebuilt from `f5a8539`, its commit;
  - QE's gem5.cpuid;
  - the laptop's g6 build (`bin/champsim`, which prints the line the variant
    needs);
  - five stand-in programs with the real ones' thread layouts and inputs. One
    pthread program reads its input from a file (fluidanimate, vips) or a
    directory (bodytrack's `sequenceB_2`, facesim's `Face_Data`).
- The lengths were shortened by environment only: 3 M records, QT 2 M, runs
  0.5 M + 1 M.
- **Guards, each through the whole command, each refused before anything
  ran:**
  - the wrong h2 tracer md5;
  - the wrong nc tracer md5;
  - an altered gem5.cpuid;
  - a program not sized;
  - an extra line in PROGS;
  - nc's QK not passed;
  - QZ not passed;
  - a second launch while the chain runs.
- **The pass:**
  - Each set's `DONE` names the tracer Note 6 gives: h2's for facesim, nc's
    for the other four.
  - `CPUID` is 74d72229, and every run reported "cpuid: replaced 32 unlisted
    0".
  - The inputs were copied into the trace directories, the two directories
    included.
  - facesim's thread 0 opened at its broadcast: 10,157,200 instructions in,
    base seq 7, 3,001,475 records of which 1,475 are sync records. The runs
    read `raw0`, not an aligned file.
  - vips was given a length below QT on purpose. QT failed and the rule traced
    it again with the whole run, and it passed (6,122,720 records).
  - Five trees `phaseA_b3_h2_<p>4`. The runs read threads 1-4, 1-4, 0-3, 3-6
    and 0-3, with sync replay on.
  - All five completed with 0 unexplained violations and no `SYNC DEADLOCK`.
  - A relaunch skipped the traced sets and the completed runs.
- **Found by the rehearsal, in the stand-in, not the pipeline:**
  - The first stand-in for ocean non-contiguous did more serial work in main
    before creating its workers than its 3 M-record trace held. So the
    workers waited for a create its trace never reached. Main replayed on
    (CPU 0 at 70 M) while CPUs 1-3 waited.
  - The replay's deadlock detector needs 30 periods of 10 M cycles. That is
    about 1.5 h at the stand-in's speed, so the run was stopped by hand.
  - The real program creates its workers at 2.1 M of its 215 M. With the
    stand-in fixed, it completed.
  - Kept for the record: a trace that ends before a release another traced
    thread waits for stalls that thread. It is caught only by the 300 M-cycle
    detector, and Q3's `SYNC DEADLOCK` reports it.
- **Changed after the first pass:** the h2 status shows the builds' QZ / QR
  lines only before the chain starts. That change only affects the status
  display. The relaunch ran the final file.

### Note 6, started 2026-11-05 05:11:36 server time (laptop 10:41; `e5a1782`)

`scripts/heldout2_all.sh trace`; laptop copy
`simulator/results/heldout2/trace_20261105_1041.txt`.
- Every guard passed: h2's tracer 02ff8f48, gem5.cpuid 74d72229, the g6
  binary `champsim_g6_1e3060c1`, Q0, and the five sized programs.
- The chain is alive: five programs to trace, two at a time, then five runs.
- At the start, step 5's 16 runs were 16 h in, every held-out gem5 run had
  ended (facesim's two included), the load was 33.5 of 48, and 151 GB was
  free.

### Note 6, tracing done 2026-11-05 (status at laptop 11:47; `status_20261105_1147.txt`)

- **5 of 5 traced.** Each line is written only after QT holds and the
  program's `DONE` marker is set:

  | program | traced (server time) | traces on disk |
  |---|---|---|
  | bodytrack | 05:25:33 | 229 MB |
  | fluidanimate | 05:38:01 | 172 MB |
  | facesim | 05:42:49 | 221 MB |
  | oceannc | 05:47:53 | 340 MB |
  | vips | 05:54:04 | 202 MB |

- The chain is alive, with 0 of its 5 runs complete.
- 150 GB was free on the disk.
- The pull at 05:25:50 counted no tracer process. That was a gap between Pin
  runs: bodytrack had finished 17 s earlier.
- No trace count, run row or ratio has been read.

## Note 7, 2026-11-05: step 4, the counter runs, written before any is made

No counter run of these programs exists, and none of their trace counts or
ChampSim rows has been read. Their five ChampSim runs are in flight.
streamcluster joins by newbench amendment 3 (`4baf804`).

**What runs: 24 counter runs.**
- **Programs:** the five of this set and streamcluster.
- **Runs per program:**
  - three under gem5's CPUID (`gem5 1-3`);
  - one under the host's (`host 1`), reported only, as the design says.
- **The counter:** h2's build, `~/sync_h2_build/.../stream_count.so`, md5
  `22776143`.
  - QR held on the server on 2026-11-05.
  - Without `-base0`, R3 showed it counts exactly as the streamfix counter,
    byte for byte.
- **Each run is the program as traced:**
  - the PROGS line the chain traced (`~/heldout2/PROGS`; streamcluster's line
    from `~/newbench/PROGS`, unchanged): the same binary, arguments and
    standard input;
  - the input files copied with `cp -r` into the run's own directory, which
    is its working directory;
  - the binary's md5 recorded in the run's directory.
- **Options:** `-o c -skip <field 7>`, and:
  - **facesim:** `-base0 broadcast`. Thread 0's window is based at its first
    broadcast, where its trace starts.
  - **the other five:** `-cut0 0`. Thread 0's window counts from its start,
    as ocean non-contiguous's trace does. In the PARSEC programs thread 0 is
    not traced, so its row does not enter.
  - **Window:** the default `-from 50000000 -to 150000000`, counted from
    each traced thread's base (a worker's creation; thread 0 as above). This
    is v1's window of the traces: records 50-150 M.
  - **Under gem5's CPUID:** `-cpuid ~/sync_h2/gem5.cpuid` (md5 `74d72229`,
    the file the traces used).
- **Address randomisation stays on**, as when the traces were made. The
  native range then measures run-to-run variation as it is (Note 5, "what
  it means later").

**QE-h2, before any count.**
- `cpuid_dump` (`~/streamfix/build`) runs under this counter with `-cpuid`
  that file.
- `cpuid_qe.py` then applies QE's rule: every line gem5 answered is equal,
  and extra pairs appear only where gem5 aborts.
- QE held on the streamfix counter; this repeats it on the binary that
  counts.
- **If QE-h2 fails, nothing is counted.**

**How the runs go.**
- Four at a time, at `nice 10`, the longest first (facesim).
- **Time limit: 12 h a run.**
- **A run that does not exit 0** is run again once, in a fresh directory.
  The failed attempt is kept in `~/sync_h2/count/failed/`.
  - After a second failure, its program has no native range.
  - QC and v2 then read "not checked": the program is reported and not
    scored.
- **Output:** `~/sync_h2/count/runs/<program>__<gem5|host>__<k>/`, the
  layout `stream_check2.py rows` reads. The driver's log is
  `~/sync_h2/count/driver.log`, and QE-h2's run is in `~/sync_h2/qeh2/`.
  - The counter's files: `c.summary`, `c.t<tid>.cnt`, `c.t<tid>.rtn`.
  - `STATUS` (exit code and time).
  - `RUN`: the binary's, counter's and CPUID file's md5s, and the options.
- **Checks when the runs end** (structure only; no rate is printed):
  - each run exited 0;
  - its `KNOBS` lines show the options above;
  - each facesim run has one `BROADCAST 0` line and one `BASE0` line;
  - every traced thread has its `.cnt` file.

**Guards (the command refuses otherwise).**
- QR_PASSED, and the counter's md5 equals COUNTER_MD5 (`22776143...`).
- `gem5.cpuid`'s md5 is `74d72229`.
- `cpuid_dump` and `cpuid_qe.py` exist.
- Each program's binary exists.
- streamcluster's line is in `~/newbench/PROGS` exactly once.
- No counter run already exists from another counter.

**Nothing is read.**
- The counts come to the laptop with `heldout2_all.sh pullcount`.
- `stream_check2.py rows` is not run on them before step 5's note is
  written and committed.
- QC, v2 and QW are step 5's note.

**streamcluster's trace and run (amendment 3's pipeline).**
- Once the chain's five runs have ended, `heldout2_all.sh sc` writes
  `~/heldout2/streamcluster.PROGS` and `.JOBS` (the lines from `~/newbench`,
  unchanged) and starts the chain again.
- With those files, the h2 variant reads six programs. streamcluster's
  sizing check is step 4's own (`~/newbench/streamcluster/SIZED`).
- The five done are skipped, and streamcluster is traced by nc's tracer
  under gem5's CPUID, as the PARSEC programs were. QT and the length rule are
  as Note 6.
- It is then run on the g6 binary into `phaseA_b3_h2_streamcluster4`.
- Started only on the owner's word, as every step.

**Commands (each on the owner's word):**
- `scripts/heldout2_all.sh count`: uploads `sync_server.sh` as
  `~/sync_server_h2.sh` (a new file then `mv`, so the live chain keeps its
  copy), then starts QE-h2 and the 24 runs, detached;
- `status`;
- `pullcount`;
- `sc`, once the chain's five runs have ended.

### Note 7, rehearsed 2026-11-05 (stand-in server; real Pin, the counter built from the same source, gem5's real `gem5.cpuid`)

- **`count`:**
  - QE-h2 holds: 354 lines equal, and the 14 other pairs are the 14 gem5
    aborts on ("CPUID replaced 402 unlisted 0").
  - 24 of 24 runs exited 0.
  - facesim's runs show `KNOBS base0 broadcast`, one `BROADCAST 0` line and
    one `BASE0` line. The other five show `cut0 0`.
  - Every run shows the 50-150 M window and gem5's CPUID file (or `host`).
  - Each run's `RUN` file holds the binary's, counter's and CPUID file's
    md5s.
  - "COUNT DONE".
- **Guards refuse, each alone:**
  - G2: the counter is not COUNTER_MD5's;
  - G3: the CPUID file's md5;
  - G4: no `cpuid_dump`;
  - G5: two streamcluster lines;
  - G5b: a seventh program;
  - G6: counts already made by another counter.
- **G1:** after DONE there is nothing to do, and the laptop command returns
  at once.
- **G7: QE-h2 fails** (an injected checker that answers "differs"): no run
  is made, there is no QEH2_PASSED and no DONE, and the laptop command
  reports it stopped.
- **G8: a run fails once** (a stand-in that exits 3 the first time): it is
  retried, 24 of 24 exit 0, and the failed attempt is kept in `failed/`.
- **G9: a run fails twice:** "did not exit 0" names each such run. "COUNT
  ENDED WITH FAILURES", no DONE, and 4 directories in `failed/`.
- **G10: facesim's line without `start0:broadcast`:** the structure check
  names each facesim run with no base, and there is no DONE.
- **L1:** `count` refuses while the counter driver is alive.
- **L2:** `pullcount` copies the 24 runs' count files, about 2 MB here. The
  program's own outputs stay on the server, and no rate is printed.
- **`sc`:**
  - S1: refused while the chain is alive, and no streamcluster file is
    written.
  - S2: streamcluster's lines written; the chain traced it (nc's stand-in
    tracer, under gem5's CPUID, workers 1-4 on CPUs 0-3) and ran it (complete).
    The five programs already done were skipped: "6 of 6 runs complete".
  - S3: a streamcluster line that is not step 4's stops the chain, and no
    chain starts.
  - S4: a relaunch with nothing left to do now says so ("nothing left to
    do: ... CHAIN END"). Before, it read "did not start", which was a false
    alarm in the launcher, older than this note.
  - S5: a chain that fails at once is still reported.
- **Fixed during the rehearsal:**
  - `count` waited 5 min after "nothing to do";
  - a "No such file" message on the first `count`;
  - the false "did not start" above;
  - three mistakes in my test script.

  None of these changes what is counted or how.
- **The live chain on the server is unaffected by `count`'s upload.** It
  has started all five of its runs (`xargs` holds no more lines), and after
  that it never reads `sync_server_h2.sh` again. The new file arrives
  through a new name and `mv`.

### Note 7, started 2026-11-05 07:29 server time (laptop 12:59; `678af2c`)

`scripts/heldout2_all.sh count`, run by Claude on the owner's word ("yup
start"), now that key login is set up. Laptop copy:
`simulator/results/heldout2/count_20261105_1259.txt`.
- **QE-h2 holds on the server** (07:29:25): 354 lines equal, and the 14
  other pairs are the 14 gem5 aborts on ("CPUID replaced 401 unlisted 0").
- **The first four runs are facesim's.** The `RUN` file of `gem5 1` shows:
  - counter `22776143`;
  - CPUID `74d72229`;
  - options `-o c -skip 0 -base0 broadcast -cpuid ~/sync_h2/gem5.cpuid`.
- **The h2 chain is still alive,** with its five ChampSim runs untouched
  (0 of 5 complete).
- The load average was 22.5 on 48 cores.

## Note 8, 2026-11-05: step 5, the checks and the score, fixed before any number of these programs is read

Written before any trace count, counter count, ChampSim row or gem5 rate of
held-out set 2 or of streamcluster's gem5-CPUID trace has been read.
- **What exists:**
  - the five ChampSim runs and the 24 counter runs are in flight on the
    server;
  - the five trace sets' counts (`raw<t>.mix`) are on the server, not pulled;
  - the ten gem5 runs' files came to the laptop with the 05:25 pull and are
    unread. Only `b3_stream_check.py extract`'s one printing of request counts
    by type happened (`newbench_lunc_results_2026-11-05.md`, "Not read");
  - streamcluster is not traced yet (`sc` comes after the chain's five runs).
- **No rule of the design changes.** This note fixes the code, the files and
  the order. Where the design's words leave a choice, it is made below,
  before any number exists.

**One checker: `scripts/heldout2_score.py`.** Four modes make row files from
pulled files (facts only), and two read them:
- `check`: every check, per program, and whether the program is scored. It
  prints the stream checks' rates and gem5's event count, never a B3 ratio.
- `score`: `check`, then `b3_score.py`'s block (`h2@set2`) **for the
  programs that pass every check and only those**, then the target.

**The programs, fixed in the script** (Notes 2, 3, 4, 6; amendment 3):

| program | traced threads (= gem5 CPUs) | gem5 CPUs | stop on | static binary | tracer | role |
|---|---|---|---|---|---|---|
| fluidanimate | 1-4 | 5 | 1-4 | `~/heldout2_static/fluidanimate` | nc's f39707f3 | counted |
| bodytrack | 1-4 | 6 | 1-4 | `~/heldout2_static/bodytrack` | nc's | counted |
| facesim | 0-3 | 4 | 1-3 | `~/heldout2_static/facesim` | h2's 02ff8f48 | counted |
| vips | 3-6 | 7 | 3-6 | `~/heldout2_static/vips` | nc's | counted |
| ocean non-contiguous | 0-3 | 4 | 1-3 | `~/heldout2_static/OCEAN-NC` | nc's | apart |
| streamcluster | 1-4 | 5 | 1-4 | `~/splash-newbench/streamcluster` | nc's | step 4 |

gem5 runs: `heldout2/<p>/l2_2MB_mi{50,150}M/<p>_4c`. streamcluster's are
step 4's `newbench/streamcluster/...`.

**The checks as coded** (the design's tolerances, unchanged):
- **QB:** set 2: the sizing's `SIZED` marker. `heldout2_server.sh` writes it
  only after QB held (`qb ... || return 1` comes first).
  streamcluster: step 4's sizing (`CHOSEN`), whose QB held.
- **QT:**
  - the set's `DONE` names the table's tracer;
  - `CPUID` is 74d72229;
  - there is no `FAILED` and no unbalanced sync call;
  - every traced thread holds at least 172.5 M instructions (records minus
    sync records, trace_mix's T line) and reaches record 150 M;
  - facesim's `pin.err` says thread 0's window opened;
  - the length rule, if applied (`LEN`), is reported.
- **Q3**, from the run log and the rows:
  - the run completed;
  - no `SYNC DEADLOCK` and no `Reached end of trace`;
  - in the Region of Interest block, `VIEW-ORDER VIOLATIONS UNEXPLAINED` 0
    and the raw count equal to the lines by silent re-listing;
  - `SYNC REPLAY: on`, `SYNC MUTEX ORDER: timing`;
  - CPU c runs `traces/sync_h2/<p>/raw<t_c>` in the table's order;
  - the chain's log names `champsim_g6_1e3060c1` at its start;
  - from the rows: both complete with equal instructions; self-check 0 with
    12 private caches; stale-holders 0; level 2; no page-pool or wrap flag.
  - Releases of a mutex not held are reported. facesim expects 1 (Note 4).
- **QG**, from `config.ini`, `run.log` and the gem5 rows:
  - both runs ended at their stop;
  - the table's CPU count and static binary;
  - L2 2,097,152 bytes and randomization false;
  - `max_insts_any_thread` equal to the stop on exactly the "stop on" CPUs,
    0 on every other (Note 3);
  - no counter smaller at 150 M than at 50 M.
- **QW:** in gem5's window (150 M stop minus 50 M stop, per CPU), the
  untraced CPUs' instructions over the traced CPUs' must be under 1%.
- **The counter runs.** A run is usable only if all of these hold:
  - exit 0 in `STATUS` and in its summary;
  - the counter is 22776143da830acac58082ebc8f2eede;
  - a gem5 run has CPUID 74d72229 and `KNOBS ... cpuid .../sync_h2/gem5.cpuid`;
    a host run has `host`;
  - the window is 50-150 M and the threads are the table's;
  - facesim has `KNOBS base0 broadcast`, one `BASE0` with a number and one
    `BROADCAST 0`; the others have `cut0 0`, no base0 and skip 0;
  - every traced thread's window is present.

  If any of the three gem5-CPUID runs is unusable, the program has no native
  range: QC and v2 read "not checked" and fail (Note 7). The host run is
  printed and decides nothing.
- **The windows.**
  - **Trace:** records [50 M, 150 M) of each traced thread's trace. Sync
    records count as records, as in v1 (`b3_stream_check.py window`; the same
    arithmetic, checked below).
  - **Counter:** positions [base + 50 M, base + 150 M) on its 100,000-record
    grid (rounded as `stream_check2.py rows` rounds, at most 0.05% at each
    end).
    - base 0 for a worker (from its creation) and for ocean non-contiguous's
      thread 0;
    - facesim's thread 0 at its run's own `BASE0`.
  - Summed over the traced threads.
- **QC:** for loads, stores and RMWs per 1,000 records, the trace's rate x
  must satisfy lo × 0.99 ≤ x ≤ hi × 1.01. lo and hi are the least and the
  greatest of the three gem5-CPUID runs. For RMWs, lo − 0.01 ≤ x ≤ hi + 0.01
  also passes.
- **v2:** per 1,000 instructions in gem5's units:
  - gem5's rates:
    - loads: MemRead + FloatMemRead on the traced CPUs, over their
      instructions;
    - stores: MemWrite + FloatMemWrite, the same way;
    - RMWs: Ruby's RMW_Read + Locked_RMW_Read over all instructions, as
      `stream_check2.py`.
  - The counter runs' rates: gld, gst and rmw, each over ginst.
  - gem5's rate g must satisfy lo × 0.95 ≤ g ≤ hi × 1.05. For RMWs,
    lo − 0.05 ≤ g ≤ hi + 0.05 also passes, and RMWs gate.
  - **The held-out rule:** for loads and stores, a g outside that range but
    inside lo × 0.92 to hi × 1.08 is scored, with the miss from the range
    stated. Beyond that, nothing is scored.
  - Per-thread rows (counter run gem5 1 against gem5's CPU) are printed and
    decide nothing.
- **500:** (SS + MT) L1_GETX at 150 M minus at 50 M, from the gem5 rows, as
  `b3_score.py` counts it. It must be at least 500.

**Choices the design's words left open, made now:**
- **The range.** "Widened by 1% (5%, 8%) on each side" means the least run
  × (1 − x) and the greatest × (1 + x). "Within 0.01 (0.05) per 1,000"
  means within that distance of the range's ends.
- **For a point range** (three equal runs) this is the single-run rule, with
  the tolerance taken relative to the counter's rate where v1's QC took it
  relative to the trace's. Equal to second order.
- **The 500 events are a check.** The design lists them under "Qualifying
  checks (before any ratio is read)". So the ratios of a program under 500
  are not printed. Step 4 printed lu's and raytrace's beside their counts.
  Here they are not printed.
- **PENDING is not a failure.** A program with no trace set, no ChampSim
  run log or no counter run yet is "pending", with its checks printed so
  far. It is scored by the same command once the missing part exists.
  - The target reads NOT YET DECIDED while pending programs could still
    meet it.
  - A run log without completion is a Q3 failure, not pending.
- **`.prev_*` directories are skipped** by `b3_score.py gem5-rows`,
  `b3_stream_check.py extract` and `stream_check2.py gem5rows`. These are
  Note 3's stopped runs, "not read". Before, `gem5-rows` stopped on them (0
  statistics dumps).

**The target is computed by `score`:** the counted programs (fluidanimate,
bodytrack, facesim, vips) that pass every check. MET at two or more.
Agreement on them is P15, and a P15 miss is stated beside it. Ocean
non-contiguous and streamcluster never count toward it.

**The predictions,** printed per scored program by `b3_score.py`'s block
(`ref == 'set2'`, the same arithmetic as step 4's P8-P10):
- **P15:** R_g5 in 0.5-2.
- **P16:** R_b ≥ R_g5.
- **P17:** traffic in 0.5-2.

streamcluster's line reads P8-P10, and ocean non-contiguous's says it is
reported apart. Upgrades (U_g5) are printed and not predicted.

**Expected, stated now (not predictions; nothing is changed if they come
out otherwise):**
- bodytrack fails QW (Note 2: native 3.4-4.0%).
- facesim's run reports 1 release of a mutex not held (Note 4).

**The order, on the laptop, once the five runs and the 24 counter runs have
ended:**

```bash
scripts/pull_results.sh            # rows; gem5 (stats, run.log, config.ini); NEW: held-out set 2's trace reports, run logs, sizing markers, the chain's log
scripts/heldout2_all.sh pullcount  # the counter runs
python3 scripts/heldout2_score.py tracerows simulator/results/heldout2/traces simulator/results/heldout2/server simulator/results/newbench/server > bench/policy_sanity/h2_trace_rows_v1.txt
python3 scripts/heldout2_score.py countrows simulator/results/heldout2/count > bench/policy_sanity/h2_count_rows_v1.txt
python3 scripts/heldout2_score.py runrows simulator/results/heldout2/logs simulator/results/heldout2/driver.log > bench/policy_sanity/h2_run_rows_v1.txt
python3 scripts/heldout2_score.py gem5cfg simulator/results/gem5_b3 > bench/policy_sanity/h2_gem5_config_v1.txt
python3 scripts/stream_check2.py gem5rows simulator/results/gem5_b3 > bench/policy_sanity/gem5_percpu_v2.txt
python3 scripts/b3_stream_check.py extract simulator/results/gem5_b3 > bench/policy_sanity/gem5_mix_v6.txt
python3 scripts/b3_score.py gem5-rows > bench/policy_sanity/gem5_b3_rows_v6.txt
python3 scripts/heldout2_score.py score bench/policy_sanity/h2_trace_rows_v1.txt bench/policy_sanity/h2_count_rows_v1.txt \
  bench/policy_sanity/h2_run_rows_v1.txt bench/policy_sanity/h2_gem5_config_v1.txt bench/policy_sanity/gem5_percpu_v2.txt \
  bench/policy_sanity/gem5_mix_v6.txt bench/policy_sanity/gem5_b3_rows_v6.txt bench/policy_sanity/phasea_rows_v<N>.txt bench/policy_sanity/b3_rows_v<K>.txt
```

- Before `score`, the v6 gem5 files must hold every v5 row unchanged (and
  `gem5_percpu_v2` every v1 row). A difference stops the scoring.
- The output goes into a results document whole, as it is printed.
- streamcluster is scored when its trace and run exist (after `sc`), by the
  same command on new versions of the row files. The first scoring shows it
  as pending.

**Tested before this note (laptop; nothing of these programs was read):**
- **The gem5 readers** (on a copy of the gem5 tree without `heldout2/`, as
  for v5):
  - `gem5-rows` and `extract` give `gem5_b3_rows_v5.txt` and
    `gem5_mix_v5.txt` byte for byte;
  - with a `.prev_` directory added, all three readers give the same output
    as before. The committed `b3_score.py` stops on it (exit 1).
  - `b3_score.py score` over 11 generation specs (v5 to n2@new) gives byte-identical
    output (md5 fda04fdb) after the `set2` change.
- **The row makers, on real files already scored:**
  - `countrows` on the streamfix counter runs: streamcluster's 8 window rows
    equal `stream_v2_rows_v1.txt`'s;
  - `tracerows` on lunc's `.mix` files: the window rows equal `trace_mix_v5`'s
    `lunc_4t_window_t0-3`;
  - `runrows` on lunc's run log: complete, 0, 0, view-order 0 / 0 / 0,
    timing, 1 release not held (`newbench_lunc_results`);
  - `gem5cfg` on lunc's two runs: 4 CPUs, `LU-NC`, 2,097,152, false, the stop
    on CPUs 1-3 only, ended at the stop.
- **The native range at a point, on real data:** streamcluster's streamfix
  runs, each copied as gem5 1-3, give the rates `stream_check2.py check`
  printed:
  - QC: 284.070 / 284.072, 3.278, 0.005;
  - v2 under gem5's CPUID: 284.295 against 284.314; 2.878 against 2.806;
    0.005.
- **A synthetic set of the nine files** with hand-known values:
  - Clean, all six are scored. R_g5 = R_b = 1.000 and traffic = window /
    400 M, as built. Each block carries its program's P lines.
  - **30 faults, each alone, each named:**
    - QB: not sized.
    - QT:
      - the wrong tracer;
      - thread 0's window never opened;
      - a 170 M trace.
    - QC:
      - loads at 305 (out);
      - loads at 304.4 (in: an edge);
      - RMWs 0.509 (in by the 0.01);
      - RMWs 0.511 (out).
    - The counter runs:
      - a gem5 run exiting 1 (QC and v2);
      - the host run exiting 1 (still scored);
      - another counter (QC, v2);
      - facesim without its base (QC, v2).
    - Q3:
      - another binary (all six);
      - a deadlock;
      - unexplained 1;
      - raw ≠ explained;
      - a CPU on the wrong trace;
      - self-check 1;
      - level 0;
      - the rows disagreeing.
    - QG:
      - Note 3's old stop;
      - a run not ended;
      - randomization on;
      - the dynamic binary;
      - a counter going backwards (QG and 500).
    - QW at 4.1%.
    - v2:
      - loads 6% out (scored, the miss stated);
      - 9% out (fails);
      - RMWs 0.6 against 0.505 (fails).
    - 499 events.
  - In every case only the passing programs' blocks are printed.
  - The target reads MET, NOT MET (Q3 everywhere) and NOT YET DECIDED (one
    passing, two pending) where built.
- `pull_results.sh`'s new section against a fake server tree copies exactly
  the reports, run logs, sizing markers and the chain's log. No trace, no
  input file, no set-1 tree, no config.

**Nothing is read before this note is committed.** The scoring runs on the
owner's word, once the runs have ended. Pulls are read-only copies.

### Note 8 amendment 1, 2026-11-06: `countrows` left facesim's workers without a window; fixed to Note 8's own rule. Written before `score` ran and before any rate was read.

**What happened.** The owner said (2026-11-06) "run sc then score the five".
`sc` started at 05:45:34 server time: streamcluster's lines were written and
the h2 chain restarted (the five done are skipped). Then `pull_results.sh`
(rows v27, b3 v18) and `heldout2_all.sh pullcount` (24 of 24 exited 0) ran.
The first row maker, `countrows`, printed 12 of its 96 window rows as
`UNSUPPORTED start start0:broadcast`: facesim's threads 1, 2 and 3, in all
four of its runs.

Only the flagged lines, the run lines and the window positions were looked
at. No rate, count of a load, store or RMW, or ratio was read.

**Cause.** In `countrows`, a thread got a base only if it was thread 0 of a
`start0:` run, or any thread of a run that starts at 0. facesim's workers
are neither, so they fell to the "unsupported" branch. Note 8 says (The
windows): "base 0 for a worker (from its creation) ... facesim's thread 0 at
its run's own `BASE0`." The code did not do what the note says. This path was
never exercised before:
- the real-file test ran `countrows` on streamcluster's streamfix runs,
  which start at 0;
- the synthetic set wrote its window rows directly, not through `countrows`.

**The fix, one condition.** A worker of a `start0:` run takes the base a worker
takes in any other run: `elif start == '0' or start.startswith('start0:')`.
Thread 0 of a `start0:` run is unchanged (its `BASE0`, or `NOBASE` without
one). Nothing else in the script changes. No criterion, band, width,
threshold or window changes.

**Tested before `score`:**
- **On the pulled counter files:**
  - 112 of the 124 lines are byte for byte as before: every other program,
    every run line, facesim's thread 0.
  - The 12 changed lines are exactly facesim's workers. Each now reads
    `lo 50000000 hi 150000000`, as every other worker does.
  - facesim's thread 0 is at its own `BASE0` + 50 M on the 100,000 grid:
    gem5 runs 8,055,451,159 / 8,055,451,185 x2 -> 8,105,500,000; host
    8,185,319,666 -> 8,235,300,000.
- **On hand-built counter files** (a facesim-like run with thread 0 based at
  8,055,451,159, and a fluidanimate-like run). Thread 0 rises by 10 loads
  per 100,000 records before its base and 30 after; worker t by 30 + t.
  - The fix gives exactly the built counts: thread 0 30,000 (a window at 0
    would read 10,000), the workers 31,000-34,000.
  - The old code gives the same thread 0 row and `UNSUPPORTED` for the
    three workers.

**streamcluster in this scoring.** The pull ran while streamcluster was being
traced (11:15-11:18 laptop time), so its pulled set holds only `LEN` and
`pin.err`. `tracerows` prints a `SET` row for it, without `DONE`. So its
line will read "not scored (QT ...)", not "pending": Note 8 calls a program
pending only when no trace set exists.
- **That line is not a verdict.** It records a trace still being made.
- streamcluster is not counted toward the target, and only passing programs
  print ratios, so nothing else depends on it.
- It is scored, as Note 8 says, by the same command on new row files once
  its trace and its ChampSim run exist.
- The rule is not changed for it.

The order of commands is Note 8's, with `bench/policy_sanity/phasea_rows_v27.txt`
and `b3_rows_v18.txt`.
