# One program with known answers, through both simulators: scored (2026-10-18)

Against `micro_design_2026-10-17.md` (`5629acc`, M3 amended in `9251b7b`
before any gem5 run). `bench/coherence_micro.c` (md5 1802fafd4f2c), 4 rounds
per case, small hierarchy (L1D 2 KB, private L2 8 KB, shared 256 KB) in both.

- gem5: 11 runs on the server (`micro_server.sh`), MESI_Three_Level,
  TimingSimpleCPU; each stats.txt holds 2 dumps, the first is the window
  between thread 0's markers (m5ops worked). The control (0 rounds) reads 0
  on every counter, so the counts below are the patterns alone.
- ChampSim: the laptop (`bench/micro_champsim.sh`, `bin/champsim` at
  `e082655`), levels 0 and 2; counted on the whole run and, from the event
  log, on the test lines only -- the two agree in every case.

## Result (4 rounds; hand counts in brackets)

| case | gem5 GETX-o | gem5 UPG | ChampSim L2: P | A | B | U |
|---|---|---|---|---|---|---|
| pp_lock | **11** [12] | 0 | **12** | 12 | 12 | 0 |
| pp_store | **11** [12] | 0 | **12** | 12 | 12 | 0 |
| pp_rmw | **11** | 0 | **12** | 12 | 12 | 0 |
| readers | **4** [4] | 0 | **4** | 4 | 4 | 0 |
| upgrade | 1 [0] | **3** [4] | 0 | 0 | 0 | **4** |
| ctl | **3** [4] | 0 | **4** | 4 | 4 | 0 |
| priv_E | **0** (measured) | 0 | 4 | 0 | 4 | 0 |
| priv_S | **4** (measured) | 0 | 4 | 0 | 4 | 0 |
| llc_out | 1 [0] | 0 | 4 | 4 | 4 | 0 |
| offchip | **0** [0] | 0 | 4 | 0 | **0** | 0 |

ChampSim at level 0: the ping-pongs read 4 (1 a round), upgrade 0, the rest as
at level 2. **Every ChampSim count equals its hand count**, at both levels.

## The predictions

| | result |
|---|---|
| **M1** the metric: pp_lock, pp_store, readers, ctl agree within 1 | **holds**: 11/12, 11/12, 4/4, 3/4 |
| **M2** upgrades: gem5 UPG = ChampSim U = 4 | **3 of 4**; gem5's fourth hand-over is a GETX finding the line shared (`SS.L1_GETX` 1): the owner's shared copy had left its 8 KB private cache before its store. Hand-overs 4 = 4 |
| **M3** plain RMWs (measured) | **gem5 issues a plain RMW's load as an ownership request**, as ChampSim does: 11 GETX-o, 0 upgrades, like pp_store. Agrees with gem5's source (`Sequencer.cc` 1046-1047: StoreCheck load -> RMW_Read, handed to the protocol as ST). Not a difference |
| **M4** the bounded view's premise (offchip): gem5 0, ChampSim P 4, B 0 | **holds** |
| **M5** inclusion (llc_out): gem5 0, ChampSim P = A = B = 4 | **3 of 4 rounds** read 0 in gem5; in one the line survived the 1.5x sweep of gem5's pseudo-LRU shared cache |
| priv_E (measured) | **gem5 forgets an exclusive holder when its private caches drop the line** (0; `M.L1_GETX` 4: the L2 holds the line with no owner) |
| priv_S (measured) | **gem5 keeps listing shared readers that dropped their copies** (4; `SS.L1_GETX` 4) |

The misses of one (pp 11 of 12, ctl 3 of 4) each show up as `M.L1_GETX` 1:
the owner's line had left gem5's 8 KB private cache (it also holds
instructions) before the next core's store. The design allowed 1.

## What it means

1. **The B3 metric is validated directly.** On a program whose answer is
   known, gem5's `(SS + MT).L1_GETX` and ChampSim's protocol-view count
   agree within one in every case where nothing leaves a cache, and the
   two simulators file plain and locked read-modify-writes the same way.
2. **gem5's rule for remembering a core is now measured, not argued:**
   - an exclusive holder is forgotten when its private caches drop the line;
   - shared readers stay listed after dropping their copies, until the
     shared cache evicts the line (inclusive: their copies go with it).
   ChampSim's protocol view keeps both kinds for ever (P = 4 in priv_E,
   llc_out and offchip, where gem5 reads 0). That is radix's over-count in
   miniature. The bounded view matches gem5 in offchip only.
3. A gem5-like rule for ChampSim (step 4) would be: forget an exclusive
   holder when it drops its copy; forget shared readers when the line
   leaves the chip. But `b3_bounded_results_2026-10-18.md` shows ocean's
   agreement rests on lines ChampSim's replay has already lost and gem5
   still holds, so the cause of that residency gap comes first.
