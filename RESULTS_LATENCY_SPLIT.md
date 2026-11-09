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

---

## 7. Per-query comparison: the compute crossover is ~1,000 terms, not ~73,000

The per-query view is the one that separates "is the architecture right?" from
"is the host path right?", and the two have different answers. It answers three
distinct questions, which give three different orderings, so any number taken
from here must say which one it is.

### 7.1 Per query at `ring50` (100 OR terms), 1,576-query batch

| | ns/query |
|---|---|
| CPU 1 core, `word` mode | **0.76** |
| **FPGA kernel, marginal (II=1 @ 300 MHz)** | **3.33** |
| GPU kernel alone | 4.57 |
| GPU `resident`, per hop | 8.88 |
| GPU `roundtrip`, per hop | 28.93 |
| **FPGA measured per hop** | **191.62** |

### 7.2 The compute-only crossover

The FPGA's marginal cost is **flat in graph size** -- one query per cycle
whatever the fan-in, because the graph is wiring. The CPU's is **linear in OR
terms**, at 5.3 ns/term per 1,576-query batch = **3.363 ps per query per term**.

| OR terms | CPU 1 core | FPGA kernel | winner |
|---|---|---|---|
| 100 | 0.34 ns | 3.33 ns | CPU, 9.9x |
| **991** | **3.33 ns** | **3.33 ns** | **crossover** |
| 20,000 | 67.3 ns | 3.33 ns | FPGA, 20x |
| 64,000 | 215.2 ns | 6.67 ns | FPGA, 32x |
| 128,000 | 430.5 ns | 6.67 ns | FPGA, 65x |

**The compute crosses over at ~1,000 OR terms -- 73x lower than the ~73,000 for
the full hop (`RESULTS_CPU_BASELINE.md`). The difference between those two
crossovers IS the host path.** The architecture was never the problem.

II is not constant across designs: `ring50` achieves II=1, but all five n1000
designs achieved **II=2**, so 6.67 ns/query is used for the large graphs rather
than extrapolating ring50's best case.

### 7.3 At a graph that matters -- n1000 d64, 64,000 terms

| | ns/query |
|---|---|
| **FPGA kernel** | **6.67** |
| GPU kernel | 10.09 |
| GPU `resident` per hop | 11.23 |
| GPU `roundtrip` per hop | 45.2 |
| FPGA measured per hop | ~194.7 |
| CPU 1 core | 205.3 |

**The FPGA has the best compute of the three and the worst delivered
performance.** It beats the GPU's kernel by 1.5x and loses the hop by 4.3x.

### 7.4 Which number answers which question

| question | metric | answer |
|---|---|---|
| Is the architecture right? | marginal kernel | **Yes above ~1,000 terms**, and it beats the GPU kernel |
| Is the implementation usable? | amortized per hop | Only at huge batches -- see below |
| What is single-query latency? | one query, one hop | **296.8 us.** Hopeless |

Dispatch is paid once per BATCH, so the amortized figure is entirely
batch-dependent:

| queries per hop | FPGA ns/query |
|---|---|
| 1 | 296,783 |
| 64 | 4,640 |
| 1,576 | 191.6 |
| 11,032 | 30.2 |
| 100,000 | **6.3** |

It takes a ~100,000-query batch for the amortized figure to approach the
marginal one. That is the overhead being diluted, not removed.

### 7.5 What could move these numbers

1. **The CPU column is one core and no honest multi-core number exists**
   (`--threads` spawns threads per hop; see `RESULTS_CPU_BASELINE.md` section
   5). With `part0`'s 8 vCPU the compute crossover could move from ~1,000 to
   ~8,000 terms. Still far below 73,000, so the structural conclusion survives,
   but the margin does not.
2. **The ~296 us overhead is measured at `ring50`'s 12.3 KiB payload.** At
   n=1000 the payload is 197 KiB, 16x larger -- 12.5 us of wire time against
   170 us measured, so still per-call dominated, but the n1000 d64 per-hop row
   is an assumption, not a measurement.
3. **Per-query amortization is a throughput metric, not a latency one.** It is
   legitimate for sustained rates, but it hides that the FPGA needs a
   100,000-query batch to look good while the CPU needs none.
