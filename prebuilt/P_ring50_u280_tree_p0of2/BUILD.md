# P_ring50_u280_tree_p0of2 - design P partition bitstream, tree OR

| | |
|---|---|
| design | P - one graph partitioned across FPGAs, partitioned by target vertex |
| graph | `ring50` - 50 vertices, 50 edges (ring), eccentricity 25 |
| partition | p0of2 of 2, **block** split; owns 25 vertices: 0-24 |
| terms | local_terms 50; cut_terms 4 (4% of 100) |
| OR reduction shape | **tree** - balanced, explicit named temporaries per level |
| generator | `graphgen/gen_hls_partitioned.py` |
| build command | `OR_MODE=tree bash scripts/build_part.sh ring50 2 block` |
| kernel | `graph_engine_part` |
| platform VBNV (build) | `xilinx_u280_gen3x16_xdma_1_202211_1` |
| deployment shell (run) | `xilinx_u280_gen3x16_xdma_base_1` |
| logic UUID | not recorded |
| **sha256** | `4fc0f8bebe3fef095ee1a8bd197b54ccd352f825e5b12066eedf22df24d2c269` |
| size | 49,343,554 bytes |
| Vitis | not recorded |
| Vivado | not recorded |
| XRT at build | not recorded |
| g++ at build | not recorded |
| XRT at run | 2.16.204 |
| built on | csg-fpga-compile3 (NRP Coder) |
| link time | not recorded |
| WNS / WHS | **+0.016 ns** / +0.006 ns |

## Cross-checking this bitstream

```bash
sha256sum kernel.xclbin   # expect 4fc0f8bebe3fef095ee1a8bd197b54ccd352f825e5b12066eedf22df24d2c269
```

Generated HLS source shipped alongside:

```
97257ff0234c0b49deec8da2fe7b01a06d3aecf40f1d0572529b7d04a5503b20  graph_engine.cpp
cfbeb3415e0d1ddba65331b42db82327b20f85b4c2cd2573b8ca1f0311db6c34  graph_wire.hpp
```

Regenerate with the recorded build command and compare, from the repo root:

```bash
OR_MODE=tree bash scripts/build_part.sh ring50 2 block
diff build/ring50_p0of2_block_tree/graph_engine.cpp \
    prebuilt/P_ring50_u280_tree_p0of2/graph_engine.cpp
diff build/ring50_p0of2_block_tree/graph_wire.hpp \
    prebuilt/P_ring50_u280_tree_p0of2/graph_wire.hpp
```

`graph_wire.hpp` is byte-identical to the flat sibling. Only the OR
emission changed, not the wiring. The build VBNV was verified by reading
the ASCII VBNV from the xclbin header.

## OR mode is not in the metadata

`partition.meta.json` does **not** record the OR mode; it is byte-identical
between the flat and tree builds of this partition. Identify the tree
variant by the sha256, directory name, or
`// OR reduction shape: tree` in the shipped `graph_engine.cpp`.

## Routed timing

WNS **+0.016 ns**, WHS +0.006 ns; timing met.

`timing_summary_routed.rpt` was not synced off the compile box. No
routed-timing excerpt is available beyond these WNS/WHS values.

`ring50` has 100 OR terms total and max fan-in 3. The tree adds at most
`ceil(log2(3)) = 2` registered levels over the flat form
(~6.7 ns at 300 MHz).

## Memory

HBM or DDR; bundles pinned per scripts/u280.cfg

## Hardware verification

2026-11-07, FABRIC slice `fpga-part-internode`: nodes part0 + part1,
one Alveo U280 each, at two different sites, exchanging over FABNetv4.
Path: `10.137.2.2 <-> 10.135.1.2`, tcp/5055.

`sim/compare_part.py` default sweep: 11,032 queries, 69 hops,
**0 mismatches, PASS**. First end-to-end hardware validation of the
tree reduction.

Hop p50 32,938.0 us; exchange_rtt p50 32,728.2 us;
local_fpga p50 305.4 us; ICMP avg 32,268 us.
Full record: `../../RESULTS_ASK2_HARDWARE.md`.

The +45.5 us local_fpga difference versus the flat build does not
establish that the tree is slower. The within-run spread is
219.6-405.0 us, 4x that difference; one run of each build cannot
separate them.

This p0 bitstream alone was also used for the local partition-query
latency analysis in `../../RESULTS_LATENCY_SPLIT.md`: NQ sweeps and
the `--gap-ms` cold-invocation test, with `--no-selfcheck` because one
partition cannot reproduce the full graph.

## Important: this is ONE HALF of a pair

A single partition cannot answer a query. Each kernel computes only
its own vertices' rows and leaves every foreign bit 0, so the next
state is `partial_0 OR partial_1` - both partitions are required, and
one exchange is required **per hop**. The generator refuses
`--stages > 1`.
