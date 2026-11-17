/* fm3: model-fraction codec, format FM3. C reference implementation = the spec for the BPL and JS ports.
 *
 *   fm4 enc LEVEL(0-5) bytes IN OUT | fm4 enc LEVEL image WIDTH IN OUT (raw RGB24) | fm4 dec IN OUT
 *   experiments: env FEAT (feature bits, overrides the level), BB (log2 buckets/table), LIMIT, LR, HUGE=0
 *
 * Container (28-byte header, little endian):
 *   "FM4\x01" | mode u8 (0 store, 1 bytes, 2 image) | bb u8 | counter limit u8 | mixer lr u8
 *   | feat u32 | width u32 | L u64 | payload (store: raw bytes; else digits of N: data = model-decode(N/256^k))
 *
 * Feature bits (feat):
 *   bytes  1 match model (6-byte hash)        2 word contexts                4 mixer-1 set by match length
 *          8 order-2 APM                       16 orders 5 and 7              32 mixer 2 + order-1 APM
 *          64 E8/E9 transform was applied     128 sparse / alignment ctx     256 3-mixer network + final mixer
 *          2048 bit-history inputs            32768 indirect contexts        65536 match-model APM
 *          131072 2nd match model (12 bytes)  262144 column + word-pair ctx  1<<21 lite: orders 1-3 only
 *   image  32 mixer 2 + APM   256 3-mixer network   512 4 extra contexts   1<<20 blend weight 1/err (else 1/err^2)
 *          1<<21 lite: MED predictor + 6 contexts
 *   8192 is always set (32-bit mixer arithmetic); decoders ignore it.
 *
 * Model (all integer; every port must match bit for bit):
 *   - context tables: per context, 2^bb buckets of 16 u32 (64 bytes). Bucket per (context, nibble):
 *     h = nib_hash(ctx, c0); i0 = h >> (32 - bb); check = (h * 0x2545F491) >> 16 (0 -> 1);
 *     use bucket i0 or i0^1 whose [0] low 16 bits == check, else reset the one with the smaller
 *     node-1 count. Entries [1..15] (node = 1, then node*2+bit within the nibble): p16 | n8 << 16 | hist8 << 24.
 *     Low-cardinality contexts use smaller tables (tableBits()).
 *   - counter: p += ((bit<<16) - p) * RECIP[n] >> 15, RECIP[n] = 65536/(2n+3); n++ while n < limit.
 *     history: h = h<<1|bit, if h >= 256: h = (h & 0x7F) | 0x80 (initial 1).
 *   - history map per input: SM[k*256 + hist] = p16 | n << 16, same update, n capped at 255.
 *   - mixer: dot = sum((w*st) >> 8) >> 8; w += (st * (err*LR)) >> 14, clamp [-2^19, 2^19-1].
 *   - APM: 33 buckets, interpolated on stretch(p); update nearer bucket by (target - a) >> 6.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <math.h>

#define MAXIN 96
#define NPRED 12
#define HDR 28
#define MBITS 22

static int SQ_T[33] = {1, 2, 3, 6, 10, 16, 27, 45, 73, 120, 194, 310, 488, 747, 1101, 1546, 2047,
                       2549, 2994, 3348, 3607, 3785, 3901, 3975, 4022, 4050, 4068, 4079, 4085, 4089, 4092, 4093, 4094};
static int STRETCH[4096], RECIP[256], LR = 4, OPT_HUGE = 1;
#define OSKIP 4          /* OLS: solve every 4th sample */
#define OLAM 0.998
#define OEPS 0.001

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

/* big tables on 2 MB huge pages where available (fewer TLB misses; no effect on output) */
static void *big_alloc(size_t n) {
    void *p = NULL;
    if (OPT_HUGE && n >= (1u << 21)) {
        if (posix_memalign(&p, 1u << 21, n)) p = NULL;
        else madvise(p, n, MADV_HUGEPAGE);
    }
    return p ? p : malloc(n);
}
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
/* mixer: 16-bit weights (4096 = 1.0), 32-bit wrapping accumulator */
static inline int dot16(const int16_t *w, const int16_t *st, int n) {
    uint32_t s = 0;
    for (int k = 0; k < n; k++) s += (uint32_t)(w[k] * st[k]);
    return (int32_t)s >> 12;
}
static inline void upd16(int16_t *w, const int16_t *st, int n, int e) {
    int el = e * LR;
    for (int k = 0; k < n; k++) {
        int nw = w[k] + ((st[k] * el + (1 << 17)) >> 18);
        w[k] = nw > 32767 ? 32767 : (nw < -32768 ? -32768 : nw);
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
static void apm_init(uint16_t *A, int n) {
    for (int k = 0; k < n; k++) for (int j = 0; j < 33; j++) A[k * 33 + j] = squash((j - 16) * 128) * 16;
}

#define OLSN 40
typedef struct { int n, cnt; double lam; double m[OLSN][OLSN], b[OLSN], w[OLSN], x[OLSN]; } Ols;
static double ols_pred(Ols *o) { double s = 0; for (int k = 0; k < o->n; k++) s += o->w[k] * o->x[k]; return s; }
static void ols_upd(Ols *o, double y) {
    int n = o->n; double L[OLSN][OLSN], z[OLSN];
    for (int j = 0; j < n; j++) {
        for (int k = 0; k <= j; k++) o->m[j][k] = o->lam * o->m[j][k] + (1 - o->lam) * o->x[j] * o->x[k];
        o->b[j] = o->lam * o->b[j] + (1 - o->lam) * o->x[j] * y;
    }
    if (++o->cnt < OSKIP) return;
    o->cnt = 0;
    for (int j = 0; j < n; j++) for (int k = 0; k <= j; k++) {
        double v = o->m[j][k] + (j == k ? OEPS : 0);
        for (int t = 0; t < k; t++) v -= L[j][t] * L[k][t];
        if (j == k) { if (v <= 0) return; L[j][j] = sqrt(v); } else L[j][k] = v / L[k][k];
    }
    for (int j = 0; j < n; j++) { double v = o->b[j]; for (int t = 0; t < j; t++) v -= L[j][t] * z[t]; z[j] = v / L[j][j]; }
    for (int j = n - 1; j >= 0; j--) { double v = z[j]; for (int t = j + 1; t < n; t++) v -= L[t][j] * o->w[t]; o->w[j] = v / L[j][j]; }
}
static void run(Coder *c, int mode, int bb, int limit, uint32_t feat, uint32_t feat2, int64_t width, uint8_t *data, int64_t L) {
    int img = mode == 2, aud = mode == 3, nchan = aud ? (int)width : 0;
    int XORD = !img && (feat2 & 1), XM4 = (feat & 256) && (feat2 & 2), XTXT = !img && (feat2 & 4), XRUN = !img && (feat2 & 8);
    int XOLS = img && (feat2 & 16), XWIDE = XOLS && (feat2 & 32), XCOL = img && (feat2 & 64), XIM = img && (feat2 & 128);
    int flite = (feat & (1u << 21)) != 0;
    int fmatch = !img && (feat & 1), fword = !img && (feat & 2), fmsel = !img && (feat & 4);
    int fapm2 = !img && (feat & 8), fhi = !img && !flite && (feat & 16), fmix2 = (feat & 32) != 0;
    int fsparse = !img && (feat & 128), fmix3 = fmix2 && (feat & 256), fimgx = img && !flite && (feat & 512);
    int fhist = !img && (feat & 2048) != 0;
    int find = !img && (feat & 32768), fmapm = fmatch && fmix2 && (feat & 65536);
    int fm2nd = fmatch && (feat & 131072), fcol = !img && (feat & 262144);
    int fblend1 = img && (feat & (1u << 20));

    int nord = flite ? 3 : 6 + (fhi ? 2 : 0);
    int bword = nord, bsparse = bword + (fword ? 2 : 0), bind = bsparse + (fsparse ? 3 : 0), bcol = bind + (find ? 2 : 0);
    int btxt = bcol + (fcol ? 2 : 0), ntxt = XTXT ? 4 : 0;
    int nctx = img ? (flite ? 6 : 12 + (fimgx ? 4 : 0) + (XOLS ? 2 : 0) + (XCOL ? 2 : 0) + (XIM ? 1 : 0)) : btxt + ntxt;
    if (aud) nctx = 10;
    int nimm = XIM ? 1 : 0;
    int nrun = XRUN ? nctx : 0;
    int nin = nctx * (fhist ? 2 : 1) + nrun + nimm + (fmatch ? 1 : 0) + (fm2nd ? 1 : 0) + 1;   /* + match(es) + bias */
    int np = img && !flite ? 9 + (XOLS ? 1 : 0) : 0;
    Ols *OL = calloc(3, sizeof(Ols)); OL[0].n = 10; OL[1].n = 14; OL[2].n = 15; if (XWIDE) for (int k = 0; k < 3; k++) OL[k].n += 10; int oin = 0;
    for (int k = 0; k < 3; k++) OL[k].lam = OLAM;

    /* table size per context: low-cardinality contexts get small, cache-resident tables */
    static const int TB_IMG[16] = {8, 12, 12, 12, 16, 16, 0, 17, 0, 0, 0, 0, 17, 16, 16, 0};
    int tb[MAXIN];
    for (int k = 0; k < nctx; k++) tb[k] = bb;
    if (img) { for (int k = 0; k < nctx && k < 16; k++) if (TB_IMG[k] && TB_IMG[k] < bb && (k < 12 || fimgx)) tb[k] = TB_IMG[k]; }
    else {
        if (flite) tb[0] = 13 < bb ? 13 : bb;                 /* order 1 */
        else { tb[0] = 6; tb[1] = 13 < bb ? 13 : bb; }      /* order 0, order 1 */
        if (fsparse) { tb[bsparse] = 13 < bb ? 13 : bb; tb[bsparse + 2] = 15 < bb ? 15 : bb; }
    }
    if (aud) for (int k = 0; k < nctx; k++) tb[k] = bb < 16 ? bb : 16;
    /* audio: per channel a long OLS (16 or 32 own samples + 4 of the neighbour channel) and a short fast one */
    int an1 = (feat2 & 32 ? 32 : 16), an = an1 + (nchan > 1 ? 4 : 0);
    Ols *AO = aud ? calloc(2 * nchan, sizeof(Ols)) : NULL;
    for (int k = 0; k < nchan; k++) { AO[k].n = an; AO[k].lam = 0.998; AO[nchan + k].n = 8; AO[nchan + k].lam = 0.99; }
    int16_t *aerr = aud ? calloc(L / 2 + 1, 2) : NULL;
    int apred = 0, azig = 0, ahi = 0, aq = 0, ach = 0; uint32_t actx[16];
    uint32_t *T[MAXIN];
    for (int k = 0; k < nctx; k++) {
        size_t tsz = (size_t)16 << tb[k];
        T[k] = big_alloc(tsz * 4);
        for (size_t j = 0; j < tsz; j++) T[k][j] = (j & 15) ? (32768 | 1u << 24) : 0;
    }
    uint32_t *SM = malloc(sizeof(uint32_t) * MAXIN * 256);
    for (int j = 0; j < MAXIN * 256; j++) SM[j] = 32768;
    int32_t winit = 19661 * 6 / nin;
    int16_t *W1 = malloc(2 * 8 * 256 * MAXIN), *W2 = malloc(2 * 768 * MAXIN), *W3 = malloc(2 * 2048 * MAXIN), *W4 = malloc(2 * 4096 * MAXIN);
    int32_t *WF = malloc(sizeof(int32_t) * 256 * 4);
    for (int j = 0; j < 8 * 256 * MAXIN; j++) W1[j] = winit >> 4;
    for (int j = 0; j < 768 * MAXIN; j++) W2[j] = winit >> 4;
    for (int j = 0; j < 2048 * MAXIN; j++) W3[j] = winit >> 4;
    for (int j = 0; j < 4096 * MAXIN; j++) W4[j] = winit >> 4;
    for (int j = 0; j < 256 * 4; j++) WF[j] = XM4 ? 16384 : 21845;
    int napm1 = img ? 256 * 16 * 3 : 65536;
    uint16_t *A1 = malloc(sizeof(uint16_t) * napm1 * 33); apm_init(A1, napm1);
    uint16_t *A2 = fapm2 ? malloc(sizeof(uint16_t) * (1 << 18) * 33) : NULL; if (fapm2) apm_init(A2, 1 << 18);
    uint16_t *A3 = fmapm ? malloc(sizeof(uint16_t) * 65536 * 33) : NULL; if (fmapm) apm_init(A3, 65536);
    uint32_t *MT = fmatch ? calloc((size_t)1 << MBITS, 4) : NULL, *MT2 = fm2nd ? calloc((size_t)1 << MBITS, 4) : NULL;
    uint16_t MP[64], MP2[64]; uint8_t MN[64] = {0}, MN2[64] = {0};   /* P(expected bit is right) per length bucket */
    for (int j = 0; j < 64; j++) MP[j] = MP2[j] = 49152;
    uint16_t *IND1 = find ? calloc(256, 2) : NULL, *IND2 = find ? calloc(1 << 22, 2) : NULL;
    int16_t *err = img ? calloc(L + 1, 2) : NULL;
    uint8_t *perr = np ? calloc((L + 1) * np, 1) : NULL;
    int64_t stride = 3 * width, mptr = 0, mlen = 0, mptr2 = 0, mlen2 = 0, linestart = 0, prevline = 0, indent = 0, inind = 1, imptr = 0, imlen = 0, imok = 0, imev = -1;
    uint32_t *IMT = XIM ? calloc((size_t)1 << MBITS, 4) : NULL;
    uint32_t ctx[MAXIN], c4 = 0, c8 = 0, w0 = 0, w1 = 0, w2 = 0, *bk[MAXIN];
    int16_t st[2 * MAXIN + 4]; int smi[MAXIN];
    uint32_t *rk[MAXIN]; int rb[MAXIN], rq[MAXIN], reb[MAXIN], rmiss[MAXIN];
    uint16_t *RP = calloc(MAXIN * 64, 2); uint8_t *RN = calloc(MAXIN * 64, 1); for (int j = 0; j < MAXIN * 64; j++) RP[j] = 49152;
    int hord = 0, isym = -1, iq = 0, imiss = 0; uint16_t IMP[64]; uint8_t IMN[64] = {0}; for (int j = 0; j < 64; j++) IMP[j] = 49152;
    static const int ORD[8] = {0, 1, 2, 3, 4, 6, 5, 7};

    for (int64_t i = 0; i < L; i++) {
        int ch = 0, act = 0, eP = 0, pred = 0, sym = 0, pr[NPRED];
        int mb = -1, lenq = 0, msel = 0, mb2 = -1, lenq2 = 0;
        if (aud) {
#define SMP(j) ((int)(int16_t)(data[2 * (j)] | data[2 * (j) + 1] << 8))
#define QA(d) ((uint32_t)((d) < 0 ? 20 - bitlen(-(d)) : 20 + bitlen(d)))
            int bpos = (int)(i & 1); int64_t si = i >> 1, t = si / nchan;
            if (bpos == 0) {
                ach = (int)(si % nchan);
                int s1 = t > 0 ? SMP(si - nchan) : 0, s2 = t > 1 ? SMP(si - 2 * nchan) : s1;
                int p1 = s1, p2 = s1, p3 = 2 * s1 - s2;
                if (t >= an1) {
                    double *X = AO[ach].x, *Y = AO[nchan + ach].x;
                    for (int k = 0; k < an1; k++) X[k] = SMP(si - (int64_t)(k + 1) * nchan);
                    if (nchan > 1) {   /* neighbour channel: its sample at this time if already coded, then older ones */
                        int oc = ach ? ach - 1 : nchan - 1; int64_t ob = t * nchan + oc - (ach ? 0 : nchan);
                        for (int k = 0; k < 4; k++) X[an1 + k] = SMP(ob - (int64_t)k * nchan);
                    }
                    for (int k = 0; k < 8; k++) Y[k] = X[k];
                    double v = floor(ols_pred(&AO[ach]) + 0.5); p1 = v < -32768 ? -32768 : v > 32767 ? 32767 : (int)v;
                    v = floor(ols_pred(&AO[nchan + ach]) + 0.5); p2 = v < -32768 ? -32768 : v > 32767 ? 32767 : (int)v;
                }
                p3 = p3 < -32768 ? -32768 : p3 > 32767 ? 32767 : p3;
                apred = p1;
                int r1 = t > 0 ? aerr[si - nchan] : 0, r2 = t > 1 ? aerr[si - 2 * nchan] : 0, r3 = t > 2 ? aerr[si - 3 * nchan] : 0;
                int ro = ach ? aerr[si - 1] : (t > 0 ? aerr[si - 1] : 0);
                int e8 = 0; for (int k = 1; k <= 8; k++) if (t >= k) e8 += iabs(aerr[si - (int64_t)k * nchan]);
                act = bitlen(iabs(r1) + iabs(r2) + iabs(r3)); if (act > 15) act = 15;
                ctx[0] = 0;
                ctx[1] = (uint32_t)act;
                ctx[2] = (uint32_t)(bitlen(iabs(r1)) | bitlen(iabs(r2)) << 5);
                ctx[3] = QA(p2 - p1);
                ctx[4] = QA(p3 - p1) | (uint32_t)act << 8;
                ctx[5] = QA(ro) | (uint32_t)act << 8;
                ctx[6] = QA(r1) | QA(r2) << 8;
                ctx[7] = (uint32_t)bitlen(e8);
                ctx[8] = (uint32_t)bitlen(iabs(apred)) | (uint32_t)act << 8;
                ctx[9] = QA(p1 - s1) | QA(p2 - p1) << 8;
                for (int k = 0; k < nctx; k++) actx[k] = ctx[k];
                aq = (int)QA(p2 - p1);
                if (!c->dec) { int r = (int16_t)(SMP(si) - apred); azig = r >= 0 ? 2 * r : -2 * r - 1; }
            }
            for (int k = 0; k < nctx; k++) ctx[k] = H(80 + k, (uint32_t)(ach | bpos << 3), bpos ? (uint32_t)ahi : 0, actx[k]);
            ch = bpos;
            if (!c->dec) sym = bpos ? azig & 255 : azig >> 8;
        } else if (!img) {
            for (int k = 0; k < nord; k++) {
                int o = flite ? k + 1 : ORD[k];
                uint32_t m = o >= 4 ? 0xFFFFFFFFu : ((1u << (8 * o)) - 1);
                uint32_t hi = o == 6 ? (c8 & 0xFFFF) : o == 5 ? (c8 & 0xFF) : o == 7 ? (c8 & 0xFFFFFF) : 0;
                ctx[k] = H(o, c4 & m, hi, 0);
            }
            if (fword) { ctx[bword] = H(30, w0, 0, 0); ctx[bword + 1] = H(31, w0, w1, 0); }
            if (fsparse) {
                ctx[bsparse] = H(40, (c4 >> 8) & 0xFF, 0, 0);             /* byte i-2 alone */
                ctx[bsparse + 1] = H(41, (c4 >> 16) & 0xFFFF, 0, 0);      /* bytes i-3, i-4 */
                ctx[bsparse + 2] = H(42, (uint32_t)(i & 3), c4 & 0xFF, 0); /* 4-byte alignment + last byte */
            }
            if (find) {   /* what followed this order-1 / order-2 context the last two times */
                ctx[bind] = H(50, c4 & 0xFF, IND1[c4 & 0xFF], 0);
                ctx[bind + 1] = H(51, c4 & 0xFFFF, IND2[H(52, c4 & 0xFFFF, 0, 0) >> 10], 0);
            }
            if (fcol) {   /* char above in the previous line + column; word pair */
                int64_t col = i - linestart, ab = prevline + col;
                uint32_t above = ab < linestart ? data[ab] : 0;
                ctx[bcol] = H(60, above, (uint32_t)(col > 255 ? 255 : col), c4 & 0xFF);
                ctx[bcol + 1] = H(61, w0, w1, w2);
            }
            if (ntxt) {
                int j = btxt; int64_t col = i - linestart, ab = prevline + col;
                uint32_t above = ab < linestart ? data[ab] : 0, above1 = ab + 1 < linestart ? data[ab + 1] : 0;
                ctx[j++] = H(70, w0, w2, 0);                              /* skip-gram */
                ctx[j++] = H(71, above, above1, c4 & 0xFFFF);              /* 2 chars above + order 2 */
                ctx[j++] = H(72, (uint32_t)indent, w0, inind);             /* indentation + word */
                ctx[j++] = H(74, (uint32_t)indent, c4 & 0xFFFFFF, 0);      /* indentation + order 3 */
            }
            if (fmatch) {
                if (mlen > 0) { if (data[mptr] == data[i - 1]) { mlen++; mptr++; } else mlen = 0; }
                if (i >= 6) {
                    uint32_t h = H(99, c4, c8 & 0xFFFF, 0) >> (32 - MBITS);
                    if (mlen == 0 && MT[h] > 0) {
                        int64_t cand = MT[h], len = 0;
                        while (len < 400 && cand - 1 - len >= 0 && data[cand - 1 - len] == data[i - 1 - len]) len++;
                        if (len >= 6) { mlen = len; mptr = cand; }
                    }
                    MT[h] = (uint32_t)i;
                }
                if (fm2nd) {
                    if (mlen2 > 0) { if (data[mptr2] == data[i - 1]) { mlen2++; mptr2++; } else mlen2 = 0; }
                    if (i >= 12) {
                        uint32_t far = (uint32_t)data[i - 9] | (uint32_t)data[i - 10] << 8 | (uint32_t)data[i - 11] << 16 | (uint32_t)data[i - 12] << 24;
                        uint32_t hh = H(98, c4, c8, far) >> (32 - MBITS);
                        if (mlen2 == 0 && MT2[hh] > 0 && (int64_t)MT2[hh] != mptr) {
                            int64_t cand = MT2[hh], len = 0;
                            while (len < 400 && cand - 1 - len >= 0 && data[cand - 1 - len] == data[i - 1 - len]) len++;
                            if (len >= 12) { mlen2 = len; mptr2 = cand; }
                        }
                        MT2[hh] = (uint32_t)i;
                    }
                    if (mlen2 > 65535) mlen2 = 65535;
                    if (mlen2 > 0) {
                        mb2 = data[mptr2];
                        lenq2 = mlen2 < 16 ? (int)mlen2 : 16 + (int)((mlen2 - 16) >> 4 > 15 ? 15 : (mlen2 - 16) >> 4);
                    }
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
            int64_t px = i / 3, x = px % width, y = px / width;
            int hasW = x > 0, hasN = y > 0, hasNE = y > 0 && x < width - 1, hasWW = x > 1, hasNN = y > 1;
            int64_t iW = i - 3, iN = i - stride, iNW = iN - 3, iNE = iN + 3;
            int Wv = hasW ? data[iW] : (hasN ? data[iN] : 0);
            int Nv = hasN ? data[iN] : Wv;
            int NWv = (hasN && hasW) ? data[iNW] : Nv;
            int NEv = hasNE ? data[iNE] : Nv;
            int WWv = hasWW ? data[i - 6] : Wv;
            int NNv = hasNN ? data[iN - stride] : Nv;
            int mx = Wv > Nv ? Wv : Nv, mn = Wv < Nv ? Wv : Nv;
            pr[0] = NWv >= mx ? mn : (NWv <= mn ? mx : Wv + Nv - NWv);   /* MED */
            pred = pr[0];
            if (np) {
                pr[1] = clamp255(Wv + Nv - NWv);
                pr[2] = (Wv + NEv + 1) >> 1;
                pr[3] = clamp255(Nv + ((Wv - NWv + NEv - Nv) >> 1));
                pr[4] = pr[0];
                if (ch > 0) {   /* cross-channel: MED + previous channel's MED error */
                    int pw = hasW ? data[iW - 1] : (hasN ? data[iN - 1] : 0);
                    int pn = hasN ? data[iN - 1] : pw;
                    int pnw = (hasN && hasW) ? data[iNW - 1] : pn;
                    int pmx = pw > pn ? pw : pn, pmn = pw < pn ? pw : pn;
                    int pmed = pnw >= pmx ? pmn : (pnw <= pmn ? pmx : pw + pn - pnw);
                    pr[4] = clamp255(pr[0] + (data[i - 1] - pmed));
                }
                pr[5] = Wv; pr[6] = Nv; pr[7] = clamp255(2 * Wv - WWv); pr[8] = clamp255(2 * Nv - NNv);
                if (XOLS) {
                    oin = x >= 3 && y >= 3 && x < width - 3;
                    pr[9] = pr[0];
                    if (oin) {
                        double *X = OL[ch].x; int64_t s2 = 2 * stride;
                        X[0] = data[iW]; X[1] = data[iN]; X[2] = data[iNW]; X[3] = data[iNE]; X[4] = data[i - 6];
                        X[5] = data[i - s2]; X[6] = data[i - s2 + 3]; X[7] = data[iN - 6]; X[8] = data[iN + 6]; X[9] = data[i - s2 - 3];
                        if (ch >= 1) { X[10] = data[i - 1]; X[11] = data[iW - 1]; X[12] = data[iN - 1]; X[13] = data[iNW - 1]; }
                        if (ch == 2) X[14] = data[i - 2];
                        if (XWIDE) {   /* wider: 6 more same-channel, 4 more cross-channel */
                            int b = OL[ch].n - 10;
                            X[b] = data[i - 9]; X[b + 1] = data[iN - 9 < 0 ? iN : iN - 9]; X[b + 2] = data[iN + 9 >= i ? iN : iN + 9];
                            X[b + 3] = data[i - s2 - 6]; X[b + 4] = data[i - s2 + 6 >= i ? i - s2 : i - s2 + 6]; X[b + 5] = data[i - 3 * stride >= 0 ? i - 3 * stride : i - s2];
                            int c2 = ch ? 1 : 0;
                            X[b + 6] = c2 ? data[iNE - 1] : 0; X[b + 7] = c2 ? data[i - 7] : 0; X[b + 8] = c2 ? data[i - s2 - 1] : 0;
                            X[b + 9] = ch == 2 ? data[iW - 2] : 0;
                        }
                        double v = floor(ols_pred(&OL[ch]) + 0.5);
                        pr[9] = v < 0 ? 0 : v > 255 ? 255 : (int)v;
                    }
                }
                int64_t num = 0, den = 0;
                for (int k = 0; k < np; k++) {
                    int s = 1;
                    if (hasW) s += perr[iW * np + k];
                    if (hasN) s += perr[iN * np + k];
                    if (hasN && hasW) s += perr[iNW * np + k];
                    if (hasNE) s += perr[iNE * np + k];
                    int64_t w = fblend1 ? (1LL << 24) / s : (1LL << 24) / ((int64_t)s * s);
                    num += w * pr[k]; den += w;
                }
                pred = (int)((num + den / 2) / den);
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
            if (!flite) {
                ctx[6] = H(16, chv, qe(eNW, 8) * 256 + qe(eNE, 8), act);
                ctx[7] = H(17, chv, qg(Wv - NWv) * 16 + qg(Nv - NWv), qg(NEv - Nv));
                ctx[8] = H(18, chv, ch ? qe(eP, 20) * 256 + qe(eP2, 20) : 255, pred >> 5);
                ctx[9] = H(19, chv, qe(pr[0] - pred, 24) * 256 + qe(pr[4] - pred, 24), 0);
                ctx[10] = H(20, chv, qe(pr[2] - pred, 24) * 256 + qe(pr[3] - pred, 24), 0);
                ctx[11] = H(21, chv, qe(Wv - pred, 24) * 256 + qe(Nv - pred, 24), qe(NEv - pred, 24));
            }
            if (fimgx) {
                int eWW = hasWW ? err[i - 6] : 0, eNN = hasNN ? err[iN - stride] : 0;
                ctx[12] = H(22, chv, (uint32_t)(Wv >> 3), (uint32_t)(Nv >> 3));
                ctx[13] = H(23, chv, qe(eWW, 12) * 256 + qe(eNN, 12), 0);
                ctx[14] = H(24, chv, (uint32_t)(pred >> 3), act);
                ctx[15] = H(25, chv, ch ? qe(eP, 8) : 255, qe(eW, 6) * 256 + qe(eN, 6));
            }
            if (XOLS) {
                int j = 12 + (fimgx ? 4 : 0);
                ctx[j] = H(26, chv, qe(pr[9] - pred, 40), 0);
                ctx[j + 1] = H(27, chv, qe(pr[9] - pred, 10) * 256 + (ch ? qe(eP, 10) : 255), qe(pr[0] - pred, 10));
            }
            {
                int j = 12 + (fimgx ? 4 : 0) + (XOLS ? 2 : 0);
                if (XCOL) ctx[j++] = H(28, chv, (uint32_t)(Wv | Nv << 8 | NWv << 16), (uint32_t)NEv);
                if (XCOL) ctx[j++] = H(29, chv, (uint32_t)((ch ? data[i - 1] : 0) | (ch == 2 ? data[i - 2] : 0) << 8 | Wv << 16), (uint32_t)(ch ? (i > 3 ? data[iW - 1] : 0) - data[i - 1] + 256 : 0) * 256 + (uint32_t)Nv);
                if (XIM) {   /* 2-D match: pixel seen after the same 4 neighbour pixels */
                    if (ch == 0) {
                        if (imlen > 0 && imok) { imptr++; if (imlen < 65535) imlen++; } else imlen = 0;
                        if (x >= 1 && y >= 1 && x < width - 1) {
                            int64_t a = iW, b = iN;
                            uint32_t hh = H(97, (uint32_t)(data[a] | data[a + 1] << 8 | data[a + 2] << 16), (uint32_t)(data[b] | data[b + 1] << 8 | data[b + 2] << 16),
                                            (uint32_t)(data[iNW] | data[iNW + 1] << 8 | data[iNW + 2] << 16) ^ (uint32_t)(data[iNE] | data[iNE + 1] << 8 | data[iNE + 2] << 16) * 0x9E3779B1u) >> (32 - MBITS);
                            if (imlen == 0 && IMT[hh]) { imptr = IMT[hh]; imlen = 1; }
                            IMT[hh] = (uint32_t)px;
                        }
                        imok = 1;
                    }
                    int ev = imlen ? data[imptr * 3 + ch] : -1;
                    ctx[j++] = H(30, chv, ev < 0 ? 999u : (uint32_t)(uint8_t)(ev - pred), (uint32_t)(imlen > 15 ? 15 : imlen));
                    imev = ev;
                    if (ev >= 0) { int sd = (int8_t)(uint8_t)(ev - pred); isym = sd >= 0 ? 2 * sd : -2 * sd - 1; iq = imlen > 15 ? 15 : imlen; } else isym = -1;
                }
            }
            if (!c->dec) { int s = (int8_t)(uint8_t)(data[i] - pred); sym = s >= 0 ? 2 * s : -2 * s - 1; }
        }
        int sel1 = img ? act : aud ? act + 16 * ch : (fmsel ? msel : 0);
        uint32_t c0 = 1, node = 1;
        int mmiss = 0, mmiss2 = 0; imiss = 0; int ieb = -1, iqq = 0;
        for (int bp = 0; bp < 8; bp++) {
            if (bp == 0 || bp == 4) {   /* hash all contexts, prefetch all buckets, then search */
                uint32_t hk[MAXIN];
                for (int k = 0; k < nctx; k++) {
                    hk[k] = nib_hash(ctx[k], c0);
                    uint32_t i0 = hk[k] >> (32 - tb[k]);
                    __builtin_prefetch(T[k] + ((size_t)i0 << 4));
                    __builtin_prefetch(T[k] + ((size_t)(i0 ^ 1) << 4));
                }
                for (int k = 0; k < nctx; k++) bk[k] = find_bucket(T[k], tb[k], hk[k]);
                node = 1;
                if (bp == 0) {
                    if (nrun) for (int k = 0; k < nctx; k++) {
                        rk[k] = bk[k]; uint32_t r = bk[k][0] >> 16;
                        rb[k] = r & 255; int rc = r >> 8; rq[k] = rc > 15 ? 15 : rc; rmiss[k] = rc == 0;
                    }
                    if (XORD) { hord = 0; for (int k = 0; k < nord; k++) if ((bk[k][1] >> 16) & 255) hord++; }
                }
            }
            int n = 0;
            uint32_t ev[MAXIN], sv[MAXIN];
            for (int k = 0; k < nctx; k++) { ev[k] = bk[k][node]; st[n++] = STRETCH[(ev[k] & 0xFFFF) >> 4]; }
            if (fhist) for (int k = 0; k < nctx; k++) {
                smi[k] = k * 256 + (int)(ev[k] >> 24);
                sv[k] = SM[smi[k]];
                st[n++] = STRETCH[(sv[k] & 0xFFFF) >> 4];
            }
            int eb = -1, mq = 0, eb2 = -1, mq2 = 0;
            for (int k = 0; k < nrun; k++) {
                if (!rmiss[k]) {
                    reb[k] = (rb[k] >> (7 - bp)) & 1;
                    int sp = STRETCH[RP[k * 64 + rq[k] * 2 + (bp == 0)] >> 4];
                    st[n++] = reb[k] ? sp : -sp;
                } else { reb[k] = -1; st[n++] = 0; }
            }
            if (nimm) {
                ieb = -1;
                if (isym >= 0 && !imiss) { ieb = (isym >> (7 - bp)) & 1; iqq = iq * 2 + (bp == 0); int sp = STRETCH[IMP[iqq] >> 4]; st[n++] = ieb ? sp : -sp; }
                else st[n++] = 0;
            }
            if (fmatch) {
                if (mb >= 0 && !mmiss) {
                    eb = (mb >> (7 - bp)) & 1; mq = lenq * 2 + (bp == 0);
                    int sp = STRETCH[MP[mq] >> 4];
                    st[n++] = eb ? sp : -sp;
                } else st[n++] = 0;
            }
            if (fm2nd) {
                if (mb2 >= 0 && !mmiss2) {
                    eb2 = (mb2 >> (7 - bp)) & 1; mq2 = lenq2 * 2 + (bp == 0);
                    int sp = STRETCH[MP2[mq2] >> 4];
                    st[n++] = eb2 ? sp : -sp;
                } else st[n++] = 0;
            }
            st[n++] = 256;   /* bias */
            if (XIM) sel1 = act + 16 * (isym < 0 ? 0 : imiss ? 1 : iq < 4 ? 2 : iq < 12 ? 3 : 4);
            int16_t *w1 = W1 + (bp * 256 + (XORD ? sel1 * 16 + hord : sel1)) * MAXIN;
            int16_t *w2 = W2 + (img ? ((bp * 3 + ch) * 32 + (ch ? (int)qe(eP, 15) - 49 : 0)) : aud ? ch * 256 + (int)c0 : (int)c0) * MAXIN;
            int16_t *w3 = W3 + ((img ? ch * 256 + (int)c0 : aud ? ((ch * 16 + act) * 8 + bp) + 1024 * (ach & 1) : (int)((c4 & 0xFF) << 3 | bp)) & 2047) * MAXIN;
            int32_t *wf = WF + (int)c0 * 4;
            int16_t *w4 = W4 + (img ? (bp * 3 + ch) * 32 + (np > 9 ? (int)qe(pr[9] - pred, 15) - 49 : 0) : aud ? (bp * 2 + ch) * 64 + aq : (int)((c4 >> 8 & 0xFF) << 3 | bp)) * MAXIN;
            int d = dot16(w1, st, nin), p1 = clampp(squash(d)), p2 = 0, p3 = 0, p4 = 0, pf = 0, dd[4] = {0, 0, 0, 0}, nm = XM4 ? 4 : 3;
            if (fmix2) {
                int d2 = dot16(w2, st, nin);
                p2 = clampp(squash(d2));
                d = (d + d2) >> 1;
            }
            if (fmix3) {   /* learned final mixer over the three mixer outputs */
                dd[0] = dot16(w1, st, nin); dd[1] = dot16(w2, st, nin); dd[2] = dot16(w3, st, nin);
                if (XM4) { dd[3] = dot16(w4, st, nin); dd[3] = dd[3] < -2047 ? -2047 : (dd[3] > 2047 ? 2047 : dd[3]); p4 = clampp(squash(dd[3])); }
                for (int k = 0; k < 3; k++) dd[k] = dd[k] < -2047 ? -2047 : (dd[k] > 2047 ? 2047 : dd[k]);
                p3 = clampp(squash(dd[2]));
                int64_t df = (int64_t)wf[0] * dd[0] + (int64_t)wf[1] * dd[1] + (int64_t)wf[2] * dd[2] + (int64_t)wf[3] * dd[3];
                d = (int)(df >> 16);
                pf = clampp(squash(d));
            }
            int p12 = squash(d), ai1 = 0, aw1 = 0, ai2 = 0, aw2 = 0, ai3 = 0, aw3 = 0, a3used = 0;
            if (fmix2) {
                int pa = apm_p(A1, img ? (((int)c0 * 16 + act) * 3 + ch) : aud ? (int)(c0 | (uint32_t)(act + 16 * ch) << 8) : (int)(c0 | (c4 & 255) << 8), d, &ai1, &aw1);
                if (fapm2) {
                    int pb = apm_p(A2, (int)(((H(77, c4 & 0xFFFF, 0, 0) >> 22) << 8) | c0), d, &ai2, &aw2);
                    p12 = (2 * p12 + 3 * pa + 3 * pb) >> 3;
                } else p12 = (p12 + 3 * pa) >> 2;
                if (fmapm && mb >= 0 && !mmiss) {
                    int a3 = (((mb + 256) >> (7 - bp)) & 255) | (lenq > 15 ? 15 : lenq) << 8 | 1 << 12;
                    p12 = (p12 + apm_p(A3, a3, d, &ai3, &aw3)) >> 1;
                    a3used = 1;
                }
            }
            p12 = clampp(p12);
            int bit = code_bit(c, p12, (sym >> (7 - bp)) & 1);
            upd16(w1, st, nin, (bit << 12) - p1);
            if (fmix2) {
                upd16(w2, st, nin, (bit << 12) - p2);
                if (fmix3) { upd16(w3, st, nin, (bit << 12) - p3); if (XM4) upd16(w4, st, nin, (bit << 12) - p4); { int el = ((bit << 12) - pf) * LR; for (int k = 0; k < nm; k++) { int32_t nw = wf[k] + ((dd[k] * el) >> 14); wf[k] = nw > (1 << 19) - 1 ? (1 << 19) - 1 : (nw < -(1 << 19) ? -(1 << 19) : nw); } } }
                apm_upd(A1, ai1, aw1, bit);
                if (fapm2) apm_upd(A2, ai2, aw2, bit);
                if (a3used) apm_upd(A3, ai3, aw3, bit);
            }
            for (int k = 0; k < nctx; k++) {
                uint32_t e = ev[k], p = e & 0xFFFF, cnt = (e >> 16) & 255, hb = e >> 24;
                int np2 = (int)p + (((((int)bit << 16) - (int)p) * RECIP[cnt]) >> 15);
                cnt += (int)cnt < limit;
                hb = (hb << 1) | bit;
                hb = hb >= 256 ? (hb & 0x7F) | 0x80 : hb;
                ev[k] = (uint32_t)np2 | cnt << 16 | hb << 24;
            }
            if (fhist) {
                for (int k = 0; k < nctx; k++) {
                    int sp = sv[k] & 0xFFFF, sn = sv[k] >> 16;
                    sp += (((bit << 16) - sp) * RECIP[sn]) >> 15;
                    sv[k] = (uint32_t)sp | (uint32_t)(sn < 255 ? sn + 1 : 255) << 16;
                }
                for (int k = 0; k < nctx; k++) SM[smi[k]] = sv[k];
            }
            for (int k = 0; k < nctx; k++) bk[k][node] = ev[k];
            for (int k = 0; k < nrun; k++) if (reb[k] >= 0) {
                int ok = bit == reb[k], j = k * 64 + rq[k] * 2 + (bp == 0), cnt = RN[j];
                RP[j] += (((ok << 16) - RP[j]) * RECIP[cnt]) >> 15;
                if (cnt < 255) RN[j] = cnt + 1;
                if (!ok) rmiss[k] = 1;
            }
            if (ieb >= 0) {
                int ok = bit == ieb, cnt = IMN[iqq];
                IMP[iqq] += (((ok << 16) - IMP[iqq]) * RECIP[cnt]) >> 15;
                if (cnt < 255) IMN[iqq] = cnt + 1;
                if (!ok) imiss = 1;
            }
            if (eb >= 0) {
                int ok = bit == eb, cnt = MN[mq];
                MP[mq] += (((ok << 16) - MP[mq]) * RECIP[cnt]) >> 15;
                if (cnt < 255) MN[mq] = cnt + 1;
                if (!ok) mmiss = 1;
            }
            if (eb2 >= 0) {
                int ok = bit == eb2, cnt = MN2[mq2];
                MP2[mq2] += (((ok << 16) - MP2[mq2]) * RECIP[cnt]) >> 15;
                if (cnt < 255) MN2[mq2] = cnt + 1;
                if (!ok) mmiss2 = 1;
            }
            c0 = c0 * 2 + bit;
            node = node * 2 + bit;
        }
        int v = c0 & 255;
        if (aud) {
            if (!(i & 1)) ahi = v;
            else {
                int64_t si = i >> 1;
                if (c->dec) {
                    int z = ahi << 8 | v, r = (z & 1) ? -((z + 1) >> 1) : (z >> 1), sv = (int16_t)(apred + r);
                    data[i - 1] = (uint8_t)sv; data[i] = (uint8_t)(sv >> 8);
                }
                int sv = SMP(si);
                aerr[si] = (int16_t)(sv - apred);
                if (si / nchan >= an1) { ols_upd(&AO[ach], sv); ols_upd(&AO[nchan + ach], sv); }
            }
        } else if (!img) {
            if (c->dec) data[i] = v;
            for (int k = 0; k < nrun; k++) {
                uint32_t r = rk[k][0] >> 16, b = r & 255, rc = r >> 8;
                if (rc && b == (uint32_t)v) { if (rc < 255) rc++; } else { b = v; rc = 1; }
                rk[k][0] = (rk[k][0] & 0xFFFF) | (b | rc << 8) << 16;
            }
            if (find) {
                IND1[c4 & 0xFF] = (uint16_t)(IND1[c4 & 0xFF] << 8 | data[i]);
                uint32_t h2 = H(52, c4 & 0xFFFF, 0, 0) >> 10;
                IND2[h2] = (uint16_t)(IND2[h2] << 8 | data[i]);
            }
            if (data[i] == '\n') { prevline = linestart; linestart = i + 1; indent = 0; inind = 1; }
            else if (inind && (data[i] == ' ' || data[i] == '\t')) indent++; else inind = 0;
            c8 = (c8 << 8) | (c4 >> 24); c4 = (c4 << 8) | data[i];
            if (fword) {
                int b = data[i];
                int isw = (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9') || b == '_' || b >= 128;
                if (isw) w0 = (w0 + (uint32_t)(b | 32) + 1) * 0x01000193u;
                else if (w0) { w2 = w1; w1 = w0; w0 = 0; }
            }
        } else {
            if (c->dec) { int s = (v & 1) ? -((v + 1) >> 1) : (v >> 1); data[i] = (uint8_t)(pred + s); }
            err[i] = (int8_t)(uint8_t)(data[i] - pred);
            for (int k = 0; k < np; k++) { int ek = iabs(data[i] - pr[k]); perr[i * np + k] = ek > 255 ? 255 : ek; }
            if (imev >= 0 && data[i] != imev) imok = 0;
            if (XOLS && oin) ols_upd(&OL[ch], data[i]);
        }
    }
    for (int k = 0; k < nctx; k++) free(T[k]);
    free(SM); free(W1); free(W2); free(W3); free(WF); free(A1); free(A2); free(A3);
    free(MT); free(MT2); free(IND1); free(IND2); free(err); free(perr); free(AO); free(aerr);
}

static int e8e9_detect(const uint8_t *d, int64_t n) {
    int64_t cnt = 0, good = 0;
    for (int64_t i = 0; i + 4 < n; i++) if (d[i] == 0xE8 || d[i] == 0xE9) { cnt++; if (d[i + 4] == 0 || d[i + 4] == 0xFF) good++; }
    return cnt > n / 256 && good * 2 > cnt;
}
/* x86 CALL/JMP rel32 <-> absolute; positions are decided by the opcode byte, which never changes */
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
static void header(uint8_t *h, int mode, int bb, int limit, int lr, uint32_t feat, uint32_t feat2, int64_t width, int64_t L) {
    memcpy(h, "FM4\x01", 4); h[4] = mode; h[5] = bb; h[6] = limit; h[7] = lr;
    put32(h + 8, feat); put32(h + 12, (uint32_t)width); put32(h + 16, (uint32_t)L); put32(h + 20, (uint32_t)((uint64_t)L >> 32));
    put32(h + 24, feat2);
}
/* Levels (feat, feat2):
 *   bytes 1: orders 1-3 + match                    2: orders 0-4,6, match, words, mixer2/APM, hit-count mixer select
 *         3: + order-2 APM, sparse, indirect, match APM, 2nd match, column/word-pair, 4 text contexts
 *         4: + bit-history inputs, orders 5/7, 4-mixer network     5: + run inputs, 2x tables
 *   image 1: MED + 6 contexts                      2: 9-predictor blend + 12 contexts + 2-D match
 *         3: + mixer2/APM + exact-colour contexts  4: + 4 contexts, OLS predictor, 4-mixer network
 *         5: + wide OLS */
#define B_L1 ((1u << 21) | 1 | 4)
#define B_L2 (1u | 2 | 4 | 32)
#define B_L3 (B_L2 | 8 | 128 | 32768 | 65536 | 131072 | 262144)
#define B_L4 (B_L3 | 16 | 256 | 2048)
#define I_L1 (1u << 21)
#define I_L2 (1u << 20)
#define I_L3 (I_L2 | 32)
#define I_L4 (I_L3 | 256 | 512)
static uint8_t *fm4_encode(int level, int mode, int64_t width, uint8_t *data, int64_t L, int64_t *outLen) {
    static const uint32_t BL[6] = {0, B_L1, B_L2, B_L3, B_L4, B_L4}, IL[6] = {0, I_L1, I_L2, I_L3, I_L4, I_L4};
    static const uint32_t BL2[6] = {0, 0, 1, 1 | 4, 1 | 2 | 4, 1 | 2 | 4 | 8}, IL2[6] = {0, 0, 128, 128 | 64, 128 | 64 | 16 | 2, 128 | 64 | 16 | 2 | 32};
    static const uint32_t AL[6] = {0, 0, 32, 32 | 256, 32 | 256 | 2048, 32 | 256 | 2048}, AL2[6] = {0, 0, 0, 2, 2 | 32, 2 | 32};
    uint32_t feat = mode == 2 ? IL[level] : mode == 3 ? AL[level] : BL[level], feat2 = mode == 2 ? IL2[level] : mode == 3 ? AL2[level] : BL2[level];
    int bb = level == 5 && mode == 1 ? 19 : 18, limit = 255;
    if (getenv("FEAT")) feat = (uint32_t)atoi(getenv("FEAT"));
    if (getenv("FEAT2")) feat2 = (uint32_t)atoi(getenv("FEAT2"));
    if (getenv("BB")) bb = atoi(getenv("BB"));
    uint8_t *best = NULL; int64_t bestLen = 0;
    if (level > 0) {
        feat &= ~64u;
        if (mode == 1 && e8e9_detect(data, L)) { e8e9(data, L, 1); feat |= 64; }
        Coder c = {0, 0xFFFFFFFFu, 0, NULL, 0, 0, 0, 0};
        for (int i = 0; i < HDR; i++) emit(&c, 0);
        run(&c, mode, bb, limit, feat, feat2, width, data, L);
        for (int i = 3; i >= 0; i--) emit(&c, c.x1 >> (8 * i));
        while (c.len > HDR && c.buf[c.len - 1] == 0) c.len--;
        header(c.buf, mode, bb, limit, LR, feat, feat2, width, L);
        best = c.buf; bestLen = c.len;
        if (feat & 64) e8e9(data, L, 0);
    }
    if (!best || bestLen >= L + HDR) {   /* store */
        free(best);
        best = malloc(L + HDR);
        header(best, 0, 0, 0, 0, 0, 0, width, L);
        memcpy(best + HDR, data, L); bestLen = L + HDR;
    }
    *outLen = bestLen;
    return best;
}
static uint8_t *fm4_decode(uint8_t *f, int64_t n, int64_t *outLen) {
    if (n < HDR || memcmp(f, "FM4\x01", 4)) return NULL;
    int mode = f[4], bb = f[5], limit = f[6]; uint32_t feat = get32(f + 8), feat2 = get32(f + 24);
    int64_t width = get32(f + 12), L = (int64_t)get32(f + 16) | (int64_t)get32(f + 20) << 32;
    uint8_t *data = malloc(L ? L : 1);
    if (mode == 0) memcpy(data, f + HDR, L);
    else {
        LR = f[7];
        Coder c = {0, 0xFFFFFFFFu, 0, f + HDR, n - HDR, 0, 0, 1};
        for (int i = 0; i < 4; i++) c.x = (c.x << 8) | (c.pos < c.len ? c.buf[c.pos] : 0), c.pos++;
        run(&c, mode, bb, limit, feat, feat2, width, data, L);
        if (feat & 64) e8e9(data, L, 0);
    }
    *outLen = L;
    return data;
}

static uint8_t *slurp(const char *path, int64_t *n) {
    FILE *f = fopen(path, "rb"); if (!f) { perror(path); exit(1); }
    fseek(f, 0, SEEK_END); *n = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *b = malloc(*n ? *n : 1);
    if ((int64_t)fread(b, 1, *n, f) != *n) { perror("read"); exit(1); }
    fclose(f); return b;
}
static int spit(const char *path, uint8_t *b, int64_t n) {
    FILE *f = fopen(path, "wb"); if (!f) { perror(path); return 1; }
    fwrite(b, 1, n, f); fclose(f); return 0;
}
int main(int argc, char **argv) {
    init_tables();
    if (getenv("HUGE")) OPT_HUGE = atoi(getenv("HUGE"));
    if (argc >= 6 && !strcmp(argv[1], "enc")) {
        int level = atoi(argv[2]), mode = !strcmp(argv[3], "image") ? 2 : !strcmp(argv[3], "audio") ? 3 : 1;
        int64_t width = mode >= 2 ? atoll(argv[4]) : 0, L, n;
        if (level < 0 || level > 5 || (mode >= 2 && argc < 7)) goto usage;
        if (getenv("LR")) LR = atoi(getenv("LR"));
        uint8_t *data = slurp(argv[mode >= 2 ? 5 : 4], &L);
        if (mode == 2 && (width <= 0 || L % (3 * width))) { fprintf(stderr, "bad width\n"); return 1; }
        if (mode == 3 && (width <= 0 || width > 8 || L % (2 * width))) { fprintf(stderr, "audio: need 1-8 channels and a whole number of 16-bit frames\n"); return 1; }
        uint8_t *o = fm4_encode(level, mode, width, data, L, &n);
        return spit(argv[mode >= 2 ? 6 : 5], o, n);
    }
    if (argc == 4 && !strcmp(argv[1], "dec")) {
        int64_t n, L; uint8_t *f = slurp(argv[2], &n);
        uint8_t *d = fm4_decode(f, n, &L);
        if (!d) { fprintf(stderr, "not an FM4 file\n"); return 1; }
        return spit(argv[3], d, L);
    }
usage:
    fprintf(stderr, "usage: fm4 enc LEVEL(0-5) bytes IN OUT | fm4 enc LEVEL image WIDTH IN OUT | fm4 dec IN OUT\n"
                    "       env FEAT overrides the level's feature set; BB, LIMIT, LR, HUGE for experiments\n");
    return 2;
}
