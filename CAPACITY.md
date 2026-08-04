# Capacity: how big a graph fits on one U280 (baked wiring)

## Resource model

The baked design maps, per clock (II=1):

| Graph quantity | FPGA cost |
|---|---|
| node (1 state bit) | 2 flip-flops (`s[]` + `ns[]`, partitioned complete) |
| edge (one OR term)  | ~1/5 LUT (LUT6 collapses ~5–6 terms; OR built as a tree) |
| per-node activation | OR tree of its in-degree; depth ~log(degree) |
| active-count trace  | an N-input popcount adder (~N LUTs) |

So, ignoring the AXI wrapper (~5 k LUT / ~5 k FF, fixed):

```
FF  ≈ 2·N
LUT ≈ E/5 + N        (E = total OR terms = sum of in-degrees)
```

## Device: Alveo U280 (`xcu280-fsvh2892-2L-e`)

`LUT 1,303,680 · FF 2,607,360 · BRAM 4032 · DSP 9024 · URAM 960 · 3 SLRs`

On an Alveo card the **XDMA shell** consumes ~20–30 % of the device (static
region + HBM/DDR controllers), so the *user* region is roughly
`LUT ~1.0 M · FF ~2.0 M`. (Exact post-route numbers come from the sweep below.)

## Limits (single U280, flat baked kernel)

- **Nodes — FF-bound:** `2N ≲ 2.0 M` → **N ≲ ~10⁶ nodes** (achievable only at
  tiny degree; the `array_partition complete` on a 10⁶-entry array is itself
  near the HLS practical edge).
- **Edges — LUT-bound:** `E/5 + N ≲ 1.0 M` → **E ≲ ~5 × 10⁶ OR terms** when N
  is small.
- **The real wall is HLS + routing, well below the raw counts.** The unrolled
  step is a *single basic block* with ~E terms; Vitis's basic-block threshold
  is ~200 k instructions, and an `array_partition complete` all-to-many OR
  network congests routing. Timing also degrades as degree grows (deeper OR
  trees). Practical comfortable ceiling per single-kernel build:

  > **E ≈ 1–2 × 10⁶ OR terms, N ≈ 10⁵–10⁶, jointly E = N·degree bounded.**

It is a hyperbola, not two free knobs — the same shape as the ASIC tradeoff in
`optical-interconnect-design.md` (`N·(1+degree) ≲ budget`), just with a
one-FPGA budget instead of 50 T transistors.

## Against the design target

The design substrate is **10⁶ nodes / 10⁹ edges**. One U280 holds ~10⁶ edges —
**~1000× short on edges.** That gap *is* the design doc's whole thesis: no
single device carries 10⁹ arbitrary edges; you need ~10³ U280s partitioned
(cut edges become inter-FPGA AXI/serial links), or the crossbar / free-space
optical substrate analysed in the doc.

## The largest sample graph here

`make_graph.py` builds circulant regular graphs of any (N, degree):

```
python graphgen/make_graph.py --nodes 100000 --degree 20 -o big.edges
python graphgen/gen_hls.py big.edges --seed 0 --name big_n100k_d20 --steps 8
```

`big_n100k_d20`: **N = 100,000, degree 20, 1,000,000 edges, 2,000,000 OR terms.**
Estimated ~200 k FF (**7.7 %**) / ~500 k LUT (**38 %**) of the device — fits by
resources; the open question it answers empirically is HLS/routing/timing.

> `--steps` only sets the testbench/self-check depth; the hardware `num_steps`
> is a runtime argument, so a baked graph runs any number of hops on the card.

## Empirical sweep

`scripts/capacity_sweep.sh` runs csynth for a ladder of sizes on `xcu280`,
recording LUT/FF and estimated Fmax, to pin the practical ceiling. Results are
appended to `capacity_results.txt` (committed once the run completes).
