#!/bin/sh
# fm4 test suite: round trips in every mode and level, identical output across builds and thread counts,
# archives, corrupt input, and the locked output hashes in tests/expected.txt (catches unintended format
# changes and platform differences). Builds that exist are tested: c/fm4 (required), bpl/fm4, bpl/fm4.wasm
# (with node). UPDATE=1 rewrites tests/expected.txt. FM4=path overrides the C binary (e.g. a sanitizer build).
set -u
# sanitizer builds (FM4=...): report errors with status 99, which the corrupt-input checks don't accept; an
# impossible allocation returns NULL as plain malloc does (the code then exits with "out of memory")
export ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=0}:exitcode=99:allocator_may_return_null=1" UBSAN_OPTIONS="${UBSAN_OPTIONS:-print_stacktrace=1}:exitcode=99" MSAN_OPTIONS="${MSAN_OPTIONS:-}:exitcode=99:allocator_may_return_null=1"
R=$(cd "$(dirname "$0")/.." && pwd)
C=${FM4:-$R/c/fm4}
B=$R/bpl/fm4
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
python3 "$R/tests/gen.py" "$D/in" || exit 1
fail=0
bad() { echo "FAIL: $*"; fail=1; }
none_like() { for f in "$@"; do [ -e "$f" ] && return 1; done; return 0; }   # none of these (glob) names exist
hash() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -c1-64; else shasum -a 256 "$1" | cut -c1-64; fi; }
T=; if command -v timeout >/dev/null; then T="timeout 60"; elif command -v gtimeout >/dev/null; then T="gtimeout 60"; else echo "warning: no timeout(1); corrupt-input hangs are not detected"; fi
nb=0; [ -x "$B" ] && nb=1
nw=0; [ -f "$R/bpl/fm4.wasm" ] && command -v node >/dev/null && nw=1
echo "builds: C$( [ $nb = 1 ] && echo ', BPL native')$( [ $nw = 1 ] && echo ', wasm')"

# ---- every mode and level ----
: > "$D/hashes"; : > "$D/wasm.list"
# first in the wasm list (fresh instance): a stream with the largest bb the encoder writes (20), so the decode
# memory estimate has to come from the stream's header, not from the input size (decode only: no BB in wasm)
if BB=20 $C enc 4 bytes "$D/in/text.txt" "$D/bb20.fm4"; then echo "$D/in/text.txt $D/bb20.fm4 - bytes" >> "$D/wasm.list"; else bad "C enc with BB=20"; fi
if [ $nb = 1 ]; then $B dec "$D/bb20.fm4" "$D/d" && cmp -s "$D/d" "$D/in/text.txt" || bad "BPL decode of a bb=20 stream"; fi
while read -r name mode args; do
    for lv in 0 1 2 3 4 5; do
        f=$D/in/$name o=$D/$name.$lv.fm4
        $C enc $lv $mode $args "$f" "$o" || { bad "C enc $lv $mode $name"; continue; }
        $C dec "$o" "$D/d" && cmp -s "$D/d" "$f" || bad "C round trip $lv $mode $name"
        echo "$name $lv $(hash "$o")" >> "$D/hashes"
        if [ $nb = 1 ]; then
            $B enc $lv $mode $args "$f" "$D/b" && cmp -s "$D/b" "$o" || bad "BPL output differs from C: $lv $mode $name"
            $B dec "$o" "$D/d" && cmp -s "$D/d" "$f" || bad "BPL decode $lv $mode $name"
        fi
        echo "$f $o $lv $mode $args" >> "$D/wasm.list"
    done
done <<EOF
text.txt bytes
bin.dat bytes
empty.bin bytes
ff.bin bytes
text_ff.bin bytes
x86.bin bytes
one.bin bytes
random.bin bytes
img_96.rgb image 96
audio_2.pcm audio 2
video_64x48.rgb video 64 48
EOF
if [ $nw = 1 ]; then node "$R/tests/wasm_check.mjs" "$R/bpl" "$D/wasm.list" || bad "wasm"; fi

# ---- table bits above 20 (decoders accept 21-22 from earlier BB= experiments; the encoder now writes <= 20) ----
# native decoders read a bb 21 stream (~2.3 GB of tables; bb 22 would need ~4.5 GB, too much for CI runners);
# wasm (up to 2 GB) must reject it with a clear error before allocating any of it
$C dec "$R/tests/large_bb/bb21.fm4" "$D/d" && cmp -s "$D/d" "$D/in/text.txt" || bad "C decode of a bb=21 stream"
if [ $nb = 1 ]; then $B dec "$R/tests/large_bb/bb21.fm4" "$D/d" && cmp -s "$D/d" "$D/in/text.txt" || bad "BPL decode of a bb=21 stream"; fi
if [ $nw = 1 ]; then node -e '
  const fs = require("fs");
  import(require("url").pathToFileURL(process.argv[1] + "/fm4wasm.mjs").href).then(async ({ loadFm4Wasm }) => {
    const fm4 = await loadFm4Wasm(fs.readFileSync(process.argv[1] + "/fm4.wasm"));
    try { fm4.decode(new Uint8Array(fs.readFileSync(process.argv[2]))); console.log("decoded"); process.exit(1); }
    catch (e) { process.exit(/not enough memory/.test(e.message) ? 0 : 1); }
  });' "$R/bpl" "$R/tests/large_bb/bb21.fm4" || bad "wasm: a bb=21 stream must fail with a clear out-of-memory error"; fi

# ---- format 1 files (written by the previous encoder) still decode ----
for t in "text.fm4 text.txt" "img_96.fm4 img_96.rgb" "ff.fm4 ff.bin"; do
    set -- $t
    $C dec "$R/tests/v1/$1" "$D/d" && cmp -s "$D/d" "$D/in/$2" || bad "C format 1 decode $1"
    if [ $nb = 1 ]; then $B dec "$R/tests/v1/$1" "$D/d" && cmp -s "$D/d" "$D/in/$2" || bad "BPL format 1 decode $1"; fi
done

# ---- hostile files found by fuzzing (tests/fuzz): each must be rejected, without a crash ----
for h in "$R"/tests/hostile/*.fm4; do
    for bin in "$C" $( [ $nb = 1 ] && echo "$B" ); do
        $T $bin dec "$h" "$D/d" >/dev/null 2>&1; rc=$?
        [ $rc = 1 ] || bad "${bin#$R/} dec tests/hostile/$(basename "$h"): exit status $rc (want 1)"
    done
done

# archives whose stored names are ordinary file names on POSIX but not on Windows, where they must be refused:
# t/..\..\escape.txt ('\' is a separator there: it would land next to the target directory) and t/a:stream
# (':' is a drive or an alternate data stream)
for t in "backslash_path ..\\..\\escape.txt" "colon_path a:stream"; do
    set -- $t; rm -rf "$D/bx"; mkdir -p "$D/bx/in"
    case $(uname -s) in
    MINGW*|MSYS*|CYGWIN*)
        $C x "$R/tests/hostile/$1.fma" "$D/bx/in" >/dev/null 2>&1; rc=$?
        [ $rc = 1 ] && [ ! -e "$D/bx/escape.txt" ] && [ -z "$(ls -A "$D/bx/in")" ] || bad "Windows: $1.fma was not refused (exit $rc)";;
    *)  $C x "$R/tests/hostile/$1.fma" "$D/bx/in" >/dev/null 2>&1 && [ -f "$D/bx/in/t/$2" ] || bad "extract $1.fma (an ordinary name on POSIX)";;
    esac
done

# ---- segmented video: same file for any thread count and build ----
v=$D/in/video_64x48.rgb
SEG_MB=0.05 $C enc -t 1 4 video 64 48 "$v" "$D/s1" && SEG_MB=0.05 $C enc -t 3 4 video 64 48 "$v" "$D/s3" || bad "C segmented enc"
cmp -s "$D/s1" "$D/s3" || bad "segmented video depends on thread count"
[ "$(head -c 4 "$D/s1")" = "$(printf 'FMV\001')" ] || bad "video not segmented"
$C dec -t 2 "$D/s1" "$D/d" && cmp -s "$D/d" "$v" || bad "C segmented round trip"
echo "video_64x48.rgb seg $(hash "$D/s1")" >> "$D/hashes"
if [ $nb = 1 ]; then
    SEG_MB=0.05 $B enc -t 2 4 video 64 48 "$v" "$D/sb" && cmp -s "$D/sb" "$D/s1" || bad "BPL segmented output differs from C"
    $B dec "$D/s1" "$D/d" && cmp -s "$D/d" "$v" || bad "BPL segmented decode"
fi

# ---- archive ----
mkdir -p "$D/tree/sub/deeper" "$D/tree/empty"
cp "$D/in/text.txt" "$D/in/random.bin" "$D/tree/"; cp "$D/in/bin.dat" "$D/tree/sub/"; cp "$D/in/one.bin" "$D/tree/sub/deeper/"
cp "$D/in/empty.bin" "$D/tree/sub/"
chmod 750 "$D/tree/sub/bin.dat"
(cd "$D" && PART_MB=0.02 $C a -t 1 4 a1.fma tree && PART_MB=0.02 $C a -t 3 4 a3.fma tree) >/dev/null 2>&1 || bad "archive"
cmp -s "$D/a1.fma" "$D/a3.fma" || bad "archive depends on thread count"
mkdir "$D/x" && $C x "$D/a1.fma" "$D/x" >/dev/null 2>&1 && diff -r "$D/tree" "$D/x/tree" >/dev/null || bad "archive round trip"
case $(uname -s) in MINGW*|MSYS*|CYGWIN*) ;;   # Windows has no Unix permission bits
*) [ "$(ls -l "$D/x/tree/sub/bin.dat" | cut -c1-10)" = "-rwxr-x---" ] || bad "archive permissions";; esac
mkdir "$D/x2" && (cd "$D/x2" && $C x "$D/a1.fma" >/dev/null 2>&1) && diff -r "$D/tree" "$D/x2/tree" >/dev/null || bad "extract to ."

# ---- corrupt input ----
n=0
# corrupt input: may fail, must not crash or hang (exit status 0 or 1); format 2 has CRCs, so a decode that
# succeeds must give the original data
for t in "text.txt.4.fm4 text.txt" "img_96.rgb.4.fm4 img_96.rgb" "audio_2.pcm.4.fm4 audio_2.pcm" "video_64x48.rgb.4.fm4 video_64x48.rgb" "s1 video_64x48.rgb" "a1.fma -"; do
    set -- $t; o=$D/$1 orig=$D/in/$2
    python3 - "$o" "$D/zc" <<'EOF'
import sys
d = open(sys.argv[1], "rb").read()
cases = [d[:k] for k in (0, 3, 4, 8, 20, 27, 28, 29, 40, len(d) // 2, len(d) - 1)] + [d + b"\0"]
for p in (3, 4, 5, 6, 7, 8, 9, 12, 16, 17, 18, 19, 20, 23, 24, 28, 31, 32, 35, 36, 45, len(d) // 3, len(d) - 2):
    if p < len(d):
        e = bytearray(d); e[p] ^= 0x41; cases.append(bytes(e))
for i, c in enumerate(cases):
    open(f"{sys.argv[2]}{i:02d}", "wb").write(c)
EOF
    for z in "$D"/zc*; do
        for bin in "$C" $( [ $nb = 1 ] && echo "$B" ); do
            case $o in *.fma) cmd="x $z $D/zx";; *) cmd="dec $z $D/zd";; esac
            [ "$bin" = "$B" ] && [ "${o##*.}" = fma ] && continue
            rm -rf "$D/zx"; mkdir "$D/zx"
            $T $bin $cmd >/dev/null 2>&1; rc=$?
            [ $rc -le 1 ] || bad "${bin#$R/} $cmd ($(basename "$o") case ${z##*zc}): exit status $rc"
            [ $rc = 0 ] && [ "$2" != - ] && ! cmp -s "$D/zd" "$orig" && bad "${bin#$R/} $cmd ($(basename "$o") case ${z##*zc}): wrong output accepted"
            n=$((n + 1))
        done
        rm -f "$z"
    done
done
echo "corrupt inputs: $n runs"

# ---- the file-backed paths (inputs mapped, output written in place, temporary files for big buffers) run
# only from 64 MB; FM4_BIG=1 runs them on the small inputs: same files, and no temporary files left behind ----
mkdir -p "$D/big" && cp "$D/in/text.txt" "$D/in/video_64x48.rgb" "$D/in/audio_2.pcm" "$D/in/random.bin" "$D/in/x86.bin" "$D/big/"
(cd "$D/big" && export FM4_BIG=1 SEG_MB=0.05 PART_MB=0.02 &&
    $C enc 4 bytes text.txt t.fm4 && $C dec t.fm4 t.out && cmp -s t.out text.txt && cmp -s t.fm4 "$D/text.txt.4.fm4" &&
    $C enc 0 bytes random.bin r.fm4 && $C dec r.fm4 r.out && cmp -s r.out random.bin &&
    $C enc 4 bytes x86.bin e.fm4 && cmp -s e.fm4 "$D/x86.bin.4.fm4" && $C dec e.fm4 e.out && cmp -s e.out x86.bin &&
    $C enc -t 2 4 video 64 48 video_64x48.rgb v.fmv && cmp -s v.fmv "$D/s1" && $C dec v.fmv v.out && cmp -s v.out video_64x48.rgb &&
    mkdir tree && cp text.txt audio_2.pcm random.bin tree/ && $C a 4 a.fma tree >/dev/null 2>&1 && mkdir x && $C x a.fma x >/dev/null 2>&1 &&
    diff -r tree x/tree >/dev/null && ! $C dec "$D/text.txt.4.fm4" /nonexistent/dir/o 2>/dev/null &&
    ! $C dec a.fma bad.out 2>/dev/null && none_like bad.out* .fm4-* ./*.fm4-* x/.fm4-*) || bad "file-backed paths (FM4_BIG=1)"
if [ $nb = 1 ]; then
    (cd "$D/big" && export FM4_BIG=1 SEG_MB=0.05 && rm -f t.out v.out &&
        $B enc 4 bytes text.txt tb.fm4 && cmp -s tb.fm4 t.fm4 && $B dec tb.fm4 t.out && cmp -s t.out text.txt &&
        $B enc 4 bytes x86.bin eb.fm4 && cmp -s eb.fm4 e.fm4 && $B dec eb.fm4 e.out && cmp -s e.out x86.bin &&
        $B enc -t 2 4 video 64 48 video_64x48.rgb vb.fmv && cmp -s vb.fmv v.fmv && $B dec vb.fmv v.out && cmp -s v.out video_64x48.rgb &&
        ! $B dec a.fma badb.out >/dev/null 2>&1 && none_like badb.out* .fm4-* ./*.fm4-*) || bad "BPL file-backed paths (FM4_BIG=1)"
fi

# a format-1 header claiming a huge length is decoded into memory, never into a file it would fill: the
# output file must not be created (the allocation fails or the decode is rejected)
python3 -c "
import struct, sys
d = bytearray(open(sys.argv[1], 'rb').read()); d[16:24] = struct.pack('<Q', 1 << 39)
open(sys.argv[2], 'wb').write(d)" "$R/tests/v1/text.fm4" "$D/big/v1huge.fm4"
# (with vm.overcommit_memory=1 the allocation succeeds and decoding just runs: then a timeout is fine too; the
# point is that no output file appears)
if [ -n "$T" ]; then
    (cd "$D/big" && FM4_BIG=1 ${T% *} 10 $C dec v1huge.fm4 huge.out >/dev/null 2>&1; rc=$?
     { [ $rc -le 1 ] || [ $rc = 124 ] || [ $rc = 137 ]; } && none_like huge.out*) || bad "format-1 huge length went to a file"
fi

# ---- locked hashes ----
if [ "${UPDATE:-0}" = 1 ]; then cp "$D/hashes" "$R/tests/expected.txt"; echo "tests/expected.txt updated"
elif ! diff "$R/tests/expected.txt" "$D/hashes"; then bad "output differs from tests/expected.txt (UPDATE=1 if intended)"; fi

[ $fail = 0 ] && echo "all tests passed"
exit $fail
