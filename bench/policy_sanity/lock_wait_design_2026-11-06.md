# Round 2, step 1: count the lock acquires that waited (records only), and the prediction they test. Pre-registered 2026-11-06

Owner, 2026-11-06: "ok start step 1, the lock counter". This follows round 1
(`disagree_diagnosis_results_2026-11-06.md`, `e02452d`).

- **Round 1's lead (H-C2).** In ChampSim a core that waits for a mutex sits
  silent, and its lock instructions run only after it is granted the mutex.
  The tracer writes the ACQUIRE record before the lock's own instructions.
  - A thread in gem5 attacks the lock word while the holder still holds it.
  - So a contended acquire moves the lock word's line between cores about
    three times in gem5, against once in the replay.
- **What this step does.** A counter that changes nothing but adds lines
  says how many acquires waited, and why, in the measured phase. From that
  count, a prediction fixed here says what R_g5 would read if the missing
  transfers were there.
  - No fix is built in this step.
  - F-C, the replay issuing the waiter's lock-word accesses, gets its own
    note, and only if the prediction below holds.

## 1. The counter

- **Waited.** Under the timing mutex order, an acquire has *waited* if its
  dispatch was held for its mutex for at least one cycle. These are the same
  cycles `CYCLES WAITING FOR A MUTEX` already counts, at the same place
  (`ooo_cpu.cc`, after dispatch).
- **Why it waited.** Each held cycle reads the mutex's state:
  - **contended:** at some held cycle, another core held the mutex, or another
    core was ahead of it in the mutex's queue;
  - **own:** otherwise. The only thing it waited for was its own release
    still in flight ("a core's own unretired release does not free the mutex
    for it", `sync_replay.h`).
- **When it counts.** The acquire is counted when it takes the mutex, in the
  phase its core is in then: warm-up or measured.
- **Measured cycles.** The cycles held for a mutex are also counted for the
  measured phase alone. Round 1's W summed over warm-up as well. In barnes
  std's force span, warm-up is the lock-heavy tree build. That may be why
  that span read 10.9% while it agrees.
- **New printout,** one line per core under the existing mutex lines:
  `CPU n MUTEX WAITED ACQUIRES: measured contended A own B cycles C; warmup contended D own E`
- **Records only.** No other line, no timing, no event changes.
  - Recorded-order runs, and acquires without a mutex address, are not
    counted: they never take the timing path.
  - A trace with no mutex record prints no such line, as now.

## 2. Local checks, before anything goes to the server

- **K1, exact** (`check_coherence_exact.sh`, levels 0, 1, 2; warm-up 0, so
  everything is measured):
  - `mx_excl`: contended **199**, own **0**, summed over the four cores.
    - Four cores take 50 sections each, first come first served. Each core
      asks again with 10 records between its release and its next acquire,
      while the other cores are already queued.
    - So every acquire but the very first finds another core holding the
      mutex or ahead in the queue.
  - `mx_handover`: contended **0**, own **198**.
    - A takes its 100 turns alone, then B its 100, after B's 1 M
      instructions.
    - Each next acquire has 2 records between it and the core's own
      release. The release cannot retire before its RMW's store is
      performed, so every acquire but each core's first waits for its own
      release (99 + 99).
  - `mx_handover_rec`, `mx_cond_rec` (recorded order): no waited acquire is
    counted (0 / 0).
  - `mx_cond`: printed, not asserted. Its ordered acquires wait on recorded
    releases, and its mutex waits are not hand-derived.
  - Cases without mutex records: no line.
  - Every count the suite already asserts stays as it is.
- **K2, the split.** `mx_excl` with a warm-up of 80,000 instructions a core:
  warm-up + measured = 199 / 0. Both phases are non-zero.
- **K3, Q0.** The new binary against the current source's binary (`1b56891`,
  the g6 build's source). Every line of each log is identical, apart from the
  new lines, on:
  - the whole exact suite at levels 0, 1 and 2;
  - Q2b's real Pin traces of `bench/mutex_micro.c` (glibc mutexes, through
    `bench/micro_champsim.sh`);
  - short runs (1 M + 2 M) of the laptop's real `canneal_4t` and `barnes_4t`
    traces (no sync records).

A failure in K1-K3 stops the step. It is diagnosed, and nothing is changed to
make it pass.

## 3. The server runs (only on the owner's word)

- **Build.** In its own tree, frozen as `bin/champsim_lc_<md5>`. `bin/champsim`
  and every live chain are untouched.
- **Q0 on the server.** Against `champsim_g6_1e3060c1`, as before.
- **Rerun every span round 1 read, on the same traces and settings as its
  scored run:**
  - set 2: fluidanimate, vips, ocean non-contiguous, bodytrack (reported);
  - the g3 runs: barnes std window, start and force, barnes-256, ocean 2 MB,
    canneal 4c 2 MB, canneal 8c, radix, fmm (reported);
  - lunc's step 4 run.
- **Q0-full.** Every old line of each rerun equals the scored run's log. A
  difference stops the step: the counter would have changed behaviour.

## 4. The prediction, fixed now

**The lock in gem5.** `pthread_mutex_lock` on a default mutex uses glibc's
low-level lock: `lll_lock`, `__lll_lock_wait`, `lll_unlock`.
- Lock: one `lock cmpxchg` 0 → 1. If that fails, `__lll_lock_wait`: `xchg`
  → 2, and a futex wait while the old value is not 0.
- Unlock: `xchg` → 0, and a futex wake if the old value was 2.

**One waiter W against a holder H:**
- in gem5:
  1. W's failed `cmpxchg` takes the line from H;
  2. H's unlock `xchg` takes it back from W;
  3. W's `xchg` after waking takes it from H.

  That is 3 store misses that find another core.
- In the replay: 1. W is granted the mutex, and its first lock instruction
  takes the line from H.

**With further waiters,** a waiter's own two transfers remain, and the
unlock's transfer is shared among them. So:
- **the replay misses k = 1 to 2 events per contended acquire** (2 for a
  lone waiter, 1 at the least);
- own waits miss nothing: no other core touches the line.

**The predicted ratio, with N the measured contended waited acquires summed
over cores:**

  R_g5(k) = ((C + k · N) / I_c) / (G / I_g),  for k = 1 and k = 2

C, I_c, G and I_g are as in round 1: the scored rows, unchanged by a
records-only rerun. N comes from ChampSim's own timing, not gem5's, and F-C
would add the transfers in ChampSim's own timing. This prediction tests
exactly that.

**Rules:**
- **P-L1 (failing spans: fluidanimate, barnes std window, barnes std start,
  barnes-256):** the interval [R_g5(1), R_g5(2)] meets the band [0.5, 2].
- **P-L2 (agreeing spans: barnes std force, ocean 2 MB, canneal 4c 2 MB,
  canneal 8c, radix, lunc, ocean non-contiguous):** R_g5(1) and R_g5(2)
  both stay in [0.5, 2].
- **Reported, deciding nothing:**
  - vips. Expected to move little (round 1: W 0.075%); its candidates are
    the main thread and drift.
  - bodytrack and fmm (programs not scored).
  - Each span's measured-phase W.
- **Verdict:**
  - **H-C2 SUPPORTED** if P-L1 holds on at least three of the four failing
    spans and P-L2 holds on every agreeing span. Then F-C's note is written.
  - **H-C2 REJECTED** if P-L1 fails on three or more failing spans by
    falling short (R_g5(2) < 0.5). The diagnosis goes on, and F-C is not
    built.
  - **Overshoot** (R_g5(1) > 2 on a failing span, or P-L2 failing above 2):
    k ≥ 1 per contended acquire is too many. That is reported, and the next
    note reads gem5's lock-word traffic directly.
  - **Anything else:** PARTIAL, reported as measured.

## 5. The order

1. Commit this note.
2. Build the counter (`simulator/src/sync_replay.cc`, `inc/sync_replay.h`,
   `src/ooo_cpu.cc`) and add its K1 assertions to
   `check_coherence_exact.sh`.
3. Run K1-K3 locally.
4. Write the server script and rehearse it against a stand-in server.
5. Give the owner the one command.
6. Score with `scripts/lock_wait_score.py`. It is written before the runs end,
   and checked on a hand case.
