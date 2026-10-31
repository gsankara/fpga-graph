# P_ring50_u55c_p0of2 — design P partition bitstream

| | |
|---|---|
| design | P — one graph partitioned across FPGAs, partitioned by target vertex |
| graph | `ring50` — 50 vertices, 50 edges (ring), eccentricity 25 |
| partition | p0of2 of 2, **block** split; owns 25 vertices: 0-24 |
| generator | `graphgen/gen_hls_partitioned.py` |
| kernel | `graph_engine_part` |
| platform VBNV (build) | `xilinx_u55c_gen3x16_xdma_3_202210_1` |
| deployment shell (run) | `xilinx_u55c_gen3x16_xdma_base_3` |
| logic UUID | `97088961-FEAE-DA91-52A2-1D9DFD63CCEF` |
| **sha256** | `87a4448869333fed842d82869993c8125c18bc4ed4c4aff99d1250014b099df9` |
| size | 47,299,997 bytes |
| Vitis | 2023.2 |
| Vivado | 2023.2 (SW Build 4029153, Fri Oct 13 20:13:54 MDT 2023) — invoked BY Vitis |
| XRT at build | 2.19.194 (branch 2025.1) |
| g++ at build | 13.3.0 |
| built on | csg-fpga-compile3 (NRP Coder, Ubuntu 24.04.5, 32 cores) |
| link time | ~2 h 20 m |
| WNS / WHS | **+0.003 ns** / +0.009 ns |

## Cross-checking this bitstream

```bash
sha256sum kernel.xclbin   # expect 87a4448869333fed842d82869993c8125c18bc4ed4c4aff99d1250014b099df9
```

Generated HLS source shipped alongside, so the kernel can be
re-derived and diffed without a Vitis install:

```
a84b745b82f17ca9e4175a82a260699b0f4724b6243539ec414d57e8f1e8f039  graph_engine.cpp
cfbeb3415e0d1ddba65331b42db82327b20f85b4c2cd2573b8ca1f0311db6c34  graph_wire.hpp
```

Regenerate and compare:

```bash
python3 graphgen/gen_hls_partitioned.py examples/ring50.edges \
    --part 0 --nparts 2 --split block --name ring50
diff build/ring50_p0of2_block/graph_engine.cpp graph_engine.cpp
```

## Routed timing (from `timing_summary_routed.rpt`)

```
WNS 0.003 ns   TNS 0.000   failing setup 0/449660
WHS 0.009 ns   THS 0.000   failing hold  0/447889
```

The verdict is **not** reliably in `vpp_link.log`; it lives in
`_xl/reports/link/imp/impl_1_hw_bb_locked_timing_summary_routed.rpt`.

## Memory

HBM ONLY -- the U55C has no DDR, so every bundle must be pinned to an HBM bank or the link fails (scripts/u55c.cfg)

## Hardware verification

NRP csg-2fpga, 2 x U55C in one box: 11,032 queries, 0 mismatches; single-query latency 117.8 us

## Important: this is ONE HALF of a pair

A single partition cannot answer a query. Each kernel computes only
its own vertices' rows and leaves every foreign bit 0, so the next
state is `partial_0 OR partial_1` — both partitions are required, and
one exchange is required **per hop**. The generator refuses
`--stages > 1` because a second local stage would read neighbour bits
the card does not own (they read as 0) and be silently wrong.
See `../../RESULTS_PARTITION.md` section 4.
