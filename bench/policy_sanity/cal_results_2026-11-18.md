# H2, the band's noise floor: results (2026-11-18)

- **Design:** `calibration_design_2026-11-14.md` (pre-registered `3156ae9`;
  built and rehearsed `c64fedd`), launched 2026-11-14 10:42 server time.
- **Pull:** 2026-11-18 (`scripts/cal_all.sh pull`), into `simulator/results/cal/`.
- **Rows:** `cal_gem5_rows_v1.txt` (32).
- **Score output:** `cal_score_v1.txt` (`cal_score.py score`; self-test
  passes).
- **The verdicts stand as scored.** These labels say how firm each one is.

## Checks

- **QV0, 32 of 32:** each perturbed gem5 run's config differs from the
  scored run's only in `static_backend_latency`, at the declared value.
- **QV1, 32 of 32:** every run exits "because a thread reached the max
  instruction count", and every one ended at its stop.
- **Re-traces, 20 of 20:** traced, each by its program's own procedure.
- **Replays, 20 of 20:** complete, with 0 unexplained view-order
  violations. Every replay qualifies, so each program has 6 trace sets
  (the reference and r1-r5).
- **The scorer's parser** reproduces the committed rows on 14 of 14 scored
  logs.

## The four programs

C_k is ChampSim's events per KI (6 trace sets); G_j is gem5's (5
latencies, 8-12 ns).

| program | R (scored) | the 30 R_kj | in the band | s_c | s_g | s_p | own interval | label |
|---|---|---|---|---|---|---|---|---|
| ocean 2 MB | 0.712 | 0.635-0.754 | 30 of 30 | 0.0395 | 0.0221 | 0.0453 | 0.661-0.767 | ROBUSTLY IN |
| canneal 4c 2 MB | 1.018 | 1.013-1.030 | 30 of 30 | 0.0046 | 0.0012 | 0.0047 | 1.010-1.026 | ROBUSTLY IN |
| lunc | 1.830 | 1.615-2.051 | 25 of 30 | 0.0510 | 0.0434 | 0.0670 | 1.639-2.044 | NEAR THE EDGE |
| fluidanimate | 0.400 | 0.396-0.419 | 0 of 30 | 0.0205 | 0.0018 | 0.0206 | 0.386-0.414 | ROBUSTLY OUT |

- **s\* = 0.0670** (lunc's s_p), below 0.4214. So the band is wider than
  the measured noise, and labels can be given.
- **Trace-to-trace (s_c) is the larger source on every program.** gem5's
  latency (s_g) matters mainly for lunc (gem5 0.0859-0.0952 per KI) and
  ocean.
- **Reported, deciding nothing:** no perturbed window equals the scored
  one exactly (ocean's events 27,443-29,016 against 27,649).

## Labels (ln R ± 1.645 s\*, against [0.5, 2])

| span | R_g5 | interval | label |
|---|---|---|---|
| canneal 4c 2 MB | 1.018 | 0.911-1.136 | ROBUSTLY IN |
| canneal 8c | 1.534 | 1.374-1.713 | ROBUSTLY IN |
| ocean 2 MB | 0.712 | 0.638-0.795 | ROBUSTLY IN |
| radix | 0.988 | 0.885-1.103 | ROBUSTLY IN |
| barnes std force | 0.635 | 0.568-0.709 | ROBUSTLY IN |
| barnes std window | 0.954 | 0.854-1.065 | ROBUSTLY IN |
| barnes-256 | 0.780 | 0.698-0.870 | ROBUSTLY IN |
| ocean non-contiguous (apart) | 0.701 | 0.628-0.783 | ROBUSTLY IN |
| lunc | 1.830 | 1.639-2.044 | NEAR THE EDGE |
| barnes std start | 0.449 | 0.402-0.502 | NEAR THE EDGE |
| fluidanimate | 0.400 | 0.358-0.446 | ROBUSTLY OUT |
| vips | 0.308 | 0.276-0.344 | ROBUSTLY OUT |
| bodytrack (not scored: QW) | 0.352 | 0.316-0.394 | ROBUSTLY OUT |
| fmm (not scored: same stream) | 0.725 | 0.650-0.810 | ROBUSTLY IN |

The design's worked table predicted exactly these labels for this s\*:

- lunc needed s\* below 0.0540 to be robustly in;
- barnes std start needed s\* below 0.0654 to be robustly out.

## For the paper

- **The band is not moved.** Measured noise (s\* 0.067, about ±11% at 90%)
  is small against it.
- Eight scored spans are robustly in and three are robustly out.
- **lunc and barnes std start sit near an edge.** Each is now stated with
  its interval.
- lunc is already stated as sensitive to gem5's L2 policy (H4).
- Part B's ratios, once scored, take labels by the same formula
  (`cal_score.py score ... label=R`).
