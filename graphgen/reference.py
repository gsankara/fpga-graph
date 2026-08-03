"""
reference.py -- graph parsing + golden software model for the FPGA
routing-graph engine.

Compute semantics (from the design doc, "optical-interconnect-design.md"):

    state[v] in {0,1}, one bit per node.
    One clock cycle advances the wavefront by exactly one graph hop:

        pulse mode (the doc's literal headline formula):
            next[v] = OR over in-neighbors u of v : state[u]

        latch mode (monotone flood-fill / reachability -- once on, stays on):
            next[v] = state[v] OR ( OR over in-neighbors u of v : state[u] )

Edges are directed u -> v meaning "v hears u". Undirected graphs add both
directions. This module is the single source of truth; gen_hls.py emits HLS
whose behaviour must match sim_steps() exactly.
"""
from __future__ import annotations
import sys, json
from collections import deque


def parse_edges(path):
    """Parse a .edges file. Lines 'u v' (0-indexed ints). '#' starts a comment.
    Directives: '# directed' / '# undirected' (default undirected),
                '# nodes N' to force node count.
    Returns (n, edges, directed) where edges is a list of (u, v) as given.
    """
    directed = False
    forced_n = None
    edges = []
    maxid = -1
    with open(path) as f:
        for raw in f:
            line = raw.strip()
            if not line:
                continue
            if line.startswith('#'):
                toks = line[1:].split()
                if len(toks) >= 1 and toks[0].lower() == 'directed':
                    directed = True
                elif len(toks) >= 1 and toks[0].lower() == 'undirected':
                    directed = False
                elif len(toks) >= 2 and toks[0].lower() == 'nodes':
                    forced_n = int(toks[1])
                continue
            a, b = line.split()[:2]
            u, v = int(a), int(b)
            edges.append((u, v))
            maxid = max(maxid, u, v)
    n = forced_n if forced_n is not None else maxid + 1
    if n <= 0:
        raise ValueError(f"{path}: could not determine node count")
    return n, edges, directed


def build_in_adj(n, edges, directed):
    """in_adj[v] = sorted list of nodes u with an edge u->v (v hears u)."""
    in_adj = [set() for _ in range(n)]
    for (u, v) in edges:
        if not (0 <= u < n and 0 <= v < n):
            raise ValueError(f"edge ({u},{v}) out of range for n={n}")
        in_adj[v].add(u)
        if not directed:
            in_adj[u].add(v)
    return [sorted(s) for s in in_adj]


def sim_steps(n, in_adj, seed, num_steps, latch):
    """Run num_steps hops. seed = iterable of initially-on node ids.
    Returns (final_state list[int 0/1], trace list of active-counts per step)."""
    s = [0] * n
    for v in seed:
        s[v] = 1
    trace = []
    for _ in range(num_steps):
        ns = [0] * n
        for v in range(n):
            acc = s[v] if latch else 0
            if not acc:
                for u in in_adj[v]:
                    if s[u]:
                        acc = 1
                        break
            ns[v] = acc
        s = ns
        trace.append(sum(s))
    return s, trace


def bfs_levels(n, in_adj, seed):
    """Golden BFS depth each node is first reached at (reverse of in_adj is the
    forward reachability). Returns list of level (or -1 if unreachable)."""
    # forward adjacency: u -> v means v hears u, so activation flows u -> v.
    fwd = [[] for _ in range(n)]
    for v in range(n):
        for u in in_adj[v]:
            fwd[u].append(v)
    level = [-1] * n
    q = deque()
    for v in seed:
        level[v] = 0
        q.append(v)
    while q:
        u = q.popleft()
        for v in fwd[u]:
            if level[v] == -1:
                level[v] = level[u] + 1
                q.append(v)
    return level


def degree_stats(in_adj):
    degs = [len(a) for a in in_adj]
    nz = [d for d in degs] or [0]
    return {
        "min_indeg": min(nz), "max_indeg": max(nz),
        "avg_indeg": round(sum(nz) / len(nz), 3),
        "total_terms": sum(nz),
    }


if __name__ == "__main__":
    # quick self-test / inspector: python reference.py file.edges [seed]
    path = sys.argv[1]
    seed = [int(x) for x in sys.argv[2].split(',')] if len(sys.argv) > 2 else [0]
    n, edges, directed = parse_edges(path)
    in_adj = build_in_adj(n, edges, directed)
    lv = bfs_levels(n, in_adj, seed)
    reach = sum(1 for x in lv if x >= 0)
    diam = max((x for x in lv if x >= 0), default=0)
    print(json.dumps({
        "file": path, "n": n, "edges": len(edges), "directed": directed,
        "seed": seed, "reachable": reach, "eccentricity_from_seed": diam,
        **degree_stats(in_adj),
    }, indent=2))
