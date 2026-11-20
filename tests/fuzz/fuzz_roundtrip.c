/* libFuzzer: every input must encode and decode back exactly, in every mode and level. The first bytes
   choose level, mode and shape (always valid: the CLI rejects the rest); the remainder is the data.
   Tables use BB=12 so each run stays fast; the model logic is the same at every table size. */
#define NO_FORK 1   /* in-process: no fork() under libFuzzer, and out_open must not mkstemp next to /dev/null */
#define main fm4_cli_main
#include "../../c/fm4.c"
#undef main

int LLVMFuzzerInitialize(int *argc, char ***argv) { (void)argc; (void)argv; setenv("BB", "12", 1); return 0; }

int LLVMFuzzerTestOneInput(const uint8_t *d, size_t n) {
    if (n < 4 || n > 1028) return 0;
    int level = d[0] % 6, mode = 1 + d[1] % 3, video = mode == 2 && (d[1] & 4);
    int64_t w = 0, L = n - 4;
    if (mode == 2) {
        int64_t fw = 1 + d[2] % 32, fh = 1 + d[3] % 16, unit = 3 * fw * (video ? fh : 1);
        L -= L % unit;
        w = video ? fw | fh << 16 : fw;
    } else if (mode == 3) {
        w = 1 + d[2] % 8;
        L -= L % (2 * w);
    }
    uint8_t *data = xmalloc(L ? L : 1), *ref = xmalloc(L ? L : 1);
    memcpy(data, d + 4, L); memcpy(ref, d + 4, L);
    int64_t m, L2;
    uint8_t *enc = fm4_encode(level, mode, w, data, L, &m);
    if (memcmp(data, ref, L)) abort();   /* the encoder must leave its input as it found it */
    uint8_t *dec = fm4_decode(enc, m, &L2);
    if (!dec || L2 != L || memcmp(dec, ref, L)) abort();
    free(dec); scratch_free(enc, ENC_CAP(L)); free(data); free(ref);
    return 0;
}
