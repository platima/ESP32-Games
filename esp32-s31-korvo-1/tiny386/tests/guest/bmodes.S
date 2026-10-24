/*
 * BMODES.COM: every video mode from 00h to 13h through int 10h AH=00h.
 *
 * Each mode is set, read back with AH=0Fh and from the BIOS data area, and
 * a picture is drawn in it straight into video memory, the way the mode's
 * memory is laid out on a VGA:
 *   text modes      every cell a character from "!" to "~", the colours
 *                   changing from row to row; the screen's memory goes out
 *                   as @text, so that the picture can be read against it
 *   graphics modes  upright bars of each colour across the picture, and a
 *                   border one pixel wide round it
 * and then @shot asks for the screen to be looked at (tests/bioscheck.py
 * knows each picture).  Modes 08h to 0Ch are not VGA modes: the BIOS should
 * leave the mode as it was.  Mode 83h, 03h with bit 7 set, should keep what
 * is in video memory.
 *
 * Build:
 *   as --32 -I tests/guest -o bmodes.o bmodes.S
 *   ld -m elf_i386 -Ttext 0x100 --oformat binary -o BMODES.COM bmodes.o
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

/* set mode M and check what the BIOS says about it */
	.macro	SETMODE m, cols, rows1, cheight
	mov	ax, 0x00\m
	int	0x10
	mov	ah, 0x0f
	int	0x10
	CK8	"10.00.m\m\().getmode", al, 0x\m
	CK8	"10.00.m\m\().getcols", ah, \cols
	CK8	"10.00.m\m\().getpage", bh, 0
	push	es
	push	0x40
	pop	es
	CK8	"10.00.m\m\().bda-mode", es:[0x49], 0x\m
	CK16	"10.00.m\m\().bda-cols", es:[0x4a], \cols
	CK8	"10.00.m\m\().bda-rows", es:[0x84], \rows1
	CK16	"10.00.m\m\().bda-cheight", es:[0x85], \cheight
	pop	es
	.endm

/* a text mode: SEG is b800 or b000 */
	.macro	TEXTMODE m, cols, seg, mono
	SETMODE	\m, \cols, 24, 16
	mov	ah, 0x01		/* no cursor: it blinks */
	mov	cx, 0x2000
	int	0x10
	push	es
	push	0x\seg
	pop	es
	mov	cl, \cols
	mov	ch, 25
	mov	bl, \mono
	call	draw_text
	mov	si, offset .Ln\@
	mov	dl, \cols
	mov	dh, 25
	mov	cx, \cols * 25
	call	textdump
	pop	es
	SHOT	10.00.m\m
	jmp	.Le\@
.Ln\@:	.asciz	"10.00.m\m"
.Le\@:
	.endm

/* a mode that a VGA does not have: nothing should change */
	.macro	NOTMODE m, was
	mov	ax, 0x00\m
	int	0x10
	mov	ah, 0x0f
	int	0x10
	CK8	"10.00.m\m\().refused", al, 0x\was
	.endm

main:
	cld
	TEXTMODE 00, 40, b800, 0
	TEXTMODE 01, 40, b800, 0
	TEXTMODE 02, 80, b800, 0
	TEXTMODE 03, 80, b800, 0

	/* 03h again with bit 7: the memory is kept, and AH=0Fh says 83h */
	push	es
	push	0xb800
	pop	es
	mov	eax, es:[0]
	mov	ebx, es:[3998]
	push	ebx
	push	eax
	mov	ax, 0x0083
	int	0x10
	mov	ah, 0x0f
	int	0x10
	CK8	10.00.m83.getmode, al, 0x83
	pop	ecx
	CK32	10.00.m83.kept-first, es:[0], ecx
	pop	ecx
	CK32	10.00.m83.kept-last, es:[3998], ecx
	pop	es

	NOTMODE	08, 83
	NOTMODE	09, 83
	NOTMODE	0a, 83
	NOTMODE	0b, 83
	NOTMODE	0c, 83

	/* 320x200, 4 colours: CGA's memory, two bits a pixel */
	SETMODE	04, 40, 24, 8
	xor	al, al
	call	draw_cga
	SHOT	10.00.m04
	SETMODE	05, 40, 24, 8
	xor	al, al
	call	draw_cga
	SHOT	10.00.m05
	/* 640x200, 2 colours */
	SETMODE	06, 80, 24, 8
	mov	al, 1
	call	draw_cga
	SHOT	10.00.m06

	/* the planar modes: 4 planes, 8 pixels a byte */
	SETMODE	0d, 40, 24, 8
	mov	bx, 40
	mov	cx, 200
	mov	dx, 0x0f10
	xor	si, si
	call	draw_planar
	SHOT	10.00.m0d
	SETMODE	0e, 80, 24, 8
	mov	bx, 80
	mov	cx, 200
	mov	dx, 0x0f10
	xor	si, si
	call	draw_planar
	SHOT	10.00.m0e
	/* 640x350 monochrome: planes 0 and 2, so 0, 1, 4 and 5 */
	SETMODE	0f, 80, 24, 14
	mov	bx, 80
	mov	cx, 350
	mov	dx, 0x0504
	mov	si, offset mono4
	call	draw_planar
	SHOT	10.00.m0f
	SETMODE	10, 80, 24, 14
	mov	bx, 80
	mov	cx, 350
	mov	dx, 0x0f10
	xor	si, si
	call	draw_planar
	SHOT	10.00.m10
	SETMODE	11, 80, 29, 16
	mov	bx, 80
	mov	cx, 480
	mov	dx, 0x0102
	xor	si, si
	call	draw_planar
	SHOT	10.00.m11
	SETMODE	12, 80, 29, 16
	mov	bx, 80
	mov	cx, 480
	mov	dx, 0x0f10
	xor	si, si
	call	draw_planar
	SHOT	10.00.m12

	/* 320x200, 256 colours, a byte a pixel */
	SETMODE	13, 40, 24, 8
	call	draw_chain4
	SHOT	10.00.m13

	/* the monochrome text mode last: it uses the ports from 3B0h, and
	   what goes wrong there should not spoil the modes above */
	TEXTMODE 07, 80, b000, 1

	/* mode 03h after it: are the palette registers what mode 03h has?
	   And after mode 03h set a second time? */
	mov	ax, 0x0003
	int	0x10
	mov	si, offset n_after7
	call	check_ar
	mov	ax, 0x0003
	int	0x10
	mov	si, offset n_after3
	call	check_ar
	DONE

mono4:	.byte	0, 1, 4, 5
n_after7: .asciz "10.00.m03-after-m07.palette-registers"
n_after3: .asciz "10.00.m03-after-m03.palette-registers"
/* the palette registers and overscan of mode 03h, as on a VGA */
ar03:	.byte	0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x14, 0x07
	.byte	0x38, 0x39, 0x3a, 0x3b, 0x3c, 0x3d, 0x3e, 0x3f, 0x00

/* the palette registers through 1009h against ar03; cs:si the name */
check_ar:
	pusha
	push	es
	push	cs
	pop	es
	push	si
	mov	ax, 0x1009
	mov	dx, linebuf
	int	0x10
	mov	si, linebuf
	mov	di, offset ar03
	mov	cx, 17
	repe	cmpsb
	pop	si
	jne	1f
	call	say_ok
	call	putnl
	jmp	2f
1:	call	say_bad
	PUTS	" got="
	push	si
	mov	si, linebuf
	mov	cx, 17
	call	hexdump
	pop	si
	call	putnl
2:	pop	es
	popa
	ret

	.include "draw.inc"
