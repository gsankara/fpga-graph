#!/bin/bash
# build_xclbin_u280.sh -- build hardware xclbins for the sample graphs against
# the U280 platform. Run on the build box in a login shell.
#
#   XPFM=/path/to/xilinx_u280...xpfm  bash scripts/build_xclbin_u280.sh [graphs...]
#
# Builds run in parallel; writes BUILD_STATUS + BUILD_DONE sentinel on finish.
set -u
cd "$(dirname "$0")/.."
ROOT="$PWD"
XPFM="${XPFM:?set XPFM to the U280 .xpfm path}"
GRAPHS=("${@:-tree ring16}")
GRAPHS=(${GRAPHS[@]})

rm -f BUILD_DONE BUILD_STATUS

build_one() {
  local G="$1"
  local L="$ROOT/build/$G"
  python3 graphgen/gen_hls.py "examples/$G.edges" --seed 0 --name "$G" >/dev/null
  echo "[$(date +%H:%M:%S)] $G: v++ compile ..."
  v++ -c -t hw --platform "$XPFM" -k graph_engine -I"$L" "$L/graph_engine.cpp" \
      --temp_dir "$L/_x" -o "$L/graph_engine.xo" > "$L/vpp_compile.log" 2>&1
  local rc=$?
  if [ $rc -ne 0 ]; then echo "[$G] COMPILE FAILED rc=$rc"; return $rc; fi
  echo "[$(date +%H:%M:%S)] $G: v++ link (long) ..."
  v++ -l -t hw --platform "$XPFM" "$L/graph_engine.xo" \
      --temp_dir "$L/_xl" -o "$L/graph_engine.xclbin" > "$L/vpp_link.log" 2>&1
  echo "[$G] link rc=$?"
}

pids=()
for G in "${GRAPHS[@]}"; do build_one "$G" & pids+=($!); done
rc=0
for p in "${pids[@]}"; do wait "$p" || rc=1; done

{
  echo "build finished at $(date)"
  for G in "${GRAPHS[@]}"; do
    if [ -f "build/$G/graph_engine.xclbin" ]; then
      echo "$G: OK  $(ls -la build/$G/graph_engine.xclbin | awk '{print $5, $9}')"
    else
      echo "$G: MISSING xclbin (see build/$G/vpp_*.log)"
    fi
  done
} > BUILD_STATUS 2>&1
touch BUILD_DONE
exit $rc
