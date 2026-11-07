#!/usr/bin/env bash
# Mutex order by simulated timing (bench/policy_sanity/sync_mutex_design_2026-10-19.md):
# build in ~/sync_mx_build, check (guards, Q0, Q0b), re-trace the 8 B3 programs
# with mutex addresses, then the 12 B3 runs -> results/phaseA_b3_m2_*. One
# command, one password; the steps are sync_all.sh's.
#
#   scripts/syncmx_all.sh          # from the repo root, on the LAPTOP
#   scripts/syncmx_all.sh pull     # later: status, and the new runs' logs and trace checks
VARIANT=mx exec "$(dirname "$(readlink -f "$0")")/sync_all.sh" "$@"
