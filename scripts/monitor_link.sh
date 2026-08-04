#!/bin/bash
# monitor_link.sh -- early verdict on the tree link: exits as soon as it sees a
# crash, OR the run clearing IPCACHE into placement/routing, OR completion.
cd ~/fpga-routing-graph || exit 1
R=build/tree/_xl/link/vivado/vpl/runme.log
for i in $(seq 1 60); do
  if find build/tree -name "hs_err_pid*.log" 2>/dev/null | grep -q .; then
    echo "VERDICT: CRASH AGAIN"
    find build/tree -name "hs_err_pid*.log"
    tail -4 "$R" 2>/dev/null
    exit 0
  fi
  if grep -qE "place_design|route_design|Placer|Router " "$R" 2>/dev/null; then
    echo "VERDICT: PAST IPCACHE -> reached placement/routing (sequential fix worked)"
    grep -nE "synth_design|opt_design|place_design|route_design" "$R" 2>/dev/null | tail -4
    exit 0
  fi
  if [ -f BUILD_DONE ]; then echo "VERDICT: BUILD_DONE"; cat BUILD_STATUS; exit 0; fi
  sleep 60
done
echo "VERDICT: still in early phase after 60 min"
tail -4 "$R" 2>/dev/null
