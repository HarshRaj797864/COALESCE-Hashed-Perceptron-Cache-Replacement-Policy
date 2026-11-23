# H8: wall-clock time to result, from the logs (2026-11-14). Reported only

Design `h8_speed_design_2026-11-14.md` (pre-registered `004fa46`; amendment
1, the 24-hour wrap, written before these rows). Rows
`h8_speed_rows_v1.txt`:
- 204 complete ChampSim runs and 21 incomplete ones (still running; no row);
- 106 gem5 runs, plus radix_16's two, still running and unread.

```
sim   cores  runs  K instr / wall s: median [min, max]   wall hours: median [min, max]
ChampSim   4   136      35.8 [12.6, 56.7]         4.6 [1.5, 13.3]
ChampSim   8    48      29.2 [13.6, 49.6]        11.4 [6.7, 24.5]
ChampSim  16    20      36.0 [24.4, 40.8]        18.6 [16.3, 27.3]
gem5       4    32      71.6 [9.5, 162.5]         2.6 [0.3, 39.1]
gem5       5    10     134.8 [13.6, 140.8]         8.4 [0.9, 14.6]
gem5       6     2     113.8 [110.8, 116.7]         1.1 [0.7, 1.6]
gem5       7     2     107.7 [104.7, 110.6]         1.3 [0.8, 1.8]
gem5       8    20      69.5 [42.0, 97.2]         5.5 [0.4, 48.4]
gem5       9     6      78.7 [61.7, 102.0]         5.3 [2.0, 14.6]
gem5      10     2      79.6 [78.7, 80.4]         3.0 [1.6, 4.4]
gem5      11     2      75.8 [74.6, 77.0]         3.4 [1.9, 4.9]
gem5      16    18      60.4 [37.2, 91.1]         9.2 [0.5, 28.9]
gem5      17     6      66.7 [51.9, 79.5]        12.7 [3.6, 25.1]
gem5      18     2      64.0 [62.9, 65.2]         7.6 [3.9, 11.2]
gem5      19     2      61.2 [55.3, 67.2]         8.2 [3.8, 12.6]
```

**What it says.**
- Nearly all ChampSim runs simulate cores x 150 M instructions (50 M warm-up
  + 100 M). The lock-fix spans are shorter; each rate uses its own log's
  window. The median run took 4.6 h of wall time at 4 cores, 11.4 h at 8 and
  18.6 h at 16, at a median 29-36 K instructions a wall-second.
- gem5's runs simulate each program from its start to the stop, so their
  instruction counts differ from ChampSim's. They ran at a median 60-135 K a
  wall-second, depending on the CPU count.

**What it does not say** (the note's rules):
- These are wall times on a shared 48-core server: nice 19, load 60-110,
  other users' jobs, and 8-24 of our runs at once.
- gem5 and ChampSim did not run under equal load, so **no ratio between the
  simulators is stated**.
- The controlled measurement stays `speed_results_2026-10-19.md`: CPU-
  seconds at 4 cores; ChampSim 64.0 K/s, gem5 O3 + Ruby 44.9, gem5
  TimingSimple + Ruby 145.5. Its P1 failed, so **the paper makes no speed
  claim**.
- The paper may state the wall hours above as the cost of a run on that
  server.

**The defect found on the way** (amendment 1): ChampSim's printed elapsed
time wraps at 24 h (fmt's `%H` on a duration). Anyone timing ChampSim from
its logs must unwrap it. This is upstream's printing, not something we
changed.
