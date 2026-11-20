/* libFuzzer: c/fm4.c's decoder on hostile input. The harness repairs what would otherwise stop almost every
   mutation at the door (magic and version, bb in 12-14 so tables stay small, L < 1 KB, mostly an accepted
   feature set, the header CRC), so the fuzzer exercises the model and coder on garbage payloads and headers a forger could write.
   Build and run: make fuzz (tests/fuzz/run.sh). */
#define main fm4_cli_main
#include "../../c/fm4.c"
#undef main

int LLVMFuzzerTestOneInput(const uint8_t *d, size_t n) {
    if (n < HDR || n > 1 << 16) return 0;
    uint8_t *f = xmalloc(n);
    memcpy(f, d, n);
    memcpy(f, "FM4\x02", 4);
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
    int64_t L;
    uint8_t *o = fm4_decode(f, n, &L);
    if (o && crc32_of(o, L) == 0x9E3779B9u) fputc(0, stderr);   /* reads every output byte: MSan flags unwritten ones */
    free(o);
    free(f);
    return 0;
}
