/*
 * BINFO.COM: what the BIOS says about the display, and its odds and ends:
 * int 10h AH=12h (BL=10h EGA information, 32h video addressing, 34h cursor
 * emulation, 36h screen refresh), AH=1Ah (display combination), AH=1Bh
 * (functionality and state, in modes 03h, 12h and 13h) and AH=1Ch (save
 * and restore the video state).
 *
 * What a VGA with 256K answers is what is wanted.  One picture: the screen
 * with refresh turned off, which a VGA shows black.
 *
 * Build:
 *   as --32 -I tests/guest -o binfo.o binfo.S
 *   ld -m elf_i386 -Ttext 0x100 --oformat binary -o BINFO.COM binfo.o
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

state	= 0x9000		/* 1Bh's 64 bytes */
save	= 0xa000		/* 1Ch's buffer */

/* the byte or word at OFFSET of 1Bh's buffer */
	.macro	ST8 name, offset, want
	CK8	"\name", [state+\offset], \want
	.endm
	.macro	ST16 name, offset, want
	CK16	"\name", [state+\offset], \want
	.endm

main:
	cld
	mov	ax, 0x0003
	int	0x10

	/* ---- 12h BL=10h: colour, 256K */
	mov	ah, 0x12
	mov	bl, 0x10
	mov	cx, 0xffff
	int	0x10
	CK8	10.12.10.colour, bh, 0
	CK8	10.12.10.memory-256k, bl, 3
	INFO16	10.12.10.cx-features-switches, cx

	/* ---- 12h BL=34h: cursor emulation off, then 0607h is taken as it is */
	mov	ax, 0x1201
	mov	bl, 0x34
	int	0x10
	CK8	10.12.34.disable, al, 0x12
	push	0x40
	pop	es
	mov	al, es:[0x87]
	and	al, 1
	CK8	10.12.34.bda-bit, al, 1
	mov	ah, 1
	mov	cx, 0x0607
	int	0x10
	call	crtc_cursor
	CK16	10.12.34.crtc-as-given, ax, 0x0607
	mov	ax, 0x1200
	mov	bl, 0x34
	int	0x10
	mov	al, es:[0x87]
	and	al, 1
	CK8	10.12.34.enable, al, 0

	/* ---- 12h BL=32h: the processor kept from video memory, and let back */
	push	0xb800
	pop	es
	mov	word ptr es:[0], 0x1f41
	mov	ax, 0x1201
	mov	bl, 0x32
	int	0x10
	CK8	10.12.32.disable, al, 0x12
	mov	dx, 0x3cc		/* the misc output register: bit 1 off */
	in	al, dx
	and	al, 2
	CK8	10.12.32.misc-output-bit1-off, al, 0
	mov	word ptr es:[0], 0x2e42
	mov	ax, 0x1200
	mov	bl, 0x32
	int	0x10
	CK16	10.12.32.write-ignored-while-off, es:[0], 0x1f41
	mov	word ptr es:[0], 0x1f43
	CK16	10.12.32.on-again, es:[0], 0x1f43

	/* ---- 1Ah: a VGA with a colour display, nothing else */
	mov	ax, 0x1a00
	int	0x10
	CK8	10.1a.00.al, al, 0x1a
	CK8	10.1a.00.active, bl, 0x08
	CK8	10.1a.00.alternate, bh, 0x00
	mov	ax, 0x1a01
	mov	bx, 0x0008
	int	0x10
	CK8	10.1a.01.al, al, 0x1a

	/* ---- 1Bh in mode 03h, the cursor at 5,10 */
	mov	ah, 2
	xor	bh, bh
	mov	dx, 0x050a
	int	0x10
	call	state1b
	CK8	10.1b.al, al, 0x1b
	ST8	10.1b.m03.mode, 4, 3
	ST16	10.1b.m03.cols, 5, 80
	ST16	10.1b.m03.regen-length, 7, 0x1000
	ST16	10.1b.m03.start, 9, 0
	ST16	10.1b.m03.cursor-page0, 0x0b, 0x050a
	ST16	10.1b.m03.cursor-type, 0x1b, 0x0607
	ST8	10.1b.m03.page, 0x1d, 0
	ST16	10.1b.m03.crtc-port, 0x1e, 0x3d4
	ST8	10.1b.m03.rows, 0x22, 25
	ST16	10.1b.m03.char-height, 0x23, 16
	ST8	10.1b.m03.dcc-active, 0x25, 8
	ST8	10.1b.m03.dcc-alternate, 0x26, 0
	ST16	10.1b.m03.colours, 0x27, 16
	ST8	10.1b.m03.pages, 0x29, 8
	ST8	10.1b.m03.scan-lines-400, 0x2a, 2
	ST8	10.1b.m03.memory-256k, 0x31, 3
	INFO8	10.1b.m03.mode-ctl-3x8, [state+0x20]
	INFO8	10.1b.m03.palette-3x9, [state+0x21]
	INFO8	10.1b.m03.char-blocks, [state+0x2b]
	INFO8	10.1b.m03.misc-flags, [state+0x2d]
	INFO8	10.1b.m03.save-flags, [state+0x32]
	/* the static functionality table it points to */
	push	ds
	lds	si, [state]
	mov	eax, [si]
	mov	bl, [si + 7]
	mov	bh, [si + 8]
	mov	cl, [si + 9]
	pop	ds
	and	eax, 0x00ffffff
	CK32	10.1b.table.modes-00-13, eax, 0x000fe0ff
	CK8	10.1b.table.scan-lines, bl, 7
	INFO8	10.1b.table.char-blocks, bh
	INFO8	10.1b.table.active-blocks, cl

	/* ---- 1Bh in mode 12h and 13h */
	mov	ax, 0x0012
	int	0x10
	call	state1b
	ST8	10.1b.m12.mode, 4, 0x12
	ST16	10.1b.m12.cols, 5, 80
	ST8	10.1b.m12.rows, 0x22, 30
	ST16	10.1b.m12.char-height, 0x23, 16
	ST16	10.1b.m12.colours, 0x27, 16
	ST8	10.1b.m12.pages, 0x29, 1
	ST8	10.1b.m12.scan-lines-480, 0x2a, 3
	mov	ax, 0x0013
	int	0x10
	call	state1b
	ST8	10.1b.m13.mode, 4, 0x13
	ST16	10.1b.m13.cols, 5, 40
	ST8	10.1b.m13.rows, 0x22, 25
	ST16	10.1b.m13.char-height, 0x23, 8
	ST16	10.1b.m13.colours, 0x27, 256
	ST8	10.1b.m13.pages, 0x29, 1
	ST8	10.1b.m13.scan-lines-400, 0x2a, 2

	/* ---- 1Ch: the hardware, the BIOS data and the DAC saved, changed,
	   and put back */
	mov	ax, 0x0003
	int	0x10
	mov	ax, 0x1c00
	mov	cx, 7
	int	0x10
	CK8	10.1c.00.al, al, 0x1c
	INFO16	10.1c.00.blocks, bx
	cmp	bx, 0x40		/* no more than the 4K kept for it */
	jbe	1f
	BAD	10.1c.00.size, "more than 4K"
	jmp	9f
1:	mov	ah, 2			/* the state: the cursor at 5,10, DAC 1 */
	xor	bh, bh
	mov	dx, 0x050a
	int	0x10
	mov	ax, 0x1010
	mov	bx, 1
	mov	dh, 10
	mov	cx, 0x141e
	int	0x10
	push	cs
	pop	es
	mov	ax, 0x1c01
	mov	cx, 7
	mov	bx, save
	int	0x10
	CK8	10.1c.01.al, al, 0x1c
	mov	ah, 2			/* changed */
	xor	bh, bh
	mov	dx, 0x1446
	int	0x10
	mov	ax, 0x1010
	mov	bx, 1
	mov	dh, 63
	xor	cx, cx
	int	0x10
	mov	ax, 0x1000
	mov	bx, 0x3f01
	int	0x10
	push	cs
	pop	es
	mov	ax, 0x1c02		/* and back */
	mov	cx, 7
	mov	bx, save
	int	0x10
	CK8	10.1c.02.al, al, 0x1c
	push	0x40
	pop	es
	CK16	10.1c.02.bda-cursor, es:[0x50], 0x050a
	call	crtc_curpos
	CK16	10.1c.02.crtc-cursor, ax, 5*80+10
	mov	ax, 0x1015
	mov	bx, 1
	int	0x10
	CK8	10.1c.02.dac-r, dh, 0x0a
	CK8	10.1c.02.dac-g, ch, 0x14
	CK8	10.1c.02.dac-b, cl, 0x1e
	mov	ax, 0x1007
	mov	bl, 1
	int	0x10
	CK8	10.1c.02.palette-register, bh, 1
9:

	/* ---- 12h BL=36h: the screen's refresh off: a VGA shows black */
	mov	ax, 0x0012
	int	0x10
	mov	bx, 80
	mov	cx, 480
	mov	dx, 0x0f10
	xor	si, si
	call	draw_planar
	mov	ax, 0x1201
	mov	bl, 0x36
	int	0x10
	CK8	10.12.36.off, al, 0x12
	mov	dx, 0x3c4
	mov	al, 1
	out	dx, al
	inc	dx
	in	al, dx
	and	al, 0x20
	CK8	10.12.36.sr01-bit5, al, 0x20
	SHOT	10.12.36.refresh-off
	mov	ax, 0x1200
	mov	bl, 0x36
	int	0x10
	mov	dx, 0x3c4
	mov	al, 1
	out	dx, al
	inc	dx
	in	al, dx
	and	al, 0x20
	CK8	10.12.36.on, al, 0

	mov	ax, 0x0003
	int	0x10
	DONE

/* 1Bh's state into state; al what the BIOS returns */
state1b:
	push	bx
	push	di
	push	es
	push	cs
	pop	es
	mov	di, state
	mov	cx, 64
	xor	al, al
	rep	stosb
	mov	ah, 0x1b
	xor	bx, bx
	mov	di, state
	int	0x10
	pop	es
	pop	di
	pop	bx
	ret

crtc_read:			/* al the index: al the value */
	push	dx
	mov	dx, 0x3d4
	out	dx, al
	inc	dx
	in	al, dx
	pop	dx
	ret
crtc_cursor:
	mov	al, 0x0a
	call	crtc_read
	mov	ah, al
	mov	al, 0x0b
	jmp	crtc_read
crtc_curpos:
	mov	al, 0x0e
	call	crtc_read
	mov	ah, al
	mov	al, 0x0f
	jmp	crtc_read

	.include "draw.inc"
