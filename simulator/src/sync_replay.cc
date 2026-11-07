#include "sync_replay.h"

#include <algorithm>
#include <deque>
#include <map>
#include <set>
#include <stdexcept>
#include <utility>
#include <vector>
#include <fmt/core.h>

namespace
{
struct mutex_state {
  int holder = -1;             // the core holding it, or -1
  std::deque<unsigned> queue;  // cores waiting for it, first come first served
};

struct state {
  bool active = false;
  std::map<uint64_t, uint64_t> released_upto; // tid -> highest seq released (a base sets first seq - 1)
  std::vector<uint64_t> acquires, releases, stall_total, stall_period;
  // mutex order (sync_mutex_design_2026-10-19.md)
  bool timing = true;
  std::set<uint64_t> mutexes_seen;
  std::map<uint64_t, mutex_state> mutexes;
  std::vector<uint64_t> mutex_acquires, mutex_stall;
  uint64_t ordered_acquires = 0, unheld_releases = 0;
};

state& st()
{
  static state s;
  return s;
}

void grow(unsigned cpu)
{
  auto& s = st();
  if (std::size(s.acquires) <= cpu) {
    s.acquires.resize(cpu + 1);
    s.releases.resize(cpu + 1);
    s.stall_total.resize(cpu + 1);
    s.stall_period.resize(cpu + 1);
  }
  if (std::size(s.mutex_acquires) <= cpu) {
    s.mutex_acquires.resize(cpu + 1);
    s.mutex_stall.resize(cpu + 1);
  }
}
} // namespace

namespace champsim::sync
{
void set_base(uint64_t first_release_id)
{
  auto& s = st();
  s.active = true;
  const uint64_t tid = first_release_id & 0xff;
  const uint64_t seq = first_release_id >> 8;
  auto [it, inserted] = s.released_upto.try_emplace(tid, seq == 0 ? 0 : seq - 1);
  if (!inserted)
    it->second = std::max(it->second, seq == 0 ? 0 : seq - 1);
}

bool released(uint64_t id)
{
  const auto& s = st();
  auto it = s.released_upto.find(id & 0xff);
  if (it == s.released_upto.end())
    return true; // a thread no trace holds
  return (id >> 8) <= it->second;
}

void release(unsigned cpu, uint64_t id)
{
  auto& s = st();
  s.active = true;
  grow(cpu);
  ++s.releases[cpu];
  auto [it, inserted] = s.released_upto.try_emplace(id & 0xff, id >> 8);
  if (!inserted)
    it->second = std::max(it->second, id >> 8);
}

void note_acquire(unsigned cpu)
{
  auto& s = st();
  s.active = true;
  grow(cpu);
  ++s.acquires[cpu];
}

void note_stall(unsigned cpu)
{
  grow(cpu);
  ++st().stall_total[cpu];
  ++st().stall_period[cpu];
}

uint64_t take_stall_cycles(unsigned cpu)
{
  auto& s = st();
  if (std::size(s.stall_period) <= cpu)
    return 0;
  return std::exchange(s.stall_period[cpu], 0);
}

bool active() { return st().active; }

namespace
{
std::vector<std::function<bool()>>& l1d_checks()
{
  static std::vector<std::function<bool()>> v;
  return v;
}
} // namespace

void register_l1d_pending(unsigned cpu, std::function<bool()> has_pending_writes)
{
  if (std::size(l1d_checks()) <= cpu)
    l1d_checks().resize(cpu + 1);
  l1d_checks()[cpu] = std::move(has_pending_writes);
}

bool l1d_pending_writes(unsigned cpu)
{
  return cpu < std::size(l1d_checks()) && l1d_checks()[cpu] && l1d_checks()[cpu]();
}

void print_stats()
{
  const auto& s = st();
  if (!s.active)
    return;
  fmt::print("SYNC REPLAY: on ({} threads with sync records)\n", std::size(s.released_upto));
  for (std::size_t cpu = 0; cpu < std::size(s.acquires); ++cpu)
    fmt::print("CPU {} SYNC ACQUIRES: {} RELEASES: {} CYCLES HELD: {}\n", cpu, s.acquires[cpu], s.releases[cpu], s.stall_total[cpu]);
  if (!std::empty(s.mutexes_seen)) {
    fmt::print("SYNC MUTEX ORDER: {} ({} mutexes; ordered acquires {}; releases of a mutex not held {})\n", s.timing ? "timing" : "recorded",
               std::size(s.mutexes_seen), s.ordered_acquires, s.unheld_releases);
    for (std::size_t cpu = 0; cpu < std::size(s.mutex_acquires); ++cpu)
      fmt::print("CPU {} MUTEX ACQUIRES: {} CYCLES WAITING FOR A MUTEX: {}\n", cpu, s.mutex_acquires[cpu], s.mutex_stall[cpu]);
  }
}

void set_mutex_order(const std::string& mode)
{
  if (mode != "timing" && mode != "recorded")
    throw std::invalid_argument("sync_mutex_order must be \"timing\" or \"recorded\"");
  st().timing = (mode == "timing");
}

bool mutex_timing() { return st().timing; }

void note_mutex_record(uint64_t mutex) { st().mutexes_seen.insert(mutex); }

bool mutex_ready(unsigned cpu, uint64_t mutex)
{
  auto& mx = st().mutexes[mutex];
  if (mx.holder < 0 && (std::empty(mx.queue) || mx.queue.front() == cpu))
    return true;
  // held (by another core, or by this one with its release still in flight), or others are first
  if (std::find(std::begin(mx.queue), std::end(mx.queue), cpu) == std::end(mx.queue))
    mx.queue.push_back(cpu);
  return false;
}

void mutex_take(unsigned cpu, uint64_t mutex, bool ordered)
{
  auto& s = st();
  grow(cpu);
  auto& mx = s.mutexes[mutex];
  if (!std::empty(mx.queue) && mx.queue.front() == cpu)
    mx.queue.pop_front();
  mx.holder = static_cast<int>(cpu);
  ++s.mutex_acquires[cpu];
  if (ordered)
    ++s.ordered_acquires;
}

void mutex_release(unsigned cpu, uint64_t mutex)
{
  auto& s = st();
  auto it = s.mutexes.find(mutex);
  if (it == std::end(s.mutexes) || it->second.holder != static_cast<int>(cpu)) {
    ++s.unheld_releases; // only where a trace was cut or skipped while the mutex was held
    return;
  }
  it->second.holder = -1;
}

void note_mutex_stall(unsigned cpu)
{
  grow(cpu);
  ++st().mutex_stall[cpu];
}

void print_state()
{
  const auto& s = st();
  int n = 0;
  for (const auto& [addr, mx] : s.mutexes) {
    if (mx.holder < 0 && std::empty(mx.queue))
      continue;
    if (++n > 20) {
      fmt::print("SYNC STATE: more mutexes held or waited for\n");
      break;
    }
    fmt::print("SYNC STATE: mutex {:#x} held by {} waited for by", addr, mx.holder);
    for (auto c : mx.queue)
      fmt::print(" {}", c);
    fmt::print("\n");
  }
  for (const auto& [tid, seq] : s.released_upto)
    fmt::print("SYNC STATE: thread {} released up to seq {}\n", tid, seq);
}
} // namespace champsim::sync
