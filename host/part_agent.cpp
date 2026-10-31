// part_agent.cpp -- design P across a NETWORK: one FPGA per node, one
// partition each, and the per-hop exchange crossing a link instead of host
// memory.
//
// This is the inter-node arm. host/part_query.cpp is the same computation with
// both cards in one box; running the two against the same graph and the same
// bitstreams is the measurement: what does distributing a graph across sites
// cost per BFS hop?
//
// Roles
//   --serve <port>            worker: holds one partition, answers hop requests
//   --drive <host>:<port>     coordinator: holds one partition, reads queries
//                             from stdin, drives the hops, prints the answers
//
// The coordinator's stdin/stdout protocol is identical to batch_query.cpp and
// part_query.cpp, so sim/compare_part.py signs this off unchanged.
//
// Each hop is one round trip:
//   coordinator  send state -> compute its own rows -> recv peer partial -> OR
// The send happens before the local compute so the peer works while we do, and
// the hop costs about max(RTT, local) rather than their sum. Both are reported
// so the breakdown stays visible.
//
// Build:
//   g++ -std=c++17 -O2 part_agent.cpp -o part_agent
//       -I$XILINX_XRT/include -L$XILINX_XRT/lib
//       -lxrt_coreutil -luuid -pthread
//
//   -luuid is required: xrt::uuid (xrt_uuid.h, reached through
//   xrt_device.h) uses libuuid, and XRT does not pull it in for you.
//   Without it the link fails on uuid_clear with 'DSO missing from
//   command line'. Verified on XRT 2.19.194.
//
// Run (worker first):
//   part_agent --serve 5055        50 1 p1.xclbin
//   part_agent --drive node1:5055  50 1 p0.xclbin  < queries.txt
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

#include <arpa/inet.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>

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
static const size_t WORD_BYTES = 64;
static const uint32_t MAGIC = 0x50415254;         // 'PART'
static int g_ndev_override = 0;   // 0 = probe; >0 = trust the operator

// ---------- framed, length-prefixed exchange ----------
struct Hdr { uint32_t magic, nq, nbytes, hop; };

static bool send_all(int fd, const void* p, size_t n) {
    const char* c = (const char*) p;
    while (n) {
        ssize_t w = ::send(fd, c, n, 0);
        if (w <= 0) return false;
        c += w; n -= (size_t) w;
    }
    return true;
}
static bool recv_all(int fd, void* p, size_t n) {
    char* c = (char*) p;
    while (n) {
        ssize_t r = ::recv(fd, c, n, 0);
        if (r <= 0) return false;
        c += r; n -= (size_t) r;
    }
    return true;
}
static void nodelay(int fd) {
    // Without this Nagle batches the 64-byte exchange and adds tens of ms per
    // hop -- it would swamp the very quantity being measured.
    int one = 1;
    ::setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
}

// ---------- one card, one partition ----------
struct Card {
    xrt::device device; xrt::uuid uuid; xrt::kernel kernel;
    xrt::bo bo_in, bo_out, bo_cnt;
    uint8_t* hin = nullptr; uint8_t* hout = nullptr; uint32_t* hcnt = nullptr;
    double t_h2d = 0, t_exec = 0, t_d2h = 0;
    size_t qbytes = 0;

    bool open(unsigned idx, const std::string& xclbin, size_t maxq, size_t qb) {
        qbytes = qb;
        // xrt::device(i) SEGFAULTS rather than throwing on a missing index,
        // so the count is checked first -- or taken from --ndev when this XRT
        // build gives no supported way to ask.
        const int probed = gw_device_count();
        unsigned present = 0;
        if (g_ndev_override > 0) {
            present = (unsigned) g_ndev_override;
        } else if (probed < 0) {
            fprintf(stderr,
                "ERR this XRT build exposes no supported way to count devices.\n"
                "    Pass --ndev <n> with the number `xbutil examine` reports;\n"
                "    opening a device index that is not there segfaults rather\n"
                "    than failing cleanly, so this refuses to guess.\n");
            return false;
        } else {
            present = (unsigned) probed;
        }
        if (idx >= present) {
            fprintf(stderr, "ERR device %u requested, XRT sees %u\n", idx, present);
            return false;
        }
        try { device = xrt::device(idx); uuid = device.load_xclbin(xclbin); }
        catch (const std::exception& e) {
            fprintf(stderr, "ERR device %u load %s: %s\n", idx, xclbin.c_str(), e.what());
            return false;
        }
        try {
            kernel = xrt::kernel(device, uuid, "graph_engine_part",
                                 xrt::kernel::cu_access_mode::exclusive);
        } catch (const std::exception& e) {
            fprintf(stderr, "ERR no graph_engine_part kernel in %s: %s\n",
                    xclbin.c_str(), e.what());
            return false;
        }
        bo_in  = xrt::bo(device, maxq * qbytes,           kernel.group_id(0));
        bo_out = xrt::bo(device, maxq * qbytes,           kernel.group_id(1));
        bo_cnt = xrt::bo(device, maxq * sizeof(uint32_t), kernel.group_id(2));
        hin  = bo_in.map<uint8_t*>();
        hout = bo_out.map<uint8_t*>();
        hcnt = bo_cnt.map<uint32_t*>();
        fprintf(stderr, "[card] device %u loaded %s\n", idx, xclbin.c_str());
        return true;
    }

    // One hop over this partition's rows for a whole batch.
    void hop(const uint8_t* state, unsigned nq, unsigned steps) {
        std::memcpy(hin, state, (size_t) nq * qbytes);
        auto a = clk::now();
        bo_in.sync(XCL_BO_SYNC_BO_TO_DEVICE, (size_t) nq * qbytes, 0);
        auto b = clk::now();
        kernel(bo_in, bo_out, bo_cnt, nq, steps).wait();
        auto c = clk::now();
        bo_out.sync(XCL_BO_SYNC_BO_FROM_DEVICE, (size_t) nq * qbytes, 0);
        auto d = clk::now();
        t_h2d += us(a, b); t_exec += us(b, c); t_d2h += us(c, d);
    }
};

static void usage(const char* p) {
    fprintf(stderr,
        "usage: %s --serve <port>        <n> <nw> <xclbin> [--dev i] [--ndev n]\n"
        "       %s --drive <host>:<port> <n> <nw> <xclbin> [--dev i] [--ndev n]\n", p, p);
}

int main(int argc, char** argv) {
    std::string mode, endpoint;
    std::vector<std::string> pos;
    unsigned devidx = 0;
    size_t maxq_hint = 4096;
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        if ((a == "--serve" || a == "--drive") && i + 1 < argc) {
            mode = a; endpoint = argv[++i];
        } else if (a == "--dev" && i + 1 < argc) {
            devidx = (unsigned) atoi(argv[++i]);
        } else if (a == "--ndev" && i + 1 < argc) {
            g_ndev_override = atoi(argv[++i]);
        } else if (a == "--maxq" && i + 1 < argc) {
            maxq_hint = (size_t) atol(argv[++i]);
        } else {
            pos.push_back(a);
        }
    }
    if (mode.empty() || pos.size() < 3) { usage(argv[0]); return 1; }
    const unsigned n  = (unsigned) std::stoul(pos[0]);
    const unsigned nw = (unsigned) std::stoul(pos[1]);
    const std::string xclbin = pos[2];
    const size_t qbytes = (size_t) nw * WORD_BYTES;

    // =====================================================================
    // WORKER
    // =====================================================================
    if (mode == "--serve") {
        const int port = atoi(endpoint.c_str());
        Card card;
        if (!card.open(devidx, xclbin, maxq_hint, qbytes)) return 2;

        int ls = ::socket(AF_INET, SOCK_STREAM, 0);
        if (ls < 0) { perror("socket"); return 2; }
        int one = 1;
        ::setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
        sockaddr_in sa{};
        sa.sin_family = AF_INET; sa.sin_addr.s_addr = INADDR_ANY;
        sa.sin_port = htons((uint16_t) port);
        if (::bind(ls, (sockaddr*) &sa, sizeof(sa)) < 0) { perror("bind"); return 2; }
        if (::listen(ls, 4) < 0) { perror("listen"); return 2; }
        fprintf(stderr, "[serve] listening on %d, partition from %s\n", port, xclbin.c_str());

        for (;;) {
            sockaddr_in ca{}; socklen_t cl = sizeof(ca);
            int fd = ::accept(ls, (sockaddr*) &ca, &cl);
            if (fd < 0) { perror("accept"); continue; }
            nodelay(fd);
            char ip[INET_ADDRSTRLEN] = {0};
            inet_ntop(AF_INET, &ca.sin_addr, ip, sizeof(ip));
            fprintf(stderr, "[serve] coordinator %s connected\n", ip);

            std::vector<uint8_t> buf;
            size_t hops = 0;
            for (;;) {
                Hdr h{};
                if (!recv_all(fd, &h, sizeof(h))) break;
                if (h.magic != MAGIC) {
                    fprintf(stderr, "[serve] bad magic 0x%x -- wrong protocol\n", h.magic);
                    break;
                }
                if (h.nbytes != qbytes) {
                    fprintf(stderr, "[serve] peer says %u bytes/query, this bitstream "
                                    "wants %zu -- mismatched graph or nw\n",
                            h.nbytes, qbytes);
                    break;
                }
                const size_t total = (size_t) h.nq * qbytes;
                if (h.nq > maxq_hint) {
                    fprintf(stderr, "[serve] batch %u exceeds --maxq %zu\n", h.nq, maxq_hint);
                    break;
                }
                buf.resize(total);
                if (!recv_all(fd, buf.data(), total)) break;
                card.hop(buf.data(), h.nq, 1u);
                if (!send_all(fd, card.hout, total)) break;
                ++hops;
            }
            fprintf(stderr, "[serve] coordinator gone after %zu hops | "
                            "H2D %.1f us exec %.1f us D2H %.1f us (totals)\n",
                    hops, card.t_h2d, card.t_exec, card.t_d2h);
            ::close(fd);
        }
    }

    // =====================================================================
    // COORDINATOR
    // =====================================================================
    std::string host = endpoint;
    int port = 5055;
    auto colon = endpoint.rfind(':');
    if (colon != std::string::npos) {
        host = endpoint.substr(0, colon);
        port = atoi(endpoint.substr(colon + 1).c_str());
    }

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

    size_t maxq = 0;
    for (size_t i = 0; i < ks.size(); ++i)
        maxq = std::max(maxq, (size_t) std::count(ks.begin(), ks.end(), ks[i]));
    maxq = std::max(maxq, (size_t) 1);

    Card card;
    if (!card.open(devidx, xclbin, maxq, qbytes)) return 2;

    // connect
    addrinfo hints{}, *res = nullptr;
    hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM;
    std::string ports = std::to_string(port);
    if (::getaddrinfo(host.c_str(), ports.c_str(), &hints, &res) != 0 || !res) {
        fprintf(stderr, "ERR cannot resolve %s\n", host.c_str()); return 2;
    }
    int fd = -1;
    for (addrinfo* p = res; p; p = p->ai_next) {
        fd = ::socket(p->ai_family, p->ai_socktype, p->ai_protocol);
        if (fd < 0) continue;
        if (::connect(fd, p->ai_addr, p->ai_addrlen) == 0) break;
        ::close(fd); fd = -1;
    }
    ::freeaddrinfo(res);
    if (fd < 0) {
        fprintf(stderr, "ERR cannot connect to %s:%d -- is the worker's "
                        "part_agent --serve running, and the port reachable?\n",
                host.c_str(), port);
        return 2;
    }
    nodelay(fd);
    fprintf(stderr, "[drive] connected to %s:%d\n", host.c_str(), port);

    std::vector<double> hop_us, rtt_us, local_us;
    std::vector<std::string> outline(ks.size());
    size_t total_q = 0;
    const unsigned kmax = *std::max_element(ks.begin(), ks.end());

    for (unsigned kk = 0; kk <= kmax; ++kk) {
        std::vector<size_t> idx;
        for (size_t i = 0; i < ks.size(); ++i) if (ks[i] == kk) idx.push_back(i);
        if (idx.empty()) continue;
        const unsigned nq = (unsigned) idx.size();

        std::vector<uint8_t> state((size_t) nq * qbytes, 0);
        for (unsigned q = 0; q < nq; ++q)
            for (unsigned v : seeds[idx[q]])
                if (v < n) state[(size_t) q * qbytes + v / 8] |= (uint8_t) (1u << (v % 8));
        std::vector<uint8_t> peer((size_t) nq * qbytes);

        for (unsigned hop = 0; hop < kk; ++hop) {
            auto h0 = clk::now();
            Hdr h{MAGIC, nq, (uint32_t) qbytes, hop};
            if (!send_all(fd, &h, sizeof(h)) ||
                !send_all(fd, state.data(), state.size())) {
                fprintf(stderr, "ERR peer dropped mid-hop %u\n", hop); return 5;
            }
            auto sent = clk::now();
            card.hop(state.data(), nq, 1u);          // our rows, while they do theirs
            auto locald = clk::now();
            if (!recv_all(fd, peer.data(), peer.size())) {
                fprintf(stderr, "ERR peer dropped before replying to hop %u\n", hop);
                return 5;
            }
            auto got = clk::now();
            for (size_t b = 0; b < state.size(); ++b)
                state[b] = card.hout[b] | peer[b];
            auto h1 = clk::now();
            rtt_us.push_back(us(sent, got));
            local_us.push_back(us(sent, locald));
            hop_us.push_back(us(h0, h1));
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
    ::close(fd);

    auto stat = [](std::vector<double>& v, const char* label) {
        if (v.empty()) return;
        std::sort(v.begin(), v.end());
        double sum = 0; for (double x : v) sum += x;
        auto pc = [&](double p) { return v[(size_t)(p * (v.size() - 1) + 0.5)]; };
        fprintf(stderr, "[%s] n=%zu min %.1f p50 %.1f p90 %.1f max %.1f mean %.1f us\n",
                label, v.size(), v.front(), pc(0.50), pc(0.90), v.back(), sum / v.size());
    };
    fprintf(stderr, "[queries] %zu\n", total_q);
    stat(hop_us,   "hop");            // end to end, what a BFS level costs
    stat(rtt_us,   "exchange_rtt");   // the wide-area component
    stat(local_us, "local_fpga");     // our own card, overlapped with the RTT
    fprintf(stderr, "[card] H2D %.1f us | exec %.1f us | D2H %.1f us (totals)\n",
            card.t_h2d, card.t_exec, card.t_d2h);
    return 0;
}
