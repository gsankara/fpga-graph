#!/bin/bash
# screen_sweep.sh -- login-shell wrapper to run the capacity sweep in a detached
# screen. Launch: screen -dmS sweep bash -l ~/fpga-routing-graph/scripts/screen_sweep.sh
# Reattach: screen -r sweep
cd ~/fpga-routing-graph || exit 1
exec bash scripts/capacity_sweep.sh > sweep.out 2>&1
