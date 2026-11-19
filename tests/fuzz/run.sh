#!/bin/sh
# Builds the libFuzzer harnesses (clang; ASan + UBSan, and the decoder also with MSan) and runs each for
# FUZZ_SECONDS (default 60).
# Seeds: tests/gen.py inputs, small slices, encoded with BB=12 in several modes and levels.
# Crashes are written to $OUT (default a temp dir) and make the script fail.
set -eu
R=$(cd "$(dirname "$0")/../.." && pwd)
CC=${CC:-clang}
OUT=${OUT:-$(mktemp -d)}
SEC=${FUZZ_SECONDS:-60}
mkdir -p "$OUT/seed_decode" "$OUT/seed_roundtrip" "$OUT/corpus_decode" "$OUT/corpus_roundtrip" "$OUT/corpus_decode_msan"
for h in decode roundtrip; do
    $CC -g -O2 -fsanitize=fuzzer,address,undefined -fno-sanitize-recover=undefined -ffp-contract=off \
        -o "$OUT/fuzz_$h" "$R/tests/fuzz/fuzz_$h.c" -lm
done
# MemorySanitizer: reads of memory that was never written (e.g. output bytes a decoder skipped)
$CC -g -O2 -fsanitize=fuzzer,memory -ffp-contract=off -o "$OUT/fuzz_decode_msan" "$R/tests/fuzz/fuzz_decode.c" -lm
[ -x "$R/c/fm4" ] || make -C "$R" c/fm4
python3 "$R/tests/gen.py" "$OUT/in"
i=0
for t in "text.txt 1008 bytes" "bin.dat 1008 bytes" "ff.bin 1008 bytes" "img_96.rgb 864 image 96" "audio_2.pcm 1008 audio 2" "video_64x48.rgb 768 video 16 8"; do
    set -- $t; f=$OUT/in/$1 k=$2; shift 2   # slices of whole rows / frames, below the harness's 1 KB cap
    head -c $k "$f" > "$OUT/slice"
    for lv in 1 3 5; do
        BB=12 "$R/c/fm4" enc $lv "$@" "$OUT/slice" "$OUT/seed_decode/s$i" && i=$((i + 1))
    done
    { printf '\003\001\040\020'; head -c 1024 "$f"; } > "$OUT/seed_roundtrip/s$i"; i=$((i + 1))
done
fail=0
for h in decode roundtrip decode_msan; do
    echo "fuzz_$h: $SEC s"
    (cd "$OUT" && ./fuzz_$h -max_total_time=$SEC -print_final_stats=1 -artifact_prefix="$OUT/crash_$h-" \
        "$OUT/corpus_$h" "$OUT/seed_${h%_msan}" 2>&1 | grep -E "stat::number_of_executed_units|ERROR|runtime error|SUMMARY" ) || true
    ls "$OUT"/crash_$h-* >/dev/null 2>&1 && { echo "fuzz_$h found a crash: $(ls "$OUT"/crash_$h-*)"; fail=1; }
done
[ $fail = 0 ] && echo "fuzzing: no crashes"
exit $fail
