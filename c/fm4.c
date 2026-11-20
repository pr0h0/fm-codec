/* fm4: model-fraction codec, format FM4. C reference implementation = the spec for the BPL port.
 *
 *   fm4 enc [-t N] LEVEL(0-5) bytes IN OUT | enc LEVEL image WIDTH IN OUT | enc LEVEL audio CHANNELS IN OUT
 *   | enc LEVEL video WIDTH HEIGHT IN OUT | dec IN OUT | a [-m auto|bytes] [-t N] LEVEL OUT PATH... | x [-t N] IN [DIR]
 *   experiments: env FEAT, FEAT2 (feature bits, override the level), BB (log2 buckets/table), LR, HUGE=0;
 *   decoding files made with FEAT/FEAT2/LR needs FM4_ANY_FEAT=1 (C and the native BPL CLI; trusted input only)
 *
 * Container, format 1 (36-byte header, little endian):
 *   "FM4\x01" | mode u8 (0 store, 1 bytes, 2 image/video, 3 audio) | bb u8 | counter limit u8 | mixer lr u8
 *   | feat u32 | width u32 | L u64 | feat2 u32 | CRC-32 of the data u32 | CRC-32 of header bytes 0-31 u32
 *   | payload (store: raw bytes; else the arithmetic coder's bytes, all of them)
 *   width: image width; audio: channels (1-8); video: width | frame height << 16.
 *   Until a first release, format 1 is the only format and may still change; after it, the version byte changes
 *   whenever an existing decoder could not read the new files.
 *
 * Feature bits 2 (feat2):
 *   1 mixer selection by hit count   2 4th mixer   4 text contexts   8 run inputs   16 OLS predictor
 *   32 wide OLS (audio: 32 own samples)   64 exact-colour contexts   128 2-D match model   256 video (previous frame)
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
#define __USE_MINGW_ANSI_STDIO 1
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <sys/stat.h>
#include <dirent.h>
#include <errno.h>
/* Portability: POSIX (Linux, macOS, BSD) codes segments and archive streams in parallel, one forked process
   each with results in shared memory; Windows (MinGW-w64) has no fork and codes them one after another in
   the process (same output). */
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <direct.h>
#include <io.h>
#define NO_FORK 1
#define mkdir(p, m) _mkdir(p)
#define lstat stat
#define fseeko _fseeki64
#define ftello _ftelli64
#else
#include <sys/mman.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/wait.h>
#endif

#define MAXIN 96
#define NPRED 12
#define HDR 36    /* header size */
#define MBITS 22
#define AERR_RING 128   /* > 8 frames x 8 channels, a power of two */
#define BB_MIN 12   /* table bits (log2 buckets per context) a file may use */
#define BB_MAX 20   /* the encoder writes at most 2^20 buckets (~1.2 GB of tables): every new file decodes in wasm32 */
#define BB_DEC_MAX 22   /* decoders also read 21-22 (earlier BB= experiments; ~4.4 GB, native builds only) */

static int SQ_T[33] = {1, 2, 3, 6, 10, 16, 27, 45, 73, 120, 194, 310, 488, 747, 1101, 1546, 2047,
                       2549, 2994, 3348, 3607, 3785, 3901, 3975, 4022, 4050, 4068, 4079, 4085, 4089, 4092, 4093, 4094};
static int16_t STRETCH[4096]; static int RECIP[256], LR = 4, OPT_HUGE = 1;
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

/* allocation failure ends the process (status 1): it happens on hostile or corrupt sizes, never silently */
static void *alloc_ok(void *p) { if (!p) { fputs("out of memory\n", stderr); exit(1); } return p; }
#define xmalloc(n) alloc_ok(malloc(n))
#define xcalloc(n, k) alloc_ok(calloc(n, k))
/* big tables on 2 MB huge pages where available (fewer TLB misses; no effect on output) */
static void *big_alloc(size_t n) {
    void *p = NULL;
#if defined(MADV_HUGEPAGE)
    if (OPT_HUGE && n >= (1u << 21)) {
        if (posix_memalign(&p, 1u << 21, n)) p = NULL;
        else madvise(p, n, MADV_HUGEPAGE);
    }
#endif
    return p ? p : xmalloc(n);
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

/* end: decoding stops once pos passes it (a valid stream is never read past its last byte) */
typedef struct { uint32_t x1, x2, x; uint8_t *buf; int64_t len, pos, cap; int dec; int64_t end; } Coder;
/* the encoder writes into a buffer of L + HDR bytes: a longer result would be stored instead, so when it is
   full, coding stops (pos > end ends run()'s loop) */
static void emit(Coder *c, uint8_t b) {
    if (c->len == c->cap) { c->pos = 1; c->end = 0; return; }
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
/* n is a multiple of 16 (inputs past the real count are 0, so their weights stay 0): fixed-size blocks vectorize fully */
static inline int dot16(const int16_t *restrict w, const int16_t *restrict st, int n) {
    uint32_t s = 0;
    for (int b = 0; b < n; b += 16) for (int k = b; k < b + 16; k++) s += (uint32_t)(w[k] * st[k]);
    return (int32_t)s >> 12;
}
static inline void upd16(int16_t *restrict w, const int16_t *restrict st, int n, int e) {
    int el = e * LR;
    for (int b = 0; b < n; b += 16) for (int k = b; k < b + 16; k++) {
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
/* p[0, unit) is set: repeat it over p[0, total) with doubling copies (memcpy is far faster than an element
   loop, which matters for the many-MB tables of short inputs; same as fillRep in the BPL build) */
static void fill_rep(void *p, size_t unit, size_t total) {
    for (size_t have = unit; have < total; have *= 2) memcpy((char *)p + have, p, have < total - have ? have : total - have);
}
static void apm_init(uint16_t *A, int n) {
    for (int j = 0; j < 33; j++) A[j] = squash((j - 16) * 128) * 16;
    fill_rep(A, 33 * 2, (size_t)n * 33 * 2);
}

#define OLSN 40
typedef struct { int n, cnt; double lam; double m[OLSN][OLSN], b[OLSN], w[OLSN], x[OLSN]; } Ols;
static double ols_pred(Ols *o) { double s = 0; for (int k = 0; k < o->n; k++) s += o->w[k] * o->x[k]; return s; }
static void ols_upd(Ols *o, double y) {
    int n = o->n; double L[OLSN][OLSN], z[OLSN], col[OLSN];
    for (int j = 0; j < n; j++) {
        for (int k = 0; k <= j; k++) o->m[j][k] = o->lam * o->m[j][k] + (1 - o->lam) * o->x[j] * o->x[k];
        o->b[j] = o->lam * o->b[j] + (1 - o->lam) * o->x[j] * y;
    }
    if (++o->cnt < OSKIP) return;
    o->cnt = 0;
    /* Cholesky + forward substitution, column by column. Every element still gets its products subtracted in
       the same order (t ascending) as the row-by-row form, so the result is bit-identical, but the inner loop
       has no dependency chain and vectorizes. */
    for (int j = 0; j < n; j++) { for (int k = 0; k <= j; k++) L[j][k] = o->m[j][k] + (j == k ? OEPS : 0); z[j] = o->b[j]; }
    for (int t = 0; t < n; t++) {
        if (L[t][t] <= 0) return;
        double d = sqrt(L[t][t]), zt = z[t] / d;
        L[t][t] = d; z[t] = zt;
        for (int j = t + 1; j < n; j++) col[j] = L[j][t] = L[j][t] / d;
        for (int j = t + 1; j < n; j++) {
            double cj = col[j], *restrict row = L[j];
            for (int k = t + 1; k <= j; k++) row[k] -= cj * col[k];
            z[j] -= cj * zt;
        }
    }
    for (int j = n - 1; j >= 0; j--) { double v = z[j]; for (int t = j + 1; t < n; t++) v -= L[t][j] * o->w[t]; o->w[j] = v / L[j][j]; }
}
/* the model; always inlined into run() below, which calls it with constant parameters per level */
static inline __attribute__((always_inline)) void run_body(Coder *c, int mode, int bb, int limit, uint32_t feat, uint32_t feat2, int64_t width, uint8_t *data, int64_t L) {
    int img = mode == 2, aud = mode == 3, nchan = aud ? (int)width : 0;
    /* video = image mode with feat2 bit 256: width field = width | frame height << 16 */
    int fvid = img && (feat2 & 256); int64_t fh = fvid ? width >> 16 : 0; if (fvid) width &= 0xFFFF;
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
    int nctx = img ? (flite ? 6 : 12 + (fimgx ? 4 : 0) + (XOLS ? 2 : 0) + (XCOL ? 2 : 0) + (XIM ? 1 : 0) + (fvid ? 3 : 0)) : btxt + ntxt;
    if (aud) nctx = 10;
    int nimm = XIM ? 1 : 0;
    int nrun = XRUN ? nctx : 0;
    int nin = nctx * (fhist ? 2 : 1) + nrun + nimm + (fmatch ? 1 : 0) + (fm2nd ? 1 : 0) + 1;   /* + match(es) + bias */
    int np = img && !flite ? 9 + (XOLS ? 1 : 0) + (fvid ? 2 : 0) : 0;
    Ols *OL = xcalloc(3, sizeof(Ols)); OL[0].n = 10; OL[1].n = 14; OL[2].n = 15; if (XWIDE) for (int k = 0; k < 3; k++) OL[k].n += 10; int oin = 0;
    for (int k = 0; k < 3; k++) { OL[k].lam = OLAM; if (fvid) OL[k].n += 4; }

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
    Ols *AO = aud ? xcalloc(2 * nchan, sizeof(Ols)) : NULL;
    for (int k = 0; k < nchan; k++) { AO[k].n = an; AO[k].lam = 0.998; AO[nchan + k].n = 8; AO[nchan + k].lam = 0.99; }
    int16_t *aerr = aud ? xcalloc(AERR_RING, 2) : NULL;   /* ring: residuals are read back at most 8 frames x 8 channels */
    int apred = 0, azig = 0, ahi = 0, aq = 0, ach = 0; uint32_t actx[16];
    uint32_t *T[MAXIN];
    for (int k = 0; k < nctx; k++) {
        size_t tsz = (size_t)16 << tb[k];
        T[k] = big_alloc(tsz * 4);
        for (size_t j = 0; j < 16; j++) T[k][j] = j ? (32768 | 1u << 24) : 0;
        fill_rep(T[k], 64, tsz * 4);
    }
    uint32_t *SM = xmalloc(sizeof(uint32_t) * MAXIN * 256);
    SM[0] = 32768; fill_rep(SM, 4, sizeof(uint32_t) * MAXIN * 256);
    int32_t winit = 19661 * 6 / nin;
    int16_t *W1 = xmalloc(2 * 8 * 256 * MAXIN), *W2 = xmalloc(2 * 768 * MAXIN), *W3 = xmalloc(2 * 2048 * MAXIN), *W4 = xmalloc(2 * 4096 * MAXIN);
    int32_t *WF = xmalloc(sizeof(int32_t) * 256 * 4);
    W1[0] = W2[0] = W3[0] = W4[0] = winit >> 4;
    fill_rep(W1, 2, 2 * 8 * 256 * MAXIN); fill_rep(W2, 2, 2 * 768 * MAXIN); fill_rep(W3, 2, 2 * 2048 * MAXIN); fill_rep(W4, 2, 2 * 4096 * MAXIN);
    for (int j = 0; j < 256 * 4; j++) WF[j] = XM4 ? 16384 : 21845;
    int napm1 = img ? 256 * 16 * 3 : 65536;
    uint16_t *A1 = xmalloc(sizeof(uint16_t) * napm1 * 33); apm_init(A1, napm1);
    uint16_t *A2 = fapm2 ? xmalloc(sizeof(uint16_t) * (1 << 18) * 33) : NULL; if (fapm2) apm_init(A2, 1 << 18);
    uint16_t *A3 = fmapm ? xmalloc(sizeof(uint16_t) * 65536 * 33) : NULL; if (fmapm) apm_init(A3, 65536);
    uint32_t *MT = fmatch ? xcalloc((size_t)1 << MBITS, 4) : NULL, *MT2 = fm2nd ? xcalloc((size_t)1 << MBITS, 4) : NULL;
    uint16_t MP[64], MP2[64]; uint8_t MN[64] = {0}, MN2[64] = {0};   /* P(expected bit is right) per length bucket */
    for (int j = 0; j < 64; j++) MP[j] = MP2[j] = 49152;
    uint16_t *IND1 = find ? xcalloc(256, 2) : NULL, *IND2 = find ? xcalloc(1 << 22, 2) : NULL;
    /* per-pixel errors are read back at most 2 rows + 2 pixels (6 * 65535 + 6 bytes): ring buffers of 2^19 entries,
       or the next power of two >= L + 1 for smaller inputs (no effect on output) */
    int64_t RM = 63; while (RM < L && RM < (1 << 19) - 1) RM = RM * 2 + 1;
    int16_t *err = img ? xcalloc(RM + 1, 2) : NULL;
    uint8_t *perr = np ? xcalloc((RM + 1) * np, 1) : NULL;
    int64_t stride = 3 * width, mptr = 0, mlen = 0, mptr2 = 0, mlen2 = 0, linestart = 0, prevline = 0, indent = 0, inind = 1, imptr = 0, imlen = 0, imok = 0, imev = -1;
    uint32_t *IMT = XIM ? xcalloc((size_t)1 << MBITS, 4) : NULL;
    uint32_t ctx[MAXIN], c4 = 0, c8 = 0, w0 = 0, w1 = 0, w2 = 0, *bk[MAXIN];
    int16_t st[2 * MAXIN + 4] = {0}; int smi[MAXIN]; int nb = (nin + 15) & ~15;   /* mixer input count rounded up to a block */
    uint32_t *rk[MAXIN]; int rb[MAXIN], rq[MAXIN], reb[MAXIN], rmiss[MAXIN];
    uint16_t *RP = xcalloc(MAXIN * 64, 2); uint8_t *RN = xcalloc(MAXIN * 64, 1); for (int j = 0; j < MAXIN * 64; j++) RP[j] = 49152;
    int hord = 0, isym = -1, iq = 0, imiss = 0; uint16_t IMP[64]; uint8_t IMN[64] = {0}; for (int j = 0; j < 64; j++) IMP[j] = 49152;
    static const int ORD[8] = {0, 1, 2, 3, 4, 6, 5, 7};

    for (int64_t i = 0; i < L && c->pos <= c->end; i++) {
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
                int r1 = t > 0 ? aerr[(si - nchan) & (AERR_RING - 1)] : 0, r2 = t > 1 ? aerr[(si - 2 * nchan) & (AERR_RING - 1)] : 0, r3 = t > 2 ? aerr[(si - 3 * nchan) & (AERR_RING - 1)] : 0;
                int ro = ach ? aerr[(si - 1) & (AERR_RING - 1)] : (t > 0 ? aerr[(si - 1) & (AERR_RING - 1)] : 0);
                int e8 = 0; for (int k = 1; k <= 8; k++) if (t >= k) e8 += iabs(aerr[(si - (int64_t)k * nchan) & (AERR_RING - 1)]);
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
                        uint32_t far4 = (uint32_t)data[i - 9] | (uint32_t)data[i - 10] << 8 | (uint32_t)data[i - 11] << 16 | (uint32_t)data[i - 12] << 24;
                        uint32_t hh = H(98, c4, c8, far4) >> (32 - MBITS);
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
            int64_t fb = stride * fh; int hasP = fvid && i >= fb;
            int Pv = hasP ? data[i - fb] : 0, PWv = hasP && hasW ? data[i - fb - 3] : Pv, PNv = hasP && i - fb - stride >= 0 ? data[i - fb - stride] : Pv;
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
                        if (fvid) { int b = OL[ch].n - 4; X[b] = Pv; X[b + 1] = PWv; X[b + 2] = PNv; X[b + 3] = hasP ? data[i - fb + 3] : 0; }
                        if (XWIDE) {   /* wider: 6 more same-channel, 4 more cross-channel */
                            int b = OL[ch].n - 10 - (fvid ? 4 : 0);
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
                if (fvid) {   /* previous frame: same pixel, and same pixel + spatial change since then */
                    pr[np - 2] = hasP ? Pv : pr[0];
                    pr[np - 1] = hasP ? clamp255(Pv + Wv - PWv) : pr[0];
                }
                int64_t num = 0, den = 0;
                for (int k = 0; k < np; k++) {
                    int s = 1;
                    if (hasW) s += perr[((iW) & RM) * np + k];
                    if (hasN) s += perr[((iN) & RM) * np + k];
                    if (hasN && hasW) s += perr[((iNW) & RM) * np + k];
                    if (hasNE) s += perr[((iNE) & RM) * np + k];
                    int64_t w = fblend1 ? (1LL << 24) / s : (1LL << 24) / ((int64_t)s * s);
                    num += w * pr[k]; den += w;
                }
                pred = (int)((num + den / 2) / den);
            }
            int eW = hasW ? err[(iW) & RM] : 0, eN = hasN ? err[(iN) & RM] : 0, eNW = (hasN && hasW) ? err[(iNW) & RM] : 0;
            int eNE = hasNE ? err[(iNE) & RM] : 0, eP2 = ch == 2 ? err[(i - 2) & RM] : 0;
            eP = ch ? err[(i - 1) & RM] : 0;
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
                int eWW = hasWW ? err[(i - 6) & RM] : 0, eNN = hasNN ? err[(iN - stride) & RM] : 0;
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
                if (fvid) {
                    ctx[j++] = H(31, chv, hasP ? qe(Pv - pred, 40) : 999u, 0);
                    ctx[j++] = H(32, chv, hasP ? (uint32_t)Pv : 999u, qe(pr[0] - pred, 10));
                    ctx[j++] = H(33, chv, hasP ? qe(Pv - pred, 10) * 256 + qe(PWv - Wv, 10) : 99999u, qe(PNv - Nv, 10));
                }
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
        uint32_t hk[MAXIN];
        for (int bp = 0; bp < 8; bp++) {
            if (bp == 0 || bp == 4) {   /* hash all contexts, prefetch all buckets, then search */
                if (bp == 0) for (int k = 0; k < nctx; k++) {
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
            int d = dot16(w1, st, nb), p1 = clampp(squash(d)), p2 = 0, p3 = 0, p4 = 0, pf = 0, dd[4] = {d, 0, 0, 0}, nm = XM4 ? 4 : 3;
            if (fmix2) {
                dd[1] = dot16(w2, st, nb);
                p2 = clampp(squash(dd[1]));
                d = (d + dd[1]) >> 1;
            }
            if (fmix3) {   /* learned final mixer over the three mixer outputs */
                dd[2] = dot16(w3, st, nb);
                if (XM4) { dd[3] = dot16(w4, st, nb); dd[3] = dd[3] < -2047 ? -2047 : (dd[3] > 2047 ? 2047 : dd[3]); p4 = clampp(squash(dd[3])); }
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
            if (bp == 3) for (int k = 0; k < nctx; k++) {   /* second nibble known: fetch its buckets while this bit's updates run */
                hk[k] = nib_hash(ctx[k], c0 * 2 + bit);
                uint32_t i0 = hk[k] >> (32 - tb[k]);
                __builtin_prefetch(T[k] + ((size_t)i0 << 4));
                __builtin_prefetch(T[k] + ((size_t)(i0 ^ 1) << 4));
            }
            upd16(w1, st, nb, (bit << 12) - p1);
            if (fmix2) {
                upd16(w2, st, nb, (bit << 12) - p2);
                if (fmix3) { upd16(w3, st, nb, (bit << 12) - p3); if (XM4) upd16(w4, st, nb, (bit << 12) - p4); { int el = ((bit << 12) - pf) * LR; for (int k = 0; k < nm; k++) { int32_t nw = wf[k] + ((int32_t)((uint32_t)dd[k] * (uint32_t)el) >> 14); wf[k] = nw > (1 << 19) - 1 ? (1 << 19) - 1 : (nw < -(1 << 19) ? -(1 << 19) : nw); } } }
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
                aerr[si & (AERR_RING - 1)] = (int16_t)(sv - apred);
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
            err[(i) & RM] = (int8_t)(uint8_t)(data[i] - pred);
            for (int k = 0; k < np; k++) { int ek = iabs(data[i] - pr[k]); perr[((i) & RM) * np + k] = ek > 255 ? 255 : ek; }
            if (imev >= 0 && data[i] != imev) imok = 0;
            if (XOLS && oin) ols_upd(&OL[ch], data[i]);
        }
    }
    for (int k = 0; k < nctx; k++) free(T[k]);
    free(SM); free(W1); free(W2); free(W3); free(W4); free(WF); free(A1); free(A2); free(A3); free(OL);
    free(MT); free(MT2); free(IND1); free(IND2); free(IMT); free(err); free(perr); free(AO); free(aerr); free(RP); free(RN);
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
/* CRC-32 (IEEE, as in zlib/PNG) */
static uint32_t crc32_of(const uint8_t *p, int64_t n) {
    static uint32_t T[256];
    if (!T[1]) for (uint32_t i = 0; i < 256; i++) { uint32_t c = i; for (int k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320u ^ (c >> 1) : c >> 1; T[i] = c; }
    uint32_t c = 0xFFFFFFFFu;
    for (int64_t i = 0; i < n; i++) c = T[(c ^ p[i]) & 255] ^ (c >> 8);
    return c ^ 0xFFFFFFFFu;
}
static int64_t get64(const uint8_t *p) { return (int64_t)((uint64_t)get32(p) | (uint64_t)get32(p + 4) << 32); }   /* unsigned shift: no overflow UB */
static void header(uint8_t *h, int mode, int bb, int limit, int lr, uint32_t feat, uint32_t feat2, int64_t width, int64_t L, uint32_t crc) {
    memcpy(h, "FM4\x01", 4); h[4] = mode; h[5] = bb; h[6] = limit; h[7] = lr;
    put32(h + 8, feat); put32(h + 12, (uint32_t)width); put32(h + 16, (uint32_t)L); put32(h + 20, (uint32_t)((uint64_t)L >> 32));
    put32(h + 24, feat2); put32(h + 28, crc); put32(h + 32, crc32_of(h, 32));
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
static const uint32_t BL[6] = {0, B_L1, B_L2, B_L3, B_L4, B_L4}, IL[6] = {0, I_L1, I_L2, I_L3, I_L4, I_L4};
static const uint32_t BL2[6] = {0, 0, 1, 1 | 4, 1 | 2 | 4, 1 | 2 | 4 | 8}, IL2[6] = {0, 0, 128, 128 | 64, 128 | 64 | 16 | 2, 128 | 64 | 16 | 2 | 32};
static const uint32_t AL[6] = {0, 0, 32, 32 | 256, 32 | 256 | 2048, 32 | 256 | 2048}, AL2[6] = {0, 0, 0, 2, 2 | 32, 2 | 32};
#define LEVEL_FEAT(mode, level) ((mode) == 2 ? IL[level] : (mode) == 3 ? AL[level] : BL[level])
#define LEVEL_FEAT2(mode, level) ((mode) == 2 ? IL2[level] : (mode) == 3 ? AL2[level] : BL2[level])
/* The model's array indexing is only valid for the feature sets the levels produce (other combinations can
   index past the mixer weights), so a decoder accepts exactly those: per mode, levels 1-5, plus the x86
   transform bit (bytes) and the video bit (image with a frame height, levels 2-5), counter limit 255 and a
   mixer rate of 1-15. FM4_ANY_FEAT=1 lifts this for files from FEAT/FEAT2/LR experiments (trusted input only). */
static int params_ok(int mode, uint32_t feat, uint32_t feat2, int64_t width, int limit, int lr) {
    if (getenv("FM4_ANY_FEAT")) return 1;
    if (limit != 255 || lr < 1 || lr > 15) return 0;
    if (mode == 1) feat &= ~64u;
    int video = mode == 2 && (feat2 & 256);
    if (video) { if (!(width >> 16)) return 0; feat2 &= ~256u; }
    for (int level = 1; level <= 5; level++)
        if (feat == LEVEL_FEAT(mode, level) && feat2 == LEVEL_FEAT2(mode, level) && (!video || level >= 2) && !(mode == 2 && !video && level >= 2 && (width >> 16))) return 1;
    return 0;
}
/* One copy of the model per level and mode, compiled with its feature bits as constants: the compiler drops
   the unused features' code and branches (bytes level 1: ~35% faster; same output). Other parameter sets
   (FEAT/FEAT2 experiments) run the general copy. The x86 bit (64) only tells the decoder to undo the transform. */
static int RAN_GENERAL;   /* the last encode / decode used the general copy (no level matched; see spec_missed) */
static void run(Coder *c, int mode, int bb, int limit, uint32_t feat, uint32_t feat2, int64_t width, uint8_t *data, int64_t L) {
    uint32_t f = feat & ~64u;
    RAN_GENERAL = 0;
#define SPEC(m, lv, v) if (mode == m && f == LEVEL_FEAT(m, lv) && feat2 == (LEVEL_FEAT2(m, lv) | v)) { run_body(c, m, bb, limit, LEVEL_FEAT(m, lv), LEVEL_FEAT2(m, lv) | v, width, data, L); return; }
    SPEC(1, 1, 0) SPEC(1, 2, 0) SPEC(1, 3, 0) SPEC(1, 4, 0) SPEC(1, 5, 0)
    SPEC(2, 1, 0) SPEC(2, 2, 0) SPEC(2, 3, 0) SPEC(2, 4, 0) SPEC(2, 5, 0)
    SPEC(2, 2, 256) SPEC(2, 3, 256) SPEC(2, 4, 256) SPEC(2, 5, 256)
    SPEC(3, 1, 0) SPEC(3, 2, 0) SPEC(3, 3, 0) SPEC(3, 4, 0)   /* audio level 5 = level 4 */
#undef SPEC
    RAN_GENERAL = 1;
    run_body(c, mode, bb, limit, feat, feat2, width, data, L);
}
/* FM4_CHECK_SPEC=1 (tests/run.sh): a level that ran the general copy is an error (exit 3). It still codes the
   same bytes, only slower, so without this check a level missing from run()'s list would go unnoticed. */
static int spec_missed(void) {
    if (!getenv("FM4_CHECK_SPEC") || !RAN_GENERAL) return 0;
    fputs("fm4: this level ran the general model copy: run()'s level list does not cover it\n", stderr);
    return 1;
}
#define ENC_CAP(L) ((L) + HDR)
static int64_t BIG;
static uint8_t *scratch(int64_t n);
static void scratch_free(void *p, int64_t n);
static uint8_t *fm4_encode(int level, int mode, int64_t width, uint8_t *data, int64_t L, int64_t *outLen) {
    RAN_GENERAL = 0;   /* per call (a stored stream never reaches run()) */
    uint32_t feat = LEVEL_FEAT(mode, level), feat2 = LEVEL_FEAT2(mode, level);
    int bb = level == 5 && mode == 1 ? 19 : 18, limit = 255;
    /* short inputs get small tables: 2^(bb-2) >= L (16 buckets each; larger tables would stay mostly empty).
       Costs at most ~0.05% in size and cuts memory for a 2 KB input from 320 to 50 MB. */
    int bbs = BB_MIN; while (bbs < bb && ((int64_t)1 << (bbs - 2)) < L) bbs++;
    bb = bbs;
    if (mode == 2 && (width >> 16) && (width & 0xFFFF) && level >= 2) feat2 |= 256;   /* video (a plain image 65536*k wide is not: run() would divide by width 0) */
    if (getenv("FEAT")) feat = (uint32_t)atoi(getenv("FEAT"));
    if (getenv("FEAT2")) feat2 = (uint32_t)atoi(getenv("FEAT2"));
    if (getenv("BB")) bb = atoi(getenv("BB"));
    if (bb < BB_MIN || bb > BB_MAX) { fprintf(stderr, "BB must be %d-%d\n", BB_MIN, BB_MAX); exit(1); }
    /* result: at most L + HDR bytes (else stored); release with scratch_free(result, ENC_CAP(L)) */
    uint8_t *best = scratch(ENC_CAP(L)); int64_t bestLen = -1; uint32_t crc = crc32_of(data, L);
    if (level > 0) {
        feat &= ~64u;
        uint8_t *cd = data, *tdata = NULL;   /* the data the model codes */
        if (mode == 1 && e8e9_detect(data, L)) {
            /* the transform rewrites nearly every page: on a large mapped input those pages would become anonymous
               memory, so it works on a file-backed copy instead (and the input stays untouched) */
            if (L >= BIG) { cd = tdata = scratch(L); memcpy(tdata, data, L); }
            e8e9(cd, L, 1); feat |= 64;
        }
        Coder c = {0, 0xFFFFFFFFu, 0, best, 0, 0, L + HDR, 0, INT64_MAX};
        for (int i = 0; i < HDR; i++) emit(&c, 0);
        run(&c, mode, bb, limit, feat, feat2, width, cd, L);
        for (int i = 3; i >= 0; i--) emit(&c, c.x1 >> (8 * i));
        if (c.end) { header(best, mode, bb, limit, LR, feat, feat2, width, L, crc); bestLen = c.len; }   /* end == 0: full */
        if (tdata) scratch_free(tdata, L);
        else if (feat & 64) e8e9(data, L, 0);   /* restore the input */
    }
    if (bestLen < 0 || bestLen >= L + HDR) {   /* store */
        header(best, 0, 0, 0, 0, 0, 0, width, L, crc);
        memcpy(best + HDR, data, L); bestLen = L + HDR;
    }
    *outLen = bestLen;
    return best;
}
/* Checks of one FM4 stream (m bytes at s, decoded length L) that need no decoding: magic and version, header CRC,
   and L bounded by the payload (no zero bytes are stripped, and every coded bit has p in [1, 4095]/4096 so costs at
   least log2(4096/4095) bits: at most ~2840 bytes per payload byte; 50 MB of zeros: 2838). fm4_decode starts with
   it; containers call it for each stream before adding the lengths up and allocating. Decoding then stops at the
   end of the payload, and the CRC of the result must match. */
static int stream_ok(const uint8_t *s, int64_t m, int64_t L) {
    if (m < HDR || memcmp(s, "FM4\x01", 4) || L < 0 || L > (int64_t)1 << 40) return 0;
    return get32(s + 32) == crc32_of(s, 32) && (s[4] == 0 ? L <= m - HDR : L / 4096 <= m - HDR);
}
/* get(L, ctx) supplies the output buffer once L is known and checked (NULL: malloc); NULL result: corrupt */
static uint8_t *fm4_decode_to(uint8_t *f, int64_t n, int64_t *outLen, uint8_t *(*get)(int64_t, void *), void *ctx) {
    RAN_GENERAL = 0;   /* per call (a stored stream never reaches run()) */
    if (n < HDR) return NULL;
    int hd = HDR, mode = f[4], bb = f[5], limit = f[6]; uint32_t feat = get32(f + 8), feat2 = get32(f + 24);
    int64_t width = get32(f + 12), L = get64(f + 16);
    if (!stream_ok(f, n, L)) return NULL;   /* magic, header CRC and L bound */
    if (mode > 3 || (mode == 2 && !(width & 0xFFFF)) || (mode == 3 && (width < 1 || width > 8))) return NULL;   /* corrupt header */
    if (mode && (bb < BB_MIN || bb > BB_DEC_MAX || !params_ok(mode, feat, feat2, width, limit, f[7]))) return NULL;   /* the encoder never writes others */
    if (mode == 0 && L > n - hd) return NULL;
    /* whole pixels / frames / samples, as the encoder requires (else the last bytes would never be written) */
    if ((mode == 2 && (L % (3 * (width & 0xFFFF)) || ((width >> 16) && L % (3 * (width & 0xFFFF) * (width >> 16))))) || (mode == 3 && L % (2 * width))) return NULL;
    uint8_t *data = get ? get(L, ctx) : xmalloc(L ? L : 1);
    if (!data) return NULL;
    if (mode == 0) memcpy(data, f + hd, L);
    else {
        LR = f[7];
        Coder c = {0, 0xFFFFFFFFu, 0, f + hd, n - hd, 0, 0, 1, n - hd};
        for (int i = 0; i < 4; i++) c.x = (c.x << 8) | (c.pos < c.len ? c.buf[c.pos] : 0), c.pos++;
        run(&c, mode, bb, limit, feat, feat2, width, data, L);
        if (c.pos > c.end) { if (!get) free(data); return NULL; }   /* read past the end: corrupt */
        if (feat & 64) e8e9(data, L, 0);
    }
    if (crc32_of(data, L) != get32(f + 28)) { if (!get) free(data); return NULL; }
    *outLen = L;
    return data;
}
#define fm4_decode(f, n, outLen) fm4_decode_to(f, n, outLen, NULL, NULL)

/* ---- memory for data, which may be larger than RAM (POSIX). Buffers of BIG bytes and more live in mappings of
   files, so the kernel can write them out and read them back instead of needing that much memory: inputs are
   mapped (copy-on-write), decoded output goes straight into the output file, and large intermediate buffers
   (shared_alloc, scratch) use unlinked temporary files in SCRATCH_DIR (the output's directory). Windows: memory. */
static int64_t BIG = (int64_t)64 << 20;   /* env FM4_BIG (bytes) lowers it: tests run every path on small data */
static char SCRATCH_DIR[4096] = ".";
static void scratch_dir_for(const char *path, int is_dir) {   /* the directory of an output file, or the directory itself */
    snprintf(SCRATCH_DIR, sizeof SCRATCH_DIR, "%s", path);
    char *sl = strrchr(SCRATCH_DIR, '/');
    if (is_dir) return;
    if (sl) sl[sl == SCRATCH_DIR] = 0; else strcpy(SCRATCH_DIR, ".");
}
#ifndef NO_FORK
static void *map_fd(int fd, int64_t n, int shared) {
    void *p = mmap(NULL, n, PROT_READ | PROT_WRITE, shared ? MAP_SHARED : MAP_PRIVATE, fd, 0);
    return p == MAP_FAILED ? NULL : p;
}
/* Gives the file n bytes of disk blocks now: a mapped page that cannot be written back later (disk full, quota)
   would kill the process with SIGBUS, so a full disk must fail here, as an error. */
static int reserve(int fd, int64_t n) {
#ifdef __APPLE__
    fstore_t st = {F_ALLOCATEALL, F_PEOFPOSMODE, 0, n, 0};
    if (fcntl(fd, F_PREALLOCATE, &st) == -1) return -1;
    return ftruncate(fd, n);
#else
    int e = posix_fallocate(fd, 0, n);
    if (e) { errno = e; return -1; }
    return 0;
#endif
}
static void *map_temp(int64_t n) {   /* n bytes in an unlinked temporary file, shared with forked processes */
    char t[4200]; snprintf(t, sizeof t, "%s/.fm4-XXXXXX", SCRATCH_DIR);
    int fd = mkstemp(t); if (fd < 0) return NULL;
    unlink(t);
    void *p = reserve(fd, n) ? NULL : map_fd(fd, n, 1);
    close(fd); return p;
}
#endif
/* memory the coding processes write their results into (shared with them; a temporary file when large;
   Windows: plain memory) */
static uint8_t *shared_alloc(int64_t n) {
#ifdef NO_FORK
    return malloc(n ? n : 1);
#else
    void *p = n >= BIG ? map_temp(n) : NULL;
    if (!p) p = mmap(NULL, n ? n : 1, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    return p == MAP_FAILED ? NULL : p;
#endif
}
/* private working memory (the encoder's output); release with scratch_free(p, n) */
static uint8_t *scratch(int64_t n) {
#ifndef NO_FORK
    if (n >= BIG) {   /* always a mapping, so scratch_free can unmap it */
        void *p = map_temp(n);
        if (!p && (p = mmap(NULL, n, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0)) == MAP_FAILED) p = NULL;
        return alloc_ok(p);
    }
#endif
    return xmalloc(n ? n : 1);
}
static void scratch_free(void *p, int64_t n) {
#ifndef NO_FORK
    if (n >= BIG) { munmap(p, n); return; }
#endif
    (void)n; free(p);
}
static uint8_t *slurp(const char *path, int64_t *n);
/* the whole file at path, writable (changes stay in memory); large files are mapped, not read */
static uint8_t *map_in(const char *path, int64_t *n) {
#ifndef NO_FORK
    int fd = open(path, O_RDONLY); struct stat st;
    if (fd < 0) { perror(path); exit(1); }
    if (fstat(fd, &st)) { perror(path); exit(1); }
    if (S_ISREG(st.st_mode) && st.st_size > 0 && st.st_size >= (BIG < (1 << 20) ? BIG : 1 << 20)) {
        void *p = map_fd(fd, st.st_size, 0);
        close(fd);
        if (!p) { perror(path); exit(1); }
        *n = st.st_size; return p;
    }
    close(fd);
#endif
    return slurp(path, n);
}
/* Output written in place. out_open(o, n) gives the buffer, out_close(o, ok) publishes it as o->path.
   POSIX: a mapping of a new temporary file next to path (mkstemp, so no existing file is touched),
   with its disk space reserved; renamed to path on success, removed on failure. Only for lengths bounded by the
   input (stream_ok: ~2840x the payload). Windows: memory, written at the end. */
typedef struct { const char *path; char tmp[4200]; uint8_t *p; int64_t n; int mapped, ioerr; } Out;
static int spit(const char *path, uint8_t *b, int64_t n);
#ifndef NO_FORK
/* An interrupted decode removes its temporary output (it has the full size reserved), then dies of the signal
   as before (the shell sees a signal death). Signals that were ignored (nohup, background jobs) stay ignored, and
   the earlier handlers come back once the output is published or removed. */
static char PENDING[4200];
static const int CLEAN_SIG[3] = {SIGINT, SIGTERM, SIGHUP};
static void (*OLD_SIG[3])(int);
static void on_signal(int sig) { if (PENDING[0]) unlink(PENDING); signal(sig, SIG_DFL); raise(sig); }
static void pending(const char *t) {
    if (t) {
        snprintf(PENDING, sizeof PENDING, "%s", t);
        for (int i = 0; i < 3; i++) if ((OLD_SIG[i] = signal(CLEAN_SIG[i], on_signal)) == SIG_IGN) signal(CLEAN_SIG[i], SIG_IGN);
    } else if (PENDING[0]) {
        for (int i = 0; i < 3; i++) signal(CLEAN_SIG[i], OLD_SIG[i]);
        PENDING[0] = 0;
    }
}
#endif
static uint8_t *out_open(Out *o, int64_t n) {
    o->n = n; o->mapped = 0;
#ifndef NO_FORK
    if (n > 0) {
        snprintf(o->tmp, sizeof o->tmp, "%s.fm4-XXXXXX", o->path);   /* recognisable if a crash leaves it */
        int fd = mkstemp(o->tmp);
        if (fd < 0) { perror(o->tmp); o->ioerr = 1; return NULL; }
        pending(o->tmp);
        mode_t um = umask(0); umask(um); fchmod(fd, 0666 & ~um);   /* the permissions fopen would give */
        void *p = reserve(fd, n) ? NULL : map_fd(fd, n, 1);
        if (!p) { perror(o->path); close(fd); unlink(o->tmp); pending(NULL); o->ioerr = 1; return NULL; }
        close(fd); o->mapped = 1;
        return o->p = p;
    }
#endif
    return o->p = xmalloc(n ? n : 1);
}
static int out_close(Out *o, int ok) {   /* 0: published */
#ifndef NO_FORK
    if (o->mapped) {
        if (munmap(o->p, o->n)) { perror(o->path); ok = 0; }
        if (!ok) { unlink(o->tmp); pending(NULL); return 1; }
        if (rename(o->tmp, o->path)) { perror(o->path); unlink(o->tmp); pending(NULL); o->ioerr = 1; return 1; }
        pending(NULL); return 0;
    }
#endif
    int r = ok ? spit(o->path, o->p, o->n) : 1;
    if (ok && r) o->ioerr = 1;
    free(o->p); return r;
}
static uint8_t *slurp(const char *path, int64_t *n) {
    FILE *f = fopen(path, "rb"); if (!f) { perror(path); exit(1); }
    fseeko(f, 0, SEEK_END); *n = ftello(f); fseeko(f, 0, SEEK_SET);   /* 64-bit offsets (Windows: long is 32 bits) */
    uint8_t *b = xmalloc(*n ? *n : 1);
    if ((int64_t)fread(b, 1, *n, f) != *n) { perror("read"); exit(1); }
    fclose(f); return b;
}
static int spit(const char *path, uint8_t *b, int64_t n) {
    FILE *f = fopen(path, "wb"); if (!f) { perror(path); return 1; }
    if ((int64_t)fwrite(b, 1, n, f) != n || fclose(f)) { perror(path); return 1; }
    return 0;
}
/* ---- archive: "FMA\x01" | u32 nsolid | stream* ; stream = u64 length | FM4 stream.
   The first nsolid streams (bytes mode), decoded and joined, are the index followed by the solid data of every file, files sorted by extension.
   Index: u32 count | per file: u16 path length | path | u32 permissions | u64 size | u64 a | u64 b.
   For a file with b > 0, bytes [a, a+b) are not in the solid data but in a stream of their own (next in file order):
   PCM of a WAV in audio mode, pixels of a BMP/PPM in image mode, or a file that looks already compressed, stored. ---- */
typedef struct { char *path; uint8_t *d; int64_t size, a, b, width; int mode, perm; } Ent;
static Ent *ents; static int nents;
static void put64(uint8_t *p, uint64_t v) { for (int i = 0; i < 8; i++) p[i] = v >> (8 * i); }
/* Lexical normalization in place: drops leading "/", empty and "." components, resolves ".." against the
   components before it, keeps a trailing "/" (empty directory entries). Returns how many ".." went above
   the start, i.e. would leave the base directory. No filesystem lookups, so symlinks are not resolved. */
static int norm_path(char *p) {
    char *w = p, *r = p; int up = 0, dir = *p && p[strlen(p) - 1] == '/';
    while (*r) {
        while (*r == '/') r++;
        char *e = r; while (*e && *e != '/') e++;
        size_t len = e - r;
        if (len == 2 && r[0] == '.' && r[1] == '.') {
            if (w > p) { while (w > p && w[-1] != '/') w--; if (w > p) w--; } else up++;
        } else if (len && !(len == 1 && r[0] == '.')) {
            if (w > p) *w++ = '/';
            memmove(w, r, len); w += len;
        }
        r = e;
    }
    if (dir && w > p) *w++ = '/';
    *w = 0;
    return up;
}
/* log2(x) in 1/65536 units for x >= 1, integer only (libm's log2 may differ in the last bit between platforms) */
static int64_t log2_q16(uint64_t x) {
    int e = 63 - __builtin_clzll(x);
    uint64_t m = e <= 31 ? x << (31 - e) : x >> (e - 31);   /* mantissa in [2^31, 2^32) */
    int64_t r = (int64_t)e << 16;
    for (int b = 15; b >= 0; b--) { m = (m * m) >> 31; if (m >= (1ull << 32)) { m >>= 1; r |= (int64_t)1 << b; } }
    return r;
}
static void add_path(const char *path) {
#ifdef _WIN32
    /* stat follows symlinks and junctions; skip them as lstat does on POSIX (a junction to a parent would recurse).
       Only link-like reparse tags (the name-surrogate bit: symlinks, junctions, WSL symlinks); OneDrive
       placeholders, deduplicated files etc. are ordinary files. */
    WIN32_FIND_DATAA fd; HANDLE fh = FindFirstFileA(path, &fd);
    if (fh != INVALID_HANDLE_VALUE) {
        FindClose(fh);
        if ((fd.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) && IsReparseTagNameSurrogate(fd.dwReserved0)) {
            fprintf(stderr, "%s: not a regular file, skipped\n", path); return;
        }
    }
#endif
    struct stat st;
    if (lstat(path, &st)) { perror(path); exit(1); }
    if (S_ISDIR(st.st_mode)) {
        DIR *dir = opendir(path); struct dirent *de; int any = 0;
        if (!dir) { perror(path); exit(1); }
        while ((de = readdir(dir))) {
            if (!strcmp(de->d_name, ".") || !strcmp(de->d_name, "..")) continue;
            char *sub = xmalloc(strlen(path) + strlen(de->d_name) + 2);
            sprintf(sub, "%s/%s", path, de->d_name); add_path(sub); free(sub); any = 1;
        }
        closedir(dir);
        if (any) return;
    }
    if (S_ISREG(st.st_mode) || S_ISDIR(st.st_mode)) {   /* a file, or an empty directory (stored as a path ending in "/") */
        /* stored name: the path normalized; ".." above the start is dropped (like tar), so "../x" is stored as "x" */
        char *name = xmalloc(strlen(path) + 2); strcpy(name, path);
#ifdef _WIN32
        for (char *c = name; *c; c++) if (*c == '\\') *c = '/';   /* stored names always use '/' */
#endif
        if (norm_path(name)) fprintf(stderr, "%s: leading \"..\" removed, stored as %s\n", path, *name ? name : ".");
        if (strlen(name) > 65534) { fprintf(stderr, "%s: path too long\n", path); exit(1); }
        if (!(nents & (nents + 1))) ents = realloc(ents, (2 * nents + 2) * sizeof(Ent));
        Ent *e = &ents[nents++]; memset(e, 0, sizeof *e);
        e->perm = st.st_mode & 0777;
        if (S_ISDIR(st.st_mode)) { if (!*name) { nents--; free(name); return; } if (name[strlen(name) - 1] != '/') strcat(name, "/"); e->path = name; e->d = xmalloc(1); }
        else if (!*name) { fprintf(stderr, "%s: no file name, skipped\n", path); nents--; free(name); return; }
        else { e->path = name; e->d = map_in(path, &e->size); }
    } else fprintf(stderr, "%s: not a regular file, skipped\n", path);
}
static int ent_cmp(const void *x, const void *y) {
    const Ent *a = x, *b = y;
    const char *ea = strrchr(a->path, '.'), *eb = strrchr(b->path, '.');
    int c = strcmp(ea ? ea : "", eb ? eb : "");
    return c ? c : strcmp(a->path, b->path);
}
static int rd16(const uint8_t *p) { return p[0] | p[1] << 8; }
static void detect(Ent *e, int media) {
    uint8_t *d = e->d; int64_t n = e->size, a = 0, b = 0, w = 0; int mode = 0;
    if (media && n >= 44 && !memcmp(d, "RIFF", 4) && !memcmp(d + 8, "WAVE", 4)) {   /* WAV, 16-bit PCM */
        int ch = 0;
        for (int64_t p = 12; p + 8 <= n; ) {
            int64_t len = get32(d + p + 4);
            if (!memcmp(d + p, "fmt ", 4) && p + 24 <= n && rd16(d + p + 8) == 1 && rd16(d + p + 22) == 16) ch = rd16(d + p + 10);
            if (!memcmp(d + p, "data", 4)) {
                if (ch >= 1 && ch <= 8) { a = p + 8; b = len < n - a ? len : n - a; b -= b % (2 * ch); w = ch; mode = 3; }
                break;
            }
            p += 8 + len + (len & 1);
        }
    } else if (media && n >= 54 && d[0] == 'B' && d[1] == 'M' && rd16(d + 28) == 24 && !get32(d + 30)) {   /* BMP, 24-bit, rows without padding */
        w = get32(d + 18); a = get32(d + 10);
        if (w > 0 && w <= 65535 && w % 4 == 0 && a < n) { b = n - a; b -= b % (3 * w); mode = 2; }
    } else if (media && n >= 9 && d[0] == 'P' && d[1] == '6') {   /* PPM, 8-bit */
        char h[32] = {0}; int pw, ph, mv, off = 0;
        memcpy(h, d, n < 31 ? n : 31);
        if (sscanf(h, "P6 %d %d %d%n", &pw, &ph, &mv, &off) == 3 && off && mv == 255 && pw > 0 && pw <= 65535 && ph > 0) {
            w = pw; a = off + 1; b = n - a < 3 * w * ph ? n - a : 3 * w * ph; b -= b % (3 * w); mode = 2;
        }
    }
    if (b < 4096) { a = b = 0; mode = 0; }
    if (!mode && n >= 1024) {   /* already compressed? (byte entropy above 7.8 bits) -> store, do not spend time on it */
        int64_t cnt[256] = {0}, h = 0;   /* h = n * entropy in 1/65536 bits, integer only: same on every platform */
        for (int64_t i = 0; i < n; i++) cnt[d[i]]++;
        for (int i = 0; i < 256; i++) if (cnt[i]) h += cnt[i] * (log2_q16(n) - log2_q16(cnt[i]));
        if (h * 5 > n * 2555904) b = n;   /* 7.8 bits: 7.8 * 65536 * 5 = 2555904 */
    }
    e->a = a; e->b = b; e->mode = mode; e->width = w;
}
/* Streams are independent, so they are coded in parallel, one forked process each, results in shared memory. */
typedef struct { int mode, level; int64_t width, L, n; uint8_t *in, *out; long pid; } Job;
static uint8_t *job_out(int64_t L, void *j) { return L == ((Job *)j)->L ? ((Job *)j)->out : NULL; }   /* decode in place */
static int do_job(Job *j, int decode) {   /* 0 on success, 3: spec_missed, 1: failed */
    int64_t m;
    if (decode) { int bad = !fm4_decode_to(j->in, j->n, &m, job_out, j); return bad ? 1 : spec_missed() ? 3 : 0; }
    uint8_t *o = fm4_encode(j->level, j->mode, j->width, j->in, j->L, &m);
    put64(j->out, m); memcpy(j->out + 8, o, m); scratch_free(o, ENC_CAP(j->L));
    return spec_missed() ? 3 : 0;
}
/* a job's status into the total: 3 only while every failure was a spec miss, else 1 */
static int job_fail(int fail, int r) { return !r ? fail : r == 3 && fail != 1 ? 3 : 1; }
static int run_jobs(Job *jobs, int nj, int threads, int decode) {
    int fail = 0;
    if (!decode) {   /* out: u64 length | stream (at most L + HDR bytes), all in one shared buffer; decode: the caller's */
        int64_t all = 0; for (int i = 0; i < nj; i++) all += jobs[i].L + HDR + 8;
        uint8_t *o = shared_alloc(all);
        if (!o) { fputs("out of memory\n", stderr); return 1; }
        for (int i = 0; i < nj; i++) { jobs[i].out = o; o += jobs[i].L + HDR + 8; }
    }
#ifdef NO_FORK
    (void)threads;
    for (int i = 0; i < nj; i++) fail = job_fail(fail, do_job(&jobs[i], decode));
#else
    int next = 0, running = 0, st;
    while (next < nj || running) {
        if (next < nj && running < threads) {
            Job *j = &jobs[next++];
            fflush(NULL);
            if ((j->pid = fork()) < 0) { perror("fork"); return 1; }
            if (!j->pid) _exit(do_job(j, decode));
            running++;
        } else { fail = job_fail(fail, wait(&st) < 0 || !WIFEXITED(st) ? 1 : WEXITSTATUS(st)); running--; }
    }
#endif
    return fail;
}
static int archive(int level, int media, int threads, const char *out, char **paths, int np) {
    for (int i = 0; i < np; i++) add_path(paths[i]);
    qsort(ents, nents, sizeof(Ent), ent_cmp);
    int64_t n = 4, total = 0; int nown = 0;
    for (int i = 0; i < nents; i++) { Ent *e = &ents[i]; detect(e, media); n += 30 + strlen(e->path) + e->size - e->b; total += e->size; nown += e->b > 0; }
    uint8_t *s = shared_alloc(n), *p = s;   /* index + solid data (file-backed when large) */
    if (!s) { fputs("out of memory\n", stderr); return 1; }
    for (int i = 0; i < 4; i++) *p++ = (uint32_t)nents >> (8 * i);
    for (int i = 0; i < nents; i++) {
        Ent *e = &ents[i]; int pl = strlen(e->path);
        *p++ = pl; *p++ = pl >> 8; memcpy(p, e->path, pl); p += pl;
        for (int k = 0; k < 4; k++) *p++ = (uint32_t)e->perm >> (8 * k);
        put64(p, e->size); put64(p + 8, e->a); put64(p + 16, e->b); p += 24;
    }
    for (int i = 0; i < nents; i++) {
        Ent *e = &ents[i];
        memcpy(p, e->d, e->a); p += e->a;
        memcpy(p, e->d + e->a + e->b, e->size - e->a - e->b); p += e->size - e->a - e->b;
    }
    /* the solid data is cut into n / PART_MB equal parts (default 8 MB, so each is at least that): costs a little
       size, lets encoding and decoding run in parallel. The cut depends only on the data, never on the thread
       count, so the archive is the same on every machine. */
    int64_t part = (int64_t)((getenv("PART_MB") ? atof(getenv("PART_MB")) : 8) * 1048576);
    int nsolid = part > 0 && n / part > 1 ? (int)(n / part) : 1, nj = 0;
    Job *jobs = xcalloc(nsolid + nown, sizeof(Job));
    for (int k = 0; k < nsolid; k++) { int64_t lo = n * k / nsolid, hi = n * (k + 1) / nsolid; jobs[nj++] = (Job){1, level, 0, hi - lo, 0, s + lo, NULL, 0}; }
    for (int i = 0; i < nents; i++) { Ent *e = &ents[i]; if (e->b) jobs[nj++] = (Job){e->mode, e->mode ? level : 0, e->width, e->b, 0, e->d + e->a, NULL, 0}; }
    int jr = run_jobs(jobs, nj, threads, 0);
    if (jr) { if (jr == 1) fprintf(stderr, "compression failed\n"); return jr; }
    FILE *f = fopen(out, "wb"); if (!f) { perror(out); return 1; }
    int64_t written = 8, k = nsolid; uint8_t n4[4] = {nsolid, nsolid >> 8, nsolid >> 16, nsolid >> 24};
    fwrite("FMA\x01", 1, 4, f); fwrite(n4, 1, 4, f);
    for (int i = 0; i < nj; i++) { int64_t m = get64(jobs[i].out); fwrite(jobs[i].out, 1, 8 + m, f); written += 8 + m; }
    for (int i = 0; i < nsolid; i++) fprintf(stderr, "solid  %12lld -> %12lld  (index and all other data, part %d of %d)\n", (long long)jobs[i].L, (long long)get64(jobs[i].out), i + 1, nsolid);
    for (int i = 0; i < nents; i++) { Ent *e = &ents[i]; if (e->b) { fprintf(stderr, "%-6s %12lld -> %12lld  %s\n", e->mode == 3 ? "audio" : e->mode == 2 ? "image" : "stored", (long long)e->b, (long long)get64(jobs[k].out), e->path); k++; } }
    if (fclose(f)) { perror(out); return 1; }
    fprintf(stderr, "%d files, %lld -> %lld bytes\n", nents, (long long)total, (long long)written);
    return 0;
}
static int extract(const char *in, const char *dir, int threads) {
    int64_t n, sn = 0, all = 0; uint8_t *f = map_in(in, &n);
    if (n < 8 || memcmp(f, "FMA\x01", 4)) { fprintf(stderr, "not an FMA archive\n"); return 1; }
    int64_t nsolid = get32(f + 4), nj = 0, cap = 0; Job *jobs = NULL;
    for (int64_t pos = 8; pos < n; ) {   /* list the streams, then decode them all in parallel into one shared buffer */
        if (n - pos < 8 + HDR) goto bad;
        int64_t m = get64(f + pos), L = get64(f + pos + 8 + 16);
        if (m > n - pos - 8 || !stream_ok(f + pos + 8, m, L) || all + L < all) goto bad;
        if (nj == cap) jobs = alloc_ok(realloc(jobs, (cap = 2 * cap + 16) * sizeof(Job)));
        jobs[nj] = (Job){0, 0, 0, L, m, f + pos + 8, NULL, 0};
        if (nj++ < nsolid) sn += L;
        all += L; pos += 8 + m;
    }
    if (nsolid < 1 || nj < nsolid || sn < 4) goto bad;
    if (mkdir(dir, 0777) && errno != EEXIST) { perror(dir); return 1; }
    uint8_t *s = shared_alloc(all), *o = s;   /* every decoded stream (file-backed when large) */
    if (!s) goto bad;
    for (int64_t i = 0; i < nj; i++) { jobs[i].out = o; o += jobs[i].L; }
    int jr = run_jobs(jobs, nj, threads, 1);
    if (jr == 3) return 3;
    if (jr) goto bad;
    int64_t count = get32(s), ip = 4, total = 0, k = nsolid;
    for (int64_t i = 0; i < count; i++) {   /* first pass over the index: find where the data starts */
        if (sn - ip < 2 || sn - ip < 30 + rd16(s + ip)) goto bad;
        ip += 30 + rd16(s + ip);
    }
    uint8_t *q = s + ip; ip = 4;
    /* ponytail: an existing symlink inside the target directory is followed; extract into a fresh directory if the archive is untrusted */
    for (int64_t i = 0; i < count; i++) {
        int pl = rd16(s + ip); char *name = xmalloc(strlen(dir) + pl + 2), *rel = name + strlen(dir) + 1;
        sprintf(name, "%s/", dir); memcpy(rel, s + ip + 2, pl); rel[pl] = 0; ip += 2 + pl;
        int perm = get32(s + ip) & 0777; int64_t size = get64(s + ip + 4), a = get64(s + ip + 12), b = get64(s + ip + 20); ip += 28;
        /* the stored name is normalized again here and must stay inside DIR: not absolute, no ".." above the start */
#ifdef _WIN32
        /* '\\' is a separator there and ':' a drive or stream: either could leave DIR (archives store '/' only) */
        if (strpbrk(rel, "\\:")) { fprintf(stderr, "unsafe path in archive: %.*s\n", pl, s + ip - 28 - pl); return 1; }
#endif
        if ((int64_t)strlen(rel) != pl || rel[0] == '/' || norm_path(rel) || !*rel) { fprintf(stderr, "unsafe path in archive: %.*s\n", pl, s + ip - 28 - pl); return 1; }
        pl = strlen(rel);
        if (size < 0 || a < 0 || b < 0 || a > size || b > size - a || size - b > s + sn - q) goto bad;
        if (b && (k >= nj || jobs[k].L != b)) goto bad;
        uint8_t *own = b ? jobs[k++].out : NULL;
        for (char *c = rel; (c = strchr(c, '/')); *c++ = '/') { *c = 0; if (mkdir(name, 0777) && errno != EEXIST) { perror(name); return 1; } }
        if (pl && rel[pl - 1] != '/') {
            FILE *w = fopen(name, "wb"); if (!w) { perror(name); return 1; }
            fwrite(q, 1, a, w); if (b) fwrite(own, 1, b, w); fwrite(q + a, 1, size - a - b, w);
            if (fclose(w)) { perror(name); return 1; }
        }
        chmod(name, perm);
        q += size - b; total += size; free(name);
    }
    fprintf(stderr, "%lld files, %lld bytes\n", (long long)count, (long long)total);
    return 0;
bad:
    fprintf(stderr, "corrupt archive\n"); return 1;
}
/* Segments (every mode): "FMS\x01" | u32 nseg | nseg x (u64 length | FM4 stream). Inputs of at least
   2 x SEG_MB (default 64 MB) are cut into L / SEG_MB equal runs of whole units (bytes: a byte; image: a row;
   video: a frame; audio: a sample of every channel), so the cut depends only on the data, never on the thread
   count; smaller inputs stay one plain FM4 stream. Each segment is an independent stream, coded in parallel
   (each costs its model's memory: 60-630 MB by level). */
static int64_t seg_unit(int mode, int64_t width) {
    return mode == 2 ? 3 * (width & 0xFFFF) * ((width >> 16) ? width >> 16 : 1) : mode == 3 ? 2 * width : 1;
}
static int64_t segments(int64_t L, int64_t unit) {
    int64_t seg = (int64_t)((getenv("SEG_MB") ? atof(getenv("SEG_MB")) : 64) * 1048576), nu = L / unit;
    int64_t ns = seg > 0 ? L / seg : 1;
    return ns > nu ? (nu > 0 ? nu : 1) : (ns < 1 ? 1 : ns);
}
static int enc_segments(int level, int mode, int64_t width, uint8_t *data, int64_t L, int64_t ns, int threads, const char *out) {
    int64_t unit = seg_unit(mode, width), nu = L / unit;
    Job *jobs = xcalloc(ns, sizeof(Job));
    for (int64_t k = 0; k < ns; k++) {
        int64_t a = nu * k / ns * unit, b = nu * (k + 1) / ns * unit;
        jobs[k] = (Job){mode, level, width, b - a, 0, data + a, NULL, 0};
    }
    int jr = run_jobs(jobs, ns, threads, 0);
    if (jr) { if (jr == 1) fprintf(stderr, "compression failed\n"); return jr; }
    FILE *f = fopen(out, "wb"); if (!f) { perror(out); return 1; }
    uint8_t h[8] = {'F', 'M', 'S', 1}; for (int i = 0; i < 4; i++) h[4 + i] = (uint64_t)ns >> (8 * i);
    fwrite(h, 1, 8, f);
    for (int64_t k = 0; k < ns; k++) fwrite(jobs[k].out, 1, 8 + get64(jobs[k].out), f);
    if (fclose(f)) { perror(out); return 1; }
    return 0;
}
static int dec_segments(uint8_t *f, int64_t n, int threads, Out *out) {   /* 0 on success, 1: corrupt or failed */
    int64_t ns = get32(f + 4), all = 0, pos = 8;
    if (ns > (n - 8) / (8 + HDR)) return 1;   /* each segment takes at least 8 + HDR bytes */
    Job *jobs = xcalloc(ns ? ns : 1, sizeof(Job));
    int r = 1;
    for (int64_t k = 0; k < ns; k++) {
        if (n - pos < 8 + HDR) goto done;
        int64_t m = get64(f + pos), L = get64(f + pos + 8 + 16);
        if (m > n - pos - 8 || !stream_ok(f + pos + 8, m, L) || all + L < all) goto done;
        jobs[k] = (Job){0, 0, 0, L, m, f + pos + 8, NULL, 0};
        all += L; pos += 8 + m;
    }
    if (pos != n) goto done;
    /* the segments decode straight into the output file (lengths bounded by the input) */
    uint8_t *d = out_open(out, all), *o = d;
    if (!d) goto done;
    for (int64_t k = 0; k < ns; k++) { jobs[k].out = o; o += jobs[k].L; }
    int jr = run_jobs(jobs, ns, threads, 1);
    r = out_close(out, !jr);
    if (jr == 3) r = 3;
done:
    free(jobs);
    return r;
}
static uint8_t *out_get(int64_t L, void *ctx) { return out_open(ctx, L); }
static int ncpu(void) {
#ifdef NO_FORK
    return 1;
#else
    long n = sysconf(_SC_NPROCESSORS_ONLN);
    return n > 0 ? (int)n : 1;
#endif
}
int main(int argc, char **argv) {
    init_tables();
    if (getenv("HUGE")) OPT_HUGE = atoi(getenv("HUGE"));
    if (getenv("FM4_BIG")) BIG = atoll(getenv("FM4_BIG")) > 0 ? atoll(getenv("FM4_BIG")) : 1;
    if (argc >= 3 && (!strcmp(argv[1], "a") || !strcmp(argv[1], "x"))) {   /* fm4 a [-m auto|bytes] [-t N] LEVEL OUT PATH... | fm4 x [-t N] IN [DIR] */
        int media = 1, k = 2, threads = ncpu();
        for (; k + 1 < argc && argv[k][0] == '-'; k += 2) {
            if (!strcmp(argv[k], "-m") && (!strcmp(argv[k + 1], "bytes") || !strcmp(argv[k + 1], "auto"))) media = argv[k + 1][0] == 'a';
            else if (!strcmp(argv[k], "-t") && atoi(argv[k + 1]) > 0) threads = atoi(argv[k + 1]);
            else goto usage;
        }
        if (argv[1][0] == 'x') {
            if (argc - k < 1 || argc - k > 2) goto usage;
            scratch_dir_for(argc - k == 2 ? argv[k + 1] : ".", 1);
            return extract(argv[k], argc - k == 2 ? argv[k + 1] : ".", threads);
        }
        if (argc < k + 3 || argv[k][0] < '0' || argv[k][0] > '5' || argv[k][1]) goto usage;
        if (getenv("LR") && ((LR = atoi(getenv("LR"))) < 1 || LR > 15)) { fprintf(stderr, "LR must be 1-15\n"); return 2; }
        scratch_dir_for(argv[k + 1], 0);
        return archive(argv[k][0] - '0', media, threads, argv[k + 1], argv + k + 2, argc - k - 2);
    }
    int threads = ncpu();
    if (argc >= 4 && (!strcmp(argv[1], "enc") || !strcmp(argv[1], "dec")) && !strcmp(argv[2], "-t")) {   /* fm4 enc|dec -t N ... */
        if ((threads = atoi(argv[3])) < 1) goto usage;
        memmove(argv + 2, argv + 4, (argc - 3) * sizeof *argv); argc -= 2;
    }
    if (argc >= 6 && !strcmp(argv[1], "enc")) {
        int level = atoi(argv[2]), video = !strcmp(argv[3], "video"), mode = !strcmp(argv[3], "image") || video ? 2 : !strcmp(argv[3], "audio") ? 3 : 1;
        int64_t width = mode >= 2 ? atoll(argv[4]) : 0, fheight = video ? atoll(argv[5]) : 0, L, n;
        if (level < 0 || level > 5 || (mode >= 2 && argc < 7 + video)) goto usage;
        if (getenv("LR") && ((LR = atoi(getenv("LR"))) < 1 || LR > 15)) { fprintf(stderr, "LR must be 1-15\n"); return 2; }
        uint8_t *data = map_in(argv[(mode >= 2 ? 5 : 4) + video], &L);
        scratch_dir_for(argv[(mode >= 2 ? 6 : 5) + video], 0);
        if (mode == 2 && (width <= 0 || width > 65535 || L % (3 * width))) { fprintf(stderr, "bad width\n"); return 1; }
        if (video && (width > 65535 || fheight <= 0 || fheight > 65535 || L % (3 * width * fheight))) { fprintf(stderr, "video: bad frame size\n"); return 1; }
        if (video) width |= fheight << 16;
        if (mode == 3 && (width <= 0 || width > 8 || L % (2 * width))) { fprintf(stderr, "audio: need 1-8 channels and a whole number of 16-bit frames\n"); return 1; }
        int64_t ns = segments(L, seg_unit(mode, width));
        if (ns > 1) return enc_segments(level, mode, width, data, L, ns, threads, argv[(mode >= 2 ? 6 : 5) + video]);
        uint8_t *o = fm4_encode(level, mode, width, data, L, &n);
        if (spec_missed()) { scratch_free(o, ENC_CAP(L)); return 3; }
        int r = spit(argv[(mode >= 2 ? 6 : 5) + video], o, n);
        scratch_free(o, ENC_CAP(L)); return r;
    }
    if (argc == 4 && !strcmp(argv[1], "dec")) {
        int64_t n, L; uint8_t *f = map_in(argv[2], &n);
        scratch_dir_for(argv[3], 0);
        static Out o; o.path = argv[3];
        int bad;
        if (n >= 8 && !memcmp(f, "FMS\x01", 4)) bad = dec_segments(f, n, threads, &o);
        else {   /* decode straight into the output file */
            uint8_t *d = fm4_decode_to(f, n, &L, out_get, &o);
            if (d && spec_missed()) { out_close(&o, 0); return 3; }
            bad = o.p ? out_close(&o, d != NULL) : 1;
        }
        if (bad == 3) return 3;   /* a segment's spec_missed (reported) */
        if (bad && !o.ioerr) fprintf(stderr, "not an FM4 file, or corrupt\n");   /* (I/O errors were reported) */
        return bad;
    }
usage:
    fprintf(stderr, "usage: fm4 enc LEVEL(0-5) bytes IN OUT\n"
                    "       fm4 enc LEVEL image WIDTH IN OUT          raw RGB24\n"
                    "       fm4 enc LEVEL audio CHANNELS IN OUT       raw 16-bit little-endian PCM\n"
                    "       fm4 enc LEVEL video WIDTH HEIGHT IN OUT   raw RGB24 frames\n"
                    "       fm4 dec IN OUT\n"
                    "       fm4 enc|dec -t N ...                      processes for segments (default: all cores);\n"
                    "                                                 inputs of 128 MB and more are cut into segments of >= 64 MB\n"
                    "       fm4 a [-m auto|bytes] [-t N] LEVEL OUT PATH...   archive files and directories\n"
                    "             -m auto (default): audio model for WAV, image model for BMP/PPM; -m bytes: neither\n"
                    "             -t N: processes (default: all cores); solid data is cut into parts of >= 8 MB (same file for any N)\n"
                    "       fm4 x [-t N] IN [DIR]                            extract an archive\n"
                    "       env FEAT, FEAT2, BB, LR, HUGE, PART_MB (archive), SEG_MB (segments) for experiments\n");
    return 2;
}
