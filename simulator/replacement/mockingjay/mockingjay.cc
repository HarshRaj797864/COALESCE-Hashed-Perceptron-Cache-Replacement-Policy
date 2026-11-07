// Mockingjay — implementation.  See mockingjay.h for provenance and for the
// list of defects this rewrite corrects.
//
// Line references below are to the authors' artifact `mockingjay.llc_repl`.

#include "mockingjay.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>

#include "champsim.h"

namespace
{
int ilog2(long x)
{
  int r = 0;
  while (x > 1) {
    x >>= 1;
    ++r;
  }
  return r;
}

// Artifact lines 49-56, verbatim.
uint64_t CRC_HASH(uint64_t _blockAddress)
{
  static const unsigned long long crcPolynomial = 3988292384ULL;
  unsigned long long _returnVal = _blockAddress;
  for (unsigned int i = 0; i < 3; i++)
    _returnVal = ((_returnVal & 1) == 1) ? ((_returnVal >> 1) ^ crcPolynomial) : (_returnVal >> 1);
  return _returnVal;
}

} // namespace

champsim::modules::replacement::register_module<mockingjay> mockingjay_register("mockingjay");

mockingjay::mockingjay(champsim::modules::ModuleBuilder builder)
    : NUM_SET(static_cast<long>(builder.get_parent<champsim::modules::cache_module>()->num_sets())),
      NUM_WAY(static_cast<long>(builder.get_parent<champsim::modules::cache_module>()->num_ways()))
{
  LOG2_BLOCK = static_cast<int>(LOG2_BLOCK_SIZE);
  LOG2_LLC_SET = ilog2(NUM_SET);
  LOG2_LLC_SIZE = LOG2_LLC_SET + ilog2(NUM_WAY) + LOG2_BLOCK;
  LOG2_SAMPLED_SETS = LOG2_LLC_SIZE - 16;
  SAMPLED_CACHE_TAG_BITS = 31 - LOG2_LLC_SIZE;
  PC_SIGNATURE_BITS = LOG2_LLC_SIZE - 10;

  INF_RD = static_cast<int>(NUM_WAY) * HISTORY - 1;
  INF_ETR = (static_cast<int>(NUM_WAY) * HISTORY / GRANULARITY) - 1;
  MAX_RD = INF_RD - 22;
  FLEXMIN_PENALTY = 2.0 - std::log2(static_cast<double>(NUM_CPUS)) / 4.0;

  etr.assign(static_cast<std::size_t>(NUM_SET * NUM_WAY), 0);
  etr_clock.assign(static_cast<std::size_t>(NUM_SET), GRANULARITY);
  current_timestamp.assign(static_cast<std::size_t>(NUM_SET), 0);

  // Artifact lines 132-142.
  for (long set = 0; set < NUM_SET; set++) {
    if (is_sampled_set(set)) {
      const int modifier = 1 << LOG2_LLC_SET;
      const int limit = 1 << LOG2_SAMPLED_CACHE_SETS;
      for (int i = 0; i < limit; i++)
        sampled_cache[static_cast<uint32_t>(set + modifier * i)] = std::vector<SampledCacheLine>(SAMPLED_CACHE_WAYS);
    }
  }
}

// Artifact lines 43-47.
bool mockingjay::is_sampled_set(long set) const
{
  const int mask_length = LOG2_LLC_SET - LOG2_SAMPLED_SETS;
  const int mask = (1 << mask_length) - 1;
  return (set & mask) == ((set >> (LOG2_LLC_SET - mask_length)) & mask);
}

// Artifact lines 58-80.
uint64_t mockingjay::get_pc_signature(uint64_t pc, bool hit, bool prefetch, uint32_t core) const
{
  if (NUM_CPUS == 1) {
    pc = pc << 1;
    if (hit)
      pc = pc | 1;
    pc = pc << 1;
    if (prefetch)
      pc = pc | 1;
    pc = CRC_HASH(pc);
    pc = (pc << (64 - PC_SIGNATURE_BITS)) >> (64 - PC_SIGNATURE_BITS);
  } else {
    pc = pc << 1;
    if (prefetch)
      pc = pc | 1;
    pc = pc << 2;
    pc = pc | core;
    pc = CRC_HASH(pc);
    pc = (pc << (64 - PC_SIGNATURE_BITS)) >> (64 - PC_SIGNATURE_BITS);
  }
  return pc;
}

// Artifact lines 82-93.
uint32_t mockingjay::get_sampled_cache_index(uint64_t full_addr) const
{
  full_addr = full_addr >> LOG2_BLOCK;
  full_addr = (full_addr << (64 - (LOG2_SAMPLED_CACHE_SETS + LOG2_LLC_SET))) >> (64 - (LOG2_SAMPLED_CACHE_SETS + LOG2_LLC_SET));
  return static_cast<uint32_t>(full_addr);
}

uint64_t mockingjay::get_sampled_cache_tag(uint64_t x) const
{
  x >>= LOG2_LLC_SET + LOG2_BLOCK + LOG2_SAMPLED_CACHE_SETS;
  x = (x << (64 - SAMPLED_CACHE_TAG_BITS)) >> (64 - SAMPLED_CACHE_TAG_BITS);
  return x;
}

// Artifact lines 96-104.
int mockingjay::search_sampled_cache(uint64_t block_address, uint32_t set)
{
  auto it = sampled_cache.find(set);
  if (it == sampled_cache.end())
    return -1;
  auto& sampled_set = it->second;
  for (int way = 0; way < SAMPLED_CACHE_WAYS; way++) {
    if (sampled_set.at(static_cast<std::size_t>(way)).valid && (sampled_set.at(static_cast<std::size_t>(way)).tag == block_address))
      return way;
  }
  return -1;
}

// Artifact lines 106-118.
void mockingjay::detrain(uint32_t set, int way)
{
  if (way < 0)
    return;
  auto it = sampled_cache.find(set);
  if (it == sampled_cache.end())
    return;
  SampledCacheLine& temp = it->second.at(static_cast<std::size_t>(way));
  if (!temp.valid)
    return;

  if (rdp.count(temp.signature))
    rdp[temp.signature] = std::min(rdp[temp.signature] + 1, INF_RD);
  else
    rdp[temp.signature] = INF_RD;
  temp.valid = false;
}

// Artifact lines 175-188.  NOTE the int truncation: the step is +/-1 only once
// |sample - init| >= 16, and 0 inside that dead zone.  Reproduced exactly.
int mockingjay::temporal_difference(int init, int sample) const
{
  if (sample > init) {
    int diff = sample - init;
    diff = static_cast<int>(diff * TEMP_DIFFERENCE);
    diff = std::min(1, diff);
    return std::min(init + diff, INF_RD);
  } else if (sample < init) {
    int diff = init - sample;
    diff = static_cast<int>(diff * TEMP_DIFFERENCE);
    diff = std::min(1, diff);
    return std::max(init - diff, 0);
  }
  return init;
}

int mockingjay::increment_timestamp(int input) const
{
  input++;
  input = input % (1 << TIMESTAMP_BITS);
  return input;
}

int mockingjay::time_elapsed(int global, int local) const
{
  if (global >= local)
    return global - local;
  global = global + (1 << TIMESTAMP_BITS);
  return global - local;
}

// ---------------------------------------------------------------------------
// find_victim  — artifact lines 147-172
// ---------------------------------------------------------------------------
long mockingjay::find_victim(uint32_t triggering_cpu, uint64_t /*instr_id*/, long set, const champsim::cache_block* current_set, champsim::address ip,
                             champsim::address /*full_addr*/, access_type type)
{
  for (long way = 0; way < NUM_WAY; way++) {
    if (!current_set[way].valid)
      return way;
  }

  const std::size_t base = static_cast<std::size_t>(set * NUM_WAY);

  // Evict the line with the largest |Etr|; on a tie prefer the negative one
  // (its predicted reuse has already passed, so it is the safer victim).
  // THIS abs() IS THE HEART OF THE POLICY — dropping it inverts it into MRU.
  int max_etr = 0;
  long victim_way = 0;
  for (long way = 0; way < NUM_WAY; way++) {
    const int e = etr.at(base + static_cast<std::size_t>(way));
    if (std::abs(e) > max_etr || (std::abs(e) == max_etr && e < 0)) {
      max_etr = std::abs(e);
      victim_way = way;
    }
  }

  // Bypass: decline to allocate when this PC's predicted reuse distance is
  // beyond what the cache can hold, or is further out than every resident line.
  // Guarded on type because ChampSim asserts that writes may not bypass
  // (src/cache.cc:187).
  const uint64_t pc_signature = get_pc_signature(ip.to<uint64_t>(), false, type == access_type::PREFETCH, triggering_cpu);
  if (type != access_type::WRITE && rdp.count(pc_signature) && (rdp[pc_signature] > MAX_RD || rdp[pc_signature] / GRANULARITY > max_etr)) {
    stat_bypasses++;
    return NUM_WAY;
  }

  stat_victims++;

  // Which kind of line are we evicting? A negative Etr means the predicted
  // reuse already came and went, so the line is probably dead -- that should
  // dominate. A positive Etr means OPT says its next use is far enough away to
  // be the best candidate anyway. Both are healthy; a run with almost no
  // negative victims would mean the Etr counters are not ageing.
  const int victim_etr = etr.at(base + static_cast<std::size_t>(victim_way));
  if (victim_etr > 0)
    stat_victim_etr_pos++;
  else if (victim_etr < 0)
    stat_victim_etr_neg++;
  else
    stat_victim_etr_zero++;

  return victim_way;
}

// ---------------------------------------------------------------------------
// handle_access — the artifact's llc_update_replacement_state body (lines 208-305)
//
// Called on every hit (from try_hit) and every fill (forwarded from
// impl_replacement_cache_fill, inc/cache.h:515).  This matches the artifact's
// single llc_update_replacement_state hook.
// ---------------------------------------------------------------------------
void mockingjay::replacement_cache_fill(uint32_t triggering_cpu, long set, long way, champsim::address full_addr, champsim::address ip,
                                        champsim::address /*victim_addr*/, access_type type)
{
  stat_fills++;
  handle_access(triggering_cpu, set, way, full_addr, ip, type, false);
}

void mockingjay::update_replacement_state(uint32_t triggering_cpu, long set, long way, champsim::address full_addr, champsim::address ip,
                                          champsim::address /*victim_addr*/, access_type type, bool hit)
{
  // Misses reach us through replacement_cache_fill instead; here `way` is
  // past-the-end and must not be used to index. Mirrors upstream lru.
  if (!hit)
    return;
  stat_hits++;
  handle_access(triggering_cpu, set, way, full_addr, ip, type, true);
}

void mockingjay::handle_access(uint32_t triggering_cpu, long set, long way, champsim::address full_addr, champsim::address ip, access_type type, bool hit)
{
  // access_type::WRITE is a writeback from the level above.
  if (type == access_type::WRITE) {
    if (!hit && way < NUM_WAY) {
      // -INF_ETR: maximal |Etr| with the negative tie-break, i.e. the next
      // victim.  A writeback has no reuse prediction to offer.
      etr.at(static_cast<std::size_t>(set * NUM_WAY + way)) = -INF_ETR;
    }
    return;
  }

  const uint64_t pc = get_pc_signature(ip.to<uint64_t>(), hit, type == access_type::PREFETCH, triggering_cpu);

  if (is_sampled_set(set)) {
    const uint32_t sc_index = get_sampled_cache_index(full_addr.to<uint64_t>());
    const uint64_t sc_tag = get_sampled_cache_tag(full_addr.to<uint64_t>());
    const int sc_way = search_sampled_cache(sc_tag, sc_index);

    auto sc_it = sampled_cache.find(sc_index);
    if (sc_it != sampled_cache.end()) {
      auto& sc_set = sc_it->second;

      // Re-reference observed: train the RDP for the PC that last brought it in.
      if (sc_way > -1) {
        const uint64_t last_signature = sc_set.at(static_cast<std::size_t>(sc_way)).signature;
        const int last_timestamp = sc_set.at(static_cast<std::size_t>(sc_way)).timestamp;
        int sample = time_elapsed(current_timestamp.at(static_cast<std::size_t>(set)), last_timestamp);

        if (sample <= INF_RD) {
          if (type == access_type::PREFETCH)
            sample = static_cast<int>(sample * FLEXMIN_PENALTY);
          if (rdp.count(last_signature))
            rdp[last_signature] = temporal_difference(rdp[last_signature], sample);
          else
            rdp[last_signature] = sample;
          sc_set.at(static_cast<std::size_t>(sc_way)).valid = false;
        }
      }

      // Make room in the sampled set, detraining whatever we displace.
      int lru_way = -1;
      int lru_rd = -1;
      for (int w = 0; w < SAMPLED_CACHE_WAYS; w++) {
        if (!sc_set.at(static_cast<std::size_t>(w)).valid) {
          lru_way = w;
          lru_rd = INF_RD + 1;
          continue;
        }
        const int last_timestamp = sc_set.at(static_cast<std::size_t>(w)).timestamp;
        const int sample = time_elapsed(current_timestamp.at(static_cast<std::size_t>(set)), last_timestamp);
        if (sample > INF_RD) {
          lru_way = w;
          lru_rd = INF_RD + 1;
          detrain(sc_index, w);
        } else if (sample > lru_rd) {
          lru_way = w;
          lru_rd = sample;
        }
      }
      detrain(sc_index, lru_way);

      for (int w = 0; w < SAMPLED_CACHE_WAYS; w++) {
        if (!sc_set.at(static_cast<std::size_t>(w)).valid) {
          sc_set.at(static_cast<std::size_t>(w)).valid = true;
          sc_set.at(static_cast<std::size_t>(w)).signature = pc;
          sc_set.at(static_cast<std::size_t>(w)).tag = sc_tag;
          sc_set.at(static_cast<std::size_t>(w)).timestamp = current_timestamp.at(static_cast<std::size_t>(set));
          break;
        }
      }

      current_timestamp.at(static_cast<std::size_t>(set)) = increment_timestamp(current_timestamp.at(static_cast<std::size_t>(set)));
    }
  }

  // Age the set once every GRANULARITY accesses — NOT once per access — and
  // skip the line being touched, which is about to get a fresh prediction.
  const std::size_t base = static_cast<std::size_t>(set * NUM_WAY);
  if (etr_clock.at(static_cast<std::size_t>(set)) == GRANULARITY) {
    for (long w = 0; w < NUM_WAY; w++) {
      if (w != way && std::abs(etr.at(base + static_cast<std::size_t>(w))) < INF_ETR)
        etr.at(base + static_cast<std::size_t>(w))--;
    }
    etr_clock.at(static_cast<std::size_t>(set)) = 0;
  }
  etr_clock.at(static_cast<std::size_t>(set))++;

  // way == NUM_WAY when the fill was bypassed; there is no line to update.
  if (way < NUM_WAY) {
    if (!rdp.count(pc)) {
      // Unknown PC: single-core assumes imminent reuse (Etr 0, protected),
      // multi-core assumes the worst (Etr INF_ETR, immediately evictable).
      etr.at(base + static_cast<std::size_t>(way)) = (NUM_CPUS == 1) ? 0 : INF_ETR;
    } else if (rdp[pc] > MAX_RD) {
      etr.at(base + static_cast<std::size_t>(way)) = INF_ETR;
    } else {
      etr.at(base + static_cast<std::size_t>(way)) = rdp[pc] / GRANULARITY;
    }
  }
}

void mockingjay::replacement_final_stats()
{
  // Two of these are genuine health checks. `fills` at zero means the
  // insertion hook is not wired up and the policy is learning nothing;
  // `rdp_entries` at zero means the predictor never trained. Either is a bug.
  fmt::print("\nMockingjay: victims {} bypasses {} rdp_entries {}\n", stat_victims, stat_bypasses, rdp.size());
  fmt::print("Mockingjay: fills {} hits {}\n", stat_fills, stat_hits);

  // A "victim was the most-recently-touched way" counter used to be printed
  // here with the claim that it should sit near 1/NUM_WAY. Both the claim and
  // the measurement were wrong, and it cost a false alarm. The rate is
  // meaningless once the policy bypasses: on a bypassed fill no line is
  // installed, so the recorded way goes stale and ends up naming whichever
  // line has aged longest -- which is exactly the line that SHOULD be evicted.
  // On 429.mcf, bypasses outnumbered victims, and the counter read ~50-62%
  // while the policy was behaving correctly.
  //
  // The real regression test for the eviction-rule inversion is
  // bench/policy_sanity/mockingjay_etr_probe.cc, which is deterministic and
  // shows the broken rule scoring 100% in EVERY RDP state, trained included.
  // That invariance to prediction, not any rate measured in-simulator, is the
  // signal that distinguishes the inverted rule from the correct one.
  if (stat_victims > 0) {
    fmt::print("Mockingjay: victim Etr  overdue(negative) {:.2f}%  distant-reuse(positive) {:.2f}%  zero {:.2f}%\n",
               100.0 * static_cast<double>(stat_victim_etr_neg) / static_cast<double>(stat_victims),
               100.0 * static_cast<double>(stat_victim_etr_pos) / static_cast<double>(stat_victims),
               100.0 * static_cast<double>(stat_victim_etr_zero) / static_cast<double>(stat_victims));
  }
}
