# Step 4's same-stream failures: diagnosis and fix. Pre-registered 2026-11-02

Pre-registered before the counter below has run on any program, and before
any ChampSim ratio of fft, streamcluster or volrend has been read (none has:
`newbench_results_2026-11-01.md`).

**Why.** Step 4's check that gem5 and the traces ran the same instruction
stream (`b3_stream_check.py`, "v1") failed on three of five new programs
(fft, streamcluster, volrend). By the step 4 design they are reported, not
scored. The owner (2026-11-01): fix this, if possible, before step 5, so the
tool can run a large set of benchmarks. **A failure is diagnosed, never tuned
away:** nothing below changes the B3 measure, its band, or any ChampSim
setting. It changes how the check counts, and possibly how traces are
recorded, and only by the rules written here.

## What is known (gem5's per-CPU counts and the traces' counts; no ChampSim number)

Per CPU, each gem5 CPU's own window (its counts at the 50 M and 150 M stops)
against the same thread's trace records (`scripts/stream_percpu.py`):

- **lu, raytrace:** agree thread by thread.
- **fft:** gem5 counts about twice the loads and stores per instruction
  (207.8 / 103.8 per 1,000 against the trace's 107.7 / 55.7). gem5's
  floating-point memory micro-ops halved, plus its integer ones, give 103.9
  loads and 51.9 stores. That fits gem5's x86 model splitting each 16-byte
  SSE access into two 8-byte micro-ops, which TimingSimpleCPU sends as two
  requests.
- **fft, thread 0:** gem5's CPU 0 sits 99.2 M instructions further into the
  program than the trace's cut predicts. Defined as
  Δ = (CPU 0's count at the 50 M stop) − (thread 0's last pthread_create in
  the trace) − (the workers' mean count at that stop): fft +99.21 M,
  lu −4.40 M, raytrace −1.20 M, volrend +0.16 M. fft's serial set-up computes
  its roots of unity with `sin`/`cos`, and glibc picks a libm variant by the
  CPU's features. The host's and gem5's differ, so the variants can differ.
- **streamcluster:** loads equal on every thread; threads 2-4 have about 0.5
  more store-only records per 1,000 in the trace, and loads per 1,000 are
  diluted by about 0.05%, as extra store-only records would do. Pin records a
  REP-prefixed string instruction once per iteration. On the host, glibc's
  `memset`/`memcpy` use `rep stosb`/`rep movsb` (one record per byte) where
  the CPU reports ERMS. gem5 does not run AVX, so its glibc picks SSE2
  routines (one 8-byte micro-op per 8 bytes).
- **volrend:** per-thread stores differ widely (a work queue); four-thread
  totals within 4%; read-modify-writes 6.7% more in gem5, most of them on
  thread 0 (3.25 per 1,000 against 0.10-0.26). Its locks' timing varies from
  run to run.

## Hypotheses

- **H1 (units):** gem5 counts memory micro-ops (an access of n bytes is
  ⌈n / 8⌉ of them) per instruction (a REP instruction once); the traces count
  instructions with a load or a store. fft's factor of 2 is this alone.
- **H2 (library variants):** glibc chooses its string and math routines by
  CPUID. On the host it picks AVX2/ERMS/FMA variants that gem5's CPU does not
  report. That moves fft's thread 0 (libm) and adds streamcluster's store
  records (REP strings in libc).
- **H3 (run-to-run variation):** volrend's 6.7% read-modify-write gap is within
  its own variation between native runs.

## The instruments (new)

- **`stream_count`** (a Pin tool, `simulator/tracer/stream_count/`). It counts
  every instruction where the tracer writes a record (IPOINT_BEFORE, every
  iteration of a REP instruction), per thread, in two units:
  - *record units*, as `trace_mix.c` counts a trace: instructions, with a
    load, with a store, read-modify-writes (a memory operand both read and
    written);
  - *gem5 units*: instructions with a REP instruction counted once (its first
    iteration), read micro-ops and write micro-ops (each operand ⌈size / 8⌉).

  It writes running counts every 100,000 instructions (as `trace_mix.c`
  does), each `pthread_create` with its position, and per thread the routines
  executed (whole run; window; for thread 0, before its first
  `pthread_create`), with their image (program, libc, libm, ld.so) and the
  write micro-ops of their REP iterations.
- **`-cpuid FILE`:** every CPUID instruction returns FILE's values for its
  leaf and subleaf instead of the host's. FILE is what gem5 answers:
  **`cpuid_dump.c`**, a static program that prints every leaf and subleaf
  (0-15), run in gem5 with the step 4 runs' settings. A leaf not in FILE
  returns zeros and is counted.
- **The stream check v2** (`scripts/stream_check2.py`). The windows are v1's:
  for every traced thread, the records ChampSim simulates (50-150 M after the
  thread's start, skip and cut; barnes std's three spans as designed),
  located in the counter's run by instruction position. Thread 0's cut is
  the counter run's own last `pthread_create`. The gem5 side is each CPU's own
  window. The unit is gem5's:
  - loads = read micro-ops per 1,000 gem5-unit instructions, against gem5's
    `MemRead + FloatMemRead` per 1,000 `numInsts`;
  - stores = write micro-ops, against `MemWrite + FloatMemWrite`;
  - read-modify-writes, as in v1, against Ruby's `RMW_Read + Locked_RMW_Read`.

  Summed over the traced threads and their CPUs (the gate). It is also
  printed per thread (reported, not gating). The tolerances are v1's: 5%,
  0.05 per 1,000 for RMWs; the held-out rule (loads and stores up to 8%
  scored with the miss stated, RMWs gate) for the held-out and step 4
  programs.

## Tested on the laptop before the server run (no step 4 program)

- **Hand counts, exact:** `bench/stream_micro.c` (a thread runs a known
  kernel K times: a 32-byte load, a 16-byte load and store, a locked RMW, an
  8-byte load, `rep stosb` of 64 bytes). Between K = 1000 and 2000, thread
  1's eight counts differ by exactly 1000 times the hand counts (rec 75, ld 4,
  st 66, rmw 1, ginst 12, gld 8, gst 67, rep 64), with and without the AVX
  instructions.
- **The counter counts what the tracer writes:** the tracer (built fresh
  from the current source) on the same program: `trace_mix` of thread 1's
  trace equals the counter's records, loads, stores and RMWs exactly (75,329;
  4,105; 66,065; 1,005). The tracer writes one record per `rep stosb` byte.
  Thread 0 differs by 24 records of loader start-up between the two runs.
- **The emulation:** `cpuid_dump` under `-cpuid FILE` prints FILE exactly.
  It caught one bug before any program ran: glibc asks leaf 0 with ECX left
  over (0x50), and the first version answered it with zeros. A leaf whose 16
  subleaves read the same now ignores ECX, as the CPU does.
- **The mechanism, on a test program** (`memset`/`memcpy` of 1 MB in a thread,
  `sin`/`cos` in thread 0) with a reduced CPU (leaf 1 ECX = SSSE3 and below,
  leaf 7 zero): glibc moves from `__memcpy_avx_unaligned_erms` and
  `__memset_avx2_unaligned_erms` (`rep movsb`/`rep stosb`, one record per
  byte) to `__memcpy_ssse3` and `__memset_sse2_unaligned_erms` (no REP; 8x
  fewer write micro-ops), and from `__sin_fma`/`__cos_fma` to the `_sse2`
  ones. Thread 0's serial start changes by 8.12 M instructions, all of it in
  libm.
- **Seen on the laptop, stated before the server run:** a local SPLASH-3 FFT
  calls `sincos` (the compiler merges `sin` and `cos`), and it runs the same
  code under both CPUs. The server's glibc and compiler differ, so S2 stands
  as written. It may fail on its libm part.
- **gem5's CPU, from the step 4 runs' `config.ini`:** vendor `HygonGenuine`,
  name "Fake gem5 x86_64 CPU". glibc chooses some routines by vendor and
  family too. The dump, not the configuration, is what the counter uses.
- **The server script rehearsed** end to end (real Pin, a stand-in gem5 that
  runs the dump natively and answers as the reduced CPU, local FFT and LU):
  build, exact, facts, CPUID, QE, and the runs. One bug fixed: the job list
  named programs absent from the table.

## The runs (`scripts/streamfix_server.sh`; writes only under `~/streamfix`)

1. Facts: glibc version, the CPU's flags, gem5's version; `cpuid_dump`
   natively and in gem5.
2. `stream_count` on every program with a gem5 comparison, run as it was
   traced (same binary, arguments, input, working files): ocean, canneal 4 and
   8, barnes-256, barnes std, radix, water-nsquared, fmm, fft, lu, raytrace,
   streamcluster, volrend. Each once with the host's CPUID and once with gem5's.
   volrend twice more with gem5's CPUID and once more with the host's (H3).
3. QE: `cpuid_dump` run under `stream_count -cpuid` prints FILE exactly.

Nothing else on the server is touched. No trace, no ChampSim run, no gem5
run other than `cpuid_dump`.

## Qualifying checks (before any prediction is read)

- **QE (the emulation takes):** as above, and in every run with gem5's CPUID,
  no routine of libc, libm, ld.so or libpthread whose name contains `avx`,
  `evex` or `fma` executes (gem5 runs none of those instructions; the
  program's own code is the binary gem5 ran, so only the libraries choose).
  If QE fails, the gem5-CPUID runs are void. (The library restriction was
  written into `stream_check2.py` and here on 2026-11-02, before any server
  data.)
- **QC (the counter reproduces the trace):** host CPUID. For every trace
  window in `trace_mix_v4.txt`, the counter's record-unit counts over the
  same records are within 1% for loads and stores, and within 1% or 0.01 per
  1,000 for RMWs, summed over the program's threads. The trace's sync records
  are not instructions to the counter; the shift they make is under 0.3%. A
  program that fails QC is reported and its predictions are not scored.
  volrend is the expected candidate (work queue).
- **QA (alignment):** for every program with thread 0 cut, the counter's last
  `pthread_create` is within 0.5% of the trace's cut (host CPUID).

## Predictions

- **S0 (v2 keeps what v1 passed):** v2 holds on every workload that v1 passes
  (ocean, canneal, canneal 8, barnes-256, barnes std force, start and window,
  radix, water-nsquared, lu, raytrace), host CPUID. barnes-256's stores (v1
  1.058, the micro-op effect) read within 3% in v2. fmm still fails (v1:
  stores 1.32, RMWs 1.37; its threads run unevenly under gem5, which units do
  not explain).
- **S1 (fft is units, H1):** host CPUID. On each of fft's workers (threads
  1-3), v2's loads and stores are within 5% of gem5's.
- **S2 (fft's thread 0 is libm, H2):** Δ computed with the counter's last
  `pthread_create` reads +99 ± 2 M with the host's CPUID and within ±5 M with
  gem5's. At least 80% of the difference in thread 0's instructions before
  its first `pthread_create` between the two runs is in libm.
- **S3 (streamcluster is libc's REP strings, H2):** host CPUID: v2's stores on
  threads 2-4 summed are more than 5% above gem5's, and REP iterations in libc
  routines make at least 60% of the excess write micro-ops. gem5's CPUID: v2
  holds on streamcluster, every worker within 5% on loads and stores.
- **S4 (H3):** volrend's four-thread RMW rate in the window (record units, as
  v1) across its three gem5-CPUID runs spans a range that, widened by 5% on
  each side, contains gem5's rate.

## What follows (decided now)

- **F1, v2 replaces v1** for every program from now, if QC holds and S0 and S1
  hold. If S0 fails on a program, v2 is not adopted. The failure is
  diagnosed, and v1 stays.
- **F2, traces recorded with gem5's CPUID,** if QE holds and S2 and S3 hold.
  - The tracer gains `-cpuid FILE` (the same code). Its check: without it,
    every trace byte is as before.
  - fft, streamcluster, lu, raytrace, volrend and LU non-contiguous (rule c)
    are traced with gem5's CPUID, run on the g6 binary, and pass v2 before any
    of their ratios is read. lu's and raytrace's present results become the
    "before".
  - The earlier B3 programs keep their traces if v2 with gem5's CPUID differs
    from v2 with the host's by under 2% on every rate. Otherwise they are
    retraced and rescored, and today's B3 results become the "before".
- **F3, run-to-run variation, if S4 holds:** a program's RMW criterion is met
  if gem5's rate is within 5% of the trace's, or within its native range
  (three runs with the CPUID its traces use) widened by 5% on each side. It
  applies to every program, and it is said so in the paper. **This rule is
  written knowing volrend misses by 6.7%.** It stands only because it is
  fixed before the native range is measured, and because a program whose
  native runs differ that much is not a different stream when gem5 differs
  the same way.
- **If S1 fails:** H1 is wrong. fft stays unscored until a new diagnosis.
- **If S2 or S3 fails:** H2 is wrong for that program. No trace is recorded
  differently. The program stays unscored and is reported with what the
  counter shows.
- **Never:** a tolerance changed after a v2 number is seen; a program's
  B3 ratio read before its v2 check passes.

## Afterwards (not part of this design)

LU non-contiguous (rule c); a discriminating held-out program (lu and
raytrace share too little); then step 5, after `policy_rerun_design` is
amended (binary g6; Q3 = unexplained 0; barnes rows run, not scored until
barnes agrees).

## Amendment 1, 2026-11-02 (afternoon): F2's procedure, before any count from the server is read

Written while the counter runs on the server, before any of its output has
been pulled or seen. It adds procedure only; no prediction, tolerance or
verdict above changes.

**The tracer's `-cpuid` (F2's first bullet) is built and checked**
(`f5a8539`; the counter's emulation copied verbatim).
- **Without the option, every trace byte is as before**, once the tool's
  size is equal. Compared against the committed tracer padded with an unused
  72 KB array, 4 of 4 traces are identical: stream_micro and libtest, with
  sync records and without, with skip and max_instr.
- Unpadded, the only difference is one memory region of thread 0, shifted by
  the 18 pages the tool grew. Every IP, register and branch field is
  identical. The shift is constant over every address in that region.
- **With the option:** cpuid_dump under the tracer prints its file back
  (608 lines). On libtest, under the host's CPUID and a reduced one,
  trace_mix's records, loads, stores and RMWs equal the counter's on both
  threads.
- A missing or empty file exits 1. A plain return leaves Pin's exit
  status 0.

**The F2 traces may be made before the verdict, to save time.** They are
used only if F2 holds as written (QE, S2 and S3, read from
`stream_check2.py check`). Otherwise they are moved aside, and no ratio of
the runs made from them is read. Pipeline: `scripts/syncnc_all.sh`
(sync_server.sh `VARIANT=nc`; traces `traces/sync_nc`, runs
`phaseA_b3_n3_*`, binary g6 as step 4).
- **Tracer and checks.** The tracer is built in its own tree. gem5's CPUID
  is used only if `streamfix` printed "QE holds"; it is frozen in
  `~/sync_nc`. QS runs under it. A new check, **QK**: cpuid_dump under the
  tracer prints the frozen file exactly, and on stream_micro 1000, both under
  gem5's CPUID, thread 1's records, loads, stores and RMWs in the trace equal
  the counter's. Nothing is traced unless QS and QK hold.
- **Lengths.** Each program's first trace has amendment 2's length
  (newbench_design). Under gem5's CPUID thread 0's set-up moves, so
  amendment 2's rule is applied once, automatically, if the first trace
  fails for its length. If the anchor was found but QT fails, the program is
  traced again at the anchor + 215 M, rounded up to 5 M. If no anchor was
  found, it is traced again as the whole run. Any other failure is not
  retried.

**Before any ratio from the nc runs is read (F2's "pass v2"):**
`stream_check2.py ncheck`, per program. It reads nothing unless `check`
prints F2 YES. Two conditions must both hold:
- **QC-nc:** the new traces' window (made as v1's, `b3_stream_check.py
  window`, into a new trace-mix file) against the counter's gem5-CPUID run,
  by QC's rule. That is 1% for loads and stores, and 1% or 0.01 per 1,000
  for RMWs.
- **v2 with gem5's CPUID**, by v2's rule. If F3 holds, a program with three
  gem5-CPUID runs (volrend) meets the RMW criterion inside its widened
  native range, as F3 states.

A program that passes both has its ratios read and scored by the step 4
design (P8-P10, the 500-event rule, R_g5 primary). A program that fails is
reported and not scored.

**LU non-contiguous (rule c)** enters the same way.
- **Counter runs.** It gets the counter runs with both CPUIDs once it is
  sized (`streamfix_server.sh more lunc`). Its gem5 rows come from its own
  two gem5 runs.
- **Where it is counted.** It is in `rows` and `ncheck`, not in `check`. It
  was not in S0-S4. Adding it to `check`'s table would mark QC "not
  checked" (it has no host trace) and change F1's input.
- **If F2 does not hold,** it is traced with the host's CPUID as step 4's
  programs were (`VARIANT=nb`) and checked by whichever check F1 leaves in
  force.

**Tested before commit:**
- **The pipeline**, rehearsed on the laptop with real Pin and ChampSim and
  a stand-in CPUID file. The runs covered QS, QK, the first-length failure
  with the anchor found, the one without, a program that fails otherwise
  (no retry), and partial runs.
- **ncheck**, on synthetic inputs: every verdict path, F3 inside and
  outside, and F2 not holding.

## Amendment 2, 2026-11-04 (before any gem5-CPUID count exists)

**What happened.** Read in the pull of 2026-11-04, 04:56 server time.
- **The first round.** It ran 2026-11-02 08:22-08:26 (server time). Build
  and exact held: 8 of 8 hand counts, and the counter equals the tracer.
- **gem5 aborted in the middle of `cpuid_dump`.** The message was
  `src/arch/x86/cpuid.cc:122 ... Assertion 'capabilities[function].size() >=
  (cap_offset + 4)' failed`, on leaf 0xd, subleaf 2. `gem5.cpuid` therefore
  held 210 lines: leaves 0-0xc, and 0xd subleaves 0-1. It held no extended
  leaf.
- **QE failed.** The dump under the emulation printed those 210 lines
  exactly. It also printed 30 lines that gem5 never printed: 0xd/2-f, and
  0x80000000/0-f (zeros, because the file held no extended leaf).
- **What was not made or read.** No gem5-CPUID run was made. The 14 host
  runs exited 0. Their counts were pulled to the laptop and not opened: no
  `rows` or `check` was run.

**Why, from gem5's source.** Read at tag v25.1.0.0 (the server runs
25.1.0.1): `src/arch/x86/cpuid.cc`, `isa.cc`, `X86ISA.py` and
`isa/decoder/two_byte_opcodes.isa`.
- **Only leaf 0xd takes a subleaf** (`hasSignificantIndex`). `ExtendedState`
  holds two subleaves (8 words), so any subleaf of 2 or more trips the
  assertion.
- **Every other leaf ignores ECX.**
- **A leaf outside gem5's map answers 0 in all four registers.** The
  emulation answers the same for a pair FILE lacks.

The emulation is not at fault: the dump of gem5 was incomplete.

**Does a program ever meet the abort?** Read in glibc 2.39, the server's
glibc (`cpu-features.c`, `dl-cacheinfo.h` at tag glibc-2.39).
- **gem5's CPU, as glibc sees it:** HygonGenuine, which takes the AMD path;
  largest basic leaf 0xd; leaf 1 ECX = 0x209 (no OSXSAVE); family 0x11.
- **What glibc asks:** leaves 0, 1, 7/0, 7/1, 0xd/1, 0x80000000, 0x80000001,
  0x80000007 and 0x80000008. For the caches it asks 0x80000005 and
  0x80000006.
- **What it does not ask:** 0xd/0 and the XSAVE subleaves are behind
  OSXSAVE. 0x8000001D is asked only for family 0x17 and later.

None of these is a pair gem5 aborts on, or a leaf it lacks. This agrees
with every step 4 gem5 run having completed.

**The change.** It is procedure only. No check, prediction or decision
changes.
1. **`cpuid_dump`** gains `LEAF [FIRST]`: one leaf, subleaves FIRST to 15.
   Its output is unbuffered. Without arguments it prints as before (on the
   laptop, pinned to one core, the output is identical).
2. **`streamfix_server.sh cpuid`.**
   - gem5 runs the whole dump once, for its header (the largest leaves).
     Then it runs each leaf alone.
   - A run that stops before subleaf 15 must end in gem5's assertion. That
     pair is written into `gem5.cpuid` as `# gem5 aborts: leaf L subleaf S`,
     and the leaf resumes after it.
   - The whole dump's lines must equal the leaf-by-leaf ones.
   - Anything else stops the gem5 side, as before.
3. **QE's first half, restated for a gem5 that cannot answer every pair**
   (`scripts/cpuid_qe.py`). The dump under the emulation prints gem5's
   header and every line of `gem5.cpuid` exactly. Its other pairs are
   exactly the ones gem5 aborts on.
   - The same comparison is the tracer's QK (`sync_server.sh`).
   - QE's second half is unchanged: no AVX, EVEX or FMA routine of the
     libraries runs in any gem5-CPUID run.
4. **`streamfix_server.sh redo`.**
   - The first round's log, CPUID files, QE and exact test move to
     `~/streamfix/r1`.
   - The counter is rebuilt from the same committed source. If it is the
     same file as the first round's (md5 `cb5902c7...`, recorded in
     `COUNTER_MD5`), the 14 host runs stand. Otherwise they are moved
     aside and every run is made again.
   - Then the round runs as before: exact, facts, cpuid, QE, and the 15
     gem5-CPUID runs. lunc's two runs follow, through `more`.
5. **Reported, not a condition.** For each gem5-CPUID run,
   `stream_check2.py rows` reports `unlisted`: how many CPUID questions it
   asked that are not in `gem5.cpuid`. 0 is expected.
6. **`syncnc_all.sh` may be started while streamfix runs.** The server
   waits for "QE holds" before it builds the tracer. It stops, with
   nothing traced, if streamfix ends without it. Amendment 1 already lets
   F2's traces be made before the verdict.

**A deviation, stated.** The emulation treats a leaf as ignoring ECX when
every subleaf FILE holds for it reads the same (the code). It does not wait
for all 16 to read the same, as this document said above. For gem5's file
the two rules differ only on leaf 0xd, which has two equal lines.
- The emulation answers 0xd/k, for k of 2 or more, with zeros. gem5 aborts
  there instead.
- By the glibc reading above, no program asks those pairs.
- The counter and the tracer are left as they are, so their checks stand.

**Expected from gem5's source** (not a condition; the dump, not the source,
is what the emulation uses). Extended leaves, as eax ebx ecx edx:
- 0x80000000: 80000008 6f677948 656e6975 6e65476e
- 0x80000001: 20f51 405 20001 ebd3fbff
- 0x80000002-4: the name "Fake gem5 x86_64 CPU"
- 0x80000005: ff08ff08 ff20ff20 40020140 40020140
- 0x80000006: 0 42004200 4008140 0
- 0x80000007: 80000018 68747541 444d4163 69746e65
- 0x80000008: 3030 0 0 0

**Tested on the laptop.** The stand-in gem5 answers from gem5's own 210
lines plus the extended leaves from its source, and aborts on 0xd/2 and
above.
- **The committed script reproduces the server's failure exactly:** 210
  lines and 31 diff lines.
- **`redo` then works through the whole round.**
  - It assembles 354 lines and 14 aborts (0xd/2-f). The whole dump's lines
    equal the leaf-by-leaf ones.
  - QE holds, and the host runs stand.
  - The gem5-CPUID runs run, with `unlisted 0` and no AVX routine.
- **`cpuid_qe.py` refuses 6 injected faults:**
  - a value changed;
  - an abort entry dropped;
  - the header changed;
  - a line missing from the dump;
  - an aborted pair never asked;
  - a pair both answered and aborted.
- **The script's guards hold.** A different counter moves the old runs
  aside. A gem5 crash without the assertion stops the gem5 side.
- **QK holds** with the committed tracer (`f5a8539`), and refuses a dropped
  abort.
