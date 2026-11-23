# Part A: E1 read early on the completed pairs. Interim, 2026-11-14

- **What E1 is** (`breadth_bc_design_2026-11-10.md`, Part A): ours with the
  extension off prints the same log as upstream `f9ed890e`, line for line,
  apart from the allowed added lines. It is an equivalence check against
  upstream and reads no gem5 number.
- **The pull** (`bash scripts/partA_all.sh pull`, 2026-11-14 ~18:15 server
  time): 120 logs. The driver had 96 runs complete (all rc=0, none failed)
  and 24 running, of 185.
- **Command:** `python3 scripts/upstream_equiv.py dir simulator/results/partA/logs`.

## Result

- **E1 holds on 44 of 44 pairs whose two logs are complete.** By mix:

  | mixes | pairs |
  |---|---|
  | single-core SPEC | 21 |
  | 4-core (4a, 4b, 4c) | 5 + 5 + 3 |
  | 8-core (8a, 8b) | 5 + 5 |

- **The other 16 pairs read FAILS only because a log is unfinished.** Each
  has at least one log without "ChampSim completed all CPUs". There are 24
  such logs, exactly the 24 runs in flight. They are read again when
  complete.
- **E2** (the RMW change on: only the per-type LOAD / RFO lines move): no
  `oursdefault` run is complete yet, so 0 of 0.
- Nothing is decided. E1 and E2 are scored when all 185 runs end, then on
  add16's 16-core mixes.
