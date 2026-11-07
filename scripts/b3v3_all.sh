#!/usr/bin/env bash
# B3 v3 step 1: deploy the read-modify-write change (f23e03f), keep the
# previous binary as bin/champsim_b3v2_acb76b2, build, and launch the five
# LRU queues (launch_b3_v2.sh SET=v3). One command, one password.
# Pre-registered: bench/policy_sanity/b3v3_rmw_design_2026-10-07.md.
#
#   scripts/b3v3_all.sh        # from the repo root, on the LAPTOP
LAUNCHER=launch_b3_v2.sh LAUNCHER_ENV="SET=v3" EXPECT="2 2 2 2 2" COUNTER="RMW LOADS ISSUED AS RFO" \
  FREEZE_AS=champsim_b3v2_acb76b2 exec bash "$(dirname "$0")/deploy_launch.sh"
