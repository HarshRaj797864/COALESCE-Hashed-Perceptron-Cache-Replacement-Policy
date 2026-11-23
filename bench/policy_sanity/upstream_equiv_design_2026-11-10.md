# Part A: with the extension off, our ChampSim is upstream ChampSim. Pre-registered 2026-11-10, before any run

**Why** (owner, 2026-11-10): the tool's claim must rest on wide testing. HiPC
turned the paper down partly for too little variety. Part A is the base of
that claim: before anything is said about what the extension adds, show that
it takes nothing away. With every part of the extension switched off, our
binary must print exactly what upstream ChampSim prints.

No such test has been made before. A4 (`a4_results_2026-09-21.md`) compared
policies with each other, not our binary with upstream's.

## The two binaries

- **Upstream:** ChampSim `develop` at **`f9ed890e`** (2026-09-12), the commit
  our tree was migrated onto (`a6b1e51`). It is built untouched, with its own
  Makefile, in a fresh worktree of the laptop's ChampSim clone
  (`~/programming-playground/repos/ChampSim`), on the server, with the same
  compiler and vcpkg libraries as ours. Its source tree's checksum is
  recorded, and its `replacement/` directory must equal upstream's at that
  commit (`git status` clean).
- **Ours:** `main` at the commit that adds the switch below, built in its own
  tree, never `bin/champsim`.

## The one new setting: `rmw_as_rfo`

Since B3 v3 step 1 (`f23e03f`), a read-modify-write instruction issues its
load as an RFO (a request for ownership), as gem5 does. This is always on.
Upstream issues it as a load. That changes the cache counters by access type
on any real program, so exact equality needs a way to turn it off.

- **Setting** `rmw_as_rfo` (`make_config.py --rmw-as-rfo 0|1`, **default 1**,
  the current behaviour). With 0, `LSQ_ENTRY::rmw` is never set, so the load
  goes out as a read, as upstream's does. The two RMW counters stay at 0.
- **Q-def, the default is unchanged:** with the setting absent or 1, every log
  line equals the previous binary's on the exact suite
  (`check_coherence_exact.sh`, all cases, levels 0-2; logs compared line by
  line), Q2b (`mutex_micro.c` cases) and the laptop's `canneal_4t` and
  `barnes_4t` (1 M + 2 M; shared level 0, shared level 2, private level 2).
  It is checked before anything else runs.

## "The extension off"

`--regime private` (no shared memory overlay), `--private-coherence 0`,
`--rmw-as-rfo 0`, and traces without sync records. Multi-core runs here are
**multi-programmed**: each core runs a different program, which is what
upstream models. (The shared regime would alias different programs' virtual
addresses onto one physical page and manufacture sharing, so it is never used
with these mixes.)

## Inputs

The 12 SPEC CPU2006 traces on the server, `traces/spec/` (the public DPC-3 /
CRC-2 set): 410.bwaves-1963B, 429.mcf-22B, 433.milc-127B, 437.leslie3d-232B,
450.soplex-247B, 459.GemsFDTD-1169B, 462.libquantum-1343B, 470.lbm-1274B,
471.omnetpp-188B, 473.astar-153B, 482.sphinx3-1100B, 483.xalancbmk-716B.

- **Single core:** each trace alone.
- **4 cores, three mixes**, by a fixed rule (the traces sorted by name as
  above): mix 4a = traces 1-4, 4b = 5-8, 4c = 9-12.
- **8 cores, two mixes:** 8a = traces 1-8, 8b = traces 5-12.
- **Policies:** the five upstream ships and we run unchanged: lru, srrip,
  drrip, ship, random.
- **Lengths:** 50 M warm-up + 100 M simulated instructions a core.
- **Configuration:** one JSON per (cores, policy), written by our
  `make_config.py`, and **the same file is given to both binaries**.

Runs: (12 + 3 + 2) configurations x 5 policies = 85 per binary, **170**.

## Checks and the pass rule

- **E0, the inputs:** both binaries read the same configuration. Upstream
  must start without a configuration error and print the same "Number of
  CPUs", cache geometry and lengths as ours. Every run completes, and none
  reaches the end of its trace (the runner's trace-length preflight; ChampSim
  reopens a short trace silently, S3).
- **E1, equivalence (the claim):** for each of the 170 pairs, with the wall
  clock masked (`Simulation time` and the heartbeat's elapsed time):
  - every line upstream prints appears in ours, **identical and in the same
    order**;
  - ours adds only lines from a fixed list of our new statistics: the
    coherence, sharer-directory, gem5-rule, view-order, sync and mutex
    counters, the RMW counters, `VMEM ALIASED FILLS` and the settings lines
    (regime, private-coherence level, sync mutex order). The list is a
    file of patterns committed with the runner, before any run.
  - **Passes only at 85 of 85.** Any other difference is a defect, to be
    found and fixed before this part is reported. Nothing is left as a
    "close enough".
- **E2, what the RMW change does (reported, with a prediction):** ours again
  with `--rmw-as-rfo 1` (the default) on the 12 single-core traces and the
  three 4-core mixes, LRU only (15 runs), against upstream.
  - **Prediction** (step 1 found its change timing-neutral on canneal,
    `b3v3_step1_2026-10-09.md`): cycles and instructions identical; the only
    lines that differ are the per-type LOAD and RFO counts of L1D, L2C and LLC
    (each cache's TOTAL unchanged) and our RMW counters.
  - If cycles differ, the difference is reported with its size, and its
    cause found from the logs.

## What a result means

- **E1 holds:** the paper can say that with the extension off, the tool
  prints exactly what upstream ChampSim prints, on 12 public traces at 1, 4
  and 8 cores with five policies. So every difference the extension makes
  comes from a named, switchable change.
- **E1 fails:** we have changed upstream behaviour we did not intend. The
  difference is found, fixed, and the affected runs (on both sides) repeated.
  This part is not reported until it holds.

**Disclosed, not a failure:** upstream's SRRIP inserts a new line at RRPV 3,
not the published 2 (its fill hook is empty; `docs/policy_audit.md`). Ours is
upstream's code, so E1 is unaffected; the paper states it where SRRIP appears.

## Order

1. This note, committed.
2. The switch, built; Q-def on the laptop.
3. Rehearsal on the laptop: upstream built in scratch; E1 on `429.mcf` and
   `600.perlbench` (single core, 5 policies, 1 M + 5 M) and a 4-core mix of
   `canneal_4t`'s threads in the private regime (1 M + 2 M).
4. The server runner (its own trees and binaries; `bin/champsim` and the
   main tree untouched), rehearsed against the stand-in server.
5. Launch on the owner's word. Score with the comparison script, committed
   before any server log is read.

## Amendment 1, 2026-11-10: before Q-def ran

Q2b's program is traced again by Pin each time `micro_champsim.sh` runs, so
two binaries would not replay the same trace. **Q-def's Q2b is replaced by
ocean 4c's synchronised traces** (`traces/sync_mx/ocean4`, traced by Pin with
glibc's mutexes and barriers recorded), 1 M + 2 M, with step 5's LRU configs
(shared, level 2; private, level 2), on both binaries. The previous binary is
main's simulator source before the switch (equal to `991ec4f`'s), built as
`champsim_lc_7fcf31e0` in the lock-wait rehearsal. Nothing else changes.

## Results on the laptop, 2026-11-10 (steps 2 and 3)

**Q-def holds: the default is unchanged.** The switch's binary (`631fee7f`)
against the previous one (`champsim_lc_7fcf31e0`, the same source without
the switch):
- the exact suite on both: every hand count met by each ("PASS ... at levels
  0 1 2"); **54 of 54 logs identical** line for line (trace paths and wall
  clock masked); **68 of 68 generated traces byte-equal**;
- real traces, 1 M + 2 M: canneal_4t and barnes_4t at shared level 0,
  shared level 2, private level 2, and ocean 4c's synchronised traces with
  step 5's LRU configs (shared, private): **8 of 8 pairs identical**. The
  default still issues RMW loads as RFOs (canneal shared level 2: 12,174 on
  CPU 0) and never prints `RMW LOADS AS RFO: off`; ocean's logs carry their
  SYNC and MUTEX lines (14).
- `make_config.py` without `--rmw-as-rfo` writes byte-identical configs: 96 of
  96 combinations (policies, cores 1-16, regimes, the other options) against
  the previous script.

**Upstream builds untouched.** `git archive f9ed890e` of the laptop's ChampSim
clone (commit `f9ed890e9477649c24b8defc4d789fbecbc1e7d5`; source checksum,
vcpkg excluded, `b7144198...`), built with its own Makefile against the same
vcpkg libraries (its `vcpkg.json` equals ours).

**Rehearsal of E1 (step 3): 15 of 15 pairs hold** (`scripts/upstream_equiv.py
dir`, committed `dcf436e` with its allowed-lines file, self-test 8 hand
cases). Same JSON for both binaries (`make_config.py --regime private
--rmw-as-rfo 0`):
- `429.mcf-22B` and `600.perlbench_s-210B`, single core, 1 M + 5 M, five
  policies: upstream's 122 lines all present, identical and in order; 200-202
  added lines, every one on the list;
- `canneal_4t`'s four threads as a 4-core multi-programmed mix (private
  regime), 1 M + 2 M, five policies: 671 upstream lines, 1,420 added. canneal
  is full of read-modify-writes, so this also shows the switch restoring
  upstream's behaviour.

One mistake of mine on the way, not a defect: a first smoke run aborted
("cannot use value() with null") because my shell command backgrounded the
step that wrote the config together with the upstream run, so our binary
read the file before it existed. Rerun after the file was written: identical.

**Next (step 4):** the server runner, rehearsed against the stand-in server.

## Amendment 2, 2026-11-10: the trace-end rule, before any server run

E0 said no run may reach the end of its trace. That rule comes from the
multi-threaded traces, where a replayed start would replay synchronisation.
It does not fit multi-programmed mixes: there, upstream itself reopens the
trace of a core that has finished its count and keeps it running until the
slowest core finishes (`repeatable.h`, the same file in both trees, printing
the same `*** Reached end of trace` line). That is upstream's method, and E1
already requires both binaries to print the same lines.

- **E0's trace rule is now:** every trace holds at least 150 M instructions
  (warm-up + simulation), counted on the server before any run, so no core
  reaches its trace end before its own count is done. A core that has
  finished may wrap; both binaries must then print the same line (E1).
- Counted on the laptop for the two local traces: 429.mcf-22B and
  600.perlbench_s-210B hold 2,000,000,000 records each.

Nothing else changes.

## Step 4, 2026-11-10 / 11: the server runner, rehearsed against a stand-in server

`scripts/partA_all.sh` (laptop) and `scripts/partA_server.sh` (server side:
`build | chain | status | stop`). Rehearsed end to end against a stand-in
server (a fake `ssh` / `scp` into a scratch home; the real Makefiles, guards,
binaries and comparators; 0.5 M + 1 M instructions, 6 at a time; the 12 SPEC
names linked to the two traces the laptop holds). Nothing has touched the
real server.

What the runner does:

- Laptop: requires a clean source tree; archives upstream at
  `f9ed890e9477649c24b8defc4d789fbecbc1e7d5` from the local ChampSim clone
  (source checksum `b7144198...`, checked again on the server); uploads our
  sources to `~/partA_ours_build` and upstream's to `~/partA_up_build`, each
  checked equal after upload. The main tree, its binaries and every live
  runner are not touched.
- Server, detached: both builds (upstream's by its own Makefile, unmodified),
  the three guards on ours, each binary frozen under its md5
  (`champsim_partA_ours_<md5>`, `champsim_partA_up_<md5>`), E0 (each trace
  read only as far as warm-up + simulation), then the chain: 185 runs (E1 85
  pairs = 170 runs, E2 15 runs of ours with the default settings), 8-core
  first, 24 at a time, nice 19.
- A run counts as done only if its log ends complete **and** was made by the
  binary now frozen (each log has a sidecar `<log>.bin` naming it). So a
  relaunch after a reboot skips finished runs, and a relaunch after a source
  change reruns everything.
- `pull` brings the logs and sidecars to `simulator/results/partA/logs/`;
  `stop` ends the chain and its simulators.

Rehearsal results:

| check | result |
|---|---|
| uploads equal on both ends; both builds; guards | hold (3 of 3 guards) |
| a rebuild from the same sources | byte-identical binaries (same md5 names) |
| E0 | holds on 12 traces |
| the chain | 185 of 185 runs complete |
| **E1** (upstream's log an in-order subsequence of ours-off) | **holds on 85 of 85 pairs**, 0 without a partner |
| **E2** (default settings: only the L1D / L2C / LLC LOAD and RFO lines may differ) | **the prediction holds on 15 of 15** |
| E2 zero control (ours-off against upstream) | 15 of 15 with 0 differing lines |
| E2 positive control (canneal 4-core mix, default against upstream) | 48 LOAD / RFO lines differ, 0 others, cycles identical |
| a second launch while the chain runs | refused |
| `stop`, then a relaunch | chain ends with 0 simulators left; the relaunch resumes |
| a relaunch after the chain ended | 185 of 185 skipped, none rerun (log times unchanged) |
| `pull`, then both scores from the pulled logs | 185 logs + sidecars; E1 85 of 85, E2 15 of 15 |
| injected: uncommitted change in the sources | stops at step 1 |
| injected: the upstream commit missing from the clone | stops at step 1 |

The E2 comparison (`upstream_equiv.py e2 DIR`) was added in this step. Its
rule: both runs complete exactly once; every line that differs must be a
per-type access line of a data cache (`cpuN->cpuN_L1D`, `cpuN_L2C` or `LLC`,
`LOAD` or `RFO`); nothing else may differ, cycles included. Its self-test
holds hand cases for each way it must fail (a run that did not complete, an
L1I line that moves, a cycle count that moves). The comparison's first
version was corrected after the positive control; the version committed is
the one both controls and the self-test check.

What the rehearsal cannot show: the server's own compiler and libraries
(the build there is new), the 12 real traces' lengths (E0 counts them), and
the real run times (a laptop run of 8 SPEC cores had IPC ~0.2; 8-core runs
are expected to take 10-24 h under nice 19).

**Next:** `scripts/partA_all.sh` on the server (owner's word, 2026-11-11),
then `scripts/partA_all.sh pull`, then
`python3 scripts/upstream_equiv.py dir simulator/results/partA/logs` (E1) and
`python3 scripts/upstream_equiv.py e2 simulator/results/partA/logs` (E2).

Also committed with this step, for part C
(`breadth_bc_design_2026-11-10.md`): `scripts/sync_strip.py` (`strip`,
`count`, `selftest`), which drops every sync record from a synchronised trace
and copies every other record byte for byte. Self-test passes (hand-made
records, raw and xz, a chunk boundary). On ocean 4c's four `sync_mx` traces
it leaves exactly 215,000,000 records each (3,378 / 3,100 / 2,700 / 3,270
sync records removed). First C0 check on those stripped traces (LRU, 1 M +
2 M, upstream against ours-off): E1 holds, 671 upstream lines.

## Amendment 3, 2026-11-11: E1 at 16 cores, before any 16-core pair exists

Owner, 2026-11-11: 16 cores as well. Two 16-core multi-programmed mixes are
added to E1. The server holds 12 SPEC traces, so a 16-core mix repeats four
of them; in the private regime each core has its own memory, so a repeated
trace shares nothing, and both binaries read the same files.

- `16a`: traces 1-12 (sorted by name), then 1-4 again. `16b`: traces 1-12,
  then 9-12 again.
- Five policies (lru srrip drrip ship random), both sides, 50 M + 100 M a
  core: 20 runs. E2 (ours with the default settings, LRU): 2 runs.
- E0, E1 and E2 as written. The pass rule now reads: E1 holds on all 95
  pairs; E2's prediction on all 17.
- These 22 runs are added to the chain after its first 185 have ended, by a
  runner change rehearsed against the stand-in server first. The first 185
  runs are scored as designed whether or not the 16-core runs have ended;
  the paper's sentence names the core counts that have been scored.

## Amendment 4, 2026-11-12: the runner change for amendment 3, before any 16-core run

`partA_server.sh` gains a mode **`e0_16`**, and `partA_all.sh` a mode
**`add16`** (the owner's word, once the 185 runs have ended):

- `add16` refuses while the partA chain runs; uploads `partA_server.sh`
  (`.new`, then `mv`; md5 checked); runs `e0_16`; starts `chain` again.
- `e0_16` refuses while the chain runs, and **unless all 185 runs are
  complete** (a chain cut short is resumed with `chain` first). It checks
  that E0 counted each of the 12 traces at least 150 M records (they are
  the same files), writes the six 16-core configs with the frozen tree's
  `make_config.py` exactly as E0 wrote the others (`off_16_<policy>.json`
  with `--regime private --rmw-as-rfo 0`; `default_16_lru.json`), and
  records the binaries it wrote them for (`E0_16` = `E0_PASSED`).
- **The mixes join the job list only while `E0_16` names the frozen
  binaries**, so the job list is the 185 before and 207 after (16a and 16b
  first; E2 includes their LRU runs). A relaunch skips every run already
  complete with its sidecar naming the same binary, so the first 185 are
  not rerun.
- `upstream_equiv.py dir` and `e2` pair logs by name; they need no change.

Rehearsed on the laptop before it is used (results below this line when
recorded).

### Amendment 4, rehearsal part 1 (2026-11-12, laptop; stand-in server)

Setting: a scratch home laid out as the upload makes it (`git archive` of
HEAD's `SRC_DIRS`, `FILES` and the three guards into `~/partA_ours_build`;
upstream f9ed890e built in scratch as `~/partA_up_build`); the 12 SPEC names
linked alternately to the laptop's 429.mcf and 600.perlbench traces;
**20 K + 50 K instructions, 4 at a time** (the first rehearsal used 0.5 M +
1 M on an idle laptop; this one shared it with Q16). The committed runner
(`1f719a5`'s `partA_server.sh`) ran `build` and `chain`; the new one ran from
a separate copy, so the live driver's file was never touched.

- A first attempt with `~/partA_ours_build` as a symlink stopped at
  `check_include_path` (the generated `absolute.options` names the resolved
  path): a stand-in artefact; the server's tree is a real directory. Rebuilt
  as a real tree: build, 3 of 3 guards, frozen copies, E0 on 12 traces hold.
- **The chain: 185 of 185 complete; E1 85 of 85 pairs, E2 15 of 15** (as in
  the first rehearsal).
- **`e0_16`'s refusals and failure:**
  - while the chain runs: refused, nothing written;
  - one run's log moved aside (184 of 185): refused ("184 of 185 runs are
    complete"), no `E0_16`, no 16-core config written;
  - warm-up + simulation above what E0 counted (400 K > 300 K): "E0 (16
    cores) FAILED (12)", no `E0_16`, the job list stays 185. (The six
    configs are written before the verdict; unused while `E0_16` is
    absent, and rewritten by a later `e0_16` that holds.)
  - `E0_16` naming other binaries: the job list stays 185 (`has16` false).
- **16 cores, the two binaries directly** (outside the runner): upstream and
  ours-off on `off_16`-style settings (srrip, private, `rmw_as_rfo 0`), 16
  SPEC traces alternating 429.mcf / 600.perlbench, 200 K + 500 K: both
  complete; **E1 holds** (`upstream_equiv.py pair`: all 2,591 upstream lines
  in order in ours-off's log).

Part 2 (`partA_all.sh add16` through the stand-in ssh: upload, `e0_16`,
`chain` with the 185 skipped and 22 added, E1 and E2 on all 207) follows the
commit of this runner change, since `add16` refuses uncommitted files.

### Amendment 4, rehearsal part 2 (2026-11-12, laptop; stand-in server): `add16` holds end to end

`scripts/partA_all.sh add16` at `30be47e`, through the stand-in ssh / scp,
on the part 1 home (185 of 185 complete; 20 K + 50 K, 4 at a time):

- uploaded `partA_server.sh` (`.new`, then `mv`; md5 equal); `e0_16`: "E0 (16
  cores) holds: E0's 12 traces counted; 6 configs written; mixes 16a, 16b
  added (207 runs in all)"; the chain started.
- **207 of 207 complete. E1 holds on 95 of 95 pairs (0 without a partner);
  E2 on 17 of 17** (16a_lru and 16b_lru: 32 per-type LOAD / RFO lines differ,
  0 other lines).
- **The 185 earlier logs are untouched:** each one's md5 and modification
  time equal before and after (185 of 185).
- A second `add16` while that chain ran: "STOPPED at step 1: the partA chain
  is still running"; the server's script not touched.
- `chain` again after the end: 207 SKIP, 0 START.

On the server, `add16` waits until its 185 runs are complete (2026-11-12
06:30 UTC: 5 of 185, the 8-core runs still going); `e0_16` refuses before
that in any case.

## Amendment 5, 2026-11-13: add16 waits on the server (owner's word: "green flag for everything")

**What changes is when add16's server half runs, not what it does.** The
first chain (185 runs) is slower than estimated: after ~49 h, 9 of 185 were
complete, with the 8-core mixes still running at nice 19 under load 65-90.
Amendment 4 adds the 16-core mixes "once the 185 runs have ended", on the
owner's word. The owner gave that word on 2026-11-13. So that the 16-core
runs do not wait on a person, `scripts/partA_all.sh add16wait` does the
following:
- It stages amendment 4's runner as `~/partA_server.sh.add16`, uploaded as
  `.new` and then moved, with its md5 checked. The live `~/partA_server.sh`,
  which the running chain's jobs execute, is not touched.
- It starts `~/partA_add16_wait.sh` detached.

That waiter:
- checks every 10 min whether the chain is alive, and waits while it is;
- then moves the staged runner onto `~/partA_server.sh`, md5 checked before
  and after;
- runs `e0_16` (which refuses unless all 185 runs are complete) and then
  `chain`, exactly as `partA_all.sh add16` would.

Any refusal or failure stops it with nothing added (log
`~/partA/add16_wait.log`). A reboot ends it, as it ends the chain; then
`partA_all.sh add16` is run by hand.

Tested on the laptop with a stub runner: it waits while a stand-in chain
lives and then adds; it stops on a wrong md5; and it stops when `e0_16`
refuses.
