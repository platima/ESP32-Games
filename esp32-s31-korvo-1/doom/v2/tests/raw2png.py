#!/usr/bin/env python3
"""Turn a raw little-endian RGB565 dump into a PNG.

Usage: raw2png.py WIDTH HEIGHT in.raw out.png
Uses only the standard library.
"""
import struct
import sys
import zlib


def chunk(kind, data):
    body = kind + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)


def main():
    width, height = int(sys.argv[1]), int(sys.argv[2])
    with open(sys.argv[3], "rb") as f:
        raw = f.read()
    if len(raw) != width * height * 2:
        sys.exit("%s: %d bytes, expected %d" % (sys.argv[3], len(raw), width * height * 2))

    rows = bytearray()
    pixels = struct.unpack("<%dH" % (width * height), raw)
    for y in range(height):
        rows.append(0)  # filter type: none
        for v in pixels[y * width:(y + 1) * width]:
            r, g, b = v >> 11, (v >> 5) & 63, v & 31
            # widen 5 and 6 bits to 8 by repeating the top bits
            rows += bytes(((r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2)))

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(rows), 9))
    png += chunk(b"IEND", b"")
    with open(sys.argv[4], "wb") as f:
        f.write(png)


if __name__ == "__main__":
    main()
