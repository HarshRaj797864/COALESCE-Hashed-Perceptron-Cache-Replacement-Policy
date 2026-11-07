#!/usr/bin/env bash
# B3 v2: deploy the sharer directory (acb76b2), build it, and launch the
# comparison's ChampSim queues (launch_b3_v2.sh). One command, one password.
#
#   scripts/b3v2_all.sh        # from the repo root, on the LAPTOP
LAUNCHER=launch_b3_v2.sh EXPECT="2 2 2" COUNTER="COHERENCE DIR RFO PROTOCOL-OTHER" \
  exec bash "$(dirname "$0")/deploy_launch.sh"
