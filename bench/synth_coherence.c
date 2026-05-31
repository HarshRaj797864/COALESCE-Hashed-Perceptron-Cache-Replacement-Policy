/*
 * synth_coherence.c — synthetic validation harness for the COALESCE VMEM overlay.
 *
 * Three deterministic sharing modes selected by argv[1]:
 *   A : private-only — each thread reads/writes a local array on its stack.
 *       Expected when traced + replayed with shared_cpus=[0..N]:
 *         - sharer_count histogram peaks at bin[1] (still mostly private even with overlay)
 *         - coherence_invalidations = 0
 *       Acts as the NEGATIVE CONTROL: confirms the overlay isn't a synthetic inflator.
 *
 *   B : producer/consumer — one producer writes a cacheline-isolated shared array,
 *       the other 7 threads read those same elements. Expected with overlay:
 *         - sharer_count histogram: significant population in bins[2..N]
 *         - coherence_invalidations >> 0 (every producer write following a consumer read fires)
 *         - VMEM aliased_fills >> 0
 *       This is the POSITIVE CASE: demonstrates the coherence-aware path actually fires.
 *
 *   C : read-mostly migratory — all 8 threads round-robin read a shared const array.
 *       Expected:
 *         - sharer_count histogram: heavy population at high bins (≈ thread_count)
 *         - coherence_invalidations = 0 (no writes)
 *         - VMEM aliased_fills >> 0
 *       Validates that read-only sharing populates sharer_mask without spurious invalidations.
 *
 * Build:   gcc -O0 -pthread -Wall bench/synth_coherence.c -o bench/synth_coherence
 *          (-O0 keeps the loop body intact so the trace is predictable)
 *
 * Usage:   ./synth_coherence {A|B|C} [iterations]
 *          Default iterations: 200000. Each iteration does ~5–10 instructions per thread,
 *          so 200k → ~1–2 M instructions per thread, ~8–16 M total.
 *
 * Trace:   on the server with PIN MT-Sync (see simulator/tracer/pin/):
 *            cd simulator/tracer/pin
 *            $PIN_ROOT/pin -t obj-intel64/champsim_tracer.so \
 *              -o ../../traces/synth_modeA -- ../../../bench/synth_coherence A 200000
 *          Produces synth_modeA{0..7}.champsimtrace (one per pthread).
 *
 * ChampSim:
 *            ./config.sh some_synth_config.json   # with vmem_shared_cpus=[0..7]
 *            bin/<binary> --warmup-instructions <W> --simulation-instructions <S> \
 *               traces/synth_modeB0.champsimtrace ... traces/synth_modeB7.champsimtrace
 */

#define _GNU_SOURCE
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define N_THREADS 8

/* Shared data structures must have predictable virtual addresses so the trace's
 * recorded VAs are stable across runs. Declaring them at file scope places them
 * in .bss / .rodata, which ld assigns at link time. */
#define LINE_BYTES 64

/* Mode B: 16 cacheline-isolated counters. Producer writes a subset; consumers read. */
__attribute__((aligned(LINE_BYTES))) static volatile int b_shared[16 * (LINE_BYTES / sizeof(int))];

/* Mode C: ~64 KB read-mostly array, all threads round-robin read it. */
#define C_ARRAY_LEN 16384
static const int c_const_data[C_ARRAY_LEN] = {0};  /* zero-initialized in .rodata */

static pthread_barrier_t start_barrier;
static long g_iterations = 200000;
static char g_mode = '?';

/* ---- Mode A: per-thread private array on the stack ---- */
static void run_mode_A(int tid)
{
  (void)tid;
  volatile int local[1024];  /* 4 KB on stack — per-thread, never shared. */
  for (int i = 0; i < 1024; i++) local[i] = 0;
  long sum = 0;
  for (long iter = 0; iter < g_iterations; iter++) {
    int idx = (int)(iter & 1023);
    local[idx] = local[idx] + (int)iter;     /* RMW */
    sum += local[(idx + 1) & 1023];           /* extra load */
  }
  /* keep sum live so the compiler can't eliminate the loop */
  if (sum == 0xDEADBEEF) fprintf(stderr, "tid %d magic\n", tid);
}

/* ---- Mode B: producer/consumer over cacheline-isolated shared cells ---- */
static void run_mode_B(int tid)
{
  /* Indices into b_shared that are 64-byte aligned. */
  const int line_step = LINE_BYTES / (int)sizeof(int);
  const int n_cells = 16;

  if (tid == 0) {
    /* Producer: write a rotating set of shared cells. */
    for (long iter = 0; iter < g_iterations; iter++) {
      int cell = (int)(iter % n_cells);
      b_shared[cell * line_step] = (int)iter;  /* one store per iter to a cacheline */
    }
  } else {
    /* Consumer: read one assigned cell repeatedly so all consumers concurrently
     * hammer the same lines the producer is writing. */
    int my_cell = (tid - 1) % n_cells;
    int idx = my_cell * line_step;
    long sum = 0;
    for (long iter = 0; iter < g_iterations; iter++) {
      sum += b_shared[idx];                    /* one load per iter */
    }
    if (sum == 0xDEADBEEF) fprintf(stderr, "tid %d magic\n", tid);
  }
}

/* ---- Mode C: read-mostly migratory shared array ---- */
static void run_mode_C(int tid)
{
  long sum = 0;
  for (long iter = 0; iter < g_iterations; iter++) {
    int idx = (int)((iter + (long)tid * 64L) & (C_ARRAY_LEN - 1));
    sum += c_const_data[idx];                  /* read-only access to shared array */
  }
  if (sum == 0xDEADBEEF) fprintf(stderr, "tid %d magic\n", tid);
}

static void* worker(void* arg)
{
  int tid = (int)(intptr_t)arg;
  pthread_barrier_wait(&start_barrier);
  switch (g_mode) {
    case 'A': run_mode_A(tid); break;
    case 'B': run_mode_B(tid); break;
    case 'C': run_mode_C(tid); break;
  }
  return NULL;
}

int main(int argc, char** argv)
{
  if (argc < 2 || (argv[1][0] != 'A' && argv[1][0] != 'B' && argv[1][0] != 'C')) {
    fprintf(stderr, "usage: %s {A|B|C} [iterations]\n", argv[0]);
    fprintf(stderr, "  A = private (negative control); B = producer/consumer; C = read-mostly\n");
    return 1;
  }
  g_mode = argv[1][0];
  if (argc >= 3) g_iterations = strtol(argv[2], NULL, 10);

  /* Touch the shared arrays once before the threads start so they're paged in
   * deterministically — this helps the tracer record the same VAs every run. */
  for (int i = 0; i < 16 * (LINE_BYTES / (int)sizeof(int)); i++) b_shared[i] = 0;
  /* Read c_const_data to fault it in. */
  volatile int touch_c = 0;
  for (int i = 0; i < C_ARRAY_LEN; i++) touch_c += c_const_data[i];
  (void)touch_c;

  pthread_barrier_init(&start_barrier, NULL, N_THREADS);
  pthread_t threads[N_THREADS];
  for (int t = 0; t < N_THREADS; t++) {
    pthread_create(&threads[t], NULL, worker, (void*)(intptr_t)t);
  }
  for (int t = 0; t < N_THREADS; t++) {
    pthread_join(threads[t], NULL);
  }
  pthread_barrier_destroy(&start_barrier);

  fprintf(stderr, "synth_coherence mode=%c iterations=%ld threads=%d done\n",
          g_mode, g_iterations, N_THREADS);
  return 0;
}
