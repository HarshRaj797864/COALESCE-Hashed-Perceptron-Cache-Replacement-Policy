# Mutex order by simulated timing. Pre-registered 2026-10-19, before any code

Why: `sync_results_p1_2026-10-19.md`. Synchronised replay
(`sync_replay_design_2026-10-18.md`) enforces every recorded order, the
order in which each mutex was taken included. That order is the traced (Pin)
run's, and so is its timing. The replay reproduces that run's thread spread
bin by bin (barnes std 7.0 M against 7.0 M; barnes-256 30.1 M against 30.1 M),
where gem5's threads stay within 1.6 M and 13 M. The barrier-driven programs
already agree with gem5. **Owner, 2026-10-19: fix it before anything from
the synchronised runs is scored.**

The change: **a mutex stays exclusive, and the simulated timing decides who
takes it next**, as gem5's timing does. Every other recorded dependency stays:
barrier departures, thread creation, condition-variable signals, and one
class of mutex acquires (below).

## The trace (tracer `-sync 1`; record kinds unchanged)

- A mutex record carries the mutex's address in `source_memory[2]`; every
  other record carries 0. Mutex records are: `pthread_mutex_lock`, a
  `pthread_mutex_trylock` that succeeded, an unlock, and the mutex half of a
  condition wait (its release of the mutex, and its re-acquire).
- **Every mutex acquire is written**, including one that natively waited for
  nothing (the first lock of a mutex; a condition wait's re-acquire of a mutex
  nobody touched meanwhile). Until now those were left out, since in recorded
  order they waited for nothing. Their recorded wait is then 0.
- **The ordered flag**, `source_memory[3]` = 1, on a mutex acquire whose
  recorded predecessor (the mutex's last release in the native run) was a
  condition wait's release of that mutex. Why: a condition variable's
  protocol carries dependencies through the mutex order. In a barrier built
  from a mutex and a condition variable, the last arriver's lock natively
  follows every other arriver's wait. Under pure timing it could take the
  mutex first, broadcast to nobody, and pass the barrier alone. An ordered
  acquire keeps its recorded wait, so arrivals keep their native order, and
  only plain handovers become timing-decided.

## ChampSim (setting `sync_mutex_order`: `timing`, the default, or `recorded`)

- In `timing` mode a mutex acquire (a record with a mutex address) dispatches
  only when:
  1. its recorded wait is released, if it is flagged ordered; then
  2. the mutex is free, and this core is first in the mutex's queue (or the
     queue is empty).
  A core joins the queue only after step 1 holds, so it never blocks a mutex
  while waiting for something else. Dispatching the acquire takes the mutex.
  An unflagged acquire's recorded wait is ignored.
- A mutex release frees the mutex when it retires. It is still a fence, as
  before: it retires only once its core's older stores are performed. A
  release of a mutex this core does not hold changes nothing and is counted.
  That happens only where a trace was cut or skipped while the mutex was held.
- **A core's own unretired release does not make the mutex free for it.**
  Dispatch runs ahead of retire: a core's next lock can reach dispatch while
  its previous unlock is still in its ROB. That core waits and queues like any
  other, behind the cores already waiting. Without this, a core could re-take
  a mutex for ever.
- The queue is first-come, first-served. Ties within one cycle go to the core
  that operates first.
- `recorded` mode, and any trace without mutex addresses (every trace made
  before this change), behave exactly as before.
- Printed when mutex records are seen: `SYNC MUTEX ORDER: timing|recorded`,
  the number of mutexes, acquires (ordered ones separately), and releases of a
  mutex not held. Per core: mutex acquires and the cycles spent waiting for a
  mutex.
- **Deadlock guard.** A core held at one sync record for 30 consecutive
  livelock periods (300 M cycles) ends the run with `SYNC DEADLOCK`, and
  prints each held core's wait and each mutex's holder and queue. A full
  deadlock was already caught by ChampSim's own check (no progress at all).
  This guard catches a partial one, where other cores keep running.

## Qualifying checks (before any server run)

- **Q0:** traces without sync records: every log line equals
  `champsim_b3v4_69ebdcce`'s, as for the first synchronised build.
- **Q0b:** traces with sync records but no mutex addresses (the s2 traces):
  every log line equals `champsim_sync_06f98fcb`'s. Locally on the existing
  exact-test cases; on the server on one s2 trace set, 1 M + 2 M.
- **Q1, exact:** `check_coherence_exact.sh` passes every existing case (36),
  plus three new ones. Columns are v1e v1s pre prc pte ptc rmw fwd upe upc
  inv; R = 50; levels 0, 1, 2.
  - **`mx_handover`** (the two modes differ): cores A and B take turns on
    mutex M, A, B, A, B, each turn an RMW of X_j, recorded as alternating. B
    first runs 1,000,000 instructions alone.
    - Timing: A takes all its turns first, then B: one handover a round. L0
      `50 50 50 50 50 50 200 0 0 0 0`; L1/2 `50 50 50 50 50 50 200 0 0 0 100`.
    - Recorded: the alternation, as `sync_pingpong`. L0 as above; L1/2
      `150 150 150 150 150 150 200 0 0 0 300`.
  - **`mx_excl`** (exclusion, timing): four cores, 50 critical sections each
    on M. Each section: RMW Y, 3,000 instructions, RMW Y; 10 instructions
    between sections. Every section after the first finds Y at the previous
    holder, a different core (the queue rotates).
    - L1/2: `199 594 199 199 199 199 400 0 0 0 398`. The LLC's own
      sharer mask keeps every core that touched Y (invalidations do not clear
      it, as in `order`): 1 + 2 + 3 + 196 x 3 = 594.
    - L0, where nothing is invalidated, so after each core's first section its
      RMWs hit its own copy: `3 6 3 6 3 3 400 0 0 0 0`.
    - Without exclusion, sections overlap and the counts differ.
  - **`mx_cond`** (the ordered flag): a barrier built from a mutex and a
    condition variable. Per round, three cores work 30,000 instructions, LOAD
    Z_j, and wait at the barrier in a recorded order. The fourth, natively
    last, arrives after 10 instructions, then broadcasts, unlocks and RMWs
    Z_j.
    - If it waits for the others: its RMW finds three readers. L0
      `50 150 50 150 50 150 50 0 0 0 0`; L1/2
      `50 150 50 150 50 150 50 0 0 0 300`.
    - If it passed early: 0 events. The same counts in both modes.
- **Amendments to Q1, 2026-10-19, after the first local run (before
  anything ran on the server); no expectation of the tested properties
  changed:**
  - `mx_handover` in recorded order wrapped a trace. A waits through B's 1 M,
    then needs about 1 M more after B is done, and B keeps running. Its tail is
    now 2 M (the harness's prescribed fix for a wrap).
  - `mx_cond`'s v1 column read 101 of 150 in both modes, and 100 with the
    readers staggered by 5,000 instructions. The event log shows why: one
    reader's LOAD reached the LLC 130 cycles after another's and merged into
    that miss. The LLC's own mask records only the miss's owner, v1's known
    flaw (as in `wb_control`, where v1 is not asserted either). Presence, the
    protocol view and the invalidations listed all three readers, exactly as
    counted by hand. **v1 is not asserted for `mx_cond`**; the stagger was
    reverted.
- **Q2, the micro test with real barriers,** re-traced with the new tracer
  (`-sync 1`, `-DBARRIER_STEPS`): every case's X-line counts as before.
  **Corrected 2026-10-19, before it ran:** this is not "real glibc mutexes".
  `coherence_micro.c`'s ping-pong uses a locked x86 add, not a pthread mutex,
  so Q2 covers only barrier records under the new tracer and binary.
- **Q2b, real mutexes and condition variables, added 2026-10-19 before it
  ran:** `bench/mutex_micro.c` (same markers; `MICRO_SRC=` in
  `micro_champsim.sh`), ROUNDS 8, traced with real Pin and `-sync 1`, timing
  mode, X-line counts (P = ownership events finding another core in the
  protocol view, A = the same in presence, U = upgrades):
  - `mx_lock`: four threads each take a real mutex 8 times. Inside: a
    locked add on X[0], ~3,000 instructions, a locked add on X[0]. Every
    section after the first finds X[0] at the previous holder: L2
    `P 31 A 31 U 0`; L0 (nothing invalidated) `P 3 A 3 U 0`.
  - `mx_condbar`: 8 barriers of a real mutex and condition variable. Each
    round's thread j%4 sleeps 20 ms, so it is last in the traced run and first
    in the replay. Its lock is an ordered acquire. After the barrier it does a
    locked add on X[j], which the three others loaded before arriving. Held:
    `P 8 A 8 U 0` at L0 and L2. Passed early: 0.
- **Q3, no deadlock:** every re-traced program runs to completion; the guard
  never fires.

## Local results (2026-10-19)

- **Q1: 51 of 51 exact** (the 36 earlier cases and 15 new), levels 0, 1, 2.
  - `mx_excl` reads 199 / 594 / 398 at L1-2 and `3 6 3 6 3 3` at L0:
    exclusion and the first-come queue hold.
  - `mx_handover`: timing 50 / 100, recorded 150 / 300. The setting changes
    the order, as it should.
  - `mx_cond` with its ordered flags stripped (an injected fault) reads 0
    protocol events, against 50. The flag is what holds the barrier.
- **Q0b, locally:** the binary built from the last commit before this change
  (`607b114`, simulator unchanged since `95f9969`, which built
  `champsim_sync_06f98fcb`) and the new binary print identical logs in 20 of
  20 cases. The cases are the old sync cases and two without sync records,
  levels 0 and 2, both settings. The server step `sync_server.sh q0b`
  was rehearsed: it passes on old-format traces and refuses traces with
  mutex records.
- **Q2b found a defect in the tracer of 2026-10-18, and it is fixed:
  condition variables were never recorded.** glibc keeps two versions of each
  `pthread_cond_*` at different addresses: `GLIBC_2.3.2`, which programs call,
  and an old `GLIBC_2.2.5`. Pin names both plainly, and the lookup by name
  found the old one. `mx_condbar` read `P 6` of 8, with 8 mutex acquires a
  thread and no ordered ones. The tracer now instruments every routine of each
  name, and reports each thread's calls by kind. With it: 6 condition waits
  and 2 broadcasts a thread, exactly the program's. The mutex, barrier and
  create functions were unaffected, since both of their versions share one
  address. **The s2 traces carry no condition-variable records,** so any of the
  8 programs that waits on a condition variable was replayed without that
  dependency. The re-trace prints the call counts, which shows which programs
  do.
- **Q2b: both cases exact.** `mx_lock`: L0 `P 3 A 3 U 0`, L2
  `P 31 A 31 U 0`. `mx_condbar`: L0 and L2 `P 8 A 8 U 0`, with 24 ordered
  acquires (the 2nd, 3rd and last arrival of each of 8 rounds). Real Pin, real
  glibc, timing mode.
- **Q2: every X-line count identical to the previous Q2** (11 cases at L0 and
  L2; `simulator/results/micro_champsim_syncmx/summary.txt` against
  `micro_champsim_sync/`). Re-traced with the fixed tracer, on the new binary,
  no trace wrapped, and no mutex line, as this program has barriers only.
- **The server path, rehearsed end to end on a fake tree:**
  - `VARIANT=mx sync_server.sh build`: the three guards pass, the binary is
    frozen, the tracer builds, Q0 holds 8 of 8, Q0b 4 of 4.
  - `chain`, detached, with `mutex_micro` standing in for the programs: real
    Pin through FIFOs into xz, a thread-0 cut, both runs complete (24 ordered
    acquires, 0 releases of a mutex not held).
  - `status` reads it; without `VARIANT` the s2 status is untouched.

## Predictions (re-traced programs, level 2, timing mode; trees `phaseA_b3_m2_*`)

- **P1 (the reason for this change):**
  - barnes std's force-span median spread falls **under 4 M** (s2 6.08 M;
    gem5 1.6 M);
  - barnes-256's spread in the 140-150 M bin falls **under 20 M** (s2 30.1 M;
    gem5 13.2 M);
  - ocean, canneal 4c / 8c and radix stay **within 1 M** of their s2
    medians (their order is barrier-driven).
- **P2-P4 as pre-registered** in `sync_replay_design_2026-10-18.md`, scored
  on these runs: ocean's R_a and R_bounded at least 0.5 at 2 MB, with R_b in
  the band; canneal 4c / 8c and barnes std (force, start) R_b in the band;
  radix R_b above 2.
- Reported: releases of a mutex not held (expected 0, or a handful where a
  trace was cut); cycles held against s2; barnes's R_b against the s2 runs
  (recorded order), the one ablation of this change.

## How the outcomes are read

- **Q fails:** fixed before anything goes to the server.
- **P1 holds:** the lock order explained barnes's drift; score P2-P4.
- **P1 fails on barnes while the barrier programs hold:** lock order is not
  the whole cause. Examine the per-core rates (IPC) before scoring barnes.
  ocean, canneal and radix are scored.
- **A barrier program moves by more than 1 M:** the ordered flag or the queue
  is wrong. Found and fixed first.

Nothing is tuned after a number is seen.

## On the server (2026-10-20): Q3 FAILED -- a tracer defect, found and fixed

The m2 chain ended with **3 of 12 runs complete**. Every SPLASH-3 run
(ocean, radix, water-nsquared, fmm, barnes std in three spans, barnes-256)
stopped in warm-up with `SYNC DEADLOCK`. In each, one core held a mutex
while waiting on a recorded signal, and the cores that signal depended on
were queued for that mutex. canneal, with barriers only, completed (4c, 4c
scaled, 8c). step 3's Q0m failed for the same reason: both binaries
deadlocked identically, and Q0m counts a reference that does not complete as
a failure.

**Cause: the tracer of 2026-10-19 recorded no `pthread_mutex_lock` or
`unlock` on the server.**
- Every thread's report read `lock 0 unlock 0`, beside hundreds of condition
  waits and broadcasts.
- The fix for the two condition-variable versions matched routines by their
  own names. On the server's older glibc the lock and unlock routines carry
  another primary name, which only the earlier lookup by name (aliases
  included) found. The laptop's glibc names them plainly, so Q1, Q2, Q2b and
  the rehearsals all passed there.
- With no lock or unlock recorded, a SPLASH-3 barrier (a mutex and a
  condition variable) became a condition wait whose re-acquire took the mutex
  and whose unlock was never recorded: the mutex was held for ever.
- **The replay's rules were not at fault.** A reproduction with SPLASH-3's
  barrier code (`bench/splash_barrier_micro.c`), traced locally with every
  call recorded, ran 20 barriers through without a deadlock.

**Fixed:**
- **The tracer** instruments each routine found either way: by name, which
  finds aliases, and by every routine's own name, which finds every version.
  Duplicates are removed by address. Locally: `mutex_micro` reads lock 8,
  unlock 8 and condition calls 8 on every thread.
- **QS, a new check in every server build:** the freshly built tracer runs
  `mutex_micro` on that machine's glibc. Every thread must record at least 8
  locks, 8 unlocks and 8 condition calls, or nothing is traced. It rejects
  the 2026-10-19 server report (lock 0 / unlock 0) and passes the fixed
  tracer.
- **`sync_server.sh refresh`** (VARIANT=mx, run by the launcher) moves a
  trace set made by another tracer aside (`traces/sync_mx.void_<stamp>`),
  with its runs (`results/void_<stamp>/`). Nothing is deleted. Each trace
  set's DONE now records the md5 of the tracer that made it.

**What reruns:** the 8 programs are re-traced and the 12 m2 runs rerun, then
step 3 (g2). The binaries are unchanged (`champsim_syncmx_cc45d6f5`,
`champsim_g5_034cd735`): the defect was in the traces. canneal's three
completed runs are moved aside too, as one consistent set, and rerun.
**No B3 number from the void runs was read.**

### The relaunch (2026-10-20, evening)

The first relaunch stopped at Q0b, before anything ran: 4 of 4 differ. The
build tree now holds step 3's sources, so the rebuilt binary
(`champsim_syncmx_ff193e2a`) prints the gem5-rule and view-order lines. Q0
filters those lines; Q0b did not. **The m2 runs therefore use the
pre-registered `champsim_syncmx_cc45d6f5`** (checked on 2026-10-19: Q0 8/8,
Q0b 4/4), and the rebuild is used for its tracer only. Q0b now filters the
new lines too. step 3's runs keep `champsim_g5_034cd735` (the rebuild
reproduced it exactly), so Q0-full still compares two different binaries.
step 3's chain counts only trace sets whose DONE names the tracer that made
them (pre-2026-10-20 sets have an empty DONE); `sync_server.sh stop` ends a
chain and everything it started.
