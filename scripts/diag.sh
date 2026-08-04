#!/bin/bash
# diag.sh -- is the load CPU-bound or I/O-bound, and who owns it?
echo "=== vmstat: r=runnable(CPU) b=blocked(D/IO-wait)  wa=IO-wait%  id=idle% ==="
vmstat 1 3
echo
echo "=== process-state histogram (R=onCPU/runnable  D=IO-wait  S=sleep  T=stopped) ==="
ps -eo stat --no-headers | cut -c1 | sort | uniq -c | sort -rn
echo
echo "=== processes per user (who owns the swarm) ==="
ps -eo user --no-headers | sort | uniq -c | sort -rn | head
echo
echo "=== Vivado/Vitis processes by user ==="
ps -eo user:14,comm --no-headers | grep -iE "vivado|vpl|vitis|v\+\+|abc|synth" | sort | uniq -c | sort -rn | head
echo
echo "=== top 15 CPU consumers: user %cpu state cmd ==="
ps -eo user:14,pcpu,stat,comm --sort=-pcpu --no-headers | head -15
echo
echo "=== my build procs ==="
echo -n "tree (running): ";  pgrep -f "fpga-routing-graph/build/tree"   | wc -l
echo -n "ring16 (paused): "; pgrep -f "fpga-routing-graph/build/ring16" | wc -l
echo -n "resume watcher: ";  pgrep -f resume_ring16.sh | wc -l
echo
echo "=== storage backing /home/coder (Ceph RBD = network block dev) ==="
df -hT ~ | tail -1
