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

#include <cmath>
#include <numeric>
#include <ratio>
#include <string_view> // for string_view
#include <utility>
#include <vector>
#include <fmt/chrono.h>
#include <fmt/core.h>
#include <fmt/ostream.h>

#include "stats_printer.h"
#include "sharer_directory.h" // C0: the latency, to print its counter only when set

namespace
{
template <typename N, typename D>
auto print_ratio(N num, D denom)
{
  if (denom > 0) {
    return fmt::format("{:.4g}", std::ceil(num) / std::ceil(denom));
  }
  return std::string{"-"};
}
} // namespace

std::vector<std::string> champsim::plain_printer::format(champsim::modules::core_module::stats_type stats)
{
  constexpr std::array types{branch_type::BRANCH_DIRECT_JUMP, branch_type::BRANCH_INDIRECT,      branch_type::BRANCH_CONDITIONAL,
                             branch_type::BRANCH_DIRECT_CALL, branch_type::BRANCH_INDIRECT_CALL, branch_type::BRANCH_RETURN};
  auto total_branch = std::ceil(
      std::accumulate(std::begin(types), std::end(types), 0LL, [tbt = stats.total_branch_types](auto acc, auto next) { return acc + tbt.value_or(next, 0); }));
  auto total_mispredictions = std::ceil(
      std::accumulate(std::begin(types), std::end(types), 0LL, [btm = stats.branch_type_misses](auto acc, auto next) { return acc + btm.value_or(next, 0); }));

  std::vector<std::string> lines{};
  lines.push_back(fmt::format("{} cumulative IPC: {} instructions: {} cycles: {}", stats.name, ::print_ratio(stats.instrs(), stats.cycles()), stats.instrs(),
                              stats.cycles()));

  lines.push_back(fmt::format("{} Branch Prediction Accuracy: {}% MPKI: {} Average ROB Occupancy at Mispredict: {}", stats.name,
                              ::print_ratio(100 * (total_branch - total_mispredictions), total_branch),
                              ::print_ratio(std::kilo::num * total_mispredictions, stats.instrs()),
                              ::print_ratio(stats.total_rob_occupancy_at_branch_mispredict, total_mispredictions)));
  lines.push_back(fmt::format("{} RMW LOADS ISSUED AS RFO: {}", stats.name, stats.rmw_loads_as_rfo));
  lines.push_back(fmt::format("{} RMW LOADS FORWARDED FROM THE STORE QUEUE: {}", stats.name, stats.rmw_loads_forwarded));

  lines.emplace_back("Branch type MPKI");
  for (auto idx : types) {
    lines.push_back(fmt::format("{}: {}", branch_type_names.at(champsim::to_underlying(idx)),
                                ::print_ratio(std::kilo::num * stats.branch_type_misses.value_or(idx, 0), stats.instrs())));
  }

  return lines;
}

std::vector<std::string> champsim::plain_printer::format(champsim::modules::cache_module::stats_type stats)
{
  using hits_value_type = typename decltype(stats.hits)::value_type;
  using misses_value_type = typename decltype(stats.misses)::value_type;
  using miss_merge_value_type = typename decltype(stats.miss_merge)::value_type;
  using fill_value_type = typename decltype(stats.fill)::value_type;

  std::vector<std::size_t> cpus;

  // build a vector of all existing cpus
  auto stat_keys = {stats.hits.get_keys(), stats.misses.get_keys(), stats.miss_merge.get_keys(), stats.fill.get_keys()};
  for (auto keys : stat_keys) {
    std::transform(std::begin(keys), std::end(keys), std::back_inserter(cpus), [](auto val) { return val.second; });
  }
  std::sort(std::begin(cpus), std::end(cpus));
  auto uniq_end = std::unique(std::begin(cpus), std::end(cpus));
  cpus.erase(uniq_end, std::end(cpus));

  for (const auto type : {access_type::LOAD, access_type::RFO, access_type::PREFETCH, access_type::WRITE, access_type::TRANSLATION}) {
    for (auto cpu : cpus) {
      stats.hits.allocate(std::pair{type, cpu});
      stats.misses.allocate(std::pair{type, cpu});
      stats.miss_merge.allocate(std::pair{type, cpu});
      stats.fill.allocate(std::pair{type, cpu});
    }
  }

  std::vector<std::string> lines{};
  for (auto cpu : cpus) {
    hits_value_type total_hits = 0;
    misses_value_type total_misses = 0;
    miss_merge_value_type total_miss_merge = 0;
    fill_value_type total_fill = 0;
    for (const auto type : {access_type::LOAD, access_type::RFO, access_type::PREFETCH, access_type::WRITE, access_type::TRANSLATION}) {
      total_hits += stats.hits.value_or(std::pair{type, cpu}, hits_value_type{});
      total_misses += stats.misses.value_or(std::pair{type, cpu}, misses_value_type{});
      total_miss_merge += stats.miss_merge.value_or(std::pair{type, cpu}, miss_merge_value_type{});
      total_fill += stats.fill.value_or(std::pair{type, cpu}, miss_merge_value_type{});
    }

    fmt::format_string<std::string_view, std::string_view, int, int, int> hitmiss_fmtstr{
        "cpu{}->{} {:<12s} ACCESS: {:10d} HIT: {:10d} MISS: {:10d} MISS_MERGE: {:10d}"};
    lines.push_back(fmt::format(hitmiss_fmtstr, cpu, stats.name, "TOTAL", total_hits + total_misses, total_hits, total_misses, total_miss_merge));
    for (const auto type : {access_type::LOAD, access_type::RFO, access_type::PREFETCH, access_type::WRITE, access_type::TRANSLATION}) {
      lines.push_back(
          fmt::format(hitmiss_fmtstr, cpu, stats.name, access_type_names.at(champsim::to_underlying(type)),
                      stats.hits.value_or(std::pair{type, cpu}, hits_value_type{}) + stats.misses.value_or(std::pair{type, cpu}, misses_value_type{}),
                      stats.hits.value_or(std::pair{type, cpu}, hits_value_type{}), stats.misses.value_or(std::pair{type, cpu}, misses_value_type{}),
                      stats.miss_merge.value_or(std::pair{type, cpu}, miss_merge_value_type{})));
    }

    lines.push_back(fmt::format("cpu{}->{} PREFETCH REQUESTED: {:10} ISSUED: {:10} USEFUL: {:10} USELESS: {:10}", cpu, stats.name, stats.pf_requested,
                                stats.pf_issued, stats.pf_useful, stats.pf_useless));

    uint64_t total_downstream_demands = total_fill - stats.fill.value_or(std::pair{access_type::PREFETCH, cpu}, fill_value_type{});
    lines.push_back(
        fmt::format("cpu{}->{} AVERAGE MISS LATENCY: {} cycles", cpu, stats.name, ::print_ratio(stats.total_miss_latency_cycles, total_downstream_demands)));
  }

  // COALESCE coherence statistics. Cache-wide rather than per-CPU, so printed
  // once after the per-CPU loop.
  lines.push_back(fmt::format("{} COHERENCE INVALIDATIONS: {:10}", stats.name, stats.coherence_invalidations));
  lines.push_back(fmt::format("{} COHERENCE WRITE-HIT OTHER-SHARER EVENTS: {:10}", stats.name, stats.coherence_write_hit_other_sharer_events));
  lines.push_back(fmt::format("{} COHERENCE RFO-HIT OTHER-SHARER EVENTS: {:10}", stats.name, stats.coherence_rfo_hit_other_sharer_events));
  lines.push_back(fmt::format("{} COHERENCE RFO-HIT OTHER SHARERS: {:10}", stats.name, stats.coherence_rfo_hit_other_sharers));
  lines.push_back(fmt::format("{} COHERENCE DIR RFO PRESENCE-OTHER EVENTS: {:10}", stats.name, stats.coherence_dir_rfo_presence_events));
  lines.push_back(fmt::format("{} COHERENCE DIR RFO PRESENCE-OTHER CORES: {:10}", stats.name, stats.coherence_dir_rfo_presence_others));
  lines.push_back(fmt::format("{} COHERENCE DIR RFO PROTOCOL-OTHER EVENTS: {:10}", stats.name, stats.coherence_dir_rfo_protocol_events));
  lines.push_back(fmt::format("{} COHERENCE DIR RFO PROTOCOL-OTHER CORES: {:10}", stats.name, stats.coherence_dir_rfo_protocol_others));
  lines.push_back(fmt::format("{} COHERENCE DIR SELF-CHECK MISMATCHES: {:10}", stats.name, stats.coherence_dir_selfcheck_mismatches));
  lines.push_back(fmt::format("{} COHERENCE DIR PRIVATE CACHES REGISTERED: {:10}", stats.name, stats.coherence_dir_registered));
  lines.push_back(fmt::format("{} COHERENCE DIR COPIES INVALIDATED: {:10}", stats.name, stats.coherence_dir_copies_invalidated));
  lines.push_back(fmt::format("{} COHERENCE DIR UPGRADE EVENTS: {:10}", stats.name, stats.coherence_dir_upgrade_events));
  lines.push_back(fmt::format("{} COHERENCE DIR UPGRADE OTHER CORES: {:10}", stats.name, stats.coherence_dir_upgrade_cores));
  lines.push_back(fmt::format("{} COHERENCE DIR UPGRADE PRESENCE EVENTS: {:10}", stats.name, stats.coherence_dir_upgrade_presence_events));
  lines.push_back(fmt::format("{} COHERENCE DIR STALE FILLS DROPPED: {:10}", stats.name, stats.coherence_dir_stale_fills));
  lines.push_back(fmt::format("{} COHERENCE DIR STALE-HOLDER VIOLATIONS: {:10}", stats.name, stats.coherence_dir_stale_holders));
  if (champsim::coherence::coherence_latency() > 0)
    lines.push_back(fmt::format("{} COHERENCE LATENCY WAITS: {:10}", stats.name, stats.coherence_latency_waits));
  lines.push_back(fmt::format("{} COHERENCE DIR RFO BOUNDED-PROTOCOL EVENTS: {:10}", stats.name, stats.coherence_dir_rfo_bounded_events));
  lines.push_back(fmt::format("{} COHERENCE DIR UPGRADE BOUNDED-PROTOCOL EVENTS: {:10}", stats.name, stats.coherence_dir_upgrade_bounded_events));
  lines.push_back(fmt::format("{} COHERENCE DIR RFO GEM5-RULE EVENTS: {:10}", stats.name, stats.coherence_dir_rfo_g5_events));
  lines.push_back(fmt::format("{} COHERENCE DIR RFO GEM5-RULE CORES: {:10}", stats.name, stats.coherence_dir_rfo_g5_cores));
  lines.push_back(fmt::format("{} COHERENCE DIR UPGRADE GEM5-RULE EVENTS: {:10}", stats.name, stats.coherence_dir_upgrade_g5_events));
  lines.push_back(fmt::format("{} COHERENCE DIR UPGRADE GEM5-RULE CORES: {:10}", stats.name, stats.coherence_dir_upgrade_g5_cores));
  lines.push_back(fmt::format("{} COHERENCE DIR VIEW-ORDER VIOLATIONS: {:10}", stats.name, stats.coherence_dir_view_order_violations));
  lines.push_back(fmt::format("{} COHERENCE DIR GEM5-RULE SILENT RE-LISTINGS: {:10}", stats.name, stats.coherence_dir_upgrade_g5_silent));
  lines.push_back(fmt::format("{} COHERENCE DIR VIEW-ORDER LINES BY SILENT RE-LISTING: {:10}", stats.name, stats.coherence_dir_view_order_by_silent));
  lines.push_back(fmt::format("{} COHERENCE DIR VIEW-ORDER VIOLATIONS UNEXPLAINED: {:10}", stats.name, stats.coherence_dir_view_order_unexplained));

  uint64_t hist_total = 0;
  for (auto v : stats.coherence_sharer_hist) {
    hist_total += v;
  }
  if (hist_total > 0) {
    lines.push_back(fmt::format("{} SHARER HIST TOTAL: {:14}", stats.name, hist_total));
    for (std::size_t i = 0; i < std::size(stats.coherence_sharer_hist); i++) {
      if (stats.coherence_sharer_hist[i] > 0) {
        lines.push_back(fmt::format("{} SHARER HIST[{:2}]: {:14}  ({:6.3f}%)", stats.name, i, stats.coherence_sharer_hist[i],
                                    100.0 * static_cast<double>(stats.coherence_sharer_hist[i]) / static_cast<double>(hist_total)));
      }
    }
  }

  return lines;
}

std::vector<std::string> champsim::plain_printer::format(champsim::modules::memory_controller_module::stats_type stats)
{
  std::vector<std::string> lines{};
  lines.push_back(fmt::format("{} RQ ROW_BUFFER_HIT: {:10}", stats.name, stats.RQ_ROW_BUFFER_HIT));
  lines.push_back(fmt::format("  ROW_BUFFER_MISS: {:10}", stats.RQ_ROW_BUFFER_MISS));
  lines.push_back(fmt::format("  AVG DBUS CONGESTED CYCLE: {}", ::print_ratio(stats.dbus_cycle_congested, stats.dbus_count_congested)));
  lines.push_back(fmt::format("{} WQ ROW_BUFFER_HIT: {:10}", stats.name, stats.WQ_ROW_BUFFER_HIT));
  lines.push_back(fmt::format("  ROW_BUFFER_MISS: {:10}", stats.WQ_ROW_BUFFER_MISS));
  lines.push_back(fmt::format("  FULL: {:10}", stats.WQ_FULL));

  if (stats.refresh_cycles > 0)
    lines.push_back(fmt::format("{} REFRESHES ISSUED: {:10}", stats.name, stats.refresh_cycles));
  else
    lines.push_back(fmt::format("{} REFRESHES ISSUED: -", stats.name));

  return lines;
}

void champsim::plain_printer::print(champsim::phase_stats& stats)
{
  auto lines = format(stats);
  std::copy(std::begin(lines), std::end(lines), std::ostream_iterator<std::string>(stream, "\n"));
}

std::vector<std::string> champsim::plain_printer::format(champsim::phase_stats& stats)
{
  std::vector<std::string> lines{};
  lines.push_back(fmt::format("=== {} ===", stats.name));

  int i = 0;
  for (auto tn : stats.trace_names) {
    lines.push_back(fmt::format("CPU {} runs {}", i++, tn));
  }

  if (NUM_CPUS > 1) {
    lines.emplace_back("");
    lines.emplace_back("Total Simulation Statistics (not including warmup)");

    for (const auto& stat : stats.sim_cpu_stats) {
      auto sublines = format(stat);
      lines.emplace_back("");
      std::move(std::begin(sublines), std::end(sublines), std::back_inserter(lines));
      lines.emplace_back("");
    }

    for (const auto& stat : stats.sim_cache_stats) {
      auto sublines = format(stat);
      std::move(std::begin(sublines), std::end(sublines), std::back_inserter(lines));
    }
  }

  lines.emplace_back("");
  lines.emplace_back("Region of Interest Statistics");

  for (const auto& stat : stats.roi_cpu_stats) {
    auto sublines = format(stat);
    lines.emplace_back("");
    std::move(std::begin(sublines), std::end(sublines), std::back_inserter(lines));
    lines.emplace_back("");
  }

  for (const auto& stat : stats.roi_cache_stats) {
    auto sublines = format(stat);
    std::move(std::begin(sublines), std::end(sublines), std::back_inserter(lines));
  }

  lines.emplace_back("");
  lines.emplace_back("DRAM Statistics");
  for (const auto& stat : stats.roi_dram_stats) {
    auto sublines = format(stat);
    lines.emplace_back("");
    std::move(std::begin(sublines), std::end(sublines), std::back_inserter(lines));
  }

  return lines;
}

void champsim::plain_printer::print(std::vector<phase_stats>& stats)
{
  for (auto p : stats) {
    print(p);
  }
}
