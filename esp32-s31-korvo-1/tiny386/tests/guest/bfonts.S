/*
 * BFONTS.COM: the fonts in the VGA BIOS, through int 10h AX=1130h, out on
 * the debug port, so that tests/bioscheck.py can read text off the screen
 * in every mode with the BIOS's own fonts.  Also checks what 1130h says
 * about the current font in mode 03h.  No screen is needed.
 *
 * Build:
 *   as --32 -I tests/guest -o bfonts.o bfonts.S
 *   ld -m elf_i386 -Ttext 0x100 --oformat binary -o BFONTS.COM bfonts.o
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

/* the font that AX=1130h gives for bh, cx bytes of it, as @font NAME:
   cs:si the name */
dumpfont:
	push	ax
	push	bx
	push	cx
	push	dx
	push	bp
	push	es
	push	ds
	push	cx
	mov	ax, 0x1130
	int	0x10
	pop	cx
	PUTS	"@font "
	call	puts
	call	putsp
	push	es
	pop	ds
	push	si
	mov	si, bp
	call	hexdump
	pop	si
	call	putnl
	pop	ds
	pop	es
	pop	bp
	pop	dx
	pop	cx
	pop	bx
	pop	ax
	ret

/* an alternate font (9x14 or 9x16): entries of a character code and
   cx - 1 bytes, up to a code of 0 */
dumpalt:
	push	ax
	push	bx
	push	cx
	push	dx
	push	bp
	push	es
	push	ds
	push	cx
	mov	ax, 0x1130
	int	0x10
	pop	cx
	PUTS	"@font "
	call	puts
	call	putsp
	push	es
	pop	ds
	push	si
	mov	si, bp
	mov	dx, 64			/* no more than 64 entries */
1:	push	cx
	mov	cx, 1
	call	hexdump
	pop	cx
	cmp	byte ptr [si], 0
	je	2f
	push	cx
	dec	cx
	inc	si
	call	hexdump
	add	si, cx
	pop	cx
	dec	dx
	jnz	1b
2:	pop	si
	call	putnl
	pop	ds
	pop	es
	pop	bp
	pop	dx
	pop	cx
	pop	bx
	pop	ax
	ret

main:
	mov	ax, 0x0003
	int	0x10

	/* what the current font is: 16 lines a character, 25 rows */
	mov	ax, 0x1130
	mov	bh, 6
	int	0x10
	CK16	10.11.30.cx, cx, 16
	CK8	10.11.30.dl, dl, 24
	mov	ax, es
	or	ax, bp
	CKFLAG	10.11.30.bh6-pointer, ck_nz
	mov	ax, 0x1130
	mov	bh, 2
	int	0x10
	mov	ax, es
	or	ax, bp
	CKFLAG	10.11.30.bh2-pointer, ck_nz
	mov	ax, 0x1130
	mov	bh, 3
	int	0x10
	mov	ax, es
	or	ax, bp
	CKFLAG	10.11.30.bh3-pointer, ck_nz

	/* the pointers, for the record: int 1Fh, int 43h, and each font */
	xor	bh, bh
0:	mov	ax, 0x1130
	push	bx
	int	0x10
	pop	bx
	HEAD	info, "10.11.30.pointer-bh"
	mov	al, bh
	call	puthex8
	call	putsp
	mov	ax, es
	call	puthex16
	mov	al, ':'
	call	putc
	mov	ax, bp
	call	puthex16
	call	putnl
	inc	bh
	cmp	bh, 8
	jb	0b

	mov	si, offset n8x16
	mov	bh, 6
	mov	cx, 256 * 16
	call	dumpfont
	mov	si, offset n8x14
	mov	bh, 2
	mov	cx, 256 * 14
	call	dumpfont
	mov	si, offset n8x8lo
	mov	bh, 3
	mov	cx, 128 * 8
	call	dumpfont
	mov	si, offset n8x8hi
	mov	bh, 4
	mov	cx, 128 * 8
	call	dumpfont
	mov	si, offset n9x14
	mov	bh, 5
	mov	cx, 15
	call	dumpalt
	mov	si, offset n9x16
	mov	bh, 7
	mov	cx, 17
	call	dumpalt
	DONE

/* ZF clear: ok */
ck_nz:
	jz	ck_isbad
	jmp	ck_isok

n8x16:	.asciz	"8x16"
n8x14:	.asciz	"8x14"
n8x8lo:	.asciz	"8x8lo"
n8x8hi:	.asciz	"8x8hi"
n9x14:	.asciz	"9x14alt"
n9x16:	.asciz	"9x16alt"
