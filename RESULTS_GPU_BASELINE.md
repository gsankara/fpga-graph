# GPU baseline for the graph hop — and the finding that the FPGA's overhead is not structural

Measured 2026-11-06 on FABRIC node `gpu0` @ HAWI (`hawi-w2`), an **NVIDIA A30**
alongside an **AMD EPYC 7543** — the *same CPU model* as `part0`, which drove
the CPU baseline. Both binaries were run on this one host, so the GPU/CPU
comparison is single-machine rather than stitched across two.

> **Headline.** The A30 does the `ring50` hop in **29.5 µs** against the
> two-FPGA design's **387.7 µs** — **13× faster** — while running the *same*
> one-hop-per-invocation PCIe round trip the FPGA design uses. That is the
> result that matters: the FPGA's ~388 µs per hop is **not** an unavoidable cost
> of "state over PCIe, one hop at a time". Another accelerator pays 68 µs for
> the same structure on comparable work.
>
> Against a single CPU core the GPU crosses over at **~12,600 OR terms**, and at
> the FPGA's own ~20,000-term ceiling the ordering is
> **GPU 68.4 µs < CPU 105.2 µs < FPGA 387.7 µs.** The FPGA loses to both.

---

## 1. Machine and method

| | |
|---|---|
| host | FABRIC `gpu0` @ HAWI (`hawi-w2`) — AMD **EPYC 7543**, 16 vCPU |
| GPU | **NVIDIA A30**, 24 GiB HBM2, cc 8.0, 56 SMs, PCIe **gen4 ×16** |
| driver / toolkit | 580.178.04 / CUDA 11.5 (`nvcc` V11.5.119), host compiler g++-10 |
| program | `host/gpu_hop.cu` |
| semantics | `reference.sim_steps()`, latch — identical to the bitstreams |

`gpu_hop.cu` copies its stdin/stdout protocol, its group-by-step-count batching
and its hop semantics from `host/cpu_hop.cpp`, which took them from
`host/part_query.cpp`. So `sim/compare_part.py` validates it unchanged and the
identical 11,032-query / 69-hop sweep applies.

**Parallelisation axis** is the same as `cpu_hop`'s `word` mode: bit-parallel
*across queries*. One GPU thread owns one (vertex, query-word) pair, so
consecutive threads read consecutive words of a source row and coalesce. This is
deliberately **not** a frontier-based BFS — the point is to measure the same
primitive the FPGA bakes into wiring (a full-graph OR sweep per hop). A frontier
implementation would win on sparse graphs and would be answering a different
question.

Two modes, because the interesting question is where the PCIe round trip sits:

- **`roundtrip`** (default) — H2D + kernel + D2H **every hop**. The structural
  analogue of the FPGA design, and the only number comparable to its per-hop
  figure.
- **`resident`** — state stays in device memory for the whole group. The "what
  if the host got out of the way" number.

In both modes `[local_gpu]` is the kernel alone, measured with CUDA events, so
the kernel figure is comparable across modes and against `cpu_hop`.

---

## 2. Correctness

The identical **11,032-query / 69-hop** default sweep on `ring50`, all three
**PASS** with **0 mismatches**:

| config | per-hop p50 | kernel p50 | queries | mismatches |
|---|---|---|---|---|
| GPU `roundtrip` | 29.5 µs | 8.2 µs | 11,032 | **0** |
| GPU `resident` | 15.4 µs | 8.2 µs | 11,032 | **0** |
| CPU 1 core (`word`), same host | **0.8 µs** | — | 11,032 | **0** |

The same-host CPU figure (0.8 µs) matches `part0`'s (0.7 µs) on the same EPYC
model, which retrospectively validates the cross-machine comparison in
`RESULTS_CPU_BASELINE.md`.

Transfer breakdown on the `roundtrip` sweep: `[h2d]` p50 2.8 µs, `[d2h]` p50
9.1 µs, kernel 8.2 µs — i.e. **27.75% of the hop is compute**, the rest is PCIe
and launch. D2H costs ~3× H2D here.

---

## 3. Scaling

Fixed batch of **1,576 queries** (the FPGA sweep's batch width), 10 hops, same
graph points as the CPU table. *Timing-only runs on synthetic query sets, not
validated against the Python reference — only §2 is.*

| graph | n | OR terms | CPU 1 core | GPU roundtrip | GPU resident | GPU kernel |
|---|---|---|---|---|---|---|
| ring50 | 50 | 100 | **0.7** | 45.6 | 14.0 | 7.2 |
| n1000 d2 | 1,000 | 2,000 | 15.3 | 69.7 | **13.7** | 11.0 |
| **n1000 d20** | **1,000** | **20,000** | 105.2 | **68.4** | **15.1** | 12.4 |
| n1000 d32 | 1,000 | 32,000 | 162.6 | 68.1 | 15.8 | 13.4 |
| n2000 d20 | 2,000 | 40,000 | 210.5 | 115.6 | 16.3 | 14.2 |
| n1000 d64 | 1,000 | 64,000 | 314.5 | **71.2** | 17.7 | 15.9 |
| n4000 d20 | 4,000 | 80,000 | 426.5 | 182.0 | 16.5 | 17.7 |
| n10000 d32 | 10,000 | 320,000 | 1,646.2 | 380.7 | 28.3 | 30.5 |
| n100000 d2 | 100,000 | 200,000 | **1,943.3** | 3,579.2 | 92.7 | 82.2 |

All times are per-hop p50 in microseconds.

### Three distinct cost laws, which is why the ordering keeps changing

1. **CPU is linear in OR terms** — ~5.0 ns/term per 1,576-query batch here,
   matching the 5.3 ns/term measured on `part0`.
2. **GPU `roundtrip` is linear in STATE SIZE, not OR terms.** The per-hop
   transfer is `n × ceil(nq/64) × 8` bytes each way. At n=100,000 that is
   **20.0 MB each way**, and 40 MB over PCIe gen4 is ~3.3 ms — which is the
   3,579 µs measured, almost exactly. This is why the GPU **loses to the CPU**
   on the largest, sparsest graph: 3,579 µs vs 1,943 µs. Same reason
   `n1000 d64` (64k terms, 71.2 µs) beats `n4000 d20` (80k terms, 182.0 µs) —
   fewer vertices, less state, despite more work.
3. **GPU `resident` is essentially flat**: 13.7 → 17.7 µs across 100 → 80,000
   OR terms, a 800× range in work for a 1.3× change in time. The A30 is nowhere
   near saturated; per-hop cost is kernel launch, not compute. It only starts
   moving at n=10,000+ where the state no longer fits comfortably in cache.

**GPU/CPU crossover: ~12,600 OR terms** (CPU's 5.0 ns/term line crosses the
GPU's ~68 µs roundtrip plateau). Below that the CPU wins, above it the GPU wins
— until state size reasserts itself on very large sparse graphs.

---

## 4. What this does to the FPGA argument

`RESULTS_CPU_BASELINE.md` established that the design cannot reach its own
break-even against one CPU core: crossover ~73,000 OR terms against a ~20,000
term ceiling, so **3.7× short**. The GPU sharpens this in two ways.

> **UPDATE 2026-11-07.** The ~20,000 ceiling has been lifted to **128,000
> terms** by the RTL OR tree (`RESULTS_ASK2_OR_TREE.md`), past the ~73,000
> crossover, so the design can now be built at a size where it beats one CPU
> core. **Part (a) below is therefore historical.** Part (b) is not: at
> ~128,000 terms the GPU still does the same round trip in ~71 µs against the
> FPGA's ~388 µs, so the 5.7× GPU gap survives the capacity fix untouched —
> which is exactly the point part (b) makes.

**(a) At the FPGA's maximum bakeable graph, it is last.**

| at ~20,000 OR terms | per-hop p50 |
|---|---|
| GPU `resident` | **15.1 µs** |
| GPU `roundtrip` | 68.4 µs |
| CPU, 1 core | 105.2 µs |
| **2×U280, intra-node** | **387.7 µs** |

The FPGA is **5.7× slower than a GPU** doing the same PCIe round trip and 3.7×
slower than one core.

**(b) The more damaging point: the overhead is not structural.** The standing
explanation for the FPGA's ~388 µs has been that the hop is PCIe transfer,
enqueue and doorbell rather than compute — true, and measured. But `gpu_hop`
in `roundtrip` mode pays *the same architectural price* — state across PCIe,
one hop per device invocation, host in the loop every hop — and lands at
**68 µs**, with 2.8 µs H2D and 9.1 µs D2H. So "one hop per PCIe round trip"
costs tens of microseconds, not hundreds. The remaining ~320 µs is specific to
the XRT/OpenCL enqueue path and this host code, not to the design's shape.

**Consequence for ask 2 — and it held.** Ask 2 cleared the capacity bar at
6.4× (128,000 terms) and the tree runs correctly on hardware, while the per-hop
overhead moved not at all: `local_fpga` measured ~300 µs on the tree build for
a kernel whose compute is nanoseconds. The prediction below was correct.

An RTL binary OR tree raises the term ceiling, and
the bar from the CPU baseline was "≥3.7× more OR terms". That bar is necessary
but **not sufficient**: even with unlimited capacity, the per-hop overhead would
still be ~388 µs, which already loses to a GPU by 5.7× at any size. Capacity and
per-hop overhead are **two independent problems**, and ask 2 only addresses the
first. The second is where the ~320 µs of unexplained enqueue cost lives, and it
is now bounded by a concrete comparison rather than assumed to be irreducible.

---

## 5. What this does not say

- **It is not a verdict on FPGAs for graph work**, and not a claim that a GPU is
  the right tool either. It is a measurement of three implementations of one
  narrow primitive.
- **`resident` mode is not comparable to the FPGA arms.** It is included because
  it bounds the kernel's own cost and shows the device is launch-bound; the
  honest FPGA comparison is the `roundtrip` column.
- **One GPU.** An A30 is a mid-range datacenter part. The kernel is
  memory-bandwidth bound in principle, but at these sizes it never gets there —
  a faster GPU would mostly shorten an already-negligible kernel.
- **Not a frontier BFS.** See §1. On sparse graphs a frontier implementation
  would beat every column here, including the CPU's.
- **The scaling rows are timing-only.** Only §2 is validated against the
  reference model.
- **CUDA 11.5, not the newest.** Ubuntu 22.04's `nvidia-cuda-toolkit`; it cannot
  parse GCC 11's libstdc++, hence `-ccbin g++-10`. The kernel is simple enough
  that a newer toolkit is unlikely to move these numbers.

## 6. Reproducing

```bash
# on a FABRIC node with an A30/A40/RTX6000 attached
sudo apt-get install -y nvidia-driver-535 nvidia-cuda-toolkit g++-10
nvcc -O3 -std=c++17 -arch=sm_80 -ccbin g++-10 host/gpu_hop.cu -o gpu_hop

# correctness + the comparability sweep (both modes)
python3 sim/compare_part.py --graph examples/ring50.edges \
        --exe "./gpu_hop examples/ring50.edges --mode roundtrip"
python3 sim/compare_part.py --graph examples/ring50.edges \
        --exe "./gpu_hop examples/ring50.edges --mode resident"

# scaling: fixed 1,576-query batch, 10 hops
python3 graphgen/make_graph.py --nodes 1000 --degree 20 -o /tmp/g.edges
python3 scripts/mkq_scaling.py 1000 1576 10 > /tmp/q.txt
./gpu_hop /tmp/g.edges --mode roundtrip < /tmp/q.txt > /dev/null
```

Note `-arch=sm_80` is the A30/A100; use `sm_75` for an RTX6000 (Turing) or
`sm_86` for an A40. The program reports the device it found in its `[gpu]` line,
so a mismatch is visible rather than silent.
