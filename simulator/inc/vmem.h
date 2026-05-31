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

#ifndef VMEM_H
#define VMEM_H

#include <cstdint>
#include <deque>
#include <limits>
#include <map>
#include <optional>
#include <random>
#include <vector>

#include "address.h"
#include "champsim.h"
#include "chrono.h"

class MEMORY_CONTROLLER;

using pte_entry = champsim::data::size<long long, std::ratio<8>>;

class VirtualMemory
{
private:
  std::map<std::pair<uint32_t, champsim::page_number>, champsim::page_number> vpage_to_ppage_map;
  std::map<std::tuple<uint32_t, uint32_t, champsim::address_slice<champsim::dynamic_extent>>, champsim::address> page_table;
  std::optional<uint64_t> randomization_seed;
  MEMORY_CONTROLLER& dram;

  // COALESCE: per-CPU effective ASID for va_to_pa key. Default behavior treats cpu_num
  // as the ASID (each core gets its own physical address space). Cores added to
  // shared_cpu_ids via set_shared_cpus() are remapped to SHARED_ASID, so identical VAs
  // from any of those cores alias on the same physical page.
  std::map<uint32_t, uint32_t> cpu_to_shared_asid;
  // Tracks first allocator of each shared vpage, for cross-CPU alias accounting.
  std::map<champsim::page_number, uint32_t> shared_first_allocator;

public:
  const champsim::chrono::clock::duration minor_fault_penalty;
  const std::size_t pt_levels;
  const pte_entry pte_page_size; // Size of a PTE page

  // COALESCE: sentinel ASID value indicating "share this core's translations".
  static constexpr uint32_t SHARED_ASID = std::numeric_limits<uint32_t>::max();

  // COALESCE: global counter of cross-CPU shared-page alias events.
  // Incremented inside va_to_pa whenever a request for a shared vpage finds it
  // already mapped by a DIFFERENT core. Static so it can be read at end-of-sim
  // without plumbing an accessor through generated_environment.
  static inline std::uint64_t aliased_fills = 0;

private:
  std::deque<champsim::page_number> ppage_free_list;
  champsim::page_number active_pte_page{};
  champsim::address_slice<champsim::dynamic_extent> next_pte_page;

  // champsim::page_number next_ppage;
  // champsim::page_number last_ppage;

  [[nodiscard]] champsim::page_number ppage_front() const;
  void ppage_pop();

  void shuffle_pages();
  void populate_pages();

public:
  /**
   * Initialize the virtual memory.
   * The size of the virtual memory space is determined from the size of a page table page and the number of levels in the hierarchy.
   *
   * :param page_table_page_size: The size of one page table page. This value must be less than the size of a physical page.
   * :param page_table_levels: The number of levels in the virtual memory table hierarchy.
   * :param minor_penalty: The latency of a minor page fault.
   * :param dram: The physical memory of the system.
   *   This is currently only used to issue a warning if the physical memory is smaller than the virtual memory.
   *   Future versions may perform major page faults through this reference.
   */
  VirtualMemory(champsim::data::bytes page_table_page_size, std::size_t page_table_levels, champsim::chrono::clock::duration minor_penalty,
                MEMORY_CONTROLLER& dram_);
  VirtualMemory(champsim::data::bytes page_table_page_size, std::size_t page_table_levels, champsim::chrono::clock::duration minor_penalty,
                MEMORY_CONTROLLER& dram_, std::optional<uint64_t> randomization_seed_);

  /**
   * Find the bit location of the lowest bit for the given page table level.
   */
  [[nodiscard]] champsim::data::bits shamt(std::size_t level) const;

  /**
   * Find the extent for the given page table level.
   */
  [[nodiscard]] champsim::dynamic_extent extent(std::size_t level) const;

  /**
   * Get the page table page offset of the address for the given level.
   */
  [[nodiscard]] uint64_t get_offset(champsim::address vaddr, std::size_t level) const;
  [[nodiscard]] uint64_t get_offset(champsim::page_number vaddr, std::size_t level) const;

  /**
   * The count of unallocated physical pages.
   */
  [[nodiscard]] std::size_t available_ppages() const;

  /**
   * Translate the given address from the virtual space to the physical space.
   * If a page translation does not already exist, one will be created and the minor fault penalty will be applied.
   *
   * :param cpu_num: The cpu index of the core making the request. This is currently used as an address space ID.
   * :param vaddr: The address to translate.
   *
   * :returns: A pair of the physical address and the latency to be applied to the translation.
   */
  std::pair<champsim::page_number, champsim::chrono::clock::duration> va_to_pa(uint32_t cpu_num, champsim::page_number vaddr);

  /**
   * Find the address for the page table page for the given virtual address (under translation), and the given level.
   * If a page table page does not already exist, one will be created and the minor fault penalty will be applied.
   *
   * :param cpu_num: The cpu index of the core making the request. This is currently used as an address space ID.
   * :param vaddr: The address to translate.
   * :param level: The current level being translated.
   *
   * :returns: A pair of the page table page address and the latency to be applied to the operation.
   */
  std::pair<champsim::address, champsim::chrono::clock::duration> get_pte_pa(uint32_t cpu_num, champsim::page_number vaddr, std::size_t level);

  /**
   * COALESCE: enable cross-CPU page aliasing for the given cores.
   *
   * Cores listed in shared_cpu_ids will use SHARED_ASID as their effective ASID
   * when calling va_to_pa, so any two such cores accessing the same virtual page
   * collapse to the same physical page (mimicking pthread shared memory).
   *
   * Cores NOT listed are unaffected — they continue using cpu_num as their ASID
   * and remain isolated. Idempotent and additive.
   *
   * Default (never called or called with empty vector): all cores private,
   * preserving existing ChampSim semantics.
   *
   * Does NOT change get_pte_pa: PTEs remain per-CPU (page tables are not shared).
   */
  void set_shared_cpus(const std::vector<uint32_t>& shared_cpu_ids);
};

#endif
