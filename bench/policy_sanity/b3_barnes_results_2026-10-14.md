# B3, barnes scored both ways — and the first cross-regime number on the validated tool

**2026-10-14.** Scored against two pre-registrations, each committed before
its runs existed:
- `b3_barnes_std_design_2026-10-13.md` (`3c81819`): SPLASH-3's barnes as
  shipped, traced anew and aligned, against gem5's standard runs;
- `b3_barnes256_design_2026-10-12.md` (`07f52b9`): gem5 on the 256-body-leaf
  program the old `barnes_4t` traces hold, against the ChampSim rows already
  in hand.

Sources: `phasea_rows_v18.txt`, `b3_rows_v9.txt`, `gem5_b3_rows_v2.txt`,
`gem5_mix_v2.txt`, `trace_mix_v2.txt`; the server's pipeline files in
`simulator/results/barnes_std/`. Every number comes from `b3_score.py`,
`b3_stream_check.py` and `analyze_rows.py`.

## The standard barnes

### Qualifying checks — all hold

| check | result |
|---|---|
| QB, the binary | the dynamic build equals the binary gem5 ran in all 11 force and tree-build functions (instruction count and constants), on the server |
| QT, the traces | four, each 200 M records; memory operands in 36.8-49.9% of records. The anchor: thread 0 reaches `CountLock` at record 10,570,780, threads 1-3 at 774; after dropping 10,570,006 records the first barrier is at record 25,476 in all four. Shift left: 0 |
| QG, the guard | 9.40 / 9.45 / 9.80 / 11.00 read-modify-writes per 1,000 instructions (8-13.5 required; the 256 build makes 26.8) |
| QS, the same stream | force span: loads 1.048, stores 1.041, read-modify-writes 1.003 (gem5 / trace). Start span 1.021 / 1.031 / 0.995; window 1.047 / 1.044 / 0.991. All within 5% |
| QF, no barrier in gem5's force span | between its 50 M and 100 M stops gem5's cores ran 50.00, 49.95, 49.97 and 50.10 M instructions |
| Q1, the private regime untouched | in each span the private rows at levels 1 and 2 equal level 0's in every column: 3 rows, 0 differ, at each level |
| Q2 | 18 of 18 complete, no trace wrapped, self-check 0, 12 registered, stale-holder check 0, each log printing its level |

### Results

R_b per 1,000 instructions; in the start span by count, as pre-registered.

| span | level 0 | level 1 | **level 2** | U at level 2 | traffic at level 2 |
|---|---|---|---|---|---|
| **force** (37.9 M + 50 M; primary) | 0.401 | 0.551 | **0.689** | not scored: gem5 has 5,901 upgrades (ChampSim 12,605) | 0.81 |
| **start** (0 + 37.9 M; by count) | 0.082 | 0.100 | **0.761** (93,664 / 123,076) | **0.713** (110,258 / 154,740) | 0.56 |
| window (37.9 M + 100 M) | 0.360 | 0.384 | 0.492 | 0.818 | 0.70 |

| prediction | result |
|---|---|
| **P1** force span, level 2: 0.5 ≤ R_b ≤ 2 | **holds: 0.689** |
| **P2** start span, level 2, by count | **holds: 0.761** |
| P3 window reported, expected at or above the force span | **direction fails:** 0.492, below the force span's 0.689, and just below the band |
| **P4** upgrades in the band in the start span | **holds: 0.713** (force span not scored: under 10,000 in gem5) |
| **P5** traffic within 2× in force and start | **holds:** 0.81, 0.56 |
| P6 force span: R_b < 0.5 at levels 0 and 1 | **fails at level 1: 0.551** (level 0: 0.401) |
| P7 R_b at level 1 ≤ level 2, every span | **holds:** 0.100 ≤ 0.761; 0.551 ≤ 0.689; 0.384 ≤ 0.492 |

**What it means.**
- **At level 2 the standard barnes agrees with gem5** in the two spans where
  the replay can be held to the program: inside the force phase, and from
  the aligned start through the first tree build.
- **The start span is where barnes shares.** gem5 counts 123,076 store
  misses that find another core there, against 708 inside the force phase.
  Levels 0 and 1 see 8-10% of them; level 2 sees 76%, and 71% of the
  upgrades.
- **The force span discriminates weakly between levels** (0.40 / 0.55 /
  0.69), because there is almost no sharing in it. That is why P6 failed at
  level 1: 396 events against gem5's 708.
- **The window reads below the force span, not above**, so the predicted
  cost of crossing a barrier did not show as an overshoot. It reads 0.49.

## The 256-body-leaf barnes

### Qualifying checks

- **QB holds** (server, 2026-10-13): the new static binary's seven force-phase
  functions equal the traced binary's in instruction count and constants.
- **QG holds:** both gem5 runs ended at their stops; each config shows the 256
  binary, a 2 MB L2, 8 of 8 buffers unordered, randomization off.
- **QS misses on one of four measures:** loads 1.028, **stores 1.058** (5%
  allowed), read-modify-writes 1.019, locked read-modify-writes 1.013.
  - **Measured:** gem5's side of this check counts memory **micro-ops**, not
    instructions. Its Ruby request counts equal its committed memory micro-ops
    exactly (barnes-256: 328.20 loads and 177.96 stores per 1,000
    instructions, both ways; canneal 377.19 and 215.24, both ways).
  - barnes is floating-point code (115 FloatMemRead micro-ops per 1,000
    instructions, against canneal's 59). Every barnes comparison, the
    standard program's included, reads 3-6% more memory accesses in gem5
    than in the trace; canneal reads 0.1%.
  - **Not established:** which instructions take two memory micro-ops in
    gem5. A gcc 11 build on the laptop has no 16-byte vector memory
    instructions in the force functions; the server's gcc 13 was not read.
  - The measures the comparison rests on, read-modify-writes and locked
    ones, agree within 2%. **Scored below with the miss stated.**

### Results

Window 50-150 M, per 1,000 instructions.

| level | R_b | U | traffic | hand-overs (store misses that find another core + upgrades) |
|---|---|---|---|---|
| 0 (`v3`, `v4l0`) | 0.000 (50 / 295,420) | 0 | 0.15 | 50 / 729,180 |
| 1 (`v4`) | 0.009 | 0 | 0.15 | 0.003 |
| **2 (`v5`)** | **0.634** | **0.478** | **0.44** | **0.541** (398,143 / 729,180) |

| prediction | result |
|---|---|
| **P1** level 2: 0.5 ≤ R_b ≤ 2 (expected 0.75-1.6) | **holds: 0.634**, below the expected range |
| P2 level 2: 0.5 ≤ U ≤ 2 (low edge flagged at risk) | **fails: 0.478** |
| **P3** level 1: R_b < 0.5 | **holds: 0.009** |
| **P4** level 0: R_b < 0.5 | **holds: 0.000** |
| P5 traffic within 2× (flagged at risk, low) | **fails: 0.44** (0.59 with ChampSim's upgrades added) |
| **P6** hand-overs within 2× | **holds: 0.541** |

**What it means.**
- **The "overshoot" of 2026-10-12 is gone.** Against the program it actually
  ran, ChampSim at level 2 makes 0.54 of gem5's hand-overs on this
  lock-heavy program, not 3.7×.
- gem5 counts more than the ideal directory predicted from the traces
  (295,420 store misses that find another core, against 237-254 thousand;
  433,760 upgrades, against 401-427 thousand). A real core waits on a
  locked instruction; the ideal model assumed it never waits.
- Its shortfall is in upgrades and traffic, both flagged before the run.

## The cross-regime result on the validated tool, 16 cores

The A5 rerun at level 2 has finished its fixed-geometry canneal 16-core set
(9 of 9). Against the same scaled-private rows as A5 (the private regime is
the same at every level, by Q1), `analyze_rows.py compare`:

| 16 cores | private (scaled) | shared (fixed 2 MB), level 2 |
|---|---|---|
| order | hawkeye +9.95, mockingjay +8.13, drrip +4.02, srrip +3.15, lru, ship −0.67, srrip_bias −2.28, random −2.97 | srrip +14.00, srrip_bias +13.73, mockingjay +11.86, hawkeye +10.95, drrip +7.37, ship +5.16, lru, random −0.94 |
| Kendall τ, 8 baselines | **+0.29**, as at level 0 | |

- **The 16-core result holds on the validated tool:** τ +0.29, the shared
  order the same as at level 0, and SRRIP still ahead of Hawkeye in the
  shared regime while Hawkeye leads in the private one.
- ~~Pressure is less well matched than before: LRU's LLC load hit rate is
  26.4% (private) against 31.7% (shared at level 2; it was 24.8% at
  level 0).~~ **Corrected 2026-10-14 (`a5_size_control_2026-10-14.md`):** the
  two load rates come from different binaries, and from step 1 on a
  read-modify-write's load counts as an RFO. On loads plus RFOs, the same on
  both binaries, it is 26.4% against 25.3%: as well matched as at level 0.
- **Read with `a5_size_control_2026-10-14.md`:** the private regime alone,
  with only the LLC size changed, gives τ +0.36 at 16 cores and the same
  Hawkeye-SRRIP swap, so this τ is not attributable to sharing.
- 4 and 8 cores wait on the rest of the queue (`l2_fixed` 19 of 40 at the
  pull; `l2_scaled` complete).

## Where B3 stands

At level 2, the setting the owner adopted, R_b is in the band for:

| program | 2 MB | 8 MB |
|---|---|---|
| ocean | 0.986 | 1.125 |
| canneal | 1.263 | 1.142 |
| barnes, standard (force / start) | 0.689 / 0.761 | — |
| barnes, 256-body leaves | 0.634 | — |

Disclosed with it: the window span of the standard barnes at 0.492;
upgrades low for ocean 8 MB (0.21) and barnes-256 (0.478); barnes-256's
traffic (0.44); QS missing on stores for barnes-256; 4 cores only.

**Whether B3 has landed is the owner's decision.** My reading: on the
pre-registered primary measure, all three shipped programs agree at level 2,
and the misses are on secondary measures, each disclosed.
