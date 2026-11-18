#!/bin/sh
# fm4.wasm in headless Chromium through createFm4() (Web Workers): output must equal c/fm4's, for 1 and
# 4 workers, single streams and a segmented video; also corrupt segmented files.
# Needs bun, node, Playwright (PLAYWRIGHT=/path/to/node_modules/playwright/index.mjs) and its Chromium.
set -e
R=$(cd "$(dirname "$0")/../.." && pwd); D=$(mktemp -d); T=$R/testdata
head -c 1000000 $T/text_1mb.bin > $D/t1; $R/c/fm4 enc 4 bytes $D/t1 $D/t1.fm4
head -c $((640*426*3)) $T/corpus/img16_jpg_640.rgb > $D/img.rgb; $R/c/fm4 enc 4 image 640 $D/img.rgb $D/img.fm4
head -c $((640*360*3*10)) $T/media/v4_640x360x10.rgb > $D/v.rgb   # 10 frames, 6.9 MB: 3 segments with SEG_MB=2
SEG_MB=2 $R/c/fm4 enc 4 video 640 360 $D/v.rgb $D/v.fmv
BPLDIR=$R/bpl DATADIR=$D PAGE=$R/bench/browser/fm4_test.html bun $R/bench/browser/serve.ts & S=$!
sleep 1; node $R/bench/browser/run.mjs; kill $S; rm -r $D
