# fm4 native CLI (BPL):  fm4 enc LEVEL bytes IN OUT | fm4 enc LEVEL image WIDTH IN OUT |
# fm4 enc LEVEL audio CHANNELS IN OUT | fm4 enc LEVEL video WIDTH HEIGHT IN OUT | fm4 dec IN OUT
# fm4 enc|dec -t N ...: processes for segmented video (same FMV format and cut as c/fm4.c).
import printf, malloc, strcmp, atoi from "std/c.bpl";
import fm4Encode, fm4Decode, fm4Result, fm4Estimate, fm4SetArena, xalloc, fm4StreamOk, fm4AllowAnyParams from "./fm4_core.bpl";

extern fopen(path: string, mode: string) ret *void;
extern fread(buffer: *void, size: long, count: long, stream: *void) ret long;
extern fwrite(buffer: *void, size: long, count: long, stream: *void) ret long;
extern fclose(stream: *void) ret int;
extern fseek(stream: *void, offset: long, whence: int) ret int;
extern ftell(stream: *void) ret long;
extern posix_memalign(out: **void, align: long, size: long) ret int;
extern madvise(p: *void, n: long, advice: int) ret int;
extern atoll(s: string) ret long;
extern getenv(name: string) ret string;
extern atof(s: string) ret double;
extern sysconf(name: int) ret long;
extern fork() ret int;
extern wait(status: *int) ret int;
extern _exit(code: int);
extern fflush(stream: *void) ret int;
extern mmap(addr: *void, n: long, prot: int, flags: int, fd: int, off: long) ret *void;
extern memcpy(dst: *void, src: *void, n: long) ret *void;
extern memmove(dst: *void, src: *void, n: long) ret *void;

global HDR_MAX: long = 36;   # 28-byte FM4 header + 8 (stream may exceed L by the header plus a little)
global USAGE: string = "usage: fm4 enc LEVEL(0-5) bytes IN OUT | fm4 enc LEVEL image WIDTH IN OUT | fm4 enc LEVEL audio CHANNELS IN OUT | fm4 enc LEVEL video WIDTH HEIGHT IN OUT | fm4 dec IN OUT | fm4 enc|dec -t N ...\n";

# Working memory for L input bytes on 2 MB huge pages where the system gives them (fewer TLB misses
# in the big hash tables; no effect on the output). On failure the codec allocates for itself.
frame hugeArena(L: long, mode: int) {
    local n: long = fm4Estimate(L, mode);
    local p: *void = nullptr;
    if (posix_memalign(&p, 2097152, n) == 0) {
        madvise(p, n, 14);
        fm4SetArena(cast<*u8>(p), n);
    }
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
    local b: *u8 = cast<*u8>(xalloc(n + 1));
    fread(cast<*void>(b), 1, n, f);
    fclose(f);
    *outLen = n;
    return b;
}

frame spit(path: string, b: *u8, n: long) ret int {
    local f: *void = fopen(path, "wb");
    if (f == nullptr) {
        printf("cannot write %s\n", path);
        return 1;
    }
    fwrite(cast<*void>(b), 1, n, f);
    fclose(f);
    return 0;
}


frame get64(p: *u8) ret long {
    local v: long = 0;
    loop (local i: int = 7; i >= 0; i = i - 1) {
        v = (v << 8) | cast<long>(p[i]);
    }
    return v;
}

frame put64(p: *u8, v: long) {
    loop (local i: int = 0; i < 8; i = i + 1) {
        p[i] = cast<u8>((v >> (8 * i)) & 255);
    }
}

frame shared(n: long) ret *u8 {
    # MAP_SHARED | MAP_ANONYMOUS: children write results here
    local p: *void = mmap(nullptr, n, 3, 33, -1, 0);
    if (cast<long>(p) == -1) {
        return nullptr;
    }
    return cast<*u8>(p);
}

# Segmented video: "FMV\x01" | u32 nseg | nseg x (u64 length | FM4 stream), each stream a run of whole
# frames. Inputs of at least 2 x SEG_MB (default 64 MB) are cut into L / SEG_MB runs; same rule as c/fm4.c.
frame videoSegments(L: long, fbytes: long) ret long {
    local mb: double = 64.0;
    if (getenv("SEG_MB") != nullptr) {
        mb = atof(getenv("SEG_MB"));
    }
    local seg: long = cast<long>(mb * 1048576.0);
    local nf: long = L / fbytes;
    local ns: long = 1;
    if (seg > 0) {
        ns = L / seg;
    }
    if (ns > nf) {
        return (nf > 0) ? nf : 1;
    }
    return (ns < 1) ? 1 : ns;
}

# One forked process per job, at most `threads` at once. Encode: in/L -> out = u64 length | stream
# (out holds L + 36 bytes). Decode: in/n -> out, exactly L bytes. Returns 0 when every job succeeded.
frame runJobs(nj: long, threads: long, decode: bool, mode: int, level: int, width: long, ins: **u8, ns: *long, Ls: *long, outs: **u8) ret int {
    local next: long = 0;
    local running: long = 0;
    local fail: int = 0;
    local st: int = 0;
    loop (next < nj || running > 0) {
        if (next < nj && running < threads) {
            local j: long = next;
            next = next + 1;
            fflush(nullptr);
            local pid: int = fork();
            if (pid < 0) {
                printf("fork failed\n");
                return 1;
            }
            if (pid == 0) {
                if (decode) {
                    hugeArena(Ls[j], 2);
                    local m: long = fm4Decode(ins[j], ns[j]);
                    if (m != Ls[j]) {
                        _exit(1);
                    }
                    memcpy(cast<*void>(outs[j]), cast<*void>(fm4Result()), m);
                } else {
                    hugeArena(Ls[j], mode);
                    local m2: long = fm4Encode(level, mode, width, ins[j], Ls[j]);
                    put64(outs[j], m2);
                    memcpy(cast<*void>(&outs[j][8]), cast<*void>(fm4Result()), m2);
                }
                _exit(0);
            }
            running = running + 1;
        } else {
            if (wait(&st) < 0 || st != 0) {
                fail = 1;
            }
            running = running - 1;
        }
    }
    return fail;
}

frame encVideoSegments(level: int, width: long, data: *u8, L: long, ns: long, threads: long, out: string) ret int {
    local fbytes: long = 3 * (width & 65535) * (width >> 16);
    local nf: long = L / fbytes;
    local ins: **u8 = cast<**u8>(xalloc(ns * 8));
    local Ls: *long = cast<*long>(xalloc(ns * 8));
    local outs: **u8 = cast<**u8>(xalloc(ns * 8));
    loop (local k: long = 0; k < ns; k = k + 1) {
        local a: long = nf * k / ns * fbytes;
        local b: long = nf * (k + 1) / ns * fbytes;
        ins[k] = &data[a];
        Ls[k] = b - a;
        outs[k] = shared(b - a + HDR_MAX + 8);
        if (outs[k] == nullptr) {
            printf("mmap failed\n");
            return 1;
        }
    }
    if (runJobs(ns, threads, false, 2, level, width, ins, Ls, Ls, outs) != 0) {
        printf("compression failed\n");
        return 1;
    }
    local f: *void = fopen(out, "wb");
    if (f == nullptr) {
        printf("cannot write %s\n", out);
        return 1;
    }
    local h: *u8 = cast<*u8>(xalloc(8));
    h[0] = cast<u8>(70);
    h[1] = cast<u8>(77);
    h[2] = cast<u8>(86);
    h[3] = cast<u8>(1);
    put64(&h[4], ns);
    fwrite(cast<*void>(h), 1, 8, f);
    loop (local k2: long = 0; k2 < ns; k2 = k2 + 1) {
        fwrite(cast<*void>(outs[k2]), 1, 8 + get64(outs[k2]), f);
    }
    if (fclose(f) != 0) {
        printf("cannot write %s\n", out);
        return 1;
    }
    return 0;
}

# Returns the decoded length (output in *outp), or -1 for a corrupt file.
frame decVideoSegments(f: *u8, n: long, threads: long, outp: **u8) ret long {
    local ns: long = get64(&f[4]) & 4294967295;
    if (ns > (n - 8) / 36) {   # each segment takes at least 8 + 28 bytes
        return -1;
    }
    local ins: **u8 = cast<**u8>(xalloc(ns * 8 + 8));
    local Ms: *long = cast<*long>(xalloc(ns * 8 + 8));
    local Ls: *long = cast<*long>(xalloc(ns * 8 + 8));
    local outs: **u8 = cast<**u8>(xalloc(ns * 8 + 8));
    local all: long = 0;
    local pos: long = 8;
    loop (local k: long = 0; k < ns; k = k + 1) {
        if (n - pos < 36) {
            return -1;
        }
        local m: long = get64(&f[pos]);
        local sl: long = get64(&f[pos + 24]);
        if (m < 28 || m > n - pos - 8 || !fm4StreamOk(&f[pos + 8], m, sl)) {
            return -1;
        }
        ins[k] = &f[pos + 8];
        Ms[k] = m;
        Ls[k] = sl;
        all = all + sl;
        pos = pos + 8 + m;
    }
    if (pos != n) {
        return -1;
    }
    local d: *u8 = shared((all > 0) ? all : 1);
    if (d == nullptr) {
        return -1;
    }
    local o: long = 0;
    loop (local k2: long = 0; k2 < ns; k2 = k2 + 1) {
        outs[k2] = &d[o];
        o = o + Ls[k2];
    }
    if (runJobs(ns, threads, true, 0, 0, 0, ins, Ms, Ls, outs) != 0) {
        return -1;
    }
    *outp = d;
    return all;
}

frame main(argc: int, argv: *string) ret int {
    if (getenv("FM4_ANY_FEAT") != nullptr) {
        fm4AllowAnyParams();   # decode files from FEAT/FEAT2/LR experiments (trusted input only)
    }
    local threads: long = sysconf(84);
    if (argc >= 4 && (strcmp(argv[1], "enc") == 0 || strcmp(argv[1], "dec") == 0) && strcmp(argv[2], "-t") == 0) {
        threads = atoll(argv[3]);
        if (threads < 1) {
            printf("%s", USAGE);
            return 2;
        }
        memmove(cast<*void>(&argv[2]), cast<*void>(&argv[4]), cast<long>(argc - 3) * 8);
        argc = argc - 2;
    }
    if (argc >= 6 && strcmp(argv[1], "enc") == 0) {
        local level: int = atoi(argv[2]);
        local video: int = (strcmp(argv[3], "video") == 0) ? 1 : 0;
        local mode: int = 1;
        if (video == 1 || strcmp(argv[3], "image") == 0) {
            mode = 2;
        } else if (strcmp(argv[3], "audio") == 0) {
            mode = 3;
        }
        local width: long = 0;
        local fheight: long = 0;
        local ia: int = 4;
        if (level < 0 || level > 5 || (mode >= 2 && argc < 7 + video)) {
            printf("%s", USAGE);
            return 2;
        }
        if (mode >= 2) {
            width = atoll(argv[4]);
            ia = 5 + video;
        }
        if (video == 1) {
            fheight = atoll(argv[5]);
        }
        local L: long = 0;
        local data: *u8 = slurp(argv[ia], &L);
        if (data == nullptr) {
            return 1;
        }
        if (mode == 2 && (width <= 0 || L % (3 * width) != 0)) {
            printf("bad width\n");
            return 1;
        }
        if (video == 1 && (width > 65535 || fheight <= 0 || fheight > 65535 || L % (3 * width * fheight) != 0)) {
            printf("video: bad frame size\n");
            return 1;
        }
        if (video == 1) {
            width = width | (fheight << 16);
        }
        if (mode == 3 && (width <= 0 || width > 8 || L % (2 * width) != 0)) {
            printf("audio: need 1-8 channels and a whole number of 16-bit frames\n");
            return 1;
        }
        if (video == 1) {
            local ns: long = videoSegments(L, 3 * (width & 65535) * fheight);
            if (ns > 1) {
                return encVideoSegments(level, width, data, L, ns, threads, argv[ia + 1]);
            }
        }
        hugeArena(L, mode);
        local n: long = fm4Encode(level, mode, width, data, L);
        return spit(argv[ia + 1], fm4Result(), n);
    }
    if (argc == 4 && strcmp(argv[1], "dec") == 0) {
        local n: long = 0;
        local f: *u8 = slurp(argv[2], &n);
        if (f == nullptr) {
            return 1;
        }
        if (n >= 8 && f[0] == cast<u8>(70) && f[1] == cast<u8>(77) && f[2] == cast<u8>(86) && f[3] == cast<u8>(1)) {
            local d: *u8 = nullptr;
            local dl: long = decVideoSegments(f, n, threads, &d);
            if (dl < 0) {
                printf("not an FM4 file, or corrupt\n");
                return 1;
            }
            return spit(argv[3], d, dl);
        }
        if (n >= 28) {
            # original length (low 32 bits) and mode from the header
            local hl: long = cast<long>(f[16]) | (cast<long>(f[17]) << 8) | (cast<long>(f[18]) << 16) | (cast<long>(f[19]) << 24);
            hugeArena(hl, cast<int>(f[4]));
        }
        local L: long = fm4Decode(f, n);
        if (L < 0) {
            printf("not an FM4 file\n");
            return 1;
        }
        return spit(argv[3], fm4Result(), L);
    }
    printf("%s", USAGE);
    return 2;
}
