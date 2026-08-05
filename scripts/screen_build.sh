#!/bin/bash
# screen_build.sh <graph> -- login-shell wrapper so the Xilinx tools are on PATH
# when run inside a detached screen. Launch with:
#   screen -dmS build_<graph> bash -l ~/fpga-routing-graph/scripts/screen_build.sh <graph>
# Reattach any time with:  screen -r build_<graph>   (list: screen -ls)
cd ~/fpga-routing-graph || exit 1
exec bash scripts/build_graph.sh "${1:?graph}"
