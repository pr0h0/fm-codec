#!/usr/bin/env bash
# Benchmark every port on every dataset; checks round trip and byte-identical output vs C.
set -u
cd "$(dirname "$0")/.."
T=$(mktemp -d)
declare -A RUN=(
  [c]="c/fm"
  [bpl]="bpl/fm"
  [bun]="bun js/fm.mjs"
  [node]="node js/fm.mjs"
)
SETS=(
  "text_1mb|bytes|testdata/text_1mb.bin"
  "text_10mb|bytes|testdata/text_10mb.bin"
  "random_1mb|bytes|testdata/random_1mb.bin"
  "noah_320x308|image 320|testdata/thumbref_noah.rgb"
  "library_512x288|image 512|testdata/style_win_library.rgb"
  "A_original_2048x1152|image 2048|testdata/thumbnail-A-original.rgb"
)
printf "%-22s %-5s %10s %10s %7s %8s %8s %8s %9s %s\n" data port input output ratio enc_s dec_s MB/s peakMB check
for s in "${SETS[@]}"; do
  IFS='|' read -r name mode in <<<"$s"
  size=$(stat -c%s "$in")
  c/fm enc $mode "$in" "$T/ref.frc"
  for p in c bpl bun node; do
    /usr/bin/time -f "%e %M" -o "$T/te" ${RUN[$p]} enc $mode "$in" "$T/$p.frc"
    /usr/bin/time -f "%e %M" -o "$T/td" ${RUN[$p]} dec "$T/$p.frc" "$T/$p.out"
    read -r te me <"$T/te"; read -r td md <"$T/td"
    out=$(stat -c%s "$T/$p.frc")
    ok=$(cmp -s "$in" "$T/$p.out" && echo rt-ok || echo RT-FAIL)
    same=$(cmp -s "$T/ref.frc" "$T/$p.frc" && echo same || echo DIFF)
    peak=$(( (me > md ? me : md) / 1024 ))
    printf "%-22s %-5s %10d %10d %7.3f %8.2f %8.2f %8.2f %9d %s/%s\n" "$name" "$p" "$size" "$out" \
      "$(echo "$out/$size" | bc -l)" "$te" "$td" "$(echo "$size/1000000/$te" | bc -l)" "$peak" "$ok" "$same"
  done
done
rm -rf "$T"
