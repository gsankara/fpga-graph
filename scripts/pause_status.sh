#!/bin/bash
# pause_status.sh -- report ring16/tree pause state, resume watcher, and load.
cd ~/fpga-routing-graph || exit 1
echo "=== ring16 processes and states -- T means stopped ==="
for p in $(pgrep -f "fpga-routing-graph/build/ring16"); do
  ps -o pid,stat,comm -p "$p" --no-headers 2>/dev/null
done
echo "=== tree link procs alive ==="
pgrep -f "fpga-routing-graph/build/tree/_xl" | wc -l
echo "=== tree heartbeat ==="
tail -1 build/tree/vpp_link.log 2>/dev/null
echo "=== resume watcher running ==="
pgrep -af "resume_ring16.sh" | grep -v pause_status
echo "=== sentinels ==="
for f in BUILD_DONE ring16_resumed.txt SWEEP_DONE capacity_results.txt; do
  printf "%-22s %s\n" "$f" "$([ -e "$f" ] && echo present || echo -)"
done
echo "=== load ==="
uptime
