# fm4

A lossless compressor built on context mixing: a learned model predicts every bit, and an
arithmetic coder turns those predictions into output. It has models for general data (text, code,
binaries), raw RGB images, 16-bit PCM audio and raw RGB video. It also has an archive mode for files and
directories.

There are three implementations that write byte-identical files: a C reference, a
[BPL](https://github.com/pr0h0/bpl3) port that builds natively, and the same port compiled to
WebAssembly for browsers and Node.

It compresses harder than xz, zstd and FLAC on the data it models, and it is much slower. See
[Results](#results) and [Caveats](#caveats) before you pick it for anything.

> **Status: pre-release.** The file format (format 1) may still change in ways that old builds can't
> read. Don't use fm4 for files you need to keep until there is a tagged release.

## Contents

- [Quick start](#quick-start)
- [Usage](#usage)
- [JavaScript and the browser](#javascript-and-the-browser)
- [Results](#results)
- [Caveats](#caveats)
- [How it works](#how-it-works)
- [Building and testing](#building-and-testing)
- [Repository layout](#repository-layout)

## Quick start

You need a C compiler (clang or gcc) and make.

```bash
make c                                   # builds c/fm4
c/fm4 enc 4 bytes notes.txt notes.fm4    # compress at level 4
c/fm4 dec notes.fm4 notes.txt.out        # decompress
cmp notes.txt notes.txt.out              # identical
```

## Usage

```
fm4 enc LEVEL bytes IN OUT                 any file
fm4 enc LEVEL image WIDTH IN OUT           raw RGB24 pixels, WIDTH pixels per row
fm4 enc LEVEL audio CHANNELS IN OUT        raw 16-bit little-endian PCM, 1-8 channels
fm4 enc LEVEL video WIDTH HEIGHT IN OUT    raw RGB24 frames
fm4 dec IN OUT                             decompress (mode and level are read from the file)
fm4 enc|dec -t N ...                       processes for large inputs (default: all cores)

fm4 a [-m auto|bytes] [-t N] LEVEL OUT PATH...   archive files and directories
fm4 x [-t N] ARCHIVE [DIR]                       extract
```

**Levels** run from 0 (store) to 5. Each level adds models: more contexts, a second match model,
indirect and sparse contexts, more mixers. Higher levels compress better and run slower. Level 4 is a
good default.

**Modes** must match the data. The image, audio and video modes expect raw samples, not PNG, WAV or MP4
files. Convert first, for example with ffmpeg:

```bash
ffmpeg -i photo.png -f rawvideo -pix_fmt rgb24 photo.rgb       # then: c/fm4 enc 4 image <width> photo.rgb photo.fm4
ffmpeg -i talk.wav -f s16le -acodec pcm_s16le talk.pcm         # then: c/fm4 enc 4 audio <channels> talk.pcm talk.fm4
ffmpeg -i clip.mp4 -f rawvideo -pix_fmt rgb24 clip.rgb         # then: c/fm4 enc 4 video <width> <height> clip.rgb clip.fm4
```

The decoder needs nothing but the file: `fm4 dec` restores the raw bytes. Wrapping them back into
PNG, WAV or MP4 is up to you.

**Archives** (`fm4 a`) compress all files as one solid stream, sorted by extension so similar files share
context. The PCM inside 16-bit WAV files goes through the audio model, and the pixels of 24-bit BMP and
PPM files through the image model; `-m bytes` turns that off. Already-compressed files (PNG, JPEG, MP4,
zip) are detected and stored. Permissions and empty directories are kept; symlinks and timestamps are not.

```bash
c/fm4 a 4 project.fma src/ docs/ README.md
c/fm4 x project.fma restored/
```

**Large inputs.** Inputs of 128 MB and more are cut into 64 MB segments, which are coded in parallel. This
costs 2-5% of size. Archives cut their solid data into parts of at least 8 MB. The output is the same
for any `-t`. The native builds memory-map their input and write output through temporary files, so
files larger than RAM work.

**Environment variables** (mostly for experiments):

| Variable | Effect |
|---|---|
| `SEG_MB` | segment size in MB (default 64) |
| `PART_MB` | archive part size in MB (default 8) |
| `FEAT`, `FEAT2`, `BB`, `LR` | override the model's feature bits, table size, mixer rate |
| `FM4_ANY_FEAT=1` | decode files made with `FEAT`/`FEAT2`/`LR` (trusted input only) |
| `HUGE=0` | don't use huge pages for the tables |

## JavaScript and the browser

`bpl/fm4.wasm` with `bpl/fm4wasm.mjs` and `bpl/fm4worker.mjs` runs in browsers, Node and Bun. Serve the
three files side by side. `fm4.wasm` comes from `make wasm` and needs the BPL compiler (see
[Building](#building-and-testing)).

```js
import { createFm4 } from "./bpl/fm4wasm.mjs";

const fm4 = await createFm4(new URL("./bpl/fm4.wasm", import.meta.url), { threads: 4 });

const packed = await fm4.encode(bytes, { level: 4 });                                  // bytes mode
const img = await fm4.encode(rgb, { level: 4, mode: "image", width: 1920 });
const pcm = await fm4.encode(samples, { level: 4, mode: "audio", channels: 2 });
const vid = await fm4.encode(frames, { level: 4, mode: "video", width: 640, height: 360 });

const original = await fm4.decode(packed);                                             // Uint8Array
```

- **Workers.** `createFm4` runs all coding in Web Workers (module workers: Chrome 91+, Firefox 114+,
  Safari 16.4+), so the page stays responsive. Large inputs are coded one segment per worker.
- **Memory.** Each worker needs about 300-800 MB of wasm memory, which is why the default is at most 4
  workers. Inputs under 64 KB need much less (2 KB: about 80 MB).
- **Speed.** Single streams run at about half the native speed.
- **Synchronous API.** `loadFm4Wasm(bytes)` is a synchronous single-instance API for Node, Bun or code
  already running inside a worker.

The wasm build reads and writes the same files as the native builds, segmented ones included. It can't
decode files from `BB=21`/`22` experiments, which need more than 2 GB.

## Results

Compressed size / original size, smaller is better. Native C build, one thread, Intel i7-6700. fm4's
encode and decode times are about equal.

| | Python source, 4 MB | x86-64 code, 4 MB | Photo-like image, 2048x1152 RGB | Speed, MB/s (source / image) | Memory, MB (source / image) |
|---|---:|---:|---:|---:|---:|
| fm4 level 1 | 0.130 | 0.330 | 0.389 | 2.7 / 2.4 | 60 / 24 |
| fm4 level 2 | 0.114 | 0.307 | 0.346 | 1.0 / 1.4 | 125 / 148 |
| fm4 level 3 | 0.102 | 0.290 | 0.341 | 0.67 / 0.92 | 315 / 180 |
| fm4 level 4 | 0.094 | 0.270 | 0.336 | 0.41 / 0.51 | 347 / 244 |
| fm4 level 5 | **0.092** | **0.265** | **0.332** | 0.27 / 0.40 | 619 / 244 |
| xz -9e | 0.134 | 0.363 | 0.665 | | |
| zstd -19 | 0.137 | 0.381 | 0.742 | | |
| gzip -9 | 0.198 | 0.479 | 0.803 | | |
| PNG (max compression) | | | 0.549 | | |
| JPEG XL lossless, effort 7 | | | 0.352 | | |

Raw numbers: [bench/results/fm4_levels.txt](bench/results/fm4_levels.txt).

**Audio** (12 clips of 20 s; speech, music, saxophone), level 4: 0.097-0.530 of raw, 6-45% smaller than
`flac -8` on every clip. The same clips in bytes mode, without the audio model, come out 5-60% larger
than FLAC.

**Video** (10 frames 640x360), level 4:

| Clip | fm4 | best other tool |
|---|---:|---:|
| screen recording | 0.0055 | xz -9e: 0.0071 |
| stick-figure animation | 0.0110 | xz -9e: 0.0204 |
| animated background | 0.0532 | xz -9e: 0.0942 |
| camera footage | 0.2066 | ffv1: 0.2408 |

The video model has no motion compensation, so camera footage gains little. Raw numbers:
[bench/results/media_fm4.txt](bench/results/media_fm4.txt).

**Archives.** A source tree with binaries (80 files, 4.18 MB) at level 4 came out at 276,794 bytes. For
comparison: `tar | xz -9e` 404,800, `zstd -19` 443,387, `zip -9` 935,388.

## Caveats

- **Slow.** About 0.3-2.7 MB/s per core depending on level (table above), against tens to hundreds of
  MB/s for zstd. Decoding is as slow as encoding: the decoder has to run the same model.
- **Memory.** 25-630 MB per process depending on level, and each parallel segment or archive part is
  its own process. Archives use about 350-420 MB per process.
- **Pre-release format.** Format 1 may still change in ways that old builds can't read.
- **Raw media only.** The image, audio and video modes take raw RGB24 or 16-bit PCM, and you have to give
  the width, channel count or frame size. fm4 doesn't parse PNG, WAV or video containers except inside
  archives (WAV, BMP, PPM).
- **No streaming.** fm4 works on whole files. It can't read stdin or write stdout, and it can't
  decompress part of a file.
- **Archives** don't keep symlinks or timestamps.
- **Platforms.** It is developed on Linux x86-64. macOS arm64 and Windows (MinGW-w64) build and pass
  the tests in CI, but get less use. On Windows, segments and archive parts are coded one after another
  instead of in parallel.
- **Not audited.** The decoders are fuzzed and reject corrupt input (see
  [docs/internals.md](docs/internals.md#integrity-and-hostile-input)), but nobody has reviewed them for
  security.

## How it works

1. Every byte is coded as 8 yes/no decisions. For each bit the **model** predicts the probability that
   it is 1.
2. The **arithmetic coder** keeps an interval inside [0, 1). It splits the interval in proportion to the
   prediction and keeps the part that matches the real bit. A well-predicted bit costs only a fraction of
   a bit of output.
3. The model looks at many **contexts**: the previous bytes, words, columns, matches with earlier data,
   or neighbouring pixels and their prediction errors. It keeps an adaptive probability for each, and
   small **mixers** (logistic regression, trained as it goes) combine them into one prediction.
4. The decoder runs the identical model on the bits decoded so far, so nothing about the model is
   stored in the file.

The whole file becomes one number in [0, 1), with as many digits as the model's predictions call for.
The project started as an attempt to encode files as plain fractions; [docs/history.md](docs/history.md)
tells how it got here.

More detail (the model, the file formats, integrity checks, large-data handling, determinism):
[docs/internals.md](docs/internals.md). The format spec is the comment at the top of
[`c/fm4.c`](c/fm4.c).

## Building and testing

```bash
make c                               # c/fm4 (C reference)
make bpl wasm BPL=/path/to/bpl       # bpl/fm4 (native) and bpl/fm4.wasm
make test                            # tests/run.sh
make sanitize                        # the tests on ASan+UBSan and MSan builds (clang)
make fuzz                            # libFuzzer harnesses, FUZZ_SECONDS each (default 60)
```

- **C.** `c/fm4.c` is one file with no dependencies beyond libc and libm. It builds on Linux, macOS and
  Windows (MinGW-w64, e.g. MSYS2 UCRT64: `make c/fm4 CC=gcc`). Keep `-ffp-contract=off` if you build by
  hand: identical output across builds depends on it.
- **BPL.** The BPL builds need the [bpl3](https://github.com/pr0h0/bpl3) compiler (staging 80d04313 or
  later), clang and wasm-ld.
- **Tests.** `tests/run.sh` round-trips every mode and level, checks that C, BPL native and wasm write
  identical files (testing whichever builds exist), covers archives, segments and corrupt input, and
  compares output hashes against `tests/expected.txt`. A change to those hashes is a format change.
  `UPDATE=1 tests/run.sh` rewrites the file.
- **Benchmarks.** `tools/make_testdata.sh` builds benchmark inputs from files on a Linux system into
  `testdata/` (not in git). `bench/archivers_bench.sh` and `bench/imgcodecs_bench.sh` run other tools
  on the same inputs.

## Repository layout

| Path | Contents |
|---|---|
| `c/fm4.c` | C reference implementation and format spec |
| `bpl/fm4_core.bpl` | BPL port: model and coder |
| `bpl/fm4_cli.bpl`, `bpl/fm4_wasm.bpl` | native command line and WebAssembly entry points |
| `bpl/fm4wasm.mjs`, `bpl/fm4worker.mjs` | JavaScript host and Web Worker for `fm4.wasm` |
| `tests/` | test suite, fuzzing harnesses, hostile inputs, locked output hashes |
| `bench/` | benchmark scripts, the browser check, recorded results |
| `tools/` | scripts that build benchmark inputs |
| `docs/` | internals and project history |
| `research/` | the original fraction-encoding idea and Python prototypes |

## License

[Apache License 2.0](LICENSE), the same as [bpl3](https://github.com/pr0h0/bpl3).
