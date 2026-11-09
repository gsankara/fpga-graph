# Where the ~300 us per hop actually goes

Measured 2026-11-07 from the `ring50` tree-bitstream hardware run on
`fpga-part-internode` (`RESULTS_ASK2_HARDWARE.md`). The split was already being
instrumented by `host/part_agent.cpp` (`[card] H2D ... exec ... D2H`, line 426)
and by `host/part_query.cpp` (line 387) -- it had simply never been read.

> **Headline. The kernel is ~2% of the hop and the payload needs 0.80 us of
> PCIe wire time, yet the hop costs ~302 us.** Of that, ~98% is per-call
> overhead in the XRT buffer-sync and run-dispatch path. It is not bandwidth,
> not the design, and not the OR shape.

## 1. Measured, per hop (69 hops, reported totals / 69)

| stage | per hop | share |
|---|---|---|
| H2D `bo_in.sync(XCL_BO_SYNC_BO_TO_DEVICE)` | **98.7 us** | 34.8% |
| `kernel(...).wait()` window | **112.6 us** | 39.7% |
| D2H `bo_out.sync(XCL_BO_SYNC_BO_FROM_DEVICE)` | **72.0 us** | 25.4% |
| **sum of stages** | **283.4 us** | |
| residual (host `memcpy` + loop) | 18.6 us | |
| **measured `local_fpga` mean** | **302.0 us** | |

The stages account for **93.8%** of the measured figure, so the accounting
closes rather than leaving the bulk unexplained.

## 2. The kernel is nanoseconds; only batching makes it microseconds

From `ring50`'s own HLS report
(`build/ring50_p0of2_block_tree/_x/reports/kernel/hls_reports/graph_engine_part_csynth.rpt`):

```
BATCH loop:  II achieved = 1 (target 1),  iteration latency 144 cycles, pipelined
ap_clk:      3.33 ns target, 2.433 ns estimated
```

| granularity | kernel time |
|---|---|
| **per query** | **3.33 ns** (one cycle, II=1) |
| pipeline depth | **480 ns** (144 cycles) |
| per hop, batch of `nq` | (144 + `nq`) cycles |

At a 1,576-query batch that is **5.73 us**. **Upper bound: even if one hop
processed all 11,032 queries of the sweep at once, the kernel would be 37.3 us**
-- still a minority of the 302 us. So the conclusion does not depend on knowing
the exact batch width.

This matches the RTL: `ring50`'s max fan-in is 3, so its `or_tree` is 2 levels
-- 6.7 ns registered at 300 MHz, or purely combinational at `REG_EVERY=0`.

## 3. The decisive number: transfer cost is per-call, not per-byte

Payload per direction is `nq x qbytes` = 1,576 x 8 B = **12.3 KiB**. On the
U280's gen3 x16 XDMA shell (~15.75 GB/s) that is **0.80 us of wire time**.

| | measured | wire time | ratio |
|---|---|---|---|
| H2D | 98.7 us | 0.80 us | **123x** |
| D2H | 72.0 us | 0.80 us | **90x** |

**The H2D path contains no kernel at all**, so its 98.7 us is unambiguously
per-call cost. Nothing here is bandwidth-bound; a `sync()` costs ~70-100 us
regardless of how little it carries.

## 4. Against the GPU, same structure and same payload

From `RESULTS_GPU_BASELINE.md`, A30 `roundtrip` on `ring50`:

| | FPGA / XRT | GPU / CUDA | ratio |
|---|---|---|---|
| H2D | 98.7 us | 2.8 us | **35x** |
| D2H | 72.0 us | 9.1 us | **8x** |
| kernel | ~5.7 us | 8.2 us | **0.7x** (FPGA faster) |
| **per hop** | **302.0 us** | **29.5 us** | **10x** |

**The kernels are comparable -- the FPGA's is faster. The transfer calls are
8-35x worse.** That is the whole gap, and it confirms from the other side what
`RESULTS_GPU_BASELINE.md` inferred: the overhead is not structural to "one hop
per PCIe round trip", it is specific to this host path.

## 5. Where to look, in order

1. **The `.wait()` at `part_agent.cpp:200` rebuilds an `xrt::run` and rebinds
   five arguments every hop.** The BOs, `nq` and the latch flag are invariant
   within a query group. A persistent `xrt::run` created before the loop removes
   per-hop dispatch setup. This attacks the ~107 us of `exec` that is not
   kernel.
2. **The two `sync()` calls are the larger target (170.7 us combined, 57% of
   the hop).** Worth testing: `XCL_BO_SYNC` on a host-pointer BO vs
   `xrt::bo::map` with explicit cache management, and whether a smaller BO
   (currently allocated at `maxq`, synced at `nq`) changes the cost -- i.e.
   whether the cost tracks the allocation or the transfer length.
3. **The cards are serialized.** `part_agent` does H2D -> exec -> wait -> D2H
   for one card completely before the next, though the cards are independent
   until the combine barrier. Overlapping them is ~2x on the device portion.

## 6. What this does not establish

- **The `exec` row is the one estimate here.** `exec` brackets dispatch, kernel
  and completion together, so the ~5.7 us kernel is derived from the HLS II and
  batch width, not read off hardware. Splitting it properly needs XRT profiling
  counters or polling `xrt::run::state` instead of blocking on `.wait()`.
  Section 3 does not depend on it: the H2D path has no kernel in it.
- **One run, `ring50` only.** `local_fpga` ranged 219.6-405.0 us within this
  run, so per-stage figures carry that spread. Repeats are needed before any
  improvement under ~50 us can be called real.
- **The batch width is assumed to be ~1,576** (the FPGA sweep's width used in
  the scaling runs), not read from this run's output. Section 2's upper bound
  is there precisely so the conclusion survives if it is wrong.
