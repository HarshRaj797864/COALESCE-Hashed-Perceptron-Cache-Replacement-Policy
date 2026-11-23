# Prefetchers under sharing: a smoke test (pre-registration, 2026-11-23)

Written and committed before the run.

## Why

- **What the draft claims:** "every ChampSim policy and prefetcher runs
  under sharing unchanged" (Cost and Limitations, Speed).
- **No run so far has used a prefetcher.** `make_config.py` sets
  `"prefetcher": "no"` at L1D, L2C and the LLC in every config. The exact
  coherence suite, the B3 runs and step 5 all ran without one.
- **So prefetch fills into coherent private caches are an untested path:**
  - a prefetched copy of a line that another core owns;
  - a prefetch that merges with a demand miss.
  - A reviewer can ask about them. The sentence stands only if a run
    exercises that path and keeps the directory's invariants.

## What runs (laptop, minutes)

- **Binary:** the local `simulator/bin/champsim`, built 2026-11-18 from C's
  tree. That is F-C plus C's records-only load counter. It prints `SYNC LOCK
  WORD` and C's `LOAD GEM5-RULE OWNER EVENTS` lines.
- **Traces:** `traces/sync_mx/canneal4/raw{1..4}` (synchronized, 4 threads).
- **Config:** `make_config.py --policy lru --cores 4 --regime shared
  --private-coherence 2 --sync-lock-word request`. Warmup 1 M, then 3 M per
  core.
- **Two runs:**
  - **NP:** as generated (no prefetcher).
  - **PF:** the same, with `next_line` at L1D and `ip_stride` at L2C. These
    are upstream's modules as shipped.

## Checks and reading (fixed now)

- **PS1:** both runs complete, with no SYNC DEADLOCK and no end of trace.
- **PS2:** in PF, L1D and L2C each report prefetches issued > 0 and useful
  prefetches > 0, so the prefetchers ran and their fills were used.
- **PS3:** in both runs, summed over every cache, these all read 0:
  - `COHERENCE DIR SELF-CHECK MISMATCHES`;
  - `STALE-HOLDER VIOLATIONS`;
  - `VIEW-ORDER VIOLATIONS UNEXPLAINED`.
- **Reported, not judged:** PF's and NP's store-time gem5-rule events and
  cycles.
- **If PS1-PS3 hold:** the draft may say that a run with ChampSim's
  `next_line` and `ip_stride` prefetchers keeps every coherence invariant.
  It still says that no result uses a prefetcher.
- **If PS3 fails in PF only:**
  - The sentence about prefetchers is removed.
  - The paper states that prefetchers are not supported under coherence
    yet.
  - A diagnosis follows, in its own note.
  - Nothing already scored changes, since no scored run used a prefetcher.
- **If PS1 or PS2 fails:** reported. The test is redone only after the
  cause is understood.

## Result (2026-11-23): PS1, PS2 and PS3 hold

- **Setup:**
  - Binary `simulator/bin/champsim`, md5 `f304e2eb2cc9…`.
  - Window 1 M + 3 M a core.
  - Logs: scratchpad `pfsmoke/{np,pf}.log`, not kept. The numbers are below.
- **PS1:** both runs complete. Each has 0 SYNC DEADLOCK, 0 end of trace,
  and prints `SYNC LOCK WORD: request`.
- **PS2:** in PF, every core's L1D and L2C issued prefetches and had useful
  ones.

  | Cache | Issued | Useful | Cores with 0 |
  |---|---|---|---|
  | L1D (`next_line`) | 1,463,868 | 5,297 | 0 of 4 |
  | L2C (`ip_stride`) | 1,113 | 8 | 0 of 4 |

  NP issued 0.
- **PS3:** in both runs, summed over the 25 cache lines of the ROI block,
  `SELF-CHECK MISMATCHES`, `STALE-HOLDER VIOLATIONS` and `VIEW-ORDER
  VIOLATIONS UNEXPLAINED` are each 0.
- **Reported:**

  | | NP | PF |
  |---|---|---|
  | RFO gem5-rule events | 2,553 | 1,990 |
  | Upgrade gem5-rule events | 12 | 16 |
  | Stale fills dropped | 4 | 0 |
  | Slowest core, cycles | 6,509,436 | 6,476,616 |

- **Reading, as fixed:** the draft may say that a run with upstream's
  `next_line` and `ip_stride` prefetchers keeps every coherence invariant.
  It also says that no result uses a prefetcher.
- **What this does not show:** whether prefetch traffic is modelled as gem5
  would model it. No gem5 comparison with prefetchers was made.
