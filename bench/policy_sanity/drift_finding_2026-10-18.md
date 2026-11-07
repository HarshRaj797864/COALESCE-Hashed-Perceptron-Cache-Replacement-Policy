# Why ChampSim's replay loses lines gem5 still holds: the threads drift apart (2026-10-18)

Step 2(a/b) of PLAN § 10, answered from data already in hand -- no new run.
Sources: the audit's raw logs (`collect_20261017_115926`, heartbeat lines,
one every 10 M instructions per core) and the C counter's per-100,000-record
mix of every trace (`simulator/results/audit/traces/`).

## 1. The traces start nearly together (alignment is not the cause)

Each thread's store fraction per 100,000 records, cross-correlated against
thread 1's, gives its start offset. Checked on radix, whose traces were
aligned at an anchor: all four at offset 0 (r 1.00). ocean: thread 3 at
+0.1 M (r 0.98); threads 0 and 2 at -0.8 and -1.3 M with weaker fits
(r 0.68, 0.67; their partitions differ). So ocean's starts are within about
a million instructions -- not the 10.57 M serial start barnes had.

## 2. During the run the cores drift 8-19 M instructions apart

From the heartbeats, each core's instruction count at the same cycle, 200
points across each run; the spread between the most and least advanced core:

| run (level 2, shared) | cores apart, median | max | R_b | R_bounded |
|---|---|---|---|---|
| ocean 2 MB | 11.6 M | 19.1 M | 0.986 | **0.091** |
| ocean 8 MB | 8.1 M | 12.0 M | 1.125 | **0.491** |
| canneal 4c | 10.7 M | 11.0 M | 1.263 | 1.022 |
| canneal 8c | 10.8 M | 11.2 M | 1.721 | 1.540 |
| barnes std, force | 7.9 M | 8.1 M | 0.689 | 0.580 |
| barnes std, window | 7.7 M | 8.1 M | 0.492 | 0.366 |
| **barnes std, start** | **0.4 M** | **0.6 M** | 0.761 | **0.795** |
| barnes-256 | 12.4 M | 12.8 M | 0.634 | 0.634 |
| radix | 3.7 M | 6.4 M | 42.96 | 0.878 |
| water-nsquared | 9.5 M | 10.2 M | 1.924 | 1.924 |
| fmm | 11.1 M | 15.2 M | 1.409 | 0.314 |

At one moment of the ocean run the four cores stand at 81.3, 81.7, 64.7 and
70.5 M instructions. They finish their 100 M within 1% of each other in
cycles only because the fast and slow stretches average out. The warm-up
starts the drift: every core must reach 50 M before measurement begins, and
the fast ones run on while they wait.

## 3. Why that loses ocean's lines

A trace replay never waits at a barrier; the program, and gem5, do. ocean
exchanges grid boundaries between neighbours every sweep, with a barrier
between sweeps, so in gem5 a neighbour's store comes within a phase of the
owner's read and the owner still holds the line (`MT`, 99% of gem5's
events). In the replay the two cores are millions of instructions -- many
sweeps -- apart, and the owner's caches have long since dropped the line
(presence 8%, held on chip 9%). The protocol view hides this because it never
forgets. The one span whose cores stay together, barnes's start (0.4 M
apart: it begins at warm-up 0 from aligned traces), is the one where the
bounded view loses nothing (0.795 against 0.761).

## What follows

- **The fix is in the replay, not in a forgetting rule:** threads must wait
  for each other where the program makes them wait. Recording the program's
  synchronisation (lock, unlock, condition wait and wake, barrier) in the
  traces, with its order in the real run, and making ChampSim hold a core
  until the event it depends on has been replayed, is the extension
  ChampSim's authors name as future work ("support for synchronization
  constructs such as locks and barriers ... in a new trace format"). Related
  work to cite: SynchroTrace (Nilakantan et al., ISPASS 2015) does this for
  gem5.
- **Every multi-threaded result so far ran on drifting threads**, the policy
  evaluations (A5, A6, C0) included: the shared cache saw interleavings the
  programs would not produce. After the replay is synchronised, they rerun.
- SPLASH-3's barriers are built (`pthread.m4.stougie`) from a mutex and a
  condition variable, not `pthread_barrier_wait`; the tracer must record
  mutexes and condition variables, not only barrier calls.
