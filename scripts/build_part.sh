#!/bin/bash
# build_part.sh -- build every partition of a graph as its own xclbin, on an
# NRP Coder box. Runs ON the workspace; the weave launches it detached.
#
#   TARGET=u280 bash scripts/build_part.sh ring50 2 block     # csg-fpga-compile0
#   TARGET=u55c bash scripts/build_part.sh ring50 2 block     # csg-fpga-compile3
#
#   $1  graph name (examples/<name>.edges)
#   $2  number of partitions            (default 2)
#   $3  split: block | interleave       (default block)
#
# Writes build/<name>_p<K>of<M>_<split>/kernel.xclbin for each K and prints a
# BUILD_RESULT line per partition that the weave parses.
#
# Every guard here exists because of a failure seen for real; see the `fpga`
# skill section 6 and scripts/build_xclbin_u280.sh.
set -uo pipefail                 # NOT -e: a failed partition must still report

NAME="${1:-ring50}"
NPARTS="${2:-2}"
SPLIT="${3:-block}"
TARGET="${TARGET:-u280}"
VITIS_VER="${VITIS_VER:-2023.2}"
STALL_LIMIT="${STALL_LIMIT:-900}"
PARALLEL="${PARALLEL:-0}"        # 1 = link all partitions at once (heavy)
POLL=60

cd "$(dirname "$0")/.."
ROOT="$PWD"

case "$TARGET" in
  u280) XPFM_GLOB='xilinx_u280*xdma*.xpfm'; CFG="$ROOT/scripts/u280.cfg" ;;
  u55c) XPFM_GLOB='xilinx_u55c*xdma*.xpfm'; CFG="$ROOT/scripts/u55c.cfg" ;;
  *)    echo "BUILD_RESULT status=fail reason=unknown_target:$TARGET"; exit 1 ;;
esac

echo "[$(date +%H:%M:%S)] target=$TARGET graph=$NAME nparts=$NPARTS split=$SPLIT"

source "/tools/Xilinx/Vitis/$VITIS_VER/settings64.sh" 2>/dev/null || {
    echo "BUILD_RESULT status=fail reason=no_vitis_$VITIS_VER"; exit 1; }

# --- the libudev shim ------------------------------------------------------
# Vivado heap-aborts ~6 min into the link without this, and v++ never reaps it,
# so the run looks like a slow link for as long as you let it. LD_PRELOAD does
# NOT work: the symbols are dlsym'd off a dlopen handle.
STUB="$HOME/udevstub"
if [ ! -f "$STUB/libudev.so.1" ]; then
    STUBSRC=""
    for c in "$ROOT/scripts/udev_stub.c" \
             "$HOME/my_artifacts/NRP_Coder_HLS_To_FABRIC/tools/udev_stub.c"; do
        [ -f "$c" ] && STUBSRC="$c" && break
    done
    if [ -n "$STUBSRC" ]; then
        echo "[$(date +%H:%M:%S)] building libudev shim from $STUBSRC"
        mkdir -p "$STUB"
        gcc -shared -fPIC -o "$STUB/libudev.so.1" "$STUBSRC" || {
            echo "BUILD_RESULT status=fail reason=udev_shim_build_failed"; exit 1; }
    else
        echo "[$(date +%H:%M:%S)] WARNING: no udev_stub.c found; the link may"
        echo "    heap-abort ~6 min in and then sit at 0% CPU forever."
    fi
fi
[ -d "$STUB" ] && export LD_LIBRARY_PATH="$STUB:${LD_LIBRARY_PATH:-}"

XPFM="${XPFM:-$(find /opt/xilinx "$HOME" /tools -maxdepth 6 -name "$XPFM_GLOB" 2>/dev/null | head -1)}"
[ -n "$XPFM" ] || { echo "BUILD_RESULT status=fail reason=no_platform_xpfm:$XPFM_GLOB"; exit 1; }
echo "[$(date +%H:%M:%S)] platform: $XPFM"

# --- generate every partition, then GATE on the wiring --------------------
# check_wiring.py needs no compiler and takes under a second. Running it before
# the links means a generator bug costs a second, not two hours of place-and-route.
DIRS=()
for ((K=0; K<NPARTS; K++)); do
    D="build/${NAME}_p${K}of${NPARTS}_${SPLIT}"
    python3 graphgen/gen_hls_partitioned.py "examples/${NAME}.edges" \
            --part "$K" --nparts "$NPARTS" --split "$SPLIT" --name "$NAME" || {
        echo "BUILD_RESULT status=fail reason=generate_failed_part$K"; exit 1; }
    DIRS+=("$D")
done
if ! python3 sim/check_wiring.py "${DIRS[@]}"; then
    echo "BUILD_RESULT status=fail reason=wiring_check_failed"
    echo "  The generated kernels do not match the graph. Fix the generator"
    echo "  before spending link time; nothing below would be trustworthy."
    exit 1
fi

# --- sweep stale processes -------------------------------------------------
# A killed v++ orphans an xcd daemon that breaks the NEXT run. Never pkill -f:
# the pattern matches this script's own command line and kills it (trap 22/the
# build-dir self-match that cost a whole reported build on 2026-10-26).
for p in $(ps -eo pid,args --ppid 1 | grep -E 'xcd --port|vivado|v\+\+' | grep -v grep | awk '{print $1}'); do
    echo "[$(date +%H:%M:%S)] killing orphan $p"; kill -9 "$p" 2>/dev/null
done

link_one() {
    local K="$1"
    local D="$ROOT/build/${NAME}_p${K}of${NPARTS}_${SPLIT}"
    local TAG="p${K}of${NPARTS}"
    rm -rf "$D/_x" "$D/_xl"          # never reuse a temp dir from a crashed run

    echo "[$(date +%H:%M:%S)] [$TAG] COMPILE START"
    v++ -c -t hw --platform "$XPFM" -k graph_engine_part -I"$D" \
        "$D/graph_engine.cpp" --temp_dir "$D/_x" -o "$D/kernel.xo" \
        > "$D/vpp_compile.log" 2>&1
    echo "[$(date +%H:%M:%S)] [$TAG] COMPILE END rc=$?"
    if [ ! -f "$D/kernel.xo" ]; then
        echo "--- last 20 lines of $TAG vpp_compile.log ---"
        tail -20 "$D/vpp_compile.log" | cut -c1-160
        echo "BUILD_RESULT part=$K status=fail reason=compile_failed"; return 1
    fi

    echo "[$(date +%H:%M:%S)] [$TAG] LINK START"
    v++ -l -t hw --platform "$XPFM" --config "$CFG" "$D/kernel.xo" \
        --temp_dir "$D/_xl" -o "$D/kernel.xclbin" > "$D/vpp_link.log" 2>&1 &
    local VPID=$!
    local last_change=$(date +%s)
    while kill -0 $VPID 2>/dev/null; do
        sleep $POLL
        # A crashed link and a slow one look identical at a glance, so watch
        # for the crash dump and for the temp dir going quiet.
        if find "$D/_xl" -name 'hs_err_pid*.log' 2>/dev/null | grep -q .; then
            echo "[$(date +%H:%M:%S)] [$TAG] *** VIVADO CRASHED (hs_err dump) -- aborting"
            pkill -9 -P $VPID 2>/dev/null; kill -9 $VPID 2>/dev/null; break
        fi
        if [ "$(find "$D/_xl" -type f -newermt "-${STALL_LIMIT} seconds" 2>/dev/null | wc -l)" -gt 0 ]; then
            last_change=$(date +%s)
        fi
        if [ $(( $(date +%s) - last_change )) -ge $STALL_LIMIT ]; then
            echo "[$(date +%H:%M:%S)] [$TAG] *** STALLED ${STALL_LIMIT}s with no file activity -- aborting"
            pkill -9 -P $VPID 2>/dev/null; kill -9 $VPID 2>/dev/null; break
        fi
    done
    wait $VPID 2>/dev/null
    echo "[$(date +%H:%M:%S)] [$TAG] LINK END rc=$?"

    # The timing verdict is NOT reliably in vpp_link.log -- one real design-C
    # build printed it and an identical one printed nothing. Read the routed
    # report and record the NUMBERS: a +0.007 ns pass and a comfortable one
    # read the same in prose, and every design-C bitstream closed within 16 ps.
    local WNS="" WHS="" MET="unknown" RPT
    RPT=$(find "$D/_xl" -name '*timing_summary_routed.rpt' 2>/dev/null | head -1)
    if [ -n "$RPT" ]; then
        read -r WNS WHS <<< "$(grep -A6 'Design Timing Summary' "$RPT" | tail -1 | awk '{print $1, $5}')"
        grep -q 'All user specified timing constraints are met' "$RPT" && MET="yes" || MET="no"
        cp "$RPT" "$D/timing_summary_routed.rpt" 2>/dev/null
    fi

    if [ -f "$D/kernel.xclbin" ]; then
        echo "BUILD_RESULT part=$K status=ok target=$TARGET" \
             "bytes=$(stat -c%s "$D/kernel.xclbin")" \
             "sha256=$(sha256sum "$D/kernel.xclbin" | cut -d' ' -f1)" \
             "wns=${WNS:-NA} whs=${WHS:-NA} timing_met=$MET"
    else
        echo "--- last 20 lines of $TAG vpp_link.log ---"
        tail -20 "$D/vpp_link.log" | cut -c1-160
        echo "BUILD_RESULT part=$K status=fail reason=no_xclbin wns=${WNS:-NA} timing_met=$MET"
        return 1
    fi
}

rc=0
if [ "$PARALLEL" = "1" ]; then
    # Two concurrent Vivado links on one box doubles peak memory. Sequential is
    # the default because these partitions are tiny (tens of LUTs) and the link
    # time is dominated by the static shell, so parallelism buys little.
    pids=()
    for ((K=0; K<NPARTS; K++)); do link_one "$K" & pids+=($!); done
    for p in "${pids[@]}"; do wait "$p" || rc=1; done
else
    for ((K=0; K<NPARTS; K++)); do link_one "$K" || rc=1; done
fi

# Sweep orphaned xcd daemons ONLY, never by a pattern this script's own command
# line contains -- matching on "$BUILD" did exactly that on 2026-10-26: the
# sweep matched its own pid, killed itself, and never printed BUILD_DONE, so a
# successful build looked like a hung one.
SELF=$$
for p in $(pgrep -f 'xcd --port' 2>/dev/null); do
    [ "$p" = "$SELF" ] && continue
    [ "$p" = "$PPID" ] && continue
    kill -9 "$p" 2>/dev/null
done

{
  echo "build finished at $(date)"
  echo "target=$TARGET graph=$NAME nparts=$NPARTS split=$SPLIT"
  for ((K=0; K<NPARTS; K++)); do
    D="build/${NAME}_p${K}of${NPARTS}_${SPLIT}"
    if [ -f "$D/kernel.xclbin" ]; then
      echo "p$K: OK $(stat -c%s "$D/kernel.xclbin") bytes"
    else
      echo "p$K: MISSING xclbin (see $D/vpp_*.log)"
    fi
  done
} > "BUILD_STATUS_${TARGET}" 2>&1
echo BUILD_DONE
exit $rc
