# Step 4 scored: five of the six new benchmarks. 2026-11-01

> **Update 2026-11-05: LU non-contiguous, which replaced radiosity, is
> scored in `newbench_lunc_results_2026-11-05.md`.** It discriminates (37,519
> gem5 events) and P8-P10 hold (R_g5 1.831, traffic 1.109). The line "No
> program tests P8-P10 yet" below is superseded. The rest of this note
> stands.

Pull of 2026-11-01 05:26 server time (`phasea_rows_v25.txt`,
`b3_rows_v16.txt`). Made today from the pulled files: `trace_mix_v4.txt`,
`gem5_mix_v4.txt`, `gem5_b3_rows_v4.txt`; every v3 row is unchanged in v4.
Pre-registration: `newbench_design_2026-10-19.md` (`9cc7cb1`; amendment
`df6a32e`; the note of 2026-10-27; amendment 2 `d81d589`, `206159b`).
Binary `champsim_g6_1e3060c1`, level 2, mutex order by timing (every run
log). Primary measure R_g5 (owner, 2026-10-27, before any of the six was
scored). Nothing was tuned.

## In one line

**No program tests P8-P10 yet.** Three of the five fail the same-stream
check, so by the design they are reported and not scored. The two that pass
(lu, raytrace) are not discriminating: gem5 counts 108 and 184 store misses
that find another core in the window, below the 500 the design requires.
radiosity is replaced by LU non-contiguous under rule (c); that program has
not been sized, traced or run.

## Qualifying checks

- **QT: 5 of 5 hold** (each program's `DONE`; lu 160 M, raytrace 827 M, fft
  549 M, volrend 514 M, streamcluster 130 M as traced).
- **radiosity: no anchor** (`radiosity: FAILED -- no anchor`, 2026-10-30
  05:03:22 server time, 47.4 h after its chain started). **Rule (c) applies:
  it is replaced by LU non-contiguous** (`-n2048 -p4 -b16`, sized by the size
  rule, traced by amendment 2's length rule). Its 12 gem5 runs ended; they are
  not used.
- **Q3: holds in 5 of 5.**

  | run | completed | SYNC DEADLOCK | end of trace | self-check | stale-holders | view-order raw = by silent re-listing | unexplained |
  |---|---|---|---|---|---|---|---|
  | fft | yes | 0 | 0 | 0 | 0 | 0 = 0 | 0 |
  | lu | yes | 0 | 0 | 0 | 0 | 3 = 3 | 0 |
  | raytrace | yes | 0 | 0 | 0 | 0 | 5 = 5 | 0 |
  | streamcluster | yes | 0 | 0 | 0 | 0 | 0 = 0 | 0 |
  | volrend | yes | 0 | 0 | 0 | 0 | 21 = 21 | 0 |

- **Same stream** (`b3_stream_check.py check trace_mix_v4.txt
  gem5_mix_v4.txt`; the held-out rule, as the design says: RMWs within 5%
  gate; loads and stores within 5%, up to 8% scored with the miss stated).
  Per 1,000 instructions, trace / gem5 (gem5 / trace):

  | program | with a load | with a store | read-modify-write | verdict |
  |---|---|---|---|---|
  | fft | 107.733 / 207.766 (1.929) | 55.742 / 103.756 (1.861) | 0 / 0 | **not the same stream** |
  | lu | 234.175 / 234.186 (1.000) | 113.573 / 113.580 (1.000) | 0.001 / 0.001 | same stream |
  | raytrace | 371.026 / 371.489 (1.001) | 26.305 / 26.583 (1.011) | 0.132 / 0.132 (1.004) | same stream |
  | streamcluster | 284.070 / 292.871 (1.031) | 3.278 / 2.878 (0.878) | 0.005 / 0.005 | **not the same stream** (stores) |
  | volrend | 194.158 / 195.269 (1.006) | 39.007 / 40.646 (1.042) | 0.933 / 0.995 (1.067) | **not the same stream** (RMWs: 0.062/KI apart, over the 0.05 allowed) |

  The earlier workloads read exactly as before (ocean's one-trace store miss,
  barnes-256's 1.058, fmm's failure).

## lu and raytrace: reported, not discriminating

`b3_score.py score phasea_rows_v25.txt b3_rows_v16.txt gem5_b3_rows_v4.txt
n2@new`. Only these two blocks of its output were read.

| program | gem5 events (MT) | ChampSim gem5-rule events | R_g5 | R_b | traffic | upgrades ChampSim / gem5 | verdict |
|---|---|---|---|---|---|---|---|
| lu | 108 (100) | 22 | 0.192 | 0.192 | 0.54 | 56 / 72 (too few to score) | not discriminating |
| raytrace | 184 (184) | 486 | 2.485 | 2.506 | 1.14 | 11,733 / 11,952: **U_g5 0.924** | not discriminating |

- With so few events, neither R is a test; they are stated with their counts,
  as the design orders.
- **raytrace's upgrades agree** (U_g5 0.924; U 0.927 in the protocol view;
  hand-overs 12,271 against 12,136, ratio 0.951). Upgrades are reported, not
  predicted.
- Both runs: R_g5 ≤ R_b (the views forget only more), self-check 0, level 2.

## fft, streamcluster, volrend: not scored

Their ratios were not looked at. Each failure is a failure of the
comparison's precondition (the two simulators' instruction streams), not a
reading of the tool. Diagnoses, **all untested hypotheses**:

- **fft:** gem5 counts about twice the loads and the stores per instruction;
  neither side has an RMW. A factor near 2 on both fits gem5's x86 model
  issuing two 8-byte requests for each 16-byte SSE access, and fft's complex
  doubles move in 16-byte accesses. The barnes check already measured gem5
  counting memory micro-ops, not instructions (3-6% more there).
- **streamcluster:** stores 12% fewer in gem5 (3.28 against 2.88 per KI) while
  loads agree within 3%. Thread 1's trace holds about 5x the stores of the
  other three (0.81 M against 0.17 M in the window). Which gem5 CPU runs that
  thread's work, and whether gem5's window covers it, is not established.
- **volrend:** RMWs 6.7% more in gem5. Thread 0 holds most of them (3.25 per
  KI against 0.10-0.26 for the others), so the alignment of thread 0's window
  is the first thing to check.

## What it means

- **Step 4 gives no held-out test of agreement yet.** The paper cannot state
  held-out agreement from it. The agreement on the development programs
  (`sync_mx_g5_results_2026-10-27.md`) is untouched.
- By the design, "a failure is diagnosed, never tuned away": scoring any of
  the three needs its diagnosis first, pre-registered before any of its ratios
  is read.

## Next (the owner's choice)

1. LU non-contiguous, by rule (c): size, trace, run. There is no command for
   it yet.
2. Diagnose fft's stream check (the 16-byte hypothesis) before reading any of
   its ratios. If it holds, the check needs a per-request count on the trace
   side, as an amendment.
3. A discriminating held-out program: the two that qualify share too little.
4. Step 5 waited for step 4's scoring (owner, 2026-10-27). Before it is
   launched, amend `policy_rerun_design` (binary g6; Q3 = unexplained 0;
   barnes rows run but are not scored until barnes agrees).

## Tools changed today (tested)

- `b3_stream_check.py`: `window NAME MIX` makes a trace-count row from
  `trace_mix.c`'s running counts (it reproduces 15 of 15 committed rows of
  `trace_mix_v3.txt` from the audit's counts); the six programs and LU
  non-contiguous are listed under the held-out rule.
- `b3_score.py`: a gem5 rate of 0 printed as "-" instead of crashing the
  score (fft has none); output identical to before on the m2, g2 and v5 / x2
  / h2 / e2 scorings.
- `pull_results.sh`: retries the rows steps once on a lost connection and
  names the cause; counts our processes without counting itself.

## Commands

```bash
for each trace:  python3 scripts/b3_stream_check.py window <prog>_4t_window_t<i> simulator/results/newbench/traces/<prog>/raw<i>[_aligned].mix
python3 scripts/b3_stream_check.py extract simulator/results/gem5_b3 > bench/policy_sanity/gem5_mix_v4.txt
python3 scripts/b3_score.py gem5-rows > bench/policy_sanity/gem5_b3_rows_v4.txt
python3 scripts/b3_stream_check.py check bench/policy_sanity/trace_mix_v4.txt bench/policy_sanity/gem5_mix_v4.txt
python3 scripts/b3_score.py score bench/policy_sanity/phasea_rows_v25.txt bench/policy_sanity/b3_rows_v16.txt bench/policy_sanity/gem5_b3_rows_v4.txt n2@new
```
