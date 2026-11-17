# fm4 native CLI (BPL):  fm4 enc LEVEL bytes IN OUT | fm4 enc LEVEL image WIDTH IN OUT | fm4 dec IN OUT
import printf, malloc, strcmp, atoi from "std/c.bpl";
import fm4Encode, fm4Decode, fm4Result from "./fm4_core.bpl";

extern fopen(path: string, mode: string) ret *void;
extern fread(buffer: *void, size: long, count: long, stream: *void) ret long;
extern fwrite(buffer: *void, size: long, count: long, stream: *void) ret long;
extern fclose(stream: *void) ret int;
extern fseek(stream: *void, offset: long, whence: int) ret int;
extern ftell(stream: *void) ret long;

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
        local mode: int = (strcmp(argv[3], "image") == 0) ? 2 : 1;
        local width: long = 0;
        local ia: int = 4;
        if (mode == 2) {
            if (argc < 7) {
                printf("usage: fm4 enc LEVEL image WIDTH IN OUT\n");
                return 2;
            }
            width = cast<long>(atoi(argv[4]));
            ia = 5;
        }
        if (level < 0 || level > 5) {
            printf("level must be 0-5\n");
            return 2;
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
        local n: long = fm4Encode(level, mode, width, data, L);
        return spit(argv[ia + 1], fm4Result(), n);
    }
    if (argc == 4 && strcmp(argv[1], "dec") == 0) {
        local n: long = 0;
        local f: *u8 = slurp(argv[2], &n);
        if (f == nullptr) {
            return 1;
        }
        local L: long = fm4Decode(f, n);
        if (L < 0) {
            printf("not an FM4 file\n");
            return 1;
        }
        return spit(argv[3], fm4Result(), L);
    }
    printf("usage: fm4 enc LEVEL(0-5) bytes IN OUT | fm4 enc LEVEL image WIDTH IN OUT | fm4 dec IN OUT\n");
    return 2;
}
