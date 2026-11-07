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

**Path walked by hand 2026-11-03** for `gsankara/sequence`, so the weave has a
worked reference: built on `csg-fpga-compile0`, staged to FABRIC slice
`fpga-part-internode` node `part0` (losa-w2), run there. Results and the
prebuilt bitstream live in that repo under `fpga/RESULTS_U280_HW.md` and
`fpga/prebuilt/repeater_u280_4lane/`. Four things the weave must get right,
each of which cost time here:

- **Build the host on the machine that runs it.** compile0 is Ubuntu 24.04 /
  glibc 2.39 / XRT 2.19.194; FABRIC U280 nodes are 22.04 / glibc 2.35 / XRT
  2.16.204. The compile0 binary does not load.
- **`v++` exits 0 on a timing failure.** That build recorded `LINK_RC=0` and
  `BUILD_RESULT status=ok` while missing its 300 MHz target by 834 ps. The
  weave must read `_xl/reports/link/imp/*_timing_summary_routed.rpt`, and
  should also check `xbutil examine --report platform` for the clock the card
  actually loaded — `v++` silently derates via `AUTO-FREQ-SCALING-04`, so the
  target in the `.cfg` is a request, not a result.
- **`coder ssh` cannot stream a binary on stdout.** `tar cf - ... > local.tar`
  died at 118 bytes. Tar to a remote file, then pull it (base64 round-trip
  worked, sha256-verified end to end).
- **`scp` is denied in this container.** Use `rsync -a -e ssh`; the FABRIC hop
  needs `-i <slice_key> -F fabric_config/ssh_config`, and IPv6 management
  addresses need brackets in the rsync target.

## Deferred to a later session

**`heterojit` retarget** — resuming 2026-11-04. Its kernel is already
`extern "C"` with `m_axi ... offset=slave` on three pointers, so it is a
straight retarget to the U280 rather than an interface rewrite. Needs
`csg-fpga-compile3` started and the U280 dev platform installed there
(`/home/fabric/work/u280-debs/...deb`, sha256
`050b2a17b06c5d905a890affd929a1e5eb4dfaf123c28b4c16444fcd94326952`). Builds run
one at a time: nothing else should be linking while it does.

**Consolidated weave** — one weave that runs the NRP, OCT and FABRIC partition
arms and emits a single comparison table. The three arm weaves are published
and already write a common `last_run.json` shape, so this should merge their
output rather than re-implement any measurement. Constraints: keep
`compare_part.py`'s default sweep on every arm (that is what makes the numbers
comparable), run whichever arms are available and mark the rest skipped rather
than failing, and always print the ICMP RTT beside each per-hop figure. See
`../HANDOFF-2026-10-31.md`.

## Ask 2 follow-up: uniform 1000-input trees (user ask, 2026-11-07)

Instead of sizing each vertex's `or_tree` to that vertex's own fan-in, give
EVERY vertex `N_IN = N` (all 1000) and drive the non-neighbour leaves with
constant `1'b0`. ORing in a zero changes nothing, so the value is identical;
what changes is that every tree has the same shape.

Why this is better than what `gen_rtl_or.py` does today:

  * Depth becomes `ceil(log2(N))` for every vertex, a CONSTANT, independent of
    the graph. Today depth varies with fan-in, and with `REG_EVERY > 0` that
    means different vertices' bits land on different cycles -- `state_out`
    would silently mix two hops. The current workaround is to pad each gather
    to the graph's MAX fan-in; padding to N instead removes the per-graph
    parameter entirely and makes the latency a property of the module, not of
    the input graph.
  * One `or_tree` instantiation for the whole design, so the generator emits
    a mask per vertex rather than a differently-shaped tree per vertex.

The cost to check, not assume: synthesis constant-folds a leaf tied to 0, so
the netlist should collapse back to roughly the true fan-in's LUT count --
i.e. uniformity in the SOURCE, real cost in silicon. That is the claim to
verify, because if Vivado instead keeps 1000 live leaves per vertex the LUT
cost goes quadratic in N. The registered levels should survive folding (they
are explicit reset FFs), which is what keeps the latency uniform; confirm that
too rather than relying on it.

Verify with: the existing 6-config `gen_rtl_or.py` vector check (must stay
PASS, `oob_warnings=0`), plus a synth run comparing LUT/FF against the
fan-in-sized build at the same graph.
