/* Model fraction (FRC1), C port.  Integer-only spec shared by every port, so
 * outputs are byte-identical across languages.
 *
 *   fm enc bytes IN OUT          fm enc image WIDTH IN OUT (IN = raw RGB24)
 *   fm dec IN OUT
 *
 * File: "FRC1" | mode u8 (0 bytes, 1 image) | width u32le | L u32le | N bytes
 * The data is the fraction N / 256^len(N), decoded through the model below.
 *
 * Spec (all arithmetic on u32 wraps; >> on signed values is arithmetic):
 *  H(k,a,b,c): h=(k+1)*0x9E3779B1; h=(h^a)*0x85EBCA6B; h^=h>>13;
 *              h=(h^b)*0xC2B2AE35; h^=h>>16; h=(h^c)*0x85EBCA6B; h^=h>>15
 *  per bit, input k: slot = (ctx_k + c0*0x9E3779B1) & (2^22-1), c0 = 1,then 1b,1bb,...
 *  bytes ctx: k in {0,1,2,3,4,6}: H(k, c4 & mask_k, k==6 ? c8&0xFFFF : 0, 0)
 *             c4 = last 4 bytes (newest low), c8 = the 4 before; mask_k = 2^(8k)-1 (k<4)
 *  image ctx: MED predictor; ea/eb/ep = clamp(err,-12,12)+16 of left/up/prev-channel
 *             (0+16 when missing, ep=255 for ch 0), g = bitlen(|a-c|+|b-c|)
 *             H(10,ch,0,0) H(11,ch,ea,0) H(12,ch,eb,0) H(13,ch,ep,0)
 *             H(14,ch,ea,eb) H(15,ch,ep,g) H(16,ch,ep,ea);  symbol = (pix-med)&255
 *  counter: p u16 (init 32768), n u8; p += ((bit<<16)-p)*RECIP[n] >> 15,
 *           RECIP[n]=65536/(2n+3), clamp 0..65535, n<60 -> n++
 *  mixer:   8 weight sets (by bit position), w init 19661; st=STRETCH[p>>4];
 *           p12 = clamp(squash((sum w*st) >> 16), 1, 4095)
 *           w += (st*((bit<<12)-p12)*20) >> 14, clamp +-2^22
 *  coder:   32-bit binary arithmetic coder, p12 = P(bit=1), flush x1 (4 bytes),
 *           strip trailing zero bytes (decoder pads zeros)
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define TBITS 22
#define TSIZE (1u << TBITS)
#define TMASK (TSIZE - 1)
#define MAXIN 7

static int SQ_T[33] = {1, 2, 3, 6, 10, 16, 27, 45, 73, 120, 194, 310, 488, 747, 1101, 1546, 2047,
                       2549, 2994, 3348, 3607, 3785, 3901, 3975, 4022, 4050, 4068, 4079, 4085, 4089, 4092, 4093, 4094};
static int STRETCH[4096];
static int RECIP[64];

static int squash(int d) {
    if (d > 2047) return 4095;
    if (d < -2047) return 1;
    int w = d & 127, i = (d >> 7) + 16;
    return (SQ_T[i] * (128 - w) + SQ_T[i + 1] * w + 64) >> 7;
}

static void init_tables(void) {
    int pi = 0;
    for (int x = -2047; x <= 2047; x++) {
        int v = squash(x);
        for (int j = pi; j <= v; j++) STRETCH[j] = x;
        pi = v + 1;
    }
    for (int j = pi; j < 4096; j++) STRETCH[j] = 2047;
    for (int n = 0; n < 64; n++) RECIP[n] = 65536 / (2 * n + 3);
}

static uint32_t H(uint32_t k, uint32_t a, uint32_t b, uint32_t c) {
    uint32_t h = (k + 1) * 0x9E3779B1u;
    h = (h ^ a) * 0x85EBCA6Bu; h ^= h >> 13;
    h = (h ^ b) * 0xC2B2AE35u; h ^= h >> 16;
    h = (h ^ c) * 0x85EBCA6Bu; h ^= h >> 15;
    return h;
}

/* ---- arithmetic coder ---- */
typedef struct {
    uint32_t x1, x2, x;
    uint8_t *buf; size_t len, pos, cap;  /* output (enc) or input (dec) */
    int decoding;
} Coder;

static int code_bit(Coder *c, int p12, int bit) {
    uint32_t xmid = c->x1 + ((c->x2 - c->x1) >> 12) * (uint32_t)p12;
    if (c->decoding) bit = c->x <= xmid;
    if (bit) c->x2 = xmid; else c->x1 = xmid + 1;
    while (((c->x1 ^ c->x2) & 0xFF000000u) == 0) {
        if (c->decoding) {
            uint8_t b = c->pos < c->len ? c->buf[c->pos] : 0;
            c->pos++;
            c->x = (c->x << 8) | b;
        } else {
            if (c->len == c->cap) { c->cap = c->cap ? c->cap * 2 : 1 << 16; c->buf = realloc(c->buf, c->cap); }
            c->buf[c->len++] = c->x2 >> 24;
        }
        c->x1 <<= 8; c->x2 = (c->x2 << 8) | 255;
    }
    return bit;
}

/* ---- model + main loop (encode when !c->decoding: data holds input) ---- */
static void run(Coder *c, int mode, uint32_t width, uint8_t *data, uint32_t L) {
    int nin = mode ? 7 : 6;
    uint16_t *P[MAXIN]; uint8_t *N[MAXIN];
    for (int k = 0; k < nin; k++) {
        P[k] = malloc(TSIZE * 2); N[k] = calloc(TSIZE, 1);
        for (uint32_t j = 0; j < TSIZE; j++) P[k][j] = 32768;
    }
    int32_t W[8][MAXIN];
    for (int b = 0; b < 8; b++) for (int k = 0; k < nin; k++) W[b][k] = 19661;
    int16_t *err = mode ? calloc(L ? L : 1, 2) : NULL;
    static const int ORD[6] = {0, 1, 2, 3, 4, 6};
    uint32_t c4 = 0, c8 = 0, ctx[MAXIN], idx[MAXIN];
    int st[MAXIN];

    for (uint32_t i = 0; i < L; i++) {
        int med = 0;
        if (mode == 0) {
            for (int k = 0; k < 6; k++) {
                int o = ORD[k];
                uint32_t m = o >= 4 ? 0xFFFFFFFFu : ((1u << (8 * o)) - 1);
                ctx[k] = H(o, c4 & m, o == 6 ? (c8 & 0xFFFF) : 0, 0);
            }
        } else {
            uint32_t ch = i % 3, x = (i / 3) % width;
            int64_t up = (int64_t)i - 3 * (int64_t)width;
            int a = x ? data[i - 3] : (up >= 0 ? data[up] : 0);
            int b = up >= 0 ? data[up] : a;
            int cc = (up >= 0 && x) ? data[up - 3] : b;
            int mx = a > b ? a : b, mn = a < b ? a : b;
            med = cc >= mx ? mn : (cc <= mn ? mx : a + b - cc);
#define Q(e) ((uint32_t)(((e) < -12 ? -12 : ((e) > 12 ? 12 : (e))) + 16))
            uint32_t ea = x ? Q(err[i - 3]) : 16, eb = up >= 0 ? Q(err[up]) : 16, ep = ch ? Q(err[i - 1]) : 255;
            int gv = abs(a - cc) + abs(b - cc);
            uint32_t g = gv ? 32 - __builtin_clz(gv) : 0;
            ctx[0] = H(10, ch, 0, 0); ctx[1] = H(11, ch, ea, 0); ctx[2] = H(12, ch, eb, 0);
            ctx[3] = H(13, ch, ep, 0); ctx[4] = H(14, ch, ea, eb); ctx[5] = H(15, ch, ep, g);
            ctx[6] = H(16, ch, ep, ea);
        }
        int sym = c->decoding ? 0 : (mode ? ((data[i] - med) & 255) : data[i]);
        uint32_t c0 = 1;
        for (int bp = 0; bp < 8; bp++) {
            int32_t *w = W[bp];
            int64_t dot = 0;
            for (int k = 0; k < nin; k++) {
                idx[k] = (ctx[k] + c0 * 0x9E3779B1u) & TMASK;
                st[k] = STRETCH[P[k][idx[k]] >> 4];
                dot += (int64_t)w[k] * st[k];
            }
            int p12 = squash((int)(dot >> 16));
            p12 = p12 < 1 ? 1 : (p12 > 4095 ? 4095 : p12);
            int bit = code_bit(c, p12, (sym >> (7 - bp)) & 1);
            int e = (bit << 12) - p12;
            for (int k = 0; k < nin; k++) {
                int32_t nw = w[k] + ((st[k] * e * 20) >> 14);
                w[k] = nw > (1 << 22) ? (1 << 22) : (nw < -(1 << 22) ? -(1 << 22) : nw);
                uint32_t j = idx[k];
                int n = N[k][j];
                int p = P[k][j] + ((((bit << 16) - P[k][j]) * RECIP[n]) >> 15);
                P[k][j] = p < 0 ? 0 : (p > 65535 ? 65535 : p);
                if (n < 60) N[k][j] = n + 1;
            }
            c0 = c0 * 2 + bit;
        }
        uint8_t byte = c0 & 255;
        if (mode == 0) {
            if (c->decoding) data[i] = byte;
            c8 = (c8 << 8) | (c4 >> 24); c4 = (c4 << 8) | data[i];
        } else {
            if (c->decoding) data[i] = (med + byte) & 255;
            err[i] = data[i] - med;
        }
    }
    for (int k = 0; k < nin; k++) { free(P[k]); free(N[k]); }
    free(err);
}

static uint8_t *slurp(const char *path, size_t *n) {
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); exit(1); }
    fseek(f, 0, SEEK_END); *n = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *b = malloc(*n ? *n : 1);
    if (fread(b, 1, *n, f) != *n) { perror("read"); exit(1); }
    fclose(f);
    return b;
}

static void put32(uint8_t *p, uint32_t v) { for (int i = 0; i < 4; i++) p[i] = v >> (8 * i); }
static uint32_t get32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }

int main(int argc, char **argv) {
    init_tables();
    if (argc >= 5 && !strcmp(argv[1], "enc")) {
        int mode = !strcmp(argv[2], "image");
        uint32_t width = mode ? strtoul(argv[3], 0, 10) : 0;
        const char *in = argv[3 + mode], *out = argv[4 + mode];
        size_t L; uint8_t *data = slurp(in, &L);
        if (mode && (width == 0 || L % (3 * width))) { fprintf(stderr, "bad width\n"); return 1; }
        if (L > 0xFFFFFFFFu) { fprintf(stderr, "input > 4 GB\n"); return 1; }
        Coder c = {0, 0xFFFFFFFFu, 0, NULL, 0, 0, 0, 0};
        run(&c, mode, width, data, (uint32_t)L);
        for (int i = 3; i >= 0; i--) {  /* flush x1 */
            if (c.len == c.cap) { c.cap = c.cap ? c.cap * 2 : 16; c.buf = realloc(c.buf, c.cap); }
            c.buf[c.len++] = c.x1 >> (8 * i);
        }
        while (c.len && c.buf[c.len - 1] == 0) c.len--;
        uint8_t hdr[13] = {'F', 'R', 'C', '1', (uint8_t)mode};
        put32(hdr + 5, width); put32(hdr + 9, (uint32_t)L);
        FILE *f = fopen(out, "wb");
        fwrite(hdr, 1, 13, f); fwrite(c.buf, 1, c.len, f); fclose(f);
        return 0;
    }
    if (argc == 4 && !strcmp(argv[1], "dec")) {
        size_t n; uint8_t *f = slurp(argv[2], &n);
        if (n < 13 || memcmp(f, "FRC1", 4)) { fprintf(stderr, "not an FRC1 file\n"); return 1; }
        int mode = f[4]; uint32_t width = get32(f + 5), L = get32(f + 9);
        Coder c = {0, 0xFFFFFFFFu, 0, f + 13, n - 13, 0, 0, 1};
        for (int i = 0; i < 4; i++) c.x = (c.x << 8) | (c.pos < c.len ? c.buf[c.pos] : 0), c.pos++;
        uint8_t *data = malloc(L ? L : 1);
        run(&c, mode, width, data, L);
        FILE *o = fopen(argv[3], "wb");
        fwrite(data, 1, L, o); fclose(o);
        return 0;
    }
    fprintf(stderr, "usage: fm enc bytes IN OUT | fm enc image WIDTH IN OUT | fm dec IN OUT\n");
    return 2;
}
