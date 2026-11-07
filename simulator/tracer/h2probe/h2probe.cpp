/*
 * h2probe: a Pin tool for held-out set 2's sizing (heldout2_design_2026-11-04.md,
 * Note 2). Records only; changes nothing in the program.
 *
 *   - every thread's instruction count (Pin thread ids: 0 = main, then in
 *     creation order), as inscount_tls counts;
 *   - each pthread_create, pthread_join, pthread_cond_broadcast /
 *     pthread_cond_signal and pthread_barrier_wait call with the calling
 *     thread's count at the call (broadcast / signal / barrier: the first
 *     -nsync calls of each thread);
 *   - a snapshot of every thread's count each time the reference thread
 *     (-ref, default 1: the first created thread) passes a multiple of -step.
 *
 * What it is for: where the main thread is when its workers start, and how
 * much the threads that are not traced execute while the traced ones run.
 * Every number it prints is reported and decides nothing by itself.
 *
 *   pin -t obj-intel64/h2probe.so -o probe.txt [-ref 1] [-step 10000000] -- <program> ...
 */
#include "pin.H"
#include <cstdio>
#include <cstring>
#include <set>
#include <string>

static KNOB<std::string> KnobOut(KNOB_MODE_WRITEONCE, "pintool", "o", "probe.txt", "output file");
static KNOB<UINT32> KnobRef(KNOB_MODE_WRITEONCE, "pintool", "ref", "1", "reference thread for the snapshots");
static KNOB<UINT64> KnobStep(KNOB_MODE_WRITEONCE, "pintool", "step", "10000000", "snapshot every STEP instructions of the reference thread");
static KNOB<UINT32> KnobNsync(KNOB_MODE_WRITEONCE, "pintool", "nsync", "40", "broadcast / signal / barrier calls logged per thread");

static const UINT32 MAXT = 256;
struct alignas(64) Counter { volatile UINT64 n; UINT64 nsync; };
static Counter cnt[MAXT];
static volatile UINT32 nthreads = 0;
static UINT64 next_snap;
static FILE* out;
static PIN_LOCK lk;

static VOID PIN_FAST_ANALYSIS_CALL Bbl(UINT32 n, THREADID t)
{
    if (t >= MAXT) return;
    cnt[t].n += n;
}
// called only for the reference thread's blocks (InsertIfCall below)
static ADDRINT PIN_FAST_ANALYSIS_CALL IsRefDue(THREADID t)
{
    return t == KnobRef.Value() && cnt[t].n >= next_snap;
}
static VOID Snap(THREADID t)
{
    PIN_GetLock(&lk, t + 1);
    if (cnt[t].n >= next_snap) {
        fprintf(out, "SNAP ref %lu |", (unsigned long)cnt[t].n);
        for (UINT32 i = 0; i < nthreads && i < MAXT; i++) fprintf(out, " t%u %lu", i, (unsigned long)cnt[i].n);
        fprintf(out, "\n");
        while (next_snap <= cnt[t].n) next_snap += KnobStep.Value();
    }
    PIN_ReleaseLock(&lk);
}

static VOID Trace(TRACE trace, VOID*)
{
    for (BBL bbl = TRACE_BblHead(trace); BBL_Valid(bbl); bbl = BBL_Next(bbl)) {
        BBL_InsertCall(bbl, IPOINT_BEFORE, (AFUNPTR)Bbl, IARG_FAST_ANALYSIS_CALL, IARG_UINT32, BBL_NumIns(bbl),
                       IARG_THREAD_ID, IARG_END);
        BBL_InsertIfCall(bbl, IPOINT_BEFORE, (AFUNPTR)IsRefDue, IARG_FAST_ANALYSIS_CALL, IARG_THREAD_ID, IARG_END);
        BBL_InsertThenCall(bbl, IPOINT_BEFORE, (AFUNPTR)Snap, IARG_THREAD_ID, IARG_END);
    }
}

static VOID Call(const char* what, THREADID t)
{
    if (t >= MAXT) return;
    bool sync = std::strcmp(what, "create") != 0 && std::strcmp(what, "join") != 0;
    if (sync && cnt[t].nsync++ >= KnobNsync.Value()) return;
    PIN_GetLock(&lk, t + 1);
    fprintf(out, "CALL %s t%u at %lu\n", what, t, (unsigned long)cnt[t].n);
    PIN_ReleaseLock(&lk);
}

// every version of each routine (glibc keeps several; see the tracer's fix of 2026-10-19)
static const char* const NAMES[][2] = {
    {"pthread_create", "create"}, {"pthread_join", "join"},
    {"pthread_cond_broadcast", "broadcast"}, {"pthread_cond_signal", "signal"},
    {"pthread_barrier_wait", "barrier"},
};
static VOID Image(IMG img, VOID*)
{
    for (SEC sec = IMG_SecHead(img); SEC_Valid(sec); sec = SEC_Next(sec))
        for (RTN rtn = SEC_RtnHead(sec); RTN_Valid(rtn); rtn = RTN_Next(rtn)) {
            std::string nm = RTN_Name(rtn);
            std::string base = nm.substr(0, nm.find('@'));
            if (base.size() > 2 && base.compare(0, 2, "__") == 0) base = base.substr(2);
            for (auto& p : NAMES) {
                if (base != p[0]) continue;
                RTN_Open(rtn);
                RTN_InsertCall(rtn, IPOINT_BEFORE, (AFUNPTR)Call, IARG_PTR, p[1], IARG_THREAD_ID, IARG_END);
                RTN_Close(rtn);
                PIN_GetLock(&lk, 1);
                fprintf(out, "HOOK %s %s in %s\n", p[1], nm.c_str(), IMG_Name(img).c_str());
                PIN_ReleaseLock(&lk);
            }
        }
}

static VOID ThreadStart(THREADID t, CONTEXT*, INT32, VOID*)
{
    PIN_GetLock(&lk, t + 1);
    if (t + 1 > nthreads) nthreads = t + 1;
    fprintf(out, "START t%u\n", t);
    PIN_ReleaseLock(&lk);
}
static VOID ThreadFini(THREADID t, const CONTEXT*, INT32, VOID*)
{
    PIN_GetLock(&lk, t + 1);
    fprintf(out, "END t%u at %lu\n", t, t < MAXT ? (unsigned long)cnt[t].n : 0UL);
    PIN_ReleaseLock(&lk);
}
static VOID Fini(INT32, VOID*)
{
    for (UINT32 i = 0; i < nthreads && i < MAXT; i++) fprintf(out, "TOTAL t%u %lu\n", i, (unsigned long)cnt[i].n);
    fprintf(out, "THREADS %u\n", nthreads);
    fclose(out);
}

int main(int argc, char* argv[])
{
    PIN_InitSymbols();
    if (PIN_Init(argc, argv)) return 1;
    out = fopen(KnobOut.Value().c_str(), "w");
    if (!out) return 1;
    PIN_InitLock(&lk);
    next_snap = KnobStep.Value();
    fprintf(out, "H2PROBE ref t%u step %lu\n", KnobRef.Value(), (unsigned long)KnobStep.Value());
    IMG_AddInstrumentFunction(Image, 0);
    TRACE_AddInstrumentFunction(Trace, 0);
    PIN_AddThreadStartFunction(ThreadStart, 0);
    PIN_AddThreadFiniFunction(ThreadFini, 0);
    PIN_AddFiniFunction(Fini, 0);
    PIN_StartProgram();
    return 0;
}
