#!/usr/bin/env python3
"""
compare_part.py -- sign off a PARTITIONED run (csim or hardware) against
reference.py.

Mirrors sim/compare_batch.py, which does the same job for design C, and drives
the same protocol: the program under test reads `<steps> <seeds>` lines and
emits `<idx> <steps> <count> <verts>`. host/part_query.cpp and
host/part_agent.cpp both speak it, so this one comparator signs off the
intra-node, inter-node, and csim paths without modification.

What it is NOT: a check that the partitioning is a correct cover. That lives in
sim/check_wiring.py (metadata and emitted wiring) and in part_query's own
runtime self-check. This file only asks whether the orchestrated answer matches
the whole-graph reference.

Usage:
    compare_part.py --graph examples/ring50.edges --n 50 \
                    --exe "./part_query 50 1 p0.xclbin p1.xclbin" \
                    [--max-subset 2] [--random 300] [--steps 1,2,5,25] [--seed 11]
"""
from __future__ import annotations
import argparse, itertools, os, random, shlex, subprocess, sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "graphgen"))
import reference                                        # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--graph", required=True)
    ap.add_argument("--exe", required=True,
                    help="program under test, with its arguments, as one string")
    ap.add_argument("--n", type=int, default=None, help="override node count")
    ap.add_argument("--max-subset", type=int, default=2)
    ap.add_argument("--random", type=int, default=300)
    ap.add_argument("--steps", default=None, help="comma-separated hop counts")
    ap.add_argument("--seed", type=int, default=11)
    ap.add_argument("--pulse", action="store_true", help="bitstreams built in pulse mode")
    ap.add_argument("--timeout", type=int, default=1800)
    a = ap.parse_args()

    n, edges, directed = reference.parse_edges(a.graph)
    if a.n and a.n != n:
        sys.exit("--n %d disagrees with %s (n=%d)" % (a.n, a.graph, n))
    in_adj = reference.build_in_adj(n, edges, directed)
    latch = not a.pulse
    rng = random.Random(a.seed)

    if a.steps:
        hops = [int(x) for x in a.steps.split(",")]
    else:
        lv = reference.bfs_levels(n, in_adj, [0])
        ecc = max((x for x in lv if x >= 0), default=1)
        hops = sorted({0, 1, 2, 3, max(1, ecc // 2), ecc, ecc + 1})

    # Exhaustive up to --max-subset, then sampled: exhaustive pairs are C(n,2),
    # which is fine at n=50 and a fake hang at n=1000 (fpga skill, trap 23).
    subs = [[]]
    for k in range(1, a.max_subset + 1):
        subs += [list(s) for s in itertools.combinations(range(n), k)]
    subs += [sorted(rng.sample(range(n), rng.randint(2, n))) for _ in range(a.random)]

    queries, expect = [], {}
    for sub in subs:
        for k in hops:
            i = len(queries)
            queries.append("%d %s" % (k, ",".join(map(str, sub)) if sub else "-"))
            st, _ = reference.sim_steps(n, in_adj, sub, k, latch)
            expect[i] = sorted(v for v in range(n) if st[v])

    cmd = shlex.split(a.exe)
    try:
        r = subprocess.run(cmd, input="\n".join(queries) + "\n",
                           capture_output=True, text=True, timeout=a.timeout)
    except subprocess.TimeoutExpired:
        print("FAIL: %r timed out after %ds" % (a.exe, a.timeout), file=sys.stderr)
        return 1
    if r.returncode != 0:
        print("FAIL: %r exited %d" % (a.exe, r.returncode), file=sys.stderr)
        sys.stderr.write(r.stderr[-4000:])
        return 1
    sys.stderr.write(r.stderr)            # keep the program's timing lines

    lines = [l for l in r.stdout.strip().split("\n") if l.strip()]
    seen, bad = set(), 0
    for line in lines:
        f = line.split()
        if len(f) < 4:
            print("  MALFORMED %r" % line, file=sys.stderr); bad += 1; continue
        i = int(f[0])
        got = [] if f[3] == "-" else [int(x) for x in f[3].split(",")]
        seen.add(i)
        if got != expect[i]:
            bad += 1
            if bad <= 5:
                print("  MISMATCH %r\n    got  %s\n    want %s"
                      % (queries[i], got, expect[i]), file=sys.stderr)
    missing = set(expect) - seen
    if missing:
        print("  %d queries produced no answer, e.g. %s"
              % (len(missing), sorted(missing)[:5]), file=sys.stderr)
        bad += len(missing)

    print("%s: %d queries, %d mismatches -> %s"
          % (os.path.basename(a.graph), len(expect), bad, "PASS" if not bad else "FAIL"))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
