# B3 v4 — coherent private caches (steps 2 and 3): pre-registered

**2026-10-11.** Written and committed **before** the change is built or run.
The owner chose on 2026-10-07 to fix ChampSim step by step, each step
validated against the existing gem5 runs. Step 1 is scored
(`b3v3_step1_2026-10-09.md`); the verification pass before this one is
`verification_2026-10-11.md`.

## Why two steps, not one

barnes still reads R_b = 0.001. The plan named one step: invalidate other
cores' private copies when a core takes a line. gem5's own counters say
that is half of it. In the 50–150 M window:

| | `(SS+MT).L1_GETX` — a store that **missed** its private caches | `SS.L1_UPGRADE` — a store that **hit** a shared copy |
|---|---|---|
| ocean 2 MB / 8 MB | 27,649 / 26,451 | 41,899 / 67,195 |
| canneal 2 MB / 8 MB | 89,307 / 98,861 | 580 / 659 |
| barnes 2 MB | 44,867 | 61,777 |

A pthread mutex shows why. `pthread_mutex_lock` first reads the mutex's kind
with a plain load, then takes it with `lock cmpxchg`, on the same line. The
load fetches the line shared; the locked instruction then **hits** it. A real
protocol makes that hit an upgrade, which invalidates the previous holder.
ChampSim lets the hit through, and the previous holder keeps its copy. So
invalidating only on store misses would stop after one hand-over.

## The change: one setting, three values

`private_coherence` in the run config (`make_config.py --private-coherence
N`), printed in every log:

- **0** — the step-1 simulator. Nothing below runs.
- **1 (step 2)** — **an ownership request accepted at the shared cache
  invalidates every other core's private copies of that line** (L1I, L1D,
  L2C). An ownership request is an RFO: a store that missed, or a
  read-modify-write's load (step 1).
- **2 (step 3)** — level 1, plus: **a store or RFO that hits a private copy
  takes the line too, when the directory lists another core** (its protocol
  view) or another core's private caches hold it. The others' copies are
  invalidated and the hitter becomes the sole listed owner. This is the
  upgrade. It is detected in the L1D (a store, or a read-modify-write's
  load) and in the L2C (an RFO that missed the L1D).

**The stale-fill rule, at levels 1 and 2.** A copy can be in flight to a core
when another core takes the line. So the directory marks every other core
stale for the line at each ownership grant, and clears a core's mark when a
request of its own for that line is next accepted at the shared cache. A fill
arriving in a private cache for a stale core completes its instruction and
leaves no copy.

**Counters added** (all zero at level 0):
- private copies invalidated, per private cache;
- upgrade events and the cores they found, per private cache (protocol view,
  and separately by presence);
- stale fills dropped, per private cache;
- at the shared cache, a check that must read 0: lines some core both holds
  and is marked stale for.

The existing counters keep their definitions. R_b's numerator is unchanged:
RFOs accepted at the shared cache that find another core in the protocol
view.

## What it does not model — disclosed, not tuned

- **No added latency.** An invalidation or an upgrade takes effect at once.
  PLAN § 11 rules out a network model; a fixed directory latency could be
  added later.
- **A read-modify-write is not atomic.** Its load takes the line, and its
  store writes at retirement. If another core takes the line in between, the
  store misses and asks again. gem5 locks the line for both halves.
- **An invalidated dirty copy is dropped**, with no writeback: the new owner
  holds the newer data.
- **A writeback already in flight** from a core that has just lost the line
  still reaches the shared cache.
- **A clean copy leaves a private cache silently**, so the directory keeps
  its core listed. For a shared copy gem5 does the same. For an exclusive
  clean copy gem5 notifies the directory, and ChampSim does not. This
  over-lists, and is a candidate for R_b above 1.
- **The shared cache's own per-line sharer mask and MESI state are
  untouched.** They follow the older rules (an RFO adds a sharer; only a
  writeback makes a sole owner). COALESCE and `srrip_bias` read them. Whether
  to align them is a separate decision, after this.

## Tests first

`check_coherence_exact.sh` runs every case at each level, with hand-computed
counts. Columns: the eight existing ones, then upgrade events, upgrade
cores, copies invalidated.

| case | level 0 | level 1 | level 2 |
|---|---|---|---|
| `order`, shared | `100 200 100 200 100 150 100 0 · 0 0 0` | `100 200 100 150 100 150 100 0 · 0 0 300` | as level 1 |
| `order`, private | `0 0 0 0 0 0 100 0 · 0 0 0` | same | same |
| `pingpong` | `50 50 50 50 50 50 200 0 · 0 0 0` | **`150 150 150 150 150 150 200 0 · 0 0 300`** | as level 1 |
| `upgrade` (new) | `0 0 0 0 0 0 100 0 · 0 0 0` | same | `0 0 0 0 0 0 100 0 · 100 100 200` |
| `upgrade_l2` (new) | `0 0 0 0 0 0 50 0 · 0 0 0` | same | `0 0 0 0 0 0 50 0 · 50 50 100` |
| `forward` | `0 0 0 0 0 0 50 50 · 0 0 0` | same | same |
| `wb_control` | `- - 8 8 8 8 16 0 · 0 0 0` | `- - 8 8 8 8 16 0 · 0 0 16` | as level 1 |
| `wb_evict` | `- - 0 0 0 0 16 0 · 0 0 0` | same | same |

- `upgrade`: A loads X, B loads X, A read-modify-writes X, B loads X, A
  read-modify-writes X. At level 2 each of A's two hits finds B listed.
- `upgrade_l2`: A loads X, B loads X, A loads ten other lines of X's L1D
  set, A read-modify-writes X. X is then in A's L2C only, so the upgrade is
  detected there.
- `storm` (new): all four cores read-modify-write the same line at the same
  instruction, 50 times. Its counts depend on cycle-level ordering, so it
  asserts only what must hold: the run completes; the self-check and the
  stale-holder check read 0; protocol events are at least 3 a round; stale
  fills are 0 at level 0 and above 0 at levels 1 and 2.

Every case also asserts self-check 0, 12 registered, the stale-holder check
0, no wrapped trace.

## Runs

ChampSim, LRU, 4 cores, both regimes, one binary:

| trees | level | configurations |
|---|---|---|
| `b3_v4_*` | 1 | ocean fixed and scaled, canneal fixed and scaled, barnes fixed |
| `b3_v5_*` | 2 | the same five |
| `b3_v4l0_*` | 0 | canneal fixed, barnes fixed (the control) |

gem5: the existing runs, unchanged. Same window (50–150 M), same arithmetic
(`scripts/b3_score.py`).

A new measure at level 2: **U** = ChampSim upgrade events (protocol view) per
KI over gem5 `SS.L1_UPGRADE` per KI, in the same window.

## Pre-registered predictions

**Qualifying. If any fails, nothing is scored until it is explained.**
- **Q0 — level 0 is the step-1 simulator.** The control rows equal their
  `b3_v3` rows in every column.
- **Q1 — the private regime is untouched.** Every private-regime row at
  levels 1 and 2 equals its `b3_v3` row in every existing column, and every
  new counter reads 0 there. No line has two cores in that regime.
- **Q2 —** self-check 0, 12 registered, stale-holder check 0, in every row;
  the trees pass `analyze_rows.py check`; no trace wraps.

**Level 1 (step 2).**
- **P1 — ocean stays in agreement:** 0.5 ≤ R_b ≤ 2 at both sizes. Expected
  to move up by no more than 15%: when an RFO arrives, another core holds a
  private copy in only 6% (2 MB) and 15% (8 MB) of the events counted now.
- **P2 — canneal stays in agreement:** 0.5 ≤ R_b ≤ 2 at both sizes, and its
  ownership-request stream stays within [0.95, 1.10] of gem5's (0.997 /
  1.001 now). Expected to move up by under 10%.
- **P3 — barnes does not yet agree: R_b < 0.5.** Its hand-overs are a load
  and then an upgrade, which level 1 does not model.

**Level 2 (step 3).**
- **P4 — barnes agrees (the target): 0.5 ≤ R_b ≤ 2.** Its window is not
  steady (gem5's three spans differ 6.7×), so the verdict is also stated
  against each span, as before.
- **P5 — upgrades match where gem5 has enough to score:** 0.5 ≤ U ≤ 2 for
  ocean at both sizes and for barnes. canneal has under 700 in the window,
  so its count is reported and expected small: under 0.02 per KI.
- **P6 — ocean stays in agreement:** 0.5 ≤ R_b ≤ 2 at both sizes. Expected at
  or below its level-1 value: an upgrade leaves the upgrader the sole listed
  owner, which removes sharers listed only by an old read.
- **P7 — canneal stays in agreement:** 0.5 ≤ R_b ≤ 2 at both sizes, within
  10% of its level-1 value.

**Traffic, both levels:** shared-cache demand accesses stay within 2× of
gem5's on all five. Expected: barnes's ratio (0.63) rises at level 2.

## How each outcome is read

- **Q0, Q1 or Q2 fails:** a defect. Stop and find it.
- **ocean or canneal leaves the band at a level:** that level regresses a
  workload that agreed. It is not adopted.
- **barnes below 0.5 at level 2:** the private caches then pass every exact
  test and barnes still disagrees, so its gap is elsewhere. Candidates: the
  window, which is unsteady and need not line up between a trace and gem5's
  execution; the non-atomic read-modify-write.
- **barnes above 2, or R_b rising further above 1:** over-counting.
  Candidates: the silent clean eviction; a contended read-modify-write
  asking twice.

**Nothing is tuned after R is seen.**

## The A5 rerun, and the rule that starts it

Levels 1 and 2 change timing in the shared regime, so A5's shared side must
be rerun on the level adopted. The server account expires 2026-10-26 and the
rerun takes days, so it is chained to these runs by a rule fixed here.

**It starts by itself if, and only if, at level 2:** Q0, Q1 and Q2 hold, and
ocean and canneal are in the band at both sizes. barnes is reported and does
not gate: A5 is canneal, with ocean as its control, and barnes cannot
separate policies (`a5_crossregime_2026-10-01.md`).

**What it runs:** level 2, shared regime only, fixed 2 MB and scaled:
- the 8 baselines and COALESCE as deployed (variant B);
- canneal at 4, 8 and 16 cores, and ocean at 4.

The private side is not rerun: by Q1 it cannot change.

**It is read only if the owner adopts level 2.** Running it commits to
nothing.
