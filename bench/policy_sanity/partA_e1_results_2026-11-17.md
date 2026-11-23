# Part A: ours with the extension off against upstream ChampSim -- results for the 185 runs (2026-11-17)

Design: `upstream_equiv_design_2026-11-10.md` (pre-registered; amendment 3,
2026-11-11, adds the 16-core mixes 16a and 16b, 22 runs; amendment 5,
`1427b76`, the waiter that adds them). Early read:
`partA_e1_interim_2026-11-14.md` (44 of 44 pairs then).

## State at the pull (2026-11-17, server about 13:50 UTC)

- The first chain's **185 of 185 runs complete**. The add16 waiter then
  added 16a and 16b at 00:56:39 server time (E0 at 16 cores held: 12 traces
  counted, 6 configs written; 207 runs in all) and restarted the chain,
  which skips the 185.
- **The 22 16-core runs are still running: 0 of 22 logs complete.**
- `bash scripts/partA_all.sh pull`: 207 logs and each one's binary sidecar
  to `simulator/results/partA/logs/`.

## E1 (the claim)

`python3 scripts/upstream_equiv.py dir simulator/results/partA/logs`
-> `partA_e1_v1.txt`:

- **E1 holds on 85 of 85 pairs of the first 185 runs**: 60 single-core
  (12 SPEC CPU2006 traces x 5 policies), 15 at 4 cores (mixes 4a, 4b, 4c x
  5) and 10 at 8 cores (8a, 8b x 5). In each, upstream's log is an
  in-order subsequence of ours-off, every added line is allowed, and both
  completed once; 0 without a partner. This is the design's original pass rule (85 of 85),
  met.
- The tool prints "85 of 95": the other 10 are the 16-core pairs, all read
  FAILS only because neither log has finished ("ChampSim completed all
  CPUs" printed 0 times). **Not decided.** Amendment 3's rule (95 of 95)
  waits for them.

## E2 (reported, with the prediction)

`python3 scripts/upstream_equiv.py e2 simulator/results/partA/logs`
-> `partA_e2_v1.txt`:

- **The prediction holds on 15 of 15** of the first set: with our default
  settings (RMW loads issued as RFOs), the only lines that differ from
  upstream are the per-type LOAD and RFO lines of L1D, L2C and LLC (0-6
  lines on the 12 single-core runs, 0 on mcf, milc and lbm; 28, 36 and 48
  on the three 4-core mixes); 0 other lines.
- The tool prints "15 of 17": 16a_lru and 16b_lru (ours default) are
  running. Not decided.

## What the paper states (now)

With the extension off, our ChampSim prints exactly what upstream ChampSim
`f9ed890e` prints, on 85 of 85 run pairs (12 SPEC CPU2006 traces at 1 core;
4- and 8-core mixes; lru, srrip, drrip, ship, random), only adding its own
statistics lines. With our defaults, only the per-type LOAD / RFO counts of
the caches change (15 of 15). The 16-core pairs are added when they finish.

Next: `bash scripts/partA_all.sh pull`, then both commands again, once the
22 runs end.
