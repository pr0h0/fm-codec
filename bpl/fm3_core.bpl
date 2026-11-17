# fm3 core (BPL). Same spec as c/fm3.c -> byte-identical output (see that file's header comment).
# Shared by the native CLI (fm3_cli.bpl) and the WebAssembly build (fm3_wasm.bpl).
# All working memory comes from reusable global buffers: wasm32 freestanding malloc is a bump
# allocator whose free() is a no-op, so repeated encode/decode calls must not allocate afresh.
# Hot-path helpers that contain loops are written inline in run(): BPL adds a stack guard to every
# function with a loop, which is measurable when called per bit.
import malloc, free, memset, memcpy from "std/c.bpl";

global HDR: long = 28;
global SQ_T: *int = nullptr;
global STRETCH: *int = nullptr;
global RECIP: *int = nullptr;
global LR: int = 4;

# coder state (shared with encodeOne / fm3Decode)
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
global AR_BASE: *u8 = nullptr;
global AR_CAP: long = 0;
global AR_USED: long = 0;
global OB0: *u8 = nullptr;
global OB1: *u8 = nullptr;
global OB_CAP: long = 0;
global DB: *u8 = nullptr;
global DB_CAP: long = 0;
global IB: *u8 = nullptr;
global IB_CAP: long = 0;
global RESULT: *u8 = nullptr;

frame ptrAdd(p: *u8, off: long) ret *u8 {
    return cast<*u8>(cast<long>(p) + off);
}

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
    SQ_T = cast<*int>(malloc(33 * 4));
    local vals: int[33] = [1, 2, 3, 6, 10, 16, 27, 45, 73, 120, 194, 310, 488, 747, 1101, 1546, 2047, 2549, 2994, 3348, 3607, 3785, 3901, 3975, 4022, 4050, 4068, 4079, 4085, 4089, 4092, 4093, 4094];
    loop (local i: int = 0; i < 33; i = i + 1) {
        SQ_T[i] = vals[i];
    }
    STRETCH = cast<*int>(malloc(4096 * 4));
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
    RECIP = cast<*int>(malloc(256 * 4));
    loop (local n: int = 0; n < 256; n = n + 1) {
        RECIP[n] = 65536 / (2 * n + 3);
    }
}

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

frame nibHash(ctx: uint, c0: uint) ret uint {
    local x: uint = ctx + c0 * cast<uint>(0x9E3779B1);
    x = x ^ (x >> 15);
    x = x * cast<uint>(0x2C1B3C6D);
    x = x ^ (x >> 12);
    x = x * cast<uint>(0x297A2D39);
    x = x ^ (x >> 15);
    return x;
}

frame clamp255(v: int) ret int {
    if (v < 0) {
        return 0;
    }
    if (v > 255) {
        return 255;
    }
    return v;
}

frame clampp(p: int) ret int {
    if (p < 1) {
        return 1;
    }
    if (p > 4095) {
        return 4095;
    }
    return p;
}

frame iabs(v: int) ret int {
    return (v < 0) ? -v : v;
}

# bit length of v in 0..1020 (branches only: a loop would add a stack guard)
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

frame clampW(v: int) ret int {
    if (v > 524287) {
        return 524287;
    }
    if (v < -524288) {
        return -524288;
    }
    return v;
}

frame clamp2047(v: int) ret int {
    if (v > 2047) {
        return 2047;
    }
    if (v < -2047) {
        return -2047;
    }
    return v;
}

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

frame emitByte(b: u8) {
    if (G_LEN < G_CAP) {
        G_BUF[G_LEN] = b;
    } else {
        G_OVF = true;
    }
    G_LEN = G_LEN + 1;
}

frame nextByte() ret uint {
    local b: uint = 0;
    if (G_POS < G_LEN) {
        b = cast<uint>(G_BUF[G_POS]);
    }
    G_POS = G_POS + 1;
    return b;
}

# ---- arena ----
frame arenaReset(total: long) {
    if (total > AR_CAP) {
        if (AR_BASE != nullptr) {
            free(cast<*void>(AR_BASE));
        }
        AR_BASE = cast<*u8>(malloc(total));
        AR_CAP = total;
    }
    AR_USED = 0;
}

frame arenaTake(n: long) ret *u8 {
    local p: *u8 = ptrAdd(AR_BASE, AR_USED);
    AR_USED = AR_USED + ((n + 63) / 64) * 64;
    return p;
}

frame hasF(feat: uint, bit: uint) ret bool {
    return (feat & bit) != cast<uint>(0);
}

# number of order contexts, context count, and table bits for context k (mirrors c/fm3.c run())
frame nOrd(img: bool, feat: uint) ret int {
    if (hasF(feat, cast<uint>(2097152))) {
        return 3;
    }
    if (!img && hasF(feat, cast<uint>(16))) {
        return 8;
    }
    return 6;
}

frame nCtx(img: bool, feat: uint) ret int {
    local lite: bool = hasF(feat, cast<uint>(2097152));
    if (img) {
        if (lite) {
            return 6;
        }
        return hasF(feat, cast<uint>(512)) ? 16 : 12;
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
    return n;
}

frame minBits(a: int, bb: int) ret int {
    return (a < bb) ? a : bb;
}

frame tableBits(img: bool, feat: uint, bb: int, k: int) ret int {
    if (img) {
        local tbi: int[16] = [8, 12, 12, 12, 16, 16, 0, 17, 0, 0, 0, 0, 17, 16, 16, 0];
        if (k < 16 && tbi[k] != 0) {
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

frame arenaSize(mode: int, bb: int, feat: uint, L: long) ret long {
    local img: bool = mode == 2;
    local nctx: int = nCtx(img, feat);
    local total: long = 0;
    loop (local k: int = 0; k < nctx; k = k + 1) {
        total = total + (cast<long>(64) << cast<long>(tableBits(img, feat, bb, k)));
    }
    total = total + 48 * 256 * 4 + 128 * 48 * 4 + 768 * 48 * 4 + 2048 * 48 * 4 + 256 * 3 * 4;
    local napm1: long = img ? 12288 : 65536;
    total = total + napm1 * 33 * 2 + 64;
    local fmatch: bool = !img && hasF(feat, cast<uint>(1));
    local fmix2: bool = hasF(feat, cast<uint>(32));
    if (!img && hasF(feat, cast<uint>(8))) {
        total = total + 262144 * 33 * 2 + 64;
    }
    if (fmatch && fmix2 && hasF(feat, cast<uint>(65536))) {
        total = total + 65536 * 33 * 2 + 64;
    }
    if (fmatch) {
        total = total + 4194304 * 4 + 64;
        if (hasF(feat, cast<uint>(131072))) {
            total = total + 4194304 * 4 + 64;
        }
    }
    if (!img && hasF(feat, cast<uint>(32768))) {
        total = total + 256 * 2 + 64 + 4194304 * 2 + 64;
    }
    if (img) {
        total = total + (L + 1) * 2 + 64;
        if (!hasF(feat, cast<uint>(2097152))) {
            total = total + (L + 1) * 9 + 64;
        }
    }
    return total + 1024;
}

# ---- model ----
frame run(mode: int, bb: int, limit: int, feat: uint, width: long, data: *u8, L: long) {
    local img: bool = mode == 2;
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
    local nctx: int = nCtx(img, feat);
    local nin: int = nctx * (fhist ? 2 : 1) + (fmatch ? 1 : 0) + (fm2nd ? 1 : 0) + 1;
    local np: int = (img && !flite) ? 9 : 0;

    arenaReset(arenaSize(mode, bb, feat, L));
    local tb: int[48] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    local tOff: long[48] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    local tTotal: long = 0;
    loop (local k: int = 0; k < nctx; k = k + 1) {
        tb[k] = tableBits(img, feat, bb, k);
        tOff[k] = tTotal;
        tTotal = tTotal + (cast<long>(16) << cast<long>(tb[k]));
    }
    local T: *uint = cast<*uint>(arenaTake(tTotal * 4));
    loop (local j: long = 0; j < tTotal; j = j + 1) {
        T[j] = ((j & 15) != 0) ? cast<uint>(16809984) : cast<uint>(0);
    }
    local SM: *uint = cast<*uint>(arenaTake(48 * 256 * 4));
    loop (local j: int = 0; j < 48 * 256; j = j + 1) {
        SM[j] = cast<uint>(32768);
    }
    local winit: int = 19661 * 6 / nin;
    local W1: *int = cast<*int>(arenaTake(128 * 48 * 4));
    local W2: *int = cast<*int>(arenaTake(768 * 48 * 4));
    local W3: *int = cast<*int>(arenaTake(2048 * 48 * 4));
    local WF: *int = cast<*int>(arenaTake(256 * 3 * 4));
    loop (local j: int = 0; j < 128 * 48; j = j + 1) {
        W1[j] = winit;
    }
    loop (local j: int = 0; j < 768 * 48; j = j + 1) {
        W2[j] = winit;
    }
    loop (local j: int = 0; j < 2048 * 48; j = j + 1) {
        W3[j] = winit;
    }
    loop (local j: int = 0; j < 768; j = j + 1) {
        WF[j] = 21845;
    }
    local apmInit: u16[33] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    loop (local j: int = 0; j < 33; j = j + 1) {
        apmInit[j] = cast<u16>(squash((j - 16) * 128) * 16);
    }
    local napm1: int = img ? 12288 : 65536;
    local A1: *u16 = cast<*u16>(arenaTake(cast<long>(napm1) * 33 * 2));
    loop (local j: int = 0; j < napm1 * 33; j = j + 1) {
        A1[j] = apmInit[j % 33];
    }
    local A2: *u16 = cast<*u16>(nullptr);
    if (fapm2) {
        A2 = cast<*u16>(arenaTake(cast<long>(262144) * 33 * 2));
        loop (local j: int = 0; j < 262144 * 33; j = j + 1) {
            A2[j] = apmInit[j % 33];
        }
    }
    local A3: *u16 = cast<*u16>(nullptr);
    if (fmapm) {
        A3 = cast<*u16>(arenaTake(cast<long>(65536) * 33 * 2));
        loop (local j: int = 0; j < 65536 * 33; j = j + 1) {
            A3[j] = apmInit[j % 33];
        }
    }
    local MT: *uint = cast<*uint>(nullptr);
    local MT2: *uint = cast<*uint>(nullptr);
    if (fmatch) {
        MT = cast<*uint>(arenaTake(4194304 * 4));
        memset(cast<*void>(MT), 0, 4194304 * 4);
        if (fm2nd) {
            MT2 = cast<*uint>(arenaTake(4194304 * 4));
            memset(cast<*void>(MT2), 0, 4194304 * 4);
        }
    }
    local IND1: *u16 = cast<*u16>(nullptr);
    local IND2: *u16 = cast<*u16>(nullptr);
    if (find) {
        IND1 = cast<*u16>(arenaTake(256 * 2));
        memset(cast<*void>(IND1), 0, 256 * 2);
        IND2 = cast<*u16>(arenaTake(4194304 * 2));
        memset(cast<*void>(IND2), 0, 4194304 * 2);
    }
    local err: *i16 = cast<*i16>(nullptr);
    local perr: *u8 = cast<*u8>(nullptr);
    if (img) {
        err = cast<*i16>(arenaTake((L + 1) * 2));
        memset(cast<*void>(err), 0, (L + 1) * 2);
        if (np > 0) {
            perr = arenaTake((L + 1) * 9);
            memset(cast<*void>(perr), 0, (L + 1) * 9);
        }
    }
    local MP: u16[64] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    local MP2: u16[64] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    local MN: u8[64] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    local MN2: u8[64] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    loop (local j: int = 0; j < 64; j = j + 1) {
        MP[j] = cast<u16>(49152);
        MP2[j] = cast<u16>(49152);
    }
    local ctx: uint[48] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    local bko: long[48] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    local st: int[50] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    local smi: int[48] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    local pr: int[9] = [0, 0, 0, 0, 0, 0, 0, 0, 0];
    local dd: int[3] = [0, 0, 0];
    local stride: long = 3 * width;
    local mptr: long = 0;
    local mlen: long = 0;
    local mptr2: long = 0;
    local mlen2: long = 0;
    local linestart: long = 0;
    local prevline: long = 0;
    local c4: uint = 0;
    local c8: uint = 0;
    local w0: uint = 0;
    local w1h: uint = 0;
    local w2h: uint = 0;
    local z: uint = 0;
    local lr: int = LR;
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

    loop (local i: long = 0; i < L; i = i + 1) {
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
        if (!img) {
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
            if (fcol) {
                local col: long = i - linestart;
                local ab: long = prevline + col;
                local above: uint = 0;
                if (ab < linestart) {
                    above = cast<uint>(data[ab]);
                }
                local colc: long = (col > 255) ? 255 : col;
                ctx[bcol] = hash4(cast<uint>(60), above, cast<uint>(colc), c4 & cast<uint>(0xFF));
                ctx[bcol + 1] = hash4(cast<uint>(61), w0, w1h, w2h);
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
                local num: long = 0;
                local den: long = 0;
                loop (local k: int = 0; k < 9; k = k + 1) {
                    local s: int = 1;
                    local kl: long = cast<long>(k);
                    if (hasW) {
                        s = s + cast<int>(perr[iW * 9 + kl]);
                    }
                    if (hasN) {
                        s = s + cast<int>(perr[iN * 9 + kl]);
                    }
                    if (hasN && hasW) {
                        s = s + cast<int>(perr[iNW * 9 + kl]);
                    }
                    if (hasNE) {
                        s = s + cast<int>(perr[iNE * 9 + kl]);
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
            local eW: int = hasW ? cast<int>(err[iW]) : 0;
            local eN: int = hasN ? cast<int>(err[iN]) : 0;
            local eNW: int = (hasN && hasW) ? cast<int>(err[iNW]) : 0;
            local eNE: int = hasNE ? cast<int>(err[iNE]) : 0;
            local eP2: int = (ch == 2) ? cast<int>(err[i - 2]) : 0;
            if (ch > 0) {
                eP = cast<int>(err[i - 1]);
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
                local eWW: int = hasWW ? cast<int>(err[i - 6]) : 0;
                local eNN: int = hasNN ? cast<int>(err[iN - stride]) : 0;
                ctx[12] = hash4(cast<uint>(22), chv, cast<uint>(Wv >> 3), cast<uint>(Nv >> 3));
                ctx[13] = hash4(cast<uint>(23), chv, qe(eWW, 12) * cast<uint>(256) + qe(eNN, 12), z);
                ctx[14] = hash4(cast<uint>(24), chv, cast<uint>(pred >> 3), cast<uint>(act));
                local q15: uint = cast<uint>(255);
                if (ch > 0) {
                    q15 = qe(eP, 8);
                }
                ctx[15] = hash4(cast<uint>(25), chv, q15, qe(eW, 6) * cast<uint>(256) + qe(eN, 6));
            }
            if (!dec) {
                local s0: int = (cast<int>(data[i]) - pred) & 255;
                if (s0 > 127) {
                    s0 = s0 - 256;
                }
                sym = (s0 >= 0) ? 2 * s0 : -2 * s0 - 1;
            }
        }
        local sel1: int = 0;
        if (img) {
            sel1 = act;
        } else if (fmsel) {
            sel1 = msel;
        }
        local c0: uint = 1;
        local node: long = 1;
        local mmiss: bool = false;
        local mmiss2: bool = false;
        loop (local bp: int = 0; bp < 8; bp = bp + 1) {
            if (bp == 0 || bp == 4) {
                loop (local k: int = 0; k < nctx; k = k + 1) {
                    local h: uint = nibHash(ctx[k], c0);
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
            }
            local n: int = 0;
            loop (local k: int = 0; k < nctx; k = k + 1) {
                st[n] = STRETCH[cast<int>((T[bko[k] + node] & cast<uint>(0xFFFF)) >> 4)];
                n = n + 1;
            }
            if (fhist) {
                loop (local k: int = 0; k < nctx; k = k + 1) {
                    smi[k] = k * 256 + cast<int>(T[bko[k] + node] >> 24);
                    st[n] = STRETCH[cast<int>((SM[smi[k]] & cast<uint>(0xFFFF)) >> 4)];
                    n = n + 1;
                }
            }
            local eb: int = -1;
            local mq: int = 0;
            local eb2: int = -1;
            local mq2: int = 0;
            if (fmatch) {
                if (mb >= 0 && !mmiss) {
                    eb = (mb >> (7 - bp)) & 1;
                    mq = lenq * 2 + ((bp == 0) ? 1 : 0);
                    local sp: int = STRETCH[cast<int>(MP[mq]) >> 4];
                    st[n] = (eb != 0) ? sp : -sp;
                } else {
                    st[n] = 0;
                }
                n = n + 1;
            }
            if (fm2nd) {
                if (mb2 >= 0 && !mmiss2) {
                    eb2 = (mb2 >> (7 - bp)) & 1;
                    mq2 = lenq2 * 2 + ((bp == 0) ? 1 : 0);
                    local sp2: int = STRETCH[cast<int>(MP2[mq2]) >> 4];
                    st[n] = (eb2 != 0) ? sp2 : -sp2;
                } else {
                    st[n] = 0;
                }
                n = n + 1;
            }
            st[n] = 256;
            local w1o: int = (bp * 16 + sel1) * 48;
            local w2o: int = cast<int>(c0) * 48;
            if (img) {
                local sel2: int = 0;
                if (ch > 0) {
                    sel2 = cast<int>(qe(eP, 15)) - 49;
                }
                w2o = ((bp * 3 + ch) * 32 + sel2) * 48;
            }
            local w3o: int = 0;
            if (img) {
                w3o = ((ch * 256 + cast<int>(c0)) & 2047) * 48;
            } else {
                w3o = (cast<int>(((c4 & cast<uint>(0xFF)) << 3) | cast<uint>(bp)) & 2047) * 48;
            }
            local wfo: int = cast<int>(c0) * 3;
            local s1: int = 0;
            loop (local k: int = 0; k < nin; k = k + 1) {
                s1 = s1 + ((W1[w1o + k] * st[k]) >> 8);
            }
            local d: int = s1 >> 8;
            local p1: int = clampp(squash(d));
            local p2: int = 0;
            local p3: int = 0;
            local pf: int = 0;
            local d2: int = 0;
            if (fmix2) {
                local s2: int = 0;
                loop (local k: int = 0; k < nin; k = k + 1) {
                    s2 = s2 + ((W2[w2o + k] * st[k]) >> 8);
                }
                d2 = s2 >> 8;
                p2 = clampp(squash(d2));
                d = (d + d2) >> 1;
            }
            if (fmix3) {
                local s3: int = 0;
                loop (local k: int = 0; k < nin; k = k + 1) {
                    s3 = s3 + ((W3[w3o + k] * st[k]) >> 8);
                }
                dd[0] = clamp2047(s1 >> 8);
                dd[1] = clamp2047(d2);
                dd[2] = clamp2047(s3 >> 8);
                p3 = clampp(squash(dd[2]));
                local df: long = cast<long>(WF[wfo]) * cast<long>(dd[0]) + cast<long>(WF[wfo + 1]) * cast<long>(dd[1]) + cast<long>(WF[wfo + 2]) * cast<long>(dd[2]);
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
            loop (local k: int = 0; k < nin; k = k + 1) {
                W1[w1o + k] = clampW(W1[w1o + k] + ((st[k] * el1) >> 14));
            }
            if (fmix2) {
                local el2: int = ((bit << 12) - p2) * lr;
                loop (local k: int = 0; k < nin; k = k + 1) {
                    W2[w2o + k] = clampW(W2[w2o + k] + ((st[k] * el2) >> 14));
                }
                if (fmix3) {
                    local el3: int = ((bit << 12) - p3) * lr;
                    loop (local k: int = 0; k < nin; k = k + 1) {
                        W3[w3o + k] = clampW(W3[w3o + k] + ((st[k] * el3) >> 14));
                    }
                    local elf: int = ((bit << 12) - pf) * lr;
                    loop (local k: int = 0; k < 3; k = k + 1) {
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
                local ei: long = bko[k] + node;
                local e: uint = T[ei];
                local p: int = cast<int>(e & cast<uint>(0xFFFF));
                local cnt: int = cast<int>((e >> 16) & cast<uint>(255));
                local hb: uint = e >> 24;
                local np2: int = p + ((((bit << 16) - p) * RECIP[cnt]) >> 15);
                if (cnt < limit) {
                    cnt = cnt + 1;
                }
                if (fhist) {
                    local sv: uint = SM[smi[k]];
                    local spv: int = cast<int>(sv & cast<uint>(0xFFFF));
                    local sn: int = cast<int>(sv >> 16);
                    spv = spv + ((((bit << 16) - spv) * RECIP[sn]) >> 15);
                    if (sn < 255) {
                        sn = sn + 1;
                    }
                    SM[smi[k]] = cast<uint>(spv) | (cast<uint>(sn) << 16);
                }
                hb = (hb << 1) | cast<uint>(bit);
                if (hb >= cast<uint>(256)) {
                    hb = (hb & cast<uint>(0x7F)) | cast<uint>(0x80);
                }
                T[ei] = cast<uint>(np2) | (cast<uint>(cnt) << 16) | (hb << 24);
            }
            if (eb >= 0) {
                local ok: int = (bit == eb) ? 1 : 0;
                local mc: int = cast<int>(MN[mq]);
                local mpv: int = cast<int>(MP[mq]);
                MP[mq] = cast<u16>(mpv + ((((ok << 16) - mpv) * RECIP[mc]) >> 15));
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
                MP2[mq2] = cast<u16>(mpv2 + ((((ok2 << 16) - mpv2) * RECIP[mc2]) >> 15));
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
        if (!img) {
            if (dec) {
                data[i] = cast<u8>(v);
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
            local ev: int = (cast<int>(data[i]) - pred) & 255;
            if (ev > 127) {
                ev = ev - 256;
            }
            err[i] = cast<i16>(ev);
            if (np > 0) {
                loop (local k: int = 0; k < 9; k = k + 1) {
                    local ek: int = iabs(cast<int>(data[i]) - pr[k]);
                    if (ek > 255) {
                        ek = 255;
                    }
                    perr[i * 9 + cast<long>(k)] = cast<u8>(ek);
                }
            }
        }
    }
    G_X1 = x1;
    G_X2 = x2;
    G_X = xx;
    G_LEN = glen;
    G_POS = gpos;
    G_OVF = ovf;
}

# ---- E8/E9 x86 transform ----
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

frame writeHeader(h: *u8, mode: int, bb: int, limit: int, lr: int, feat: uint, width: long, L: long) {
    h[0] = cast<u8>(70);
    h[1] = cast<u8>(77);
    h[2] = cast<u8>(51);
    h[3] = cast<u8>(1);
    h[4] = cast<u8>(mode);
    h[5] = cast<u8>(bb);
    h[6] = cast<u8>(limit);
    h[7] = cast<u8>(lr);
    put32(ptrAdd(h, 8), feat);
    put32(ptrAdd(h, 12), cast<uint>(width));
    put32(ptrAdd(h, 16), cast<uint>(L & 4294967295));
    put32(ptrAdd(h, 20), cast<uint>(L >> 32));
    put32(ptrAdd(h, 24), cast<uint>(0));
}

frame ensureOut(L: long) {
    local need: long = L + HDR + 64;
    if (need > OB_CAP) {
        if (OB0 != nullptr) {
            free(cast<*void>(OB0));
            free(cast<*void>(OB1));
        }
        OB0 = cast<*u8>(malloc(need));
        OB1 = cast<*u8>(malloc(need));
        OB_CAP = need;
    }
}

# one candidate into buf; container length, or -1 if it would not beat store
frame encodeOne(buf: *u8, mode: int, bb: int, limit: int, feat: uint, width: long, data: *u8, L: long) ret long {
    G_X1 = 0;
    G_X2 = cast<uint>(0xFFFFFFFF);
    G_X = 0;
    G_DEC = false;
    G_OVF = false;
    G_BUF = buf;
    G_CAP = L + HDR;
    G_LEN = HDR;
    G_POS = 0;
    run(mode, bb, limit, feat, width, data, L);
    loop (local i: int = 3; i >= 0; i = i - 1) {
        emitByte(cast<u8>((G_X1 >> cast<uint>(8 * i)) & cast<uint>(255)));
    }
    if (G_OVF) {
        return -1;
    }
    loop (G_LEN > HDR && buf[G_LEN - 1] == cast<u8>(0)) {
        G_LEN = G_LEN - 1;
    }
    writeHeader(buf, mode, bb, limit, LR, feat, width, L);
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

# Encode; result in fm3Result(). Returns container length. data is restored after an E8/E9 pass.
@[c_export]
frame fm3Encode(level: int, mode: int, width: long, data: *u8, L: long) ret long {
    initTables();
    ensureOut(L);
    LR = 4;
    local ncand: int = 0;
    local feats: uint[2] = [0, 0];
    local bbs: int[2] = [18, 18];
    if (level >= 1 && level <= 5) {
        ncand = 1;
        feats[0] = levelFeat(level, mode);
        if (level == 5 && mode == 1) {
            bbs[0] = 19;
        }
        if (level == 5 && mode == 2) {
            feats[1] = feats[0] & ~cast<uint>(1048576);
            ncand = 2;
        }
    }
    local xf: uint = cast<uint>(8192);
    if (ncand > 0 && mode == 1 && e8e9Detect(data, L)) {
        e8e9(data, L, true);
        xf = xf | cast<uint>(64);
    }
    local best: *u8 = cast<*u8>(nullptr);
    local bestLen: long = -1;
    loop (local k: int = 0; k < ncand; k = k + 1) {
        local buf: *u8 = (best == OB0) ? OB1 : OB0;
        local f: uint = (feats[k] & ~cast<uint>(64 | 8192)) | xf;
        local n: long = encodeOne(buf, mode, bbs[k], 255, f, width, data, L);
        if (n >= 0 && (bestLen < 0 || n < bestLen)) {
            best = buf;
            bestLen = n;
        }
    }
    if ((xf & cast<uint>(64)) != cast<uint>(0)) {
        e8e9(data, L, false);
    }
    if (bestLen < 0 || bestLen >= L + HDR) {
        best = OB0;
        writeHeader(best, 0, 0, 0, 0, cast<uint>(0), width, L);
        memcpy(cast<*void>(ptrAdd(best, HDR)), cast<*void>(data), L);
        bestLen = L + HDR;
    }
    RESULT = best;
    return bestLen;
}

# Decode; result in fm3Result(). Returns original length, or -1 for a bad container.
@[c_export]
frame fm3Decode(f: *u8, n: long) ret long {
    initTables();
    if (n < HDR || f[0] != cast<u8>(70) || f[1] != cast<u8>(77) || f[2] != cast<u8>(51) || f[3] != cast<u8>(1)) {
        return -1;
    }
    local mode: int = cast<int>(f[4]);
    local bb: int = cast<int>(f[5]);
    local limit: int = cast<int>(f[6]);
    local feat: uint = get32(ptrAdd(f, 8));
    local width: long = cast<long>(get32(ptrAdd(f, 12)));
    local L: long = cast<long>(get32(ptrAdd(f, 16))) | (cast<long>(get32(ptrAdd(f, 20))) << 32);
    if (L + 1 > DB_CAP) {
        if (DB != nullptr) {
            free(cast<*void>(DB));
        }
        DB = cast<*u8>(malloc(L + 1));
        DB_CAP = L + 1;
    }
    if (mode == 0) {
        memcpy(cast<*void>(DB), cast<*void>(ptrAdd(f, HDR)), L);
    } else {
        LR = cast<int>(f[7]);
        G_DEC = true;
        G_BUF = ptrAdd(f, HDR);
        G_LEN = n - HDR;
        G_POS = 0;
        G_X1 = 0;
        G_X2 = cast<uint>(0xFFFFFFFF);
        G_X = 0;
        G_OVF = false;
        loop (local i: int = 0; i < 4; i = i + 1) {
            G_X = (G_X << 8) | nextByte();
        }
        run(mode, bb, limit, feat, width, DB, L);
        G_DEC = false;
        if ((feat & cast<uint>(64)) != cast<uint>(0)) {
            e8e9(DB, L, false);
        }
    }
    RESULT = DB;
    return L;
}

@[c_export]
frame fm3Result() ret *u8 {
    return RESULT;
}

# Reusable input buffer for hosts that copy data in (JS / WebAssembly).
@[c_export]
frame fm3InputBuffer(n: long) ret *u8 {
    if (n + 1 > IB_CAP) {
        if (IB != nullptr) {
            free(cast<*void>(IB));
        }
        IB = cast<*u8>(malloc(n + 1));
        IB_CAP = n + 1;
    }
    return IB;
}

# Upper bound of bytes the next encode/decode of L bytes (any level) may newly allocate.
@[c_export]
frame fm3Estimate(L: long, mode: int) ret long {
    local feat: uint = levelFeat(4, mode);
    local bb: int = (mode == 2) ? 18 : 19;
    local total: long = 1048576 + 4096 * 4 + 256 * 4 + 33 * 4;
    local ar: long = arenaSize(mode, bb, feat, L);
    if (ar > AR_CAP) {
        total = total + ar;
    }
    local need: long = L + HDR + 64;
    if (need > OB_CAP) {
        total = total + 2 * need;
    }
    if (L + 1 > DB_CAP) {
        total = total + L + 1;
    }
    if (L + 1 > IB_CAP) {
        total = total + L + 1;
    }
    return total;
}

export fm3Encode;
export fm3Decode;
export fm3Result;
export fm3InputBuffer;
export fm3Estimate;
