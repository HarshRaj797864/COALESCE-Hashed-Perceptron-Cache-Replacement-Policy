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

#include "champsim.h"

#include <algorithm>
#include <chrono>
#include <numeric>
#include <optional>
#include <vector>
#include <fmt/chrono.h>
#include <fmt/core.h>

#include "event_listeners.h"
#include "modules.h"
#include "ooo_cpu.h"
#include "operable.h"
#include "phase_info.h"
#include "sync_replay.h"
#include "tracereader.h"

const auto start_time = std::chrono::steady_clock::now();

std::chrono::seconds elapsed_time() { return std::chrono::duration_cast<std::chrono::seconds>(std::chrono::steady_clock::now() - start_time); }

namespace
{
// Synchronised replay (sync_replay.h): each trace's first record, read before
// the first cycle so every thread's base is known before any core asks
// whether a release has happened. A base record is consumed there; anything
// else is kept here and given to its core first.
std::vector<std::optional<ooo_model_instr>>& primed()
{
  static std::vector<std::optional<ooo_model_instr>> p;
  return p;
}
} // namespace

namespace champsim
{
long do_cycle(std::vector<std::reference_wrapper<champsim::operable>> operables, std::vector<std::reference_wrapper<champsim::modules::core_module>>& cores,
              std::vector<tracereader>& traces, std::vector<std::size_t> trace_index, champsim::chrono::clock& global_clock)
{
  std::sort(std::begin(operables), std::end(operables),
            [](const champsim::operable& lhs, const champsim::operable& rhs) { return lhs.current_time < rhs.current_time; });

  // Operate
  long progress{0};
  for (champsim::operable& op : operables) {
    progress += op.operate_on(global_clock);
  }

  // Read from trace
  for (champsim::modules::core_module& cpu : cores) {
    const auto t = trace_index.at(cpu.get_cpu_num());
    auto& trace = traces.at(t);
    auto pkt_count = cpu.instructions_requested();
    if (pkt_count > 0 && t < std::size(primed()) && primed()[t].has_value()) {
      cpu.push_instruction(*primed()[t]);
      primed()[t].reset();
      --pkt_count;
    }
    for (; !trace.eof() && pkt_count > 0; --pkt_count) {
      auto instr = trace();
      while (instr.sync_base && !trace.eof()) { // a base met again (a reopened trace): it only sets the base
        champsim::sync::set_base(instr.sync_release);
        instr = trace();
      }
      if (instr.sync_base) {
        champsim::sync::set_base(instr.sync_release);
        break;
      }
      cpu.push_instruction(instr);
    }
  }

  return progress;
}

phase_stats do_phase(const phase_info& phase, modules::environment_module& env, std::vector<tracereader>& traces, champsim::chrono::clock& global_clock)
{
  // Cache typed views once — these never change during simulation
  auto operables = env.typed_view<champsim::operable>("operable");
  auto cores = env.typed_view<champsim::modules::core_module>("core");

  auto [phase_name, is_warmup, length, trace_index, trace_names] = phase;

  // Initialize phase
  for (champsim::operable& op : operables) {
    op.warmup = is_warmup;
    op.begin_phase();
  }

  const auto time_quantum = std::accumulate(std::cbegin(operables), std::cend(operables), champsim::chrono::clock::duration::max(),
                                            [](const auto acc, const operable& y) { return std::min(acc, y.clock_period); });

  const int DEADLOCK_CYCLE = env.get_deadlock_cycles();

  bool livelock_trigger{false};
  uint64_t livelock_period{10000000};
  uint64_t livelock_timer{0};
  //                                   die | critical | warning
  std::vector<double> livelock_threshold{0.01, 0.02, 0.05};
  std::vector<uint64_t> livelock_instr(std::size(cores), 0);
  // Synchronised replay: a core held at a sync record that retires nothing for
  // this many periods in a row is deadlocked (sync_mutex_design_2026-10-19.md).
  // A whole-machine deadlock is caught below by DEADLOCK_CYCLE; this catches
  // one where other cores keep running.
  constexpr int SYNC_DEADLOCK_PERIODS = 30;
  std::vector<int> sync_stuck(std::size(cores), 0);

  // Perform phase
  int stalled_cycle{0};
  std::vector<bool> phase_complete(std::size(cores), false);
  while (!std::accumulate(std::begin(phase_complete), std::end(phase_complete), true, std::logical_and{})) {
    auto next_phase_complete = phase_complete;
    global_clock.tick(time_quantum);

    auto progress = do_cycle(operables, cores, traces, trace_index, global_clock);

    if (progress == 0) {
      ++stalled_cycle;
    } else {
      stalled_cycle = 0;
    }

    // Livelock detect, every livelock_period cycles, check progress and alert the user
    livelock_timer++;
    if (livelock_timer >= livelock_period) {
      // for each cpu
      for (champsim::modules::core_module& cpu : cores) {
        // A core held at a sync record for most of the period is waiting
        // for another core, as the program would; it is not livelocked.
        const bool sync_waiting = champsim::sync::take_stall_cycles(static_cast<unsigned>(cpu.get_cpu_num())) * 2 >= livelock_period;
        auto& stuck = sync_stuck.at(cpu.get_cpu_num());
        stuck = (sync_waiting && cpu.sim_instr() == livelock_instr[cpu.get_cpu_num()]) ? stuck + 1 : 0;
        if (stuck >= SYNC_DEADLOCK_PERIODS) {
          fmt::print("{} CPU {} SYNC DEADLOCK: held at a sync record, nothing retired for {} periods of {} cycles\n", phase_name, cpu.get_cpu_num(), stuck,
                     livelock_period);
          champsim::sync::print_state();
          livelock_trigger = true;
        }
        // for each threshold
        for (auto thres = std::begin(livelock_threshold); thres != std::end(livelock_threshold); thres++) {
          if (thres == std::begin(livelock_threshold) && sync_waiting)
            break;
          double livelock_ipc = std::ceil(cpu.sim_instr() - livelock_instr[cpu.get_cpu_num()]) / std::ceil(livelock_period);
          if (livelock_ipc <= *thres) {
            if (std::distance(std::begin(livelock_threshold), thres) == 0) {
              livelock_trigger = true;
              fmt::print("{} CPU {} panic: IPC {:.5g} < {:.5g}\n", phase_name, cpu.get_cpu_num(), livelock_ipc, *thres);
            } else if (std::distance(std::begin(livelock_threshold), thres) == 1)
              fmt::print("{} CPU {} critical: IPC {:.5g} < {:.5g}\n", phase_name, cpu.get_cpu_num(), livelock_ipc, *thres);
            else
              fmt::print("{} CPU {} warning: IPC {:.5g} < {:.5g}\n", phase_name, cpu.get_cpu_num(), livelock_ipc, *thres);

            break;
          }
        }
        livelock_instr[cpu.get_cpu_num()] = cpu.sim_instr();
      }
      livelock_timer = 0;
    }

    if (stalled_cycle >= DEADLOCK_CYCLE || livelock_trigger) {
      std::for_each(std::begin(operables), std::end(operables), [](champsim::operable& c) { c.print_deadlock(); });
      exit(-1); // abort fails to flush which can truncate deadlock printouts, so use exit with -1 to indicate failure
    }

    // If any trace reaches EOF, terminate all phases
    if (std::any_of(std::begin(traces), std::end(traces), [](const auto& tr) { return tr.eof(); })) {
      std::fill(std::begin(next_phase_complete), std::end(next_phase_complete), true);
    }

    // Check for phase finish
    for (champsim::modules::core_module& cpu : cores) {
      // Phase complete
      next_phase_complete[cpu.get_cpu_num()] = next_phase_complete[cpu.get_cpu_num()] || (cpu.sim_instr() >= length);
    }

    for (champsim::modules::core_module& cpu : cores) {
      if (next_phase_complete[cpu.get_cpu_num()] != phase_complete[cpu.get_cpu_num()]) {
        for (champsim::operable& op : operables) {
          op.end_phase(cpu.get_cpu_num());
        }

        fmt::print("{} finished CPU {} instructions: {} cycles: {} cumulative IPC: {:.4g} (Simulation time: {:%H hr %M min %S sec})\n", phase_name,
                   cpu.get_cpu_num(), cpu.sim_instr(), cpu.sim_cycle(), std::ceil(cpu.sim_instr()) / std::ceil(cpu.sim_cycle()), elapsed_time());
      }
    }

    phase_complete = next_phase_complete;
  }

  for (champsim::modules::core_module& cpu : cores) {
    fmt::print("{} complete CPU {} instructions: {} cycles: {} cumulative IPC: {:.4g} (Simulation time: {:%H hr %M min %S sec})\n", phase_name,
               cpu.get_cpu_num(), cpu.sim_instr(), cpu.sim_cycle(), std::ceil(cpu.sim_instr()) / std::ceil(cpu.sim_cycle()), elapsed_time());
  }

  phase_stats stats;
  stats.name = phase.name;

  for (std::size_t i = 0; i < std::size(trace_index); ++i) {
    stats.trace_names.push_back(trace_names.at(trace_index.at(i)));
  }

  std::transform(std::begin(cores), std::end(cores), std::back_inserter(stats.sim_cpu_stats),
                 [](const champsim::modules::core_module& cpu) { return cpu.get_sim_stats(); });
  std::transform(std::begin(cores), std::end(cores), std::back_inserter(stats.roi_cpu_stats),
                 [](const champsim::modules::core_module& cpu) { return cpu.get_roi_stats(); });

  auto caches = env.typed_view<champsim::modules::cache_module>("cache");
  std::transform(std::begin(caches), std::end(caches), std::back_inserter(stats.sim_cache_stats),
                 [](const champsim::modules::cache_module& cache) { return cache.get_sim_stats(); });
  std::transform(std::begin(caches), std::end(caches), std::back_inserter(stats.roi_cache_stats),
                 [](const champsim::modules::cache_module& cache) { return cache.get_roi_stats(); });

  for (champsim::modules::memory_controller_module& dram : env.typed_view<champsim::modules::memory_controller_module>("memory_controller")) {
    for (std::size_t chan_no = 0; chan_no < dram.get_num_channels(); ++chan_no) {
      stats.sim_dram_stats.push_back(dram.get_sim_stats(chan_no));
      stats.roi_dram_stats.push_back(dram.get_roi_stats(chan_no));
    }
  }

  return stats;
}

// simulation entry point
std::vector<phase_stats> main(modules::environment_module& env, std::vector<phase_info>& phases, std::vector<tracereader>& traces)
{
  for (champsim::operable& op : env.typed_view<champsim::operable>("operable")) {
    op.initialize();
  }

  // Synchronised replay: read every trace's first record now (see primed()).
  primed().assign(std::size(traces), std::nullopt);
  for (std::size_t t = 0; t < std::size(traces); ++t) {
    if (traces[t].eof())
      continue;
    auto first = traces[t]();
    if (first.sync_base)
      champsim::sync::set_base(first.sync_release);
    else
      primed()[t] = first;
  }

  champsim::chrono::clock global_clock;
  std::vector<phase_stats> results;
  for (auto phase : phases) {
    // call event listeners
    handle_event<Event::BEGIN_PHASE>(phase.is_warmup);
    // handle_begin_phase(0, phase.is_warmup);

    auto stats = do_phase(phase, env, traces, global_clock);
    if (!phase.is_warmup) {
      results.push_back(stats);
    }
  }

  return results;
}
} // namespace champsim
