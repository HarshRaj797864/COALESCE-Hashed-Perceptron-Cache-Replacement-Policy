/*
 * Copyright 2023 The ChampSim Contributors
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

#include <fstream>
#include <iostream>
#include <stdlib.h>
#include <string.h>
#include <string>
#include <map>
#include <deque>
#include <set>
#include <sstream>
#include <vector>

#include "../../inc/trace_instruction.h"
#include "pin.H"

using trace_instr_format_t = input_instr;

/* ================================================================== */
// Thread-Local Global variables
/* ================================================================== */
UINT64 instrCount[PIN_MAX_THREADS] = {0};
std::ofstream* outfiles[PIN_MAX_THREADS] = {NULL};
trace_instr_format_t curr_instr[PIN_MAX_THREADS];
// -start0: thread 0's window is closed until its first pthread_cond_broadcast;
// skip0 is then the number of its instructions before the window (not traced)
static bool start0 = false, open0 = false;
static UINT64 skip0 = 0;

/* ===================================================================== */
// Command line switches
/* ===================================================================== */
KNOB<std::string> KnobOutputFile(KNOB_MODE_WRITEONCE, "pintool", "o", "champsim.trace", "specify base file name");
// Knob names must not collide with Pin's own options. This knob was originally
// "-t", which is Pin's tool flag; it was renamed "-n" on the server, and that
// still did not take effect -- a 50000 cap produced 35 million records per
// thread. Using unambiguous long names avoids the whole class of problem.
KNOB<UINT64> KnobSkipInstructions(KNOB_MODE_WRITEONCE, "pintool", "skip_instr", "0", "Instructions to skip per thread");
KNOB<UINT64> KnobTraceInstructions(KNOB_MODE_WRITEONCE, "pintool", "max_instr", "1000000", "Instructions to trace per thread (0 = unlimited)");
// Synchronised replay (bench/policy_sanity/sync_replay_design_2026-10-18.md):
// 1 records mutexes, condition variables, barriers and thread creation as sync
// records, numbered in the native order. 0 (the default) traces exactly as before.
KNOB<UINT32> KnobSync(KNOB_MODE_WRITEONCE, "pintool", "sync", "0", "Write sync records (1) or not (0)");
// Traces recorded as on gem5's CPU (bench/policy_sanity/stream_fix_design_2026-11-02.md, F2):
// every CPUID instruction answers from FILE (cpuid_dump's output, run in gem5), so
// glibc picks the routines it picks under gem5. Unset (the default), nothing changes.
KNOB<std::string> KnobCpuid(KNOB_MODE_WRITEONCE, "pintool", "cpuid", "", "answer CPUID from this file (cpuid_dump's output)");
// Held-out set 2, facesim (bench/policy_sanity/heldout2_design_2026-11-04.md, Note 4):
// "broadcast" opens thread 0's window at its first pthread_cond_broadcast, where
// its parallel work starts, instead of at -skip_instr; thread 0's base record is
// written there, before that call's release is numbered, so the threads woken by
// it wait for it in a replay. Other threads keep -skip_instr. Unset (the
// default), nothing changes.
KNOB<std::string> KnobStart0(KNOB_MODE_WRITEONCE, "pintool", "start0", "", "open thread 0's window at its first call of this kind: broadcast");

/* ================================================================== */
// CPUID emulation: the code of simulator/tracer/stream_count/stream_count.cpp,
// copied verbatim (its lock renamed), so the counter and the tracer answer alike
/* ================================================================== */
struct Regs { UINT32 a, b, c, d; };
static std::map<std::pair<UINT32, UINT32>, Regs> cpuid_table;
static std::map<UINT32, bool> cpuid_flat; // leaf -> every subleaf in FILE reads the same (the CPU ignores ECX)
static bool emulate = false;
static UINT32 cpuid_leaf[PIN_MAX_THREADS], cpuid_sub[PIN_MAX_THREADS];
static UINT64 cpuid_replaced = 0, cpuid_unlisted = 0;
static std::vector<std::pair<UINT32, UINT32>> unlisted_seen;
PIN_LOCK cpuid_lock;

static VOID CpuidBefore(THREADID tid, ADDRINT eax, ADDRINT ecx)
{
    cpuid_leaf[tid] = static_cast<UINT32>(eax);
    cpuid_sub[tid] = static_cast<UINT32>(ecx);
}

static VOID CpuidAfter(THREADID tid, ADDRINT* rax, ADDRINT* rbx, ADDRINT* rcx, ADDRINT* rdx)
{
    // A leaf that ignores ECX (all its subleaves in FILE equal) answers as
    // subleaf 0 whatever ECX holds: glibc asks leaf 0 with ECX left over.
    const UINT32 leaf = cpuid_leaf[tid];
    const auto flat = cpuid_flat.find(leaf);
    const auto key = std::make_pair(leaf, (flat != cpuid_flat.end() && flat->second) ? 0u : cpuid_sub[tid]);
    auto it = cpuid_table.find(key);
    PIN_GetLock(&cpuid_lock, tid + 1);
    if (it != cpuid_table.end()) {
        *rax = it->second.a;
        *rbx = it->second.b;
        *rcx = it->second.c;
        *rdx = it->second.d;
        cpuid_replaced++;
    } else {
        *rax = *rbx = *rcx = *rdx = 0;
        cpuid_unlisted++;
        if (unlisted_seen.size() < 20)
            unlisted_seen.push_back(key);
    }
    PIN_ReleaseLock(&cpuid_lock);
}

static bool LoadCpuid(const std::string& path)
{
    std::ifstream in(path.c_str());
    if (!in)
        return false;
    std::string line;
    while (std::getline(in, line)) {
        std::istringstream s(line);
        std::string tag;
        UINT32 leaf, sub;
        Regs r;
        if (!(s >> tag) || tag != "CPUID")
            continue;
        if (s >> std::hex >> leaf >> sub >> r.a >> r.b >> r.c >> r.d)
            cpuid_table[{leaf, sub}] = r;
    }
    for (const auto& e : cpuid_table) {
        const Regs& z = cpuid_table[{e.first.first, 0}];
        const bool same = e.second.a == z.a && e.second.b == z.b && e.second.c == z.c && e.second.d == z.d;
        auto f = cpuid_flat.find(e.first.first);
        cpuid_flat[e.first.first] = (f == cpuid_flat.end() ? true : f->second) && same;
    }
    return !cpuid_table.empty();
}

static VOID CpuidFini(INT32 code, VOID* v)
{
    std::cerr << "[champsim_tracer] cpuid: replaced " << cpuid_replaced << " unlisted " << cpuid_unlisted << std::endl;
    for (const auto& u : unlisted_seen)
        std::cerr << "[champsim_tracer] cpuid: unlisted leaf " << std::hex << u.first << " subleaf " << u.second << std::dec << std::endl;
}

/* ================================================================== */
// Synchronised replay: state
/* ================================================================== */
// A sync record is an ordinary record with destination_memory[1] = SYNC_MAGIC
// (non-canonical, so no real operand carries it): destination_memory[0] the
// release it announces, source_memory[0] the release it waits for,
// source_memory[1] the kind. A release id is (seq << 8) | tid.
// A MUTEX record (lock, successful trylock, unlock, and a condition wait's
// release and re-acquire of its mutex) carries the mutex's address in
// source_memory[2]; source_memory[3] = 1 marks an ORDERED acquire, one whose
// native predecessor was a condition wait's release of that mutex
// (bench/policy_sanity/sync_mutex_design_2026-10-19.md). Every mutex acquire is
// written, even one that waited for nothing (its wait is then 0).
static const unsigned long long SYNC_MAGIC = 0x53594E4353594E43ULL;
enum SyncKind { SK_RELEASE = 1, SK_ACQUIRE = 2, SK_BASE = 3 };
enum SyncCall { SC_LOCK, SC_TRYLOCK, SC_UNLOCK, SC_CONDWAIT, SC_SIGNAL, SC_BROADCAST, SC_BARRIER, SC_BARRIER_INIT, SC_CREATE };

PIN_LOCK sync_lock;
UINT64 sync_seq = 0;                       // every release of the native run, in order
std::map<ADDRINT, UINT64> last_release;    // mutex or condition -> its last release id
std::map<ADDRINT, bool> last_is_cond;      // mutex -> was its last release a condition wait's
// A departure waits for EVERY arrival of its generation: in the native run the
// last arrival implies the others, in a replay it does not.
struct BarrierState { UINT32 n = 0; UINT32 count = 0; UINT64 gen = 0; std::map<UINT64, std::vector<UINT64>> arrivals; };
std::map<ADDRINT, BarrierState> barriers;
std::deque<UINT64> pending_create;         // create releases, for the threads they start

struct ThreadSync {
    int depth = 0;                          // nested sync calls (a condition wait re-locking) count once
    bool buffering = false;                 // an acquire's call: its instructions wait for its record
    std::vector<trace_instr_format_t> buf;
    SyncCall call = SC_LOCK;
    ADDRINT obj = 0, obj2 = 0;
    ADDRINT ip = 0;                         // the call's code address: the records' ip (never a data address)
    UINT64 rel_id = 0;                      // numbered on entry, written on exit
    UINT64 arrival_gen = 0;
    UINT64 create_wait = 0;                 // a new thread's first record waits for its create
    bool base_written = false;
    UINT64 enters = 0, exits = 0, records = 0;
    UINT64 by_call[SC_CREATE + 1] = {}; // outermost calls, by kind
};
ThreadSync tsync[PIN_MAX_THREADS];

/* ===================================================================== */
// Analysis routines
/* ===================================================================== */

void ResetCurrentInstruction(VOID* ip, THREADID tid)
{
    curr_instr[tid] = {};
    curr_instr[tid].ip = (unsigned long long int)ip;
}

BOOL ShouldWrite(THREADID tid)
{
    const UINT64 n = ++instrCount[tid];
    UINT64 skip = KnobSkipInstructions.Value();
    if (start0 && tid == 0) {
        if (!open0)
            return FALSE;
        skip = skip0;
    }
    const UINT64 cap = KnobTraceInstructions.Value();
    if (n <= skip)
        return FALSE;
    if (cap == 0)
        return TRUE; // unlimited
    return (n - skip) <= cap;
}

// Is this thread inside its traced window (past skip_instr, before max_instr)?
// Sync records are written only there; they do not count as instructions.
BOOL InWindow(THREADID tid)
{
    const UINT64 n = instrCount[tid];
    UINT64 skip = KnobSkipInstructions.Value();
    if (start0 && tid == 0) {
        if (!open0)
            return FALSE;
        skip = skip0;
    }
    const UINT64 cap = KnobTraceInstructions.Value();
    return n > skip && (cap == 0 || (n - skip) <= cap);
}

trace_instr_format_t SyncRecord(ADDRINT ip, UINT64 rel, UINT64 wait, UINT64 kind, UINT64 mutex = 0, UINT64 ordered = 0)
{
    trace_instr_format_t r = {};
    r.ip = ip;
    r.destination_memory[0] = rel;
    r.destination_memory[1] = SYNC_MAGIC;
    r.source_memory[0] = wait;
    r.source_memory[1] = kind;
    r.source_memory[2] = mutex;
    r.source_memory[3] = ordered;
    return r;
}

void RawWrite(THREADID tid, const trace_instr_format_t& r)
{
    if (outfiles[tid])
        outfiles[tid]->write(reinterpret_cast<const char*>(&r), sizeof(trace_instr_format_t));
}

// Every record goes through here. With -sync 1, a thread's first record is
// preceded by its base record (its first release id: any earlier release of
// it was skipped) and, for a created thread, an acquire on its create.
void Emit(THREADID tid, const trace_instr_format_t& r)
{
    ThreadSync& t = tsync[tid];
    if (KnobSync.Value() && !t.base_written) {
        t.base_written = true;
        PIN_GetLock(&sync_lock, tid + 1);
        const UINT64 base = ((sync_seq + 1) << 8) | (tid & 0xff);
        PIN_ReleaseLock(&sync_lock);
        RawWrite(tid, SyncRecord(r.ip, base, 0, SK_BASE));
        if (t.create_wait)
            RawWrite(tid, SyncRecord(r.ip, 0, t.create_wait, SK_ACQUIRE));
    }
    if (t.buffering)
        t.buf.push_back(r);
    else
        RawWrite(tid, r);
}

void WriteCurrentInstruction(THREADID tid)
{
    Emit(tid, curr_instr[tid]);
}

void EmitSync(THREADID tid, ADDRINT ip, UINT64 rel, UINT64 wait, UINT64 kind, UINT64 mutex = 0, UINT64 ordered = 0)
{
    if (!InWindow(tid))
        return;
    ++tsync[tid].records;
    Emit(tid, SyncRecord(ip, rel, wait, kind, mutex, ordered));
}

// End an acquire's call: its records first, then the call's held instructions.
void Release(THREADID tid)
{
    ThreadSync& t = tsync[tid];
    t.buffering = false;
    for (const auto& r : t.buf)
        Emit(tid, r);
    t.buf.clear();
}

UINT64 NewRelease(THREADID tid) // under sync_lock
{
    return ((++sync_seq) << 8) | (tid & 0xff);
}

// -start0: thread 0's first pthread_cond_broadcast (outermost) opens its window.
// Its base record is written now, BEFORE the call's release is numbered, so that
// release is inside the trace: a thread it woke waits for it in a replay. (Emit
// would write the base only at the first record, after the numbering, and the
// release would then count as already done.) Every earlier release of thread 0
// is before the base, so it counts as done; nothing of thread 0 before the window
// is in its trace.
void Open0(THREADID tid, ADDRINT ip)
{
    open0 = true;
    skip0 = instrCount[tid];
    UINT64 base = 0;
    if (KnobSync.Value() && !tsync[tid].base_written) {
        tsync[tid].base_written = true;
        PIN_GetLock(&sync_lock, tid + 1);
        base = ((sync_seq + 1) << 8) | (tid & 0xff);
        PIN_ReleaseLock(&sync_lock);
        RawWrite(tid, SyncRecord(ip, base, 0, SK_BASE));
    }
    std::cerr << "[champsim_tracer] start0: thread 0's window opens after " << skip0 << " of its instructions, at its first pthread_cond_broadcast"
              << " (base release seq " << (base >> 8) << ")" << std::endl;
}

VOID SyncEnter(THREADID tid, UINT32 call, ADDRINT a0, ADDRINT a1, ADDRINT a2, ADDRINT ip)
{
    ThreadSync& t = tsync[tid];
    ++t.enters;
    if (t.depth++ > 0)
        return;
    if (start0 && !open0 && tid == 0 && call == SC_BROADCAST)
        Open0(tid, ip);
    t.call = static_cast<SyncCall>(call);
    if (call <= SC_CREATE)
        ++t.by_call[call];
    t.ip = ip;
    t.obj = a0;
    t.obj2 = a1;
    switch (t.call) {
    case SC_LOCK:
    case SC_TRYLOCK:
        t.buffering = true;
        break;
    case SC_UNLOCK:
    case SC_SIGNAL:
    case SC_BROADCAST:
        PIN_GetLock(&sync_lock, tid + 1);
        t.rel_id = NewRelease(tid);
        last_release[a0] = t.rel_id;
        last_is_cond[a0] = false;
        PIN_ReleaseLock(&sync_lock);
        break;
    case SC_CONDWAIT: // releases the mutex (a1), then waits on the condition (a0)
        PIN_GetLock(&sync_lock, tid + 1);
        t.rel_id = NewRelease(tid);
        last_release[a1] = t.rel_id;
        last_is_cond[a1] = true;
        PIN_ReleaseLock(&sync_lock);
        t.buffering = true;
        break;
    case SC_BARRIER: {
        PIN_GetLock(&sync_lock, tid + 1);
        const UINT64 id = NewRelease(tid);
        BarrierState& b = barriers[a0];
        t.arrival_gen = b.gen;
        b.arrivals[b.gen].push_back(id);
        if (b.n && ++b.count >= b.n) { // the last arrival closes this generation (n unknown: one generation)
            ++b.gen;
            b.count = 0;
        }
        PIN_ReleaseLock(&sync_lock);
        EmitSync(tid, ip, id, 0, SK_RELEASE); // the arrival, before the call's instructions
        t.buffering = true;
        break;
    }
    case SC_BARRIER_INIT:
        PIN_GetLock(&sync_lock, tid + 1);
        barriers[a0] = BarrierState();
        barriers[a0].n = static_cast<UINT32>(a2);
        PIN_ReleaseLock(&sync_lock);
        break;
    case SC_CREATE: {
        PIN_GetLock(&sync_lock, tid + 1);
        const UINT64 id = NewRelease(tid);
        pending_create.push_back(id);
        PIN_ReleaseLock(&sync_lock);
        EmitSync(tid, ip, id, 0, SK_RELEASE);
        break;
    }
    }
}

VOID SyncExit(THREADID tid, ADDRINT ret)
{
    ThreadSync& t = tsync[tid];
    ++t.exits;
    if (t.depth == 0 || --t.depth > 0)
        return;
    const ADDRINT ip = t.ip;
    UINT64 w1 = 0, w2 = 0;
    bool ord = false;
    switch (t.call) {
    case SC_LOCK:
    case SC_TRYLOCK:
        if (t.call == SC_LOCK || ret == 0) {
            PIN_GetLock(&sync_lock, tid + 1);
            w1 = last_release.count(t.obj) ? last_release[t.obj] : 0;
            ord = w1 && last_is_cond[t.obj];
            PIN_ReleaseLock(&sync_lock);
            t.buffering = false; // the acquire goes before the held instructions
            EmitSync(tid, ip, 0, w1, SK_ACQUIRE, t.obj, ord ? 1 : 0); // every mutex acquire, even one that waited for nothing
        }
        Release(tid);
        break;
    case SC_UNLOCK:
        EmitSync(tid, ip, t.rel_id, 0, SK_RELEASE, t.obj); // after the call's instructions
        break;
    case SC_SIGNAL:
    case SC_BROADCAST:
        EmitSync(tid, ip, t.rel_id, 0, SK_RELEASE); // after the call's instructions
        break;
    case SC_CONDWAIT:
        PIN_GetLock(&sync_lock, tid + 1);
        w1 = last_release.count(t.obj) ? last_release[t.obj] : 0;   // the signal that woke it
        w2 = last_release.count(t.obj2) ? last_release[t.obj2] : 0; // the mutex it re-acquired
        if (w2 == t.rel_id)
            w2 = 0;                                                   // nobody took the mutex meanwhile
        ord = w2 && last_is_cond[t.obj2];
        PIN_ReleaseLock(&sync_lock);
        t.buffering = false;
        EmitSync(tid, ip, t.rel_id, 0, SK_RELEASE, t.obj2);         // the mutex, released on entry
        if (w1)
            EmitSync(tid, ip, 0, w1, SK_ACQUIRE);
        EmitSync(tid, ip, 0, w2, SK_ACQUIRE, t.obj2, ord ? 1 : 0); // and re-acquired
        Release(tid);
        break;
    case SC_BARRIER: {
        PIN_GetLock(&sync_lock, tid + 1);
        const std::vector<UINT64> all = barriers[t.obj].arrivals[t.arrival_gen];
        PIN_ReleaseLock(&sync_lock);
        t.buffering = false;
        for (UINT64 a : all)
            if ((a & 0xff) != (tid & 0xff)) // its own arrival is earlier in its own trace
                EmitSync(tid, ip, 0, a, SK_ACQUIRE);
        Release(tid);
        break;
    }
    case SC_BARRIER_INIT:
    case SC_CREATE:
        break;
    }
}

std::set<ADDRINT> sync_instrumented;

VOID ImageLoad(IMG img, VOID* v)
{
    static const struct { const char* name; SyncCall call; } calls[] = {
        {"pthread_mutex_lock", SC_LOCK},       {"pthread_mutex_trylock", SC_TRYLOCK},   {"pthread_mutex_unlock", SC_UNLOCK},
        {"pthread_cond_wait", SC_CONDWAIT},    {"pthread_cond_timedwait", SC_CONDWAIT}, {"pthread_cond_signal", SC_SIGNAL},
        {"pthread_cond_broadcast", SC_BROADCAST}, {"pthread_barrier_wait", SC_BARRIER}, {"pthread_barrier_init", SC_BARRIER_INIT},
        {"pthread_create", SC_CREATE},
    };
    // Each routine is found TWO ways, and instrumented once per address:
    //  - by name (RTN_FindByName), which also matches an alias: on an older
    //    glibc (the server's) pthread_mutex_lock/unlock live in libpthread
    //    under another primary name, and only this lookup finds them;
    //  - every routine whose own name, symbol version stripped, matches: glibc
    //    keeps an old pthread_cond_* (GLIBC_2.2.5) at another address beside
    //    the one programs call (GLIBC_2.3.2), and a lookup by name finds only
    //    one of them.
    // Either alone failed somewhere: by name alone missed condition variables
    // on the laptop's glibc (mutex_micro, 2026-10-19); by routine name alone
    // missed every mutex lock and unlock on the server's (the m2 traces,
    // 2026-10-20: lock 0, unlock 0 on every thread, and every SPLASH-3 run
    // deadlocked). A nested call (one version calling the other, or libc's
    // forwarder calling libpthread's) is recorded once: SyncEnter counts depth.
    auto instrument = [&img](RTN rtn, const char* name, SyncCall call) {
        if (!RTN_Valid(rtn) || sync_instrumented.count(RTN_Address(rtn)))
            return;
        sync_instrumented.insert(RTN_Address(rtn));
        RTN_Open(rtn);
        RTN_InsertCall(rtn, IPOINT_BEFORE, (AFUNPTR)SyncEnter, IARG_THREAD_ID, IARG_UINT32, (UINT32)call, IARG_FUNCARG_ENTRYPOINT_VALUE, 0,
                       IARG_FUNCARG_ENTRYPOINT_VALUE, 1, IARG_FUNCARG_ENTRYPOINT_VALUE, 2, IARG_INST_PTR, IARG_END);
        RTN_InsertCall(rtn, IPOINT_AFTER, (AFUNPTR)SyncExit, IARG_THREAD_ID, IARG_FUNCRET_EXITPOINT_VALUE, IARG_END);
        RTN_Close(rtn);
        std::cerr << "[champsim_tracer] sync: " << name << " (routine " << RTN_Name(rtn) << ") at " << std::hex << RTN_Address(rtn) << std::dec << " in "
                  << IMG_Name(img) << std::endl;
    };
    for (const auto& c : calls)
        instrument(RTN_FindByName(img, c.name), c.name, c.call);
    for (SEC sec = IMG_SecHead(img); SEC_Valid(sec); sec = SEC_Next(sec)) {
        for (RTN rtn = SEC_RtnHead(sec); RTN_Valid(rtn); rtn = RTN_Next(rtn)) {
            const std::string full = RTN_Name(rtn);
            const std::string base = full.substr(0, full.find('@'));
            for (const auto& c : calls)
                if (base == c.name)
                    instrument(rtn, c.name, c.call);
        }
    }
}

void BranchOrNot(UINT32 taken, THREADID tid)
{
    curr_instr[tid].is_branch = 1;
    curr_instr[tid].branch_taken = taken;
}

template <typename T>
void WriteToSet(T* begin, T* end, T r)
{
    auto set_end = std::find(begin, end, 0);
    auto found_reg = std::find(begin, set_end, r); // already present?
    if (found_reg != end)                          // guard: set may be full
        *found_reg = r;
}

/* The analysis routines below MUST take THREADID and index curr_instr
 * themselves. An earlier version passed `curr_instr[0].<field>` straight to
 * INS_InsertCall as IARG_PTR, but IARG_PTR binds its value once at
 * instrumentation time -- so every thread's operands landed in thread 0's
 * buffer, while ResetCurrentInstruction/WriteCurrentInstruction correctly used
 * curr_instr[tid]. Every thread but 0 therefore emitted instructions with no
 * memory operands at all, and thread 0's stream collected races from all the
 * others. Do not reintroduce pointer-passing here. */

void WriteSourceReg(UINT32 r, THREADID tid)
{
    auto* begin = curr_instr[tid].source_registers;
    WriteToSet<unsigned char>(begin, begin + NUM_INSTR_SOURCES, static_cast<unsigned char>(r));
}

void WriteDestReg(UINT32 r, THREADID tid)
{
    auto* begin = curr_instr[tid].destination_registers;
    WriteToSet<unsigned char>(begin, begin + NUM_INSTR_DESTINATIONS, static_cast<unsigned char>(r));
}

void WriteSourceMem(ADDRINT addr, THREADID tid)
{
    auto* begin = curr_instr[tid].source_memory;
    WriteToSet<unsigned long long int>(begin, begin + NUM_INSTR_SOURCES, static_cast<unsigned long long int>(addr));
}

void WriteDestMem(ADDRINT addr, THREADID tid)
{
    auto* begin = curr_instr[tid].destination_memory;
    WriteToSet<unsigned long long int>(begin, begin + NUM_INSTR_DESTINATIONS, static_cast<unsigned long long int>(addr));
}

/* ===================================================================== */
// Instrumentation callbacks
/* ===================================================================== */

VOID Instruction(INS ins, VOID* v)
{
    // -cpuid: the CPUID's answer is replaced after it runs; its record is written as always
    if (emulate && INS_Opcode(ins) == XED_ICLASS_CPUID) {
        INS_InsertCall(ins, IPOINT_BEFORE, (AFUNPTR)CpuidBefore, IARG_THREAD_ID, IARG_REG_VALUE, REG_GAX, IARG_REG_VALUE, REG_GCX, IARG_END);
        INS_InsertCall(ins, IPOINT_AFTER, (AFUNPTR)CpuidAfter, IARG_THREAD_ID, IARG_REG_REFERENCE, REG_GAX, IARG_REG_REFERENCE, REG_GBX,
                       IARG_REG_REFERENCE, REG_GCX, IARG_REG_REFERENCE, REG_GDX, IARG_END);
    }

    INS_InsertCall(ins, IPOINT_BEFORE, (AFUNPTR)ResetCurrentInstruction, IARG_INST_PTR, IARG_THREAD_ID, IARG_END);

    if (INS_IsBranch(ins))
        INS_InsertCall(ins, IPOINT_BEFORE, (AFUNPTR)BranchOrNot, IARG_BRANCH_TAKEN, IARG_THREAD_ID, IARG_END);

    // Register reads
    for (UINT32 i = 0; i < INS_MaxNumRRegs(ins); i++)
        INS_InsertCall(ins, IPOINT_BEFORE, (AFUNPTR)WriteSourceReg, IARG_UINT32, INS_RegR(ins, i), IARG_THREAD_ID, IARG_END);

    // Register writes -- upstream instruments these; the MT rewrite had dropped
    // them entirely, so destination_registers was always empty.
    for (UINT32 i = 0; i < INS_MaxNumWRegs(ins); i++)
        INS_InsertCall(ins, IPOINT_BEFORE, (AFUNPTR)WriteDestReg, IARG_UINT32, INS_RegW(ins, i), IARG_THREAD_ID, IARG_END);

    // Memory operands
    for (UINT32 memOp = 0; memOp < INS_MemoryOperandCount(ins); memOp++) {
        if (INS_MemoryOperandIsRead(ins, memOp))
            INS_InsertCall(ins, IPOINT_BEFORE, (AFUNPTR)WriteSourceMem, IARG_MEMORYOP_EA, memOp, IARG_THREAD_ID, IARG_END);
        if (INS_MemoryOperandIsWritten(ins, memOp))
            INS_InsertCall(ins, IPOINT_BEFORE, (AFUNPTR)WriteDestMem, IARG_MEMORYOP_EA, memOp, IARG_THREAD_ID, IARG_END);
    }

    INS_InsertIfCall(ins, IPOINT_BEFORE, (AFUNPTR)ShouldWrite, IARG_THREAD_ID, IARG_END);
    INS_InsertThenCall(ins, IPOINT_BEFORE, (AFUNPTR)WriteCurrentInstruction, IARG_THREAD_ID, IARG_END);
}

// Called every time a new thread starts
VOID ThreadStart(THREADID tid, CONTEXT* ctxt, INT32 flags, VOID* v)
{
    std::string filename = KnobOutputFile.Value() + std::to_string(tid) + ".champsimtrace";
    outfiles[tid] = new std::ofstream(filename.c_str(), std::ios_base::binary | std::ios_base::trunc);
    if (KnobSync.Value()) {
        PIN_GetLock(&sync_lock, tid + 1);
        if (!pending_create.empty()) { // the create this thread starts from (one creating thread at a time)
            tsync[tid].create_wait = pending_create.front();
            pending_create.pop_front();
        }
        PIN_ReleaseLock(&sync_lock);
    }
    if (!outfiles[tid] || !outfiles[tid]->is_open()) { // `new` throws rather than returning null; check the stream
        std::cerr << "Couldn't open output trace file for thread " << tid << std::endl;
        exit(1);
    }
}

// Called when a thread finishes
VOID ThreadFini(THREADID tid, const CONTEXT* ctxt, INT32 code, VOID* v)
{
    if (start0 && tid == 0)
        std::cerr << "[champsim_tracer] start0: thread 0 executed " << instrCount[0] << " instructions; "
                  << (open0 ? "its window opened after " + std::to_string(skip0) : std::string("its window NEVER opened (no pthread_cond_broadcast)")) << std::endl;
    if (KnobSync.Value()) {
        Release(tid); // anything still held (a thread ending inside a call)
        std::cerr << "[champsim_tracer] sync: thread " << tid << " calls entered " << tsync[tid].enters << ", returned " << tsync[tid].exits
                  << ", records written " << tsync[tid].records << (tsync[tid].enters != tsync[tid].exits ? "  <-- UNBALANCED" : "") << std::endl;
        const UINT64* b = tsync[tid].by_call;
        std::cerr << "[champsim_tracer] sync: thread " << tid << " calls: lock " << b[SC_LOCK] << " trylock " << b[SC_TRYLOCK] << " unlock " << b[SC_UNLOCK]
                  << " cond_wait " << b[SC_CONDWAIT] << " signal " << b[SC_SIGNAL] << " broadcast " << b[SC_BROADCAST] << " barrier " << b[SC_BARRIER]
                  << " create " << b[SC_CREATE] << std::endl;
    }
    if (outfiles[tid]) {
        outfiles[tid]->close();
        delete outfiles[tid];
        outfiles[tid] = NULL;
    }
}

int main(int argc, char* argv[])
{
    if (PIN_Init(argc, argv)) return -1;

    std::cerr << "[champsim_tracer] output prefix = " << KnobOutputFile.Value()
              << ", skip_instr = " << KnobSkipInstructions.Value()
              << ", max_instr = " << KnobTraceInstructions.Value()
              << (KnobTraceInstructions.Value() == 0 ? " (unlimited)" : "") << ", sync = " << KnobSync.Value() << std::endl;

    if (!KnobCpuid.Value().empty()) {
        if (!LoadCpuid(KnobCpuid.Value())) {
            std::cerr << "[champsim_tracer] no CPUID lines in " << KnobCpuid.Value() << std::endl;
            PIN_ExitProcess(1); // a plain return leaves pin's exit status 0, and no trace
        }
        emulate = true;
        PIN_InitLock(&cpuid_lock);
        PIN_AddFiniFunction(CpuidFini, 0);
        std::cerr << "[champsim_tracer] cpuid = " << KnobCpuid.Value() << " (" << cpuid_table.size() << " leaf/subleaf pairs)" << std::endl;
    }

    if (!KnobStart0.Value().empty()) {
        if (KnobStart0.Value() != "broadcast" || !KnobSync.Value()) {
            std::cerr << "[champsim_tracer] -start0 takes only \"broadcast\", and needs -sync 1" << std::endl;
            PIN_ExitProcess(1);
        }
        start0 = true;
        std::cerr << "[champsim_tracer] start0 = broadcast: thread 0's window opens at its first pthread_cond_broadcast" << std::endl;
    }

    if (KnobSync.Value()) {
        PIN_InitSymbols(); // routines by name
        PIN_InitLock(&sync_lock);
        IMG_AddInstrumentFunction(ImageLoad, 0);
    }
    PIN_AddThreadStartFunction(ThreadStart, 0);
    INS_AddInstrumentFunction(Instruction, 0);
    PIN_AddThreadFiniFunction(ThreadFini, 0);

    PIN_StartProgram();
    return 0;
}
