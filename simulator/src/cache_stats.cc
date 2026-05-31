#include "cache_stats.h"

cache_stats operator-(cache_stats lhs, cache_stats rhs)
{
  cache_stats result;
  result.pf_requested = lhs.pf_requested - rhs.pf_requested;
  result.pf_issued = lhs.pf_issued - rhs.pf_issued;
  result.pf_useful = lhs.pf_useful - rhs.pf_useful;
  result.pf_useless = lhs.pf_useless - rhs.pf_useless;
  result.pf_fill = lhs.pf_fill - rhs.pf_fill;

  result.hits = lhs.hits - rhs.hits;
  result.misses = lhs.misses - rhs.misses;

  result.coherence_invalidations = lhs.coherence_invalidations - rhs.coherence_invalidations;
  result.coherence_write_hit_other_sharer_events = lhs.coherence_write_hit_other_sharer_events - rhs.coherence_write_hit_other_sharer_events;
  for (int i = 0; i < 17; i++)
    result.coherence_sharer_hist[i] = lhs.coherence_sharer_hist[i] - rhs.coherence_sharer_hist[i];

  result.total_miss_latency_cycles = lhs.total_miss_latency_cycles - rhs.total_miss_latency_cycles;
  return result;
}
