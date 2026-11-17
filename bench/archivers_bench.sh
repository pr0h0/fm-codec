#!/usr/bin/env bash
# Benchmark standard compressors (single-threaded) on given files; skips tools that aren't installed.
# Usage: bench/archivers_bench.sh FILE...    Output: tool  file  input  output  ratio  enc_MB/s  dec_MB/s  check
set -u
T=$(mktemp -d)
# name | needed binary | compress (IN -> $T/c) | decompress ($T/c -> $T/d)
TOOLS=(
  "tar (no compression)|tar|tar cf \$T/c -C \$(dirname \$IN) \$(basename \$IN)|tar xf \$T/c -O > \$T/d"
  "gzip -6|gzip|gzip -6 -c \$IN > \$T/c|gzip -dc \$T/c > \$T/d"
  "gzip -9|gzip|gzip -9 -c \$IN > \$T/c|gzip -dc \$T/c > \$T/d"
  "zip -9|zip|zip -9 -q -j \$T/c.zip \$IN && mv \$T/c.zip \$T/c|unzip -p \$T/c > \$T/d"
  "bzip2 -9|bzip2|bzip2 -9 -c \$IN > \$T/c|bzip2 -dc \$T/c > \$T/d"
  "zstd -19|zstd|zstd -19 -T1 -q -c \$IN > \$T/c|zstd -dq -c \$T/c > \$T/d"
  "zstd -22 --ultra|zstd|zstd --ultra -22 -T1 -q -c \$IN > \$T/c|zstd -dq --memory=2048MB -c \$T/c > \$T/d"
  "xz -9e|xz|xz -9e -T1 -c \$IN > \$T/c|xz -dc \$T/c > \$T/d"
  "7z LZMA2 -mx9|7z|7z a -mx9 -mmt1 -bso0 -bsp0 \$T/c.7z \$IN && mv \$T/c.7z \$T/c|7z e -so \$T/c > \$T/d"
  "7z PPMd -mx9|7z|7z a -m0=PPMd -mx9 -mmt1 -bso0 -bsp0 \$T/c.7z \$IN && mv \$T/c.7z \$T/c|7z e -so \$T/c > \$T/d"
  "rar -m5|rar|rar a -m5 -mt1 -ep -idq \$T/c.rar \$IN && mv \$T/c.rar \$T/c|rar p -inul \$T/c > \$T/d"
  "zpaq -m5|zpaq|zpaq a \$T/c.zpaq \$IN -m5 -t1 >/dev/null && mv \$T/c.zpaq \$T/c|mv \$T/c \$T/x.zpaq && zpaq x \$T/x.zpaq -to \$T/xo -t1 >/dev/null && find \$T/xo -type f -exec cat {} + > \$T/d; mv \$T/x.zpaq \$T/c; rm -rf \$T/xo"
)
for IN in "$@"; do
  size=$(stat -c%s "$IN")
  for t in "${TOOLS[@]}"; do
    IFS='|' read -r name bin enc dec <<<"$t"
    command -v "$bin" >/dev/null || continue
    rm -rf "$T"/c "$T"/d "$T"/c.*
    s=$(date +%s.%N); eval "$enc" 2>/dev/null; m=$(date +%s.%N); eval "$dec" 2>/dev/null; e=$(date +%s.%N)
    out=$(stat -c%s "$T/c" 2>/dev/null || echo 0)
    printf "%-18s %-26s %11d %11d %7.3f %9.2f %9.2f %s\n" "$name" "$(basename "$IN")" "$size" "$out" \
      "$(echo "$out/$size" | bc -l)" "$(echo "$size/1000000/($m-$s)" | bc -l)" "$(echo "$size/1000000/($e-$m)" | bc -l)" \
      "$(cmp -s "$IN" "$T/d" && echo ok || echo FAIL)"
  done
done
rm -rf "$T"
