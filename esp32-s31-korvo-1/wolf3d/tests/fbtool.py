#!/usr/bin/env python3
"""Helpers for run-tests.sh.  Only the standard library is used.

  fbtool.py state FILE                 the fake console's state, in words
  fbtool.py png W H in.raw out.png     a raw RGB565 frame buffer as a PNG
  fbtool.py bbox W H in.raw            where the pixels that are not black are
  fbtool.py scalecheck W H ref.raw X,Y,W,H shot.raw X,Y,W,H
                                       is the picture in shot.raw the one in
                                       ref.raw, enlarged to that rectangle?
  fbtool.py keys FIFO CODE...          key codes as the kernel sends them in
                                       medium raw mode; +N presses, -N lets
                                       go, N does both, a bare number with a
                                       leading 0x is one raw byte
  fbtool.py mouse FIFO WORD...         events for a fake mouse: x=N y=N
                                       wheel=N left=0|1 right=0|1 middle=0|1
                                       syn, drop (SYN_DROPPED)
"""
import errno
import os
import struct
import sys
import time
import zlib

KD = {0: "text", 1: "GRAPHICS"}
KB = {0: "RAW", 1: "xlate", 2: "MEDIUMRAW", 3: "unicode", 4: "off"}
TERM = {0: "as at the start", 1: "RAW", 2: "SOMETHING ELSE"}
NVT = 8


def state(path):
    with open(path, "rb") as f:
        raw = f.read()
    ints = struct.unpack("<%di" % (9 + 4 * NVT), raw[:4 * (9 + 4 * NVT)])
    magic, active, locked, putvar, redraws, kbent, switches, blocked, flushed = ints[:9]
    kd = ints[9:9 + NVT]
    kb = ints[9 + NVT:9 + 2 * NVT]
    term = ints[9 + 2 * NVT:9 + 3 * NVT]
    if magic != 0x464B4642:
        sys.exit("%s: not a state file" % path)
    print("screen on vt%d, switching %s" % (active, "LOCKED" if locked else "free"))
    for n in range(1, NVT):
        if n == 1 or kd[n] != 0 or kb[n] != 3 or term[n] != 0:
            print("vt%d: %s mode, keyboard %s, terminal settings %s"
                  % (n, KD.get(kd[n], "?"), KB.get(kb[n], "?"), TERM.get(term[n], "?")))
    print("counts: %d mode requests, %d console redraws, %d keymap requests, "
          "%d screen switches, %d waits that would hang, %d key bytes dropped"
          % (putvar, redraws, kbent, switches, blocked, flushed))
    # one line for the scripts: is the console as it was?
    clean = (active == 1 and not locked and blocked == 0
             and all(kd[n] == 0 and kb[n] == 3 and term[n] == 0 for n in range(1, NVT)))
    print("console: %s" % ("as it was" if clean else "NOT AS IT WAS"))


def chunk(kind, data):
    body = kind + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)


def pixels(width, height, path):
    with open(path, "rb") as f:
        raw = f.read(width * height * 2)
    if len(raw) != width * height * 2:
        sys.exit("%s: %d bytes, expected at least %d" % (path, len(raw), width * height * 2))
    return struct.unpack("<%dH" % (width * height), raw)


def png(width, height, src, dst):
    pix = pixels(width, height, src)
    rows = bytearray()
    for y in range(height):
        rows.append(0)
        for v in pix[y * width:(y + 1) * width]:
            r, g, b = v >> 11, (v >> 5) & 63, v & 31
            rows += bytes(((r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2)))
    out = b"\x89PNG\r\n\x1a\n"
    out += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    out += chunk(b"IDAT", zlib.compress(bytes(rows), 9))
    out += chunk(b"IEND", b"")
    with open(dst, "wb") as f:
        f.write(out)


def bbox(width, height, src):
    pix = pixels(width, height, src)
    x0, y0, x1, y1 = width, height, -1, -1
    colours = set()
    for y in range(height):
        row = pix[y * width:(y + 1) * width]
        if any(row):
            y0 = min(y0, y)
            y1 = max(y1, y)
            for x, v in enumerate(row):
                if v:
                    x0 = min(x0, x)
                    break
            for x in range(width - 1, -1, -1):
                if row[x]:
                    x1 = max(x1, x)
                    break
            colours.update(row)
    if y1 < 0:
        print("picture: none, the screen is black")
    else:
        print("picture: %dx%d at (%d,%d), %d colours"
              % (x1 - x0 + 1, y1 - y0 + 1, x0, y0, len(colours - {0})))


def scalecheck(width, height, refpath, rect, shotpath, dst):
    """Is the picture in SHOT the picture in REF, enlarged?

    rect is where the picture is in REF, as x,y,w,h, and dst where it should
    be in SHOT.  Each pixel of the enlarged picture has to be the pixel of
    the original that its centre falls on, and everything around it black.
    This is worked out here, apart from the program under test.
    """
    ref = pixels(width, height, refpath)
    shot = pixels(width, height, shotpath)
    rx, ry, rw, rh = rect
    dx, dy, dw, dh = dst
    wrong = 0
    first = None
    for y in range(height):
        inside_y = dy <= y < dy + dh
        sy = ((2 * (y - dy) + 1) * rh) // (2 * dh) if inside_y else 0
        for x in range(width):
            if inside_y and dx <= x < dx + dw:
                sx = ((2 * (x - dx) + 1) * rw) // (2 * dw)
                want = ref[(ry + sy) * width + rx + sx]
            else:
                want = 0
            if shot[y * width + x] != want:
                wrong += 1
                if first is None:
                    first = (x, y)
    if wrong:
        print("scaled: %d pixels are wrong, the first at (%d,%d)" % (wrong, first[0], first[1]))
    else:
        print("scaled: all %d pixels are right" % (width * height))


def send(path, data, patient=True):
    """Write to a FIFO that the program under test has open.

    The first write of a run waits for the program to open it.  After that a
    FIFO that nobody reads means the program has ended, which is often what
    the key just sent was for: the rest is dropped without a word.
    """
    for _ in range(200 if patient else 1):
        try:
            fd = os.open(path, os.O_WRONLY | os.O_NONBLOCK)
            break
        except OSError as e:
            if e.errno not in (errno.ENXIO, errno.ENOENT):
                raise
            time.sleep(0.05)
    else:
        if patient:
            sys.exit("%s: nobody is reading" % path)
        return
    os.write(fd, data)
    os.close(fd)


def keys(path, words):
    first = True
    for w in words:
        if w.startswith("0x"):
            send(path, bytes([int(w, 16)]), first)
        elif w.startswith("+"):
            send(path, bytes([int(w[1:])]), first)
        elif w.startswith("-"):
            send(path, bytes([int(w[1:]) | 0x80]), first)
        else:
            send(path, bytes([int(w)]), first)
            time.sleep(0.15)
            send(path, bytes([int(w) | 0x80]), False)
        first = False
        time.sleep(0.15)


EV_SYN, EV_KEY, EV_REL = 0, 1, 2
CODES = {"x": (EV_REL, 0), "y": (EV_REL, 1), "wheel": (EV_REL, 8),
         "left": (EV_KEY, 0x110), "right": (EV_KEY, 0x111), "middle": (EV_KEY, 0x112)}


def mouse(path, words):
    out = b""
    for w in words:
        if w == "syn":
            out += struct.pack("<IIHHi", 0, 0, EV_SYN, 0, 0)
        elif w == "drop":
            out += struct.pack("<IIHHi", 0, 0, EV_SYN, 3, 0)
        else:
            name, value = w.split("=")
            kind, code = CODES[name]
            out += struct.pack("<IIHHi", 0, 0, kind, code, int(value))
    send(path, out)


def main():
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "state":
        state(args[0])
    elif cmd == "png":
        png(int(args[0]), int(args[1]), args[2], args[3])
    elif cmd == "bbox":
        bbox(int(args[0]), int(args[1]), args[2])
    elif cmd == "scalecheck":
        scalecheck(int(args[0]), int(args[1]), args[2], [int(v) for v in args[3].split(",")],
                   args[4], [int(v) for v in args[5].split(",")])
    elif cmd == "keys":
        keys(args[0], args[1:])
    elif cmd == "mouse":
        mouse(args[0], args[1:])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
