"""Encode a real image file two ways: raw pixels (image model) and the file bytes (bytes model).
Usage: python3 imgbench.py images/foo.png    (needs ffmpeg for pixel decoding)"""
import json, lzma, os, subprocess, sys, time
import modelfrac

sys.set_int_max_str_digits(0)  # N has millions of digits

path = sys.argv[1]
probe = json.loads(subprocess.run(
    ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height",
     "-of", "json", path], capture_output=True, check=True).stdout)["streams"][0]
w, h = probe["width"], probe["height"]
rgb = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
                     capture_output=True, check=True).stdout
assert len(rgb) == w * h * 3
filebytes = open(path, "rb").read()
name = os.path.basename(path)
os.makedirs("out", exist_ok=True)

for what, data, mode in (("raw pixels", rgb, "image"), ("file bytes", filebytes, "bytes")):
    t0 = time.time(); N, k, L = modelfrac.encode(data, mode, w); t1 = time.time()
    ok = modelfrac.decode(N, k, L, mode, w) == data; t2 = time.time()
    open(f"out/{name}.{mode}.frac", "wb").write(N.to_bytes(k, "big"))
    s = str(N)
    print(json.dumps({"file": name, "dims": f"{w}x{h}", "what": what, "input": len(data),
                      "file_size": len(filebytes), "fraction_bytes": k, "lzma": len(lzma.compress(data, preset=9)),
                      "vs_input": round(k / len(data), 3), "vs_file": round(k / len(filebytes), 3),
                      "N_digits": len(s), "N_head": s[:40], "enc_s": round(t1 - t0, 1),
                      "dec_s": round(t2 - t1, 1), "lossless_ok": ok}), flush=True)
