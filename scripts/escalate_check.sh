#!/bin/bash
cd ~/fpga-routing-graph || exit 1
R=build/tree/_xl/link/vivado/vpl/runme.log
echo "=== did maxThreads=1 apply? (runCacheChecks thread count) ==="
grep -m1 "number of threads" "$R" 2>/dev/null
echo "=== was Vivado_init.tcl sourced? ==="
grep -m1 -iE "Vivado_init|maxThreads" "$R" 2>/dev/null || echo "(no mention in log)"
echo "=== glibc version ==="
ldd --version 2>/dev/null | head -1
echo "=== alternative allocators available (drop-in heap fix)? ==="
ldconfig -p 2>/dev/null | grep -iE "jemalloc|tcmalloc|libmimalloc" | head
ls /usr/lib/x86_64-linux-gnu/ 2>/dev/null | grep -iE "jemalloc|tcmalloc|mimalloc"
echo "=== hs_err faulting frame ==="
f=$(ls -t build/tree/_xl/link/vivado/vpl/hs_err_pid*.log 2>/dev/null | head -1)
echo "file: $f"
grep -iE "Problematic frame|libc|malloc|realloc|Signal" "$f" 2>/dev/null | head -6
echo "=== container runtimes available ==="
for c in docker podman singularity apptainer; do
  if command -v "$c" >/dev/null 2>&1; then echo "$c: $("$c" --version 2>/dev/null | head -1)"; fi
done
