#!/bin/bash
# kill_stale.sh -- tear down the dead/parallel build orchestration and its
# wedged Vivado zombies, and clear crashed IP-cache state for a clean rebuild.
cd ~/fpga-routing-graph || exit 1
# 1. stop orchestrators/watchers
pkill -f build_xclbin_u280.sh 2>/dev/null
pkill -f resume_ring16.sh    2>/dev/null
pkill -f run_after_builds.sh 2>/dev/null
sleep 1
# 2. kill the wedged/paused build processes for BOTH graphs (SIGKILL works on T)
pkill -9 -f "fpga-routing-graph/build/tree"   2>/dev/null
pkill -9 -f "fpga-routing-graph/build/ring16" 2>/dev/null
sleep 2
# 3. clear crashed/partial build + any IP cache that may be corrupted
rm -rf build/tree/_x build/tree/_xl build/ring16/_x build/ring16/_xl
rm -rf .local .Xil .run 2>/dev/null
rm -f BUILD_DONE BUILD_STATUS SWEEP_DONE ring16_resumed.txt ring16_paused.pids
# 4. verify nothing build-related survives
echo "=== leftover orchestrators/watchers (want: none) ==="
pgrep -af "build_xclbin_u280|resume_ring16|run_after_builds"
echo "=== leftover build procs (want: none) ==="
pgrep -af "fpga-routing-graph/build/tree|fpga-routing-graph/build/ring16"
echo "=== leftover vpl/v++ (want: none) ==="
pgrep -a vpl; pgrep -a "v\+\+"
echo "done"
