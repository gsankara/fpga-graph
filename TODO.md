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
- Intra-node (2 FPGAs in one host) is the OCT-like local case.
- Inter-node across FABRIC sites is the wide-area case.
- **RESOLVED 2026-10-25 — the intra-node arm is impossible on FABRIC.** A sweep
  of all 33 sites found 23 U280 hosts, every one with capacity **exactly 1**.
  No host anywhere on the testbed has two U280s, so neither one VM with two
  FPGAs nor two co-located VMs can be built. (21 of the 23 are free; GATECH and
  PRIN are ours.) CIEN has one `FPGA-Xilinx-SN1022`, a different card.
  `add_component` imposes no per-node cap, so a two-FPGA request builds fine
  client-side and would fail at submit when the orchestrator cannot bind the
  second card — untested, and untestable here.
  **Decision needed:** drop the intra-node arm, or source it off-testbed (NRP,
  or a local dual-U280 box). The inter-node arm is well supported.
- Inter-node pairs, chosen on *per-host* free capacity (snapshot 2026-10-25):
  long-haul `ucsd-w3` + `psc-w2`; short-RTT `psc-w2` + `mass-w2`. Avoid
  `indi-w2`/`max-w3`/`ncsa-w2`/`tacc-w3` (0 free cores) and `star-w3` (4) —
  the U280 is free but the VM will not fit, and it fails late at submit with
  `Insufficient resources : [core]`. Avoid `sri-w2` (3 GB disk) and `clem-w2`
  (33 GB) for a 100 GB tooling VM. Always pin with `add_node(..., host=...)`.

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
