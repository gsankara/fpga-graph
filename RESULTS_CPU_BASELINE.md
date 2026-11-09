# CPU baseline for the graph hop — and where the FPGA's crossover actually is

Measured 2026-11-06 on FABRIC node `part0` (LOSA), the **same host that drives
the p0 U280**, so the CPU and FPGA numbers come from one machine.

> **Headline.** On `ring50`, one CPU core does the hop in **0.7 µs** against the
> two-FPGA design's **387.7 µs** — **554× faster**. More importantly: the
> CPU/FPGA crossover sits at **~73,000 OR terms**, while the practical ceiling
> for a flat-baked HLS kernel is **~20,000 OR terms**. The current design is
> therefore **3.7× short of its own break-even point** — there is no graph it
> can build today on which it beats a single CPU core.
>
> **SUPERSEDED 2026-11-07 — see section 5.** The ~20,000 ceiling was the FLAT
> OR expression's limit. The RTL binary tree (ask 2) synthesizes **128,000
> terms**, past the ~73,000 crossover, so the "no graph it can build" claim no
> longer holds. The 554x figure on `ring50` and the 5.3 ns/term fit are
> unaffected — they are measurements, not conclusions.

---

## 1. Machine and method

| | |
|---|---|
| host | FABRIC `part0` @ LOSA — AMD **EPYC 7543** 32-Core, 8 vCPU exposed |
| cache | L1d 512 KiB, L2 4 MiB, L3 **128 MiB** (8 instances) |
| compiler | g++ 11.4.0, `-std=c++17 -O3 -march=native -pthread` |
| program | `host/cpu_hop.cpp` |
| semantics | `reference.sim_steps()`, latch mode — identical to the bitstreams |

`cpu_hop.cpp` copies three things from `host/part_query.cpp` so the numbers are
comparable rather than merely adjacent:

1. **Byte-identical stdin/stdout**, so `sim/compare_part.py` validates it with
   no changes and the same default sweep applies.
2. **The same batching**: queries grouped by step count, one timing sample per
   (group, hop) — so sample counts and batch widths match the FPGA runs.
3. **The same hop semantics**, latch by default.

Two modes, because "the CPU baseline" is not one number:

- **`word`** (default) — bit-parallel *across queries*: for each vertex, a
  bitmask over 64 queries, so one 64-bit OR advances 64 queries at once. The
  structural analogue of the card: the FPGA parallelises over vertices with the
  graph as wiring; this parallelises over queries with the graph as an edge list.
- **`scalar`** — the naive per-query, per-vertex translation of
  `reference.sim_steps()`. The "someone wrote the obvious C" number.

---

## 2. Correctness — the comparability run

The identical **11,032-query / 69-hop** default sweep used for all three FPGA
arms, on `ring50`:

| config | per-hop p50 | queries | mismatches |
|---|---|---|---|
| `word`, 1 thread | **0.7 µs** | 11,032 | **0** |
| `scalar`, 1 thread | 134.4 µs | 11,032 | **0** |
| `word`, 8 threads | 338.4 µs | 11,032 | **0** |

All three **PASS**. Against the published FPGA arms on the same sweep and graph:

| arm | exchange | per-hop p50 | vs 1-core CPU |
|---|---|---|---|
| **CPU, 1 core** (`word`) | none | **0.7 µs** | 1× |
| CPU, 1 core (`scalar`) | none | 134.4 µs | 192× slower |
| NRP 2×U55C, one box | host memory | 387.7 µs | **554× slower** |
| OCT 2×U280, one rack | TCP, private LAN | 899.1 µs | 1,284× slower |
| FABRIC 2×U280, LOSA↔GPN | TCP, FABNetv4 | 44,986.6 µs | 64,266× slower |

Even the *naive* scalar CPU beats the two-FPGA intra-node arm by 2.9×.

### The 8-thread number is an artefact — do not quote it as "8-core CPU"

`--threads 8` is **480× slower than 1 thread**, because one hop on `ring50` is
only ~3,750 word-operations and `parallel_hop` creates threads *per hop*:
8 spawns × 69 hops of pure overhead against a few microseconds of work. The
finding is real and worth stating — **at this problem size, threading is pure
loss** — but 338.4 µs measures thread creation, not the EPYC. A persistent pool
would remove the overhead; it would not make threading worthwhile here. The
source now warns on stderr when this regime is entered.

---

## 3. Scaling — where the crossover is

The FPGA's per-hop cost is **essentially constant in graph size** (it is PCIe
transfer, enqueue, doorbell and the exchange; synthesis puts the kernel itself
under a microsecond). The CPU's cost is **linear in OR terms**. So a crossover
must exist, and it is worth knowing where.

Fixed batch of **1,576 queries** (the FPGA sweep's batch width), k=10,
`word` mode, 1 thread. *These are scaling runs, not the comparability sweep
above — they use a fixed synthetic query set and are not validated against the
Python reference, which is impractical at n=100,000.*

| graph | n | OR terms | max fan-in | CPU hop p50 |
|---|---|---|---|---|
| ring50 | 50 | 100 | 2 | 1.2 µs |
| n1000 d2 | 1,000 | 2,000 | 2 | 20.6 µs |
| **n1000 d20** | **1,000** | **20,000** | **20** | **105.0 µs** |
| n1000 d32 | 1,000 | 32,000 | 32 | 215.4 µs |
| n2000 d20 | 2,000 | 40,000 | 20 | 212.3 µs |
| n1000 d64 | 1,000 | 64,000 | 64 | 323.5 µs |
| n4000 d20 | 4,000 | 80,000 | 20 | 429.0 µs |
| n10000 d32 | 10,000 | 320,000 | 32 | 2,151.0 µs |
| n100000 d2 | 100,000 | 200,000 | 2 | 2,485.3 µs |

The fit is clean and linear in OR terms at **~5.3 ns per term** per 1,576-query
batch (≈3.4 ps per term per query). Node count barely matters independently —
`n1000 d64` (64k terms) and `n4000 d20` (80k terms) land where their term counts
predict, not where their vertex counts would.

**Crossover against the 387.7 µs two-card intra-node arm: ~73,000 OR terms**
(interpolating 64k → 323.5 µs and 80k → 429.0 µs).

---

## 4. The finding that matters

From `CAPACITY.md`, measured by `scripts/capacity_sweep.sh`:

> **Practical ceiling for a single flat-baked kernel: ~1000 nodes / ~20k OR
> terms.** The binding limit is **HLS synthesis time, not device resources** —
> csynth goes 9 min → 86 min → timeout across two 2× size steps, while the
> N=1000 design uses only ~74k LUT (~6%) and ~14k FF (<1%) of the U280.

Put the two together:

| | OR terms | CPU hop p50 |
|---|---|---|
| largest graph the design can currently **bake** | ~20,000 | **105.0 µs** |
| graph size needed to **break even** with 2 FPGAs | ~73,000 | 387.7 µs |

**The FPGA design cannot currently reach its own break-even point.** At its
maximum bakeable graph it loses to one CPU core by **3.7×**. And the gap to
break-even is also 3.7× — in OR terms.

> **No longer true as of 2026-11-07.** See section 5.

Two consequences:

1. **The bottleneck is not the silicon, and it never was.** Earlier work
   established that the hop is network (99.3% of local compute hides behind a
   wide-area exchange) and that the host-side combine is the throughput
   bottleneck. This adds the third: the *compute* the FPGA does is work a single
   core does faster, at every size the design can be built at.

2. **Ask 2 is necessary but, we now know, not sufficient.** The GPU baseline
   shows the per-hop overhead is a *separate* problem from the term ceiling: even
   with unlimited capacity the design would still pay ~388 µs a hop, which loses
   to a GPU by 5.7×. See `RESULTS_GPU_BASELINE.md` §4.

3. **Ask 2 is the unlock for capacity, not an optimisation.** The flat 1000-term OR basic
   block is precisely what makes csynth time out, which is what caps the design
   at ~20k terms, which is what keeps it below break-even. An explicit
   parameterised RTL binary OR tree replaces that basic block. **It must buy at
   least 3.7× more OR terms to make the FPGA worth using at all** — that is now
   a concrete, falsifiable acceptance criterion for ask 2, rather than "improve
   timing".

---

## 5. What this does not say

- **It is not a verdict on FPGAs for graph work.** It is a verdict on *this*
  design — one flip-flop per vertex, graph baked as wiring, one hop per
  invocation, driven over PCIe from a host that could have done the OR itself.
  A design that keeps many hops on-card between host round trips, or that
  streams a CSR graph rather than baking it, has a different cost structure
  entirely and is not measured here.
- **The GPU half is now measured** — see `RESULTS_GPU_BASELINE.md`. The answer
  to the crossover question posed here: an A30 doing the *same* PCIe round trip
  lands at 68.4 µs at 20,000 OR terms, beating one core (105.2 µs) above
  ~12,600 terms, and beating the two-FPGA arm by 5.7× at the FPGA's ceiling.
  Its `roundtrip` cost turns out to scale with **state size**, not OR terms, so
  on a large sparse graph (n=100,000) it loses to the CPU again. Crucially it
  shows the FPGA's ~388 µs per hop is **not** an inherent cost of the
  one-hop-per-round-trip structure.
- **One CPU, one compiler.** EPYC 7543 at 8 vCPU. The OCT arm's hosts are
  2×64-core; a 128-core run of the `word` kernel with a persistent pool would
  move the crossover further out, not closer in.
- **The scaling runs are timing-only.** Only the `ring50` run in §2 is validated
  against the reference model.

## 6. Reproducing

```bash
# on a host with g++ (no XRT, no Vitis, no card needed)
g++ -std=c++17 -O3 -march=native host/cpu_hop.cpp -o cpu_hop -pthread

# correctness + the comparability sweep
python3 sim/compare_part.py --graph examples/ring50.edges \
        --exe "./cpu_hop examples/ring50.edges --mode word --threads 1"

# scaling: fixed 1,576-query batch, 10 hops
python3 graphgen/make_graph.py --nodes 1000 --degree 20 -o /tmp/g.edges
python3 scripts/mkq_scaling.py 1000 1576 10 > /tmp/q.txt
./cpu_hop /tmp/g.edges --mode word --threads 1 < /tmp/q.txt > /dev/null
```

---

## 5. Update 2026-11-07: the ceiling moved, so this verdict changed

Everything above was measured against a **~20,000 OR term** ceiling. That
ceiling was a property of the flat OR expression handed to the HLS scheduler,
not of the device. `RESULTS_ASK2_OR_TREE.md` shows the explicit balanced binary
tree csynthesizing **128,000 terms in 9,527 s at 8.6% LUT / 10.3% FF**, while
the flat form does not finish even at 20,000 under a 9,000 s cap. Tree
bitstreams also run correctly on two U280s — 11,032 queries, 0 mismatches
(`RESULTS_ASK2_HARDWARE.md`).

128,000 terms is past the **~73,000** crossover this file identified. So:

| at ~128,000 OR terms | per-hop |
|---|---|
| GPU `roundtrip` (A30) | ~71 µs |
| **2×U280, intra-node** | **~388 µs** |
| CPU, 1 core | **~678 µs** (interpolated from the 5.3 ns/term fit) |

**For the first time the design can be built at a size where it beats a single
CPU core — by ~1.75×.** It still loses to the A30 by ~5.5×.

Three things keep this from being a clean win, in order of how likely each is
to overturn it:

1. **The multi-core number does not exist, and it is the cheapest experiment
   that could erase the 1.75×.** `cpu_hop --threads N` spawns threads *per
   hop* and is 480x slower than single-threaded on `ring50`, so it measures
   thread creation. `part0` exposes 8 vCPU. A correct parallel implementation
   would need only ~2x to wipe out the FPGA's advantage entirely. **Fix
   `--threads` to use a persistent pool before quoting the 1.75× anywhere.**
2. **678 µs is an interpolation of a fit, not a measurement.** The largest
   measured point near it is 80,000 terms at 429.0 µs. Run `cpu_hop` on a
   128,000-term graph.
3. **No FPGA measurement exists at 128,000 terms either.** The 387.7 µs is the
   intra-node arm at `ring50`'s 100 terms, and is assumed constant in graph
   size because the hop is enqueue- and transfer-bound. That assumption is well
   supported but untested at the new ceiling — the `n1000d20` tree link is the
   next step.

The structural conclusion in section 4 is unchanged: **the per-hop overhead is
a separate problem from the term ceiling.** Ask 2 addressed only the ceiling.
