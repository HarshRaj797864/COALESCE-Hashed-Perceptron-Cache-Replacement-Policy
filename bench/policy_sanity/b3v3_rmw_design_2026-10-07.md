# B3 v3, step 1 — a read-modify-write claims its line: pre-registered

**2026-10-07.** Written and committed **before** the change is built or run.
The owner approved step 1 on 2026-10-07. Step 2, invalidating other cores'
private copies, is separate and comes later.

## Why

B3 v2 on canneal (`b3v2_canneal_barnes_2026-10-07.md`): R_b = 0 at 2 and
8 MB.
- canneal reads every element's location with `lock cmpxchg`
  (`AtomicPtr::Get` → `atomic_load_acq_ptr`).
- gem5 issues a locked RMW as a store coherence request, a GETX: 946,589 in
  the window.
- ChampSim issues the read half as a LOAD; the write half then hits. Its LLC
  saw 175 RFOs.
- Demand traffic matched (1.04 / 1.06). Only the request type was wrong.

## The change

An instruction whose destination memory addresses include one of its source
addresses is a read-modify-write. **Its load is issued to L1D as an RFO, not a
LOAD** (`ooo_cpu.cc`, `execute_load`). Nothing else changes. A per-core
counter records how many loads were issued this way.

**A deliberate approximation.** The ChampSim trace records an instruction's
addresses but not its lock prefix, so locked and unlocked RMWs look the same.
- For a locked RMW, ownership at the read is what gem5 does (the Sequencer)
  and what hardware must do.
- An unlocked RMW (`add [mem], r`) also needs ownership before its write
  completes. Taking it at the read moves the request earlier, but it does
  not add one.

**What it does not change, read from the code.**
- No prefetcher is configured at any level (`make_config.py`).
- The caches treat an RFO exactly as a LOAD for lookup, MSHR, fill and
  timing. The only RFO-specific code is the type of a forwarded WRITE miss
  (`cache.cc:328`), the v1 store-time counter, and the directory's request
  kind.
- At the LLC, the overlay's sharer mask and MESI state are updated the same
  way for both (`cache.cc` hit branch). Only a writeback invalidates.
- LRU ignores the request type except for writebacks.
- **So under LRU, step 1 should relabel requests and change no timing.**

## Runs

- **ChampSim, LRU, both regimes, on the step-1 binary:**
  - ocean 4c, fixed and scaled;
  - canneal 4c, fixed and scaled;
  - barnes 4c, fixed.
  Tags `b3_v3_*`.
- **gem5: the existing B3 runs, unchanged.** Same window, 50–150 M, same
  arithmetic as `b3v2_canneal_barnes_2026-10-07.md`.

## Pre-registered predictions

**P0 — relabelling only (qualifying; if it fails, stop and diagnose).** Every
v3 LRU row matches its v2 row exactly in:
- `max_cycles`, `min_cycles` and instructions;
- LLC total accesses and hits, writebacks, translations;
- aliased fills and invalidations.

Also unchanged: `load_acc + rfo_acc` and `load_hit + rfo_hit`. Only the
split between loads and RFOs may move.

**P1 — canneal's store-miss stream now matches gem5.** ChampSim LLC RFOs per
KI over gem5 L2 `L1_GETX` (all states) per KI, within **[0.5, 2] at 2 MB and
at 8 MB**. It is 0.0002 now.

**P2 — canneal agrees (the primary criterion): 0.5 ≤ R_b ≤ 2 at both
sizes.**
- **Expected below 1.** Step 1 still leaves a core's copy in place after
  another core takes the line. gem5 would invalidate that copy and count
  its next access. Step 2 addresses this.

**P3 — ocean stays in agreement:** R_b within [0.5, 2] at both sizes, and
within ±10% of 1.263 and 1.348. Ocean's sharing is plain store misses, and
it has few RMWs.

**P4 — barnes does not yet agree: R_b < 0.5.** Its gap is the missing
invalidation (step 2), not RMWs.

**Qualifying, as before:**
- the trees pass `analyze_rows.py check`;
- self-check 0 and 12 registered in every row;
- the private regime reads 0 for (a) and (b).

## How each outcome is read

- **P0 fails:** the change does more than relabel. Find out what before
  scoring anything.
- **P1 fails low:** the RMW loads are not reaching the LLC as RFOs, or are
  fewer than gem5's GETX. Diagnose with the per-core counter.
- **P1 holds but P2 fails low:** the request types now match, so the gap is
  the stale private copies. That is step 2's job, and the result is
  reported as such.
- **P3 fails:** step 1 disturbs the workload that agreed. That is a
  regression and must be explained.

**Nothing is tuned after R is seen.** Step 2 gets its own pre-registration.
