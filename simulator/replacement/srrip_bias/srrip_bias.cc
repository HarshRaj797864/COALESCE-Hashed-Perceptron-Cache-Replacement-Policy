#include "srrip_bias.h"

#include <algorithm>
#include <cassert>

champsim::modules::replacement::register_module<srrip_bias> srrip_bias_register("srrip_bias");

srrip_bias::srrip_bias(champsim::modules::ModuleBuilder builder)
    : srrip_bias(static_cast<long>(builder.get_parent<champsim::modules::cache_module>()->num_sets()),
                 static_cast<long>(builder.get_parent<champsim::modules::cache_module>()->num_ways()))
{
}

srrip_bias::srrip_bias(long sets, long ways) : NUM_SET(sets), NUM_WAY(ways), rrpv_values(static_cast<std::size_t>(sets * ways), maxRRPV) {}

auto srrip_bias::get_rrpv(long set, long way) -> rrpv_type& { return rrpv_values.at(static_cast<std::size_t>(set * NUM_WAY + way)); }

long srrip_bias::find_victim(uint32_t triggering_cpu, uint64_t instr_id, long set, const champsim::cache_block* current_set, champsim::address ip,
                             champsim::address full_addr, access_type type)
{
  const std::size_t base = static_cast<std::size_t>(set * NUM_WAY);

  // SRRIP ageing: if no line is at maxRRPV, shift the whole set up.
  auto begin = std::next(std::begin(rrpv_values), static_cast<long>(base));
  auto end = std::next(begin, NUM_WAY);
  if (auto shift = maxRRPV - *std::max_element(begin, end); shift != 0)
    std::transform(begin, end, begin, [shift](auto x) { return x + shift; });

  // Rank by effective RRPV = RRPV - coherence bias, clamped at 0. Highest wins.
  // Unlike a veto, a coherence-expensive line is still evictable once its RRPV
  // has aged past everything else in the set.
  long victim = 0;
  rrpv_type best = -1;
  for (long w = 0; w < NUM_WAY; w++) {
    rrpv_type eff = rrpv_values.at(base + static_cast<std::size_t>(w));

    if (current_set[w].state == MODIFIED)
      eff -= BIAS_MODIFIED;
    if (__builtin_popcount(current_set[w].sharer_mask) >= SHARED_THRESHOLD)
      eff -= BIAS_SHARED;

    if (eff < 0)
      eff = 0;

    if (eff > best) {
      best = eff;
      victim = w;
    }
  }
  return victim;
}

void srrip_bias::update_replacement_state(uint32_t triggering_cpu, long set, long way, champsim::address full_addr, champsim::address ip,
                                          champsim::address victim_addr, access_type type, bool hit)
{
  // Misses are handled by replacement_cache_fill; here `way` is past-the-end.
  if (!hit)
    return;
  get_rrpv(set, way) = 0;
}
