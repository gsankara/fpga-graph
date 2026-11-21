# The RTL kernel path — ask 2's second half

`RESULTS_ASK2_OR_TREE.md` built the tree (`rtl/or_tree.v`) and the per-vertex
wiring (`graphgen/gen_rtl_or.py` → `graph_or.v`), verified both in `xsim`, and
stopped at: *"the remaining path is an RTL-kernel wrapper exposing only the AXI
in/out around `graph_or.v`, wiring it into the normal build path, and a `v++`
link."* This is that path.

**Nothing here has run yet.** It is written, cross-checked for interface
agreement, and unsimulated: this container has no `xsim`, no Vivado and no
Vitis. Every claim below is about what the code is meant to do.

## What the shipped tree bitstreams are NOT

`prebuilt/P_ring50_u280_tree_p{0,1}of2/` — the only tree bitstreams that have
ever run on hardware — contain **no Verilog from this repo**. Their "tree" is
the C++ emission from `gen_hls_partitioned.py --or-mode tree`
(`emit_or_tree`), and Vitis HLS wrote the RTL itself. `or_tree.v` has never
been in a bitstream. That distinction is the entire reason this file exists.

## Files

| file | role |
|---|---|
| `rtl/or_tree.v` | the balanced tree. Pre-existing, xsim-verified, unchanged |
| `graphgen/gen_rtl_or.py` | emits `graph_or.v`: one `or_tree` per vertex, graph as gather wiring. Pre-existing |
| `rtl/graph_engine_rtl.v` | **new.** The Vitis RTL kernel: AXI4-Lite control, three AXI4 masters, chunked datapath around `graph_or` |
| `rtl/kernel.xml` | **new.** XRT descriptor; arg offsets must match the register map in the `.v` |
| `rtl/axi_mem_model.v` | **new.** Behavioural AXI4 slave, simulation only |
| `rtl/tb_graph_engine_rtl.v` | **new.** Drives the kernel the way XRT does, checks against `reference.py` vectors |
| `scripts/package_rtl_xo.tcl` | **new.** `package_xo` wrapper |
| `scripts/build_rtl_part.sh` | **new.** generate → xsim gate → package → link |

## The one design decision that matters

The kernel presents **the same name and the same five arguments** as the
generated HLS kernel:

```c
graph_engine_part(const gw_word_t *state_in, gw_word_t *part_out,
                  unsigned *count_out, unsigned nq, unsigned num_steps)
```

so `host/part_query.cpp`, `host/part_agent.cpp` and `sim/compare_part.py`
drive it unchanged, and `scripts/u280.cfg` pins `m_axi_gmem0/1/2` by name with
no edit. Swapping this xclbin in for an HLS one is then a pure substitution:
whatever a measurement shows is the reduction, not the harness.

## This is a correctness build, not a performance build

The datapath is strictly sequential per chunk — read a burst, compute it, write
the states, write the counts — with one outstanding burst at a time. A
streaming design would overlap all four. That is deliberate: the first
question is whether the RTL reduction is **correct in silicon** on the same
11,032-query sweep every other arm runs, and a kernel whose inner loop is ~4×
off ideal answers that just as well.

**Do not quote a latency from this build without saying it is the
non-overlapped wrapper.** If it is slower per hop than the HLS tree, that is
this wrapper, not `or_tree.v`.

## Known limits, written down before anyone trips on them

- **`NW = 1` only.** One 512-bit beat must carry a whole state vector, which
  holds for `N ≤ 512`. An `n1000` build needs `NW = 2` and a two-beat gather;
  the kernel fails loudly at elaboration rather than returning garbage upper
  bits.
- **`ap_ctrl_hs`, no `auto_restart` behaviour.** The bit is writable and
  readable because XRT expects it, and is otherwise ignored.
- **One kernel instance.** No `nparts` story here yet: `gen_rtl_or.py` has no
  `--part`, so the first target is whole-graph `ring50` (`nparts=1`,
  single card), which `compare_part.py` validates directly.
- **`-generic_top` for a Verilog parameter** is accepted by most `xelab`
  versions but documented for VHDL generics; the build script falls back to the
  TB default rather than failing over a simulator flag.

## Running it

On a Coder compile box, after `coder login`:

```bash
TARGET=u280 bash scripts/build_rtl_part.sh ring50        # csg-fpga-compile0
```

The script gates on `xsim` before packaging — generation and simulation take
seconds, the link takes ~2 h. **Do not set `SKIP_SIM=1`**: the simulation is
the only cheap check that the AXI handshakes are right, and it runs twice, once
against an always-ready slave and once against a stalling one, because a master
that only works against an always-ready slave is the classic way an AXI bug
reaches hardware.

Then the usual single-card validation:

```bash
./part_query 1 1 build/ring50_rtl/kernel.xclbin      # via compare_part.py
python3 sim/compare_part.py --graph examples/ring50.edges ...
```

## Cheaper experiment, if the goal is the open question

`RESULTS_ASK2_OR_TREE.md` lists "does a large tree still close timing?" as
unanswered — it reports csynth estimates with **no Vivado implementation**
behind them. That question needs no kernel, no xclbin, no FABRIC slice and no
host: synthesize and implement `graph_or.v` **out of context** on the U280 part
at `n1000 d128` and read WNS off the routed report. Hours of Vivado instead of
days of integration. The xclbin is the right target for an end-to-end hardware
run; it is the expensive way to answer a timing question.
