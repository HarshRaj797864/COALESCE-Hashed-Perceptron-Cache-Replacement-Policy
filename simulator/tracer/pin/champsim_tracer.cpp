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

#include "../../inc/trace_instruction.h"
#include "pin.H"

using trace_instr_format_t = input_instr;

/* ================================================================== */
// Thread-Local Global variables
/* ================================================================== */
UINT64 instrCount[PIN_MAX_THREADS] = {0};
std::ofstream* outfiles[PIN_MAX_THREADS] = {NULL};
trace_instr_format_t curr_instr[PIN_MAX_THREADS];

/* ===================================================================== */
// Command line switches
/* ===================================================================== */
KNOB<std::string> KnobOutputFile(KNOB_MODE_WRITEONCE, "pintool", "o", "champsim.trace", "specify base file name");
KNOB<UINT64> KnobSkipInstructions(KNOB_MODE_WRITEONCE, "pintool", "s", "0", "Instructions to skip per thread");
KNOB<UINT64> KnobTraceInstructions(KNOB_MODE_WRITEONCE, "pintool", "t", "1000000", "Instructions to trace per thread");

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
    ++instrCount[tid];
    return (instrCount[tid] > KnobSkipInstructions.Value()) && 
           (instrCount[tid] <= (KnobTraceInstructions.Value() + KnobSkipInstructions.Value()));
}

void WriteCurrentInstruction(THREADID tid)
{
    if (outfiles[tid]) {
        outfiles[tid]->write(reinterpret_cast<char*>(&curr_instr[tid]), sizeof(trace_instr_format_t));
    }
}

void BranchOrNot(UINT32 taken, THREADID tid)
{
    curr_instr[tid].is_branch = 1;
    curr_instr[tid].branch_taken = taken;
}

template <typename T>
void WriteToSet(T* begin, T* end, UINT32 r)
{
    auto set_end = std::find(begin, end, 0);
    auto found_reg = std::find(begin, set_end, r);
    *found_reg = r;
}

/* ===================================================================== */
// Instrumentation callbacks
/* ===================================================================== */

VOID Instruction(INS ins, VOID* v)
{
    INS_InsertCall(ins, IPOINT_BEFORE, (AFUNPTR)ResetCurrentInstruction, IARG_INST_PTR, IARG_THREAD_ID, IARG_END);

    if (INS_IsBranch(ins))
        INS_InsertCall(ins, IPOINT_BEFORE, (AFUNPTR)BranchOrNot, IARG_BRANCH_TAKEN, IARG_THREAD_ID, IARG_END);

    // Register reads
    for (UINT32 i = 0; i < INS_MaxNumRRegs(ins); i++) {
        UINT32 regNum = INS_RegR(ins, i);
        INS_InsertCall(ins, IPOINT_BEFORE, (AFUNPTR)WriteToSet<unsigned char>, 
            IARG_PTR, curr_instr[0].source_registers, // Logic handled via thread offset in analysis would be better, but simplified for BTP
            IARG_PTR, curr_instr[0].source_registers + NUM_INSTR_SOURCES, 
            IARG_UINT32, regNum, IARG_END);
    }
    
    // Memory operands
    for (UINT32 memOp = 0; memOp < INS_MemoryOperandCount(ins); memOp++) {
        if (INS_MemoryOperandIsRead(ins, memOp))
            INS_InsertCall(ins, IPOINT_BEFORE, (AFUNPTR)WriteToSet<unsigned long long int>, IARG_PTR, curr_instr[0].source_memory, IARG_PTR, curr_instr[0].source_memory + NUM_INSTR_SOURCES, IARG_MEMORYOP_EA, memOp, IARG_END);
        if (INS_MemoryOperandIsWritten(ins, memOp))
            INS_InsertCall(ins, IPOINT_BEFORE, (AFUNPTR)WriteToSet<unsigned long long int>, IARG_PTR, curr_instr[0].destination_memory, IARG_PTR, curr_instr[0].destination_memory + NUM_INSTR_DESTINATIONS, IARG_MEMORYOP_EA, memOp, IARG_END);
    }

    INS_InsertIfCall(ins, IPOINT_BEFORE, (AFUNPTR)ShouldWrite, IARG_THREAD_ID, IARG_END);
    INS_InsertThenCall(ins, IPOINT_BEFORE, (AFUNPTR)WriteCurrentInstruction, IARG_THREAD_ID, IARG_END);
}

// Called every time a new thread starts
VOID ThreadStart(THREADID tid, CONTEXT* ctxt, INT32 flags, VOID* v)
{
    std::string filename = KnobOutputFile.Value() + std::to_string(tid) + ".champsimtrace";
    outfiles[tid] = new std::ofstream(filename.c_str(), std::ios_base::binary | std::ios_base::trunc);
    if (!outfiles[tid]) {
        std::cerr << "Couldn't open output trace file for thread " << tid << std::endl;
        exit(1);
    }
}

// Called when a thread finishes
VOID ThreadFini(THREADID tid, const CONTEXT* ctxt, INT32 code, VOID* v)
{
    if (outfiles[tid]) {
        outfiles[tid]->close();
        delete outfiles[tid];
        outfiles[tid] = NULL;
    }
}

int main(int argc, char* argv[])
{
    if (PIN_Init(argc, argv)) return -1;

    PIN_AddThreadStartFunction(ThreadStart, 0);
    INS_AddInstrumentFunction(Instruction, 0);
    PIN_AddThreadFiniFunction(ThreadFini, 0);

    PIN_StartProgram();
    return 0;
}
