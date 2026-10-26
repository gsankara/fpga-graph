// batch_query.cpp -- XRT host for the PIPELINED BATCH graph engine.
//
// The repo's tools/neighbor_query.cpp drives the older single-query
// `graph_engine` kernel. The design-C bitstreams export `graph_engine_batch`,
// which takes a whole batch of queries at once (one query per clock sustained),
// so it needs its own host program.
//
// stdin/stdout are byte-identical to sim/tb_batch.cpp, which is what lets
// sim/compare_batch.py validate hardware with no changes: the same comparator
// that signed off csim signs off the card.
//
// Build:
//   g++ -std=c++17 -O2 batch_query.cpp -o batch_query \
//       -I$XILINX_XRT/include -L$XILINX_XRT/lib -lxrt_coreutil -pthread
//
// Run:
//   batch_query <xclbin> <n> <nw> <stages> [device_index]
//
// Protocol -- one query per stdin line:
//   <steps> <v1,v2,...>        ("-" or empty = empty set)
// One response line per query, emitted grouped by step count:
//   <input_line_index> <steps> <active_count> <v1,v2,...>
//
// Timing goes to stderr so it never perturbs the comparator.
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <chrono>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

#include "xrt/xrt_device.h"
#include "xrt/xrt_kernel.h"
#include "xrt/xrt_bo.h"

using clk = std::chrono::high_resolution_clock;
static double ms(clk::time_point a, clk::time_point b) {
    return std::chrono::duration<double, std::milli>(b - a).count();
}

int main(int argc, char** argv) {
    if (argc < 5) {
        fprintf(stderr, "usage: %s <xclbin> <n> <nw> <stages> [device_index]\n", argv[0]);
        return 1;
    }
    const char*    xclbin = argv[1];
    const unsigned n      = (unsigned) std::stoul(argv[2]);
    const unsigned nw     = (unsigned) std::stoul(argv[3]);
    const unsigned stages = (unsigned) std::stoul(argv[4]);
    const unsigned dev    = (argc > 5) ? (unsigned) std::stoul(argv[5]) : 0u;

    const size_t WORD_BYTES = 64;                   // 512-bit AXI word
    const size_t qbytes     = (size_t) nw * WORD_BYTES;

    // ---- read every query up front; group by k below ----
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

    // xrt::device(0) SEGFAULTS rather than throwing when no card is present,
    // so refuse explicitly instead of dying with an unexplained SIGSEGV.
    auto t_open = clk::now();
    xrt::device device;
    try {
        device = xrt::device(dev);
    } catch (const std::exception& e) {
        fprintf(stderr, "ERR cannot open device %u: %s\n", dev, e.what());
        return 2;
    }
    auto t_opened = clk::now();
    auto uuid   = device.load_xclbin(xclbin);
    auto t_load = clk::now();
    auto kernel = xrt::kernel(device, uuid, "graph_engine_batch",
                              xrt::kernel::cu_access_mode::exclusive);

    // One allocation sized for the largest batch, reused across k groups.
    size_t maxq = 0;
    for (unsigned kk = 0; kk <= stages + 8; ++kk) {
        size_t c = 0;
        for (size_t i = 0; i < ks.size(); ++i) if (ks[i] == kk) ++c;
        if (c > maxq) maxq = c;
    }
    auto bo_in  = xrt::bo(device, maxq * qbytes,            kernel.group_id(0));
    auto bo_out = xrt::bo(device, maxq * qbytes,            kernel.group_id(1));
    auto bo_cnt = xrt::bo(device, maxq * sizeof(uint32_t),  kernel.group_id(2));
    auto*  hin  = bo_in.map<uint8_t*>();
    auto*  hout = bo_out.map<uint8_t*>();
    auto*  hcnt = bo_cnt.map<uint32_t*>();

    double t_h2d = 0, t_exec = 0, t_d2h = 0;
    size_t total = 0;

    for (unsigned kk = 0; kk <= stages + 8; ++kk) {
        std::vector<size_t> idx;
        for (size_t i = 0; i < ks.size(); ++i) if (ks[i] == kk) idx.push_back(i);
        if (idx.empty()) continue;
        const unsigned nq = (unsigned) idx.size();

        std::memset(hin, 0, nq * qbytes);
        for (unsigned q = 0; q < nq; ++q)
            for (unsigned v : seeds[idx[q]])
                if (v < n) hin[q * qbytes + v / 8] |= (uint8_t) (1u << (v % 8));

        auto a = clk::now();
        bo_in.sync(XCL_BO_SYNC_BO_TO_DEVICE, nq * qbytes, 0);
        auto b = clk::now();
        auto run = kernel(bo_in, bo_out, bo_cnt, nq, kk);
        run.wait();
        auto c = clk::now();
        bo_out.sync(XCL_BO_SYNC_BO_FROM_DEVICE, nq * qbytes, 0);
        bo_cnt.sync(XCL_BO_SYNC_BO_FROM_DEVICE, nq * sizeof(uint32_t), 0);
        auto d = clk::now();
        t_h2d += ms(a, b); t_exec += ms(b, c); t_d2h += ms(c, d);
        total += nq;

        for (unsigned q = 0; q < nq; ++q) {
            std::string vs; unsigned cc = 0;
            for (unsigned v = 0; v < n; ++v)
                if (hout[q * qbytes + v / 8] & (1u << (v % 8))) {
                    if (cc) vs += ","; vs += std::to_string(v); ++cc;
                }
            // Trust the kernel's own counter over our re-derivation: a
            // disagreement is a real defect, so surface it rather than hide it.
            if (cc != hcnt[q])
                fprintf(stderr, "WARN q=%zu count_out=%u but %u bits set\n",
                        idx[q], hcnt[q], cc);
            printf("%zu %u %u %s\n", idx[q], kk, cc, cc ? vs.c_str() : "-");
        }
    }

    fprintf(stderr,
            "[timing] device_open %.1f ms | load_xclbin %.1f ms | "
            "H2D %.3f ms | exec %.3f ms | D2H %.3f ms | %zu queries\n",
            ms(t_open, t_opened), ms(t_opened, t_load),
            t_h2d, t_exec, t_d2h, total);
    return 0;
}
