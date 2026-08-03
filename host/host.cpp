// host.cpp -- XRT native-API host for the baked graph-engine kernel.
//
// Loads an xclbin, seeds the initial active node(s), runs the wavefront for
// N steps on the FPGA, reads back the final state + per-step active-count
// trace, and self-checks against the golden expected.txt emitted by gen_hls.py.
//
// Build (on a machine with XRT + the target platform):
//   g++ -std=c++17 -O2 host/host.cpp -o host_graph \
//       -I$XILINX_XRT/include -L$XILINX_XRT/lib -lxrt_coreutil -pthread
//
// Run:
//   ./host_graph build/<graph>/graph_engine.xclbin build/<graph>/expected.txt
//
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "xrt/xrt_device.h"
#include "xrt/xrt_kernel.h"
#include "xrt/xrt_bo.h"

struct Expected {
    std::string name;
    unsigned n = 0, nw = 0, steps = 0, final_active = 0;
    std::vector<unsigned> seed, trace, nodes;
};

static std::vector<unsigned> ints(std::istringstream& is) {
    std::vector<unsigned> v; unsigned x;
    while (is >> x) v.push_back(x);
    return v;
}

static Expected load_expected(const char* path) {
    Expected e;
    std::ifstream f(path);
    if (!f) { fprintf(stderr, "cannot open %s\n", path); exit(2); }
    std::string line;
    while (std::getline(f, line)) {
        std::istringstream is(line);
        std::string key; is >> key;
        if      (key == "NAME")  is >> e.name;
        else if (key == "N")     is >> e.n;
        else if (key == "NW")    is >> e.nw;
        else if (key == "STEPS") is >> e.steps;
        else if (key == "FINAL") is >> e.final_active;
        else if (key == "SEED")  e.seed  = ints(is);
        else if (key == "TRACE") e.trace = ints(is);
        else if (key == "NODES") e.nodes = ints(is);
    }
    return e;
}

int main(int argc, char** argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <xclbin> <expected.txt> [device_index]\n", argv[0]);
        return 1;
    }
    const char* xclbin_path = argv[1];
    Expected e = load_expected(argv[2]);
    unsigned dev_index = (argc > 3) ? std::stoul(argv[3]) : 0;

    const size_t WORD_BYTES = 64;                 // 512-bit AXI word
    const size_t io_bytes   = (size_t) e.nw * WORD_BYTES;
    const size_t trace_len  = 4096;               // GW_MAXSTEPS
    const size_t trace_bytes = trace_len * sizeof(uint32_t);

    printf("[host] device=%u xclbin=%s graph=%s N=%u NW=%u steps=%u\n",
           dev_index, xclbin_path, e.name.c_str(), e.n, e.nw, e.steps);

    auto device = xrt::device(dev_index);
    auto uuid   = device.load_xclbin(xclbin_path);
    auto kernel = xrt::kernel(device, uuid, "graph_engine",
                              xrt::kernel::cu_access_mode::exclusive);

    auto seed_bo  = xrt::bo(device, io_bytes,    kernel.group_id(0));
    auto state_bo = xrt::bo(device, io_bytes,    kernel.group_id(1));
    auto trace_bo = xrt::bo(device, trace_bytes, kernel.group_id(3));

    auto* seed_map  = seed_bo.map<uint8_t*>();
    auto* state_map = state_bo.map<uint8_t*>();
    auto* trace_map = trace_bo.map<uint32_t*>();
    std::memset(seed_map, 0, io_bytes);
    std::memset(state_map, 0, io_bytes);
    std::memset(trace_map, 0, trace_bytes);

    for (unsigned v : e.seed) seed_map[v / 8] |= (uint8_t)(1u << (v % 8));

    seed_bo.sync(XCL_BO_SYNC_BO_TO_DEVICE);
    trace_bo.sync(XCL_BO_SYNC_BO_TO_DEVICE);

    auto run = kernel(seed_bo, state_bo, e.steps, trace_bo);
    run.wait();

    state_bo.sync(XCL_BO_SYNC_BO_FROM_DEVICE);
    trace_bo.sync(XCL_BO_SYNC_BO_FROM_DEVICE);

    // reconstruct golden final-state bitmap
    std::vector<uint8_t> gold(e.n, 0);
    for (unsigned v : e.nodes) gold[v] = 1;

    int errors = 0, active = 0;
    for (unsigned v = 0; v < e.n; ++v) {
        int hw = (state_map[v / 8] >> (v % 8)) & 1;
        active += hw;
        if (hw != gold[v]) {
            if (errors < 20) printf("  MISMATCH node %u: hw=%d golden=%d\n", v, hw, gold[v]);
            ++errors;
        }
    }

    printf("[host] hw trace (active/step):");
    for (unsigned t = 0; t < e.steps; ++t) printf(" %u", trace_map[t]);
    printf("\n[host] expected trace         :");
    for (unsigned x : e.trace) printf(" %u", x);
    printf("\n[host] active_final hw=%d golden=%u  errors=%d\n",
           active, e.final_active, errors);

    int trace_err = 0;
    for (unsigned t = 0; t < e.steps && t < e.trace.size(); ++t)
        if (trace_map[t] != e.trace[t]) ++trace_err;

    if (errors == 0 && trace_err == 0) { printf("PASS\n"); return 0; }
    printf("FAIL (state_errors=%d trace_errors=%d)\n", errors, trace_err);
    return 1;
}
