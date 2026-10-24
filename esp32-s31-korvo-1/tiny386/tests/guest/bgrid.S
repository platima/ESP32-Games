/*
 * BGRID.COM: mode 10h (640x350, 16 colours) used as an 80x25 grid of text,
 * the glyphs written straight into video memory, as DOS programs did to be
 * quicker than the BIOS.
 *
 * The glyphs are the BIOS's own 8x14 font (int 10h AX=1130h BH=02h).  Each
 * cell has a character, a foreground and a background colour, both drawn;
 * the characters and colours change from one way of drawing to the next, so
 * that each picture has to replace all of the one before.  The ways:
 *   a  the map mask, one plane at a time: each plane's byte worked out
 *      from the glyph and the two colours (write mode 0, plain)
 *   b  write mode 0 with set/reset on all planes: the bit mask the glyph's
 *      background bits, then its foreground bits, the colour from set/reset
 *   c  write mode 2: the bit mask as in b, the colour as the byte written
 *   d  write mode 3 with set/reset and a rotate of 3: the byte written,
 *      turned 3 to the left, is the bit mask after the VGA turns it back
 * then
 *   scroll  the grid up a row with write mode 1 (all four planes copied
 *      through the latches, a byte at a time), and the last row cleared to
 *      blue with set/reset
 *   read    on the picture of d, read mode 0 plane by plane, and read mode 1
 *      (colour compare) for each cell's foreground and background, and with
 *      no plane compared
 *   bios    the same grid through int 10h AH=09h (foreground only: the BIOS
 *      clears the background), and a scroll with AH=06h, for comparison
 * Each picture goes to the harness with the grid as @text, and
 * tests/bioscheck.py checks every pixel of it.
 *
 * "BGRID perf" draws the same without pictures or checks, with marks
 * (0xA1 to 0xA7, then 0xAF) at 0000:04F0 around each way, for
 * tests/perf.sh to count; "BGRID pic" draws a once and puts 0xB1 there,
 * for the cost of showing the picture.
 *
 * Build:
 *   as --32 -I tests/guest -o bgrid.o bgrid.S
 *   ld -m elf_i386 -Ttext 0x100 --oformat binary -o BGRID.COM bgrid.o
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

FONT	= 0x9000		/* the 8x14 font: 3584 bytes */
MODEL	= 0xa000		/* the grid: 2000 cells of character, attribute */
ROWB	= 80 * 14		/* bytes of a row of cells in each plane */

	.macro	OUTW port, value
	mov	dx, \port
	mov	ax, \value
	out	dx, ax
	.endm

/* the four planes written at once, write mode 0, nothing else on */
	.macro	PLAIN
	OUTW	0x3c4, 0x0f02
	OUTW	0x3ce, 0x0005
	OUTW	0x3ce, 0x0001
	OUTW	0x3ce, 0x0003
	OUTW	0x3ce, 0xff08
	.endm

/* a picture: the grid as @text NAME, then @shot NAME; in perf mode, mark M */
	.macro	PIC name, m
	cmp	byte ptr [how], 0
	jne	.Lp\@
	push	si
	mov	si, offset .Ln\@
	call	dumpgrid
	pop	si
	SHOT	\name
	jmp	.Le\@
.Ln\@:	.asciz	"\name"
.Lp\@:
.Le\@:
	.endm

/* in perf mode, mark M before the next piece */
	.macro	MARK m
	cmp	byte ptr [how], 1
	jne	.Le\@
	mov	al, \m
	call	setmark
.Le\@:
	.endm

main:
	cld
	/* what for: nothing, "perf" or "pic" */
	mov	byte ptr [how], 0
	cmp	byte ptr ds:[0x80], 3
	jb	1f
	cmp	byte ptr ds:[0x82], 'p'
	jne	1f
	mov	byte ptr [how], 1
	cmp	byte ptr ds:[0x83], 'e'
	je	1f
	mov	byte ptr [how], 2
1:
	mov	ax, 0x0010
	int	0x10
	mov	ah, 0x0f
	int	0x10
	cmp	byte ptr [how], 0
	jne	2f
	CK8	grid.mode-10h, al, 0x10
2:
	/* the BIOS's 8x14 font into this segment */
	push	ds
	mov	ax, 0x1130
	mov	bh, 2
	int	0x10
	push	es
	pop	ds
	mov	si, bp
	push	cs
	pop	es
	mov	di, FONT
	mov	cx, 256 * 14
	rep	movsb
	pop	ds
	push	0xa000
	pop	es

	/* ---- a: the map mask, a plane at a time */
	mov	byte ptr [k], 0
	call	fill_model
	MARK	0xa1
	PLAIN
	mov	byte ptr [plane], 0
3:	mov	cl, [plane]
	mov	ah, 1
	shl	ah, cl
	mov	al, 2
	mov	dx, 0x3c4
	out	dx, ax
	mov	word ptr [cellfn], offset cell_a
	call	for_cells
	inc	byte ptr [plane]
	cmp	byte ptr [plane], 4
	jb	3b
	PLAIN
	cmp	byte ptr [how], 2
	jne	4f
	mov	al, 0xb1		/* "pic": the picture is up */
	call	setmark
5:	hlt
	jmp	5b
4:	PIC	grid.a-map-mask

	/* ---- b: write mode 0 with set/reset and the bit mask */
	mov	byte ptr [k], 1
	call	fill_model
	MARK	0xa2
	PLAIN
	OUTW	0x3ce, 0x0f01		/* set/reset on all four planes */
	mov	word ptr [cellfn], offset cell_b
	call	for_cells
	PLAIN
	PIC	grid.b-set-reset

	/* ---- c: write mode 2 */
	mov	byte ptr [k], 2
	call	fill_model
	MARK	0xa3
	PLAIN
	OUTW	0x3ce, 0x0205
	mov	word ptr [cellfn], offset cell_c
	call	for_cells
	PLAIN
	PIC	grid.c-write-mode-2

	/* ---- d: write mode 3, set/reset, a rotate of 3 */
	mov	byte ptr [k], 3
	call	fill_model
	MARK	0xa4
	PLAIN
	OUTW	0x3ce, 0x0305
	OUTW	0x3ce, 0x0303
	mov	word ptr [cellfn], offset cell_d
	call	for_cells
	PLAIN
	PIC	grid.d-write-mode-3

	/* ---- reading it back, read mode 0 and read mode 1 */
	cmp	byte ptr [how], 0
	jne	6f
	call	reads
6:
	/* ---- up a row with write mode 1, the last row cleared to blue */
	call	model_up
	MARK	0xa5
	OUTW	0x3c4, 0x0f02
	OUTW	0x3ce, 0x0105		/* write mode 1: the latches */
	push	ds
	push	0xa000
	pop	ds
	mov	si, ROWB
	xor	di, di
	mov	cx, ROWB * 24
	rep	movsb			/* each read loads the latches */
	pop	ds
	OUTW	0x3ce, 0x0005
	OUTW	0x3ce, 0x0f01
	OUTW	0x3ce, 0x0100		/* set/reset: blue */
	mov	di, ROWB * 24
	mov	cx, ROWB
	rep	stosb
	PLAIN
	OUTW	0x3ce, 0x0000
	PIC	grid.scroll-write-mode-1

	/* ---- the BIOS: AH=09h a cell at a time, the background black */
	mov	byte ptr [k], 4
	call	fill_model
	MARK	0xa6
	call	bios_grid
	PIC	grid.bios-09h
	/* and AH=06h up a row, blue in */
	call	model_up
	MARK	0xa7
	mov	ax, 0x0601
	mov	bh, 1
	xor	cx, cx
	mov	dx, 0x184f
	int	0x10
	PIC	grid.bios-06h

	MARK	0xaf
	cmp	byte ptr [how], 1
	jne	7f
8:	hlt
	jmp	8b
7:	mov	ax, 0x0003
	int	0x10
	DONE

how:	.byte	0		/* 0 test, 1 perf, 2 pic */
k:	.byte	0		/* which grid */
plane:	.byte	0
cellfn:	.word	0
nbad:	.word	0
cfg:	.byte	0
cbg:	.byte	0

/* al into 0000:04F0 */
setmark:
	push	es
	push	0
	pop	es
	mov	es:[0x4f0], al
	pop	es
	ret

/*
 * fill_model: the grid for way k.  Cell i (row r, column c) holds
 * character (i + 37k) mod 256, foreground (c + r + k) mod 16 and background
 * (3c + 7r + 5k + 1) mod 16, the background turned by 8 where the two
 * would be the same.  For the BIOS (k = 4) the foreground is never 0, and
 * the background is 0.
 */
fill_model:
	pusha
	mov	bx, MODEL
	xor	bp, bp			/* r */
1:	xor	cx, cx			/* c */
2:	mov	ax, bp			/* the character: (80r + c + 37k) mod 256 */
	imul	ax, ax, 80
	add	ax, cx
	movzx	dx, byte ptr [k]
	imul	dx, dx, 37
	add	ax, dx
	mov	[bx], al
	mov	ax, cx
	add	ax, bp			/* c + r */
	cmp	byte ptr [k], 4
	je	6f
	add	al, [k]
	and	al, 15
	mov	[cfg], al		/* the foreground */
	imul	ax, cx, 3
	imul	dx, bp, 7
	add	ax, dx
	movzx	dx, byte ptr [k]
	imul	dx, dx, 5
	add	ax, dx
	inc	ax
	and	al, 15			/* the background */
	cmp	al, [cfg]
	jne	7f
	xor	al, 8
7:	shl	al, 4
	or	al, [cfg]
	mov	[bx + 1], al
	jmp	5f
6:	mov	dl, 15			/* the BIOS's: (c + r) mod 15 + 1 on black */
	div	dl
	mov	al, ah
	inc	al
	mov	[bx + 1], al
5:	add	bx, 2
	inc	cx
	cmp	cx, 80
	jb	2b
	inc	bp
	cmp	bp, 25
	jb	1b
	popa
	ret

/* the grid up a row; the last row blue, nothing on it */
model_up:
	pusha
	push	es
	push	cs
	pop	es
	mov	si, MODEL + 160
	mov	di, MODEL
	mov	cx, 80 * 24
	rep	movsw
	mov	ax, 0x1f20
	mov	cx, 80
	rep	stosw
	pop	es
	popa
	ret

/* @text NAME 50 19 HEX: the grid; cs:si the name */
dumpgrid:
	pusha
	push	es
	mov	ax, cs
	add	ax, MODEL / 16
	mov	es, ax
	mov	dx, 0x1950
	mov	cx, 2000
	call	textdump
	pop	es
	popa
	ret

/*
 * for_cells: [cellfn] for every cell, row by row, with si the glyph's first
 * line in FONT, di the cell's first byte in video memory (es a000), dl the
 * foreground and dh the background.  The function may change any register
 * but bx, cx and bp, and es and ds.
 */
for_cells:
	pusha
	mov	bx, MODEL
	xor	bp, bp			/* r */
1:	xor	cx, cx			/* c */
2:	mov	ax, [bx]
	movzx	si, al
	imul	si, si, 14
	add	si, FONT
	mov	dl, ah
	and	dl, 15
	mov	dh, ah
	shr	dh, 4
	imul	di, bp, ROWB
	add	di, cx
	push	bx
	push	cx
	push	bp
	call	[cellfn]
	pop	bp
	pop	cx
	pop	bx
	add	bx, 2
	inc	cx
	cmp	cx, 80
	jb	2b
	inc	bp
	cmp	bp, 25
	jb	1b
	popa
	ret

/* a: this plane's byte for each line: the glyph where the foreground has
   the plane's bit, its inverse where the background has */
cell_a:
	mov	cl, [plane]
	mov	al, dl
	shr	al, cl
	and	al, 1
	neg	al
	mov	bl, al			/* 0FFh if the foreground has it */
	mov	al, dh
	shr	al, cl
	and	al, 1
	neg	al
	mov	bh, al			/* likewise the background */
	mov	cx, 14
1:	lodsb
	mov	ah, al
	and	al, bl
	not	ah
	and	ah, bh
	or	al, ah
	mov	es:[di], al
	add	di, ROWB / 14
	loop	1b
	ret

/* b: set/reset the background, the bit mask the glyph's inverse; then
   the foreground and the glyph.  A read before each write loads the
   latches, which keep the bits the mask leaves out. */
cell_b:
	mov	[cfg], dl
	mov	[cbg], dh
	push	si
	push	di
	mov	dx, 0x3ce
	mov	ah, [cbg]
	xor	al, al
	out	dx, ax
	mov	cx, 14
1:	mov	ah, [si]
	not	ah
	mov	al, 8
	out	dx, ax
	mov	al, es:[di]
	mov	es:[di], al
	inc	si
	add	di, 80
	loop	1b
	pop	di
	pop	si
	mov	ah, [cfg]
	xor	al, al
	out	dx, ax
	mov	cx, 14
2:	mov	ah, [si]
	mov	al, 8
	out	dx, ax
	mov	al, es:[di]
	mov	es:[di], al
	inc	si
	add	di, 80
	loop	2b
	ret

/* c: write mode 2, the colour is the byte written */
cell_c:
	mov	[cfg], dl
	mov	[cbg], dh
	mov	dx, 0x3ce
	mov	cx, 14
1:	mov	ah, [si]
	not	ah
	mov	al, 8
	out	dx, ax
	mov	al, es:[di]
	mov	al, [cbg]
	mov	es:[di], al
	mov	ah, [si]
	mov	al, 8
	out	dx, ax
	mov	al, es:[di]
	mov	al, [cfg]
	mov	es:[di], al
	inc	si
	add	di, 80
	loop	1b
	ret

/* d: write mode 3, set/reset the colour; the byte written, turned 3 to the
   left, is turned back by the VGA and becomes the bit mask */
cell_d:
	mov	[cfg], dl
	mov	[cbg], dh
	push	si
	push	di
	mov	dx, 0x3ce
	mov	ah, [cbg]
	xor	al, al
	out	dx, ax
	mov	cx, 14
1:	mov	al, [si]
	not	al
	rol	al, 3
	mov	ah, es:[di]
	mov	es:[di], al
	inc	si
	add	di, 80
	loop	1b
	pop	di
	pop	si
	mov	ah, [cfg]
	xor	al, al
	out	dx, ax
	mov	cx, 14
2:	mov	al, [si]
	rol	al, 3
	mov	ah, es:[di]
	mov	es:[di], al
	inc	si
	add	di, 80
	loop	2b
	ret

/* ---- reading back the picture of d */

reads:
	pusha
	/* read mode 0, each plane */
	mov	byte ptr [plane], 0
1:	mov	ah, [plane]
	mov	al, 4
	mov	dx, 0x3ce
	out	dx, ax
	mov	word ptr [nbad], 0
	mov	word ptr [cellfn], offset read0
	call	for_cells
	mov	al, [plane]
	add	al, '0'
	mov	[n_r0 + 23], al
	mov	si, offset n_r0
	call	report
	inc	byte ptr [plane]
	cmp	byte ptr [plane], 4
	jb	1b
	OUTW	0x3ce, 0x0004
	/* read mode 1: the foreground's colour, the background's, no plane */
	OUTW	0x3ce, 0x0805
	OUTW	0x3ce, 0x0f07		/* every plane compared */
	mov	word ptr [nbad], 0
	mov	word ptr [cellfn], offset read1_fg
	call	for_cells
	mov	si, offset n_r1fg
	call	report
	mov	word ptr [nbad], 0
	mov	word ptr [cellfn], offset read1_bg
	call	for_cells
	mov	si, offset n_r1bg
	call	report
	OUTW	0x3ce, 0x0007		/* no plane compared: every bit 1 */
	mov	word ptr [nbad], 0
	mov	word ptr [cellfn], offset read1_none
	call	for_cells
	mov	si, offset n_r1none
	call	report
	OUTW	0x3ce, 0x0f07
	OUTW	0x3ce, 0x0005
	popa
	ret
n_r0:	  .asciz "grid.read-mode-0.plane-x"
n_r1fg:	  .asciz "grid.read-mode-1.foreground"
n_r1bg:	  .asciz "grid.read-mode-1.background"
n_r1none: .asciz "grid.read-mode-1.no-plane"

/* @ok or @bad cs:si, by [nbad] */
report:
	cmp	word ptr [nbad], 0
	jne	1f
	call	say_ok
	PUTS	" every byte of 2000 cells\n"
	ret
1:	call	say_bad
	PUTS	" bytes wrong: "
	mov	ax, [nbad]
	call	puthex16
	call	putnl
	ret

/* read mode 0: the plane's byte, as cell_a would write it */
read0:
	mov	cl, [plane]
	mov	al, dl
	shr	al, cl
	and	al, 1
	neg	al
	mov	bl, al
	mov	al, dh
	shr	al, cl
	and	al, 1
	neg	al
	mov	bh, al
	mov	cx, 14
1:	lodsb
	mov	ah, al
	and	al, bl
	not	ah
	and	ah, bh
	or	al, ah
	cmp	es:[di], al
	je	2f
	inc	word ptr [nbad]
2:	add	di, 80
	loop	1b
	ret

/* read mode 1 with the foreground as the colour to compare: the glyph */
read1_fg:
	mov	ah, dl
	call	compare
	mov	cx, 14
1:	lodsb
	cmp	es:[di], al
	je	2f
	inc	word ptr [nbad]
2:	add	di, 80
	loop	1b
	ret

/* with the background: the glyph's inverse */
read1_bg:
	mov	ah, dh
	call	compare
	mov	cx, 14
1:	lodsb
	not	al
	cmp	es:[di], al
	je	2f
	inc	word ptr [nbad]
2:	add	di, 80
	loop	1b
	ret

/* with no plane compared: 0FFh */
read1_none:
	mov	cx, 14
1:	cmp	byte ptr es:[di], 0xff
	je	2f
	inc	word ptr [nbad]
2:	add	di, 80
	loop	1b
	ret

/* the colour compare register (GR02h) from ah */
compare:
	push	dx
	mov	al, 2
	mov	dx, 0x3ce
	out	dx, ax
	pop	dx
	ret

/* the grid through int 10h: AH=02h to the cell, AH=09h the character in
   its foreground */
bios_grid:
	pusha
	mov	bx, MODEL
	xor	dx, dx			/* dh row, dl column */
1:	push	bx
	mov	ah, 2
	xor	bh, bh
	int	0x10
	pop	bx
	mov	al, [bx]
	push	bx
	mov	bl, [bx + 1]
	xor	bh, bh
	mov	ah, 9
	mov	cx, 1
	int	0x10
	pop	bx
	add	bx, 2
	inc	dl
	cmp	dl, 80
	jb	1b
	xor	dl, dl
	inc	dh
	cmp	dh, 25
	jb	1b
	popa
	ret
