/* fm2: model-fraction codec with compression levels. Reference implementation = the spec;
 * BPL and JS ports must produce byte-identical output.
 *
 *   fm2 enc LEVEL bytes IN OUT          LEVEL 0..5 (0 = store)
 *   fm2 enc LEVEL image WIDTH IN OUT    IN = raw RGB24 pixels
 *   fm2 dec IN OUT
 *
 * Container (20-byte header): "FM2" 0x01 | mode u8 (0 store,1 bytes,2 image) | profile u8 |
 *   limit u8 | 0 u8 | width u32le | L u64le | payload (store: raw bytes; else N, the fraction
 *   digits: data = model-decode(N / 256^len)). The decoder needs only the header, never the level.
 *
 * Levels (encoder side only): each picks (profile, counter limit) candidates; >1 candidate = one
 * pass per candidate, smallest wins. Any result >= input size falls back to store.
 *   bytes: 1 (1,60)  2 (2,60)  3 (3,60)  4 (4,255)  5 {(4,255),(4,60),(3,255)}
 *   image: 1 (1,60)  2 (2,60)  3 (3,255) 4 (4,255)  5 (4,255) (extra passes found nothing for images)
 * Profiles:
 *   bytes 1: order-2 context, counter probability used directly (no mixer)  -- 1 lookup/bit
 *   bytes 2: orders 1,2,3 mixed                                             -- 3 lookups/bit
 *   bytes 3: orders 0,1,2,3,4,6 mixed (same model as fm v1)                 -- 6 lookups/bit
 *   bytes 4: profile 3 + second mixer (selected by partial byte) + APM        -- 6 lookups/bit
 *   image 1: MED predictor, 3 contexts
 *   image 2: MED predictor, 6 contexts
 *   image 3: 5-predictor error-weighted blend (incl. cross-channel), 9 contexts, mixer by activity
 *   image 4: 9-predictor blend, 12 contexts, second mixer, APM
 * Shared integer spec: see H(), squash/stretch tables, counters (p += (bit*65536-p)*RECIP[n]>>15,
 * RECIP[n]=65536/(2n+3), n++ while n<limit), mixers (w init 19661*6/nin, dot>>16, each mixer
 * trains on its own clamped output: w += st*err*20>>14, clamp +-2^22), 32-bit binary arithmetic
 * coder (p12 = P(bit=1), emit top byte when x1,x2 agree, flush x1, strip trailing zeros).
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define TBITS 22
#define TSIZE (1u << TBITS)
#define TMASK (TSIZE - 1)
#define MAXIN 12
#define NPRED 9
#define HDR 20

static int SQ_T[33] = {1, 2, 3, 6, 10, 16, 27, 45, 73, 120, 194, 310, 488, 747, 1101, 1546, 2047,
                       2549, 2994, 3348, 3607, 3785, 3901, 3975, 4022, 4050, 4068, 4079, 4085, 4089, 4092, 4093, 4094};
static int STRETCH[4096], RECIP[256];

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
static inline int clamp255(int v) { return v < 0 ? 0 : (v > 255 ? 255 : v); }
static inline int clampp(int p) { return p < 1 ? 1 : (p > 4095 ? 4095 : p); }
static inline int iabs(int v) { return v < 0 ? -v : v; }
static inline int bitlen(int v) { return v > 0 ? 32 - __builtin_clz(v) : 0; }
static inline uint32_t qe(int e, int lim) { return (uint32_t)((e < -lim ? -lim : (e > lim ? lim : e)) + 64); }
static inline uint32_t qg(int d) {
    int a = iabs(d), q = a == 0 ? 0 : a < 3 ? 1 : a < 7 ? 2 : a < 21 ? 3 : 4;
    return (uint32_t)((d < 0 ? -q : q) + 8);
}

/* ---- arithmetic coder ---- */
typedef struct { uint32_t x1, x2, x; uint8_t *buf; int64_t len, pos, cap; int dec; } Coder;
static void emit(Coder *c, uint8_t b) {
    if (c->len == c->cap) { c->cap = c->cap ? c->cap * 2 : 1 << 16; c->buf = realloc(c->buf, c->cap); }
    c->buf[c->len++] = b;
}
static int code_bit(Coder *c, int p12, int bit) {
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

/* ---- model ---- */
static void run(Coder *c, int mode, int prof, int limit, int64_t width, uint8_t *data, int64_t L) {
    int img = mode == 2;
    static const int NIN_B[5] = {0, 1, 3, 6, 6}, NIN_I[5] = {0, 3, 6, 9, 12};
    int nin = img ? NIN_I[prof] : NIN_B[prof];
    int direct = !img && prof == 1, mix2 = prof == 4, apm = prof == 4;
    int np = img ? (prof == 3 ? 5 : prof == 4 ? 9 : 0) : 0;
    uint16_t *P = malloc((size_t)TSIZE * nin * 2);
    uint8_t *N = calloc((size_t)TSIZE * nin, 1);
    for (size_t j = 0; j < (size_t)TSIZE * nin; j++) P[j] = 32768;
    int32_t winit = 19661 * 6 / nin;
    int32_t *W1 = malloc(sizeof(int32_t) * 128 * MAXIN), *W2 = malloc(sizeof(int32_t) * 768 * MAXIN);
    for (int j = 0; j < 128 * MAXIN; j++) W1[j] = winit;
    for (int j = 0; j < 768 * MAXIN; j++) W2[j] = winit;
    int napm = apm ? (img ? 256 * 16 * 3 : 65536) : 0;
    uint16_t *A = malloc(sizeof(uint16_t) * (napm ? napm : 1) * 33);
    for (int k = 0; k < napm; k++) for (int j = 0; j < 33; j++) A[k * 33 + j] = squash((j - 16) * 128) * 16;
    int16_t *err = img ? calloc(L + 1, 2) : NULL;
    uint8_t *perr = np ? calloc((L + 1) * np, 1) : NULL;
    int64_t stride = 3 * width;
    uint32_t ctx[MAXIN], idx[MAXIN], c4 = 0, c8 = 0;
    int st[MAXIN];
    static const int ORD2[3] = {1, 2, 3}, ORD3[6] = {0, 1, 2, 3, 4, 6};

    for (int64_t i = 0; i < L; i++) {
        int ch = 0, act = 0, eP = 0, pred = 0, sym = 0, pr[NPRED];
        if (!img) {
            if (prof == 1) ctx[0] = H(2, c4 & 0xFFFF, 0, 0);
            else for (int k = 0; k < nin; k++) {
                int o = prof == 2 ? ORD2[k] : ORD3[k];
                uint32_t m = o >= 4 ? 0xFFFFFFFFu : ((1u << (8 * o)) - 1);
                ctx[k] = H(o, c4 & m, o == 6 ? (c8 & 0xFFFF) : 0, 0);
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
            pred = pr[0];
            if (np) {
                pr[1] = clamp255(Wv + Nv - NWv);
                pr[2] = (Wv + NEv + 1) >> 1;
                pr[3] = clamp255(Nv + ((Wv - NWv + NEv - Nv) >> 1));
                pr[4] = pr[0];
                if (ch > 0) {   /* cross-channel: MED of this channel + previous channel's MED error */
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
            }
            int eW = hasW ? err[iW] : 0, eN = hasN ? err[iN] : 0, eNW = (hasN && hasW) ? err[iNW] : 0;
            int eNE = hasNE ? err[iNE] : 0, eP2 = ch == 2 ? err[i - 2] : 0;
            eP = ch ? err[i - 1] : 0;
            act = bitlen(iabs(eW) + iabs(eN) + iabs(eNW) + iabs(eNE));
            if (act > 15) act = 15;
            uint32_t chv = ch, qp = ch ? qe(eP, 12) : 255;
            if (prof == 1) {
                ctx[0] = H(10, chv, 0, 0); ctx[1] = H(14, chv, qe(eW, 12), qe(eN, 12)); ctx[2] = H(15, chv, qp, act);
            } else {
                ctx[0] = H(10, chv, 0, 0);
                ctx[1] = H(11, chv, qe(eW, 12), 0);
                ctx[2] = H(12, chv, qe(eN, 12), 0);
                ctx[3] = H(13, chv, qp, ch ? 0 : 99);
                ctx[4] = H(14, chv, qe(eW, 12), qe(eN, 12));
                ctx[5] = H(15, chv, qp, act);
                if (prof >= 3) {
                    ctx[6] = H(16, chv, qe(eNW, 8) * 256 + qe(eNE, 8), act);
                    ctx[7] = H(17, chv, qg(Wv - NWv) * 16 + qg(Nv - NWv), qg(NEv - Nv));
                    ctx[8] = H(18, chv, ch ? qe(eP, 20) * 256 + qe(eP2, 20) : 255, pred >> 5);
                }
                if (prof == 4) {
                    ctx[9] = H(19, chv, qe(pr[0] - pred, 24) * 256 + qe(pr[4] - pred, 24), 0);
                    ctx[10] = H(20, chv, qe(pr[2] - pred, 24) * 256 + qe(pr[3] - pred, 24), 0);
                    ctx[11] = H(21, chv, qe(Wv - pred, 24) * 256 + qe(Nv - pred, 24), qe(NEv - pred, 24));
                }
            }
            if (!c->dec) { int s = (int8_t)(uint8_t)(data[i] - pred); sym = s >= 0 ? 2 * s : -2 * s - 1; }
        }
        int sel1 = img && prof >= 3 ? act : 0;
        uint32_t c0 = 1;
        for (int bp = 0; bp < 8; bp++) {
            int p12, p1 = 0, p2 = 0, aidx = 0, awt = 0;
            int32_t *w1 = W1 + (bp * 16 + sel1) * MAXIN;
            int32_t *w2 = W2 + (img ? ((bp * 3 + ch) * 32 + (ch ? (int)qe(eP, 15) - 49 : 0)) : (int)c0) * MAXIN;
            for (int k = 0; k < nin; k++) {
                idx[k] = (uint32_t)k * TSIZE + ((ctx[k] + c0 * 0x9E3779B1u) & TMASK);
                st[k] = STRETCH[P[idx[k]] >> 4];
            }
            if (direct) p12 = clampp(P[idx[0]] >> 4);
            else {
                int64_t dot = 0;
                for (int k = 0; k < nin; k++) dot += (int64_t)w1[k] * st[k];
                int d = (int)(dot >> 16);
                p1 = clampp(squash(d));
                if (mix2) {
                    int64_t dot2 = 0;
                    for (int k = 0; k < nin; k++) dot2 += (int64_t)w2[k] * st[k];
                    int d2 = (int)(dot2 >> 16);
                    p2 = clampp(squash(d2));
                    d = (d + d2) >> 1;
                }
                p12 = squash(d);
                if (apm) {
                    int ds = d < -2047 ? -2047 : (d > 2047 ? 2047 : d);
                    int a = img ? (((int)c0 * 16 + act) * 3 + ch) : (int)(c0 | (c4 & 255) << 8);
                    int pos = (ds + 2048) * 32;
                    awt = pos & 4095; aidx = a * 33 + (pos >> 12);
                    int pa = (A[aidx] * (4096 - awt) + A[aidx + 1] * awt) >> 16;
                    p12 = (p12 + 3 * pa) >> 2;
                }
                p12 = clampp(p12);
            }
            int bit = code_bit(c, p12, (sym >> (7 - bp)) & 1);
            if (!direct) {
                int e1 = (bit << 12) - p1;
                for (int k = 0; k < nin; k++) {
                    int32_t nw = w1[k] + ((st[k] * e1 * 20) >> 14);
                    w1[k] = nw > (1 << 22) ? (1 << 22) : (nw < -(1 << 22) ? -(1 << 22) : nw);
                }
                if (mix2) {
                    int e2 = (bit << 12) - p2;
                    for (int k = 0; k < nin; k++) {
                        int32_t nw = w2[k] + ((st[k] * e2 * 20) >> 14);
                        w2[k] = nw > (1 << 22) ? (1 << 22) : (nw < -(1 << 22) ? -(1 << 22) : nw);
                    }
                }
                if (apm) {
                    int g = (bit << 16) + (bit << 5) - bit - bit;
                    int j = awt >> 11 ? aidx + 1 : aidx;
                    A[j] += (g - A[j]) >> 6;
                }
            }
            for (int k = 0; k < nin; k++) {
                uint32_t j = idx[k]; int n = N[j];
                int p = P[j] + ((((bit << 16) - P[j]) * RECIP[n]) >> 15);
                P[j] = p < 0 ? 0 : (p > 65535 ? 65535 : p);
                if (n < limit) N[j] = n + 1;
            }
            c0 = c0 * 2 + bit;
        }
        int v = c0 & 255;
        if (!img) {
            if (c->dec) data[i] = v;
            c8 = (c8 << 8) | (c4 >> 24); c4 = (c4 << 8) | data[i];
        } else {
            if (c->dec) { int s = (v & 1) ? -((v + 1) >> 1) : (v >> 1); data[i] = (uint8_t)(pred + s); }
            err[i] = (int8_t)(uint8_t)(data[i] - pred);
            for (int k = 0; k < np; k++) { int ek = iabs(data[i] - pr[k]); perr[i * np + k] = ek > 255 ? 255 : ek; }
        }
    }
    free(P); free(N); free(W1); free(W2); free(A); free(err); free(perr);
}

static void put32(uint8_t *p, uint32_t v) { for (int i = 0; i < 4; i++) p[i] = v >> (8 * i); }
static uint32_t get32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }

/* encode one candidate; returns malloc'd container, sets *outLen */
static uint8_t *encode_one(int mode, int prof, int limit, int64_t width, uint8_t *data, int64_t L, int64_t *outLen) {
    Coder c = {0, 0xFFFFFFFFu, 0, NULL, 0, 0, 0, 0};
    for (int i = 0; i < HDR; i++) emit(&c, 0);
    run(&c, mode, prof, limit, width, data, L);
    for (int i = 3; i >= 0; i--) emit(&c, c.x1 >> (8 * i));
    while (c.len > HDR && c.buf[c.len - 1] == 0) c.len--;
    uint8_t *h = c.buf;
    memcpy(h, "FM2\x01", 4); h[4] = mode; h[5] = prof; h[6] = limit; h[7] = 0;
    put32(h + 8, (uint32_t)width); put32(h + 12, (uint32_t)L); put32(h + 16, (uint32_t)((uint64_t)L >> 32));
    *outLen = c.len;
    return c.buf;
}

uint8_t *fm2_encode(int level, int mode, int64_t width, uint8_t *data, int64_t L, int64_t *outLen) {
    static const int CB[6][3][2] = {{{0}}, {{1, 60}}, {{2, 60}}, {{3, 60}}, {{4, 255}}, {{4, 255}, {4, 60}, {3, 255}}};
    static const int CI[6][3][2] = {{{0}}, {{1, 60}}, {{2, 60}}, {{3, 255}}, {{4, 255}}, {{4, 255}}};
    uint8_t *best = NULL; int64_t bestLen = 0;
    if (level > 0) {
        for (int k = 0; k < 3; k++) {
            const int *cand = mode == 2 ? CI[level][k] : CB[level][k];
            if (!cand[0]) break;
            int64_t n; uint8_t *o = encode_one(mode, cand[0], cand[1], width, data, L, &n);
            if (!best || n < bestLen) { free(best); best = o; bestLen = n; } else free(o);
        }
    }
    if (!best || bestLen >= L + HDR) {   /* store */
        free(best);
        best = malloc(L + HDR);
        memcpy(best, "FM2\x01", 4); best[4] = 0; best[5] = best[6] = best[7] = 0;
        put32(best + 8, (uint32_t)width); put32(best + 12, (uint32_t)L); put32(best + 16, (uint32_t)((uint64_t)L >> 32));
        memcpy(best + HDR, data, L); bestLen = L + HDR;
    }
    *outLen = bestLen;
    return best;
}

uint8_t *fm2_decode(uint8_t *f, int64_t n, int64_t *outLen) {
    if (n < HDR || memcmp(f, "FM2\x01", 4)) return NULL;
    int mode = f[4], prof = f[5], limit = f[6];
    int64_t width = get32(f + 8), L = (int64_t)get32(f + 12) | (int64_t)get32(f + 16) << 32;
    uint8_t *data = malloc(L ? L : 1);
    if (mode == 0) memcpy(data, f + HDR, L);
    else {
        Coder c = {0, 0xFFFFFFFFu, 0, f + HDR, n - HDR, 0, 0, 1};
        for (int i = 0; i < 4; i++) c.x = (c.x << 8) | (c.pos < c.len ? c.buf[c.pos] : 0), c.pos++;
        run(&c, mode, prof, limit, width, data, L);
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
static void spit(const char *path, uint8_t *b, int64_t n) {
    FILE *f = fopen(path, "wb"); if (!f) { perror(path); exit(1); }
    fwrite(b, 1, n, f); fclose(f);
}

int main(int argc, char **argv) {
    init_tables();
    if (argc >= 6 && !strcmp(argv[1], "enc")) {
        int level = atoi(argv[2]), mode = !strcmp(argv[3], "image") ? 2 : 1;
        int64_t width = mode == 2 ? atoll(argv[4]) : 0, L, n;
        const char *in = argv[mode == 2 ? 5 : 4], *out = argv[mode == 2 ? 6 : 5];
        if (level < 0 || level > 5 || (mode == 2 && argc < 7)) goto usage;
        uint8_t *data = slurp(in, &L);
        if (mode == 2 && (width <= 0 || L % (3 * width))) { fprintf(stderr, "bad width\n"); return 1; }
        uint8_t *o = fm2_encode(level, mode, width, data, L, &n);
        spit(out, o, n);
        return 0;
    }
    if (argc == 4 && !strcmp(argv[1], "dec")) {
        int64_t n, L; uint8_t *f = slurp(argv[2], &n);
        uint8_t *d = fm2_decode(f, n, &L);
        if (!d) { fprintf(stderr, "not an FM2 file\n"); return 1; }
        spit(argv[3], d, L);
        return 0;
    }
usage:
    fprintf(stderr, "usage: fm2 enc LEVEL(0-5) bytes IN OUT | fm2 enc LEVEL image WIDTH IN OUT | fm2 dec IN OUT\n");
    return 2;
}
