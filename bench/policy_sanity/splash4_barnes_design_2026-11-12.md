# Splash-4's barnes against Splash-3's: is barnes's under-count the replay of its mutexes? Pre-registered 2026-11-12

Written before Splash-4 has been downloaded, surveyed, built, sized, traced or
run, and before any number of it exists. PLAN § 10 item 8 lists this as a
diagnosis experiment for before the results freeze, "pre-registered first";
`docs/literature_review_2026-11-11.md` § 7 proposes it.

## Why

barnes is the one SPLASH-3 program in the development set that fails, on the
g6 binary, in both views (`sync_mx_g5_results_2026-10-27.md`,
`disagree_diagnosis_results_2026-11-06.md`):

| span (4 threads) | R_g5 |
|---|---|
| barnes std start | 0.234 |
| barnes std window | 0.249 |
| barnes-256 (its own gem5 reference) | 0.267 |
| barnes std force | 0.634 (agrees) |

Round 1 and round 2 of the diagnosis point at its mutexes:
- **H-C / H-C2:** in the replay a waiter sits silent and runs its lock
  instructions only after the grant; in gem5 it attacks the lock word while
  the holder has it. Contended acquires therefore lose lock-word transfers
  (`lock_wait_design_2026-11-06.md` § 4 fixes the size: 1-2 per contended
  acquire). The waited-acquire counter that tests this is running on the
  server (launched 2026-11-11, not yet pulled or scored).
- **SynchroTrace** (ISPASS 2015) failed on the same class (bodytrack's thread
  pool, raytrace's mutex, ocean).

**Splash-4** (Gómez-Hernández et al., ISPASS 2021, IISWC 2022; checked against
Crossref 2026-11-12) is Splash-3 with its critical sections turned into atomic
operations. Its barnes is the same computation without the cell mutexes. The
level-2 simulator issues an atomic read-modify-write as an ownership request,
as gem5 issues it as a GETX; no mutex order or lock word is involved. So:

**H-M: barnes's under-count comes from how the replay handles its mutexes.**
If H-M holds, Splash-4's barnes agrees where Splash-3's does not, under the
same procedure, input and thread count.

## The two programs, and how they run

- **S3:** Splash-3's barnes, standard (`MAX_BODIES_PER_LEAF 10`), the source
  barnes std was built from (`~/barnes_std_build` on the server).
- **S4:** Splash-4's barnes, from the authors' public repository at the commit
  the survey records, built with **POSIX barriers** (`pthread_barrier_wait`,
  which the tracer records) if the build offers them (E-S2).
- **4 threads**, where the failure is established. Nothing at 8 or 16
  threads is part of this note.
- **The same input rung for both:** the ladder `n16384`, `n32768`, `n65536`
  (barnes std's input, then Part B's sizes); the first rung on which every
  traced thread of **both** programs executes at least 300 M instructions
  (E5, applied to the pair). The input file's other lines are barnes std's.
- **The procedure is B1's** (Part B Notes 1-3, `breadth_bc_design_2026-11-10.md`),
  the same for both programs:
  - traces from h2's tracer under gem5's CPUID, `-sync 1`, thread 0 cut at its
    last `pthread_create` (the anchor), first length anchor + 215 M rounded
    up to 5 M, then the length rule once;
  - ChampSim on `champsim_g6_1e3060c1`, level 2, 2 MB shared LLC, LRU, into
    `phaseA_b3_s4_<s3|s4>4`;
  - gem5: one CPU per thread created, 2 MB, randomisation off, Note 3's
    worker stop on the traced CPUs, stops at 50 M and 150 M of the workers'
    window, a 96 h limit through `timeout`;
  - the counter: three runs under gem5's CPUID and one under the host's.
- **S3 here is new data,** not barnes std's older rows. Those were traced
  under the host's CPUID with spans set in instructions from the anchor; S3
  repeats barnes under the procedure S4 uses, so that the pair differs only
  in how barnes synchronises.

## Eligibility, checked in this order before any B3 number exists

- **E-S1 (survey, read-only).** Splash-4's source is public at a fixed commit,
  its barnes builds on the laptop and on the server, and the input format is
  Splash-3's (or the survey writes down the mapping).
- **E-S2 (survey and source).** S4's barriers are `pthread_barrier_wait` in
  the build used. A barrier the tracer cannot see means the replay never
  waits there, and drift (round 1's T3) would confound the test. If no POSIX
  build exists, S4 is **excluded**, the note's result is "not tested", and
  nothing else runs.
- **E-S3 (survey and source).** Every other wait between threads in S4 is
  listed with its kind: a pthread call, or a spin on memory (an atomic flag).
  Spins are **allowed** and reported: the trace holds the spin's iterations
  as the Pin run made them, and a flag's hand-over moves its line once on
  each side whatever the timing. They are a stated limit of the reading.
- **E-S4 (from the traces, before any ratio).** S4 has shed its mutexes:
  its mutex acquires per KI in the measured window, from the tracer's
  per-call report, are at most **10%** of S3's. Otherwise S4 is not a test of
  H-M and is reported as excluded with both rates.
- **E3, E4 (QB), E5 as set 2's**, for each program: exactly four threads do
  the parallel work (thread starts counted as in Part B's amendment 3);
  dynamic and static binaries from the same objects with fortify off, QB
  equal function by function; the size rule above.

## Qualifying checks (before any ratio is read)

Set 2's, as Part B Note 3 runs them through `heldout2_score.py`'s checker:
QB, QT, Q3 (unexplained view-order violations 0, a run log per thread),
QG (config.ini), QW (untraced CPUs under 1% of the window), QC and v2 with
the native range from the counter's runs, and **500 gem5 events**. A program
failing a check is reported with that check and not scored.

## Predictions (for programs passing every check)

- **P-S1:** S3's R_g5 < 0.5. (The failure reproduces under B1's procedure.)
- **P-S2:** S4's R_g5 is in the band [0.5, 2].
- **P-S3:** R_b ≥ R_g5 for each (as P16).
- **P-S4:** the demand-traffic ratio is in [0.5, 2] for each (as P17).
- Reported, deciding nothing: upgrades (U_g5), each program's drift in the
  replay against gem5's per-CPU spread at its stops (`heartbeat_drift.py`),
  S4's spin loads per KI (E-S3), the waited-acquire counts of both.

## How the outcomes are read

- **P-S1 and P-S2 hold: H-M SUPPORTED.** The paper may say that barnes's
  under-count follows its mutexes, and that the lock-free version of the same
  program agrees. It does not say the lock fix works; that is F-C's own
  note.
- **P-S1 holds, S4's R_g5 < 0.5: H-M REJECTED for barnes.** The under-count
  survives without the mutexes; the cause is in barnes's sharing or its
  replay otherwise (drift, spins). The lock-wait verdict is read beside this,
  and F-C, if it is built, is not expected to fix barnes.
- **P-S1 fails (S3 in the band):** the failure does not reproduce under B1's
  procedure. H-M cannot be read from this pair; both rows are reported, and
  the next note asks what in the older procedure or spans made barnes fail.
- **S4 above 2:** overshoot, reported; no reading of H-M.
- **Anything else** (a check failing on one side, E-S4 failing): reported as
  measured; H-M not read.
- Every outcome is reported in the results note and, if the paper discusses
  barnes, in the paper. Nothing is tuned after a number is seen.

## The order

1. Commit this note.
2. **Survey (read-only, laptop):** download Splash-4 at a fixed commit into a
   new directory; read barnes's synchronisation (E-S1 to E-S3). Note 1 records
   what was found, before anything is built.
3. **Note 2:** the build and sizing recipes (S3 and S4: dynamic and static,
   QB) and the runner (Part B's scripts with their own keys and state
   directory, so the live Part B chain is not touched), rehearsed against a
   stand-in server.
4. **The server, only on the owner's word:** sizing, gem5's two runs each,
   tracing, ChampSim, the counter runs.
5. **Note 3:** the scoring commands, fixed before any number is read; then
   the score and a results note.

Server cost, estimated: 4 gem5 runs of 4-5 CPUs, 2 traces, 2 ChampSim runs,
8 counter runs. Small beside Part B; it runs at nice 19 beside it.

## Note 1, 2026-11-12: the survey (E-S1 to E-S4, from the source). S4 is not a test of H-M; the experiment stops here

Read-only, on the laptop. Nothing was built, sized, traced or run, and no
number of S4 exists.

**Source.** `https://github.com/OdnetninI/Splash-4` (the authors'), tag
`IISWC-2022` = `223ab86` ("Updated citation"); master was `59949ac`. Between
the two, barnes differs only in its region-of-interest markers (empty macros
either way) and the `CLOCK` macro (`time()` → `gettimeofday`, used only for
the printed timings). barnes's whole history in the repository is one commit,
"ISPASS 2021 version" (`995ebe5`). Splash-3 is the laptop's
`repos/splash3`, `codes/apps/barnes` (the source barnes std was built from).

- **E-S1 holds.** Public at a fixed commit; m4 + C11 build, as Splash-3's.
- **E-S2, as written, cannot hold:** no build of Splash-4 uses
  `pthread_barrier_wait`. `pthread.m4`'s `BARRIER` is either the atomic
  sense-reversing barrier (`-D ATOMIC_BARRIERS`, on by default in
  `Makefile.config`: a spin on `__sense__`, which the tracer cannot see) or,
  without it, **Splash-3's own barrier**, a pthread mutex and condition
  variable, which the tracer records. The note's reason for E-S2 (the replay
  must wait at barriers) is met by the second. This would have needed an
  amendment; E-S4 makes it moot.
- **E-S3:** without `ATOMIC_BARRIERS`, barnes has no spin on memory. Its
  waits are pthread mutexes, the `Done_cv` condition waits in `hackcofm`
  (`load.c.in`), the barriers and `pthread_join`.
- **E-S4 cannot hold (decided from the source).** S4's barnes keeps every
  mutex and condition variable of S3's, on the same paths:
  - the cell locks of tree building (`ALOCK` in `loadtree`, `load.c.in`
    217-251) and of `hackcofm` (368-420, with `Done_cv`);
  - the optional locks of the force phase (`code.c.in` 696-700,
    `grav.c.in` 61-66, unless `WITH_NO_OPTIONAL_LOCKS`, in both suites);
  - `CountLock` in `code_io.c.in`, `io_lock` in `load.c.in`.

  The whole difference, ignoring blank lines (`diff -b`): one
  `LOCK(CountLock)` / `UNLOCK` per thread at start-up becomes
  `FETCH_ADD(Global->current_id, 1)` (`code.c.in` 397-402), and two
  `CONDVARINIT(Done_cv(...))` calls are dropped (`load.c.in` 494, 521). So
  S4's mutex acquires per KI in any measured window equal S3's to within one
  acquire per thread, nowhere near the 10% E-S4 requires. Tracing S4 to
  measure that would spend server time on a known answer.

**Result: S4 is excluded by E-S4. H-M is not tested by this pair.** Nothing
is built or run under this note. If the owner wants E-S4 measured formally,
it costs S4's sizing and one trace (no gem5 run).

**Corrections this forces elsewhere (made the same day):** the literature
review (§ 7) and PLAN § 10 item 8 describe Splash-4's barnes as "the same
program with its mutexes replaced by atomic operations". It is not: in barnes
(and, by a count of `LOCK` / `ALOCK` call sites, in fmm, water-nsquared,
radiosity and raytrace) Splash-4 keeps Splash-3's lock calls and turns
counters and reductions into atomics. Any sentence of the paper that cites
Splash-4 must not say its barnes is lock-free.

**What still tests H-M:** the waited-acquire counter (round 2, running on the
server since 2026-11-11) and, only if its prediction holds, F-C
(`lock_wait_design_2026-11-06.md` § 4).
