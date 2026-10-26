#!/usr/bin/env python3
"""Validate the pipelined BATCH kernel's csim against reference.py."""
import os
import importlib.util, itertools, random, re, subprocess, sys
repo, graph, exe, n, stages = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5])
pkg = os.environ.get("PKG", os.path.expanduser("~/fpga-graph-onecycle"))
spec = importlib.util.spec_from_file_location("reference", repo + "/graphgen/reference.py")
ref = importlib.util.module_from_spec(spec); spec.loader.exec_module(ref)
# Topology from the .edges file -- the box's clone has no prebuilt/ dir, and
# edges are an independent source (not derived from the kernel under test).
edges_path = "%s/generated/%s.edges" % (pkg, graph)
_n, _edges, _directed = ref.parse_edges(edges_path)   # honours the file's own directive
in_adj = ref.build_in_adj(n, _edges, _directed)
random.seed(11)
# Exhaustive pairs are C(n,2): 120 at n=16, half a million at n=1000. Past a
# threshold, sample the subset space instead so the Python reference stays
# tractable -- coverage per query is unchanged, only the query count shrinks.
if n <= 64:
    subs = [[]] + [[v] for v in range(n)] + list(map(list, itertools.combinations(range(n), 2)))
    subs += [random.sample(range(n), random.randint(3, n)) for _ in range(120)]
else:
    subs  = [[]]
    subs += [[v] for v in random.sample(range(n), 100)]
    subs += [sorted(random.sample(range(n), 2)) for _ in range(150)]
    subs += [sorted(random.sample(range(n), random.randint(3, n))) for _ in range(50)]
KS = list(range(0, stages + 5))
q, exp = [], {}
for sub in subs:
    for k in KS:
        i = len(q)
        q.append("%d %s" % (k, ",".join(map(str, sub)) if sub else "-"))
        eff = min(k, stages)                      # kernel clamps to GW_STAGES
        st, _ = ref.sim_steps(n, in_adj, sub, eff, 1)
        exp[i] = sorted(v for v in range(n) if st[v])
out = subprocess.run([exe], input="\n".join(q) + "\n", capture_output=True, text=True).stdout.strip().split("\n")
bad = 0
for line in out:
    f = line.split()
    i = int(f[0]); got = [] if f[3] == "-" else [int(x) for x in f[3].split(",")]
    if got != exp[i]:
        bad += 1
        if bad <= 3: print("  MISMATCH %r got=%s want=%s" % (q[i], got, exp[i]))
print("%-7s %d queries (batched), %d mismatches -> %s" % (graph, len(out), bad, "PASS" if not bad else "FAIL"))
sys.exit(1 if bad else 0)
