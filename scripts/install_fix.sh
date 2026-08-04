#!/bin/bash
# install_fix.sh -- tear down any running build, install the single-thread
# Vivado_init.tcl workaround, and verify it is in place.
cd ~/fpga-routing-graph || exit 1
bash scripts/kill_stale.sh >/dev/null 2>&1
mkdir -p ~/.Xilinx/Vivado
if [ ! -f scripts/vivado_init.tcl ]; then
  echo "ERROR: scripts/vivado_init.tcl not on box"; exit 1
fi
cp -f scripts/vivado_init.tcl ~/.Xilinx/Vivado/Vivado_init.tcl
echo "=== installed ~/.Xilinx/Vivado/Vivado_init.tcl ==="
cat ~/.Xilinx/Vivado/Vivado_init.tcl 2>/dev/null || echo STILL_MISSING
echo "=== any build procs still alive (want none) ==="
pgrep -af "build_graph.sh|build_all_seq.sh|fpga-routing-graph/build/(tree|ring16)" | head
echo "install_fix done"
