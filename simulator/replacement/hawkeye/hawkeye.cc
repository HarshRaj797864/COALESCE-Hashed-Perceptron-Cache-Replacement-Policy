// Hawkeye -- implementation. See hawkeye.h for provenance, the list of defects
// this rewrite corrects, and the deliberate adaptations to this simulator.
//
// Function names below mirror the CRC2 artifact so the two can be read side by
// side: GetVictimInSet -> find_victim, UpdateReplacementState -> handle_access.

#include "hawkeye.h"

#include <algorithm>
#include <cassert>

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

// helper_function.h, verbatim. Note this is a 32-round CRC; Mockingjay's
// artifact uses a 3-round variant of the same polynomial. They are not
// interchangeable.
uint64_t CRC(uint64_t address)
{
  unsigned long long crcPolynomial = 3988292384ULL; // 0xEDB88320
  unsigned long long result = address;
  for (unsigned int i = 0; i < 32; i++) {
    if ((result & 1) == 1)
      result = (result >> 1) ^ crcPolynomial;
    else
      result >>= 1;
  }
  return result;
}

uint64_t bitmask(int l) { return (l == 64) ? ~0ULL : ((1ULL << l) - 1ULL); }
uint64_t bits(uint64_t x, int i, int l) { return (x >> i) & bitmask(l); }

constexpr int LOG2_BLOCK = 6;
} // namespace

// ---------------------------------------------------------------------------
// Hawkeye predictor -- hawkeye_predictor.h
// ---------------------------------------------------------------------------

bool hawkeye::Predictor::get_prediction(uint64_t pc) const
{
  // The artifact returns cache-friendly when the entry is absent, and absent
  // entries initialise to (MAX_PCMAP+1)/2, which is itself cache-friendly. A
  // vector pre-filled with that value is therefore exactly equivalent.
  return counters.at(CRC(pc) % PCMAP_SIZE) >= ((MAX_PCMAP + 1) / 2);
}

void hawkeye::Predictor::increase(uint64_t pc)
{
  int& c = counters.at(CRC(pc) % PCMAP_SIZE);
  if (c < MAX_PCMAP)
    c++;
  else
    c = MAX_PCMAP;
}

void hawkeye::Predictor::decrease(uint64_t pc)
{
  int& c = counters.at(CRC(pc) % PCMAP_SIZE);
  if (c != 0)
    c--;
}

// ---------------------------------------------------------------------------
// OPTgen -- optgen.h
// ---------------------------------------------------------------------------

bool hawkeye::OPTgen::is_cache(uint64_t val, uint64_t endVal)
{
  bool cache = true;
  uint64_t count = endVal;
  while (count != val) {
    if (liveness_intervals.at(count) >= cache_size) {
      cache = false;
      break;
    }
    count = (count + 1) % liveness_intervals.size();
  }

  if (cache) {
    count = endVal;
    while (count != val) {
      liveness_intervals.at(count)++;
      count = (count + 1) % liveness_intervals.size();
    }
    num_cache++;
  }
  return cache;
}

// ---------------------------------------------------------------------------
// construction -- InitReplacementState
// ---------------------------------------------------------------------------

champsim::modules::replacement::register_module<hawkeye> hawkeye_register("hawkeye");

hawkeye::hawkeye(champsim::modules::ModuleBuilder builder)
    : NUM_SET(static_cast<long>(builder.get_parent<champsim::modules::cache_module>()->num_sets())),
      NUM_WAY(static_cast<long>(builder.get_parent<champsim::modules::cache_module>()->num_ways()))
{
  LOG2_LLC_SET = ilog2(NUM_SET);

  rrip.assign(static_cast<std::size_t>(NUM_SET * NUM_WAY), MAXRRIP);
  sample_signature.assign(static_cast<std::size_t>(NUM_SET * NUM_WAY), 0);
  prefetching_line.assign(static_cast<std::size_t>(NUM_SET * NUM_WAY), 0);
  set_timer.assign(static_cast<std::size_t>(NUM_SET), 0);

  // Disclosed constant: capacity is NUM_WAY - 2, per the artifact.
  optgen_occup_vector.resize(static_cast<std::size_t>(NUM_SET));
  for (auto& og : optgen_occup_vector)
    og.init(static_cast<uint64_t>(NUM_WAY) - 2);

  cache_history_sampler.clear();
  cache_history_sampler.resize(SAMPLER_SETS);

  // A single predictor pair shared across all cores, per CRC2 paper section
  // 4.1: "Hawkeye uses a single occupancy vector and a single predictor to
  // reconstruct and learn OPT's solution for the interleaved access stream."
  predictor_demand.init();
  predictor_prefetch.init();
}

// Sampled sets, selected by the artifact's bit-match rather than a stride.
//
// NOT "64 sampled sets", as this comment and the artifact's own ("sample 64
// sets for each core") both used to say. The two 6-bit fields compared are
// bits [0,6) and [log2(sets)-6, log2(sets)). At 2048 sets the second starts at
// bit 5, so they OVERLAP at bit 5 and the formula admits only 32 sets. With no
// overlap it admits sets/64. Counted exactly, with the artifact's formula:
//
//     2048 sets ->  32     8192 ->  128     16384 -> 256     32768 -> 512
//
// This reproduces the artifact's BEHAVIOUR faithfully -- the reference itself
// samples 32 sets at its own 2048-set default (hawkeye_algorithm.cc:43, commit
// f960a5d355f0) -- so it is deliberately left unchanged. What it does mean:
// Hawkeye's training rate differs 16x between our 2 MB-fixed and 16c-scaled
// geometries, and at 2 MB fixed the same 32 sets serve every core count.
// See bench/policy_sanity/hawkeye_verification_2026-09-23.md.
bool hawkeye::is_sampled_set(long set) const
{
  const uint64_t s = static_cast<uint64_t>(set);
  // The artifact hardcodes a 2048-set LLC, so its `log2(LLC_SETS) - 6` is
  // always positive. Guard it: a cache with fewer than 64 sets would shift by
  // a negative amount, which is undefined behaviour. Clamping to 0 makes every
  // set sampled, which is the sensible degenerate case for a cache that small.
  const int shift = std::max(0, LOG2_LLC_SET - 6);
  return bits(s, 0, 6) == bits(s, shift, 6);
}

void hawkeye::update_cache_history(std::size_t sample_set, uint32_t currentVal)
{
  for (auto& e : cache_history_sampler.at(sample_set)) {
    if (e.second.lru < currentVal)
      e.second.lru++;
  }
}

// ---------------------------------------------------------------------------
// find_victim -- GetVictimInSet
// ---------------------------------------------------------------------------

long hawkeye::find_victim(uint32_t /*triggering_cpu*/, uint64_t /*instr_id*/, long set, const champsim::cache_block* /*current_set*/, champsim::address /*ip*/,
                          champsim::address /*full_addr*/, access_type /*type*/)
{
  const std::size_t base = static_cast<std::size_t>(set * NUM_WAY);

  // Any cache-averse line (RRIP == MAXRRIP) is the preferred victim.
  for (long way = 0; way < NUM_WAY; way++) {
    if (rrip.at(base + static_cast<std::size_t>(way)) == MAXRRIP)
      return way;
  }

  // Otherwise evict the oldest cache-friendly line. Note `>=`, which takes the
  // LAST maximum; the artifact does the same and it is not interchangeable
  // with `>`.
  unsigned max_rrpv = 0;
  long victim = 0;
  for (long way = 0; way < NUM_WAY; way++) {
    if (rrip.at(base + static_cast<std::size_t>(way)) >= max_rrpv) {
      max_rrpv = rrip.at(base + static_cast<std::size_t>(way));
      victim = way;
    }
  }

  // Detrain the load instruction that brought in the evicted line. CRC2 paper
  // section 2.3 -- this is part of the algorithm, not an implementation
  // detail, and the previous implementation omitted it entirely.
  if (is_sampled_set(set)) {
    const std::size_t idx = base + static_cast<std::size_t>(victim);
    if (prefetching_line.at(idx))
      predictor_prefetch.decrease(sample_signature.at(idx));
    else
      predictor_demand.decrease(sample_signature.at(idx));
    stat_detrains++;
  }

  return victim;
}

// ---------------------------------------------------------------------------
// hooks
// ---------------------------------------------------------------------------

void hawkeye::replacement_cache_fill(uint32_t triggering_cpu, long set, long way, champsim::address full_addr, champsim::address ip,
                                     champsim::address /*victim_addr*/, access_type type)
{
  stat_fills++;
  handle_access(triggering_cpu, set, way, full_addr, ip, type, false);
}

void hawkeye::update_replacement_state(uint32_t triggering_cpu, long set, long way, champsim::address full_addr, champsim::address ip,
                                       champsim::address /*victim_addr*/, access_type type, bool hit)
{
  // Misses reach us through replacement_cache_fill instead; here `way` is
  // past-the-end and must not be used to index. Mirrors upstream lru.
  if (!hit)
    return;
  stat_hits++;
  handle_access(triggering_cpu, set, way, full_addr, ip, type, true);
}

// ---------------------------------------------------------------------------
// handle_access -- UpdateReplacementState
// ---------------------------------------------------------------------------

void hawkeye::handle_access(uint32_t /*triggering_cpu*/, long set, long way, champsim::address full_addr, champsim::address ip, access_type type, bool hit)
{
  // access_type::WRITE is ChampSim's writeback, the artifact's WRITEBACK:
  // ignored outright, RRIP left untouched.
  if (type == access_type::WRITE)
    return;

  const uint64_t paddr = (full_addr.to<uint64_t>() >> LOG2_BLOCK) << LOG2_BLOCK;
  const uint64_t PC = ip.to<uint64_t>();
  const std::size_t base = static_cast<std::size_t>(set * NUM_WAY);
  const std::size_t line = base + static_cast<std::size_t>(way);

  if (type == access_type::PREFETCH) {
    if (!hit)
      prefetching_line.at(line) = 1;
  } else {
    prefetching_line.at(line) = 0;
  }

  if (is_sampled_set(set)) {
    const uint64_t currentVal = set_timer.at(static_cast<std::size_t>(set)) % OPTGEN_SIZE;
    const uint64_t sample_tag = CRC(paddr >> 12) % 256;
    const std::size_t sample_set = static_cast<std::size_t>((paddr >> LOG2_BLOCK) % SAMPLER_SETS);

    auto& hist_set = cache_history_sampler.at(sample_set);
    auto found = hist_set.find(sample_tag);
    auto& og = optgen_occup_vector.at(static_cast<std::size_t>(set));

    if ((type != access_type::PREFETCH) && found != hist_set.end()) {
      // Demand re-reference: ask OPTgen whether OPT would have kept the line
      // over this usage interval, and train the PC that last touched it.
      HISTORY& h = found->second;

      uint64_t current_time = set_timer.at(static_cast<std::size_t>(set));
      if (current_time < h.previousVal)
        current_time += TIMER_SIZE;
      const uint64_t previousVal = h.previousVal % OPTGEN_SIZE;
      const bool isWrap = (current_time - h.previousVal) > OPTGEN_SIZE;

      if (!isWrap && og.is_cache(currentVal, previousVal)) {
        if (h.prefetching)
          predictor_prefetch.increase(h.PCval);
        else
          predictor_demand.increase(h.PCval);
      } else {
        if (h.prefetching)
          predictor_prefetch.decrease(h.PCval);
        else
          predictor_demand.decrease(h.PCval);
      }

      og.set_access(currentVal);
      update_cache_history(sample_set, h.lru);
      h.prefetching = false;
    } else if (found == hist_set.end()) {
      // First time this address is seen in the sampler. Evict the sampler's
      // LRU entry if the set is full.
      if (hist_set.size() == SAMPLER_HIST) {
        uint64_t addr_val = 0;
        for (auto& e : hist_set) {
          if (e.second.lru == (SAMPLER_HIST - 1)) {
            addr_val = e.first;
            break;
          }
        }
        hist_set.erase(addr_val);
      }

      hist_set[sample_tag] = HISTORY{};
      if (type == access_type::PREFETCH) {
        hist_set[sample_tag].set_prefetch();
        og.set_prefetch(currentVal);
      } else {
        og.set_access(currentVal);
      }

      update_cache_history(sample_set, static_cast<uint32_t>(SAMPLER_HIST - 1));
    } else {
      // Prefetch re-reference. Only a short prefetch-to-prefetch interval is
      // treated as a useful liveness interval; see CRC2 paper section 3.1.
      HISTORY& h = found->second;
      const uint64_t previousVal = h.previousVal % OPTGEN_SIZE;

      if (set_timer.at(static_cast<std::size_t>(set)) - h.previousVal < 5 * NUM_CPUS) {
        if (og.is_cache(currentVal, previousVal)) {
          if (h.prefetching)
            predictor_prefetch.increase(h.PCval);
          else
            predictor_demand.increase(h.PCval);
        }
      }

      h.set_prefetch();
      og.set_prefetch(currentVal);
      update_cache_history(sample_set, h.lru);
    }

    hist_set[sample_tag].update(static_cast<uint32_t>(set_timer.at(static_cast<std::size_t>(set))), PC);
    hist_set[sample_tag].lru = 0;
    set_timer.at(static_cast<std::size_t>(set)) = (set_timer.at(static_cast<std::size_t>(set)) + 1) % TIMER_SIZE;
  }

  // Insertion / promotion priority from the predictor.
  bool prediction = predictor_demand.get_prediction(PC);
  if (type == access_type::PREFETCH)
    prediction = predictor_prefetch.get_prediction(PC);

  sample_signature.at(line) = PC;

  if (!prediction) {
    // Cache-averse: insert at MAXRRIP so it is the next victim.
    rrip.at(line) = MAXRRIP;
  } else {
    // Cache-friendly: insert at 0. Age the other cache-friendly lines, but
    // ONLY on a miss, and only while none has already saturated at MAXRRIP-1.
    rrip.at(line) = 0;
    if (!hit) {
      bool isMaxVal = false;
      for (long i = 0; i < NUM_WAY; i++) {
        if (rrip.at(base + static_cast<std::size_t>(i)) == MAXRRIP - 1)
          isMaxVal = true;
      }
      for (long i = 0; i < NUM_WAY; i++) {
        if (!isMaxVal && rrip.at(base + static_cast<std::size_t>(i)) < MAXRRIP - 1)
          rrip.at(base + static_cast<std::size_t>(i))++;
      }
    }
    rrip.at(line) = 0;
  }
}

void hawkeye::replacement_final_stats()
{
  uint64_t hits = 0;
  uint64_t accesses = 0;
  for (const auto& og : optgen_occup_vector) {
    hits += og.num_cache;
    accesses += og.access;
  }

  fmt::print("\nHawkeye: fills {} hits {} detrains {}\n", stat_fills, stat_hits, stat_detrains);
  fmt::print("Hawkeye: OPTgen hits {} accesses {} hit rate {:.2f}%\n", hits, accesses, accesses ? 100.0 * static_cast<double>(hits) / static_cast<double>(accesses) : 0.0);
}
