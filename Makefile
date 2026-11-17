# Builds the C reference, the BPL native CLI and the BPL WebAssembly module.
# BPL compiler: set BPL=/path/to/bpl (https://github.com/pr0h0/bpl3), needs clang + wasm-ld.
BPL ?= bpl
CC ?= gcc
CFLAGS ?= -O3 -march=native -Wall

all: c bpl wasm

c: c/fm2 c/fm c/fmx
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
	rm -f c/fm c/fm2 c/fmx bpl/fm bpl/fm2 bpl/fm2.wasm bpl/*.ll

.PHONY: all c bpl wasm testdata clean
