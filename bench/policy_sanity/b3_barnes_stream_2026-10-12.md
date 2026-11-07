# B3, barnes: gem5 and the traces did not run the same instruction stream

**2026-10-12.** Found while diagnosing why barnes reads R_b = 4.196 at level 2
(`b3v4_steps23_2026-10-12.md`). This is a diagnosis after the fact. It
pre-registers nothing and scores nothing.

**The finding.** Per 1,000 instructions, the barnes traces execute 2.5× the
read-modify-write instructions that gem5's barnes run executed, and 6.3× the
locked ones. canneal agrees to 0.1% on the same measure. **So no barnes
number so far compares the same program in the two simulators.**

**The cause (found the same evening, section "The cause"):** the traced
BARNES was built with tree leaves of up to 256 bodies. SPLASH-3's source,
and the binary gem5 ran, use 10. That one constant turns a body-cell
computation into a body-body one, and barnes takes a mutex on every
body-body interaction.

## The measurement

`scripts/b3_stream_check.py check trace_mix_v1.txt gem5_mix_v1.txt`, window
50–150 M, per 1,000 instructions:

| | | trace | gem5 | gem5 / trace |
|---|---|---|---|---|
| **canneal** | instructions with a load | 377.73 | 377.19 | 0.999 |
| | with a store | 215.71 | 215.24 | 0.998 |
| | read-modify-write | 11.665 | 11.659 | 1.000 |
| **ocean** (trace: thread 0 only) | with a load | 317.15 | 313.47 | 0.988 |
| | with a store | 65.87 | 72.23 | **1.097** |
| | read-modify-write | 0.046 | 0.053 | 1.14 (0.007 apart) |
| **barnes** | with a load | 319.41 | 321.69 | 1.007 |
| | with a store | 168.14 | 205.34 | **1.221** |
| | read-modify-write | **26.84** | **10.58** | **0.394** |

- **Trace side:** `count_rmw.py` over records 50 M–150 M of each thread, run
  on the server on 2026-10-11 (`trace_mix_v1.txt`).
- **gem5 side:** the Ruby Sequencer's request counts between the 50 M and
  150 M stops (`gem5_mix_v1.txt`, extracted from the pulled `stats.txt`).
  - with a load = `LD + RMW_Read + Locked_RMW_Read`;
  - with a store = `ST + Locked_RMW_Write`;
  - read-modify-write = `RMW_Read + Locked_RMW_Read`.
- The gem5 runs use `TimingSimpleCPU`, which sends every access to Ruby, so
  these count executed instructions. **canneal's agreement on all three
  checks the mapping.**

**barnes, split by kind** (the trace's from a scan of all four traces, by
instruction address):

| per 1,000 instructions | trace | gem5 |
|---|---|---|
| locked read-modify-writes | **10.49** | **1.66** |
| unlocked read-modify-writes | 16.34 | 8.92 |

## What the trace's extra instructions are

**A pthread mutex taken on every body-body interaction.**
- Each thread makes 5.17 lock/unlock pairs per 1,000 instructions, at a
  steady rate from its record 5 M to its last (200 M).
- They fall on about 85 mutexes 40 bytes apart, at 0x5d2deeb078e0 to
  0x5d2deeb08634: an array, 1.6 mutexes to a cache line. All four threads
  use it.
- Each pair is four read-modify-writes: `lock cmpxchg` and `xchg` on the
  lock word, and `nusers++` and `nusers--` twelve bytes on.
- The source says where. SPLASH-3's `gravsub` (`grav.c.in:61-67`) locks
  `CellLock->CL[parent->seqnum % MAXLOCK]` around one read of the other
  body's position, unless it is compiled with `-DWITH_NO_OPTIONAL_LOCKS`.
- The counts fit: thread 1 makes 1,034,778 pairs in 200 M instructions and
  1,005,220 body-body interactions (the `myn2bterm++` instruction).

## The cause: the traced BARNES has 256-body leaves

**Both binaries contain the lock.** `scripts/check_barnes_build.sh` on the
server (2026-10-12) shows one call to `pthread_mutex_lock` in `gravsub` in
the traced binary (built 2026-06-12) and in the static one (2026-10-05),
and no `WITH_NO_OPTIONAL_LOCKS` anywhere. My first reading, that gem5's
binary lacked the lock, was wrong.

**What differs is how often the lock is reached.** `gravsub` locks only for
a body-body interaction (`p != pmem`); a body-cell interaction takes none.

| per thread | body-body | body-cell | source |
|---|---|---|---|
| the trace, records 50-150 M | 512,415 (every one after a lock) | 87,967 | the two counter instructions in thread 1's trace |
| standard barnes, one whole step | 77-85 thousand | 0.79-0.98 million | a native run of the same source and input on the laptop |
| barnes with `MAX_BODIES_PER_LEAF 256`, one whole step | 2.4-3.9 million | 0.50-0.61 million | the same, with that one constant changed |

**The trace's leaves are 2,216 bytes and hold up to 252 bodies.**
- In 8 M records of thread 1, bodies' `parent` pointers name 38 leaves,
  spaced by multiples of 2,216 bytes, with 66 bodies each on average and
  252 at most.
- SPLASH-3's leaf is 248 bytes with `MAX_BODIES_PER_LEAF 10`: 168 bytes and
  8 per body. **168 + 8 × 256 = 2,216.**
- The body is 128 bytes in both, and the trace's bodies span 2,047 KB, so
  the body count is the same 16,384.

**gem5's counts are the standard program's.** Per thread and step it
executed 1.235 M unlocked and 0.279 M locked read-modify-writes. A native
standard run makes 0.96 M interactions and 0.08 M of them body-body: with
the tree build's locks, about 0.14 M lock pairs, which gives 0.96 + 2 × 0.14
= 1.24 M unlocked and 0.28 M locked.

**So the traces are of a different computation.**
- About 9× the standard run's body-body interactions per instruction (5.1
  per 1,000 against 0.6), and 30 to 46× per step, each with a mutex.
- A step about 4× as long: the trace's 200 M instructions per thread end a
  third of the way through the first force phase. There is no barrier after
  record 4.8 M.
- **Every ChampSim result labelled "barnes" is of this program,** including
  the Phase A rows, not only B3's.

**Confirmed from the binaries on the server (2026-10-13,
`barnes256_gem5.sh`):** the traced binary's `loadtree` compares a leaf's
body count with 0x100 and `SubdivideLeaf` reserves 0x858 bytes; the static
binary gem5 ran compares with 0xa and reserves 0xb8.

**Not known:** why the June build used 256. The server's source now builds
the standard program (the static binary is one).

**The instruction-count comparison could not see it.** A constant changes
immediates, not the number of instructions: `gravsub` is the same size in
both. `check_barnes_build.sh` now compares each function's constants and
reads the leaf size from `SubdivideLeaf`'s stack frame (0xb8 for 10, 0x868
for 256); tested on local builds of both.

**ocean is not identical either.** Thread 0's store rate is 9.7% below
gem5's, whose four cores all read 72.2. Loads agree to 1.2%. Its two
binaries have the same instruction counts in 20 of 21 functions; their
constants are compared by the same script. Only one of ocean's four traces
was counted.

## What ChampSim's barnes hand-overs are

From the event log added in `9eb1067` (records only, off by default), read
with `scripts/coherence_events.py`, on the laptop's copies of the traces.

**The full window at level 2** (50 M + 100 M, LRU, 4 cores, shared). The
laptop run reproduces the server's row exactly: 189,125 protocol events,
209,018 upgrades, 59,753 stale fills, 734,381 copies invalidated.
- **98.6% of the 398,143 ownership hand-overs fall on the 47 cache lines of
  the mutex array.** Four lines take 72%.
- **An instruction that takes a line and has to take it again is rare:**
  395,518 instructions had a hand-over and 2,625 of them had two (1.007 per
  instruction).
- 45.6% are a store hitting a copy another core is listed for (an upgrade
  in the L1D), 47.5% a store miss at the shared cache.
- Of the 59,753 stale fills dropped, 45,863 are plain loads.

**Re-aligning thread 0** (its serial start removed) changes little: 196,349
protocol events and 214,294 upgrades, +3.8% and +2.5%.

**An ideal directory over the mutex array alone**, driven straight from the
four traces (no caches, no timing, zero latency), counts 640-680 thousand
hand-overs in the window, 1.7 times ChampSim's.
- It moves by under 3% when thread 0 is re-aligned, when one thread is
  shifted by 1,000 to 5,000,000 instructions, and when the threads run at
  different relative rates.

## Corrections to what I wrote this morning

`b3v4_steps23_2026-10-12.md` said the barnes rows "point at" a
read-modify-write that is not atomic. **That is not supported.**
- A core asking twice for one instruction accounts for 0.7% of hand-overs
  in the window.
- 77% of the stale fills dropped are plain loads, not read-modify-writes.

A second idea, tested and dropped: **thread 0's trace starts 10,567,500
instructions before the others'**, because it carries the program's serial
start (its first lock operation is at record 10,594,075; the others' are
near 26,500). ChampSim therefore runs thread 0 that far behind the others.
The ideal directory shows this does not change the lock hand-overs.

## What this voids, and what it does not

**Void until the reference runs the traced program: every barnes verdict.**
- B3 v2: R_b 0.001, traffic 0.63.
- Step 1: R_b 0.001 ("still fails, as predicted").
- Level 1: R_b 0.057 (P3 "holds").
- Level 2: R_b 4.196 and U 3.368 (P4 and P5 "fail"), traffic 1.84.

Each divided a rate from the 256-body-leaf program by a rate from the
standard one. They are neither failures nor passes.

**Not touched:**
- **canneal:** the same stream to 0.1%. Its results stand.
- **The rule that started the A5 rerun:** it used ocean and canneal only.
- **The simulator:** nothing here shows a defect in it. Every exact count
  and self-check still holds.

**Weakened, and to be closed:**
- **ocean:** agreement on R_b (0.99 / 1.13 at level 2) stands as measured,
  with a caveat until its two binaries are compared: a ~10% difference in
  store rate on the one thread counted.
- **The design's reason for step 3** cited gem5's barnes counters (61,777
  upgrades against 44,867 store misses). Those are the standard program's
  and are still true of it. The mechanism is exact on the hand-computed
  cases and moves ocean toward 1.
- **Every policy result on "barnes"** (Phase A) is a result on the
  256-body-leaf program. It stands as a measurement and is mislabelled.

## Next

Two ways to give the two simulators the same program. They are not
alternatives.

1. **Trace the standard barnes** (the server's current source), aligned at
   the start of the parallel section, and run ChampSim on it at levels 0, 1
   and 2. gem5's existing runs are its reference. **This is the one the
   papers need:** a benchmark as its authors ship it.
2. **Run gem5 on a 256-body-leaf build,** as a second, lock-heavy point. The
   ChampSim rows for it exist already.

Both get a pre-registration before anything is read, and
`b3_stream_check.py` must pass for each before it is scored. Neither uses
`bin/champsim`, so both can be prepared beside the A5 rerun.

3. **Close ocean:** count all four ocean traces, and read the constants
   comparison for OCEAN.
4. **The owner decides** whether the Phase A barnes rows are rerun on the
   standard traces or dropped. A5 does not use barnes.
