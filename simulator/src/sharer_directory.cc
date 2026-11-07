#include "sharer_directory.h"

#include <array>
#include <cassert>
#include <cstdlib>
#include <regex>
#include <stdexcept>
#include <unordered_map>

namespace
{
struct dir_entry {
  uint64_t presence = 0; // bit cpu*dir_levels + level
  uint32_t protocol = 0; // bit cpu
  uint32_t stale = 0;    // bit cpu; only ever set at private_coherence >= 1
  uint32_t bounded = 0;  // bit cpu: the bounded protocol view (diagnosis; sharer_directory.h)
  bool llc = false;      // the LLC holds the line (kept for the bounded and gem5-rule views only)
  uint32_t g5 = 0;       // bit cpu: the gem5-rule view (step 3; sharer_directory.h)
  bool g5_excl = false;  // ... and whether its one listed core holds the line exclusive (E or M)
  uint32_t g5_silent = 0; // bit cpu: listed by the gem5-rule view only through a silent re-listing (amendment 2)
};

// Single-threaded simulator, one directory per process.
std::unordered_map<uint64_t, dir_entry>& table()
{
  static std::unordered_map<uint64_t, dir_entry> t;
  return t;
}

unsigned& registered()
{
  static unsigned n = 0;
  return n;
}

unsigned& coherence_level()
{
  static unsigned l = 0;
  return l;
}

unsigned& latency_cycles()
{
  static unsigned c = 0;
  return c;
}

// One per private cache, indexed cpu*dir_levels + level.
auto& invalidators()
{
  static std::array<std::function<void(uint64_t)>, champsim::coherence::dir_max_cpus * champsim::coherence::dir_levels> a;
  return a;
}

uint64_t presence_bit(unsigned cpu, unsigned level)
{
  assert(cpu < champsim::coherence::dir_max_cpus && level < champsim::coherence::dir_levels);
  return uint64_t{1} << (cpu * champsim::coherence::dir_levels + level);
}

// Cores with any presence bit, as a core mask.
uint32_t cores_of(uint64_t presence)
{
  uint32_t cores = 0;
  for (unsigned c = 0; presence != 0; ++c, presence >>= champsim::coherence::dir_levels) {
    if (presence & ((uint64_t{1} << champsim::coherence::dir_levels) - 1))
      cores |= uint32_t{1} << c;
  }
  return cores;
}

void erase_if_empty(std::unordered_map<uint64_t, dir_entry>::iterator it)
{
  if (it->second.presence == 0 && it->second.protocol == 0 && it->second.stale == 0 && it->second.bounded == 0 && !it->second.llc && it->second.g5 == 0)
    table().erase(it);
}

// The gem5-rule view (sharer_directory.h): the line is held nowhere on chip,
// so every core is forgotten.
void g5_forget_all(dir_entry& e)
{
  e.g5 = 0;
  e.g5_excl = false;
  e.g5_silent = 0;
}

// Amendment 2: a core stays marked as silently re-listed only while the
// gem5-rule view lists it and the bounded view does not.
void g5_silent_trim(dir_entry& e) { e.g5_silent &= e.g5 & ~e.bounded; }

// ... `cpu` has taken the line: it alone, exclusive.
void g5_own(dir_entry& e, unsigned cpu)
{
  e.g5 = uint32_t{1} << cpu;
  e.g5_excl = true;
  e.g5_silent = 0;
}

// `cpu` has taken `line`: every other core's private copies go, and every
// other core is marked stale for it. The caller has set the protocol view to
// `cpu` alone, so the entry outlives the dir_evict calls the copies make.
void invalidate_others(uint64_t line, unsigned cpu)
{
  using namespace champsim::coherence;
  const uint64_t held = table().at(line).presence; // a copy: dir_evict edits the entry
  for (unsigned c = 0; c < dir_max_cpus; ++c) {
    if (c == cpu)
      continue;
    for (unsigned level = 0; level < dir_levels; ++level) {
      if ((held & presence_bit(c, level)) != 0)
        invalidators().at(c * dir_levels + level)(line);
    }
  }
  auto& e = table().at(line);
  assert((cores_of(e.presence) & ~(uint32_t{1} << cpu)) == 0);
  e.stale = ~(uint32_t{1} << cpu);
}
} // namespace

namespace champsim::coherence
{
std::pair<int, int> private_cache_of(const std::string& name)
{
  static const std::regex pat{"^cpu([0-9]+)_(L1I|L1D|L2C)$"};
  std::smatch m;
  if (!std::regex_match(name, m, pat))
    return {-1, -1};
  const int level = m[2] == "L1I" ? 0 : (m[2] == "L1D" ? 1 : 2);
  return {std::stoi(m[1]), level};
}

void dir_register_private_cache(unsigned cpu, unsigned level, std::function<void(uint64_t)> invalidate)
{
  assert(cpu < dir_max_cpus && level < dir_levels);
  invalidators().at(cpu * dir_levels + level) = std::move(invalidate);
  ++registered();
}
unsigned dir_registered_private_caches() { return registered(); }

void set_private_coherence(unsigned level)
{
  if (level > 2)
    throw std::invalid_argument("private_coherence must be 0, 1 or 2");
  coherence_level() = level;
}
unsigned private_coherence() { return coherence_level(); }

void set_coherence_latency(unsigned cycles)
{
  if (cycles > 0 && coherence_level() < 2)
    throw std::invalid_argument("coherence_latency needs private_coherence 2");
  latency_cycles() = cycles;
}
unsigned coherence_latency() { return latency_cycles(); }

dir_lookup dir_peek(uint64_t line, unsigned cpu)
{
  assert(cpu < dir_max_cpus);
  const uint32_t me = uint32_t{1} << cpu;
  dir_lookup r;
  auto it = table().find(line);
  if (it == table().end())
    return r;
  r.presence_others = cores_of(it->second.presence) & ~me;
  r.protocol_others = it->second.protocol & ~me;
  return r;
}

void dir_fill(uint64_t line, unsigned cpu, unsigned level) { table()[line].presence |= presence_bit(cpu, level); }

void dir_evict(uint64_t line, unsigned cpu, unsigned level)
{
  auto it = table().find(line);
  if (it == table().end())
    return;
  auto& e = it->second;
  e.presence &= ~presence_bit(cpu, level);
  // gem5 rule: an exclusive holder whose last private copy has gone is
  // forgotten (gem5's PUTX / PUTE).
  if ((cores_of(e.presence) & (uint32_t{1} << cpu)) == 0 && e.g5_excl && e.g5 == (uint32_t{1} << cpu))
    g5_forget_all(e);
  if (e.presence == 0 && !e.llc) {
    e.bounded = 0; // held nowhere on chip: the bounded view forgets
    g5_forget_all(e); // and so does the gem5-rule view
  }
  g5_silent_trim(e);
  erase_if_empty(it);
}

void dir_llc_fill(uint64_t line) { table()[line].llc = true; }

void dir_llc_evict(uint64_t line)
{
  auto it = table().find(line);
  if (it == table().end())
    return;
  it->second.llc = false;
  if (it->second.presence == 0) {
    it->second.bounded = 0; // held nowhere on chip: the bounded view forgets
    g5_forget_all(it->second); // and so does the gem5-rule view
  }
  g5_silent_trim(it->second);
  erase_if_empty(it);
}

dir_lookup dir_llc_request(uint64_t line, unsigned cpu, dir_req kind)
{
  assert(cpu < dir_max_cpus);
  const uint32_t me = uint32_t{1} << cpu;
  auto& e = table()[line];
  dir_lookup r;
  r.presence_others = cores_of(e.presence) & ~me;
  r.protocol_others = e.protocol & ~me;
  r.bounded_others = e.bounded & ~me;
  r.g5_others = e.g5 & ~me;
  switch (kind) {
  case dir_req::read:
    e.protocol |= me;
    break;
  case dir_req::store:
    e.protocol = me;
    break;
  case dir_req::writeback:
    e.protocol &= ~me;
    break;
  }
  if (coherence_level() >= 1) {
    if (kind == dir_req::store)
      invalidate_others(line, cpu);
    else if (kind == dir_req::read)
      table().at(line).stale &= ~me; // its fill is ordered after any earlier grant
  }
  // The bounded view (diagnosis) changes as the protocol view does. Set after
  // the invalidations, which may have found the line held nowhere on chip.
  {
    auto& b = table().at(line).bounded;
    if (kind == dir_req::read)
      b |= me;
    else if (kind == dir_req::store)
      b = me;
    else
      b &= ~me;
  }
  // The gem5-rule view, likewise after the invalidations: a read nobody else
  // holds is granted E, else it shares; a store takes M; a writeback leaves.
  {
    auto& g = table().at(line);
    if (kind == dir_req::read) {
      if ((g.g5 & ~me) == 0) {
        g5_own(g, cpu);
      } else {
        g.g5 |= me;
        g.g5_excl = false;
      }
    } else if (kind == dir_req::store) {
      g5_own(g, cpu);
    } else {
      g.g5 &= ~me;
      if (g.g5 == 0)
        g.g5_excl = false;
    }
    g5_silent_trim(g);
  }
  erase_if_empty(table().find(line));
  return r;
}

dir_lookup dir_private_ownership_hit(uint64_t line, unsigned cpu)
{
  assert(cpu < dir_max_cpus);
  const uint32_t me = uint32_t{1} << cpu;
  dir_lookup r;
  auto it = table().find(line);
  if (it == table().end())
    return r;
  r.presence_others = cores_of(it->second.presence) & ~me;
  r.protocol_others = it->second.protocol & ~me;
  r.bounded_others = it->second.bounded & ~me; // a subset of protocol_others
  r.g5_others = it->second.g5 & ~me;           // a subset of bounded_others
  if (r.presence_others == 0 && r.protocol_others == 0) {
    auto& e = it->second;
    // amendment 2: a silent re-listing -- the requester is in neither the
    // bounded nor the gem5-rule view (its writeback dropped it from both)
    const uint32_t kept = e.g5_silent & e.g5;
    const uint32_t relisted = ((e.bounded | e.g5) & me) == 0 ? me : 0;
    g5_own(e, cpu); // gem5: the store makes the line M here, whoever else was listed
    e.g5_silent = kept | relisted;
    g5_silent_trim(e);
    r.g5_relisted = relisted != 0;
    return r;
  }
  it->second.protocol = me;
  invalidate_others(line, cpu);
  table().at(line).bounded = me;
  g5_own(table().at(line), cpu);
  return r;
}

std::FILE* dir_event_log()
{
  static std::FILE* const f = [] {
    const char* path = std::getenv("COHERENCE_EVENT_LOG");
    return (path != nullptr && *path != '\0') ? std::fopen(path, "w") : nullptr;
  }();
  return f;
}

bool dir_is_stale(uint64_t line, unsigned cpu)
{
  auto it = table().find(line);
  return it != table().end() && (it->second.stale & (uint32_t{1} << cpu)) != 0;
}

bool dir_present(uint64_t line, unsigned cpu, unsigned level)
{
  auto it = table().find(line);
  return it != table().end() && (it->second.presence & presence_bit(cpu, level)) != 0;
}

uint64_t dir_count_present(unsigned cpu, unsigned level)
{
  const uint64_t bit = presence_bit(cpu, level);
  uint64_t n = 0;
  for (const auto& [line, e] : table())
    if (e.presence & bit)
      ++n;
  return n;
}

uint64_t dir_count_view_order_violations()
{
  uint64_t n = 0;
  for (const auto& [line, e] : table())
    if ((e.g5 & ~e.bounded) != 0 || (e.bounded & ~e.protocol) != 0)
      ++n;
  return n;
}

uint64_t dir_count_view_order_by_silent_relisting()
{
  uint64_t n = 0;
  for (const auto& [line, e] : table())
    if ((e.g5 & ~e.bounded) != 0 && (e.g5 & ~e.bounded & ~e.g5_silent) == 0 && (e.bounded & ~e.protocol) == 0)
      ++n;
  return n;
}

uint64_t dir_count_stale_holders()
{
  uint64_t n = 0;
  for (const auto& [line, e] : table())
    n += static_cast<uint64_t>(__builtin_popcount(cores_of(e.presence) & e.stale));
  return n;
}
} // namespace champsim::coherence
