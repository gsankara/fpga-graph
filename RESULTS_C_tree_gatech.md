# Design C (`tree`) — first Coder-built bitstream verified on FABRIC silicon

Date: 2026-10-25. Card: GATECH `probe-gatech` (host `gatech-w3`), Alveo U280,
shell `xilinx_u280_gen3x16_xdma_base_1`, XRT 2.16.204.

## Provenance

Built on the NRP Coder box (`csg-fpga-compile0`), Vitis 2023.2, link
15:03 → 17:39 (2 h 36 m), rc=0, **"All user specified timing constraints are
met."** Transferred Coder → container → FABRIC node; SHA256
`8bd9c880dd9a5da0684abc99fe46dd3e0fbbad37f338dd1ba260e31b8bfcf8f2`
(49,024,199 bytes) verified identical at all three hops.

`tree.edges` md5 `63d689160c7b7e5255160581e1e1468f` and `reference.py` md5
`516f70741ec1cf33e447e46802b7d13b` confirmed identical between the build host
and the run host, so the reference model and the baked graph cannot have drifted.

Kernel VBNV is `xilinx_u280_gen3x16_xdma_1_202211_1` (development platform)
against the card's `xilinx_u280_gen3x16_xdma_base_1` (deployment shell) — the
matching pair. XRT binds on interface UUID, not the VBNV string.

## Verification

`tools/batch_query.cpp` is a new XRT host for the batch kernel. The repo's
`tools/neighbor_query.cpp` drives the older single-query `graph_engine`; design C
exports `graph_engine_batch`, a different signature. Its stdin/stdout are
byte-identical to `sim/tb_batch.cpp`, so `sim/compare_batch.py` validates
hardware unmodified — the same comparator that signed off csim signs off silicon.

```
tree    1496 queries (batched), 0 mismatches -> PASS
```

**Negative control.** Flipping the reference to pulse mode (`sim_steps(..., 0)`)
yields 1302 / 1496 mismatches, each differing exactly by the seed set
(`got=[0,1,2] want=[1,2]`). The harness discriminates; the PASS is evidence.

## Latency (feeds TODO #1)

Median of 5 runs, `k=3`, one batch per call.

| nq | H2D | exec | D2H |
|---|---|---|---|
| 10 | 0.030 ms | 0.062 ms | 0.031 ms |
| 10,000 | 0.090 ms | 0.165 ms | 0.090 ms |

Fixed per-call cost is ~62 µs of `exec` (enqueue + doorbell + wait), independent
of batch size. Marginal cost is (165 − 62) µs / 9990 ≈ **10.3 ns/query**, about
3 clocks at 300 MHz rather than the II=1 ideal of 3.33 ns — the kernel moves
64 B in + 64 B out + 4 B per query across three `m_axi` bundles, so this is
plausibly gmem-bound, not pipeline-bound. **Not yet confirmed** — distinguishing
AXI stalls from pipeline behaviour needs the HLS cosim trace or a profile run.

`load_xclbin` costs **6481 ms on the first load** and ~36 ms on every later one:
XRT skips reprogramming when the bitstream is already resident. Any latency
figure must say which of the two it includes.

## Caveats

- One card, one site, one session. No cross-site or multi-card data here.
- The latency split is wall-clock around XRT calls, not hardware counters.
