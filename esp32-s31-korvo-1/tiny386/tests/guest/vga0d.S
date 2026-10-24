/*
 * VGA0D.COM: a picture in VGA mode 0Dh (320x200, 16 colours in four bit
 * planes, at half the dot clock), the EGA's mode that many DOS games use,
 * shown by the emulator as 640x400.  Sixteen bands of 12 lines, one in each
 * colour, drawn by choosing which planes a write goes to; the last 8 lines
 * are black.  A key ends it and puts the text mode back.
 *
 * Build:
 *   as --32 -o vga0d.o vga0d.S
 *   ld -m elf_i386 -Ttext 0x100 --oformat binary -o VGA0D.COM vga0d.o
 *
 * Offered under the licence of tiny386 (BSD 3-clause).
 */
	.intel_syntax noprefix
	.code16
	.text
	.globl _start
_start:
	cld
	mov	ax, 0x000d
	int	0x10
	mov	ax, 0xa000
	mov	es, ax

	/* the bands: colour bl in the 480 bytes from di on */
	xor	di, di
	xor	bl, bl
1:	mov	al, bl
	call	planes
	mov	cx, 40 * 12
	mov	al, 0xff
	rep	stosb
	inc	bl
	cmp	bl, 16
	jne	1b

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
