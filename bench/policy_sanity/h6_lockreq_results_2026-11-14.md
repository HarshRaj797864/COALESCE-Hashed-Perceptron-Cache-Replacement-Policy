# H6(a): why an F-C lock-word request adds about 0.56 gem5-rule events. Results, 2026-11-14

- **Note:** `h6_lockreq_design_2026-11-14.md` (`364220e`). Its amendment 1
  (`3752bed`) was written after QI2 failed and before any class was read.
- **Run:** barnes std start on `champsim_fc_a2e88e46` with
  `COHERENCE_EVENT_LOG`, ended 2026-11-14 14:49:26 server time. Pulled to
  `simulator/results/h6/`: `run.log`, `pairs.txt`, `events.log.xz` (5.8 MB),
  the server's `summary.txt`, and `summary_amend1.txt` (the classification
  rerun on the laptop under amendment 1).
- **Records only.** Nothing about the tool changes.

## Checks

- **QE0 HOLDS:** the run's log equals the F-C rerun's, 2,127 lines, with the
  times masked.
- **Pairs:** 831 (ip, mutex line) pairs from the four traces' ACQUIRE
  records (first 45 M records each): 2 call sites, 824 mutex lines.
- **QI1 HOLDS:** identified request events against measured requests:

  | | CPU 0 | CPU 1 | CPU 2 | CPU 3 |
  |---|---|---|---|---|
  | identified events | 4,355 | 4,549 | 4,320 | 4,405 |
  | measured requests | 8,162 | 8,393 | 13,842 | 13,849 |

- **QI2 FAILED as written, then HELD under amendment 1.**
  - 1,033 measured S events carried a request pair. An S is a stale fill
    (`cache.cc:139`), not an access.
  - All 1,033 are RFO fills: 737 follow their own request's G, and 296 are
    L1D fills of requests that hit their own L2C.
  - The amendment keeps QI2's purpose: no L or W event, and no S of another
    access type, carries a pair.
  - **Disclosed:** the G / U split of the identified events (16,797 / 832)
    was printed during that diagnosis, before the amendment.

## The classes (44,246 measured requests)

| class | requests | share | meaning |
|---|---|---|---|
| R0 | 26,617 | 60.2% | no event: the request stayed in the waiter's private caches |
| R1 | 225 | 0.5% | an event with nobody listed |
| R2 | 0 | 0.0% | listed by the protocol view, forgotten by the gem5 rule |
| R3G | 16,572 | 37.5% | an event at the LLC (counts in C) |
| R3U | 832 | 1.9% | an upgrade event (counts in U, not in C) |

- R3 by the number of other cores listed: 1 core 16,208; 2 cores 1,189;
  3 cores 7.
- **Take-backs** (the next G or U on the line by another core). Every one
  lists the waiter:

  | class | located | lists the waiter | gap q1 / median / q3 (cycles) |
  |---|---|---|---|
  | R1 | 225 of 225 | 100% | 137 / 219 / 433 |
  | R3G | 16,572 of 16,572 | 100% | 20 / 29 / 46 |
  | R3U | 832 of 832 | 100% | 26 / 32 / 38 |

## Readings (fixed in the note)

- **Leading cause: R0.** It is 26,617 of the 27,674 requests that add
  nothing to C (96%). That is more than the half the rule needs.
- **SUPPORTED: "the request goes out before the holder has taken the lock
  word."**
  - R0 + R1 are 26,842 of 27,674. The rule needs at least half.
  - All 225 of R1's take-backs list the waiter. The rule needs at least
    half.
- **Not supported:**
  - "the request's event is an upgrade": R3U is 832;
  - "the holder's copy was already dropped": R2 is 0.
- **R3G is 37.5% of the requests**, under the 0.9 that would put the
  shortfall in displaced events.
- **Decomposition** of C_F-C - C_before = 24,935:
  - 16,572 are the requests' own events (R3G), 0.375 a request;
  - the other +8,363 (0.189 a request) are events elsewhere in C,
    consistent with the take-backs, each of which lists the waiter.
  - Together they make the 0.564.

## What it means

- F-C issues its request on the waiter's first contended cycle. A record's
  grant happens at dispatch (`mutex_take`), but the holder's own lock store
  reaches memory later. **In 60% of the requests the waiter still holds the
  lock word when its request goes out**, so the request finds nothing to
  take: no event.
- Where the request does find the holder (37.5%), the expected pair
  appears: the request's own event, then the holder's take-back about 29
  cycles later, listing the waiter.
- So the shortfall from the predicted 1-2 events a request is a property of
  F-C's issue point, as the note anticipated. It is not a defect of the
  gem5-rule view (R2 = 0).
- **Nothing is decided about the tool.** The paper states barnes std
  start's R_g5 0.449 as an open under-count, with this cause. A change to
  F-C's issue point (for example, issuing when the holder's store is
  performed) would need its own note and the 20-Nov rule of
  `lock_fix_design_2026-11-12.md`.
