# Ask 2: the RTL binary OR tree lifts the term ceiling 6.4x

Measured 2026-11-07 on Coder box `csg-fpga-compile3`, Vitis HLS 2023.2, part
`xcu280-fsvh2892-2L-e`, 3.33 ns target. Top `graph_engine_part`.

> **Headline.** The flat OR expression does not finish csynth even at 20,000
> terms -- the size `CAPACITY.md` records as the practical ceiling. The explicit
> balanced tree finishes at **128,000 terms in 9,527 s**, at **8% LUT / 10% FF**
> of the device, with its worst logic path at **1.779 ns against a 2.431 ns
> budget**. That is **6.4x** the old ceiling, against the **>=3.7x** bar
> `RESULTS_CPU_BASELINE.md` set.

## 1. The sweep

N fixed at 1,000 vertices; the OR shape is the only variable. 9,000 s cap on
the flat runs, 10,800 s on the two largest trees.

| OR terms | flat | tree | tree LUT | tree FF | est. |
|---|---|---|---|---|---|
| 20,000 | **TIMEOUT** (rc=124) | 970 s | 37,830 | 49,038 | 2.431 ns |
| 40,000 | **TIMEOUT** (rc=124) | 2,034 s | 53,177 | 88,338 | 2.431 ns |
| 64,000 | **TIMEOUT** (rc=124) | 3,860 s | 72,764 | 139,686 | 2.431 ns |
| 96,000 | not run | **6,323 s** | 92,952 | 199,502 | 2.431 ns |
| 128,000 | not run | **9,527 s** | 112,319 | 269,486 | 2.431 ns |

The "est." column is the HLS *Estimated* figure, and on its own it is close to
meaningless -- see section 2a before drawing anything from the fact that it
does not move.

All five tree runs rc=0. BRAM_18K 62, DSP 0, URAM 0 throughout. Loop `BATCH`
II=2 against a target of 1, iteration latency 148 -- unchanged across the whole
range, so the tree is not costing throughput to buy capacity.

At 128,000 terms the design is still only **8% of the U280's LUTs and 10% of its
FFs** (25% / 31% of a single SLR). 128,000 is not the limit either; it is the
largest point queued. The limit is now csynth wall time, which is growing
roughly linearly in terms (~74 ms/term) rather than exploding.

## 1a. These runs are ONE KERNEL OWNING THE WHOLE GRAPH

The top is called `graph_engine_part`, which invites the assumption that each
run is one half of a two-card split. It is not. All five were generated with
`--nparts 1`: `partition.meta.json` records `n=1000, nparts=1, part=0,
local_terms=20000..128000, cut_terms=0`, and `graph_engine.cpp` contains
exactly **1000** `res[...]` row assignments in every run.

So **128,000 terms is one card carrying the entire 1000-vertex graph.** There
is no halving to apply, and the per-card figure and the whole-graph figure are
the same number here. A genuine `--nparts M` split would put ~1/M of the terms
on each card, so M cards reach ~M times the per-card ceiling -- but none of
these runs demonstrates that, and the inter-card path is unmeasured.

## 1b. Utilization: the design was never resource-limited

| OR terms | LUT | %dev | %SLR | FF | %dev | %SLR | BRAM | DSP | URAM |
|---|---|---|---|---|---|---|---|---|---|
| 20,000 | 37,830 | 2.90 | 8.71 | 49,038 | 1.88 | 5.64 | 62 | 0 | 0 |
| 40,000 | 53,177 | 4.08 | 12.24 | 88,338 | 3.39 | 10.16 | 62 | 0 | 0 |
| 64,000 | 72,764 | 5.58 | 16.74 | 139,686 | 5.36 | 16.07 | 62 | 0 | 0 |
| 96,000 | 92,952 | 7.13 | 21.39 | 199,502 | 7.65 | 22.96 | 62 | 0 | 0 |
| 128,000 | 112,319 | **8.62** | 25.85 | 269,486 | **10.34** | 31.01 | 62 | 0 | 0 |

**At the old 20,000-term ceiling the design used 2.9% of the LUTs.** The
ceiling was never silicon; 97% of the device went unused because of how the
source was written.

Where it goes, at 128,000 terms: LUTs are **59% Expression** (the tree nodes
and the `do_hop` muxes) and 41% Instance; FFs are **68% Instance / 32%
Register and zero Expression** -- pipeline registers, not logic. The Instance
FFs are not the AXI adapters: 302 instances of `icmp_*ns_*ns_1_2_1` at 580 FF
/ 130 LUT each account for ~175k FF, and that instance count tracks size
(45 / 93 / 156 / 222 / 302).

**BRAM 62 is entirely the three AXI adapters (30 + 30 + 2)** and has nothing to
do with graph state: `s[GW_N]` is `ARRAY_PARTITION complete` into flops and
`GW_NW` is 2. That is why BRAM never moves -- this sweep varied degree only,
never vertex count.

## 1c. Capacity: FF binds, at roughly 1.0M terms per card

Least-squares fits over the five points:

| quantity | per OR term | fixed | R² |
|---|---|---|---|
| LUT | **0.690** | 25,807 | 0.9958 |
| FF | **2.030** | 7,914 | 0.9994 |
| csynth wall | 0.0794 s | -982 s | 0.9908 |

| budget | LUT-limited | FF-limited | binding |
|---|---|---|---|
| 100% device (unreachable) | 1,852,856 | **1,280,444** | FF |
| 80% device (20% shell, **assumed**) | 1,474,801 | **1,023,575** | FF |
| 100% of one SLR | 592,673 | **424,216** | FF |
| 80% of one SLR | 466,655 | **338,593** | FF |

**Headline: ~1.0M OR terms per card, FF-bound.** Staying inside one SLR to
avoid SLL crossing entirely: **~340k terms.**

As graph shapes (terms = N x average degree, a strict hyperbola):

| avg degree | 80% device (1,023,575 terms) | one SLR 80% (338,593) |
|---|---|---|
| 2 | 511,788 vertices | 169,296 |
| 20 | 51,179 | 16,930 |
| 32 | 31,987 | 10,581 |
| 64 | 15,993 | 5,291 |
| 128 | 7,997 | 2,645 |

**The low-degree/high-N corner is the worst choice in practice even though the
resource fit favours it.** State is `ceil(N/512)` 512-bit words per query per
direction, so 512k vertices at degree 2 moves 64 KB per query per direction
against 1 KB for 8k vertices at degree 128 -- a **64x** difference in PCIe
traffic for identical logic. Per `RESULTS_GPU_BASELINE.md` the hop is already
transfer- and enqueue-dominated, so that corner loses on exactly the axis that
already hurts.

### What these numbers are not

- **Synthesis estimates extrapolated 8x** beyond the largest measured point.
  No post-route number exists for any of them.
- **The 20% shell figure is an assumption.** The platform directory holds only
  `.xsa`/`.spfm`/`.xpfm` -- no utilization data -- so no measured shell cost
  was available.
- **Per-vertex cost is unmeasured.** N was fixed at 1000 in all five runs, so
  the fits are in terms only. The degree-2 row above varies N by 500x on an
  axis nothing measured; treat it as the weakest line in the table.
- **csynth time probably binds before resources do.** At 79 ms/term, 1.0M
  terms is ~22.6 h (a convex quadratic fit gives ~33 h), and `graph_engine.cpp`
  would grow from 7.25 MB / 131k lines to ~58 MB / ~1M lines, which nothing has
  tested.
- **SLR crossing is unmeasured.** A design over one SLR must cross ~23k SLL per
  boundary, and a 1000-bit broadcast state network can exhaust that
  independently of LUT/FF.

## 2a. What the timing numbers actually say

**There is no implementation timing yet.** These are csynth runs; no Vivado
place-and-route report exists, so nothing here is a closed-timing claim.

Target 3.330 ns, clock uncertainty 0.899 ns, so the logic budget is
3.330 - 0.899 = **2.431 ns**. "Estimated 2.431 ns" is therefore the budget
exactly, in every one of the five runs -- and the reason is visible in the
schedule report: **146 of 150 states have the m_axi `gmem0` bus request or bus
read as their critical path**, and HLS prices a bus access at the whole
available period regardless of design size. So the *identical* 2.431 ns across
20,000 -> 128,000 terms is an artefact of the AXI model and says nothing about
whether the reduction got deeper.

What does say something is the worst path that is NOT the bus. There is exactly
one such state (State 76), and it moves:

| OR terms | State 76 critical path | delay |
|---|---|---|
| 20,000 | `icmp` on `s` (state unpack) | **1.165 ns** |
| 128,000 | `icmp` on `t_576_7_0` (1.501 ns) + `select` on `res` (0.278 ns) | **1.779 ns** |

At 128,000 terms the deepest logic path is a **level-7 OR-tree node of vertex
576** feeding the `do_hop` mux. That is the tree showing up where it should:
it is now the worst logic in the design, it is **0.65 ns inside the budget**,
and it grew only **1.53x** for a **6.4x** increase in terms -- the sublinear
growth the `ceil(log2(fan-in))` depth predicts. At 20,000 terms the tree is
not even the worst path; the state unpack is.

The OR reduction appears in **zero** critical paths in the flat-form sense at
either size, which is the point: the shape that used to be an unschedulable
single basic block is now ordinary pipelined logic with slack.

## 2. Why the flat form fails, and what killed it

All three flat runs died **inside `csynth_design`, after Compile/Link
succeeded** -- 1,247,265 / 2,487,265 / 3,975,265 instructions -- without
reaching scheduling, and with **no ERROR line**. They were killed by the wall
clock, not by a resource or legality check.

That is the direct confirmation of the hypothesis `CAPACITY.md` argued from
indirect evidence (9 min -> 86 min -> timeout across two 2x size steps at ~6%
LUT): the binding constraint was never device resources, it was the single
enormous basic block the generated HLS hands the scheduler. One vertex's fan-in
written as `s[0] | s[1] | ... | s[999]` is one expression the scheduler must
process whole. Writing the same reduction as `ceil(log2(N))` levels of pairwise
ORs turns an uncontrolled combinational depth into a parameter.

## 3. Equivalence and verification

The tree is not a new design, it is a rewriting of the same reduction, and that
was checked rather than asserted:

  * **flat vs tree, byte-identical** over 4,000 random queries on both `ring50`
    partitions -- `EQUIV_RESULT: PASS`. A bitwise OR is associative, so this is
    expected; it is checked because an off-by-one in the pairing loop would drop
    or duplicate a leaf and still look plausible.
  * **`rtl/or_tree.v`** against `tb_or_tree.v` / `tb_or_tree_iso.v` /
    `tb_or_tree_width.v`: 16 configs, **0 errors**, including a single-bit walk
    through every leaf for `N_IN <= 64` (the check that catches a lost leaf,
    which an all-ones vector cannot).
  * **generated `graph_or.v`** against vectors derived from
    `graphgen/reference.py` -- not from a testbench that reimplements the hop --
    6 configs **PASS**, `oob_warnings=0`: ring50_r0 400 vectors, ring50_r2 400,
    tree_r2 300, n1000d20_r0 120, n1000d20_r3 60, n1000d20_r1 60.

Two bugs this found, both of which pass a value-only test:

  * **xsim silently returns all-zeros for a single `reg` wider than 2^14 bits**,
    no error, no warning. 16,000 b PASS / 16,384 b FAIL / 32,000 b FAIL /
    1,024 b PASS. Fixed by registering per node rather than per level, which
    caps every vector at `WIDTH`. See `rtl/or_tree.v` for the sweep.
  * **`vsr[-1:0]` when `LATENCY == 1`** -- `{vsr[LATENCY-2:0], in_valid}`
    degenerates. Fixed in `or_tree.v`, then recurred independently in the
    generated `graph_or.v` (`PIPE == 1`), where it surfaced ONLY as
    `oob_warnings=2` while every vector still passed. The warning count was the
    only signal it existed, which is why the generated-RTL check reports it.

## 4. What this does and does not settle

**Settles:** capacity. The >=3.7x bar is cleared at 6.4x, and the ~73,000-term
CPU crossover from `RESULTS_CPU_BASELINE.md` is now inside the buildable range
with margin.

**Does not settle:** per-hop latency, which is an independent problem.
`RESULTS_GPU_BASELINE.md` measured an A30 paying **68 us** for the same
one-hop-per-PCIe-round-trip structure the two-U280 design pays **387.7 us**
for. Capacity was necessary, not sufficient -- with unlimited capacity the
design still loses to a GPU by 5.7x at any size. The ~320 us of unexplained
enqueue cost is the next target.

**Not yet built:** this is csynth only. The remaining path is an RTL-kernel
wrapper exposing only the AXI in/out around `graph_or.v` (HLS blackbox JSON or
`package_xo`), wiring `--or-mode tree` into the normal build path, and a `v++`
link to an .xclbin on the U280 platform. No hardware number here.

## 5. Reproducing

```bash
# generate a design with the tree-shaped reduction. gen_hls_partitioned.py
# takes an .edges file and has no --nodes/--degree of its own; make_graph.py
# makes the graph. --part is REQUIRED. The sweep used --nparts 1, i.e. one
# kernel owning the whole graph (see section 1a).
python3 graphgen/make_graph.py --nodes 1000 --degree 128 -o g1000d128.edges
python3 graphgen/gen_hls_partitioned.py g1000d128.edges --part 0 --nparts 1 \
        --or-mode tree --name n1000d128 -o /tmp/d128_tree
# csynth it (on a box with Vitis HLS and the U280 part)
vitis_hls -f hls/run_hls_part.tcl   # top graph_engine_part, 3.33 ns

# the RTL path: one or_tree per vertex, graph as gather wiring
python3 graphgen/gen_rtl_or.py --graph examples/ring50.edges --reg-every 2
xvlog rtl/or_tree.v graph_or.v tb_graph_or.v
xelab -debug typical tb_graph_or -s s && xsim s -runall
```

`--or-mode flat` reproduces the timeouts; budget 9,000 s per failed run.
