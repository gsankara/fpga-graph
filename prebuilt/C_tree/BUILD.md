# C_tree — design C pipelined batch bitstream

| | |
|---|---|
| graph | `tree`, N=11, directed binary tree, D=3 |
| generator | `graphgen/gen_hls_pipelined.py` |
| kernel | `graph_engine_batch` (NOT `graph_engine` — see note) |
| platform VBNV | `xilinx_u280_gen3x16_xdma_1_202211_1` |
| sha256 | `8bd9c880dd9a5da0684abc99fe46dd3e0fbbad37f338dd1ba260e31b8bfcf8f2` |
| size | 49,024,199 bytes |
| built | 2026-10-25, Vitis 2023.2 on an NRP Coder box, link 2 h 36 m |

**Timing: closed with zero margin.** WNS **0.000 ns**, WHS +0.006 ns,
0 failing endpoints of 448,478. "All user specified timing constraints are met"
is true but hides that there is no slack at all. Do not assume a rebuild closes.

**Verified on hardware** — FABRIC GATECH U280, shell
`xilinx_u280_gen3x16_xdma_base_1`, XRT 2.16.204: 1496 queries, 0 mismatches
against `graphgen/reference.py`. See `RESULTS_C_tree_gatech.md`.

Run it with `host/batch_query.cpp`, not `host/host.cpp`: this kernel takes a
whole batch per call and has a different signature.

```bash
batch_query graph_engine.xclbin 11 1 3
```

`GW_LATCH=1`, so one hop gives the closed expansion S u N(S), not N(S).
