# Collaborator asks — feasibility and sequencing

Raised 2026-11-06. Four asks, assessed against what the code and the available
hardware can actually do today. Each entry says what exists, what must be
built, what it costs, and what blocks it.

**The one structural finding first:** asks 2 and 4 are coupled, and doing 4
first would measure the wrong thing. See "Sequencing" at the end.

---

## 1. Software CPU baseline and a separate GPU baseline for the graph unit

**Why it matters more than it looks.** The measured FPGA cost for `ring50` is
~117 µs fixed per hop, of which the kernel itself is under a microsecond — the
hop is PCIe, enqueue and doorbell, not compute. A CPU doing a 50-bit OR per
vertex will almost certainly beat that by orders of magnitude. So this baseline
may well show the FPGA **losing** at this graph size. That is a result worth
having, not a risk to manage: it relocates the design's claim from "faster per
hop" to "where the crossover actually is", which needs the baseline to state.

**What exists.** `sim/reference.py` is the correctness reference, not a
performance baseline. Nothing times a software hop.

**What to build.**
- `host/cpu_hop.cpp` — same bit-vector hop, and critically the **same
  stdin/stdout query protocol** as `batch_query.cpp`, so `sim/compare_part.py`
  validates it unchanged and the identical 11,032-query sweep applies. Three
  variants worth separating: scalar, word-parallel (`uint64_t` / AVX2), and
  thread-parallel.
- `host/gpu_hop.cu` — same protocol, one thread per vertex or per word.

**Cost / blockers.** CPU: low, no special hardware — but note **this container
has no `g++`, no `nvcc`, no Vitis and no GPU**, so even the CPU baseline builds
on a remote node (FABRIC nodes carry g++ 11.4.0). GPU: needs a GPU node; FABRIC
GPU components (RTX6000 / A30 / A40) are the easiest route since FABRIC access
is working. Both slot into the comparison weave as new arms — `ARM_SPEC` in
`Partition_Three_Arm_Comparison/three_arm_compare.py` is a registry for exactly
this, and the table already renders `icmp: null` as `n/a` for an arm with no
network exchange.

**Reporting care.** A CPU number without its CPU named is meaningless; the
arms already differ 2×64-core (OCT) vs 8 vCPU (FABRIC). The baseline must
record model, clock, core count and compiler flags, the way
`machine-details/` already does.

---

## 2. RTL binary tree for the 1000-entry OR reduction; I/O only in HLS

**Reading the ask.** "1000 entry OR to 1 entry" matches a **high-fan-in
vertex**: `next_state[v] = OR over in-neighbours(v)`, where a vertex in the
N=1000 graph can have up to 1000 in-neighbours. Today the generator emits that
as one flat OR expression and leaves the tree to Vivado. Note there is a
*second* OR in the system — the host-side combine across partitions — which is
separately the measured throughput bottleneck (ask 4 depends on it). **These
are different reductions and worth confirming which is meant**; the plan below
assumes the in-kernel fan-in tree, with the host-side combine handled under
"Sequencing".

**Why it is the right target.** Every design-C bitstream closed timing within
**16 picoseconds** of failing, and that margin comes from the U280 static
shell, not the kernel. A flat 1000-term OR is precisely the structure that
makes depth unpredictable. An explicitly balanced tree with registered levels
turns an uncontrolled combinational depth into a parameter, which is the only
lever that has ever moved WNS on this design.

**What to build.**
- `rtl/or_tree.v` — parameterized `N_IN`, `WIDTH`, `LEVELS_PER_REG`; a balanced
  binary tree, ~`ceil(log2(1000)) = 10` levels, with a register every
  *k* levels so depth trades against latency explicitly.
- An HLS shim holding **only** the AXI4-Stream in/out, per the ask, with sizes
  as parameters, binding the Verilog module (Vitis RTL-kernel flow via
  `package_xo`, or an HLS blackbox).
- `graphgen/` emits the tree's wiring table rather than a flat expression.

**Cost / blockers.** Needs Vivado/Vitis → a Coder compile box
(`csg-fpga-compile0` for U280, `csg-fpga-compile3` for U55C); both are
currently **Stopped**. No RTL simulator here either (`iverilog`, `verilator`,
`vivado` all absent), so simulate with `xsim` on the compile box. Budget ~2 h
per link, plus the known Vivado heap-abort trap that the NRP weave's libudev
shim already works around. The `rand1k` (N=1000) design-C bitstream already
exists as the comparison point.

---

## 3. One FPGA querying its counterpart to complete an answer — over the network *and* over PCIe/host

**A design tension to surface explicitly.** Design P partitions by **target**
vertex *specifically so that no card ever needs its counterpart's data
mid-query*. That is the whole reason `full_step(s) == OR of partial_step_k(s)`
holds exactly, with one exchange per hop and no boundary correction. This ask
is the opposite regime: a card that must *request* data from its peer to
complete an answer. So this is a **second design (call it Q), not a
modification of P** — and the honest expectation is that it performs worse,
because a request-response round trip serialises where P's
send-before-compute overlap gives `max(RTT, local)`. Measuring that penalty
against P is a real result; quietly replacing P with it would be a regression.

**The genuinely new part is the PCIe path.** "Over the PCIe/host side" has two
distinct meanings and the interesting one has never been measured:
- *host-memory bounce* — what the intra-node arm already does (387.7 µs/hop).
- **FPGA-to-FPGA PCIe P2P** — `xbutil p2p --enable`, then a buffer object
  mapped on the peer's memory, so the exchange never touches host DRAM. This
  is a **fourth exchange path** for the table and should sit below the
  host-memory number.

**Cost / blockers.** Design Q needs a new partitioning mode in the generator
plus a request-response protocol in `part_agent` — the largest code change of
the four. P2P needs BAR support and mgmt access: fine on NRP/OCT bare metal,
**unlikely to work on FABRIC VMs**, so the P2P arm is NRP-or-OCT only. Network
arm reuses the existing OCT and FABRIC arms.

---

## 4. FPGA count vs overall latency, for more partitions

**Mostly already supported — the cost is bitstreams, not code.**
- `graphgen/gen_hls_partitioned.py` already takes arbitrary `--nparts` and
  validates `0 <= part < nparts`. Ready.
- `host/part_query.cpp` (intra-node) already accepts **N** bitstreams:
  `<n> <nw> <xclbin0> [<xclbin1> ...]`. Ready.
- `host/part_agent.cpp` is explicitly a **coordinator/worker pair** — one
  `--serve` port, one `--drive` peer, one peer buffer. Distributed N-way needs
  generalising to N−1 peers, and the `nparts != 2` guards in the OCT and
  FABRIC drivers lifted.

**The hardware ceiling, which decides the shape of the experiment.**
- **NRP `csg-2fpga` has 6 U55C cards with only 2 exposed.** Exposing more gives
  `nparts ∈ {2,4,6}` *intra-node* — the clean curve, with no network term
  confounding it. This is the measurement to do first.
- FABRIC hosts are all `fpga_capacity: 1` and only **7 of 24 sites** can run an
  xclbin at all, so wide-area N-way needs N nodes and realistically caps at 4.

**Cost.** `nparts=4` needs 4 new bitstreams, `nparts=6` needs 6 — so {4,6} is
10 links at ~2 h each, ≈20 h of Vitis, parallelisable across compile0 (U280)
and compile3 (U55C). This is the most expensive ask by wall-clock and the
cheapest by code.

---

## Sequencing — why ask 2 should come before ask 4

The host-side combine ORs `nparts` partials per hop and is **O(nparts)**. It is
already measured as the throughput bottleneck: 0.122 µs/query, **70% of
marginal cost and 42% of a batch-1000 hop** — more than the FPGAs and the
network together at that batch size.

So an `nparts` sweep run today would produce a curve whose slope is dominated
by a scalar byte-loop on the host:

```c
for (b = 0; b < nq * qbytes; ++b) state[b] |= p[b];   // host/part_query.cpp
```

That curve would be real, and it would be a measurement of the host CPU, not of
distributing a graph across FPGAs. Two options, either defensible, but the
choice must be deliberate:

1. **Vectorise or move the combine on-device first** (ask 2's sibling
   reduction), then run the `nparts` sweep — the curve then reflects the
   interconnect and the cards.
2. **Run the sweep now and report the combine as the explicit cause** of the
   slope, with the fix as the follow-up.

Recommended order: **1 → 2 → 4 → 3.** Ask 1 is cheap, unblocked, and reframes
every other number. Ask 2 removes the artefact that would otherwise dominate
ask 4. Ask 4 then measures what it is supposed to. Ask 3 is the largest new
design surface and benefits from all three.

## Open questions for the collaborators

1. **Ask 2:** the in-kernel fan-in OR tree (high-fan-in vertex, N=1000), or the
   host-side combine across partitions? They are different reductions with
   different payoffs — the first buys timing margin, the second buys
   throughput.
2. **Ask 3:** is "over the PCIe/host side" the host-memory bounce that the
   intra-node arm already measures, or true FPGA-to-FPGA P2P? Only the latter
   is new.
3. **Ask 4:** which partition counts — `{2,4,6}` intra-node on NRP is the clean
   curve; wide-area N-way costs N scarce FABRIC U280s per point.
4. **Ask 1:** which CPU and which GPU should be the reference? The answer
   decides whether the baseline is "a big server" or "what the FPGA's own host
   happens to be", and those give very different ratios.
