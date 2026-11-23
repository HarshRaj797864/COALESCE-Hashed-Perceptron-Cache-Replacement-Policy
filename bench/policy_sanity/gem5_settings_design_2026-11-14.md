# H4 and H5: gem5's LLC policy and CPU model as settings -- design (pre-registered 2026-11-14)

PLAN § 10 item 9, parts H4 and H5. Written before anything for them is built
or run. No gem5 run with another LLC policy or CPU model and no ChampSim run
with srrip or drrip on these windows exists yet, so none of their numbers has
been seen.

## Why

Every gem5 reference run so far differs from ChampSim in two settings that a
reviewer will name:

- **gem5's shared L2 (the LLC) uses `TreePLRURP`**, gem5's default for a Ruby
  cache (`RubyCache.py:40`; the originals' `config.ini` reads
  `type=TreePLRURP`, `num_leaves=16`). ChampSim's LLC uses LRU.
- **gem5's CPU is `TimingSimpleCPU`**, one instruction at a time; ChampSim's
  core is out of order.

H4 sets gem5's LLC policy to match ChampSim's lru, srrip and drrip, and asks
two questions: does the coherence agreement (R_g5) hold under each matched
policy, and do the two simulators order the policies the same way on LLC
misses? H5 runs gem5's out-of-order CPU and asks whether R_g5 depends on
gem5's CPU model. **The band does not move, and no scored verdict is scored
again.**

## Common to both

- The F-C binary (`champsim_fc_a2e88e46`) is the ChampSim side, as in the
  paper. ChampSim's C (gem5-rule RFO events per KI) for LRU is the F-C
  reference run's, read as `lock_fix_score.py` reads it.
- Each gem5 run is its original's (binary, inputs, options, CPU count, cache
  sizes, the FIFO patch, the stop) with one setting changed, started through
  the same mode and settings as the original (the 13 resolved in H1's build
  record), into `~/gem5_b3/hset/<setting>/<program>/l2_2MB_mi<stop>M/<tag>/`,
  through H2's copy of `run_gem5_splash.sh` (`GEM5_PARAMS`, `CPU_TYPE`; both
  exist; the live runner and `~/gem5/configs` are not touched). Nice 19.
- **QS1, the end:** as H2's QV1: "because a thread reached the max
  instruction count" and one statistics dump; anything else (a panic, the
  limit) and that point is "not measured".
- **The window** is the longer stop's statistics minus the shorter stop's
  (`b3_score.py window`, as every score; a counter going backwards: not
  measured).
- G is gem5's SS + MT `L1_GETX` per KI in the window; R_g5 = C / G, as
  scored.

## H4: gem5's LLC replacement policy

**Programs:** the four 4-core spans that agree, at their scored stops:
ocean 2 MB (50 / 150 M), canneal 4c 2 MB (50 / 150 M), lunc (50 / 150 M),
radix (830 / 930 M). F-C R_g5 (TreePLRU in gem5, LRU in ChampSim): 0.712,
1.018, 1.830, 0.988.

**gem5's L2, set through `GEM5_PARAMS`** (`system.ruby.l2_cntrl0.L2cache.
replacement_policy = __import__('m5.objects', fromlist=['x']).<policy>`;
one L2 bank, `--num-l2caches=1`):

| setting | gem5 policy | ChampSim module it matches |
|---|---|---|
| `lru` | `LRURP()` | `lru` |
| `srrip` | `BRRIPRP(num_bits=2, btp=0, hit_priority=True)` | `srrip` as it behaves |
| `drrip` | `DRRIPRP(constituency_size=512, team_size=16, replacement_policy_a=BRRIPRP(num_bits=2, btp=3, hit_priority=True), replacement_policy_b=RRIPRP(num_bits=2, hit_priority=True))` | `drrip` |

Why these parameters (read in both sources, 2026-11-14):

- **srrip:** upstream ChampSim's `srrip` never runs its insertion (its
  `replacement_cache_fill` is empty; `srrip_insertion_diagnosis_2026-11-11.md`),
  so a filled line keeps the victim's RRPV, 3; a hit sets 0; the victim is
  the first way at the largest RRPV once the set is aged. gem5's `BRRIP` with
  `btp=0` inserts every line at the saturated RRPV (3 with 2 bits),
  `hit_priority` sets 0 on a hit, and its victim is the first candidate with
  the largest RRPV after the same ageing (invalid ways first in both).
- **drrip:** ChampSim's `drrip` has one leader set of each team per 32
  sets (sample rate 32 for 2,048 sets; `msl::categorizer`: category = (the
  set's low 5 bits - its next 5 bits) mod 32, leaders are categories 0 and
  1, so their position moves from one block of 32 to the next): 64 of each.
  Its PSEL is 10 bits; BRRIP inserts at 3 with every 32nd fill at 2 (a
  counter), SRRIP at 2, and hits go to 0. gem5's `DuelingMonitor` makes the
  first `team_size` entries of every `constituency_size` entries one team and
  the last `team_size` the other; Ruby instantiates the entries set by set
  (`CacheMemory.cc:116-121`), so 512 and 16 give one leader set of each team
  per 32 sets (the first and the last of each 32): 64 of each.
  `Dueling::getVictim` requires `team_size` = the associativity (16). Its
  selector is 10 bits. `btp=3` is 3% at random against ChampSim's 1 in 32.
- **lru:** gem5's `LRU` inserts at MRU and moves a touched line to MRU, as
  ChampSim's.

**Differences that stay (stated in the paper, not fixed):**

- Ruby changes an L2 line's replacement state on a fill and wherever the
  protocol calls `setMRU` (`MESI_Two_Level-L2cache.sm`, which
  MESI_Three_Level uses for its L2), not on every access; ChampSim's modules
  see every LLC hit and fill, writebacks included.
- ChampSim's `drrip` keeps one PSEL per core; gem5's `DRRIP` one selector.
  The leader sets are as many but at other positions (a diagonal against
  the first and last set of each 32).
- gem5's L2 is inclusive of the private caches; ChampSim's LLC is not.

**ChampSim runs:** the F-C binary with `srrip` and with `drrip` on the four
F-C reference windows (50 M + 100 M; radix's as its reference log gives),
each with its reference's config (`~/sync_fc/cfg/<p>.json`) with only
`LLC.replacement` changed, the reference's traces in its thread order, into
`results/phaseA_b3_hs_<setting>_<suffix>/regime_shared/<wl>_4core/<setting>/run.log`.
8 runs. LRU is the F-C reference run itself.

**Runs:** 24 gem5 (3 settings x 4 programs x 2 stops), 8 at a time, the
longer stops first, limit 168 h a run; 8 ChampSim, 4 at a time.

**Checks:**

- **QH0, the same configuration:** each gem5 run's `config.ini` equals its
  original's (the same stop, the original's directory read as the new one)
  in every section except `[system.ruby.l2_cntrl0.L2cache.replacement_policy]`
  and its children. Those must hold exactly the declared policy: `type` and
  each declared parameter (`LRURP`; `BRRIPRP` with `btp=0`,
  `hit_priority=true`, `num_bits=2`; `DuelingRP` with `constituency_size=512`,
  `team_size=16`, and children `replacement_policy_a` = `BRRIPRP` `btp=3`
  `hit_priority=true` `num_bits=2`, `replacement_policy_b` = `BRRIPRP`
  `btp=100` `hit_priority=true` `num_bits=2`). Any other difference: the run
  is void and the driver stops launching H4.
- **QH2, a ChampSim run qualifies** by lock_fix_score's `qualify` against its
  F-C reference log (complete, the request line, level 2, no wrap,
  self-check 0, stale holders 0, registered caches, Q3 unexplained 0, the
  same lengths, CPU count and traces), and its config equals the reference's
  but `LLC.replacement`. A run that does not qualify is reported, not used.

**The measures:**

- R_g5 for each matched pair (program, setting) = C(ChampSim, setting) /
  G(gem5, setting): 12 values, printed beside the scored TreePLRU / LRU one.
- M = LLC demand misses per KI in the window: gem5 `m_demand_accesses -
  m_demand_hits` of `l2_cntrl0.L2cache` (gem5 rows' `demand_acc`,
  `demand_hits`); ChampSim the LLC's (total - writeback) misses, as the
  traffic measure counts the accesses. Both simulators, 3 settings, 4
  programs.
- gem5 TreePLRU against gem5 LRU: the change in G and in M, per program
  (how much gem5's default mattered).

**The reading, fixed now:**

- **P-H4a:** with gem5 on `LRURP`, R_g5 lies in [0.5, 2] for each of the
  four programs (where TreePLRU's did). Expected beforehand, so it is a
  prediction; lunc (1.830) is the one at risk.
- **P-H4b:** under the srrip and drrip pairs, R_g5 lies in the band for each
  of the four (8 values).
- The paper says **"the agreement holds under three matched LLC policies"**
  only if all 12 are in the band; otherwise it gives the count and names
  each one outside. With H2's s\*, each of the 12 also gets its label.
- **The ordering (description, not a test):** per program, the order of the
  three settings by M in each simulator, and over the 12 pairs (4 programs x
  3 pairs of settings) the number whose sign agrees. A pair whose relative
  difference is under 1% in either simulator is a tie and counted apart.
  With three policies no ranking statistic is significant, and none is
  claimed.

## H5: gem5's CPU model

**Programs:** ocean 2 MB and canneal 4c 2 MB (agree), fluidanimate and vips
(disagree: F-C R_g5 0.400 and 0.308), both stops (50 / 150 M): **8 runs**
with `CPU_TYPE=X86O3CPU` (the speed test's), everything else the
original's, the FIFO patch on as for every original. 4 at a time, the 150 M
stops first, limit 168 h (the speed test measured O3 + Ruby at about a
third of TimingSimpleCPU + Ruby's rate).

- **QO0, the same configuration**, fixed from a real pair of `config.ini`s
  (the speed test's `G-ts-ruby.1` and `G-o3-ruby.1`, the same program under
  both CPUs: outside `system.cpu<N>` they differ only in their output
  directory). Once the original's directory is read as the new one:
  - every section of the original exists in the new one, and every section
    only in the new one lies under `system.cpu<N>.`;
  - every section other than `[system.cpu<N>]` is identical, the workload's
    (`system.cpu0.workload`: binary, arguments, input) included;
  - in each `[system.cpu<N>]`, every line of the original is present
    unchanged except `type=BaseTimingSimpleCPU` (must read
    `type=BaseO3CPU`), `branchPred=Null` and `children=` (whose list must
    contain the original's).
  Any other difference: void, and launching H5 stops.
- **Measures:** G_O3 in the window; R_g5(O3) = C (the F-C reference's) /
  G_O3; R_g5(O3) / R_g5(Timing). **Reported only:** the window's committed
  instructions per CPU against TimingSimpleCPU's (spinning under O3 can
  change how a thread's instructions fall), and the window's loads and
  stores per KI (gem5 mix rows).
- **P-H5a:** ocean's and canneal's R_g5(O3) lie in the band.
- **fluidanimate and vips, reported, no prediction:** if R_g5(O3) moves into
  the band, the paper says their disagreement depends on gem5's CPU model and
  reports both values; the scored verdicts stand.

## Scorer and runner

- `scripts/hset_check.py`: `qh0`, `qo0`, `qend` (server); `rows` (the pulled
  gem5 runs as gem5 rows), `score`, `selftest` (laptop). The self-test covers
  QH0 passing and failing for each declared policy, QO0 on the speed test's
  real pair (passing) and with an injected change in a cache size, the
  workload and the CPU's `max_insts_any_thread` (failing), and R / M on hand
  rows.
- `scripts/hset_server.sh` (`guards`, `list`, `chain`, `status`, `stop
  [runs]`; gem5 and ChampSim drivers, H2's stop and relaunch rules) and
  `scripts/hset_all.sh` (`go`, `guards`, `status`, `list`, `pull`, `stop`).
- **Guards:** gem5 at v25.1.0.1 with only the FIFO patch; H2's runner copy
  with `GEM5_PARAMS` and `CPU_TYPE`; every original complete at its stop,
  after the gem5 binary; the F-C binary's md5 and its checks; the four F-C
  reference runs complete; `X86O3CPU` in gem5's `--list-cpu-types`.
- Rehearsed against a stand-in server before launch (QH0 / QO0 passing and
  failing, a panic, the limit, stop and relaunch). The rehearsal's checks go
  into this note's build record. Launch on the owner's word.

## Cost

- H4: 24 gem5 runs. The originals took about 1.3 h (lunc), 2.8 h (ocean),
  9.2 h (canneal) and 9.5 h (radix) at the 150 M / 930 M stop (`hostSeconds`,
  read 2026-11-14), the shorter stops less; under today's load (about 70 on
  48 cores) perhaps twice that. 8 ChampSim runs at 4 cores.
- H5: 8 gem5 runs at about three times their originals' time (ocean 2.8 h,
  canneal 9.2 h, fluidanimate and vips 1.8 h at 150 M): roughly 5-30 h each
  before load.

## Build record (2026-11-14, before any launch)

- **Read on the server first (read-only):**
  - the speed test's pair `~/speed/G-ts-ruby.1/config.ini` and
    `~/speed/G-o3-ruby.1/config.ini` (copied to the laptop, untracked, under
    `simulator/results/hset/speedcfg/`), from which QO0 is fixed;
  - the twelve originals' `config.ini` (L2 `TreePLRURP`, `[system.cpu0]`
    `BaseTimingSimpleCPU`) and `hostSeconds` (Cost, above);
  - the F-C reference logs and configs (`~/sync_fc/cfg/<p>.json`, LLC `lru`,
    `sync_lock_word request`), vips's included (`phaseA_b3_fc_h2_vips4`).
- **Built:**
  - `scripts/hset_check.py`: `qh0 ORIG NEW SETTING`, `qo0 ORIG NEW`, `qend`,
    `cfg REF NEW SETTING` (the ChampSim config equals the reference's but
    `LLC.replacement`), `rows`, `mix`, `score`, `selftest`. The self-test has
    33 cases. They include QH0 passing and failing for each declared policy.
    They also include QO0 on the speed test's real pair: it passes as read,
    and fails with one CPU's stop changed. The verdicts count measured points
    only.
  - `scripts/hset_server.sh` (`guards`, `list`, `chain`, `status`, `stop
    [runs]`; three drivers: H4 gem5 8 at a time, H5 gem5 4 at a time, H4
    ChampSim 4 at a time; H2's stop and relaunch rules). Its ChampSim
    driver takes each run's traces from the F-C reference log's `CPU N runs`
    lines, so a run's traces are the reference's by construction.
  - `scripts/hset_all.sh` (`go`, `guards`, `status`, `list`, `pull`,
    `stop`). `go` refuses unless the scripts and this note are committed,
    the note has this record and the self-test passes.
  - gem5's runs go through H2's runner copy `~/gem5_cal/run_gem5_splash.sh`
    (`GEM5_PARAMS`, `CPU_TYPE`), checked by md5. `run_gem5_splash.sh` is not
    changed.
- **Rehearsed against a stand-in server.** It used H2's fake home,
  extended:
  - the radix and vips originals from the pulled files;
  - a stand-in `gem5.opt` that writes the original's `config.ini` with the
    declared policy's section, or under `--cpu-type=X86O3CPU` the O3 CPU's
    sections, and answers `--list-cpu-types`;
  - a stand-in F-C binary whose counts depend on `LLC.replacement`;
  - the real F-C configs; vips's sizing line.

  What it showed:
  - **Guards:** they pass on the clean home. Eleven injected faults are each
    refused by their own FAIL line alone, and `chain` then starts nothing.
    The faults: the runner copy changed; the F-C binary's md5; an original
    not TreePLRU; an original not ended at its stop; an original not
    TimingSimpleCPU; gem5 without `X86O3CPU`; an F-C config not LLC `lru`;
    an F-C reference without its request line; F-C's `K0_PASSED` missing;
    the live gem5 tree changed; an original older than the gem5 binary.
  - **H4:**
    - all 24 runs pass QH0, 8 for each policy;
    - an injected panic in radix drrip is classified OTHER;
    - an injected srrip `btp=3` fails QH0, which names `btp=3, declared 0`,
      and the run is VOID.
  - **H5:**
    - the clean pass: all 8 ENDED with QO0 PASS (4, 5 and 7 CPUs). gem5's
      arguments carry `--cpu-type=X86O3CPU`, and each policy statement
      arrives as one argument;
    - an injected change of `max_insts_any_thread` on fluidanimate fails
      QO0: the run is VOID and the rest NOT RUN.
  - **Stop and relaunch:** `stop runs` with 5 gem5 runs and 2 ChampSim runs
    in flight leaves no process. The relaunch starts each of them again
    ("ended while no driver ran, not at its stop"). An injected ChampSim
    abort is classified FAILED.
  - **The scorer, end to end on the pulled rehearsal files:**
    - its parser reproduces the 14 committed F-C rows;
    - the LRU reference R_g5 reproduce 0.712 / 1.018 / 1.830 / 0.988;
    - P-H4a reads 4 of 4;
    - canneal drrip, which did not complete, prints NOT USED; so does lunc
      srrip, with an injected Q3 violation [2, 2];
    - radix drrip's gem5 panic prints "not measured";
    - P-H4b reads "not decided" (5 of 8 measured);
    - H5 prints G, R and R(O3) / R(Timing), the per-CPU window instructions
      and the loads and stores per KI.
- **Defects found and fixed:**
  1. The scorer counted a point it could not measure as measured. P-H4a / b
     could then read FAILS with nothing outside the band, and "three matched
     policies" NO while points were missing. Now: HOLDS only when every point
     is measured and in the band; FAILS when a measured point lies outside;
     otherwise "not decided". Self-test cases added.
  2. The `X86O3CPU` guard piped gem5's output into `grep -qw` under
     pipefail, the class of the 2026-10-28 guard. The output is now captured
     first.
  3. Rehearsal only: the stand-in gem5 looked for the program one directory
     too high, and vips's sizing line was missing from the fake home, so its
     launch failed (LAUNCH-FAILED, as designed).
  4. Not a defect: the rehearsal's reference logs had their trace paths
     rewritten to the fake home, while the scorer reads the laptop's real
     F-C logs. So it refused the srrip / drrip runs ("its lengths, CPU count
     or traces differ"). With the paths mapped back it qualifies them. On
     the server the driver copies the reference's own trace lines, so they
     are equal.
- **Not testable before launch:** whether the real gem5 accepts the
  `__import__` statements. The first runs' QH0 decides it: a run that does
  not read the declared section is VOID and launching stops.
- **Launch (owner's word, "start the H's in that order"):** `bash
  scripts/hset_all.sh go`; then `status`.
- **Scoring, once the runs end:**
  - `bash scripts/hset_all.sh pull`;
  - `python3 scripts/hset_check.py rows simulator/results/hset/gem5 >
    bench/policy_sanity/hset_gem5_rows_v1.txt`;
  - `python3 scripts/hset_check.py mix simulator/results/hset/gem5 >
    bench/policy_sanity/hset_gem5_mix_v1.txt`, and the originals' mix the
    same way from `simulator/results/hset/orig`;
  - `HS_LOGS=simulator/results/hset/logs HS_CFG=simulator/results/hset/cfg
    python3 scripts/hset_check.py score <rows> <mix> <orig mix>`.

## Amendment 1 (2026-11-14 ~11:45 server time, before any H4 number exists)

**What happened.** Launched 11:24 (`fffd9d1`). H4's first gem5 run (lru,
ocean, 150 M) exited before `m5.instantiate`. It wrote no `config.ini` and
ran no instruction. Its `run.log`:

```
SimObjectCliWrapperException: tried to set or unsettableobject parameter: replacement_policy
  src/python/m5/SimObject.py(590): __setattr__
  <string>(1): <module>
  src/python/m5/SimObject.py(1374): apply_config
  /home/harshraj/gem5/configs/common/Simulation.py(684): run
```

**Cause, read in gem5 v25.1's source on the server.**
- `apply_config` executes each `--param` statement with the root's children
  wrapped in `SimObjectCliWrapper` (`SimObject.py:565-597`).
- The wrapper's `__setattr__` sets a parameter only if
  `isCmdLineSettable()`, which is false for every SimObject parameter.
- The right-hand side, `__import__('m5.objects', ...).LRURP()`, had evaluated:
  the exception is raised at the assignment.

So the build record's "not testable before launch" case occurred. The
driver's QH0 (no `config.ini`) makes the run VOID and stops launching H4,
as designed.

H5 (set through `CPU_TYPE`) and the ChampSim runs are not affected: QO0
passed on the real gem5 for ocean O3 at 11:25.

**The change (the mechanism only).** The statement makes the same assignment
on the real object. It reaches it through the root, which `Root.getInstance()`
returns (`src/sim/Root.py:52`):

```
__import__('m5.objects', fromlist=['x']).Root.getInstance().system.ruby.l2_cntrl0.L2cache.replacement_policy = __import__('m5.objects', fromlist=['x']).<policy>
```

- `Simulation.py:684-685` calls `root.apply_config(options.param)` and then
  `m5.instantiate`. So the assignment happens before instantiation, as a
  configuration script would make it.
- `SimObject.add_child` clears the replaced child, so `config.ini` holds
  only the new policy.
- The policies, their parameters, QH0, the programs, stops, limits,
  predictions and the scoring are unchanged.
- QH0 still decides each run: `config.ini` must equal the original's except
  the `replacement_policy` sections, which must hold exactly the declared
  type and parameters.

**Relaunch of H4's gem5 part only** (`hset_server.sh relaunch4`, from
`hset_all.sh relaunch4`):
- It refuses while the H4 gem5 driver or any H4 gem5 process is alive.
- It runs the guards that concern H4's gem5 runs. It does not check whether
  the H5 and ChampSim drivers are alive: they keep running.
- It moves every H4 run whose result is VOID, NOT RUN or LAUNCH-FAILED aside,
  its state and its output directory, to `~/hset/void_<time>/`. A decided
  run that ran is kept.
- It then starts the H4 gem5 driver alone.

The first run of each policy is checked by QH0 before the next launch, as
before. A failure again stops H4 and is written here before anything else.

**Rehearsed (2026-11-14, stand-in server).** The stand-in gem5 now refuses
any `L2cache.replacement_policy` statement without `Root.getInstance()`, as
gem5's wrapper does: the same exception in `run.log`, exit 1, no
`config.ini`. Today's sequence, replayed:
- `chain` with the committed `fffd9d1` script: the first H4 run is VOID
  (no `config.ini`), the other 23 NOT RUN, the H4 driver ends; H5 and
  ChampSim run on;
- `relaunch4` while the H4 driver still waits is refused;
- the new script uploaded by `.new` + `mv`; `relaunch4` passes the guards
  without the H5 / ChampSim liveness checks, sets the 24 aside (the VOID
  run's `run.log` with the exception kept under `void_<time>/out/`) and
  starts the H4 driver; the H5 and ChampSim drivers keep their pids;
- all 24 relaunched runs pass QH0 and end at their stops; each carries the
  `Root.getInstance()` statement as one argument;
- H5 (8 of 8) and ChampSim (8 of 8) complete through the relaunch;
- `relaunch4` again: nothing set aside, 24 kept, the driver ends at once;
- no stand-in process is left.

**Relaunch record (2026-11-14, server time).** 11:39:58 the first driver
voided lru ocean 150 M (no `config.ini`) and stopped; 11:41:53 it ended.
11:42 `bash scripts/hset_all.sh relaunch4` (`9a0be12`): the H4 guards pass,
the 24 set aside to `~/hset/void_20261114_114208` (the VOID run's `run.log`
with gem5's exception kept there), the H4 driver started. **QH0 passes on
the real gem5 for every policy:** lru ocean 11:43:10 (LRURP), srrip ocean
11:44:08 (BRRIPRP), drrip ocean 11:45:06 (DuelingRP, constituency 512, team
16, policy a BRRIPRP btp=3, policy b printed by gem5 as BRRIPRP btp=100,
which is RRIPRP's definition), then canneal's three and lunc lru. At 11:49
the eight long ocean / canneal runs (three policies and O3 each) are alive
with no panic. H5 and the ChampSim runs kept running throughout.
