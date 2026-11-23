# K2, steps 1 and 2: results (2026-11-17)

Design: `k2_sharing_gap_design_2026-11-17.md` (pre-registered `03f362d`;
amendment 1 and the tool, `fa899cc`). Run once, on the laptop, on H6(b)'s
pulled event files:

```
python3 scripts/k2_episodes.py run    # output: k2_episodes_v1.txt
```

## Checks

- Each program's R on these events equals H6(b)'s (1.018, 0.400, 0.308).
- **Events outside the window** (counted and kept, as the note says):
  - canneal: 90 of 91,376 ChampSim events;
  - fluidanimate: 3 of 18,744;
  - vips and every gem5 file: 0.

  All lie after the last core's finish, by at most 0.13% of the window
  (canneal's latest at cycle 232,060,043 against an end of 231,802,112).
  They are in the run log's count (QC0), so they are not dropped.

## Step 1: episodes (gamma = 0.1% of the window, primary)

| | Ep (stretches) | Per (hand-overs a stretch) | R | share_I | reading | at 0.01% / 1% |
|---|---|---|---|---|---|---|
| **canneal 4c (control)** | 1.017 | 1.001 | 1.018 | -- | **control HOLDS** (both in [0.8, 1.25]) | 1.018 / 1.000; 1.016 / 1.002 |
| **fluidanimate** | 0.949 | **0.421** | 0.400 | **0.943** | **I** | 0.937 I; 0.966 I |
| **vips** | **0.341** | 0.904 | 0.308 | **0.086** | **E** | 0.085 E; 0.089 E |

Neither reading depends on the time scale.

- **fluidanimate (I):** ChampSim shares a line in as many separate stretches
  as gem5 (10,819 against 10,670 episodes; Ep 0.95). Inside a stretch, gem5
  passes the line back and forth far more often: events per episode median
  2 and p90 10 in gem5, against median 1 and p90 2 in ChampSim. Stores alone
  read the same (share 0.987).
- **vips (E):** each stretch has about as many hand-overs in both (Per 0.90;
  median and p90 1 in both). ChampSim has a third as many stretches (1,006
  against 2,860).

**Reported, deciding nothing** (`k2_episodes_v1.txt` has the full bins):

- **fluidanimate's timeline:** in both simulators the events come in two
  bursts, the same phase structure.
  - gem5: 95.6% of events in bins 10 and 46-47 (21,067 + 8,081 + 12,791 of
    43,879).
  - ChampSim: 92.2% in bins 7-10 and 41-44 (9,170 + 8,120 of 18,744).
  - **ChampSim's bursts are spread over 3-4 bins (6-8% of the window);
    gem5's over 1-2 (2-4%).**
- **vips's timeline:** in both simulators the events come in a regular burst
  every third bin, the bursts in step with each other. gem5's bursts hold
  about 200 events each, ChampSim's about 67, so each burst has a third as
  many.
- **Episodes by distinct cores:** almost all involve two cores in both
  (fluidanimate 10,653 of 10,670 in gem5, 10,799 of 10,819 in ChampSim; vips
  2,811 of 2,860 and 993 of 1,006).

## Step 2: vips's drift (reported)

- The cores' spread in ChampSim grows from 6.8 M to about 12 M over the
  window.
- Spearman's rho, events per 2% bin against the spread: **-0.252**. That is
  above the -0.3 the note set, so this does not indicate step 3 for vips.
- With the bursts in step in both simulators, a growing spread does not
  line up with vips's missing stretches.

## Step 3's condition

By the note's rule: **fluidanimate reads I, so step 3 is INDICATED**. vips
does not indicate it (E, but rho -0.252 > -0.3).

The note's step 3 is a diagnostic run that keeps ChampSim's cores within
Delta instructions of each other. Its build, exact tests and rehearsal go in
an amendment first; it runs on the owner's word, and it is never the tool's
setting. The amendment follows.

**vips:** the note's step 3 is not indicated for it. Its reading E (a third as
many stretches, in bursts at the same times) points to which lines each
burst shares, not to the timing inside a burst. The per-core counts H6(b)
reported fit this: cores 1 and 2 have 16 and 85 events in ChampSim against
741 and 686 for the matching gem5 threads. By the note, that question gets a
note of its own.

## What the paper can say (fixed by 1 Dec, by the stop rule)

- **fluidanimate:** both simulators share the same lines in the same phases.
  In ChampSim a shared line changes hands about 2.4x less often inside each
  sharing burst. ChampSim's bursts are longer (3-4 bins of the window against 1-2). It is
  not retention (at most 23%), lock words, untraced threads, or gem5's CPU
  model.
- **vips:** the sharing bursts fall at the same times, but each has a third
  as many shared lines in ChampSim, concentrated on two of the four cores.
  It is not retention, untraced threads, or gem5's CPU model.
