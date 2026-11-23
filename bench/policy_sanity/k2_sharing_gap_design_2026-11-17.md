# K2: why ChampSim's plain stores find another core's copy less often in fluidanimate and vips -- design (pre-registered 2026-11-17, before any of its numbers is computed)

## Where this comes from

H6(b) (`h6b_attribution_results_2026-11-17.md`) read **K2** for both
programs. Their shortfall is in plain stores (R_store 0.388 and 0.319), not in
lock words, and not in the untraced threads (A2). Its "What follows" names
two candidates, for a note of their own: **drift within a phase**, or
**private-cache capacity**. This is that note.

## Already known, from records scored before today (no new reading)

1. **The private caches are the same size in both simulators.**
   - ChampSim (the F-C configs, `simulator/results/lockfix/cfg/<p>.json`):
     L1D 64 sets x 8 ways = 32 KB; L2C 1,024 x 8 = 512 KB; both LRU.
   - gem5 (`config.ini` of the scored runs): L0D 32 KB, 8-way, LRURP; L1
     512 KB, 8-way, TreePLRURP.
   - What differs: inclusion (gem5's L1 includes its L0 and the L2 the
     L1s; ChampSim's are non-inclusive) and the L1 / L2C replacement policy.
2. **Retention can explain at most part of fluidanimate's gap, and none of
   vips's.** ChampSim's protocol view never forgets a holder, so it bounds
   what any retention rule could add. From the scored rows (`b3_rows_v20.txt`,
   held-out set 2, 2026-11-06):
   - fluidanimate: protocol 25,211 events, R_b 0.538, against the gem5-rule
     view's 18,681, R_g5 0.398 (the bounded view, 18,711). Even a cache that
     never dropped a line would close
     at most (0.538 - 0.398) / (1 - 0.398) = **23% of the shortfall**.
   - vips: protocol 1,032 = gem5-rule 1,032, R_b = R_g5 = 0.309: **none**.
   - **So capacity, as H6(b) named it, is answered: not the main cause.**
     This note tests the other candidate.
3. **Ruled out before:**
   - untraced threads (H6(b) A2);
   - lock words (H6(b) K2: RMW events 4% / 3% of gem5's; the lock fix moved
     neither, 0.400 / 0.308);
   - gem5's CPU model (H5: 0.391 / 0.165 under O3).
4. **Coarse drift** (round 1, T3, `disagree_diagnosis_results_2026-11-06.md`):
   - fluidanimate's cores are as far apart in ChampSim as in gem5 (median
     4.50 M against 7.61 M at gem5's stop);
   - vips's are ten times further apart in ChampSim (10.94 M against 1.14 M).

## Seen before this note (disclosed)

H6(b)'s "reported, deciding nothing" section was read on 2026-11-17, before
this note:
- the distinct lines with events (fluidanimate gem5 7,248, ChampSim 7,529;
  vips 2,762, 974);
- the events per requesting core.

So the split below (fluidanimate: fewer events per line; vips: fewer lines)
was seen before the hypotheses were written. **Nothing about the events'
timing has been computed.**

## Hypotheses

- **H-I, within an episode.** When two cores share a line, gem5 hands it
  back and forth more times in one stretch of time than ChampSim does. The
  cores' relative progress inside a phase decides how finely their accesses
  interleave.
- **H-E, episodes.** ChampSim shares a line in fewer separate stretches of
  time, each with as many hand-overs as gem5's. That points away from
  fine-grained timing, to which phases or which lines are shared.
- **H-D, vips's drift.** vips's cores are about 10 M instructions apart in
  ChampSim (1 M in gem5). A thread then touches a buffer long after its
  partner did, so fewer lines are seen changing hands.

## Step 1: episodes (laptop, H6(b)'s pulled event files only)

**Inputs.** `simulator/results/h6b/g5/<p>/ev.txt` and `.../cs/<p>/ev.txt` (the
events H6(b) counted: QG0, QC0 held), for fluidanimate, vips and canneal 4c.

**Normalised time.** t' = (t - start) / (end - start).
- gem5: start = T_a (`g5/<p>/command.txt`); end = the scored 150 M run's
  `finalTick` (`gem5_b3_view`; QG1 held, the rerun's is equal).
- ChampSim: start = the earliest `Warmup finished` cycle, end = the latest
  `Simulation finished` cycle in `cs/<p>/run.log`.

**Episodes.** For each line, its events in time order. A new episode starts
when the gap to the line's previous event exceeds gamma. **gamma = 0.001 (0.1%
of the window) is primary**; 0.0001 and 0.01 are reported.

**Ratios.** s is H6(b)'s (I_g / I_c: fluidanimate 0.9358, vips 0.9697,
canneal 0.9946). C and G are the events counted, N the episodes.
- Ep = N_C x s / N_G (how many stretches);
- Per = (C / N_C) / (G / N_G) (hand-overs per stretch);
- Ep x Per = R on these events (0.400, 0.308, 1.018);
- share_I = ln(Per) / ln(R), the part of the shortfall inside episodes.

**Readings, fixed now (fluidanimate and vips each, at gamma = 0.1%):**
- **I:** share_I >= 2/3 (supports H-I);
- **E:** share_I <= 1/3 (supports H-E or, for vips, H-D);
- **mixed:** otherwise.

If the reading at 0.01% or 1% differs from the primary one, the note says
"depends on the time scale". The primary reading stands.

**Control, canneal 4c (agrees, R 1.018):** Ep and Per each in [0.8, 1.25] at
gamma = 0.1%. If the control fails, the episode split is called unreliable and
step 1's readings are not used.

**Reported, deciding nothing:**
- median and 90th percentile of events per episode, in each simulator;
- episodes by the number of distinct cores in them;
- events in 50 bins of normalised time, in each simulator, to show whether
  the same phase structure appears in both;
- the same split on store events alone.

## Step 2: vips's drift (laptop, reported only)

- From ChampSim's heartbeats (every 10 M instructions a core), each core's
  position, interpolated at each event cycle; the spread of the four.
- Events per 2% of the window against that bin's spread; Spearman's rho is
  printed.
- gem5 has only its stop counts, so this decides nothing. It says whether
  step 3 is worth running for vips.

## Step 3: a diagnostic run, only if step 1 or 2 points to timing

**When.** fluidanimate reads I, or vips reads E or mixed with rho <= -0.3.

**The test.** A diagnostic ChampSim setting holds a core at dispatch while
it is more than Delta instructions ahead of the slowest running core:
- a core waiting at a synchronisation record, or finished, is never the
  slowest;
- a held core is released whenever every other core waits.
- Delta = 1 M and 0.1 M.
- Programs: fluidanimate and vips. Controls (reported): canneal 4c and
  ocean.

**Prediction under the timing reading:** R_g5 rises by at least 0.15 at
Delta = 0.1 M.

**Conditions.**
- Its build, exact tests and rehearsal go in an amendment before it is
  built.
- It runs only on the owner's word.
- **It is a diagnosis, never the tool's setting.** gem5's threads are not in
  lockstep (fluidanimate's traced CPUs span 7.6 M at its stop).

If fluidanimate reads E instead, the next question (which phases or lines are
shared) goes to its own note, using the sync records' barrier departures.

## Stop rule

- Step 1 and step 2 are laptop-only and take minutes.
- **By Tue 1 Dec, the paper's text on fluidanimate and vips is fixed**,
  whatever has run. It states:
  - what is ruled out (untraced threads, lock words, gem5's CPU model);
  - what is bounded (retention: at most 23% of fluidanimate's shortfall,
    none of vips's);
  - step 1's reading;
  - step 3's result, if it ran.
- No scored verdict changes; nothing is tuned.

## Tools

`scripts/k2_episodes.py` (`run`, `drift`, `selftest`), written after this
note is committed. Before it reads a real file, its self-test runs on
hand-made event files with known episode counts, ratios and readings: an I
case, an E case, a mixed case, and a control that passes and one that fails.

## Amendment 1 (2026-11-17, while building the tool, before it read any real file)

**The ChampSim window's end.** The text above says "end = the latest
`Simulation finished` cycle". That line prints the cycles of the measured
phase, not the cycle since the start. For vips's CPU 2: warm-up finished at
16,223,269; `Simulation finished ... cycles: 91,108,228`; its last heartbeat
reads 107,331,496 at 150 M instructions, and 16,223,269 + 91,108,228 =
107,331,497. Read literally, the end would cut the window short. **The end
is each core's warm-up cycle plus its measured-phase cycles; the window ends
at the latest of these.** This was read from the run logs' marker lines
only; no event time and no metric was computed.

## Build record (2026-11-17)

- `scripts/k2_episodes.py` (`run`, `drift`, `selftest`), as fixed above.
- **Self-test PASS**, on hand-made files with known answers:
  - one case each for I, E and mixed;
  - s != 1;
  - time-scale dependence (gaps of 0.005: E at 0.1%, I at 1%);
  - the control holding and failing (Ep 0.5, Per 2);
  - the stores-only filter dropping an untraced CPU;
  - an event outside the window, counted and kept;
  - the ChampSim window;
  - Spearman's rho (-1 on a constructed drift case; 8 / sqrt(95) on a hand
    case with ties);
  - interpolation;
  - step 3's condition;
  - a malformed event line refused.
- **The self-test catches injected faults:**
  - the window end read literally (amendment 1's error): "cs window" fails;
  - Ep computed without s: "pS" fails.
- **Not run on any real file.** Run on the owner's word:
  `python3 scripts/k2_episodes.py run`, which runs step 1 on canneal,
  fluidanimate and vips, then step 2 on vips, then prints step 3's
  condition.

## Amendment 2 (2026-11-17): step 3's setting, checks, runs and readings, before it is built

Step 1 read fluidanimate as **I** and vips as **E**, with vips's rho -0.252
(`k2_sharing_gap_results_2026-11-17.md`, `d2ea161`). By the rule above,
**step 3 is indicated by fluidanimate**. This fixes how it is built, checked
and read.

**The setting `sync_lead_limit` (instructions; default 0 = off).** With 0,
nothing is called and nothing is printed. Otherwise, in every cycle:
- pos(c): instructions core c has retired since its trace's first record
  (warm-up included).
- **Waiting:** core c's dispatch head is held by a sync record this cycle
  (a recorded wait, or its mutex).
- **Done:** core c has completed the current phase.
- **S:** the cores neither waiting nor done; min = the lowest pos over S.
  If S is empty, no core is held.
- **Held:** core c is not dispatched in a cycle where pos(c) - min > Delta,
  unless its head is already sync-held. As with a sync hold, the
  instruction stays at the head. Done cores are held too.
- **Consequences, by construction:**
  - the slowest core of S is never held;
  - a core is released whenever every other core waits or is done
    (then S holds it alone);
  - a core's retired lead over min can exceed Delta by at most what its
    ROB holds when the hold begins, plus one dispatch group: ROB_SIZE 352
    plus DISPATCH_WIDTH 6 in these configs.
- A lead-held cycle counts as a held cycle for the livelock check only.
  It is not added to CYCLES HELD. A machine-wide stall is still caught by
  DEADLOCK_CYCLE.
- **Records (printed only when on):**
  - `SYNC LEAD LIMIT: <Delta> instructions`;
  - per CPU, `CPU n LEAD HOLDS: cycles measured X warmup Y; max lead Z`;
  - Z is the largest pos(c) - min over the cycles in which c was in S.

**Checks, before any diagnostic run's ratio is read.**
- **KL0 (server, as F-C's K0):**
  - the new binary, without the setting, against `champsim_fc_a2e88e46`:
    Q0 on 8 short runs and Q0m on canneal4, ocean4 and barnesstd_force,
    each log identical line for line;
  - the exact suite with the new binary: 66 of 66 PASS, and its logs
    identical to the F-C binary's.
- **KL1 (laptop, exact):** the micro program, two threads with no sync
  records, one fast (no memory) and one slow (dependent misses).
  - Delta 100,000: the fast core's max lead is at most Delta + 358; its
    lead-held cycles are above 0 and the slow core's are 0; both complete.
  - Without the setting, the lead exceeds 1,000,000 (the case
    discriminates).
- **KL2 (laptop):** `sync_barrier`, `mx_lock` and `mx_condbar` at Delta =
  1,000 complete, with no deadlock and every hand count of the case met.
- **Q3** on every diagnostic run: complete, unexplained view-order
  violations 0, no trace wrapped, one `SYNC LEAD LIMIT` line.

**Runs (8; on the owner's word).**
- fluidanimate, vips, canneal 4c 2 MB, ocean 4c 2 MB, each at Delta =
  1,000,000 and 100,000.
- Each run: its F-C rerun's config (`sync_lock_word request`) plus
  `sync_lead_limit` and nothing else, its traces and window.
- Trees `phaseA_b3_k2d1m_<p>4` and `phaseA_b3_k2d100k_<p>4`.
- fluidanimate at 100,000 also writes `COHERENCE_EVENT_LOG` (records only,
  as H6(b)), so that step 1's split can be read on it.
- **Never the tool's setting.** gem5's threads are not in lockstep.

**Readings, fixed now** (R_g5 from the run's rows by b3_score's formula,
against the F-C row of the same span: fluidanimate 0.400, vips 0.308,
canneal 4c 1.018, ocean 0.712).
- **Primary, fluidanimate at Delta 100,000:**
  - **rise >= 0.15: timing SUPPORTED.** Keeping ChampSim's cores together
    closes part of fluidanimate's within-burst gap.
  - **rise < 0.15: NOT SUPPORTED by this test.** The paper states the gap
    without the timing explanation.
- **Specificity:** if either control moves by 0.15 or more at the same
  Delta, the reading adds "not specific to fluidanimate".
- **Reported, deciding nothing:**
  - every run's R_g5, R_b, traffic and cycles against its F-C run, with
    lead-held cycles and max lead;
  - vips at both Deltas (step 3 was not indicated for it);
  - fluidanimate at Delta 1,000,000;
  - fluidanimate at Delta 100,000 split by step 1 (`k2_episodes.py` on
    its event log against gem5's events): Ep, Per, share_I.

**Stop rule unchanged:** the paper's text is fixed by Tue 1 Dec whatever
has run. No scored verdict changes.

## Amendment 3 (2026-11-17, while building step 3, before KL2 or any server check has run)

- **KL2's cases.** Amendment 2 named `mx_lock` and `mx_condbar`. These are
  Q2b's Pin-traced glibc programs, run through `bench/micro_champsim.sh`,
  which takes no config option. KL2 uses the exact suite's hand-counted
  cases instead: `sync_barrier` (barrier), `mx_handover` (mutex hand-overs
  between cores) and `mx_cond` (a condition variable), at levels 0, 1 and
  2, with Delta = 1,000. The suite gains `LEAD=N`: with it, every config
  sets the limit and every log must print `SYNC LEAD LIMIT: N
  instructions` once; without it, no log may print a lead line (so K0 also
  checks that the setting is absent). **Criterion unchanged:** the suite
  PASSES, meaning every hand count is met and nothing deadlocks.
- **Where.** KL2 runs on the server inside `check`, after K0, not on the
  laptop (the owner's rule: as little laptop load as possible). KL1 stays
  on the laptop (`bench/lead_micro.py`, two synthetic traces, about 15
  minutes).
- **Q0l**, the chain's gate, works like F-C's Q0r: the four programs at
  Delta 100,000, 1 M + 2 M. Each must complete and print one lead line, a
  LEAD HOLDS line per core, the request line, and 0 unexplained
  view-order violations. It decides only whether the chain may start;
  nothing in it is read.
- **Q0m** uses the F-C configs (request) on both binaries, since the
  reference is now the F-C binary.
- **fluidanimate's event file.** The 100,000 run's `COHERENCE_EVENT_LOG`
  becomes `ev.txt` through H6(b)'s `h6b_attr.py champsim`, with H6(b)'s
  `rmw.txt` of the same traces.
- **Tools:**
  - `scripts/k2lead_server.sh` (`check`, `chain`, `status`, `q3`, `stop`)
    and `scripts/k2lead_all.sh` (`check`, `go`, `status`, `pull`, `stop`):
    copies of F-C's runner;
  - builds in `~/k2_build`, state in `~/k2lead`;
  - binary `champsim_k2_<md5>`;
  - trees `phaseA_b3_k2d<1m|100k>_<p>4`.

## Step 3 build record (2026-11-17, laptop; before any server check or run)

- **Code:**
  - `simulator/inc/sync_replay.h` and `src/sync_replay.cc`:
    `set_lead_limit`, `lead_limit`, `lead_check`, `note_lead`, `set_done`,
    and the two lines `SYNC LEAD LIMIT` and `CPU n LEAD HOLDS`, printed
    only when the limit is on.
  - `src/ooo_cpu.cc`: dispatch stops while the core leads by more than
    Delta. A lead-held cycle counts toward the livelock check only.
  - `src/champsim.cc`: a core counts as done at the end of its phase.
  - `src/legacy_environment.cc`: reads `sync_lead_limit` (default 0, off).
  - `scripts/make_config.py --sync-lead-limit N`: the key is written only
    when given.
  - The laptop build's md5 is d3456edd957145a2afe376e8901d216f. The server
    builds its own binary in `check`.
- **KL1** (`bench/lead_micro.py`; laptop, 18.5 min; three logs, md5
  4d892a24 / 746a3c49 / a5d784a7):
  - KL1a: core 0 held 33,443,453 cycles, max lead 100,352 (bound
    100,358), core 1 held 0, both complete.
  - KL1b: max lead 1,490,200 at Delta 10^12, no held cycle.
  - KL1c: 1,127 lines, 0 differ from KL1b once the lead lines and time
    stamps are set aside.
  - **Disclosed:** the first judging printed KL1a FAILS with every bound
    above met. The checker's "both complete" counted `complete CPU` lines,
    and those include the two `Warmup complete CPU` lines (4 for 2). Fixed:
    it now counts `Simulation complete CPU` lines (2) and requires the end
    marker. The fix is applied to all three cases, and a `judge WORK` mode
    re-reads the existing logs. Re-judged on the same three logs without a
    rerun: **KL1a, KL1b and KL1c hold.** The criterion is unchanged.
- **The exact suite** (`check_coherence_exact.sh`) gains `LEAD=N` (amendment
  3). It parses. It runs only on the server: K0 without LEAD, KL2 with
  `LEAD=1000`.
- **Server tools** (amendment 3): `scripts/k2lead_server.sh` and
  `scripts/k2lead_all.sh`. They were read against the server's paths
  (read-only):
  - `~/h6b/h6b_attr.py` equals the committed one (md5 a5a86cce);
  - `~/h6b/cs/fluidanimate/rmw.txt` is present;
  - `~/k2_build` and `~/k2lead` do not exist yet;
  - the F-C configs, the F-C binary (md5 a2e88e46) and the four reference
    logs are present.
- **Next:**
  1. `bash scripts/k2lead_all.sh check`: build, guards, Q0, Q0m, Q0l, K0,
     KL2. It starts no run.
  2. On CHECK PASSED, `bash scripts/k2lead_all.sh go`: 8 runs.
