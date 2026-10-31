#!/usr/bin/env python3
"""
check_wiring.py -- validate the wiring gen_hls_partitioned.py emitted, without
a compiler.

csim and cosim need Vitis (or at least g++) and therefore the build box. This
check runs anywhere: it parses the generated graph_engine.cpp, recovers each
baked row expression, and holds it against the graph two ways.

  STRUCTURAL  every owned vertex gets exactly one row; no row is emitted for a
              vertex this partition does not own; and each row's OR terms are
              exactly in_adj[v] (plus the self term in latch mode). A generator
              that dropped or duplicated a term fails here.
  BEHAVIOURAL evaluate the recovered expressions as the hardware would, OR the
              partitions' partials, iterate with one exchange per hop, and
              compare against reference.sim_steps.

This catches a generator bug before it costs a 2.5 h link. It does NOT replace
csim: it says nothing about the ap_uint plumbing, the batch loop, or the AXI
interfaces, which is what `make csim` on the build box covers.

Usage:
    check_wiring.py build/ring50_p0of2_block build/ring50_p1of2_block
                    [--graph examples/ring50.edges] [--random 300] [--seed 7]
"""
from __future__ import annotations
import argparse, json, os, random, re, sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "graphgen"))
import reference                                        # noqa: E402
import partition as part                                # noqa: E402

ROW = re.compile(r'^\s*res\[(\d+)\]\s*=\s*do_hop\s*\?\s*\((.*?)\)\s*:\s*s\[(\d+)\]\s*;\s*$')
TERM = re.compile(r's\[(\d+)\]')


def parse_rows(path):
    """vertex -> sorted list of source vertices in its OR expression."""
    rows = {}
    dup = []
    for line in open(os.path.join(path, "graph_engine.cpp")):
        m = ROW.match(line)
        if not m:
            continue
        v, expr, passthru = int(m.group(1)), m.group(2), int(m.group(3))
        if v != passthru:
            raise AssertionError("row %d passes through s[%d]" % (v, passthru))
        if v in rows:
            dup.append(v)
        # Reject anything that is not a pure OR of state bits: a stray & or ^
        # would evaluate differently in hardware than in this checker.
        stripped = TERM.sub("", expr).replace("|", "").strip()
        if stripped:
            raise AssertionError("row %d has non-OR content: %r" % (v, expr))
        rows[v] = sorted(int(t) for t in TERM.findall(expr))
    if dup:
        raise AssertionError("duplicate rows for vertices %s" % dup)
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("parts", nargs="+", help="generated partition directories")
    ap.add_argument("--graph", default=None)
    ap.add_argument("--random", type=int, default=300)
    ap.add_argument("--seed", type=int, default=7)
    a = ap.parse_args()

    metas = [json.load(open(os.path.join(p, "partition.meta.json"))) for p in a.parts]
    m0 = metas[0]
    graph = a.graph or os.path.join("examples", m0["graph"])
    n, edges, directed = reference.parse_edges(graph)
    in_adj = reference.build_in_adj(n, edges, directed)
    latch = m0["latch"]

    # --- the partitions must agree about the problem and complement each other
    for m in metas[1:]:
        for key in ("graph", "n", "nparts", "split", "latch", "stages"):
            if m[key] != m0[key]:
                sys.exit("partition mismatch on %r: %r vs %r" % (key, m0[key], m[key]))
    if len(metas) != m0["nparts"]:
        sys.exit("given %d partitions but they declare nparts=%d"
                 % (len(metas), m0["nparts"]))
    owned = [set(m["local_vertices"]) for m in metas]
    union = set().union(*owned)
    for i in range(len(owned)):
        for j in range(i + 1, len(owned)):
            if owned[i] & owned[j]:
                sys.exit("partitions %d and %d both own %s"
                         % (i, j, sorted(owned[i] & owned[j])))
    if union != set(range(n)):
        sys.exit("partitions do not cover the graph; unowned: %s"
                 % sorted(set(range(n)) - union))

    # --- STRUCTURAL -------------------------------------------------------
    rows_by_part = []
    for p, m in zip(a.parts, metas):
        rows = parse_rows(p)
        local = set(m["local_vertices"])
        if set(rows) != local:
            extra, missing = set(rows) - local, local - set(rows)
            sys.exit("%s: rows %s not owned, owned-but-missing %s"
                     % (p, sorted(extra), sorted(missing)))
        for v, terms in rows.items():
            want = sorted(set(in_adj[v]) | ({v} if latch else set()))
            if terms != want:
                sys.exit("%s: row %d wired to %s, graph says %s"
                         % (p, v, terms, want))
        rows_by_part.append(rows)
    print("structural: %d partitions, %d rows total, every row matches in_adj%s"
          % (len(metas), sum(len(r) for r in rows_by_part),
             " + self (latch)" if latch else " (pulse)"))

    # --- BEHAVIOURAL ------------------------------------------------------
    def hw_partial(rows, s, do_hop):
        """Evaluate one partition's recovered wiring exactly as emitted."""
        out = [0] * n
        for v, terms in rows.items():
            out[v] = (1 if any(s[u] for u in terms) else 0) if do_hop else s[v]
        return out

    rng = random.Random(a.seed)
    lv = reference.bfs_levels(n, in_adj, [0])
    ecc = max((x for x in lv if x >= 0), default=1)
    hops = list(range(0, ecc + 3))

    cases = [[]] + [[v] for v in range(n)]
    cases += [sorted(rng.sample(range(n), rng.randint(2, n))) for _ in range(a.random)]

    checked = bad = 0
    for seed in cases:
        for k in hops:
            want, _ = reference.sim_steps(n, in_adj, seed, k, latch)
            s = [1 if v in seed else 0 for v in range(n)]
            for _ in range(k):                      # one exchange per hop
                partials = [hw_partial(r, s, True) for r in rows_by_part]
                s = part.combine(partials, n)
            checked += 1
            if s != want:
                bad += 1
                if bad <= 3:
                    print("  MISMATCH seed=%s steps=%d differs at %s"
                          % (seed[:8], k, [v for v in range(n) if s[v] != want[v]]),
                          file=sys.stderr)
    print("behavioural: %d orchestrated queries, %d mismatches -> %s"
          % (checked, bad, "PASS" if not bad else "FAIL"))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
