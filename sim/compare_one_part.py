#!/usr/bin/env python3
"""compare_one_part.py -- sign off ONE partition's bitstream on hardware.

Why this exists separately from compare_part.py: that comparator scores a
*complete* partitioned run against the whole-graph reference, which needs every
partition present. With a single card the correct answer is not the full hop at
all -- it is partition k's PARTIAL, a full-width state in which only bits owned
by k may be set. This compares against exactly that.

Deliberately restricted to ONE hop. A second hop would feed the incomplete
combined state back in, and the partial-only result then diverges from any
reference -- not a bug, just a quantity nothing predicts. So multi-hop signoff
genuinely requires all partitions, and this refuses to pretend otherwise.

What it proves: the bitstream in the fabric computes the same rows that the
generator emitted, on real hardware. What it does NOT prove: that the
partitions cover the graph (sim/check_wiring.py), or that the per-hop exchange
is correct (needs every card).

usage:
    compare_one_part.py --graph examples/ring50.edges --part 0 --nparts 2 \
        --exe "./part_query 50 1 p0.xclbin --no-selfcheck"
"""
from __future__ import annotations
import argparse, itertools, os, random, shlex, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "graphgen"))
import reference                                             # noqa: E402
import partition as part_mod                                 # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--graph", required=True)
    ap.add_argument("--exe", required=True)
    ap.add_argument("--part", type=int, required=True)
    ap.add_argument("--nparts", type=int, default=2)
    ap.add_argument("--split", default="block", choices=["block", "interleave"])
    ap.add_argument("--n", type=int, default=None)
    ap.add_argument("--max-subset", type=int, default=2)
    ap.add_argument("--random", type=int, default=300)
    ap.add_argument("--seed", type=int, default=11)
    ap.add_argument("--pulse", action="store_true")
    ap.add_argument("--timeout", type=int, default=1800)
    a = ap.parse_args()

    n, edges, directed = reference.parse_edges(a.graph)
    if a.n and a.n != n:
        sys.exit("--n %d disagrees with %s (n=%d)" % (a.n, a.graph, n))
    in_adj = reference.build_in_adj(n, edges, directed)
    latch = not a.pulse
    owner = part_mod.make_partition(n, a.nparts, a.split)
    mine = part_mod.local_vertices(owner, a.part)
    rng = random.Random(a.seed)

    subs = [[]]
    for k in range(1, a.max_subset + 1):
        subs += [list(s) for s in itertools.combinations(range(n), k)]
    subs += [sorted(rng.sample(range(n), rng.randint(2, n))) for _ in range(a.random)]

    queries, expect = [], {}
    for sub in subs:
        s = [0] * n
        for v in sub:
            s[v] = 1
        out = part_mod.partition_step(n, in_adj, owner, a.part, s, latch)
        i = len(queries)
        queries.append("1 %s" % (",".join(map(str, sub)) if sub else "-"))
        expect[i] = sorted(v for v in range(n) if out[v])

    print("partition %d/%d (%s): owns %d of %d vertices; %d one-hop queries"
          % (a.part, a.nparts, a.split, len(mine), n, len(queries)),
          file=sys.stderr)

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
    sys.stderr.write(r.stderr)

    lines = [l for l in r.stdout.strip().split("\n") if l.strip()]
    seen, bad, foreign = set(), 0, 0
    owned = set(mine)
    for line in lines:
        f = line.split()
        if len(f) < 4:
            print("  MALFORMED %r" % line, file=sys.stderr); bad += 1; continue
        i = int(f[0])
        got = [] if f[3] == "-" else [int(x) for x in f[3].split(",")]
        seen.add(i)
        # A partial must never set a bit this partition does not own. Called out
        # separately because it localises the bug: wrong rows vs wrong masking.
        stray = [v for v in got if v not in owned]
        if stray:
            foreign += 1
            if foreign <= 3:
                print("  FOREIGN BITS SET %r -> %s (not owned by part %d)"
                      % (queries[i], stray, a.part), file=sys.stderr)
        if got != expect[i]:
            bad += 1
            if bad <= 5:
                print("  MISMATCH %r\n    got  %s\n    want %s"
                      % (queries[i], got, expect[i]), file=sys.stderr)

    missing = set(expect) - seen
    if missing:
        print("FAIL: %d queries produced no answer" % len(missing), file=sys.stderr)
        return 1
    if bad or foreign:
        print("FAIL: %d/%d mismatched, %d with foreign bits set"
              % (bad, len(expect), foreign), file=sys.stderr)
        return 1
    print("PASS: %d one-hop queries, partition %d matches its reference partial, "
          "no foreign bits ever set" % (len(expect), a.part), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
