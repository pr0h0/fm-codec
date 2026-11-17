# Builds the C reference, the BPL native CLI and the BPL WebAssembly module.
# BPL compiler: set BPL=/path/to/bpl (https://github.com/pr0h0/bpl3, needs @[unchecked]: > 0.1.3), needs clang + wasm-ld.
BPL ?= bpl
CC ?= gcc
CFLAGS ?= -O3 -march=native -Wall

all: c bpl wasm bpl3 wasm3 bpl4 wasm4

c: c/fm4 c/fm3 c/fm2 c/fm c/fmx
c/fm4: c/fm4.c ; $(CC) $(CFLAGS) -ffp-contract=off -o $@ $< -lm
c/fm3: c/fm3.c ; $(CC) $(CFLAGS) -o $@ $<
c/fm2: c/fm2.c ; $(CC) $(CFLAGS) -o $@ $<
c/fm: c/fm.c ; $(CC) $(CFLAGS) -o $@ $<
c/fmx: c/fmx.c ; $(CC) $(CFLAGS) -o $@ $<

bpl: bpl/fm2
bpl/fm2: bpl/fm2_core.bpl bpl/fm2_cli.bpl
	cd bpl && $(BPL) build fm2_cli.bpl -O 3 -o fm2

wasm: bpl/fm2.wasm
bpl/fm2.wasm: bpl/fm2_core.bpl bpl/fm2_wasm.bpl
	cd bpl && BPL_REQUIRE_WASM_LD=1 $(BPL) build fm2_wasm.bpl --target wasm32-unknown-unknown -O 3 -o fm2.wasm

testdata:
	tools/make_testdata.sh

clean:
	rm -f c/fm c/fm2 c/fm3 c/fmx bpl/fm bpl/fm2 bpl/fm3 bpl/fm4 bpl/*.wasm bpl/*.ll

bpl3: bpl/fm3
bpl/fm3: bpl/fm3_core.bpl bpl/fm3_cli.bpl
	cd bpl && $(BPL) build fm3_cli.bpl -O 3 --march native -o fm3
wasm3: bpl/fm3.wasm
bpl/fm3.wasm: bpl/fm3_core.bpl bpl/fm3_wasm.bpl
	cd bpl && BPL_REQUIRE_WASM_LD=1 $(BPL) build fm3_wasm.bpl --target wasm32-unknown-unknown -O 3 -o fm3.wasm

bpl4: bpl/fm4
bpl/fm4: bpl/fm4_core.bpl bpl/fm4_cli.bpl
	cd bpl && $(BPL) build fm4_cli.bpl -O 3 --march native -o fm4
wasm4: bpl/fm4.wasm
bpl/fm4.wasm: bpl/fm4_core.bpl bpl/fm4_wasm.bpl
	cd bpl && BPL_REQUIRE_WASM_LD=1 $(BPL) build fm4_wasm.bpl --target wasm32-unknown-unknown -O 3 -o fm4.wasm
# Optional SIMD build (about 1.4x faster). --cpu bleeding-edge is the only way to get simd128 past the
# per-function target features BPL emits; it also turns on tail calls, bulk memory and saturating
# conversions, so it needs Chrome 112+, Firefox 121+ or Safari 18.2+. Same exports, same host file.
wasm4simd: bpl/fm4.simd.wasm
bpl/fm4.simd.wasm: bpl/fm4_core.bpl bpl/fm4_wasm.bpl
	cd bpl && BPL_REQUIRE_WASM_LD=1 $(BPL) build fm4_wasm.bpl --target wasm32-unknown-unknown --cpu bleeding-edge -O 3 -o fm4.simd.wasm

.PHONY: bpl3 wasm3 bpl4 wasm4 wasm4simd all c bpl wasm testdata clean
