#!/bin/bash
cd ~/fpga-routing-graph || exit 1
R=build/tree/_xl/link/vivado/vpl/runme.log
echo "=== hs_err crash logs in tree build (count + newest) ==="
find build/tree -name "hs_err_pid*.log" 2>/dev/null | wc -l
find build/tree -name "hs_err_pid*.log" -printf "%TY-%Tm-%Td %TH:%TM  %p\n" 2>/dev/null | sort | tail -5
echo
echo "=== crash markers in runme.log ==="
echo -n "Abnormal terminations: "; grep -c "Abnormal program termination" "$R" 2>/dev/null
echo -n "heap-corruption lines:  "; grep -cE "realloc\(\)|invalid pointer|corrupted|double free|malloc" "$R" 2>/dev/null
echo
echo "=== tree processes: state + age ==="
for p in $(pgrep -f "fpga-routing-graph/build/tree"); do ps -o pid,stat,etime,comm -p "$p" --no-headers 2>/dev/null; done
echo
echo "=== does v++ report failure yet? (vpp_link.log tail) ==="
tail -6 build/tree/vpp_link.log 2>/dev/null
echo
echo "=== newest crash log: signal + faulting op ==="
f=$(find build/tree -name "hs_err_pid*.log" -printf "%T@ %p\n" 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2)
echo "file: $f"
grep -E "Signal|Current thread|abort|realloc|Problematic|Stack:|libc|vivado" "$f" 2>/dev/null | head -12
