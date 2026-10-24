/*
 * VGA13.COM: a picture in VGA mode 13h (320x200, 256 colours), for looking
 * at how an emulator puts that mode on a screen.  The 256 colours of the
 * palette side by side from the left, a column each, and the first 64 again
 * to fill the 320.  A key ends it and puts the text mode back.
 *
 * Build:
 *   as --32 -o vga13.o vga13.S
 *   ld -m elf_i386 -Ttext 0x100 --oformat binary -o VGA13.COM vga13.o
 *
 * Offered under the licence of tiny386 (BSD 3-clause).
 */
	.intel_syntax noprefix
	.code16
	.text
	.globl _start
_start:
	cld
	mov	ax, 0x0013
	int	0x10
	mov	ax, 0xa000
	mov	es, ax
	xor	di, di
	mov	dx, 200
1:	xor	bx, bx
2:	mov	al, bl
	inc	al			/* colour 1 first: colour 0 is black */
	stosb
	inc	bx
	cmp	bx, 320
	jb	2b
	dec	dx
	jnz	1b

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
