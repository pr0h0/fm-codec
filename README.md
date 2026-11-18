# fm-codec — model-fraction compression

Lossless compression that represents a whole file as **one number**: the data is the fraction
`N / 256^k`, and a learned probability model decides how that number is read back.

Started as an experiment to encode data as a fraction `N/D` whose decimal expansion begins with the data
([research/IDEA.md](research/IDEA.md)). A plain fraction can never be shorter than the data (measured:
always 1.00×). Letting a predictive model choose the interval widths turns it into context-mixing
arithmetic coding, which does compress, and that is what this repository implements and benchmarks.

## How it works

1. Every byte is coded as 8 yes/no decisions. For each bit a **model** predicts `P(bit = 1)`.
2. The **coder** keeps an interval `[low, high)` inside `[0, 1)`, splits it in proportion to that
   probability and keeps the half matching the real bit. After the last bit the interval width equals the
   probability of the whole file, so the number needs about `log2(1/P(data))` bits.
3. The **model** looks at contexts (previous bytes, or neighbouring pixels and their prediction errors),
   keeps an adaptive probability per context, and a learned **mixer** combines them. Encoder and decoder
   run the identical model, so nothing about the model is stored.
4. Everything is integer arithmetic with a fixed spec, so every implementation produces
   **byte-identical** files.

Image mode (raw RGB24) codes the error of a blended pixel predictor (MED, gradient, cross-channel, …)
with neighbour-error contexts. It is lossless.

## Implementations

| Path | What |
|---|---|
| `c/fm4.c` | current format (FM4, levels 0–5; bytes, image, audio, video): C reference and spec |
| `bpl/fm4_core.bpl`, `bpl/fm4_cli.bpl`, `bpl/fm4_wasm.bpl`, `bpl/fm4wasm.mjs` | FM4 in BPL: core, native CLI, WebAssembly entry, JS host |
| `c/fm3.c` | previous format (FM3, levels 0–5): C reference and spec |
| `bpl/fm3_core.bpl`, `bpl/fm3_cli.bpl`, `bpl/fm3_wasm.bpl` | FM3 in BPL: shared core, native CLI, WebAssembly entry |
| `bpl/fm3wasm.mjs` | JS host for `bpl/fm3.wasm` (browser / Node / Bun), same API as `js/fm3core.mjs` |
| `js/fm3core.mjs`, `js/fm3.mjs` | FM3 pure JS port (browser-safe core + CLI) |
| `c/fm2.c` | reference implementation and spec of FM2 (levels 0–5) |
| `bpl/fm2_core.bpl` | [BPL](https://github.com/pr0h0/bpl3) core, shared by native CLI and WebAssembly |
| `bpl/fm2_cli.bpl`, `bpl/fm2_wasm.bpl` | native CLI entry and wasm entry |
| `bpl/fm2wasm.mjs` | JS host for the BPL-built `fm2.wasm` (browser / Node / Bun) |
| `js/fm2core.mjs`, `js/fm2.mjs` | pure JS port (browser-safe core + CLI) |
| `c/fm.c`, `js/fm.mjs`, `bpl/fm.bpl` | v1 format (FRC1) |
| `c/fmx.c` | image-model experiments (feature flags) |
| `research/` | Python prototypes: plain fraction search, first model-fraction coder, benchmarks |

```bash
make c                      # C reference (fm3, fm2, ...)
c/fm3 enc 4 bytes in.txt out.fm3          # fm3, level 0..5
make bpl wasm bpl3 wasm3 BPL=~/Projects/bpl3/bpl
c/fm2 enc 4 bytes in.txt out.fm2          # level 0..5
c/fm2 enc 4 image 2048 in.rgb out.fm2     # raw RGB24, width 2048
c/fm2 dec out.fm2 restored
```

JS / browser:

```js
import { encode, decode } from "./js/fm2core.mjs";            // pure JS
import { loadFm2Wasm } from "./bpl/fm2wasm.mjs";              // BPL -> wasm, same API
const fm2 = await loadFm2Wasm(await fetch("bpl/fm2.wasm"));
const packed = fm2.encode(bytes, { level: 4, mode: "image", width: 2048 });
```

## fm4 (current: `c/fm4.c`, `bpl/fm4_*.bpl`)

fm4 adds to fm3: an online least-squares (OLS) pixel predictor, a 2-D match model and exact-colour
contexts for images; four text contexts, a fourth mixer, mixer selection by context hit count and
(level 5) per-context run inputs for text; a 16-bit mixer; and two new modes, **audio** (16-bit PCM)
and **video** (raw RGB frames, uses the previous frame).

```bash
make c bpl4 wasm4 BPL=~/Projects/bpl3/bpl     # BPL needs bpl3 staging 80d04313 or later
c/fm4 enc 4 bytes in.txt out.fm4              # levels 0..5
c/fm4 enc 4 image 2048 in.rgb out.fm4         # raw RGB24, width
c/fm4 enc 4 audio 2 in.pcm out.fm4            # raw 16-bit little-endian PCM, channels
c/fm4 enc 4 video 640 360 in.rgb out.fm4      # raw RGB24 frames, width height
c/fm4 dec out.fm4 restored
c/fm4 a 4 out.fma dir file ...                # archive files and directories (C only)
c/fm4 a -m bytes 4 out.fma dir                # same, without the audio/image models
c/fm4 a -t 1 4 out.fma dir                    # one process, smallest output (default: all cores)
c/fm4 x out.fma destdir                       # extract (also parallel)
```

**Archives** (`FMA`, format described above `archive()` in `c/fm4.c`): all files are sorted by extension
and compressed as one stream, so small similar files share context. The PCM data of 16-bit WAV files
goes through the audio model and the pixels of 24-bit BMP (width a multiple of 4) and PPM files through
the image model, each as its own stream; `-m bytes` turns that off. Files that look already compressed
(byte entropy above 7.8 bits: PNG, JPEG, MP4, zip) are stored. Permissions and empty directories are
kept; symlinks and timestamps are not. Streams are coded in parallel (one process each, about 350–420 MB
of memory per process); solid data over 16 MB is cut into parts of at least 8 MB, at most one per
process, which costs some size: a 32 MB tar with `-t 1` 4,369,452 bytes in 106 s, in 3 parts 4,516,281
(+3.4%) in 39 s (`xz -9e` 5,839,928). A source tree with binaries (80 files, 4.18 MB): level 4
276,794 bytes in 13.7 s, level 2 411,136 in 3.8 s; `tar | xz -9e` 404,800, `zstd -19` 443,387,
`zip -9` 935,388. `-m bytes` is not a speed-up at the same level (a WAV at level 4: 1.9 s and 69 KB
with the audio model, 2.3 s and 167 KB without); use a lower level for speed.

Measured on a corpus built from a source tree (`tools/make_corpus.sh`: 10 text types, 20 images) plus
the earlier test files, fm4 vs fm3 at level 4: text and code -1.9% mean (level 5: -3.3%), images
-15.2% mean (up to -36% on screenshots); every file is smaller.

| Media (level 4, compressed / raw) | fm4 | best other tool |
|---|---:|---:|
| Audio, 12 clips of 20 s (speech, music, sax) | 0.097 - 0.530 | flac -8: 0.137 - 0.601 (fm4 is 6-45% smaller on every clip) |
| Video, 10 frames 640x360: screen recording | 0.0055 | lossless x264: 0.0091 |
| Video: stick-figure animation | 0.0110 | xz: 0.0204, x264: 0.0224 |
| Video: animated background | 0.0532 | xz: 0.0942, ffv1: 0.1182 |
| Video: camera footage | 0.2066 | ffv1: 0.2408 |

Without the audio model (bytes mode) the same audio clips come out 5-60% larger than FLAC. The video
mode has no motion compensation, so camera footage gains little over coding the frames as one image.
Raw numbers: `bench/results/media_fm4.txt`.

The BPL build produces byte-identical files (native and WebAssembly) and is 1.02-1.12x the time of the
C build (clang; text 2.56 s vs 2.60 s per MB at level 4, video 2.72 s vs 3.05 s); the wasm build runs the model in 16 KB chunks so browsers switch to optimized code.
`bench/results/fm4_c_vs_bpl.txt`, `fm4_bpl_opt.txt`. There is no JS port of fm4 yet (fm3 has one).

fm4 is slow: about 0.3 MB/s for text and images at level 4, 0.2-0.4 MB/s for audio.
The OLS predictor uses floating point; identical output across builds relies on IEEE doubles without
fused multiply-add (`-ffp-contract=off` in the Makefile).

## fm3 (previous format, C reference: `c/fm3.c`)

fm3 replaces fm2's per-bit hash slots with checksummed 64-byte nibble buckets (one cache line per
context per 4 bits), and adds: two match models, word / word-pair / column contexts, indirect
contexts, sparse contexts and an x86 E8/E9 transform for binaries, 7-bit history per context mapped
through adaptive tables, a 3-mixer network with a learned final mixer, and three APM stages.
Image mode blends 9 predictors weighted by recent local error (1/err), with 16 contexts.

| Level | bytes | image |
|---|---|---|
| 0 | store | store |
| 1 | orders 1–3 + match model | MED predictor, 6 contexts |
| 2 | orders 0–4,6, match, words, 2 mixers + APM | 9-predictor blend, 12 contexts |
| 3 | + 2nd match, indirect, sparse, column, more APMs | + 2 mixers + APM |
| 4 | + bit-history inputs, orders 5/7, 3-mixer network | + 4 contexts, 3-mixer network |
| 5 | level 4 with 2x tables | level 4, two blend weightings tried |

Incompressible input falls back to store. x86 code is detected and E8/E9-transformed automatically.

### Results (ratio = output / input, smaller is better)

| Data | fm3 L1 | fm3 L2 | fm3 L4 | fm3 L5 | fm2 L4 | xz -9e | 7z PPMd | zpaq -m5 | JPEG XL e9 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 10 MB source code | 0.160 | 0.141 | 0.119 | **0.118** | 0.184 | 0.162 | 0.146 | 0.122 | — |
| 3.3 MB English prose | 0.197 | 0.173 | 0.158 | **0.157** | 0.215 | 0.208 | 0.180 | 0.160 | — |
| 10 MB x86-64 binary | 0.316 | 0.295 | 0.261 | **0.259** | 0.375 | 0.340 | 0.326 | 0.281 | — |
| 7 MB photo-like image (raw RGB) | 0.390 | 0.347 | **0.341** | 0.341 | 0.349 | 0.665 | 0.651 | 0.501 | 0.347 |
| 0.4 MB busy illustration | 0.547 | 0.501 | 0.494 | **0.493** | 0.4995 | 0.647 | 0.672 | 0.571 | 0.501 |
| 0.3 MB character image | 0.234 | 0.208 | **0.205** | 0.205 | 0.209 | 0.315 | 0.281 | 0.237 | 0.212 |

All FM3 implementations (C, BPL native, BPL→wasm, JS) produce byte-identical files.

Speed by implementation (text 10 MB / 7 MB image, level 4, encode): C 26 s / 11 s, BPL native
(`--march native`) 31–34 s / 14 s (BPL keeps bounds/null/stack checks it cannot turn off, which cost
15–25% once the code is compute-bound). In the browser (Chromium 156) BPL→wasm and the JS port run at
about the same speed (JS ~25% faster on the large image at L4); in Bun the wasm build avoids JS JIT
stalls. Raw numbers: `bench/results/fm3_c_vs_bpl.txt`, `bench_wasm3_*.txt`, `bench_browser3_chromium.txt`.

Speed (C, single thread, i7-6700, MB/s encode; decode is the same):
L1 2.2 (text) / 1.9 (image), L2 1.0 / 1.0, L3 0.6 / 0.8, L4 0.36 / 0.6. Peak memory: L1 12–67 MB,
L2 ~130 MB, L3/L4 ~250–290 MB, L5 ~500 MB. Full numbers: `bench/results/fm3_levels_c.txt`.

## FM2 (previous format; C, BPL native + wasm, JS)

| Level | bytes mode | image mode |
|---|---|---|
| 0 | store | store |
| 1 | order-2 context, no mixer (fastest) | MED predictor, 3 contexts |
| 2 | orders 1–3 mixed | MED, 6 contexts |
| 3 | orders 0–4,6 mixed (= v1 model) | 5-predictor blend, 9 contexts |
| 4 | + second mixer + APM | 9-predictor blend, 12 contexts, second mixer, APM |
| 5 | 3 passes, smallest wins | same as 4 |

### FM2 results

Ratio = output / input (smaller is better). Speeds are single-threaded encode, C build.

| Data | fm2 L1 | fm2 L4 | fm2 L5 | gzip -9 | xz -9e | 7z PPMd | zpaq -m5 | JPEG XL e9 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 10 MB source code | 0.280 | 0.184 | 0.178 | 0.225 | 0.162 | 0.146 | 0.122 | — |
| 7 MB photo-like image (raw RGB) | 0.392 | 0.349 | 0.349 | 0.803 | 0.665 | 0.651 | 0.501 | 0.347 |
| 0.3 MB character image | 0.241 | 0.209 | 0.209 | 0.387 | 0.315 | 0.281 | 0.237 | 0.212 |
| 0.4 MB busy illustration | 0.553 | 0.4995 | 0.4995 | 0.730 | 0.647 | 0.672 | 0.571 | 0.501 |

Speed (MB/s, encode; decode is the same): C L1 7.3 (text) / 2.1 (image), L4 0.65 / 0.31.
BPL native is within ±7% of C at levels 2–4 (23% slower at level 1), BPL→wasm runs at ~60–75% of native
and is 1.1–1.5× faster than the pure JS port in Node and Chromium. Raw numbers: [bench/results](bench/results).

## Benchmarks

```bash
tools/make_testdata.sh            # testdata/ from system files; put your own images in testdata/images/
bench/bench.sh                    # v1 ports
bench/archivers_bench.sh FILE...  # gzip, zip, bzip2, xz, zstd, 7z, rar, zpaq (whatever is installed)
bench/imgcodecs_bench.sh IMG...   # PNG, QOI, JPEG-LS, JPEG 2000, FFV1, WebP, JPEG XL, AV1 (ffmpeg)
node bench/bench_wasm.mjs         # JS port vs BPL wasm (also with bun)
```
