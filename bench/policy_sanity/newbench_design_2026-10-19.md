# Step 4: six new benchmarks against gem5. Pre-registered 2026-10-19, before any is built, sized or run

Why: the owner asked for **at least 10 benchmarks** (2026-10-18). Six programs
have gem5 runs today: ocean, canneal, barnes (std and 256-body leaf), radix,
water-nsquared and fmm. Six more make twelve. None has played any part in the
tool's development, so they are held out by construction. They are scored
once, on the final tool.

Facts this design rests on: `scripts/newbench_all.sh survey`
(`newbench_survey_2026-10-19.txt`, 2026-10-19), read before this was
written.

## The programs (4 threads each)

| name | source (server) | how it runs | input ladder, smallest first |
|---|---|---|---|
| fft | SPLASH-3 `kernels/fft` (FFT) | `-m<M> -p4` | M = 22, 24, 26 |
| lu | SPLASH-3 `kernels/lu/contiguous_blocks` (LU) | `-n<N> -p4 -b16` | N = 1024, 2048 |
| cholesky | SPLASH-3 `kernels/cholesky` (CHOLESKY) | `-p4 < <file>` | tk25.O, tk29.O |
| waterspatial | SPLASH-3 `apps/water-spatial` (WATER-SPATIAL) | `< <file>` (+ `random.in`, if the program opens it) | `n512-p4` with 32, 64, 128 steps (field 3 of line 1, as water-nsquared's 8 were set) |
| raytrace | SPLASH-3 `apps/raytrace` (RAYTRACE) | `-p4 -m<MB> <file>.env`, run in `inputs/` | car (-m64), balls4 (-m128) |
| streamcluster | PARSEC `parsec-full/pkgs/kernels/streamcluster` | `10 20 128 <n> <n> 1000 none out.txt 4` (one chunk) | n = 16384, 65536, 262144 |

- **Size rule, fixed now:** the input is the first on its ladder for which
  every thread that will be traced executes **at least 300 M instructions**.
  This is measured on the server with Pin's per-thread counter
  (`inscount_tls`). The runs need 172.5 M after thread 0's cut (50 M + 100 M
  and the runners' 15% margin), and gem5 must reach 150 M per thread.
- **A program whose ladder ends below the rule is replaced,** in this order:
  volrend (`head.den`), radiosity (`-p 4 -batch -largeroom`), LU
  non-contiguous (`-n2048 -p4 -b16`). The replacement is said so in the
  scoring.
- **SPLASH-3:** thread 0 creates three workers and works itself, so threads
  0-3 are traced. Thread 0's serial start is cut at its last
  `pthread_create` (`scripts/sync_anchor.py`, below).
- **streamcluster:** the main thread only creates workers, as canneal's does,
  so the first four created threads are traced: the main clustering pass.
  `localSearch` creates threads again for the small final pass over the
  centres, but those later threads are not used. **Built with POSIX
  barriers:** PARSEC's `parsec_barrier.hpp` replaces `pthread_barrier_wait`
  with a spin barrier (an `#define`, unconditional). A spin barrier has no
  pthread call, so the tracer could not see it, and a replay would loop
  through the traced run's spin counts. The build copy disables
  `ENABLE_AUTOMATIC_DROPIN`, and gem5 runs the same objects.
- **Builds:** from a copy of the server's source with the tree's flags,
  fortify off (as for the held-out programs). There is a dynamic binary for
  Pin and the same objects linked `-static` for gem5. **QB:** every function
  in the program's objects has the same instruction count and constants in
  both, as for the held-out programs.

## Alignment (thread 0), checked before this was written

`sync_anchor.py` cuts thread 0 at its last `pthread_create`. The workers'
first records name the creations; the old anchor needed raw, unsynchronised
traces. The tolerance against the old anchors was set before any number:
within 50,000 instructions. **On the m2 traces:**

| program | new cut | old anchor | difference |
|---|---|---|---|
| barnes std | 10,570,202 | 10,570,006 | +196 |
| water-nsquared | 12,952,976 | 12,952,793 | +183 |
| fmm | 12,775,033 | 12,773,531 | +1,502 |

**The method is used for every new SPLASH-3 program.**

## The runs

- **Traces:** Pin with the fixed tracer, `-sync 1` (mutex addresses, the
  ordered flag, condition variables in every version), 215 M records a
  thread, straight into xz, into `traces/sync_nb/`. Thread 0 cut `auto`.
- **ChampSim:** the final tool, `champsim_g5_034cd735` (timing mutex order,
  gem5-rule view). Level 2, shared, LRU, 2 MB, 4 cores, 50 M + 100 M ->
  `phaseA_b3_n2_<program>4`.
  - If step 2's or step 3's scoring changes the tool, these rerun on the
    changed tool from the same traces.
- **gem5:** MESI_Three_Level, TimingSimpleCPU, the same 2 MB shared cache,
  the static binary and the same input.
  - Every program stops when a **worker** reaches 50 M and 150 M:
    CPUs 1-3 for SPLASH-3, as the held-out programs did (thread 0's serial
    start falls before the window), and the workers on 5 CPUs for
    streamcluster, as canneal did.
  - **Corrected 2026-10-19, before anything ran:** this first said that
    SPLASH-3 programs stop "when a thread reaches" them, "as the held-out
    programs did". The held-out launcher in fact stops on a worker
    (`launch_b3_gem5.sh`, WORKER_MAXINSTS), and that is what is meant.

## Qualifying checks

- **QB:** as above, per program.
- **QT:**
  - every traced thread exists and holds at least 172.5 M instructions after
    its cut;
  - every sync call entered returned (no `UNBALANCED`);
  - the tracer's per-call report is kept.
- **Q3:** every run completes; no `SYNC DEADLOCK`; view-order violations 0;
  self-check and stale-holders 0.
- **Same stream:** `scripts/b3_stream_check.py` on the window, trace mix
  against gem5's, before any score. As for the held-out programs, a program
  that fails it is reported and not scored.

## Predictions

R_g5 and R_b as in `b3_g5rule_design_2026-10-19.md`: store misses that find
another core, per KI, divided by gem5's (SS + MT).L1_GETX per KI. The band is
0.5-2.

A program is **discriminating** when gem5 counts at least 500 such events in
the window (as for the held-out programs). For the discriminating programs:
- **P8:** R_g5 is in the band for every one.
- **P9:** R_b ≥ R_g5 for every one (each view only forgets more), and R_b
  is reported.
- **P10:** the shared-cache demand traffic ratio (ChampSim against gem5, per
  KI) is within 0.5-2 for every one.

Non-discriminating programs are reported with their counts. Upgrades
(U against gem5's) are reported, not predicted.

## How the outcomes are read

- **All six programs are reported, whatever their result.** A failure is
  diagnosed, never tuned away.
- **P8 holds:** the agreement found on the development programs carries to
  programs that played no part in the tool's development.
- **P8 fails on a program:** found before the paper states agreement, and
  stated beside it.
- **Which measure the paper calls primary** (R_g5 or R_b) is the owner's
  decision after step 3's scoring. Both are computed here.

Nothing is tuned after a number is seen.

## Amendment, 2026-10-20: two programs replaced, as the design's rule orders, before anything else runs

Sizing on the server (`newbench_server.sh size`, 2026-10-19/20; output in
`simulator/results/newbench/server/`):

| program | result | rung chosen |
|---|---|---|
| fft | sized | `-m22 -p4` |
| lu | sized | `-n1024 -p4 -b16` |
| raytrace | sized; `car` (-m64) exited 1, `balls4` met the rule (workers 1.20-1.23 G) | `-p4 -m128 balls4.env` |
| streamcluster | sized; workers 6.95 G each, main 178 M | `10 20 128 16384 16384 1000 none out.txt 4` |
| **cholesky** | **below the rule on every rung**: tk29.O, workers 225, 227 and 238 M (tk25.O lower) | -- |
| **water-spatial** | **hangs on every rung**: thread 1 stops at 277.59 M instructions while threads 0, 2 and 3 spin past 8 x 10^12 in the 4-hour limit; the same on all three step counts | -- |

So, by the replacement order fixed in the design (volrend, then radiosity,
then LU non-contiguous), **cholesky and water-spatial are replaced by
volrend and radiosity.** Their ladders, fixed now, before either is built or
sized:

| name | source (SPLASH-3) | ladder, smallest first |
|---|---|---|
| volrend | `apps/volrend` (VOLREND), run in its own directory with `head.den` | `4 head 4`, `4 head 16`, `4 head 64` (processes, input prefix, frames) |
| radiosity | `apps/radiosity` (RADIOSITY) | `-p 4 -batch -room`, `-p 4 -batch -largeroom` |

- The size rule is unchanged.
- volrend's arguments are SPLASH-3's usage as remembered, not read from the
  server. The sizing step therefore also records each program's usage text
  (run with no arguments), and a rung with the wrong arguments exits at once.
- If either fails the rule, LU non-contiguous (`-n2048 -p4 -b16`) takes its
  place.
- water-spatial's hang is not diagnosed further: under the rule it is
  replaced either way. It is reported as found.

The six are now **fft, lu, raytrace, streamcluster, volrend, radiosity**
(the last two subject to sizing). The predictions and checks are unchanged.

## Note, 2026-10-21: the first build of volrend and radiosity failed; the build fixed before either ran

- **What failed** (`newbench_server.sh size`, 2026-10-20 15:13): `make
  failed` on both within a second. `make CFLAGS=...` on the command line
  replaces each Makefile's own additions, so volrend lost `-I./libtiff`
  (`tiffio.h` not found) and radiosity `-I./glibdumb -I./glibps` (`glib.h`
  not found). The static link also left out the libraries these two build in
  subdirectories.
- **Fix:** fortify off through `make CC="gcc -U_FORTIFY_SOURCE
  -D_FORTIFY_SOURCE=0"`. That reaches every compile, the bundled libtiff's
  (own CFLAGS) included, and keeps each Makefile's flags. The static link
  adds the program's own archives (volrend `libtiff.a`; radiosity `glib.a`,
  `glibps.a`).
- **Nothing already built changes:** the Makefiles of fft, lu, raytrace and
  of the held-out radix, water-nsquared and fmm add no flags (read from the
  SPLASH-3 source), so their compiles were the tree's flags with fortify off.
- **Rehearsed on the laptop** on the same SPLASH-3 source: both build; QB
  holds (VOLREND 76 functions, RADIOSITY 162); both static binaries run their
  first rung to exit 0.
- **volrend's third argument** is the rotation steps along each of the three
  axes (`4 head 4` renders 12 frames), not the frame count as the amendment
  said. The ladder's values are unchanged.

## Note, 2026-10-27: the binary and Q3, before any of the six is traced or run

- **Binary:** the g6 build (`champsim_g6_1e3060c1`; amendment 2 of
  `b3_g5rule_design_2026-10-19.md`, `7bf54fe` / `1b56891`). It adds records
  only. It passed Q0 (8 of 8) and Q0m (2 of 2) against
  `champsim_g5_034cd735` on the server on 2026-10-27. The nb chain refuses
  to run without both.
- **Q3 as amended there:** `VIEW-ORDER VIOLATIONS UNEXPLAINED` reads 0 in
  every run. The raw `VIEW-ORDER VIOLATIONS` count is reported and must equal
  `VIEW-ORDER LINES BY SILENT RE-LISTING`. It need not be 0: a silent
  re-listing is correct behaviour.
- **The primary measure** (R_g5 or R_b) was to be the owner's decision after
  step 3's scoring. Step 3 was scored on 2026-10-27 and the decision is still
  open. It is to be made before any of the six is scored. P8 is stated on
  R_g5 either way, and both ratios are computed.
- **DECIDED by the owner, 2026-10-27, after step 3's scoring and before any of
  the six was traced to completion or scored: R_g5, the gem5-rule view, is
  the primary B3 measure.** R_b is reported beside it everywhere.

## Amendment 2, 2026-10-28: the trace length, before any of the six is traced again and before any of their runs starts

**What happened** (the nb chain of 2026-10-27, `driver.log`; pull of
2026-10-28 02:58 server time):

| program | thread 0's last `pthread_create` | left of 215 M after the cut | QT |
|---|---|---|---|
| streamcluster | (main thread not traced) | -- | **holds**; traced |
| lu | after 156,621,166 instructions | 58,378,834 | **fails** (172.5 M needed) |
| raytrace | after 184,715,485 | 30,284,515 | **fails** |
| fft | not in the trace: thread 0 wrote 0 sync records | -- | **no anchor** |
| volrend | not in the trace: thread 0 wrote 2 sync records (its base record and one other; no create) | -- | **no anchor** |
| radiosity | still tracing at the pull, 11.5 h after it started (15:31:41) | -- | -- |

- The chain runs no job until every program is traced, so **no ChampSim run
  of the six has started.**
- The gem5 runs start at the program's beginning and stop on a worker, so
  this does not touch them. They continue. lu's, raytrace's and
  streamcluster's 50 M stops have ended; their statistics were pulled to the
  laptop and **have not been read. No ratio of the six has been computed.**

**Cause: the design fixed 215 M records a thread** (§ The runs). That was
right for the earlier programs, whose thread 0 is cut after 10.6-13.0 M. In
these four, thread 0 runs a long serial set-up before it starts the workers:
- lu: 157 M; raytrace: 185 M;
- fft and volrend: more than 215 M. From sizing (`count.txt`): fft's thread 0
  executes 1.77 G instructions against 0.53 G a worker; volrend's 2.63 G
  against 0.54-0.66 G. So their set-ups are about 1.2 G and 2.0 G.

The size rule counts each thread's whole run, so it could not see this.
QT, which counts what is left after the cut, caught it as designed.
radiosity's sizing counted 308.8 G instructions for thread 0 and 173.0-178.6 G
a worker. The tracer runs a program to its end after every thread's budget
is spent, so tracing radiosity runs those 840 G instructions under Pin. The
sizing pass (Pin's per-thread counter, not the tracer) took 20 minutes.

**The fix: the trace length is set per program.** The window the design
defines does not change: 50 M + 100 M after the cut, 172.5 M with the
runners' margin. Everything else is unchanged: the binary (g6), the runs,
QT, Q3, the same-stream check, P8-P10 and the primary measure (R_g5).

- **Where the first trace found the anchor:** max_instr = the anchor + 215 M
  (the design's 215 M, now counted from the anchor), rounded up to 5 M.
  - **lu: 375 M** (156.6 + 215 = 371.6);
  - **raytrace: 400 M** (184.7 + 215 = 399.7).
- **Where it did not (fft, volrend): the whole run** (max_instr 0, which
  the tracer reads as unlimited). Thread 0's whole run (1.77 G, 2.63 G)
  holds the anchor wherever it is. QT then confirms at least 172.5 M after
  the cut.
- **The workers are traced to the same length.** The tracer's length is per
  thread, and the runs read only the first 172.5 M of each trace, so the
  extra length changes nothing that is measured.
- **streamcluster stands** as traced.

**radiosity, decided now, before its first trace has ended:**
- **(a)** it passes QT: it stands.
- **(b)** it fails QT with its anchor found: it is traced again at the anchor
  + 215 M, as above.
- **(c)** no anchor is found (its set-up exceeds 215 M): it cannot be traced
  whole (thread 0 runs 308.8 G instructions), so it is **replaced by LU
  non-contiguous** (`-n2048 -p4 -b16`), the next in the design's order. LU
  non-contiguous is sized by the size rule and traced by this amendment's
  length rule.
- **(d)** its trace has not ended **48 h** after it starts: it is stopped and
  replaced as in (c).

**How it runs (pipeline only):**
- radiosity is traced in a chain of its own (`~/sync_nb_r`), so its long
  trace no longer holds back the other five. Both chains use the same trace
  directory, one program each, and write disjoint runs.
- The first attempt at radiosity is stopped and started again in its own
  chain. Rule (d)'s 48 h count from that restart.
- **In VARIANT=nb, a run starts only from a program whose traces passed QT**
  (its `DONE` marker). The runs of the programs that passed go ahead when
  another program fails: before, one failure held back every run, and a run
  would have used any trace file present, `DONE` or not.
- One command: `scripts/newbench_all.sh retrace`.

## Amendment 3, 2026-11-05: streamcluster scored by held-out set 2's procedure, before any ChampSim ratio of it is read

**Decided by the owner, 2026-11-05**, together with the rule that agreement
is sought first on the programs in hand before more are added.

**Why streamcluster.**
- It failed v1 on 2026-11-01, on stores: gem5 / trace 0.878.
  `stream_fix_results_2026-11-04.md` found why. **S3 held:**
  - under the host's CPUID, glibc runs `REP` string routines, and gem5
    counts their iterations as separate requests (120% of the excess);
  - under gem5's CPUID, v2 holds, with every worker within 5%.
- gem5 counts **2,245 events** in its window: (186 + 4,149) − (68 + 2,022),
  `SS.L1_GETX + MT.L1_GETX` at the two stops (`gem5_b3_rows_v4.txt`). That
  is enough to discriminate.
- F2 was not adopted for step 4's programs as a group, because S2 failed on
  fft's thread 0 (its serial start).
  - streamcluster's traced threads are workers, traced from their creation,
    so thread 0's serial start does not enter.
  - This is held-out set 2's argument for its PARSEC programs
    (`heldout2_design_2026-11-04.md`, "Why v2 and gem5's CPUID").

**What is known and what is not.**
- **No ChampSim ratio of streamcluster has been read, from any trace.**
  - Step 4's run on the host-CPUID traces (`phaseA_b3_n2_streamcluster4`)
    was never read.
  - The nc traces were voided unread, before any run.
  - A scratch file of the 2026-11-05 scoring that held its n2 block was
    deleted unread.
- Known:
  - gem5's counts (the 2,245 events and its stream rates);
  - the streamfix counter rows, which are stream checks, not agreement.

**Procedure: held-out set 2's, unchanged** (`heldout2_design_2026-11-04.md`:
The runs, Qualifying checks, Notes 6 and 7).
- **Program:** step 4's streamcluster as it stands. Its PROGS and JOBS lines
  are copied unchanged:
  - the same dynamic binary;
  - arguments `10 20 128 16384 16384 1000 none out.txt 4`;
  - threads 1-4 traced from their creation, no skip, no cut.
- **Trace:**
  - nc's tracer (md5 `f39707f3`; QS and QK held), with `-cpuid` the frozen
    `gem5.cpuid` (md5 `74d72229`), `-sync 1`, 215 M records a thread;
  - into `traces/sync_h2/streamcluster`;
  - QT as step 4; amendment 2's length rule, applied once if needed.
- **ChampSim:** `champsim_g6_1e3060c1`. Level 2, shared, LRU, 2 MB, 4 cores,
  50 M + 100 M, into `phaseA_b3_h2_streamcluster4`.
  - The h2 chain runs it as a sixth program, after its five runs now in
    flight. A relaunch skips what is done.
- **gem5:** step 4's two runs stand: the static binary from the same objects
  (QB held), 5 CPUs, stops when a worker reaches 50 M and 150 M. QG checks
  their configuration.
- **Counter:** three runs under gem5's CPUID and one under the host's, in
  held-out set 2's counter command (Note 7), by the same counter.

**Checks, all held-out set 2's text, unchanged:**
- QT, Q3 and QG;
- QW: untraced CPUs under 1% of the window;
- QC and v2, both with the native range;
- at least 500 events.

They are computed by the code that held-out set 2's scoring note fixes,
before any number of either is read.

**Predictions: P8, P9 and P10 as step 4** (the same content as P15-P17):
- R_g5 in the band 0.5-2;
- R_b ≥ R_g5;
- traffic within 0.5-2.

Upgrades are reported, not predicted.

**How it is read:**
- Reported whatever happens. A program that fails a check is reported with
  that check and not scored. It gets no further attempt without a new
  pre-registration.
- It counts as a step 4 program, not toward held-out set 2's target of two.
- The paper reports both streamcluster results: the v1 failure on the host
  traces, and this one.
- **Not changed:** fft and volrend stay unscored. The run on the host traces
  is never read or scored.
