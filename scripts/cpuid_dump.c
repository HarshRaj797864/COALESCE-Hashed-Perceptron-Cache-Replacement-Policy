/* cpuid_dump: print what CPUID answers, for stream_count -cpuid
 * (bench/policy_sanity/stream_fix_design_2026-11-02.md). Run natively it shows
 * the host; run in gem5 (static build) it shows what gem5 answers.
 *
 *   gcc -O2 -static -o cpuid_dump cpuid_dump.c
 *
 * Prints, for every basic leaf 0..max and every extended leaf
 * 0x80000000..max, subleaves 0-15 (hex, inputs EAX = leaf, ECX = subleaf,
 * EBX = EDX = 0):
 *   CPUID leaf subleaf eax ebx ecx edx
 * and a comment line with the vendor string. max is capped at 0x40 basic and
 * 0x80000040 extended.
 *
 *   cpuid_dump LEAF [FIRST]   (hex) only that leaf, subleaves FIRST..15, no header
 *
 * gem5 25.1 aborts (an assertion in doCpuid) on a subleaf of leaf 0xd past the
 * two it holds, so in gem5 the dump is taken leaf by leaf and resumed after
 * the subleaf it aborts on (streamfix_server.sh, cpuid). Output is unbuffered:
 * every line printed before an abort is kept. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void cpuid(unsigned leaf, unsigned sub, unsigned r[4])
{
  unsigned a = leaf, b = 0, c = sub, d = 0;
  __asm__ volatile("cpuid" : "+a"(a), "+b"(b), "+c"(c), "+d"(d));
  r[0] = a; r[1] = b; r[2] = c; r[3] = d;
}

static void one(unsigned leaf, unsigned first)
{
  unsigned r[4];
  for (unsigned sub = first; sub < 16; sub++) {
    cpuid(leaf, sub, r);
    printf("CPUID %x %x %x %x %x %x\n", leaf, sub, r[0], r[1], r[2], r[3]);
  }
}

static void range(unsigned first, unsigned last)
{
  for (unsigned leaf = first; leaf <= last; leaf++)
    one(leaf, 0);
}

int main(int argc, char **argv)
{
  unsigned r[4];
  char vendor[13];
  setvbuf(stdout, NULL, _IONBF, 0);
  if (argc >= 2) {
    one((unsigned)strtoul(argv[1], NULL, 16), argc >= 3 ? (unsigned)strtoul(argv[2], NULL, 16) : 0);
    return 0;
  }
  cpuid(0, 0, r);
  memcpy(vendor, &r[1], 4); memcpy(vendor + 4, &r[3], 4); memcpy(vendor + 8, &r[2], 4); vendor[12] = 0;
  unsigned maxb = r[0] > 0x40 ? 0x40 : r[0];
  cpuid(0x80000000u, 0, r);
  unsigned maxe = r[0];
  if (maxe < 0x80000000u) maxe = 0x80000000u;
  if (maxe > 0x80000040u) maxe = 0x80000040u;
  printf("# cpuid_dump: vendor %s, basic leaves 0-%x, extended 80000000-%x\n", vendor, maxb, maxe);
  range(0, maxb);
  range(0x80000000u, maxe);
  return 0;
}
