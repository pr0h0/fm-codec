# Builds the C reference, the BPL native CLI and the BPL WebAssembly module.
# BPL compiler: set BPL=/path/to/bpl (https://github.com/pr0h0/bpl3, needs staging 80d04313 or later: @[unchecked], @[noalias], wasm SIMD flags), needs clang + wasm-ld.
BPL ?= bpl
CC ?= gcc
# clang is about 5% faster than gcc here (it vectorizes the counter loops with gathers)
CC := $(shell command -v clang || echo cc)
CFLAGS ?= -O3 -march=native -Wall

all: c bpl wasm

c: c/fm4
c/fm4: c/fm4.c ; $(CC) $(CFLAGS) -ffp-contract=off -o $@ $< -lm

testdata:
	tools/make_testdata.sh

clean:
	rm -f c/fm4 c/fm4-asan c/fm4-msan bpl/fm4 bpl/*.wasm bpl/*.ll

bpl: bpl/fm4
bpl/fm4: bpl/fm4_core.bpl bpl/fm4_cli.bpl
	cd bpl && $(BPL) build fm4_cli.bpl -O 3 --march native -o fm4
wasm: bpl/fm4.wasm
bpl/fm4.wasm: bpl/fm4_core.bpl bpl/fm4_wasm.bpl
	cd bpl && BPL_REQUIRE_WASM_LD=1 $(BPL) build fm4_wasm.bpl --target wasm32-unknown-unknown --clang-flag -msimd128 --clang-flag -mbulk-memory -O 3 -o fm4.wasm
# fm4.wasm uses wasm SIMD (about 1.4x faster) and bulk memory: needs Chrome 91+, Firefox 89+, Safari 16.4+ or Node 16.4+,
# and a BPL compiler where --clang-flag -msimd128 reaches the per-function target features (80d04313 or later).

# round trips, identical output across builds, archives, corrupt input, locked hashes (tests/run.sh);
# also tests bpl/fm4 and bpl/fm4.wasm when they are built
test: c/fm4
	tests/run.sh

# the test suite on sanitizer builds of c/fm4: ASan + UBSan, then MSan (clang)
sanitize: c/fm4.c
	clang -g -O1 -fsanitize=address,undefined -fno-sanitize-recover=undefined -ffp-contract=off -o c/fm4-asan c/fm4.c -lm
	clang -g -O1 -fsanitize=memory -fsanitize-memory-track-origins -ffp-contract=off -o c/fm4-msan c/fm4.c -lm
	FM4=$(CURDIR)/c/fm4-asan tests/run.sh
	FM4=$(CURDIR)/c/fm4-msan tests/run.sh

# libFuzzer: decoder (ASan + UBSan, and MSan) and encode/decode round trip, FUZZ_SECONDS each (default 60)
fuzz: c/fm4
	tests/fuzz/run.sh

.PHONY: all c bpl wasm testdata clean test sanitize fuzz
