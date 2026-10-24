/*
 * draw.inc: pictures for the BIOS tests, drawn straight into video memory
 * the way each kind of mode lays it out on a VGA.  tests/bioscheck.py knows
 * what each should look like on the screen.
 *
 * Offered under the licence of tiny386 (BSD 3-clause).
 */

linebuf = 0x8000		/* a line of a picture, built before it is copied */

/*
 * draw_text: es the screen's segment, cl columns, ch rows, bl 1 for a
 * monochrome screen.  The character in row r, column c is "!" + (7r + c)
 * mod 94; the attribute of row r is (r mod 7 + 1) * 16 + 15 - r mod 7, on a
 * monochrome screen 70h, so that no cell is black on black.
 */
draw_text:
	pusha
	xor	di, di
	xor	dl, dl			/* 7r mod 94 */
	xor	dh, dh			/* r mod 7 */
	mov	bh, ch			/* rows to go */
1:	mov	al, dh
	inc	al
	shl	al, 4
	mov	ah, 15
	sub	ah, dh
	or	ah, al
	test	bl, bl
	jz	2f
	mov	ah, 0x70
2:	mov	al, dl
	push	cx
	xor	ch, ch
3:	push	ax
	add	al, '!'
	stosw
	pop	ax
	inc	al
	cmp	al, 94
	jb	4f
	xor	al, al
4:	loop	3b
	pop	cx
	add	dl, 7
	cmp	dl, 94
	jb	5f
	sub	dl, 94
5:	inc	dh
	cmp	dh, 7
	jb	6f
	xor	dh, dh
6:	dec	bh
	jnz	1b
	popa
	ret

/*
 * draw_cga: the picture in CGA's memory at b800, even lines from 0000 and
 * odd lines from 2000, 80 bytes a line.  al 0: 320x200 in 4 colours, four
 * bars of 80 pixels and a border in colour 3; al 1: 640x200 in 2, two bars
 * of 320 and a border in colour 1.
 */
draw_cga:
	pusha
	push	ds
	push	es
	push	cs
	pop	ds
	push	0xb800
	pop	es
	mov	bl, al
	xor	si, si
1:	mov	ax, si
	test	bl, bl
	jnz	2f
	mov	cl, 20			/* 2 bits: colour = column / 20 */
	div	cl
	mov	ah, 0x55
	mul	ah
	jmp	3f
2:	xor	al, al			/* 1 bit: colour = column / 40 */
	cmp	si, 40
	jb	3f
	mov	al, 0xff
3:	mov	[linebuf + si], al
	inc	si
	cmp	si, 80
	jb	1b
	test	bl, bl
	jnz	4f
	or	byte ptr [linebuf], 0xc0
	or	byte ptr [linebuf + 79], 0x03
	jmp	5f
4:	or	byte ptr [linebuf], 0x80
	or	byte ptr [linebuf + 79], 0x01
5:	xor	dx, dx			/* the line */
6:	mov	ax, dx
	shr	ax, 1
	imul	di, ax, 80
	test	dl, 1
	jz	7f
	add	di, 0x2000
7:	mov	cx, 80
	test	dx, dx
	jz	8f
	cmp	dx, 199
	je	8f
	mov	si, offset linebuf
	rep	movsb
	jmp	9f
8:	mov	al, 0xff
	rep	stosb
9:	inc	dx
	cmp	dx, 200
	jb	6b
	pop	es
	pop	ds
	popa
	ret

/*
 * draw_planar: the picture in a planar mode's memory at a000.  bx bytes a
 * line, cx lines, dl colours, dh the border's colour, si a table of the
 * colours (0: the colour is the bar's number).  The bar of byte column b is
 * b * dl / bx.  Written with write mode 2, which puts a colour into all
 * eight pixels of a byte at once.
 */
draw_planar:
	pusha
	push	ds
	push	es
	push	cs
	pop	ds
	push	0xa000
	pop	es
	mov	[pl_bpl], bx
	mov	[pl_lines], cx
	mov	[pl_ncol], dl
	mov	[pl_border], dh
	mov	[pl_tab], si
	mov	dx, 0x3ce
	mov	ax, 0x0205		/* write mode 2 */
	out	dx, ax
	mov	ax, 0xff08		/* every bit */
	out	dx, ax
	mov	dx, 0x3c4
	mov	ax, 0x0f02		/* every plane */
	out	dx, ax
	xor	bx, bx
1:	mov	ax, bx
	movzx	cx, byte ptr [pl_ncol]
	mul	cx
	div	word ptr [pl_bpl]
	mov	si, [pl_tab]
	test	si, si
	jz	2f
	add	si, ax
	mov	al, [si]
2:	mov	[linebuf + bx], al
	inc	bx
	cmp	bx, [pl_bpl]
	jb	1b
	xor	di, di
	mov	dx, [pl_lines]
3:	mov	si, offset linebuf
	mov	cx, [pl_bpl]
	rep	movsb
	dec	dx
	jnz	3b
	/* the border: the first and last lines */
	mov	al, [pl_border]
	xor	di, di
	mov	cx, [pl_bpl]
	rep	stosb
	mov	ax, [pl_lines]
	dec	ax
	mul	word ptr [pl_bpl]
	mov	di, ax
	mov	al, [pl_border]
	mov	cx, [pl_bpl]
	rep	stosb
	/* and the first and last pixel of every line: one bit of the byte,
	   the others kept by loading the latches first */
	mov	dx, 0x3ce
	mov	ax, 0x8008
	out	dx, ax
	xor	di, di
	mov	cx, [pl_lines]
	mov	bl, [pl_border]
4:	mov	al, es:[di]
	mov	es:[di], bl
	add	di, [pl_bpl]
	loop	4b
	mov	ax, 0x0108
	out	dx, ax
	mov	di, [pl_bpl]
	dec	di
	mov	cx, [pl_lines]
5:	mov	al, es:[di]
	mov	es:[di], bl
	add	di, [pl_bpl]
	loop	5b
	mov	ax, 0xff08
	out	dx, ax
	mov	ax, 0x0005		/* write mode 0 again */
	out	dx, ax
	pop	es
	pop	ds
	popa
	ret
pl_bpl:	.word	0
pl_lines: .word	0
pl_ncol: .byte	0
pl_border: .byte 0
pl_tab:	.word	0

/*
 * draw_chain4: mode 13h, 320x200 a byte a pixel at a000: 32 bars of 10
 * pixels in colours 0 to 31, and a border in colour 15.
 */
draw_chain4:
	pusha
	push	ds
	push	es
	push	cs
	pop	ds
	push	0xa000
	pop	es
	xor	bx, bx
1:	mov	ax, bx
	mov	cl, 10
	div	cl
	mov	[linebuf + bx], al
	inc	bx
	cmp	bx, 320
	jb	1b
	mov	byte ptr [linebuf], 15
	mov	byte ptr [linebuf + 319], 15
	xor	di, di
	xor	dx, dx
2:	mov	cx, 320
	test	dx, dx
	jz	3f
	cmp	dx, 199
	je	3f
	mov	si, offset linebuf
	rep	movsb
	jmp	4f
3:	mov	al, 15
	rep	stosb
4:	inc	dx
	cmp	dx, 200
	jb	2b
	pop	es
	pop	ds
	popa
	ret
