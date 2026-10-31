// csim harness for a PARTITIONED kernel (design P). One partition, one hop.
//
// Protocol -- deliberately the same line shape as tb_batch.cpp, but the input
// is the FULL graph state rather than a seed set, and the output is this
// partition's PARTIAL next state (bits outside the partition are always clear):
//
//   stdin   <steps> <v1,v2,...>       steps 0 = passthrough, >=1 = one hop
//   stdout  <idx> <steps> <count> <v1,v2,...>
//
// Multi-hop is NOT done here: one invocation is one hop by construction, and
// the per-hop exchange is the orchestrator's job (sim/orchestrate_part.py on
// the software side, host/part_query.cpp and host/part_agent.cpp on hardware).
// The three speak this same protocol, so one comparator signs off all of them.
#include "graph_wire.hpp"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <sstream>
#include <iostream>
#include <vector>

extern "C" void graph_engine_part(const gw_word_t*, gw_word_t*, unsigned*, unsigned, unsigned);

int main() {
    std::vector<unsigned> ks;
    std::vector<std::vector<unsigned>> states;
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
        ks.push_back(k); states.push_back(sv);
    }
    // num_steps is a scalar for the whole batch, so batch per distinct value.
    for (unsigned kk = 0; kk <= 1; ++kk) {
        std::vector<size_t> idx;
        for (size_t i = 0; i < ks.size(); ++i) {
            unsigned eff = ks[i] > 1 ? 1u : ks[i];        // kernel clamps to 1
            if (eff == kk) idx.push_back(i);
        }
        if (idx.empty()) continue;
        unsigned nq = (unsigned) idx.size();
        std::vector<gw_word_t> in(nq * GW_NW), out(nq * GW_NW);
        std::vector<unsigned> cnt(nq);
        for (unsigned q = 0; q < nq; ++q)
            for (unsigned v : states[idx[q]])
                if (v < GW_N) in[q * GW_NW + v / GW_WORD_BITS][v % GW_WORD_BITS] = 1;
        graph_engine_part(in.data(), out.data(), cnt.data(), nq, kk);
        for (unsigned q = 0; q < nq; ++q) {
            std::string vs; unsigned c = 0;
            for (unsigned v = 0; v < GW_N; ++v)
                if (out[q * GW_NW + v / GW_WORD_BITS][v % GW_WORD_BITS]) {
                    if (c) vs += ","; vs += std::to_string(v); ++c;
                }
            if (c != cnt[q])
                fprintf(stderr, "WARN q=%zu count_out=%u but %u bits set\n", idx[q], cnt[q], c);
            printf("%zu %u %u %s\n", idx[q], kk, c, c ? vs.c_str() : "-");
        }
    }
    return 0;
}
