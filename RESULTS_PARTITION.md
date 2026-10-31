# Design P: one graph across two FPGAs — setup, method and measurements

**The question.** A graph is split across two FPGAs, each holding half the
vertices. What does one BFS hop cost, and how much of that cost is the
distribution itself? Measured 2026-10-31 on three platforms whose *only*
material difference is where the per-hop exchange goes.

**The answer.** Per hop: **387.7 us** with both cards in one box, **899.1 us**
across a rack, **44,986.6 us** across the continent. Correctness identical on
all three: 11,032 queries, 0 mismatches.

---

## 1. Experimental setup

Same design, same graph, same query load on every arm. The exchange path is the
independent variable. Per-machine detail in `machine-details/`.

| | NRP (intra-node) | OCT (datacenter LAN) | FABRIC (wide area) |
|---|---|---|---|
| machines | 1 box, 2 cards | 2 hosts, 1 card each | 2 sites, 1 card each |
| card | 2 x Alveo **U55C** | 2 x Alveo **U280** | 2 x Alveo **U280** |
| where | NRP Coder `csg-2fpga` | CloudLab UMass `pc170`, `pc174`, one experiment | FABRIC `losa-w2` (LOSA) + `gpn-w3` (GPN) |
| exchange | **host memory** | **TCP**, private LAN `192.168.40.30 <-> .32` | **TCP**, FABNetv4 `10.137.2.2 <-> 10.135.13.2` |
| measured net RTT | n/a | **0.206 ms** ICMP avg | **44.343 ms** ICMP avg |
| host program | `host/part_query.cpp` | `host/part_agent.cpp` | `host/part_agent.cpp` |
| shell | `xilinx_u55c_gen3x16_xdma_base_3`, UUID `97088961-FEAE-DA91-52A2-1D9DFD63CCEF` | `xilinx_u280_gen3x16_xdma_base_1`, UUID `283BAB8F-654D-8674-968F-4DA57F7FA5D7` | same as OCT |
| XRT | 2.19.194 (branch 2025.1) | 2.16.204 (branch 2023.2) | 2.16.204 (branch 2023.2) |
| host CPU | 4 cores | 2 x 64 cores | 2 x 8 vCPU |
| g++ | 13.3.0 | 11.4.0 | 11.4.0 |

Bitstreams were built once on an NRP Coder box with **Vitis 2023.2** (U55C
against platform `xilinx_u55c_gen3x16_xdma_3_202210_1`, U280 against
`xilinx_u280_gen3x16_xdma_1_202211_1`) and deployed unmodified. Neither Vitis
nor Vivado nor any licence is needed to *run* an xclbin: only XRT, the matching
deployment shell and `g++`.

The xclbins report the *development* platform VBNV while the cards report the
*deployment* shell. The names differ but the interface UUIDs match, and XRT
resolves on UUID, so a string comparison yields a false "shell mismatch".

---

## 2. The example graph

`examples/ring50.edges`, from `make_graph.py --nodes 50 --degree 2`:

| property | value |
|---|---|
| vertices | 50 |
| edges | 50 -- a ring, vertex *v* adjacent to *v*+-1 mod 50 |
| in-adjacency terms | 100 (2 per vertex) |
| eccentricity from vertex 0 | 25 |
| estimated logic | ~35 LUT, ~50 FF per partition |

Small on purpose. The goal is **latency**, not capacity -- this graph fits one
card thousands of times over. Its value is the eccentricity of 25: a seed can
be driven through a long hop series, which is what exercises the per-hop
exchange repeatedly. A larger or denser graph would change the logic size
without changing the thing being measured.

---

## 3. The data partition

Partitioned **by target vertex**, block split, 2 partitions:

| partition | owns vertices | in-adjacency terms | cut terms |
|---|---|---|---|
| p0of2 | 0-24 (25 vertices) | 50 of 100 | 4 (4.0%) |
| p1of2 | 25-49 (25 vertices) | 50 of 100 | 4 (4.0%) |

The partitions are **disjoint** (no vertex owned twice) and **covering** (every
vertex owned once). Those two properties are what make the decomposition exact.
The generator checks them and the host program asserts them at runtime before
trusting a run.

FPGA *k* holds the in-adjacency wiring of **only its own vertices**. The emitted
kernel is one flat row per owned vertex -- for vertex 0 in the ring:

```c
res[0] = do_hop ? (s[0] | s[1] | s[49]) : s[0];
```

`s[0]` is the self term (latch semantics); `s[1]` and `s[49]` are vertex 0's
in-neighbours. Note `s[49]` is a vertex partition 0 does **not own**: a card
still needs the *whole* state vector as input, because a neighbour may live
anywhere. Only the *outputs* are partitioned. Rows for foreign vertices are
absent, so a partial output has every foreign bit clear by construction.

The 4 cut terms are the ring's two boundaries (24<->25 and 49<->0). The cut is a
reported statistic, not a cost: every arm ships the full state vector anyway,
so cutting fewer edges would not reduce traffic until someone builds a
boundary-only optimisation. A block split cuts 4 of 100 terms; an interleaved
split cuts all 100 -- at identical exchange volume.

---

## 4. How the final result is computed from both FPGAs

One hop is **not** "each card runs a hop and the answers are concatenated":

```
            s  (full 50-bit state, the SAME bits sent to both cards)
            |
      +-----+-----+
      v           v
   FPGA 0      FPGA 1          each computes ONLY its own rows,
   rows 0-24   rows 25-49      leaving every foreign bit 0
      |           |
   partial_0   partial_1       both are FULL-WIDTH 50-bit vectors
      |           |
      +-----+-----+
            v
     s' = partial_0 OR partial_1       bitwise OR  ("combine")
            |
            +------> fed back as s for the next hop
```

**Why a plain OR is exact.** For every vertex *v*, exactly one partition owns
*v* (covering and disjoint). The owner computes *v*'s true next value; every
other partition emits 0 for *v*. So each output bit has exactly one contributor
and the OR can neither double-count nor lose anything:

```
full_step(s)[v]  ==  partial_owner(v)(s)[v]      for every v
full_step(s)     ==  OR over k of partial_k(s)
```

This holds **exactly** -- no boundary correction, no overlap region, no
iteration to convergence. Verified by `sim/verify_partition.py` against the
unpartitioned reference: **185,360 comparisons, 0 failures**.

**One exchange per hop is mandatory, and enforced.** A card needs the whole
state but produces only part of it, so it cannot take a second hop on its own
output -- the neighbour bits it does not own would read as 0 and the answer
would be silently wrong. Every hop therefore requires: broadcast state ->
compute partials -> OR -> feed back. `gen_hls_partitioned.py` **refuses
`--stages > 1`** so the invalid variant cannot be built. Running *k* hops
locally and combining once is a different, wrong computation, caught by ~50% of
the verifier's cases under a block split and ~89% under an interleaved one.

**Where the OR runs, per arm:**

- **NRP** -- the host reads both cards' partials into memory and ORs them on
  the CPU (`host/part_query.cpp`). Reported as `combine`.
- **OCT and FABRIC** -- the coordinator sends the state, computes its own
  partial while the peer works, receives the peer's partial, and ORs the two
  (`host/part_agent.cpp`). Sending *before* computing locally is deliberate, so
  a hop costs about `max(RTT, local)` rather than their sum.

`GW_LATCH=1`, so a hop is a monotone flood-fill: one hop yields the closed
expansion `S union N(S)`, not `N(S)`.

---

## 5. The query load

`sim/compare_part.py` with its **default** parameters on all three arms --
deliberately, so the per-hop numbers are comparable.

**Seed sets: 1,576**

| kind | count |
|---|---|
| empty set | 1 |
| all singletons | 50 |
| all pairs, exhaustive C(50,2) | 1,225 |
| random subsets, size 2-50, seeded RNG | 300 |

**Hop counts: 7** -- `{0, 1, 2, 3, 12, 25, 26}`, derived from the graph's
eccentricity (25): zero, a few small values, half the eccentricity, the
eccentricity, and one beyond it.

**Total: 1,576 x 7 = 11,032 queries.**

**Hop rounds: 69.** Queries are grouped by hop count and each group runs as one
pipelined batch, so a group needing *k* hops contributes *k* rounds:
`0+1+2+3+12+25+26 = 69`. **Each hop round carries a batch of 1,576 queries** --
so the per-hop latencies below are the cost of one exchange plus one batched
kernel invocation, *not* of a single query. Section 7 separates the two.

Expected answers come from `graphgen/reference.py`, an independent
unpartitioned implementation -- not from the FPGA, and not from the partitioned
model.

---

## 6. Latency measurements

### Per-hop (each hop = one exchange + a batch of 1,576 queries)

| arm | exchange path | net RTT | **per-hop p50** | vs baseline |
|---|---|---|---|---|
| **NRP** 2xU55C, one box | host memory | n/a | **387.7 us** | 1x |
| **OCT** 2xU280, one rack | TCP, private LAN | 0.206 ms | **899.1 us** | **2.3x** |
| **FABRIC** 2xU280, LOSA<->GPN | TCP, FABNetv4 | 44.343 ms | **44,986.6 us** | **116x** |

All three: **11,032 queries, 0 mismatches**, with the runtime self-check
confirming the partitions are disjoint and cover all 50 vertices.

### NRP -- intra-node, host-memory exchange
```
[hops] 69 hops over 11032 queries
   per-hop us: min 380.5  p50 387.7  p90 397.8  max 430.3  mean 389.2
   combine mean 199.89 us
```

### OCT -- datacenter LAN (pc170 <-> pc174)
```
[hop]           n=69  min  677.4  p50  899.1  p90 1018.1  max 1804.0  mean  905.2 us
[exchange_rtt]  n=69  min  526.4  p50  650.3  p90  768.4  max 1664.9  mean  669.3 us
[local_fpga]    n=69  min  167.3  p50  253.7  p90  296.6  max  331.3  mean  246.7 us
[card] H2D 5661.1 us | exec 5124.7 us | D2H 5555.6 us (totals)
ICMP RTT (20 pings):  min 0.162  avg 0.206  max 0.256 ms
```

### FABRIC -- wide area (LOSA <-> GPN)
```
[hop]           n=69  min 44831.8  p50 44986.6  p90 45072.6  max 271797.3  mean 48272.5 us
[exchange_rtt]  n=69  min 44666.3  p50 44776.4  p90 44866.8  max 271614.4  mean 48064.6 us
[local_fpga]    n=69  min   167.6  p50   307.0  p90   358.7  max   1317.3  mean   312.3 us
[card] H2D 8350.7 us | exec 6553.3 us | D2H 4446.2 us (totals)
ICMP RTT (20 pings):  min 44.243  avg 44.343  max 45.692 ms
```

---

## 7. Query latency vs throughput (NRP, 2 x U55C)

The per-hop figures cover a batch of 1,576. Sweeping batch size with uniform
one-hop single-seed queries separates fixed from marginal cost:

| batch | hop p50 (us) | per-query (us) | combine (us) |
|---|---|---|---|
| **1** | **117.8** | **117.800** | 0.39 |
| 2 | 119.9 | 59.950 | 0.54 |
| 4 | 117.1 | 29.275 | 0.76 |
| 10 | 119.3 | 11.930 | 1.48 |
| 50 | 128.4 | 2.568 | 6.59 |
| 100 | 135.9 | 1.359 | 12.34 |
| 500 | 212.4 | 0.425 | 60.81 |
| 1000 | 291.5 | **0.291** | 122.62 |

**Single-query latency: 117.8 us.** The fit is affine,
`hop(n) ~= 117 + 0.173n` us:

- **fixed ~117 us/hop**, flat from batch 1 to 10 -- the first ten queries are
  effectively free (buffer transfer + kernel invocation + exchange, paid once)
- **marginal ~0.173 us/query**; best measured 0.291 us/query (3.4M q/s) at 1000

**The model predicts the headline number.** At the sweep's batch of 1,576:
`117 + 0.173 x 1576 = 389.6 us` against **387.7 us** measured -- 0.5%. The
per-hop figure and the batch sweep are two views of one cost structure.

**The host-side combine dominates marginal cost.** `combine` scales at
~0.122 us/query -- **70% of the 0.173 us marginal**, and 42% of a batch-1000
hop. Past a few hundred queries per hop the bottleneck is neither the FPGAs nor
the exchange but the CPU OR-ing bit vectors. Vectorising it, or moving the OR
on-device, is the obvious target if throughput ever matters.

**Single-query cost of distribution is far worse than the batched figure.** One
wide-area query costs ~44.8 ms, essentially all RTT, against 117.8 us
intra-node: roughly **380x**, not 116x. Batching amortises the RTT over 1,576
queries; single-query latency is where distribution hurts most.

---

## 8. What the breakdown shows

**The send-before-compute overlap only pays when RTT dominates.** On FABRIC,
hop (44,987) ~= exchange (44,776) and the 307 us of local compute is **99.3%
hidden** -- a hop costs `max(RTT, local)`. On OCT the same code is essentially
**additive**: hop (899.1) ~= exchange (650.3) + local (253.7) = 904. Once local
compute and the exchange are the same order of magnitude, the overlap buys
almost nothing. Optimise it for wide-area links; it is not where LAN time goes.

**On a LAN, protocol overhead dominates; on a WAN it is invisible.**

| arm | ICMP RTT | measured exchange | overhead |
|---|---|---|---|
| OCT (LAN) | 206 us | 650 us | **+444 us (3.2x)** |
| FABRIC (WAN) | 44,343 us | 44,776 us | +433 us (1.01x) |

The absolute overhead is nearly identical (~440 us of syscall and TCP cost) --
1% of a wide-area hop, but more than twice the raw network time on a LAN. The
LAN arm has optimisation headroom left; the wide-area arm has none.

**The FPGAs are never the bottleneck.** 254-307 us of compute against 0.2 ms or
44 ms of flight time. The cost of distributing this graph is geography, not
silicon.

**Quote p50, not mean.** One wide-area hop hit 271.8 ms (~6x p50), pulling that
arm's mean to 48.3 ms. Over 69 samples a single retransmit dominates an average.

---

## 9. Correctness chain

| level | evidence |
|---|---|
| decomposition is exact | `sim/verify_partition.py`: **185,360** comparisons vs `reference.py`, 0 failures |
| emitted wiring matches the graph | `sim/check_wiring.py`: structural (rows == owned set, terms == in_adj + self) + 9,828 behavioural queries |
| bitstream matches the wiring, 1 card | `sim/compare_one_part.py` on OCT pc174: 1,576 one-hop queries, 0 mismatches, **no foreign bits ever set** |
| -- its negative control | the same bitstream scored against the *other* partition's reference: **fails 1,295/1,296** |
| 2 cards, host-memory exchange | NRP: 11,032 queries, 0 mismatches |
| 2 cards, LAN exchange | OCT: 11,032 queries, 0 mismatches |
| 2 cards, wide-area exchange | FABRIC: 11,032 queries, 0 mismatches |

The negative control is what makes the passes evidence rather than a comparator
that always agrees.

---

## 10. Bitstreams

| target | partition | bytes | WNS | WHS | sha256 |
|---|---|---|---|---|---|
| U280 | p0of2 | 49,355,051 | +0.016 ns | +0.006 ns | `e5385375f21cff73c097ce3662fc0c818deb8023a45a1a72e0c5ef962e58bffa` |
| U280 | p1of2 | 49,649,011 | +0.016 ns | +0.006 ns | `8b7346ba1e8c852b55163a5deac3d8a17a4939af81b4cc89b5ebff1e7b9feff2` |
| U55C | p0of2 | 47,299,997 | +0.003 ns | +0.009 ns | `87a4448869333fed842d82869993c8125c18bc4ed4c4aff99d1250014b099df9` |
| U55C | p1of2 | 46,637,197 | +0.003 ns | +0.009 ns | `c0d7fc55948f87de74deddcc785f09053e5a314ccd48502df38907686ade6751` |

All four closed timing, all from Vitis 2023.2, each verified by sha256 after
every transfer. The U55C pair closed at **3 picoseconds** of setup slack -- a
margin set by the static shell, not the kernel: these are ~35 LUT designs that
closed no better than a 28-line vector add. There is no headroom to add logic.

---

## 11. Consistency checks

- `local_fpga` p50: 253.7 us (OCT) vs 307.0 us (FABRIC) -- same U280 hardware
  and kernel at different sites, agreeing within 20%.
- Batch model vs headline: predicted 389.6 us vs measured 387.7 us (0.5%).
- Wide-area RTT reproducibility: 44.343 ms at first measurement, 44.277 ms
  after a slice renewal ~20 minutes later (0.15%).

---

## 12. Reproducing

```bash
# gate before spending link time (no compiler needed, under a second)
python3 sim/check_wiring.py build/ring50_p0of2_block build/ring50_p1of2_block

# intra-node: two cards in one box
python3 sim/compare_part.py --graph examples/ring50.edges --n 50 \
    --exe "./part_query 50 1 p0.xclbin p1.xclbin"

# two hosts: worker first, then the coordinator
./part_agent --serve 5055 50 1 p1.xclbin                      # on the peer
python3 sim/compare_part.py --graph examples/ring50.edges --n 50 \
    --exe "./part_agent --drive <peer>:5055 50 1 p0.xclbin"
```

Weaves that automate deployment and measurement, each with platform setup notes
in its own `SETUP.md`:
`my_artifacts/{NRP_U55C_Partition,OCT_Dual_U280_Partition,FABRIC_Partition_InterNode}/`
