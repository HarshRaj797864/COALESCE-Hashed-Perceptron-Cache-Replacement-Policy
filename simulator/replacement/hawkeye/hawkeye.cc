// Hawkeye cache replacement policy — implementation.
// See hawkeye.h for the high-level description and citation.

#include "hawkeye.h"

#include <algorithm>
#include <cassert>
#include <cstddef>

#include "champsim.h"

// ===========================================================================
// OPTgen
// ===========================================================================
//
// OPTgen approximates Belady's MIN over a sliding window. For each sampled
// set we maintain an occupancy ring buffer indexed by a monotonically
// increasing per-sampled-set quanta. Each entry is the number of currently
// "live" lines whose lifetime spans that quanta.
//
// When an address is re-referenced with previous timestamp `prev_quanta`, we
// check whether the cache could have kept the line resident over the whole
// interval [prev_quanta, current_quanta) — that is, whether every entry in
// that interval is strictly below cache_capacity. If yes, the line is
// "cache-friendly" and we (a) train the predictor toward FRIENDLY and (b)
// mark the interval by incrementing every entry by 1 (we are reserving a way
// for this line's lifetime). Otherwise the line is "cache-averse" and we
// only train the predictor.

void hawkeye::OPTgen::init(unsigned ways)
{
  cache_capacity = ways;
  occupancy.assign(static_cast<std::size_t>(ways) * OPTGEN_VECTOR_FACTOR, 0u);
  current_quanta = 0;
}

bool hawkeye::OPTgen::would_cache(uint64_t prev_quanta) const
{
  // If the gap is larger than the ring-buffer length we have no information;
  // be conservative and call it cache-averse.
  const uint64_t window = occupancy.size();
  if (current_quanta - prev_quanta >= window)
    return false;

  for (uint64_t t = prev_quanta; t < current_quanta; ++t) {
    if (occupancy[t % window] >= cache_capacity)
      return false;
  }
  return true;
}

void hawkeye::OPTgen::add_access(uint64_t prev_quanta)
{
  const uint64_t window = occupancy.size();
  if (current_quanta - prev_quanta >= window)
    return;
  for (uint64_t t = prev_quanta; t < current_quanta; ++t) {
    if (occupancy[t % window] < std::numeric_limits<unsigned>::max())
      occupancy[t % window]++;
  }
}

void hawkeye::OPTgen::advance()
{
  current_quanta++;
  // clear the slot we are about to overwrite as the new "tail"
  occupancy[current_quanta % occupancy.size()] = 0;
}

// ===========================================================================
// hawkeye
// ===========================================================================

hawkeye::hawkeye(CACHE* cache)
    : replacement(cache), NUM_SET(cache->NUM_SET), NUM_WAY(cache->NUM_WAY),
      rrpv(static_cast<std::size_t>(cache->NUM_SET * cache->NUM_WAY), MAX_RRPV)
{
  // Per-CPU predictor tables (3-bit saturating counters, default-initialized to 0).
  predictor.resize(NUM_CPUS);

  // Pick SAMPLED_SETS evenly-spaced sets across the cache (deterministic so that
  // results are reproducible; the original CRC2 implementation also uses a
  // deterministic stride).
  is_sampled.assign(static_cast<std::size_t>(NUM_SET), false);
  set_to_optgen_idx.assign(static_cast<std::size_t>(NUM_SET), 0);

  const std::size_t actual_sampled = std::min<std::size_t>(SAMPLED_SETS, static_cast<std::size_t>(NUM_SET));
  optgens.resize(actual_sampled);
  sampler.assign(actual_sampled, std::vector<SamplerEntry>(SAMPLER_WAYS));

  const long stride = std::max<long>(1, NUM_SET / static_cast<long>(actual_sampled));
  std::size_t sidx = 0;
  for (long s = 0; s < NUM_SET && sidx < actual_sampled; s += stride) {
    is_sampled[static_cast<std::size_t>(s)] = true;
    set_to_optgen_idx[static_cast<std::size_t>(s)] = sidx;
    optgens[sidx].init(static_cast<unsigned>(NUM_WAY));
    ++sidx;
  }
}

std::size_t hawkeye::hash_pc(champsim::address ip)
{
  // XOR-fold the lower 32 bits down to the predictor table size.
  using namespace champsim::data::data_literals;
  auto v = ip.slice_lower<32_b>().to<std::size_t>();
  v ^= (v >> 13);
  v ^= (v >> 7);
  return v % PREDICTOR_ENTRIES;
}

void hawkeye::age_set(long set)
{
  const std::size_t base = static_cast<std::size_t>(set * NUM_WAY);
  for (long w = 0; w < NUM_WAY; ++w) {
    if (rrpv[base + static_cast<std::size_t>(w)] < MAX_RRPV - 1)
      rrpv[base + static_cast<std::size_t>(w)]++;
  }
}

long hawkeye::find_victim(uint32_t /*triggering_cpu*/, uint64_t /*instr_id*/,
                          long set, const champsim::cache_block* /*current_set*/,
                          champsim::address /*ip*/, champsim::address /*full_addr*/,
                          access_type /*type*/)
{
  const std::size_t base = static_cast<std::size_t>(set * NUM_WAY);
  // Pick the way with the largest RRPV. If no line is at MAX_RRPV we still
  // pick the max — Hawkeye does NOT age on miss, it ages on cache-friendly
  // re-references (see update_replacement_state).
  long victim = 0;
  unsigned max_seen = rrpv[base];
  for (long w = 1; w < NUM_WAY; ++w) {
    unsigned r = rrpv[base + static_cast<std::size_t>(w)];
    if (r > max_seen) {
      max_seen = r;
      victim = w;
    }
  }
  return victim;
}

void hawkeye::update_replacement_state(uint32_t triggering_cpu, long set, long way,
                                       champsim::address full_addr, champsim::address ip,
                                       champsim::address /*victim_addr*/,
                                       access_type type, uint8_t hit)
{
  // Hawkeye does NOT learn from writeback fills (consistent with the CRC2
  // reference) — they are a side effect of evictions in the upper level.
  if (type == access_type::WRITE && !hit) {
    rrpv[static_cast<std::size_t>(set * NUM_WAY + way)] = MAX_RRPV - 1;
    return;
  }

  const std::size_t pc_idx = hash_pc(ip);

  // ---------- OPTgen + sampler update (only sampled sets) -----------------
  if (is_sampled[static_cast<std::size_t>(set)]) {
    const std::size_t s_idx = set_to_optgen_idx[static_cast<std::size_t>(set)];
    auto& og = optgens[s_idx];
    auto& sset = sampler[s_idx];

    // Block-aligned address tag.
    using namespace champsim::data::data_literals;
    auto addr_tag = full_addr.slice_upper(6_b).to<uint64_t>();

    // Look for this address in the sampler.
    auto match = std::find_if(sset.begin(), sset.end(), [&](const SamplerEntry& e) {
      return e.valid && e.addr_tag == addr_tag;
    });

    if (match != sset.end()) {
      // Re-reference. Ask OPTgen if Belady would have kept it.
      bool friendly = og.would_cache(match->last_quanta);
      if (friendly) {
        og.add_access(match->last_quanta);
        // Train predictor for the PC that brought this in to "more friendly".
        // Decrement counter (low counter = friendly).
        if (predictor[match->cpu][match->pc_sig] > 0)
          predictor[match->cpu][match->pc_sig]--;
      } else {
        // Train toward "more averse" — saturate up.
        predictor[match->cpu][match->pc_sig]++;
      }

      match->last_quanta = og.current_quanta;
      match->pc_sig = pc_idx;
      match->cpu = triggering_cpu;
      match->last_used = access_counter++;
    } else {
      // New address in this sampled set. Evict the LRU sampler slot.
      auto victim = std::min_element(sset.begin(), sset.end(),
                                     [](const SamplerEntry& a, const SamplerEntry& b) {
                                       if (!a.valid) return true;
                                       if (!b.valid) return false;
                                       return a.last_used < b.last_used;
                                     });
      victim->valid = true;
      victim->addr_tag = addr_tag;
      victim->pc_sig = pc_idx;
      victim->cpu = triggering_cpu;
      victim->last_quanta = og.current_quanta;
      victim->last_used = access_counter++;
    }

    og.advance();
  }

  // ---------- RRPV update --------------------------------------------------
  const std::size_t rrpv_idx = static_cast<std::size_t>(set * NUM_WAY + way);
  const bool averse = predictor[triggering_cpu][pc_idx] >= PREDICTOR_THRESHOLD;

  if (hit) {
    // On hit, set RRPV based on current prediction for the *accessing* PC.
    if (averse) {
      rrpv[rrpv_idx] = MAX_RRPV;
    } else {
      rrpv[rrpv_idx] = 0;
      // After promoting to 0 we age the rest of the set so that the new line
      // is preferred but old cache-friendly lines fall behind eventually.
      age_set(set);
      rrpv[rrpv_idx] = 0; // restore: age_set leaves friendly lines at higher RRPV.
    }
  } else {
    // Miss / fill. Insert at 0 (friendly) or MAX_RRPV (averse).
    if (averse) {
      rrpv[rrpv_idx] = MAX_RRPV;
    } else {
      rrpv[rrpv_idx] = 0;
      age_set(set);
      rrpv[rrpv_idx] = 0;
    }
  }
}
