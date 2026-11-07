# Synchronised replay, first reading (2026-10-19): Q3 holds; P1 fails on barnes only

Design: `sync_replay_design_2026-10-18.md` (pre-registered `1b8641c`).
Pulled 2026-10-19 (server 03:17): 8 of 8 programs traced with `-sync 1`,
12 of 12 runs complete on `champsim_sync_06f98fcb` (level 2, shared, LRU).
Rows: `phasea_rows_v21.txt`, `b3_rows_v12.txt` (trees `phaseA_b3_s2_*`).

**The design's rule:** "P1 fails: the records do not hold the threads together
(a missed synchronisation path); found and fixed before anything is scored."
P1 fails on barnes std, so **P2, P3 and P4 are not scored yet.** No B3 ratio
from these runs has been computed or looked at.

## Q3, no deadlock: holds

Every program ran to completion (12 of 12, every run log ends
`ChampSim completed all CPUs`, none reached a trace end). In every thread of
every program, each sync call entered also returned (no `UNBALANCED`). The
thread-0 cuts kept the earlier anchors (barnes std 10,570,006; water
12,952,793; fmm 12,773,531).

## P1, the threads stay together (median spread under 2 M in ocean, canneal, barnes std)

`scripts/heartbeat_drift.py` on the run logs (`--bins` gives the spread per
10 M of the cores' mean position):

| run | before (unsynchronised) | now | P1 |
|---|---|---|---|
| ocean 2 MB | 11.6 M | **0.94 M** | holds |
| ocean 8 MB | 8.1 M | **1.21 M** | holds |
| canneal 4c | 10.7 M | **0.85 M** | holds |
| canneal 8c | 10.8 M | **0.87 M** | holds |
| barnes std, start | 0.4 M | 1.02 M | holds |
| **barnes std, force** | 7.9 M | **6.08 M** | **fails** |
| **barnes std, window** | 7.7 M | **6.96 M** | **fails** |
| radix (reported) | 3.7 M | 0.95 M | -- |
| water-nsquared (reported) | 9.5 M | 6.36 M | -- |
| fmm (reported) | 11.1 M | 15.62 M | -- |
| barnes-256 (reported) | 12.4 M | **24.83 M** (worse) | -- |

## The same spread in gem5 (post hoc, not a prediction)

gem5's per-core committed instructions at its stops (`commitStats0.numInsts`,
first stats block; thread 0's cut subtracted where the traces were cut) set
beside the replay's spread at the same positions:

| program | gem5, at its stops | replay, same positions |
|---|---|---|
| ocean 2 MB | 0.46 M (50 M), 1.92 M (150 M) | 0.47 M (40-50 M), 2.08 M (140-150 M) |
| canneal 4c | 0.58 M, 0.68 M | ~0.6 M, 0.82 M |
| canneal 8c | 0.92 M (150 M) | 1.04 M |
| water-nsquared | 2.14 M, 10.24 M | 3.3-4.3 M, 10.49 M |
| fmm | 14.03 M, 18.44 M | 13.9-15.6 M, 18.28 M |
| radix | 0.22-0.25 M | 1.0-1.3 M |
| **barnes std** | 1.69 M (~38 M), **1.57 M (~88 M)**, 22.8 M (~138 M) | 2.48 M, **6.95 M**, 15.7-23.1 M |
| **barnes-256** | 12.6 M (50 M), **13.2 M (150 M)** | 14.1 M, **30.1 M** |

**On six of eight programs the replay's spread now matches gem5's**, including
water's and fmm's large ones: those programs' threads do unequal work, and
both simulators show it. The "under 2 M" of P1 was a proxy that does not fit
them; they were not in P1.

**The two that do not match are the lock-heavy ones.** barnes-256 has 5.2
lock/unlock pairs per 1,000 instructions, and barnes std about 1.1 (sync
acquires in its runs). In both, the replay's threads move apart where gem5's
stay together.
barnes-256's cores are held at a sync wait on most cycles (99-108 M held
cycles, warm-up included; the counter counts every cycle the dispatch head
waits, even when the core has other work).

## Hypothesis, to test before any fix

**H1, the order is the traced run's:** the replay enforces each mutex's
acquisition order as the Pin run produced it. Under Pin, each thread's speed
was set by instrumentation and by its own xz compressor. A lock order recorded
there carries that run's drift, and the replay reproduces it faithfully. A
barrier order carries no such timing, which would explain why barrier-driven
programs now match gem5 and lock-driven ones do not.

**H2, a missed path:** the replay lets threads run apart that the traced run
held together.

**The test (`scripts/sync_native_all.sh`, read-only, 2026-10-19):** read the
traced run's own spread from the sync records. Every release carries a number
from one counter shared by all threads, a clock of the traced run.
`sync_native_drift.py` gives each thread's position at the same clock, binned
as `heartbeat_drift.py --bins` bins the replay.

- If the traced run's spread in barnes std's force phase is about 7 M, and
  barnes-256's grows toward 30 M, H1 holds. The replay is then faithful to its
  trace, and the fix belongs in what the replay enforces: a mutex is
  exclusive, but its order is decided by the simulated timing, as gem5
  decides it. Barriers, thread creation and condition waits keep their
  recorded dependencies. That is a design change: pre-registered before it
  is built.
- If it is near gem5's (1-2 M), H2 holds: find the path the replay misses.

Tested locally on synthetic traces with a planted 0.30 M offset: it reads
0.29 M (interpolation between releases accounts for the rest).

## The test, run (2026-10-19, server 06:13): H1 holds, H2 is rejected

`scripts/sync_native_all.sh`; output in `simulator/results/sync/native/`.

**Where releases are dense, the replay's spread IS the traced run's, bin by
bin.**

| bin (M) | barnes std: traced | replay | barnes-256: traced | replay |
|---|---|---|---|---|
| 10-20 | 1.02 | 0.87 | 11.31 | 11.12 |
| 30-40 | 1.97 | 2.72 | 13.41 | 13.50 |
| 50-60 | 6.45 | 6.23 | 17.38 | 16.44 |
| 60-70 | 7.35 | 7.38 | 18.47 | 18.61 |
| 80-90 | 6.96 | 7.01 | 22.12 | 22.08 |
| 100-110 | 6.66 | 6.73 | 26.21 | 26.51 |
| 140-150 | 22.99 | 23.11 | 30.08 | 30.13 |

fmm the same: traced 15.3-16.4 M then 18.3-18.7 M, replay 13.2-15.6 then
18.3, gem5 14.0 then 18.4.

**So no synchronisation path is missed.** The records hold the threads
exactly where the traced run had them. In barnes, the traced run's threads
were 7 M apart in the force phase (gem5: 1.6 M), and barnes-256's grew to
30 M (gem5: 13 M). The replay enforces each mutex's order as that run took
it, and with it that run's relative progress. In barnes std about 45,000
acquires per thread wait on another thread's release, one every ~4,800
instructions, which is enough to pin the interleaving.

**The barrier-driven programs agree in all three places.** At the barrier
arrivals themselves (each thread's k-th release in canneal, where every
release is a barrier arrival and four consecutive clock values make one
generation):

| | traced run, at barriers | replay | gem5 |
|---|---|---|---|
| canneal 4c | 0.19-1.00 M | 0.6-1.0 M | 0.58-0.68 M |
| canneal 8c | 0.30-1.14 M | ~1.0 M | 0.92 M |
| radix | 0.14-0.16 M | ~1 M | 0.22-0.25 M |
| ocean | 0.32-0.39 M, then 1.25-1.35 M | 0.5-2 M | 0.46 -> 1.92 M |
| water | grows 2.0 -> 12.3 M | -> 10.5 M | -> 10.2 M |

(ocean's and water's rows are the clock-consecutive ones of a thinned file,
not every generation.)

**An error of mine in the first output, corrected:** the "interpolated"
column read canneal 7-8 M, radix up to 34 M and water up to 27 M. Between
barriers the shared clock barely ticks, and interpolating each thread's
position across a whole phase invents spread. A second attempt (any N
consecutive releases from N threads) was also wrong: it can join the last
arrivals of one barrier with the first of the next. `sync_native_drift.py`
now also measures at barriers, from the departure records. A departure is a
run of N-1 acquires naming the other arrivals of its generation, so the
generation is exact. On synthetic traces with a known imbalance of 3,000
instructions a phase, it reads every generation exactly: 40 of 40 found,
median 0.06 M, max 0.12 M; the locks between barriers are not taken for
barriers. Rerunning the command re-measures every program with it
(optional; the conclusions above do not depend on it).

## What follows

The replay is faithful to its trace. For barrier-driven programs that is
also faithful to gem5. For lock-heavy ones it freezes one run's lock order,
taken under Pin, where an execution-driven simulator lets its own timing
decide who takes a lock next. The fix stated in advance for H1: **a mutex
is exclusive, but its order is decided by the simulated timing.** Barriers,
thread creation and condition waits keep their recorded dependencies. The
tracer must record each mutex's address, so every program is re-traced. It
is pre-registered before it is built.

**The rule, and the owner's decision.** The pre-registered rule holds back
all scoring until the P1 failure is "found and fixed". Found: no missed
path. Fixed: only once the mutex change is built. Whether ocean (P2), canneal
(P3) and radix (P4) are scored now on these runs is the owner's decision. In
those programs the replay matches both the traced run and gem5. No B3 ratio
from the s2 runs has been looked at.

## Found later the same day: the s2 traces carry no condition-variable records

The 2026-10-18 tracer hooked an old, unused version of glibc's
`pthread_cond_*` functions (two versions at different addresses; Pin names
both plainly), so condition waits and signals were never recorded. Found by
`mutex_micro.c`'s `mx_condbar` while checking the mutex change; fixed in the
tracer (`sync_mutex_design_2026-10-19.md`, local results). Mutexes, barriers
and thread creation were recorded correctly. Every program is re-traced with
the fixed tracer for the m2 runs, and its per-call report shows which of them
use condition variables.

## Noted for the scoring, whenever it happens

ChampSim counts a sync record as an instruction, and the traced run did not.
Per 1,000 instructions this dilutes by the sync records' share: barnes-256
about 1.0% (2.2 M of 215 M per thread), barnes std 0.2%, fmm up to 0.1%, the
others less than 0.01%. The scoring should state it, or subtract it.
