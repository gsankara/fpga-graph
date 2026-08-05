#!/bin/bash
# screen_all.sh -- login-shell wrapper to run the full sequential build
# (tree -> ring16 -> capacity sweep) inside a detached screen. Launch with:
#   screen -dmS buildall bash -l ~/fpga-routing-graph/scripts/screen_all.sh
# Reattach: screen -r buildall   (list: screen -ls)
cd ~/fpga-routing-graph || exit 1
exec bash scripts/build_all_seq.sh
