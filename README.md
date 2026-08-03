# FPGA Routing-Graph Engine

Bake an arbitrary graph into a synthesizable FPGA design where **the graph is
the wiring**: one flip-flop per node, edges as combinational OR wiring, and a
wavefront that advances **exactly one graph hop per clock cycle**.

This is the hardware realization of the compute model in
`optical-interconnect-design.md`:

- **State:** 1 bit per node (on/off).
- **Activation (the design's headline formula):**
  `next_state[v] = OR over in-neighbours(v)` — the design doc's
  *"column read = wired-OR = activation for free."*
- **Neighbour exploration:** iterating that step is a BFS / flood-fill
  wavefront (design doc §3: "flood-fill, diffusion, short-range propagation").
- **Clock-cycle spec:** each cycle = one hop. After *k* cycles the active set is
  every node within *k* hops of the seed.

## What this produces

A code generator reads a graph and emits a **graph-specialized Vitis HLS
kernel** — the edges are unrolled into per-node OR expressions
(`ns[v] = s[v] | s[u1] | s[u2] | ...`), synthesized to RTL, and (optionally)
built into an Alveo `xclbin` bitstream. "Configure once, run long": the graph
is compiled into the fabric, not streamed from memory.

## Layout

```
graphgen/reference.py     golden software model (single source of truth)
graphgen/gen_hls.py       graph -> baked HLS kernel + testbench + params
hls/run_hls.tcl           Vitis HLS: csim -> csynth -> cosim -> export IP
Makefile                  gen / csim / csynth / cosim / export / xclbin
examples/*.edges          sample graphs (ring16, tree)
build/<graph>/            generated per-graph kernel + reports (git-ignored)
```

## Input format (`.edges`)

```
# undirected          # or: directed        (default undirected)
# nodes 16            # optional: force node count
0 1                   # edge u v, 0-indexed  (u -> v means "v hears u")
1 2
...
```

## Quick start

Local (any machine with Python 3) — generate and self-check:

```
python graphgen/gen_hls.py examples/tree.edges --seed 0 --mode latch
```

On the build box (`csg-fpga-compile.coder`, login shell so Vitis is on PATH):

```
make csim   GRAPH=tree      # baked wiring vs. golden BFS
make csynth GRAPH=tree      # -> Verilog RTL + timing/resource report
make cosim  GRAPH=tree      # RTL vs. testbench, cycle-accurate
make export GRAPH=tree      # packaged IP for a Vivado block design
make xclbin GRAPH=tree PLATFORM=<xpfm>   # full Alveo bitstream (slow)
```

### Modes

- `--mode latch` (default): monotone flood-fill, `next[v] = s[v] | OR(nbrs)`.
  Once on, stays on — this is reachability / BFS-frontier exploration.
- `--mode pulse`: the literal `next[v] = OR(nbrs)` (no self term). A
  non-monotone wave; a node switches off if no neighbour is active next cycle.

The generator picks the step count from the seed's eccentricity, and the
emitted testbench recomputes a golden BFS in plain C and self-checks csim.

## Validated results (Vitis HLS 2023.2, part xcu250-figd2104-2L-e, 300 MHz target)

| Graph  | Nodes | csim   | STEP loop II | Est. Fmax |
|--------|-------|--------|--------------|-----------|
| tree   | 11    | PASS   | **1**        | 411 MHz   |
| ring16 | 16    | PASS   | **1**        | 359 MHz   |

`II = 1` confirms the clock-cycle spec: one graph hop per cycle. `csim PASS`
confirms the baked wiring matches the golden BFS bit-for-bit.

## Scaling (why this is the interesting hard part)

Baking flat wiring is exact and fast but device-bound. The design doc's target
(N = 10^6 nodes, ~10^9 edges) is deliberately beyond one device: 10^9 OR terms
of fan-in will not fit any single FPGA — that is the whole motivation for the
crossbar / optical-fanout analysis in `optical-interconnect-design.md`.

`gen_hls.py` refuses (via `--max-terms`, default 2M) to emit a design too large
to route, rather than hang the tools. To go big:

1. **Partition** the graph into per-device tiles; bake each tile, connect tiles
   over a NoC / inter-FPGA links (cut edges become I/O). O(N) per device.
2. **Generic CSR engine** (soft, memory-driven): store edges in BRAM/HBM and
   iterate neighbours per cycle — handles arbitrary N but trades the
   "one-hop-per-clock, wiring-is-the-graph" property for memory bandwidth.
   (Not yet implemented here; the baked flow is the faithful realization.)

## Notes on the build box

- Vitis/Vivado/v++ 2023.2 live under `/tools/Xilinx`; they need a **login
  shell** (`bash -lc`) to be on PATH.
- Vitis 2023.2 ships binutils 2.37, whose `ld` can't read Ubuntu 24.04's libm
  (`.relr.dyn`). `run_hls.tcl` passes `-B/usr/bin` to csim so the system linker
  is used. Override with `CSIM_LDFLAGS=` if needed.
