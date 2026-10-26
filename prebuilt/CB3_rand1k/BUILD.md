# CB3_rand1k — design C-BRAM bitstream, N=1000

| | |
|---|---|
| graph | `rand1k`, N=1000, undirected, degree ~6, ring backbone + random chords, D=4 |
| generator | `graphgen/gen_hls_bram.py` (adjacency in BRAM, **not** baked into logic) |
| kernel | `graph_engine_batch` |
| parameters | `GW_NW=2`, `GW_NW64=16`, `GW_STAGES=4`, `GW_PAR=8`, `GW_LATCH=1` |
| platform VBNV | `xilinx_u280_gen3x16_xdma_1_202211_1` |
| sha256 | `82b815ee2874de9ca216c305fa5e017a1bc91343b50fe1530816d1bc4ab61ca2` |
| size | 49,725,500 bytes |
| built | 2026-10-26, Vitis 2023.2 on an NRP Coder box, link 2 h 25 m |

**Run it with `nw = 2`**, the host-facing AXI word count. 16 is `GW_NW64`, the
internal 64-bit lane count, and passing it will read the buffers wrong:

```bash
batch_query graph_engine.xclbin 1000 2 4
```

**Timing: the most margin of the three design C bitstreams.** WNS **+0.015 ns**,
WHS +0.006 ns, 0 failing endpoints of 472,295 — on the densest design of the
three. HLS had estimated 2.433 ns against a 2.43 ns effective budget, i.e. 3 ps
over before place-and-route; the router beat that. HLS's 0.90 ns uncertainty is
a conservative routing allowance, not a forecast.

**Verified on hardware** — FABRIC GATECH U280: 2709 queries, 0 mismatches
against `graphgen/reference.py`, with a pulse-mode negative control producing
748 mismatches. See `RESULTS_CB3_rand1k_gatech.md`.

**This design is not II=1.** Baked-logic adjacency gives one query per clock but
at N=1000 emits 3,359,792 instructions and will not synthesise. BRAM adjacency
evaluates `GW_PAR=8` vertices per clock, so a query costs about
`GW_N / GW_PAR * GW_STAGES` = 500 cycles plus overhead. Measured 3.02 us/query
(~906 cycles at 300 MHz) against HLS's predicted 1033. At this size FPGA
execution dominates: H2D + D2H are under 1% of wall time.

`GW_LATCH=1`, so one hop gives the closed expansion S u N(S), not N(S).
`rand1k.edges` is included; its md5 is `5c7a4d1d1a0ea84ca5323ce81767daa5`.
