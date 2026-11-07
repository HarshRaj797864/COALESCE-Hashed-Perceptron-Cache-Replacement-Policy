# Synchronised replay: threads wait where the program makes them wait. Pre-registered

**2026-10-18.** Written and committed before any code below is run on a real
program. Step 2 of PLAN § 10; the cause it addresses is measured in
`drift_finding_2026-10-18.md` (the replay's threads drift 8-19 M instructions
apart; gem5's stay within a phase).

## What changes

### The trace (a superset of ChampSim's format; old traces read as before)

A **sync record** is an ordinary 64-byte record whose `destination_memory[1]`
holds `0x53594E4353594E43` ("SYNCSYNC") -- a non-canonical x86-64 address, so
no real memory operand can ever carry it. Its other fields:

| field | meaning |
|---|---|
| `ip` | the program counter of the synchronisation call (real code) |
| `destination_memory[0]` | a release this record announces (`seq << 8 | tid`), or 0 |
| `source_memory[0]` | a release this record waits for, or 0 |
| `source_memory[1]` | kind: 1 release, 2 acquire, 3 base |

`seq` is one counter over the whole native run, so every release has a
unique place in the real order; `tid` is the releasing thread. A thread's
releases are numbered in its program order.

The **base record**, first in every trace that has sync records, says from
which `seq` this thread's releases appear in the trace; any release by that
thread numbered earlier (skipped, or cut by alignment) counts as already
released, and so does any release by a thread that is not simulated.

### The tracer (`champsim_tracer.cpp`, `-sync 1`)

It intercepts, by routine, in every image: `pthread_mutex_lock`,
`pthread_mutex_trylock` (on success), `pthread_mutex_unlock`,
`pthread_cond_wait`, `pthread_cond_timedwait`, `pthread_cond_signal`,
`pthread_cond_broadcast`, `pthread_barrier_wait`, and `pthread_create`.
- Releases (written on entry): unlock (the mutex); signal and broadcast (the
  condition); a barrier arrival; create (for the child's first record).
- Acquires (written on return): lock -- waits for the mutex's last release;
  condition wait -- waits for the condition's last signal **and** the
  mutex's last release (two records); barrier -- waits for the last arrival
  of its generation; a new thread's first record -- waits for its create.
- ~~Instructions inside these calls are not written.~~ **Amended
  2026-10-18, before any code ran:** they are written as before. They hold
  the accesses to the lock words themselves -- the hand-overs gem5 counts
  (barnes: 5 lock/unlock pairs per 1,000 instructions) -- and dropping them
  would remove real sharing and change the instruction counts the same-stream
  check compares. glibc's mutexes and condition variables wait in the kernel,
  not in user spin loops, so few native-timing instructions remain.
- Where the record goes, so the lock word's own accesses replay in the
  native order: an **acquire** record is placed *before* the call's
  instructions (the tracer holds them until the call returns, when the
  release it waited for is known); a **release** is numbered on entry (so a
  thread that acquires next sees it) but its record is placed *after* the
  call's instructions (so the unlocking store replays first). A barrier
  arrival is a release placed at entry.
- Nested calls (a condition wait re-locking its mutex) produce nothing extra.

SPLASH-3 builds its barriers from a mutex and a condition variable
(`pthread.m4.stougie`), so they are captured through those calls.
**Not captured:** synchronisation by plain atomics and spin loops in user
code (canneal's lock-free swaps) -- those replay as ordinary accesses, as now.

### ChampSim

- The trace reader turns a sync record into an instruction with no memory
  operands carrying `sync_release` / `sync_wait`; a base record sets the
  thread's base and is not fed to the core.
- **A core does not dispatch an instruction whose `sync_wait` has not been
  released**, so nothing after an acquire executes early; a release is
  announced when its instruction retires.
- A core held at an acquire counts sync-stall cycles; the livelock detector
  skips a core held there most of its period.
- With no sync records in the traces nothing changes, and the log prints
  exactly what it printed before (the new lines are printed only when sync
  records were seen).

### Corrections found by Q2 (the micro test with real barriers), before any program was traced

1. **A release is a fence.** ChampSim retires a store before writing it to
   the L1D. A release that retired right after a store let the next core go
   while the store was in flight: pp_store at level 2 read 4 hand-overs for
   12. On x86 an unlock or a barrier is a full fence, so a release now
   retires only when no older store is in the store queue and its L1D holds
   no pending write. Exact case `sync_storepp` added; it needs the fence.
2. **A barrier departure waits for every arrival, not the last.** In the
   native run the last arrival implies the others; in a replay it does not.
   (SPLASH-3's mutex-and-condition barriers chain through the mutex and were
   never affected; `pthread_barrier_wait` -- canneal's -- was.)
3. **Caution:** a binary without synchronised replay reads sync records as
   stores to odd addresses and prints plausible nonsense. The server runner
   refuses that pairing (it checks the binary for `SYNC REPLAY`).

## Qualifying checks

- **Q0:** on traces without sync records (canneal, barnes, both regimes,
  levels 0 and 2), every log line equals the current binary's.
- **Q1, exact:** `check_coherence_exact.sh` passes; new synthetic cases with
  sync records hit hand counts: a lock ping-pong whose turns are ordered only
  by the records (no spacing), at levels 0 and 2 (1 and 3 events a round),
  and a barrier case whose cores do unequal work between barriers.
- **Q2, the micro test with real barriers:** `coherence_micro.c` with a
  barrier between steps instead of timed waits, traced with `-sync 1`: every
  ChampSim count equals its hand count, including the cases with unequal
  work.
- **Q3, no deadlock:** every re-traced program runs to completion.

## Predictions, for the re-traced programs at level 2 (scored when they exist)

- **P1, the threads stay together:** the median heartbeat spread between
  cores falls from 8-12 M instructions to **under 2 M** in ocean, canneal and
  barnes std.
- **P2, ocean's lines are held at hand-over:** ocean's presence ratio R_a and
  bounded ratio rise from 0.08 / 0.09 to **at least 0.5** at 2 MB, while R_b
  stays in the band.
- **P3, the agreeing programs keep agreeing:** canneal (4c, 8c) and barnes
  std (force, start) R_b in the band.
- **P4, radix is not fixed by this:** its R_b stays above 2. Its over-count
  is lines that left the chip, which synchronisation does not bring back;
  that is step 3 (gem5's forgetting rule, `micro_results_2026-10-18.md`).
- Reported: barnes std's window span (it crosses a barrier: expected to rise
  toward the force span), fmm's uneven threads, every R_bounded.

## How the outcomes are read

- **P1 and P2 hold:** the drift explained ocean, the replay is now faithful
  in the way gem5 is, and step 3's rule can be built on it.
- **P1 holds, P2 fails:** synchronisation was needed but ocean's lines are
  lost for another reason as well (the private caches' behaviour); examined
  before step 3.
- **P1 fails:** the records do not hold the threads together (a missed
  synchronisation path); found and fixed before anything is scored.

Nothing is tuned after a number is seen.
