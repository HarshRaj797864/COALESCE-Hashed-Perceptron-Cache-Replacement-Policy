#ifndef CORE_STATS_H
#define CORE_STATS_H

#include <cstdint>
#include <string>

#include "event_counter.h"
#include "instruction.h"

struct cpu_stats {
  std::string name;
  long long begin_instrs = 0;
  long long begin_cycles = 0;
  long long end_instrs = 0;
  long long end_cycles = 0;
  uint64_t total_rob_occupancy_at_branch_mispredict = 0;
  // Loads of read-modify-write instructions issued to L1D as RFOs (B3 v3
  // step 1, ooo_cpu.cc execute_load).
  uint64_t rmw_loads_as_rfo = 0;
  // RMW loads that never reached L1D: an older store to the same address was
  // still in the store queue, and the load took its value from it. Every RMW
  // load dispatched is one or the other, so the two sum to the trace's RMW
  // count (verification_2026-10-11.md).
  uint64_t rmw_loads_forwarded = 0;

  champsim::stats::event_counter<branch_type> total_branch_types = {};
  champsim::stats::event_counter<branch_type> branch_type_misses = {};

  [[nodiscard]] auto instrs() const { return end_instrs - begin_instrs; }
  [[nodiscard]] auto cycles() const { return end_cycles - begin_cycles; }
};

cpu_stats operator-(cpu_stats lhs, cpu_stats rhs);

#endif
