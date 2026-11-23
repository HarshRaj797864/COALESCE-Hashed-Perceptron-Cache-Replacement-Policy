# streamcluster scored by held-out set 2's procedure: it agrees (2026-11-07)

Scored by the command fixed in Note 8 (`heldout2_design_2026-11-04.md`), on new
row files, as `heldout2_results_2026-11-06.md` said it would be once its run
ended. This follows newbench amendment 3 (`4baf804`): streamcluster is a step 4
program, re-traced under gem5's CPUID by nc's tracer and scored by set 2's
checks, with step 4's predictions P8-P10.

## Result

**streamcluster passes every check and agrees with gem5:**
- **R_g5 0.925**, in the band 0.5-2 (P8 holds);
- **R_b 0.927**, at least R_g5 (P9 holds);
- **traffic 0.987**, in 0.5-2 (P10 holds);
- gem5 counts 2,245 store misses that find another core in the window
  (at least 500: it discriminates);
- reported, deciding nothing: upgrades U_g5 1.063, in the band; hand-overs
  1.191; demand accesses 1.004 with ChampSim's upgrades added.

**The checks:**
- QB, QT, Q3, QG and QW hold;
- QC and v2 hold, with the native range;
- its run reads 0 deadlocks, 0 unexplained view-order violations and 0
  releases of a mutex not held.

**Unchanged from 2026-11-06:**
- fluidanimate 0.398 and vips 0.309 still fail P15;
- ocean non-contiguous (apart) 0.663 still agrees;
- set 2's target is still MET (2 of 4 counted programs pass every check and
  discriminate);
- streamcluster does not count toward set 2's target.

**Held-out programs that discriminate and are scored, as of this note:**
- agree: radix, LU non-contiguous and streamcluster;
- do not agree: fluidanimate and vips;
- ocean non-contiguous agrees but is reported apart.

## What changed in the inputs

The pull of 2026-11-07 (05:3x server time) produced `phasea_rows_v28`
(915 rows, 20 incomplete, all step 5's) and `b3_rows_v19`. The row makers were
rerun on the pulled files and compared with the versions set 2 was scored on.

| file | against | change |
|---|---|---|
| `h2_trace_rows_v2` | v1 | streamcluster's 5 lines only: its trace set done (tracer f39707f3, CPUID 74d72229, 215 M a thread), where v1 had it missing |
| `h2_run_rows_v2` | v1 | streamcluster's 1 line only: its run complete, where v1 had it absent |
| `h2_count_rows` | v1 | identical (v1 reused) |
| `h2_gem5_config` | v1 | identical (v1 reused) |
| `gem5_percpu` | v2 | identical (v2 reused) |
| `gem5_mix` | v6 | identical (v6 reused) |
| `gem5_b3_rows` | v6 | identical (v6 reused) |

No gem5 run was added: streamcluster's two gem5 runs are step 4's.

## Commands

```bash
scripts/pull_results.sh        # rows v28, b3 v19; set 2's reports and run logs, streamcluster's included
python3 scripts/heldout2_score.py tracerows simulator/results/heldout2/traces simulator/results/heldout2/server simulator/results/newbench/server > bench/policy_sanity/h2_trace_rows_v2.txt
python3 scripts/heldout2_score.py countrows simulator/results/heldout2/count     # = h2_count_rows_v1
python3 scripts/heldout2_score.py runrows simulator/results/heldout2/logs simulator/results/heldout2/driver.log > bench/policy_sanity/h2_run_rows_v2.txt
python3 scripts/heldout2_score.py gem5cfg simulator/results/gem5_b3              # = h2_gem5_config_v1
python3 scripts/stream_check2.py gem5rows simulator/results/gem5_b3              # = gem5_percpu_v2
python3 scripts/b3_stream_check.py extract simulator/results/gem5_b3             # = gem5_mix_v6
python3 scripts/b3_score.py gem5-rows                                            # = gem5_b3_rows_v6
python3 scripts/heldout2_score.py score bench/policy_sanity/h2_trace_rows_v2.txt bench/policy_sanity/h2_count_rows_v1.txt \
  bench/policy_sanity/h2_run_rows_v2.txt bench/policy_sanity/h2_gem5_config_v1.txt bench/policy_sanity/gem5_percpu_v2.txt \
  bench/policy_sanity/gem5_mix_v6.txt bench/policy_sanity/gem5_b3_rows_v6.txt bench/policy_sanity/phasea_rows_v28.txt bench/policy_sanity/b3_rows_v19.txt
```

## Not read

- Step 5's rows: 111 of 171 runs were complete on the server at 05:27, and
  `phasea_rows_v28` marks 20 rows incomplete. Step 5 is scored when it
  completes.
- Step 4's fft and volrend blocks.

## streamcluster's checks and score, as printed

```
== streamcluster (step 4 program, scored by set 2's procedure (newbench amendment 3)); traced threads 1,2,3,4
   QB    holds: step 4 sizing (CHOSEN; QB held then)
   QT    holds: tracer f39707f3, CPUID 74d72229, length rule applied (LEN 215000000); instructions t1 215.0 M, t2 215.0 M, t3 215.0 M, t4 215.0 M
   Q3    holds (view-order raw 0 = by silent re-listing 0; releases of a mutex not held 0, reported)
   QG    holds: 5 CPUs, /home/harshraj/splash-newbench/streamcluster, L2 2 MB, randomization false, stop on CPUs 1,2,3,4
   QW    holds: untraced CPUs 0 commit 0.000% of the traced CPUs' 388.3 M window instructions (under 1% needed); per CPU 0:0.00M 1:100.00M 2:96.11M 3:96.11M 4:96.12M
   QC    holds: per 1,000 records, the trace in the three gem5-CPUID runs' range (widened 1%; RMWs or 0.01): loads 284.231 in [284.232, 284.233]; stores 2.684 in [2.683, 2.684]; RMWs 0.005 in [0.005, 0.005]; host run 284.072, 3.278, 0.005
   v2    holds: per 1,000 instructions (gem5 units), gem5 in the three counter runs' range (widened 5%; RMWs or 0.05): loads 284.295 in [284.315, 284.315]; stores 2.878 in [2.806, 2.806]; RMWs 0.005 in [0.005, 0.005]
   500   holds: gem5 counts 2245 store misses that find another core in the window (SS + MT L1_GETX; at least 500)
   -> SCORED

   streamcluster 2MB   0.0058    0.0054  0.927  0.666  0.902 |    0.99     0.5620    0.00 | self-check 0
                 gem5 events 2245 (MT 2127, upgrades 60876), GETX all 17516, window 388348364 instr, per cpu [0, 100000000, 96110519, 96113136, 96124709]; ChampSim protocol 2154, LLC RFO 10191, 402031854 instr
                 level 2; upgrades 75681 (0.1882/KI; gem5 0.1568/KI; U = 1.201), by presence 66955; copies invalidated 136963 (0.3407/KI); stale fills 1529; stale-holders 0
                 hand-overs: ChampSim 77835 (0.1936/KI), gem5 63121 (0.1625/KI), ratio 1.191; demand accesses 10.4412 against 10.5819/KI; with ChampSim's upgrades added 10.6294, ratio 1.004
                 bounded view: R_bounded 0.926 (2153 events, protocol 2154; subset yes); bounded upgrades 67100 (U_bounded = 1.065) -- in the band
                 gem5-rule view: R_g5 0.925 (2150 events, 2210 cores; at most the bounded view's: yes; view-order violations 0); its upgrades 67017 (U_g5 = 1.063) -- in the band
                 streamcluster (newbench amendment 3: a step 4 program): P8 R_g5 0.925 holds; P9 R_b 0.927 >= R_g5: holds; P10 traffic 0.987 holds  (2245 gem5 events)

== The target (two counted programs that pass every check and discriminate): 2 of 4 (fluidanimate, vips) -> MET
   Agreement on them is P15 above; a P15 miss is stated beside it. ocean non-contiguous and streamcluster do not count toward it.
```
