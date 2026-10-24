#!/usr/bin/env python3
"""Reads the text off a picture of tiny386's VGA text screen.

    fbtext.py VGAFONT.c WIDTH HEIGHT shot.raw

shot.raw is a frame buffer of WIDTH x HEIGHT pixels, RGB565, as the tests'
fake console keeps it.  The text screen is 80 columns of 25 lines in cells
of 9x16 pixels, 720x400 in all, in the middle of the frame buffer.  Each
cell is compared with the 256 characters of the font in vgafont.c of the
tiny386 sources, which is the font the emulated VGA starts with; a cell
that is none of them (the one with the cursor in it, as a rule) is shown
as an underscore, and one that is all one colour as a space.

Only the standard library is used.
"""
import re
import struct
import sys

COLS, ROWS, CW, CH = 80, 25, 9, 16

CP437 = (
    ' ☺☻♥♦♣♠•◘○◙♂♀♪♫☼►◄↕‼¶§▬↨↑↓→←∟↔▲▼'
    + ''.join(chr(c) for c in range(0x20, 0x7f)) + '⌂'
    + 'ÇüéâäàåçêëèïîìÄÅÉæÆôöòûùÿÖÜ¢£¥₧ƒáíóúñÑªº¿⌐¬½¼¡«»'
    + '░▒▓│┤╡╢╖╕╣║╗╝╜╛┐└┴┬├─┼╞╟╚╔╩╦╠═╬╧╨╤╥╙╘╒╓╫╪┘┌█▄▌▐▀'
    + 'αßΓπΣσµτΦΘΩδ∞φε∩≡±≥≤⌠⌡÷≈°∙·√ⁿ²■ '
)


assert len(CP437) == 256


def read_font(path):
    text = open(path).read()
    body = text[text.index('{') + 1:text.index('}')]
    vals = [int(v, 16) for v in re.findall(r'0x([0-9a-fA-F]{2})', body)]
    assert len(vals) == 256 * 16, 'not the font that was expected'
    glyphs = {}
    for ch in range(255, -1, -1):       # the lowest code wins a tie
        glyphs[tuple(vals[ch * 16:ch * 16 + 16])] = ch
    return glyphs


def main():
    font, w, h, shot = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
    glyphs = read_font(font)
    raw = open(shot, 'rb').read(w * h * 2)
    pix = struct.unpack('<%dH' % (w * h), raw)
    x0, y0 = (w - COLS * CW) // 2, (h - ROWS * CH) // 2
    lines = []
    for row in range(ROWS):
        line = ''
        for col in range(COLS):
            cx, cy = x0 + col * CW, y0 + row * CH
            cell = [pix[(cy + r) * w + cx:(cy + r) * w + cx + 8] for r in range(CH)]
            colours = set(c for r in cell for c in r)
            if len(colours) == 1:
                line += ' '
                continue
            if len(colours) > 2:
                line += '_'
                continue
            found = None
            for ink in colours:
                bits = tuple(sum((1 << (7 - i)) for i in range(8) if r[i] == ink) for r in cell)
                if bits in glyphs:
                    found = glyphs[bits]
                    # a cell that could be read either way round: take the
                    # one that is not a block character
                    if found not in (0xdb, 0x08, 0x0a):
                        break
            line += CP437[found] if found is not None else '_'
        lines.append(line.rstrip())
    print('\n'.join(lines))


main()
