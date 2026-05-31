#include <catch.hpp>

#include "dram_controller.h"
#include "vmem.h"

// Helper: build a fresh DRAM + VMEM for each SCENARIO so static aliased_fills
// resets are not required (it's accumulated across tests, but each scenario asserts
// deltas, so cross-scenario coupling is acceptable for this audit).
namespace {
auto make_dram()
{
  return MEMORY_CONTROLLER{champsim::chrono::picoseconds{3200},
                            champsim::chrono::picoseconds{6400},
                            std::size_t{18},
                            std::size_t{18},
                            std::size_t{18},
                            std::size_t{38},
                            champsim::chrono::microseconds{64000},
                            {},
                            64,
                            64,
                            1,
                            champsim::data::bytes{8},
                            1024,
                            1024,
                            4,
                            4,
                            4,
                            8192};
}
}  // namespace

SCENARIO("The virtual memory remove PA asked by PTE")
{
  GIVEN("A large virtual memory")
  {
    constexpr unsigned levels = 5;
    constexpr champsim::data::bytes pte_page_size{1ull << 12};
    MEMORY_CONTROLLER dram{champsim::chrono::picoseconds{3200},
                           champsim::chrono::picoseconds{6400},
                           std::size_t{18},
                           std::size_t{18},
                           std::size_t{18},
                           std::size_t{38},
                           champsim::chrono::microseconds{64000},
                           {},
                           64,
                           64,
                           1,
                           champsim::data::bytes{8},
                           1024,
                           1024,
                           4,
                           4,
                           4,
                           8192};
    VirtualMemory uut{pte_page_size, levels, std::chrono::nanoseconds{6400}, dram};

    WHEN("PTE requires memory")
    {
      std::size_t original_size = uut.available_ppages();

      const champsim::page_number to_check{0xdeadbeef};
      AND_WHEN("PTE ask for a page")
      {
        auto [paddr_a, delay_a] = uut.get_pte_pa(0, to_check, 1);

        THEN("The page table missed") { REQUIRE(delay_a > champsim::chrono::clock::duration::zero()); }

        AND_WHEN("PTE asks for another page")
        {
          auto [paddr_b, delay_b] = uut.get_pte_pa(0, to_check, 2);

          THEN("The page table missed") { REQUIRE(delay_b > champsim::chrono::clock::duration::zero()); }

          THEN("The pages are different") { REQUIRE(paddr_a != paddr_b); }

          THEN("The pages are remove from the available pages") { REQUIRE(original_size - 2 == uut.available_ppages()); }
        }
      }
    }
  }
}

// COALESCE: cross-CPU isolation + shared-overlay tests (added 2026-05-31).
// These assert the load-bearing semantics of set_shared_cpus() — the foundation
// of the true-sharing regime described in docs/PUBLICATION_STRATEGY.md.

SCENARIO("VMEM default mode keeps CPUs isolated (cross-CPU same VA -> different PAs)")
{
  GIVEN("A virtual memory with no shared CPUs configured")
  {
    constexpr unsigned levels = 5;
    constexpr champsim::data::bytes pte_page_size{1ull << 12};
    auto dram = make_dram();
    VirtualMemory uut{pte_page_size, levels, std::chrono::nanoseconds{6400}, dram};

    WHEN("two different CPUs translate the same virtual page")
    {
      const champsim::page_number vaddr{0xc0ffee};
      auto [pa_cpu0, _0] = uut.va_to_pa(0u, vaddr);
      auto [pa_cpu1, _1] = uut.va_to_pa(1u, vaddr);

      THEN("the physical pages differ (per-CPU isolation preserved)")
      {
        REQUIRE(pa_cpu0 != pa_cpu1);
      }
    }
  }
}

SCENARIO("VMEM shared mode aliases same VA across configured CPUs")
{
  GIVEN("A virtual memory where CPUs {0,1,2} are configured as shared")
  {
    constexpr unsigned levels = 5;
    constexpr champsim::data::bytes pte_page_size{1ull << 12};
    auto dram = make_dram();
    VirtualMemory uut{pte_page_size, levels, std::chrono::nanoseconds{6400}, dram};

    uut.set_shared_cpus({0u, 1u, 2u});
    const auto baseline_aliased = VirtualMemory::aliased_fills;

    WHEN("CPU 0 translates a shared VA")
    {
      const champsim::page_number shared_vaddr{0xdeadbeef};
      auto [pa_cpu0, _] = uut.va_to_pa(0u, shared_vaddr);

      AND_WHEN("CPU 1 (also in shared set) translates the same VA")
      {
        auto [pa_cpu1, _2] = uut.va_to_pa(1u, shared_vaddr);
        THEN("the physical pages are the same (aliased)")
        {
          REQUIRE(pa_cpu0 == pa_cpu1);
        }
        THEN("the aliased_fills counter incremented")
        {
          REQUIRE(VirtualMemory::aliased_fills == baseline_aliased + 1);
        }
      }

      AND_WHEN("CPU 2 (also in shared set) translates the same VA")
      {
        auto [pa_cpu2, _3] = uut.va_to_pa(2u, shared_vaddr);
        THEN("the physical page matches CPU 0's")
        {
          REQUIRE(pa_cpu0 == pa_cpu2);
        }
      }

      AND_WHEN("CPU 5 (NOT in shared set) translates the same VA")
      {
        auto [pa_cpu5, _4] = uut.va_to_pa(5u, shared_vaddr);
        THEN("the physical page differs from CPU 0's (isolation preserved for non-shared CPUs)")
        {
          REQUIRE(pa_cpu0 != pa_cpu5);
        }
      }
    }

    WHEN("two shared CPUs translate distinct VAs")
    {
      const champsim::page_number va_a{0x1111};
      const champsim::page_number va_b{0x2222};
      auto [pa_a, _0] = uut.va_to_pa(0u, va_a);
      auto [pa_b, _1] = uut.va_to_pa(1u, va_b);
      THEN("distinct VAs still map to distinct PAs even within the shared address space")
      {
        REQUIRE(pa_a != pa_b);
      }
    }
  }
}

SCENARIO("VMEM set_shared_cpus is idempotent and additive")
{
  GIVEN("A virtual memory")
  {
    constexpr unsigned levels = 5;
    constexpr champsim::data::bytes pte_page_size{1ull << 12};
    auto dram = make_dram();
    VirtualMemory uut{pte_page_size, levels, std::chrono::nanoseconds{6400}, dram};

    WHEN("set_shared_cpus is called twice with overlapping sets")
    {
      uut.set_shared_cpus({0u, 1u});
      uut.set_shared_cpus({1u, 2u});

      const champsim::page_number vaddr{0xabcd};
      auto [pa0, _0] = uut.va_to_pa(0u, vaddr);
      auto [pa1, _1] = uut.va_to_pa(1u, vaddr);
      auto [pa2, _2] = uut.va_to_pa(2u, vaddr);

      THEN("all three CPUs share the same physical page (union of both sets)")
      {
        REQUIRE(pa0 == pa1);
        REQUIRE(pa1 == pa2);
      }
    }
  }
}
