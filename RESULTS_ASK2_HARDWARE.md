# Ask 2 on hardware: the RTL OR tree runs correctly on two U280s

Measured 2026-11-07 on FABRIC slice `fpga-part-internode` — `part0` and
`part1`, one Alveo U280 each, at two different sites, exchanging over FABNetv4.
XRT 2.16.204 on both, shell `xilinx_u280_gen3x16_xdma_base_1`.

Bitstreams: `ring50` 2x block, **`--or-mode tree`**, linked with
`OR_MODE=tree bash scripts/build_part.sh ring50 2 block` on `csg-fpga-compile3`
against `xilinx_u280_gen3x16_xdma_1_202211_1`.

| | p0 | p1 |
|---|---|---|
| sha256 | `4fc0f8be…d2c269` | `a33f7868…88ad28` |
| bytes | 49,343,554 | 49,247,698 |
| **WNS / WHS** | **+0.016 / +0.006 ns** | **+0.016 / +0.006 ns** |
| timing met | **yes** | **yes** |

Both verified by sha256 on-node after staging.

## 1. The result that matters: it is correct in silicon

**11,032 queries, 69 hops, 0 mismatches — PASS**, on the same default
`compare_part.py` sweep every other arm runs. This is the first end-to-end
hardware validation of the tree-shaped reduction: RTL tree -> csynth -> v++
link -> two real cards -> exact agreement with `reference.sim_steps()`.

Everything before this was simulation (`xsim` vectors, `check_wiring.py`'s
56,233 orchestrated queries) or synthesis estimate.

## 2. Latency, and what it does and does not show

| | n | min | p50 | p90 | max | mean |
|---|---|---|---|---|---|---|
| hop | 69 | 32,810.5 | **32,938.0** | 33,038.2 | 194,306.0 | 35,289.1 |
| exchange_rtt | 69 | 32,630.5 | 32,728.2 | 32,827.3 | 194,139.5 | 35,079.3 |
| local_fpga | 69 | 219.6 | **305.4** | 337.5 | 405.0 | 302.0 |
| icmp_rtt | — | 32,253.0 | 32,268.0 (avg) | — | 32,402.0 | — |

All microseconds. Path `10.137.2.2 <-> 10.135.1.2`, FABNetv4, tcp/5055.

Against the flat build measured on this same path and slice:

| | flat | tree | delta |
|---|---|---|---|
| hop p50 | 32,940.7 | **32,938.0** | −2.7 us |
| exchange_rtt p50 | 32,788.9 | 32,728.2 | −60.7 us |
| local_fpga p50 | 259.9 | **305.4** | **+45.5 us** |

**The hop is unchanged, as it must be: 99.2% of it is the wide-area
round trip**, and ICMP alone is 32,268 us. Nothing about the OR shape could
move that number, and it did not.

**The `local_fpga` difference is NOT resolvable and must not be read as the
tree being slower.** The within-run spread is 219.6 to 405.0 us — a 185 us
range in a single run of 69 hops — which is four times the 45.5 us
build-to-build difference. One run of each build cannot separate a real effect
from that noise.

There is also a first-principles reason to disbelieve a real 45 us effect:
`ring50` has **100 OR terms**, and the tree adds at most
`ceil(log2(3)) = 2` registered levels over the flat form. At 300 MHz that is
**6.7 ns**. A 45 us difference is 6,700x too large to be the reduction.

What the numbers do say, clearly: **`local_fpga` is ~300 us for a kernel whose
compute is nanoseconds.** That is the ~320 us of XRT enqueue overhead
`RESULTS_GPU_BASELINE.md` identified, now measured directly on the tree build
too. It is untouched by ask 2, as expected — capacity and per-hop overhead
were always independent problems.

## 3. Honest limits of this run

- **One run per build.** No repeats, so no confidence interval on
  `local_fpga`. Resolving a <50 us effect against a 185 us spread needs
  repeated runs, and that was not done.
- **`ring50` only.** 100 OR terms, which is ~0.08% of the 128,000 the tree
  was shown to synthesize. This run proves the tree is *correct* in hardware;
  it says nothing about whether a large tree still closes timing. The
  `n1000d20` tree link (20,000 terms — the size the flat form cannot csynth at
  all) is the build that would answer that.
- **Wide-area arm only.** The intra-node 387.7 us figure in
  `RESULTS_PARTITION.md` came from two cards in one chassis, a different arm.
  This run does not update it.
- **One hop outlier**: hop max 194,306 us with exchange_rtt max 194,139.5 us —
  a network event, not the card. The p50/p90 are the figures to use.
