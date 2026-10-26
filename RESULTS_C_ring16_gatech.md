# Design C (`ring16`) — verified on FABRIC silicon

Date: 2026-10-25. Card: GATECH `probe-gatech` (host `gatech-w3`), Alveo U280,
shell `xilinx_u280_gen3x16_xdma_base_1`, XRT 2.16.204. Companion to
`RESULTS_C_tree_gatech.md`; same harness, same comparator.

Graph: undirected 16-node ring, `GW_N=16`, `GW_NW=1`, `GW_STAGES=8`
(eccentricity — the antipode is 8 hops away either direction), `GW_LATCH=1`.

## Provenance

Built on the NRP Coder box (`csg-fpga-compile0`), Vitis 2023.2, link 2 h 21 m,
rc=0. SHA256 `f333f3d4b52edd9fb33fcb81de4c803da8afa0b53ae0272a193a4170eedc9994`
(49,578,741 bytes) verified identical on the build box, in the container and on
the node. `ring16.edges` md5 `64b3de06b2521a4985af7e844f2586aa` confirmed
identical on build and run hosts.

**Timing closed, with almost nothing to spare.**

| WNS | TNS | failing setup endpoints | WHS | THS | failing hold endpoints |
|---|---|---|---|---|---|
| **+0.007 ns** | 0.000 | 0 / 448,511 | **+0.006 ns** | 0.000 | 0 / 446,740 |

"All user specified timing constraints are met." Note this verdict appears only
in `_xl/reports/link/imp/impl_1_hw_bb_locked_timing_summary_routed.rpt` — it is
**absent from `vpp_link.log`**, unlike the tree build, so grepping the link log
alone would wrongly suggest the run never closed. Check the routed report.

Seven picoseconds of setup margin is not reproducible headroom. A re-link with
a different seed, or any edit to the kernel, may fail to close.

## Verification

```
ring16  3341 queries (batched), 0 mismatches -> PASS
```

257 seed subsets (empty, all 16 singletons, all 120 pairs, 120 random) x 13 step
counts 0..12, via `sim/compare_batch.py` against `graphgen/reference.py`, driven
by `host/batch_query.cpp`. Comparator unmodified from the csim run.

Spot checks confirm ring semantics: from `{0}`, k=1 gives `{0,1,15}` (wraps both
directions), k=2 gives `{0,1,2,14,15}`, and **k=7 returns 15 of 16 vertices,
missing exactly vertex 8** — the antipode, which is the one vertex at distance 8.
k=8 closes the ring.

**Negative control.** Pulse-mode reference (`sim_steps(..., 0)`) gives
1450 / 3341 mismatches, each differing by exactly the seed set
(`got=[0,1,15] want=[1,15]`). The harness discriminates.

## Latency

Median of 4, `k=8`, one batch per call.

| nq | H2D | exec | D2H |
|---|---|---|---|
| 10 | 0.035 ms | 0.084 ms | 0.027 ms |
| 10,000 | 0.085 ms | 0.199 ms | 0.080 ms |

Fixed cost ~84 us; marginal (199 − 84) / 9990 ≈ **11.5 ns/query**.

Against tree (~62 us fixed, ~10.3 ns/query): ring16 is deeper (8 stages vs 3)
and both figures are higher. **Do not read that as causation.** Pipeline depth
is latency, not throughput, at II=1 — 5 extra stages is ~17 ns total, nowhere
near the ~22 us gap in fixed cost. The cause is unidentified; it could be
placement, clock, or cross-session variation. Two designs is not a trend.

## Caveats

- One card, one site, one session; wall-clock around XRT calls, not counters.
- `load_xclbin` was 6502 ms here — a full reprogram, since the card held the
  tree bitstream. The ~36 ms figure applies only to reloading what is resident.
