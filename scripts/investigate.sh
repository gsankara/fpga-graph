#!/bin/bash
# investigate.sh -- find the context-switch-storm source and tree's real P&R phase.
echo "=== total tasks (threads) vs processes ==="
echo "threads: $(ps -eLf --no-headers 2>/dev/null | wc -l)   processes: $(ps -e --no-headers | wc -l)"
echo
echo "=== top processes by thread count (nlwp) ==="
ps -eo pid,nlwp,stat,pcpu,user,comm --sort=-nlwp --no-headers | head -8
echo
echo "=== per-task context-switch rate (pidstat if present) ==="
if command -v pidstat >/dev/null 2>&1; then
  pidstat -wt 1 1 2>/dev/null | awk 'NR>3 && ($4+$5)>1000 {print}' | sort -k5 -rn | head -12
else
  echo "pidstat not installed; sampling /proc ctxt_switches for top-thread procs:"
  for p in $(ps -eo pid --sort=-nlwp --no-headers | head -6); do
    a=$(awk '/ctxt_switches/{s+=$2} END{print s}' /proc/$p/status 2>/dev/null)
    sleep 1
    b=$(awk '/ctxt_switches/{s+=$2} END{print s}' /proc/$p/status 2>/dev/null)
    echo "pid $p  cs/s=$((b-a))  threads=$(ps -o nlwp= -p $p 2>/dev/null|tr -d ' ')  $(ps -o comm= -p $p 2>/dev/null)"
  done
fi
echo
echo "=== tree Vivado implementation: latest log + phase ==="
L=$(find build/tree/_xl -name runme.log 2>/dev/null | xargs ls -t 2>/dev/null | head -1)
echo "log: $L"
tail -6 "$L" 2>/dev/null
echo "--- phase markers ---"
grep -E "Phase|route_design|place_design|Router|Placer|Starting|Ending|Time \(s\)" "$L" 2>/dev/null | tail -8
