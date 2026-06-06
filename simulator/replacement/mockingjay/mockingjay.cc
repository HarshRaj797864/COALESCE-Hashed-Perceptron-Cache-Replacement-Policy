// Mockingjay cache replacement policy — implementation.
// See mockingjay.h for the high-level description and citation.

#include "mockingjay.h"

#include <algorithm>
#include <cassert>
#include <cstdint>

#include "champsim.h"

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

std::size_t mockingjay::hash_pc(champsim::address ip)
{
  using namespace champsim::data::data_literals;
  auto v = ip.slice_lower<32_b>().to<std::size_t>();
  // Two-stage XOR-fold; same trick used in Hawkeye for orthogonal hash quality.
  v ^= (v >> 13);
  v ^= (v >> 7);
  return v % RDP_ENTRIES;
}

int mockingjay::clamp_etr(int x)
{
  if (x > ETR_MAX) return ETR_MAX;
  if (x < ETR_MIN) return ETR_MIN;
  return x;
}

int mockingjay::clamp_rdp(int x)
{
  if (x >  MAX_DISTANCE) return  MAX_DISTANCE;
  if (x < -MAX_DISTANCE) return -MAX_DISTANCE;
  return x;
}

// ---------------------------------------------------------------------------
// constructor
// ---------------------------------------------------------------------------

mockingjay::mockingjay(CACHE* cache)
    : replacement(cache), NUM_SET(cache->NUM_SET), NUM_WAY(cache->NUM_WAY),
      etr(static_cast<std::size_t>(cache->NUM_SET * cache->NUM_WAY), ETR_INSERT_DEFAULT),
      etr_valid(static_cast<std::size_t>(cache->NUM_SET * cache->NUM_WAY), false)
{
  // Per-CPU RDP. Initialise entries to MAX_DISTANCE so that "unknown PC" is
  // treated as "very far reuse" (i.e., good victim) until we learn otherwise.
  // This matches the published Mockingjay's reluctance to over-commit cache
  // capacity to cold PCs.
  rdp.assign(NUM_CPUS, std::vector<int>(RDP_ENTRIES, MAX_DISTANCE));

  // Pick sampled sets evenly across the cache.
  is_sampled.assign(static_cast<std::size_t>(NUM_SET), false);
  set_to_sc_idx.assign(static_cast<std::size_t>(NUM_SET), 0);

  const std::size_t actual_sampled = std::min<std::size_t>(SAMPLED_SETS, static_cast<std::size_t>(NUM_SET));
  sc.assign(actual_sampled, std::vector<SamplerEntry>(SC_WAYS));

  const long stride = std::max<long>(1, NUM_SET / static_cast<long>(actual_sampled));
  std::size_t sidx = 0;
  for (long s = 0; s < NUM_SET && sidx < actual_sampled; s += stride) {
    is_sampled[static_cast<std::size_t>(s)] = true;
    set_to_sc_idx[static_cast<std::size_t>(s)] = sidx;
    ++sidx;
  }
}

bool mockingjay::maybe_advance_quanta()
{
  if (++access_counter_for_quanta >= QUANTA_GRANULARITY) {
    access_counter_for_quanta = 0;
    ++global_quanta;
    return true;
  }
  return false;
}

void mockingjay::decay_set(long set)
{
  const std::size_t base = static_cast<std::size_t>(set * NUM_WAY);
  for (long w = 0; w < NUM_WAY; ++w) {
    const std::size_t idx = base + static_cast<std::size_t>(w);
    if (etr_valid[idx])
      etr[idx] = clamp_etr(etr[idx] - 1);
  }
}

// ---------------------------------------------------------------------------
// find_victim
// ---------------------------------------------------------------------------

long mockingjay::find_victim(uint32_t /*triggering_cpu*/, uint64_t /*instr_id*/,
                             long set, const champsim::cache_block* current_set,
                             champsim::address /*ip*/, champsim::address /*full_addr*/,
                             access_type /*type*/)
{
  const std::size_t base = static_cast<std::size_t>(set * NUM_WAY);

  // 1) Prefer any invalid line.
  for (long w = 0; w < NUM_WAY; ++w) {
    if (!current_set[w].valid) return w;
  }

  // 2) Otherwise pick the line with the largest Etr. Tie-break: lower way
  //    index. A high Etr = predicted distant reuse = best victim.
  long victim = 0;
  int max_etr_seen = etr[base];
  for (long w = 1; w < NUM_WAY; ++w) {
    int e = etr[base + static_cast<std::size_t>(w)];
    if (e > max_etr_seen) {
      max_etr_seen = e;
      victim = w;
    }
  }
  return victim;
}

// ---------------------------------------------------------------------------
// update_replacement_state
// ---------------------------------------------------------------------------

void mockingjay::update_replacement_state(uint32_t triggering_cpu, long set, long way,
                                          champsim::address full_addr, champsim::address ip,
                                          champsim::address /*victim_addr*/,
                                          access_type type, uint8_t hit)
{
  // Writeback fills: do not train, but do reset the per-line Etr so the
  // freshly-filled (dirty) line has a sensible prediction. Mirrors the
  // reference implementation's behavior.
  if (type == access_type::WRITE && !hit) {
    const std::size_t idx = static_cast<std::size_t>(set * NUM_WAY + way);
    etr[idx] = ETR_INSERT_DEFAULT;
    etr_valid[idx] = true;
    return;
  }

  // Advance the LLC quanta clock and decay this set's Etr counters.
  // Decay happens on every access (not only on quanta tick) — this is the
  // simpler "per-access decay" variant. Effect on rank order is identical
  // since every line in the set decays by the same amount.
  maybe_advance_quanta();
  decay_set(set);

  const std::size_t pc_idx = hash_pc(ip);

  // ---------- Sampled Cache update / training ----------------------------
  if (is_sampled[static_cast<std::size_t>(set)]) {
    const std::size_t s_idx = set_to_sc_idx[static_cast<std::size_t>(set)];
    auto& sset = sc[s_idx];

    using namespace champsim::data::data_literals;
    auto addr_tag = full_addr.slice_upper(6_b).to<uint64_t>();

    auto match = std::find_if(sset.begin(), sset.end(), [&](const SamplerEntry& e) {
      return e.valid && e.addr_tag == addr_tag;
    });

    if (match != sset.end()) {
      // Re-reference observed. Compute distance and train the RDP for the
      // PC that originally brought this line in.
      const int64_t raw_distance = static_cast<int64_t>(global_quanta) - static_cast<int64_t>(match->last_quanta);
      const int distance = clamp_rdp(static_cast<int>(raw_distance));

      // Move the RDP entry one step toward the observed distance.
      // (Saturating-counter style update: +1 if observed > stored, -1 otherwise.)
      int& slot = rdp[match->cpu][match->pc_idx];
      if (distance > slot)      slot = clamp_rdp(slot + 1);
      else if (distance < slot) slot = clamp_rdp(slot - 1);

      match->last_quanta = global_quanta;
      match->pc_idx      = pc_idx;
      match->cpu         = triggering_cpu;
      match->last_used   = ++sc_lru_counter;
    } else {
      // New address. Evict the LRU SC slot and install.
      auto victim = std::min_element(sset.begin(), sset.end(),
                                     [](const SamplerEntry& a, const SamplerEntry& b) {
                                       if (!a.valid) return true;
                                       if (!b.valid) return false;
                                       return a.last_used < b.last_used;
                                     });
      victim->valid       = true;
      victim->addr_tag    = addr_tag;
      victim->pc_idx      = pc_idx;
      victim->cpu         = triggering_cpu;
      victim->last_quanta = global_quanta;
      victim->last_used   = ++sc_lru_counter;
    }
  }

  // ---------- Per-line Etr update ----------------------------------------
  const std::size_t line_idx = static_cast<std::size_t>(set * NUM_WAY + way);
  // Predict next reuse distance for this PC.
  int predicted = rdp[triggering_cpu][pc_idx];
  // RDP holds signed distances; if the predictor has never been trained for
  // this PC it stays at MAX_DISTANCE (cold). Use that prediction directly.
  etr[line_idx] = clamp_etr(predicted);
  etr_valid[line_idx] = true;
}
