#!/usr/bin/env bash
# Generate the benchmark inputs from files already on a Linux system.
#   text_1mb / text_10mb : Python standard library sources (code)
#   prose_3mb            : licenses + READMEs/NEWS/.txt from /usr/share/doc (English prose)
#   bin_10mb             : 10 MB slice of the largest LLVM shared library (machine code)
#   random_1mb           : /dev/urandom
#   mixed_1gb.tar        : first 1 GB of a tar of /usr/lib and /usr/share (mixed, partly precompressed)
#   images               : put PNG/JPG files in testdata/images/; each becomes testdata/<name>.rgb (raw RGB24)
#                          and its width is printed (image mode needs it). Needs ffmpeg.
set -eu
cd "$(dirname "$0")/.."
mkdir -p testdata
python3 - <<'EOF'
import glob, os
t = b"".join(open(f, "rb").read() for f in sorted(glob.glob("/usr/lib/python3*/**/*.py", recursive=True)))
open("testdata/text_1mb.bin", "wb").write(t[:1_000_000])
open("testdata/text_10mb.bin", "wb").write(t[:10_000_000])
open("testdata/random_1mb.bin", "wb").write(os.urandom(1_000_000))
open("testdata/tiny.txt", "wb").write(b"hello")
EOF
(cat /usr/share/common-licenses/* 2>/dev/null
 find /usr/share/doc -type f \( -name '*.txt' -o -name 'README*' -o -name 'NEWS' -o -name '*.md' \) ! -name '*.gz' -size +2k 2>/dev/null | sort | xargs cat 2>/dev/null) \
  | head -c 5000000 > testdata/prose_3mb.txt || true
lib=$(ls -S /usr/lib/llvm-*/lib/libLLVM*.so* 2>/dev/null | head -1 || true)
[ -n "$lib" ] && head -c 30000000 "$lib" | tail -c 10000000 > testdata/bin_10mb.bin
if [ "${WITH_1GB:-0}" = 1 ]; then (tar cf - /usr/lib /usr/share 2>/dev/null | head -c 1000000000 > testdata/mixed_1gb.tar) || true; fi
for img in testdata/images/*.{png,jpg,jpeg}; do
  [ -e "$img" ] || continue
  name=$(basename "${img%.*}")
  w=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$img")
  ffmpeg -v error -y -i "$img" -f rawvideo -pix_fmt rgb24 "testdata/$name.rgb"
  echo "testdata/$name.rgb  width=$w"
done
ls -la testdata
