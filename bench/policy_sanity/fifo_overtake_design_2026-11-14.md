# H1b: how many messages overtake in each scored gem5 run. Pre-registered 2026-11-14, before anything is built or run

PLAN § 10 item 9, H1's follow-up. `fifo_check_design_2026-11-14.md` fixed
it in advance: "If any configuration panics, a records-only counter of
overtakes (a stat in `MessageBuffer::enqueue`, built in a separate gem5
tree; its own Q0: every other statistic identical) is pre-registered next,
to say how many overtakes per million messages each run had."

**The trigger, seen 2026-11-14 (`fifo_all.sh status`):** H1's run 06,
barnes std, PANIC at tick 323,384,552,500 in `system.ruby.l0_cntrl0.
bufferFromL1` (delta 500, arrival ...553,000, last ...553,500), in the
window (the short stop ends at 104,456,444,500). Runs 01 and 02 (ocean
2 MB and 8 MB) are COMPLETE-IDENTICAL; the rest are running or pending.
No other H1 result has been read.

## The counter (records only)

- **Where:** gem5 v25.1.0.1, `src/mem/ruby/network/MessageBuffer.cc`,
  `MessageBuffer::enqueue`, after the arrival time is computed and before
  the strict-FIFO check.
- **What:** each message whose arrival time is earlier than the previous
  message enqueued in the same buffer is logged, under the check's own
  condition (`!(bypassStrictFIFO || m_last_message_strict_fifo_bypassed)
  && arrival_time < m_last_arrival_time`), whether or not the buffer is
  ordered. The log line holds the tick, the buffer's name, delta, arrival,
  last arrival and the buffer's `ordered` flag.
- **How:** a file named by the environment variable
  `COALESCE_OVERTAKE_LOG`, opened (empty) at the first enqueue of the run.
  An empty file means no overtake. A missing file means the variable did
  not reach gem5, and the run is void.
- **Nothing else changes:** no statistic, no timing and no message.
  `MessageBuffer.hh` is not touched.
- **Build:** a copy of `~/gem5` (`cp -a`, 6.6 GB of build, no symlinks in
  it) at `~/gem5_ovt`; the one file patched; `scons build/X86/gem5.opt`,
  nice 19. The live `~/gem5` and its binary are not touched.

## The runs

- **What:** the 13 scored configurations of H1's table, each **exactly as
  scored**: the patched (unordered) L0 buffers, the live `~/gem5/configs`,
  the same mode, settings and working directory. Only the binary differs
  (`~/gem5_ovt/build/X86/gem5.opt`, through a copy of
  `run_gem5_splash.sh` that gains `GEM5_BIN`), plus the environment
  variable.
- **Where:** `~/gem5_b3/ovt/<n>_<name>/`.
- **When:** the runs start only after H1's driver has ended, so that the
  two do not load the server together. 4 at a time, nice 19, 96 h limit.

## Checks, in order

- **QO-S, before any run:** the micro program (`~/micro/micro_m5`,
  `pp_store`, 4 rounds, H6(b)'s QP settings) under the old binary and the
  new one. The two `stats.txt` must be equal line for line (host lines
  aside), and the new binary's log file must exist. If QO-S fails, no run
  starts.
- **QO0, each run:** its `config.ini` equals its original's apart from
  output paths. If not, the run is void and launching stops.
- **QO1, each run's outcome:**
  - **COMPLETE-IDENTICAL:** it reaches its stop with `stats.txt` equal to
    the original's line for line (host lines aside). Only then are its
    counts read.
  - **COMPLETE-DIFFERENT:** the counter changed the simulation. Launching
    stops, and nothing is read until that is diagnosed.
  - **OTHER:** a limit, a panic or a missing log: reported, not read.
- **QO2, exact, for every configuration that panicked in H1:** the
  counter's first overtake in an L0 `bufferToL1` / `bufferFromL1` equals
  H1's panic line (tick, buffer, delta, arrival, last arrival). gem5 is
  deterministic and the two runs are identical up to that point, so any
  difference voids that configuration's counts.

## What is reported (no prediction; nothing is scored)

For each configuration that passes QO1 (and QO2 where it applies):
- overtakes in the L0 buffers, in the whole run and in the window (after
  the short stop's `finalTick`), by buffer;
- the window's overtakes per million messages through those buffers (the
  sum of `m_msg_count` over `l0_cntrl*.bufferToL1` and `bufferFromL1`,
  150 M stop minus 50 M stop);
- overtakes in any other buffer (expected 0: those buffers are ordered,
  and the scored runs never panicked);
- the smallest and largest overtake margins (last arrival minus arrival).

The paper states, for each configuration: COMPLETE-IDENTICAL in H1 (the
patch did nothing), or PANIC in H1 with this run's count of overtakes per
million messages in the window. Nothing is tuned and no B3 ratio changes.

## Tools

- `scripts/ovt_check.py`: `qs` (QO-S), `qo0`, `qo1`, `qo2`, `report`,
  `selftest`.
- `scripts/ovt_server.sh` (server): `guards`, `list`, `chain` (copy, patch,
  build, QO-S, wait for H1, the 13 runs; detached), `status`,
  `stop [runs]`.
- `scripts/ovt_all.sh` (laptop): `go`, `status`, `pull`.

Rehearsed against a stand-in server (a stand-in scons and gem5) before
launch.

## Build record (2026-11-14, before anything ran on the server)

- **The patch on the real source.** The server's `~/gem5/src/mem/ruby/
  network/MessageBuffer.cc` (585 lines, read with `cat`) was patched on the
  laptop by `ovt_server.sh`'s own `patch_src`. Both anchors are found once,
  and the change is 23 added lines and 0 removed.
- **The counter's logic.** In `enqueue`, `m_last_arrival_time` is set from
  every message outside cache-trace warm-up, ordered buffer or not. So the
  check's condition works unchanged on the unordered L0 buffers. With
  randomization off, `arrival_time = current_time + delta` in both builds.
- **Compile check.** The inserted block, in a stand-in class with the same
  members, compiles under gem5's warning flags with `-Werror`
  (`-Wall -Wundef -Wextra`). It logs exactly one line for a hand case:
  an overtake, then a later message, then a bypassed one. Without the
  variable it writes nothing.
- **Rehearsed against a stand-in server** (scratchpad `ovtreh`):
  - the real `ovt_server.sh`, `ovt_check.py` and `run_gem5_splash.sh`
    (with `GEM5_BIN`);
  - a stand-in scons that builds only if the patch is in;
  - a stand-in gem5 for each binary, live and counter;
  - H1 RESULT files, 03's a PANIC line.

  Results, on four configurations (01, 03, 06, 08):
  - copy, patch (+23 / -0), build, BUILT;
  - QO-S holds;
  - each run: QO0 holds, then QO1 COMPLETE-IDENTICAL;
  - 03: QO2 HOLDS (the first L0 overtake is H1's panic line exactly); 3 L0
    overtakes, 3 in the window (FromL1 2, ToL1 1), 0.402 per million;
  - 06: "other buffers 1", as injected; the others 0.
- **Faults, each caught:**

  | fault | outcome |
  |---|---|
  | the counter changes one statistic | COMPLETE-DIFFERENT, "launching stops"; the rest NOT RUN; the run's counts NOT READ |
  | the micro's statistics differ | "QO-S FAILED: no run starts" |
  | one run's `config.ini` differs | QO0 FAILS; that run VOID and its gem5 ended; launching stops |
  | the variable does not reach gem5 | VOID, "no counter log after N s"; launching stops |
  | the build fails | "STOPPED at the build"; then the guard refuses a relaunch ("exists without BUILT") |
  | H1's driver alive | "WAITING for H1's driver", then the runs once it ends |

- **Two changes from the rehearsal:**
  - a VOID now says which check failed;
  - the wait for the counter log is a setting, `LOG_WAIT_S`, default 1800 s
    (it was 300). The log opens at the first enqueue, and gem5's start-up
    under the server's load (~120) can be slow. A run that is working does
    not wait.
- **The limit path** (a run past 96 h is ended and read as OTHER) is
  `fifo_server.sh`'s, unchanged. It was not rehearsed here.
- **Server state read before launch** (read-only):
  - `~/gem5` binary of 2026-09-24, 6.7 GB tree;
  - 79 GB free on /home;
  - load 118-124;
  - H1's driver alive (pid 2310686), so H1b's runs wait for it;
  - `~/gem5_ovt` and `~/gem5_ovt_w` absent.

## Launch record

- **2026-11-14 17:53:59 server time:** `bash scripts/ovt_all.sh go` from
  `04ecb8c`, on the owner's word ("ok do all of them").
- **Guards:** all 23 pass, among them the 13 originals with their short
  stops, scons, the micro and the self-test. 78 GB free.
- **Driver:** pid 3023389, log `~/gem5_ovt_w/driver.log`. It copies, patches
  and builds, runs QO-S, then waits for H1's driver (pid 2310686: 2 runs
  identical, 06 PANIC, 03/04/05/07 running, 08-13 pending).
- **Next:** `bash scripts/ovt_all.sh status`, then `pull` when the chain
  ends.

## Amendment 1 (2026-11-14 19:10 server time, before any run has started; no run's count exists)

Read from the server's driver log and the QO-S micro's own log:

- **The build recompiled 1,004 objects and linked 3** (`scons rc=0`,
  17:55-18:52). The note expected only the patched file, but the copy's new
  path makes scons rebuild more. The sources are the live tree plus the
  23-line patch (QO-S's diff check). Whether a recompile in another path
  changes the simulation is exactly what QO-S and each run's QO1 test.
  **QO-S HOLDS on the server:** 5,379 statistics lines equal (host lines
  aside). Binary md5 `b41cbe44...`.
- **"Other buffers: expected 0" was wrong as written.** The QO-S micro's log
  holds 12 overtakes, all in `system.ruby.l2_cntrl0.responseFromL2Cache`
  with the ordered flag 0. That buffer is unordered in MESI_Three_Level, and
  an overtake there is legal Ruby behaviour, not a near-panic. (An overtake
  in an ordered buffer would panic, and the run would read OTHER.)
- **Change, reporting only:** `ovt_check.py report` now prints other
  buffers split by the flag (`other buffers N (unordered U, ordered O)`);
  self-test PASS with a hand case of both kinds. Nothing is checked on it,
  and QO-S, QO0, QO1 and QO2 are unchanged.
  - The server's copy (`04ecb8c`) still writes the old line in its
    REPORT files.
  - The report of record is recomputed on the laptop from the pulled
    `overtakes.txt` with this version. The server is not touched.
