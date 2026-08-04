#!/bin/bash
# resume_ring16.sh -- wait until tree's place-and-route finishes, then SIGCONT
# the paused ring16 build. Self-discovering: re-finds the stopped ring16
# processes at resume time, so it needs no saved PID file.
cd ~/fpga-routing-graph || exit 1
# tree is done when its link temp-dir process is gone (success or fail)
while pgrep -f "fpga-routing-graph/build/tree/_xl" >/dev/null 2>&1; do
  sleep 60
done
sleep 15
kill -CONT $(pgrep -f "fpga-routing-graph/build/ring16") 2>/dev/null
date > ring16_resumed.txt
