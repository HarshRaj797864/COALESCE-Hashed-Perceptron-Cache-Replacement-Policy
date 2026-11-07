# Validation round: one program with known answers, through both simulators. Pre-registered

**2026-10-17.** Written and committed before any gem5 run of this program
exists. Part of the full validation round (`validation_round_2026-10-17.md`).

## Why

Every B3 verdict compares ChampSim's "store misses that find another core"
(protocol view, per 1,000 instructions) with gem5's `(SS + MT).L1_GETX` at its
shared L2, and ChampSim's upgrades with gem5's `SS.L1_UPGRADE`. That the two
count the same event has been argued from the protocol's source
(`phaseB_metric_semantics_2026-09-23.md`) and supported by agreement on real
programs, but never tested on a program whose answer is known. radix's 43x
over-count makes the question concrete: which reader does each simulator
remember, and for how long?

## The program

`bench/coherence_micro.c`: four threads (thread 0 works, as in SPLASH) run a
fixed schedule of steps on a fresh line X_j per round, with long waits between
steps so the order is set by the schedule. A small hierarchy, the same in both
simulators: L1D 2 KB (4 sets x 8 ways), L1I 32 KB, private L2 8 KB (16 x 8),
shared cache 256 KB (256 x 16). 4 rounds per case (each thread takes each role
once), and a control run with 0 rounds; counts are the run minus the control.

- gem5 (server): MESI_Three_Level, TimingSimpleCPU, the static binary built
  with `-DM5OPS`: thread 0 resets the statistics at its start mark and dumps
  them at its end mark. Counted from that dump: `SS.L1_GETX + MT.L1_GETX`
  ("GETX-o") and `SS.L1_UPGRADE` ("UPG").
- ChampSim (laptop): the dynamic binary traced with Pin, each trace cut at
  its thread's start mark (`bench/micro_trim.py`), level 0 and level 2, LRU,
  shared regime, warm-up 0. Counted: protocol-view events (P), presence-view
  events (A), bounded-view events (B), upgrade events (U); and, from the
  per-request event log, the same events restricted to the X lines, which
  removes any noise.

## Hand counts, per round (x 4 rounds)

| case | what happens to X_j | gem5 GETX-o | gem5 UPG | ChampSim L2: P | A | B | U |
|---|---|---|---|---|---|---|---|
| pp_lock | A, B, A, B locked increment | 3 | 0 | 3 | 3 | 3 | 0 |
| pp_store | A, B, A, B store | 3 | 0 | 3 | 3 | 3 | 0 |
| pp_rmw | A, B, A, B plain `add [mem]` | 3 or 0 (amended: measured) | 0 or 3 | 3 | 3 | 3 | 0 |
| readers | A, B, C load; D stores | 1 | 0 | 1 | 1 | 1 | 0 |
| upgrade | A, B load; A stores | 0 | 1 | 0 | 0 | 0 | 1 |
| ctl | A loads; B stores | 1 | 0 | 1 | 1 | 1 | 0 |
| priv_E | A loads; every core flushes its private caches; B stores | measured | 0 | 1 | 0 | 1 | 0 |
| priv_S | A, C load; flush; B stores | measured | 0 | 1 | 0 | 1 | 0 |
| llc_out | A loads; B, C, D push X_j out of the shared cache; B stores | **0** (inclusive L2: A's copy is invalidated with it) | 0 | 1 | 1 | 1 | 0 |
| offchip | A loads; everyone sweeps (X_j held nowhere); B stores | **0** | 0 | 1 | 0 | **0** | 0 |

ChampSim at level 0: pp_* read 1 a round (the second and fourth turns hit
stale private copies), upgrade 0; the rest as at level 2.

Why pp_rmw differs: a plain read-modify-write's load is a load in gem5 (GETS,
then an upgrade for its store), while ChampSim cannot tell a locked RMW from a
plain one in the trace and issues every RMW's load as an RFO (step 1). The two
then file the same hand-over under different counters. The hand-overs (GETX-o +
UPG against P + U) agree.

**Amended 2026-10-17, before any gem5 run of this program:** the paragraph
above is probably wrong about gem5. As I recall gem5's Ruby sequencer, an x86
load carrying the StoreCheck flag -- the load of a plain read-modify-write --
is recorded as `RMW_Read` but handed to the protocol as a **store** (secondary
type ST), so the L1 asks for ownership (GETX, or an upgrade if it holds the
line shared), just as ChampSim's step 1 does. That is a recollection, not a
reading; `micro_server.sh go` now prints the sequencer's lines so it is read
on the server. **M3 is therefore withdrawn as a prediction and kept as a
measurement**: pp_rmw reads either like pp_store (GETX-o 12, UPG 0: the two
simulators agree on plain RMWs) or as first written (GETX-o 0, UPG 12).

priv_E and priv_S are what this test exists to measure: when a core's private
caches drop a clean copy, does gem5's L2 still list it? MESI_Three_Level's
private L1 notifies the L2 when it evicts an exclusive line (PUTX), so priv_E
is expected to read 0 in gem5; whether shared copies leave silently decides
priv_S.

## Predictions

- **M1, the metric:** in pp_lock, pp_store, readers and ctl, gem5's GETX-o
  equals ChampSim's P, both equal to the hand count (12, 12, 4, 4), within 1
  count each (gem5's statistics window opens and closes on thread 0 only).
- **M2, the upgrade:** in upgrade, gem5's UPG = ChampSim's U = 4.
- **M3, plain RMWs: measured, no prediction** (amended above). ChampSim: P 12,
  U 0. gem5: GETX-o 12 and UPG 0 if its sequencer hands the load to the
  protocol as a store; GETX-o 0 and UPG 12 if as a load.
- **M4, the bounded view, its premise:** in offchip, gem5 GETX-o = 0 and
  ChampSim P = 4, B = 0.
- **M5, inclusion:** in llc_out, gem5 GETX-o = 0 and ChampSim P = A = B = 4.
- **Measured, no prediction:** priv_E and priv_S in gem5.
- ChampSim's own counts above are checked first, on the laptop. If any misses
  its hand count, the test is broken (that is how the first version, with a
  256 KB ring, was caught: its threads drifted apart and steps overtook each
  other), and nothing is scored until it is fixed.

## How the outcomes are read

- **M1-M2 hold:** the two simulators count the same events on the same
  sequence; the B3 metric is validated directly, not only by agreement on
  real programs.
- **pp_rmw reads as upgrades in gem5:** a known, systematic difference:
  wherever plain RMWs carry the sharing, R_b reads high and U low against
  gem5, by construction; checked against radix (106 RMWs per 1,000
  instructions, almost all plain) before step 4 is designed. **If it reads like
  pp_store,** the two agree on plain RMWs and that is not radix's cause.
- **M4 holds:** the bounded view's premise is shown on a program, not only
  argued.
- **priv_E or priv_S reads 0 in gem5:** gem5 forgets a reader when its
  private caches drop the line, even while the L2 keeps it. Then the bounded
  view, which forgets only when the line leaves the chip, would still over-count
  against gem5, and a step 4 must forget earlier.
