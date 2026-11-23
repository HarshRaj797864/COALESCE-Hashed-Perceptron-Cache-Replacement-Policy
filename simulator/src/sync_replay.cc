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
  // acquires that waited for their mutex (lock_wait_design_2026-11-06.md), records only:
  // [0] warm-up, [1] measured; contended = another core held it or was ahead in its queue
  std::vector<uint8_t> wait_flags; // per core, the acquire at its dispatch head: 1 held a cycle, 2 another core involved
  std::vector<uint64_t> waited_contended[2], waited_own[2], mutex_stall_measured;
  // F-C (lock_fix_design_2026-11-12.md): lock-word requests issued, [0] warm-up, [1] measured
  bool lock_word = false;
  std::vector<uint64_t> lock_word_requests[2];
  // K2 step 3 (k2_sharing_gap_design_2026-11-17.md, amendment 2): the lead limit, a diagnostic
  uint64_t lead_delta = 0;
  std::vector<uint64_t> lead_pos, lead_last, lead_max, lead_cycles[2];
  std::vector<uint8_t> lead_wait, lead_done;
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
    s.wait_flags.resize(cpu + 1);
    for (auto* v : {&s.waited_contended[0], &s.waited_contended[1], &s.waited_own[0], &s.waited_own[1], &s.mutex_stall_measured,
                    &s.lock_word_requests[0], &s.lock_word_requests[1]})
      v->resize(cpu + 1);
  }
}
void grow_lead(unsigned cpu)
{
  auto& s = st();
  if (std::size(s.lead_pos) <= cpu) {
    for (auto* v : {&s.lead_pos, &s.lead_last, &s.lead_max, &s.lead_cycles[0], &s.lead_cycles[1]})
      v->resize(cpu + 1);
    s.lead_wait.resize(cpu + 1);
    s.lead_done.resize(cpu + 1);
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
  if (s.lead_delta != 0) { // K2 step 3: printed only when on (traces without sync records too)
    fmt::print("SYNC LEAD LIMIT: {} instructions\n", s.lead_delta);
    for (std::size_t cpu = 0; cpu < std::size(s.lead_pos); ++cpu)
      fmt::print("CPU {} LEAD HOLDS: cycles measured {} warmup {}; max lead {}\n", cpu, s.lead_cycles[1][cpu], s.lead_cycles[0][cpu], s.lead_max[cpu]);
  }
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
    for (std::size_t cpu = 0; cpu < std::size(s.mutex_acquires); ++cpu)
      fmt::print("CPU {} MUTEX WAITED ACQUIRES: measured contended {} own {} cycles {}; warmup contended {} own {}\n", cpu, s.waited_contended[1][cpu],
                 s.waited_own[1][cpu], s.mutex_stall_measured[cpu], s.waited_contended[0][cpu], s.waited_own[0][cpu]);
  }
  if (s.lock_word) { // printed only when on, so a run with the setting absent prints exactly as before
    fmt::print("SYNC LOCK WORD: request\n");
    for (std::size_t cpu = 0; cpu < std::size(s.lock_word_requests[0]); ++cpu)
      fmt::print("CPU {} LOCK-WORD REQUESTS: measured {} warmup {}\n", cpu, s.lock_word_requests[1][cpu], s.lock_word_requests[0][cpu]);
  }
}

void set_mutex_order(const std::string& mode)
{
  if (mode != "timing" && mode != "recorded")
    throw std::invalid_argument("sync_mutex_order must be \"timing\" or \"recorded\"");
  st().timing = (mode == "timing");
}

bool mutex_timing() { return st().timing; }

void set_lock_word(const std::string& mode)
{
  if (mode != "none" && mode != "request")
    throw std::invalid_argument("sync_lock_word must be \"none\" or \"request\"");
  st().lock_word = (mode == "request");
}

bool lock_word_request() { return st().lock_word; }

bool mutex_contended(unsigned cpu, uint64_t mutex)
{
  const auto& s = st();
  const auto it = s.mutexes.find(mutex);
  if (it == std::end(s.mutexes))
    return false;
  const auto& mx = it->second;
  const auto me = std::find(std::begin(mx.queue), std::end(mx.queue), cpu);
  return (mx.holder >= 0 && mx.holder != static_cast<int>(cpu)) || me != std::begin(mx.queue); // as note_mutex_wait's flag 2
}

void set_lead_limit(uint64_t delta) { st().lead_delta = delta; }

uint64_t lead_limit() { return st().lead_delta; }

bool lead_check(unsigned cpu, uint64_t pos)
{
  auto& s = st();
  grow_lead(cpu);
  s.lead_pos[cpu] = pos;
  bool any = false;
  uint64_t lo = 0;
  for (std::size_t c = 0; c < std::size(s.lead_pos); ++c) {
    if (s.lead_wait[c] || s.lead_done[c])
      continue;
    lo = any ? std::min(lo, s.lead_pos[c]) : s.lead_pos[c];
    any = true;
  }
  s.lead_last[cpu] = (any && pos > lo) ? pos - lo : 0;
  return any && s.lead_last[cpu] > s.lead_delta;
}

void note_lead(unsigned cpu, bool waiting, bool held, bool measured)
{
  auto& s = st();
  grow(cpu);
  grow_lead(cpu);
  s.lead_wait[cpu] = waiting;
  if (held) {
    ++s.lead_cycles[measured ? 1 : 0][cpu];
    ++s.stall_period[cpu]; // the livelock check only (not CYCLES HELD)
  }
  if (!waiting && !s.lead_done[cpu])
    s.lead_max[cpu] = std::max(s.lead_max[cpu], s.lead_last[cpu]);
}

void set_done(unsigned cpu, bool done)
{
  grow_lead(cpu);
  st().lead_done[cpu] = done;
}

void note_lock_word_request(unsigned cpu, bool measured)
{
  auto& s = st();
  grow(cpu);
  ++s.lock_word_requests[measured ? 1 : 0][cpu];
}

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

void note_mutex_wait(unsigned cpu, uint64_t mutex, bool measured)
{
  auto& s = st();
  grow(cpu);
  s.wait_flags[cpu] |= 1;
  if (measured)
    ++s.mutex_stall_measured[cpu];
  const auto it = s.mutexes.find(mutex);
  if (it == std::end(s.mutexes))
    return;
  const auto& mx = it->second;
  const auto me = std::find(std::begin(mx.queue), std::end(mx.queue), cpu);
  if ((mx.holder >= 0 && mx.holder != static_cast<int>(cpu)) || me != std::begin(mx.queue))
    s.wait_flags[cpu] |= 2; // held by another core, or another core is ahead of this one
}

void note_mutex_taken(unsigned cpu, bool measured)
{
  auto& s = st();
  grow(cpu);
  if (s.wait_flags[cpu] & 1)
    ++((s.wait_flags[cpu] & 2) ? s.waited_contended : s.waited_own)[measured ? 1 : 0][cpu];
  s.wait_flags[cpu] = 0;
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
