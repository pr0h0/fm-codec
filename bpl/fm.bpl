# Model fraction (FRC1), BPL port. Same spec as c/fm.c (byte-identical output).
#   fm enc bytes IN OUT | fm enc image WIDTH IN OUT | fm dec IN OUT
import printf, malloc, free, strcmp, atoi from "std/c.bpl";

extern fopen(path: string, mode: string) ret *void;
extern fread(buffer: *void, size: long, count: long, stream: *void) ret long;
extern fwrite(buffer: *void, size: long, count: long, stream: *void) ret long;
extern fclose(stream: *void) ret int;
extern fseek(stream: *void, offset: long, whence: int) ret int;
extern ftell(stream: *void) ret long;
extern realloc(ptr: *void, size: long) ret *void;
extern calloc(count: long, size: long) ret *void;

global TSIZE: long = 4194304;
global TMASK: uint = 4194303;
global SQ_T: *int = nullptr;
global STRETCH: *int = nullptr;
global RECIP: *int = nullptr;

# arithmetic coder state
global G_X1: uint = 0;
global G_X2: uint = 0;
global G_X: uint = 0;
global G_BUF: *u8 = nullptr;
global G_LEN: long = 0;
global G_POS: long = 0;
global G_CAP: long = 0;
global G_DEC: bool = false;

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
    RECIP = cast<*int>(malloc(64 * 4));
    loop (local n: int = 0; n < 64; n = n + 1) {
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

frame emitByte(b: u8) {
    if (G_LEN == G_CAP) {
        G_CAP = (G_CAP == 0) ? 65536 : G_CAP * 2;
        G_BUF = cast<*u8>(realloc(cast<*void>(G_BUF), G_CAP));
    }
    G_BUF[G_LEN] = b;
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
            emitByte(cast<u8>(G_X2 >> 24));
        }
        G_X1 = G_X1 << 8;
        G_X2 = (G_X2 << 8) | cast<uint>(255);
    }
    return bit;
}

frame q16(e: int) ret uint {
    local v: int = e;
    if (v < -12) {
        v = -12;
    }
    if (v > 12) {
        v = 12;
    }
    return cast<uint>(v + 16);
}

frame iabs(v: int) ret int {
    return (v < 0) ? -v : v;
}

frame run(mode: int, width: long, data: *u8, L: long) {
    local nin: int = (mode != 0) ? 7 : 6;
    local P: *u16 = cast<*u16>(malloc(TSIZE * 2 * cast<long>(nin)));
    local N: *u8 = cast<*u8>(calloc(TSIZE * cast<long>(nin), 1));
    loop (local j: long = 0; j < TSIZE * cast<long>(nin); j = j + 1) {
        P[j] = cast<u16>(32768);
    }
    local W: *int = cast<*int>(malloc(8 * 7 * 4));
    loop (local j: int = 0; j < 56; j = j + 1) {
        W[j] = 19661;
    }
    local err: *i16 = cast<*i16>(calloc(L + 1, 2));
    local ctx: *uint = cast<*uint>(malloc(7 * 4));
    local idx: *long = cast<*long>(malloc(7 * 8));
    local st: *int = cast<*int>(malloc(7 * 4));
    local ord: int[6] = [0, 1, 2, 3, 4, 6];
    local c4: uint = 0;
    local c8: uint = 0;

    loop (local i: long = 0; i < L; i = i + 1) {
        local med: int = 0;
        if (mode == 0) {
            loop (local k: int = 0; k < 6; k = k + 1) {
                local o: int = ord[k];
                local m: uint = cast<uint>(0xFFFFFFFF);
                if (o < 4) {
                    m = (cast<uint>(1) << cast<uint>(8 * o)) - cast<uint>(1);
                }
                local hi: uint = 0;
                if (o == 6) {
                    hi = c8 & cast<uint>(0xFFFF);
                }
                ctx[k] = hash4(cast<uint>(o), c4 & m, hi, cast<uint>(0));
            }
        } else {
            local ch: uint = cast<uint>(i % 3);
            local x: long = (i / 3) % width;
            local up: long = i - 3 * width;
            local a: int = 0;
            if (x > 0) {
                a = cast<int>(data[i - 3]);
            } else if (up >= 0) {
                a = cast<int>(data[up]);
            }
            local b: int = a;
            if (up >= 0) {
                b = cast<int>(data[up]);
            }
            local cc: int = b;
            if (up >= 0 && x > 0) {
                cc = cast<int>(data[up - 3]);
            }
            local mx: int = (a > b) ? a : b;
            local mn: int = (a < b) ? a : b;
            if (cc >= mx) {
                med = mn;
            } else if (cc <= mn) {
                med = mx;
            } else {
                med = a + b - cc;
            }
            local ea: uint = 16;
            if (x > 0) {
                ea = q16(cast<int>(err[i - 3]));
            }
            local eb: uint = 16;
            if (up >= 0) {
                eb = q16(cast<int>(err[up]));
            }
            local ep: uint = 255;
            if (ch != cast<uint>(0)) {
                ep = q16(cast<int>(err[i - 1]));
            }
            local gv: int = iabs(a - cc) + iabs(b - cc);
            local g: uint = 0;
            loop (gv > 0) {
                g = g + cast<uint>(1);
                gv = gv >> 1;
            }
            local z: uint = 0;
            ctx[0] = hash4(cast<uint>(10), ch, z, z);
            ctx[1] = hash4(cast<uint>(11), ch, ea, z);
            ctx[2] = hash4(cast<uint>(12), ch, eb, z);
            ctx[3] = hash4(cast<uint>(13), ch, ep, z);
            ctx[4] = hash4(cast<uint>(14), ch, ea, eb);
            ctx[5] = hash4(cast<uint>(15), ch, ep, g);
            ctx[6] = hash4(cast<uint>(16), ch, ep, ea);
        }
        local sym: int = 0;
        if (!G_DEC) {
            if (mode != 0) {
                sym = (cast<int>(data[i]) - med) & 255;
            } else {
                sym = cast<int>(data[i]);
            }
        }
        local c0: uint = 1;
        loop (local bp: int = 0; bp < 8; bp = bp + 1) {
            local wb: int = bp * 7;
            local cmix: uint = c0 * cast<uint>(0x9E3779B1);
            local dot: long = 0;
            loop (local k: int = 0; k < nin; k = k + 1) {
                local j: long = cast<long>(k) * TSIZE + cast<long>((ctx[k] + cmix) & TMASK);
                idx[k] = j;
                st[k] = STRETCH[cast<int>(P[j]) >> 4];
                dot = dot + cast<long>(W[wb + k]) * cast<long>(st[k]);
            }
            local p12: int = squash(cast<int>(dot >> 16));
            if (p12 < 1) {
                p12 = 1;
            }
            if (p12 > 4095) {
                p12 = 4095;
            }
            local bit: int = codeBit(p12, (sym >> (7 - bp)) & 1);
            local e: int = (bit << 12) - p12;
            loop (local k: int = 0; k < nin; k = k + 1) {
                local nw: int = W[wb + k] + ((st[k] * e * 20) >> 14);
                if (nw > 4194304) {
                    nw = 4194304;
                }
                if (nw < -4194304) {
                    nw = -4194304;
                }
                W[wb + k] = nw;
                local j: long = idx[k];
                local n: int = cast<int>(N[j]);
                local pk: int = cast<int>(P[j]);
                local p: int = pk + ((((bit << 16) - pk) * RECIP[n]) >> 15);
                if (p < 0) {
                    p = 0;
                }
                if (p > 65535) {
                    p = 65535;
                }
                P[j] = cast<u16>(p);
                if (n < 60) {
                    N[j] = cast<u8>(n + 1);
                }
            }
            c0 = c0 * cast<uint>(2) + cast<uint>(bit);
        }
        local byte: int = cast<int>(c0 & cast<uint>(255));
        if (mode == 0) {
            if (G_DEC) {
                data[i] = cast<u8>(byte);
            }
            c8 = (c8 << 8) | (c4 >> 24);
            c4 = (c4 << 8) | cast<uint>(data[i]);
        } else {
            if (G_DEC) {
                data[i] = cast<u8>((med + byte) & 255);
            }
            err[i] = cast<i16>(cast<int>(data[i]) - med);
        }
    }
    free(cast<*void>(P));
    free(cast<*void>(N));
    free(cast<*void>(W));
    free(cast<*void>(err));
    free(cast<*void>(ctx));
    free(cast<*void>(idx));
    free(cast<*void>(st));
}

frame slurp(path: string, outLen: *long) ret *u8 {
    local f: *void = fopen(path, "rb");
    if (f == nullptr) {
        printf("cannot open %s\n", path);
        return nullptr;
    }
    fseek(f, 0, 2);
    local n: long = ftell(f);
    fseek(f, 0, 0);
    local b: *u8 = cast<*u8>(malloc(n + 1));
    fread(cast<*void>(b), 1, n, f);
    fclose(f);
    *outLen = n;
    return b;
}

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

frame main(argc: int, argv: *string) ret int {
    initTables();
    G_X1 = 0;
    G_X2 = cast<uint>(0xFFFFFFFF);
    if (argc >= 5 && strcmp(argv[1], "enc") == 0) {
        local mode: int = (strcmp(argv[2], "image") == 0) ? 1 : 0;
        local width: long = 0;
        if (mode != 0) {
            width = cast<long>(atoi(argv[3]));
        }
        local L: long = 0;
        local data: *u8 = slurp(argv[3 + mode], &L);
        if (data == nullptr) {
            return 1;
        }
        if (mode != 0 && (width <= 0 || L % (3 * width) != 0)) {
            printf("bad width\n");
            return 1;
        }
        run(mode, width, data, L);
        loop (local i: int = 3; i >= 0; i = i - 1) {
            emitByte(cast<u8>((G_X1 >> cast<uint>(8 * i)) & cast<uint>(255)));
        }
        loop (G_LEN > 0 && G_BUF[G_LEN - 1] == cast<u8>(0)) {
            G_LEN = G_LEN - 1;
        }
        local hdr: *u8 = cast<*u8>(malloc(13));
        hdr[0] = cast<u8>(70);
        hdr[1] = cast<u8>(82);
        hdr[2] = cast<u8>(67);
        hdr[3] = cast<u8>(49);
        hdr[4] = cast<u8>(mode);
        put32(cast<*u8>(cast<long>(hdr) + 5), cast<uint>(width));
        put32(cast<*u8>(cast<long>(hdr) + 9), cast<uint>(L));
        local f: *void = fopen(argv[4 + mode], "wb");
        fwrite(cast<*void>(hdr), 1, 13, f);
        fwrite(cast<*void>(G_BUF), 1, G_LEN, f);
        fclose(f);
        return 0;
    }
    if (argc == 4 && strcmp(argv[1], "dec") == 0) {
        local n: long = 0;
        local fb: *u8 = slurp(argv[2], &n);
        if (fb == nullptr || n < 13 || fb[0] != cast<u8>(70) || fb[3] != cast<u8>(49)) {
            printf("not an FRC1 file\n");
            return 1;
        }
        local mode: int = cast<int>(fb[4]);
        local width: long = cast<long>(get32(cast<*u8>(cast<long>(fb) + 5)));
        local L: long = cast<long>(get32(cast<*u8>(cast<long>(fb) + 9)));
        G_DEC = true;
        G_BUF = cast<*u8>(cast<long>(fb) + 13);
        G_LEN = n - 13;
        G_POS = 0;
        loop (local i: int = 0; i < 4; i = i + 1) {
            G_X = (G_X << 8) | nextByte();
        }
        local data: *u8 = cast<*u8>(malloc(L + 1));
        run(mode, width, data, L);
        local o: *void = fopen(argv[3], "wb");
        fwrite(cast<*void>(data), 1, L, o);
        fclose(o);
        return 0;
    }
    printf("usage: fm enc bytes IN OUT | fm enc image WIDTH IN OUT | fm dec IN OUT\n");
    return 2;
}
