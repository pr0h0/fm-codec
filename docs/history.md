# History: from a fraction to fm4

## The idea

The project started as an experiment: encode a file as a fraction `N / D` whose decimal expansion begins
with the file's bytes, and search for small `N` and `D` ([research/IDEA.md](../research/IDEA.md), Python
prototypes in `research/`). A plain fraction can never be shorter than the data: by counting, there are
not enough short fractions to go round, and the measured ratio was always 1.00x.

The fix is to let a probability model choose how wide each digit's interval is, so likely data gets wide
intervals and short numbers. That is arithmetic coding with a context-mixing model, and it does compress.
The file is still one number, `N / 256^k`, but the model decides how it is read back.

## Earlier formats

Each format below was a complete codec with its own C reference and ports. None of them is in the current
tree. Their code is in the git history, at tag [`fm1-fm3`](https://github.com/pr0h0/fm-codec/tree/fm1-fm3).

| Format | Main ideas | Implementations |
|---|---|---|
| fm (FRC1) | first model-fraction coder: orders 0-4 and 6, mixed | C, JS, BPL |
| fm2 | levels 0-5; image mode (MED and blended predictors, error contexts); second mixer, APM | C, BPL native + wasm, JS |
| fm3 | 64-byte nibble buckets (one cache line per context per 4 bits); two match models; word, sparse and indirect contexts; x86 E8/E9 transform; bit histories; a 3-mixer network; 9-predictor image blend | C, BPL native + wasm, JS |
| fm4 | current: OLS predictors, 2-D match, exact-colour contexts, more text contexts, a fourth mixer; audio and video modes; segments, archives, hardening | C, BPL native + wasm |

fm4 compared with fm3 at level 4, on a corpus of 10 text types and 20 images (`tools/make_corpus.sh`):
text and code 1.9% smaller on average (level 5: 3.3%), images 15.2% smaller on average (up to 36% on
screenshots). Every file came out smaller.

### fm3 against other tools

Compressed size / input size, smaller is better (from before fm4):

| Data | fm3 L1 | fm3 L2 | fm3 L4 | fm3 L5 | xz -9e | 7z PPMd | zpaq -m5 | JPEG XL e9 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 10 MB source code | 0.160 | 0.141 | 0.119 | **0.118** | 0.162 | 0.146 | 0.122 | — |
| 3.3 MB English prose | 0.197 | 0.173 | 0.158 | **0.157** | 0.208 | 0.180 | 0.160 | — |
| 10 MB x86-64 binary | 0.316 | 0.295 | 0.261 | **0.259** | 0.340 | 0.326 | 0.281 | — |
| 7 MB photo-like image (raw RGB) | 0.390 | 0.347 | **0.341** | 0.341 | 0.665 | 0.651 | 0.501 | 0.347 |
| 0.4 MB busy illustration | 0.547 | 0.501 | 0.494 | **0.493** | 0.647 | 0.672 | 0.571 | 0.501 |
| 0.3 MB character image | 0.234 | 0.208 | **0.205** | 0.205 | 0.315 | 0.281 | 0.237 | 0.212 |

## The BPL port

Every format from fm2 on was also written in [BPL](https://github.com/pr0h0/bpl3), which compiles to
native code and to WebAssembly. The port had to produce byte-identical files, and doing so found several
bpl3 compiler bugs along the way. fm4's BPL build runs within about 2% of the C build in every mode
(`bench/results/fm4_c_vs_bpl.txt`, `fm4_bpl_opt.txt`).
