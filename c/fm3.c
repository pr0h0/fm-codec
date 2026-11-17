/* fm3 (experimental): fm2 + cache-friendly checksummed nibble buckets, match model, word model,
 * mixer selection by match state, second APM. Feature bits (env FEAT, stored in the header):
 *   bytes: 1 match model   2 word contexts   4 mixer1 selected by match length   8 APM2 (order-2)
 *          16 extra orders (5, 7)   32 second mixer + APM1 (as fm2 profile 4)
 *   image: fm2 profile-4 model on nibble buckets (feature bits ignored except 32 = mixer2+APM)
 * env BB = log2(buckets per context table) (default 18 -> 16 MB per table).
 *   fm3 enc bytes IN OUT | fm3 enc image WIDTH IN OUT | fm3 dec IN OUT
 * Header (28 bytes): "FM3\x01" mode u8, bb u8, limit u8, LR u8 | feat u32 | width u32 | L u64 | pad u32
 * feat bits also record: 64 E8E9 applied, 8192 32-bit mixer (MIXV), 16384 full-size tables (no SMALLT)
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

#define MAXIN 36
#define NPRED 9
#define HDR 28

static int SQ_T[33] = {1, 2, 3, 6, 10, 16, 27, 45, 73, 120, 194, 310, 488, 747, 1101, 1546, 2047,
                       2549, 2994, 3348, 3607, 3785, 3901, 3975, 4022, 4050, 4068, 4079, 4085, 4089, 4092, 4093, 4094};
static int STRETCH[4096], RECIP[256], LR = 4, LR0 = 0, LRCUR = 4;
static int MIXV = 1;
static int OPT_HUGE = 1, OPT_SMALLT = 1, A2BITS = 18;
static int squash(int d) {
    if (d > 2047) return 4095;
    if (d < -2047) return 1;
    int w = d & 127, i = (d >> 7) + 16;
    return (SQ_T[i] * (128 - w) + SQ_T[i + 1] * w + 64) >> 7;
}
static void init_tables(void) {
    int pi = 0;
    for (int x = -2047; x <= 2047; x++) { int v = squash(x); for (int j = pi; j <= v; j++) STRETCH[j] = x; pi = v + 1; }
    for (int j = pi; j < 4096; j++) STRETCH[j] = 2047;
    for (int n = 0; n < 256; n++) RECIP[n] = 65536 / (2 * n + 3);
}
static uint32_t H(uint32_t k, uint32_t a, uint32_t b, uint32_t c) {
    uint32_t h = (k + 1) * 0x9E3779B1u;
    h = (h ^ a) * 0x85EBCA6Bu; h ^= h >> 13;
    h = (h ^ b) * 0xC2B2AE35u; h ^= h >> 16;
    h = (h ^ c) * 0x85EBCA6Bu; h ^= h >> 15;
    return h;
}
static inline uint32_t nib_hash(uint32_t ctx, uint32_t c0) {
    uint32_t x = ctx + c0 * 0x9E3779B1u;
    x ^= x >> 15; x *= 0x2C1B3C6Du; x ^= x >> 12; x *= 0x297A2D39u; x ^= x >> 15;
    return x;
}
static inline int clamp255(int v) { return v < 0 ? 0 : (v > 255 ? 255 : v); }
static inline int clampp(int p) { return p < 1 ? 1 : (p > 4095 ? 4095 : p); }
static inline int iabs(int v) { return v < 0 ? -v : v; }
static inline int bitlen(int v) { return v > 0 ? 32 - __builtin_clz(v) : 0; }
static inline uint32_t qe(int e, int lim) { return (uint32_t)((e < -lim ? -lim : (e > lim ? lim : e)) + 64); }
static inline uint32_t qg(int d) {
    int a = iabs(d), q = a == 0 ? 0 : a < 3 ? 1 : a < 7 ? 2 : a < 21 ? 3 : 4;
    return (uint32_t)((d < 0 ? -q : q) + 8);
}

static void *big_alloc(size_t n) {
    void *p = NULL;
    if (OPT_HUGE && n >= (1u << 21)) {
        if (posix_memalign(&p, 1u << 21, n)) p = NULL;
        else madvise(p, n, MADV_HUGEPAGE);
    }
    return p ? p : malloc(n);
}
/* checksummed 2-way nibble bucket: 16 x u32 = 64 bytes; [0] = check, [1..15] = p16 | n<<16 */
static inline uint32_t *find_bucket(uint32_t *T, int bb, uint32_t h) {
    uint32_t chk = (h * 0x2545F491u) >> 16;
    if (!chk) chk = 1;
    uint32_t i0 = h >> (32 - bb);
    uint32_t *b0 = T + ((size_t)i0 << 4), *b1 = T + ((size_t)(i0 ^ 1) << 4);
    if ((b0[0] & 0xFFFF) == chk) return b0;
    if ((b1[0] & 0xFFFF) == chk) return b1;
    uint32_t *v = ((b0[1] >> 16) & 255) <= ((b1[1] >> 16) & 255) ? b0 : b1;
    v[0] = chk;
    for (int j = 1; j < 16; j++) v[j] = 32768 | 1u << 24;
    return v;
}

typedef struct { uint32_t x1, x2, x; uint8_t *buf; int64_t len, pos, cap; int dec; } Coder;
static void emit(Coder *c, uint8_t b) {
    if (c->len == c->cap) { c->cap = c->cap ? c->cap * 2 : 1 << 16; c->buf = realloc(c->buf, c->cap); }
    c->buf[c->len++] = b;
}
static inline int code_bit(Coder *c, int p12, int bit) {
    uint32_t xmid = c->x1 + ((c->x2 - c->x1) >> 12) * (uint32_t)p12;
    if (c->dec) bit = c->x <= xmid;
    if (bit) c->x2 = xmid; else c->x1 = xmid + 1;
    while (((c->x1 ^ c->x2) & 0xFF000000u) == 0) {
        if (c->dec) { c->x = (c->x << 8) | (c->pos < c->len ? c->buf[c->pos] : 0); c->pos++; }
        else emit(c, c->x2 >> 24);
        c->x1 <<= 8; c->x2 = (c->x2 << 8) | 255;
    }
    return bit;
}
/* MIXV: 32-bit-only mixer (vectorizes 8-wide): dot = sum((w*st) >> 8) >> 8, |w| <= 2^19 */
static inline int dot32(const int32_t *w, const int *st, int n) {
    int32_t s = 0;
    for (int k = 0; k < n; k++) s += (w[k] * st[k]) >> 8;
    return s >> 8;
}
static inline void upd32(int32_t *w, const int *st, int n, int e) {
    int el = e * LRCUR;
    for (int k = 0; k < n; k++) {
        int32_t nw = w[k] + ((st[k] * el) >> 14);
        w[k] = nw > (1 << 19) - 1 ? (1 << 19) - 1 : (nw < -(1 << 19) ? -(1 << 19) : nw);
    }
}
static inline void upd_w(int32_t *w, const int *st, int n, int e) {
    if (MIXV) { upd32(w, st, n, e); return; }
    for (int k = 0; k < n; k++) {
        int32_t nw = w[k] + ((st[k] * e * LRCUR) >> 14);
        w[k] = nw > (1 << 22) ? (1 << 22) : (nw < -(1 << 22) ? -(1 << 22) : nw);
    }
}
static inline int apm_p(uint16_t *A, int ctx, int d, int *aidx, int *awt) {
    int ds = d < -2047 ? -2047 : (d > 2047 ? 2047 : d);
    int pos = (ds + 2048) * 32;
    *awt = pos & 4095; *aidx = ctx * 33 + (pos >> 12);
    return (A[*aidx] * (4096 - *awt) + A[*aidx + 1] * *awt) >> 16;
}
static inline void apm_upd(uint16_t *A, int aidx, int awt, int bit) {
    int g = (bit << 16) + (bit << 5) - bit - bit;
    int j = awt >> 11 ? aidx + 1 : aidx;
    A[j] += (g - A[j]) >> 6;
}

#define MBITS 22
static void run(Coder *c, int mode, int bb, int limit, uint32_t feat, int64_t width, uint8_t *data, int64_t L) {
    int img = mode == 2;
    int fmatch = !img && (feat & 1), fword = !img && (feat & 2), fmsel = !img && (feat & 4);
    int fapm2 = !img && (feat & 8), fhi = !img && (feat & 16), fmix2 = (feat & 32) != 0;
    int fsparse = !img && (feat & 128), fmix3 = fmix2 && (feat & 256);
    int fimgx = img && (feat & 512), fbias = img && (feat & 1024);
    int32_t BS[2187 * 2] = {0};   /* per gradient-context error sum / count (bias cancellation) */
    int nctx = img ? 12 + (fimgx ? 4 : 0) : 6 + (fword ? 2 : 0) + (fhi ? 2 : 0) + (fsparse ? 3 : 0);
    int fhist = (feat & 2048) != 0;
    int nin = nctx * (fhist ? 2 : 1) + (fmatch ? 1 : 0) + 1;       /* (+ history inputs) + match + bias */
    /* bit-history state maps: per input, 256 history patterns -> P(1) (16-bit) + count */
    int fhbp = fhist && (feat & 4096);   /* history maps also keyed by bit position */
    uint32_t *SM = malloc(sizeof(uint32_t) * MAXIN * 2048);   /* p16 | count << 16 */
    for (int j = 0; j < MAXIN * 2048; j++) SM[j] = 32768;
    int smi[MAXIN];
    int np = img ? 9 : 0;
    /* table size per context: low-cardinality contexts get small, cache-resident tables */
    int tb[MAXIN];
    static const int TB_IMG[16] = {8, 12, 12, 12, 16, 16, 0, 17, 0, 0, 0, 0, 17, 16, 16, 0};
    for (int k = 0; k < nctx; k++) tb[k] = bb;
    if (OPT_SMALLT) {
        if (img) { for (int k = 0; k < nctx; k++) if (TB_IMG[k] && TB_IMG[k] < bb) tb[k] = TB_IMG[k]; }
        else {
            tb[0] = 6; tb[1] = 13 < bb ? 13 : bb;               /* order 0, order 1 */
            if (fsparse) { int b = 6 + (fhi ? 2 : 0) + (fword ? 2 : 0); tb[b] = 13 < bb ? 13 : bb; tb[b + 2] = 15 < bb ? 15 : bb; }
        }
    }
    uint32_t *T[MAXIN];
    for (int k = 0; k < nctx; k++) {
        size_t tsz = (size_t)16 << tb[k];
        T[k] = big_alloc(tsz * 4);
        for (size_t j = 0; j < tsz; j++) T[k][j] = (j & 15) ? (32768 | 1u << 24) : 0;
    }
    int32_t winit = 19661 * 6 / nin;
    int nsets1 = 8 * 16, nsets2 = 768;
    int32_t *W1 = malloc(sizeof(int32_t) * nsets1 * MAXIN), *W2 = malloc(sizeof(int32_t) * nsets2 * MAXIN);
    for (int j = 0; j < nsets1 * MAXIN; j++) W1[j] = winit;
    for (int j = 0; j < nsets2 * MAXIN; j++) W2[j] = winit;
    int32_t *W3 = malloc(sizeof(int32_t) * 2048 * MAXIN), *WF = malloc(sizeof(int32_t) * 256 * 3);
    for (int j = 0; j < 2048 * MAXIN; j++) W3[j] = winit;
    for (int j = 0; j < 256 * 3; j++) WF[j] = 21845;
    int napm1 = img ? 256 * 16 * 3 : 65536, napm2 = 1 << A2BITS;
    uint16_t *A1 = malloc(sizeof(uint16_t) * napm1 * 33), *A2 = malloc(sizeof(uint16_t) * (fapm2 ? napm2 : 1) * 33);
    for (int k = 0; k < napm1; k++) for (int j = 0; j < 33; j++) A1[k * 33 + j] = squash((j - 16) * 128) * 16;
    if (fapm2) for (int k = 0; k < napm2; k++) for (int j = 0; j < 33; j++) A2[k * 33 + j] = squash((j - 16) * 128) * 16;
    uint32_t *MT = fmatch ? calloc((size_t)1 << MBITS, 4) : NULL;
    uint16_t MP[64]; for (int j = 0; j < 64; j++) MP[j] = 49152;  /* P(expected bit is right) */
    uint8_t MN[64] = {0};
    int16_t *err = img ? calloc(L + 1, 2) : NULL;
    uint8_t *perr = np ? calloc((L + 1) * np, 1) : NULL;
    int64_t stride = 3 * width;
    uint32_t ctx[MAXIN], c4 = 0, c8 = 0, w0 = 0, w1 = 0;
    uint32_t *bk[MAXIN];
    int st[MAXIN + 2];
    int64_t mptr = 0, mlen = 0;
    static const int ORD[8] = {0, 1, 2, 3, 4, 6, 5, 7};

    for (int64_t i = 0; i < L; i++) {
        int ch = 0, act = 0, eP = 0, pred = 0, sym = 0, pr[NPRED], bctx = 0, predRaw = 0;
        int mb = -1, lenq = 0, msel = 0;
        if (!img) {
            for (int k = 0; k < 6 + (fhi ? 2 : 0); k++) {
                int o = ORD[k];
                uint32_t m = o >= 4 ? 0xFFFFFFFFu : ((1u << (8 * o)) - 1);
                uint32_t hi = o == 6 ? (c8 & 0xFFFF) : o == 5 ? (c8 & 0xFF) : o == 7 ? (c8 & 0xFFFFFF) : 0;
                ctx[k] = H(o, c4 & m, hi, 0);
            }
            if (fword) { int b = 6 + (fhi ? 2 : 0); ctx[b] = H(30, w0, 0, 0); ctx[b + 1] = H(31, w0, w1, 0); }
            if (fsparse) {
                int b = 6 + (fhi ? 2 : 0) + (fword ? 2 : 0);
                ctx[b] = H(40, (c4 >> 8) & 0xFF, 0, 0);          /* byte i-2 alone */
                ctx[b + 1] = H(41, (c4 >> 16) & 0xFFFF, 0, 0);   /* bytes i-3,i-4 */
                ctx[b + 2] = H(42, (uint32_t)(i & 3), c4 & 0xFF, 0); /* 4-byte alignment + last byte */
            }
            if (fmatch) {
                if (mlen > 0) { if (data[mptr] == data[i - 1]) { mlen++; mptr++; } else mlen = 0; }
                if (i >= 6) {
                    uint32_t h = H(99, c4, c8 & 0xFFFF, 0) >> (32 - MBITS);
                    if (mlen == 0) {
                        int64_t cand = MT[h];
                        if (cand > 0) {
                            int64_t len = 0;
                            while (len < 400 && cand - 1 - len >= 0 && data[cand - 1 - len] == data[i - 1 - len]) len++;
                            if (len >= 6) { mlen = len; mptr = cand; }
                        }
                    }
                    MT[h] = (uint32_t)i;
                }
                if (mlen > 65535) mlen = 65535;
                if (mlen > 0) {
                    mb = data[mptr];
                    lenq = mlen < 16 ? (int)mlen : 16 + (int)((mlen - 16) >> 4 > 15 ? 15 : (mlen - 16) >> 4);
                    msel = mlen < 16 ? 1 : mlen < 32 ? 2 : 3;
                }
            }
            if (!c->dec) sym = data[i];
        } else {
            ch = i % 3;
            int64_t px = i / 3; int64_t x = px % width, y = px / width;
            int hasW = x > 0, hasN = y > 0, hasNE = y > 0 && x < width - 1, hasWW = x > 1, hasNN = y > 1;
            int64_t iW = i - 3, iN = i - stride, iNW = iN - 3, iNE = iN + 3;
            int Wv = hasW ? data[iW] : (hasN ? data[iN] : 0);
            int Nv = hasN ? data[iN] : Wv;
            int NWv = (hasN && hasW) ? data[iNW] : Nv;
            int NEv = hasNE ? data[iNE] : Nv;
            int WWv = hasWW ? data[i - 6] : Wv;
            int NNv = hasNN ? data[iN - stride] : Nv;
            int mx = Wv > Nv ? Wv : Nv, mn = Wv < Nv ? Wv : Nv;
            pr[0] = NWv >= mx ? mn : (NWv <= mn ? mx : Wv + Nv - NWv);
            pr[1] = clamp255(Wv + Nv - NWv);
            pr[2] = (Wv + NEv + 1) >> 1;
            pr[3] = clamp255(Nv + ((Wv - NWv + NEv - Nv) >> 1));
            pr[4] = pr[0];
            if (ch > 0) {
                int pw = hasW ? data[iW - 1] : (hasN ? data[iN - 1] : 0);
                int pn = hasN ? data[iN - 1] : pw;
                int pnw = (hasN && hasW) ? data[iNW - 1] : pn;
                int pmx = pw > pn ? pw : pn, pmn = pw < pn ? pw : pn;
                int pmed = pnw >= pmx ? pmn : (pnw <= pmn ? pmx : pw + pn - pnw);
                pr[4] = clamp255(pr[0] + (data[i - 1] - pmed));
            }
            pr[5] = Wv; pr[6] = Nv; pr[7] = clamp255(2 * Wv - WWv); pr[8] = clamp255(2 * Nv - NNv);
            int64_t num = 0, den = 0;
            for (int k = 0; k < np; k++) {
                int s = 1;
                if (hasW) s += perr[iW * np + k];
                if (hasN) s += perr[iN * np + k];
                if (hasN && hasW) s += perr[iNW * np + k];
                if (hasNE) s += perr[iNE * np + k];
                int64_t w = (1LL << 24) / ((int64_t)s * s);
                num += w * pr[k]; den += w;
            }
            pred = (int)((num + den / 2) / den);
            if (fbias) {
                bctx = (((int)qg(Wv - NWv) - 4) * 9 + ((int)qg(Nv - NWv) - 4)) * 9 + ((int)qg(NEv - Nv) - 4);
                bctx = bctx * 3 + ch;
                predRaw = pred;
                int sum = BS[bctx * 2], cnt = BS[bctx * 2 + 1];
                if (cnt > 0) pred = clamp255(pred + (sum >= 0 ? (sum + cnt / 2) / cnt : -((-sum + cnt / 2) / cnt)));
            }
            int eW = hasW ? err[iW] : 0, eN = hasN ? err[iN] : 0, eNW = (hasN && hasW) ? err[iNW] : 0;
            int eNE = hasNE ? err[iNE] : 0, eP2 = ch == 2 ? err[i - 2] : 0;
            eP = ch ? err[i - 1] : 0;
            act = bitlen(iabs(eW) + iabs(eN) + iabs(eNW) + iabs(eNE));
            if (act > 15) act = 15;
            uint32_t chv = ch, qp = ch ? qe(eP, 12) : 255;
            ctx[0] = H(10, chv, 0, 0);
            ctx[1] = H(11, chv, qe(eW, 12), 0);
            ctx[2] = H(12, chv, qe(eN, 12), 0);
            ctx[3] = H(13, chv, qp, ch ? 0 : 99);
            ctx[4] = H(14, chv, qe(eW, 12), qe(eN, 12));
            ctx[5] = H(15, chv, qp, act);
            ctx[6] = H(16, chv, qe(eNW, 8) * 256 + qe(eNE, 8), act);
            ctx[7] = H(17, chv, qg(Wv - NWv) * 16 + qg(Nv - NWv), qg(NEv - Nv));
            ctx[8] = H(18, chv, ch ? qe(eP, 20) * 256 + qe(eP2, 20) : 255, pred >> 5);
            ctx[9] = H(19, chv, qe(pr[0] - pred, 24) * 256 + qe(pr[4] - pred, 24), 0);
            ctx[10] = H(20, chv, qe(pr[2] - pred, 24) * 256 + qe(pr[3] - pred, 24), 0);
            ctx[11] = H(21, chv, qe(Wv - pred, 24) * 256 + qe(Nv - pred, 24), qe(NEv - pred, 24));
            if (fimgx) {
                int eWW = hasWW ? err[i - 6] : 0, eNN = hasNN ? err[iN - stride] : 0;
                ctx[12] = H(22, chv, (uint32_t)(Wv >> 3), (uint32_t)(Nv >> 3));
                ctx[13] = H(23, chv, qe(eWW, 12) * 256 + qe(eNN, 12), 0);
                ctx[14] = H(24, chv, (uint32_t)(pred >> 3), act);
                ctx[15] = H(25, chv, ch ? qe(eP, 8) : 255, qe(eW, 6) * 256 + qe(eN, 6));
            }
            if (!c->dec) { int s = (int8_t)(uint8_t)(data[i] - pred); sym = s >= 0 ? 2 * s : -2 * s - 1; }
        }
        LRCUR = LR0 > LR ? LR + (int)((int64_t)(LR0 - LR) * 131072 / (131072 + i)) : LR;
        int sel1 = img ? act : (fmsel ? msel : 0);
        uint32_t c0 = 1, node = 1;
        int mmiss = 0;
        for (int bp = 0; bp < 8; bp++) {
            if (bp == 0 || bp == 4) {
                /* hash every context, request all buckets, then search: the cache misses overlap */
                uint32_t hk[MAXIN];
                for (int k = 0; k < nctx; k++) {
                    hk[k] = nib_hash(ctx[k], c0);
                    uint32_t i0 = hk[k] >> (32 - tb[k]);
                    __builtin_prefetch(T[k] + ((size_t)i0 << 4));
                    __builtin_prefetch(T[k] + ((size_t)(i0 ^ 1) << 4));
                }
                for (int k = 0; k < nctx; k++) bk[k] = find_bucket(T[k], tb[k], hk[k]);
                node = 1;
            }
            int n = 0;
            for (int k = 0; k < nctx; k++) st[n++] = STRETCH[(bk[k][node] & 0xFFFF) >> 4];
            int smb = fhbp ? bp * 256 : 0;
            if (fhist) for (int k = 0; k < nctx; k++) {
                smi[k] = k * 2048 + smb + (int)(bk[k][node] >> 24);
                st[n++] = STRETCH[(SM[smi[k]] & 0xFFFF) >> 4];
            }
            int eb = -1, mq = 0;
            if (fmatch) {
                if (mb >= 0 && !mmiss) {
                    eb = (mb >> (7 - bp)) & 1;
                    mq = lenq * 2 + (bp == 0);
                    int sp = STRETCH[MP[mq] >> 4];
                    st[n++] = eb ? sp : -sp;
                } else st[n++] = 0;
            }
            st[n++] = 256;  /* bias */
            int32_t *w1 = W1 + (bp * 16 + sel1) * MAXIN;
            int32_t *w2 = W2 + (img ? ((bp * 3 + ch) * 32 + (ch ? (int)qe(eP, 15) - 49 : 0)) : (int)c0) * MAXIN;
            int d, p2 = 0;
            if (MIXV) d = dot32(w1, st, nin);
            else { int64_t dot = 0; for (int k = 0; k < nin; k++) dot += (int64_t)w1[k] * st[k]; d = (int)(dot >> 16); }
            int p1 = clampp(squash(d));
            if (fmix2) {
                int d2;
                if (MIXV) d2 = dot32(w2, st, nin);
                else { int64_t dot2 = 0; for (int k = 0; k < nin; k++) dot2 += (int64_t)w2[k] * st[k]; d2 = (int)(dot2 >> 16); }
                p2 = clampp(squash(d2));
                d = (d + d2) >> 1;
            }
            int p3 = 0, pf = 0, dd[3] = {0, 0, 0};
            int32_t *w3 = W3 + ((img ? ch * 256 + (int)c0 : (int)((c4 & 0xFF) << 3 | bp)) & 2047) * MAXIN;
            int32_t *wf = WF + (int)c0 * 3;
            if (fmix3) {  /* replace the plain average with a learned final mixer */
                if (MIXV) { dd[0] = dot32(w1, st, nin); dd[1] = dot32(w2, st, nin); dd[2] = dot32(w3, st, nin); }
                else {
                    int64_t dot1 = 0, dot2 = 0, dot3 = 0;
                    for (int k = 0; k < nin; k++) { dot1 += (int64_t)w1[k] * st[k]; dot2 += (int64_t)w2[k] * st[k]; dot3 += (int64_t)w3[k] * st[k]; }
                    dd[0] = (int)(dot1 >> 16); dd[1] = (int)(dot2 >> 16); dd[2] = (int)(dot3 >> 16);
                }
                for (int k = 0; k < 3; k++) dd[k] = dd[k] < -2047 ? -2047 : (dd[k] > 2047 ? 2047 : dd[k]);
                p3 = clampp(squash(dd[2]));
                int64_t df = (int64_t)wf[0] * dd[0] + (int64_t)wf[1] * dd[1] + (int64_t)wf[2] * dd[2];
                d = (int)(df >> 16);
                pf = clampp(squash(d));
            }
            int p12 = squash(d), ai1 = 0, aw1 = 0, ai2 = 0, aw2 = 0;
            if (fmix2) {
                int a = img ? (((int)c0 * 16 + act) * 3 + ch) : (int)(c0 | (c4 & 255) << 8);
                int pa = apm_p(A1, a, d, &ai1, &aw1);
                if (fapm2) {
                    int a2 = (int)(((H(77, c4 & 0xFFFF, 0, 0) >> (40 - A2BITS)) << 8) | c0);
                    int pb = apm_p(A2, a2, d, &ai2, &aw2);
                    p12 = (2 * p12 + 3 * pa + 3 * pb) >> 3;
                } else p12 = (p12 + 3 * pa) >> 2;
            }
            p12 = clampp(p12);
            int bit = code_bit(c, p12, (sym >> (7 - bp)) & 1);
            upd_w(w1, st, nin, (bit << 12) - p1);
            if (fmix2) {
                upd_w(w2, st, nin, (bit << 12) - p2);
                if (fmix3) { upd_w(w3, st, nin, (bit << 12) - p3); upd_w(wf, dd, 3, (bit << 12) - pf); }
                apm_upd(A1, ai1, aw1, bit);
                if (fapm2) apm_upd(A2, ai2, aw2, bit);
            }
            for (int k = 0; k < nctx; k++) {
                uint32_t e = bk[k][node], p = e & 0xFFFF, cnt = (e >> 16) & 255, hb = e >> 24;
                /* RECIP[n] < 2/3 * 32768, so p stays within 0..65535 without clamping */
                int np2 = (int)p + (((((int)bit << 16) - (int)p) * RECIP[cnt]) >> 15);
                if ((int)cnt < limit) cnt++;
                if (fhist) {
                    uint32_t sv = SM[smi[k]]; int sp = sv & 0xFFFF, sn = sv >> 16;
                    sp += (((bit << 16) - sp) * RECIP[sn]) >> 15;
                    SM[smi[k]] = (uint32_t)sp | (uint32_t)(sn < 255 ? sn + 1 : 255) << 16;
                }
                hb = (hb << 1) | bit;           /* shift in bit, keep a length sentinel, max 7 bits */
                if (hb >= 256) hb = (hb & 0x7F) | 0x80;
                bk[k][node] = (uint32_t)np2 | cnt << 16 | hb << 24;
            }
            if (eb >= 0) {
                int ok = bit == eb, cnt = MN[mq];
                int p = MP[mq] + ((((ok << 16) - MP[mq]) * RECIP[cnt]) >> 15);
                MP[mq] = p < 0 ? 0 : (p > 65535 ? 65535 : p);
                if (cnt < 255) MN[mq] = cnt + 1;
                if (!ok) mmiss = 1;
            }
            c0 = c0 * 2 + bit;
            node = node * 2 + bit;
        }
        int v = c0 & 255;
        if (!img) {
            if (c->dec) data[i] = v;
            c8 = (c8 << 8) | (c4 >> 24); c4 = (c4 << 8) | data[i];
            if (fword) {
                int ch2 = data[i];
                int isw = (ch2 >= 'a' && ch2 <= 'z') || (ch2 >= 'A' && ch2 <= 'Z') || (ch2 >= '0' && ch2 <= '9') || ch2 == '_' || ch2 >= 128;
                if (isw) w0 = (w0 + (uint32_t)(ch2 | 32) + 1) * 0x01000193u;
                else if (w0) { w1 = w0; w0 = 0; }
            }
        } else {
            if (c->dec) { int s = (v & 1) ? -((v + 1) >> 1) : (v >> 1); data[i] = (uint8_t)(pred + s); }
            err[i] = (int8_t)(uint8_t)(data[i] - pred);
            if (fbias) {
                BS[bctx * 2] += data[i] - predRaw;
                if (++BS[bctx * 2 + 1] >= 32) { BS[bctx * 2] /= 2; BS[bctx * 2 + 1] /= 2; }
            }
            for (int k = 0; k < np; k++) { int ek = iabs(data[i] - pr[k]); perr[i * np + k] = ek > 255 ? 255 : ek; }
        }
    }
    for (int k = 0; k < nctx; k++) free(T[k]);
    free(W1); free(W2); free(W3); free(WF); free(SM); free(A1); free(A2); free(MT); free(err); free(perr);
}

static int e8e9_detect(const uint8_t *d, int64_t n) {
    int64_t cnt = 0, good = 0;
    for (int64_t i = 0; i + 4 < n; i++) if (d[i] == 0xE8 || d[i] == 0xE9) { cnt++; if (d[i + 4] == 0 || d[i + 4] == 0xFF) good++; }
    return cnt > n / 256 && good * 2 > cnt;
}
/* x86 CALL/JMP rel32 -> absolute (fwd) and back; positions decided by the opcode byte, which is unchanged */
static void e8e9(uint8_t *d, int64_t n, int fwd) {
    for (int64_t i = 0; i + 4 < n;) {
        if (d[i] == 0xE8 || d[i] == 0xE9) {
            uint32_t v = d[i + 1] | d[i + 2] << 8 | d[i + 3] << 16 | (uint32_t)d[i + 4] << 24;
            v = fwd ? v + (uint32_t)(i + 5) : v - (uint32_t)(i + 5);
            d[i + 1] = v; d[i + 2] = v >> 8; d[i + 3] = v >> 16; d[i + 4] = v >> 24;
            i += 5;
        } else i++;
    }
}
static void put32(uint8_t *p, uint32_t v) { for (int i = 0; i < 4; i++) p[i] = v >> (8 * i); }
static uint32_t get32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }
static uint8_t *slurp(const char *path, int64_t *n) {
    FILE *f = fopen(path, "rb"); if (!f) { perror(path); exit(1); }
    fseek(f, 0, SEEK_END); *n = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *b = malloc(*n ? *n : 1);
    if ((int64_t)fread(b, 1, *n, f) != *n) { perror("read"); exit(1); }
    fclose(f); return b;
}
int main(int argc, char **argv) {
    init_tables();
    if (argc >= 5 && !strcmp(argv[1], "enc")) {
        int mode = !strcmp(argv[2], "image") ? 2 : 1;
        int64_t width = mode == 2 ? atoll(argv[3]) : 0, L;
        const char *in = argv[mode == 2 ? 4 : 3], *out = argv[mode == 2 ? 5 : 4];
        uint32_t feat = getenv("FEAT") ? (uint32_t)atoi(getenv("FEAT")) : 63;
        int bb = getenv("BB") ? atoi(getenv("BB")) : 18, limit = getenv("LIMIT") ? atoi(getenv("LIMIT")) : 255;
        uint8_t *data = slurp(in, &L);
        if (getenv("LR")) LR = atoi(getenv("LR"));
        if (getenv("LR0")) LR0 = atoi(getenv("LR0"));
        if (getenv("HUGE")) OPT_HUGE = atoi(getenv("HUGE"));
        if (getenv("SMALLT")) OPT_SMALLT = atoi(getenv("SMALLT"));
        if (getenv("A2BITS")) A2BITS = atoi(getenv("A2BITS"));
        if (getenv("MIXV")) MIXV = atoi(getenv("MIXV"));
        feat &= ~(64u | 8192u | 16384u);
        if (MIXV) feat |= 8192;
        if (!OPT_SMALLT) feat |= 16384;
        if (mode == 1 && (getenv("E8") ? atoi(getenv("E8")) : 1) && e8e9_detect(data, L)) { e8e9(data, L, 1); feat |= 64; }
        Coder c = {0, 0xFFFFFFFFu, 0, NULL, 0, 0, 0, 0};
        for (int i = 0; i < HDR; i++) emit(&c, 0);
        run(&c, mode, bb, limit, feat, width, data, L);
        for (int i = 3; i >= 0; i--) emit(&c, c.x1 >> (8 * i));
        while (c.len > HDR && c.buf[c.len - 1] == 0) c.len--;
        uint8_t *h = c.buf;
        memcpy(h, "FM3\x01", 4); h[4] = mode; h[5] = bb; h[6] = limit; h[7] = (uint8_t)LR;
        put32(h + 8, feat); put32(h + 12, (uint32_t)width); put32(h + 16, (uint32_t)L); put32(h + 20, (uint32_t)((uint64_t)L >> 32));
        FILE *f = fopen(out, "wb"); fwrite(c.buf, 1, c.len, f); fclose(f);
        return 0;
    }
    if (argc == 4 && !strcmp(argv[1], "dec")) {
        int64_t n; uint8_t *f = slurp(argv[2], &n);
        if (n < HDR || memcmp(f, "FM3\x01", 4)) { fprintf(stderr, "not FM3\n"); return 1; }
        int mode = f[4], bb = f[5], limit = f[6]; uint32_t feat = get32(f + 8);
        int64_t width = get32(f + 12), L = (int64_t)get32(f + 16) | (int64_t)get32(f + 20) << 32;
        uint8_t *data = malloc(L ? L : 1);
        Coder c = {0, 0xFFFFFFFFu, 0, f + HDR, n - HDR, 0, 0, 1};
        for (int i = 0; i < 4; i++) c.x = (c.x << 8) | (c.pos < c.len ? c.buf[c.pos] : 0), c.pos++;
        LR = f[7]; MIXV = (feat & 8192) != 0; OPT_SMALLT = !(feat & 16384);
        if (getenv("HUGE")) OPT_HUGE = atoi(getenv("HUGE"));
        if (getenv("A2BITS")) A2BITS = atoi(getenv("A2BITS"));
        run(&c, mode, bb, limit, feat, width, data, L);
        if (feat & 64) e8e9(data, L, 0);
        FILE *o = fopen(argv[3], "wb"); fwrite(data, 1, L, o); fclose(o);
        return 0;
    }
    fprintf(stderr, "usage: fm3 enc bytes IN OUT | fm3 enc image WIDTH IN OUT | fm3 dec IN OUT  (env FEAT, BB, LIMIT)\n");
    return 2;
}
