// gpu_hop.cu -- GPU baseline for the graph hop (ask 1, GPU half).
//
// Why this exists
// ---------------
// host/cpu_hop.cpp established that one CPU core does the ring50 hop in 0.7 us
// against the two-FPGA design's 387.7 us, and that the CPU/FPGA crossover sits
// at ~73,000 OR terms while a flat-baked HLS kernel tops out near ~20,000. So
// the design loses to a single core at every size it can be built at.
//
// The GPU asks a sharper version of the same question. RESULTS_CPU_BASELINE.md
// put it this way: "A GPU's PCIe round trip is the same order as the FPGA's, so
// the interesting question is whether its compute advantage over one CPU core
// shows up before that round trip swamps it -- i.e. the same crossover
// question, with a different constant."
//
// That is exactly what this program measures, and it is why it reports TWO
// numbers per run rather than one:
//
//   [hop]        H2D + kernel + D2H, every hop. This is the structural analogue
//                of the FPGA design -- one hop per device invocation, state
//                shipped across PCIe each time -- so it is the number that is
//                comparable to the 387.7 / 899.1 / 32,940.7 us FPGA arms.
//   [local_gpu]  kernel only, measured with CUDA events. The analogue of
//                [local_fpga] in the partitioned arms, and the number that is
//                comparable to cpu_hop's pure-compute figure.
//
// Reporting only the first would understate the silicon; reporting only the
// second would be the mistake the FPGA numbers already made for months. The
// gap between them IS the finding.
//
// Fidelity -- what makes this comparable
// --------------------------------------
// Copied exactly from host/cpu_hop.cpp, which in turn copied it from
// host/part_query.cpp:
//
//   1. stdin/stdout are byte-identical to sim/tb_part.cpp and batch_query.cpp,
//      so sim/compare_part.py validates this binary with NO changes and the
//      identical 11,032-query / 69-hop default sweep applies.
//   2. Queries are grouped by step count, one timing sample per (group, hop),
//      so sample counts and batch widths match every other arm.
//   3. Hop semantics are reference.sim_steps(): latch by default
//      (next[v] = state[v] OR (OR over in-neighbours)), pulse under --pulse.
//   4. Graph parsing mirrors graphgen/reference.py parse_edges(), including the
//      '# directed' / '# undirected' / '# nodes N' directives and dedupe.
//
// Parallelisation axis
// --------------------
// Same axis as cpu_hop's `word` mode: bit-parallel ACROSS QUERIES. State is
// transposed so each vertex holds a bitmask over the batch's queries, and one
// 64-bit OR advances 64 queries at once. One GPU thread owns one
// (vertex, query-word) pair, so a thread's reads walk that vertex's
// in-adjacency row at a fixed word offset -- consecutive threads read
// consecutive words, which coalesces.
//
// This is deliberately NOT a frontier-based BFS. The point is to measure the
// same primitive the FPGA bakes into wiring (a full-graph OR sweep per hop),
// not to produce the fastest possible BFS. A frontier implementation would win
// on sparse graphs and would be answering a different question.
//
// Modes
// -----
//   --mode roundtrip  (default) H2D + kernel + D2H every hop. Faithful to the
//                     FPGA design's one-hop-per-invocation structure.
//   --mode resident   State stays in device memory for the whole group; copied
//                     up once and back once. The "what if the host got out of
//                     the way" number, i.e. the cost structure the CPU baseline
//                     doc flags as unmeasured: "A design that keeps many hops
//                     on-card between host round trips [...] has a different
//                     cost structure entirely."
//
// In BOTH modes [local_gpu] is the kernel-only time, so the kernel figure is
// directly comparable across modes.
//
// Build:
//   nvcc -O3 -std=c++17 -arch=native gpu_hop.cu -o gpu_hop
//   # nvcc older than 11.5 has no -arch=native; use the real target, e.g.
//   #   RTX6000 (Turing) -arch=sm_75   A30/A40 (Ampere) -arch=sm_80 / sm_86
//
// Run:
//   ./gpu_hop <graph.edges> [--mode roundtrip|resident] [--pulse] [--block N]
//   python3 sim/compare_part.py --graph examples/ring50.edges \
//           --exe "./gpu_hop examples/ring50.edges"
//
// Protocol -- one query per stdin line:
//   <steps> <v1,v2,...>        ("-" or empty = empty set)
// One response line per query:
//   <input_line_index> <steps> <active_count> <v1,v2,...>
// Timing goes to stderr so it never perturbs the comparator.
#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

#include <cuda_runtime.h>

using clk = std::chrono::high_resolution_clock;
static double us(clk::time_point a, clk::time_point b) {
    return std::chrono::duration<double, std::micro>(b - a).count();
}

#define CU(call)                                                               \
    do {                                                                       \
        cudaError_t _e = (call);                                               \
        if (_e != cudaSuccess) {                                               \
            fprintf(stderr, "ERR cuda %s failed at %s:%d: %s\n", #call,        \
                    __FILE__, __LINE__, cudaGetErrorString(_e));               \
            exit(1);                                                           \
        }                                                                      \
    } while (0)

// --------------------------------------------------------------- graph input
// Mirrors graphgen/reference.py parse_edges(): '#' comments, the '# directed',
// '# undirected' and '# nodes N' directives, undirected by default.
struct Graph {
    unsigned n = 0;
    bool directed = false;
    std::vector<std::vector<unsigned>> in_adj;   // in_adj[v] = u with u -> v
};

static bool load_graph(const std::string& path, Graph& g, std::string& err) {
    std::ifstream f(path);
    if (!f) { err = "cannot open " + path; return false; }
    std::vector<std::pair<unsigned, unsigned>> edges;
    long maxid = -1, forced_n = -1;
    std::string raw;
    while (std::getline(f, raw)) {
        std::string line = raw;
        size_t a = line.find_first_not_of(" \t\r\n");
        if (a == std::string::npos) continue;
        size_t b = line.find_last_not_of(" \t\r\n");
        line = line.substr(a, b - a + 1);
        if (line.empty()) continue;
        if (line[0] == '#') {
            std::istringstream ss(line.substr(1));
            std::string tok; ss >> tok;
            for (auto& c : tok) c = (char) tolower(c);
            if (tok == "directed")        g.directed = true;
            else if (tok == "undirected") g.directed = false;
            else if (tok == "nodes")      { long v; if (ss >> v) forced_n = v; }
            continue;
        }
        std::istringstream ss(line);
        long u, v;
        if (!(ss >> u >> v)) { err = "malformed edge line: " + line; return false; }
        edges.push_back({(unsigned) u, (unsigned) v});
        maxid = std::max(maxid, std::max(u, v));
    }
    long n = (forced_n >= 0) ? forced_n : maxid + 1;
    if (n <= 0) { err = path + ": could not determine node count"; return false; }
    g.n = (unsigned) n;
    g.in_adj.assign(g.n, {});
    for (auto& e : edges) {
        if (e.first >= g.n || e.second >= g.n) {
            err = "edge out of range for n=" + std::to_string(g.n); return false;
        }
        g.in_adj[e.second].push_back(e.first);
        if (!g.directed) g.in_adj[e.first].push_back(e.second);
    }
    for (auto& a2 : g.in_adj) {                    // dedupe, as reference does
        std::sort(a2.begin(), a2.end());
        a2.erase(std::unique(a2.begin(), a2.end()), a2.end());
    }
    return true;
}

// ------------------------------------------------------------------- kernel
// One thread owns one (vertex, query-word) pair:
//   nxt[v][w] = (latch ? cur[v][w] : 0) | OR over u in in_adj(v) of cur[u][w]
//
// tid -> (v = tid / QW, w = tid % QW), so consecutive threads in a warp read
// consecutive words of the same source row: coalesced. The in-adjacency row is
// read through __ldg because every thread handling vertex v walks the same
// row_start/row_end pair, which makes it a broadcast through the read-only
// path rather than QW separate loads.
__global__ void hop_kernel(const unsigned* __restrict__ row,
                           const unsigned* __restrict__ col,
                           const uint64_t* __restrict__ cur,
                           uint64_t* __restrict__ nxt,
                           unsigned n, unsigned QW, int latch) {
    size_t tid = (size_t) blockIdx.x * blockDim.x + threadIdx.x;
    size_t total = (size_t) n * QW;
    if (tid >= total) return;
    unsigned v = (unsigned) (tid / QW);
    unsigned w = (unsigned) (tid % QW);

    uint64_t acc = latch ? cur[(size_t) v * QW + w] : 0ull;
    unsigned s = __ldg(&row[v]), e = __ldg(&row[v + 1]);
    for (unsigned i = s; i < e; ++i) {
        unsigned u = __ldg(&col[i]);
        acc |= cur[(size_t) u * QW + w];
    }
    nxt[(size_t) v * QW + w] = acc;
}

int main(int argc, char** argv) {
    std::string graph_path, mode = "roundtrip";
    bool latch = true;
    int block = 256;
    std::vector<std::string> pos;
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        if (a == "--mode" && i + 1 < argc)        mode = argv[++i];
        else if (a == "--block" && i + 1 < argc)  block = atoi(argv[++i]);
        else if (a == "--pulse")                  latch = false;
        // Accepted and ignored, for argument-compatibility with cpu_hop and the
        // FPGA hosts so the same weave arg can drive any of them.
        else if (a == "--threads" && i + 1 < argc) ++i;
        else                                      pos.push_back(a);
    }
    if (pos.empty()) {
        fprintf(stderr,
            "usage: %s <graph.edges> [--mode roundtrip|resident] [--pulse] [--block N]\n"
            "\n"
            "  --mode roundtrip  (default) H2D + kernel + D2H every hop; the\n"
            "                    structural analogue of the FPGA design and the\n"
            "                    number comparable to its per-hop figure\n"
            "  --mode resident   state stays on the device for the whole group;\n"
            "                    the 'host out of the way' number\n"
            "\n"
            "[hop] is the per-hop cost in the selected mode; [local_gpu] is\n"
            "always kernel-only, so it is comparable across modes and to\n"
            "cpu_hop's pure-compute number.\n"
            "\n"
            "Reads queries on stdin, writes answers on stdout, timing on stderr.\n"
            "Validate with: python3 sim/compare_part.py --graph <g> --exe \"%s <g>\"\n",
            argv[0], argv[0]);
        return 1;
    }
    graph_path = pos[0];
    long n_arg = (pos.size() > 1) ? atol(pos[1].c_str()) : -1;
    if (mode != "roundtrip" && mode != "resident") {
        fprintf(stderr, "ERR --mode must be roundtrip or resident (got %s)\n", mode.c_str());
        return 1;
    }
    if (block <= 0 || block > 1024) { fprintf(stderr, "ERR --block must be 1..1024\n"); return 1; }

    Graph g;
    std::string err;
    if (!load_graph(graph_path, g, err)) { fprintf(stderr, "ERR %s\n", err.c_str()); return 1; }
    if (n_arg > 0 && (unsigned) n_arg != g.n) {
        fprintf(stderr, "ERR n=%ld disagrees with %s (n=%u)\n", n_arg, graph_path.c_str(), g.n);
        return 1;
    }
    const unsigned n = g.n;

    int ndev = 0;
    if (cudaGetDeviceCount(&ndev) != cudaSuccess || ndev == 0) {
        // Same shape of message part_agent uses, so a driver/CUDA problem is
        // never mistaken for a correctness failure.
        fprintf(stderr, "ERR 0 devices found (no CUDA device or driver mismatch)\n");
        return 1;
    }
    cudaDeviceProp prop{};
    CU(cudaGetDeviceProperties(&prop, 0));

    // ---- read every query up front, exactly as the other hosts do ---------
    std::vector<unsigned> ks;
    std::vector<std::vector<unsigned>> seeds;
    {
        std::string line;
        while (std::getline(std::cin, line)) {
            if (line.find_first_not_of(" \t\r\n") == std::string::npos) continue;
            std::istringstream ss(line);
            long k; ss >> k;
            std::string rest; ss >> rest;
            std::vector<unsigned> sd;
            if (!rest.empty() && rest != "-") {
                std::istringstream vs(rest);
                std::string t;
                while (std::getline(vs, t, ',')) if (!t.empty()) sd.push_back((unsigned) atoi(t.c_str()));
            }
            ks.push_back((unsigned) k);
            seeds.push_back(std::move(sd));
        }
    }
    if (ks.empty()) { fprintf(stderr, "ERR no queries on stdin\n"); return 1; }

    // ---- CSR of the in-adjacency, built once and left on the device -------
    // The graph is static across the whole sweep, so it is uploaded once. This
    // mirrors the FPGA, where the graph is baked into the bitstream and is not
    // part of any per-hop transfer -- charging the graph upload to every hop
    // would be measuring the wrong thing.
    std::vector<unsigned> row(n + 1, 0), col;
    size_t total_terms = 0;
    for (unsigned v = 0; v < n; ++v) total_terms += g.in_adj[v].size();
    col.reserve(total_terms);
    for (unsigned v = 0; v < n; ++v) {
        row[v + 1] = row[v] + (unsigned) g.in_adj[v].size();
        for (unsigned u : g.in_adj[v]) col.push_back(u);
    }

    fprintf(stderr, "[gpu] device=%s cc=%d.%d sms=%d mode=%s block=%d "
                    "n=%u in-adj-terms=%zu latch=%d\n",
            prop.name, prop.major, prop.minor, prop.multiProcessorCount,
            mode.c_str(), block, n, total_terms, latch ? 1 : 0);

    unsigned *d_row = nullptr, *d_col = nullptr;
    CU(cudaMalloc(&d_row, (n + 1) * sizeof(unsigned)));
    CU(cudaMemcpy(d_row, row.data(), (n + 1) * sizeof(unsigned), cudaMemcpyHostToDevice));
    if (!col.empty()) {
        CU(cudaMalloc(&d_col, col.size() * sizeof(unsigned)));
        CU(cudaMemcpy(d_col, col.data(), col.size() * sizeof(unsigned), cudaMemcpyHostToDevice));
    } else {
        CU(cudaMalloc(&d_col, sizeof(unsigned)));     // never dereferenced
    }

    cudaEvent_t ev0, ev1;
    CU(cudaEventCreate(&ev0));
    CU(cudaEventCreate(&ev1));

    std::vector<double> hop_us, kern_us, h2d_us, d2h_us;
    std::vector<std::string> outline(ks.size());
    size_t total_q = 0;
    const unsigned kmax = *std::max_element(ks.begin(), ks.end());

    // One group per step count, one timing sample per hop within a group --
    // the same decomposition host/part_query.cpp and cpu_hop.cpp use, so the
    // sample counts and batch widths line up with every other arm.
    for (unsigned kk = 0; kk <= kmax; ++kk) {
        std::vector<size_t> idx;
        for (size_t i = 0; i < ks.size(); ++i) if (ks[i] == kk) idx.push_back(i);
        if (idx.empty()) continue;
        const size_t nq = idx.size();
        const unsigned QW = (unsigned) ((nq + 63) / 64);
        const size_t words = (size_t) n * QW;
        const size_t bytes = words * sizeof(uint64_t);

        std::vector<uint64_t> cur(words, 0ull), nxt(words, 0ull);
        for (size_t q = 0; q < nq; ++q)
            for (unsigned v : seeds[idx[q]])
                if (v < n) cur[(size_t) v * QW + q / 64] |= (1ull << (q % 64));

        uint64_t *d_cur = nullptr, *d_nxt = nullptr;
        CU(cudaMalloc(&d_cur, bytes));
        CU(cudaMalloc(&d_nxt, bytes));

        const size_t grid = (words + block - 1) / (size_t) block;

        if (mode == "resident") {
            // Up once, back once: the per-hop figure then contains no PCIe.
            CU(cudaMemcpy(d_cur, cur.data(), bytes, cudaMemcpyHostToDevice));
            for (unsigned hop = 0; hop < kk; ++hop) {
                auto h0 = clk::now();
                CU(cudaEventRecord(ev0));
                hop_kernel<<<(unsigned) grid, block>>>(d_row, d_col, d_cur, d_nxt,
                                                       n, QW, latch ? 1 : 0);
                CU(cudaEventRecord(ev1));
                CU(cudaGetLastError());
                CU(cudaEventSynchronize(ev1));
                auto h1 = clk::now();
                float ms = 0.f;
                CU(cudaEventElapsedTime(&ms, ev0, ev1));
                kern_us.push_back(ms * 1000.0);
                hop_us.push_back(us(h0, h1));
                std::swap(d_cur, d_nxt);
            }
            CU(cudaMemcpy(cur.data(), d_cur, bytes, cudaMemcpyDeviceToHost));
        } else {
            // One hop per device invocation, state across PCIe each way -- the
            // FPGA design's structure.
            for (unsigned hop = 0; hop < kk; ++hop) {
                auto h0 = clk::now();
                CU(cudaMemcpy(d_cur, cur.data(), bytes, cudaMemcpyHostToDevice));
                auto t_h2d = clk::now();

                CU(cudaEventRecord(ev0));
                hop_kernel<<<(unsigned) grid, block>>>(d_row, d_col, d_cur, d_nxt,
                                                       n, QW, latch ? 1 : 0);
                CU(cudaEventRecord(ev1));
                CU(cudaGetLastError());
                CU(cudaEventSynchronize(ev1));
                auto t_k = clk::now();

                CU(cudaMemcpy(nxt.data(), d_nxt, bytes, cudaMemcpyDeviceToHost));
                auto h1 = clk::now();

                float ms = 0.f;
                CU(cudaEventElapsedTime(&ms, ev0, ev1));
                kern_us.push_back(ms * 1000.0);
                h2d_us.push_back(us(h0, t_h2d));
                d2h_us.push_back(us(t_k, h1));
                hop_us.push_back(us(h0, h1));
                cur.swap(nxt);
            }
        }

        CU(cudaFree(d_cur));
        CU(cudaFree(d_nxt));

        for (size_t q = 0; q < nq; ++q) {
            std::string vs; unsigned c = 0;
            for (unsigned v = 0; v < n; ++v)
                if (cur[(size_t) v * QW + q / 64] >> (q % 64) & 1ull) {
                    if (c) vs += ","; vs += std::to_string(v); ++c;
                }
            char buf[64];
            snprintf(buf, sizeof(buf), "%zu %u %u ", idx[q], kk, c);
            outline[idx[q]] = std::string(buf) + (c ? vs : "-");
        }
        total_q += nq;
    }

    for (const auto& s : outline) if (!s.empty()) printf("%s\n", s.c_str());

    CU(cudaFree(d_row));
    CU(cudaFree(d_col));
    CU(cudaEventDestroy(ev0));
    CU(cudaEventDestroy(ev1));

    // ---- timing ----------------------------------------------------------
    auto stats = [](const char* tag, std::vector<double> s, const char* note) {
        if (s.empty()) return;
        std::sort(s.begin(), s.end());
        double sum = 0; for (double v : s) sum += v;
        auto pct = [&](double p) { return s[(size_t) (p * (s.size() - 1) + 0.5)]; };
        fprintf(stderr, "%-15s n=%zu  min %8.1f  p50 %8.1f  p90 %8.1f  "
                        "max %8.1f  mean %8.1f us%s%s\n",
                tag, s.size(), s.front(), pct(0.50), pct(0.90), s.back(),
                sum / s.size(), note ? "  " : "", note ? note : "");
    };

    if (!hop_us.empty()) {
        std::vector<double> s = hop_us;
        std::sort(s.begin(), s.end());
        double sum = 0; for (double v : s) sum += v;
        auto pct = [&](double p) { return s[(size_t) (p * (s.size() - 1) + 0.5)]; };

        // "[hop] n=..." is what part_agent prints and what the weave drivers'
        // LAT_RE parses; "[hops] N hops over M queries" is what part_query
        // prints and what HOPS_RE parses. Emitting one of each means this
        // binary drops into either parser unchanged, exactly as cpu_hop does.
        fprintf(stderr,
                "[hop]           n=%zu  min %8.1f  p50 %8.1f  p90 %8.1f  "
                "max %8.1f  mean %8.1f us\n",
                s.size(), s.front(), pct(0.50), pct(0.90), s.back(), sum / s.size());
        fprintf(stderr,
                "[hops] %zu hops over %zu queries | per-hop us: min %.1f p50 %.1f "
                "p90 %.1f max %.1f mean %.1f\n",
                s.size(), total_q, s.front(), pct(0.50), pct(0.90), s.back(),
                sum / s.size());

        // The kernel-only figure, named to match [local_fpga] in the
        // partitioned arms. The ratio [hop]/[local_gpu] is the whole point of
        // this program: it says how much of a GPU hop is PCIe rather than
        // compute, which is the same question the FPGA arms answer with
        // 99.2% hidden behind the exchange.
        stats("[local_gpu]", kern_us, "kernel only");
        stats("[h2d]", h2d_us, nullptr);
        stats("[d2h]", d2h_us, nullptr);

        if (!kern_us.empty()) {
            std::vector<double> k = kern_us;
            std::sort(k.begin(), k.end());
            double kp50 = k[(size_t) (0.50 * (k.size() - 1) + 0.5)];
            double hp50 = pct(0.50);
            if (kp50 > 0.0)
                fprintf(stderr, "[split] kernel is %.2f%% of the hop p50 "
                                "(%.1f us of %.1f us); the rest is PCIe + launch\n",
                        100.0 * kp50 / hp50, kp50, hp50);
        }

        // No network exchange: this is a single device. Printed so the weave
        // drivers' parsers see the same key set every arm emits.
        fprintf(stderr, "[exchange_rtt]  n=0  (none: single device, no exchange)\n");
        fprintf(stderr, "[total] %.3f ms in hops\n", sum / 1000.0);
    }
    return 0;
}
