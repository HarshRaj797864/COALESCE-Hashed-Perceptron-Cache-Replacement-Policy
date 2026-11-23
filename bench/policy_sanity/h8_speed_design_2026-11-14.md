# H8: wall-clock time to result, from existing logs. Pre-registered 2026-11-14, before any row is read

PLAN § 10 item 9, H8. Owner, 2026-11-14: "besides the paper do everything".

**Why.** A reviewer asks how long a 4-, 8- or 16-core run takes, in ChampSim
and in gem5. The speed test (`speed_results_2026-10-19.md`) answered speed
under control: CPU-seconds, 4 cores, barnes std, two repeats. Its P1 failed
(ChampSim / gem5 O3 + Ruby = 1.43, needed 2), so **the paper makes no speed
claim**, and nothing here changes that. Since then, hundreds of runs have
finished at 4, 8 and 16 cores in both simulators. Their logs already hold
wall times.

**What is read (no new run).**
- **ChampSim:** every completed `run.log` of
  - step 5 (`phaseA_b3_p2_*`, 171);
  - Part B's g6 runs (`phaseA_b3_b1_*`, `_b2_*`, `_b16_*`);
  - the F-C reruns (lock fix and amendment 10);
  - H7's p3 runs, once pulled.

  The wall time is the largest `Simulation time` on a `Simulation complete`
  line. ChampSim's `elapsed_time()` counts from program start
  (`src/champsim.cc:35-37`), so it covers warm-up and the measured phase.
  The rate is cores x (warm-up + measured) / wall, from the configured
  counts.
- **gem5:** every pulled `stats.txt` of the B3, held-out and Part B runs
  (Note 3's `.prev_` runs skipped). It takes the last dump's `simInsts` and
  `hostSeconds` (wall), and the CPU count from `config.ini` (`system.cpu<k>`
  sections).
- **Tool:** `scripts/h8_speed.py` (`champsim`, `gem5`, `summary`,
  `selftest`). The self-test takes the largest complete line, not a
  heartbeat; the last gem5 dump; and gives no row for an incomplete run.

**What is reported.** For each simulator and core count: the number of runs,
and the median and range of the rate (K instructions per wall-second) and of
the wall hours. The extension's cost stays the speed test's P3 (3%).

**What is not claimed.** These are WALL times on a shared server: nice 19,
load 60-110 on 48 cores, other users' jobs, many of our runs at once. They
measure time to result under those conditions, not simulator speed. The two
simulators did not run under equal load: gem5's runs were 24 at a time and
ChampSim's 8-16. So **no ratio between the simulators is stated from them**.
The paper may say "a 16-core window of 1.6 G instructions took a median of X
h of wall time on a shared 48-core server". It says nothing faster or slower.

**No prediction.** Nothing is decided by these rows.

Output: `bench/policy_sanity/h8_speed_rows_v1.txt` (the rows) and
`h8_speed_results_2026-11-<dd>.md` (the summary).

## Amendment 1, 2026-11-14 (after the first summary was printed and read)

The first `summary`, from rows made by the committed tool, showed ChampSim
runs at 8 and 16 cores ending in 0.5-0.7 h at up to 1,003 K instructions a
wall-second. The cause is a defect in the measurement:
- ChampSim prints elapsed time with fmt's `{:%H hr %M min %S sec}`;
- for a duration, `%H` is the hour **modulo 24**.

In step 5's canneal 16 COALESCE log, the times run up to 22 h 23 min, then
drop to 00 h 17 min (line 257 of its 304 time stamps), and the run "ends" at
00 h 39 min. It ran 24 h 40 min.

**Fix:**
- read every `(Simulation time: ...)` in file order, heartbeats included;
- each drop adds 24 h;
- take the largest unwrapped time on a `Simulation complete` line.

Heartbeats come every 10 M instructions a core, so no run goes 24 h without
one. The self-test gains a run with two drops (2 x 24 h + 1 h).

The same first summary also dropped gem5's rows: its length test required 7
fields, and a gem5 row has 6. Fixed.

**Disclosed:** that first summary (medians 35.8 / 29.4 / 40.7 K a
wall-second at 4 / 8 / 16 cores) was read before this amendment. It is
void. Nothing in the note's rules changes, and there is still no prediction.
The rows file is made only with the amended tool.
