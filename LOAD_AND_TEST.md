# Building the U280 bitstream, loading it, and testing

This project targets a **Xilinx Alveo U280** (`xcu280-fsvh2892-2L-e`). The
repo ships, per sample graph, everything needed to build and run:

```
prebuilt/<graph>/
  graph_engine.cpp        baked kernel (edges = OR wiring), U280-synthesized
  graph_wire.hpp          parameters (N, packing, latch mode)
  graph_engine_csynth.rpt Vitis HLS report (II=1, Fmax, resources) on xcu280
  graph_engine_ip_u280.zip packaged HLS IP (Verilog RTL), xcu280
  expected.txt            golden trace + final active set (self-check oracle)
  graph.meta.json         provenance / stats
```

> **Why no `.xclbin` in the repo?** An Alveo `xclbin` must be linked against the
> exact **platform (shell)** installed on the machine that hosts the card. The
> build box (`csg-fpga-compile.coder`) has no U280 platform and no internet to
> fetch one, so the final link must happen where the U280 lives. Everything up
> to that link is prebuilt and included. Steps 1–2 below produce the `xclbin` on
> the target machine in one command each.

---

## 0. Prerequisites on the target machine

- Alveo U280 with its shell flashed (`xbmgmt examine` shows the card).
- Xilinx **XRT** installed and sourced: `source /opt/xilinx/xrt/setup.sh`.
- The U280 **development platform** installed. List what you have:
  ```bash
  platforminfo -l | grep u280
  ```
  Note the exact `baseName` (e.g. `xilinx_u280_gen3x16_xdma_1_202211_1`) and
  pass it as `PLATFORM=` below. It must match your shell.
- Vitis 2023.2 (to run `v++`). The kernel source is toolchain-portable.

## 1. Build the xclbin (per graph) — ~1–2 h each (P&R of the shell dominates)

```bash
make xclbin GRAPH=tree   PLATFORM=<your_u280_platform>
make xclbin GRAPH=ring16 PLATFORM=<your_u280_platform>
```

This runs, under the hood:
```bash
v++ -c -t hw --platform <plat> -k graph_engine -Ibuild/<graph> \
    build/<graph>/graph_engine.cpp -o build/<graph>/graph_engine.xo
v++ -l -t hw --platform <plat> \
    build/<graph>/graph_engine.xo -o build/<graph>/graph_engine.xclbin
```

`make gen GRAPH=<graph>` (run automatically) recreates `build/<graph>/` from the
edge list, including `expected.txt`. To skip the long build first, sanity-check
the flow with software emulation:
```bash
make xclbin GRAPH=tree TARGET=sw_emu PLATFORM=<plat>
XCL_EMULATION_MODE=sw_emu make run GRAPH=tree
```

## 2. Build the host program (once)

```bash
make host          # -> build/host_graph  (links against XRT)
```

## 3. Load onto the card and self-check

```bash
make run GRAPH=tree      # loads build/tree/graph_engine.xclbin, checks vs golden
make run GRAPH=ring16
```

`make run` invokes:
```bash
build/host_graph build/<graph>/graph_engine.xclbin build/<graph>/expected.txt
```

The host seeds the initial node(s), runs the wavefront `STEPS` cycles on the
FPGA (one graph hop per clock), reads back the final state + per-step
active-count trace, and compares against `expected.txt`.

### Expected output

`tree` (11-node binary tree, seed 0, latch/flood-fill):
```
[host] hw trace (active/step): 3 7 11 11
[host] expected trace        : 3 7 11 11
[host] active_final hw=11 golden=11  errors=0
PASS
```

`ring16` (16-node ring, seed 0, latch/flood-fill):
```
[host] hw trace (active/step): 3 5 7 9 11 13 15 16 16
[host] expected trace        : 3 5 7 9 11 13 15 16 16
[host] active_final hw=16 golden=16  errors=0
PASS
```

The trace *is* the BFS wavefront: each step is the count of nodes reached within
that many hops of the seed. `tree` fills in 3 hops (its depth); `ring16` reaches
the antipode at hop 8.

## 4. Your own graph

```bash
python graphgen/gen_hls.py my_graph.edges --seed 0 --mode latch --name mygraph
make xclbin GRAPH=mygraph PLATFORM=<plat>
make run    GRAPH=mygraph
```

See the top-level `README.md` for the `.edges` format, `pulse` vs `latch`
modes, and scaling limits (why very large graphs must be partitioned).
