// part_query.cpp -- XRT host for design P: a graph partitioned across several
// FPGAs IN ONE BOX. One card per partition, exchange through host memory.
//
// This is the intra-node arm (OCT's dual-U280 nodes, or a Coder box with two
// U55Cs). The inter-node arm, where the exchange crosses a network, is
// host/part_agent.cpp; both speak the same stdin/stdout protocol as
// host/batch_query.cpp, so one comparator signs off every path.
//
// Build:
//   g++ -std=c++17 -O2 part_query.cpp -o part_query
//       -I$XILINX_XRT/include -L$XILINX_XRT/lib
//       -lxrt_coreutil -luuid -pthread
//
//   -luuid is required: xrt::uuid (xrt_uuid.h, reached through
//   xrt_device.h) uses libuuid, and XRT does not pull it in for you.
//   Without it the link fails on uuid_clear with 'DSO missing from
//   command line'. Verified on XRT 2.19.194.
//
// Run:
//   part_query <n> <nw> <xclbin0> [<xclbin1> ...]        devices 0,1,... in order
//   part_query <n> <nw> --dev 0,2 a.xclbin b.xclbin      explicit device indices
//
// Protocol -- one query per stdin line, identical to batch_query.cpp:
//   <steps> <v1,v2,...>        ("-" or empty = empty set)
//   -> <input_line_index> <steps> <active_count> <v1,v2,...>
//
// Each hop is: broadcast the full state to every card, each card computes its
// own rows, OR the partials, feed back. One exchange per hop -- NOT k hops per
// card, which is the bug sim/verify_partition.py's BUG2 covers and which 50-89%
// of its cases would expose.
//
// Timing goes to stderr so it never perturbs the comparator.
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <algorithm>
#include <chrono>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

#include "xrt/xrt_device.h"
#include "xrt/xrt_kernel.h"
#include "xrt/xrt_bo.h"
// Counting devices portably is fiddlier than it looks, and it matters because
// xrt::device(i) SEGFAULTS rather than throwing on a missing index.
//
// xrt::system::enumerate_devices() is the supported API and libxrt_coreutil
// exports it, but its HEADER moves between XRT versions -- it is
// xrt/experimental/xrt_system.h in 2.19.194 (2025.1, the NRP Coder box) and
// has sat at other spellings elsewhere. All three are tried below.
//
// xclProbe() is NOT a usable fallback: 2.19 still declares it in
// xrt/deprecated/xrt.h but exports it from no library at all, so it links with
// "hidden symbol `xclProbe' isn't defined". Verified on the box, not assumed.
#if defined(__has_include)
#  if __has_include(<xrt/experimental/xrt_system.h>)
#    include "xrt/experimental/xrt_system.h"
#    define GW_HAVE_XRT_SYSTEM 1
#  elif __has_include(<xrt/xrt_system.h>)
#    include "xrt/xrt_system.h"
#    define GW_HAVE_XRT_SYSTEM 1
#  elif __has_include(<experimental/xrt_system.h>)
#    include "experimental/xrt_system.h"
#    define GW_HAVE_XRT_SYSTEM 1
#  endif
#endif
#ifndef GW_HAVE_XRT_SYSTEM
#  define GW_HAVE_XRT_SYSTEM 0
#endif

// Returns the device count, or -1 if this XRT build gives us no way to ask.
// A caller that gets -1 must be told to pass the count explicitly rather than
// be allowed to guess, because guessing high segfaults.
static int gw_device_count() {
#if GW_HAVE_XRT_SYSTEM
    try {
        return (int) xrt::system::enumerate_devices();
    } catch (const std::exception&) {
        return -1;
    }
#else
    return -1;
#endif
}

using clk = std::chrono::high_resolution_clock;
static double us(clk::time_point a, clk::time_point b) {
    return std::chrono::duration<double, std::micro>(b - a).count();
}

static const size_t WORD_BYTES = 64;          // 512-bit AXI word

struct Card {
    unsigned          index;
    std::string       path;
    xrt::device       device;
    xrt::uuid         uuid;
    xrt::kernel       kernel;
    xrt::bo           bo_in, bo_out, bo_cnt;
    uint8_t*          hin  = nullptr;
    uint8_t*          hout = nullptr;
    uint32_t*         hcnt = nullptr;
    double            t_h2d = 0, t_exec = 0, t_d2h = 0;
};

int main(int argc, char** argv) {
    std::vector<std::string> xclbins;
    std::vector<unsigned>    devs;
    unsigned n = 0, nw = 0;
    bool selfcheck = true;
    int  ndev_override = 0;      // 0 = probe; >0 = trust the operator

    // ---- arguments ----
    std::vector<std::string> pos;
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        if (a == "--dev" && i + 1 < argc) {
            std::stringstream ss(argv[++i]); std::string t;
            while (std::getline(ss, t, ',')) if (!t.empty()) devs.push_back((unsigned) atoi(t.c_str()));
        } else if (a == "--ndev" && i + 1 < argc) {
            ndev_override = atoi(argv[++i]);
        } else if (a == "--no-selfcheck") {
            selfcheck = false;
        } else {
            pos.push_back(a);
        }
    }
    if (pos.size() < 3) {
        fprintf(stderr,
            "usage: %s <n> <nw> <xclbin0> [<xclbin1> ...] "
            "[--dev i,j] [--ndev n] [--no-selfcheck]\n",
            argv[0]);
        return 1;
    }
    n  = (unsigned) std::stoul(pos[0]);
    nw = (unsigned) std::stoul(pos[1]);
    for (size_t i = 2; i < pos.size(); ++i) xclbins.push_back(pos[i]);
    const unsigned nparts = (unsigned) xclbins.size();
    if (devs.empty()) for (unsigned i = 0; i < nparts; ++i) devs.push_back(i);
    if (devs.size() != nparts) {
        fprintf(stderr, "ERR --dev lists %zu devices but %u xclbins given\n",
                devs.size(), nparts);
        return 1;
    }
    const size_t qbytes = (size_t) nw * WORD_BYTES;

    // ---- read every query up front ----
    std::vector<unsigned> ks;
    std::vector<std::vector<unsigned>> seeds;
    std::string line;
    while (std::getline(std::cin, line)) {
        if (line.empty()) continue;
        std::istringstream is(line);
        unsigned k; std::string spec;
        is >> k; is >> spec;
        std::vector<unsigned> sv;
        if (!spec.empty() && spec != "-") {
            std::stringstream ss(spec); std::string t;
            while (std::getline(ss, t, ',')) if (!t.empty()) sv.push_back((unsigned) atoi(t.c_str()));
        }
        ks.push_back(k); seeds.push_back(sv);
    }
    if (ks.empty()) { fprintf(stderr, "no queries on stdin\n"); return 1; }

    // ---- open the cards ----
    // xrt::device(i) SEGFAULTS rather than throwing when the index is absent,
    // so count first and refuse explicitly (fpga skill, trap 7).
    const int probed = gw_device_count();
    unsigned present = 0;
    if (ndev_override > 0) {
        present = (unsigned) ndev_override;
        fprintf(stderr, "[devices] %u taken from --ndev (probe %s), %u needed\n",
                present, probed < 0 ? "unavailable" : "overridden", nparts);
    } else if (probed < 0) {
        fprintf(stderr,
            "ERR this XRT build exposes no supported way to count devices, so\n"
            "    the count cannot be checked. Pass --ndev <n> with the number\n"
            "    `xbutil examine` reports. Opening a device index that is not\n"
            "    there segfaults rather than failing cleanly, so this refuses to\n"
            "    guess.\n");
        return 2;
    } else {
        present = (unsigned) probed;
        fprintf(stderr, "[devices] %u present, %u needed\n", present, nparts);
    }
    if (present < nparts) {
        fprintf(stderr,
            "ERR this partitioning needs %u FPGAs but XRT sees %u.\n"
            "    A partitioned run cannot be faked on one card: each bitstream\n"
            "    carries only its own rows, so a missing partition silently drops\n"
            "    every vertex it owned.\n", nparts, present);
        return 2;
    }
    for (unsigned k = 0; k < nparts; ++k)
        if (devs[k] >= present) {
            fprintf(stderr, "ERR device index %u requested but only %u present\n",
                    devs[k], present);
            return 2;
        }

    std::vector<Card> cards(nparts);
    size_t maxq = 0;
    {
        for (unsigned kk = 0; kk < ks.size(); ++kk) {
            size_t c = std::count(ks.begin(), ks.end(), ks[kk]);
            if (c > maxq) maxq = c;
        }
    }
    for (unsigned k = 0; k < nparts; ++k) {
        Card& c = cards[k];
        c.index = devs[k];
        c.path  = xclbins[k];
        auto t0 = clk::now();
        try { c.device = xrt::device(c.index); }
        catch (const std::exception& e) {
            fprintf(stderr, "ERR cannot open device %u: %s\n", c.index, e.what());
            return 2;
        }
        try { c.uuid = c.device.load_xclbin(c.path); }
        catch (const std::exception& e) {
            fprintf(stderr, "ERR device %u cannot load %s: %s\n",
                    c.index, c.path.c_str(), e.what());
            return 3;
        }
        try {
            c.kernel = xrt::kernel(c.device, c.uuid, "graph_engine_part",
                                   xrt::kernel::cu_access_mode::exclusive);
        } catch (const std::exception& e) {
            fprintf(stderr, "ERR device %u has no graph_engine_part kernel: %s\n"
                            "    (a design-C bitstream exports graph_engine_batch;"
                            " this host needs a partitioned one)\n",
                    c.index, e.what());
            return 3;
        }
        c.bo_in  = xrt::bo(c.device, maxq * qbytes,           c.kernel.group_id(0));
        c.bo_out = xrt::bo(c.device, maxq * qbytes,           c.kernel.group_id(1));
        c.bo_cnt = xrt::bo(c.device, maxq * sizeof(uint32_t), c.kernel.group_id(2));
        c.hin  = c.bo_in.map<uint8_t*>();
        c.hout = c.bo_out.map<uint8_t*>();
        c.hcnt = c.bo_cnt.map<uint32_t*>();
        fprintf(stderr, "[device %u] loaded %s (%.1f ms)\n",
                c.index, c.path.c_str(), us(t0, clk::now()) / 1000.0);
    }

    // ---- runtime pairing self-check ------------------------------------
    // Hop once from the all-ones state. Every card's partial must be non-empty,
    // the partials must be pairwise disjoint, and their OR must cover all N
    // bits. That catches a mis-paired set of bitstreams -- two copies of the
    // same partition, or two halves cut with different splits -- on hardware,
    // where the metadata is not available to check.
    if (selfcheck) {
        std::vector<std::vector<uint8_t>> part(nparts, std::vector<uint8_t>(qbytes, 0));
        for (unsigned k = 0; k < nparts; ++k) {
            Card& c = cards[k];
            std::memset(c.hin, 0, qbytes);
            for (unsigned v = 0; v < n; ++v) c.hin[v / 8] |= (uint8_t) (1u << (v % 8));
            c.bo_in.sync(XCL_BO_SYNC_BO_TO_DEVICE, qbytes, 0);
            c.kernel(c.bo_in, c.bo_out, c.bo_cnt, 1u, 1u).wait();
            c.bo_out.sync(XCL_BO_SYNC_BO_FROM_DEVICE, qbytes, 0);
            std::memcpy(part[k].data(), c.hout, qbytes);
        }
        std::vector<int> ownerof(n, -1);
        bool ok = true;
        for (unsigned k = 0; k < nparts; ++k) {
            unsigned bits = 0;
            for (unsigned v = 0; v < n; ++v)
                if (part[k][v / 8] & (1u << (v % 8))) {
                    ++bits;
                    if (ownerof[v] >= 0) {
                        fprintf(stderr, "ERR selfcheck: vertex %u claimed by both "
                                        "partition %d and %u\n", v, ownerof[v], k);
                        ok = false;
                    }
                    ownerof[v] = (int) k;
                }
            fprintf(stderr, "[selfcheck] partition %u owns %u vertices\n", k, bits);
            if (bits == 0) {
                fprintf(stderr, "ERR selfcheck: partition %u owns no vertices\n", k);
                ok = false;
            }
        }
        std::vector<unsigned> unowned;
        for (unsigned v = 0; v < n; ++v) if (ownerof[v] < 0) unowned.push_back(v);
        if (!unowned.empty()) {
            fprintf(stderr, "ERR selfcheck: %zu vertices owned by no partition, "
                            "first few:", unowned.size());
            for (size_t i = 0; i < unowned.size() && i < 10; ++i)
                fprintf(stderr, " %u", unowned[i]);
            fprintf(stderr, "\n    These bitstreams are not a complete cover of the "
                            "graph; results would be silently wrong.\n");
            ok = false;
        }
        if (!ok) return 4;
        fprintf(stderr, "[selfcheck] OK: %u partitions, disjoint, covering all %u vertices\n",
                nparts, n);
    }

    // ---- the orchestrated hops -----------------------------------------
    std::vector<double> hop_us;          // wall time of each hop, all cards
    std::vector<double> combine_us;
    double t_total_hops = 0;
    size_t total_q = 0;

    const unsigned kmax = *std::max_element(ks.begin(), ks.end());
    std::vector<std::string> outline(ks.size());

    for (unsigned kk = 0; kk <= kmax; ++kk) {
        std::vector<size_t> idx;
        for (size_t i = 0; i < ks.size(); ++i) if (ks[i] == kk) idx.push_back(i);
        if (idx.empty()) continue;
        const unsigned nq = (unsigned) idx.size();

        // current full state for each query in this group
        std::vector<uint8_t> state((size_t) nq * qbytes, 0);
        for (unsigned q = 0; q < nq; ++q)
            for (unsigned v : seeds[idx[q]])
                if (v < n) state[(size_t) q * qbytes + v / 8] |= (uint8_t) (1u << (v % 8));

        for (unsigned hop = 0; hop < kk; ++hop) {
            auto h0 = clk::now();
            // broadcast + compute on every card
            for (unsigned k = 0; k < nparts; ++k) {
                Card& c = cards[k];
                std::memcpy(c.hin, state.data(), (size_t) nq * qbytes);
                auto a = clk::now();
                c.bo_in.sync(XCL_BO_SYNC_BO_TO_DEVICE, (size_t) nq * qbytes, 0);
                auto b = clk::now();
                c.kernel(c.bo_in, c.bo_out, c.bo_cnt, nq, 1u).wait();
                auto cc = clk::now();
                c.bo_out.sync(XCL_BO_SYNC_BO_FROM_DEVICE, (size_t) nq * qbytes, 0);
                auto d = clk::now();
                c.t_h2d += us(a, b); c.t_exec += us(b, cc); c.t_d2h += us(cc, d);
            }
            // combine: OR the partials into the next state
            auto g0 = clk::now();
            std::memset(state.data(), 0, (size_t) nq * qbytes);
            for (unsigned k = 0; k < nparts; ++k) {
                const uint8_t* p = cards[k].hout;
                for (size_t b = 0; b < (size_t) nq * qbytes; ++b) state[b] |= p[b];
            }
            auto g1 = clk::now();
            combine_us.push_back(us(g0, g1));
            hop_us.push_back(us(h0, g1));
            t_total_hops += us(h0, g1);
        }

        for (unsigned q = 0; q < nq; ++q) {
            std::string vs; unsigned c = 0;
            for (unsigned v = 0; v < n; ++v)
                if (state[(size_t) q * qbytes + v / 8] & (1u << (v % 8))) {
                    if (c) vs += ",";
                    vs += std::to_string(v);
                    ++c;
                }
            char buf[64];
            snprintf(buf, sizeof(buf), "%zu %u %u ", idx[q], kk, c);
            outline[idx[q]] = std::string(buf) + (c ? vs : "-");
        }
        total_q += nq;
    }

    for (const auto& s : outline) if (!s.empty()) printf("%s\n", s.c_str());

    // ---- timing ---------------------------------------------------------
    // The headline number for a distributed-graph experiment is the per-hop
    // cost, because every hop is one exchange. Report the distribution, not
    // just a mean: on a shared testbed the tail is the interesting part.
    if (!hop_us.empty()) {
        std::vector<double> sorted = hop_us;
        std::sort(sorted.begin(), sorted.end());
        double sum = 0; for (double v : sorted) sum += v;
        auto pct = [&](double p) {
            size_t i = (size_t) (p * (sorted.size() - 1) + 0.5);
            return sorted[i];
        };
        double csum = 0; for (double v : combine_us) csum += v;
        fprintf(stderr,
            "[hops] %zu hops over %zu queries | per-hop us: min %.1f p50 %.1f "
            "p90 %.1f max %.1f mean %.1f | combine mean %.2f us\n",
            hop_us.size(), total_q, sorted.front(), pct(0.50), pct(0.90),
            sorted.back(), sum / sorted.size(), csum / combine_us.size());
        for (unsigned k = 0; k < nparts; ++k)
            fprintf(stderr, "[device %u] H2D %.1f us | exec %.1f us | D2H %.1f us (totals)\n",
                    cards[k].index, cards[k].t_h2d, cards[k].t_exec, cards[k].t_d2h);
        fprintf(stderr, "[total] %.3f ms in orchestrated hops\n", t_total_hops / 1000.0);
    }
    return 0;
}
