# Every program that does not agree: round 1 results. 2026-11-06

Pre-registration: `disagree_diagnosis_design_2026-11-06.md` (`856c5d5`),
amendment 1 (`4f6da76`), both committed before the script ran. Script:
`scripts/disagree_diag.py`. Its whole output is at the end.

Only pulled files were read. Nothing ran on the server. Nothing was tuned.

## In one line

**The untraced main thread does not explain fluidanimate, and may explain
vips. Contended locks fit fluidanimate and barnes-256 in size, but not
barnes std's window span in the form the note tested. By the note's rules,
H-C is PARTIAL.**

The clearest pattern is one the rules did not score:
- every failing span except vips spends 2.8-65% of its cycles waiting for a
  mutex in ChampSim;
- every agreeing span except barnes's force span spends under 0.05%.

## The hand check

fluidanimate's D from the script: 43,879 − 2 × 18,681 × 386,005,066 /
412,469,354 = 8,914. This equals the hand value from the score.

## T1 (H-A): the untraced CPUs

| program | untraced gem5 CPUs | their L2 -> L1 messages in the window (M_u) | D | verdict |
|---|---|---|---|---|
| fluidanimate | 0 | **84** | 8,914 | **H-A rejected** (M_u < 0.1 D) |
| vips | 0, 1, 2 | 1,262 + 168 + 0 = **1,430** | 1,240 | **H-A can explain it** (M_u ≥ D, an upper bound) |
| bodytrack (reported) | 0, 5 | 13,319 + 5,783 = 19,102 | 7,971 | (QW already failed: CPU 0 works in the window) |
| canneal 4c (control) | 0 | 4 | in the band | |
| canneal 8c (control) | 0 | 0 | in the band | |

- The expectation for fluidanimate (M_u < D) held.
- canneal's idle main thread is found by almost nothing, and canneal agrees.
- vips's CPU 0 commits 22,584 instructions in the window and receives
  1,262 messages. Its main thread is idle, but it is still giving lines to
  the workers.

## T2 (H-C): contention

| span | role | E (gem5's excess RMWs) | E / D | E / G | W (ChampSim cycles held for a mutex) | S (gem5 syscalls, see below) |
|---|---|---|---|---|---|---|
| fluidanimate | fails | 19,112 | **2.14** | 0.436 | **2.83%** (471,353 acquires) | 0 |
| vips | fails | 921 | 0.74 | 0.284 | 0.075% (1,200) | 104 |
| barnes std window | fails | **−28,901** | −1.28 | −0.644 | **14.31%** (749,484) | 7,022 |
| barnes-256 | fails | 290,921 | **2.12** | 0.985 | **65.50%** (3,222,281) | 13,783 |
| barnes std start | fails | not computed (stream not established) | | | **15.82%** (274,412) | 18,795 |
| barnes std force | agrees | 7,470 | (in band) | 10.55 | **10.86%** (407,838) | 2 |
| ocean 2 MB | agrees | 1,036 | | 0.037 | 0.036% | 839 |
| canneal 4c | control | −2,326 | | −0.026 | 0.020% (4 acquires) | 0 |
| canneal 8c | control | 3,249 | | 0.012 | 0.041% (8) | 0 |
| radix | control | −998 | | −0.027 | 0.0009% (70) | 10 |
| lunc | agrees | 19 | | 0.001 | 0.0024% | 29 |
| ocean non-contiguous | agrees | 1,466 | | 0.048 | 0.035% | 1,033 |
| bodytrack (reported) | | −435,394 | | | 0.012% | 19 |

**The rules:**
- (a) E ≥ D on fluidanimate (2.14 D) and barnes-256 (2.12 D). **Not on
  barnes std window (E < 0).** So (a) fails.
- (b) **Fails on fluidanimate (S = 0), because S measures the wrong
  thing.** gem5 dumps `numSyscalls` only for `system.cpu0.workload`. The
  worker threads are cloned processes, and their system calls are not in
  the dump (checked: one such stat per run). So S counts the main thread's
  calls only.
  - fluidanimate's main thread waits in `pthread_join` through the window,
    hence 0.
  - The note assumed S was process-wide. That was wrong, and (b) as written
    cannot be met on a program whose main thread is idle.
  - W > 0 on all three.
- (c) E < 0.1 G on canneal 4c (−0.026), canneal 8c (0.012) and radix
  (−0.027): **holds.**
- (d) vips: E + M_u = 2,351 ≥ D = 1,240: **holds.**
- Rejection rule (E < 0.1 D on two of the three in (a)): not met; only
  barnes std window.
- **Verdict by the note: H-C PARTIAL.**

**What E cannot show (barnes's force span):** E is 10.5 times gem5's events
there, and the span agrees. Extra RMWs need not be cross-core store misses.
So E bounds the effect from above; it does not measure it. That is how the
note used it.

## T3 (H-B): drift

| span | ChampSim cores apart (median, max) | gem5's traced CPUs at the stop (spread) |
|---|---|---|
| fluidanimate | 4.50, 8.57 M | 7.61 M |
| **vips** | **10.94, 12.89 M** | **1.14 M** |
| barnes std window | 6.49, 23.30 M | 22.84 M |
| **barnes-256** | **20.57, 22.26 M** | 13.17 M |
| barnes std start | 0.57, 0.69 M | 12.24 M |
| barnes std force | 6.57, 7.22 M | 12.14 M |
| ocean 2 MB | 1.39, 3.51 M | 1.92 M |
| canneal 4c / 8c | 0.78 / 0.70 M | 0.68 / 0.92 M |
| radix | 0.92 M | 0.21 M |
| lunc | 4.58 M | 89.08 M (CPU 0 is not a stop CPU) |
| ocean non-contiguous | 1.81 M | 1.94 M |

- **vips's cores drift ten times further apart in ChampSim than in gem5.**
  barnes-256's drift more too. The other failing spans do not.
- T3 decides nothing alone.

## Reading

- **fluidanimate:**
  - Not its untraced CPU: 84 messages against the 8,914 events needed.
  - In size, consistent with contended locks: gem5 executes 19,112 more RMWs
    than the native run, 2.1 times the shortfall, while ChampSim's cores
    wait for mutexes 2.8% of the time.
  - Not established.
- **vips:** three candidates, none established:
  - its main thread's CPU hands lines to the workers (an upper bound of
    1,430 events against 1,240 needed);
  - gem5's excess RMWs (921);
  - **a drift of 10.9 M in ChampSim against 1.1 M in gem5.** Its threads
    may synchronise through something the tracer does not record.
- **barnes-256:** consistent with contended locks in size (E = 2.1 D).
  ChampSim's cores spend 65% of their cycles waiting for a mutex.
- **barnes std window:** not explained in round 1. gem5 executes fewer RMWs
  than the replayed trace (E < 0), yet ChampSim waits 14% of its cycles.
- **The controls are clean.** canneal 4c and 8c and radix have E within
  ±3% of G and W under 0.05%. ocean, lunc and ocean non-contiguous have E
  within 5% of G and W under 0.05%.

## Found after the run, from the tracer's code: a sharper form of H-C (a new hypothesis, not a result)

`simulator/tracer/pin/champsim_tracer.cpp` (`SyncEnter`, `SyncExit`):
- The tracer buffers `pthread_mutex_lock`'s own instructions.
- At the call's exit it writes the ACQUIRE record **before** them ("the
  acquire goes before the held instructions").

ChampSim holds a waiting core at that record. The lock's instructions,
including any slow-path retries the native run made, are replayed only
**after** the core has been granted the mutex. By then no other core holds
the lock word.

In gem5 (and natively), a waiting thread's failed `lock cmpxchg` and its
`xchg` in `__lll_lock_wait` take the lock word's line from the holder, while
the holder is still inside its critical section. The holder's unlock then
takes it back, and the waiter's retry takes it again. So:
- **a contended acquire costs gem5 about three cross-core store misses on
  the lock word;**
- **ChampSim makes one** (the granted core's first lock instruction).

**H-C2:** the missing events are lock-word transfers during the wait. Their
number follows the count of contended acquires, not the count of RMWs.
- This is why E (a count) can be negative on barnes std window while the
  events are still missing.
- It was formed after reading round 1's numbers, so it is a hypothesis to
  test, not a finding.

**How to test it before building anything (round 2, proposed):**
1. A **records-only** ChampSim counter: acquires that had to wait, per core,
   in the measured window. It changes no behaviour (Q0: every other line
   identical).
2. A pre-registered prediction from glibc 2.39's `lll_lock` /
   `__lll_lock_wait` / `lll_unlock` code: R_g5 with k × N_waited events
   added, for the k the code gives. fluidanimate, barnes-256, barnes std
   start and window should then move into the band, and every agreeing
   span stay in it.
3. Only if that holds: **F-C**, the replay issues the waiter's lock-word
   accesses while it waits. This is its own note, built and checked
   locally (an exact micro case), then server runs on the owner's word.

## Not results

- **bodytrack's R_g5 (0.350)** is printed by the script beside its T1-T3
  numbers. bodytrack failed QW, so this is not a result, as for fmm on
  2026-10-17.
- **No fix was built or run.**

## The whole output

```
== Round 1 (disagree_diagnosis_design_2026-11-06.md + amendment 1); pulled files only

== fluidanimate (fail); ChampSim phaseA_b3_h2_fluidanimate4 (simulator/results/heldout2/logs/phaseA_b3_h2_fluidanimate4/regime_shared/fluidanimate_4core/lru/run.log); gem5 heldout2/fluidanimate/l2_2MB_mi50M/fluidanimate_4c -> heldout2/fluidanimate/l2_2MB_mi150M/fluidanimate_4c
   G 43879 events in I_g 386005066 instr; C 18681 in I_c 412469354; R_g5 0.398; D = 43879 - 2*18681*386005066/412469354 = 8914
   T1  gem5 CPUs 5, traced 1,2,3,4, untraced 0; L2->L1 messages in the window by CPU {0: 84, 1: 84959, 2: 92392, 3: 86707, 4: 91474}; M_u 84 = 0.01 D
   T2  gem5 RMWs 1248467 in 386005066 instr = 3.2343/KI; native 3.1848/KI (counter, gem5-CPUID runs 3.1848 / 3.1848 / 3.1848 (the highest))
       E 19112 = 2.14 D = 0.436 G; S (gem5 syscalls) 0; W 12106315 cycles held for a mutex over 471353 acquires = 2.8303% of 427734270 cycles; per CPU {0: (95730, 2741887), 1: (129349, 2994466), 2: (106297, 3063954), 3: (139977, 3306008)}
   T3  ChampSim cores apart (heartbeats): median 4.50 M, max 8.57 M; gem5 traced CPUs at the l2_2MB_mi150M stop: [142.39, 147.84, 142.79, 150.0] M, spread 7.61 M

== vips (fail); ChampSim phaseA_b3_h2_vips4 (simulator/results/heldout2/logs/phaseA_b3_h2_vips4/regime_shared/vips_4core/lru/run.log); gem5 heldout2/vips/l2_2MB_mi50M/vips_4c -> heldout2/vips/l2_2MB_mi150M/vips_4c
   G 3242 events in I_g 398703787 instr; C 1032 in I_c 411131895; R_g5 0.309; D = 3242 - 2*1032*398703787/411131895 = 1240
   T1  gem5 CPUs 7, traced 3,4,5,6, untraced 0,1,2; L2->L1 messages in the window by CPU {0: 1262, 1: 168, 2: 0, 3: 159169, 4: 153308, 5: 172208, 6: 150926}; M_u 1430 = 1.15 D
   T2  gem5 RMWs 87832 in 398703787 instr = 0.2203/KI; native 0.2180/KI (counter, gem5-CPUID runs 0.2173 / 0.2180 / 0.2173 (the highest))
       E 921 = 0.74 D = 0.284 G; S (gem5 syscalls) 104; W 309825 cycles held for a mutex over 1200 acquires = 0.0751% of 412637101 cycles; per CPU {0: (327, 117321), 1: (297, 86067), 2: (286, 10302), 3: (290, 96135)}
   T3  ChampSim cores apart (heartbeats): median 10.94 M, max 12.89 M; gem5 traced CPUs at the l2_2MB_mi150M stop: [148.86, 149.96, 148.98, 150.0] M, spread 1.14 M

== barnes std window (fail); ChampSim phaseA_b3_g3_barnesstd4 (simulator/results/sync_g6/logs/phaseA_b3_g3_barnesstd4/regime_shared/barnes_4core/lru/run.log); gem5 barnes/l2_2MB_mi50M/barnes_4c -> barnes/l2_2MB_mi150M/barnes_4c
   G 44867 events in I_g 401940250 instr; C 12082 in I_c 435383460; R_g5 0.249; D = 44867 - 2*12082*401940250/435383460 = 22559
   T1  gem5 CPUs 4, traced 0,1,2,3, untraced none; L2->L1 messages in the window by CPU {0: 69692, 1: 65106, 2: 65992, 3: 69253}; M_u 0
   T2  gem5 RMWs 4254692 in 401940250 instr = 10.5854/KI; native 10.6573/KI (replayed traces sync_mx/barnesstd, records [37.9 M, 137.9 M), 4262915 RMWs in 400000000 records)
       E -28901 = -1.28 D = -0.644 G; S (gem5 syscalls) 7022; W 68250158 cycles held for a mutex over 749484 acquires = 14.3111% of 476902915 cycles; per CPU {0: (189197, 16123432), 1: (187040, 16792265), 2: (187456, 18046031), 3: (185791, 17288430)}
   T3  ChampSim cores apart (heartbeats): median 6.49 M, max 23.30 M; gem5 traced CPUs at the l2_2MB_mi150M stop: [146.15, 142.28, 150.0, 127.16] M, spread 22.84 M

== barnes-256 (fail); ChampSim phaseA_b3_g3_barnes4 (simulator/results/sync_g6/logs/phaseA_b3_g3_barnes4/regime_shared/barnes_4core/lru/run.log); gem5 barnes_leaf256/l2_2MB_mi50M/barnes_4c -> barnes_leaf256/l2_2MB_mi150M/barnes_4c
   G 295420 events in I_g 400177469 instr; C 81202 in I_c 411617099; R_g5 0.267; D = 295420 - 2*81202*400177469/411617099 = 137530
   T1  gem5 CPUs 4, traced 0,1,2,3, untraced none; L2->L1 messages in the window by CPU {0: 319298, 1: 269757, 2: 406400, 3: 259982}; M_u 0
   T2  gem5 RMWs 10938650 in 400177469 instr = 27.3345/KI; native 26.6075/KI (replayed traces sync_mx/barnes256, records [50 M, 150 M), 10643007 RMWs in 400000000 records)
       E 290921 = 2.12 D = 0.985 G; S (gem5 syscalls) 13783; W 324909133 cycles held for a mutex over 3222281 acquires = 65.4976% of 496062911 cycles; per CPU {0: (819718, 80139721), 1: (827006, 80205265), 2: (791148, 82898914), 3: (784409, 81665233)}
   T3  ChampSim cores apart (heartbeats): median 20.57 M, max 22.26 M; gem5 traced CPUs at the l2_2MB_mi150M stop: [150.0, 137.98, 136.83, 138.19] M, spread 13.17 M

== barnes std start (fail-noE); ChampSim phaseA_b3_g3_barnesstd4_start (simulator/results/sync_g6/logs/phaseA_b3_g3_barnesstd4_start/regime_shared/barnes_4core/lru/run.log); gem5 None -> barnes/l2_2MB_mi50M/barnes_4c
   G 123076 events in I_g 163653240 instr; C 26838 in I_c 153244676; R_g5 0.233; D = 123076 - 2*26838*163653240/153244676 = 65754
   T1  gem5 CPUs 4, traced 0,1,2,3, untraced none; L2->L1 messages in the window by CPU {0: 138600, 1: 134334, 2: 143417, 3: 144868}; M_u 0
   T2  gem5 RMWs 2081238 in 163653240 instr = 12.7174/KI; native - (not computed (stream not established))
       E -; S (gem5 syscalls) 18795; W 25572838 cycles held for a mutex over 274412 acquires = 15.8235% of 161613009 cycles; per CPU {0: (74988, 6528660), 1: (63922, 5513871), 2: (70840, 6993467), 3: (64662, 6536840)}
   T3  ChampSim cores apart (heartbeats): median 0.57 M, max 0.69 M; gem5 traced CPUs at the l2_2MB_mi50M stop: [50.0, 37.95, 37.94, 37.76] M, spread 12.24 M

== bodytrack (reported); ChampSim phaseA_b3_h2_bodytrack4 (simulator/results/heldout2/logs/phaseA_b3_h2_bodytrack4/regime_shared/bodytrack_4core/lru/run.log); gem5 heldout2/bodytrack/l2_2MB_mi50M/bodytrack_4c -> heldout2/bodytrack/l2_2MB_mi150M/bodytrack_4c
   G 26542 events in I_g 415128508 instr; C 9307 in I_c 416086207; R_g5 0.350; D = 26542 - 2*9307*415128508/416086207 = 7971
   T1  gem5 CPUs 6, traced 1,2,3,4, untraced 0,5; L2->L1 messages in the window by CPU {0: 13319, 1: 21472, 2: 22790, 3: 21903, 4: 21658, 5: 5783}; M_u 19102 = 2.40 D
   T2  gem5 RMWs 8758653 in 415128508 instr = 21.0987/KI; native 22.1475/KI (counter, gem5-CPUID runs 22.1475 / 21.9441 / 22.0677 (the highest))
       E -435394 = -54.62 D = -16.404 G; S (gem5 syscalls) 19; W 38059 cycles held for a mutex over 1776 acquires = 0.0123% of 309396123 cycles; per CPU {0: (446, 10835), 1: (438, 12972), 2: (455, 7316), 3: (437, 6936)}
   T3  ChampSim cores apart (heartbeats): median 4.85 M, max 12.32 M; gem5 traced CPUs at the l2_2MB_mi150M stop: [150.0, 148.82, 148.94, 148.83] M, spread 1.18 M

== barnes std force (agree); ChampSim phaseA_b3_g3_barnesstd4_force (simulator/results/sync_g6/logs/phaseA_b3_g3_barnesstd4_force/regime_shared/barnes_4core/lru/run.log); gem5 barnes/l2_2MB_mi50M/barnes_4c -> barnes/l2_2MB_mi100M/barnes_4c
   G 708 events in I_g 200018516 instr; C 453 in I_c 201991713; R_g5 0.634; D = 708 - 2*453*200018516/201991713 = -189
   T1  gem5 CPUs 4, traced 0,1,2,3, untraced none; L2->L1 messages in the window by CPU {0: 10042, 1: 11163, 2: 11424, 3: 9879}; M_u 0
   T2  gem5 RMWs 1992266 in 200018516 instr = 9.9604/KI; native 9.9231/KI (replayed traces sync_mx/barnesstd, records [37.9 M, 87.9 M), 1984612 RMWs in 200000000 records)
       E 7470 = 10.551 G; S (gem5 syscalls) 2; W 25577357 cycles held for a mutex over 407838 acquires = 10.8571% of 235581859 cycles; per CPU {0: (105198, 5755885), 1: (100802, 5996404), 2: (98087, 6538558), 3: (103751, 7286510)}
   T3  ChampSim cores apart (heartbeats): median 6.57 M, max 7.22 M; gem5 traced CPUs at the l2_2MB_mi100M stop: [100.0, 87.9, 87.91, 87.86] M, spread 12.14 M

== ocean 2 MB (agree); ChampSim phaseA_b3_g3_ocean4 (simulator/results/sync_g6/logs/phaseA_b3_g3_ocean4/regime_shared/ocean_4core/lru/run.log); gem5 l2_2MB_mi50M/ocean_4c -> l2_2MB_mi150M/ocean_4c
   G 27649 events in I_g 397195762 instr; C 19109 in I_c 402687798; R_g5 0.682; D = 27649 - 2*19109*397195762/402687798 = -10048
   T1  gem5 CPUs 4, traced 0,1,2,3, untraced none; L2->L1 messages in the window by CPU {0: 1080701, 1: 1125103, 2: 1091364, 3: 1062490}; M_u 0
   T2  gem5 RMWs 20987 in 397195762 instr = 0.0528/KI; native 0.0502/KI (replayed traces sync_mx/ocean4, records [50 M, 150 M), 20092 RMWs in 400000000 records)
       E 1036 = 0.037 G; S (gem5 syscalls) 839; W 563355 cycles held for a mutex over 4211 acquires = 0.0362% of 1554568644 cycles; per CPU {0: (1166, 239125), 1: (1029, 144635), 2: (892, 73179), 3: (1124, 106416)}
   T3  ChampSim cores apart (heartbeats): median 1.39 M, max 3.51 M; gem5 traced CPUs at the l2_2MB_mi150M stop: [150.0, 148.08, 148.19, 149.75] M, spread 1.92 M

== canneal 4c 2 MB (agree-ctl); ChampSim phaseA_b3_g3_canneal4 (simulator/results/sync_g6/logs/phaseA_b3_g3_canneal4/regime_shared/canneal_4core/lru/run.log); gem5 canneal/l2_2MB_mi50M/canneal_4c -> canneal/l2_2MB_mi150M/canneal_4c
   G 89307 events in I_g 399351235 instr; C 91207 in I_c 401547440; R_g5 1.016; D = 89307 - 2*91207*399351235/401547440 = -92109
   T1  gem5 CPUs 5, traced 1,2,3,4, untraced 0; L2->L1 messages in the window by CPU {0: 4, 1: 320538, 2: 321201, 3: 320262, 4: 319632}; M_u 4
   T2  gem5 RMWs 4656175 in 399351235 instr = 11.6593/KI; native 11.6652/KI (replayed traces sync_mx/canneal4, records [50 M, 150 M), 4666069 RMWs in 400000000 records)
       E -2326 = -0.026 G; S (gem5 syscalls) 0; W 188667 cycles held for a mutex over 4 acquires = 0.0204% of 923914393 cycles; per CPU {0: (1, 89527), 1: (1, 64233), 2: (1, 0), 3: (1, 34907)}
   T3  ChampSim cores apart (heartbeats): median 0.78 M, max 1.77 M; gem5 traced CPUs at the l2_2MB_mi150M stop: [150.0, 149.32, 149.55, 149.42] M, spread 0.68 M

== canneal 8c (agree-ctl); ChampSim phaseA_b3_g3_canneal8 (simulator/results/sync_g6/logs/phaseA_b3_g3_canneal8/regime_shared/canneal_8core/lru/run.log); gem5 canneal8/l2_2MB_mi50M/canneal_8c -> canneal8/l2_2MB_mi150M/canneal_8c
   G 260815 events in I_g 798080015 instr; C 403703 in I_c 803586534; R_g5 1.537; D = 260815 - 2*403703*798080015/803586534 = -541058
   T1  gem5 CPUs 9, traced 1,2,3,4,5,6,7,8, untraced 0; L2->L1 messages in the window by CPU {0: 0, 1: 554674, 2: 553464, 3: 554197, 4: 554729, 5: 552154, 6: 553144, 7: 557360, 8: 556417}; M_u 0
   T2  gem5 RMWs 9248346 in 798080015 instr = 11.5882/KI; native 11.5842/KI (replayed traces sync_mx/canneal8, records [50 M, 150 M), 9267338 RMWs in 800000000 records)
       E 3249 = 0.012 G; S (gem5 syscalls) 0; W 821660 cycles held for a mutex over 8 acquires = 0.0410% of 2005084844 cycles; per CPU {0: (1, 0), 1: (1, 201141), 2: (1, 144155), 3: (1, 87161), 4: (1, 61068), 5: (1, 35012), 6: (1, 175056), 7: (1, 118067)}
   T3  ChampSim cores apart (heartbeats): median 0.70 M, max 1.30 M; gem5 traced CPUs at the l2_2MB_mi150M stop: [149.93, 149.34, 149.49, 149.22, 149.08, 149.26, 150.0, 149.94] M, spread 0.92 M

== radix (agree-ctl); ChampSim phaseA_b3_g3_radix4 (simulator/results/sync_g6/logs/phaseA_b3_g3_radix4/regime_shared/radix_4core/lru/run.log); gem5 heldout/radix/l2_2MB_mi830M/radix_4c -> heldout/radix/l2_2MB_mi930M/radix_4c
   G 36869 events in I_g 400067203 instr; C 36813 in I_c 403466207; R_g5 0.990; D = 36869 - 2*36813*400067203/403466207 = -36137
   T1  gem5 CPUs 4, traced 0,1,2,3, untraced none; L2->L1 messages in the window by CPU {0: 1178676, 1: 1188008, 2: 1192390, 3: 1172663}; M_u 0
   T2  gem5 RMWs 42463020 in 400067203 instr = 106.1397/KI; native 106.1422/KI (replayed traces sync_mx/radix, records [50 M, 150 M), 42456885 RMWs in 400000000 records)
       E -998 = -0.027 G; S (gem5 syscalls) 10; W 15749 cycles held for a mutex over 70 acquires = 0.0009% of 1685587222 cycles; per CPU {0: (14, 1754), 1: (17, 2005), 2: (19, 4165), 3: (20, 7825)}
   T3  ChampSim cores apart (heartbeats): median 0.92 M, max 2.66 M; gem5 traced CPUs at the l2_2MB_mi930M stop: [930.19, 929.97, 929.98, 930.0] M, spread 0.21 M

== lunc (agree); ChampSim phaseA_b3_n2_lunc4 (simulator/results/newbench/logs/phaseA_b3_n2_lunc4/regime_shared/lunc_4core/lru/run.log); gem5 newbench/lunc/l2_2MB_mi50M/lunc_4c -> newbench/lunc/l2_2MB_mi150M/lunc_4c
   G 37519 events in I_g 394203825 instr; C 72366 in I_c 415176209; R_g5 1.831; D = 37519 - 2*72366*394203825/415176209 = -99902
   T1  gem5 CPUs 4, traced 0,1,2,3, untraced none; L2->L1 messages in the window by CPU {0: 948526, 1: 1088598, 2: 752106, 3: 588394}; M_u 0
   T2  gem5 RMWs 384 in 394203825 instr = 0.0010/KI; native 0.0009/KI (trace_mix_v5 lunc_4t_window_t*, 370 RMWs in 400000000 records)
       E 19 = 0.001 G; S (gem5 syscalls) 29; W 14370 cycles held for a mutex over 88 acquires = 0.0024% of 587660292 cycles; per CPU {0: (23, 3874), 1: (21, 2379), 2: (23, 6137), 3: (21, 1980)}
   T3  ChampSim cores apart (heartbeats): median 4.58 M, max 6.70 M; gem5 traced CPUs at the l2_2MB_mi150M stop: [235.06, 145.99, 147.8, 150.0] M, spread 89.08 M

== ocean non-contiguous (agree); ChampSim phaseA_b3_h2_oceannc4 (simulator/results/heldout2/logs/phaseA_b3_h2_oceannc4/regime_shared/oceannc_4core/lru/run.log); gem5 heldout2/oceannc/l2_2MB_mi50M/oceannc_4c -> heldout2/oceannc/l2_2MB_mi150M/oceannc_4c
   G 30667 events in I_g 399766801 instr; C 20364 in I_c 400256323; R_g5 0.663; D = 30667 - 2*20364*399766801/400256323 = -10011
   T1  gem5 CPUs 4, traced 0,1,2,3, untraced none; L2->L1 messages in the window by CPU {0: 1121899, 1: 1092481, 2: 1099503, 3: 1103794}; M_u 0
   T2  gem5 RMWs 20001 in 399766801 instr = 0.0500/KI; native 0.0464/KI (counter, gem5-CPUID runs 0.0460 / 0.0460 / 0.0464 (the highest))
       E 1466 = 0.048 G; S (gem5 syscalls) 1033; W 494911 cycles held for a mutex over 4001 acquires = 0.0350% of 1415646514 cycles; per CPU {0: (1005, 125843), 1: (989, 108319), 2: (985, 129101), 3: (1022, 131648)}
   T3  ChampSim cores apart (heartbeats): median 1.81 M, max 4.22 M; gem5 traced CPUs at the l2_2MB_mi150M stop: [151.87, 149.92, 149.93, 150.0] M, spread 1.94 M

== The rules (design § 4)
   (a) fluidanimate: E 19112 >= D 8914
   (a) barnes std window: E -28901 < D 22559
   (a) barnes-256: E 290921 >= D 137530
   (a) E >= D on all three: NO
   (b) S > 0 and W > 0 on all three: NO {'fluidanimate': (0, 12106315), 'barnes std window': (7022, 68250158), 'barnes-256': (13783, 324909133)}
   (c) E < 0.1 G on canneal 4c 2 MB, canneal 8c, radix: yes {'canneal 4c 2 MB': -0.026, 'canneal 8c': 0.012, 'radix': -0.027}
   (d) vips: E 921, M_u 1430, D 1240: yes
   T1 fluidanimate: M_u 84 against D 8914: H-A rejected (M_u < 0.1 D)
   T1 vips: M_u 1430 against D 1240: H-A can explain it
   H-C: PARTIAL
```
