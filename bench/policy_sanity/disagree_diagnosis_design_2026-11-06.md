# Every program that does not agree: the inventory, the hypotheses, the tests. Pre-registered 2026-11-06

Owner, 2026-11-06, after held-out set 2 was scored
(`heldout2_results_2026-11-06.md`): "find all the programs that did not agree
and the reason lets try to fix them". The owner's rule (2026-11-05):
failures are diagnosed, never tuned, and every step is written before it
runs.

This note:
- lists every program that has not agreed, or could not be tested, and the
  reason on record;
- states the hypotheses for the programs that were scored and failed;
- fixes round 1's tests, their predictions and what each outcome leads to.

Round 1 reads only files already on the laptop. Nothing runs on the server.
No fix is built in round 1. Each fix gets its own note, and any server work
runs on the owner's word.

## 1. The inventory

**A. Scored, and outside the band (the tool disagrees with gem5):**

| program | R_g5 | set | source |
|---|---|---|---|
| fluidanimate | 0.398 | held-out set 2 | `heldout2_results_2026-11-06.md` |
| vips | 0.309 | held-out set 2 | same |
| barnes std, start span | 0.233 | development | `sync_mx_g5_results_2026-10-27.md` |
| barnes std, window span | 0.249 (reported) | development | same |
| barnes-256 | 0.267 | development (its own gem5 run) | same |

- All five read **low**: ChampSim lists fewer cores at a store miss than gem5.
- barnes std's force span agrees (0.634), and so do ocean (0.682 / 0.768),
  canneal 4c and 8c (1.016 / 0.927 / 1.537), radix (0.990), lunc (1.831) and
  ocean non-contiguous (0.663).
- Reason on record: none for set 2. For barnes, "from the replay, not the
  rule" (it fails in the protocol view too), with P1 (drift) failing on
  barnes std force and barnes-256. Not diagnosed.

**B. Not scored, because a qualifying check failed (agreement unknown):**

| program | check failed | reason on record | gem5 events |
|---|---|---|---|
| fft | same stream (v1) | gem5 counts a 16-byte access as two requests (H1 of `stream_fix_design`); libm differs between the host's and gem5's CPUID (S2 failed) | 0 |
| volrend | same stream (QC: stores +1.1%, RMWs +1.5% against one counter run) | run-to-run variation of its work queue (H3), not established | 6,888 |
| fmm | same stream (v1: stores 1.32x, RMWs 1.37x, loads 1.065x) | "threads run unevenly under gem5", not established | 9,953 |
| streamcluster | same stream (v1, host CPUID) | glibc's string routines differ between CPUIDs (H2) | 2,245 |
| bodytrack | QW (untraced CPUs 3.933% > 1%) | its main thread works during the window (CPU 0, 15.71 M) | 26,542 |

- streamcluster is being redone now by set 2's procedure (newbench
  amendment 3; `sc` ran 2026-11-06). It is not diagnosed here.

**C. Not discriminating (gem5 has under 500 events). Not a disagreement:**
- lu 108, raytrace 184, water-nsquared 414, facesim 1.
- Nothing is proposed for them. Their checks hold, and they cannot test
  agreement.

**D. Replaced before running, by the step 4 rules:**
- cholesky (below the size rule);
- water-spatial (hangs);
- radiosity (no anchor in 48 h; replaced by lunc).

## 2. What is already established about group A

- **The cache geometry is matched.**
  - ChampSim: L1D 32 KB (64 x 8), L2C 512 KB (1024 x 8), LLC 2 MB, no
    prefetcher (`make_config.py`).
  - gem5 (`config.ini`, held-out runs): L0 32 KB, L1 512 KB, L2 2 MB,
    `enable_prefetch=false`.
  - **Capacity is ruled out as the cause.**
- **The instruction streams match.**
  - fluidanimate and vips pass QC and v2 with the native range.
  - barnes std's force and window spans pass v1.
  - barnes-256 passes v1 on RMWs (1.019) and locked RMWs (1.013); it misses
    only on stores (1.058, gem5's micro-ops).
- **RMW volume alone does not break agreement.** canneal issues 11.67 RMWs
  per 1,000 instructions (`lock cmpxchg` on its element pointers), equal in
  the trace and gem5 to 0.1%, and agrees.
- **The failing spans are the ones where threads wait on mutexes:**
  - barnes's tree build (start span: a lock per cell insertion);
  - barnes-256 (5.17 lock/unlock pairs per 1,000 instructions);
  - fluidanimate (a mutex per boundary cell);
  - vips (a pool of worker threads; whether they wait on mutexes is not
    yet read, and W below shows it).
  - barnes's force phase reads the tree with few locks, and agrees.

**Already seen before this note** (it would be wrong to call these blind):
- the score's rates for set 2 (gem5 RMWs per 1,000: fluidanimate 3.234
  against the counter's 3.185; vips 0.220 against 0.217-0.218);
- barnes-256's RMW ratios (1.019 / 1.013);
- canneal's (0.1%);
- fmm's (1.37x).

**Not yet seen:**
- gem5's system calls and idle cycles;
- ChampSim's cycles waiting for a mutex;
- gem5's per-CPU messages from L2;
- the drift of the set 2 runs;
- the RMW excess for ocean, radix, lunc, ocean non-contiguous, bodytrack
  and barnes std's spans.

## 3. The hypotheses for group A

- **H-C, contended locks (the leading hypothesis).** When a ChampSim core
  waits for a mutex another core holds, the synchronised replay holds it at
  dispatch, and it issues nothing (`CYCLES WAITING FOR A MUTEX` counts this
  time). A thread in gem5 runs glibc's slow path instead:
  - a failed `lock cmpxchg`;
  - an `xchg` before the futex wait;
  - another `xchg` after each wake-up.

  Each of these takes the lock word's line from the core that holds it: a
  store miss that finds another core. The trace was recorded under Pin's
  timing, where these retries were rare (fluidanimate's three counter runs
  give identical counts). So ChampSim replays few of them, while gem5 makes
  its own.
  - Predicted consequence: R_g5 reads low exactly where mutexes are
    contended, by roughly the share of gem5's events that are retries.
- **H-A, untraced CPUs.** gem5 runs the main thread (fluidanimate CPU 0;
  vips CPUs 0-2; bodytrack CPUs 0 and 5) on CPUs that ChampSim does not
  model. Idle in the window, their private caches can still hold lines
  written during set-up. A worker's store miss on such a line counts in
  gem5, and in ChampSim it cannot.
- **H-B, drift.** ChampSim's cores drift further apart than gem5's, so fewer
  conflicting accesses meet (P1 failed on barnes).

**Ruled out (§ 2):** capacity; a different instruction stream.

## 4. Round 1: the tests (laptop, pulled files only)

Definitions, for a window (the 150 M stop minus the 50 M stop, as
`b3_score.py`):
- G is gem5's events (SS + MT `L1_GETX`) and I_g gem5's window
  instructions.
- C is ChampSim's gem5-rule events and I_c its instructions.
- **D**, the shortfall from the band's edge: D = G − 2 · C · I_g / I_c.
  These are the gem5 events that would have to go for R_g5 to reach 0.5. D
  ≤ 0 means the program is in the band.

**T1 (H-A): the most the untraced CPUs can explain.**
- M_u is the sum, over the untraced CPUs, of the messages their L1 received
  from the L2 in the window: `system.ruby.l1_cntrl<c>.requestFromL2.m_msg_count`.
  These are invalidations, forwarded GETX and forwarded GETS.
  - Every gem5 event in which an untraced CPU holds the line sends that CPU
    at least one such message. So M_u bounds those events from above.
  - It also counts the L2's own back-invalidations, so it is a loose bound.
- **H-A can explain a program's miss only if M_u ≥ D.** If M_u < 0.1 · D, H-A
  is rejected for it.
- Programs: fluidanimate, vips; bodytrack reported.
- **Expected:** fluidanimate's M_u < D. Its CPU 0 commits nothing in the
  window, and only lines it still holds can count (at most ~9,200: 512 KB +
  64 KB), against a D of about 8,900. The margin is small; the number
  decides. vips: no expectation.

**T2 (H-C): contention, and the retries ChampSim cannot replay.** For every
scored span, agreeing and failing:
- **E**, gem5's excess RMWs over the native run, at gem5's window
  instructions: (gem5's RMWs per 1,000 − the native rate) · I_g / 1000.
  - gem5's RMWs = `RMW_Read + Locked_RMW_Read` (`gem5_mix_v6.txt`, as both
    checks).
  - Native: for set 2, the highest of the three gem5-CPUID counter runs (in
    gem5 units, the smallest E). For the older programs, the trace
    (`trace_mix_v5.txt`).
- **S:** gem5's system calls in the window (`system.cpu0.workload.numSyscalls`,
  process-wide). In a compute phase these are almost all futex waits and
  wakes, one or two per contended acquire.
- **W:** ChampSim's cycles waiting for a mutex, summed over its cores, as a
  share of cores x simulated cycles (`CPU n MUTEX ACQUIRES: ... CYCLES
  WAITING FOR A MUTEX: N`).
- **The rule:**
  - **H-C is supported as the main cause** if all four hold:
    - (a) E ≥ D on fluidanimate, barnes std window and barnes-256;
    - (b) S > 0 and W > 0 on each of those three;
    - (c) on canneal 4c and 8c and radix (agreeing; barrier and CAS
      programs), E < 0.1 · G;
    - (d) vips has E ≥ D, or E + M_u ≥ D (H-C and H-A together).
  - **H-C is rejected as the main cause** if E < 0.1 · D on two of the three
    in (a).
  - **Anything else is partial:** reported as measured, and the next step is
    chosen in the next note.
- barnes std's start span gets E only if its stream is established; it was
  "not established" in v1 (thread 0's serial start was not pulled).
  Otherwise it is reported without E.
- **What I expect (not a prediction):** (a) holds on fluidanimate. From the
  rates already seen, E ≈ 18,900 against D ≈ 8,900. barnes and vips are not
  known.

**T3 (H-B): drift, reported.**
- Each run's median core spread is computed by `heartbeat_drift.py` from the
  ChampSim run log.
- It is set beside gem5's spread among the traced CPUs at its 150 M stop
  (their committed instructions, `gem5_b3_rows_v6.txt`).
- Under H-B, the failing runs read ≥ 4 M wider than gem5 and the agreeing
  runs do not. T3 decides nothing alone.

**Runs used:**
- ChampSim: `phaseA_b3_h2_*` (set 2, ocean non-contiguous);
  `phaseA_b3_g3_*` (barnes std spans, barnes-256, ocean, canneal 4c / 8c,
  radix); lunc's step 4 run.
- gem5: the pairs `b3_score.py` uses for each (REFS).
- The script is written after this note is committed, in
  `scripts/disagree_diag.py`. It reads only those files and prints every
  number with its inputs.

## 5. What each outcome leads to (each fix is its own note, before it is built)

- **H-C supported → F-C, contended-lock traffic in the replay.**
  - While a core waits for a mutex another core holds, ChampSim issues what
    glibc's slow path issues: an RMW on the mutex's line when the wait
    begins, and one when the core is granted the mutex.
  - The mutex's address is already in the traces (the mx tracer records it).
  - Its note pre-registers:
    - the exact sequence, from glibc 2.39's `lll_lock` / `__lll_lock_wait`
      source;
    - an exact micro case;
    - predictions: fluidanimate, barnes std and barnes-256 move into the
      band, and every agreeing program stays in it.
  - It touches only runs where a core waits for a mutex.
- **H-A can explain vips → F-A.** The untraced threads' set-up enters
  ChampSim: thread 0's trace replays on an extra core during warm-up only.
  This is a new run mode; its note states how warm-up ends for that core.
- **Both rejected → round 2.** It examines which lines carry gem5's extra
  events, with a gem5 run that records them by address. That is a server
  run, and only on the owner's word.
- **Group B, by procedure:**
  - volrend and fft by set 2's procedure, as streamcluster now:
    - gem5-CPUID traces by nc's tracer;
    - the counter x3 + host;
    - QC and v2 with the native range.
    - The native range is what volrend's run-to-run variation needs; v2's
      gem5 units absorb H1 for fft.
    - fft can at most show the same stream (gem5 has 0 events).
  - fmm: its RMW excess (1.37x) is far beyond any native range. Under H-C it
    is gem5's lock retries; then it is a case for F-C, and its same-stream
    rule needs its own wording in F-C's note.
  - **bodytrack → F-W:**
    - its main thread is traced as a fifth core;
    - ChampSim gets gem5's stop rule: the run ends when the worker cores end
      their window, so a mostly idle thread need not run 150 M
      instructions.
    - This is new engineering, and its own note.

## 6. The order

1. Commit this note.
2. Write `scripts/disagree_diag.py`. Check it on one hand-computed case
   (fluidanimate's G, C, I_g and I_c from the score, which give D = 8,914).
   Then run T1-T3.
3. Write the results in `disagree_diagnosis_results_2026-11-06.md`, every
   number as printed.
4. Write the fix notes that the outcomes call for, for the owner's word.

## Amendment 1, 2026-11-06: before the script ran, before any new number

Found while writing `scripts/disagree_diag.py`, from file listings and run
logs only (the traces each run replayed). No value was read.

- **The native rate for the older programs comes from the traces ChampSim
  replayed, not from `trace_mix_v5.txt`.**
  - The g3 runs replay the synchronised re-traces in `traces/sync_mx/`.
  - `trace_mix_v5.txt`'s barnes, ocean, canneal and radix rows count the
    earlier traces: a different native run, whose lock retries can differ.
  - The re-traces' own counts were pulled: `simulator/results/sync_mx/traces/<p>/raw*.mix`.
  - The window is each run's own: records [warm-up, warm-up + simulation)
    from its log. barnes std: [37.9 M, 137.9 M) for the window span and
    [37.9 M, 87.9 M) for the force span. The others: [50 M, 150 M).
  - lunc keeps `trace_mix_v5.txt`'s rows: they count the traces lunc's run
    replayed.
- **canneal is added to T1 as a reported control.**
  - Its gem5 runs have 5 CPUs (9 at 8 cores), and CPU 0, the main thread, is
    not traced. So H-A applies to it, and it agrees.
  - Its M_u is printed beside fluidanimate's and vips's. It decides nothing.
- **W's denominator:** the run's cycles, warm-up plus simulation, summed over
  cores. The stall counter (`sync_replay.cc`, `note_mutex_stall`) counts
  every cycle the dispatch is held for a mutex, from the run's start.
