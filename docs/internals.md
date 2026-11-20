# fm4 internals

How the codec works in more depth than the README: the model, the file formats, large inputs, integrity
and the things that keep three implementations byte-identical. The authoritative spec is the comment
block at the top of [`c/fm4.c`](../c/fm4.c); this page explains it.

## The coder and the model

Every byte is coded as 8 binary decisions. For each bit a model predicts `P(bit = 1)`, and a 32-bit binary
arithmetic coder (12-bit probabilities) narrows an interval in proportion to that probability. After the last bit the interval's
width is the probability the model gave the whole file, so the output takes about `log2(1 / P(data))` bits.
The decoder runs the same model on the bits it has decoded so far, so it gets the same predictions and
nothing about the model is stored. That is also why decoding costs as much as encoding.

The model (per mode, more of it at higher levels):

- **Context tables.** Each context (the previous bytes, a word, a column, a hashed pixel neighbourhood, …)
  owns 64-byte buckets, one cache line per context per 4 bits, with a 16-bit checksum. Each slot holds an
  adaptive probability, a confidence count and a short history of the bits seen in that context; the
  history goes through a second adaptive table.
- **Match models.** They look up the longest earlier occurrence of the current context (6 bytes, and
  12 bytes from level 3) and predict the byte that followed it. Images use a 2-D match on pixel
  neighbourhoods.
- **Mixers.** Small neural networks (logistic mixing) combine the predictions. The weight set is chosen
  by context, e.g. the match length or how many contexts were found. Levels 4-5 use a network of mixers
  with a final mixer.
- **APM / SSE stages.** They refine the mixed probability by context.
- **Images** (raw RGB24) code the error of a blended pixel predictor: MED, gradients, cross-channel
  predictors and an online least-squares (OLS) predictor, weighted by recent local error.
  Neighbour-error and exact-colour contexts sit on top.
- **Audio** (16-bit PCM, 1-8 channels) predicts each sample with OLS filters: 16 or 32 of the channel's own
  past samples plus 4 of the neighbouring channel, and a short fast filter.
- **Video** (raw RGB24 frames) is the image model plus contexts from the same pixels in the previous frame.
  There is no motion compensation.
- **x86 code** is detected and E8/E9-transformed (relative call/jump targets made absolute) before
  coding.

Input the model can't compress (incompressible or already compressed) is stored instead: level 0, or a
fallback when the coded output would be larger.

## File formats

All integers are little endian.

**FM4 stream, format 1** (header 36 bytes):

```
"FM4\x01" | mode u8 | bb u8 | counter limit u8 | mixer rate u8 | feat u32 | width u32 | L u64
| feat2 u32 | CRC-32 of the data u32 | CRC-32 of header bytes 0-31 u32 | payload
```

`mode` is 0 store, 1 bytes, 2 image/video, 3 audio. `feat`/`feat2` are the model's feature bits
(see `c/fm4.c`). `width` is the image width, the audio channel count, or width | frame height << 16
for video. `L` is the original length.

**Segments** (`FMS\x01 | u32 count | count x (u64 length | FM4 stream)`): inputs of 128 MB and more,
in any mode, are cut into size / 64 MB runs of whole units: bytes, image rows, video frames, or audio
samples of every channel. The runs are coded as independent streams, in parallel. The cut depends only on
the data, so the file is the same for any thread count. Each segment costs its model's memory (25-630 MB
by level). Splitting costs a little compression, because each segment starts with an empty model.
256 MB of mixed data at level 1 in 4 segments came out 1.9% larger, and took 62 s instead of 158 s on
4 cores. `SEG_MB` sets the segment size.

**Archives** (`FMA\x01 | u32 nsolid | streams`, described above `archive()` in `c/fm4.c`): an index
(paths, permissions, sizes) followed by all files sorted by extension and coded as solid data, cut into
size / 8 MB parts (at least 8 MB each). The PCM data of 16-bit WAV files and the pixels of 24-bit BMP
and PPM files get their own audio or image stream. Files that look already compressed (byte entropy
above 7.8 bits) are stored. Symlinks and timestamps are not kept. The archive is byte-identical for any
`-t` and any machine.

## Integrity and hostile input

A corrupt or malicious file is rejected. It is never decoded to wrong data, and it never makes the
decoder crash or allocate without bound:

- The header CRC, and a bound of `L` to about 2840x the payload, stop a bad length before anything is
  allocated. The same holds for every stream of an archive or segmented file, before their lengths are
  added up.
- Decoders accept only the parameter sets the encoder's levels write (feature bits, table size,
  counter limit, mixer rate) and whole pixels, frames or samples. Other combinations would index past
  the model's arrays. Files from `FEAT`/`FEAT2`/`LR` experiments need `FM4_ANY_FEAT=1` to decode (native
  builds, trusted input only; wasm always rejects them).
- Decoding stops once it reads past the payload, and the data CRC is checked at the end.
- Archive extraction refuses paths that would leave the destination (absolute paths, `..`, and on
  Windows `\` and `:`).

The test suite feeds every decoder truncated and bit-flipped files. libFuzzer harnesses
(`tests/fuzz/`) fuzz the decoder (single streams and segmented files, under ASan + UBSan and MSan) and
the encode/decode round trip. `tests/fuzz/replay.py` replays a fuzzing corpus through the C and BPL
builds and requires the same verdict and the same bytes. Inputs that once broke a decoder are kept in
`tests/hostile/`.

## Identical output across implementations

`c/fm4.c` is the reference. The BPL port (native and WebAssembly) must write the same bytes for the same
input and level, on every platform; `tests/expected.txt` locks the output hashes. That works because:

- All model arithmetic is integer, except the OLS predictors, which use IEEE doubles. Builds use
  `-ffp-contract=off` (no fused multiply-add), and of libm only `sqrt` and `floor`, which IEEE 754
  defines exactly.
- Segment and archive-part boundaries depend only on the data, never on the thread count or machine.

**Specialized model copies.** The model body is compiled once per (mode, level) with its feature bits
as constants: 18 copies, selected by a dispatcher. The general copy only runs for experiment feature
sets. With `FM4_CHECK_SPEC=1` (set by the test suite) a level that falls back to the general copy fails
with exit status 3. The copies make bytes level 1 about 35% faster, levels 2-5 10-16% and image levels
1-3 35-40%. The cost is a larger `fm4.wasm`: 355 KB instead of 62 KB, or 97 KB gzipped.

## Data larger than RAM

The native builds (`c/fm4`, `bpl/fm4`) don't keep the data in memory:

- Inputs are memory-mapped.
- Decoded output is written straight into a mapping of a new temporary file `OUT.fm4-XXXXXX`, renamed
  to `OUT` when complete and removed on failure or on Ctrl-C/SIGTERM.
- Buffers of 64 MB and more (encoder output, archive data, segment results, the E8/E9 copy of a large
  executable) live in unlinked temporary files next to the output.

The kernel can page all of it out, so only the model's tables (up to about 1.2 GB per process) need
memory. Under a 1 GB memory limit a 3 GB file encodes and decodes, and a 1.2 GB text file encodes at
level 1 under 512 MB.

Disk space:

- Decoding reserves the output's size up front (Linux, and macOS in C), so a full disk is an error
  instead of a crash. The BPL build on macOS can only extend the file.
- Encoding needs free space of up to about twice the input besides the output: the reserved encoder
  buffer, plus an E8/E9 copy for executables.
- When a temporary file can't be created, it falls back to memory.
- Windows reads and writes files in memory.

## Platforms

- **POSIX** (Linux, macOS, BSD): segments and archive streams are coded in parallel, one forked process
  each, with results in shared memory.
- **Windows** (MinGW-w64): there is no `fork`, so they are coded one after another, with the same
  output.
- **WebAssembly:** `createFm4()` runs one Web Worker per segment.

CI (`.github/workflows/test.yml`) runs the tests on Linux x86-64, macOS arm64 and Windows, plus sanitizer
and fuzzing jobs.
