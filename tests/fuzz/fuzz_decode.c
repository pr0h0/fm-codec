/* libFuzzer: c/fm4.c's decoder on hostile input, as single FM4 streams and as segmented files (FMS, when the
   input starts with "FMS"). The harness repairs what would otherwise stop almost every mutation at the door
   (magic and version, bb in 12-14 so tables stay small, L < 1 KB, mostly an accepted feature set, the header
   CRC; in a segmented file, every stream header that fits), so the fuzzer exercises the segment table, the model
   and the coder on garbage payloads and headers a forger could write. The segment lengths and count are left as
   the fuzzer wrote them. NO_FORK: segments decode one after another, as on Windows.
   Build and run: make fuzz (tests/fuzz/run.sh). */
#define NO_FORK 1   /* in-process: no fork() under libFuzzer, and out_open must not mkstemp next to /dev/null */
#define main fm4_cli_main
#include "../../c/fm4.c"
#undef main

static void repair(uint8_t *f) {   /* the HDR bytes of one stream header */
    memcpy(f, "FM4\x01", 4);
    f[5] = BB_MIN + f[5] % 3;
    if (f[9] & 1) {   /* mostly a feature set the decoder accepts (else the raw bits test the rejection) */
        int mode = f[4] & 3, level = 1 + f[8] % 5;
        uint32_t feat = LEVEL_FEAT(mode, level), feat2 = LEVEL_FEAT2(mode, level);
        if (mode == 1 && (f[9] & 2)) feat |= 64;
        if (mode == 2 && level >= 2 && (f[9] & 2)) { feat2 |= 256; f[14] |= 1; }
        f[4] = mode; f[6] = 255; f[7] = 1 + f[7] % 15;
        put32(f + 8, feat); put32(f + 24, feat2);
    }
    put64(f + 16, get64(f + 16) & 0x3FF);
    put32(f + 32, crc32_of(f, 32));
}

int LLVMFuzzerTestOneInput(const uint8_t *d, size_t n) {
    if (n < HDR || n > 1 << 16) return 0;
    uint8_t *f = xmalloc(n);
    memcpy(f, d, n);
    if (!memcmp(f, "FMS", 3)) {
        f[3] = 1;
        for (int64_t pos = 8, k = 0; k < get32(f + 4) && (int64_t)n - pos >= 8 + HDR; k++) {
            repair(f + pos + 8);
            uint64_t m = get64(f + pos);   /* unsigned: a length >= 2^63 must stop here too */
            if (m > (uint64_t)n - pos - 8) break;
            pos += 8 + m;
        }
        static Out o; memset(&o, 0, sizeof o); o.path = "/dev/null";   /* spit() writes it: MSan checks the bytes */
        dec_segments(f, n, 1, &o);
    } else {
        repair(f);
        int64_t L;
        uint8_t *o = fm4_decode(f, n, &L);
        if (o && crc32_of(o, L) == 0x9E3779B9u) fputc(0, stderr);   /* reads every output byte: MSan flags unwritten ones */
        free(o);
    }
    free(f);
    return 0;
}
