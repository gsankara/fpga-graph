# generated_hls — generator output with no bitstream

These are `graphgen/gen_hls_partitioned.py` outputs that were generated and
kept, but never linked to an `.xclbin`. They are here so the generated HLS for
every partition variant discussed in the results docs is in the repo, not only
the variants that reached hardware.

| directory | graph | split | OR mode | terms | bitstream? |
|---|---|---|---|---|---|
| `ring50_p0of2_interleave` | ring50, n=50 | interleave | flat (pre-dates `--or-mode`) | 50 local of 100 | no |
| `ring50_p1of2_interleave` | ring50, n=50 | interleave | flat (pre-dates `--or-mode`) | 50 local of 100 | no |
| `n1000d20_p0of2_block_tree` | n1000 d20, n=1000, 10,000 edges | block | **tree** | 10,000 local of 20,000, cut 220 | no |
| `n1000d20_p1of2_block_tree` | n1000 d20, n=1000, 10,000 edges | block | **tree** | 10,000 local of 20,000, cut 220 | no |

The variants that DID reach hardware have their own `prebuilt/` directories
with the `.xclbin` and a `BUILD.md`:
`P_ring50_u280_p{0,1}of2` (flat), `P_ring50_u280_tree_p{0,1}of2` (tree),
`P_ring50_u55c_p{0,1}of2` (flat, U55C).

## Why `n1000d20_*_block_tree` matters

20,000 OR terms is the size the **flat** form cannot csynth at all, which is
what ask 2 was for. The HLS here is the tree-shaped emission at that size. It
has never been linked, so nothing in this repo shows whether a tree that large
closes timing on a U280 — see the limits section of
`../../RESULTS_ASK2_HARDWARE.md`.

## One hash note, so a mismatch does not look alarming

Re-running the generator in flat mode today produces output that differs from
the `graph_engine.cpp` shipped in `P_ring50_u280_p{0,1}of2/` by **exactly one
line**: the generator gained a `// OR reduction shape: flat` marker comment
after those bitstreams were built. Everything else is byte-identical, so the
shipped flat bitstreams still correspond to the generator at HEAD.

The `*_interleave` directories here pre-date that marker too, which is why they
carry no `OR reduction shape` comment.
