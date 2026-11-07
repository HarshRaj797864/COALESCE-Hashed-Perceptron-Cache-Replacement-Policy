#!/usr/bin/env bash
# Guards against the defect fixed in 8a0bf0a (replacement/random).
#
# CACHE::impl_find_victim and impl_update_replacement_state pick a module's
# method by SFINAE over a fixed list of accepted signatures (inc/cache.h). If a
# module's signature matches none of them, `has_find_victim` is simply false,
# the dispatch falls through to `return return_type{}`, and the policy silently
# becomes "always evict way 0". No warning, no error, no crash -- it compiles,
# links, runs, and produces plausible numbers.
#
# random::find_victim took `const CACHE::BLOCK*, uint64_t ip, uint64_t
# full_addr, access_type type`. The raw-integer overload needs
# std::underlying_type_t<access_type>, which a scoped enum will not bind, so it
# matched nothing and "random replacement" was always-way-0 for the life of the
# project.
#
# The accepted find_victim forms all pair their address type with a matching
# access_type form. Mixing them -- raw integer addresses with the scoped enum --
# is the trap, so that is what this checks.
set -uo pipefail

cd "$(dirname "$0")/../../simulator/replacement" || exit 2

fail=0
for d in */; do
  p="${d%/}"
  [[ -f "$p/$p.h" ]] || continue

  # Pull the find_victim declaration whatever its RETURN TYPE, joined onto one
  # line.
  #
  # This used to grep for the literal "long find_victim". A declaration
  # returning anything else produced an empty $sig, which took a `skip` branch
  # and continued WITHOUT failing -- so `uint32_t find_victim(...)` with raw
  # addresses, which is the `random` defect this guard was written for,
  # reported "declares no find_victim" and the script exited 0. Verified
  # 2026-09-23 by injecting exactly that signature: the guard passed it.
  #
  # The return type is not cosmetic. develop makes find_victim pure virtual
  # with a `long` return, so a different one does not override it and the
  # dispatch never reaches the module.
  sig=$(grep -A3 -E '\bfind_victim[[:space:]]*\(' "$p/$p.h" 2>/dev/null | tr '\n' ' ' | tr -s ' ')
  if [[ -z "$sig" ]]; then
    if grep -qE '\bfind_victim[[:space:]]*\(' "$p/$p.cc" 2>/dev/null; then
      printf '  \033[31mFAIL\033[0m  %s  -- find_victim is defined in the .cc but not declared in the .h,\n' "$p"
      printf '        so it overrides nothing and is never dispatched.\n'
    else
      printf '  \033[31mFAIL\033[0m  %s  -- declares no find_victim at all. It is pure virtual in\n' "$p"
      printf '        develop, so this module cannot be doing replacement.\n'
    fi
    fail=1
    continue
  fi

  raw_addr=0; strong_addr=0; enum_type=0; ret_long=0
  [[ "$sig" == *"uint64_t ip"* ]] && raw_addr=1
  [[ "$sig" == *"champsim::address ip"* ]] && strong_addr=1
  [[ "$sig" == *"access_type type"* ]] && enum_type=1
  [[ "$sig" =~ (^|[^_[:alnum:]])long[[:space:]]+find_victim ]] && ret_long=1

  if [[ $ret_long -eq 1 && $strong_addr -eq 1 && $enum_type -eq 1 ]]; then
    printf '  \033[32mok\033[0m    %s  (long, strong addresses + access_type)\n' "$p"
  elif [[ $raw_addr -eq 1 && $enum_type -eq 1 ]]; then
    printf '  \033[31mFAIL\033[0m  %s  -- raw uint64_t addresses paired with the scoped `access_type`.\n' "$p"
    printf '        No overload accepts that combination; find_victim will never be\n'
    printf '        called and the policy will silently always evict way 0.\n'
    fail=1
  elif [[ $ret_long -eq 0 ]]; then
    printf '  \033[31mFAIL\033[0m  %s  -- find_victim does not return `long`, so it does not override\n' "$p"
    printf '        the pure virtual and is never dispatched.\n'
    fail=1
  else
    # Previously a pass-through "check by hand", which exits 0 and is therefore
    # indistinguishable from ok in any script that consumes this one.
    printf '  \033[31mFAIL\033[0m  %s  -- unrecognised signature. Verify against inc/cache.h; if it is\n' "$p"
    printf '        legitimate, add it here explicitly rather than letting it pass.\n'
    fail=1
  fi
done

echo
if [[ $fail -ne 0 ]]; then
  echo "FAIL: a replacement module's find_victim will never be dispatched."
  echo "Use the strong-address form, which every other policy here uses:"
  echo "  long find_victim(uint32_t triggering_cpu, uint64_t instr_id, long set,"
  echo "                   const champsim::cache_block* current_set,"
  echo "                   champsim::address ip, champsim::address full_addr,"
  echo "                   access_type type);"
  exit 1
fi
echo "PASS: every find_victim matches a dispatchable overload."
