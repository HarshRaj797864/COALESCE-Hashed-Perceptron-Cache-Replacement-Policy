# H6(b): where gem5's extra sharing events are, in fluidanimate and vips. Pre-registered 2026-11-14, before anything is built or run

PLAN § 10 item 9, H6(b). Owner, 2026-11-14: "besides the paper do
everything", then "ok do all of them".

## The question

Two set-2 programs pass every check, discriminate, and fail P15. These are
the F-C reruns (`lock_fix_score_v1.txt`); C and G are store-time sharing
events (store misses that find the line at another core, gem5's rule), I the
window's instructions:

| program | gem5 G / I_g | ChampSim C / I_c | R_g5 | D, events gem5 has beyond the band's floor |
|---|---|---|---|---|
| fluidanimate | 43,879 / 386,005,066 | 18,744 / 412,469,348 | 0.400 | 8,796 |
| vips | 3,242 / 398,703,787 | 1,031 / 411,142,861 | 0.308 | 1,242 |

D = G - 2 x C x I_g / I_c.

**Round 1** (`disagree_diagnosis_results_2026-11-06.md`) left three
candidates:
- **untraced CPUs (H-A):** gem5 runs threads ChampSim does not have.
  Rejected for fluidanimate: 84 messages to them. For vips, an upper bound
  (1,430 >= D) leaves it possible.
- **contended locks (H-K):** gem5 executes 19,112 more RMWs than the native
  run on fluidanimate. ChampSim's replay has only 68 contended acquires
  there. So F-C changed nothing.
- **data sharing (H-D):** ChampSim sees fewer store misses on ordinary data.

Round 1 had only totals. This note attributes **each** gem5 event (who asked,
who held the line, which kind of instruction), and each ChampSim event the
same way. The candidates can then be told apart.

## The instrument: gem5's own protocol trace

gem5 25.1 prints every Ruby transition under the debug flag `ProtocolTrace`
(`src/mem/slicc/symbols/StateMachine.py:1750`): tick, controller number,
controller (`L0Cache`, `L1Cache`, `L2Cache`), event, state > next state,
line address. With randomization off, a run with the flag is the same
simulation (QG1 checks it). The sequencer prints `Seq Begin` with the
request's address and type (`Sequencer.cc:1157`). The L0, L1 and sequencer
numbers equal the CPU index (`MESI_Three_Level.py`; QP checks it).

**A gem5 event** is an `L2Cache` transition on `L1_GETX` from state `SS` or
`MT` (not a stall line): exactly what `b3_score.py` counts from stats.
- **Requester:** the oldest unpaired `L1Cache` transition `Store` from `I`
  (or `NP`) to `IM` on the same line. Each `L2Cache` `L1_GETX`, in any state,
  takes one from that line's queue.
- **Holders:**
  - in `MT`, the first later `L1Cache` `Fwd_GETX` on the line by another
    core;
  - in `SS`, every `L1Cache` `Inv` on the line by another core, until the
    requester's `IM` completes (`Data_all_Acks`, or `Ack_all` from `SM`).
- **Instruction:** the requester's latest `Seq Begin` on the line before its
  `IM` transition.
  - `Locked_RMW_Read` / `Locked_RMW_Write`: a locked RMW.
  - `RMW_Read`, or `ST` right after the same core's `RMW_Read` on the same
    address: a plain RMW.
  - Any other `ST`: a store.
- **Anomalies, counted:** an `L1_GETX` with nothing to pair, an event with no
  holder found, an event with no `Seq Begin`.

**A ChampSim event** is a measured-phase `G` line of the coherence event log
with a nonzero gem5-rule field.
- Requester: its CPU.
- Holders: the field's bits.
- Instruction: an RMW if its `ip` is the `ip` of a trace record whose
  destination address equals one of its source addresses; else a store.

## The runs (records only; nothing scored changes)

**gem5:**
- fluidanimate, vips and canneal 4c (the control), each rerun exactly as its
  scored 150 M run: the command line from that run's `run.log`, a new output
  directory, inputs copied as `run_one` copies them;
- plus `--debug-flags=ProtocolTrace --debug-start=T_a`, where T_a is the 50
  M run's `finalTick`;
- the output is filtered in the pipe (`L1Cache` and `L2Cache` transitions;
  `Seq Begin` of `ST`, `RMW_Read`, `Locked_RMW_*`) and compressed.

**ChampSim:** fluidanimate4, vips4 and canneal4, each its F-C rerun
(`champsim_fc_a2e88e46`, its config, window and traces) with
`COHERENCE_EVENT_LOG`.

**The traces:** one pass over each run's traces for the RMW `ip`s and, for
the line classes, the lines RMWs touch. It reads records up to warm-up +
simulation + 5%; record positions include sync records, so the measured
span is approximate (disclosed).

## Checks, in order

- **QP, before any real run:** the micro program (`~/micro/micro_m5`,
  micro_server.sh's 4-CPU settings) under gem5 with `ProtocolTrace`, cases
  `pp_store`, `pp_lock`, `pp_rmw` and `readers`, 4 rounds. Round j uses
  A = j % 4, B = (j + 1) % 4, C = (j + 2) % 4, D = (j + 3) % 4.
  - Each case must show at least 4 lines with exactly the hand pattern:
    - `pp_store`, `pp_lock`, `pp_rmw`: 3 events, (requester, holder) =
      (B, A), (A, B), (B, A); instruction store / locked RMW / plain RMW;
    - `readers`: 1 event, requester D, holders {A, B, C}, a store.
  - Zero anomalies on those lines.
  - **If QP fails, nothing else runs.**
- **QG0:** the run's events from T_a on equal its stats' window count
  (150 M run minus 50 M run, `SS` + `MT` `L1_GETX`) within 0.1%.
- **QG1:** the rerun's stats equal the scored 150 M run's (host statistics
  aside). If not, the readings use the rerun's own counts and are labelled
  "a rerun, not the scored run".
- **QE0:** each ChampSim run's log equals its F-C rerun's, times masked. If
  not, its event log is not read.
- **QC0:** the event log's events equal the run log's gem5-rule count.
- **Anomalies:** more than 1% of a program's gem5 events unpaired, without a
  holder, or without an instruction stops its readings.

## Readings (fixed now)

s = I_g / I_c, from the scored rows above. R_k = C_k x s / G_k, for a class
k.

**Step 1, H-A.** G_u = gem5 events with an untraced CPU as requester or
holder (fluidanimate: CPU 0; vips: 0, 1 and 2; canneal: 0). ChampSim has no
such events.
- **A1:** C x s / (G - G_u) >= 0.5. H-A can explain the failure; F-W
  follows by its own note.
- **A2:** otherwise.

**Step 2, on the remaining events.** Split by instruction: RMW (locked and
plain) and store.
- **K1:** R_store in [0.5, 2] and R_RMW < 0.5. The excess is RMW
  (lock-word) traffic.
- **K2:** R_store < 0.5. ChampSim under-counts data sharing (H-D).
- **K3:** anything else (stated).

**Control (canneal 4c, which agrees):** every class with at least 100 gem5
events must have R_k in [0.5, 2].
- If the control fails, the class split is reported as unreliable and K1-K3
  are not read.
- A1 / A2 are read anyway: they rest on the participants, not the split.

**Reported, deciding nothing:**
- the locked / plain split of the RMW events;
- line classes (lines an RMW touches, or not);
- the 10 hottest lines' share and the number of distinct lines;
- events per requesting core in both simulators;
- the number of holders (1 or several);
- for fluidanimate, gem5's locked events on lines with locked RMWs from at
  least two cores: the contention count.

## What follows

Nothing is scored or tuned.
- **A1 for vips:** F-W (trace the main thread, a stop rule for the workers)
  gets its own note.
- **K1:** gem5's timing makes more lock contention than the native run and
  the replay. The replay cannot reproduce that without modelling contention
  timing; it is stated as a limit, with these numbers.
- **K2:** the next round asks why ChampSim's stores find fewer holders:
  drift within a phase, or private-cache capacity. Its own note.

## Tools

- `scripts/h6b_attr.py`:
  - `gem5` (the parser above), `qp`, `champsim`, `rmwips`, `report` (the
    readings), `selftest` (hand cases: pairing, holders, instruction kinds,
    anomalies).
- `scripts/h6b_server.sh` (server): `guards`, `go` (QP first, then the
  three gem5 reruns, three ChampSim runs and the trace passes, then the
  report, detached, nice 19), `status`.
- `scripts/h6b_all.sh` (laptop): `go`, `status`, `pull`.

Rehearsed against a stand-in server and a stand-in gem5 before launch.

## Amendment 1 (2026-11-14, before anything ran): what gem5 prints, read from its source

Found by reading gem5 25.1's source on the server (`~/gem5/src/mem/ruby`)
before the parser met any real trace. Each finding would have broken the
parser above.

1. **The sequencer prints a request's secondary type** (`Sequencer.cc:1157`,
   `RubyRequestType_to_string(secondary_type)`).
   - For a locked RMW's read and write, and for a plain RMW's read, the
     secondary type is `ST` (`Sequencer.cc:1002-1008`, `1046-1047`).
   - So `Seq Begin` reads `ST` for a store, a locked RMW and a plain RMW
     alike. The note's kinds could not be read from it: QP would have failed
     on `pp_lock` and `pp_rmw`, and nothing would have run.
2. **An upgrade can arrive at the L2 as `L1_GETX`.**
   - The L1 issues GETX only from `I` (`I, Store -> IM`) and UPGRADE from `S`
     or `SS` (`-> SM`). The L1 has no `NP` state.
   - The L2 takes an UPGRADE as `L1_GETX` when the requester is no longer
     a sharer (`MESI_Two_Level-L2cache.sm:285-290`): it lost its copy while
     its upgrade waited.
   - The note's pairing queued only `I -> IM` issues.
3. **Stalled requests print again.**
   - The L2's `zz_stallAndWaitL1RequestQueue` transitions print as ordinary
     lines, once when the request stalls and again when it is woken. The
     states are `{SS_MB, MT_MB, MT_IIB, MT_IB, MT_SB}`, `{I_F, MT_F, I_FF}`,
     `{IS, ISS}`, `IM` and `{I_I, S_I, MT_I, MCT_I, M_I}`.
   - The note's rule ("each L2Cache L1_GETX, in any state, takes one") would
     have taken several issues for one request.

**The instruction, new rule.**
- The awk filter in the pipe sees every `Seq Begin`, loads and fetches
  included. An `ST` whose core's previous request (any type) was an `ST` at
  the same address is written `Seq Pair`.
- TimingSimpleCPU has one memory request outstanding at a time, and an RMW's
  read and write are consecutive micro-ops of one instruction. So the
  pair's first `ST`, the read that takes the line, is an **RMW**. A
  **store** is any other `ST`.
- **Locked and plain RMWs cannot be told apart.**
  - The locked / plain split leaves the reported items.
  - fluidanimate's contention count becomes "RMW events on lines with RMWs
    from two or more cores".
  - QP's `pp_lock` expects an RMW.
  - ChampSim's kind (destination = a source) already counts both.
- **Misread, disclosed and not measured:** two consecutive stores by one core
  to the same address, with no fetch or load between, read as an RMW.

**The pairing, new rule (replaces "Requester" and "Holders" above).**
- A **transaction** opens at each L2 transition that pops a request:
  `L1_GETX` in `NP`, `SS`, `M` or `MT`, and `L1_UPGRADE` in `SS`. Other
  states are stalls and are skipped. A state in neither list is counted.
- The L2 blocks the line (`SS_MB`, `MT_MB`) until the requester unblocks.
  So the **requester** is the core whose L1 next completes `IM > M`
  (`Data_all_Acks`) or `SM > M` (`Ack_all`) on the line. This does not
  depend on the order in which requests reach the L2. The note's issue-order
  pairing is kept only as a count ("events the issue order pairs
  differently").
- **Holders:** every core, the requester aside, that prints `Inv`, `Fwd_GETX`
  or `L0_Invalidate_Else` on the line while the transaction is open.
  `L0_Invalidate_Else` is the L1's form of both when its L0 holds the line
  (`MESI_Three_Level-L1cache.sm:357-377`).
- **Stale holders (new, reported):** holders whose every such line was an
  `Inv` in `I`, `IM`, `IS` or `IS_I`, i.e. sharers the L2 still lists
  without a copy.
- **Instruction:** the requester's latest `ST` Seq Begin on the line before
  its L1 issue. It is an RMW if a `Seq Pair` follows it.
- **Unchanged:**
  - an event is a transaction opened by `L1_GETX` in `SS` or `MT`;
  - the gated anomalies: an event that never completes, an event with no
    holder, an event with no instruction (1%);
  - the readings, the checks and the control.
- **Reported parser counts (new):**
  - issue-order disagreements;
  - requester among holders;
  - completions without a transaction (the L2 step came before the trace
    began);
  - L2 requests without an L1 issue in the trace;
  - unlisted states;
  - issues while one is pending, and issues left pending;
  - pairs without their first request.

## Build and rehearsal record

- **`scripts/h6b_attr.py` self-test PASS.** Its hand trace has:
  - an UPGRADE taken as `L1_GETX` after the L2 served another core first:
    the issue order names the wrong requester twice, the completions name
    the right one;
  - stalled lines that must not pop;
  - a stale holder;
  - an `L1_UPGRADE`, which is not an event;
  - an unlisted state;
  - an RMW whose `Seq Pair` comes after its completion;
  - a pair without its first request.
- **`scripts/h6b_server.sh`:** the pipe's filter is the awk above.
  `filter_check` is a guard that runs the awk on a hand case (pairs within
  a core; a load or a no-address request between breaks a pair; other
  controllers' lines are dropped). The server's awk is GNU Awk 5.2.1.
- **Rehearsed against a stand-in server** (scratchpad). The stand-in gem5
  prints what gem5 25.1 prints:
  - secondary types;
  - a fetch before each instruction;
  - the no-address `Seq Begin`;
  - an RMW's write after its read completes;
  - stalled L2 lines printed again.

  QP holds 4 of 4. The chain for the three programs ran: QG0, QG1, QE0 and
  QC0 hold, and the reports print (8 of 23 stand-in events are RMWs, as
  built). An injected fault (`pp_rmw` without its write) fails QP and stops
  the chain.
- **The cost, estimated:**
  - one trace about 0.5-2 GB compressed;
  - the gem5 reruns as long as the scored 150 M runs, plus the printing
    after T_a, under the 96 h limit;
  - the guard keeps 30 GB free.

## Launch record

- **2026-11-14 17:19:02 server time:** `bash scripts/h6b_all.sh go`
  (`15c7b57`). The three scripts were uploaded and their md5s checked
  (h6b_server.sh 62a35c3d, h6b_attr.py fdffc9e4, h6_lockreq.py 41be3105).
- **Guards pass:** `champsim_fc_a2e88e46`, gem5 md5 24b116bb, micro md5
  22652611; the F-C reruns are complete and the gem5 runs present; the
  self-tests and the filter's hand case pass; 79 GB free. Server load 110.
- QP's four gem5 runs started first. The programs run only if QP holds.

## Amendment 2 (2026-11-15, after QP FAILED; no program run had started, nothing of any program read)

### What happened

- **QP FAILED on the server, 2026-11-14 19:36:19.** All four cases read 0
  events, and the chain stopped as the note orders.
- **The cause is mine: the parser and the pipe's filter assumed a bare hex
  address.** gem5 25.1 prints every address through `printAddress`
  (`src/mem/ruby/common/Address.cc:76`), as `[0xADDR, line 0xLINE]`. That
  includes the Sequencer's `Seq Begin` (Sequencer.cc:1157, `%#x` given a
  string), whose type then comes last. Amendment 1 read the format string
  but not what `%#x` receives. The rehearsal's stand-in shared the
  assumption.
  - **The parser** crashed on the first L1 line, `ValueError:
    '[0x1a00,'` (`attr.err`), so `ev.txt` is empty.
  - **The filter** read the type from field 7, which is `line`, so it
    dropped every Seq line. The failed QP's traces (kept on the server and
    copied to the laptop scratchpad) hold the L1 and L2 lines intact but no
    Seq line. Kinds cannot be read from them.

### Seen after the failure (disclosed)

With the parser fixed, I read the failed QP's four traces with kinds
ignored.

- **Ping-pong cases (rounds 0-3, old rule):** the requester and holders
  matched rounds 0, 2 and 3, not round 1. Round 1's line (`0x3ec040`) lacks
  one hand-over. Core 2's L1 replaced the line from MM (`L1_Replacement
  MM>M_I`, then the L2's `L1_PUTX MT>M`) 154 ticks before core 1's store. So
  core 1's GETX found the L2 in `M` with no other holder: by definition,
  no event. The micro's caches are tiny (2 kB L0D, 8 kB L1D).
- **readers:** all four rounds matched under the old rule. A first draft of
  the new rule removed any replacing holder, and it failed readers round 1.
  - There, readers 1 and 2 dropped their SS copies silently (no message).
  - The L2 still listed them and sent each an Inv, so the event has holders
    {1, 2, 3}, 2 of them stale.
  - The rule was refined to what the protocol does: only an E / M
    replacement (a PUTX) removes a holder; an S replacement leaves the core
    as a stale holder, and the stale count is checked too.
- **Both behaviours are gem5's documented ones.** They were measured on
  2026-10-18 (`micro_results_2026-10-18.md`): gem5 forgets an EXCLUSIVE
  holder when its private caches drop the line, and keeps SHARED readers
  that dropped their copies.

### QP's rule, amended

- Each round's events must equal the hand sequence's exactly: requester,
  holders, kind, and the number of stale holders.
- A round is found by its line's L1 store issues: exactly A, B, A, B
  (ping-pong), or exactly D after loads by A, B and C (readers).
- **E / M replacement:** a hand-over is removed from the expected list iff
  the raw trace shows the holder's `L1_Replacement` of the line from E / M
  (EE, MM). It must fall between the holder's own store issue (a reader's
  load) and the requester's store issue.
- **S replacement:** the holder stays, counted stale.
- A round with no expected event left fails. Every case needs all four
  rounds, as before.
- The raw records come from `h6b_attr.py gem5 ... --repl` (QP only). It
  writes `S` / `L` / `R tick line core state` for L1 store and load issues
  and replacements.
- **On the failed QP's traces, kinds not checked, all four cases hold:**
  - ping-pong: holders removed [0, 1, 0, 0] in each case;
  - readers: stale holders [0, 2, 0, 0].
- **Kinds are checked only on a rerun.**

### Changes

- **`h6b_attr.py`:**
  - `addr_of` reads both address forms;
  - a Seq line's type is its last field;
  - `--repl`;
  - `qp` rewritten as above.
- **`h6b_server.sh`:**
  - the filter finds the address as the first `[0x...,` field and writes
    each ST line normalised (`tick core Seq Begin|Pair > 0xADDR ST`);
  - `filter_check`'s hand case is in gem5 25.1's form, one line in the bare
    form, and one same-line, other-byte ST that must not pair;
  - QP calls `gem5 --repl`;
  - new mode `go2`: only when DONE says QP FAILED. It keeps the failed QP
    as `~/h6b/qp.fail_a1_<time>` (and its DONE), then runs `go`: guards,
    QP, and the chain if QP holds.
- **`h6b_all.sh`:** `go2` (requires this amendment).
- Nothing else changes: the programs, the runs, QG0, QG1, QE0, QC0, the
  anomaly gate, and the readings.

### Checked before the rerun

- **Self-test PASS:**
  - the hand trace again in gem5 25.1's address form gives the same events
    and anomalies;
  - QP: 3 positive cases (pp_store with an MM eviction, readers with a
    silent SS drop, pp_lock) and 3 faults (kinds differ, an event the
    eviction rules out, the stale count differs).
- **`filter_check` PASS** (it is one of the guards).
- **The real traces:** parsed whole (16.9 M L1 / L2 lines a case). No event
  was unpaired or without a holder.
- **Rehearsal against a stand-in server.** The stand-in now prints gem5
  25.1's form: the NetDest on L2 lines, `TLBI` as the no-address form, an
  MM eviction in round 1, and a silent SS drop in readers. Results:
  - `go2` from a failed-QP state: the failed QP kept aside;
  - QP holds 4 / 4 (removed [0, 1, 0, 0], readers stale [1, 1, 1, 1]);
  - the chain completes, with kinds read (canneal: RMW 13, store 24, no
    instruction 0);
  - `go2` refuses on a finished chain, and `go` refuses while DONE exists.

## Relaunch record (amendment 2)

- **2026-11-14 19:54:57 server time:** `bash scripts/h6b_all.sh go2` from
  `b34f55d`.
- **Uploaded md5s:** h6b_server.sh 5cad4cec, h6b_attr.py a5a86cce,
  h6_lockreq.py 22becbf6.
- **Guards pass on the server:** filter_check in gem5 25.1's form, both
  self-tests, F-C reruns complete, gem5 runs present; 72 GB free.
- **The failed QP is kept as `~/h6b/qp.fail_a1_20261114_195457`.** QP runs
  again, then the chain if it holds.
- **QP HOLDS, 2026-11-14 23:09:05 server time,** on all four cases with kinds
  checked:
  - pp_store `store`; pp_lock and pp_rmw `rmw`; readers `store`;
  - rounds [1, 1, 1, 1] in each case;
  - holders removed [0, 1, 0, 0] in each ping-pong case; readers stale
    [0, 2, 0, 0]. That is the pattern the failed QP's L1 / L2 lines showed,
    now with kinds.
  - Gated anomalies 0 in every case (unpaired, no holder, no instruction).
    Reported: "issue order pairs differently" 2 a case.
- **The program runs started the same second:** 3 gem5 reruns with
  ProtocolTrace and 3 ChampSim runs with the event log.
