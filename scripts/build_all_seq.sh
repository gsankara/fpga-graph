#!/bin/bash
# build_all_seq.sh -- build U280 xclbins SEQUENTIALLY (tree, then ring16), then
# run the capacity sweep. Sequential execution avoids the parallel Vivado
# IP-cache collision that heap-corrupted both runs on the first attempt.
cd ~/fpga-routing-graph || exit 1
XPFM=~/u280dev/opt/xilinx/platforms/xilinx_u280_gen3x16_xdma_1_202211_1/xilinx_u280_gen3x16_xdma_1_202211_1.xpfm
# Fix for Vivado "realloc(): invalid pointer" on newer OS: preload system
# libudev (Vivado's bundled libudev is too old). Xilinx AR 000034450.
LIBUDEV=/usr/lib/x86_64-linux-gnu/libudev.so.1
[ -f "$LIBUDEV" ] && export LD_PRELOAD="$LIBUDEV"
rm -f BUILD_DONE SWEEP_DONE BUILD_STATUS

build_one() {
  local G="$1"
  local L="$PWD/build/$G"
  python3 graphgen/gen_hls.py "examples/$G.edges" --seed 0 --name "$G" >/dev/null 2>&1
  echo "[$(date +%H:%M:%S)] $G: v++ compile"
  v++ -c -t hw --platform "$XPFM" -k graph_engine -I"$L" "$L/graph_engine.cpp" \
      --temp_dir "$L/_x" -o "$L/graph_engine.xo" > "$L/vpp_compile.log" 2>&1 \
      || { echo "[$G] COMPILE FAILED"; return 1; }
  echo "[$(date +%H:%M:%S)] $G: v++ link (P&R, the long step)"
  v++ -l -t hw --platform "$XPFM" "$L/graph_engine.xo" \
      --temp_dir "$L/_xl" -o "$L/graph_engine.xclbin" > "$L/vpp_link.log" 2>&1
  echo "[$(date +%H:%M:%S)] $G: link rc=$?"
}

build_one tree
build_one ring16

{
  echo "sequential build finished $(date)"
  for G in tree ring16; do
    if [ -f "build/$G/graph_engine.xclbin" ]; then
      echo "$G: OK   $(ls -la build/$G/graph_engine.xclbin | awk '{print $5, $9}')"
    else
      echo "$G: MISSING (see build/$G/vpp_link.log)"
    fi
  done
} > BUILD_STATUS 2>&1
touch BUILD_DONE

# capacity sweep after both bitstreams
bash scripts/capacity_sweep.sh > sweep.out 2>&1
touch SWEEP_DONE
