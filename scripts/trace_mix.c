/* trace_mix: an independent count of a ChampSim trace, read from stdin
 * (decompressed). Written for the 2026-10-17 validation round so the
 * instruction mix is not re-derived by the same code that produced it
 * (count_rmw.py, barnes_std_traces.py mix).
 *
 *   xz -dc t.champsimtrace.xz | trace_mix [STEP]       (STEP records, default 100000)
 *
 * A record is ChampSim's 64-byte input_instr: ip (8), is_branch (1),
 * branch_taken (1), destination_registers[2], source_registers[4],
 * destination_memory[2] (8 each), source_memory[4] (8 each).
 *   load   : any source memory address non-zero
 *   store  : any destination memory address non-zero
 *   rmw    : a non-zero destination address equal to a source address
 *   branch : is_branch != 0
 * Prints, every STEP records, the counts so far (cumulative, records [0, idx)),
 * the ip of record idx, and an FNV-1a hash of every byte so far:
 *   C idx loads stores rmw branches ip_at_idx hash
 * and at the end
 *   T records loads stores rmw branches hash trailing_bytes [sync N]
 * trailing_bytes is a partial record at the end of the stream (should be 0).
 * Sync records (synchronised replay: destination_memory[1] == SYNCSYNC) are
 * counted as records but not as loads, stores or RMWs, and their number is
 * appended as "sync N" when there are any.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define REC 64

static uint64_t rd64(const unsigned char *p)
{
  uint64_t v;
  memcpy(&v, p, 8); /* the traces are little-endian, as is the host */
  return v;
}

int main(int argc, char **argv)
{
  uint64_t step = argc > 1 ? strtoull(argv[1], NULL, 10) : 100000;
  if (step == 0)
    step = 100000;
  static unsigned char buf[REC * 65536];
  uint64_t n = 0, loads = 0, stores = 0, rmw = 0, br = 0, sync = 0;
  uint64_t h = 1469598103934665603ULL;
  size_t have = 0;
  for (;;) {
    size_t got = fread(buf + have, 1, sizeof buf - have, stdin);
    have += got;
    size_t whole = have / REC * REC;
    for (size_t off = 0; off < whole; off += REC) {
      const unsigned char *r = buf + off;
      if (n % step == 0)
        printf("C %llu %llu %llu %llu %llu %llx %llx\n", (unsigned long long)n, (unsigned long long)loads,
               (unsigned long long)stores, (unsigned long long)rmw, (unsigned long long)br,
               (unsigned long long)rd64(r), (unsigned long long)h);
      uint64_t dm[2] = {rd64(r + 16), rd64(r + 24)};
      uint64_t sm[4] = {rd64(r + 32), rd64(r + 40), rd64(r + 48), rd64(r + 56)};
      if (dm[1] == 0x53594E4353594E43ULL) { /* a sync record: no memory operands */
        sync++;
        dm[0] = dm[1] = 0;
        sm[0] = sm[1] = sm[2] = sm[3] = 0;
      }
      int is_load = (sm[0] | sm[1] | sm[2] | sm[3]) != 0;
      int is_store = (dm[0] | dm[1]) != 0;
      int is_rmw = 0;
      for (int i = 0; i < 2 && !is_rmw; i++)
        if (dm[i])
          for (int j = 0; j < 4; j++)
            if (dm[i] == sm[j]) {
              is_rmw = 1;
              break;
            }
      loads += is_load;
      stores += is_store;
      rmw += is_rmw;
      br += r[8] != 0;
      for (int i = 0; i < REC; i++) {
        h ^= r[i];
        h *= 1099511628211ULL;
      }
      n++;
    }
    memmove(buf, buf + whole, have - whole);
    have -= whole;
    if (got == 0)
      break;
  }
  printf("T %llu %llu %llu %llu %llu %llx %zu", (unsigned long long)n, (unsigned long long)loads,
         (unsigned long long)stores, (unsigned long long)rmw, (unsigned long long)br, (unsigned long long)h, have);
  if (sync)
    printf(" sync %llu", (unsigned long long)sync);
  printf("\n");
  return ferror(stdin) ? 2 : 0;
}
