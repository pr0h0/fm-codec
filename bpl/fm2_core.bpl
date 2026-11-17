# fm2 core (BPL). Same spec as c/fm2.c -> byte-identical output.
# Used by the native CLI (fm2_cli.bpl) and the WebAssembly build (fm2_wasm.bpl).
# Memory: everything comes from reusable global buffers (wasm32 freestanding malloc is a bump
# allocator whose free() is a no-op), so repeated encode/decode calls do not leak.
import malloc, free, memset, memcpy from "std/c.bpl";

global TSIZE: long = 4194304;
global TMASK: uint = 4194303;
global HDR: long = 20;
global MAXIN: int = 12;
global SQ_T: *int = nullptr;
global STRETCH: *int = nullptr;
global RECIP: *int = nullptr;

# coder state
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

frame bitlen(v: int) ret int {
    local n: int = 0;
    local x: int = v;
    loop (x > 0) {
        n = n + 1;
        x = x >> 1;
    }
    return n;
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
    if (v > 4194304) {
        return 4194304;
    }
    if (v < -4194304) {
        return -4194304;
    }
    return v;
}

# ---- coder ----
frame emit(b: u8) {
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

frame codeBit(p12: int, bitIn: int) ret int {
    local xmid: uint = G_X1 + ((G_X2 - G_X1) >> 12) * cast<uint>(p12);
    local bit: int = bitIn;
    if (G_DEC) {
        bit = (G_X <= xmid) ? 1 : 0;
    }
    if (bit != 0) {
        G_X2 = xmid;
    } else {
        G_X1 = xmid + cast<uint>(1);
    }
    loop (((G_X1 ^ G_X2) & cast<uint>(0xFF000000)) == cast<uint>(0)) {
        if (G_DEC) {
            G_X = (G_X << 8) | nextByte();
        } else {
            emit(cast<u8>(G_X2 >> 24));
        }
        G_X1 = G_X1 << 8;
        G_X2 = (G_X2 << 8) | cast<uint>(255);
    }
    return bit;
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
    AR_USED = AR_USED + ((n + 15) / 16) * 16;
    return p;
}

frame ninFor(img: bool, prof: int) ret int {
    if (img) {
        return 3 * prof;
    }
    if (prof == 1) {
        return 1;
    }
    if (prof == 2) {
        return 3;
    }
    return 6;
}

frame npFor(img: bool, prof: int) ret int {
    if (!img) {
        return 0;
    }
    if (prof == 3) {
        return 5;
    }
    if (prof == 4) {
        return 9;
    }
    return 0;
}

frame arenaSize(img: bool, prof: int, L: long) ret long {
    local nin: long = cast<long>(ninFor(img, prof));
    local np: long = cast<long>(npFor(img, prof));
    local napm: long = 1;
    if (prof == 4) {
        napm = img ? 12288 : 65536;
    }
    local total: long = TSIZE * nin * 3 + 128 * 12 * 4 + 768 * 12 * 4 + napm * 33 * 2 + 16 * 8;
    if (img) {
        total = total + (L + 1) * 2 + (L + 1) * np;
    }
    return total;
}

# ---- model ----
frame run(mode: int, prof: int, limit: int, width: long, data: *u8, L: long) {
    local img: bool = mode == 2;
    local nin: int = ninFor(img, prof);
    local direct: bool = !img && prof == 1;
    local mix2: bool = prof == 4;
    local apm: bool = prof == 4;
    local np: int = npFor(img, prof);
    local napm: int = 0;
    if (apm) {
        napm = img ? 12288 : 65536;
    }
    arenaReset(arenaSize(img, prof, L));
    local P: *u16 = cast<*u16>(arenaTake(TSIZE * cast<long>(nin) * 2));
    local N: *u8 = arenaTake(TSIZE * cast<long>(nin));
    local W1: *int = cast<*int>(arenaTake(128 * 12 * 4));
    local W2: *int = cast<*int>(arenaTake(768 * 12 * 4));
    local A: *u16 = cast<*u16>(arenaTake(cast<long>((napm > 0) ? napm : 1) * 33 * 2));
    local err: *i16 = cast<*i16>(nullptr);
    local perr: *u8 = cast<*u8>(nullptr);
    if (img) {
        err = cast<*i16>(arenaTake((L + 1) * 2));
        memset(cast<*void>(err), 0, (L + 1) * 2);
    }
    if (np > 0) {
        perr = arenaTake((L + 1) * cast<long>(np));
        memset(cast<*void>(perr), 0, (L + 1) * cast<long>(np));
    }
    local tn: long = TSIZE * cast<long>(nin);
    loop (local j: long = 0; j < tn; j = j + 1) {
        P[j] = cast<u16>(32768);
    }
    memset(cast<*void>(N), 0, tn);
    local winit: int = 19661 * 6 / nin;
    loop (local j: int = 0; j < 128 * 12; j = j + 1) {
        W1[j] = winit;
    }
    loop (local j: int = 0; j < 768 * 12; j = j + 1) {
        W2[j] = winit;
    }
    loop (local k: int = 0; k < napm; k = k + 1) {
        loop (local j: int = 0; j < 33; j = j + 1) {
            A[k * 33 + j] = cast<u16>(squash((j - 16) * 128) * 16);
        }
    }
    local ctx: uint[12] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    local idx: uint[12] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    local st: int[12] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    local pr: int[9] = [0, 0, 0, 0, 0, 0, 0, 0, 0];
    local ord2: int[3] = [1, 2, 3];
    local ord3: int[6] = [0, 1, 2, 3, 4, 6];
    local c4: uint = 0;
    local c8: uint = 0;
    local stride: long = 3 * width;
    local z: uint = 0;
    # coder state in locals: the bit coder is inlined below (a per-bit call costs a stack guard)
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
        if (!img) {
            if (prof == 1) {
                ctx[0] = hash4(cast<uint>(2), c4 & cast<uint>(0xFFFF), z, z);
            } else {
                loop (local k: int = 0; k < nin; k = k + 1) {
                    local o: int = (prof == 2) ? ord2[k] : ord3[k];
                    local m: uint = cast<uint>(0xFFFFFFFF);
                    if (o < 4) {
                        m = (cast<uint>(1) << cast<uint>(8 * o)) - cast<uint>(1);
                    }
                    local hi: uint = 0;
                    if (o == 6) {
                        hi = c8 & cast<uint>(0xFFFF);
                    }
                    ctx[k] = hash4(cast<uint>(o), c4 & m, hi, z);
                }
            }
            if (!G_DEC) {
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
            local WWv: int = (x > 1) ? cast<int>(data[i - 6]) : Wv;
            local NNv: int = (y > 1) ? cast<int>(data[iN - stride]) : Nv;
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
                local npl: long = cast<long>(np);
                loop (local k: int = 0; k < np; k = k + 1) {
                    local s: int = 1;
                    local kl: long = cast<long>(k);
                    if (hasW) {
                        s = s + cast<int>(perr[iW * npl + kl]);
                    }
                    if (hasN) {
                        s = s + cast<int>(perr[iN * npl + kl]);
                    }
                    if (hasN && hasW) {
                        s = s + cast<int>(perr[iNW * npl + kl]);
                    }
                    if (hasNE) {
                        s = s + cast<int>(perr[iNE * npl + kl]);
                    }
                    local w: long = cast<long>(16777216) / (cast<long>(s) * cast<long>(s));
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
            act = bitlen(iabs(eW) + iabs(eN) + iabs(eNW) + iabs(eNE));
            if (act > 15) {
                act = 15;
            }
            local chv: uint = cast<uint>(ch);
            local qp: uint = (ch > 0) ? qe(eP, 12) : cast<uint>(255);
            if (prof == 1) {
                ctx[0] = hash4(cast<uint>(10), chv, z, z);
                ctx[1] = hash4(cast<uint>(14), chv, qe(eW, 12), qe(eN, 12));
                ctx[2] = hash4(cast<uint>(15), chv, qp, cast<uint>(act));
            } else {
                ctx[0] = hash4(cast<uint>(10), chv, z, z);
                ctx[1] = hash4(cast<uint>(11), chv, qe(eW, 12), z);
                ctx[2] = hash4(cast<uint>(12), chv, qe(eN, 12), z);
                ctx[3] = hash4(cast<uint>(13), chv, qp, (ch > 0) ? z : cast<uint>(99));
                ctx[4] = hash4(cast<uint>(14), chv, qe(eW, 12), qe(eN, 12));
                ctx[5] = hash4(cast<uint>(15), chv, qp, cast<uint>(act));
                if (prof >= 3) {
                    ctx[6] = hash4(cast<uint>(16), chv, qe(eNW, 8) * cast<uint>(256) + qe(eNE, 8), cast<uint>(act));
                    ctx[7] = hash4(cast<uint>(17), chv, qg(Wv - NWv) * cast<uint>(16) + qg(Nv - NWv), qg(NEv - Nv));
                    local c8v: uint = cast<uint>(255);
                    if (ch > 0) {
                        c8v = qe(eP, 20) * cast<uint>(256) + qe(eP2, 20);
                    }
                    ctx[8] = hash4(cast<uint>(18), chv, c8v, cast<uint>(pred >> 5));
                }
                if (prof == 4) {
                    ctx[9] = hash4(cast<uint>(19), chv, qe(pr[0] - pred, 24) * cast<uint>(256) + qe(pr[4] - pred, 24), z);
                    ctx[10] = hash4(cast<uint>(20), chv, qe(pr[2] - pred, 24) * cast<uint>(256) + qe(pr[3] - pred, 24), z);
                    ctx[11] = hash4(cast<uint>(21), chv, qe(Wv - pred, 24) * cast<uint>(256) + qe(Nv - pred, 24), qe(NEv - pred, 24));
                }
            }
            if (!G_DEC) {
                local s: int = (cast<int>(data[i]) - pred) & 255;
                if (s > 127) {
                    s = s - 256;
                }
                sym = (s >= 0) ? 2 * s : -2 * s - 1;
            }
        }
        local sel1: int = 0;
        if (img && prof >= 3) {
            sel1 = act;
        }
        local c0: uint = 1;
        loop (local bp: int = 0; bp < 8; bp = bp + 1) {
            local p12: int = 0;
            local p1: int = 0;
            local p2: int = 0;
            local aidx: int = 0;
            local awt: int = 0;
            local w1: int = (bp * 16 + sel1) * 12;
            local w2: int = cast<int>(c0) * 12;
            if (img) {
                local sel2: int = 0;
                if (ch > 0) {
                    sel2 = cast<int>(qe(eP, 15)) - 49;
                }
                w2 = ((bp * 3 + ch) * 32 + sel2) * 12;
            }
            local cmix: uint = c0 * cast<uint>(0x9E3779B1);
            loop (local k: int = 0; k < nin; k = k + 1) {
                local j: uint = cast<uint>(k) * cast<uint>(4194304) + ((ctx[k] + cmix) & TMASK);
                idx[k] = j;
                st[k] = STRETCH[cast<int>(P[cast<long>(j)]) >> 4];
            }
            if (direct) {
                p12 = clampp(cast<int>(P[cast<long>(idx[0])]) >> 4);
            } else {
                local dot: long = 0;
                loop (local k: int = 0; k < nin; k = k + 1) {
                    dot = dot + cast<long>(W1[w1 + k]) * cast<long>(st[k]);
                }
                local d: int = cast<int>(dot >> 16);
                p1 = clampp(squash(d));
                if (mix2) {
                    local dot2: long = 0;
                    loop (local k: int = 0; k < nin; k = k + 1) {
                        dot2 = dot2 + cast<long>(W2[w2 + k]) * cast<long>(st[k]);
                    }
                    local d2: int = cast<int>(dot2 >> 16);
                    p2 = clampp(squash(d2));
                    d = (d + d2) >> 1;
                }
                p12 = squash(d);
                if (apm) {
                    local ds: int = d;
                    if (ds < -2047) {
                        ds = -2047;
                    }
                    if (ds > 2047) {
                        ds = 2047;
                    }
                    local a: int = 0;
                    if (img) {
                        a = (cast<int>(c0) * 16 + act) * 3 + ch;
                    } else {
                        a = cast<int>(c0 | ((c4 & cast<uint>(255)) << 8));
                    }
                    local pos: int = (ds + 2048) * 32;
                    awt = pos & 4095;
                    aidx = a * 33 + (pos >> 12);
                    local pa: int = (cast<int>(A[aidx]) * (4096 - awt) + cast<int>(A[aidx + 1]) * awt) >> 16;
                    p12 = (p12 + 3 * pa) >> 2;
                }
                p12 = clampp(p12);
            }
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
            if (!direct) {
                local e1: int = (bit << 12) - p1;
                loop (local k: int = 0; k < nin; k = k + 1) {
                    W1[w1 + k] = clampW(W1[w1 + k] + ((st[k] * e1 * 20) >> 14));
                }
                if (mix2) {
                    local e2: int = (bit << 12) - p2;
                    loop (local k: int = 0; k < nin; k = k + 1) {
                        W2[w2 + k] = clampW(W2[w2 + k] + ((st[k] * e2 * 20) >> 14));
                    }
                }
                if (apm) {
                    local g: int = (bit << 16) + (bit << 5) - bit - bit;
                    local ja: int = aidx;
                    if ((awt >> 11) != 0) {
                        ja = aidx + 1;
                    }
                    local av: int = cast<int>(A[ja]);
                    A[ja] = cast<u16>(av + ((g - av) >> 6));
                }
            }
            loop (local k: int = 0; k < nin; k = k + 1) {
                local jl: long = cast<long>(idx[k]);
                local n: int = cast<int>(N[jl]);
                local pk: int = cast<int>(P[jl]);
                local p: int = pk + ((((bit << 16) - pk) * RECIP[n]) >> 15);
                if (p < 0) {
                    p = 0;
                }
                if (p > 65535) {
                    p = 65535;
                }
                P[jl] = cast<u16>(p);
                if (n < limit) {
                    N[jl] = cast<u8>(n + 1);
                }
            }
            c0 = c0 * cast<uint>(2) + cast<uint>(bit);
        }
        local v: int = cast<int>(c0 & cast<uint>(255));
        if (!img) {
            if (G_DEC) {
                data[i] = cast<u8>(v);
            }
            c8 = (c8 << 8) | (c4 >> 24);
            c4 = (c4 << 8) | cast<uint>(data[i]);
        } else {
            if (G_DEC) {
                local s: int = v >> 1;
                if ((v & 1) != 0) {
                    s = -((v + 1) >> 1);
                }
                data[i] = cast<u8>((pred + s) & 255);
            }
            local e: int = (cast<int>(data[i]) - pred) & 255;
            if (e > 127) {
                e = e - 256;
            }
            err[i] = cast<i16>(e);
            loop (local k: int = 0; k < np; k = k + 1) {
                local ek: int = iabs(cast<int>(data[i]) - pr[k]);
                if (ek > 255) {
                    ek = 255;
                }
                perr[i * cast<long>(np) + cast<long>(k)] = cast<u8>(ek);
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

# ---- container ----
frame put32(p: *u8, v: uint) {
    loop (local i: int = 0; i < 4; i = i + 1) {
        p[i] = cast<u8>((v >> cast<uint>(8 * i)) & cast<uint>(255));
    }
}

frame get32(p: *u8) ret uint {
    local v: uint = 0;
    loop (local i: int = 3; i >= 0; i = i - 1) {
        v = (v << 8) | cast<uint>(p[i]);
    }
    return v;
}

frame writeHeader(h: *u8, mode: int, prof: int, limit: int, width: long, L: long) {
    h[0] = cast<u8>(70);
    h[1] = cast<u8>(77);
    h[2] = cast<u8>(50);
    h[3] = cast<u8>(1);
    h[4] = cast<u8>(mode);
    h[5] = cast<u8>(prof);
    h[6] = cast<u8>(limit);
    h[7] = cast<u8>(0);
    put32(ptrAdd(h, 8), cast<uint>(width));
    put32(ptrAdd(h, 12), cast<uint>(L & 4294967295));
    put32(ptrAdd(h, 16), cast<uint>(L >> 32));
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

# encode one candidate into buf; returns container length, or -1 if it would not beat store
frame encodeOne(buf: *u8, mode: int, prof: int, limit: int, width: long, data: *u8, L: long) ret long {
    G_X1 = 0;
    G_X2 = cast<uint>(0xFFFFFFFF);
    G_DEC = false;
    G_OVF = false;
    G_BUF = buf;
    G_CAP = L + HDR;
    G_LEN = HDR;
    run(mode, prof, limit, width, data, L);
    loop (local i: int = 3; i >= 0; i = i - 1) {
        emit(cast<u8>((G_X1 >> cast<uint>(8 * i)) & cast<uint>(255)));
    }
    if (G_OVF) {
        return -1;
    }
    loop (G_LEN > HDR && buf[G_LEN - 1] == cast<u8>(0)) {
        G_LEN = G_LEN - 1;
    }
    writeHeader(buf, mode, prof, limit, width, L);
    return G_LEN;
}

# Encode; result in fm2Result(). Returns container length.
@[c_export]
frame fm2Encode(level: int, mode: int, width: long, data: *u8, L: long) ret long {
    initTables();
    ensureOut(L);
    local profs: int[3] = [0, 0, 0];
    local limits: int[3] = [0, 0, 0];
    local ncand: int = 0;
    if (level >= 1 && level <= 5) {
        ncand = 1;
        if (mode == 2) {
            local ip: int[6] = [0, 1, 2, 3, 4, 4];
            local il: int[6] = [0, 60, 60, 255, 255, 255];
            profs[0] = ip[level];
            limits[0] = il[level];
        } else {
            local bpf: int[6] = [0, 1, 2, 3, 4, 4];
            local bl: int[6] = [0, 60, 60, 60, 255, 255];
            profs[0] = bpf[level];
            limits[0] = bl[level];
            if (level == 5) {
                ncand = 3;
                profs[1] = 4;
                limits[1] = 60;
                profs[2] = 3;
                limits[2] = 255;
            }
        }
    }
    local best: *u8 = cast<*u8>(nullptr);
    local bestLen: long = -1;
    loop (local k: int = 0; k < ncand; k = k + 1) {
        local buf: *u8 = (best == OB0) ? OB1 : OB0;
        local n: long = encodeOne(buf, mode, profs[k], limits[k], width, data, L);
        if (n >= 0 && (bestLen < 0 || n < bestLen)) {
            best = buf;
            bestLen = n;
        }
    }
    if (bestLen < 0 || bestLen >= L + HDR) {
        best = OB0;
        writeHeader(best, 0, 0, 0, width, L);
        memcpy(cast<*void>(ptrAdd(best, HDR)), cast<*void>(data), L);
        bestLen = L + HDR;
    }
    RESULT = best;
    return bestLen;
}

# Decode; result in fm2Result(). Returns original length, or -1 for a bad container.
@[c_export]
frame fm2Decode(f: *u8, n: long) ret long {
    initTables();
    if (n < HDR || f[0] != cast<u8>(70) || f[1] != cast<u8>(77) || f[2] != cast<u8>(50) || f[3] != cast<u8>(1)) {
        return -1;
    }
    local mode: int = cast<int>(f[4]);
    local prof: int = cast<int>(f[5]);
    local limit: int = cast<int>(f[6]);
    local width: long = cast<long>(get32(ptrAdd(f, 8)));
    local L: long = cast<long>(get32(ptrAdd(f, 12))) | (cast<long>(get32(ptrAdd(f, 16))) << 32);
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
        G_DEC = true;
        G_BUF = ptrAdd(f, HDR);
        G_LEN = n - HDR;
        G_POS = 0;
        G_X1 = 0;
        G_X2 = cast<uint>(0xFFFFFFFF);
        G_X = 0;
        loop (local i: int = 0; i < 4; i = i + 1) {
            G_X = (G_X << 8) | nextByte();
        }
        run(mode, prof, limit, width, DB, L);
        G_DEC = false;
    }
    RESULT = DB;
    return L;
}

@[c_export]
frame fm2Result() ret *u8 {
    return RESULT;
}

# Reusable input buffer (for hosts such as JS/WebAssembly that must copy data in).
@[c_export]
frame fm2InputBuffer(n: long) ret *u8 {
    if (n + 1 > IB_CAP) {
        if (IB != nullptr) {
            free(cast<*void>(IB));
        }
        IB = cast<*u8>(malloc(n + 1));
        IB_CAP = n + 1;
    }
    return IB;
}

# Upper bound of bytes the next encode/decode of L bytes may newly allocate (for wasm memory growth).
@[c_export]
frame fm2Estimate(L: long, mode: int) ret long {
    local img: bool = mode == 2;
    local total: long = 1048576 + 4096 * 4 + 256 * 4 + 33 * 4;
    local ar: long = arenaSize(img, 4, L);
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

export fm2Encode;
export fm2Decode;
export fm2Result;
export fm2InputBuffer;
export fm2Estimate;
