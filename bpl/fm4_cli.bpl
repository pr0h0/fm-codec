# fm4 native CLI (BPL):  fm4 enc LEVEL bytes IN OUT | fm4 enc LEVEL image WIDTH IN OUT |
# fm4 enc LEVEL audio CHANNELS IN OUT | fm4 enc LEVEL video WIDTH HEIGHT IN OUT | fm4 dec IN OUT
# fm4 enc|dec -t N ...: processes for segmented video (same FMV format and cut as c/fm4.c).
import printf, malloc, strcmp, atoi, snprintf from "std/c.bpl";
import fm4Encode, fm4Decode, fm4Result, fm4Estimate, fm4EstimateDecode, fm4SetArena, xalloc, fm4StreamOk, fm4AllowAnyParams, fm4UseBuffer, fm4InputIsScratch, e8e9Detect from "./fm4_core.bpl";

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
extern open(path: string, flags: int, mode: int) ret int;
extern close(fd: int) ret int;
extern lseek(fd: int, off: long, whence: int) ret long;
extern ftruncate(fd: int, n: long) ret int;
extern mkstemp(template: string) ret int;
extern unlink(path: string) ret int;
extern rename(src: string, dst: string) ret int;
extern munmap(p: *void, n: long) ret int;
extern strrchr(s: string, c: int) ret string;
extern free(p: *void);
extern posix_fallocate(fd: int, off: long, n: long) ret int;
extern fchmod(fd: int, mode: int) ret int;
extern umask(mode: int) ret int;
extern signal(sig: int, handler: Func<void>(int)) ret Func<void>(int);
extern kill(pid: int, sig: int) ret int;
extern getpid() ret int;

global HDR_MAX: long = 36;   # 28-byte FM4 header + 8 (stream may exceed L by the header plus a little)
global USAGE: string = "usage: fm4 enc LEVEL(0-5) bytes IN OUT | fm4 enc LEVEL image WIDTH IN OUT | fm4 enc LEVEL audio CHANNELS IN OUT | fm4 enc LEVEL video WIDTH HEIGHT IN OUT | fm4 dec IN OUT | fm4 enc|dec -t N ...\n";

# Working memory for L input bytes on 2 MB huge pages where the system gives them (fewer TLB misses
# in the big hash tables; no effect on the output). On failure the codec allocates for itself.
frame hugeArena(L: long, mode: int) {
    hugeArenaN(fm4Estimate(L, mode));
}

frame hugeArenaN(n: long) {
    local p: *void = nullptr;
    if (posix_memalign(&p, 2097152, n) == 0) {
        madvise(p, n, 14);
        fm4SetArena(cast<*u8>(p), n);
    }
}

# ---- data larger than RAM (as in c/fm4.c): inputs are mapped (copy-on-write), decoded output goes straight
# into a mapping of OUT.partial (renamed on success), and buffers of BIG bytes or more live in unlinked
# temporary files in the output's directory, so the kernel can page them out instead of needing the memory.
global BIG: long = 67108864;   # env FM4_BIG (bytes) lowers it: tests run every path on small data
global SDIR: string = ".";

frame mapShared() ret int {
    return 1;   # MAP_SHARED (same on Linux and macOS)
}

frame mapAnonShared() ret int {
    return __TARGET_MACOS__ ? 4097 : 33;   # MAP_SHARED | MAP_ANONYMOUS
}

# Gives the file n bytes of disk blocks now: a mapped page that cannot be written back later (disk full) would
# kill the process with SIGBUS, so a full disk must fail here (as reserve() in c/fm4.c). macOS: ftruncate only.
frame reserve(fd: int, n: long) ret bool {
    if (__TARGET_LINUX__) {
        return posix_fallocate(fd, 0, n) == 0;
    }
    return ftruncate(fd, n) == 0;
}

frame mapped(p: *void) ret *u8 {
    return (cast<long>(p) == -1) ? cast<*u8>(nullptr) : cast<*u8>(p);
}

# the directory of the output file path (temporary files go there, not to a possibly memory-backed /tmp)
frame scratchDirFor(path: string) {
    local d: string = cast<string>(xalloc(4200));
    snprintf(d, 4200, "%s", path);
    local sl: string = strrchr(d, 47);
    if (sl == nullptr) {
        snprintf(d, 4200, ".");
    } else if (cast<long>(sl) == cast<long>(d)) {
        snprintf(d, 4200, "/");
    } else {
        cast<*u8>(sl)[0] = cast<u8>(0);
    }
    SDIR = d;
}

# n bytes in an unlinked temporary file, shared with forked processes; nullptr on failure
frame mapTemp(n: long) ret *u8 {
    local t: string = cast<string>(xalloc(4200));
    snprintf(t, 4200, "%s/.fm4-XXXXXX", SDIR);
    local fd: int = mkstemp(t);
    if (fd < 0) {
        return nullptr;
    }
    unlink(t);
    local p: *u8 = nullptr;
    if (reserve(fd, n)) {
        p = mapped(mmap(nullptr, n, 3, mapShared(), fd, 0));
    }
    close(fd);
    return p;
}


# the whole file, writable (changes stay in memory); files of 1 MB (or BIG) and more are mapped, not read
frame mapIn(path: string, outLen: *long) ret *u8 {
    local fd: int = open(path, 0, 0);
    if (fd < 0) {
        printf("cannot open %s\n", path);
        return nullptr;
    }
    local n: long = lseek(fd, 0, 2);
    if (n > 0 && n >= ((BIG < 1048576) ? BIG : 1048576)) {
        local p: *u8 = mapped(mmap(nullptr, n, 3, 2, fd, 0));   # MAP_PRIVATE
        close(fd);
        if (p != nullptr) {
            *outLen = n;
            return p;
        }
    } else {
        close(fd);
    }
    return slurp(path, outLen);
}

# Output written in place: mapOut gives a mapping of a new temporary file next to path (mkstemp: no existing file
# is touched) with its space reserved; finishOut renames it to path, or removes it on failure. Only for format-2
# lengths, which are bounded by the input (see Out in c/fm4.c); format 1 decodes into memory.
global OUT_TMP: string = "";
global PENDING: bool = false;   # OUT_TMP exists and an interrupted run removes it (its full size is reserved)
global IO_ERR: bool = false;   # an I/O error was already reported (not a corrupt file)

# An interrupted decode removes its temporary output, then dies of the signal (the shell sees a signal death).
# Ignored signals (nohup, background jobs) stay ignored; the earlier handlers come back afterwards (as c/fm4.c).
global OLD_SIG: **void = nullptr;

frame sigAction(v: long) ret Func<void>(int) {
    return cast<Func<void>(int)>(cast<*void>(v));   # SIG_DFL = 0, SIG_IGN = 1
}

frame onSignal(sig: int) {
    if (PENDING) {
        unlink(OUT_TMP);
    }
    signal(sig, sigAction(0));
    kill(getpid(), sig);
}

frame cleanSig(i: int) ret int {
    return (i == 0) ? 2 : ((i == 1) ? 15 : 1);   # SIGINT, SIGTERM, SIGHUP
}

frame catchSignals() {
    OLD_SIG = cast<**void>(xalloc(3 * 8));
    loop (local i: int = 0; i < 3; i = i + 1) {
        local old: Func<void>(int) = signal(cleanSig(i), onSignal);
        OLD_SIG[i] = cast<*void>(old);
        if (cast<long>(OLD_SIG[i]) == 1) {
            signal(cleanSig(i), old);   # was ignored: stays ignored
        }
    }
}

frame releaseSignals() {
    if (OLD_SIG != nullptr) {
        loop (local i: int = 0; i < 3; i = i + 1) {
            signal(cleanSig(i), cast<Func<void>(int)>(OLD_SIG[i]));
        }
        OLD_SIG = nullptr;
    }
    PENDING = false;
}

frame mapOut(path: string, n: long) ret *u8 {
    OUT_TMP = cast<string>(xalloc(4200));
    snprintf(OUT_TMP, 4200, "%s.fm4-XXXXXX", path);   # recognisable if a crash leaves it
    local fd: int = mkstemp(OUT_TMP);
    if (fd < 0) {
        printf("cannot write %s\n", path);
        IO_ERR = true;
        return nullptr;
    }
    PENDING = true;
    catchSignals();
    local um: int = umask(0);
    umask(um);
    fchmod(fd, 438 & ~um);   # 0666 minus umask, what fopen gives
    local p: *u8 = nullptr;
    if (n == 0) {
        p = xalloc(1);
    } else if (reserve(fd, n)) {
        p = mapped(mmap(nullptr, n, 3, mapShared(), fd, 0));
    }
    close(fd);
    if (p == nullptr) {
        printf("cannot write %s (disk full?)\n", path);
        unlink(OUT_TMP);
        releaseSignals();
        IO_ERR = true;
    }
    return p;
}

frame finishOut(path: string, p: *u8, n: long, ok: bool) ret int {
    local good: bool = ok;
    if (n == 0) {
        free(cast<*void>(p));
    } else if (munmap(cast<*void>(p), n) != 0) {
        good = false;
    }
    if (!good) {
        unlink(OUT_TMP);
        releaseSignals();
        return 1;
    }
    if (rename(OUT_TMP, path) != 0) {
        printf("cannot write %s\n", path);
        unlink(OUT_TMP);
        releaseSignals();
        IO_ERR = true;
        return 1;
    }
    releaseSignals();   # only now: a signal before the rename still removes the temporary file
    return 0;
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
    local w: long = fwrite(cast<*void>(b), 1, n, f);
    if (fclose(f) != 0 || w != n) {
        printf("cannot write %s\n", path);
        return 1;
    }
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

# memory forked children write their results into: a temporary file when large, else anonymous shared
frame shared(n: long) ret *u8 {
    if (n >= BIG) {
        local t: *u8 = mapTemp(n);
        if (t != nullptr) {
            return t;
        }
    }
    return sharedAnon(n);
}

frame sharedAnon(n: long) ret *u8 {
    return mapped(mmap(nullptr, n, 3, mapAnonShared(), -1, 0));
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
                    hugeArenaN(fm4EstimateDecode(Ls[j], cast<int>(ins[j][4]), cast<int>(ins[j][5])));
                    fm4UseBuffer(outs[j], Ls[j]);   # decode straight into this segment's part of the output (as C)
                    local m: long = fm4Decode(ins[j], ns[j]);
                    if (m != Ls[j]) {
                        _exit(1);
                    }
                    if (fm4Result() != outs[j]) {
                        memcpy(cast<*void>(outs[j]), cast<*void>(fm4Result()), m);
                    }
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

# Decodes straight into the file out. Returns 0, or 1 for a corrupt file.
frame decVideoSegments(f: *u8, n: long, threads: long, out: string) ret int {
    local ns: long = get64(&f[4]) & 4294967295;
    if (ns > (n - 8) / 36) {   # each segment takes at least 8 + 28 bytes
        return 1;
    }
    local ins: **u8 = cast<**u8>(xalloc(ns * 8 + 8));
    local Ms: *long = cast<*long>(xalloc(ns * 8 + 8));
    local Ls: *long = cast<*long>(xalloc(ns * 8 + 8));
    local outs: **u8 = cast<**u8>(xalloc(ns * 8 + 8));
    local all: long = 0;
    local pos: long = 8;
    local v2: bool = true;
    loop (local k: long = 0; k < ns; k = k + 1) {
        if (n - pos < 36) {
            return 1;
        }
        local m: long = get64(&f[pos]);
        local sl: long = get64(&f[pos + 24]);
        if (m < 28 || m > n - pos - 8 || !fm4StreamOk(&f[pos + 8], m, sl)) {
            return 1;
        }
        ins[k] = &f[pos + 8];
        v2 = v2 && f[pos + 11] == cast<u8>(2);
        Ms[k] = m;
        Ls[k] = sl;
        all = all + sl;
        pos = pos + 8 + m;
    }
    if (pos != n) {
        return 1;
    }
    # format 2: straight into the output file; format 1 (lengths with no bound): memory, written at the end
    local d: *u8 = v2 ? mapOut(out, all) : sharedAnon((all > 0) ? all : 1);
    if (d == nullptr) {
        return 1;
    }
    local o: long = 0;
    loop (local k2: long = 0; k2 < ns; k2 = k2 + 1) {
        outs[k2] = &d[o];
        o = o + Ls[k2];
    }
    local ok: bool = runJobs(ns, threads, true, 0, 0, 0, ins, Ms, Ls, outs) == 0;
    if (!v2) {
        if (!ok) {
            return 1;
        }
        if (spit(out, d, all) != 0) {
            IO_ERR = true;
            return 1;
        }
        return 0;
    }
    return finishOut(out, d, all, ok);
}

frame main(argc: int, argv: *string) ret int {
    if (getenv("FM4_ANY_FEAT") != nullptr) {
        fm4AllowAnyParams();   # decode files from FEAT/FEAT2/LR experiments (trusted input only)
    }
    if (getenv("FM4_BIG") != nullptr) {
        BIG = atoll(getenv("FM4_BIG"));
        if (BIG < 1) {
            BIG = 1;
        }
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
        local data: *u8 = mapIn(argv[ia], &L);
        scratchDirFor(argv[ia + 1]);
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
        if (mode == 1 && L >= BIG && level >= 1 && e8e9Detect(data, L)) {
            # the E8/E9 pass rewrites nearly every page: on a mapped input those would become anonymous memory,
            # so the encoder gets a file-backed copy (as in c/fm4.c)
            local cp: *u8 = mapTemp(L);
            if (cp != nullptr) {
                memcpy(cast<*void>(cp), cast<*void>(data), L);
                data = cp;
                fm4InputIsScratch();   # no need to undo the transform on the copy afterwards
            }
        }
        if (L + 36 >= BIG) {
            local eb: *u8 = mapTemp(L + 36);   # the result (at most L + 36 bytes) in a temporary file
            if (eb != nullptr) {
                fm4UseBuffer(eb, L + 36);
            }
        }
        local n: long = fm4Encode(level, mode, width, data, L);
        return spit(argv[ia + 1], fm4Result(), n);
    }
    if (argc == 4 && strcmp(argv[1], "dec") == 0) {
        local n: long = 0;
        local f: *u8 = mapIn(argv[2], &n);
        if (f == nullptr) {
            return 1;
        }
        scratchDirFor(argv[3]);
        if (n >= 8 && f[0] == cast<u8>(70) && f[1] == cast<u8>(77) && f[2] == cast<u8>(86) && f[3] == cast<u8>(1)) {
            if (decVideoSegments(f, n, threads, argv[3]) != 0) {
                if (!IO_ERR) {
                    printf("not an FM4 file, or corrupt\n");
                }
                return 1;
            }
            return 0;
        }
        if (n >= 28) {
            # original length (low 32 bits), mode and table bits from the header
            local hl: long = cast<long>(f[16]) | (cast<long>(f[17]) << 8) | (cast<long>(f[18]) << 16) | (cast<long>(f[19]) << 24);
            hugeArenaN(fm4EstimateDecode(hl, cast<int>(f[4]), cast<int>(f[5])));
        }
        # a header that passes the checks gets its output written in place, into the output file
        local out: *u8 = nullptr;
        local hL: long = (n >= 28) ? get64(&f[16]) : -1;
        if (n >= 36 && f[0] == cast<u8>(70) && f[1] == cast<u8>(77) && f[2] == cast<u8>(52) && f[3] == cast<u8>(2) && fm4StreamOk(f, n, hL)) {
            out = mapOut(argv[3], hL);
            if (out == nullptr) {
                return 1;
            }
            fm4UseBuffer(out, hL);
        }
        local L: long = fm4Decode(f, n);
        if (out != nullptr) {
            if (finishOut(argv[3], out, hL, L == hL) != 0) {
                if (!IO_ERR) {
                    printf("not an FM4 file\n");
                }
                return 1;
            }
            return 0;
        }
        if (L < 0) {
            printf("not an FM4 file\n");
            return 1;
        }
        return spit(argv[3], fm4Result(), L);
    }
    printf("%s", USAGE);
    return 2;
}
