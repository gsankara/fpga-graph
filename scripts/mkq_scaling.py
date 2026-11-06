import random, sys
random.seed(7)
N = int(sys.argv[1]); NQ = int(sys.argv[2]); K = int(sys.argv[3])
out = []
for _ in range(NQ):
    seeds = sorted({random.randrange(N) for _ in range(8)})
    out.append("%d %s" % (K, ",".join(map(str, seeds))))
sys.stdout.write("\n".join(out) + "\n")
