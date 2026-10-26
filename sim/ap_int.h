// Minimal ap_uint<> shim -- ONLY for host-side csim of the generated kernel.
// Covers exactly what gen_hls_onecycle.py emits: zero-init, bit read/write via
// operator[], cross-width bit assignment, and ap_uint<1> used as a boolean
// under | and +. Not a general ap_int implementation.
#pragma once
#include <cstdint>
#include <cstring>

template <int W> struct ap_uint {
    static const int NWORDS = (W + 63) / 64;
    uint64_t w[NWORDS];

    ap_uint() { std::memset(w, 0, sizeof(w)); }
    ap_uint(unsigned long long v) { std::memset(w, 0, sizeof(w)); w[0] = (uint64_t) v; if (W < 64) w[0] &= ((1ULL << W) - 1); }
    ap_uint(unsigned v)   { std::memset(w, 0, sizeof(w)); w[0] = v; if (W < 64) w[0] &= ((1ULL << W) - 1); }
    ap_uint(int v)        { std::memset(w, 0, sizeof(w)); w[0] = (uint64_t)(unsigned) v; if (W < 64) w[0] &= ((1ULL << W) - 1); }

    ap_uint& operator=(unsigned long long v) { std::memset(w, 0, sizeof(w)); w[0] = (uint64_t) v; if (W < 64) w[0] &= ((1ULL << W) - 1); return *this; }

    struct BitRef {
        ap_uint* p; int i;
        operator int() const { return (int) ((p->w[i >> 6] >> (i & 63)) & 1ULL); }
        void set(int v) {
            if (v) p->w[i >> 6] |=  (1ULL << (i & 63));
            else   p->w[i >> 6] &= ~(1ULL << (i & 63));
        }
        BitRef& operator=(int v)            { set(v);            return *this; }
        BitRef& operator=(unsigned v)       { set((int) v);      return *this; }
        BitRef& operator=(const BitRef& o)  { set((int) o);      return *this; }
        template <int V> BitRef& operator=(const ap_uint<V>& o) { set((int)(unsigned) o); return *this; }
        template <int V> BitRef& operator=(const typename ap_uint<V>::BitRef& o) { set((int) o); return *this; }
    };

    BitRef operator[](int i) { BitRef b; b.p = this; b.i = i; return b; }
    int    operator[](int i) const { return (int) ((w[i >> 6] >> (i & 63)) & 1ULL); }

    // ap_uint<1> is used as a plain boolean in the generated OR-trees.
    operator unsigned() const { return (unsigned) w[0]; }

    // Assign from a bit proxy of any width (s[idx] = word[b]).
    template <int V> ap_uint(const typename ap_uint<V>::BitRef& b) { std::memset(w, 0, sizeof(w)); w[0] = (uint64_t)(int) b; }
    template <int V> ap_uint& operator=(const typename ap_uint<V>::BitRef& b) { std::memset(w, 0, sizeof(w)); w[0] = (uint64_t)(int) b; return *this; }

    // ---- word-level ops, used by the BRAM-adjacency kernel ----
    // (gen_hls_bram.py ANDs a constant adjacency row with the frontier and
    //  OR-reduces it, so csim needs &, |=, and a test against zero.)
    ap_uint operator&(const ap_uint& o) const {
        ap_uint r; for (int i = 0; i < NWORDS; ++i) r.w[i] = w[i] & o.w[i]; return r;
    }
    ap_uint operator|(const ap_uint& o) const {
        ap_uint r; for (int i = 0; i < NWORDS; ++i) r.w[i] = w[i] | o.w[i]; return r;
    }
    ap_uint& operator|=(const ap_uint& o) {
        for (int i = 0; i < NWORDS; ++i) w[i] |= o.w[i]; return *this;
    }
    ap_uint& operator&=(const ap_uint& o) {
        for (int i = 0; i < NWORDS; ++i) w[i] &= o.w[i]; return *this;
    }

    // ---- shifts + cross-width conversion ----
    // The BRAM kernel assembles each 64-bit lane in a shift register
    // (constant shifts only), so csim needs these.
    void gw_mask() { int r = W & 63; if (r) w[NWORDS - 1] &= ((1ULL << r) - 1); }
    template <int V> ap_uint(const ap_uint<V>& o) {
        std::memset(w, 0, sizeof(w));
        int n = (V + 63) / 64; if (n > NWORDS) n = NWORDS;
        for (int i = 0; i < n; ++i) w[i] = o.w[i];
        gw_mask();
    }
    ap_uint operator<<(int s) const {
        ap_uint r; if (s < 0 || s >= W) return r;
        int ws = s >> 6, bs = s & 63;
        for (int i = NWORDS - 1; i >= 0; --i) {
            uint64_t v = 0;
            if (i - ws >= 0) {
                v = w[i - ws] << bs;
                if (bs && i - ws - 1 >= 0) v |= w[i - ws - 1] >> (64 - bs);
            }
            r.w[i] = v;
        }
        r.gw_mask(); return r;
    }
    ap_uint operator>>(int s) const {
        ap_uint r; if (s < 0 || s >= W) return r;
        int ws = s >> 6, bs = s & 63;
        for (int i = 0; i < NWORDS; ++i) {
            uint64_t v = 0;
            if (i + ws < NWORDS) {
                v = w[i + ws] >> bs;
                if (bs && i + ws + 1 < NWORDS) v |= w[i + ws + 1] << (64 - bs);
            }
            r.w[i] = v;
        }
        return r;
    }

    bool any() const { for (int i = 0; i < NWORDS; ++i) if (w[i]) return true; return false; }
    bool operator!=(int v) const { return v ? !(*this == v) : any(); }
    bool operator==(int v) const {
        if (v != 0) { if (w[0] != (uint64_t) v) return false; }
        else if (w[0] != 0) return false;
        for (int i = 1; i < NWORDS; ++i) if (w[i]) return false;
        return true;
    }
};
