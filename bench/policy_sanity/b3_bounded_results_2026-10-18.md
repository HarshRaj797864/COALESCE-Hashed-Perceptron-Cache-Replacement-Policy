# The radix diagnosis, scored: P1 holds, P2 fails (2026-10-18)

Against `b3_bounded_design_2026-10-17.md` (`fe4d8a9`). 12 of 12 runs on
`champsim_diag_e583dac3` (server Q0 8 of 8). Rows `phasea_rows_v20.txt`,
`b3_rows_v11.txt`; gem5 `gem5_b3_rows_v3.txt`. Scored with
`b3_score.py score ... d2 d2@std d2@leaf256 d2@held d2@e8`; the protocol,
presence and upgrade columns re-derived from the raw logs by
`verify_numbers.py` (validation round).

## Qualifying checks

- **Q0 (server):** all 12 rows equal the existing level-2 rows (v5, x2, h2,
  e2) in every column of `phasea_rows` -- 12 of 12; the diagnosis changed no
  simulated behaviour.
- **Q1:** bounded <= protocol in every run.
- **Q2:** `check_coherence_exact.sh` passed on the laptop build; and the new
  `offchip` exact cases (validation round) meet their hand counts.

## Result

| program | R_b (protocol) | **R_bounded** | R_a (presence) | verdict |
|---|---|---|---|---|
| **radix** (P1) | 42.96 | **0.878** | 0.876 | **P1 holds** |
| ocean 2 MB (P2) | 0.986 | **0.091** | 0.082 | **P2 fails** |
| ocean 8 MB (P2) | 1.125 | **0.491** | 0.174 | **P2 fails** (just below 0.5) |
| canneal 2 MB | 1.263 | 1.022 | 1.017 | holds |
| canneal 8 MB | 1.142 | 1.034 | 0.920 | holds |
| canneal 8 cores | 1.721 | 1.540 | 1.540 | holds |
| barnes std, force | 0.689 | 0.580 | 0.572 | holds |
| barnes std, start (by count) | 0.761 | 0.795 | 0.766 | holds |
| barnes-256 | 0.634 | 0.634 | 0.631 | holds |
| reported: barnes window | 0.492 | 0.366 | 0.349 | |
| reported: water-nsquared | 1.924 | 1.924 | 1.924 | (414 events) |
| reported: fmm | 1.409 | 0.314 | 0.284 | (not scored) |

**The pre-registered reading: "P1 holds, P2 fails: forgetting off-chip lines
fixes radix and breaks others; the right rule lies elsewhere."** No step 4
on this rule.

## What it shows

- **radix's 43x is lines that left the chip:** in 1,576,331 of its
  1,609,213 protocol events, every core listed had read the line before it
  last left the chip entirely (no private copy, not in the shared cache).
  Forget those and radix agrees.
- **ocean's agreement rests on the same kind of line.** In gem5, 99% of
  ocean's store misses that find another core find it as the line's
  *owner*, still holding it (`MT`: 27,331 of 27,649 at 2 MB). In ChampSim's
  replay, at the same misses, the other core's caches hold the line 8% of the
  time (R_a 0.082) and the chip 9% (R_bounded 0.091). The protocol view
  agrees with gem5 on ocean only because it never forgets.
- So no rule that follows ChampSim's own residency can fit both: in radix
  the lines really are gone in both simulators; in ocean they are gone in
  ChampSim but held in gem5. **The question is why ChampSim's replay has
  lost ocean's lines that gem5 still holds.**
  - Not drift in speed: ocean's four cores take 316-319 M cycles for their
    100 M instructions (1% apart; 11% at 8 MB).
  - **Candidate 1, alignment:** the ocean traces were never aligned (barnes
    std and the held-out programs were): each trace's 50 M warm-up counts
    from its own thread's start, and thread 0's includes the serial set-up.
    The threads then replay offset from each other by up to that set-up,
    where gem5's barriers hold them together. A neighbour's store then
    comes long after the owner last touched the line.
  - **Candidate 2, no barriers at all:** a trace replay never waits at a
    barrier, so even aligned threads drift by phases. barnes's window span,
    which crosses a barrier, reads lowest of the barnes spans (0.492; bounded
    0.366).
  - Candidate 3: the private caches keep lines differently (inclusion,
    replacement). Less likely: the sizes are matched and canneal agrees on
    both views.

## What the micro test adds (`micro_results_2026-10-18.md`)

gem5 forgets a core that held a line **exclusively** as soon as its private
caches drop it (priv_E: 0), but keeps listing cores that **shared** it
(priv_S: 4), until the shared cache evicts the line (offchip: 0). ChampSim's
protocol view keeps both; the bounded view keeps both while the line is on
chip. A rule that copies gem5 is now known exactly -- but it is still a rule
on residency, and ocean shows residency at hand-over differs between the
replay and gem5. That has to be settled first.
