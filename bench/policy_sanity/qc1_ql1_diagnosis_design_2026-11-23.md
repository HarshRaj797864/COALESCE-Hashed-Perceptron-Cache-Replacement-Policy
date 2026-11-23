# C's QC1 and E's QL1 failures: diagnosis design (2026-11-23)

Written before any file behind the two failures was pulled or read. The only
numbers seen so far are the verdict lines from the 23 Nov status read:

| Check | Case | Seen | Needed |
|---|---|---|---|
| QC1a, ChampSim, test-line count | readers | 5 | 4 |
| QC1a | priv_S | 3 | 4 |
| QC1b, gem5 MT.L1_GETS r8 − r4 | llc_out | 24 | 0 ± 1 |
| QC1b | offchip | 24 | 0 ± 1 |
| QL1, Δ G Two_Level against Three_Level | ctl | 4 against 2 | within 1 |

- QC1b's lines also showed EE.Fwd_GETS / MM.Fwd_GETS.
- The ctl hand count is 4.

Designs: `load_side_design_2026-11-18.md` (C) and
`second_protocol_design_2026-11-18.md` (E).
- **Per both designs, nothing of C or E is scored.** This note only finds
  the cause.
- **A cause found here does not turn a failure into a pass.** A changed
  check needs its own amendment and the owner's word, and is disclosed as
  written after the failure.

## Inputs (read-only pulls, no server change)

- `bash scripts/ld_all.sh pull`:
  - `qc1a.txt`, `qc1b.txt`;
  - the ChampSim micro event logs (`micro_cs/*.log`, `*.xline`);
  - the MESI_Three_Level micro statistics (`g5micro/gem5/*/stats.txt`).
- `bash scripts/e2_all.sh pull`:
  - `ql1.txt`;
  - the MESI_Two_Level micro statistics (`g5micro/`).

## Hypotheses and their tests, fixed now

### H1 (QC1b, llc_out and offchip): per-round inclusion victims of shared read-only lines

- **The claim:**
  - Only these two cases sweep beyond the shared L2: 384 KB and 512 KB
    through 256 KB.
  - gem5's L2 is inclusive. Evicting a line back-invalidates every private
    copy of it, so lines that all four threads read evict together. These
    are the code of `worker`, `chase` and `reads`, and the read-only
    globals: `ring[]`, `sweepbuf[]`, `X`, `CASE`, `ROUNDS`.
  - The first core to re-read such a line is granted E, so the next core's
    GETS counts MT.L1_GETS.
  - This background repeats every round, so r8 − r4 does not cancel it.
    QC1b's design assumed it was constant.
  - ChampSim's LLC is non-inclusive, so its private copies stay and no such
    event happens there. QC1a judged only the test lines in any case.
- **Predictions (from the statistics alone):**
  - P1a: in llc_out and offchip, r8 − r4 of the private caches' instruction
    fetch misses is well above the same difference in ctl and priv_E. That
    is the L0's Ifetch on a non-present line, or its equivalent in
    `stats.txt`.
  - P1b: EE.Fwd_GETS covers most of the 24, and MM.Fwd_GETS at most a few.
    Code and read-only data are clean.
  - P1c: every other case's QC1b Δ is within 1 of its hand count.
- **Verdicts:**
  - P1a and P1b hold: **H1 SUPPORTED**. QC1b's background assumption fails
    on the sweeping cases, and gem5 shows no fault.
  - Otherwise: not supported, and the cause stays open.
- **Address proof is not done here.** A ProtocolTrace rerun of
  llc_out r4 / r8, classified by address, would show it. That is a server
  run, on the owner's word.

### H2 (QC1a readers 5): one step overtaken in ChampSim's timed form

- **The claim:** in one round, D's store reached the LLC before C's load.
  C's load then found D exclusive: one event more than the hand count.
- **Test:** the kept event log, test lines only. For each round's X line,
  list the L / S events in order, with core, cycle and flag.
- **Verdicts:**
  - Supported if exactly one round has two flagged loads and its order is D
    before C.
  - Any other pattern is reported as seen.

### H3 (QC1a priv_S 3): in one round, C's load did not find A listed exclusive

- **The claim:** one of three things happened in that round:
  - (a) C's load reached the LLC before A's fill listed A;
  - (b) A was already forgotten, its private caches having dropped the
    line before C's load;
  - (c) C's load came first, so A's load finds C. That still counts 1, so
    it cannot explain a 3. It is listed for completeness.
- **Test:** the same per-round listing. The round with no flagged load
  shows which: A's and C's cycles, and any eviction line between them.
- **Verdict:** the sub-case seen, as seen.

### H4 (QL1 ctl): the difference is background, not ctl's round events

- **The claim:**
  - ctl's events per round are one (B's store finds A's E copy).
  - The r4 and r8 runs differ in timing, so their non-test background (the
    start, the end marks, thread 0's statistics dump, the tail chase) need
    not be equal. A difference of 2 in background then appears in Δ G.
- **Test (statistics only):**
  - for both protocols, ctl's G and U at r4 and r8, beside pp_store's and
    readers';
  - the earlier MESI_Three_Level micro runs (2026-10-18, the
    pre-Q16 source) where they hold ctl at both lengths.
- **Readings:**
  - The Three_Level Δ is not 4 on another case that should be exact: the
    background varies, and QL1's "within 1" is too tight for this micro.
    That is reported, nothing changes.
  - Only ctl is off, by 2 on Three_Level alone: H4 is not supported, and
    the per-round cause needs ProtocolTrace (server).
- **Which side is wrong:** Two_Level reading the hand count (4) does not by
  itself make Three_Level wrong. Both are reported.

## After the diagnosis

- A results note gives each hypothesis's verdict.
- What would change a check, if anything, is proposed to the owner as an
  amendment written after the failure:
  - QC1b on the test lines' addresses (ProtocolTrace);
  - QL1 on a background-free count.
- No C or E ratio is read before then.
