# fmm under gem5: diagnosis, pre-registered (2026-11-17)

This is the owner's decision of 2026-11-14 ("fmm's gem5 behaviour, own
diagnosis"; `v2_located_results_2026-11-14.md`, "What follows", item 3).

It is written before any of the files named below has been opened for
this question. What is known so far comes from that results note only:

- In gem5's fmm_8 run at the 50 M stop, CPUs 1-6 had committed about
  0.40 M instructions each. CPU 7 had 50 M and CPU 0 56.6 M. fmm_4 and
  fmm_16 look the same.
- So gem5's window holds threads 1-6's first ~86 M instructions, and the
  counter's window holds 50-150 M.
- On gem5's own positions the native rates still differ from gem5's
  (fmm_8: stores 29.74-29.95 against 22.81 per 1,000; RMWs 2.49 against
  0.55).
- fmm fails v2 at every core count and is not scored.

Nothing here changes a check or a score. fmm stays not scored unless a
later note, written before any fmm ratio is read, says otherwise.

## Two questions, three hypotheses

**(a) Timing: why do six workers barely run while one runs 50 M?**

- **H-F1, gem5's SE mode.** The workers wait in futex calls, and gem5's
  syscall emulation wakes them late or not at all, e.g. for an op it does
  not model. So the imbalance is gem5's own.
- **H-F2, the program.** fmm has a phase where one thread works while the
  others wait at a barrier or condition variable. The traced (native)
  run, and so the replay, which keeps the native order of barriers and
  condition waits, shows it too.

**(b) The stream: why do the rates differ even at the same positions?**

- **H-F3, contention.** The extra RMWs and stores in the native windows
  are lock retries and slow paths (glibc's lock and futex routines). They
  depend on timing: under Pin, waits are longer and more contended than
  under gem5.

## Tests (each from files that already exist; nothing is rerun)

- **T1, gem5's own files** (`simulator/results/gem5_b3/partB/fmm_8/...`,
  `heldout/fmm/...`, `fmm_16`): per CPU at each stop, the idle fraction
  (or idle cycles) and committed instructions; the run log's warnings.
  - It reads "suspended" if CPUs 1-6 are idle for more than 90% of the
    cycles to the 50 M stop.
  - Any warning naming futex or an unimplemented syscall is reported
    whole.
- **T2, the replay's positions** (the scored ChampSim runs' heartbeats,
  `scripts/heartbeat_drift.py`): fmm_8's g6 and F-C runs, fmm_4 (set 1)
  and fmm_16.
  - For each, take the first heartbeat at which the core replaying thread 7
    (fmm_4: the thread gem5 ran furthest at its stop) has passed 50 M
    *since its trace's start*. Report the other cores' positions.
  - Also report each core's SYNC CYCLES HELD and mutex waiting.
- **T3, the native routines** (the gem5-CPUID counter runs, `c.t<n>.rtn`,
  window rows `W`): for each fmm key and thread, the share of window
  records in libc routines whose names contain `lll_lock`, `mutex`,
  `futex`, `cond` or `barrier`. Then the same share over gem5's located
  window, as far as the grid allows (the counter's per-routine counts are
  window totals; the located window is reported only if the tool can
  place it, else not).

## Readings (fixed now)

- **H-F2 supported:** in T2, at the moment the leading core passes 50 M,
  the cores of threads 1-6 are below 5 M.
- **H-F2 rejected:** they are above 25 M.
- **Undecided:** between the two. The two thresholds are fixed now.
- **H-F1:** supported if T1 reads "suspended", H-F2 is rejected, and a
  futex or unimplemented-syscall warning is present. Indicated (not
  shown) if only the first two hold.
- **H-F3:** supported if lock/futex/cond/barrier routines hold at least
  10% of the native window records of threads 1-6 (fmm_8) and gem5's RMW
  rate is below the native one. Rejected if they hold under 2%.
- **If H-F2 holds,** the imbalance is the program's. The replay reproduces
  it, the located windows are the right comparison, and (b) is the only
  open question.
- **If H-F1 holds,** a gem5 rerun with syscall debugging is the next step,
  pre-registered then. Nothing is run under this note.

## Output

`fmm_gem5_results_2026-11-17.md` (or the date it is read), with each
test's numbers and the reading. The paper's text on fmm stays "not scored:
fails v2 (located windows W2)" whatever the reading. The reading adds
only why.

## Amendment 1 (2026-11-17, before T2 has read any fmm log)

- **The problem.** The replay's heartbeats come every 10 M instructions a
  core. A core that has not reached its first heartbeat is known only to
  be below about 10 M, so T2 cannot tell "below 5 M". Writing T2's tool
  showed this; no fmm log had been read.
- **The fix:** H-F2 is supported if, at that moment, the cores of threads
  1-6 are below 10 M, either interpolated below 10 M or before their first
  heartbeat.
- Rejected stays "above 25 M"; between the two stays undecided. The
  thresholds were the note's, and this changes only the lower one, to the
  resolution the data has.

## Amendment 2 (2026-11-17): H-F4 and T4, written after T1-T3 ran and before any T4 count was looked at

- **What was seen first (T1-T3, in the results note).** T2 reads
  differently by key. At fmm_8 the replay's workers run together, with
  thread 1 ahead and held for very few cycles. At fmm_16 the replay's
  thread 15 runs to 50 M alone. T1 reads "suspended" at fmm_8 and fmm_16
  but not at fmm_4.
- **The source, read then (not a number):** fmm assigns `my_id` in the
  order threads take `count_lock` after a barrier (`fmm.c.in:170-174`).
  - The thread with `my_id == 0` runs `CreateParticleList` and
    `InitParticleList` over all `Total_Particles` (and larger boxes).
  - The others make their own small lists and wait at the next barrier
    (`:206`).
  - Main also runs `ParallelExecute`: SPLASH-3's `CREATE` makes N-1
    threads and then calls the function.
- **H-F4 (post hoc, from the source).** Which thread gets the serial
  role depends on timing. So gem5's CPU k and the trace's thread k can
  do different work, and a per-thread comparison (v2, the located
  windows) can then pair different roles.
- **T4** (counter runs `simulator/results/partB/stage2/count/runs/fmm_<n>__{gem5,host}__<k>/`,
  A rows of `c.t<t>.rtn`, routine `InitParticleList`, image `FMM*`):
  - A run's **role thread** is the thread whose `InitParticleList` A
    records are at least 10x every other thread's. With no such thread,
    the run has none ("no single role thread").
  - **gem5's role CPU** at a key: the worker CPU (1 to N-1; CPU 0's count
    includes main's set-up) with the most instructions at the 50 M stop,
    if it leads every other worker CPU by at least 10 M. Otherwise it is
    undetermined. From T1's numbers: CPU 3 (fmm_4), 7 (fmm_8), 15
    (fmm_16).
- **Readings, fixed now:**
  - **H-F4 supported at fmm_8** if every counter run has a single role
    thread and at least one of the three gem5-CPUID runs has a role
    thread other than 7.
  - **H-F4 rejected at fmm_8** if all three have role thread 7.
  - **fmm_4 the same, with CPU 3.** fmm_16 is reported, with no
    prediction.
  - The host run is reported, not read.
- **The trace's own role thread (the replayed run)** is reported only as
  indicated, from the replay's SYNC CYCLES HELD (seen already: thread 1
  at fmm_4 and fmm_8, thread 15 at fmm_16). T4 does not test it, and
  nothing is decided on it.
- **The note's opening claim was wrong:** fmm_4 does not look like fmm_8
  at the 50 M stop. T1 shows CPUs 1-2 at 36.4 / 36.0 M with idle 49%,
  against fmm_8's 0.40 M. The claim came from the results note's summary.
- **Whatever T4 reads, fmm stays not scored.** A role-matched comparison
  would need its own note before any fmm ratio is read.
