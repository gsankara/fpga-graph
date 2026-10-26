// csim harness for the pipelined BATCH kernel. Reads all queries from stdin,
// submits them as one batch, prints one result line each: <k> <count> <v,...>
#include "graph_wire.hpp"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <sstream>
#include <iostream>
#include <vector>

extern "C" void graph_engine_batch(const gw_word_t*, gw_word_t*, unsigned*, unsigned, unsigned);

int main() {
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
    // One batch per distinct k (num_steps is a scalar for the whole batch).
    for (unsigned kk = 0; kk <= GW_STAGES + 4; ++kk) {
        std::vector<size_t> idx;
        for (size_t i = 0; i < ks.size(); ++i) if (ks[i] == kk) idx.push_back(i);
        if (idx.empty()) continue;
        unsigned nq = (unsigned) idx.size();
        std::vector<gw_word_t> in(nq * GW_NW), out(nq * GW_NW);
        std::vector<unsigned> cnt(nq);
        for (unsigned q = 0; q < nq; ++q)
            for (unsigned v : seeds[idx[q]])
                in[q * GW_NW + v / GW_WORD_BITS][v % GW_WORD_BITS] = 1;
        graph_engine_batch(in.data(), out.data(), cnt.data(), nq, kk);
        for (unsigned q = 0; q < nq; ++q) {
            std::string vs; unsigned c = 0;
            for (unsigned v = 0; v < GW_N; ++v)
                if (out[q * GW_NW + v / GW_WORD_BITS][v % GW_WORD_BITS]) {
                    if (c) vs += ","; vs += std::to_string(v); ++c;
                }
            printf("%zu %u %u %s\n", idx[q], kk, c, c ? vs.c_str() : "-");
        }
    }
    return 0;
}
