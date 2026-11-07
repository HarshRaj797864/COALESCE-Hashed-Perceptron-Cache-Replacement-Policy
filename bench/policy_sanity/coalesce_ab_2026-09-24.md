# COALESCE A/B on A4 — verdict: close, relaunch both arms

**2026-09-24.** Raw rows: `a4_ab_rows_2026-09-24.txt` (72 rows, both arms),
compared against the pre-fix run in `a4_rows_2026-09-21.txt`. Single core,
50M warmup + 50M simulation, 12 SPEC CPU2006 SimPoints, 2 MB LLC.

- **Arm A** = `4b00ecf`: the ghost-tag fix plus one-factor ablations.
- **Arm B** = the deployed HEAD: arm A plus hit training on the allocating PC
  (`5beb7a8`) and the rescue keyed on the line address (`8de8c42`).

## How the arms were built and checked

One detached pipeline (`scripts/ab_pipeline.sh`, launched 2026-09-24 10:58 UTC),
each step gated on the last: the build from the deployed tree passed all three
guards; both COALESCE probes passed, each with its negative control; the two
binaries were built from one tree differing only in the six COALESCE-family
files, and `ab_build.sh` confirmed `arms differ; bin/champsim == arm B; sources
restored`; both arms completed 36 / 36. The comparison's own checks passed:
full coverage, neither arm identical to the pre-fix run or to the other arm,
every run length within 1% of LRU's.

## Verdict, by the rule committed before any arm ran (`769b535`)

A win needs a ≥ 1.0 pp geomean lead **and** being better on ≥ 7 of the 10
discriminating traces.

| geomean IPC vs LRU | pre-fix | arm A | arm B | B vs A |
|---|---|---|---|---|
| coalesce | +2.23% | +1.59% | +1.72% | +0.13% |
| coalesce_no_mesi | +2.49% | +1.94% | +2.54% | +0.58% |
| coalesce_no_sharer | +2.73% | +1.85% | +1.64% | −0.21% |
| *(srrip)* | +2.74% | | | |
| *(hawkeye)* | +9.60% | | | |
| *(mockingjay)* | +11.29% | | | |

`coalesce`: arm A better on 5 traces, arm B on 4, one tie. **Close — both arms
go to the multi-core relaunch.**

## Observed, not yet claimed

Single core: `sharer_mask` is always one core, so the sharer feature is inert
and MODIFIED means only "dirty". Nothing here speaks to the multi-core case.

- **After the fix, COALESCE's single-core gain is lower than before**: +1.59% /
  +1.72% against +2.23% pre-fix, and about 1 pp behind SRRIP (+2.74%). The
  pre-fix figure was inflated by rescues that fired on lines never evicted.
- **Removing the MESI feature still helps on single core**, in both arms
  (arm A +1.94% vs +1.59%; arm B +2.54% vs +1.72%). A4's earlier finding — the
  `+40` MODIFIED bias acting as a dirty-line preference that costs — survives
  the fix in direction. The sharer ablation is mixed across arms.
- **Per-trace swings are large** between versions: 450.soplex reads +8.47%
  pre-fix, +3.12% in arm A, +7.81% in arm B. Single-trace comparisons between
  COALESCE versions should not be quoted.
