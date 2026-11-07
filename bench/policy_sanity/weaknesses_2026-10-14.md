# The weaknesses a reviewer would raise, and what was done about each (2026-10-14)

Asked for by the owner the same day ("tackle all the possible weaknesses").
Each item says what was done, what it found, and what still waits on the
server. Every number is re-derivable from the committed files named.

## 1. "The tool was fitted to the programs it was checked on"

Every fix (the directory, steps 1-3) was designed after ocean and canneal
disagreed with gem5, and checked on the same runs.

- **Done:** three held-out SPLASH-3 programs chosen by a rule applied to
  native instruction counts before any simulation (radix, water-nsquared,
  fmm), and the frozen tool to be scored on them with the same band
  (`b3_heldout_design_2026-10-14.md`, committed `21b7869`, amended before
  any server run). Pipeline `scripts/b3_heldout.sh`, rehearsed on the laptop.
- **The rehearsal changed the design, before any data:** radix's workers
  generate keys privately for 780 M of their 1,007 M instructions, so its
  window starts at its region of interest; the alignment anchor must be an
  address thread 0 also touches; the memory-operand floor is 5%.
- **Waits on:** `scripts/checks_all.sh` (the owner runs it).

## 2. "A factor-of-two band is loose"

The band stays as pre-registered; the paper reports the numbers.

| level 2, primary measure | R_b | off by |
|---|---|---|
| ocean 2 MB | 0.986 | 1.4% |
| ocean 8 MB | 1.125 | 12.5% |
| canneal 2 MB | 1.263 | 26.3% |
| canneal 8 MB | 1.142 | 14.2% |
| barnes, force span | 0.689 | 31.1% |
| barnes, start span (by count) | 0.761 | 23.9% |

Geometric mean 0.971; typical factor 1.21 (mean |log R|); worst 1.45. With
the 256-body-leaf barnes (0.634): worst 1.58. So: **within about 20% typically
and within 1.6× at worst**, not merely "within 2×". From
`b3_score.py score phasea_rows_v18 b3_rows_v9 gem5_b3_rows_v2 v5 x2@std v5@leaf256`.

## 3. "Coherence costs no time in the tool"

- **First-order estimate, from the A5 rerun's rows** (`b3_rows_v9`,
  `phasea_rows_v18`): at fixed 2 MB, shared, level 2, coherence events per
  core (store misses that find another core plus upgrades) differ across the
  8 policies by 0.35% (8c) and 0.17% (16c). If each event stalled its core
  for L cycles, one after another, LRU's runtime would grow 2.7% (8c) and
  4.3% (16c) at L = 100, and no pair of policies could change order below
  L ≈ 8,000 (8c) and 32,000 (16c). At 2 MB per core, 16 cores, every policy
  is within 0.8% of LRU and some within 0.001% of each other (the cache holds
  the working set), so that order is noise at any L.
- **Done:** C0 built (`coherence_latency`, `c0_latency_design_2026-10-14.md`):
  a request that must take its line from other cores waits L cycles. At
  L = 0 the binary prints what the old one prints (Q0, being checked
  locally, then on the server). Runner `scripts/c0_server.sh`, one command
  `scripts/c0_all.sh`: 72 runs, L = 20, 50, 100.
- **Disclosed limit:** ChampSim's core does not wait for plain stores, so C0
  is a lower bound on the cost.

## 4. "One program, and the regimes differ in cache size"

- **Found:** the size control (`a5_size_control_2026-10-14.md`). Inside the
  private regime, with no sharing, changing only the LLC size reorders the
  policies as much as the cross-regime comparison does, Hawkeye-SRRIP swap
  included. **The A5 claim is withdrawn as a sharing effect.** What stands:
  at one size, sharing keeps the order (τ +0.64 to +0.86) and multiplies the
  gains (2-3% against 13-14% over LRU at 8 and 16 cores).
- **Found on the way:** from step 1 a read-modify-write's load is an RFO, so
  load-only hit rates differ between binaries; load+RFO is the invariant
  measure. `analyze_rows.py` prints it; a wrong conclusion in the barnes doc
  is corrected.
- **Done:** A6, the LLC-size sweep in both regimes, canneal 4c and 8c,
  1-32 MB (`a6_size_sweep_design_2026-10-14.md`, `scripts/a6_sweep.sh`,
  rehearsed). Its rule separates sharing from size.
- **The mid-term deck and speech** were changed the same day (slide 12, the
  summary, the next steps).
- **Waits on:** `scripts/checks_all.sh`; the A5 rerun finishing frees cores.

## 5. Only 4 cores in the gem5 check

- **Done:** canneal at 8 cores against gem5 with 8 workers
  (`b3_canneal8_design_2026-10-14.md`, `scripts/b3_canneal8.sh`). Started by
  `scripts/checks_all.sh`.

## 6. The secondary misses (upgrades for ocean 8 MB and barnes-256; barnes-256 traffic; the barnes window span)

**Not addressed today.** They are disclosed. A diagnosis would compare where
each simulator counts an upgrade (gem5's L2 `SS.L1_UPGRADE` against
ChampSim's hits in the L1D and L2C), using the event log (`9eb1067`). It does
not block the primary measure.

## 7. "gem5 is itself a simulator"

A writing item: gem5 is the reference the field uses for coherence, and
real-hardware counters are out of scope (PLAN § 11). No action.

## 8. Novelty

Searched 2026-10-14 (web). **No published multi-threaded or coherent
ChampSim was found.** The ChampSim paper (Gober et al., arXiv 2210.14324)
names multi-threaded trace simulation as future work. To cite and set
apart:
- an Uppsala master's thesis that prototyped shared memory on ChampSim
  (shared TLB, a broadcast bus; diva2:1805423) -- **not yet read** (the
  repository refused the connection); read before writing;
- trace-driven simulation of multithreaded programs in general (ISPASS 2011,
  TaskSim; ElasticSimMATE on gem5; Pac-Sim, TACO 2024);
- sharing-aware LLC replacement (SRCP; HAPC, 2022; a multi-socket bias,
  arXiv 1909.09463) -- for the COALESCE paper.

## 9. The SCI audit paper: upstream or ours?

`docs/policy_audit.md` already records each defect's origin: drrip, ship,
random and S1-S3 upstream; Hawkeye, Mockingjay, srrip_bias and the COALESCE
family ours. **S3 (`repeatable::eof()` always false) is still in `develop`**
(`inc/repeatable.h:47`), so at least one upstream finding is live, not
historical. The paper should say, per defect, which ChampSim version has it.

## 10. The server account expires 2026-10-26

Everything above that needs the server is ready to launch in two commands
(`scripts/checks_all.sh`, `scripts/c0_all.sh`). At the stated job counts it
is about 1,000 CPU-hours: two to three days at 16-20 jobs. An extension
request is the owner's to make.

## Outcomes, 2026-10-17

- **1 (fitting):** the held-out test **found a failure**: radix, R_b 42.96,
  while its presence view agrees (0.876); water-nsquared did not discriminate
  (its upgrades agree, U 0.953); fmm could not be scored
  (`b3_heldout_results_2026-10-17.md`). The concern was real.
- **3 (latency):** C0 holds its primary prediction: canneal's order is
  unchanged at 20, 50 and 100 cycles (τ +1.00); ocean +0.93
  (`c0_results_2026-10-17.md`).
- **4 (one program, size):** A5's rerun is complete and the size control
  stands; A6 is at 48 of 116.
- **5 (4 cores only):** canneal at 8 cores agrees, R_b 1.721.
