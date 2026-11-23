# Part C: C0 read early on the completed pairs. Interim, 2026-11-14 (no M1 / M2, no C1 / C2)

- **What C0 is** (`breadth_bc_design_2026-11-10.md`, Part C, Note 4): on each
  pair, our binary with the extension off prints the same log as upstream's,
  by Part A's E1 (`upstream_equiv.py`). It is an equivalence check. It reads
  no gem5 number and no ratio, so reading it early decides nothing that is
  scored later.
- **The pull** (`bash scripts/partC_all.sh pull`, 2026-11-14 ~18:10 server
  time): 30 pairs' logs. The driver lists 25 as "complete (both logs)"; the
  other 5 (canneal_16, fmm_16, raytrace_8, streamcluster_8, waternsq_16)
  were still running and were pulled part-written.
- **Command:** `python3 scripts/partC_score.py c0 simulator/results/partC/logs`
  (self-test passes).

## Result

- **C0 holds on 25 of 25 completed pairs:**
  - at 4 cores: barnes, bodytrack, canneal, fft, fluidanimate, fmm, lunc,
    ocean, oceannc, radix, raytrace, streamcluster, vips, volrend,
    waternsq;
  - at 8 cores: barnes, bodytrack, canneal, fft, fluidanimate, fmm, lunc,
    vips, volrend, waternsq.
- **The 5 running pairs read FAILS only because they are unfinished:**
  - neither log has "ChampSim completed all CPUs" yet;
  - where a line differs, it is the last line, cut mid-write (e.g.
    raytrace_8 line 270: "Heartbeat CPU 6 instructions: 110000000 cycles:
    189456" against the full line upstream).
  - They are read again when they complete.
- Part C's measures (M1, M2) and criteria (C1, C2) are not computed. They
  wait for every pair and for Part B's scored keys, as the note orders.

## Addendum, 2026-11-18 pull (no M1 / M2, no ratio)

- `bash scripts/partC_all.sh pull`: 72 logs, i.e. 36 pairs.
- `python3 scripts/partC_score.py c0 simulator/results/partC/logs`:
  **E1 holds on 30 of 30 completed pairs.**
- The other 6 were running at the pull: barnes_16, fft_16, lunc_16,
  ocean_8, oceannc_8 and radix_8. Each reads as unfinished: no "ChampSim
  completed all CPUs" on at least one side, and a last heartbeat line cut
  mid-write. They are not failures.
- 9 pairs had not started.
