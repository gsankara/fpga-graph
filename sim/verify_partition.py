#!/usr/bin/env python3
"""
verify_partition.py -- prove the 2-FPGA decomposition is exact, in software,
before any of it costs link time.

The claim under test: partitioning the vertex set across `nparts` FPGAs, having
each compute only its own rows, and OR-ing the partials, gives bit-for-bit the
same answer as the whole-graph engine -- for every seed set, every hop count,
both latch and pulse semantics, and every split mode.

reference.sim_steps is the repo's single source of truth, so that is what the
partitioned model is held against. A pass here is what licenses building two
bitstreams; a failure here would be invisible on hardware until the two cards
disagreed with the software model and it was unclear which half was wrong.

Usage:
    verify_partition.py examples/ring50.edges [--nparts 2] [--max-subset 2]
                        [--random 400] [--seed 1234] [--quiet]
"""
from __future__ import annotations
import argparse, itertools, json, os, random, sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "graphgen"))
import reference                                        # noqa: E402
import partition as part                                # noqa: E402


def seed_sets(n, max_subset, nrandom, rng):
    """Exhaustive subsets up to max_subset, then nrandom sampled ones.

    Exhaustive-only would be O(n^2) at pairs and worse beyond -- the same trap
    that made the n=1000 comparator look like a hang (fpga skill, trap 23). The
    random tier is what actually exercises wide frontiers.
    """
    seen = set()
    for k in range(0, max_subset + 1):
        for s in itertools.combinations(range(n), k):
            if s not in seen:
                seen.add(s)
                yield list(s)
    for _ in range(nrandom):
        size = rng.randint(1, n)
        s = tuple(sorted(rng.sample(range(n), size)))
        if s not in seen:
            seen.add(s)
            yield list(s)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("graph")
    ap.add_argument("--nparts", type=int, default=2)
    ap.add_argument("--max-subset", type=int, default=2)
    ap.add_argument("--random", type=int, default=400)
    ap.add_argument("--seed", type=int, default=1234)
    ap.add_argument("--steps", default=None,
                    help="comma-separated hop counts; default 0..ecc+2")
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()

    n, edges, directed = reference.parse_edges(a.graph)
    in_adj = reference.build_in_adj(n, edges, directed)
    rng = random.Random(a.seed)

    if a.steps:
        hop_counts = [int(x) for x in a.steps.split(",")]
    else:
        lv = reference.bfs_levels(n, in_adj, [0])
        ecc = max((x for x in lv if x >= 0), default=1)
        hop_counts = list(range(0, ecc + 3))

    cases = list(seed_sets(n, a.max_subset, a.random, rng))
    total = 0
    failures = []
    report = {"graph": a.graph, "n": n, "edges": len(edges),
              "directed": directed, "nparts": a.nparts,
              "hop_counts": hop_counts, "modes": {}}

    for mode in ("block", "interleave"):
        owner = part.make_partition(n, a.nparts, mode)
        stats = part.cut_stats(n, in_adj, owner)
        report["modes"][mode] = {"cut": stats, "checked": 0}
        for latch in (True, False):
            for seed in cases:
                for k in hop_counts:
                    want_s, want_t = reference.sim_steps(n, in_adj, seed, k, latch)
                    got_s, got_t = part.sim_steps_partitioned(
                        n, in_adj, owner, a.nparts, seed, k, latch)
                    total += 1
                    report["modes"][mode]["checked"] += 1
                    if got_s != want_s or got_t != want_t:
                        failures.append({
                            "mode": mode, "latch": latch, "seed": seed, "steps": k,
                            "want_state": want_s, "got_state": got_s,
                            "want_trace": want_t, "got_trace": got_t,
                            "differing_vertices": [v for v in range(n)
                                                   if want_s[v] != got_s[v]],
                        })
                        if len(failures) >= 5:
                            break
                if len(failures) >= 5:
                    break
            if len(failures) >= 5:
                break
        if len(failures) >= 5:
            break

    report["comparisons"] = total
    report["failures"] = len(failures)
    report["verdict"] = "PASS" if not failures else "FAIL"

    if not a.quiet:
        print(json.dumps(report, indent=2))
        for f in failures:
            print("MISMATCH %s latch=%s steps=%d seed=%s differ at %s"
                  % (f["mode"], f["latch"], f["steps"], f["seed"],
                     f["differing_vertices"]), file=sys.stderr)

    if failures:
        print("FAIL: %d of %d comparisons disagreed with reference.sim_steps"
              % (len(failures), total), file=sys.stderr)
        return 1
    print("PASS: %d comparisons, partitioned == whole-graph on every one" % total)
    return 0


if __name__ == "__main__":
    sys.exit(main())
