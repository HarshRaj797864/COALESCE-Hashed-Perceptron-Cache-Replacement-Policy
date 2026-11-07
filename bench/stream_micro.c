/* stream_micro: hand-known counts for stream_count and the tracer
 * (bench/policy_sanity/stream_fix_design_2026-11-02.md).
 *
 *   gcc -O2 -pthread [-DNO_AVX] -o stream_micro bench/stream_micro.c
 *   stream_micro K       thread 1 runs the kernel K times; thread 0 waits
 * It prints the per-iteration counts it was built to give ("EXPECT ...");
 * -DNO_AVX (a CPU without AVX) drops the two AVX instructions.
 *
 * One kernel iteration, by hand (x86-64, AT&T):
 *   vmovupd (src), ymm1      load 32 B         rec, ld; gem5: 1 inst, 4 read micro-ops
 *   movupd  (src), xmm0      load 16 B         rec, ld; 1 inst, 2 read
 *   movupd  xmm0, (dst)      store 16 B        rec, st; 1 inst, 2 write
 *   mov     $1, eax                            rec;     1 inst
 *   lock xadd eax, (cnt)     RMW 4 B           rec, ld, st, rmw; 1 inst, 1 read, 1 write
 *   mov     (src), rax       load 8 B          rec, ld; 1 inst, 1 read
 *   mov     buf, rdi                           rec;     1 inst
 *   mov     $64, rcx                           rec;     1 inst
 *   rep stosb                64 x store 1 B    64 rec, 64 st, 64 rep; 1 inst, 64 write
 *   vzeroupper                                 rec;     1 inst
 *   dec     n                                  rec;     1 inst
 *   jnz                                        rec;     1 inst
 * Per iteration: rec 75, ld 4, st 66, rmw 1, ginst 12, gld 8, gst 67, rep 64
 * (without AVX: rec 73, ld 3, ginst 10, gld 4).
 * Running K and 2K, thread 1's counts differ by exactly K times that. */
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

static double src[8] __attribute__((aligned(64))) = {1, 2, 3, 4, 5, 6, 7, 8};
static double dst[8] __attribute__((aligned(64)));
static unsigned char buf[64] __attribute__((aligned(64)));
static int cnt;

static void* kernel(void* arg)
{
  long n = (long)arg;
  if (n <= 0)
    return NULL;
  __asm__ volatile(
      "1:\n\t"
#ifndef NO_AVX
      "vmovupd (%[s]), %%ymm1\n\t"
#endif
      "movupd (%[s]), %%xmm0\n\t"
      "movupd %%xmm0, (%[d])\n\t"
      "movl $1, %%eax\n\t"
      "lock xaddl %%eax, (%[c])\n\t"
      "movq (%[s]), %%rax\n\t"
      "movq %[b], %%rdi\n\t"
      "movq $64, %%rcx\n\t"
      "rep stosb\n\t"
#ifndef NO_AVX
      "vzeroupper\n\t"
#endif
      "decq %[n]\n\t"
      "jnz 1b\n\t"
      : [n] "+r"(n)
      : [s] "r"(src), [d] "r"(dst), [c] "r"(&cnt), [b] "r"(buf)
      : "rax", "rcx", "rdi", "xmm0", "xmm1", "memory", "cc");
  return NULL;
}

int main(int argc, char** argv)
{
  long k = argc > 1 ? atol(argv[1]) : 1000;
  pthread_t t;
  if (pthread_create(&t, NULL, kernel, (void*)k) != 0)
    return 1;
  pthread_join(t, NULL);
  printf("stream_micro: %ld iterations, cnt %d\n", k, cnt);
#ifndef NO_AVX
  printf("EXPECT rec 75 ld 4 st 66 rmw 1 ginst 12 gld 8 gst 67 rep 64\n");
#else
  printf("EXPECT rec 73 ld 3 st 66 rmw 1 ginst 10 gld 4 gst 67 rep 64\n");
#endif
  return cnt == k ? 0 : 1;
}
