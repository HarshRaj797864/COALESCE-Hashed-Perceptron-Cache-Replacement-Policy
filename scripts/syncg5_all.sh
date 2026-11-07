#!/usr/bin/env bash
# Step 3, gem5's measured rule as a records-only view (bench/policy_sanity/b3_g5rule_design_2026-10-19.md):
# build in ~/sync_g5_build, check (guards, Q0), then -- on the server, detached --
# wait for the mutex-order traces (traces/sync_mx/), check Q0m against the
# mutex-order build, run the 12 B3 configurations -> results/phaseA_b3_g2_*,
# and compare each with its m2 run line by line (Q0-full). One command, one
# password; the steps are sync_all.sh's.
#
#   scripts/syncg5_all.sh          # from the repo root, on the LAPTOP
#   scripts/syncg5_all.sh pull     # later: status and the new runs' logs
VARIANT=g5 exec "$(dirname "$(readlink -f "$0")")/sync_all.sh" "$@"
