#!/bin/bash
# capacity_sweep.sh -- csynth a ladder of graph sizes on xcu280 and record
# LUT/FF/Fmax, to find the practical baked-wiring ceiling on one U280.
# Run on the build box (login shell). Writes capacity_results.txt.
set -u
cd "$(dirname "$0")/.."
PART=xcu280-fsvh2892-2L-e
OUT=capacity_results.txt
mkdir -p examples/cap
{
  echo "# capacity sweep on $PART  $(date)"
  echo "# device: LUT 1,303,680  FF 2,607,360"
  printf "# %-8s %-6s %-10s %-9s %-9s %-9s %-18s %s\n" \
         N degree terms LUT FF "Fmax(MHz)" status seconds
} > "$OUT"

run() {
  local N=$1 D=$2
  local name="cap_n${N}_d${D}"
  local terms=$((N * D))
  python3 graphgen/make_graph.py --nodes "$N" --degree "$D" -o "examples/cap/$name.edges" >/dev/null 2>&1
  python3 graphgen/gen_hls.py "examples/cap/$name.edges" --seed 0 --name "$name" \
          --steps 4 --max-terms 100000000 >/dev/null 2>&1
  local t0 t1 rc; t0=$(date +%s)
  GDIR="$PWD/build/$name" PART="$PART" PERIOD=3.33 RUN_CSIM=0 STOP=csynth \
    timeout 5400 vitis_hls -f hls/run_hls.tcl > "build/$name/csynth.log" 2>&1
  rc=$?; t1=$(date +%s)
  local R="build/$name/hls_proj/sol1/syn/report/graph_engine_csynth.rpt"
  local fmax lut ff
  fmax=$(grep -oE "Estimated Fmax: [0-9.]+" "build/$name/csynth.log" | tail -1 | grep -oE "[0-9.]+$")
  if [ -f "$R" ]; then
    # Utilization Summary "Total" row: Name BRAM18K DSP FF LUT URAM
    read -r ff lut < <(awk '/Total/{gsub(/\|/," "); print $4, $5; exit}' "$R")
  fi
  local status=OK
  [ "$rc" -ne 0 ] && status="FAIL_rc$rc"
  [ -f "build/$name/graph_engine.xclbin" ] 2>/dev/null
  printf "%-10s %-6s %-10s %-9s %-9s %-9s %-18s %ss\n" \
         "$N" "$D" "$terms" "${lut:--}" "${ff:--}" "${fmax:--}" "$status" "$((t1 - t0))" >> "$OUT"
  echo "[sweep] N=$N D=$D terms=$terms -> LUT=${lut:--} FF=${ff:--} Fmax=${fmax:--} $status $((t1-t0))s"
}

# Ladder as space-separated "N:degree" pairs; override with the LADDER env var.
# Default descends in size to find the practical csynth ceiling: 20000 nodes
# (400k OR terms) exceeds Vitis HLS's single-basic-block instruction limit and
# fails, so we probe smaller graphs to locate where synthesis passes.
# Empirically, csynth time blows up superlinearly: N=500 ~9min, N=1000 ~86min,
# N=2000 times out (>90min). So the flat-baked single-kernel ceiling is ~1000
# nodes / ~20k OR terms -- far below the device's resource capacity. Default
# ladder stops at 2000 (the timeout point); override with the LADDER env var.
LADDER="${LADDER:-500:20 1000:20 2000:20}"
for pair in $LADDER; do
  run "${pair%%:*}" "${pair##*:}"
done
echo "DONE" >> "$OUT"
echo "[sweep] complete -> $OUT"
