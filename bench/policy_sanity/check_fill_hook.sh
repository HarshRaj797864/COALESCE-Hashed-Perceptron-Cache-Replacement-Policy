#!/usr/bin/env bash
# Guards against the defect documented in docs/PLAN.md section 0.
#
# ChampSim splits replacement notifications across two hooks. inc/cache.h:475
# gates update_replacement_state on `hit || has_cache_fill`, and the forwarding
# else-branch in impl_replacement_cache_fill routes through that same guard with
# hit=false. Net effect: a replacement module that does NOT declare
# replacement_cache_fill is never told about fills at all. It is notified only
# on hits.
#
# Any policy that sets per-line state at insertion -- an RRPV, an Etr, a
# predicted reuse distance -- is therefore silently crippled. That is what
# happened to drrip, ship, hawkeye and mockingjay here, undetected for months,
# because nothing checked and the simulator reports no error.
#
# This script fails the build if a module is unaccounted for. Run it after any
# change under simulator/replacement/.
set -uo pipefail

cd "$(dirname "$0")/../../simulator/replacement" || exit 2

# Policies that legitimately need no insertion hook, with the reason.
declare -A EXEMPT=(
  [random]="stateless -- find_victim returns a random way, no per-line state"
)

# Known-outstanding, tracked in docs/PLAN.md. Remove entries as they are fixed;
# the check tightens automatically. Empty is the goal state.
declare -A TRACKED=()

fail=0
for d in */; do
  p="${d%/}"
  [[ -f "$p/$p.h" ]] || continue

  if grep -q "replacement_cache_fill" "$p/$p.h"; then
    printf '  \033[32mok\033[0m       %s\n' "$p"
  elif [[ -n "${EXEMPT[$p]:-}" ]]; then
    printf '  \033[36mexempt\033[0m   %s  (%s)\n' "$p" "${EXEMPT[$p]}"
  elif [[ -n "${TRACKED[$p]:-}" ]]; then
    printf '  \033[33mtracked\033[0m  %s  (%s)\n' "$p" "${TRACKED[$p]}"
  else
    printf '  \033[31mFAIL\033[0m     %s  -- declares no replacement_cache_fill and is not exempt or tracked\n' "$p"
    fail=1
  fi
done

echo
if [[ $fail -ne 0 ]]; then
  echo "FAIL: a replacement module will never be told about cache fills."
  echo "Declare replacement_cache_fill (empty is fine if insertion is by"
  echo "inheritance -- see replacement/srrip/srrip.h), and remember that adding"
  echo "the hook makes update_replacement_state fire on misses too, where \`way\`"
  echo "is past-the-end. Guard it with \`if (!hit) return;\`."
  exit 1
fi
echo "PASS: every replacement module accounts for its insertion behaviour."
