#!/usr/bin/env python3
"""Differential check of c/fm4 against bpl/fm4 (which may be an ASan build); neither may crash.
  replay.py C_BIN BPL_BIN DECODE_CORPUS       each file, repaired as in fuzz_decode.c, gets the same verdict
                                             (both reject, or both decode to the same bytes)
  replay.py --enc C_BIN BPL_BIN RT_CORPUS     each file, read as in fuzz_roundtrip.c, encodes to the same file"""
import os, struct, subprocess, sys, tempfile, zlib

enc = sys.argv[1] == "--enc"
c_bin, b_bin, corpus = sys.argv[1 + enc:4 + enc]
# the encoder's experiment overrides would change what a level writes (and what the --enc check encodes)
clean = {k: v for k, v in os.environ.items() if k not in ("FEAT", "FEAT2", "LR", "BB")}

def level_tables():
    """(feat, feat2) per mode and level, read from files c/fm4 encodes (no copy of the tables to go stale)."""
    t = {1: [(0, 0)], 2: [(0, 0)], 3: [(0, 0)]}
    with tempfile.TemporaryDirectory() as d:
        open(f"{d}/in", "wb").write(b"the quick brown fox jumps over the lazy dog. " * 40)   # 1800 bytes, compressible
        for mode, args in ((1, ["bytes"]), (2, ["image", "10"]), (3, ["audio", "2"])):
            for level in range(1, 6):
                subprocess.run([c_bin, "enc", str(level), *args, f"{d}/in", f"{d}/out"], check=True, capture_output=True, env=clean)
                h = open(f"{d}/out", "rb").read(36)
                assert h[4] == mode, f"level {level} {args} was stored; use more compressible data"
                t[mode].append((struct.unpack("<I", h[8:12])[0], struct.unpack("<I", h[24:28])[0]))
    return t

LEVELS = level_tables()

def repair(d):  # mirrors LLVMFuzzerTestOneInput in fuzz_decode.c
    f = bytearray(d)
    f[0:3] = b"FM4"; f[3] = 1 + (f[3] & 1); f[5] = 12 + f[5] % 3
    if f[9] & 1:
        mode, level = f[4] & 3, 1 + f[8] % 5
        feat, feat2 = LEVELS[mode if mode else 1][level]
        if mode == 1 and f[9] & 2: feat |= 64
        if mode == 2 and level >= 2 and f[9] & 2: feat2 |= 256; f[14] |= 1
        f[4] = mode; f[6] = 255; f[7] = 1 + f[7] % 15
        f[8:12] = struct.pack("<I", feat); f[24:28] = struct.pack("<I", feat2)
    f[16:24] = struct.pack("<Q", struct.unpack("<Q", bytes(f[16:24]))[0] & 0x3FF)
    if f[3] == 2: f[32:36] = struct.pack("<I", zlib.crc32(bytes(f[:32])))
    return bytes(f)

def rt_args(d):  # mirrors LLVMFuzzerTestOneInput in fuzz_roundtrip.c: CLI arguments and the data
    level, mode = d[0] % 6, 1 + d[1] % 3
    video, L = mode == 2 and d[1] & 4, len(d) - 4
    if mode == 2:
        fw, fh = 1 + d[2] % 32, 1 + d[3] % 16
        L -= L % (3 * fw * (fh if video else 1))
        args = ["video", str(fw), str(fh)] if video else ["image", str(fw)]
    elif mode == 3:
        ch = 1 + d[2] % 8; L -= L % (2 * ch); args = ["audio", str(ch)]
    else:
        args = ["bytes"]
    return [str(level)] + args, d[4:4 + L]

env = dict(clean, ASAN_OPTIONS="detect_leaks=0:exitcode=99", UBSAN_OPTIONS="exitcode=99")
bad = n = 0
if enc:
    with tempfile.TemporaryDirectory() as t:
        for name in sorted(os.listdir(corpus)):
            d = open(os.path.join(corpus, name), "rb").read()
            if not 4 <= len(d) <= 1028: continue
            args, data = rt_args(d)
            open(f"{t}/in", "wb").write(data)
            outs = []
            for i, b in enumerate((c_bin, b_bin)):
                rc = subprocess.run([b, "enc", *args, f"{t}/in", f"{t}/o{i}"], env=env, capture_output=True, timeout=120).returncode
                outs.append(open(f"{t}/o{i}", "rb").read() if rc == 0 else rc)
            n += 1
            if outs[0] != outs[1] or not isinstance(outs[0], bytes): print(f"DIFFER {name} ({' '.join(args)}): {[o if isinstance(o, int) else len(o) for o in outs]}"); bad = 1
    print(f"encoded {n} inputs: {'mismatch' if bad else 'C and BPL produce identical files'}")
    sys.exit(bad)
with tempfile.TemporaryDirectory() as t:
    for name in sorted(os.listdir(corpus)):
        d = open(os.path.join(corpus, name), "rb").read()
        if not 36 <= len(d) <= 65536: continue
        open(f"{t}/in", "wb").write(repair(d))
        res = []
        for b in (c_bin, b_bin):
            out = f"{t}/out"
            if os.path.exists(out): os.remove(out)
            rc = subprocess.run([b, "dec", f"{t}/in", out], env=env, capture_output=True, timeout=120).returncode
            res.append((rc, open(out, "rb").read() if rc == 0 else None))
        n += 1
        if any(rc not in (0, 1) for rc, _ in res): print(f"CRASH {name}: exit {[r[0] for r in res]}"); bad = 1
        elif (res[0][0] == 0) != (res[1][0] == 0) or res[0][1] != res[1][1]: print(f"DIFFER {name}: C exit {res[0][0]}, BPL exit {res[1][0]}"); bad = 1
print(f"replayed {n} inputs: {'mismatch' if bad else 'C and BPL agree'}")
sys.exit(bad)
