/*
 * BCHARGEN.COM: the character generator, int 10h AH=11h.
 *
 *   text   the ROM fonts loaded with (11h, 12h, 14h) and without (01h,
 *          02h, 04h) the screen made to fit; 50 lines (8x8 in 400 scan
 *          lines), 43 lines (8x8 in 350, chosen with AH=12h BL=30h) and 28
 *          (8x14 in 400); a font of the user's own (00h), and two fonts of
 *          256 at once (03h, with 04h and 00h into block 1)
 *   graphics  the fonts for graphics modes (22h, 23h, 24h) and what
 *          AH=09h and 0Eh then draw with them in modes 12h, 13h and 04h
 *
 * What is in the font memory (plane 2) is read back and held against the
 * BIOS's own fonts (AX=1130h), and each screen goes to the harness.  The
 * text drawn in graphics modes is listed as @gtext lines, which say where
 * each string is, in which font and colour.
 *
 * Build:
 *   as --32 -I tests/guest -o bchargen.o bchargen.S
 *   ld -m elf_i386 -Ttext 0x100 --oformat binary -o BCHARGEN.COM bchargen.o
 *
 * Offered under the licence of tiny386 (BSD 3-clause).
 */
	.intel_syntax noprefix
	.code16
	.text
	.globl	_start
_start:
	jmp	main
	.include "bios.inc"

buf	= 0x9000		/* a glyph out of plane 2: 32 bytes */

/* ROWS NAME, ROWS1, CHEIGHT: the BIOS data area and the CRTC's character
   height after a font change */
	.macro	ROWS name, rows1, cheight
	push	es
	push	0x40
	pop	es
	CK8	"\name\().bda-rows", es:[0x84], \rows1
	CK16	"\name\().bda-cheight", es:[0x85], \cheight
	pop	es
	mov	al, 9
	call	crtc_read
	and	al, 0x1f
	CK8	"\name\().crtc-09", al, (\cheight-1)
	.endm

/* TEXTSHOT NAME, ROWS[, COLS, SEG, MONO]: the screen filled, sent as @text
   and looked at */
	.macro	TEXTSHOT name, rows, cols=80, seg=0xb800, mono=0
	push	es
	push	\seg
	pop	es
	mov	cl, \cols
	mov	ch, \rows
	mov	bl, \mono
	call	draw_text
	mov	si, offset .Ln\@
	mov	dl, \cols
	mov	dh, \rows
	mov	cx, \cols * \rows
	call	textdump
	pop	es
	SHOT	\name
	jmp	.Le\@
.Ln\@:	.asciz	"\name"
.Le\@:
	.endm

/* GLYPH NAME, BLOCK, CODE, BH, HEIGHT: is the glyph of CODE in font block
   BLOCK the one in the BIOS's font BH (1130h), HEIGHT lines of it? */
	.macro	GLYPH name, block, code, bh, height
	mov	al, \block
	mov	ah, \code
	call	plane2_glyph
	mov	bh, \bh
	mov	al, \code
	mov	cx, \height
	mov	si, offset .Ln\@
	call	same_glyph
	jmp	.Le\@
.Ln\@:	.asciz	"\name"
.Le\@:
	.endm

/* GTEXT STRING, ROW, COL, COLOUR, FONT: AH=09h, a character at a time, the
   cursor moved with AH=02h; then said as @gtext.  FONT is 8x8, 8x14 or
   8x16, the font's height also being the cell's. */
	.macro	GTEXT str, row, col, colour, font, height
	push	si
	mov	si, offset .Ls\@
	mov	dx, (\row << 8) | \col
	mov	bl, \colour
	call	gwrite
	PUTS	"@gtext x "
	mov	ax, \col * 8
	call	puthex16
	call	putsp
	mov	ax, \row * \height
	call	puthex16
	PUTS	" \font "
	mov	al, \colour
	call	puthex8
	call	putsp
	call	puts
	call	putnl
	pop	si
	jmp	.Le\@
.Ls\@:	.asciz	"\str"
.Le\@:
	.endm

main:
	cld
	mov	ax, 0x0003
	int	0x10
	mov	ah, 1
	mov	cx, 0x2000
	int	0x10

	/* ---- 01h, 02h, 04h: the ROM fonts into block 0, the screen as it was */
	mov	ax, 0x1101
	xor	bl, bl
	int	0x10
	GLYPH	10.11.01.glyph-A, 0, 'A', 2, 14
	GLYPH	10.11.01.glyph-g, 0, 'g', 2, 14
	ROWS	10.11.01, 24, 16
	mov	ax, 0x1102
	xor	bl, bl
	int	0x10
	GLYPH	10.11.02.glyph-A, 0, 'A', 3, 8
	GLYPH	10.11.02.glyph-g, 0, 'g', 3, 8
	mov	ax, 0x1104
	xor	bl, bl
	int	0x10
	GLYPH	10.11.04.glyph-A, 0, 'A', 6, 16
	GLYPH	10.11.04.glyph-g, 0, 'g', 6, 16
	ROWS	10.11.04, 24, 16

	/* ---- 12h: 8x8 in 400 lines, 50 rows */
	mov	ax, 0x1112
	xor	bl, bl
	int	0x10
	ROWS	10.11.12.50-lines, 49, 8
	mov	ah, 1
	mov	cx, 0x2000
	int	0x10
	TEXTSHOT 10.11.12.50-lines, 50
	/* ---- 11h: 8x14 in 400 lines, 28 rows */
	mov	ax, 0x1111
	xor	bl, bl
	int	0x10
	ROWS	10.11.11.28-lines, 27, 14
	mov	ah, 1
	mov	cx, 0x2000
	int	0x10
	TEXTSHOT 10.11.11.28-lines, 28
	/* ---- 14h: 8x16 again, 25 rows */
	mov	ax, 0x1114
	xor	bl, bl
	int	0x10
	ROWS	10.11.14, 24, 16

	/* ---- 350 scan lines (12h BL=30h), mode 03h: 25 rows of 14; then
	   12h, 8x8 in 350 lines: 43 rows */
	mov	ax, 0x1201
	mov	bl, 0x30
	int	0x10
	CK8	10.12.30.350, al, 0x12
	mov	ax, 0x0003
	int	0x10
	ROWS	10.12.30.350-lines, 24, 14
	mov	ah, 1
	mov	cx, 0x2000
	int	0x10
	TEXTSHOT 10.12.30.350-lines, 25
	mov	ax, 0x1112
	xor	bl, bl
	int	0x10
	ROWS	10.11.12.43-lines, 42, 8
	mov	ah, 1
	mov	cx, 0x2000
	int	0x10
	TEXTSHOT 10.11.12.43-lines, 43
	/* the other text modes in 350 lines: 07h, 9x14 (720x350), and 01h,
	   8x14 with every dot twice (640x350) */
	mov	ax, 0x0007
	int	0x10
	push	es
	push	0x40
	pop	es
	CK8	10.12.30.350-lines.m07.bda-rows, es:[0x84], 24
	CK16	10.12.30.350-lines.m07.bda-cheight, es:[0x85], 14
	pop	es
	mov	ah, 1
	mov	cx, 0x2000
	int	0x10
	TEXTSHOT 10.12.30.350-lines.m07, 25, 80, 0xb000, 1
	mov	ax, 0x0001
	int	0x10
	ROWS	10.12.30.350-lines.m01, 24, 14
	mov	ah, 1
	mov	cx, 0x2000
	int	0x10
	TEXTSHOT 10.12.30.350-lines.m01, 25, 40
	/* 400 lines again */
	mov	ax, 0x1202
	mov	bl, 0x30
	int	0x10
	CK8	10.12.30.400, al, 0x12
	mov	ax, 0x0003
	int	0x10
	ROWS	10.12.30.400-lines, 24, 16

	/* ---- 00h: a glyph of the user's own for A, a chequer */
	mov	ah, 1
	mov	cx, 0x2000
	int	0x10
	push	cs
	pop	es
	mov	ax, 0x1100
	mov	bx, 0x1000		/* 16 bytes a character, block 0 */
	mov	cx, 1
	mov	dx, 'A'
	mov	bp, offset chequer
	int	0x10
	mov	al, 0
	mov	ah, 'A'
	call	plane2_glyph
	push	cs
	pop	es
	mov	si, offset buf
	mov	di, offset chequer
	mov	cx, 16
	repe	cmpsb
	CKZ	10.11.00.glyph
	PUTS	"@glyph 10.11.00.user 41 x "
	mov	si, offset chequer
	mov	cx, 16
	call	hexdump
	call	putnl
	call	fill_ab
	push	0xb800
	pop	es
	mov	si, offset n_user
	mov	dx, 0x1950
	mov	cx, 2000
	call	textdump
	SHOT	10.11.00.user

	/* ---- 03h: two fonts.  The ROM's 8x16 into block 1 (04h, BL=1), the
	   chequer for A in block 1 only, and block 1 chosen for characters
	   whose attribute has bit 3 set (03h BL=04h).  A plain A then shows
	   as A in grey (07h) and as the chequer in white (0Fh). */
	mov	ax, 0x0003
	int	0x10
	mov	ah, 1
	mov	cx, 0x2000
	int	0x10
	mov	ax, 0x1104
	mov	bl, 1
	int	0x10
	push	cs
	pop	es
	mov	ax, 0x1100
	mov	bx, 0x1001
	mov	cx, 1
	mov	dx, 'A'
	mov	bp, offset chequer
	int	0x10
	GLYPH	10.11.04.block1-glyph-B, 1, 'B', 6, 16
	mov	ax, 0x1103
	mov	bl, 0x04
	int	0x10
	mov	dx, 0x3c4
	mov	al, 3
	out	dx, al
	inc	dx
	in	al, dx
	CK8	10.11.03.sr3, al, 0x04
	PUTS	"@glyph 10.11.03.blocks 41 1 "
	mov	si, offset chequer
	mov	cx, 16
	call	hexdump
	call	putnl
	call	fill_ab
	push	0xb800
	pop	es
	mov	di, 1
	mov	cx, 1000		/* every other cell in white: block 1 */
1:	mov	byte ptr es:[di], 0x0f
	add	di, 4
	loop	1b
	mov	si, offset n_blocks
	mov	dx, 0x1950
	mov	cx, 2000
	call	textdump
	SHOT	10.11.03.blocks

	/* ---- fonts for graphics modes: 23h (8x8), 24h (8x16) and 22h
	   (8x14), and AH=09h and 0Eh with them, in mode 12h */
	mov	ax, 0x0012
	int	0x10
	mov	ax, 0x1123
	xor	bl, bl
	mov	dl, 60
	int	0x10
	push	es
	push	0x40
	pop	es
	CK8	10.11.23.bda-rows, es:[0x84], 59
	CK16	10.11.23.bda-cheight, es:[0x85], 8
	pop	es
	call	int43_is
	mov	bh, 3
	call	font_ptr
	CK32	10.11.23.int43, eax, edx
	GTEXT	"ABCDEFGHIJKLMNOP", 1, 0, 0x0e, 8x8, 8
	/* AH=08h in a graphics mode: the character found by its glyph */
	mov	ah, 2
	xor	bh, bh
	mov	dx, 0x0102
	int	0x10
	mov	ah, 8
	xor	bh, bh
	int	0x10
	CK8	10.08.m12-graphics, al, 'C'
	/* AH=09h with bit 7 of the colour set draws with XOR: twice is
	   nothing, and once more is there */
	mov	dx, 0x0505
	mov	bl, 0x8f
	mov	si, offset s_x
	call	gwrite
	call	gwrite
	GTEXT	"X", 5, 6, 0x0f, 8x8, 8
	/* 0Eh, the teletype, in colour 0Ch */
	mov	ah, 2
	xor	bh, bh
	mov	dx, 0x0300
	int	0x10
	mov	si, offset s_hello
1:	mov	al, [si]
	or	al, al
	jz	2f
	mov	ah, 0x0e
	mov	bx, 0x000c
	int	0x10
	inc	si
	jmp	1b
2:	PUTS	"@gtext x 0000 0018 8x8 0c hello\n"
	mov	ax, 0x1124
	xor	bl, bl
	mov	dl, 30
	int	0x10
	push	es
	push	0x40
	pop	es
	CK8	10.11.24.bda-rows, es:[0x84], 29
	CK16	10.11.24.bda-cheight, es:[0x85], 16
	pop	es
	call	int43_is
	mov	bh, 6
	call	font_ptr
	CK32	10.11.24.int43, eax, edx
	GTEXT	"QRSTUVWXYZ", 10, 0, 0x0a, 8x16, 16
	mov	ax, 0x1122
	xor	bl, bl
	mov	dl, 34
	int	0x10
	push	es
	push	0x40
	pop	es
	CK8	10.11.22.bda-rows, es:[0x84], 33
	CK16	10.11.22.bda-cheight, es:[0x85], 14
	pop	es
	call	int43_is
	mov	bh, 2
	call	font_ptr
	CK32	10.11.22.int43, eax, edx
	GTEXT	"0123456789", 20, 0, 0x0b, 8x14, 14
	SHOT	10.11.2x.m12

	/* ---- mode 13h: AH=09h in 256 colours, with the mode's own font */
	mov	ax, 0x0013
	int	0x10
	GTEXT	"Mode13", 0, 0, 0x0f, 8x8, 8
	GTEXT	"256col", 2, 4, 0x09, 8x8, 8
	mov	ah, 2
	xor	bh, bh
	mov	dx, 0x0001
	int	0x10
	mov	ah, 8
	xor	bh, bh
	int	0x10
	CK8	10.08.m13-graphics, al, 'o'
	SHOT	10.09.m13

	/* ---- mode 04h: colours 1 to 3, and int 1Fh's characters from 80h on */
	mov	ax, 0x0004
	int	0x10
	GTEXT	"CGA", 0, 0, 0x03, 8x8, 8
	GTEXT	"pal", 1, 2, 0x01, 8x8, 8
	GTEXT	"\200\201\202", 3, 0, 0x02, 8x8, 8
	mov	ah, 2
	xor	bh, bh
	mov	dx, 0x0001
	int	0x10
	mov	ah, 8
	xor	bh, bh
	int	0x10
	CK8	10.08.m04-graphics, al, 'G'
	SHOT	10.09.m04

	mov	ax, 0x0003
	int	0x10
	DONE

n_user:	  .asciz "10.11.00.user"
n_blocks: .asciz "10.11.03.blocks"
s_x:	  .asciz "X"
s_hello:  .asciz "hello"
chequer:  .byte	0xaa, 0x55, 0xaa, 0x55, 0xaa, 0x55, 0xaa, 0x55
	  .byte	0xaa, 0x55, 0xaa, 0x55, 0xaa, 0x55, 0xaa, 0x55

crtc_read:			/* al the index: al the value */
	push	dx
	mov	dx, 0x3d4
	out	dx, al
	inc	dx
	in	al, dx
	pop	dx
	ret

/* the screen full of A and B in grey: A at even cells, B at odd */
fill_ab:
	pusha
	push	es
	push	0xb800
	pop	es
	xor	di, di
	mov	cx, 1000
1:	mov	ax, 0x0741
	stosw
	mov	ax, 0x0742
	stosw
	loop	1b
	pop	es
	popa
	ret

/* the glyph of character ah in font block al, out of plane 2, into buf
   (32 bytes).  The sequencer and graphics controller are set for reading
   plane 2 and put back as a text mode has them. */
plane2_glyph:
	pusha
	push	ds
	push	es
	push	cs
	pop	es
	movzx	bx, al			/* block: 0..7 at 8K each, 0 2 4 6 1 3 5 7 */
	mov	si, bx
	and	si, 3
	shl	si, 14			/* blocks 0-3: 0, 16K, 32K, 48K */
	test	bl, 4
	jz	1f
	add	si, 0x2000		/* 4-7: 8K further */
1:	movzx	ax, ah
	shl	ax, 5
	add	si, ax
	mov	dx, 0x3c4
	mov	ax, 0x0402		/* writes to plane 2 only (not needed) */
	out	dx, ax
	mov	ax, 0x0604		/* no odd/even, all of memory */
	out	dx, ax
	mov	dx, 0x3ce
	mov	ax, 0x0204		/* read plane 2 */
	out	dx, ax
	mov	ax, 0x0005
	out	dx, ax
	mov	ax, 0x0406		/* a000, 64K, no odd/even */
	out	dx, ax
	push	0xa000
	pop	ds
	mov	di, buf
	mov	cx, 32
	rep	movsb
	/* as a text mode has them */
	mov	dx, 0x3c4
	mov	ax, 0x0302
	out	dx, ax
	mov	ax, 0x0204
	out	dx, ax
	mov	dx, 0x3ce
	mov	ax, 0x0004
	out	dx, ax
	mov	ax, 0x1005
	out	dx, ax
	mov	ax, 0x0e06
	out	dx, ax
	pop	es
	pop	ds
	popa
	ret

/* buf against cx lines of character al in the BIOS's font bh; cs:si the
   name */
same_glyph:
	pusha
	push	es
	push	ax
	push	cx
	push	si
	mov	ax, 0x1130
	int	0x10			/* es:bp the font */
	pop	si
	pop	cx
	pop	ax
	movzx	ax, al
	mul	cx
	mov	di, bp
	add	di, ax
	push	si
	mov	si, buf
	repe	cmpsb			/* ds:si (buf) against es:di */
	pop	si
	call	ck_z
	pop	es
	popa
	ret

/* eax: int 43h's vector, segment in the high half */
int43_is:
	push	es
	push	0
	pop	es
	mov	eax, es:[0x43 * 4]
	pop	es
	ret

/* edx: the pointer that 1130h gives for bh, as segment:offset */
font_ptr:
	push	es
	push	bp
	push	cx
	push	ax
	push	bx
	mov	ax, 0x1130
	int	0x10
	mov	dx, es
	shl	edx, 16
	mov	dx, bp
	pop	bx
	pop	ax
	pop	cx
	pop	bp
	pop	es
	ret

/* the string at cs:si with AH=09h, a character at a time, from row dh,
   column dl, colour bl, the cursor moved with 02h */
gwrite:
	pusha
1:	mov	al, cs:[si]
	or	al, al
	jz	2f
	push	bx
	mov	ah, 2
	xor	bh, bh
	int	0x10
	pop	bx
	push	bx
	mov	ah, 9
	xor	bh, bh
	mov	cx, 1
	int	0x10
	pop	bx
	inc	si
	inc	dl
	jmp	1b
2:	popa
	ret

	.include "draw.inc"
