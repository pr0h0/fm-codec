"""Fraction encoding: bytes -> (N, D, L) such that the first L base-256 digits of N/D are the data.

Data is read as a base-256 fraction x = T / 256^L. Any N/D in [T/256^L, (T+1)/256^L) decodes back
exactly. We take continued-fraction convergents of the interval midpoint and return the first one
that lands inside the interval (near-minimal N and D). The continued fraction is computed with a
recursive half-gcd style reduction so MB-sized inputs finish in minutes, not years.
"""
import sys

sys.set_int_max_str_digits(0)

PLAIN_BITS = 4096  # below this, plain Euclid steps are faster than recursion


def _mul(A, B):
    return (A[0] * B[0] + A[1] * B[2], A[0] * B[1] + A[1] * B[3],
            A[2] * B[0] + A[3] * B[2], A[2] * B[1] + A[3] * B[3])


def _step(a, b, M, qs):
    q, r = divmod(a, b)
    qs.append(q)
    # M <- M * [[q,1],[1,0]]
    return b, r, (M[0] * q + M[1], M[0], M[2] * q + M[3], M[2])


def reduce(a, b, target):
    """Euclid on a > b >= 0 until b < 2^target.

    Returns (M, qs, a', b') with (a, b) = M (a', b') and qs the quotients used.
    Big cases recurse on the top bits; wrong trailing quotients are detected and popped
    (a valid state always has 0 <= b' < a', which pins the quotients uniquely).
    """
    M, qs = (1, 0, 0, 1), []
    while b.bit_length() > target:
        n, nb = a.bit_length(), b.bit_length()
        excess = nb - target
        if n <= PLAIN_BITS or excess <= 64 or n - nb > 32:
            a, b, M = _step(a, b, M, qs)
            continue
        r = min(excess, n // 4)
        h = 2 * r + 64
        s = n - h
        S, sub, _, _ = reduce(a >> s, b >> s, h - r)
        det = -1 if len(sub) & 1 else 1
        a2 = det * (S[3] * a - S[1] * b)
        b2 = det * (S[0] * b - S[2] * a)
        while sub and not (0 <= b2 < a2):  # undo quotients the truncation got wrong
            q = sub.pop()
            a2, b2 = q * a2 + b2, a2
            S = (S[1], S[0] - q * S[1], S[3], S[2] - q * S[3])
        if not sub:
            a, b, M = _step(a, b, M, qs)
            continue
        qs += sub
        M = _mul(M, S)
        a, b = a2, b2
    return M, qs, a, b


def encode(data: bytes) -> tuple[int, int, int]:
    L = len(data)
    if L == 0:
        return 0, 1, 0
    T = int.from_bytes(data, "big")
    if T == 0:
        return 0, 1, L
    B = 1 << (8 * L)
    inside = lambda n, d: T * d <= n * B < (T + 1) * d
    # CF of midpoint x = (2T+1)/(2B); run on (2B, 2T+1) so convergent of x is m10/m00.
    num, den = 2 * B, 2 * T + 1
    M, _, a, b = reduce(num, den, 4 * L + 32)  # stop a little before the expected hit
    while not inside(M[2], M[0]):
        if b == 0:
            break
        a, b, M = _step(a, b, M, [])
    N, D = M[2], M[0]
    assert inside(N, D)
    return N, D, L


def decode(N: int, D: int, L: int) -> bytes:
    return (((N % D) << (8 * L)) // D).to_bytes(L, "big")


if __name__ == "__main__":
    import os
    for size in (1, 2, 5, 100, 1000, 5000):
        for data in (os.urandom(size), b"\0" * size, b"\xff" * size, bytes(range(256)) * (size // 256 + 1)):
            data = data[:size]
            N, D, L = encode(data)
            assert decode(N, D, L) == data, (size, data[:8])
    assert encode(b"hello")[2] == 5
    print("self-check ok")
