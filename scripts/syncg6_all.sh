#!/usr/bin/env bash
# Amendment 2 of the gem5-rule view (bench/policy_sanity/b3_g5rule_design_2026-10-19.md,
# 2026-10-27): the view-order violations split into silent re-listings and
# unexplained ones (records only; no B3 number changes). Uploads the sources to
# ~/sync_g6_build; then, DETACHED on the server: build, guards, Q0 and Q0m
# against champsim_g5_034cd735 (only the three new lines filtered), and the
# chain -- the 12 B3 configurations -> results/phaseA_b3_g3_*, Q0-full against
# the g2 runs, Q3. Step 4 and step 5 run on this binary. One command, one password.
#
#   scripts/syncg6_all.sh          # from the repo root, on the LAPTOP
#   scripts/syncg6_all.sh pull     # later: status and the new runs' logs
VARIANT=g6 exec "$(dirname "$(readlink -f "$0")")/sync_all.sh" "$@"
