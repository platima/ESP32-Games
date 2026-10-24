#!/usr/bin/env python3
"""Checks for the BIOS tests (bios-tests.sh).  Only the standard library.

  bioscheck.py mkdisk KIND FILE         a disk image with a pattern in it:
                                        hd (300 cylinders, 16 heads, 63
                                        sectors), fd144 or fd720
  bioscheck.py fonts LOG FONTS          the fonts that BFONTS.COM put in LOG,
                                        one file of them
  bioscheck.py shot NAME RAW LOG FONTS  the screen shot RAW (800x480 RGB565)
                                        against what picture NAME should be;
                                        LOG has what the guest said before
  bioscheck.py disk KIND BEFORE AFTER LOG
                                        what the guest wrote to a disk image
  bioscheck.py report RESULTS EXPECTED [some]
                                        every result against the list of
                                        what is expected of it; some: only
                                        some cases were run, so a line of the
                                        list that nothing matched is not
                                        missing

The guest programs report on the BIOS's debug port in lines that begin with
@ (see tests/guest/bios.inc).  This prints its findings in the same form,
@ok NAME, @bad NAME, @info NAME, so that the harness can put them together.

The pictures are worked out here, apart from the emulator: what a VGA
would show for each, placed as tiny386 places a picture on a screen of
800x480 (in the middle, no scaling).
"""
import copy
import fnmatch
import os
import re
import struct
import sys

FBW, FBH = 800, 480
# a screen of another size (the fake console's FAKE_GEOMETRY): WxH
if os.environ.get("BIOSCHECK_GEOMETRY"):
    FBW, FBH = (int(v) for v in os.environ["BIOSCHECK_GEOMETRY"].split("x"))

# ---------------------------------------------------------------- colours

def rgb565(r6, g6, b6):
    """A colour of the VGA's 6-bit DAC as tiny386 puts it on the screen."""
    return ((r6 >> 1) << 11) | (g6 << 5) | (b6 >> 1)


def rgb565_8(r8, g8, b8):
    """A colour of an 8-bit DAC."""
    return ((r8 >> 3) << 11) | ((g8 >> 2) << 5) | (b8 >> 3)


def name565(v):
    return "%04x(%d,%d,%d)" % (v, v >> 11, (v >> 5) & 63, v & 31)


# the sixteen colours of CGA, EGA and VGA text, in the 6-bit DAC
EGA16 = [rgb565(*c) for c in [
    (0, 0, 0), (0, 0, 42), (0, 42, 0), (0, 42, 42),
    (42, 0, 0), (42, 0, 42), (42, 21, 0), (42, 42, 42),
    (21, 21, 21), (21, 21, 63), (21, 63, 21), (21, 63, 63),
    (63, 21, 21), (63, 21, 63), (63, 63, 21), (63, 63, 63)]]
# mode 13h's palette after the first sixteen: a grey ramp
GREYS = [rgb565(g, g, g) for g in
         (0, 5, 8, 11, 14, 17, 20, 24, 28, 32, 36, 40, 45, 50, 56, 63)]
PAL256_32 = EGA16 + GREYS
BLACK, WHITE = rgb565(0, 0, 0), rgb565(63, 63, 63)
# mode 04h: palette 1, bright (light cyan, light magenta, white); 05h:
# the third CGA palette, bright (light cyan, light red, white)
CGA_M4 = [BLACK, rgb565(21, 63, 63), rgb565(63, 21, 63), WHITE]
CGA_M5 = [BLACK, rgb565(21, 63, 63), rgb565(63, 21, 21), WHITE]

# ---------------------------------------------------------------- the log

def at_lines(log):
    """The guest's @ lines, as (kind, name, rest)."""
    out = []
    with open(log, "rb") as f:
        for raw in f:
            line = raw.decode("latin-1").rstrip("\r\n")
            if not line.startswith("@"):
                continue
            parts = line[1:].split(" ", 2)
            while len(parts) < 3:
                parts.append("")
            out.append(tuple(parts))
    return out


def read_fonts(path):
    fonts = {}
    with open(path) as f:
        for line in f:
            name, hexs = line.split()
            fonts[name] = bytes.fromhex(hexs)
    return fonts


def glyphs(fonts, name):
    """The 256 glyphs of a font, as tuples of row bytes."""
    if name == "8x8":
        data, h = fonts["8x8lo"] + fonts["8x8hi"], 8
    else:
        data, h = fonts[name], int(name.split("x")[1])
    return [tuple(data[c * h:(c + 1) * h]) for c in range(256)], h


def pixels(path):
    with open(path, "rb") as f:
        raw = f.read(FBW * FBH * 2)
    if len(raw) != FBW * FBH * 2:
        sys.exit("%s: %d bytes, expected %d" % (path, len(raw), FBW * FBH * 2))
    return struct.unpack("<%dH" % (FBW * FBH), raw)


def bbox(pix):
    x0, y0, x1, y1 = FBW, FBH, -1, -1
    for y in range(FBH):
        row = pix[y * FBW:(y + 1) * FBW]
        if not any(row):
            continue
        y0 = min(y0, y)
        y1 = y
        for x in range(FBW):
            if row[x]:
                x0 = min(x0, x)
                break
        for x in range(FBW - 1, -1, -1):
            if row[x]:
                x1 = max(x1, x)
                break
    if y1 < 0:
        return None
    return (x0, y0, x1 - x0 + 1, y1 - y0 + 1)


def rect_s(r):
    return "none (black)" if r is None else "%dx%d at (%d,%d)" % (r[2], r[3], r[0], r[1])


def say(kind, name, text=""):
    print(("@%s %s %s" % (kind, name, text)).rstrip())


# ---------------------------------------------------------------- pictures

class Bars:
    """Upright bars across a picture of w x h, with a border one pixel wide.

    The bar of pixel x is ((x // unit) * ncol) // (w // unit), unit being
    the pixels a byte of video memory holds (the bars change at bytes);
    table, if given, turns a bar's number into the colour written; border
    None: no border.  The picture is expected at rect on the screen, each
    pixel sx by sy.  With xoff or yoff the screen shows the picture from
    (xoff, yoff) on: what would come from past its right edge is not
    judged, and what comes from below it should be black."""

    def __init__(self, w, h, unit, ncol, border, rect, sx, sy, pal, table=None,
                 xoff=0, yoff=0, rows=(), loose=False):
        self.w, self.h, self.unit, self.ncol = w, h, unit, ncol
        self.border, self.rect, self.sx, self.sy = border, rect, sx, sy
        self.pal, self.table = pal, table
        self.xoff, self.yoff, self.rows = xoff, yoff, rows
        self.loose = loose

    def bar(self, x, y):
        """The colour index at x, y of the picture."""
        if self.border is not None and (x == 0 or y == 0 or x == self.w - 1 or
                                        y == self.h - 1 or y in self.rows):
            return self.border
        b = ((x // self.unit) * self.ncol) // (self.w // self.unit)
        return self.table[b] if self.table else b

    def index(self, x, y):
        """What the screen should show at x, y of the picture's place: a
        colour index, -1 for black, or None for not judged."""
        x, y = x + self.xoff, y + self.yoff
        if x >= self.w:
            return None
        if y >= self.h:
            return -1
        return self.bar(x, y)

    def check(self, name, pix):
        got = bbox(pix)
        rx, ry, rw, rh = self.rect
        inside = got is not None and got[0] >= rx and got[1] >= ry and \
            got[0] + got[2] <= rx + rw and got[1] + got[3] <= ry + rh
        if got != self.rect and not (self.loose and inside):
            say("bad", name + ".geometry", "picture %s, wanted %s" % (rect_s(got), rect_s(self.rect)))
            say("bad", name + ".pattern", "not looked at: the picture is not where it should be")
            if self.pal:
                say("bad", name + ".colours", "not looked at: the picture is not where it should be")
            describe(name, pix)
            return
        say("ok", name + ".geometry", rect_s(got))
        # every pixel: which colour index it should be, and what is there
        seen = {}
        judged = 0
        for Y in range(ry, ry + rh):
            y = (Y - ry) // self.sy
            row = pix[Y * FBW:(Y + 1) * FBW]
            for X in range(rx, rx + rw):
                i = self.index((X - rx) // self.sx, y)
                if i is None:
                    continue
                judged += 1
                d = seen.setdefault(i, {})
                v = row[X]
                d[v] = d.get(v, 0) + 1
        wrong = 0
        found = {}
        for i, d in seen.items():
            v, n = max(d.items(), key=lambda kv: kv[1])
            if i == -1:
                v = BLACK
                n = d.get(BLACK, 0)
            found[i] = v
            wrong += sum(d.values()) - n
        if wrong:
            say("bad", name + ".pattern", "%d of %d pixels are not their bar's colour" % (wrong, judged))
        else:
            say("ok", name + ".pattern", "%d pixels, %d colours" % (judged, len(found)))
        found.pop(-1, None)
        if self.pal:
            bad = ["%d is %s, wanted %s" % (i, name565(found[i]), name565(self.pal[i]))
                   for i in sorted(found) if found[i] != self.pal[i]]
            if bad:
                say("bad", name + ".colours", "; ".join(bad))
            else:
                say("ok", name + ".colours", "all %d as wanted" % len(found))
        else:
            say("info", name + ".colours", " ".join("%d=%s" % (i, name565(found[i])) for i in sorted(found)))


class Split(Bars):
    """Mode X with the line compare at scan line 240: the top half page 2
    (the bars the other way round), the bottom half page 0 from its first
    line.  The lines either side of the split are not judged: where exactly
    a VGA splits in a doubled mode is a line here or there."""

    def index(self, x, y):
        if 118 <= y <= 121:
            return None
        if y < 120:
            # the border by where it is: bar 15 has the border's colour
            # too, and is reversed like the others
            if x == 0 or y == 0 or x == self.w - 1 or y == self.h - 1:
                return self.border
            return 15 - Bars.bar(self, x, y)
        return Bars.bar(self, x, y - 120)


class Black:
    """A screen that a VGA shows black."""

    def check(self, name, pix):
        got = bbox(pix)
        if got is None:
            say("ok", name + ".black", "nothing on the screen")
        else:
            say("bad", name + ".black", "the picture is still shown: %s" % rect_s(got))


def describe(name, pix):
    """A few words on a picture that is not where it should be."""
    r = bbox(pix)
    if r is None:
        say("info", name + ".seen", "the screen is black")
        return
    x0, y0, w, h = r
    cols = set()
    for y in range(y0, y0 + h):
        cols.update(pix[y * FBW + x0:y * FBW + x0 + w])
    # the colours along the middle line, as runs
    y = y0 + h // 2
    runs = []
    for x in range(x0, x0 + w):
        v = pix[y * FBW + x]
        if runs and runs[-1][0] == v:
            runs[-1][1] += 1
        else:
            runs.append([v, 1])
    say("info", name + ".seen", "%s, %d colours; middle line: %s" % (
        rect_s(r), len(cols), " ".join("%dx%04x" % (n, v) for v, n in runs[:40])))


class Text:
    """A text screen of cols x rows cells of cw x ch dots, each dot sx
    pixels wide, expected at rect, read with the BIOS font FONT against what
    video memory held (the guest's @text line)."""

    def __init__(self, cols, rows, cw, ch, sx, rect, font, pal):
        self.cols, self.rows, self.cw, self.ch, self.sx = cols, rows, cw, ch, sx
        self.rect, self.font, self.pal = rect, font, pal

    def check(self, name, pix, memory, fonts, skip=None):
        """The text has to be read where a VGA would put it, and nothing
        may be drawn outside that.  When it cannot be, it is looked for
        where tiny386 would put it if it drew each dot once (40 columns
        360 pixels wide)."""
        got = bbox(pix)
        rx, ry, rw, rh = self.rect
        inside = got is not None and got[0] >= rx and got[1] >= ry and \
            got[0] + got[2] <= rx + rw and got[1] + got[3] <= ry + rh
        if inside:
            say("ok", name + ".geometry", "%s, within %s" % (rect_s(got), rect_s(self.rect)))
        else:
            say("bad", name + ".geometry", "picture %s, wanted it within %s" % (rect_s(got), rect_s(self.rect)))
        n = self.cols * self.rows
        wrong, wrongcol = self.read(pix, memory, fonts, rx, ry, self.cw, self.sx, skip)
        if not wrong:
            say("ok", name + ".text", "all %d cells" % n)
            if self.pal:
                if wrongcol:
                    say("bad", name + ".colours", "%d cells have the wrong colours" % wrongcol)
                else:
                    say("ok", name + ".colours", "all %d cells" % n)
            return
        say("bad", name + ".text", "%d of %d cells are not the character in memory" % (wrong, n))
        if self.pal:
            say("bad", name + ".colours", "not looked at: the text is not where it should be")
        # where tiny386 puts it: the rows of cells in the middle of the
        # screen, a pixel a dot
        w, h = self.cols * self.cw, self.rows * self.ch
        x0, y0 = (FBW - w) // 2, (FBH - h) // 2
        if (x0, y0, self.sx) != (rx, ry, 1):
            alt, altcol = self.read(pix, memory, fonts, x0, y0, self.cw, 1, skip)
            say("info", name + ".text-where-tiny386-puts-it", "%d of %d cells right at %s" % (
                n - alt, n, rect_s((x0, y0, w, h))))
            if not alt:
                # and is the rest of the screen black?
                stray = sum(1 for y in range(FBH) for x in range(FBW)
                            if pix[y * FBW + x] and not (x0 <= x < x0 + w and y0 <= y < y0 + h))
                if stray:
                    say("bad", name + ".cleared", "%d pixels of what was on the screen before are "
                        "still there around it" % stray)
                else:
                    say("ok", name + ".cleared", "nothing else on the screen")
        describe(name, pix)

    overrides = ()

    def read(self, pix, memory, fonts, x0, y0, cw, sx, skip=None):
        """How many cells do not show their character, and how many not
        their colours.  The cell skip, (row, column), is left out."""
        gl, fh = glyphs(fonts, self.font)
        # glyphs of the guest's own (@glyph): code, bit 3 of the
        # attribute or None for any, the glyph
        own = {}
        for code, bit3, glyph in self.overrides:
            own[(code, bit3)] = glyph
        wrong = wrongcol = 0
        for r in range(self.rows):
            for c in range(self.cols):
                if (r, c) == skip:
                    continue
                ch = memory[2 * (r * self.cols + c)]
                at = memory[2 * (r * self.cols + c) + 1]
                X, Y = x0 + c * cw * sx, y0 + r * self.ch
                cell = [[pix[(Y + j) * FBW + X + i * sx] for i in range(cw)]
                        for j in range(self.ch)]
                if self.pal:
                    fg, bg = self.pal[at & 15], self.pal[at >> 4]
                else:
                    counts = {}
                    for row in cell:
                        for v in row:
                            counts[v] = counts.get(v, 0) + 1
                    order = sorted(counts, key=lambda v: -counts[v])
                    bg = order[0]
                    fg = order[1] if len(order) > 1 else None
                colours = set(v for row in cell for v in row)
                if self.pal and not colours <= {fg, bg}:
                    wrongcol += 1
                bits = tuple(sum(1 << (7 - i) for i in range(8) if row[i] == fg) for row in cell)
                ninth_ok = cw == 8 or all(row[8] == bg for row in cell) or 0xb0 <= ch <= 0xdf
                want = own.get((ch, (at >> 3) & 1), own.get((ch, None), gl[ch]))
                if bits != tuple(want[:self.ch]) or not ninth_ok:
                    wrong += 1
        return wrong, wrongcol


class Cursor(Text):
    """An 80x25 text screen with the cursor at row, col, its lines first to
    last lit when it is shown.  Several looks at the screen are given, since
    it blinks."""

    def __init__(self, row, col, first, last):
        Text.__init__(self, 80, 25, 9, 16, 1, VGA_TEXT, "8x16", EGA16)
        self.row, self.col, self.first, self.last = row, col, first, last

    def lit(self, pix, memory):
        """The lines of the cursor's cell that are all its colour."""
        at = memory[2 * (self.row * 80 + self.col) + 1]
        fg = self.pal[at & 15]
        X, Y = self.rect[0] + self.col * 9, self.rect[1] + self.row * 16
        return [j for j in range(16)
                if all(pix[(Y + j) * FBW + X + i] == fg for i in range(9))]

    def check_all(self, name, frames, memory, fonts):
        self.check(name, frames[0], memory, fonts, (self.row, self.col))
        want = list(range(self.first, self.last + 1))
        seen = [self.lit(p, memory) for p in frames]
        shown = [l for l in seen if l]
        if want in seen:
            say("ok", name + ".shown", "lines %d to %d" % (self.first, self.last))
        else:
            say("bad", name + ".shown", "lit lines seen %s, wanted %d to %d" % (
                sorted(set(tuple(l) for l in seen)), self.first, self.last))
        if shown and len(shown) < len(seen):
            say("ok", name + ".blinks", "shown in %d of %d looks" % (len(shown), len(seen)))
        else:
            say("bad", name + ".blinks", "shown in %d of %d looks" % (len(shown), len(seen)))


class PresetRow(Text):
    """80x25 text with the preset row scan (CR08h) at 5: a VGA shows it 5
    scan lines higher, the top of the first row cut off.  Rows 1 to 24 are
    read there."""

    def __init__(self, shift):
        Text.__init__(self, 80, 25, 9, 16, 1, VGA_TEXT, "8x16", EGA16)
        self.shift = shift

    def check(self, name, pix, memory, fonts, skip=None):
        inner = Text(80, 24, 9, 16, 1, VGA_TEXT, "8x16", EGA16)
        mem = memory[160:]
        wrong, _ = inner.read(pix, mem, fonts, 40, 56 - self.shift, 9, 1)
        if not wrong:
            say("ok", name + ".shifted", "rows 1 to 24, %d lines up" % self.shift)
            return
        say("bad", name + ".shifted", "%d of 1920 cells of rows 1 to 24 are not %d lines up"
            % (wrong, self.shift))
        wrong, _ = inner.read(pix, mem, fonts, 40, 56, 9, 1)
        say("info", name + ".unshifted", "%d of 1920 cells right where they would be without it"
            % (1920 - wrong))


class Blink(Text):
    """A text screen of red B on light grey with the blink bit (F4h) in
    every cell, as a VGA shows it with blinking on: the background light
    grey (7), the B shown and not by turns."""

    def __init__(self):
        Text.__init__(self, 80, 25, 9, 16, 1, VGA_TEXT, "8x16", EGA16)

    def check_all(self, name, frames, memory, fonts):
        bg_want, fg = EGA16[7], EGA16[4]
        X, Y = self.rect[0] + 9 * 40, self.rect[1] + 16 * 12      # a cell in the middle
        bgs, shown = set(), 0
        for p in frames:
            cell = [p[(Y + j) * FBW + X + i] for j in range(16) for i in range(9)]
            counts = {}
            for v in cell:
                counts[v] = counts.get(v, 0) + 1
            bgs.add(max(counts, key=counts.get))
            if fg in counts:
                shown += 1
        if bgs == {bg_want}:
            say("ok", name + ".background", "light grey, as with blinking on")
        else:
            say("bad", name + ".background", "%s, wanted %s (light grey): bit 7 of the attribute "
                "is taken as a bright background" % (" ".join(name565(v) for v in bgs), name565(bg_want)))
        if 0 < shown < len(frames):
            say("ok", name + ".blinks", "the B shown in %d of %d looks" % (shown, len(frames)))
        else:
            say("bad", name + ".blinks", "the B shown in %d of %d looks" % (shown, len(frames)))


class GText:
    """Text that AH=09h or 0Eh drew in a graphics mode of w x h, expected at
    rect with each pixel sx by sy: the guest's @gtext lines say where each
    string is (x, y in pixels), in which font and colour.  Everything else
    is black."""

    def __init__(self, w, h, rect, sx, sy, pal):
        self.w, self.h, self.rect, self.sx, self.sy, self.pal = w, h, rect, sx, sy, pal

    def check(self, name, pix, strings, fonts, points=()):
        want = {}
        for x, y, colour in points:
            want[(x, y)] = colour
        for x, y, font, colour, text in strings:
            gl, fh = glyphs(fonts, font)
            for k, ch in enumerate(text):
                g = gl[ord(ch)]
                for j in range(fh):
                    for i in range(8):
                        if g[j] & (0x80 >> i):
                            want[(x + 8 * k + i, y + j)] = colour
        rx, ry, rw, rh = self.rect
        wrong = 0
        first = None
        for Y in range(FBH):
            for X in range(FBW):
                v = pix[Y * FBW + X]
                if rx <= X < rx + rw and ry <= Y < ry + rh:
                    c = want.get(((X - rx) // self.sx, (Y - ry) // self.sy))
                    w = self.pal[c] if c is not None else BLACK
                else:
                    w = BLACK
                if v != w:
                    wrong += 1
                    if first is None:
                        first = (X, Y, v, w)
        if wrong:
            say("bad", name + ".text", "%d pixels wrong, the first at (%d,%d): %s, wanted %s" % (
                wrong, first[0], first[1], name565(first[2]), name565(first[3])))
            describe(name, pix)
        else:
            say("ok", name + ".text", "%d strings and %d pixels, every pixel right" % (
                len(strings), len(points)))


# what each picture of the tests should be
VGA_TEXT = (40, 40, 720, 400)

TEXT80 = Text(80, 25, 9, 16, 1, VGA_TEXT, "8x16", EGA16)
GRID_RECT = {(800, 480): (80, 65, 640, 350), (800, 600): (80, 125, 640, 350)}.get(
    (FBW, FBH), ((FBW - 640) // 2, (FBH - 350) // 2, 640, 350))
GRID = Text(80, 25, 8, 14, 1, GRID_RECT, "8x14", EGA16)
PICTURES = {
    # BMODES
    "10.00.m00": Text(40, 25, 9, 16, 2, VGA_TEXT, "8x16", EGA16),
    "10.00.m01": Text(40, 25, 9, 16, 2, VGA_TEXT, "8x16", EGA16),
    "10.00.m02": TEXT80,
    "10.00.m03": TEXT80,
    "10.00.m07": Text(80, 25, 9, 16, 1, VGA_TEXT, "8x16", None),
    "10.00.m04": Bars(320, 200, 4, 4, 3, (80, 40, 640, 400), 2, 2, CGA_M4),
    # which palette a VGA gives mode 05h I could not find out for certain:
    # its colours are recorded, not judged
    "10.00.m05": Bars(320, 200, 4, 4, 3, (80, 40, 640, 400), 2, 2, None),
    "10.00.m06": Bars(640, 200, 8, 2, 1, (80, 40, 640, 400), 1, 2, [BLACK, WHITE]),
    "10.00.m0d": Bars(320, 200, 8, 16, 15, (80, 40, 640, 400), 2, 2, EGA16),
    "10.00.m0e": Bars(640, 200, 8, 16, 15, (80, 40, 640, 400), 1, 2, EGA16),
    "10.00.m0f": Bars(640, 350, 8, 4, 5, (80, 65, 640, 350), 1, 1, None, [0, 1, 4, 5]),
    "10.00.m10": Bars(640, 350, 8, 16, 15, (80, 65, 640, 350), 1, 1, EGA16),
    "10.00.m11": Bars(640, 480, 8, 2, 1, (80, 0, 640, 480), 1, 1, [BLACK, WHITE]),
    "10.00.m12": Bars(640, 480, 8, 16, 15, (80, 0, 640, 480), 1, 1, EGA16),
    "10.00.m13": Bars(320, 200, 1, 32, 15, (80, 40, 640, 400), 2, 2, PAL256_32),
    # BTEXT
    "10.05.page1": TEXT80,
    "10.text-final": TEXT80,
    # the shape that 01h is given is 000Fh, and the one a mode set leaves is
    # 0607h, lines 13 and 14 on a VGA
    "10.01.cursor-block": Cursor(10, 20, 0, 15),
    "10.01.cursor-default": Cursor(12, 40, 13, 14),
    # BPAL: mode 12h's bars in the colours that the guest's own copy of the
    # palette says (@pal)
    "10.10.00": Bars(640, 480, 8, 16, 15, (80, 0, 640, 480), 1, 1, "log"),
    "10.10.02": Bars(640, 480, 8, 16, 15, (80, 0, 640, 480), 1, 1, "log"),
    "10.10.12": Bars(640, 480, 8, 16, 15, (80, 0, 640, 480), 1, 1, "log"),
    "10.10.13": Bars(640, 480, 8, 16, 15, (80, 0, 640, 480), 1, 1, "log"),
    "10.10.03.blink": Blink(),
    "10.10.03.intensity": TEXT80,
    # BCHARGEN: on a VGA the text of a mode starts at the top of its
    # picture, which is centred
    "10.11.12.50-lines": Text(80, 50, 9, 8, 1, VGA_TEXT, "8x8", EGA16),
    # SeaVGABIOS leaves the vertical display end at 400 lines when it loads
    # the 8x14 font, and a VGA scans to that line whatever the rows: under
    # the 28 rows it shows the top 8 lines of a 29th, from video memory.
    # So the picture may reach 400 lines; the 28 rows are what is read.
    "10.11.11.28-lines": Text(80, 28, 9, 14, 1, (40, 40, 720, 400), "8x14", EGA16),
    # 350 scan lines: IBM's VGA sets the colour text modes as the EGA had
    # them, characters 8 dots wide (mode 03h 640x350, and 43 lines in the
    # same 640x350); only mode 07h is 9 wide there.  Under 43 rows of 8 a
    # VGA shows the top 6 lines of a 44th, as under the 28 rows above.
    "10.12.30.350-lines": Text(80, 25, 8, 14, 1, (80, 65, 640, 350), "8x14", EGA16),
    "10.11.12.43-lines": Text(80, 43, 8, 8, 1, (80, 65, 640, 350), "8x8", EGA16),
    "10.12.30.350-lines.m07": Text(80, 25, 9, 14, 1, (40, 65, 720, 350), "8x14", None),
    "10.12.30.350-lines.m01": Text(40, 25, 8, 14, 2, (80, 65, 640, 350), "8x14", EGA16),
    "10.11.00.user": TEXT80,
    "10.11.03.blocks": TEXT80,
    "10.11.2x.m12": GText(640, 480, (80, 0, 640, 480), 1, 1, EGA16),
    "10.09.m13": GText(320, 200, (80, 40, 640, 400), 2, 2, PAL256_32),
    "10.09.m04": GText(320, 200, (80, 40, 640, 400), 2, 2, CGA_M4),
    # BINFO
    "10.12.36.refresh-off": Black(),
    # BPIXEL: the pixels that 0Ch wrote (@gpixel)
    "10.0c.m12": GText(640, 480, (80, 0, 640, 480), 1, 1, EGA16),
    "10.0c.m13": GText(320, 200, (80, 40, 640, 400), 2, 2, PAL256_32),
    # BVBE: 640x480 in 256 colours, a pixel a pixel
    "10.4f.02.m101": Bars(640, 480, 1, 16, 15, (80, 0, 640, 480), 1, 1, EGA16),
    "10.4f.07.start-line-1": Bars(640, 480, 1, 16, 15, (80, 0, 640, 479), 1, 1, EGA16, yoff=1),
    "10.4f.09.dac8": Bars(640, 480, 1, 16, 15, (80, 0, 640, 480), 1, 1, "log8"),
    "10.4f.02.m101-lfb": Bars(640, 480, 1, 16, 15, (80, 0, 640, 480), 1, 1, EGA16),
    "10.4f.02.m111-lfb": Bars(640, 480, 1, 2, None, (80, 0, 640, 480), 1, 1, [0xf800, 0x001f]),
    # 800x600 on a screen of 800x480: tiny386 shows the top 800x480 of it.
    # 103h has white lines across at 200 and 400 too, and is looked at again
    # with the display start 120 lines down, which shows the rest
    "10.4f.02.m103": Bars(800, 600, 1, 16, 15, (0, 0, 800, 480), 1, 1, EGA16, rows=(200, 400)),
    "10.4f.07.m103-start-120": Bars(800, 600, 1, 16, 15, (0, 0, 800, 480), 1, 1, EGA16,
                                    rows=(200, 400), yoff=120),
    "10.4f.02.m114-lfb": Bars(800, 600, 1, 2, None, (0, 0, 800, 480), 1, 1, [0xf800, 0x001f]),
    "10.4f.02.m102": Bars(800, 600, 8, 16, 15, (0, 0, 800, 480), 1, 1, EGA16),
    # BGRID: mode 10h, 640x350, as an 80x25 grid of 8x14 glyphs written
    # straight into video memory; every pixel read against the grid that
    # was in the guest's memory (@text).  In the middle of the screen: at
    # (80,65) on 800x480, (80,125) on 800x600
    "grid.a-map-mask": GRID,
    "grid.b-set-reset": GRID,
    "grid.c-write-mode-2": GRID,
    "grid.d-write-mode-3": GRID,
    "grid.scroll-write-mode-1": GRID,
    "grid.bios-09h": GRID,
    "grid.bios-06h": GRID,
    # BREGS: mode X is 320x240, each pixel doubled both ways
    "regs.modex": Bars(320, 240, 1, 16, 15, (80, 0, 640, 480), 2, 2, EGA16),
    "regs.modex.page2": Bars(320, 240, 1, 16, 15, (80, 0, 640, 480), 2, 2, EGA16,
                             table=list(range(15, -1, -1))),
    "regs.split": Split(320, 240, 1, 16, 15, (80, 0, 640, 480), 2, 2, EGA16),
    "regs.modex.latch-copy": Bars(320, 240, 1, 16, 15, (80, 0, 640, 480), 2, 2, EGA16, rows=(120,)),
    # what comes in at the right is the next line's start: only within
    "regs.pan12": Bars(640, 480, 8, 16, 15, (80, 0, 640, 480), 1, 1, EGA16, xoff=3, loose=True),
    "regs.preset-row": PresetRow(5),
    "regs.retrace-palette": Bars(320, 200, 1, 32, 15, (80, 40, 640, 400), 2, 2, "log"),
}


def shot(name, raws, log, fontfile):
    """raws: the shot, or several looks at the screen with commas between."""
    frames = [pixels(r) for r in raws.split(",")]
    pic = PICTURES.get(name)
    if pic is None:
        say("bad", name + ".picture", "bioscheck.py does not know this picture")
        return
    lines = at_lines(log)
    if isinstance(pic, GText):
        # the @gtext lines between the picture before this one and this
        strings, points = [], []
        for kind, n, rest in lines:
            if kind == "shot":
                if n == name:
                    break
                strings, points = [], []
            elif kind == "gtext":
                x, y, font, colour, text = rest.split(" ", 4)
                strings.append((int(x, 16), int(y, 16), font, int(colour, 16), text))
            elif kind == "gpixel":
                x, y, colour = rest.split()
                points.append((int(x, 16), int(y, 16), int(colour, 16)))
        pic.check(name, frames[0], strings, read_fonts(fontfile), points)
    elif isinstance(pic, Text):
        memory = None
        overrides = []
        for kind, n, rest in lines:
            if kind == "text" and n == name:
                memory = bytes.fromhex(rest.split()[2])
            if kind == "glyph" and n == name:
                code, bit3, hexs = rest.split()
                overrides.append((int(code, 16), None if bit3 == "x" else int(bit3), bytes.fromhex(hexs)))
        if memory is None:
            say("bad", name + ".text", "the guest sent no @text for it")
            return
        pic.overrides = overrides
        if isinstance(pic, (Cursor, Blink)):
            pic.check_all(name, frames, memory, read_fonts(fontfile))
        else:
            pic.check(name, frames[0], memory, read_fonts(fontfile))
    elif isinstance(pic, Black):
        pic.check(name, frames[0])
    else:
        if pic.pal in ("log", "log8"):
            # the colours the guest worked out: @pal (6 bits) or @pal8
            pal = None
            conv = rgb565 if pic.pal == "log" else rgb565_8
            for kind, n, rest in lines:
                if kind == pic.pal.replace("log", "pal") and n == name:
                    h = rest.strip()
                    pal = [conv(int(h[6 * i:6 * i + 2], 16), int(h[6 * i + 2:6 * i + 4], 16),
                                int(h[6 * i + 4:6 * i + 6], 16)) for i in range(len(h) // 6)]
            if pal is None:
                say("bad", name + ".colours", "the guest sent no @%s for it" % pic.pal.replace("log", "pal"))
                return
            pic = copy.copy(pic)
            pic.pal = pal
        pic.check(name, frames[0])


# ---------------------------------------------------------------- disks

SECTOR = 512


def pattern(lba):
    """What the sector at lba holds before a test: its number, LRDT, and
    then (k + 7 * lba) & 255 in byte k."""
    head = struct.pack("<I", lba & 0xffffffff) + b"LRDT"
    return head + bytes((k + 7 * lba) & 255 for k in range(8, SECTOR))


def written(lba):
    """What a test writes: its number, WRTN, and (3k + lba) & 255."""
    head = struct.pack("<I", lba & 0xffffffff) + b"WRTN"
    return head + bytes((3 * k + lba) & 255 for k in range(8, SECTOR))


DISKS = {
    # (sectors in all, the ranges of them that have the pattern)
    "hd": (300 * 16 * 63, [(0, 4 * 1008), (255 * 1008, 257 * 1008), (299 * 1008, 300 * 1008)]),
    "fd144": (2880, [(0, 2880)]),
    "fd720": (1440, [(0, 1440)]),
}


def mkdisk(kind, path):
    total, ranges = DISKS[kind]
    with open(path, "wb") as f:
        f.truncate(total * SECTOR)
        for a, b in ranges:
            f.seek(a * SECTOR)
            f.write(b"".join(pattern(lba) for lba in range(a, b)))


def disk(kind, before, after, log):
    """Every sector that differs has to be one the guest said it wrote
    (@wrote LBA COUNT lines), holding written(lba); and every one it said it
    wrote has to be so."""
    claimed, ignored = set(), set()
    for k, n, rest in at_lines(log):
        if k in ("wrote", "ignore"):
            lba, count = int(n, 16), int(rest, 16)
            (claimed if k == "wrote" else ignored).update(range(lba, lba + count))
    total = DISKS[kind][0]
    changed = set()
    with open(before, "rb") as a, open(after, "rb") as b:
        for lba in range(total):
            x, y = a.read(SECTOR), b.read(SECTOR)
            if x != y:
                changed.add(lba)
                if lba in claimed and y != written(lba):
                    say("bad", "13.%s.image-content" % kind,
                        "sector %d changed, but not to what was written" % lba)
    stray = sorted(changed - claimed - ignored)
    if ignored:
        say("info", "13.%s.image-ignored" % kind, "%d sectors not looked at (formatted), of which %d changed"
            % (len(ignored), len(changed & ignored)))
    lost = sorted(claimed - changed)
    if stray:
        say("bad", "13.%s.image-stray" % kind, "%d sectors changed that were not written to, from %d"
            % (len(stray), stray[0]))
    else:
        say("ok", "13.%s.image-stray" % kind, "no sector changed but those written")
    if lost:
        say("bad", "13.%s.image-written" % kind, "%d sectors written are not in the image, from %d"
            % (len(lost), lost[0]))
    else:
        say("ok", "13.%s.image-written" % kind, "%d sectors written, all there: %s" % (
            len(claimed), ",".join(str(x) for x in sorted(claimed))))


# ---------------------------------------------------------------- report

def report(results, expected, some=None):
    """Each result against the list.  The list's lines are NAME (a shell
    pattern) EXPECT [why], EXPECT pass or xfail; the last line that
    matches a name says what is expected of it."""
    rules = []
    with open(expected) as f:
        for line in f:
            line = line.split("#", 1)[0].rstrip()
            if not line.strip():
                continue
            parts = line.split(None, 2)
            if len(parts) < 2 or parts[1] not in ("pass", "xfail"):
                sys.exit("%s: not understood: %s" % (expected, line))
            rules.append([parts[0], parts[1], parts[2] if len(parts) > 2 else "", 0])
    seen = {}
    infos = []
    with open(results) as f:
        for line in f:
            m = re.match(r"@(ok|bad|info) (\S+) ?(.*)", line.rstrip("\n"))
            if not m:
                continue
            kind, name, rest = m.groups()
            if kind == "info":
                infos.append((name, rest))
                continue
            if name in seen and seen[name][0] == "ok" and kind == "bad":
                seen[name] = (kind, rest)
            elif name not in seen:
                seen[name] = (kind, rest)
    counts = {"PASS": 0, "XFAIL": 0, "FAIL": 0, "XPASS": 0, "MISSING": 0, "UNLISTED": 0}
    lines = []
    for name in seen:
        kind, rest = seen[name]
        rule = None
        for r in rules:
            if fnmatch.fnmatchcase(name, r[0]):
                rule = r
        if rule is None:
            verdict = "UNLISTED"
        else:
            rule[3] += 1
            if rule[1] == "pass":
                verdict = "PASS" if kind == "ok" else "FAIL"
            else:
                verdict = "XFAIL" if kind == "bad" else "XPASS"
        counts[verdict] += 1
        why = "  [%s]" % rule[2] if rule and rule[2] and verdict in ("XFAIL", "XPASS") else ""
        lines.append("%-8s %-40s %s%s" % (verdict, name, rest, why))
    for r in rules:
        if r[3] == 0 and not some:
            counts["MISSING"] += 1
            lines.append("%-8s %-40s no such result" % ("MISSING", r[0]))
    for l in lines:
        print(l)
    print()
    for name, rest in infos:
        print("info     %-40s %s" % (name, rest))
    print()
    print("%d passed, %d failed as expected, %d failed, %d passed unexpectedly, "
          "%d missing, %d not in the list" % (
              counts["PASS"], counts["XFAIL"], counts["FAIL"], counts["XPASS"],
              counts["MISSING"], counts["UNLISTED"]))
    return 0 if counts["FAIL"] + counts["XPASS"] + counts["MISSING"] + counts["UNLISTED"] == 0 else 1


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    a = sys.argv[2:]
    if cmd == "mkdisk" and len(a) == 2:
        mkdisk(a[0], a[1])
    elif cmd == "fonts" and len(a) == 2:
        with open(a[1], "w") as f:
            for kind, name, rest in at_lines(a[0]):
                if kind == "font":
                    f.write("%s %s\n" % (name, rest.strip()))
    elif cmd == "shot" and len(a) == 4:
        shot(*a)
    elif cmd == "disk" and len(a) == 4:
        disk(*a)
    elif cmd == "report" and len(a) in (2, 3):
        sys.exit(report(*a))
    else:
        sys.exit(__doc__)


main()
