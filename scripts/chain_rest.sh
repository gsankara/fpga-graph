#!/bin/bash
# chain_rest.sh -- after the already-running tree build finishes, build ring16
# and run the capacity sweep. Writes ALL_DONE when everything completes.
cd ~/fpga-routing-graph || exit 1
# wait for the in-flight tree build to finish (tree_DONE touched by build_graph.sh)
while [ ! -f tree_DONE ]; do sleep 60; done
echo "[$(date +%H:%M:%S)] tree done; building ring16" > chain_rest.out
bash scripts/build_graph.sh ring16 >> chain_rest.out 2>&1
echo "[$(date +%H:%M:%S)] ring16 done; running capacity sweep" >> chain_rest.out
bash scripts/capacity_sweep.sh > sweep.out 2>&1
{
  echo "all finished $(date)"
  for G in tree ring16; do
    if [ -f "build/$G/graph_engine.xclbin" ]; then
      echo "$G: OK  $(ls -la build/$G/graph_engine.xclbin | awk '{print $5, $9}')"
    else
      echo "$G: MISSING (see build/$G/vpp_link.log)"
    fi
  done
} > ALL_STATUS 2>&1
touch ALL_DONE
