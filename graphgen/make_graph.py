#!/usr/bin/env python3
"""
make_graph.py -- emit a parametric graph as an .edges file, for capacity tests.

Circulant graph: node i connects to i+-1, i+-2, ..., i+-k (mod N), giving a
regular undirected graph of degree d = 2k. The BFS wavefront from any seed
spreads k nodes per hop in each direction, so eccentricity ~= N / (2k) =  N/d.
Clean, scalable, and its reachability is analytically known -- ideal for
pushing the synthesizer to find the node/edge limit.

Usage:
    python make_graph.py --nodes N --degree D [-o out.edges] [--directed]

Total OR terms baked = N * D (this is what bounds FPGA LUT/routing use).
"""
from __future__ import annotations
import argparse, sys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--nodes", type=int, required=True)
    ap.add_argument("--degree", type=int, required=True,
                    help="target degree (rounded down to even for the circulant)")
    ap.add_argument("-o", "--out", default=None)
    ap.add_argument("--directed", action="store_true",
                    help="emit i->i+j only (in-degree = degree)")
    args = ap.parse_args()

    n, d = args.nodes, args.degree
    if n < 2:
        sys.exit("need >= 2 nodes")
    k = d // 2
    if k < 1:
        sys.exit("degree must be >= 2")
    if 2 * k >= n:
        sys.exit(f"degree {2*k} too large for {n} nodes (must be < N)")

    out = args.out or f"circulant_n{n}_d{2*k}.edges"
    terms = n * (k if args.directed else 2 * k)
    with open(out, "w") as f:
        f.write("# directed\n" if args.directed else "# undirected\n")
        f.write(f"# circulant N={n} degree={2*k}  (baked OR terms = {terms})\n")
        f.write(f"# nodes {n}\n")
        for i in range(n):
            for j in range(1, k + 1):
                f.write(f"{i} {(i + j) % n}\n")
                if args.directed:
                    # also i <- i-j so in-degree = k; write as (i-j)->i
                    f.write(f"{(i - j) % n} {i}\n")
    print(f"[make_graph] wrote {out}: N={n} degree={2*k} "
          f"{'directed' if args.directed else 'undirected'} -> {terms} OR terms")


if __name__ == "__main__":
    main()
