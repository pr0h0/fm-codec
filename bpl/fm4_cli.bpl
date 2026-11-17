# fm4 native CLI (BPL):  fm4 enc LEVEL bytes IN OUT | fm4 enc LEVEL image WIDTH IN OUT |
# fm4 enc LEVEL audio CHANNELS IN OUT | fm4 enc LEVEL video WIDTH HEIGHT IN OUT | fm4 dec IN OUT
import printf, malloc, strcmp, atoi from "std/c.bpl";
import fm4Encode, fm4Decode, fm4Result, fm4Estimate, fm4SetArena from "./fm4_core.bpl";

extern fopen(path: string, mode: string) ret *void;
extern fread(buffer: *void, size: long, count: long, stream: *void) ret long;
extern fwrite(buffer: *void, size: long, count: long, stream: *void) ret long;
extern fclose(stream: *void) ret int;
extern fseek(stream: *void, offset: long, whence: int) ret int;
extern ftell(stream: *void) ret long;
extern posix_memalign(out: **void, align: long, size: long) ret int;
extern madvise(p: *void, n: long, advice: int) ret int;
extern atoll(s: string) ret long;

global USAGE: string = "usage: fm4 enc LEVEL(0-5) bytes IN OUT | fm4 enc LEVEL image WIDTH IN OUT | fm4 enc LEVEL audio CHANNELS IN OUT | fm4 enc LEVEL video WIDTH HEIGHT IN OUT | fm4 dec IN OUT\n";

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
    local b: *u8 = cast<*u8>(malloc(n + 1));
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

frame main(argc: int, argv: *string) ret int {
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
