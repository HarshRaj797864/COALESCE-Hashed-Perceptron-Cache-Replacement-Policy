#!/usr/bin/env bash
# B3 v4, coherent private caches (steps 2 and 3): deploy, keep the step-1
# binary as bin/champsim_b3v3_f23e03f, build, and launch the 12 LRU queues
# (launch_b3_v4.sh) with the A5 rerun chained to their result
# (b3v4_chain.sh). One command, one password.
# Pre-registered: bench/policy_sanity/b3v4_coherent_private_design_2026-10-11.md.
#
#   scripts/b3v4_all.sh        # from the repo root, on the LAPTOP
#
# Afterwards, any time:  scripts/pull_results.sh   (it also prints the chain's verdict)
LAUNCHER=launch_b3_v4.sh EXPECT="2 2 2 2 2 2 2 2 2 2 2 2" COUNTER="COHERENCE DIR STALE-HOLDER VIOLATIONS" \
  FREEZE_AS=champsim_b3v3_f23e03f \
  EXTRA_UPLOADS="scripts/b3v4_chain.sh scripts/b3_score.py bench/policy_sanity/gem5_b3_rows_v1.txt" \
  exec bash "$(dirname "$0")/deploy_launch.sh"
