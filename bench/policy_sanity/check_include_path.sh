#!/usr/bin/env bash
# Guards against the build compiling against someone else's headers.
#
# `simulator/absolute.options` supplies the -I path for every compilation unit.
# It is generated once and then NEVER regenerated -- config.sh writes
# _configuration.mk and the module lists on every run, but leaves this file
# alone. So a stale copy silently governs the build forever.
#
# That is exactly what happened here. The file was dated 2025-12-30 and pointed
# at a sibling ChampSim checkout:
#
#   -I/home/rajharsh/programming-playground/repos/ChampSim/inc ...
#
# For nine months every local build took its headers from that other tree, so
# edits to simulator/inc/ were silently ignored. simulator/inc/block.h had
# carried `uint16_t sharer_mask` (16-core support) while the sibling still said
# `uint8_t`, and the build used the uint8_t one -- cores 8-15 were invisible to
# the sharer mask on any local build. CLAUDE.md documented this as a "CRITICAL
# BUILD GOTCHA" to be worked around by mirroring headers by hand, when the
# actual fix was one stale file.
#
# Regenerate it with:
#   cd simulator && printf -- "-I%s/inc -isystem %s/vcpkg_installed/x64-linux/include\n" "$PWD" "$PWD" > absolute.options
set -uo pipefail

sim_dir="$(cd "$(dirname "$0")/../../simulator" && pwd)"
opts="$sim_dir/absolute.options"

if [[ ! -f "$opts" ]]; then
  echo "FAIL: $opts does not exist. The build has no include path."
  exit 1
fi

inc_path=$(grep -oE -- '-I[^ ]+' "$opts" | head -1 | sed 's/^-I//')

if [[ -z "$inc_path" ]]; then
  printf '  \033[31mFAIL\033[0m  absolute.options contains no -I path\n'
  exit 1
fi

if [[ "$inc_path" == "$sim_dir/inc" ]]; then
  printf '  \033[32mok\033[0m    headers come from this tree: %s\n' "$inc_path"
  echo
  echo "PASS: the build compiles against simulator/inc."
  exit 0
fi

printf '  \033[31mFAIL\033[0m  the build is using headers from ANOTHER tree:\n'
printf '          %s\n' "$inc_path"
printf '        expected:\n'
printf '          %s/inc\n' "$sim_dir"
echo
echo "Edits to simulator/inc/ are being silently ignored. Regenerate with:"
echo "  cd $sim_dir && printf -- \"-I%s/inc -isystem %s/vcpkg_installed/x64-linux/include\\n\" \"\$PWD\" \"\$PWD\" > absolute.options"
exit 1
