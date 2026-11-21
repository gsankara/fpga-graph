#!/bin/bash
# build_rtl_part.sh -- build the RTL-kernel xclbin: or_tree.v + graph_or.v
# wrapped by rtl/graph_engine_rtl.v, packaged with package_xo, linked by v++.
#
# Ask 2's second half: no HLS in the datapath at all. The kernel name and its
# five arguments match the generated HLS kernel exactly, so part_query,
# part_agent and compare_part.py drive this xclbin unchanged.
#
#   TARGET=u280 bash scripts/build_rtl_part.sh ring50        # csg-fpga-compile0
#   TARGET=u55c bash scripts/build_rtl_part.sh ring50        # csg-fpga-compile3
#
#   $1  graph name (examples/<name>.edges)
#   REG_EVERY=k  or_tree registering, default 2
#   SKIP_SIM=1   skip the xsim gate (do not: it is the only cheap check)
#
# Writes build/<name>_rtl/kernel.xclbin and prints BUILD_RESULT lines.
set -uo pipefail

NAME="${1:-ring50}"
TARGET="${TARGET:-u280}"
REG_EVERY="${REG_EVERY:-2}"
VITIS_VER="${VITIS_VER:-2023.2}"
SKIP_SIM="${SKIP_SIM:-0}"

cd "$(dirname "$0")/.."
ROOT="$PWD"
D="$ROOT/build/${NAME}_rtl"

case "$TARGET" in
  u280) XPFM_GLOB='xilinx_u280*xdma*.xpfm'; CFG="$ROOT/scripts/u280.cfg"
        PART='xcu280-fsvh2892-2L-e' ;;
  u55c) XPFM_GLOB='xilinx_u55c*xdma*.xpfm'; CFG="$ROOT/scripts/u55c.cfg"
        PART='xcu55c-fsvh2892-2L-e' ;;
  *)    echo "BUILD_RESULT status=fail reason=unknown_target:$TARGET"; exit 1 ;;
esac

mkdir -p "$D"
echo "[$(date +%H:%M:%S)] target=$TARGET graph=$NAME reg_every=$REG_EVERY rtl=yes"

source "/tools/Xilinx/Vitis/$VITIS_VER/settings64.sh" 2>/dev/null || {
    echo "BUILD_RESULT status=fail reason=no_vitis_$VITIS_VER"; exit 1; }

# The libudev shim: Vivado heap-aborts ~6 min into the link without it and v++
# never reaps it, so the run looks like a slow link for as long as you let it.
STUB="$HOME/udevstub"
if [ ! -f "$STUB/libudev.so.1" ]; then
    for c in "$ROOT/scripts/udev_stub.c" \
             "$HOME/my_artifacts/NRP_Coder_HLS_To_FABRIC/tools/udev_stub.c"; do
        [ -f "$c" ] && { mkdir -p "$STUB"
            gcc -shared -fPIC -o "$STUB/libudev.so.1" "$c" || true; break; }
    done
fi
[ -d "$STUB" ] && export LD_LIBRARY_PATH="$STUB:${LD_LIBRARY_PATH:-}"

# --- 1. generate the graph as RTL -----------------------------------------
python3 graphgen/gen_rtl_or.py "examples/${NAME}.edges" \
        --reg-every "$REG_EVERY" --name "$NAME" -o "$D" || {
    echo "BUILD_RESULT status=fail reason=gen_rtl_failed"; exit 1; }
[ -f "$D/graph_or.v" ] || {
    echo "BUILD_RESULT status=fail reason=no_graph_or_v"; exit 1; }

N=$(sed -n 's|^// vertices  *\([0-9]\+\).*|\1|p' "$D/graph_or.v" | head -1)
[ -n "$N" ] || { echo "BUILD_RESULT status=fail reason=cannot_read_N"; exit 1; }
echo "[$(date +%H:%M:%S)] graph_or.v: N=$N"

# --- 2. the xsim gate -----------------------------------------------------
# Under a second against two hours of place-and-route. The kernel talks AXI to
# behavioural memories and is checked against reference.py's vectors, with and
# without slave stalls. Skipping this is how an AXI bug reaches hardware.
if [ "$SKIP_SIM" != "1" ]; then
    python3 graphgen/gen_rtl_or.py "examples/${NAME}.edges" \
            --reg-every "$REG_EVERY" --name "$NAME" \
            --emit-vectors 2000 -o "$D" >/dev/null || {
        echo "BUILD_RESULT status=fail reason=gen_vectors_failed"; exit 1; }
    ( cd "$D" || exit 1
      rm -rf xsim.dir .Xil
      xvlog "$ROOT/rtl/or_tree.v" graph_or.v \
            "$ROOT/rtl/graph_engine_rtl.v" "$ROOT/rtl/axi_mem_model.v" \
            "$ROOT/rtl/tb_graph_engine_rtl.v" > xvlog.log 2>&1 || {
          echo "BUILD_RESULT status=fail reason=xvlog_failed"
          tail -20 xvlog.log; exit 1; }
      for TOP in tb_graph_engine_rtl tb_graph_engine_rtl_stall; do
          # -generic_top overrides the TB's N. xelab documents it for VHDL
          # generics and accepts it for Verilog parameters in most versions;
          # where it does not, fall back to the TB default (N=50 = ring50)
          # rather than failing a build over a simulator flag.
          xelab -debug off -top "$TOP" -snapshot "snap_$TOP" \
                -generic_top "N=$N" >> xelab.log 2>&1 \
          || xelab -debug off -top "$TOP" -snapshot "snap_$TOP" \
                >> xelab.log 2>&1 || {
              echo "BUILD_RESULT status=fail reason=xelab_failed:$TOP"
              tail -20 xelab.log; exit 1; }
          xsim "snap_$TOP" -runall > "xsim_$TOP.log" 2>&1
          if grep -q 'TB_RESULT: PASS' "xsim_$TOP.log"; then
              echo "[$(date +%H:%M:%S)] xsim $TOP: PASS"
          else
              echo "BUILD_RESULT status=fail reason=sim_failed:$TOP"
              grep -E 'TB_RESULT|FAIL|ERROR' "xsim_$TOP.log" | head -20
              exit 1
          fi
      done ) || exit 1
fi

# --- 3. package the .xo ---------------------------------------------------
# A killed v++ orphans an xcd daemon that breaks the NEXT run. Never pkill -f:
# the pattern matches this script's own command line.
for p in $(ps -eo pid,args --ppid 1 | grep -E 'xcd --port|vivado|v\+\+' \
           | grep -v grep | awk '{print $1}'); do
    echo "[$(date +%H:%M:%S)] killing orphan $p"; kill -9 "$p" 2>/dev/null
done

rm -f "$D/kernel.xo"
echo "[$(date +%H:%M:%S)] PACKAGE START"
( cd "$D" && vivado -mode batch -nojournal -nolog \
      -source "$ROOT/scripts/package_rtl_xo.tcl" \
      -tclargs "$D/kernel.xo" "$D/graph_or.v" "$PART" "$N" "$REG_EVERY" \
      > "$D/package.log" 2>&1 )
if [ ! -f "$D/kernel.xo" ]; then
    echo "BUILD_RESULT status=fail reason=package_xo_failed"
    grep -E 'ERROR|CRITICAL' "$D/package.log" | head -20
    exit 1
fi
echo "[$(date +%H:%M:%S)] PACKAGE OK $(stat -c%s "$D/kernel.xo") bytes"

# --- 4. link --------------------------------------------------------------
XPFM="${XPFM:-$(find /opt/xilinx "$HOME" /tools -maxdepth 6 -name "$XPFM_GLOB" \
       2>/dev/null | head -1)}"
[ -n "$XPFM" ] || { echo "BUILD_RESULT status=fail reason=no_platform_xpfm"; exit 1; }
echo "[$(date +%H:%M:%S)] platform: $XPFM"
echo "[$(date +%H:%M:%S)] LINK START (expect ~2 h)"
rm -rf "$D/_xl"
v++ -l -t hw --platform "$XPFM" --config "$CFG" "$D/kernel.xo" \
    --temp_dir "$D/_xl" -o "$D/kernel.xclbin" > "$D/vpp_link.log" 2>&1
if [ ! -f "$D/kernel.xclbin" ]; then
    echo "BUILD_RESULT status=fail reason=link_failed"
    grep -E 'ERROR|CRITICAL WARNING' "$D/vpp_link.log" | head -20
    exit 1
fi

# The routed-timing verdict is NOT reliably in vpp_link.log; it lives here.
RPT=$(find "$D/_xl" -name '*timing_summary_routed.rpt' 2>/dev/null | head -1)
WNS="unknown"; WHS="unknown"
if [ -n "$RPT" ]; then
    WNS=$(grep -A6 'Design Timing Summary' "$RPT" | awk 'NF>3 {print $1; exit}')
    WHS=$(grep -A6 'Design Timing Summary' "$RPT" | awk 'NF>3 {print $5; exit}')
    cp "$RPT" "$D/timing_summary_routed.rpt"
fi
echo "BUILD_RESULT status=ok kernel=$D/kernel.xclbin" \
     "bytes=$(stat -c%s "$D/kernel.xclbin")" \
     "sha256=$(sha256sum "$D/kernel.xclbin" | cut -d' ' -f1)" \
     "wns=$WNS whs=$WHS n=$N reg_every=$REG_EVERY rtl=yes"
