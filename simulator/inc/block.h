/*
 *    Copyright 2023 The ChampSim Contributors
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

#ifndef BLOCK_H
#define BLOCK_H

#include <cstdint>

#include "champsim.h"

// COALESCE: declared outside the namespace so replacement policies can name it
// without qualification.
enum MESI_State { INVALID = 0, SHARED = 1, EXCLUSIVE = 2, MODIFIED = 3 };

namespace champsim
{
struct cache_block {
  bool valid = false;
  bool prefetch = false;
  bool dirty = false;

  champsim::address address{};
  champsim::address v_address{};
  champsim::address data{};

  uint32_t pf_metadata = 0;

  // -- COALESCE coherence extensions ----------------------------------------
  // The allocating instruction's PC, carried on the block so a replacement
  // policy can recover the context that brought a line in.
  uint64_t ip = 0;

  // Coherence state and the set of cores currently holding this line.
  // 16-bit: the scaling study goes to 16 cores, and `1u << cpu` for cpu >= 8
  // truncates to zero in a uint8_t. See docs/policy_audit.md.
  MESI_State state = INVALID;
  uint16_t sharer_mask = 0;
};
} // namespace champsim

#endif
