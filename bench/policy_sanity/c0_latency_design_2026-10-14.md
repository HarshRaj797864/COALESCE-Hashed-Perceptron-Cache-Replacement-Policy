# C0, the cost of an invalidation: pre-registered

**2026-10-14.** Written and committed **before** the binary that implements
it has been run on any real trace beyond its equivalence checks, and before
any C0 run exists.

## Why

The tool counts coherence events but charges no time for them: a store that
must take a line from other cores proceeds as if it held the line. So the
cross-regime result rests on where data lives, not on what keeping it
coherent costs. PLAN § 5 names the check: the conclusions under an assumed
invalidation cost of 0, 20, 50 and 100 cycles.

A first-order estimate from the A5 rerun's rows (2026-10-14): at fixed 2 MB,
shared, level 2, coherence events per policy differ by 0.17-0.35% on canneal
(8 and 16 cores), so a fixed cost per event shifts every policy almost
equally. If each event stalled its core for L cycles, one after another, the
fastest-first order could not change below L of about 8,000 cycles at 8
cores. That is a model; this measures it.

## What changes in the simulator

One run setting, `coherence_latency` (cycles), `make_config.py
--coherence-latency L`. It needs `--private-coherence 2`; 0, the default,
leaves the simulator exactly as it was and writes nothing new to the config
or the log.

At L > 0, outside warm-up, a request **waits L cycles before its tag check**
when it must take its line from other cores, in exactly the cases where
level 2 invalidates copies:
- a store miss (RFO) reaching the LLC while the directory lists another core
  or another core's private caches hold the line;
- a store or RFO that hits a private copy under the same condition (the
  upgrade), decided in the cache where it hits.

The waiting request leaves the tag pipeline (as in a directory's transaction
buffer), so the requests behind it go on. Each request waits at most once per
cache. A new counter, `COHERENCE LATENCY WAITS`, printed only when L > 0,
counts the waits.

**Not modelled, disclosed.** ChampSim's core frees a store when it is issued
to the L1D at retirement and expects no response, so a plain store's wait
costs its core nothing directly; the cost reaches timing through
read-modify-writes (issued as RFOs and waited for, as canneal's locked
instructions are), through later accesses to the line, and through queue
occupancy. A real store buffer that fills would stall. So C0 measures a lower
bound on the cost of coherence. The wait is the same for every request; no
network or directory contention is modelled (none is in scope: PLAN § 11).

## Qualifying checks

- **Q0, nothing changes at 0:** the new binary at L = 0 prints logs
  byte-identical (wall-clock lines aside) to `champsim_b3v4_69ebdcce` on
  canneal 4c and barnes 4c, shared and private, levels 0 and 2. Then the A5
  rerun's `phaseA_l2_fixed` rows stand as the L = 0 rows.
- **Q1, the existing exact tests:** `check_coherence_exact.sh` passes at
  levels 0, 1, 2 on the new binary, and the three policy guards pass.
- **Q2, the wait happens where it should:** at L = 50 on canneal 4c (LRU,
  shared, short run), the waits counter is non-zero and of the order of the
  store misses that find another core plus the upgrades (within 2× of their
  sum; the two are counted at different moments, so they need not be equal);
  `max_cycles` is at least the L = 0 value. At level 2 with L = 50 in the
  private regime, the waits counter reads 0.
- **Q3:** every run complete, no trace wrapped, self-check 0, stale-holders 0,
  the log printing the latency.

## The runs

The new binary, frozen as `champsim_c0_<hash>`, built in its own tree so
`bin/champsim` is not touched. Shared regime, fixed 2 MB, level 2, the 8
baselines, 50 M + 100 M, L = 20, 50 and 100 cycles:
canneal 4c and 8c, and ocean 4c. 72 runs (about 290 CPU-hours). L = 0 is the
A5 rerun's rows, by Q0.

## Predictions

- **P1, the order holds:** at every L ≤ 100, for canneal 4c and 8c and ocean
  4c, Kendall τ between the order at L and the order at 0 is at least +0.86
  (at most one swapped pair among the 8).
- **P2, the cost is small and nearly uniform:** at L = 100, LRU's `max_cycles`
  rises by less than the serial estimate (events per core × L), and the
  spread of the rise across the 8 policies is under 1 percentage point.
- **P3:** `max_cycles` does not fall as L rises, for LRU, in any configuration.

## How each outcome is read

- **P1 holds:** the shared-regime rankings do not depend on charging no time
  for invalidations, up to 100 cycles each, as a lower bound. The paper states
  this with the store-buffer limit.
- **P1 fails:** the cost of coherence reorders the policies; a ranking study
  on the tool needs a latency, and the paper says which pairs move and at
  which L.
- **P3 fails:** reported as a timing anomaly with its size; it does not void
  P1.

Nothing is tuned after a τ is seen.
