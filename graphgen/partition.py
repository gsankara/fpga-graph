"""
partition.py -- split a graph's vertex set across several FPGAs and model the
distributed hop exactly.

PARTITIONING AXIS
-----------------
We partition by the *target* vertex: FPGA k owns a subset V_k of the vertices
and holds the in-adjacency lists of exactly those vertices. One hop on FPGA k
computes, for v in V_k only,

    ns[v] = s[v] | OR over u in in_adj[v] : s[u]        (latch mode)
    ns[v] =        OR over u in in_adj[v] : s[u]        (pulse mode)

and leaves every bit outside V_k clear. Because the V_k are disjoint and cover
V, the partial results have disjoint support and

    full_step(s) == OR over k of partial_step_k(s)

holds *exactly*, with no boundary correction. That identity is what
sim/verify_partition.py checks, and it is the reason this decomposition needs
no approximation: the OR is a union over a partition of the output bits.

WHY THE INPUT IS NOT PARTITIONED
--------------------------------
FPGA k needs the *whole* state s to evaluate in_adj[v] -- a neighbour u of a
local vertex may live anywhere. So each hop is:

    broadcast s (N bits) -> every FPGA
    each FPGA emits its partial (N bits, only its own set)
    OR the partials -> s for the next hop

One exchange per hop. That is the quantity the latency experiments measure:
on OCT the exchange is a host memcpy between two cards in one box, on FABRIC
it is a wide-area round trip between two sites.

The exchange *volume* is N bits regardless of how the vertices are split, so
the cut size does not change communication cost in this scheme -- it is
reported by cut_stats() as a statistic, and as the figure of merit for a later
boundary-only optimisation (send just the bits the peer's rows actually read).
"""
from __future__ import annotations


def make_partition(n, nparts=2, mode="block"):
    """owner[v] = which partition owns vertex v.

    block      contiguous ranges; on a ring this cuts only 2 edges.
    interleave round-robin; on a ring this cuts every edge.

    The two modes bracket the locality question: same graph, same exchange
    volume, very different cut.
    """
    if nparts < 1:
        raise ValueError("nparts must be >= 1")
    if mode == "block":
        # ceil division so the earlier partitions take the remainder
        per = (n + nparts - 1) // nparts
        owner = [min(v // per, nparts - 1) for v in range(n)]
    elif mode == "interleave":
        owner = [v % nparts for v in range(n)]
    else:
        raise ValueError("mode must be 'block' or 'interleave'")
    present = set(owner)
    missing = [k for k in range(nparts) if k not in present]
    if missing:
        raise ValueError(
            "partition %s leaves partitions %s with no vertices (n=%d, nparts=%d)"
            % (mode, missing, n, nparts))
    return owner


def local_vertices(owner, part):
    """Sorted list of vertices owned by `part`."""
    return [v for v, o in enumerate(owner) if o == part]


def partition_step(n, in_adj, owner, part, s, latch):
    """One hop as computed by partition `part` alone.

    Returns a full-width state in which only bits owned by `part` may be set,
    so partials from different partitions can simply be OR'd.
    """
    out = [0] * n
    for v in range(n):
        if owner[v] != part:
            continue
        acc = s[v] if latch else 0
        if not acc:
            for u in in_adj[v]:
                if s[u]:
                    acc = 1
                    break
        out[v] = acc
    return out


def combine(partials, n):
    """OR the per-partition partials into the next full state."""
    out = [0] * n
    for p in partials:
        for v in range(n):
            if p[v]:
                out[v] = 1
    return out


def sim_steps_partitioned(n, in_adj, owner, nparts, seed, num_steps, latch):
    """num_steps hops, each one a partitioned step followed by an exchange.

    Byte-for-byte the same contract as reference.sim_steps: returns
    (final_state, trace_of_active_counts). verify_partition.py asserts the two
    agree on every input it tries.
    """
    s = [0] * n
    for v in seed:
        s[v] = 1
    trace = []
    for _ in range(num_steps):
        partials = [partition_step(n, in_adj, owner, k, s, latch)
                    for k in range(nparts)]
        s = combine(partials, n)
        trace.append(sum(s))
    return s, trace


def cut_stats(n, in_adj, owner):
    """Edge-cut and per-partition load.

    cut_terms  in-adjacency terms (u,v) whose endpoints sit in different
               partitions -- the edges a boundary-only exchange would have to
               carry.
    terms      total in-adjacency terms, and the per-partition split. This is
               the 'adjacencies per FPGA' figure: it is what the baked wiring
               costs in LUTs.
    """
    nparts = max(owner) + 1
    cut = 0
    per_part_terms = [0] * nparts
    per_part_verts = [0] * nparts
    for v in range(n):
        per_part_verts[owner[v]] += 1
        for u in in_adj[v]:
            per_part_terms[owner[v]] += 1
            if owner[u] != owner[v]:
                cut += 1
    total = sum(per_part_terms)
    return {
        "n": n,
        "nparts": nparts,
        "total_terms": total,
        "cut_terms": cut,
        "cut_fraction": round(cut / total, 4) if total else 0.0,
        "vertices_per_part": per_part_verts,
        "terms_per_part": per_part_terms,
    }
