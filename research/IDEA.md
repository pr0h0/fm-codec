# Fraction-Based Lossless Data Encoding — Idea and Findings

**Status:** Exploratory proof of concept  
**Goal:** Represent arbitrary data (from short strings to multi-gigabyte files) using a fixed number of integer values, preferably two integers forming a fraction, plus a constant number of helper values.

## 1. Original idea

1. Serialize the input into an exact sequence of digits (for example, fixed-width decimal byte values, hexadecimal, or binary).
2. Find two integers, a **numerator** `N` and **denominator** `D`, such that the decimal expansion of `N / D` **begins with** the serialized sequence.
3. Transmit `N`, `D`, and the number of decimal digits `L` to extract (or another fixed-format length/framing helper).
4. Recover exactly `L` digits after the decimal point using **integer arithmetic**, then deserialize them back into the original bytes.

The crucial refinement: **do not directly take the serialized integer as the numerator with a fixed power-of-ten denominator.** Instead, *search* for a fraction that produces the desired prefix, ideally with small numerator and denominator.

### Output contract

```text
numerator:   arbitrary-precision nonnegative integer
denominator: arbitrary-precision positive integer
length:      number of decimal prefix digits to recover
```

The number of fields is constant, but their **digit lengths are not**. A 4 GB arbitrary file cannot always be represented with a small, bounded number of bits.

## 2. Exact mathematical formulation

For a serialized decimal string `S` of length `L`, let `T = int(S)` and `B = 10^L`.

A fraction `N/D` in the interval `[0,1)` matches the target prefix if and only if

\[
\frac{T}{B} \le \frac{N}{D} < \frac{T+1}{B}.
\]

Equivalently, we can test each candidate without floating point:

```text
T * D <= N * B < (T + 1) * D
```

The exact decoder extracts the first `L` digits after the decimal point:

```python
prefix_int = ((N % D) * 10**L) // D
prefix = str(prefix_int).zfill(L)
```

`N % D` enables a possible nonzero whole-number part. For the initial prototype, search in `[0,1)`, so the whole part is zero. Fixed-width serialization is required so leading zeros and byte boundaries are recoverable.

## 3. Verified small examples

| Target decimal prefix | Numerator `N` | Denominator `D` | Notes |
|---|---:|---:|---|
| `500` | 1 | 2 | `1/2 = 0.500...` |
| `12345` | 10 | 81 | `10/81 = 0.123456790...` |
| `142857` | 1 | 7 | `1/7 = 0.142857142857...` |
| `396259796741889` | 15,262,441 | 38,516,249 | Verified exact 15-digit prefix |
| `104101108108111` | 6,911,611 | 66,393,251 | Verified exact 15-digit prefix; fixed-width 3-digit ASCII for `hello` |

The first two longer fractions were checked by **exact integer arithmetic**, not floating point.

Note: `396259796741889` was an illustrative decimal target in the discussion; it is **not** the standard decimal ASCII serialization of `hello`.

### Example: `hello`

ASCII bytes: `104 101 108 108 111`  
Serialized target: `104101108108111` (15 digits)

One matching fraction:

```text
N = 6911611
D = 66393251
L = 15
```

Take the first 15 decimal digits after the point in `N/D`, yielding `104101108108111`; split into 3-digit groups and convert the byte values to recover `hello`.

## 4. Algorithm: Stern–Brocot / continued-fraction interval search

Rather than naively trying denominators 1, 2, 3, ..., search for a rational number inside the exact interval using Stern–Brocot mediants and accelerated jumps.

A working conceptual implementation:

```python
def find_fraction(digits: str) -> tuple[int, int, int]:
    if not digits or not digits.isascii() or not digits.isdecimal():
        raise ValueError("Expected a nonempty ASCII decimal string")

    scale = 10 ** len(digits)
    target = int(digits)

    # Rational bounds: 0/1 and 1/0 (positive infinity).
    left_n, left_d = 0, 1
    right_n, right_d = 1, 0

    while True:
        n = left_n + right_n
        d = left_d + right_d

        if n * scale < target * d:
            steps = (target * left_d - scale * left_n - 1) // (
                scale * right_n - target * right_d
            )
            left_n += steps * right_n
            left_d += steps * right_d

        elif n * scale >= (target + 1) * d:
            steps = (scale * right_n - (target + 1) * right_d) // (
                (target + 1) * left_d - scale * left_n
            )
            right_n += steps * left_n
            right_d += steps * left_d

        else:
            return n, d, len(digits)


def recover(n: int, d: int, length: int) -> str:
    return str(((n % d) * 10**length) // d).zfill(length)


def encode_text(text: str) -> tuple[int, int, int]:
    digits = ''.join(f'{byte:03d}' for byte in text.encode('utf-8'))
    if not digits:
        # Empty input requires an explicit convention; do not call find_fraction('').
        return 0, 1, 0
    return find_fraction(digits)


def decode_text(n: int, d: int, length: int) -> str:
    if length == 0:
        return ''
    digits = recover(n, d, length)
    if length % 3:
        raise ValueError('Invalid byte serialization length')
    byte_values = [int(digits[i:i+3]) for i in range(0, length, 3)]
    if any(value > 255 for value in byte_values):
        raise ValueError('Invalid encoded byte')
    return bytes(byte_values).decode('utf-8')

n, d, length = encode_text('hello')
assert recover(n, d, length) == '104101108108111'
assert decode_text(n, d, length) == 'hello'
```

**Important implementation note:** This is a research prototype, not a hardened streaming or multi-GB implementation. The search needs formal validation for edge cases, adversarial inputs, and performance before production use. Python may impose configurable limits on decimal integer string conversion; lifting such limits does not eliminate memory or CPU costs.

## 5. What is proven, and what is not

### Established

- Every finite decimal digit string defines a nonempty rational interval with a rational number inside it.
- A matching fraction can be found using exact arithmetic; it need not be the trivial target-over-`10^L` construction.
- If `N`, `D`, `L`, and the serialization convention are known, decoding the prefix is lossless.
- The **number of fields** can stay constant for any finite input size.
- A surprisingly small fraction can reproduce some specific long digit patterns, notably recurring decimals.

### Not established

- That this scheme reliably reduces stored or transmitted bytes compared with the original input.
- That the minimum-denominator fraction also minimizes `digits(N) + digits(D)` or binary serialized size.
- That searching and encoding several GB is efficient on commodity hardware.
- That a given target necessarily yields a compact fraction (many arbitrary sequences do not).

## 6. Fundamental constraint: fixed fields do not imply fixed information size

The numerator and denominator may each require arbitrarily many digits. Searching for them cannot defeat the counting bound: there are `256^n` possible byte strings of length `n`, and a lossless scheme must distinguish all of them. No fixed-size representation can encode all 4 GB inputs.

A rational with a small denominator can produce infinitely many decimal digits, but those digits have constrained, repeating structure. They cannot realize every arbitrary prefix of a given length.

Thus this is best regarded as **fractional representation of data**, with possible **compression for special inputs**, not guaranteed universal compression.

## 7. Questions for the next experiments

1. **Optimize the right metric.** Compare minimum denominator with minimum combined binary length: `bit_length(N) + bit_length(D)` (including any length field).
2. **Compare serialization bases.** Three-decimal-digit UTF-8 byte codes are easy to explain, but binary or hexadecimal representations may be more natural. Exact rational prefix extraction can be generalized to any base `b` by replacing `10^L` with `b^L`.
3. **Benchmark distinct data types.** Random bytes, repeating bytes, plain English, structured JSON, compressed archives, encrypted data.
4. **Scale gradually.** 5 B → 100 B → 1 KB → 10 KB → 100 KB → 1 MB, recording exact round-trip correctness, execution time, peak memory, numerator length, denominator length and total serialized size.
5. **Test compression before fraction selection.** Compare raw input against zstd/gzip then rational encoding. Any savings should be attributed properly to the precompression stage.
6. **Investigate fast interval-rational algorithms.** Continued fractions, Stern–Brocot accelerated traversal, and shortest-rational-in-interval methods; avoid per-denominator brute force.
7. **Plan beyond RAM.** For GB-scale targets, consider streaming/chunked representations or out-of-core big integers, though a single fraction with two giant decimal integers is likely impractical.

## 8. Working research objective

Find a deterministic reversible mapping:

```text
encode(data: bytes) -> (N: integer, D: integer, L: integer)
decode(N, D, L) -> exact original bytes
```

Subject to:

```text
N >= 0
D > 0
L >= 0
serialized_bytes(decode(N,D,L)) == serialized_bytes(original)
```

And optimize, in order:

1. Correctness and unambiguous decoding.
2. Combined encoded byte length (including helper fields).
3. Encoding time and peak memory.
4. Decoding time and peak memory.
5. Scaling from strings to 4 GB binary files.

**Bottom line:** The prefix-matching fraction search is real and mathematically valid. We have verified several examples where the numerator and denominator are not directly derived as the serialized integer over a fixed power of ten. The next meaningful milestone is a reproducible benchmark that reveals the size/time tradeoffs, not assuming a compression benefit.
