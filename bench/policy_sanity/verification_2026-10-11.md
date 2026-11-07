# Verification pass before step 2 — the laptop half

**2026-10-11.** The owner asked for every step to be re-verified before more
is built on it ("I am confident we have made errors"). This records what was
checked, how, and what turned up. The server half is pending:
`scripts/verify_b3_all.sh`.

## Result so far

**No error found in the simulator, the counters or the published verdicts.**
The one surprise, a 2× to 26× gap between the trace's RMW count and the
simulator's, was run down to store-to-load forwarding and closed to within
2 instructions of 13,368.
- Seven errors found in my own tooling and claims, all fixed. Six were in
  test tooling. The seventh is one extraction column that read 0.7% low, a
  diagnostic no verdict uses.
- One property worth stating was found by reading the code.
- One reproducibility gap is closed.

## What was checked

| check | how | result |
|---|---|---|
| The coherence counters count right | `check_coherence_exact.sh`: five 4-core traces whose counts are worked out by hand; the simulator must match **exactly** | **pass**, all five; identical on a second full run |
| A read-modify-write is issued as an RFO, once | same test: 100 / 200 / 16 RMW loads expected and counted | pass |
| The private regime shares nothing | same test, `order` in the private regime | every counter 0 |
| A writeback removes the core from the directory | `wb_evict`: directory 0 / 0 after a forced eviction, 14 LLC writebacks; `wb_control`: 8 / 8 without it | pass |
| A request is counted once | read `cache.cc`: the hook sits in the hit branch, after a miss is accepted (merged or forwarded), and in `handle_write`; a miss retried for a full MSHR returns before it | no double count possible on these paths |
| Events and instructions cover the same span | read `champsim.cc`: "Simulation complete" prints each core's count at the end of the phase; the LLC's scalar counters are copied at the last core's finish, the same moment | consistent |
| b3_rows.sh reads the right block | the exact test asserts that the first block's protocol count equals the Region of Interest block's | equal in all five |
| gem5 extraction | one statistics dump per file; per-CPU instructions sum to `simInsts`; one L2 controller; scalar totals | pass, all 13 runs (`b3_score.py gem5-rows` refuses otherwise) |
| The published numbers | `scripts/b3_score.py`, written fresh, from committed rows only | reproduces every R, traffic and store-miss ratio in the B3 documents, and the 10-row identity (P0) |

The five exact cases, as run (`v1e v1s pre prc pte ptc rmw`):

```
ok    order, shared          100 200 100 200 100 150 100   self-check 0, registered 12
ok    order, private         0 0 0 0 0 0 100
ok    pingpong               50 50 50 50 50 50 200
ok    wb_control             7 7 8 8 8 8 16          (v1 not asserted)
ok    wb_evict               0 0 0 0 0 0 16          LLC writebacks 14
```

## Found by reading the code

1. ~~Traffic rates per KI read up to ~0.7% low.~~ **Retracted the same day:
   this was wrong.** `CACHE::end_phase` copies the cache counters whole
   (`roi_stats.hits = sim_stats.hits`), so the LLC's access counts cover the
   whole measured phase, as the instruction total does. The raw log shows the
   two blocks equal. I had read half of that function. See "the server half"
   below.
2. **A core that only read a line stays in the protocol view after it
   silently drops its clean copy.** A later store by another core then counts
   an event. Whether gem5 counts that case depends on the state the reader
   held; this is **not verified** against the protocol source. It is a
   candidate for why R_b sits above 1 on ocean and canneal (1.11–1.35), and
   it is recorded here, not acted on. Nothing is tuned.

## The known gap, now pinned down

`pingpong`: two cores take turns writing one line, four turns a round.
ChampSim counts **1** event a round, the first hand-over. The later turns hit
each core's own stale copy and never reach the LLC. A real protocol counts 3.
This is barnes's failure in miniature (`b3v2_canneal_barnes_2026-10-07.md`),
and it is step 2's target: its expected count must change from 50 to 150,
deliberately.

## Errors found — all in my tooling

| error | effect | fixed by |
|---|---|---|
| test: one core always missed to DRAM and drifted behind | its "known order" broke after ~26 rounds; counts looked wrong (172 of 200) | rotating the roles across cores |
| test: lines 64 KB apart assumed to collide in the L2C | they collide only in the L1D (physical indexing), so the eviction never happened | sweeping a 2 MB region |
| test: traces exactly as long as the simulation | every trace wrapped at its end (S3) | a quiet tail; the check refuses any wrap |
| test: two pairs first-touching their regions together | interleaved page numbers; the sweep missed the target set in 2 of 12 rounds | the second pair starts after the first |
| test: expected v1 to fire where the LLC had lost the line | v1 read 7 of 8: its known flaw, not a new one | v1 not asserted there |
| `verify_b3.sh`: `pgrep -f count_rmw.py` matched my own shell | "already running" when nothing was | matching the python process itself |
| `b3_rows.sh`: the RMW column read the per-core ROI block; and my claim of a 0.7% traffic bias | the RMW diagnostic 0.7% low; a false caveat on the traffic ratios | reading the whole-simulation block; the claim retracted (server half, below) |

Each of the first four first looked like a simulator bug. In each case
a second counter settled it: LLC writebacks 0, or presence agreeing with the
self-checked cache contents.

## The reproducibility gap, closed

- The scoring arithmetic lived in throwaway scripts, lost on 2026-10-09. It
  is now `scripts/b3_score.py`.
- The gem5 counters were never committed, only ChampSim's rows. They are now
  `gem5_b3_rows_v1.txt` (13 runs).

## The server half — `scripts/verify_b3_all.sh`, run 2026-10-11

Read-only. Its output is in `simulator/results/verify_b3_20261011_113549.txt`
(untracked).

| check | result |
|---|---|
| The server's sources are this checkout's | **14 of 14 files identical** by md5 (`1ab4cdb`; the simulator is unchanged since `f23e03f`) |
| The binaries | `bin/champsim` built 2026-10-07 17:18:19, two seconds before the v3 queues started, with the step-1 counter; `bin/champsim_b3v2_acb76b2` built 2026-10-05, directory but no step-1 counter |
| Every B3 run's settings | all 20 logs: warmup 50 M, simulation 100 M, 4 CPUs, ended, **no wrapped trace** |
| The traces each core ran | canneal `canneal1..4` (thread 0 skipped), ocean `ocean0..3`, barnes `barnes_4t0..3`; four distinct traces in every run |
| The regime | aliased fills 0 in all 10 private runs; identical between each v2 and v3 shared run |
| Which binary ran what | the step-1 counter prints in all 10 v3 logs and in no v2 log |
| The rows against a raw log | canneal 4c shared, 2 MB, step 1: **every column of both rows files matches the log**: instructions, cycles, the five LLC access types, invalidations, all eight coherence counters |

**That last check caught an error of mine: the seventh.**
- The raw log shows the LLC's two stats blocks equal, so the LLC's counts
  cover the whole measured phase. Finding 1 above was therefore wrong and is
  retracted.
- The same false belief had made me read the RMW column from the per-core
  Region of Interest block "to match the instruction column". The
  instruction column is whole-simulation. So **the RMW column in
  `b3_rows_v5` reads 0.7% low**: 2,255,265 for 2,270,517, i.e. 5.60 per KI
  for 5.64.
- It is a diagnostic. No R, ratio or verdict uses it.
- `b3_rows.sh` now reads the whole-simulation block. Tested on that run's
  raw lines: 2,270,517, every other column unchanged.
- `b3v3_step1_2026-10-09.md` carries a dated correction.

## Also re-derived, independently of the tools that produced them

- **A5's Kendall τ**, with a few fresh lines of arithmetic instead of
  `analyze_rows.py`, from `phasea_rows_v14.txt`. Every value matches:
  - canneal, pressure-matched: +0.57 / +0.29 / +0.29 (22–6, 18–10, 18–10 of
    28 pairs);
  - geometry-matched: +0.29 / +0.14 / +0.29;
  - fixed: +0.86 / +0.71 / +0.64;
  - ocean control: +0.71 / +0.93.

  The policy orders match too.
- **gem5's hierarchy against ChampSim's**, from the pulled `config.ini`
  files and `make_config.py`. They are identical in size and associativity
  at all three levels: 32 KB 8-way, 512 KB 8-way, 2 MB or 8 MB 16-way,
  64-byte lines. The one difference is the pre-registered one: Ruby's
  tree-PLRU against LRU.

## The trace count — and what it turned up

`count_rmw.py`, straight from the traces, records 50 M–150 M of each thread
(`verify_b3_rmw_20261011_120223.txt`), against the simulator's "RMW loads
issued as RFO" from `b3_rows_v6.txt` (the corrected, whole-simulation
column):

| | RMW instructions in the trace, per KI | issued as RFO, per KI |
|---|---|---|
| ocean (thread 0) | 0.046 | 0.038 |
| canneal (4 threads) | 11.65–11.67 | 5.64 |
| barnes (4 threads) | 26.5–27.5 | 1.02 |

The trace count was expected to be an upper bound, but not by 2× and 26×.
So the gap was run down rather than waved through.

**The gap is store-to-load forwarding, which is upstream ChampSim behaviour
that step 1 does not touch.** A store stays in the store queue until its
instruction retires (`operate_lsq`). A later load of the same address,
dispatched before then, takes its value from the store and is never issued
to L1D (`do_memory_scheduling`). Compiler-generated stack updates, such as
a loop counter, are RMWs of exactly that kind.

**Shown exactly, on a real canneal trace** (`canneal_simlarge`, records
1,000,000–3,000,000, one core):

| | count |
|---|---|
| RMW instructions in the trace (`count_rmw.py`) | 13,368 |
| issued as RFO (the simulator) | 11,774 |
| satisfied from the store queue (the simulator, new counter) | 1,592 |
| issued + forwarded | **13,366** |

The 2 short are instructions in flight at the window's edges. Independently,
from the trace alone: the RMWs whose previous store to the same address is
at most 72 instructions back number 1,594, and those further back 11,774.

**What was added, so this is checkable from now on:**
- A second statistics-only counter, "RMW LOADS FORWARDED FROM THE STORE
  QUEUE". Every RMW load dispatched is issued or forwarded, so the two must
  sum to the trace's count.
- The simulator's output is otherwise identical line for line, and the
  exact tests' counts are unchanged.
- A sixth exact case, `forward`: 50 issued, 50 forwarded, by construction.
  The other five cases now also assert 0 forwarded.

**Why forwarding loses no ownership request:** the older store that the
load took its value from goes to L1D itself, as a WRITE, and a WRITE that
misses is forwarded as an RFO.

**Not yet closed on the real `canneal_4t` window.** The server's step-1
binary predates the forwarded counter. It closes with the traces on the
laptop (`scripts/pull_traces.sh`: one core, the same records) or with the
next server build.

## Rows refreshed

`b3_rows_v6.txt` has the corrected RMW column; its other 17 columns are
identical to v5. `phasea_rows_v15.txt` is identical to v14.
`phasea_rows_v12.txt` and `b3_rows_v3.txt` are an earlier pull of
2026-10-07, identical in content to v13 and v4, committed for the record.

## Closed on the real 4-thread traces (2026-10-11, later)

The identity above was shown on `canneal_simlarge`. With `canneal_4t` and
`barnes_4t` on the laptop (md5s equal to the server's), it is closed on the
traces the B3 runs use: 4 cores, shared, 2 M warmup + 10 M simulated, the
B3 v4 binary at level 0. Each core's simulated records were counted with
`count_rmw.py` from its own start and length, as its log prints them.

| | RMWs in the trace | issued as RFO + forwarded | short by |
|---|---|---|---|
| canneal, 4 threads | 483,873 | 236,104 + 247,757 = 483,861 | 12 |
| barnes, 4 threads | 1,041,239 | 163,786 + 877,443 = 1,041,229 | 10 |

No core is off by more than 6. Those are instructions in flight at the
window's two edges.
