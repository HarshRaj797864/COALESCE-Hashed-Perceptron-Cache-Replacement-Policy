#ifndef SYNC_REPLAY_H
#define SYNC_REPLAY_H

#include <cstdint>
#include <functional>
#include <string>

// Synchronised replay (bench/policy_sanity/sync_replay_design_2026-10-18.md).
//
// A trace may carry SYNC RECORDS: ordinary records whose destination_memory[1]
// holds MAGIC, a non-canonical x86-64 address no real operand can carry.
//   destination_memory[0]  a release this record announces, or 0
//   source_memory[0]       a release this record waits for, or 0
//   source_memory[1]       KIND_RELEASE, KIND_ACQUIRE or KIND_BASE
// A release id is (seq << 8) | tid: seq orders every release of the native run,
// tid is the thread that made it. A thread's releases come in its program
// order, so per thread "released up to seq" is all the state needed.
//
// A BASE record (first in every trace with sync records) carries the id of the
// first release that thread's trace holds: its earlier releases were skipped
// or cut away, and count as done. A release by a thread no trace holds also
// counts as done.
//
// A core does not dispatch an instruction whose wait is not yet released; a
// release is announced when its instruction retires. With no sync records,
// nothing here is ever called and nothing is printed.
//
// MUTEX ORDER (bench/policy_sanity/sync_mutex_design_2026-10-19.md). A mutex
// record carries the mutex's address in source_memory[2] (traces made before
// 2026-10-19 carry none, and replay exactly as before). With the setting
// sync_mutex_order "timing" (the default), a mutex acquire ignores its recorded
// wait -- unless flagged ORDERED (source_memory[3]), when it keeps it -- and
// dispatches only when the mutex is free and the core is first in the mutex's
// queue; dispatching takes the mutex, and the release frees it when it
// retires. A core joins the queue only once its recorded wait (if kept) is
// released. A core's own unretired release does not free the mutex for it.
// "recorded" keeps every recorded wait, as before.
namespace champsim::sync
{
inline constexpr uint64_t MAGIC = 0x53594E4353594E43ULL; // "SYNCSYNC"
inline constexpr uint64_t KIND_RELEASE = 1;
inline constexpr uint64_t KIND_ACQUIRE = 2;
inline constexpr uint64_t KIND_BASE = 3;

void set_base(uint64_t first_release_id);
bool released(uint64_t id);
void release(unsigned cpu, uint64_t id);

// Bookkeeping, per core: acquires dispatched, releases retired, cycles held.
void note_acquire(unsigned cpu);
void note_stall(unsigned cpu);
uint64_t take_stall_cycles(unsigned cpu); // since the last call (the livelock check)

bool active(); // any sync record seen
void print_stats();

void set_mutex_order(const std::string& mode); // "timing" or "recorded"
bool mutex_timing();
void note_mutex_record(uint64_t mutex);         // a mutex record dispatched or retired (for the printout)
bool mutex_ready(unsigned cpu, uint64_t mutex); // free and this core first? If not, the core joins the queue
void mutex_take(unsigned cpu, uint64_t mutex, bool ordered);
void mutex_release(unsigned cpu, uint64_t mutex);
void note_mutex_stall(unsigned cpu);
// Records only (lock_wait_design_2026-11-06.md): a cycle the core's acquire was held for its
// mutex (notes whether another core held it or was ahead), and the acquire taking it (counts it
// as waited, contended or own, in the core's phase).
void note_mutex_wait(unsigned cpu, uint64_t mutex, bool measured);
void note_mutex_taken(unsigned cpu, bool measured);
void print_state(); // the mutexes held or waited for (a deadlock printout)

// F-C (bench/policy_sanity/lock_fix_design_2026-11-12.md): sync_lock_word "none" (the
// default: nothing changes) or "request": on the first cycle a mutex hold is contended,
// the held core issues one ownership request for the mutex's word (the lock word), as a
// waiter's failed lock cmpxchg does natively. Own waits issue nothing.
void set_lock_word(const std::string& mode);
bool lock_word_request();
bool mutex_contended(unsigned cpu, uint64_t mutex); // another core holds it, or is ahead of this one in its queue
void note_lock_word_request(unsigned cpu, bool measured);

// A release is a fence, as an unlock or a barrier is on x86: it retires only
// when every older store of its core has been performed -- issued to the L1D
// and finished there, an ownership request to the shared cache included. Each
// core's L1D registers a check for writes it still holds.
void register_l1d_pending(unsigned cpu, std::function<bool()> has_pending_writes);
bool l1d_pending_writes(unsigned cpu);

// K2 step 3 (bench/policy_sanity/k2_sharing_gap_design_2026-11-17.md, amendment 2): a
// DIAGNOSTIC setting, never the tool's. sync_lead_limit Delta (instructions; 0, the default,
// is off: nothing is called and nothing printed). pos(c) = instructions core c has retired
// since its trace's first record. S = the cores whose dispatch head is not held by a sync
// record and which have not completed the phase. Core c is not dispatched in a cycle where
// pos(c) - min over S of pos > Delta (unless its head is sync-held); with S empty, nothing
// is held. Lead-held cycles count for the livelock check only. Records: printed when on.
void set_lead_limit(uint64_t delta);
uint64_t lead_limit();
bool lead_check(unsigned cpu, uint64_t pos);                       // stores pos; true: hold this cycle
void note_lead(unsigned cpu, bool waiting, bool held, bool measured); // this cycle's waiting flag and hold
void set_done(unsigned cpu, bool done);                            // the core has completed the phase
} // namespace champsim::sync

#endif
