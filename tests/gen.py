#!/usr/bin/env python3
"""Writes small deterministic test inputs for every fm4 mode into DIR (no dependence on testdata/).
Uses its own LCG so the bytes are the same on every Python version and platform."""
import math, os, struct, sys

d = sys.argv[1]
os.makedirs(d, exist_ok=True)
s = 12345
def rnd():
    global s
    s = (s * 6364136223846793005 + 1442695040888963407) & (2**64 - 1)
    return s >> 33  # 31 bits

def put(name, b):
    open(os.path.join(d, name), "wb").write(bytes(b))

words = "the of and to in is that for it as with was on be by at this which from or have an are not but had".split()
words += "codec model context mixing arithmetic coder predict bit byte stream table hash weight".split()
text = []
while sum(len(w) + 1 for w in text) < 40000:
    w = words[rnd() % len(words)]
    text.append(w.capitalize() + "." if rnd() % 13 == 0 else w)
put("text.txt", " ".join(text).encode())

b = bytearray()  # records with counters, floats and small ints, like a binary file
for i in range(3000):
    b += struct.pack("<IHhf", i * 7, rnd() % 600, (rnd() % 200) - 100, i * 0.25)
put("bin.dat", b)

W, H = 96, 64  # image: gradients, a disc and noise
img = bytearray()
for y in range(H):
    for x in range(W):
        disc = (x - 40) ** 2 + (y - 30) ** 2 < 300
        n = rnd() % 9
        img += bytes(((x * 2 + n) & 255, (y * 3 + n) & 255, 200 if disc else (x + y + n) & 255))
put("img_96.rgb", img)

pcm = bytearray()  # 0.5 s of stereo 16 kHz: two tones and noise
for i in range(8000):
    l = int(8000 * math.sin(i * 0.05) + (rnd() % 400) - 200)
    r = int(6000 * math.sin(i * 0.031) + (rnd() % 400) - 200)
    pcm += struct.pack("<hh", l, r)
put("audio_2.pcm", pcm)

VW, VH, NF = 64, 48, 24  # video: a square moving over a noisy gradient
vid = bytearray()
for f in range(NF):
    for y in range(VH):
        for x in range(VW):
            sq = 10 + f <= x < 26 + f and 12 <= y < 28
            n = rnd() % 5
            vid += bytes((250, 40, 40) if sq else ((x * 3 + n) & 255, (y * 4 + n) & 255, 90 + n))
put("video_64x48.rgb", vid)

put("ff.bin", b"\xff" * 100000)  # codes as zero bytes, which are stripped: a header-only file
put("text_ff.bin", " ".join(text[:500]).encode() + b"\xff" * 200000)
put("empty.bin", b"")
put("one.bin", b"x")
put("random.bin", bytes(rnd() & 255 for _ in range(5000)))  # incompressible: stored
