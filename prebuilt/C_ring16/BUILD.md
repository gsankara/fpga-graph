# C_ring16 — design C pipelined batch bitstream

| | |
|---|---|
| graph | `ring16`, N=16, undirected ring, D=8 (antipode is 8 hops either way) |
| generator | `graphgen/gen_hls_pipelined.py` |
| kernel | `graph_engine_batch` (NOT `graph_engine` — see note) |
| platform VBNV | `xilinx_u280_gen3x16_xdma_1_202211_1` |
| sha256 | `f333f3d4b52edd9fb33fcb81de4c803da8afa0b53ae0272a193a4170eedc9994` |
| size | 49,578,741 bytes |
| built | 2026-10-25, Vitis 2023.2 on an NRP Coder box, link 2 h 21 m |

**Timing: closed by 7 picoseconds.** WNS **+0.007 ns**, WHS +0.006 ns,
0 failing endpoints of 448,511. That is not reproducible headroom.

**The verdict is not in `vpp_link.log` for this build** — it appears only in
`_xl/reports/link/imp/impl_1_hw_bb_locked_timing_summary_routed.rpt`. Grepping
the link log alone makes this closed build look like it never finished.

**Verified on hardware** — FABRIC GATECH U280, shell
`xilinx_u280_gen3x16_xdma_base_1`, XRT 2.16.204: 3341 queries, 0 mismatches
against `graphgen/reference.py`. See `RESULTS_C_ring16_gatech.md`.

```bash
batch_query graph_engine.xclbin 16 1 8
```

`GW_LATCH=1`, so one hop gives the closed expansion S u N(S), not N(S).
