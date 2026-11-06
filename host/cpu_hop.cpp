// cpu_hop.cpp -- SOFTWARE CPU baseline for the graph hop.
//
// Why this exists
// ---------------
// Every measured FPGA per-hop number so far (387.7 us intra-node, 899.1 us
// across a rack, 44,986.6 us across the continent) is dominated by things that
// are not graph computation: PCIe transfer, kernel enqueue, doorbell/interrupt
// wait, and the network exchange. Synthesis puts the kernel itself at well
// under a microsecond. So "is the FPGA fast?" has never actually been asked
// against a competent software implementation of the same hop. This program
// asks it.
//
// It is a BASELINE, not a competitor: the point is to locate the crossover,
// not to win. A result where the CPU is far faster at n=50 is the expected
// and useful outcome, because it moves the design's claim from "faster per
// hop" to "faster above some graph size / fan-in", which is a claim that can
// then be tested.
//
// Fidelity -- what makes this comparable
// --------------------------------------
// Three things are copied exactly from host/part_query.cpp, because a baseline
// that batches differently is not a baseline:
//
//   1. stdin/stdout are byte-identical to sim/tb_part.cpp and batch_query.cpp,
//      so sim/compare_part.py validates this binary with NO changes and the
//      identical 11,032-query / 69-hop default sweep applies.
//   2. Queries are grouped by step count, and one timing sample is taken per
//      (group, hop) -- so the sample count and the batch width match the FPGA
//      runs exactly (default sweep: 69 samples, batch of 1,576).
//   3. The hop semantics are reference.sim_steps(): latch by default
//      (next[v] = state[v] OR (OR over in-neighbours)), pulse under --pulse.
//
// Two modes, because "the CPU baseline" is not one number
// ------------------------------------------------------
//   --mode scalar   One query at a time, per-vertex loop over the in-adjacency
//                   list with an early exit. This is the naive translation of
//                   reference.sim_steps() and the honest "someone wrote the
//                   obvious C" number.
//   --mode word     (default) Bit-parallel ACROSS QUERIES: state is transposed
//                   so that for each vertex we hold a bitmask over 64 queries,
//                   and one 64-bit OR advances 64 queries at once. This is the
//                   fair "someone who knows what they are doing wrote the C"
//                   number, and it is the structural analogue of what the card
//                   does -- the FPGA parallelises over vertices with the graph
//                   as wiring, this parallelises over queries with the graph as
//                   an edge list.
//
// Quoting either one as "the CPU" without saying which, or without naming the
// CPU, is the mistake this file is trying to make impossible: the arms already
// differ 2x64-core (OCT) vs 8 vCPU (FABRIC).
//
// Build (no XRT, no Vitis, no card needed):
//   g++ -std=c++17 -O3 -march=native cpu_hop.cpp -o cpu_hop -pthread
//
// Run:
//   ./cpu_hop <graph.edges> [--mode word|scalar] [--threads T] [--pulse]
//   python3 sim/compare_part.py --graph examples/ring50.edges \
//           --exe "./cpu_hop examples/ring50.edges"
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
#include <thread>
#include <vector>

using clk = std::chrono::high_resolution_clock;
static double us(clk::time_point a, clk::time_point b) {
    return std::chrono::duration<double, std::micro>(b - a).count();
}

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

// ------------------------------------------------------------------ the hops
// word mode: cur[v * QW + w] is a bitmask over queries (bit q%64 = query q).
// One hop touches every vertex once and every in-adjacency term once, for all
// 64 queries in a word simultaneously.
static void hop_word(const Graph& g, const std::vector<uint64_t>& cur,
                     std::vector<uint64_t>& nxt, size_t QW, bool latch,
                     size_t w0, size_t w1) {
    const unsigned n = g.n;
    for (unsigned v = 0; v < n; ++v) {
        const auto& adj = g.in_adj[v];
        uint64_t* out = &nxt[(size_t) v * QW];
        const uint64_t* self = &cur[(size_t) v * QW];
        for (size_t w = w0; w < w1; ++w) out[w] = latch ? self[w] : 0ull;
        for (unsigned u : adj) {
            const uint64_t* src = &cur[(size_t) u * QW];
            for (size_t w = w0; w < w1; ++w) out[w] |= src[w];
        }
    }
}

// scalar mode: the naive per-query, per-vertex translation of sim_steps().
static void hop_scalar(const Graph& g, const std::vector<uint8_t>& cur,
                       std::vector<uint8_t>& nxt, size_t qbytes, bool latch,
                       size_t q0, size_t q1) {
    const unsigned n = g.n;
    for (size_t q = q0; q < q1; ++q) {
        const uint8_t* s = &cur[q * qbytes];
        uint8_t* ns = &nxt[q * qbytes];
        std::memset(ns, 0, qbytes);
        for (unsigned v = 0; v < n; ++v) {
            int acc = latch ? ((s[v / 8] >> (v % 8)) & 1) : 0;
            if (!acc) {
                for (unsigned u : g.in_adj[v])
                    if ((s[u / 8] >> (u % 8)) & 1) { acc = 1; break; }
            }
            if (acc) ns[v / 8] |= (uint8_t) (1u << (v % 8));
        }
    }
}

// Run one hop across the whole batch, over `threads` workers. Splitting by
// query-word (word mode) or by query (scalar mode) keeps every worker's writes
// disjoint, so no synchronisation is needed inside a hop.
//
// CAUTION -- threads are created PER HOP, so for small graphs this measures
// thread creation and not the CPU. Measured on ring50 (n=50, 100 in-adjacency
// terms, ~3,750 word-ops per hop): 0.7 us/hop at --threads 1 against
// 338.4 us/hop at --threads 8, i.e. 480x SLOWER. The conclusion that threading
// does not pay at this problem size is real, but an 8-thread number from this
// regime must not be quoted as an N-core figure. A persistent pool would remove
// the overhead without making threading worthwhile here. main() warns when the
// per-hop work is too small for the thread count.
template <class Fn>
static void parallel_hop(unsigned threads, size_t units, Fn&& fn) {
    if (threads <= 1 || units < 2) { fn(0, units); return; }
    unsigned t = (unsigned) std::min<size_t>(threads, units);
    std::vector<std::thread> pool;
    size_t per = (units + t - 1) / t;
    for (unsigned i = 0; i < t; ++i) {
        size_t a = i * per, b = std::min(units, a + per);
        if (a >= b) break;
        pool.emplace_back([&fn, a, b] { fn(a, b); });
    }
    for (auto& th : pool) th.join();
}

int main(int argc, char** argv) {
    std::string graph_path, mode = "word";
    bool latch = true;
    unsigned threads = 1;
    std::vector<std::string> pos;
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        if (a == "--mode" && i + 1 < argc)         mode = argv[++i];
        else if (a == "--threads" && i + 1 < argc) threads = (unsigned) atoi(argv[++i]);
        else if (a == "--pulse")                   latch = false;
        else                                       pos.push_back(a);
    }
    if (pos.empty()) {
        fprintf(stderr,
            "usage: %s <graph.edges> [--mode word|scalar] [--threads T] [--pulse]\n"
            "\n"
            "  --mode word    (default) bit-parallel across 64 queries per word\n"
            "  --mode scalar  naive per-query, per-vertex translation of\n"
            "                 reference.sim_steps()\n"
            "\n"
            "Reads queries on stdin, writes answers on stdout, timing on stderr.\n"
            "Validate with: python3 sim/compare_part.py --graph <g> --exe \"%s <g>\"\n",
            argv[0], argv[0]);
        return 1;
    }
    graph_path = pos[0];
    // A positional n/nw may follow, for argument-compatibility with the FPGA
    // hosts. n is cross-checked; nw is irrelevant to a CPU and ignored.
    long n_arg = -1;
    if (pos.size() > 1) n_arg = atol(pos[1].c_str());
    if (mode != "word" && mode != "scalar") {
        fprintf(stderr, "ERR --mode must be word or scalar (got %s)\n", mode.c_str());
        return 1;
    }
    if (threads == 0) threads = std::max(1u, std::thread::hardware_concurrency());

    Graph g;
    std::string err;
    if (!load_graph(graph_path, g, err)) { fprintf(stderr, "ERR %s\n", err.c_str()); return 1; }
    if (n_arg > 0 && (unsigned) n_arg != g.n) {
        fprintf(stderr, "ERR n=%ld disagrees with %s (n=%u)\n", n_arg, graph_path.c_str(), g.n);
        return 1;
    }
    const unsigned n = g.n;

    // ---- read every query up front, exactly as the FPGA hosts do ----------
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

    size_t total_terms = 0;
    for (auto& a : g.in_adj) total_terms += a.size();
    fprintf(stderr, "[cpu] mode=%s threads=%u n=%u in-adj-terms=%zu latch=%d\n",
            mode.c_str(), threads, n, total_terms, latch ? 1 : 0);

    // Threads are spawned per hop, so below roughly 100k in-adjacency terms the
    // spawn cost exceeds the work. Say so loudly rather than let the number be
    // quoted as an N-core result: on ring50 --threads 8 is 480x slower than 1.
    if (threads > 1 && total_terms < 100000) {
        fprintf(stderr,
            "[cpu] WARNING: --threads %u with only %zu in-adj terms. Threads are\n"
            "[cpu]          created per hop, so this very likely measures thread\n"
            "[cpu]          creation, not this CPU. Compare against --threads 1\n"
            "[cpu]          before quoting it; on ring50 8 threads is 480x SLOWER.\n",
            threads, total_terms);
    }

    std::vector<double> hop_us;
    std::vector<std::string> outline(ks.size());
    size_t total_q = 0;
    const unsigned kmax = *std::max_element(ks.begin(), ks.end());

    // One group per step count, one timing sample per hop within a group --
    // the same decomposition host/part_query.cpp uses, so sample counts and
    // batch widths line up with the FPGA arms.
    for (unsigned kk = 0; kk <= kmax; ++kk) {
        std::vector<size_t> idx;
        for (size_t i = 0; i < ks.size(); ++i) if (ks[i] == kk) idx.push_back(i);
        if (idx.empty()) continue;
        const size_t nq = idx.size();

        if (mode == "word") {
            const size_t QW = (nq + 63) / 64;
            std::vector<uint64_t> cur((size_t) n * QW, 0ull), nxt((size_t) n * QW, 0ull);
            for (size_t q = 0; q < nq; ++q)
                for (unsigned v : seeds[idx[q]])
                    if (v < n) cur[(size_t) v * QW + q / 64] |= (1ull << (q % 64));

            for (unsigned hop = 0; hop < kk; ++hop) {
                auto h0 = clk::now();
                parallel_hop(threads, QW, [&](size_t a, size_t b) {
                    hop_word(g, cur, nxt, QW, latch, a, b);
                });
                auto h1 = clk::now();
                hop_us.push_back(us(h0, h1));
                cur.swap(nxt);
            }
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
        } else {
            const size_t qbytes = (n + 7) / 8;
            std::vector<uint8_t> cur(nq * qbytes, 0), nxt(nq * qbytes, 0);
            for (size_t q = 0; q < nq; ++q)
                for (unsigned v : seeds[idx[q]])
                    if (v < n) cur[q * qbytes + v / 8] |= (uint8_t) (1u << (v % 8));

            for (unsigned hop = 0; hop < kk; ++hop) {
                auto h0 = clk::now();
                parallel_hop(threads, nq, [&](size_t a, size_t b) {
                    hop_scalar(g, cur, nxt, qbytes, latch, a, b);
                });
                auto h1 = clk::now();
                hop_us.push_back(us(h0, h1));
                cur.swap(nxt);
            }
            for (size_t q = 0; q < nq; ++q) {
                std::string vs; unsigned c = 0;
                for (unsigned v = 0; v < n; ++v)
                    if (cur[q * qbytes + v / 8] >> (v % 8) & 1) {
                        if (c) vs += ","; vs += std::to_string(v); ++c;
                    }
                char buf[64];
                snprintf(buf, sizeof(buf), "%zu %u %u ", idx[q], kk, c);
                outline[idx[q]] = std::string(buf) + (c ? vs : "-");
            }
        }
        total_q += nq;
    }

    for (const auto& s : outline) if (!s.empty()) printf("%s\n", s.c_str());

    // ---- timing ----------------------------------------------------------
    // Both formats are emitted on purpose: "[hop] n=..." is what part_agent
    // prints and what the weave drivers' LAT_RE parses, and "[hops] N hops
    // over M queries" is what part_query prints and what HOPS_RE parses. One
    // line each means this binary drops into either parser unchanged.
    if (!hop_us.empty()) {
        std::vector<double> s = hop_us;
        std::sort(s.begin(), s.end());
        double sum = 0; for (double v : s) sum += v;
        auto pct = [&](double p) { return s[(size_t) (p * (s.size() - 1) + 0.5)]; };
        fprintf(stderr,
                "[hop]           n=%zu  min %8.1f  p50 %8.1f  p90 %8.1f  "
                "max %8.1f  mean %8.1f us\n",
                s.size(), s.front(), pct(0.50), pct(0.90), s.back(), sum / s.size());
        fprintf(stderr,
                "[hops] %zu hops over %zu queries | per-hop us: min %.1f p50 %.1f "
                "p90 %.1f max %.1f mean %.1f\n",
                s.size(), total_q, s.front(), pct(0.50), pct(0.90), s.back(),
                sum / s.size());
        // No exchange and no PCIe: this arm's hop IS its compute, which is the
        // whole reason it is the floor the FPGA arms are measured against.
        fprintf(stderr, "[exchange_rtt]  n=0  (none: single device, no exchange)\n");
        fprintf(stderr, "[total] %.3f ms in hops\n", sum / 1000.0);
    }
    return 0;
}
