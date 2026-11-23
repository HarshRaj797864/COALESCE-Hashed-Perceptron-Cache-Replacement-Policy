# Step 5 scored: the replacement policies on the final tool (2026-11-10)

Design: `policy_rerun_design_2026-10-19.md` (`d127873`), amendment 1
(2026-11-02) and amendment 2 (2026-11-10, `e4496a1`, before any P11-P14 number
was read). Scorer: `scripts/policy_score.py` (`c88dddb`, self-tested on a
made-up step 5 before any number was read). Binary `champsim_g6_1e3060c1`.
171 runs, ended 2026-11-07 23:58 server time.

## Result

| prediction | verdict | numbers |
|---|---|---|
| **P11** sharing keeps the order at one size (canneal, tau >= +0.5) | **FAILS, 2 of 4** | fixed 2 MB: 4c **+0.78**, 8c **+0.50**; 2 MB a core: 4c **+0.33**, 8c **+0.28** |
| **P12** sharing raises the stakes (canneal fixed 2 MB) | **HOLDS, 2 of 2** | best gain over LRU, shared vs private: 4c 13.92% vs 10.17% (Mockingjay both); 8c 13.18% (COALESCE) vs 3.21% (SRRIP) |
| **P13** the control (ocean, tau >= +0.7) | **HOLDS, 2 of 2** | fixed 2 MB +0.78; 2 MB a core +0.94 |
| **P14** 64 LLC MSHRs against 16 (canneal 4c fixed shared, tau >= +0.7) | **HOLDS** | tau +1.00: the 9 runs are identical line for line |

**How the design reads a P11 failure:** "sharing reorders policies there at
one LLC size. That is the claim A5 first made and then withdrew; it is
reported with the size control beside it." The size control (one regime,
fixed 2 MB against 2 MB a core):

| | private | shared |
|---|---|---|
| canneal 4c | +0.39 | +0.50 |
| canneal 8c | +0.17 | +0.39 |
| ocean 4c | +0.61 | +0.67 |

Changing only the LLC size reorders canneal as much as sharing does at 2 MB a
core (+0.17 to +0.50, against +0.28 / +0.33). As in A5's withdrawal
(`a5_size_control_2026-10-14.md`), the failure is not shown to be a sharing
effect: at 2 MB a core (8 / 16 MB) the policies sit closer together, and any
change of conditions reorders them. At fixed 2 MB, where the gains are large,
sharing keeps the order (+0.78, +0.50) and raises the stakes (P12).

**P14 is identical runs, not close ones.** A local control on `canneal_4t`
(1 M + 2 M, LRU, shared, level 2): LLC MSHRs 4 change the run (754 log lines
differ), 16 and 64 give identical logs. The setting reaches the LLC
(`legacy_environment.cc:841`); 16 is never the limit on canneal at 4 cores.

## Reported, no prediction

**Synchronised replay against the level-2 A5 rerun on drifting threads**
(shared, tau over 9): canneal 4c +1.00 / +1.00, 8c +0.94 / +0.83, 16c +0.94
/ +0.72, ocean 4c +0.83 / +0.83 (fixed 2 MB / 2 MB a core). Replaying the
synchronisation changes the policy conclusions little.

**COALESCE (arm B, architecture frozen), its place among 9:**

| | fixed 2 MB, shared | fixed 2 MB, private | 2 MB a core, shared | 2 MB a core, private |
|---|---|---|---|---|
| canneal 4c | 4th, +10.25% vs LRU; Mockingjay +13.92% | 6th, +1.18% | 7th, +2.71%; Mockingjay +5.68% | 9th, -8.51% |
| canneal 8c | **1st, +13.18%**; next Mockingjay, 0.67% behind | 5th, +1.03% | 8th, -0.68% | 9th, -7.67% |
| canneal 16c | **1st, +13.94%**; next SRRIP, 0.06% behind | -- | 8th, -0.66% (all 9 within 0.7%) | -- |
| ocean 4c | 6th, +4.48%; Mockingjay +22.73% | 4th, +17.32% | 7th, -6.12% | 7th, -25.56% |

At fixed 2 MB, shared, COALESCE leads at 8 and 16 cores by 0.67% and 0.06%;
these margins are small and come from one workload. It is weak whenever the
LLC is large or the regime private, and worst on ocean at 8 MB.

**Two anomalies, reported, not diagnosed:**
- **ocean 4c at 2 MB a core:** SRRIP and srrip_bias take 48-51% more cycles
  than LRU in both regimes (COALESCE 6.5% shared, 34.3% private). The level-2
  A5 rerun on drifting threads showed it already (SRRIP +23.2%, srrip_bias
  +23.7% shared), so synchronised replay did not create it; it grew.
- **canneal 16c at 2 MB a core (32 MB):** all 9 policies within 0.7%; LRU
  first. The LLC nearly holds the working set, so the policy hardly matters.

**barnes std:** all 36 runs pass every check; **not ranked** (amendment 1,
item 3: barnes does not agree with gem5).

## The checks (all hold)

- C1 171 of 171 complete (rows and logs); C2 no SYNC DEADLOCK, no end of
  trace, trace-wrap and page pool ok; C3 level 2, self-check 0,
  stale-holders 0, view-order unexplained 0; C4 `SYNC MUTEX ORDER: timing` in
  every run; C6 QT: canneal 16's threads 1-16 at 215.0 M each; C7 LLC MSHRs 64
  in the `_mshr64` runs, 16 elsewhere.
- C5, the standing row checks: one tie, barnes std 2 MB a core shared,
  srrip_bias = srrip at 111,577,821 cycles. Explained by amendment 2 (LLC
  counters differ; CPU 1 finishes last at the same cycle in both); barnes is
  not ranked anyway.

## Commands

```bash
scripts/pull_results.sh       # rows v29, b3 v20 (2026-11-10)
# step 5's logs, configs and canneal 16's .mix files (read-only rsync) to simulator/results/policy/
python3 scripts/policy_score.py logrows simulator/results/policy/logs simulator/results/policy/sync_pol/cfg > bench/policy_sanity/p2_log_rows_v1.txt
python3 scripts/policy_score.py score bench/policy_sanity/phasea_rows_v29.txt bench/policy_sanity/b3_rows_v20.txt \
  bench/policy_sanity/p2_log_rows_v1.txt simulator/results/policy/qt
```

The size control and the ocean comparison were computed with
`policy_score.tau` and the rows file, as above.

## The score, as printed

```
== P11: sharing keeps the order at one size (canneal 4 and 8; tau >= +0.5 at both sizes)
   canneal 4c, fixed 2 MB: shared vs private tau +0.78 over 9
   canneal 4c, 2 MB a core: shared vs private tau +0.33 over 9
   canneal 8c, fixed 2 MB: shared vs private tau +0.50 over 9
   canneal 8c, 2 MB a core: shared vs private tau +0.28 over 9
   P11 FAILS (2 of 4)

== P12: sharing raises the stakes (canneal fixed 2 MB: best gain over LRU, shared > private)
   canneal 4c: shared +13.92% (mockingjay), private +10.17% (mockingjay)
   canneal 8c: shared +13.18% (coalesce), private +3.21% (srrip)
   P12 HOLDS (2 of 2)

== P13: the control (ocean, both sizes; tau >= +0.7)
   ocean 4c, fixed 2 MB: shared vs private tau +0.78 over 9
   ocean 4c, 2 MB a core: shared vs private tau +0.94 over 9
   P13 HOLDS (2 of 2)

== P14: MSHRs (canneal 4c fixed shared, 64 against 16; tau >= +0.7)
   tau +1.00 over 9
   P14 HOLDS

== barnes std: every check above held; NOT ranked (amendment 1, item 3: barnes does not agree with gem5)

== Reported, no prediction: synchronised (this step) against the level-2 A5 rerun on drifting traces, shared
   canneal 4c, fixed 2 MB: tau +1.00 over 9
   canneal 4c, 2 MB a core: tau +1.00 over 9
   canneal 8c, fixed 2 MB: tau +0.94 over 9
   canneal 8c, 2 MB a core: tau +0.83 over 9
   canneal 16c, fixed 2 MB: tau +0.94 over 9
   canneal 16c, 2 MB a core: tau +0.72 over 9
   ocean 4c, fixed 2 MB: tau +0.83 over 9
   ocean 4c, 2 MB a core: tau +0.83 over 9

== Reported: the rankings (COALESCE is the case study; its architecture stays frozen)
   canneal 4c, fixed 2 MB, shared
     1. mockingjay     183,644,131  vs LRU +13.92%  gap to next  +0.44%
     2. hawkeye        184,459,627  vs LRU +13.42%  gap to next  +2.72%
     3. srrip          189,476,440  vs LRU +10.41%  gap to next  +0.15%
     4. coalesce       189,756,880  vs LRU +10.25%  gap to next  +1.41%  <- COALESCE (arm B)
     5. srrip_bias     192,425,289  vs LRU +8.72%  gap to next  +2.04%
     6. drrip          196,358,515  vs LRU +6.54%  gap to next  +2.84%
     7. ship           201,932,618  vs LRU +3.60%  gap to next  +3.60%
     8. lru            209,209,194  vs LRU +0.00%  gap to next  +0.55%
     9. random         210,364,230  vs LRU -0.55%  gap to next        
   canneal 4c, fixed 2 MB, private
     1. mockingjay     216,629,158  vs LRU +10.17%  gap to next  +1.62%
     2. hawkeye        220,140,390  vs LRU +8.41%  gap to next  +2.74%
     3. srrip          226,180,303  vs LRU +5.52%  gap to next  +3.16%
     4. srrip_bias     233,325,608  vs LRU +2.29%  gap to next  +0.42%
     5. drrip          234,298,247  vs LRU +1.86%  gap to next  +0.67%
     6. coalesce       235,870,022  vs LRU +1.18%  gap to next  +0.18%  <- COALESCE (arm B)
     7. random         236,283,955  vs LRU +1.01%  gap to next  +0.57%
     8. ship           237,635,340  vs LRU +0.43%  gap to next  +0.43%
     9. lru            238,663,463  vs LRU +0.00%  gap to next        
   canneal 4c, 2 MB a core, shared
     1. mockingjay     143,988,166  vs LRU +5.68%  gap to next  +0.03%
     2. srrip          144,031,037  vs LRU +5.65%  gap to next  +0.49%
     3. ship           144,737,171  vs LRU +5.13%  gap to next  +0.14%
     4. srrip_bias     144,937,131  vs LRU +4.99%  gap to next  +0.42%
     5. drrip          145,543,344  vs LRU +4.55%  gap to next  +1.07%
     6. hawkeye        147,101,339  vs LRU +3.44%  gap to next  +0.72%
     7. coalesce       148,154,025  vs LRU +2.71%  gap to next  +2.71%  <- COALESCE (arm B)
     8. lru            152,168,148  vs LRU +0.00%  gap to next  +4.56%
     9. random         159,106,552  vs LRU -4.36%  gap to next        
   canneal 4c, 2 MB a core, private
     1. mockingjay     184,555,167  vs LRU +8.86%  gap to next  +0.51%
     2. hawkeye        185,500,003  vs LRU +8.31%  gap to next  +4.37%
     3. drrip          193,602,521  vs LRU +3.78%  gap to next  +1.69%
     4. srrip          196,883,951  vs LRU +2.05%  gap to next  +2.05%
     5. lru            200,914,140  vs LRU +0.00%  gap to next  +0.60%
     6. ship           202,121,970  vs LRU -0.60%  gap to next  +2.53%
     7. random         207,228,795  vs LRU -3.05%  gap to next  +2.10%
     8. srrip_bias     211,574,203  vs LRU -5.04%  gap to next  +3.79%
     9. coalesce       219,596,940  vs LRU -8.51%  gap to next          <- COALESCE (arm B)
   canneal 8c, fixed 2 MB, shared
     1. coalesce       203,025,844  vs LRU +13.18%  gap to next  +0.67%  <- COALESCE (arm B)
     2. mockingjay     204,390,997  vs LRU +12.43%  gap to next  +0.01%
     3. srrip          204,401,974  vs LRU +12.42%  gap to next  +0.28%
     4. srrip_bias     204,964,084  vs LRU +12.11%  gap to next  +0.19%
     5. hawkeye        205,345,182  vs LRU +11.90%  gap to next  +4.20%
     6. drrip          213,979,395  vs LRU +7.39%  gap to next  +2.19%
     7. ship           218,665,432  vs LRU +5.09%  gap to next  +5.09%
     8. lru            229,788,386  vs LRU +0.00%  gap to next  +0.53%
     9. random         231,003,916  vs LRU -0.53%  gap to next        
   canneal 8c, fixed 2 MB, private
     1. srrip          260,348,636  vs LRU +3.21%  gap to next  +0.46%
     2. hawkeye        261,547,881  vs LRU +2.74%  gap to next  +0.26%
     3. mockingjay     262,224,888  vs LRU +2.47%  gap to next  +1.07%
     4. srrip_bias     265,035,673  vs LRU +1.38%  gap to next  +0.35%
     5. coalesce       265,963,553  vs LRU +1.03%  gap to next  +0.15%  <- COALESCE (arm B)
     6. drrip          266,368,506  vs LRU +0.88%  gap to next  +0.66%
     7. random         268,123,093  vs LRU +0.22%  gap to next  +0.01%
     8. ship           268,140,461  vs LRU +0.21%  gap to next  +0.21%
     9. lru            268,703,696  vs LRU +0.00%  gap to next        
   canneal 8c, 2 MB a core, shared
     1. srrip          131,722,420  vs LRU +1.42%  gap to next  +0.15%
     2. srrip_bias     131,919,813  vs LRU +1.26%  gap to next  +0.02%
     3. mockingjay     131,940,099  vs LRU +1.25%  gap to next  +0.02%
     4. ship           131,966,221  vs LRU +1.23%  gap to next  +0.34%
     5. hawkeye        132,408,649  vs LRU +0.89%  gap to next  +0.19%
     6. drrip          132,665,836  vs LRU +0.69%  gap to next  +0.69%
     7. lru            133,586,451  vs LRU +0.00%  gap to next  +0.68%
     8. coalesce       134,494,288  vs LRU -0.68%  gap to next  +3.53%  <- COALESCE (arm B)
     9. random         139,242,061  vs LRU -4.06%  gap to next        
   canneal 8c, 2 MB a core, private
     1. mockingjay     203,848,891  vs LRU +9.44%  gap to next  +0.87%
     2. hawkeye        205,628,296  vs LRU +8.50%  gap to next  +4.47%
     3. drrip          214,821,070  vs LRU +3.85%  gap to next  +1.36%
     4. srrip          217,742,297  vs LRU +2.46%  gap to next  +2.46%
     5. lru            223,100,599  vs LRU +0.00%  gap to next  +1.60%
     6. ship           226,662,042  vs LRU -1.57%  gap to next  +1.53%
     7. random         230,134,009  vs LRU -3.06%  gap to next  +0.92%
     8. srrip_bias     232,255,939  vs LRU -3.94%  gap to next  +4.04%
     9. coalesce       241,636,825  vs LRU -7.67%  gap to next          <- COALESCE (arm B)
   canneal 16c, fixed 2 MB, shared
     1. coalesce       230,646,301  vs LRU +13.94%  gap to next  +0.06%  <- COALESCE (arm B)
     2. srrip          230,790,314  vs LRU +13.86%  gap to next  +0.18%
     3. srrip_bias     231,198,345  vs LRU +13.66%  gap to next  +1.58%
     4. mockingjay     234,842,904  vs LRU +11.90%  gap to next  +1.08%
     5. hawkeye        237,388,141  vs LRU +10.70%  gap to next  +3.11%
     6. drrip          244,772,001  vs LRU +7.36%  gap to next  +2.16%
     7. ship           250,047,446  vs LRU +5.10%  gap to next  +5.10%
     8. lru            262,787,994  vs LRU +0.00%  gap to next  +1.08%
     9. random         265,623,722  vs LRU -1.07%  gap to next        
   canneal 16c, 2 MB a core, shared
     1. lru            123,880,290  vs LRU +0.00%  gap to next  +0.00%
     2. ship           123,883,730  vs LRU -0.00%  gap to next  +0.00%
     3. hawkeye        123,886,170  vs LRU -0.00%  gap to next  +0.00%
     4. mockingjay     123,888,095  vs LRU -0.01%  gap to next  +0.09%
     5. srrip          123,994,245  vs LRU -0.09%  gap to next  +0.04%
     6. srrip_bias     124,048,175  vs LRU -0.14%  gap to next  +0.25%
     7. drrip          124,353,610  vs LRU -0.38%  gap to next  +0.28%
     8. coalesce       124,704,574  vs LRU -0.66%  gap to next  +0.03%  <- COALESCE (arm B)
     9. random         124,745,735  vs LRU -0.69%  gap to next        
   ocean 4c, fixed 2 MB, shared
     1. mockingjay     298,792,964  vs LRU +22.73%  gap to next  +0.03%
     2. drrip          298,877,042  vs LRU +22.69%  gap to next  +4.62%
     3. hawkeye        312,690,513  vs LRU +17.27%  gap to next  +5.95%
     4. ship           331,300,465  vs LRU +10.68%  gap to next  +5.92%
     5. random         350,908,662  vs LRU +4.50%  gap to next  +0.02%
     6. coalesce       350,983,229  vs LRU +4.48%  gap to next  +4.48%  <- COALESCE (arm B)
     7. lru            366,694,882  vs LRU +0.00%  gap to next  +1.52%
     8. srrip_bias     372,263,054  vs LRU -1.50%  gap to next  +0.36%
     9. srrip          373,600,852  vs LRU -1.85%  gap to next        
   ocean 4c, fixed 2 MB, private
     1. drrip          298,683,893  vs LRU +23.40%  gap to next  +0.11%
     2. mockingjay     299,014,067  vs LRU +23.26%  gap to next  +4.34%
     3. hawkeye        311,988,382  vs LRU +18.14%  gap to next  +0.69%
     4. coalesce       314,147,668  vs LRU +17.32%  gap to next  +6.24%  <- COALESCE (arm B)
     5. ship           333,740,591  vs LRU +10.44%  gap to next  +5.71%
     6. random         352,806,330  vs LRU +4.47%  gap to next  +4.47%
     7. lru            368,569,467  vs LRU +0.00%  gap to next  +2.58%
     8. srrip          378,073,192  vs LRU -2.51%  gap to next  +0.16%
     9. srrip_bias     378,661,775  vs LRU -2.67%  gap to next        
   ocean 4c, 2 MB a core, shared
     1. hawkeye        200,938,626  vs LRU +3.88%  gap to next  +2.94%
     2. mockingjay     206,838,690  vs LRU +0.92%  gap to next  +0.33%
     3. drrip          207,521,308  vs LRU +0.59%  gap to next  +0.59%
     4. lru            208,739,203  vs LRU +0.00%  gap to next  +0.56%
     5. ship           209,912,100  vs LRU -0.56%  gap to next  +1.25%
     6. random         212,543,704  vs LRU -1.79%  gap to next  +4.61%
     7. coalesce       222,341,362  vs LRU -6.12%  gap to next +38.83%  <- COALESCE (arm B)
     8. srrip          308,679,384  vs LRU -32.38%  gap to next  +0.28%
     9. srrip_bias     309,556,624  vs LRU -32.57%  gap to next        
   ocean 4c, 2 MB a core, private
     1. mockingjay     205,758,345  vs LRU +2.23%  gap to next  +0.73%
     2. hawkeye        207,266,010  vs LRU +1.49%  gap to next  +0.88%
     3. drrip          209,086,434  vs LRU +0.60%  gap to next  +0.60%
     4. lru            210,347,424  vs LRU +0.00%  gap to next  +0.52%
     5. ship           211,434,085  vs LRU -0.51%  gap to next  +1.40%
     6. random         214,393,139  vs LRU -1.89%  gap to next +31.79%
     7. coalesce       282,558,041  vs LRU -25.56%  gap to next +12.12%  <- COALESCE (arm B)
     8. srrip          316,800,484  vs LRU -33.60%  gap to next  +0.03%
     9. srrip_bias     316,897,632  vs LRU -33.62%  gap to next        
   canneal 4c, fixed 2 MB, shared, 64 LLC MSHRs
     1. mockingjay     183,644,131  vs LRU +13.92%  gap to next  +0.44%
     2. hawkeye        184,459,627  vs LRU +13.42%  gap to next  +2.72%
     3. srrip          189,476,440  vs LRU +10.41%  gap to next  +0.15%
     4. coalesce       189,756,880  vs LRU +10.25%  gap to next  +1.41%  <- COALESCE (arm B)
     5. srrip_bias     192,425,289  vs LRU +8.72%  gap to next  +2.04%
     6. drrip          196,358,515  vs LRU +6.54%  gap to next  +2.84%
     7. ship           201,932,618  vs LRU +3.60%  gap to next  +3.60%
     8. lru            209,209,194  vs LRU +0.00%  gap to next  +0.55%
     9. random         210,364,230  vs LRU -0.55%  gap to next        
```
