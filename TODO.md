# fpga-graph — TODO

Captured 2026-10-25.

## 1. Latency breakdown
Decompose query latency into PCIe transfer, FPGA query execution, and other
contributors, instead of the single end-to-end number measured so far.
- Have: total ~82–95 µs fixed cost, and `bench_latency.cpp` already separates
  `kernel` (enqueue+wait) from `total` (H2D + kernel + D2H).
- Need: split the fixed cost further — H2D vs D2H vs enqueue overhead vs
  doorbell/interrupt latency vs actual kernel cycles. Synthesis gives the kernel
  side exactly (design B = 148 cycles / 0.493 µs), so the rest is attributable.
- **Partial result 2026-10-25** (design C `tree` on GATECH, see
  `RESULTS_C_tree_gatech.md`): H2D and D2H are each ~0.03–0.09 ms and barely
  grow from 10 to 10,000 queries, so PCIe transfer is *not* the fixed cost.
  The ~62 µs floor sits in `exec` — enqueue + doorbell + wait — and the
  marginal cost is ~10.3 ns/query. Still needed: separating AXI stalls from
  pipeline behaviour (cosim trace or profile run), and the interrupt-vs-poll
  component of that 62 µs.

## 2. Distribute the graph across FPGAs
Partition one graph across 2 FPGAs and measure the latency effect.

**The design exists and is verified in software — see `PARTITION.md`.**
`graphgen/gen_hls_partitioned.py` emits one kernel per partition;
`sim/verify_partition.py` proves the decomposition exact over 185,360
comparisons against `reference.py`. The demo graph is `examples/ring50.edges`
(50 vertices, 50 edges -> 25 vertices and 50 adjacency terms per card,
eccentricity 25). Remaining work is the two bitstreams per target and the runs.

- **RESOLVED 2026-10-25 — the intra-node arm is impossible on FABRIC.** A sweep
  of all 33 sites found 23 U280 hosts, every one with capacity **exactly 1**.
  No host anywhere on the testbed has two U280s, so neither one VM with two
  FPGAs nor two co-located VMs can be built. CIEN has one `FPGA-Xilinx-SN1022`,
  a different card. `add_component` imposes no per-node cap, so a two-FPGA
  request builds fine client-side and would fail at submit when the
  orchestrator cannot bind the second card.
  **Decision taken 2026-10-30: source the intra-node arm off-testbed.** Two
  places, both off FABRIC:
  - **OCT** — dual-U280 nodes. Exchange through host memory, the lower bound.
  - **NRP** — U55C pair, built on `csg-fpga-compile3`. The U55C is HBM-only,
    so bundles must be pinned to HBM banks (`scripts/u55c.cfg`); a
    default-placement kernel links on a U280 and fails on a U55C.

- **Inter-node pairs — the 2026-10-25 list below was wrong and is replaced.**
  It was chosen on per-host free cores, before the shell survey. `ucsd-w3`,
  `psc-w2` and `mass-w2` all carry OpenNIC/ESnet network shells (PCI
  `903f`/`913f`) that XRT can never bind, so none of them can run an xclbin at
  all. Choosing an FPGA host by free capacity actively misleads: the roomiest
  hosts are disproportionately the unusable ones.

  Only **7 of 24** FPGA sites were XRT-usable on the 2026-10-26 deep scan, and
  `star-w3` has just 4 free cores, too few for the tooling VM — so the real
  inter-node pool is **6 hosts**:

  | host | shell | cores | ram | disk |
  |---|---|---|---|---|
  | `dall-w2` | `xrt-xdma-base` | 36 | 50 | 233 |
  | `losa-w2` | `xrt-xdma-base` | 34 | 262 | 1233 |
  | `gpn-w3`  | `xrt-xdma-base` | 32 | 334 | 933 |
  | `salt-w2` | `xrt-xdma-base` | 32 | 190 | 1933 |
  | `wash-w2` | `xrt-xdma-base` | 30 | 150 | 1023 |
  | `kans-w2` | `xrt-xdma-base` | 26 | 174 | 923 |

  Suggested pairs: long-haul **`losa-w2` + `wash-w2`** (LA to DC), short-RTT
  **`dall-w2` + `kans-w2`**. Capacity is a 2026-10-26 snapshot — re-scan with
  the `FPGA_Daily_Scan` weave before reserving, and always pin with
  `add_node(..., host=...)`. Verify the PCI id is `500c`/`500d` before
  committing: the shell, not the free-core count, decides whether a host can
  run a bitstream.

## 3. Weave: daily FPGA status scan
A weave that scans FPGA availability/health across sites on a schedule and
reports shell identity (`903f`/`913f`/`d00c`/`500c`) per card.
- Reuse the shell-identification table and `xbutil examine` parsing from the
  `fpga` skill and `FPGA_Graph_U280_Test`.

## 4. Weave: simple HLS workload, end to end
One weave spanning three inputs:
1. the HLS workload source,
2. an NRP Coder instance to compile it (`coder ssh csg-fpga-compile0`),
3. a FABRIC FPGA node to run it.
- Must carry the build-box lessons: IP-cache crash workaround, link watchdog,
  and the stale-process sweep (see `fpga` skill §6).

## Deferred to a later session

**Consolidated weave** — one weave that runs the NRP, OCT and FABRIC partition
arms and emits a single comparison table. The three arm weaves are published
and already write a common `last_run.json` shape, so this should merge their
output rather than re-implement any measurement. Constraints: keep
`compare_part.py`'s default sweep on every arm (that is what makes the numbers
comparable), run whichever arms are available and mark the rest skipped rather
than failing, and always print the ICMP RTT beside each per-hop figure. See
`../HANDOFF-2026-10-31.md`.
