# C's QC1 and E's QL1 failures: diagnosis results (2026-11-23)

Design: `qc1_ql1_diagnosis_design_2026-11-23.md` (`5f690f5`), committed
before these files were pulled.

**Inputs, all read-only:**
- `scripts/ld_all.sh pull` and `scripts/e2_all.sh pull`;
- the ChampSim micro event logs, copied by rsync from `~/ld/micro_cs/*.events`
  to `simulator/results/ld/micro_cs_ev/` (the pull does not include them).

**Nothing of C or E is scored, and nothing changes.**
- Disk at the time: 4 GB free on /home.

## H1 (QC1b, llc_out and offchip): SUPPORTED

Each value is r8 − r4 of the first statistics block (MESI_Three_Level, C's
micro runs):

| Case | L0 instruction-fetch misses | L2 SS replacements | MT.L1_GETS | EE / MM Fwd_GETS |
|---|---|---|---|---|
| ctl | 3 | 0 | 0 | 0 / 0 |
| priv_E | 123 | 0 | 1 | 1 / 0 |
| priv_S | 127 | 0 | 4 | 0 / 4 |
| readers | 10 | 0 | 4 | 0 / 4 |
| **llc_out** | **472** | **25** | **24** | 13 / 11 |
| **offchip** | **616** | **32** | **24** | 24 / 0 |

The other cases (pp_lock, pp_store, pp_rmw, upgrade) read 7-10 / 0 / 0-4.

- **P1a holds.** Only the two sweeping cases re-fetch code every round, and
  only they evict shared lines (SS) from the inclusive L2: 25 and 32 per 4
  rounds against 24 events. FLUSH (priv_E, priv_S) re-fetches code from
  the L2, where the line stays SS with its sharers listed, so no event
  follows.
- **P1b fails as written** (llc_out MM 11 is not "a few"). **Its premise was
  wrong:** `readers`, whose loads are clean, reads MM.Fwd_GETS 4. So in
  MESI_Three_Level's L1, MM does not mean dirty. The prediction tested
  nothing.
- **P1c holds:** every other case is within 1 of its hand count.
- **Reading:**
  - gem5's MT.L1_GETS counts what was assumed on the test lines.
  - The 24 is a per-round background from the sweep: shared lines (code and
    read-only globals) evicted from an inclusive L2, re-fetched, granted E to
    the first reader and found MT by the next.
  - QC1b's assumption that r8 − r4 cancels the background does not hold for
    the sweeping cases.
  - Not shown by address: that needs a ProtocolTrace run (server).
- **For C's meaning, if it is ever scored:** ChampSim's LLC is
  non-inclusive, so it never makes these events. On real programs, gem5's
  MT.L1_GETS includes re-fetches of shared code and read-only data after L2
  evictions, which ChampSim does not model. R_ld would have to state this.

## H2 (QC1a readers 5): SUPPORTED

- **Round 3** (A = core 3, B = core 0, C = core 1, D = core 2):

  | Cycle | Event | gem5-rule view | Flag |
  |---|---|---|---|
  | 19,525,672 | A's load | | 0 |
  | 21,026,798 | B's load | finds core 3 | 1 |
  | **24,027,069** | **D's RFO** | | |
  | **24,400,259** | **C's load** | finds core 2 (mask 4) | **1** |

- C's load came 3.37 M cycles after B's; one step is about 1.5 M.
- Rounds 0-2 each have exactly one flagged load, in the scheduled order.
- **The counter is right by its definition.** The hand count assumed the
  step order, and core 1 broke it.

## H3 (QC1a priv_S 3): sub-case (b)

- **Round 3:** A (core 3) loads at 24,043,022. C (core 1) loads at
  27,664,349, 3.62 M cycles later.
- At C's load:
  - no private copy is held (presence 0);
  - the gem5-rule view lists nobody (0);
  - only the never-forgetting protocol view still lists core 3.
- So A's FLUSH had dropped the line before C's late load. The flag 0 is
  right by the counter's definition.
- **The same core is late in the same round in both cases** (core 1,
  round 3, about 2 M cycles). ChampSim's timed form does not hold the step
  order to round 3 for that core.

## H4 (QL1 ctl, background): NOT SUPPORTED. The losses are per round, in rounds 5-8

Store-time sharing events G (SS + MT L1_GETX) and upgrades U, at r4 and r8:

| Case | Protocol | r4 | r8 | Hand count (r8) | r8's M.L1_GETX |
|---|---|---|---|---|---|
| ctl | Three_Level | G 4 | G 6 | 8 | 2 |
| ctl | Two_Level | G 4 | **G 8** | 8 | 0 |
| pp_store | Three_Level | G 12 | G 22 | 24 | 2 |
| pp_store | Two_Level | G 12 | G 23 | 24 | 1 |
| upgrade | Three_Level | G 0 U 4 | G 2 U 6 | G 0 U 8 | |
| upgrade | Two_Level | G 0 U 4 | G 1 U 7 | G 0 U 8 | |

pp_lock reads the same as pp_store.

- **Both protocols are exact at r4, on every case shown.** The background
  does not differ.
- The shortfall is in rounds 5-8. It shows up as **M.L1_GETX**: the
  owner's private copy was written back before the next core's store.
  - This is the signature the 2026-10-18 micro already showed (pp 11 of 12,
    ctl 3 of 4, each through one M.L1_GETX).
- **QL1 fails because the two hierarchies lose different rounds:**
  - Three_Level (L0 + L1 + L2) loses 2 in ctl;
  - Two_Level (L1 8 kB + L2) loses 0.
  - Two_Level matching the hand count does not make Three_Level wrong.
    Both are real protocol behaviour of their hierarchies; QL1's "within 1"
    assumed the same evictions.

## What follows (owner's decision; each would be an amendment written after the failure, and disclosed)

- **C:**
  - (i) QC1b on the test lines only, by a ProtocolTrace run of llc_out and
    offchip at r4 and r8 filtered on X (server). Or (ii) state llc_out and
    offchip as background-limited and judge QC1b on the other 8 cases.
  - QC1a: rerun in the barrier form, as Q16 did, or judge the order round
    by round.
  - Until then C is not scored, as its design says.
- **E:** judge QL1 on the r4 runs, where both protocols are exact; or
  count M.L1_GETX losses beside G. Until then no MESI_Two_Level ratio is
  read.
- **Neither result shows a defect in ChampSim's counters or in gem5's.**
  Each shows a micro-program assumption that does not hold:
  - a constant background under sweeps (gem5);
  - the step order in round 3 (ChampSim's timed form);
  - no write-back during a wait (both gem5 protocols, rounds 5-8).
