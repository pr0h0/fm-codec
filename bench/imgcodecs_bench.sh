#!/usr/bin/env bash
# Lossless image codecs via ffmpeg: size, encode/decode speed, verified pixel-exact. Usage: imgcodecs_bench.sh IMG...
T=$(mktemp -d)
C=(
 "PNG (max)|png|-c:v png -compression_level 9 -pred mixed"
 "QOI|qoi|-c:v qoi"
 "JPEG-LS|jls|-c:v jpegls -pred 0"
 "JPEG 2000 lossless|j2k|-c:v libopenjpeg -prog_order lrcp -compression_level 0"
 "FFV1 (context coder)|mkv|-c:v ffv1 -level 3 -coder 1 -context 1 -g 1"
 "WebP lossless z9|webp|-c:v libwebp -lossless 1 -compression_level 6 -quality 100"
 "JPEG XL lossless e7|jxl|-c:v libjxl -distance 0 -effort 7"
 "JPEG XL lossless e9|jxl|-c:v libjxl -distance 0 -effort 9"
 "AV1 lossless (aom)|mkv|-c:v libaom-av1 -crf 0 -cpu-used 4 -pix_fmt gbrp"
)
for IMG in "$@"; do
  ffmpeg -v error -y -i "$IMG" -f rawvideo -pix_fmt rgb24 $T/ref.rgb
  raw=$(stat -c%s $T/ref.rgb)
  for c in "${C[@]}"; do
    IFS='|' read -r name ext args <<<"$c"
    pf=rgb24; [[ $ext == jls || $ext == j2k ]] && pf=rgb24
    s=$(date +%s.%N); ffmpeg -v error -y -i "$IMG" $args $T/o.$ext 2>/dev/null; m=$(date +%s.%N)
    ffmpeg -v error -y -i $T/o.$ext -f rawvideo -pix_fmt rgb24 $T/d.rgb 2>/dev/null; e=$(date +%s.%N)
    sz=$(stat -c%s $T/o.$ext 2>/dev/null || echo 0)
    printf "%-24s %-28s %9d %9d %7.3f %7.2f %7.2f %s\n" "$name" "$(basename $IMG)" $raw $sz "$(echo "$sz/$raw"|bc -l)" \
      "$(echo "$raw/1e6/($m-$s)"|bc -l)" "$(echo "$raw/1e6/($e-$m)"|bc -l)" "$(cmp -s $T/ref.rgb $T/d.rgb && echo exact || echo NOT-EXACT)"
  done
done
rm -rf $T
