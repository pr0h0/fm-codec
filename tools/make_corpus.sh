#!/usr/bin/env bash
# Broader test corpus from a source tree (default ~/Projects): ~1 MB per text type, up to 20 images
# cropped to <= 1024x1024 raw RGB24. Output: testdata/corpus/ (gitignored), images named NAME_W.rgb.
set -eu
ROOT=${1:-$HOME/Projects}; OUT="$(dirname "$0")/../testdata/corpus"; mkdir -p "$OUT"
skip='-name node_modules -prune -o -name .git -prune -o -name dist -prune -o -name build -prune -o -name .venv -prune -o -name venv -prune -o -name site-packages -prune -o -name fm-codec -prune -o -name .next -prune -o -name target -prune'
files() { eval find "$ROOT" $skip -o -type f \\\( "$1" \\\) -size -200k ! -name "'*.min.*'" -print 2>/dev/null | sort | awk 'BEGIN{srand(7)} {print rand() "\t" $0}' | sort | cut -f2; }
cat_type() {  # name, find-expr: concatenate shuffled files (skipping lines > 2000 chars = minified) up to 1 MB
  files "$2" | while read -r f; do awk 'length($0) < 2000' "$f"; done 2>/dev/null | head -c 1000000 > "$OUT/$1.txt" || true
}
cat_type ts   "-name '*.ts' -o -name '*.tsx'"
cat_type js   "-name '*.js' -o -name '*.mjs'"
cat_type py   "-name '*.py'"
cat_type go   "-name '*.go'"
cat_type c    "-name '*.c' -o -name '*.h' -o -name '*.cpp'"
cat_type md   "-name '*.md'"
cat_type json "-name '*.json'"
cat_type html "-name '*.html' -o -name '*.css'"
cat_type bpl  "-name '*.bpl'"
cat_type sh   "-name '*.sh' -o -name '*.yaml' -o -name '*.yml'"
n=0
# at most 2 images per project subdirectory, so one big image folder doesn't dominate
files "-iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp'" \
  | awk -v r="$ROOT/" '{ k = substr($0, length(r) + 1); split(k, p, "/"); if (seen[p[1] "/" p[2]]++ < 2) print }' | while read -r img; do
  [ $n -ge 20 ] && break
  wh=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$img" 2>/dev/null) || continue
  w=${wh%,*}; h=${wh#*,}; [ "${w:-0}" -ge 256 ] && [ "${h:-0}" -ge 256 ] || continue
  cw=$((w < 1024 ? w : 1024)); ch=$((h < 1024 ? h : 1024)); ext=${img##*.}; ext=${ext,,}
  ffmpeg -v error -y -i "$img" -frames:v 1 -vf "crop=$cw:$ch" -f rawvideo -pix_fmt rgb24 "$OUT/img${n}_${ext}_$cw.rgb" 2>/dev/null || continue
  n=$((n + 1))
done
ls -la "$OUT"
