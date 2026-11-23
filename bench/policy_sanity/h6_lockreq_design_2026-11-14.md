# H6(a): why an F-C lock-word request adds about 0.56 gem5-rule events, not 1 to 2. Pre-registered 2026-11-14, before the run

PLAN § 10 item 9, H6(a). Owner, 2026-11-14: "besides the paper do
everything". A diagnosis: **nothing here changes the tool**. A fix would
need its own note and the 20-Nov rule of `lock_fix_design_2026-11-12.md`.

## The question

F-C (`lock_fix_design_2026-11-12.md`, adopted 2026-11-14): on the first
contended cycle of a mutex hold, the waiter issues one ownership request for
the mutex's word (`src/ooo_cpu.cc:445-458`). The lock-wait note predicted
k = 1 to 2 gem5-rule events per request:
- one from the request itself, which finds the holder listed;
- one more when the holder's release takes the line back from the waiter.

Measured on barnes std start: (C_F-C - C_before) / requests = 0.564, over
44,246 measured requests. So R_g5 reads 0.449, against a predicted
[0.614, 0.994]. Barnes std window (0.563) and barnes-256 (0.574) read the
same (`lock_fix_results_2026-11-14.md`, "not diagnosed").

## The run (records only)

- **Binary:** `champsim_fc_a2e88e46` (md5 a2e88e46...), the binary the result
  came from.
- **Configuration:** the F-C rerun of barnes std start, exactly as it ran:
  config `~/sync_fc/cfg/barnesstd_start.json` (md5 3efd5110...), window 0 +
  37,900,000, the four traces its `cmd.txt` names
  (`traces/sync_mx/barnesstd/raw0_aligned, raw1, raw2, raw3`).
- **The only difference:** `COHERENCE_EVENT_LOG` set. The log is written by
  `cache.cc` (`dir_log_event`, `dir_invalidate_line`). Its 13 fields are
  `kind cache cycle warmup cpu instr_id ip v_line line type protocol_others
  presence_others g5_others`; an `I` line has 12.
- **QE0, before anything is read from the log:** the run's own log equals
  the F-C rerun's (`phaseA_b3_fc_g3_barnesstd4_start/.../run.log`) line for
  line, once each `(Simulation time: ...)` is masked. If QE0 fails, the
  event log is not read, and the difference is diagnosed first.

## Identifying a request in the log

An F-C request carries its ACQUIRE record's `ip` and `instr_id`
(`ooo_cpu.cc:450-452`) and the mutex's address. A record's `ip` is the call
site (`champsim_tracer.cpp`: "the call's code address"). That call's own
instruction pushes to the stack, never to the mutex. So **a request's event
is a G (an RFO accepted at the LLC) or a U (an upgrade at a private cache)
whose `ip` is an ACQUIRE record's `ip` and whose `v_line` is that record's
mutex line.**

The pairs (ip, mutex line) come from the four traces' sync records:
`destination_memory[1]` = SYNC_MAGIC, kind 2, mutex non-zero. They are read
by scanning the records the window covers and more; the extra records add
only pairs that never appear in the window.

Checks on the identification (before any class is read):
- **QI1:** for each CPU, identified request events ≤ that CPU's measured
  `LOCK-WORD REQUESTS`.
- **QI2:** no measured-phase L, W or S event has a request pair. A request
  is an RFO: an L there would mean a normal load shares the pair.

If QI1 or QI2 fails, the classes are not read. The failure is reported.

## The classes (fixed now)

For each measured request (per-CPU totals from the run's `LOCK-WORD
REQUESTS` lines):
- **R0, no event:** requests minus identified events. The request stayed in
  the waiter's private caches (a hit with no other core listed, or merged
  with a miss in flight). It reached neither the LLC nor an upgrade.
- **R1, nobody listed:** an event whose `protocol_others` and `g5_others`
  are both 0.
- **R2, listed by the protocol view, forgotten by the gem5 rule:**
  `protocol_others` ≠ 0 and `g5_others` = 0. The other core's private copy
  was dropped before the request arrived.
- **R3, an event:** `g5_others` ≠ 0, reported by the number of other cores
  listed, in two parts:
  - **R3G**, a G: it counts in C, R_g5's numerator (`COHERENCE DIR RFO
    GEM5-RULE EVENTS`);
  - **R3U**, a U: it counts in the upgrades (U_g5), **not in C**.

**Take-back, for R1-R3** (each is located in the log): the next G or U on
the same line by another core. The fraction whose `g5_others` lists the
waiter, and the cycle gap to it (median, quartiles). This is the holder's
own lock store, or its release, taking the line from the waiter.

**Added per request, decomposed** (C counts G events only):
- C_F-C - C_before = 0.564 x 44,246 ≈ 24,950 events (from the scored rows);
- the requests' own events in C = R3G;
- the rest = net events the request moved elsewhere in C: displaced
  (negative) or caused (take-backs).

## Readings (fixed now; R0-R3 sum to the requests)

- **The leading cause** is the largest of R0, R1, R2 and R3U (the classes
  that add nothing to C), if it covers at least half of the requests that are
  not R3G. Otherwise there is no single cause, and the shares are reported.
- **"The request's event is an upgrade, which C does not count"** is
  supported if R3U leads. The waiter already holds a shared copy of the
  lock word; gem5 counts the same situation as an upgrade too.
- **"The request goes out before the holder has taken the lock word"** is
  supported if R0 and R1 together are at least half of the requests that add
  nothing to C, and if at least half of R1's take-backs list the waiter.
  - A record's grant happens at dispatch (`mutex_take`), but the holder's
    own lock store reaches memory later. So the waiter's first contended
    cycle can come before the holder's store.
  - This is a property of F-C's issue point. It is not a defect of the
    view.
- **"The holder's copy was already dropped"** is supported if R2 leads.
- If R3G ≥ 0.9 of the requests, the shortfall is not the request's own
  event. It lies in displaced events, and the decomposition says how many.
- Nothing is decided about the tool. The paper states the 0.449 as an open
  under-count and, once this is scored, its cause or causes.

## Tools

- `scripts/h6_lockreq.py`:
  - `pairs TRACE...` reads the (ip, mutex line) pairs from xz traces;
  - `qe0 A B` compares two run logs with times masked;
  - `classify EVENTLOG PAIRS RUNLOG` gives QI1, QI2, the classes, the
    take-backs and the decomposition;
  - `selftest` runs on hand-made logs.
- `scripts/h6_server.sh` (guards, run, status; detached) and
  `scripts/h6_all.sh` (go, status, pull).

The run and the reading happen on the server. Pulled: the run's log, the
pairs, the summary, and the event log compressed with xz.

## Build and rehearsal record (2026-11-14, before the run)

- `scripts/h6_lockreq.py`: `pairs`, `qe0`, `classify`, `selftest`. The
  self-test covers:
  - pairs from an xz trace: a release, an acquire without a mutex, and the
    magic at the wrong offset all give no pair; `--max-records` is honoured;
  - a hand event log with every class (R0 2, R1 1, R2 1, R3G 1, R3U 1),
    take-backs listing the waiter with their gaps, a call's stack push on
    another line, and a warm-up line, none of which are read as requests;
  - "no single cause" and the R0 + R1 reading;
  - QI1 (more events than requests) and QI2 (a load carrying a request pair)
    each stop the reading;
  - `qe0`: equal with the times masked, and a real difference caught.
- One defect fixed before the rehearsal: the record's kind and mutex were
  read from the wrong fields (source_memory[2] and [3]). The self-test
  caught it.
- The reading "R0 + R1" was made exact: R0 and R1 together are at least half
  of the requests that add nothing to C. Written before any count exists.
- **Against a stand-in server** (scratchpad `h6reh/`): the real F-C barnes
  std start log as the reference; xz stand-in traces with ACQUIRE records; a
  stand-in binary that writes an event log.
  - The guards pass clean. Six faults are each refused alone: binary md5,
    config md5, an incomplete reference, another window in `cmd.txt`, a
    missing trace, and a reference that ran another trace.
  - With one counter line changed, QE0 FAILS and the event log is not read.
    DONE refuses a second `go`.
  - With QE0 holding: 8 pairs as built, QI1 and QI2 hold, and the classes
    print.
  - One launcher defect fixed: a run that ended within 3 s was reported as
    not started. The start check now reads the driver log.

## Launch record

`bash scripts/h6_all.sh go` (from `364220e`), 2026-11-14 13:34:55 server
time. Uploaded `~/h6/h6_server.sh` (md5 3ad6d0fe) and `~/h6/h6_lockreq.py`
(41be3105). Guards passed: `champsim_fc_a2e88e46` md5 a2e88e46; config md5
3efd5110; the F-C rerun complete; its 4 traces present; the self-test passes
on the server; 81 GB free. Load about 120.

## Amendment 1 (2026-11-14, after QI2 failed, before any class was read)

**What happened.**
- The run ended 14:49:26 server time. QE0 HOLDS (2,127 lines equal with
  the times masked). QI1 HOLDS: identified events per CPU are 4,355 /
  4,549 / 4,320 / 4,405, against 8,162 / 8,393 / 13,842 / 13,849 measured
  requests.
- **QI2 FAILED: 1,033 measured S events carry a request pair.** By the
  rule above the classes were not read, and `summary.txt` stops there.

**QI2's premise was wrong for S.**
- An S is not an access. It is a *stale fill* (`cache.cc:139`): the fill of
  a request already issued, logged at the L2C and / or the L1D when another
  core took the line while the fill was in flight. QI2 was meant to catch a
  normal **load** sharing a pair; an S is a load's only if its access type
  is LOAD.
- Diagnosis (pulled event log; S events only, no class; scratchpad
  `h6_sdiag.py`, `h6_sdiag2.py`):
  - all 1,033 are RFO fills;
  - 737 follow their own request's G (same CPU, `instr_id` and line);
  - the other 296 are L1D fills with no earlier G or U, i.e. requests that
    hit their own L2C with no other core listed (no event, class R0) and
    whose fill to the L1D was overtaken;
  - 316 of the 717 requests with an S logged one at both the L2C and the
    L1D.
- **Disclosed:** the first diagnosis script also printed the identified
  events by kind, G 16,797 and U 832. Their sum, 17,629, is QI1's per-CPU
  total already printed. The G / U split was seen before this amendment.
  It bounds R3U at 832, so "the request's event is an upgrade" cannot lead.

**The amendment.**
- **QI2:** no measured L or W event has a request pair, and every measured
  S with a pair is an RFO fill. An S with a pair and any other access type
  fails QI2, as an L would. The S fills are reported by access type.
- Nothing else changes: the classes, take-backs, decomposition, readings,
  the 0.564 and the run. S events never entered the classes (only G and U
  are identified events).
- The self-test gains the request's own S at the L2C and the L1D (QI2
  holds, the classes unchanged) and an S that is a LOAD's fill (QI2 fails).
  Self-test PASS.
- The classification is rerun on the laptop on the pulled event log
  (5.8 MB), the pulled pairs and the run log, with the amended
  `h6_lockreq.py`.
