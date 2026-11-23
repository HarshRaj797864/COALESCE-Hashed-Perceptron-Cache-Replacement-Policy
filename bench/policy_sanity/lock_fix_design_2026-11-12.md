# F-C: the replay issues a contended waiter's lock-word request. Pre-registered 2026-11-12

Written before any of it is built. It follows the waited-acquire counter's
verdict, **H-C2 SUPPORTED** (`lock_wait_results_2026-11-12.md`, `cd0f3d2`),
by that design's rule (`lock_wait_design_2026-11-06.md` § 4: "Then F-C's note
is written"). PLAN § 10 item 8 fixes the deadline: **F-C enters the paper
only if it is scored at 4 cores by Fri 20 Nov 2026.**

## The cause it addresses

In gem5 a waiter attacks the lock word while the holder has it: a failed
`lock cmpxchg` (an ownership request, GETX), then the futex sleep; the
holder's unlock `xchg` takes the line back; the woken waiter's `xchg` takes it
again. That is three transfers of the lock word's line per contended acquire
with one waiter. In the replay a waiting core is held at dispatch, silent;
only its traced lock instructions, after the grant, move the line: one
transfer. The counter measured where this matters: tens of thousands of
contended acquires in each failing barnes span, at most 879 anywhere else.

## The change

- **Where.** `O3_CPU::dispatch_instruction` (`src/ooo_cpu.cc`), where an
  acquire is held for its mutex (`sync_hold::mutex`). The record carries the
  mutex's address (`sync_mutex`); glibc's lock word is the first field of
  `pthread_mutex_t`, so that address is the lock word's.
- **What.** On the first cycle an acquire's hold is **contended** (another
  core holds the mutex or is ahead of it in the queue: the counter's own
  definition, `note_mutex_wait`), the core issues **one ownership request**
  for that address through `L1D_bus.issue_rfo`, the path a traced locked
  read-modify-write takes at level 2. If the L1D's read queue is full it
  retries on the next held cycle. One request per acquire at most.
- **What it does not do.**
  - An own wait (only the core's own release in flight) issues nothing: no
    other core touches the lock word.
  - Recorded-order runs, ORDERED acquires (after a condition wait; they keep
    their recorded wait) and acquires without a mutex address never take the
    timing path, so they issue nothing.
  - The request is not an instruction: nothing is added to the ROB, the
    retired-instruction counts or the trace position. Its answer returns
    through the L1D's returned queue, which matches loads by block (as two
    loads of one block already merge).
- **The setting.** `sync_lock_word`: `none` (the default; the binary behaves
  and prints exactly as without this change) or `request`.
  `make_config.py --sync-lock-word request`. Each run prints
  `SYNC LOCK WORD: <mode>` only when the mode is `request`, and per core
  `CPU n LOCK-WORD REQUESTS: measured A warmup B` (requests issued, by the
  phase the core was in).
- **The tracer and the traces are unchanged.** The holder's unlock and the
  waiter's lock instructions are already in the traces; F-C only adds the
  waiter's earlier request, so that each of them finds the line at the other
  core when the timing makes it so.

## Checks before any server run (laptop)

- **K0, nothing changes when off.** The exact suite (54 cases) at levels 0,
  1, 2, identical counts; and on real traces (canneal and barnes std, 4
  cores, level 2) every log line identical to the lock-wait binary's
  (`c601b4e4`'s source) with the setting absent.
- **K1, a new exact case `mx_lockword`, level 2** (R = 50 rounds a core, 2
  cores, one mutex M): each core's section is an ACQUIRE record, an RMW of
  M's word (the lock), 30,000 instructions, an RMW of M's word (the unlock),
  a RELEASE record; then 10,000 instructions outside, so each core asks
  again while the other holds M. The order is the tracer's
  (`champsim_tracer.cpp` `SyncExit`: the ACQUIRE goes before the lock call's
  buffered instructions, the RELEASE after the unlock call's; the mutex
  address is the call's first argument). 100 acquires, 99 hand-overs, every acquire
  after the first contended.
  - `none`: each hand-over moves M's line once (the new holder's lock RMW
    finds it at the old holder): **99** store-time events finding another
    core, 99 contended waited acquires, 0 lock-word requests.
  - `request`: per hand-over, the waiter's request finds M at the holder,
    the holder's unlock RMW finds it at the waiter, the waiter's lock RMW
    finds it at the holder: **297** events; **99** requests issued, all
    measured (warm-up 0).
- **K2, own waits issue nothing:** `mx_handover` (contended 0, own 198) with
  `request`: every count identical to `none`, 0 requests.
- **K3, consistency under a queue:** `mx_excl` (4 cores, contended 199) with
  `request`: requests issued = 199 (contended acquires); the shared-data
  events on Y are 199 as before. The lock-word events are printed, not hand
  counted (which core asked last depends on the queue's timing).
- **K4, view order:** Q3's rule on every case: unexplained view-order
  violations 0.

## The server runs (only on the owner's word)

- Build in its own tree (`~/sync_fc_build`), frozen `champsim_fc_<md5>`;
  **Q0** on the server: with the setting absent, 8 reruns print every line
  of the lock-wait reruns (`phaseA_b3_lc_*`) identically.
- **14 reruns with `request`**, the lock-wait set exactly (same traces,
  lengths, configurations, level 2, LRU), into `phaseA_b3_fc_*`.
- **Q3** on each: unexplained view-order violations 0.

## Predictions (scored by `scripts/lock_fix_score.py`, written and self-tested before the reruns end)

R_g5 = (C / I_c) / (G / I_g) with C and I_c from the `request` reruns, G and
I_g from the gem5 rows used for every earlier score (unchanged).

- **P-F1 (barnes's failing spans: std window, std start, barnes-256):**
  R_g5 in [0.5, 2].
- **P-F2 (the agreeing spans: barnes std force, ocean 2 MB, canneal 4c 2 MB,
  canneal 8c, radix, lunc, ocean non-contiguous):** R_g5 stays in [0.5, 2].
- **P-F3:** the shared-cache demand-traffic ratio stays in [0.5, 2] on every
  span where it was.
- **Reported, deciding nothing:** fluidanimate (expected NOT to move: 70
  contended against 52,492 own waits), vips, bodytrack, fmm; each span's
  requests issued against the counter's N; upgrades; cycles against the
  lock-wait reruns.

## How the outcome is read

- **F-C ADOPTED** if P-F2 holds on 7 of 7 and P-F1 on at least 2 of 3, and
  K0-K4 held. Then every Part B ChampSim run is rerun on the F-C binary with
  `request` under an amendment written before those reruns (traces, gem5
  runs and counter runs unchanged), and the paper reports the F-C binary,
  stating the change and fluidanimate's open under-count.
- **F-C NOT ADOPTED** otherwise (or if not scored by Fri 20 Nov). The paper
  reports the g6 binary and states lock-heavy programs as its limit, with the
  counter's evidence (H-C2 supported) and F-C's result if it exists.
- **Overshoot** (R_g5 > 2 on a failing span): reported as an over-count;
  nothing is tuned (no partial request, no probability). A failure is
  diagnosed, never tuned.

## The order

1. Commit this note.
2. Build the setting and the request; add K1-K3 to
   `check_coherence_exact.sh` (the trace generator gains lock-word RMWs).
   Run K0-K4 locally.
3. Write `scripts/lock_fix_score.py` with a self-test on hand cases; the
   server script (a `VARIANT=fc` of the lock-wait runner); rehearse against a
   stand-in server.
4. The owner's word: build, Q0, the 14 reruns.
5. Pull, score, results note. Target: launched by Sun 15 Nov, scored by
   Wed 18 Nov.

## Amendment 1, 2026-11-12: ORDERED acquires, before any code is written

The note says ORDERED acquires (a condition wait's re-acquire of its mutex)
"never take the timing path, so they issue nothing". **That is wrong.** In
`dispatch_instruction` an ORDERED acquire first keeps its recorded wait
(`sync_hold::recorded`); once that release has retired it is checked against
its mutex like any other timing-path acquire, and may be held there
(`sync_hold::mutex`). The waited-acquire counter counted those holds
(`note_mutex_wait` runs for every `sync_hold::mutex`), so the prediction's N
includes them; and in gem5 `pthread_cond_wait` re-locks its mutex through
the same lock word.

**Corrected rule:** a request is issued on the first contended cycle of any
`sync_hold::mutex` hold, ORDERED or not. Own waits, holds for a recorded
wait (`sync_hold::recorded`), recorded-order runs and acquires without a
mutex address issue nothing. Nothing else in the note changes; no code
existed when this was written.

## Build record, 2026-11-12 (step 2 of the order; no server run)

**The code** (working tree on `e033dfc`): `sync_replay.h/.cc` (the setting,
`mutex_contended` -- the same predicate as `note_mutex_wait`'s "another core
involved" -- and the per-core request counts, printed only when on),
`legacy_environment.cc` (`sync_lock_word`, default `none`), `ooo_cpu.h/.cc`
(in `dispatch_instruction`'s `sync_hold::mutex` branch: on the first held
cycle with `mutex_contended`, `L1D_bus.issue_rfo` for `sync_mutex`, retried
while the L1D refuses it; the flag clears when the acquire dispatches),
`make_config.py --sync-lock-word none|request` (the key is written only when
given). A request carries the acquire record's `instr_id` and `ip`; it goes
through the L1D's read queue as a traced RMW's RFO does. It increments no
instruction or RMW counter (the suite's `rmw` column stays 200 with it).

**The exact suite** (`check_coherence_exact.sh`, `coherence_exact_traces.py`):
case `mx_lockword` (K1's traces) and three `_req` cases replayed with a config
that adds `--sync-lock-word request` (`sharedreq<L>.json`). Every run now also
checks the lock-word lines: a `_req` case prints `SYNC LOCK WORD: request` and
the requests asserted below; every other case prints none. `mx_excl_req`'s
totals mix the lock word's events with Y's, so the run writes the event log
(`COHERENCE_EVENT_LOG`) and the suite splits the LLC's G events by line (the
log's others fields are core masks; their bits are counted).
Two corrections before any count was read as a result: `mx_lockword`'s traces
wrapped (cores 2 and 3 keep running while A and B serialise: its tail is now
2 M, as `mx_handover`'s), and the split first summed the masks as numbers.

**K1, K2, K3 hold, at levels 0, 1, 2** (columns v1e v1s pre prc pte ptc rmw
fwd upe upc inv, then the gem5-rule view):

| case | L0 | L1, L2 | waited (contended, own) | requests (measured, warm-up) |
|---|---|---|---|---|
| mx_lockword | 1 1 1 1 1 1 200 0 0 0 0 | 99 99 99 99 99 99 200 0 0 0 198 | 99, 0 | none printed |
| mx_lockword_req | 1 1 1 1 1 1 200 0 0 0 0 | **297** 297 297 297 297 297 200 0 0 0 **594** | 99, 0 | **99, 0** |
| mx_handover_req | as mx_handover | as mx_handover | 0, 198 | **0, 0** |
| mx_excl_req | Y: 3 6 3 3 (as mx_excl) | Y: 199 199 199 199 (as mx_excl) | 199, 0 | **199, 0** |

- Level 0 with request: B's first request brings M into B's caches (the one
  event); nothing is invalidated at level 0, so every later access hits. The
  same count as without, as written into the suite beforehand.
- `mx_excl_req`, reported: the lock word's own events, L0 3 / L1-2 198 (every
  request after the first finds the previous requester); no event on any
  third line.
- K4 on these cases: unexplained view-order violations 0, and raw violations
  0 (the suite asserts both), self-check 0, stale holders 0.

**The scorer, `scripts/lock_fix_score.py`** (self-test 29 of 29; `parser`
mode): C and I_c are read from each rerun's log exactly as `b3_rows.sh` reads
them, traffic as `run_phase_a.sh`'s rows. Before any rerun is read it runs the
parser on the 14 scored logs: **14 of 14 reproduce the committed rows** (b3
rows v18 rfo_g5 and ins, phasea rows v27 tot_acc and wr_acc). A rerun is
scored only if it qualifies (complete; the request line once; one request line
per waited-acquire line; the scored run's lengths and traces; level 2; no
wrap; self-check, stale holders, registration; Q3).

**The server procedure, as built (`scripts/lockfix_all.sh`,
`scripts/lockfix_server.sh`, copies of the lock-wait pair).** The note's
"Q0: with the setting absent, 8 reruns print every line of the lock-wait
reruns identically" is made concrete here, before anything runs: the
lock-wait runner's own Q0 (8 pairs on `canneal_4t`, 1 M + 2 M, LRU and
Hawkeye, both regimes, levels 0 and 2) and Q0m (the synchronised traces of
barnes std force and ocean 4, 1 M + 2 M, their configs), both against the
lock-wait binary `champsim_lc_c601b4e4`, every line equal and no lock-word
line. Added: **Q0r**, the same two synchronised spans with request, 1 M + 2 M,
must complete with the request lines and 0 unexplained violations (it only
gates the chain). Each rerun's config is the scored config plus
`"sync_lock_word": "request"` (checked: no other key differs). After the
chain, Q3 on every rerun.

## Amendment 2, 2026-11-12 evening: K0 and the rehearsal move to the server; the chain gets its own step

**Why.** The owner asked that the laptop carry as little load as possible
("if we can run something on server then lets do it"). The laptop also
rebooted (~17:36) while two jobs were running. The first was K0, on the
laptop: its runs were lost and no result was read. The second was the
stand-in rehearsal: it had built the binary, passed the guards and frozen
`champsim_fc_ae3bb91f`, and was running Q0. Nothing had run on the server.
What K0 tests is unchanged. Only where it runs, and in what order, changes.

**K0 runs on the server**, after the build and on the frozen binary, as part
of a new `check` step (`scripts/lockfix_all.sh check`). The server runs
`bench/policy_sanity/check_coherence_exact.sh` and
`coherence_exact_traces.py`, uploaded to `~/sync_fc_build` with the sources
and checked to be committed. It runs twice, side by side, at nice 19, 8 runs
at a time each, with traces under `/tmp/harshraj_fc_k0` (removed afterwards;
`/home` is 99% full):
- the F-C binary on every case (the 54 cases plus K1-K3's 12) at levels 0, 1
  and 2: the suite must print PASS;
- the lock-wait binary `champsim_lc_c601b4e4` on the 18 case names it can run
  (every one except the three `_req` cases), 57 runs: PASS;
- those 57 logs must be equal line for line between the two binaries. The
  run time and the trace directory are the only text taken out.

This is stronger than "identical counts". **K0's real-trace half moves into
Q0m:** `Q0M_SPANS` gains `canneal4`, so Q0m covers canneal 4, barnes std
force and ocean 4, on synchronised traces, level 2, with their scored
configs, every line equal to `c601b4e4`'s. Q0 (canneal_4t, 8 pairs) is
unchanged. Q0r gains canneal 4 too.

**The rehearsal.** The `check` step on the real server replaces the stand-in
rehearsal for everything up to the chain: upload, build, guards, the frozen
copy, Q0, Q0m, Q0r and K0. It starts no rerun. The chain is the lock-wait
chain, which ran 14 of 14 on this server on 2026-11-11, with three changes:
the binary, the tree names, and the config maker `make_fc_cfg`. The
`check` step exercises all three (Q0r makes and runs request configs), and
`chain` makes all 14 configs before it starts. **The chain is a separate
step, `scripts/lockfix_all.sh go`, taken only on the owner's word after
`CHECK PASSED`.** It refuses unless Q0, Q0m, Q0r and K0 all passed on that
binary. The combined "build, then chain" launch is gone.

Nothing else changes: the predictions, the adoption rule (P-F2 7/7 and P-F1
≥ 2/3) and the date (scored by Fri 20 Nov).

## Check record, 2026-11-12 (amendment 2's `check`, on the server; no rerun started)

`scripts/lockfix_all.sh check` (`5a93925`). The sources and the exact suite
were uploaded and matched the laptop's. **CHECK PASSED on
`champsim_fc_a2e88e46`** (md5 a2e88e46788e1f332427567a19bc2f90, built in
`~/sync_fc_build`):
- **Guards:** all three pass.
- **Q0 holds:** 8 of 8 canneal_4t pairs print every line the same as
  `champsim_lc_c601b4e4`.
- **Q0m holds:** barnes std force, ocean 4 and canneal 4 on their
  synchronised traces print every line the same, with no lock-word line.
- **Q0r holds:** all 3 complete with the request lines and 0 unexplained
  violations. Their request counts are records, not results.
- **K0 holds:**
  - the suite with the F-C binary: 66 ok, 0 FAIL, PASS;
  - with the lock-wait binary on the cases it can run: 57 ok, 0 FAIL, PASS;
  - those 57 logs are equal line for line between the two binaries.

K0's traces in `/tmp/harshraj_fc_k0` were removed. Reruns: 0 of 14 (none
started). The 14 reruns start with `scripts/lockfix_all.sh go`, on the
owner's word.
