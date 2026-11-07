# The 2 MB LLC was suppressing the effect being measured

**2026-09-19.** LRU, canneal, 5M warmup + 10M simulation per core. Two identical
passes differing only in LLC geometry:

- **fixed** — 2048 sets x 16 ways x 64 B = **2 MB at every core count**. This is
  what `make_config.py` and all four original configs use, and what every
  published number in this project was measured with.
- **scaled** — 2 MB per core: **8 / 16 / 32 MB** at 4 / 8 / 16 cores, which is
  the order of magnitude real parts carry.

## LLC hit rate

| cores | regime | fixed 2 MB | scaled | |
|---|---|---|---|---|
| 4 | private | 12.21% | **50.79%** | |
| 8 | private | 0.93% | **50.77%** | |
| 16 | private | 0.24% | **50.56%** | |
| 4 | shared | 33.76% | **74.88%** | +24.09 pp over private |
| 8 | shared | 21.26% | **84.74%** | +33.97 pp |
| 16 | shared | 21.44% | **91.18%** | +40.62 pp |

**The private-regime collapse was entirely cache sizing.** At 2 MB, private hit
rate falls 12.21% -> 0.93% -> 0.24% as cores scale. Given a cache that scales
with the core count it is **flat at ~50.7%**. Nothing about the private regime
degrades with core count; a 2 MB cache simply cannot hold four, then eight, then
sixteen independent working sets.

**The regime effect survives, and grows.** The shared-over-private gap widens
with core count -- +24, +34, +41 percentage points -- where at 2 MB it was
non-monotone and confounded.

## Coherence traffic

| cores | fixed 2 MB | scaled | |
|---|---|---|---|
| 4 | 25.80 | **73.93** | 7.4% of LLC accesses |
| 8 | 26.26 | **133.44** | 13.3% |
| 16 | 29.46 | **189.97** | **19.0%** |

*(invalidations per thousand LLC accesses)*

Roughly **6.5x more coherence traffic at 16 cores** with a realistic cache. The
mechanism is straightforward: at 2 MB a line is evicted long before another core
can invalidate it, so invalidations cannot happen. Enlarging the cache lets
lines live long enough to be invalidated, which is what coherence traffic *is*.

## Internal consistency check

Aliased fills per thousand LLC accesses are essentially identical across the two
configurations -- 61.23 / 76.01 / 85.25 fixed against 61.18 / 76.13 / 85.26
scaled. Aliasing is a VMEM-level event and should not depend on cache geometry,
and it does not. The overlay behaved identically; only the cache changed.

## What this means

**Every policy result in this project was measured with the coherence signal
suppressed.** COALESCE's -2.4% 8-core geomean, the ablations, the bias sweep,
and the claim that Hawkeye and Mockingjay "fail under sharing" were all taken at
2 MB, where coherence events are 2.6-3.0% of LLC accesses. At a realistic size
they are 7-19%.

That does not mean a coherence-aware policy will now win. It means the previous
evaluation could not have detected it either way, and -2.4% is not evidence
about the idea -- it is evidence about the configuration.

It also sharpens the criticism of the 16-core results specifically. At a 0.24%
hit rate no replacement policy can matter, because nothing survives long enough
to be reused. Any 16-core policy comparison at 2 MB was measuring noise around a
floor.

## Caveats

Short-length runs (10M simulation per core); magnitudes are directional and the
full-length sweep supersedes them. LRU only, canneal only. And a higher
invalidation rate establishes that there is signal to act on -- not that any
policy successfully acts on it.

2 MB per core is a defensible choice, not the only one. What matters is that the
LLC scale with the core count at all; holding it fixed while varying cores
confounds the variable under study.
