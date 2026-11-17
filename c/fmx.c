/* fmx: experimental image model v2 for fm (raw RGB24 only).
 *   fmx enc WIDTH IN OUT | fmx dec IN OUT          FEAT=<bitmask> env selects features (default all)
 * Features (bit): 0 zigzag residuals   1 blend of predictors weighted by local error
 *                 2 cross-channel predictor   3 extra neighbour contexts
 *                 4 mixer weights selected by local activity   5 APM/SSE refinement stage
 * Same coder/counter/squash as fm.c; file header "FRX2" | feat u8 | width u32 | L u32 | N bytes.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define TBITS 22
#define TSIZE (1u << TBITS)
#define TMASK (TSIZE - 1)
#define NIN 12
#define NPRED 9

static int SQ_T[33] = {1, 2, 3, 6, 10, 16, 27, 45, 73, 120, 194, 310, 488, 747, 1101, 1546, 2047,
                       2549, 2994, 3348, 3607, 3785, 3901, 3975, 4022, 4050, 4068, 4079, 4085, 4089, 4092, 4093, 4094};
static int STRETCH[4096], RECIP[256];
static int LIMIT = 255;
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
typedef struct { uint32_t x1, x2, x; uint8_t *buf; size_t len, pos, cap; int dec; } Coder;
static int code_bit(Coder *c, int p12, int bit) {
    uint32_t xmid = c->x1 + ((c->x2 - c->x1) >> 12) * (uint32_t)p12;
    if (c->dec) bit = c->x <= xmid;
    if (bit) c->x2 = xmid; else c->x1 = xmid + 1;
    while (((c->x1 ^ c->x2) & 0xFF000000u) == 0) {
        if (c->dec) { c->x = (c->x << 8) | (c->pos < c->len ? c->buf[c->pos] : 0); c->pos++; }
        else { if (c->len == c->cap) { c->cap = c->cap ? c->cap * 2 : 1 << 16; c->buf = realloc(c->buf, c->cap); } c->buf[c->len++] = c->x2 >> 24; }
        c->x1 <<= 8; c->x2 = (c->x2 << 8) | 255;
    }
    return bit;
}

static inline int clamp255(int v) { return v < 0 ? 0 : (v > 255 ? 255 : v); }
static inline int iabs(int v) { return v < 0 ? -v : v; }
static inline int bitlen(int v) { return v > 0 ? 32 - __builtin_clz(v) : 0; }
static inline uint32_t qe(int e, int lim) { return (uint32_t)((e < -lim ? -lim : (e > lim ? lim : e)) + 64); }
/* JPEG-LS style gradient quantizer */
static inline uint32_t qg(int d) {
    int s = d < 0 ? -1 : 1, a = iabs(d), q = a == 0 ? 0 : a < 3 ? 1 : a < 7 ? 2 : a < 21 ? 3 : 4;
    return (uint32_t)(s * q + 8);
}

static void run(Coder *c, int feat, int width, uint8_t *data, int64_t L) {
    int nin = (feat & 64) ? 12 : (feat & 8) ? 9 : 6;
    uint16_t *P = malloc((size_t)TSIZE * nin * 2); uint8_t *N = calloc((size_t)TSIZE * nin, 1);
    for (size_t j = 0; j < (size_t)TSIZE * nin; j++) P[j] = 32768;
    int nsets = 8 * 16;
    int32_t *W = malloc(sizeof(int32_t) * nsets * NIN);
    for (int j = 0; j < nsets * NIN; j++) W[j] = 19661 * 6 / nin;
    int32_t *W2 = malloc(sizeof(int32_t) * 8 * 3 * 32 * NIN);
    for (int j = 0; j < 8 * 3 * 32 * NIN; j++) W2[j] = 19661 * 6 / nin;
    int p2save = 2048;
    /* APM: 256 c0 x 16 activity x 3 ch contexts, 33 buckets */
    int napm = 256 * 16 * 3;
    uint16_t *A = malloc(sizeof(uint16_t) * napm * 33);
    for (int k = 0; k < napm; k++) for (int j = 0; j < 33; j++) A[k * 33 + j] = squash((j - 16) * 128) * 16;
    int16_t *err = calloc(L + 1, 2);           /* signed residual of the final predictor */
    uint8_t *perr = calloc((L + 1) * NPRED, 1); /* |error| of each predictor, for blending */
    int64_t stride = 3 * (int64_t)width;
    uint32_t ctx[NIN], idx[NIN]; int st[NIN];

    for (int64_t i = 0; i < L; i++) {
        int ch = i % 3; int64_t px = i / 3; int x = px % width; int y = px / width;
        int hasW = x > 0, hasN = y > 0, hasNE = y > 0 && x < width - 1, hasWW = x > 1, hasNN = y > 1;
        int64_t iW = i - 3, iN = i - stride, iNW = iN - 3, iNE = iN + 3, iWW = i - 6, iNN = iN - stride;
        int Wv = hasW ? data[iW] : (hasN ? data[iN] : 0);
        int Nv = hasN ? data[iN] : Wv;
        int NWv = (hasN && hasW) ? data[iNW] : Nv;
        int NEv = hasNE ? data[iNE] : Nv;
        int WWv = hasWW ? data[iWW] : Wv;
        int NNv = hasNN ? data[iNN] : Nv;
        (void)WWv; (void)NNv;
        int mx = Wv > Nv ? Wv : Nv, mn = Wv < Nv ? Wv : Nv;
        int pr[NPRED];
        pr[0] = NWv >= mx ? mn : (NWv <= mn ? mx : Wv + Nv - NWv);       /* MED */
        pr[1] = clamp255(Wv + Nv - NWv);                                 /* plane */
        pr[2] = (Wv + NEv + 1) >> 1;                                     /* W/NE average */
        pr[3] = clamp255(Nv + ((Wv - NWv + NEv - Nv) >> 1));             /* gradient-adjusted */
        pr[4] = pr[0];
        pr[5] = Wv; pr[6] = Nv; pr[7] = clamp255(2 * Wv - WWv); pr[8] = clamp255(2 * Nv - NNv);
        if ((feat & 4) && ch > 0) {                                      /* cross-channel: reuse prev channel's delta */
            int pw = hasW ? data[iW - 1] : (hasN ? data[iN - 1] : 0);
            int pn = hasN ? data[iN - 1] : pw;
            int pnw = (hasN && hasW) ? data[iNW - 1] : pn;
            int pmx = pw > pn ? pw : pn, pmn = pw < pn ? pw : pn;
            int pmed = pnw >= pmx ? pmn : (pnw <= pmn ? pmx : pw + pn - pnw);
            pr[4] = clamp255(pr[0] + (data[i - 1] - pmed));
        }
        int pred;
        if (feat & 2) {
            int64_t num = 0, den = 0;
            int np = (feat & 128) ? 9 : (feat & 4) ? 5 : 4;
            if ((feat & 128) == 0 && np == 9) np = 5;
            for (int k = 0; k < np; k++) {
                if (k == 4 && !(feat & 4)) continue;
                int s = 1;
                if (hasW) s += perr[iW * NPRED + k];
                if (hasN) s += perr[iN * NPRED + k];
                if (hasN && hasW) s += perr[iNW * NPRED + k];
                if (hasNE) s += perr[iNE * NPRED + k];
                int64_t w = (1LL << 24) / ((int64_t)s * s);
                num += w * pr[k]; den += w;
            }
            pred = (int)((num + den / 2) / den);
        } else pred = (feat & 4) && ch > 0 ? pr[4] : pr[0];

        int eW = hasW ? err[iW] : 0, eN = hasN ? err[iN] : 0, eNW = (hasN && hasW) ? err[iNW] : 0;
        int eNE = hasNE ? err[iNE] : 0, eP = ch ? err[i - 1] : 0, eP2 = ch == 2 ? err[i - 2] : 0;
        int act = bitlen(iabs(eW) + iabs(eN) + iabs(eNW) + iabs(eNE)); /* 0..10 */
        if (act > 15) act = 15;
        uint32_t chv = ch, pch = ch ? 0 : 99;
        ctx[0] = H(10, chv, 0, 0);
        ctx[1] = H(11, chv, qe(eW, 12), 0);
        ctx[2] = H(12, chv, qe(eN, 12), 0);
        ctx[3] = H(13, chv, ch ? qe(eP, 12) : 255, pch);
        ctx[4] = H(14, chv, qe(eW, 12), qe(eN, 12));
        ctx[5] = H(15, chv, ch ? qe(eP, 12) : 255, act);
        if (feat & 8) {
            ctx[6] = H(16, chv, qe(eNW, 8) * 256 + qe(eNE, 8), act);
            ctx[7] = H(17, chv, qg(Wv - NWv) * 16 + qg(Nv - NWv), qg(NEv - Nv));
            ctx[8] = H(18, chv, ch ? qe(eP, 20) * 256 + qe(eP2, 20) : 255, pred >> 5);
        }
        if (feat & 64) {   /* where do the individual predictors disagree with the blend? */
            ctx[9]  = H(19, chv, qe(pr[0] - pred, 24) * 256 + qe(pr[4] - pred, 24), 0);
            ctx[10] = H(20, chv, qe(pr[2] - pred, 24) * 256 + qe(pr[3] - pred, 24), 0);
            ctx[11] = H(21, chv, qe(Wv - pred, 24) * 256 + qe(Nv - pred, 24), qe(NEv - pred, 24));
        }
        int sym;
        if (!c->dec) {
            int s = (int8_t)(uint8_t)(data[i] - pred);        /* residual mod 256 as signed -128..127 */
            sym = (feat & 1) ? (s >= 0 ? 2 * s : -2 * s - 1) : (s & 255);
        } else sym = 0;
        int wsel = (feat & 16) ? act : 0;
        uint32_t c0 = 1;
        for (int bp = 0; bp < 8; bp++) {
            int32_t *w = W + ((bp * 16 + wsel) * NIN);
            int64_t dot = 0;
            for (int k = 0; k < nin; k++) {
                idx[k] = (uint32_t)k * TSIZE + ((ctx[k] + c0 * 0x9E3779B1u) & TMASK);
                st[k] = STRETCH[P[idx[k]] >> 4];
                dot += (int64_t)w[k] * st[k];
            }
            int d = (int)(dot >> 16);
            int32_t *w2 = W2 + ((bp * 3 + ch) * 32 + (ch ? (int)qe(eP, 15) - 49 : 0)) * NIN;
            int64_t dot2 = 0;
            if (feat & 256) {
                for (int k = 0; k < nin; k++) dot2 += (int64_t)w2[k] * st[k];
                int d2 = (int)(dot2 >> 16);
                p2save = squash(d2);
                d = (d + d2) >> 1;
            }
            int p12 = squash(d);
            int aidx = 0, awt = 0;
            if (feat & 32) {
                int ds = d < -2047 ? -2047 : (d > 2047 ? 2047 : d);
                int a = (((int)c0 * 16 + act) * 3 + ch);
                int pos = (ds + 2048) * 32;
                int j = pos >> 12; awt = pos & 4095;
                aidx = a * 33 + j;
                int pa = (A[aidx] * (4096 - awt) + A[aidx + 1] * awt) >> 16;
                p12 = (p12 + 3 * pa) >> 2;
            }
            p12 = p12 < 1 ? 1 : (p12 > 4095 ? 4095 : p12);
            int bit = code_bit(c, p12, (sym >> (7 - bp)) & 1);
            int e = (bit << 12) - p12;
            if (feat & 256) {
                int e2 = (bit << 12) - p2save;
                for (int k = 0; k < nin; k++) {
                    int32_t nw = w2[k] + ((st[k] * e2 * 20) >> 14);
                    w2[k] = nw > (1 << 22) ? (1 << 22) : (nw < -(1 << 22) ? -(1 << 22) : nw);
                }
            }
            for (int k = 0; k < nin; k++) {
                int32_t nw = w[k] + ((st[k] * e * 20) >> 14);
                w[k] = nw > (1 << 22) ? (1 << 22) : (nw < -(1 << 22) ? -(1 << 22) : nw);
                uint32_t j = idx[k]; int n = N[j];
                int p = P[j] + ((((bit << 16) - P[j]) * RECIP[n]) >> 15);
                P[j] = p < 0 ? 0 : (p > 65535 ? 65535 : p);
                if (n < LIMIT) N[j] = n + 1;
            }
            if (feat & 32) {
                int g = (bit << 16) + (bit << 5) - bit - bit;
                int j = awt >> 11 ? aidx + 1 : aidx;
                A[j] += (g - A[j]) >> 6;
            }
            c0 = c0 * 2 + bit;
        }
        int v = c0 & 255;
        if (c->dec) {
            int s = (feat & 1) ? ((v & 1) ? -((v + 1) >> 1) : (v >> 1)) : (int8_t)v;
            data[i] = (uint8_t)(pred + s);
        }
        err[i] = (int8_t)(uint8_t)(data[i] - pred);
        for (int k = 0; k < NPRED; k++) { int ek = iabs(data[i] - pr[k]); perr[i * NPRED + k] = ek > 255 ? 255 : ek; }
    }
    free(P); free(N); free(W); free(W2); free(A); free(err); free(perr);
}

static uint8_t *slurp(const char *path, size_t *n) {
    FILE *f = fopen(path, "rb"); if (!f) { perror(path); exit(1); }
    fseek(f, 0, SEEK_END); *n = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *b = malloc(*n ? *n : 1);
    if (fread(b, 1, *n, f) != *n) { perror("read"); exit(1); }
    fclose(f); return b;
}
static void put32(uint8_t *p, uint32_t v) { for (int i = 0; i < 4; i++) p[i] = v >> (8 * i); }
static uint32_t get32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }

int main(int argc, char **argv) {
    init_tables();

    if (argc == 5 && !strcmp(argv[1], "enc")) {
        int feat = getenv("FEAT") ? atoi(getenv("FEAT")) : 511;
        int width = atoi(argv[2]); size_t L; uint8_t *data = slurp(argv[3], &L);
        if (width <= 0 || L % (3 * (size_t)width)) { fprintf(stderr, "bad width\n"); return 1; }
        Coder c = {0, 0xFFFFFFFFu, 0, NULL, 0, 0, 0, 0};
        run(&c, feat, width, data, (int64_t)L);
        for (int i = 3; i >= 0; i--) { if (c.len == c.cap) { c.cap = c.cap ? c.cap * 2 : 16; c.buf = realloc(c.buf, c.cap); } c.buf[c.len++] = c.x1 >> (8 * i); }
        while (c.len && c.buf[c.len - 1] == 0) c.len--;
        uint8_t hdr[13] = {'F', 'R', 'X', (uint8_t)(feat >> 8), (uint8_t)(feat & 255)}; put32(hdr + 5, width); put32(hdr + 9, (uint32_t)L);
        FILE *f = fopen(argv[4], "wb"); fwrite(hdr, 1, 13, f); fwrite(c.buf, 1, c.len, f); fclose(f);
        return 0;
    }
    if (argc == 4 && !strcmp(argv[1], "dec")) {
        size_t n; uint8_t *f = slurp(argv[2], &n);
        if (n < 13 || memcmp(f, "FRX", 3)) { fprintf(stderr, "not FRX2\n"); return 1; }
        int feat = f[3] << 8 | f[4]; int width = get32(f + 5); uint32_t L = get32(f + 9);
        Coder c = {0, 0xFFFFFFFFu, 0, f + 13, n - 13, 0, 0, 1};
        for (int i = 0; i < 4; i++) c.x = (c.x << 8) | (c.pos < c.len ? c.buf[c.pos] : 0), c.pos++;
        uint8_t *data = malloc(L ? L : 1);
        run(&c, feat, width, data, L);
        FILE *o = fopen(argv[3], "wb"); fwrite(data, 1, L, o); fclose(o);
        return 0;
    }
    fprintf(stderr, "usage: fmx enc WIDTH IN OUT | fmx dec IN OUT   (env FEAT=bitmask, default 63)\n");
    return 2;
}
