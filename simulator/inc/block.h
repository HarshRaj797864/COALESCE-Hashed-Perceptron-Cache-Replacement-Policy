#ifndef BLOCK_H
#define BLOCK_H

#include "champsim.h"

// Define this globally so your replacement policy can see it easily
enum MESI_State { INVALID = 0, SHARED = 1, EXCLUSIVE = 2, MODIFIED = 3 };

namespace champsim
{
struct cache_block {
  bool valid = false;
  bool prefetch = false;
  bool dirty = false;
  uint64_t ip = 0;
  champsim::address address{};
  champsim::address v_address{};
  champsim::address data{};

  uint32_t pf_metadata = 0;


  // COALESCE Coherence Extensions
  MESI_State state = INVALID;
  uint8_t sharer_mask = 0;
};
} // namespace champsim

#endif
