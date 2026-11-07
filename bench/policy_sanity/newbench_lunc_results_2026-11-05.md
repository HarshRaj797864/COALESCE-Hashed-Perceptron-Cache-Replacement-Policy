# Step 4: LU non-contiguous scored. 2026-11-05

Pull of 2026-11-05 05:25 server time (`phasea_rows_v26.txt`,
`b3_rows_v17.txt`). Made today from the pulled files: `trace_mix_v5.txt`,
`gem5_mix_v5.txt`, `gem5_b3_rows_v5.txt`. Each is v4 plus LU
non-contiguous's rows; every v4 row is unchanged.

- Pre-registration: `newbench_design_2026-10-19.md`: the 2026-10-20
  amendment (`df6a32e`) and amendment 2, rule (c) (`d81d589`, `206159b`).
- Check in force: v1 (`stream_fix_results_2026-11-04.md`: F2 no, so lunc is
  traced with the host's CPUID and checked by v1).
- Binary `champsim_g6_1e3060c1`, level 2, mutex order by timing.
- Primary measure R_g5 (owner, 2026-10-27).

Nothing was tuned. Earlier result: `newbench_results_2026-11-01.md`.

## In one line

**LU non-contiguous is step 4's first discriminating held-out program, and
P8, P9 and P10 all hold on it.**

- gem5 counts 37,519 store misses that find another core in the window.
  The design requires at least 500.
- R_g5 = 1.831, inside the 0.5-2 band but near its top.
- ChampSim counts 2.4x gem5's upgrades. Upgrades are reported, not predicted.

## The program

- **Replaces radiosity, by rule (c):** radiosity's trace never found its
  anchor.
- **Input `-n1024 -p4 -b16`, sized by the size rule.**
  - Rung 1 of the ladder `-n1024`, `-n2048`.
  - Pin's counter gave 759-889 M instructions a thread. The rule needs 300 M.
- **Note on the input:** the design's text names `-n2048 -p4 -b16`, but the
  ladder is in the server script committed with the same amendment
  (`df6a32e`, 2026-10-20). That was before LU non-contiguous was sized,
  traced or run. lu's ladder is the same (N = 1024, 2048). The trace, the
  ChampSim run and both gem5 runs all use `-n1024`.
- **QB holds:** all 17 functions of LU's objects are equal in instruction
  count and constants in the dynamic and static binaries.

## Qualifying checks

- **QT holds (`DONE`).**
  - The first trace (215 M a thread) was too short after the cut (122.5 M).
  - Amendment 2's length rule, applied once: anchor 92,473,486, so the trace
    was redone at 310 M a thread.
  - On the second trace, thread 0's anchor (its last `pthread_create`) fell
    at 92,474,146, 660 instructions later than in the first trace. Each
    trace is cut at its own anchor.
  - 217.5 M records are kept after the cut; at least 172.5 M are needed.
  - Every sync call that entered returned, on all four threads.
- **Q3 holds:**
  - the run completed;
  - SYNC DEADLOCK 0, end of trace 0;
  - self-check 0, stale-holders 0;
  - view-order violations 0, unexplained 0.
  - The log reports 1 release of a mutex not held. lu's run reports the
    same: a lock taken by thread 0 before the cut is not in its trace.
- **gem5:** both runs ended at the worker stop ("a thread reached the max
  instruction count"). Both ran the static `LU-NC -n1024 -p4 -b16`.
- **Same stream (v1, the held-out rule): the same stream.** Per 1,000
  instructions, trace / gem5:

  | | trace | gem5 | gem5 / trace |
  |---|---|---|---|
  | with a load | 235.005 | 235.012 | 1.000 |
  | with a store | 113.872 | 113.876 | 1.000 |
  | read-modify-write | 0.001 | 0.001 | 1.053 (0.00005 per 1,000 apart; up to 0.05 allowed) |

  The other programs' verdicts are as on 2026-11-01. The check's output
  differs from v4's only in lunc's lines.

## The score

`b3_score.py score phasea_rows_v26.txt b3_rows_v17.txt gem5_b3_rows_v5.txt
n2@new`. Only lunc's block of its output was read. lu's and raytrace's
blocks were compared, without being printed, to the 2026-11-01 scoring:
they are identical.

| | value |
|---|---|
| gem5 events in the window (SS + MT) | **37,519** (MT 37,514); window 394.2 M instructions |
| ChampSim gem5-rule events | 72,366; 415.2 M instructions |
| **R_g5** | **1.831**: in the band, **P8 holds** |
| R_b (protocol view) | 1.831 ≥ R_g5: **P9 holds** (R_a 1.831, R_bounded 1.831) |
| shared-cache demand traffic | 10.78 against 9.72 per 1,000, **1.109: P10 holds** |
| upgrades, ChampSim / gem5 | 8.23 / 3.48 per 1,000: **U_g5 2.361** (reported, not predicted) |
| hand-overs | 8.41 / 3.58 per 1,000, ratio 2.349 |

Arithmetic check: (72,366 / 415.18 M) / (37,519 / 394.20 M) = 0.17430 /
0.09518 = 1.831.

## What it means

- **Step 4 now has a held-out test of agreement, on one program.** It agrees
  on the primary measure and on traffic.
- The paper may state it, with the rest of step 4 beside it:
  - lu and raytrace pass the same-stream check, but share too little to
    discriminate;
  - fft, streamcluster and volrend fail the same-stream check and stay
    unscored.
- **R_g5 at 1.83 is the highest of any program in the band so far.** The
  next is canneal at 8 cores, 1.537 (`sync_mx_g5_results_2026-10-27.md`).
  ChampSim sees more transfers of ownership than gem5 on this program:
  - store misses that find another core: 1.8x;
  - upgrades and hand-overs: 2.4x.

  Neither was predicted, and neither is diagnosed. It is stated beside the
  result, not explained away.
- **Held-out set 2's target is unchanged:** at least 2 more counted programs
  that pass and discriminate (`heldout2_design_2026-11-04.md`).

## Not read

- **Step 5's rows.** 7 of 171 had completed in `phasea_rows_v26.txt` and
  `b3_rows_v17.txt`. Step 5 is scored when it completes.
- **fft's, streamcluster's and volrend's blocks of the score output.**
- **Held-out set 2:** no ratio and no sharing event was read.
  - `b3_stream_check.py extract` over the whole gem5 tree printed, once, its
    gem5 request counts by type (loads, stores, RMWs, instruction fetches).
    These are not sharing events, and nothing is set from them.
  - The v5 files were then built from a copy of the gem5 tree without
    `heldout2/`, so they hold step 4's runs only.
  - `b3_score.py gem5-rows` over the whole tree stops on the two stopped
    bodytrack runs and the two stopped vips runs (`.prev_*`, Note 3). Each
    has 0 statistics dumps. Stopping there is correct.

## Commands

```bash
for i in 0 1 2 3: python3 scripts/b3_stream_check.py window lunc_4t_window_t$i simulator/results/newbench/traces/lunc/raw$i.mix   # thread 0: raw0_aligned.mix; appended to a copy of v4
rsync -a --exclude=heldout2 simulator/results/gem5_b3/ <copy>/gem5_b3/
python3 scripts/b3_stream_check.py extract <copy>/gem5_b3 > bench/policy_sanity/gem5_mix_v5.txt
python3 scripts/b3_score.py gem5-rows <copy>/gem5_b3 > bench/policy_sanity/gem5_b3_rows_v5.txt
python3 scripts/b3_stream_check.py check bench/policy_sanity/trace_mix_v5.txt bench/policy_sanity/gem5_mix_v5.txt
python3 scripts/b3_score.py score bench/policy_sanity/phasea_rows_v26.txt bench/policy_sanity/b3_rows_v17.txt bench/policy_sanity/gem5_b3_rows_v5.txt n2@new   # lunc's block only
```

## Also checked: the pull's "pin 0"

The pull's process line read "champsim 16, pin 0, gem5 0" at 05:25:50 server
time, 14 minutes after held-out set 2's tracing chain started.

- **The count itself works.** On the laptop, a process traced by Pin shows
  the tool's path (`champsim_tracer`) in its command line.
- **So no tracer was running at that moment.** That fits the chain being
  between Pin runs:
  - after Pin ends, the chain cuts and checks the traces with no Pin
    running;
  - for lunc this took about 7 minutes (12:39:44 to 12:46:53).
- **The pull has no held-out set 2 section.** Its state is read only with
  `scripts/heldout2_all.sh status`.
- **Resolved the same day, from that status:** bodytrack's traces were
  finished 17 s before the pull's count, and all five programs were traced
  by 05:54:04. The count caught a gap between Pin runs.
