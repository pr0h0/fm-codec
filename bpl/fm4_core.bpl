# fm4 core (BPL). Same spec as c/fm4.c -> byte-identical output (see that file's header comment).
# Shared by the native CLI (fm4_cli.bpl) and the WebAssembly build (fm4_wasm.bpl).
# All working memory comes from reusable global buffers: wasm32 freestanding malloc is a bump
# allocator whose free() is a no-op, so repeated encode/decode calls must not allocate afresh.
# The model loop is runChunk(); run() calls it for 16 KB of input at a time (see runChunk).
# Helpers are @[unchecked] leaf functions (no index/null checks, no stack guard); runChunk itself keeps
# its checks, as it also decodes untrusted input.
# The OLS predictor is floating point: every expression keeps the exact operation order of
# ols_pred / ols_upd in c/fm4.c (no fused multiply-add, no reordering); sqrt and floor are the
# LLVM intrinsics (sqrtsd / f64.sqrt), which are correctly rounded like libm's.
import malloc, free, memset, memcpy from "std/c.bpl";
import sqrt, floor, prefetch from "std/intrinsics.bpl";
extern exit(code: int);
extern puts(s: string) ret int;

global HDR: long = 36;    # header size, format 2 (format 1: 28)
global HDR1: long = 28;
global BB_MIN: int = 12;       # table bits a stream may use (c/fm4.c BB_MIN, BB_DEC_MAX); the encoder writes <= 20
global BB_DEC_MAX: int = 22;
global CRC_T: *uint = nullptr;
global G_END: long = 0;   # decoding stops once G_POS passes it (format 2)
global G_CRC: uint = 0;   # CRC-32 of the data being encoded
global ANY_FEAT: bool = false;   # fm4AllowAnyParams(): accept files from FEAT/FEAT2/LR experiments (trusted input)

# Allocation failure ends the process with status 1 (native) or traps (wasm, the host gets an exception):
# it comes from corrupt or hostile sizes and must not turn into a null dereference.
frame xalloc(n: long) ret *u8 {
    local p: *u8 = cast<*u8>(malloc(n));
    if (p == nullptr) {
        if (!__TARGET_WASM__) {
            puts("out of memory");   # the wasm runtime has no output; the trap reaches the host as an exception
        }
        exit(1);
    }
    return p;
}
global SQ_T: *int = nullptr;
global STRETCH: *int = nullptr;
global RECIP: *int = nullptr;
global LR: int = 4;

# coder state (shared with encodeOne / fm4Decode)
global G_X1: uint = 0;
global G_X2: uint = 0;
global G_X: uint = 0;
global G_BUF: *u8 = nullptr;
global G_LEN: long = 0;
global G_POS: long = 0;
global G_CAP: long = 0;
global G_DEC: bool = false;
global G_OVF: bool = false;

# reusable buffers
global AR_RAW: *u8 = nullptr;
global AR_BASE: *u8 = nullptr;
global AR_CAP: long = 0;
global AR_USED: long = 0;
global OB0: *u8 = nullptr;
global OB_CAP: long = 0;
global DB: *u8 = nullptr;
global DB_CAP: long = 0;
global IB: *u8 = nullptr;
global IB_CAP: long = 0;
global RESULT: *u8 = nullptr;

# model state that lives across runChunk calls (everything else is in the arena or rebuilt per call)
global S_MPTR: long = 0;
global S_MLEN: long = 0;
global S_MPTR2: long = 0;
global S_MLEN2: long = 0;
global S_LINESTART: long = 0;
global S_PREVLINE: long = 0;
global S_INDENT: long = 0;
global S_ININD: bool = true;
global S_IMPTR: long = 0;
global S_IMLEN: long = 0;
global S_IMOK: bool = false;
global S_C4: uint = 0;
global S_C8: uint = 0;
global S_W0: uint = 0;
global S_W1H: uint = 0;
global S_W2H: uint = 0;
global S_OLC0: int = 0;
global S_OLC1: int = 0;
global S_OLC2: int = 0;
global S_APRED: int = 0;
global S_AZIG: int = 0;
global S_AHI: int = 0;
global S_AQ: int = 0;
global S_ACH: int = 0;
# bytes per runChunk call
global CHUNK: long = 16384;

@[unchecked]
frame ptrAdd(p: *u8, off: long) ret *u8 {
    return cast<*u8>(cast<long>(p) + off);
}

@[unchecked]
frame squash(d: int) ret int {
    if (d > 2047) {
        return 4095;
    }
    if (d < -2047) {
        return 1;
    }
    local w: int = d & 127;
    local i: int = (d >> 7) + 16;
    return (SQ_T[i] * (128 - w) + SQ_T[i + 1] * w + 64) >> 7;
}

frame initTables() {
    if (SQ_T != nullptr) {
        return;
    }
    SQ_T = cast<*int>(xalloc(33 * 4));
    local vals: int[33] = [1, 2, 3, 6, 10, 16, 27, 45, 73, 120, 194, 310, 488, 747, 1101, 1546, 2047, 2549, 2994, 3348, 3607, 3785, 3901, 3975, 4022, 4050, 4068, 4079, 4085, 4089, 4092, 4093, 4094];
    loop (local i: int = 0; i < 33; i = i + 1) {
        SQ_T[i] = vals[i];
    }
    STRETCH = cast<*int>(xalloc(4096 * 4));
    local pi: int = 0;
    loop (local x: int = -2047; x <= 2047; x = x + 1) {
        local v: int = squash(x);
        loop (local j: int = pi; j <= v; j = j + 1) {
            STRETCH[j] = x;
        }
        pi = v + 1;
    }
    loop (local j: int = pi; j < 4096; j = j + 1) {
        STRETCH[j] = 2047;
    }
    CRC_T = cast<*uint>(xalloc(256 * 4));
    loop (local i: uint = 0; i < cast<uint>(256); i = i + cast<uint>(1)) {
        local c: uint = i;
        loop (local k: int = 0; k < 8; k = k + 1) {
            c = ((c & cast<uint>(1)) != cast<uint>(0)) ? (cast<uint>(0xEDB88320) ^ (c >> cast<uint>(1))) : (c >> cast<uint>(1));
        }
        CRC_T[i] = c;
    }
    RECIP = cast<*int>(xalloc(256 * 4));
    loop (local n: int = 0; n < 256; n = n + 1) {
        RECIP[n] = 65536 / (2 * n + 3);
    }
}

@[unchecked]
frame hash4(k: uint, a: uint, b: uint, c: uint) ret uint {
    local h: uint = (k + cast<uint>(1)) * cast<uint>(0x9E3779B1);
    h = (h ^ a) * cast<uint>(0x85EBCA6B);
    h = h ^ (h >> 13);
    h = (h ^ b) * cast<uint>(0xC2B2AE35);
    h = h ^ (h >> 16);
    h = (h ^ c) * cast<uint>(0x85EBCA6B);
    h = h ^ (h >> 15);
    return h;
}

@[unchecked]
frame nibHash(ctx: uint, c0: uint) ret uint {
    local x: uint = ctx + c0 * cast<uint>(0x9E3779B1);
    x = x ^ (x >> 15);
    x = x * cast<uint>(0x2C1B3C6D);
    x = x ^ (x >> 12);
    x = x * cast<uint>(0x297A2D39);
    x = x ^ (x >> 15);
    return x;
}

@[unchecked]
frame clamp255(v: int) ret int {
    if (v < 0) {
        return 0;
    }
    if (v > 255) {
        return 255;
    }
    return v;
}

@[unchecked]
frame clampp(p: int) ret int {
    if (p < 1) {
        return 1;
    }
    if (p > 4095) {
        return 4095;
    }
    return p;
}

@[unchecked]
frame iabs(v: int) ret int {
    return (v < 0) ? -v : v;
}

# bit length of v in 0..1020 (branches only: a loop would add a stack guard)
@[unchecked]
frame bitlen10(v: int) ret int {
    if (v >= 512) {
        return 10;
    }
    if (v >= 256) {
        return 9;
    }
    if (v >= 128) {
        return 8;
    }
    if (v >= 64) {
        return 7;
    }
    if (v >= 32) {
        return 6;
    }
    if (v >= 16) {
        return 5;
    }
    if (v >= 8) {
        return 4;
    }
    if (v >= 4) {
        return 3;
    }
    if (v >= 2) {
        return 2;
    }
    if (v >= 1) {
        return 1;
    }
    return 0;
}

# bit length of v in 0..2^20-1
@[unchecked]
frame bitlen(v: int) ret int {
    if (v >= 1024) {
        return 10 + bitlen10(v >> 10);
    }
    return bitlen10(v);
}

# audio: signed log2 bucket of a difference (QA in c/fm4.c)
@[unchecked]
frame qa(d: int) ret uint {
    if (d < 0) {
        return cast<uint>(20 - bitlen(-d));
    }
    return cast<uint>(20 + bitlen(d));
}

# (int16_t)v
@[unchecked]
frame s16(v: int) ret int {
    local s: int = v & 65535;
    if (s > 32767) {
        s = s - 65536;
    }
    return s;
}

# 16-bit little-endian sample j
@[unchecked]
frame smp(d: *u8, j: long) ret int {
    return s16(cast<int>(d[2 * j]) | (cast<int>(d[2 * j + 1]) << 8));
}

@[unchecked]
frame clamp16(v: double) ret int {
    if (v < -32768.0) {
        return -32768;
    }
    if (v > 32767.0) {
        return 32767;
    }
    return cast<int>(v);
}

@[unchecked]
frame qe(e: int, lim: int) ret uint {
    local v: int = e;
    if (v < -lim) {
        v = -lim;
    }
    if (v > lim) {
        v = lim;
    }
    return cast<uint>(v + 64);
}

@[unchecked]
frame qg(d: int) ret uint {
    local a: int = iabs(d);
    local q: int = 4;
    if (a == 0) {
        q = 0;
    } else if (a < 3) {
        q = 1;
    } else if (a < 7) {
        q = 2;
    } else if (a < 21) {
        q = 3;
    }
    if (d < 0) {
        q = -q;
    }
    return cast<uint>(q + 8);
}

@[unchecked]
frame clampW(v: int) ret int {
    if (v > 524287) {
        return 524287;
    }
    if (v < -524288) {
        return -524288;
    }
    return v;
}

@[unchecked]
frame clamp2047(v: int) ret int {
    if (v > 2047) {
        return 2047;
    }
    if (v < -2047) {
        return -2047;
    }
    return v;
}

# signed 8-bit residual of (a - b), as (int8_t)(uint8_t)(a - b) in C
@[unchecked]
frame sdiff8(a: int, b: int) ret int {
    local s: int = (a - b) & 255;
    if (s > 127) {
        s = s - 256;
    }
    return s;
}

@[unchecked]
frame lenBucket(m: long) ret int {
    if (m < 16) {
        return cast<int>(m);
    }
    local q: long = (m - 16) >> 4;
    if (q > 15) {
        q = 15;
    }
    return 16 + cast<int>(q);
}

# a byte past the capacity means the result cannot beat store (as in C, which keeps every byte)
@[unchecked]
frame emitByte(b: u8) {
    if (G_LEN < G_CAP) {
        G_BUF[G_LEN] = b;
    } else {
        G_OVF = true;
    }
    G_LEN = G_LEN + 1;
}

@[unchecked]
frame nextByte() ret uint {
    local b: uint = 0;
    if (G_POS < G_LEN) {
        b = cast<uint>(G_BUF[G_POS]);
    }
    G_POS = G_POS + 1;
    return b;
}

@[unchecked]
frame pix24(d: *u8, i: long) ret uint {
    return cast<uint>(d[i]) | (cast<uint>(d[i + 1]) << 8) | (cast<uint>(d[i + 2]) << 16);
}

# ---- online least squares (one state block per channel: m[40][40], b[40], w[40], x[40] = 1720 doubles) ----
@[unchecked]
frame olsPred(o: *double, n: int) ret double {
    local s: double = 0.0;
    loop (local k: int = 0; k < n; k = k + 1) {
        s = s + o[1640 + k] * o[1680 + k];
    }
    return s;
}

# Lm: scratch [40][40] + z[40]. lam: forgetting factor. cnt: samples since the last solve.
# row[k] = a * row[k] + c * x[k] for k < n: rows and x never overlap, which lets the loop vectorize without
# runtime overlap checks.
@[unchecked]
frame olsDecay(@[noalias] row: *double, @[noalias] x: *double, n: long, a: double, c: double) {
    loop (local k: long = 0; k < n; k = k + 1) {
        row[k] = a * row[k] + c * x[k];
    }
}

# Loop indexes here are long: int arithmetic wraps (R-TYPE-13), so LLVM cannot widen int indexes and the
# solve runs about 20% slower with them.
@[unchecked]
frame olsUpd(o: *double, Lm: *double, ni: int, cnt: *int, lam: double, y: double) {
    local n: long = cast<long>(ni);
    local oml: double = 1.0 - lam;
    local col: double[40];
    loop (local j: long = 0; j < n; j = j + 1) {
        local c: double = oml * o[1680 + j];
        olsDecay(&o[j * 40], &o[1680], j + 1, lam, c);
        o[1600 + j] = lam * o[1600 + j] + c * y;
    }
    cnt[0] = cnt[0] + 1;
    if (cnt[0] < 4) {
        return;
    }
    cnt[0] = 0;
    # Cholesky + forward substitution, column by column: every element gets its products subtracted in the
    # same order (t ascending) as the row-by-row form, so the result is bit-identical, and the inner loop
    # has no dependency chain. Lm: [40][40] factor, then z[40] at 1600.
    loop (local j: long = 0; j < n; j = j + 1) {
        loop (local k: long = 0; k <= j; k = k + 1) {
            Lm[j * 40 + k] = o[j * 40 + k] + ((j == k) ? 0.001 : 0.0);
        }
        Lm[1600 + j] = o[1600 + j];
    }
    loop (local t: long = 0; t < n; t = t + 1) {
        if (Lm[t * 40 + t] <= 0.0) {
            return;
        }
        local d: double = sqrt(Lm[t * 40 + t]);
        local zt: double = Lm[1600 + t] / d;
        Lm[t * 40 + t] = d;
        Lm[1600 + t] = zt;
        loop (local j: long = t + 1; j < n; j = j + 1) {
            col[j] = Lm[j * 40 + t] / d;
            Lm[j * 40 + t] = col[j];
        }
        loop (local j: long = t + 1; j < n; j = j + 1) {
            local cj: double = col[j];
            loop (local k: long = t + 1; k <= j; k = k + 1) {
                Lm[j * 40 + k] = Lm[j * 40 + k] - cj * col[k];
            }
            Lm[1600 + j] = Lm[1600 + j] - cj * zt;
        }
    }
    loop (local j: long = n - 1; j >= 0; j = j - 1) {
        local v: double = Lm[1600 + j];
        loop (local t: long = j + 1; t < n; t = t + 1) {
            v = v - Lm[t * 40 + j] * o[1640 + t];
        }
        o[1640 + j] = v / Lm[j * 40 + j];
    }
}

# ---- mixer kernels ----
# sum of w[k] * st[k] and the weight update, over n inputs (32-bit wrapping sum: order is free).
# Fixed blocks of 16 and 8 over n rounded up to 8 compile to straight vector code with no scalar
# remainder loop (native and wasm simd128): the inputs past n are 0, so they add nothing and leave
# their weights unchanged (each weight set has room for 96).
@[unchecked]
frame dot16(w: *i16, st: *i16, n: int) ret int {
    local s: int = 0;
    local n8: int = (n + 7) & -8;
    local k: int = 0;
    loop (k + 16 <= n8) {
        loop (local j: int = 0; j < 16; j = j + 1) {
            s = s + cast<int>(w[k + j]) * cast<int>(st[k + j]);
        }
        k = k + 16;
    }
    if (k < n8) {
        loop (local j: int = 0; j < 8; j = j + 1) {
            s = s + cast<int>(w[k + j]) * cast<int>(st[k + j]);
        }
    }
    return s;
}

@[unchecked]
frame updW(w: int, s: int, el: int) ret int {
    local v: int = w + ((s * el + 131072) >> 18);
    if (v > 32767) {
        return 32767;
    }
    if (v < -32768) {
        return -32768;
    }
    return v;
}

# noalias: w is a weight set in the arena, st the input array on runChunk's stack; they never
# overlap. Without it the compiler must assume they do and the blocks fall back to scalar code.
@[unchecked]
frame upd16(@[noalias] w: *i16, @[noalias] st: *i16, n: int, el: int) {
    local n8: int = (n + 7) & -8;
    local k: int = 0;
    loop (k + 16 <= n8) {
        loop (local j: int = 0; j < 16; j = j + 1) {
            w[k + j] = cast<i16>(updW(cast<int>(w[k + j]), cast<int>(st[k + j]), el));
        }
        k = k + 16;
    }
    if (k < n8) {
        loop (local j: int = 0; j < 8; j = j + 1) {
            w[k + j] = cast<i16>(updW(cast<int>(w[k + j]), cast<int>(st[k + j]), el));
        }
    }
}

# ---- arena ----
# The arena starts on a 64-byte boundary so that a 16-slot hash bucket is exactly one cache line.
frame arenaAdopt(raw: *u8, n: long) {
    AR_RAW = raw;
    AR_BASE = cast<*u8>((cast<long>(raw) + 63) & -64);
    AR_CAP = n - 64;
}

frame arenaReset(total: long) {
    if (total > AR_CAP) {
        if (AR_RAW != nullptr) {
            free(cast<*void>(AR_RAW));
        }
        arenaAdopt(cast<*u8>(xalloc(total + 64)), total + 64);
    }
    AR_USED = 0;
}

@[unchecked]
frame arenaTake(n: long) ret *u8 {
    local p: *u8 = ptrAdd(AR_BASE, AR_USED);
    AR_USED = AR_USED + ((n + 63) / 64) * 64;
    return p;
}

# empty hash tables: slot 0 of each 16-slot bucket is the check word (up to 640 MB to write, so this
# must vectorize: unchecked)
@[unchecked]
frame fillTables(T: *uint, n: long) {
    loop (local j: long = 0; j < 16; j = j + 1) {
        T[j] = (j != 0) ? cast<uint>(16809984) : cast<uint>(0);
    }
    fillRep(cast<*u8>(T), 64, n * 4);
}

# p[0, unit) is set: repeat it over p[0, total) by doubling copies. In WebAssembly these become
# memory.copy (bulk memory), much faster than an element loop that runs once in baseline code.
@[unchecked]
frame fillRep(p: *u8, unit: long, total: long) {
    local have: long = unit;
    loop (have < total) {
        local n: long = (have < total - have) ? have : total - have;
        memcpy(cast<*void>(ptrAdd(p, have)), cast<*void>(p), n);
        have = have + n;
    }
}

@[unchecked]
frame hasF(feat: uint, bit: uint) ret bool {
    return (feat & bit) != cast<uint>(0);
}

# number of order contexts, context count, and table bits for context k (mirrors c/fm4.c run())
frame nOrd(img: bool, feat: uint) ret int {
    if (hasF(feat, cast<uint>(2097152))) {
        return 3;
    }
    if (!img && hasF(feat, cast<uint>(16))) {
        return 8;
    }
    return 6;
}

frame nCtx(img: bool, feat: uint, feat2: uint) ret int {
    local lite: bool = hasF(feat, cast<uint>(2097152));
    if (img) {
        if (lite) {
            return 6;
        }
        local m: int = hasF(feat, cast<uint>(512)) ? 16 : 12;
        if (hasF(feat2, cast<uint>(16))) {
            m = m + 2;
        }
        if (hasF(feat2, cast<uint>(64))) {
            m = m + 2;
        }
        if (hasF(feat2, cast<uint>(128))) {
            m = m + 1;
        }
        if (hasF(feat2, cast<uint>(256))) {
            m = m + 3;
        }
        return m;
    }
    local n: int = nOrd(img, feat);
    if (hasF(feat, cast<uint>(2))) {
        n = n + 2;
    }
    if (hasF(feat, cast<uint>(128))) {
        n = n + 3;
    }
    if (hasF(feat, cast<uint>(32768))) {
        n = n + 2;
    }
    if (hasF(feat, cast<uint>(262144))) {
        n = n + 2;
    }
    if (hasF(feat2, cast<uint>(4))) {
        n = n + 4;
    }
    return n;
}

frame minBits(a: int, bb: int) ret int {
    return (a < bb) ? a : bb;
}

frame tableBits(img: bool, feat: uint, bb: int, k: int) ret int {
    if (img) {
        local tbi: int[16] = [8, 12, 12, 12, 16, 16, 0, 17, 0, 0, 0, 0, 17, 16, 16, 0];
        local fimgx: bool = !hasF(feat, cast<uint>(2097152)) && hasF(feat, cast<uint>(512));
        if (k < 16 && tbi[k] != 0 && (k < 12 || fimgx)) {
            return minBits(tbi[k], bb);
        }
        return bb;
    }
    if (hasF(feat, cast<uint>(2097152))) {
        if (k == 0) {
            return minBits(13, bb);
        }
    } else {
        if (k == 0) {
            return minBits(6, bb);
        }
        if (k == 1) {
            return minBits(13, bb);
        }
    }
    if (hasF(feat, cast<uint>(128))) {
        local bs: int = nOrd(img, feat);
        if (hasF(feat, cast<uint>(2))) {
            bs = bs + 2;
        }
        if (k == bs) {
            return minBits(13, bb);
        }
        if (k == bs + 2) {
            return minBits(15, bb);
        }
    }
    return bb;
}

# bytes run() takes from the arena (every block is rounded up to 64; 4096 covers the rounding)
# nchan: audio channel count (mode 3)
# entries of the per-pixel error rings: errors are read back at most 2 rows + 2 pixels (6 * 65535 + 6 bytes),
# so 2^19 entries, or the next power of two >= L + 1 for smaller inputs (same as c/fm4.c; no effect on output)
@[unchecked]
frame ringSize(L: long) ret long {
    local r: long = 64;
    loop (r - 1 < L && r < 524288) {
        r = r * 2;
    }
    return r;
}

frame arenaSize(mode: int, bb: int, feat: uint, feat2: uint, L: long, nchan: long) ret long {
    local img: bool = mode == 2;
    local aud: bool = mode == 3;
    local nctx: int = aud ? 10 : nCtx(img, feat, feat2);
    local total: long = 4096;
    loop (local k: int = 0; k < nctx; k = k + 1) {
        total = total + (cast<long>(64) << cast<long>(aud ? minBits(16, bb) : tableBits(img, feat, bb, k)));
    }
    if (aud) {
        # OLS blocks + scratch, aerr, actx, OLS counters
        total = total + 2 * nchan * 1720 * 8 + 1640 * 8 + (L / 2 + 1) * 2 + 64 + 2 * nchan * 4;
    }
    # SM, W1, W2, W3, W4, WF, RP, RN, saved match predictors (3 * 64 u16 + 3 * 64 u8)
    total = total + 64 * 6 + 64 * 3 + 96 * 256 * 4 + 2048 * 96 * 2 + 768 * 96 * 2 + 2048 * 96 * 2 + 4096 * 96 * 2 + 256 * 4 * 4 + 96 * 64 * 2 + 96 * 64;
    local napm1: long = img ? 12288 : 65536;
    total = total + napm1 * 33 * 2;
    local fmatch: bool = !img && hasF(feat, cast<uint>(1));
    local fmix2: bool = hasF(feat, cast<uint>(32));
    if (!img && hasF(feat, cast<uint>(8))) {
        total = total + 262144 * 33 * 2;
    }
    if (fmatch && fmix2 && hasF(feat, cast<uint>(65536))) {
        total = total + 65536 * 33 * 2;
    }
    if (fmatch) {
        total = total + 4194304 * 4;
        if (hasF(feat, cast<uint>(131072))) {
            total = total + 4194304 * 4;
        }
    }
    if (!img && hasF(feat, cast<uint>(32768))) {
        total = total + 256 * 2 + 4194304 * 2;
    }
    if (img) {
        local rn: long = ringSize(L);
        total = total + rn * 2;
        if (!hasF(feat, cast<uint>(2097152))) {
            total = total + rn * 12;
        }
        if (hasF(feat2, cast<uint>(128))) {
            total = total + 4194304 * 4;
        }
        if (hasF(feat2, cast<uint>(16))) {
            total = total + (3 * 1720 + 1640) * 8;
        }
    }
    return total;
}

# ---- model ----
# Codes bytes [i0, i1) of data. The first call (i0 == 0) builds the model in the arena; later calls
# find the same blocks again (the arena is taken in the same order) and reload the few scalars and
# small arrays that are kept in locals while the loop runs. The work is split into calls because
# WebAssembly engines only switch a function to optimized code when it is entered again: one call
# for the whole input would run in baseline code to the end.
@[noinline, unchecked]
frame runChunk(mode: int, bb: int, limit: int, feat: uint, feat2: uint, widthF: long, data: *u8, L: long, i0: long, i1: long) {
    local first: bool = i0 == 0;
    local img: bool = mode == 2;
    local aud: bool = mode == 3;
    local nchan: long = aud ? widthF : 0;
    # video = image mode with feat2 bit 256: width field = width | frame height << 16
    local fvid: bool = img && hasF(feat2, cast<uint>(256));
    local width: long = fvid ? (widthF & 65535) : widthF;
    local fh: long = fvid ? (widthF >> 16) : 0;
    local XORD: bool = !img && hasF(feat2, cast<uint>(1));
    local XM4: bool = hasF(feat, cast<uint>(256)) && hasF(feat2, cast<uint>(2));
    local XTXT: bool = !img && hasF(feat2, cast<uint>(4));
    local XRUN: bool = !img && hasF(feat2, cast<uint>(8));
    local XOLS: bool = img && hasF(feat2, cast<uint>(16));
    local XWIDE: bool = XOLS && hasF(feat2, cast<uint>(32));
    local XCOL: bool = img && hasF(feat2, cast<uint>(64));
    local XIM: bool = img && hasF(feat2, cast<uint>(128));
    local flite: bool = hasF(feat, cast<uint>(2097152));
    local fmatch: bool = !img && hasF(feat, cast<uint>(1));
    local fword: bool = !img && hasF(feat, cast<uint>(2));
    local fmsel: bool = !img && hasF(feat, cast<uint>(4));
    local fapm2: bool = !img && hasF(feat, cast<uint>(8));
    local fhi: bool = !img && !flite && hasF(feat, cast<uint>(16));
    local fmix2: bool = hasF(feat, cast<uint>(32));
    local fsparse: bool = !img && hasF(feat, cast<uint>(128));
    local fmix3: bool = fmix2 && hasF(feat, cast<uint>(256));
    local fimgx: bool = img && !flite && hasF(feat, cast<uint>(512));
    local fhist: bool = !img && hasF(feat, cast<uint>(2048));
    local find: bool = !img && hasF(feat, cast<uint>(32768));
    local fmapm: bool = fmatch && fmix2 && hasF(feat, cast<uint>(65536));
    local fm2nd: bool = fmatch && hasF(feat, cast<uint>(131072));
    local fcol: bool = !img && hasF(feat, cast<uint>(262144));
    local fblend1: bool = img && hasF(feat, cast<uint>(1048576));

    local nord: int = 6;
    if (flite) {
        nord = 3;
    } else if (fhi) {
        nord = 8;
    }
    local bword: int = nord;
    local bsparse: int = bword + (fword ? 2 : 0);
    local bind: int = bsparse + (fsparse ? 3 : 0);
    local bcol: int = bind + (find ? 2 : 0);
    local btxt: int = bcol + (fcol ? 2 : 0);
    local nctx: int = aud ? 10 : nCtx(img, feat, feat2);
    local nimm: int = XIM ? 1 : 0;
    local nrun: int = XRUN ? nctx : 0;
    local nin: int = nctx * (fhist ? 2 : 1) + nrun + nimm + (fmatch ? 1 : 0) + (fm2nd ? 1 : 0) + 1;
    local np: int = 0;
    if (img && !flite) {
        np = 9 + (XOLS ? 1 : 0) + (fvid ? 2 : 0);
    }
    local npl: long = cast<long>(np);
    local nm: int = XM4 ? 4 : 3;
    # first image context after the fixed 12 (+4): OLS pair, colour pair, previous-frame triple, 2-D match
    local jols: int = 12 + (fimgx ? 4 : 0);
    local jcol: int = jols + (XOLS ? 2 : 0);
    local jvid: int = jcol + (XCOL ? 2 : 0);
    local jim: int = jvid + (fvid ? 3 : 0);

    if (first) {
        arenaReset(arenaSize(mode, bb, feat, feat2, L, nchan));
    } else {
        AR_USED = 0;
    }
    local tb: int[96];
    local tOff: long[96];
    local tTotal: long = 0;
    loop (local k: int = 0; k < nctx; k = k + 1) {
        tb[k] = aud ? minBits(16, bb) : tableBits(img, feat, bb, k);
        tOff[k] = tTotal;
        tTotal = tTotal + (cast<long>(16) << cast<long>(tb[k]));
    }
    local T: *uint = cast<*uint>(arenaTake(tTotal * 4));
    local Tb: *u8 = cast<*u8>(T);
    local SM: *uint = cast<*uint>(arenaTake(96 * 256 * 4));
    local W1: *i16 = cast<*i16>(arenaTake(2048 * 96 * 2));
    local W2: *i16 = cast<*i16>(arenaTake(768 * 96 * 2));
    local W3: *i16 = cast<*i16>(arenaTake(2048 * 96 * 2));
    local W4: *i16 = cast<*i16>(arenaTake(4096 * 96 * 2));
    local WF: *int = cast<*int>(arenaTake(256 * 4 * 4));
    local napm1: int = img ? 12288 : 65536;
    local A1: *u16 = cast<*u16>(arenaTake(cast<long>(napm1) * 33 * 2));
    local A2: *u16 = cast<*u16>(nullptr);
    if (fapm2) {
        A2 = cast<*u16>(arenaTake(cast<long>(262144) * 33 * 2));
    }
    local A3: *u16 = cast<*u16>(nullptr);
    if (fmapm) {
        A3 = cast<*u16>(arenaTake(cast<long>(65536) * 33 * 2));
    }
    local MT: *uint = cast<*uint>(nullptr);
    local MT2: *uint = cast<*uint>(nullptr);
    if (fmatch) {
        MT = cast<*uint>(arenaTake(4194304 * 4));
        if (fm2nd) {
            MT2 = cast<*uint>(arenaTake(4194304 * 4));
        }
    }
    local IND1: *u16 = cast<*u16>(nullptr);
    local IND2: *u16 = cast<*u16>(nullptr);
    if (find) {
        IND1 = cast<*u16>(arenaTake(256 * 2));
        IND2 = cast<*u16>(arenaTake(4194304 * 2));
    }
    local err: *i16 = cast<*i16>(nullptr);
    local perr: *u8 = cast<*u8>(nullptr);
    if (img) {
        err = cast<*i16>(arenaTake(ringSize(L) * 2));
        if (np > 0) {
            perr = arenaTake(ringSize(L) * npl);
        }
    }
    local IMT: *uint = cast<*uint>(nullptr);
    if (XIM) {
        IMT = cast<*uint>(arenaTake(4194304 * 4));
    }
    local RP: *u16 = cast<*u16>(arenaTake(96 * 64 * 2));
    local RN: *u8 = arenaTake(96 * 64);
    # OLS: 3 channel blocks of 1720 doubles, then the Cholesky scratch (1600 + 40)
    local OL: *double = cast<*double>(nullptr);
    local OLm: *double = cast<*double>(nullptr);
    local oln: int[3] = [10, 14, 15];
    local olc: int[3] = [S_OLC0, S_OLC1, S_OLC2];
    if (XOLS) {
        OL = cast<*double>(arenaTake((3 * 1720 + 1640) * 8));
        OLm = cast<*double>(ptrAdd(cast<*u8>(OL), 3 * 1720 * 8));
        if (XWIDE) {
            oln[0] = 20;
            oln[1] = 24;
            oln[2] = 25;
        }
        if (fvid) {
            oln[0] = oln[0] + 4;
            oln[1] = oln[1] + 4;
            oln[2] = oln[2] + 4;
        }
    }
    # audio: per channel a long OLS (16 or 32 own samples + 4 of the neighbour channel) then a short
    # one (blocks 0..nchan-1 and nchan..2*nchan-1), the scratch, the residuals, the contexts of the
    # current sample and the per-block solve counters
    local an1: int = hasF(feat2, cast<uint>(32)) ? 32 : 16;
    local an: int = an1 + ((nchan > 1) ? 4 : 0);
    local AO: *double = cast<*double>(nullptr);
    local AOm: *double = cast<*double>(nullptr);
    local aerr: *i16 = cast<*i16>(nullptr);
    local actx: *uint = cast<*uint>(nullptr);
    local acnt: *int = cast<*int>(nullptr);
    if (aud) {
        AO = cast<*double>(arenaTake(2 * nchan * 1720 * 8));
        AOm = cast<*double>(arenaTake(1640 * 8));
        aerr = cast<*i16>(arenaTake((L / 2 + 1) * 2));
        actx = cast<*uint>(arenaTake(64));
        acnt = cast<*int>(arenaTake(2 * nchan * 4));
        if (first) {
            memset(cast<*void>(AO), 0, 2 * nchan * 1720 * 8);
            memset(cast<*void>(AOm), 0, 1640 * 8);
            memset(cast<*void>(aerr), 0, (L / 2 + 1) * 2);
            memset(cast<*void>(actx), 0, 64);
            memset(cast<*void>(acnt), 0, 2 * nchan * 4);
        }
    }
    # match predictors between calls: MP, MP2, IMP then MN, MN2, IMN
    local SVP: *u16 = cast<*u16>(arenaTake(64 * 6));
    local SVN: *u8 = arenaTake(64 * 3);
    if (first) {
        fillTables(T, tTotal);
        SM[0] = cast<uint>(32768);
        fillRep(cast<*u8>(SM), 4, 96 * 256 * 4);
        local winit: i16 = cast<i16>((19661 * 6 / nin) >> 4);
        W1[0] = winit;
        fillRep(cast<*u8>(W1), 2, 2048 * 96 * 2);
        W2[0] = winit;
        fillRep(cast<*u8>(W2), 2, 768 * 96 * 2);
        W3[0] = winit;
        fillRep(cast<*u8>(W3), 2, 2048 * 96 * 2);
        W4[0] = winit;
        fillRep(cast<*u8>(W4), 2, 4096 * 96 * 2);
        loop (local j: int = 0; j < 1024; j = j + 1) {
            WF[j] = XM4 ? 16384 : 21845;
        }
        local apmInit: u16[33];
        loop (local j: int = 0; j < 33; j = j + 1) {
            apmInit[j] = cast<u16>(squash((j - 16) * 128) * 16);
        }
        memcpy(cast<*void>(A1), cast<*void>(&apmInit[0]), 66);
        fillRep(cast<*u8>(A1), 66, cast<long>(napm1) * 66);
        if (fapm2) {
            memcpy(cast<*void>(A2), cast<*void>(&apmInit[0]), 66);
            fillRep(cast<*u8>(A2), 66, 262144 * 66);
        }
        if (fmapm) {
            memcpy(cast<*void>(A3), cast<*void>(&apmInit[0]), 66);
            fillRep(cast<*u8>(A3), 66, 65536 * 66);
        }
        if (fmatch) {
            memset(cast<*void>(MT), 0, 4194304 * 4);
            if (fm2nd) {
                memset(cast<*void>(MT2), 0, 4194304 * 4);
            }
        }
        if (find) {
            memset(cast<*void>(IND1), 0, 256 * 2);
            memset(cast<*void>(IND2), 0, 4194304 * 2);
        }
        if (img) {
            memset(cast<*void>(err), 0, ringSize(L) * 2);
            if (np > 0) {
                memset(cast<*void>(perr), 0, ringSize(L) * npl);
            }
        }
        if (XIM) {
            memset(cast<*void>(IMT), 0, 4194304 * 4);
        }
        loop (local j: int = 0; j < 96 * 64; j = j + 1) {
            RP[j] = cast<u16>(49152);
            RN[j] = cast<u8>(0);
        }
        if (XOLS) {
            memset(cast<*void>(OL), 0, (3 * 1720 + 1640) * 8);
        }
        olc[0] = 0;
        olc[1] = 0;
        olc[2] = 0;
        loop (local j: int = 0; j < 64 * 3; j = j + 1) {
            SVP[j] = cast<u16>(49152);
            SVN[j] = cast<u8>(0);
        }
    }
    local oin: bool = false;

    local MP: u16[64];
    local MP2: u16[64];
    local IMP: u16[64];
    local MN: u8[64];
    local MN2: u8[64];
    local IMN: u8[64];
    loop (local j: int = 0; j < 64; j = j + 1) {
        MP[j] = SVP[j];
        MP2[j] = SVP[64 + j];
        IMP[j] = SVP[128 + j];
        MN[j] = SVN[j];
        MN2[j] = SVN[64 + j];
        IMN[j] = SVN[128 + j];
    }
    local ctx: uint[96];
    local bko: long[96];
    local rko: long[96];
    local st: i16[196];
    local smi: int[96];
    local ev: uint[96];
    local hk: uint[96];
    local sv: uint[96];
    local rb: int[96];
    local rq: int[96];
    local reb: int[96];
    local rmiss: bool[96];
    loop (local j: int = 0; j < 96; j = j + 1) {
        ctx[j] = cast<uint>(0);
        bko[j] = 0;
        rko[j] = 0;
        smi[j] = 0;
        ev[j] = cast<uint>(0);
        hk[j] = cast<uint>(0);
        sv[j] = cast<uint>(0);
        rb[j] = 0;
        rq[j] = 0;
        reb[j] = -1;
        rmiss[j] = true;
    }
    loop (local j: int = 0; j < 196; j = j + 1) {
        st[j] = cast<i16>(0);
    }
    # entries past nin stay 0 (dot16 relies on it)
    local stp: *i16 = &st[0];
    local pr: int[12] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    local dd: int[4] = [0, 0, 0, 0];
    local stride: long = 3 * width;
    local rmask: long = ringSize(L) - 1;
    local mptr: long = 0;
    local mlen: long = 0;
    local mptr2: long = 0;
    local mlen2: long = 0;
    local linestart: long = 0;
    local prevline: long = 0;
    local indent: long = 0;
    local inind: bool = true;
    local imptr: long = 0;
    local imlen: long = 0;
    local imok: bool = false;
    local c4: uint = 0;
    local c8: uint = 0;
    local w0: uint = 0;
    local w1h: uint = 0;
    local w2h: uint = 0;
    local apred: int = 0;
    local azig: int = 0;
    local ahi: int = 0;
    local aq: int = 0;
    local ach: int = 0;
    if (!first) {
        apred = S_APRED;
        azig = S_AZIG;
        ahi = S_AHI;
        aq = S_AQ;
        ach = S_ACH;
        mptr = S_MPTR;
        mlen = S_MLEN;
        mptr2 = S_MPTR2;
        mlen2 = S_MLEN2;
        linestart = S_LINESTART;
        prevline = S_PREVLINE;
        indent = S_INDENT;
        inind = S_ININD;
        imptr = S_IMPTR;
        imlen = S_IMLEN;
        imok = S_IMOK;
        c4 = S_C4;
        c8 = S_C8;
        w0 = S_W0;
        w1h = S_W1H;
        w2h = S_W2H;
    }
    # set again for every byte that uses them
    local imev: int = -1;
    local hord: int = 0;
    local isym: int = -1;
    local iq: int = 0;
    local z: uint = 0;
    local lr: int = LR;
    # table pointers in locals: a global would be reloaded (and null-checked) after every store
    local recip: *int = RECIP;
    local stretch: *int = STRETCH;
    # coder state in locals (inlined coder)
    local x1: uint = G_X1;
    local x2: uint = G_X2;
    local xx: uint = G_X;
    local dec: bool = G_DEC;
    local gbuf: *u8 = G_BUF;
    local glen: long = G_LEN;
    local gpos: long = G_POS;
    local gcap: long = G_CAP;
    local ovf: bool = G_OVF;

    loop (local i: long = i0; i < i1; i = i + 1) {
        local ch: int = 0;
        local act: int = 0;
        local eP: int = 0;
        local pred: int = 0;
        local sym: int = 0;
        local mb: int = -1;
        local lenq: int = 0;
        local msel: int = 0;
        local mb2: int = -1;
        local lenq2: int = 0;
        if (aud) {
            local bpos: int = cast<int>(i & 1);
            local si: long = i >> 1;
            local t: long = si / nchan;
            if (bpos == 0) {
                ach = cast<int>(si % nchan);
                local as1: int = (t > 0) ? smp(data, si - nchan) : 0;
                local as2: int = (t > 1) ? smp(data, si - 2 * nchan) : as1;
                local ap1: int = as1;
                local ap2: int = as1;
                local ap3: int = 2 * as1 - as2;
                if (t >= cast<long>(an1)) {
                    local AX: *double = cast<*double>(ptrAdd(cast<*u8>(AO), (cast<long>(ach) * 1720 + 1680) * 8));
                    local AY: *double = cast<*double>(ptrAdd(cast<*u8>(AO), ((nchan + cast<long>(ach)) * 1720 + 1680) * 8));
                    loop (local k: int = 0; k < an1; k = k + 1) {
                        AX[k] = cast<double>(smp(data, si - cast<long>(k + 1) * nchan));
                    }
                    if (nchan > 1) {
                        # neighbour channel: its sample at this time if already coded, then older ones
                        local ob: long = t * nchan + cast<long>(ach) - 1;
                        loop (local k: int = 0; k < 4; k = k + 1) {
                            AX[an1 + k] = cast<double>(smp(data, ob - cast<long>(k) * nchan));
                        }
                    }
                    loop (local k: int = 0; k < 8; k = k + 1) {
                        AY[k] = AX[k];
                    }
                    ap1 = clamp16(floor(olsPred(cast<*double>(ptrAdd(cast<*u8>(AO), cast<long>(ach) * 1720 * 8)), an) + 0.5));
                    ap2 = clamp16(floor(olsPred(cast<*double>(ptrAdd(cast<*u8>(AO), (nchan + cast<long>(ach)) * 1720 * 8)), 8) + 0.5));
                }
                if (ap3 < -32768) {
                    ap3 = -32768;
                } else if (ap3 > 32767) {
                    ap3 = 32767;
                }
                apred = ap1;
                local ar1: int = (t > 0) ? cast<int>(aerr[si - nchan]) : 0;
                local ar2: int = (t > 1) ? cast<int>(aerr[si - 2 * nchan]) : 0;
                local ar3: int = (t > 2) ? cast<int>(aerr[si - 3 * nchan]) : 0;
                local aro: int = (ach > 0 || t > 0) ? cast<int>(aerr[si - 1]) : 0;
                local ae8: int = 0;
                loop (local k: int = 1; k <= 8; k = k + 1) {
                    if (t >= cast<long>(k)) {
                        ae8 = ae8 + iabs(cast<int>(aerr[si - cast<long>(k) * nchan]));
                    }
                }
                act = bitlen(iabs(ar1) + iabs(ar2) + iabs(ar3));
                if (act > 15) {
                    act = 15;
                }
                local actu: uint = cast<uint>(act) << 8;
                actx[0] = cast<uint>(0);
                actx[1] = cast<uint>(act);
                actx[2] = cast<uint>(bitlen(iabs(ar1)) | (bitlen(iabs(ar2)) << 5));
                actx[3] = qa(ap2 - ap1);
                actx[4] = qa(ap3 - ap1) | actu;
                actx[5] = qa(aro) | actu;
                actx[6] = qa(ar1) | (qa(ar2) << 8);
                actx[7] = cast<uint>(bitlen(ae8));
                actx[8] = cast<uint>(bitlen(iabs(apred))) | actu;
                actx[9] = qa(ap1 - as1) | (qa(ap2 - ap1) << 8);
                aq = cast<int>(qa(ap2 - ap1));
                if (!dec) {
                    local ares: int = s16(smp(data, si) - apred);
                    azig = (ares >= 0) ? 2 * ares : -2 * ares - 1;
                }
            }
            loop (local k: int = 0; k < nctx; k = k + 1) {
                ctx[k] = hash4(cast<uint>(80 + k), cast<uint>(ach | (bpos << 3)), (bpos != 0) ? cast<uint>(ahi) : z, actx[k]);
            }
            ch = bpos;
            if (!dec) {
                sym = (bpos != 0) ? (azig & 255) : (azig >> 8);
            }
        } else if (!img) {
            loop (local k: int = 0; k < nord; k = k + 1) {
                local o: int = k;
                if (flite) {
                    o = k + 1;
                } else if (k == 5) {
                    o = 6;
                } else if (k == 6) {
                    o = 5;
                }
                local m: uint = cast<uint>(0xFFFFFFFF);
                if (o < 4) {
                    m = (cast<uint>(1) << cast<uint>(8 * o)) - cast<uint>(1);
                }
                local hi: uint = 0;
                if (o == 6) {
                    hi = c8 & cast<uint>(0xFFFF);
                } else if (o == 5) {
                    hi = c8 & cast<uint>(0xFF);
                } else if (o == 7) {
                    hi = c8 & cast<uint>(0xFFFFFF);
                }
                ctx[k] = hash4(cast<uint>(o), c4 & m, hi, z);
            }
            if (fword) {
                ctx[bword] = hash4(cast<uint>(30), w0, z, z);
                ctx[bword + 1] = hash4(cast<uint>(31), w0, w1h, z);
            }
            if (fsparse) {
                ctx[bsparse] = hash4(cast<uint>(40), (c4 >> 8) & cast<uint>(0xFF), z, z);
                ctx[bsparse + 1] = hash4(cast<uint>(41), (c4 >> 16) & cast<uint>(0xFFFF), z, z);
                ctx[bsparse + 2] = hash4(cast<uint>(42), cast<uint>(i & 3), c4 & cast<uint>(0xFF), z);
            }
            if (find) {
                ctx[bind] = hash4(cast<uint>(50), c4 & cast<uint>(0xFF), cast<uint>(IND1[cast<long>(c4 & cast<uint>(0xFF))]), z);
                local hi2: uint = hash4(cast<uint>(52), c4 & cast<uint>(0xFFFF), z, z) >> 10;
                ctx[bind + 1] = hash4(cast<uint>(51), c4 & cast<uint>(0xFFFF), cast<uint>(IND2[cast<long>(hi2)]), z);
            }
            if (fcol || XTXT) {
                local col: long = i - linestart;
                local ab: long = prevline + col;
                local above: uint = 0;
                if (ab < linestart) {
                    above = cast<uint>(data[ab]);
                }
                if (fcol) {
                    local colc: long = (col > 255) ? 255 : col;
                    ctx[bcol] = hash4(cast<uint>(60), above, cast<uint>(colc), c4 & cast<uint>(0xFF));
                    ctx[bcol + 1] = hash4(cast<uint>(61), w0, w1h, w2h);
                }
                if (XTXT) {
                    local above1: uint = 0;
                    if (ab + 1 < linestart) {
                        above1 = cast<uint>(data[ab + 1]);
                    }
                    ctx[btxt] = hash4(cast<uint>(70), w0, w2h, z);
                    ctx[btxt + 1] = hash4(cast<uint>(71), above, above1, c4 & cast<uint>(0xFFFF));
                    ctx[btxt + 2] = hash4(cast<uint>(72), cast<uint>(indent), w0, inind ? cast<uint>(1) : z);
                    ctx[btxt + 3] = hash4(cast<uint>(74), cast<uint>(indent), c4 & cast<uint>(0xFFFFFF), z);
                }
            }
            if (fmatch) {
                if (mlen > 0) {
                    if (data[mptr] == data[i - 1]) {
                        mlen = mlen + 1;
                        mptr = mptr + 1;
                    } else {
                        mlen = 0;
                    }
                }
                if (i >= 6) {
                    local h: long = cast<long>(hash4(cast<uint>(99), c4, c8 & cast<uint>(0xFFFF), z) >> 10);
                    if (mlen == 0 && MT[h] > cast<uint>(0)) {
                        local cand: long = cast<long>(MT[h]);
                        local len: long = 0;
                        loop (len < 400 && cand - 1 - len >= 0 && data[cand - 1 - len] == data[i - 1 - len]) {
                            len = len + 1;
                        }
                        if (len >= 6) {
                            mlen = len;
                            mptr = cand;
                        }
                    }
                    MT[h] = cast<uint>(i);
                }
                if (fm2nd) {
                    if (mlen2 > 0) {
                        if (data[mptr2] == data[i - 1]) {
                            mlen2 = mlen2 + 1;
                            mptr2 = mptr2 + 1;
                        } else {
                            mlen2 = 0;
                        }
                    }
                    if (i >= 12) {
                        local far: uint = cast<uint>(data[i - 9]) | (cast<uint>(data[i - 10]) << 8) | (cast<uint>(data[i - 11]) << 16) | (cast<uint>(data[i - 12]) << 24);
                        local hh: long = cast<long>(hash4(cast<uint>(98), c4, c8, far) >> 10);
                        if (mlen2 == 0 && MT2[hh] > cast<uint>(0) && cast<long>(MT2[hh]) != mptr) {
                            local cand2: long = cast<long>(MT2[hh]);
                            local len2: long = 0;
                            loop (len2 < 400 && cand2 - 1 - len2 >= 0 && data[cand2 - 1 - len2] == data[i - 1 - len2]) {
                                len2 = len2 + 1;
                            }
                            if (len2 >= 12) {
                                mlen2 = len2;
                                mptr2 = cand2;
                            }
                        }
                        MT2[hh] = cast<uint>(i);
                    }
                    if (mlen2 > 65535) {
                        mlen2 = 65535;
                    }
                    if (mlen2 > 0) {
                        mb2 = cast<int>(data[mptr2]);
                        lenq2 = lenBucket(mlen2);
                    }
                }
                if (mlen > 65535) {
                    mlen = 65535;
                }
                if (mlen > 0) {
                    mb = cast<int>(data[mptr]);
                    lenq = lenBucket(mlen);
                    msel = 3;
                    if (mlen < 16) {
                        msel = 1;
                    } else if (mlen < 32) {
                        msel = 2;
                    }
                }
            }
            if (!dec) {
                sym = cast<int>(data[i]);
            }
        } else {
            ch = cast<int>(i % 3);
            local px: long = i / 3;
            local x: long = px % width;
            local y: long = px / width;
            local hasW: bool = x > 0;
            local hasN: bool = y > 0;
            local hasNE: bool = y > 0 && x < width - 1;
            local hasWW: bool = x > 1;
            local hasNN: bool = y > 1;
            local iW: long = i - 3;
            local iN: long = i - stride;
            local iNW: long = iN - 3;
            local iNE: long = iN + 3;
            local Wv: int = 0;
            if (hasW) {
                Wv = cast<int>(data[iW]);
            } else if (hasN) {
                Wv = cast<int>(data[iN]);
            }
            local Nv: int = hasN ? cast<int>(data[iN]) : Wv;
            local NWv: int = (hasN && hasW) ? cast<int>(data[iNW]) : Nv;
            local NEv: int = hasNE ? cast<int>(data[iNE]) : Nv;
            local WWv: int = hasWW ? cast<int>(data[i - 6]) : Wv;
            local NNv: int = hasNN ? cast<int>(data[iN - stride]) : Nv;
            local mx: int = (Wv > Nv) ? Wv : Nv;
            local mn: int = (Wv < Nv) ? Wv : Nv;
            if (NWv >= mx) {
                pr[0] = mn;
            } else if (NWv <= mn) {
                pr[0] = mx;
            } else {
                pr[0] = Wv + Nv - NWv;
            }
            local fb: long = stride * fh;
            local hasP: bool = fvid && i >= fb;
            local Pv: int = hasP ? cast<int>(data[i - fb]) : 0;
            local PWv: int = (hasP && hasW) ? cast<int>(data[i - fb - 3]) : Pv;
            local PNv: int = (hasP && i - fb - stride >= 0) ? cast<int>(data[i - fb - stride]) : Pv;
            pred = pr[0];
            if (np > 0) {
                pr[1] = clamp255(Wv + Nv - NWv);
                pr[2] = (Wv + NEv + 1) >> 1;
                pr[3] = clamp255(Nv + ((Wv - NWv + NEv - Nv) >> 1));
                pr[4] = pr[0];
                if (ch > 0) {
                    local pw: int = 0;
                    if (hasW) {
                        pw = cast<int>(data[iW - 1]);
                    } else if (hasN) {
                        pw = cast<int>(data[iN - 1]);
                    }
                    local pn: int = hasN ? cast<int>(data[iN - 1]) : pw;
                    local pnw: int = (hasN && hasW) ? cast<int>(data[iNW - 1]) : pn;
                    local pmx: int = (pw > pn) ? pw : pn;
                    local pmn: int = (pw < pn) ? pw : pn;
                    local pmed: int = pw + pn - pnw;
                    if (pnw >= pmx) {
                        pmed = pmn;
                    } else if (pnw <= pmn) {
                        pmed = pmx;
                    }
                    pr[4] = clamp255(pr[0] + (cast<int>(data[i - 1]) - pmed));
                }
                pr[5] = Wv;
                pr[6] = Nv;
                pr[7] = clamp255(2 * Wv - WWv);
                pr[8] = clamp255(2 * Nv - NNv);
                if (XOLS) {
                    oin = x >= 3 && y >= 3 && x < width - 3;
                    pr[9] = pr[0];
                    if (oin) {
                        local X: *double = cast<*double>(ptrAdd(cast<*u8>(OL), cast<long>(ch * 1720 + 1680) * 8));
                        local s2: long = 2 * stride;
                        X[0] = cast<double>(cast<int>(data[iW]));
                        X[1] = cast<double>(cast<int>(data[iN]));
                        X[2] = cast<double>(cast<int>(data[iNW]));
                        X[3] = cast<double>(cast<int>(data[iNE]));
                        X[4] = cast<double>(cast<int>(data[i - 6]));
                        X[5] = cast<double>(cast<int>(data[i - s2]));
                        X[6] = cast<double>(cast<int>(data[i - s2 + 3]));
                        X[7] = cast<double>(cast<int>(data[iN - 6]));
                        X[8] = cast<double>(cast<int>(data[iN + 6]));
                        X[9] = cast<double>(cast<int>(data[i - s2 - 3]));
                        if (ch >= 1) {
                            X[10] = cast<double>(cast<int>(data[i - 1]));
                            X[11] = cast<double>(cast<int>(data[iW - 1]));
                            X[12] = cast<double>(cast<int>(data[iN - 1]));
                            X[13] = cast<double>(cast<int>(data[iNW - 1]));
                        }
                        if (ch == 2) {
                            X[14] = cast<double>(cast<int>(data[i - 2]));
                        }
                        if (fvid) {
                            local bv4: int = oln[ch] - 4;
                            X[bv4] = cast<double>(Pv);
                            X[bv4 + 1] = cast<double>(PWv);
                            X[bv4 + 2] = cast<double>(PNv);
                            X[bv4 + 3] = hasP ? cast<double>(cast<int>(data[i - fb + 3])) : 0.0;
                        }
                        if (XWIDE) {
                            local b: int = oln[ch] - 10 - (fvid ? 4 : 0);
                            X[b] = cast<double>(cast<int>(data[i - 9]));
                            X[b + 1] = cast<double>(cast<int>(data[(iN - 9 < 0) ? iN : iN - 9]));
                            X[b + 2] = cast<double>(cast<int>(data[(iN + 9 >= i) ? iN : iN + 9]));
                            X[b + 3] = cast<double>(cast<int>(data[i - s2 - 6]));
                            X[b + 4] = cast<double>(cast<int>(data[(i - s2 + 6 >= i) ? i - s2 : i - s2 + 6]));
                            X[b + 5] = cast<double>(cast<int>(data[(i - 3 * stride >= 0) ? i - 3 * stride : i - s2]));
                            X[b + 6] = (ch > 0) ? cast<double>(cast<int>(data[iNE - 1])) : 0.0;
                            X[b + 7] = (ch > 0) ? cast<double>(cast<int>(data[i - 7])) : 0.0;
                            X[b + 8] = (ch > 0) ? cast<double>(cast<int>(data[i - s2 - 1])) : 0.0;
                            X[b + 9] = (ch == 2) ? cast<double>(cast<int>(data[iW - 2])) : 0.0;
                        }
                        local ov: double = floor(olsPred(cast<*double>(ptrAdd(cast<*u8>(OL), cast<long>(ch * 1720) * 8)), oln[ch]) + 0.5);
                        if (ov < 0.0) {
                            pr[9] = 0;
                        } else if (ov > 255.0) {
                            pr[9] = 255;
                        } else {
                            pr[9] = cast<int>(ov);
                        }
                    }
                }
                if (fvid) {
                    # previous frame: same pixel, and same pixel + spatial change since then
                    pr[np - 2] = hasP ? Pv : pr[0];
                    pr[np - 1] = hasP ? clamp255(Pv + Wv - PWv) : pr[0];
                }
                local num: long = 0;
                local den: long = 0;
                loop (local k: int = 0; k < np; k = k + 1) {
                    local s: int = 1;
                    local kl: long = cast<long>(k);
                    if (hasW) {
                        s = s + cast<int>(perr[((iW) & rmask) * npl + kl]);
                    }
                    if (hasN) {
                        s = s + cast<int>(perr[((iN) & rmask) * npl + kl]);
                    }
                    if (hasN && hasW) {
                        s = s + cast<int>(perr[((iNW) & rmask) * npl + kl]);
                    }
                    if (hasNE) {
                        s = s + cast<int>(perr[((iNE) & rmask) * npl + kl]);
                    }
                    local w: long = 0;
                    if (fblend1) {
                        w = cast<long>(16777216) / cast<long>(s);
                    } else {
                        w = cast<long>(16777216) / (cast<long>(s) * cast<long>(s));
                    }
                    num = num + w * cast<long>(pr[k]);
                    den = den + w;
                }
                pred = cast<int>((num + den / 2) / den);
            }
            local eW: int = hasW ? cast<int>(err[(iW) & rmask]) : 0;
            local eN: int = hasN ? cast<int>(err[(iN) & rmask]) : 0;
            local eNW: int = (hasN && hasW) ? cast<int>(err[(iNW) & rmask]) : 0;
            local eNE: int = hasNE ? cast<int>(err[(iNE) & rmask]) : 0;
            local eP2: int = (ch == 2) ? cast<int>(err[(i - 2) & rmask]) : 0;
            if (ch > 0) {
                eP = cast<int>(err[(i - 1) & rmask]);
            }
            act = bitlen10(iabs(eW) + iabs(eN) + iabs(eNW) + iabs(eNE));
            local chv: uint = cast<uint>(ch);
            local qp: uint = (ch > 0) ? qe(eP, 12) : cast<uint>(255);
            ctx[0] = hash4(cast<uint>(10), chv, z, z);
            ctx[1] = hash4(cast<uint>(11), chv, qe(eW, 12), z);
            ctx[2] = hash4(cast<uint>(12), chv, qe(eN, 12), z);
            ctx[3] = hash4(cast<uint>(13), chv, qp, (ch > 0) ? z : cast<uint>(99));
            ctx[4] = hash4(cast<uint>(14), chv, qe(eW, 12), qe(eN, 12));
            ctx[5] = hash4(cast<uint>(15), chv, qp, cast<uint>(act));
            if (!flite) {
                ctx[6] = hash4(cast<uint>(16), chv, qe(eNW, 8) * cast<uint>(256) + qe(eNE, 8), cast<uint>(act));
                ctx[7] = hash4(cast<uint>(17), chv, qg(Wv - NWv) * cast<uint>(16) + qg(Nv - NWv), qg(NEv - Nv));
                local c8v: uint = cast<uint>(255);
                if (ch > 0) {
                    c8v = qe(eP, 20) * cast<uint>(256) + qe(eP2, 20);
                }
                ctx[8] = hash4(cast<uint>(18), chv, c8v, cast<uint>(pred >> 5));
                ctx[9] = hash4(cast<uint>(19), chv, qe(pr[0] - pred, 24) * cast<uint>(256) + qe(pr[4] - pred, 24), z);
                ctx[10] = hash4(cast<uint>(20), chv, qe(pr[2] - pred, 24) * cast<uint>(256) + qe(pr[3] - pred, 24), z);
                ctx[11] = hash4(cast<uint>(21), chv, qe(Wv - pred, 24) * cast<uint>(256) + qe(Nv - pred, 24), qe(NEv - pred, 24));
            }
            if (fimgx) {
                local eWW: int = hasWW ? cast<int>(err[(i - 6) & rmask]) : 0;
                local eNN: int = hasNN ? cast<int>(err[(iN - stride) & rmask]) : 0;
                ctx[12] = hash4(cast<uint>(22), chv, cast<uint>(Wv >> 3), cast<uint>(Nv >> 3));
                ctx[13] = hash4(cast<uint>(23), chv, qe(eWW, 12) * cast<uint>(256) + qe(eNN, 12), z);
                ctx[14] = hash4(cast<uint>(24), chv, cast<uint>(pred >> 3), cast<uint>(act));
                local q15: uint = cast<uint>(255);
                if (ch > 0) {
                    q15 = qe(eP, 8);
                }
                ctx[15] = hash4(cast<uint>(25), chv, q15, qe(eW, 6) * cast<uint>(256) + qe(eN, 6));
            }
            if (XOLS) {
                local q27: uint = cast<uint>(255);
                if (ch > 0) {
                    q27 = qe(eP, 10);
                }
                ctx[jols] = hash4(cast<uint>(26), chv, qe(pr[9] - pred, 40), z);
                ctx[jols + 1] = hash4(cast<uint>(27), chv, qe(pr[9] - pred, 10) * cast<uint>(256) + q27, qe(pr[0] - pred, 10));
            }
            if (XCOL) {
                ctx[jcol] = hash4(cast<uint>(28), chv, cast<uint>(Wv | (Nv << 8) | (NWv << 16)), cast<uint>(NEv));
                local cp1: int = (ch > 0) ? cast<int>(data[i - 1]) : 0;
                local cp2: int = (ch == 2) ? cast<int>(data[i - 2]) : 0;
                local cd: int = 0;
                if (ch > 0) {
                    # the very first pixel has no byte at iW - 1: it counts as 0
                    local wp: int = (i > 3) ? cast<int>(data[iW - 1]) : 0;
                    cd = wp - cp1 + 256;
                }
                ctx[jcol + 1] = hash4(cast<uint>(29), chv, cast<uint>(cp1 | (cp2 << 8) | (Wv << 16)), cast<uint>(cd) * cast<uint>(256) + cast<uint>(Nv));
            }
            if (fvid) {
                ctx[jvid] = hash4(cast<uint>(31), chv, hasP ? qe(Pv - pred, 40) : cast<uint>(999), z);
                ctx[jvid + 1] = hash4(cast<uint>(32), chv, hasP ? cast<uint>(Pv) : cast<uint>(999), qe(pr[0] - pred, 10));
                ctx[jvid + 2] = hash4(cast<uint>(33), chv, hasP ? qe(Pv - pred, 10) * cast<uint>(256) + qe(PWv - Wv, 10) : cast<uint>(99999), qe(PNv - Nv, 10));
            }
            if (XIM) {
                if (ch == 0) {
                    if (imlen > 0 && imok) {
                        imptr = imptr + 1;
                        if (imlen < 65535) {
                            imlen = imlen + 1;
                        }
                    } else {
                        imlen = 0;
                    }
                    if (x >= 1 && y >= 1 && x < width - 1) {
                        local hh: long = cast<long>(hash4(cast<uint>(97), pix24(data, iW), pix24(data, iN), pix24(data, iNW) ^ (pix24(data, iNE) * cast<uint>(0x9E3779B1))) >> 10);
                        if (imlen == 0 && IMT[hh] != cast<uint>(0)) {
                            imptr = cast<long>(IMT[hh]);
                            imlen = 1;
                        }
                        IMT[hh] = cast<uint>(px);
                    }
                    imok = true;
                }
                local iev: int = -1;
                if (imlen != 0) {
                    iev = cast<int>(data[imptr * 3 + cast<long>(ch)]);
                }
                local imq: int = (imlen > 15) ? 15 : cast<int>(imlen);
                local ihv: uint = cast<uint>(999);
                if (iev >= 0) {
                    ihv = cast<uint>((iev - pred) & 255);
                }
                # with the lite model this slot is past nctx and unused, as in C
                ctx[jim] = hash4(cast<uint>(30), chv, ihv, cast<uint>(imq));
                imev = iev;
                if (iev >= 0) {
                    local isd: int = sdiff8(iev, pred);
                    isym = (isd >= 0) ? 2 * isd : -2 * isd - 1;
                    iq = imq;
                } else {
                    isym = -1;
                }
            }
            if (!dec) {
                local s0: int = sdiff8(cast<int>(data[i]), pred);
                sym = (s0 >= 0) ? 2 * s0 : -2 * s0 - 1;
            }
        }
        local sel1: int = 0;
        if (img) {
            sel1 = act;
        } else if (aud) {
            sel1 = act + 16 * ch;
        } else if (fmsel) {
            sel1 = msel;
        }
        local c0: uint = 1;
        local node: long = 1;
        local mmiss: bool = false;
        local mmiss2: bool = false;
        local imiss: bool = false;
        local ieb: int = -1;
        local iqq: int = 0;
        local w4sel: int = 0;
        if (img && np > 9) {
            w4sel = cast<int>(qe(pr[9] - pred, 15)) - 49;
        }
        loop (local bp: int = 0; bp < 8; bp = bp + 1) {
            local b0f: int = (bp == 0) ? 1 : 0;
            if (bp == 0 || bp == 4) {
                # hash all contexts and prefetch both candidate buckets, then search
                loop (local k: int = 0; k < nctx; k = k + 1) {
                    hk[k] = nibHash(ctx[k], c0);
                    local pi0: long = cast<long>(hk[k] >> cast<uint>(32 - tb[k]));
                    prefetch(cast<*void>(ptrAdd(Tb, (tOff[k] + (pi0 << 4)) * 4)), 0, 3);
                    prefetch(cast<*void>(ptrAdd(Tb, (tOff[k] + ((pi0 ^ 1) << 4)) * 4)), 0, 3);
                }
                loop (local k: int = 0; k < nctx; k = k + 1) {
                    local h: uint = hk[k];
                    local chk: uint = (h * cast<uint>(0x2545F491)) >> 16;
                    if (chk == cast<uint>(0)) {
                        chk = cast<uint>(1);
                    }
                    local i0: uint = h >> cast<uint>(32 - tb[k]);
                    local b0: long = tOff[k] + (cast<long>(i0) << 4);
                    local b1: long = tOff[k] + (cast<long>(i0 ^ cast<uint>(1)) << 4);
                    if ((T[b0] & cast<uint>(0xFFFF)) == chk) {
                        bko[k] = b0;
                    } else if ((T[b1] & cast<uint>(0xFFFF)) == chk) {
                        bko[k] = b1;
                    } else {
                        local vb: long = b1;
                        if (((T[b0 + 1] >> 16) & cast<uint>(255)) <= ((T[b1 + 1] >> 16) & cast<uint>(255))) {
                            vb = b0;
                        }
                        T[vb] = chk;
                        loop (local j: long = 1; j < 16; j = j + 1) {
                            T[vb + j] = cast<uint>(16809984);
                        }
                        bko[k] = vb;
                    }
                }
                node = 1;
                if (bp == 0) {
                    loop (local k: int = 0; k < nrun; k = k + 1) {
                        rko[k] = bko[k];
                        local r: int = cast<int>(T[bko[k]] >> 16);
                        rb[k] = r & 255;
                        local rc: int = r >> 8;
                        rq[k] = (rc > 15) ? 15 : rc;
                        rmiss[k] = rc == 0;
                    }
                    if (XORD) {
                        hord = 0;
                        loop (local k: int = 0; k < nord; k = k + 1) {
                            if (((T[bko[k] + 1] >> 16) & cast<uint>(255)) != cast<uint>(0)) {
                                hord = hord + 1;
                            }
                        }
                    }
                }
            }
            local n: int = 0;
            loop (local k: int = 0; k < nctx; k = k + 1) {
                ev[k] = T[bko[k] + node];
                st[n] = cast<i16>(stretch[cast<int>((ev[k] & cast<uint>(0xFFFF)) >> 4)]);
                n = n + 1;
            }
            if (fhist) {
                loop (local k: int = 0; k < nctx; k = k + 1) {
                    smi[k] = k * 256 + cast<int>(ev[k] >> 24);
                    sv[k] = SM[smi[k]];
                    st[n] = cast<i16>(stretch[cast<int>((sv[k] & cast<uint>(0xFFFF)) >> 4)]);
                    n = n + 1;
                }
            }
            local eb: int = -1;
            local mq: int = 0;
            local eb2: int = -1;
            local mq2: int = 0;
            loop (local k: int = 0; k < nrun; k = k + 1) {
                if (!rmiss[k]) {
                    reb[k] = (rb[k] >> (7 - bp)) & 1;
                    local spr: int = stretch[cast<int>(RP[k * 64 + rq[k] * 2 + b0f]) >> 4];
                    st[n] = cast<i16>((reb[k] != 0) ? spr : -spr);
                } else {
                    reb[k] = -1;
                    st[n] = cast<i16>(0);
                }
                n = n + 1;
            }
            if (nimm != 0) {
                ieb = -1;
                if (isym >= 0 && !imiss) {
                    ieb = (isym >> (7 - bp)) & 1;
                    iqq = iq * 2 + b0f;
                    local spi: int = stretch[cast<int>(IMP[iqq]) >> 4];
                    st[n] = cast<i16>((ieb != 0) ? spi : -spi);
                } else {
                    st[n] = cast<i16>(0);
                }
                n = n + 1;
            }
            if (fmatch) {
                if (mb >= 0 && !mmiss) {
                    eb = (mb >> (7 - bp)) & 1;
                    mq = lenq * 2 + b0f;
                    local sp: int = stretch[cast<int>(MP[mq]) >> 4];
                    st[n] = cast<i16>((eb != 0) ? sp : -sp);
                } else {
                    st[n] = cast<i16>(0);
                }
                n = n + 1;
            }
            if (fm2nd) {
                if (mb2 >= 0 && !mmiss2) {
                    eb2 = (mb2 >> (7 - bp)) & 1;
                    mq2 = lenq2 * 2 + b0f;
                    local sp2: int = stretch[cast<int>(MP2[mq2]) >> 4];
                    st[n] = cast<i16>((eb2 != 0) ? sp2 : -sp2);
                } else {
                    st[n] = cast<i16>(0);
                }
                n = n + 1;
            }
            st[n] = cast<i16>(256);
            if (XIM) {
                local isel: int = 4;
                if (isym < 0) {
                    isel = 0;
                } else if (imiss) {
                    isel = 1;
                } else if (iq < 4) {
                    isel = 2;
                } else if (iq < 12) {
                    isel = 3;
                }
                sel1 = act + 16 * isel;
            }
            local w1o: int = (bp * 256 + (XORD ? sel1 * 16 + hord : sel1)) * 96;
            local w2o: int = cast<int>(c0) * 96;
            local w3o: int = 0;
            local w4o: int = 0;
            if (img) {
                local sel2: int = 0;
                if (ch > 0) {
                    sel2 = cast<int>(qe(eP, 15)) - 49;
                }
                w2o = ((bp * 3 + ch) * 32 + sel2) * 96;
                w3o = ((ch * 256 + cast<int>(c0)) & 2047) * 96;
                w4o = ((bp * 3 + ch) * 32 + w4sel) * 96;
            } else if (aud) {
                w2o = (ch * 256 + cast<int>(c0)) * 96;
                w3o = ((((ch * 16 + act) * 8 + bp) + 1024 * (ach & 1)) & 2047) * 96;
                w4o = ((bp * 2 + ch) * 64 + aq) * 96;
            } else {
                w3o = (cast<int>(((c4 & cast<uint>(0xFF)) << 3) | cast<uint>(bp)) & 2047) * 96;
                w4o = cast<int>((((c4 >> 8) & cast<uint>(0xFF)) << 3) | cast<uint>(bp)) * 96;
            }
            local wfo: int = cast<int>(c0) * 4;
            # mixers: int16 weights and inputs, wrapping 32-bit sum, arithmetic >> 12
            local s1: int = dot16(&W1[w1o], stp, nin);
            local d: int = s1 >> 12;
            local p1: int = clampp(squash(d));
            local p2: int = 0;
            local p3: int = 0;
            local p4: int = 0;
            local pf: int = 0;
            local d2: int = 0;
            if (fmix2) {
                local s2m: int = dot16(&W2[w2o], stp, nin);
                d2 = s2m >> 12;
                p2 = clampp(squash(d2));
                d = (d + d2) >> 1;
            }
            if (fmix3) {
                local s3: int = dot16(&W3[w3o], stp, nin);
                if (XM4) {
                    local s4: int = dot16(&W4[w4o], stp, nin);
                    dd[3] = clamp2047(s4 >> 12);
                    p4 = clampp(squash(dd[3]));
                }
                dd[0] = clamp2047(s1 >> 12);
                dd[1] = clamp2047(d2);
                dd[2] = clamp2047(s3 >> 12);
                p3 = clampp(squash(dd[2]));
                local df: long = cast<long>(WF[wfo]) * cast<long>(dd[0]) + cast<long>(WF[wfo + 1]) * cast<long>(dd[1]) + cast<long>(WF[wfo + 2]) * cast<long>(dd[2]) + cast<long>(WF[wfo + 3]) * cast<long>(dd[3]);
                d = cast<int>(df >> 16);
                pf = clampp(squash(d));
            }
            local p12: int = squash(d);
            local ai1: int = 0;
            local aw1: int = 0;
            local ai2: int = 0;
            local aw2: int = 0;
            local ai3: int = 0;
            local aw3: int = 0;
            local a3used: bool = false;
            if (fmix2) {
                local ds: int = clamp2047(d);
                local pos: int = (ds + 2048) * 32;
                local a1c: int = 0;
                if (img) {
                    a1c = (cast<int>(c0) * 16 + act) * 3 + ch;
                } else if (aud) {
                    a1c = cast<int>(c0) | ((act + 16 * ch) << 8);
                } else {
                    a1c = cast<int>(c0 | ((c4 & cast<uint>(255)) << 8));
                }
                aw1 = pos & 4095;
                ai1 = a1c * 33 + (pos >> 12);
                local pa: int = (cast<int>(A1[ai1]) * (4096 - aw1) + cast<int>(A1[ai1 + 1]) * aw1) >> 16;
                if (fapm2) {
                    local a2c: int = cast<int>(((hash4(cast<uint>(77), c4 & cast<uint>(0xFFFF), z, z) >> 22) << 8) | c0);
                    aw2 = aw1;
                    ai2 = a2c * 33 + (pos >> 12);
                    local pb: int = (cast<int>(A2[ai2]) * (4096 - aw2) + cast<int>(A2[ai2 + 1]) * aw2) >> 16;
                    p12 = (2 * p12 + 3 * pa + 3 * pb) >> 3;
                } else {
                    p12 = (p12 + 3 * pa) >> 2;
                }
                if (fmapm && mb >= 0 && !mmiss) {
                    local lq: int = (lenq > 15) ? 15 : lenq;
                    local a3c: int = (((mb + 256) >> (7 - bp)) & 255) | (lq << 8) | 4096;
                    aw3 = aw1;
                    ai3 = a3c * 33 + (pos >> 12);
                    local pm: int = (cast<int>(A3[ai3]) * (4096 - aw3) + cast<int>(A3[ai3 + 1]) * aw3) >> 16;
                    p12 = (p12 + pm) >> 1;
                    a3used = true;
                }
            }
            p12 = clampp(p12);
            # ---- arithmetic coder (inlined) ----
            local bit: int = (sym >> (7 - bp)) & 1;
            local xmid: uint = x1 + ((x2 - x1) >> 12) * cast<uint>(p12);
            if (dec) {
                bit = (xx <= xmid) ? 1 : 0;
            }
            if (bit != 0) {
                x2 = xmid;
            } else {
                x1 = xmid + cast<uint>(1);
            }
            loop (((x1 ^ x2) & cast<uint>(0xFF000000)) == cast<uint>(0)) {
                if (dec) {
                    local nb: uint = 0;
                    if (gpos < glen) {
                        nb = cast<uint>(gbuf[gpos]);
                    }
                    gpos = gpos + 1;
                    xx = (xx << 8) | nb;
                } else {
                    if (glen < gcap) {
                        gbuf[glen] = cast<u8>(x2 >> 24);
                    } else {
                        ovf = true;
                    }
                    glen = glen + 1;
                }
                x1 = x1 << 8;
                x2 = (x2 << 8) | cast<uint>(255);
            }
            # ---- updates ----
            local el1: int = ((bit << 12) - p1) * lr;
            upd16(&W1[w1o], stp, nin, el1);
            if (fmix2) {
                local el2: int = ((bit << 12) - p2) * lr;
                upd16(&W2[w2o], stp, nin, el2);
                if (fmix3) {
                    local el3: int = ((bit << 12) - p3) * lr;
                    upd16(&W3[w3o], stp, nin, el3);
                    if (XM4) {
                        local el4: int = ((bit << 12) - p4) * lr;
                        upd16(&W4[w4o], stp, nin, el4);
                    }
                    local elf: int = ((bit << 12) - pf) * lr;
                    loop (local k: int = 0; k < nm; k = k + 1) {
                        WF[wfo + k] = clampW(WF[wfo + k] + ((dd[k] * elf) >> 14));
                    }
                }
                local g: int = (bit << 16) + (bit << 5) - bit - bit;
                local ja: int = ((aw1 >> 11) != 0) ? ai1 + 1 : ai1;
                local av: int = cast<int>(A1[ja]);
                A1[ja] = cast<u16>(av + ((g - av) >> 6));
                if (fapm2) {
                    local jb: int = ((aw2 >> 11) != 0) ? ai2 + 1 : ai2;
                    local bv: int = cast<int>(A2[jb]);
                    A2[jb] = cast<u16>(bv + ((g - bv) >> 6));
                }
                if (a3used) {
                    local jc: int = ((aw3 >> 11) != 0) ? ai3 + 1 : ai3;
                    local cv: int = cast<int>(A3[jc]);
                    A3[jc] = cast<u16>(cv + ((g - cv) >> 6));
                }
            }
            loop (local k: int = 0; k < nctx; k = k + 1) {
                local e: uint = ev[k];
                local p: int = cast<int>(e & cast<uint>(0xFFFF));
                local cnt: int = cast<int>((e >> 16) & cast<uint>(255));
                local hb: uint = e >> 24;
                local np2: int = p + ((((bit << 16) - p) * recip[cnt]) >> 15);
                if (cnt < limit) {
                    cnt = cnt + 1;
                }
                hb = (hb << 1) | cast<uint>(bit);
                if (hb >= cast<uint>(256)) {
                    hb = (hb & cast<uint>(0x7F)) | cast<uint>(0x80);
                }
                ev[k] = cast<uint>(np2) | (cast<uint>(cnt) << 16) | (hb << 24);
            }
            if (fhist) {
                loop (local k: int = 0; k < nctx; k = k + 1) {
                    local spv: int = cast<int>(sv[k] & cast<uint>(0xFFFF));
                    local sn: int = cast<int>(sv[k] >> 16);
                    spv = spv + ((((bit << 16) - spv) * recip[sn]) >> 15);
                    if (sn < 255) {
                        sn = sn + 1;
                    }
                    sv[k] = cast<uint>(spv) | (cast<uint>(sn) << 16);
                }
                loop (local k: int = 0; k < nctx; k = k + 1) {
                    SM[smi[k]] = sv[k];
                }
            }
            # stores kept out of the arithmetic passes above so that those vectorize
            loop (local k: int = 0; k < nctx; k = k + 1) {
                T[bko[k] + node] = ev[k];
            }
            loop (local k: int = 0; k < nrun; k = k + 1) {
                if (reb[k] >= 0) {
                    local okr: int = (bit == reb[k]) ? 1 : 0;
                    local jr: int = k * 64 + rq[k] * 2 + b0f;
                    local rcn: int = cast<int>(RN[jr]);
                    local rpv: int = cast<int>(RP[jr]);
                    RP[jr] = cast<u16>((rpv + ((((okr << 16) - rpv) * recip[rcn]) >> 15)) & 65535);
                    if (rcn < 255) {
                        RN[jr] = cast<u8>(rcn + 1);
                    }
                    if (okr == 0) {
                        rmiss[k] = true;
                    }
                }
            }
            if (ieb >= 0) {
                local oki: int = (bit == ieb) ? 1 : 0;
                local icn: int = cast<int>(IMN[iqq]);
                local ipv: int = cast<int>(IMP[iqq]);
                IMP[iqq] = cast<u16>((ipv + ((((oki << 16) - ipv) * recip[icn]) >> 15)) & 65535);
                if (icn < 255) {
                    IMN[iqq] = cast<u8>(icn + 1);
                }
                if (oki == 0) {
                    imiss = true;
                }
            }
            if (eb >= 0) {
                local ok: int = (bit == eb) ? 1 : 0;
                local mc: int = cast<int>(MN[mq]);
                local mpv: int = cast<int>(MP[mq]);
                MP[mq] = cast<u16>((mpv + ((((ok << 16) - mpv) * recip[mc]) >> 15)) & 65535);
                if (mc < 255) {
                    MN[mq] = cast<u8>(mc + 1);
                }
                if (ok == 0) {
                    mmiss = true;
                }
            }
            if (eb2 >= 0) {
                local ok2: int = (bit == eb2) ? 1 : 0;
                local mc2: int = cast<int>(MN2[mq2]);
                local mpv2: int = cast<int>(MP2[mq2]);
                MP2[mq2] = cast<u16>((mpv2 + ((((ok2 << 16) - mpv2) * recip[mc2]) >> 15)) & 65535);
                if (mc2 < 255) {
                    MN2[mq2] = cast<u8>(mc2 + 1);
                }
                if (ok2 == 0) {
                    mmiss2 = true;
                }
            }
            c0 = c0 * cast<uint>(2) + cast<uint>(bit);
            node = node * 2 + cast<long>(bit);
        }
        local v: int = cast<int>(c0 & cast<uint>(255));
        if (aud) {
            if ((i & 1) == 0) {
                ahi = v;
            } else {
                local sj: long = i >> 1;
                if (dec) {
                    local zz: int = (ahi << 8) | v;
                    local zr: int = ((zz & 1) != 0) ? -((zz + 1) >> 1) : (zz >> 1);
                    local dsv: int = s16(apred + zr);
                    data[i - 1] = cast<u8>(dsv & 255);
                    data[i] = cast<u8>((dsv >> 8) & 255);
                }
                local asv: int = smp(data, sj);
                aerr[sj] = cast<i16>(s16(asv - apred));
                if (sj / nchan >= cast<long>(an1)) {
                    local achl: long = cast<long>(ach);
                    olsUpd(cast<*double>(ptrAdd(cast<*u8>(AO), achl * 1720 * 8)), AOm, an, &acnt[achl], 0.998, cast<double>(asv));
                    olsUpd(cast<*double>(ptrAdd(cast<*u8>(AO), (nchan + achl) * 1720 * 8)), AOm, 8, &acnt[nchan + achl], 0.99, cast<double>(asv));
                }
            }
        } else if (!img) {
            if (dec) {
                data[i] = cast<u8>(v);
            }
            loop (local k: int = 0; k < nrun; k = k + 1) {
                local r: uint = T[rko[k]] >> 16;
                local rbv: uint = r & cast<uint>(255);
                local rc: uint = r >> 8;
                if (rc != cast<uint>(0) && rbv == cast<uint>(v)) {
                    if (rc < cast<uint>(255)) {
                        rc = rc + cast<uint>(1);
                    }
                } else {
                    rbv = cast<uint>(v);
                    rc = cast<uint>(1);
                }
                T[rko[k]] = (T[rko[k]] & cast<uint>(0xFFFF)) | ((rbv | (rc << 8)) << 16);
            }
            local cb: uint = cast<uint>(data[i]);
            if (find) {
                local i1: long = cast<long>(c4 & cast<uint>(0xFF));
                IND1[i1] = cast<u16>(((cast<uint>(IND1[i1]) << 8) | cb) & cast<uint>(0xFFFF));
                local h2: long = cast<long>(hash4(cast<uint>(52), c4 & cast<uint>(0xFFFF), z, z) >> 10);
                IND2[h2] = cast<u16>(((cast<uint>(IND2[h2]) << 8) | cb) & cast<uint>(0xFFFF));
            }
            if (cb == cast<uint>(10)) {
                prevline = linestart;
                linestart = i + 1;
                indent = 0;
                inind = true;
            } else if (inind && (cb == cast<uint>(32) || cb == cast<uint>(9))) {
                indent = indent + 1;
            } else {
                inind = false;
            }
            c8 = (c8 << 8) | (c4 >> 24);
            c4 = (c4 << 8) | cb;
            if (fword) {
                local b: int = cast<int>(cb);
                local isw: bool = (b >= 97 && b <= 122) || (b >= 65 && b <= 90) || (b >= 48 && b <= 57) || b == 95 || b >= 128;
                if (isw) {
                    w0 = (w0 + cast<uint>(b | 32) + cast<uint>(1)) * cast<uint>(0x01000193);
                } else if (w0 != cast<uint>(0)) {
                    w2h = w1h;
                    w1h = w0;
                    w0 = 0;
                }
            }
        } else {
            if (dec) {
                local sd: int = v >> 1;
                if ((v & 1) != 0) {
                    sd = -((v + 1) >> 1);
                }
                data[i] = cast<u8>((pred + sd) & 255);
            }
            local di: int = cast<int>(data[i]);
            err[(i) & rmask] = cast<i16>(sdiff8(di, pred));
            loop (local k: int = 0; k < np; k = k + 1) {
                local ek: int = iabs(di - pr[k]);
                if (ek > 255) {
                    ek = 255;
                }
                perr[((i) & rmask) * npl + cast<long>(k)] = cast<u8>(ek);
            }
            if (imev >= 0 && di != imev) {
                imok = false;
            }
            if (XOLS && oin) {
                olsUpd(cast<*double>(ptrAdd(cast<*u8>(OL), cast<long>(ch * 1720) * 8)), OLm, oln[ch], &olc[ch], 0.998, cast<double>(di));
            }
        }
    }
    G_X1 = x1;
    G_X2 = x2;
    G_X = xx;
    G_LEN = glen;
    G_POS = gpos;
    G_OVF = ovf;
    S_MPTR = mptr;
    S_MLEN = mlen;
    S_MPTR2 = mptr2;
    S_MLEN2 = mlen2;
    S_LINESTART = linestart;
    S_PREVLINE = prevline;
    S_INDENT = indent;
    S_ININD = inind;
    S_IMPTR = imptr;
    S_IMLEN = imlen;
    S_IMOK = imok;
    S_C4 = c4;
    S_C8 = c8;
    S_W0 = w0;
    S_W1H = w1h;
    S_W2H = w2h;
    S_OLC0 = olc[0];
    S_OLC1 = olc[1];
    S_OLC2 = olc[2];
    S_APRED = apred;
    S_AZIG = azig;
    S_AHI = ahi;
    S_AQ = aq;
    S_ACH = ach;
    loop (local j: int = 0; j < 64; j = j + 1) {
        SVP[j] = MP[j];
        SVP[64 + j] = MP2[j];
        SVP[128 + j] = IMP[j];
        SVN[j] = MN[j];
        SVN[64 + j] = MN2[j];
        SVN[128 + j] = IMN[j];
    }
}

frame run(mode: int, bb: int, limit: int, feat: uint, feat2: uint, width: long, data: *u8, L: long) {
    local i0: long = 0;
    loop (i0 < L || i0 == 0) {
        local i1: long = i0 + CHUNK;
        if (i1 > L) {
            i1 = L;
        }
        runChunk(mode, bb, limit, feat, feat2, width, data, L, i0, i1);
        i0 = i0 + CHUNK;
        if (G_DEC && G_POS > G_END) {
            return;   # read past the end of the payload: corrupt (checked by the caller)
        }
    }
}

# ---- E8/E9 x86 transform ----
@[unchecked]
frame e8e9Detect(d: *u8, n: long) ret bool {
    local cnt: long = 0;
    local good: long = 0;
    loop (local i: long = 0; i + 4 < n; i = i + 1) {
        if (d[i] == cast<u8>(232) || d[i] == cast<u8>(233)) {
            cnt = cnt + 1;
            if (d[i + 4] == cast<u8>(0) || d[i + 4] == cast<u8>(255)) {
                good = good + 1;
            }
        }
    }
    return cnt > n / 256 && good * 2 > cnt;
}

@[unchecked]
frame e8e9(d: *u8, n: long, fwd: bool) {
    local i: long = 0;
    loop (i + 4 < n) {
        if (d[i] == cast<u8>(232) || d[i] == cast<u8>(233)) {
            local v: uint = cast<uint>(d[i + 1]) | (cast<uint>(d[i + 2]) << 8) | (cast<uint>(d[i + 3]) << 16) | (cast<uint>(d[i + 4]) << 24);
            if (fwd) {
                v = v + cast<uint>(i + 5);
            } else {
                v = v - cast<uint>(i + 5);
            }
            d[i + 1] = cast<u8>(v & cast<uint>(255));
            d[i + 2] = cast<u8>((v >> 8) & cast<uint>(255));
            d[i + 3] = cast<u8>((v >> 16) & cast<uint>(255));
            d[i + 4] = cast<u8>((v >> 24) & cast<uint>(255));
            i = i + 5;
        } else {
            i = i + 1;
        }
    }
}

# ---- container ----
frame put32(p: *u8, v: uint) {
    p[0] = cast<u8>(v & cast<uint>(255));
    p[1] = cast<u8>((v >> 8) & cast<uint>(255));
    p[2] = cast<u8>((v >> 16) & cast<uint>(255));
    p[3] = cast<u8>((v >> 24) & cast<uint>(255));
}

frame get32(p: *u8) ret uint {
    return cast<uint>(p[0]) | (cast<uint>(p[1]) << 8) | (cast<uint>(p[2]) << 16) | (cast<uint>(p[3]) << 24);
}

# CRC-32 (IEEE, as in zlib/PNG)
@[unchecked]
frame crc32Of(p: *u8, n: long) ret uint {
    local t: *uint = CRC_T;
    local c: uint = cast<uint>(0xFFFFFFFF);
    loop (local i: long = 0; i < n; i = i + 1) {
        c = t[cast<long>((c ^ cast<uint>(p[i])) & cast<uint>(255))] ^ (c >> cast<uint>(8));
    }
    return c ^ cast<uint>(0xFFFFFFFF);
}

frame writeHeader(h: *u8, mode: int, bb: int, limit: int, lr: int, feat: uint, feat2: uint, width: long, L: long, crc: uint) {
    h[0] = cast<u8>(70);
    h[1] = cast<u8>(77);
    h[2] = cast<u8>(52);
    h[3] = cast<u8>(2);
    h[4] = cast<u8>(mode);
    h[5] = cast<u8>(bb);
    h[6] = cast<u8>(limit);
    h[7] = cast<u8>(lr);
    put32(ptrAdd(h, 8), feat);
    put32(ptrAdd(h, 12), cast<uint>(width));
    put32(ptrAdd(h, 16), cast<uint>(L & 4294967295));
    put32(ptrAdd(h, 20), cast<uint>(L >> 32));
    put32(ptrAdd(h, 24), feat2);
    put32(ptrAdd(h, 28), crc);
    put32(ptrAdd(h, 32), crc32Of(h, 32));
}

frame ensureOut(L: long) {
    local need: long = L + HDR + 64;
    if (need > OB_CAP) {
        if (OB0 != nullptr) {
            free(cast<*void>(OB0));
        }
        OB0 = cast<*u8>(xalloc(need));
        OB_CAP = need;
    }
}

# encode into buf; container length, or -1 if it cannot beat store
frame encodeOne(buf: *u8, mode: int, bb: int, limit: int, feat: uint, feat2: uint, width: long, data: *u8, L: long) ret long {
    G_X1 = 0;
    G_X2 = cast<uint>(0xFFFFFFFF);
    G_X = 0;
    G_DEC = false;
    G_OVF = false;
    G_BUF = buf;
    G_CAP = L + HDR;
    G_LEN = HDR;
    G_POS = 0;
    run(mode, bb, limit, feat, feat2, width, data, L);
    loop (local i: int = 3; i >= 0; i = i - 1) {
        emitByte(cast<u8>((G_X1 >> cast<uint>(8 * i)) & cast<uint>(255)));
    }
    if (G_OVF) {
        return -1;
    }
    writeHeader(buf, mode, bb, limit, LR, feat, feat2, width, L, G_CRC);
    return G_LEN;
}

frame levelFeat(level: int, mode: int) ret uint {
    local bl1: uint = cast<uint>(2097152 | 1 | 4);
    local bl2: uint = cast<uint>(1 | 2 | 4 | 32);
    local bl3: uint = bl2 | cast<uint>(8 | 128 | 32768 | 65536 | 131072 | 262144);
    local bl4: uint = bl3 | cast<uint>(16 | 256 | 2048);
    local il1: uint = cast<uint>(2097152);
    local il2: uint = cast<uint>(1048576);
    local il3: uint = il2 | cast<uint>(32);
    local il4: uint = il3 | cast<uint>(256 | 512);
    if (mode == 3) {
        local al: uint[6] = [0, 0, 32, 288, 2336, 2336];
        return al[level];
    }
    if (mode == 2) {
        if (level == 1) {
            return il1;
        }
        if (level == 2) {
            return il2;
        }
        if (level == 3) {
            return il3;
        }
        return il4;
    }
    if (level == 1) {
        return bl1;
    }
    if (level == 2) {
        return bl2;
    }
    if (level == 3) {
        return bl3;
    }
    return bl4;
}

frame levelFeat2(level: int, mode: int) ret uint {
    local bl2: uint[6] = [0, 0, 1, 5, 7, 15];
    local il2: uint[6] = [0, 0, 128, 192, 210, 242];
    local al2: uint[6] = [0, 0, 0, 2, 34, 34];
    if (mode == 3) {
        return al2[level];
    }
    return (mode == 2) ? il2[level] : bl2[level];
}

# Encode; result in fm4Result(). Returns container length. data is restored after an E8/E9 pass.
@[c_export]
frame fm4Encode(level: int, mode: int, width: long, data: *u8, L: long) ret long {
    initTables();
    ensureOut(L);
    LR = 4;
    local best: *u8 = OB0;
    local bestLen: long = -1;
    G_CRC = crc32Of(data, L);
    if (level >= 1 && level <= 5) {
        local feat: uint = levelFeat(level, mode);
        local feat2: uint = levelFeat2(level, mode);
        local bb: int = bbFor(L, (level == 5 && mode == 1) ? 19 : 18);
        # video; a plain image 65536*k wide is not (its low 16 bits are no width)
        if (mode == 2 && (width >> 16) != 0 && (width & 65535) != 0 && level >= 2) {
            feat2 = feat2 | cast<uint>(256);
        }
        if (mode == 1 && e8e9Detect(data, L)) {
            e8e9(data, L, true);
            feat = feat | cast<uint>(64);
        }
        bestLen = encodeOne(best, mode, bb, 255, feat, feat2, width, data, L);
        if ((feat & cast<uint>(64)) != cast<uint>(0)) {
            e8e9(data, L, false);
        }
    }
    if (bestLen < 0 || bestLen >= L + HDR) {
        writeHeader(best, 0, 0, 0, 0, cast<uint>(0), cast<uint>(0), width, L, G_CRC);
        memcpy(cast<*void>(ptrAdd(best, HDR)), cast<*void>(data), L);
        bestLen = L + HDR;
    }
    RESULT = best;
    return bestLen;
}

# Decode; result in fm4Result(). Returns original length, or -1 for a bad container. Format 2: header CRC,
# L bounded by the payload (~2840 bytes per payload byte at most), no read past the payload, CRC of the result;
# format 1 (no CRCs, trailing zero bytes stripped): only a fixed cap on L. Same rules as c/fm4.c.
@[c_export]
frame fm4Decode(f: *u8, n: long) ret long {
    initTables();
    if (n < HDR1 || f[0] != cast<u8>(70) || f[1] != cast<u8>(77) || f[2] != cast<u8>(52) || f[3] < cast<u8>(1) || f[3] > cast<u8>(2)) {
        return -1;
    }
    local v2: bool = f[3] == cast<u8>(2);
    local hd: long = v2 ? HDR : HDR1;
    local mode: int = cast<int>(f[4]);
    local bb: int = cast<int>(f[5]);
    local limit: int = cast<int>(f[6]);
    local feat: uint = get32(ptrAdd(f, 8));
    local feat2: uint = get32(ptrAdd(f, 24));
    local width: long = cast<long>(get32(ptrAdd(f, 12)));
    local L: long = cast<long>(get32(ptrAdd(f, 16))) | (cast<long>(get32(ptrAdd(f, 20))) << 32);
    if (!fm4StreamOk(f, n, L)) {
        return -1;   # format 2: header CRC and L bound
    }
    if (mode > 3 || (mode == 2 && (width & 65535) == 0) || (mode == 3 && (width < 1 || width > 8))) {
        return -1;
    }
    if (mode != 0 && (bb < BB_MIN || bb > BB_DEC_MAX || !paramsOk(mode, feat, feat2, width, limit, cast<int>(f[7])))) {
        return -1;
    }
    if (mode == 0 && L > n - hd) {
        return -1;
    }
    # whole pixels / frames / samples, as the encoder requires (else the last bytes would never be written)
    local fw: long = width & 65535;
    if (mode == 2 && (L % (3 * fw) != 0 || ((width >> 16) != 0 && L % (3 * fw * (width >> 16)) != 0))) {
        return -1;
    }
    if (mode == 3 && L % (2 * width) != 0) {
        return -1;
    }
    if (L + 1 > DB_CAP) {
        if (DB != nullptr) {
            free(cast<*void>(DB));
        }
        DB = cast<*u8>(malloc(L + 1));
        DB_CAP = L + 1;
        if (DB == nullptr) {
            DB_CAP = 0;
            return -1;
        }
    }
    if (mode == 0) {
        memcpy(cast<*void>(DB), cast<*void>(ptrAdd(f, hd)), L);
    } else {
        LR = cast<int>(f[7]);
        G_DEC = true;
        G_BUF = ptrAdd(f, hd);
        G_LEN = n - hd;
        G_END = v2 ? n - hd : 9223372036854775807;
        G_POS = 0;
        G_X1 = 0;
        G_X2 = cast<uint>(0xFFFFFFFF);
        G_X = 0;
        G_OVF = false;
        loop (local i: int = 0; i < 4; i = i + 1) {
            G_X = (G_X << 8) | nextByte();
        }
        run(mode, bb, limit, feat, feat2, width, DB, L);
        G_DEC = false;
        if (G_POS > G_END) {
            return -1;
        }
        if ((feat & cast<uint>(64)) != cast<uint>(0)) {
            e8e9(DB, L, false);
        }
    }
    if (v2 && crc32Of(DB, L) != get32(ptrAdd(f, 28))) {
        return -1;
    }
    RESULT = DB;
    return L;
}

# The model's indexing is only valid for the feature sets the levels produce, so the decoder accepts exactly
# those (params_ok in c/fm4.c): levels 1-5 of the mode, plus the x86 bit (bytes) and the video bit (image with a
# frame height, levels 2-5), counter limit 255, mixer rate 1-15.
frame paramsOk(mode: int, feat0: uint, feat20: uint, width: long, limit: int, lr: int) ret bool {
    if (ANY_FEAT) {
        return true;
    }
    if (limit != 255 || lr < 1 || lr > 15) {
        return false;
    }
    local feat: uint = feat0;
    local feat2: uint = feat20;
    if (mode == 1) {
        feat = feat & ~cast<uint>(64);
    }
    local video: bool = mode == 2 && (feat2 & cast<uint>(256)) != cast<uint>(0);
    if (video) {
        if ((width >> 16) == 0) {
            return false;
        }
        feat2 = feat2 & ~cast<uint>(256);
    }
    loop (local level: int = 1; level <= 5; level = level + 1) {
        if (feat == levelFeat(level, mode) && feat2 == levelFeat2(level, mode) && (!video || level >= 2) && !(mode == 2 && !video && level >= 2 && (width >> 16) != 0)) {
            return true;
        }
    }
    return false;
}

# Lifts the paramsOk restriction for files from FEAT/FEAT2/LR experiments (the native CLI: FM4_ANY_FEAT=1).
# Only for trusted input: other parameter sets can index past the model's arrays.
@[c_export]
frame fm4AllowAnyParams() {
    ANY_FEAT = true;
}

# Checks of one FM4 stream (m >= 28 bytes at s, decoded length L) that need no decoding: the fixed cap, and for
# format 2 the header CRC and the L bound (stream_ok in c/fm4.c). fm4Decode starts with it; containers call it
# for each stream before adding the lengths up and allocating.
@[c_export]
frame fm4StreamOk(s: *u8, m: long, L: long) ret bool {
    initTables();
    if (L < 0 || L > 1099511627776) {
        return false;
    }
    if (s[3] != cast<u8>(2)) {
        return true;
    }
    if (m < HDR || get32(ptrAdd(s, 32)) != crc32Of(s, 32)) {
        return false;
    }
    return (s[4] == cast<u8>(0)) ? L <= m - HDR : L / 4096 <= m - HDR;
}

# Optional: give the codec its working memory (n bytes at p, allocated with malloc or compatible; the
# codec frees it if it ever needs more). The native CLI passes huge-page memory here.
@[c_export]
frame fm4SetArena(p: *u8, n: long) {
    if (AR_RAW != nullptr) {
        free(cast<*void>(AR_RAW));
    }
    arenaAdopt(p, n);
}

@[c_export]
frame fm4Result() ret *u8 {
    return RESULT;
}

# Reusable input buffer for hosts that copy data in (JS / WebAssembly).
@[c_export]
frame fm4InputBuffer(n: long) ret *u8 {
    if (n + 1 > IB_CAP) {
        if (IB != nullptr) {
            free(cast<*void>(IB));
        }
        IB = cast<*u8>(xalloc(n + 1));
        IB_CAP = n + 1;
    }
    return IB;
}

# Table bits for L bytes: the level's default, or less for short inputs (2^(bb-2) >= L), as in c/fm4.c.
frame bbFor(L: long, dflt: int) ret int {
    local bb: int = BB_MIN;
    loop (bb < dflt && (cast<long>(1) << cast<long>(bb - 2)) < L) {
        bb = bb + 1;
    }
    return bb;
}

# Upper bound of bytes the next encode of L bytes (any level) may newly allocate.
@[c_export]
frame fm4Estimate(L: long, mode: int) ret long {
    return estimateWith(L, mode, bbFor(L, (mode == 2) ? 18 : 19));
}

# The same for decoding a stream whose header says bb (any value a decoder accepts).
@[c_export]
frame fm4EstimateDecode(L: long, mode: int, bb: int) ret long {
    return estimateWith(L, mode, (bb < BB_MIN) ? BB_MIN : ((bb > BB_DEC_MAX) ? BB_DEC_MAX : bb));
}

frame estimateWith(L: long, mode: int, bb: int) ret long {
    local total: long = 1048576 + 4096 * 4 + 256 * 4 + 33 * 4;
    # worst case: video bit set, 8 audio channels
    local ar: long = arenaSize(mode, bb, levelFeat(5, mode), levelFeat2(5, mode) | cast<uint>((mode == 2) ? 256 : 0), L, 8);
    if (ar > AR_CAP) {
        total = total + ar + 64;
    }
    local need: long = L + HDR + 64;
    if (need > OB_CAP) {
        total = total + need;
    }
    if (L + 1 > DB_CAP) {
        total = total + L + 1;
    }
    if (L + 1 > IB_CAP) {
        total = total + L + 1;
    }
    return total;
}

export fm4Encode;
export fm4Decode;
export fm4Result;
export fm4InputBuffer;
export fm4Estimate;
export fm4EstimateDecode;
export xalloc;
export fm4StreamOk;
export fm4AllowAnyParams;
export fm4SetArena;
