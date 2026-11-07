/*
 *    Copyright 2023 The ChampSim Contributors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "cache.h"

#include <algorithm>
#include <cassert>
#include <cmath>
#include <iomanip>
#include <numeric>
#include <fmt/core.h>

#include "bandwidth.h"
#include "champsim.h"
#include "chrono.h"
#include "deadlock.h"
#include "instruction.h"
#include "util/algorithm.h"
#include "util/bits.h"
#include "util/span.h"

CACHE::CACHE(CACHE&& /*other*/) : champsim::modules::cache_module(champsim::chrono::picoseconds{})
{
  assert(false && "CACHE move constructor called, but this is not expected to be used in a way that requires moving. Please report this to the developers.");
}

auto CACHE::operator=(CACHE&& /*other*/) -> CACHE&
{
  assert(false
         && "CACHE move assignment operator called, but this is not expected to be used in a way that requires moving. Please report this to the developers.");
  return *this;
}

CACHE::tag_lookup_type::tag_lookup_type(const request_type& req, bool local_pref, bool skip)
    : address(req.address), v_address(req.v_address), data(req.data), ip(req.ip), instr_id(req.instr_id), pf_metadata(req.pf_metadata), cpu(req.cpu),
      type(req.type), prefetch_from_this(local_pref), skip_fill(skip), is_translated(req.is_translated), instr_depend_on_me(req.instr_depend_on_me)
{
}

CACHE::fill_type::fill_type(const tag_lookup_type& req, champsim::chrono::clock::time_point _time_enqueued)
    : address(req.address), v_address(req.v_address), ip(req.ip), instr_id(req.instr_id), cpu(req.cpu), type(req.type),
      prefetch_from_this(req.prefetch_from_this), time_enqueued(_time_enqueued), instr_depend_on_me(req.instr_depend_on_me), to_return(req.to_return)
{
}

CACHE::fill_type CACHE::fill_type::merge(fill_type predecessor, fill_type successor)
{
  std::vector<uint64_t> merged_instr{};
  std::vector<std::deque<response_type>*> merged_return{};

  std::set_union(std::begin(predecessor.instr_depend_on_me), std::end(predecessor.instr_depend_on_me), std::begin(successor.instr_depend_on_me),
                 std::end(successor.instr_depend_on_me), std::back_inserter(merged_instr));
  std::set_union(std::begin(predecessor.to_return), std::end(predecessor.to_return), std::begin(successor.to_return), std::end(successor.to_return),
                 std::back_inserter(merged_return));

  fill_type retval{(successor.type == access_type::PREFETCH) ? predecessor : successor};

  // set the time enqueued to the predecessor unless its a demand into prefetch, in which case we use the successor
  retval.time_enqueued =
      ((successor.type != access_type::PREFETCH && predecessor.type == access_type::PREFETCH)) ? successor.time_enqueued : predecessor.time_enqueued;
  retval.instr_depend_on_me = merged_instr;
  retval.to_return = merged_return;
  retval.data_promise = predecessor.data_promise;

  if constexpr (champsim::debug_print) {
    if (successor.type == access_type::PREFETCH) {
      fmt::print("[MSHR] {} address {} type: {} into address {} type: {}\n", __func__, successor.address,
                 access_type_names.at(champsim::to_underlying(successor.type)), predecessor.address,
                 access_type_names.at(champsim::to_underlying(successor.type)));
    } else {
      fmt::print("[MSHR] {} address {} type: {} into address {} type: {}\n", __func__, predecessor.address,
                 access_type_names.at(champsim::to_underlying(predecessor.type)), successor.address,
                 access_type_names.at(champsim::to_underlying(successor.type)));
    }
  }

  return retval;
}

auto CACHE::fill_block(fill_type fill, uint32_t metadata) -> BLOCK
{
  CACHE::BLOCK to_fill;
  to_fill.valid = true;
  to_fill.prefetch = fill.prefetch_from_this;
  to_fill.dirty = (fill.type == access_type::WRITE);
  to_fill.address = fill.address;
  to_fill.v_address = fill.v_address;
  to_fill.data = fill.data_promise->data;
  to_fill.pf_metadata = metadata;

  // COALESCE coherence extensions. A freshly filled line is owned solely by the
  // core that requested it: MODIFIED if the fill was a writeback, EXCLUSIVE
  // otherwise. The allocating PC is carried so a replacement policy can recover
  // the context that brought the line in.
  to_fill.state = to_fill.dirty ? MODIFIED : EXCLUSIVE;
  to_fill.sharer_mask = static_cast<uint16_t>(1u << fill.cpu);
  to_fill.ip = fill.ip.to<uint64_t>();

  return to_fill;
}

auto CACHE::matches_address(champsim::address addr) const
{
  return [match = addr.slice_upper(OFFSET_BITS), shamt = OFFSET_BITS](const auto& entry) {
    return entry.address.slice_upper(shamt) == match;
  };
}

template <typename T>
champsim::address CACHE::module_address(const T& element) const
{
  auto address = virtual_prefetch ? element.v_address : element.address;
  return champsim::address{address.slice_upper(match_offset_bits ? champsim::data::bits{} : OFFSET_BITS)};
}

bool CACHE::handle_fill(const fill_type& fill)
{
  cpu = fill.cpu;

  // B3 v4 (private_coherence 1 and 2): another core took this line while the
  // fill was in flight. The waiting instruction completes -- it used the data
  // once, as it would under a real protocol -- and no copy is left behind.
  if (dir_cpu >= 0 && champsim::coherence::private_coherence() >= 1
      && champsim::coherence::dir_is_stale(dir_line(fill.address), static_cast<unsigned>(dir_cpu))) {
    ++sim_stats.coherence_dir_stale_fills;
    dir_log_event('S', fill, 0, 0);
    if (fill.type != access_type::PREFETCH)
      sim_stats.total_miss_latency_cycles += (current_time - (fill.time_enqueued + clock_period)) / clock_period;
    sim_stats.fill.increment(std::pair{fill.type, fill.cpu});

    response_type response{fill.address, fill.v_address, fill.data_promise->data, fill.data_promise->pf_metadata, fill.instr_depend_on_me};
    for (auto* ret : fill.to_return) {
      ret->push_back(response);
    }
    return true;
  }

  // find victim
  auto [set_begin, set_end] = get_set_span(fill.address);
  auto way = std::find_if_not(set_begin, set_end, [](auto x) { return x.valid; });
  if (way == set_end) {
    way = std::next(set_begin, impl_find_victim(fill.cpu, fill.instr_id, get_set_index(fill.address), &*set_begin, fill.ip, fill.address, fill.type));
  }
  assert(set_begin <= way);
  assert(way <= set_end);
  assert(way != set_end || fill.type != access_type::WRITE); // Writes may not bypass
  const auto way_idx = std::distance(set_begin, way);        // cast protected by earlier assertion

  if constexpr (champsim::debug_print) {
    fmt::print("[{}] {} instr_id: {} address: {} v_address: {} set: {} way: {} type: {} prefetch_metadata: {} cycle_enqueued: {} cycle: {}\n", NAME, __func__,
               fill.instr_id, fill.address, fill.v_address, get_set_index(fill.address), way_idx, access_type_names.at(champsim::to_underlying(fill.type)),
               fill.data_promise->pf_metadata, (fill.time_enqueued.time_since_epoch()) / clock_period, (current_time.time_since_epoch()) / clock_period);
  }

  if (way != set_end && way->valid && way->dirty) {
    request_type writeback_packet;

    writeback_packet.cpu = fill.cpu;
    writeback_packet.address = way->address;
    writeback_packet.data = way->data;
    writeback_packet.instr_id = fill.instr_id;
    writeback_packet.ip = champsim::address{};
    writeback_packet.type = access_type::WRITE;
    writeback_packet.pf_metadata = way->pf_metadata;
    writeback_packet.response_requested = false;

    if constexpr (champsim::debug_print) {
      fmt::print("[{}] {} evict address: {} v_address: {} prefetch_metadata: {}\n", NAME, __func__, writeback_packet.address, writeback_packet.v_address,
                 fill.data_promise->pf_metadata);
    }

    auto success = lower_level->add_wq(writeback_packet);
    if (!success) {
      return false;
    }
  }

  champsim::address evicting_address{};
  if (way != set_end && way->valid) {
    evicting_address = module_address(*way);
  }

  auto metadata_thru = impl_prefetcher_cache_fill(module_address(fill), get_set_index(fill.address), way_idx, (fill.type == access_type::PREFETCH),
                                                  evicting_address, fill.data_promise->pf_metadata);
  impl_replacement_cache_fill(fill.cpu, get_set_index(fill.address), way_idx, module_address(fill), fill.ip, evicting_address, fill.type);

  if (way != set_end) {
    if (way->valid && way->prefetch) {
      ++sim_stats.pf_useless;
    }

    // B3 v2 sharer directory: the victim leaves this private cache, the fill
    // enters it. Records only.
    if (dir_cpu >= 0) {
      if (way->valid)
        champsim::coherence::dir_evict(dir_line(way->address), static_cast<unsigned>(dir_cpu), static_cast<unsigned>(dir_level));
      champsim::coherence::dir_fill(dir_line(fill.address), static_cast<unsigned>(dir_cpu), static_cast<unsigned>(dir_level));
    }
    // The LLC's residency, for the bounded view only (b3_bounded_design_2026-10-17.md).
    if (dir_is_llc) {
      if (way->valid)
        champsim::coherence::dir_llc_evict(dir_line(way->address));
      champsim::coherence::dir_llc_fill(dir_line(fill.address));
    }

    if (fill.type == access_type::PREFETCH) {
      ++sim_stats.pf_fill;
    }

    *way = fill_block(fill, metadata_thru);
  }

  // COLLECT STATS
  if (fill.type != access_type::PREFETCH)
    sim_stats.total_miss_latency_cycles += (current_time - (fill.time_enqueued + clock_period)) / clock_period;
  sim_stats.fill.increment(std::pair{fill.type, fill.cpu});

  response_type response{fill.address, fill.v_address, fill.data_promise->data, metadata_thru, fill.instr_depend_on_me};
  for (auto* ret : fill.to_return) {
    ret->push_back(response);
  }

  return true;
}

bool CACHE::try_hit(const tag_lookup_type& handle_pkt)
{
  cpu = handle_pkt.cpu;

  // access cache
  auto [set_begin, set_end] = get_set_span(handle_pkt.address);
  auto way = std::find_if(set_begin, set_end, [matcher = matches_address(handle_pkt.address)](const auto& x) { return x.valid && matcher(x); });
  const auto hit = (way != set_end);
  const auto useful_prefetch = (hit && way->prefetch && !handle_pkt.prefetch_from_this);

  if constexpr (champsim::debug_print) {
    fmt::print("[{}] {} instr_id: {} address: {} v_address: {} data: {} set: {} way: {} ({}) type: {} cycle: {}\n", NAME, __func__, handle_pkt.instr_id,
               handle_pkt.address, handle_pkt.v_address, handle_pkt.data, get_set_index(handle_pkt.address), std::distance(set_begin, way),
               hit ? "HIT" : "MISS", access_type_names.at(champsim::to_underlying(handle_pkt.type)), current_time.time_since_epoch() / clock_period);
  }

  auto metadata_thru = handle_pkt.pf_metadata;
  if (should_activate_prefetcher(handle_pkt)) {
    metadata_thru = impl_prefetcher_cache_operate(module_address(handle_pkt), handle_pkt.ip, hit, useful_prefetch, handle_pkt.type, metadata_thru);
  }

  // update replacement policy
  const auto way_idx = std::distance(set_begin, way);
  impl_update_replacement_state(handle_pkt.cpu, get_set_index(handle_pkt.address), way_idx, module_address(handle_pkt), handle_pkt.ip, {}, handle_pkt.type,
                                hit);

  if (hit) {
    sim_stats.hits.increment(std::pair{handle_pkt.type, handle_pkt.cpu});

    // B3 v2: counted here and in handle_miss/handle_write, where a request is
    // accepted -- never above this branch, which a miss retried for a full
    // MSHR runs again.
    if (dir_is_llc)
      dir_on_llc_request(handle_pkt);

    // B3 v4, private_coherence 2: a store or RFO that hits a private copy
    // needs the line to itself. In the L1D that is a store (WRITE) or a
    // read-modify-write's load (RFO); in the L2C, an RFO that missed the L1D.
    // A WRITE reaching the L2C is a writeback, not a store.
    if (dir_cpu >= 0 && champsim::coherence::private_coherence() >= 2
        && (handle_pkt.type == access_type::RFO || (handle_pkt.type == access_type::WRITE && dir_level == 1)))
      dir_on_private_ownership_hit(handle_pkt);

    response_type response{handle_pkt.address, handle_pkt.v_address, way->data, metadata_thru, handle_pkt.instr_depend_on_me};
    for (auto* ret : handle_pkt.to_return) {
      ret->push_back(response);
    }

    way->dirty |= (handle_pkt.type == access_type::WRITE);

    // COALESCE: dynamic coherence state on a hit.
    //   Write hit -- the writer becomes sole owner. Bits cleared from the sharer
    //   mask are counted as a synthetic invalidation broadcast. This is LLC
    //   bookkeeping only: ChampSim models no inter-level coherence, so the
    //   "invalidated" cores' L1/L2 tags still hold stale copies. See
    //   coalesce_paper/COHERENCE_HOOK_AUDIT.md.
    //   Read hit  -- the reader joins the sharer set, and the line becomes
    //   SHARED once more than one core holds it.
    //
    //   Known simplification: a read hit on a MODIFIED line adds a sharer
    //   without downgrading M->S as real MESI would. Measured at 0.3% of
    //   MODIFIED observations, because the write-hit clearing keeps the state
    //   transient. Recorded in docs/policy_audit.md, not corrected here.
    // COALESCE: sharing-degree distribution, sampled at every hit BEFORE the
    // mask is modified, so it records how widely shared a line was when it was
    // accessed.
    //
    // coherence_sharer_hist has existed since the coherence hooks were written
    // and was never incremented -- declared in cache_stats.h, copied into
    // roi_stats, printed by plain_printer. It read as absent rather than zero
    // because the printer skips the block when the total is 0, which is why it
    // went unnoticed. docs/PLAN.md names sharing-degree distribution as one of
    // the three metrics gem5 validation compares against, so it has to work.
    {
      const auto observed = static_cast<std::size_t>(__builtin_popcount(way->sharer_mask));
      const auto bound = std::size(sim_stats.coherence_sharer_hist) - 1;
      ++sim_stats.coherence_sharer_hist[observed < bound ? observed : bound];
    }

    if (handle_pkt.type == access_type::WRITE) {
      const auto other_sharers = static_cast<uint16_t>(way->sharer_mask & static_cast<uint16_t>(~(1u << handle_pkt.cpu)));
      if (other_sharers != 0) {
        sim_stats.coherence_invalidations += static_cast<uint64_t>(__builtin_popcount(other_sharers));
        ++sim_stats.coherence_write_hit_other_sharer_events;
      }
      way->sharer_mask = static_cast<uint16_t>(1u << handle_pkt.cpu);
      way->state = MODIFIED;
    } else {
      // Store-time counter (cache_stats.h): an RFO is a store that missed the
      // private hierarchy. Read the mask BEFORE the storer is added to it.
      if (handle_pkt.type == access_type::RFO) {
        const auto rfo_other = static_cast<uint16_t>(way->sharer_mask & static_cast<uint16_t>(~(1u << handle_pkt.cpu)));
        if (rfo_other != 0) {
          ++sim_stats.coherence_rfo_hit_other_sharer_events;
          sim_stats.coherence_rfo_hit_other_sharers += static_cast<uint64_t>(__builtin_popcount(rfo_other));
        }
      }
      way->sharer_mask |= static_cast<uint16_t>(1u << handle_pkt.cpu);
      if (way->state != MODIFIED && __builtin_popcount(way->sharer_mask) > 1) {
        way->state = SHARED;
      }
    }

    // update prefetch stats and reset prefetch bit
    if (useful_prefetch) {
      ++sim_stats.pf_useful;
      way->prefetch = false;
    }
  }

  return hit;
}

auto CACHE::mshr_and_forward_packet(const tag_lookup_type& handle_pkt) -> std::pair<fill_type, request_type>
{
  fill_type to_allocate{handle_pkt, current_time};

  request_type fwd_pkt;

  fwd_pkt.asid[0] = handle_pkt.asid[0];
  fwd_pkt.asid[1] = handle_pkt.asid[1];
  fwd_pkt.type = (handle_pkt.type == access_type::WRITE) ? access_type::RFO : handle_pkt.type;
  fwd_pkt.pf_metadata = handle_pkt.pf_metadata;
  fwd_pkt.cpu = handle_pkt.cpu;

  fwd_pkt.address = handle_pkt.address;
  fwd_pkt.v_address = handle_pkt.v_address;
  fwd_pkt.data = handle_pkt.data;
  fwd_pkt.instr_id = handle_pkt.instr_id;
  fwd_pkt.ip = handle_pkt.ip;

  fwd_pkt.instr_depend_on_me = handle_pkt.instr_depend_on_me;
  fwd_pkt.response_requested = (!handle_pkt.prefetch_from_this || !handle_pkt.skip_fill);

  return std::pair{std::move(to_allocate), std::move(fwd_pkt)};
}

bool CACHE::handle_miss(const tag_lookup_type& handle_pkt)
{
  if constexpr (champsim::debug_print) {
    fmt::print("[{}] {} instr_id: {} address: {} v_address: {} type: {} local_prefetch: {} cycle: {}\n", NAME, __func__, handle_pkt.instr_id,
               handle_pkt.address, handle_pkt.v_address, access_type_names.at(champsim::to_underlying(handle_pkt.type)), handle_pkt.prefetch_from_this,
               current_time.time_since_epoch() / clock_period);
  }

  fill_type to_allocate{handle_pkt, current_time};

  cpu = handle_pkt.cpu;

  auto mshr_pkt = mshr_and_forward_packet(handle_pkt);

  // check mshr
  auto fill_entry = std::find_if(std::begin(MSHR), std::end(MSHR), matches_address(handle_pkt.address));
  bool mshr_full = (MSHR.size() == MSHR_SIZE);

  // check inflight fills
  if (fill_entry == MSHR.end()) {
    fill_entry = std::find_if(inflight_fills.begin(), inflight_fills.end(), matches_address(handle_pkt.address));
  }

  if (fill_entry != inflight_fills.end()) // miss or fill already inflight
  {
    if (fill_entry->type == access_type::PREFETCH && handle_pkt.type != access_type::PREFETCH) {
      // Mark the prefetch as useful
      if (fill_entry->prefetch_from_this) {
        ++sim_stats.pf_useful;
      }
    }

    // COLLECT STATS
    sim_stats.miss_merge.increment(std::pair{to_allocate.type, to_allocate.cpu});

    *fill_entry = fill_type::merge(*fill_entry, to_allocate);
  } else {
    if (mshr_full) { // not enough MSHR resource
      return false;  // TODO should we allow prefetches anyway if they will not be filled to this level?
    }

    const bool send_to_rq = (prefetch_as_load || handle_pkt.type != access_type::PREFETCH);
    bool success = send_to_rq ? lower_level->add_rq(mshr_pkt.second) : lower_level->add_pq(mshr_pkt.second);

    if (!success) {
      return false;
    }

    // Allocate an MSHR
    if (mshr_pkt.second.response_requested) {
      MSHR.emplace_back(std::move(mshr_pkt.first));
    }
  }

  if (dir_is_llc)
    dir_on_llc_request(handle_pkt);

  sim_stats.misses.increment(std::pair{handle_pkt.type, handle_pkt.cpu});

  return true;
}

bool CACHE::handle_write(const tag_lookup_type& handle_pkt)
{
  if constexpr (champsim::debug_print) {
    fmt::print("[{}] {} instr_id: {} address: {} v_address: {} type: {} local_prefetch: {} cycle: {}\n", NAME, __func__, handle_pkt.instr_id,
               handle_pkt.address, handle_pkt.v_address, access_type_names.at(champsim::to_underlying(handle_pkt.type)), handle_pkt.prefetch_from_this,
               current_time.time_since_epoch() / clock_period);
  }

  fill_type to_allocate{handle_pkt, current_time};
  to_allocate.data_promise.ready_at(current_time + (warmup ? champsim::chrono::clock::duration{} : FILL_LATENCY));
  inflight_fills.push_back(to_allocate);

  if (dir_is_llc)
    dir_on_llc_request(handle_pkt);

  sim_stats.misses.increment(std::pair{handle_pkt.type, handle_pkt.cpu});

  return true;
}

template <bool UpdateRequest>
auto CACHE::initiate_tag_check(champsim::modules::channel_module* ul)
{
  return [time = current_time + (warmup ? champsim::chrono::clock::duration{} : HIT_LATENCY), ul](const auto& entry) {
    CACHE::tag_lookup_type retval{entry};
    retval.event_cycle = time;

    if constexpr (UpdateRequest) {
      if (entry.response_requested) {
        retval.to_return = {&ul->get_returned()};
      }
    } else {
      (void)ul; // supress warning about ul being unused
    }

    if constexpr (champsim::debug_print) {
      fmt::print("[TAG] initiate_tag_check instr_id: {} address: {} v_address: {} type: {} response_requested: {}\n", retval.instr_id, retval.address,
                 retval.v_address, access_type_names.at(champsim::to_underlying(retval.type)), !std::empty(retval.to_return));
    }

    return retval;
  };
}

long CACHE::operate()
{
  long progress{0};

  auto is_ready = [time = current_time](const auto& entry) {
    return entry.event_cycle <= time;
  };
  auto is_translated = [](const auto& entry) {
    return entry.is_translated;
  };

  // Finish returns
  std::for_each(std::cbegin(lower_level->get_returned()), std::cend(lower_level->get_returned()), [this](const auto& pkt) { this->finish_packet(pkt); });
  progress += std::distance(std::cbegin(lower_level->get_returned()), std::cend(lower_level->get_returned()));
  lower_level->get_returned().clear();

  // Finish translations
  if (lower_translate != nullptr) {
    std::for_each(std::cbegin(lower_translate->get_returned()), std::cend(lower_translate->get_returned()),
                  [this](const auto& pkt) { this->finish_translation(pkt); });
    progress += std::distance(std::cbegin(lower_translate->get_returned()), std::cend(lower_translate->get_returned()));
    lower_translate->get_returned().clear();
  }

  // Perform fills
  champsim::bandwidth fill_bw{MAX_FILL};
  auto [fill_begin, fill_end] = champsim::get_span_p(std::cbegin(inflight_fills), std::cend(inflight_fills), fill_bw,
                                                     [time = current_time](const auto& x) { return x.data_promise.is_ready_at(time); });
  auto complete_end = std::find_if_not(fill_begin, fill_end, [this](const auto& x) { return this->handle_fill(x); });
  fill_bw.consume(std::distance(fill_begin, complete_end));
  inflight_fills.erase(fill_begin, complete_end);

  // Initiate tag checks
  const champsim::bandwidth::maximum_type bandwidth_from_tag_checks{champsim::to_underlying(MAX_TAG) * (long)(HIT_LATENCY / clock_period)
                                                                    - (long)std::size(inflight_tag_check)};
  champsim::bandwidth initiate_tag_bw{std::clamp(bandwidth_from_tag_checks, champsim::bandwidth::maximum_type{0}, MAX_TAG)};
  // Admission throttle: cap in-flight untranslated tag checks at MSHR_SIZE.
  // Counted fresh (not a start-of-cycle snapshot) so the cap tightens as
  // untranslated entries are admitted this cycle. Translated entries and
  // non-translating caches are never throttled. finish_translation re-admits
  // translated entries directly, so there is nothing to pull from the stash here.
  auto can_translate = [this](const auto& entry) {
    return entry.is_translated || lower_translate == nullptr
           || (std::count_if(std::begin(inflight_tag_check), std::end(inflight_tag_check), [](const auto& e) { return !e.is_translated; })
               + static_cast<long>(std::size(translation_stash)))
                  < static_cast<long>(MSHR_SIZE);
  };
  std::vector<long long> channels_bandwidth_consumed{};

  if (std::size(upper_levels) > 1) {
    std::rotate(upper_levels.begin(), upper_levels.begin() + 1, upper_levels.end());
  }

  // upper levels get an equal portion of the remaining bandwidth
  champsim::bandwidth::maximum_type per_upper_bandwidth =
      std::size(upper_levels) >= 1
          ? (champsim::bandwidth::maximum_type)std::max((size_t)initiate_tag_bw.amount_remaining() / std::size(upper_levels), size_t{1})
          : champsim::bandwidth::maximum_type{};

  for (auto* ul : upper_levels) {
    for (auto q : {std::ref(ul->get_wq()), std::ref(ul->get_rq()), std::ref(ul->get_pq())}) {
      // this needs to be in this loop, we need to ensure that for cases where bandwidth doesn't divide nicely across upstreams,
      // we don't accidentally consume more bandwidth than expected
      champsim::bandwidth per_upper_tag_bw{std::min(per_upper_bandwidth, champsim::bandwidth::maximum_type{initiate_tag_bw.amount_remaining()})};
      auto bandwidth_consumed =
          champsim::transform_while_n(q.get(), std::back_inserter(inflight_tag_check), per_upper_tag_bw, can_translate, initiate_tag_check<true>(ul));
      channels_bandwidth_consumed.push_back(bandwidth_consumed);
      initiate_tag_bw.consume(bandwidth_consumed);
    }
  }

  auto pq_bandwidth_consumed =
      champsim::transform_while_n(internal_PQ, std::back_inserter(inflight_tag_check), initiate_tag_bw, can_translate, initiate_tag_check<false>());
  initiate_tag_bw.consume(pq_bandwidth_consumed);

  // Issue translations
  std::for_each(std::begin(inflight_tag_check), std::end(inflight_tag_check), [this](auto& x) { this->issue_translation(x); });
  std::for_each(std::begin(translation_stash), std::end(translation_stash), [this](auto& x) { this->issue_translation(x); });

  // Park EVERY untranslated entry in the stash, not only those already ready.
  // The tag check cannot begin before translation resolves the physical set
  // index, and while parked the entry cannot block translated entries behind it.
  // finish_translation re-admits it, timing the tag check from translation.
  auto [last_not_missed, stash_end] = champsim::extract_if(std::begin(inflight_tag_check), std::end(inflight_tag_check), std::back_inserter(translation_stash),
                                                           [is_translated](const auto& x) { return !is_translated(x); });
  progress += std::distance(last_not_missed, std::end(inflight_tag_check));
  inflight_tag_check.erase(last_not_missed, std::end(inflight_tag_check));

  // C0 (bench/policy_sanity/c0_latency_design_2026-10-14.md): an ownership
  // request that must take its line from other cores waits coherence_latency
  // cycles for the invalidations, then has its tag check. It waits off the tag
  // pipeline, as in a directory's transaction buffer, so the requests behind
  // it go on. Off (0) by default; and never in warm-up, where ChampSim charges
  // no latency at all.
  if (const auto lat = champsim::coherence::coherence_latency(); lat > 0) {
    auto back_begin = std::stable_partition(std::begin(coherence_wait), std::end(coherence_wait), [is_ready](const auto& x) { return !is_ready(x); });
    std::move(back_begin, std::end(coherence_wait), std::back_inserter(inflight_tag_check));
    coherence_wait.erase(back_begin, std::end(coherence_wait));
    if (!warmup) {
      auto must_wait = [this, is_ready, is_translated](const auto& x) {
        return !x.coherence_waited && is_ready(x) && is_translated(x) && this->dir_ownership_wait(x);
      };
      auto wait_begin =
          std::stable_partition(std::begin(inflight_tag_check), std::end(inflight_tag_check), [must_wait](const auto& x) { return !must_wait(x); });
      for (auto it = wait_begin; it != std::end(inflight_tag_check); ++it) {
        it->coherence_waited = true;
        it->event_cycle = current_time + lat * clock_period;
        ++sim_stats.coherence_latency_waits;
      }
      std::move(wait_begin, std::end(inflight_tag_check), std::back_inserter(coherence_wait));
      inflight_tag_check.erase(wait_begin, std::end(inflight_tag_check));
    }
  }

  // Perform tag checks
  auto do_handle_miss = [this](const auto& pkt) {
    if (pkt.type == access_type::WRITE && !this->match_offset_bits) {
      return this->handle_write(pkt); // Treat writes (that is, writebacks) like fills
    }
    return this->handle_miss(pkt); // Treat writes (that is, stores) like reads
  };
  champsim::bandwidth tag_check_bw{MAX_TAG};
  auto [tag_check_ready_begin, tag_check_ready_end] =
      champsim::get_span_p(std::begin(inflight_tag_check), std::end(inflight_tag_check), tag_check_bw,
                           [is_ready, is_translated](const auto& pkt) { return is_ready(pkt) && is_translated(pkt); });
  auto hits_end = std::stable_partition(tag_check_ready_begin, tag_check_ready_end, [this](const auto& pkt) { return this->try_hit(pkt); });
  auto finish_tag_check_end = std::stable_partition(hits_end, tag_check_ready_end, do_handle_miss);
  tag_check_bw.consume(std::distance(tag_check_ready_begin, finish_tag_check_end));
  inflight_tag_check.erase(tag_check_ready_begin, finish_tag_check_end);

  impl_prefetcher_cycle_operate();

  if constexpr (champsim::debug_print) {
    fmt::print("[{}] {} cycle completed: {} tags checked: {} remaining: {} stash remaining: {} channel consumed: {} pq consumed {} unused consume "
               "bw {}\n",
               NAME, __func__, current_time.time_since_epoch() / clock_period, tag_check_bw.amount_consumed(), std::size(inflight_tag_check),
               std::size(translation_stash), channels_bandwidth_consumed, pq_bandwidth_consumed, initiate_tag_bw.amount_remaining());
  }

  return progress + fill_bw.amount_consumed() + initiate_tag_bw.amount_consumed() + tag_check_bw.amount_consumed();
}

// LCOV_EXCL_START exclude deprecated function
uint64_t CACHE::get_set(uint64_t address) const { return static_cast<uint64_t>(get_set_index(champsim::address{address})); }
// LCOV_EXCL_STOP

long CACHE::get_set_index(champsim::address address) const { return address.slice(champsim::dynamic_extent{OFFSET_BITS, champsim::lg2(NUM_SET)}).to<long>(); }

template <typename It>
std::pair<It, It> get_span(It anchor, typename std::iterator_traits<It>::difference_type set_idx, typename std::iterator_traits<It>::difference_type num_way)
{
  auto begin = std::next(anchor, set_idx * num_way);
  return {std::move(begin), std::next(begin, num_way)};
}

auto CACHE::get_set_span(champsim::address address) -> std::pair<set_type::iterator, set_type::iterator>
{
  const auto set_idx = get_set_index(address);
  assert(set_idx < NUM_SET);
  return get_span(std::begin(block), static_cast<set_type::difference_type>(set_idx), NUM_WAY); // safe cast because of prior assert
}

auto CACHE::get_set_span(champsim::address address) const -> std::pair<set_type::const_iterator, set_type::const_iterator>
{
  const auto set_idx = get_set_index(address);
  assert(set_idx < NUM_SET);
  return get_span(std::cbegin(block), static_cast<set_type::difference_type>(set_idx), NUM_WAY); // safe cast because of prior assert
}

// LCOV_EXCL_START exclude deprecated function
uint64_t CACHE::get_way(uint64_t address, uint64_t /*unused set index*/) const
{
  champsim::address intern_addr{address};
  auto [begin, end] = get_set_span(intern_addr);
  return static_cast<uint64_t>(std::distance(begin, std::find_if(begin, end, matches_address(champsim::address{address}))));
}
// LCOV_EXCL_STOP

long CACHE::invalidate_entry(champsim::address inval_addr)
{
  auto [begin, end] = get_set_span(inval_addr);
  auto inv_way = std::find_if(begin, end, matches_address(inval_addr));

  if (inv_way != end) {
    if (dir_cpu >= 0 && inv_way->valid)
      champsim::coherence::dir_evict(dir_line(inv_way->address), static_cast<unsigned>(dir_cpu), static_cast<unsigned>(dir_level));
    if (dir_is_llc && inv_way->valid)
      champsim::coherence::dir_llc_evict(dir_line(inv_way->address));
    inv_way->valid = false;
  }

  return std::distance(begin, inv_way);
}

// B3 v2 sharer directory: one request reaching the LLC (counted once).
void CACHE::dir_on_llc_request(const tag_lookup_type& pkt)
{
  using champsim::coherence::dir_req;
  const dir_req kind = pkt.type == access_type::RFO ? dir_req::store : (pkt.type == access_type::WRITE ? dir_req::writeback : dir_req::read);
  const auto r = champsim::coherence::dir_llc_request(dir_line(pkt.address), pkt.cpu, kind);
  dir_log_event(kind == dir_req::store ? 'G' : (kind == dir_req::read ? 'L' : 'W'), pkt, r.protocol_others, r.presence_others, r.g5_others);
  if (kind != dir_req::store)
    return;
  if (r.presence_others != 0) {
    ++sim_stats.coherence_dir_rfo_presence_events;
    sim_stats.coherence_dir_rfo_presence_others += static_cast<uint64_t>(__builtin_popcount(r.presence_others));
  }
  if (r.protocol_others != 0) {
    ++sim_stats.coherence_dir_rfo_protocol_events;
    sim_stats.coherence_dir_rfo_protocol_others += static_cast<uint64_t>(__builtin_popcount(r.protocol_others));
  }
  if (r.bounded_others != 0)
    ++sim_stats.coherence_dir_rfo_bounded_events; // diagnosis: the bounded view
  if (r.g5_others != 0) { // step 3: the gem5-rule view
    ++sim_stats.coherence_dir_rfo_g5_events;
    sim_stats.coherence_dir_rfo_g5_cores += static_cast<uint64_t>(__builtin_popcount(r.g5_others));
  }
}

// C0: would this request take its line from other cores? The same cases that
// invalidate copies at level 2: a store miss (RFO) at the LLC, and a store or
// RFO that hits a private copy (the upgrade, decided where it hits; a miss
// goes on and is decided at the next level). Other holders by either view, as
// the invalidation itself uses. Reads the directory, changes nothing.
bool CACHE::dir_ownership_wait(const tag_lookup_type& pkt) const
{
  using champsim::coherence::dir_peek;
  if (champsim::coherence::private_coherence() < 2)
    return false;
  if (dir_is_llc) {
    if (pkt.type != access_type::RFO)
      return false;
    const auto r = dir_peek(dir_line(pkt.address), pkt.cpu);
    return (r.protocol_others | r.presence_others) != 0;
  }
  if (dir_cpu < 0 || !(pkt.type == access_type::RFO || (pkt.type == access_type::WRITE && dir_level == 1)))
    return false;
  auto [set_begin, set_end] = get_set_span(pkt.address);
  if (std::none_of(set_begin, set_end, [matcher = matches_address(pkt.address)](const auto& x) { return x.valid && matcher(x); }))
    return false;
  const auto r = dir_peek(dir_line(pkt.address), static_cast<unsigned>(dir_cpu));
  return (r.protocol_others | r.presence_others) != 0;
}

// B3 v4, private_coherence 2: an ownership access that hit this private cache.
void CACHE::dir_on_private_ownership_hit(const tag_lookup_type& pkt)
{
  const auto r = champsim::coherence::dir_private_ownership_hit(dir_line(pkt.address), static_cast<unsigned>(dir_cpu));
  if (r.protocol_others != 0 || r.presence_others != 0)
    dir_log_event('U', pkt, r.protocol_others, r.presence_others, r.g5_others);
  if (r.protocol_others != 0) {
    ++sim_stats.coherence_dir_upgrade_events;
    sim_stats.coherence_dir_upgrade_cores += static_cast<uint64_t>(__builtin_popcount(r.protocol_others));
  }
  if (r.presence_others != 0)
    ++sim_stats.coherence_dir_upgrade_presence_events;
  if (r.bounded_others != 0)
    ++sim_stats.coherence_dir_upgrade_bounded_events; // diagnosis: the bounded view
  if (r.g5_others != 0) { // step 3: the gem5-rule view
    ++sim_stats.coherence_dir_upgrade_g5_events;
    sim_stats.coherence_dir_upgrade_g5_cores += static_cast<uint64_t>(__builtin_popcount(r.g5_others));
  }
  if (r.g5_relisted) // amendment 2: a silent re-listing
    ++sim_stats.coherence_dir_upgrade_g5_silent;
}

// B3 v4: another core has taken this line (called through the directory).
// Drop this private cache's copy. A dirty copy goes without a writeback: the
// new owner holds the newer data.
void CACHE::dir_invalidate_line(uint64_t line)
{
  const champsim::address addr{line << champsim::to_underlying(OFFSET_BITS)};
  auto [begin, end] = get_set_span(addr);
  auto way = std::find_if(begin, end, [matcher = matches_address(addr)](const auto& x) { return x.valid && matcher(x); });
  if (way == end)
    return;
  champsim::coherence::dir_evict(line, static_cast<unsigned>(dir_cpu), static_cast<unsigned>(dir_level));
  if (auto* f = champsim::coherence::dir_event_log())
    fmt::print(f, "I {} {} {} {} 0 0 0 {:x} {} 0 0\n", NAME, current_time.time_since_epoch() / clock_period, warmup ? 1 : 0, dir_cpu, line, way->dirty ? 1 : 0);
  way->valid = false;
  ++sim_stats.coherence_dir_copies_invalidated;
}

// One line of the diagnostic event log (sharer_directory.h); off unless asked
// for. kind: L, G, W -- a load, RFO or writeback accepted at the LLC; U -- an
// upgrade; S -- a stale fill dropped. (I, a private copy invalidated, is
// written by dir_invalidate_line, before the G or U line that caused it.)
//   kind cache cycle warmup cpu instr_id ip v_line line type protocol_others presence_others g5_others
// (g5_others, the gem5-rule view, since 2026-10-19: readers take 12 fields or more)
template <typename T>
void CACHE::dir_log_event(char kind, const T& pkt, uint32_t protocol_others, uint32_t presence_others, uint32_t g5_others) const
{
  auto* f = champsim::coherence::dir_event_log();
  if (f == nullptr)
    return;
  fmt::print(f, "{} {} {} {} {} {} {:x} {:x} {:x} {} {:x} {:x} {:x}\n", kind, NAME, current_time.time_since_epoch() / clock_period, warmup ? 1 : 0, pkt.cpu,
             pkt.instr_id, pkt.ip.template to<uint64_t>(), dir_line(pkt.v_address), dir_line(pkt.address), access_type_names.at(champsim::to_underlying(pkt.type)),
             protocol_others, presence_others, g5_others);
}

// Synchronised replay (sync_replay.h): does a store from this L1D's core
// still wait anywhere here -- in the channel from the core, the tag pipeline,
// translation, a C0 wait, or a miss in flight?
bool CACHE::has_pending_writes() const
{
  auto is_write = [](const auto& x) { return x.type == access_type::WRITE; };
  for (auto* ul : upper_levels)
    if (!std::empty(ul->get_wq()))
      return true;
  return std::any_of(std::begin(inflight_tag_check), std::end(inflight_tag_check), is_write)
         || std::any_of(std::begin(translation_stash), std::end(translation_stash), is_write)
         || std::any_of(std::begin(coherence_wait), std::end(coherence_wait), is_write)
         || std::any_of(std::begin(MSHR), std::end(MSHR), is_write) || std::any_of(std::begin(inflight_fills), std::end(inflight_fills), is_write);
}

// B3 v2 self-check, at the end of each phase. A private cache's valid blocks
// must be exactly the lines the directory marks present for it: every block
// marked, and no more marks than blocks. Written to both stats blocks, since
// the printer shows both and extraction reads the first.
void CACHE::dir_selfcheck()
{
  if (dir_is_llc) {
    sim_stats.coherence_dir_registered = roi_stats.coherence_dir_registered = champsim::coherence::dir_registered_private_caches();
    sim_stats.coherence_dir_stale_holders = roi_stats.coherence_dir_stale_holders = champsim::coherence::dir_count_stale_holders();
    sim_stats.coherence_dir_view_order_violations = roi_stats.coherence_dir_view_order_violations
        = champsim::coherence::dir_count_view_order_violations();
    sim_stats.coherence_dir_view_order_by_silent = roi_stats.coherence_dir_view_order_by_silent
        = champsim::coherence::dir_count_view_order_by_silent_relisting();
    sim_stats.coherence_dir_view_order_unexplained = roi_stats.coherence_dir_view_order_unexplained
        = sim_stats.coherence_dir_view_order_violations - sim_stats.coherence_dir_view_order_by_silent;
  }
  if (dir_cpu < 0)
    return;
  uint64_t valid = 0, unmarked = 0;
  for (const auto& b : block) {
    if (!b.valid)
      continue;
    ++valid;
    if (!champsim::coherence::dir_present(dir_line(b.address), static_cast<unsigned>(dir_cpu), static_cast<unsigned>(dir_level)))
      ++unmarked;
  }
  const uint64_t marked = champsim::coherence::dir_count_present(static_cast<unsigned>(dir_cpu), static_cast<unsigned>(dir_level));
  // marked blocks vs marks: more marks = a stale mark; more marked blocks than
  // marks = the same line held twice in this cache. Either is a mismatch.
  const uint64_t marked_blocks = valid - unmarked;
  const uint64_t skew = marked > marked_blocks ? marked - marked_blocks : marked_blocks - marked;
  sim_stats.coherence_dir_selfcheck_mismatches = roi_stats.coherence_dir_selfcheck_mismatches = unmarked + skew;
}

bool CACHE::prefetch_line(champsim::address pf_addr, bool fill_this_level, uint32_t prefetch_metadata)
{
  ++sim_stats.pf_requested;

  if (std::size(internal_PQ) >= PQ_SIZE) {
    return false;
  }

  request_type pf_packet;
  pf_packet.type = access_type::PREFETCH;
  pf_packet.pf_metadata = prefetch_metadata;
  pf_packet.cpu = cpu;
  pf_packet.address = pf_addr;
  pf_packet.v_address = virtual_prefetch ? pf_addr : champsim::address{};
  pf_packet.is_translated = !virtual_prefetch;

  internal_PQ.emplace_back(pf_packet, true, !fill_this_level);
  ++sim_stats.pf_issued;

  return true;
}

// LCOV_EXCL_START exclude deprecated function
bool CACHE::prefetch_line(uint64_t pf_addr, bool fill_this_level, uint32_t prefetch_metadata)
{
  return prefetch_line(champsim::address{pf_addr}, fill_this_level, prefetch_metadata);
}

bool CACHE::prefetch_line(uint64_t /*deprecated*/, uint64_t /*deprecated*/, uint64_t pf_addr, bool fill_this_level, uint32_t prefetch_metadata)
{
  return prefetch_line(champsim::address{pf_addr}, fill_this_level, prefetch_metadata);
}
// LCOV_EXCL_STOP

void CACHE::finish_packet(const response_type& packet)
{
  // check MSHR information
  auto mshr_entry = std::find_if(std::begin(MSHR), std::end(MSHR), matches_address(packet.address));

  // sanity check
  if (mshr_entry == MSHR.end()) {
    fmt::print(stderr, "[{}_MSHR] {} cannot find a matching entry! address: {} v_address: {}\n", NAME, __func__, packet.address, packet.v_address);
    assert(0);
  }

  // MSHR holds the most updated information about this request
  fill_type::returned_value finished_value{packet.data, packet.pf_metadata};
  mshr_entry->data_promise = champsim::waitable{finished_value, current_time + (warmup ? champsim::chrono::clock::duration{} : FILL_LATENCY)};
  if constexpr (champsim::debug_print) {
    fmt::print("[{}_MSHR] finish_packet instr_id: {} address: {} data: {} type: {} current: {}\n", this->NAME, mshr_entry->instr_id, mshr_entry->address,
               mshr_entry->data_promise->data, access_type_names.at(champsim::to_underlying(mshr_entry->type)), current_time.time_since_epoch() / clock_period);
  }

  std::iter_swap(mshr_entry, std::begin(MSHR));
  inflight_fills.push_back(MSHR.front());
  MSHR.pop_front();
}

void CACHE::finish_translation(const response_type& packet)
{
  auto matches_vpage = [page_num = champsim::page_number{packet.v_address}](const auto& entry) {
    return (champsim::page_number{entry.v_address} == page_num) && !entry.is_translated;
  };
  // A physically-indexed tag check cannot begin until translation resolves the
  // physical set index, so time it from translation completion, not admission.
  const auto tag_check_ready = current_time + (warmup ? champsim::chrono::clock::duration{} : HIT_LATENCY);
  auto mark_translated = [p_page = champsim::page_number{packet.data}, tag_check_ready, this](auto& entry) {
    [[maybe_unused]] auto old_address = entry.address;
    entry.address = champsim::address{champsim::splice(p_page, champsim::page_offset{entry.v_address})}; // translated address
    entry.is_translated = true;                                                                          // This entry is now translated
    entry.event_cycle = tag_check_ready;                                                                 // serialize: tag check waits for translation

    if constexpr (champsim::debug_print) {
      fmt::print("[{}_TRANSLATE] finish_translation old: {} paddr: {} vaddr: {} type: {} cycle: {}\n", this->NAME, old_address, entry.address, entry.v_address,
                 access_type_names.at(champsim::to_underlying(entry.type)), this->current_time.time_since_epoch() / this->clock_period);
    }
  };

  // Move every stash entry whose translation just resolved into the timed
  // tag-check pipeline. Re-admission happens here, not in operate(), so it does
  // not compete for tag-check bandwidth with newly-admitted entries. Every
  // untranslated entry is parked, so inflight_tag_check holds only translated
  // entries and there is nothing left to mark there.
  auto matched_end = std::stable_partition(std::begin(translation_stash), std::end(translation_stash), matches_vpage);
  std::for_each(std::begin(translation_stash), matched_end, [&](auto& entry) {
    mark_translated(entry);
    inflight_tag_check.push_back(std::move(entry));
  });
  translation_stash.erase(std::begin(translation_stash), matched_end);
}

void CACHE::issue_translation(tag_lookup_type& q_entry) const
{
  if (!q_entry.translate_issued && !q_entry.is_translated) {
    request_type fwd_pkt;
    fwd_pkt.asid[0] = q_entry.asid[0];
    fwd_pkt.asid[1] = q_entry.asid[1];
    fwd_pkt.type = access_type::LOAD;
    fwd_pkt.cpu = q_entry.cpu;

    fwd_pkt.address = q_entry.address;
    fwd_pkt.v_address = q_entry.v_address;
    fwd_pkt.data = q_entry.data;
    fwd_pkt.instr_id = q_entry.instr_id;
    fwd_pkt.ip = q_entry.ip;

    fwd_pkt.instr_depend_on_me = q_entry.instr_depend_on_me;
    fwd_pkt.is_translated = true;

    q_entry.translate_issued = lower_translate->add_rq(fwd_pkt);
    if constexpr (champsim::debug_print) {
      if (q_entry.translate_issued) {
        fmt::print("[TRANSLATE] do_issue_translation instr_id: {} paddr: {} vaddr: {} type: {}\n", q_entry.instr_id, q_entry.address, q_entry.v_address,
                   access_type_names.at(champsim::to_underlying(q_entry.type)));
      }
    }
  }
}

std::size_t CACHE::get_mshr_occupancy() const { return std::size(MSHR); }

std::vector<std::size_t> CACHE::get_rq_occupancy() const
{
  std::vector<std::size_t> retval;
  std::transform(std::begin(upper_levels), std::end(upper_levels), std::back_inserter(retval), [](auto ulptr) { return ulptr->rq_occupancy(); });
  return retval;
}

std::vector<std::size_t> CACHE::get_wq_occupancy() const
{
  std::vector<std::size_t> retval;
  std::transform(std::begin(upper_levels), std::end(upper_levels), std::back_inserter(retval), [](auto ulptr) { return ulptr->wq_occupancy(); });
  return retval;
}

std::vector<std::size_t> CACHE::get_pq_occupancy() const
{
  std::vector<std::size_t> retval;
  std::transform(std::begin(upper_levels), std::end(upper_levels), std::back_inserter(retval), [](auto ulptr) { return ulptr->pq_occupancy(); });
  retval.push_back(std::size(internal_PQ));
  return retval;
}

// LCOV_EXCL_START exclude deprecated function
std::size_t CACHE::get_occupancy(uint8_t queue_type, uint64_t /*deprecated*/) const
{
  if (queue_type == 0) {
    return get_mshr_occupancy();
  }
  return 0;
}

std::size_t CACHE::get_occupancy(uint8_t queue_type, champsim::address /*deprecated*/) const
{
  if (queue_type == 0) {
    return get_mshr_occupancy();
  }
  return 0;
}
// LCOV_EXCL_STOP

std::size_t CACHE::get_mshr_size() const { return MSHR_SIZE; }
std::vector<std::size_t> CACHE::get_rq_size() const
{
  std::vector<std::size_t> retval;
  std::transform(std::begin(upper_levels), std::end(upper_levels), std::back_inserter(retval), [](auto ulptr) { return ulptr->rq_size(); });
  return retval;
}

std::vector<std::size_t> CACHE::get_wq_size() const
{
  std::vector<std::size_t> retval;
  std::transform(std::begin(upper_levels), std::end(upper_levels), std::back_inserter(retval), [](auto ulptr) { return ulptr->wq_size(); });
  return retval;
}

std::vector<std::size_t> CACHE::get_pq_size() const
{
  std::vector<std::size_t> retval;
  std::transform(std::begin(upper_levels), std::end(upper_levels), std::back_inserter(retval), [](auto ulptr) { return ulptr->pq_size(); });
  retval.push_back(PQ_SIZE);
  return retval;
}

// LCOV_EXCL_START exclude deprecated function
std::size_t CACHE::get_size(uint8_t queue_type, champsim::address /*deprecated*/) const
{
  if (queue_type == 0) {
    return get_mshr_size();
  }
  return 0;
}

std::size_t CACHE::get_size(uint8_t queue_type, uint64_t /*deprecated*/) const
{
  if (queue_type == 0) {
    return get_mshr_size();
  }
  return 0;
}
// LCOV_EXCL_STOP

namespace
{
double occupancy_ratio(std::size_t occ, std::size_t sz) { return std::ceil(occ) / std::ceil(sz); }

std::vector<double> occupancy_ratio_vec(std::vector<std::size_t> occ, std::vector<std::size_t> sz)
{
  std::vector<double> retval;
  std::transform(std::begin(occ), std::end(occ), std::begin(sz), std::back_inserter(retval), occupancy_ratio);
  return retval;
}
} // namespace

double CACHE::get_mshr_occupancy_ratio() const { return ::occupancy_ratio(get_mshr_occupancy(), get_mshr_size()); }

std::vector<double> CACHE::get_rq_occupancy_ratio() const { return ::occupancy_ratio_vec(get_rq_occupancy(), get_rq_size()); }

std::vector<double> CACHE::get_wq_occupancy_ratio() const { return ::occupancy_ratio_vec(get_wq_occupancy(), get_wq_size()); }

std::vector<double> CACHE::get_pq_occupancy_ratio() const { return ::occupancy_ratio_vec(get_pq_occupancy(), get_pq_size()); }

void CACHE::impl_prefetcher_initialize() const
{
  std::for_each(pref_module_pimpl.begin(), pref_module_pimpl.end(), [](const auto pref) { pref->prefetcher_initialize(); });
}

uint32_t CACHE::impl_prefetcher_cache_operate(champsim::address addr, champsim::address ip, bool cache_hit, bool useful_prefetch, access_type type,
                                              uint32_t metadata_in) const
{
  uint32_t metadata_out = metadata_in;
  std::for_each(pref_module_pimpl.begin(), pref_module_pimpl.end(),
                [&](const auto pref) { metadata_out = pref->prefetcher_cache_operate(addr, ip, cache_hit, useful_prefetch, type, metadata_out); });
  return (metadata_out);
}

uint32_t CACHE::impl_prefetcher_cache_fill(champsim::address addr, long set, long way, bool prefetch, champsim::address evicted_addr,
                                           uint32_t metadata_in) const
{
  uint32_t metadata_out = metadata_in;
  std::for_each(pref_module_pimpl.begin(), pref_module_pimpl.end(),
                [&](const auto pref) { metadata_out = pref->prefetcher_cache_fill(addr, set, way, prefetch, evicted_addr, metadata_out); });
  return (metadata_out);
}

void CACHE::impl_prefetcher_cycle_operate() const
{
  std::for_each(pref_module_pimpl.begin(), pref_module_pimpl.end(), [](const auto pref) { pref->prefetcher_cycle_operate(); });
}

void CACHE::impl_prefetcher_final_stats() const
{
  std::for_each(pref_module_pimpl.begin(), pref_module_pimpl.end(), [](const auto pref) { pref->prefetcher_final_stats(); });
}

void CACHE::impl_prefetcher_branch_operate(champsim::address ip, uint8_t branch_type, champsim::address branch_target) const
{
  std::for_each(pref_module_pimpl.begin(), pref_module_pimpl.end(), [&](const auto pref) { pref->prefetcher_branch_operate(ip, branch_type, branch_target); });
}

void CACHE::impl_initialize_replacement() const
{
  std::for_each(repl_module_pimpl.begin(), repl_module_pimpl.end(), [](const auto repl) { repl->initialize_replacement(); });
}

long CACHE::impl_find_victim(uint32_t triggering_cpu, uint64_t instr_id, long set, const BLOCK* current_set, champsim::address ip, champsim::address full_addr,
                             access_type type) const
{
  long victim = -1;

  std::for_each(repl_module_pimpl.begin(), repl_module_pimpl.end(), [&](const auto repl) {
    long temp_victim = repl->find_victim(triggering_cpu, instr_id, set, current_set, ip, full_addr, type);
    if (temp_victim != -1)
      victim = temp_victim;
  });

  assert(victim >= 0);
  return (victim);
}

void CACHE::impl_update_replacement_state(uint32_t triggering_cpu, long set, long way, champsim::address full_addr, champsim::address ip,
                                          champsim::address victim_addr, access_type type, bool hit) const
{
  std::for_each(repl_module_pimpl.begin(), repl_module_pimpl.end(),
                [&](const auto repl) { repl->update_replacement_state(triggering_cpu, set, way, full_addr, ip, victim_addr, type, hit); });
}

void CACHE::impl_replacement_cache_fill(uint32_t triggering_cpu, long set, long way, champsim::address full_addr, champsim::address ip,
                                        champsim::address victim_addr, access_type type) const
{
  std::for_each(repl_module_pimpl.begin(), repl_module_pimpl.end(),
                [&](const auto repl) { repl->replacement_cache_fill(triggering_cpu, set, way, full_addr, ip, victim_addr, type); });
}

void CACHE::impl_replacement_final_stats() const
{
  std::for_each(repl_module_pimpl.begin(), repl_module_pimpl.end(), [](const auto repl) { repl->replacement_final_stats(); });
}

void CACHE::initialize()
{
  impl_prefetcher_initialize();
  impl_initialize_replacement();
}

void CACHE::begin_phase()
{
  stats_type new_roi_stats;
  stats_type new_sim_stats;

  new_roi_stats.name = NAME;
  new_sim_stats.name = NAME;

  roi_stats = new_roi_stats;
  sim_stats = new_sim_stats;

  for (auto* ul : upper_levels) {
    channel_type::stats_type ul_new_roi_stats;
    channel_type::stats_type ul_new_sim_stats;
    ul->get_roi_stats() = ul_new_roi_stats;
    ul->get_sim_stats() = ul_new_sim_stats;
  }
}

void CACHE::end_phase(unsigned finished_cpu)
{
  finished_cpu = finished_cpu;
  roi_stats.total_miss_latency_cycles = sim_stats.total_miss_latency_cycles;

  roi_stats.coherence_invalidations = sim_stats.coherence_invalidations;
  roi_stats.coherence_write_hit_other_sharer_events = sim_stats.coherence_write_hit_other_sharer_events;
  roi_stats.coherence_rfo_hit_other_sharer_events = sim_stats.coherence_rfo_hit_other_sharer_events;
  roi_stats.coherence_rfo_hit_other_sharers = sim_stats.coherence_rfo_hit_other_sharers;
  roi_stats.coherence_dir_rfo_presence_events = sim_stats.coherence_dir_rfo_presence_events;
  roi_stats.coherence_dir_rfo_presence_others = sim_stats.coherence_dir_rfo_presence_others;
  roi_stats.coherence_dir_rfo_protocol_events = sim_stats.coherence_dir_rfo_protocol_events;
  roi_stats.coherence_dir_rfo_protocol_others = sim_stats.coherence_dir_rfo_protocol_others;
  roi_stats.coherence_dir_copies_invalidated = sim_stats.coherence_dir_copies_invalidated;
  roi_stats.coherence_dir_upgrade_events = sim_stats.coherence_dir_upgrade_events;
  roi_stats.coherence_dir_upgrade_cores = sim_stats.coherence_dir_upgrade_cores;
  roi_stats.coherence_dir_upgrade_presence_events = sim_stats.coherence_dir_upgrade_presence_events;
  roi_stats.coherence_latency_waits = sim_stats.coherence_latency_waits;
  roi_stats.coherence_dir_rfo_bounded_events = sim_stats.coherence_dir_rfo_bounded_events;
  roi_stats.coherence_dir_upgrade_bounded_events = sim_stats.coherence_dir_upgrade_bounded_events;
  roi_stats.coherence_dir_rfo_g5_events = sim_stats.coherence_dir_rfo_g5_events;
  roi_stats.coherence_dir_rfo_g5_cores = sim_stats.coherence_dir_rfo_g5_cores;
  roi_stats.coherence_dir_upgrade_g5_events = sim_stats.coherence_dir_upgrade_g5_events;
  roi_stats.coherence_dir_upgrade_g5_cores = sim_stats.coherence_dir_upgrade_g5_cores;
  roi_stats.coherence_dir_upgrade_g5_silent = sim_stats.coherence_dir_upgrade_g5_silent;
  roi_stats.coherence_dir_stale_fills = sim_stats.coherence_dir_stale_fills;
  dir_selfcheck();
  std::copy(std::begin(sim_stats.coherence_sharer_hist), std::end(sim_stats.coherence_sharer_hist), std::begin(roi_stats.coherence_sharer_hist));

  roi_stats.hits = sim_stats.hits;
  roi_stats.misses = sim_stats.misses;
  roi_stats.miss_merge = sim_stats.miss_merge;
  roi_stats.fill = sim_stats.fill;

  roi_stats.pf_requested = sim_stats.pf_requested;
  roi_stats.pf_issued = sim_stats.pf_issued;
  roi_stats.pf_useful = sim_stats.pf_useful;
  roi_stats.pf_useless = sim_stats.pf_useless;
  roi_stats.pf_fill = sim_stats.pf_fill;

  for (auto* ul : upper_levels) {
    ul->get_roi_stats().RQ_ACCESS = ul->get_sim_stats().RQ_ACCESS;
    ul->get_roi_stats().RQ_FULL = ul->get_sim_stats().RQ_FULL;
    ul->get_roi_stats().RQ_TO_CACHE = ul->get_sim_stats().RQ_TO_CACHE;

    ul->get_roi_stats().PQ_ACCESS = ul->get_sim_stats().PQ_ACCESS;
    ul->get_roi_stats().PQ_FULL = ul->get_sim_stats().PQ_FULL;
    ul->get_roi_stats().PQ_TO_CACHE = ul->get_sim_stats().PQ_TO_CACHE;

    ul->get_roi_stats().WQ_ACCESS = ul->get_sim_stats().WQ_ACCESS;
    ul->get_roi_stats().WQ_FULL = ul->get_sim_stats().WQ_FULL;
    ul->get_roi_stats().WQ_TO_CACHE = ul->get_sim_stats().WQ_TO_CACHE;
  }
}

void CACHE::end_simulation()
{
  impl_prefetcher_final_stats();
  impl_replacement_final_stats();
}

template <typename T>
bool CACHE::should_activate_prefetcher(const T& pkt) const
{
  return !pkt.prefetch_from_this && std::count(std::begin(pref_activate_mask), std::end(pref_activate_mask), pkt.type) > 0;
}

// LCOV_EXCL_START Exclude the following function from LCOV
void CACHE::print_deadlock()
{
  std::string_view mshr_write{"instr_id: {} address: {} v_addr: {} type: {} ready: {}"};
  auto mshr_pack = [time = current_time](const auto& entry) {
    return std::tuple{entry.instr_id, entry.address, entry.v_address, access_type_names.at(champsim::to_underlying(entry.type)),
                      entry.data_promise.is_ready_at(time)};
  };

  std::string_view tag_check_write{"instr_id: {} address: {} v_addr: {} is_translated: {} translate_issued: {} event_cycle: {}"};
  auto tag_check_pack = [period = clock_period](const auto& entry) {
    return std::tuple{entry.instr_id,      entry.address,          entry.v_address,
                      entry.is_translated, entry.translate_issued, entry.event_cycle.time_since_epoch() / period};
  };

  champsim::range_print_deadlock(MSHR, NAME + "_MSHR", mshr_write, mshr_pack);
  champsim::range_print_deadlock(inflight_tag_check, NAME + "_tags", tag_check_write, tag_check_pack);
  champsim::range_print_deadlock(translation_stash, NAME + "_translation", tag_check_write, tag_check_pack);

  std::string_view q_writer{"instr_id: {} address: {} v_addr: {} type: {} translated: {}"};
  auto q_entry_pack = [](const auto& entry) {
    return std::tuple{entry.instr_id, entry.address, entry.v_address, access_type_names.at(champsim::to_underlying(entry.type)), entry.is_translated};
  };

  for (auto* ul : upper_levels) {
    champsim::range_print_deadlock(ul->get_rq(), NAME + "_RQ", q_writer, q_entry_pack);
    champsim::range_print_deadlock(ul->get_wq(), NAME + "_WQ", q_writer, q_entry_pack);
    champsim::range_print_deadlock(ul->get_pq(), NAME + "_PQ", q_writer, q_entry_pack);
  }
}
// LCOV_EXCL_STOP

champsim::modules::cache_module::register_module<CACHE> default_cache_module("DEFAULT_CACHE");