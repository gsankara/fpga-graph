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

Payload per direction is `nq x qbytes` = **1,576 x 8 B = 12,608 B = 12.3 KiB**.
`nq` is 1,576 because `compare_part.py` re-runs the whole 1,576-query set at
each of 7 step-count groups (`[0,1,2,3,12,25,26]` for `ring50`, eccentricity
25), whose hop counts sum to the 69 hop samples; 11,032 is the query-RESULT
count, not queries per hop. On the U280's gen3 x16 XDMA shell (~15.75 GB/s)
12.3 KiB is **0.80 us of wire time**.

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

---

## 8. Is the ~300 us caused by partitioning? No.

A natural suspicion, since the design splits the graph across two cards. Three
independent reasons it is not, and one cross-check.

**1. By construction, `local_fpga` excludes the partition.** The 302 us is one
card's own H2D + dispatch + D2H for its own state vector. The partition's cost
is a *separate* metric in the same table: `exchange_rtt`, 32,728 us p50, plus
the host combine. Partitioning cannot be inside the 302 us.

**2. The same overhead appears with no partitioning at all.** From the
single-card design-C runs -- one card, no partition, no exchange:

| design | fixed per-call `exec` cost | source |
|---|---|---|
| `C_tree` (N=11) | **~62 us**, independent of batch size | `RESULTS_C_tree_gatech.md` |
| `C_ring16` (N=16) | **~84 us**, independent of batch size | `RESULTS_C_ring16_gatech.md` |

Those files already named it "enqueue + doorbell + wait". Partitioning absent,
overhead present, same order of magnitude.

**3. The H2D leg contains no partitioning and no kernel.** One `bo_in.sync()`
moving 12.3 KiB -- 0.80 us of wire time -- costing 98.7 us. Splitting a graph
across cards plays no part in that number.

**Cross-check from the other direction:** the GPU is not partitioned at all
(one device, whole graph) and pays 29.5 us for the identical round-trip
structure. So neither partitioning nor the round-trip shape explains 300 us.

### What partitioning actually costs

| | cost | where it shows |
|---|---|---|
| **the exchange** | **32,728 us** p50 | `exchange_rtt` -- 99.2% of the wide-area hop |
| host combine (OR the partials) | reported separately | `combine_us` |
| **cards serialized, not overlapped** | up to ~2x on the device portion | folded into the hop |

The third is genuinely partition-induced: `part_agent` completes
H2D -> exec -> wait -> D2H for one card before starting the next, though the
cards are independent until the combine barrier. That is plausibly part of why
design P's `exec` is 112.6 us against the single-card designs' 62-84 us -- but
it is a ~2x effect on an already-broken path, not the cause of it.

**Ranking of what to fix:** the exchange dominates by ~100x and is largely
physics (32.3 ms of ICMP on a cross-country path); the ~300 us XRT path is next
and is not partition-related; card serialization is a ~2x refinement after
that.

---

## 9. Single-card sweep: partitioning ruled out, and the host combine found

Measured 2026-11-10 on FABRIC `part0`, one U280, running **partition 0's tree
bitstream alone** -- no peer, no exchange, no combine across cards.
`--no-selfcheck`, because partition 0 cannot reproduce the full graph and
correctness is irrelevant to a timing measurement. Sweeping `NQ` (queries per
hop, all with the same step count so each hop processes exactly `NQ`) is what
separates fixed per-call cost from marginal per-query cost. `part_query` needed
no change: `nparts` is just `xclbins.size()`, so one xclbin gives a single-card
run.

| NQ | payload | hop p50 | H2D/hop | exec/hop | D2H/hop | combine/hop |
|---|---|---|---|---|---|---|
| 1 | 8 B | 84.6 | 33.5 | 44.8 | 22.4 | 0.2 |
| 64 | 512 B | 78.9 | 28.9 | 37.0 | 23.6 | 2.2 |
| 1,024 | 8 KiB | 135.6 | 34.4 | 50.9 | 28.5 | 28.0 |
| 16,384 | 128 KiB | 905.0 | 124.4 | 136.4 | 114.2 | **513.2** |
| 65,536 | 512 KiB | 3,297.6 | 408.6 | 367.6 | 389.7 | **1,980.3** |

All us. Stage columns are reported totals / 10 hops.

Fitted over NQ = 1,024 -> 65,536:

| stage | fixed | marginal |
|---|---|---|
| H2D | 28.5 us | 5.80 ns/query |
| exec | 45.9 us | 4.91 ns/query |
| D2H | 22.8 us | 5.60 ns/query |
| **host combine** | ~0 | **30.26 ns/query** |

### 9.1 RETRACTED: the nq used here was wrong

**This section originally claimed the partitioned 302 us was "entirely
explained by single-card behaviour at nq ~ 11,032", predicting H2D 92.5 / exec
100.1 / D2H 84.6 us against measured 98.7 / 112.6 / 72.0. That agreement was
numerology: 11,032 is the query-RESULT count, not the queries per hop.**

The real batch size, derived from `sim/compare_part.py`: `ring50` has
eccentricity 25, so the sweep uses step-count groups
`[0, 1, 2, 3, 12, 25, 26]` -- 7 groups whose hop counts sum to the **69** hop
samples. The full query set is re-run at each, so

```
nq per hop = 11,032 / 7 = 1,576      payload = 1,576 x 8 B = 12,608 B = 12.3 KiB
```

`nq` is 1,576 and constant across all 69 samples. At that nq the single-card
fit predicts:

| | single-card prediction | partitioned wide-area, measured |
|---|---|---|
| H2D | 37.6 us | 98.7 us |
| exec | 53.6 us | 112.6 us |
| D2H | 31.6 us | 72.0 us |
| **sum** | **122.9 us** | **283.4 us** |

**The partitioned run costs 2.31x what one card costs at the same batch size.**
So ~160 us is paid by that run and not by the single-card sweep, and section
8's conclusion is weaker than stated there: the per-call floor does exist
without partitioning (sections 3, 6, 8 stand on that), but something in the
partitioned wide-area run adds 2.3x on top.

**Leading hypothesis, and it is not the data partition:** the wide-area run
waits ~32.7 ms for the exchange between hops, so the card is invoked once per
32 ms rather than back-to-back. Cold caches, CPU C-state and frequency
scaling, and XRT re-arming would all plausibly cost ~160 us on a cold
invocation. The single-card sweep hammered the card continuously -- the best
case, not a representative one.

**The test that separates them:** add a configurable inter-hop delay to the
single-card run. If ~32 ms of idle reproduces ~283 us on one card with no
partition and no exchange, it is a cold-invocation effect. If it does not, the
cost belongs to `part_agent` or to the partitioned structure after all. Until
that is run, treat the 2.31x as unexplained rather than attributed.

### 9.2 Correction: it is not mostly per-call overhead

Section 3 and section 6 framed the ~300 us as dominated by **per-call** cost.
That holds only at tiny batches. At nq = 11,032 the split is:

- **fixed: 97.2 us (34%)** -- the genuine per-call floor
- **marginal: ~180 us (64%)** -- scales with query count

The 8-byte run does confirm the fixed floor is real (84.6 us to move 8 bytes,
consistent with `C_tree`'s 62 us and `C_ring16`'s 84 us). But at any realistic
batch most of the cost is marginal, and the earlier framing was wrong about
that.

### 9.3 The biggest single target is host code, not XRT

**The host combine -- `for (b ...) state[b] |= p[b]`, a byte-at-a-time
`uint8_t` loop -- costs 30.26 ns/query: 65% of all marginal cost and 9x the
kernel.** At NQ = 65,536 it is 1,980 us of a 3,298 us hop, i.e. **60% of the
hop is a host memory loop** running at roughly 0.5 GB/s.

Marginal cost per query, ranked:

| | ns/query | share |
|---|---|---|
| host combine | 30.26 | **65%** |
| H2D | 5.80 | 12% |
| D2H | 5.60 | 12% |
| **kernel** | **3.33** | **7%** |
| exec, non-kernel | 1.58 | 3% |

Two actionable items, in order:

1. **Rewrite the combine over `uint64_t`, or `memcpy` when `nparts == 1`.** A
   few lines, and it is the largest term by 5x. `part_query.cpp:341-342` and
   the equivalent in `part_agent.cpp`.
2. **H2D/D2H marginal is ~1.38 GB/s effective, about 9% of PCIe gen3 x16 wire
   speed.** At large batches the syncs are not per-call-bound either; they are
   genuinely slow per byte. Worth testing whether a host-pointer BO or explicit
   cache management changes it.

### 9.4 Limits

- **One run per NQ, no repeats.**
- **The NQ = 1 and 64 rows are noisy**: hop p50 (84.6) is *below* the sum of
  stage means (100.7), because the stage figures are means over 10 hops that
  include a 244.6 us outlier. The large-NQ rows carry the conclusions and are
  stable (p50 within 1% of mean).
- **`ring50`, nw = 1** (8 B/query) only. At n = 1000 the payload is 16x larger
  per query and the marginal terms would change; the fixed terms should not.
- Script: `scratchpad/sweep_nq.sh`, run on `part0` in `~/fpga-part`. Note
  `part_query` needs `-luuid` alongside `-lxrt_coreutil`.

---

## 10. The 2.31x is a COLD-INVOCATION cost, measured

Section 9.1 left 2.31x unexplained and named the test. Here it is, run
2026-11-10 on `part0`: one card, partition 0's bitstream alone, no peer, no
exchange, nq = 1,576 (the real sweep batch size). The only variable is idle
time inserted between hops via the new `part_query --gap-ms N`, placed
**before** the hop timer so the idle itself is not measured.

| gap between hops | hop p50 | H2D | exec | D2H | combine | 3-stage sum |
|---|---|---|---|---|---|---|
| 0 ms | **181.9** | 37.9 | 62.8 | 38.2 | 66.0 | 138.9 |
| 1 ms | 188.7 | 40.5 | 61.9 | 37.7 | 57.6 | 140.1 |
| 5 ms | 194.4 | 39.8 | 42.0 | 46.0 | 69.1 | 127.8 |
| **32 ms** | **378.4** | **85.4** | **89.7** | **82.3** | 93.4 | **257.4** |
| 100 ms | 379.4 | 88.3 | 105.2 | 80.9 | 110.4 | 274.4 |

All us; stage columns are reported totals / 10 hops.

**A 32 ms gap on ONE card, with no partitioning and no exchange anywhere,
reproduces the partitioned wide-area run:** 257.4 us of stages against that
run's 283.4 us. H2D doubles (37.9 -> 85.4), D2H doubles (38.2 -> 82.3), `exec`
rises 1.43x.

The effect **saturates between 5 ms and 32 ms** -- 100 ms is
indistinguishable from 32 ms. A threshold rather than gradual warming, which
fits CPU C-state exit, frequency scaling or cache eviction on the host, not
anything on the card.

### 10.1 What this settles

**The ~160 us is cold-invocation cost, not the data partition.** Section 8's
conclusion is restored, now by direct measurement with a mechanism rather than
by indirect argument. Partitioning's role is only indirect: the wide-area
exchange takes 32.7 ms, which guarantees every kernel invocation is cold.

### 10.2 What it costs the rest of this repo

**Every wide-area FPGA latency figure here is ~2x inflated by this.**
`local_fpga` 302 us is a cold number; warm at the same batch size is
**181.9 us**.

It also makes the cross-arm comparisons unfair in a known direction:
`cpu_hop` and `gpu_hop` run back-to-back with nothing between iterations --
**warm** -- while the FPGA was measured **cold**. So:

| ring50, per hop | as published | warm-vs-warm |
|---|---|---|
| GPU `roundtrip` | 29.5 us | 29.5 us |
| FPGA, 1 card, nq=1,576 | 302.0 us (cold) | **181.9 us** |
| ratio | 10.2x | **6.2x** |

The FPGA still loses. But a chunk of what sections 3-6 attributed to "the XRT
enqueue path" is really "the host idled for 32 ms between invocations", and
that distinction matters because the two have completely different fixes.

### 10.3 Limits

- **One run per gap value.** The 5 ms row is visibly noisy (`exec` 42.0 us
  against 62.8 at 0 ms and 89.7 at 32 ms), so the threshold is somewhere in
  5-32 ms and is not located more precisely than that.
- **The mechanism is inferred, not instrumented.** C-state, frequency and cache
  behaviour were not measured; the evidence is the saturating threshold and
  that H2D/D2H -- host-side calls -- move most. Pinning it down means
  `cpupower`/`turbostat` during a run, or repeating with C-states disabled.
- **`ring50`, nw=1, one card.** Not re-measured on the two-card arms.
- Scripts: `scratchpad/sweep_nq.sh`, `scratchpad/gap_test.sh`, run in
  `~/fpga-part` on `part0`.

---

## 11. Fixing the combine: warm hop 181.9 -> 122.3 us (-33%)

Section 9.3 found the host combine -- `state[b] |= p[b]`, byte at a time -- was
the largest single term in the hop. Replaced with a word-wise `or_into()`
(memcpy into `uint64_t`, scalar tail) in both `host/part_query.cpp` and
`host/part_agent.cpp`, plus one structural change: start the combine from card
0's partial instead of `memset` to zero and then OR every card. That is the
same OR of every partial and saves a full pass over the buffer.

Same card, same bitstream, same nq = 1,576, only the combine changed:

| gap | combine before | combine after | speedup | hop p50 before | hop p50 after |
|---|---|---|---|---|---|
| 0 ms | 66.04 | **7.52** | **8.8x** | 181.9 | **122.3** |
| 1 ms | 57.62 | 7.62 | 7.6x | 188.7 | 140.3 |
| 5 ms | 69.10 | 10.65 | 6.5x | 194.4 | 218.2 |
| 32 ms | 93.38 | 20.72 | 4.5x | 378.4 | 276.2 |
| 100 ms | 110.43 | 26.42 | 4.2x | 379.4 | 243.1 |

All us. **At gap 0 the hop drops 59.6 us, which is exactly the 58.5 us the
combine saved** -- the saving is real and lands where predicted, not absorbed
elsewhere.

Per query the combine went **30.26 -> 4.77 ns**, a 6.3x improvement. It is now
the same order as the kernel's 3.33 ns rather than 9x it.

Revised warm per-hop picture at nq = 1,576, one card:

| | before | after |
|---|---|---|
| hop p50 | 181.9 us | **122.3 us** |
| vs GPU `roundtrip` 29.5 us | 6.2x | **4.1x** |
| vs the originally published 302 us (cold) | -- | **2.5x better** |

### 11.1 Correctness

`or_into` was unit-tested against the byte loop it replaces over **every length
0-200 at every alignment offset 0-7 (1,608 combinations) plus the real
1,576 x 8 B shape**: byte-exact, PASS. The test is
`scratchpad/t_or.cpp`. `memcpy` into a `uint64_t` is used rather than a cast
because it is the defined way to do an unaligned load, and the scalar tail
means correctness does not depend on `qbytes` being a multiple of 8.

`part_agent.cpp` was recompiled against XRT to confirm it still builds.

**Not yet re-validated: the two-card end-to-end run.** `or_into` is verified as
a pure function and the restructure is logically equivalent, but
`compare_part.py` has not been re-run across both cards since the change,
because the FABRIC token expired. **That check is owed before any new
two-card number is published from this code.** A single card cannot stand in
for it: partition 0 alone cannot reproduce the full graph, which is why the
sweeps here use `--no-selfcheck`.

### 11.2 What is left

With the combine fixed, the warm 122.3 us hop at nq = 1,576 is roughly:

| | us | note |
|---|---|---|
| H2D | 33.8 | ~28 us fixed + 5.8 ns/query |
| exec | 55.5 | ~46 us fixed; kernel is 5.2 us of it |
| D2H | 36.1 | ~23 us fixed + 5.6 ns/query |
| combine | 7.5 | was 66.0 |

**The fixed per-call floor (~97 us) now dominates the warm hop.** The next
targets are therefore the ones section 9.3 ranked second: a persistent
`xrt::run` instead of rebuilding it every hop, and whatever makes a `sync()`
cost ~25 us before it moves a byte.
