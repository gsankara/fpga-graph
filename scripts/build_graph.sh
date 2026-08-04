#!/bin/bash
# build_graph.sh <graph> -- build one U280 xclbin (compile + link). Writes
# <graph>_DONE sentinel. Use to test/build a single graph in isolation.
G="${1:?usage: build_graph.sh <graph>}"
cd ~/fpga-routing-graph || exit 1
# Vivado 2023.2 vs Ubuntu 24.04 glibc 2.39: glibc's malloc aborts on Vivado's
# heap ops (realloc: invalid pointer). Preload tcmalloc to replace the allocator
# and bypass the abort. This is the working fix for the IPCACHE threadPool crash.
export LD_PRELOAD=/lib/x86_64-linux-gnu/libtcmalloc_minimal.so.4
XPFM=~/u280dev/opt/xilinx/platforms/xilinx_u280_gen3x16_xdma_1_202211_1/xilinx_u280_gen3x16_xdma_1_202211_1.xpfm
L="$PWD/build/$G"
rm -rf "$L/_x" "$L/_xl" "$L/graph_engine.xclbin"
rm -f "${G}_DONE"
python3 graphgen/gen_hls.py "examples/$G.edges" --seed 0 --name "$G" >/dev/null 2>&1
echo "[$(date +%H:%M:%S)] $G: v++ compile"
v++ -c -t hw --platform "$XPFM" -k graph_engine -I"$L" "$L/graph_engine.cpp" \
    --temp_dir "$L/_x" -o "$L/graph_engine.xo" > "$L/vpp_compile.log" 2>&1 \
    || { echo "[$G] COMPILE FAILED"; touch "${G}_DONE"; exit 1; }
echo "[$(date +%H:%M:%S)] $G: v++ link (P&R)"
v++ -l -t hw --platform "$XPFM" "$L/graph_engine.xo" \
    --temp_dir "$L/_xl" -o "$L/graph_engine.xclbin" > "$L/vpp_link.log" 2>&1
echo "[$(date +%H:%M:%S)] $G: link rc=$?  xclbin=$(ls -la "$L/graph_engine.xclbin" 2>/dev/null | awk '{print $5}')"
touch "${G}_DONE"
