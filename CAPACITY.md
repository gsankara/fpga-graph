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

> **MEASURED 2026-11-07, and this model is wrong on both counts.** A five-point
> csynth sweep of the tree-shaped kernel (N fixed at 1000, E from 20,000 to
> 128,000 — `RESULTS_ASK2_OR_TREE.md`) fits:
>
> ```
> FF  ≈ 2.03·E + 7,900     (R² 0.9994)   — scales with TERMS, not nodes
> LUT ≈ 0.690·E + 25,800   (R² 0.9958)   — 3.4x the E/5 estimate
> ```
>
> Two corrections follow. **FF scales with E, not N**, because every tree node
> is registered, so the `FF ≈ 2·N` line and the "N ≲ ~10⁶ nodes" conclusion
> below do not hold. And **FF binds before LUT**, the reverse of what this file
> predicts: the FF-limited ceiling is ~1.28M terms against a LUT-limited
> ~1.85M. The headline becomes **~1.0M terms per card** at an assumed 80%
> usable device, or ~340k inside a single SLR.
>
> Caveats that keep this from being a buildable guarantee: these are csynth
> estimates extrapolated 8x past the largest measured point, no post-route
> number exists, the 20% shell cost is an assumption rather than a measurement,
> and **N was fixed at 1000 in every run so the per-vertex cost is unmeasured**
> — which is exactly the axis the `FF ≈ 2·N` claim was about.

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

## Empirical sweep (measured on xcu280)

`scripts/capacity_sweep.sh` runs csynth for a ladder of sizes and records
LUT/FF/Fmax to `capacity_results.txt`. Measured results (degree 20):

| N (nodes) | OR terms | LUT | FF | Fmax | csynth time | status |
|-----------|----------|-----|-----|------|-------------|--------|
| 500  | 10,000 | 32,649 | 7,452  | 411 MHz | ~9 min  | OK |
| 1000 | 20,000 | 73,872 | 14,400 | 356 MHz | ~86 min | OK |
| 2000 | 40,000 | —      | —      | —       | >90 min | **timeout** |

**The binding limit is HLS synthesis TIME, not device resources.** csynth cost
grows superlinearly with the single unrolled basic block (9 min -> 86 min ->
timeout across a 2x, 2x size step). At N=1000 the design uses only ~74k LUT
(~6%) and ~14k FF (<1%) of the U280 -- resources are nowhere near full, but the
HLS front end can't schedule a bigger flat kernel in reasonable time.

> **SUPERSEDED for the tree-shaped kernel, 2026-11-07.** The ~20k ceiling
> below is a property of the FLAT OR expression, not of the device or of the
> design. Rewriting each vertex's fan-in as an explicit balanced binary tree
> takes csynth to **128,000 terms in 9,527 s at 8.6% LUT / 10.3% FF**, while
> the flat form does not finish even at 20,000 terms under a 9,000 s cap. See
> `RESULTS_ASK2_OR_TREE.md`. Note also that at the same 20,000 terms the tree
> kernel uses 37,830 LUT / 49,038 FF against the flat row's 73,872 / 14,400
> below — about half the LUTs for ~3.4x the flip-flops — though the two rows
> come from different generators (`gen_hls.py` multi-stage vs
> `gen_hls_partitioned.py --nparts 1`), so that is a direction, not a clean
> A/B.

**Practical ceiling for a single flat-baked kernel: ~1000 nodes / ~20k OR
terms.** This is ~1000x below the resource-based estimate above, and the real
reason large graphs must be **partitioned into ~1000-node tiles** (or use a
soft CSR engine) rather than baked whole. LUT scales ~74xN, so even by resources
one device tops out near ~13k nodes -- but HLS time caps it far lower.
