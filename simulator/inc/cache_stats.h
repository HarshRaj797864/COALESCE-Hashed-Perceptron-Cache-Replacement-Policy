#ifndef CACHE_STATS_H
#define CACHE_STATS_H

#include <cstdint>
#include <string>
#include <type_traits>
#include <utility>

#include "channel.h"
#include "event_counter.h"

struct cache_stats {
  std::string name;
  // prefetch stats
  uint64_t pf_requested = 0;
  uint64_t pf_issued = 0;
  uint64_t pf_useful = 0;
  uint64_t pf_useless = 0;
  uint64_t pf_fill = 0;

  champsim::stats::event_counter<std::pair<access_type, std::remove_cv_t<decltype(NUM_CPUS)>>> hits = {};
  champsim::stats::event_counter<std::pair<access_type, std::remove_cv_t<decltype(NUM_CPUS)>>> misses = {};
  champsim::stats::event_counter<std::pair<access_type, std::remove_cv_t<decltype(NUM_CPUS)>>> mshr_merge = {};
  champsim::stats::event_counter<std::pair<access_type, std::remove_cv_t<decltype(NUM_CPUS)>>> mshr_return = {};

  // COALESCE A.2: synthetic invalidation counter (2026-05-21).
  // Counts bits cleared from sharer_mask on write hits to multi-sharer lines.
  // This is LLC-bookkeeping only — does not model real interconnect/L1/L2 invalidation
  // traffic (ChampSim has no inter-level coherence). See COHERENCE_HOOK_AUDIT.md.
  uint64_t coherence_invalidations = 0;

  // COALESCE 2026-05-31: count of *events* (not bits) where a write hit found
  // other_sharers != 0. Distinct from coherence_invalidations: that counts bits
  // cleared (popcount), this counts the number of times the clearing happened.
  // Useful for distinguishing "rare multi-sharer events with many bits each"
  // from "frequent two-sharer events" in the histogram analysis.
  uint64_t coherence_write_hit_other_sharer_events = 0;

  // COALESCE 2026-05-29 sharer-count histogram. Index = popcount(sharer_mask)
  // observed in find_victim's per-way scan. Settles whether cross-core sharing
  // actually exists in the workload — see docs SESSION_CONTEXT.md sec 16.
  uint64_t coherence_sharer_hist[17] = {0};

  long total_miss_latency_cycles{};
};

cache_stats operator-(cache_stats lhs, cache_stats rhs);

#endif
