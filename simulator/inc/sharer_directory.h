#ifndef SHARER_DIRECTORY_H
#define SHARER_DIRECTORY_H

#include <cstdint>
#include <cstdio>
#include <functional>
#include <string>
#include <utility>

// COALESCE B3 v2: a sharer directory, one per simulation
// (bench/policy_sanity/b3v2_design_2026-10-05.md).
//
// The LLC sharer masks (block.h) record sharers only while the non-inclusive
// LLC holds a line, and forget them when it evicts it. At 2 MB that lost 99%
// of the store misses' sharer records, against gem5's inclusive L2 (B3 v1,
// b3_ocean4_2026-10-05.md). This directory is keyed by physical line address
// and is independent of LLC residency. It records and counts; it changes no
// simulated behaviour -- at private_coherence 0. See below for 1 and 2.
//
//   presence       which cores' private data caches (L1I, L1D, L2C) hold the
//                  line now -- set on fill, cleared on eviction/invalidation
//   protocol view  the sharer set a MESI directory would list, driven by the
//                  requests that reach the LLC: a read adds the requester, a
//                  store miss (RFO) leaves it the sole owner, a writeback
//                  removes it
//
// COALESCE B3 v4: private-cache coherence, set per run
// (bench/policy_sanity/b3v4_coherent_private_design_2026-10-11.md).
//
//   0  none. The directory records and counts, as above.
//   1  an ownership request (RFO) accepted at the LLC invalidates every other
//      core's private copies of the line.
//   2  1, and: a store or RFO that HITS a private copy takes the line the same
//      way when the protocol view lists another core or another core's private
//      caches hold it -- the upgrade.
//
// At 1 and 2 a copy may be in flight to a core when another core takes the
// line. Each grant therefore marks every other core STALE for the line; a
// core's mark is cleared when a request of its own for the line is next
// accepted at the LLC. A fill reaching a private cache for a stale core
// completes its instruction and leaves no copy.
namespace champsim::coherence
{
// 3 presence bits per core (L1I, L1D, L2C) in one 64-bit word.
inline constexpr unsigned dir_levels = 3;
inline constexpr unsigned dir_max_cpus = 21;

enum class dir_req { read, store, writeback };

struct dir_lookup {
  uint32_t presence_others = 0; // other cores whose private caches hold the line
  uint32_t protocol_others = 0; // other cores the protocol view lists
  uint32_t bounded_others = 0;  // other cores the bounded protocol view lists (diagnosis, below)
  uint32_t g5_others = 0;       // other cores the gem5-rule view lists (below)
  bool g5_relisted = false;     // an ownership hit re-listed the requester in the gem5-rule view only (below)
};

// Diagnosis, records only (b3_bounded_design_2026-10-17.md): a second protocol
// view, kept exactly as the first except that it forgets every core once the
// line is held nowhere on chip -- in no private cache and not in the LLC -- as
// an inclusive shared cache that is also the directory (gem5's
// MESI_Three_Level L2) forgets its sharers when it evicts the line. It changes
// no simulated behaviour; it only feeds two counters. The LLC tells the
// directory what it holds:
void dir_llc_fill(uint64_t line);
void dir_llc_evict(uint64_t line);

// Step 3, records only (b3_g5rule_design_2026-10-19.md): a third view, the
// rule gem5's MESI_Three_Level directory was measured to follow
// (micro_results_2026-10-18.md). An EXCLUSIVE holder -- granted E on a read
// nobody else held, or M on a store, or an ownership hit -- is forgotten when
// its last private copy leaves; SHARED readers stay listed until the line is
// held nowhere on chip, when every core is forgotten. It changes no simulated
// behaviour. Each view only forgets more than the one before:
// gem5-rule <= bounded <= protocol, line by line; this counts the lines where
// that fails.
// Amendment 2 (2026-10-27): that order has one known exception. The protocol
// and bounded views drop a core on its writeback; ChampSim's private caches
// are not inclusive, so a core's L2C can write a line back while its L1D
// keeps a copy. A store to that copy (an ownership hit finding no other core)
// re-lists the core in the gem5-rule view only: a SILENT RE-LISTING. The
// views' rules are unchanged; the directory remembers which cores the
// gem5-rule view lists that way. Raw violations = lines by silent
// re-listing (every departure is such a core) + unexplained (must be 0).
uint64_t dir_count_view_order_violations();
uint64_t dir_count_view_order_by_silent_relisting();

// "cpu<N>_L1I" / "_L1D" / "_L2C" -> {N, level 0/1/2}; anything else -> {-1, -1}.
// TLBs and the LLC are not private data caches.
std::pair<int, int> private_cache_of(const std::string& name);

// `invalidate` drops that cache's copy of a line, if it holds one.
void dir_register_private_cache(unsigned cpu, unsigned level, std::function<void(uint64_t)> invalidate);
unsigned dir_registered_private_caches();

void set_private_coherence(unsigned level); // 0, 1 or 2
unsigned private_coherence();

// C0 (bench/policy_sanity/c0_latency_design_2026-10-14.md): the cycles an
// ownership request waits for its invalidations when it must take a line from
// other cores -- a store miss at the LLC, or an upgrade in a private cache.
// Needs private_coherence 2. 0, the default, is the simulator as it was.
void set_coherence_latency(unsigned cycles);
unsigned coherence_latency();

// The other holders of `line` as a request from `cpu` would find them now.
// Changes nothing (C0 decides from it whether a request waits).
dir_lookup dir_peek(uint64_t line, unsigned cpu);

void dir_fill(uint64_t line, unsigned cpu, unsigned level);
void dir_evict(uint64_t line, unsigned cpu, unsigned level);

// A request from `cpu` reaching the LLC, counted once per request. Returns the
// other holders as they were BEFORE the request, then updates the protocol view.
// At private_coherence >= 1 a store also invalidates the other cores' copies.
dir_lookup dir_llc_request(uint64_t line, unsigned cpu, dir_req kind);

// private_coherence 2: a store or RFO from `cpu` that hit one of its own
// private caches. Returns the other holders as they were; if there are any, by
// either view, `cpu` takes the line as a store at the LLC would.
dir_lookup dir_private_ownership_hit(uint64_t line, unsigned cpu);

// Is a fill of `line` now reaching `cpu` older than another core's ownership?
bool dir_is_stale(uint64_t line, unsigned cpu);

// Diagnosis only. If the environment variable COHERENCE_EVENT_LOG names a
// file, cache.cc writes one line to it per request the directory sees
// (scripts/coherence_events.py reads them). Null otherwise. Nothing is
// simulated differently either way.
std::FILE* dir_event_log();

// For the end-of-run self-check.
bool dir_present(uint64_t line, unsigned cpu, unsigned level);
uint64_t dir_count_present(unsigned cpu, unsigned level);
// Cores that hold a line they are marked stale for, over all lines. Must be 0.
uint64_t dir_count_stale_holders();
} // namespace champsim::coherence

#endif
