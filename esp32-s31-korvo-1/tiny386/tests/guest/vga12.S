/*
 * VGA12.COM: a picture in VGA mode 12h (640x480, 16 colours in four bit
 * planes), the mode Windows 3.x and 9x use with their standard VGA driver.
 * Sixteen bands of 30 lines, one in each colour, drawn by choosing which
 * planes a write goes to.  Then a white box, 16 pixels square, is moved
 * along the top band forty times, one line of text cell to the right each
 * time: what a mouse pointer or a caret does to the screen.  A key ends it
 * and puts the text mode back.
 *
 * Built with TEXT defined (VGA12T.COM) it then has the BIOS print forty
 * characters over one of the bands, as a program does that draws no text of
 * its own.  The BIOS moves the text cursor for each one, which is two writes
 * to the CRT controller, and tiny386 as released clears the screen at each.
 *
 * Build:
 *   as --32 -o vga12.o vga12.S
 *   ld -m elf_i386 -Ttext 0x100 --oformat binary -o VGA12.COM vga12.o
 *   as --32 --defsym TEXT=1 -o vga12t.o vga12.S
 *   ld -m elf_i386 -Ttext 0x100 --oformat binary -o VGA12T.COM vga12t.o
 *
 * Offered under the licence of tiny386 (BSD 3-clause).
 */
	.intel_syntax noprefix
	.code16
	.text
	.globl _start
_start:
	cld
	mov	ax, 0x0012
	int	0x10
	mov	ax, 0xa000
	mov	es, ax

	/* the bands: colour bl in the 2400 bytes from di on */
	xor	di, di
	xor	bl, bl
1:	mov	al, bl
	call	planes
	mov	cx, 80 * 30
	mov	al, 0xff
	rep	stosb
	inc	bl
	cmp	bl, 16
	jne	1b

	/* the box: 2 bytes wide and 16 lines high, at byte column si of
	   lines 4 to 19, drawn and taken away again by turns */
	mov	al, 15
	call	planes
	xor	si, si
2:	mov	al, 0xff
	call	box
	call	pause
	xor	al, al
	call	box
	add	si, 2
	cmp	si, 80
	jb	2b
	mov	al, 0xff
	xor	si, si
	call	box

	.ifdef TEXT
	/* the cursor to row 21, column 20, and forty characters from there,
	   in yellow */
	mov	ah, 0x02
	xor	bh, bh
	mov	dx, 0x1514
	int	0x10
	mov	cx, 40
	mov	al, 'A'
3:	push	ax
	push	cx
	mov	ah, 0x0e
	mov	bx, 0x000e
	int	0x10
	pop	cx
	pop	ax
	inc	al
	dec	cx
	jnz	3b
	.endif

	/* tell whoever is watching that the picture is up: 0xB1 in the
	   byte at 0000:04F0 (see tests/perf-main.c) */
	push	ds
	xor	ax, ax
	mov	ds, ax
	mov	byte ptr ds:[0x4f0], 0xb1
	pop	ds

	xor	ax, ax
	int	0x16
	mov	ax, 0x0003
	int	0x10
	ret

/* writes go to the planes in al */
planes:
	push	dx
	push	ax
	mov	dx, 0x3c4
	mov	al, 2
	out	dx, al
	inc	dx
	pop	ax
	out	dx, al
	pop	dx
	ret

/* al into the box at byte column si */
box:
	mov	di, 80 * 4
	add	di, si
	mov	cx, 16
1:	mov	es:[di], al
	mov	es:[di + 1], al
	add	di, 80
	dec	cx
	jnz	1b
	ret

/* two ticks of the BIOS clock, about a ninth of a second */
pause:
	push	ds
	xor	ax, ax
	mov	ds, ax
	mov	ax, ds:[0x46c]
	add	ax, 2
1:	cmp	ax, ds:[0x46c]
	jne	1b
	pop	ds
	ret
