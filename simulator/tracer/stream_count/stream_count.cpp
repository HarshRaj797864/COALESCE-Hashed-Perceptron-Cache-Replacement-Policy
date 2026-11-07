/*
 * stream_count: a per-thread instruction-mix counter for the same-stream check
 * (bench/policy_sanity/stream_fix_design_2026-11-02.md).
 *
 * It counts every instruction where champsim_tracer writes a record
 * (IPOINT_BEFORE, so every iteration of a REP-prefixed instruction), per
 * thread, in two units:
 *   record units, as scripts/trace_mix.c counts a trace
 *     rec    instructions (a trace's records, its sync records aside)
 *     ld     instructions with a memory read
 *     st     instructions with a memory write
 *     rmw    instructions with a memory operand both read and written
 *   gem5 units, as gem5's TimingSimpleCPU commits them
 *     ginst  instructions, a REP-prefixed one once (its first iteration)
 *     gld    read micro-ops: each read operand, ceil(size / 8)
 *     gst    write micro-ops: each written operand, ceil(size / 8)
 *   and rep, the REP iterations among rec.
 *
 * Files, for -o P:
 *   P.t<tid>.cnt   C rec ld st rmw ginst gld gst rep   every -step instructions: the counts before that one
 *                  T rec ld st rmw ginst gld gst rep   at the thread's end
 *   P.t<tid>.rtn   A|W|S records ld st rep gld gst rep_gst image routine
 *                  (rep_gst: the write micro-ops of REP iterations)
 *                  A: the thread's whole run
 *                  W: the thread's window [base + from, base + to), base = -skip;
 *                     for thread 0 with -cut0 1 (the default), its position at
 *                     its latest pthread_create
 *                  S: thread 0 before its first pthread_create (its serial start);
 *                     with -base0 broadcast, before its first broadcast
 *   P.summary      the knobs; CREATE tid rec ginst for each pthread_create;
 *                  BROADCAST tid rec ginst at each thread's first (outermost)
 *                  pthread_cond_broadcast, the counts before its first
 *                  instruction; with -base0 broadcast, BASE0 broadcast rec
 *                  (or BASE0 broadcast NEVER); HOOK pthread_cond_broadcast
 *                  routine address, for each version hooked; CPUID replaced /
 *                  unlisted counts
 *
 * -base0 broadcast (held-out set 2, facesim: heldout2_design_2026-11-04.md,
 * Note 5): thread 0's window base is its first pthread_cond_broadcast, where
 * the tracer's -start0 broadcast opens its trace; a pthread_create does not
 * move it. Thread 0's W is [base + from, base + to) and its S everything before
 * the broadcast, whether or not it has created a thread. Unset (the default), the
 * window is as before and the summary only gains the BROADCAST and HOOK lines.
 *
 * -cpuid FILE: every CPUID instruction returns FILE's values for its leaf and
 * subleaf. FILE's lines "CPUID leaf subleaf eax ebx ecx edx" (hex) are what
 * cpuid_dump prints; other lines are ignored. A leaf whose subleaves in FILE
 * all read the same ignores ECX (as the CPU does: glibc asks leaf 0 with ECX
 * left over). A leaf/subleaf FILE lacks returns zeros and is counted (and the
 * first 20 are listed).
 */
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iostream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

#include "pin.H"

KNOB<std::string> KnobOut(KNOB_MODE_WRITEONCE, "pintool", "o", "count", "output prefix");
KNOB<UINT64> KnobStep(KNOB_MODE_WRITEONCE, "pintool", "step", "100000", "instructions between running counts");
KNOB<UINT64> KnobSkip(KNOB_MODE_WRITEONCE, "pintool", "skip", "0", "every thread's window starts after this many instructions");
KNOB<UINT64> KnobFrom(KNOB_MODE_WRITEONCE, "pintool", "from", "50000000", "window start, after skip (and thread 0's last create)");
KNOB<UINT64> KnobTo(KNOB_MODE_WRITEONCE, "pintool", "to", "150000000", "window end");
KNOB<UINT32> KnobCut0(KNOB_MODE_WRITEONCE, "pintool", "cut0", "1", "thread 0's window counts from its latest pthread_create (1) or from -skip (0)");
KNOB<std::string> KnobCpuid(KNOB_MODE_WRITEONCE, "pintool", "cpuid", "", "answer CPUID from this file (cpuid_dump's output)");
KNOB<std::string> KnobBase0(KNOB_MODE_WRITEONCE, "pintool", "base0", "", "broadcast: thread 0's window base is its first pthread_cond_broadcast");

enum { REC, LD, ST, RMW, GINST, GLD, GST, REP, NC };

struct InsInfo {
    UINT32 rtn;
    UINT32 rreq, wreq;
    UINT8 ld, st, rmw, rep;
};

struct RtnCount {
    UINT64 c[7] = {}; // records ld st rep gld gst rep_gst
};

struct TData {
    UINT64 c[NC] = {};
    UINT64 next = 0;
    UINT64 base = 0;     // the window's base: -skip, plus thread 0's latest create
    bool created = false; // thread 0: has it called pthread_create yet
    int create_depth = 0;
    bool bcast_seen = false; // has it entered pthread_cond_broadcast yet
    int bcast_depth = 0;
    FILE* f = nullptr;
    std::vector<RtnCount> all, win, setup;
};

static TData* td[PIN_MAX_THREADS] = {};
static UINT64 step_, skip_, from_, to_;
static bool cut0_;
static bool base0_bcast_ = false;

// routines, by id (instrumentation runs under Pin's lock, one at a time)
static std::vector<std::string> rtn_names;
static std::map<std::string, UINT32> rtn_ids;

static PIN_LOCK out_lock;
static FILE* summary = nullptr;

// CPUID
struct Regs { UINT32 a, b, c, d; };
static std::map<std::pair<UINT32, UINT32>, Regs> cpuid_table;
static std::map<UINT32, bool> cpuid_flat; // leaf -> every subleaf in FILE reads the same (the CPU ignores ECX)
static bool emulate = false;
static UINT32 cpuid_leaf[PIN_MAX_THREADS], cpuid_sub[PIN_MAX_THREADS];
static UINT64 cpuid_replaced = 0, cpuid_unlisted = 0;
static std::vector<std::pair<UINT32, UINT32>> unlisted_seen;

static std::string Base(const std::string& path)
{
    const size_t s = path.rfind('/');
    return s == std::string::npos ? path : path.substr(s + 1);
}

static UINT32 RtnId(INS ins)
{
    std::string key = "? ?";
    RTN rtn = INS_Rtn(ins);
    if (RTN_Valid(rtn)) {
        IMG img = SEC_Img(RTN_Sec(rtn));
        key = (IMG_Valid(img) ? Base(IMG_Name(img)) : std::string("?")) + " " + RTN_Name(rtn);
    } else {
        IMG img = IMG_FindByAddress(INS_Address(ins));
        if (IMG_Valid(img))
            key = Base(IMG_Name(img)) + " ?";
    }
    auto it = rtn_ids.find(key);
    if (it != rtn_ids.end())
        return it->second;
    const UINT32 id = static_cast<UINT32>(rtn_names.size());
    rtn_names.push_back(key);
    rtn_ids[key] = id;
    return id;
}

static void Line(TData& t, char kind)
{
    fprintf(t.f, "%c", kind);
    for (int i = 0; i < NC; i++)
        fprintf(t.f, " %llu", (unsigned long long)t.c[i]);
    fprintf(t.f, "\n");
}

static inline void Add(std::vector<RtnCount>& v, const InsInfo* ii)
{
    if (ii->rtn >= v.size())
        v.resize(ii->rtn + 1024);
    UINT64* r = v[ii->rtn].c;
    r[0]++;
    r[1] += ii->ld;
    r[2] += ii->st;
    r[3] += ii->rep;
    r[4] += ii->rreq;
    r[5] += ii->wreq;
    r[6] += ii->rep ? ii->wreq : 0;
}

static VOID Count(THREADID tid, const InsInfo* ii, BOOL first)
{
    TData& t = *td[tid];
    if (t.c[REC] == t.next) {
        Line(t, 'C');
        t.next += step_;
    }
    const UINT64 pos = t.c[REC];
    t.c[REC]++;
    t.c[LD] += ii->ld;
    t.c[ST] += ii->st;
    t.c[RMW] += ii->rmw;
    t.c[GINST] += (!ii->rep || first) ? 1 : 0;
    t.c[GLD] += ii->rreq;
    t.c[GST] += ii->wreq;
    t.c[REP] += ii->rep;

    Add(t.all, ii);
    if (tid == 0 && base0_bcast_) { // -base0 broadcast: the serial start is everything before the first broadcast
        if (!t.bcast_seen)
            Add(t.setup, ii);
        else if (pos >= t.base + from_ && pos < t.base + to_)
            Add(t.win, ii);
    } else if (tid == 0 && !t.created) // the serial start first: thread 0's window counts from a create
        Add(t.setup, ii);
    else if (pos >= t.base + from_ && pos < t.base + to_)
        Add(t.win, ii);
}

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
    PIN_GetLock(&out_lock, tid + 1);
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
    PIN_ReleaseLock(&out_lock);
}

static VOID CreateEnter(THREADID tid)
{
    TData& t = *td[tid];
    if (t.create_depth++ > 0)
        return;
    PIN_GetLock(&out_lock, tid + 1);
    fprintf(summary, "CREATE %u %llu %llu\n", tid, (unsigned long long)t.c[REC], (unsigned long long)t.c[GINST]);
    fflush(summary);
    PIN_ReleaseLock(&out_lock);
    t.created = true;
    if (tid == 0 && cut0_ && !base0_bcast_)
        t.base = t.c[REC];
}

static VOID CreateExit(THREADID tid)
{
    TData& t = *td[tid];
    if (t.create_depth > 0)
        t.create_depth--;
}

// A thread's first outermost pthread_cond_broadcast: called before the
// routine's first instruction is counted, so the position is the count before
// it, as the tracer's K under -start0 broadcast (Note 5's QR checks the two
// are equal).
static VOID BcastEnter(THREADID tid)
{
    TData& t = *td[tid];
    if (t.bcast_depth++ > 0 || t.bcast_seen)
        return;
    t.bcast_seen = true;
    PIN_GetLock(&out_lock, tid + 1);
    fprintf(summary, "BROADCAST %u %llu %llu\n", tid, (unsigned long long)t.c[REC], (unsigned long long)t.c[GINST]);
    if (tid == 0 && base0_bcast_)
        fprintf(summary, "BASE0 broadcast %llu\n", (unsigned long long)t.c[REC]);
    fflush(summary);
    PIN_ReleaseLock(&out_lock);
    if (tid == 0 && base0_bcast_)
        t.base = t.c[REC];
}

static VOID BcastExit(THREADID tid)
{
    TData& t = *td[tid];
    if (t.bcast_depth > 0)
        t.bcast_depth--;
}

static VOID Instruction(INS ins, VOID*)
{
    if (emulate && INS_Opcode(ins) == XED_ICLASS_CPUID) {
        INS_InsertCall(ins, IPOINT_BEFORE, (AFUNPTR)CpuidBefore, IARG_THREAD_ID, IARG_REG_VALUE, REG_GAX, IARG_REG_VALUE, REG_GCX, IARG_END);
        INS_InsertCall(ins, IPOINT_AFTER, (AFUNPTR)CpuidAfter, IARG_THREAD_ID, IARG_REG_REFERENCE, REG_GAX, IARG_REG_REFERENCE, REG_GBX,
                       IARG_REG_REFERENCE, REG_GCX, IARG_REG_REFERENCE, REG_GDX, IARG_END);
    }

    InsInfo* ii = new InsInfo(); // static facts of this instruction, kept for the run
    ii->rtn = RtnId(ins);
    for (UINT32 m = 0; m < INS_MemoryOperandCount(ins); m++) {
        const UINT32 req = static_cast<UINT32>((INS_MemoryOperandSize(ins, m) + 7) / 8);
        const bool r = INS_MemoryOperandIsRead(ins, m), w = INS_MemoryOperandIsWritten(ins, m);
        if (r) {
            ii->ld = 1;
            ii->rreq += req ? req : 1;
        }
        if (w) {
            ii->st = 1;
            ii->wreq += req ? req : 1;
        }
        if (r && w)
            ii->rmw = 1;
    }
    ii->rep = INS_HasRealRep(ins) ? 1 : 0;
    if (ii->rep)
        INS_InsertCall(ins, IPOINT_BEFORE, (AFUNPTR)Count, IARG_THREAD_ID, IARG_PTR, ii, IARG_FIRST_REP_ITERATION, IARG_END);
    else
        INS_InsertCall(ins, IPOINT_BEFORE, (AFUNPTR)Count, IARG_THREAD_ID, IARG_PTR, ii, IARG_BOOL, TRUE, IARG_END);
}

static std::map<ADDRINT, bool> create_done, bcast_done;

static VOID ImageLoad(IMG img, VOID*)
{
    // pthread_create, found by name and by every routine whose name (version
    // stripped) matches, as the tracer finds its sync calls; once per address
    auto hook = [](RTN rtn) {
        if (!RTN_Valid(rtn) || create_done.count(RTN_Address(rtn)))
            return;
        create_done[RTN_Address(rtn)] = true;
        RTN_Open(rtn);
        RTN_InsertCall(rtn, IPOINT_BEFORE, (AFUNPTR)CreateEnter, IARG_THREAD_ID, IARG_END);
        RTN_InsertCall(rtn, IPOINT_AFTER, (AFUNPTR)CreateExit, IARG_THREAD_ID, IARG_END);
        RTN_Close(rtn);
    };
    // pthread_cond_broadcast, the same two ways (glibc keeps two versions at
    // different addresses; a nested call is counted once by its depth)
    auto hookb = [](RTN rtn) {
        if (!RTN_Valid(rtn) || bcast_done.count(RTN_Address(rtn)))
            return;
        bcast_done[RTN_Address(rtn)] = true;
        RTN_Open(rtn);
        RTN_InsertCall(rtn, IPOINT_BEFORE, (AFUNPTR)BcastEnter, IARG_THREAD_ID, IARG_END);
        RTN_InsertCall(rtn, IPOINT_AFTER, (AFUNPTR)BcastExit, IARG_THREAD_ID, IARG_END);
        RTN_Close(rtn);
        PIN_GetLock(&out_lock, 1);
        fprintf(summary, "HOOK pthread_cond_broadcast %s %lx\n", RTN_Name(rtn).c_str(), (unsigned long)RTN_Address(rtn));
        fflush(summary);
        PIN_ReleaseLock(&out_lock);
    };
    hook(RTN_FindByName(img, "pthread_create"));
    hookb(RTN_FindByName(img, "pthread_cond_broadcast"));
    for (SEC sec = IMG_SecHead(img); SEC_Valid(sec); sec = SEC_Next(sec))
        for (RTN rtn = SEC_RtnHead(sec); RTN_Valid(rtn); rtn = RTN_Next(rtn)) {
            const std::string n = RTN_Name(rtn);
            if (n.substr(0, n.find('@')) == "pthread_create")
                hook(rtn);
            if (n.substr(0, n.find('@')) == "pthread_cond_broadcast")
                hookb(rtn);
        }
}

static VOID ThreadStart(THREADID tid, CONTEXT*, INT32, VOID*)
{
    TData* t = new TData();
    t->base = skip_;
    const std::string fn = KnobOut.Value() + ".t" + std::to_string(tid) + ".cnt";
    t->f = fopen(fn.c_str(), "w");
    if (!t->f) {
        std::cerr << "stream_count: cannot open " << fn << std::endl;
        PIN_ExitProcess(1);
    }
    td[tid] = t;
}

static void WriteRtn(FILE* f, char kind, const std::vector<RtnCount>& v)
{
    std::vector<std::pair<UINT64, UINT32>> order;
    for (UINT32 i = 0; i < v.size(); i++)
        if (v[i].c[0])
            order.push_back({v[i].c[0], i});
    std::sort(order.rbegin(), order.rend());
    for (const auto& o : order) {
        const UINT64* c = v[o.second].c;
        fprintf(f, "%c %llu %llu %llu %llu %llu %llu %llu %s\n", kind, (unsigned long long)c[0], (unsigned long long)c[1],
                (unsigned long long)c[2], (unsigned long long)c[3], (unsigned long long)c[4], (unsigned long long)c[5], (unsigned long long)c[6],
                rtn_names[o.second].c_str());
    }
}

static VOID ThreadFini(THREADID tid, const CONTEXT*, INT32, VOID*)
{
    TData& t = *td[tid];
    Line(t, 'T');
    if (t.create_depth != 0) {
        PIN_GetLock(&out_lock, tid + 1);
        fprintf(summary, "CREATE-UNBALANCED %u depth %d\n", tid, t.create_depth);
        PIN_ReleaseLock(&out_lock);
    }
    fclose(t.f);
    t.f = nullptr;
    const std::string fn = KnobOut.Value() + ".t" + std::to_string(tid) + ".rtn";
    FILE* f = fopen(fn.c_str(), "w");
    if (f) {
        WriteRtn(f, 'A', t.all);
        WriteRtn(f, 'W', t.win);
        WriteRtn(f, 'S', t.setup);
        fclose(f);
    }
}

static VOID Fini(INT32 code, VOID*)
{
    if (base0_bcast_ && !(td[0] && td[0]->bcast_seen))
        fprintf(summary, "BASE0 broadcast NEVER\n");
    fprintf(summary, "EXIT %d\n", code);
    if (emulate) {
        fprintf(summary, "CPUID replaced %llu unlisted %llu\n", (unsigned long long)cpuid_replaced, (unsigned long long)cpuid_unlisted);
        for (const auto& u : unlisted_seen)
            fprintf(summary, "CPUID unlisted leaf %x subleaf %x\n", u.first, u.second);
    }
    fclose(summary);
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

int main(int argc, char* argv[])
{
    PIN_InitSymbols();
    if (PIN_Init(argc, argv)) {
        std::cerr << KNOB_BASE::StringKnobSummary() << std::endl;
        return 1;
    }
    step_ = KnobStep.Value() ? KnobStep.Value() : 100000;
    skip_ = KnobSkip.Value();
    from_ = KnobFrom.Value();
    to_ = KnobTo.Value();
    cut0_ = KnobCut0.Value() != 0;
    if (!KnobBase0.Value().empty()) {
        if (KnobBase0.Value() != "broadcast") {
            std::cerr << "stream_count: -base0 takes only \"broadcast\"" << std::endl;
            return 1;
        }
        base0_bcast_ = true;
    }
    PIN_InitLock(&out_lock);
    summary = fopen((KnobOut.Value() + ".summary").c_str(), "w");
    if (!summary) {
        std::cerr << "stream_count: cannot open the summary" << std::endl;
        return 1;
    }
    if (!KnobCpuid.Value().empty()) {
        if (!LoadCpuid(KnobCpuid.Value())) {
            std::cerr << "stream_count: no CPUID lines in " << KnobCpuid.Value() << std::endl;
            return 1;
        }
        emulate = true;
    }
    fprintf(summary, "KNOBS step %llu skip %llu from %llu to %llu cut0 %d cpuid %s (%zu leaf/subleaf pairs)\n", (unsigned long long)step_,
            (unsigned long long)skip_, (unsigned long long)from_, (unsigned long long)to_, cut0_ ? 1 : 0,
            emulate ? KnobCpuid.Value().c_str() : "host", cpuid_table.size());
    if (base0_bcast_)
        fprintf(summary, "KNOBS base0 broadcast\n");
    fflush(summary);

    IMG_AddInstrumentFunction(ImageLoad, 0);
    INS_AddInstrumentFunction(Instruction, 0);
    PIN_AddThreadStartFunction(ThreadStart, 0);
    PIN_AddThreadFiniFunction(ThreadFini, 0);
    PIN_AddFiniFunction(Fini, 0);
    PIN_StartProgram();
    return 0;
}
